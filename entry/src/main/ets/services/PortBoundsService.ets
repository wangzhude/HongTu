import { Shape, ShapeType, ShapeBounds } from '../models/GdsiiData';
import { LayoutPort, MAX_LAYOUT_PORTS } from '../models/LayoutPort';
import type { EditStructureState } from './EditService';
import { instanceTransformMat, Mat2D } from './HierarchyExpandService';

export const MAX_PORT_BOUNDS_SOURCE_SHAPES: number = 1000000;
export const MAX_PORT_BOUNDS_CELLS: number = 100000;
export const MAX_PORT_BOUNDS_WORK: number = 1000000;

export interface PortBoundsResult {
  ok: boolean;
  truncated: boolean;
  bounds?: ShapeBounds;
  /** Exact symbolic endpoint count; a count beyond safe integer capacity fails. */
  portCount: number;
  definitionsVisited: number;
  instancesVisited: number;
  message: string;
}

interface PortDefinitionBounds { bounds?: ShapeBounds; count: number; }
interface PortGraphFrame { cellId: number; next: number; }

function checked(bounds: ShapeBounds): ShapeBounds {
  if (![bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].every((value: number): boolean => Number.isFinite(value)) ||
    bounds.minX > bounds.maxX || bounds.minY > bounds.maxY) throw new Error('端口范围或实例变换超出有限数值');
  return bounds;
}

function merge(left: ShapeBounds | undefined, right: ShapeBounds): ShapeBounds {
  if (left === undefined) return checked(right);
  return checked({ minX: Math.min(left.minX, right.minX), minY: Math.min(left.minY, right.minY),
    maxX: Math.max(left.maxX, right.maxX), maxY: Math.max(left.maxY, right.maxY) });
}

function aperture(port: LayoutPort): ShapeBounds {
  const angle: number = ((port.orientationDeg % 360) + 360) % 360 * Math.PI / 180;
  const half: number = port.widthNm * port.frameMagnification / 2;
  const dx: number = Math.abs(Math.sin(angle) * half), dy: number = Math.abs(Math.cos(angle) * half);
  // Own frame mirror reverses the tangent, so this symmetric aperture is
  // unchanged. The parent's actual matrix applies any placement reflection.
  const padX: number = Number.EPSILON * 8 * (Math.abs(port.centerNm.x) + half);
  const padY: number = Number.EPSILON * 8 * (Math.abs(port.centerNm.y) + half);
  return checked({ minX: port.centerNm.x - dx - padX, minY: port.centerNm.y - dy - padY,
    maxX: port.centerNm.x + dx + padX, maxY: port.centerNm.y + dy + padY });
}

function transformed(bounds: ShapeBounds, matrix: Mat2D): ShapeBounds {
  let result: ShapeBounds | undefined = undefined;
  const xs: number[] = [bounds.minX, bounds.maxX], ys: number[] = [bounds.minY, bounds.maxY];
  for (const x of xs) for (const y of ys) {
    const worldX: number = matrix.a * x + matrix.b * y + matrix.tx;
    const worldY: number = matrix.c * x + matrix.d * y + matrix.ty;
    // Account for rounding of the products before cancellation as well as
    // their sum. This is camera padding, never a change to saved port data.
    const padX: number = Number.EPSILON * 8 * (Math.abs(matrix.a * x) + Math.abs(matrix.b * y) + Math.abs(matrix.tx));
    const padY: number = Number.EPSILON * 8 * (Math.abs(matrix.c * x) + Math.abs(matrix.d * y) + Math.abs(matrix.ty));
    result = merge(result, { minX: worldX - padX, minY: worldY - padY, maxX: worldX + padX, maxY: worldY + padY });
  }
  if (result === undefined) throw new Error('端口范围缺少有效坐标');
  return result;
}

function arrayDimension(value: number | undefined): number {
  if (value === undefined || value === 0) return 1;
  if (!Number.isSafeInteger(value) || value < 1) throw new Error('端口实例阵列行列数无效');
  return value;
}

class PortBoundsResolver {
  private byPortCell: Map<number, LayoutPort[]> = new Map<number, LayoutPort[]>();
  private byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
  private cache: Map<string, PortDefinitionBounds> = new Map<string, PortDefinitionBounds>();
  private work: number = 0;
  definitionsVisited: number = 0;
  instancesVisited: number = 0;

  private tick(amount: number = 1): void {
    this.work += amount;
    if (this.work > MAX_PORT_BOUNDS_WORK) throw new Error('端口完整范围计算超过定义工作预算；未使用截断显示列表适配');
  }

  constructor(shapes: Shape[], structure: EditStructureState) {
    const names: string[] = structure.cellNames, keys: string[] = structure.cellKeys ?? [];
    if (keys.length !== names.length || new Set<string>(keys).size !== keys.length ||
      keys.some((key: string): boolean => typeof key !== 'string' || key.length === 0)) throw new Error('端口范围的稳定 Cell 身份无效');
    const ids: Set<string> = new Set<string>();
    for (const port of structure.ports ?? []) {
      this.tick();
      if (port === undefined || port === null || typeof port.id !== 'string' || port.id.length === 0 || ids.has(port.id) ||
        !Number.isInteger(port.ownerCellId) || port.ownerCellId < 0 || port.ownerCellId >= names.length ||
        port.ownerCellKey !== keys[port.ownerCellId] || port.centerNm === undefined || port.centerNm === null ||
        !Number.isFinite(port.centerNm.x) || !Number.isFinite(port.centerNm.y) || !Number.isFinite(port.orientationDeg) ||
        !Number.isFinite(port.widthNm) || port.widthNm <= 0 || !Number.isFinite(port.frameMagnification) || port.frameMagnification <= 0 ||
        !Number.isFinite(port.widthNm * port.frameMagnification) || typeof port.frameMirror !== 'boolean') throw new Error('端口定义或 owner Cell 已失效，未适配不完整范围');
      ids.add(port.id);
      const group: LayoutPort[] = this.byPortCell.get(port.ownerCellId) ?? [];
      group.push(port); this.byPortCell.set(port.ownerCellId, group);
    }
    for (const shape of shapes) {
      this.tick();
      if (shape.type !== ShapeType.INSTANCE) continue;
      const owner: number = shape.ownerCellId ?? structure.topCellId;
      if (!Number.isInteger(owner) || owner < 0 || owner >= names.length || shape.cellId === undefined ||
        !Number.isInteger(shape.cellId) || shape.cellId < 0 || shape.cellId >= names.length ||
        (shape.cellName !== undefined && shape.cellName !== names[shape.cellId])) throw new Error('端口层级引用的 Cell 已失效');
      if (shape.points.length === 0 || !Number.isFinite(shape.points[0].x) || !Number.isFinite(shape.points[0].y) ||
        !Number.isFinite(shape.rotation ?? 0) || ![0, 1, 2].includes(shape.mirror ?? 0) ||
        !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 ||
        ![shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0]
          .every((value: number): boolean => Number.isFinite(value))) throw new Error('端口层级实例 frame 或阵列步向量无效');
      arrayDimension(shape.arrayCols); arrayDimension(shape.arrayRows);
      const group: Shape[] = this.byOwner.get(owner) ?? [];
      group.push(shape); this.byOwner.set(owner, group);
    }
  }

  /** Iterative DAG validation never recurses through a deep source graph. */
  validateGraph(root: number): void {
    const color: Map<number, number> = new Map<number, number>();
    const initial: PortGraphFrame = { cellId: root, next: 0 };
    const stack: PortGraphFrame[] = [initial]; color.set(root, 1);
    while (stack.length > 0) {
      this.tick();
      const frame: PortGraphFrame = stack[stack.length - 1], instances: Shape[] = this.byOwner.get(frame.cellId) ?? [];
      if (frame.next >= instances.length) { color.set(frame.cellId, 2); stack.pop(); continue; }
      const child: number = instances[frame.next++].cellId as number;
      if (color.get(child) === 1) throw new Error('端口层级含循环引用，未适配不完整范围');
      if (color.get(child) === 2) continue;
      const next: PortGraphFrame = { cellId: child, next: 0 }; stack.push(next); color.set(child, 1);
    }
  }

  bounds(cellId: number, remaining: number): PortDefinitionBounds {
    const key: string = `${cellId}:${remaining}`;
    const cached: PortDefinitionBounds | undefined = this.cache.get(key);
    if (cached !== undefined) return cached;
    this.tick(); this.definitionsVisited++;
    let bounds: ShapeBounds | undefined = undefined, count: number = 0;
    for (const port of this.byPortCell.get(cellId) ?? []) { this.tick(); bounds = merge(bounds, aperture(port)); count++; }
    if (remaining > 0) for (const shape of this.byOwner.get(cellId) ?? []) {
      this.tick(); this.instancesVisited++;
      const child: PortDefinitionBounds = this.bounds(shape.cellId as number, remaining - 1);
      const columns: number = arrayDimension(shape.arrayCols), rows: number = arrayDimension(shape.arrayRows);
      const occurrences: number = child.count * columns * rows;
      if (!Number.isSafeInteger(occurrences) || !Number.isSafeInteger(count + occurrences)) throw new Error('端口实例数量超过精确整数容量，未适配不完整范围');
      count += occurrences;
      if (child.bounds === undefined) continue;
      const matrix: Mat2D = instanceTransformMat(shape);
      if (![matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].every((value: number): boolean => Number.isFinite(value))) throw new Error('端口层级变换超出有限数值');
      const local: ShapeBounds = transformed(child.bounds, matrix);
      const cx: number = (columns - 1) * (shape.arrayColStepX ?? 0), cy: number = (columns - 1) * (shape.arrayColStepY ?? 0);
      const rx: number = (rows - 1) * (shape.arrayRowStepX ?? 0), ry: number = (rows - 1) * (shape.arrayRowStepY ?? 0);
      // Array steps live in the parent coordinates, not the child's rotated
      // frame. The four affine grid corners give each coordinate's extrema.
      const dx: number[] = [0, cx, rx, cx + rx], dy: number[] = [0, cy, ry, cy + ry];
      const padX: number = Number.EPSILON * 8 * (Math.abs(cx) + Math.abs(rx));
      const padY: number = Number.EPSILON * 8 * (Math.abs(cy) + Math.abs(ry));
      bounds = merge(bounds, { minX: local.minX + Math.min(...dx) - padX, minY: local.minY + Math.min(...dy) - padY,
        maxX: local.maxX + Math.max(...dx) + padX, maxY: local.maxY + Math.max(...dy) + padY });
    }
    const result: PortDefinitionBounds = { bounds: bounds, count: count }; this.cache.set(key, result); return result;
  }
}

/** Complete conservative aperture + center bounds in the current Cell frame.
 * Depth 1 is local, depth N includes N-1 definition edges. Hidden layers remain
 * included, matching the editor's fit-all geometry contract. Arrays are symbolic.
 * A failure returns no partial bounds; callers must display message and stop Fit.
 */
export function summarizeCellPorts(allShapes: Shape[], structure: EditStructureState,
  rootCellId: number, hierarchyDepth: number): PortBoundsResult {
  let resolver: PortBoundsResolver | undefined = undefined;
  try {
    if (!Array.isArray(allShapes) || allShapes.length > MAX_PORT_BOUNDS_SOURCE_SHAPES ||
      !Array.isArray(structure.cellNames) || structure.cellNames.length > MAX_PORT_BOUNDS_CELLS ||
      !Array.isArray(structure.ports ?? []) || (structure.ports ?? []).length > MAX_LAYOUT_PORTS) throw new Error('端口完整范围的源定义超出预算');
    if (!Number.isInteger(rootCellId) || rootCellId < 0 || rootCellId >= structure.cellNames.length) throw new Error('端口范围的当前 Cell 已失效');
    if (!Number.isInteger(hierarchyDepth) || hierarchyDepth < 1 || hierarchyDepth > 32) throw new Error('端口范围层级深度必须为 1 到 32');
    if ((structure.ports ?? []).length === 0) return { ok: true, truncated: false, portCount: 0, definitionsVisited: 0, instancesVisited: 0, message: '' };
    resolver = new PortBoundsResolver(allShapes, structure); resolver.validateGraph(rootCellId);
    const summary: PortDefinitionBounds = resolver.bounds(rootCellId, hierarchyDepth - 1);
    return { ok: true, truncated: false, bounds: summary.bounds, portCount: summary.count,
      definitionsVisited: resolver.definitionsVisited, instancesVisited: resolver.instancesVisited, message: '' };
  } catch (error) {
    return { ok: false, truncated: true, portCount: 0, definitionsVisited: resolver?.definitionsVisited ?? 0,
      instancesVisited: resolver?.instancesVisited ?? 0, message: error instanceof Error ? error.message : String(error) };
  }
}
