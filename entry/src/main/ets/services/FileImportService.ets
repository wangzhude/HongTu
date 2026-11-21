import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import type { GdsiiResult } from '../../cpp/types/libhongtu/Index';
import { nativeHongTuService } from './NativeHongTuService';
import { LayoutSemanticState, normalizeLayoutSemantics } from '../models/LayoutPort';
import { RecentFile } from '../workbench/WorkbenchModels';

const RECENT_FILE_META_STORAGE_KEY: string = 'hongtuRecentFileMeta';
const MAX_RECENT_FILE_META_ENTRIES: number = 32;
const IMPORT_CACHE_FILE_PATTERN: RegExp = /^hongtu-import-\d+-\d+\.[a-z0-9]+$/i;

export interface RecentFileSummaryMeta {
  key: string;
  topCellName: string;
  cellCount: number;
  elementCount: number;
  updatedAt: number;
}

const memoryRecentMeta: Map<string, RecentFileSummaryMeta> = new Map<string, RecentFileSummaryMeta>();
const probedSandboxPaths: Set<string> = new Set<string>();
let metaStorageLoaded: boolean = false;

function normalizeSandboxPath(rawPath: string): string {
  return rawPath.trim().replace(/[\\/]+/g, '/');
}

function ensureRecentMetaLoaded(): void {
  if (metaStorageLoaded) {
    return;
  }
  metaStorageLoaded = true;
  try {
    PersistentStorage.persistProp(RECENT_FILE_META_STORAGE_KEY, '[]');
    const raw: string = AppStorage.get<string>(RECENT_FILE_META_STORAGE_KEY) ?? '[]';
    const entries: RecentFileSummaryMeta[] = JSON.parse(raw) as RecentFileSummaryMeta[];
    if (Array.isArray(entries)) {
      for (let i = 0; i < entries.length; i++) {
        const entry: RecentFileSummaryMeta = entries[i];
        if (entry && typeof entry.key === 'string' && entry.key.length > 0) {
          memoryRecentMeta.set(entry.key, entry);
        }
      }
    }
  } catch (_err) {
  }
}

function flushRecentMetaStorage(): void {
  try {
    const entries: RecentFileSummaryMeta[] = Array.from(memoryRecentMeta.values())
      .sort((a: RecentFileSummaryMeta, b: RecentFileSummaryMeta): number => b.updatedAt - a.updatedAt)
      .slice(0, MAX_RECENT_FILE_META_ENTRIES);
    memoryRecentMeta.clear();
    for (let i = 0; i < entries.length; i++) {
      memoryRecentMeta.set(entries[i].key, entries[i]);
    }
    AppStorage.setOrCreate<string>(RECENT_FILE_META_STORAGE_KEY, JSON.stringify(entries));
  } catch (_err) {
  }
}

export function extractLayoutTopCellName(result: GdsiiResult): string {
  if (!Array.isArray(result.cells) || result.cells.length === 0) {
    return '';
  }
  const topIndex: number = result.primaryTopCellId >= 0 && result.primaryTopCellId < result.cells.length
    ? result.primaryTopCellId
    : 0;
  return result.cells[topIndex]?.name ?? '';
}

export function recordRecentFileMetadataForResult(paths: string[], result: GdsiiResult): void {
  if (!result.success) {
    return;
  }
  ensureRecentMetaLoaded();
  const topCellName: string = extractLayoutTopCellName(result);
  const cellCount: number = Number.isFinite(result.cellCount) && result.cellCount >= 0
    ? result.cellCount
    : (Array.isArray(result.cells) ? result.cells.length : 0);
  const elementCount: number = Number.isFinite(result.totalElements) && result.totalElements >= 0
    ? result.totalElements
    : 0;
  const now: number = Date.now();
  let updated: boolean = false;
  for (let i = 0; i < paths.length; i++) {
    const key: string = paths[i].trim();
    if (key.length === 0) {
      continue;
    }
    memoryRecentMeta.set(key, {
      key: key,
      topCellName: topCellName,
      cellCount: cellCount,
      elementCount: elementCount,
      updatedAt: now
    });
    updated = true;
  }
  if (updated) {
    flushRecentMetaStorage();
  }
}

export function resolveRecentFileMetadata(file: RecentFile): RecentFileSummaryMeta | undefined {
  if (file.topCellName !== undefined || file.cellCount !== undefined || file.elementCount !== undefined) {
    return {
      key: file.key(),
      topCellName: file.topCellName ?? '',
      cellCount: file.cellCount ?? -1,
      elementCount: file.elementCount ?? -1,
      updatedAt: file.openedAt
    };
  }
  ensureRecentMetaLoaded();
  const bySandbox: RecentFileSummaryMeta | undefined = file.sandboxPath.length > 0
    ? memoryRecentMeta.get(file.sandboxPath)
    : undefined;
  if (bySandbox !== undefined) {
    file.topCellName = bySandbox.topCellName;
    file.cellCount = bySandbox.cellCount;
    file.elementCount = bySandbox.elementCount;
    return bySandbox;
  }
  const byUri: RecentFileSummaryMeta | undefined = file.sourceUri.length > 0
    ? memoryRecentMeta.get(file.sourceUri)
    : undefined;
  if (byUri !== undefined) {
    file.topCellName = byUri.topCellName;
    file.cellCount = byUri.cellCount;
    file.elementCount = byUri.elementCount;
    return byUri;
  }
  if (file.sandboxPath.length > 0 && !probedSandboxPaths.has(file.sandboxPath)) {
    probedSandboxPaths.add(file.sandboxPath);
    try {
      if (fs.accessSync(file.sandboxPath)) {
        const scanned: GdsiiResult = nativeHongTuService.quickScan(file.sandboxPath);
        if (scanned.success) {
          recordRecentFileMetadataForResult([file.sandboxPath, file.sourceUri], scanned);
          const resolved: RecentFileSummaryMeta | undefined = memoryRecentMeta.get(file.sandboxPath);
          if (resolved !== undefined) {
            file.topCellName = resolved.topCellName;
            file.cellCount = resolved.cellCount;
            file.elementCount = resolved.elementCount;
            return resolved;
          }
        }
      }
    } catch (_err) {
    }
  }
  return undefined;
}

/** Picker URIs and cached paths share one format detector, including encoded suffixes and query/fragment tails. */
export function layoutFileExtensionForUri(uri: string): string {
  let pathPart: string = uri.split(/[?#]/)[0];
  try { pathPart = decodeURIComponent(pathPart); } catch (_error) {}
  const lower: string = pathPart.toLowerCase();
  for (const suffix of ['.gdsii', '.gds', '.oasis', '.oas', '.cif', '.dxf']) {
    if (lower.endsWith(suffix)) return suffix;
  }
  return '.gds';
}

export function layoutFileTypeForPath(path: string): string {
  const extension: string = layoutFileExtensionForUri(path);
  if (extension === '.oas' || extension === '.oasis') return 'OASIS';
  if (extension === '.cif') return 'CIF';
  if (extension === '.dxf') return 'DXF';
  return 'GDSII';
}

export class ImportedLayoutResult {
  sourceUri: string;
  sandboxPath: string;
  quickInfo: GdsiiResult;
  parseResult: GdsiiResult;

  constructor(sourceUri: string, sandboxPath: string, quickInfo: GdsiiResult, parseResult: GdsiiResult) {
    this.sourceUri = sourceUri;
    this.sandboxPath = sandboxPath;
    this.quickInfo = quickInfo;
    this.parseResult = parseResult;
    recordRecentFileMetadataForResult([sandboxPath, sourceUri], parseResult);
  }
}

/** pickAndScan 的返回：已复制到沙箱并完成 quickScan，尚未解析（供大文件向导介入） */
export interface PickedLayout {
  sourceUri: string;
  sandboxPath: string;
  quickInfo: GdsiiResult;
}

export class FileImportService {
  private importSequence: number = 0;
  private activeImportPaths: Set<string> = new Set<string>();

  /** 标记正在导入/解析中的沙箱路径，防止并发垃圾回收误删尚未挂入标签页或 recentFiles 的活跃副本 */
  retainActiveImportPath(sandboxPath: string): void {
    const clean: string = normalizeSandboxPath(sandboxPath);
    if (clean.length > 0) {
      this.activeImportPaths.add(clean);
    }
  }

  releaseActiveImportPath(sandboxPath: string): void {
    const clean: string = normalizeSandboxPath(sandboxPath);
    if (clean.length > 0) {
      this.activeImportPaths.delete(clean);
    }
  }

  /**
   * 选择文件 + 复制到沙箱 + quickScan（不解析、不清理）。
   * 调用方根据 quickInfo.fileSize 决定是否弹出"大版图打开向导"，
   * 然后调用 parseImported 完成解析，最后在 finally 中调用 cleanup。
   */
  async pickAndScan(context: common.UIAbilityContext, scanAction?: (path: string) => Promise<GdsiiResult>): Promise<PickedLayout> {
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris = await documentPicker.select({
      fileSuffixFilters: ['版图文件|.gds,.gdsii,.oas,.oasis,.cif,.dxf'],
      maxSelectNumber: 1,
    });

    if (uris.length === 0) {
      throw new Error('未选择文件');
    }

    return await this.scanFromUri(context, uris[0], scanAction);
  }

  /**
   * 从已知外部 URI（文件选择器或 UDMF 统一拖拽拖入）复制到沙箱并执行 quickScan。
   */
  async scanFromUri(
    context: common.UIAbilityContext,
    sourceUri: string,
    scanAction?: (path: string) => Promise<GdsiiResult>
  ): Promise<PickedLayout> {
    const sandboxPath = await this.cacheSourceFile(context, sourceUri);
    this.retainActiveImportPath(sandboxPath);

    // FILE-1: quickScan 抛异常时也需清理沙箱文件，避免泄漏
    let quickInfo: GdsiiResult;
    try {
      quickInfo = scanAction === undefined ? nativeHongTuService.quickScan(sandboxPath) : await scanAction(sandboxPath);
    } catch (e) {
      this.releaseActiveImportPath(sandboxPath);
      this.cleanup(sandboxPath);
      throw new Error(`文件快速扫描异常: ${e}`);
    }
    if (!quickInfo.success) {
      // quickScan 失败：清理后抛出，避免沙箱堆积
      this.releaseActiveImportPath(sandboxPath);
      this.cleanup(sandboxPath);
      // FILE-3: errorMessage 可能为 undefined，提供兜底信息
      throw new Error(quickInfo.errorMessage || '文件快速扫描失败（未知原因）');
    }

    this.releaseActiveImportPath(sandboxPath);
    recordRecentFileMetadataForResult([sandboxPath, sourceUri], quickInfo);
    return { sourceUri, sandboxPath, quickInfo };
  }

  /** Copy the complete provider file without changing the active native document.
   * Saved files use this too, so recent-file reopening reads the successful output.
   * Each copy gets a new path; existing imports and workspace tabs keep theirs.
   */
  async cacheSourceFile(context: common.UIAbilityContext, sourceUri: string,
                        expectedBytes?: number): Promise<string> {
    if (sourceUri.length === 0) throw new Error('文件来源为空');
    const sandboxPath = `${context.filesDir}/hongtu-import-${Date.now()}-${++this.importSequence}${this.extensionFromUri(sourceUri)}`;
    this.retainActiveImportPath(sandboxPath);
    try {
      const sourceFile = await fs.open(sourceUri, fs.OpenMode.READ_ONLY);
      try {
        const sourceBytes: number = fs.statSync(sourceFile.fd).size;
        if (!Number.isSafeInteger(sourceBytes) || sourceBytes <= 0 || sourceBytes > 512 * 1024 * 1024) {
          throw new Error('版图文件应为非空且不超过 512 MiB');
        }
        if (expectedBytes !== undefined && sourceBytes !== expectedBytes) {
          throw new Error('保存文件长度已变化，未更新最近文件');
        }
        await fs.copyFile(sourceFile.fd, sandboxPath, 0);
        if (fs.statSync(sandboxPath).size !== sourceBytes) throw new Error('版图文件复制长度不一致');
      } finally {
        fs.closeSync(sourceFile);
      }
    } catch (error) {
      this.releaseActiveImportPath(sandboxPath);
      this.cleanup(sandboxPath);
      throw new Error(`文件复制到沙箱失败: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      this.releaseActiveImportPath(sandboxPath);
    }
    ensureRecentMetaLoaded();
    const existingByUri: RecentFileSummaryMeta | undefined = memoryRecentMeta.get(sourceUri);
    if (existingByUri !== undefined) {
      memoryRecentMeta.set(sandboxPath, {
        key: sandboxPath,
        topCellName: existingByUri.topCellName,
        cellCount: existingByUri.cellCount,
        elementCount: existingByUri.elementCount,
        updatedAt: Date.now()
      });
      flushRecentMetaStorage();
    }
    return sandboxPath;
  }

  /** 解析沙箱文件（不在内部清理，由调用方在 finally 中 cleanup）。 */
  async parseImportedAsync(sandboxPath: string): Promise<GdsiiResult> {
    const lower: string = sandboxPath.toLowerCase();
    const parseResult: GdsiiResult = lower.endsWith('.cif') || lower.endsWith('.dxf')
      ? this.parseImported(sandboxPath)
      : await nativeHongTuService.parseAsync(sandboxPath);
    if (!parseResult.success) {
      throw new Error(parseResult.errorMessage || '文件解析失败（未知原因）');
    }
    this.validateImportedSemantics(parseResult);
    recordRecentFileMetadataForResult([sandboxPath], parseResult);
    return parseResult;
  }

  /** Synchronous compatibility for text formats and existing API users. */
  parseImported(sandboxPath: string): GdsiiResult {
    const parseResult = nativeHongTuService.parse(sandboxPath);
    if (!parseResult.success) {
      // FILE-4: errorMessage 可能为空串，提供兜底信息
      const msg: string = parseResult.errorMessage && parseResult.errorMessage.length > 0
        ? parseResult.errorMessage
        : '文件解析失败（未知原因）';
      throw new Error(msg);
    }
    this.validateImportedSemantics(parseResult);
    recordRecentFileMetadataForResult([sandboxPath], parseResult);
    return parseResult;
  }

  /** 清理沙箱临时文件（无论成功失败都应调用，避免多次导入堆积）。 */
  private validateImportedSemantics(result: GdsiiResult): void {
    const state: LayoutSemanticState = { cellKeys: result.cellKeys, ports: result.ports, crossSections: result.crossSections,
      layoutContextRecords: result.layoutContextRecords, cellContextRecords: result.cellContextRecords };
    normalizeLayoutSemantics(state, result.cells.length, true);
  }

  cleanup(sandboxPath: string): void {
    if (sandboxPath.length > 0) {
      this.releaseActiveImportPath(sandboxPath);
      probedSandboxPaths.delete(sandboxPath);
      if (memoryRecentMeta.delete(sandboxPath)) {
        flushRecentMetaStorage();
      }
      try {
        fs.unlinkSync(sandboxPath);
      } catch (e) {
        // FILE-2: 清理失败不影响主流程，但记录日志便于诊断磁盘泄漏
        console.warn('清理沙箱文件失败: ' + e);
      }
    }
  }

  /**
   * 扫描 filesDir 下全部 `hongtu-import-*` 导入副本，异步回收既不在 recentFiles、
   * 也不被任何工作区活动标签页或正在进行的导入任务引用的孤儿大文件（单文件可达 512 MiB）。
   */
  async pruneUnreferencedImports(filesDir: string, retainedPaths: string[]): Promise<number> {
    const root: string = normalizeSandboxPath(filesDir).replace(/\/+$/, '');
    if (root.length === 0) {
      return 0;
    }
    const retained: Set<string> = new Set<string>();
    for (let i: number = 0; i < retainedPaths.length; i++) {
      const normalized: string = normalizeSandboxPath(retainedPaths[i]);
      if (normalized.length > 0) {
        retained.add(normalized);
      }
    }
    this.activeImportPaths.forEach((activePath: string) => {
      retained.add(activePath);
    });

    let names: string[] = [];
    try {
      names = await fs.listFile(root, { recursion: false });
    } catch (_err) {
      return 0;
    }

    ensureRecentMetaLoaded();
    let removedCount: number = 0;
    let metaDirty: boolean = false;
    for (let i: number = 0; i < names.length; i++) {
      const name: string = names[i];
      if (!IMPORT_CACHE_FILE_PATTERN.test(name)) {
        continue;
      }
      const fullPath: string = `${root}/${name}`;
      if (retained.has(fullPath) || this.activeImportPaths.has(fullPath)) {
        continue;
      }
      try {
        await fs.unlink(fullPath);
        removedCount++;
        probedSandboxPaths.delete(fullPath);
        if (memoryRecentMeta.delete(fullPath)) {
          metaDirty = true;
        }
      } catch (_unlinkErr) {
      }
    }
    if (metaDirty) {
      flushRecentMetaStorage();
    }
    return removedCount;
  }

  private extensionFromUri(uri: string): string {
    return layoutFileExtensionForUri(uri);
  }
}

export const fileImportService = new FileImportService();
