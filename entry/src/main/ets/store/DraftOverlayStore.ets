/**
 * 鸿图 120fps 瞬态绘制与磁吸视觉引擎状态仓（Phase 8 全链路绘图增强版）
 *
 * 架构要点：
 * 1. `DraftCanvasEngine` 为纯命令式 120fps 瞬态绘制数据总线，指针高频移动直接调用 `requestRepaint()`，
 *    零 `@State` 写入、零根组件重建；
 * 2. 新增 `DraftStampPreview`（子单元实例与 PCell 器件 120fps 幽灵外框+端口跟随点放）、矩形中心外扩与定尺寸预览、
 *    路径端头（PATHTYPE 0/1/2）与首尾续画状态、以及圆环/圆弧固定波导环宽与 45°/顺逆时针控制。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Point } from '../models/GdsiiData';
import { AlignmentGuide, SnapMarker } from '../services/SnapService';
import { RoutingMode } from '../services/RoutingConstraintService';

export interface DraftRectPreview {
  x: number;
  y: number;
  w: number;
  h: number;
  layerColor: string;
  centerAnchor?: Point;
}

export interface DraftPolyPreview {
  isPath: boolean;
  committed: Point[];
  liveTail: Point[];
  pathWidthNm: number;
  pathType: number;
  layerColor: string;
  closeLoopReady: boolean;
}

/** 画布直接拖拽曲线（圆形/圆环/椭圆/圆弧）瞬态预览 */
export interface DraftCurvePreview {
  kind: string;
  center: Point;
  edge: Point;
  points: Point[];
  layerColor: string;
}

/** 子单元实例 / 参数化器件 PCell 120fps 画布磁吸点放幽灵预览 */
export interface DraftStampPreview {
  anchor: Point;
  label: string;
  rotation: number;
  mirror: number;
  outlines: DraftGhostOutline[];
  ports: Point[];
}

/** 测量尺正交直角三角分解虚线预览（世界坐标 nm） */
export interface DraftMeasureTriangle {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

export interface DraftGhostOutline {
  closed: boolean;
  points: Point[];
  color: string;
}

export interface DraftMovePreview {
  fromX: number;
  fromY: number;
  dxNm: number;
  dyNm: number;
  outlines: DraftGhostOutline[];
}

export interface DraftBoxPreview {
  x: number;
  y: number;
  w: number;
  h: number;
  leftToRight: boolean;
  isBoxZoom: boolean;
}

export interface DraftCursorHud {
  screenX: number;
  screenY: number;
  primaryText: string;
  secondaryText: string;
}

export interface DraftLoupeShape {
  closed: boolean;
  points: Point[];
  color: string;
}

export interface DraftStampTemplate {
  outlines: DraftGhostOutline[];
  ports: Point[];
}

export interface DraftTouchLoupe {
  active: boolean;
  fingerScreenX: number;
  fingerScreenY: number;
  snappedWorldX: number;
  snappedWorldY: number;
  gridStepNm: number;
  badgeText: string;
  localShapes: DraftLoupeShape[];
}

export const CURVE_KIND_ORDER: string[] = ['CIRCLE', 'DONUT', 'ELLIPSE', 'ARC'];

/**
 * 低频草稿控制条状态（页面 `@State` 持有，`LayoutCanvasView` / `DraftOverlayLayer` 以 `@ObjectLink` 透传，
 * 仅 `DraftOverlayLayer` 内各叶子浮条观察其属性）
 */
@Observed
export class DraftControlStore {
  // 多边形与路径控制
  polyActive: boolean = false;
  isPath: boolean = false;
  pointCount: number = 0;
  canFinish: boolean = false;
  closeLoopReady: boolean = false;
  routingMode: RoutingMode = RoutingMode.MANHATTAN_90;
  horizontalFirst: boolean = true;
  useLBend: boolean = true;
  pathWidthStr: string = '8';
  /** GDSII PATHTYPE: 0=平头(Flush), 1=圆头(Round), 2=半宽方延(Extended) */
  pathType: number = 0;
  /** 若正在对已有 PATH 进行首尾续画，记录目标图形 ID（-1 为新建） */
  continuingShapeId: number = -1;

  // 矩形绘制增强控制
  rectActive: boolean = false;
  /** 0=对角拉框, 1=中心对称外扩, 2=定宽定高磁吸点放 */
  rectDrawMode: number = 0;
  rectSquareLock: boolean = false;
  rectFixedWNmStr: string = '200';
  rectFixedHNmStr: string = '100';

  // 交互式曲线绘制模式
  curveKind: string = '';
  /** 圆环/圆弧内径百分比（40 / 60 / 75） */
  curveInnerRatioPct: number = 60;
  /** 是否改用固定波导/护环线宽（outerR - innerR 恒定 nm） */
  curveUseFixedWidth: boolean = false;
  curveRingWidthNmStr: string = '100';
  /** 圆弧角度跨度（45 / 90 / 180 / 270） */
  curveArcSweepDeg: number = 90;
  /** 圆弧顺时针张开开关 */
  curveArcClockwise: boolean = false;

  // 实例与 PCell 画布幽灵盖章放置态
  stampActive: boolean = false;
  stampIsPCell: boolean = false;
  stampLabel: string = '';
  stampRotation: number = 0;
  stampMirror: number = 0;
  stampContinuous: boolean = true;

  syncPolyState(active: boolean, isPath: boolean, count: number, closeReady: boolean = false): void {
    if (this.polyActive !== active) this.polyActive = active;
    if (this.isPath !== isPath) this.isPath = isPath;
    if (this.pointCount !== count) this.pointCount = count;
    const finishable: boolean = active && (isPath ? count >= 2 : count >= 3);
    if (this.canFinish !== finishable) this.canFinish = finishable;
    if (this.closeLoopReady !== closeReady) this.closeLoopReady = closeReady;
  }

  resetPoly(): void {
    this.continuingShapeId = -1;
    this.syncPolyState(false, false, 0, false);
  }

  resetStamp(): void {
    if (this.stampActive) this.stampActive = false;
    if (this.stampLabel.length > 0) this.stampLabel = '';
  }

  routingModeIndex(): number {
    if (this.routingMode === RoutingMode.OCTILINEAR_45) return 1;
    if (this.routingMode === RoutingMode.FREE) return 2;
    return 0;
  }

  static routingModeForIndex(index: number): RoutingMode {
    if (index === 1) return RoutingMode.OCTILINEAR_45;
    if (index === 2) return RoutingMode.FREE;
    return RoutingMode.MANHATTAN_90;
  }

  cyclePathType(): void {
    if (this.pathType === 0) {
      this.pathType = 1;
    } else if (this.pathType === 1) {
      this.pathType = 2;
    } else {
      this.pathType = 0;
    }
  }

  pathTypeLabel(): string {
    if (this.pathType === 1) return '端头:圆头';
    if (this.pathType === 2) return '端头:方延';
    return '端头:平齐';
  }

  swapRectFixedDimensions(): void {
    const tmp: string = this.rectFixedWNmStr;
    this.rectFixedWNmStr = this.rectFixedHNmStr;
    this.rectFixedHNmStr = tmp;
  }

  curveKindIndex(): number {
    const idx: number = CURVE_KIND_ORDER.indexOf(this.curveKind);
    return idx >= 0 ? idx : 0;
  }

  static curveKindForIndex(index: number): string {
    return CURVE_KIND_ORDER[index] ?? 'CIRCLE';
  }

  cycleInnerRatio(): void {
    if (this.curveInnerRatioPct === 40) {
      this.curveInnerRatioPct = 60;
    } else if (this.curveInnerRatioPct === 60) {
      this.curveInnerRatioPct = 75;
    } else {
      this.curveInnerRatioPct = 40;
    }
  }

  cycleArcSweep(): void {
    if (this.curveArcSweepDeg === 45) {
      this.curveArcSweepDeg = 90;
    } else if (this.curveArcSweepDeg === 90) {
      this.curveArcSweepDeg = 180;
    } else if (this.curveArcSweepDeg === 180) {
      this.curveArcSweepDeg = 270;
    } else {
      this.curveArcSweepDeg = 45;
    }
  }

  cycleStampRotation(): number {
    this.stampRotation = (this.stampRotation + 90) % 360;
    return this.stampRotation;
  }

  cycleStampMirror(): number {
    this.stampMirror = (this.stampMirror + 1) % 3;
    return this.stampMirror;
  }

  stampMirrorLabel(): string {
    if (this.stampMirror === 1) return '镜像:X';
    if (this.stampMirror === 2) return '镜像:Y';
    return '无镜像';
  }

  hasAnyTopStrip(): boolean {
    return this.polyActive || this.curveKind.length > 0 || this.rectActive || this.stampActive;
  }
}

/**
 * 120fps 命令式瞬态绘制引擎
 */
export class DraftCanvasEngine {
  rectPreview: DraftRectPreview | null = null;
  polyPreview: DraftPolyPreview | null = null;
  curvePreview: DraftCurvePreview | null = null;
  stampPreview: DraftStampPreview | null = null;
  measureTriangle: DraftMeasureTriangle | null = null;
  movePreview: DraftMovePreview | null = null;
  boxPreview: DraftBoxPreview | null = null;
  snapMarker: SnapMarker | null = null;
  alignmentGuides: AlignmentGuide[] = [];
  cursorHud: DraftCursorHud | null = null;
  loupe: DraftTouchLoupe | null = null;

  private repaintCallback: (() => void) | null = null;

  bindRepaint(callback: (() => void) | null): void {
    this.repaintCallback = callback;
  }

  requestRepaint(): void {
    if (this.repaintCallback !== null) {
      this.repaintCallback();
    }
  }

  hasAnyOverlay(): boolean {
    return this.rectPreview !== null ||
      this.polyPreview !== null ||
      this.curvePreview !== null ||
      this.stampPreview !== null ||
      this.measureTriangle !== null ||
      this.movePreview !== null ||
      this.boxPreview !== null ||
      this.snapMarker !== null ||
      this.alignmentGuides.length > 0 ||
      this.cursorHud !== null ||
      (this.loupe !== null && this.loupe.active);
  }

  clearTransientPointerVisuals(keepPolyCommitted: boolean = true, keepStamp: boolean = false): void {
    this.rectPreview = null;
    this.curvePreview = null;
    if (!keepStamp) {
      this.stampPreview = null;
    }
    this.measureTriangle = null;
    this.movePreview = null;
    this.boxPreview = null;
    this.snapMarker = null;
    this.alignmentGuides = [];
    this.cursorHud = null;
    this.loupe = null;
    if (!keepPolyCommitted) {
      this.polyPreview = null;
    } else if (this.polyPreview !== null) {
      this.polyPreview = {
        isPath: this.polyPreview.isPath,
        committed: this.polyPreview.committed,
        liveTail: [],
        pathWidthNm: this.polyPreview.pathWidthNm,
        pathType: this.polyPreview.pathType,
        layerColor: this.polyPreview.layerColor,
        closeLoopReady: false,
      };
    }
    this.requestRepaint();
  }

  clearAll(): void {
    this.clearTransientPointerVisuals(false, false);
  }
}

export const draftCanvasEngine: DraftCanvasEngine = new DraftCanvasEngine();
