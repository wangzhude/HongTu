import { Shape, ShapeType, Point, getShapeBounds, normalizePropRecords } from '../models/GdsiiData';
import { editService } from './EditService';
import type { EditStructureState } from './EditService';
import { collectLayerExpressionHierarchy, LayerExpressionPlacement } from './LayerExpressionHierarchyCollector';
import { cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export type LayerRegionOp = 'union' | 'difference' | 'intersection' | 'xor';
export interface LayerRegionResult { ok: boolean; polygons: number[][]; message: string; roundCapErrorNm?: number; }
/** Each contour is a filled polygon. The adapter must merge overlaps and fracture holes before returning. */
export interface LayerRegionAdapter {
  boolean(subject: number[][], clip: number[][], op: LayerRegionOp, gridNm: number): LayerRegionResult;
  /** Shared painted-region operation used by other editing services. */
  shape?: (shape: Shape, gridNm: number, worldScale: number) => LayerRegionResult;
  /** Full-layer expression requires an explicit whole-contour PATH operation. */
  expressionPath?: (shape: Shape, gridNm: number, worldScale: number) => LayerRegionResult;
}
export interface LayerSelector { layer: number | null; datatype: number | null; key: string; }
export interface LayerExpressionInstruction { kind: 'source' | 'operation'; selectorKey: string; op?: LayerRegionOp; }
export interface LayerExpressionParseResult {
  ok: boolean; message: string; selectors: LayerSelector[]; instructions: LayerExpressionInstruction[];
}
export interface LayerExpressionOptions {
  expression: string;
  outputLayer: number;
  outputDatatype: number;
  keepSources: boolean;
  /** Explicit native quantization grid in nm; this is independent of display/drawing/snap settings. */
  gridNm: number;
  documentIdentity: string;
  /** Child edges included below current Cell: 0 = direct, 1..32 = recursive. */
  hierarchyDepth: number;
}
export interface LayerExpressionSource { selector: string; sourceIds: number[]; ignoredNonAreaIds: number[]; }
export interface LayerExpressionPreview {
  /** Unique issuance; equal geometry from a new prepare is a different preview. */
  generation: number;
  options: LayerExpressionOptions;
  outputs: Shape[];
  sourceIds: number[];
  ignoredNonAreaIds: number[];
  provenance: LayerExpressionSource[];
  revision: number;
  cellId: number;
  sourceFingerprint: string;
  areaNm2: number;
  pathSourceCount: number;
  roundCapErrorNm: number;
  /** Actual filled sources in current Cell coordinates, never source bounding boxes. */
  sourceGeometry: Shape[];
  sourceOccurrenceCount: number;
  visitedNodes: number;
  referenceIds: number[];
  occurrences: LayerExpressionSourceOccurrence[];
  structureFingerprint: string;
}
export interface LayerExpressionSourceOccurrence { sourceId: number; sourceCellId: number; instancePath: LayerExpressionPlacement[]; }
export interface LayerExpressionResult { ok: boolean; message: string; preview?: LayerExpressionPreview; }

const MAX_EXPRESSION_LENGTH: number = 4096;
const MAX_TOKENS: number = 512;
const MAX_SELECTORS: number = 32;
const MAX_PARENTHESES_DEPTH: number = 64;
const MAX_SOURCE_SHAPES: number = 100000;
const MAX_REGION_POLYGONS: number = 40000;
const MAX_NATIVE_INPUT_POINTS: number = 20000;
const MAX_REGION_POINTS: number = 400000;
const MAX_WORK_POINTS: number = 4000000;
const MAX_DOCUMENT_SHAPES: number = 1000000;
const MAX_DOCUMENT_POINTS: number = 4000000;
const MAX_ABS_GRID_COORDINATE: number = 1e14;
const MAX_OUTPUT_PROVENANCE_BYTES: number = 16 * 1024 * 1024;

interface ExpressionToken { kind: 'source' | 'operator' | 'left' | 'right'; text: string; selector?: LayerSelector; }
interface SourceCollection {
  ok: boolean; message: string; sourceIds: number[]; ignoredNonAreaIds: number[];
  provenance: LayerExpressionSource[]; regions: Map<string, number[][]>; fingerprint: string;
  pathSourceCount: number; roundCapErrorNm: number;
  sourceGeometry: Shape[]; sourceOccurrenceCount: number; visitedNodes: number; referenceIds: number[];
  occurrences: LayerExpressionSourceOccurrence[];
}
interface PersistedExpressionSource { selector: string; objectCount: number; }
interface PersistedExpressionDefinition { cellId: number; ids: number[]; }
interface PersistedExpressionProvenance {
  expression: string; gridNm: number; scope: string; sourceCellId: number;
  sourceObjectCount: number; sources: PersistedExpressionSource[];
  pathSourceCount: number; roundCapErrorNm: number;
  hierarchyDepth: number; sourceOccurrenceCount: number; referenceObjectCount: number;
  propertiesPolicy: string;
  sourceDefinitions: PersistedExpressionDefinition[];
}

function utf8Length(value: string): number {
  let bytes: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 128) bytes++; else if (code < 2048) bytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length &&
      value.charCodeAt(i + 1) >= 0xDC00 && value.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
    else bytes += 3;
  }
  return bytes;
}

function operatorName(text: string): LayerRegionOp | undefined {
  if (text === '|' || text === '+' || text === 'union' || text === 'or') return 'union';
  if (text === '-' || text === 'difference' || text === 'subtract' || text === 'diff') return 'difference';
  if (text === '&' || text === 'intersection' || text === 'intersect' || text === 'and') return 'intersection';
  if (text === '^' || text === 'xor') return 'xor';
  return undefined;
}

/** Explicit purpose selectors avoid accidentally treating L68/D20 as all of layer 68. */
class ExpressionParser {
  private tokens: ExpressionToken[] = [];
  private index: number = 0;
  private selectors: LayerSelector[] = [];
  private instructions: LayerExpressionInstruction[] = [];
  private error: string = '';

  parse(expression: string): LayerExpressionParseResult {
    if (typeof expression !== 'string' || expression.trim().length === 0 || expression.length > MAX_EXPRESSION_LENGTH) {
      return { ok: false, message: '表达式不能为空，且不能超过 4096 个字符', selectors: [], instructions: [] };
    }
    let offset: number = 0;
    while (offset < expression.length) {
      const remaining: string = expression.slice(offset);
      const spaces: RegExpMatchArray | null = remaining.match(/^\s+/);
      if (spaces !== null) { offset += spaces[0].length; continue; }
      const source: RegExpMatchArray | null = remaining.match(/^[lL]?(\d+|\*)\s*\/\s*[dD]?(\d+|\*)/);
      if (source !== null) {
        const layer: number | null = source[1] === '*' ? null : Number(source[1]);
        const datatype: number | null = source[2] === '*' ? null : Number(source[2]);
        if ((layer !== null && (!Number.isInteger(layer) || layer < 0 || layer > 32767)) ||
          (datatype !== null && (!Number.isInteger(datatype) || datatype < 0 || datatype > 32767))) {
          return { ok: false, message: '源 layer/datatype 必须为 0–32767；通配必须显式写 *', selectors: [], instructions: [] };
        }
        const key: string = `${layer === null ? '*' : layer}/${datatype === null ? '*' : datatype}`;
        this.tokens.push({ kind: 'source', text: source[0], selector: { layer: layer, datatype: datatype, key: key } });
        offset += source[0].length;
      } else {
        const symbol: string = remaining[0];
        if (symbol === '(' || symbol === ')') {
          this.tokens.push({ kind: symbol === '(' ? 'left' : 'right', text: symbol }); offset++;
        } else if ('|+-&^'.indexOf(symbol) >= 0) {
          this.tokens.push({ kind: 'operator', text: symbol }); offset++;
        } else {
          const word: RegExpMatchArray | null = remaining.match(/^(union|or|difference|subtract|diff|intersection|intersect|and|xor)\b/i);
          if (word === null) return { ok: false, message: `第 ${offset + 1} 字符无效；源层请写 68/20 或显式 68/*`, selectors: [], instructions: [] };
          this.tokens.push({ kind: 'operator', text: word[0].toLowerCase() }); offset += word[0].length;
        }
      }
      if (this.tokens.length > MAX_TOKENS) return { ok: false, message: '表达式超过 512 个语法项的预算', selectors: [], instructions: [] };
    }
    this.parseUnion(0);
    if (this.error.length === 0 && this.index !== this.tokens.length) this.error = '源层之间需要运算符，括号必须成对';
    return { ok: this.error.length === 0, message: this.error, selectors: this.selectors, instructions: this.instructions };
  }

  // Highest to lowest: intersection, difference, xor, union. Equal operators associate left to right.
  private parseUnion(depth: number): void {
    this.parseXor(depth);
    while (this.error.length === 0 && this.hasOperator('union')) {
      this.index++; this.parseXor(depth); this.instructions.push({ kind: 'operation', selectorKey: '', op: 'union' });
    }
  }
  private parseXor(depth: number): void {
    this.parseDifference(depth);
    while (this.error.length === 0 && this.hasOperator('xor')) {
      this.index++; this.parseDifference(depth); this.instructions.push({ kind: 'operation', selectorKey: '', op: 'xor' });
    }
  }
  private parseDifference(depth: number): void {
    this.parseIntersection(depth);
    while (this.error.length === 0 && this.hasOperator('difference')) {
      this.index++; this.parseIntersection(depth); this.instructions.push({ kind: 'operation', selectorKey: '', op: 'difference' });
    }
  }
  private parseIntersection(depth: number): void {
    this.parsePrimary(depth);
    while (this.error.length === 0 && this.hasOperator('intersection')) {
      this.index++; this.parsePrimary(depth); this.instructions.push({ kind: 'operation', selectorKey: '', op: 'intersection' });
    }
  }
  private hasOperator(op: LayerRegionOp): boolean {
    const token: ExpressionToken | undefined = this.tokens[this.index];
    return token !== undefined && token.kind === 'operator' && operatorName(token.text) === op;
  }
  private parsePrimary(depth: number): void {
    if (this.error.length > 0) return;
    const token: ExpressionToken | undefined = this.tokens[this.index];
    if (token === undefined) { this.error = '运算符后缺少源层或括号表达式'; return; }
    if (token.kind === 'left') {
      if (depth >= MAX_PARENTHESES_DEPTH) { this.error = '括号嵌套超过 64 层预算'; return; }
      this.index++; this.parseUnion(depth + 1);
      if (this.error.length > 0) return;
      if (this.tokens[this.index]?.kind !== 'right') { this.error = '缺少右括号'; return; }
      this.index++; return;
    }
    if (token.kind !== 'source' || token.selector === undefined) { this.error = '需要完整的 layer/datatype 源层'; return; }
    const selector: LayerSelector = token.selector;
    if (!this.selectors.some((item: LayerSelector): boolean => item.key === selector.key)) {
      if (this.selectors.length >= MAX_SELECTORS) { this.error = '表达式最多使用 32 个不同源层选择器'; return; }
      this.selectors.push(selector);
    }
    this.instructions.push({ kind: 'source', selectorKey: selector.key }); this.index++;
  }
}

export function parseLayerExpression(expression: string): LayerExpressionParseResult { return new ExpressionParser().parse(expression); }

function matches(shape: Shape, selector: LayerSelector): boolean {
  return (selector.layer === null || shape.layerNumber === selector.layer) &&
    (selector.datatype === null || shape.datatype === selector.datatype);
}

function polygonOf(shape: Shape): number[] {
  if (shape.type === ShapeType.RECT) {
    if (shape.points.length < 2) throw new Error(`矩形 #${shape.id} 缺少坐标`);
    const bounds = getShapeBounds(shape);
    return [bounds.minX, bounds.minY, bounds.maxX, bounds.minY, bounds.maxX, bounds.maxY, bounds.minX, bounds.maxY];
  }
  const points: Point[] = shape.points;
  let length: number = points.length;
  if (length > 3 && points[0].x === points[length - 1].x && points[0].y === points[length - 1].y) length--;
  const polygon: number[] = [];
  for (let i: number = 0; i < length; i++) polygon.push(points[i].x, points[i].y);
  return polygon;
}

function polygonArea(polygon: number[]): number {
  let sum: number = 0; let correction: number = 0;
  const x: number = polygon[0]; const y: number = polygon[1];
  for (let i: number = 0; i < polygon.length; i += 2) {
    const next: number = (i + 2) % polygon.length;
    const term: number = (polygon[i] - x) * (polygon[next + 1] - y) - (polygon[next] - x) * (polygon[i + 1] - y);
    const adjusted: number = term - correction; const combined: number = sum + adjusted;
    correction = (combined - sum) - adjusted; sum = combined;
  }
  return Math.abs(sum) / 2;
}

function checkRegion(polygons: number[][], gridNm: number, requireGrid: boolean): number {
  if (!Array.isArray(polygons) || polygons.length > MAX_REGION_POLYGONS) throw new Error('区域超过 40000 个多边形预算');
  let points: number = 0;
  for (const polygon of polygons) {
    if (!Array.isArray(polygon) || polygon.length < 6 || polygon.length % 2 !== 0) throw new Error('区域含不完整的多边形');
    points += polygon.length / 2;
    if (points > MAX_REGION_POINTS) throw new Error('区域超过 400000 个顶点预算');
    for (const value of polygon) {
      const scaled: number = value / gridNm;
      if (!Number.isFinite(value) || !Number.isFinite(scaled) || Math.abs(scaled) > MAX_ABS_GRID_COORDINATE) throw new Error('坐标或 DBU 比例超过安全范围');
      if (requireGrid && Math.abs(scaled - Math.round(scaled)) > 1e-6) throw new Error('区域内核返回了不在声明 DBU 网格上的坐标');
    }
    if (!Number.isFinite(polygonArea(polygon)) || polygonArea(polygon) <= 0) throw new Error('区域含零面积或无效轮廓');
  }
  return points;
}

function collectSources(selectors: LayerSelector[], cellId: number, gridNm: number, keepSources: boolean,
  depth: number, structure?: EditStructureState, adapter?: LayerRegionAdapter, collectGeometry: boolean = true,
  isCurrent?: () => boolean): SourceCollection {
  const regions: Map<string, number[][]> = new Map<string, number[][]>();
  const provenance: LayerExpressionSource[] = selectors.map((selector: LayerSelector): LayerExpressionSource => {
    regions.set(selector.key, []); return { selector: selector.key, sourceIds: [], ignoredNonAreaIds: [] };
  });
  const sourceIds: number[] = []; const ignoredNonAreaIds: number[] = []; const sourceGeometry: Shape[] = [];
  const occurrences: LayerExpressionSourceOccurrence[] = [];
  const seenIds: Set<number> = new Set<number>(); const ignoredIds: Set<number> = new Set<number>(); let sourcePoints: number = 0;
  let pathSourceCount: number = 0; let roundCapErrorNm: number = 0;
  const hierarchy = collectLayerExpressionHierarchy(editService.getShapes(), editService.getTopCellId(), cellId,
    depth, selectors, structure?.cellNames);
  try {
    if (!hierarchy.ok) throw new Error(hierarchy.message);
    for (const occurrence of hierarchy.occurrences) {
      if (isCurrent !== undefined && !isCurrent()) throw new Error('预览已取消');
      const shape: Shape = occurrence.shape;
      const selected: LayerSelector[] = selectors.filter((selector: LayerSelector): boolean => matches(shape, selector));
      if (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON && shape.type !== ShapeType.PATH) {
        if (!ignoredIds.has(shape.id)) {
          ignoredIds.add(shape.id); ignoredNonAreaIds.push(shape.id);
          for (const selector of selected) provenance.find((source: LayerExpressionSource): boolean => source.selector === selector.key)?.ignoredNonAreaIds.push(shape.id);
        }
        continue;
      }
      occurrences.push({ sourceId: shape.id, sourceCellId: occurrence.sourceCellId, instancePath: occurrence.instancePath });
      if (occurrences.length > MAX_SOURCE_SHAPES) throw new Error('源图形超过 100000 个对象预算');
      if (!keepSources && !editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error('待替换的源层已锁定；可保留原图输出到可编辑层');
      let polygons: number[][] = [];
      if (shape.type === ShapeType.PATH) {
        pathSourceCount++;
        if (collectGeometry) {
          if (adapter?.expressionPath === undefined) throw new Error(`源 PATH #${shape.id} 缺少轮廓计算功能，请先用多边形重绘所需轮廓后再处理；原图保留`);
          const copied: Shape = cloneShapeModel(shape, true) as Shape;
          // Transform the spine before painting/quantization. Absolute WIDTH
          // remains physical; signed type-4 extensions follow the instance MAG.
          const m = occurrence.transform;
          copied.points = shape.points.map((p: Point): Point => ({ x: m.a * p.x + m.b * p.y + m.tx, y: m.c * p.x + m.d * p.y + m.ty }));
          copied.pathWidth = (shape.pathWidth ?? 0) * (shape.pathWidthAbsolute === true ? 1 : occurrence.worldScale);
          copied.pathBeginExtension = (shape.pathBeginExtension ?? 0) * occurrence.worldScale;
          copied.pathEndExtension = (shape.pathEndExtension ?? 0) * occurrence.worldScale;
          if (!Number.isFinite(copied.pathWidth) || !Number.isFinite(copied.pathBeginExtension) || !Number.isFinite(copied.pathEndExtension)) throw new Error('PATH 宽度或端帽变换超过安全范围');
          const region: LayerRegionResult = adapter.expressionPath(copied, gridNm, 1);
          if (isCurrent !== undefined && !isCurrent()) throw new Error('预览已取消');
          if (!region.ok) throw new Error(region.message.length > 0 ? region.message : `源 PATH #${shape.id} 区域转换失败`);
          polygons = region.polygons;
          if (polygons.length === 0) throw new Error(`源 PATH #${shape.id} 未产生有效面积；原图保留`);
          sourcePoints += checkRegion(polygons, gridNm, true);
          if (region.roundCapErrorNm !== undefined) {
            if (!Number.isFinite(region.roundCapErrorNm) || region.roundCapErrorNm < 0) throw new Error('PATH 区域适配器返回无效圆端误差');
            roundCapErrorNm = Math.max(roundCapErrorNm, region.roundCapErrorNm);
          }
        }
      } else if (collectGeometry) {
        const local: number[] = polygonOf(shape); const world: number[] = []; const m = occurrence.transform;
        for (let i: number = 0; i < local.length; i += 2) world.push(m.a * local[i] + m.b * local[i + 1] + m.tx, m.c * local[i] + m.d * local[i + 1] + m.ty);
        polygons = [world]; sourcePoints += checkRegion(polygons, gridNm, false);
      }
      if (sourcePoints > MAX_NATIVE_INPUT_POINTS) throw new Error('源图形超过 20000 个原生输入顶点预算');
      if (collectGeometry) {
        for (const polygon of polygons) {
          const points: Point[] = []; for (let i: number = 0; i < polygon.length; i += 2) points.push({ x: polygon[i], y: polygon[i + 1] });
          sourceGeometry.push({ id: sourceGeometry.length + 1, type: ShapeType.POLYGON, layerNumber: shape.layerNumber,
            datatype: shape.datatype, ownerCellId: cellId, points: points, selected: false });
        }
      }
      const first: boolean = !seenIds.has(shape.id);
      if (first) { seenIds.add(shape.id); sourceIds.push(shape.id); }
      for (const selector of selected) {
        const region: number[][] | undefined = regions.get(selector.key); if (region !== undefined) region.push(...polygons);
        if (first) provenance.find((source: LayerExpressionSource): boolean => source.selector === selector.key)?.sourceIds.push(shape.id);
      }
    }
    for (const region of regions.values()) checkRegion(region, gridNm, false);
    return { ok: true, message: '', sourceIds: sourceIds, ignoredNonAreaIds: ignoredNonAreaIds, provenance: provenance, regions: regions,
      fingerprint: hierarchy.fingerprint, pathSourceCount: pathSourceCount, roundCapErrorNm: roundCapErrorNm,
      sourceGeometry: sourceGeometry, sourceOccurrenceCount: occurrences.length, visitedNodes: hierarchy.visitedNodes,
      referenceIds: hierarchy.referenceIds, occurrences: occurrences };
  } catch (error) {
    return { ok: false, message: (error as Error).message, sourceIds: [], ignoredNonAreaIds: [], provenance: [], regions: regions,
      fingerprint: '', pathSourceCount: 0, roundCapErrorNm: 0, sourceGeometry: [], sourceOccurrenceCount: 0,
      visitedNodes: hierarchy.visitedNodes, referenceIds: [], occurrences: [] };
  }
}

/** Whole-layer evaluation is independent of visibility/selection. Recursive
 * operands are flattened into current Cell coordinates; definitions stay live. */
export class LayerExpressionService {
  private issuedPreviewFingerprint: string = '';
  private operationEpoch: number = 0;

  /** Conditional cancellation prevents an old dialog closing a newer preview. */
  cancel(preview?: LayerExpressionPreview): void {
    if (preview !== undefined && JSON.stringify(preview) !== this.issuedPreviewFingerprint) return;
    this.issuedPreviewFingerprint = ''; this.operationEpoch++;
  }

  prepare(inputOptions: LayerExpressionOptions, adapter: LayerRegionAdapter, structure?: EditStructureState): LayerExpressionResult {
    // Own caller parameters before any native callback can re-enter the UI.
    const options: LayerExpressionOptions = { expression: inputOptions.expression, outputLayer: inputOptions.outputLayer,
      outputDatatype: inputOptions.outputDatatype, keepSources: inputOptions.keepSources, gridNm: inputOptions.gridNm,
      documentIdentity: inputOptions.documentIdentity, hierarchyDepth: inputOptions.hierarchyDepth };
    this.cancel(); const epoch: number = this.operationEpoch;
    if (!Number.isInteger(options.hierarchyDepth) || options.hierarchyDepth < 0 || options.hierarchyDepth > 32) return { ok: false, message: '递归深度必须为 0–32 的整数；0 仅当前 Cell' };
    if (options.hierarchyDepth > 0 && options.keepSources !== true) return { ok: false, message: '递归运算必须保留源图形；不能删除子 Cell 的共享源对象' };
    if (options.hierarchyDepth > 0 && structure === undefined) return { ok: false, message: '递归运算缺少完整 Cell 结构上下文，请更新入口接线' };
    if (structure !== undefined && (structure.topCellId !== editService.getTopCellId() ||
      editService.getCurrentCellId() < 0 || editService.getCurrentCellId() >= structure.cellNames.length)) return { ok: false, message: 'Cell 结构上下文不一致，请重新预览' };
    if (typeof options.documentIdentity !== 'string' || options.documentIdentity.length === 0 || options.documentIdentity.length > 4096) return { ok: false, message: '缺少有效文档身份，无法建立预览' };
    if (!Number.isInteger(options.outputLayer) || options.outputLayer < 0 || options.outputLayer > 32767 ||
      !Number.isInteger(options.outputDatatype) || options.outputDatatype < 0 || options.outputDatatype > 32767) return { ok: false, message: '输出 layer/datatype 必须为 0–32767 的整数' };
    if (typeof options.keepSources !== 'boolean' || !Number.isFinite(options.gridNm) || options.gridNm <= 0) return { ok: false, message: '必须声明有效的正数 DBU 网格与保留原图选项' };
    if (!editService.canEditLayer(options.outputLayer, options.outputDatatype)) return { ok: false, message: '输出图层已锁定' };
    const parsed: LayerExpressionParseResult = parseLayerExpression(options.expression);
    if (!parsed.ok) return { ok: false, message: parsed.message };
    const revision: number = editService.getSessionRevision(); const cellId: number = editService.getCurrentCellId();
    const structureFingerprint: string = structure === undefined ? '' : JSON.stringify(structure);
    const sources: SourceCollection = collectSources(parsed.selectors, cellId, options.gridNm, options.keepSources,
      options.hierarchyDepth, structure, adapter, true, (): boolean => epoch === this.operationEpoch);
    if (!sources.ok) return { ok: false, message: sources.message };
    const merged: Map<string, number[][]> = new Map<string, number[][]>(); const stack: number[][][] = [];
    let workPoints: number = 0;
    const compute = (subject: number[][], clip: number[][], op: LayerRegionOp): number[][] => {
      if (epoch !== this.operationEpoch) throw new Error('预览已取消');
      const inputPoints: number = checkRegion(subject, options.gridNm, false) + checkRegion(clip, options.gridNm, false);
      if (inputPoints > MAX_NATIVE_INPUT_POINTS) throw new Error('单次区域运算超过 20000 个输入顶点预算');
      workPoints += inputPoints;
      if (workPoints > MAX_WORK_POINTS) throw new Error('表达式累计运算超过 4000000 个顶点预算');
      // Native adapters receive owned copies, so they cannot modify cached leaves or the live document.
      const result: LayerRegionResult = adapter.boolean(subject.map((polygon: number[]): number[] => polygon.slice()),
        clip.map((polygon: number[]): number[] => polygon.slice()), op, options.gridNm);
      if (epoch !== this.operationEpoch) throw new Error('预览已取消');
      if (!result.ok) throw new Error(result.message.length > 0 ? result.message : '区域内核计算失败');
      workPoints += checkRegion(result.polygons, options.gridNm, true);
      if (workPoints > MAX_WORK_POINTS) throw new Error('表达式累计结果超过 4000000 个顶点预算');
      return result.polygons.map((polygon: number[]): number[] => polygon.slice());
    };
    try {
      for (const instruction of parsed.instructions) {
        if (instruction.kind === 'source') {
          let region: number[][] | undefined = merged.get(instruction.selectorKey);
          if (region === undefined) {
            const raw: number[][] = sources.regions.get(instruction.selectorKey) ?? [];
            region = raw.length === 0 ? [] : compute(raw, [], 'union'); merged.set(instruction.selectorKey, region);
          }
          stack.push(region);
        } else {
          const right: number[][] | undefined = stack.pop(); const left: number[][] | undefined = stack.pop();
          if (right === undefined || left === undefined || instruction.op === undefined) throw new Error('表达式栈无效');
          stack.push(compute(left, right, instruction.op));
        }
      }
      if (stack.length !== 1) throw new Error('表达式未产生单一区域');
      if (epoch !== this.operationEpoch) throw new Error('预览已取消');
      if (revision !== editService.getSessionRevision() || cellId !== editService.getCurrentCellId()) throw new Error('文档在计算期间变化，请重新预览');
      const refreshed: SourceCollection = collectSources(parsed.selectors, cellId, options.gridNm, options.keepSources,
        options.hierarchyDepth, structure, undefined, false);
      if (!refreshed.ok || refreshed.fingerprint !== sources.fingerprint ||
        (structure !== undefined && JSON.stringify(structure) !== structureFingerprint)) throw new Error('源层级或结构在计算期间变化，请重新预览');
      const definitions: PersistedExpressionDefinition[] = []; const definitionIds: Set<number> = new Set<number>();
      for (const source of sources.occurrences) {
        if (definitionIds.has(source.sourceId)) continue;
        definitionIds.add(source.sourceId);
        let cell: PersistedExpressionDefinition | undefined = definitions.find((item: PersistedExpressionDefinition): boolean => item.cellId === source.sourceCellId);
        if (cell === undefined) { cell = { cellId: source.sourceCellId, ids: [] }; definitions.push(cell); }
        cell.ids.push(source.sourceId);
      }
      const provenanceData: PersistedExpressionProvenance = { expression: options.expression, gridNm: options.gridNm,
        scope: options.hierarchyDepth === 0 ? 'current-cell' : 'recursive-current-cell', sourceCellId: cellId, sourceObjectCount: sources.sourceIds.length,
        pathSourceCount: sources.pathSourceCount, roundCapErrorNm: sources.roundCapErrorNm,
        hierarchyDepth: options.hierarchyDepth, sourceOccurrenceCount: sources.sourceOccurrenceCount, referenceObjectCount: sources.referenceIds.length,
        propertiesPolicy: `${options.keepSources ? 'source-definitions-retained' : 'direct-area-sources-replaced'};derived-output-expression-provenance-only;TEXT-NODE-retained`,
        sourceDefinitions: definitions,
        sources: sources.provenance.map((source: LayerExpressionSource): PersistedExpressionSource => ({ selector: source.selector, objectCount: source.sourceIds.length })) };
      const provenanceValue: string = 'HONGTU_LAYER_EXPR_V1:' + JSON.stringify(provenanceData);
      const provenanceBytes: number = utf8Length(provenanceValue);
      if (provenanceBytes > 65530 && stack[0].length > 0) throw new Error('表达式来源记录超过 65530 字节 GDS 属性预算');
      if (provenanceBytes * stack[0].length > MAX_OUTPUT_PROVENANCE_BYTES) throw new Error('结果来源属性超过 16 MiB 总量预算');
      const outputs: Shape[] = []; let areaNm2: number = 0; let correction: number = 0;
      for (const polygon of stack[0]) {
        const points: Point[] = []; for (let i: number = 0; i < polygon.length; i += 2) points.push({ x: polygon[i], y: polygon[i + 1] });
        const adjusted: number = polygonArea(polygon) - correction; const sum: number = areaNm2 + adjusted;
        correction = (sum - areaNm2) - adjusted; areaNm2 = sum;
        outputs.push({ id: 0, type: ShapeType.POLYGON, layerNumber: options.outputLayer, datatype: options.outputDatatype,
          ownerCellId: cellId, points: points, selected: false,
          // Numeric GDS PROPATTR and a namespaced value are portable to both
          // native writers. A named OAS property is not a valid GDS property.
          properties: [{ attr: 126, dtype: 6, name: '', value: provenanceValue }] });
      }
      if (!Number.isFinite(areaNm2)) throw new Error('结果面积超过数值安全范围');
      const preview: LayerExpressionPreview = { generation: epoch, options: { expression: options.expression, outputLayer: options.outputLayer,
        outputDatatype: options.outputDatatype, keepSources: options.keepSources, gridNm: options.gridNm,
        documentIdentity: options.documentIdentity, hierarchyDepth: options.hierarchyDepth }, outputs: outputs,
        sourceIds: sources.sourceIds, ignoredNonAreaIds: sources.ignoredNonAreaIds, provenance: sources.provenance,
        revision: revision, cellId: cellId, sourceFingerprint: sources.fingerprint, areaNm2: areaNm2,
        pathSourceCount: sources.pathSourceCount, roundCapErrorNm: sources.roundCapErrorNm,
        sourceGeometry: sources.sourceGeometry, sourceOccurrenceCount: sources.sourceOccurrenceCount, visitedNodes: sources.visitedNodes,
        referenceIds: sources.referenceIds, occurrences: sources.occurrences, structureFingerprint: structureFingerprint };
      this.issuedPreviewFingerprint = JSON.stringify(preview);
      return { ok: true, message: `当前 Cell 全层预览 · 递归深度 ${options.hierarchyDepth}：${sources.sourceIds.length} 个源对象 / ${sources.sourceOccurrenceCount} 次放置 → ${outputs.length} 个多边形；DBU ${options.gridNm} nm${sources.pathSourceCount > 0 ? `；含 ${sources.pathSourceCount} 个真实宽度 PATH` : ''}${sources.roundCapErrorNm > 0 ? `；圆端近似最大误差 ≤ ${sources.roundCapErrorNm.toPrecision(4)} nm（含量化）` : ''}${sources.ignoredNonAreaIds.length > 0 ? `；${sources.ignoredNonAreaIds.length} 个无面积注释保留` : ''}`, preview: preview };
    } catch (error) { return { ok: false, message: `全层表达式失败：${(error as Error).message}，原图已保留` }; }
  }

  apply(preview: LayerExpressionPreview, structure: EditStructureState, documentIdentity: string): LayerExpressionResult {
    if (this.issuedPreviewFingerprint.length === 0 || JSON.stringify(preview) !== this.issuedPreviewFingerprint) return { ok: false, message: '预览已过期或被修改，请重新生成' };
    if (documentIdentity !== preview.options.documentIdentity || preview.revision !== editService.getSessionRevision() ||
      preview.cellId !== editService.getCurrentCellId()) return { ok: false, message: '文档或编辑范围已变化，请重新生成预览' };
    if (structure.topCellId !== editService.getTopCellId() || preview.cellId < 0 || preview.cellId >= structure.cellNames.length) return { ok: false, message: 'Cell 结构上下文不一致，请重新生成预览' };
    if (preview.structureFingerprint.length > 0 && JSON.stringify(structure) !== preview.structureFingerprint) return { ok: false, message: 'Cell 结构或语义属性已变化，请重新生成预览' };
    const parsed: LayerExpressionParseResult = parseLayerExpression(preview.options.expression);
    if (!parsed.ok) return { ok: false, message: parsed.message };
    // The issued preview seals computed regions. Apply rechecks all source
    // identities/metadata and locks without invoking an unavailable adapter or
    // recomputing a potentially different PATH outline.
    const sources: SourceCollection = collectSources(parsed.selectors, preview.cellId, preview.options.gridNm,
      preview.options.keepSources, preview.options.hierarchyDepth, structure, undefined, false);
    if (!sources.ok || sources.fingerprint !== preview.sourceFingerprint) return { ok: false, message: sources.ok ? '全层源图形已变化，请重新预览' : sources.message };
    if (!editService.canEditLayer(preview.options.outputLayer, preview.options.outputDatatype)) return { ok: false, message: '输出图层已锁定' };
    const removed: Set<number> = new Set<number>(preview.options.keepSources ? [] : preview.sourceIds);
    if (removed.size === 0 && preview.outputs.length === 0) {
      this.issuedPreviewFingerprint = '';
      return { ok: true, message: '结果为空；原图已保留，未改变文档、选区或撤销记录' };
    }
    const candidate: Shape[] = editService.getShapes().filter((shape: Shape): boolean => !removed.has(shape.id));
    if (candidate.length + preview.outputs.length > MAX_DOCUMENT_SHAPES) return { ok: false, message: '结果超过 1000000 个文档对象预算，原图已保留' };
    let points: number = 0;
    for (const shape of candidate) { points += shape.points.length; if (points > MAX_DOCUMENT_POINTS) return { ok: false, message: '文档超过 4000000 个顶点预算，原图已保留' }; }
    for (const output of preview.outputs) { points += output.points.length; if (points > MAX_DOCUMENT_POINTS) return { ok: false, message: '结果超过 4000000 个文档顶点预算，原图已保留' }; }
    let nextId: number = editService.getNextShapeId(); const ids: number[] = [];
    if (!Number.isSafeInteger(nextId) || nextId <= 0 || !Number.isSafeInteger(nextId + preview.outputs.length)) return { ok: false, message: '对象 ID 超过安全范围，原图已保留' };
    for (const output of preview.outputs) {
      const copy: Shape = { id: nextId++, type: ShapeType.POLYGON, layerNumber: output.layerNumber, datatype: output.datatype,
        ownerCellId: preview.cellId, points: output.points.map((point: Point): Point => ({ x: point.x, y: point.y })), selected: false,
        properties: normalizePropRecords(output.properties) };
      candidate.push(copy); ids.push(copy.id);
    }
    try {
      if (!editService.applyDocumentStructure(candidate, structure, structure, `全层表达式 ${preview.options.expression} → L${preview.options.outputLayer}/D${preview.options.outputDatatype} · ${ids.length} 个结果`, preview.options.hierarchyDepth > 0, preview.options.hierarchyDepth === 0 ? ids : undefined)) return { ok: false, message: '提交被拒绝，原图已保留' };
    } catch (error) {
      // EditService restores geometry, ID allocator, selection and history
      // before propagating a failing external structure callback.
      return { ok: false, message: `提交失败：${(error as Error).message}；原图已保留` };
    }
    this.issuedPreviewFingerprint = '';
    return { ok: true, message: `全层表达式已应用：${ids.length} 个对象，DBU ${preview.options.gridNm} nm，可一次撤销` };
  }
}
export const layerExpressionService: LayerExpressionService = new LayerExpressionService();
