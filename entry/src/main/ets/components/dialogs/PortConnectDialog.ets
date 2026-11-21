import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { PortEndpoint, ResolvedPort } from '../../models/LayoutPort';
import { PortRequest, PortPreview, PortResult } from '../../services/PortService';
import { GeometryNumberField } from './GeometryNumberField';
import { PortGeometryPanel, PortUiChoice } from './PortGeometryPanel';
import { PortChoiceQuery } from '../../models/PortUiChoice';
import { clonePortEndpointModel, cloneStructured } from '../../common/CloneUtils';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct PortConnectDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  contextProvider: () => string = () => '';
  choicesProvider: (options?: PortChoiceQuery) => PortUiChoice[] = (_options?: PortChoiceQuery) => [];
  scopeNoticeProvider: () => string = () => '';
  resolveAction: (endpoint: PortEndpoint) => ResolvedPort = (_endpoint: PortEndpoint) => { throw new Error('端口未就绪'); };
  previewPortsProvider: (preview: PortPreview) => ResolvedPort[] = (_preview: PortPreview) => [];
  prepareAction: (request: PortRequest) => PortResult = (_request: PortRequest) => ({ ok: false, message: '' });
  applyAction: (id: string) => PortResult = (_id: string) => ({ ok: false, message: '' });
  cancelAction: (id?: string) => void = (_id?: string) => {};
  private openedContext: string = '';
  private preview: PortPreview | undefined = undefined;
  @State movingChoices: PortUiChoice[] = [];
  @State targetChoices: PortUiChoice[] = [];
  @State movingQuery: string = '';
  @State targetQuery: string = '';
  private movingNotice: string = '';
  private targetNotice: string = '';
  @State movingIndex: number = 0;
  @State targetIndex: number = 0;
  @State movingRow: string = '0';
  @State movingCol: string = '0';
  @State targetRow: string = '0';
  @State targetCol: string = '0';
  @State overlapText: string = '0';
  @State sourcePorts: ResolvedPort[] = [];
  @State outputPorts: ResolvedPort[] = [];
  @State compatibilityText: string = '请选择移动端口和目标端口';
  @State transformText: string = '';
  @State status: string = '';
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State contentWidth: number = 740;
  @State scopeNotice: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.invalidate(); this.openedContext = this.contextProvider(); this.movingQuery = ''; this.targetQuery = '';
    this.movingChoices = this.choicesProvider({ scope: 'instance', query: this.movingQuery }); this.movingNotice = this.scopeNoticeProvider();
    this.targetChoices = this.choicesProvider({ scope: 'all', query: this.targetQuery }); this.targetNotice = this.scopeNoticeProvider();
    this.scopeNotice = [this.movingNotice, this.targetNotice].filter((notice: string): boolean => !!notice).join('；');
    this.movingIndex = 0; this.targetIndex = Math.max(0, this.targetChoices.findIndex((choice: PortUiChoice): boolean => choice.endpoint.path.length === 0));
    this.overlapText = '0'; this.pickMoving(0); this.pickTarget(this.targetIndex);
    this.status = this.movingChoices.length === 0 ? '当前 Cell 暂无含端口的实例' : '';
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0; this.invalidate(); }
  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview.id);
    this.preview = undefined; this.ready = false; this.outputPorts = []; this.transformText = '';
  }
  private changed(): void { this.invalidate(); this.status = '端点或参数已变化，请更新预览'; this.showComparison(); }
  private changeMovingQuery(value: string): void {
    if (this.busy) return; this.invalidate(); this.movingQuery = value;
    try { this.movingChoices = this.choicesProvider({ scope: 'instance', query: value }); this.movingNotice = this.scopeNoticeProvider(); }
    catch (error) { this.movingChoices = []; this.movingNotice = `移动端口检索失败：${String(error)}`; }
    this.scopeNotice = [this.movingNotice, this.targetNotice].filter((notice: string): boolean => !!notice).join('；'); this.pickMoving(0);
  }
  private changeTargetQuery(value: string): void {
    if (this.busy) return; this.invalidate(); this.targetQuery = value;
    try { this.targetChoices = this.choicesProvider({ scope: 'all', query: value }); this.targetNotice = this.scopeNoticeProvider(); }
    catch (error) { this.targetChoices = []; this.targetNotice = `目标端口检索失败：${String(error)}`; }
    this.scopeNotice = [this.movingNotice, this.targetNotice].filter((notice: string): boolean => !!notice).join('；'); this.pickTarget(0);
  }
  private matches(): boolean { try { return this.openedContext.length > 0 && this.openedContext === this.contextProvider(); } catch (_) { return false; } }
  private pickMoving(index: number): void {
    this.movingIndex = index; const path = this.movingChoices[index]?.endpoint.path;
    this.movingRow = `${path !== undefined && path.length > 0 ? path[path.length - 1].row : 0}`;
    this.movingCol = `${path !== undefined && path.length > 0 ? path[path.length - 1].col : 0}`; this.changed();
  }
  private pickTarget(index: number): void {
    this.targetIndex = index; const path = this.targetChoices[index]?.endpoint.path;
    this.targetRow = `${path !== undefined && path.length > 0 ? path[path.length - 1].row : 0}`;
    this.targetCol = `${path !== undefined && path.length > 0 ? path[path.length - 1].col : 0}`; this.changed();
  }
  private endpoint(choice: PortUiChoice | undefined, row: string, col: string): PortEndpoint {
    if (choice === undefined) throw new Error('请选择两个实际端口');
    const endpoint: PortEndpoint = clonePortEndpointModel(choice.endpoint) as PortEndpoint;
    if (endpoint.path.length > 0) {
      if (!/^\d+$/.test(row.trim()) || !/^\d+$/.test(col.trim()) || !Number.isSafeInteger(Number(row)) || !Number.isSafeInteger(Number(col))) throw new Error('阵列行列须为从零开始的整数');
      endpoint.path[endpoint.path.length - 1].row = Number(row); endpoint.path[endpoint.path.length - 1].col = Number(col);
    }
    return endpoint;
  }
  private moving(): PortEndpoint { return this.endpoint(this.movingChoices[this.movingIndex], this.movingRow, this.movingCol); }
  private target(): PortEndpoint { return this.endpoint(this.targetChoices[this.targetIndex], this.targetRow, this.targetCol); }
  private showComparison(): void {
    this.sourcePorts = [];
    try {
      const moving: ResolvedPort = this.resolveAction(this.moving()), target: ResolvedPort = this.resolveAction(this.target());
      this.sourcePorts = [moving, target];
      this.compatibilityText = `移动 ${moving.definition.name}: ${moving.effectiveWidthNm} nm · ${moving.definition.portType} · L${moving.definition.layerNumber}/D${moving.definition.datatype}\n目标 ${target.definition.name}: ${target.effectiveWidthNm} nm · ${target.definition.portType} · L${target.definition.layerNumber}/D${target.definition.datatype}`;
    } catch (error) { this.compatibilityText = String(error); }
  }
  private refresh(): void {
    if (this.busy) return; this.invalidate();
    if (!this.matches()) { this.status = '文档或选区已变化，请重新打开端口连接对齐'; return; }
    this.busy = true;
    try {
      if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(this.overlapText.trim()) || !Number.isFinite(Number(this.overlapText))) throw new Error('请填写有限的重叠量');
      const moving: PortEndpoint = this.moving(), target: PortEndpoint = this.target();
      this.sourcePorts = [this.resolveAction(moving), this.resolveAction(target)];
      const result: PortResult = this.prepareAction({ kind: 'connect', moving: moving, target: target, overlapNm: Number(this.overlapText) });
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview; this.outputPorts = this.previewPortsProvider(result.preview);
        if (!this.matches()) { this.invalidate(); this.status = '预览期间文档变化，请重新打开连接对齐'; return; }
        if (this.outputPorts.length !== 2) throw new Error('候选端点预览不完整');
        const before: ResolvedPort = this.sourcePorts[0], after: ResolvedPort = this.outputPorts[0];
        const delta: number = ((after.orientationDeg - before.orientationDeg + 540) % 360) - 180;
        this.transformText = `端点 ΔX ${after.centerNm.x - before.centerNm.x} nm · ΔY ${after.centerNm.y - before.centerNm.y} nm · 方向变化 ${delta}°`;
        this.ready = true;
      }
    } catch (error) { this.invalidate(); this.status = `连接未预览：${String(error)}`; }
    finally { this.busy = false; }
  }
  private apply(): void {
    if (this.busy || !this.ready || this.preview === undefined) return;
    if (!this.matches()) { this.invalidate(); this.status = '文档或选区已变化，请重新打开连接对齐'; return; }
    this.busy = true;
    try { const result: PortResult = this.applyAction(this.preview.id); this.status = result.message; this.invalidate(); if (result.ok) this.controller.close(); }
    catch (error) { this.invalidate(); this.status = `连接未应用：${String(error)}`; }
    finally { this.busy = false; }
  }
  @Builder
  EndpointFields() {
    Column({ space: 10 }) {
      Text('移动端口').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Search({ value: this.movingQuery, placeholder: '搜索移动端口名称或 ID' })
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .width('100%').height(UI.fieldHeight).textFont({ size: UI.fontBody }).placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((value: string) => this.changeMovingQuery(value))
      Select(this.movingChoices.map((choice: PortUiChoice): SelectOption => ({ value: choice.label }))).selected(this.movingIndex)
        .value(this.movingChoices[this.movingIndex]?.label ?? '没有实例端口').height(UI.fieldHeight).width('100%').font({ size: UI.fontBody })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
        .onSelect((index: number) => { if (index !== this.movingIndex) this.pickMoving(index); })
      Row({ space: 10 }) {
        GeometryNumberField({ label: '移动阵列行（从 0 开始）', value: this.movingRow, inputAllowed: !this.busy, onValueChange: (value: string) => { this.movingRow = value; this.changed(); } }).layoutWeight(1)
        GeometryNumberField({ label: '移动阵列列（从 0 开始）', value: this.movingCol, inputAllowed: !this.busy, onValueChange: (value: string) => { this.movingCol = value; this.changed(); } }).layoutWeight(1)
      }.width('100%')
      Text('目标端口').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Search({ value: this.targetQuery, placeholder: '搜索目标端口名称或 ID' })
        .onFocus(() => { resetModifierKeys(); })
        .width('100%').height(UI.fieldHeight).textFont({ size: UI.fontBody }).placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((value: string) => this.changeTargetQuery(value))
      Select(this.targetChoices.map((choice: PortUiChoice): SelectOption => ({ value: choice.label }))).selected(this.targetIndex)
        .value(this.targetChoices[this.targetIndex]?.label ?? '没有目标端口').height(UI.fieldHeight).width('100%').font({ size: UI.fontBody })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
        .onSelect((index: number) => { if (index !== this.targetIndex) this.pickTarget(index); })
      Row({ space: 10 }) {
        GeometryNumberField({ label: '目标阵列行（从 0 开始）', value: this.targetRow, inputAllowed: !this.busy && (this.targetChoices[this.targetIndex]?.endpoint.path.length ?? 0) > 0, onValueChange: (value: string) => { this.targetRow = value; this.changed(); } }).layoutWeight(1)
        GeometryNumberField({ label: '目标阵列列（从 0 开始）', value: this.targetCol, inputAllowed: !this.busy && (this.targetChoices[this.targetIndex]?.endpoint.path.length ?? 0) > 0, onValueChange: (value: string) => { this.targetCol = value; this.changed(); } }).layoutWeight(1)
      }.width('100%')
      GeometryNumberField({ label: '沿目标外方向的重叠量 (nm)', value: this.overlapText, inputAllowed: !this.busy, onValueChange: (value: string) => { this.overlapText = value; this.changed(); } })
      Text(this.compatibilityText).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({ space: 16 }) {
      Text('端口连接对齐').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          this.EndpointFields()
          if (this.contentWidth >= 580) {
            Row({ space: 12 }) {
              Column() { PortGeometryPanel({ title: '对齐前', ports: this.sourcePorts, extentPorts: this.sourcePorts.concat(this.outputPorts) }) }.layoutWeight(1)
              Column() { PortGeometryPanel({ title: this.ready ? '对齐后' : '对齐后待计算', ports: this.outputPorts, extentPorts: this.sourcePorts.concat(this.outputPorts) }) }.layoutWeight(1)
            }.width('100%')
          } else {
            PortGeometryPanel({ title: '对齐前', ports: this.sourcePorts, extentPorts: this.sourcePorts.concat(this.outputPorts) })
            PortGeometryPanel({ title: this.ready ? '对齐后' : '对齐后待计算', ports: this.outputPorts, extentPorts: this.sourcePorts.concat(this.outputPorts) })
          }
          if (this.transformText.length > 0) { Text(this.transformText).fontSize(UI.fontCaption).fontColor(COLORS.ink).width('100%') }
          if (this.status.length > 0) { Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%') }
          if (this.scopeNotice.length > 0) { Text(this.scopeNotice).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%') }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => { this.invalidate(); this.controller.close(); })
        Blank()
        Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && this.movingChoices.length > 0 && this.targetChoices.length > 0).onClick(() => this.refresh())
        Button('应用对齐', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(Color.White)
          .backgroundColor(COLORS.primary).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.ready && !this.busy).onClick(() => this.apply())
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(820).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 820 }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
