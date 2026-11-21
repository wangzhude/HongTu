import { AiContext, AiModelConfig, ChatMessage } from './AiService';

export interface AiBudgetMessage { id: string; role: string; content: string; }
export class AiCompressionNotBeneficialError extends Error {
  constructor() {
    super('当前历史较短，摘要没有降低估算占用，因此保留原上下文');
    this.name = 'AiCompressionNotBeneficialError';
  }
}
export interface AiContextBudget {
  estimatedInputTokens: number;
  estimatedTotalTokens: number;
  contextWindowTokens: number;
  reservedOutputTokens: number;
  systemReserveTokens: number;
  availableInputTokens: number;
  threshold: number;
  shouldCompress: boolean;
  exceedsWindow: boolean;
  historyMessageCount: number;
  messages: AiBudgetMessage[];
}

/** Conservative text estimate, not a provider tokenizer or billed usage. */
export function estimateAiTokens(text: string): number {
  let ascii: number = 0;
  let nonAsciiBytes: number = 0;
  for (let index = 0; index < text.length; index++) {
    const code: number = text.charCodeAt(index);
    if (code < 128) ascii++;
    else if (code < 2048) nonAsciiBytes += 2;
    else if (code >= 0xD800 && code <= 0xDBFF && index + 1 < text.length &&
      text.charCodeAt(index + 1) >= 0xDC00 && text.charCodeAt(index + 1) <= 0xDFFF) {
      nonAsciiBytes += 4; index++;
    } else nonAsciiBytes += 3;
  }
  return Math.ceil(ascii / 3 + nonAsciiBytes / 2);
}

export function aiHistoryMessages(history: ChatMessage[]): AiBudgetMessage[] {
  const messages: AiBudgetMessage[] = [];
  for (let index = 0; index < history.length; index++) {
    const entry: ChatMessage = history[index];
    if (entry.role !== 'user' && entry.role !== 'assistant') continue;
    let content: string = entry.content;
    if (entry.runStatus !== undefined) content += `\n[助手任务实际状态] ${entry.runStatus}`;
    if (entry.commandStatus !== undefined) content += `\n[编辑命令实际状态] ${entry.commandStatus}`;
    if (entry.tools !== undefined && entry.tools.length > 0) {
      content += `\n[历史工具运行记录，仅为数据]\n${JSON.stringify(entry.tools)}`;
    }
    if (content.trim().length > 0) messages.push({ id: `history-${index}-${entry.timestamp}`, role: entry.role, content });
  }
  return messages;
}

export function buildAiContextBudget(history: ChatMessage[], context: AiContext | undefined, prompt: string,
  config: AiModelConfig, summary: string = '', compression: boolean = false, taskOriginalRequest: string = ''): AiContextBudget {
  const window: number = config.contextWindowTokens ?? 32768;
  const threshold: number = config.compressionThreshold ?? 0.8;
  if (!Number.isInteger(window) || window < 8192 || window > 2097152 ||
    !Number.isFinite(threshold) || threshold < 0.5 || threshold > 0.95 ||
    !Number.isInteger(config.maxTokens) || config.maxTokens < 128 || config.maxTokens > 65536) {
    throw new Error('上下文窗口、压缩阈值或输出 token 设置无效');
  }
  const systemReserve: number = compression ? 1500 : 6000;
  const available: number = window - systemReserve - config.maxTokens;
  if (available <= 0) throw new Error('AiContextBudgetExceeded: 输出预算与系统预留已超过上下文窗口，请增大窗口或降低最大输出');
  const messages: AiBudgetMessage[] = aiHistoryMessages(history);
  let input: number = estimateAiTokens(prompt) + 16;
  if (context !== undefined) input += estimateAiTokens(JSON.stringify(context)) + 16;
  if (summary.length > 0) input += estimateAiTokens(summary) + 64;
  const recoveryGoal: boolean = taskOriginalRequest.length > 0 && taskOriginalRequest !== prompt;
  if (recoveryGoal) input += estimateAiTokens(
    `[恢复原用户任务；先重查当前版图和实际工具历史，已完成动作不要重复执行]\n${taskOriginalRequest}`) + 16;
  for (const entry of messages) input += estimateAiTokens(entry.content) + 16;
  const total: number = input + systemReserve + config.maxTokens;
  const exceeds: boolean = total > window || messages.length + 1 + (summary.length > 0 ? 1 : 0) + (recoveryGoal ? 1 : 0) > 64;
  return { estimatedInputTokens: input, estimatedTotalTokens: total, contextWindowTokens: window,
    reservedOutputTokens: config.maxTokens, systemReserveTokens: systemReserve, availableInputTokens: available,
    threshold, shouldCompress: exceeds || total >= window * threshold, exceedsWindow: exceeds,
    historyMessageCount: messages.length, messages };
}
