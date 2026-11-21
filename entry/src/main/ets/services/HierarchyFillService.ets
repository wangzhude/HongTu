/** Fixed-origin hierarchy-preserving Fill. All coordinates are physical nm.
 * A footprint is a declared rectangular reservation, never a substitute for the
 * actual fill-area region. Region holes/concavities are tested by the real region
 * difference engine. Source definitions, references and properties stay intact.
 * Licensed under GPLv3. */
import { Shape, ShapeType, Point, ShapeBounds, MAX_PROPS_PER_OWNER } from '../models/GdsiiData';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import type { EditStructureState } from './EditService';
import type { LayerRegionAdapter, LayerRegionResult } from './LayerExpressionService';
import { NativeLayerRegionAdapter } from './NativeLayerRegionAdapter';
import { instanceTransformMat, Mat2D } from './HierarchyExpandService';
import { getPathGeometryBounds } from './PathBoundsService';
import { strictRectangleCorners } from './RectangleGeometryService';
import type { PathBoundsTransform } from './PathBoundsService';
import { normalizeLayoutSemantics } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface HierarchyFillLayer { layerNumber: number; datatype: number; }
export interface HierarchyFillLimits {
  maxCandidates?: number; maxPlacements?: number; maxShapes?: number; maxPoints?: number; maxDepth?: number;
}
export interface HierarchyFillOptions extends HierarchyFillLimits {
  targetCellId: number; fillCellId: number; dbuNm: number;
  /** Filled contours; holes are represented by omitted/fractured material. */
  areaPolygons?: Point[][];
  /** Direct area objects in the target Cell; source IDs are ignored in avoidance. */
  areaShapeIds?: number[];
  footprint?: ShapeBounds;
  origin: Point; columnStep: Point; rowStep: Point;
  /** Rectangular safety space on all four footprint sides, in physical nm. */
  regionMarginNm: number; excludeSpacingNm: number;
  excludeMode: 'none' | 'all' | 'layers'; excludeLayers?: HierarchyFillLayer[];
  instanceLayer: number; instanceDatatype: number;
  instanceProperties?: LayoutPropRecord[];
  nextShapeId?: number;
}
export interface HierarchyFillFootprintResult {
  ok: boolean; message: string; footprint?: ShapeBounds; visitedPlacements?: number;
}
export interface HierarchyFillPlan {
  shapes: Shape[]; structure: EditStructureState; targetCellId: number; fillCellId: number;
  footprint: ShapeBounds; placedInstances: number; addedShapes: number; consideredCandidates: number;
  rejectedOutside: number; rejectedExcluded: number; rejectedOverlap: number;
  visitedPlacements: number; conservativeExclusionCount: number;
}
export interface HierarchyFillResult { ok: boolean; message: string; plan?: HierarchyFillPlan; }
interface FillBudgets { candidates: number; placements: number; shapes: number; points: number; depth: number; }
interface FillLibrary { owners: Map<number, Shape[]>; nextId: number; points: number; }
interface FillMember { row: number; col: number; x: number; y: number; }
interface FillTraversal { placements: number; visits: number; points: number; }
interface FillScanEdge { ax: number; ay: number; bx: number; by: number; key: string; }
interface FillCrossing { value: number; error: number; key: string; }
interface FillInterval { low: FillCrossing; high: FillCrossing; }

/** Continuous polygon-union/rectangle relation before integer-grid booleans.
 * Intersections of oblique boundaries can create sub-DBU slivers that disappear
 * in a grid subtraction. Sweep every arrangement slab and retain original
 * source contours, so those slivers can neither permit an outside tile nor hide
 * an obstacle. Numerical ambiguity rejects the plan rather than claiming fit. */
function continuousRelation(box: ShapeBounds, rings: number[][], covered: boolean, work: FillTraversal, limits: FillBudgets): boolean {
  const width: number = box.maxX - box.minX, height: number = box.maxY - box.minY;
  const edges: FillScanEdge[][] = [], all: FillScanEdge[] = [], critical: number[] = [0, width];
  for (const ring of rings) {
    const polygon: FillScanEdge[] = [];
    for (let index: number = 0; index < ring.length; index += 2) {
      const next: number = (index + 2) % ring.length;
      const ax: number = ring[index] - box.minX, ay: number = ring[index + 1] - box.minY,
        bx: number = ring[next] - box.minX, by: number = ring[next + 1] - box.minY;
      const first: string = `${ring[index]}/${ring[index + 1]}`, second: string = `${ring[next]}/${ring[next + 1]}`;
      const edge: FillScanEdge = { ax: ax, ay: ay, bx: bx, by: by, key: first < second ? `${first}:${second}` : `${second}:${first}` };
      polygon.push(edge);
      if (ax > 0 && ax < width) critical.push(ax);
      if (by !== ay) for (const y of [0, height]) {
        const fraction: number = (y - ay) / (by - ay), x: number = ax + fraction * (bx - ax);
        if (fraction > 0 && fraction < 1 && x > 0 && x < width) critical.push(x);
      }
      if (Math.max(ax, bx) >= 0 && Math.min(ax, bx) <= width && Math.max(ay, by) >= 0 && Math.min(ay, by) <= height) all.push(edge);
    }
    edges.push(polygon); work.points += polygon.length;
  }
  if (work.points > limits.points) throw new Error('Fill 连续区域审查超过工作顶点预算');
  for (let index: number = 0; index < all.length; index++) for (let other: number = index + 1; other < all.length; other++) {
    if (++work.points > limits.points) throw new Error('Fill 连续边界交点审查超过工作预算');
    const a: FillScanEdge = all[index], b: FillScanEdge = all[other];
    const dx: number = a.bx - a.ax, dy: number = a.by - a.ay, ex: number = b.bx - b.ax, ey: number = b.by - b.ay;
    const determinant: number = dx * ey - dy * ex;
    if (determinant === 0) continue;
    if (Math.abs(determinant) <= (Math.abs(dx * ey) + Math.abs(dy * ex)) * Number.EPSILON * 32) throw new Error('Fill 连续边界近共线，无法证明包含关系');
    const ox: number = b.ax - a.ax, oy: number = b.ay - a.ay;
    const fraction: number = (ox * ey - oy * ex) / determinant, second: number = (ox * dy - oy * dx) / determinant;
    const x: number = a.ax + fraction * dx, y: number = a.ay + fraction * dy;
    if (fraction > 0 && fraction < 1 && second > 0 && second < 1 && x > 0 && x < width && y >= 0 && y <= height) critical.push(x);
  }
  critical.sort((a: number, b: number): number => a - b);
  const unique: number[] = critical.filter((x: number, index: number): boolean => index === 0 || x !== critical[index - 1]);
  for (let slab: number = 1; slab < unique.length; slab++) {
    const x: number = unique[slab - 1] + (unique[slab] - unique[slab - 1]) / 2;
    if (!(x > unique[slab - 1] && x < unique[slab])) throw new Error('Fill 连续边界精度不足，无法证明窄缝');
    const intervals: FillInterval[] = [];
    for (const polygon of edges) {
      const crossings: FillCrossing[] = [];
      for (const edge of polygon) {
        if (++work.points > limits.points) throw new Error('Fill 连续剖面审查超过工作预算');
        if (!((edge.ax <= x && edge.bx > x) || (edge.bx <= x && edge.ax > x))) continue;
        const fraction: number = (x - edge.ax) / (edge.bx - edge.ax), displacement: number = fraction * (edge.by - edge.ay),
          value: number = edge.ay + displacement;
        const error: number = edge.by === edge.ay ? 0 : (Math.abs(edge.ay) + Math.abs(displacement) + Math.abs(value)) * Number.EPSILON * 32;
        crossings.push({ value: value, error: error, key: edge.key });
      }
      crossings.sort((a: FillCrossing, b: FillCrossing): number => a.value - b.value);
      if (crossings.length % 2 !== 0) throw new Error('Fill 连续区域剖面不完整');
      for (let index: number = 0; index < crossings.length; index += 2) intervals.push({ low: crossings[index], high: crossings[index + 1] });
    }
    if (!covered) {
      for (const interval of intervals) {
        const lower: number = Math.max(0, interval.low.value - interval.low.error), upper: number = Math.min(height, interval.high.value + interval.high.error);
        if (upper > lower) return false;
      }
      continue;
    }
    intervals.sort((a: FillInterval, b: FillInterval): number => a.low.value - b.low.value);
    let end: FillCrossing = { value: 0, error: 0, key: '' };
    for (const interval of intervals) {
      if (interval.high.value - interval.high.error < end.value - end.error) continue;
      const sameBoundary: boolean = interval.low.value === end.value && interval.low.key === end.key;
      if (interval.low.value + interval.low.error > end.value - end.error && !sameBoundary) return false;
      end = interval.high;
      if (end.value - end.error >= height) break;
    }
    if (end.value - end.error < height) return false;
  }
  return true;
}

function copyShape(shape: Shape): Shape { return cloneShapeModel(shape, true) as Shape; }
function numberLimit(value: number | undefined, maximum: number): number {
  const result: number = value ?? maximum;
  if (!Number.isInteger(result) || result < 1 || result > maximum) throw new Error('Fill 预算须为有效正整数');
  return result;
}
function budgets(options: HierarchyFillLimits): FillBudgets {
  return { candidates: numberLimit(options.maxCandidates, 100000), placements: numberLimit(options.maxPlacements, 100000),
    shapes: numberLimit(options.maxShapes, 1000000), points: numberLimit(options.maxPoints, 4000000), depth: numberLimit(options.maxDepth, 256) };
}
function dimension(value: number | undefined): number {
  const result: number = value === undefined || value === 0 ? 1 : value;
  if (!Number.isInteger(result) || result < 1 || result > 32767) throw new Error('Fill 源阵列维数无效');
  return result;
}
function validPoint(point: Point): boolean {
  return point !== undefined && point !== null && Number.isFinite(point.x) && Number.isFinite(point.y) &&
    Math.abs(point.x) <= 1e14 && Math.abs(point.y) <= 1e14;
}
function validLayer(layer: number, datatype: number): boolean {
  return Number.isInteger(layer) && layer >= 0 && layer <= 32767 && Number.isInteger(datatype) && datatype >= 0 && datatype <= 32767;
}
function validProperties(properties: LayoutPropRecord[] | undefined): boolean {
  return properties === undefined || (Array.isArray(properties) && properties.length <= MAX_PROPS_PER_OWNER &&
    properties.every((record: LayoutPropRecord): boolean => record !== null && record !== undefined &&
      Number.isInteger(record.attr) && record.attr >= 0 && record.attr <= 65535 && Number.isInteger(record.dtype) &&
      record.dtype >= 0 && record.dtype <= 7 && typeof record.name === 'string' && typeof record.value === 'string' &&
      record.name.length <= 8192 && record.value.length <= 16382));
}
function ringArea(ring: number[]): number {
  let sum: number = 0;
  for (let index: number = 0; index < ring.length; index += 2) {
    const next: number = (index + 2) % ring.length;
    sum += (ring[index] - ring[0]) * (ring[next + 1] - ring[1]) - (ring[next] - ring[0]) * (ring[index + 1] - ring[1]);
  }
  return sum / 2;
}
function rectRing(box: ShapeBounds): number[] {
  return [box.minX, box.minY, box.maxX, box.minY, box.maxX, box.maxY, box.minX, box.maxY];
}
function pointRing(points: Point[]): number[] {
  const ring: number[] = []; for (const point of points) ring.push(point.x, point.y); return ring;
}
function boundsOf(points: Point[]): ShapeBounds {
  let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
  for (const point of points) { minX = Math.min(minX, point.x); minY = Math.min(minY, point.y); maxX = Math.max(maxX, point.x); maxY = Math.max(maxY, point.y); }
  return { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
}
function validBounds(box: ShapeBounds): boolean {
  return [box.minX, box.minY, box.maxX, box.maxY].every((value: number): boolean => Number.isFinite(value) && Math.abs(value) <= 1e14) &&
    box.minX < box.maxX && box.minY < box.maxY;
}
function containsBounds(outer: ShapeBounds, inner: ShapeBounds): boolean {
  return inner.minX >= outer.minX && inner.minY >= outer.minY && inner.maxX <= outer.maxX && inner.maxY <= outer.maxY;
}
function overlap(a: ShapeBounds, b: ShapeBounds): boolean {
  return a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY;
}
function placed(box: ShapeBounds, point: Point, margin: number): ShapeBounds {
  return { minX: box.minX + point.x - margin, minY: box.minY + point.y - margin,
    maxX: box.maxX + point.x + margin, maxY: box.maxY + point.y + margin };
}
function composed(left: Mat2D, right: Mat2D): Mat2D {
  return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
    c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx, ty: left.c * right.tx + left.d * right.ty + left.ty };
}
function transformed(point: Point, matrix: Mat2D): Point {
  return { x: matrix.a * point.x + matrix.b * point.y + matrix.tx, y: matrix.c * point.x + matrix.d * point.y + matrix.ty };
}
function identity(): Mat2D { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }
function onGrid(value: number, grid: number): boolean {
  if (typeof value !== 'number') return false;
  const units: number = value / grid;
  return Number.isFinite(units) && Math.abs(units) <= 1e14 &&
    Math.abs(value - Math.round(units) * grid) <= Math.max(grid * 1e-8, Math.abs(value) * Number.EPSILON * 4);
}
function gridCeiling(value: number, grid: number): number { return Math.ceil(value / grid) * grid; }
function gridFloor(value: number, grid: number): number { return Math.floor(value / grid) * grid; }

export class HierarchyFillService {
  private validate(shapes: Shape[], structure: EditStructureState, limits: FillBudgets): FillLibrary {
    const semantic: EditStructureState = cloneEditStructureModel(structure, true) as EditStructureState;
    normalizeLayoutSemantics(semantic, structure.cellNames.length);
    if (!Array.isArray(structure.cellNames) || structure.cellNames.length < 1 || structure.cellNames.length > 100000 ||
      structure.cellProperties.length !== structure.cellNames.length || !Number.isInteger(structure.topCellId) || structure.topCellId < 0 ||
      structure.topCellId >= structure.cellNames.length || structure.cellStack.length < 1 || structure.cellStack[0] !== structure.topCellId ||
      structure.cellStack.some((cell: number): boolean => !Number.isInteger(cell) || cell < 0 || cell >= structure.cellNames.length)) throw new Error('Fill 源 Cell 库或导航无效');
    const names: Set<string> = new Set<string>();
    for (const name of structure.cellNames) {
      if (typeof name !== 'string' || name.length < 1 || name.length > 512 || /[\x00-\x1f]/.test(name) || names.has(name)) throw new Error('Fill 源 Cell 名称重复或无效');
      names.add(name);
    }
    if (!validProperties(structure.libProperties) || structure.cellProperties.some((properties: LayoutPropRecord[]): boolean => !validProperties(properties)) ||
      (structure.physicalUnits !== undefined && (!Number.isFinite(structure.physicalUnits) || structure.physicalUnits <= 0)) ||
      (structure.userUnits !== undefined && (!Number.isFinite(structure.userUnits) || structure.userUnits <= 0))) throw new Error('Fill 源单位或属性无效，不能截断属性');
    const owners: Map<number, Shape[]> = new Map<number, Shape[]>(), ids: Set<number> = new Set<number>();
    let nextId: number = 1, points: number = 0;
    if (shapes.length > limits.shapes) throw new Error('Fill 源对象超过预算');
    for (const shape of shapes) {
      const owner: number = shape.ownerCellId ?? structure.topCellId;
      if (!Number.isSafeInteger(shape.id) || shape.id < 1 || ids.has(shape.id) || !Number.isInteger(owner) || owner < 0 || owner >= structure.cellNames.length ||
        !validLayer(shape.layerNumber, shape.datatype) || !Array.isArray(shape.points) || shape.points.some((point: Point): boolean => !validPoint(point)) ||
        !validProperties(shape.properties)) throw new Error('Fill 源对象 ID、归属、坐标、图层或属性无效');
      if (shape.type === ShapeType.INSTANCE) {
        if (!Number.isInteger(shape.cellId) || (shape.cellId ?? -1) < 0 || (shape.cellId ?? -1) >= structure.cellNames.length || shape.points.length !== 1 ||
          !Number.isFinite(shape.rotation ?? 0) || !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 ||
          [0, 1, 2].indexOf(shape.mirror ?? 0) < 0 || ![shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0,
            shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0].every((value: number): boolean => Number.isFinite(value))) throw new Error('Fill 源实例引用或变换无效');
        dimension(shape.arrayCols); dimension(shape.arrayRows);
      } else if (shape.type === ShapeType.RECT) {
        strictRectangleCorners(shape.points);
      } else if (shape.type === ShapeType.POLYGON) {
        if (shape.points.length < 3 || !Number.isFinite(ringArea(pointRing(shape.points))) || ringArea(pointRing(shape.points)) === 0) throw new Error('Fill 源多边形无面积');
      } else if (shape.type === ShapeType.PATH) {
        if (shape.points.length < 2 || !Number.isFinite(shape.pathWidth) || (shape.pathWidth ?? 0) <= 0 || ![0, 1, 2, 4].includes(shape.pathType ?? 0) ||
          !Number.isFinite(shape.pathBeginExtension ?? 0) || !Number.isFinite(shape.pathEndExtension ?? 0)) throw new Error('Fill 源 PATH 无效');
      } else if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE) {
        if (shape.points.length < 1) throw new Error('Fill 源非面积对象无坐标');
      } else throw new Error('Fill 源图形类型无效');
      ids.add(shape.id); nextId = Math.max(nextId, shape.id + 1); points += shape.points.length;
      const cell: Shape[] = owners.get(owner) ?? []; cell.push(shape); owners.set(owner, cell);
    }
    if (points > limits.points || !Number.isSafeInteger(nextId)) throw new Error('Fill 源顶点或 ID 超过预算');
    const depths: Map<number, number> = new Map<number, number>();
    const visit = (cell: number, ancestors: number[]): number => {
      if (ancestors.indexOf(cell) >= 0) throw new Error('Fill 源库包含循环引用');
      if (ancestors.length >= limits.depth) throw new Error('Fill 源层级超过深度预算');
      const cached: number | undefined = depths.get(cell);
      if (cached !== undefined) { if (ancestors.length + cached > limits.depth) throw new Error('Fill 共享层级超过深度预算'); return cached; }
      let depth: number = 1;
      for (const shape of owners.get(cell) ?? []) if (shape.type === ShapeType.INSTANCE) depth = Math.max(depth, 1 + visit(shape.cellId ?? -1, ancestors.concat([cell])));
      if (ancestors.length + depth > limits.depth) throw new Error('Fill 源层级超过深度预算');
      depths.set(cell, depth); return depth;
    };
    for (let cell: number = 0; cell < structure.cellNames.length; cell++) visit(cell, []);
    return { owners: owners, nextId: nextId, points: points };
  }

  private walk(library: FillLibrary, cellId: number, limits: FillBudgets, traversal: FillTraversal,
    action: (shape: Shape, matrix: Mat2D) => void, forbiddenCell: number = -1, definitionGrid: number = 0): void {
    const visit = (cell: number, matrix: Mat2D, depth: number): void => {
      if (cell === forbiddenCell) throw new Error('Fill Cell 引用目标 Cell，会产生循环，原图已保留');
      if (depth > limits.depth) throw new Error('Fill 实际展开超过深度预算');
      for (const shape of library.owners.get(cell) ?? []) {
        if (++traversal.visits > limits.shapes) throw new Error('Fill 实际展开超过对象预算');
        if (shape.type !== ShapeType.INSTANCE) { action(shape, matrix); continue; }
        const columns: number = dimension(shape.arrayCols), rows: number = dimension(shape.arrayRows);
        if (definitionGrid > 0 && (!onGrid(shape.points[0].x, definitionGrid) || !onGrid(shape.points[0].y, definitionGrid) ||
          (columns > 1 && (!onGrid(shape.arrayColStepX ?? 0, definitionGrid) || !onGrid(shape.arrayColStepY ?? 0, definitionGrid))) ||
          (rows > 1 && (!onGrid(shape.arrayRowStepX ?? 0, definitionGrid) || !onGrid(shape.arrayRowStepY ?? 0, definitionGrid))))) {
          throw new Error('Fill 子定义实例坐标或阵列步长未对齐 DBU；保存量化可能改变 footprint，请先明确对齐');
        }
        if (columns * rows > limits.placements - traversal.placements) throw new Error('Fill 实际阵列展开超过实例预算');
        for (let row: number = 0; row < rows; row++) for (let col: number = 0; col < columns; col++) {
          traversal.placements++;
          const member: Mat2D = instanceTransformMat(shape);
          member.tx += col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0);
          member.ty += col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0);
          const world: Mat2D = composed(matrix, member);
          if (![world.a, world.b, world.c, world.d, world.tx, world.ty].every((value: number): boolean => Number.isFinite(value))) throw new Error('Fill 层级变换溢出');
          visit(shape.cellId ?? -1, world, depth + 1);
        }
      }
    };
    visit(cellId, identity(), 1);
  }

  private paintedBounds(shape: Shape, matrix: Mat2D): ShapeBounds {
    if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE) throw new Error('Fill footprint 尚不能证明 TEXT/NODE 的真实绘制范围，请使用面积 Cell');
    let box: ShapeBounds | undefined;
    if (shape.type === ShapeType.PATH) {
      const pathTransform: PathBoundsTransform = { a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d, tx: matrix.tx, ty: matrix.ty };
      box = getPathGeometryBounds(shape, pathTransform);
    }
    else {
      const points: Point[] = shape.type === ShapeType.RECT ? strictRectangleCorners(shape.points) : shape.points;
      box = boundsOf(points.map((point: Point): Point => transformed(point, matrix)));
    }
    if (box === undefined || !validBounds(box)) throw new Error('Fill Cell 材料范围无效');
    if (shape.type === ShapeType.PATH && (shape.pathType ?? 0) === 1) {
      // PathBounds shares the renderer's eight-segment semicircle. Enclose the
      // mathematical cap as well, including under arbitrary nested rotations.
      const scale: number = Math.sqrt(Math.abs(matrix.a * matrix.d - matrix.b * matrix.c));
      const width: number = (shape.pathWidth ?? 0) * (shape.pathWidthAbsolute === true ? 1 : scale);
      const error: number = width / 2 * (1 - Math.cos(Math.PI / 16));
      box = { minX: box.minX - error, minY: box.minY - error, maxX: box.maxX + error, maxY: box.maxY + error };
    }
    return box;
  }

  private footprint(library: FillLibrary, cellId: number, grid: number, limits: FillBudgets, traversal: FillTraversal, forbidden: number = -1): ShapeBounds {
    const result: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    this.walk(library, cellId, limits, traversal, (shape: Shape, matrix: Mat2D): void => {
      if (shape.points.some((point: Point): boolean => !onGrid(point.x, grid) || !onGrid(point.y, grid)) ||
        (shape.type === ShapeType.PATH && (!onGrid(shape.pathWidth ?? 0, grid) || !onGrid(shape.pathBeginExtension ?? 0, grid) || !onGrid(shape.pathEndExtension ?? 0, grid)))) {
        throw new Error('Fill 子定义坐标、PATH WIDTH 或扩展未对齐 DBU；保存量化可能改变 footprint，请先明确对齐');
      }
      const box: ShapeBounds = this.paintedBounds(shape, matrix);
      result.minX = Math.min(result.minX, box.minX); result.minY = Math.min(result.minY, box.minY);
      result.maxX = Math.max(result.maxX, box.maxX); result.maxY = Math.max(result.maxY, box.maxY);
    }, forbidden, grid);
    if (!validBounds(result)) throw new Error('Fill Cell 没有有效面积材料');
    return { minX: gridFloor(result.minX, grid), minY: gridFloor(result.minY, grid), maxX: gridCeiling(result.maxX, grid), maxY: gridCeiling(result.maxY, grid) };
  }

  /** Complete-budget bounds, including nested MAG/rotation/reflection, skew AREF,
   * absolute GDS WIDTH and signed custom extensions. No display-depth truncation. */
  definitionFootprint(shapes: Shape[], structure: EditStructureState, fillCellId: number, dbuNm: number,
    options: HierarchyFillLimits = {}): HierarchyFillFootprintResult {
    try {
      const limits: FillBudgets = budgets(options), library: FillLibrary = this.validate(shapes, structure, limits);
      if (!Number.isInteger(fillCellId) || fillCellId < 0 || fillCellId >= structure.cellNames.length || !Number.isFinite(dbuNm) || dbuNm <= 0 || dbuNm > 1e6) throw new Error('Fill Cell 或 DBU 无效');
      const traversal: FillTraversal = { placements: 0, visits: 0, points: 0 };
      return { ok: true, message: '', footprint: this.footprint(library, fillCellId, dbuNm, limits, traversal), visitedPlacements: traversal.placements };
    } catch (error) { return { ok: false, message: String(error) }; }
  }

  createPlan(shapes: Shape[], structure: EditStructureState, options: HierarchyFillOptions,
    adapter: LayerRegionAdapter = new NativeLayerRegionAdapter()): HierarchyFillResult {
    try {
      const limits: FillBudgets = budgets(options), library: FillLibrary = this.validate(shapes, structure, limits), grid: number = options.dbuNm;
      if (!Number.isFinite(grid) || grid <= 0 || grid > 1e6 || !Number.isInteger(options.targetCellId) || options.targetCellId < 0 || options.targetCellId >= structure.cellNames.length ||
        !Number.isInteger(options.fillCellId) || options.fillCellId < 0 || options.fillCellId >= structure.cellNames.length || options.fillCellId === options.targetCellId) throw new Error('Fill 目标、Fill Cell 或 DBU 无效');
      if (structure.physicalUnits !== undefined && Math.abs(structure.physicalUnits * 1e9 - grid) > grid * 1e-10) throw new Error('Fill DBU 与文档物理单位不一致');
      if (structure.precision !== undefined && Math.abs(structure.precision.dbuNm - grid) > grid * 1e-10) throw new Error('Fill DBU 与文档精度不一致');
      if (!validLayer(options.instanceLayer, options.instanceDatatype) || !validProperties(options.instanceProperties) ||
        ['none', 'all', 'layers'].indexOf(options.excludeMode) < 0 || !Array.isArray(options.excludeLayers ?? []) ||
        (options.excludeLayers ?? []).some((layer: HierarchyFillLayer): boolean => !validLayer(layer.layerNumber, layer.datatype)) ||
        (options.excludeMode === 'layers' && (options.excludeLayers ?? []).length < 1)) throw new Error('Fill 输出图层、属性或避让范围无效');
      for (const point of [options.origin, options.columnStep, options.rowStep]) if (!validPoint(point) || !onGrid(point.x, grid) || !onGrid(point.y, grid)) throw new Error('Fill 起点和步长须在文档 DBU 上，不能偷偷量化');
      if (![options.regionMarginNm, options.excludeSpacingNm].every((value: number): boolean => Number.isFinite(value) && value >= 0 && onGrid(value, grid))) throw new Error('Fill 安全边距须为非负且在 DBU 上');
      const determinant: number = options.columnStep.x * options.rowStep.y - options.columnStep.y * options.rowStep.x;
      if (!Number.isFinite(determinant) || determinant === 0) throw new Error('Fill 行列步长不能共线或为零');
      const traversal: FillTraversal = { placements: 0, visits: 0, points: 0 };
      const material: ShapeBounds = this.footprint(library, options.fillCellId, grid, limits, traversal, options.targetCellId);
      const footprint: ShapeBounds = options.footprint === undefined ? material : { minX: options.footprint.minX, minY: options.footprint.minY, maxX: options.footprint.maxX, maxY: options.footprint.maxY };
      if (!validBounds(footprint) || !containsBounds(footprint, material) || ![footprint.minX, footprint.minY, footprint.maxX, footprint.maxY].every((value: number): boolean => onGrid(value, grid))) throw new Error('Fill footprint 必须完整覆盖真实材料，且坐标在 DBU 上');
      const checkRegion = (result: LayerRegionResult): number[][] => {
        if (result === undefined || result === null || !result.ok || typeof result.message !== 'string' || !Array.isArray(result.polygons)) throw new Error(result?.message || 'Fill 区域计算失败');
        let count: number = 0;
        if (result.polygons.length > 40000 || result.polygons.some((ring: number[]): boolean => {
          if (!Array.isArray(ring) || ring.length < 6 || ring.length % 2 !== 0) return true;
          count += ring.length / 2;
          return count > 400000 || !Number.isFinite(ringArea(ring)) || ringArea(ring) === 0 || ring.some((coordinate: number): boolean => !onGrid(coordinate, grid));
        })) throw new Error('Fill 区域结果无效、未量化或超预算');
        traversal.points += count;
        if (traversal.points > limits.points) throw new Error('Fill 区域累计工作顶点超过预算');
        return result.polygons.map((ring: number[]): number[] => ring.slice());
      };
      const boolean = (a: number[][], b: number[][], operation: 'union' | 'difference' | 'intersection'): number[][] => {
        for (const ring of a.concat(b)) traversal.points += ring.length / 2;
        if (traversal.points > limits.points) throw new Error('Fill 区域累计输入顶点超过预算');
        return checkRegion(adapter.boolean(a, b, operation, grid));
      };
      const exactAxisPath = (shape: Shape, matrix: Mat2D): boolean => {
        const scale: number = Math.sqrt(Math.abs(matrix.a * matrix.d - matrix.b * matrix.c));
        const localWidth: number = (shape.pathWidth ?? 0) / (shape.pathWidthAbsolute === true ? scale : 1);
        if ((shape.pathType ?? 0) === 1 || !onGrid(localWidth / 2, grid) || !shape.points.every((point: Point, index: number): boolean =>
          onGrid(point.x, grid) && onGrid(point.y, grid) && (index === 0 || point.x === shape.points[index - 1].x || point.y === shape.points[index - 1].y))) return false;
        const world: Point[] = shape.points.map((point: Point): Point => transformed(point, matrix));
        return world.every((point: Point, index: number): boolean => onGrid(point.x, grid) && onGrid(point.y, grid) &&
          (index === 0 || Math.abs(point.x - world[index - 1].x) < grid * 1e-8 || Math.abs(point.y - world[index - 1].y) < grid * 1e-8)) &&
          onGrid(shape.pathBeginExtension ?? 0, grid) && onGrid(shape.pathEndExtension ?? 0, grid);
      };
      const continuousArea: number[][] = [], continuousExcluded: number[][] = [];
      const sourceGeometry = (shape: Shape, matrix: Mat2D, area: boolean): number[][] => {
        if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE) {
          if (area) throw new Error('Fill 区域只能选择面积对象');
          return [];
        }
        const corners: Point[] = shape.type === ShapeType.RECT ? strictRectangleCorners(shape.points) : shape.points;
        const world: Point[] = corners.map((point: Point): Point => transformed(point, matrix));
        const exact: boolean = world.every((point: Point): boolean => onGrid(point.x, grid) && onGrid(point.y, grid)) &&
          (shape.type !== ShapeType.PATH || exactAxisPath(shape, matrix));
        if (!exact) {
          if (area) throw new Error('Fill 区域轮廓尚不能证明 DBU 精确包含；圆头、斜 PATH 或未对齐变换请先显式区域化并检查精度');
          conservativeExclusionCount++;
          const box: ShapeBounds = this.paintedBounds(shape, matrix);
          const ring: number[] = rectRing({ minX: gridFloor(box.minX, grid), minY: gridFloor(box.minY, grid), maxX: gridCeiling(box.maxX, grid), maxY: gridCeiling(box.maxY, grid) });
          continuousExcluded.push(ring.slice()); return [ring];
        }
        if (shape.type !== ShapeType.PATH) {
          const ring: number[] = pointRing(world); (area ? continuousArea : continuousExcluded).push(ring.slice());
          return boolean([ring], [], 'union');
        }
        if (adapter.shape === undefined) throw new Error('Fill PATH 需要真实区域模块');
        const scale: number = Math.sqrt(Math.abs(matrix.a * matrix.d - matrix.b * matrix.c));
        const local: LayerRegionResult = adapter.shape(copyShape(shape), grid, scale);
        if (!local.ok || (local.roundCapErrorNm ?? 0) > 0 || !Array.isArray(local.polygons)) throw new Error(local.message || 'Fill PATH 精度不足');
        const transformedRings: number[][] = local.polygons.map((ring: number[]): number[] => {
          if (ring.length < 6 || ring.length % 2 !== 0 || ring.length > 40000) throw new Error('Fill PATH 轮廓无效');
          const output: number[] = [];
          for (let index: number = 0; index < ring.length; index += 2) { const point: Point = transformed({ x: ring[index], y: ring[index + 1] }, matrix); output.push(point.x, point.y); }
          if (output.some((value: number): boolean => !onGrid(value, grid))) throw new Error('Fill PATH 世界轮廓未对齐 DBU');
          return output;
        });
        for (const ring of transformedRings) (area ? continuousArea : continuousExcluded).push(ring.slice());
        return boolean(transformedRings, [], 'union');
      };
      let conservativeExclusionCount: number = 0;
      let area: number[][] = [];
      const areaIds: Set<number> = new Set<number>(options.areaShapeIds ?? []);
      if (!Array.isArray(options.areaShapeIds ?? []) || areaIds.size !== (options.areaShapeIds ?? []).length) throw new Error('Fill 区域选择 ID 重复或无效');
      const explicit: Point[][] = options.areaPolygons ?? [];
      if (!Array.isArray(explicit) || explicit.length > 40000) throw new Error('Fill 显式区域超过预算');
      const explicitRings: number[][] = [];
      for (const polygon of explicit) {
        if (!Array.isArray(polygon) || polygon.length < 3 || polygon.some((point: Point): boolean => !validPoint(point) || !onGrid(point.x, grid) || !onGrid(point.y, grid))) throw new Error('Fill 显式区域必须为 DBU 上的真实轮廓');
        const ring: number[] = pointRing(polygon); if (ringArea(ring) === 0 || !Number.isFinite(ringArea(ring))) throw new Error('Fill 显式区域无有效面积');
        explicitRings.push(ring);
      }
      if (explicitRings.length > 0) { for (const ring of explicitRings) continuousArea.push(ring.slice()); area = boolean(explicitRings, [], 'union'); }
      for (const id of areaIds) {
        const shape: Shape | undefined = (library.owners.get(options.targetCellId) ?? []).find((candidate: Shape): boolean => candidate.id === id);
        if (shape === undefined || shape.type === ShapeType.INSTANCE) throw new Error('Fill 区域选择必须为当前 Cell 的直接面积对象');
        area = boolean(area, sourceGeometry(shape, identity(), true), 'union');
      }
      if (area.length < 1) throw new Error('Fill 区域为空，原图已保留');
      let excluded: number[][] = [];
      if (options.excludeMode !== 'none') {
        this.walk(library, options.targetCellId, limits, traversal, (shape: Shape, matrix: Mat2D): void => {
          if (areaIds.has(shape.id) || (options.excludeMode === 'layers' && !(options.excludeLayers ?? []).some((layer: HierarchyFillLayer): boolean => layer.layerNumber === shape.layerNumber && layer.datatype === shape.datatype))) return;
          const geometry: number[][] = sourceGeometry(shape, matrix, false);
          if (geometry.length > 0) excluded = boolean(excluded, geometry, 'union');
        });
      }
      const areaPoints: Point[] = [];
      for (const ring of area) for (let index: number = 0; index < ring.length; index += 2) areaPoints.push({ x: ring[index], y: ring[index + 1] });
      const areaBounds: ShapeBounds = boundsOf(areaPoints);
      const originBounds: ShapeBounds = { minX: areaBounds.minX - footprint.maxX, minY: areaBounds.minY - footprint.maxY,
        maxX: areaBounds.maxX - footprint.minX, maxY: areaBounds.maxY - footprint.minY };
      const originCorners: Point[] = [
        { x: originBounds.minX, y: originBounds.minY }, { x: originBounds.maxX, y: originBounds.minY },
        { x: originBounds.maxX, y: originBounds.maxY }, { x: originBounds.minX, y: originBounds.maxY }];
      const latticePoints: Point[] = originCorners.map((point: Point): Point => {
          const x: number = point.x - options.origin.x, y: number = point.y - options.origin.y;
          return { x: (x * options.rowStep.y - y * options.rowStep.x) / determinant,
            y: (options.columnStep.x * y - options.columnStep.y * x) / determinant };
        });
      const lattice: ShapeBounds = boundsOf(latticePoints);
      const minCol: number = Math.floor(lattice.minX), maxCol: number = Math.ceil(lattice.maxX),
        minRow: number = Math.floor(lattice.minY), maxRow: number = Math.ceil(lattice.maxY);
      if (![minCol, maxCol, minRow, maxRow].every((value: number): boolean => Number.isSafeInteger(value)) ||
        (maxCol - minCol + 1) * (maxRow - minRow + 1) > limits.candidates) throw new Error('Fill 固定栅格候选超过预算，请缩小范围或增大步长');
      const accepted: FillMember[] = [], acceptedBuckets: Map<string, ShapeBounds[]> = new Map<string, ShapeBounds[]>();
      const bucketWidth: number = footprint.maxX - footprint.minX, bucketHeight: number = footprint.maxY - footprint.minY;
      let considered: number = 0, rejectedOutside: number = 0, rejectedExcluded: number = 0, rejectedOverlap: number = 0;
      for (let row: number = minRow; row <= maxRow; row++) for (let col: number = minCol; col <= maxCol; col++) {
        considered++;
        const point: Point = { x: options.origin.x + col * options.columnStep.x + row * options.rowStep.x,
          y: options.origin.y + col * options.columnStep.y + row * options.rowStep.y };
        const reservation: ShapeBounds = placed(footprint, point, options.regionMarginNm);
        if (!validPoint(point) || !onGrid(point.x, grid) || !onGrid(point.y, grid) || !validBounds(reservation) ||
          ![reservation.minX, reservation.minY, reservation.maxX, reservation.maxY].every((value: number): boolean => onGrid(value, grid))) throw new Error('Fill 放置坐标超出 DBU 范围');
        // The bbox cheaply rejects only. A concavity or hole is always tested by
        // subtraction of actual material, not corners/center or a bounding box.
        if (!containsBounds(areaBounds, reservation) || !continuousRelation(reservation, continuousArea, true, traversal, limits) || boolean([rectRing(reservation)], area, 'difference').length > 0) { rejectedOutside++; continue; }
        const avoidBox: ShapeBounds = placed(footprint, point, options.excludeSpacingNm);
        if (excluded.length > 0 && (!continuousRelation(avoidBox, continuousExcluded, false, traversal, limits) || boolean([rectRing(avoidBox)], excluded, 'intersection').length > 0)) { rejectedExcluded++; continue; }
        const rawBox: ShapeBounds = placed(footprint, point, 0);
        const bucketX: number = Math.floor(rawBox.minX / bucketWidth), bucketY: number = Math.floor(rawBox.minY / bucketHeight);
        let intersects: boolean = false;
        for (let dy: number = -1; dy <= 1; dy++) for (let dx: number = -1; dx <= 1; dx++) {
          if ((acceptedBuckets.get(`${bucketX + dx}/${bucketY + dy}`) ?? []).some((box: ShapeBounds): boolean => overlap(box, rawBox))) intersects = true;
        }
        if (intersects) { rejectedOverlap++; continue; }
        if (accepted.length >= limits.placements - traversal.placements) throw new Error('Fill 放置结果超过实例预算，未提交部分结果');
        accepted.push({ row: row, col: col, x: point.x, y: point.y });
        const key: string = `${bucketX}/${bucketY}`, occupants: ShapeBounds[] = acceptedBuckets.get(key) ?? [];
        occupants.push(rawBox); acceptedBuckets.set(key, occupants);
      }
      let nextId: number = options.nextShapeId ?? library.nextId;
      if (!Number.isSafeInteger(nextId) || nextId < library.nextId) throw new Error('Fill 对象 ID 分配器过期或无效');
      const additions: Shape[] = [];
      for (let index: number = 0; index < accepted.length;) {
        const first: FillMember = accepted[index]; let end: number = index + 1;
        while (end < accepted.length && end - index < 32767 && accepted[end].row === first.row && accepted[end].col === accepted[end - 1].col + 1) end++;
        if (shapes.length + additions.length + 1 > limits.shapes || library.points + additions.length + 1 > limits.points || !Number.isSafeInteger(nextId + 1)) throw new Error('Fill 对象、顶点或 ID 结果超预算');
        const count: number = end - index;
        additions.push({ id: nextId++, type: ShapeType.INSTANCE, ownerCellId: options.targetCellId, cellId: options.fillCellId,
          cellName: structure.cellNames[options.fillCellId], layerNumber: options.instanceLayer, datatype: options.instanceDatatype,
          points: [{ x: first.x, y: first.y }], selected: false, rotation: 0, mirror: 0, magnification: 1,
          arrayCols: count > 1 ? count : 0, arrayRows: count > 1 ? 1 : 0,
          arrayColStepX: count > 1 ? options.columnStep.x : 0, arrayColStepY: count > 1 ? options.columnStep.y : 0,
          arrayRowStepX: 0, arrayRowStepY: 0,
          properties: options.instanceProperties === undefined ? undefined : cloneStructured(options.instanceProperties) as LayoutPropRecord[] });
        index = end;
      }
      const plan: HierarchyFillPlan = { shapes: shapes.map((shape: Shape): Shape => copyShape(shape)).concat(additions),
        structure: cloneEditStructureModel(structure, true) as EditStructureState, targetCellId: options.targetCellId, fillCellId: options.fillCellId,
        footprint: footprint, placedInstances: accepted.length, addedShapes: additions.length, consideredCandidates: considered,
        rejectedOutside: rejectedOutside, rejectedExcluded: rejectedExcluded, rejectedOverlap: rejectedOverlap,
        visitedPlacements: traversal.placements, conservativeExclusionCount: conservativeExclusionCount };
      normalizeLayoutSemantics(plan.structure, plan.structure.cellNames.length);
      return { ok: true, message: `固定起点 Fill 可放置 ${accepted.length} 个实例，压缩为 ${additions.length} 个引用；安全边距为矩形四边空间` +
        (conservativeExclusionCount > 0 ? `；${conservativeExclusionCount} 个不确定轮廓使用保守绘制范围避让` : ''), plan: plan };
    } catch (error) { return { ok: false, message: `${String(error)}，原图已保留` }; }
  }
}
export const hierarchyFillService: HierarchyFillService = new HierarchyFillService();
