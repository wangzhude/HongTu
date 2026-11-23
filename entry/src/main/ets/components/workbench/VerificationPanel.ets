import { StableSegmentButton } from '../StableSegmentButton';
import { pasteboard } from '@kit.BasicServicesKit';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { WorkbenchIcon } from './WorkbenchIcon';
import type { TechnologyPackage } from '../../common/technologyPackage';
import { technologyService } from '../../services/TechnologyService';
import { pythonBridgeService } from '../../services/PythonBridgeService';
import type { PythonDocumentInput, PythonVerificationResult, PythonViolation, PythonVerifiedDevice } from '../../services/PythonBridgeService';
import type { PythonOperationHandle, PythonCancellationResult } from '../../services/PythonBridgeService';
import { engineeringFileService } from '../../services/EngineeringFileService';

function emptyVerification(): PythonVerificationResult {
  return { success: false, complete: false, passed: false, kind: '', technologyId: '', deckId: '',
    engine: '', scope: '', foundrySignoff: false, netCount: 0, reportText: '', error: '',
    violations: [], devices: [], violationCount: 0, markersTruncated: false };
}

@Component
export struct VerificationPanel {
  @Prop @Watch('invalidateResult') inputRevision: string = '';
  @Prop panelWidth: number = 620;
  @Prop panelHeight: number = 720;
  documentProvider: () => Promise<PythonDocumentInput> = async () => { throw new Error('当前文档快照尚未连接'); };
  revisionProvider: () => string = () => '';
  locateAction: (violation: PythonViolation, cellName: string) => void = () => {};
  resultAction: (result: PythonVerificationResult) => void = () => {};
  technologyAction: () => void = () => {};
  settingsAction: () => void = () => {};
  closeAction: () => void = () => {};
  @State kind: 'drc' | 'lvs' = 'drc';
  @State technologyName: string = '';
  @State deckName: string = '';
  @State cellName: string = '';
  @State referenceSpice: string = '';
  @State busy: boolean = false;
  @State fileBusy: boolean = false;
  @State status: string = '';
  @State result: PythonVerificationResult = emptyVerification();
  @State requestCell: string = '';
  private resultRevision: string = '';
  private active: boolean = true;
  private generation: number = 0;
  private verificationPending: boolean = false;
  private ownedOperation: PythonOperationHandle | null = null;
  private cancellation: Promise<PythonCancellationResult> | null = null;
  aboutToAppear(): void { this.active = true; this.refreshTechnology(); }
  aboutToDisappear(): void { this.active = false; this.cancelRun(); }
  private cancelRun(): void {
    this.generation++;
    const operation: PythonOperationHandle | null = this.ownedOperation;
    if (operation !== null) {
      if (this.active) this.status = '正在请求取消验证，等待工作进程确认停止…';
      this.cancellation = pythonBridgeService.cancelOperation(operation).then((result: PythonCancellationResult): PythonCancellationResult => {
        if (this.active && this.ownedOperation === operation) this.status = result.message;
        return result;
      }).catch((): PythonCancellationResult => {
        const result: PythonCancellationResult = { confirmed: false, message: '取消未获确认，验证可能仍在运行' };
        if (this.active && this.ownedOperation === operation) this.status = result.message;
        return result;
      });
    } else if (this.active && this.busy) this.status = '已取消，验证尚未启动；正在清理当前快照';
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private refreshTechnology(): void {
    const technology: TechnologyPackage | undefined = technologyService.getActive();
    this.technologyName = technology === undefined ? '未绑定工艺' : `${technology.name} ${technology.version}`;
    this.deckName = technology === undefined ? '' : this.kind === 'drc' ? technology.drcDeckId : technology.lvsDeckId;
  }
  private invalidateResult(): void {
    this.resultRevision = '';
    this.requestCell = '';
    this.result = emptyVerification();
    this.resultAction(this.result);
    this.status = '验证输入已变化，请重新运行';
  }
  private changeKind(kind: 'drc' | 'lvs'): void {
    if (this.busy || this.fileBusy || this.kind === kind) return;
    this.kind = kind;
    this.refreshTechnology();
    this.invalidateResult();
  }
  private changeCellName(value: string): void {
    if (this.busy || this.fileBusy || this.cellName === value) return;
    this.cellName = value;
    this.invalidateResult();
  }
  private changeReference(value: string): void {
    if (this.busy || this.fileBusy || this.referenceSpice === value) return;
    this.referenceSpice = value;
    this.invalidateResult();
  }
  private async readReference(): Promise<void> {
    if (this.busy || this.fileBusy) return;
    const revision: string = this.revisionProvider();
    this.fileBusy = true;
    try {
      const reference: string = await engineeringFileService.pickText(this.context(), '参考 SPICE/CDL 网表|.cir,.sp,.spice,.cdl,.txt');
      if (!this.active) return;
      if (revision !== this.revisionProvider()) throw new Error('选择网表期间文档已变化，请重新选择');
      if (this.referenceSpice !== reference) {
        this.referenceSpice = reference;
        this.invalidateResult();
      }
      this.status = '参考网表已读取';
    } catch (error) { if (this.active) this.status = error instanceof Error ? error.message : String(error); }
    finally { this.fileBusy = false; }
  }
  private async run(): Promise<void> {
    if (this.busy || this.fileBusy) return;
    this.invalidateResult();
    this.refreshTechnology();
    const technology: TechnologyPackage | undefined = technologyService.getActive();
    if (technology === undefined || this.deckName.length === 0) { this.status = '先绑定工艺并配置对应验证 deck ID'; return; }
    if (this.kind === 'lvs' && this.referenceSpice.trim().length === 0) { this.status = '器件 LVS 需要参考 SPICE/CDL 网表'; return; }
    const revision: string = this.revisionProvider();
    const token: number = ++this.generation;
    const kind: 'drc' | 'lvs' = this.kind;
    const deckId: string = this.deckName;
    const requestedCell: string = this.cellName.trim();
    const reference: string = kind === 'lvs' ? this.referenceSpice : '';
    const context = this.context();
    let document: PythonDocumentInput | undefined;
    let cancelledOutcome: string = '';
    this.busy = true; this.resultRevision = ''; this.requestCell = '';
    this.result = emptyVerification(); this.resultAction(this.result);
    this.status = '正在把当前编辑态交给电脑 KLayout 验证…';
    try {
      document = await this.documentProvider();
      if (!this.active || token !== this.generation) return;
      if (revision !== this.revisionProvider()) throw new Error('创建验证快照期间文档已变化，请重新运行');
      const cell: string = requestedCell || document.currentCellName || '';
      if (cell.length === 0) throw new Error('当前 Cell 名称不可用，请明确指定检查 Cell');
      this.verificationPending = true;
      this.ownedOperation = pythonBridgeService.createOperation('verify');
      this.cancellation = null;
      const result: PythonVerificationResult = await pythonBridgeService.verify({ kind: kind,
        technologyId: technology.id, deckId: deckId, document: document,
        referenceSpice: reference, cellName: cell }, this.ownedOperation);
      if (token !== this.generation) {
        cancelledOutcome = result.success ? '验证已先于取消完成；本次结果未应用，请重新运行以显示报告'
          : `验证已结束：${result.error ?? '未完成验证'}`;
      }
      if (!this.active || token !== this.generation) return;
      if (revision !== this.revisionProvider()) throw new Error('验证期间当前文档发生变化，请重新运行；旧结果未应用');
      this.result = result; this.requestCell = cell; this.resultRevision = revision; this.resultAction(result);
      this.status = !result.success ? `未完成：${result.error ?? '验证失败'}` : !result.complete
        ? '检查不完整，不能判定通过' : result.passed ? '所选规则范围通过' : '所选规则范围未通过';
    } catch (error) {
      const message: string = error instanceof Error ? error.message : String(error);
      if (token !== this.generation) cancelledOutcome = message;
      if (this.active && token === this.generation) this.status = message;
    }
    finally {
      if (this.cancellation !== null) await this.cancellation;
      if (this.active && cancelledOutcome.length > 0) this.status = cancelledOutcome;
      this.ownedOperation = null; this.cancellation = null;
      this.verificationPending = false;
      try { if (document !== undefined) await pythonBridgeService.disposeDocumentInput(document, context); }
      finally { this.busy = false; }
    }
  }
  private async saveReport(): Promise<void> {
    if (this.busy || this.fileBusy || this.result.reportText.length === 0) return;
    if (this.resultRevision !== this.revisionProvider()) { this.invalidateResult(); return; }
    const revision: string = this.resultRevision;
    const generation: number = this.generation;
    const result: PythonVerificationResult = this.result;
    const canPublish: () => boolean = (): boolean => this.active && generation === this.generation &&
      revision === this.revisionProvider() && this.resultRevision === revision && result === this.result;
    this.fileBusy = true;
    try { await engineeringFileService.saveText(this.context(), `${this.kind}-verification.json`, result.reportText, canPublish); if (canPublish()) this.status = '验证报告已导出'; }
    catch (error) { if (canPublish()) this.status = error instanceof Error ? error.message : String(error); }
    finally { this.fileBusy = false; }
  }
  private locate(violation: PythonViolation): void {
    if (this.resultRevision !== this.revisionProvider()) {
      this.status = '验证后文档已变化，请重新验证后定位';
      this.resultRevision = ''; this.requestCell = ''; this.result = emptyVerification(); this.resultAction(this.result);
      return;
    }
    if (!this.result.success || this.requestCell.length === 0) return;
    this.locateAction(violation, this.requestCell);
  }
  private statusColor(): string {
    return !this.result.success || this.busy || this.fileBusy ? COLORS.muted
      : this.result.complete && this.result.passed ? COLORS.success : COLORS.danger;
  }
  build() {
    Column({ space: 14 }) {
      PanelHeading({ title: '工艺 DRC / 器件 LVS', subtitle: '', closeAction: () => this.closeAction() })
      Flex({ direction: this.panelWidth < 520 ? FlexDirection.Column : FlexDirection.Row }) {
        Row() {
          StableSegmentButton({
            items: [{ text: 'DRC' }, { text: '器件 LVS' }] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
            selectedIndex: this.kind === 'drc' ? 0 : 1,
            onItemClicked: (idx: number) => {
              if (!this.busy && !this.fileBusy) {
                this.changeKind(idx === 0 ? 'drc' : 'lvs');
              }
            },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: UI.fontBody,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: UI.controlHeight,
            itemMinHeight: UI.controlHeight - 6
          })
        }.width(this.panelWidth < 520 ? '100%' : '48%').opacity(!this.busy && !this.fileBusy ? 1.0 : 0.5)
          .enabled(!this.busy && !this.fileBusy).margin({ bottom: this.panelWidth < 520 ? 10 : 0 })
        Row({ space: 8 }) {
          Blank()
          Button('工艺配置', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).enabled(!this.busy && !this.fileBusy).onClick(() => this.technologyAction())
          Button('连接设置', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).enabled(!this.busy && !this.fileBusy).onClick(() => this.settingsAction())
        }.width(this.panelWidth < 520 ? '100%' : '52%')
      }.width('100%')
      Text(`${this.technologyName} · deck: ${this.deckName || '未配置'}`).fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%')
      Row({ space: 12 }) {
        Text('检查 Cell').fontSize(UI.fontBody).fontColor(COLORS.ink).width(72)
        TextInput({ text: this.cellName, placeholder: '留空检查当前 Cell' }).utilityInput().layoutWeight(1).enabled(!this.busy && !this.fileBusy).onChange((value: string) => this.changeCellName(value))
      }.width('100%')
      if (this.kind === 'lvs') {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            Text('参考网表').fontSize(UI.fontBody).fontColor(COLORS.ink).width(72)
            Button('从文件读取', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).fontSize(12).enabled(!this.busy && !this.fileBusy).onClick(() => { this.readReference(); })
            if (!this.busy && !this.fileBusy) {
              Row() {
                PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
                  .fontSize(12)
                  .fontColor(Color.White)
                  .iconColor(Color.White)
                  .backgroundColor(COLORS.primary)
                  .padding({ top: 7, bottom: 7, left: 12, right: 12 })
                  .onClick((_event: ClickEvent, pasteResult: PasteButtonOnClickResult) => {
                    if (pasteResult === PasteButtonOnClickResult.SUCCESS && !this.busy && !this.fileBusy) {
                      pasteboard.getSystemPasteboard().getData().then((data) => {
                        const text: string = data.getPrimaryText() ?? '';
                        if (text.trim().length > 0) {
                          this.changeReference(text);
                          this.status = '已从剪贴板粘贴参考 SPICE/CDL 网表';
                        } else {
                          this.status = '剪贴板中暂无可用的文本网表';
                        }
                      }).catch(() => {
                        this.status = '读取剪贴板失败，请手动粘贴或从文件读取';
                      });
                    }
                  })
              }
            }
          }.width('100%').alignItems(VerticalAlign.Center)
          TextArea({ text: this.referenceSpice, placeholder: '.SUBCKT ...' }).height(132).width('100%').fontSize(12).fontFamily('monospace').fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).padding(12).enabled(!this.busy && !this.fileBusy)
            .onChange((value: string) => this.changeReference(value))
        }.width('100%')
      }
      Row({ space: 8 }) {
        Button(this.busy ? '正在验证…' : '运行验证', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(13)
          .width(this.panelWidth < 480 ? 128 : 148).padding({ left: 8, right: 8 }).backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .enabled(!this.busy && !this.fileBusy).onClick(() => { this.run(); })
        if (this.busy && this.panelWidth >= 480) { Button('取消验证', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).onClick(() => this.cancelRun()) }
        Button('导出报告', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).padding({ left: 10, right: 10 })
          .enabled(this.result.reportText.length > 0 && !this.busy && !this.fileBusy).onClick(() => { this.saveReport(); })
        Blank()
      }.width('100%')
      if (this.busy && this.panelWidth < 480) { Button('取消验证', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width('100%').fontSize(12).onClick(() => this.cancelRun()) }
      if (this.busy) {
        Row({ space: 10 }) {
          LoadingProgress().width(18).height(18).color(COLORS.primary)
          Progress({ value: this.verificationPending ? 65 : 25, total: 100, type: ProgressType.Linear })
            .color(COLORS.primary)
            .backgroundColor(COLORS.surfaceMuted)
            .style({ strokeWidth: 6, enableScanEffect: true })
            .layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)
      }
      if (this.status.length > 0) {
        Row({ space: 8 }) {
          WorkbenchIcon({ name: this.result.success && this.result.complete && this.result.passed ? 'verify' : 'info', iconSize: 16, color: this.statusColor() })
          Text(this.status).fontSize(UI.fontBody).fontColor(this.statusColor()).layoutWeight(1)
        }.width('100%')
      }
      Column({ space: 12 }) {
        Text('验证结果').fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        Scroll() {
          Column({ space: 12 }) {
            if (this.result.success) {
              Row({ space: 12 }) {
                Text(`Cell：${this.requestCell}`).fontSize(12).fontColor(COLORS.ink)
                Text(`引擎：${this.result.engine}`).fontSize(12).fontColor(COLORS.muted).layoutWeight(1)
              }.width('100%')
              if (this.result.scope.length > 0) {
                Text(this.result.scope).fontSize(11).fontColor(COLORS.muted).width('100%')
              }
              Text(`违例 ${this.result.violationCount} · 器件 ${this.result.devices.length} · 网络 ${this.result.netCount}`)
                .fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
                .padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
              if (this.result.violations.length > 0) {
                Row({ space: 10 }) {
                  Text('#').fontSize(11).fontColor(COLORS.muted).width(22)
                  Text('规则名').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                  if (this.panelWidth >= 480) { Text('图层 / 数据型').fontSize(11).fontColor(COLORS.muted).width(88) }
                  Text('操作').fontSize(11).fontColor(COLORS.muted).width(72)
                }.width('100%').padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
                ForEach(this.result.violations.slice(0, 300), (item: PythonViolation, index: number) => {
                  Row({ space: 10 }) {
                    Text(`${index + 1}`).fontSize(12).fontColor(COLORS.muted).width(22)
                    Column({ space: 4 }) {
                      Text(item.rule).fontSize(12).fontColor(COLORS.ink).width('100%').maxLines(2)
                      if (this.panelWidth < 480) { Text(`L${item.layerNumber}/D${item.datatype}`).fontSize(11).fontColor(COLORS.muted).width('100%') }
                      if (item.message.length > 0) { Text(item.message).fontSize(11).fontColor(COLORS.muted).width('100%') }
                    }.layoutWeight(1)
                    if (this.panelWidth >= 480) { Text(`L${item.layerNumber}/D${item.datatype}`).fontSize(11).fontColor(COLORS.ink).width(88) }
                    Button(`定位 ${index + 1}`, { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).width(72).padding(0).fontSize(11)
                      .backgroundColor(COLORS.surface).fontColor(COLORS.primary).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).onClick(() => this.locate(item))
                  }.width('100%').padding(10).border({ width: { bottom: 1 }, color: COLORS.border })
                }, (item: PythonViolation, index: number) => `${index}:${item.rule}`)
              }
              if (this.result.violations.length > 300 || this.result.markersTruncated) {
                Text('仅显示前 300 项，完整统计见导出报告').fontSize(11).fontColor(COLORS.muted).width('100%')
              }
              if (this.result.devices.length > 0) {
                Row({ space: 10 }) {
                  Text('#').fontSize(11).fontColor(COLORS.muted).width(22)
                  Text('器件名').fontSize(11).fontColor(COLORS.muted).width(this.panelWidth < 480 ? 48 : 84)
                  Text('器件类型').fontSize(11).fontColor(COLORS.muted).width(this.panelWidth < 480 ? 54 : 84)
                  Text('参数').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                }.width('100%').padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
                ForEach(this.result.devices.slice(0, 300), (item: PythonVerifiedDevice, index: number) => {
                  Row({ space: 10 }) {
                    Text(`${index + 1}`).fontSize(12).fontColor(COLORS.muted).width(22)
                    Text(item.name).fontSize(12).fontColor(COLORS.ink).width(this.panelWidth < 480 ? 48 : 84).maxLines(2)
                    Text(item.model).fontSize(12).fontColor(COLORS.ink).width(this.panelWidth < 480 ? 54 : 84).maxLines(2)
                    Text(JSON.stringify(item.parameters)).fontSize(UI.fontCaption).fontFamily('monospace').fontColor(COLORS.muted).layoutWeight(1)
                  }.width('100%').padding(10).border({ width: { bottom: 1 }, color: COLORS.border })
                }, (item: PythonVerifiedDevice, index: number) => `${index}:${item.name}`)
              }
            } else if (!this.busy) {
              Text('尚未运行验证').fontSize(12).fontColor(COLORS.muted).width('100%').padding({ top: 12 })
            }
          }.width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)
      }.layoutWeight(1).width('100%').padding({ top: 14 }).border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .padding({ left: 18, right: 18, top: 8, bottom: 24 })
    .backgroundColor(Color.Transparent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@Extend(Button)
function utilityButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}

@Extend(TextInput)
function utilityInput() {
  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
}
