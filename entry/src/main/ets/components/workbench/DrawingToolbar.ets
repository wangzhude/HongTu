import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { FONT_MONO } from '../../common/Fonts';
import { resetModifierKeys } from '../../common/ModifierKeys';
import { ActiveTool } from '../../workbench/WorkbenchModels';
import { WorkbenchIcon } from './WorkbenchIcon';
import { StableSegmentButton } from '../StableSegmentButton';
import { MeasureStore } from '../../common/UiStores';
import { DraftControlStore, REGULAR_POLYGON_SIDES_PRESETS } from '../../store/DraftOverlayStore';
import { RoutingMode } from '../../services/RoutingConstraintService';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { Point } from '../../models/GdsiiData';

/**
 * 鸿图画布左侧悬浮绘制工具条与触屏水平工具栏
 *
 * 1. 对齐参考布局左侧悬浮工具条序列：选择、移动、测量、矩形、多边形、路径、文本、实例、曲线，以及底部放大、缩小、全图适配；
 * 2. 完整保留 PS/AE/KLayout 风格右下角子模式三角热区与精确数值创建弹出框。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

interface DrawingToolDef {
  id: string;
  tool: ActiveTool;
  icon: string;
  label: string;
  key: string;
}

const DESKTOP_DRAWING_TOOLS: DrawingToolDef[] = [
  { id: 'select', tool: ActiveTool.Select, icon: 'select', label: '选择', key: 'S' },
  { id: 'move', tool: ActiveTool.Move, icon: 'move', label: '移动', key: 'M' },
  { id: 'measure', tool: ActiveTool.Measure, icon: 'measure', label: '测量', key: 'K' },
  { id: 'rect', tool: ActiveTool.Rect, icon: 'rect', label: '矩形', key: 'B' },
  { id: 'polygon', tool: ActiveTool.Polygon, icon: 'polygon', label: '多边形', key: 'P' },
  { id: 'path', tool: ActiveTool.Path, icon: 'path', label: '路径', key: 'L' },
  { id: 'text', tool: ActiveTool.Text, icon: 'text', label: '文本', key: 'T' },
  { id: 'instance', tool: ActiveTool.Instance, icon: 'instance', label: '实例', key: 'I' },
];

const TOUCH_DRAWING_TOOLS: DrawingToolDef[] = [
  { id: 'select', tool: ActiveTool.Select, icon: 'select', label: '选择', key: 'S' },
  { id: 'move', tool: ActiveTool.Move, icon: 'move', label: '移动', key: 'M' },
  { id: 'pan', tool: ActiveTool.Pan, icon: 'pan', label: '漫游', key: 'H' },
  { id: 'measure', tool: ActiveTool.Measure, icon: 'measure', label: '测量', key: 'K' },
  { id: 'rect', tool: ActiveTool.Rect, icon: 'rect', label: '矩形', key: 'B' },
  { id: 'polygon', tool: ActiveTool.Polygon, icon: 'polygon', label: '多边形', key: 'P' },
  { id: 'path', tool: ActiveTool.Path, icon: 'path', label: '路径', key: 'L' },
  { id: 'text', tool: ActiveTool.Text, icon: 'text', label: '文本', key: 'T' },
  { id: 'instance', tool: ActiveTool.Instance, icon: 'instance', label: '实例', key: 'I' },
];

interface CurveToolDef { name: string; label: string; commands: string; }
const CURVE_TOOLS: CurveToolDef[] = [
  { name: 'CIRCLE', label: '圆形', commands: 'M20 12A8 8 0 1 1 4 12A8 8 0 1 1 20 12Z' },
  { name: 'DONUT', label: '圆环', commands: 'M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM17 12A5 5 0 1 1 7 12A5 5 0 1 1 17 12Z' },
  { name: 'ELLIPSE', label: '椭圆', commands: 'M22 12A10 6 0 1 1 2 12A10 6 0 1 1 22 12Z' },
  { name: 'ARC', label: '圆弧', commands: 'M3 16A10 10 0 0 1 20 5M6 16A7 7 0 0 1 18 8M3 16L6 16M20 5L18 8' },
];

const PATH_WIDTH_PRESETS: number[] = [50, 100, 200, 500, 1000];
const RECT_SIZE_PRESETS: number[] = [100, 200, 500, 1000, 2000];
const TEXT_PIN_PRESETS: string[] = ['VDD', 'VSS', 'GND', 'CLK', 'IN', 'OUT'];

@Component
export struct DrawingToolbar {
  @ObjectLink draftStore: DraftControlStore;
  @ObjectLink measureStore: MeasureStore;
  @Prop currentTool: ActiveTool = ActiveTool.Select;
  @Prop activeCurveKind: string = '';
  @Prop editable: boolean = true;
  @Prop isCompact: boolean = false;
  @Prop vertical: boolean = false;
  @Prop availableHeight: number = 460;
  @Prop multiSelectAdditive: boolean = false;
  @Prop hierarchyDepth: number = 2;

  selectToolAction: (tool: ActiveTool, label: string) => void = () => {};
  interactiveCurveAction: (curveKind: string) => void = (_k: string) => {};
  curveAction: (pcellName: string) => void = () => {};
  routingModeChangeAction: (mode: RoutingMode) => void = (_m: RoutingMode) => {};
  pathWidthChangeAction: (widthStr: string) => void = (_w: string) => {};
  toggleAdditiveSelectAction: () => void = () => {};
  selectAllAction: () => void = () => {};
  clearSelectionAction: () => void = () => {};
  switchMoveToolAction: () => void = () => {};
  zoomAction: (delta: number) => void = (_d: number) => {};
  fitAllAction: () => void = () => {};
  resetViewAction: () => void = () => {};
  viewBackAction: () => void = () => {};
  setHierarchyDepthAction: (depth: number) => void = (_d: number) => {};
  exactCreateRectAction: (minX: number, minY: number, maxX: number, maxY: number) => boolean = () => false;
  viewportCenterProvider: () => Point = () => ({ x: 0, y: 0 });
  placeInstanceDialogAction: () => void = () => {};
  placePCellDialogAction: () => void = () => {};
  makeCellFromSelectionAction: () => void = () => {};
  arrayCopySelectionAction: () => void = () => {};

  @State private openPopoverId: string = '';
  @State private exactRectError: string = '';

  private toolItems(): DrawingToolDef[] {
    return this.vertical ? DESKTOP_DRAWING_TOOLS : TOUCH_DRAWING_TOOLS;
  }

  private toolEnabled(tool: ActiveTool): boolean {
    return this.editable || tool === ActiveTool.Select || tool === ActiveTool.Pan ||
      tool === ActiveTool.Measure || tool === ActiveTool.BoxZoom;
  }

  private isCurveActive(): boolean {
    return this.activeCurveKind.length > 0;
  }

  private isItemActive(item: DrawingToolDef): boolean {
    if (this.isCurveActive()) return false;
    if (item.id === 'move' && this.vertical) {
      return this.currentTool === ActiveTool.Move || this.currentTool === ActiveTool.Pan;
    }
    if (item.id === 'pan') {
      return this.currentTool === ActiveTool.Pan || this.currentTool === ActiveTool.BoxZoom;
    }
    return this.currentTool === item.tool;
  }

  private subModeTag(id: string): string {
    if (id === 'select') {
      if (this.multiSelectAdditive) return '加选';
      return this.draftStore.boxSelectRule === 0 ? '' : (this.draftStore.boxSelectRule === 1 ? '相交' : '全包');
    }
    if (id === 'move') {
      return this.currentTool === ActiveTool.Pan ? '漫游' : '';
    }
    if (id === 'pan') {
      return this.currentTool === ActiveTool.BoxZoom ? '框放' : '';
    }
    if (id === 'measure') {
      if (this.measureStore.rulerMode) return '标尺';
      if (this.measureStore.isAreaMode()) return '面积';
      return this.measureStore.angleLock === 'ortho90' ? '90°' : (this.measureStore.angleLock === 'diag45' ? '45°' : '');
    }
    if (id === 'rect') {
      if (this.draftStore.rectDrawMode === 1) return '中心';
      if (this.draftStore.rectDrawMode === 2) return '定尺';
      return this.draftStore.rectSquareLock ? '正方' : '';
    }
    if (id === 'polygon') {
      if (this.draftStore.polygonSubMode === 1) return `正${this.draftStore.regularPolygonSides}`;
      if (this.draftStore.routingMode === RoutingMode.OCTILINEAR_45) return '45°';
      if (this.draftStore.routingMode === RoutingMode.FREE) return '自由';
      return '';
    }
    if (id === 'path') {
      return this.vertical ? '' : `${this.draftStore.pathWidthStr}`;
    }
    if (id === 'text') {
      if (this.draftStore.textQuickPreset === 'AUTO_PIN') return 'PIN+';
      return this.draftStore.textQuickPreset;
    }
    return '';
  }

  private handlePrimaryClick(item: DrawingToolDef): void {
    if (item.id === 'move' && !this.editable) {
      this.selectToolAction(ActiveTool.Pan, '漫游');
      return;
    }
    if (!this.toolEnabled(item.tool)) return;
    if (item.tool === ActiveTool.Instance) {
      if (this.openPopoverId === 'instance') {
        this.openPopoverId = '';
      } else {
        this.selectToolAction(ActiveTool.Instance, item.label);
      }
      return;
    }
    if (item.id === 'move') {
      if (this.currentTool === ActiveTool.Move) {
        this.openPopoverId = this.openPopoverId === 'move' ? '' : 'move';
        return;
      }
      this.openPopoverId = '';
      this.switchMoveToolAction();
      return;
    }
    if (this.isItemActive(item)) {
      this.openPopoverId = this.openPopoverId === item.id ? '' : item.id;
      this.exactRectError = '';
      return;
    }
    this.openPopoverId = '';
    this.selectToolAction(item.tool, item.label);
  }

  private handleDiscloseOpen(item: DrawingToolDef): void {
    if (item.id !== 'move' && !this.toolEnabled(item.tool)) return;
    if (item.id === 'move') {
      if (this.editable && this.currentTool !== ActiveTool.Move && this.currentTool !== ActiveTool.Pan) {
        this.switchMoveToolAction();
      }
      this.openPopoverId = this.openPopoverId === 'move' ? '' : 'move';
      return;
    }
    if (item.tool !== ActiveTool.Instance && !this.isItemActive(item)) {
      this.selectToolAction(item.tool, item.label);
    }
    this.exactRectError = '';
    this.openPopoverId = this.openPopoverId === item.id ? '' : item.id;
  }

  private fillExactRectCenter(): void {
    const c: Point = this.viewportCenterProvider();
    this.draftStore.exactRectXStr = String(Math.round(c.x));
    this.draftStore.exactRectYStr = String(Math.round(c.y));
    this.exactRectError = '';
  }

  private commitExactRect(): void {
    const xVal: number = Number(this.draftStore.exactRectXStr.trim());
    const yVal: number = Number(this.draftStore.exactRectYStr.trim());
    const wVal: number = Number(this.draftStore.exactRectWStr.trim());
    const hVal: number = Number(this.draftStore.exactRectHStr.trim());
    if (!Number.isFinite(xVal) || !Number.isFinite(yVal) || !Number.isFinite(wVal) || !Number.isFinite(hVal) ||
      wVal <= 0 || hVal <= 0) {
      this.exactRectError = '请输入有效坐标，且宽、高须大于 0 nm';
      return;
    }
    const minX: number = this.draftStore.exactRectAnchorMode === 1 ? Math.round(xVal - wVal * 0.5) : Math.round(xVal);
    const minY: number = this.draftStore.exactRectAnchorMode === 1 ? Math.round(yVal - hVal * 0.5) : Math.round(yVal);
    const maxX: number = Math.round(minX + wVal);
    const maxY: number = Math.round(minY + hVal);
    if (maxX <= minX || maxY <= minY) {
      this.exactRectError = '矩形尺寸过小';
      return;
    }
    if (this.exactCreateRectAction(minX, minY, maxX, maxY)) {
      this.exactRectError = '';
      this.openPopoverId = '';
    } else {
      this.exactRectError = '创建未成功，请检查当前图层是否锁定或隐藏';
    }
  }

  private activeCurveButtonLabel(): string {
    for (let i = 0; i < CURVE_TOOLS.length; i++) {
      if (CURVE_TOOLS[i].name === this.activeCurveKind) {
        return CURVE_TOOLS[i].label;
      }
    }
    return '曲线';
  }

  @Builder
  private popoverHeader(title: string, shortcutHint: string) {
    Row({ space: 6 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
      if (shortcutHint.length > 0) {
        Text(shortcutHint)
          .fontSize(10)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.muted)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .backgroundColor(COLORS.surfaceMuted)
          .borderRadius(4)
      }
      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'close', iconSize: 12, color: COLORS.muted })
      }
      .width(22)
      .height(22)
      .padding(0)
      .borderRadius(Radius.pill)
      .backgroundColor(COLORS.surfaceMuted)
      .focusable(false)
      .onClick(() => { this.openPopoverId = ''; })
    }
    .width('100%')
    .padding({ bottom: 6 })
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }

  @Builder
  private quickPill(text: string, active: boolean, onTap: () => void) {
    Button(text, { type: ButtonType.Normal })
      .height(26)
      .fontSize(11)
      .padding({ left: 8, right: 8 })
      .fontColor(active ? COLORS.primary : COLORS.ink)
      .backgroundColor(active ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 1, color: active ? COLORS.primary : COLORS.border })
      .borderRadius(6)
      .focusable(false)
      .onClick(() => onTap())
  }

  @Builder
  private buildToolPopover(id: string) {
    Column({ space: 8 }) {
      if (id === 'select') {
        this.popoverHeader('选择与框选选项', 'S · Shift加选 · Tab轮选')
        Text('点选模式').fontSize(11).fontColor(COLORS.muted).width('100%')
        StableSegmentButton({
          items: [{ text: '单选替换' }, { text: '连续加减选' }] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.multiSelectAdditive ? 1 : 0,
          onItemClicked: (idx: number) => {
            if ((idx === 1) !== this.multiSelectAdditive) {
              this.toggleAdditiveSelectAction();
            }
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        Text('框选判定规则').fontSize(11).fontColor(COLORS.muted).width('100%')
        StableSegmentButton({
          items: [{ text: '左包右交(标准)' }, { text: '始终相交' }, { text: '始终全包' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.draftStore.boxSelectRule,
          onItemClicked: (idx: number) => {
            this.draftStore.boxSelectRule = idx;
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        Row({ space: 6 }) {
          this.quickPill('全选 Ctrl+A', false, () => { this.selectAllAction(); this.openPopoverId = ''; })
          this.quickPill('清空选区 Esc', false, () => { this.clearSelectionAction(); this.openPopoverId = ''; })
          this.quickPill('移动工具 M', this.currentTool === ActiveTool.Move, () => { this.switchMoveToolAction(); this.openPopoverId = ''; })
        }.width('100%')
      } else if (id === 'move' || id === 'pan') {
        this.popoverHeader('图形平移与视口漫游', 'M移动 · H抓手 · Z框放')
        StableSegmentButton({
          items: [{ text: '移动图形 (M)' }, { text: '抓手漫游 (H)' }, { text: '拉框放大 (Z)' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.currentTool === ActiveTool.BoxZoom ? 2 : (this.currentTool === ActiveTool.Pan ? 1 : 0),
          onItemClicked: (idx: number) => {
            if (idx === 0 && this.editable) {
              this.switchMoveToolAction();
            } else if (idx === 1) {
              this.selectToolAction(ActiveTool.Pan, '漫游');
            } else {
              this.selectToolAction(ActiveTool.BoxZoom, '框选放大');
            }
            this.openPopoverId = '';
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        Row({ space: 6 }) {
          this.quickPill('适配全图 F', false, () => { this.fitAllAction(); this.openPopoverId = ''; })
          this.quickPill('重置 100%', false, () => { this.resetViewAction(); this.openPopoverId = ''; })
          this.quickPill('回上级 Cell', false, () => { this.viewBackAction(); this.openPopoverId = ''; })
        }.width('100%')
        Text('层级展开深度 (快捷键 1~5)').fontSize(11).fontColor(COLORS.muted).width('100%')
        Row({ space: 6 }) {
          ForEach([1, 2, 3, 4, 5], (d: number) => {
            this.quickPill(d === 1 ? '1 仅本层' : (d === 5 ? '5 全部' : `${d} 层`), this.hierarchyDepth === d, () => {
              this.setHierarchyDepthAction(d);
            })
          }, (d: number) => `depth_${d}`)
        }.width('100%')
      } else if (id === 'measure') {
        this.popoverHeader('测量、面积与参考标尺', 'K / R · Shift锁角')
        StableSegmentButton({
          items: [{ text: '两点测距' }, { text: '拉框测面积' }, { text: '参考标尺' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.measureStore.subModeIndex(),
          onItemClicked: (idx: number) => {
            this.measureStore.setSubModeByIndex(idx);
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        if (this.measureStore.subMode === 'distance') {
          Text('测距角度锁定').fontSize(11).fontColor(COLORS.muted).width('100%')
          StableSegmentButton({
            items: [{ text: '自由角' }, { text: '正交锁90°' }, { text: '斜角锁45°' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
            selectedIndex: this.measureStore.angleLockIndex(),
            onItemClicked: (idx: number) => { this.measureStore.setAngleLockByIndex(idx); },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 11,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: 30,
            itemMinHeight: 24
          })
        } else if (this.measureStore.rulerMode) {
          Text('参考标尺类型').fontSize(11).fontColor(COLORS.muted).width('100%')
          StableSegmentButton({
            items: [{ text: '自动' }, { text: '水平Y' }, { text: '竖直X' }, { text: '十字线' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
            selectedIndex: this.measureStore.rulerOrientationIndex(),
            onItemClicked: (idx: number) => { this.measureStore.setRulerOrientationByIndex(idx); },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 11,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: 30,
            itemMinHeight: 24
          })
        }
        Text('读数显示单位').fontSize(11).fontColor(COLORS.muted).width('100%')
        StableSegmentButton({
          items: [{ text: '微米 (µm)' }, { text: '纳米 (nm)' }, { text: '双单位' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.measureStore.unitMode === 'nm' ? 1 : (this.measureStore.unitMode === 'dual' ? 2 : 0),
          onItemClicked: (idx: number) => {
            this.measureStore.unitMode = idx === 1 ? 'nm' : (idx === 2 ? 'dual' : 'um');
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        Row({ space: 6 }) {
          this.quickPill('撤上一条', false, () => {
            if (this.measureStore.rulerMode) this.measureStore.undoLastRuler();
            else this.measureStore.undoLastAnnotation();
          })
          this.quickPill(`清空测量 (${this.measureStore.totalMeasurementCount()})`, false, () => {
            this.measureStore.clearAnnotations();
          })
          this.quickPill(`清空标尺 (${this.measureStore.rulers.length})`, false, () => {
            this.measureStore.clearRulers();
          })
        }.width('100%')
      } else if (id === 'rect') {
        this.popoverHeader('矩形绘制与精确创建', 'B · Alt临时中心 · Shift正方')
        Text('鼠标/触屏绘制方式').fontSize(11).fontColor(COLORS.muted).width('100%')
        StableSegmentButton({
          items: [{ text: '对角两点' }, { text: '中心外扩' }, { text: '定宽高点放' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.draftStore.rectDrawMode,
          onItemClicked: (idx: number) => {
            if (idx >= 0 && idx <= 2) this.draftStore.rectDrawMode = idx;
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        if (this.draftStore.rectDrawMode !== 2) {
          Row({ space: 6 }) {
            this.quickPill('1:1 正方形锁定 (Shift)', this.draftStore.rectSquareLock, () => {
              this.draftStore.rectSquareLock = !this.draftStore.rectSquareLock;
            })
          }.width('100%')
        } else {
          Row({ space: 6 }) {
            Text('定宽').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.draftStore.rectFixedWNmStr })
              .width(64).height(28).fontSize(12).padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
              .onFocus(() => resetModifierKeys())
              .onKeyEvent((e: KeyEvent) => e.stopPropagation())
              .onChange((v: string) => { this.draftStore.rectFixedWNmStr = v; })
            Text('× 高').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.draftStore.rectFixedHNmStr })
              .width(64).height(28).fontSize(12).padding({ left: 6, right: 6 })
              .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
              .onFocus(() => resetModifierKeys())
              .onKeyEvent((e: KeyEvent) => e.stopPropagation())
              .onChange((v: string) => { this.draftStore.rectFixedHNmStr = v; })
            Text('nm').fontSize(11).fontColor(COLORS.muted)
            this.quickPill('互换', false, () => { this.draftStore.swapRectFixedDimensions(); })
          }.width('100%').alignItems(VerticalAlign.Center)
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(RECT_SIZE_PRESETS, (sz: number) => {
              Button(`${sz}×${sz}`, { type: ButtonType.Normal })
                .height(24).fontSize(10).padding({ left: 6, right: 6 }).margin({ right: 4, bottom: 4 })
                .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
                .border({ width: 0.8, color: COLORS.border }).borderRadius(5).focusable(false)
                .onClick(() => {
                  this.draftStore.rectFixedWNmStr = String(sz);
                  this.draftStore.rectFixedHNmStr = String(sz);
                })
            }, (sz: number) => `rsz_${sz}`)
          }.width('100%')
        }

        Column({ space: 6 }) {
          Row({ space: 6 }) {
            Text('精确数值创建矩形 (nm)')
              .fontSize(11).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
            this.quickPill('取视口中心', false, () => this.fillExactRectCenter())
          }.width('100%').alignItems(VerticalAlign.Center)

          StableSegmentButton({
            items: [{ text: '按左下角 (X, Y)' }, { text: '按中心点 (CX, CY)' }] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
            selectedIndex: this.draftStore.exactRectAnchorMode,
            onItemClicked: (idx: number) => {
              this.draftStore.exactRectAnchorMode = idx === 0 ? 0 : 1;
            },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 11,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: 28,
            itemMinHeight: 22
          })

          Row({ space: 6 }) {
            Column({ space: 3 }) {
              Text(this.draftStore.exactRectAnchorMode === 1 ? '中心 CX' : '左下 X').fontSize(10).fontColor(COLORS.muted)
              TextInput({ text: this.draftStore.exactRectXStr })
                .height(28).fontSize(12).padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((v: string) => { this.draftStore.exactRectXStr = v; this.exactRectError = ''; })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column({ space: 3 }) {
              Text(this.draftStore.exactRectAnchorMode === 1 ? '中心 CY' : '左下 Y').fontSize(10).fontColor(COLORS.muted)
              TextInput({ text: this.draftStore.exactRectYStr })
                .height(28).fontSize(12).padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((v: string) => { this.draftStore.exactRectYStr = v; this.exactRectError = ''; })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')

          Row({ space: 6 }) {
            Column({ space: 3 }) {
              Text('宽度 W (nm)').fontSize(10).fontColor(COLORS.muted)
              TextInput({ text: this.draftStore.exactRectWStr })
                .height(28).fontSize(12).padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((v: string) => { this.draftStore.exactRectWStr = v; this.exactRectError = ''; })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column({ space: 3 }) {
              Text('高度 H (nm)').fontSize(10).fontColor(COLORS.muted)
              TextInput({ text: this.draftStore.exactRectHStr })
                .height(28).fontSize(12).padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((v: string) => { this.draftStore.exactRectHStr = v; this.exactRectError = ''; })
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%')

          if (this.exactRectError.length > 0) {
            Text(this.exactRectError).fontSize(10).fontColor(COLORS.danger).width('100%')
          }

          Button('在当前图层创建矩形', { type: ButtonType.Normal })
            .width('100%').height(30).fontSize(12).fontWeight(FontWeight.Medium)
            .backgroundColor(COLORS.primary).fontColor(Color.White).borderRadius(UI.controlRadius)
            .focusable(false)
            .onClick(() => this.commitExactRect())
        }
        .width('100%')
        .padding({ top: 6 })
        .border({ width: { top: 0.8 }, color: COLORS.border })
      } else if (id === 'polygon') {
        this.popoverHeader('多边形与正 N 边形', 'P · 双击或Enter闭合 · Tab翻拐角')
        StableSegmentButton({
          items: [{ text: '逐点折线多边形' }, { text: '正 N 边形 (中心拖拽)' }] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.draftStore.polygonSubMode,
          onItemClicked: (idx: number) => {
            this.draftStore.polygonSubMode = idx === 1 ? 1 : 0;
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        if (this.draftStore.polygonSubMode === 0) {
          Text('边角走线约束').fontSize(11).fontColor(COLORS.muted).width('100%')
          StableSegmentButton({
            items: [{ text: '90°正交' }, { text: '45°斜角' }, { text: '自由折线' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
            selectedIndex: this.draftStore.routingModeIndex(),
            onItemClicked: (idx: number) => {
              const mode: RoutingMode = DraftControlStore.routingModeForIndex(idx);
              this.draftStore.routingMode = mode;
              this.routingModeChangeAction(mode);
            },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 11,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: 30,
            itemMinHeight: 24
          })
          Row({ space: 6 }) {
            this.quickPill(this.draftStore.horizontalFirst ? '正交拐向: 横先 (Tab)' : '正交拐向: 纵先 (Tab)', true, () => {
              this.draftStore.horizontalFirst = !this.draftStore.horizontalFirst;
            })
          }.width('100%')
        } else {
          Text('正多边形边数（按下定中心，拖动定外接圆半径，Shift锁15°旋转）')
            .fontSize(10.5).fontColor(COLORS.muted).width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(REGULAR_POLYGON_SIDES_PRESETS, (n: number) => {
              Button(`${n} 边`, { type: ButtonType.Normal })
                .height(26).fontSize(11).padding({ left: 8, right: 8 }).margin({ right: 5, bottom: 5 })
                .fontColor(this.draftStore.regularPolygonSides === n ? COLORS.primary : COLORS.ink)
                .backgroundColor(this.draftStore.regularPolygonSides === n ? COLORS.primarySoft : COLORS.surfaceMuted)
                .border({ width: 1, color: this.draftStore.regularPolygonSides === n ? COLORS.primary : COLORS.border })
                .borderRadius(6).focusable(false)
                .onClick(() => { this.draftStore.regularPolygonSides = n; })
            }, (n: number) => `ngon_${n}`)
          }.width('100%')
        }
      } else if (id === 'path') {
        this.popoverHeader('路径 / 波导走线设置', 'L / W · Tab翻拐向 · Backspace退点')
        StableSegmentButton({
          items: [{ text: '90°正交' }, { text: '45°折线' }, { text: '自由角' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.draftStore.routingModeIndex(),
          onItemClicked: (idx: number) => {
            const mode: RoutingMode = DraftControlStore.routingModeForIndex(idx);
            this.draftStore.routingMode = mode;
            this.routingModeChangeAction(mode);
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        Row({ space: 6 }) {
          Text('线宽 (nm)').fontSize(11).fontColor(COLORS.muted)
          TextInput({ text: this.draftStore.pathWidthStr })
            .width(72).height(28).fontSize(12).padding({ left: 6, right: 6 })
            .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
            .onFocus(() => resetModifierKeys())
            .onKeyEvent((e: KeyEvent) => e.stopPropagation())
            .onChange((v: string) => {
              this.draftStore.pathWidthStr = v;
              this.pathWidthChangeAction(v);
            })
        }.width('100%').alignItems(VerticalAlign.Center)
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(PATH_WIDTH_PRESETS, (w: number) => {
            Button(`${w}nm`, { type: ButtonType.Normal })
              .height(24).fontSize(10.5).padding({ left: 7, right: 7 }).margin({ right: 5, bottom: 4 })
              .fontColor(this.draftStore.pathWidthStr === String(w) ? COLORS.primary : COLORS.ink)
              .backgroundColor(this.draftStore.pathWidthStr === String(w) ? COLORS.primarySoft : COLORS.surfaceMuted)
              .border({ width: 1, color: this.draftStore.pathWidthStr === String(w) ? COLORS.primary : COLORS.border })
              .borderRadius(5).focusable(false)
              .onClick(() => {
                this.draftStore.pathWidthStr = String(w);
                this.pathWidthChangeAction(String(w));
              })
          }, (w: number) => `pw_${w}`)
        }.width('100%')
        Text('端头帽型 (GDS PATHTYPE)').fontSize(11).fontColor(COLORS.muted).width('100%')
        StableSegmentButton({
          items: [{ text: '平齐 (0)' }, { text: '半圆 (1)' }, { text: '方延 (2)' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: [0, 1, 2].indexOf(this.draftStore.pathType) >= 0 ? this.draftStore.pathType : 0,
          onItemClicked: (idx: number) => {
            if (idx === 0 || idx === 1 || idx === 2) this.draftStore.pathType = idx;
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
      } else if (id === 'text') {
        this.popoverHeader('文本与芯片引脚标签', 'T / X · 选预设后点击画布直落')
        Row({ space: 6 }) {
          this.quickPill('每次弹窗输入', this.draftStore.textQuickPreset.length === 0, () => {
            this.draftStore.textQuickPreset = '';
          })
          this.quickPill(`自动递增 PIN_${this.draftStore.textAutoPinIndex}++`, this.draftStore.textQuickPreset === 'AUTO_PIN', () => {
            this.draftStore.textQuickPreset = 'AUTO_PIN';
          })
          if (this.draftStore.textAutoPinIndex > 1) {
            this.quickPill('重置#1', false, () => { this.draftStore.textAutoPinIndex = 1; })
          }
        }.width('100%')
        Text('常用芯片电源 / 信号引脚一键连盖章').fontSize(11).fontColor(COLORS.muted).width('100%')
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(TEXT_PIN_PRESETS, (pin: string) => {
            Button(pin, { type: ButtonType.Normal })
              .height(26).fontSize(11).fontFamily(FONT_MONO).padding({ left: 9, right: 9 }).margin({ right: 5, bottom: 5 })
              .fontColor(this.draftStore.textQuickPreset === pin ? COLORS.primary : COLORS.ink)
              .backgroundColor(this.draftStore.textQuickPreset === pin ? COLORS.primarySoft : COLORS.surfaceMuted)
              .border({ width: 1, color: this.draftStore.textQuickPreset === pin ? COLORS.primary : COLORS.border })
              .borderRadius(6).focusable(false)
              .onClick(() => { this.draftStore.textQuickPreset = pin; })
          }, (pin: string) => `pin_${pin}`)
        }.width('100%')
      } else if (id === 'instance') {
        this.popoverHeader('单元实例与阵列引用', 'I · 支持子 Cell 行列阵列 AREF')
        Column({ space: 6 }) {
          Button('放置子 Cell 实例 / 行列阵列 (AREF)…', { type: ButtonType.Normal })
            .width('100%').height(32).fontSize(12).fontColor(Color.White).backgroundColor(COLORS.primary)
            .borderRadius(UI.controlRadius).focusable(false)
            .onClick(() => { this.openPopoverId = ''; this.placeInstanceDialogAction(); })
          Button('放置参数化器件 (PCell)…', { type: ButtonType.Normal })
            .width('100%').height(30).fontSize(12).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).focusable(false)
            .onClick(() => { this.openPopoverId = ''; this.placePCellDialogAction(); })
          Button('将当前选中图形打包为新子 Cell…', { type: ButtonType.Normal })
            .width('100%').height(30).fontSize(12).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).focusable(false)
            .onClick(() => { this.openPopoverId = ''; this.makeCellFromSelectionAction(); })
          Button('对选中图形执行行列阵列复制…', { type: ButtonType.Normal })
            .width('100%').height(30).fontSize(12).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).focusable(false)
            .onClick(() => { this.openPopoverId = ''; this.arrayCopySelectionAction(); })
        }.width('100%')
      } else if (id === 'curve') {
        this.popoverHeader('曲线与光子结构绘制', '按下定圆心 · 拖动定外径')
        StableSegmentButton({
          items: [{ text: '圆形' }, { text: '圆环' }, { text: '椭圆' }, { text: '圆弧' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
          selectedIndex: this.draftStore.curveKindIndex(),
          onItemClicked: (idx: number) => {
            const kind: string = DraftControlStore.curveKindForIndex(idx);
            this.interactiveCurveAction(kind);
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: 11,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 30,
          itemMinHeight: 24
        })
        if (this.activeCurveKind === 'DONUT' || this.activeCurveKind === 'ARC') {
          Row({ space: 6 }) {
            this.quickPill(this.draftStore.curveUseFixedWidth ? '固定环宽(nm)' : `内径比 ${this.draftStore.curveInnerRatioPct}%`, true, () => {
              this.draftStore.curveUseFixedWidth = !this.draftStore.curveUseFixedWidth;
            })
            if (this.draftStore.curveUseFixedWidth) {
              TextInput({ text: this.draftStore.curveRingWidthNmStr })
                .width(64).height(26).fontSize(11).padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(6)
                .onFocus(() => resetModifierKeys())
                .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                .onChange((v: string) => { this.draftStore.curveRingWidthNmStr = v; })
              Text('nm').fontSize(11).fontColor(COLORS.muted)
            } else {
              this.quickPill('切内径比', false, () => { this.draftStore.cycleInnerRatio(); })
            }
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        Button('打开精确曲线参数对话框…', { type: ButtonType.Normal })
          .width('100%').height(30).fontSize(12).fontColor(COLORS.primary).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).focusable(false)
          .onClick(() => {
            const target: string = this.activeCurveKind.length > 0 ? this.activeCurveKind : 'CIRCLE';
            this.openPopoverId = '';
            this.curveAction(target);
          })
      }
    }
    .width(276)
    .padding(12)
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
    .onTouch((e: TouchEvent) => e.stopPropagation())
    .onMouse((e: MouseEvent) => e.stopPropagation())
  }

  @Builder
  private buildCurvePopover() {
    this.buildToolPopover('curve')
  }

  @Builder
  private curveToolItem() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Button({ type: ButtonType.Normal }) {
        if (this.vertical) {
          SymbolGlyph($r('sys.symbol.circle_lefthalf_inset_filled'))
            .fontSize(17.5)
            .fontColor([this.isCurveActive() ? COLORS.primary : COLORS.ink])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        } else {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.circle_lefthalf_inset_filled'))
              .fontSize(15)
              .fontColor([this.isCurveActive() ? COLORS.primary : COLORS.ink])
              .renderingStrategy(SymbolRenderingStrategy.SINGLE)
            Text(this.activeCurveButtonLabel())
              .fontSize(12)
              .fontColor(this.isCurveActive() ? COLORS.primary : COLORS.ink)
              .fontWeight(this.isCurveActive() ? FontWeight.Bold : FontWeight.Medium)
          }
        }
      }
      .id('curve-tools-menu')
      .width(this.vertical ? 34 : undefined)
      .height(this.vertical ? 34 : UI.compactControlHeight)
      .padding(this.vertical ? 0 : { left: 9, right: 12 })
      .backgroundColor(this.isCurveActive() ? COLORS.primarySoft : Color.Transparent)
      .border({
        width: this.isCurveActive() ? 0.8 : 0,
        color: this.isCurveActive() ? COLORS.primary : Color.Transparent,
        radius: UI.controlRadius
      })
      .borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .enabled(this.editable)
      .hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText('曲线工具（点击启用，再点或点角标展开选项）')
      .accessibilitySelected(this.isCurveActive())
      .bindTips('曲线：点击绘制圆形/圆环/椭圆/圆弧，点右下角展开选项')
      .onClick(() => {
        if (!this.editable) return;
        if (!this.isCurveActive()) {
          this.openPopoverId = '';
          this.interactiveCurveAction('CIRCLE');
        } else {
          this.openPopoverId = this.openPopoverId === 'curve' ? '' : 'curve';
        }
      })
      .onMouse((event: MouseEvent) => {
        if (this.editable && event.action === MouseAction.Press && event.button === MouseButton.Right) {
          event.stopPropagation();
          if (!this.isCurveActive()) this.interactiveCurveAction('CIRCLE');
          this.openPopoverId = 'curve';
        }
      })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        if (!this.editable) return;
        if (!this.isCurveActive()) this.interactiveCurveAction('CIRCLE');
        this.openPopoverId = 'curve';
      }))

      Stack({ alignContent: Alignment.BottomEnd }) {
        Polygon({ width: 4.5, height: 4.5 })
          .points([[4.5, 0], [4.5, 4.5], [0, 4.5]])
          .fill(this.isCurveActive() ? COLORS.primary : COLORS.muted)
          .opacity(this.editable ? 0.6 : 0.25)
          .margin({ right: 2.5, bottom: 2.5 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(12)
      .height(12)
      .onClick(() => {
        if (!this.editable) return;
        if (!this.isCurveActive()) this.interactiveCurveAction('CIRCLE');
        this.openPopoverId = this.openPopoverId === 'curve' ? '' : 'curve';
      })
    }
    .bindPopup(this.openPopoverId === 'curve', {
      builder: this.buildCurvePopover,
      placement: this.vertical ? Placement.RightTop : Placement.Bottom,
      enableArrow: true,
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      autoCancel: true,
      mask: false,
      onStateChange: (e) => {
        if (!e.isVisible && this.openPopoverId === 'curve') {
          this.openPopoverId = '';
        }
      }
    })
  }

  @Builder
  private renderToolItem(item: DrawingToolDef) {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Button({ type: ButtonType.Normal }) {
        if (this.vertical) {
          Column({ space: 1 }) {
            WorkbenchIcon({
              name: item.id === 'move' && this.currentTool === ActiveTool.Pan
                ? 'pan'
                : (item.id === 'pan' && this.currentTool === ActiveTool.BoxZoom ? 'search' : item.icon),
              iconSize: this.subModeTag(item.id).length > 0 ? 16.5 : 17.5,
              color: this.isItemActive(item) ? COLORS.primary : COLORS.ink
            })
            if (this.subModeTag(item.id).length > 0) {
              Text(this.subModeTag(item.id))
                .fontSize(8)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.isItemActive(item) ? COLORS.primary : COLORS.muted)
                .maxLines(1)
            }
          }.justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        } else {
          Row({ space: 4 }) {
            WorkbenchIcon({
              name: item.id === 'pan' && this.currentTool === ActiveTool.BoxZoom ? 'search' : item.icon,
              iconSize: 15,
              color: this.isItemActive(item) ? COLORS.primary : COLORS.ink
            })
            Text(this.subModeTag(item.id).length > 0 ? `${item.label}·${this.subModeTag(item.id)}` : item.label)
              .fontSize(12)
              .fontColor(this.isItemActive(item) ? COLORS.primary : COLORS.ink)
              .fontWeight(this.isItemActive(item) ? FontWeight.Bold : FontWeight.Medium)
            if (!this.isCompact) {
              Text(item.key)
                .fontSize(10)
                .fontColor(this.isItemActive(item) ? COLORS.primary : COLORS.muted)
                .fontFamily(FONT_MONO)
            }
          }
          .alignItems(VerticalAlign.Center)
        }
      }
      .width(this.vertical ? 34 : undefined)
      .height(this.vertical ? 34 : UI.compactControlHeight)
      .padding(this.vertical ? 0 : { left: 9, right: 12 })
      .margin(this.vertical ? 0 : { right: 2 })
      .borderRadius(UI.controlRadius)
      .animation(null)
      .backgroundColor(this.isItemActive(item) ? COLORS.primarySoft : Color.Transparent)
      .border({
        width: this.isItemActive(item) ? 0.8 : 0,
        color: this.isItemActive(item) ? COLORS.primary : Color.Transparent,
        radius: UI.controlRadius
      })
      .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
      .animation(null)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .stateEffect(true)
      .enabled(item.id === 'move' ? true : this.toolEnabled(item.tool))
      .hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText(`${item.label} ${item.key}`)
      .accessibilityDescription(`${item.label} (${item.key})，再次点击或点右下角展开绘制模式`)
      .accessibilitySelected(this.isItemActive(item))
      .bindTips(`${item.label} (${item.key}) · 再点或右键展开子模式`)
      .onClick(() => this.handlePrimaryClick(item))
      .onMouse((event: MouseEvent) => {
        if ((item.id === 'move' || this.toolEnabled(item.tool)) &&
          event.action === MouseAction.Press && event.button === MouseButton.Right) {
          event.stopPropagation();
          this.handleDiscloseOpen(item);
        }
      })
      .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
        this.handleDiscloseOpen(item);
      }))

      Stack({ alignContent: Alignment.BottomEnd }) {
        Polygon({ width: 4.5, height: 4.5 })
          .points([[4.5, 0], [4.5, 4.5], [0, 4.5]])
          .fill(this.isItemActive(item) ? COLORS.primary : COLORS.muted)
          .opacity((item.id === 'move' || this.toolEnabled(item.tool)) ? 0.6 : 0.25)
          .margin({ right: 2.5, bottom: 2.5 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width(12)
      .height(12)
      .onClick(() => this.handleDiscloseOpen(item))
    }
    .bindPopup(this.openPopoverId === item.id, {
      builder: () => { this.buildToolPopover(item.id); },
      placement: this.vertical ? Placement.RightTop : Placement.Bottom,
      enableArrow: true,
      popupColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      autoCancel: true,
      mask: false,
      onStateChange: (e) => {
        if (!e.isVisible && this.openPopoverId === item.id) {
          this.openPopoverId = '';
        }
      }
    })
  }

  build() {
    if (this.vertical) {
      Scroll() {
        Column({ space: 3 }) {
          ForEach(this.toolItems(), (item: DrawingToolDef) => {
            this.renderToolItem(item)
          }, (item: DrawingToolDef) => item.id)

          this.curveToolItem()

          Divider().width(24).color(COLORS.border).margin({ top: 3, bottom: 3 })

          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({ name: 'loupe', iconSize: 17, color: COLORS.ink })
          }
          .width(34).height(32).padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .hoverEffect(HoverEffect.Highlight)
          .focusable(false)
          .accessibilityText('放大视图')
          .bindTips('放大视图 (+)')
          .onClick(() => this.zoomAction(1))

          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({ name: 'zoomOut', iconSize: 17, color: COLORS.ink })
          }
          .width(34).height(32).padding(0)
          .backgroundColor(Color.Transparent)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .hoverEffect(HoverEffect.Highlight)
          .focusable(false)
          .accessibilityText('缩小视图')
          .bindTips('缩小视图 (-)')
          .onClick(() => this.zoomAction(-1))

          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({
              name: 'dashedRect',
              iconSize: 17,
              color: this.currentTool === ActiveTool.BoxZoom ? COLORS.primary : COLORS.ink
            })
          }
          .width(34).height(32).padding(0)
          .backgroundColor(this.currentTool === ActiveTool.BoxZoom ? COLORS.primarySoft : Color.Transparent)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .hoverEffect(HoverEffect.Highlight)
          .focusable(false)
          .accessibilityText('适配全图（右键切换拉框放大）')
          .bindTips('全图适配 (F) · 右键或长按切换拉框放大 (Z)')
          .onClick(() => {
            if (this.currentTool === ActiveTool.BoxZoom) {
              this.selectToolAction(ActiveTool.Select, '选择');
            }
            this.fitAllAction();
          })
          .onMouse((event: MouseEvent) => {
            if (event.action === MouseAction.Press && event.button === MouseButton.Right) {
              event.stopPropagation();
              this.selectToolAction(ActiveTool.BoxZoom, '框选放大');
            }
          })
          .gesture(LongPressGesture({ repeat: false, duration: 380 }).onAction(() => {
            this.selectToolAction(ActiveTool.BoxZoom, '框选放大');
          }))

          if (this.measureStore.totalMeasurementCount() > 0) {
            Button({ type: ButtonType.Normal }) {
              WorkbenchIcon({ name: 'delete', iconSize: 15, color: COLORS.danger })
            }
            .width(34).height(30).padding(0)
            .backgroundColor(COLORS.dangerSoft)
            .borderRadius(UI.controlRadius)
            .focusable(false)
            .accessibilityText('清空测量与标尺')
            .bindTips('清空全部测量与标尺 (Shift+K)')
            .onClick(() => { this.measureStore.clearAll(); })
          }
        }
      }
      .scrollable(ScrollDirection.Vertical)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width(44)
      .constraintSize({ maxHeight: Math.max(120, this.availableHeight) })
      .padding({ left: 5, right: 5, top: 6, bottom: 6 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
    } else {
      Scroll() {
        Row() {
          ForEach(this.toolItems(), (item: DrawingToolDef) => {
            this.renderToolItem(item)
          }, (item: DrawingToolDef) => item.id)
          Row().width(1).height(22).backgroundColor(COLORS.border).margin({ left: 3, right: 4 })
          this.curveToolItem()
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .height(UI.controlHeight)
      .width('100%')
      .padding({ left: 8, right: 8 })
      .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
        ? hongTuThemeState.luminous.translucentCardColor
        : COLORS.surface)
      .border({ width: { bottom: 0.8 }, color: COLORS.border })
    }
  }
}
