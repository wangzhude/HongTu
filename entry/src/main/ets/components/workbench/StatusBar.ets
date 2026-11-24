import { COLORS, umText, formatZoomPercent } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { WorkbenchIcon } from './WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { CursorStore } from '../../common/UiStores';
import { PrecisionSettings, GEOMETRY_SNAP_KINDS, validatePrecision, quantizationText, cleanMetricNumber } from '../../services/PrecisionService';
import { MENU_ITEM_STYLE, menuCheckIcon, menuIcon, menuStyle, workbenchLuminousMenuOptions } from '../../common/WorkbenchMenuStyle';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { hongTuThemeState } from '../../store/ThemeStore';

/**
 * 鸿图主界面底部结构化状态栏（对齐参考布局：DRC 状态 | 已选对象 | 单位 | 栅格 µm <---> 准星 X/Y µm | 缩放 ▾）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct WorkbenchStatusBar {
  @Prop statusText: string = '就绪';
  @Prop shapeCount: number = 0;
  @Prop selectedShapeCount: number = 0;
  @Prop drcIssueCount: number = 0;
  @Prop drcHasRun: boolean = false;
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
  runDrcAction: () => void = () => {};
  setZoomPercentAction: (percent: number) => void = (_p: number) => {};
  fitAllAction: () => void = () => {};
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

  private zoomMenuSizing(): MenuItemOptions[] {
    return [
      { content: '25%', symbolStartIcon: menuIcon('zoomOut') },
      { content: '50%', symbolStartIcon: menuIcon('zoomOut') },
      { content: '100%', symbolStartIcon: menuIcon('view') },
      { content: '200%', symbolStartIcon: menuIcon('zoomIn') },
      { content: '400%', symbolStartIcon: menuIcon('zoomIn') },
      { content: '适配全部版图', labelInfo: 'F', symbolStartIcon: menuIcon('view') }
    ];
  }

  @Builder
  private buildStatusZoomMenu() {
    Menu() {
      MenuItemGroup({ header: '缩放比例' }) {
        ForEach([25, 50, 100, 200, 400], (pct: number) => {
          MenuItem({
            content: `${pct}%`,
            symbolStartIcon: menuIcon(pct < 100 ? 'zoomOut' : (pct > 100 ? 'zoomIn' : 'view')),
            symbolEndIcon: menuCheckIcon(Math.abs(this.zoomPercent - pct) < 0.5)
          })
            .attributeModifier(MENU_ITEM_STYLE)
            .selected(Math.abs(this.zoomPercent - pct) < 0.5)
            .onClick(() => this.setZoomPercentAction(pct))
        }, (pct: number): string => `sbz_${pct}_${Math.round(this.zoomPercent)}`)
      }
      MenuItemGroup() {
        MenuItem({ content: '适配全部版图', labelInfo: 'F', symbolStartIcon: menuIcon('view') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.fitAllAction())
      }
    }
    .attributeModifier(menuStyle(this.zoomMenuSizing(), this.getUIContext()))
  }

  @Builder
  private statusSeparator() {
    Row()
      .width(1)
      .height(12)
      .backgroundColor(COLORS.border)
      .margin({ left: 10, right: 10 })
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
    .height(32)
    .width('100%')
    .padding({ left: 14, right: 14 })
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

      Row() {
        this.precisionButton()
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
      // 1. DRC 状态指示器（对齐参考图左下角绿勾「DRC: 通过 (0 个违例)」）
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          if (this.drcIssueCount > 0) {
            WorkbenchIcon({ name: 'warning', iconSize: 14, color: COLORS.danger })
            Text(`DRC: 未通过 (${this.drcIssueCount} 个违例)`)
              .fontSize(11.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.danger)
          } else {
            Stack({ alignContent: Alignment.Center }) {
              Circle({ width: 14, height: 14 }).fill(COLORS.success)
              WorkbenchIcon({ name: 'check', iconSize: 9.5, color: '#FFFFFF' })
            }
            .width(14)
            .height(14)
            Text('DRC: ')
              .fontSize(11.5)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
            Text('通过')
              .fontSize(11.5)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.success)
            Text(` (${this.drcIssueCount} 个违例)`)
              .fontSize(11.5)
              .fontColor(COLORS.muted)
          }
        }.alignItems(VerticalAlign.Center)
      }
      .height(24)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hoverEffect(HoverEffect.Highlight)
      .bindTips('点击运行 DRC 设计规则检查')
      .onClick(() => this.runDrcAction())

      this.statusSeparator()

      // 2. 已选择对象计数 + 未保存标记
      Row({ space: 6 }) {
        Text(`已选择: ${this.selectedShapeCount} 个对象`)
          .fontSize(11.5)
          .fontColor(COLORS.ink)
          .bindTips(this.statusText)
        if (this.documentDirty) {
          Row({ space: 3 }) {
            DrawnStatusIcon({ kind: 'dirty', iconSize: 8, strokeColor: COLORS.warning, showSoftPlate: false })
            Text('未保存').fontSize(10.5).fontColor(COLORS.warning)
          }.alignItems(VerticalAlign.Center)
        }
      }.alignItems(VerticalAlign.Center)

      this.statusSeparator()

      // 3. 单位指示
      Text('单位: µm')
        .fontSize(11.5)
        .fontColor(COLORS.ink)

      this.statusSeparator()

      // 4. 栅格尺寸（点击弹出精度与几何吸附面板）
      Button({ type: ButtonType.Normal }) {
        Text(`栅格: ${umText(this.effectiveDisplayGrid())} µm`)
          .fontSize(11.5)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.ink)
      }
      .height(24)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hoverEffect(HoverEffect.Highlight)
      .accessibilityText('精度与栅格设置')
      .bindTips(`DBU ${cleanMetricNumber(this.dbuNm)} nm · 步长 ${cleanMetricNumber(this.effectiveDrawStep())} nm（点击配置精度与吸附）`)
      .onClick(() => this.openPrecision())
      .bindPopup(this.showPrecision, {
        builder: this.precisionPopup,
        placement: Placement.Top,
        onStateChange: (event: PopupStateChangeParam) => { this.showPrecision = event.isVisible; }
      })

      // 5. 中部弹性区（显示实时测量读数）
      Row() {
        if (this.cursorStore.readout.length > 0) {
          Text(this.readoutLine())
            .fontSize(11)
            .fontColor(COLORS.success)
            .fontFamily(FONT_MONO)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 16, right: 12 })
        }
      }
      .layoutWeight(1)
      .justifyContent(FlexAlign.End)

      // 6. 右侧实时准星坐标 X / Y (µm)
      Row({ space: 14 }) {
        Row({ space: 5 }) {
          WorkbenchIcon({ name: 'magnet', iconSize: 13, color: COLORS.muted })
          Text(`X: ${umText(this.cursorStore.x)} µm`)
            .fontSize(11.5)
            .fontFamily(FONT_MONO)
            .fontColor(COLORS.ink)
            .constraintSize({ minWidth: 96 })
        }.alignItems(VerticalAlign.Center)

        Text(`Y: ${umText(this.cursorStore.y)} µm`)
          .fontSize(11.5)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.ink)
          .constraintSize({ minWidth: 88 })
      }
      .alignItems(VerticalAlign.Center)

      this.statusSeparator()

      // 7. 缩放下拉选择器
      Button({ type: ButtonType.Normal }) {
        Row({ space: 4 }) {
          Text(`缩放: ${formatZoomPercent(this.zoomPercent)}`)
            .fontSize(11.5)
            .fontFamily(FONT_MONO)
            .fontColor(COLORS.ink)
          WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
        }.alignItems(VerticalAlign.Center)
      }
      .height(24)
      .padding({ left: 6, right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(5)
      .focusable(false)
      .hoverEffect(HoverEffect.Highlight)
      .bindTips(`${this.nativeText} · 点击快速切换缩放比例`)
      .bindMenu(this.buildStatusZoomMenu, workbenchLuminousMenuOptions())
    }
    .height(30)
    .width('100%')
    .padding({ left: 12, right: 12 })
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
    Button(this.isCompact ? '精度' : `栅格 ${umText(this.effectiveDisplayGrid())} µm`, { type: ButtonType.Normal })
      .height(UI.compactControlHeight).fontSize(UI.fontCaption).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
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
