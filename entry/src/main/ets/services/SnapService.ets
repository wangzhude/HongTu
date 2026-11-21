/**
 * 鸿图统一空间磁吸与智能对齐参考线服务（Phase 5 高帧率空间网格桶升级版）
 *
 * 对标 KiCad GAL GRID_HELPER 与 KLayout Object Snap：
 * 1. 引入均匀空间网格桶索引（SpatialSnapIndex），将视口/全图几千至数万图元的吸附查询从每帧 O(N) 全扫降至 O(1) 局部桶检索，
 *    且索引缓存键与相机缩放/平移完全解耦，双指缩放平移与 120Hz 指针移动零重建开销；
 * 2. 新增视觉磁吸靶标元数据（SnapMarker：顶点方框、交点双环叉、中点三角、中心菱形、边垂足圆环、闭合首点双环、网格微十字）；
 * 3. 新增跨图元十字延伸智能对齐参考线（AlignmentGuide：自动捕捉附近顶点/中心的水平 Y 对齐与竖直 X 对齐，支持双轴交汇磁吸）；
 * 4. 100% 兼容原有 snapToGeometry / snapToGrid / snapToVertex / snapToEdge / snapForVertexDrag 签名。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, Point, ShapeBounds, getShapeBounds } from '../models/GdsiiData';

export interface GeometrySnapResult {
  point: Point;
  kind: string;
}

/** 视觉磁吸靶标分类（驱动 DraftOverlayLayer 绘制差异化 CAD 靶标符号） */
export type SnapMarkerSymbol =
  | 'vertex'
  | 'intersection'
  | 'midpoint'
  | 'center'
  | 'edge'
  | 'closeLoop'
  | 'guideCross'
  | 'grid';

/** 画布光标磁吸靶标描述 */
export interface SnapMarker {
  point: Point;
  kind: string;
  symbol: SnapMarkerSymbol;
}

/** 智能正交延伸对齐参考线（世界坐标 nm） */
export interface AlignmentGuide {
  /** true = 竖直对齐线 (X 恒定)，false = 水平对齐线 (Y 恒定) */
  vertical: boolean;
  /** 对齐轴坐标（vertical 时为 X，否则为 Y） */
  axisValue: number;
  /** 触发对齐的参考锚点（世界坐标 nm） */
  fromPoint: Point;
  /** 当前光标吸附点（世界坐标 nm） */
  toPoint: Point;
  /** 参考源说明（如 '顶点对齐' / '中心对齐' / '首点对齐'） */
  label: string;
}

/** 富磁吸结果（坐标 + 视觉靶标 + 智能对齐线） */
export interface RichSnapResult {
  point: Point;
  snappedGeometry: boolean;
  closeLoopHit: boolean;
  marker: SnapMarker | null;
  guides: AlignmentGuide[];
  readoutText: string;
}

interface SnapSegment {
  a: Point;
  b: Point;
  shapeId: number;
}

interface GuideAnchor {
  point: Point;
  label: string;
  shapeId: number;
}

/**
 * 均匀空间网格哈希索引：将图元包围盒与关键对齐锚点分桶，指针移动期仅检索 3×3 邻域桶
 */
export class SpatialSnapIndex {
  readonly cacheKey: string;
  private cellSizeNm: number = 1000;
  private shapeBuckets: Map<string, Shape[]> = new Map<string, Shape[]>();
  private anchorBuckets: Map<string, GuideAnchor[]> = new Map<string, GuideAnchor[]>();
  private allShapes: Shape[] = [];
  private maxBucketsPerShape: number = 64;
  private oversizeShapes: Shape[] = [];

  constructor(cacheKey: string, shapes: Shape[]) {
    this.cacheKey = cacheKey;
    this.build(shapes);
  }

  private bucketKey(ix: number, iy: number): string {
    return `${ix}_${iy}`;
  }

  private toBucketCoord(v: number): number {
    return Math.floor(v / this.cellSizeNm);
  }

  private build(shapes: Shape[]): void {
    this.allShapes = shapes;
    if (shapes.length === 0) {
      return;
    }

    // 根据图元平均跨度自适应计算网格桶尺寸，兼顾纳米器件与毫米级顶层芯片
    let spanSum: number = 0;
    let spanCount: number = 0;
    for (let i = 0; i < shapes.length && spanCount < 512; i++) {
      const s: Shape = shapes[i];
      if (s.type === ShapeType.NODE || s.points.length === 0) {
        continue;
      }
      const b: ShapeBounds = getShapeBounds(s);
      const span: number = Math.max(b.maxX - b.minX, b.maxY - b.minY);
      if (Number.isFinite(span) && span > 0) {
        spanSum += span;
        spanCount++;
      }
    }
    const avgSpan: number = spanCount > 0 ? spanSum / spanCount : 1000;
    this.cellSizeNm = Math.max(50, Math.min(200000, avgSpan * 2.5));

    const maxIndexedAnchors: number = 12000;
    let anchorCount: number = 0;

    for (let i = 0; i < shapes.length; i++) {
      const s: Shape = shapes[i];
      if (s.type === ShapeType.NODE || s.points.length === 0) {
        continue;
      }
      const b: ShapeBounds = getShapeBounds(s);
      if (!Number.isFinite(b.minX) || !Number.isFinite(b.maxX) ||
        !Number.isFinite(b.minY) || !Number.isFinite(b.maxY)) {
        continue;
      }
      const x0: number = this.toBucketCoord(b.minX);
      const x1: number = this.toBucketCoord(b.maxX);
      const y0: number = this.toBucketCoord(b.minY);
      const y1: number = this.toBucketCoord(b.maxY);
      const bucketCount: number = (x1 - x0 + 1) * (y1 - y0 + 1);

      if (bucketCount > this.maxBucketsPerShape) {
        this.oversizeShapes.push(s);
      } else {
        for (let bx = x0; bx <= x1; bx++) {
          for (let by = y0; by <= y1; by++) {
            const key: string = this.bucketKey(bx, by);
            let list: Shape[] | undefined = this.shapeBuckets.get(key);
            if (list === undefined) {
              list = [];
              this.shapeBuckets.set(key, list);
            }
            list.push(s);
          }
        }
      }

      // 提取顶点与中心作为智能对齐参考线锚点
      if (anchorCount < maxIndexedAnchors) {
        const pts: Point[] = this.extractAnchorVertices(s, b);
        for (let pIdx = 0; pIdx < pts.length && anchorCount < maxIndexedAnchors; pIdx++) {
          this.insertAnchor({ point: pts[pIdx], label: '顶点对齐', shapeId: s.id });
          anchorCount++;
        }
        if ((s.type === ShapeType.RECT || s.type === ShapeType.POLYGON) && anchorCount < maxIndexedAnchors) {
          this.insertAnchor({
            point: { x: (b.minX + b.maxX) * 0.5, y: (b.minY + b.maxY) * 0.5 },
            label: '中心对齐',
            shapeId: s.id,
          });
          anchorCount++;
        }
      }
    }
  }

  private extractAnchorVertices(shape: Shape, b: ShapeBounds): Point[] {
    if (shape.type === ShapeType.RECT && shape.points.length === 2) {
      return [
        { x: b.minX, y: b.minY },
        { x: b.maxX, y: b.minY },
        { x: b.maxX, y: b.maxY },
        { x: b.minX, y: b.maxY },
      ];
    }
    // 对超多点圆弧多边形采样前 24 个关键顶点防锚点膨胀
    if (shape.points.length > 24) {
      const step: number = Math.max(1, Math.floor(shape.points.length / 16));
      const sampled: Point[] = [];
      for (let i = 0; i < shape.points.length; i += step) {
        sampled.push(shape.points[i]);
      }
      return sampled;
    }
    return shape.points;
  }

  private insertAnchor(anchor: GuideAnchor): void {
    const bx: number = this.toBucketCoord(anchor.point.x);
    const by: number = this.toBucketCoord(anchor.point.y);
    const key: string = this.bucketKey(bx, by);
    let list: GuideAnchor[] | undefined = this.anchorBuckets.get(key);
    if (list === undefined) {
      list = [];
      this.anchorBuckets.set(key, list);
    }
    list.push(anchor);
  }

  /**
   * 查询 (x, y) 周围 radiusNm 邻域内的唯一候选图元
   */
  queryShapesNear(x: number, y: number, radiusNm: number): Shape[] {
    if (this.allShapes.length === 0 || !Number.isFinite(radiusNm) || radiusNm < 0) {
      return [];
    }
    const x0: number = this.toBucketCoord(x - radiusNm);
    const x1: number = this.toBucketCoord(x + radiusNm);
    const y0: number = this.toBucketCoord(y - radiusNm);
    const y1: number = this.toBucketCoord(y + radiusNm);
    if ((x1 - x0 + 1) * (y1 - y0 + 1) > 256) {
      return this.allShapes;
    }

    const seen: Set<number> = new Set<number>();
    const out: Shape[] = [];
    for (let i = 0; i < this.oversizeShapes.length; i++) {
      const s: Shape = this.oversizeShapes[i];
      seen.add(s.id);
      out.push(s);
    }
    for (let bx = x0; bx <= x1; bx++) {
      for (let by = y0; by <= y1; by++) {
        const bucket: Shape[] | undefined = this.shapeBuckets.get(this.bucketKey(bx, by));
        if (bucket === undefined) {
          continue;
        }
        for (let i = 0; i < bucket.length; i++) {
          const s: Shape = bucket[i];
          if (!seen.has(s.id)) {
            seen.add(s.id);
            out.push(s);
          }
        }
      }
    }
    return out;
  }

  /**
   * 查询智能对齐参考线候选锚点（沿水平与竖直走廊检索邻近桶）
   */
  queryGuideAnchors(x: number, y: number, corridorToleranceNm: number, maxGuideLengthNm: number, excludedShapeId: number = -1): GuideAnchor[] {
    if (this.anchorBuckets.size === 0 || maxGuideLengthNm <= 0) {
      return [];
    }
    const cxMin: number = this.toBucketCoord(x - corridorToleranceNm);
    const cxMax: number = this.toBucketCoord(x + corridorToleranceNm);
    const cyMin: number = this.toBucketCoord(y - corridorToleranceNm);
    const cyMax: number = this.toBucketCoord(y + corridorToleranceNm);
    const spanXMin: number = this.toBucketCoord(x - maxGuideLengthNm);
    const spanXMax: number = this.toBucketCoord(x + maxGuideLengthNm);
    const spanYMin: number = this.toBucketCoord(y - maxGuideLengthNm);
    const spanYMax: number = this.toBucketCoord(y + maxGuideLengthNm);

    // 防止极小视口缩放到全芯片鸟瞰时桶跨度过大
    const maxSpanSteps: number = 24;
    const clampedSpanXMin: number = Math.max(spanXMin, this.toBucketCoord(x) - maxSpanSteps);
    const clampedSpanXMax: number = Math.min(spanXMax, this.toBucketCoord(x) + maxSpanSteps);
    const clampedSpanYMin: number = Math.max(spanYMin, this.toBucketCoord(y) - maxSpanSteps);
    const clampedSpanYMax: number = Math.min(spanYMax, this.toBucketCoord(y) + maxSpanSteps);

    const out: GuideAnchor[] = [];
    const visitedBuckets: Set<string> = new Set<string>();

    // 竖直走廊（找同 X 的上下锚点）
    for (let bx = cxMin; bx <= cxMax; bx++) {
      for (let by = clampedSpanYMin; by <= clampedSpanYMax; by++) {
        const k: string = this.bucketKey(bx, by);
        if (visitedBuckets.has(k)) continue;
        visitedBuckets.add(k);
        const list: GuideAnchor[] | undefined = this.anchorBuckets.get(k);
        if (list !== undefined) {
          for (let i = 0; i < list.length && out.length < 320; i++) {
            if (list[i].shapeId !== excludedShapeId) {
              out.push(list[i]);
            }
          }
        }
      }
    }

    // 水平走廊（找同 Y 的左右锚点）
    for (let by = cyMin; by <= cyMax; by++) {
      for (let bx = clampedSpanXMin; bx <= clampedSpanXMax; bx++) {
        const k: string = this.bucketKey(bx, by);
        if (visitedBuckets.has(k)) continue;
        visitedBuckets.add(k);
        const list: GuideAnchor[] | undefined = this.anchorBuckets.get(k);
        if (list !== undefined) {
          for (let i = 0; i < list.length && out.length < 320; i++) {
            if (list[i].shapeId !== excludedShapeId) {
              out.push(list[i]);
            }
          }
        }
      }
    }
    return out;
  }
}

/**
 * 统一吸附服务（兼容旧接口 + 空间桶富磁吸与智能对齐线）
 */
export class SnapService {
  private cachedIndex: SpatialSnapIndex | null = null;

  /**
   * 获取或复用空间网格桶索引
   */
  ensureSpatialIndex(cacheKey: string, shapes: Shape[]): SpatialSnapIndex {
    if (this.cachedIndex !== null && this.cachedIndex.cacheKey === cacheKey) {
      return this.cachedIndex;
    }
    this.cachedIndex = new SpatialSnapIndex(cacheKey, shapes);
    return this.cachedIndex;
  }

  private symbolForKind(kind: string): SnapMarkerSymbol {
    if (kind === '顶点') return 'vertex';
    if (kind === '交点') return 'intersection';
    if (kind === '中点') return 'midpoint';
    if (kind === '包围盒中心') return 'center';
    if (kind === '边') return 'edge';
    return 'grid';
  }

  /**
   * 高帧率富磁吸主入口：
   * 优先级：多边形首点闭合磁吸 > 精确几何靶标（顶点/交点/中点/中心/边） > 智能正交延伸对齐线（双轴交汇或单轴对齐+网格） > 网格交点 > 裸坐标
   */
  snapRich(
    x: number,
    y: number,
    spatialIndex: SpatialSnapIndex | null,
    geometryEnabled: boolean,
    thresholdNm: number,
    kinds: string[],
    smartGuidesEnabled: boolean,
    maxGuideLengthNm: number,
    gridEnabled: boolean,
    gridStepNm: number,
    extraAnchors: Point[] = [],
    closeLoopAnchor: Point | null = null,
    excludedShapeId: number = -1
  ): RichSnapResult {
    // 1. 多边形首点闭合优先判定
    if (closeLoopAnchor !== null && thresholdNm > 0) {
      const cdx: number = closeLoopAnchor.x - x;
      const cdy: number = closeLoopAnchor.y - y;
      if (cdx * cdx + cdy * cdy <= (thresholdNm * 1.25) * (thresholdNm * 1.25)) {
        const pt: Point = { x: closeLoopAnchor.x, y: closeLoopAnchor.y };
        return {
          point: pt,
          snappedGeometry: true,
          closeLoopHit: true,
          marker: { point: pt, kind: '闭合首点', symbol: 'closeLoop' },
          guides: this.findCollinearGuides(pt.x, pt.y, spatialIndex, thresholdNm * 0.25, maxGuideLengthNm, extraAnchors, excludedShapeId),
          readoutText: '吸附：闭合首点（松手自动闭合）',
        };
      }
    }

    // 2. 精确几何吸附（经空间桶仅取 3×3 局部图元）
    if (geometryEnabled && spatialIndex !== null && thresholdNm > 0 && kinds.length > 0) {
      const localShapes: Shape[] = spatialIndex.queryShapesNear(x, y, thresholdNm);
      const filteredShapes: Shape[] = excludedShapeId >= 0
        ? localShapes.filter((s: Shape): boolean => s.id !== excludedShapeId)
        : localShapes;
      const geoHit: GeometrySnapResult | null = this.snapToGeometry(x, y, filteredShapes, thresholdNm, kinds);
      if (geoHit !== null) {
        const guides: AlignmentGuide[] = smartGuidesEnabled
          ? this.findCollinearGuides(geoHit.point.x, geoHit.point.y, spatialIndex, Math.max(1e-3, thresholdNm * 0.15), maxGuideLengthNm, extraAnchors, excludedShapeId)
          : [];
        return {
          point: geoHit.point,
          snappedGeometry: true,
          closeLoopHit: false,
          marker: { point: geoHit.point, kind: geoHit.kind, symbol: this.symbolForKind(geoHit.kind) },
          guides: guides,
          readoutText: `吸附：${geoHit.kind}`,
        };
      }
    }

    // 3. 智能正交延伸对齐参考线（Smart Alignment Guides）
    const guideTol: number = thresholdNm > 0 ? thresholdNm * 0.65 : 0;
    if (smartGuidesEnabled && guideTol > 0 && (spatialIndex !== null || extraAnchors.length > 0)) {
      const candidates: GuideAnchor[] = spatialIndex !== null
        ? spatialIndex.queryGuideAnchors(x, y, guideTol, maxGuideLengthNm, excludedShapeId)
        : [];
      for (let i = 0; i < extraAnchors.length; i++) {
        candidates.push({ point: extraAnchors[i], label: '草稿顶点对齐', shapeId: -2 });
      }

      let bestVert: GuideAnchor | null = null;
      let bestVertDx: number = guideTol;
      let bestVertSpan: number = maxGuideLengthNm;

      let bestHoriz: GuideAnchor | null = null;
      let bestHorizDy: number = guideTol;
      let bestHorizSpan: number = maxGuideLengthNm;

      for (let i = 0; i < candidates.length; i++) {
        const c: GuideAnchor = candidates[i];
        const adx: number = Math.abs(c.point.x - x);
        const ady: number = Math.abs(c.point.y - y);
        if (adx <= bestVertDx && ady <= maxGuideLengthNm && ady > thresholdNm * 0.35) {
          if (adx < bestVertDx - 1e-6 || ady < bestVertSpan) {
            bestVert = c;
            bestVertDx = adx;
            bestVertSpan = ady;
          }
        }
        if (ady <= bestHorizDy && adx <= maxGuideLengthNm && adx > thresholdNm * 0.35) {
          if (ady < bestHorizDy - 1e-6 || adx < bestHorizSpan) {
            bestHoriz = c;
            bestHorizDy = ady;
            bestHorizSpan = adx;
          }
        }
      }

      if (bestVert !== null || bestHoriz !== null) {
        const baseGrid: Point = (gridEnabled && gridStepNm > 0) ? this.snapToGrid(x, y, gridStepNm) : { x, y };
        const finalX: number = bestVert !== null ? bestVert.point.x : baseGrid.x;
        const finalY: number = bestHoriz !== null ? bestHoriz.point.y : baseGrid.y;
        const finalPt: Point = { x: finalX, y: finalY };
        const guides: AlignmentGuide[] = [];
        if (bestVert !== null) {
          guides.push({
            vertical: true,
            axisValue: finalX,
            fromPoint: bestVert.point,
            toPoint: finalPt,
            label: bestVert.label,
          });
        }
        if (bestHoriz !== null) {
          guides.push({
            vertical: false,
            axisValue: finalY,
            fromPoint: bestHoriz.point,
            toPoint: finalPt,
            label: bestHoriz.label,
          });
        }
        const dualHit: boolean = bestVert !== null && bestHoriz !== null;
        return {
          point: finalPt,
          snappedGeometry: dualHit,
          closeLoopHit: false,
          marker: {
            point: finalPt,
            kind: dualHit ? '双轴对齐交点' : (bestVert !== null ? '竖直参考对齐' : '水平参考对齐'),
            symbol: 'guideCross',
          },
          guides: guides,
          readoutText: dualHit ? '吸附：双轴对齐交点' : (bestVert !== null ? '吸附：竖直对齐线' : '吸附：水平对齐线'),
        };
      }
    }

    // 4. 网格吸附回退
    if (gridEnabled && gridStepNm > 0) {
      const gp: Point = this.snapToGrid(x, y, gridStepNm);
      return {
        point: gp,
        snappedGeometry: false,
        closeLoopHit: false,
        marker: { point: gp, kind: '网格', symbol: 'grid' },
        guides: [],
        readoutText: '吸附：网格',
      };
    }

    return {
      point: { x, y },
      snappedGeometry: false,
      closeLoopHit: false,
      marker: null,
      guides: [],
      readoutText: '',
    };
  }

  private findCollinearGuides(
    px: number,
    py: number,
    spatialIndex: SpatialSnapIndex | null,
    epsNm: number,
    maxGuideLengthNm: number,
    extraAnchors: Point[],
    excludedShapeId: number
  ): AlignmentGuide[] {
    const guides: AlignmentGuide[] = [];
    const candidates: GuideAnchor[] = spatialIndex !== null
      ? spatialIndex.queryGuideAnchors(px, py, epsNm, maxGuideLengthNm, excludedShapeId)
      : [];
    for (let i = 0; i < extraAnchors.length; i++) {
      candidates.push({ point: extraAnchors[i], label: '草稿顶点对齐', shapeId: -2 });
    }
    let vertAnchor: GuideAnchor | null = null;
    let vertDist: number = maxGuideLengthNm;
    let horizAnchor: GuideAnchor | null = null;
    let horizDist: number = maxGuideLengthNm;
    for (let i = 0; i < candidates.length; i++) {
      const c: GuideAnchor = candidates[i];
      const adx: number = Math.abs(c.point.x - px);
      const ady: number = Math.abs(c.point.y - py);
      if (adx <= epsNm && ady > epsNm * 4 && ady < vertDist) {
        vertDist = ady;
        vertAnchor = c;
      }
      if (ady <= epsNm && adx > epsNm * 4 && adx < horizDist) {
        horizDist = adx;
        horizAnchor = c;
      }
    }
    const target: Point = { x: px, y: py };
    if (vertAnchor !== null) {
      guides.push({ vertical: true, axisValue: px, fromPoint: vertAnchor.point, toPoint: target, label: vertAnchor.label });
    }
    if (horizAnchor !== null) {
      guides.push({ vertical: false, axisValue: py, fromPoint: horizAnchor.point, toPoint: target, label: horizAnchor.label });
    }
    return guides;
  }

  /** Exact geometry only: vertices, intersections, midpoints, bbox centers, then edges. */
  snapToGeometry(x: number, y: number, shapes: Shape[], threshold: number,
                 kinds: string[] = ['顶点', '交点', '中点', '包围盒中心', '边']): GeometrySnapResult | null {
    if (!Number.isFinite(x) || !Number.isFinite(y) || threshold <= 0 || kinds.length === 0) return null;
    const near: Shape[] = shapes.filter((s: Shape) => s.type !== ShapeType.NODE && this.bboxNear(s, x, y, threshold));
    const vertex: Point | null = kinds.indexOf('顶点') >= 0 ? this.snapToVertex(x, y, near, threshold) : null;
    if (vertex !== null) return { point: vertex, kind: '顶点' };
    const segments: SnapSegment[] = [];
    const midpoints: Point[] = [];
    const centers: Point[] = [];
    for (let i = 0; i < near.length; i++) {
      const s: Shape = near[i];
      if (s.type === ShapeType.TEXT || s.type === ShapeType.INSTANCE) continue;
      const pts: Point[] = this.edgePoints(s);
      const count: number = s.type === ShapeType.PATH ? pts.length - 1 : pts.length;
      for (let j = 0; j < count; j++) {
        const a: Point = pts[j]; const b: Point = pts[(j + 1) % pts.length];
        midpoints.push({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
        const p: Point | null = this.projectOnSegment(x, y, a, b);
        if (p !== null && (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y) <= threshold * threshold && segments.length < 96) {
          segments.push({ a: a, b: b, shapeId: s.id });
        }
      }
      if (s.type === ShapeType.RECT || s.type === ShapeType.POLYGON) {
        const b: ShapeBounds = getShapeBounds(s);
        centers.push({ x: (b.minX + b.maxX) / 2, y: (b.minY + b.maxY) / 2 });
      }
    }
    const intersections: Point[] = [];
    if (kinds.indexOf('交点') >= 0) {
      for (let i = 0; i < segments.length; i++) {
        for (let j = i + 1; j < segments.length; j++) {
          if (segments[i].shapeId === segments[j].shapeId) continue;
          const p: Point | null = this.segmentIntersection(segments[i], segments[j]);
          if (p !== null) intersections.push(p);
        }
      }
    }
    const crossing: Point | null = kinds.indexOf('交点') >= 0 ? this.closestPoint(x, y, intersections, threshold) : null;
    if (crossing !== null) return { point: crossing, kind: '交点' };
    const midpoint: Point | null = kinds.indexOf('中点') >= 0 ? this.closestPoint(x, y, midpoints, threshold) : null;
    if (midpoint !== null) return { point: midpoint, kind: '中点' };
    const center: Point | null = kinds.indexOf('包围盒中心') >= 0 ? this.closestPoint(x, y, centers, threshold) : null;
    if (center !== null) return { point: center, kind: '包围盒中心' };
    const edge: Point | null = kinds.indexOf('边') >= 0 ? this.snapToEdge(x, y, near, threshold) : null;
    return edge === null ? null : { point: edge, kind: '边' };
  }

  private closestPoint(x: number, y: number, points: Point[], threshold: number): Point | null {
    let best: Point | null = null; let distance: number = threshold * threshold;
    for (let i = 0; i < points.length; i++) {
      const p: Point = points[i]; const d: number = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y);
      if (d <= distance) { best = p; distance = d; }
    }
    return best;
  }

  private segmentIntersection(a: SnapSegment, b: SnapSegment): Point | null {
    const rx: number = a.b.x - a.a.x; const ry: number = a.b.y - a.a.y;
    const sx: number = b.b.x - b.a.x; const sy: number = b.b.y - b.a.y;
    const divisor: number = rx * sy - ry * sx;
    if (Math.abs(divisor) < 1e-12) return null;
    const qx: number = b.a.x - a.a.x; const qy: number = b.a.y - a.a.y;
    const t: number = (qx * sy - qy * sx) / divisor; const u: number = (qx * ry - qy * rx) / divisor;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return { x: a.a.x + t * rx, y: a.a.y + t * ry };
  }

  snapToGrid(x: number, y: number, gridSize: number): Point {
    if (gridSize <= 0) {
      return { x, y };
    }
    const sx: number = Math.round(x / gridSize) * gridSize;
    const sy: number = Math.round(y / gridSize) * gridSize;
    return { x: sx, y: sy };
  }

  snapToVertex(x: number, y: number, shapes: Shape[], threshold: number): Point | null {
    if (threshold <= 0 || shapes.length === 0) {
      return null;
    }
    let best: Point | null = null;
    let bestDistSq: number = threshold * threshold;
    for (let i = 0; i < shapes.length; i++) {
      if (shapes[i].type === ShapeType.NODE) continue;
      const pts: Point[] = this.edgePoints(shapes[i]);
      if (!pts || !this.bboxNear(shapes[i], x, y, threshold)) {
        continue;
      }
      for (let j = 0; j < pts.length; j++) {
        const dx: number = pts[j].x - x;
        const dy: number = pts[j].y - y;
        const dSq: number = dx * dx + dy * dy;
        if (dSq <= bestDistSq) {
          bestDistSq = dSq;
          best = { x: pts[j].x, y: pts[j].y };
        }
      }
    }
    return best;
  }

  snapToEdge(x: number, y: number, shapes: Shape[], threshold: number): Point | null {
    if (threshold <= 0 || shapes.length === 0) {
      return null;
    }
    let best: Point | null = null;
    let bestDistSq: number = threshold * threshold;
    for (let i = 0; i < shapes.length; i++) {
      const shape: Shape = shapes[i];
      if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE || shape.type === ShapeType.INSTANCE ||
          !this.bboxNear(shape, x, y, threshold)) {
        continue;
      }
      const pts: Point[] = this.edgePoints(shape);
      const closed: boolean = shape.type !== ShapeType.PATH;
      const segCount: number = closed ? pts.length : pts.length - 1;
      for (let j = 0; j < segCount; j++) {
        const a: Point = pts[j];
        const b: Point = pts[(j + 1) % pts.length];
        const proj: Point | null = this.projectOnSegment(x, y, a, b);
        if (proj === null) {
          continue;
        }
        const dx: number = proj.x - x;
        const dy: number = proj.y - y;
        const dSq: number = dx * dx + dy * dy;
        if (dSq <= bestDistSq) {
          bestDistSq = dSq;
          best = proj;
        }
      }
    }
    return best;
  }

  snapForVertexDrag(x: number, y: number, shapes: Shape[], threshold: number,
                    editedShapeId: number, editedIndex: number, gridSize: number, kinds: string[] = ['顶点']): Point {
    const others: Shape[] = shapes.filter((shape: Shape): boolean => shape.id !== editedShapeId);
    const external: GeometrySnapResult | null = this.snapToGeometry(x, y, others, threshold, kinds);
    if (external !== null) return external.point;
    if (threshold > 0 && shapes.length > 0 && kinds.indexOf('顶点') >= 0) {
      let best: Point | null = null;
      let bestDistSq: number = threshold * threshold;
      for (let i = 0; i < shapes.length; i++) {
        const shape: Shape = shapes[i];
        if (shape.id !== editedShapeId || shape.type === ShapeType.NODE) continue;
        const pts: Point[] = this.edgePoints(shape);
        if (!pts || pts.length === 0) {
          continue;
        }
        const skipSelf: boolean = shape.id === editedShapeId && editedIndex >= 0;
        if (!skipSelf && !this.bboxNear(shape, x, y, threshold)) {
          continue;
        }
        for (let j = 0; j < pts.length; j++) {
          if (skipSelf && j === editedIndex) {
            continue;
          }
          const dx: number = pts[j].x - x;
          const dy: number = pts[j].y - y;
          const dSq: number = dx * dx + dy * dy;
          if (dSq <= bestDistSq) {
            bestDistSq = dSq;
            best = { x: pts[j].x, y: pts[j].y };
          }
        }
      }
      if (best !== null) {
        return best;
      }
    }
    return this.snapToGrid(x, y, gridSize);
  }

  private bboxNear(shape: Shape, x: number, y: number, threshold: number): boolean {
    if (shape.points.length === 0) {
      return false;
    }
    const b: ShapeBounds = getShapeBounds(shape);
    return x >= b.minX - threshold && x <= b.maxX + threshold &&
      y >= b.minY - threshold && y <= b.maxY + threshold;
  }

  private edgePoints(shape: Shape): Point[] {
    const pts: Point[] = shape.points;
    if (shape.type === ShapeType.RECT && pts.length === 2) {
      const b: ShapeBounds = getShapeBounds(shape);
      return [
        { x: b.minX, y: b.minY },
        { x: b.maxX, y: b.minY },
        { x: b.maxX, y: b.maxY },
        { x: b.minX, y: b.maxY },
      ];
    }
    return pts;
  }

  private projectOnSegment(x: number, y: number, a: Point, b: Point): Point | null {
    const ex: number = b.x - a.x;
    const ey: number = b.y - a.y;
    const lenSq: number = ex * ex + ey * ey;
    if (lenSq <= 1e-9) {
      return null;
    }
    let t: number = ((x - a.x) * ex + (y - a.y) * ey) / lenSq;
    t = Math.max(0, Math.min(1, t));
    return { x: a.x + ex * t, y: a.y + ey * t };
  }
}

export const snapService: SnapService = new SnapService();
