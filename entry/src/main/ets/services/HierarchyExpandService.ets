/**
 * 层级几何展开（对齐 KLayout hierarchy depth 语义）
 *
 * depth = 1 -> 仅当前 Cell 本地几何（不递归实例）
 * depth = N -> 递归展开 N-1 层子 Cell，几何经 SREF 变换画到父坐标系
 *
 * GDS 变换顺序（与 GDSII Stream / 常见阅读器一致）:
 *   Magnification -> MirrorX -> Rotation -> Translation
 *
 * 展开结果仅用于显示；编辑仍以 EditService 中的 owner Cell 本地图形为准。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, Point, getShapeBounds, ShapeBounds } from '../models/GdsiiData';
import { getPathGeometryBounds, pathGeometryContains } from './PathBoundsService';
import { SceneTextGeometryService } from './SceneTextGeometryService';
import type { InstancePathStep, InstancePathTransform } from './EditService';

/** 合成展开图形 ID 起点，避免与真实 shape.id 冲突 */
export const EXPANDED_SHAPE_ID_BASE: number = 1000000000;

export interface Mat2D {
  a: number;
  b: number;
  c: number;
  d: number;
  tx: number;
  ty: number;
}

function identityMat(): Mat2D {
  return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
}

/** this * other：先应用 other，再应用 this */
function multiplyMat(left: Mat2D, right: Mat2D): Mat2D {
  return {
    a: left.a * right.a + left.b * right.c,
    b: left.a * right.b + left.b * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx,
    c: left.c * right.a + left.d * right.c,
    d: left.c * right.b + left.d * right.d,
    ty: left.c * right.tx + left.d * right.ty + left.ty,
  };
}

function applyMat(m: Mat2D, x: number, y: number): Point {
  return {
    x: m.a * x + m.b * y + m.tx,
    y: m.c * x + m.d * y + m.ty,
  };
}

/**
 * 由 INSTANCE 字段构建 GDS 实例矩阵。
 * mirror: 0=无 1=X 轴镜像 2=Y 轴镜像（=X 镜像再转 180°，GDS STRANS bit15 只有 X 位）
 */
export function instanceTransformMat(inst: Shape): Mat2D {
  const mag: number = (inst.magnification !== undefined && inst.magnification > 0) ? inst.magnification : 1;
  // mirror 码：0=无 1=X 轴 2=Y 轴。GDS 只有 X 镜像位，Y 镜像 = X 镜像 + 180°，
  // 必须在此展开（写出侧 gdsii_writer 与 napi 快照重建同样归一），否则
  // 「纵向镜像」的实例在展开/渲染里少转 180°，与保存后的文件不一致。
  const mirrorCode: number = inst.mirror ?? 0;
  const mirror: boolean = mirrorCode === 1 || mirrorCode === 2;
  const rot: number = (inst.rotation ?? 0) + (mirrorCode === 2 ? 180 : 0);
  const ox: number = inst.points.length > 0 ? inst.points[0].x : 0;
  const oy: number = inst.points.length > 0 ? inst.points[0].y : 0;

  let m: Mat2D = identityMat();
  // 1) magnification
  if (mag !== 1) {
    m = multiplyMat({ a: mag, b: 0, c: 0, d: mag, tx: 0, ty: 0 }, m);
  }
  // 2) mirror about X (y = -y)
  if (mirror) {
    m = multiplyMat({ a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0 }, m);
  }
  // 3) rotation (CCW degrees)
  if (rot !== 0) {
    const rad: number = rot * Math.PI / 180;
    const cosA: number = Math.cos(rad);
    const sinA: number = Math.sin(rad);
    m = multiplyMat({ a: cosA, b: -sinA, c: sinA, d: cosA, tx: 0, ty: 0 }, m);
  }
  // 4) translation
  m = multiplyMat({ a: 1, b: 0, c: 0, d: 1, tx: ox, ty: oy }, m);
  return m;
}

function ownerOf(shape: Shape, fallbackTop: number): number {
  return shape.ownerCellId !== undefined ? shape.ownerCellId : fallbackTop;
}

function clonePointsTransformed(points: Point[], m: Mat2D): Point[] {
  const out: Point[] = [];
  for (let i = 0; i < points.length; i++) {
    out.push(applyMat(m, points[i].x, points[i].y));
  }
  return out;
}

function transformPathWidth(width: number | undefined, m: Mat2D): number | undefined {
  if (width === undefined) {
    return undefined;
  }
  // 均匀缩放近似：取行列式绝对值的平方根
  const det: number = m.a * m.d - m.b * m.c;
  const scale: number = Math.sqrt(Math.abs(det));
  return width * scale;
}

export interface HierarchySummary {
  bounds?: ShapeBounds;
  shapeCount: number;
  /** TEXT is kept by the existing viewport contract; absolute paths cannot use scaled bounds. */
  uncullable: boolean;
  absolutePathPadding: number;
}

export interface HierarchyBoundsResult {
  ok: boolean;
  bounds?: ShapeBounds;
  shapeCount: number;
  message: string;
}

export interface HierarchyHitResult {
  ok: boolean;
  shapeId: number;
  layerNumber: number;
  datatype: number;
  message: string;
}

export interface HierarchyHitCandidate {
  rootShapeId: number;
  leafShapeId: number;
  rootType: ShapeType;
  leafType: ShapeType;
  layerNumber: number;
  datatype: number;
  path: InstancePathStep[];
  marker: boolean;
}
export interface HierarchyHitOptions {
  maxCandidates?: number;
  maxNodes?: number;
  maxPoints?: number;
  layerNumber?: number;
  datatype?: number;
  types?: ShapeType[];
  includeInstanceMarkers?: boolean;
  leafSelectable?: (shape: Shape) => boolean;
}
export interface HierarchyCandidatesResult {
  ok: boolean;
  candidates: HierarchyHitCandidate[];
  complete: boolean;
  message: string;
}

interface ArrayIndexRange {
  min: number;
  max: number;
}

function polygonContains(points: Point[], x: number, y: number, tolerance: number): boolean {
  if (points.length < 3) return false;
  let inside: boolean = false;
  for (let i: number = 0, j: number = points.length - 1; i < points.length; j = i++) {
    const a: Point = points[j];
    const b: Point = points[i];
    const dx: number = b.x - a.x;
    const dy: number = b.y - a.y;
    const length: number = Math.hypot(dx, dy);
    if (length > 0 && Number.isFinite(length)) {
      const ux: number = dx / length;
      const uy: number = dy / length;
      const along: number = Math.max(0, Math.min(length, (x - a.x) * ux + (y - a.y) * uy));
      if (Math.hypot(x - a.x - along * ux, y - a.y - along * uy) <= tolerance) return true;
    } else if (Math.hypot(x - a.x, y - a.y) <= tolerance) return true;
    if ((a.y > y) !== (b.y > y) && x < a.x + (y - a.y) / (b.y - a.y) * dx) inside = !inside;
  }
  return inside;
}

function mergeBounds(a: ShapeBounds | undefined, b: ShapeBounds): ShapeBounds {
  if (a === undefined) return b;
  return { minX: Math.min(a.minX, b.minX), minY: Math.min(a.minY, b.minY),
    maxX: Math.max(a.maxX, b.maxX), maxY: Math.max(a.maxY, b.maxY) };
}

function transformedBounds(b: ShapeBounds, m: Mat2D): ShapeBounds {
  const corners: Point[] = [applyMat(m, b.minX, b.minY), applyMat(m, b.maxX, b.minY),
    applyMat(m, b.maxX, b.maxY), applyMat(m, b.minX, b.maxY)];
  let minX: number = Infinity, minY: number = Infinity;
  let maxX: number = -Infinity, maxY: number = -Infinity;
  for (const p of corners) {
    minX = Math.min(minX, p.x); minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y);
  }
  return { minX, minY, maxX, maxY };
}

class HierarchyIndex {
  private byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
  private summaries: Map<string, HierarchySummary> = new Map<string, HierarchySummary>();

  constructor(allShapes: Shape[], fallbackTop: number) {
    for (const s of allShapes) {
      const owner: number = ownerOf(s, fallbackTop);
      let shapes: Shape[] | undefined = this.byOwner.get(owner);
      if (shapes === undefined) { shapes = []; this.byOwner.set(owner, shapes); }
      shapes.push(s);
    }
  }

  local(cellId: number): Shape[] { return this.byOwner.get(cellId) ?? []; }

  summary(cellId: number, remainingDepth: number, ancestors: number[] = []): HierarchySummary {
    if (ancestors.indexOf(cellId) >= 0) {
      return { shapeCount: 0, uncullable: true, absolutePathPadding: 0 };
    }
    const key: string = `${cellId}:${remainingDepth}:${ancestors.join(',')}`;
    const cached: HierarchySummary | undefined = this.summaries.get(key);
    if (cached !== undefined) return cached;
    let bounds: ShapeBounds | undefined = undefined;
    let shapeCount: number = 0;
    let uncullable: boolean = false;
    let absolutePathPadding: number = 0;
    const path: number[] = ancestors.concat([cellId]);
    for (const s of this.local(cellId)) {
      if (s.type !== ShapeType.INSTANCE) {
        if (s.points.length === 0) continue;
        bounds = mergeBounds(bounds, getShapeBounds(s));
        shapeCount++;
        uncullable = uncullable || s.type === ShapeType.TEXT || s.pathWidthAbsolute === true;
        if (s.type === ShapeType.PATH && s.pathWidthAbsolute === true) {
          absolutePathPadding = Math.max(absolutePathPadding, Math.abs(s.pathWidth ?? 0) * Math.SQRT2 / 2);
        }
        continue;
      }
      if (remainingDepth <= 0 || s.cellId === undefined || s.cellId < 0) continue;
      const child: HierarchySummary = this.summary(s.cellId, remainingDepth - 1, path);
      const cols: number = Math.max(1, s.arrayCols ?? 1);
      const rows: number = Math.max(1, s.arrayRows ?? 1);
      if (child.shapeCount > 0 && cols * rows > 1000000) throw new Error('阵列展开超过 100 万实例，原始阵列仍完整保留');
      shapeCount += child.shapeCount * cols * rows;
      uncullable = uncullable || child.uncullable;
      absolutePathPadding = Math.max(absolutePathPadding, child.absolutePathPadding);
      if (child.bounds === undefined) continue;
      const m: Mat2D = instanceTransformMat(s);
      const b: ShapeBounds = transformedBounds(child.bounds, m);
      // Absolute WIDTH remains a world width when a child is shrunk.
      const scale: number = Math.sqrt(Math.abs(m.a * m.d - m.b * m.c));
      const pad: number = child.absolutePathPadding * Math.max(0, 1 - scale);
      const cx: number = (cols - 1) * (s.arrayColStepX ?? 0);
      const cy: number = (cols - 1) * (s.arrayColStepY ?? 0);
      const rx: number = (rows - 1) * (s.arrayRowStepX ?? 0);
      const ry: number = (rows - 1) * (s.arrayRowStepY ?? 0);
      bounds = mergeBounds(bounds, { minX: b.minX + Math.min(0, cx) + Math.min(0, rx) - pad,
        minY: b.minY + Math.min(0, cy) + Math.min(0, ry) - pad,
        maxX: b.maxX + Math.max(0, cx) + Math.max(0, rx) + pad,
        maxY: b.maxY + Math.max(0, cy) + Math.max(0, ry) + pad });
    }
    const result: HierarchySummary = { bounds, shapeCount, uncullable, absolutePathPadding };
    this.summaries.set(key, result);
    return result;
  }
}

/** Presentation bounds are independent of the number of painted leaf levels.
 * A stopped reference is one outline around its complete AREF extent. Bounds
 * are combined from definitions, never from an allocated list of members. */
export interface HierarchyDisplaySummary extends HierarchySummary {
  frameCount: number;
}

export class HierarchyReferenceBoundsResolver {
  private index: HierarchyIndex;
  private complete: Map<number, HierarchySummary> = new Map<number, HierarchySummary>();
  private display: Map<string, HierarchyDisplaySummary> = new Map<string, HierarchyDisplaySummary>();
  private visible: (layer: number, datatype: number) => boolean;
  private cellCount: number | undefined;
  private definitionVisits: number = 0;

  constructor(shapes: Shape[], fallbackTop: number,
    visible: (layer: number, datatype: number) => boolean = (): boolean => true, cellCount?: number) {
    if (shapes.length > 1000000) throw new Error('引用范围定义超过 100 万图形预算');
    this.index = new HierarchyIndex(shapes, fallbackTop); this.visible = visible; this.cellCount = cellCount;
  }

  private count(value: number): number {
    if (!Number.isSafeInteger(value) || value < 0 || value > 1000000) throw new Error('引用范围超过 100 万图形预算');
    return value;
  }

  private dimension(value: number | undefined): number {
    // Clip/member extraction encode SREF dimensions as 0. Treat them like
    // omitted dimensions while still rejecting malformed negative/fractional values.
    const count: number = value === undefined || value === 0 ? 1 : value;
    if (!Number.isSafeInteger(count) || count < 1) throw new Error('引用范围阵列或变换无效');
    return count;
  }

  private members(shape: Shape): number {
    const cols: number = this.dimension(shape.arrayCols); const rows: number = this.dimension(shape.arrayRows);
    if (![shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0,
        shape.arrayRowStepY ?? 0, shape.rotation ?? 0, shape.magnification ?? 1].every((n: number): boolean => Number.isFinite(n)) ||
      (shape.magnification ?? 1) <= 0 || !Number.isSafeInteger(cols * rows)) throw new Error('引用范围阵列或变换无效');
    return cols * rows;
  }

  private referenceCell(shape: Shape): number {
    const id: number = shape.cellId ?? -1;
    if (!Number.isInteger(id) || id < 0 || (this.cellCount !== undefined && id >= this.cellCount)) throw new Error('引用范围 Cell 无效');
    return id;
  }

  private mapped(shape: Shape, child: HierarchySummary): ShapeBounds | undefined {
    this.members(shape);
    if (child.bounds === undefined) return undefined;
    const m: Mat2D = instanceTransformMat(shape); const b: ShapeBounds = transformedBounds(child.bounds, m);
    const scale: number = Math.sqrt(Math.abs(m.a * m.d - m.b * m.c));
    const pad: number = child.absolutePathPadding * Math.max(0, 1 - scale);
    const cols: number = this.dimension(shape.arrayCols), rows: number = this.dimension(shape.arrayRows);
    const cx: number = (cols - 1) * (shape.arrayColStepX ?? 0);
    const cy: number = (cols - 1) * (shape.arrayColStepY ?? 0);
    const rx: number = (rows - 1) * (shape.arrayRowStepX ?? 0);
    const ry: number = (rows - 1) * (shape.arrayRowStepY ?? 0);
    const out: ShapeBounds = { minX: b.minX + Math.min(0, cx) + Math.min(0, rx) - pad,
      minY: b.minY + Math.min(0, cy) + Math.min(0, ry) - pad,
      maxX: b.maxX + Math.max(0, cx) + Math.max(0, rx) + pad,
      maxY: b.maxY + Math.max(0, cy) + Math.max(0, ry) + pad };
    if (![out.minX, out.minY, out.maxX, out.maxY].every((n: number): boolean => Number.isFinite(n))) throw new Error('引用范围坐标溢出');
    return out;
  }

  private leaf(shape: Shape): boolean {
    return shape.type !== ShapeType.NODE && shape.points.length > 0 && this.visible(shape.layerNumber, shape.datatype) &&
      (shape.type !== ShapeType.TEXT || (shape.text ?? '').length > 0);
  }

  private completeCell(cellId: number, ancestors: number[]): HierarchySummary {
    if (ancestors.indexOf(cellId) >= 0) throw new Error('引用范围包含循环实例');
    if (ancestors.length >= 32) throw new Error('完整引用范围超过 32 层预算');
    const cached: HierarchySummary | undefined = this.complete.get(cellId); if (cached !== undefined) return cached;
    let bounds: ShapeBounds | undefined; let shapeCount: number = 0; let absolutePathPadding: number = 0;
    for (const shape of this.index.local(cellId)) {
      if (++this.definitionVisits > 1000000) throw new Error('引用范围定义超过 100 万图形预算');
      if (shape.type === ShapeType.INSTANCE) {
        const child: HierarchySummary = this.completeCell(this.referenceCell(shape), ancestors.concat([cellId]));
        shapeCount = this.count(shapeCount + this.count(child.shapeCount * this.members(shape)));
        const b: ShapeBounds | undefined = this.mapped(shape, child); if (b !== undefined) bounds = mergeBounds(bounds, b);
        absolutePathPadding = Math.max(absolutePathPadding, child.absolutePathPadding);
      } else if (this.leaf(shape)) {
        bounds = mergeBounds(bounds, getShapeBounds(shape)); shapeCount = this.count(shapeCount + 1);
        if (shape.type === ShapeType.PATH && shape.pathWidthAbsolute === true) {
          absolutePathPadding = Math.max(absolutePathPadding, Math.abs(shape.pathWidth ?? 0) * Math.SQRT2 / 2);
        }
      }
    }
    const result: HierarchySummary = { bounds, shapeCount, uncullable: false, absolutePathPadding };
    this.complete.set(cellId, result); return result;
  }

  summaryForInstance(shape: Shape): HierarchySummary {
    const child: HierarchySummary = this.completeCell(this.referenceCell(shape), []);
    const shapeCount: number = this.count(child.shapeCount * this.members(shape));
    return { bounds: this.mapped(shape, child), shapeCount, absolutePathPadding: child.absolutePathPadding, uncullable: false };
  }

  boundsForInstance(shape: Shape): ShapeBounds | undefined {
    return this.summaryForInstance(shape).bounds;
  }

  summary(cellId: number, hierarchyDepth: number, ancestors: number[] = []): HierarchyDisplaySummary {
    if (ancestors.indexOf(cellId) >= 0) throw new Error('显示范围包含循环实例');
    const key: string = `${cellId}:${hierarchyDepth}`;
    const cached: HierarchyDisplaySummary | undefined = this.display.get(key); if (cached !== undefined) return cached;
    let bounds: ShapeBounds | undefined; let shapeCount: number = 0; let frameCount: number = 0; let absolutePathPadding: number = 0;
    for (const shape of this.index.local(cellId)) {
      if (shape.type === ShapeType.INSTANCE) {
        if (hierarchyDepth <= 1) {
          const reference: HierarchySummary = this.summaryForInstance(shape);
          const b: ShapeBounds | undefined = reference.bounds;
          if (b !== undefined) { bounds = mergeBounds(bounds, b); frameCount = this.count(frameCount + 1); }
          absolutePathPadding = Math.max(absolutePathPadding, reference.absolutePathPadding);
        } else {
          const child: HierarchyDisplaySummary = this.summary(this.referenceCell(shape), hierarchyDepth - 1, ancestors.concat([cellId]));
          const n: number = this.members(shape);
          shapeCount = this.count(shapeCount + this.count(child.shapeCount * n)); frameCount = this.count(frameCount + this.count(child.frameCount * n));
          const b: ShapeBounds | undefined = this.mapped(shape, child); if (b !== undefined) bounds = mergeBounds(bounds, b);
          absolutePathPadding = Math.max(absolutePathPadding, child.absolutePathPadding);
        }
      } else if (this.leaf(shape)) {
        bounds = mergeBounds(bounds, getShapeBounds(shape)); shapeCount = this.count(shapeCount + 1);
        if (shape.type === ShapeType.PATH && shape.pathWidthAbsolute === true) absolutePathPadding =
          Math.max(absolutePathPadding, Math.abs(shape.pathWidth ?? 0) * Math.SQRT2 / 2);
      }
    }
    const result: HierarchyDisplaySummary = { bounds, shapeCount, frameCount, uncullable: false, absolutePathPadding };
    this.display.set(key, result); return result;
  }
}

/** Fit the same leaves and stopped-reference frames that the scene displays. */
export function summarizeCellDisplayShapes(allShapes: Shape[], rootCellId: number, hierarchyDepth: number,
  visible: (layer: number, datatype: number) => boolean = (): boolean => true): HierarchyDisplaySummary {
  const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth)));
  return new HierarchyReferenceBoundsResolver(allShapes, rootCellId, visible).summary(rootCellId, depth);
}

/** Visible geometry bounds for editing: no markers, LOD boxes, or rotated child bboxes.
 * Reuse one resolver per revision/operation. AREF offsets are combined analytically.
 */
export class HierarchyBoundsResolver {
  private index: HierarchyIndex;
  private cache: Map<string, HierarchyBoundsResult> = new Map<string, HierarchyBoundsResult>();
  private visitedShapes: number = 0;
  private visitedPoints: number = 0;
  private visible: (layer: number, datatype: number) => boolean;
  private maxShapes: number;
  private maxPoints: number;
  private hitNodes: number = 0;
  private hitPoints: number = 0;
  private hitNodeLimit: number = 100000;
  private hitPointLimit: number = 400000;
  private candidateLimit: number = 64;
  private candidateOverflow: boolean = false;
  private textGeometry: SceneTextGeometryService;

  constructor(shapes: Shape[], fallbackTop: number, visible: (layer: number, datatype: number) => boolean,
    maxShapes: number = 1000000, maxPoints: number = 4000000,
    measureTextWidth: (text: string) => number = (text: string): number => text.length * 24) {
    this.index = new HierarchyIndex(shapes, fallbackTop);
    this.visible = visible;
    this.maxShapes = maxShapes;
    this.maxPoints = maxPoints;
    this.textGeometry = new SceneTextGeometryService(instanceTransformMat, measureTextWidth);
  }

  boundsForShape(shape: Shape, hierarchyDepth: number): HierarchyBoundsResult {
    const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth)));
    return this.shapeBounds(shape, identityMat(), depth - 1, []);
  }

  /** Start one complete-geometry request; cached exact bounds remain reusable. */
  beginCompleteBoundsRequest(): void {
    this.visitedShapes = 0;
    this.visitedPoints = 0;
  }

  /** Complete document geometry: Workspace validates at most 256 reference
   * levels. Display depth remains unchanged in boundsForShape. */
  completeBoundsForShape(shape: Shape): HierarchyBoundsResult {
    return this.shapeBounds(shape, identityMat(), 257, []);
  }

  /** Bounded painted-contour candidates. A truncated list is explicit; a budget failure returns no partial selection. */
  hitCandidatesCell(cellId: number, hierarchyDepth: number, x: number, y: number, tolerance: number,
    selectable: (shape: Shape) => boolean, options: HierarchyHitOptions = {}): HierarchyCandidatesResult {
    this.hitNodes = 0; this.hitPoints = 0; this.candidateOverflow = false;
    this.hitNodeLimit = options.maxNodes ?? 100000; this.hitPointLimit = options.maxPoints ?? 400000;
    this.candidateLimit = options.maxCandidates ?? 64;
    const candidates: HierarchyHitCandidate[] = [];
    try {
      if (![x, y, tolerance, hierarchyDepth].every((n: number) => Number.isFinite(n)) || tolerance < 0 ||
        !Number.isInteger(this.candidateLimit) || this.candidateLimit < 1 || this.candidateLimit > 512 ||
        !Number.isInteger(this.hitNodeLimit) || this.hitNodeLimit < 1 ||
        !Number.isInteger(this.hitPointLimit) || this.hitPointLimit < 1) throw new Error('候选查询参数无效');
      const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth))) - 1;
      const local: Shape[] = this.index.local(cellId);
      for (let i: number = local.length - 1; i >= 0 && !this.candidateOverflow; i--) {
        const root: Shape = local[i]; if (!selectable(root)) continue;
        const before: number = candidates.length;
        this.collectHitCandidates(root, root, identityMat(), identityMat(), depth, [cellId], x, y, tolerance, [], options, candidates);
        if (before === candidates.length && !this.candidateOverflow && options.includeInstanceMarkers !== false &&
          root.type === ShapeType.INSTANCE && depth > 0 && root.points.length > 0 &&
          Math.abs(x - root.points[0].x) <= 10 + tolerance && Math.abs(y - root.points[0].y) <= 10 + tolerance) {
          const matrix: Mat2D = instanceTransformMat(root);
          const markerTransform: InstancePathTransform = { a: matrix.a, b: matrix.b, c: matrix.c,
            d: matrix.d, tx: matrix.tx, ty: matrix.ty };
          const markerStep: InstancePathStep = { parentCellId: cellId, cellId: root.cellId ?? -1,
            instanceId: root.id, row: 0, col: 0, transform: markerTransform };
          this.appendHitCandidate(root, root, [markerStep], true, options, candidates);
        }
      }
      return { ok: true, candidates: candidates, complete: !this.candidateOverflow,
        message: this.candidateOverflow ? `命中超过 ${this.candidateLimit} 项，请按图层或类型过滤` : '' };
    } catch (error) { return { ok: false, candidates: [], complete: false, message: String(error) }; }
  }

  private appendHitCandidate(root: Shape, leaf: Shape, path: InstancePathStep[], marker: boolean,
    options: HierarchyHitOptions, result: HierarchyHitCandidate[]): void {
    if (options.layerNumber !== undefined && options.layerNumber >= 0 &&
      (leaf.layerNumber !== options.layerNumber || (options.datatype !== undefined && leaf.datatype !== options.datatype))) return;
    if (options.types !== undefined && options.types.length > 0 && options.types.indexOf(leaf.type) < 0 &&
      options.types.indexOf(root.type) < 0) return;
    if (options.leafSelectable !== undefined && !options.leafSelectable(leaf)) return;
    if (result.length >= this.candidateLimit) { this.candidateOverflow = true; return; }
    result.push({ rootShapeId: root.id, leafShapeId: leaf.id, rootType: root.type, leafType: leaf.type,
      layerNumber: leaf.layerNumber, datatype: leaf.datatype, path: path, marker: marker });
  }

  private collectHitCandidates(shape: Shape, root: Shape, linear: Mat2D, full: Mat2D, depth: number,
    ancestors: number[], x: number, y: number, tolerance: number, path: InstancePathStep[],
    options: HierarchyHitOptions, result: HierarchyHitCandidate[]): void {
    if (this.candidateOverflow) return;
    if (++this.hitNodes > this.hitNodeLimit) throw new Error('候选查询超过节点预算，请放大或降低层级');
    if (shape.type !== ShapeType.INSTANCE) {
      const hit: HierarchyHitResult = this.hitShape(shape, linear, depth, ancestors, x, y, tolerance);
      if (!hit.ok) throw new Error(hit.message);
      if (hit.shapeId >= 0) this.appendHitCandidate(root, shape, path, false, options, result);
      return;
    }
    if (depth <= 0) return;
    const whole: HierarchyBoundsResult = this.shapeBounds(shape, linear, depth, ancestors);
    if (!whole.ok) throw new Error(whole.message);
    if (whole.bounds === undefined || !this.pointNearBounds(whole.bounds, x, y, tolerance + 16)) return;
    const cell: number = shape.cellId ?? -1;
    if (ancestors.indexOf(cell) >= 0) throw new Error('实例包含循环引用，未改变选择');
    const m: Mat2D = multiplyMat(linear, instanceTransformMat(shape));
    const childLinear: Mat2D = { a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0 };
    const bounds: HierarchyBoundsResult = this.cellBounds(cell, childLinear, depth - 1, ancestors);
    if (!bounds.ok) throw new Error(bounds.message);
    if (bounds.bounds === undefined) return;
    const qx: number = x - m.tx; const qy: number = y - m.ty; const pad: number = tolerance + 16;
    const col: Point = applyMat(linear, shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0);
    const row: Point = applyMat(linear, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0);
    const cols: number = Math.max(1, shape.arrayCols ?? 1); const rows: number = Math.max(1, shape.arrayRows ?? 1);
    const shifts: ShapeBounds = { minX: qx - bounds.bounds.maxX - pad, maxX: qx - bounds.bounds.minX + pad,
      minY: qy - bounds.bounds.maxY - pad, maxY: qy - bounds.bounds.minY + pad };
    let cr: ArrayIndexRange = { min: 0, max: cols - 1 }; let rr: ArrayIndexRange = { min: 0, max: rows - 1 };
    const det: number = col.x * row.y - row.x * col.y;
    const scale: number = Math.hypot(col.x, col.y) * Math.hypot(row.x, row.y);
    if (cols > 1 && rows > 1 && Number.isFinite(det) && Math.abs(det) > scale * 1e-12) {
      const range: ShapeBounds = transformedBounds(shifts, { a: row.y / det, b: -row.x / det,
        c: -col.y / det, d: col.x / det, tx: 0, ty: 0 });
      cr = this.clippedRange(range.minX, range.maxX, cols); rr = this.clippedRange(range.minY, range.maxY, rows);
    } else { cr = this.projectedArrayRange(shifts, col, row, rows, cols); rr = this.projectedArrayRange(shifts, row, col, cols, rows); }
    const children: Shape[] = this.index.local(cell);
    for (let r: number = rr.max; r >= rr.min && !this.candidateOverflow; r--) {
      for (let c: number = cr.max; c >= cr.min && !this.candidateOverflow; c--) {
        if (++this.hitNodes > this.hitNodeLimit) throw new Error('阵列候选查询超过预算，请按层或类型过滤');
        const px: number = qx - c * col.x - r * row.x; const py: number = qy - c * col.y - r * row.y;
        if (!this.pointNearBounds(bounds.bounds, px, py, pad)) continue;
        const member: Mat2D = instanceTransformMat(shape);
        member.tx += c * (shape.arrayColStepX ?? 0) + r * (shape.arrayRowStepX ?? 0);
        member.ty += c * (shape.arrayColStepY ?? 0) + r * (shape.arrayRowStepY ?? 0);
        const world: Mat2D = multiplyMat(full, member);
        const nextTransform: InstancePathTransform = { a: world.a, b: world.b, c: world.c,
          d: world.d, tx: world.tx, ty: world.ty };
        const nextStep: InstancePathStep = { parentCellId: ancestors[ancestors.length - 1],
          cellId: cell, instanceId: shape.id, row: r, col: c, transform: nextTransform };
        const nextPath: InstancePathStep[] = path.concat([nextStep]);
        for (let i: number = children.length - 1; i >= 0 && !this.candidateOverflow; i--) {
          this.collectHitCandidates(children[i], root, childLinear, world, depth - 1, ancestors.concat([cell]),
            px, py, tolerance, nextPath, options, result);
        }
      }
    }
  }

  /** Return the current Cell's root object, never a synthetic/child ID. Bounds
   * only prune candidates; each accepted leaf must pass a painted contour test. */
  hitTestCell(cellId: number, hierarchyDepth: number, x: number, y: number, tolerance: number,
    selectable: (shape: Shape) => boolean, includeInstanceMarkers: boolean = true,
    maxNodes: number = 100000, maxPoints: number = 400000): HierarchyHitResult {
    this.hitNodes = 0;
    this.hitPoints = 0;
    this.hitNodeLimit = maxNodes;
    this.hitPointLimit = maxPoints;
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(tolerance) || tolerance < 0 ||
      !Number.isFinite(hierarchyDepth) || !Number.isFinite(maxNodes) || !Number.isFinite(maxPoints) ||
      maxNodes < 1 || maxPoints < 1) return this.hitFailure('命中测试参数无效');
    const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth))) - 1;
    const local: Shape[] = this.index.local(cellId);
    for (let i: number = local.length - 1; i >= 0; i--) {
      if (++this.hitNodes > this.hitNodeLimit) return this.hitFailure('实例命中超过查询预算，请放大或降低显示层级');
      const shape: Shape = local[i];
      if (!selectable(shape)) continue;
      const result: HierarchyHitResult = this.hitShape(shape, identityMat(), depth, [cellId], x, y, tolerance);
      if (!result.ok) return result;
      if (result.shapeId >= 0) {
        result.shapeId = shape.id;
        return result;
      }
      // The explicitly drawn root marker remains an entry point for empty Cells.
      // Geometry failures above never degrade into an anchor/bbox success.
      if (includeInstanceMarkers && depth > 0 && shape.type === ShapeType.INSTANCE && shape.points.length > 0 &&
        Math.abs(x - shape.points[0].x) <= 10 + tolerance && Math.abs(y - shape.points[0].y) <= 10 + tolerance) {
        return { ok: true, shapeId: shape.id, layerNumber: shape.layerNumber, datatype: shape.datatype, message: '' };
      }
    }
    return this.noHit();
  }

  private noHit(): HierarchyHitResult {
    return { ok: true, shapeId: -1, layerNumber: -1, datatype: 0, message: '' };
  }

  private hitFailure(message: string): HierarchyHitResult {
    return { ok: false, shapeId: -1, layerNumber: -1, datatype: 0, message: message };
  }

  private pointNearBounds(b: ShapeBounds, x: number, y: number, tolerance: number): boolean {
    return x >= b.minX - tolerance && x <= b.maxX + tolerance && y >= b.minY - tolerance && y <= b.maxY + tolerance;
  }

  private hitShape(shape: Shape, linear: Mat2D, depth: number, ancestors: number[],
    x: number, y: number, tolerance: number): HierarchyHitResult {
    if (shape.type === ShapeType.NODE || (shape.type !== ShapeType.INSTANCE && !this.visible(shape.layerNumber, shape.datatype))) return this.noHit();
    if (shape.type === ShapeType.INSTANCE) return this.hitInstance(shape, linear, depth, ancestors, x, y, tolerance);
    if (shape.points.length === 0 || (shape.type === ShapeType.RECT && shape.points.length < 2)) return this.noHit();
    const isIdentity: boolean = linear.a === 1 && linear.b === 0 && linear.c === 0 && linear.d === 1 &&
      linear.tx === 0 && linear.ty === 0;
    if (shape.type === ShapeType.TEXT) {
      this.hitPoints += shape.points.length;
      if (this.hitPoints > this.hitPointLimit) return this.hitFailure('实例命中超过顶点预算，请降低显示层级');
      const glyph: HierarchyBoundsResult = this.textBounds(shape, linear);
      if (!glyph.ok || glyph.bounds === undefined) return this.hitFailure(glyph.message);
      const rawAnchor: ShapeBounds = getShapeBounds(shape);
      const anchor: ShapeBounds = isIdentity ? rawAnchor : transformedBounds(rawAnchor, linear);
      if (!this.checked(anchor, 1).ok) return this.hitFailure('文字锚点坐标越界，未更改选择');
      if (!this.pointNearBounds(glyph.bounds, x, y, tolerance) &&
          !this.pointNearBounds(anchor, x, y, tolerance + 16)) return this.noHit();
      return { ok: true, shapeId: shape.id, layerNumber: shape.layerNumber, datatype: shape.datatype, message: '' };
    }
    let bounds: ShapeBounds;
    if (shape.type === ShapeType.PATH) {
      const pathBounds: ShapeBounds | undefined = getPathGeometryBounds(shape,
        { a: linear.a, b: linear.b, c: linear.c, d: linear.d, tx: 0, ty: 0 });
      if (pathBounds === undefined) return this.noHit();
      bounds = pathBounds;
    } else {
      const rawBounds: ShapeBounds = getShapeBounds(shape);
      bounds = isIdentity ? rawBounds : transformedBounds(rawBounds, linear);
    }
    if (!this.checked(bounds, 1).ok) return this.hitFailure('实例轮廓坐标越界，未更改选择');
    const pad: number = tolerance;
    if (!this.pointNearBounds(bounds, x, y, pad)) return this.noHit();
    // 仅对包围盒命中的候选图形计入精确轮廓测试顶点预算，避免百万顶点版图空点/选图时被远处多边形耗尽预算
    this.hitPoints += shape.points.length;
    if (this.hitPoints > this.hitPointLimit) return this.hitFailure('实例命中超过顶点预算，请降低显示层级');
    let hit: boolean = false;
    if (shape.type === ShapeType.PATH) {
      hit = pathGeometryContains(shape, x, y, tolerance,
        { a: linear.a, b: linear.b, c: linear.c, d: linear.d, tx: 0, ty: 0 });
    } else if (shape.type === ShapeType.RECT && isIdentity) {
      hit = true; // pointNearBounds 已精确覆盖轴对齐矩形本体与容差带
    } else {
      let points: Point[] = shape.points;
      if (shape.type === ShapeType.RECT) {
        const b: ShapeBounds = getShapeBounds(shape);
        points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY },
          { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }];
      }
      const testPoints: Point[] = isIdentity ? points : clonePointsTransformed(points, linear);
      hit = polygonContains(testPoints, x, y, tolerance);
    }
    return hit ? { ok: true, shapeId: shape.id, layerNumber: shape.layerNumber, datatype: shape.datatype, message: '' } : this.noHit();
  }

  private hitCell(cellId: number, linear: Mat2D, depth: number, ancestors: number[],
    x: number, y: number, tolerance: number): HierarchyHitResult {
    if (ancestors.indexOf(cellId) >= 0) return this.hitFailure('实例包含循环引用，未更改选择');
    const local: Shape[] = this.index.local(cellId);
    const path: number[] = ancestors.concat([cellId]);
    for (let i: number = local.length - 1; i >= 0; i--) {
      if (++this.hitNodes > this.hitNodeLimit) return this.hitFailure('实例命中超过查询预算，请放大或降低显示层级');
      const result: HierarchyHitResult = this.hitShape(local[i], linear, depth, path, x, y, tolerance);
      if (!result.ok || result.shapeId >= 0) return result;
    }
    return this.noHit();
  }

  private hitInstance(shape: Shape, linear: Mat2D, depth: number, ancestors: number[],
    x: number, y: number, tolerance: number): HierarchyHitResult {
    if (depth <= 0) return this.noHit();
    const whole: HierarchyBoundsResult = this.shapeBounds(shape, linear, depth, ancestors);
    if (!whole.ok) return this.hitFailure(whole.message);
    if (whole.bounds === undefined || !this.pointNearBounds(whole.bounds, x, y, tolerance + 16)) return this.noHit();
    const cellId: number = shape.cellId ?? -1;
    const m: Mat2D = multiplyMat(linear, instanceTransformMat(shape));
    const childLinear: Mat2D = { a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0 };
    const child: HierarchyBoundsResult = this.cellBounds(cellId, childLinear, depth - 1, ancestors);
    if (!child.ok) return this.hitFailure(child.message);
    if (child.bounds === undefined) return this.noHit();
    const qx: number = x - m.tx;
    const qy: number = y - m.ty;
    const col: Point = applyMat(linear, shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0);
    const row: Point = applyMat(linear, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0);
    const cols: number = col.x === 0 && col.y === 0 ? 1 : Math.max(1, shape.arrayCols ?? 1);
    const rows: number = row.x === 0 && row.y === 0 ? 1 : Math.max(1, shape.arrayRows ?? 1);
    // The possible lattice translations form q - childBounds. Expand only for
    // pointer tolerance / legacy text anchors, never turn this box into a hit.
    const pad: number = tolerance + 16;
    const shifts: ShapeBounds = { minX: qx - child.bounds.maxX - pad, maxX: qx - child.bounds.minX + pad,
      minY: qy - child.bounds.maxY - pad, maxY: qy - child.bounds.minY + pad };
    let colRange: ArrayIndexRange = { min: 0, max: cols - 1 };
    let rowRange: ArrayIndexRange = { min: 0, max: rows - 1 };
    const determinant: number = col.x * row.y - row.x * col.y;
    const scale: number = Math.hypot(col.x, col.y) * Math.hypot(row.x, row.y);
    if (cols > 1 && rows > 1 && Number.isFinite(determinant) && Math.abs(determinant) > scale * 1e-12) {
      const inverse: Mat2D = { a: row.y / determinant, b: -row.x / determinant,
        c: -col.y / determinant, d: col.x / determinant, tx: 0, ty: 0 };
      const candidates: ShapeBounds = transformedBounds(shifts, inverse);
      colRange = this.clippedRange(candidates.minX, candidates.maxX, cols);
      rowRange = this.clippedRange(candidates.minY, candidates.maxY, rows);
    } else {
      colRange = this.projectedArrayRange(shifts, col, row, rows, cols);
      rowRange = this.projectedArrayRange(shifts, row, col, cols, rows);
    }
    for (let r: number = rowRange.max; r >= rowRange.min; r--) {
      for (let c: number = colRange.max; c >= colRange.min; c--) {
        if (++this.hitNodes > this.hitNodeLimit) return this.hitFailure('阵列命中超过候选预算，请放大或降低显示层级');
        const px: number = qx - c * col.x - r * row.x;
        const py: number = qy - c * col.y - r * row.y;
        if (!this.pointNearBounds(child.bounds, px, py, pad)) continue;
        const result: HierarchyHitResult = this.hitCell(cellId, childLinear, depth - 1, ancestors, px, py, tolerance);
        if (!result.ok || result.shapeId >= 0) return result;
      }
    }
    return this.noHit();
  }

  private clippedRange(min: number, max: number, count: number): ArrayIndexRange {
    return { min: Math.max(0, Math.ceil(min - 1e-9)), max: Math.min(count - 1, Math.floor(max + 1e-9)) };
  }

  private projectedArrayRange(shifts: ShapeBounds, step: Point, other: Point, otherCount: number, count: number): ArrayIndexRange {
    let min: number = 0;
    let max: number = count - 1;
    const axes: Point[] = [{ x: step.x, y: other.x * (otherCount - 1) }, { x: step.y, y: other.y * (otherCount - 1) }];
    for (let axis: number = 0; axis < 2; axis++) {
      const lo: number = (axis === 0 ? shifts.minX : shifts.minY) - Math.max(0, axes[axis].y);
      const hi: number = (axis === 0 ? shifts.maxX : shifts.maxY) - Math.min(0, axes[axis].y);
      const delta: number = axes[axis].x;
      if (delta === 0) {
        if (lo > 0 || hi < 0) return { min: 1, max: 0 };
      } else {
        min = Math.max(min, Math.min(lo / delta, hi / delta));
        max = Math.min(max, Math.max(lo / delta, hi / delta));
      }
    }
    return this.clippedRange(min, max, count);
  }

  private failure(message: string): HierarchyBoundsResult {
    return { ok: false, shapeCount: 0, message: message };
  }

  private textBounds(shape: Shape, linear: Mat2D): HierarchyBoundsResult {
    try {
      return this.checked(this.textGeometry.boundsForShape(shape,
        { a: linear.a, b: linear.b, c: linear.c, d: linear.d, tx: linear.tx, ty: linear.ty }), 1);
    } catch (error) { return this.failure(`文字轮廓无法计算：${error}`); }
  }

  private cellBounds(cellId: number, linear: Mat2D, depth: number, ancestors: number[]): HierarchyBoundsResult {
    if (ancestors.indexOf(cellId) >= 0) return this.failure('实例包含循环引用，未更改选择或图形');
    const key: string = `${cellId}:${depth}:${linear.a}:${linear.b}:${linear.c}:${linear.d}:${ancestors.join(',')}`;
    const cached: HierarchyBoundsResult | undefined = this.cache.get(key);
    if (cached !== undefined) return cached;
    let bounds: ShapeBounds | undefined = undefined;
    let count: number = 0;
    const path: number[] = ancestors.concat([cellId]);
    for (const shape of this.index.local(cellId)) {
      this.visitedShapes++;
      if (this.visitedShapes > this.maxShapes) return this.failure('实例范围计算超过图形预算，请降低显示层级后重试');
      const result: HierarchyBoundsResult = this.shapeBounds(shape, linear, depth, path);
      if (!result.ok) return result;
      count += result.shapeCount;
      if (count > this.maxShapes) return this.failure('实例展开超过图形预算，请降低显示层级后重试');
      if (result.bounds !== undefined) bounds = mergeBounds(bounds, result.bounds);
    }
    const result: HierarchyBoundsResult = { ok: true, bounds: bounds, shapeCount: count, message: '' };
    this.cache.set(key, result);
    return result;
  }

  private shapeBounds(shape: Shape, linear: Mat2D, depth: number, ancestors: number[]): HierarchyBoundsResult {
    if (shape.type === ShapeType.NODE || (shape.type !== ShapeType.INSTANCE && !this.visible(shape.layerNumber, shape.datatype))) {
      return { ok: true, shapeCount: 0, message: '' };
    }
    if (shape.type === ShapeType.INSTANCE) {
      if (depth <= 0) return { ok: true, shapeCount: 0, message: '' };
      if (shape.cellId === undefined || !Number.isInteger(shape.cellId) || shape.cellId < 0) return this.failure('实例引用无效，无法计算可见范围');
      // Native SREF snapshots use zero for both absent COLROW values.
      const cols: number = shape.arrayCols === 0 ? 1 : (shape.arrayCols ?? 1);
      const rows: number = shape.arrayRows === 0 ? 1 : (shape.arrayRows ?? 1);
      if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols <= 0 || rows <= 0 || cols * rows > this.maxShapes) {
        return this.failure('实例阵列超过范围计算预算，请降低阵列数量');
      }
      const m: Mat2D = multiplyMat(linear, instanceTransformMat(shape));
      const childLinear: Mat2D = { a: m.a, b: m.b, c: m.c, d: m.d, tx: 0, ty: 0 };
      const child: HierarchyBoundsResult = this.cellBounds(shape.cellId, childLinear, depth - 1, ancestors);
      if (!child.ok) return child;
      const count: number = child.shapeCount * cols * rows;
      if (count > this.maxShapes) return this.failure('实例展开超过图形预算，请降低显示层级后重试');
      if (child.bounds === undefined) return { ok: true, shapeCount: count, message: '' };
      const col: Point = applyMat(linear, (cols - 1) * (shape.arrayColStepX ?? 0), (cols - 1) * (shape.arrayColStepY ?? 0));
      const row: Point = applyMat(linear, (rows - 1) * (shape.arrayRowStepX ?? 0), (rows - 1) * (shape.arrayRowStepY ?? 0));
      const bounds: ShapeBounds = {
        minX: child.bounds.minX + m.tx + Math.min(0, col.x) + Math.min(0, row.x),
        minY: child.bounds.minY + m.ty + Math.min(0, col.y) + Math.min(0, row.y),
        maxX: child.bounds.maxX + m.tx + Math.max(0, col.x) + Math.max(0, row.x),
        maxY: child.bounds.maxY + m.ty + Math.max(0, col.y) + Math.max(0, row.y)
      };
      return this.checked(bounds, count);
    }
    if (shape.points.length === 0) return { ok: true, shapeCount: 0, message: '' };
    this.visitedPoints += shape.points.length;
    if (this.visitedPoints > this.maxPoints) return this.failure('实例范围计算超过顶点预算，请降低显示层级后重试');
    if (shape.type === ShapeType.TEXT) return this.textBounds(shape, linear);
    if (shape.type === ShapeType.PATH) {
      const bounds: ShapeBounds | undefined = getPathGeometryBounds(shape,
        { a: linear.a, b: linear.b, c: linear.c, d: linear.d, tx: linear.tx, ty: linear.ty });
      return bounds === undefined ? { ok: true, shapeCount: 0, message: '' } : this.checked(bounds, 1);
    }
    let points: Point[] = shape.points;
    if (shape.type === ShapeType.RECT) {
      const b: ShapeBounds = getShapeBounds(shape);
      points = [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY },
        { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }];
    }
    const leaf: Shape = { id: shape.id, type: shape.type === ShapeType.RECT ? ShapeType.POLYGON : shape.type,
      layerNumber: shape.layerNumber, datatype: shape.datatype, selected: false,
      points: clonePointsTransformed(points, linear) };
    return this.checked(getShapeBounds(leaf), 1);
  }

  private checked(bounds: ShapeBounds, count: number): HierarchyBoundsResult {
    if (!Number.isFinite(bounds.minX) || !Number.isFinite(bounds.minY) ||
      !Number.isFinite(bounds.maxX) || !Number.isFinite(bounds.maxY)) return this.failure('实例变换坐标越界，未更改选择或图形');
    return { ok: true, bounds: bounds, shapeCount: count, message: '' };
  }
}

/** Fit a hierarchy using definition bounds and array extents, without allocating each copy. */
export function summarizeCellShapes(allShapes: Shape[], rootCellId: number,
  hierarchyDepth: number, includeInstanceMarkers: boolean = true): HierarchySummary {
  const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth)));
  const index: HierarchyIndex = new HierarchyIndex(allShapes, rootCellId);
  const summary: HierarchySummary = index.summary(rootCellId, depth - 1);
  let bounds: ShapeBounds | undefined = summary.bounds;
  let shapeCount: number = summary.shapeCount;
  if (includeInstanceMarkers && depth >= 2) {
    for (const s of index.local(rootCellId)) {
      if (s.type === ShapeType.INSTANCE && s.points.length > 0) {
        bounds = mergeBounds(bounds, getShapeBounds(s)); shapeCount++;
      }
    }
  }
  return { bounds, shapeCount, uncullable: summary.uncullable, absolutePathPadding: summary.absolutePathPadding };
}

/**
 * 从 rootCellId 出发，按 hierarchyDepth 展开可见几何。
 * @param allShapes 全库扁平 shapes（含各 Cell 本地图与 INSTANCE）
 * @param rootCellId 当前浏览/编辑上下文 Cell
 * @param hierarchyDepth UI 层级 1–32（32 为“全部层级”，映射 maxDepth = depth-1）
 * @param includeInstanceMarkers depth>=2 时附带当前 Cell 的 INSTANCE 框（双击进入子 Cell）
 */
export function expandCellShapes(
  allShapes: Shape[],
  rootCellId: number,
  hierarchyDepth: number,
  includeInstanceMarkers: boolean = true,
  viewport?: WorldViewport,
  maxResults: number = Number.POSITIVE_INFINITY
): Shape[] {
  const depth: number = Math.max(1, Math.min(32, Math.round(hierarchyDepth)));
  const maxDepth: number = depth - 1;
  const result: Shape[] = [];
  const resultLimit: number = Number.isFinite(maxResults) ? Math.max(0, Math.floor(maxResults)) : Number.POSITIVE_INFINITY;
  let nextSynthId: number = EXPANDED_SHAPE_ID_BASE;
  /** 路径上的 cellId，用于切断循环引用 */
  const visiting: number[] = [];
  const index: HierarchyIndex = new HierarchyIndex(allShapes, rootCellId);

  const emitLocal = (cellId: number, parentMat: Mat2D, currentDepth: number): void => {
    if (currentDepth > maxDepth || result.length >= resultLimit) {
      return;
    }
    for (let v = 0; v < visiting.length; v++) {
      if (visiting[v] === cellId) {
        return;
      }
    }
    visiting.push(cellId);
    if (viewport !== undefined) {
      const summary: HierarchySummary = index.summary(cellId, maxDepth - currentDepth, visiting.slice(0, -1));
      if (!summary.uncullable && summary.bounds !== undefined &&
        !boundsIntersects(transformedBounds(summary.bounds, parentMat), viewport)) {
        visiting.pop();
        return;
      }
    }
    const localShapes: Shape[] = index.local(cellId);
    for (let i = 0; i < localShapes.length && result.length < resultLimit; i++) {
      const s: Shape = localShapes[i];
      if (s.type === ShapeType.INSTANCE) {
        if (currentDepth >= maxDepth) {
          continue;
        }
        const childId: number = s.cellId !== undefined ? s.cellId : -1;
        if (childId < 0) {
          continue;
        }
        const instMat: Mat2D = instanceTransformMat(s);
        const cols: number = Math.max(1, s.arrayCols ?? 1);
        const rows: number = Math.max(1, s.arrayRows ?? 1);
        if (cols * rows > 1000000) throw new Error('阵列展开超过 100 万实例，原始阵列仍完整保留');
        for (let row: number = 0; row < rows && result.length < resultLimit; row++) {
          for (let col: number = 0; col < cols && result.length < resultLimit; col++) {
            const elemMat: Mat2D = { a: instMat.a, b: instMat.b, c: instMat.c, d: instMat.d,
              tx: instMat.tx + col * (s.arrayColStepX ?? 0) + row * (s.arrayRowStepX ?? 0),
              ty: instMat.ty + col * (s.arrayColStepY ?? 0) + row * (s.arrayRowStepY ?? 0) };
            const childMat: Mat2D = multiplyMat(parentMat, elemMat);
            emitLocal(childId, childMat, currentDepth + 1);
          }
        }
        continue;
      }
      // 本地几何
      const isIdentity: boolean =
        parentMat.a === 1 && parentMat.b === 0 && parentMat.c === 0 && parentMat.d === 1 &&
        parentMat.tx === 0 && parentMat.ty === 0;
      if (isIdentity && currentDepth === 0) {
        // 当前 Cell 本地图形：保留原始 id，便于选择/编辑
        if (viewport === undefined || (s.points.length > 0 && (s.type === ShapeType.TEXT ||
          boundsIntersects(getShapeBounds(s), viewport)))) result.push(s);
      } else {
        let sourceType: ShapeType = s.type;
        let sourcePoints: Point[] = s.points;
        // RECT 存为对角两点；非单位变换后不再轴对齐，转为 4 点 POLYGON 绘制
        if (s.type === ShapeType.RECT && s.points.length >= 2 && !isIdentity) {
          const rectBounds: ShapeBounds = getShapeBounds(s);
          const x0: number = rectBounds.minX;
          const y0: number = rectBounds.minY;
          const x1: number = rectBounds.maxX;
          const y1: number = rectBounds.maxY;
          sourceType = ShapeType.POLYGON;
          sourcePoints = [
            { x: x0, y: y0 },
            { x: x1, y: y0 },
            { x: x1, y: y1 },
            { x: x0, y: y1 },
          ];
        }
        const pts: Point[] = clonePointsTransformed(sourcePoints, parentMat);
        if (pts.length === 0) {
          continue;
        }
        const expanded: Shape = {
          id: nextSynthId++,
          type: sourceType,
          layerNumber: s.layerNumber,
          datatype: s.datatype,
          points: pts,
          selected: false,
          ownerCellId: rootCellId,
        };
        if (sourceType === ShapeType.PATH) {
          const pw: number | undefined = s.pathWidthAbsolute ? s.pathWidth : transformPathWidth(s.pathWidth, parentMat);
          const pathScale: number = Math.sqrt(Math.abs(parentMat.a * parentMat.d - parentMat.b * parentMat.c));
          expanded.pathBeginExtension = (s.pathBeginExtension ?? 0) * pathScale;
          expanded.pathEndExtension = (s.pathEndExtension ?? 0) * pathScale;
          expanded.pathWidthAbsolute = s.pathWidthAbsolute;
          if (pw !== undefined) {
            expanded.pathWidth = pw;
          }
          // 展开出的实例几何必须带端型，否则画布/DRC 用 flush 轮廓、
          // 而磁盘上的 SREF 仍是 round/extended，两边不一致
          if (s.pathType !== undefined && s.pathType > 0) {
            expanded.pathType = s.pathType;
          }
        }
        if (sourceType === ShapeType.TEXT && s.text !== undefined) {
          expanded.text = s.text;
        }
        if (viewport === undefined || expanded.type === ShapeType.TEXT ||
          boundsIntersects(getShapeBounds(expanded), viewport)) result.push(expanded);
      }
    }
    visiting.pop();
  };

  emitLocal(rootCellId, identityMat(), 0);

  if (includeInstanceMarkers && depth >= 2) {
    const localShapes: Shape[] = index.local(rootCellId);
    for (let i = 0; i < localShapes.length && result.length < resultLimit; i++) {
      const s: Shape = localShapes[i];
      if (s.type === ShapeType.INSTANCE) {
        // 避免重复（若上面未 push instance）
        let already: boolean = false;
        for (let j = 0; j < result.length; j++) {
          if (result[j].id === s.id) {
            already = true;
            break;
          }
        }
        if (!already) {
          result.push(s);
        }
      }
    }
  }

  return result;
}

/** 是否为层级展开产生的合成图形（不可当作当前 Cell 本地编辑对象） */
export function isExpandedSyntheticShape(shape: Shape): boolean {
  return shape.id >= EXPANDED_SHAPE_ID_BASE;
}

/** 视口矩形（世界坐标 nm） */
export interface WorldViewport {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

/**
 * 由画布像素与相机参数估算世界视口（与 ShapeNode 映射一致）。
 * pixelX = (worldX + viewOffsetX) * z；pixelY = (viewOffsetY - worldY) * z。
 * Y 向上，因此视口底边是 minY，顶边是 maxY。
 */
export function worldViewportFromCamera(
  canvasWidth: number,
  canvasHeight: number,
  zoomPercent: number,
  viewOffsetX: number,
  viewOffsetY: number,
  marginPx: number = 64
): WorldViewport {
  const z: number = Math.max(1e-8, zoomPercent / 100);
  const pad: number = marginPx / z;
  const minX: number = (0 / z) - viewOffsetX - pad;
  const minY: number = viewOffsetY - (Math.max(1, canvasHeight) / z) - pad;
  const maxX: number = (Math.max(1, canvasWidth) / z) - viewOffsetX + pad;
  const maxY: number = viewOffsetY + pad;
  return { minX, minY, maxX, maxY };
}

function boundsIntersects(a: ShapeBounds, v: WorldViewport): boolean {
  return a.minX <= v.maxX && a.maxX >= v.minX && a.minY <= v.maxY && a.maxY >= v.minY;
}

/**
 * 视口裁剪：丢弃 bbox 完全在视口外的图形，减少 GL 上传与 draw call。
 * INSTANCE / TEXT 默认保留（交互入口，bbox 可能只是占位）。
 */
export function cullShapesToViewport(shapes: Shape[], viewport: WorldViewport): Shape[] {
  const out: Shape[] = [];
  for (let i = 0; i < shapes.length; i++) {
    const s: Shape = shapes[i];
    if (s.type === ShapeType.INSTANCE || s.type === ShapeType.TEXT) {
      out.push(s);
      continue;
    }
    if (s.points.length === 0) {
      continue;
    }
    const b: ShapeBounds = getShapeBounds(s);
    if (boundsIntersects(b, viewport)) {
      out.push(s);
    }
  }
  return out;
}

/**
 * 展开 + 视口裁剪一条龙（画布主路径）。
 */
export function expandAndCullCellShapes(
  allShapes: Shape[],
  rootCellId: number,
  hierarchyDepth: number,
  viewport: WorldViewport,
  includeInstanceMarkers: boolean = true
): Shape[] {
  return expandCellShapes(allShapes, rootCellId, hierarchyDepth, includeInstanceMarkers, viewport);
}

export interface BoundedHierarchyDrawResult {
  shapes: Shape[];
  overflow: boolean;
  limit: number;
}

/**
 * ArkUI fallback has a finite node budget. One extra visible object proves
 * overflow; stop traversal immediately and return no partial drawing.
 * Source definitions / instances are never changed by this display-only API.
 */
export function expandAndCullCellShapesBounded(
  allShapes: Shape[], rootCellId: number, hierarchyDepth: number,
  viewport: WorldViewport, includeInstanceMarkers: boolean = true, maxShapes: number = 2000
): BoundedHierarchyDrawResult {
  const limit: number = Number.isFinite(maxShapes) ? Math.max(0, Math.floor(maxShapes)) : 2000;
  const shapes: Shape[] = expandCellShapes(allShapes, rootCellId, hierarchyDepth,
    includeInstanceMarkers, viewport, limit + 1);
  const overflow: boolean = shapes.length > limit;
  return { shapes: overflow ? [] : shapes, overflow, limit };
}

/**
 * 简单 LOD：按世界尺寸相对视口的比例简化几何，降低远景顶点数。
 * - zoom 很高（图元大）：原样
 * - 图元 bbox 相对视口很小时：用轴对齐矩形代替多边形/路径（仍可见色块）
 * - 超小时：可丢弃非 INSTANCE/TEXT（由 dropTiny 控制）
 *
 * @param shapes 已展开/裁剪后的图形
 * @param viewport 世界视口
 * @param zoomPercent 当前缩放百分比（与相机一致）
 */
export function applyLodToShapes(
  shapes: Shape[],
  viewport: WorldViewport,
  zoomPercent: number,
  dropTiny: boolean = true
): Shape[] {
  const vpW: number = Math.max(1, viewport.maxX - viewport.minX);
  const vpH: number = Math.max(1, viewport.maxY - viewport.minY);
  const vpDiag: number = Math.sqrt(vpW * vpW + vpH * vpH);
  // 像素尺度：世界 nm 每像素
  const z: number = Math.max(1e-8, zoomPercent / 100);
  const worldPerPx: number = 1 / z;
  // 约 2px 以下视为可简化；约 0.5px 可丢弃
  const simplifyThresh: number = worldPerPx * 2;
  const dropThresh: number = worldPerPx * 0.5;

  const out: Shape[] = [];
  for (let i = 0; i < shapes.length; i++) {
    const s: Shape = shapes[i];
    if (s.type === ShapeType.INSTANCE || s.type === ShapeType.TEXT) {
      out.push(s);
      continue;
    }
    if (s.points.length === 0) {
      continue;
    }
    const b: ShapeBounds = getShapeBounds(s);
    const bw: number = Math.max(0, b.maxX - b.minX);
    const bh: number = Math.max(0, b.maxY - b.minY);
    const size: number = Math.max(bw, bh);

    if (dropTiny && size < dropThresh && size < vpDiag * 0.0005) {
      continue;
    }
    // 多边形点数多且屏幕很小 -> 收成 RECT 对角两点
    if ((s.type === ShapeType.POLYGON || s.type === ShapeType.PATH) &&
      s.points.length > 4 && size < simplifyThresh) {
      const lod: Shape = {
        id: s.id,
        type: ShapeType.RECT,
        layerNumber: s.layerNumber,
        datatype: s.datatype,
        points: [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.maxY }],
        selected: s.selected,
      };
      if (s.ownerCellId !== undefined) {
        lod.ownerCellId = s.ownerCellId;
      }
      out.push(lod);
      continue;
    }
    out.push(s);
  }
  return out;
}
