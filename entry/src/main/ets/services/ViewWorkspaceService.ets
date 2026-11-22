import { MIN_ZOOM_PERCENT, MAX_ZOOM_PERCENT } from '../common/constants';
import type { Shape } from '../models/GdsiiData';
import { instanceTransformMat } from './HierarchyExpandService';
import type { Mat2D } from './HierarchyExpandService';
import type { ViewAffine, ViewBookmark, ViewBookmarkFile, ViewCameraState, ViewCanvasCamera,
  ViewDatabaseSnapshot, ViewDatabaseSource, ViewDocumentState, ViewLayerVisibility, ViewLocation,
  ViewOverlayState, ViewPlacementRef, ViewPresentation, ViewRecord, ViewRenderSource, ViewResolvedLocation,
  ViewResolvedPlacement, ViewRuntime, ViewWorkspaceState, ViewWorkspaceStore, ViewRenderResolution, ViewRenderDiagnostic } from '../models/ViewWorkspace';
import { viewWorkspaceStorageService } from './ViewWorkspaceStorageService';
import { isFiniteViewAffine } from './ViewAffineValidationService';
import { cloneStructured } from '../common/CloneUtils';

const VIEW_SCHEMA: string = 'hongtu-view-workspace/v1';
const BOOKMARK_SCHEMA: string = 'hongtu-view-bookmarks/v1';
const VIEW_BYTE_BUDGET: number = 2 * 1024 * 1024;
interface LocatedView { document: ViewDocumentState; view: ViewRecord; }
interface ViewContentStamp { documentId: string; revision: number; dirty: boolean; historyToken: string; cellKeys: string[]; topCellKey: string; }
interface OverlaySourceGuard { documentId: string; shapes: Shape[]; token: string; styles: string; }

function copyPresentation(value: ViewPresentation): ViewPresentation { return cloneStructured(value) as ViewPresentation; }
function identity(): ViewAffine { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }
function copyAffine(value: ViewAffine): ViewAffine {
  return { a: value.a, b: value.b, c: value.c, d: value.d, tx: value.tx, ty: value.ty };
}
function copyLayerVisibility(value: ViewLayerVisibility): ViewLayerVisibility {
  return { layerNumber: value.layerNumber, datatype: value.datatype, visible: value.visible };
}
function compose(left: ViewAffine, right: ViewAffine): ViewAffine {
  return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
    c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx, ty: left.c * right.tx + left.d * right.ty + left.ty };
}
function assertObject(value: Object, allowed: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).some((key: string): boolean => !allowed.includes(key))) throw new Error(`${label}结构或字段无效`);
}
function text(value: string, label: string): void {
  if (typeof value !== 'string' || value.length === 0 || value.length > 512 || /[\x00-\x1f]/.test(value)) throw new Error(`${label}须为1–512字符且不含控制字符`);
}
function name(value: string): string { text(value, '名称'); const result: string = value.trim(); text(result, '名称'); return result; }
function finite(value: number, label: string): void { if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error(`${label}须为有限数`); }
function integer(value: number, low: number, high: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < low || value > high) throw new Error(`${label}越界`);
}
function validateCamera(value: ViewCameraState): void {
  assertObject(value, ['centerXNm', 'centerYNm', 'zoomPercent'], '相机');
  finite(value.centerXNm, '相机X'); finite(value.centerYNm, '相机Y'); finite(value.zoomPercent, '缩放');
  if (value.zoomPercent < MIN_ZOOM_PERCENT || value.zoomPercent > MAX_ZOOM_PERCENT) {
    throw new Error(`缩放须在${MIN_ZOOM_PERCENT}–${MAX_ZOOM_PERCENT}%之间`);
  }
}
function validateLayers(values: ViewLayerVisibility[]): void {
  if (!Array.isArray(values) || values.length > 32768) throw new Error('显示图层预算无效');
  const keys: Set<string> = new Set<string>();
  for (const value of values) {
    assertObject(value, ['layerNumber', 'datatype', 'visible'], '显示图层');
    integer(value.layerNumber, 0, 32767, '层号'); integer(value.datatype, 0, 32767, 'datatype');
    if (typeof value.visible !== 'boolean') throw new Error('显示图层visible须为boolean');
    const key: string = `${value.layerNumber}:${value.datatype}`;
    if (keys.has(key)) throw new Error('显示图层重复'); keys.add(key);
  }
}
function validateLocation(value: ViewLocation): void {
  assertObject(value, ['cellStackKeys', 'placements'], 'Cell定位');
  if (!Array.isArray(value.cellStackKeys) || value.cellStackKeys.length === 0 || value.cellStackKeys.length > 256 ||
    !Array.isArray(value.placements) || value.placements.length > 255) throw new Error('Cell路径预算无效');
  for (const key of value.cellStackKeys) text(key, 'Cell稳定键');
  if (new Set<string>(value.cellStackKeys).size !== value.cellStackKeys.length) throw new Error('Cell路径有循环');
  if (value.placements.length !== 0 && value.placements.length !== value.cellStackKeys.length - 1) throw new Error('具体实例路径与Cell栈不匹配');
  for (let index: number = 0; index < value.placements.length; index++) {
    const step = value.placements[index];
    assertObject(step, ['parentCellKey', 'cellKey', 'instanceId', 'row', 'col'], '实例定位');
    if (step.parentCellKey !== value.cellStackKeys[index] || step.cellKey !== value.cellStackKeys[index + 1]) throw new Error('实例稳定键与Cell栈不匹配');
    integer(step.instanceId, 0, Number.MAX_SAFE_INTEGER, '实例ID');
    integer(step.row, 0, Number.MAX_SAFE_INTEGER, 'AREF行'); integer(step.col, 0, Number.MAX_SAFE_INTEGER, 'AREF列');
  }
}
function validatePresentation(value: ViewPresentation): void {
  assertObject(value, ['camera', 'location', 'hierarchyDepth', 'layerVisibilities'], '视图');
  validateCamera(value.camera); validateLocation(value.location);
  integer(value.hierarchyDepth, 1, 32, '层级深度'); validateLayers(value.layerVisibilities);
}
function validateAffine(value: ViewAffine): void {
  assertObject(value, ['a', 'b', 'c', 'd', 'tx', 'ty'], '视图变换');
  if (!isFiniteViewAffine(value)) throw new Error('视图变换或完整逆变换在数值上不可用');
}
function validateOverlays(values: ViewOverlayState[]): void {
  if (!Array.isArray(values) || values.length > 64) throw new Error('叠加来源超过64项预算');
  const ids: Set<string> = new Set<string>();
  for (const value of values) {
    assertObject(value, ['id', 'sourceDocumentId', 'cellKey', 'visible', 'opacity', 'transform', 'layerVisibilities'], '叠加来源');
    text(value.id, '叠加ID'); text(value.sourceDocumentId, '来源文档'); text(value.cellKey, '来源Cell');
    if (ids.has(value.id)) throw new Error('叠加来源ID重复'); ids.add(value.id);
    if (typeof value.visible !== 'boolean') throw new Error('叠加visible须为boolean');
    finite(value.opacity, '叠加透明度'); if (value.opacity < 0 || value.opacity > 1) throw new Error('叠加透明度须在0–1之间');
    validateAffine(value.transform); validateLayers(value.layerVisibilities);
  }
}
function validateBookmark(value: ViewBookmark): void {
  assertObject(value, ['id', 'name', 'presentation'], '书签'); text(value.id, '书签ID');
  if (name(value.name) !== value.name) throw new Error('书签名称需规范化'); validatePresentation(value.presentation);
}
function validateState(value: ViewWorkspaceState): void {
  assertObject(value, ['schema', 'serial', 'documents'], '视图库');
  if (value.schema !== VIEW_SCHEMA) throw new Error('未知视图库schema，原内容已保留');
  integer(value.serial, 0, Number.MAX_SAFE_INTEGER, '视图库序号');
  if (!Array.isArray(value.documents) || value.documents.length > 256) throw new Error('视图库文档超过256项预算');
  const documentIds: Set<string> = new Set<string>(); const ids: Set<string> = new Set<string>();
  for (const document of value.documents) {
    assertObject(document, ['documentId', 'activeViewId', 'views', 'bookmarks'], '文档视图'); text(document.documentId, '文档ID');
    if (documentIds.has(document.documentId)) throw new Error('视图库文档重复'); documentIds.add(document.documentId);
    if (!Array.isArray(document.views) || document.views.length < 1 || document.views.length > 128 ||
      !Array.isArray(document.bookmarks) || document.bookmarks.length > 2048) throw new Error('视图/书签数量预算无效');
    const viewNames: Set<string> = new Set<string>(); const bookmarkNames: Set<string> = new Set<string>();
    for (const view of document.views) {
      assertObject(view, ['id', 'name', 'presentation', 'overlays'], '视图记录'); text(view.id, '视图ID');
      if (name(view.name) !== view.name || viewNames.has(view.name) || ids.has(view.id)) throw new Error('视图名称或ID重复');
      viewNames.add(view.name); ids.add(view.id); validatePresentation(view.presentation); validateOverlays(view.overlays);
    }
    if (!document.views.some((view: ViewRecord): boolean => view.id === document.activeViewId)) throw new Error('激活视图不存在');
    for (const bookmark of document.bookmarks) {
      validateBookmark(bookmark);
      if (bookmarkNames.has(bookmark.name) || ids.has(bookmark.id)) throw new Error('书签名称或ID重复');
      bookmarkNames.add(bookmark.name); ids.add(bookmark.id);
    }
  }
}
function contentToken(value: ViewDatabaseSnapshot): string {
  const stamp: ViewContentStamp = { documentId: value.documentId, revision: value.revision, dirty: value.dirty,
    historyToken: value.historyToken, cellKeys: value.cellKeys, topCellKey: value.topCellKey }; return JSON.stringify(stamp);
}
function samePresentation(left: ViewPresentation, right: ViewPresentation): boolean {
  validatePresentation(left); validatePresentation(right);
  const near = (a: number, b: number): boolean => Math.abs(a - b) <= Math.max(1e-9, Math.max(Math.abs(a), Math.abs(b)) * Number.EPSILON * 8);
  if (!near(left.camera.centerXNm, right.camera.centerXNm) || !near(left.camera.centerYNm, right.camera.centerYNm) || left.camera.zoomPercent !== right.camera.zoomPercent) return false;
  const canonical = (value: ViewPresentation): ViewPresentation => ({ camera: { centerXNm: 0, centerYNm: 0, zoomPercent: 1 },
    location: { cellStackKeys: value.location.cellStackKeys.slice(), placements: value.location.placements.map((step: ViewPlacementRef): ViewPlacementRef =>
      ({ parentCellKey: step.parentCellKey, cellKey: step.cellKey, instanceId: step.instanceId, row: step.row, col: step.col })) },
    hierarchyDepth: value.hierarchyDepth, layerVisibilities: value.layerVisibilities.map((entry: ViewLayerVisibility): ViewLayerVisibility =>
      ({ layerNumber: entry.layerNumber, datatype: entry.datatype, visible: entry.visible })).sort((a: ViewLayerVisibility, b: ViewLayerVisibility): number => a.layerNumber - b.layerNumber || a.datatype - b.datatype) });
  return JSON.stringify(canonical(left)) === JSON.stringify(canonical(right));
}

/** Separate presentation metadata over a single live source per document. */
export class ViewWorkspaceService {
  private store: ViewWorkspaceStore;
  private state: ViewWorkspaceState = { schema: 'hongtu-view-workspace/v1', serial: 0, documents: [] };
  private baseline: string | undefined = undefined;
  private ready: boolean = false;
  private busy: boolean = false;
  private error: string = '';
  private sources: Map<string, ViewDatabaseSource> = new Map<string, ViewDatabaseSource>();

  constructor(store: ViewWorkspaceStore) { this.store = store; }

  initialize(filesDir?: string): boolean {
    if (this.busy) { this.error = '视图事务进行中，不能重新载入'; return false; }
    try {
      if (filesDir !== undefined) {
        if (this.store.configure === undefined) throw new Error('视图库backend不支持私有目录配置');
        this.store.configure(filesDir);
      }
      const raw: string | undefined = this.store.read();
      if (raw !== undefined && (typeof raw !== 'string' || raw.length > VIEW_BYTE_BUDGET)) throw new Error('视图库输入超过预算');
      const state: ViewWorkspaceState = raw === undefined ? { schema: 'hongtu-view-workspace/v1', serial: 0, documents: [] } : JSON.parse(raw) as ViewWorkspaceState;
      validateState(state); this.state = state; this.baseline = raw; this.ready = true; this.error = ''; return true;
    } catch (failure) { this.ready = false; this.error = `视图库未载入，原文件未改动：${String(failure)}`; return false; }
  }
  isReady(): boolean { return this.ready; }
  getError(): string { return this.error; }

  /** Read the adopted live metadata without consulting a just-written transaction slot. */
  exportRecovery(): ViewWorkspaceState {
    if (!this.ready) throw new Error(this.error || '视图库尚未载入');
    return this.copyState();
  }

  bindDatabase(source: ViewDatabaseSource): void {
    text(source.documentId, '文档ID');
    const previous: ViewDatabaseSource | undefined = this.sources.get(source.documentId);
    if (previous !== undefined && previous !== source) throw new Error('此文档已有真实数据库source，请先明确解绑');
    this.sources.set(source.documentId, source);
    try { this.readSource(source.documentId); } catch (failure) {
      if (previous === undefined) this.sources.delete(source.documentId);
      throw new Error(failure instanceof Error ? failure.message : String(failure));
    }
  }
  unbindDatabase(documentId: string): void { if (this.busy) throw new Error('视图事务进行中，不能解绑数据库'); this.sources.delete(documentId); }

  ensureDocument(documentId: string, presentation: ViewPresentation): ViewRecord {
    if (!this.ready) throw new Error(this.error || '视图库尚未载入');
    this.readSource(documentId);
    const existing: ViewDocumentState | undefined = this.state.documents.find((item: ViewDocumentState): boolean => item.documentId === documentId);
    if (existing !== undefined) return this.getView(existing.activeViewId);
    this.resolveLocation(documentId, presentation.location); validatePresentation(presentation);
    const candidate: ViewWorkspaceState = this.copyState(); const id: string = this.nextId(candidate, 'view');
    const view: ViewRecord = { id, name: '主视图', presentation: copyPresentation(presentation), overlays: [] };
    candidate.documents.push({ documentId, activeViewId: id, views: [view], bookmarks: [] });
    this.publish(candidate); return this.getView(id);
  }
  listViews(documentId: string): ViewRecord[] { return cloneStructured(this.document(documentId).views) as ViewRecord[]; }
  activeViewId(documentId: string): string { return this.document(documentId).activeViewId; }
  getView(viewId: string): ViewRecord { return cloneStructured(this.view(viewId).view) as ViewRecord; }

  /** Capture the live source presentation and clone it in one persistence transaction. */
  cloneView(viewId: string, viewName: string, presentation?: ViewPresentation): ViewRecord {
    const located = this.view(viewId); const normalized: string = name(viewName);
    this.uniqueViewName(located.document, normalized);
    const captured: ViewPresentation = presentation ?? located.view.presentation;
    validatePresentation(captured); this.resolveLocation(located.document.documentId, captured.location);
    const candidate: ViewWorkspaceState = this.copyState(); const document = this.documentIn(candidate, located.document.documentId);
    const clone: ViewRecord = cloneStructured(located.view) as ViewRecord;
    if (presentation !== undefined) {
      document.views.find((item: ViewRecord): boolean => item.id === viewId)!.presentation = copyPresentation(captured);
      clone.presentation = copyPresentation(captured);
    }
    clone.id = this.nextId(candidate, 'view'); clone.name = normalized; document.views.push(clone);
    this.publish(candidate); return this.getView(clone.id);
  }
  renameView(viewId: string, viewName: string): void {
    const located = this.view(viewId); const normalized: string = name(viewName);
    this.uniqueViewName(located.document, normalized, viewId);
    const candidate: ViewWorkspaceState = this.copyState();
    this.documentIn(candidate, located.document.documentId).views.find((item: ViewRecord): boolean => item.id === viewId)!.name = normalized;
    this.publish(candidate);
  }
  closeView(viewId: string, runtime?: ViewRuntime): void {
    const located = this.view(viewId);
    if (located.document.views.length === 1) throw new Error('不能关闭最后一个视图；请使用文档关闭操作');
    if (located.document.activeViewId === viewId) {
      if (runtime === undefined) throw new Error('关闭激活视图需要真实UI runtime以原子切换');
      const next: ViewRecord = located.document.views.find((item: ViewRecord): boolean => item.id !== viewId)!;
      this.activate(next.id, next.presentation, runtime, viewId); return;
    }
    const candidate: ViewWorkspaceState = this.copyState(); const document = this.documentIn(candidate, located.document.documentId);
    document.views = document.views.filter((item: ViewRecord): boolean => item.id !== viewId); this.publish(candidate);
  }
  updateView(viewId: string, presentation: ViewPresentation): void {
    const located = this.view(viewId); validatePresentation(presentation); this.resolveLocation(located.document.documentId, presentation.location);
    const candidate: ViewWorkspaceState = this.copyState();
    this.documentIn(candidate, located.document.documentId).views.find((item: ViewRecord): boolean => item.id === viewId)!.presentation = copyPresentation(presentation);
    this.publish(candidate);
  }

  listBookmarks(documentId: string): ViewBookmark[] { return cloneStructured(this.document(documentId).bookmarks) as ViewBookmark[]; }
  saveBookmark(viewId: string, bookmarkName: string, presentation: ViewPresentation): ViewBookmark {
    const located = this.view(viewId); const normalized: string = name(bookmarkName);
    if (located.document.bookmarks.some((item: ViewBookmark): boolean => item.name === normalized)) throw new Error('书签名称已存在，请显式更新或使用新名称');
    validatePresentation(presentation); this.resolveLocation(located.document.documentId, presentation.location);
    const candidate: ViewWorkspaceState = this.copyState(); const id: string = this.nextId(candidate, 'bookmark');
    this.documentIn(candidate, located.document.documentId).bookmarks.push({ id, name: normalized, presentation: copyPresentation(presentation) });
    this.publish(candidate); return this.listBookmarks(located.document.documentId).find((item: ViewBookmark): boolean => item.id === id)!;
  }
  updateBookmark(documentId: string, bookmarkId: string, presentation: ViewPresentation): void {
    this.bookmark(documentId, bookmarkId); validatePresentation(presentation); this.resolveLocation(documentId, presentation.location);
    const candidate: ViewWorkspaceState = this.copyState();
    this.documentIn(candidate, documentId).bookmarks.find((item: ViewBookmark): boolean => item.id === bookmarkId)!.presentation = copyPresentation(presentation);
    this.publish(candidate);
  }
  renameBookmark(documentId: string, bookmarkId: string, bookmarkName: string): void {
    this.bookmark(documentId, bookmarkId); const normalized: string = name(bookmarkName);
    if (this.document(documentId).bookmarks.some((item: ViewBookmark): boolean => item.id !== bookmarkId && item.name === normalized)) throw new Error('书签名称已存在');
    const candidate: ViewWorkspaceState = this.copyState();
    this.documentIn(candidate, documentId).bookmarks.find((item: ViewBookmark): boolean => item.id === bookmarkId)!.name = normalized; this.publish(candidate);
  }
  deleteBookmark(documentId: string, bookmarkId: string): void {
    this.bookmark(documentId, bookmarkId); const candidate: ViewWorkspaceState = this.copyState();
    const document = this.documentIn(candidate, documentId); document.bookmarks = document.bookmarks.filter((item: ViewBookmark): boolean => item.id !== bookmarkId); this.publish(candidate);
  }
  activateView(viewId: string, runtime: ViewRuntime): void {
    const located = this.view(viewId); this.activate(viewId, located.view.presentation, runtime);
  }
  locateBookmark(viewId: string, bookmarkId: string, runtime: ViewRuntime): void {
    const located = this.view(viewId); this.activate(viewId, this.bookmark(located.document.documentId, bookmarkId).presentation, runtime);
  }
  exportBookmarks(documentId: string): string {
    const result: ViewBookmarkFile = { schema: 'hongtu-view-bookmarks/v1', documentId, bookmarks: this.listBookmarks(documentId) };
    return JSON.stringify(result, null, 2);
  }
  importBookmarks(documentId: string, json: string, replace: boolean): void {
    if (typeof replace !== 'boolean' || typeof json !== 'string' || json.length > VIEW_BYTE_BUDGET) throw new Error('书签导入参数或预算无效');
    const input: ViewBookmarkFile = JSON.parse(json) as ViewBookmarkFile;
    assertObject(input, ['schema', 'documentId', 'bookmarks'], '书签文件');
    if (input.schema !== BOOKMARK_SCHEMA || input.documentId !== documentId || !Array.isArray(input.bookmarks)) throw new Error('书签schema或所属文档不匹配');
    const candidate: ViewWorkspaceState = this.copyState(); const document = this.documentIn(candidate, documentId);
    if (replace) document.bookmarks = [];
    for (const bookmark of input.bookmarks) {
      validateBookmark(bookmark); this.resolveLocation(documentId, bookmark.presentation.location);
      if (document.bookmarks.some((item: ViewBookmark): boolean => item.name === bookmark.name)) throw new Error('导入书签名称冲突');
      document.bookmarks.push({ id: this.nextId(candidate, 'bookmark'), name: bookmark.name, presentation: copyPresentation(bookmark.presentation) });
    }
    this.publish(candidate);
  }

  setOverlays(viewId: string, overlays: ViewOverlayState[]): void {
    const located = this.view(viewId); validateOverlays(overlays);
    const guards: OverlaySourceGuard[] = [];
    for (const overlay of overlays) {
      try {
        const snapshot: ViewDatabaseSnapshot = this.resolveOverlay(overlay).snapshot;
        guards.push({ documentId: snapshot.documentId, shapes: snapshot.shapes, token: contentToken(snapshot), styles: JSON.stringify([snapshot.cellNames, snapshot.layers]) });
      }
      catch (failure) {
        // An unavailable stable reference stays diagnosable and removable. It
        // cannot be rebound by editing its identity while the source is absent.
        const previous: ViewOverlayState | undefined = located.view.overlays.find((item: ViewOverlayState): boolean => item.id === overlay.id);
        if (previous === undefined || previous.sourceDocumentId !== overlay.sourceDocumentId || previous.cellKey !== overlay.cellKey) {
          throw new Error(failure instanceof Error ? failure.message : String(failure));
        }
      }
    }
    const candidate: ViewWorkspaceState = this.copyState();
    this.documentIn(candidate, located.document.documentId).views.find((item: ViewRecord): boolean => item.id === viewId)!.overlays = cloneStructured(overlays) as ViewOverlayState[];
    this.publish(candidate, (): void => {
      for (const guard of guards) {
        const after: ViewDatabaseSnapshot = this.readSource(guard.documentId);
        if (guard.token !== contentToken(after) || guard.shapes !== after.shapes ||
          guard.styles !== JSON.stringify([after.cellNames, after.layers])) throw new Error('叠加来源在提交期间已变化');
      }
    });
  }
  /** Invalid references are omitted with explicit diagnostics, never old pixels. */
  resolveRenderScene(viewId: string, includeBase: boolean = true): ViewRenderResolution {
    const located = this.view(viewId);
    const sources: ViewRenderSource[] = [];
    if (includeBase) {
      const snapshot: ViewDatabaseSnapshot = this.readSource(located.document.documentId);
      const location: ViewResolvedLocation = this.resolveLocation(located.document.documentId, located.view.presentation.location);
      sources.push({ sourceId: `main:${viewId}`, sourceDocumentId: snapshot.documentId,
        cellId: location.cellStack[location.cellStack.length - 1], snapshot, transform: identity(), opacity: 1,
        layerVisibilities: located.view.presentation.layerVisibilities.map((item: ViewLayerVisibility): ViewLayerVisibility => copyLayerVisibility(item)), readOnly: false });
    }
    const diagnostics: ViewRenderDiagnostic[] = [];
    for (const overlay of located.view.overlays) {
      try {
        const source: ViewRenderSource = this.resolveOverlay(overlay);
        if (overlay.visible && overlay.opacity > 0) sources.push(source);
      } catch (failure) { diagnostics.push({ overlayId: overlay.id, message: String(failure) }); }
    }
    return { sources, diagnostics };
  }
  resolveRenderSources(viewId: string): ViewRenderSource[] {
    const located = this.view(viewId); const snapshot: ViewDatabaseSnapshot = this.readSource(located.document.documentId);
    const location: ViewResolvedLocation = this.resolveLocation(located.document.documentId, located.view.presentation.location);
    const result: ViewRenderSource[] = [{ sourceDocumentId: snapshot.documentId, cellId: location.cellStack[location.cellStack.length - 1], snapshot,
      transform: identity(), opacity: 1, layerVisibilities: located.view.presentation.layerVisibilities.map((item: ViewLayerVisibility): ViewLayerVisibility => copyLayerVisibility(item)), readOnly: false }];
    for (const overlay of located.view.overlays) {
      if (!overlay.visible || overlay.opacity === 0) continue;
      result.push(this.resolveOverlay(overlay));
    }
    return result;
  }
  resolveLocation(documentId: string, location: ViewLocation): ViewResolvedLocation {
    validateLocation(location); const snapshot: ViewDatabaseSnapshot = this.readSource(documentId);
    const cellStack: number[] = location.cellStackKeys.map((key: string): number => {
      const index: number = snapshot.cellKeys.indexOf(key); if (index < 0) throw new Error('视图Cell稳定键不存在或已删除'); return index;
    });
    const navigationPath: ViewResolvedPlacement[] = []; let matrix: ViewAffine = identity();
    for (let index: number = 0; index < location.placements.length; index++) {
      const step = location.placements[index]; const parent: number = cellStack[index], target: number = cellStack[index + 1];
      const shape: Shape | undefined = snapshot.shapes.find((item: Shape): boolean => item.id === step.instanceId && (item.ownerCellId ?? snapshot.cellKeys.indexOf(snapshot.topCellKey)) === parent);
      if (shape === undefined || shape.type !== 'instance' || shape.cellId !== target || shape.points.length < 1) throw new Error('视图实例不存在或已改靶');
      if (shape.magnification !== undefined && (!Number.isFinite(shape.magnification) || shape.magnification <= 0)) throw new Error('视图实例MAG无效');
      finite(shape.rotation ?? 0, '视图实例旋转'); integer(shape.mirror ?? 0, 0, 2, '视图实例镜像');
      finite(shape.points[0].x, '视图实例X'); finite(shape.points[0].y, '视图实例Y');
      const rows: number = shape.arrayRows === undefined || shape.arrayRows === 0 ? 1 : shape.arrayRows;
      const cols: number = shape.arrayCols === undefined || shape.arrayCols === 0 ? 1 : shape.arrayCols;
      integer(rows, 1, Number.MAX_SAFE_INTEGER, 'AREF行数'); integer(cols, 1, Number.MAX_SAFE_INTEGER, 'AREF列数');
      if (step.row >= rows || step.col >= cols) throw new Error('视图AREF成员越界');
      const instance: Mat2D = instanceTransformMat(shape);
      const member: ViewAffine = { a: instance.a, b: instance.b, c: instance.c,
        d: instance.d, tx: instance.tx, ty: instance.ty };
      member.tx += step.col * (shape.arrayColStepX ?? 0) + step.row * (shape.arrayRowStepX ?? 0);
      member.ty += step.col * (shape.arrayColStepY ?? 0) + step.row * (shape.arrayRowStepY ?? 0);
      validateAffine(member); matrix = compose(matrix, member); validateAffine(matrix);
      navigationPath.push({ parentCellId: parent, cellId: target, instanceId: step.instanceId, row: step.row, col: step.col, transform: copyAffine(matrix) });
    }
    return { cellStack, navigationPath };
  }

  private activate(viewId: string, presentation: ViewPresentation, runtime: ViewRuntime, closedViewId: string = ''): void {
    const located = this.view(viewId); const documentId: string = located.document.documentId;
    if (runtime.documentId() !== documentId || runtime.viewId() !== located.document.activeViewId || !runtime.isIdle()) throw new Error('文档/激活视图已变化或手势未结束，不能切换视图');
    validatePresentation(presentation); const resolved: ViewResolvedLocation = this.resolveLocation(documentId, presentation.location);
    const beforeSource: ViewDatabaseSnapshot = this.readSource(documentId); const guard: string = contentToken(beforeSource);
    const context: string = runtime.contextToken(), beforeViewId: string = runtime.viewId();
    const beforePresentation: ViewPresentation = copyPresentation(runtime.capturePresentation()); validatePresentation(beforePresentation);
    // Geometry edits may add or remove layers after this view was saved. A view restores the
    // visibility of extant layers, keeps new layers at their live setting and never creates layers.
    const targetPresentation: ViewPresentation = copyPresentation(presentation);
    const savedVisibility: Map<string, boolean> = new Map<string, boolean>();
    for (const layer of presentation.layerVisibilities) savedVisibility.set(`${layer.layerNumber}:${layer.datatype}`, layer.visible);
    targetPresentation.layerVisibilities = beforePresentation.layerVisibilities.map((layer: ViewLayerVisibility): ViewLayerVisibility => {
      return { layerNumber: layer.layerNumber, datatype: layer.datatype,
        visible: savedVisibility.get(`${layer.layerNumber}:${layer.datatype}`) ?? layer.visible };
    });
    const candidate: ViewWorkspaceState = this.copyState(); const document = this.documentIn(candidate, documentId);
    document.views.find((item: ViewRecord): boolean => item.id === beforeViewId)!.presentation = copyPresentation(beforePresentation);
    document.activeViewId = viewId;
    document.views.find((item: ViewRecord): boolean => item.id === viewId)!.presentation = copyPresentation(targetPresentation);
    if (closedViewId.length > 0) document.views = document.views.filter((item: ViewRecord): boolean => item.id !== closedViewId);
    let applied: boolean = false;
    this.publish(candidate, (): void => {
      if (runtime.documentId() !== documentId || runtime.viewId() !== beforeViewId || runtime.contextToken() !== context || !runtime.isIdle() ||
        contentToken(this.readSource(documentId)) !== guard || this.readSource(documentId).shapes !== beforeSource.shapes) throw new Error('发布前文档/数据库/手势已变化');
      applied = true; runtime.applyPresentation(copyPresentation(targetPresentation), resolved, viewId);
      if (runtime.documentId() !== documentId || runtime.viewId() !== viewId || contentToken(this.readSource(documentId)) !== guard ||
        this.readSource(documentId).shapes !== beforeSource.shapes || !samePresentation(runtime.capturePresentation(), targetPresentation)) throw new Error('视图回调改变了数据库/历史或未发布完整目标视图');
    }, (): void => {
      if (!applied) return;
      if (runtime.documentId() !== documentId) throw new Error('文档已切换，未对新文档回放旧视图');
      runtime.rollbackPresentation(copyPresentation(beforePresentation), beforeViewId);
      if (runtime.documentId() !== documentId || runtime.viewId() !== beforeViewId || contentToken(this.readSource(documentId)) !== guard ||
        this.readSource(documentId).shapes !== beforeSource.shapes || !samePresentation(runtime.capturePresentation(), beforePresentation)) throw new Error('视图回滚未恢复原上下文/编辑历史');
    });
  }
  private resolveOverlay(overlay: ViewOverlayState): ViewRenderSource {
    const snapshot: ViewDatabaseSnapshot = this.readSource(overlay.sourceDocumentId); const cellId: number = snapshot.cellKeys.indexOf(overlay.cellKey);
    if (cellId < 0) throw new Error('叠加来源Cell已删除');
    return { sourceId: overlay.id, sourceDocumentId: overlay.sourceDocumentId, cellId, snapshot, transform: copyAffine(overlay.transform), opacity: overlay.opacity,
      layerVisibilities: overlay.layerVisibilities.map((item: ViewLayerVisibility): ViewLayerVisibility => copyLayerVisibility(item)), readOnly: true };
  }
  private readSource(documentId: string): ViewDatabaseSnapshot {
    const source: ViewDatabaseSource | undefined = this.sources.get(documentId); if (source === undefined) throw new Error('真实数据库source未绑定或已关闭');
    const value: ViewDatabaseSnapshot = source.read();
    if (value.documentId !== documentId || !Array.isArray(value.shapes) || !Array.isArray(value.cellKeys) || value.cellKeys.length === 0 ||
      new Set<string>(value.cellKeys).size !== value.cellKeys.length || !value.cellKeys.includes(value.topCellKey) ||
      typeof value.dirty !== 'boolean') throw new Error('真实数据库snapshot身份/内容无效');
    integer(value.revision, 0, Number.MAX_SAFE_INTEGER, '数据库revision'); text(value.historyToken, '编辑历史token');
    for (const key of value.cellKeys) text(key, '数据库Cell稳定键'); return value;
  }
  private document(documentId: string): ViewDocumentState { return this.documentIn(this.state, documentId); }
  private documentIn(state: ViewWorkspaceState, documentId: string): ViewDocumentState {
    const document: ViewDocumentState | undefined = state.documents.find((item: ViewDocumentState): boolean => item.documentId === documentId);
    if (document === undefined) throw new Error('此文档尚无视图记录'); return document;
  }
  private view(viewId: string): LocatedView {
    for (const document of this.state.documents) {
      const view: ViewRecord | undefined = document.views.find((item: ViewRecord): boolean => item.id === viewId);
      if (view !== undefined) return { document, view };
    }
    throw new Error('视图不存在或已关闭');
  }
  private bookmark(documentId: string, bookmarkId: string): ViewBookmark {
    const bookmark: ViewBookmark | undefined = this.document(documentId).bookmarks.find((item: ViewBookmark): boolean => item.id === bookmarkId);
    if (bookmark === undefined) throw new Error('书签不存在或已删除'); return bookmark;
  }
  private uniqueViewName(document: ViewDocumentState, viewName: string, except: string = ''): void {
    if (document.views.some((item: ViewRecord): boolean => item.id !== except && item.name === viewName)) throw new Error('视图名称已存在');
  }
  private copyState(): ViewWorkspaceState { if (!this.ready) throw new Error(this.error || '视图库尚未载入'); return cloneStructured(this.state) as ViewWorkspaceState; }
  private nextId(state: ViewWorkspaceState, kind: string): string { integer(state.serial, 0, Number.MAX_SAFE_INTEGER - 1, '视图库序号'); state.serial++; return `${kind}-${Date.now()}-${state.serial}`; }
  private publish(candidate: ViewWorkspaceState, apply?: () => void, rollback?: () => void): void {
    if (!this.ready || this.busy) throw new Error(this.busy ? '视图事务进行中，拒绝重入' : this.error || '视图库未载入');
    validateState(candidate); const encoded: string = JSON.stringify(candidate);
    if (encoded.length > VIEW_BYTE_BUDGET) throw new Error('视图库序列化超过预算');
    const previous: string | undefined = this.baseline; this.busy = true; let attempted: boolean = false;
    try {
      attempted = true; this.store.compareAndSwap(previous, encoded);
      if (this.store.read() !== encoded) throw new Error('视图库回读不一致');
      if (apply !== undefined) apply();
      this.state = candidate; this.baseline = encoded; this.error = '';
    } catch (failure) {
      let recovery: string = '';
      if (rollback !== undefined) {
        try { rollback(); } catch (rollbackFailure) { this.ready = false; recovery += `；UI/上下文回滚未完成：${String(rollbackFailure)}`; }
      }
      try {
        if (attempted) {
          const observed: string | undefined = this.store.read();
          if (observed === encoded) this.store.compareAndSwap(encoded, previous);
          else if (observed !== previous) throw new Error('存储已变化，未覆盖其他操作内容');
          if (this.store.read() !== previous) throw new Error('旧视图库回读不一致');
        }
      } catch (storageFailure) { this.ready = false; recovery += `；存储回滚未完成：${String(storageFailure)}`; }
      this.error = `视图操作未提交：${String(failure)}${recovery}`; throw new Error(this.error);
    } finally { this.busy = false; }
  }
}

export function viewCameraFromCanvas(width: number, height: number, zoomPercent: number, offsetX: number, offsetY: number): ViewCameraState {
  finite(width, '视口宽'); finite(height, '视口高'); if (width <= 0 || height <= 0) throw new Error('视口尚未测量');
  finite(offsetX, '相机offsetX'); finite(offsetY, '相机offsetY');
  const value: ViewCameraState = { centerXNm: width * 50 / zoomPercent - offsetX, centerYNm: offsetY - height * 50 / zoomPercent, zoomPercent };
  validateCamera(value); return value;
}
export function viewCameraToCanvas(value: ViewCameraState, width: number, height: number): ViewCanvasCamera {
  validateCamera(value); finite(width, '视口宽'); finite(height, '视口高'); if (width <= 0 || height <= 0) throw new Error('视口尚未测量');
  const offsetX: number = width * 50 / value.zoomPercent - value.centerXNm, offsetY: number = height * 50 / value.zoomPercent + value.centerYNm;
  finite(offsetX, '相机offsetX'); finite(offsetY, '相机offsetY'); return { zoomPercent: value.zoomPercent, offsetX, offsetY };
}
export function viewRenderLayerKey(documentId: string, layerNumber: number, datatype: number): string {
  text(documentId, '图层来源'); integer(layerNumber, 0, 32767, '层号'); integer(datatype, 0, 32767, 'datatype');
  return `${encodeURIComponent(documentId)}:${layerNumber}:${datatype}`;
}

export const viewWorkspaceService = new ViewWorkspaceService(viewWorkspaceStorageService);
