import { rdbService, rdbCellQName, rdbValueDisplay, defaultRdbLimits } from './RdbService';
import type { RdbDocument, RdbItem, RdbCell, RdbTagRef, RdbLimits, RdbFramePath, RdbValue } from '../models/RdbData';
import type { RdbWaiverTagChange } from '../models/RdbWaiver';
import type { RdbReviewSource, RdbReviewFilter, RdbReviewRow, RdbReviewPage, RdbReviewPatch,
  RdbReviewSaveTicket, RdbReviewFrameSelection, RdbReviewLayoutMapping, RdbReviewLocationPlan,
  RdbReviewSnapshot, RdbReviewCounts, RdbReviewStatistics, RdbReviewRecovery } from '../models/RdbReview';
import { cloneStructured } from '../common/CloneUtils';

let reviewInstanceSerial: number = 0;
function copyDocument(value: RdbDocument): RdbDocument { return cloneStructured(value) as RdbDocument; }
function copyFilter(value: RdbReviewFilter): RdbReviewFilter { return cloneStructured(value) as RdbReviewFilter; }
function reportIdentity(value: RdbDocument, limits?: RdbLimits): string {
  const document: RdbDocument = copyDocument(value);
  // Definitions are compared separately: existing definitions stay ordered and exact.
  document.tags = [];
  for (const item of document.items) {
    item.comment = ''; item.visited = false; item.image = '';
    item.tags = item.tags.filter((tag: RdbTagRef): boolean => !tag.user && tag.name !== 'waived' && tag.name !== 'important');
  }
  const encoded = rdbService.serialize(document, limits);
  if (!encoded.ok || encoded.xml === undefined) throw new Error(encoded.message);
  return encoded.xml;
}
function reviewCompatible(baseline: RdbDocument, candidate: RdbDocument, limits?: RdbLimits): void {
  if (reportIdentity(baseline, limits) !== reportIdentity(candidate, limits)) throw new Error('审阅不得改变报告几何、分类、Cell、值或其他原始信息');
  if (candidate.tags.length < baseline.tags.length) throw new Error('审阅不得删除原有标签声明');
  const names: Set<string> = new Set();
  for (let i: number = 0; i < baseline.tags.length; i++) {
    const original = baseline.tags[i], next = candidate.tags[i];
    if (original.name !== next.name || original.description !== next.description) throw new Error('审阅不得重排或更改原有标签声明与描述');
    names.add(original.name);
  }
  const values: Set<string> = new Set(), unknownSystems: Set<string> = new Set();
  const users: Set<string> = new Set(), systems: Set<string> = new Set();
  for (const item of candidate.items) {
    for (const value of item.values) { if (value.tag !== undefined) values.add(value.tag.name); }
    for (const tag of item.tags) {
      if (tag.user) users.add(tag.name);
      else {
        systems.add(tag.name);
        if (tag.name !== 'waived' && tag.name !== 'important') unknownSystems.add(tag.name);
      }
    }
  }
  // Retain evidence of an existing reference even when this edit removes its review flag.
  for (const item of baseline.items) for (const tag of item.tags) {
    if (tag.user) users.add(tag.name); else systems.add(tag.name);
  }
  for (let i: number = baseline.tags.length; i < candidate.tags.length; i++) {
    const name: string = candidate.tags[i].name;
    if (names.has(name)) throw new Error('审阅不得追加同名标签声明');
    if (values.has(name) || unknownSystems.has(name) || (users.has(name) && systems.has(name))) {
      throw new Error('新增审阅标签声明与原有值或系统标签关联冲突');
    }
    // New review vocabulary may remain unused after a later annotation is removed.
    // Standard waived/important declarations are also review metadata. Unknown
    // system references and every value-tag association are immutable above.
    names.add(name);
  }
}
function sourceCopy(value: RdbReviewSource): RdbReviewSource { return { identity: value.identity, name: value.name }; }
function isWaived(item: RdbItem): boolean {
  // KLayout rdb.h Tag::is_user_tag: waived is a system tag; #waived is a distinct user tag.
  return item.tags.some((tag: RdbTagRef): boolean => tag.name === 'waived' && !tag.user);
}
function isImportant(item: RdbItem): boolean {
  return item.tags.some((tag: RdbTagRef): boolean => tag.name === 'important' && !tag.user);
}
function decimalAdd(a: string, b: string): string {
  let result: string = ''; let carry: number = 0;
  for (let i: number = a.length - 1, j: number = b.length - 1; i >= 0 || j >= 0 || carry > 0; i--, j--) {
    const digit: number = (i < 0 ? 0 : Number(a[i])) + (j < 0 ? 0 : Number(b[j])) + carry;
    result = String(digit % 10) + result; carry = Math.floor(digit / 10);
  }
  return result;
}
function counts(items: RdbItem[]): RdbReviewCounts {
  const result: RdbReviewCounts = { items: items.length, visited: 0, waived: 0, important: 0,
    multiplicity: '0', visitedMultiplicity: '0', waivedMultiplicity: '0', importantMultiplicity: '0' };
  for (const item of items) {
    const weight: string = String(item.multiplicity); result.multiplicity = decimalAdd(result.multiplicity, weight);
    if (item.visited) { result.visited++; result.visitedMultiplicity = decimalAdd(result.visitedMultiplicity, weight); }
    if (isWaived(item)) { result.waived++; result.waivedMultiplicity = decimalAdd(result.waivedMultiplicity, weight); }
    if (isImportant(item)) { result.important++; result.importantMultiplicity = decimalAdd(result.importantMultiplicity, weight); }
  }
  return result;
}
function textOrder(a: string, b: string): number { return a < b ? -1 : a > b ? 1 : 0; }
function categoryOrder(a: string[], b: string[]): number {
  for (let i: number = 0; i < Math.min(a.length, b.length); i++) { const order: number = textOrder(a[i], b[i]); if (order !== 0) return order; }
  return a.length - b.length;
}
function objectFields(value: Object, fields: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).some((key: string): boolean => !fields.includes(key))) throw new Error(`${label}字段无效`);
}
function requiredText(value: string, label: string): void {
  if (typeof value !== 'string' || value.length === 0 || value.length > 4096 || /[\x00-\x1f]/.test(value)) throw new Error(`${label}无效`);
}
function whole(value: number, low: number, high: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < low || value > high) throw new Error(`${label}越界`);
}

/** Independent report review. No layout, editor, picker or global storage is imported. */
export class RdbReviewService {
  private readonly instance: number = ++reviewInstanceSerial;
  private readonly limits?: RdbLimits;
  private report: RdbDocument | undefined = undefined;
  private reportSource: RdbReviewSource | undefined = undefined;
  private revision: number = 0;
  private generation: number = 0;
  private currentXml: string = '';
  private savedXml: string = '';
  private pendingExport: boolean | undefined = undefined;
  private filter: RdbReviewFilter = { query: {} };
  private indices: number[] = [];
  private pageIndex: number = 0;
  private pageSize: number = 50;
  private selectedIndex: number = -1;
  private frameTarget: string | undefined = undefined;
  private frame: RdbReviewFrameSelection | undefined = undefined;
  private saveSerial: number = 0;
  private pendingSave: RdbReviewSaveTicket | undefined = undefined;

  constructor(limits?: RdbLimits) {
    this.limits = limits === undefined ? undefined : cloneStructured(limits) as RdbLimits;
  }
  isLoaded(): boolean { return this.report !== undefined; }
  isDirty(): boolean { return this.isLoaded() && (this.currentXml !== this.savedXml || this.pendingExport === true); }
  getRevision(): number { return this.revision; }
  contextToken(): string { return `${this.instance}:${this.generation}:${this.revision}`; }
  source(): RdbReviewSource | undefined { return this.reportSource === undefined ? undefined : sourceCopy(this.reportSource); }
  document(): RdbDocument { return copyDocument(this.requireReport()); }
  serialize(): string { this.requireReport(); return this.currentXml; }

  load(xml: string, source: RdbReviewSource, expectedContext?: string, discardDirty: boolean = false): void {
    this.checkReplacement(source, expectedContext, discardDirty);
    const parsed = rdbService.parse(xml, this.limits);
    if (!parsed.ok || parsed.document === undefined) throw new Error(parsed.message);
    this.replaceDocument(parsed.document, source, expectedContext, discardDirty);
  }
  replaceDocument(document: RdbDocument, source: RdbReviewSource, expectedContext?: string, discardDirty: boolean = false): void {
    this.checkReplacement(source, expectedContext, discardDirty);
    const encoded = rdbService.serialize(document, this.limits);
    if (!encoded.ok || encoded.xml === undefined) throw new Error(encoded.message);
    const candidate: RdbDocument = copyDocument(document);
    const indices: number[] = this.query(candidate, { query: {} });
    this.report = candidate; this.reportSource = sourceCopy(source); this.currentXml = encoded.xml; this.savedXml = encoded.xml;
    this.pendingExport = undefined;
    this.revision++; this.generation++; this.pendingSave = undefined; this.filter = { query: {} };
    this.indices = indices; this.pageIndex = 0; this.selectedIndex = -1; this.frameTarget = undefined; this.frame = undefined;
  }
  /** New DRC/merged output remains unsaved until an issued external-save ticket is acknowledged. */
  loadGenerated(document: RdbDocument, source: RdbReviewSource, expectedContext?: string, discardDirty: boolean = false): void {
    this.replaceDocument(document, source, expectedContext, discardDirty);
    this.pendingExport = true;
  }
  snapshot(): RdbReviewSnapshot {
    const snapshot: RdbReviewSnapshot = { loaded: this.isLoaded(), source: this.source(), revision: this.revision, dirty: this.isDirty(),
      totalItems: this.report?.items.length ?? 0, filter: copyFilter(this.filter), pageIndex: this.pageIndex,
      pageSize: this.pageSize, filteredCount: this.indices.length, selectedIndex: this.selectedIndex,
      frameTarget: this.selectedFrameTarget(), frame: this.selectedFrame() };
    if (this.pendingExport !== undefined) snapshot.pendingExport = this.pendingExport;
    return snapshot;
  }
  exportRecovery(): RdbReviewRecovery {
    this.requireReport();
    const recovery: RdbReviewRecovery = { schemaVersion: 1, source: this.source()!, currentXml: this.currentXml, savedXml: this.savedXml,
      filter: copyFilter(this.filter), pageIndex: this.pageIndex, pageSize: this.pageSize,
      selectedIndex: this.selectedIndex, frameTarget: this.selectedFrameTarget(), frame: this.selectedFrame() };
    if (this.pendingExport !== undefined) recovery.pendingExport = this.pendingExport;
    return recovery;
  }
  restoreRecovery(state: RdbReviewRecovery, expectedContext?: string, discardDirty: boolean = false): void {
    objectFields(state, ['schemaVersion', 'source', 'currentXml', 'savedXml', 'pendingExport', 'filter', 'pageIndex', 'pageSize', 'selectedIndex', 'frameTarget', 'frame'], '报告恢复');
    if (state.schemaVersion !== 1) throw new Error('报告恢复版本不支持');
    if (Object.keys(state).includes('pendingExport') && typeof state.pendingExport !== 'boolean') throw new Error('待导出标志必须为布尔值');
    this.checkReplacement(state.source, expectedContext, discardDirty);
    // A staging session validates every field before the live session is touched.
    const candidate: RdbReviewService = new RdbReviewService(this.limits);
    candidate.load(state.currentXml, state.source);
    const saved = rdbService.parse(state.savedXml, this.limits);
    if (!saved.ok || saved.document === undefined) throw new Error(saved.message);
    const encoded = rdbService.serialize(saved.document, this.limits);
    if (!encoded.ok || encoded.xml === undefined) throw new Error(encoded.message);
    reviewCompatible(saved.document, candidate.requireReport(), this.limits);
    candidate.setQuery(state.filter);
    whole(state.selectedIndex, -1, candidate.requireReport().items.length - 1, '恢复选择');
    if (state.selectedIndex >= 0) candidate.selectItem(state.selectedIndex);
    if (state.frameTarget !== undefined) candidate.selectFrameTarget(state.selectedIndex, state.frameTarget);
    if (state.frame !== undefined) {
      if (state.frame.itemIndex !== state.selectedIndex) throw new Error('恢复 frame 与选中标记不一致');
      if (state.frameTarget !== undefined && state.frame.targetCell !== state.frameTarget) throw new Error('恢复 frame 与所选坐标系不一致');
      candidate.selectFrame(state.frame.itemIndex, state.frame.targetCell, state.frame.pathIndex);
      if (JSON.stringify(candidate.selectedFrame()) !== JSON.stringify(state.frame)) throw new Error('恢复 frame 路径或变换已失效');
    }
    candidate.setPage(state.pageIndex, state.pageSize);
    this.report = candidate.document(); this.reportSource = candidate.source();
    this.currentXml = candidate.serialize(); this.savedXml = encoded.xml;
    this.pendingExport = state.pendingExport;
    this.filter = copyFilter(candidate.filter); this.indices = candidate.indices.slice();
    this.pageIndex = candidate.pageIndex; this.pageSize = candidate.pageSize;
    this.selectedIndex = candidate.selectedIndex; this.frameTarget = candidate.selectedFrameTarget(); this.frame = candidate.selectedFrame();
    this.revision++; this.generation++; this.pendingSave = undefined;
  }
  setQuery(filter: RdbReviewFilter): void {
    const indices: number[] = this.query(this.requireReport(), filter);
    this.filter = copyFilter(filter); this.indices = indices; this.pageIndex = 0;
    if (!indices.includes(this.selectedIndex)) { this.selectedIndex = -1; this.frameTarget = undefined; this.frame = undefined; }
  }
  setPage(pageIndex: number, pageSize: number = 50): void {
    this.requireReport(); whole(pageSize, 1, 100000, '每页条目数');
    const count: number = Math.max(1, Math.ceil(this.indices.length / pageSize));
    whole(pageIndex, 0, count - 1, '页码'); this.pageIndex = pageIndex; this.pageSize = pageSize;
  }
  page(): RdbReviewPage {
    const document: RdbDocument = this.requireReport();
    const start: number = this.pageIndex * this.pageSize;
    return { pageIndex: this.pageIndex, pageSize: this.pageSize, totalItems: document.items.length,
      filteredCount: this.indices.length, pageCount: Math.max(1, Math.ceil(this.indices.length / this.pageSize)),
      rows: this.indices.slice(start, start + this.pageSize).map((index: number): RdbReviewRow => this.row(index)) };
  }
  selectItem(index: number): void {
    this.item(index); const position: number = this.indices.indexOf(index);
    if (position < 0) throw new Error('标记不在当前筛选结果中，请刷新列表');
    this.selectedIndex = index; this.pageIndex = Math.floor(position / this.pageSize); this.frameTarget = undefined; this.frame = undefined;
  }
  selectedItem(): RdbReviewRow | undefined { return this.selectedIndex < 0 ? undefined : this.row(this.selectedIndex); }
  statistics(): RdbReviewStatistics {
    const document: RdbDocument = this.requireReport();
    return { all: counts(document.items), filtered: counts(this.indices.map((index: number): RdbItem => document.items[index])) };
  }
  updateReview(index: number, patch: RdbReviewPatch, expectedContext?: string): void {
    this.checkContext(expectedContext); this.item(index); objectFields(patch, ['comment', 'visited', 'waived', 'important'], '审阅');
    if (patch.comment !== undefined && typeof patch.comment !== 'string') throw new Error('评论必须为字符串');
    if (patch.visited !== undefined && typeof patch.visited !== 'boolean') throw new Error('visited 必须为布尔值');
    if (patch.waived !== undefined && typeof patch.waived !== 'boolean') throw new Error('waived 必须为布尔值');
    if (patch.important !== undefined && typeof patch.important !== 'boolean') throw new Error('important 必须为布尔值');
    const candidate: RdbDocument = copyDocument(this.requireReport()); const item: RdbItem = candidate.items[index];
    if (patch.comment !== undefined) item.comment = patch.comment;
    if (patch.visited !== undefined) item.visited = patch.visited;
    if (patch.waived !== undefined && patch.waived !== isWaived(item)) {
      if (patch.waived) item.tags.push({ name: 'waived', user: false });
      else item.tags = item.tags.filter((tag: RdbTagRef): boolean => tag.name !== 'waived' || tag.user);
    }
    if (patch.important !== undefined && patch.important !== isImportant(item)) {
      if (patch.important) item.tags.push({ name: 'important', user: false });
      else item.tags = item.tags.filter((tag: RdbTagRef): boolean => tag.name !== 'important' || tag.user);
    }
    this.applyReviewDocument(candidate, expectedContext);
  }
  /** Batch-only waiver bridge. Exact before-tags protect user #waived, pre-existing
   * system flags and ordered annotations. All changes validate before publication. */
  applyWaiverChanges(changes: RdbWaiverTagChange[], expectedContext: string): void {
    requiredText(expectedContext, '豁免确认上下文');
    this.checkContext(expectedContext);
    if (!Array.isArray(changes)) throw new Error('豁免变更必须为数组');
    const candidate: RdbDocument = copyDocument(this.requireReport()); const seen: Set<number> = new Set();
    for (const change of changes) {
      objectFields(change, ['index', 'beforeTags', 'afterTags'], '豁免变更'); this.item(change.index);
      if (seen.has(change.index)) throw new Error('豁免变更重复标记'); seen.add(change.index);
      if (!Array.isArray(change.beforeTags) || !Array.isArray(change.afterTags) ||
        JSON.stringify(candidate.items[change.index].tags) !== JSON.stringify(change.beforeTags)) throw new Error('豁免标签所有权已改变');
      const appended: RdbTagRef[] = change.beforeTags.concat([{ name: 'waived', user: false }]);
      const removed: RdbTagRef[] = change.afterTags.concat([{ name: 'waived', user: false }]);
      const add: boolean = !change.beforeTags.some((tag: RdbTagRef): boolean => tag.name === 'waived' && !tag.user) && JSON.stringify(appended) === JSON.stringify(change.afterTags);
      const remove: boolean = !change.afterTags.some((tag: RdbTagRef): boolean => tag.name === 'waived' && !tag.user) && JSON.stringify(removed) === JSON.stringify(change.beforeTags);
      if (!add && !remove) throw new Error('豁免只能追加或移除本次末尾系统标记');
      candidate.items[change.index].tags = cloneStructured(change.afterTags) as RdbTagRef[];
    }
    this.applyReviewDocument(candidate, expectedContext);
  }
  /** Apply only review annotations while retaining this source and saved baseline.
   * Existing tag declarations (including duplicate names from imported files) stay
   * verbatim and ordered. New unique review vocabulary is appended; it cannot
   * rebind a value tag or unknown system tag. This is no layout/document reload. */
  applyReviewDocument(document: RdbDocument, expectedContext?: string): void {
    this.checkContext(expectedContext);
    const original: RdbDocument = this.requireReport();
    const encoded = rdbService.serialize(document, this.limits);
    if (!encoded.ok || encoded.xml === undefined) throw new Error(encoded.message);
    const candidate: RdbDocument = copyDocument(document);
    reviewCompatible(original, candidate, this.limits);
    const saved = rdbService.parse(this.savedXml, this.limits);
    if (!saved.ok || saved.document === undefined) throw new Error(saved.message);
    // Also prove the final draft remains cold-restorable relative to its baseline.
    reviewCompatible(saved.document, candidate, this.limits);
    const indices: number[] = this.query(candidate, this.filter);
    if (encoded.xml === this.currentXml) return;
    whole(this.revision, 0, Number.MAX_SAFE_INTEGER - 1, '报告修订');
    this.report = candidate; this.currentXml = encoded.xml; this.revision++; this.pendingSave = undefined; this.indices = indices;
    this.pageIndex = Math.min(this.pageIndex, Math.max(0, Math.ceil(indices.length / this.pageSize) - 1));
    if (!indices.includes(this.selectedIndex)) { this.selectedIndex = -1; this.frameTarget = undefined; this.frame = undefined; }
  }
  framePaths(index: number, targetCell: string): RdbFramePath[] {
    const result = rdbService.framePaths(this.requireReport(), this.item(index).cell, targetCell, this.limits);
    if (!result.ok) throw new Error(result.message);
    return cloneStructured(result.paths) as RdbFramePath[];
  }
  selectFrameTarget(index: number, targetCell: string, expectedContext?: string): void {
    this.checkContext(expectedContext);
    if (typeof targetCell !== 'string') throw new Error('报告坐标系必须为字符串');
    const paths: RdbFramePath[] = this.framePaths(index, targetCell);
    if (paths.length === 0) throw new Error('所选标记无法到达该报告坐标系');
    this.selectItem(index); this.frameTarget = targetCell;
  }
  selectedFrameTarget(): string | undefined { return this.frameTarget; }
  selectFrame(index: number, targetCell: string, pathIndex: number): void {
    const paths: RdbFramePath[] = this.framePaths(index, targetCell); whole(pathIndex, 0, paths.length - 1, '实例 frame');
    this.selectItem(index); this.frameTarget = targetCell; this.frame = { itemIndex: index, targetCell, pathIndex, path: paths[pathIndex] };
  }
  selectedFrame(): RdbReviewFrameSelection | undefined {
    return this.frame === undefined ? undefined : cloneStructured(this.frame) as RdbReviewFrameSelection;
  }
  matchingCells(layoutCellName: string): RdbCell[] {
    // All candidates are returned: two variants with one layout-name remain ambiguous.
    return this.document().cells.filter((cell: RdbCell): boolean =>
      (cell.layoutName.length > 0 ? cell.layoutName : cell.name) === layoutCellName);
  }
  planLocation(index: number, mapping: RdbReviewLayoutMapping, pathIndex: number): RdbReviewLocationPlan {
    this.validateMapping(mapping); const paths: RdbFramePath[] = this.framePaths(index, mapping.reportCell);
    whole(pathIndex, 0, paths.length - 1, '实例 frame');
    const bounds = rdbService.itemBoundsNm(this.item(index), paths[pathIndex].transform, this.limits);
    if (!bounds.ok) throw new Error(bounds.message);
    return { contextToken: this.contextToken(), itemIndex: index,
      mapping: cloneStructured(mapping) as RdbReviewLayoutMapping, pathIndex, path: paths[pathIndex],
      boundsNm: bounds.boundsNm, labelAnchorOnly: bounds.labelAnchorOnly, conservativePath: bounds.conservativePath };
  }
  isLocationCurrent(plan: RdbReviewLocationPlan, mapping: RdbReviewLayoutMapping): boolean {
    try {
      this.validateMapping(mapping);
      if (plan.contextToken !== this.contextToken() || JSON.stringify(plan.mapping) !== JSON.stringify(mapping)) return false;
      return JSON.stringify(this.planLocation(plan.itemIndex, mapping, plan.pathIndex)) === JSON.stringify(plan);
    } catch (_error) { return false; }
  }
  prepareSave(): RdbReviewSaveTicket {
    this.requireReport(); whole(this.saveSerial, 0, Number.MAX_SAFE_INTEGER - 1, '保存序号');
    const ticket: RdbReviewSaveTicket = { token: `${this.contextToken()}:save:${++this.saveSerial}`,
      revision: this.revision, sourceIdentity: this.reportSource!.identity, xml: this.currentXml };
    this.pendingSave = ticket; return { token: ticket.token, revision: ticket.revision, sourceIdentity: ticket.sourceIdentity, xml: ticket.xml };
  }
  acknowledgeSave(ticket: RdbReviewSaveTicket): boolean {
    if (this.pendingSave === undefined || ticket.token !== this.pendingSave.token || ticket.revision !== this.revision ||
      ticket.sourceIdentity !== this.reportSource?.identity || ticket.xml !== this.currentXml ||
      JSON.stringify(ticket) !== JSON.stringify(this.pendingSave)) return false;
    this.savedXml = ticket.xml; this.pendingExport = undefined; this.pendingSave = undefined; return true;
  }
  private checkContext(expected?: string): void {
    if (expected !== undefined && expected !== this.contextToken()) throw new Error('报告或审阅内容已改变，旧操作未应用');
  }
  private checkReplacement(source: RdbReviewSource, expected: string | undefined, discardDirty: boolean): void {
    this.checkContext(expected); objectFields(source, ['identity', 'name'], '报告来源');
    requiredText(source.identity, '报告来源身份'); requiredText(source.name, '报告名称');
    if (typeof discardDirty !== 'boolean') throw new Error('替换意图必须为布尔值');
    if (this.isDirty() && !discardDirty) throw new Error('当前报告审阅尚未保存，请先保存或明确放弃');
    whole(this.revision, 0, Number.MAX_SAFE_INTEGER - 1, '报告修订');
  }
  private requireReport(): RdbDocument { if (this.report === undefined) throw new Error('尚未打开报告'); return this.report; }
  private item(index: number): RdbItem {
    const document: RdbDocument = this.requireReport(); whole(index, 0, document.items.length - 1, '标记序号'); return document.items[index];
  }
  private row(index: number): RdbReviewRow {
    const item: RdbItem = this.item(index);
    return { index, item: cloneStructured(item) as RdbItem, waived: isWaived(item), important: isImportant(item) };
  }
  private query(document: RdbDocument, filter: RdbReviewFilter): number[] {
    objectFields(filter, ['query', 'waived', 'important', 'categories', 'cells', 'sortBy', 'descending'], '筛选');
    if (filter.waived !== undefined && typeof filter.waived !== 'boolean') throw new Error('waived 筛选必须为布尔值');
    if (filter.important !== undefined && typeof filter.important !== 'boolean') throw new Error('important 筛选必须为布尔值');
    if (filter.descending !== undefined && typeof filter.descending !== 'boolean') throw new Error('排序方向必须为布尔值');
    if (filter.sortBy !== undefined && !['index', 'category', 'cell', 'multiplicity', 'value'].includes(filter.sortBy)) throw new Error('排序字段无效');
    if (filter.categories !== undefined && (!Array.isArray(filter.categories) || filter.categories.some((path: string[]): boolean =>
      !Array.isArray(path) || path.some((name: string): boolean => typeof name !== 'string')))) throw new Error('分类并集无效');
    const cellNames: Set<string> = new Set(document.cells.map((cell: RdbCell): string => rdbCellQName(cell)));
    if (filter.cells !== undefined && (!Array.isArray(filter.cells) || filter.cells.some((cell: string): boolean =>
      typeof cell !== 'string' || !cellNames.has(cell)))) throw new Error('Cell 并集必须使用精确报告 Cell/variant');
    const result = rdbService.queryItems(document, filter.query, this.limits);
    if (!result.ok) throw new Error(result.message);
    // Preflight extended-filter work as well: fail atomically, never return a truncated prefix.
    const categoryWork: number = filter.categories === undefined ? 0 : filter.categories.reduce((sum: number, path: string[]): number => sum + path.length + 1, 0);
    const maximumWork: number = this.limits?.maximumWork ?? defaultRdbLimits().maximumWork;
    if (result.indices.length * categoryWork > maximumWork) throw new Error('分类并集超过工作预算，未发布部分结果');
    const cells: Set<string> | undefined = filter.cells === undefined ? undefined : new Set(filter.cells);
    const indices: number[] = result.indices.filter((index: number): boolean => {
      const item: RdbItem = document.items[index];
      if (filter.waived !== undefined && isWaived(item) !== filter.waived) return false;
      if (filter.important !== undefined && isImportant(item) !== filter.important) return false;
      if (cells !== undefined && !cells.has(item.cell)) return false;
      return filter.categories === undefined || filter.categories.some((path: string[]): boolean =>
        item.category.length >= path.length && (filter.query.includeDescendants !== false || item.category.length === path.length) &&
        path.every((name: string, depth: number): boolean => item.category[depth] === name));
    });
    const valueKeys: Map<number, string> = new Map();
    if (filter.sortBy === 'value') {
      let work: number = 0;
      for (const index of indices) {
        const key: string = document.items[index].values.map((value: RdbValue): string => rdbValueDisplay(value)).join('\n');
        work += key.length; if (work > maximumWork) throw new Error('值排序超过工作预算，未发布部分结果'); valueKeys.set(index, key);
      }
    }
    indices.sort((a: number, b: number): number => {
      const left: RdbItem = document.items[a], right: RdbItem = document.items[b]; let order: number = a - b;
      if (filter.sortBy === 'category') order = categoryOrder(left.category, right.category);
      else if (filter.sortBy === 'cell') order = textOrder(left.cell, right.cell);
      else if (filter.sortBy === 'multiplicity') order = left.multiplicity - right.multiplicity;
      else if (filter.sortBy === 'value') order = textOrder(valueKeys.get(a)!, valueKeys.get(b)!);
      // Equal keys retain original item order in either direction.
      return order === 0 ? a - b : (filter.descending === true ? -order : order);
    });
    return indices;
  }
  private validateMapping(mapping: RdbReviewLayoutMapping): void {
    this.requireReport(); objectFields(mapping, ['reportSourceIdentity', 'reportCell', 'layoutDocumentId', 'layoutRevision', 'layoutCellId', 'layoutCellKey'], '定位映射');
    if (mapping.reportSourceIdentity !== this.reportSource!.identity) throw new Error('报告来源与显式 Cell 映射不匹配');
    requiredText(mapping.layoutDocumentId, '目标布局文档'); requiredText(mapping.layoutCellKey, '目标 Cell 稳定键');
    whole(mapping.layoutRevision, 0, Number.MAX_SAFE_INTEGER, '布局修订'); whole(mapping.layoutCellId, 0, Number.MAX_SAFE_INTEGER, '布局 Cell');
    if (!this.requireReport().cells.some((cell: RdbCell): boolean => rdbCellQName(cell) === mapping.reportCell)) throw new Error('映射必须指定精确报告 Cell/variant');
  }
}
