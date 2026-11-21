import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { workspaceService, WorkspaceDocument } from './WorkspaceService';
import { safeFilePublishService } from './SafeFilePublishService';
import { cloneStructured } from '../common/CloneUtils';

/** Process identity belongs to a preset; geometry and PCell parameters stay in their existing fields. */
export interface PCellProcessIdentity {
  technologyId: string;
  technologyVersion: string;
  deviceName: string;
  deviceModel: string;
}

export interface ComponentLibraryEntry {
  id: string;
  title: string;
  category: string;
  createdAt: number;
  pcellName: string;
  params: Record<string, number | string | boolean>;
  document?: WorkspaceDocument;
  pcellIdentity?: PCellProcessIdentity;
}

interface ComponentLibraryFile {
  version: number;
  entries: ComponentLibraryEntry[];
}

export class ComponentLibraryService {
  private entries: ComponentLibraryEntry[] = [];
  private path: string = '';
  private queue: Promise<void> = Promise.resolve();
  private serial: number = 0;
  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.path = `${context.filesDir}/hongtu-components.json`;
    let found: boolean = false;
    for (const candidate of [this.path, `${this.path}.previous`]) {
      if (!await fs.access(candidate)) continue;
      found = true;
      let raw: string;
      let parsed: ComponentLibraryEntry[];
      try { raw = await workspaceService.readBounded(candidate, 64 * 1024 * 1024); parsed = this.parse(raw); }
      catch (_) { continue; }
      const original: ComponentLibraryFile = JSON.parse(raw) as ComponentLibraryFile;
      if (original.entries.some((entry: ComponentLibraryEntry): boolean => entry.document?.version === 1)) {
        try {
          if (candidate === this.path) await workspaceService.atomicWrite(`${this.path}.previous`, raw);
          await workspaceService.atomicWrite(this.path, JSON.stringify({ version: 1, entries: parsed } as ComponentLibraryFile));
        } catch (error) { throw new Error(`器件库身份迁移未持久化：${String(error)}；原器件库保留，请重试`); }
      }
      this.entries = parsed;
      return;
    }
    if (found) throw new Error('器件库损坏，原文件保留');
    this.entries = [];
  }
  list(): ComponentLibraryEntry[] {
    return cloneStructured(this.entries) as ComponentLibraryEntry[];
  }
  async add(title: string, category: string, pcellName: string,
    params: Record<string, number | string | boolean>, document?: WorkspaceDocument, pcellIdentity?: PCellProcessIdentity): Promise<void> {
    if (title.trim().length === 0 || title.length > 128 || category.length > 64) throw new Error('器件名称或分类无效');
    workspaceService.validateParameters(params);
    const entry: ComponentLibraryEntry = { id: `component-${Date.now()}-${++this.serial}`, title: title.trim(),
      category: category.trim() || '个人器件', createdAt: Date.now(), pcellName: pcellName,
      params: cloneStructured(params) as Record<string, number | string | boolean>,
      document: document === undefined ? undefined : workspaceService.cloneValidatedDocument(document),
      pcellIdentity: pcellIdentity === undefined ? undefined : this.copyPCellIdentity(pcellIdentity) };
    await this.updateEntries((current: ComponentLibraryEntry[]): ComponentLibraryEntry[] => {
      if (current.length >= 128) throw new Error('器件库已达到 128 项，请先删除不需要的项');
      return current.concat([entry]);
    });
  }
  async remove(id: string): Promise<void> {
    await this.updateEntries((current: ComponentLibraryEntry[]): ComponentLibraryEntry[] =>
      current.filter((entry: ComponentLibraryEntry) => entry.id !== id));
  }
  async exportWithPicker(context: common.UIAbilityContext): Promise<void> {
    safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    const snapshotEntries: ComponentLibraryEntry[] = this.list();
    const encoded: string = JSON.stringify({ version: 1, entries: snapshotEntries } as ComponentLibraryFile);
    workspaceService.assertTextBudget(encoded, 64 * 1024 * 1024);
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save({ newFileNames: ['hongtu-components.htlib'], fileSuffixChoices: ['鸿图器件库|.htlib'] });
    if (uris.length === 0) throw new Error('已取消导出器件库');
    const data: Uint8Array = new util.TextEncoder().encodeInto(encoded);
    const buffer: ArrayBuffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    safeFilePublishService.publishBuffer(buffer, uris[0], context.cacheDir);
  }
  async importWithPicker(context: common.UIAbilityContext): Promise<void> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.select({ fileSuffixFilters: ['鸿图器件库|.htlib'], maxSelectNumber: 1 });
    if (uris.length === 0) throw new Error('已取消导入器件库');
    const incoming: ComponentLibraryEntry[] = this.parse(await workspaceService.readBounded(uris[0], 64 * 1024 * 1024));
    await this.updateEntries((current: ComponentLibraryEntry[]): ComponentLibraryEntry[] => {
      const next: ComponentLibraryEntry[] = current.slice();
      const contents: Set<string> = new Set<string>();
      for (const item of current) contents.add(this.entryContent(item));
      for (const entry of incoming) {
        const content: string = this.entryContent(entry);
        if (contents.has(content)) continue;
        entry.id = `component-${Date.now()}-${++this.serial}`;
        next.push(entry);
        contents.add(content);
      }
      if (next.length > 128) throw new Error('合并后的器件库超过 128 项，导入未应用');
      return next;
    });
  }
  /** Runtime id/time do not define reusable content. Preserve every other
   * field, including unknown imported metadata and complete document payload. */
  private entryContent(entry: ComponentLibraryEntry): string {
    const source: Record<string, Object> = entry as Object as Record<string, Object>;
    const content: string[] = [];
    for (const key of Object.keys(source).sort()) {
      if (key !== 'id' && key !== 'createdAt') content.push(JSON.stringify(key), this.canonicalContentValue(source[key]));
    }
    return `[${content.join(',')}]`;
  }

  /** Canonical JSON text keeps every object key and array position without
   * assigning imported keys to a new object's prototype. */
  private canonicalContentValue(value: Object): string {
    if (value === null) return 'null';
    if (typeof value === 'string' || typeof value === 'boolean') return JSON.stringify(value);
    if (typeof value === 'number') {
      if (!Number.isFinite(value as number)) throw new Error('器件内容含非有限数值');
      return JSON.stringify(value);
    }
    const content: string[] = [];
    if (Array.isArray(value)) {
      for (const item of value as Object[]) content.push(this.canonicalContentValue(item));
      return `[${content.join(',')}]`;
    }
    if (typeof value !== 'object') throw new Error('器件内容仅支持 JSON 数据');
    const source: Record<string, Object> = value as Record<string, Object>;
    for (const key of Object.keys(source).sort()) {
      content.push(`${JSON.stringify(key)}:${this.canonicalContentValue(source[key])}`);
    }
    return `{${content.join(',')}}`;
  }

  private parse(raw: string): ComponentLibraryEntry[] {
    workspaceService.assertTextBudget(raw, 64 * 1024 * 1024);
    const library: ComponentLibraryFile = JSON.parse(raw) as ComponentLibraryFile;
    if (library === null || library.version !== 1 || !Array.isArray(library.entries) || library.entries.length > 128) throw new Error('器件库格式无效');
    let vertices: number = 0;
    let expandedShapes: number = 0;
    const ids: Set<string> = new Set<string>();
    for (const entry of library.entries) {
      if (entry === null || typeof entry.id !== 'string' || !/^[A-Za-z0-9_-]{1,180}$/.test(entry.id) || ids.has(entry.id) ||
        typeof entry.title !== 'string' || entry.title.trim().length === 0 || entry.title.length > 128 ||
        typeof entry.category !== 'string' || entry.category.length > 64 || typeof entry.pcellName !== 'string' ||
        entry.pcellName.length > 128 || !Number.isFinite(entry.createdAt)) throw new Error('器件库条目无效');
      ids.add(entry.id);
      workspaceService.validateParameters(entry.params);
      if (entry.pcellIdentity !== undefined) {
        if (entry.pcellName.length === 0) throw new Error('工艺器件预设需要 PCell 名称');
        entry.pcellIdentity = this.copyPCellIdentity(entry.pcellIdentity);
      }
      if (entry.document !== undefined) {
        entry.document = workspaceService.cloneValidatedDocument(entry.document);
        expandedShapes += workspaceService.expandedShapeCount(entry.document);
        for (const shape of entry.document.shapes) vertices += shape.points.length;
      } else if (entry.pcellName.length === 0) throw new Error('器件条目缺少几何或 PCell');
      if (vertices > 1000000 || expandedShapes > 1000000) throw new Error('器件库总顶点或实例展开超过预算');
    }
    return library.entries;
  }
  private copyPCellIdentity(identity: PCellProcessIdentity): PCellProcessIdentity {
    if (identity === null || typeof identity !== 'object' || Array.isArray(identity)) throw new Error('器件预设工艺身份无效');
    for (const text of [identity.technologyId, identity.technologyVersion, identity.deviceName, identity.deviceModel]) {
      if (typeof text !== 'string' || text.trim().length === 0 || text.length > 120 || text.includes('\0')) throw new Error('器件预设工艺身份无效');
    }
    return { technologyId: identity.technologyId, technologyVersion: identity.technologyVersion,
      deviceName: identity.deviceName, deviceModel: identity.deviceModel };
  }
  private updateEntries(build: (entries: ComponentLibraryEntry[]) => ComponentLibraryEntry[]): Promise<void> {
    const run: Promise<void> = this.queue.catch(() => {}).then(async () => {
      if (this.path.length === 0) throw new Error('器件库尚未初始化');
      // Build against the latest committed list, not the state before queueing.
      const next: ComponentLibraryEntry[] = this.parse(JSON.stringify({ version: 1, entries: build(this.entries) } as ComponentLibraryFile));
      const encoded: string = JSON.stringify({ version: 1, entries: next } as ComponentLibraryFile);
      if (await fs.access(this.path)) {
        let previous: string = '';
        try { previous = await workspaceService.readBounded(this.path, 64 * 1024 * 1024); this.parse(previous); }
        catch (_) { previous = ''; }
        if (previous.length > 0) await workspaceService.atomicWrite(`${this.path}.previous`, previous);
      }
      await workspaceService.atomicWrite(this.path, encoded);
      this.entries = next;
    });
    this.queue = run;
    return run;
  }
}
export const componentLibraryService = new ComponentLibraryService();
