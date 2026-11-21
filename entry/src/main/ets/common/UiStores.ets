/**
 * 鸿图 UI 状态存储（Phase 6 全工具链与双技能合规增强版）
 *
 * 升级亮点：
 * 1. MeasureStore 支持多条持久测量标注（MeasureAnnotation[]），测完一条自动留存画布，支持「撤一条」、整批清空与一键撤销恢复；
 * 2. 新增触屏友好的测量锁角（自由角 / 锁90° / 锁45°）与标尺定向（自动 / 水平 / 竖直）索引映射，直连受控原生 `StableSegmentButton`；
 * 3. 标尺拖拽期间实时更新 liveX/liveY 磁吸落点，松手按实时磁吸位置落线而非按下瞬间死坐标。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { umText } from './constants';
import { Point } from '../models/GdsiiData';

/** 光标位置存储：隔离高频移动更新，仅 StatusBar/CanvasHud 观察 */
@Observed
export class CursorStore {
  x: number = 0;
  y: number = 0;
  shapeId: number = -1;
  layerNumber: number = -1;
  datatype: number = 0;
  readout: string = '';

  update(x: number, y: number): void {
    this.x = x;
    this.y = y;
  }

  setHit(shapeId: number, layerNumber: number, datatype: number = 0): void {
    if (this.shapeId !== shapeId) {
      this.shapeId = shapeId;
    }
    if (this.layerNumber !== layerNumber) {
      this.layerNumber = layerNumber;
    }
    if (this.datatype !== datatype) this.datatype = datatype;
  }

  setReadout(text: string): void {
    if (this.readout !== text) {
      this.readout = text;
    }
  }
}

/** 标尺线（世界坐标 nm；vertical=true 为竖直标尺，吸附于 X） */
export interface RulerLine {
  id: number;
  vertical: boolean;
  pos: number;
}

/** 已锁定的两点测量尺寸标注（世界坐标 nm，切换工具保留） */
export interface MeasureAnnotation {
  id: number;
  x1: number;
  y1: number;
  x2: number;
  y2: number;
}

export type MeasureAngleLock = 'free' | 'ortho90' | 'diag45';
export type RulerOrientationMode = 'auto' | 'horizontal' | 'vertical';

/**
 * 测量 / 标尺状态存储（多标注持久留存 + 受控分段锁角 + 实时磁吸标尺）
 */
@Observed
export class MeasureStore {
  /** true = 标尺模式（放置持久参考线），false = 两点测量模式 */
  rulerMode: boolean = false;
  /** 已落下第一点，等待第二点 */
  pending: boolean = false;
  /** 起点（nm） */
  x1: number = 0;
  y1: number = 0;
  /** 终点（nm），hasEnd=false 时无意义 */
  x2: number = 0;
  y2: number = 0;
  /** 终点是否已提交 */
  hasEnd: boolean = false;
  /** 拖动中的实时端点（nm） */
  liveX: number = 0;
  liveY: number = 0;
  /** 触屏/桌面通用测量角度锁定 */
  angleLock: MeasureAngleLock = 'free';
  /** 标尺放置方向模式 */
  rulerOrientation: RulerOrientationMode = 'auto';
  /** 多条已锁定测量尺寸标注集合 */
  annotations: MeasureAnnotation[] = [];
  /** 持久标尺线集合 */
  rulers: RulerLine[] = [];
  private nextRulerId: number = 1;
  private nextAnnotationId: number = 1;

  /** 落起点开启新一次测量（保留历史 annotations 与持久标尺） */
  begin(x: number, y: number): void {
    this.x1 = x;
    this.y1 = y;
    this.liveX = x;
    this.liveY = y;
    this.hasEnd = false;
    this.pending = true;
  }

  /** 更新橡皮筋端点 */
  moveLive(x: number, y: number): void {
    this.liveX = x;
    this.liveY = y;
  }

  /** 落终点完成一次测量，并推入持久测量标注列表 */
  commit(x: number, y: number): void {
    this.x2 = x;
    this.y2 = y;
    this.liveX = x;
    this.liveY = y;
    this.hasEnd = true;
    this.pending = false;
    if (Math.hypot(x - this.x1, y - this.y1) > 1e-6) {
      const item: MeasureAnnotation = {
        id: this.nextAnnotationId++,
        x1: this.x1,
        y1: this.y1,
        x2: x,
        y2: y,
      };
      const next: MeasureAnnotation[] = this.annotations.slice();
      next.push(item);
      this.annotations = next;
    }
  }

  /** 仅清除当前未完成的活动线段（保留已锁定 annotations 与标尺） */
  reset(): void {
    this.pending = false;
    this.hasEnd = false;
    this.x1 = 0;
    this.y1 = 0;
    this.x2 = 0;
    this.y2 = 0;
    this.liveX = 0;
    this.liveY = 0;
  }

  undoLastAnnotation(): void {
    if (this.pending) {
      this.reset();
      return;
    }
    if (this.annotations.length > 0) {
      this.annotations = this.annotations.slice(0, -1);
      this.hasEnd = false;
    }
  }

  restoreAnnotations(items: MeasureAnnotation[]): void {
    this.annotations = items.map((ann: MeasureAnnotation): MeasureAnnotation => ({
      id: ann.id,
      x1: ann.x1,
      y1: ann.y1,
      x2: ann.x2,
      y2: ann.y2,
    }));
    this.nextAnnotationId = this.annotations.reduce(
      (next: number, ann: MeasureAnnotation): number => Math.max(next, ann.id + 1),
      1
    );
  }

  clearAnnotations(): void {
    this.reset();
    if (this.annotations.length > 0) {
      this.annotations = [];
    }
  }

  cycleAngleLock(): MeasureAngleLock {
    if (this.angleLock === 'free') {
      this.angleLock = 'ortho90';
    } else if (this.angleLock === 'ortho90') {
      this.angleLock = 'diag45';
    } else {
      this.angleLock = 'free';
    }
    return this.angleLock;
  }

  angleLockIndex(): number {
    if (this.angleLock === 'ortho90') return 1;
    if (this.angleLock === 'diag45') return 2;
    return 0;
  }

  setAngleLockByIndex(index: number): void {
    if (index === 1) {
      this.angleLock = 'ortho90';
    } else if (index === 2) {
      this.angleLock = 'diag45';
    } else {
      this.angleLock = 'free';
    }
  }

  angleLockLabel(): string {
    if (this.angleLock === 'ortho90') return '锁90°';
    if (this.angleLock === 'diag45') return '锁45°';
    return '自由角';
  }

  cycleRulerOrientation(): RulerOrientationMode {
    if (this.rulerOrientation === 'auto') {
      this.rulerOrientation = 'horizontal';
    } else if (this.rulerOrientation === 'horizontal') {
      this.rulerOrientation = 'vertical';
    } else {
      this.rulerOrientation = 'auto';
    }
    return this.rulerOrientation;
  }

  rulerOrientationIndex(): number {
    if (this.rulerOrientation === 'horizontal') return 1;
    if (this.rulerOrientation === 'vertical') return 2;
    return 0;
  }

  setRulerOrientationByIndex(index: number): void {
    if (index === 1) {
      this.rulerOrientation = 'horizontal';
    } else if (index === 2) {
      this.rulerOrientation = 'vertical';
    } else {
      this.rulerOrientation = 'auto';
    }
  }

  rulerOrientationLabel(): string {
    if (this.rulerOrientation === 'horizontal') return '水平线';
    if (this.rulerOrientation === 'vertical') return '竖直线';
    return '自动定向';
  }

  endX(): number {
    return this.hasEnd ? this.x2 : this.liveX;
  }

  endY(): number {
    return this.hasEnd ? this.y2 : this.liveY;
  }

  dxNm(): number {
    return this.endX() - this.x1;
  }

  dyNm(): number {
    return this.endY() - this.y1;
  }

  distanceNm(): number {
    const dx: number = this.dxNm();
    const dy: number = this.dyNm();
    return Math.sqrt(dx * dx + dy * dy);
  }

  /** 当前是否有正在拖拽瞄准的活动测量线 */
  hasSegment(): boolean {
    return this.pending;
  }

  // ===== 持久标尺 =====

  addRuler(vertical: boolean, pos: number): void {
    const line: RulerLine = { id: this.nextRulerId++, vertical: vertical, pos: pos };
    const next: RulerLine[] = this.rulers.slice();
    next.push(line);
    this.rulers = next;
  }

  undoLastRuler(): void {
    if (this.rulers.length > 0) {
      this.rulers = this.rulers.slice(0, -1);
    }
  }

  restoreRulers(lines: RulerLine[]): void {
    this.rulers = lines.map((line: RulerLine): RulerLine => ({ id: line.id, vertical: line.vertical, pos: line.pos }));
    this.nextRulerId = this.rulers.reduce((next: number, line: RulerLine): number => Math.max(next, line.id + 1), 1);
  }

  clearRulers(): void {
    if (this.rulers.length > 0) {
      this.rulers = [];
    }
  }

  rulerSpacingNm(vertical: boolean): number {
    const same: RulerLine[] = this.rulers.filter((r: RulerLine) => r.vertical === vertical);
    if (same.length < 2) {
      return 0;
    }
    return Math.abs(same[same.length - 1].pos - same[same.length - 2].pos);
  }

  rulerReadout(): string {
    if (this.rulers.length === 0) {
      return '';
    }
    const v: number = this.rulerSpacingNm(true);
    const h: number = this.rulerSpacingNm(false);
    if (v === 0 && h === 0) {
      return `标尺 ${this.rulers.length} 条（拖拽磁吸边角，松手落线）`;
    }
    const parts: string[] = [];
    if (v > 0) {
      parts.push(`竖直间距 ${umText(v)}µm`);
    }
    if (h > 0) {
      parts.push(`水平间距 ${umText(h)}µm`);
    }
    return `标尺 ${this.rulers.length} 条 · ${parts.join(' ')}`;
  }
}

/**
 * 顶点编辑状态存储（gap-matrix §6）
 */
@Observed
export class VertexStore {
  active: boolean = false;
  explicitlyPinned: boolean = false;
  deleteMode: boolean = false;
  orthoLock: boolean = false;
  isRect: boolean = false;
  shapeId: number = -1;
  closed: boolean = true;
  layerNumber: number = 0;
  points: Point[] = [];
  edgeHandles: Point[] = [];
  livePoints: Point[] = [];
  dragIndex: number = -1;
  /** 1=拖角点/顶点, 2=多边形/路径边中点插入顶点, 3=单击删顶点, 4=矩形四边单轴推拉 */
  gestureKind: number = 0;
  gestureRevision: number = -1;
  gestureCellId: number = -1;
  originVertexX: number = 0;
  originVertexY: number = 0;
  hint: string = '';

  bind(shapeId: number, closed: boolean, layerNumber: number,
       points: Point[], edgeHandles: Point[], isRect: boolean = false): void {
    if (this.dragIndex >= 0) {
      return;
    }
    if (this.shapeId === shapeId && this.closed === closed && this.isRect === isRect &&
      this.layerNumber === layerNumber &&
      this.samePoints(this.points, points) && this.samePoints(this.edgeHandles, edgeHandles)) {
      return;
    }
    this.shapeId = shapeId;
    this.closed = closed;
    this.isRect = isRect;
    this.layerNumber = layerNumber;
    this.points = points;
    this.edgeHandles = edgeHandles;
    this.livePoints = points;
  }

  isEditing(): boolean {
    return this.active && this.shapeId >= 0;
  }

  isDragging(): boolean {
    return this.dragIndex >= 0;
  }

  displayPoints(): Point[] {
    return this.dragIndex >= 0 ? this.livePoints : this.points;
  }

  beginDrag(index: number, live: Point[], kind: number, revision: number = -1, cellId: number = -1): void {
    this.dragIndex = index;
    this.gestureKind = kind;
    this.gestureRevision = revision;
    this.gestureCellId = cellId;
    this.livePoints = live;
  }

  moveDrag(live: Point[]): void {
    this.livePoints = live;
  }

  settle(committed: Point[]): void {
    this.dragIndex = -1;
    this.gestureKind = 0;
    this.gestureRevision = -1;
    this.gestureCellId = -1;
    this.points = committed;
    this.livePoints = committed;
  }

  revert(): void {
    this.dragIndex = -1;
    this.gestureKind = 0;
    this.gestureRevision = -1;
    this.gestureCellId = -1;
    this.livePoints = this.points;
  }

  setHint(text: string): void {
    if (this.hint !== text) {
      this.hint = text;
    }
  }

  reset(): void {
    this.active = false;
    this.explicitlyPinned = false;
    this.deleteMode = false;
    this.isRect = false;
    this.shapeId = -1;
    this.layerNumber = 0;
    this.points = [];
    this.edgeHandles = [];
    this.livePoints = [];
    this.dragIndex = -1;
    this.gestureKind = 0;
    this.gestureRevision = -1;
    this.gestureCellId = -1;
    this.hint = '';
  }

  private samePoints(a: Point[], b: Point[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].x !== b[i].x || a[i].y !== b[i].y) {
        return false;
      }
    }
    return true;
  }
}

@Observed
export class PanelStore {
  showAiPanel: boolean = false;
  showMacroPanel: boolean = false;
  showFilePanel: boolean = false;
  showShortcutPanel: boolean = false;
  showLayerStylePanel: boolean = false;

  aiLoading: boolean = false;
  aiStreamingText: string = '';
  aiError: string = '';

  macroRecording: boolean = false;
  macroStatusText: string = '';

  toggleAi(): void { this.showAiPanel = !this.showAiPanel; }
  toggleMacro(): void { this.showMacroPanel = !this.showMacroPanel; }
  toggleFile(): void { this.showFilePanel = !this.showFilePanel; }
  toggleShortcut(): void { this.showShortcutPanel = !this.showShortcutPanel; }
  toggleLayerStyle(): void { this.showLayerStylePanel = !this.showLayerStylePanel; }

  closeAll(): void {
    this.showAiPanel = false;
    this.showMacroPanel = false;
    this.showFilePanel = false;
    this.showShortcutPanel = false;
    this.showLayerStylePanel = false;
  }
}

@Observed
export class ToolbarStore {
  canUndo: boolean = false;
  canRedo: boolean = false;
  selectionCount: number = 0;
  hasSelection: boolean = false;
  currentToolName: string = '';

  updateFromEditService(canUndo: boolean, canRedo: boolean, selCount: number): void {
    this.canUndo = canUndo;
    this.canRedo = canRedo;
    this.selectionCount = selCount;
    this.hasSelection = selCount > 0;
  }
}

@Observed
export class LayerDisplayCache {
  displayLayers: UiLayerDisplay[] = [];
  visibleLayerNumbers: number[] = [];
  private shapesVersion: number = 0;
  private currentVersion: number = 0;

  invalidate(): void {
    this.currentVersion++;
  }

  needsRecompute(): boolean {
    return this.shapesVersion !== this.currentVersion;
  }

  update(layers: UiLayerDisplay[], visibleNumbers: number[]): void {
    this.displayLayers = layers;
    this.visibleLayerNumbers = visibleNumbers;
    this.shapesVersion = this.currentVersion;
  }
}

export interface UiLayerDisplay {
  layerNumber: number;
  datatype: number;
  name: string;
  nameEn: string;
  color: string;
  visible: boolean;
  shapeCount: number;
}
