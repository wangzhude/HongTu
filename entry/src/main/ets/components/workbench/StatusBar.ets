import { COLORS, umText, formatZoomPercent } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { WorkbenchIcon } from './WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { CursorStore } from '../../common/UiStores';
import { PrecisionSettings, GEOMETRY_SNAP_KINDS, validatePrecision, quantizationText, cleanMetricNumber } from '../../services/PrecisionService';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { hongTuThemeState } from '../../store/ThemeStore';

/**
 * 鸿图主界面状态栏（纯矢量圆点指示器 + 轻通透光感背板 + 数据区与画布区按模块分流）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct WorkbenchStatusBar {
  @Prop statusText: string = '就绪';
  @Prop shapeCount: number = 0;
  @Prop visibleLayerCount: number = 0;
  @Prop zoomPercent: number = 100;
  @Prop gridSize: number = 10;
  @Prop dbuNm: number = 1;
  @Prop drawStepNm: number = -1;
  @Prop displayGridNm: number = -1;
  @Prop geometrySnapEnabled: boolean = false;
  @Prop geometrySnapKinds: string[] = ['顶点', '交点', '中点', '包围盒中心', '边'];
  precisionChangeAction: (settings: PrecisionSettings) => boolean | void = () => {};
  precisionContextProvider: () => string = () => '';
  @State showPrecision: boolean = false;
  @State dbuDraft: string = '1';
  @State drawDraft: string = '10';
  @State displayDraft: string = '10';
  @State geometryDraft: boolean = false;
  @State kindsDraft: string[] = [];
  @State precisionError: string = '';
  private precisionOpenedContext: string = '';
  @Prop nativeText: string = 'Native: unknown';
  @Prop viewMode: string = '编辑';
  @Prop isCompact: boolean = false;
  @Prop desktopMode: boolean = false;
  @Prop dataMode: boolean = false;
  @ObjectLink cursorStore: CursorStore;
  @Prop documentDirty: boolean = false;

  private dataStatusLabel(): string {
    const trimmed: string = this.statusText.trim();
    if (trimmed.length === 0 || trimmed.startsWith('当前工具') || trimmed.startsWith('已激活 L')) {
      return '数据管理就绪';
    }
    return trimmed;
  }

  @Builder
  private dataStatusBar() {
    Row() {
      Text(this.dataStatusLabel())
        .fontSize(11)
        .fontColor(COLORS.ink)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.documentDirty) {
        Row({ space: 4 }) {
          DrawnStatusIcon({ kind: 'dirty', iconSize: 10, strokeColor: COLORS.warning, showSoftPlate: false })
          Text('未保存').fontSize(10).fontColor(COLORS.warning)
        }
        .alignItems(VerticalAlign.Center)
        .margin({ left: 10 })
      }
      if (!this.isCompact && this.shapeCount > 0) {
        Text(`当前版图 ${this.shapeCount} 个图元`)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .margin({ left: 16 })
      }
    }
    .height(UI.controlHeight)
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { top: 0.8 }, color: COLORS.border })
  }

  @Builder
  private legacyBar() {
    Row() {
      Row() {
        WorkbenchIcon({ name: this.viewMode === '查看' ? 'eye' : 'edit', iconSize: 10, color: '#FFFFFF' })
        Text(this.viewMode === '查看' ? ' 查看' : ' 编辑')
          .fontSize(10)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
      }
      .linearGradient({
        angle: 135,
        colors: this.viewMode === '查看'
          ? [['#149E92', 0.0], ['#35B8AB', 1.0]]
          : [['#0A73F6', 0.0], ['#2984FF', 1.0]]
      })
      .borderRadius(UI.segmentItemRadius)
      .padding({ left: 8, right: 8, top: 2, bottom: 2 })
      .margin({ right: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.documentDirty) {
        Row({ space: 4 }) {
          DrawnStatusIcon({ kind: 'dirty', iconSize: 10, strokeColor: COLORS.warning, showSoftPlate: false })
          Text('未保存')
            .fontSize(10)
            .fontColor(COLORS.warning)
            .fontFamily(FONT_MONO)
        }
        .alignItems(VerticalAlign.Center)
        .margin({ right: 8 })
      }

      Text(this.statusText)
        .fontSize(11)
        .fontColor(COLORS.muted)
        .fontFamily(FONT_MONO)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      if (this.cursorStore.readout.length > 0) {
        Text(this.readoutLine())
          .fontSize(10)
          .fontColor(COLORS.success)
          .fontFamily(FONT_MONO)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ right: 12 })
      }

      if (!this.isCompact) {
        Row() {
          StatusMetric({ label: '图形', value: this.shapeCount.toString() })
          StatusMetric({ label: '图层', value: this.visibleLayerCount.toString() })
          StatusMetric({ label: '缩放', value: formatZoomPercent(this.zoomPercent) })
          StatusMetric({ label: 'X(µm)', value: umText(this.cursorStore.x) })
          StatusMetric({ label: 'Y(µm)', value: umText(this.cursorStore.y), last: this.cursorStore.layerNumber < 0 })
          if (this.cursorStore.layerNumber >= 0) {
            StatusMetric({ label: '光标层', value: `L${this.cursorStore.layerNumber}/D${this.cursorStore.datatype}`, last: true })
          }
        }
        .alignItems(VerticalAlign.Center)
      }

      Row() {
        this.precisionButton()

        Row() {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.nativeText.indexOf('ERROR') >= 0 ? COLORS.danger : COLORS.success)
          Text(this.nativeText.replace('Native: ', 'Native '))
            .fontSize(10)
            .fontColor(COLORS.muted)
            .fontFamily(FONT_MONO)
            .margin({ left: 5 })
        }
        .alignItems(VerticalAlign.Center)
        .margin({ left: 10 })
        .padding({ left: 8, right: 8, top: 2, bottom: 2 })
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.segmentItemRadius)
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(UI.controlHeight)
    .width('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { top: 0.8 }, color: COLORS.border })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  private desktopBar() {
    Row() {
      Text(this.statusText)
        .fontSize(11)
        .fontColor(COLORS.ink)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.documentDirty) {
        Row({ space: 4 }) {
          DrawnStatusIcon({ kind: 'dirty', iconSize: 10, strokeColor: COLORS.warning, showSoftPlate: false })
          Text('未保存').fontSize(10).fontColor(COLORS.warning)
        }
        .alignItems(VerticalAlign.Center)
        .margin({ left: 10 })
      }
      if (this.cursorStore.readout.length > 0) {
        Text(this.readoutLine())
          .fontSize(10)
          .fontColor(COLORS.success)
          .fontFamily(FONT_MONO)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 320 })
          .margin({ left: 14, right: 16 })
      }
      Text(`X: ${umText(this.cursorStore.x)} µm`)
        .fontSize(10)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.muted)
        .margin({ left: 20 })
      Text(`Y: ${umText(this.cursorStore.y)} µm`)
        .fontSize(10)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.muted)
        .margin({ left: 20 })
      Text(formatZoomPercent(this.zoomPercent))
        .fontSize(10)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.muted)
        .margin({ left: 20 })
      Row().width(1).height(13).backgroundColor(COLORS.border).margin({ left: 18, right: 18 })
      this.precisionButton()
    }
    .height(UI.controlHeight)
    .width('100%')
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { top: 0.8 }, color: COLORS.border })
  }

  build() {
    if (this.dataMode) {
      this.dataStatusBar()
    } else if (this.desktopMode) {
      this.desktopBar()
    } else {
      this.legacyBar()
    }
  }

  private effectiveDrawStep(): number { return this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize; }
  private effectiveDisplayGrid(): number { return this.displayGridNm > 0 ? this.displayGridNm : this.gridSize; }

  private openPrecision(): void {
    this.dbuDraft = String(cleanMetricNumber(this.dbuNm));
    this.drawDraft = String(cleanMetricNumber(this.effectiveDrawStep()));
    this.displayDraft = String(cleanMetricNumber(this.effectiveDisplayGrid()));
    this.geometryDraft = this.geometrySnapEnabled;
    this.kindsDraft = this.geometrySnapKinds.slice();
    this.precisionError = '';
    this.precisionOpenedContext = this.precisionContextProvider();
    this.showPrecision = true;
  }

  private commitPrecision(): void {
    if (this.precisionOpenedContext !== this.precisionContextProvider()) { this.precisionError = '版图已变化，请重新打开精度设置'; return; }
    if ([this.dbuDraft, this.drawDraft, this.displayDraft].some((value: string) => value.trim().length === 0)) { this.precisionError = '请填写完整的精度数值'; return; }
    const settings: PrecisionSettings = { dbuNm: Number(this.dbuDraft), drawStepNm: Number(this.drawDraft),
      displayGridNm: Number(this.displayDraft), geometrySnapEnabled: this.geometryDraft, geometrySnapKinds: this.kindsDraft.slice() };
    this.precisionError = validatePrecision(settings);
    if (this.precisionError.length > 0) return;
    try {
      if (this.precisionChangeAction(settings) === false) { this.precisionError = '精度未应用，请检查状态栏说明'; return; }
      this.showPrecision = false;
    } catch (error) { this.precisionError = `精度未应用：${String(error)}`; }
  }

  private toggleSnapKind(kind: string, enabled: boolean): void {
    const current: boolean = this.kindsDraft.indexOf(kind) >= 0;
    if (enabled === current) {
      return;
    }
    this.kindsDraft = enabled ? this.kindsDraft.concat([kind]).filter((item: string, index: number, all: string[]) => all.indexOf(item) === index)
      : this.kindsDraft.filter((item: string) => item !== kind);
  }

  private coordinateQuantization(): string {
    const dbu: number = Number(this.dbuDraft);
    if (!Number.isFinite(dbu) || dbu <= 0) return '';
    try { return `X ${quantizationText(this.cursorStore.x, dbu)}\nY ${quantizationText(this.cursorStore.y, dbu)}`; }
    catch (error) { return String(error); }
  }

  @Builder
  private precisionButton() {
    Button(this.isCompact ? '精度' : `DBU ${cleanMetricNumber(this.dbuNm)} · 步长 ${cleanMetricNumber(this.effectiveDrawStep())} · 网格 ${cleanMetricNumber(this.effectiveDisplayGrid())} nm`, { type: ButtonType.Normal })
      .height(UI.compactControlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      .padding({ left: 8, right: 8 }).accessibilityText('精度与吸附设置')
      .bindTips('文件 DBU、绘制步长、显示网格和几何吸附')
      .onClick(() => this.openPrecision())
      .bindPopup(this.showPrecision, { builder: this.precisionPopup, placement: Placement.Top,
        onStateChange: (event: PopupStateChangeParam) => { this.showPrecision = event.isVisible; } })
  }

  @Builder
  private precisionPopup() {
    Column({ space: 8 }) {
      PanelHeading({ title: '精度与吸附', subtitle: '',
        canClose: true, closeAction: () => { this.showPrecision = false; } })
      Row({ space: 8 }) {
        Text('文件 DBU (nm)').fontSize(12).fontColor(COLORS.ink).width(140)
        TextInput({ text: this.dbuDraft }).layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => this.dbuDraft = value)
      }
      Row({ space: 8 }) {
        Text('绘制步长 (nm)').fontSize(12).fontColor(COLORS.ink).width(140)
        TextInput({ text: this.drawDraft }).layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => this.drawDraft = value)
      }
      Row({ space: 8 }) {
        Text('显示网格 (nm)').fontSize(12).fontColor(COLORS.ink).width(140)
        TextInput({ text: this.displayDraft }).layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => this.displayDraft = value)
      }
      Row() {
        Text('几何吸附').fontSize(12).fontColor(COLORS.ink).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.geometryDraft }).onChange((enabled: boolean) => {
          if (enabled === this.geometryDraft) {
            return;
          }
          this.geometryDraft = enabled;
        })
      }
      ForEach(GEOMETRY_SNAP_KINDS, (kind: string) => {
        Row() {
          Text(kind).fontSize(12).fontColor(COLORS.ink).layoutWeight(1)
          Checkbox({ name: kind }).select(this.kindsDraft.indexOf(kind) >= 0)
            .onChange((enabled: boolean) => this.toggleSnapKind(kind, enabled))
        }.width('100%').height(32)
      }, (kind: string) => kind)
      Text(this.coordinateQuantization()).fontSize(11).fontFamily(FONT_MONO).fontColor(COLORS.muted).width('100%')
      if (this.precisionError.length > 0) Text(this.precisionError).fontSize(12).fontColor(COLORS.danger).width('100%')
      Row({ space: 10 }) {
        Blank()
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).width(88).fontSize(UI.fontBody)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onClick(() => this.showPrecision = false)
        Button('应用', { type: ButtonType.Normal }).height(UI.controlHeight).width(88).fontSize(UI.fontBody)
          .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .onClick(() => this.commitPrecision())
      }
      .width('100%').padding({ top: 8 })
    }
    .width(this.isCompact ? 300 : 340)
    .padding(UI.panelPadding)
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
  }

  private readoutLine(): string {
    const text: string = this.cursorStore.readout;
    const nl: number = text.indexOf('\n');
    return nl < 0 ? text : text.substring(0, nl);
  }
}

@Component
struct StatusMetric {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop last: boolean = false;

  build() {
    Row() {
      Text(this.label)
        .fontSize(10)
        .fontColor(COLORS.muted)
      Text(this.value)
        .fontSize(10)
        .fontColor(COLORS.ink)
        .fontFamily(FONT_MONO)
        .margin({ left: 4 })
    }
    .alignItems(VerticalAlign.Center)
    .margin({ left: 0, right: 14 })
  }
}
