import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { Shape } from '../../models/GdsiiData';
import { CellInfo } from './PlaceInstanceDialog';
import { GeometryNumberField } from './GeometryNumberField';
import { BooleanGeometryPanel } from './BooleanPreviewDialog';
import { CellMaintenanceRequest, CellMaintenancePreview, CellMaintenanceResult } from '../../services/CellMaintenanceService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct CellMaintenanceDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  cellsProvider: () => CellInfo[] = () => [];
  currentCellProvider: () => number = () => 0;
  dbuProvider: () => number = () => 1;
  selectedInstancesProvider: () => number[] = () => [];
  sourcesProvider: () => Shape[] = () => [];
  previewShapesProvider: (preview: CellMaintenancePreview) => Shape[] = (_preview: CellMaintenancePreview) => [];
  prepareAction: (request: CellMaintenanceRequest) => CellMaintenanceResult = (_request: CellMaintenanceRequest) => ({ ok: false, message: '' });
  applyAction: (id: string) => CellMaintenanceResult = (_id: string) => ({ ok: false, message: '' });
  cancelAction: (id?: string) => void = (_id?: string) => {};
  private openedContext: string = '';
  private preview: CellMaintenancePreview | undefined = undefined;
  @State cells: CellInfo[] = [];
  @State kindIndex: number = 0;
  @State sourceIndex: number = 0;
  @State targetIndex: number = 0;
  @State scopeIndex: number = 0;
  @State posX: string = '0';
  @State posY: string = '0';
  @State preserveIds: number[] = [];
  @State sources: Shape[] = [];
  @State outputs: Shape[] = [];
  @State removedCellNames: string[] = [];
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State status: string = '';
  @State contentWidth: number = 720;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.invalidate(); this.openedContext = this.contextProvider(); this.cells = this.cellsProvider();
    const current: number = this.cells.findIndex((cell: CellInfo): boolean => cell.id === this.currentCellProvider());
    this.sourceIndex = Math.max(0, current); this.targetIndex = this.cells.length > 1 ? (this.sourceIndex + 1) % this.cells.length : 0;
    this.kindIndex = 0; this.scopeIndex = 0; this.posX = '0'; this.posY = '0'; this.preserveIds = [];
    this.status = '';
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }
  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview.id);
    this.preview = undefined; this.ready = false; this.sources = []; this.outputs = []; this.removedCellNames = [];
  }
  private changed(): void { this.invalidate(); this.status = '参数已变化，请更新预览'; }
  private cancel(): void { if (!this.busy) { this.invalidate(); this.controller.close(); } }
  private options(): SelectOption[] { return this.cells.map((cell: CellInfo): SelectOption => ({ value: `${cell.name} (#${cell.id})` })); }
  private contextMatches(): boolean {
    try { return this.openedContext.length > 0 && this.openedContext === this.contextProvider(); } catch (_) { return false; }
  }
  private togglePreserve(id: number, checked: boolean): void {
    if (this.busy || (this.preserveIds.indexOf(id) >= 0) === checked) return;
    this.preserveIds = checked ? this.preserveIds.concat([id]) : this.preserveIds.filter((value: number): boolean => value !== id);
    this.changed();
  }
  private refresh(): void {
    if (this.busy) return; this.invalidate();
    if (!this.contextMatches()) { this.status = '文档或编辑范围已变化，请重新打开库维护'; return; }
    if (this.cells.length === 0 || this.cells[this.sourceIndex] === undefined || this.cells[this.targetIndex] === undefined) {
      this.status = '当前文档没有可用的 Cell 定义'; return;
    }
    this.busy = true;
    try {
      const dbu: number = this.dbuProvider();
      let request: CellMaintenanceRequest;
      if (this.kindIndex === 0) {
        if ([this.posX, this.posY].some((value: string): boolean => !/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(value.trim()) || !Number.isFinite(Number(value)))) { this.status = '请填写新原点的两个有限 nm 坐标'; return; }
        request = { kind: 'origin', cellId: this.cells[this.sourceIndex].id, xNm: Number(this.posX), yNm: Number(this.posY), dbuNm: dbu };
      } else if (this.kindIndex === 1) {
        request = this.scopeIndex === 0 ? { kind: 'relink', targetCellId: this.cells[this.targetIndex].id,
          instanceIds: this.selectedInstancesProvider(), dbuNm: dbu } : { kind: 'relink', targetCellId: this.cells[this.targetIndex].id,
          sourceCellId: this.cells[this.sourceIndex].id, dbuNm: dbu };
      } else request = { kind: 'prune', rootCellIds: [this.currentCellProvider()].concat(this.preserveIds), preserveCellIds: this.preserveIds.slice(), dbuNm: dbu };
      const result: CellMaintenanceResult = this.prepareAction(request); this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview; this.sources = this.sourcesProvider(); this.outputs = this.previewShapesProvider(result.preview);
        if (!this.contextMatches()) { this.invalidate(); this.status = '预览期间文档变化，请重新打开库维护'; return; }
        this.removedCellNames = result.preview.removedCellNames.slice(); this.ready = true;
        this.status = `修改 ${result.preview.changedShapes} 个对象 · 直接引用 ${result.preview.directReferences} · 放置 ${result.preview.placements} · 删除 ${result.preview.removedCellIds.length} 个 Cell。${result.preview.warnings.join('；')}`;
      }
    } catch (error) { this.invalidate(); this.status = `维护预览失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  private apply(): void {
    if (this.busy || !this.ready || this.preview === undefined) return;
    if (!this.contextMatches()) { this.invalidate(); this.status = '文档或编辑范围已变化，请重新打开库维护'; return; }
    this.busy = true;
    try {
      const result: CellMaintenanceResult = this.applyAction(this.preview.id); this.status = result.message;
      this.invalidate(); if (result.ok) this.controller.close();
    } catch (error) { this.invalidate(); this.status = `维护提交失败：${String(error)}`; }
    finally { this.busy = false; }
  }
  @Builder
  CellFields() {
    Column({ space: 8 }) {
      Text(this.kindIndex === 1 ? '来源 Cell（全库重链接）' : '选择 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Select(this.options()).selected(this.sourceIndex).value(this.options()[this.sourceIndex]?.value ?? '请选择 Cell')
        .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy && (this.kindIndex !== 1 || this.scopeIndex === 1))
        .onSelect((index: number) => { if (index !== this.sourceIndex) { this.sourceIndex = index; this.changed(); } })
    }.width('100%')
    if (this.kindIndex === 0) {
      Row({ space: 12 }) {
        GeometryNumberField({ label: '新原点 X (nm)', value: this.posX, inputAllowed: !this.busy, onValueChange: (value: string) => { this.posX = value; this.changed(); } }).layoutWeight(1)
        GeometryNumberField({ label: '新原点 Y (nm)', value: this.posY, inputAllowed: !this.busy, onValueChange: (value: string) => { this.posY = value; this.changed(); } }).layoutWeight(1)
      }.width('100%')
    } else if (this.kindIndex === 1) {
      Column({ space: 8 }) {
        Text('重链接范围').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Select([{ value: '当前选中实例' }, { value: '全库引用来源 Cell' }]).selected(this.scopeIndex).value(this.scopeIndex === 0 ? '当前选中实例' : '全库引用来源 Cell')
          .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onSelect((index: number) => { if (index !== this.scopeIndex) { this.scopeIndex = index; this.changed(); } })
        Text('目的 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Select(this.options()).selected(this.targetIndex).value(this.options()[this.targetIndex]?.value ?? '请选择 Cell')
          .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onSelect((index: number) => { if (index !== this.targetIndex) { this.targetIndex = index; this.changed(); } })
      }.width('100%')
    }
  }
  build() {
    Column({ space: 16 }) {
      Text('Cell 库维护').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Text(`当前 Cell #${this.currentCellProvider()} · DBU ${this.dbuProvider()} nm`).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          Select([{ value: '移动原点' }, { value: '重链接实例' }, { value: '清理不可达 Cell' }]).defaultFocus(true).selected(this.kindIndex)
            .value(this.kindIndex === 0 ? '移动原点' : this.kindIndex === 1 ? '重链接实例' : '清理不可达 Cell')
            .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
            .onSelect((index: number) => { if (index !== this.kindIndex) { this.kindIndex = index; this.changed(); } })
          if (this.kindIndex < 2) { this.CellFields() }
          else {
            Text('勾选需额外保留的根 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            ForEach(this.cells, (cell: CellInfo) => {
              Row({ space: 8 }) {
                Checkbox({ name: `preserve-${cell.id}` }).select(this.preserveIds.indexOf(cell.id) >= 0).enabled(!this.busy)
                  .onChange((checked: boolean) => this.togglePreserve(cell.id, checked))
                Text(`${cell.name} (#${cell.id})`).fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
              }.width('100%')
            }, (cell: CellInfo): string => `${cell.id}`)
          }
          if (this.contentWidth >= 480) {
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: `维护前 · ${this.sources.length} 个填充图形`, shapes: this.sources, extentShapes: this.sources })
              BooleanGeometryPanel({ title: this.ready ? `维护后 · ${this.outputs.length} 个填充图形` : '维护后待计算', shapes: this.outputs, extentShapes: this.sources })
            }.width('100%')
          } else {
            Row() { BooleanGeometryPanel({ title: `维护前 · ${this.sources.length} 个填充图形`, shapes: this.sources, extentShapes: this.sources }) }.width('100%')
            Row() { BooleanGeometryPanel({ title: this.ready ? `维护后 · ${this.outputs.length} 个填充图形` : '维护后待计算', shapes: this.outputs, extentShapes: this.sources }) }.width('100%')
          }
          if (this.status.length > 0) {
            Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%')
          }
          if (this.removedCellNames.length > 0) {
            Text(`将删除：${this.removedCellNames.join('、')}`).fontSize(UI.fontBody).fontColor(COLORS.danger).width('100%')
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      Flex({ direction: this.contentWidth < 480 ? FlexDirection.Column : FlexDirection.Row, justifyContent: FlexAlign.SpaceBetween }) {
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => this.cancel())
        Row({ space: 12 }) {
          Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => this.refresh())
          Button('应用维护', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).backgroundColor(COLORS.primary).fontColor(Color.White)
            .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.ready && !this.busy).onClick(() => this.apply())
        }
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(800).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 760 }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
