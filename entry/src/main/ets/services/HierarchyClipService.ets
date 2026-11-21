/** Hierarchy-preserving rectangular Clip. Coordinates stay in physical nm.
 * The source library is retained; only partial placements acquire independent
 * Cell variants. The adapter must clip real filled geometry and fracture holes.
 * Licensed under GPLv3.
 */
import { Shape, ShapeType, Point, ShapeBounds, normalizePropRecords, MAX_PROPS_PER_OWNER } from '../models/GdsiiData';
import type { EditStructureState } from './EditService';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import { instanceTransformMat, Mat2D } from './HierarchyExpandService';
import { getPathGeometryBounds } from './PathBoundsService';
import { strictRectangleCorners } from './RectangleGeometryService';
import type { PathBoundsTransform } from './PathBoundsService';
import { normalizeLayoutSemantics, appendCellSemantics, validateLayoutSemantics } from '../models/LayoutPort';
import type { LayoutPort } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface HierarchyClipGeometryResult {
  ok: boolean;
  message: string;
  unchanged: boolean;
  polygons: Point[][];
}
/** A partial PATH may be refused if the adapter cannot produce its exact outline.
 * worldScale is required for negative/absolute GDS WIDTH semantics. */
export type HierarchyClipAdapter = (shape: Shape, clipPolygon: Point[], dbuNm: number,
  worldScale: number) => HierarchyClipGeometryResult;
export interface HierarchyClipOptions {
  sourceCellId: number;
  outputCellName: string;
  bounds: ShapeBounds;
  dbuNm: number;
  /** TEXT is included by its anchor; NODE is included only if all its points fit. */
  textPolicy?: 'anchor' | 'omit';
  nodePolicy?: 'all-points' | 'omit';
  maxCells?: number;
  maxShapes?: number;
  maxPoints?: number;
  maxPlacements?: number;
  maxDepth?: number;
  /** Session callers supply the editor's monotonic ID allocator, including IDs
   * that no longer occur in live geometry but remain in undo/redo history. */
  nextShapeId?: number;
}
export interface HierarchyClipPlan {
  shapes: Shape[];
  structure: EditStructureState;
  outputCellId: number;
  addedCells: number;
  addedShapes: number;
  keptReferences: number;
  clippedObjects: number;
  addedPorts: number;
  droppedPorts: number;
  visitedPlacements: number;
}
export interface HierarchyClipResult { ok: boolean; message: string; plan?: HierarchyClipPlan; }
interface ClippedCell { id: number; unchanged: boolean; empty: boolean; }
interface ClipLimits { cells: number; shapes: number; points: number; placements: number; depth: number; }
/** New Clip definitions are static results. Preserve the generator's complete
 * source recipe as lineage, without the active prefix consumed by PCell readers.
 * Unchanged shared source definitions keep their original generator identity. */
export const CLIP_PCELL_SOURCE_PROPERTY_PREFIX: string = 'HONGTU_PCELL_CLIP_SOURCE_V1:';
const ACTIVE_PCELL_PROPERTY_PREFIX: string = 'HONGTU_PCELL_V1:';

function clipSourceProperties(properties: LayoutPropRecord[] | undefined): LayoutPropRecord[] | undefined {
  const normalized: LayoutPropRecord[] | undefined = normalizePropRecords(properties);
  if (normalized === undefined) return undefined;
  return normalized.map((record: LayoutPropRecord): LayoutPropRecord => {
    if (!record.value.startsWith(ACTIVE_PCELL_PROPERTY_PREFIX)) return record;
    const value: string = CLIP_PCELL_SOURCE_PROPERTY_PREFIX + record.value.substring(ACTIVE_PCELL_PROPERTY_PREFIX.length);
    // A provenance conversion must not turn a saveable record into a truncated
    // GDS property. The writer permits at most 65530 bytes plus even padding.
    if (value.length > 65530 || value.includes('\u0000')) throw new Error('Clip PCell 来源记录超过 GDS 属性长度，原图已保留');
    return { attr: record.attr, dtype: record.dtype, name: record.name, value: value };
  });
}

function compose(left: Mat2D, right: Mat2D): Mat2D {
  return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
    c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx,
    ty: left.c * right.tx + left.d * right.ty + left.ty };
}
function transform(point: Point, m: Mat2D): Point {
  return { x: m.a * point.x + m.b * point.y + m.tx, y: m.c * point.x + m.d * point.y + m.ty };
}
function inverse(m: Mat2D): Mat2D {
  const det: number = m.a * m.d - m.b * m.c;
  if (!Number.isFinite(det) || det === 0) throw new Error('实例变换不可逆，原图已保留');
  const a: number = m.d / det, b: number = -m.b / det, c: number = -m.c / det, d: number = m.a / det;
  return { a, b, c, d, tx: -a * m.tx - b * m.ty, ty: -c * m.tx - d * m.ty };
}
function copiedShape(shape: Shape): Shape { return cloneShapeModel(shape, true) as Shape; }
function validProperties(properties: LayoutPropRecord[]): boolean {
  return properties.length <= MAX_PROPS_PER_OWNER && properties.every((record: LayoutPropRecord): boolean =>
    record !== null && record !== undefined && typeof record.attr === 'number' && Number.isFinite(record.attr) &&
    typeof record.dtype === 'number' && Number.isFinite(record.dtype) && typeof record.name === 'string' && typeof record.value === 'string');
}
function contained(point: Point, box: ShapeBounds): boolean {
  return point.x >= box.minX && point.x <= box.maxX && point.y >= box.minY && point.y <= box.maxY;
}
function validPoint(point: Point): boolean {
  return Number.isFinite(point.x) && Number.isFinite(point.y) && Math.abs(point.x) <= 1e14 && Math.abs(point.y) <= 1e14;
}
function pointsBounds(points: Point[]): ShapeBounds {
  let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
  for (const p of points) { minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
  return { minX, minY, maxX, maxY };
}
function limit(value: number | undefined, fallback: number): number {
  const result: number = value ?? fallback;
  if (!Number.isInteger(result) || result < 1 || result > fallback) throw new Error('Clip 预算必须为有效的正整数');
  return result;
}
function dimension(value: number | undefined): number {
  const result: number = value === undefined || value === 0 ? 1 : value;
  if (!Number.isInteger(result) || result < 1 || result > 32767) throw new Error('实例阵列维数无效');
  return result;
}
function hasArea(points: Point[]): boolean {
  if (points.length < 3) return false;
  const origin: Point = points[0];
  let twiceArea: number = 0;
  for (let i: number = 0; i < points.length; i++) {
    const a: Point = points[i], b: Point = points[(i + 1) % points.length];
    twiceArea += (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y);
  }
  return Number.isFinite(twiceArea) && twiceArea !== 0;
}

export class HierarchyClipService {
  /** Pure candidate creation. Apply the exact returned geometry + structure in
   * one EditService.applyDocumentStructure transaction after rechecking context. */
  createPlan(shapes: Shape[], structure: EditStructureState, options: HierarchyClipOptions,
    adapter: HierarchyClipAdapter): HierarchyClipResult {
    try {
      const limits: ClipLimits = { cells: limit(options.maxCells, 100000), shapes: limit(options.maxShapes, 1000000),
        points: limit(options.maxPoints, 4000000), placements: limit(options.maxPlacements, 100000), depth: limit(options.maxDepth, 256) };
      const box: ShapeBounds = options.bounds;
      if (![box.minX, box.minY, box.maxX, box.maxY].every((n: number): boolean => Number.isFinite(n) && Math.abs(n) <= 1e14) ||
        !(box.maxX > box.minX) || !(box.maxY > box.minY) || !Number.isFinite(options.dbuNm) || options.dbuNm <= 0 || options.dbuNm > 1e6) throw new Error('裁剪矩形或 DBU 无效');
      const name: string = options.outputCellName.trim();
      if (name.length === 0 || name.length > 512 || /[\x00-\x1f]/.test(name) || structure.cellNames.indexOf(name) >= 0) throw new Error('输出 Cell 名称须唯一，长度 1–512 且不含控制字符');
      const sourceNames: Set<string> = new Set<string>();
      for (const sourceName of structure.cellNames) {
        if (typeof sourceName !== 'string' || sourceName.length === 0 || sourceName.length > 512 || /[\x00-\x1f]/.test(sourceName) || sourceNames.has(sourceName)) throw new Error('源 Cell 名称重复或无效');
        sourceNames.add(sourceName);
      }
      if (!Number.isInteger(options.sourceCellId) || options.sourceCellId < 0 || options.sourceCellId >= structure.cellNames.length ||
        structure.cellProperties.length !== structure.cellNames.length || structure.cellNames.length >= limits.cells) throw new Error('源 Cell 或结构无效，或超过 Cell 预算');
      if (!Number.isInteger(structure.topCellId) || structure.topCellId < 0 || structure.topCellId >= structure.cellNames.length ||
        structure.cellStack.length < 1 || structure.cellStack[0] !== structure.topCellId || structure.cellStack.some((cell: number): boolean =>
          !Number.isInteger(cell) || cell < 0 || cell >= structure.cellNames.length)) throw new Error('源顶层 Cell 或导航结构无效');
      if ((structure.userUnits !== undefined && (!Number.isFinite(structure.userUnits) || structure.userUnits <= 0)) ||
        (structure.physicalUnits !== undefined && (!Number.isFinite(structure.physicalUnits) || structure.physicalUnits <= 0))) throw new Error('源物理单位无效');
      for (const properties of structure.cellProperties) {
        if (!validProperties(properties)) throw new Error('源 Cell 属性无效，裁剪不能截断属性');
      }
      if (structure.libProperties !== undefined && !validProperties(structure.libProperties)) throw new Error('源库属性无效');
      if (options.textPolicy !== undefined && options.textPolicy !== 'anchor' && options.textPolicy !== 'omit') throw new Error('TEXT 策略无效');
      if (options.nodePolicy !== undefined && options.nodePolicy !== 'all-points' && options.nodePolicy !== 'omit') throw new Error('NODE 策略无效');
      const byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
      const ids: Set<number> = new Set<number>();
      let nextId: number = 1, pointCount: number = 0;
      if (shapes.length > limits.shapes) throw new Error('源文档超过 Clip 对象预算');
      for (const shape of shapes) {
        const owner: number = shape.ownerCellId ?? structure.topCellId;
        if (!Number.isSafeInteger(shape.id) || shape.id < 1 || ids.has(shape.id) || !Number.isInteger(owner) || owner < 0 || owner >= structure.cellNames.length ||
          shape.points.some((p: Point): boolean => !validPoint(p)) || !Number.isInteger(shape.layerNumber) || !Number.isInteger(shape.datatype) ||
          shape.layerNumber < 0 || shape.layerNumber > 32767 || shape.datatype < 0 || shape.datatype > 32767) throw new Error('源图形 ID、归属、图层或坐标无效');
        if (shape.properties !== undefined && !validProperties(shape.properties)) throw new Error('源图形属性无效，裁剪不能截断属性');
        if (shape.type === ShapeType.INSTANCE) {
          const child: number = shape.cellId ?? -1;
          if (!Number.isInteger(child) || child < 0 || child >= structure.cellNames.length || shape.points.length !== 1 ||
            !Number.isFinite(shape.rotation ?? 0) || !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 ||
            [0, 1, 2].indexOf(shape.mirror ?? 0) < 0 ||
            ![shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0].every((n: number): boolean => Number.isFinite(n))) throw new Error('源实例引用或变换无效');
          dimension(shape.arrayCols); dimension(shape.arrayRows);
        } else if (shape.type === ShapeType.PATH) {
          if (shape.points.length < 2 || ![0, 1, 2, 4].includes(shape.pathType ?? 0) ||
            !Number.isFinite(shape.pathWidth ?? 0) || (shape.pathWidth ?? 0) <= 0 ||
            !Number.isFinite(shape.pathBeginExtension ?? 0) || !Number.isFinite(shape.pathEndExtension ?? 0)) throw new Error('源 PATH 宽度、端型或扩展无效');
        } else if (shape.type === ShapeType.RECT) {
          strictRectangleCorners(shape.points);
        } else if (shape.type === ShapeType.POLYGON) {
          if (shape.points.length < 3 || !hasArea(shape.points)) throw new Error('源多边形轮廓无效');
        } else if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE) {
          if (shape.points.length === 0) throw new Error('源文字或 NODE 缺少坐标');
        } else throw new Error('源图形类型无效');
        ids.add(shape.id); nextId = Math.max(nextId, shape.id + 1); pointCount += shape.points.length;
        const local: Shape[] = byOwner.get(owner) ?? []; local.push(shape); byOwner.set(owner, local);
      }
      if (shapes.length > limits.shapes || pointCount > limits.points || !Number.isSafeInteger(nextId)) throw new Error('源文档超过 Clip 对象或顶点预算');
      if (options.nextShapeId !== undefined) {
        if (!Number.isSafeInteger(options.nextShapeId) || options.nextShapeId < nextId) throw new Error('Clip 对象 ID 分配器已过期或无效');
        nextId = options.nextShapeId;
      }
      const navigation = structure.navigationPath ?? [];
      if (navigation.length > 0) {
        if (navigation.length !== structure.cellStack.length - 1) throw new Error('源实例导航路径与 Cell 栈不一致');
        let placement: Mat2D = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
        for (let i: number = 0; i < navigation.length; i++) {
          const step = navigation[i];
          const instance: Shape | undefined = (byOwner.get(step.parentCellId) ?? []).find((shape: Shape): boolean => shape.id === step.instanceId);
          if (step.parentCellId !== structure.cellStack[i] || step.cellId !== structure.cellStack[i + 1] || instance === undefined ||
            instance.type !== ShapeType.INSTANCE || instance.cellId !== step.cellId || !Number.isInteger(step.row) || !Number.isInteger(step.col) ||
            step.row < 0 || step.col < 0 || step.row >= dimension(instance.arrayRows) || step.col >= dimension(instance.arrayCols)) throw new Error('源实例导航路径已失效');
          const member: Mat2D = instanceTransformMat(instance);
          member.tx += step.col * (instance.arrayColStepX ?? 0) + step.row * (instance.arrayRowStepX ?? 0);
          member.ty += step.col * (instance.arrayColStepY ?? 0) + step.row * (instance.arrayRowStepY ?? 0);
          placement = compose(placement, member);
          const actual: number[] = [step.transform.a, step.transform.b, step.transform.c, step.transform.d, step.transform.tx, step.transform.ty];
          const expected: number[] = [placement.a, placement.b, placement.c, placement.d, placement.tx, placement.ty];
          if (actual.some((value: number, index: number): boolean => !Number.isFinite(value) ||
            Math.abs(value - expected[index]) > Math.max(1, Math.abs(expected[index])) * 1e-12)) throw new Error('源实例导航变换与当前实例不一致');
        }
      }
      // Validate the whole retained library before spatial rejection. Invalid
      // unrelated definitions must not be carried into an otherwise valid plan.
      const validatedDepth: Map<number, number> = new Map<number, number>();
      const validateCell = (cell: number, ancestors: number[]): number => {
        if (ancestors.indexOf(cell) >= 0) throw new Error('源层级包含循环引用');
        if (ancestors.length >= limits.depth) throw new Error('层级超过 Clip 深度预算');
        const cachedDepth: number | undefined = validatedDepth.get(cell);
        if (cachedDepth !== undefined) {
          if (ancestors.length + cachedDepth > limits.depth) throw new Error('层级超过 Clip 深度预算');
          return cachedDepth;
        }
        let depth: number = 1;
        for (const shape of byOwner.get(cell) ?? []) {
          if (shape.type !== ShapeType.INSTANCE) continue;
          const child: number = shape.cellId ?? -1;
          depth = Math.max(depth, 1 + validateCell(child, ancestors.concat([cell])));
        }
        if (ancestors.length + depth > limits.depth) throw new Error('层级超过 Clip 深度预算');
        validatedDepth.set(cell, depth);
        return depth;
      };
      for (let cell: number = 0; cell < structure.cellNames.length; cell++) validateCell(cell, []);
      const after: EditStructureState = cloneEditStructureModel(structure, true) as EditStructureState;
      normalizeLayoutSemantics(after, after.cellNames.length);
      const additions: Shape[] = [];
      const worldClip: Point[] = [{ x: box.minX, y: box.minY }, { x: box.maxX, y: box.minY },
        { x: box.maxX, y: box.maxY }, { x: box.minX, y: box.maxY }];
      const cache: Map<string, ClippedCell> = new Map<string, ClippedCell>();
      let placements: number = 0, visits: number = 0, keptReferences: number = 0, clippedObjects: number = 0;
      let addedPorts: number = 0, droppedPorts: number = 0;
      const portsByOwner: Map<number, LayoutPort[]> = new Map<number, LayoutPort[]>();
      for (const port of after.ports ?? []) {
        const owned: LayoutPort[] = portsByOwner.get(port.ownerCellId) ?? [];
        owned.push(port); portsByOwner.set(port.ownerCellId, owned);
      }
      const apertureContained = (port: LayoutPort, matrix: Mat2D): boolean => {
        const radians: number = port.orientationDeg * Math.PI / 180;
        const half: number = port.widthNm * port.frameMagnification / 2;
        const dx: number = -Math.sin(radians) * half, dy: number = Math.cos(radians) * half;
        const ends: Point[] = [transform({ x: port.centerNm.x + dx, y: port.centerNm.y + dy }, matrix),
          transform({ x: port.centerNm.x - dx, y: port.centerNm.y - dy }, matrix)];
        return ends.every((point: Point): boolean => contained(point, box));
      };
      const appendCell = (source: number, local: Shape[], root: boolean, matrix: Mat2D): number => {
        if (after.cellNames.length >= limits.cells || shapes.length + additions.length + local.length > limits.shapes) throw new Error('Clip 结果超过 Cell 或对象预算，原图已保留');
        const cellId: number = after.cellNames.length;
        let cellName: string = root ? name : `${structure.cellNames[source].slice(0, 470)}_clip_${cellId}`;
        let suffix: number = 1;
        const baseName: string = cellName;
        while (after.cellNames.indexOf(cellName) >= 0 || (!root && cellName === name)) cellName = `${baseName.slice(0, 480)}_${suffix++}`;
        after.cellNames.push(cellName); after.cellProperties.push(clipSourceProperties(structure.cellProperties[source]) ?? []);
        const copiedPorts: Map<string, string> = appendCellSemantics(after, source, 'clip-static',
          (port: LayoutPort): boolean => apertureContained(port, matrix));
        addedPorts += copiedPorts.size;
        droppedPorts += (portsByOwner.get(source)?.length ?? 0) - copiedPorts.size;
        for (const original of local) {
          pointCount += original.points.length;
          if (pointCount > limits.points || !Number.isSafeInteger(nextId)) throw new Error('Clip 结果超过顶点或 ID 预算，原图已保留');
          const copy: Shape = copiedShape(original); copy.id = nextId++; copy.ownerCellId = cellId; copy.selected = false;
          // Detach every local object's active identity, including a fully kept
          // marker-bearing shape when another object/reference was omitted.
          copy.properties = clipSourceProperties(copy.properties); additions.push(copy);
        }
        return cellId;
      };
      const visitCell = (cell: number, matrix: Mat2D, ancestors: number[], root: boolean = false): ClippedCell => {
        if (ancestors.indexOf(cell) >= 0 || ancestors.length >= limits.depth) throw new Error('Clip 层级循环或超过深度预算');
        const localClip: Point[] = worldClip.map((p: Point): Point => transform(p, inverse(matrix)));
        if (localClip.some((p: Point): boolean => !validPoint(p))) throw new Error('局部裁剪坐标超出范围');
        const worldScale: number = Math.sqrt(Math.abs(matrix.a * matrix.d - matrix.b * matrix.c));
        const key: string = `${cell}:${JSON.stringify(localClip)}:${worldScale}`;
        const cached: ClippedCell | undefined = cache.get(key);
        if (!root && cached !== undefined) return cached;
        const result: Shape[] = [];
        const localPorts: LayoutPort[] = portsByOwner.get(cell) ?? [];
        const containedPorts: number = localPorts.filter((port: LayoutPort): boolean => apertureContained(port, matrix)).length;
        let unchanged: boolean = containedPorts === localPorts.length;
        for (const shape of byOwner.get(cell) ?? []) {
          if (++visits > limits.shapes) throw new Error('Clip 遍历超过对象预算');
          if (shape.type === ShapeType.INSTANCE) {
            const cols: number = dimension(shape.arrayCols), rows: number = dimension(shape.arrayRows);
            const members: ClippedCell[] = [];
            let allUnchanged: boolean = true;
            for (let row: number = 0; row < rows; row++) for (let col: number = 0; col < cols; col++) {
              if (++placements > limits.placements) throw new Error('Clip 阵列遍历超过实例预算');
              const member: Mat2D = instanceTransformMat(shape);
              member.tx += col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0);
              member.ty += col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0);
              const child: ClippedCell = visitCell(shape.cellId ?? -1, compose(matrix, member), ancestors.concat([cell]));
              members.push(child); allUnchanged = allUnchanged && child.unchanged && !child.empty;
            }
            if (allUnchanged) { result.push(shape); keptReferences++; continue; }
            unchanged = false;
            for (let row: number = 0; row < rows; row++) for (let col: number = 0; col < cols;) {
              const child: ClippedCell = members[row * cols + col];
              if (child.empty) { col++; continue; }
              let end: number = col + 1;
              while (end < cols && !members[row * cols + end].empty && members[row * cols + end].id === child.id) end++;
              const copy: Shape = copiedShape(shape);
              copy.cellId = child.id; copy.cellName = after.cellNames[child.id];
              copy.points = [{ x: shape.points[0].x + col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0),
                y: shape.points[0].y + col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0) }];
              copy.arrayCols = end - col > 1 ? end - col : 0; copy.arrayRows = end - col > 1 ? 1 : 0;
              if (!validPoint(copy.points[0])) throw new Error('Clip 阵列位置超出坐标范围');
              result.push(copy); if (child.unchanged) keptReferences++; col = end;
            }
            continue;
          }
          if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE) {
            const omit: boolean = shape.type === ShapeType.TEXT ? options.textPolicy === 'omit' : options.nodePolicy === 'omit';
            const included: boolean = !omit && shape.points.length > 0 && (shape.type === ShapeType.TEXT ?
              contained(transform(shape.points[0], matrix), box) : shape.points.every((p: Point): boolean => contained(transform(p, matrix), box)));
            if (included) result.push(shape); else unchanged = false;
            continue;
          }
          if (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON && shape.type !== ShapeType.PATH) throw new Error('Clip 遇到不支持的图形类型');
          if (shape.type === ShapeType.RECT) strictRectangleCorners(shape.points);
          if (shape.type === ShapeType.POLYGON && shape.points.length < 3) throw new Error('Clip 源轮廓不完整');
          if (shape.type === ShapeType.POLYGON && !hasArea(shape.points)) throw new Error('Clip 多边形无有效面积');
          if (shape.type === ShapeType.PATH && (![0, 1, 2, 4].includes(shape.pathType ?? 0) ||
            !Number.isFinite(shape.pathWidth ?? 0) || (shape.pathWidth ?? 0) <= 0)) throw new Error('Clip PATH 宽度或端型无效');
          let painted: ShapeBounds | undefined;
          if (shape.type === ShapeType.PATH) {
            const pathTransform: PathBoundsTransform = { a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d, tx: matrix.tx, ty: matrix.ty };
            painted = getPathGeometryBounds(shape, pathTransform);
          }
          else {
            const local: Point[] = shape.type === ShapeType.RECT ? strictRectangleCorners(shape.points) : shape.points;
            painted = pointsBounds(local.map((p: Point): Point => transform(p, matrix)));
          }
          if (painted === undefined) throw new Error('Clip PATH 无有效的填充轮廓');
          if (![painted.minX, painted.minY, painted.maxX, painted.maxY].every((n: number): boolean => Number.isFinite(n))) throw new Error('Clip 填充轮廓坐标无效');
          // Bounds only certify disjoint/full-contained cases. Partial geometry
          // always goes to the real region adapter, never a bbox replacement.
          if (painted.maxX < box.minX || painted.minX > box.maxX || painted.maxY < box.minY || painted.minY > box.maxY) { unchanged = false; continue; }
          if (painted.minX >= box.minX && painted.maxX <= box.maxX && painted.minY >= box.minY && painted.maxY <= box.maxY) { result.push(shape); continue; }
          const clipped: HierarchyClipGeometryResult = adapter(copiedShape(shape), localClip, options.dbuNm, worldScale);
          if (clipped === undefined || clipped === null || typeof clipped.ok !== 'boolean' ||
            typeof clipped.unchanged !== 'boolean' || typeof clipped.message !== 'string' || !Array.isArray(clipped.polygons)) throw new Error('区域裁剪返回格式无效');
          if (!clipped.ok) throw new Error(clipped.message || '区域裁剪失败，原图已保留');
          if (clipped.unchanged) { result.push(shape); continue; }
          unchanged = false; clippedObjects++;
          if (clipped.polygons.length > limits.shapes - shapes.length - additions.length - result.length) throw new Error('区域裁剪结果超过对象预算');
          let localOutputPoints: number = 0;
          for (const polygon of clipped.polygons) {
            localOutputPoints += polygon.length;
            if (localOutputPoints > limits.points - pointCount) throw new Error('区域裁剪结果超过顶点预算');
            if (polygon.length < 3 || polygon.some((p: Point): boolean => !validPoint(p)) || !hasArea(polygon)) throw new Error('区域裁剪返回了无效轮廓');
            result.push({ id: 0, type: ShapeType.POLYGON, ownerCellId: cell, layerNumber: shape.layerNumber,
              datatype: shape.datatype, selected: false, points: polygon.map((p: Point): Point => ({ x: p.x, y: p.y })), properties: normalizePropRecords(shape.properties) });
          }
        }
        const empty: boolean = result.length === 0 && containedPorts === 0;
        if (empty && !root && !unchanged) droppedPorts += localPorts.length;
        const outcome: ClippedCell = { id: unchanged && !root ? cell : !empty || root ? appendCell(cell, result, root, matrix) : -1,
          unchanged: unchanged, empty: empty };
        if (!root) cache.set(key, outcome);
        return outcome;
      };
      const output: ClippedCell = visitCell(options.sourceCellId, { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }, [], true);
      const plan: HierarchyClipPlan = { shapes: shapes.map((shape: Shape): Shape => copiedShape(shape)).concat(additions), structure: after, outputCellId: output.id,
        addedCells: after.cellNames.length - structure.cellNames.length, addedShapes: additions.length,
        keptReferences: keptReferences, clippedObjects: clippedObjects, visitedPlacements: placements,
        addedPorts: addedPorts, droppedPorts: droppedPorts };
      validateLayoutSemantics(after, after.cellNames.length);
      return { ok: true, message: `Clip 新建 ${plan.addedCells} 个 Cell、${plan.addedShapes} 个对象、${addedPorts} 个端口；片段排除 ${droppedPorts} 个孔径越界端口，源定义保留。端口须完整孔径包含，TEXT 按锚点，NODE 按完整点列处理`, plan: plan };
    } catch (error) { return { ok: false, message: String(error) }; }
  }
}
export const hierarchyClipService: HierarchyClipService = new HierarchyClipService();
