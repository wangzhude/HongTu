import { hongTuThemeState } from '../../store/ThemeStore';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { StableSegmentButton } from '../StableSegmentButton';
import { PanelHeading } from '../workbench/PanelHeading';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { LayoutPort, LayoutPortDraft, ResolvedPort, PortEndpoint, portDraft } from '../../models/LayoutPort';
import { PortRequest, PortResult, PortPreview } from '../../services/PortService';
import { GeometryNumberField } from './GeometryNumberField';
import { PortGeometryPanel, PortUiChoice } from './PortGeometryPanel';
import { PortChoiceQuery } from '../../models/PortUiChoice';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

const PRESET_PORT_TYPES: string[] = ['electrical', 'optical', 'rf'];

@CustomDialog
export struct PortManagerDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  private autoPreviewTimer: number = -1;
  contextProvider: () => string = () => '';
  cellNameProvider: () => string = () => '';
  currentCellProvider: () => number = () => 0;
  choicesProvider: (options?: PortChoiceQuery) => PortUiChoice[] = (_options?: PortChoiceQuery) => [];
  scopeNoticeProvider: () => string = () => '';
  initialEndpointProvider: () => PortEndpoint | undefined = () => undefined;
  previewPortsProvider: (preview: PortPreview) => ResolvedPort[] = (_preview: PortPreview) => [];
  prepareAction: (request: PortRequest) => PortResult = (_request: PortRequest) => ({ ok: false, message: '' });
  applyAction: (id: string) => PortResult = (_id: string) => ({ ok: false, message: '' });
  cancelAction: (id?: string) => void = (_id?: string) => {};
  private openedContext: string = '';
  private preview: PortPreview | undefined = undefined;
  private selected: PortUiChoice | undefined = undefined;
  private pendingKind: string = 'edit';
  @State choices: PortUiChoice[] = [];
  @State query: string = '';
  @State portScopeIndex: number = 0;
  @State selectedKey: string = '';
  @State nameText: string = 'port';
  @State typeText: string = 'electrical';
  @State centerX: string = '0';
  @State centerY: string = '0';
  @State angleText: string = '0';
  @State widthText: string = '100';
  @State layerText: string = '1';
  @State datatypeText: string = '0';
  @State magText: string = '1';
  @State mirrorIndex: number = 0;
  @State infoText: string = '{}';
  @State crossSectionText: string = '无 CrossSection';
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State status: string = '';
  @State previewPorts: ResolvedPort[] = [];
  @State sourcePorts: ResolvedPort[] = [];
  @State contentWidth: number = 760;
  @State scopeNotice: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.invalidate();
    this.openedContext = this.contextProvider();
    const initial: PortEndpoint | undefined = this.initialEndpointProvider();
    this.choices = this.choicesProvider({ scope: 'all', preferredEndpoint: initial });
    this.scopeNotice = this.scopeNoticeProvider();
    this.query = '';
    this.portScopeIndex = 0;
    this.newPort(false);
    this.status = '';
    if (initial !== undefined) {
      const choice: PortUiChoice | undefined = this.choices.find((item: PortUiChoice): boolean =>
        item.endpoint.portId === initial.portId &&
        item.endpoint.rootCellKey === initial.rootCellKey &&
        JSON.stringify(item.endpoint.path.map((step) => [step.instanceId, step.row, step.col])) ===
        JSON.stringify(initial.path.map((step) => [step.instanceId, step.row, step.col]))
      );
      if (choice !== undefined) {
        this.portScopeIndex = choice.endpoint.path.length > 0 ? 1 : 0;
        this.choose(choice);
        return;
      }
    }
    this.scheduleAutoPreview();
  }

  aboutToDisappear(): void {
    if (this.autoPreviewTimer >= 0) {
      clearTimeout(this.autoPreviewTimer);
      this.autoPreviewTimer = -1;
    }
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
    this.invalidate();
  }

  private invalidate(): void {
    if (this.preview !== undefined) this.cancelAction(this.preview.id);
    this.preview = undefined;
    this.ready = false;
    this.previewPorts = [];
  }

  private scheduleAutoPreview(): void {
    if (this.autoPreviewTimer >= 0) {
      clearTimeout(this.autoPreviewTimer);
      this.autoPreviewTimer = -1;
    }
    if (this.portScopeIndex !== 0) return;
    this.autoPreviewTimer = setTimeout(() => {
      this.autoPreviewTimer = -1;
      if (!this.busy && this.portScopeIndex === 0) {
        this.refresh('edit');
      }
    }, 120);
  }

  private changed(): void {
    this.pendingKind = 'edit';
    this.invalidate();
    this.scheduleAutoPreview();
  }

  private matches(): boolean {
    try { return this.openedContext.length > 0 && this.openedContext === this.contextProvider(); } catch (_) { return false; }
  }

  private newPort(autoPrecheck: boolean = true): void {
    this.selected = undefined;
    this.selectedKey = '';
    this.pendingKind = 'edit';
    this.nameText = 'port';
    this.typeText = 'electrical';
    this.centerX = '0';
    this.centerY = '0';
    this.angleText = '0';
    this.widthText = '100';
    this.layerText = '1';
    this.datatypeText = '0';
    this.magText = '1';
    this.mirrorIndex = 0;
    this.infoText = '{}';
    this.crossSectionText = '无 CrossSection';
    this.sourcePorts = [];
    this.invalidate();
    if (autoPrecheck) {
      this.scheduleAutoPreview();
    }
  }

  private list(): PortUiChoice[] {
    return this.choices.filter((choice: PortUiChoice): boolean => (choice.endpoint.path.length > 0) === (this.portScopeIndex === 1));
  }

  private reloadChoices(): void {
    try {
      this.choices = this.choicesProvider({ scope: this.portScopeIndex === 1 ? 'instance' : 'definition', query: this.query });
      this.scopeNotice = this.scopeNoticeProvider();
    } catch (error) { this.choices = []; this.status = `端口检索失败：${String(error)}`; }
  }

  private changeQuery(value: string): void {
    if (this.busy) return;
    this.query = value;
    this.newPort(this.portScopeIndex === 0);
    this.reloadChoices();
  }

  private changeScope(index: number): void {
    if (this.busy || index === this.portScopeIndex) return;
    this.portScopeIndex = index;
    this.newPort(index === 0);
    this.reloadChoices();
    if (index === 1) {
      this.status = '选择左侧实例端口后，可一键复制到当前 Cell 形成独立定义';
    }
  }

  private choose(choice: PortUiChoice): void {
    this.invalidate();
    this.selected = choice;
    this.selectedKey = choice.label;
    this.pendingKind = 'edit';
    const port: LayoutPort = choice.resolved.definition;
    this.nameText = port.name;
    this.typeText = port.portType;
    this.centerX = `${choice.resolved.centerNm.x}`;
    this.centerY = `${choice.resolved.centerNm.y}`;
    this.angleText = `${choice.resolved.orientationDeg}`;
    this.widthText = `${port.widthNm}`;
    this.layerText = `${port.layerNumber}`;
    this.datatypeText = `${port.datatype}`;
    this.magText = `${choice.resolved.frameMagnification}`;
    this.mirrorIndex = choice.resolved.frameMirror ? 1 : 0;
    this.infoText = port.infoJson;
    this.crossSectionText = port.crossSectionKey === undefined ? '无 CrossSection' : `${port.crossSectionKey} · v${port.crossSectionVersion}`;
    this.sourcePorts = [choice.resolved];
    if (choice.endpoint.path.length > 0) {
      this.status = '实例端口按真实路径投影；点击左侧「从实例复制」可复制到当前 Cell';
    } else {
      this.scheduleAutoPreview();
    }
  }

  private portTypeSegmentIndex(): number {
    const idx: number = PRESET_PORT_TYPES.indexOf(this.typeText.trim().toLowerCase());
    return idx >= 0 ? idx : 0;
  }

  private draft(): LayoutPortDraft {
    for (const value of [this.centerX, this.centerY, this.angleText, this.widthText, this.layerText, this.datatypeText, this.magText]) {
      if (!/^[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?$/.test(value.trim()) || !Number.isFinite(Number(value))) throw new Error('请填写有限的端口数值');
    }
    if (Number(this.widthText) <= 0) throw new Error('固有宽度必须大于0 nm');
    const original: LayoutPortDraft | undefined = this.selected === undefined ? undefined : portDraft(this.selected.resolved.definition);
    return {
      name: this.nameText.trim(),
      portType: this.typeText.trim(),
      centerNm: { x: Number(this.centerX), y: Number(this.centerY) },
      orientationDeg: Number(this.angleText),
      widthNm: Number(this.widthText),
      layerNumber: Number(this.layerText),
      datatype: Number(this.datatypeText),
      frameMirror: this.mirrorIndex === 1,
      frameMagnification: Number(this.magText),
      infoJson: this.infoText,
      crossSectionKey: original?.crossSectionKey,
      crossSectionVersion: original?.crossSectionVersion,
      provenance: original?.provenance
    };
  }

  private refresh(kind: string = 'edit'): void {
    if (this.busy) return;
    if (this.autoPreviewTimer >= 0) {
      clearTimeout(this.autoPreviewTimer);
      this.autoPreviewTimer = -1;
    }
    this.invalidate();
    if (!this.matches()) { this.status = '文档或选区已改变，请重新打开端口管理'; return; }
    this.busy = true;
    this.pendingKind = kind;
    try {
      let request: PortRequest;
      if (kind === 'remove') {
        if (this.selected === undefined || this.selected.endpoint.path.length > 0) throw new Error('只能删除当前 Cell 的定义端口');
        request = { kind: 'remove', portId: this.selected.endpoint.portId };
      } else if (kind === 'copy') {
        if (this.selected === undefined || this.selected.endpoint.path.length === 0) throw new Error('请选择一个具体实例端口');
        request = { kind: 'copy', endpoint: this.selected.endpoint, name: this.nameText.trim() };
      } else {
        if (this.selected !== undefined && this.selected.endpoint.path.length > 0) throw new Error('实例端口通过从实例复制形成独立定义');
        request = this.selected === undefined
          ? { kind: 'add', ownerCellId: this.currentCellProvider(), draft: this.draft() }
          : { kind: 'update', portId: this.selected.endpoint.portId, draft: this.draft() };
      }
      const result: PortResult = this.prepareAction(request);
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview;
        this.previewPorts = this.previewPortsProvider(result.preview);
        if (!this.matches()) { this.invalidate(); this.status = '预览期间文档变化，请重新打开端口管理'; return; }
        this.ready = true;
      }
    } catch (error) {
      this.invalidate();
      this.status = `端口未预览：${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private apply(): void {
    if (this.busy) return;
    if (!this.ready || this.preview === undefined) {
      const autoKind: string = this.portScopeIndex === 1 ? 'copy' : this.pendingKind;
      this.refresh(autoKind);
    }
    if (!this.ready || this.preview === undefined) return;
    if (!this.matches()) { this.invalidate(); this.status = '文档或选区已改变，请重新打开端口管理'; return; }
    this.busy = true;
    try {
      const result: PortResult = this.applyAction(this.preview.id);
      this.status = result.message;
      this.invalidate();
      if (result.ok) this.controller.close();
    } catch (error) {
      this.invalidate();
      this.status = `端口未应用：${String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  @Builder
  PortList() {
    Column({ space: 8 }) {
      Search({ value: this.query, placeholder: '搜索完整端口名称或 ID' })
        .onFocus(() => { resetModifierKeys(); })
        .width('100%').height(UI.fieldHeight).textFont({ size: UI.fontBody }).placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((value: string) => this.changeQuery(value))
      Select([{ value: '定义端口' }, { value: '实例端口' }]).selected(this.portScopeIndex).value(this.portScopeIndex === 0 ? '定义端口' : '实例端口')
        .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy)
        .onSelect((index: number) => this.changeScope(index))
      Scroll() {
        Column({ space: 6 }) {
          if (this.list().length === 0) {
            Text(this.portScopeIndex === 0 ? '此范围暂无定义端口（右侧正在新建）' : '此范围暂无实例端口')
              .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').padding({ top: 6, bottom: 6 })
          }
          ForEach(this.list(), (choice: PortUiChoice) => {
            Button(choice.label, { type: ButtonType.Normal }).width('100%').height(UI.controlHeight).fontSize(UI.fontCaption)
              .fontColor(this.selectedKey === choice.label ? COLORS.primary : COLORS.ink)
              .backgroundColor(this.selectedKey === choice.label ? COLORS.primarySoft : COLORS.surfaceMuted)
              .border({ width: 1, color: this.selectedKey === choice.label ? COLORS.primary : COLORS.border })
              .borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.choose(choice))
          }, (choice: PortUiChoice): string => choice.label)
        }.width('100%')
      }.constraintSize({ minHeight: 120, maxHeight: 220 }).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      Button(this.selectedKey.length === 0 && this.portScopeIndex === 0 ? '新建端口（当前模式）' : '新增端口', { type: ButtonType.Normal })
        .height(UI.controlHeight).width('100%').fontSize(UI.fontBody)
        .fontColor(this.selectedKey.length === 0 && this.portScopeIndex === 0 ? COLORS.primary : COLORS.ink)
        .backgroundColor(this.selectedKey.length === 0 && this.portScopeIndex === 0 ? COLORS.primarySoft : COLORS.surfaceMuted)
        .border({ width: 1, color: this.selectedKey.length === 0 && this.portScopeIndex === 0 ? COLORS.primary : COLORS.border })
        .borderRadius(UI.controlRadius)
        .enabled(!this.busy && this.portScopeIndex === 0).onClick(() => this.newPort(true))
      Button('从实例复制', { type: ButtonType.Normal }).height(UI.controlHeight).width('100%').fontSize(UI.fontBody)
        .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(!this.busy && this.selectedKey.length > 0 && this.portScopeIndex === 1).onClick(() => this.refresh('copy'))
    }.width(this.contentWidth >= 640 ? 236 : '100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  PortFields() {
    Column({ space: 8 }) {
      Row({ space: 10 }) {
        GeometryNumberField({
          label: '名称',
          value: this.nameText,
          inputAllowed: !this.busy,
          onValueChange: (value: string) => { if (value !== this.nameText) { this.nameText = value; this.changed(); } }
        }).layoutWeight(1)
        GeometryNumberField({
          label: '类型',
          value: this.typeText,
          inputAllowed: !this.busy && this.portScopeIndex === 0,
          onValueChange: (value: string) => { if (value !== this.typeText) { this.typeText = value; this.changed(); } }
        }).layoutWeight(1)
      }.width('100%')

      if (this.portScopeIndex === 0) {
        Row({ space: 8 }) {
          Text('常用类型').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          Row() {
            StableSegmentButton({
              items: [{ text: '电气 electrical' }, { text: '光学 optical' }, { text: '射频 rf' }] as [
                SegmentButtonTextItem,
                SegmentButtonTextItem,
                SegmentButtonTextItem
              ] as SegmentButtonItemTuple,
              selectedIndex: this.portTypeSegmentIndex(),
              onItemClicked: (idx: number) => {
                if (!this.busy && idx >= 0 && idx < PRESET_PORT_TYPES.length) {
                  const nextType: string = PRESET_PORT_TYPES[idx];
                  if (this.typeText !== nextType) {
                    this.typeText = nextType;
                    this.changed();
                  }
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: UI.fontCaption,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 32,
              itemMinHeight: 26,
              itemPaddingHorizontal: 6
            })
          }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)
      }

      Row({ space: 10 }) {
        GeometryNumberField({ label: '中心 X (nm)', value: this.centerX, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.centerX) { this.centerX = value; this.changed(); } } }).layoutWeight(1)
        GeometryNumberField({ label: '中心 Y (nm)', value: this.centerY, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.centerY) { this.centerY = value; this.changed(); } } }).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        GeometryNumberField({ label: '方向 (°)', value: this.angleText, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.angleText) { this.angleText = value; this.changed(); } } }).layoutWeight(1)
        GeometryNumberField({ label: '固有宽度 (nm)', value: this.widthText, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.widthText) { this.widthText = value; this.changed(); } } }).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        GeometryNumberField({ label: '图层', value: this.layerText, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.layerText) { this.layerText = value; this.changed(); } } }).layoutWeight(1)
        GeometryNumberField({ label: '数据类型', value: this.datatypeText, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.datatypeText) { this.datatypeText = value; this.changed(); } } }).layoutWeight(1)
      }.width('100%')
      Row({ space: 10 }) {
        GeometryNumberField({ label: 'Frame 放大率', value: this.magText, inputAllowed: !this.busy && this.portScopeIndex === 0, onValueChange: (value: string) => { if (value !== this.magText) { this.magText = value; this.changed(); } } }).layoutWeight(1)
        Column({ space: 8 }) {
          Text('Frame 镜像').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          Select([{ value: '无镜像' }, { value: '镜像' }]).selected(this.mirrorIndex).value(this.mirrorIndex === 1 ? '镜像' : '无镜像')
            .height(UI.fieldHeight).width('100%').font({ size: UI.fontBody }).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy && this.portScopeIndex === 0)
            .onSelect((index: number) => { if (index !== this.mirrorIndex) { this.mirrorIndex = index; this.changed(); } })
        }.layoutWeight(1)
      }.width('100%')
      Row({ space: 8 }) {
        Text('附加信息 (JSON)').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
        Text(this.crossSectionText).fontSize(UI.fontCaption).fontColor(COLORS.muted)
      }.width('100%')
      TextArea({ text: this.infoText }).height(64).width('100%').fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy && this.portScopeIndex === 0)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .onChange((value: string) => { if (value !== this.infoText) { this.infoText = value; this.changed(); } })
      PortGeometryPanel({ title: this.ready ? '应用后端口预览' : '当前端口投影', ports: this.ready ? this.previewPorts : this.sourcePorts })
      if (this.selectedKey.length > 0 && this.portScopeIndex === 0) {
        Button('预览删除端口', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.danger)
          .backgroundColor(COLORS.dangerSoft).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .enabled(!this.busy).onClick(() => this.refresh('remove'))
      }
    }.width('100%').padding({ right: 6, bottom: 12 }).alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 12 }) {
      PanelHeading({
        title: '端口管理',
        subtitle: `当前 Cell · ${this.cellNameProvider()}`,
        closeAction: () => { if (!this.busy) { this.invalidate(); this.controller.close(); } }
      })
      Scroll() {
        Column({ space: 12 }) {
          if (this.contentWidth >= 640) {
            Row({ space: 16 }) {
              this.PortList()
              Column() { this.PortFields() }.layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Top)
          } else {
            this.PortList()
            this.PortFields()
          }
          if (this.scopeNotice.length > 0) {
            Text(this.scopeNotice).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          }
        }.width('100%').padding({ bottom: 8 }).alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      if (this.status.length > 0) {
        Text(this.status).fontSize(UI.fontCaption).fontColor(this.ready ? COLORS.muted : COLORS.danger).width('100%')
      }
      Row({ space: 12 }) {
        Button('关闭', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy)
          .onClick(() => { this.invalidate(); this.controller.close(); })
        Blank()
        Button('预览修改', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy && this.portScopeIndex === 0)
          .onClick(() => this.refresh())
        Button('应用端口', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).fontColor(Color.White)
          .backgroundColor(COLORS.primary).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(!this.busy && (this.portScopeIndex === 0 || (this.ready && this.preview !== undefined)))
          .onClick(() => this.apply())
      }.width('100%').padding({ top: 14 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(900).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 820 }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
