import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { Shape, ShapeBounds } from '../../models/GdsiiData';
import { BooleanGeometryPanel } from './BooleanPreviewDialog';
import { HierarchyClipOptions } from '../../services/HierarchyClipService';
import { HierarchyClipPreview, HierarchyClipSessionResult } from '../../services/HierarchyClipSessionService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

/** @Prop bindings keep the native input synchronized after preview refresh.
 * Passing an initial value through a parameter Builder would capture a copy. */
@Component
export struct ClipCoordinateField {
  @Prop label: string = '';
  @Prop value: string = '';
  onValueChange: (value: string) => void = (_value: string) => {};
  build() {
    Column({ space: 8 }) {
      Text(this.label).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      TextInput({ text: this.value, placeholder: 'nm' }).height(UI.fieldHeight).width('100%')
        .fontSize(UI.fontBody).fontFamily('monospace').fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .onChange((text: string) => this.onValueChange(text))
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }
}

/** Source/preview providers return actual expanded, filled geometry, including
 * native PATH outlines. The immutable commit candidate stays in the session. */
@CustomDialog
export struct HierarchyClipDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  cellNameProvider: () => string = () => '';
  sourceCellProvider: () => number = () => 0;
  dbuProvider: () => number = () => 1;
  boundsProvider: () => ShapeBounds = () => ({ minX: 0, minY: 0, maxX: 1, maxY: 1 });
  sourcesProvider: () => Shape[] = () => [];
  previewShapesProvider: (preview: HierarchyClipPreview) => Shape[] = (_preview: HierarchyClipPreview) => [];
  prepareAction: (options: HierarchyClipOptions) => HierarchyClipSessionResult = (_options: HierarchyClipOptions) => ({ ok: false, message: '' });
  applyAction: (previewId: string) => HierarchyClipSessionResult = (_previewId: string) => ({ ok: false, message: '' });
  cancelAction: (previewId?: string) => void = (_previewId?: string) => {};
  private openedContext: string = '';
  private preview: HierarchyClipPreview | undefined = undefined;
  @State outputCellName: string = '';
  @State minX: string = '0';
  @State minY: string = '0';
  @State maxX: string = '1';
  @State maxY: string = '1';
  @State textIndex: number = 0;
  @State nodeIndex: number = 0;
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State sources: Shape[] = [];
  @State outputs: Shape[] = [];
  @State status: string = '';
  @State contentWidth: number = 720;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.outputCellName = `${this.cellNameProvider().slice(0, 480)}_clip`;
    const bounds: ShapeBounds = this.boundsProvider();
    this.minX = `${bounds.minX}`; this.minY = `${bounds.minY}`;
    this.maxX = `${bounds.maxX}`; this.maxY = `${bounds.maxY}`;
    this.textIndex = 0; this.nodeIndex = 0; this.invalidate();
    this.status = '';
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }

  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview.id);
    this.preview = undefined; this.ready = false; this.sources = []; this.outputs = [];
  }

  private changed(): void { this.invalidate(); this.status = '参数已变化，请更新预览'; }

  private cancel(): void { this.invalidate(); this.controller.close(); }

  private refresh(): void {
    if (this.busy) return;
    this.invalidate();
    if (this.openedContext !== this.contextProvider()) { this.status = '文档或编辑范围已变化，请重新打开层级 Clip'; return; }
    if (!this.outputCellName.trim() || !this.minX.trim() || !this.minY.trim() || !this.maxX.trim() || !this.maxY.trim()) {
      this.status = '请填写输出 Cell 与四个裁剪坐标'; return;
    }
    this.busy = true;
    try {
      const options: HierarchyClipOptions = { sourceCellId: this.sourceCellProvider(), outputCellName: this.outputCellName.trim(),
        bounds: { minX: Number(this.minX), minY: Number(this.minY), maxX: Number(this.maxX), maxY: Number(this.maxY) },
        dbuNm: this.dbuProvider(), textPolicy: this.textIndex === 0 ? 'anchor' : 'omit', nodePolicy: this.nodeIndex === 0 ? 'all-points' : 'omit' };
      const result: HierarchyClipSessionResult = this.prepareAction(options);
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview;
        this.sources = this.sourcesProvider();
        this.outputs = this.previewShapesProvider(result.preview);
        if (this.openedContext !== this.contextProvider()) { this.invalidate(); this.status = '文档在预览期间变化，请重新打开层级 Clip'; return; }
        this.ready = true;
        this.status = `保留源 Cell 和共享引用 · 新建 ${result.preview.addedCells} 个 Cell / ${result.preview.addedShapes} 个对象 · 保留 ${result.preview.keptReferences} 条引用 · 新增 ${result.preview.addedPorts} 个端口 / 片段排除 ${result.preview.droppedPorts} 个端口 · DBU ${result.preview.dbuNm} nm。仅保留完整孔径包含的端口，源定义端口保留。`;
      }
    } catch (error) { this.invalidate(); this.status = `Clip 预览失败：${String(error)}`; }
    finally { this.busy = false; }
  }

  private apply(): void {
    if (this.busy || !this.ready || this.preview === undefined) return;
    if (this.openedContext !== this.contextProvider()) { this.invalidate(); this.status = '文档或编辑范围已变化，请重新打开层级 Clip'; return; }
    this.busy = true;
    try {
      const result: HierarchyClipSessionResult = this.applyAction(this.preview.id);
      this.status = result.message;
      if (result.ok) { this.invalidate(); this.controller.close(); } else this.invalidate();
    } catch (error) { this.invalidate(); this.status = `Clip 提交失败：${String(error)}`; }
    finally { this.busy = false; }
  }

  @Builder
  PolicyFields() {
    Column({ space: 8 }) {
      Text('TEXT').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Select([{ value: '锚点在框内' }, { value: '省略文字' }]).selected(this.textIndex).value(this.textIndex === 0 ? '锚点在框内' : '省略文字')
        .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
        .onSelect((index: number) => { if (index !== this.textIndex) { this.textIndex = index; this.changed(); } })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    Column({ space: 8 }) {
      Text('NODE').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Select([{ value: '全部点在框内' }, { value: '省略 NODE' }]).selected(this.nodeIndex).value(this.nodeIndex === 0 ? '全部点在框内' : '省略 NODE')
        .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
        .onSelect((index: number) => { if (index !== this.nodeIndex) { this.nodeIndex = index; this.changed(); } })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  CancelButton() {
    Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
      .enabled(!this.busy).onClick(() => this.cancel())
  }

  @Builder
  RefreshButton() {
    Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
      .enabled(!this.busy).onClick(() => this.refresh())
  }

  @Builder
  ApplyButton() {
    Button('创建 Cell', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
      .borderRadius(UI.controlRadius).enabled(this.ready && !this.busy).backgroundColor(COLORS.primary).fontColor(Color.White)
      .onClick(() => this.apply())
  }

  build() {
    Column({ space: 16 }) {
      Text('层级 Clip').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text(`当前 Cell ${this.cellNameProvider()} · DBU ${this.dbuProvider()} nm`).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          Column({ space: 8 }) {
            Text('输出 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.outputCellName, placeholder: '新的 Cell 名称' }).height(UI.fieldHeight).width('100%')
              .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
              .defaultFocus(true)
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((value: string) => { if (value !== this.outputCellName) { this.outputCellName = value; this.changed(); } })
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.contentWidth >= 640) {
            Row({ space: 12 }) {
              ClipCoordinateField({ label: '最小 X (nm)', value: this.minX, onValueChange: (value: string) => { if (value !== this.minX) { this.minX = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
              ClipCoordinateField({ label: '最小 Y (nm)', value: this.minY, onValueChange: (value: string) => { if (value !== this.minY) { this.minY = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
              ClipCoordinateField({ label: '最大 X (nm)', value: this.maxX, onValueChange: (value: string) => { if (value !== this.maxX) { this.maxX = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
              ClipCoordinateField({ label: '最大 Y (nm)', value: this.maxY, onValueChange: (value: string) => { if (value !== this.maxY) { this.maxY = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
            }.width('100%')
          } else {
            Row({ space: 12 }) {
              ClipCoordinateField({ label: '最小 X (nm)', value: this.minX, onValueChange: (value: string) => { if (value !== this.minX) { this.minX = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
              ClipCoordinateField({ label: '最小 Y (nm)', value: this.minY, onValueChange: (value: string) => { if (value !== this.minY) { this.minY = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
            }.width('100%')
            Row({ space: 12 }) {
              ClipCoordinateField({ label: '最大 X (nm)', value: this.maxX, onValueChange: (value: string) => { if (value !== this.maxX) { this.maxX = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
              ClipCoordinateField({ label: '最大 Y (nm)', value: this.maxY, onValueChange: (value: string) => { if (value !== this.maxY) { this.maxY = value; this.changed(); } } }).layoutWeight(1).enabled(!this.busy)
            }.width('100%')
          }
          if (this.contentWidth >= 480) {
            Row({ space: 12 }) { this.PolicyFields() }.width('100%')
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: `原始层级 · ${this.sources.length} 个填充图形`, shapes: this.sources, extentShapes: this.sources })
              BooleanGeometryPanel({ title: this.ready ? `裁剪结果 · ${this.outputs.length} 个填充图形` : '裁剪结果待计算', shapes: this.outputs, extentShapes: this.sources })
            }.width('100%')
          } else {
            Column({ space: 12 }) { this.PolicyFields() }.width('100%')
            Row() { BooleanGeometryPanel({ title: `原始层级 · ${this.sources.length} 个填充图形`, shapes: this.sources, extentShapes: this.sources }) }.width('100%')
            Row() { BooleanGeometryPanel({ title: this.ready ? `裁剪结果 · ${this.outputs.length} 个填充图形` : '裁剪结果待计算', shapes: this.outputs, extentShapes: this.sources }) }.width('100%')
          }
          if (this.status.length > 0) {
            Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      if (this.contentWidth >= 480) {
        Row({ space: 12 }) {
          this.CancelButton()
          Blank()
          this.RefreshButton()
          this.ApplyButton()
        }
          .width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
      } else {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            this.CancelButton()
            Blank()
            this.RefreshButton()
          }.width('100%')
          Row() {
            Blank()
            this.ApplyButton()
          }.width('100%')
        }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
      }
    }.width(800).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 760 }).padding(UI.dialogPadding).backgroundColor(COLORS.surface)
      .borderRadius(UI.dialogRadius).transition(dialogTransition()).onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
