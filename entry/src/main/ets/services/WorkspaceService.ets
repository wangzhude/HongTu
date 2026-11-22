import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Shape, ShapeType, nativeResultToShapesAsync } from '../models/GdsiiData';
import { nativeHongTuService } from './NativeHongTuService';
import { UiLayer } from '../common/types';
import { RulerLine } from '../common/UiStores';
import type { LayoutPropRecord, SourceLayerDefinition, LayerNameInterval } from '../../cpp/types/libhongtu/Index';
import { safeFilePublishService } from './SafeFilePublishService';
import { PrecisionSettings, validatePrecision, cleanDbuNm } from './PrecisionService';
import type { InstancePathStep } from './EditService';
import { engineeringProjectService } from './EngineeringProjectService';
import type { EngineeringProjectBundle } from './EngineeringProjectService';
import type { PythonEditorDraft } from './PythonWorkspaceService';
import { normalizeLayoutSemantics } from '../models/LayoutPort';
import type { LayoutSemanticState } from '../models/LayoutPort';
import type { DrcConfiguration } from './DrcService';
import { incrementalSnapshotEngine, isFiniteValidatedPointArray } from '../common/CloneUtils';
import { layoutConcurrencyService } from './LayoutConcurrencyService';

export interface WorkspaceLocalProcessState {
  schema: 'hongtu-local-process/v1';
  technologyJson: string;
  drcDeckJson: string;
  drcConfiguration: DrcConfiguration;
}

export interface PCellVariant {
  cellId: number;
  name: string;
  params: Record<string, number | string | boolean>;
  technologyId?: string;
  technologyVersion?: string;
  deviceName?: string;
  deviceModel?: string;
}

export interface WorkspaceDocument extends LayoutSemanticState {
  engineering?: EngineeringProjectBundle;
  precision?: PrecisionSettings;
  navigationPath?: InstancePathStep[];
  layerDefinitions?: SourceLayerDefinition[];
  version: number;
  id: string;
  title: string;
  sourcePath: string;
  /** 未修改大版图草稿引用的持久化沙箱二进制源路径（避免每次缩放/平移序列化上亿字节 JSON） */
  externalBinaryPath?: string;
  saveUri: string;
  projectUri: string;
  libName: string;
  topCellName: string;
  topCellId: number;
  cellNames: string[];
  cellProperties: LayoutPropRecord[][];
  libProperties: LayoutPropRecord[];
  shapes: Shape[];
  layers: UiLayer[];
  userUnits: number;
  physicalUnits: number;
  dirty: boolean;
  viewMode?: 'edit' | 'viewer';
  cellStack: number[];
  selectedIds: number[];
  zoom: number;
  offsetX: number;
  offsetY: number;
  hierarchyDepth: number;
  gridSize: number;
  rulers: RulerLine[];
  pcells: PCellVariant[];
  technologyId: string;
  technologyJson?: string;
  localProcessState?: WorkspaceLocalProcessState;
  /** Locally edited text only; external projects cannot claim this restoration path. */
  localPythonDraft?: PythonEditorDraft;
  /** Whether this local text still needs a successful engineering-project save. */
  localPythonDraftDirty?: boolean;
  revision: number;
  updatedAt: number;
}

export interface WorkspaceTab {
  id: string;
  title: string;
  dirty: boolean;
}

export interface WorkspacePreparedDraft {
  document: WorkspaceDocument;
}

interface WorkspacePreparedDraftPayload {
  snapshot: WorkspaceDocument;
  documentId: string;
  revision: number;
  title: string;
}

export interface WorkspaceHistory {
  id: string;
  documentId: string;
  title: string;
  createdAt: number;
  file: string;
}

interface WorkspaceDiskTab {
  id: string;
  title: string;
  dirty: boolean;
  file: string;
}

interface WorkspaceIndex {
  version: number;
  activeId: string;
  tabs: WorkspaceDiskTab[];
  history: WorkspaceHistory[];
}

interface WorkspaceReferenceBudget { parent: number; copies: number; }

export interface WorkspaceRecovery {
  documents: WorkspaceDocument[];
  activeId: string;
  warnings: string[];
}

interface ValidatedShapeStamp {
  pointsRef: Object;
  pointLen: number;
  id: number;
  type: ShapeType;
  layerNumber: number;
  datatype: number;
  ownerCellId: number | undefined;
  cellId: number | undefined;
  pathWidth: number | undefined;
  pathType: number | undefined;
  pathBeginExtension: number | undefined;
  pathEndExtension: number | undefined;
  rotation: number | undefined;
  magnification: number | undefined;
  mirror: number | undefined;
  arrayCols: number | undefined;
  arrayRows: number | undefined;
  arrayColStepX: number | undefined;
  arrayColStepY: number | undefined;
  arrayRowStepX: number | undefined;
  arrayRowStepY: number | undefined;
  text: string | undefined;
  propertiesRef: Object | undefined;
}

const VALIDATED_SHAPE_STAMPS: WeakMap<Shape, ValidatedShapeStamp> = new WeakMap<Shape, ValidatedShapeStamp>();

function matchesValidatedStamp(shape: Shape, s: ValidatedShapeStamp): boolean {
  return s.pointsRef === shape.points &&
    s.pointLen === shape.points.length &&
    s.id === shape.id &&
    s.type === shape.type &&
    s.layerNumber === shape.layerNumber &&
    s.datatype === shape.datatype &&
    s.ownerCellId === shape.ownerCellId &&
    s.cellId === shape.cellId &&
    s.pathWidth === shape.pathWidth &&
    s.pathType === shape.pathType &&
    s.pathBeginExtension === shape.pathBeginExtension &&
    s.pathEndExtension === shape.pathEndExtension &&
    s.rotation === shape.rotation &&
    s.magnification === shape.magnification &&
    s.mirror === shape.mirror &&
    s.arrayCols === shape.arrayCols &&
    s.arrayRows === shape.arrayRows &&
    s.arrayColStepX === shape.arrayColStepX &&
    s.arrayColStepY === shape.arrayColStepY &&
    s.arrayRowStepX === shape.arrayRowStepX &&
    s.arrayRowStepY === shape.arrayRowStepY &&
    s.text === shape.text &&
    s.propertiesRef === shape.properties;
}

function recordValidatedStamp(shape: Shape): void {
  VALIDATED_SHAPE_STAMPS.set(shape, {
    pointsRef: shape.points,
    pointLen: shape.points.length,
    id: shape.id,
    type: shape.type,
    layerNumber: shape.layerNumber,
    datatype: shape.datatype,
    ownerCellId: shape.ownerCellId,
    cellId: shape.cellId,
    pathWidth: shape.pathWidth,
    pathType: shape.pathType,
    pathBeginExtension: shape.pathBeginExtension,
    pathEndExtension: shape.pathEndExtension,
    rotation: shape.rotation,
    magnification: shape.magnification,
    mirror: shape.mirror,
    arrayCols: shape.arrayCols,
    arrayRows: shape.arrayRows,
    arrayColStepX: shape.arrayColStepX,
    arrayColStepY: shape.arrayColStepY,
    arrayRowStepX: shape.arrayRowStepX,
    arrayRowStepY: shape.arrayRowStepY,
    text: shape.text,
    propertiesRef: shape.properties
  });
}

/** Documents are immutable on disk. Only a fully written manifest publishes a draft. */
export class WorkspaceService {
  private directory: string = '';
  private diskTabs: WorkspaceDiskTab[] = [];
  private history: WorkspaceHistory[] = [];
  private queue: Promise<void> = Promise.resolve();
  private serial: number = 0;
  private issuedDrafts: WeakMap<WorkspacePreparedDraft, WorkspacePreparedDraftPayload> =
    new WeakMap<WorkspacePreparedDraft, WorkspacePreparedDraftPayload>();
  private activePendingNames: Set<string> = new Set<string>();

  newId(): string {
    return `doc-${Date.now()}-${++this.serial}`;
  }

  async initialize(context: common.UIAbilityContext): Promise<WorkspaceRecovery> {
    safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    this.directory = `${context.filesDir}/hongtu-workspace`;
    if (!await fs.access(this.directory)) await fs.mkdir(this.directory);
    const warnings: string[] = [];
    let index: WorkspaceIndex | undefined;
    for (const name of ['index.json', 'index.previous.json']) {
      try {
        if (!await fs.access(`${this.directory}/${name}`)) continue;
        const candidate: WorkspaceIndex = JSON.parse(await this.readBounded(`${this.directory}/${name}`, 1024 * 1024)) as WorkspaceIndex;
        this.validateIndex(candidate);
        index = candidate;
        if (name !== 'index.json') warnings.push('已使用上一次完整工作区索引恢复');
        break;
      } catch (error) {
        warnings.push(`工作区索引读取失败：${String(error)}`);
      }
    }
    const documents: WorkspaceDocument[] = [];
    const migrations: Map<string, WorkspaceDocument> = new Map<string, WorkspaceDocument>();
    this.diskTabs = [];
    this.history = [];
    if (index !== undefined) {
      for (const tab of index.tabs) {
        try {
          this.assertFileName(tab.file);
          const raw: string = await this.readBounded(`${this.directory}/${tab.file}`, 384 * 1024 * 1024);
          const original: WorkspaceDocument = JSON.parse(raw) as WorkspaceDocument;
          let doc: WorkspaceDocument;
          if (
            Array.isArray(original.shapes) &&
            original.shapes.length === 0 &&
            typeof original.externalBinaryPath === 'string' &&
            original.externalBinaryPath.length > 0 &&
            await fs.access(original.externalBinaryPath)
          ) {
            const lowerExt: string = original.externalBinaryPath.toLowerCase();
            const isOasis: boolean = lowerExt.endsWith('.oas') || lowerExt.endsWith('.oasis');
            const job = nativeHongTuService.startParseJob(original.externalBinaryPath, {
              scope: `ws-recover-${tab.id}-${Date.now()}`,
              isOasis: isOasis,
              quickScan: false,
              publishToActive: false,
            });
            if (job === null) throw new Error('无法启动外部版图恢复作业');
            const jobOut = await job.completion;
            if (jobOut.status !== 'succeeded' || jobOut.result === undefined || !jobOut.result.success) {
              throw new Error(jobOut.message || '外部二进制版图恢复失败');
            }
            original.shapes = await nativeResultToShapesAsync(jobOut.result, true);
            original.sourcePath = original.externalBinaryPath;
            original.externalBinaryPath = undefined;
            doc = this.validateAndNormalizeDocument(original);
          } else {
            doc = this.validateAndNormalizeDocument(JSON.parse(raw) as WorkspaceDocument);
          }
          if (doc.id !== tab.id) throw new Error('文档与索引不匹配');
          documents.push(doc);
          this.diskTabs.push(tab);
          if (original.version === 1) migrations.set(tab.id, doc);
        } catch (error) {
          warnings.push(`${tab.title} 未恢复：${String(error)}`);
        }
      }
      if (Array.isArray(index.history)) this.history = index.history.slice(-24);
      if (migrations.size > 0) {
        try {
          // Publish all recovered legacy tabs together. Never overwrite an old
          // immutable draft or checkpoint, and never publish a partial batch.
          const nextTabs: WorkspaceDiskTab[] = [];
          for (const tab of index.tabs) {
            const migrated: WorkspaceDocument | undefined = migrations.get(tab.id);
            if (migrated === undefined) { nextTabs.push(tab); continue; }
            const file: string = `${migrated.id}-migrate-v2-${Date.now()}-${++this.serial}.json`;
            this.assertFileName(file);
            await this.atomicWrite(`${this.directory}/${file}`, JSON.stringify(migrated));
            nextTabs.push({ id: tab.id, title: tab.title, dirty: tab.dirty, file: file });
          }
          const next: WorkspaceIndex = { version: index.version, activeId: index.activeId,
            tabs: nextTabs, history: index.history.slice() };
          this.validateIndex(next);
          await this.backupValidIndex(`${this.directory}/index.json`);
          await this.atomicWrite(`${this.directory}/index.json`, JSON.stringify(next));
          this.diskTabs = this.diskTabs.map((tab: WorkspaceDiskTab): WorkspaceDiskTab =>
            nextTabs.find((candidate: WorkspaceDiskTab): boolean => candidate.id === tab.id) ?? tab);
        } catch (error) {
          warnings.push(`旧版工程身份迁移未持久化：${String(error)}；原索引、草稿和历史文件保留，新身份仅在本次内存会话有效`);
        }
      }
    }
    if (index !== undefined && migrations.size === 0 && warnings.length === 0) {
      try { await this.pruneUnreferencedDrafts(index); } catch (_) {}
    } else {
      try { await this.pruneOrphanPendingFiles(); } catch (_) {}
    }
    const requested: string = index?.activeId ?? '';
    const activeId: string = documents.some((doc: WorkspaceDocument) => doc.id === requested) ? requested : (documents[0]?.id ?? '');
    return { documents: documents, activeId: activeId, warnings: warnings };
  }

  listHistory(documentId: string): WorkspaceHistory[] {
    return this.history.filter((item: WorkspaceHistory) => item.documentId === documentId).slice().reverse();
  }

  /** Clone before queueing: later edits must never change an in-flight recovery record. */
  saveDraft(document: WorkspaceDocument, tabs: WorkspaceTab[], activeId: string, checkpoint: boolean = false): Promise<void> {
    return this.savePreparedDraft(this.prepareDraft(document), tabs, activeId, checkpoint);
  }

  /** 零 JSON 增量克隆并执行完整工程语义校验（替代同步 JSON.stringify + parseDocument） */
  cloneValidatedDocument(document: WorkspaceDocument): WorkspaceDocument {
    const cloned: WorkspaceDocument = incrementalSnapshotEngine.cloneWorkspaceDocument(document);
    return this.validateAndNormalizeDocument(cloned);
  }

  /** 对刚水合生成的全新独立文档原地执行完整工程语义校验（零额外数组/对象分配） */
  adoptValidatedDocument(document: WorkspaceDocument): WorkspaceDocument {
    return this.validateAndNormalizeDocument(document);
  }

  /** Issue validated incremental CoW snapshot on UI thread; JSON encoding runs off-thread in TaskPool. */
  prepareDraft(document: WorkspaceDocument): WorkspacePreparedDraft {
    const snapshot: WorkspaceDocument = this.validateAndNormalizeDocument(
      incrementalSnapshotEngine.captureReadOnlyWorkspaceDocument(document), true
    );
    const prepared: WorkspacePreparedDraft = { document: snapshot };
    this.issuedDrafts.set(prepared, {
      snapshot: snapshot,
      documentId: snapshot.id,
      revision: snapshot.revision,
      title: snapshot.title
    });
    return prepared;
  }

  /** Every explicit save remains a distinct FIFO job, encoding JSON asynchronously via TaskPool. */
  savePreparedDraft(prepared: WorkspacePreparedDraft, tabs: WorkspaceTab[], activeId: string,
    checkpoint: boolean = false): Promise<void> {
    const payload: WorkspacePreparedDraftPayload | undefined = this.issuedDrafts.get(prepared);
    if (payload === undefined) throw new Error('工作区草稿凭据未由当前服务发行');
    const snapshot: WorkspaceDocument = payload.snapshot;
    const documentId: string = payload.documentId;
    const revision: number = payload.revision;
    const title: string = payload.title;
    const tabSnapshot: WorkspaceTab[] = tabs.map((tab: WorkspaceTab): WorkspaceTab => ({ id: tab.id, title: tab.title, dirty: tab.dirty }));
    if (tabSnapshot.length > 8 || new Set<string>(tabSnapshot.map((t: WorkspaceTab) => t.id)).size !== tabSnapshot.length ||
      tabSnapshot.some((t: WorkspaceTab) => !this.validFileName(`${t.id}.json`) || typeof t.title !== 'string' || t.title.length > 512)) {
      throw new Error('工作区标签页无效或超过 8 个');
    }
    const run: Promise<void> = this.queue.catch(() => {}).then(async () => {
      if (this.directory.length === 0) throw new Error('工作区尚未初始化');
      let draftPayload: WorkspaceDocument = snapshot;
      if (!checkpoint && !snapshot.dirty && snapshot.sourcePath.length > 0) {
        let totalPts: number = 0;
        for (let i = 0; i < snapshot.shapes.length; i++) {
          totalPts += snapshot.shapes[i].points.length;
          if (totalPts > 100000) break;
        }
        if (totalPts > 100000) {
          try {
            if (await fs.access(snapshot.sourcePath)) {
              draftPayload = incrementalSnapshotEngine.cloneWorkspaceDocumentMetadataWithShapes(snapshot, []);
              draftPayload.externalBinaryPath = snapshot.sourcePath;
            }
          } catch (_) {}
        }
      }
      const encodedResult = await layoutConcurrencyService.encodeJsonWithBudgetAsync(
        draftPayload,
        384 * 1024 * 1024,
        'workspace-draft'
      );
      const utf8Buffer: ArrayBuffer = await layoutConcurrencyService.encodeJsonToUtf8BufferAsync(encodedResult);
      const fileName: string = `${documentId}-${revision}-${Date.now()}-${++this.serial}.json`;
      this.assertFileName(fileName);
      await this.atomicWriteBuffer(`${this.directory}/${fileName}`, utf8Buffer);
      const nextTabs: WorkspaceDiskTab[] = [];
      for (const tab of tabSnapshot) {
        if (tab.id === documentId) {
          nextTabs.push({ id: tab.id, title: tab.title, dirty: tab.dirty, file: fileName });
        } else {
          const prior: WorkspaceDiskTab | undefined = this.diskTabs.find((item: WorkspaceDiskTab) => item.id === tab.id);
          if (prior !== undefined) nextTabs.push(prior);
        }
      }
      const nextHistory: WorkspaceHistory[] = this.history.slice();
      if (checkpoint) {
        nextHistory.push({ id: `checkpoint-${Date.now()}-${this.serial}`, documentId,
          title, createdAt: Date.now(), file: fileName });
      }
      const index: WorkspaceIndex = { version: 1, activeId: activeId, tabs: nextTabs, history: nextHistory.slice(-24) };
      const indexPath: string = `${this.directory}/index.json`;
      await this.backupValidIndex(indexPath);
      await this.atomicWrite(indexPath, JSON.stringify(index));
      this.diskTabs = nextTabs;
      this.history = index.history;
      // Cleanup is best effort after publication; failures never invalidate a save.
      try { await this.pruneUnreferencedDrafts(index); } catch (_) {}
    });
    this.queue = run;
    return run;
  }

  /** Persist selection only after all preceding publications have succeeded. */
  saveActiveDocument(activeId: string, isOpen?: () => boolean): Promise<void> {
    const run: Promise<void> = this.queue.then(async () => {
      if (isOpen !== undefined && !isOpen()) throw new Error('活动工作区文档已关闭');
      if (this.directory.length === 0) throw new Error('工作区尚未初始化');
      if (typeof activeId !== 'string' || !this.validFileName(`${activeId}.json`)) {
        throw new Error('活动工作区文档身份无效');
      }
      const tabs: WorkspaceDiskTab[] = this.diskTabs.map((tab: WorkspaceDiskTab): WorkspaceDiskTab =>
        ({ id: tab.id, title: tab.title, dirty: tab.dirty, file: tab.file }));
      const target: WorkspaceDiskTab | undefined = tabs.find((tab: WorkspaceDiskTab): boolean => tab.id === activeId);
      if (target === undefined) throw new Error('活动工作区文档尚未发布或已关闭');
      const history: WorkspaceHistory[] = this.history.map((item: WorkspaceHistory): WorkspaceHistory =>
        ({ id: item.id, documentId: item.documentId, title: item.title, createdAt: item.createdAt, file: item.file }));
      const index: WorkspaceIndex = { version: 1, activeId, tabs, history };
      this.validateIndex(index);
      const encoded: string = JSON.stringify(index);
      this.assertTextBudget(encoded, 1024 * 1024);
      if (!await fs.access(`${this.directory}/${target.file}`)) throw new Error('活动工作区文档文件不存在');
      const indexPath: string = `${this.directory}/index.json`;
      await this.backupValidIndex(indexPath);
      await this.atomicWrite(indexPath, encoded, isOpen);
    });
    this.queue = run;
    return run;
  }

  async restoreHistory(item: WorkspaceHistory): Promise<WorkspaceDocument> {
    this.assertFileName(item.file);
    const doc: WorkspaceDocument = this.parseDocument(await this.readBounded(`${this.directory}/${item.file}`, 192 * 1024 * 1024));
    if (doc.id !== item.documentId) throw new Error('历史记录与文档不匹配');
    return doc;
  }

  async exportProject(context: common.UIAbilityContext, document: WorkspaceDocument, saveAs: boolean,
    contextGuard?: () => boolean): Promise<string> {
    safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    const snapshot: WorkspaceDocument = this.cloneValidatedDocument(document);
    if (snapshot.localProcessState !== undefined && snapshot.engineering !== undefined) {
      snapshot.engineering = engineeringProjectService.refreshProcessBundle(snapshot.engineering,
        snapshot.localProcessState.technologyJson, snapshot.localProcessState.drcDeckJson);
      snapshot.technologyJson = snapshot.engineering.technologyJson;
      snapshot.localProcessState.technologyJson = snapshot.engineering.technologyJson;
      snapshot.localProcessState.drcDeckJson = snapshot.engineering.drcDeckJson;
    }
    if (snapshot.localPythonDraft !== undefined) {
      const bundle: EngineeringProjectBundle = snapshot.engineering ?? engineeringProjectService.buildBundle({
        workspaceId: snapshot.id, technologyJson: snapshot.technologyJson, pcells: snapshot.pcells });
      snapshot.engineering = engineeringProjectService.refreshPythonDraftBundle(bundle, snapshot.localPythonDraft);
      snapshot.localPythonDraft = undefined;
      snapshot.localPythonDraftDirty = undefined;
    }
    let uri: string = saveAs ? '' : snapshot.projectUri;
    if (uri.length === 0) {
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.save({ newFileNames: [`${snapshot.libName || 'layout'}.hongtu`],
        fileSuffixChoices: ['鸿图工程|.hongtu'] });
      if (uris.length === 0) throw new Error('已取消保存工程');
      uri = uris[0];
    }
    if (contextGuard !== undefined && !contextGuard()) throw new Error('工程或工具内容已变化，请重新保存；目标文件未写入');
    const utf8Buffer: ArrayBuffer = await layoutConcurrencyService.encodeUtf8BufferWithBudgetAsync(
      snapshot,
      192 * 1024 * 1024,
      'project-export'
    );
    safeFilePublishService.publishBuffer(utf8Buffer, uri, context.cacheDir);
    return uri;
  }

  async importProject(context: common.UIAbilityContext): Promise<WorkspaceDocument> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select({ fileSuffixFilters: ['鸿图工程|.hongtu'], maxSelectNumber: 1 });
    if (uris.length === 0) throw new Error('已取消打开工程');
    const doc: WorkspaceDocument = this.parseDocument(await this.readBounded(uris[0], 192 * 1024 * 1024));
    doc.id = this.newId();
    // External project data cannot assert ownership of the current local process.
    // The exported current process remains embedded for explicit tool restoration.
    doc.localProcessState = undefined;
    doc.localPythonDraft = undefined;
    doc.localPythonDraftDirty = undefined;
    doc.projectUri = uris[0];
    // A project's old sandbox source belongs to another installation/session.
    doc.sourcePath = '';
    doc.saveUri = '';
    // Reopening exactly what was saved has no unsaved edits in this new workspace.
    doc.dirty = false;
    return doc;
  }

  parseDocument(raw: string): WorkspaceDocument {
    this.assertTextBudget(raw, 384 * 1024 * 1024);
    const doc: WorkspaceDocument = JSON.parse(raw) as WorkspaceDocument;
    return this.validateAndNormalizeDocument(doc);
  }

  private validateAndNormalizeDocument(doc: WorkspaceDocument, reuseShapeValidation: boolean = false): WorkspaceDocument {
    if (doc === null || (doc.version !== 1 && doc.version !== 2) || typeof doc.id !== 'string' || !this.validFileName(`${doc.id}.json`) ||
      !Array.isArray(doc.shapes) || doc.shapes.length > 2000000 || !Array.isArray(doc.cellNames) ||
      doc.cellNames.length === 0 || doc.cellNames.length > 100000 || !Array.isArray(doc.layers) ||
      !Number.isFinite(doc.physicalUnits) || doc.physicalUnits <= 0 || !Number.isFinite(doc.userUnits) || doc.userUnits <= 0 ||
      !Number.isInteger(doc.topCellId) || doc.topCellId < 0 || doc.topCellId >= doc.cellNames.length) {
      throw new Error('鸿图工程格式或资源规模无效');
    }
    normalizeLayoutSemantics(doc, doc.cellNames.length, doc.version === 2);
    doc.version = 2;
    if (typeof doc.title !== 'string' || doc.title.length > 512 || typeof doc.libName !== 'string' || doc.libName.length > 512 ||
      typeof doc.topCellName !== 'string' || doc.cellNames.some((name: string) => typeof name !== 'string' || name.length === 0 || name.length > 512) ||
      new Set<string>(doc.cellNames).size !== doc.cellNames.length || doc.layers.length > 65536 ||
      !Number.isSafeInteger(doc.revision) || doc.revision < 0 || !Number.isFinite(doc.updatedAt) ||
      typeof doc.dirty !== 'boolean') throw new Error('工程名称或版本信息无效');
    if (doc.viewMode === undefined) doc.viewMode = 'edit';
    if (doc.viewMode !== 'edit' && doc.viewMode !== 'viewer') throw new Error('工程编辑模式无效');
    const ids: Set<number> = new Set<number>();
    let pointCount: number = 0;
    const cellNameCount: number = doc.cellNames.length;
    for (const shape of doc.shapes) {
      if (shape === null || !Number.isSafeInteger(shape.id) || shape.id <= 0 || ids.has(shape.id) || !Array.isArray(shape.points)) {
        throw new Error('工程含无效图形');
      }
      ids.add(shape.id);
      pointCount += shape.points.length;
      if (pointCount > 25000000) throw new Error('工程顶点超过恢复预算');
      const stamp: ValidatedShapeStamp | undefined = reuseShapeValidation ? VALIDATED_SHAPE_STAMPS.get(shape) : undefined;
      if (stamp !== undefined && matchesValidatedStamp(shape, stamp)) {
        if (shape.ownerCellId !== undefined && (shape.ownerCellId < 0 || shape.ownerCellId >= cellNameCount)) {
          throw new Error('图形归属 Cell 无效');
        }
        if (shape.type === ShapeType.INSTANCE && (shape.cellId === undefined || shape.cellId < 0 || shape.cellId >= cellNameCount)) {
          throw new Error('实例引用 Cell 无效');
        }
        continue;
      }
      if (!Number.isInteger(shape.layerNumber) || shape.layerNumber < 0 || shape.layerNumber > 32767 ||
        !Number.isInteger(shape.datatype) || shape.datatype < 0 || shape.datatype > 32767 ||
        [ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH, ShapeType.TEXT, ShapeType.INSTANCE, ShapeType.NODE].indexOf(shape.type) < 0) {
        throw new Error('工程含无效图形');
      }
      if (!isFiniteValidatedPointArray(shape.points)) {
        for (const point of shape.points) if (point === null || !Number.isFinite(point.x) || !Number.isFinite(point.y)) throw new Error('工程含非有限坐标');
      }
      if (shape.points.length === 0 || (shape.type === ShapeType.RECT && shape.points.length < 2) ||
        (shape.type === ShapeType.POLYGON && shape.points.length < 3) ||
        (shape.type === ShapeType.PATH && (shape.points.length < 2 || (shape.pathWidth !== undefined &&
          (!Number.isFinite(shape.pathWidth) || shape.pathWidth < 0))))) throw new Error('工程图形几何退化');
      if (shape.text !== undefined && typeof shape.text !== 'string') throw new Error('工程文字字段无效');
      if (shape.pathType !== undefined && [0, 1, 2, 4].indexOf(shape.pathType) < 0) throw new Error('工程路径端型无效');
      const optionalNumbers: (number | undefined)[] = [shape.pathBeginExtension, shape.pathEndExtension, shape.rotation,
        shape.magnification, shape.arrayColStepX, shape.arrayColStepY, shape.arrayRowStepX, shape.arrayRowStepY];
      if (optionalNumbers.some((n: number | undefined) => n !== undefined && !Number.isFinite(n)) ||
        (shape.magnification !== undefined && shape.magnification <= 0) ||
        (shape.mirror !== undefined && [0, 1, 2].indexOf(shape.mirror) < 0)) throw new Error('工程变换参数无效');
      for (const count of [shape.arrayCols, shape.arrayRows]) {
        if (count !== undefined && (!Number.isInteger(count) || count < 0 || count > 32767)) throw new Error('工程阵列维数无效');
      }
      this.validateProperties(shape.properties);
      if (shape.ownerCellId !== undefined && (!Number.isInteger(shape.ownerCellId) || shape.ownerCellId < 0 || shape.ownerCellId >= cellNameCount)) throw new Error('图形归属 Cell 无效');
      if (shape.type === ShapeType.INSTANCE && (shape.cellId === undefined || !Number.isInteger(shape.cellId) || shape.cellId < 0 || shape.cellId >= cellNameCount)) throw new Error('实例引用 Cell 无效');
      if (reuseShapeValidation) recordValidatedStamp(shape);
    }
    this.validateExpandedBudget(doc);
    if (doc.cellProperties === undefined) doc.cellProperties = [];
    if (!Array.isArray(doc.cellProperties) || doc.cellProperties.length > doc.cellNames.length) throw new Error('Cell 属性集合无效');
    for (const records of doc.cellProperties) this.validateProperties(records);
    while (doc.cellProperties.length < doc.cellNames.length) doc.cellProperties.push([]);
    if (doc.libProperties === undefined) doc.libProperties = [];
    this.validateProperties(doc.libProperties);
    if (doc.cellStack === undefined) doc.cellStack = [doc.topCellId];
    if (!Array.isArray(doc.cellStack) || doc.cellStack.length === 0 || doc.cellStack.length > 256 ||
      doc.cellStack.some((id: number) => !Number.isInteger(id) || id < 0 || id >= doc.cellNames.length)) throw new Error('工程 Cell 导航栈无效');
    if (doc.navigationPath !== undefined) {
      if (!Array.isArray(doc.navigationPath) || doc.navigationPath.length > 32 ||
        (doc.navigationPath.length > 0 && doc.navigationPath.length !== doc.cellStack.length - 1)) throw new Error('工程实例路径层数无效');
      const lookup: Map<number, Shape> = new Map<number, Shape>();
      for (const shape of doc.shapes) lookup.set(shape.id, shape);
      for (let index: number = 0; index < doc.navigationPath.length; index++) {
        const step: InstancePathStep = doc.navigationPath[index];
        if (step === null || !Number.isSafeInteger(step.instanceId) || step.parentCellId !== doc.cellStack[index] ||
          step.cellId !== doc.cellStack[index + 1]) throw new Error('工程实例路径与导航栈不一致');
        const instance: Shape | undefined = lookup.get(step.instanceId);
        if (instance === undefined || instance.type !== ShapeType.INSTANCE ||
          (instance.ownerCellId ?? doc.topCellId) !== step.parentCellId || instance.cellId !== step.cellId ||
          !Number.isInteger(step.row) || !Number.isInteger(step.col) || step.row < 0 || step.col < 0 ||
          step.row >= Math.max(1, instance.arrayRows ?? 1) || step.col >= Math.max(1, instance.arrayCols ?? 1) ||
          step.transform === null || step.transform === undefined ||
          ![step.transform.a, step.transform.b, step.transform.c, step.transform.d, step.transform.tx, step.transform.ty]
            .every((value: number) => Number.isFinite(value))) throw new Error('工程实例路径引用或阵列成员无效');
      }
    }
    if (doc.precision !== undefined) {
      if (doc.precision === null || typeof doc.precision.geometrySnapEnabled !== 'boolean' ||
        !Array.isArray(doc.precision.geometrySnapKinds) || doc.precision.geometrySnapKinds.length > 5) throw new Error('工程精度配置无效');
      const precisionError: string = validatePrecision(doc.precision);
      if (precisionError.length > 0) throw new Error(precisionError);
      if (Math.abs(doc.precision.dbuNm - cleanDbuNm(doc.physicalUnits)) > Math.max(1e-12, doc.precision.dbuNm * 1e-12)) {
        throw new Error('工程精度与文件 DBU 不一致');
      }
    }
    if (doc.selectedIds === undefined) doc.selectedIds = [];
    if (!Array.isArray(doc.selectedIds) || doc.selectedIds.length > doc.shapes.length || doc.selectedIds.some((id: number) => !ids.has(id))) throw new Error('工程选区引用无效');
    if (doc.rulers === undefined) doc.rulers = [];
    if (!Array.isArray(doc.rulers) || doc.rulers.length > 10000 || doc.rulers.some((r: RulerLine) => r === null ||
      !Number.isSafeInteger(r.id) || r.id < 1 || typeof r.vertical !== 'boolean' || !Number.isFinite(r.pos))) throw new Error('工程标尺无效');
    if (doc.pcells === undefined) doc.pcells = [];
    if (!Array.isArray(doc.pcells) || doc.pcells.length > doc.cellNames.length) throw new Error('工程 PCell 集合无效');
    for (const pcell of doc.pcells) {
      if (pcell === null || !Number.isInteger(pcell.cellId) || pcell.cellId < 0 || pcell.cellId >= doc.cellNames.length ||
        typeof pcell.name !== 'string' || pcell.name.length === 0 || pcell.name.length > 128) throw new Error('工程 PCell 无效');
      this.validateParameters(pcell.params);
      for (const text of [pcell.technologyId, pcell.technologyVersion, pcell.deviceName, pcell.deviceModel]) {
        if (text !== undefined && (typeof text !== 'string' || text.length === 0 || text.length > 120 || text.includes('\0'))) throw new Error('工程 PCell 工艺器件身份无效');
      }
    }
    if (!Number.isFinite(doc.zoom) || doc.zoom <= 0 || !Number.isFinite(doc.offsetX) || !Number.isFinite(doc.offsetY) ||
      !Number.isInteger(doc.hierarchyDepth) || doc.hierarchyDepth < 1 || doc.hierarchyDepth > 256 ||
      !Number.isFinite(doc.gridSize) || doc.gridSize <= 0) throw new Error('工程视图参数无效');
    for (const layer of doc.layers) {
      if (layer === null || !Number.isInteger(layer.layerNumber) || layer.layerNumber < 0 || layer.layerNumber > 32767 ||
        !Number.isInteger(layer.datatype) || layer.datatype < 0 || layer.datatype > 32767 ||
        typeof layer.englishName !== 'string' || typeof layer.chineseName !== 'string' || typeof layer.color !== 'string' ||
        typeof layer.visible !== 'boolean') throw new Error('工程图层配置无效');
      if (layer.sourceName !== undefined && (typeof layer.sourceName !== 'string' || layer.sourceName.length > 65535 || layer.sourceName.includes('\0'))) {
        throw new Error('工程源图层名称无效');
      }
      if (layer.fillColor !== undefined && (typeof layer.fillColor !== 'string' || layer.fillColor.length > 32)) {
        throw new Error('工程图层填充色无效');
      }
    }
    if (doc.layerDefinitions !== undefined) {
      if (!Array.isArray(doc.layerDefinitions) || doc.layerDefinitions.length > 100000) throw new Error('工程图层定义超出预算');
      for (const definition of doc.layerDefinitions) {
        if (definition === null || typeof definition.name !== 'string' || definition.name.length > 65535 ||
          definition.name.includes('\0') || typeof definition.textLayer !== 'boolean') throw new Error('工程图层定义无效');
        this.validateLayerInterval(definition.layer); this.validateLayerInterval(definition.datatype);
      }
    }
    doc.technologyId = typeof doc.technologyId === 'string' ? doc.technologyId : '';
    if (doc.technologyJson !== undefined && (typeof doc.technologyJson !== 'string' || doc.technologyJson.length > 4 * 1024 * 1024)) throw new Error('工程工艺配置过大或无效');
    if (doc.localProcessState !== undefined) {
      const state: WorkspaceLocalProcessState = doc.localProcessState;
      if (state === null || typeof state !== 'object' || state.schema !== 'hongtu-local-process/v1' ||
        typeof state.technologyJson !== 'string' || state.technologyJson.length > 4 * 1024 * 1024 ||
        typeof state.drcDeckJson !== 'string' || state.drcDeckJson.length > 4 * 1024 * 1024 ||
        state.drcConfiguration === null || typeof state.drcConfiguration !== 'object' ||
        Array.isArray(state.drcConfiguration) ||
        JSON.stringify(state.drcConfiguration).length > 8 * 1024 * 1024) throw new Error('本地工艺与规则恢复配置无效或过大');
      engineeringProjectService.validateProcessPayload(state.technologyJson, state.drcDeckJson);
      const configuration: DrcConfiguration = state.drcConfiguration;
      if (!Array.isArray(configuration.rules) || !Array.isArray(configuration.baseRules) ||
        !Array.isArray(configuration.ruleFiles) || configuration.ruleFiles.length > 4096 ||
        configuration.ruleFiles.some((file: string): boolean => typeof file !== 'string' || file.length > 4096 || file.includes('\0')) ||
        typeof configuration.currentProcess !== 'string' || configuration.currentProcess.length > 256 ||
        (configuration.ruleSource !== 'builtin' && configuration.ruleSource !== 'custom') ||
        typeof configuration.ruleSourceLabel !== 'string' || configuration.ruleSourceLabel.length > 4096 ||
        typeof configuration.ruleFilter !== 'string' || configuration.ruleFilter.length > 4096 ||
        typeof configuration.rulesTweaked !== 'boolean' || typeof configuration.deepMode !== 'boolean' ||
        typeof configuration.tilingEnabled !== 'boolean' || !Number.isInteger(configuration.hierarchyDepth) ||
        configuration.hierarchyDepth < 0 || configuration.hierarchyDepth > 16 ||
        !Number.isFinite(configuration.tileSize) || configuration.tileSize <= 0) throw new Error('本地完整 DRC 配置无效');
      engineeringProjectService.validateRuleState(configuration.rules);
      engineeringProjectService.validateRuleState(configuration.baseRules);
    }
    if (doc.engineering !== undefined) doc.engineering = engineeringProjectService.validateBundle(doc.engineering);
    if (doc.localPythonDraft !== undefined) doc.localPythonDraft = engineeringProjectService.validateLocalPythonDraft(doc.localPythonDraft);
    if (doc.localPythonDraftDirty !== undefined && (typeof doc.localPythonDraftDirty !== 'boolean' ||
      doc.localPythonDraft === undefined)) throw new Error('本地 Python 草稿保存状态无效');
    doc.sourcePath = typeof doc.sourcePath === 'string' ? doc.sourcePath : '';
    doc.saveUri = typeof doc.saveUri === 'string' ? doc.saveUri : '';
    doc.projectUri = typeof doc.projectUri === 'string' ? doc.projectUri : '';
    return doc;
  }

  validateParameters(params: Record<string, number | string | boolean>): void {
    if (params === null || typeof params !== 'object' || Array.isArray(params)) throw new Error('PCell 参数无效');
    const keys: string[] = Object.keys(params);
    if (keys.length > 128) throw new Error('PCell 参数过多');
    for (const key of keys) {
      const value: number | string | boolean = params[key];
      if (key.length > 128 || (typeof value !== 'number' && typeof value !== 'string' && typeof value !== 'boolean') ||
        (typeof value === 'number' && !Number.isFinite(value)) || (typeof value === 'string' && value.length > 4096)) throw new Error('PCell 参数值无效');
    }
  }

  private validateLayerInterval(interval: LayerNameInterval): void {
    if (interval === null || interval === undefined || !Number.isInteger(interval.type) || interval.type < 0 || interval.type > 4 ||
      !Number.isInteger(interval.lower) || !Number.isInteger(interval.upper) || interval.lower < 0 || interval.upper > 4294967295 ||
      interval.lower > interval.upper || (interval.type === 0 && (interval.lower !== 0 || interval.upper !== 4294967295)) ||
      (interval.type === 1 && interval.lower !== 0) || (interval.type === 2 && interval.upper !== 4294967295) ||
      (interval.type === 3 && interval.lower !== interval.upper)) throw new Error('工程图层名称区间无效');
  }

  /** Save and read enforce the same UTF-8 byte limit without allocating a second large buffer. */
  assertTextBudget(raw: string, limit: number): void {
    if (raw.length > limit) throw new Error('文本超过文件读取预算');
    let bytes: number = 0;
    for (let i = 0; i < raw.length; i++) {
      const code: number = raw.charCodeAt(i);
      if (code < 0x80) bytes++;
      else if (code < 0x800) bytes += 2;
      else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < raw.length &&
        raw.charCodeAt(i + 1) >= 0xDC00 && raw.charCodeAt(i + 1) <= 0xDFFF) { bytes += 4; i++; }
      else bytes += 3;
      if (bytes > limit) throw new Error('文本超过文件读取预算');
    }
  }

  private validateProperties(records: LayoutPropRecord[] | undefined): void {
    if (records === undefined) return;
    if (!Array.isArray(records) || records.length > 64) throw new Error('GDS 属性集合无效或超过 64 项恢复预算');
    for (const r of records) {
      if (r === null || !Number.isInteger(r.attr) || r.attr < -32768 || r.attr > 32767 ||
        !Number.isInteger(r.dtype) || r.dtype < 0 || r.dtype > 255 || typeof r.name !== 'string' ||
        typeof r.value !== 'string' || r.name.length > 65536 || r.value.length > 1048576) throw new Error('GDS 属性记录无效');
    }
  }

  /** Count compressed references without expanding geometry. Kahn order detects cycles. */
  expandedShapeCount(doc: WorkspaceDocument): number { return this.validateExpandedBudget(doc); }

  private validateExpandedBudget(doc: WorkspaceDocument): number {
    const count: number = doc.cellNames.length;
    const sizes: number[] = new Array<number>(count).fill(0);
    const depths: number[] = new Array<number>(count).fill(0);
    const pending: number[] = new Array<number>(count).fill(0);
    const parents: Map<number, WorkspaceReferenceBudget[]> = new Map<number, WorkspaceReferenceBudget[]>();
    for (const shape of doc.shapes) {
      const owner: number = shape.ownerCellId ?? doc.topCellId;
      if (shape.type === ShapeType.INSTANCE) {
        const child: number = shape.cellId as number;
        const copies: number = (shape.arrayCols || 1) * (shape.arrayRows || 1);
        pending[owner]++;
        let list: WorkspaceReferenceBudget[] | undefined = parents.get(child);
        if (list === undefined) { list = []; parents.set(child, list); }
        list.push({ parent: owner, copies: copies });
      } else { sizes[owner]++; }
    }
    const ready: number[] = [];
    for (let i = 0; i < count; i++) if (pending[i] === 0) ready.push(i);
    let seen: number = 0;
    let maximum: number = 0;
    for (let cursor = 0; cursor < ready.length; cursor++) {
      const child: number = ready[cursor]; seen++;
      if (sizes[child] > 10000000) throw new Error('工程 AREF 或嵌套实例展开超过恢复预算');
      if (depths[child] > 256) throw new Error('工程层级超过 256 层恢复预算');
      maximum = Math.max(maximum, sizes[child]);
      const list: WorkspaceReferenceBudget[] = parents.get(child) ?? [];
      for (const ref of list) {
        // Match native ValidateInteractiveImportBudget: an empty placement costs
        // one; a nonempty reference costs its content, not another marker too.
        sizes[ref.parent] += ref.copies * Math.max(1, sizes[child]);
        depths[ref.parent] = Math.max(depths[ref.parent], depths[child] + 1);
        pending[ref.parent]--;
        if (pending[ref.parent] === 0) ready.push(ref.parent);
      }
    }
    if (seen !== count) throw new Error('工程包含循环 Cell 引用');
    return maximum;
  }

  private validateIndex(index: WorkspaceIndex): void {
    if (index === null || index.version !== 1 || typeof index.activeId !== 'string' ||
      !Array.isArray(index.tabs) || index.tabs.length > 8 ||
      !Array.isArray(index.history) || index.history.length > 24) throw new Error('工作区索引无效');
    const ids: Set<string> = new Set<string>();
    for (const tab of index.tabs) {
      if (tab === null || !this.validFileName(tab.file) || typeof tab.id !== 'string' || ids.has(tab.id) ||
        typeof tab.title !== 'string' || typeof tab.dirty !== 'boolean') throw new Error('工作区索引条目无效');
      ids.add(tab.id);
    }
    for (const item of index.history) if (item === null || !this.validFileName(item.file) || typeof item.id !== 'string' ||
      typeof item.documentId !== 'string' || typeof item.title !== 'string' || !Number.isFinite(item.createdAt)) throw new Error('工作区历史索引无效');
  }

  private async backupValidIndex(path: string): Promise<void> {
    if (!await fs.access(path)) return;
    let previous: string;
    try {
      previous = await this.readBounded(path, 1024 * 1024);
      this.validateIndex(JSON.parse(previous) as WorkspaceIndex);
    } catch (_) { return; } // Never overwrite a valid recovery index with a corrupt primary.
    await this.atomicWrite(`${this.directory}/index.previous.json`, previous);
  }

  private async pruneUnreferencedDrafts(current: WorkspaceIndex): Promise<void> {
    const retained: Set<string> = new Set<string>();
    for (const tab of current.tabs) retained.add(tab.file);
    for (const item of current.history) retained.add(item.file);
    const previousPath: string = `${this.directory}/index.previous.json`;
    if (await fs.access(previousPath)) {
      const previous: WorkspaceIndex = JSON.parse(await this.readBounded(previousPath, 1024 * 1024)) as WorkspaceIndex;
      this.validateIndex(previous); // A questionable backup disables cleanup entirely.
      for (const tab of previous.tabs) retained.add(tab.file);
      for (const item of previous.history) retained.add(item.file);
    }
    await this.pruneOrphanPendingFiles();
    const names: string[] = await fs.listFile(this.directory, { recursion: false });
    for (const name of names) {
      if (this.isOrphanPendingFileName(name)) {
        try { await fs.unlink(`${this.directory}/${name}`); } catch (_) {}
        continue;
      }
      // Only this service's generated immutable snapshots, never arbitrary files,
      // manifests, external projects, subdirectories or history.
      if (!this.validFileName(name) || !/^[A-Za-z0-9_-]+-\d+-\d{13}-\d+\.json$/.test(name) || retained.has(name)) continue;
      await fs.unlink(`${this.directory}/${name}`);
    }
  }

  private isOrphanPendingFileName(name: string): boolean {
    if (typeof name !== 'string' || name.length === 0 || name.length > 260) return false;
    if (this.activePendingNames.has(name)) return false;
    return /^[A-Za-z0-9_.-]+\.pending(?:-\d+-\d+)?$/.test(name);
  }

  private async pruneOrphanPendingFiles(): Promise<void> {
    if (this.directory.length === 0) return;
    const names: string[] = await fs.listFile(this.directory, { recursion: false });
    for (const name of names) {
      if (!this.isOrphanPendingFileName(name)) continue;
      try { await fs.unlink(`${this.directory}/${name}`); } catch (_) {}
    }
  }

  private validFileName(name: string): boolean {
    return typeof name === 'string' && name.length <= 240 && /^[A-Za-z0-9_-]+\.json$/.test(name);
  }

  private assertFileName(name: string): void {
    if (!this.validFileName(name)) throw new Error('工作区文件名无效');
  }

  async readBounded(path: string, limit: number): Promise<string> {
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const stat = await fs.stat(file.fd);
      if (!Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > limit) throw new Error('文件超过读取预算');
      const decoder = new util.TextDecoder();
      const chunks: string[] = [];
      let position: number = 0;
      while (position < stat.size) {
        const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, stat.size - position));
        const count: number = await fs.read(file.fd, buffer);
        if (count <= 0 || count > buffer.byteLength) throw new Error('文件读取不完整');
        chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true }));
        position += count;
      }
      if ((await fs.stat(file.fd)).size !== stat.size) throw new Error('文件在读取期间发生变化');
      chunks.push(decoder.decodeToString(new Uint8Array(0)));
      return chunks.join('');
    } finally {
      await fs.close(file);
    }
  }

  async writeAllToUri(path: string, text: string): Promise<void> {
    const data: Uint8Array = new util.TextEncoder().encodeInto(text);
    safeFilePublishService.publishBuffer(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength), path, this.directory);
  }

  /** Owned temporary files only. Public exports always use verified safe publication. */
  private async writeOwnedBuffer(path: string, buffer: ArrayBuffer): Promise<void> {
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      let position: number = 0;
      while (position < buffer.byteLength) {
        const part: ArrayBuffer = buffer.slice(position, Math.min(position + 65536, buffer.byteLength));
        const count: number = await fs.write(file.fd, part);
        if (count <= 0 || count > part.byteLength) throw new Error('工程文件未完整写入');
        position += count;
      }
      await fs.fsync(file.fd);
    } finally {
      await fs.close(file);
    }
  }

  private async writeOwnedText(path: string, text: string): Promise<void> {
    const data: Uint8Array = new util.TextEncoder().encodeInto(text);
    const slice: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    await this.writeOwnedBuffer(path, slice);
  }

  async atomicWriteBuffer(path: string, buffer: ArrayBuffer, publicationGuard?: () => boolean): Promise<void> {
    const temporary: string = `${path}.pending`;
    const pendingName: string = temporary.substring(Math.max(temporary.lastIndexOf('/'), temporary.lastIndexOf('\\')) + 1);
    this.activePendingNames.add(pendingName);
    try {
      await this.writeOwnedBuffer(temporary, buffer);
      if (publicationGuard !== undefined && !publicationGuard()) throw new Error('工作区发布条件已变化');
      await fs.rename(temporary, path);
    } catch (error) {
      try { if (await fs.access(temporary)) await fs.unlink(temporary); } catch (_) {}
      throw new Error(String(error));
    } finally {
      this.activePendingNames.delete(pendingName);
    }
  }

  async atomicWrite(path: string, text: string, publicationGuard?: () => boolean): Promise<void> {
    const data: Uint8Array = new util.TextEncoder().encodeInto(text);
    const slice: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    await this.atomicWriteBuffer(path, slice, publicationGuard);
  }
}

export const workspaceService = new WorkspaceService();
