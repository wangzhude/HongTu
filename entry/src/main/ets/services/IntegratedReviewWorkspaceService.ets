import { IntegratedWorkspaceCoordinator } from './IntegratedWorkspaceCoordinator';
import { IntegratedWorkspaceStorageService } from './IntegratedWorkspaceStorageService';
import { ViewWorkspaceStorageService } from './ViewWorkspaceStorageService';
import { ViewWorkspaceService } from './ViewWorkspaceService';
import { RdbWaiverStorageService } from './RdbWaiverStorageService';
import { RdbReviewStorageService } from './RdbReviewStorageService';
import { RdbWaiverService } from './RdbWaiverService';
import { EngineeringReviewRestoreService } from './EngineeringReviewRestoreService';
import { validateEngineeringViews, validateEngineeringLayoutMappings } from './EngineeringReviewBundleService';
import type { IntegratedWorkspaceAtomicStore, IntegratedWorkspaceSlots, IntegratedWorkspaceLiveSlots, IntegratedWorkspaceProjectionStore } from '../models/IntegratedWorkspaceState';
import type { ViewWorkspaceState, ViewWorkspaceStore } from '../models/ViewWorkspace';
import type { RdbReviewLayoutMapping } from '../models/RdbReview';
import type { RdbWaiverStore } from '../models/RdbWaiver';
import type { EngineeringReviewStore, EngineeringReviewRestoreState } from '../models/EngineeringReviewBundle';
import { cloneStructured } from '../common/CloneUtils';

/** Legacy stores are read only. Their configure methods may create directories. */
export interface IntegratedReviewLegacyReader {
  configure(filesDir: string): void;
  read(): string | undefined;
}

/** Detached C publications generate a validated seed/projection, never a file write. */
class IntegratedReviewScratchStore implements RdbWaiverStore {
  private raw: string | undefined;
  constructor(raw?: string) { this.raw = raw; }
  read(): string | undefined { return this.raw; }
  compareAndSwap(expected: string | undefined, next: string): void {
    if (this.raw !== expected) throw new Error('集成审查scratch基线已改变');
    this.raw = next;
  }
}

class IntegratedReviewCallbackWaiverStore implements RdbWaiverStore {
  private reader: () => string | undefined;
  private writer: (expected: string | undefined, next: string) => void;
  constructor(reader: () => string | undefined, writer: (expected: string | undefined, next: string) => void) {
    this.reader = reader; this.writer = writer;
  }
  read(): string | undefined { return this.reader(); }
  compareAndSwap(expected: string | undefined, next: string): void { this.writer(expected, next); }
}

/** Stable facade for Index's report persistence and waiver library entry points. */
export class IntegratedReviewRdbStorage {
  private owner: IntegratedReviewWorkspaceService;
  private service: RdbWaiverService | undefined = undefined;
  constructor(owner: IntegratedReviewWorkspaceService) { this.owner = owner; }
  configure(filesDir: string): void { this.owner.configure(filesDir); if (this.service === undefined) this.loadCurrent(); }
  read(): string | undefined { return this.library().readWorkspace(); }
  compareAndSwap(expected: string | undefined, next: string): void { this.library().compareAndSwapWorkspace(expected, next); }
  library(): RdbWaiverService {
    this.owner.assertReady();
    if (this.service === undefined) throw new Error('集成豁免facade尚未载入');
    return this.service;
  }
  /** Detached load never reloads the outer or changes another facade's C instance. */
  loadCurrent(): void { this.service = this.owner.createRdbLibrary(); }
  /** Caller must adopt reports, views and mappings after explicit recovery. */
  reload(): void { this.owner.reloadRdb(); this.loadCurrent(); }
}

/** One physical outer record; domain validation and engineering projection stay in
 * their actual A/B/C codecs. Historical receipts never replace the current slots. */
export class IntegratedReviewWorkspaceService {
  private physical: IntegratedWorkspaceAtomicStore;
  private coordinator: IntegratedWorkspaceCoordinator;
  private legacyViews: IntegratedReviewLegacyReader;
  private legacyWaiver: IntegratedReviewLegacyReader;
  private legacyReports: IntegratedReviewLegacyReader;
  private filesDir: string = '';
  private ready: boolean = false;
  private loading: boolean = false;
  private error: string = '';
  private facade: IntegratedReviewRdbStorage;

  constructor(store: IntegratedWorkspaceAtomicStore = new IntegratedWorkspaceStorageService(),
    legacyViews: IntegratedReviewLegacyReader = new ViewWorkspaceStorageService(),
    legacyWaiver: IntegratedReviewLegacyReader = new RdbWaiverStorageService(),
    legacyReports: IntegratedReviewLegacyReader = new RdbReviewStorageService()) {
    this.physical = store; this.coordinator = new IntegratedWorkspaceCoordinator(store);
    this.legacyViews = legacyViews; this.legacyWaiver = legacyWaiver; this.legacyReports = legacyReports;
    this.facade = new IntegratedReviewRdbStorage(this);
  }

  configure(filesDir: string): void {
    if (this.filesDir.length > 0) {
      if (this.filesDir !== filesDir) throw new Error('集成审查工作区不能重定向');
      this.requireReady(); return;
    }
    this.coordinator.configure(filesDir); this.filesDir = filesDir; this.reload();
  }
  isReady(): boolean { return this.ready && !this.coordinator.isBlocked(); }
  getError(): string { return this.error || this.coordinator.getError(); }

  /** Readonly cold load. An existing outer is authoritative, including absent slots.
   * No legacy file is opened when an outer exists, even if its content is corrupt. */
  reload(): void {
    if (this.filesDir.length === 0) throw new Error('集成审查工作区尚未配置');
    if (this.loading) throw new Error('集成审查正在读取，禁止重入');
    this.loading = true; this.ready = false;
    try {
      const before: string | undefined = this.physical.read();
      this.coordinator.load();
      if (this.physical.read() !== before) throw new Error('集成审查冷读取期间outer已改变');
      if (before === undefined) {
        this.legacyViews.configure(this.filesDir); const views: string | undefined = this.legacyViews.read();
        this.legacyWaiver.configure(this.filesDir); let waiver: string | undefined = this.legacyWaiver.read();
        if (waiver === undefined) {
          this.legacyReports.configure(this.filesDir); const reports: string | undefined = this.legacyReports.read();
          const scratch: IntegratedReviewScratchStore = new IntegratedReviewScratchStore();
          const legacy: RdbWaiverService = new RdbWaiverService(scratch); legacy.load(reports); waiver = scratch.read();
        }
        // Coordinator checks lexical JSON, duplicate names, UTF-8 and complete budgets.
        this.coordinator.load(views, waiver);
      }
      this.refreshDomains(); this.facade.loadCurrent(); this.error = '';
    } catch (failure) {
      this.ready = false; this.error = `集成审查未载入：${String(failure)}`;
      throw new Error(this.error);
    } finally { this.loading = false; }
  }

  createViewStore(): ViewWorkspaceStore {
    return {
      configure: (filesDir: string): void => { this.configure(filesDir); },
      read: (): string | undefined => { this.requireReady(); return this.coordinator.readSlot('viewJson'); },
      compareAndSwap: (expected: string | undefined, next: string | undefined): void => {
        this.requireMutable(); this.validateViews(next); this.coordinator.compareAndSwapSlot('viewJson', expected, next);
      }
    };
  }
  rdb(): IntegratedReviewRdbStorage { return this.facade; }
  createRdbStore(): IntegratedReviewRdbStorage {
    this.requireMutable(); const facade: IntegratedReviewRdbStorage = new IntegratedReviewRdbStorage(this); facade.loadCurrent(); return facade;
  }
  forkRdb(): IntegratedReviewRdbStorage { return this.createRdbStore(); }
  /** Detect physical changes even for C snapshot() which reads only memory. */
  assertReady(): void { this.requireReady(); this.coordinator.snapshot(); }
  /** Healthy refresh keeps the coordinator's rollback ticket. A blocked refresh
   * explicitly reloads all domains; the caller must then rebuild its live runtime. */
  reloadRdb(): void {
    if (this.loading) throw new Error('集成审查正在读取，禁止重入');
    if (!this.isReady()) { this.reload(); return; }
    this.loading = true;
    try { this.refreshDomains(); }
    catch (failure) { this.ready = false; this.error = String(failure); throw new Error(this.error); }
    finally { this.loading = false; }
  }
  readViews(): ViewWorkspaceState {
    this.requireReady(); return this.validateViews(this.coordinator.readSlot('viewJson'));
  }
  readLayoutMappings(): RdbReviewLayoutMapping[] {
    this.requireReady(); return this.validateMappings(this.coordinator.readSlot('layoutMappingsJson'));
  }
  writeLayoutMappings(expected: RdbReviewLayoutMapping[], next: RdbReviewLayoutMapping[]): void {
    this.requireMutable(); validateEngineeringLayoutMappings(expected); validateEngineeringLayoutMappings(next);
    const raw: string | undefined = this.coordinator.readSlot('layoutMappingsJson');
    if (JSON.stringify(this.validateMappings(raw)) !== JSON.stringify(expected)) throw new Error('报告定位映射基线已改变');
    if (JSON.stringify(expected) === JSON.stringify(next)) return;
    this.coordinator.compareAndSwapSlot('layoutMappingsJson', raw, JSON.stringify(next));
  }

  /** Call immediately before EACH prepare. Never reuse an adapter after edits. */
  createEngineeringRestore(): EngineeringReviewRestoreService {
    this.requireMutable();
    const projection: IntegratedWorkspaceProjectionStore = this.coordinator.createEngineeringStore(
      (receipt: string, before: IntegratedWorkspaceSlots): IntegratedWorkspaceLiveSlots => this.projectEngineering(receipt, before));
    const store: EngineeringReviewStore = { read: (): string | undefined => projection.read(),
      compareAndSwap: (expected: string | undefined, next: string | undefined): void => projection.compareAndSwap(expected, next) };
    return new EngineeringReviewRestoreService(store);
  }
  /** Call only after B confirm returned successfully and live adoption completed. */
  finishEngineeringCommit(): void {
    this.requireMutable(); this.loading = true;
    try { this.refreshDomains(); this.coordinator.finishEngineeringCommit(); }
    finally { this.loading = false; }
  }

  private requireReady(): void {
    if (!this.isReady()) throw new Error(this.getError() || '集成审查未载入，请显式重新读取并重建运行态');
  }
  private requireMutable(): void {
    this.requireReady(); if (this.loading) throw new Error('集成审查正在读取，禁止重入发布');
  }
  private validateViews(raw: string | undefined): ViewWorkspaceState {
    const state: ViewWorkspaceState = raw === undefined ? { schema: 'hongtu-view-workspace/v1', serial: 0, documents: [] } : JSON.parse(raw) as ViewWorkspaceState;
    validateEngineeringViews(state);
    const views: ViewWorkspaceService = new ViewWorkspaceService({ read: (): string | undefined => raw,
      compareAndSwap: (): void => { throw new Error('集成视图只读校验禁止发布'); } });
    if (!views.initialize()) throw new Error(views.getError());
    return cloneStructured(state) as ViewWorkspaceState;
  }
  private validateMappings(raw: string | undefined): RdbReviewLayoutMapping[] {
    const values: RdbReviewLayoutMapping[] = raw === undefined ? [] : JSON.parse(raw) as RdbReviewLayoutMapping[];
    validateEngineeringLayoutMappings(values); return cloneStructured(values) as RdbReviewLayoutMapping[];
  }
  private validateReceipt(raw: string | undefined): EngineeringReviewRestoreState | undefined {
    const validator: EngineeringReviewRestoreService = new EngineeringReviewRestoreService({ read: (): string | undefined => raw,
      compareAndSwap: (): void => { throw new Error('集成receipt只读校验禁止发布'); } });
    return validator.readCommitted();
  }
  private validateWaiver(raw: string | undefined): void {
    const scratch: RdbWaiverService = new RdbWaiverService(new IntegratedReviewScratchStore(raw)); scratch.load();
    scratch.snapshot(); scratch.readWorkspace();
  }
  private validateSlots(slots: IntegratedWorkspaceSlots): void {
    this.validateViews(slots.viewJson); this.validateWaiver(slots.waiverJson);
    this.validateMappings(slots.layoutMappingsJson); this.validateReceipt(slots.engineeringReceipt);
  }
  private refreshDomains(): void {
    const snapshot = this.coordinator.snapshot(); this.validateSlots(snapshot);
    this.ready = true;
  }
  /** A facade owns this loaded instance; publication/rollback can swap references. */
  createRdbLibrary(): RdbWaiverService {
    this.requireReady(); const alreadyLoading: boolean = this.loading; this.loading = true;
    try {
      this.coordinator.snapshot();
      const store: RdbWaiverStore = new IntegratedReviewCallbackWaiverStore(
        (): string | undefined => { this.requireReady(); return this.coordinator.readSlot('waiverJson'); },
        (expected: string | undefined, next: string): void => {
          this.requireMutable(); this.validateWaiver(next); this.coordinator.compareAndSwapSlot('waiverJson', expected, next);
        }
      );
      const library: RdbWaiverService = new RdbWaiverService(store);
      library.load(); return library;
    } finally { this.loading = alreadyLoading; }
  }
  private projectEngineering(receipt: string, before: IntegratedWorkspaceSlots): IntegratedWorkspaceLiveSlots {
    this.validateSlots(before);
    const candidate: EngineeringReviewRestoreState | undefined = this.validateReceipt(receipt);
    if (candidate === undefined) throw new Error('工程恢复receipt缺失');
    const viewJson: string = JSON.stringify(candidate.state.views);
    const layoutMappingsJson: string | undefined = candidate.state.layoutMappings === undefined ? undefined : JSON.stringify(candidate.state.layoutMappings);
    this.validateViews(viewJson); this.validateMappings(layoutMappingsJson);
    const scratch: IntegratedReviewScratchStore = new IntegratedReviewScratchStore(before.waiverJson);
    const library: RdbWaiverService = new RdbWaiverService(scratch); library.load();
    const oldWorkspace: string | undefined = library.readWorkspace();
    library.compareAndSwapWorkspace(oldWorkspace, JSON.stringify(candidate.state.reports));
    return { viewJson, waiverJson: scratch.read(), layoutMappingsJson };
  }
}
