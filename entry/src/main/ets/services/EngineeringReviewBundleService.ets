import { MIN_ZOOM_PERCENT, MAX_ZOOM_PERCENT } from '../common/constants';
import { RdbReviewWorkspaceService } from './RdbReviewWorkspaceService';
import type { EngineeringReviewBundle, EngineeringReviewSource } from '../models/EngineeringReviewBundle';
import type { ViewAffine, ViewLayerVisibility, ViewPresentation, ViewDocumentState, ViewWorkspaceState } from '../models/ViewWorkspace';
import type { RdbReviewWorkspaceRecovery } from '../models/RdbReviewWorkspace';
import type { RdbReviewLayoutMapping } from '../models/RdbReview';
import { cloneStructured } from '../common/CloneUtils';

export const ENGINEERING_REVIEW_BYTE_BUDGET: number = 100 * 1024 * 1024;
/** Public carry contains a URI description, never a picker query token/user-info credential. */
export function engineeringReviewOriginUri(uri: string): string {
  if (typeof uri !== 'string') throw new Error('工程来源URI必须为字符串');
  return uri.split(/[?#]/)[0].replace(/^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)[^/]*@/, '$1');
}
/** Count actual UTF-8 bytes and reject unpaired surrogates before serialization/storage. */
export function engineeringReviewBytes(value: string): number {
  let count: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      const next: number = value.charCodeAt(++i);
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('工程审阅文本含无配对 Unicode');
      count += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('工程审阅文本含无配对 Unicode');
    else count += code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
  }
  return count;
}
function fields(value: Object, allowed: string[], required: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).some((key: string): boolean => !allowed.includes(key)) ||
    required.some((key: string): boolean => !Object.keys(value).includes(key))) throw new Error(`${label}字段无效`);
}
function text(value: string, label: string, maximum: number = 512): void {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum || /[\x00-\x1f\x7f]/.test(value)) throw new Error(`${label}无效`);
  engineeringReviewBytes(value);
}
function integer(value: number, low: number, high: number, label: string): void {
  if (!Number.isSafeInteger(value) || value < low || value > high) throw new Error(`${label}越界`);
}
function finite(value: number): void { if (typeof value !== 'number' || !Number.isFinite(value)) throw new Error('工程视图数值无效'); }
function affine(value: ViewAffine): void {
  fields(value, ['a', 'b', 'c', 'd', 'tx', 'ty'], ['a', 'b', 'c', 'd', 'tx', 'ty'], '工程视图变换');
  for (const number of [value.a, value.b, value.c, value.d, value.tx, value.ty]) finite(number);
  const determinant: number = value.a * value.d - value.b * value.c;
  if (!Number.isFinite(determinant) || determinant === 0) throw new Error('工程视图变换不可逆');
}
function layers(values: ViewLayerVisibility[]): void {
  if (!Array.isArray(values) || values.length > 32768) throw new Error('工程显示图层超过预算');
  const keys: Set<string> = new Set<string>();
  for (const value of values) {
    fields(value, ['layerNumber', 'datatype', 'visible'], ['layerNumber', 'datatype', 'visible'], '工程显示图层');
    integer(value.layerNumber, 0, 32767, '层号'); integer(value.datatype, 0, 32767, '用途');
    if (typeof value.visible !== 'boolean' || keys.has(`${value.layerNumber}:${value.datatype}`)) throw new Error('工程显示图层重复或visible无效');
    keys.add(`${value.layerNumber}:${value.datatype}`);
  }
}
export function validateEngineeringPresentation(value: ViewPresentation): void {
  fields(value, ['camera', 'location', 'hierarchyDepth', 'layerVisibilities'], ['camera', 'location', 'hierarchyDepth', 'layerVisibilities'], '工程视图');
  fields(value.camera, ['centerXNm', 'centerYNm', 'zoomPercent'], ['centerXNm', 'centerYNm', 'zoomPercent'], '工程相机');
  finite(value.camera.centerXNm); finite(value.camera.centerYNm); finite(value.camera.zoomPercent);
  if (value.camera.zoomPercent < MIN_ZOOM_PERCENT || value.camera.zoomPercent > MAX_ZOOM_PERCENT) throw new Error('工程缩放越界');
  integer(value.hierarchyDepth, 1, 32, '工程层级'); layers(value.layerVisibilities);
  const location = value.location;
  fields(location, ['cellStackKeys', 'placements'], ['cellStackKeys', 'placements'], '工程Cell定位');
  if (!Array.isArray(location.cellStackKeys) || location.cellStackKeys.length < 1 || location.cellStackKeys.length > 256 ||
    !Array.isArray(location.placements) || location.placements.length > 255 ||
    (location.placements.length !== 0 && location.placements.length !== location.cellStackKeys.length - 1)) throw new Error('工程Cell路径无效');
  for (const key of location.cellStackKeys) text(key, '工程Cell稳定键');
  if (new Set<string>(location.cellStackKeys).size !== location.cellStackKeys.length) throw new Error('工程Cell路径循环');
  for (let index: number = 0; index < location.placements.length; index++) {
    const step = location.placements[index];
    fields(step, ['parentCellKey', 'cellKey', 'instanceId', 'row', 'col'], ['parentCellKey', 'cellKey', 'instanceId', 'row', 'col'], '工程实例路径');
    if (step.parentCellKey !== location.cellStackKeys[index] || step.cellKey !== location.cellStackKeys[index + 1]) throw new Error('工程实例路径与Cell栈不一致');
    integer(step.instanceId, 0, Number.MAX_SAFE_INTEGER, '实例ID'); integer(step.row, 0, Number.MAX_SAFE_INTEGER, '阵列行'); integer(step.col, 0, Number.MAX_SAFE_INTEGER, '阵列列');
  }
}
export function validateEngineeringViews(value: ViewWorkspaceState): void {
  fields(value, ['schema', 'serial', 'documents'], ['schema', 'serial', 'documents'], '工程视图库');
  if (value.schema !== 'hongtu-view-workspace/v1' || !Array.isArray(value.documents) || value.documents.length > 256 ||
    engineeringReviewBytes(JSON.stringify(value)) > 2 * 1024 * 1024) throw new Error('工程视图库版本或预算无效');
  integer(value.serial, 0, Number.MAX_SAFE_INTEGER, '工程视图序号');
  const docs: Set<string> = new Set<string>(), ids: Set<string> = new Set<string>();
  for (const document of value.documents) {
    fields(document, ['documentId', 'activeViewId', 'views', 'bookmarks'], ['documentId', 'activeViewId', 'views', 'bookmarks'], '工程文档视图');
    text(document.documentId, '工程文档ID');
    if (docs.has(document.documentId) || !Array.isArray(document.views) || document.views.length < 1 || document.views.length > 128 ||
      !Array.isArray(document.bookmarks) || document.bookmarks.length > 2048) throw new Error('工程视图/书签数量或文档重复');
    docs.add(document.documentId);
    const viewNames: Set<string> = new Set<string>(), bookmarkNames: Set<string> = new Set<string>();
    for (const view of document.views) {
      fields(view, ['id', 'name', 'presentation', 'overlays'], ['id', 'name', 'presentation', 'overlays'], '工程视图记录');
      text(view.id, '工程视图ID'); text(view.name, '工程视图名称');
      if (view.name.trim() !== view.name || ids.has(view.id) || viewNames.has(view.name) || !Array.isArray(view.overlays) || view.overlays.length > 64) throw new Error('工程视图名称/ID重复或叠加超过预算');
      ids.add(view.id); viewNames.add(view.name); validateEngineeringPresentation(view.presentation);
      const overlays: Set<string> = new Set<string>();
      for (const overlay of view.overlays) {
        fields(overlay, ['id', 'sourceDocumentId', 'cellKey', 'visible', 'opacity', 'transform', 'layerVisibilities'], ['id', 'sourceDocumentId', 'cellKey', 'visible', 'opacity', 'transform', 'layerVisibilities'], '工程叠加');
        text(overlay.id, '工程叠加ID'); text(overlay.sourceDocumentId, '工程叠加来源'); text(overlay.cellKey, '工程叠加Cell');
        if (overlays.has(overlay.id) || typeof overlay.visible !== 'boolean') throw new Error('工程叠加ID重复或visible无效');
        overlays.add(overlay.id); finite(overlay.opacity); if (overlay.opacity < 0 || overlay.opacity > 1) throw new Error('工程叠加透明度无效');
        affine(overlay.transform); layers(overlay.layerVisibilities);
      }
    }
    if (!document.views.some((view): boolean => view.id === document.activeViewId)) throw new Error('工程激活视图不存在');
    for (const bookmark of document.bookmarks) {
      fields(bookmark, ['id', 'name', 'presentation'], ['id', 'name', 'presentation'], '工程书签'); text(bookmark.id, '工程书签ID'); text(bookmark.name, '工程书签名称');
      if (bookmark.name.trim() !== bookmark.name || ids.has(bookmark.id) || bookmarkNames.has(bookmark.name)) throw new Error('工程书签ID或名称重复');
      ids.add(bookmark.id); bookmarkNames.add(bookmark.name); validateEngineeringPresentation(bookmark.presentation);
    }
  }
}
export function validateEngineeringReports(value: RdbReviewWorkspaceRecovery): void {
  const candidate: RdbReviewWorkspaceService = new RdbReviewWorkspaceService();
  candidate.restoreRecovery(value);
  // Validate through the real XML/review codec, then retain the original serialized fields/bytes.
}
export function engineeringReviewLayoutMappingKey(value: RdbReviewLayoutMapping): string {
  return JSON.stringify([value.reportSourceIdentity, value.reportCell, value.layoutDocumentId]);
}
export function validateEngineeringLayoutMappings(values: RdbReviewLayoutMapping[]): void {
  if (!Array.isArray(values) || values.length > 100000) throw new Error('工程报告定位映射超过预算');
  const keys: Set<string> = new Set<string>();
  for (const value of values) {
    fields(value, ['reportSourceIdentity', 'reportCell', 'layoutDocumentId', 'layoutRevision', 'layoutCellId', 'layoutCellKey'],
      ['reportSourceIdentity', 'reportCell', 'layoutDocumentId', 'layoutRevision', 'layoutCellId', 'layoutCellKey'], '工程报告定位映射');
    text(value.reportSourceIdentity, '报告来源', 4096); text(value.reportCell, '报告Cell', 4096);
    text(value.layoutDocumentId, '定位文档'); text(value.layoutCellKey, '定位Cell键');
    integer(value.layoutRevision, 0, Number.MAX_SAFE_INTEGER, '定位版本'); integer(value.layoutCellId, 0, 2147483647, '定位Cell ID');
    const key: string = engineeringReviewLayoutMappingKey(value);
    if (keys.has(key)) throw new Error('工程报告定位映射明确键重复，未修补旧绑定');
    keys.add(key);
  }
}
export class EngineeringReviewBundleService {
  validate(input: EngineeringReviewBundle | string): EngineeringReviewBundle {
    const raw: string = typeof input === 'string' ? input : JSON.stringify(input);
    if (raw.length > ENGINEERING_REVIEW_BYTE_BUDGET || engineeringReviewBytes(raw) > ENGINEERING_REVIEW_BYTE_BUDGET) throw new Error('工程审阅载体超过100MiB预算');
    const value: EngineeringReviewBundle = JSON.parse(raw) as EngineeringReviewBundle;
    fields(value, ['schema', 'workspaceId', 'sources', 'views', 'reports', 'layoutMappings'], ['schema', 'workspaceId', 'sources'], '工程审阅载体');
    if (value.schema !== 'hongtu-engineering-review/v1' || !Array.isArray(value.sources) || value.sources.length > 256) throw new Error('工程审阅版本或来源预算无效');
    text(value.workspaceId, '工程来源文档', 256);
    const ids: Set<string> = new Set<string>();
    for (const source of value.sources) {
      fields(source, ['documentId', 'cellKeys', 'topCellKey', 'originUri'], ['documentId', 'cellKeys', 'topCellKey'], '工程来源引用');
      text(source.documentId, '工程来源ID'); text(source.topCellKey, '工程来源根Cell');
      if (ids.has(source.documentId) || !Array.isArray(source.cellKeys) || source.cellKeys.length < 1 || source.cellKeys.length > 100000) throw new Error('工程来源重复或Cell预算无效');
      ids.add(source.documentId); for (const key of source.cellKeys) text(key, '工程来源Cell键');
      if (new Set<string>(source.cellKeys).size !== source.cellKeys.length || !source.cellKeys.includes(source.topCellKey)) throw new Error('工程来源Cell键重复或根Cell缺失');
      if (source.originUri !== undefined) {
        text(source.originUri, '工程来源URI', 4096);
        if (engineeringReviewOriginUri(source.originUri) !== source.originUri) throw new Error('工程来源URI不能携带查询授权');
      }
    }
    if (value.views !== undefined && value.views !== null) {
      if (value.views.documentId !== value.workspaceId) throw new Error('工程视图必须属于工程来源文档');
      validateEngineeringViews({ schema: 'hongtu-view-workspace/v1', serial: 0, documents: [value.views] });
    }
    if (value.reports !== undefined && value.reports !== null) {
      validateEngineeringReports(value.reports);
      for (const report of value.reports.reports) if (engineeringReviewOriginUri(report.uri) !== report.uri) throw new Error('工程报告来源URI不能携带查询授权');
    }
    if (value.layoutMappings !== undefined && value.layoutMappings !== null) validateEngineeringLayoutMappings(value.layoutMappings);
    return value;
  }
  capture(workspaceId: string, sources: EngineeringReviewSource[], views?: ViewDocumentState | null, reports?: RdbReviewWorkspaceRecovery | null, layoutMappings?: RdbReviewLayoutMapping[] | null): EngineeringReviewBundle {
    const safeSources: EngineeringReviewSource[] = cloneStructured(sources) as EngineeringReviewSource[];
    for (const source of safeSources) if (source.originUri !== undefined) source.originUri = engineeringReviewOriginUri(source.originUri);
    const value: EngineeringReviewBundle = { schema: 'hongtu-engineering-review/v1', workspaceId, sources: safeSources };
    if (views !== undefined) value.views = views;
    if (reports !== undefined) {
      value.reports = reports === null ? null : cloneStructured(reports) as RdbReviewWorkspaceRecovery;
      if (value.reports !== null) for (const report of value.reports.reports) report.uri = engineeringReviewOriginUri(report.uri);
    }
    if (layoutMappings !== undefined) value.layoutMappings = layoutMappings;
    return this.validate(value);
  }
  encode(input: EngineeringReviewBundle): string { return JSON.stringify(this.validate(input)); }
}
export const engineeringReviewBundleService = new EngineeringReviewBundleService();
