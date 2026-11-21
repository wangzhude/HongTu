import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { Point, Shape, ShapeType, releaseParsedGeometryBuffers } from '../models/GdsiiData';
import type { GdsiiResult, NativeParseJob, NativeJobProgress, NativeShape } from '../../cpp/types/libhongtu/Index';
import type { EditStructureState } from './EditService';
import { ImportMergeService, validateImportMergeSource } from './ImportMergeService';
import type { ImportMergeSource, ImportMergeOptions, ImportMergePreview, ImportMergeResult } from './ImportMergeService';
import { nativeHongTuService } from './NativeHongTuService';
import { cloneStructured, markImmutablePointArray } from '../common/CloneUtils';
import { cleanDbuNm } from './PrecisionService';

export interface ImportMergeFileCell { id: number; name: string; elementCount: number; referencedCellIds?: number[]; }
export interface ImportMergeFileLayer { layer: number; datatype: number; elementCount: number; }
/** UI metadata is separate from the sealed source; editing rows cannot change imported geometry. */
export interface ImportMergeFileSelection {
  token: number;
  fileName: string;
  fileType: string;
  fileSize: number;
  sourceDbuNm: number;
  topCellId: number;
  topCellIds: number[];
  cells: ImportMergeFileCell[];
  layerPairs: ImportMergeFileLayer[];
}
export interface ImportMergeFileResult {
  ok: boolean;
  cancelled: boolean;
  message: string;
  selection?: ImportMergeFileSelection;
}
interface ImportFileName { name: string; extension: string; type: string; }

function importFileName(uri: string): ImportFileName {
  if (typeof uri !== 'string' || uri.length === 0 || uri.includes('\0')) throw new Error('版图文件来源无效');
  let name: string = uri.split(/[?#]/)[0].split('/').pop() ?? '';
  try { name = decodeURIComponent(name); } catch (_error) {}
  if (name.length === 0 || name.includes('\0')) throw new Error('版图文件名称无效');
  const extension: string = name.substring(name.lastIndexOf('.')).toLowerCase();
  if (['.gds', '.gdsii', '.oas', '.oasis', '.cif', '.dxf'].indexOf(extension) < 0) throw new Error('合并导入支持 GDSII、OASIS、CIF 和 DXF');
  const type: string = extension === '.oas' || extension === '.oasis' ? 'OASIS' : extension === '.cif' ? 'CIF' : extension === '.dxf' ? 'DXF' : 'GDSII';
  return { name: name, extension: extension, type: type };
}

/** Unlike the general display adapter, no missing points, IDs or unknown kinds are repaired or dropped. */
async function isolatedSourceAsync(parsed: GdsiiResult, checkOwned: () => void): Promise<ImportMergeSource> {
  if (parsed === null || parsed.success !== true || !Array.isArray(parsed.cells) || !Array.isArray(parsed.shapes) ||
    parsed.cellCount !== parsed.cells.length || parsed.totalElements !== parsed.shapes.length ||
    !Array.isArray(parsed.topCellIds) || new Set<number>(parsed.topCellIds).size !== parsed.topCellIds.length ||
    parsed.topCellIds.some((id: number): boolean => !Number.isInteger(id) || id < 0 || id >= parsed.cells.length)) {
    throw new Error('隔离解析结果不完整或 Cell / 对象数量不一致');
  }
  const source: ImportMergeSource = { coordinateUnit: 'nm', shapes: [],
    cellNames: parsed.cells.map((cell): string => cell.name), cellProperties: parsed.cells.map((cell) => cell.properties ?? []),
    libProperties: parsed.libProperties, layerDefinitions: parsed.layerDefinitions, topCellId: parsed.primaryTopCellId,
    userUnits: parsed.userUnits, physicalUnits: parsed.physicalUnits };
  const packedCoords: Float64Array | undefined = parsed.packedCoords;
  const pointOffsets: Int32Array | undefined = parsed.shapePointOffsets;
  const pointCounts: Int32Array | undefined = parsed.shapePointCounts;
  const usePacked: boolean = packedCoords !== undefined && pointOffsets !== undefined && pointCounts !== undefined &&
    pointOffsets.length === parsed.shapes.length && pointCounts.length === parsed.shapes.length;

  let sliceShapes: number = 0;
  let slicePoints: number = 0;
  for (let i = 0; i < parsed.shapes.length; i++) {
    if ((i & 255) === 0) checkOwned();
    const native: NativeShape = parsed.shapes[i];
    if (native === null || [ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH, ShapeType.TEXT, ShapeType.INSTANCE, ShapeType.NODE].indexOf(native.type as ShapeType) < 0 ||
      !Number.isInteger(native.ownerCellId) || native.ownerCellId < 0 || native.ownerCellId >= parsed.cells.length) {
      throw new Error('隔离解析含未知对象类型或无效 Cell 归属');
    }
    let pts: Point[];
    if (usePacked && packedCoords !== undefined && pointOffsets !== undefined && pointCounts !== undefined) {
      const cnt: number = pointCounts[i];
      const off: number = pointOffsets[i];
      pts = new Array<Point>(cnt);
      let base: number = off * 2;
      for (let j = 0; j < cnt; j++) {
        pts[j] = { x: packedCoords[base], y: packedCoords[base + 1] };
        base += 2;
      }
    } else {
      const rawPts = native.points ?? [];
      pts = new Array<Point>(rawPts.length);
      for (let j = 0; j < rawPts.length; j++) {
        pts[j] = { x: rawPts[j].x, y: rawPts[j].y };
      }
    }
    markImmutablePointArray(pts);

    const shape: Shape = { id: native.id, type: native.type as ShapeType, layerNumber: native.layerNumber, datatype: native.datatype,
      ownerCellId: native.ownerCellId, points: pts, selected: false, properties: native.properties };
    if (shape.type === ShapeType.PATH) {
      shape.pathWidth = native.pathWidth; shape.pathType = native.pathType; shape.pathBeginExtension = native.pathBeginExtension;
      shape.pathEndExtension = native.pathEndExtension; shape.pathWidthAbsolute = native.pathWidthAbsolute;
    }
    if (shape.type === ShapeType.TEXT || shape.type === ShapeType.INSTANCE) {
      shape.rotation = native.rotation; shape.mirror = native.mirror; shape.magnification = native.magnification;
    }
    if (shape.type === ShapeType.TEXT) { shape.text = native.text; shape.textPresentation = native.textPresentation; }
    if (shape.type === ShapeType.INSTANCE) {
      shape.cellId = native.cellId; shape.cellName = native.cellName;
      shape.arrayCols = native.arrayCols; shape.arrayRows = native.arrayRows;
      shape.arrayColStepX = native.arrayColStepX; shape.arrayColStepY = native.arrayColStepY;
      shape.arrayRowStepX = native.arrayRowStepX; shape.arrayRowStepY = native.arrayRowStepY;
    }
    source.shapes.push(shape);
    (parsed.shapes as Array<NativeShape | undefined>)[i] = undefined;
    sliceShapes++;
    slicePoints += pts.length;
    if (sliceShapes >= 2048 || slicePoints >= 160000) {
      sliceShapes = 0;
      slicePoints = 0;
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 0); });
    }
  }
  const savedTopCellIds: number[] = parsed.topCellIds.slice();
  releaseParsedGeometryBuffers(parsed);
  parsed.topCellIds = savedTopCellIds;
  await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 0); });
  checkOwned();
  const error: string = validateImportMergeSource(source);
  if (error.length > 0) throw new Error(error);
  return source;
}

/** A separate native parse never replaces the active render/export caches or editor session. */
export class ImportMergeFileService {
  private serial: number = 0;
  private generation: number = 0;
  private busy: boolean = false;
  private job: NativeParseJob | null = null;
  private source: ImportMergeSource | null = null;
  private selection: ImportMergeFileSelection | null = null;
  private ownership: (() => boolean) | null = null;
  private cleanupWarning: string = '';
  private merge: ImportMergeService = new ImportMergeService();

  getProgress(): NativeJobProgress | undefined {
    if (this.job === null) return undefined;
    return nativeHongTuService.getJobProgress(this.job.jobId, this.job.scope);
  }

  selectionCurrent(selection: ImportMergeFileSelection): boolean {
    if (this.source === null || this.selection === null || selection === null || selection.token !== this.selection.token ||
      this.ownership === null || !this.accepts(this.ownership)) return false;
    return true;
  }

  getSourceSnapshot(selection: ImportMergeFileSelection): ImportMergeSource | null {
    if (!this.selectionCurrent(selection)) return null;
    return cloneStructured(this.source) as ImportMergeSource;
  }

  getPreviewSnapshot(preview: ImportMergePreview): ImportMergeSource | null {
    if (this.source === null || this.ownership === null || !this.accepts(this.ownership)) return null;
    return this.merge.getPreviewSnapshot(preview);
  }

  /** Cancellation is a request. pickSource waits for the existing worker before allowing another parse. */
  cancel(): void {
    this.generation++; this.source = null; this.selection = null; this.ownership = null; this.merge.cancel();
    if (this.job !== null) nativeHongTuService.cancelJob(this.job.jobId, this.job.scope);
  }

  async pickSource(context: common.UIAbilityContext, canAccept: () => boolean): Promise<ImportMergeFileResult> {
    if (this.busy) return { ok: false, cancelled: false, message: '已有导入文件正在选择或解析，请等待作业结束' };
    if (!this.accepts(canAccept)) return { ok: false, cancelled: false, message: '目标文档已变化，请重新打开导入合并' };
    this.cancel(); this.busy = true; this.cleanupWarning = '';
    const generation: number = this.generation;
    let cachePath: string = '';
    let result: ImportMergeFileResult;
    try {
      const chooser = new picker.DocumentViewPicker(context);
      const uris: string[] = await chooser.select({ fileSuffixFilters: ['合并导入版图|.gds,.gdsii,.oas,.oasis,.cif,.dxf'], maxSelectNumber: 1 });
      this.assertOwned(generation, canAccept);
      if (uris.length === 0) return { ok: false, cancelled: true, message: '已取消选择导入文件' };
      if (uris.length !== 1) throw new Error('请选择一个版图文件');
      const file: ImportFileName = importFileName(uris[0]);
      const token: number = ++this.serial;
      cachePath = `${context.cacheDir}/hongtu-merge-${Date.now()}-${token}${file.extension}`;
      const bytes: number = await this.copyCompleteFile(uris[0], cachePath, generation, canAccept);
      this.assertOwned(generation, canAccept);
      const scope: string = `merge-source-${Date.now()}-${token}`;
      const job: NativeParseJob | null = nativeHongTuService.startParseJob(cachePath,
        { scope: scope, isOasis: file.type === 'OASIS', quickScan: false, publishToActive: false });
      if (job === null || typeof job.jobId !== 'string' || job.jobId.length === 0 || job.scope !== scope) throw new Error('无法启动隔离版图解析，当前文档保留');
      this.job = job;
      const completed = await job.completion;
      this.assertOwned(generation, canAccept);
      if (completed === null || completed.jobId !== job.jobId || completed.scope !== job.scope) throw new Error('隔离解析返回了不属于本次导入的作业结果');
      if (completed.status === 'cancelled') return { ok: false, cancelled: true, message: '已取消导入解析' };
      if (completed.status !== 'succeeded' || completed.result === undefined) throw new Error(completed.message || '隔离版图解析失败');
      // bounded means the analytic count hit its saturation cap, not "safe / finite".
      if (completed.budget === undefined || completed.budget.withinBudget !== true || completed.budget.bounded !== false) throw new Error('导入文件超出可编辑预算，未产生合并源');
      if (completed.result.filePath !== cachePath || completed.result.fileSize !== bytes) throw new Error('解析文件来源或长度与已复制文件不同');
      const source: ImportMergeSource = await isolatedSourceAsync(completed.result, (): void => this.assertOwned(generation, canAccept));
      const ownerCounts: number[] = source.cellNames.map((): number => 0);
      const referenced: Set<number>[] = source.cellNames.map((): Set<number> => new Set<number>());
      const pairs: Map<string, ImportMergeFileLayer> = new Map<string, ImportMergeFileLayer>();
      for (const shape of source.shapes) {
        ownerCounts[shape.ownerCellId as number]++;
        if (shape.type === ShapeType.INSTANCE) { referenced[shape.ownerCellId as number].add(shape.cellId as number); continue; }
        const key: string = `${shape.layerNumber}/${shape.datatype}`;
        let layer: ImportMergeFileLayer | undefined = pairs.get(key);
        if (layer === undefined) { layer = { layer: shape.layerNumber, datatype: shape.datatype, elementCount: 0 }; pairs.set(key, layer); }
        layer.elementCount++;
      }
      const selection: ImportMergeFileSelection = { token: token, fileName: file.name, fileType: file.type, fileSize: bytes,
        sourceDbuNm: cleanDbuNm(source.physicalUnits), topCellId: source.topCellId, topCellIds: completed.result.topCellIds.slice(),
        cells: source.cellNames.map((name: string, id: number): ImportMergeFileCell => ({ id: id, name: name,
          elementCount: ownerCounts[id], referencedCellIds: Array.from(referenced[id]) })),
        layerPairs: Array.from(pairs.values()).sort((a: ImportMergeFileLayer, b: ImportMergeFileLayer): number => a.layer - b.layer || a.datatype - b.datatype) };
      this.assertOwned(generation, canAccept);
      this.source = source;
      this.selection = cloneStructured(selection) as ImportMergeFileSelection;
      this.ownership = canAccept;
      result = { ok: true, cancelled: false, message: `已读取 ${file.name}：${selection.cells.length} 个 Cell、${source.shapes.length} 个对象`, selection: selection };
    } catch (error) {
      this.source = null; this.selection = null; this.ownership = null; this.merge.cancel();
      const cancelled: boolean = generation !== this.generation;
      result = { ok: false, cancelled: cancelled, message: cancelled ? '已取消导入，当前文档保留' : error instanceof Error ? error.message : String(error) };
    } finally {
      this.job = null; this.busy = false;
      if (cachePath.length > 0) this.removeCache(cachePath);
    }
    if (this.cleanupWarning.length > 0) result.message += `；${this.cleanupWarning}`;
    return result;
  }

  prepare(selection: ImportMergeFileSelection, structure: EditStructureState, options: ImportMergeOptions,
    documentIdentity: string): ImportMergeResult {
    if (this.source === null || this.selection === null || selection === null || selection.token !== this.selection.token ||
      this.ownership === null || !this.accepts(this.ownership)) {
      this.merge.cancel(); return { ok: false, message: '文件合并源或目标文档已失效，请重新选择文件' };
    }
    return this.merge.prepare(this.source, structure, options, documentIdentity);
  }

  apply(preview: ImportMergePreview, structure: EditStructureState, documentIdentity: string,
    rollbackStructure?: (state: EditStructureState) => void): ImportMergeResult {
    if (this.source === null || this.ownership === null || !this.accepts(this.ownership)) {
      this.merge.cancel(); return { ok: false, message: '目标文档已变化，请重新选择导入文件' };
    }
    return this.merge.apply(preview, structure, documentIdentity, rollbackStructure);
  }

  private accepts(canAccept: () => boolean): boolean {
    try { return canAccept() === true; } catch (_error) { return false; }
  }
  private assertOwned(generation: number, canAccept: () => boolean): void {
    if (generation !== this.generation) throw new Error('已取消导入');
    if (!this.accepts(canAccept)) throw new Error('选择或解析期间目标文档已变化，请重新选择文件');
  }
  private async copyCompleteFile(uri: string, path: string, generation: number, canAccept: () => boolean): Promise<number> {
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      this.assertOwned(generation, canAccept);
      const bytes: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(bytes) || bytes <= 0 || bytes > 512 * 1024 * 1024) throw new Error('导入版图应为非空且不超过 512 MiB');
      await fs.copyFile(file.fd, path, 0);
      this.assertOwned(generation, canAccept);
      if (fs.statSync(file.fd).size !== bytes || fs.statSync(path).size !== bytes) throw new Error('导入文件在复制期间变化或复制不完整');
      return bytes;
    } finally { fs.closeSync(file); }
  }
  private removeCache(path: string): void {
    try { if (fs.accessSync(path)) fs.unlinkSync(path); }
    catch (error) { this.cleanupWarning = '导入临时文件清理失败'; console.warn(`[ImportMerge] ${this.cleanupWarning}: ${String(error)}`); }
  }
}

export const importMergeFileService: ImportMergeFileService = new ImportMergeFileService();
