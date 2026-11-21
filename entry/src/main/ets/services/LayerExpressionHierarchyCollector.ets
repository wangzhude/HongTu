import { Shape, ShapeType } from '../models/GdsiiData';
import { cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface LayerExpressionFilter { layer: number | null; datatype: number | null; }
export interface LayerExpressionTransform { a: number; b: number; c: number; d: number; tx: number; ty: number; }
export interface LayerExpressionPlacement { instanceId: number; column: number; row: number; }
export interface LayerExpressionOccurrence {
  shape: Shape; sourceCellId: number; transform: LayerExpressionTransform; worldScale: number;
  instancePath: LayerExpressionPlacement[];
}
export interface LayerExpressionHierarchyResult {
  ok: boolean; message: string; occurrences: LayerExpressionOccurrence[]; fingerprint: string;
  referenceIds: number[]; visitedNodes: number;
}
const MAX_NODES: number = 100000;
const MAX_SOURCE_POINTS: number = 20000;

function compose(l: LayerExpressionTransform, r: LayerExpressionTransform): LayerExpressionTransform {
  const m: LayerExpressionTransform = { a: l.a * r.a + l.b * r.c, b: l.a * r.b + l.b * r.d,
    c: l.c * r.a + l.d * r.c, d: l.c * r.b + l.d * r.d,
    tx: l.a * r.tx + l.b * r.ty + l.tx, ty: l.c * r.tx + l.d * r.ty + l.ty };
  if (![m.a, m.b, m.c, m.d, m.tx, m.ty].every((v: number): boolean => Number.isFinite(v)) ||
    !Number.isFinite(m.a * m.d - m.b * m.c) || m.a * m.d - m.b * m.c === 0) throw new Error('实例累计变换无效或不可逆');
  return m;
}
function dimension(value: number | undefined): number {
  const n: number = value === undefined || value === 0 ? 1 : value;
  if (!Number.isInteger(n) || n < 1 || n > 32767) throw new Error('实例阵列维数无效');
  return n;
}
function instanceMatrix(shape: Shape): LayerExpressionTransform {
  const mag: number = shape.magnification ?? 1; const rotation: number = shape.rotation ?? 0;
  const mirror: number = shape.mirror ?? 0;
  if (!Number.isFinite(mag) || mag <= 0 || !Number.isFinite(rotation) ||
    !Number.isInteger(mirror) || mirror < 0 || mirror > 2 || shape.points.length !== 1 ||
    !Number.isFinite(shape.points[0].x) || !Number.isFinite(shape.points[0].y)) throw new Error('实例 MAG、旋转、镜像或锚点无效');
  // GDS: mirror about X, then rotate; mirror Y is mirror X plus 180 degrees.
  const angle: number = (rotation + (mirror === 2 ? 180 : 0)) % 360;
  const rad: number = angle * Math.PI / 180;
  const cos: number = Math.abs(Math.cos(rad)) < 1e-15 ? 0 : Math.cos(rad);
  const sin: number = Math.abs(Math.sin(rad)) < 1e-15 ? 0 : Math.sin(rad);
  const sign: number = mirror === 0 ? 1 : -1;
  return { a: mag * cos, b: -mag * sin * sign, c: mag * sin, d: mag * cos * sign,
    tx: shape.points[0].x, ty: shape.points[0].y };
}

/** Whole-layer traversal ignores selection, visibility and viewport. A depth
 * of N includes N child edges. No display collector or partial result is used.
 * All expanded placements and selected geometry have explicit finite budgets. */
export function collectLayerExpressionHierarchy(allShapes: Shape[], topCellId: number, currentCellId: number,
  depth: number, selectors: LayerExpressionFilter[], cellNames?: string[]): LayerExpressionHierarchyResult {
  const occurrences: LayerExpressionOccurrence[] = []; const referenceIds: number[] = [];
  let visitedNodes: number = 0; let sourcePoints: number = 0;
  try {
    if (!Number.isInteger(depth) || depth < 0 || depth > 32) throw new Error('递归深度必须为 0–32 的整数');
    if (!Number.isSafeInteger(currentCellId) || currentCellId < 0) throw new Error('当前 Cell ID 无效');
    const index: Map<number, Shape[]> = new Map<number, Shape[]>();
    const documentIds: Set<number> = new Set<number>(); const duplicateIds: Set<number> = new Set<number>();
    if (allShapes.length > 1000000) throw new Error('文档超过 1000000 个对象预算');
    for (const shape of allShapes) {
      if (documentIds.has(shape.id)) duplicateIds.add(shape.id); else documentIds.add(shape.id);
      const owner: number = shape.ownerCellId ?? topCellId;
      let local: Shape[] | undefined = index.get(owner);
      if (local === undefined) { local = []; index.set(owner, local); }
      local.push(shape);
    }
    const definitions: Map<number, Shape> = new Map<number, Shape>();
    const refs: Set<number> = new Set<number>(); const fingerprintShapes: Shape[] = [];
    const remember = (shape: Shape): void => {
      if (!Number.isSafeInteger(shape.id) || shape.id <= 0 || duplicateIds.has(shape.id)) throw new Error('源对象 ID 无效或重复');
      const previous: Shape | undefined = definitions.get(shape.id);
      if (previous !== undefined && previous !== shape) throw new Error('源对象 ID 无效或重复');
      if (previous === undefined) {
        definitions.set(shape.id, shape);
        const copy: Shape = cloneShapeModel(shape, true) as Shape; copy.selected = false;
        fingerprintShapes.push(copy);
      }
    };
    const visit = (cellId: number, remaining: number, world: LayerExpressionTransform, scale: number,
      ancestors: number[], path: LayerExpressionPlacement[]): void => {
      visitedNodes++;
      if (visitedNodes > MAX_NODES) throw new Error('层级展开超过 100000 个节点预算');
      if (ancestors.indexOf(cellId) >= 0) throw new Error('层级含循环引用，原图已保留');
      if (cellNames !== undefined && (cellId < 0 || cellId >= cellNames.length || typeof cellNames[cellId] !== 'string' || cellNames[cellId].length === 0)) throw new Error('实例引用的 Cell 不存在');
      const chain: number[] = ancestors.concat([cellId]);
      for (const shape of index.get(cellId) ?? []) {
        visitedNodes++;
        if (visitedNodes > MAX_NODES) throw new Error('层级展开超过 100000 个节点预算');
        if (shape.type === ShapeType.INSTANCE) {
          // The chosen finite boundary is deliberate; no omitted child is
          // presented as part of the evaluated region.
          if (remaining === 0) continue;
          remember(shape);
          if (shape.cellId === undefined || !Number.isSafeInteger(shape.cellId) || shape.cellId < 0) throw new Error('实例引用无效');
          if (shape.cellName !== undefined && cellNames !== undefined && shape.cellName !== cellNames[shape.cellId]) throw new Error('实例 Cell ID 与名称不一致');
          const cols: number = dimension(shape.arrayCols), rows: number = dimension(shape.arrayRows);
          if (cols * rows > MAX_NODES - visitedNodes) throw new Error('实例阵列超过 100000 个节点预算');
          const steps: number[] = [shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0];
          if (!steps.every((v: number): boolean => Number.isFinite(v))) throw new Error('实例阵列步长无效');
          const local: LayerExpressionTransform = instanceMatrix(shape); const childScale: number = scale * (shape.magnification ?? 1);
          if (!Number.isFinite(childScale) || childScale <= 0) throw new Error('实例累计 MAG 超过安全范围');
          if (!refs.has(shape.id)) { refs.add(shape.id); referenceIds.push(shape.id); }
          for (let row: number = 0; row < rows; row++) {
            for (let col: number = 0; col < cols; col++) {
              // AREF steps are already in the parent Cell coordinate system.
              const element: LayerExpressionTransform = { a: local.a, b: local.b, c: local.c, d: local.d,
                tx: local.tx + col * steps[0] + row * steps[2], ty: local.ty + col * steps[1] + row * steps[3] };
              visit(shape.cellId, remaining - 1, compose(world, element), childScale, chain,
                path.concat([{ instanceId: shape.id, column: col, row: row }]));
            }
          }
        } else if (selectors.some((selector: LayerExpressionFilter): boolean =>
          (selector.layer === null || selector.layer === shape.layerNumber) &&
          (selector.datatype === null || selector.datatype === shape.datatype))) {
          remember(shape);
          if (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON && shape.type !== ShapeType.PATH &&
            shape.type !== ShapeType.TEXT && shape.type !== ShapeType.NODE) throw new Error('源层含未知几何类型');
          if (!Array.isArray(shape.points) || shape.points.some((p): boolean => !Number.isFinite(p.x) || !Number.isFinite(p.y))) throw new Error('源对象含非有限坐标');
          if (shape.type === ShapeType.RECT || shape.type === ShapeType.POLYGON || shape.type === ShapeType.PATH) {
            sourcePoints += shape.type === ShapeType.RECT ? 4 : shape.points.length;
            if (sourcePoints > MAX_SOURCE_POINTS) throw new Error('源图形超过 20000 个原生输入顶点预算');
          }
          occurrences.push({ shape: shape, sourceCellId: cellId, transform: world, worldScale: scale, instancePath: path });
        }
      }
    };
    visit(currentCellId, depth, { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }, 1, [], []);
    return { ok: true, message: '', occurrences: occurrences, referenceIds: referenceIds, visitedNodes: visitedNodes,
      fingerprint: JSON.stringify(fingerprintShapes) };
  } catch (error) {
    return { ok: false, message: (error as Error).message, occurrences: [], fingerprint: '', referenceIds: [], visitedNodes: visitedNodes };
  }
}
