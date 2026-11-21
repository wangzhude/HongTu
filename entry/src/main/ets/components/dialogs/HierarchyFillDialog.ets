import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { Shape, ShapeBounds, Point } from '../../models/GdsiiData';
import { CellInfo } from './PlaceInstanceDialog';
import { GeometryNumberField } from './GeometryNumberField';
import { BooleanGeometryPanel } from './BooleanPreviewDialog';
import { HierarchyFillOptions, HierarchyFillLayer, HierarchyFillFootprintResult } from '../../services/HierarchyFillService';
import { HierarchyFillPreview, HierarchyFillSessionResult } from '../../services/HierarchyFillSessionService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct HierarchyFillDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  cellsProvider: () => CellInfo[] = () => [];
  currentCellProvider: () => number = () => 0;
  dbuProvider: () => number = () => 1;
  layerProvider: () => number[] = () => [1, 0];
  boundsProvider: () => ShapeBounds = () => ({ minX: 0, minY: 0, maxX: 1, maxY: 1 });
  selectedAreaProvider: () => number[] = () => [];
  footprintProvider: (id: number) => HierarchyFillFootprintResult = (_id: number) => ({ ok: false, message: '' });
  areaPreviewProvider: (options: HierarchyFillOptions) => Shape[] = (_options: HierarchyFillOptions) => [];
  previewShapesProvider: (preview: HierarchyFillPreview) => Shape[] = (_preview: HierarchyFillPreview) => [];
  prepareAction: (options: HierarchyFillOptions) => HierarchyFillSessionResult = (_options: HierarchyFillOptions) => ({ ok: false, message: '' });
  applyAction: (id: string) => HierarchyFillSessionResult = (_id: string) => ({ ok: false, message: '' });
  cancelAction: (id?: string) => void = (_id?: string) => {};
  private openedContext: string = '';
  private preview: HierarchyFillPreview | undefined = undefined;
  @State cells: CellInfo[] = [];
  @State fillIndex: number = 0;
  @State areaIndex: number = 0;
  @State excludeIndex: number = 1;
  @State minX: string = '0';
  @State minY: string = '0';
  @State maxX: string = '1';
  @State maxY: string = '1';
  @State originX: string = '0';
  @State originY: string = '0';
  @State columnX: string = '1';
  @State columnY: string = '0';
  @State rowX: string = '0';
  @State rowY: string = '1';
  @State regionMargin: string = '0';
  @State spacing: string = '0';
  @State layer: string = '1';
  @State datatype: string = '0';
  @State excludeLayers: string = '1/0';
  @State sources: Shape[] = [];
  @State outputs: Shape[] = [];
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State status: string = '';
  @State contentWidth: number = 720;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.invalidate(); this.openedContext = this.contextProvider();
    this.cells = this.cellsProvider().filter((cell: CellInfo): boolean => cell.id !== this.currentCellProvider()); this.fillIndex = 0;
    const bounds: ShapeBounds = this.boundsProvider(); const layer: number[] = this.layerProvider();
    this.minX = `${bounds.minX}`; this.minY = `${bounds.minY}`; this.maxX = `${bounds.maxX}`; this.maxY = `${bounds.maxY}`;
    this.originX = this.minX; this.originY = this.minY; this.areaIndex = 0; this.excludeIndex = 1;
    this.regionMargin = '0'; this.spacing = '0'; this.columnY = '0'; this.rowX = '0';
    this.layer = `${layer[0]}`; this.datatype = `${layer[1]}`; this.excludeLayers = `${layer[0]}/${layer[1]}`;
    this.setFillDefaults();
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }
  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview.id);
    this.preview = undefined; this.ready = false; this.sources = []; this.outputs = [];
  }
  private changed(): void { this.invalidate(); this.status = '参数已变化，请更新预览'; }
  private cancel(): void { if (!this.busy) { this.invalidate(); this.controller.close(); } }
  private contextMatches(): boolean {
    try { return this.openedContext.length > 0 && this.openedContext === this.contextProvider(); } catch (_) { return false; }
  }
  private setFillDefaults(): void {
    this.changed();
    if (this.cells[this.fillIndex] === undefined) { this.status = '请先创建或导入一个独立的面积填充 Cell'; return; }
    try {
      const result: HierarchyFillFootprintResult = this.footprintProvider(this.cells[this.fillIndex].id);
      if (!result.ok || result.footprint === undefined) { this.status = result.message; return; }
      const dbu: number = this.dbuProvider();
      this.columnX = `${result.footprint.maxX - result.footprint.minX + dbu}`;
      this.rowY = `${result.footprint.maxY - result.footprint.minY + dbu}`;
      this.columnY = '0'; this.rowX = '0';
      this.status = `填充包络 ${result.footprint.minX},${result.footprint.minY} — ${result.footprint.maxX},${result.footprint.maxY} nm`;
    } catch (error) { this.status = `填充 Cell 检查失败：${String(error)}`; }
  }
  private options(): HierarchyFillOptions {
    const fields: string[] = [this.originX, this.originY, this.columnX, this.columnY, this.rowX, this.rowY, this.regionMargin, this.spacing, this.layer, this.datatype];
    if (fields.some((field: string): boolean => !/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(field.trim()) || !Number.isFinite(Number(field)))) throw new Error('排列、边距和实例用途必须填写完整有限数值');
    if (this.cells[this.fillIndex] === undefined) throw new Error('请选择独立的面积填充 Cell');
    const layers: HierarchyFillLayer[] = [];
    if (this.excludeIndex === 2) {
      const values: string[] = this.excludeLayers.trim().split(/[,，;；\s]+/);
      for (const value of values) {
        if (!/^\d+\/\d+$/.test(value)) throw new Error('避让用途按 layer/datatype 填写，多个用途以逗号分隔');
        const pair: string[] = value.split('/'); layers.push({ layerNumber: Number(pair[0]), datatype: Number(pair[1]) });
      }
    }
    const options: HierarchyFillOptions = { targetCellId: this.currentCellProvider(), fillCellId: this.cells[this.fillIndex].id, dbuNm: this.dbuProvider(),
      origin: { x: Number(this.originX), y: Number(this.originY) }, columnStep: { x: Number(this.columnX), y: Number(this.columnY) },
      rowStep: { x: Number(this.rowX), y: Number(this.rowY) }, regionMarginNm: Number(this.regionMargin), excludeSpacingNm: Number(this.spacing),
      excludeMode: this.excludeIndex === 0 ? 'none' : this.excludeIndex === 1 ? 'all' : 'layers', excludeLayers: layers,
      instanceLayer: Number(this.layer), instanceDatatype: Number(this.datatype) };
    if (this.areaIndex === 0) {
      const coordinates: string[] = [this.minX, this.minY, this.maxX, this.maxY];
      if (coordinates.some((field: string): boolean => !/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(field.trim()) || !Number.isFinite(Number(field)))) throw new Error('请填写四个有限 nm 区域坐标');
      const x0: number = Number(this.minX), y0: number = Number(this.minY), x1: number = Number(this.maxX), y1: number = Number(this.maxY);
      if (x1 <= x0 || y1 <= y0) throw new Error('最大坐标必须大于最小坐标');
      const ring: Point[] = [{ x: x0, y: y0 }, { x: x1, y: y0 }, { x: x1, y: y1 }, { x: x0, y: y1 }];
      options.areaPolygons = [ring];
    } else options.areaShapeIds = this.selectedAreaProvider();
    return options;
  }
  private refresh(): void {
    if (this.busy) return; this.invalidate();
    if (!this.contextMatches()) { this.status = '文档或编辑范围已变化，请重新打开 Fill'; return; }
    this.busy = true;
    try {
      const options: HierarchyFillOptions = this.options(); const result: HierarchyFillSessionResult = this.prepareAction(options);
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview; this.sources = this.areaPreviewProvider(options); this.outputs = this.previewShapesProvider(result.preview);
        if (!this.contextMatches()) { this.invalidate(); this.status = '预览期间文档变化，请重新打开 Fill'; return; }
        this.ready = true;
        this.status = `预览 ${result.preview.placedInstances} 个实例 / ${result.preview.addedShapes} 个引用对象 · 候选 ${result.preview.consideredCandidates} · 区域外 ${result.preview.rejectedOutside} · 避让 ${result.preview.rejectedExcluded} · 相互重叠 ${result.preview.rejectedOverlap} · 安全避让 ${result.preview.conservativeExclusionCount}`;
        if (result.preview.placedInstances < 1) this.status += ' · 没有可放置实例，请调整区域、排列或避让设置';
      }
    } catch (error) { this.invalidate(); this.status = `Fill 预览失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  private canApply(): boolean {
    return this.ready && !this.busy && this.preview !== undefined && this.preview.placedInstances > 0;
  }
  private apply(): void {
    if (this.busy || !this.ready || this.preview === undefined) return;
    if (!this.contextMatches()) { this.invalidate(); this.status = '文档或编辑范围已变化，请重新打开 Fill'; return; }
    if (!this.canApply()) return;
    this.busy = true;
    try {
      const result: HierarchyFillSessionResult = this.applyAction(this.preview.id); this.status = result.message;
      this.invalidate(); if (result.ok) this.controller.close();
    } catch (error) { this.invalidate(); this.status = `Fill 提交失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  @Builder
  AreaFields() {
    Row({ space: 12 }) {
      GeometryNumberField({ label: '最小 X (nm)', value: this.minX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.minX = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '最小 Y (nm)', value: this.minY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.minY = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
    Row({ space: 12 }) {
      GeometryNumberField({ label: '最大 X (nm)', value: this.maxX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.maxX = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '最大 Y (nm)', value: this.maxY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.maxY = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
  }
  @Builder
  ArrangementFields() {
    Row({ space: 12 }) {
      GeometryNumberField({ label: '起点 X (nm)', value: this.originX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.originX = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '起点 Y (nm)', value: this.originY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.originY = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
    Row({ space: 12 }) {
      GeometryNumberField({ label: '列向量 X (nm)', value: this.columnX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.columnX = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '列向量 Y (nm)', value: this.columnY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.columnY = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
    Row({ space: 12 }) {
      GeometryNumberField({ label: '行向量 X (nm)', value: this.rowX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.rowX = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '行向量 Y (nm)', value: this.rowY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.rowY = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
    Row({ space: 12 }) {
      GeometryNumberField({ label: '边界余量 (nm)', value: this.regionMargin, inputAllowed: !this.busy, onValueChange: (value: string) => { this.regionMargin = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '避让间距 (nm)', value: this.spacing, inputAllowed: !this.busy, onValueChange: (value: string) => { this.spacing = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
    Row({ space: 12 }) {
      GeometryNumberField({ label: '实例 layer', value: this.layer, inputAllowed: !this.busy, onValueChange: (value: string) => { this.layer = value; this.changed(); } }).layoutWeight(1)
      GeometryNumberField({ label: '实例 datatype', value: this.datatype, inputAllowed: !this.busy, onValueChange: (value: string) => { this.datatype = value; this.changed(); } }).layoutWeight(1)
    }.width('100%')
  }
  build() {
    Column({ space: 16 }) {
      Text('区域 Fill').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text(`当前 Cell #${this.currentCellProvider()} · DBU ${this.dbuProvider()} nm`).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          Text('填充 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          Select(this.cells.map((cell: CellInfo): SelectOption => ({ value: cell.name }))).selected(this.fillIndex).value(this.cells[this.fillIndex]?.name ?? '请先创建独立的面积 Cell')
            .defaultFocus(true).height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy && this.cells.length > 0)
            .onSelect((index: number) => { if (index !== this.fillIndex) { this.fillIndex = index; this.setFillDefaults(); } })
          Text('区域').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          Select([{ value: '矩形范围' }, { value: '当前选中区域（直接面积对象）' }]).selected(this.areaIndex).value(this.areaIndex === 0 ? '矩形范围' : '当前选中区域（直接面积对象）')
            .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
            .onSelect((index: number) => { if (index !== this.areaIndex) { this.areaIndex = index; this.changed(); } })
          if (this.areaIndex === 0) { this.AreaFields() }
          Text('排列').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
          this.ArrangementFields()
          Text('避让范围').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          Select([{ value: '不避让已有材料' }, { value: '避让全部已有材料' }, { value: '避让指定 layer/datatype' }]).selected(this.excludeIndex)
            .value(this.excludeIndex === 0 ? '不避让已有材料' : this.excludeIndex === 1 ? '避让全部已有材料' : '避让指定 layer/datatype')
            .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
            .onSelect((index: number) => { if (index !== this.excludeIndex) { this.excludeIndex = index; this.changed(); } })
          if (this.excludeIndex === 2) {
            Text('避让用途（例如 1/0,2/0）').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.excludeLayers, placeholder: '1/0,2/0' }).height(UI.fieldHeight).width('100%')
              .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
              .onFocus(() => { resetModifierKeys(); }).onKeyEvent((event: KeyEvent) => { event.stopPropagation(); }).onChange((value: string) => { if (value !== this.excludeLayers) { this.excludeLayers = value; this.changed(); } })
          }
          if (this.contentWidth >= 480) {
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: '目标区域', shapes: this.sources, extentShapes: this.sources })
              BooleanGeometryPanel({ title: this.ready ? `填充后材料（含原有） · ${this.outputs.length} 个图形` : '填充结果待计算', shapes: this.outputs, extentShapes: this.sources })
            }.width('100%')
          } else {
            Row() { BooleanGeometryPanel({ title: '目标区域', shapes: this.sources, extentShapes: this.sources }) }.width('100%')
            Row() { BooleanGeometryPanel({ title: this.ready ? `填充后材料（含原有） · ${this.outputs.length} 个图形` : '填充结果待计算', shapes: this.outputs, extentShapes: this.sources }) }.width('100%')
          }
          if (this.status.length > 0) {
            Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      Flex({ direction: this.contentWidth < 480 ? FlexDirection.Column : FlexDirection.Row, justifyContent: FlexAlign.SpaceBetween }) {
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .enabled(!this.busy).onClick(() => this.cancel())
        Row({ space: 12 }) {
          Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .enabled(!this.busy).onClick(() => this.refresh())
          Button('应用 Fill', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).backgroundColor(COLORS.primary).fontColor(Color.White)
            .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).enabled(this.canApply()).onClick(() => this.apply())
        }
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(800).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 760 }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
