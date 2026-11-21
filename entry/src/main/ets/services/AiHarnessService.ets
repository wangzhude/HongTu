import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AiContext, AiModelConfig, ChatMessage, AiAgentTask, aiService } from './AiService';
import { pythonBridgeService } from './PythonBridgeService';
import { AiBudgetMessage, aiHistoryMessages, buildAiContextBudget } from './AiContextBudget';
import type { AiEditorQuery } from './AiWorkbenchQuery';

/** Native transport for the upstream Pydantic AI Harness / AG-UI runtime. */
export interface HarnessToolState {
  id: string; name: string; status: 'running' | 'completed' | 'failed';
  arguments: string; result: string;
}
export interface HarnessArtifactInfo {
  artifactId: string; script: string; originalRequest: string; summary: string;
  validationProfile?: 'generic_inverter';
}
export interface AiHarnessResult {
  text: string; reasoning: string; tools: HarnessToolState[];
  artifacts: HarnessArtifactInfo[]; commandsJson: string;
  contextUsage?: HarnessContextUsage;
  workflow?: HarnessWorkflow;
  toolCallPassed?: boolean;
}
export interface HarnessWorkflow { workflow: string; summary: string; }
interface HarnessRunControl { endpoint: string; token: string; runId: string; }
interface HarnessStopStatus { terminal?: boolean; workerStopped?: boolean; modelStopped?: boolean; }
export interface HarnessContextUsage {
  usedTokens: number; windowTokens: number; fraction: number; estimated: boolean;
  basis: 'heuristic' | 'provider_anchored'; windowSource: 'configured';
}
export interface AiHarnessCallbacks {
  onText: (delta: string) => void;
  onReasoning: (delta: string) => void;
  onTool: (state: HarnessToolState) => void;
  onStatus: (status: string) => void;
  onContextUsage?: (usage: HarnessContextUsage) => void;
  onHistoryInput?: (request: string, task: AiAgentTask | undefined, redact: (text: string) => string) => void;
  onEditorQuery?: (query: AiEditorQuery) => Promise<Object>;
  onRunId?: (runId: string) => void;
}
interface HarnessMessage { id: string; role: string; content: string; }
interface HarnessModelConfig {
  provider: string; endpoint: string; apiKey: string; modelName: string;
  temperature: number; maxTokens: number; timeoutMs: number;
  contextWindowTokens: number;
}
interface HarnessForwardedProps {
  modelConfig: HarnessModelConfig; layoutContext: AiContext;
  availableTabs: number; originalRequest: string;
  requiredValidationProfile?: 'generic_inverter';
  taskOriginalRequest?: string; resumeTask?: boolean; readOnly?: boolean; artifactGenerationAllowed?: boolean;
  runKind?: 'compression' | 'diagnostic'; conversationSummary?: string;
  editorProtocol?: string;
}
interface HarnessState { contextVersion?: number; }
interface HarnessInput {
  threadId: string; runId: string; messages: HarnessMessage[];
  tools: Object[]; context: Object[]; state: HarnessState; forwardedProps: HarnessForwardedProps;
}
interface HarnessCustomValue {
  artifactId?: string; script?: string; originalRequest?: string; summary?: string;
  validationProfile?: 'generic_inverter'; commands?: Object[];
  usedTokens?: number; windowTokens?: number; fraction?: number; estimated?: boolean;
  basis?: 'heuristic' | 'provider_anchored'; windowSource?: 'configured';
  queryId?: string; query?: AiEditorQuery; workflow?: string;
  toolCallPassed?: boolean;
}
interface AguiEvent {
  type: string; delta?: string; messageId?: string; toolCallId?: string;
  toolCallName?: string; content?: string; name?: string;
  value?: HarnessCustomValue; message?: string; code?: string;
}
interface ToolResultStatus { success?: boolean; status?: string; error?: string; }

/**
 * 校验伴随服务地址是否允许承载敏感 API Key：
 * 仅允许 HTTPS 加密传输或严格本机回环地址（127.0.0.1 / localhost / [::1]），
 * 严禁经局域网或公网明文 HTTP 转发上游模型 apiKey。
 */
export function isSecureOrLoopbackCompanionEndpoint(rawEndpoint: string): boolean {
  const trimmed: string = rawEndpoint.trim();
  if (/^https:\/\//i.test(trimmed)) {
    return true;
  }
  if (!/^http:\/\//i.test(trimmed)) {
    return false;
  }
  const rest: string = trimmed.substring(7);
  const slashIdx: number = rest.search(/[/?#]/);
  const authority: string = slashIdx >= 0 ? rest.substring(0, slashIdx) : rest;
  if (authority.length === 0 || authority.includes('@')) {
    return false;
  }
  let host: string = authority;
  if (authority.startsWith('[')) {
    const closeBracket: number = authority.indexOf(']');
    if (closeBracket < 0) return false;
    host = authority.substring(1, closeBracket).toLowerCase();
  } else {
    const colonIdx: number = authority.indexOf(':');
    host = (colonIdx >= 0 ? authority.substring(0, colonIdx) : authority).toLowerCase();
  }
  return host === '127.0.0.1' || host === 'localhost' || host === '::1';
}

function assertSafeApiKeyForwarding(companionEndpoint: string, apiKey: string): string {
  if (apiKey.trim().length === 0) {
    return '';
  }
  if (!isSecureOrLoopbackCompanionEndpoint(companionEndpoint)) {
    throw new Error('安全拦截：禁止经非本机明文 HTTP 伴随服务转发模型 API Key，请改用 127.0.0.1/localhost 本机地址或启用 HTTPS');
  }
  return apiKey;
}

function redactRunHistory(text: string, apiKey: string, token: string): string {
  let clean: string = token.length > 0 ? text.split(token).join('[已隐藏凭据]') : text;
  if (apiKey.length > 0) clean = clean.split(apiKey).join('[已隐藏凭据]');
  return aiService.redactConversationText(clean);
}

export class AiHarnessService {
  private activeRequest: http.HttpRequest | null = null;
  private serial: number = 0;
  private busy: boolean = false;
  private cancelRequest: (() => void) | null = null;
  private runControl: HarnessRunControl | null = null;

  private async controlRequest(url: string, token: string, body?: string): Promise<string> {
    const request = http.createHttp();
    try {
      const response = await request.request(url, { method: body === undefined ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        extraData: body, connectTimeout: 3000, readTimeout: 5000 });
      if (response.responseCode !== 200) throw new Error(`Agent 控制协议 HTTP ${response.responseCode}`);
      return String(response.result);
    } finally { request.destroy(); }
  }

  async cancelAndConfirm(): Promise<string> {
    const control: HarnessRunControl | null = this.runControl;
    this.cancel();
    if (control === null) return '已取消等待；后台状态未知';
    const url: string = `${control.endpoint}/v1/assistant/runs/${control.runId}`;
    try {
      let status: HarnessStopStatus = JSON.parse(await this.controlRequest(`${url}/cancel`, control.token, '{}')) as HarnessStopStatus;
      for (let i: number = 0; i < 15; i++) {
        if (status.terminal === true && status.workerStopped === true && status.modelStopped === true) return '已取消，后台模型任务与工具进程均已停止';
        await new Promise<void>((resolve) => { setTimeout(resolve, 150); });
        status = JSON.parse(await this.controlRequest(url, control.token)) as HarnessStopStatus;
      }
      return '取消请求已送达，后台仍在收尾；尚未确认停止';
    } catch (_) { return '已取消等待；伴随服务未确认后台停止，请检查连接或更新服务'; }
  }

  async diagnose(config: AiModelConfig): Promise<string> {
    const started: number = Date.now();
    const prompt: string = '请执行只读工具协议诊断，调用诊断工具后报告返回标记。';
    const result: AiHarnessResult = await this.run(prompt, { layers: [], currentLayer: 0, shapeCount: 0,
      selectedShape: null, layoutContextIncluded: false, selectionContextIncluded: false }, config, [], 0,
      { onText: (_text: string): void => {}, onReasoning: (_text: string): void => {},
        onTool: (_tool: HarnessToolState): void => {}, onStatus: (_status: string): void => {} },
      undefined, undefined, '', { originalRequest: prompt, readOnly: true, artifactGenerationAllowed: false }, false, true);
    if (result.toolCallPassed !== true || !result.tools.some((tool: HarnessToolState): boolean =>
      tool.name === 'check_tool_protocol' && tool.status === 'completed') || result.text.trim().length === 0) {
      throw new Error('伴随服务已响应，但模型未完成工具调用与流式答复；请更新服务或选择支持工具调用的模型');
    }
    return `模型工具调用与流式答复通过，耗时 ${((Date.now() - started) / 1000).toFixed(1)} 秒；未发送版图资料。`;
  }

  cancel(): void {
    this.serial++;
    if (this.cancelRequest !== null) this.cancelRequest();
  }

  async run(prompt: string, context: AiContext, config: AiModelConfig, history: ChatMessage[],
    availableTabs: number, callbacks: AiHarnessCallbacks,
    requiredValidationProfile?: 'generic_inverter', sessionId?: string, summary: string = '', task?: AiAgentTask,
    resumeTask: boolean = false, diagnostic: boolean = false): Promise<AiHarnessResult> {
    if (this.busy) throw new Error('版图助手正在处理请求');
    if (config.enabled === false) throw new Error('当前模型已停用，请在助手设置中启用');
    if (config.provider !== 'openai_compatible' && config.provider !== 'ollama_local') throw new Error('Agent 需要 OpenAI 兼容或 Ollama 工具协议');
    if (prompt.trim().length === 0 || prompt.length > 16000) throw new Error('需求须为 1–16000 字符');
    if (!Number.isInteger(availableTabs) || availableTabs < 0 || availableTabs > 8) throw new Error('工作区容量无效');
    if (task !== undefined && (task.originalRequest.trim().length === 0 || task.originalRequest.length > 16000)) throw new Error('原任务目标无效');
    if (task !== undefined && !resumeTask && task.originalRequest !== prompt) throw new Error('新任务目标必须与本轮用户请求一致');
    const budget = buildAiContextBudget(history, context, prompt, config, summary, false, task?.originalRequest ?? '');
    if (budget.exceedsWindow) throw new Error('AiContextBudgetExceeded: 完整会话超过当前窗口预算，请先压缩会话或调整模型窗口；原文未删除');
    if (summary.length > 6000) throw new Error('会话摘要超过 6000 字符，请重新压缩');
    pythonBridgeService.beginConnectionUse();
    this.busy = true;
    const ticket: number = ++this.serial;
    try {
      const bridge = await pythonBridgeService.loadConfig();
      // Only this run's already-loaded credentials are used; no extra reads or
      // credential retention. The callback receives bounded ordinary text only.
      const historyText = (value: string): string => redactRunHistory(value, config.apiKey, bridge.token);
      callbacks.onHistoryInput?.(historyText(prompt), task === undefined ? undefined : {
        originalRequest: historyText(task.originalRequest), readOnly: task.readOnly,
        artifactGenerationAllowed: task.artifactGenerationAllowed, requiredValidationProfile: task.requiredValidationProfile }, historyText);
      if (ticket !== this.serial) throw new Error('助手请求已取消');
      if (bridge.token.length === 0) throw new Error('Agent 尚未连接：请打开助手中的“连接 Agent 伴随服务”，填写地址与令牌并检查连接');
      const endpoint: string = bridge.endpoint.trim().replace(/\/$/, '');
      const safeForwardedKey: string = assertSafeApiKeyForwarding(endpoint, config.apiKey);
      const messages: HarnessMessage[] = budget.messages.map((entry: AiBudgetMessage): HarnessMessage =>
        ({ id: entry.id, role: entry.role, content: entry.content }));
      const runId: string = `hongtu-${Date.now()}-${ticket}`;
      this.runControl = { endpoint, token: bridge.token, runId };
      callbacks.onRunId?.(runId);
      messages.push({ id: `${runId}-user`, role: 'user', content: prompt });
      const body: HarnessInput = {
        threadId: this.conversationId(sessionId, runId), runId, messages, tools: [], context: [], state: {},
        forwardedProps: { modelConfig: { provider: config.provider, endpoint: config.endpoint,
          apiKey: safeForwardedKey, modelName: config.modelName, temperature: config.temperature,
          maxTokens: config.maxTokens, timeoutMs: config.timeoutMs, contextWindowTokens: budget.contextWindowTokens },
          layoutContext: context, availableTabs, originalRequest: prompt,
          requiredValidationProfile: task?.requiredValidationProfile ?? requiredValidationProfile, conversationSummary: summary,
          taskOriginalRequest: task?.originalRequest, resumeTask: task === undefined ? undefined : resumeTask,
          readOnly: task?.readOnly, artifactGenerationAllowed: task?.artifactGenerationAllowed }
      };
      if (callbacks.onEditorQuery !== undefined) body.forwardedProps.editorProtocol = 'hongtu-editor-query/v1';
      if (diagnostic) body.forwardedProps.runKind = 'diagnostic';
      callbacks.onStatus('已连接开源 Harness，正在处理版图需求…');
      return await this.stream(`${endpoint}/v1/assistant`, this.requestBody(body), bridge.token, config.apiKey, ticket, callbacks, false, config.timeoutMs);
    } finally { this.busy = false; this.runControl = null; pythonBridgeService.endConnectionUse(); }
  }

  private conversationId(id: string | undefined, fallback: string): string {
    if (id === undefined) return fallback;
    if (!/^[A-Za-z0-9_.:-]{1,160}$/.test(id)) throw new Error('会话标识无效');
    return id;
  }

  private requestBody(body: HarnessInput): string {
    const encoded: string = JSON.stringify(body);
    // A conservative UTF-8 upper bound keeps the authenticated HTTP request under 512 KiB.
    if (encoded.length * 3 > 512 * 1024) throw new Error('AiContextBudgetExceeded: 会话超出单次传输预算，请先压缩；原文未删除');
    return encoded;
  }

  async compress(history: ChatMessage[], config: AiModelConfig, conversationId: string,
    callbacks: AiHarnessCallbacks): Promise<AiHarnessResult> {
    if (this.busy) throw new Error('版图助手正在处理请求');
    this.conversationId(conversationId, '');
    const usable: ChatMessage[] = history.filter((entry: ChatMessage): boolean =>
      (entry.role === 'user' || entry.role === 'assistant') &&
      (entry.content.trim().length > 0 || entry.commandStatus !== undefined || (entry.tools !== undefined && entry.tools.length > 0)));
    if (usable.length === 0) throw new Error('没有可压缩的会话内容');
    const prompt: string = '请使用官方会话压缩能力总结所提供的历史资料，保留真实状态和未完成事项。';
    buildAiContextBudget([], undefined, prompt, config, '', true);
    pythonBridgeService.beginConnectionUse();
    this.busy = true;
    const ticket: number = ++this.serial;
    try {
      const bridge = await pythonBridgeService.loadConfig();
      callbacks.onHistoryInput?.(redactRunHistory(prompt, config.apiKey, bridge.token), undefined,
        (text: string): string => redactRunHistory(text, config.apiKey, bridge.token));
      if (ticket !== this.serial) throw new Error('助手请求已取消');
      if (bridge.token.length === 0) throw new Error('请先连接内置助手服务');
      let covered: number = 0;
      let result: AiHarnessResult = { text: '', reasoning: '', tools: [], artifacts: [], commandsJson: '' };
      // Each block uses the official SDK compact_now, never a local summary or truncated text.
      for (let block = 0; covered < usable.length && block < 8; block++) {
        if (ticket !== this.serial) throw new Error('助手请求已取消');
        const chunk: ChatMessage[] = [];
        while (covered + chunk.length < usable.length) {
          const candidate: ChatMessage[] = chunk.concat([usable[covered + chunk.length]]);
          const budget = buildAiContextBudget(candidate, undefined, prompt, config, result.text, true);
          if (budget.exceedsWindow || JSON.stringify(budget.messages).length * 3 > 440 * 1024) break;
          chunk.push(usable[covered + chunk.length]);
        }
        if (chunk.length === 0) throw new Error('AiContextBudgetExceeded: 单条完整消息与摘要无法放入压缩窗口；请增大窗口，原文未删除');
        const runId: string = `hongtu-compact-${Date.now()}-${ticket}-${block}`;
        const messages: HarnessMessage[] = aiHistoryMessages(chunk).map((entry: AiBudgetMessage): HarnessMessage =>
          ({ id: entry.id, role: entry.role, content: entry.content }));
        messages.push({ id: `${runId}-request`, role: 'user', content: prompt });
        const compactEndpoint: string = bridge.endpoint.trim().replace(/\/$/, '');
        const safeCompactKey: string = assertSafeApiKeyForwarding(compactEndpoint, config.apiKey);
        const body: HarnessInput = { threadId: conversationId, runId, messages, tools: [], context: [], state: {},
          forwardedProps: { modelConfig: { provider: config.provider, endpoint: config.endpoint, apiKey: safeCompactKey,
            modelName: config.modelName, temperature: config.temperature, maxTokens: config.maxTokens,
            timeoutMs: config.timeoutMs, contextWindowTokens: config.contextWindowTokens ?? 32768 },
            layoutContext: { layers: [], currentLayer: 0, shapeCount: 0, selectedShape: null },
            availableTabs: 0, originalRequest: prompt, runKind: 'compression', conversationSummary: result.text } };
        callbacks.onStatus(`官方 SDK 正在压缩第 ${block + 1} 段会话…`);
        result = await this.stream(`${compactEndpoint}/v1/assistant`, this.requestBody(body),
          bridge.token, config.apiKey, ticket, callbacks, true, config.timeoutMs);
        result.text = redactRunHistory(result.text, config.apiKey, bridge.token).trim();
        covered += chunk.length;
      }
      if (covered !== usable.length) throw new Error('AiContextBudgetExceeded: 完整会话需要超过 8 段压缩，请增大窗口；原文未删除');
      return result;
    } finally { this.busy = false; pythonBridgeService.endConnectionUse(); }
  }

  private async stream(url: string, body: string, token: string, apiKey: string, ticket: number,
    callbacks: AiHarnessCallbacks, compression: boolean = false, timeoutMs: number = 180000): Promise<AiHarnessResult> {
    const request = http.createHttp();
    this.activeRequest = request;
    const decoder = new util.TextDecoder('utf-8', { fatal: true });
    const result: AiHarnessResult = { text: '', reasoning: '', tools: [], artifacts: [], commandsJson: '' };
    let partial: string = '';
    let received: number = 0;
    let code: number = 0;
    let dataEnded: boolean = false;
    let runFinished: boolean = false;
    let finished: boolean = false;
    let lastTextMessage: string = '';
    let lastReasoningMessage: string = '';
    let textSeparatorPending: boolean = false;
    let reasoningSeparatorPending: boolean = false;
    const answeredQueries: Set<string> = new Set<string>();
    return new Promise<AiHarnessResult>((resolve, reject) => {
      let idleTimer: number = -1;
      let totalTimer: number = -1;
      const cleanup = (): void => {
        clearTimeout(idleTimer); clearTimeout(totalTimer);
        this.cancelRequest = null;
        try { request.off('dataReceive'); request.off('dataEnd'); request.destroy(); } catch (_) {}
        if (this.activeRequest === request) this.activeRequest = null;
      };
      const fail = (message: string): void => {
        if (finished) return;
        finished = true; cleanup();
        // Credential-bearing transport input is never put into UI history or logs.
        const clean: string = redactRunHistory(message, apiKey, token);
        reject(new Error(clean));
      };
      const resetIdle = (): void => {
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => fail('助手连接读取超时'), Math.min(45000, timeoutMs));
      };
      const finishIfReady = (): void => {
        if (finished || !dataEnded || code === 0) return;
        if (code !== 200) { fail(`助手服务请求失败（HTTP ${code}）`); return; }
        if (!runFinished) { fail('助手流式响应中断，未载入未完成结果'); return; }
        if (ticket !== this.serial) { fail('助手请求已取消'); return; }
        if (result.text.trim().length === 0 && result.artifacts.length === 0 && result.commandsJson.length === 0 && result.workflow === undefined) {
          fail('助手未返回答复或版图结果'); return;
        }
        finished = true; cleanup(); resolve(result);
      };
      const updateTool = (event: AguiEvent): HarnessToolState | undefined => {
        if (typeof event.toolCallId !== 'string' || event.toolCallId.length > 256) return undefined;
        let tool = result.tools.find((item: HarnessToolState): boolean => item.id === event.toolCallId);
        if (tool === undefined) {
          if (result.tools.length >= 32) { fail('助手工具调用超过限制'); return undefined; }
          tool = { id: event.toolCallId, name: event.toolCallName ?? '版图工具', status: 'running', arguments: '', result: '' };
          result.tools.push(tool);
        }
        return tool;
      };
      const publishTool = (tool: HarnessToolState): void => {
        callbacks.onTool({ id: tool.id, name: tool.name, status: tool.status,
          arguments: tool.arguments, result: tool.result });
      };
      const consume = (line: string): void => {
        if (finished || ticket !== this.serial) return;
        const trimmed: string = line.trim();
        if (trimmed.length === 0 || trimmed.startsWith(':') || /^(?:id|event|retry):/.test(trimmed)) return;
        if (!trimmed.startsWith('data:')) { fail('助手服务返回了无效 AG-UI 流'); return; }
        let event: AguiEvent;
        try { event = JSON.parse(trimmed.substring(5).trim()) as AguiEvent; } catch (_) {
          fail('助手服务返回了无效 AG-UI 事件'); return;
        }
        if (event === null || typeof event !== 'object' || typeof event.type !== 'string') {
          fail('助手服务返回了无效 AG-UI 事件'); return;
        }
        if (event.type === 'RUN_ERROR') { fail(typeof event.message === 'string' ? event.message.substring(0, 4000) : '开源助手运行失败'); return; }
        if (compression && (event.type.startsWith('TOOL_CALL_') ||
          (event.type === 'CUSTOM' && (event.name === 'hongtu.artifact' || event.name === 'hongtu.commands')))) {
          fail('会话压缩返回了未经允许的工具或编辑结果'); return;
        }
        if (event.type === 'RUN_FINISHED') { runFinished = true; return; }
        if (event.type === 'TEXT_MESSAGE_START') {
          textSeparatorPending = result.text.length > 0 && lastTextMessage !== event.messageId;
          lastTextMessage = event.messageId ?? ''; return;
        }
        if (event.type === 'REASONING_MESSAGE_START') {
          reasoningSeparatorPending = result.reasoning.length > 0 && lastReasoningMessage !== event.messageId;
          lastReasoningMessage = event.messageId ?? ''; return;
        }
        if (event.type === 'TEXT_MESSAGE_CONTENT' || event.type === 'REASONING_MESSAGE_CONTENT') {
          if (typeof event.delta !== 'string') { fail('助手事件正文无效'); return; }
          if (event.type === 'TEXT_MESSAGE_CONTENT') {
            if (event.delta.length > 0 && textSeparatorPending) {
              textSeparatorPending = false; result.text += '\n\n'; callbacks.onText('\n\n');
            }
            result.text += event.delta;
            if (compression && result.text.length > 6000) { fail('会话摘要超过 6000 字符，未替换原文'); return; }
            callbacks.onText(event.delta);
          } else {
            if (event.delta.length > 0 && reasoningSeparatorPending) {
              reasoningSeparatorPending = false; result.reasoning += '\n\n'; callbacks.onReasoning('\n\n');
            }
            result.reasoning += event.delta; callbacks.onReasoning(event.delta);
          }
          if (result.text.length + result.reasoning.length > 512 * 1024) fail('助手文本超过限制');
          return;
        }
        if (event.type === 'TOOL_CALL_START' || event.type === 'TOOL_CALL_ARGS' ||
          event.type === 'TOOL_CALL_END' || event.type === 'TOOL_CALL_RESULT') {
          const tool = updateTool(event);
          if (tool === undefined) return;
          if (event.type === 'TOOL_CALL_START') callbacks.onStatus(`正在调用 ${tool.name}…`);
          if (event.type === 'TOOL_CALL_ARGS' && typeof event.delta === 'string') {
            tool.arguments += event.delta;
            if (tool.arguments.length > 65536) { fail('助手工具参数超过限制'); return; }
          }
          if (event.type === 'TOOL_CALL_RESULT') {
            tool.result = typeof event.content === 'string' ? event.content.substring(0, 16000) : '';
            tool.status = 'completed';
            // Official SDK RetryPromptPart appends this public retry suffix to
            // both tool exceptions and parameter validation errors.
            const retrySuffix: string = 'Fix the errors and try again.';
            if (typeof event.content === 'string' && event.content.trim().endsWith(retrySuffix)) tool.status = 'failed';
            // Planning returns this exact business error as a successful tool
            // transport result. Do not apply the wording to arbitrary tools.
            if (tool.name === 'update_task_status' && typeof event.content === 'string' &&
              event.content.endsWith(" not found.") && /^Step with id '[^'\r\n]+' not found\.$/.test(event.content)) {
              tool.status = 'failed';
            }
            try {
              const status = JSON.parse(tool.result) as ToolResultStatus;
              if (status.success === false || status.status === 'failed' || typeof status.error === 'string') tool.status = 'failed';
            } catch (_) { /* Non-JSON SDK tool output remains a readable result. */ }
          }
          publishTool(tool); return;
        }
        if (event.type === 'CUSTOM' && event.value !== undefined) {
          if (event.value === null || typeof event.value !== 'object') { fail('助手自定义事件无效'); return; }
          if (event.name === 'hongtu.editor_query') {
            const id: string = event.value.queryId ?? '';
            const query: AiEditorQuery | undefined = event.value.query;
            if (compression || !/^[a-f0-9]{32}$/.test(id) || query === undefined || answeredQueries.has(id) ||
              answeredQueries.size >= 16 || callbacks.onEditorQuery === undefined) { fail('编辑器实时查询协议无效'); return; }
            answeredQueries.add(id);
            callbacks.onEditorQuery(query).then(async (reply: Object): Promise<void> => {
              if (finished || ticket !== this.serial) return;
              const raw: string = JSON.stringify(reply);
              if (raw.length * 3 > 96 * 1024) throw new Error('编辑器查询结果超过传输预算');
              await this.controlRequest(url.replace(/\/v1\/assistant$/, `/v1/assistant/queries/${id}`), token, raw);
            }).catch((_error: Object): void => { fail('编辑器实时查询失败，文档未修改；请检查连接或重新开始任务'); });
          } else if (event.name === 'hongtu.workflow') {
            const name: string = event.value.workflow ?? '';
            if (compression || !['pcell', 'ports', 'route', 'boolean_union', 'boolean_intersection', 'boolean_difference', 'cell_hierarchy'].includes(name) ||
              typeof event.value.summary !== 'string' || event.value.summary.length > 240 || result.workflow !== undefined ||
              result.commandsJson.length > 0 || result.artifacts.length > 0) { fail('专业流程提案无效'); return; }
            result.workflow = { workflow: name, summary: event.value.summary };
          } else if (event.name === 'hongtu.diagnostic') {
            if (compression || typeof event.value.toolCallPassed !== 'boolean') { fail('工具诊断结果无效'); return; }
            result.toolCallPassed = event.value.toolCallPassed;
          } else if (event.name === 'hongtu.context_usage') {
            const value: HarnessCustomValue = event.value;
            if (typeof value.usedTokens !== 'number' || !Number.isFinite(value.usedTokens) || value.usedTokens < 0 ||
              typeof value.windowTokens !== 'number' || !Number.isFinite(value.windowTokens) || value.windowTokens <= 0 ||
              typeof value.fraction !== 'number' || !Number.isFinite(value.fraction) || value.fraction < 0 ||
              value.estimated !== true || value.windowSource !== 'configured' ||
              (value.basis !== 'heuristic' && value.basis !== 'provider_anchored')) { fail('助手上下文用量无效'); return; }
            const usage: HarnessContextUsage = { usedTokens: value.usedTokens, windowTokens: value.windowTokens,
              fraction: value.fraction, estimated: true, basis: value.basis, windowSource: 'configured' };
            result.contextUsage = usage;
            callbacks.onContextUsage?.(usage);
          } else if (event.name === 'hongtu.artifact') {
            const value: HarnessCustomValue = event.value;
            if (typeof value.artifactId !== 'string' || !/^[a-f0-9-]{32,36}$/i.test(value.artifactId) ||
              typeof value.script !== 'string' || value.script.length > 65536 ||
              typeof value.originalRequest !== 'string' || value.originalRequest.length > 16000 ||
              typeof value.summary !== 'string' || value.summary.length > 4000 || result.artifacts.length >= 1 ||
              result.commandsJson.length > 0 || result.workflow !== undefined) {
              fail('助手生成结果元数据无效'); return;
            }
            result.artifacts.push({ artifactId: value.artifactId, script: value.script,
              originalRequest: value.originalRequest, summary: value.summary, validationProfile: value.validationProfile });
          } else if (event.name === 'hongtu.commands') {
            if (!Array.isArray(event.value.commands) || event.value.commands.length > 256 ||
              result.artifacts.length > 0 || result.commandsJson.length > 0 || result.workflow !== undefined) { fail('助手编辑方案无效'); return; }
            result.commandsJson = JSON.stringify(event.value.commands);
          }
        }
      };
      const consumeSafely = (line: string): void => {
        try { consume(line); } catch (_) { fail('助手事件处理失败'); }
      };
      this.cancelRequest = (): void => fail('助手请求已取消');
      totalTimer = setTimeout(() => fail('助手运行总时长超过 180 秒'), 180000);
      resetIdle();
      try {
      request.on('dataReceive', (data: ArrayBuffer): void => {
        if (finished) return;
        if (ticket !== this.serial) { fail('助手请求已取消'); return; }
        received += data.byteLength;
        if (received > 8 * 1024 * 1024) { fail('助手事件流超过限制'); return; }
        resetIdle();
        try { partial += decoder.decodeToString(new Uint8Array(data), { stream: true }); } catch (_) {
          fail('助手事件流 UTF-8 编码无效'); return;
        }
        if (partial.length > 1024 * 1024) { fail('助手事件单行超过限制'); return; }
        const lines: string[] = partial.split('\n'); partial = lines[lines.length - 1];
        for (let index = 0; index < lines.length - 1; index++) { consumeSafely(lines[index]); if (finished) return; }
      });
      request.on('dataEnd', (): void => {
        if (finished) return;
        try { partial += decoder.decodeToString(new Uint8Array(0), { stream: false }); } catch (_) {
          fail('助手事件流 UTF-8 数据不完整'); return;
        }
        if (partial.trim().length > 0) consumeSafely(partial);
        partial = ''; dataEnded = true; finishIfReady();
      });
      request.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', Accept: 'text/event-stream', Authorization: `Bearer ${token}` },
        extraData: body, connectTimeout: Math.min(15000, timeoutMs), readTimeout: timeoutMs
      }).then((responseCode: number): void => {
        code = responseCode;
        if (code !== 200) {
          fail(code === 401 || code === 403 ? `Agent 连接认证失败（HTTP ${code}），请打开助手连接设置更新伴随服务令牌` :
            `助手服务请求失败（HTTP ${code}），请打开助手连接设置检查或更新伴随服务`); return;
        }
        finishIfReady();
      }).catch((_error: Object): void => fail('助手流式连接失败，请打开助手连接设置检查伴随服务地址、令牌和网络')); }
      catch (_) { fail('助手流式连接无法启动'); }
    });
  }
}

export const aiHarnessService = new AiHarnessService();
