/**
 * 鸿图版图正交/斜角走线约束、测量锁角、导轨移动与交互式曲线几何服务
 *
 * Phase 6 扩展：
 * 1. 支持多边形/路径 90° 正交 L 型拐弯、45° 锁角、自由角；
 * 2. 支持移动工具（Move）与测量尺（Measure）的 90° 正交导轨 / 45° 斜角导轨锁定；
 * 3. 支持圆形（CIRCLE）、圆环（DONUT，带无自交微缝合桥）、椭圆（ELLIPSE）、圆弧（ARC）
 *    在画布上直接按「圆心 → 边缘磁吸点」拖拽生成高精度闭合多边形。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Point } from '../models/GdsiiData';

export enum RoutingMode {
  MANHATTAN_90 = 'manhattan90',
  OCTILINEAR_45 = 'octilinear45',
  FREE = 'free',
}

export interface RoutedSegmentResult {
  previewTail: Point[];
  endPoint: Point;
  angleDeg: number;
  segmentLengthNm: number;
  modeBadge: string;
}

const TAN_22_5: number = 0.41421356237;
const EPSILON_NM: number = 1e-6;

export class RoutingConstraintService {
  effectiveMode(baseMode: RoutingMode, shiftHeld: boolean): RoutingMode {
    if (!shiftHeld) {
      return baseMode;
    }
    return baseMode === RoutingMode.FREE ? RoutingMode.OCTILINEAR_45 : RoutingMode.FREE;
  }

  nextMode(current: RoutingMode): RoutingMode {
    if (current === RoutingMode.MANHATTAN_90) {
      return RoutingMode.OCTILINEAR_45;
    }
    if (current === RoutingMode.OCTILINEAR_45) {
      return RoutingMode.FREE;
    }
    return RoutingMode.MANHATTAN_90;
  }

  modeLabel(mode: RoutingMode): string {
    if (mode === RoutingMode.MANHATTAN_90) {
      return '90°正交';
    }
    if (mode === RoutingMode.OCTILINEAR_45) {
      return '45°锁角';
    }
    return '自由角';
  }

  curveKindLabel(kind: string): string {
    if (kind === 'CIRCLE') return '圆形';
    if (kind === 'DONUT') return '圆环';
    if (kind === 'ELLIPSE') return '椭圆';
    if (kind === 'ARC') return '圆弧';
    return '曲线';
  }

  /** 顶点拖拽正交单轴锁定：保持原顶点的水平 Y 或竖直 X 不变，防止正交多边形边被拖歪 */
  constrainVertexOrtho(origin: Point, target: Point): Point {
    const dx: number = Math.abs(target.x - origin.x);
    const dy: number = Math.abs(target.y - origin.y);
    return dx >= dy
      ? { x: target.x, y: origin.y }
      : { x: origin.x, y: target.y };
  }

  constrainRectEnd(start: Point, rawEnd: Point, lockSquare: boolean, gridStepNm: number = 0): Point {
    if (!lockSquare) {
      return rawEnd;
    }
    const dx: number = rawEnd.x - start.x;
    const dy: number = rawEnd.y - start.y;
    let side: number = Math.max(Math.abs(dx), Math.abs(dy));
    if (gridStepNm > 0) {
      side = Math.round(side / gridStepNm) * gridStepNm;
    }
    const sx: number = dx < 0 ? -1 : 1;
    const sy: number = dy < 0 ? -1 : 1;
    return {
      x: start.x + sx * side,
      y: start.y + sy * side,
    };
  }

  /**
   * 移动工具（Move）位移导轨约束：90°正交锁单轴（水平或竖直导轨），45°锁八方向，自由角不约束
   */
  constrainMoveTarget(
    origin: Point,
    snappedTarget: Point,
    baseMode: RoutingMode,
    shiftHeld: boolean,
    gridStepNm: number = 0,
    exactGeometrySnap: boolean = false
  ): Point {
    if (exactGeometrySnap) {
      return snappedTarget;
    }
    const mode: RoutingMode = this.effectiveMode(baseMode, shiftHeld);
    if (mode === RoutingMode.FREE) {
      return snappedTarget;
    }
    const dx: number = snappedTarget.x - origin.x;
    const dy: number = snappedTarget.y - origin.y;
    const adx: number = Math.abs(dx);
    const ady: number = Math.abs(dy);
    if (mode === RoutingMode.MANHATTAN_90) {
      return adx >= ady
        ? { x: snappedTarget.x, y: origin.y }
        : { x: origin.x, y: snappedTarget.y };
    }
    // 45° 八方向导轨
    const sx: number = dx < 0 ? -1 : 1;
    const sy: number = dy < 0 ? -1 : 1;
    const major: number = Math.max(adx, ady);
    const minor: number = Math.min(adx, ady);
    if (major > 0 && minor / major > TAN_22_5) {
      let diag: number = (adx + ady) * 0.5;
      if (gridStepNm > 0) {
        diag = Math.round(diag / gridStepNm) * gridStepNm;
      }
      return { x: origin.x + sx * diag, y: origin.y + sy * diag };
    }
    return adx >= ady
      ? { x: snappedTarget.x, y: origin.y }
      : { x: origin.x, y: snappedTarget.y };
  }

  /**
   * 测量尺（Measure）终点角度约束（兼容触屏按钮锁角与键盘 Shift 锁角）
   */
  constrainMeasureEnd(
    start: Point,
    snappedTarget: Point,
    angleLock: string,
    shiftHeld: boolean,
    gridStepNm: number = 0
  ): Point {
    const effectiveLock: string = shiftHeld && angleLock === 'free' ? 'diag45' : angleLock;
    if (effectiveLock === 'free') {
      return snappedTarget;
    }
    const dx: number = snappedTarget.x - start.x;
    const dy: number = snappedTarget.y - start.y;
    const adx: number = Math.abs(dx);
    const ady: number = Math.abs(dy);
    if (effectiveLock === 'ortho90') {
      return adx >= ady
        ? { x: snappedTarget.x, y: start.y }
        : { x: start.x, y: snappedTarget.y };
    }
    const sx: number = dx < 0 ? -1 : 1;
    const sy: number = dy < 0 ? -1 : 1;
    const major: number = Math.max(adx, ady);
    const minor: number = Math.min(adx, ady);
    if (major > 0 && minor / major > TAN_22_5) {
      let diag: number = (adx + ady) * 0.5;
      if (gridStepNm > 0) {
        diag = Math.round(diag / gridStepNm) * gridStepNm;
      }
      return { x: start.x + sx * diag, y: start.y + sy * diag };
    }
    return adx >= ady
      ? { x: snappedTarget.x, y: start.y }
      : { x: start.x, y: snappedTarget.y };
  }

  routeNextPoints(
    committed: Point[],
    snappedTarget: Point,
    baseMode: RoutingMode,
    shiftHeld: boolean,
    horizontalFirst: boolean,
    useLBend: boolean = true,
    gridStepNm: number = 0,
    exactSnapHit: boolean = false
  ): RoutedSegmentResult {
    const mode: RoutingMode = this.effectiveMode(baseMode, shiftHeld);
    if (committed.length === 0) {
      return {
        previewTail: [snappedTarget],
        endPoint: snappedTarget,
        angleDeg: 0,
        segmentLengthNm: 0,
        modeBadge: this.modeLabel(mode),
      };
    }

    const anchor: Point = committed[committed.length - 1];
    const dx: number = snappedTarget.x - anchor.x;
    const dy: number = snappedTarget.y - anchor.y;
    const adx: number = Math.abs(dx);
    const ady: number = Math.abs(dy);

    if (adx < EPSILON_NM && ady < EPSILON_NM) {
      return {
        previewTail: [anchor],
        endPoint: anchor,
        angleDeg: 0,
        segmentLengthNm: 0,
        modeBadge: this.modeLabel(mode),
      };
    }

    if (mode === RoutingMode.FREE) {
      const dist: number = Math.hypot(dx, dy);
      const deg: number = Math.atan2(dy, dx) * 180 / Math.PI;
      return {
        previewTail: [snappedTarget],
        endPoint: snappedTarget,
        angleDeg: deg,
        segmentLengthNm: dist,
        modeBadge: '自由角',
      };
    }

    if (mode === RoutingMode.MANHATTAN_90) {
      if (adx < EPSILON_NM || ady < EPSILON_NM) {
        return {
          previewTail: [snappedTarget],
          endPoint: snappedTarget,
          angleDeg: Math.atan2(dy, dx) * 180 / Math.PI,
          segmentLengthNm: adx + ady,
          modeBadge: '90°正交',
        };
      }
      if (useLBend) {
        let hFirst: boolean = horizontalFirst;
        if (committed.length >= 2) {
          const prev: Point = committed[committed.length - 2];
          const pdx: number = Math.abs(anchor.x - prev.x);
          const pdy: number = Math.abs(anchor.y - prev.y);
          if (pdx > EPSILON_NM && pdy < EPSILON_NM) {
            hFirst = !horizontalFirst;
          } else if (pdy > EPSILON_NM && pdx < EPSILON_NM) {
            hFirst = horizontalFirst;
          }
        }
        const elbow: Point = hFirst
          ? { x: snappedTarget.x, y: anchor.y }
          : { x: anchor.x, y: snappedTarget.y };
        const validElbow: boolean =
          (Math.abs(elbow.x - anchor.x) > EPSILON_NM || Math.abs(elbow.y - anchor.y) > EPSILON_NM) &&
          (Math.abs(snappedTarget.x - elbow.x) > EPSILON_NM || Math.abs(snappedTarget.y - elbow.y) > EPSILON_NM);
        const tail: Point[] = validElbow ? [elbow, snappedTarget] : [snappedTarget];
        const primaryDx: number = tail[0].x - anchor.x;
        const primaryDy: number = tail[0].y - anchor.y;
        return {
          previewTail: tail,
          endPoint: snappedTarget,
          angleDeg: Math.atan2(primaryDy, primaryDx) * 180 / Math.PI,
          segmentLengthNm: adx + ady,
          modeBadge: hFirst ? '90°横先' : '90°纵先',
        };
      }
      const orthoEnd: Point = adx >= ady
        ? { x: snappedTarget.x, y: anchor.y }
        : { x: anchor.x, y: snappedTarget.y };
      const odx: number = orthoEnd.x - anchor.x;
      const ody: number = orthoEnd.y - anchor.y;
      return {
        previewTail: [orthoEnd],
        endPoint: orthoEnd,
        angleDeg: Math.atan2(ody, odx) * 180 / Math.PI,
        segmentLengthNm: Math.hypot(odx, ody),
        modeBadge: '90°锁轴',
      };
    }

    if (exactSnapHit && committed.length >= 3 &&
      Math.abs(snappedTarget.x - committed[0].x) < EPSILON_NM &&
      Math.abs(snappedTarget.y - committed[0].y) < EPSILON_NM) {
      return {
        previewTail: [snappedTarget],
        endPoint: snappedTarget,
        angleDeg: Math.atan2(dy, dx) * 180 / Math.PI,
        segmentLengthNm: Math.hypot(dx, dy),
        modeBadge: '闭合首点',
      };
    }

    const sx: number = dx < 0 ? -1 : 1;
    const sy: number = dy < 0 ? -1 : 1;
    const major: number = Math.max(adx, ady);
    const minor: number = Math.min(adx, ady);
    let endPt: Point;
    if (major > 0 && minor / major > TAN_22_5) {
      let diag: number = (adx + ady) * 0.5;
      if (gridStepNm > 0) {
        diag = Math.round(diag / gridStepNm) * gridStepNm;
      }
      endPt = {
        x: anchor.x + sx * diag,
        y: anchor.y + sy * diag,
      };
    } else if (adx >= ady) {
      endPt = { x: snappedTarget.x, y: anchor.y };
    } else {
      endPt = { x: anchor.x, y: snappedTarget.y };
    }
    const rdx: number = endPt.x - anchor.x;
    const rdy: number = endPt.y - anchor.y;
    return {
      previewTail: [endPt],
      endPoint: endPt,
      angleDeg: Math.atan2(rdy, rdx) * 180 / Math.PI,
      segmentLengthNm: Math.hypot(rdx, rdy),
      modeBadge: '45°锁角',
    };
  }

  /**
   * 交互式曲线直接拖拽多边形生成器（支持圆形、圆环、椭圆、圆弧）
   * 输出严格满足 GDSII 无自交单轮廓多边形规范
   */
  buildInteractiveCurvePolygon(
    kind: string,
    center: Point,
    edgePt: Point,
    segments: number = 64,
    innerRatioPct: number = 60,
    arcSweepDeg: number = 180,
    clockwise: boolean = false,
    fixedRingWidthNm: number = 0
  ): Point[] {
    const dx: number = edgePt.x - center.x;
    const dy: number = edgePt.y - center.y;
    const radius: number = Math.hypot(dx, dy);
    if (!Number.isFinite(radius) || radius < 1) {
      return [];
    }
    const segs: number = Math.max(16, Math.min(256, Math.round(segments)));
    const ratio: number = Math.max(0.10, Math.min(0.95, innerRatioPct / 100));
    const useFixedW: boolean = Number.isFinite(fixedRingWidthNm) && fixedRingWidthNm > 0;

    if (kind === 'ELLIPSE') {
      const rx: number = Math.max(2, Math.abs(dx));
      const ry: number = Math.max(2, Math.abs(dy));
      const pts: Point[] = [];
      for (let i = 0; i < segs; i++) {
        const theta: number = (2 * Math.PI * i) / segs;
        pts.push({
          x: Math.round(center.x + rx * Math.cos(theta)),
          y: Math.round(center.y + ry * Math.sin(theta)),
        });
      }
      return this.dedupAdjacentPoints(pts);
    }

    if (kind === 'DONUT') {
      const rInner: number = useFixedW
        ? (radius > fixedRingWidthNm + 1 ? radius - fixedRingWidthNm : Math.max(1, radius * 0.25))
        : Math.max(1, radius * ratio);
      if (radius - rInner < 1) {
        return [];
      }
      const slitRad: number = 0.0015;
      const startAngle: number = Math.atan2(dy, dx);
      const span: number = 2 * Math.PI - slitRad * 2;
      const pts: Point[] = [];
      for (let i = 0; i <= segs; i++) {
        const a: number = startAngle + slitRad + (span * i) / segs;
        pts.push({
          x: Math.round(center.x + radius * Math.cos(a)),
          y: Math.round(center.y + radius * Math.sin(a)),
        });
      }
      for (let i = segs; i >= 0; i--) {
        const a: number = startAngle + slitRad + (span * i) / segs;
        pts.push({
          x: Math.round(center.x + rInner * Math.cos(a)),
          y: Math.round(center.y + rInner * Math.sin(a)),
        });
      }
      return this.dedupAdjacentPoints(pts);
    }

    if (kind === 'ARC') {
      const rInner: number = useFixedW
        ? (radius > fixedRingWidthNm + 1 ? radius - fixedRingWidthNm : Math.max(1, radius * 0.25))
        : Math.max(1, radius * ratio);
      if (radius - rInner < 1) {
        return [];
      }
      const startAngle: number = Math.atan2(dy, dx);
      const absSweepRad: number = Math.max(15, Math.min(350, arcSweepDeg)) * Math.PI / 180;
      const signedSweep: number = clockwise ? -absSweepRad : absSweepRad;
      const arcSegs: number = Math.max(12, Math.round(segs * (absSweepRad / (2 * Math.PI))));
      const pts: Point[] = [];
      for (let i = 0; i <= arcSegs; i++) {
        const a: number = startAngle + (signedSweep * i) / arcSegs;
        pts.push({
          x: Math.round(center.x + radius * Math.cos(a)),
          y: Math.round(center.y + radius * Math.sin(a)),
        });
      }
      for (let i = arcSegs; i >= 0; i--) {
        const a: number = startAngle + (signedSweep * i) / arcSegs;
        pts.push({
          x: Math.round(center.x + rInner * Math.cos(a)),
          y: Math.round(center.y + rInner * Math.sin(a)),
        });
      }
      return this.dedupAdjacentPoints(pts);
    }

    // 默认 CIRCLE
    const pts: Point[] = [];
    for (let i = 0; i < segs; i++) {
      const theta: number = (2 * Math.PI * i) / segs;
      pts.push({
        x: Math.round(center.x + radius * Math.cos(theta)),
        y: Math.round(center.y + radius * Math.sin(theta)),
      });
    }
    return this.dedupAdjacentPoints(pts);
  }

  private dedupAdjacentPoints(pts: Point[]): Point[] {
    if (pts.length === 0) return [];
    const out: Point[] = [pts[0]];
    for (let i = 1; i < pts.length; i++) {
      const prev: Point = out[out.length - 1];
      if (pts[i].x !== prev.x || pts[i].y !== prev.y) {
        out.push(pts[i]);
      }
    }
    if (out.length > 2 && out[0].x === out[out.length - 1].x && out[0].y === out[out.length - 1].y) {
      out.pop();
    }
    return out;
  }

  buildPathEnvelopePolygon(centerline: Point[], widthNm: number, pathType: number = 0): Point[] {
    if (!Number.isFinite(widthNm) || widthNm <= 0 || centerline.length < 2) {
      return [];
    }
    const clean: Point[] = [{ x: centerline[0].x, y: centerline[0].y }];
    for (let i = 1; i < centerline.length; i++) {
      const prev: Point = clean[clean.length - 1];
      const cur: Point = centerline[i];
      if (Math.hypot(cur.x - prev.x, cur.y - prev.y) > EPSILON_NM) {
        clean.push({ x: cur.x, y: cur.y });
      }
    }
    if (clean.length < 2) {
      return [];
    }
    // PATHTYPE=2: 首尾两端各沿切线方向外延半个线宽
    if (pathType === 2) {
      const halfExt: number = widthNm * 0.5;
      const d0x: number = clean[1].x - clean[0].x;
      const d0y: number = clean[1].y - clean[0].y;
      const l0: number = Math.hypot(d0x, d0y);
      if (l0 > EPSILON_NM) {
        clean[0] = { x: clean[0].x - (d0x / l0) * halfExt, y: clean[0].y - (d0y / l0) * halfExt };
      }
      const last: number = clean.length - 1;
      const d1x: number = clean[last].x - clean[last - 1].x;
      const d1y: number = clean[last].y - clean[last - 1].y;
      const l1: number = Math.hypot(d1x, d1y);
      if (l1 > EPSILON_NM) {
        clean[last] = { x: clean[last].x + (d1x / l1) * halfExt, y: clean[last].y + (d1y / l1) * halfExt };
      }
    }

    const halfW: number = widthNm * 0.5;
    const segNormals: Point[] = [];
    for (let i = 0; i < clean.length - 1; i++) {
      const dx: number = clean[i + 1].x - clean[i].x;
      const dy: number = clean[i + 1].y - clean[i].y;
      const len: number = Math.hypot(dx, dy);
      segNormals.push({ x: -dy / len, y: dx / len });
    }

    const leftSide: Point[] = [];
    const rightSide: Point[] = [];
    const miterLimit: number = 2.2;

    for (let i = 0; i < clean.length; i++) {
      const p: Point = clean[i];
      if (i === 0) {
        const n: Point = segNormals[0];
        leftSide.push({ x: p.x + n.x * halfW, y: p.y + n.y * halfW });
        rightSide.push({ x: p.x - n.x * halfW, y: p.y - n.y * halfW });
      } else if (i === clean.length - 1) {
        const n: Point = segNormals[segNormals.length - 1];
        leftSide.push({ x: p.x + n.x * halfW, y: p.y + n.y * halfW });
        rightSide.push({ x: p.x - n.x * halfW, y: p.y - n.y * halfW });
      } else {
        const n0: Point = segNormals[i - 1];
        const n1: Point = segNormals[i];
        const mx: number = n0.x + n1.x;
        const my: number = n0.y + n1.y;
        const mLenSq: number = mx * mx + my * my;
        if (mLenSq < 1e-4) {
          leftSide.push({ x: p.x + n0.x * halfW, y: p.y + n0.y * halfW });
          leftSide.push({ x: p.x + n1.x * halfW, y: p.y + n1.y * halfW });
          rightSide.push({ x: p.x - n0.x * halfW, y: p.y - n0.y * halfW });
          rightSide.push({ x: p.x - n1.x * halfW, y: p.y - n1.y * halfW });
        } else {
          const mLen: number = Math.sqrt(mLenSq);
          const ux: number = mx / mLen;
          const uy: number = my / mLen;
          const dot: number = ux * n1.x + uy * n1.y;
          const scale: number = dot > 0.1 ? Math.min(miterLimit, 1.0 / dot) : miterLimit;
          leftSide.push({ x: p.x + ux * halfW * scale, y: p.y + uy * halfW * scale });
          rightSide.push({ x: p.x - ux * halfW * scale, y: p.y - uy * halfW * scale });
        }
      }
    }

    const polygon: Point[] = [];
    for (let i = 0; i < leftSide.length; i++) {
      polygon.push(leftSide[i]);
    }
    if (pathType === 1) {
      const endPt: Point = clean[clean.length - 1];
      const nEnd: Point = segNormals[segNormals.length - 1];
      const baseAngle: number = Math.atan2(nEnd.y, nEnd.x);
      for (let s = 1; s < 6; s++) {
        const a: number = baseAngle - (Math.PI * s) / 6;
        polygon.push({ x: endPt.x + Math.cos(a) * halfW, y: endPt.y + Math.sin(a) * halfW });
      }
    }
    for (let i = rightSide.length - 1; i >= 0; i--) {
      polygon.push(rightSide[i]);
    }
    if (pathType === 1) {
      const startPt: Point = clean[0];
      const nStart: Point = segNormals[0];
      const baseAngle: number = Math.atan2(-nStart.y, -nStart.x);
      for (let s = 1; s < 6; s++) {
        const a: number = baseAngle - (Math.PI * s) / 6;
        polygon.push({ x: startPt.x + Math.cos(a) * halfW, y: startPt.y + Math.sin(a) * halfW });
      }
    }
    return polygon;
  }
}

export const routingConstraintService: RoutingConstraintService = new RoutingConstraintService();
