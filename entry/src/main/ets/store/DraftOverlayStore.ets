/**
 * 鸿图 120fps 瞬态绘制与磁吸视觉引擎状态仓（v7 全工具子模式扩展版）
 *
 * 架构要点：
 * 1. `DraftCanvasEngine` 为纯命令式 120fps 瞬态绘制数据总线，指针高频移动直接调用 `requestRepaint()`，
 *    零 `@State` 写入、零根组件重建；
 * 2. 涵盖矩形（对角框 / 中心外扩 / 定尺寸点放 / 精确数值创建）、多边形（折线正交/45°/自由 + 正 N 边形中心拖拽）、
 *    路径（线宽预设 + PATHTYPE 0/1/2 + 续画）、选择框判定规则（左包右交 / 始终相交 / 始终全包含）、
 *    文本引脚快捷连盖章（VDD/VSS/GND/CLK/PIN++）、曲线及实例盖章全套子模式。
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

/** 画布直接拖拽曲线或正多边形（圆形/圆环/椭圆/圆弧/正N边形）瞬态预览 */
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
export const REGULAR_POLYGON_SIDES_PRESETS: number[] = [3, 4, 5, 6, 8, 12, 16];

/**
 * 低频草稿控制条与工具子模式状态
 */
@Observed
export class DraftControlStore {
  // 选择工具框选规则：0=KLayout/CAD标准（左→右全包含，右→左相交即选）, 1=始终相交即选, 2=始终全包含
  boxSelectRule: number = 0;

  // 多边形与路径控制
  polyActive: boolean = false;
  polygonToolActive: boolean = false;
  pathToolActive: boolean = false;
  isPath: boolean = false;
  /** 多边形绘制子模式：0=逐点折线多边形, 1=正N边形（中心→外接圆半径拖拽） */
  polygonSubMode: number = 0;
  /** 正多边形边数（3~32，默认 6 正六边形，适配光子晶体晶格与电感） */
  regularPolygonSides: number = 6;
  pointCount: number = 0;
  canFinish: boolean = false;
  closeLoopReady: boolean = false;
  routingMode: RoutingMode = RoutingMode.MANHATTAN_90;
  horizontalFirst: boolean = true;
  useLBend: boolean = true;
  pathWidthStr: string = '100';
  /** GDSII PATHTYPE: 0=平头(Flush), 1=圆头(Round), 2=半宽方延(Extended) */
  pathType: number = 0;
  /** 若正在对已有 PATH 进行首尾续画，记录目标图形 ID（-1 为新建） */
  continuingShapeId: number = -1;

  // 矩形绘制增强控制
  rectActive: boolean = false;
  /** 0=对角拉框(Corner→Corner), 1=中心对称外扩(Center→Corner), 2=定宽定高磁吸点放(Fixed W×H) */
  rectDrawMode: number = 0;
  rectSquareLock: boolean = false;
  rectFixedWNmStr: string = '200';
  rectFixedHNmStr: string = '100';
  /** 精确数值创建矩形参数：0=按左下角(X,Y), 1=按中心点(CX,CY) */
  exactRectAnchorMode: number = 1;
  exactRectXStr: string = '0';
  exactRectYStr: string = '0';
  exactRectWStr: string = '1000';
  exactRectHStr: string = '1000';
  showExactRectBar: boolean = false;

  // 文本快捷引脚预设（空字符串=每次点击弹窗输入；非空如 'VDD'/'VSS'/'AUTO_PIN'=点击直接落标签）
  textToolActive: boolean = false;
  textQuickPreset: string = '';
  textAutoPinIndex: number = 1;

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

  rectModeShortBadge(): string {
    if (this.rectDrawMode === 1) return '中心';
    if (this.rectDrawMode === 2) return '定尺';
    return this.rectSquareLock ? '正方' : '对角';
  }

  polygonModeShortBadge(): string {
    if (this.polygonSubMode === 1) return `正${this.regularPolygonSides}`;
    if (this.routingMode === RoutingMode.OCTILINEAR_45) return '45°';
    if (this.routingMode === RoutingMode.FREE) return '自由';
    return '90°';
  }

  boxSelectRuleLabel(): string {
    if (this.boxSelectRule === 1) return '始终相交';
    if (this.boxSelectRule === 2) return '始终全包';
    return '左包右交';
  }

  consumeQuickTextLabel(): string {
    if (this.textQuickPreset.length === 0) return '';
    if (this.textQuickPreset === 'AUTO_PIN') {
      const idx: number = this.textAutoPinIndex;
      this.textAutoPinIndex = idx + 1;
      return `PIN_${idx}`;
    }
    return this.textQuickPreset;
  }

  cycleRegularPolygonSides(): number {
    const idx: number = REGULAR_POLYGON_SIDES_PRESETS.indexOf(this.regularPolygonSides);
    const nextIdx: number = idx >= 0 ? (idx + 1) % REGULAR_POLYGON_SIDES_PRESETS.length : 3;
    this.regularPolygonSides = REGULAR_POLYGON_SIDES_PRESETS[nextIdx];
    return this.regularPolygonSides;
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
    return this.polyActive || this.polygonToolActive || this.pathToolActive ||
      this.curveKind.length > 0 || this.rectActive || this.stampActive || this.textToolActive;
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
