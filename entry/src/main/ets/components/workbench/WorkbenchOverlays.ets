import { dialogTransition } from '../../common/Motion';
import { SettingsToggleRow } from '../SettingsKit';
import { StableSegmentButton } from '../StableSegmentButton';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { HdsColorPicker, HdsColorPickerTabType } from '@kit.UIDesignKit';
import { CounterComponent, CounterType, SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { hongTuThemeState } from '../../store/ThemeStore';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { showAppSnackBar } from '../AppSnackBar';
import { UiLayer } from '../../common/types';
import { RecentFile } from '../../workbench/WorkbenchModels';
import {
  aiService,
  AiModelConfig,
  AiProviderProfile,
  AiSavedModel,
  AiDiscoveredModelSpec,
  AiReasoningEffort,
  inferAiModelContextWindow,
  createDefaultConfig,
  AiProvider,
  PRESET_PROVIDERS,
  PresetProvider,
  TestConnectionResult,
  ChatMessage,
  ChatRole,
  AiChatToolState,
  AiConversationSummary,
  AiContextOptions,
  ParsedCommand,
} from '../../services/AiService';
import { Macro, macroService } from '../../services/MacroService';
import { MacroManagerDialog } from '../dialogs/MacroManagerDialog';
import { shortcutService, ShortcutEntry } from '../../services/ShortcutService';
import { COLORS, LAYER_NAME_MAP } from '../../common/constants';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { Shape, ShapeType, getShapeBounds } from '../../models/GdsiiData';
import { editService } from '../../services/EditService';
import { WorkbenchIcon } from './WorkbenchIcon';
import { PanelHeading } from './PanelHeading';
import { AiMarkdownBody } from './AiMarkdownBody';
import {
  AiExtractedThinking,
  AiSlashCommandSpec,
  AiTokenMeterState,
  AiToolField,
  AiToolPresentation,
  computeDraftAwareTokenMeter,
  describeAiToolCall,
  exportConversationAsMarkdown,
  formatCompactTokens,
  formatRelativeConversationTime,
  matchAiSlashCommands,
  parseAiTokenMeter,
  reasoningEffortLabel,
  splitInlineThinking
} from '../../services/AiAgentPresentation';
import { pythonBridgeService } from '../../services/PythonBridgeService';
import { aiHarnessService } from '../../services/AiHarnessService';
import type { AiReviewGroup } from '../../services/AiReviewGroups';
import { ProfileImportDialog } from '../dialogs/ProfileImportDialog';
import { ALPHA, Elevation, RADIUS, SHADOW_BY_ELEVATION, withAlpha, layerRenderStyle } from '../../common/MaterialTokens';
import { UI } from '../../common/UiTokens';
import { motionDuration, MOTION, panelTransition } from '../../common/Motion';
import { cloneStructured, cloneUiLayerModel } from '../../common/CloneUtils';

interface AiPlanStepView {
  id: string;
  content: string;
  status: string;
}

interface AiPendingFieldRow {
  label: string;
  value: string;
  accent: boolean;
}

interface AiReviewGroupRowSpec {
  group: AiReviewGroup;
  accepted: boolean;
}

@Component
export struct AiAssistantPanel {
  closeAction: () => void = () => {};
  minimizeAction: () => void = () => {};
  openPythonAction: () => void = () => {};
  openAgentConnectionAction: () => void = () => {};
  promptAction: (prompt: string, resumeTask?: boolean, forceReadOnly?: boolean) => void = () => {};
  @Prop sessionMode: 'agent' | 'readonly' = 'agent';
  toggleSessionModeAction: () => void = () => {};
  /** 当前上下文摘要（由 Index 构造传入，替代硬编码） */
  @Prop contextSummary: string = '';
  @Prop conversations: AiConversationSummary[] = [];
  @Prop @Watch('onActiveConversationChange') activeConversationId: string = '';
  @Prop contextOptions: AiContextOptions = { includeHistory: true, includeLayout: true, includeSelection: true };
  @Prop contextUsageSummary: string = '';
  @Prop compressionSummary: string = '';
  @Prop contextDetail: string = '';
  @Prop checkpointSummary: string = '';
  @Prop hasRecoverableArtifact: boolean = false;
  @Prop reviewGroups: AiReviewGroup[] = [];
  toggleReviewGroupAction: (id: string, accepted: boolean) => void = () => {};
  focusReviewAction: () => void = () => {};
  @Prop projectNote: string = '';
  @Prop @Watch('onProjectChange') projectIdentity: string = '';
  saveProjectNoteAction: (text: string) => boolean = () => false;
  analyzeResultAction: () => void = () => {};
  recoverArtifactAction: () => void = () => {};
  @State projectNoteDraft: string = '';
  @State projectNoteEditing: boolean = false;
  @State showTaskTemplate: boolean = false;
  @State templateRows: string = '2';
  @State templateColumns: string = '4';
  @State templatePitch: string = '1000';
  newConversationAction: () => void = () => {};
  switchConversationAction: (id: string) => void = () => {};
  renameConversationAction: (id: string, title: string) => void = () => {};
  deleteConversationAction: (id: string) => void = () => {};
  clearConversationAction: () => void = () => {};
  setContextOptionsAction: (options: AiContextOptions) => void = () => {};
  compressConversationAction: () => void = () => {};
  clearCompressionAction: () => void = () => {};
  configChangedAction: () => void = () => {};
  /** 紧凑模式（sm 手机端）：收窄宽度并重定位到左上角，避免溢出窄屏） */
  @Prop isCompact: boolean = false;
  /** 桌面助手由父页面放置在画布右侧，不占用常驻检查器宽度。 */
  @Prop desktopMode: boolean = false;
  @Prop panelWidth: number = 420;
  @Prop panelHeight: number = 640;
  @Prop fileName: string = '';
  @Prop cellName: string = '';
  @Prop topCellName: string = '';
  @Prop selectionCount: number = 0;
  @Prop @Watch('onPendingChange') pendingSummary: string = '';
  @Prop pendingDetail: string = '';
  @Prop lastResult: string = '';
  @Prop canUndo: boolean = false;
  applyPendingAction: () => void = () => {};
  cancelPendingAction: () => void = () => {};
  undoAction: () => void = () => {};
  /** AI-10: 聊天消息列表（由 Index 从 aiService.getChatHistory 传入） */
  @Prop @Watch('onConversationChange') messages: ChatMessage[] = [];
  /** AI-11: 加载状态指示 */
  @Prop @Watch('onLoadingChange') isLoading: boolean = false;
  @Prop canCancel: boolean = false;
  @Prop generationStatus: string = '';
  cancelGenerationAction: () => void = () => {};
  /** AI-11: 错误信息 */
  @Prop errorMessage: string = '';
  /** AI-15: 流式增量文本（onChunk 累加，空字符串表示无流式输出） */
  @Prop streamingText: string = '';
  @Prop reasoningText: string = '';
  @Prop toolCalls: AiChatToolState[] = [];
  @State expandedReasoning: string[] = [];
  @State expandedTools: string[] = [];
  @State expandedTraces: string[] = [];
  @State expandedRawTools: string[] = [];
  @State slashMenuForced: boolean = false;
  /** 自由输入文本 */
  @State inputText: string = '';
  @State showQuickActions: boolean = true;
  @State showPendingRawDetail: boolean = false;
  @State showSettings: boolean = false;
  @State showConversations: boolean = false;
  @State showContext: boolean = false;
  @State conversationSearch: string = '';
  @State renamingConversationId: string = '';
  @State conversationTitleText: string = '';
  @State managementStatus: string = '';
  @State managementStatusKind: 'info' | 'error' = 'error';
  // OVERLAY-2: 初始值设为 0 避免 PRESET_PROVIDERS 长度不足时越界，aboutToAppear 会修正为实际配置
  @State selectedProviderIndex: number = 0;
  @State providerValue: AiProvider = AiProvider.DEMO_MODE;
  @State endpointText: string = '';
  @State modelNameText: string = 'hongtu-demo';
  @State apiKeyText: string = '';
  @State temperatureText: string = '0.3';
  @State maxTokensText: string = '2048';
  @State timeoutSecondsText: string = '30';
  @State contextWindowText: string = '32768';
  @State compressionThresholdText: string = '80';
  @State autoCompressValue: boolean = false;
  @State configBusy: boolean = false;
  @State testStatusText: string = '';
  @State providerProfiles: AiProviderProfile[] = [];
  @State selectedProfileId: string = '';
  @State selectedModelId: string = '';
  @State profileNameText: string = '';
  @State modelsEndpointText: string = '';
  @State discoveredModels: string[] = [];
  @State discoveredCatalog: AiDiscoveredModelSpec[] = [];
  @State catalogSearchText: string = '';
  @State catalogCategory: string = '全部';
  @State manualNewModelText: string = '';
  @State pendingDraftModels: string[] = [];
  @State showAdvancedModelsUrl: boolean = false;
  @State showPresetTemplates: boolean = false;
  @State showQuickModelPicker: boolean = false;
  @State quickModelSearch: string = '';
  @State reasoningEffortValue: AiReasoningEffort = 'auto';
  @State autoExpandThinking: boolean = true;
  @State collapsedThinkingKeys: string[] = [];
  @State showCompressedSummaryText: boolean = false;
  @State contextCustomWindowText: string = '';
  @State discoveryBusy: boolean = false;
  @State agentConnectionText: string = 'Agent 连接尚未检查';
  @State connectionBusy: boolean = false;
  @State configEnabled: boolean = true;
  @State credentialReady: boolean = false;
  private panelDisposed: boolean = false;
  private discoveryTicket: number = 0;
  private credentialReloadTicket: number = 0;
  private diagnosticRunning: boolean = false;
  private conversationScroller: Scroller = new Scroller();
  private liveThinkingScroller: Scroller = new Scroller();
  private chatViewportHeight: number = 0;
  private chatContentHeight: number = 0;
  private liveThinkingViewportHeight: number = 0;
  private liveThinkingContentHeight: number = 0;
  @State followsLatest: boolean = true;
  private userScrollPending: boolean = false;
  private scrollRequestTimer: number = -1;
  private composerShiftHeld: boolean = false;

  aboutToAppear(): void {
    this.panelDisposed = false;
    PersistentStorage.persistProp('hongtu_ai_auto_expand_thinking', true);
    this.autoExpandThinking = AppStorage.get<boolean>('hongtu_ai_auto_expand_thinking') ?? true;
    aiService.ensureReady().then(() => {
      if (this.panelDisposed) return;
      this.loadConfigFields();
      this.testStatusText = aiService.getCredentialError();
      this.refreshAgentConnection();
    });
  }

  aboutToDisappear(): void {
    this.panelDisposed = true;
    if (this.diagnosticRunning) aiHarnessService.cancelAndConfirm();
    this.discoveryTicket++;
    this.credentialReloadTicket++;
    aiService.cancelModelDiscovery();
    this.configBusy = false; this.discoveryBusy = false;
    this.apiKeyText = '';
    if (this.scrollRequestTimer >= 0) {
      clearTimeout(this.scrollRequestTimer);
      this.scrollRequestTimer = -1;
    }
  }

  onConversationChange(): void {
    this.scrollConversationToLatest();
  }

  onProjectChange(): void {
    this.projectNoteDraft = ''; this.projectNoteEditing = false;
  }

  onActiveConversationChange(): void {
    this.inputText = '';
    this.expandedReasoning = [];
    this.expandedTools = [];
    this.renamingConversationId = '';
    this.conversationTitleText = '';
    this.managementStatus = '';
    this.followsLatest = true;
    this.scrollConversationToLatest();
  }

  onLoadingChange(): void {
    if (!this.isLoading) return;
    this.collapsedThinkingKeys = this.collapsedThinkingKeys.filter((key: string): boolean => key !== 'live:thinking');
    this.expandedTools = this.expandedTools.filter((key: string): boolean => !key.startsWith('0:'));
  }

  onPendingChange(): void {
    this.showPendingRawDetail = false;
    if (this.pendingSummary.length > 0 && !this.showSettings && !this.showConversations && !this.showContext) {
      this.followsLatest = true;
    }
    this.scrollConversationToLatest();
  }

  private pinConversationToBottomInstant(): void {
    if (this.panelDisposed || !this.followsLatest || this.showConversations || this.showContext || this.showSettings) {
      return;
    }
    try {
      if (this.chatContentHeight > 0 && this.chatViewportHeight > 0) {
        const targetY: number = Math.max(0, this.chatContentHeight - this.chatViewportHeight);
        this.conversationScroller.scrollTo({ xOffset: 0, yOffset: targetY, animation: false });
      } else {
        this.conversationScroller.scrollEdge(Edge.Bottom);
      }
    } catch (_) {}
  }

  private scrollConversationToLatest(): void {
    if (!this.followsLatest) {
      return;
    }
    this.pinConversationToBottomInstant();
    if (this.scrollRequestTimer >= 0) {
      clearTimeout(this.scrollRequestTimer);
    }
    this.scrollRequestTimer = setTimeout(() => {
      this.scrollRequestTimer = -1;
      this.pinConversationToBottomInstant();
    }, 16);
  }

  private toggleDesktopSettings(): void {
    this.showConversations = false;
    this.showContext = false;
    animateTo({ duration: motionDuration(MOTION.panel), curve: Curve.EaseOut }, () => {
      this.showSettings = !this.showSettings;
    });
    if (!this.showSettings) {
      this.followsLatest = true;
      this.scrollConversationToLatest();
      return;
    }
    this.followsLatest = false;
    if (this.scrollRequestTimer >= 0) {
      clearTimeout(this.scrollRequestTimer);
    }
    this.scrollRequestTimer = setTimeout(() => {
      this.scrollRequestTimer = -1;
      this.conversationScroller.scrollEdge(Edge.Top);
    }, 0);
  }

  private commandStatusLabel(message: ChatMessage): string {
    if (message.runStatus === 'cancelled') return '已取消等待，任务未完成';
    if (message.runStatus === 'failed') return '任务未完成';
    if (message.commandStatus === 'executed') {
      return '命令已执行';
    }
    if (message.commandStatus === 'failed') {
      return '命令执行失败';
    }
    if (!this.desktopMode) {
      return '… 命令待执行';
    }
    if (this.pendingSummary.length > 0) {
      for (let i: number = this.messages.length - 1; i >= 0; i--) {
        const candidate: ChatMessage = this.messages[i];
        if (candidate.isCommand && candidate.commandStatus === 'pending') {
          if (candidate.timestamp === message.timestamp && candidate.content === message.content) {
            return '待确认修改';
          }
          break;
        }
      }
    }
    return '历史方案';
  }

  private messageText(message: ChatMessage): string {
    if (!message.isCommand || message.role !== ChatRole.ASSISTANT) {
      return message.content;
    }
    const trimmed: string = message.content.trim();
    if (!trimmed.startsWith('[') && !trimmed.startsWith('{') && !trimmed.startsWith('```')) {
      return message.content;
    }
    const start: number = message.content.indexOf('[');
    const end: number = message.content.lastIndexOf(']');
    if (start < 0 || end <= start) {
      return message.content;
    }
    try {
      const commands: ParsedCommand[] = JSON.parse(message.content.substring(start, end + 1)) as ParsedCommand[];
      const descriptions: string[] = [];
      for (const command of commands) {
        if (typeof command.description === 'string' && command.description.length > 0) {
          descriptions.push(`- ${command.description}`);
        }
      }
      return descriptions.length > 0 ? `修改方案\n${descriptions.join('\n')}` : '已生成版图操作方案。';
    } catch (_) {
      return message.content;
    }
  }

  private loadConfigFields(preserveCatalog: boolean = false): void {
    if (!preserveCatalog) {
      this.discoveryTicket++;
      this.discoveredModels = [];
      this.discoveredCatalog = [];
    }
    this.providerProfiles = aiService.getProviderProfiles();
    this.selectedProfileId = aiService.getActiveProfileId();
    this.credentialReady = aiService.isProviderCredentialReady(this.selectedProfileId);
    const profile = this.providerProfiles.find((item: AiProviderProfile): boolean => item.id === this.selectedProfileId);
    this.selectedModelId = profile?.activeModelId ?? '';
    this.profileNameText = profile?.name ?? '';
    this.modelsEndpointText = profile?.modelsEndpoint ?? '';
    this.showAdvancedModelsUrl = this.modelsEndpointText.trim().length > 0;
    this.pendingDraftModels = [];
    const config: AiModelConfig = aiService.getConfig();
    this.fillConfigFields(config);
  }

  private fillConfigFields(config: AiModelConfig): void {
    this.providerValue = config.provider;
    this.endpointText = config.endpoint;
    this.modelNameText = config.modelName;
    this.apiKeyText = config.apiKey;
    this.temperatureText = String(config.temperature);
    this.maxTokensText = String(config.maxTokens);
    this.timeoutSecondsText = String(config.timeoutMs / 1000);
    this.contextWindowText = String(config.contextWindowTokens ?? 32768);
    this.contextCustomWindowText = String(config.contextWindowTokens ?? 32768);
    this.compressionThresholdText = String(Math.round((config.compressionThreshold ?? 0.8) * 100));
    this.autoCompressValue = config.autoCompress ?? false;
    this.reasoningEffortValue = config.reasoningEffort ?? 'auto';
    this.configEnabled = config.enabled;
    this.selectedProviderIndex = this.indexForProvider(config);
  }

  private profileOptions(): SelectOption[] {
    return this.providerProfiles.map((item: AiProviderProfile): SelectOption => ({ value: item.name }));
  }
  private selectedProfileIndex(): number {
    return this.providerProfiles.findIndex((item: AiProviderProfile): boolean => item.id === this.selectedProfileId);
  }
  private savedModels(): AiSavedModel[] {
    return this.providerProfiles.find((item: AiProviderProfile): boolean => item.id === this.selectedProfileId)?.models ?? [];
  }
  private savedModelOptions(): SelectOption[] {
    return this.savedModels().map((item: AiSavedModel): SelectOption => ({ value: item.config.modelName }));
  }
  private selectedModelIndex(): number {
    return this.savedModels().findIndex((item: AiSavedModel): boolean => item.id === this.selectedModelId);
  }
  private async switchProviderModel(profileId: string, modelId: string = ''): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true;
    try {
      await aiService.selectProviderModel(profileId, modelId);
      if (!this.panelDisposed) { this.loadConfigFields(); this.configChangedAction(); this.testStatusText = '已切换到保存的供应商与模型'; }
    } catch (error) { if (!this.panelDisposed) this.testStatusText = error instanceof Error ? error.message : '切换失败'; }
    finally { this.configBusy = false; }
  }
  private newProviderDraft(): void {
    if (this.isLoading || this.configBusy) return;
    this.discoveryTicket++;
    this.selectedProfileId = ''; this.selectedModelId = ''; this.profileNameText = '';
    this.modelsEndpointText = ''; this.discoveredModels = []; this.discoveredCatalog = [];
    this.pendingDraftModels = [];
    this.showPresetTemplates = true;
    this.testStatusText = '点选上方预设服务商或填写地址与密钥，随后可获取并添加模型';
    const draft: AiModelConfig = createDefaultConfig();
    draft.provider = AiProvider.OPENAI_COMPATIBLE;
    draft.modelName = '';
    this.fillConfigFields(draft);
  }
  private newModelDraft(): void {
    if (this.isLoading || this.configBusy) return;
    this.selectedModelId = ''; this.modelNameText = ''; this.testStatusText = '填写新模型 ID 后保存，现有模型保留';
  }
  private deleteProviderOrModel(modelOnly: boolean, explicitModelId: string = ''): void {
    if (this.isLoading || this.configBusy || this.selectedProfileId.length === 0) return;
    const profileId: string = this.selectedProfileId;
    const modelId: string = modelOnly ? (explicitModelId.length > 0 ? explicitModelId : this.selectedModelId) : '';
    if (modelOnly && modelId.length === 0) return;
    AlertDialog.show({ title: modelOnly ? '移除该模型' : '删除供应商',
      message: modelOnly ? '从当前供应商移除该模型？会话历史不受影响。' : '删除该供应商及其系统凭据？会话历史不受影响。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => { this.removeProviderOrModel(profileId, modelId); } } });
  }
  private async removeProviderOrModel(profileId: string, modelId: string): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true;
    try {
      await aiService.deleteProviderModel(profileId, modelId);
      if (!this.panelDisposed) { this.loadConfigFields(modelId.length > 0); this.configChangedAction(); this.testStatusText = '已移除'; }
    } catch (error) { if (!this.panelDisposed) this.testStatusText = error instanceof Error ? error.message : '删除失败'; }
    finally { this.configBusy = false; }
  }
  private async fetchModels(): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true; this.discoveryBusy = true; this.discoveredModels = []; this.discoveredCatalog = [];
    this.catalogSearchText = ''; this.catalogCategory = '全部';
    const ticket: number = ++this.discoveryTicket;
    const fingerprint: string = this.modelDiscoveryFingerprint();
    this.testStatusText = '正在请求远端模型目录…';
    try {
      const result = await aiService.discoverModels(this.modelDiscoveryConfigFromFields(), this.modelsEndpointText);
      if (!this.panelDisposed && ticket === this.discoveryTicket && fingerprint === this.modelDiscoveryFingerprint()) {
        this.discoveredModels = result.modelIds;
        this.discoveredCatalog = result.catalog ?? result.modelIds.map((id: string): AiDiscoveredModelSpec => ({
          id,
          displayName: id,
          contextWindow: inferAiModelContextWindow(id, 0),
          categories: ['文本'],
          supportsThinking: false,
          windowInferred: true
        }));
        this.testStatusText = result.modelIds.length > 0
          ? `已获取 ${result.modelIds.length} 个远端模型，可搜索并点击「+ 添加」加入当前供应商`
          : '服务返回空模型目录，请在上方输入框手动添加模型 ID';
      }
      else if (!this.panelDisposed && ticket === this.discoveryTicket) this.testStatusText = '连接字段已变动，请重新获取模型目录';
    } catch (error) { if (!this.panelDisposed && ticket === this.discoveryTicket) this.testStatusText = error instanceof Error ? error.message : '模型目录获取失败'; }
    finally { if (ticket === this.discoveryTicket) { this.configBusy = false; this.discoveryBusy = false; } }
  }
  private modelDiscoveryFingerprint(): string {
    // In-memory only. This snapshot is never persisted, logged or shown.
    return JSON.stringify([this.selectedProfileId, this.providerValue, this.endpointText, this.modelsEndpointText, this.apiKeyText]);
  }
  private discoveredModelOptions(): SelectOption[] {
    return this.discoveredModels.map((id: string): SelectOption => ({ value: id }));
  }
  private chooseDiscoveredModel(index: number): void {
    if (this.isLoading || this.configBusy || index < 0 || index >= this.discoveredModels.length) return;
    const modelName: string = this.discoveredModels[index];
    const saved = this.savedModels().find((item: AiSavedModel): boolean => item.config.modelName === modelName);
    // Discovery edits the current draft. Loading a saved config here would discard
    // the endpoint/key and tuning that produced this list, and activate old values.
    this.selectedModelId = saved?.id ?? '';
    this.modelNameText = modelName;
    this.testStatusText = saved !== undefined ? '已选择保存的模型 ID，连接与参数草稿保留；保存配置后启用' :
      '已选择新模型 ID，连接与参数草稿保留；保存配置后启用';
  }

  private latestUserPrompt(): string {
    for (let index: number = this.messages.length - 1; index >= 0; index--) {
      if (this.messages[index].role === ChatRole.USER) return this.messages[index].content;
    }
    return '';
  }
  private async refreshAgentConnection(check: boolean = false): Promise<void> {
    if (this.connectionBusy || this.isLoading) return;
    this.connectionBusy = true;
    try {
      const config = await pythonBridgeService.loadConfig();
      if (this.panelDisposed) return;
      if (config.token.length === 0) { this.agentConnectionText = 'Agent 未连接：打开连接设置填写伴随服务地址与令牌'; return; }
      this.agentConnectionText = check ? '正在检查 Agent 连接…' : 'Agent 连接已配置，尚未检查服务是否在线';
      if (check) {
        await pythonBridgeService.checkConnection(true);
        if (!this.panelDisposed) this.agentConnectionText = 'Agent 伴随服务连接通过；模型和工具执行在任务运行时验证';
      }
    } catch (_) { if (!this.panelDisposed) this.agentConnectionText = 'Agent 连接未通过：打开连接设置检查服务、地址与令牌，再重试任务'; }
    finally { this.connectionBusy = false; }
  }
  private activeModelLabel(): string {
    const config: AiModelConfig = aiService.getConfig();
    const profile = this.providerProfiles.find((item: AiProviderProfile): boolean => item.id === aiService.getActiveProfileId());
    return config.provider === AiProvider.DEMO_MODE ? '本地演示指令' : `Agent · ${profile?.name ?? '供应商'} · ${config.modelName}`;
  }
  private continueAgent(retry: boolean): void {
    if (this.isLoading || this.configBusy || this.pendingSummary.length > 0 || !this.contextOptions.includeHistory) return;
    const goal: string = retry ? '重试上一次未完成的部分，以上一轮用户请求为目标。' : '继续上一次尚未完成的任务。';
    this.inputText = goal + '先检查当前版图与历史中的实际工具结果；已载入版图或已应用的动作不要重复执行，包括删除、移动和创建。仅生成但因中断未载入的版图可重新生成；生成成功不代表已载入。待应用提案不代表已执行，需等待用户确认。若目标已完成，说明实际状态即可。';
    this.sendInput(true);
  }

  private async diagnoseAgent(): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true; this.diagnosticRunning = true;
    this.testStatusText = '正在进行只读工具诊断，会实际调用当前草稿模型…';
    try {
      const config: AiModelConfig = this.currentConfigFromFields();
      const result: string = await aiHarnessService.diagnose(config);
      if (!this.panelDisposed) this.testStatusText = result;
    } catch (error) { if (!this.panelDisposed) this.testStatusText = error instanceof Error ? error.message : String(error); }
    finally { this.diagnosticRunning = false; if (!this.panelDisposed) this.configBusy = false; }
  }

  private fillArrayTemplate(): void {
    const rows: number = Number(this.templateRows), columns: number = Number(this.templateColumns), pitch: number = Number(this.templatePitch);
    if (!Number.isInteger(rows) || !Number.isInteger(columns) || rows < 1 || columns < 1 || rows > 1000 || columns > 1000 || rows * columns > 10000 ||
      !Number.isFinite(pitch) || pitch <= 0 || pitch > 1e9) {
      this.managementStatusKind = 'error';
      this.managementStatus = '行列须为正整数、总数不超过10000，间距须为有效正数（nm）';
      return;
    }
    this.managementStatus = '';
    this.inputText = `将当前选区复制为 ${rows} 行 × ${columns} 列阵列，X/Y间距均为 ${pitch} nm。先核对当前Cell、图层与选区，提出预览方案，保留原图并作为一次可撤销操作。`;
    this.showTaskTemplate = false;
  }

  private indexForProvider(config: AiModelConfig): number {
    for (let i = 0; i < PRESET_PROVIDERS.length; i++) {
      const preset: PresetProvider = PRESET_PROVIDERS[i];
      if (preset.config.provider === config.provider &&
        preset.config.endpoint === config.endpoint &&
        preset.config.modelName === config.modelName) {
        return i;
      }
    }
    return -1;
  }

  private providerOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < PRESET_PROVIDERS.length; i++) {
      const option: SelectOption = { value: PRESET_PROVIDERS[i].name };
      options.push(option);
    }
    return options;
  }

  private selectedProviderName(): string {
    if (this.selectedProviderIndex >= 0 && this.selectedProviderIndex < PRESET_PROVIDERS.length) {
      return PRESET_PROVIDERS[this.selectedProviderIndex].name;
    }
    return '自定义连接（可选模板）';
  }

  private applyProviderPreset(index: number): void {
    if (index < 0 || index >= PRESET_PROVIDERS.length) {
      return;
    }
    const preset: PresetProvider = PRESET_PROVIDERS[index];
    this.discoveryTicket++;
    this.apiKeyText = ''; this.modelsEndpointText = ''; this.discoveredModels = []; this.discoveredCatalog = [];
    this.selectedProviderIndex = index;
    if (this.selectedProfileId.length === 0 || this.profileNameText.trim().length === 0) {
      this.profileNameText = preset.name;
    }
    if (preset.config.provider !== undefined) {
      this.providerValue = preset.config.provider;
    }
    if (preset.config.endpoint !== undefined) {
      this.endpointText = preset.config.endpoint;
    }
    if (preset.config.modelName !== undefined) {
      this.modelNameText = preset.config.modelName;
      this.selectedModelId = '';
    }
    if (preset.config.contextWindowTokens !== undefined) {
      this.contextWindowText = String(preset.config.contextWindowTokens);
    }
    if (preset.config.maxTokens !== undefined) {
      this.maxTokensText = String(preset.config.maxTokens);
    }
    if (this.providerValue === AiProvider.DEMO_MODE) {
      this.apiKeyText = '';
    }
    this.showPresetTemplates = false;
    this.testStatusText = `已填入「${preset.name}」预设，填写 API Key 后即可获取模型或保存`;
  }

  private applyWindowPresetInSettings(tokens: number): void {
    this.contextWindowText = String(tokens);
    const curMax: number = Number(this.maxTokensText.trim());
    if (Number.isFinite(curMax) && curMax + 6000 >= tokens) {
      this.maxTokensText = String(Math.max(512, tokens - 6500));
    }
  }

  private filteredCatalogModels(): AiDiscoveredModelSpec[] {
    const q: string = this.catalogSearchText.trim().toLowerCase();
    const cat: string = this.catalogCategory;
    return this.discoveredCatalog.filter((spec: AiDiscoveredModelSpec): boolean => {
      if (cat !== '全部' && !spec.categories.includes(cat)) return false;
      if (q.length === 0) return true;
      return spec.id.toLowerCase().includes(q) || spec.displayName.toLowerCase().includes(q);
    });
  }

  private isModelSavedInCurrentDraft(modelId: string): boolean {
    if (this.savedModels().some((m: AiSavedModel): boolean => m.config.modelName === modelId)) return true;
    return this.pendingDraftModels.includes(modelId);
  }

  private async addModelFromInputOrCatalog(modelId: string, suggestedWindow: number = 0, activateNow: boolean = true): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    const clean: string = modelId.trim();
    if (clean.length === 0) {
      this.testStatusText = '请先输入要添加的模型 ID';
      return;
    }
    const inferredWin: number = inferAiModelContextWindow(clean, suggestedWindow);
    if (this.selectedProfileId.length === 0) {
      if (!this.pendingDraftModels.includes(clean)) {
        this.pendingDraftModels = this.pendingDraftModels.concat([clean]);
      }
      if (activateNow || this.modelNameText.trim().length === 0) {
        this.modelNameText = clean;
        this.applyWindowPresetInSettings(inferredWin);
      }
      this.manualNewModelText = '';
      this.testStatusText = `已将「${clean}」加入待保存列表（共 ${this.pendingDraftModels.length} 个），点击底部「保存配置」即可落盘`;
      return;
    }
    this.configBusy = true;
    try {
      await aiService.addModelToProvider(this.selectedProfileId, clean, inferredWin, activateNow);
      if (!this.panelDisposed) {
        this.loadConfigFields(true);
        this.manualNewModelText = '';
        this.configChangedAction();
        this.testStatusText = activateNow
          ? `已添加并切换到模型「${clean}」（窗口 ${formatCompactTokens(inferredWin)}）`
          : `已添加模型「${clean}」到当前供应商`;
        showAppSnackBar(this.getUIContext(), `已添加模型 ${clean}`);
      }
    } catch (error) {
      if (!this.panelDisposed) {
        this.testStatusText = error instanceof Error ? error.message : String(error);
      }
    } finally {
      this.configBusy = false;
    }
  }

  private async batchAddFilteredCatalogModels(): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    const candidates: AiDiscoveredModelSpec[] = this.filteredCatalogModels()
      .filter((spec: AiDiscoveredModelSpec): boolean => !this.isModelSavedInCurrentDraft(spec.id))
      .slice(0, 8);
    if (candidates.length === 0) {
      this.testStatusText = '当前筛选结果中的模型均已添加';
      return;
    }
    if (this.selectedProfileId.length === 0) {
      for (let i = 0; i < candidates.length; i++) {
        if (!this.pendingDraftModels.includes(candidates[i].id)) {
          this.pendingDraftModels = this.pendingDraftModels.concat([candidates[i].id]);
        }
      }
      if (this.modelNameText.trim().length === 0) {
        this.modelNameText = candidates[0].id;
        this.applyWindowPresetInSettings(candidates[0].contextWindow);
      }
      this.testStatusText = `已暂存 ${candidates.length} 个模型，点击「保存配置」完成创建`;
      return;
    }
    this.configBusy = true;
    try {
      const count: number = await aiService.addModelsBatchToProvider(this.selectedProfileId, candidates);
      if (!this.panelDisposed) {
        this.loadConfigFields(true);
        this.configChangedAction();
        this.testStatusText = `已批量添加 ${count} 个模型至当前供应商`;
        showAppSnackBar(this.getUIContext(), `已批量添加 ${count} 个模型`);
      }
    } catch (error) {
      if (!this.panelDisposed) this.testStatusText = error instanceof Error ? error.message : String(error);
    } finally {
      this.configBusy = false;
    }
  }

  private async quickSelectModel(profileId: string, modelId: string): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true;
    try {
      await aiService.selectProviderModel(profileId, modelId);
      if (!this.panelDisposed) {
        this.loadConfigFields(false);
        this.configChangedAction();
        this.showQuickModelPicker = false;
        showAppSnackBar(this.getUIContext(), `已切换至 ${aiService.getConfig().modelName}`);
      }
    } catch (error) {
      if (!this.panelDisposed) {
        showAppSnackBar(this.getUIContext(), error instanceof Error ? error.message : '模型切换失败');
      }
    } finally {
      this.configBusy = false;
    }
  }

  private async quickSetReasoningEffort(effort: AiReasoningEffort): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.reasoningEffortValue = effort;
    if (this.selectedProfileId.length === 0) return;
    this.configBusy = true;
    try {
      await aiService.setReasoningEffort(effort);
      if (!this.panelDisposed) {
        this.configChangedAction();
      }
    } catch (_) {}
    finally {
      this.configBusy = false;
    }
  }

  private async quickApplyContextPolicy(newWindow?: number, newThresholdPct?: number, newAutoCompress?: boolean): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    const cfg: AiModelConfig = aiService.getConfig();
    const targetWin: number = newWindow ?? (cfg.contextWindowTokens ?? 32768);
    if (!Number.isInteger(targetWin) || targetWin < 8192 || targetWin > 2097152) {
      this.managementStatusKind = 'error';
      this.managementStatus = '窗口容量须为 8192–2097152 之间的整数 token';
      return;
    }
    const targetThreshold: number = newThresholdPct !== undefined ? (newThresholdPct / 100) : (cfg.compressionThreshold ?? 0.8);
    const targetAuto: boolean = newAutoCompress !== undefined ? newAutoCompress : (cfg.autoCompress ?? false);
    this.configBusy = true;
    try {
      await aiService.updateActiveContextWindowAndPolicy(targetWin, targetThreshold, targetAuto);
      if (!this.panelDisposed) {
        this.loadConfigFields(true);
        this.configChangedAction();
        this.managementStatusKind = 'info';
        this.managementStatus = `已更新上下文配置：窗口 ${formatCompactTokens(targetWin)}（${targetWin.toLocaleString()} tokens）· 压缩阈值 ${Math.round(targetThreshold * 100)}%`;
      }
    } catch (error) {
      if (!this.panelDisposed) {
        this.managementStatusKind = 'error';
        this.managementStatus = error instanceof Error ? error.message : String(error);
      }
    } finally {
      this.configBusy = false;
    }
  }

  private toggleAutoExpandThinking(enabled: boolean): void {
    this.autoExpandThinking = enabled;
    AppStorage.setOrCreate<boolean>('hongtu_ai_auto_expand_thinking', enabled);
    if (enabled) {
      this.collapsedThinkingKeys = [];
    }
  }

  private modelDiscoveryConfigFromFields(): AiModelConfig {
    const config: AiModelConfig = aiService.getConfig();
    config.provider = this.providerValue;
    config.endpoint = this.endpointText.trim();
    config.apiKey = this.apiKeyText.trim();
    config.timeoutMs = Math.round(this.configNumber(this.timeoutSecondsText, '超时秒数', 1, 180, false) * 1000);
    return config;
  }

  private currentConfigFromFields(): AiModelConfig {
    const temperature: number = this.configNumber(this.temperatureText, '温度', 0, 2, false);
    const contextWindowTokens: number = this.configNumber(this.contextWindowText, '上下文窗口', 8192, 2097152, true);
    let maxTokens: number = this.configNumber(this.maxTokensText, '最大输出', 128, 65536, true);
    if (maxTokens + 6000 >= contextWindowTokens) {
      maxTokens = Math.max(512, contextWindowTokens - 6500);
      this.maxTokensText = String(maxTokens);
    }
    const timeoutSeconds: number = this.configNumber(this.timeoutSecondsText, '超时秒数', 1, 180, false);
    const compressionThreshold: number = this.configNumber(this.compressionThresholdText, '压缩阈值百分比', 50, 95, false) / 100;
    const fallbackModel = this.providerValue === AiProvider.DEMO_MODE ? 'hongtu-demo' : '';
    const candidateModel: string = this.modelNameText.trim().length > 0
      ? this.modelNameText.trim()
      : (this.pendingDraftModels.length > 0 ? this.pendingDraftModels[0] : fallbackModel);
    if (candidateModel.length === 0) throw new Error('请填写或从远端目录添加至少一个模型 ID');
    const config: AiModelConfig = {
      provider: this.providerValue,
      endpoint: this.endpointText.trim(),
      apiKey: this.apiKeyText.trim(),
      modelName: candidateModel,
      temperature,
      maxTokens,
      timeoutMs: Math.round(timeoutSeconds * 1000),
      contextWindowTokens,
      compressionThreshold,
      autoCompress: this.autoCompressValue,
      reasoningEffort: this.reasoningEffortValue,
      enabled: this.configEnabled,
    };
    return config;
  }

  private canSaveProviderDraft(): boolean {
    return this.selectedProfileId.length === 0 || this.credentialReady || this.apiKeyText.trim().length > 0;
  }

  private async reloadProviderCredentials(): Promise<void> {
    if (this.isLoading || this.configBusy) return;
    this.configBusy = true;
    const ticket: number = ++this.credentialReloadTicket;
    try {
      await aiService.ensureReady();
      if (!this.panelDisposed && ticket === this.credentialReloadTicket) {
        this.loadConfigFields();
        this.testStatusText = this.credentialReady ? '已重新读取保存的配置与凭据，可编辑后保存' : aiService.getCredentialError();
      }
    } catch (_) { if (!this.panelDisposed && ticket === this.credentialReloadTicket) this.testStatusText = '系统凭据尚未读取，请检查权限后重试'; }
    finally { if (ticket === this.credentialReloadTicket) this.configBusy = false; }
  }

  private async saveAiConfig(): Promise<void> {
    if (this.isLoading || this.configBusy) {
      this.testStatusText = '请等待当前任务结束后再保存配置';
      return;
    }
    if (!this.canSaveProviderDraft()) {
      this.testStatusText = '该供应商原凭据状态未知，请重试读取原凭据或填写新的 API Key 后保存';
      return;
    }
    const extraDraftModels: string[] = this.pendingDraftModels.slice();
    this.configBusy = true;
    try {
      const savedProfileId: string = await aiService.saveProviderProfile(
        this.profileNameText.trim().length > 0 ? this.profileNameText : '自定义模型服务',
        this.currentConfigFromFields(),
        this.selectedProfileId,
        this.selectedModelId,
        this.modelsEndpointText
      );
      for (let i = 0; i < extraDraftModels.length; i++) {
        const extraName: string = extraDraftModels[i];
        if (extraName !== this.modelNameText.trim()) {
          await aiService.addModelToProvider(savedProfileId, extraName, inferAiModelContextWindow(extraName, 0), false);
        }
      }
      if (!this.panelDisposed) {
        this.loadConfigFields(true);
        this.testStatusText = '供应商与模型配置已保存';
        if (aiService.getCredentialError().length > 0) this.testStatusText += `；${aiService.getCredentialError()}`;
        showAppSnackBar(this.getUIContext(), '模型配置已保存');
        try { this.configChangedAction(); }
        catch (_) { this.testStatusText = '配置已保存，上下文计量将在下次请求刷新'; }
      }
    } catch (e) {
      if (!this.panelDisposed) this.testStatusText = `配置保存失败：${e instanceof Error ? e.message : String(e)}`;
    } finally { this.configBusy = false; }
  }

  private async testAiConfig(): Promise<void> {
    if (this.isLoading || this.configBusy) {
      this.testStatusText = '请等待当前任务结束后再测试连接';
      return;
    }
    this.configBusy = true;
    try {
      const config: AiModelConfig = this.currentConfigFromFields();
      this.testStatusText = '正在测试连接（不会保存配置）…';
      const result: TestConnectionResult = await aiService.testConnection(config);
      if (!this.panelDisposed) this.testStatusText = result.message;
    } catch (e) {
      if (!this.panelDisposed) this.testStatusText = `连接测试失败：${e}`;
    } finally { this.configBusy = false; }
  }

  private configNumber(text: string, label: string, min: number, max: number, integer: boolean): number {
    const value: number = Number(text.trim());
    if (text.trim().length === 0 || !Number.isFinite(value) || value < min || value > max ||
      (integer && !Number.isInteger(value))) throw new Error(`${label}须为 ${min}–${max}${integer ? ' 的整数' : ' 之间的数字'}`);
    return value;
  }

  private activeConversationTitle(): string {
    const current: AiConversationSummary | undefined = this.conversations.find((item: AiConversationSummary): boolean => item.id === this.activeConversationId);
    return current?.title || '新会话';
  }

  private visibleConversations(): AiConversationSummary[] {
    const query: string = this.conversationSearch.trim().toLocaleLowerCase();
    return this.conversations.filter((item: AiConversationSummary): boolean => query.length === 0 || item.title.toLocaleLowerCase().includes(query));
  }

  private conversationChangesAllowed(): boolean {
    if (!this.isLoading && !this.configBusy) return true;
    this.managementStatusKind = 'error'; this.managementStatus = '任务运行中，请完成或取消后再更改会话与上下文';
    return false;
  }

  private openManagement(section: string): void {
    this.showQuickModelPicker = false;
    this.showConversations = section === 'conversations' && !this.showConversations;
    this.showContext = section === 'context' && !this.showContext;
    this.showSettings = section === 'settings' && !this.showSettings;
    this.managementStatus = '';
    this.followsLatest = !(this.showConversations || this.showContext || this.showSettings);
    if (this.scrollRequestTimer >= 0) clearTimeout(this.scrollRequestTimer);
    this.scrollRequestTimer = setTimeout(() => {
      this.scrollRequestTimer = -1;
      if (this.panelDisposed) return;
      if (this.followsLatest) {
        this.pinConversationToBottomInstant();
      } else {
        this.conversationScroller.scrollTo({ xOffset: 0, yOffset: 0, animation: false });
      }
    }, 0);
  }

  private createConversation(): void {
    if (!this.conversationChangesAllowed()) return;
    this.newConversationAction();
    this.showConversations = false;
    this.conversationSearch = '';
  }

  private selectConversation(id: string): void {
    if (!this.conversationChangesAllowed() || !this.conversations.some((item: AiConversationSummary): boolean => item.id === id)) return;
    this.switchConversationAction(id);
    this.showConversations = false;
  }

  private beginRenameConversation(id: string): void {
    if (!this.conversationChangesAllowed()) return;
    const item: AiConversationSummary | undefined = this.conversations.find((candidate: AiConversationSummary): boolean => candidate.id === id);
    if (!item) return;
    this.renamingConversationId = id;
    this.conversationTitleText = item.title;
    this.managementStatus = '';
  }

  private confirmConversationRename(): void {
    if (!this.conversationChangesAllowed()) return;
    const title: string = this.conversationTitleText.trim();
    if (title.length === 0 || title.length > 80 || /[\r\n\u0000-\u001f\u007f]/.test(title)) {
      this.managementStatusKind = 'error'; this.managementStatus = '会话名称须为 1–80 个字符，不含换行或控制字符';
      return;
    }
    if (!this.conversations.some((item: AiConversationSummary): boolean => item.id === this.renamingConversationId)) {
      this.managementStatusKind = 'error'; this.managementStatus = '会话已不存在，请刷新列表';
      return;
    }
    this.renameConversationAction(this.renamingConversationId, title);
    this.renamingConversationId = '';
    this.managementStatus = '';
  }

  private requestDeleteConversation(id: string): void {
    if (!this.conversationChangesAllowed()) return;
    const item: AiConversationSummary | undefined = this.conversations.find((candidate: AiConversationSummary): boolean => candidate.id === id);
    if (!item) return;
    AlertDialog.show({ title: '删除会话', message: `删除「${item.title}」及其聊天记录和压缩摘要？此操作无法撤销，已打开的版图不会被删除。`,
      cornerRadius: 16,
      primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {} },
      secondaryButton: { value: '删除', fontColor: COLORS.danger, backgroundColor: COLORS.dangerSoft, action: () => {
        if (!this.panelDisposed && this.conversationChangesAllowed() &&
          this.conversations.some((candidate: AiConversationSummary): boolean => candidate.id === id)) this.deleteConversationAction(id);
      } }
    });
  }

  private changeContextOption(option: string, enabled: boolean): void {
    if ((option === 'history' && this.contextOptions.includeHistory === enabled) ||
      (option === 'layout' && this.contextOptions.includeLayout === enabled) ||
      (option === 'selection' && this.contextOptions.includeSelection === enabled)) {
      return;
    }
    if (!this.conversationChangesAllowed()) return;
    const options: AiContextOptions = { includeHistory: this.contextOptions.includeHistory,
      includeLayout: this.contextOptions.includeLayout, includeSelection: this.contextOptions.includeSelection };
    if (option === 'history') options.includeHistory = enabled;
    else if (option === 'layout') options.includeLayout = enabled;
    else if (option === 'selection') options.includeSelection = enabled;
    else return;
    this.setContextOptionsAction(options);
  }

  private compressCurrentConversation(clear: boolean): void {
    if (!this.conversationChangesAllowed()) return;
    if (clear) this.clearCompressionAction();
    else this.compressConversationAction();
  }

  private executeSlashSpec(spec: AiSlashCommandSpec): void {
    this.slashMenuForced = false;
    this.inputText = '';
    if (spec.kind === 'template') {
      this.showTaskTemplate = !this.showTaskTemplate;
      return;
    }
    if (spec.kind === 'python') {
      this.openPythonAction();
      return;
    }
    if (spec.kind === 'compact') {
      this.compressCurrentConversation(false);
      return;
    }
    if (spec.kind === 'new') {
      this.createConversation();
      return;
    }
    if (spec.kind === 'mode_readonly') {
      if (this.sessionMode !== 'readonly') this.toggleSessionModeAction();
      return;
    }
    if (spec.kind === 'mode_agent') {
      if (this.sessionMode !== 'agent') this.toggleSessionModeAction();
      return;
    }
    if (spec.prompt.length > 0 && !this.isLoading && !this.configBusy) {
      this.followsLatest = true;
      this.showConversations = false;
      this.showContext = false;
      this.showSettings = false;
      this.promptAction(spec.prompt, false, this.sessionMode === 'readonly');
    }
  }

  private visibleSlashCommands(): AiSlashCommandSpec[] {
    if (this.isLoading || this.configBusy) {
      return [];
    }
    if (this.slashMenuForced && !this.inputText.trimStart().startsWith('/')) {
      return matchAiSlashCommands('/');
    }
    return matchAiSlashCommands(this.inputText);
  }

  private sendInput(resumeTask: boolean = false): void {
    const prompt: string = this.inputText.trim();
    if (prompt.length === 0 || this.isLoading || this.configBusy) {
      return;
    }
    if (!resumeTask && prompt.startsWith('/')) {
      const matched: AiSlashCommandSpec[] = matchAiSlashCommands(prompt);
      if (matched.length === 1 && matched[0].command === prompt.toLowerCase()) {
        this.executeSlashSpec(matched[0]);
        return;
      }
    }
    this.slashMenuForced = false;
    this.followsLatest = true;
    this.showConversations = false;
    this.showContext = false;
    this.showSettings = false;
    const lockReadOnly: boolean = this.sessionMode === 'readonly';
    if (resumeTask) this.promptAction(prompt, true, lockReadOnly);
    else this.promptAction(prompt, false, lockReadOnly);
    this.inputText = '';
  }

  private editingContextLabel(): string {
    return `当前编辑：${this.cellName || (this.fileName.length > 0 ? this.fileName : '未打开版图')}` +
      (this.topCellName.length > 0 ? ` · Top：${this.topCellName}` : '') +
      (this.selectionCount > 0 ? ` · ${this.selectionCount} 个选中图形` : '');
  }

  private toggleReasoning(key: string): void {
    this.expandedReasoning = this.expandedReasoning.includes(key)
      ? this.expandedReasoning.filter((item: string): boolean => item !== key) : this.expandedReasoning.concat([key]);
  }

  private toggleTool(key: string): void {
    this.expandedTools = this.expandedTools.includes(key)
      ? this.expandedTools.filter((item: string): boolean => item !== key) : this.expandedTools.concat([key]);
  }

  private toggleTrace(key: string): void {
    this.expandedTraces = this.expandedTraces.includes(key)
      ? this.expandedTraces.filter((item: string): boolean => item !== key) : this.expandedTraces.concat([key]);
  }

  private toggleRawTool(key: string): void {
    this.expandedRawTools = this.expandedRawTools.includes(key)
      ? this.expandedRawTools.filter((item: string): boolean => item !== key) : this.expandedRawTools.concat([key]);
  }

  private async copyPlainText(text: string, toastMessage: string): Promise<void> {
    if (text.trim().length === 0) return;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
      showAppSnackBar(this.getUIContext(), toastMessage);
    } catch (_) {}
  }

  private isLatestAssistantMessage(msg: ChatMessage): boolean {
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.ASSISTANT) {
        return this.messages[i].timestamp === msg.timestamp && this.messages[i].content === msg.content;
      }
    }
    return false;
  }

  private retryLatestTurn(): void {
    if (this.isLoading || this.configBusy) return;
    const lastPrompt: string = this.latestUserPrompt().trim();
    if (lastPrompt.length === 0) return;
    this.followsLatest = true;
    this.promptAction(lastPrompt, false, this.sessionMode === 'readonly');
  }

  private quoteForFollowUp(msg: ChatMessage): void {
    const raw: string = this.messageText(msg).replace(/\s+/g, ' ').trim();
    if (raw.length === 0) return;
    const excerpt: string = raw.length > 48 ? `${raw.substring(0, 48)}…` : raw;
    this.inputText = `针对「${excerpt}」，请进一步`;
  }

  private tokenMeterState(): AiTokenMeterState {
    const cfg: AiModelConfig = aiService.getConfig();
    return computeDraftAwareTokenMeter(
      this.contextUsageSummary,
      this.inputText,
      cfg.contextWindowTokens ?? 32768,
      cfg.compressionThreshold ?? 0.8
    );
  }

  private shortModelPillLabel(): string {
    const cfg: AiModelConfig = aiService.getConfig();
    if (cfg.provider === AiProvider.DEMO_MODE) return '演示模式';
    const raw: string = cfg.modelName.trim() || '未选模型';
    const slashOrColon: number = Math.max(raw.lastIndexOf('/'), raw.lastIndexOf(':'));
    const tail: string = slashOrColon >= 0 ? raw.substring(slashOrColon + 1) : raw;
    const shortName: string = tail.length > 16 ? `${tail.substring(0, 15)}…` : tail;
    return `${shortName} · ${formatCompactTokens(cfg.contextWindowTokens ?? 32768)}`;
  }

  private isThinkingExpanded(key: string, isLive: boolean, isLatestTurn: boolean): boolean {
    if (isLive) {
      return !this.collapsedThinkingKeys.includes(key);
    }
    if (this.expandedReasoning.includes(key)) {
      return true;
    }
    if (this.collapsedThinkingKeys.includes(key)) {
      return false;
    }
    return this.autoExpandThinking && isLatestTurn;
  }

  private toggleThinkingCard(key: string, currentlyExpanded: boolean): void {
    if (currentlyExpanded) {
      this.expandedReasoning = this.expandedReasoning.filter((item: string): boolean => item !== key);
      if (!this.collapsedThinkingKeys.includes(key)) {
        this.collapsedThinkingKeys = this.collapsedThinkingKeys.concat([key]);
      }
    } else {
      this.collapsedThinkingKeys = this.collapsedThinkingKeys.filter((item: string): boolean => item !== key);
      if (!this.expandedReasoning.includes(key)) {
        this.expandedReasoning = this.expandedReasoning.concat([key]);
      }
    }
  }

  private hasInterruptedTurn(): boolean {
    if (this.errorMessage.length > 0 || this.checkpointSummary.length > 0) return true;
    for (let i: number = this.messages.length - 1; i >= 0; i--) {
      if (this.messages[i].role === ChatRole.ASSISTANT) {
        const st = this.messages[i].runStatus;
        return st === 'failed' || st === 'cancelled';
      }
    }
    return false;
  }

  private isExplicitActionReceipt(): boolean {
    const raw: string = this.lastResult.trim();
    if (raw.length === 0) return false;
    return raw.startsWith('已取消') || raw.startsWith('已应用') || raw.startsWith('已撤销') ||
      raw.startsWith('修改已') || raw.startsWith('操作已') || this.canUndo;
  }

  private traceSummaryText(tools: AiChatToolState[], reasoning: string, isLive: boolean): string {
    const total: number = tools.length;
    if (isLive) {
      for (let i: number = total - 1; i >= 0; i--) {
        if (tools[i].status === 'running') {
          const desc: AiToolPresentation = describeAiToolCall(tools[i], true);
          return desc.inlineTarget.length > 0
            ? `正在执行：${desc.title} · ${desc.inlineTarget}`
            : `正在执行：${desc.title}`;
        }
      }
      return total > 0 ? `正在处理 · 已执行 ${total} 步` : '正在思考…';
    }
    let failedCount: number = 0;
    for (let i: number = 0; i < total; i++) {
      if (this.toolFailed(tools[i])) failedCount++;
    }
    if (total > 0 && failedCount > 0) {
      return `工作过程 · ${total} 步工具（${failedCount} 步未通过）`;
    }
    if (total > 0) {
      const lastDesc: AiToolPresentation = describeAiToolCall(tools[total - 1], false);
      const tailHint: string = lastDesc.inlineTarget.length > 0 ? ` · ${lastDesc.inlineTarget}` : '';
      return `工作过程 · ${total} 步工具调用${tailHint}`;
    }
    return reasoning.length > 0 ? '思考过程' : '工作过程';
  }

  private liveAssistantVisible(): boolean {
    return this.streamingText.length > 0 || this.reasoningText.length > 0 || this.toolCalls.length > 0;
  }

  private resultFallbackVisible(): boolean {
    return this.lastResult.trim().length > 0;
  }

  private receiptSummaryText(): string {
    const raw: string = this.lastResult.trim();
    if (raw.length === 0) {
      return '上一步：修改已应用';
    }
    return raw.startsWith('上一步：') ? raw : `上一步：${raw}`;
  }

  private shapeTypeShortName(type: ShapeType): string {
    if (type === ShapeType.RECT) return '矩形';
    if (type === ShapeType.POLYGON) return '多边形';
    if (type === ShapeType.PATH) return '路径';
    if (type === ShapeType.TEXT) return '文本';
    if (type === ShapeType.INSTANCE) return '实例';
    return '图形';
  }

  private formatLayerBadge(layerNumber: number, datatype: number): string {
    const entry = LAYER_NAME_MAP.get(layerNumber);
    if (entry !== undefined) {
      return `${entry.english} (${layerNumber}/${datatype})`;
    }
    return `L${layerNumber}/${datatype}`;
  }

  private trimNmNumbers(text: string): string {
    return text.replace(/(\d+)\.00\b/g, '$1');
  }

  private reviewGroupRowSpecs(): AiReviewGroupRowSpec[] {
    return this.reviewGroups.map((group: AiReviewGroup): AiReviewGroupRowSpec => ({
      group,
      accepted: group.accepted
    }));
  }

  private collectPendingTargetShapes(): Shape[] {
    const allShapes: Shape[] = editService.getShapes();
    const idSet: Set<number> = new Set<number>();
    for (const group of this.reviewGroups) {
      if (!group.accepted) continue;
      for (const id of group.targetIds) {
        if (Number.isInteger(id) && id >= 0) idSet.add(id);
      }
    }
    if (idSet.size === 0 && this.pendingDetail.length > 0) {
      const hashRegex: RegExp = /#(\d+)\b/g;
      let hashMatch: RegExpExecArray | null = hashRegex.exec(this.pendingDetail);
      while (hashMatch !== null) {
        const parsed: number = Number(hashMatch[1]);
        if (Number.isInteger(parsed) && parsed >= 0) idSet.add(parsed);
        hashMatch = hashRegex.exec(this.pendingDetail);
      }
      const jsonShapeId: RegExpMatchArray | null = this.pendingDetail.match(/"shapeId"\s*:\s*(\d+)/);
      if (jsonShapeId !== null) {
        const parsed: number = Number(jsonShapeId[1]);
        if (Number.isInteger(parsed) && parsed >= 0) idSet.add(parsed);
      }
    }
    if (idSet.size === 0) {
      for (const selId of editService.getSelectedIds()) {
        idSet.add(selId);
      }
    }
    const matched: Shape[] = [];
    for (const s of allShapes) {
      if (idSet.has(s.id)) matched.push(s);
    }
    return matched;
  }

  private buildPendingStructuredRows(): AiPendingFieldRow[] {
    const rows: AiPendingFieldRow[] = [];
    const targets: Shape[] = this.collectPendingTargetShapes();
    const detail: string = this.pendingDetail.trim();
    const propMatch: RegExpMatchArray | null = detail.match(/"property"\s*:\s*"([^"]+)"/);
    const valMatch: RegExpMatchArray | null = detail.match(/"value"\s*:\s*"?([^",\n}]+)"?/);
    const layerNumMatch: RegExpMatchArray | null = detail.match(/"layerNumber"\s*:\s*(\d+)/);
    const datatypeMatch: RegExpMatchArray | null = detail.match(/"datatype"\s*:\s*(\d+)/);

    // 1. 对象
    if (targets.length === 1) {
      const s: Shape = targets[0];
      rows.push({ label: '对象', value: `${this.shapeTypeShortName(s.type)} #${s.id}`, accent: false });
    } else if (targets.length > 1) {
      const first: Shape = targets[0];
      rows.push({ label: '对象', value: `${this.shapeTypeShortName(first.type)} #${first.id} 等 ${targets.length} 项`, accent: false });
    } else {
      const firstLine: string = detail.split('\n')[0].trim();
      rows.push({
        label: '对象',
        value: firstLine.length > 0 ? firstLine.replace(/\s*\([a-zA-Z0-9_.]+\)$/, '') : '当前版图方案',
        accent: false
      });
    }

    // 2. 图层
    let layerDisplay: string = '';
    if (targets.length > 0) {
      const baseLayer: string = this.formatLayerBadge(targets[0].layerNumber, targets[0].datatype);
      if (layerNumMatch !== null) {
        const nextLn: number = Number(layerNumMatch[1]);
        const nextDt: number = datatypeMatch !== null ? Number(datatypeMatch[1]) : targets[0].datatype;
        const nextLayer: string = this.formatLayerBadge(nextLn, nextDt);
        layerDisplay = baseLayer === nextLayer ? baseLayer : `${baseLayer} → ${nextLayer}`;
      } else if (propMatch !== null && propMatch[1] === 'layerKey' && valMatch !== null) {
        const parts: string[] = valMatch[1].trim().split('/');
        const nextLn: number = Number(parts[0]);
        const nextDt: number = parts.length > 1 ? Number(parts[1]) : 0;
        const nextLayer: string = Number.isFinite(nextLn) ? this.formatLayerBadge(nextLn, Number.isFinite(nextDt) ? nextDt : 0) : valMatch[1].trim();
        layerDisplay = `${baseLayer} → ${nextLayer}`;
      } else {
        layerDisplay = baseLayer;
      }
    } else if (layerNumMatch !== null) {
      const nextLn: number = Number(layerNumMatch[1]);
      const nextDt: number = datatypeMatch !== null ? Number(datatypeMatch[1]) : 0;
      layerDisplay = this.formatLayerBadge(nextLn, nextDt);
    }
    if (layerDisplay.length > 0) {
      rows.push({ label: '图层', value: layerDisplay, accent: layerDisplay.includes('→') });
    }

    // 3. 关键尺寸 / 参数前后对比
    if (propMatch !== null && valMatch !== null && targets.length > 0) {
      const prop: string = propMatch[1];
      const nextVal: string = valMatch[1].trim();
      const bounds = getShapeBounds(targets[0]);
      const curW: number = Math.round((bounds.maxX - bounds.minX) * 100) / 100;
      const curH: number = Math.round((bounds.maxY - bounds.minY) * 100) / 100;
      if (prop === 'width') {
        rows.push({ label: '宽度', value: `${curW} nm → ${nextVal} nm`, accent: true });
      } else if (prop === 'height') {
        rows.push({ label: '高度', value: `${curH} nm → ${nextVal} nm`, accent: true });
      } else if (prop === 'pathWidth') {
        rows.push({ label: '线宽', value: `${targets[0].pathWidth ?? 1} nm → ${nextVal} nm`, accent: true });
      } else if (prop === 'x') {
        rows.push({ label: '坐标 X', value: `${Math.round(bounds.minX * 100) / 100} nm → ${nextVal} nm`, accent: true });
      } else if (prop === 'y') {
        rows.push({ label: '坐标 Y', value: `${Math.round(bounds.minY * 100) / 100} nm → ${nextVal} nm`, accent: true });
      } else if (prop !== 'layerKey') {
        rows.push({ label: '参数', value: `${prop} → ${nextVal}`, accent: true });
      }
    } else {
      const dxMatch: RegExpMatchArray | null = detail.match(/"dx"\s*:\s*(-?\d+(?:\.\d+)?)/);
      const dyMatch: RegExpMatchArray | null = detail.match(/"dy"\s*:\s*(-?\d+(?:\.\d+)?)/);
      const firstLine: string = detail.split('\n')[0].trim();
      if (dxMatch !== null || dyMatch !== null) {
        const dxVal: number = dxMatch !== null ? Number(dxMatch[1]) : 0;
        const dyVal: number = dyMatch !== null ? Number(dyMatch[1]) : 0;
        const parts: string[] = [];
        if (dxVal !== 0) parts.push(`ΔX ${dxVal > 0 ? '+' : ''}${dxVal} nm`);
        if (dyVal !== 0) parts.push(`ΔY ${dyVal > 0 ? '+' : ''}${dyVal} nm`);
        if (parts.length > 0) {
          rows.push({ label: '坐标位移', value: parts.join('，'), accent: true });
        }
      } else if (firstLine.length > 0 && /移动|平移|旋转|镜像|偏移|圆角|阵列/.test(firstLine)) {
        rows.push({ label: '变更内容', value: firstLine.replace(/\s*\([a-zA-Z0-9_.]+\)$/, ''), accent: true });
      }
      const markerIdx: number = detail.indexOf('预计几何范围（nm）：');
      if (markerIdx >= 0) {
        const rawLines: string[] = detail.substring(markerIdx + '预计几何范围（nm）：'.length).split('\n');
        const transitions: string[] = [];
        for (const rawLine of rawLines) {
          const line: string = rawLine.trim();
          if (line.length === 0 || line.startsWith('更多对象')) continue;
          const colonPos: number = line.indexOf('：');
          const body: string = colonPos >= 0 ? line.substring(colonPos + 1).trim() : line;
          if (body.includes('→')) {
            const trimmedBody: string = this.trimNmNumbers(body);
            const halves: string[] = trimmedBody.split('→');
            if (halves.length === 2 && halves[0].trim() === halves[1].trim()) {
              continue;
            }
            transitions.push(trimmedBody);
          }
          if (transitions.length >= 2) break;
        }
        if (transitions.length > 0) {
          rows.push({ label: '尺寸对比', value: transitions.join('；'), accent: true });
        }
      }
    }

    // 4. 影响图形数
    const affectedCount: number = targets.length > 0 ? targets.length : Math.max(1, this.reviewGroups.filter((g: AiReviewGroup): boolean => g.accepted).length);
    rows.push({
      label: '影响范围',
      value: targets.length > 0 ? `影响 ${affectedCount} 个图形` : `${this.pendingSummary}`,
      accent: false
    });
    return rows;
  }

  private toolStatusLabel(tool: AiChatToolState, key: string = ''): string {
    if (this.toolFailed(tool)) return '失败';
    if (tool.status === 'running' && key.length > 0 && (!key.startsWith('0:') || !this.isLoading)) return '未完成';
    return tool.status === 'running' ? '运行中' : '已完成';
  }

  private toolTitle(tool: AiChatToolState): string {
    switch (tool.name) {
      case 'inspect_layout': return '读取当前版图';
      case 'query_editor': return '查询版图明细';
      case 'list_native_tools': return '查询软件工具与参数';
      case 'read_native_tool': return '读取原生工具结果';
      case 'propose_native_tools': return '提交原生工具操作';
      case 'prepare_native_workflow': return '准备专业编辑流程';
      case 'check_tool_protocol': return '检查模型工具调用';
      case 'create_cmos_inverter': return '绘制 CMOS 反相器';
      case 'execute_layout_python': return '运行版图脚本';
      case 'propose_editor_commands': return '准备版图修改';
      case 'read_plan': return '读取执行计划';
      case 'write_plan': return '制定执行计划';
      case 'update_plan': return '更新执行计划';
      case 'update_task_status':
      case 'update_task_statuses': return '更新步骤状态';
      default: return tool.name;
    }
  }

  private toolFailed(tool: AiChatToolState): boolean {
    if (tool.status === 'failed') return true;
    if (!['write_plan', 'read_plan', 'update_plan', 'update_task_status', 'update_task_statuses'].includes(tool.name)) return false;
    return tool.result.startsWith('Plan not updated:') || tool.result.startsWith('Invalid status ') ||
      /^Step with id '[^\r\n]*' not found\.$/.test(tool.result.trim()) ||
      tool.result.endsWith('\n\nFix the errors and try again.');
  }

  private toolActionText(tool: AiChatToolState, key: string): string {
    if (this.toolFailed(tool)) return '这一步未完成，可展开查看原因';
    if (tool.status === 'running') {
      return key.startsWith('0:') && this.isLoading ? '正在执行…' : '运行未完成';
    }
    if (['下载并校验版图', '解析图形与图层', '打开独立版图', '检查当前规则'].includes(tool.name) &&
      tool.result.length > 0 && tool.result.length <= 180 && !tool.result.includes('\n')) return tool.result;
    switch (tool.name) {
      case 'inspect_layout': return '已读取当前上下文';
      case 'query_editor': return '已返回本页实测数据，请核对范围和截断标记';
      case 'list_native_tools': return '已返回工具目录或严格参数协议';
      case 'read_native_tool': return '已返回原生工具数据，未应用修改';
      case 'propose_native_tools': return '带参数的操作待审阅，尚未应用';
      case 'prepare_native_workflow': return '专业流程待确认，尚未修改几何';
      case 'check_tool_protocol': return '只读诊断工具已返回';
      case 'create_cmos_inverter':
      case 'execute_layout_python': return '已生成版图文件';
      case 'propose_editor_commands': return '已准备修改方案，应用前需要确认';
      case 'write_plan': return '执行计划已记录';
      case 'read_plan': return '已读取计划状态';
      case 'update_plan':
      case 'update_task_status':
      case 'update_task_statuses': return '已更新计划状态';
      default: return '此步骤已完成';
    }
  }

  private planStatusLabel(step: AiPlanStepView): string {
    switch (step.status) {
      case 'completed': return '已完成';
      case 'in_progress': return '进行中';
      case 'cancelled': return '已取消';
      case 'blocked': return '受阻';
      default: return '待执行';
    }
  }

  private planContentLabel(step: AiPlanStepView): string {
    return step.content.replace(/inspect_layout/g, '读取当前版图').replace(/create_cmos_inverter/g, '绘制反相器')
      .replace(/execute_layout_python/g, '运行版图脚本').replace(/propose_editor_commands/g, '准备版图修改')
      .replace(/write_plan/g, '制定执行计划').replace(/read_plan/g, '读取执行计划')
      .replace(/update_task_statuses/g, '更新步骤状态').replace(/update_task_status/g, '更新步骤状态')
      .replace(/update_plan/g, '更新执行计划').replace(/generic_inverter/g, '通用反相器');
  }

  /** Only complete, self-consistent snapshots from the official planning tools. */
  private planSnapshot(tool: AiChatToolState): AiPlanStepView[] {
    if (tool.status !== 'completed' || this.toolFailed(tool) || !['write_plan', 'read_plan'].includes(tool.name)) return [];
    const lines: string[] = tool.result.trim().split('\n').map((line: string): string => line.trim());
    const writeHeader: RegExpMatchArray | null = lines[0].match(/^Plan updated: (\d+) step\(s\)\.$/);
    if (tool.name === 'write_plan' ? writeHeader === null : lines[0] !== 'Current plan:') return [];
    const steps: AiPlanStepView[] = [];
    let footer: string = '';
    for (let i: number = 1; i < lines.length; i++) {
      const line: string = lines[i];
      if (line.length === 0) continue;
      if (footer.length > 0) {
        if (line === 'Note: keep only one step in_progress at a time.' ||
          line === 'All steps are completed. Do NOT call read_plan again -- respond to the user with a summary instead.') continue;
        return [];
      }
      if (/^\(\d+\/\d+ completed\)$/.test(line) || line.startsWith('Summary: ')) { footer = line; continue; }
      const row: RegExpMatchArray | null = tool.name === 'read_plan'
        ? line.match(/^(\d+)\. \[([ ~x!\-])\] \[([A-Za-z0-9_-]+)\] (.+)$/)
        : line.match(/^(\d+)\. \[([ ~x!\-])\] (.+)$/);
      if (row === null || Number(row[1]) !== steps.length + 1 || steps.length >= 100) return [];
      const status: string = row[2] === 'x' ? 'completed' : (row[2] === '~' ? 'in_progress' :
        (row[2] === '-' ? 'cancelled' : (row[2] === '!' ? 'blocked' : 'pending')));
      const id: string = tool.name === 'read_plan' ? row[3] : '';
      if (id.length > 0 && steps.some((step: AiPlanStepView): boolean => step.id === id)) return [];
      steps.push({ id, content: tool.name === 'read_plan' ? row[4] : row[3], status });
    }
    if (steps.length === 0 || footer.length === 0) return [];
    const completed: number = steps.filter((step: AiPlanStepView): boolean => step.status === 'completed').length;
    if (tool.name === 'write_plan') {
      if (Number(writeHeader?.[1]) !== steps.length || footer !== `(${completed}/${steps.length} completed)`) return [];
    } else {
      const summary: RegExpMatchArray | null = footer.match(/^Summary: (\d+) completed, (\d+) in progress, (\d+) pending(?:, (\d+) cancelled)?(?:, (\d+) blocked)?$/);
      if (summary === null) return [];
      const statuses: string[] = ['completed', 'in_progress', 'pending', 'cancelled', 'blocked'];
      for (let i: number = 0; i < statuses.length; i++) {
        if (Number(summary[i + 1] ?? '0') !== steps.filter((step: AiPlanStepView): boolean => step.status === statuses[i]).length) return [];
      }
    }
    return steps;
  }

  private planForDisplay(tools: AiChatToolState[], key: string): AiPlanStepView[] {
    const current: AiChatToolState[] = key === '0' ? this.toolCalls : tools;
    let steps: AiPlanStepView[] = [];
    for (const tool of current) {
      if (tool.status !== 'completed' || this.toolFailed(tool)) continue;
      if ((tool.name === 'read_plan' && tool.result.trim() === 'No plan yet. Use write_plan to create one.') ||
        (tool.name === 'write_plan' && /^Plan updated: 0 step\(s\)\.\s*\(0\/0 completed\)$/.test(tool.result.trim()))) {
        steps = [];
        continue;
      }
      const snapshot: AiPlanStepView[] = this.planSnapshot(tool);
      if (snapshot.length > 0) { steps = snapshot; continue; }
      if (tool.name !== 'update_task_status') continue;
      const update: RegExpMatchArray | null = tool.result.trim().match(/^Updated step '([^\r\n]+)' status to '(pending|in_progress|completed|cancelled|blocked)'\.$/);
      if (update === null) continue;
      const matching: AiPlanStepView[] = steps.filter((step: AiPlanStepView): boolean => step.content === update[1]);
      if (matching.length !== 1) continue;
      steps = steps.map((step: AiPlanStepView): AiPlanStepView => ({ id: step.id, content: step.content,
        status: step.content === update[1] ? update[2] : step.status }));
    }
    return steps;
  }

  private toolForDisplay(tool: AiChatToolState, key: string): AiChatToolState {
    if (key.startsWith('0:')) {
      return this.toolCalls.find((current: AiChatToolState): boolean => current.id === tool.id) ?? tool;
    }
    return tool;
  }

  /** DSH first-class Thinking Process Card: auto-expanded while streaming & on latest turn, with preview snippet when folded. */
  @Builder
  ThinkingDisclosureCard(
    thinking: string,
    key: string,
    isLive: boolean,
    activelyThinking: boolean,
    isLatestTurn: boolean = false
  ) {
    if (thinking.trim().length > 0) {
      Column({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 6 }) {
            if (activelyThinking) {
              LoadingProgress().width(14).height(14).color(COLORS.primary)
            } else {
              WorkbenchIcon({ name: 'think', iconSize: 14, color: COLORS.primary })
            }
            Text(activelyThinking ? `正在深度思考 · ${thinking.length} 字` : `思考过程 · ${thinking.length} 字`)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(activelyThinking ? COLORS.primary : COLORS.ink)
            if (!this.isThinkingExpanded(key, isLive, isLatestTurn)) {
              Text(thinking.replace(/\s+/g, ' ').trim())
                .fontSize(11)
                .fontColor(COLORS.muted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              Blank().layoutWeight(1)
            }
            Text(this.isThinkingExpanded(key, isLive, isLatestTurn) ? '收起' : '展开')
              .fontSize(11)
              .fontColor(COLORS.muted)
            WorkbenchIcon({
              name: this.isThinkingExpanded(key, isLive, isLatestTurn) ? 'chevronUp' : 'chevronDown',
              iconSize: 12,
              color: COLORS.muted
            })
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        .id(`ai-thinking-toggle-${key}`)
        .width('100%')
        .height(30)
        .padding({ left: 10, right: 10 })
        .backgroundColor(Color.Transparent)
        .borderRadius(8)
        .onClick(() => {
          this.toggleThinkingCard(key, this.isThinkingExpanded(key, isLive, isLatestTurn));
        })

        if (this.isThinkingExpanded(key, isLive, isLatestTurn)) {
          if (isLive) {
            Scroll(this.liveThinkingScroller) {
              Row({ space: 8 }) {
                Column()
                  .width(2.5)
                  .backgroundColor(withAlpha(COLORS.primary, 0.45))
                  .borderRadius(2)
                Text(thinking)
                  .fontSize(12)
                  .lineHeight(19)
                  .fontColor(COLORS.muted)
                  .wordBreak(WordBreak.BREAK_WORD)
                  .copyOption(CopyOptions.LocalDevice)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 10, right: 10, bottom: 8 })
              .onAreaChange((_oldArea: Area, newArea: Area) => {
                const nextH: number = Number(newArea.height);
                if (Number.isFinite(nextH) && Math.abs(nextH - this.liveThinkingContentHeight) > 0.5) {
                  this.liveThinkingContentHeight = nextH;
                  if (activelyThinking && this.liveThinkingViewportHeight > 0 && nextH > this.liveThinkingViewportHeight) {
                    try {
                      this.liveThinkingScroller.scrollTo({
                        xOffset: 0,
                        yOffset: Math.max(0, nextH - this.liveThinkingViewportHeight),
                        animation: false
                      });
                    } catch (_) {}
                  }
                }
              })
            }
            .width('100%')
            .constraintSize({ maxHeight: 210 })
            .align(Alignment.TopStart)
            .scrollBar(BarState.Auto)
            .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              const nextV: number = Number(newArea.height);
              if (Number.isFinite(nextV) && Math.abs(nextV - this.liveThinkingViewportHeight) > 0.5) {
                this.liveThinkingViewportHeight = nextV;
              }
            })
          } else {
            Scroll() {
              Row({ space: 8 }) {
                Column()
                  .width(2.5)
                  .backgroundColor(withAlpha(COLORS.primary, 0.45))
                  .borderRadius(2)
                Text(thinking)
                  .fontSize(12)
                  .lineHeight(19)
                  .fontColor(COLORS.muted)
                  .wordBreak(WordBreak.BREAK_WORD)
                  .copyOption(CopyOptions.LocalDevice)
                  .layoutWeight(1)
              }
              .width('100%')
              .alignItems(VerticalAlign.Top)
              .padding({ left: 10, right: 10, bottom: 8 })
            }
            .width('100%')
            .constraintSize({ maxHeight: 260 })
            .align(Alignment.TopStart)
            .scrollBar(BarState.Auto)
          }
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor(withAlpha(COLORS.surfaceMuted, 0.72))
      .border({ width: 0.8, color: activelyThinking ? withAlpha(COLORS.primary, 0.38) : COLORS.border })
      .borderRadius(10)
      .margin({ bottom: 6 })
    }
  }

  @Builder
  ToolStructuredFieldRow(field: AiToolField) {
    Row({ space: 8 }) {
      Text(field.label)
        .fontSize(11)
        .fontColor(COLORS.muted)
        .width(66)
      Text(field.value)
        .fontSize(11)
        .fontWeight(field.accent ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(field.accent ? COLORS.primary : COLORS.ink)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  ToolCard(tool: AiChatToolState, key: string) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        if (this.toolForDisplay(tool, key).status === 'running' && key.startsWith('0:') && this.isLoading) {
          LoadingProgress().width(18).height(18).color(COLORS.primary)
        } else {
          DrawnStatusIcon({
            kind: this.toolFailed(this.toolForDisplay(tool, key))
              ? 'error'
              : (this.toolForDisplay(tool, key).status === 'completed' ? 'success' : 'active'),
            iconSize: 16,
            strokeColor: this.toolFailed(this.toolForDisplay(tool, key))
              ? COLORS.danger
              : (this.toolForDisplay(tool, key).status === 'completed' ? COLORS.success : COLORS.muted),
            showSoftPlate: true
          })
        }
        Divider().vertical(true).height(16).color(COLORS.border)
      }.width(18).padding({ top: 6 })

      Column({ space: 5 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 5 }) {
            Text(this.toolTitle(this.toolForDisplay(tool, key)))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .maxLines(1)
            if (describeAiToolCall(this.toolForDisplay(tool, key), key.startsWith('0:') && this.isLoading).inlineTarget.length > 0) {
              Text('·')
                .fontSize(11)
                .fontColor(COLORS.muted)
              Text(describeAiToolCall(this.toolForDisplay(tool, key), key.startsWith('0:') && this.isLoading).inlineTarget)
                .fontSize(11)
                .fontColor(COLORS.muted)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            } else {
              Blank().layoutWeight(1)
            }
            Text(this.toolStatusLabel(this.toolForDisplay(tool, key), key))
              .fontSize(10)
              .fontColor(this.toolFailed(this.toolForDisplay(tool, key)) ? COLORS.danger :
                (this.toolForDisplay(tool, key).status === 'completed' ? COLORS.success : COLORS.primary))
            WorkbenchIcon({ name: this.expandedTools.includes(key) ? 'chevronUp' : 'chevronDown', iconSize: 12, color: COLORS.muted })
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        .height(30)
        .width('100%')
        .padding({ left: 8, right: 8 })
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .accessibilityText(`${this.toolTitle(this.toolForDisplay(tool, key))} · 展开详情`)
        .onClick(() => { this.toggleTool(key); })

        if (this.expandedTools.includes(key)) {
          Column({ space: 6 }) {
            Text(this.toolActionText(this.toolForDisplay(tool, key), key))
              .fontSize(11)
              .fontColor(this.toolFailed(this.toolForDisplay(tool, key)) ? COLORS.danger : COLORS.muted)
              .width('100%')

            if (describeAiToolCall(this.toolForDisplay(tool, key), false).fields.length > 0) {
              Column({ space: 4 }) {
                ForEach(describeAiToolCall(this.toolForDisplay(tool, key), false).fields, (f: AiToolField, idx: number) => {
                  this.ToolStructuredFieldRow(f)
                }, (f: AiToolField, idx: number): string => `${idx}:${f.label}:${f.value}`)
              }
              .width('100%')
              .padding(8)
              .backgroundColor(COLORS.surface)
              .border({ width: 0.6, color: COLORS.border })
              .borderRadius(8)
            }

            if (this.toolForDisplay(tool, key).arguments.length > 0 || this.toolForDisplay(tool, key).result.length > 0) {
              Button(this.expandedRawTools.includes(key) ? '收起原始 JSON' : '查看原始参数与返回 JSON', { type: ButtonType.Normal })
                .height(22)
                .padding(0)
                .fontSize(10)
                .fontColor(COLORS.primary)
                .backgroundColor(Color.Transparent)
                .onClick(() => { this.toggleRawTool(key); })

              if (this.expandedRawTools.includes(key)) {
                if (this.toolForDisplay(tool, key).arguments.length > 0) {
                  Text('调用参数').fontSize(10).fontColor(COLORS.muted).width('100%')
                  AiMarkdownBody({ content: this.toolForDisplay(tool, key).arguments, code: true, fontSize: 11,
                    streaming: key.startsWith('0:') && this.isLoading }).width('100%')
                }
                if (this.toolForDisplay(tool, key).result.length > 0) {
                  Text('返回数据').fontSize(10).fontColor(COLORS.muted).width('100%')
                  AiMarkdownBody({ content: this.toolForDisplay(tool, key).result, code: true, fontSize: 11,
                    streaming: key.startsWith('0:') && this.isLoading }).width('100%')
                }
              }
            }
          }
          .width('100%')
          .padding({ left: 6, right: 4, bottom: 4 })
          .alignItems(HorizontalAlign.Start)
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').alignItems(VerticalAlign.Top).margin({ top: 4, bottom: 2 })
  }

  @Builder
  PlanChecklist(tools: AiChatToolState[], key: string) {
    if (this.planForDisplay(tools, key).length > 0) {
      Column({ space: 6 }) {
        Text('执行计划').fontSize(UI.fontBody).fontColor(COLORS.ink).fontWeight(FontWeight.Medium)
        ForEach(this.planForDisplay(tools, key), (step: AiPlanStepView) => {
          Row({ space: 8 }) {
            DrawnStatusIcon({
              kind: step.status === 'completed'
                ? 'success'
                : (step.status === 'in_progress'
                  ? 'radio'
                  : (step.status === 'blocked' ? 'warning' : (step.status === 'cancelled' ? 'error' : 'active'))),
              iconSize: 15,
              strokeColor: step.status === 'completed'
                ? COLORS.success
                : (step.status === 'in_progress' ? COLORS.primary : (step.status === 'blocked' ? COLORS.warning : COLORS.muted)),
              showSoftPlate: step.status === 'completed' || step.status === 'in_progress'
            })
            Text(this.planContentLabel(step)).fontSize(12).fontColor(COLORS.ink).layoutWeight(1)
            Text(this.planStatusLabel(step)).fontSize(11).fontColor(COLORS.muted)
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (step: AiPlanStepView): string => `${step.id}:${step.content}:${step.status}`)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
        .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).margin({ top: 6, bottom: 6 })
    }
  }

  /** DSH-style collapsible Agent Tool Trace Accordion (Plan + Tool Calls). Thinking is rendered in its own top-level card. */
  @Builder
  AgentTraceAccordion(tools: AiChatToolState[], traceKey: string, isLive: boolean) {
    if (tools.length > 0) {
      Column({ space: 6 }) {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            if (isLive) {
              LoadingProgress().width(14).height(14).color(COLORS.primary)
            } else {
              Circle({ width: 7, height: 7 })
                .fill(tools.some((t: AiChatToolState): boolean => this.toolFailed(t)) ? COLORS.danger : COLORS.success)
            }
            Text(this.traceSummaryText(tools, '', isLive))
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            WorkbenchIcon({
              name: (isLive || this.expandedTraces.includes(traceKey)) ? 'chevronUp' : 'chevronDown',
              iconSize: 13,
              color: COLORS.muted
            })
          }.width('100%').alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .height(32)
        .padding({ left: 10, right: 10 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: isLive ? withAlpha(COLORS.primary, 0.35) : COLORS.border })
        .borderRadius(10)
        .onClick(() => {
          if (!isLive) this.toggleTrace(traceKey);
        })

        if (isLive || this.expandedTraces.includes(traceKey)) {
          Column({ space: 4 }) {
            this.PlanChecklist(tools, traceKey)
            ForEach(tools, (tool: AiChatToolState) => {
              this.ToolCard(tool, `${traceKey}:${tool.id}`)
            }, (tool: AiChatToolState): string => tool.id)
          }
          .width('100%')
          .padding({ left: 8, right: 8, top: 4, bottom: 6 })
          .backgroundColor(withAlpha(COLORS.surfaceMuted, 0.65))
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(10)
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .margin({ bottom: 6 })
    }
  }

  /** Live Builder expressions must read observed props, not capture a one-time ChatMessage. */
  @Builder
  LiveAssistantRow() {
    Row() {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          if (this.isLoading) {
            LoadingProgress().width(14).height(14).color(COLORS.primary)
          } else {
            WorkbenchIcon({ name: 'sparkles', iconSize: 13, color: COLORS.primary })
          }
          Text('鸿图 Agent').fontSize(12).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
          Text(this.generationStatus || (this.liveAssistantVisible() ? '思考与绘图中…' : '正在连接模型…'))
            .fontSize(11)
            .fontColor(COLORS.primary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }.width('100%').height(20).alignItems(VerticalAlign.Center).margin({ bottom: 2 })

        if (splitInlineThinking(this.streamingText, this.reasoningText).thinking.length > 0) {
          this.ThinkingDisclosureCard(
            splitInlineThinking(this.streamingText, this.reasoningText).thinking,
            'live:thinking',
            true,
            splitInlineThinking(this.streamingText, this.reasoningText).isStreamingThink ||
              (this.reasoningText.length > 0 && splitInlineThinking(this.streamingText, this.reasoningText).answer.length === 0),
            true
          )
        }

        this.AgentTraceAccordion(this.toolCalls, '0', true)

        if (splitInlineThinking(this.streamingText, this.reasoningText).answer.length > 0) {
          AiMarkdownBody({ content: splitInlineThinking(this.streamingText, this.reasoningText).answer, streaming: this.isLoading,
            fontSize: this.desktopMode ? UI.fontBody : 12 })
            .width('100%').padding({ left: 2, right: 2, top: 4, bottom: 4 })
            .backgroundColor(Color.Transparent).borderRadius(RADIUS.md)
        }
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }.width('100%').justifyContent(FlexAlign.Start).padding({ top: 6, bottom: 6 })
  }

  /** DSH-style Agent message row: right-aligned user pill vs left-aligned Agent turn with first-class Thinking + Trace + Answer. */
  @Builder
  ChatMessageRow(msg: ChatMessage) {
    if (msg.role === ChatRole.USER) {
      Row() {
        Text(this.messageText(msg))
          .fontSize(this.desktopMode ? 13 : 12)
          .lineHeight(20)
          .fontColor(COLORS.ink)
          .backgroundColor(COLORS.primarySoft)
          .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.24) })
          .borderRadius({ topLeft: 16, topRight: 4, bottomLeft: 16, bottomRight: 16 })
          .padding({ left: 13, right: 13, top: 9, bottom: 9 })
          .constraintSize({ maxWidth: '86%' })
          .copyOption(CopyOptions.LocalDevice)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
      .padding({ top: 6, bottom: 6 })
    } else {
      Row() {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            WorkbenchIcon({ name: msg.role === ChatRole.SYSTEM ? 'info' : 'sparkles', iconSize: 13,
              color: msg.role === ChatRole.SYSTEM ? COLORS.muted : COLORS.primary })
            Text(msg.role === ChatRole.SYSTEM ? '系统' : '鸿图 Agent')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
            if (msg.role === ChatRole.ASSISTANT && msg.runStatus !== undefined) {
              Text(msg.runStatus === 'completed' ? '已完成' : (msg.runStatus === 'cancelled' ? '已取消' : '未完成'))
                .fontSize(10)
                .fontColor(msg.runStatus === 'completed' ? COLORS.success : COLORS.warning)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(msg.runStatus === 'completed' ? withAlpha(COLORS.success, 0.12) : withAlpha(COLORS.warning, 0.14))
                .borderRadius(RADIUS.capsule)
            }
            if (msg.isCommand && msg.commandStatus !== undefined) {
              Text(this.commandStatusLabel(msg))
                .fontSize(10)
                .fontColor(msg.commandStatus === 'executed' ? COLORS.success :
                  (msg.commandStatus === 'failed' ? COLORS.danger : COLORS.muted))
            }
          }.width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 2 })

          if (msg.role === ChatRole.ASSISTANT &&
            splitInlineThinking(this.messageText(msg), msg.reasoning ?? '').thinking.length > 0) {
            this.ThinkingDisclosureCard(
              splitInlineThinking(this.messageText(msg), msg.reasoning ?? '').thinking,
              `msg:${msg.timestamp}`,
              false,
              false,
              this.isLatestAssistantMessage(msg)
            )
          }

          if (msg.role === ChatRole.ASSISTANT) {
            this.AgentTraceAccordion(msg.tools ?? [], `${msg.timestamp}`, false)
          }

          if (splitInlineThinking(this.messageText(msg), msg.reasoning ?? '').answer.length > 0) {
            if (msg.role === ChatRole.ASSISTANT) {
              AiMarkdownBody({
                content: splitInlineThinking(this.messageText(msg), msg.reasoning ?? '').answer,
                streaming: msg.timestamp === 0 && this.isLoading,
                fontSize: this.desktopMode ? UI.fontBody : 12
              })
                .width('100%').padding({ left: 2, right: 2, top: 4, bottom: 4 })
                .backgroundColor(msg.commandStatus === 'failed' ? withAlpha(COLORS.danger, ALPHA.SELECTED) : Color.Transparent)
                .borderRadius(RADIUS.md)
            } else {
              Text(this.messageText(msg))
                .fontSize(this.desktopMode ? 13 : 12)
                .fontColor(COLORS.ink)
                .backgroundColor(msg.commandStatus === 'failed' ? withAlpha(COLORS.danger, ALPHA.SELECTED) : COLORS.surfaceMuted)
                .borderRadius(RADIUS.md)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .width('100%')
            }
          }

          if (msg.role === ChatRole.ASSISTANT && !this.isLoading && this.messageText(msg).length > 0) {
            Row({ space: 6 }) {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 4 }) {
                  WorkbenchIcon({ name: 'copy', iconSize: 12, color: COLORS.muted })
                  Text('复制').fontSize(11).fontColor(COLORS.muted)
                }.alignItems(VerticalAlign.Center)
              }
              .height(24).padding({ left: 7, right: 7 }).backgroundColor(Color.Transparent).borderRadius(6)
              .onClick(() => { this.copyPlainText(this.messageText(msg), '已复制回复内容'); })

              Button('追问', { type: ButtonType.Normal })
                .height(24).padding({ left: 7, right: 7 }).fontSize(11).fontColor(COLORS.muted)
                .backgroundColor(Color.Transparent).borderRadius(6)
                .onClick(() => { this.quoteForFollowUp(msg); })

              if (this.isLatestAssistantMessage(msg) && this.latestUserPrompt().trim().length > 0) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 4 }) {
                    WorkbenchIcon({ name: 'reset', iconSize: 12, color: COLORS.muted })
                    Text('重试').fontSize(11).fontColor(COLORS.muted)
                  }.alignItems(VerticalAlign.Center)
                }
                .height(24).padding({ left: 7, right: 7 }).backgroundColor(Color.Transparent).borderRadius(6)
                .onClick(() => { this.retryLatestTurn(); })
              }
            }.width('100%').alignItems(VerticalAlign.Center)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .justifyContent(FlexAlign.Start)
      .padding({ top: 6, bottom: 8 })
    }
  }

  @Builder
  AgentConnectionSummary() {
    Row({ space: 8 }) {
      Text(this.activeModelLabel()).fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (aiService.getConfig().provider !== AiProvider.DEMO_MODE) {
        Button('连接设置', { type: ButtonType.Normal }).height(26).padding({ left: 8, right: 8 }).fontSize(UI.fontCaption)
          .fontColor(COLORS.primary).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy).onClick(this.openAgentConnectionAction)
      }
    }.width('100%').alignItems(VerticalAlign.Center).padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .border({ width: { bottom: 1 }, color: COLORS.border })
  }

  @Builder
  LegacyPanel() {
    Column() {
      OverlayHeader({ title: 'AI 版图助手', closeAction: this.closeAction })
      this.SessionNavigation()
      if (!this.showConversations && !this.showContext && !this.showSettings) {
        this.ContextChips()
      }
      this.DesktopConversation()
      if (!this.showConversations && !this.showContext && !this.showSettings) {
        Scroll() {
          Row({ space: 6 }) {
            this.QuickPrompt('隐藏 M3', '隐藏 M3，只看 M1/M2 互连')
            this.QuickPrompt('检查当前规则', '运行当前规则检查，并定位已知 DRC 问题')
            this.QuickPrompt('画反相器', '画一个反相器')
            this.TemplateToggle()
          }
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
          .clip(true)
          .padding({ left: 12, right: 12, top: 6 })
      }
      if (!this.showConversations && !this.showContext && !this.showSettings) {
        if (this.showTaskTemplate) {
          Column() {
            this.ArrayTaskTemplate()
          }.width('100%').padding({ left: 12, right: 12, top: 6 })
        }
      Row({ space: 8 }) {
        TextInput({ text: $$this.inputText, placeholder: this.pendingSummary.length > 0 ? '继续补充修改要求…' : '描述你的版图需求…' })
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .onSubmit(() => { this.sendInput(); })
          .layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        Button({ type: ButtonType.Normal }) {
          this.SendArrowGlyph()
        }.width(UI.controlHeight).height(UI.controlHeight).padding(0)
          .focusable(false).focusOnTouch(false)
          .backgroundColor(COLORS.primary).borderRadius(UI.controlRadius)
          .accessibilityText('发送消息')
          .enabled(this.inputText.trim().length > 0 && !this.isLoading && !this.configBusy)
          .onClick(() => { this.sendInput(); })
      }.width('100%').padding(12)
      }
    }
    .width(this.isCompact ? 296 : 360)
    .height(Math.min(this.panelHeight, 640))
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
  }

  @Builder
  SessionNavigation() {
    Column({ space: 6 }) {
      Text(this.activeConversationTitle()).fontSize(UI.fontBody).fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      Row() {
        StableSegmentButton({
          items: [
            { text: '聊天' },
            { text: '会话' },
            { text: '上下文' },
            { text: '供应商' }
          ] as [
            SegmentButtonTextItem,
            SegmentButtonTextItem,
            SegmentButtonTextItem,
            SegmentButtonTextItem
          ] as SegmentButtonItemTuple,
          selectedIndex: this.showConversations ? 1 : (this.showContext ? 2 : (this.showSettings ? 3 : 0)),
          onItemClicked: (idx: number) => {
            if (idx === 0) {
              if (this.showConversations) this.openManagement('conversations');
              else if (this.showContext) this.openManagement('context');
              else if (this.showSettings) this.openManagement('settings');
            } else if (idx === 1) {
              if (!this.showConversations) this.openManagement('conversations');
            } else if (idx === 2) {
              if (!this.showContext) this.openManagement('context');
            } else if (idx === 3) {
              if (!this.showSettings) this.openManagement('settings');
            }
          },
          fontColor: COLORS.muted,
          selectedFontColor: COLORS.primary,
          capsuleBackgroundColor: COLORS.surfaceMuted,
          selectedBackgroundColor: COLORS.primarySoft,
          fontSizeFp: UI.fontCaption,
          capsuleBorderRadius: UI.controlRadius,
          buttonMinHeight: 34,
          itemMinHeight: 28,
          itemPaddingHorizontal: 6
        })
      }.width('100%')
      if (this.isLoading || this.configBusy) {
        Text('任务运行中，暂停会话切换、删除和配置修改').fontSize(UI.fontCaption)
          .fontColor(COLORS.muted).width('100%')
        if (this.canCancel && (this.showConversations || this.showContext || this.showSettings)) {
          Button('取消生成').type(ButtonType.Normal).height(UI.compactControlHeight)
            .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .borderRadius(UI.controlRadius)
            .onClick(this.cancelGenerationAction)
        }
      }
    }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 10 })
  }

  @Builder
  TemplateToggle() {
    Button('阵列参数', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontCaption)
      .fontColor(COLORS.primary).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      .enabled(!this.isLoading && !this.configBusy).onClick(() => { this.showTaskTemplate = !this.showTaskTemplate; })
  }

  @Builder
  ArrayTaskTemplate() {
    Column({ space: 8 }) {
      Row() {
        Text('阵列选区参数（单位 nm）')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
        Button('关闭', { type: ButtonType.Normal })
          .height(22)
          .padding({ left: 8, right: 8 })
          .fontSize(11)
          .fontColor(COLORS.muted)
          .backgroundColor(Color.Transparent)
          .borderRadius(6)
          .onClick(() => {
            this.showTaskTemplate = false;
            this.managementStatus = '';
          })
      }.width('100%').alignItems(VerticalAlign.Center)

      Row({ space: 8 }) {
        Column({ space: 4 }) {
          Text('行数').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          // 严守官方规范：CounterComponent 自身不链式追加通用属性，由外层 Column 承载布局
          Column() {
            CounterComponent({
              options: {
                type: CounterType.INLINE,
                inlineOptions: {
                  value: Math.max(1, Number.parseInt(this.templateRows) || 2),
                  min: 1,
                  max: 1000,
                  step: 1,
                  textWidth: 44,
                  onChange: (val: number) => { this.templateRows = `${val}`; }
                }
              }
            })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Column({ space: 4 }) {
          Text('列数').fontSize(UI.fontCaption).fontColor(COLORS.muted)
          Column() {
            CounterComponent({
              options: {
                type: CounterType.INLINE,
                inlineOptions: {
                  value: Math.max(1, Number.parseInt(this.templateColumns) || 2),
                  min: 1,
                  max: 1000,
                  step: 1,
                  textWidth: 44,
                  onChange: (val: number) => { this.templateColumns = `${val}`; }
                }
              }
            })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%')

      Row({ space: 8 }) {
        Text('间距 (nm)').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(64)
        TextInput({ text: this.templatePitch, placeholder: '间距 nm' })
          .id('ai-array-pitch-input')
          .layoutWeight(1).height(34)
          .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .accessibilityText('阵列间距，纳米').onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .onChange((value: string) => { this.templatePitch = value; })
        Button('填入任务', { type: ButtonType.Normal })
          .id('ai-array-fill-btn')
          .height(34)
          .padding({ left: 12, right: 12 })
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy)
          .onClick(() => this.fillArrayTemplate())
      }.width('100%').alignItems(VerticalAlign.Center)

      if (this.managementStatus.length > 0) {
        Text(this.managementStatus).fontSize(UI.fontCaption).fontColor(COLORS.danger).width('100%')
      }
    }
    .id('ai-array-template-card')
    .width('100%')
    .padding(10)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.35) })
    .borderRadius(12)
  }

  @Builder
  ConversationList() {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Search({ value: this.conversationSearch, placeholder: '搜索会话名称' })
          .layoutWeight(1)
          .height(UI.fieldHeight)
          .textFont({ size: UI.fontBody })
          .placeholderFont({ size: UI.fontBody })
          .fontColor(COLORS.ink)
          .placeholderColor(COLORS.muted)
          .searchIcon({ size: 16, color: COLORS.muted })
          .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .onChange((value: string) => { this.conversationSearch = value; })
        Button('导出当前', { type: ButtonType.Normal }).height(UI.controlHeight).padding({ left: 10, right: 10 })
          .fontSize(UI.fontCaption).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .borderRadius(UI.controlRadius).enabled(this.messages.length > 0)
          .onClick(() => {
            const md: string = exportConversationAsMarkdown(this.activeConversationTitle(), this.messages);
            this.managementStatusKind = 'info';
            this.managementStatus = `已导出当前会话 Markdown 至剪贴板（共 ${this.messages.length} 条消息）`;
            this.copyPlainText(md, '当前会话已导出为 Markdown 并复制');
          })
        Button('新建会话').type(ButtonType.Normal).height(UI.controlHeight)
          .fontSize(UI.fontBody).fontColor(Color.White).backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius).enabled(!this.isLoading && !this.configBusy)
          .onClick(() => { this.createConversation(); })
      }.width('100%')
      if (this.visibleConversations().length === 0) {
        Text(this.conversationSearch.trim().length > 0 ? '没有匹配的会话' : '还没有会话，创建后开始聊天')
          .fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%').padding(12)
      }
      ForEach(this.visibleConversations(), (item: AiConversationSummary) => {
        Row({ space: 8 }) {
          Button() {
            Column({ space: 4 }) {
              Text(item.title).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
                .width('100%').textAlign(TextAlign.Start).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${item.messageCount} 条消息 · ${formatRelativeConversationTime(item.updatedAt)}${item.id === this.activeConversationId ? ' · 当前会话' : ''}`)
                .fontSize(UI.fontCaption).fontColor(item.id === this.activeConversationId ? COLORS.primary : COLORS.muted)
                .width('100%').textAlign(TextAlign.Start)
            }.width('100%').alignItems(HorizontalAlign.Start)
          }.type(ButtonType.Normal).layoutWeight(1).height(56).padding(0)
            .backgroundColor(Color.Transparent).borderRadius(UI.controlRadius).enabled(!this.isLoading && !this.configBusy)
            .onClick(() => { this.selectConversation(item.id); })
          Button('重命名').type(ButtonType.Normal).height(UI.compactControlHeight).padding({ left: 8, right: 8 })
            .fontSize(UI.fontCaption).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
            .borderRadius(UI.controlRadius).enabled(!this.isLoading && !this.configBusy)
            .onClick(() => { this.beginRenameConversation(item.id); })
          Button('删除').type(ButtonType.Normal).height(UI.compactControlHeight).padding({ left: 8, right: 8 })
            .fontSize(UI.fontCaption).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
            .borderRadius(UI.controlRadius).enabled(!this.isLoading && !this.configBusy)
            .onClick(() => { this.requestDeleteConversation(item.id); })
        }.width('100%').padding({ left: 8, right: 8, top: 8, bottom: 8 })
          .backgroundColor(item.id === this.activeConversationId ? COLORS.surfaceMuted : Color.Transparent)
          .border({ width: { bottom: 1 }, color: COLORS.border }).borderRadius(UI.controlRadius)
      }, (item: AiConversationSummary): string => `${item.id}:${item.title}:${item.messageCount}:${this.activeConversationId}`)
      if (this.managementStatus.length > 0) {
        Text(this.managementStatus)
          .fontSize(UI.fontCaption)
          .fontColor(this.managementStatusKind === 'info' ? COLORS.success : COLORS.danger)
          .width('100%')
      }
    }.width('100%').padding({ top: 8, bottom: 12 })
  }

  @Builder
  ConversationRenameFooter() {
    Column({ space: 8 }) {
      Text('修改会话名称').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
      TextInput({ text: this.conversationTitleText, placeholder: '输入新的会话名称' })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); }).maxLength(80)
        .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
        .backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        .enabled(!this.isLoading && !this.configBusy)
        .onChange((value: string) => { this.conversationTitleText = value; })
        .onSubmit(() => { this.confirmConversationRename(); })
      Row({ space: 8 }) {
        Button('取消').type(ButtonType.Normal).height(UI.compactControlHeight).layoutWeight(1)
          .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
          .borderRadius(UI.controlRadius).onClick(() => { this.renamingConversationId = ''; })
        Button('保存名称').type(ButtonType.Normal).height(UI.compactControlHeight).layoutWeight(1)
          .fontSize(UI.fontBody).fontColor(Color.White).backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius).enabled(!this.isLoading && !this.configBusy)
          .onClick(() => { this.confirmConversationRename(); })
      }.width('100%')
    }.width('100%').padding(UI.panelPadding).backgroundColor(COLORS.surface)
      .border({ width: { top: 1 }, color: COLORS.border })
  }

  @Builder
  ContextWindowPresetChips(currentWindow: number, onPick: (tokens: number) => void) {
    Row({ space: 6 }) {
      ForEach([16384, 32768, 65536, 131072, 200000, 262144, 1048576], (win: number) => {
        Button(formatCompactTokens(win), { type: ButtonType.Normal })
          .height(26)
          .padding({ left: 9, right: 9 })
          .fontSize(11)
          .fontWeight(currentWindow === win ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(currentWindow === win ? COLORS.primary : COLORS.muted)
          .backgroundColor(currentWindow === win ? COLORS.primarySoft : COLORS.surfaceMuted)
          .borderRadius(RADIUS.capsule)
          .enabled(!this.isLoading && !this.configBusy)
          .onClick(() => { onPick(win); })
      }, (win: number): string => `win-${win}-${currentWindow}`)
    }
  }

  @Builder
  ReasoningEffortChips(currentEffort: AiReasoningEffort, onPick: (effort: AiReasoningEffort) => void) {
    Row({ space: 6 }) {
      ForEach(['auto', 'none', 'low', 'medium', 'high'] as AiReasoningEffort[], (effort: AiReasoningEffort) => {
        Button(reasoningEffortLabel(effort), { type: ButtonType.Normal })
          .height(26)
          .padding({ left: 9, right: 9 })
          .fontSize(11)
          .fontWeight(currentEffort === effort ? FontWeight.Bold : FontWeight.Regular)
          .fontColor(currentEffort === effort ? COLORS.primary : COLORS.muted)
          .backgroundColor(currentEffort === effort ? COLORS.primarySoft : COLORS.surfaceMuted)
          .borderRadius(RADIUS.capsule)
          .enabled(!this.isLoading && !this.configBusy)
          .onClick(() => { onPick(effort); })
      }, (effort: AiReasoningEffort): string => `eff-${effort}-${currentEffort}`)
    }
  }

  /** DSH-Harmony Quick Model & Reasoning Switcher Popover: switch saved models/providers or thinking depth in 1 tap. */
  @Builder
  QuickModelPickerPopover() {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        WorkbenchIcon({ name: 'model', iconSize: 15, color: COLORS.primary })
        Text('快捷切换模型与思考')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
        Button('模型与添加 ›', { type: ButtonType.Normal })
          .height(24)
          .padding({ left: 8, right: 8 })
          .fontSize(11)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(RADIUS.capsule)
          .onClick(() => {
            this.showQuickModelPicker = false;
            this.openManagement('settings');
          })
        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'close', iconSize: 14, color: COLORS.muted })
        }
        .width(24).height(24).padding(0).backgroundColor(Color.Transparent).borderRadius(6)
        .onClick(() => { this.showQuickModelPicker = false; })
      }.width('100%').alignItems(VerticalAlign.Center)

      if (this.providerProfiles.reduce((acc: number, p: AiProviderProfile): number => acc + p.models.length, 0) >= 4) {
        Search({ value: this.quickModelSearch, placeholder: '搜索已添加模型…' })
          .height(32)
          .textFont({ size: 12 })
          .placeholderFont({ size: 12 })
          .fontColor(COLORS.ink)
          .placeholderColor(COLORS.muted)
          .searchIcon({ size: 14, color: COLORS.muted })
          .backgroundColor(COLORS.surfaceMuted)
          .borderRadius(8)
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .onChange((val: string) => { this.quickModelSearch = val; })
      }

      Scroll() {
        Column({ space: 6 }) {
          ForEach(this.providerProfiles, (profile: AiProviderProfile) => {
            Column({ space: 3 }) {
              Row({ space: 6 }) {
                Text(profile.name)
                  .fontSize(11)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(COLORS.muted)
                Text(profile.provider === AiProvider.DEMO_MODE ? '离线演示' : (profile.provider === AiProvider.OLLAMA_LOCAL ? 'Ollama' : 'OpenAI 兼容'))
                  .fontSize(10)
                  .fontColor(COLORS.muted)
              }.width('100%').padding({ left: 6, top: 2 })

              ForEach(
                profile.models.filter((m: AiSavedModel): boolean =>
                  this.quickModelSearch.trim().length === 0 ||
                  m.config.modelName.toLowerCase().includes(this.quickModelSearch.trim().toLowerCase()) ||
                  profile.name.toLowerCase().includes(this.quickModelSearch.trim().toLowerCase())
                ),
                (m: AiSavedModel) => {
                  Button({ type: ButtonType.Normal }) {
                    Row({ space: 8 }) {
                      Circle({ width: 6, height: 6 })
                        .fill(aiService.getActiveProfileId() === profile.id && profile.activeModelId === m.id
                          ? COLORS.primary : COLORS.border)
                      Text(m.config.modelName)
                        .fontSize(12)
                        .fontWeight(aiService.getActiveProfileId() === profile.id && profile.activeModelId === m.id
                          ? FontWeight.Bold : FontWeight.Regular)
                        .fontColor(aiService.getActiveProfileId() === profile.id && profile.activeModelId === m.id
                          ? COLORS.primary : COLORS.ink)
                        .layoutWeight(1)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(formatCompactTokens(m.config.contextWindowTokens ?? 32768))
                        .fontSize(10)
                        .fontFamily('monospace')
                        .fontColor(COLORS.muted)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .backgroundColor(COLORS.surfaceMuted)
                        .borderRadius(RADIUS.capsule)
                      if (aiService.getActiveProfileId() === profile.id && profile.activeModelId === m.id) {
                        WorkbenchIcon({ name: 'check', iconSize: 13, color: COLORS.primary })
                      }
                    }.width('100%').alignItems(VerticalAlign.Center)
                  }
                  .width('100%')
                  .height(34)
                  .padding({ left: 8, right: 8 })
                  .backgroundColor(aiService.getActiveProfileId() === profile.id && profile.activeModelId === m.id
                    ? COLORS.primarySoft : Color.Transparent)
                  .borderRadius(8)
                  .enabled(!this.isLoading && !this.configBusy)
                  .onClick(() => { this.quickSelectModel(profile.id, m.id); })
                },
                (m: AiSavedModel): string => `${profile.id}:${m.id}:${aiService.getActiveProfileId()}:${profile.activeModelId}`
              )
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (profile: AiProviderProfile): string => `${profile.id}:${profile.models.length}:${profile.activeModelId}`)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 220 })
      .scrollBar(BarState.Auto)

      Divider().color(COLORS.border)

      Row({ space: 6 }) {
        Text('思考强度')
          .fontSize(11)
          .fontColor(COLORS.muted)
        Scroll() {
          this.ReasoningEffortChips(aiService.getConfig().reasoningEffort ?? 'auto', (effort: AiReasoningEffort) => {
            this.quickSetReasoningEffort(effort);
          })
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
    .id('ai-quick-model-picker')
    .width('calc(100% - 20vp)')
    .padding(12)
    .backgroundColor(COLORS.surface)
    .border({ width: 1, color: withAlpha(COLORS.primary, 0.35) })
    .borderRadius(14)
    .shadow(hongTuThemeState.elevation('overlay'))
  }

  /** DSH Full Context & Memory Workbench: live token breakdown, direct 16K~1M window presets, compression & project notes. */
  @Builder
  ContextSettings() {
    Column({ space: 12 }) {
      // Card 1: Live Token Budget + Direct Model Context Window Switcher
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text('上下文窗口与实时占用')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
          Text(this.tokenMeterState().badgeText)
            .fontSize(11)
            .fontFamily('monospace')
            .fontColor(this.tokenMeterState().nearThreshold ? COLORS.warning : COLORS.primary)
        }.width('100%').alignItems(VerticalAlign.Center)

        Progress({ value: this.tokenMeterState().percent, total: 100, type: ProgressType.Linear })
          .color(this.tokenMeterState().nearThreshold ? COLORS.warning : COLORS.primary)
          .backgroundColor(COLORS.surface)
          .style({ strokeWidth: 7 })
          .width('100%')

        Column({ space: 5 }) {
          Row() {
            Text('系统与工具协议预留').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
            Text('6,000 tokens').fontSize(11).fontFamily('monospace').fontColor(COLORS.ink)
          }.width('100%')
          Row() {
            Text('模型最大输出预留').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
            Text(`${aiService.getConfig().maxTokens.toLocaleString()} tokens`).fontSize(11).fontFamily('monospace').fontColor(COLORS.ink)
          }.width('100%')
          Row() {
            Text('版图快照 + 历史 + 草稿估算').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
            Text(`${Math.max(0, this.tokenMeterState().usedTokens - 6000 - aiService.getConfig().maxTokens).toLocaleString()} tokens`)
              .fontSize(11).fontFamily('monospace').fontColor(COLORS.primary)
          }.width('100%')
          Row() {
            Text('剩余可用上下文余量').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
            Text(`${Math.max(0, this.tokenMeterState().windowTokens - this.tokenMeterState().usedTokens).toLocaleString()} tokens`)
              .fontSize(11).fontFamily('monospace').fontColor(COLORS.success)
          }.width('100%')
        }
        .width('100%')
        .padding(9)
        .backgroundColor(COLORS.surface)
        .border({ width: 0.6, color: COLORS.border })
        .borderRadius(8)

        Text('快捷切换当前模型窗口容量')
          .fontSize(11)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.muted)
          .width('100%')

        Scroll() {
          this.ContextWindowPresetChips(aiService.getConfig().contextWindowTokens ?? 32768, (win: number) => {
            this.contextCustomWindowText = String(win);
            this.quickApplyContextPolicy(win, undefined, undefined);
          })
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)

        Row({ space: 8 }) {
          TextInput({ text: this.contextCustomWindowText, placeholder: '自定义窗口 token（8192–2097152）' })
            .id('ai-context-window-input')
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surface)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(8)
            .enabled(!this.isLoading && !this.configBusy)
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .onChange((val: string) => { this.contextCustomWindowText = val; })
          Button('应用容量', { type: ButtonType.Normal })
            .id('ai-apply-window-btn')
            .height(34)
            .padding({ left: 12, right: 12 })
            .fontSize(12)
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.primarySoft)
            .borderRadius(8)
            .enabled(!this.isLoading && !this.configBusy)
            .onClick(() => {
              this.quickApplyContextPolicy(Number(this.contextCustomWindowText.trim()), undefined, undefined);
            })
        }.width('100%')
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      // Card 2: Auto-Compression, Summary Inspector & Clear Context
      Column({ space: 10 }) {
        Text('历史压缩与上下文清理')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .width('100%')

        SettingsToggleRow({
          title: '达到阈值自动压缩早期对话',
          isOn: aiService.getConfig().autoCompress ?? false,
          enabledState: !this.isLoading && !this.configBusy,
          compact: true,
          onToggle: (value: boolean) => {
            this.quickApplyContextPolicy(undefined, undefined, value);
          }
        })

        Row({ space: 6 }) {
          Text('压缩触发阈值').fontSize(11).fontColor(COLORS.muted)
          Blank().layoutWeight(1)
          ForEach([60, 70, 80, 90], (pct: number) => {
            Button(`${pct}%`, { type: ButtonType.Normal })
              .height(24)
              .padding({ left: 8, right: 8 })
              .fontSize(11)
              .fontColor(this.tokenMeterState().thresholdPercent === pct ? COLORS.primary : COLORS.muted)
              .backgroundColor(this.tokenMeterState().thresholdPercent === pct ? COLORS.primarySoft : COLORS.surface)
              .borderRadius(RADIUS.capsule)
              .enabled(!this.isLoading && !this.configBusy)
              .onClick(() => { this.quickApplyContextPolicy(undefined, pct, undefined); })
          }, (pct: number): string => `thr-${pct}-${this.tokenMeterState().thresholdPercent}`)
        }.width('100%').alignItems(VerticalAlign.Center)

        Column({ space: 6 }) {
          Row() {
            Text((this.compressionSummary || '尚未压缩会话').split('\n')[0])
              .fontSize(12)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            if (this.compressionSummary.includes('\n')) {
              Button(this.showCompressedSummaryText ? '收起摘要' : '查看摘要', { type: ButtonType.Normal })
                .height(22).padding({ left: 6, right: 6 }).fontSize(11).fontColor(COLORS.primary)
                .backgroundColor(Color.Transparent)
                .onClick(() => { this.showCompressedSummaryText = !this.showCompressedSummaryText; })
            }
          }.width('100%').alignItems(VerticalAlign.Center)

          if (this.showCompressedSummaryText && this.compressionSummary.includes('\n')) {
            Text(this.compressionSummary.substring(this.compressionSummary.indexOf('\n') + 1))
              .fontSize(11)
              .fontColor(COLORS.muted)
              .lineHeight(18)
              .width('100%')
          }
        }
        .width('100%')
        .padding(10)
        .backgroundColor(COLORS.surface)
        .border({ width: 0.6, color: COLORS.border })
        .borderRadius(8)

        Row({ space: 8 }) {
          Button('立即压缩历史', { type: ButtonType.Normal })
            .height(34).layoutWeight(1).fontSize(12)
            .fontColor(Color.White).backgroundColor(COLORS.primary).borderRadius(8)
            .enabled(!this.isLoading && !this.configBusy && this.contextOptions.includeHistory && this.messages.length > 0)
            .onClick(() => { this.compressCurrentConversation(false); })
          Button('恢复完整原文', { type: ButtonType.Normal })
            .height(34).layoutWeight(1).fontSize(12)
            .fontColor(COLORS.ink).backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
            .enabled(!this.isLoading && !this.configBusy)
            .onClick(() => { this.compressCurrentConversation(true); })
          Button('清空消息', { type: ButtonType.Normal })
            .height(34).padding({ left: 10, right: 10 }).fontSize(12)
            .fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft).borderRadius(8)
            .enabled(!this.isLoading && !this.configBusy && this.messages.length > 0)
            .onClick(() => {
              AlertDialog.show({
                title: '清空当前会话消息',
                message: '清空当前会话中的聊天记录与压缩摘要？版图文件不会受影响。',
                cornerRadius: 16,
                primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {} },
                secondaryButton: { value: '清空', fontColor: COLORS.danger, backgroundColor: COLORS.dangerSoft, action: () => {
                  this.clearConversationAction();
                  this.managementStatusKind = 'info';
                  this.managementStatus = '当前会话上下文已清空';
                } }
              });
            })
        }.width('100%')

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(11)
            .fontColor(COLORS.danger)
            .lineHeight(17)
            .width('100%')
            .padding(8)
            .backgroundColor(withAlpha(COLORS.danger, ALPHA.HOVER))
            .borderRadius(8)
        } else if (this.lastResult.startsWith('已压缩') || this.lastResult.startsWith('已恢复发送完整历史')) {
          Text(this.lastResult)
            .fontSize(11)
            .fontColor(COLORS.success)
            .lineHeight(17)
            .width('100%')
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      // Card 3: EDA Payload Scope & Thinking Display Preference
      Column({ space: 8 }) {
        Text('上下文注入范围与展示偏好')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .width('100%')

        SettingsToggleRow({
          title: '携带当前会话历史',
          isOn: this.contextOptions.includeHistory,
          enabledState: !this.isLoading && !this.configBusy,
          compact: true,
          onToggle: (value: boolean) => { this.changeContextOption('history', value); }
        })
        SettingsToggleRow({
          title: '携带当前版图摘要（图层 / Cell / DRC）',
          isOn: this.contextOptions.includeLayout,
          enabledState: !this.isLoading && !this.configBusy,
          compact: true,
          onToggle: (value: boolean) => { this.changeContextOption('layout', value); }
        })
        SettingsToggleRow({
          title: '携带当前选中图形几何明细',
          isOn: this.contextOptions.includeSelection,
          enabledState: !this.isLoading && !this.configBusy,
          compact: true,
          onToggle: (value: boolean) => { this.changeContextOption('selection', value); }
        })
        SettingsToggleRow({
          title: '默认展开模型思考过程',
          isOn: this.autoExpandThinking,
          enabledState: true,
          compact: true,
          onToggle: (value: boolean) => { this.toggleAutoExpandThinking(value); }
        })

        Text(this.contextDetail || this.contextSummary || '当前未附带版图上下文')
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width('100%')
          .lineHeight(18)
          .padding(9)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.6, color: COLORS.border })
          .borderRadius(8)
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      // Card 4: Persistent Document / Process Knowledge Note
      Column({ space: 8 }) {
        Text('当前文档持久说明（工艺/命名约束）')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .width('100%')
        TextArea({
          text: this.projectNoteEditing ? this.projectNoteDraft : this.projectNote,
          placeholder: '填写本版图专属规则（如最小线宽 180nm、顶层电源命名 VDD/VSS），每次请求自动附带…'
        })
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .height(88)
          .maxLength(8000)
          .fontSize(12)
          .fontColor(COLORS.ink)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(8)
          .enabled(!this.isLoading && !this.configBusy)
          .onChange((text: string): void => { this.projectNoteDraft = text; this.projectNoteEditing = true; })
        Button('保存文档说明', { type: ButtonType.Normal })
          .width('100%')
          .height(34)
          .fontSize(12)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(8)
          .enabled(!this.isLoading && !this.configBusy && this.projectNoteEditing)
          .onClick(() => {
            if (this.saveProjectNoteAction(this.projectNoteDraft)) {
              this.projectNoteEditing = false;
              this.managementStatusKind = 'info';
              this.managementStatus = '当前文档说明已保存';
            }
          })
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      if (this.managementStatus.length > 0) {
        Text(this.managementStatus)
          .fontSize(UI.fontCaption)
          .fontColor(this.managementStatusKind === 'info' ? COLORS.success : COLORS.danger)
          .width('100%')
      }
    }.width('100%').padding({ top: 8, bottom: 14 })
  }

  @Builder
  ContextChips() {
    Row({ space: 6 }) {
      Text(this.fileName.length > 0 ? this.fileName : '未打开文件')
        .fontSize(11).fontColor(COLORS.muted).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: this.panelWidth * 0.36 })
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(COLORS.surfaceMuted).borderRadius(RADIUS.capsule)
      if ((this.topCellName || this.cellName).length > 0) {
        Text(this.topCellName.length > 0 ? `Top · ${this.topCellName}` : this.cellName)
          .fontSize(11).fontColor(COLORS.muted).maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: this.panelWidth * 0.24 })
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor(COLORS.surfaceMuted).borderRadius(RADIUS.capsule)
      }
      Text(this.selectionCount > 0 ? `选中 ${this.selectionCount} 个图形` : '未选中图形')
        .fontSize(11).fontColor(this.selectionCount > 0 ? COLORS.primary : COLORS.muted).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: this.panelWidth * 0.32 })
        .padding({ left: 10, right: 10, top: 5, bottom: 5 })
        .backgroundColor(this.selectionCount > 0 ? COLORS.primarySoft : COLORS.surfaceMuted).borderRadius(RADIUS.capsule)
    }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 }).clip(true)
      .onClick(() => { if (!this.isLoading && !this.configBusy) this.openManagement('context'); })
  }

  /** DSH-Harmony Multi-Provider & Multi-Model Studio: clean card layout, searchable catalog with [+ 添加], & 16K~1M window pills. */
  @Builder
  DesktopSettings() {
    Column({ space: 12 }) {
      // Top Strip: Saved Providers Capsules + [+ 新增供应商]
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('已配置供应商')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.muted)
            .layoutWeight(1)
          if (this.selectedProfileId.length > 0 && this.providerProfiles.length > 1) {
            Button('删除当前供应商', { type: ButtonType.Normal })
              .height(22).padding({ left: 6, right: 6 }).fontSize(11)
              .fontColor(COLORS.danger).backgroundColor(Color.Transparent)
              .onClick(() => this.deleteProviderOrModel(false))
          }
        }.width('100%').alignItems(VerticalAlign.Center)

        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.providerProfiles, (p: AiProviderProfile) => {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 5 }) {
                  Circle({ width: 6, height: 6 })
                    .fill(this.selectedProfileId === p.id ? COLORS.primary : COLORS.border)
                  Text(`${p.name} (${p.models.length})`)
                    .fontSize(12)
                    .fontWeight(this.selectedProfileId === p.id ? FontWeight.Bold : FontWeight.Regular)
                    .fontColor(this.selectedProfileId === p.id ? COLORS.primary : COLORS.ink)
                }.alignItems(VerticalAlign.Center)
              }
              .height(30)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.selectedProfileId === p.id ? COLORS.primarySoft : COLORS.surfaceMuted)
              .border({ width: 0.8, color: this.selectedProfileId === p.id ? withAlpha(COLORS.primary, 0.35) : COLORS.border })
              .borderRadius(RADIUS.capsule)
              .onClick(() => { this.switchProviderModel(p.id); })
            }, (p: AiProviderProfile): string => `${p.id}:${p.name}:${p.models.length}:${this.selectedProfileId}`)

            Button('+ 新增供应商', { type: ButtonType.Normal })
              .id('ai-new-provider-btn')
              .height(30)
              .padding({ left: 11, right: 11 })
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.selectedProfileId.length === 0 ? Color.White : COLORS.primary)
              .backgroundColor(this.selectedProfileId.length === 0 ? COLORS.primary : COLORS.surface)
              .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.4) })
              .borderRadius(RADIUS.capsule)
              .onClick(() => this.newProviderDraft())
          }
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
      }.width('100%')

      // Card 1: Provider Connection & Preset Catalog
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.selectedProfileId.length > 0 ? '服务商连接与凭据' : '新建供应商草稿')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
          Button(this.showPresetTemplates ? '收起预设模板' : '套用主流预设 ▾', { type: ButtonType.Normal })
            .height(24)
            .padding({ left: 8, right: 8 })
            .fontSize(11)
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.primarySoft)
            .borderRadius(RADIUS.capsule)
            .onClick(() => { this.showPresetTemplates = !this.showPresetTemplates; })
        }.width('100%').alignItems(VerticalAlign.Center)

        if (this.showPresetTemplates || this.selectedProfileId.length === 0) {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(PRESET_PROVIDERS, (preset: PresetProvider, idx: number) => {
                Button(preset.name, { type: ButtonType.Normal })
                  .height(26)
                  .padding({ left: 10, right: 10 })
                  .fontSize(11)
                  .fontColor(this.selectedProviderIndex === idx ? COLORS.primary : COLORS.ink)
                  .backgroundColor(this.selectedProviderIndex === idx ? COLORS.primarySoft : COLORS.surface)
                  .border({ width: 0.7, color: this.selectedProviderIndex === idx ? withAlpha(COLORS.primary, 0.4) : COLORS.border })
                  .borderRadius(RADIUS.capsule)
                  .onClick(() => { this.applyProviderPreset(idx); })
              }, (preset: PresetProvider, idx: number): string => `preset-${idx}-${preset.name}`)
            }
          }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        }

        Row({ space: 6 }) {
          ForEach(
            [AiProvider.OPENAI_COMPATIBLE, AiProvider.OLLAMA_LOCAL, AiProvider.DEMO_MODE],
            (proto: AiProvider) => {
              Button(
                proto === AiProvider.OPENAI_COMPATIBLE
                  ? 'OpenAI 兼容'
                  : (proto === AiProvider.OLLAMA_LOCAL ? 'Ollama 本地' : '离线演示'),
                { type: ButtonType.Normal }
              )
                .layoutWeight(1)
                .height(28)
                .fontSize(11)
                .fontWeight(this.providerValue === proto ? FontWeight.Bold : FontWeight.Regular)
                .fontColor(this.providerValue === proto ? COLORS.primary : COLORS.muted)
                .backgroundColor(this.providerValue === proto ? COLORS.primarySoft : COLORS.surface)
                .border({ width: 0.7, color: this.providerValue === proto ? withAlpha(COLORS.primary, 0.35) : COLORS.border })
                .borderRadius(8)
                .onClick(() => {
                  this.providerValue = proto;
                  this.discoveredModels = [];
                  this.discoveredCatalog = [];
                })
            },
            (proto: AiProvider): string => `${proto}:${this.providerValue}`
          )
        }.width('100%')

        TextInput({ text: this.profileNameText, placeholder: '供应商显示名称（如 WorkBuddy / 硅基流动 / DeepSeek）' })
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .width('100%').height(36).fontSize(12).fontColor(COLORS.ink)
          .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
          .onChange((value: string) => { this.profileNameText = value; })

        if (this.providerValue !== AiProvider.DEMO_MODE) {
          TextInput({ text: this.endpointText, placeholder: 'API 基础地址（如 https://api.deepseek.com/v1）' })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .width('100%').height(36).fontSize(12).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
            .onChange((value: string) => { this.endpointText = value; this.discoveredModels = []; this.discoveredCatalog = []; })

          TextInput({
            text: this.apiKeyText,
            placeholder: this.credentialReady && this.selectedProfileId.length > 0
              ? 'API Key 已存系统安全凭据（留空保留原密钥，输入则替换）'
              : '填写该服务商的 API Key（本地免密服务可留空）'
          })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .type(InputType.Password)
            .width('100%').height(36).fontSize(12).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
            .onChange((value: string) => { this.apiKeyText = value; this.discoveredModels = []; this.discoveredCatalog = []; })

          if (!this.credentialReady && this.selectedProfileId.length > 0) {
            Row({ space: 8 }) {
              Text('系统凭据待重新读取').fontSize(11).fontColor(COLORS.warning).layoutWeight(1)
              Button('重试读取', { type: ButtonType.Normal }).height(24).padding({ left: 8, right: 8 }).fontSize(11)
                .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(6)
                .onClick(() => { this.reloadProviderCredentials(); })
            }.width('100%')
          }

          Row({ space: 8 }) {
            Button(this.showAdvancedModelsUrl ? '收起自定义目录地址' : '自定义模型目录地址（可选）', { type: ButtonType.Normal })
              .height(22).padding(0).fontSize(11).fontColor(COLORS.muted).backgroundColor(Color.Transparent)
              .onClick(() => { this.showAdvancedModelsUrl = !this.showAdvancedModelsUrl; })
            Blank().layoutWeight(1)
            Button('伴随服务设置', { type: ButtonType.Normal })
              .height(24).padding({ left: 8, right: 8 }).fontSize(11)
              .fontColor(COLORS.primary).backgroundColor(COLORS.surface)
              .border({ width: 0.7, color: COLORS.border }).borderRadius(RADIUS.capsule)
              .onClick(this.openAgentConnectionAction)
            Button('检查伴随端', { type: ButtonType.Normal })
              .height(24).padding({ left: 8, right: 8 }).fontSize(11)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surface)
              .border({ width: 0.7, color: COLORS.border }).borderRadius(RADIUS.capsule)
              .enabled(!this.connectionBusy)
              .onClick(() => { this.refreshAgentConnection(true); })
          }.width('100%').alignItems(VerticalAlign.Center)

          if (this.showAdvancedModelsUrl) {
            TextInput({ text: this.modelsEndpointText, placeholder: '留空自动拼接 /models；特殊网关可填完整目录 URL' })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .width('100%').height(34).fontSize(12).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
              .onChange((value: string) => { this.modelsEndpointText = value; this.discoveredModels = []; this.discoveredCatalog = []; })
          }
          Text(this.agentConnectionText).fontSize(11).fontColor(COLORS.muted).width('100%').maxLines(2)
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      // Card 2: Saved Models Pool + Manual [+ 添加] + Searchable Remote Model Catalog with [+ 添加]
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(`已添加的模型（${this.selectedProfileId.length > 0 ? this.savedModels().length : Math.max(this.pendingDraftModels.length, this.modelNameText.trim().length > 0 ? 1 : 0)}）`)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
          if (this.discoveryBusy) {
            LoadingProgress().width(16).height(16).color(COLORS.primary)
            Button('取消获取', { type: ButtonType.Normal })
              .height(26).padding({ left: 8, right: 8 }).fontSize(11)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surface).borderRadius(RADIUS.capsule)
              .onClick(() => aiService.cancelModelDiscovery())
          } else if (this.providerValue === AiProvider.OPENAI_COMPATIBLE || this.providerValue === AiProvider.OLLAMA_LOCAL) {
            Button('获取远端模型目录', { type: ButtonType.Normal })
              .id('ai-fetch-models-btn')
              .height(28)
              .padding({ left: 10, right: 10 })
              .fontSize(11)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.primary)
              .backgroundColor(COLORS.primarySoft)
              .borderRadius(RADIUS.capsule)
              .onClick(() => { this.fetchModels(); })
          }
        }.width('100%').alignItems(VerticalAlign.Center)

        // Saved models list under this provider
        if (this.selectedProfileId.length > 0 && this.savedModels().length > 0) {
          Column({ space: 4 }) {
            ForEach(this.savedModels(), (m: AiSavedModel) => {
              Row({ space: 6 }) {
                Button({ type: ButtonType.Normal }) {
                  Row({ space: 6 }) {
                    Circle({ width: 7, height: 7 })
                      .fill(this.selectedModelId === m.id ? COLORS.primary : COLORS.border)
                    Text(m.config.modelName)
                      .fontSize(12)
                      .fontWeight(this.selectedModelId === m.id ? FontWeight.Bold : FontWeight.Regular)
                      .fontColor(this.selectedModelId === m.id ? COLORS.primary : COLORS.ink)
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(formatCompactTokens(m.config.contextWindowTokens ?? 32768))
                      .fontSize(10)
                      .fontFamily('monospace')
                      .fontColor(COLORS.muted)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .backgroundColor(COLORS.surfaceMuted)
                      .borderRadius(RADIUS.capsule)
                    if (this.selectedModelId === m.id) {
                      Text('当前')
                        .fontSize(10)
                        .fontColor(COLORS.primary)
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .backgroundColor(COLORS.primarySoft)
                        .borderRadius(RADIUS.capsule)
                    }
                  }.width('100%').alignItems(VerticalAlign.Center)
                }
                .layoutWeight(1)
                .height(34)
                .padding({ left: 8, right: 8 })
                .backgroundColor(this.selectedModelId === m.id ? COLORS.surface : Color.Transparent)
                .borderRadius(8)
                .onClick(() => { this.switchProviderModel(this.selectedProfileId, m.id); })

                if (this.savedModels().length > 1) {
                  Button({ type: ButtonType.Normal }) {
                    WorkbenchIcon({ name: 'delete', iconSize: 13, color: COLORS.danger })
                  }
                  .width(28).height(28).padding(0)
                  .backgroundColor(COLORS.dangerSoft).borderRadius(6)
                  .accessibilityText(`移除模型 ${m.config.modelName}`)
                  .onClick(() => { this.deleteProviderOrModel(true, m.id); })
                }
              }.width('100%').alignItems(VerticalAlign.Center)
            }, (m: AiSavedModel): string => `${m.id}:${m.config.modelName}:${m.config.contextWindowTokens}:${this.selectedModelId}`)
          }.width('100%')
        } else if (this.pendingDraftModels.length > 0) {
          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.pendingDraftModels, (draftId: string) => {
                Button(`${draftId} ×`, { type: ButtonType.Normal })
                  .height(26).padding({ left: 8, right: 8 }).fontSize(11)
                  .fontColor(this.modelNameText === draftId ? COLORS.primary : COLORS.ink)
                  .backgroundColor(COLORS.surface).borderRadius(RADIUS.capsule)
                  .onClick(() => {
                    this.pendingDraftModels = this.pendingDraftModels.filter((x: string): boolean => x !== draftId);
                    if (this.modelNameText === draftId) {
                      this.modelNameText = this.pendingDraftModels[0] ?? '';
                    }
                  })
              }, (draftId: string): string => draftId)
            }
          }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
        }

        // Manual quick-add model ID bar
        Row({ space: 6 }) {
          TextInput({ text: this.manualNewModelText, placeholder: '输入模型 ID 手动添加（如 deepseek-reasoner / qwen3-coder）' })
            .id('ai-manual-model-input')
            .layoutWeight(1)
            .height(34)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surface)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(8)
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .onChange((val: string) => { this.manualNewModelText = val; })
            .onSubmit(() => { this.addModelFromInputOrCatalog(this.manualNewModelText, 0, true); })
          Button('+ 添加模型', { type: ButtonType.Normal })
            .id('ai-manual-add-model-btn')
            .height(34)
            .padding({ left: 11, right: 11 })
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(COLORS.primary)
            .borderRadius(8)
            .enabled(this.manualNewModelText.trim().length > 0)
            .onClick(() => { this.addModelFromInputOrCatalog(this.manualNewModelText, 0, true); })
        }.width('100%')

        // Interactive Searchable Remote Model Catalog (replaces old bare dropdown!)
        if (this.discoveredCatalog.length > 0) {
          Column({ space: 8 }) {
            Row({ space: 6 }) {
              Text(`远端目录（共 ${this.discoveredCatalog.length} 个，筛选 ${this.filteredCatalogModels().length} 个）`)
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLORS.ink)
                .layoutWeight(1)
              Button('批量添加前 8 项', { type: ButtonType.Normal })
                .height(22).padding({ left: 8, right: 8 }).fontSize(10)
                .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(RADIUS.capsule)
                .onClick(() => { this.batchAddFilteredCatalogModels(); })
              Button('收起', { type: ButtonType.Normal })
                .height(22).padding({ left: 6, right: 6 }).fontSize(10)
                .fontColor(COLORS.muted).backgroundColor(Color.Transparent)
                .onClick(() => { this.discoveredCatalog = []; this.discoveredModels = []; })
            }.width('100%').alignItems(VerticalAlign.Center)

            Search({ value: this.catalogSearchText, placeholder: '在已获取目录中搜索模型名或关键词…' })
              .id('ai-catalog-search')
              .height(32)
              .textFont({ size: 12 })
              .placeholderFont({ size: 12 })
              .fontColor(COLORS.ink)
              .placeholderColor(COLORS.muted)
              .searchIcon({ size: 14, color: COLORS.muted })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(8)
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((val: string) => { this.catalogSearchText = val; })

            Row({ space: 6 }) {
              ForEach(['全部', '推理', '文本', '视觉'], (cat: string) => {
                Button(cat, { type: ButtonType.Normal })
                  .height(24).padding({ left: 9, right: 9 }).fontSize(11)
                  .fontColor(this.catalogCategory === cat ? COLORS.primary : COLORS.muted)
                  .backgroundColor(this.catalogCategory === cat ? COLORS.primarySoft : COLORS.surfaceMuted)
                  .borderRadius(RADIUS.capsule)
                  .onClick(() => { this.catalogCategory = cat; })
              }, (cat: string): string => `cat-${cat}-${this.catalogCategory}`)
            }.width('100%')

            Scroll() {
              Column({ space: 4 }) {
                ForEach(this.filteredCatalogModels(), (spec: AiDiscoveredModelSpec) => {
                  Row({ space: 8 }) {
                    Column({ space: 2 }) {
                      Text(spec.id)
                        .fontSize(12)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(COLORS.ink)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(`${spec.categories.join(' · ')} · 默认窗口 ${formatCompactTokens(spec.contextWindow)}`)
                        .fontSize(10)
                        .fontColor(COLORS.muted)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                    if (this.isModelSavedInCurrentDraft(spec.id)) {
                      Button('已添加 · 选用', { type: ButtonType.Normal })
                        .height(26).padding({ left: 9, right: 9 }).fontSize(11)
                        .fontColor(COLORS.success).backgroundColor(withAlpha(COLORS.success, 0.12))
                        .borderRadius(RADIUS.capsule)
                        .onClick(() => { this.addModelFromInputOrCatalog(spec.id, spec.contextWindow, true); })
                    } else {
                      Button('+ 添加', { type: ButtonType.Normal })
                        .height(26).padding({ left: 10, right: 10 }).fontSize(11)
                        .fontWeight(FontWeight.Medium)
                        .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
                        .borderRadius(RADIUS.capsule)
                        .onClick(() => { this.addModelFromInputOrCatalog(spec.id, spec.contextWindow, true); })
                    }
                  }
                  .width('100%')
                  .padding({ left: 8, right: 8, top: 6, bottom: 6 })
                  .border({ width: { bottom: 0.5 }, color: COLORS.border })
                }, (spec: AiDiscoveredModelSpec): string => `${spec.id}:${this.isModelSavedInCurrentDraft(spec.id)}`)
              }.width('100%')
            }
            .width('100%')
            .constraintSize({ maxHeight: 220 })
            .scrollBar(BarState.Auto)
          }
          .width('100%')
          .padding(10)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.32) })
          .borderRadius(10)
        }
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)

      // Card 3: Current Model Context Window, Thinking Effort & Output Tuning (Prominently Accessible!)
      Column({ space: 10 }) {
        Row({ space: 6 }) {
          Text('当前模型上下文窗口与推理参数')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
        }.width('100%')

        Row({ space: 8 }) {
          Text('当前编辑模型').fontSize(11).fontColor(COLORS.muted).width(74)
          TextInput({ text: this.modelNameText, placeholder: '当前激活模型 ID' })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .layoutWeight(1).height(34).fontSize(12).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
            .onChange((value: string) => { this.modelNameText = value; })
        }.width('100%').alignItems(VerticalAlign.Center)

        Text('模型上下文窗口容量（点击预设或手动填写）')
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width('100%')

        Scroll() {
          this.ContextWindowPresetChips(Number(this.contextWindowText) || 32768, (win: number) => {
            this.applyWindowPresetInSettings(win);
          })
        }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)

        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text('窗口上限 (tokens)').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.contextWindowText, placeholder: '如 131072' })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .height(34).fontSize(12).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
              .onChange((value: string) => { this.contextWindowText = value; })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            Text('最大输出 (tokens)').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.maxTokensText, placeholder: '如 8192' })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .height(34).fontSize(12).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
              .onChange((value: string) => { this.maxTokensText = value; })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')

        Row({ space: 6 }) {
          Text('输出快捷档').fontSize(11).fontColor(COLORS.muted)
          Scroll() {
            Row({ space: 6 }) {
              ForEach([2048, 4096, 8192, 16384, 32768], (outTok: number) => {
                Button(formatCompactTokens(outTok), { type: ButtonType.Normal })
                  .height(24).padding({ left: 8, right: 8 }).fontSize(11)
                  .fontColor(Number(this.maxTokensText) === outTok ? COLORS.primary : COLORS.muted)
                  .backgroundColor(Number(this.maxTokensText) === outTok ? COLORS.primarySoft : COLORS.surface)
                  .borderRadius(RADIUS.capsule)
                  .onClick(() => {
                    this.maxTokensText = String(outTok);
                    const curWin: number = Number(this.contextWindowText) || 32768;
                    if (outTok + 6000 >= curWin) {
                      this.contextWindowText = String(Math.max(32768, outTok * 2));
                    }
                  })
              }, (outTok: number): string => `out-${outTok}-${this.maxTokensText}`)
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)

        Row({ space: 6 }) {
          Text('思考强度').fontSize(11).fontColor(COLORS.muted)
          Scroll() {
            this.ReasoningEffortChips(this.reasoningEffortValue, (effort: AiReasoningEffort) => {
              this.reasoningEffortValue = effort;
            })
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Center)

        Row({ space: 8 }) {
          Column({ space: 4 }) {
            Text('采样温度 (0–2)').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.temperatureText, placeholder: '0.3' })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .height(34).fontSize(12).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
              .onChange((value: string) => { this.temperatureText = value; })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)

          Column({ space: 4 }) {
            Text('请求超时 (秒)').fontSize(11).fontColor(COLORS.muted)
            TextInput({ text: this.timeoutSecondsText, placeholder: '120' })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .height(34).fontSize(12).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surface).border({ width: 0.8, color: COLORS.border }).borderRadius(8)
              .onChange((value: string) => { this.timeoutSecondsText = value; })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%')

        SettingsToggleRow({
          title: '启用当前模型',
          isOn: this.configEnabled,
          enabledState: !this.isLoading && !this.configBusy,
          compact: true,
          onToggle: (value: boolean) => { this.configEnabled = value; }
        })
      }
      .width('100%')
      .padding(12)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(12)
    }
    .width('100%')
    .padding({ top: 6, bottom: 14 })
    .enabled(!this.isLoading && !this.configBusy)
  }

  /** Compact Single-Row Settings Footer (replaces the old 220vp 4-row stacked footer). */
  @Builder
  SettingsFooter() {
    Column({ space: 6 }) {
      if (this.testStatusText.length > 0) {
        Text(this.testStatusText)
          .fontSize(11)
          .fontColor(/失败|无效|错误|超时/.test(this.testStatusText) ? COLORS.danger : COLORS.primary)
          .lineHeight(16)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      Row({ space: 8 }) {
        Button('测试连接', { type: ButtonType.Normal })
          .height(36)
          .padding({ left: 10, right: 10 })
          .fontSize(12)
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy)
          .onClick(() => { this.testAiConfig(); })

        if (this.providerValue !== AiProvider.DEMO_MODE) {
          Button('工具诊断', { type: ButtonType.Normal })
            .height(36)
            .padding({ left: 10, right: 10 })
            .fontSize(12)
            .backgroundColor(COLORS.surfaceMuted)
            .fontColor(COLORS.ink)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .enabled(!this.isLoading && !this.configBusy)
            .onClick(() => { this.diagnoseAgent(); })
        }

        Button('保存配置', { type: ButtonType.Normal })
          .id('ai-save-config-btn')
          .height(36)
          .layoutWeight(1)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy && this.canSaveProviderDraft())
          .onClick(() => { this.saveAiConfig(); })
      }.width('100%')
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 10 })
    .backgroundColor(COLORS.surface)
    .border({ width: { top: 0.8 }, color: COLORS.border })
  }

  @Builder
  SendArrowGlyph() {
    Shape() {
      Path().commands('M12 19V5M6 11L12 5L18 11')
        .fill(Color.Transparent)
        .stroke(Color.White)
        .strokeWidth('2px')
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
    }
    .viewPort({ x: '0px', y: '0px', width: '24px', height: '24px' })
    .width(18)
    .height(18)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }

  @Builder
  ReviewGroupSwitchRow(spec: AiReviewGroupRowSpec) {
    Row({ space: 8 }) {
      Text(spec.group.title)
        .fontSize(UI.fontCaption)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Toggle({ type: ToggleType.Switch, isOn: spec.accepted })
        .selectedColor(COLORS.primary)
        .height(24)
        .enabled(!this.isLoading)
        .accessibilityText(`接受操作组：${spec.group.title}`)
        .onChange((accepted: boolean) => {
          if (accepted === spec.accepted) return;
          this.toggleReviewGroupAction(spec.group.id, accepted);
        })
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  @Builder
  PendingFieldItem(row: AiPendingFieldRow) {
    Row({ space: 10 }) {
      Text(row.label)
        .fontSize(UI.fontCaption)
        .fontColor(COLORS.muted)
        .width(58)
      Text(row.value)
        .fontSize(UI.fontBody)
        .fontWeight(row.accent ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(row.accent ? COLORS.primary : COLORS.ink)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  PendingChangeCard() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text('待应用的修改')
          .fontSize(UI.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
        if (this.reviewGroups.length > 0 || this.selectionCount > 0) {
          Button('定位', { type: ButtonType.Normal })
            .height(26)
            .padding({ left: 10, right: 10 })
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.primary)
            .backgroundColor(COLORS.surface)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .enabled(!this.isLoading)
            .onClick(this.focusReviewAction)
        }
        Text('预览 · 未应用')
          .fontSize(11)
          .fontColor(COLORS.primary)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(RADIUS.capsule)
      }.width('100%').alignItems(VerticalAlign.Center)

      Column({ space: 7 }) {
        ForEach(this.buildPendingStructuredRows(), (fieldRow: AiPendingFieldRow, idx: number) => {
          this.PendingFieldItem(fieldRow)
        }, (fieldRow: AiPendingFieldRow, idx: number): string => `${idx}:${fieldRow.label}:${fieldRow.value}`)
      }
      .width('100%')
      .padding(10)
      .backgroundColor(COLORS.surface)
      .border({ width: 1, color: COLORS.border })
      .borderRadius(UI.controlRadius)

      if (this.reviewGroups.length > 1) {
        Column({ space: 6 }) {
          ForEach(this.reviewGroupRowSpecs(), (spec: AiReviewGroupRowSpec) => {
            this.ReviewGroupSwitchRow(spec)
          }, (spec: AiReviewGroupRowSpec): string => spec.group.id)
        }.width('100%')
      }

      if (this.pendingDetail.trim().length > 0) {
        Button(this.showPendingRawDetail ? '收起参数明细' : '查看参数明细', { type: ButtonType.Normal })
          .height(24)
          .padding(0)
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.showPendingRawDetail = !this.showPendingRawDetail; })
        if (this.showPendingRawDetail) {
          Text(this.pendingDetail)
            .fontSize(11)
            .fontColor(COLORS.muted)
            .lineHeight(17)
            .width('100%')
            .padding(8)
            .backgroundColor(COLORS.surface)
            .borderRadius(UI.controlRadius)
        }
      }

      Row({ space: 8 }) {
        Blank()
        Button('取消').type(ButtonType.Normal).height(UI.compactControlHeight).padding({ left: 14, right: 14 })
          .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surface)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .enabled(!this.isLoading).onClick(() => { this.cancelPendingAction(); })
        Button('应用修改').type(ButtonType.Normal).height(UI.compactControlHeight).padding({ left: 16, right: 16 })
          .fontSize(UI.fontBody).fontColor(Color.White).backgroundColor(COLORS.primary).borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && (this.reviewGroups.length === 0 || this.reviewGroups.some((group: AiReviewGroup): boolean => group.accepted)))
          .onClick(() => { this.applyPendingAction(); })
      }.width('100%').padding({ top: 2 })
    }
    .width('100%')
    .padding(12)
    .margin({ top: 8, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 1, color: withAlpha(COLORS.primary, 0.34) })
    .borderRadius(RADIUS.md)
  }

  @Builder
  DesktopConversation() {
    Stack({ alignContent: Alignment.Bottom }) {
    Scroll(this.conversationScroller) {
      Column() {
        if (this.showConversations) {
          this.ConversationList()
        } else if (this.showContext) {
          this.ContextSettings()
        } else if (this.showSettings) {
          this.DesktopSettings()
        } else {
          if (this.checkpointSummary.length > 0) {
            Text(this.checkpointSummary).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').lineHeight(18)
              .padding(UI.panelPadding).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          }
          if (this.messages.length === 0 && !this.liveAssistantVisible() && !this.isLoading && this.pendingSummary.length === 0) {
            Column({ space: 14 }) {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  WorkbenchIcon({ name: 'sparkles', iconSize: 18, color: COLORS.primary })
                  Text('鸿图版图 Agent')
                    .fontSize(16)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(COLORS.ink)
                }.alignItems(VerticalAlign.Center)
                Text('读取当前版图、提出可撤销编辑预览或生成参数化脚本（输入 / 唤出快捷指令）')
                  .fontSize(12)
                  .fontColor(COLORS.muted)
              }.width('100%').alignItems(HorizontalAlign.Start)

              Row({ space: 8 }) {
                this.WelcomeCard('search', '解释图形', '读取选中图形坐标与图层', '解释当前选中的图形及其用途')
                this.WelcomeCard('verify', '检查版图', '盘点图层、Cell 与 DRC 状态', '检查当前版图并说明需要关注的问题')
              }.width('100%')
              Row({ space: 8 }) {
                this.WelcomeCard('edit', '提出修复', '生成可预览的最小修改方案', '根据当前选区与 DRC 证据，提出最小修复方案供我预览确认，并在修改后复检；资料不足时先说明，不猜测工艺规则。')
                this.WelcomeCard('sparkles', '画反相器', '通过隔离脚本生成标准单元', '画一个反相器')
              }.width('100%')
            }
            .width('100%')
            .padding({ top: 18, bottom: 14 })
          }
          ForEach(this.messages, (msg: ChatMessage) => {
            this.ChatMessageRow(msg)
          }, (msg: ChatMessage, idx: number) =>
            `${this.activeConversationId}_${idx}_${msg.timestamp}_${msg.commandStatus ?? 'none'}`)
          if (this.isLoading || this.liveAssistantVisible()) {
            this.LiveAssistantRow()
          }
          if (this.errorMessage.length > 0) {
            Column({ space: 8 }) {
              Text(this.errorMessage)
                .fontSize(12)
                .fontColor(COLORS.danger)
                .lineHeight(19)
                .width('100%')
              if (/连接设置|HTTP 401|HTTP 403|认证失败|令牌/.test(this.errorMessage)) {
                Button('打开连接设置', { type: ButtonType.Normal })
                  .height(26)
                  .padding({ left: 10, right: 10 })
                  .fontSize(11)
                  .fontColor(COLORS.primary)
                  .backgroundColor(COLORS.surface)
                  .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.35) })
                  .borderRadius(RADIUS.capsule)
                  .enabled(!this.isLoading && !this.configBusy)
                  .onClick(this.openAgentConnectionAction)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(10)
            .backgroundColor(withAlpha(COLORS.danger, ALPHA.HOVER))
            .borderRadius(UI.controlRadius)
            .margin({ top: 8 })
          }
          if (!this.isLoading && this.pendingSummary.length === 0 && (this.hasInterruptedTurn() || this.hasRecoverableArtifact)) {
            Row({ space: 8 }) {
              if (this.hasInterruptedTurn()) {
                Button('继续任务', { type: ButtonType.Normal }).height(28).padding({ left: 10, right: 10 }).fontSize(UI.fontCaption)
                  .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).borderRadius(RADIUS.capsule)
                  .enabled(!this.configBusy && this.contextOptions.includeHistory).onClick(() => this.continueAgent(false))
              }
              if (this.errorMessage.length > 0 || this.hasInterruptedTurn()) {
                Button('重试未完成', { type: ButtonType.Normal }).height(28).padding({ left: 10, right: 10 }).fontSize(UI.fontCaption)
                  .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(RADIUS.capsule)
                  .enabled(!this.configBusy && this.contextOptions.includeHistory && this.latestUserPrompt().length > 0).onClick(() => this.continueAgent(true))
              }
              if (this.hasRecoverableArtifact) {
                Button('恢复未载入产物', { type: ButtonType.Normal }).height(28).padding({ left: 10, right: 10 }).fontSize(UI.fontCaption)
                  .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft).borderRadius(RADIUS.capsule)
                  .enabled(!this.configBusy).onClick(this.recoverArtifactAction)
              }
            }.width('100%').margin({ top: 6 })
          }
          if (this.isExplicitActionReceipt()) {
            Row({ space: 8 }) {
              Text(this.receiptSummaryText())
                .fontSize(UI.fontCaption)
                .fontColor(COLORS.muted)
                .lineHeight(18)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              if (this.canUndo) {
                Button('撤销')
                  .type(ButtonType.Normal)
                  .height(26)
                  .fontSize(UI.fontCaption)
                  .borderRadius(RADIUS.capsule)
                  .fontColor(COLORS.primary)
                  .backgroundColor(COLORS.surface)
                  .border({ width: 1, color: COLORS.border })
                  .padding({ left: 10, right: 10 })
                  .enabled(!this.isLoading)
                  .onClick(() => { this.undoAction(); })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 10, right: 10, top: 7, bottom: 7 })
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 0.8, color: COLORS.border })
            .borderRadius(10)
            .margin({ top: 8 })
          }
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 12 })
      .onAreaChange((_oldArea: Area, newArea: Area) => {
        const nextContentH: number = Number(newArea.height);
        if (Number.isFinite(nextContentH) && Math.abs(nextContentH - this.chatContentHeight) > 0.5) {
          this.chatContentHeight = nextContentH;
          this.pinConversationToBottomInstant();
        }
      })
    }
    .width('100%')
    .layoutWeight(1)
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
    .clip(true)
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const nextViewportH: number = Number(newArea.height);
      if (Number.isFinite(nextViewportH) && Math.abs(nextViewportH - this.chatViewportHeight) > 0.5) {
        this.chatViewportHeight = nextViewportH;
        this.pinConversationToBottomInstant();
      }
    })
    .onAppear(() => { this.scrollConversationToLatest(); })
    .onWillScroll((_xOffset: number, _yOffset: number, _state: ScrollState, source: ScrollSource) => {
      if (source === ScrollSource.DRAG || source === ScrollSource.FLING ||
        source === ScrollSource.OTHER_USER_INPUT || source === ScrollSource.SCROLL_BAR ||
        source === ScrollSource.SCROLL_BAR_FLING) {
        this.userScrollPending = true;
        this.followsLatest = false;
      }
    })
    .onDidScroll(() => {
      if (this.userScrollPending) {
        this.followsLatest = this.conversationScroller.isAtEnd();
        this.userScrollPending = false;
      }
    })
    if (!this.followsLatest && !this.showConversations && !this.showContext && !this.showSettings) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          WorkbenchIcon({ name: 'chevronDown', iconSize: 13, color: COLORS.primary })
          Text(this.isLoading ? '回到底部 · 实时输出中' : '回到底部')
            .fontSize(11)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.primary)
        }.alignItems(VerticalAlign.Center)
      }
      .height(28)
      .padding({ left: 12, right: 12 })
      .margin({ bottom: 8 })
      .backgroundColor(COLORS.surface)
      .border({ width: 1, color: withAlpha(COLORS.primary, 0.35) })
      .borderRadius(RADIUS.capsule)
      .onClick(() => {
        this.followsLatest = true;
        this.scrollConversationToLatest();
      })
    }
    }.width('100%').layoutWeight(1)
    if (this.showSettings) { this.SettingsFooter() }
    if (this.showConversations && this.renamingConversationId.length > 0) { this.ConversationRenameFooter() }
  }

  @Builder
  QuickPrompt(label: string, prompt: string) {
    Button(label)
      .type(ButtonType.Normal)
      .height(28)
      .fontSize(UI.fontCaption)
      .fontColor(COLORS.ink)
      .backgroundColor(COLORS.surfaceMuted)
      .borderRadius(RADIUS.capsule)
      .padding({ left: 11, right: 11 })
      .enabled(!this.isLoading && !this.configBusy)
      .onClick(() => {
        if (this.isLoading || this.configBusy) return;
        this.followsLatest = true;
        this.showConversations = false;
        this.showContext = false;
        this.showSettings = false;
        this.promptAction(prompt, false, this.sessionMode === 'readonly');
      })
  }

  @Builder
  WelcomeCard(icon: string, title: string, desc: string, prompt: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Row({ space: 6 }) {
          WorkbenchIcon({ name: icon, iconSize: 14, color: COLORS.primary })
          Text(title).fontSize(12).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).maxLines(1)
        }.width('100%').alignItems(VerticalAlign.Center)
        Text(desc).fontSize(11).fontColor(COLORS.muted).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      }.width('100%').alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .padding({ left: 11, right: 11, top: 10, bottom: 10 })
    .backgroundColor(COLORS.surface)
    .border({ width: 0.8, color: COLORS.border })
    .borderRadius(12)
    .enabled(!this.isLoading && !this.configBusy)
    .onClick(() => {
      if (this.isLoading || this.configBusy) return;
      this.followsLatest = true;
      this.promptAction(prompt, false, this.sessionMode === 'readonly');
    })
  }

  @Builder
  SlashCommandPalette() {
    if (this.visibleSlashCommands().length > 0) {
      Column({ space: 2 }) {
        Row() {
          Text('快捷斜杠指令')
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.muted)
            .layoutWeight(1)
          Button('关闭', { type: ButtonType.Normal })
            .height(20).padding({ left: 6, right: 6 }).fontSize(10).fontColor(COLORS.muted)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.slashMenuForced = false;
              if (this.inputText.trim() === '/') this.inputText = '';
            })
        }.width('100%').padding({ left: 8, right: 4, top: 4, bottom: 2 })

        Scroll() {
          Column({ space: 2 }) {
            ForEach(this.visibleSlashCommands(), (spec: AiSlashCommandSpec) => {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 8 }) {
                  Text(spec.command)
                    .fontSize(11)
                    .fontFamily('monospace')
                    .fontWeight(FontWeight.Bold)
                    .fontColor(COLORS.primary)
                    .width(68)
                  Text(spec.title)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(COLORS.ink)
                  Text(spec.subtitle)
                    .fontSize(10)
                    .fontColor(COLORS.muted)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }.width('100%').alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .height(32)
              .padding({ left: 8, right: 8 })
              .backgroundColor(Color.Transparent)
              .borderRadius(8)
              .onClick(() => { this.executeSlashSpec(spec); })
            }, (spec: AiSlashCommandSpec): string => spec.command)
          }.width('100%')
        }
        .width('100%')
        .constraintSize({ maxHeight: 168 })
        .scrollBar(BarState.Auto)
      }
      .width('100%')
      .padding(6)
      .backgroundColor(COLORS.surface)
      .border({ width: 0.8, color: withAlpha(COLORS.primary, 0.35) })
      .borderRadius(12)
    }
  }

  @Builder
  CompactContextBar() {
    Row({ space: 6 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          Circle({ width: 6, height: 6 })
            .fill(this.contextOptions.includeLayout ? COLORS.primary : COLORS.muted)
          Text(`${this.fileName || '未命名'} · ${this.cellName || this.topCellName || 'TOP'}` +
            (this.selectionCount > 0 ? ` · 已选 ${this.selectionCount}` : ''))
            .fontSize(11)
            .fontColor(COLORS.muted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }.alignItems(VerticalAlign.Center)
      }
      .height(26)
      .padding({ left: 8, right: 8 })
      .backgroundColor(COLORS.surfaceMuted)
      .borderRadius(RADIUS.capsule)
      .layoutWeight(1)
      .enabled(!this.isLoading && !this.configBusy)
      .accessibilityText('上下文管理')
      .onClick(() => this.openManagement('context'))

      Button(`上下文 ${this.tokenMeterState().percent}%`, { type: ButtonType.Normal })
        .height(26)
        .padding({ left: 8, right: 8 })
        .fontSize(11)
        .fontColor(this.tokenMeterState().nearThreshold ? COLORS.warning : COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(RADIUS.capsule)
        .enabled(!this.isLoading && !this.configBusy)
        .onClick(() => this.openManagement('context'))

      if (aiService.getConfig().provider !== AiProvider.DEMO_MODE) {
        Button('连接设置', { type: ButtonType.Normal })
          .height(26)
          .padding({ left: 8, right: 8 })
          .fontSize(11)
          .fontColor(COLORS.primary)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(RADIUS.capsule)
          .enabled(!this.isLoading && !this.configBusy)
          .onClick(this.openAgentConnectionAction)
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .border({ width: { bottom: 0.6 }, color: COLORS.border })
  }

  @Builder
  DesktopPanel() {
    Stack({ alignContent: Alignment.Top }) {
    Column() {
      // Single-row compact DSH Agent Header (Quick Model Popover Pill + Settings Gear + New Chat + Minimize + Close)
      Row({ space: 4 }) {
        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: this.showConversations || this.showContext || this.showSettings ? 'chevronLeft' : 'menu',
            iconSize: 17, color: COLORS.ink })
        }.width(28).height(28).padding(0).backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
          .accessibilityText(this.showConversations || this.showContext || this.showSettings ? '返回聊天' : '会话管理')
          .onClick(() => {
            this.showQuickModelPicker = false;
            if (this.showConversations || this.showContext || this.showSettings) {
              this.showConversations = false; this.showContext = false; this.showSettings = false;
              this.followsLatest = true; this.scrollConversationToLatest();
            } else { this.openManagement('conversations'); }
          })

        Text(this.showConversations ? '会话管理' : (this.showContext ? '上下文管理' : (this.showSettings ? '模型与供应商' : 'AI 助手')))
          .fontSize(14).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).maxLines(1)

        if (!this.showConversations && !this.showContext && !this.showSettings) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 4 }) {
              Circle({ width: 6, height: 6 })
                .fill(aiService.getConfig().provider === AiProvider.DEMO_MODE ? COLORS.muted : COLORS.success)
              Text(this.shortModelPillLabel())
                .fontSize(11)
                .fontColor(COLORS.ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              WorkbenchIcon({ name: this.showQuickModelPicker ? 'chevronUp' : 'chevronDown', iconSize: 10, color: COLORS.muted })
            }.alignItems(VerticalAlign.Center)
          }
          .id('ai-header-model-pill')
          .height(28)
          .padding({ left: 8, right: 7 })
          .backgroundColor(this.showQuickModelPicker ? COLORS.primarySoft : COLORS.surface)
          .border({ width: 0.8, color: this.showQuickModelPicker ? withAlpha(COLORS.primary, 0.4) : COLORS.border })
          .borderRadius(RADIUS.capsule)
          .layoutWeight(1)
          .enabled(!this.isLoading && !this.configBusy)
          .accessibilityText('快捷切换模型')
          .onClick(() => {
            this.quickModelSearch = '';
            this.showQuickModelPicker = !this.showQuickModelPicker;
          })

          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({ name: 'settings', iconSize: 15, color: COLORS.ink })
          }
          .id('ai-open-settings-btn')
          .width(28).height(28).padding(0)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy)
          .accessibilityText('打开模型与供应商设置')
          .onClick(() => { this.openManagement('settings'); })

          Button({ type: ButtonType.Normal }) {
            WorkbenchIcon({ name: 'plus', iconSize: 15, color: COLORS.ink })
          }
          .width(28).height(28).padding(0)
          .backgroundColor(COLORS.surface)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .enabled(!this.isLoading && !this.configBusy)
          .accessibilityText('新建会话')
          .onClick(() => { this.createConversation(); })
        } else {
          Blank()
        }

        Button({ type: ButtonType.Normal }) {
          WorkbenchIcon({ name: 'minimize', iconSize: 16, color: COLORS.ink })
        }
        .id('ai-panel-minimize-btn')
        .width(28).height(28).padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .accessibilityText('收起窗口并保留图纸运行提示')
        .bindTips('收起窗口看全屏图纸')
        .onClick(() => this.minimizeAction())

        Button({ type: ButtonType.Normal }) { WorkbenchIcon({ name: 'close', iconSize: 17, color: COLORS.muted }) }
          .width(28).height(28).padding(0).backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
          .accessibilityText('关闭 AI 助手').onClick(() => this.closeAction())
      }.width('100%').height(46).padding({ left: 8, right: 8 })
        .backgroundColor(withAlpha(COLORS.surfaceMuted, 0.72)).border({ width: { bottom: 0.8 }, color: COLORS.border })

      if ((this.showConversations || this.showContext || this.showSettings) && (this.isLoading || this.configBusy)) {
        Row({ space: 8 }) {
          Text('任务运行中，暂停会话与配置修改').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
          if (this.canCancel) {
            Button('取消生成', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontCaption)
              .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(UI.controlRadius).onClick(this.cancelGenerationAction)
          }
        }.width('100%').padding({ left: 14, right: 14, top: 8, bottom: 8 })
      }
      if (!this.showConversations && !this.showContext && !this.showSettings) {
        this.CompactContextBar()
      }
      this.DesktopConversation()

      // DSH-Harmony Docked Approval Card pinned right above the input dock
      if (!this.showConversations && !this.showContext && !this.showSettings && this.pendingSummary.length > 0) {
        Column() {
          this.PendingChangeCard()
        }.width('100%').padding({ left: 12, right: 12, bottom: 4 })
      }

      // Unified Modern Agent Input Dock (Slash Commands + Array Template + Agent/ReadOnly Mode Pill + Enter-to-Send)
      if (!this.showConversations && !this.showContext && !this.showSettings) {
        Column({ space: 6 }) {
          this.SlashCommandPalette()
          if (this.showTaskTemplate) {
            this.ArrayTaskTemplate()
          }

          if (this.showQuickActions && !this.showTaskTemplate && this.pendingSummary.length === 0 && this.visibleSlashCommands().length === 0) {
            Scroll() {
              Row({ space: 6 }) {
                this.QuickPrompt('解释图形', '解释当前选中的图形及其用途')
                this.QuickPrompt('检查版图', '检查当前版图并说明需要关注的问题')
                this.QuickPrompt('定位问题', '根据当前 DRC 具体问题，选中并定位第一个问题涉及的图形，不修改几何。')
                this.QuickPrompt('提出修复', '根据当前选区与 DRC 证据，提出最小修复方案供我预览确认，并在修改后复检；资料不足时先说明，不猜测工艺规则。')
                this.QuickPrompt('画反相器', '画一个反相器')
              }
            }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
              .clip(true)
          }

          Column({ space: 4 }) {
            TextArea({
              text: this.inputText,
              placeholder: this.sessionMode === 'readonly'
                ? '只读问答模式：提问或分析版图（不生成修改方案）…'
                : (this.pendingSummary.length > 0 ? '继续补充修改要求，或输入 / 唤出快捷指令…' : '描述版图需求（Enter 发送，Shift+Enter 换行，/ 快捷指令）…')
            })
              .id('ai-composer-textarea')
              .enterKeyType(this.desktopMode ? EnterKeyType.Send : EnterKeyType.NEW_LINE)
              .onKeyEvent((event: KeyEvent) => {
                event.stopPropagation();
                const keyName: string = canvasKeyName(event.keyCode, event.keyText);
                const modShift: boolean = event.getModifierKeyState?.(['Shift']) === true;
                if (keyName === 'SHIFT' || event.keyCode === 2047 || event.keyCode === 2048) {
                  this.composerShiftHeld = event.type === KeyType.Down;
                  return;
                }
                this.composerShiftHeld = modShift;
                if (this.desktopMode && event.type === KeyType.Down && keyName === 'ENTER' && !modShift) {
                  this.sendInput();
                }
              })
              .onWillInsert((info: InsertValue): boolean => {
                if (this.desktopMode && !this.composerShiftHeld &&
                  (info.insertValue === '\n' || info.insertValue === '\r' || info.insertValue === '\r\n')) {
                  setTimeout(() => {
                    if (!this.panelDisposed) {
                      this.sendInput();
                    }
                  }, 0);
                  return false;
                }
                return true;
              })
              .onSubmit((_enterKey: EnterKeyType, event?: SubmitEvent) => {
                if (this.desktopMode && !this.composerShiftHeld) {
                  event?.keepEditableState?.();
                  this.sendInput();
                }
              })
              .width('100%').height(60)
              .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted)
              .backgroundColor(Color.Transparent).padding({ left: 12, right: 12, top: 9, bottom: 4 })
              .onChange((value: string) => {
                this.inputText = value;
                if (!value.trimStart().startsWith('/')) {
                  this.slashMenuForced = false;
                }
              })

            Row({ space: 4 }) {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 4 }) {
                  Circle({ width: 6, height: 6 })
                    .fill(this.sessionMode === 'readonly' ? COLORS.warning : COLORS.primary)
                  Text(this.sessionMode === 'readonly' ? '只读' : 'Agent')
                    .fontSize(11)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.sessionMode === 'readonly' ? COLORS.warning : COLORS.primary)
                }.alignItems(VerticalAlign.Center)
              }
              .id('ai-mode-toggle-btn')
              .height(26)
              .padding({ left: 8, right: 8 })
              .backgroundColor(this.sessionMode === 'readonly' ? withAlpha(COLORS.warning, 0.14) : COLORS.primarySoft)
              .borderRadius(RADIUS.capsule)
              .enabled(!this.isLoading && !this.configBusy)
              .accessibilityText('切换 Agent 编辑模式与只读问答模式')
              .onClick(() => this.toggleSessionModeAction())

              Button({ type: ButtonType.Normal }) {
                Row({ space: 3 }) {
                  WorkbenchIcon({ name: 'think', iconSize: 12, color: (aiService.getConfig().reasoningEffort ?? 'auto') === 'none' ? COLORS.muted : COLORS.primary })
                  Text(`思考·${reasoningEffortLabel(aiService.getConfig().reasoningEffort)}`)
                    .fontSize(11)
                    .fontColor((aiService.getConfig().reasoningEffort ?? 'auto') === 'none' ? COLORS.muted : COLORS.ink)
                }.alignItems(VerticalAlign.Center)
              }
              .id('ai-thinking-effort-pill')
              .height(26)
              .padding({ left: 7, right: 7 })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(RADIUS.capsule)
              .enabled(!this.isLoading && !this.configBusy)
              .accessibilityText('切换模型与思考强度')
              .onClick(() => {
                this.quickModelSearch = '';
                this.showQuickModelPicker = !this.showQuickModelPicker;
              })

              Button({ type: ButtonType.Normal }) {
                WorkbenchIcon({ name: 'slash', iconSize: 13, color: this.visibleSlashCommands().length > 0 ? COLORS.primary : COLORS.muted })
              }
              .id('ai-slash-menu-btn')
              .width(26).height(26).padding(0)
              .backgroundColor(this.visibleSlashCommands().length > 0 ? COLORS.primarySoft : COLORS.surfaceMuted)
              .borderRadius(RADIUS.capsule)
              .enabled(!this.isLoading && !this.configBusy)
              .accessibilityText('斜杠快捷指令')
              .onClick(() => { this.slashMenuForced = !this.slashMenuForced; })

              Button('阵列', { type: ButtonType.Normal })
                .id('ai-array-toggle-btn')
                .height(26).padding({ left: 7, right: 7 }).fontSize(11)
                .fontColor(this.showTaskTemplate ? COLORS.primary : COLORS.muted)
                .backgroundColor(this.showTaskTemplate ? COLORS.primarySoft : COLORS.surfaceMuted)
                .borderRadius(RADIUS.capsule)
                .enabled(!this.isLoading && !this.configBusy)
                .onClick(() => { this.showTaskTemplate = !this.showTaskTemplate; })

              if (!this.isCompact) {
                Button('Python', { type: ButtonType.Normal })
                  .height(26).padding({ left: 7, right: 7 }).fontSize(11)
                  .fontColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted).borderRadius(RADIUS.capsule)
                  .enabled(!this.isLoading && !this.configBusy)
                  .onClick(this.openPythonAction)
              }

              Blank()

              // DSH Inline Context Usage Ring (live updates with draft text; click opens Context Workbench)
              Button({ type: ButtonType.Normal }) {
                Row({ space: 4 }) {
                  Progress({ value: this.tokenMeterState().percent, total: 100, type: ProgressType.Ring })
                    .width(13)
                    .height(13)
                    .color(this.tokenMeterState().nearThreshold ? COLORS.warning : COLORS.primary)
                    .backgroundColor(COLORS.border)
                    .style({ strokeWidth: 2 })
                  Text(`${this.tokenMeterState().percent}%`)
                    .fontSize(10)
                    .fontFamily('monospace')
                    .fontColor(this.tokenMeterState().nearThreshold ? COLORS.warning : COLORS.muted)
                }.alignItems(VerticalAlign.Center)
              }
              .id('ai-composer-context-ring')
              .height(26)
              .padding({ left: 6, right: 6 })
              .backgroundColor(Color.Transparent)
              .borderRadius(RADIUS.capsule)
              .enabled(!this.isLoading && !this.configBusy)
              .accessibilityText('查看并调整上下文窗口容量')
              .onClick(() => { this.openManagement('context'); })

              if (this.isLoading && this.canCancel) {
                Button('停止', { type: ButtonType.Normal })
                  .height(36).padding({ left: 12, right: 12 }).fontSize(12)
                  .fontColor(Color.White).backgroundColor(COLORS.danger).borderRadius(RADIUS.capsule)
                  .accessibilityText('取消生成')
                  .onClick(this.cancelGenerationAction)
              } else {
                Button({ type: ButtonType.Normal }) {
                  this.SendArrowGlyph()
                }
                  .id('ai-send-btn')
                  .width(36).height(36).padding(0)
                  .focusable(false)
                  .focusOnTouch(false)
                  .responseRegion({ x: -6, y: -6, width: 48, height: 48 })
                  .backgroundColor(this.inputText.trim().length > 0 ? COLORS.primary : COLORS.surfaceMuted)
                  .borderRadius(RADIUS.capsule)
                  .enabled(this.inputText.trim().length > 0 && !this.isLoading && !this.configBusy)
                  .accessibilityText('发送消息')
                  .onClick(() => this.sendInput())
              }
            }.width('100%').padding({ left: 8, right: 8, bottom: 8 }).alignItems(VerticalAlign.Center)
          }
          .width('100%')
          .backgroundColor(COLORS.surface)
          .border({
            width: 1,
            color: this.sessionMode === 'readonly'
              ? withAlpha(COLORS.warning, 0.42)
              : (this.pendingSummary.length > 0 ? withAlpha(COLORS.primary, 0.35) : COLORS.border)
          })
          .borderRadius(16)
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 8, bottom: 12 })
          .border({ width: { top: 0.8 }, color: COLORS.border })
      }
    }
    .width('100%')
    .height('100%')

    if (this.showQuickModelPicker && !this.showConversations && !this.showContext && !this.showSettings) {
      Stack({ alignContent: Alignment.Top }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#00000000')
          .onClick(() => { this.showQuickModelPicker = false; })
        Column() {
          this.QuickModelPickerPopover()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 48 })
      }
      .width('100%')
      .height('100%')
      .zIndex(30)
    }
    }.width(this.desktopMode ? this.panelWidth : Math.min(this.panelWidth, this.isCompact ? 324 : 380))
      .height(this.desktopMode ? this.panelHeight : Math.min(this.panelHeight, 640))
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).clip(true)
  }

  build() {
    this.DesktopPanel()
  }
}

@Component
export struct MacroPanel {
  @Prop @Watch('refreshMacros') macros: Macro[] = [];
  @State managedMacros: Macro[] = [];
  private manager: CustomDialogController = new CustomDialogController({
    builder: MacroManagerDialog({ onChanged: () => this.refreshMacros() }), autoCancel: false, customStyle: true
  });
  aboutToAppear(): void { this.refreshMacros(); }
  refreshMacros(): void { this.managedMacros = macroService.getAllMacros().slice(); }
  @Prop lastStatus: string = '';
  /** 紧凑模式（sm 手机端）：收窄宽度并重定位到左上角，避免溢出窄屏） */
  @Prop isCompact: boolean = false;
  @Prop availableWidth: number = 0;
  @Prop availableHeight: number = 0;
  /** 是否正在录制（由父组件传入，控制录制/停止按钮态） */
  @Prop isRecording: boolean = false;
  closeAction: () => void = () => {};
  runMacroAction: (macroId: number) => void = () => {};
  /** 开始录制：参数为宏名称 */
  startRecordingAction: (name: string) => void = () => {};
  /** 停止录制并保存 */
  stopRecordingAction: () => void = () => {};
  /** 取消录制 */
  cancelRecordingAction: () => void = () => {};
  @State recordingName: string = '';

  private panelWidth(): number {
    return Math.max(0, Math.min(this.isCompact ? 296 : 420, this.availableWidth - 16));
  }

  private panelHeight(): number {
    return Math.max(0, Math.min(560, this.availableHeight - 16));
  }

  private panelOffsetX(): number {
    return Math.max(0, Math.min(this.isCompact ? 12 : 520,
      (this.availableWidth - this.panelWidth()) / 2 - 8));
  }

  private panelOffsetY(): number {
    return Math.max(0, Math.min(this.isCompact ? 60 : 84,
      (this.availableHeight - this.panelHeight()) / 2 - 8));
  }

  build() {
    Column() {
      PanelHeading({ title: '宏 / 批处理', closeAction: this.closeAction }).padding({ top: 16, bottom: 12 })
        .border({ width: { bottom: 1 }, color: COLORS.border })
      Column({ space: 8 }) {
        Text('录制自定义宏').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        if (!this.isRecording) {
          Text('宏名称').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        }
        if (!this.isRecording) {
          Row({ space: 8 }) {
            TextInput({ text: this.recordingName, placeholder: '宏名称（如：批量移动）' })
              .type(InputType.Normal)
              .height(UI.fieldHeight)
              .fontSize(UI.fontBody)
              .fontColor(COLORS.ink)
              .placeholderColor(COLORS.muted)
              .padding({ left: 8, right: 8 })
              .layoutWeight(1)
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(UI.controlRadius)
              .onKeyEvent((e: KeyEvent) => {
                e.stopPropagation();
              })
              .onChange((val: string) => {
                this.recordingName = val;
              })
            Button('录制', { type: ButtonType.Normal })
              .fontSize(UI.fontBody)
              .fontColor(Color.White)
              .height(UI.controlHeight)
              .padding({ left: 16, right: 16 })
              .backgroundColor(COLORS.primary)
              .borderRadius(UI.controlRadius)
              .enabled(this.recordingName.trim().length > 0)
              .onClick(() => {
                if (this.recordingName.trim().length === 0) {
                  return;
                }
                this.startRecordingAction(this.recordingName.trim());
              })
          }
          .width('100%')
          .padding({ bottom: 4 })
        } else {
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              DrawnStatusIcon({ kind: 'dirty', iconSize: 12, strokeColor: COLORS.danger, showSoftPlate: true })
              Text('录制中…')
                .fontSize(12)
                .fontColor(COLORS.danger)
            }
            .alignItems(VerticalAlign.Center)
            .layoutWeight(1)
            .padding({ left: 4, right: 8 })
            Button('停止', { type: ButtonType.Normal })
              .fontSize(UI.fontBody)
              .fontColor(Color.White)
              .height(UI.controlHeight)
              .padding({ left: 16, right: 16 })
              .backgroundColor(COLORS.primary)
              .borderRadius(UI.controlRadius)
              .onClick(() => {
                this.stopRecordingAction();
              })
            Button('取消', { type: ButtonType.Normal })
              .fontSize(UI.fontBody)
              .fontColor(COLORS.ink)
              .height(UI.controlHeight)
              .padding({ left: 16, right: 16 })
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(UI.controlRadius)
              .onClick(() => {
                this.cancelRecordingAction();
              })
          }
          .width('100%')
          .padding({ bottom: 4 })
        }
      }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      Row({ space: 8 }) {
        Text('管理 · 编辑').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
        Button('宏管理').height(UI.compactControlHeight).fontSize(UI.fontBody).enabled(!this.isRecording)
          .type(ButtonType.Normal).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).onClick(() => this.manager.open())
      }.width('100%').padding({ top: 12, bottom: 12 })
      Row() {
        Text('宏列表').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
        Text(`共 ${this.managedMacros.length} 个宏`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
      }.width('100%').padding({ top: 4, bottom: 8 })
      List() {
        ForEach(this.managedMacros, (macro: Macro) => {
          ListItem() {
            MacroRow({ macro: macro, isRecording: this.isRecording, runMacroAction: this.runMacroAction })
          }
        }, (macro: Macro) => macro.id.toString())
      }.width('100%').layoutWeight(1).clip(true)
      if (this.lastStatus.length > 0) {
        Row({ space: 8 }) {
          WorkbenchIcon({ name: 'info', iconSize: 16, color: COLORS.muted })
          Text(this.lastStatus).fontSize(UI.fontCaption).fontColor(COLORS.ink).lineHeight(18).maxLines(3).layoutWeight(1)
        }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius).margin({ top: 8 })
      }
    }.width(this.panelWidth()).height(this.panelHeight()).padding({ left: 16, right: 16, bottom: 16 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).clip(true)
      .position({ x: this.panelOffsetX(), y: this.panelOffsetY() })
  }
}

@Component
struct MacroRow {
  @Prop macro: Macro = {
    id: -1,
    name: '',
    description: '',
    steps: [],
    createdAt: 0,
    updatedAt: 0,
    builtin: false
  };
  @Prop isRecording: boolean = false;
  runMacroAction: (macroId: number) => void = () => {};

  build() {
    Row({ space: 12 }) {
      WorkbenchIcon({ name: 'macro', iconSize: 22, color: COLORS.muted })
      Column() {
        Row() {
          Text(this.macro.name)
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
            .maxLines(1)
          Text(`${this.macro.steps.length} 步`)
            .fontSize(10)
            .fontColor(COLORS.muted)
        }
        .width('100%')

        Text(this.macro.description)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .maxLines(2)
          .lineHeight(16)
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button('运行')
        .type(ButtonType.Normal)
        .enabled(!this.isRecording)
        .height(UI.compactControlHeight)
        .fontSize(UI.fontBody)
        .borderRadius(UI.controlRadius)
        .backgroundColor(Color.Transparent)
        .fontColor(COLORS.primary)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .margin({ left: 10 })
        .onClick(() => {
          this.runMacroAction(this.macro.id);
        })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .border({ width: { bottom: 1 }, color: COLORS.border })
  }
}

@Component
export struct FileOpenPanel {
  @Prop files: RecentFile[] = [];
  /** 紧凑模式（sm 手机端）：收窄宽度并重定位到左上角，避免溢出窄屏） */
  @Prop isCompact: boolean = false;
  closeAction: () => void = () => {};
  chooseFileAction: (file: RecentFile) => void = () => {};

  build() {
    Column() {
      OverlayHeader({ title: '打开版图文件', closeAction: this.closeAction })
      Text('最近打开').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.muted).width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
      Scroll() {
        Column() {
          if (this.files.length === 0) {
            Text('暂无最近文件').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%').height(120).textAlign(TextAlign.Center)
          } else {
            ForEach(this.files, (file: RecentFile) => {
              FileChoiceRow({ file: file, chooseFileAction: this.chooseFileAction })
            }, (file: RecentFile) => file.key())
          }
        }.width('100%').padding({ left: 16, right: 16, bottom: 16 })
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto).clip(true)
    }.width(this.isCompact ? 296 : 420).height(320)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).clip(true)
      .position({ x: this.isCompact ? 12 : 260, y: this.isCompact ? 60 : 92 })
  }
}

@Component
export struct ShortcutPanel {
  /** 紧凑模式（sm 手机端）：重定位到左上角，避免溢出窄屏） */
  @Prop isCompact: boolean = false;
  closeAction: () => void = () => {};

  /** 数据驱动的快捷键列表（来自 shortcutService.getShortcutList） */
  @State shortcutList: ShortcutEntry[] = [];
  /** actionKey → 冲突动作中文标签（空字符串表示无冲突） */
  @State conflictMap: Record<string, string> = {};
  /** 顶部状态提示（导入成功/失败、重置完成等） */
  @State statusText: string = '';
  @State statusFailed: boolean = false;

  @State exportedProfileJson: string = '';

  private exportProfileController: CustomDialogController = new CustomDialogController({
    builder: ProfileExportDialog({
      profileJson: this.exportedProfileJson,
      onCopied: () => {
        this.statusText = 'Profile JSON 已复制到剪贴板';
        this.statusFailed = false;
        showAppSnackBar(this.getUIContext(), 'Profile JSON 已复制到剪贴板', { icon: $r('sys.symbol.checkmark_circle') });
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  // Task 2.6: Profile 导入弹窗（@CustomDialog，系统模态遮罩自动屏蔽底层触摸）
  private importProfileController: CustomDialogController = new CustomDialogController({
    builder: ProfileImportDialog({
      onSuccess: () => {
        this.clearAllConflicts();
        this.refreshList();
        this.statusText = '已导入并应用新 Profile';
        this.statusFailed = false;
        showAppSnackBar(this.getUIContext(), 'Profile 导入成功', { icon: $r('sys.symbol.checkmark_circle') });
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  aboutToAppear(): void {
    shortcutService.ensureInitialized();
    this.refreshList();
  }

  /** 重新从 service 拉取最新列表（重新赋值以触发 @State 刷新） */
  private refreshList(): void {
    this.shortcutList = shortcutService.getShortcutList();
  }

  /** 清空所有冲突标记（用于导入/重置后） */
  private clearAllConflicts(): void {
    const cleared: Record<string, string> = {};
    const keys = Object.keys(this.conflictMap);
    for (let i = 0; i < keys.length; i++) {
      cleared[keys[i]] = '';
    }
    this.conflictMap = cleared;
  }

  /**
   * 处理某行的码修改请求。
   * @returns true 表示已接受；false 表示拒绝（冲突/非法），调用方应回滚输入框
   */
  private handleCodeChange(actionKey: string, newCode: string): boolean {
    if (newCode.length === 0) {
      this.updateConflict(actionKey, '码不能为空');
      return false;
    }
    const result = shortcutService.setShortcut(actionKey, newCode);
    if (result.ok) {
      this.updateConflict(actionKey, '');
      this.refreshList();
      this.statusText = '';
      this.statusFailed = false;
      return true;
    }
    const conflictActionKey = result.conflict ?? '';
    const label = result.error ?? (conflictActionKey.length > 0
      ? `冲突：已被「${shortcutService.getActionLabel(conflictActionKey)}」占用`
      : '无效码（仅允许字母）');
    this.updateConflict(actionKey, label);
    return false;
  }

  /** 更新某行的冲突文本（重新赋值整个 Record 以触发刷新） */
  private updateConflict(actionKey: string, conflictLabel: string): void {
    const newMap: Record<string, string> = {};
    const keys = Object.keys(this.conflictMap);
    for (let i = 0; i < keys.length; i++) {
      newMap[keys[i]] = this.conflictMap[keys[i]];
    }
    newMap[actionKey] = conflictLabel;
    this.conflictMap = newMap;
  }

  /** 导出当前 profile，弹出自定义光感对话框展示可复制 JSON 并提供一键复制 */
  private handleExport(): void {
    this.exportedProfileJson = shortcutService.exportProfile();
    this.exportProfileController.open();
  }

  /** 打开导入对话框 */
  private handleImport(): void {
    this.importProfileController.open();
  }

  /** 恢复默认映射 */
  private handleReset(): void {
    const result = shortcutService.resetToDefault();
    if (!result.ok) { this.statusText = result.error ?? '快捷键未恢复'; this.statusFailed = true; return; }
    this.clearAllConflicts();
    this.refreshList();
    this.statusText = '已恢复默认快捷键';
    this.statusFailed = false;
  }

  build() {
    Column() {
      OverlayHeader({ title: '快捷键', closeAction: this.closeAction })

      Text('Space + 助记码执行命令 · 单键 B / P / L / S / M / F 切换工具')
        .fontSize(UI.fontCaption).fontColor(COLORS.muted).lineHeight(16)
        .padding({ left: 16, right: 16, top: 10, bottom: 10 })

      // 操作按钮行
      Row() {
        Button('导出 Profile')
          .type(ButtonType.Normal)
          .height(UI.compactControlHeight)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleExport();
          })
        Blank().width(8)
        Button('导入 Profile')
          .type(ButtonType.Normal)
          .height(UI.compactControlHeight)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleImport();
          })
        Blank().width(8)
        Button('恢复默认')
          .type(ButtonType.Normal)
          .height(UI.compactControlHeight)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleReset();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .fontSize(10)
          .fontColor(this.statusFailed ? COLORS.danger : COLORS.success)
          .width('100%')
          .padding({ left: 14, bottom: 6 })
      }

      Row() {
        Text('操作').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
        Text('助记码').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(72).textAlign(TextAlign.Center)
      }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor(COLORS.surfaceMuted)

      // 数据驱动的快捷键列表（可滚动）
      Scroll() {
        Column() {
          ForEach(this.shortcutList, (entry: ShortcutEntry) => {
            ShortcutRow({
              actionKey: entry.actionKey,
              label: entry.description,
              code: entry.keys,
              conflictText: this.conflictMap[entry.actionKey] ?? '',
              codeChangeAction: (ak: string, nc: string): boolean => {
                return this.handleCodeChange(ak, nc);
              }
            })
          }, (entry: ShortcutEntry) => entry.actionKey)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .clip(true)
    }
    .width(this.isCompact ? 296 : 420)
    .height(560)
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
    .clip(true)
    .position({ x: this.isCompact ? 12 : 208, y: this.isCompact ? 60 : 92 })
  }
}

const LAYER_COLOR_SWATCHES: string[] = [
  '#2984FF', '#00C853', '#FF5252', '#FFB300', '#AA00FF', '#00BCD4',
  '#FF6D00', '#F50057', '#64DD17', '#304FFE', '#FFD600', '#26A69A'
];

const LINE_STYLE_KEYS: string[] = ['solid', 'dashed', 'dotted', 'dotdash'];
const FILL_STYLE_KEYS: string[] = ['solid', 'outline', 'cross', 'diagonal', 'hollow'];

@CustomDialog
struct ProfileExportDialog {
  controller: CustomDialogController;
  @Prop profileJson: string = '';
  onCopied: () => void = () => {};

  private copyJson(): void {
    pasteboard.getSystemPasteboard().setData(
      pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.profileJson)
    ).then(() => {
      this.onCopied();
      this.controller.close();
    }).catch(() => {});
  }

  build() {
    Column({ space: 14 }) {
      Text('导出快捷键 Profile')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')

      Scroll() {
        Text(this.profileJson)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor(COLORS.ink)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
      }
      .width('100%')
      .height(210)
      .padding(12)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .clip(true)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .borderRadius(UI.controlRadius)

      Row({ space: 10 }) {
        Blank()
        Button('关闭', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 20, right: 20 })
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .fontSize(UI.fontBody)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.controller.close())
        Button('复制 JSON', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 20, right: 20 })
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.copyJson())
      }
      .width('100%')
      .padding({ top: 12 })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(440)
    .constraintSize({ maxWidth: '94%' })
    .padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
  }
}

@Component
export struct LayerStylePanel {
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop actualLayer: UiLayer | undefined = undefined;
  changeStyleAction: (layer: UiLayer) => void = () => {};
  /** 紧凑模式（sm 手机端）：收窄宽度并重定位到左上角，避免溢出窄屏） */
  @Prop isCompact: boolean = false;
  @Prop availableHeight: number = 0;
  @Prop availableWidth: number = 0;
  closeAction: () => void = () => {};
  hideLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  setCurrentLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  @State private showColorPicker: boolean = false;
  @State private favoriteColorsArgb: string[] = [
    '#FF2984FF', '#FF00C853', '#FFFF5252', '#FFFFB300', '#FFAA00FF', '#FF00BCD4'
  ];

  private panelHeight(): number {
    const baseDesired: number = this.actualLayer !== undefined ? (this.showColorPicker ? 680 : 576) : 230;
    return Math.max(0, Math.min(baseDesired, this.availableHeight - 16));
  }

  private panelOffsetY(): number {
    const desiredOffset: number = this.isCompact ? 56 : 84;
    return Math.max(0, Math.min(desiredOffset, (this.availableHeight - this.panelHeight()) / 2 - 8));
  }

  private panelOffsetX(): number {
    const panelWidth: number = this.isCompact ? 296 : 420;
    const desiredOffset: number = this.isCompact ? 12 : 510;
    return Math.max(0, Math.min(desiredOffset, (this.availableWidth - panelWidth) / 2 - 8));
  }

  private toArgbHex(rgb: string): string {
    const raw: string = rgb.trim().replace(/^#/, '');
    if (/^[0-9a-fA-F]{6}$/.test(raw)) {
      return `#FF${raw.toUpperCase()}`;
    }
    if (/^[0-9a-fA-F]{8}$/.test(raw)) {
      return `#${raw.toUpperCase()}`;
    }
    return '#FF2984FF';
  }

  private normalizeRgbHex(selectedColor: string): string {
    const raw: string = selectedColor.trim().replace(/^#/, '');
    if (/^[0-9a-fA-F]{8}$/.test(raw)) {
      return `#${raw.substring(2).toUpperCase()}`;
    }
    if (/^[0-9a-fA-F]{6}$/.test(raw)) {
      return `#${raw.toUpperCase()}`;
    }
    return '#2984FF';
  }

  private changeStyle(field: string, value: string | number): void {
    if (this.actualLayer === undefined) return;
    const next: UiLayer = cloneUiLayerModel(this.actualLayer) as UiLayer;
    if (field === 'lineStyle' && typeof value === 'string') next.lineStyle = value;
    else if (field === 'fillStyle' && typeof value === 'string') next.fillStyle = value;
    else if (field === 'color' && typeof value === 'string') { next.color = value; next.fillColor = undefined; }
    else if (field === 'transparency' && value === 'default') next.transparency = undefined;
    else if (field === 'transparency' && typeof value === 'number') next.transparency = Math.round(value);
    else return;
    this.changeStyleAction(next);
  }

  private transparencyValue(): number {
    if (this.actualLayer !== undefined && this.actualLayer.transparency !== undefined) {
      return this.actualLayer.transparency;
    }
    return Math.round((1 - layerRenderStyle(undefined).fillOpacity) * 100);
  }

  build() {
    Column() {
      OverlayHeader({ title: '图层样式', closeAction: this.closeAction })
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Text(`L${this.selectedLayerNumber} / D${this.selectedDatatype}`).fontSize(UI.fontBody).fontColor(COLORS.primary)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 }).backgroundColor(COLORS.primarySoft).borderRadius(6)
            if (this.actualLayer !== undefined) {
              Column({ space: 4 }) {
                Text(`${this.actualLayer!.chineseName} · ${this.actualLayer!.englishName}`)
                  .fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).maxLines(2)
                Text(`文件层名 ${this.actualLayer!.sourceName ?? '未声明'}`)
                  .fontSize(UI.fontCaption).fontColor(COLORS.muted)
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }
          }.width('100%').padding({ bottom: 16 }).border({ width: { bottom: 1 }, color: COLORS.border })
          if (this.actualLayer !== undefined) {
            Column({ space: 8 }) {
              Row({ space: 8 }) {
                Text('图层颜色').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
                Row().width(18).height(18).borderRadius(5).backgroundColor(this.actualLayer!.color)
                  .border({ width: 1, color: COLORS.border })
                Text(this.actualLayer!.color.toUpperCase()).fontSize(UI.fontCaption).fontFamily('monospace').fontColor(COLORS.muted)
                Blank()
                if (deviceInfo.sdkApiVersion >= 26) {
                  Button(this.showColorPicker ? '收起调色盘' : '官方取色器', { type: ButtonType.Normal })
                    .height(UI.compactControlHeight).fontSize(UI.fontCaption).padding({ left: 10, right: 10 })
                    .backgroundColor(this.showColorPicker ? COLORS.primarySoft : COLORS.surfaceMuted)
                    .fontColor(this.showColorPicker ? COLORS.primary : COLORS.ink)
                    .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                    .onClick(() => { this.showColorPicker = !this.showColorPicker; })
                }
              }.width('100%').alignItems(VerticalAlign.Center)

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(LAYER_COLOR_SWATCHES, (swatch: string) => {
                  Button({ type: ButtonType.Normal }) {
                    Row()
                  }
                  .width(26).height(26).padding(0).margin({ right: 6, bottom: 6 }).borderRadius(7)
                  .backgroundColor(swatch)
                  .border({
                    width: this.actualLayer!.color.toUpperCase() === swatch ? 2 : 1,
                    color: this.actualLayer!.color.toUpperCase() === swatch ? COLORS.ink : COLORS.border
                  })
                  .accessibilityText(`图层颜色 ${swatch}`)
                  .onClick(() => this.changeStyle('color', swatch))
                }, (swatch: string) => swatch)
              }.width('100%')

              if (this.showColorPicker && deviceInfo.sdkApiVersion >= 26) {
                // 严守官方规范：HdsColorPicker 不支持通用属性/事件且 isColorPickerShow 需 26.0.1，用外层 Column 与条件渲染收口
                Column() {
                  HdsColorPicker({
                    initialColor: this.toArgbHex(this.actualLayer!.color),
                    initialFavoriteColors: this.favoriteColorsArgb,
                    options: {
                      tabs: [HdsColorPickerTabType.GRID, HdsColorPickerTabType.SPECTRUM, HdsColorPickerTabType.SLIDERS]
                    },
                    onColorSelected: (selectedColor: string) => {
                      this.changeStyle('color', this.normalizeRgbHex(selectedColor));
                    },
                    onFavoriteColorsUpdate: (favoriteColors: Array<string>) => {
                      this.favoriteColorsArgb = favoriteColors.slice();
                    }
                  })
                }.width('100%').padding({ top: 4, bottom: 4 })
              }
            }.width('100%').alignItems(HorizontalAlign.Start)

            Column({ space: 8 }) {
              Text('线型').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
              StableSegmentButton({
                items: [
                  { text: '实线' },
                  { text: '虚线' },
                  { text: '点线' },
                  { text: '点划线' }
                ] as [
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem
                ] as SegmentButtonItemTuple,
                selectedIndex: Math.max(0, LINE_STYLE_KEYS.indexOf(this.actualLayer!.lineStyle ?? 'solid')),
                onItemClicked: (idx: number) => {
                  if (idx >= 0 && idx < LINE_STYLE_KEYS.length) {
                    this.changeStyle('lineStyle', LINE_STYLE_KEYS[idx]);
                  }
                },
                fontColor: COLORS.muted,
                selectedFontColor: COLORS.primary,
                capsuleBackgroundColor: COLORS.surfaceMuted,
                selectedBackgroundColor: COLORS.primarySoft,
                fontSizeFp: UI.fontCaption,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 34,
                itemMinHeight: 28,
                itemPaddingHorizontal: 6
              })
            }.width('100%').alignItems(HorizontalAlign.Start)

            Column({ space: 8 }) {
              Text('填充').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
              StableSegmentButton({
                items: [
                  { text: '实心' },
                  { text: '轮廓' },
                  { text: '交叉' },
                  { text: '斜线' },
                  { text: '空心' }
                ] as [
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem
                ] as SegmentButtonItemTuple,
                selectedIndex: Math.max(0, FILL_STYLE_KEYS.indexOf(this.actualLayer!.fillStyle ?? 'solid')),
                onItemClicked: (idx: number) => {
                  if (idx >= 0 && idx < FILL_STYLE_KEYS.length) {
                    this.changeStyle('fillStyle', FILL_STYLE_KEYS[idx]);
                  }
                },
                fontColor: COLORS.muted,
                selectedFontColor: COLORS.primary,
                capsuleBackgroundColor: COLORS.surfaceMuted,
                selectedBackgroundColor: COLORS.primarySoft,
                fontSizeFp: UI.fontCaption,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 34,
                itemMinHeight: 28,
                itemPaddingHorizontal: 5
              })
            }.width('100%').alignItems(HorizontalAlign.Start)
          } else {
            Text('当前图层样式尚未加载').fontSize(UI.fontBody).fontColor(COLORS.muted)
          }
        }.width('100%').padding(UI.panelPadding).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).clip(true)
      if (this.actualLayer !== undefined) {
        Column({ space: 8 }) {
          Row() {
            Text('填充透明度').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
            if (this.actualLayer!.transparency !== undefined) {
              Button('恢复默认', { type: ButtonType.Normal })
                .fontSize(UI.fontCaption).height(UI.compactControlHeight).padding({ left: 12, right: 12 })
                .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).borderRadius(UI.controlRadius)
                .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .onClick(() => this.changeStyle('transparency', 'default'))
            }
          }.width('100%')
          Row({ space: 12 }) {
            Slider({ value: this.transparencyValue(), min: 0, max: 100, step: 1 })
              .layoutWeight(1).onChange((value: number) => this.changeStyle('transparency', value))
            Text(`${this.actualLayer!.transparency === undefined ? '默认 ' : ''}${this.transparencyValue()}%`)
              .fontSize(UI.fontBody).fontColor(COLORS.muted).width(76).textAlign(TextAlign.End)
          }.width('100%')
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ left: UI.panelPadding, right: UI.panelPadding, bottom: UI.panelPadding })
      }
      Row({ space: 8 }) {
        Blank()
        Button('隐藏图层', { type: ButtonType.Normal }).width(112).height(UI.controlHeight).fontSize(UI.fontBody)
          .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.hideLayerAction(this.selectedLayerNumber, this.selectedDatatype))
        Button('设为当前', { type: ButtonType.Normal }).width(112).height(UI.controlHeight).fontSize(UI.fontBody)
          .fontColor(Color.White).backgroundColor(COLORS.primary).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.setCurrentLayerAction(this.selectedLayerNumber, this.selectedDatatype))
      }.width('100%').padding(UI.panelPadding).border({ width: { top: 1 }, color: COLORS.border })
    }.width(this.isCompact ? 296 : 420).height(this.panelHeight())
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).clip(true)
      .position({ x: this.panelOffsetX(), y: this.panelOffsetY() })
  }
}

@Component
struct OverlayHeader {
  @Prop title: string = '';
  closeAction: () => void = () => {};

  build() {
    Column() {
      PanelHeading({ title: this.title, closeAction: this.closeAction })
    }.width('100%').padding({ left: UI.panelPadding, right: UI.panelPadding, top: 16, bottom: 12 })
      .border({ width: { bottom: 1 }, color: COLORS.border })
  }
}

@Component
struct PromptRow {
  @Prop text: string = '';
  promptAction: (prompt: string) => void = () => {};

  build() {
    Row() {
      Button(this.text, { type: ButtonType.Normal })
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
        .height(UI.fieldHeight)
        .padding({ left: 12, right: 12 })
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)
        .onClick(() => {
          this.promptAction(this.text);
        })
    }
    .width('100%')
    .padding({ left: UI.panelPadding, right: UI.panelPadding, bottom: 8 })
  }
}

@Component
struct FileChoiceRow {
  @Prop file: RecentFile = new RecentFile('', '', '');
  chooseFileAction: (file: RecentFile) => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row() {
        Text(this.file.fileType)
          .fontSize(11)
          .fontColor(COLORS.primary)
          .width(54)
          .height(24)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLORS.primarySoft)
          .borderRadius(RADIUS.xs)
        Column() {
          Text(this.file.name)
            .fontSize(UI.fontBody)
            .fontColor(COLORS.ink)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.file.fileSizeLabel)
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.muted)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 12, right: 8 })
        Text('加载')
          .fontSize(UI.fontBody)
          .fontColor(COLORS.primary)
      }
      .width('100%')
      .padding(0)
    }
    .height(64)
    .width('100%')
    .padding(0)
    .backgroundColor(COLORS.surface)
    .accessibilityText(`加载${this.file.name}`)
    .border({ width: { bottom: 1 }, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .onClick(() => {
      this.chooseFileAction(this.file);
    })
  }
}

@Component
struct ShortcutRow {
  /** 稳定动作键（用于回写 service） */
  @Prop actionKey: string = '';
  /** 动作中文标签 */
  @Prop label: string = '';
  /** 当前码（来自 service.getShortcutList） */
  // OVERLAY-1: 加 @Watch 监听 code 变化，恢复默认/导入 Profile 后同步 editingCode
  @Prop @Watch('onCodeChange') code: string = '';
  /** 冲突动作中文标签，空串表示无冲突 */
  @Prop conflictText: string = '';
  /** 码修改回调，返回 true=已接受 / false=拒绝（调用方应回滚输入框） */
  codeChangeAction: (actionKey: string, newCode: string) => boolean = () => false;

  /** 当前编辑中的码（本地状态，submit 时回写） */
  @State editingCode: string = '';

  aboutToAppear(): void {
    this.editingCode = this.code;
  }

  // OVERLAY-1: code prop 变化时同步 editingCode（恢复默认/导入 Profile 后）
  onCodeChange(): void {
    this.editingCode = this.code;
  }

  build() {
    Column() {
      Row() {
        Column({ space: 4 }) {
          Text(this.label).fontSize(UI.fontBody).fontColor(COLORS.ink).maxLines(1)
          Text(this.code.length > 0 ? `Space → ${this.code}` : '未分配助记码')
            .fontSize(UI.fontCaption).fontColor(COLORS.muted)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        TextInput({ text: this.editingCode, placeholder: '如 XZ' })
          .width(72)
          .height(UI.fieldHeight)
          .fontSize(UI.fontBody)
          .fontFamily('monospace')
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.primary)
          .placeholderColor(COLORS.muted)
          .textAlign(TextAlign.Center)
          .backgroundColor(COLORS.surfaceMuted)
          .borderRadius(UI.controlRadius)
          .onKeyEvent((e: KeyEvent) => {
            e.stopPropagation();
          })
          .onChange((value: string) => {
            this.editingCode = value.toUpperCase();
          })
          .onSubmit((_enterKey: EnterKeyType) => {
            const submitted: string = this.editingCode.toUpperCase().trim();
            const ok: boolean = this.codeChangeAction(this.actionKey, submitted);
            if (!ok) {
              // 拒绝（冲突/非法）：回滚到 service 中的当前码
              this.editingCode = this.code;
            } else {
              this.editingCode = submitted;
            }
          })
      }
      .width('100%')

      if (this.conflictText.length > 0) {
        Text(this.conflictText)
          .fontSize(10)
          .fontColor(COLORS.danger)
          .width('100%')
          .margin({ top: 4 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: COLORS.border })
  }
}

@Component
struct OverlayCommand {
  @Prop label: string = '';
  @Prop colorValue: string = COLORS.muted;
  activateAction: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .height(UI.controlHeight)
      .fontSize(UI.fontBody)
      .fontColor(this.colorValue === COLORS.primary ? Color.White :
        (this.colorValue === COLORS.danger ? COLORS.danger : COLORS.ink))
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.colorValue === COLORS.primary ? COLORS.primary :
        (this.colorValue === COLORS.danger ? COLORS.dangerSoft : COLORS.surfaceMuted))
      .borderRadius(UI.controlRadius)
      .margin({ left: 8 })
      .onClick(() => {
        this.activateAction();
      })
  }
}
