/**
 * 鸿图独立 120fps 瞬态绘制与磁吸反馈画布层（Phase 6 双技能合规版）
 *
 * 合规与体验要点：
 * 1. 严格遵循 `@Observed` + `@ObjectLink` 叶子观察契约，`DraftOverlayLayer.build()` 不直接读取 `controlStore` 字段，
 *    仅下沉至 `DraftPolyControlStrip` 与 `DraftCurveControlStrip` 叶子响应；
 * 2. 原生组件优先：走线约束（`90°正交 / 45°锁角 / 自由角`）与曲线类别（`圆形 / 圆环 / 椭圆 / 圆弧`）切换全面接入受控
 *    `StableSegmentButton`（`SegmentButton`），正交拐向、内径比、角度跨度接入官方 `Chip`（外包 `Row({ space: 6 })`，
 *    严守不在 `Chip` 上挂载通用属性以免产生 `__Common__` 节点）；
 * 3. 四层光感材质与物理弹簧：浮条挂载第二层 `luminousFloatingModifier` + `panelTransition(TransitionEdge.TOP)`
 *    （`0.92` 保活透明度 + `GravityCurve.transition` 临界阻尼弹簧），操作按钮全部挂载第四层 `luminousPointLightModifier()`；
 * 4. 全量接入 `ThemeStore` 语义色 Token、`ZIndexTokens` 与官方 `CanvasRenderingContext2D.font` 标准字重语法。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import {
  AccessibilitySelectedType,
  Chip,
  ChipSize,
  FrameCallback,
  SegmentButtonItemTuple,
  SegmentButtonTextItem,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { Point } from '../../models/GdsiiData';
import { COLORS, worldToScreenPx, worldToScreenYpx } from '../../common/constants';
import { resetModifierKeys } from '../../common/ModifierKeys';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { withAlpha } from '../../common/MaterialTokens';
import { panelTransition } from '../../common/Motion';
import { hongTuThemeState, SemanticThemePalette, ZIndexTokens } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { AlignmentGuide, SnapMarker } from '../../services/SnapService';
import { RoutingMode, routingConstraintService } from '../../services/RoutingConstraintService';
import {
  DraftBoxPreview,
  draftCanvasEngine,
  DraftControlStore,
  DraftCursorHud,
  DraftCurvePreview,
  DraftGhostOutline,
  DraftLoupeShape,
  DraftMeasureTriangle,
  DraftMovePreview,
  DraftPolyPreview,
  DraftRectPreview,
  DraftStampPreview,
  DraftTouchLoupe,
} from '../../store/DraftOverlayStore';

class DraftCanvasAreaRepaintFrame extends FrameCallback {
  private readonly action: () => void;
  constructor(action: () => void) {
    super();
    this.action = action;
  }
  onFrame(_frameTimeInNano: number): void {
    this.action();
  }
}

@Component
export struct DraftOverlayLayer {
  @ObjectLink controlStore: DraftControlStore;
  @Prop @Watch('onViewportChanged') zoomPercent: number = 100;
  @Prop @Watch('onViewportChanged') viewOffsetX: number = 0;
  @Prop @Watch('onViewportChanged') viewOffsetY: number = 0;
  @Prop @Watch('onViewportChanged') canvasWidth: number = 800;
  @Prop @Watch('onViewportChanged') canvasHeight: number = 600;
  @Prop desktopMode: boolean = false;
  @Prop topStripY: number = 52;
  @Prop stepUnitNm: number = 10;

  onFinishPoly: () => void = () => {};
  onCancelPoly: () => void = () => {};
  onUndoPolyVertex: () => void = () => {};
  onSelectRoutingMode: (mode: RoutingMode) => void = (_m: RoutingMode) => {};
  onCycleRoutingMode: () => void = () => {};
  onFlipPosture: () => void = () => {};
  onPathWidthEdited: (widthStr: string) => void = (_w: string) => {};
  onPathTypeChanged: () => void = () => {};
  onSelectCurveKind: (kind: string) => void = (_k: string) => {};
  onOpenExactCurveDialog: (kind: string) => void = (_k: string) => {};
  onExitCurveMode: () => void = () => {};
  onOpenStampDialog: () => void = () => {};
  onStampTransformChanged: () => void = () => {};
  onExitStampMode: () => void = () => {};

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;
  private measuredCanvasWidth: number = 0;
  private measuredCanvasHeight: number = 0;

  private scheduleAreaRepaint(): void {
    try {
      this.getUIContext().postFrameCallback(new DraftCanvasAreaRepaintFrame((): void => {
        this.repaint();
      }));
    } catch (_err) {
      // 单元测试或脱离 UI 上下文时降级为同步重绘
    }
  }

  aboutToAppear(): void {
    draftCanvasEngine.bindRepaint(() => {
      this.repaint();
    });
  }

  aboutToDisappear(): void {
    draftCanvasEngine.bindRepaint(null);
  }

  private onViewportChanged(): void {
    this.repaint();
  }

  private isLightCanvas(): boolean {
    return !hongTuThemeState.isDark && COLORS.canvasBg === hongTuThemeState.colors.surface;
  }

  private palette(): SemanticThemePalette {
    return hongTuThemeState.colors;
  }

  private sx(worldX: number): number {
    return worldToScreenPx(worldX, this.zoomPercent, this.viewOffsetX);
  }

  private sy(worldY: number): number {
    return worldToScreenYpx(worldY, this.zoomPercent, this.viewOffsetY);
  }

  private repaint(): void {
    if (!this.canvasReady) {
      return;
    }
    const w: number = Math.max(1, this.measuredCanvasWidth > 0 ? this.measuredCanvasWidth : this.canvasWidth);
    const h: number = Math.max(1, this.measuredCanvasHeight > 0 ? this.measuredCanvasHeight : this.canvasHeight);
    const clearW: number = Math.max(w, this.canvasWidth, this.ctx.width || 0);
    const clearH: number = Math.max(h, this.canvasHeight, this.ctx.height || 0);
    const c: CanvasRenderingContext2D = this.ctx;
    c.clearRect(0, 0, clearW, clearH);

    if (!draftCanvasEngine.hasAnyOverlay()) {
      return;
    }

    const light: boolean = this.isLightCanvas();
    c.lineCap = 'round';
    c.lineJoin = 'round';

    if (draftCanvasEngine.alignmentGuides.length > 0) {
      this.drawAlignmentGuides(c, draftCanvasEngine.alignmentGuides);
    }
    if (draftCanvasEngine.measureTriangle !== null) {
      this.drawMeasureTriangle(c, draftCanvasEngine.measureTriangle);
    }
    if (draftCanvasEngine.rectPreview !== null) {
      this.drawRectPreview(c, draftCanvasEngine.rectPreview, light);
    }
    if (draftCanvasEngine.curvePreview !== null) {
      this.drawCurvePreview(c, draftCanvasEngine.curvePreview, light);
    }
    if (draftCanvasEngine.polyPreview !== null) {
      this.drawPolyPreview(c, draftCanvasEngine.polyPreview, light);
    }
    if (draftCanvasEngine.stampPreview !== null) {
      this.drawStampPreview(c, draftCanvasEngine.stampPreview, light);
    }
    if (draftCanvasEngine.movePreview !== null) {
      this.drawMovePreview(c, draftCanvasEngine.movePreview, light);
    }
    if (draftCanvasEngine.boxPreview !== null) {
      this.drawBoxPreview(c, draftCanvasEngine.boxPreview);
    }
    if (draftCanvasEngine.snapMarker !== null) {
      const mx: number = this.sx(draftCanvasEngine.snapMarker.point.x);
      const my: number = this.sy(draftCanvasEngine.snapMarker.point.y);
      this.drawSnapMarkerAt(c, mx, my, draftCanvasEngine.snapMarker);
    }

    let loupeCenterY: number = -999;
    if (draftCanvasEngine.loupe !== null && draftCanvasEngine.loupe.active) {
      loupeCenterY = this.drawTouchLoupe(c, draftCanvasEngine.loupe, w, h, light);
    }
    if (draftCanvasEngine.cursorHud !== null) {
      this.drawCursorHud(c, draftCanvasEngine.cursorHud, w, h, loupeCenterY > 0);
    }
  }

  private drawMeasureTriangle(c: CanvasRenderingContext2D, tri: DraftMeasureTriangle): void {
    const sx1: number = this.sx(tri.x1);
    const sy1: number = this.sy(tri.y1);
    const sx2: number = this.sx(tri.x2);
    const sy2: number = this.sy(tri.y2);
    const adx: number = Math.abs(sx2 - sx1);
    const ady: number = Math.abs(sy2 - sy1);
    if (adx < 6 || ady < 6) {
      return;
    }
    const pal: SemanticThemePalette = this.palette();
    c.save();
    c.strokeStyle = withAlpha(pal.success, 0.72);
    c.lineWidth = 1.35;
    c.setLineDash([4, 4]);
    c.beginPath();
    c.moveTo(sx1, sy1);
    c.lineTo(sx2, sy1);
    c.lineTo(sx2, sy2);
    c.stroke();

    if (adx >= 14 && ady >= 14) {
      const signX: number = sx1 < sx2 ? -1 : 1;
      const signY: number = sy2 > sy1 ? 1 : -1;
      c.setLineDash([]);
      c.beginPath();
      c.moveTo(sx2 + signX * 6, sy1);
      c.lineTo(sx2 + signX * 6, sy1 + signY * 6);
      c.lineTo(sx2, sy1 + signY * 6);
      c.stroke();
    }
    c.restore();
  }

  private drawCurvePreview(c: CanvasRenderingContext2D, curve: DraftCurvePreview, light: boolean): void {
    const cx: number = this.sx(curve.center.x);
    const cy: number = this.sy(curve.center.y);
    const ex: number = this.sx(curve.edge.x);
    const ey: number = this.sy(curve.edge.y);
    const pal: SemanticThemePalette = this.palette();

    c.save();
    if (curve.points.length >= 3) {
      c.setLineDash([]);
      c.beginPath();
      c.moveTo(this.sx(curve.points[0].x), this.sy(curve.points[0].y));
      for (let i = 1; i < curve.points.length; i++) {
        c.lineTo(this.sx(curve.points[i].x), this.sy(curve.points[i].y));
      }
      c.closePath();
      c.fillStyle = withAlpha(curve.layerColor, light ? 0.16 : 0.24);
      c.fill();
      c.strokeStyle = curve.layerColor;
      c.lineWidth = 1.75;
      c.stroke();
    }

    c.strokeStyle = pal.warning;
    c.lineWidth = 1.4;
    c.setLineDash([4, 3]);
    c.beginPath();
    c.moveTo(cx, cy);
    c.lineTo(ex, ey);
    c.stroke();

    c.setLineDash([]);
    c.beginPath();
    c.moveTo(cx - 5, cy);
    c.lineTo(cx + 5, cy);
    c.moveTo(cx, cy - 5);
    c.lineTo(cx, cy + 5);
    c.stroke();
    c.restore();
  }

  private drawAlignmentGuides(c: CanvasRenderingContext2D, guides: AlignmentGuide[]): void {
    const pal: SemanticThemePalette = this.palette();
    c.save();
    c.strokeStyle = pal.teal;
    c.lineWidth = 1.35;

    for (let i = 0; i < guides.length; i++) {
      const g: AlignmentGuide = guides[i];
      const x1: number = this.sx(g.fromPoint.x);
      const y1: number = this.sy(g.fromPoint.y);
      const x2: number = this.sx(g.toPoint.x);
      const y2: number = this.sy(g.toPoint.y);

      const dx: number = x2 - x1;
      const dy: number = y2 - y1;
      const len: number = Math.hypot(dx, dy);
      const extX: number = len > 1 ? x2 + (dx / len) * 14 : x2;
      const extY: number = len > 1 ? y2 + (dy / len) * 14 : y2;

      c.setLineDash([5, 4]);
      c.beginPath();
      c.moveTo(x1, y1);
      c.lineTo(extX, extY);
      c.stroke();

      c.setLineDash([]);
      c.beginPath();
      c.moveTo(x1 - 4, y1);
      c.lineTo(x1 + 4, y1);
      c.moveTo(x1, y1 - 4);
      c.lineTo(x1, y1 + 4);
      c.stroke();
    }
    c.restore();
  }

  private drawRectPreview(c: CanvasRenderingContext2D, rect: DraftRectPreview, light: boolean): void {
    const left: number = this.sx(rect.x);
    const top: number = this.sy(rect.y + rect.h);
    const width: number = Math.max(1, rect.w * this.zoomPercent / 100);
    const height: number = Math.max(1, rect.h * this.zoomPercent / 100);

    c.save();
    c.setLineDash([]);
    c.fillStyle = withAlpha(rect.layerColor, light ? 0.16 : 0.24);
    c.fillRect(left, top, width, height);

    c.strokeStyle = rect.layerColor;
    c.lineWidth = 1.65;
    c.strokeRect(left, top, width, height);

    if (rect.centerAnchor !== undefined) {
      const acx: number = this.sx(rect.centerAnchor.x);
      const acy: number = this.sy(rect.centerAnchor.y);
      c.strokeStyle = this.palette().warning;
      c.lineWidth = 1.4;
      c.setLineDash([4, 3]);
      c.beginPath();
      c.moveTo(acx, acy);
      c.lineTo(left + width, top);
      c.stroke();
      c.setLineDash([]);
      c.beginPath();
      c.moveTo(acx - 6, acy);
      c.lineTo(acx + 6, acy);
      c.moveTo(acx, acy - 6);
      c.lineTo(acx, acy + 6);
      c.stroke();
    } else if (width >= 20 && height >= 20) {
      const cx: number = left + width * 0.5;
      const cy: number = top + height * 0.5;
      c.strokeStyle = withAlpha(rect.layerColor, 0.72);
      c.lineWidth = 1.35;
      c.beginPath();
      c.moveTo(cx - 5, cy);
      c.lineTo(cx + 5, cy);
      c.moveTo(cx, cy - 5);
      c.lineTo(cx, cy + 5);
      c.stroke();
    }
    c.restore();
  }

  private drawStampPreview(c: CanvasRenderingContext2D, stamp: DraftStampPreview, light: boolean): void {
    const pal: SemanticThemePalette = this.palette();
    const ax: number = this.sx(stamp.anchor.x);
    const ay: number = this.sy(stamp.anchor.y);
    c.save();
    for (let i = 0; i < stamp.outlines.length; i++) {
      const item: DraftGhostOutline = stamp.outlines[i];
      if (item.points.length < 2) continue;
      c.setLineDash([5, 3]);
      c.lineWidth = 1.65;
      c.strokeStyle = item.color;
      c.fillStyle = withAlpha(item.color, light ? 0.14 : 0.22);
      c.beginPath();
      c.moveTo(this.sx(stamp.anchor.x + item.points[0].x), this.sy(stamp.anchor.y + item.points[0].y));
      for (let j = 1; j < item.points.length; j++) {
        c.lineTo(this.sx(stamp.anchor.x + item.points[j].x), this.sy(stamp.anchor.y + item.points[j].y));
      }
      if (item.closed && item.points.length >= 3) {
        c.closePath();
        c.fill();
      }
      c.stroke();
    }

    c.setLineDash([]);
    c.strokeStyle = pal.teal;
    c.lineWidth = 1.6;
    for (let i = 0; i < stamp.ports.length; i++) {
      const px: number = this.sx(stamp.anchor.x + stamp.ports[i].x);
      const py: number = this.sy(stamp.anchor.y + stamp.ports[i].y);
      c.beginPath();
      c.arc(px, py, 4.5, 0, Math.PI * 2);
      c.stroke();
    }

    c.strokeStyle = pal.primary;
    c.lineWidth = 1.8;
    c.beginPath();
    c.moveTo(ax - 7, ay);
    c.lineTo(ax + 7, ay);
    c.moveTo(ax, ay - 7);
    c.lineTo(ax, ay + 7);
    c.stroke();
    c.restore();
  }

  private drawPolyPreview(c: CanvasRenderingContext2D, poly: DraftPolyPreview, light: boolean): void {
    const chain: Point[] = poly.committed.concat(poly.liveTail);
    if (chain.length === 0) {
      return;
    }
    const pal: SemanticThemePalette = this.palette();
    const spineColor: string = pal.warning;

    c.save();
    if (poly.isPath) {
      if (poly.pathWidthNm > 0 && chain.length >= 2) {
        const env: Point[] = routingConstraintService.buildPathEnvelopePolygon(chain, poly.pathWidthNm, poly.pathType);
        if (env.length >= 3) {
          c.setLineDash([]);
          c.beginPath();
          c.moveTo(this.sx(env[0].x), this.sy(env[0].y));
          for (let i = 1; i < env.length; i++) {
            c.lineTo(this.sx(env[i].x), this.sy(env[i].y));
          }
          c.closePath();
          c.fillStyle = withAlpha(poly.layerColor, light ? 0.18 : 0.26);
          c.fill();
          c.strokeStyle = withAlpha(poly.layerColor, 0.88);
          c.lineWidth = 1.4;
          c.stroke();
        }
      }
      if (poly.committed.length >= 2) {
        c.setLineDash([]);
        c.strokeStyle = spineColor;
        c.lineWidth = 1.65;
        c.beginPath();
        c.moveTo(this.sx(poly.committed[0].x), this.sy(poly.committed[0].y));
        for (let i = 1; i < poly.committed.length; i++) {
          c.lineTo(this.sx(poly.committed[i].x), this.sy(poly.committed[i].y));
        }
        c.stroke();
      }
      if (poly.committed.length >= 1 && poly.liveTail.length > 0) {
        const anchor: Point = poly.committed[poly.committed.length - 1];
        c.setLineDash([5, 4]);
        c.strokeStyle = spineColor;
        c.lineWidth = 1.65;
        c.beginPath();
        c.moveTo(this.sx(anchor.x), this.sy(anchor.y));
        for (let i = 0; i < poly.liveTail.length; i++) {
          c.lineTo(this.sx(poly.liveTail[i].x), this.sy(poly.liveTail[i].y));
        }
        c.stroke();
      }
    } else {
      if (chain.length >= 3) {
        c.setLineDash([]);
        c.beginPath();
        c.moveTo(this.sx(chain[0].x), this.sy(chain[0].y));
        for (let i = 1; i < chain.length; i++) {
          c.lineTo(this.sx(chain[i].x), this.sy(chain[i].y));
        }
        c.closePath();
        c.fillStyle = withAlpha(poly.layerColor, light ? 0.14 : 0.22);
        c.fill();
      }
      if (poly.committed.length >= 2) {
        c.setLineDash([]);
        c.strokeStyle = poly.layerColor;
        c.lineWidth = 1.8;
        c.beginPath();
        c.moveTo(this.sx(poly.committed[0].x), this.sy(poly.committed[0].y));
        for (let i = 1; i < poly.committed.length; i++) {
          c.lineTo(this.sx(poly.committed[i].x), this.sy(poly.committed[i].y));
        }
        c.stroke();
      }
      if (poly.committed.length >= 1 && poly.liveTail.length > 0) {
        const anchor: Point = poly.committed[poly.committed.length - 1];
        const tip: Point = poly.liveTail[poly.liveTail.length - 1];
        c.setLineDash([6, 4]);
        c.strokeStyle = spineColor;
        c.lineWidth = 1.65;
        c.beginPath();
        c.moveTo(this.sx(anchor.x), this.sy(anchor.y));
        for (let i = 0; i < poly.liveTail.length; i++) {
          c.lineTo(this.sx(poly.liveTail[i].x), this.sy(poly.liveTail[i].y));
        }
        c.stroke();

        if (poly.committed.length >= 2) {
          c.setLineDash([2, 4]);
          c.strokeStyle = poly.closeLoopReady ? pal.success : withAlpha(poly.layerColor, 0.65);
          c.lineWidth = poly.closeLoopReady ? 1.85 : 1.35;
          c.beginPath();
          c.moveTo(this.sx(tip.x), this.sy(tip.y));
          c.lineTo(this.sx(poly.committed[0].x), this.sy(poly.committed[0].y));
          c.stroke();
        }
      }

      if (poly.committed.length >= 3) {
        const fx: number = this.sx(poly.committed[0].x);
        const fy: number = this.sy(poly.committed[0].y);
        c.setLineDash([]);
        c.strokeStyle = poly.closeLoopReady ? pal.success : withAlpha(spineColor, 0.78);
        c.lineWidth = poly.closeLoopReady ? 2.2 : 1.4;
        c.beginPath();
        c.arc(fx, fy, poly.closeLoopReady ? 10 : 7, 0, Math.PI * 2);
        c.stroke();
      }
    }

    c.setLineDash([]);
    for (let i = 0; i < poly.committed.length; i++) {
      const vx: number = this.sx(poly.committed[i].x);
      const vy: number = this.sy(poly.committed[i].y);
      c.fillStyle = i === 0 ? pal.success : spineColor;
      c.fillRect(vx - 3.5, vy - 3.5, 7, 7);
      c.strokeStyle = pal.surface;
      c.lineWidth = 1.2;
      c.strokeRect(vx - 3.5, vy - 3.5, 7, 7);
    }
    c.restore();
  }

  private drawMovePreview(c: CanvasRenderingContext2D, move: DraftMovePreview, light: boolean): void {
    const pal: SemanticThemePalette = this.palette();
    c.save();
    c.setLineDash([5, 3]);
    c.lineWidth = 1.65;

    for (let i = 0; i < move.outlines.length; i++) {
      const item: DraftGhostOutline = move.outlines[i];
      if (item.points.length < 2) continue;
      c.strokeStyle = item.color;
      c.fillStyle = withAlpha(item.color, light ? 0.12 : 0.18);
      c.beginPath();
      c.moveTo(this.sx(item.points[0].x + move.dxNm), this.sy(item.points[0].y + move.dyNm));
      for (let j = 1; j < item.points.length; j++) {
        c.lineTo(this.sx(item.points[j].x + move.dxNm), this.sy(item.points[j].y + move.dyNm));
      }
      if (item.closed && item.points.length >= 3) {
        c.closePath();
        c.fill();
      }
      c.stroke();
    }

    const x0: number = this.sx(move.fromX);
    const y0: number = this.sy(move.fromY);
    const x1: number = this.sx(move.fromX + move.dxNm);
    const y1: number = this.sy(move.fromY + move.dyNm);
    if (Math.hypot(x1 - x0, y1 - y0) > 4) {
      c.setLineDash([3, 3]);
      c.strokeStyle = pal.primary;
      c.lineWidth = 1.45;
      c.beginPath();
      c.moveTo(x0, y0);
      c.lineTo(x1, y1);
      c.stroke();

      c.setLineDash([]);
      c.fillStyle = pal.primary;
      c.beginPath();
      c.arc(x0, y0, 3.2, 0, Math.PI * 2);
      c.fill();
    }
    c.restore();
  }

  private drawBoxPreview(c: CanvasRenderingContext2D, box: DraftBoxPreview): void {
    if (box.w <= 0.5 && box.h <= 0.5) {
      return;
    }
    const pal: SemanticThemePalette = this.palette();
    const crossing: boolean = !box.isBoxZoom && !box.leftToRight;
    const strokeCol: string = crossing ? pal.success : pal.primary;
    c.save();
    c.fillStyle = withAlpha(strokeCol, 0.14);
    c.fillRect(box.x, box.y, box.w, box.h);
    c.strokeStyle = strokeCol;
    c.lineWidth = 1.6;
    c.setLineDash(crossing ? [6, 4] : []);
    c.strokeRect(box.x, box.y, box.w, box.h);
    c.restore();
  }

  private drawSnapMarkerAt(c: CanvasRenderingContext2D, x: number, y: number, marker: SnapMarker): void {
    const pal: SemanticThemePalette = this.palette();
    c.save();
    c.setLineDash([]);

    if (marker.symbol === 'grid') {
      c.strokeStyle = withAlpha(pal.primary, 0.58);
      c.lineWidth = 1.35;
      c.beginPath();
      c.moveTo(x - 5, y);
      c.lineTo(x + 5, y);
      c.moveTo(x, y - 5);
      c.lineTo(x, y + 5);
      c.stroke();
      c.restore();
      return;
    }

    if (marker.symbol === 'closeLoop') {
      c.strokeStyle = pal.success;
      c.lineWidth = 2.0;
      c.beginPath();
      c.arc(x, y, 10.5, 0, Math.PI * 2);
      c.stroke();
      c.beginPath();
      c.arc(x, y, 4.5, 0, Math.PI * 2);
      c.stroke();
      c.restore();
      return;
    }

    if (marker.symbol === 'vertex') {
      c.strokeStyle = pal.warning;
      c.lineWidth = 1.9;
      c.strokeRect(x - 5.5, y - 5.5, 11, 11);
      c.beginPath();
      c.moveTo(x - 9, y);
      c.lineTo(x - 6, y);
      c.moveTo(x + 6, y);
      c.lineTo(x + 9, y);
      c.moveTo(x, y - 9);
      c.lineTo(x, y - 6);
      c.moveTo(x, y + 6);
      c.lineTo(x, y + 9);
      c.stroke();
    } else if (marker.symbol === 'midpoint') {
      c.strokeStyle = pal.accent;
      c.lineWidth = 1.9;
      c.beginPath();
      c.moveTo(x, y - 7);
      c.lineTo(x + 6.5, y + 5);
      c.lineTo(x - 6.5, y + 5);
      c.closePath();
      c.stroke();
    } else if (marker.symbol === 'intersection') {
      c.strokeStyle = pal.danger;
      c.lineWidth = 1.9;
      c.beginPath();
      c.arc(x, y, 7.5, 0, Math.PI * 2);
      c.stroke();
      c.beginPath();
      c.moveTo(x - 5, y - 5);
      c.lineTo(x + 5, y + 5);
      c.moveTo(x + 5, y - 5);
      c.lineTo(x - 5, y + 5);
      c.stroke();
    } else if (marker.symbol === 'center') {
      c.strokeStyle = pal.primaryDeep;
      c.lineWidth = 1.9;
      c.beginPath();
      c.moveTo(x, y - 7);
      c.lineTo(x + 7, y);
      c.lineTo(x, y + 7);
      c.lineTo(x - 7, y);
      c.closePath();
      c.stroke();
    } else if (marker.symbol === 'edge') {
      c.strokeStyle = pal.warning;
      c.lineWidth = 1.9;
      c.beginPath();
      c.arc(x, y, 6.5, 0, Math.PI * 2);
      c.stroke();
      c.fillStyle = pal.warning;
      c.beginPath();
      c.arc(x, y, 2.0, 0, Math.PI * 2);
      c.fill();
    } else {
      c.strokeStyle = pal.teal;
      c.lineWidth = 1.75;
      c.beginPath();
      c.arc(x, y, 5.5, 0, Math.PI * 2);
      c.stroke();
      c.beginPath();
      c.moveTo(x - 8.5, y);
      c.lineTo(x + 8.5, y);
      c.moveTo(x, y - 8.5);
      c.lineTo(x, y + 8.5);
      c.stroke();
    }
    c.restore();
  }

  private drawCursorHud(
    c: CanvasRenderingContext2D,
    hud: DraftCursorHud,
    canvasW: number,
    canvasH: number,
    loupeVisible: boolean
  ): void {
    if (hud.primaryText.length === 0) {
      return;
    }
    const pal: SemanticThemePalette = this.palette();
    c.save();
    c.font = 'normal 500 11vp HarmonyOS Sans';
    const w1: number = c.measureText(hud.primaryText).width;
    const hasLine2: boolean = hud.secondaryText.length > 0;
    const w2: number = hasLine2 ? c.measureText(hud.secondaryText).width : 0;
    const boxW: number = Math.max(96, Math.ceil(Math.max(w1, w2)) + 18);
    const boxH: number = hasLine2 ? 38 : 24;

    let bx: number = hud.screenX + 16;
    let by: number = loupeVisible ? hud.screenY + 24 : hud.screenY + 16;
    if (bx + boxW > canvasW - 10) {
      bx = Math.max(10, hud.screenX - boxW - 14);
    }
    if (by + boxH > canvasH - 14) {
      by = Math.max(10, hud.screenY - boxH - (loupeVisible ? 150 : 16));
    }

    const floatingBorder: string = typeof hongTuThemeState.luminous.floatingBorderColor === 'string'
      ? hongTuThemeState.luminous.floatingBorderColor
      : pal.border;
    this.fillRoundedRect(
      c,
      bx,
      by,
      boxW,
      boxH,
      8,
      withAlpha(pal.surface, 0.92),
      floatingBorder
    );

    c.fillStyle = pal.text;
    c.textBaseline = 'middle';
    c.fillText(hud.primaryText, bx + 9, by + (hasLine2 ? 12 : boxH * 0.5));
    if (hasLine2) {
      c.fillStyle = pal.primary;
      c.fillText(hud.secondaryText, bx + 9, by + 27);
    }
    c.restore();
  }

  private drawTouchLoupe(
    c: CanvasRenderingContext2D,
    loupe: DraftTouchLoupe,
    canvasW: number,
    canvasH: number,
    light: boolean
  ): number {
    const pal: SemanticThemePalette = this.palette();
    const R: number = 50;
    const cx: number = Math.max(R + 14, Math.min(canvasW - R - 14, loupe.fingerScreenX));
    const cy: number = loupe.fingerScreenY > R * 2 + 64
      ? loupe.fingerScreenY - 88
      : Math.min(canvasH - R - 20, loupe.fingerScreenY + 88);

    const magZoom: number = Math.max(0.05, this.zoomPercent * 2.5) / 100;
    const lx = (wx: number): number => cx + (wx - loupe.snappedWorldX) * magZoom;
    const ly = (wy: number): number => cy - (wy - loupe.snappedWorldY) * magZoom;

    c.save();
    c.beginPath();
    c.arc(cx, cy, R, 0, Math.PI * 2);
    c.clip();

    c.fillStyle = pal.canvasBg;
    c.fillRect(cx - R, cy - R, R * 2, R * 2);

    if (loupe.gridStepNm > 0) {
      let step: number = loupe.gridStepNm;
      while (step * magZoom < 14) step *= 2;
      while (step * magZoom > 48) step *= 0.5;
      const worldHalf: number = R / magZoom;
      const gx0: number = Math.floor((loupe.snappedWorldX - worldHalf) / step) * step;
      const gx1: number = Math.ceil((loupe.snappedWorldX + worldHalf) / step) * step;
      const gy0: number = Math.floor((loupe.snappedWorldY - worldHalf) / step) * step;
      const gy1: number = Math.ceil((loupe.snappedWorldY + worldHalf) / step) * step;
      c.strokeStyle = pal.canvasGridMajor;
      c.lineWidth = 1.0;
      c.setLineDash([]);
      c.beginPath();
      for (let gx = gx0; gx <= gx1; gx += step) {
        const px: number = lx(gx);
        c.moveTo(px, cy - R);
        c.lineTo(px, cy + R);
      }
      for (let gy = gy0; gy <= gy1; gy += step) {
        const py: number = ly(gy);
        c.moveTo(cx - R, py);
        c.lineTo(cx + R, py);
      }
      c.stroke();
    }

    for (let i = 0; i < loupe.localShapes.length; i++) {
      const s: DraftLoupeShape = loupe.localShapes[i];
      if (s.points.length < 2) continue;
      c.setLineDash([]);
      c.strokeStyle = s.color;
      c.fillStyle = withAlpha(s.color, light ? 0.20 : 0.28);
      c.lineWidth = 1.35;
      c.beginPath();
      c.moveTo(lx(s.points[0].x), ly(s.points[0].y));
      for (let j = 1; j < s.points.length; j++) {
        c.lineTo(lx(s.points[j].x), ly(s.points[j].y));
      }
      if (s.closed && s.points.length >= 3) {
        c.closePath();
        c.fill();
      }
      c.stroke();
    }

    if (draftCanvasEngine.rectPreview !== null) {
      const r: DraftRectPreview = draftCanvasEngine.rectPreview;
      const rx: number = lx(r.x);
      const ry: number = ly(r.y + r.h);
      const rw: number = r.w * magZoom;
      const rh: number = r.h * magZoom;
      c.fillStyle = withAlpha(r.layerColor, 0.24);
      c.fillRect(rx, ry, rw, rh);
      c.strokeStyle = r.layerColor;
      c.lineWidth = 1.6;
      c.strokeRect(rx, ry, rw, rh);
    }
    if (draftCanvasEngine.curvePreview !== null && draftCanvasEngine.curvePreview.points.length >= 3) {
      const cp: DraftCurvePreview = draftCanvasEngine.curvePreview;
      c.setLineDash([]);
      c.fillStyle = withAlpha(cp.layerColor, 0.22);
      c.strokeStyle = cp.layerColor;
      c.lineWidth = 1.5;
      c.beginPath();
      c.moveTo(lx(cp.points[0].x), ly(cp.points[0].y));
      for (let i = 1; i < cp.points.length; i++) {
        c.lineTo(lx(cp.points[i].x), ly(cp.points[i].y));
      }
      c.closePath();
      c.fill();
      c.stroke();
    }
    if (draftCanvasEngine.polyPreview !== null) {
      const p: DraftPolyPreview = draftCanvasEngine.polyPreview;
      const chain: Point[] = p.committed.concat(p.liveTail);
      if (chain.length >= 2) {
        c.strokeStyle = pal.warning;
        c.lineWidth = 1.6;
        c.setLineDash([4, 3]);
        c.beginPath();
        c.moveTo(lx(chain[0].x), ly(chain[0].y));
        for (let i = 1; i < chain.length; i++) {
          c.lineTo(lx(chain[i].x), ly(chain[i].y));
        }
        c.stroke();
      }
    }

    if (draftCanvasEngine.stampPreview !== null) {
      const sp: DraftStampPreview = draftCanvasEngine.stampPreview;
      for (let i = 0; i < sp.outlines.length; i++) {
        const g: DraftGhostOutline = sp.outlines[i];
        if (g.points.length < 2) continue;
        c.setLineDash([4, 3]);
        c.strokeStyle = g.color;
        c.lineWidth = 1.4;
        c.beginPath();
        c.moveTo(lx(sp.anchor.x + g.points[0].x), ly(sp.anchor.y + g.points[0].y));
        for (let j = 1; j < g.points.length; j++) {
          c.lineTo(lx(sp.anchor.x + g.points[j].x), ly(sp.anchor.y + g.points[j].y));
        }
        if (g.closed && g.points.length >= 3) c.closePath();
        c.stroke();
      }
    }

    c.setLineDash([]);
    c.strokeStyle = withAlpha(pal.primary, 0.86);
    c.lineWidth = 1.35;
    c.beginPath();
    c.moveTo(cx - 16, cy);
    c.lineTo(cx - 4, cy);
    c.moveTo(cx + 4, cy);
    c.lineTo(cx + 16, cy);
    c.moveTo(cx, cy - 16);
    c.lineTo(cx, cy - 4);
    c.moveTo(cx, cy + 4);
    c.lineTo(cx, cy + 16);
    c.stroke();

    if (draftCanvasEngine.snapMarker !== null && draftCanvasEngine.snapMarker.symbol !== 'grid') {
      this.drawSnapMarkerAt(c, cx, cy, draftCanvasEngine.snapMarker);
    }
    c.restore();

    c.save();
    c.setLineDash([]);
    c.strokeStyle = pal.primary;
    c.lineWidth = 2.2;
    c.beginPath();
    c.arc(cx, cy, R, 0, Math.PI * 2);
    c.stroke();

    const loupeBorder: string = typeof hongTuThemeState.luminous.floatingBorderColor === 'string'
      ? hongTuThemeState.luminous.floatingBorderColor
      : pal.border;
    c.strokeStyle = loupeBorder;
    c.lineWidth = 1.1;
    c.beginPath();
    c.arc(cx, cy, R - 2, 0, Math.PI * 2);
    c.stroke();

    if (loupe.badgeText.length > 0) {
      c.font = 'normal 500 10vp HarmonyOS Sans';
      const tw: number = Math.min(R * 2 - 4, Math.ceil(c.measureText(loupe.badgeText).width) + 12);
      const pillX: number = cx - tw * 0.5;
      const pillY: number = cy + R - 10;
      this.fillRoundedRect(
        c,
        pillX,
        pillY,
        tw,
        18,
        9,
        withAlpha(pal.primary, 0.92),
        loupeBorder
      );
      c.fillStyle = pal.surface;
      c.textBaseline = 'middle';
      c.fillText(loupe.badgeText, pillX + 6, pillY + 9);
    }
    c.restore();
    return cy;
  }

  private fillRoundedRect(
    c: CanvasRenderingContext2D,
    x: number,
    y: number,
    w: number,
    h: number,
    r: number,
    fill: string,
    stroke: string
  ): void {
    const rad: number = Math.min(r, w * 0.5, h * 0.5);
    c.beginPath();
    c.moveTo(x + rad, y);
    c.lineTo(x + w - rad, y);
    c.arcTo(x + w, y, x + w, y + rad, rad);
    c.lineTo(x + w, y + h - rad);
    c.arcTo(x + w, y + h, x + w - rad, y + h, rad);
    c.lineTo(x + rad, y + h);
    c.arcTo(x, y + h, x, y + h - rad, rad);
    c.lineTo(x, y + rad);
    c.arcTo(x, y, x + rad, y, rad);
    c.closePath();
    c.fillStyle = fill;
    c.fill();
    c.strokeStyle = stroke;
    c.lineWidth = 1.0;
    c.setLineDash([]);
    c.stroke();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.ctx)
        .width(this.canvasWidth)
        .height(this.canvasHeight)
        .hitTestBehavior(HitTestMode.None)
        .onReady(() => {
          this.canvasReady = true;
          this.repaint();
        })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const aw: number = Number(newArea.width);
          const ah: number = Number(newArea.height);
          if (Number.isFinite(aw) && aw > 0) {
            this.measuredCanvasWidth = aw;
          }
          if (Number.isFinite(ah) && ah > 0) {
            this.measuredCanvasHeight = ah;
          }
          if (this.canvasReady) {
            this.repaint();
            this.scheduleAreaRepaint();
          }
        })

      DraftPolyControlStrip({
        store: this.controlStore,
        desktopMode: this.desktopMode,
        canvasWidth: this.canvasWidth,
        topStripY: this.topStripY,
        stepUnitNm: this.stepUnitNm,
        onFinishPoly: this.onFinishPoly,
        onCancelPoly: this.onCancelPoly,
        onUndoPolyVertex: this.onUndoPolyVertex,
        onSelectRoutingMode: this.onSelectRoutingMode,
        onFlipPosture: this.onFlipPosture,
        onPathWidthEdited: this.onPathWidthEdited,
        onPathTypeChanged: this.onPathTypeChanged,
      })

      DraftCurveControlStrip({
        store: this.controlStore,
        desktopMode: this.desktopMode,
        canvasWidth: this.canvasWidth,
        topStripY: this.topStripY,
        onSelectCurveKind: this.onSelectCurveKind,
        onOpenExactCurveDialog: this.onOpenExactCurveDialog,
        onExitCurveMode: this.onExitCurveMode,
      })

      DraftRectControlStrip({
        store: this.controlStore,
        desktopMode: this.desktopMode,
        canvasWidth: this.canvasWidth,
        topStripY: this.topStripY,
      })

      DraftStampControlStrip({
        store: this.controlStore,
        desktopMode: this.desktopMode,
        canvasWidth: this.canvasWidth,
        topStripY: this.topStripY,
        onOpenStampDialog: this.onOpenStampDialog,
        onStampTransformChanged: this.onStampTransformChanged,
        onExitStampMode: this.onExitStampMode,
      })
    }
    .width(this.canvasWidth)
    .height(this.canvasHeight)
    .zIndex(ZIndexTokens.canvasHud)
    .hitTestBehavior(HitTestMode.None)
  }
}

@Component
struct DraftPolyControlStrip {
  @ObjectLink store: DraftControlStore;
  @Prop desktopMode: boolean = false;
  @Prop canvasWidth: number = 800;
  @Prop topStripY: number = 52;
  @Prop stepUnitNm: number = 10;

  onFinishPoly: () => void = () => {};
  onCancelPoly: () => void = () => {};
  onUndoPolyVertex: () => void = () => {};
  onSelectRoutingMode: (mode: RoutingMode) => void = (_m: RoutingMode) => {};
  onFlipPosture: () => void = () => {};
  onPathWidthEdited: (widthStr: string) => void = (_w: string) => {};
  onPathTypeChanged: () => void = () => {};

  private buildRoutingSegmentItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '90°正交' },
      { text: '45°锁角' },
      { text: '自由角' }
    ];
    return items;
  }

  private bumpPathWidth(sign: number): void {
    const cur: number = Number(this.store.pathWidthStr);
    const delta: number = Math.max(1, Math.round(this.stepUnitNm > 0 ? this.stepUnitNm : 10));
    const base: number = Number.isFinite(cur) && cur > 0 ? cur : delta;
    const next: number = Math.max(1, Math.round(base + sign * delta));
    this.onPathWidthEdited(String(next));
  }

  build() {
    if (this.store.polyActive) {
      Scroll() {
        Row({ space: 8 }) {
          Text(this.store.continuingShapeId >= 0 ? '续画路径' : (this.store.isPath ? '路径' : '多边形'))
            .fontSize(12)
            .fontColor(this.store.continuingShapeId >= 0 ? COLORS.primary : COLORS.ink)
            .fontWeight(FontWeight.Medium)
          Text(`${this.store.pointCount} 点`)
            .fontSize(12)
            .fontFamily(FONT_MONO)
            .fontColor(COLORS.muted)

          Row() {
            StableSegmentButton({
              items: this.buildRoutingSegmentItems(),
              selectedIndex: this.store.routingModeIndex(),
              onItemClicked: (index: number) => {
                this.onSelectRoutingMode(DraftControlStore.routingModeForIndex(index));
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: 11,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 32,
              itemMinHeight: 26,
              itemPaddingHorizontal: 6,
              itemPaddingVertical: 3
            })
          }
          .width(188)

          if (this.store.routingMode === RoutingMode.MANHATTAN_90) {
            Row({ space: 6 }) {
              Chip({
                prefixSymbol: {
                  normal: new SymbolGlyphModifier($r('sys.symbol.stroke_path'))
                    .fontSize(14)
                    .fontColor([COLORS.primary]),
                  activated: new SymbolGlyphModifier($r('sys.symbol.stroke_path'))
                    .fontSize(14)
                    .fontColor([COLORS.primary])
                },
                label: {
                  text: this.store.horizontalFirst ? '拐向:横先' : '拐向:纵先',
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: true,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                accessibilityDescription: '翻转正交 L 型拐角方向，快捷键 Tab',
                onClicked: () => {
                  this.onFlipPosture();
                }
              })
            }
          }

          if (this.store.isPath) {
            Row({ space: 4 }) {
              Text('线宽')
                .fontSize(12)
                .fontColor(COLORS.muted)
              Button('-', { type: ButtonType.Normal })
                .width(26).height(28).padding(0).fontSize(13)
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
                .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .focusable(false)
                .onClick(() => { this.bumpPathWidth(-1); })
              TextInput({ text: this.store.pathWidthStr })
                .type(InputType.Normal)
                .width(52)
                .height(UI.fieldHeight)
                .fontSize(UI.fontBody)
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onChange((val: string) => { this.onPathWidthEdited(val); })
                .onTouch((event: TouchEvent) => { event.stopPropagation(); })
                .onMouse((event: MouseEvent) => { event.stopPropagation(); })
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              Button('+', { type: ButtonType.Normal })
                .width(26).height(28).padding(0).fontSize(13)
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
                .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .focusable(false)
                .onClick(() => { this.bumpPathWidth(1); })
              Text('nm')
                .fontSize(11)
                .fontColor(COLORS.muted)
            }
            .alignItems(VerticalAlign.Center)

            Row({ space: 6 }) {
              Chip({
                label: {
                  text: this.store.pathTypeLabel(),
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: this.store.pathType !== 0,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                accessibilityDescription: '切换路径两端帽型：平头、圆头或半宽方延',
                onClicked: () => {
                  this.store.cyclePathType();
                  this.onPathTypeChanged();
                }
              })
            }
          }

          Button('退一点', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(UI.fontBody)
            .backgroundColor(COLORS.surfaceMuted)
            .fontColor(COLORS.ink)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onUndoPolyVertex(); })

          Button('完成', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(UI.fontBody)
            .backgroundColor(this.store.canFinish ? COLORS.primary : COLORS.surfaceMuted)
            .fontColor(this.store.canFinish ? Color.White : COLORS.muted)
            .border({ width: 1, color: this.store.canFinish ? COLORS.primary : COLORS.border })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .enabled(this.store.canFinish)
            .focusable(false)
            .onClick(() => { this.onFinishPoly(); })

          Button('取消', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(UI.fontBody)
            .backgroundColor(COLORS.surfaceMuted)
            .fontColor(COLORS.ink)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onCancelPoly(); })
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - (this.desktopMode ? 86 : 28)) })
      .height(44)
      .padding({ left: 12, right: 12 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
      .transition(panelTransition(TransitionEdge.TOP))
      .zIndex(ZIndexTokens.floatingToolbar)
      .position({ x: this.desktopMode ? 72 : 14, y: this.topStripY })
      .hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { event.stopPropagation(); })
      .onMouse((event: MouseEvent) => { event.stopPropagation(); })
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
  }
}

/**
 * 矩形工具增强浮条：支持「对角框 / 中心扩 / 定尺寸」三模切换、触屏「锁正方」与固定宽×高一键点放
 */
@Component
struct DraftRectControlStrip {
  @ObjectLink store: DraftControlStore;
  @Prop desktopMode: boolean = false;
  @Prop canvasWidth: number = 800;
  @Prop topStripY: number = 52;

  private buildRectModeItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '对角框' },
      { text: '中心扩' },
      { text: '定尺寸' }
    ];
    return items;
  }

  build() {
    if (this.store.rectActive && !this.store.polyActive && this.store.curveKind.length === 0 && !this.store.stampActive) {
      Scroll() {
        Row({ space: 8 }) {
          Text('矩形')
            .fontSize(12)
            .fontColor(COLORS.ink)
            .fontWeight(FontWeight.Medium)

          Row() {
            StableSegmentButton({
              items: this.buildRectModeItems(),
              selectedIndex: this.store.rectDrawMode,
              onItemClicked: (index: number) => {
                if (index >= 0 && index <= 2) {
                  this.store.rectDrawMode = index;
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: 11,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 32,
              itemMinHeight: 26,
              itemPaddingHorizontal: 6,
              itemPaddingVertical: 3
            })
          }
          .width(184)

          if (this.store.rectDrawMode !== 2) {
            Row({ space: 6 }) {
              Chip({
                label: {
                  text: '锁正方',
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: this.store.rectSquareLock,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
                accessibilityDescription: '锁定等宽高正方形绘制',
                onClicked: () => {
                  this.store.rectSquareLock = !this.store.rectSquareLock;
                }
              })
            }
          } else {
            Row({ space: 4 }) {
              Text('宽')
                .fontSize(11)
                .fontColor(COLORS.muted)
              TextInput({ text: this.store.rectFixedWNmStr })
                .type(InputType.Normal)
                .width(56)
                .height(UI.fieldHeight)
                .fontSize(UI.fontBody)
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onChange((v: string) => { this.store.rectFixedWNmStr = v; })
                .onTouch((event: TouchEvent) => { event.stopPropagation(); })
                .onMouse((event: MouseEvent) => { event.stopPropagation(); })
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              Text('× 高')
                .fontSize(11)
                .fontColor(COLORS.muted)
              TextInput({ text: this.store.rectFixedHNmStr })
                .type(InputType.Normal)
                .width(56)
                .height(UI.fieldHeight)
                .fontSize(UI.fontBody)
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onChange((v: string) => { this.store.rectFixedHNmStr = v; })
                .onTouch((event: TouchEvent) => { event.stopPropagation(); })
                .onMouse((event: MouseEvent) => { event.stopPropagation(); })
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              Text('nm')
                .fontSize(11)
                .fontColor(COLORS.muted)
              Button('互换', { type: ButtonType.Normal })
                .height(UI.compactControlHeight)
                .fontSize(11)
                .padding({ left: 8, right: 8 })
                .backgroundColor(COLORS.surfaceMuted)
                .fontColor(COLORS.primary)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .focusable(false)
                .onClick(() => { this.store.swapRectFixedDimensions(); })
            }
            .alignItems(VerticalAlign.Center)
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - (this.desktopMode ? 86 : 28)) })
      .height(44)
      .padding({ left: 12, right: 12 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
      .transition(panelTransition(TransitionEdge.TOP))
      .zIndex(ZIndexTokens.floatingToolbar)
      .position({ x: this.desktopMode ? 72 : 14, y: this.topStripY })
      .hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { event.stopPropagation(); })
      .onMouse((event: MouseEvent) => { event.stopPropagation(); })
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
  }
}

/**
 * 实例与 PCell 画布 120fps 幽灵磁吸盖章控制浮条
 */
@Component
struct DraftStampControlStrip {
  @ObjectLink store: DraftControlStore;
  @Prop desktopMode: boolean = false;
  @Prop canvasWidth: number = 800;
  @Prop topStripY: number = 52;

  onOpenStampDialog: () => void = () => {};
  onStampTransformChanged: () => void = () => {};
  onExitStampMode: () => void = () => {};

  build() {
    if (this.store.stampActive && !this.store.polyActive) {
      Scroll() {
        Row({ space: 8 }) {
          Button(`点放: ${this.store.stampLabel}`, { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.primarySoft)
            .border({ width: 1, color: COLORS.primary })
            .borderRadius(UI.controlRadius)
            .padding({ left: 10, right: 10 })
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onOpenStampDialog(); })

          Row({ space: 6 }) {
            if (!this.store.stampIsPCell) {
              Chip({
                prefixSymbol: {
                  normal: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
                    .fontSize(14)
                    .fontColor([COLORS.primary]),
                  activated: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
                    .fontSize(14)
                    .fontColor([COLORS.primary])
                },
                label: {
                  text: `旋转 ${this.store.stampRotation}°`,
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: this.store.stampRotation !== 0,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                accessibilityDescription: '切换实例放置旋转角 0、90、180、270 度',
                onClicked: () => {
                  this.store.cycleStampRotation();
                  this.onStampTransformChanged();
                }
              })

              Chip({
                label: {
                  text: this.store.stampMirrorLabel(),
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: this.store.stampMirror !== 0,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                accessibilityDescription: '切换实例放置镜像：无、X 轴或 Y 轴',
                onClicked: () => {
                  this.store.cycleStampMirror();
                  this.onStampTransformChanged();
                }
              })
            }

            Chip({
              label: {
                text: '连续点放',
                fontSize: 12,
                fontColor: COLORS.ink,
                activatedFontColor: COLORS.primary
              },
              size: ChipSize.SMALL,
              allowClose: false,
              activated: this.store.stampContinuous,
              backgroundColor: COLORS.surfaceMuted,
              activatedBackgroundColor: COLORS.primarySoft,
              borderRadius: UI.controlRadius,
              maxFontScale: 1.3,
              accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
              accessibilityDescription: '开启后可连续点击放置多个实例，关闭则放完一个回到选择工具',
              onClicked: () => {
                this.store.stampContinuous = !this.store.stampContinuous;
              }
            })
          }

          Button('换器件/坐标…', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .padding({ left: 8, right: 8 })
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onOpenStampDialog(); })

          Button('退出', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .padding({ left: 8, right: 8 })
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onExitStampMode(); })
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - (this.desktopMode ? 86 : 28)) })
      .height(44)
      .padding({ left: 12, right: 12 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
      .transition(panelTransition(TransitionEdge.TOP))
      .zIndex(ZIndexTokens.floatingToolbar)
      .position({ x: this.desktopMode ? 72 : 14, y: this.topStripY })
      .hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { event.stopPropagation(); })
      .onMouse((event: MouseEvent) => { event.stopPropagation(); })
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
  }
}

/**
 * 画布直接拖拽曲线悬浮控制条（支持圆环/圆弧固定波导线宽 nm、45°/90°/180°/270° 跨度与顺逆时针翻转）
 */
@Component
struct DraftCurveControlStrip {
  @ObjectLink store: DraftControlStore;
  @Prop desktopMode: boolean = false;
  @Prop canvasWidth: number = 800;
  @Prop topStripY: number = 52;

  onSelectCurveKind: (kind: string) => void = (_k: string) => {};
  onOpenExactCurveDialog: (kind: string) => void = (_k: string) => {};
  onExitCurveMode: () => void = () => {};

  private buildCurveSegmentItems(): SegmentButtonItemTuple {
    const items: [
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem
    ] = [
      { text: '圆形' },
      { text: '圆环' },
      { text: '椭圆' },
      { text: '圆弧' }
    ];
    return items;
  }

  build() {
    if (this.store.curveKind.length > 0 && !this.store.polyActive && !this.store.stampActive) {
      Scroll() {
        Row({ space: 8 }) {
          Row() {
            StableSegmentButton({
              items: this.buildCurveSegmentItems(),
              selectedIndex: this.store.curveKindIndex(),
              onItemClicked: (index: number) => {
                const nextKind: string = DraftControlStore.curveKindForIndex(index);
                if (nextKind !== this.store.curveKind) {
                  this.onSelectCurveKind(nextKind);
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: 11,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 32,
              itemMinHeight: 26,
              itemPaddingHorizontal: 6,
              itemPaddingVertical: 3
            })
          }
          .width(208)

          if (this.store.curveKind === 'DONUT' || this.store.curveKind === 'ARC') {
            Row({ space: 6 }) {
              Chip({
                label: {
                  text: this.store.curveUseFixedWidth ? '定环宽' : `内径 ${this.store.curveInnerRatioPct}%`,
                  fontSize: 12,
                  fontColor: COLORS.ink,
                  activatedFontColor: COLORS.primary
                },
                size: ChipSize.SMALL,
                allowClose: false,
                activated: true,
                backgroundColor: COLORS.surfaceMuted,
                activatedBackgroundColor: COLORS.primarySoft,
                borderRadius: UI.controlRadius,
                maxFontScale: 1.3,
                accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                accessibilityDescription: '点击切换圆环或波导圆弧的内径比或固定环宽模式',
                onClicked: () => {
                  if (!this.store.curveUseFixedWidth && this.store.curveInnerRatioPct === 75) {
                    this.store.curveUseFixedWidth = true;
                  } else if (this.store.curveUseFixedWidth) {
                    this.store.curveUseFixedWidth = false;
                    this.store.curveInnerRatioPct = 40;
                  } else {
                    this.store.cycleInnerRatio();
                  }
                }
              })

              if (this.store.curveUseFixedWidth) {
                Row({ space: 4 }) {
                  TextInput({ text: this.store.curveRingWidthNmStr })
                    .type(InputType.Normal)
                    .width(52)
                    .height(UI.fieldHeight)
                    .fontSize(UI.fontBody)
                    .fontColor(COLORS.ink)
                    .backgroundColor(COLORS.surfaceMuted)
                    .border({ width: 1, color: COLORS.border })
                    .borderRadius(UI.controlRadius)
                    .onChange((v: string) => { this.store.curveRingWidthNmStr = v; })
                    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
                    .onMouse((event: MouseEvent) => { event.stopPropagation(); })
                    .onFocus(() => { resetModifierKeys(); })
                    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                  Text('nm')
                    .fontSize(11)
                    .fontColor(COLORS.muted)
                }
                .alignItems(VerticalAlign.Center)
              }

              if (this.store.curveKind === 'ARC') {
                Chip({
                  prefixSymbol: {
                    normal: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
                      .fontSize(14)
                      .fontColor([COLORS.primary]),
                    activated: new SymbolGlyphModifier($r('sys.symbol.arrow_clockwise'))
                      .fontSize(14)
                      .fontColor([COLORS.primary])
                  },
                  label: {
                    text: `张角 ${this.store.curveArcSweepDeg}°`,
                    fontSize: 12,
                    fontColor: COLORS.ink,
                    activatedFontColor: COLORS.primary
                  },
                  size: ChipSize.SMALL,
                  allowClose: false,
                  activated: true,
                  backgroundColor: COLORS.surfaceMuted,
                  activatedBackgroundColor: COLORS.primarySoft,
                  borderRadius: UI.controlRadius,
                  maxFontScale: 1.3,
                  accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
                  accessibilityDescription: '切换圆弧张角跨度（45 / 90 / 180 / 270 度）',
                  onClicked: () => {
                    this.store.cycleArcSweep();
                  }
                })

                Chip({
                  label: {
                    text: this.store.curveArcClockwise ? '顺时针' : '逆时针',
                    fontSize: 12,
                    fontColor: COLORS.ink,
                    activatedFontColor: COLORS.primary
                  },
                  size: ChipSize.SMALL,
                  allowClose: false,
                  activated: this.store.curveArcClockwise,
                  backgroundColor: COLORS.surfaceMuted,
                  activatedBackgroundColor: COLORS.primarySoft,
                  borderRadius: UI.controlRadius,
                  maxFontScale: 1.3,
                  accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
                  accessibilityDescription: '翻转圆弧张开旋转方向',
                  onClicked: () => {
                    this.store.curveArcClockwise = !this.store.curveArcClockwise;
                  }
                })
              }
            }
          }

          Button('精确参数…', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(12)
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .padding({ left: 8, right: 8 })
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onOpenExactCurveDialog(this.store.curveKind); })

          Button('退出', { type: ButtonType.Normal })
            .height(UI.compactControlHeight)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .padding({ left: 8, right: 8 })
            .attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .focusable(false)
            .onClick(() => { this.onExitCurveMode(); })
        }
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - (this.desktopMode ? 86 : 28)) })
      .height(44)
      .padding({ left: 12, right: 12 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
      .transition(panelTransition(TransitionEdge.TOP))
      .zIndex(ZIndexTokens.floatingToolbar)
      .position({ x: this.desktopMode ? 72 : 14, y: this.topStripY })
      .hitTestBehavior(HitTestMode.Default)
      .onTouch((event: TouchEvent) => { event.stopPropagation(); })
      .onMouse((event: MouseEvent) => { event.stopPropagation(); })
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
  }
}
