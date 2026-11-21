import { RdbReviewService } from './RdbReviewService';
import type { RdbLimits } from '../models/RdbData';
import type { RdbReviewRecovery } from '../models/RdbReview';
import type { RdbReviewWorkspaceLimits, RdbReviewWorkspaceRecovery, RdbReviewWorkspaceLegacyRecovery,
  RdbReviewWorkspaceReport, RdbReviewWorkspaceSnapshot, RdbReviewWorkspaceEntry,
  RdbReviewWorkspaceSaveTicket, RdbReviewWorkspaceSourceBinding } from '../models/RdbReviewWorkspace';
import { cloneStructured } from '../common/CloneUtils';

interface WorkspaceRecord {
  id: string; uri: string; session: RdbReviewService; context: string; contentContext: string;
  pendingSave?: RdbReviewWorkspaceSaveTicket;
}
interface WorkspaceBudget { items: number; xmlCharacters: number; serializedBytes: number; }
let tokenSerial: number = 0;
function token(): string {
  if (!Number.isSafeInteger(tokenSerial) || tokenSerial >= Number.MAX_SAFE_INTEGER) throw new Error('报告工作区上下文序号耗尽');
  tokenSerial++; return `rdb-workspace-${tokenSerial}`;
}
function fields(value: Object, allowed: string[], required: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label}结构无效`);
  const keys: string[] = Object.keys(value);
  if (keys.some((key: string): boolean => !allowed.includes(key)) || required.some((key: string): boolean => !keys.includes(key))) {
    throw new Error(`${label}字段无效`);
  }
}
function integer(value: number, low: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < low) throw new Error(`${label}必须为安全整数`);
}
function bytes(text: string): number {
  if (typeof text !== 'string') throw new Error('报告文本必须为字符串');
  let count: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next: number = text.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('报告文本含无配对 Unicode 字符');
      count += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('报告文本含无配对 Unicode 字符');
    else count += code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
  }
  return count;
}
function uriValue(uri: string): void {
  if (typeof uri !== 'string' || uri.length > 4096 || /[\x00-\x1f\x7f]/.test(uri)) throw new Error('报告 URI 无效或超出预算');
  bytes(uri);
  if (uri === '') return;
  if (/^[A-Za-z]:[\\/]/.test(uri) || /^[\\/]/.test(uri)) return;
  if (/^(file|datashare):\/\/.+/i.test(uri)) return;
  throw new Error('报告 URI 必须为已选择的本地文件或本地提供器 URI');
}
function ticketCopy(value: RdbReviewWorkspaceSaveTicket): RdbReviewWorkspaceSaveTicket {
  return { token: value.token, reportId: value.reportId, contentToken: value.contentToken,
    sourceIdentity: value.sourceIdentity, xml: value.xml };
}
export function defaultRdbReviewWorkspaceLimits(): RdbReviewWorkspaceLimits {
  return { maximumReports: 256, maximumXmlCharacters: 64 * 1024 * 1024,
    maximumSerializedBytes: 96 * 1024 * 1024, maximumItems: 1000000 };
}

/** Pure independent multi-report workspace. All returned sessions are detached candidates.
 * The caller persists a fork's exportRecovery with CAS before replacing its live workspace. */
export class RdbReviewWorkspaceService {
  private limits: RdbReviewWorkspaceLimits;
  private reportLimits: RdbLimits | undefined;
  private records: WorkspaceRecord[] = [];
  private active: string = '';
  private serial: number = 0;
  private context: string = token();

  constructor(limits: RdbReviewWorkspaceLimits = defaultRdbReviewWorkspaceLimits(), reportLimits?: RdbLimits) {
    fields(limits, ['maximumReports', 'maximumXmlCharacters', 'maximumSerializedBytes', 'maximumItems'],
      ['maximumReports', 'maximumXmlCharacters', 'maximumSerializedBytes', 'maximumItems'], '工作区预算');
    for (const value of [limits.maximumReports, limits.maximumXmlCharacters, limits.maximumSerializedBytes, limits.maximumItems]) integer(value, 1, '工作区预算');
    this.limits = { maximumReports: limits.maximumReports, maximumXmlCharacters: limits.maximumXmlCharacters,
      maximumSerializedBytes: limits.maximumSerializedBytes, maximumItems: limits.maximumItems };
    this.reportLimits = reportLimits === undefined ? undefined : cloneStructured(reportLimits) as RdbLimits;
  }
  contextToken(): string { return this.context; }
  activeReportId(): string { return this.active; }
  reportContext(id: string): string { return this.record(id).context; }
  /** Stable through filter/page/selection changes; content, reload, recovery and save acknowledgment may invalidate it. */
  reportContentToken(id: string): string { return this.record(id).contentContext; }
  captureSources(ids: string[], expectedWorkspace?: string): RdbReviewWorkspaceSourceBinding[] {
    this.checkWorkspace(expectedWorkspace);
    if (!Array.isArray(ids) || ids.length < 2 || ids.length > this.limits.maximumReports) throw new Error('合并需要至少两份不同的现有报告');
    const seen: Set<string> = new Set();
    return ids.map((id: string): RdbReviewWorkspaceSourceBinding => {
      if (typeof id !== 'string' || seen.has(id)) throw new Error('合并来源 ID 无效或重复');
      seen.add(id); const record: WorkspaceRecord = this.record(id);
      return { reportId: id, sourceIdentity: record.session.source()!.identity, contentToken: record.contentContext };
    });
  }
  session(id: string): RdbReviewService { return this.copySession(this.record(id).session); }
  listReports(): RdbReviewWorkspaceReport[] {
    return this.records.map((record: WorkspaceRecord): RdbReviewWorkspaceReport => ({ id: record.id,
      name: record.session.source()!.name, uri: record.uri, dirty: record.session.isDirty(),
      items: record.session.snapshot().totalItems, source: record.session.source()!, contextToken: record.context }));
  }
  snapshot(): RdbReviewWorkspaceSnapshot {
    const budget: WorkspaceBudget = this.validate(this.records, this.active, this.serial);
    return { contextToken: this.context, activeReportId: this.active, reports: this.listReports(),
      dirtyReports: this.records.filter((record: WorkspaceRecord): boolean => record.session.isDirty()).length,
      items: budget.items, xmlCharacters: budget.xmlCharacters, serializedBytes: budget.serializedBytes };
  }
  exportRecovery(): RdbReviewWorkspaceRecovery { return this.recovery(this.records, this.active, this.serial); }
  fork(): RdbReviewWorkspaceService {
    const result: RdbReviewWorkspaceService = new RdbReviewWorkspaceService(this.limits, this.reportLimits);
    result.records = this.records.map((record: WorkspaceRecord): WorkspaceRecord => this.copyRecord(record));
    result.active = this.active; result.serial = this.serial; result.context = this.context;
    return result;
  }
  addSession(session: RdbReviewService, uri: string, expectedWorkspace?: string, activate: boolean = true): string {
    this.checkWorkspace(expectedWorkspace); uriValue(uri);
    if (typeof activate !== 'boolean') throw new Error('激活标志必须为布尔值');
    integer(this.serial + 1, 1, '报告 ID 序号');
    const id: string = `rdb-report-${this.serial + 1}`;
    const record: WorkspaceRecord = { id, uri, session: this.copySession(session), context: token(), contentContext: token() };
    const records: WorkspaceRecord[] = this.records.concat([record]);
    const active: string = activate || this.active === '' ? id : this.active;
    this.commit(records, active, this.serial + 1); return id;
  }
  /** Append only. The caller has regenerated the exact merge plan and persists this fork with CAS before adoption. */
  addMergedSession(session: RdbReviewService, sources: RdbReviewWorkspaceSourceBinding[],
    expectedWorkspace: string, activate: boolean = true): string {
    if (typeof expectedWorkspace !== 'string' || expectedWorkspace.length === 0) throw new Error('合并需要明确的工作区版本');
    this.checkWorkspace(expectedWorkspace);
    if (!Array.isArray(sources)) throw new Error('合并来源绑定无效');
    const ids: string[] = sources.map((binding: RdbReviewWorkspaceSourceBinding): string => {
      fields(binding, ['reportId', 'sourceIdentity', 'contentToken'], ['reportId', 'sourceIdentity', 'contentToken'], '合并来源绑定');
      return binding.reportId;
    });
    const current: RdbReviewWorkspaceSourceBinding[] = this.captureSources(ids, expectedWorkspace);
    for (let index: number = 0; index < current.length; index++) {
      if (sources[index].sourceIdentity !== current[index].sourceIdentity || sources[index].contentToken !== current[index].contentToken) {
        throw new Error('合并来源内容或身份已改变，请重新生成预览');
      }
    }
    const recovery: RdbReviewRecovery = session.exportRecovery();
    if (recovery.pendingExport !== true) throw new Error('合并输出必须是尚未导出的新报告');
    if (this.records.some((record: WorkspaceRecord): boolean => record.session.source()!.identity === recovery.source.identity)) {
      throw new Error('合并输出必须使用独立的新来源身份');
    }
    return this.addSession(session, '', expectedWorkspace, activate);
  }
  replaceSession(id: string, session: RdbReviewService, uri: string, expectedReport: string): void {
    const previous: WorkspaceRecord = this.checkedReport(id, expectedReport); uriValue(uri);
    const candidate: RdbReviewService = this.copySession(session);
    const before: RdbReviewRecovery = previous.session.exportRecovery(), after: RdbReviewRecovery = candidate.exportRecovery();
    if (before.source.identity !== after.source.identity || before.source.name !== after.source.name || before.savedXml !== after.savedXml || before.pendingExport !== after.pendingExport) {
      throw new Error('普通审阅不能替换报告来源或保存基线，请使用重载或确认保存');
    }
    if (uri === previous.uri && JSON.stringify(before) === JSON.stringify(after)) return;
    const contentChanged: boolean = before.currentXml !== after.currentXml;
    const record: WorkspaceRecord = { id, uri, session: candidate, context: token(),
      contentContext: contentChanged ? token() : previous.contentContext,
      pendingSave: contentChanged || previous.pendingSave === undefined ? undefined : ticketCopy(previous.pendingSave) };
    this.commit(this.replaced(id, record), this.active, this.serial);
  }
  reloadSession(id: string, session: RdbReviewService, uri: string, expectedReport: string, discardDirty: boolean = false): void {
    const previous: WorkspaceRecord = this.checkedReport(id, expectedReport); this.allowDiscard([previous], discardDirty); uriValue(uri);
    const candidate: RdbReviewService = this.copySession(session);
    if (candidate.isDirty()) throw new Error('重载输入必须是已完整读取的原始报告；审阅草稿请使用工作区恢复');
    const record: WorkspaceRecord = { id, uri, session: candidate, context: token(), contentContext: token() };
    this.commit(this.replaced(id, record), this.active, this.serial);
  }
  activate(id: string, expectedWorkspace?: string): void {
    this.checkWorkspace(expectedWorkspace); this.record(id);
    if (this.active !== id) this.commit(this.records, id, this.serial);
  }
  close(id: string, expectedReport: string, discardDirty: boolean = false): void {
    const record: WorkspaceRecord = this.checkedReport(id, expectedReport); this.allowDiscard([record], discardDirty);
    const index: number = this.records.findIndex((value: WorkspaceRecord): boolean => value.id === id);
    const records: WorkspaceRecord[] = this.records.filter((value: WorkspaceRecord): boolean => value.id !== id);
    const active: string = this.active === id ? (records.length === 0 ? '' : records[Math.min(index, records.length - 1)].id) : this.active;
    this.commit(records, active, this.serial);
  }
  prepareSave(id: string): RdbReviewWorkspaceSaveTicket {
    const record: WorkspaceRecord = this.record(id);
    const ticket: RdbReviewWorkspaceSaveTicket = { token: token(), reportId: id, contentToken: record.contentContext,
      sourceIdentity: record.session.source()!.identity, xml: record.session.serialize() };
    record.pendingSave = ticket; return ticketCopy(ticket);
  }
  acknowledgeSave(ticket: RdbReviewWorkspaceSaveTicket, uri: string): boolean {
    if (ticket === null || typeof ticket !== 'object') return false;
    const record: WorkspaceRecord | undefined = this.records.find((value: WorkspaceRecord): boolean => value.id === ticket.reportId);
    if (record === undefined || record.pendingSave === undefined || JSON.stringify(record.pendingSave) !== JSON.stringify(ticket) ||
      record.contentContext !== ticket.contentToken || record.session.source()!.identity !== ticket.sourceIdentity || record.session.serialize() !== ticket.xml) return false;
    uriValue(uri);
    if (uri === '') throw new Error('保存确认必须包含实际外部文件 URI');
    const candidate: RdbReviewService = this.copySession(record.session);
    if (!candidate.acknowledgeSave(candidate.prepareSave())) throw new Error('报告保存基线无法确认');
    const next: WorkspaceRecord = { id: record.id, uri, session: candidate, context: token(), contentContext: token() };
    this.commit(this.replaced(record.id, next), this.active, this.serial); return true;
  }
  restoreRecovery(state: RdbReviewWorkspaceRecovery | RdbReviewWorkspaceLegacyRecovery,
    expectedWorkspace?: string, discardDirty: boolean = false): void {
    this.checkWorkspace(expectedWorkspace); this.allowDiscard(this.records, discardDirty);
    if (state === null || typeof state !== 'object' || Array.isArray(state)) throw new Error('报告工作区恢复结构无效');
    // Reject aggregate payloads before parsing every individual XML document.
    if (bytes(JSON.stringify(state)) > this.limits.maximumSerializedBytes) throw new Error('报告工作区恢复文件超出字节预算，未解析部分报告');
    const records: WorkspaceRecord[] = [];
    let active: string = '', serial: number = 0;
    if (state.schema === 'hongtu-rdb-review/v1') {
      const legacy: RdbReviewWorkspaceLegacyRecovery = state as RdbReviewWorkspaceLegacyRecovery;
      fields(legacy, ['schema', 'uri', 'recovery'], ['schema', 'uri', 'recovery'], '旧报告恢复');
      this.preflightRecoveries([legacy.recovery]);
      uriValue(legacy.uri); const session: RdbReviewService = this.restoredSession(legacy.recovery);
      active = 'rdb-report-1'; serial = 1;
      records.push({ id: active, uri: legacy.uri, session, context: token(), contentContext: token() });
    } else if (state.schema === 'hongtu-rdb-review/v2') {
      const current: RdbReviewWorkspaceRecovery = state as RdbReviewWorkspaceRecovery;
      fields(current, ['schema', 'serial', 'activeReportId', 'reports'], ['schema', 'serial', 'activeReportId', 'reports'], '报告工作区恢复');
      integer(current.serial, 0, '报告 ID 序号');
      if (!Array.isArray(current.reports) || current.reports.length > this.limits.maximumReports) throw new Error('报告数量超出工作区预算');
      if (typeof current.activeReportId !== 'string') throw new Error('活动报告 ID 无效');
      this.preflightRecoveries(current.reports.map((entry: RdbReviewWorkspaceEntry): RdbReviewRecovery => {
        fields(entry, ['id', 'uri', 'recovery'], ['id', 'uri', 'recovery'], '报告恢复条目'); return entry.recovery;
      }));
      serial = current.serial; active = current.activeReportId;
      for (const entry of current.reports) {
        fields(entry, ['id', 'uri', 'recovery'], ['id', 'uri', 'recovery'], '报告恢复条目');
        uriValue(entry.uri);
        records.push({ id: entry.id, uri: entry.uri, session: this.restoredSession(entry.recovery), context: token(), contentContext: token() });
      }
    } else throw new Error('报告工作区恢复版本不支持');
    this.commit(records, active, serial);
  }
  private record(id: string): WorkspaceRecord {
    const record: WorkspaceRecord | undefined = this.records.find((value: WorkspaceRecord): boolean => value.id === id);
    if (record === undefined) throw new Error('报告已关闭或 ID 不存在'); return record;
  }
  private checkedReport(id: string, expected: string): WorkspaceRecord {
    const record: WorkspaceRecord = this.record(id);
    if (expected !== record.context) throw new Error('报告内容或导航已改变，旧操作未应用'); return record;
  }
  private checkWorkspace(expected?: string): void {
    if (expected !== undefined && expected !== this.context) throw new Error('报告工作区已改变，旧操作未应用');
  }
  private allowDiscard(records: WorkspaceRecord[], discard: boolean): void {
    if (typeof discard !== 'boolean') throw new Error('放弃审阅意图必须为布尔值');
    if (!discard && records.some((record: WorkspaceRecord): boolean => record.session.isDirty())) throw new Error('报告仍有未导出审阅，请先保存或明确放弃');
  }
  private restoredSession(recovery: RdbReviewRecovery): RdbReviewService {
    const session: RdbReviewService = new RdbReviewService(this.reportLimits); session.restoreRecovery(recovery); return session;
  }
  private preflightRecoveries(recoveries: RdbReviewRecovery[]): void {
    let characters: number = 0;
    for (const recovery of recoveries) {
      if (recovery === null || typeof recovery !== 'object' || typeof recovery.currentXml !== 'string' || typeof recovery.savedXml !== 'string') {
        throw new Error('报告恢复 XML 结构无效');
      }
      characters += recovery.currentXml.length + recovery.savedXml.length;
      if (!Number.isSafeInteger(characters) || characters > this.limits.maximumXmlCharacters) throw new Error('报告工作区聚合 XML 超出预算，未解析部分报告');
    }
  }
  private copySession(session: RdbReviewService): RdbReviewService { return this.restoredSession(session.exportRecovery()); }
  private copyRecord(record: WorkspaceRecord): WorkspaceRecord {
    return { id: record.id, uri: record.uri, session: this.copySession(record.session), context: record.context,
      contentContext: record.contentContext, pendingSave: record.pendingSave === undefined ? undefined : ticketCopy(record.pendingSave) };
  }
  private replaced(id: string, replacement: WorkspaceRecord): WorkspaceRecord[] {
    return this.records.map((record: WorkspaceRecord): WorkspaceRecord => record.id === id ? replacement : record);
  }
  private recovery(records: WorkspaceRecord[], active: string, serial: number): RdbReviewWorkspaceRecovery {
    return { schema: 'hongtu-rdb-review/v2', serial, activeReportId: active,
      reports: records.map((record: WorkspaceRecord): RdbReviewWorkspaceEntry => ({ id: record.id, uri: record.uri, recovery: record.session.exportRecovery() })) };
  }
  private validate(records: WorkspaceRecord[], active: string, serial: number): WorkspaceBudget {
    integer(serial, 0, '报告 ID 序号');
    if (records.length > this.limits.maximumReports) throw new Error('报告数量超出工作区预算，未发布部分报告');
    const ids: Set<string> = new Set(); let items: number = 0, characters: number = 0;
    for (const record of records) {
      const match: RegExpExecArray | null = typeof record.id === 'string' ? /^rdb-report-([1-9][0-9]*)$/.exec(record.id) : null;
      if (match === null || !Number.isSafeInteger(Number(match[1])) || Number(match[1]) > serial || ids.has(record.id)) throw new Error('报告 ID 重复、越界或无效');
      ids.add(record.id); uriValue(record.uri);
      const recovery: RdbReviewRecovery = record.session.exportRecovery();
      characters += recovery.currentXml.length + recovery.savedXml.length;
      items += record.session.snapshot().totalItems;
      if (!Number.isSafeInteger(characters) || characters > this.limits.maximumXmlCharacters ||
        !Number.isSafeInteger(items) || items > this.limits.maximumItems) throw new Error('报告工作区聚合内容超出预算，未发布部分报告');
    }
    if ((records.length === 0 && active !== '') || (records.length > 0 && !ids.has(active))) throw new Error('活动报告 ID 不属于工作区');
    const serialized: number = bytes(JSON.stringify(this.recovery(records, active, serial)));
    if (serialized > this.limits.maximumSerializedBytes) throw new Error('报告工作区恢复文件超出字节预算，未发布部分报告');
    return { items, xmlCharacters: characters, serializedBytes: serialized };
  }
  private commit(records: WorkspaceRecord[], active: string, serial: number): void {
    this.validate(records, active, serial);
    const context: string = token(); this.records = records; this.active = active; this.serial = serial; this.context = context;
  }
}
