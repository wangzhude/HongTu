import { engineeringProjectService } from './EngineeringProjectService';
import { rdbService, rdbCellQName } from './RdbService';
import { engineeringReviewBundleService, engineeringReviewBytes, validateEngineeringViews,
  validateEngineeringReports, validateEngineeringLayoutMappings, engineeringReviewLayoutMappingKey } from './EngineeringReviewBundleService';
import type { EngineeringProjectBundle } from './EngineeringProjectService';
import type { EngineeringReviewBundle, EngineeringDocumentMapping, EngineeringIdentityMapping,
  EngineeringReviewDiagnostic, EngineeringReviewRestorePreview, EngineeringReviewRuntimeState,
  EngineeringReviewRestoreState, EngineeringReviewRuntime, EngineeringReviewStore, EngineeringReviewRestoreOptions } from '../models/EngineeringReviewBundle';
import type { ViewDatabaseSnapshot, ViewPresentation, ViewDocumentState, ViewRecord, ViewBookmark } from '../models/ViewWorkspace';
import type { RdbReviewLayoutMapping } from '../models/RdbReview';
import type { RdbReviewRecovery } from '../models/RdbReview';
import { cloneStructured } from '../common/CloneUtils';

interface PendingRestore {
  preview: EngineeringReviewRestorePreview; candidate: EngineeringReviewRestoreState;
  context: string; lifecycle: string; sources: string; liveState: string; baseline: string | undefined;
}
let sequence: number = 0;
function nextSequence(): number {
  if (!Number.isSafeInteger(sequence) || sequence >= Number.MAX_SAFE_INTEGER) throw new Error('工程恢复令牌耗尽');
  return ++sequence;
}
function copyState(value: EngineeringReviewRuntimeState): EngineeringReviewRuntimeState {
  return cloneStructured(value) as EngineeringReviewRuntimeState;
}
function validateState(value: EngineeringReviewRuntimeState): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some((key: string): boolean => !['views', 'reports', 'layoutMappings'].includes(key))) throw new Error('工程工作区状态字段无效');
  validateEngineeringViews(value.views); validateEngineeringReports(value.reports);
  if (value.layoutMappings !== undefined) validateEngineeringLayoutMappings(value.layoutMappings);
}
function validateMappings(values: EngineeringDocumentMapping[], workspaceId: string, targetWorkspaceId: string): void {
  if (!Array.isArray(values) || values.length < 1 || values.length > 256) throw new Error('工程文档映射预算无效');
  const sources: Set<string> = new Set<string>(), targets: Set<string> = new Set<string>();
  for (const mapping of values) {
    if (mapping === null || typeof mapping !== 'object' || Array.isArray(mapping) || Object.keys(mapping).length !== 2 ||
      typeof mapping.sourceDocumentId !== 'string' || typeof mapping.targetDocumentId !== 'string' ||
      mapping.sourceDocumentId.length < 1 || mapping.sourceDocumentId.length > 512 || mapping.targetDocumentId.length < 1 || mapping.targetDocumentId.length > 512 ||
      /[\x00-\x1f\x7f]/.test(mapping.sourceDocumentId + mapping.targetDocumentId) || sources.has(mapping.sourceDocumentId) || targets.has(mapping.targetDocumentId)) throw new Error('工程映射重复、合并或字段无效');
    sources.add(mapping.sourceDocumentId); targets.add(mapping.targetDocumentId);
  }
  if (!values.some((mapping: EngineeringDocumentMapping): boolean => mapping.sourceDocumentId === workspaceId && mapping.targetDocumentId === targetWorkspaceId)) throw new Error('工程主文档必须显式旧→新映射');
}
function sourceStamp(sources: ViewDatabaseSnapshot[]): string {
  if (!Array.isArray(sources) || sources.length > 256) throw new Error('工程运行来源预算无效');
  const ids: Set<string> = new Set<string>();
  for (const source of sources) {
    if (source === null || typeof source.documentId !== 'string' || ids.has(source.documentId) || !Array.isArray(source.shapes) ||
      !Array.isArray(source.cellKeys) || new Set<string>(source.cellKeys).size !== source.cellKeys.length || !source.cellKeys.includes(source.topCellKey) ||
      !Number.isSafeInteger(source.revision) || source.revision < 0 || typeof source.dirty !== 'boolean' || typeof source.historyToken !== 'string') throw new Error('工程运行来源身份无效');
    ids.add(source.documentId);
  }
  // Bind actual geometry as well as editor/history stamps; no name-only association.
  return JSON.stringify(sources);
}
function locationDiagnostic(source: ViewDatabaseSnapshot, presentation: ViewPresentation): string {
  const location = presentation.location;
  if (location.cellStackKeys[0] !== source.topCellKey) return '根Cell稳定键已改变';
  const indices: number[] = location.cellStackKeys.map((key: string): number => source.cellKeys.indexOf(key));
  if (indices.some((index: number): boolean => index < 0)) return 'Cell稳定键已删除或未载入';
  for (let index: number = 0; index < location.placements.length; index++) {
    const step = location.placements[index];
    const shape = source.shapes.find((item): boolean => item.id === step.instanceId && (item.ownerCellId ?? source.cellKeys.indexOf(source.topCellKey)) === indices[index]);
    if (shape === undefined || shape.type !== 'instance' || shape.cellId !== indices[index + 1] || shape.points.length < 1) return '具体实例已删除或改靶';
    const rows: number = shape.arrayRows === undefined || shape.arrayRows === 0 ? 1 : shape.arrayRows;
    const cols: number = shape.arrayCols === undefined || shape.arrayCols === 0 ? 1 : shape.arrayCols;
    if (!Number.isSafeInteger(rows) || !Number.isSafeInteger(cols) || rows < 1 || cols < 1 || step.row >= rows || step.col >= cols) return '阵列成员已失效';
    if (!Number.isFinite(shape.rotation ?? 0) || !Number.isInteger(shape.mirror ?? 0) || (shape.mirror ?? 0) < 0 || (shape.mirror ?? 0) > 2 ||
      !Number.isFinite(shape.magnification ?? 1) || (shape.magnification ?? 1) <= 0 || !Number.isFinite(shape.points[0].x) || !Number.isFinite(shape.points[0].y) ||
      ![shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0].every((value: number): boolean => Number.isFinite(value))) return '实例变换已失效';
  }
  return '';
}

/** Detached preview -> explicit one-shot confirmation -> one durable CAS -> synchronous live adoption.
 * No external picker URI is opened or written. The root owns tool stores and complete UI rollback.
 */
export class EngineeringReviewRestoreService {
  private store: EngineeringReviewStore;
  private pending: PendingRestore | undefined = undefined;
  private busy: boolean = false;
  private blocked: boolean = false;
  private error: string = '';
  constructor(store: EngineeringReviewStore) { this.store = store; }
  isBusy(): boolean { return this.busy; }
  isBlocked(): boolean { return this.blocked; }
  getError(): string { return this.error; }
  cancel(token: string): boolean {
    if (this.pending?.preview.token !== token) return false;
    this.pending = undefined; return true;
  }
  prepare(input: EngineeringProjectBundle, targetWorkspaceId: string, options: EngineeringReviewRestoreOptions,
    runtime: EngineeringReviewRuntime): EngineeringReviewRestorePreview {
    if (this.busy || this.blocked || !runtime.isIdle()) throw new Error('工程恢复事务忙或回滚未完成');
    // A replacement preview always revokes the previous confirmation, even when validation fails.
    this.pending = undefined;
    const project: EngineeringProjectBundle = engineeringProjectService.validateBundle(input);
    validateMappings(options.mappings, project.workspaceId, targetWorkspaceId);
    if (typeof options.replaceTargetViews !== 'boolean') throw new Error('工程替换视图选项无效');
    const context: string = runtime.contextToken(), lifecycle: string = runtime.lifecycleToken();
    const sources: ViewDatabaseSnapshot[] = runtime.readSources(), sourceBinding: string = sourceStamp(sources);
    const state: EngineeringReviewRuntimeState = copyState(runtime.readState()); validateState(state);
    const liveState: string = JSON.stringify(state), baseline: string | undefined = this.store.read();
    const idSequence: number = nextSequence();
    const preview: EngineeringReviewRestorePreview = { token: `engineering-restore-${idSequence}`, sourceWorkspaceId: project.workspaceId, targetWorkspaceId,
      mappings: cloneStructured(options.mappings) as EngineeringDocumentMapping[], viewIds: [], bookmarkIds: [], reportIds: [],
      diagnostics: [], canRestore: true, viewCount: 0, bookmarkCount: 0, overlayCount: 0, reportCount: 0, dirtyReportCount: 0 };
    const candidate: EngineeringReviewRestoreState = { schema: 'hongtu-engineering-restore/v1', project,
      targetWorkspaceId, tools: engineeringProjectService.restoreTools(project, targetWorkspaceId), state,
      mappings: preview.mappings, viewIds: preview.viewIds, bookmarkIds: preview.bookmarkIds, reportIds: preview.reportIds, reportOrigins: [] };
    const diagnose = (code: string, message: string, sourceDocumentId?: string, cellKey?: string): void => {
      const diagnostic: EngineeringReviewDiagnostic = { code, message };
      if (sourceDocumentId !== undefined) diagnostic.sourceDocumentId = sourceDocumentId;
      if (cellKey !== undefined) diagnostic.cellKey = cellKey;
      preview.diagnostics.push(diagnostic); preview.canRestore = false;
    };
    if (!sources.some((source: ViewDatabaseSnapshot): boolean => source.documentId === targetWorkspaceId)) diagnose('target-missing', '工程目标真实数据库未载入', project.workspaceId);
    const review: EngineeringReviewBundle | null | undefined = project.review;
    const resolve = (oldDocumentId: string, cellKey?: string): ViewDatabaseSnapshot | undefined => {
      const reference = review?.sources.find((source): boolean => source.documentId === oldDocumentId);
      const mapping = preview.mappings.find((item: EngineeringDocumentMapping): boolean => item.sourceDocumentId === oldDocumentId);
      if (reference === undefined) { diagnose('source-reference-missing', '工程缺少此来源引用；未按名称绑定', oldDocumentId, cellKey); return undefined; }
      if (mapping === undefined) { diagnose('source-mapping-missing', '来源需要显式旧→新映射', oldDocumentId, cellKey); return undefined; }
      const source = sources.find((item: ViewDatabaseSnapshot): boolean => item.documentId === mapping.targetDocumentId);
      if (source === undefined) { diagnose('source-missing', '映射目标真实来源未载入', oldDocumentId, cellKey); return undefined; }
      if (reference.topCellKey !== source.topCellKey || JSON.stringify(reference.cellKeys) !== JSON.stringify(source.cellKeys) || (cellKey !== undefined && !source.cellKeys.includes(cellKey))) {
        diagnose('source-cell-mismatch', '来源稳定Cell键或根Cell不一致；未改绑同名对象', oldDocumentId, cellKey); return undefined;
      }
      return source;
    };
    if (review !== undefined && review !== null && review.views !== undefined && review.views !== null) {
      const incoming: ViewDocumentState = cloneStructured(review.views) as ViewDocumentState;
      const source = resolve(review.workspaceId);
      const previousIndex: number = state.views.documents.findIndex((item): boolean => item.documentId === targetWorkspaceId);
      if (previousIndex >= 0 && !options.replaceTargetViews) diagnose('target-views-exist', '目标已有视图；需要显式确认替换目标视图', review.workspaceId);
      const allIds: Set<string> = new Set<string>();
      for (const document of state.views.documents) {
        for (const view of document.views) allIds.add(view.id);
        for (const bookmark of document.bookmarks) allIds.add(bookmark.id);
      }
      const allocate = (kind: string): string => {
        if (!Number.isSafeInteger(state.views.serial) || state.views.serial >= Number.MAX_SAFE_INTEGER) throw new Error('工程视图序号耗尽');
        let id: string;
        do { id = `${kind}-engineering-${idSequence}-${++state.views.serial}`; } while (allIds.has(id) && state.views.serial < Number.MAX_SAFE_INTEGER);
        if (allIds.has(id)) throw new Error('工程视图ID耗尽'); allIds.add(id); return id;
      };
      incoming.documentId = targetWorkspaceId;
      const originalActiveViewId: string = incoming.activeViewId;
      for (const view of incoming.views) {
        const oldId: string = view.id; view.id = allocate('view'); preview.viewIds.push({ sourceId: oldId, targetId: view.id });
        if (source !== undefined) { const error: string = locationDiagnostic(source, view.presentation); if (error !== '') diagnose('view-location-invalid', error, review.workspaceId); }
        for (const overlay of view.overlays) {
          const mapped = resolve(overlay.sourceDocumentId, overlay.cellKey);
          if (mapped !== undefined) overlay.sourceDocumentId = mapped.documentId;
          preview.overlayCount++;
        }
      }
      const activeMapping: EngineeringIdentityMapping | undefined = preview.viewIds.find((mapping: EngineeringIdentityMapping): boolean => mapping.sourceId === originalActiveViewId);
      if (activeMapping === undefined) throw new Error('工程激活视图映射缺失');
      incoming.activeViewId = activeMapping.targetId;
      for (const bookmark of incoming.bookmarks) {
        const oldId: string = bookmark.id; bookmark.id = allocate('bookmark'); preview.bookmarkIds.push({ sourceId: oldId, targetId: bookmark.id });
        if (source !== undefined) { const error: string = locationDiagnostic(source, bookmark.presentation); if (error !== '') diagnose('bookmark-location-invalid', error, review.workspaceId); }
      }
      preview.viewCount = incoming.views.length; preview.bookmarkCount = incoming.bookmarks.length;
      if (previousIndex >= 0) state.views.documents[previousIndex] = incoming;
      else state.views.documents.push(incoming);
    }
    if (review !== undefined && review !== null && review.reports !== undefined && review.reports !== null) {
      for (const report of review.reports.reports) {
        if (!Number.isSafeInteger(state.reports.serial) || state.reports.serial >= Number.MAX_SAFE_INTEGER) throw new Error('工程报告序号耗尽');
        const id: string = `rdb-report-${++state.reports.serial}`;
        state.reports.reports.push({ id, uri: '', recovery: cloneStructured(report.recovery) as RdbReviewRecovery });
        preview.reportIds.push({ sourceId: report.id, targetId: id });
        candidate.reportOrigins.push({ reportId: id, sourceReportId: report.id, uri: report.uri });
        if (report.id === review.reports.activeReportId) state.reports.activeReportId = id;
        preview.reportCount++;
        if (report.recovery.currentXml !== report.recovery.savedXml || report.recovery.pendingExport === true) preview.dirtyReportCount++;
      }
    }
    if (review !== undefined && review !== null && review.layoutMappings !== undefined && review.layoutMappings !== null) {
      if (state.layoutMappings === undefined) state.layoutMappings = [];
      const mappingPositions: Map<string, number> = new Map<string, number>();
      for (let index: number = 0; index < state.layoutMappings.length; index++) mappingPositions.set(engineeringReviewLayoutMappingKey(state.layoutMappings[index]), index);
      for (const mapping of review.layoutMappings) {
        const source = resolve(mapping.layoutDocumentId, mapping.layoutCellKey);
        const boundReports = review.reports?.reports.filter((report): boolean => report.recovery.source.identity === mapping.reportSourceIdentity) ?? [];
        if (boundReports.length === 0) {
          diagnose('report-source-missing', '报告定位绑定的报告来源未携带', mapping.layoutDocumentId, mapping.layoutCellKey); continue;
        }
        if (!boundReports.every((report): boolean => {
          const parsed = rdbService.parse(report.recovery.currentXml);
          return parsed.ok && parsed.document !== undefined && parsed.document.cells.some((cell): boolean => rdbCellQName(cell) === mapping.reportCell);
        })) { diagnose('report-cell-missing', '报告定位的精确Cell/variant已失效；未按同名Cell绑定', mapping.layoutDocumentId, mapping.layoutCellKey); continue; }
        if (source !== undefined) {
          const restored: RdbReviewLayoutMapping = { reportSourceIdentity: mapping.reportSourceIdentity, reportCell: mapping.reportCell,
            layoutDocumentId: source.documentId, layoutRevision: source.revision, layoutCellId: source.cellKeys.indexOf(mapping.layoutCellKey), layoutCellKey: mapping.layoutCellKey };
          const key: string = engineeringReviewLayoutMappingKey(restored);
          const previous: number | undefined = mappingPositions.get(key);
          if (previous !== undefined) {
            if (state.layoutMappings[previous].layoutCellKey !== restored.layoutCellKey) {
              diagnose('report-layout-conflict', '同一报告来源、精确Cell与目标文档已有不同稳定Cell绑定，未重新关联', mapping.layoutDocumentId, mapping.layoutCellKey);
              continue;
            }
            state.layoutMappings[previous] = restored;
          } else {
            mappingPositions.set(key, state.layoutMappings.length); state.layoutMappings.push(restored);
          }
        }
      }
    }
    validateState(state);
    if (engineeringReviewBytes(JSON.stringify(candidate)) > 120 * 1024 * 1024) throw new Error('工程恢复总记录超过120MiB预算');
    if (runtime.contextToken() !== context || runtime.lifecycleToken() !== lifecycle || !runtime.isIdle() || sourceStamp(runtime.readSources()) !== sourceBinding || JSON.stringify(runtime.readState()) !== liveState || this.store.read() !== baseline) throw new Error('工程预览期间上下文或存储已改变');
    this.pending = { preview, candidate, context, lifecycle, sources: sourceBinding, liveState, baseline }; this.error = '';
    return cloneStructured(preview) as EngineeringReviewRestorePreview;
  }
  confirm(token: string, runtime: EngineeringReviewRuntime): boolean {
    if (this.busy || this.blocked || this.pending?.preview.token !== token) throw new Error('工程确认已失效或事务忙');
    const pending: PendingRestore = this.pending;
    if (!pending.preview.canRestore) throw new Error('工程来源或视图诊断尚未解决，未提交');
    const guard = (): void => {
      if (this.pending !== pending || !runtime.isIdle() || runtime.contextToken() !== pending.context || runtime.lifecycleToken() !== pending.lifecycle ||
        sourceStamp(runtime.readSources()) !== pending.sources || JSON.stringify(runtime.readState()) !== pending.liveState) throw new Error('工程恢复取消或上下文已改变');
    };
    try { guard(); } catch (failure) { this.pending = undefined; throw new Error(String(failure)); }
    this.busy = true;
    const encoded: string = JSON.stringify(pending.candidate);
    let checkpoint: Object | undefined = undefined, attempted: boolean = false, published: boolean = false;
    try {
      checkpoint = runtime.capture(); guard();
      if (this.store.read() !== pending.baseline) throw new Error('工程恢复CAS基线已改变');
      attempted = true; this.store.compareAndSwap(pending.baseline, encoded);
      if (this.store.read() !== encoded) throw new Error('工程恢复完整回读不一致');
      guard(); published = true; runtime.publish(JSON.parse(encoded) as EngineeringReviewRestoreState);
      // A publisher must finish the one synchronous adoption before returning.
      if (this.pending !== pending) throw new Error('工程恢复在发布时取消');
      if (!runtime.isIdle() || runtime.lifecycleToken() !== pending.lifecycle || sourceStamp(runtime.readSources()) !== pending.sources ||
        JSON.stringify(runtime.readState()) !== JSON.stringify(pending.candidate.state)) throw new Error('工程恢复发布后上下文或工作区不一致');
      if (this.store.read() !== encoded) throw new Error('工程恢复发布期间存储已改变');
      this.pending = undefined; this.error = ''; return true;
    } catch (failure) {
      let recovery: string = '';
      if (published && checkpoint !== undefined) {
        try {
          runtime.rollback(checkpoint);
          // contextToken also binds root-owned tools/ownership. A silent partial rollback is failure.
          if (JSON.stringify(runtime.readState()) !== pending.liveState || runtime.contextToken() !== pending.context) throw new Error('运行回滚完整核对不一致');
          if (sourceStamp(runtime.readSources()) !== pending.sources) throw new Error('来源回滚完整核对不一致');
          if (runtime.lifecycleToken() !== pending.lifecycle) throw new Error('生命周期回滚完整核对不一致');
        } catch (rollbackFailure) { this.blocked = true; recovery += `；运行状态回滚未完成：${String(rollbackFailure)}`; }
      }
      if (attempted) {
        try {
          const observed: string | undefined = this.store.read();
          if (observed === encoded) this.store.compareAndSwap(encoded, pending.baseline);
          else if (observed !== pending.baseline) { this.blocked = true; recovery += '；检测到第三方存储变化，未覆盖'; }
          if (!this.blocked && this.store.read() !== pending.baseline) throw new Error('恢复回滚完整回读不一致');
        } catch (rollbackFailure) { this.blocked = true; recovery += `；存储回滚未完成：${String(rollbackFailure)}`; }
      }
      this.pending = undefined; this.error = `工程恢复未提交：${String(failure)}${recovery}`; throw new Error(this.error);
    } finally { this.busy = false; }
  }
  /** Validate a committed private record for cold adoption; this never restores tools by itself. */
  readCommitted(): EngineeringReviewRestoreState | undefined {
    const raw: string | undefined = this.store.read(); if (raw === undefined) return undefined;
    if (raw.length > 120 * 1024 * 1024 || engineeringReviewBytes(raw) > 120 * 1024 * 1024) throw new Error('工程恢复记录超过预算');
    const value: EngineeringReviewRestoreState = JSON.parse(raw) as EngineeringReviewRestoreState;
    if (value === null || typeof value !== 'object' || Array.isArray(value) || value.schema !== 'hongtu-engineering-restore/v1' ||
      Object.keys(value).sort().join(',') !== ['schema', 'project', 'targetWorkspaceId', 'tools', 'state', 'mappings', 'viewIds', 'bookmarkIds', 'reportIds', 'reportOrigins'].sort().join(',')) throw new Error('工程恢复记录字段或版本无效');
    value.project = engineeringProjectService.validateBundle(value.project);
    validateMappings(value.mappings, value.project.workspaceId, value.targetWorkspaceId); validateState(value.state);
    if (JSON.stringify(value.tools) !== JSON.stringify(engineeringProjectService.restoreTools(value.project, value.targetWorkspaceId))) throw new Error('工程恢复工具与来源不一致');
    for (const mappings of [value.viewIds, value.bookmarkIds, value.reportIds]) {
      if (!Array.isArray(mappings) || mappings.length > 2048 || new Set<string>(mappings.map((mapping: EngineeringIdentityMapping): string => mapping.targetId)).size !== mappings.length) throw new Error('工程恢复ID映射无效');
      for (const mapping of mappings) if (mapping === null || typeof mapping !== 'object' || Object.keys(mapping).length !== 2 || typeof mapping.sourceId !== 'string' || typeof mapping.targetId !== 'string' || mapping.sourceId.length === 0 || mapping.targetId.length === 0) throw new Error('工程恢复ID映射字段无效');
    }
    if (!Array.isArray(value.reportOrigins) || value.reportOrigins.length !== value.reportIds.length) throw new Error('工程恢复报告来源记录无效');
    for (let index: number = 0; index < value.reportOrigins.length; index++) {
      const origin = value.reportOrigins[index], id = value.reportIds[index];
      if (origin === null || typeof origin !== 'object' || Object.keys(origin).length !== 3 || origin.reportId !== id.targetId || origin.sourceReportId !== id.sourceId ||
        typeof origin.uri !== 'string' || !value.state.reports.reports.some((report): boolean => report.id === origin.reportId && report.uri === '')) throw new Error('工程恢复报告来源或权限字段无效');
    }
    // This is an immutable restore receipt, not a second authority for subsequent ordinary edits.
    // Cross-check every carried field against its validated, checksummed project source.
    const review: EngineeringReviewBundle | null | undefined = value.project.review;
    const carriedViews: ViewDocumentState | null | undefined = review?.views;
    if (carriedViews === undefined || carriedViews === null) {
      if (value.viewIds.length !== 0 || value.bookmarkIds.length !== 0) throw new Error('工程恢复凭空增加视图映射');
    } else {
      const expected: ViewDocumentState = cloneStructured(carriedViews) as ViewDocumentState;
      if (expected.views.length !== value.viewIds.length || expected.bookmarks.length !== value.bookmarkIds.length) throw new Error('工程恢复视图映射数量不一致');
      expected.documentId = value.targetWorkspaceId;
      const originalActiveViewId: string = expected.activeViewId;
      for (let index: number = 0; index < expected.views.length; index++) {
        const view: ViewRecord = expected.views[index], mapping: EngineeringIdentityMapping = value.viewIds[index];
        if (view.id !== mapping.sourceId) throw new Error('工程恢复视图映射来源或顺序不一致');
        view.id = mapping.targetId;
        for (const overlay of view.overlays) {
          const source = value.mappings.find((item: EngineeringDocumentMapping): boolean => item.sourceDocumentId === overlay.sourceDocumentId);
          if (source === undefined) throw new Error('工程恢复叠加来源映射缺失');
          overlay.sourceDocumentId = source.targetDocumentId;
        }
      }
      const activeMapping: EngineeringIdentityMapping | undefined = value.viewIds.find((mapping: EngineeringIdentityMapping): boolean => mapping.sourceId === originalActiveViewId);
      if (activeMapping === undefined) throw new Error('工程恢复激活视图映射缺失');
      expected.activeViewId = activeMapping.targetId;
      for (let index: number = 0; index < expected.bookmarks.length; index++) {
        const bookmark: ViewBookmark = expected.bookmarks[index], mapping: EngineeringIdentityMapping = value.bookmarkIds[index];
        if (bookmark.id !== mapping.sourceId) throw new Error('工程恢复书签映射来源或顺序不一致'); bookmark.id = mapping.targetId;
      }
      const actual = value.state.views.documents.find((document): boolean => document.documentId === value.targetWorkspaceId);
      if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('工程恢复视图或书签与工程来源不一致');
    }
    const carriedReports = review?.reports;
    if (carriedReports === undefined || carriedReports === null) {
      if (value.reportIds.length !== 0) throw new Error('工程恢复凭空增加报告映射');
    } else {
      if (carriedReports.reports.length !== value.reportIds.length) throw new Error('工程恢复报告映射数量不一致');
      const offset: number = value.state.reports.reports.length - value.reportIds.length;
      if (offset < 0) throw new Error('工程恢复报告缺失');
      for (let index: number = 0; index < value.reportIds.length; index++) {
        const source = carriedReports.reports[index], mapping: EngineeringIdentityMapping = value.reportIds[index], actual = value.state.reports.reports[offset + index];
        if (source.id !== mapping.sourceId || actual.id !== mapping.targetId || actual.uri !== '' ||
          JSON.stringify(actual.recovery) !== JSON.stringify(source.recovery) || value.reportOrigins[index].uri !== source.uri) throw new Error('工程恢复报告字段、顺序、脏状态或来源不一致');
        if (source.id === carriedReports.activeReportId && value.state.reports.activeReportId !== mapping.targetId) throw new Error('工程恢复活动报告映射不一致');
      }
    }
    const carriedMappings: RdbReviewLayoutMapping[] | null | undefined = review?.layoutMappings;
    if (carriedMappings !== undefined && carriedMappings !== null) {
      const actualMappings: RdbReviewLayoutMapping[] = value.state.layoutMappings ?? [];
      const actualByKey: Map<string, RdbReviewLayoutMapping> = new Map<string, RdbReviewLayoutMapping>();
      for (const mapping of actualMappings) actualByKey.set(engineeringReviewLayoutMappingKey(mapping), mapping);
      for (const source of carriedMappings) {
        const document = value.mappings.find((mapping: EngineeringDocumentMapping): boolean => mapping.sourceDocumentId === source.layoutDocumentId);
        const reference = review?.sources.find((item): boolean => item.documentId === source.layoutDocumentId);
        if (document === undefined || reference === undefined || !reference.cellKeys.includes(source.layoutCellKey)) throw new Error('工程恢复报告定位来源映射或稳定Cell缺失');
        const key: string = JSON.stringify([source.reportSourceIdentity, source.reportCell, document.targetDocumentId]);
        const actual: RdbReviewLayoutMapping | undefined = actualByKey.get(key);
        if (actual === undefined) throw new Error('工程恢复报告定位映射缺失');
        if (actual.reportSourceIdentity !== source.reportSourceIdentity || actual.reportCell !== source.reportCell || actual.layoutDocumentId !== document.targetDocumentId ||
          actual.layoutCellKey !== source.layoutCellKey || actual.layoutCellId !== reference.cellKeys.indexOf(source.layoutCellKey)) throw new Error('工程恢复报告定位绑定与来源不一致');
        const reports = carriedReports?.reports.filter((report): boolean => report.recovery.source.identity === source.reportSourceIdentity) ?? [];
        if (reports.length === 0 || !reports.every((report): boolean => {
          const parsed = rdbService.parse(report.recovery.currentXml);
          return parsed.ok && parsed.document !== undefined && parsed.document.cells.some((cell): boolean => rdbCellQName(cell) === source.reportCell);
        })) throw new Error('工程恢复报告定位Cell或来源失效');
      }
    }
    return value;
  }
}
