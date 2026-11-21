import { hongTuThemeState } from '../../store/ThemeStore';
import { SettingsToggleRow } from '../SettingsKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { Shape } from '../../models/GdsiiData';
import { BooleanGeometryPanel } from './BooleanPreviewDialog';
import { LayerExpressionOptions, LayerExpressionPreview, LayerExpressionResult } from '../../services/LayerExpressionService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct LayerExpressionDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  documentProvider: () => string = () => '';
  cellNameProvider: () => string = () => '';
  dbuProvider: () => number = () => 1;
  layerProvider: () => number[] = () => [1, 0];
  sourcesProvider: () => Shape[] = () => [];
  sourceRegionsProvider: (sources: Shape[]) => Shape[] = (sources: Shape[]): Shape[] => sources;
  prepareAction: (options: LayerExpressionOptions) => LayerExpressionResult = (_options: LayerExpressionOptions) => ({ ok: false, message: '' });
  applyAction: (preview: LayerExpressionPreview) => LayerExpressionResult = (_preview: LayerExpressionPreview) => ({ ok: false, message: '' });
  cancelAction: (preview?: LayerExpressionPreview) => void = (_preview?: LayerExpressionPreview) => {};
  private openedContext: string = '';
  private preview: LayerExpressionPreview | undefined = undefined;
  @State expression: string = '1/0';
  @State outputLayer: string = '1';
  @State outputDatatype: string = '0';
  @State keepSources: boolean = true;
  @State depthIndex: number = 0;
  @State busy: boolean = false;
  @State ready: boolean = false;
  @State sources: Shape[] = [];
  @State outputs: Shape[] = [];
  @State status: string = '';
  @State contentWidth: number = 640;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    const pair: number[] = this.layerProvider();
    this.expression = `${pair[0]}/${pair[1]}`;
    this.outputLayer = `${pair[0]}`; this.outputDatatype = `${pair[1]}`;
    this.keepSources = true; this.depthIndex = 0; this.busy = false; this.invalidate(); this.status = '';
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }
  private depth(): number { return [0, 1, 2, 3, 4, 5, 8, 16, 32][this.depthIndex]; }
  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview);
    this.preview = undefined; this.ready = false; this.sources = []; this.outputs = [];
  }
  private changed(): void { this.invalidate(); this.status = '参数已变化，请更新预览'; }
  private refresh(): void {
    if (this.busy) return;
    this.invalidate();
    if (this.openedContext !== this.contextProvider()) { this.status = '文档或编辑范围已变化，请重新打开全层表达式'; return; }
    if (!this.outputLayer.trim() || !this.outputDatatype.trim()) { this.status = '请填写输出 Layer 和 Datatype'; return; }
    this.busy = true;
    try {
      const result: LayerExpressionResult = this.prepareAction({ expression: this.expression, outputLayer: Number(this.outputLayer),
        outputDatatype: Number(this.outputDatatype), keepSources: this.keepSources, gridNm: this.dbuProvider(),
        documentIdentity: this.documentProvider(), hierarchyDepth: this.depth() });
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview; this.outputs = result.preview.outputs;
        this.sources = result.preview.sourceGeometry;
        if (this.openedContext !== this.contextProvider()) { this.invalidate(); this.status = '文档在计算期间变化，请重新打开全层表达式'; return; }
        this.ready = true;
        this.status = `深度 ${this.depth()} · ${result.preview.sourceIds.length} 个源对象 / ${result.preview.sourceOccurrenceCount} 次放置 · ${this.outputs.length} 个结果 · 面积 ${result.preview.areaNm2} nm² · DBU ${result.preview.options.gridNm} nm${result.preview.roundCapErrorNm > 0 ? ` · 圆端最大误差 ≤ ${result.preview.roundCapErrorNm.toPrecision(4)} nm` : ''}`;
      }
    } catch (error) { this.status = `预览失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  private apply(): void {
    if (this.busy || !this.ready || this.preview === undefined) return;
    if (this.openedContext !== this.contextProvider()) { this.invalidate(); this.status = '文档或编辑范围已变化，请重新打开全层表达式'; return; }
    this.busy = true;
    try {
      const result: LayerExpressionResult = this.applyAction(this.preview);
      this.status = result.message;
      if (result.ok) this.controller.close(); else this.invalidate();
    } catch (error) { this.invalidate(); this.status = `提交失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  @Builder
  CancelButton() {
    Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => { this.invalidate(); this.controller.close(); })
  }
  @Builder
  RefreshButton() {
    Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => this.refresh())
  }
  @Builder
  ApplyButton() {
    Button('应用', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.ready && !this.busy).backgroundColor(COLORS.primary).fontColor(Color.White).onClick(() => this.apply())
  }
  build() {
    Column({ space: 16 }) {
      Text('全层表达式').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text(`当前 Cell ${this.cellNameProvider()} · DBU ${this.dbuProvider()} nm`).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          TextInput({ text: this.expression, placeholder: '(1/0 | 2/0) - 3/0' }).height(UI.fieldHeight).width('100%')
            .fontSize(UI.fontBody).fontFamily('monospace').fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
            .defaultFocus(true)
            .onFocus(() => { resetModifierKeys(); })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .onChange((value: string) => { if (value !== this.expression) { this.expression = value; this.changed(); } })
          Text('& 相交 · - 相减 · ^ 异或 · | 合并 · * 通配').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          Column({ space: 8 }) {
            Text('递归深度 · 子 Cell 层数').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            Select([{ value: '0 · 仅当前 Cell' }, { value: '1 · 子 Cell 一层' }, { value: '2 · 子 Cell 两层' },
              { value: '3 · 子 Cell 三层' }, { value: '4 · 子 Cell 四层' }, { value: '5 · 子 Cell 五层' },
              { value: '8 · 子 Cell 八层' }, { value: '16 · 子 Cell 十六层' }, { value: '32 · 子 Cell 三十二层' }])
              .selected(this.depthIndex).value(this.depth() === 0 ? '0 · 仅当前 Cell' : `${this.depth()} · 子 Cell 层数`)
              .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
              .onSelect((index: number) => { if (index !== this.depthIndex) { this.depthIndex = index; if (this.depth() > 0) this.keepSources = true; this.changed(); } })
          }.width('100%')
          Row({ space: 12 }) {
            Column({ space: 8 }) {
              Text('输出 Layer').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              TextInput({ text: this.outputLayer, placeholder: 'Layer' }).height(UI.fieldHeight).width('100%')
                .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .onChange((value: string) => { if (value !== this.outputLayer) { this.outputLayer = value; this.changed(); } })
            }.layoutWeight(1)
            Column({ space: 8 }) {
              Text('Datatype').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              TextInput({ text: this.outputDatatype, placeholder: 'Datatype' }).height(UI.fieldHeight).width('100%')
                .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .onChange((value: string) => { if (value !== this.outputDatatype) { this.outputDatatype = value; this.changed(); } })
            }.layoutWeight(1)
          }.width('100%')
          SettingsToggleRow({
            title: '保留源图形',
            isOn: this.keepSources,
            enabledState: this.depth() === 0 && !this.busy,
            compact: true,
            onToggle: (value: boolean) => { if (value !== this.keepSources) { this.keepSources = value; this.changed(); } }
          })
          if (this.contentWidth >= 480) {
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: `原始图形 · ${this.sources.length} 个来源`, shapes: this.sources, extentShapes: this.sources })
              BooleanGeometryPanel({ title: `结果图形 · ${this.outputs.length} 个结果`, shapes: this.outputs, extentShapes: this.sources })
            }.width('100%')
          } else {
            Row() { BooleanGeometryPanel({ title: `原始图形 · ${this.sources.length} 个来源`, shapes: this.sources, extentShapes: this.sources }) }.width('100%')
            Row() { BooleanGeometryPanel({ title: `结果图形 · ${this.outputs.length} 个结果`, shapes: this.outputs, extentShapes: this.sources }) }.width('100%')
          }
          if (this.status.length > 0) {
            Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      if (this.contentWidth >= 480) {
        Row({ space: 12 }) { this.CancelButton(); Blank(); this.RefreshButton(); this.ApplyButton() }
          .width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
      } else {
        Column({ space: 12 }) {
          Row({ space: 12 }) { this.CancelButton(); Blank(); this.RefreshButton() }.width('100%')
          Row() { Blank(); this.ApplyButton() }.width('100%')
        }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
      }
    }.width(700).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 760 }).padding(UI.dialogPadding).backgroundColor(COLORS.surface)
      .borderRadius(UI.dialogRadius).transition(dialogTransition()).onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
