/** Cell library maintenance, in physical nm. Preview candidates are privately
 * sealed and published through the editor's single structural transaction.
 * Licensed under GPLv3. */
import { Shape, ShapeType, Point, MAX_PROPS_PER_OWNER } from '../models/GdsiiData';
import { EditService, editService } from './EditService';
import type { EditStructureState, InstancePathStep, InstancePathTransform } from './EditService';
import { instanceTransformMat } from './HierarchyExpandService';
import type { Mat2D } from './HierarchyExpandService';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import { normalizeLayoutSemantics, remapCellSemantics, validateLayoutSemantics } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface CellMaintenanceBudget {
  maxCells?: number;
  maxShapes?: number;
  maxPoints?: number;
  maxPlacements?: number;
  maxDepth?: number;
}
export interface CellOriginRequest extends CellMaintenanceBudget {
  kind: 'origin';
  cellId: number;
  /** Location of the new origin in the old Cell coordinate system. */
  xNm: number;
  yNm: number;
  dbuNm: number;
}
export interface CellRelinkRequest extends CellMaintenanceBudget {
  kind: 'relink';
  targetCellId: number;
  /** Supply exactly one scope: these concrete references, or all old-cell references. */
  instanceIds?: number[];
  sourceCellId?: number;
  dbuNm: number;
}
export interface CellPruneRequest extends CellMaintenanceBudget {
  kind: 'prune';
  /** Explicit user roots. Top, current/navigation Cells and truly empty definitions
   * are always preserved in addition; no name heuristic decides user ownership. */
  rootCellIds: number[];
  preserveCellIds?: number[];
  dbuNm: number;
}
export type CellMaintenanceRequest = CellOriginRequest | CellRelinkRequest | CellPruneRequest;
export interface CellMaintenanceContext { documentIdentity: string; structure: EditStructureState; }
export interface CellOriginOffset { coordinateUnit: 'nm'; xNm: number; yNm: number; }
interface CellOriginWire { version: number; coordinateUnit: string; xNm: number; yNm: number; }
export const CELL_ORIGIN_PROPERTY_PREFIX: string = 'HONGTU_CELL_ORIGIN_V1:';
export interface CellMaintenancePreview {
  id: string;
  kind: 'origin' | 'relink' | 'prune';
  changedShapes: number;
  directReferences: number;
  placements: number;
  removedCellIds: number[];
  removedCellNames: string[];
  preservedEmptyCellIds: number[];
  offGridCoordinates: number;
  maxExportQuantizationNm: number;
  warnings: string[];
}
export interface CellMaintenanceResult { ok: boolean; message: string; preview?: CellMaintenancePreview; }
export interface CellMaintenancePlan {
  shapes: Shape[];
  structure: EditStructureState;
  summary: CellMaintenancePreview;
}
interface PendingMaintenance {
  id: string;
  documentIdentity: string;
  revision: number;
  fingerprint: string;
  structureFingerprint: string;
  candidateFingerprint: string;
  before: EditStructureState;
  plan: CellMaintenancePlan;
}
interface MaintenanceLimits { cells: number; shapes: number; points: number; placements: number; depth: number; }
interface GraphFrame { cell: number; edge: number; }

function copyShape(shape: Shape): Shape { return cloneShapeModel(shape, true) as Shape; }
function copyStructure(state: EditStructureState): EditStructureState { return cloneEditStructureModel(state, true) as EditStructureState; }
function fingerprint(shapes: Shape[]): string {
  return JSON.stringify(shapes.map((shape: Shape): Shape => { const copy: Shape = copyShape(shape); copy.selected = false; return copy; }));
}
function limit(value: number | undefined, maximum: number): number {
  const n: number = value ?? maximum;
  if (!Number.isSafeInteger(n) || n < 1 || n > maximum) throw new Error('库维护预算必须为范围内的正整数');
  return n;
}
function dimension(value: number | undefined): number {
  const n: number = value === undefined || value === 0 ? 1 : value;
  if (!Number.isInteger(n) || n < 1 || n > 32767) throw new Error('库中存在无效阵列维数');
  return n;
}
function coordinate(value: number): boolean { return Number.isFinite(value) && Math.abs(value) <= 1e14; }
/** Normalizing floating-point roundoff is permitted; quantizing a geometric
 * displacement is not. Both the new origin and compensated anchors must have
 * an exactly representable DBU coordinate before a preserving shift is offered. */
function exactGrid(value: number, dbuNm: number): number {
  const grid: number = value / dbuNm, rounded: number = Math.round(grid);
  const tolerance: number = Math.max(dbuNm * 1e-7, Math.abs(value) * Number.EPSILON * 16);
  if (!Number.isSafeInteger(rounded) || rounded < -2147483648 || rounded > 2147483647 ||
    Math.abs(rounded * dbuNm - value) > tolerance) throw new Error('原点或父实例补偿不在文档 DBU 格点或超出 GDS 坐标范围，不能保持保存后的世界几何；请选择可精确补偿的偏移');
  return rounded * dbuNm;
}
function properties(values: LayoutPropRecord[]): boolean {
  return Array.isArray(values) && values.length <= MAX_PROPS_PER_OWNER && values.every((p: LayoutPropRecord): boolean =>
    p !== null && p !== undefined && Number.isFinite(p.attr) && Number.isFinite(p.dtype) && typeof p.name === 'string' && typeof p.value === 'string');
}
/** The Cell frame survives PCell regeneration and GDS/workspace persistence.
 * Physical nm is independent of source/target DBU; importing at a different DBU
 * must not scale a stored physical offset for a second time. */
export function readCellOriginOffset(values: LayoutPropRecord[] | undefined): CellOriginOffset {
  let found: CellOriginOffset | undefined;
  for (const record of values ?? []) {
    if (typeof record.value !== 'string' || !record.value.startsWith(CELL_ORIGIN_PROPERTY_PREFIX)) continue;
    if (found !== undefined) throw new Error('Cell 原点记录重复，不能猜测当前坐标系');
    if (!Number.isInteger(record.attr) || record.attr < 0 || record.attr > 32767 || record.dtype !== 6 || typeof record.name !== 'string') throw new Error('Cell 原点属性编码无效');
    let parsed: CellOriginWire;
    try { parsed = JSON.parse(record.value.substring(CELL_ORIGIN_PROPERTY_PREFIX.length)) as CellOriginWire; }
    catch (_error) { throw new Error('Cell 原点记录不是完整 JSON'); }
    if (parsed === null || parsed.version !== 1 || parsed.coordinateUnit !== 'nm' || !coordinate(parsed.xNm) || !coordinate(parsed.yNm) ||
      Object.keys(parsed).length !== 4 || Object.keys(parsed).some((key: string): boolean => !['version', 'coordinateUnit', 'xNm', 'yNm'].includes(key))) throw new Error('Cell 原点版本、单位或偏移无效');
    found = { coordinateUnit: 'nm', xNm: parsed.xNm, yNm: parsed.yNm };
  }
  return found ?? { coordinateUnit: 'nm', xNm: 0, yNm: 0 };
}
function shiftedOriginProperties(values: LayoutPropRecord[], xNm: number, yNm: number, dbuNm: number): LayoutPropRecord[] {
  const old: CellOriginOffset = readCellOriginOffset(values);
  const updated: CellOriginWire = { version: 1, coordinateUnit: 'nm', xNm: exactGrid(old.xNm + xNm, dbuNm), yNm: exactGrid(old.yNm + yNm, dbuNm) };
  const result: LayoutPropRecord[] = cloneStructured(values) as LayoutPropRecord[];
  const index: number = result.findIndex((record: LayoutPropRecord): boolean => record.value.startsWith(CELL_ORIGIN_PROPERTY_PREFIX));
  const value: string = CELL_ORIGIN_PROPERTY_PREFIX + JSON.stringify(updated);
  if (index >= 0) { result[index].value = value; return result; }
  if (result.length >= MAX_PROPS_PER_OWNER) throw new Error('Cell 属性预算已满，无法完整保存原点坐标系');
  const used: Set<number> = new Set<number>(result.map((record: LayoutPropRecord): number => record.attr));
  let attr: number = 32767; while (attr > 0 && used.has(attr)) attr--;
  if (attr <= 0) throw new Error('没有可保存原点记录的独立属性编号');
  result.push({ attr: attr, dtype: 6, name: '', value: value });
  return result;
}
function cellId(value: number, state: EditStructureState): boolean {
  return Number.isInteger(value) && value >= 0 && value < state.cellNames.length;
}
function owner(shape: Shape, state: EditStructureState): number { return shape.ownerCellId ?? state.topCellId; }
function compose(a: InstancePathTransform, b: Mat2D): InstancePathTransform {
  return { a: a.a * b.a + a.b * b.c, b: a.a * b.b + a.b * b.d,
    c: a.c * b.a + a.d * b.c, d: a.c * b.b + a.d * b.d,
    tx: a.a * b.tx + a.b * b.ty + a.tx, ty: a.c * b.tx + a.d * b.ty + a.ty };
}
function graph(shapes: Shape[], state: EditStructureState, limits: MaintenanceLimits): number[][] {
  const edges: number[][] = state.cellNames.map((): number[] => []);
  for (const shape of shapes) if (shape.type === ShapeType.INSTANCE) edges[owner(shape, state)].push(shape.cellId ?? -1);
  const color: number[] = state.cellNames.map((): number => 0);
  for (let root: number = 0; root < edges.length; root++) {
    if (color[root] !== 0) continue;
    const stack: GraphFrame[] = [{ cell: root, edge: 0 }]; color[root] = 1;
    while (stack.length > 0) {
      if (stack.length > limits.depth) throw new Error('库层级超过深度预算');
      const frame: GraphFrame = stack[stack.length - 1];
      if (frame.edge >= edges[frame.cell].length) { color[frame.cell] = 2; stack.pop(); continue; }
      const next: number = edges[frame.cell][frame.edge++];
      if (!cellId(next, state)) throw new Error('库中存在缺失 Cell 定义的引用');
      if (color[next] === 1) throw new Error('Cell 引用循环，库维护已拒绝');
      if (color[next] === 0) { color[next] = 1; stack.push({ cell: next, edge: 0 }); }
    }
  }
  // Depth is longest DAG path, even when a child was first visited from a
  // shallower disconnected root. The color walk above alone cannot prove this.
  const parents: number[][] = edges.map((): number[] => []);
  const indegree: number[] = edges.map((values: number[]): number => values.length);
  for (let p: number = 0; p < edges.length; p++) for (const child of edges[p]) parents[child].push(p);
  const depth: number[] = edges.map((): number => 1);
  const queue: number[] = [];
  for (let i: number = 0; i < indegree.length; i++) if (indegree[i] === 0) queue.push(i);
  for (let at: number = 0; at < queue.length; at++) {
    const child: number = queue[at];
    if (depth[child] > limits.depth) throw new Error('库层级超过深度预算');
    for (const p of parents[child]) { depth[p] = Math.max(depth[p], depth[child] + 1); if (--indegree[p] === 0) queue.push(p); }
  }
  return edges;
}
function validate(shapes: Shape[], state: EditStructureState, request: CellMaintenanceRequest): MaintenanceLimits {
  const limits: MaintenanceLimits = { cells: limit(request.maxCells, 100000), shapes: limit(request.maxShapes, 1000000),
    points: limit(request.maxPoints, 4000000), placements: limit(request.maxPlacements, 5000000), depth: limit(request.maxDepth, 256) };
  if (!Array.isArray(state.cellNames) || state.cellNames.length === 0 || state.cellNames.length > limits.cells ||
    state.cellProperties.length !== state.cellNames.length || !cellId(state.topCellId, state) ||
    state.cellStack.length < 1 || state.cellStack[0] !== state.topCellId || state.cellStack.some((id: number): boolean => !cellId(id, state))) throw new Error('库定义或当前导航无效');
  const names: Set<string> = new Set<string>();
  for (const name of state.cellNames) {
    if (typeof name !== 'string' || name.length < 1 || name.length > 512 || /[\x00-\x1f]/.test(name) || names.has(name)) throw new Error('Cell 名称重复或无效');
    names.add(name);
  }
  if (!Number.isFinite(request.dbuNm) || request.dbuNm <= 0 || request.dbuNm > 1e6 ||
    !Number.isFinite(state.physicalUnits) || (state.physicalUnits ?? 0) <= 0 ||
    Math.abs(request.dbuNm - (state.physicalUnits ?? 0) * 1e9) > 1e-10 * Math.max(request.dbuNm, (state.physicalUnits ?? 0) * 1e9) ||
    (state.userUnits !== undefined && (!Number.isFinite(state.userUnits) || state.userUnits <= 0))) throw new Error('库维护 DBU 必须与当前文档物理单位一致');
  if (state.cellProperties.some((p: LayoutPropRecord[]): boolean => !properties(p)) ||
    (state.libProperties !== undefined && !properties(state.libProperties))) throw new Error('库或 Cell 属性无效，不能静默截断');
  for (const p of state.cellProperties) readCellOriginOffset(p);
  if (shapes.length > limits.shapes) throw new Error('库对象超过预算');
  const ids: Set<number> = new Set<number>(); let points: number = 0, placements: number = 0;
  for (const shape of shapes) {
    if (!Number.isSafeInteger(shape.id) || shape.id < 1 || ids.has(shape.id) || !cellId(owner(shape, state), state) ||
      !Array.isArray(shape.points) || shape.points.length < 1 || shape.points.some((p: Point): boolean => !coordinate(p.x) || !coordinate(p.y)) ||
      !Number.isInteger(shape.layerNumber) || !Number.isInteger(shape.datatype) || shape.layerNumber < 0 || shape.layerNumber > 32767 ||
      shape.datatype < 0 || shape.datatype > 32767 || (shape.properties !== undefined && !properties(shape.properties))) throw new Error('库对象 ID、归属、图层、坐标或属性无效');
    ids.add(shape.id); points += shape.points.length;
    if (points > limits.points) throw new Error('库顶点超过预算');
    if (shape.type === ShapeType.INSTANCE) {
      if (!cellId(shape.cellId ?? -1, state) || shape.points.length !== 1 || !Number.isFinite(shape.rotation ?? 0) ||
        !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 || ![0, 1, 2].includes(shape.mirror ?? 0)) throw new Error('实例定义或变换无效');
      const cols: number = dimension(shape.arrayCols), rows: number = dimension(shape.arrayRows);
      const vectors: number[] = [shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0];
      if (vectors.some((n: number): boolean => !coordinate(n)) ||
        !coordinate(shape.points[0].x + (cols - 1) * vectors[0] + (rows - 1) * vectors[2]) ||
        !coordinate(shape.points[0].y + (cols - 1) * vectors[1] + (rows - 1) * vectors[3])) throw new Error('实例阵列步长或范围无效');
      placements += cols * rows; if (!Number.isSafeInteger(placements) || placements > limits.placements) throw new Error('库实例阵列超过放置预算');
    } else if (shape.type === ShapeType.PATH) {
      if (shape.points.length < 2 || !Number.isFinite(shape.pathWidth) || (shape.pathWidth ?? 0) <= 0 ||
        ![0, 1, 2, 4].includes(shape.pathType ?? 0) || !coordinate(shape.pathBeginExtension ?? 0) || !coordinate(shape.pathEndExtension ?? 0)) throw new Error('库 PATH 无效');
    } else if (shape.type === ShapeType.RECT) {
      if (shape.points.length !== 2 || shape.points[0].x === shape.points[1].x || shape.points[0].y === shape.points[1].y) throw new Error('库矩形无效');
    } else if (shape.type === ShapeType.POLYGON) {
      if (shape.points.length < 3) throw new Error('库多边形无效');
    } else if (shape.type === ShapeType.TEXT) {
      if (shape.points.length !== 1 || typeof shape.text !== 'string' || !Number.isFinite(shape.rotation ?? 0) ||
        !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 || ![0, 1, 2].includes(shape.mirror ?? 0)) throw new Error('库文本无效');
    } else if (shape.type !== ShapeType.NODE) throw new Error('库对象类型无效');
  }
  graph(shapes, state, limits);
  const idsByShape: Map<number, Shape> = new Map<number, Shape>(); for (const shape of shapes) idsByShape.set(shape.id, shape);
  let parent: number = state.topCellId;
  let matrix: InstancePathTransform = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
  const path: InstancePathStep[] = state.navigationPath ?? [];
  if (path.length > limits.depth) throw new Error('导航层级超过预算');
  for (const step of path) {
    const ref: Shape | undefined = idsByShape.get(step.instanceId);
    if (ref === undefined || ref.type !== ShapeType.INSTANCE || owner(ref, state) !== parent || step.parentCellId !== parent ||
      step.cellId !== ref.cellId || !Number.isInteger(step.col) || !Number.isInteger(step.row) || step.col < 0 || step.row < 0 ||
      step.col >= dimension(ref.arrayCols) || step.row >= dimension(ref.arrayRows)) throw new Error('导航引用或阵列成员已失效');
    const local: Mat2D = instanceTransformMat(ref);
    local.tx += step.col * (ref.arrayColStepX ?? 0) + step.row * (ref.arrayRowStepX ?? 0);
    local.ty += step.col * (ref.arrayColStepY ?? 0) + step.row * (ref.arrayRowStepY ?? 0);
    matrix = compose(matrix, local);
    const actual: number[] = [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty];
    const supplied: number[] = [step.transform.a, step.transform.b, step.transform.c, step.transform.d, step.transform.tx, step.transform.ty];
    if (actual.some((n: number, i: number): boolean => !coordinate(n) || !coordinate(supplied[i]) ||
      Math.abs(n - supplied[i]) > 1e-9 * Math.max(1, Math.abs(n), Math.abs(supplied[i])))) throw new Error('导航矩阵已失效');
    parent = step.cellId;
  }
  if (path.length > 0 && (parent !== state.cellStack[state.cellStack.length - 1] || state.cellStack.length !== path.length + 1 ||
    path.some((step: InstancePathStep, i: number): boolean => state.cellStack[i + 1] !== step.cellId))) throw new Error('导航 Cell 栈与路径不符');
  return limits;
}
/** Navigation is reconstructed from concrete candidate references, never from
 * stale matrices. A relink on an active path returns to the original definition. */
function navigation(shapes: Shape[], state: EditStructureState, originalCurrent: number): void {
  const byId: Map<number, Shape> = new Map<number, Shape>(); for (const s of shapes) byId.set(s.id, s);
  let combined: InstancePathTransform = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
  let parent: number = state.topCellId;
  const path: InstancePathStep[] = [];
  for (const step of state.navigationPath ?? []) {
    const shape: Shape | undefined = byId.get(step.instanceId);
    if (shape === undefined || shape.type !== ShapeType.INSTANCE || owner(shape, state) !== parent || shape.cellId !== step.cellId ||
      step.parentCellId !== parent || !Number.isInteger(step.row) || !Number.isInteger(step.col) || step.row < 0 || step.col < 0 ||
      step.row >= dimension(shape.arrayRows) || step.col >= dimension(shape.arrayCols)) {
      state.cellStack = originalCurrent === state.topCellId ? [state.topCellId] : [state.topCellId, originalCurrent]; state.navigationPath = []; return;
    }
    const local: Mat2D = instanceTransformMat(shape);
    local.tx += step.col * (shape.arrayColStepX ?? 0) + step.row * (shape.arrayRowStepX ?? 0);
    local.ty += step.col * (shape.arrayColStepY ?? 0) + step.row * (shape.arrayRowStepY ?? 0);
    combined = compose(combined, local);
    if (![combined.a, combined.b, combined.c, combined.d, combined.tx, combined.ty].every(coordinate)) throw new Error('导航变换超出安全范围');
    path.push({ parentCellId: parent, cellId: step.cellId, instanceId: shape.id, row: step.row, col: step.col, transform: combined }); parent = step.cellId;
  }
  if (path.length > 0 && parent !== originalCurrent) throw new Error('当前导航路径与 Cell 不符');
  state.navigationPath = path;
}
function quantization(shapes: Shape[], dbuNm: number, summary: CellMaintenancePreview): void {
  for (const shape of shapes) for (const point of shape.points) for (const n of [point.x, point.y]) {
    const written: number = Math.round(n / dbuNm) * dbuNm, error: number = Math.abs(written - n);
    if (error > 1e-10 * Math.max(1, Math.abs(n), dbuNm)) { summary.offGridCoordinates++; summary.maxExportQuantizationNm = Math.max(summary.maxExportQuantizationNm, error); }
  }
  if (summary.offGridCoordinates > 0) summary.warnings.push(`候选中 ${summary.offGridCoordinates} 个坐标分量不在 DBU 格点；保存量化误差最多 ${summary.maxExportQuantizationNm} nm，变换后的世界误差还受父实例 MAG 影响`);
}

export class CellMaintenanceService {
  private static nextServiceId: number = 0;
  private serviceId: number;
  private generation: number = 0;
  private pending: PendingMaintenance | null = null;
  private edit: EditService;
  constructor(edit: EditService = editService) { this.edit = edit; this.serviceId = ++CellMaintenanceService.nextServiceId; }
  cancel(previewId?: string): void { if (previewId === undefined || this.pending?.id === previewId) this.pending = null; }
  private contextError(context: CellMaintenanceContext): string {
    if (typeof context.documentIdentity !== 'string' || context.documentIdentity.length < 1 || context.documentIdentity.length > 4096 ||
      /[\x00-\x1f]/.test(context.documentIdentity)) return '缺少有效文档身份';
    if (context.structure.topCellId !== this.edit.getTopCellId() || JSON.stringify(context.structure.cellStack) !== JSON.stringify(this.edit.getCurrentCellStack()) ||
      JSON.stringify(context.structure.navigationPath ?? []) !== JSON.stringify(this.edit.getNavigationPath())) return 'Cell 导航已变化，请重新预览';
    return '';
  }
  /** Pure planner, useful for independent world-space and export verification. */
  createPlan(source: Shape[], structure: EditStructureState, request: CellMaintenanceRequest): CellMaintenancePlan {
    const limits: MaintenanceLimits = validate(source, structure, request);
    let shapes: Shape[] = source.map(copyShape);
    const after: EditStructureState = copyStructure(structure);
    normalizeLayoutSemantics(after, after.cellNames.length);
    const current: number = structure.cellStack[structure.cellStack.length - 1];
    const summary: CellMaintenancePreview = { id: '', kind: request.kind, changedShapes: 0, directReferences: 0, placements: 0,
      removedCellIds: [], removedCellNames: [], preservedEmptyCellIds: [], offGridCoordinates: 0, maxExportQuantizationNm: 0, warnings: [] };
    if (request.kind === 'origin') {
      if (!cellId(request.cellId, structure) || !coordinate(request.xNm) || !coordinate(request.yNm) ||
        (request.xNm === 0 && request.yNm === 0)) throw new Error('请选择有效 Cell 和非零原点偏移');
      const shiftX: number = exactGrid(request.xNm, request.dbuNm), shiftY: number = exactGrid(request.yNm, request.dbuNm);
      for (const port of after.ports ?? []) if (port.ownerCellId === request.cellId) {
        port.centerNm.x = exactGrid(port.centerNm.x - shiftX, request.dbuNm);
        port.centerNm.y = exactGrid(port.centerNm.y - shiftY, request.dbuNm);
      }
      after.cellProperties[request.cellId] = shiftedOriginProperties(after.cellProperties[request.cellId], shiftX, shiftY, request.dbuNm);
      for (const shape of shapes) {
        let changed: boolean = false;
        if (owner(shape, after) === request.cellId) {
          shape.points = shape.points.map((point: Point): Point => ({ x: point.x - shiftX, y: point.y - shiftY }));
          changed = true;
        }
        if (shape.type === ShapeType.INSTANCE && shape.cellId === request.cellId) {
          const m: Mat2D = instanceTransformMat(shape);
          const origin: Point = shape.points[0];
          shape.points = [{
            x: exactGrid(origin.x + m.a * shiftX + m.b * shiftY, request.dbuNm),
            y: exactGrid(origin.y + m.c * shiftX + m.d * shiftY, request.dbuNm)
          }];
          summary.directReferences++; summary.placements += dimension(shape.arrayCols) * dimension(shape.arrayRows); changed = true;
        }
        if (changed) summary.changedShapes++;
      }
      summary.warnings.push('所选 Cell 的本地定义坐标改变；全部现有父引用已补偿，AREF 步长和实例属性保留');
      summary.warnings.push('累计原点偏移已写入独立 Cell 属性；PCell 重新生成必须沿用该坐标系，参数和技术身份保持');
      if (request.cellId === structure.topCellId || summary.directReferences === 0) summary.warnings.push('该 Cell 的独立顶层视图坐标随新原点平移；没有父引用可以补偿该独立视图');
    } else if (request.kind === 'relink') {
      if (!cellId(request.targetCellId, structure) || ((request.instanceIds !== undefined) === (request.sourceCellId !== undefined))) throw new Error('重链接须明确选择实例列表或旧 Cell 全库范围之一');
      const chosen: Set<number> = new Set<number>();
      if (request.instanceIds !== undefined) {
        if (request.instanceIds.length === 0 || request.instanceIds.length > limits.shapes) throw new Error('请选择至少一个实例');
        for (const id of request.instanceIds) { if (!Number.isSafeInteger(id) || id < 1 || chosen.has(id)) throw new Error('实例列表含重复或无效 ID'); chosen.add(id); }
      } else {
        if (!cellId(request.sourceCellId ?? -1, structure) || request.sourceCellId === request.targetCellId) throw new Error('旧 Cell 与目标 Cell 须有效且不同');
        for (const shape of shapes) if (shape.type === ShapeType.INSTANCE && shape.cellId === request.sourceCellId) chosen.add(shape.id);
      }
      for (const shape of shapes) if (chosen.has(shape.id)) {
        if (shape.type !== ShapeType.INSTANCE || shape.cellId === request.targetCellId) throw new Error('所选对象须为引用其它 Cell 的实例');
        shape.cellId = request.targetCellId; shape.cellName = after.cellNames[request.targetCellId];
        summary.changedShapes++; summary.directReferences++; summary.placements += dimension(shape.arrayCols) * dimension(shape.arrayRows); chosen.delete(shape.id);
      }
      if (chosen.size > 0 || summary.changedShapes === 0) throw new Error('部分实例不存在或旧 Cell 没有引用');
      summary.warnings.push('重链接会改变这些实例的世界几何；placement、MAG、镜像、AREF 和实例属性保留，原 Cell 定义保留');
    } else if (request.kind === 'prune') {
      if (!Array.isArray(request.rootCellIds) || request.rootCellIds.length === 0 || request.rootCellIds.length > limits.cells ||
        (request.preserveCellIds !== undefined && !Array.isArray(request.preserveCellIds))) throw new Error('清理须显式指定至少一个根 Cell');
      const roots: Set<number> = new Set<number>();
      for (const id of request.rootCellIds.concat(request.preserveCellIds ?? [])) { if (!cellId(id, structure)) throw new Error('保留根或 Cell 无效'); roots.add(id); }
      roots.add(after.topCellId); for (const id of after.cellStack) roots.add(id);
      const counts: number[] = after.cellNames.map((): number => 0);
      for (const shape of shapes) counts[owner(shape, after)]++;
      for (let id: number = 0; id < counts.length; id++) if (counts[id] === 0) { roots.add(id); summary.preservedEmptyCellIds.push(id); }
      const edges: number[][] = graph(shapes, after, limits), reachable: Set<number> = new Set<number>();
      const queue: number[] = Array.from(roots);
      for (let at: number = 0; at < queue.length; at++) { const id: number = queue[at]; if (reachable.has(id)) continue; reachable.add(id); for (const child of edges[id]) if (!reachable.has(child)) queue.push(child); }
      const mapping: number[] = [];
      for (let old: number = 0; old < after.cellNames.length; old++) {
        mapping.push(reachable.has(old) ? old - summary.removedCellIds.length : -1);
        if (!reachable.has(old)) { summary.removedCellIds.push(old); summary.removedCellNames.push(after.cellNames[old]); }
      }
      if (summary.removedCellIds.length === 0) throw new Error('没有可清理的不可达非空 Cell；所有空 Cell 均保留');
      shapes = shapes.filter((shape: Shape): boolean => { const remove: boolean = mapping[owner(shape, after)] < 0; if (remove) summary.changedShapes++; return !remove; });
      for (const shape of shapes) {
        if (shape.ownerCellId !== undefined) shape.ownerCellId = mapping[shape.ownerCellId];
        if (shape.type === ShapeType.INSTANCE) { const next: number = mapping[shape.cellId ?? -1]; if (next < 0) throw new Error('清理会产生悬空引用'); shape.cellId = next; }
      }
      remapCellSemantics(after, mapping);
      after.cellNames = after.cellNames.filter((name: string, id: number): boolean => reachable.has(id));
      after.cellProperties = after.cellProperties.filter((p: LayoutPropRecord[], id: number): boolean => reachable.has(id));
      after.topCellId = mapping[after.topCellId]; after.cellStack = after.cellStack.map((id: number): number => mapping[id]);
      after.navigationPath = (after.navigationPath ?? []).map((step: InstancePathStep): InstancePathStep => ({
        parentCellId: mapping[step.parentCellId], cellId: mapping[step.cellId], instanceId: step.instanceId, row: step.row, col: step.col, transform: step.transform }));
      for (const shape of shapes) if (shape.type === ShapeType.INSTANCE) shape.cellName = after.cellNames[shape.cellId ?? -1];
      summary.warnings.push('仅删除预览列出的不可达非空定义及其对象；主 Top、当前导航、显式根、共享依赖和全部空 Cell 保留');
      navigation(shapes, after, mapping[current]);
    } else throw new Error('库维护操作无效');
    if (request.kind !== 'prune') navigation(shapes, after, current);
    validate(shapes, after, request);
    validateLayoutSemantics(after, after.cellNames.length);
    // Reindexing is a real object metadata change even when world geometry is
    // unchanged. Preview counts cover it rather than reporting only deletions.
    const originalById: Map<number, Shape> = new Map<number, Shape>(); for (const shape of source) originalById.set(shape.id, shape);
    summary.changedShapes = 0;
    for (const shape of shapes) { const previous: Shape | undefined = originalById.get(shape.id);
      if (previous === undefined || JSON.stringify(previous) !== JSON.stringify(shape)) summary.changedShapes++;
      originalById.delete(shape.id);
    }
    summary.changedShapes += originalById.size;
    quantization(shapes, request.dbuNm, summary);
    return { shapes: shapes, structure: after, summary: summary };
  }
  prepare(context: CellMaintenanceContext, request: CellMaintenanceRequest): CellMaintenanceResult {
    this.pending = null;
    try {
      const error: string = this.contextError(context); if (error.length > 0) return { ok: false, message: error };
      const revision: number = this.edit.getSessionRevision(), geometry: string = fingerprint(this.edit.getShapes());
      const state: string = JSON.stringify(context.structure), before: EditStructureState = copyStructure(context.structure);
      // Validate the original request before cloning: JSON would turn NaN into null.
      const plan: CellMaintenancePlan = this.createPlan(this.edit.getShapes(), before, request);
      this.checkPortChanges(before, plan.structure);
      if (revision !== this.edit.getSessionRevision() || fingerprint(this.edit.getShapes()) !== geometry ||
        JSON.stringify(context.structure) !== state || this.contextError(context).length > 0) return { ok: false, message: '文档在库维护规划期间变化，请重新预览' };
      const old: Map<number, Shape> = new Map<number, Shape>(); for (const shape of this.edit.getShapes()) old.set(shape.id, shape);
      for (const shape of plan.shapes) { const previous: Shape | undefined = old.get(shape.id); if (previous === undefined ||
        (JSON.stringify(previous) !== JSON.stringify(shape) && (!this.edit.canEditLayer(previous.layerNumber, previous.datatype) || !this.edit.canEditLayer(shape.layerNumber, shape.datatype)))) return { ok: false, message: '库维护涉及锁定图层，原图已保留' }; old.delete(shape.id); }
      for (const shape of Array.from(old.values())) if (!this.edit.canEditLayer(shape.layerNumber, shape.datatype)) return { ok: false, message: '清理涉及锁定图层，原图已保留' };
      if (!Number.isSafeInteger(this.generation + 1)) return { ok: false, message: '库维护会话计数超过安全范围' };
      const id: string = `cell-maintenance-${this.serviceId}-${++this.generation}`; plan.summary.id = id;
      this.pending = { id: id, documentIdentity: context.documentIdentity, revision: revision, fingerprint: geometry,
        structureFingerprint: state, candidateFingerprint: JSON.stringify(plan), before: before, plan: plan };
      return { ok: true, message: '库维护预览已生成，原图尚未改变', preview: cloneStructured(plan.summary) as CellMaintenancePreview };
    } catch (error) { return { ok: false, message: `库维护预览失败：${String(error)}，原图已保留` }; }
  }
  /** Owned copies for an optional actual-geometry preview; never the commit plan. */
  getPreviewShapes(previewId: string): Shape[] {
    const p: PendingMaintenance | null = this.pending;
    if (p === null || p.id !== previewId || p.revision !== this.edit.getSessionRevision() || fingerprint(this.edit.getShapes()) !== p.fingerprint) return [];
    return p.plan.shapes.map(copyShape);
  }
  getPreviewStructure(previewId: string): EditStructureState | undefined {
    const p: PendingMaintenance | null = this.pending;
    if (p === null || p.id !== previewId || p.revision !== this.edit.getSessionRevision() || fingerprint(this.edit.getShapes()) !== p.fingerprint) return undefined;
    return copyStructure(p.plan.structure);
  }
  private checkPortChanges(before: EditStructureState, after: EditStructureState): void {
    if (!this.edit.canEditStructurePorts(before, after)) throw new Error('库维护涉及锁定端口图层');
  }
  apply(previewId: string, context: CellMaintenanceContext): CellMaintenanceResult {
    const p: PendingMaintenance | null = this.pending;
    if (p === null || p.id !== previewId) return { ok: false, message: '库维护预览已取消、过期或不属本会话' };
    try {
      if (context.documentIdentity !== p.documentIdentity || this.contextError(context).length > 0 || this.edit.getSessionRevision() !== p.revision ||
        fingerprint(this.edit.getShapes()) !== p.fingerprint || JSON.stringify(context.structure) !== p.structureFingerprint || JSON.stringify(p.plan) !== p.candidateFingerprint) {
        this.pending = null; return { ok: false, message: '文档、导航或库维护预览已变化，请重新生成' };
      }
      const originals: Map<number, Shape> = new Map<number, Shape>(); for (const shape of this.edit.getShapes()) originals.set(shape.id, shape);
      this.checkPortChanges(p.before, p.plan.structure);
      const candidate: Shape[] = p.plan.shapes.map((shape: Shape): Shape => { const copy: Shape = copyShape(shape); copy.selected = originals.get(shape.id)?.selected ?? false; return copy; });
      // Consume before publication: a restore listener cannot recursively apply
      // this same preview. Failure requires a new preview after exact rollback.
      this.pending = null;
      const labels: string[] = ['调整 Cell 原点', '重链接 Cell 实例', '清理不可达 Cell'];
      const index: number = ['origin', 'relink', 'prune'].indexOf(p.plan.summary.kind);
      if (!this.edit.applyDocumentStructure(candidate, p.before, p.plan.structure, `${labels[index]} · ${p.plan.summary.changedShapes} 个对象`)) return { ok: false, message: '库维护提交被图层锁或编辑状态拒绝，原图已保留' };
      return { ok: true, message: `${labels[index]}已完成，可一次撤销`, preview: cloneStructured(p.plan.summary) as CellMaintenancePreview };
    } catch (error) { return { ok: false, message: `库维护未提交：${String(error)}` }; }
  }
}
export const cellMaintenanceService: CellMaintenanceService = new CellMaintenanceService();
