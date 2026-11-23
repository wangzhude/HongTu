import type { ChatMessage, ChatRole, AiChatToolState, AiProcessStep, AiTaskCheckpoint, AiProjectKnowledge } from './AiService';
import { cloneStructured } from '../common/CloneUtils';

export interface AiConversationSummary {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messageCount: number;
}

export interface AiContextOptions {
  includeHistory: boolean;
  includeLayout: boolean;
  includeSelection: boolean;
}
export interface AiConversationCompression {
  summary: string;
  sourceMessageCount: number;
  createdAt: number;
  modelName: string;
}

interface ConversationRecord {
  id: string;
  title: string;
  renamed: boolean;
  createdAt: number;
  updatedAt: number;
  options: AiContextOptions;
  messages: ChatMessage[];
  revision: number;
  compression?: AiConversationCompression;
  checkpoint?: AiTaskCheckpoint;
}
interface ConversationSnapshot {
  version: number;
  generation: number;
  activeId: string;
  conversations: ConversationRecord[];
  knowledge?: AiProjectKnowledge[];
}
interface ConversationCommit { slot: number; generation: number; }

/** Complete, versioned snapshots. No old conversation/message is evicted to make room. */
export class AiConversationStore {
  private readonly slots: string[] = ['hongtu_ai_conversations_v1_a', 'hongtu_ai_conversations_v1_b'];
  private readonly commitKey: string = 'hongtu_ai_conversations_v1_commit';
  private readonly legacyKey: string = 'hongtu_ai_history';
  private readonly maxBytes: number = 16 * 1024 * 1024;
  private state: ConversationSnapshot;
  private activeSlot: number = -1;
  private sequence: number = 0;
  private storageError: string = '';

  constructor() {
    const initial: ConversationRecord = this.emptyConversation();
    this.state = { version: 1, generation: 0, activeId: initial.id, conversations: [initial] };
    this.load();
  }

  getStorageError(): string { return this.storageError; }
  getActiveId(): string { return this.state.activeId; }
  getRevision(): number { return this.find(this.state, this.state.activeId).revision; }
  getCompression(): AiConversationCompression | undefined {
    const compression = this.find(this.state, this.state.activeId).compression;
    return compression === undefined ? undefined : cloneStructured(compression) as AiConversationCompression;
  }
  getCheckpoint(): AiTaskCheckpoint | undefined {
    const item = this.find(this.state, this.state.activeId).checkpoint;
    return item === undefined ? undefined : cloneStructured(item) as AiTaskCheckpoint;
  }
  setCheckpoint(checkpoint: AiTaskCheckpoint, id: string): void {
    this.validateCheckpoint(checkpoint);
    const next = this.cloneState(); const record = this.find(next, id);
    record.checkpoint = cloneStructured(checkpoint) as AiTaskCheckpoint;
    record.updatedAt = Date.now(); record.revision++; this.commit(next);
  }
  getKnowledge(documentIdentity: string): AiProjectKnowledge | undefined {
    const item = this.state.knowledge?.find((note: AiProjectKnowledge): boolean => note.documentIdentity === documentIdentity);
    return item === undefined ? undefined : { documentIdentity: item.documentIdentity, text: item.text, revision: item.revision };
  }
  setKnowledge(documentIdentity: string, text: string): void {
    if (!documentIdentity || documentIdentity.length > 256 || text.length > 8000) throw new Error('文档说明超过容量限制');
    const next = this.cloneState(); const notes: AiProjectKnowledge[] = next.knowledge ?? [];
    const index: number = notes.findIndex((note: AiProjectKnowledge): boolean => note.documentIdentity === documentIdentity);
    if (text.trim().length === 0) {
      next.knowledge = notes.filter((note: AiProjectKnowledge): boolean => note.documentIdentity !== documentIdentity);
    } else {
      const note: AiProjectKnowledge = { documentIdentity, text: text.trim(), revision: index < 0 ? 1 : notes[index].revision + 1 };
      if (index < 0) notes.push(note); else notes[index] = note;
      next.knowledge = notes;
    }
    this.commit(next);
  }
  applyCompression(summary: string, count: number, id: string, revision: number, modelName: string): boolean {
    if (id !== this.state.activeId || !this.has(id)) return false;
    const current = this.find(this.state, id);
    if (current.revision !== revision || !Number.isInteger(count) || count < 1 || count > current.messages.length - 4 ||
      (current.compression !== undefined && count < current.compression.sourceMessageCount)) return false;
    if (summary.trim().length === 0 || summary.length > 16000 || modelName.length === 0 || modelName.length > 256) {
      throw new Error('会话摘要无效或超过 16000 字符，原记录未改动');
    }
    const next = this.cloneState(); const record = this.find(next, id);
    record.compression = { summary, sourceMessageCount: count, createdAt: Date.now(), modelName };
    record.revision++; record.updatedAt = Date.now(); this.commit(next); return true;
  }
  clearCompression(): void {
    const next = this.cloneState(); const record = this.find(next, next.activeId);
    if (record.compression === undefined) return;
    record.compression = undefined; record.revision++; this.commit(next);
  }
  has(id: string): boolean { return this.state.conversations.some((item: ConversationRecord): boolean => item.id === id); }
  getSummaries(): AiConversationSummary[] {
    return this.state.conversations.map((item: ConversationRecord): AiConversationSummary => ({
      id: item.id, title: item.title, createdAt: item.createdAt, updatedAt: item.updatedAt, messageCount: item.messages.length
    })).sort((a: AiConversationSummary, b: AiConversationSummary): number => b.updatedAt - a.updatedAt);
  }
  getMessages(id: string = this.state.activeId): ChatMessage[] {
    return this.cloneMessages(this.find(this.state, id).messages);
  }
  getOptions(): AiContextOptions {
    const options: AiContextOptions = this.find(this.state, this.state.activeId).options;
    return { includeHistory: options.includeHistory, includeLayout: options.includeLayout, includeSelection: options.includeSelection };
  }
  setOptions(options: AiContextOptions): void {
    this.validateOptions(options);
    const next = this.cloneState();
    this.find(next, next.activeId).options = { includeHistory: options.includeHistory,
      includeLayout: options.includeLayout, includeSelection: options.includeSelection };
    this.find(next, next.activeId).revision++;
    this.commit(next);
  }
  create(): string {
    if (this.state.conversations.length >= 64) throw new Error('会话已达 64 个，请先导出并删除不再需要的会话');
    const next = this.cloneState();
    const record = this.emptyConversation();
    next.conversations.push(record); next.activeId = record.id;
    this.commit(next); return record.id;
  }
  switchTo(id: string): boolean {
    if (!this.has(id)) return false;
    if (id === this.state.activeId) return true;
    const next = this.cloneState(); next.activeId = id; this.commit(next); return true;
  }
  rename(id: string, title: string): boolean {
    if (!this.has(id)) return false;
    const clean: string = title.trim();
    if (clean.length === 0 || clean.length > 80 || /[\u0000-\u001F\u007F]/.test(clean)) {
      throw new Error('会话名称须为 1–80 个可显示字符');
    }
    const next = this.cloneState(); const record = this.find(next, id);
    record.title = clean; record.renamed = true; record.updatedAt = Date.now(); record.revision++;
    this.commit(next); return true;
  }
  delete(id: string): boolean {
    if (!this.has(id)) return false;
    const next = this.cloneState();
    next.conversations = next.conversations.filter((item: ConversationRecord): boolean => item.id !== id);
    if (next.conversations.length === 0) next.conversations.push(this.emptyConversation());
    if (next.activeId === id) {
      next.activeId = next.conversations.reduce((a: ConversationRecord, b: ConversationRecord): ConversationRecord =>
        a.updatedAt >= b.updatedAt ? a : b).id;
    }
    this.commit(next); return true;
  }
  clear(): void {
    const next = this.cloneState(); const record = this.find(next, next.activeId);
    record.messages = []; record.compression = undefined; record.checkpoint = undefined; record.updatedAt = Date.now(); record.revision++; this.commit(next);
  }
  append(id: string, messages: ChatMessage[]): void {
    if (!this.has(id)) throw new Error('原会话已不存在，回复未写入其他会话');
    const next = this.cloneState(); const record = this.find(next, id);
    const hadUser: boolean = record.messages.some((message: ChatMessage): boolean => message.role === 'user');
    record.messages = record.messages.concat(this.cloneMessages(messages));
    if (!record.renamed && !hadUser) {
      const first = messages.find((message: ChatMessage): boolean => message.role === 'user' && message.content.trim().length > 0);
      if (first !== undefined) record.title = this.promptTitle(first.content);
    }
    record.updatedAt = Date.now(); record.revision++; this.commit(next);
  }
  markLastCommand(id: string, status: 'pending' | 'executed' | 'failed' | undefined): void {
    const next = this.cloneState(); const record = this.find(next, id);
    for (let i = record.messages.length - 1; i >= 0; i--) {
      const message = record.messages[i];
      if (message.role === 'assistant' && message.isCommand) {
        if (record.compression !== undefined && i < record.compression.sourceMessageCount) record.compression = undefined;
        message.commandStatus = status; record.updatedAt = Date.now(); record.revision++; this.commit(next); return;
      }
    }
  }

  private emptyConversation(): ConversationRecord {
    const now: number = Date.now();
    const id: string = `conversation-${now.toString(36)}-${++this.sequence}-${Math.floor(Math.random() * 0x100000000).toString(36)}`;
    return { id, title: '新会话', renamed: false, createdAt: now, updatedAt: now,
      options: { includeHistory: true, includeLayout: true, includeSelection: true }, messages: [], revision: 0 };
  }
  private promptTitle(prompt: string): string {
    const clean: string = prompt.replace(/[\u0000-\u0020\u007F]+/g, ' ').trim();
    return clean.length > 32 ? clean.substring(0, 32) + '…' : clean;
  }
  private find(state: ConversationSnapshot, id: string): ConversationRecord {
    const record = state.conversations.find((item: ConversationRecord): boolean => item.id === id);
    if (record === undefined) throw new Error('会话不存在');
    return record;
  }
  private cloneMessages(messages: ChatMessage[]): ChatMessage[] {
    return cloneStructured(messages) as ChatMessage[];
  }
  private cloneState(): ConversationSnapshot { return cloneStructured(this.state) as ConversationSnapshot; }
  private byteLength(value: string): number {
    let bytes: number = 0;
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code <= 0x7F) bytes++;
      else if (code <= 0x7FF) bytes += 2;
      else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length &&
        value.charCodeAt(i + 1) >= 0xDC00 && value.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
      else bytes += 3;
    }
    return bytes;
  }
  private validateOptions(options: AiContextOptions): void {
    if (!options || typeof options.includeHistory !== 'boolean' || typeof options.includeLayout !== 'boolean' ||
      typeof options.includeSelection !== 'boolean') throw new Error('会话上下文选项无效');
  }
  private validateMessage(message: ChatMessage): void {
    if (message.runStatus !== undefined && !['completed', 'failed', 'cancelled'].includes(message.runStatus)) throw new Error('任务状态无效');
    if (!message || !['user', 'assistant', 'system'].includes(message.role) || typeof message.content !== 'string' ||
      message.content.length > 1048576 || !Number.isFinite(message.timestamp) || message.timestamp < 0 ||
      (message.reasoning !== undefined && (typeof message.reasoning !== 'string' || message.reasoning.length > 524288)) ||
      (message.isCommand !== undefined && typeof message.isCommand !== 'boolean') ||
      (message.commandStatus !== undefined && !['pending', 'executed', 'failed'].includes(message.commandStatus))) {
      throw new Error('会话消息无效或超过单条容量限制，原记录已保留');
    }
    if (message.tools !== undefined) {
      if (!Array.isArray(message.tools) || message.tools.length > 64) throw new Error('会话工具记录超过限制');
      for (const tool of message.tools) this.validateTool(tool);
    }
    if (message.steps !== undefined) {
      if (!Array.isArray(message.steps) || message.steps.length > 128) throw new Error('会话步骤记录超过限制');
      for (const step of message.steps) {
        if (!step || typeof step.id !== 'string' || step.id.length === 0 || step.id.length > 160 ||
          !['thinking', 'tool', 'commentary'].includes(step.kind) ||
          typeof step.title !== 'string' || step.title.length > 256 ||
          typeof step.text !== 'string' || step.text.length > 524288 ||
          !['running', 'completed', 'failed'].includes(step.status)) {
          throw new Error('会话步骤记录无效');
        }
        if (step.tool !== undefined) this.validateTool(step.tool);
      }
    }
    if (message.attachments !== undefined) {
      if (!Array.isArray(message.attachments) || message.attachments.length > 24) throw new Error('消息附件数量超过限制');
      for (const att of message.attachments) {
        if (!att || typeof att.id !== 'string' || typeof att.name !== 'string' || att.name.length > 256 ||
          !['image', 'layout', 'text', 'binary'].includes(att.kind) ||
          typeof att.sandboxPath !== 'string' || att.sandboxPath.length > 2048 ||
          !Number.isFinite(att.sizeBytes) || att.sizeBytes < 0) {
          throw new Error('消息附件元数据无效');
        }
      }
    }
    if (message.webSources !== undefined) {
      if (!Array.isArray(message.webSources) || message.webSources.length > 24) throw new Error('联网来源数量超过限制');
      for (const ws of message.webSources) {
        if (!ws || typeof ws.title !== 'string' || typeof ws.url !== 'string' || ws.url.length > 2048) {
          throw new Error('联网来源记录无效');
        }
      }
    }
    if (message.askUserExchanges !== undefined) {
      if (!Array.isArray(message.askUserExchanges) || message.askUserExchanges.length > 24) throw new Error('互动提问记录超过限制');
      for (const ex of message.askUserExchanges) {
        if (!ex || typeof ex.id !== 'string' || typeof ex.question !== 'string' || !Array.isArray(ex.options)) {
          throw new Error('互动提问记录无效');
        }
      }
    }
    const task = message.task;
    if (task !== undefined && (!task || message.role !== 'user' || typeof task.originalRequest !== 'string' ||
      task.originalRequest.trim().length === 0 || task.originalRequest.length > 16000 ||
      typeof task.readOnly !== 'boolean' || typeof task.artifactGenerationAllowed !== 'boolean' ||
      (task.readOnly && task.artifactGenerationAllowed) ||
      (task.requiredValidationProfile !== undefined && task.requiredValidationProfile !== 'generic_inverter') ||
      Object.keys(task).some((key: string): boolean => !['originalRequest', 'readOnly', 'artifactGenerationAllowed', 'requiredValidationProfile'].includes(key)))) {
      throw new Error('原任务目标或执行策略无效，原会话记录已保留');
    }
  }
  private validateTool(tool: AiChatToolState): void {
    if (!tool || typeof tool.id !== 'string' || tool.id.length === 0 || tool.id.length > 256 ||
      typeof tool.name !== 'string' || tool.name.length > 256 || !['running', 'completed', 'failed'].includes(tool.status) ||
      typeof tool.arguments !== 'string' || tool.arguments.length > 65536 || typeof tool.result !== 'string' || tool.result.length > 16000) {
      throw new Error('会话工具记录无效或超过容量限制，原记录已保留');
    }
  }
  private validateCheckpoint(item: AiTaskCheckpoint): void {
    if (!item || typeof item.id !== 'string' || !/^[A-Za-z0-9_.:-]{1,160}$/.test(item.id) ||
      typeof item.documentIdentity !== 'string' || item.documentIdentity.length > 256 ||
      !Number.isFinite(item.startedAt) || !Number.isFinite(item.updatedAt) ||
      !['running', 'pending', 'applying', 'applied', 'failed', 'cancelled', 'completed'].includes(item.phase) ||
      typeof item.receipt !== 'string' || item.receipt.length > 16000 || !Array.isArray(item.tools) || item.tools.length > 64) {
      throw new Error('任务恢复记录无效，原记录保留');
    }
    this.validateMessage({ role: 'user' as ChatRole, content: item.task?.originalRequest ?? '', task: item.task, timestamp: item.startedAt });
    if (item.task === undefined) throw new Error('任务恢复记录缺少原任务');
    if (item.loadedArtifacts !== undefined && (!Array.isArray(item.loadedArtifacts) || item.loadedArtifacts.length > 4 ||
      item.loadedArtifacts.some((id: string): boolean => typeof id !== 'string' || !/^[a-f0-9]{32}$/.test(id)))) throw new Error('任务产物回执无效');
    for (const tool of item.tools) this.validateTool(tool);
  }
  private validate(state: ConversationSnapshot): void {
    if (!state || state.version !== 1 || !Number.isSafeInteger(state.generation) || state.generation < 0 ||
      !Array.isArray(state.conversations) || state.conversations.length < 1 || state.conversations.length > 64) {
      throw new Error('会话存储无效或超过 64 个会话限制');
    }
    const ids: Set<string> = new Set(); let totalMessages: number = 0;
    if (state.knowledge !== undefined) {
      if (!Array.isArray(state.knowledge) || state.knowledge.length > 128) throw new Error('文档说明最多128份');
      const seen: Set<string> = new Set();
      for (const note of state.knowledge) {
        if (!note || typeof note.documentIdentity !== 'string' || !note.documentIdentity || note.documentIdentity.length > 256 ||
          seen.has(note.documentIdentity) || typeof note.text !== 'string' || note.text.length > 8000 ||
          !Number.isSafeInteger(note.revision) || note.revision < 1) throw new Error('文档说明无效');
        seen.add(note.documentIdentity);
      }
    }
    for (const record of state.conversations) {
      if (!record || typeof record.id !== 'string' || !/^conversation-[a-z0-9-]{1,100}$/.test(record.id) || ids.has(record.id) ||
        typeof record.title !== 'string' || record.title.trim().length === 0 || record.title.length > 80 || typeof record.renamed !== 'boolean' ||
        !Number.isFinite(record.createdAt) || !Number.isFinite(record.updatedAt) || record.createdAt < 0 || record.updatedAt < 0 ||
        !Number.isSafeInteger(record.revision) || record.revision < 0 || !Array.isArray(record.messages) ||
        record.messages.length > 2000) throw new Error('会话无效或已达每会话 2000 条限制');
      ids.add(record.id); this.validateOptions(record.options); totalMessages += record.messages.length;
      for (const message of record.messages) this.validateMessage(message);
      if (record.checkpoint !== undefined) this.validateCheckpoint(record.checkpoint);
      const compression = record.compression;
      if (compression !== undefined && (typeof compression.summary !== 'string' || compression.summary.trim().length === 0 ||
        compression.summary.length > 16000 || !Number.isSafeInteger(compression.sourceMessageCount) || compression.sourceMessageCount < 1 ||
        compression.sourceMessageCount > record.messages.length - 4 || !Number.isFinite(compression.createdAt) || compression.createdAt < 0 ||
        typeof compression.modelName !== 'string' || compression.modelName.length === 0 || compression.modelName.length > 256)) {
        throw new Error('会话压缩摘要无效，原记录已保留');
      }
    }
    if (!ids.has(state.activeId) || totalMessages > 10000) throw new Error('会话记录无效或已达 10000 条消息限制');
  }
  private readSnapshot(value: string): ConversationSnapshot | undefined {
    try {
      if (value.length === 0 || this.byteLength(value) > this.maxBytes) return undefined;
      const parsed = JSON.parse(value) as ConversationSnapshot; this.validate(parsed); return parsed;
    } catch (_) { return undefined; }
  }
  private load(): void {
    try {
      for (const key of this.slots) PersistentStorage.persistProp(key, '');
      PersistentStorage.persistProp(this.commitKey, ''); PersistentStorage.persistProp(this.legacyKey, '');
      const rawA: string = AppStorage.get<string>(this.slots[0]) ?? '';
      const rawB: string = AppStorage.get<string>(this.slots[1]) ?? '';
      const a = this.readSnapshot(rawA);
      const b = this.readSnapshot(rawB);
      let pointer: ConversationCommit | undefined = undefined;
      try { pointer = JSON.parse(AppStorage.get<string>(this.commitKey) ?? '') as ConversationCommit; } catch (_) {}
      if (pointer && (pointer.slot === 0 || pointer.slot === 1)) {
        const committed = pointer.slot === 0 ? a : b;
        if (committed && committed.generation === pointer.generation) { this.state = committed; this.activeSlot = pointer.slot; return; }
      }
      const recovered = a && b ? (a.generation >= b.generation ? a : b) : (a ?? b);
      if (recovered !== undefined) {
        this.state = recovered; this.activeSlot = recovered === a ? 0 : 1;
        this.storageError = '会话存储已从完整备份恢复'; return;
      }
      const legacy: string = AppStorage.get<string>(this.legacyKey) ?? '';
      if (legacy.length === 0 && (rawA.length > 0 || rawB.length > 0)) {
        this.storageError = '会话存储损坏，未找到完整备份；原存储未改动';
      }
      if (legacy.length > 0) {
        if (this.byteLength(legacy) > this.maxBytes) throw new Error('旧聊天记录超过迁移容量，原记录未改动');
        const messages = JSON.parse(legacy) as ChatMessage[];
        if (!Array.isArray(messages)) throw new Error('旧聊天记录格式无效，原记录未改动');
        if (messages.length > 0) {
          const next = this.cloneState(); const record = next.conversations[0];
          record.title = '旧会话'; record.renamed = true; record.messages = this.cloneMessages(messages);
          record.createdAt = messages[0].timestamp; record.updatedAt = messages[messages.length - 1].timestamp;
          // Keep valid legacy content readable/exportable even if the new storage
          // write is refused; never substitute an empty successful migration.
          for (const message of messages) this.validateMessage(message);
          this.state = next;
          this.commit(next);
          if (rawA.length > 0 || rawB.length > 0) this.storageError = '会话存储损坏，已从旧聊天备份恢复；请检查恢复记录';
        }
      }
    } catch (error) { this.storageError = error instanceof Error ? error.message : '会话读取失败，原存储未改动'; }
  }
  private write(key: string, value: string): void {
    AppStorage.setOrCreate<string>(key, value);
    if (AppStorage.get<string>(key) !== value) throw new Error('会话保存失败，请重试');
  }
  private commit(next: ConversationSnapshot): void {
    next.generation = this.state.generation + 1; this.validate(next);
    const serialized: string = JSON.stringify(next);
    if (this.byteLength(serialized) > this.maxBytes) throw new Error('会话总容量已达 16 MiB，请先导出并删除不再需要的会话');
    const slot: number = this.activeSlot === 0 ? 1 : 0;
    const oldSlot: string = AppStorage.get<string>(this.slots[slot]) ?? '';
    const oldPointer: string = AppStorage.get<string>(this.commitKey) ?? '';
    const pointer: ConversationCommit = { slot, generation: next.generation };
    try {
      // Synchronous whole-snapshot writes cannot interleave between conversations.
      // Publish the pointer only after verifying the inactive snapshot's write.
      this.write(this.slots[slot], serialized); this.write(this.commitKey, JSON.stringify(pointer));
    } catch (_) {
      try { this.write(this.commitKey, oldPointer); this.write(this.slots[slot], oldSlot); } catch (_) {}
      this.storageError = '会话保存失败，当前会话与原记录未切换';
      throw new Error('会话保存失败，当前会话与原记录未切换');
    }
    this.state = next; this.activeSlot = slot; this.storageError = '';
  }
}
