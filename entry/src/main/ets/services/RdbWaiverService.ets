import { parseRdb, serializeRdb, serializeRdbValue, rdbCellQName } from './RdbService';
import { RdbReviewWorkspaceService } from './RdbReviewWorkspaceService';
import type { RdbDocument, RdbItem, RdbCell, RdbCategory, RdbTagRef, RdbValue } from '../models/RdbData';
import type { RdbReviewWorkspaceRecovery, RdbReviewWorkspaceLegacyRecovery } from '../models/RdbReviewWorkspace';
import type { RdbWaiverContext, RdbWaiverRule, RdbWaiverEnvelope, RdbWaiverPortable, RdbWaiverStore,
  RdbWaiverLimits, RdbWaiverLibrarySnapshot, RdbWaiverPreview, RdbWaiverPreviewRow, RdbWaiverApplication,
  RdbWaiverSummary, RdbWaiverCommit, RdbWaiverTagChange, RdbWaiverUiPreview, RdbWaiverRuleRow } from '../models/RdbWaiver';
import { cloneStructured } from '../common/CloneUtils';

let instanceSerial: number = 0;
interface PendingWaiver { preview: RdbWaiverPreview; storeRaw: string | undefined; reportXml: string; workspaceJson: string; }
interface JsonFrame { object: boolean; expectingKey: boolean; names: Set<string>; }
function fail(message: string): never { throw new Error('RDB豁免库：' + message); }
function fields(value: Object, names: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).length !== names.length || Object.keys(value).some((key: string): boolean => !names.includes(key))) fail(label + '字段无效');
}
function integer(value: number, low: number, high: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < low || value > high) fail(label + '越界');
}
function text(value: string, maximum: number, label: string, empty: boolean = false): void {
  if (typeof value !== 'string' || (!empty && value.trim().length === 0) || value.length > maximum || /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.test(value)) fail(label + '无效');
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) { const next: number = value.charCodeAt(++i); if (!(next >= 0xdc00 && next <= 0xdfff)) fail(label + '含无配对Unicode'); }
    else if (code >= 0xdc00 && code <= 0xdfff) fail(label + '含无配对Unicode');
  }
}
/** Reject duplicate (including escaped) field names and excessive nesting before
 * JSON.parse can collapse ambiguity or allocate an unbounded nested structure. */
function safeJson(json: string): Object {
  const stack: JsonFrame[] = []; let nodes: number = 0;
  for (let i: number = 0; i < json.length; i++) {
    const character: string = json[i];
    if (character === '{' || character === '[') {
      stack.push({ object: character === '{', expectingKey: character === '{', names: new Set<string>() });
      nodes++; if (stack.length > 64 || nodes > 1000000) fail('JSON深度/节点预算超限');
    } else if (character === '}' || character === ']') stack.pop();
    else if (character === ',') { if (stack.length > 0 && stack[stack.length - 1].object) stack[stack.length - 1].expectingKey = true; }
    else if (character === '"') {
      const start: number = i++; let closed: boolean = false;
      for (; i < json.length; i++) { if (json[i] === '\\') i++; else if (json[i] === '"') { closed = true; break; } }
      if (!closed) fail('JSON字符串不完整'); nodes++; if (nodes > 1000000) fail('JSON节点预算超限');
      const frame: JsonFrame | undefined = stack.length === 0 ? undefined : stack[stack.length - 1];
      if (frame?.object && frame.expectingKey) {
        const key: string = JSON.parse(json.slice(start, i + 1)) as string;
        if (frame.names.has(key)) fail('JSON有重复字段，拒绝不确定覆盖'); frame.names.add(key); frame.expectingKey = false;
      }
    }
  }
  return JSON.parse(json) as Object;
}
function tagsCopy(tags: RdbTagRef[]): RdbTagRef[] { return tags.map((tag: RdbTagRef): RdbTagRef => ({ name: tag.name, user: tag.user })); }
function waived(item: RdbItem): boolean { return item.tags.some((tag: RdbTagRef): boolean => tag.name === 'waived' && !tag.user); }
function copyEnvelope(value: RdbWaiverEnvelope): RdbWaiverEnvelope { return cloneStructured(value) as RdbWaiverEnvelope; }
function copyContext(value: RdbWaiverContext): RdbWaiverContext { return cloneStructured(value) as RdbWaiverContext; }
function emptyEnvelope(): RdbWaiverEnvelope { return { schema: 'hongtu-rdb-waiver/v1', revision: 0, serial: 0, workspaceJson: '', rules: [], applications: [] }; }
export function defaultRdbWaiverLimits(): RdbWaiverLimits {
  return { maximumRules: 512, maximumApplications: 200000, maximumLibraryCharacters: 32 * 1024 * 1024,
    maximumWork: 10000000, maximumItems: 200000 };
}
class WaiverBudget {
  private work: number = 0;
  private maximum: number;
  constructor(maximum: number) { this.maximum = maximum; }
  spend(count: number = 1): void { this.work += count; if (!Number.isSafeInteger(this.work) || this.work > this.maximum) fail('工作预算超限，没有发布部分匹配'); }
}
function validatedDocument(xml: string): RdbDocument {
  const result = parseRdb(xml); if (!result.ok || result.document === undefined) fail(result.message); return result.document;
}
function encoded(document: RdbDocument): string {
  const result = serializeRdb(document); if (!result.ok || result.xml === undefined) fail(result.message); return result.xml;
}
function valueKey(item: RdbItem, budget: WaiverBudget): string {
  const values: string[] = [];
  for (const value of item.values) {
    budget.spend(); if (value.points !== undefined) budget.spend(value.points.length);
    if (value.holes !== undefined) for (const hole of value.holes) budget.spend(hole.length);
    const result = serializeRdbValue(value); if (!result.ok || result.xml === undefined) fail(result.message);
    budget.spend(result.xml.length); values.push(result.xml);
  }
  return JSON.stringify(values);
}
function categoryKey(document: RdbDocument, item: RdbItem, budget: WaiverBudget): string {
  const path: string[] = []; let categories: RdbCategory[] = document.categories;
  for (const name of item.category) {
    const matches: RdbCategory[] = categories.filter((c: RdbCategory): boolean => { budget.spend(); return c.name === name; });
    if (matches.length !== 1) fail('规则类别存在重复或未知定义');
    path.push(JSON.stringify([matches[0].name, matches[0].description])); categories = matches[0].categories;
  }
  return JSON.stringify(path);
}
/** Exact ordered reachable DAG. Raw name/variant prevent qualified-name collisions. */
function cellKey(document: RdbDocument, item: RdbItem, budget: WaiverBudget): string {
  const seen: Set<string> = new Set(); const visiting: Set<string> = new Set(); const entries: string[] = [];
  const cells: Map<string, RdbCell> = new Map();
  for (const cell of document.cells) { budget.spend(); const name: string = rdbCellQName(cell); if (cells.has(name)) fail('Cell资格名称冲突'); cells.set(name, cell); }
  const visit = (qname: string): void => {
    budget.spend(); if (visiting.has(qname)) fail('Cell引用循环'); if (seen.has(qname)) return;
    const cell: RdbCell | undefined = cells.get(qname); if (cell === undefined) fail('Cell资格悬空');
    visiting.add(qname); const references: string[] = [];
    for (const reference of cell.references) {
      budget.spend(); references.push(JSON.stringify([reference.parentCell, reference.transform.rotationDeg,
        reference.transform.mirror, reference.transform.magnification, reference.transform.x, reference.transform.y])); visit(reference.parentCell);
    }
    visiting.delete(qname); seen.add(qname); entries.push(JSON.stringify([cell.name, cell.variant, cell.layoutName, references]));
  };
  visit(item.cell); entries.sort(); return JSON.stringify([document.topCell, entries]);
}
function markerKey(document: RdbDocument, item: RdbItem, budget: WaiverBudget): string {
  return JSON.stringify([item.cell, categoryKey(document, item, budget), cellKey(document, item, budget), valueKey(item, budget)]);
}
function meaningful(item: RdbItem): boolean {
  // A text/float-only marker has no proven geometric carrier. Empty geometry is uncertain.
  return item.values.some((value: RdbValue): boolean => ['box', 'edge', 'edge-pair', 'polygon', 'path', 'label'].includes(value.kind) &&
    (value.kind === 'label' || (value.points !== undefined && value.points.length > 0)));
}
function contextValidate(value: RdbWaiverContext): RdbWaiverContext {
  fields(value, ['workspaceToken', 'reportId', 'reportContext', 'reportContentToken', 'configurationToken', 'layoutRevision', 'qualification'], '操作上下文');
  for (const s of [value.workspaceToken, value.reportId, value.reportContext, value.reportContentToken, value.configurationToken]) text(s, 4096, '上下文身份');
  integer(value.layoutRevision, 0, Number.MAX_SAFE_INTEGER, '布局修订');
  const q = value.qualification; fields(q, ['layoutIdentity', 'technologyIdentity', 'cells'], '布局资格');
  text(q.layoutIdentity, 1048576, '布局身份', true); text(q.technologyIdentity, 1048576, '规则工艺身份', true);
  if (!Array.isArray(q.cells) || q.cells.length > 200000) fail('Cell资格预算或结构无效');
  const cells: Set<string> = new Set(), stable: Set<string> = new Set();
  for (const cell of q.cells) {
    fields(cell, ['reportCell', 'stableCellKey'], 'Cell资格'); text(cell.reportCell, 4096, '报告Cell'); text(cell.stableCellKey, 4096, '稳定Cell键');
    if (cells.has(cell.reportCell) || stable.has(cell.stableCellKey)) fail('Cell资格映射不唯一'); cells.add(cell.reportCell); stable.add(cell.stableCellKey);
  }
  return copyContext(value);
}
function selectedKey(context: RdbWaiverContext, item: RdbItem): string {
  return context.qualification.cells.find((cell): boolean => cell.reportCell === item.cell)?.stableCellKey ?? '';
}
function validateRule(rule: RdbWaiverRule): RdbDocument {
  fields(rule, ['id', 'name', 'rationale', 'origin', 'layoutIdentity', 'technologyIdentity', 'stableCellKey', 'markerXml'], '规则');
  text(rule.id, 4096, '规则ID'); text(rule.name, 256, '规则名称'); text(rule.rationale, 4096, '豁免依据');
  text(rule.layoutIdentity, 1048576, '稳定布局身份'); text(rule.technologyIdentity, 1048576, '规则工艺身份'); text(rule.stableCellKey, 4096, '稳定Cell键');
  const o = rule.origin; fields(o, ['sourceIdentity', 'sourceName', 'originalFile', 'generator', 'reportContext', 'itemIndex', 'layoutRevision', 'capturedAt'], '来源');
  for (const s of [o.sourceIdentity, o.sourceName, o.reportContext]) text(s, 4096, '来源身份');
  text(o.originalFile, 1048576, '原文件', true); text(o.generator, 1048576, '生成器', true);
  integer(o.itemIndex, 0, Number.MAX_SAFE_INTEGER, '来源序号'); integer(o.layoutRevision, 0, Number.MAX_SAFE_INTEGER, '来源修订');
  if (typeof o.capturedAt !== 'string' || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/.test(o.capturedAt) || !Number.isFinite(Date.parse(o.capturedAt))) fail('捕获时间无效');
  text(rule.markerXml, 32 * 1024 * 1024, '完整标记XML'); const document: RdbDocument = validatedDocument(rule.markerXml);
  if (document.items.length !== 1 || !meaningful(document.items[0])) fail('捕获必须有且仅有一个明确几何标记');
  if (encoded(document) !== rule.markerXml) fail('标记XML必须为规范完整编码');
  markerKey(document, document.items[0], new WaiverBudget(defaultRdbWaiverLimits().maximumWork)); return document;
}
function validateTags(tags: RdbTagRef[]): void {
  if (!Array.isArray(tags)) fail('应用标签无效');
  for (const tag of tags) { fields(tag, ['name', 'user'], '应用标签'); text(tag.name, 4096, '标签名'); if (typeof tag.user !== 'boolean') fail('标签身份无效'); }
}

/** Owns an aggregate private file and issued one-shot previews. Root adopts returned
 * workspace only after confirm() has CAS-published and fully read back this aggregate. */
export class RdbWaiverService {
  private readonly instance: number = ++instanceSerial;
  private epoch: number = 0;
  private previewSerial: number = 0;
  private loaded: boolean = false;
  private raw: string | undefined = undefined;
  private envelope: RdbWaiverEnvelope = emptyEnvelope();
  private pending: PendingWaiver | undefined = undefined;
  private readonly limits: RdbWaiverLimits;
  private readonly store: RdbWaiverStore;
  constructor(store: RdbWaiverStore, limits: RdbWaiverLimits = defaultRdbWaiverLimits()) {
    this.store = store;
    fields(limits, ['maximumRules', 'maximumApplications', 'maximumLibraryCharacters', 'maximumWork', 'maximumItems'], '预算');
    for (const n of [limits.maximumRules, limits.maximumApplications, limits.maximumLibraryCharacters, limits.maximumWork, limits.maximumItems]) integer(n, 1, Number.MAX_SAFE_INTEGER, '预算');
    this.limits = { maximumRules: limits.maximumRules, maximumApplications: limits.maximumApplications,
      maximumLibraryCharacters: limits.maximumLibraryCharacters, maximumWork: limits.maximumWork, maximumItems: limits.maximumItems };
  }
  /** First run migrates legacy report bytes by one aggregate CAS; original file remains. */
  load(legacyWorkspace?: string): void {
    const raw: string | undefined = this.store.read(); const next: RdbWaiverEnvelope = raw === undefined ? emptyEnvelope() : this.parseEnvelope(raw);
    if (raw === undefined && legacyWorkspace !== undefined) {
      this.validateWorkspace(legacyWorkspace); next.workspaceJson = legacyWorkspace;
      const serialized: string = JSON.stringify(next); this.store.compareAndSwap(undefined, serialized);
      if (this.store.read() !== serialized) fail('迁移完整回读失败，未采用新内存');
      this.envelope = next; this.raw = serialized;
    } else { this.envelope = next; this.raw = raw; }
    this.loaded = true; this.epoch++; this.pending = undefined;
  }
  version(): string { this.requireLoaded(); return `waiver-${this.instance}:${this.epoch}:${this.envelope.revision}`; }
  snapshot(): RdbWaiverLibrarySnapshot {
    this.requireLoaded(); return { version: this.version(), revision: this.envelope.revision, ruleLimit: this.limits.maximumRules,
      activeApplications: this.envelope.applications.filter((a: RdbWaiverApplication): boolean => a.active).length,
      abandonedApplications: this.envelope.applications.filter((a: RdbWaiverApplication): boolean => !a.active).length,
      rules: this.envelope.rules.map((rule: RdbWaiverRule): RdbWaiverRuleRow => {
        const document: RdbDocument = validatedDocument(rule.markerXml);
        return { id: rule.id, name: rule.name, rationale: rule.rationale, sourceName: rule.origin.sourceName,
          cell: document.items[0].cell, valueCount: document.items[0].values.length, capturedAt: rule.origin.capturedAt,
          applications: this.envelope.applications.filter((a: RdbWaiverApplication): boolean => a.active && a.ruleId === rule.id).length };
      }) };
  }
  /** Drop-in read/CAS facade for Index's existing report workspace publication. */
  readWorkspace(): string | undefined { this.requireLoaded(); this.checkDisk(); return this.envelope.workspaceJson || undefined; }
  compareAndSwapWorkspace(expected: string | undefined, next: string): void {
    this.requireLoaded(); if ((this.envelope.workspaceJson || undefined) !== expected) fail('工作区基线已改变');
    const newWorkspace: RdbReviewWorkspaceService = this.validateWorkspace(next); const candidate: RdbWaiverEnvelope = copyEnvelope(this.envelope);
    const before = this.envelope.workspaceJson === '' ? undefined : this.validateWorkspace(this.envelope.workspaceJson).exportRecovery();
    const after = newWorkspace.exportRecovery();
    // Manual edits/reload/source changes abandon ownership, even if a flag is later
    // toggled back. A library removal can never erase that later manual decision.
    for (const application of candidate.applications) {
      const a = before?.reports.find((r): boolean => r.id === application.reportId);
      const b = after.reports.find((r): boolean => r.id === application.reportId);
      if (a === undefined || b === undefined || a.recovery.source.identity !== b.recovery.source.identity ||
        a.recovery.currentXml !== b.recovery.currentXml) application.active = false;
    }
    candidate.workspaceJson = next; this.publish(candidate);
  }
  capture(workspace: RdbReviewWorkspaceService, context: RdbWaiverContext, itemIndex: number,
    name: string, rationale: string, expectedVersion: string): string {
    this.checkVersion(expectedVersion); const ctx: RdbWaiverContext = this.checkContext(workspace, context);
    text(name, 256, '规则名称'); text(rationale, 4096, '豁免依据');
    const report = workspace.session(ctx.reportId), document: RdbDocument = report.document();
    integer(itemIndex, 0, document.items.length - 1, '捕获序号'); const item: RdbItem = document.items[itemIndex];
    const stable: string = selectedKey(ctx, item);
    if (ctx.qualification.layoutIdentity.length === 0 || ctx.qualification.technologyIdentity.length === 0 || stable.length === 0) fail('没有明确的稳定布局/工艺/Cell资格，不可凭同名捕获');
    if (!meaningful(item)) fail('文字、标量或空几何载体不能捕获');
    const marker: RdbDocument = document; marker.items = [item];
    const candidate: RdbWaiverEnvelope = copyEnvelope(this.envelope); const id: string = this.nextId(candidate, 'rule');
    const rule: RdbWaiverRule = { id, name, rationale, layoutIdentity: ctx.qualification.layoutIdentity,
      technologyIdentity: ctx.qualification.technologyIdentity, stableCellKey: stable, markerXml: encoded(marker),
      origin: { sourceIdentity: report.source()!.identity, sourceName: report.source()!.name, originalFile: document.originalFile,
        generator: document.generator, reportContext: ctx.reportContext, itemIndex, layoutRevision: ctx.layoutRevision, capturedAt: new Date().toISOString() } };
    const key: string = this.ruleKey(rule);
    if (candidate.rules.some((existing: RdbWaiverRule): boolean => this.ruleKey(existing) === key)) fail('完整规则已存在；未保存重复豁免');
    candidate.rules.push(rule); this.publish(candidate); return id;
  }
  deleteRule(id: string, expectedVersion: string): void {
    this.checkVersion(expectedVersion); if (!this.envelope.rules.some((r: RdbWaiverRule): boolean => r.id === id)) fail('规则不存在');
    const candidate: RdbWaiverEnvelope = copyEnvelope(this.envelope); candidate.rules = candidate.rules.filter((r: RdbWaiverRule): boolean => r.id !== id);
    // Receipts retain independent provenance. Deleting a rule does not unwaive reports.
    this.publish(candidate);
  }
  exportLibrary(expectedVersion: string): string {
    this.checkVersion(expectedVersion); this.checkDisk(); return JSON.stringify({ schema: 'hongtu-rdb-waiver-library/v1', rules: this.envelope.rules } as RdbWaiverPortable, null, 2);
  }
  importLibrary(json: string, expectedVersion: string): number {
    this.checkVersion(expectedVersion); text(json, this.limits.maximumLibraryCharacters, '导入JSON');
    const value = safeJson(json) as RdbWaiverPortable; fields(value, ['schema', 'rules'], '库导入');
    if (value.schema !== 'hongtu-rdb-waiver-library/v1' || !Array.isArray(value.rules) || value.rules.length > this.limits.maximumRules) fail('导入版本或规则预算无效');
    const incoming: Set<string> = new Set(), ids: Set<string> = new Set(); const candidate: RdbWaiverEnvelope = copyEnvelope(this.envelope);
    const existing: Set<string> = new Set(candidate.rules.map((r: RdbWaiverRule): string => this.ruleKey(r))); let count: number = 0;
    for (const rule of value.rules) {
      validateRule(rule); const key: string = this.ruleKey(rule);
      if (ids.has(rule.id) || incoming.has(key)) fail('导入内有重复ID/完整规则，冲突阻断'); ids.add(rule.id); incoming.add(key);
      if (existing.has(key)) {
        const same = candidate.rules.find((r: RdbWaiverRule): boolean => this.ruleKey(r) === key)!;
        if (same.name !== rule.name || same.rationale !== rule.rationale) fail('已存在相同匹配条件但豁免依据不同，冲突阻断');
        continue;
      }
      const copy: RdbWaiverRule = cloneStructured(rule) as RdbWaiverRule; copy.id = this.nextId(candidate, 'rule');
      candidate.rules.push(copy); existing.add(key); count++;
    }
    if (count > 0) this.publish(candidate); return count;
  }
  preview(workspace: RdbReviewWorkspaceService, context: RdbWaiverContext, ruleIds: string[], operation: 'apply' | 'remove', expectedVersion: string): RdbWaiverPreview {
    this.checkVersion(expectedVersion); const ctx: RdbWaiverContext = this.checkContext(workspace, context); this.checkDisk();
    const preview: RdbWaiverPreview = this.plan(workspace, ctx, ruleIds, operation);
    integer(this.previewSerial, 0, Number.MAX_SAFE_INTEGER - 1, '预览序号'); preview.id = `${this.version()}:preview:${++this.previewSerial}`;
    this.pending = { preview: cloneStructured(preview) as RdbWaiverPreview, storeRaw: this.raw,
      reportXml: workspace.session(ctx.reportId).serialize(), workspaceJson: JSON.stringify(workspace.exportRecovery()) };
    return cloneStructured(preview) as RdbWaiverPreview;
  }
  cancel(previewId: string): void { if (this.pending?.preview.id === previewId) this.pending = undefined; }
  previewProjection(pageIndex: number = 0, pageSize: number = 10): RdbWaiverUiPreview | null {
    if (this.pending === undefined) return null;
    integer(pageSize, 1, 100, '预览每页'); const pageCount: number = Math.max(1, Math.ceil(this.pending.preview.rows.length / pageSize));
    integer(pageIndex, 0, pageCount - 1, '预览页码');
    const value: RdbWaiverPreview = this.pending.preview;
    const projection: RdbWaiverUiPreview = { id: value.id, libraryVersion: value.libraryVersion, context: value.context, ruleIds: value.ruleIds,
      operation: value.operation, summary: value.summary,
      rows: value.rows.slice(pageIndex * pageSize, (pageIndex + 1) * pageSize), canApply: value.canApply, message: value.message,
      pageIndex, pageSize, pageCount, totalRows: value.rows.length };
    // Detach only the projected page; confirmation retains every issued engine row.
    return cloneStructured(projection) as RdbWaiverUiPreview;
  }
  /** Consumes confirmation even when stale, refused or readback-failed. Re-preview is required. */
  confirm(previewId: string, workspace: RdbReviewWorkspaceService, context: RdbWaiverContext): RdbWaiverCommit {
    const pending: PendingWaiver | undefined = this.pending;
    if (pending === undefined || pending.preview.id !== previewId) fail('确认已使用或预览不存在');
    this.pending = undefined;
    const ctx: RdbWaiverContext = this.checkContext(workspace, context);
    if (pending.storeRaw !== this.raw || pending.preview.libraryVersion !== this.version() ||
      JSON.stringify(ctx) !== JSON.stringify(pending.preview.context) || workspace.session(ctx.reportId).serialize() !== pending.reportXml ||
      JSON.stringify(workspace.exportRecovery()) !== pending.workspaceJson) fail('来源、库或配置已改变，旧预览拒绝');
    this.checkDisk(); const regenerated: RdbWaiverPreview = this.plan(workspace, ctx, pending.preview.ruleIds, pending.preview.operation);
    regenerated.id = previewId;
    if (JSON.stringify(regenerated) !== JSON.stringify(pending.preview) || !regenerated.canApply) fail('预览不完整、冲突或不确定，未应用');
    const candidate: RdbWaiverEnvelope = copyEnvelope(this.envelope), report = workspace.session(ctx.reportId);
    const document: RdbDocument = report.document(); const changes: RdbWaiverTagChange[] = [];
    for (const row of regenerated.rows) {
      if (row.status === 'match') {
        const item: RdbItem = document.items[row.itemIndex]; const beforeTags: RdbTagRef[] = tagsCopy(item.tags);
        const afterTags: RdbTagRef[] = beforeTags.concat([{ name: 'waived', user: false }]);
        const rule: RdbWaiverRule = candidate.rules.find((r: RdbWaiverRule): boolean => r.id === row.ruleIds[0])!;
        candidate.applications.push({ id: this.nextId(candidate, 'application'), ruleId: rule.id, ruleName: rule.name,
          reportId: ctx.reportId, sourceIdentity: report.source()!.identity, itemIndex: row.itemIndex,
          markerKey: markerKey(document, item, new WaiverBudget(this.limits.maximumWork)), beforeTags, afterTags, active: true });
        changes.push({ index: row.itemIndex, beforeTags, afterTags });
      } else if (row.status === 'remove') {
        const application: RdbWaiverApplication = candidate.applications.find((a: RdbWaiverApplication): boolean => a.active && a.reportId === ctx.reportId && a.itemIndex === row.itemIndex && row.ruleIds.includes(a.ruleId))!;
        changes.push({ index: row.itemIndex, beforeTags: tagsCopy(application.afterTags), afterTags: tagsCopy(application.beforeTags) }); application.active = false;
      }
    }
    report.applyWaiverChanges(changes, report.contextToken()); const nextWorkspace: RdbReviewWorkspaceService = workspace.fork();
    const entry = workspace.listReports().find((r): boolean => r.id === ctx.reportId)!;
    nextWorkspace.replaceSession(ctx.reportId, report, entry.uri, ctx.reportContext);
    const workspaceJson: string = JSON.stringify(nextWorkspace.exportRecovery()); candidate.workspaceJson = workspaceJson;
    this.publish(candidate); return { workspace: nextWorkspace, workspaceJson, summary: regenerated.summary };
  }
  private plan(workspace: RdbReviewWorkspaceService, context: RdbWaiverContext, ids: string[], operation: 'apply' | 'remove'): RdbWaiverPreview {
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > this.limits.maximumRules || new Set(ids).size !== ids.length ||
      ids.some((id: string): boolean => typeof id !== 'string') || !['apply', 'remove'].includes(operation)) fail('选择规则或操作无效');
    const rules: RdbWaiverRule[] = ids.map((id: string): RdbWaiverRule => {
      const rule = this.envelope.rules.find((r: RdbWaiverRule): boolean => r.id === id); if (rule === undefined && operation === 'apply') fail('所选规则已删除');
      return rule!;
    });
    const report = workspace.session(context.reportId), document: RdbDocument = report.document();
    if (document.items.length > this.limits.maximumItems) fail('报告标记预算超限');
    const budget: WaiverBudget = new WaiverBudget(this.limits.maximumWork), rows: RdbWaiverPreviewRow[] = [];
    const summary: RdbWaiverSummary = { items: document.items.length, changed: 0, alreadyWaived: 0, unmatched: 0, uncertain: 0, conflicts: 0 };
    const ruleKeys: string[] = [], ruleLoose: string[] = [], ruleDocs: RdbDocument[] = [];
    if (operation === 'apply') for (const rule of rules) {
      budget.spend(); const d: RdbDocument = validateRule(rule); ruleDocs.push(d);
      ruleKeys.push(markerKey(d, d.items[0], budget)); ruleLoose.push(JSON.stringify([d.items[0].cell, d.items[0].category, valueKey(d.items[0], budget)]));
    }
    const targetKeys: string[] = [], targetLoose: string[] = []; const duplicates: Map<string, number> = new Map();
    for (const item of document.items) {
      budget.spend(); const key: string = markerKey(document, item, budget); targetKeys.push(key); duplicates.set(key, (duplicates.get(key) ?? 0) + 1);
      targetLoose.push(JSON.stringify([item.cell, item.category, valueKey(item, budget)]));
    }
    for (let index: number = 0; index < document.items.length; index++) {
      const item: RdbItem = document.items[index]; const row: RdbWaiverPreviewRow = { itemIndex: index, ruleIds: [], ruleNames: [], status: 'unmatched', reason: '没有完整匹配；未更改' };
      if (operation === 'apply') {
        let qualificationMismatch: boolean = false;
        for (let n: number = 0; n < rules.length; n++) {
          budget.spend(); if (targetLoose[index] !== ruleLoose[n]) continue;
          const rule: RdbWaiverRule = rules[n]; row.ruleIds.push(rule.id); row.ruleNames.push(rule.name);
          if (!meaningful(item) || targetKeys[index] !== ruleKeys[n] || context.qualification.layoutIdentity !== rule.layoutIdentity ||
            context.qualification.technologyIdentity !== rule.technologyIdentity || selectedKey(context, item) !== rule.stableCellKey) qualificationMismatch = true;
        }
        if (row.ruleIds.length > 1) { row.status = 'conflict'; row.reason = '多个所选规则竞争同一完整标记，阻断'; }
        else if (row.ruleIds.length === 1) {
          if (qualificationMismatch || (duplicates.get(targetKeys[index]) ?? 0) > 1) { row.status = 'uncertain'; row.reason = 'Cell/布局/工艺/定义资格变化、未知或目标重复，阻断'; }
          else if (waived(item)) { row.status = 'already-waived'; row.reason = '原本已为系统waived；不取得移除所有权'; }
          else { row.status = 'match'; row.reason = '完整类别、稳定资格、引用和有序typed值相同'; }
        }
      } else {
        const applications: RdbWaiverApplication[] = this.envelope.applications.filter((a: RdbWaiverApplication): boolean => { budget.spend(); return a.reportId === context.reportId && a.itemIndex === index && ids.includes(a.ruleId); });
        const active: RdbWaiverApplication[] = applications.filter((a: RdbWaiverApplication): boolean => a.active);
        for (const a of active) { row.ruleIds.push(a.ruleId); row.ruleNames.push(a.ruleName); }
        if (active.length > 1) { row.status = 'conflict'; row.reason = '多个应用所有权冲突，阻断'; }
        else if (active.length === 1) {
          const a: RdbWaiverApplication = active[0];
          if (a.sourceIdentity !== report.source()!.identity || a.markerKey !== targetKeys[index] ||
            JSON.stringify(a.afterTags) !== JSON.stringify(item.tags)) { row.status = 'uncertain'; row.reason = '应用来源、标记或标签所有权不再确定，阻断'; }
          else { row.status = 'remove'; row.reason = '仅移除本库新增的系统waived，恢复原有标签顺序'; }
        } else if (applications.length > 0) { row.reason = '报告曾在库外改变；旧所有权已放弃，不移除标记'; }
      }
      if (row.status === 'match' || row.status === 'remove') summary.changed++;
      else if (row.status === 'already-waived') summary.alreadyWaived++;
      else if (row.status === 'uncertain') summary.uncertain++;
      else if (row.status === 'conflict') summary.conflicts++;
      else summary.unmatched++;
      rows.push(row);
    }
    const canApply: boolean = summary.changed > 0 && summary.uncertain === 0 && summary.conflicts === 0;
    return { id: '', libraryVersion: this.version(), context: copyContext(context), ruleIds: ids.slice(), operation,
      summary, rows, canApply, message: canApply ? '完整预览已生成；尚未改变报告，请明确确认' : '无变化或有冲突/不确定项；确认阻断' };
  }
  private ruleKey(rule: RdbWaiverRule): string {
    const document: RdbDocument = validateRule(rule);
    return JSON.stringify([rule.layoutIdentity, rule.technologyIdentity, rule.stableCellKey, markerKey(document, document.items[0], new WaiverBudget(this.limits.maximumWork))]);
  }
  private requireLoaded(): void { if (!this.loaded) fail('库尚未读取'); }
  private checkVersion(expected: string): void { this.requireLoaded(); if (expected !== this.version()) fail('库版本已改变'); }
  private checkDisk(): void { if (this.store.read() !== this.raw) fail('私有库已由其他操作改变，请重新读取'); }
  private checkContext(workspace: RdbReviewWorkspaceService, context: RdbWaiverContext): RdbWaiverContext {
    this.requireLoaded(); const ctx: RdbWaiverContext = contextValidate(context);
    if (ctx.workspaceToken !== workspace.contextToken() || ctx.reportContext !== workspace.reportContext(ctx.reportId) ||
      ctx.reportContentToken !== workspace.reportContentToken(ctx.reportId)) fail('工作区或报告来源已改变');
    if (JSON.stringify(workspace.exportRecovery()) !== this.envelope.workspaceJson) fail('内存工作区与持久草稿不一致');
    return ctx;
  }
  private validateWorkspace(json: string): RdbReviewWorkspaceService {
    text(json, 96 * 1024 * 1024, '报告工作区JSON'); const workspace: RdbReviewWorkspaceService = new RdbReviewWorkspaceService();
    workspace.restoreRecovery(safeJson(json) as RdbReviewWorkspaceRecovery | RdbReviewWorkspaceLegacyRecovery); workspace.snapshot(); return workspace;
  }
  private parseEnvelope(json: string): RdbWaiverEnvelope {
    text(json, 128 * 1024 * 1024, '持久聚合JSON'); const value = safeJson(json) as RdbWaiverEnvelope; this.validateEnvelope(value); return copyEnvelope(value);
  }
  private validateEnvelope(value: RdbWaiverEnvelope): void {
    fields(value, ['schema', 'revision', 'serial', 'workspaceJson', 'rules', 'applications'], '持久聚合');
    if (value.schema !== 'hongtu-rdb-waiver/v1') fail('持久版本不支持');
    integer(value.revision, 0, Number.MAX_SAFE_INTEGER, '库修订'); integer(value.serial, 0, Number.MAX_SAFE_INTEGER, '库序号');
    const workspace: RdbReviewWorkspaceService | undefined = value.workspaceJson === '' ? undefined : this.validateWorkspace(value.workspaceJson);
    if (!Array.isArray(value.rules) || !Array.isArray(value.applications) || value.rules.length > this.limits.maximumRules || value.applications.length > this.limits.maximumApplications) fail('规则/应用预算超限');
    if (JSON.stringify([value.rules, value.applications]).length > this.limits.maximumLibraryCharacters) fail('完整库字符预算超限');
    const ids: Set<string> = new Set();
    for (const rule of value.rules) { validateRule(rule); if (ids.has(rule.id)) fail('规则ID冲突'); ids.add(rule.id); }
    const owned: Set<string> = new Set(); const documents: Map<string, RdbDocument> = new Map();
    const budget: WaiverBudget = new WaiverBudget(this.limits.maximumWork);
    for (const a of value.applications) {
      fields(a, ['id', 'ruleId', 'ruleName', 'reportId', 'sourceIdentity', 'itemIndex', 'markerKey', 'beforeTags', 'afterTags', 'active'], '应用记录');
      for (const s of [a.id, a.ruleId, a.reportId, a.sourceIdentity]) text(s, 4096, '应用身份'); text(a.ruleName, 256, '应用名称'); text(a.markerKey, 32 * 1024 * 1024, '完整标记键');
      integer(a.itemIndex, 0, Number.MAX_SAFE_INTEGER, '应用序号'); if (typeof a.active !== 'boolean') fail('应用状态无效');
      validateTags(a.beforeTags); validateTags(a.afterTags);
      if (a.beforeTags.some((t: RdbTagRef): boolean => !t.user && t.name === 'waived') ||
        JSON.stringify(a.afterTags) !== JSON.stringify(a.beforeTags.concat([{ name: 'waived', user: false }]))) fail('应用不得取得原本系统waived的所有权');
      if (ids.has(a.id)) fail('应用ID冲突'); ids.add(a.id);
      if (a.active) {
        const address: string = JSON.stringify([a.reportId, a.itemIndex]); if (owned.has(address)) fail('同一标记有重复移除所有权'); owned.add(address);
        if (workspace === undefined || !workspace.listReports().some((r): boolean => r.id === a.reportId && r.source.identity === a.sourceIdentity)) fail('应用来源与持久工作区不一致');
        if (!documents.has(a.reportId)) documents.set(a.reportId, workspace.session(a.reportId).document());
        const document: RdbDocument = documents.get(a.reportId)!;
        integer(a.itemIndex, 0, document.items.length - 1, '持久应用序号');
        if (markerKey(document, document.items[a.itemIndex], budget) !== a.markerKey ||
          JSON.stringify(document.items[a.itemIndex].tags) !== JSON.stringify(a.afterTags)) fail('应用语义或标签与持久草稿不一致');
      }
    }
  }
  private nextId(candidate: RdbWaiverEnvelope, kind: string): string {
    integer(candidate.serial, 0, Number.MAX_SAFE_INTEGER - 1, '库序号'); candidate.serial++;
    const id: string = `waiver-${kind}-${candidate.serial}`;
    if (candidate.rules.some((r: RdbWaiverRule): boolean => r.id === id) || candidate.applications.some((a: RdbWaiverApplication): boolean => a.id === id)) fail('持久序号与身份冲突'); return id;
  }
  private publish(candidate: RdbWaiverEnvelope): void {
    this.requireLoaded(); this.checkDisk(); integer(this.envelope.revision, 0, Number.MAX_SAFE_INTEGER - 1, '库修订');
    candidate.revision = this.envelope.revision + 1; this.validateEnvelope(candidate); const next: string = JSON.stringify(candidate);
    this.store.compareAndSwap(this.raw, next); if (this.store.read() !== next) fail('完整回读失败，未采用新内存');
    this.envelope = copyEnvelope(candidate); this.raw = next; this.epoch++; this.pending = undefined;
  }
}
