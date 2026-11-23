import hongtu from 'libhongtu.so';
import type { NativeParseJobOptions, NativeParseJob, NativeDrcJobOptions, NativeDrcJob, NativeJobProgress } from '../../cpp/types/libhongtu/Index';
import type { NativeEmbeddedPythonInfo, NativeEmbeddedPythonRequest, NativeEmbeddedPythonResult } from '../../cpp/types/libhongtu/Index';
import type { NativeSyncResult, NativeLayoutCompareOptions, NativeLayoutCompareResult, NativeCompareJobOptions, NativeCompareJob } from '../../cpp/types/libhongtu/Index';
import type { GdsiiResult, HongTuNative, ParseOptions, LayoutStats, BooleanOpType, JoinType, NativeShape, RenderBatch, NativeLayerRenderStyle, NativeRenderSnapshot, GdsiiWriteResult, NativeDrcRule, NativeDrcViolation, ExportLayerStyle, ImageExportResult, PCellInfo, PCellGenerateResult, NativeNet, NativeViaLayer, NativeLvsResult } from '../../cpp/types/libhongtu/Index';

export enum NativeStatus {
  READY = 'ready',
  ERROR = 'error',
}

/** Empty polygons with success=true are a valid empty-set result. */
export interface GeometryEditResult {
  success: boolean;
  polygons: number[][];
  errorMessage: string;
  /** Local nm sagitta plus grid displacement for the renderer's round caps. */
  roundCapErrorNm?: number;
}

export class NativeCallResult {
  status: NativeStatus;
  message: string;
  version: string;

  constructor(status: NativeStatus, message: string, version: string) {
    this.status = status;
    this.message = message;
    this.version = version;
  }
}

export class NativeHongTuService {
  // 模块加载时即初始化；正常构建环境 libhongtu.so 一定存在
  private nativeModule: HongTuNative | null = hongtu as HongTuNative;

  startParseJob(filePath: string, options: NativeParseJobOptions): NativeParseJob | null {
    if (!this.ensureLoaded()) return null;
    try { return this.nativeModule!.startParseJob(filePath, options); }
    catch (error) { console.error(`[Native] startParseJob: ${error}`); return null; }
  }

  startDrcJob(snapshot: NativeRenderSnapshot, rules: NativeDrcRule[], options: NativeDrcJobOptions): NativeDrcJob | null {
    if (!this.ensureLoaded()) return null;
    try { return this.nativeModule!.startDrcJob(snapshot, rules, options); }
    catch (error) { console.error(`[Native] startDrcJob: ${error}`); return null; }
  }

  getJobProgress(jobId: string, scope: string): NativeJobProgress | undefined {
    if (!this.ensureLoaded()) return undefined;
    try { return this.nativeModule!.getJobProgress(jobId, scope); } catch (_) { return undefined; }
  }

  cancelJob(jobId: string, scope: string): boolean {
    if (!this.ensureLoaded()) return false;
    try { return this.nativeModule!.cancelJob(jobId, scope); } catch (_) { return false; }
  }

  /** 检查 native 模块是否可用（NATIVE-2: 兼容 .so 缺失时 import 返回 undefined 的情况） */
  private ensureLoaded(): boolean {
    return this.nativeModule !== null && this.nativeModule !== undefined;
  }

  /** 构造加载失败时的空结果 */
  private emptyResult(filePath: string, errorMessage: string): GdsiiResult {
    return {
      success: false,
      errorMessage,
      filePath,
      fileSize: 0,
      version: 0,
      libName: '',
      cellCount: 0,
      totalElements: 0,
      layerCount: 0,
      userUnits: 0,
      physicalUnits: 0,
      unitDescription: '',
      cells: [],
      topCellIds: [],
      primaryTopCellId: -1,
      allLayers: [],
      shapes: [],
      cellKeys: [], ports: [], crossSections: [], layoutContextRecords: [], cellContextRecords: [], portCapabilityDiagnostics: [],
    };
  }

  /** NATIVE-4: 统一错误信息提取，避免对非 Error 对象产出 [object Object] */
  private toErrorMessage(e: Object): string {
    if (e instanceof Error) {
      return e.message;
    }
    return String(e);
  }


  getEmbeddedPythonInfo(cpythonHomeDir: string = ''): NativeEmbeddedPythonInfo {
    if (!this.ensureLoaded()) {
      return {
        available: false,
        hasCPython: false,
        activeTier: 'unavailable',
        version: '',
        summary: 'native 模块未加载'
      };
    }
    try {
      return this.nativeModule!.getEmbeddedPythonInfo(cpythonHomeDir);
    } catch (error) {
      return {
        available: false,
        hasCPython: false,
        activeTier: 'unavailable',
        version: '',
        summary: this.toErrorMessage(error)
      };
    }
  }

  async runEmbeddedPythonAsync(request: NativeEmbeddedPythonRequest): Promise<NativeEmbeddedPythonResult> {
    if (!this.ensureLoaded()) {
      throw new Error('native 模块未加载，无法执行端侧内置 Python');
    }
    return await this.nativeModule!.runEmbeddedPythonAsync(request);
  }

  getVersion(): NativeCallResult {
    if (!this.ensureLoaded()) {
      return new NativeCallResult(NativeStatus.ERROR, 'native 未加载', 'N/A (native 未加载)');
    }
    try {
      const version = this.nativeModule!.version();
      // NATIVE-10: 对 native 返回值做类型校验，避免非字符串导致拼接异常
      const safeVersion: string = typeof version === 'string' ? version : 'unknown';
      return new NativeCallResult(NativeStatus.READY, 'native version loaded', safeVersion);
    } catch (error) {
      return new NativeCallResult(NativeStatus.ERROR, this.toErrorMessage(error), '');
    }
  }

  quickScan(filePath: string): GdsiiResult {
    if (!this.ensureLoaded()) {
      return this.emptyResult(filePath, 'native 未加载');
    }
    try {
      // N-1: 校验 native 返回值，避免 undefined/null/缺少 success 字段导致下游 NPE
      const format: string = this.formatOf(filePath);
      let result: GdsiiResult | undefined;
      console.info('[HongTuImport] native parse begin');
      if (format === 'oasis') {
        result = this.nativeModule!.quickOasisInfo(filePath);
      } else if (format === 'cif') {
        // CIF/DXF 为文本格式且通常较小，quickScan 直接完整解析
        result = this.nativeModule!.parseCif(filePath);
      } else if (format === 'dxf') {
        result = this.nativeModule!.parseDxf(filePath);
      } else {
        result = this.nativeModule!.quickInfo(filePath);
      }
      if (result === null || result === undefined) {
        return this.emptyResult(filePath, 'quickScan: native 返回空值');
      }
      return result;
    } catch (error) {
      const msg: string = this.toErrorMessage(error);
      console.error('quickScan 失败: ' + msg);
      return this.emptyResult(filePath, `quickScan 异常: ${msg}`);
    }
  }

  parse(filePath: string): GdsiiResult {
    if (!this.ensureLoaded()) {
      return this.emptyResult(filePath, 'native 未加载');
    }
    try {
      // N-1: 校验 native 返回值，避免 undefined/null 导致下游解析失败
      const format: string = this.formatOf(filePath);
      let result: GdsiiResult | undefined;
      if (format === 'oasis') {
        result = this.nativeModule!.parseOasis(filePath);
      } else if (format === 'cif') {
        result = this.nativeModule!.parseCif(filePath);
      } else if (format === 'dxf') {
        result = this.nativeModule!.parseDxf(filePath);
      } else {
        result = this.nativeModule!.parseGdsii(filePath);
      }
      if (result === null || result === undefined) {
        return this.emptyResult(filePath, 'parse: native 返回空值');
      }
      console.info(`[HongTuImport] native parse done shapes=${result.shapes.length} cells=${result.cells.length}`);
      return result;
    } catch (error) {
      const msg: string = this.toErrorMessage(error);
      console.error('parse 失败: ' + msg);
      return this.emptyResult(filePath, `parse 异常: ${msg}`);
    }
  }

  // ==================== V2 异步解析 ====================

  /** 异步解析文件 (不阻塞 UI 线程), 自动检测格式 */
  async parseAsync(filePath: string, options?: ParseOptions): Promise<GdsiiResult> {
    if (!this.ensureLoaded()) {
      return this.emptyResult(filePath, 'native 未加载');
    }
    try {
      const opts: ParseOptions = options ?? { isOasis: this.isOasis(filePath), quickScan: false };
      const result = await this.nativeModule!.parseAsync(filePath, opts);
      if (result === null || result === undefined) {
        return this.emptyResult(filePath, 'parseAsync: native 返回空值');
      }
      return result;
    } catch (error) {
      const msg: string = this.toErrorMessage(error);
      console.error('parseAsync 失败: ' + msg);
      return this.emptyResult(filePath, `parseAsync 异常: ${msg}`);
    }
  }

  // ==================== V2 空间查询 ====================

  /** 点查询: 返回包含 (x,y) 的所有形状 ID (使用 R-Tree, O(log N)) */
  queryPoint(x: number, y: number): number[] {
    if (!this.ensureLoaded()) return [];
    try {
      return this.nativeModule!.queryPoint(x, y) ?? [];
    } catch (error) {
      console.error('queryPoint 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  /** 范围查询: 返回与矩形区域相交的所有形状 ID */
  queryRange(x0: number, y0: number, x1: number, y1: number): number[] {
    if (!this.ensureLoaded()) return [];
    try {
      return this.nativeModule!.queryRange(x0, y0, x1, y1) ?? [];
    } catch (error) {
      console.error('queryRange 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  /** 最近邻查询: 返回距 (x,y) 最近的 k 个形状 ID */
  queryNearest(x: number, y: number, k: number): number[] {
    if (!this.ensureLoaded()) return [];
    try {
      return this.nativeModule!.queryNearest(x, y, k) ?? [];
    } catch (error) {
      console.error('queryNearest 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  // ==================== 原生 DRC（快速几何预检查）====================

  /**
   * 原生 DRC 内核检查（R-Tree + 真实边到边距离）。
   * @param ownerCellId 仅检查该 Cell 本地几何；-1 = 全部
   * @returns 违规列表；native 不可用或调用失败返回 null（区别于「0 违规」），
   *          调用方应回退 ArkTS 检查路径
   */
  runDrc(rules: NativeDrcRule[], ownerCellId: number): NativeDrcViolation[] | null {
    if (!this.ensureLoaded()) {
      return null;
    }
    try {
      return this.nativeModule!.runDrc(rules, ownerCellId) ?? null;
    } catch (error) {
      console.error('native runDrc 失败: ' + this.toErrorMessage(error));
      return null;
    }
  }

  /** Update native analysis/export input from the current editor without a disk save. */
  syncDocument(document: Object): NativeSyncResult {
    if (!this.ensureLoaded()) return { success: false, errorMessage: 'native 模块未加载' };
    try {
      return this.nativeModule!.syncDocument(document);
    } catch (error) {
      return { success: false, errorMessage: this.toErrorMessage(error) };
    }
  }

  async compareLayout(document: Object, filePathB: string,
    options: NativeLayoutCompareOptions): Promise<NativeLayoutCompareResult> {
    if (!this.ensureLoaded()) throw new Error('native 模块未加载');
    return await this.nativeModule!.compareLayout(document, filePathB, options);
  }

  startCompareJob(document: Object, filePathB: string, options: NativeCompareJobOptions): NativeCompareJob {
    if (!this.ensureLoaded()) throw new Error('native 模块未加载');
    return this.nativeModule!.startCompareJob(document, filePathB, options);
  }

  /** 将 native 布局快照写出为 OASIS（失败返回 success=false） */
  writeOasis(filePath: string): GdsiiWriteResult {
    if (!this.ensureLoaded()) {
      return {
        success: false,
        errorMessage: 'native 模块未加载',
        writtenCells: 0,
        writtenShapes: 0,
        skippedShapes: 0,
        bytes: 0,
      };
    }
    try {
      return this.nativeModule!.writeOasis(filePath);
    } catch (error) {
      return {
        success: false,
        errorMessage: this.toErrorMessage(error),
        writtenCells: 0,
        writtenShapes: 0,
        skippedShapes: 0,
        bytes: 0,
      };
    }
  }

  // ==================== PCell ====================

  /** 列出内置 PCell（native 不可用返回空列表） */
  listPCells(): PCellInfo[] {
    if (!this.ensureLoaded()) {
      return [];
    }
    try {
      return this.nativeModule!.listPCells() ?? [];
    } catch (error) {
      console.error('listPCells 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  /** 生成 PCell 几何 */
  generatePCell(name: string, params: Record<string, number | string | boolean>): PCellGenerateResult {
    if (!this.ensureLoaded()) {
      return { success: false, errorMessage: 'native 模块未加载', shapes: [], ports: [] };
    }
    try {
      return this.nativeModule!.generatePCell(name, params);
    } catch (error) {
      return { success: false, errorMessage: this.toErrorMessage(error), shapes: [], ports: [] };
    }
  }

  // ==================== LVS / 网络提取（连通性级预检查，非签核）====================

  /**
   * 连通网络提取。
   * @returns 网络数组；**null = native 不可用/无已加载布局**（调用方须回退或提示，
   *          不可把 null 当成「0 网络」——那会把「没数据」误报成「版图是空的」）
   */
  extractNets(viaLayers: NativeViaLayer[], ownerCellId: number,
              hierarchyDepth: number = 0): NativeNet[] | null {
    if (!this.ensureLoaded()) {
      return null;
    }
    try {
      return this.nativeModule!.extractNets(viaLayers, ownerCellId, hierarchyDepth) ?? null;
    } catch (error) {
      console.error('extractNets 失败: ' + this.toErrorMessage(error));
      throw new Error(`网络提取失败：${this.toErrorMessage(error)}`);
    }
  }

  /**
   * 连通性级 LVS 比对。
   * @returns 结果对象；null 仅表示 native 模块不可用/调用抛异常。
   *          「无布局 / 无参考网表 / 网表畸形」由 result.ran=false +
   *          result.status（no-layout / no-netlist / empty-schematic / empty-layout）
   *          表达，UI 必须与 mismatch 分别渲染。
   */
  runLvs(schematicNetlist: string, viaLayers: NativeViaLayer[],
         ownerCellId: number, hierarchyDepth: number = 0): NativeLvsResult | null {
    if (!this.ensureLoaded()) {
      return null;
    }
    try {
      return this.nativeModule!.runLvs(schematicNetlist, viaLayers, ownerCellId,
        hierarchyDepth) ?? null;
    } catch (error) {
      console.error('runLvs 失败: ' + this.toErrorMessage(error));
      return null;
    }
  }

  /** 导出提取网表为 SPICE 文本；native 不可用/无布局/失败返回 null */
  exportSpiceNetlist(viaLayers: NativeViaLayer[], ownerCellId: number,
                     hierarchyDepth: number = 0): string | null {
    if (!this.ensureLoaded()) {
      return null;
    }
    try {
      return this.nativeModule!.exportSpiceNetlist(viaLayers, ownerCellId,
        hierarchyDepth) ?? null;
    } catch (error) {
      console.error('exportSpiceNetlist 失败: ' + this.toErrorMessage(error));
      return null;
    }
  }

  // ==================== 图像导出 ====================

  /** 导出当前 native 布局为 SVG（失败返回 success=false 的结果） */
  exportSvg(filePath: string, maxWidth: number, maxHeight: number,
            layers: ExportLayerStyle[]): ImageExportResult {
    if (!this.ensureLoaded()) {
      return { success: false, errorMessage: 'native 模块未加载', bytes: 0 };
    }
    try {
      return this.nativeModule!.exportSvg(filePath, maxWidth, maxHeight, layers);
    } catch (error) {
      return { success: false, errorMessage: this.toErrorMessage(error), bytes: 0 };
    }
  }

  /** 导出当前 native 布局为 PNG */
  exportPng(filePath: string, width: number, height: number,
            layers: ExportLayerStyle[]): ImageExportResult {
    if (!this.ensureLoaded()) {
      return { success: false, errorMessage: 'native 模块未加载', bytes: 0 };
    }
    try {
      return this.nativeModule!.exportPng(filePath, width, height, layers);
    } catch (error) {
      return { success: false, errorMessage: this.toErrorMessage(error), bytes: 0 };
    }
  }

  // ==================== V2 布尔运算（experimental，不可签核）====================

  /** 多边形布尔运算（experimental 简化 Clipper，非工业级） */
  booleanOp(subject: number[], clip: number[], opType: BooleanOpType): number[][] {
    if (!this.ensureLoaded()) return [];
    try {
      return this.nativeModule!.booleanOp(subject, clip, opType) ?? [];
    } catch (error) {
      console.error('booleanOp 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  /** 多边形偏移（experimental） */
  offsetPolygon(points: number[], delta: number, joinType: JoinType = 0): number[] {
    if (!this.ensureLoaded()) return [];
    try {
      return this.nativeModule!.offsetPolygon(points, delta, joinType) ?? [];
    } catch (error) {
      console.error('offsetPolygon 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  // ==================== V2 几何查询 ====================
  booleanOpForEdit(subject: number[], clip: number[], opType: BooleanOpType): GeometryEditResult {
    if (!this.ensureLoaded()) return { success: false, polygons: [], errorMessage: '几何模块未加载，原图已保留' };
    try {
      const polygons: number[][] = this.nativeModule!.booleanOpForEdit(subject, clip, opType);
      if (!Array.isArray(polygons)) throw new Error('几何模块返回无效结果');
      return { success: true, polygons: polygons, errorMessage: '' };
    } catch (error) {
      return { success: false, polygons: [], errorMessage: this.toErrorMessage(error) };
    }
  }

  offsetPolygonsForEdit(points: number[][], delta: number, joinType: JoinType = 0): GeometryEditResult {
    if (!this.ensureLoaded()) return { success: false, polygons: [], errorMessage: '几何模块未加载，原图已保留' };
    try {
      const polygons: number[][] = this.nativeModule!.offsetPolygonsForEdit(points, delta, joinType);
      if (!Array.isArray(polygons)) throw new Error('几何模块返回无效结果');
      return { success: true, polygons: polygons, errorMessage: '' };
    } catch (error) {
      return { success: false, polygons: [], errorMessage: this.toErrorMessage(error) };
    }
  }

  regionBooleanForEdit(subject: number[][], clip: number[][], opType: BooleanOpType, gridNm: number): GeometryEditResult {
    if (!this.ensureLoaded()) return { success: false, polygons: [], errorMessage: '几何模块未加载，原图已保留' };
    try {
      const polygons: number[][] = this.nativeModule!.regionBooleanForEdit(subject, clip, opType, gridNm);
      if (!Array.isArray(polygons)) throw new Error('几何模块返回无效结果');
      return { success: true, polygons: polygons, errorMessage: '' };
    } catch (error) {
      return { success: false, polygons: [], errorMessage: this.toErrorMessage(error) };
    }
  }

  pathRegionForEdit(points: number[], widthNm: number, pathType: number, beginExtensionNm: number,
    endExtensionNm: number, worldScale: number, widthAbsolute: boolean, gridNm: number): GeometryEditResult {
    if (!this.ensureLoaded()) return { success: false, polygons: [], errorMessage: '几何模块未加载，原图已保留' };
    try {
      const polygons: number[][] = this.nativeModule!.pathRegionForEdit(points, widthNm, pathType,
        beginExtensionNm, endExtensionNm, worldScale, widthAbsolute, gridNm);
      if (!Array.isArray(polygons)) throw new Error('几何模块返回无效结果');
      const error: number = pathType === 1 ? (widthAbsolute ? widthNm / worldScale : widthNm) *
        0.5 * (1 - Math.cos(Math.PI / 16)) + gridNm / Math.sqrt(2) : 0;
      return { success: true, polygons: polygons, errorMessage: '', roundCapErrorNm: error };
    } catch (error) {
      return { success: false, polygons: [], errorMessage: this.toErrorMessage(error) };
    }
  }


  /** Full-layer expression PATH contract; callers retain the document on any rejection. */
  pathRegionWholeDPathSimple(points: number[], widthNm: number, pathType: number, beginExtensionNm: number,
    endExtensionNm: number, worldScale: number, widthAbsolute: boolean, gridNm: number): GeometryEditResult {
    if (!this.ensureLoaded()) return { success: false, polygons: [], errorMessage: '几何模块未加载，原图已保留' };
    try {
      const polygons: number[][] = this.nativeModule!.pathRegionWholeDPathSimple(points, widthNm, pathType,
        beginExtensionNm, endExtensionNm, worldScale, widthAbsolute, gridNm);
      if (!Array.isArray(polygons)) throw new Error('几何模块返回无效结果');
      const bound: number = pathType === 1 ? (widthAbsolute ? widthNm / worldScale : widthNm) *
        0.5 * (1 / Math.cos(Math.PI / 32) - 1) + gridNm / Math.sqrt(2) : 0;
      return { success: true, polygons: polygons, errorMessage: '', roundCapErrorNm: bound };
    } catch (error) {
      const detail: string = this.toErrorMessage(error);
      console.error('全层表达式 PATH 轮廓转换失败: ' + detail);
      if (detail.includes('complex-contour-not-supported')) {
        return { success: false, polygons: [], errorMessage: '回折、相交或量化后边界触碰的 PATH 暂不能参与全层表达式，请先用多边形重绘所需轮廓后再处理；原图已保留' };
      }
      if (detail.includes('contour-check-budget') || detail.includes('vertex-budget') || detail.includes('spine-budget')) {
        return { success: false, polygons: [], errorMessage: 'PATH 顶点或轮廓检查超过预算，请简化路径后再处理；原图已保留' };
      }
      return { success: false, polygons: [], errorMessage: 'PATH 轮廓转换失败，请检查宽度、端帽、网格和顶点，或用多边形重绘所需轮廓后再处理；原图已保留' };
    }
  }

  /** 边到边距离 (nm)（experimental） */
  polygonDistance(pointsA: number[], pointsB: number[]): number {
    if (!this.ensureLoaded()) return Infinity;
    try {
      return this.nativeModule!.polygonDistance(pointsA, pointsB);
    } catch (error) {
      console.error('polygonDistance 失败: ' + this.toErrorMessage(error));
      return Infinity;
    }
  }

  /** 计算多边形面积 (nm²) */
  polygonArea(points: number[]): number {
    if (!this.ensureLoaded()) return 0;
    try {
      return this.nativeModule!.polygonArea(points);
    } catch (error) {
      console.error('polygonArea 失败: ' + this.toErrorMessage(error));
      return 0;
    }
  }

  /** 点在多边形内判定: +1=内部, 0=边界, -1=外部 */
  pointInPolygon(x: number, y: number, points: number[]): number {
    if (!this.ensureLoaded()) return -1;
    try {
      return this.nativeModule!.pointInPolygon(x, y, points);
    } catch (error) {
      console.error('pointInPolygon 失败: ' + this.toErrorMessage(error));
      return -1;
    }
  }

  // ==================== V2 布局管理 ====================

  /**
   * Native 结构化写出 GDSII。失败返回 success=false，调用方回退 ArkTS 导出。
   */
  writeGdsii(filePath: string): GdsiiWriteResult {
    const empty: GdsiiWriteResult = {
      success: false,
      errorMessage: 'native 未加载',
      writtenCells: 0,
      writtenShapes: 0,
      skippedShapes: 0,
      bytes: 0,
    };
    if (!this.ensureLoaded()) {
      return empty;
    }
    try {
      if (this.nativeModule!.writeGdsii === undefined) {
        empty.errorMessage = 'writeGdsii 未导出';
        return empty;
      }
      const result: GdsiiWriteResult | undefined = this.nativeModule!.writeGdsii(filePath);
      if (result === null || result === undefined) {
        empty.errorMessage = 'writeGdsii: native 返回空值';
        return empty;
      }
      return result;
    } catch (error) {
      empty.errorMessage = this.toErrorMessage(error);
      console.error('writeGdsii 失败: ' + empty.errorMessage);
      return empty;
    }
  }

  /**
   * 用编辑后的文档（cellNames + shapes）经 native 写出，并刷新 g_layout。
   * shapes 的 points 应为扁平 number[]。
   */
  writeGdsiiDocument(filePath: string, document: Object): GdsiiWriteResult {
    const empty: GdsiiWriteResult = {
      success: false,
      errorMessage: 'native 未加载',
      writtenCells: 0,
      writtenShapes: 0,
      skippedShapes: 0,
      bytes: 0,
    };
    if (!this.ensureLoaded()) {
      return empty;
    }
    try {
      if (this.nativeModule!.writeGdsiiDocument === undefined) {
        empty.errorMessage = 'writeGdsiiDocument 未导出';
        return empty;
      }
      const result: GdsiiWriteResult | undefined = this.nativeModule!.writeGdsiiDocument(filePath, document);
      if (result === null || result === undefined) {
        empty.errorMessage = 'writeGdsiiDocument: native 返回空值';
        return empty;
      }
      return result;
    } catch (error) {
      empty.errorMessage = this.toErrorMessage(error);
      console.error('writeGdsiiDocument 失败: ' + empty.errorMessage);
      return empty;
    }
  }

  /**
   * KLayout 语义层级展开：从 cellId 按 hierarchyDepth 变换展开子 Cell 几何。
   * native 不可用或失败时返回空数组，调用方回退到 HierarchyExpandService。
   */
  expandHierarchy(cellId: number, hierarchyDepth: number): NativeShape[] {
    if (!this.ensureLoaded()) {
      return [];
    }
    try {
      if (this.nativeModule!.expandHierarchy === undefined) {
        return [];
      }
      const result: NativeShape[] | undefined = this.nativeModule!.expandHierarchy(cellId, hierarchyDepth);
      if (result === null || result === undefined) {
        return [];
      }
      return result;
    } catch (error) {
      console.error('expandHierarchy 失败: ' + this.toErrorMessage(error));
      return [];
    }
  }

  /**
   * Native 展开 → RenderBatch（可选视口裁剪）。null 表示失败；空数组是有效的空视口。
   */
  expandHierarchyToBatches(
    cellId: number,
    hierarchyDepth: number,
    minX?: number,
    minY?: number,
    maxX?: number,
    maxY?: number
  ): RenderBatch[] | null {
    if (!this.ensureLoaded()) {
      return null;
    }
    try {
      if (this.nativeModule!.expandHierarchyToBatches === undefined) {
        return null;
      }
      const result: RenderBatch[] | undefined = this.nativeModule!.expandHierarchyToBatches(
        cellId,
        hierarchyDepth,
        minX ?? 1,
        minY ?? 1,
        maxX ?? 0,
        maxY ?? 0
      );
      if (result === null || result === undefined) {
        return null;
      }
      return result;
    } catch (error) {
      console.error('expandHierarchyToBatches 失败: ' + this.toErrorMessage(error));
      return null;
    }
  }

  /** Direct C++ scene-to-GPU path. null means the capability is unavailable. */
  renderHierarchyToSurface(cellId: number, hierarchyDepth: number,
    minX: number, minY: number, maxX: number, maxY: number,
    styles: NativeLayerRenderStyle[], snapshot?: NativeRenderSnapshot): boolean | null {
    if (!this.ensureLoaded() || this.nativeModule!.renderHierarchyToSurface === undefined) return null;
    try {
      const rendered: boolean = this.nativeModule!.renderHierarchyToSurface(cellId, hierarchyDepth,
        minX, minY, maxX, maxY, styles, snapshot);
      if (!rendered && snapshot !== undefined) {
        console.warn(`[HongTuDirect] edited submission declined: cell=${cellId}, cells=${snapshot.cellNames.length}, shapes=${snapshot.shapes.length}`);
      }
      return rendered;
    } catch (error) {
      console.error('renderHierarchyToSurface 失败: ' + this.toErrorMessage(error));
      return false;
    }
  }

  /** 获取当前加载布局的统计信息 */
  getLayoutStats(): LayoutStats | null {
    if (!this.ensureLoaded()) return null;
    try {
      return this.nativeModule!.getLayoutStats();
    } catch (error) {
      console.error('getLayoutStats 失败: ' + this.toErrorMessage(error));
      return null;
    }
  }

  private isOasis(filePath: string): boolean {
    const lower = filePath.toLowerCase();
    return lower.endsWith('.oas') || lower.endsWith('.oasis');
  }

  /** 按扩展名判定文件格式：'gds' | 'oasis' | 'cif' | 'dxf' */
  private formatOf(filePath: string): string {
    const lower = filePath.toLowerCase();
    if (lower.endsWith('.oas') || lower.endsWith('.oasis')) {
      return 'oasis';
    }
    if (lower.endsWith('.cif')) {
      return 'cif';
    }
    if (lower.endsWith('.dxf')) {
      return 'dxf';
    }
    return 'gds';
  }
}

export const nativeHongTuService = new NativeHongTuService();
