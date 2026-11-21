import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { WorkbenchIcon } from './WorkbenchIcon';
import { AiContext, aiService } from '../../services/AiService';
import { pythonBridgeService, PythonLayoutArtifact, PythonDocumentInput, PythonInputMode,
  PythonParameter, PythonOperationHandle, PythonCancellationResult } from '../../services/PythonBridgeService';
import { pythonWorkspaceService, PythonTemplate, PythonRunRecord, PythonEditorDraft } from '../../services/PythonWorkspaceService';
import { readAutomationText, saveAutomationText } from '../../services/AutomationFiles';

const SAMPLE_SCRIPT: string = `import hongtu as db
layout = db.Layout()
layout.dbu = 0.001
top = layout.create_cell('ARRAY_DEMO')
unit = layout.create_cell('UNIT')
metal = layout.layer(1, 0)
unit.shapes(metal).insert(db.Box(0, 0, 800, 400))
top.insert(db.CellInstArray(unit.cell_index(), db.Trans(), db.Vector(1200, 0), db.Vector(0, 800), 6, 4))`;

/** Python is executed by the user's local CPython companion; the current document is untouched until load. */
@Component
export struct PythonLayoutPanel {
  @Prop openConnectionSettings: boolean = false;
  @Prop connectionInUse: boolean = false;
  @Prop panelWidth: number = 620;
  @Prop panelHeight: number = 740;
  contextProvider: () => AiContext = () => { throw new Error('版图上下文尚未连接'); };
  documentIdentityProvider: () => string = () => '';
  revisionProvider: () => string = () => '';
  loadLayoutAction: (path: string, name: string, canApply: () => boolean) => Promise<boolean> = async () => false;
  documentProvider: (mode: PythonInputMode) => Promise<PythonDocumentInput> = async () => { throw new Error('当前文档快照尚未连接'); };
  loadResultAction?: (artifact: PythonLayoutArtifact, mode: 'replace' | 'merge', sourceRevision: number, canApply: () => boolean) => Promise<boolean>;
  backAction: () => void = () => {};
  closeAction: () => void = () => {};
  onDraftChanged: (documentId: string, draft: PythonEditorDraft) => void = () => {};
  @State script: string = SAMPLE_SCRIPT;
  @State requestText: string = '';
  @State status: string = '';
  @State busy: boolean = false;
  @State running: boolean = false;
  @State showSettings: boolean = false;
  @State endpoint: string = 'http://127.0.0.1:7865';
  @State token: string = '';
  @State previewPath: string = '';
  @State previewSummary: string = '';
  @State readyPath: string = '';
  @State readyName: string = '';
  @State output: string = '';
  @State inputMode: PythonInputMode = 'new';
  @State parametersText: string = '{}';
  @State sweepName: string = '';
  @State sweepValues: string = '';
  @State templateName: string = '';
  @State templates: PythonTemplate[] = [];
  @State history: PythonRunRecord[] = [];
  @State showLibrary: boolean = false;
  @State showHistory: boolean = false;
  private artifact: PythonLayoutArtifact | null = null;
  private cancelRequested: boolean = false;
  private active: boolean = true;
  private panelGeneration: number = 0;
  private openedDocumentIdentity: string = '';
  private savedDraftContext: string = '';
  private ownedOperation: PythonOperationHandle | null = null;
  private cancellation: Promise<PythonCancellationResult> | null = null;
  private aiPending: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    this.panelGeneration++;
    this.openedDocumentIdentity = this.documentIdentityProvider();
    PersistentStorage.persistProp('hongtu_python_script', SAMPLE_SCRIPT);
    this.script = AppStorage.get<string>('hongtu_python_script') ?? SAMPLE_SCRIPT;
    const draft: PythonEditorDraft | undefined = pythonWorkspaceService.draft();
    if (draft !== undefined) {
      this.script = draft.script; this.parametersText = draft.parameters; this.inputMode = draft.inputMode;
      this.requestText = draft.request; this.sweepName = draft.sweepName; this.sweepValues = draft.sweepValues;
      this.templateName = draft.templateName;
    }
    this.savedDraftContext = JSON.stringify(this.currentDraft());
    this.templates = pythonWorkspaceService.templates();
    this.history = pythonWorkspaceService.history();
    const generation: number = this.panelGeneration;
    pythonBridgeService.loadConfig().then((config) => {
      if (!this.active || generation !== this.panelGeneration) return;
      this.endpoint = config.endpoint;
      this.token = config.token;
      this.showSettings = this.openConnectionSettings || config.token.length === 0;
    }).catch((error: Error) => { if (this.active && generation === this.panelGeneration) this.status = error.message; });
  }

  aboutToDisappear(): void {
    this.active = false;
    this.panelGeneration++;
    try {
      if (this.openedDocumentIdentity === this.documentIdentityProvider()) {
        AppStorage.setOrCreate<string>('hongtu_python_script', this.script);
        this.persistDraft();
      }
    } catch (_) { /* A storage failure must not leave this panel's task running. */ }
    finally { this.cancelRun(); }
  }

  private async saveConnection(): Promise<void> {
    if (!this.active || this.busy || this.running || this.connectionInUse) return;
    const generation: number = ++this.panelGeneration;
    this.busy = true;
    this.cancelRequested = false;
    try {
      await pythonBridgeService.saveConfig({ endpoint: this.endpoint, token: this.token });
      if (!this.active || generation !== this.panelGeneration) return;
      await pythonBridgeService.checkConnection();
      if (!this.active || generation !== this.panelGeneration) return;
      this.status = 'Python 执行服务已连接，令牌已存入系统凭据库';
      this.showSettings = false;
    } catch (error) { if (this.active && generation === this.panelGeneration) this.status = error instanceof Error ? error.message : String(error); }
    finally { if (this.active && generation === this.panelGeneration) this.busy = false; }
  }

  private async clearConnection(): Promise<void> {
    if (!this.active || this.busy || this.running || this.connectionInUse) return;
    const generation: number = ++this.panelGeneration;
    this.busy = true;
    try {
      const cleared = await pythonBridgeService.clearConnection();
      if (!this.active || generation !== this.panelGeneration) return;
      this.endpoint = cleared.endpoint;
      this.token = cleared.token;
      this.showSettings = true;
      this.status = '已断开并清除连接，地址已恢复默认；再次使用前请保存并连接';
    } catch (error) { if (this.active && generation === this.panelGeneration) this.status = error instanceof Error ? error.message : String(error); }
    finally { if (this.active && generation === this.panelGeneration) this.busy = false; }
  }

  private async run(generateWithAi: boolean): Promise<void> {
    if (this.busy) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let document: PythonDocumentInput | undefined;
    let completedRuns: number = 0;
    let completedArtifactRetained: boolean = false;
    this.busy = true;
    this.running = true;
    this.cancelRequested = false;
    this.invalidatePreview();
    this.previewSummary = '';
    this.output = '';
    try {
      const runs: PythonParameter[][] = pythonWorkspaceService.sweep(this.parametersText, this.sweepName, this.sweepValues);
      if (generateWithAi && this.requestText.trim().length === 0) throw new Error('先描述要生成的版图');
      const promptContext: AiContext | undefined = generateWithAi ? this.contextProvider() : undefined;
      document = this.inputMode === 'new' ? undefined : await this.documentProvider(this.inputMode);
      if (!this.active || this.cancelRequested) return;
      if (generateWithAi && promptContext !== undefined) {
        this.status = 'AI 正在编写 Python…';
        this.aiPending = true;
        try {
          this.script = await aiService.generatePythonScript(this.requestText + '\n界面参数: ' + this.parametersText,
            promptContext, undefined, this.inputMode);
        } finally { this.aiPending = false; }
        if (!this.active || this.cancelRequested) return;
      }
      AppStorage.setOrCreate<string>('hongtu_python_script', this.script);
      this.persistDraft();
      this.status = '正在运行 Python 并生成 GDS…';
      for (let index = 0; index < runs.length; index++) {
        if (!this.active || this.cancelRequested) break;
        this.status = `正在执行 ${index + 1}/${runs.length}，当前版图保持原样`;
        const params: Record<string, number | string | boolean> = {};
        for (const item of runs[index]) params[item.name] = item.value;
        const parameterJson = JSON.stringify(params);
        this.ownedOperation = pythonBridgeService.createOperation('generate');
        this.cancellation = null;
        completedArtifactRetained = false;
        let artifact: PythonLayoutArtifact;
        try {
          artifact = await pythonBridgeService.generate(this.script, context,
            { inputMode: this.inputMode, document, parameters: runs[index] }, this.ownedOperation);
        } catch (error) {
          try {
            pythonWorkspaceService.record(this.templateName || `运行 ${index + 1}`, this.script, parameterJson,
              this.inputMode, false, error instanceof Error ? error.message : String(error));
          } catch (_) { /* Do not replace the real execution outcome with a history-storage exception. */ }
          throw new Error(error instanceof Error ? error.message : String(error));
        } finally { if (this.active) this.history = pythonWorkspaceService.history(); }
        // A completed worker can win the cancel race. Preserve its real result, even after closing.
        try {
          pythonWorkspaceService.record(this.templateName || `运行 ${index + 1}`, this.script, parameterJson,
            this.inputMode, true, artifact.summary, artifact);
        } catch (_) {
          if (this.active) { this.showArtifact(artifact); this.status = '执行已完成，但运行历史保存失败；请先载入或导出结果'; }
          break;
        }
        if (this.active) this.history = pythonWorkspaceService.history();
        completedRuns++;
        completedArtifactRetained = true;
        if (!this.active || this.cancelRequested) break;
        this.showArtifact(artifact);
        this.ownedOperation = null;
      }
      if (this.active && !this.cancelRequested && completedRuns === runs.length) this.status = `${runs.length} 次执行完成。逐项预览后载入或合并，结果已保存在运行历史。`;
    } catch (error) {
      if (this.active) this.status = error instanceof Error ? error.message : String(error);
    } finally {
      if (this.cancellation !== null) await this.cancellation;
      if (this.active && this.cancelRequested && completedArtifactRetained) {
        this.status = '本次执行已完成，结果已保存在运行历史；后续扫参已停止';
      }
      this.ownedOperation = null;
      this.cancellation = null;
      if (document !== undefined) await pythonBridgeService.disposeDocumentInput(document, context);
      if (this.active) { this.busy = false; this.running = false; }
    }
  }

  private async loadGenerated(mode: 'replace' | 'merge' = 'replace'): Promise<void> {
    if (!this.active || this.busy || this.readyPath.length === 0) return;
    const generation: number = this.panelGeneration, identity: string = this.documentIdentityProvider(), revision: string = this.revisionProvider();
    const artifact = this.artifact;
    const path: string = this.readyPath;
    const canApply: () => boolean = (): boolean => this.active && generation === this.panelGeneration && identity === this.documentIdentityProvider() && revision === this.revisionProvider() && artifact === this.artifact && path === this.readyPath;
    this.busy = true;
    try {
      const loaded: boolean = this.loadResultAction !== undefined && artifact !== null
        ? await this.loadResultAction(artifact, mode, artifact.sourceRevision ?? -1, canApply)
        : (mode === 'replace' ? await this.loadLayoutAction(path, this.readyName, canApply) : false);
      if (!this.active || generation !== this.panelGeneration) return;
      if (loaded) {
        this.status = '已载入生成的版图，可继续编辑或另存为 GDS';
      } else this.status = '已保留生成结果，当前版图未替换';
    } catch (error) { if (this.active && generation === this.panelGeneration) this.status = error instanceof Error ? error.message : String(error); }
    finally { if (this.active && generation === this.panelGeneration) this.busy = false; }
  }

  private showArtifact(artifact: PythonLayoutArtifact): void {
    this.artifact = artifact; this.readyPath = artifact.path; this.readyName = artifact.name;
    this.previewPath = artifact.previewPath; this.previewSummary = artifact.summary; this.output = artifact.stdout;
  }
  private invalidatePreview(): void {
    this.artifact = null; this.readyPath = ''; this.readyName = ''; this.previewPath = '';
    this.previewSummary = ''; this.output = '';
  }
  private cancelRun(): void {
    this.cancelRequested = true;
    if (this.aiPending) aiService.cancelPythonGeneration();
    const operation: PythonOperationHandle | null = this.ownedOperation;
    if (operation === null) {
      if (this.active && this.running) this.status = '已取消后续执行；尚未启动 Python 工作进程';
      return;
    }
    if (this.active) this.status = '正在请求取消；等待 Python 工作进程确认停止…';
    this.cancellation = pythonBridgeService.cancelOperation(operation).then((result: PythonCancellationResult): PythonCancellationResult => {
      if (this.active && this.ownedOperation === operation) this.status = result.message;
      return result;
    }).catch((): PythonCancellationResult => {
      const result: PythonCancellationResult = { confirmed: false, message: '取消未获确认，后台可能仍在运行；已停止后续扫参' };
      if (this.active && this.ownedOperation === operation) this.status = result.message;
      return result;
    });
  }
  private currentDraft(): PythonEditorDraft {
    return { script: this.script, parameters: this.parametersText, inputMode: this.inputMode,
      request: this.requestText, sweepName: this.sweepName, sweepValues: this.sweepValues, templateName: this.templateName };
  }
  private persistDraft(): void {
    if (this.openedDocumentIdentity !== this.documentIdentityProvider()) {
      this.status = '文档已变化，当前编辑内容仍保留；请重新打开 Python 面板';
      return;
    }
    try {
      const draft: PythonEditorDraft = this.currentDraft();
      const content: string = JSON.stringify(draft);
      // Merely opening/closing the panel must not turn its initial sample into
      // document content or grant ownership to imported engineering tools.
      if (content === this.savedDraftContext) return;
      const previous: PythonEditorDraft | undefined = pythonWorkspaceService.draft();
      pythonWorkspaceService.saveDraft(draft);
      try { this.onDraftChanged(this.openedDocumentIdentity, draft); }
      catch (failure) {
        try {
          if (this.openedDocumentIdentity === this.documentIdentityProvider() &&
            JSON.stringify(pythonWorkspaceService.draft()) === content) pythonWorkspaceService.restoreSessionDraft(previous);
        }
        catch (rollbackFailure) { throw new Error(`${String(failure)}；Python 草稿回滚失败：${String(rollbackFailure)}`); }
        throw new Error(failure instanceof Error ? failure.message : String(failure));
      }
      this.savedDraftContext = content;
    } catch (error) { this.status = `草稿保存失败，当前编辑内容仍保留：${String(error)}`; }
  }
  private selectTemplate(item: PythonTemplate): void {
    if (this.busy) return;
    this.script = item.script; this.parametersText = item.parameters; this.inputMode = item.inputMode;
    this.templateName = item.name; this.sweepName = item.sweepName ?? ''; this.sweepValues = item.sweepValues ?? '';
    this.invalidatePreview(); this.persistDraft();
  }
  private selectHistory(item: PythonRunRecord): void {
    if (this.busy) return;
    this.script = item.script; this.parametersText = item.parameters; this.inputMode = item.inputMode;
    // A history row is one concrete run, even if it originally belonged to a sweep.
    this.sweepName = ''; this.sweepValues = ''; this.templateName = '';
    this.invalidatePreview(); this.status = item.message;
    if (item.success && item.artifact !== undefined) this.showArtifact(item.artifact);
    this.persistDraft();
  }
  private saveTemplate(): void {
    try {
      pythonWorkspaceService.saveTemplate(this.templateName, this.script, this.parametersText, this.inputMode, this.sweepName, this.sweepValues);
      this.templates = pythonWorkspaceService.templates(); this.status = '模板已保存';
    } catch (error) { this.status = String(error); }
  }
  private removeTemplate(id: number): void {
    try {
      pythonWorkspaceService.removeTemplate(id);
      this.templates = pythonWorkspaceService.templates();
      this.status = '模板已删除';
    } catch (error) { this.status = String(error); }
  }
  private async scriptFile(importing: boolean): Promise<void> {
    if (this.busy || !this.active) return;
    if (this.openedDocumentIdentity !== this.documentIdentityProvider()) {
      this.status = '文档已变化，请重新打开 Python 面板后导入导出脚本'; return;
    }
    const generation: number = this.panelGeneration;
    const identity: string = this.documentIdentityProvider();
    const revision: string = this.revisionProvider();
    const current: () => boolean = () => this.active && generation === this.panelGeneration &&
      identity === this.documentIdentityProvider() && revision === this.revisionProvider();
    this.busy = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (importing) {
        const text = await readAutomationText(context, 'Python 脚本|.py');
        if (!this.active || generation !== this.panelGeneration) return;
        if (!current()) throw new Error('文档已变化，脚本文件未应用；请重新打开面板');
        if (text !== null) {
          if (text.length > 65536) throw new Error('脚本超过 64 KiB');
          this.script = text; this.invalidatePreview(); this.status = '脚本已载入，尚未执行'; this.persistDraft();
        }
      } else if (await saveAutomationText(context, 'hongtu-layout.py', this.script, current) && current()) this.status = '脚本已导出';
    } catch (error) { if (this.active && generation === this.panelGeneration) this.status = String(error); }
    finally { if (this.active && generation === this.panelGeneration) this.busy = false; }
  }

  private selectSection(section: string): void {
    if (this.busy) return;
    this.showSettings = section === 'connection';
    this.showLibrary = section === 'templates';
    this.showHistory = section === 'history';
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Text('Python 版图').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).layoutWeight(1)
        Button('AI 助手', { type: ButtonType.Normal }).fontSize(UI.fontBody).height(UI.compactControlHeight).enabled(!this.busy)
          .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(this.backAction)
        Button({ type: ButtonType.Normal }) { WorkbenchIcon({ name: 'close', iconSize: 16, color: COLORS.muted }) }
          .width(UI.compactControlHeight).height(UI.compactControlHeight).padding(0).backgroundColor(COLORS.surfaceMuted)
          .borderRadius(UI.controlRadius).accessibilityText('关闭 Python 版图面板').enabled(!this.busy).onClick(this.closeAction)
      }.width('100%').height(UI.titleBarHeight).padding({ left: UI.panelPadding, right: UI.panelPadding })
        .border({ width: { bottom: 1 }, color: COLORS.border })
      Row({ space: 4 }) {
        this.SectionTab('编辑器', 'editor')
        this.SectionTab('连接', 'connection')
        this.SectionTab('模板', 'templates')
        this.SectionTab('历史', 'history')
      }.width('100%').padding({ left: 16, right: 16, top: 4, bottom: 0 }).border({ width: { bottom: 1 }, color: COLORS.border })
      Scroll() {
        Column({ space: 16 }) {
          if (this.showSettings) {
            this.ConnectionSection()
          } else if (this.showLibrary) {
            this.TemplateSection()
          } else if (this.showHistory) {
            this.HistorySection()
            this.ResultSection()
          } else {
            this.EditorSection()
            this.ResultSection()
          }
          if (this.output.length > 0 && !this.showSettings && !this.showLibrary) {
            Text(this.output).fontSize(UI.fontCaption).fontFamily('monospace').fontColor(COLORS.muted).width('100%')
              .padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          }
        }.width('100%').padding(UI.panelPadding).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      if (this.busy || this.status.length > 0) {
        Row({ space: 10 }) {
          if (this.busy) { LoadingProgress().width(20).height(20).color(COLORS.primary) }
          Text(this.status).fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18).layoutWeight(1).maxLines(3)
          if (this.running) {
            Button('取消', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontBody)
              .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.cancelRun())
          }
        }.width('100%').padding(12).border({ width: { top: 1 }, color: COLORS.border })
      }
    }.width(this.panelWidth).height(this.panelHeight)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).clip(true)
  }

  @Builder
  SectionTab(label: string, section: string) {
    Column({ space: 4 }) {
      Button(label, { type: ButtonType.Normal }).width('100%').height(UI.controlHeight)
        .fontSize(UI.fontBody).fontWeight(FontWeight.Medium)
        .fontColor((section === 'editor' ? (!this.showSettings && !this.showLibrary && !this.showHistory) : (section === 'connection' ? this.showSettings : (section === 'templates' ? this.showLibrary : this.showHistory))) ? COLORS.primary : COLORS.muted)
        .backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
        .enabled(!this.busy).onClick(() => this.selectSection(section))
      Rect().width('100%').height(2).fill((section === 'editor' ? (!this.showSettings && !this.showLibrary && !this.showHistory) : (section === 'connection' ? this.showSettings : (section === 'templates' ? this.showLibrary : this.showHistory))) ? COLORS.primary : Color.Transparent)
    }.layoutWeight(1)
  }

  @Builder
  ConnectionSection() {
    Column({ space: 16 }) {
      Text('连接电脑上的 Python 执行服务').fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
      Text('CPython · KLayout API').fontSize(UI.fontCaption).fontColor(COLORS.muted)
      Column({ space: 6 }) {
        Text('服务地址').fontSize(UI.fontBody).fontColor(COLORS.ink)
        TextInput({ text: this.endpoint, placeholder: 'http://127.0.0.1:7865' })
          .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).enabled(!this.busy && !this.running && !this.connectionInUse)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => this.endpoint = value)
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 6 }) {
        Text('访问令牌').fontSize(UI.fontBody).fontColor(COLORS.ink)
        TextInput({ text: this.token, placeholder: '本机服务的访问令牌' }).type(InputType.Password)
          .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).enabled(!this.busy && !this.running && !this.connectionInUse)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => this.token = value)
      }.width('100%').alignItems(HorizontalAlign.Start)
      Text('脚本在隔离副本中运行，结果确认后载入。').fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18)
      Text('断开会清除本机保存的访问令牌并恢复默认地址。').fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18)
      Row({ space: 8 }) {
        Button('断开并清除连接', { type: ButtonType.Normal }).height(UI.controlHeight).layoutWeight(1)
          .fontSize(UI.fontBody).borderRadius(UI.controlRadius).backgroundColor(COLORS.dangerSoft).fontColor(COLORS.danger)
          .enabled(!this.busy && !this.running && !this.connectionInUse).onClick(() => this.clearConnection())
        Button('保存并连接', { type: ButtonType.Normal }).height(UI.controlHeight).layoutWeight(1)
          .fontSize(UI.fontBody).borderRadius(UI.controlRadius).backgroundColor(COLORS.primary).fontColor(Color.White)
          .enabled(!this.busy && !this.running && !this.connectionInUse).onClick(() => this.saveConnection())
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  TemplateSection() {
    Column({ space: 16 }) {
      Text('个人模板').fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
      Text('保存当前脚本、参数与运行方式，便于下次复用。').fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18)
      Row({ space: 8 }) {
        TextInput({ text: this.templateName, placeholder: '模板名称' }).height(UI.fieldHeight).layoutWeight(1)
          .fontSize(UI.fontBody).enabled(!this.busy).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => { this.templateName = value; this.persistDraft(); })
        Button('保存模板', { type: ButtonType.Normal }).enabled(!this.busy).fontSize(UI.fontBody).height(UI.controlHeight)
          .borderRadius(UI.controlRadius).backgroundColor(COLORS.primary).fontColor(Color.White).onClick(() => this.saveTemplate())
      }.width('100%')
      Text(`已保存的模板（${this.templates.length}）`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
      if (this.templates.length === 0) {
        Text('还没有模板，保存当前脚本后会显示在这里。').fontSize(UI.fontBody).fontColor(COLORS.muted)
          .width('100%').padding(16).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      }
      ForEach(this.templates, (item: PythonTemplate) => {
        Row({ space: 12 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 12 }) {
              WorkbenchIcon({ name: 'text', iconSize: 20, color: COLORS.muted })
              Column({ space: 4 }) {
                Text(item.name).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
                  .width('100%').textAlign(TextAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(item.inputMode === 'new' ? '生成新文档' : (item.inputMode === 'document' ? '当前文档副本' : '当前选区副本'))
                  .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').textAlign(TextAlign.Start)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              WorkbenchIcon({ name: 'chevronRight', iconSize: 14, color: COLORS.primary })
            }.width('100%')
          }.layoutWeight(1).height(48).padding(0).enabled(!this.busy)
            .borderRadius(UI.controlRadius).backgroundColor(Color.Transparent).onClick(() => this.selectTemplate(item))
          Button('删除', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontCaption)
            .enabled(!this.busy).borderRadius(UI.controlRadius).backgroundColor(COLORS.dangerSoft).fontColor(COLORS.danger)
            .onClick(() => this.removeTemplate(item.id))
        }.width('100%').padding(12)
          .backgroundColor(this.templateName === item.name ? COLORS.primarySoft : COLORS.surface)
          .border({ width: 1, color: this.templateName === item.name ? COLORS.primary : COLORS.border }).borderRadius(UI.controlRadius)
      }, (item: PythonTemplate) => item.id.toString())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  HistorySection() {
    Column({ space: 12 }) {
      Text('运行历史').fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
      Text('选择记录查看结果。成功结果可预览、载入或合并。').fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18)
      if (this.history.length === 0) {
        Text('还没有运行记录').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%').padding(16)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      }
      ForEach(this.history, (item: PythonRunRecord) => {
        Button({ type: ButtonType.Normal }) {
          Column({ space: 6 }) {
            Row({ space: 8 }) {
              Text(item.success ? '成功' : '失败').fontSize(UI.fontCaption).fontColor(item.success ? COLORS.success : COLORS.danger)
                .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                .backgroundColor(item.success ? COLORS.surfaceMuted : COLORS.dangerSoft).borderRadius(6)
              Text(item.name).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(new Date(item.timestamp).toLocaleTimeString()).fontSize(UI.fontCaption).fontColor(COLORS.muted)
              WorkbenchIcon({ name: 'chevronRight', iconSize: 14, color: COLORS.muted })
            }.width('100%')
            Text(item.parameters).fontSize(UI.fontCaption).fontColor(COLORS.muted).maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.enabled(!this.busy).width('100%').padding(12)
          .backgroundColor(item.artifact?.path === this.readyPath ? COLORS.primarySoft : COLORS.surface)
          .border({ width: 1, color: item.artifact?.path === this.readyPath ? COLORS.primary : COLORS.border }).borderRadius(UI.controlRadius)
          .onClick(() => this.selectHistory(item))
      }, (item: PythonRunRecord) => item.id.toString())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  EditorSection() {
    Column({ space: 16 }) {
      Column({ space: 6 }) {
        Row({ space: 12 }) {
          Text('运行方式').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width(72)
          Select([{ value: '生成新文档' }, { value: '当前文档副本' }, { value: '当前选区副本' }])
          .selected(this.inputMode === 'new' ? 0 : (this.inputMode === 'document' ? 1 : 2))
          .value(this.inputMode === 'new' ? '生成新文档' : (this.inputMode === 'document' ? '当前文档副本' : '当前选区副本'))
          .width(this.panelWidth >= 560 ? 240 : this.panelWidth - 116).height(UI.fieldHeight).font({ size: UI.fontBody }).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onSelect((index: number) => { this.inputMode = index === 0 ? 'new' : (index === 1 ? 'document' : 'selection'); this.invalidatePreview(); this.persistDraft(); })
        }.width('100%')
        Text('脚本在隔离副本中运行；先预览，再决定载入或合并。').fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(18)
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 8 }) {
        Text('描述版图需求').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
        TextArea({ text: this.requestText, placeholder: '例如：生成圆孔光子晶体阵列，周期 500nm，孔半径 120nm，保留 Cell 层级。' })
          .height(56).width('100%').fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => { this.requestText = value; this.persistDraft(); })
        Row({ space: 8 }) {
          Blank()
          Button('AI 生成并运行', { type: ButtonType.Normal }).fontSize(UI.fontBody).height(UI.controlHeight).width(this.panelWidth < 440 ? 148 : 164)
            .enabled(!this.busy).borderRadius(UI.controlRadius).fontColor(Color.White).backgroundColor(COLORS.primary).onClick(() => this.run(true))
          Button('示例脚本', { type: ButtonType.Normal }).fontSize(UI.fontBody).height(UI.controlHeight).padding({ left: 8, right: 8 }).enabled(!this.busy)
            .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
            .onClick(() => {
              this.script = this.inputMode === 'new' ? SAMPLE_SCRIPT :
                "import hongtu as db\ndx = round(params.get('dx', 100) / (layout.dbu * 1000))\ncurrent_cell.transform(db.Trans(dx, 0))";
              this.invalidatePreview(); this.persistDraft();
            })
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 8 }) {
        Row() {
          Text('Python 脚本').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
          Text(this.inputMode === 'new' ? '1 DBU = 1nm' : '保留原文档 DBU').fontSize(UI.fontCaption).fontColor(COLORS.muted)
        }.width('100%')
        TextArea({ text: this.script, placeholder: 'import hongtu as db\nlayout = db.Layout()' })
          .height(180).width('100%').fontSize(12).fontFamily('monospace').fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).enabled(!this.busy)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => { this.script = value; this.invalidatePreview(); this.persistDraft(); })

      }.width('100%').alignItems(HorizontalAlign.Start)
      Column({ space: 8 }) {
        Text('参数与扫参').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
        TextArea({ text: this.parametersText, placeholder: '参数 JSON，例如 {"pitch":500}' })
          .height(60).width('100%').fontSize(12).enabled(!this.busy).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => event.stopPropagation()).onChange((value: string) => { this.parametersText = value; this.invalidatePreview(); this.persistDraft(); })
        Row({ space: 8 }) {
          TextInput({ text: this.sweepName, placeholder: '扫参名称（可空）' }).layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody)
            .fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
            .onKeyEvent((event: KeyEvent) => event.stopPropagation()).enabled(!this.busy).onChange((value: string) => { this.sweepName = value; this.persistDraft(); })
          TextInput({ text: this.sweepValues, placeholder: '400,500,600' }).layoutWeight(2).height(UI.fieldHeight).fontSize(UI.fontBody)
            .fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
            .onKeyEvent((event: KeyEvent) => event.stopPropagation()).enabled(!this.busy).onChange((value: string) => { this.sweepValues = value; this.persistDraft(); })
        }.width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
      Row({ space: 8 }) {
          Button('打开脚本', { type: ButtonType.Normal }).fontSize(UI.fontBody).height(UI.controlHeight).padding({ left: 8, right: 8 }).enabled(!this.busy)
            .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.scriptFile(true))
          Button('导出脚本', { type: ButtonType.Normal }).fontSize(UI.fontBody).height(UI.controlHeight).padding({ left: 8, right: 8 }).enabled(!this.busy)
            .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.scriptFile(false))
        Blank()
        Button('运行脚本', { type: ButtonType.Normal }).height(UI.controlHeight).width(this.panelWidth < 440 ? 96 : 120).fontSize(UI.fontBody).enabled(!this.busy)
          .borderRadius(UI.controlRadius).backgroundColor(COLORS.primary).fontColor(Color.White).onClick(() => this.run(false))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  ResultSection() {
    if (this.previewPath.length > 0 || this.readyPath.length > 0) {
      Column({ space: 12 }) {
        Text('结果预览').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
        if (this.previewPath.length > 0) {
          Image('file://' + this.previewPath).width('100%').height(220).objectFit(ImageFit.Contain)
            .backgroundColor(Color.White).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        }
        if (this.readyPath.length > 0) {
          Text(this.previewSummary).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').lineHeight(20)
          Row({ space: 8 }) {
            Button('载入版图', { type: ButtonType.Normal }).height(UI.controlHeight).width(this.panelWidth < 440 ? 100 : 140).fontSize(UI.fontBody).enabled(!this.busy)
              .borderRadius(UI.controlRadius).fontColor(Color.White).backgroundColor(COLORS.primary).onClick(() => this.loadGenerated())
            if (this.loadResultAction !== undefined && this.artifact?.inputMode !== 'document') {
              Button('合并到当前版图', { type: ButtonType.Normal }).height(UI.controlHeight).layoutWeight(1).fontSize(UI.fontBody).enabled(!this.busy)
                .borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).onClick(() => this.loadGenerated('merge'))
            }
          }.width('100%')
        }
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    } else if (!this.showHistory) {
      Column({ space: 8 }) {
        Text('结果预览').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        Text('运行后将在此显示真实结果预览。').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          .width('100%').height(72).textAlign(TextAlign.Center).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      }.width('100%').alignItems(HorizontalAlign.Start).padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }
  }
}
