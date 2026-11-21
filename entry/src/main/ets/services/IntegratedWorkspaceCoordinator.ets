import { integratedWorkspaceDefaultLimits } from '../models/IntegratedWorkspaceState';
import type { IntegratedWorkspaceAtomicStore, IntegratedWorkspaceLiveSlots, IntegratedWorkspaceSlots,
  IntegratedWorkspaceState, IntegratedWorkspaceLimits, IntegratedWorkspaceSlot,
  IntegratedWorkspaceMutableSlot, IntegratedWorkspaceProjectionStore,
  IntegratedEngineeringProjector } from '../models/IntegratedWorkspaceState';

interface IntegratedCheckpoint {
  raw: string | undefined;
  state: IntegratedWorkspaceState;
  epoch: number;
  mutation: number;
}
interface IntegratedEngineeringRollback {
  owner: number;
  before: IntegratedCheckpoint;
  afterRaw: string;
  afterReceipt: string;
}
interface JsonObjectScan { kind: string; keys: Set<string>; expectsKey: boolean; }

function fields(value: Object, allowed: string[], required: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label}结构无效`);
  const keys: string[] = Object.keys(value);
  if (keys.some((key: string): boolean => !allowed.includes(key)) ||
    required.some((key: string): boolean => !keys.includes(key))) throw new Error(`${label}字段无效`);
}

/** Unicode is checked before an encoder can silently replace unpaired surrogates. */
export function integratedWorkspaceUtf8Bytes(value: string): number {
  if (typeof value !== 'string') throw new Error('统一工作区文本类型无效');
  let bytes: number = 0;
  for (let index: number = 0; index < value.length; index++) {
    const code: number = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      const low: number = value.charCodeAt(++index);
      if (!(low >= 0xdc00 && low <= 0xdfff)) throw new Error('统一工作区文本含无配对 Unicode');
      bytes += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('统一工作区文本含无配对 Unicode');
    else bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
  }
  return bytes;
}

/** JSON.parse proves syntax; a lexical pass validates decoded string tokens and
 * duplicate keys without dynamic object indexing, payload normalization or repair.
 */
function checkedJson(raw: string, maximum: number, label: string): Object {
  if (typeof raw !== 'string' || raw.length === 0 || raw.length > maximum ||
    integratedWorkspaceUtf8Bytes(raw) > maximum) throw new Error(`${label}超过 UTF-8 预算或为空`);
  const parsed: Object = JSON.parse(raw) as Object;
  const stack: JsonObjectScan[] = [];
  for (let index: number = 0; index < raw.length; index++) {
    const token: string = raw.charAt(index);
    if (token === '"') {
      const start: number = index;
      let escaped: boolean = false;
      for (index++; index < raw.length; index++) {
        const character: string = raw.charAt(index);
        if (!escaped && character === '"') break;
        if (!escaped && character === '\\') escaped = true; else escaped = false;
      }
      const decoded: string = JSON.parse(raw.slice(start, index + 1)) as string;
      integratedWorkspaceUtf8Bytes(decoded);
      const top: JsonObjectScan | undefined = stack.length === 0 ? undefined : stack[stack.length - 1];
      if (top !== undefined && top.kind === 'object' && top.expectsKey) {
        if (top.keys.has(decoded)) throw new Error(`${label}含重复 JSON 字段`);
        top.keys.add(decoded); top.expectsKey = false;
      }
    } else if (token === '{') stack.push({ kind: 'object', keys: new Set<string>(), expectsKey: true });
    else if (token === '[') stack.push({ kind: 'array', keys: new Set<string>(), expectsKey: false });
    else if (token === '}' || token === ']') stack.pop();
    else if (token === ',') {
      const top: JsonObjectScan | undefined = stack.length === 0 ? undefined : stack[stack.length - 1];
      if (top !== undefined && top.kind === 'object') top.expectsKey = true;
    }
  }
  return parsed;
}

function emptyState(): IntegratedWorkspaceState {
  return { schema: 'hongtu-integrated-workspace/v1', version: 1, revision: 0 };
}
function copySlots(value: IntegratedWorkspaceSlots): IntegratedWorkspaceSlots {
  const next: IntegratedWorkspaceSlots = {};
  if (value.viewJson !== undefined) next.viewJson = value.viewJson;
  if (value.waiverJson !== undefined) next.waiverJson = value.waiverJson;
  if (value.layoutMappingsJson !== undefined) next.layoutMappingsJson = value.layoutMappingsJson;
  if (value.engineeringReceipt !== undefined) next.engineeringReceipt = value.engineeringReceipt;
  return next;
}
function copyState(value: IntegratedWorkspaceState): IntegratedWorkspaceState {
  const next: IntegratedWorkspaceState = { schema: value.schema, version: value.version, revision: value.revision };
  if (value.viewJson !== undefined) next.viewJson = value.viewJson;
  if (value.waiverJson !== undefined) next.waiverJson = value.waiverJson;
  if (value.layoutMappingsJson !== undefined) next.layoutMappingsJson = value.layoutMappingsJson;
  if (value.engineeringReceipt !== undefined) next.engineeringReceipt = value.engineeringReceipt;
  return next;
}
function slotValue(value: IntegratedWorkspaceSlots, slot: IntegratedWorkspaceSlot): string | undefined {
  if (slot === 'viewJson') return value.viewJson;
  if (slot === 'waiverJson') return value.waiverJson;
  if (slot === 'layoutMappingsJson') return value.layoutMappingsJson;
  if (slot === 'engineeringReceipt') return value.engineeringReceipt;
  throw new Error('统一工作区槽位无效');
}
function replaceSlot(value: IntegratedWorkspaceState, slot: IntegratedWorkspaceMutableSlot, next: string | undefined): void {
  // Optional undefined is omitted by encode/copyState, without ArkTS's forbidden
  // delete operator. Cached snapshots also omit the absent property entirely.
  if (slot === 'viewJson') value.viewJson = next;
  else if (slot === 'waiverJson') value.waiverJson = next;
  else if (slot === 'layoutMappingsJson') value.layoutMappingsJson = next;
  else throw new Error('工程收据只能通过组合工程事务改变');
}
function nextCounter(value: number, label: string): number {
  if (!Number.isSafeInteger(value) || value < 0 || value >= Number.MAX_SAFE_INTEGER) throw new Error(`${label}耗尽`);
  return value + 1;
}

/** Exact outer CAS authority shared by all projections. load() is read-only: legacy
 * seeds stay in memory until one real mutation migrates them in its single CAS.
 * An uncertain write/readback blocks adoption and all access until explicit load().
 */
export class IntegratedWorkspaceCoordinator {
  private loaded: boolean = false;
  private blocked: boolean = false;
  private busy: boolean = false;
  private error: string = '';
  private directory: string = '';
  private raw: string | undefined = undefined;
  private state: IntegratedWorkspaceState = emptyState();
  private epoch: number = 0;
  private mutation: number = 0;
  private engineeringSerial: number = 0;
  private rollback: IntegratedEngineeringRollback | undefined = undefined;
  private readonly limits: IntegratedWorkspaceLimits;
  private store: IntegratedWorkspaceAtomicStore;

  constructor(store: IntegratedWorkspaceAtomicStore, limits: IntegratedWorkspaceLimits = integratedWorkspaceDefaultLimits()) {
    this.store = store;
    fields(limits, ['maximumBytes', 'viewBytes', 'waiverBytes', 'engineeringBytes', 'layoutMappingsBytes'],
      ['maximumBytes', 'viewBytes', 'waiverBytes', 'engineeringBytes', 'layoutMappingsBytes'], '统一工作区预算');
    const ceilings: IntegratedWorkspaceLimits = integratedWorkspaceDefaultLimits();
    this.limit(limits.maximumBytes, ceilings.maximumBytes); this.limit(limits.viewBytes, ceilings.viewBytes);
    this.limit(limits.waiverBytes, ceilings.waiverBytes); this.limit(limits.engineeringBytes, ceilings.engineeringBytes);
    this.limit(limits.layoutMappingsBytes, ceilings.layoutMappingsBytes);
    this.limits = { maximumBytes: limits.maximumBytes, viewBytes: limits.viewBytes, waiverBytes: limits.waiverBytes,
      engineeringBytes: limits.engineeringBytes, layoutMappingsBytes: limits.layoutMappingsBytes };
  }

  configure(filesDir: string): void {
    if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
      !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
      filesDir.split(/[\\/]+/).some((part: string): boolean => part === '.' || part === '..')) throw new Error('统一工作区需要应用私有绝对目录');
    const directory: string = filesDir.replace(/\\/g, '/').replace(/\/$/, '');
    if (directory.length === 0 || (this.directory.length > 0 && this.directory !== directory)) throw new Error('统一工作区私有目录已绑定，不能重定向');
    if (this.store.configure !== undefined) this.store.configure(filesDir);
    this.directory = directory;
  }

  load(seedViews?: string, seedWaiver?: string, seedEngineering?: string, seedLayoutMappings?: string): void {
    if (this.busy) throw new Error('统一工作区事务忙');
    try {
      const raw: string | undefined = this.store.read();
      const next: IntegratedWorkspaceState = raw === undefined ? emptyState() : this.decode(raw);
      if (raw === undefined) {
        if (seedViews !== undefined) next.viewJson = seedViews;
        if (seedWaiver !== undefined) next.waiverJson = seedWaiver;
        if (seedEngineering !== undefined) next.engineeringReceipt = seedEngineering;
        if (seedLayoutMappings !== undefined) next.layoutMappingsJson = seedLayoutMappings;
        this.validateSlots(next);
        // The seeded outer must already fit the same future physical budget.
        this.encode(next);
      }
      if (this.store.read() !== raw) throw new Error('统一工作区读取期间已改变');
      const epoch: number = nextCounter(this.epoch, '统一工作区读取代数');
      this.raw = raw; this.state = copyState(next); this.epoch = epoch;
      this.loaded = true; this.blocked = false; this.error = ''; this.rollback = undefined;
    } catch (failure) { this.blocked = true; this.error = String(failure); throw new Error(this.error); }
  }

  isBlocked(): boolean { return this.blocked; }
  getError(): string { return this.error; }
  snapshot(): IntegratedWorkspaceState { this.requireLoaded(); this.checkDisk(); return copyState(this.state); }
  readSlot(slot: IntegratedWorkspaceSlot): string | undefined {
    this.requireLoaded(); this.checkDisk(); return slotValue(this.state, slot);
  }

  compareAndSwapSlot(slot: IntegratedWorkspaceMutableSlot, expected: string | undefined, next: string | undefined): void {
    this.requireMutable(); this.checkDisk();
    if (slot !== 'viewJson' && slot !== 'waiverJson' && slot !== 'layoutMappingsJson') throw new Error('工程收据只能通过组合工程事务改变');
    if (slotValue(this.state, slot) !== expected) throw new Error('统一工作区槽位基线已改变');
    // A no-op on an absent outer never manufactures an empty file or migrates seeds.
    if (expected === next) return;
    const candidate: IntegratedWorkspaceState = copyState(this.state);
    replaceSlot(candidate, slot, next);
    candidate.revision = nextCounter(this.state.revision, '统一工作区修订');
    const encoded: string = this.encode(candidate);
    this.write(candidate, encoded);
    this.rollback = undefined;
  }

  createViewStore(): IntegratedWorkspaceProjectionStore { return this.createSlotStore('viewJson'); }
  createWaiverStore(): IntegratedWorkspaceProjectionStore { return this.createSlotStore('waiverJson'); }
  createLayoutMappingsStore(): IntegratedWorkspaceProjectionStore { return this.createSlotStore('layoutMappingsJson'); }

  /** Create a fresh adapter immediately before each B prepare(). The adapter's
   * complete baseline never changes when B rereads its immutable receipt.
   */
  createEngineeringStore(projector: IntegratedEngineeringProjector): IntegratedWorkspaceProjectionStore {
    this.requireMutable(); this.checkDisk();
    const baseline: IntegratedCheckpoint = this.checkpoint();
    const owner: number = nextCounter(this.engineeringSerial, '统一工程事务序号');
    this.engineeringSerial = owner;
    let committed: boolean = false;
    return { configure: (filesDir: string): void => this.configure(filesDir),
      read: (): string | undefined => this.readSlot('engineeringReceipt'),
      compareAndSwap: (expected: string | undefined, next: string | undefined): void => {
        if (committed) { this.restoreEngineering(owner, expected, next); return; }
        this.commitEngineering(owner, baseline, expected, next, projector); committed = expected !== next;
      } };
  }

  /** Root calls only after B confirm() completed runtime publication and guards. */
  finishEngineeringCommit(): void { this.requireMutable(); this.checkDisk(); this.rollback = undefined; }

  private createSlotStore(slot: IntegratedWorkspaceMutableSlot): IntegratedWorkspaceProjectionStore {
    return { configure: (filesDir: string): void => this.configure(filesDir),
      read: (): string | undefined => this.readSlot(slot),
      compareAndSwap: (expected: string | undefined, next: string | undefined): void => this.compareAndSwapSlot(slot, expected, next) };
  }
  private checkpoint(): IntegratedCheckpoint {
    return { raw: this.raw, state: copyState(this.state), epoch: this.epoch, mutation: this.mutation };
  }
  private commitEngineering(owner: number, baseline: IntegratedCheckpoint, expected: string | undefined,
    next: string | undefined, projector: IntegratedEngineeringProjector): void {
    this.requireMutable(); this.checkDisk();
    if (this.raw !== baseline.raw || this.epoch !== baseline.epoch || this.mutation !== baseline.mutation ||
      this.state.engineeringReceipt !== expected || baseline.state.engineeringReceipt !== expected) throw new Error('工程预览的完整工作区基线已改变');
    if (expected === next) return;
    if (next === undefined) throw new Error('工程收据删除只允许已提交事务的精确回滚');
    checkedJson(next, this.limits.engineeringBytes, '工程收据');
    // Callback is detached codec work; no coordinator mutation can reenter it.
    this.busy = true;
    let live: IntegratedWorkspaceLiveSlots;
    try { live = projector(next, copySlots(baseline.state)); }
    finally { this.busy = false; }
    fields(live, ['viewJson', 'waiverJson', 'layoutMappingsJson'], [], '工程 live 投影');
    const candidate: IntegratedWorkspaceState = { schema: 'hongtu-integrated-workspace/v1', version: 1,
      revision: nextCounter(baseline.state.revision, '统一工作区修订'), engineeringReceipt: next };
    if (live.viewJson !== undefined) candidate.viewJson = live.viewJson;
    if (live.waiverJson !== undefined) candidate.waiverJson = live.waiverJson;
    if (live.layoutMappingsJson !== undefined) candidate.layoutMappingsJson = live.layoutMappingsJson;
    const encoded: string = this.encode(candidate);
    this.write(candidate, encoded);
    this.rollback = { owner, before: baseline, afterRaw: encoded, afterReceipt: next };
  }
  private restoreEngineering(owner: number, expected: string | undefined, next: string | undefined): void {
    this.requireMutable(); this.checkDisk();
    const rollback: IntegratedEngineeringRollback | undefined = this.rollback;
    if (rollback === undefined || rollback.owner !== owner || rollback.afterReceipt !== expected ||
      rollback.before.state.engineeringReceipt !== next || this.raw !== rollback.afterRaw) throw new Error('工程回滚资格已撤销或当前完整记录已改变，未覆盖后续保存');
    this.write(rollback.before.state, rollback.before.raw);
    this.rollback = undefined;
  }
  private write(candidate: IntegratedWorkspaceState, encoded: string | undefined): void {
    this.requireMutable();
    const mutation: number = nextCounter(this.mutation, '统一工作区变更序号');
    this.busy = true;
    try {
      this.store.compareAndSwap(this.raw, encoded);
      if (this.store.read() !== encoded) throw new Error('统一工作区完整回读不一致，内存未采用；需要重新载入');
      this.state = copyState(candidate); this.raw = encoded; this.mutation = mutation;
    } catch (failure) {
      this.blocked = true; this.error = `统一工作区存储未确认，内存未采用；需要重新载入：${String(failure)}`;
      this.rollback = undefined; throw new Error(this.error);
    } finally { this.busy = false; }
  }
  private requireLoaded(): void {
    if (!this.loaded || this.blocked) throw new Error(this.blocked ? `统一工作区已阻断，需要重新载入：${this.error}` : '统一工作区尚未载入');
  }
  private requireMutable(): void { this.requireLoaded(); if (this.busy) throw new Error('统一工作区事务忙'); }
  private checkDisk(): void {
    try { if (this.store.read() !== this.raw) throw new Error('统一工作区已由另一操作改变，需要重新载入'); }
    catch (failure) { this.blocked = true; this.error = String(failure); this.rollback = undefined; throw new Error(this.error); }
  }
  private limit(value: number, ceiling: number): void {
    if (!Number.isSafeInteger(value) || value < 1 || value > ceiling) throw new Error('统一工作区预算只能降低且必须为正整数');
  }
  private validateSlots(value: IntegratedWorkspaceSlots): void {
    if (value.viewJson !== undefined) checkedJson(value.viewJson, this.limits.viewBytes, '视图 live JSON');
    if (value.waiverJson !== undefined) checkedJson(value.waiverJson, this.limits.waiverBytes, '豁免 live JSON');
    if (value.layoutMappingsJson !== undefined) checkedJson(value.layoutMappingsJson, this.limits.layoutMappingsBytes, '定位映射 live JSON');
    if (value.engineeringReceipt !== undefined) checkedJson(value.engineeringReceipt, this.limits.engineeringBytes, '工程收据');
  }
  private decode(raw: string): IntegratedWorkspaceState {
    const value: IntegratedWorkspaceState = checkedJson(raw, this.limits.maximumBytes, '统一工作区 outer JSON') as IntegratedWorkspaceState;
    fields(value, ['schema', 'version', 'revision', 'viewJson', 'waiverJson', 'layoutMappingsJson', 'engineeringReceipt'],
      ['schema', 'version', 'revision'], '统一工作区 outer');
    if (value.schema !== 'hongtu-integrated-workspace/v1' || value.version !== 1) throw new Error('未知统一工作区 schema/version，原数据已保留');
    if (!Number.isSafeInteger(value.revision) || value.revision < 0) throw new Error('统一工作区 revision 无效');
    // JSON cannot encode undefined: explicit null and non-string slots are rejected.
    this.validateSlots(value); return copyState(value);
  }
  private encode(value: IntegratedWorkspaceState): string {
    this.validateSlots(value);
    const raw: string = JSON.stringify(value);
    if (raw.length > this.limits.maximumBytes || integratedWorkspaceUtf8Bytes(raw) > this.limits.maximumBytes) throw new Error('统一工作区 outer 超过 512 MiB 或调用方更低预算');
    return raw;
  }
}
