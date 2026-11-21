import { NativeLayoutCompareOptions, NativeLayoutCompareResult, NativeLayoutCompareLayer, NativeCompareJobOptions, NativeCompareJob, NativeCompareJobResult, NativeJobProgress } from '../../cpp/types/libhongtu/Index';
import { ExportLayoutInput, layoutExportService } from './LayoutExportService';
import { nativeHongTuService } from './NativeHongTuService';

export function emptyLayoutCompareResult(): NativeLayoutCompareResult {
  return { success: false, complete: false, geometryEqual: false, structureEqual: false,
    errorMessage: '', cellA: '', cellB: '', gridNm: 1, elapsedMs: 0, comparedLayers: 0,
    layers: [], structureDifferences: [] };
}

/** Owns the worker handle until native confirms both terminal and stopped.
 * No result, progress or cancellation is accepted using a job ID alone. */
export class LayoutCompareRun {
  readonly jobId: string;
  readonly scope: string;
  private job: NativeCompareJob;
  private stopped: boolean = false;
  constructor(job: NativeCompareJob) { this.job = job; this.jobId = job.jobId; this.scope = job.scope; }
  progress(): NativeJobProgress | undefined {
    const value: NativeJobProgress | undefined = nativeHongTuService.getJobProgress(this.jobId, this.scope);
    if (!value || value.jobId !== this.jobId || value.scope !== this.scope || value.kind !== 'compare') return undefined;
    if (value.status !== 'running' && value.terminal === true && value.workerStopped === true) this.stopped = true;
    return value;
  }
  cancel(): boolean { return nativeHongTuService.cancelJob(this.jobId, this.scope); }
  workerStopped(): boolean { return this.stopped; }
  async completion(): Promise<NativeCompareJobResult> {
    try {
      const value: NativeCompareJobResult = await this.job.completion;
      if (value.jobId !== this.jobId || value.scope !== this.scope || value.terminal !== true || value.workerStopped !== true ||
        (value.status !== 'succeeded' && value.status !== 'failed' && value.status !== 'cancelled')) {
        throw new Error('比较作业未返回有效的停止确认');
      }
      this.stopped = true;
      if (value.status === 'succeeded' && (!value.result || !value.result.success || !value.result.complete)) {
        throw new Error('比较作业缺少完整结果');
      }
      return value;
    } catch (error) {
      // Rejection/timeout is not a stop acknowledgement. A terminal native
      // record can prove cleanup is safe even when JS result allocation failed.
      this.progress();
      throw new Error(error instanceof Error ? error.message : String(error));
    }
  }
}

export function layoutCompareProgressText(progress: NativeJobProgress): string {
  let stage: string = progress.stage;
  if (stage === 'queued') stage = '等待后台作业';
  else if (stage === 'parsing') stage = '解析参考文件 B';
  else if (stage === 'reading') stage = '读取参考文件 B';
  else if (stage === 'decompressing') stage = '解压参考文件 B';
  else if (stage === 'checksum') stage = '校验参考文件 B';
  else if (stage === 'estimating') stage = '评估层级工作量';
  else if (stage === 'reading_B') stage = '读取参考文件 B';
  else if (stage.indexOf('indexing') === 0) stage = '建立比较索引';
  else if (stage.indexOf('hierarchy') === 0) stage = '展开完整层级';
  else if (stage.indexOf('union') === 0) stage = '合并图层区域';
  else if (stage === 'geometry_diff') stage = '计算图层差异';
  else if (stage.indexOf('metadata_validate') === 0) stage = '检查元数据比较预算';
  else if (stage === 'metadata_diff') stage = '严格比较端口、截面与元数据';
  else if (stage.indexOf('structure') === 0) stage = '比较结构记录';
  else if (stage === 'publishing') stage = '整理完整结果';
  else if (stage === 'succeeded') stage = '计算完成';
  else if (stage === 'cancelled') stage = '计算已停止';
  else if (stage === 'failed') stage = '计算失败';
  return progress.total > 0 ? `${stage} · ${progress.completed} / ${progress.total}` : stage;
}

export class LayoutCompareService {
  private nextRun: number = 0;
  start(input: ExportLayoutInput, pathB: string, options: NativeLayoutCompareOptions): LayoutCompareRun {
    const settings: NativeCompareJobOptions = { cellA: options.cellA, cellB: options.cellB,
      offsetX: options.offsetX, offsetY: options.offsetY, gridNm: options.gridNm,
      scope: `layout-compare-${Date.now()}-${++this.nextRun}` };
    return new LayoutCompareRun(nativeHongTuService.startCompareJob(layoutExportService.buildNativeDocument(input), pathB, settings));
  }
  async compare(input: ExportLayoutInput, pathB: string,
    options: NativeLayoutCompareOptions): Promise<NativeLayoutCompareResult> {
    return await nativeHongTuService.compareLayout(layoutExportService.buildNativeDocument(input), pathB, options);
  }
  report(result: NativeLayoutCompareResult, fileA: string, fileB: string,
    options: NativeLayoutCompareOptions): string {
    return JSON.stringify({ schema: 'hongtu-layout-comparison/v1', createdAt: new Date().toISOString(),
      fileA: fileA, fileB: fileB, options: options,
      scope: 'Full selected hierarchy; layer/datatype separated. Filled geometry is quantized to gridNm; TEXT/NODE and ordinary properties are checked as strict stored records across all Cells. Strict metadata covers all stable Cell keys, every typed Port/CrossSection field, and ordered raw layout/Cell context records across the complete Cell table. Metadata compares submitted authoritative snapshots: stored order and Cell ownership, exact binary64 numbers (including signed zero), and exact string/JSON/context bytes without type coercion or canonicalization. Standard JSON workspace/history serialization can normalize signed zero before submission. Metadata difference counts are unmatched ordered records (Cell context counts ordered Cell groups); absent tables differ from present empty groups. Structure comparison ignores the B alignment offset. Not process signoff.',
      result: result }, null, 2);
  }
  /** SVG path in world coordinates (holes retain separate rings). Canvas overlay uses even-odd fill. */
  contourPath(layer: NativeLayoutCompareLayer): string {
    let path: string = '';
    for (const ring of layer.contours) {
      if (ring.length < 3) continue;
      path += `M ${ring[0].x} ${ring[0].y} `;
      for (let i: number = 1; i < ring.length; i++) path += `L ${ring[i].x} ${ring[i].y} `;
      path += 'Z ';
    }
    return path;
  }
}
export const layoutCompareService = new LayoutCompareService();
