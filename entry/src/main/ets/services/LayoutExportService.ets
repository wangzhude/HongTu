import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Shape, ShapeType, Point, normalizePropRecords, MAX_PROPS_PER_OWNER, packShapesCoordinates } from '../models/GdsiiData';
import { UiLayer } from '../common/types';
import { nativeHongTuService } from './NativeHongTuService';
import { safeFilePublishService } from './SafeFilePublishService';
import { LayoutSemanticState, LayoutContextRecord, validateLayoutSemantics, layoutUtf8Bytes } from '../models/LayoutPort';
import { buildPortContextPayload, PortContextPayload, contextRecordBytes } from './LayoutPortInteropCodec';
import type { GdsiiWriteResult, ExportLayerStyle, ImageExportResult, LayoutPropRecord, SourceLayerDefinition, QuantizationReport } from '../../cpp/types/libhongtu/Index';

interface GdsRecord {
  type: number;
  dataType: number;
}

const REC_HEADER: GdsRecord = { type: 0x00, dataType: 0x02 };
const REC_BGNLIB: GdsRecord = { type: 0x01, dataType: 0x02 };
const REC_LIBNAME: GdsRecord = { type: 0x02, dataType: 0x06 };
const REC_UNITS: GdsRecord = { type: 0x03, dataType: 0x05 };
const REC_ENDLIB: GdsRecord = { type: 0x04, dataType: 0x00 };
const REC_BGNSTR: GdsRecord = { type: 0x05, dataType: 0x02 };
const REC_STRNAME: GdsRecord = { type: 0x06, dataType: 0x06 };
const REC_ENDSTR: GdsRecord = { type: 0x07, dataType: 0x00 };
const REC_BOUNDARY: GdsRecord = { type: 0x08, dataType: 0x00 };
const REC_PATH: GdsRecord = { type: 0x09, dataType: 0x00 };
const REC_SREF: GdsRecord = { type: 0x0A, dataType: 0x00 };
const REC_AREF: GdsRecord = { type: 0x0B, dataType: 0x00 };
const REC_COLROW: GdsRecord = { type: 0x13, dataType: 0x02 };
const REC_BGNEXTN: GdsRecord = { type: 0x30, dataType: 0x03 };
const REC_ENDEXTN: GdsRecord = { type: 0x31, dataType: 0x03 };
const REC_TEXT: GdsRecord = { type: 0x0C, dataType: 0x00 };
const REC_NODE: GdsRecord = { type: 0x15, dataType: 0x00 };
const REC_LAYER: GdsRecord = { type: 0x0D, dataType: 0x02 };
const REC_DATATYPE: GdsRecord = { type: 0x0E, dataType: 0x02 };
const REC_NODETYPE: GdsRecord = { type: 0x2A, dataType: 0x02 };
const REC_WIDTH: GdsRecord = { type: 0x0F, dataType: 0x03 };
const REC_XY: GdsRecord = { type: 0x10, dataType: 0x03 };
const REC_ENDEL: GdsRecord = { type: 0x11, dataType: 0x00 };
const REC_SNAME: GdsRecord = { type: 0x12, dataType: 0x06 };
const REC_STRANS: GdsRecord = { type: 0x1A, dataType: 0x01 };
const REC_MAG: GdsRecord = { type: 0x1B, dataType: 0x05 };
const REC_ANGLE: GdsRecord = { type: 0x1C, dataType: 0x05 };
const REC_TEXTTYPE: GdsRecord = { type: 0x16, dataType: 0x02 };
const REC_PRESENTATION: GdsRecord = { type: 0x17, dataType: 0x01 };
const REC_STRING: GdsRecord = { type: 0x19, dataType: 0x06 };
const REC_PATHTYPE: GdsRecord = { type: 0x21, dataType: 0x02 };
/** 属性对：PROPATTR 必须紧邻它所修饰的 PROPVALUE（规范码，与 gdsii_writer.cpp 一致） */
const REC_PROPATTR: GdsRecord = { type: 0x2B, dataType: 0x02 };
const REC_PROPVALUE_DT: number = 0x2C;

const MAX_XY_POINTS_PER_RECORD: number = 8191;
const MAX_ELEMENT_POINTS: number = 25 * 1000 * 1000;

export interface ExportLayoutInput extends LayoutSemanticState {
  layerDefinitions?: SourceLayerDefinition[];
  shapes: Shape[];
  layers: UiLayer[];
  libName: string;
  topCellName: string;
  sourcePath: string;
  /**
   * Cell 名表：index = cellId（与 ownerCellId / INSTANCE.cellId 对齐）。
   * 提供时按 ownerCell 结构化写出；缺失时回退到「全部进 Top + childCells」兼容路径。
   */
  cellNames?: string[];
  /** Top Cell 的 id（默认 0）；无 ownerCellId 的图形归入此 cell */
  topCellId?: number;
  /** 用户单位 / 物理单位（米），缺省 0.001 / 1e-9 */
  userUnits?: number;
  physicalUnits?: number;
  /** FILE-02 旧兼容路径数据；仅无 cellNames 时使用，结构化保存以 shapes 为唯一真源。 */
  childCells?: ChildCellExport[];
  /**
   * M2：未编辑时优先 native writeGdsii（g_lastParseResult）。
   * 编辑后请 false/省略，走 ArkTS 结构化写出。
   */
  preferNativeWriter?: boolean;
  /** 原始 GDS 沙箱文件仍与当前文档逐字节对应时才允许直接复制。 */
  preferOriginalSourceCopy?: boolean;
  /** native 临时写出目录（如 context.cacheDir）；缺省则不尝试 native */
  nativeTempDir?: string;
  /**
   * 结构级属性：index 与 cellNames 对齐（可选，整字段缺省 = 不写结构属性）。
   * 由 LayoutDocument.cells[i].properties 原样带来，两条写出路径（native document /
   * ArkTS 回退字节流）都会写回 PROPATTR/PROPVALUE 与 OASIS 一般属性。
   */
  cellProperties?: LayoutPropRecord[][];
  /** 库/数据库级属性（可选）；来自 LayoutDocument.libProperties */
  libProperties?: LayoutPropRecord[];
}

/** FILE-02: 子 cell 导出条目 */
export interface ChildCellExport {
  name: string;
  shapes: Shape[];
}

/** EXPORT-3: buildGdsiiBufferWithStats 的返回结构，避免用实例可变字段传递统计数 */
interface GdsiiBufferResult {
  buffer: ArrayBuffer;
  writtenShapes: number;
  skippedShapes: number;
  quantization?: QuantizationReport;
}

export interface SharedImageCacheResult {
  sandboxPath: string;
  fileName: string;
  bytes: number;
}

export interface LayoutExportResult {
  quantization?: QuantizationReport;
  uri: string;
  fileName: string;
  bytes: number;
  shapeCount: number;
  skippedShapeCount: number;
  warnings: string[];
  /** GDS 保存时 native 布局快照与本次输入一致；其他导出类型不设置。 */
  nativeSnapshotSynchronized?: boolean;
  /** 仅原始文件复制分支为 true；调用方用它防止编辑后再次复制旧源文件。 */
  originalSourceCopied?: boolean;
}

/** Only an empty image-save picker result represents a normal user cancellation. */
export class ImageExportCancelledError extends Error {
  constructor() { super('未选择保存位置'); }
}

interface ShapeBoundsForExport {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

export class GdsByteWriter {
  private buf: Uint8Array = new Uint8Array(65536);
  private offset: number = 0;

  get length(): number {
    return this.offset;
  }

  private ensureCapacity(extraBytes: number): void {
    const required: number = this.offset + extraBytes;
    if (required <= this.buf.byteLength) {
      return;
    }
    let nextCap: number = Math.max(65536, this.buf.byteLength);
    while (nextCap < required) {
      nextCap = nextCap < 33554432 ? nextCap * 2 : nextCap + Math.max(16777216, extraBytes);
    }
    const grown: Uint8Array = new Uint8Array(nextCap);
    grown.set(this.buf.subarray(0, this.offset), 0);
    this.buf = grown;
  }

  writeRecord(record: GdsRecord, data: number[] = []): void {
    const len: number = data.length + 4;
    if (len > 65535) {
      throw new Error(`GDSII record too large: ${len} bytes`);
    }
    this.ensureCapacity(len);
    this.writeUInt16Unchecked(len);
    this.buf[this.offset++] = record.type & 0xFF;
    this.buf[this.offset++] = record.dataType & 0xFF;
    for (let i = 0; i < data.length; i++) {
      this.buf[this.offset++] = data[i] & 0xFF;
    }
  }

  writeInt2Record(record: GdsRecord, values: number[]): void {
    const len: number = values.length * 2 + 4;
    if (len > 65535) {
      throw new Error(`GDSII record too large: ${len} bytes`);
    }
    this.ensureCapacity(len);
    this.writeUInt16Unchecked(len);
    this.buf[this.offset++] = record.type & 0xFF;
    this.buf[this.offset++] = record.dataType & 0xFF;
    for (let i = 0; i < values.length; i++) {
      const v: number = values[i] & 0xFFFF;
      this.buf[this.offset++] = (v >> 8) & 0xFF;
      this.buf[this.offset++] = v & 0xFF;
    }
  }

  writeInt4Record(record: GdsRecord, values: number[]): void {
    const len: number = values.length * 4 + 4;
    if (len > 65535) {
      throw new Error(`GDSII record too large: ${len} bytes`);
    }
    this.ensureCapacity(len);
    this.writeUInt16Unchecked(len);
    this.buf[this.offset++] = record.type & 0xFF;
    this.buf[this.offset++] = record.dataType & 0xFF;
    for (let i = 0; i < values.length; i++) {
      this.writeInt32Unchecked(values[i]);
    }
  }

  writePointSliceXYRecord(record: GdsRecord, points: Point[], start: number, count: number,
                          mapCoord: (nm: number) => number): void {
    const len: number = count * 8 + 4;
    if (len > 65535) {
      throw new Error(`GDSII record too large: ${len} bytes`);
    }
    this.ensureCapacity(len);
    this.writeUInt16Unchecked(len);
    this.buf[this.offset++] = record.type & 0xFF;
    this.buf[this.offset++] = record.dataType & 0xFF;
    const end: number = start + count;
    for (let i = start; i < end; i++) {
      this.writeInt32Unchecked(mapCoord(points[i].x));
      this.writeInt32Unchecked(mapCoord(points[i].y));
    }
  }

  writeStringRecord(record: GdsRecord, value: string): void {
    const context: LayoutContextRecord = { encoding: 'utf8', value: value };
    const data: number[] = contextRecordBytes(context);
    if (data.length % 2 !== 0) {
      data.push(0);
    }
    this.writeRecord(record, data);
  }

  writeReal8Record(record: GdsRecord, values: number[]): void {
    const len: number = values.length * 8 + 4;
    if (len > 65535) {
      throw new Error(`GDSII record too large: ${len} bytes`);
    }
    this.ensureCapacity(len);
    this.writeUInt16Unchecked(len);
    this.buf[this.offset++] = record.type & 0xFF;
    this.buf[this.offset++] = record.dataType & 0xFF;
    for (let i = 0; i < values.length; i++) {
      this.writeGdsReal8Unchecked(values[i]);
    }
  }

  toArrayBuffer(): ArrayBuffer {
    return this.buf.buffer.slice(0, this.offset);
  }

  private writeUInt16Unchecked(value: number): void {
    this.buf[this.offset++] = (value >> 8) & 0xFF;
    this.buf[this.offset++] = value & 0xFF;
  }

  private writeInt32Unchecked(value: number): void {
    const v: number = this.clampInt32(Math.round(value));
    this.buf[this.offset++] = (v >> 24) & 0xFF;
    this.buf[this.offset++] = (v >> 16) & 0xFF;
    this.buf[this.offset++] = (v >> 8) & 0xFF;
    this.buf[this.offset++] = v & 0xFF;
  }

  private writeGdsReal8Unchecked(value: number): void {
    if (value === 0 || !isFinite(value)) {
      for (let i = 0; i < 8; i++) {
        this.buf[this.offset++] = 0;
      }
      return;
    }

    const sign: number = value < 0 ? 0x80 : 0;
    let normalized: number = Math.abs(value);
    let exponent: number = 64;

    while (normalized >= 1.0) {
      normalized /= 16.0;
      exponent++;
    }
    while (normalized < 0.0625) {
      normalized *= 16.0;
      exponent--;
    }

    this.buf[this.offset++] = sign | (exponent & 0x7F);
    for (let i = 0; i < 7; i++) {
      normalized *= 256.0;
      const b: number = Math.floor(normalized);
      this.buf[this.offset++] = b & 0xFF;
      normalized -= b;
    }
  }

  private clampInt32(value: number): number {
    if (value > 2147483647) {
      return 2147483647;
    }
    if (value < -2147483648) {
      return -2147483648;
    }
    return value;
  }
}

class LayoutExportService {
  private quantization: QuantizationReport = { dbuNm: 1, examinedValueCount: 0, quantizedValueCount: 0, quantizedShapeCount: 0, maximumDeviationNm: 0 };
  private quantizedShapeIds: Set<number> = new Set<number>();
  private currentQuantizationShapeId: number = -1;
  /** 当前写出会话的 nm→dbu 缩放（由 physicalUnits 推导；1e-9 时为 1） */
  private nmToDbuScale: number = 1;

  private setNmToDbuFromPhysical(physicalUnits: number): void {
    const scaleNm: number = physicalUnits * 1e9;
    this.nmToDbuScale = scaleNm > 0 ? (1.0 / scaleNm) : 1;
  }

  private nmToDbu(value: number): number {
    const raw: number = value * this.nmToDbuScale;
    const rounded: number = raw < 0 ? -Math.round(-raw) : Math.round(raw);
    if (!Number.isFinite(raw) || rounded < -2147483648 || rounded > 2147483647) {
      throw new Error('GDSII 坐标或宽度超出 32 位数据库单位范围，保存已取消');
    }
    this.quantization.examinedValueCount++;
    const deviation: number = Math.abs(value - rounded / this.nmToDbuScale);
    if (deviation > this.quantization.dbuNm * 1e-9) {
      this.quantization.quantizedValueCount++;
      this.quantization.maximumDeviationNm = Math.max(this.quantization.maximumDeviationNm, deviation);
      this.quantizedShapeIds.add(this.currentQuantizationShapeId);
      this.quantization.quantizedShapeCount = this.quantizedShapeIds.size;
    }
    return rounded;
  }

  async exportGdsWithPicker(
    context: common.UIAbilityContext,
    input: ExportLayoutInput
  ): Promise<LayoutExportResult> {
    const fileName: string = this.defaultFileName(input);
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save({
      newFileNames: [fileName],
      fileSuffixChoices: ['GDSII Stream|.gds'],
    });

    if (uris.length === 0) {
      throw new Error('未选择保存位置');
    }

    const uri: string = uris[0];
    return await this.saveGdsToUri(context, input, uri);
  }

  /** Save to a previously authorized picker URI. Callers mark clean only on success. */
  async saveGdsToUri(context: common.UIAbilityContext, input: ExportLayoutInput,
    uri: string): Promise<LayoutExportResult> {
    if (uri.length === 0) throw new Error('保存目标为空');
    const fileName: string = this.defaultFileName(input);
    const warnings: string[] = [];
    const nativeTempDir: string = input.nativeTempDir ?? context.cacheDir;
    const savedFileName: string = this.savedDisplayName(uri, fileName);
    let nativeSnapshotSynchronized: boolean = false;

    // 未编辑的 GDS 直接复制已解析的沙箱源文件。reader 的工作模型会把 AREF
    // 展成多个实例，且并非每类原始记录都可重建；重序列化会无谓改写文件结构。
    // native 快照可用不等于源文件仍是最新内容：编辑并保存后快照会更新，
    // 但 currentFilePath 仍指向打开时的旧文件，只有独立的源文件标志能允许复制。
    const sourceLower: string = input.sourcePath.toLowerCase();
    if (input.preferNativeWriter === true && input.preferOriginalSourceCopy === true &&
      (sourceLower.endsWith('.gds') || sourceLower.endsWith('.gdsii'))) {
      try {
        const sourceBytes: number = fs.statSync(input.sourcePath).size;
        this.validateOutputFile(input.sourcePath, sourceBytes);
        await this.copyFileToUri(input.sourcePath, uri);
        warnings.push('未编辑 GDS 按原文件逐字节保存。');
        return {
          uri: uri,
          fileName: savedFileName,
          bytes: sourceBytes,
          shapeCount: input.shapes.length,
          skippedShapeCount: 0,
          warnings: warnings,
          nativeSnapshotSynchronized: true,
          originalSourceCopied: true,
        };
      } catch (copyErr) {
        throw new Error(`保存原文件失败，目标未成功发布：${String(copyErr)}`);
      }
    }

    // M2: 有 cacheDir 时优先 native 写出（未编辑用快照；有 shapes 时用 document 同步 g_layout）
    if (nativeTempDir.length > 0) {
      const nativePath: string = this.nextTemporaryPath(nativeTempDir, '.gds');
      try {
      let nw: GdsiiWriteResult;
      // dirty / 有编辑 shapes：传完整 document，native 写后刷新 g_layout
      if (input.preferNativeWriter !== true && input.cellNames !== undefined && input.cellNames.length > 0) {
        nw = nativeHongTuService.writeGdsiiDocument(nativePath, this.buildNativeDocument(input));
        if (nw.success) {
          warnings.push(`native writeGdsiiDocument：${nw.writtenCells} Cell / ${nw.writtenShapes} 图形。`);
        } else {
          warnings.push(`native document write 跳过（${nw.errorMessage}），回退 ArkTS。`);
        }
      } else if (input.preferNativeWriter === true) {
        nw = nativeHongTuService.writeGdsii(nativePath);
        if (nw.success) {
          warnings.push(`native writeGdsii：${nw.writtenCells} Cell / ${nw.writtenShapes} 图形。`);
        } else {
          warnings.push(`native write 跳过（${nw.errorMessage}），回退 ArkTS。`);
        }
      } else {
        nw = {
          success: false,
          errorMessage: 'skip native',
          writtenCells: 0,
          writtenShapes: 0,
          skippedShapes: 0,
          bytes: 0,
        };
      }
      // writeGdsiiDocument 在写成功后提交完整输入到 g_layout；writeGdsii 则复用
      // 调用方确认过的现有快照。回退写出成功本身不代表 native 快照已更新。
      nativeSnapshotSynchronized = nw.success;
      if (nw.success && nw.skippedShapes > 0) {
        warnings.push(`native 写出跳过 ${nw.skippedShapes} 个图形，尝试 ArkTS 完整写出。`);
      }
      if (nw.success && nw.skippedShapes === 0) {
        this.appendQuantizationWarning(nw.quantization, warnings);
        try {
          this.validateOutputFile(nativePath, nw.bytes);
          await this.copyFileToUri(nativePath, uri);
          return {
            uri: uri,
            fileName: savedFileName,
            bytes: nw.bytes,
            shapeCount: nw.writtenShapes,
            skippedShapeCount: nw.skippedShapes,
            warnings: warnings,
            quantization: nw.quantization,
            nativeSnapshotSynchronized: nativeSnapshotSynchronized,
          };
        } catch (copyErr) {
          throw new Error(`目标文件发布失败：${String(copyErr)}`);
        }
      }
      } finally { this.removeTemporary(nativePath); }
    }

    const result: GdsiiBufferResult = this.buildGdsiiBufferWithStats(input, warnings);
    if (result.skippedShapes > 0) {
      throw new Error(`保存中止：${result.skippedShapes} 个图形无法完整写出，原文档仍未保存。`);
    }
    this.writeBufferToUri(result.buffer, uri, nativeTempDir.length > 0 ? nativeTempDir : context.cacheDir);

    return {
      uri: uri,
      fileName: savedFileName,
      bytes: result.buffer.byteLength,
      shapeCount: result.writtenShapes,
      skippedShapeCount: result.skippedShapes,
      warnings: warnings,
      quantization: result.quantization,
      nativeSnapshotSynchronized: nativeSnapshotSynchronized,
    };
  }

  /** Write the current editor snapshot to an app-owned path without a picker or dirty reset.
   * The previous file survives serialization/short-write failures; publish by rename only
   * after all bytes are present. This is used by draft recovery and Python input snapshots.
   */
  async writeGdsToPath(input: ExportLayoutInput, path: string): Promise<LayoutExportResult> {
    if (path.length === 0) throw new Error('快照目标路径为空');
    const staging: string = `${path}.pending-${Date.now()}-${++this.temporarySequence}`;
    const warnings: string[] = [];
    let bytes: number = 0;
    let count: number = 0;
    let synchronized: boolean = false;
    let quantization: QuantizationReport | undefined = undefined;
    try {
      const written: GdsiiWriteResult = nativeHongTuService.writeGdsiiDocument(staging,
        this.buildNativeDocument(input));
      if (written.success && written.skippedShapes === 0) {
        bytes = written.bytes;
        count = written.writtenShapes;
        synchronized = true;
        quantization = written.quantization;
        this.appendQuantizationWarning(quantization, warnings);
      } else {
        if (written.skippedShapes > 0) throw new Error(`快照中止：${written.skippedShapes} 个图形无法完整写出`);
        warnings.push(`native 写出不可用，使用结构化回退：${written.errorMessage}`);
        const fallback: GdsiiBufferResult = this.buildGdsiiBufferWithStats(input, warnings);
        if (fallback.skippedShapes > 0) throw new Error(`快照中止：${fallback.skippedShapes} 个图形无法完整写出`);
        this.writeBufferToOwnedPath(fallback.buffer, staging);
        bytes = fallback.buffer.byteLength;
        count = fallback.writtenShapes;
        quantization = fallback.quantization;
      }
      if (bytes <= 0 || fs.statSync(staging).size !== bytes) throw new Error('快照文件长度校验失败');
      fs.renameSync(staging, path);
      return { uri: path, fileName: this.savedDisplayName(path, this.defaultFileName(input)),
        bytes: bytes, shapeCount: count, skippedShapeCount: 0, warnings: warnings,
        quantization: quantization,
        nativeSnapshotSynchronized: synchronized, originalSourceCopied: false };
    } finally {
      try { if (fs.accessSync(staging)) fs.unlinkSync(staging); } catch (_error) {}
    }
  }

  /**
   * 导出当前 native 布局快照为 OASIS（.oas）。
   * 先同步并写出、校验沙箱文件，再 picker → 拷贝 → 清理。
   * picker 返回后再次调用 prepareNative 校验文档，dirty 无需清除。
   */
  async exportOasisWithPicker(
    context: common.UIAbilityContext,
    nativeTempDir: string,
    baseName: string,
    prepareNative?: () => void
  ): Promise<LayoutExportResult> {
    const fileName: string = baseName + '.oas';
    const nativePath: string = this.nextTemporaryPath(nativeTempDir, '.oas');
    try {
      if (prepareNative !== undefined) prepareNative();
      const wr: GdsiiWriteResult = nativeHongTuService.writeOasis(nativePath);
      if (!wr.success) {
        throw new Error(wr.errorMessage.length > 0 ? wr.errorMessage : 'OASIS 写出失败');
      }
      if (wr.skippedShapes > 0) throw new Error(`OASIS 导出中止：${wr.skippedShapes} 个图形无法完整写出`);
      this.validateOutputFile(nativePath, wr.bytes);
      const documentPicker = new picker.DocumentViewPicker(context);
      const uris: string[] = await documentPicker.save({
        newFileNames: [fileName],
        fileSuffixChoices: ['OASIS|.oas'],
      });
      if (uris.length === 0) {
        throw new Error('未选择保存位置');
      }
      const uri: string = uris[0];
      if (prepareNative !== undefined) prepareNative();
      await this.copyFileToUri(nativePath, uri);
      const warnings: string[] = [];
      this.appendQuantizationWarning(wr.quantization, warnings);
      return {
        uri: uri,
        fileName: this.savedDisplayName(uri, fileName),
        bytes: wr.bytes,
        shapeCount: wr.writtenShapes,
        skippedShapeCount: wr.skippedShapes,
        warnings: warnings,
        quantization: wr.quantization,
      };
    } finally { this.removeTemporary(nativePath); }
  }

  /**
   * 导出当前 native 布局为 SVG/PNG 图像。
   * 流程与 GDS 导出一致：picker 选目标 → native 写沙箱临时文件 → 拷贝 → 清理。
   * 调用前以当前文档 syncDocument，确保编辑内容进入输出；无需清除 dirty。
   */
  async exportImageWithPicker(
    context: common.UIAbilityContext,
    format: string,
    nativeTempDir: string,
    baseName: string,
    layers: ExportLayerStyle[],
    widthPx: number,
    heightPx: number,
    prepareNative?: () => void
  ): Promise<LayoutExportResult> {
    if (format !== 'svg' && format !== 'png') throw new Error('图像格式必须为 SVG 或 PNG');
    if (!Number.isInteger(widthPx) || !Number.isInteger(heightPx) || widthPx < 1 || heightPx < 1 ||
      widthPx > 8192 || heightPx > 8192) throw new Error('图像宽高必须为 1 至 8192 的整数像素');
    const isSvg: boolean = format === 'svg';
    const suffix: string = isSvg ? '.svg' : '.png';
    const fileName: string = baseName + suffix;
    const documentPicker = new picker.DocumentViewPicker(context);
    const uris: string[] = await documentPicker.save({
      newFileNames: [fileName],
      fileSuffixChoices: [isSvg ? 'SVG 矢量图|.svg' : 'PNG 图片|.png'],
    });
    if (uris.length === 0) {
      throw new ImageExportCancelledError();
    }
    const uri: string = uris[0];
    const nativePath: string = this.nextTemporaryPath(nativeTempDir, suffix);
    try {
    if (prepareNative !== undefined) prepareNative();
    const result: ImageExportResult = isSvg
      ? nativeHongTuService.exportSvg(nativePath, widthPx, heightPx, layers)
      : nativeHongTuService.exportPng(nativePath, widthPx, heightPx, layers);
    if (!result.success) {
      throw new Error(result.errorMessage.length > 0 ? result.errorMessage : '图像导出失败');
    }
    this.validateOutputFile(nativePath, result.bytes);
    await this.copyFileToUri(nativePath, uri);
    return {
      uri: uri,
      fileName: this.savedDisplayName(uri, fileName),
      bytes: result.bytes,
      shapeCount: 0,
      skippedShapeCount: 0,
      warnings: [],
    };
    } finally { this.removeTemporary(nativePath); }
  }

  /**
   * 直接将当前版图导出为沙箱缓存内的 PNG / SVG 文件（供 Share Kit 系统分享面板与碰一碰分享使用），
   * 自动轮转清理历史临时分享文件，不污染用户文档状态。
   */
  exportImageToCacheForShare(
    format: 'svg' | 'png',
    cacheDir: string,
    baseName: string,
    layers: ExportLayerStyle[],
    widthPx: number,
    heightPx: number,
    prepareNative?: () => void
  ): SharedImageCacheResult {
    if (format !== 'svg' && format !== 'png') {
      throw new Error('分享图像格式必须为 SVG 或 PNG');
    }
    if (!Number.isInteger(widthPx) || !Number.isInteger(heightPx) || widthPx < 1 || heightPx < 1 || widthPx > 8192 || heightPx > 8192) {
      throw new Error('图像宽高必须为 1 至 8192 的整数像素');
    }
    const shareDir: string = this.joinPath(cacheDir, 'hongtu_share_exports');
    try {
      if (!fs.accessSync(shareDir)) {
        fs.mkdirSync(shareDir);
      }
    } catch (_err) {
      try { fs.mkdirSync(shareDir); } catch (_ignore) {}
    }
    try {
      const existing: string[] = fs.listFileSync(shareDir).sort();
      if (existing.length > 6) {
        for (let i: number = 0; i < existing.length - 6; i++) {
          this.removeTemporary(this.joinPath(shareDir, existing[i]));
        }
      }
    } catch (_listErr) {}

    const suffix: string = format === 'svg' ? '.svg' : '.png';
    const cleanBase: string = baseName.replace(/[^a-zA-Z0-9._\-一-龥]/g, '_');
    const displayFileName: string = `${cleanBase.length > 0 ? cleanBase : 'layout'}${suffix}`;
    const sandboxPath: string = this.joinPath(shareDir, `${Date.now()}_${++this.temporarySequence}_${displayFileName}`);
    if (prepareNative !== undefined) {
      prepareNative();
    }
    const result: ImageExportResult = format === 'svg'
      ? nativeHongTuService.exportSvg(sandboxPath, widthPx, heightPx, layers)
      : nativeHongTuService.exportPng(sandboxPath, widthPx, heightPx, layers);
    if (!result.success) {
      this.removeTemporary(sandboxPath);
      throw new Error(result.errorMessage.length > 0 ? result.errorMessage : '分享快照生成失败');
    }
    this.validateOutputFile(sandboxPath, result.bytes);
    return {
      sandboxPath: sandboxPath,
      fileName: displayFileName,
      bytes: result.bytes,
    };
  }

  private temporarySequence: number = 0;
  private nextTemporaryPath(dir: string, suffix: string): string {
    return this.joinPath(dir, `hongtu_export_${Date.now()}-${++this.temporarySequence}${suffix}`);
  }
  private validateOutputFile(path: string, bytes: number): void {
    if (!Number.isSafeInteger(bytes) || bytes <= 0 || fs.statSync(path).size !== bytes) {
      throw new Error('导出文件长度校验失败，未复制到目标');
    }
  }
  private removeTemporary(path: string): void {
    try { fs.unlinkSync(path); } catch (_error) {}
  }

  /**
   * ArkTS 回退写出：1MiB 分块 writeSync。
   * buffer 仍整段驻留（GdsByteWriter 产物）；写盘按块投递，避免单次超大 write 限制。
   */
  private writeBufferToUri(buffer: ArrayBuffer, destUri: string, backupDirectory: string = '.'): void {
    safeFilePublishService.publishBuffer(buffer, destUri, backupDirectory);
  }

  private writeBufferToOwnedPath(buffer: ArrayBuffer, destUri: string): void {
    const total: number = buffer.byteLength;
    const mode: number = fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC;
    const file = fs.openSync(destUri, mode);
    try {
      const CHUNK: number = 1024 * 1024;
      if (total <= CHUNK) {
        this.writeAll(file.fd, buffer);
      } else {
        let fileOff: number = 0;
        while (fileOff < total) {
          const end: number = fileOff + CHUNK > total ? total : fileOff + CHUNK;
          this.writeAll(file.fd, buffer.slice(fileOff, end));
          fileOff = end;
        }
      }
      if (fs.statSync(file.fd).size !== total) throw new Error('保存文件长度与输出数据不一致');
      fs.fsyncSync(file.fd);
    } finally {
      fs.closeSync(file);
    }
  }

  /** fileIo.writeSync 可短写；必须写完本块才继续，避免生成截断的 GDS。 */
  private writeAll(fd: number, buffer: ArrayBuffer): void {
    let written: number = 0;
    while (written < buffer.byteLength) {
      // fileIo offset addresses the FILE, not the ArrayBuffer. Keep the file
      // cursor advancing and slice only the unwritten source bytes.
      const remaining: ArrayBuffer = written === 0 ? buffer : buffer.slice(written);
      const count: number = fs.writeSync(fd, remaining, { length: remaining.byteLength });
      if (count <= 0 || count > remaining.byteLength) {
        throw new Error('写入 GDS 文件失败：未写入剩余字节');
      }
      written += count;
    }
  }

  /**
   * 将沙箱文件内容写入文档 URI。
   * 优先 fs.copyFile（与 FileImportService 一致，适合大文件）；
   * Verify the copied length; unsupported URI copies use sequential 1MiB I/O.
   */
  private async copyFileToUri(srcPath: string, destUri: string): Promise<void> {
    const slash: number = Math.max(srcPath.lastIndexOf('/'), srcPath.lastIndexOf('\\'));
    const directory: string = slash >= 0 ? srcPath.substring(0, slash) : '.';
    safeFilePublishService.publishFile(srcPath, destUri, directory);
  }

  private joinPath(dir: string, name: string): string {
    if (dir.length === 0) {
      return name;
    }
    const last: string = dir.charAt(dir.length - 1);
    if (last === '/' || last === '\\') {
      return dir + name;
    }
    return `${dir}/${name}`;
  }

  /**
   * 属性数组 → writeGdsiiDocument 的 properties 载荷（native 侧按同名字段读回 PROPATTR/PROPVALUE）。
   * 归一化后无有效属性 → undefined，调用方**省略字段**，写出端也就不产生任何属性记录。
   */
  private propsToWire(props: LayoutPropRecord[] | undefined): Object[] | undefined {
    const clean: LayoutPropRecord[] | undefined = this.strictProps(props);
    if (clean === undefined) {
      return undefined;
    }
    const out: Object[] = [];
    for (let i = 0; i < clean.length; i++) {
      const rec: Record<string, Object | number | string> = {
        'attr': clean[i].attr,
        'dtype': clean[i].dtype,
        'name': clean[i].name,
        'value': clean[i].value,
      };
      out.push(rec);
    }
    return out;
  }

  /**
   * 构造 writeGdsiiDocument 用文档：points 扁平 [x0,y0,...]，与 NAPI 解析一致。
   * 属性（图元级 properties / 结构级 cellProperties / 库级 libProperties）全部为**可选**键，
   * 只有真的有属性时才带上，旧调用方形态不变。
   */
  buildNativeDocument(input: ExportLayoutInput): Object {
    this.assertStructuredCellIds(input);
    this.assertOrdinaryPropertyBudget(input);
    if (input.cellKeys !== undefined) validateLayoutSemantics(input, input.cellNames?.length ?? 0);
    const topCellId: number = input.topCellId !== undefined && input.topCellId >= 0 ? input.topCellId : 0;
    const cellNames: string[] = input.cellNames !== undefined ? input.cellNames.slice() : [];
    const packedWire = packShapesCoordinates(input.shapes, 8192);
    const usePackedWire: boolean = packedWire.packedCoords !== undefined;
    const sharedEmptyFlat: number[] = [];
    const shapesOut: Object[] = [];
    for (let i = 0; i < input.shapes.length; i++) {
      const s: Shape = input.shapes[i];
      let flat: number[];
      if (usePackedWire) {
        flat = sharedEmptyFlat;
      } else {
        flat = [];
        for (let p = 0; p < s.points.length; p++) {
          flat.push(s.points[p].x);
          flat.push(s.points[p].y);
        }
      }
      const typeStr: string =
        s.type === ShapeType.RECT ? 'rect' :
          (s.type === ShapeType.PATH ? 'path' :
            (s.type === ShapeType.TEXT ? 'text' :
              (s.type === ShapeType.INSTANCE ? 'instance' :
                (s.type === ShapeType.NODE ? 'node' : 'polygon'))));
      const item: Record<string, Object | number | string | number[] | Object[]> = {
        'id': s.id,
        'type': typeStr,
        'layerNumber': s.layerNumber,
        'datatype': s.datatype,
        'ownerCellId': s.ownerCellId !== undefined ? s.ownerCellId : topCellId,
        'cellId': s.cellId !== undefined ? s.cellId : -1,
        'cellName': s.type === ShapeType.INSTANCE && cellNames.length > 0 && s.cellId !== undefined &&
          s.cellId >= 0 && s.cellId < cellNames.length
          ? cellNames[s.cellId] : (s.cellName !== undefined ? s.cellName : ''),
        'rotation': s.rotation !== undefined ? s.rotation : 0,
        'mirror': s.mirror !== undefined ? s.mirror : 0,
        'magnification': s.magnification !== undefined && s.magnification > 0 ? s.magnification : 1,
        'pathWidth': s.pathWidth !== undefined ? s.pathWidth : 1,
        // 端型不带给 native，保存时 LayoutShape.pathType 停在默认 0(flush)，
        // round/extended 的 PATH 会在磁盘上被削短两端各 pathWidth/2
        'pathType': s.pathType !== undefined ? s.pathType : 0,
        'pathBeginExtension': s.pathBeginExtension ?? 0,
        'pathEndExtension': s.pathEndExtension ?? 0,
        'pathWidthAbsolute': s.pathWidthAbsolute ?? false,
        'arrayCols': s.arrayCols ?? 0,
        'arrayRows': s.arrayRows ?? 0,
        'arrayColStepX': s.arrayColStepX ?? 0,
        'arrayColStepY': s.arrayColStepY ?? 0,
        'arrayRowStepX': s.arrayRowStepX ?? 0,
        'arrayRowStepY': s.arrayRowStepY ?? 0,
        'text': s.text !== undefined ? s.text : '',
        'textPresentation': s.textPresentation ?? 0,
        'points': flat,
      };
      const shapeProps: Object[] | undefined = this.propsToWire(s.properties);
      if (shapeProps !== undefined) {
        item['properties'] = shapeProps;
      }
      shapesOut.push(item);
    }
    const doc: Record<string, Object | number | string | string[] | Object[]> = {
      'libName': input.libName,
      'userUnits': input.userUnits !== undefined && input.userUnits > 0 ? input.userUnits : 0.001,
      'physicalUnits': input.physicalUnits !== undefined && input.physicalUnits > 0 ? input.physicalUnits : 1e-9,
      'topCellId': topCellId,
      'cellNames': cellNames,
      'shapes': shapesOut,
      'layers': input.layers,
      'layerDefinitions': input.layerDefinitions ?? [],
    };
    if (usePackedWire && packedWire.packedCoords !== undefined &&
      packedWire.shapePointOffsets !== undefined && packedWire.shapePointCounts !== undefined) {
      doc['packedCoords'] = packedWire.packedCoords.buffer;
      doc['shapePointOffsets'] = packedWire.shapePointOffsets.buffer;
      doc['shapePointCounts'] = packedWire.shapePointCounts.buffer;
    }
    if (input.cellKeys !== undefined) doc['cellKeys'] = input.cellKeys;
    if (input.ports !== undefined) doc['ports'] = input.ports;
    if (input.crossSections !== undefined) doc['crossSections'] = input.crossSections;
    if (input.layoutContextRecords !== undefined) doc['layoutContextRecords'] = input.layoutContextRecords;
    if (input.cellContextRecords !== undefined) doc['cellContextRecords'] = input.cellContextRecords;
    // 结构级属性：与 cellNames 同索引的数组的数组；一个都没有则整字段省略
    if (input.cellProperties !== undefined && input.cellProperties.length > 0) {
      const groups: Object[] = [];
      const emptyGroup: Object[] = [];
      let anyGroup: boolean = false;
      for (let c = 0; c < cellNames.length; c++) {
        const g: Object[] | undefined = this.propsToWire(
          c < input.cellProperties.length ? input.cellProperties[c] : undefined);
        if (g !== undefined) {
          anyGroup = true;
          groups.push(g);
        } else {
          groups.push(emptyGroup);  // 占位保持与 cellNames 同索引（native 侧越界/非数组都忽略）
        }
      }
      if (anyGroup) {
        doc['cellProperties'] = groups;
      }
    }
    const libProps: Object[] | undefined = this.propsToWire(input.libProperties);
    if (libProps !== undefined) {
      doc['libProperties'] = libProps;
    }
    return doc;
  }

  buildGdsii(input: ExportLayoutInput, uri: string = '', fileName: string = ''): LayoutExportResult {
    const warnings: string[] = [];
    const result: GdsiiBufferResult = this.buildGdsiiBufferWithStats(input, warnings);
    return {
      uri: uri,
      fileName: fileName.length > 0 ? fileName : this.defaultFileName(input),
      bytes: result.buffer.byteLength,
      shapeCount: result.writtenShapes,
      skippedShapeCount: result.skippedShapes,
      warnings: warnings,
      quantization: result.quantization,
    };
  }

  buildGdsiiBuffer(input: ExportLayoutInput, warnings: string[] = []): ArrayBuffer {
    // EXPORT-3: 保留公共签名返回 ArrayBuffer，统计数通过 buildGdsiiBufferWithStats 获取
    return this.buildGdsiiBufferWithStats(input, warnings).buffer;
  }

  /** EXPORT-3: 内部方法返回统计数，避免用实例可变字段传递副作用 */
  private buildGdsiiBufferWithStats(input: ExportLayoutInput, warnings: string[]): GdsiiBufferResult {
    this.assertOrdinaryPropertyBudget(input, true);
    this.quantization = { dbuNm: (input.physicalUnits ?? 1e-9) * 1e9, examinedValueCount: 0,
      quantizedValueCount: 0, quantizedShapeCount: 0, maximumDeviationNm: 0 };
    this.quantizedShapeIds.clear();
    // M2: 有 cellNames 时按 ownerCell 结构化写出；否则走兼容路径
    if (input.cellNames !== undefined && input.cellNames.length > 0) {
      const result: GdsiiBufferResult = this.buildStructuredByOwner(input, warnings);
      result.quantization = this.quantization;
      this.appendQuantizationWarning(this.quantization, warnings);
      return result;
    }
    const result: GdsiiBufferResult = this.buildLegacyFlatTop(input, warnings);
    result.quantization = this.quantization;
    this.appendQuantizationWarning(this.quantization, warnings);
    return result;
  }

  private appendQuantizationWarning(report: QuantizationReport | undefined, warnings: string[]): void {
    if (report !== undefined && report.quantizedValueCount > 0) {
      warnings.push(`DBU ${report.dbuNm} nm：${report.quantizedShapeCount} 个图形的 ${report.quantizedValueCount} 个写出值发生量化，最大偏差 ${Number(report.maximumDeviationNm.toPrecision(4))} nm。`);
    }
  }

  /** Cheap preflight for the precision bar; actual writer returns the serialized-field report. */
  analyzeQuantization(input: ExportLayoutInput): QuantizationReport {
    const dbuNm: number = (input.physicalUnits ?? 1e-9) * 1e9;
    if (!Number.isFinite(dbuNm) || dbuNm <= 0) throw new Error('数据库精度无效');
    const report: QuantizationReport = { dbuNm, examinedValueCount: 0, quantizedValueCount: 0, quantizedShapeCount: 0, maximumDeviationNm: 0 };
    for (const shape of input.shapes) {
      const before: number = report.quantizedValueCount;
      const values: number[] = [];
      for (const point of shape.points) values.push(point.x, point.y);
      if (shape.type === ShapeType.PATH) values.push(shape.pathWidth ?? 1, shape.pathBeginExtension ?? 0, shape.pathEndExtension ?? 0);
      if (shape.type === ShapeType.INSTANCE && (shape.arrayCols ?? 0) > 0 && (shape.arrayRows ?? 0) > 0 && shape.points.length > 0) {
        const origin: Point = shape.points[0];
        values.push(origin.x + (shape.arrayCols ?? 0) * (shape.arrayColStepX ?? 0),
          origin.y + (shape.arrayCols ?? 0) * (shape.arrayColStepY ?? 0),
          origin.x + (shape.arrayRows ?? 0) * (shape.arrayRowStepX ?? 0),
          origin.y + (shape.arrayRows ?? 0) * (shape.arrayRowStepY ?? 0));
      }
      for (const value of values) {
        if (!Number.isFinite(value)) throw new Error('量化检查遇到无效坐标');
        const raw: number = value / dbuNm;
        const stored: number = (raw < 0 ? -Math.round(-raw) : Math.round(raw)) * dbuNm;
        const deviation: number = Math.abs(value - stored);
        report.examinedValueCount++;
        if (deviation > dbuNm * 1e-9) { report.quantizedValueCount++; report.maximumDeviationNm = Math.max(report.maximumDeviationNm, deviation); }
      }
      if (report.quantizedValueCount > before) report.quantizedShapeCount++;
    }
    return report;
  }

  /**
   * M2 主路径：按 ownerCellId 分组，每个 Cell 单独 BGNSTR/ENDSTR。
   * - Top 只写归属 Top 的本地几何 + SREF
   * - 子 Cell 写其 owner 本地几何（含嵌套 INSTANCE）
   * - 避免「全量 shapes 塞进 Top」导致层级丢失
   */
  private buildStructuredByOwner(input: ExportLayoutInput, warnings: string[]): GdsiiBufferResult {
    this.assertStructuredCellIds(input);
    const writer = new GdsByteWriter();
    const libName: string = this.sanitizeGdsName(input.libName, 'HONGTU_LIB');
    const topCellId: number = input.topCellId !== undefined && input.topCellId >= 0 ? input.topCellId : 0;
    const topName: string = this.sanitizeGdsName(
      (input.cellNames !== undefined && topCellId < input.cellNames.length && input.cellNames[topCellId].length > 0)
        ? input.cellNames[topCellId]
        : input.topCellName,
      'TOP'
    );
    const userUnits: number = (input.userUnits !== undefined && input.userUnits > 0) ? input.userUnits : 0.001;
    const physicalUnits: number = (input.physicalUnits !== undefined && input.physicalUnits > 0)
      ? input.physicalUnits : 1e-9;
    this.setNmToDbuFromPhysical(physicalUnits);

    // ownerId → shapes
    const byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
    for (let i = 0; i < input.shapes.length; i++) {
      const shape: Shape = input.shapes[i];
      const owner: number = shape.ownerCellId !== undefined ? shape.ownerCellId : topCellId;
      let list: Shape[] | undefined = byOwner.get(owner);
      if (list === undefined) {
        list = [];
        byOwner.set(owner, list);
      }
      list.push(shape);
    }

    // cellId → sanitized name
    const idToName: Map<number, string> = new Map<number, string>();
    if (input.cellNames !== undefined) {
      for (let i = 0; i < input.cellNames.length; i++) {
        const n: string = this.sanitizeGdsName(input.cellNames[i], `CELL_${i}`);
        idToName.set(i, n);
      }
    }
    idToName.set(topCellId, topName);

    // Structured Cell IDs have been validated against the complete table.
    // Missing definitions must fail; inventing CELL_N shells loses geometry.

    // 写出顺序：非 Top 先写（依赖方在前），最后写 Top
    const writeOrder: number[] = [];
    idToName.forEach((_name: string, id: number) => {
      if (id !== topCellId) {
        writeOrder.push(id);
      }
    });
    writeOrder.sort((a: number, b: number) => a - b);
    writeOrder.push(topCellId);

    let writtenShapes: number = 0;
    let skippedShapes: number = 0;
    let cellCountWritten: number = 0;

    writer.writeInt2Record(REC_HEADER, [600]);
    writer.writeInt2Record(REC_BGNLIB, this.currentDateWords());
    writer.writeStringRecord(REC_LIBNAME, libName);
    writer.writeReal8Record(REC_UNITS, [userUnits, physicalUnits]);
    // 库级属性：UNITS 之后、首个 BGNSTR 之前（规范允许位置，与 gdsii_writer.cpp 同）
    this.writePropList(writer, input.libProperties);

    this.writeContextContainer(writer, buildPortContextPayload(input, input.cellNames?.length ?? 0, physicalUnits * 1e9), idToName);

    for (let wi = 0; wi < writeOrder.length; wi++) {
      const cellId: number = writeOrder[wi];
      const cellName: string = idToName.get(cellId) ?? this.sanitizeGdsName(`CELL_${cellId}`, `CELL_${cellId}`);
      writer.writeInt2Record(REC_BGNSTR, this.currentDateWords());
      writer.writeStringRecord(REC_STRNAME, cellName);
      // 结构级属性：STRNAME 之后、首个元素之前；cellProperties 与 cellNames 同索引（cellId 即该名表下标）
      if (input.cellProperties !== undefined) {
        this.writePropList(writer,
          cellId >= 0 && cellId < input.cellProperties.length ? input.cellProperties[cellId] : undefined);
      }

      // 编辑服务中的当前 shapes 是唯一几何真源。空 Cell 必须保持为空；
      // 不能从加载时的 childCells 副本补回已删除的旧图形。
      const shapesToWrite: Shape[] = byOwner.get(cellId) ?? [];
      for (let s = 0; s < shapesToWrite.length; s++) {
        const original: Shape = shapesToWrite[s];
        // Resolve SNAME as a local value; keep source geometry and even invalid
        // numeric inputs intact so nmToDbu can reject them, rather than JSON
        // cloning NaN into null and accidentally writing a zero coordinate.
        const referenceName: string | undefined = original.type === ShapeType.INSTANCE
          ? idToName.get(original.cellId ?? -1) : undefined;
        if (this.writeShape(writer, original, referenceName)) {
          writtenShapes++;
        } else {
          skippedShapes++;
        }
      }

      writer.writeRecord(REC_ENDSTR);
      cellCountWritten++;
    }

    writer.writeRecord(REC_ENDLIB);

    warnings.push(`按 ownerCell 结构化写出 ${cellCountWritten} 个 Cell（Top=${topName}）。`);
    if (skippedShapes > 0) {
      warnings.push(`有 ${skippedShapes} 个图形因几何无效或超过安全点数上限未写出。`);
    }
    if (input.layers.length === 0) {
      warnings.push('当前没有图层元数据，导出仅使用图形自身 layer/datatype。');
    }
    if (writtenShapes === 0) {
      warnings.push('当前没有可写入的版图图形。');
    }

    return {
      buffer: writer.toArrayBuffer(),
      writtenShapes: writtenShapes,
      skippedShapes: skippedShapes,
    };
  }

  /** Applies equally to native-document and ArkTS structured buffer routes.
   * Legacy flat-top exports without a Cell table retain their explicit pathway. */
  private assertStructuredCellIds(input: ExportLayoutInput): void {
    const names: string[] | undefined = input.cellNames;
    if (names === undefined || names.length === 0) return;
    const top: number = input.topCellId ?? 0;
    const valid: (id: number) => boolean = (id: number): boolean => Number.isInteger(id) && id >= 0 && id < names.length;
    if (!valid(top)) throw new Error('结构化保存的 Top Cell ID 无效，保存已取消');
    const seen: Set<string> = new Set<string>();
    for (const name of names) {
      if (typeof name !== 'string' || name.length === 0 || seen.has(name)) throw new Error('结构化保存的 Cell 名称缺失或重复，保存已取消');
      this.sanitizeGdsName(name, 'CELL'); seen.add(name);
    }
    for (const shape of input.shapes) {
      if (!valid(shape.ownerCellId ?? top)) throw new Error('结构化保存的对象归属 Cell 不存在，保存已取消');
      if (shape.type === ShapeType.INSTANCE && !valid(shape.cellId ?? -1)) throw new Error('结构化保存的引用 Cell 不存在，保存已取消');
    }
  }

  /**
   * 兼容路径：无 cellNames 时，Top 写入全部 shapes，子 cell 仅从 childCells/INSTANCE 名补空壳。
   * 保留给空白文档手绘、旧调用方。
   */
  private buildLegacyFlatTop(input: ExportLayoutInput, warnings: string[]): GdsiiBufferResult {
    if (input.cellKeys !== undefined || (input.cellContextRecords ?? []).length > 0) throw new Error('结构元数据保存需要完整 Cell 名表');
    const writer = new GdsByteWriter();
    const libName: string = this.sanitizeGdsName(input.libName, 'HONGTU_LIB');
    const topName: string = this.sanitizeGdsName(input.topCellName, 'TOP');
    const childNames: string[] = this.instanceCellNames(input.shapes, topName, input.childCells);
    let writtenShapes: number = 0;
    let skippedShapes: number = 0;
    const userUnits: number = (input.userUnits !== undefined && input.userUnits > 0) ? input.userUnits : 0.001;
    const physicalUnits: number = (input.physicalUnits !== undefined && input.physicalUnits > 0)
      ? input.physicalUnits : 1e-9;
    this.setNmToDbuFromPhysical(physicalUnits);

    writer.writeInt2Record(REC_HEADER, [600]);
    writer.writeInt2Record(REC_BGNLIB, this.currentDateWords());
    writer.writeStringRecord(REC_LIBNAME, libName);
    writer.writeReal8Record(REC_UNITS, [userUnits, physicalUnits]);
    // 库级属性：UNITS 之后、首个 BGNSTR 之前（规范允许位置，与 gdsii_writer.cpp 同）
    this.writePropList(writer, input.libProperties);
    this.writeContextContainer(writer, buildPortContextPayload(input, 0, physicalUnits * 1e9), new Map<number, string>());
    for (let i = 0; i < childNames.length; i++) {
      writer.writeInt2Record(REC_BGNSTR, this.currentDateWords());
      writer.writeStringRecord(REC_STRNAME, childNames[i]);
      const childCell: ChildCellExport | undefined = input.childCells !== undefined
        ? this.findChildCell(input.childCells, childNames[i])
        : undefined;
      if (childCell !== undefined) {
        for (let s = 0; s < childCell.shapes.length; s++) {
          if (this.writeShape(writer, childCell.shapes[s])) {
            writtenShapes++;
          } else {
            skippedShapes++;
          }
        }
      }
      writer.writeRecord(REC_ENDSTR);
    }
    if (childNames.length > 0) {
      const hasChildGeometry: boolean = input.childCells !== undefined && input.childCells.length > 0;
      if (hasChildGeometry) {
        warnings.push(`实例引用已写为 SREF；${childNames.length} 个子 cell 已写入内部几何（兼容路径）。`);
      } else {
        warnings.push(`实例引用已写为 SREF；${childNames.length} 个子 cell 当前没有可导出的内部几何（兼容路径）。`);
      }
    }

    writer.writeInt2Record(REC_BGNSTR, this.currentDateWords());
    writer.writeStringRecord(REC_STRNAME, topName);

    for (let i = 0; i < input.shapes.length; i++) {
      if (this.writeShape(writer, input.shapes[i])) {
        writtenShapes++;
      } else {
        skippedShapes++;
      }
    }

    writer.writeRecord(REC_ENDSTR);
    writer.writeRecord(REC_ENDLIB);

    if (skippedShapes > 0) {
      warnings.push(`有 ${skippedShapes} 个图形因几何无效或超过安全点数上限未写出。`);
    }
    if (input.layers.length === 0) {
      warnings.push('当前没有图层元数据，导出仅使用图形自身 layer/datatype。');
    }
    if (writtenShapes === 0) {
      warnings.push('当前没有可写入的版图图形。');
    }
    return {
      buffer: writer.toArrayBuffer(),
      writtenShapes: writtenShapes,
      skippedShapes: skippedShapes,
    };
  }

  private writeShape(writer: GdsByteWriter, shape: Shape, referenceName?: string): boolean {
    this.currentQuantizationShapeId = shape.id;
    if (shape.type === ShapeType.RECT) {
      return this.writeRect(writer, shape);
    }
    if (shape.type === ShapeType.POLYGON) {
      return this.writePolygon(writer, shape);
    }
    if (shape.type === ShapeType.PATH) {
      return this.writePath(writer, shape);
    }
    if (shape.type === ShapeType.TEXT) {
      return this.writeText(writer, shape);
    }
    if (shape.type === ShapeType.INSTANCE) {
      return this.writeInstance(writer, shape, referenceName);
    }
    if (shape.type === ShapeType.NODE) {
      return this.writeNode(writer, shape);
    }
    return false;
  }

  /**
   * 属性列表 → PROPATTR(0x2B)/PROPVALUE(0x2C) 记录对，位置由调用方决定
   * （元素：坐标/STRING 之后 ENDEL 之前；结构：STRNAME 之后首个元素之前；库：UNITS 之后）。
   *
   * 与 native NapiWriteGdsiiDocument 的 DecodePropertyWire **同语义**，因此两条写出路径
   * （native document / ArkTS 回退字节流）产出的属性字节一致：
   *   dtype 0 → 4 字节空头 PROPVALUE；dtype 7 → 十六进制载体，还原为 dtype 6；
   *   dtype 2/3/4/5 → '#' 前缀按十六进制解码，否则 UTF8 字节；dtype 6 → UTF8。
   * Invalid properties reject the complete save before publishing a file.
   */
  private strictProps(props: LayoutPropRecord[] | undefined): LayoutPropRecord[] | undefined {
    if (props === undefined || props.length === 0) return undefined;
    if (!Array.isArray(props) || props.length > MAX_PROPS_PER_OWNER) throw new Error('普通属性归属者超过 64 条预算');
    for (const prop of props) {
      if (prop === null || !Number.isInteger(prop.attr) || prop.attr < -32768 || prop.attr > 32767 ||
        !Number.isInteger(prop.dtype) || prop.dtype < 0 || prop.dtype > 255 || typeof prop.name !== 'string' || typeof prop.value !== 'string') throw new Error('普通属性记录无效');
    }
    return props;
  }

  private assertOrdinaryPropertyBudget(input: ExportLayoutInput, gdsPadding: boolean = false): void {
    let bytes: number = 0;
    const check: (props: LayoutPropRecord[] | undefined) => void = (props: LayoutPropRecord[] | undefined): void => {
      const clean: LayoutPropRecord[] | undefined = this.strictProps(props);
      for (const prop of clean ?? []) {
        let size: number = layoutUtf8Bytes(prop.value);
        if (prop.dtype === 7 || ([2, 3, 4, 5, 139].includes(prop.dtype) && prop.value.startsWith('#'))) {
          const raw: number[] | undefined = this.hexToBytes(prop.value);
          if (raw === undefined) throw new Error('属性十六进制载体无效');
          size = raw.length;
        }
        bytes += size + (gdsPadding ? size % 2 : 0);
        if (size > 65530 || bytes > 32 * 1024 * 1024) throw new Error('普通属性超过 65530 字节或文档 32MiB 预算');
      }
    };
    check(input.libProperties);
    for (const props of input.cellProperties ?? []) check(props);
    for (const shape of input.shapes) check(shape.properties);
    if (input.cellNames === undefined || input.cellNames.length === 0) {
      for (const child of input.childCells ?? []) for (const shape of child.shapes) check(shape.properties);
    }
  }

  private writePropList(writer: GdsByteWriter, props: LayoutPropRecord[] | undefined): void {
    const clean: LayoutPropRecord[] | undefined = this.strictProps(props);
    if (clean === undefined) return;
    for (const prop of clean) {
      let dt: number = prop.dtype;
      if (dt >= 128 || prop.name.length > 0 || ![0, 2, 3, 4, 5, 6, 7].includes(dt)) throw new Error('该命名/typed 属性不能无损写入 GDSII，请保存 OASIS');
      let data: number[] = [];
      if (dt === 0) {
        if (prop.value.length > 0) throw new Error('无数据属性含无法保存的值');
      } else if (dt === 7 || (dt >= 2 && dt <= 5 && prop.value.startsWith('#'))) {
        const decoded: number[] | undefined = this.hexToBytes(prop.value);
        if (decoded === undefined) throw new Error('属性十六进制载体无效');
        data = decoded; if (dt === 7) dt = 6;
      } else data = this.gdsTextBytes(prop.value);
      if (data.length > 65530) throw new Error('GDSII 属性值超过 65530 字节，保存已拒绝');
      if (data.length % 2 === 1) data.push(0);
      writer.writeInt2Record(REC_PROPATTR, [prop.attr]);
      const valueRecord: GdsRecord = { type: REC_PROPVALUE_DT, dataType: dt };
      writer.writeRecord(valueRecord, data);
    }
  }

  private writeContextContainer(writer: GdsByteWriter, payload: PortContextPayload, names: Map<number, string>): void {
    let any: boolean = payload.layout.length > 0, bytes: number = 0;
    for (const rows of [payload.layout, ...payload.cells]) {
      any = any || rows.length > 0;
      if (rows.length > 65536) throw new Error('context 条目超出预算');
      for (const row of rows) {
        const size: number = contextRecordBytes(row).length; bytes += size;
        if (size > 8 * 1024 * 1024 || bytes > 64 * 1024 * 1024) throw new Error('context 字节超出预算');
      }
    }
    if (!any) return;
    names.forEach((name: string): void => { if (name === '$$$CONTEXT_INFO$$$') throw new Error('KLayout 保留 context Cell 名称冲突'); });
    writer.writeInt2Record(REC_BGNSTR, this.currentDateWords()); writer.writeStringRecord(REC_STRNAME, '$$$CONTEXT_INFO$$$');
    this.writeContextHook(writer, payload.layout);
    for (let ci: number = 0; ci < payload.cells.length; ci++) {
      const name: string | undefined = names.get(ci);
      if (name === undefined && payload.cells[ci].length > 0) throw new Error('context 缺少真实 Cell 名称');
      this.writeContextHook(writer, payload.cells[ci], name);
    }
    writer.writeRecord(REC_ENDSTR);
  }

  private writeContextHook(writer: GdsByteWriter, records: LayoutContextRecord[], name?: string): void {
    if (records.length === 0) return;
    if (name !== undefined) { writer.writeRecord(REC_SREF); writer.writeStringRecord(REC_SNAME, name); writer.writeInt4Record(REC_XY, [0, 0]); }
    else { writer.writeRecord(REC_BOUNDARY); writer.writeInt2Record(REC_LAYER, [0]); writer.writeInt2Record(REC_DATATYPE, [0]); writer.writeInt4Record(REC_XY, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]); }
    for (let n: number = records.length - 1; n >= 0; n--) {
      const raw: number[] = contextRecordBytes(records[n]);
      if (raw.includes(0)) throw new Error('GDSII context 无法保留 NUL 字节，请保存 OASIS');
      const chunked: boolean = n > 32767 || raw.length > 32000 || raw[0] === 35;
      const parts: number = chunked ? Math.max(1, Math.ceil(raw.length / 32000)) : 1;
      for (let part: number = parts - 1; part >= 0; part--) {
        const prefix: number[] = chunked ? this.gdsTextBytes('#' + n + ',' + part + ':') : [];
        const data: number[] = prefix.concat(chunked ? raw.slice(part * 32000, (part + 1) * 32000) : raw);
        if (data.length % 2 === 1) data.push(0);
        writer.writeInt2Record(REC_PROPATTR, [Math.min(n, 32767)]);
        const property: GdsRecord = { type: REC_PROPVALUE_DT, dataType: 6 };
        writer.writeRecord(property, data);
      }
    }
    writer.writeRecord(REC_ENDEL);
  }
  private hexNibble(c: number): number {
    if (c >= 0x30 && c <= 0x39) {
      return c - 0x30;
    }
    if (c >= 0x61 && c <= 0x66) {
      return c - 0x61 + 10;
    }
    if (c >= 0x41 && c <= 0x46) {
      return c - 0x41 + 10;
    }
    return -1;
  }

  /** '#'+十六进制 → 原始字节；长度/字符非法返回 undefined */
  private hexToBytes(wire: string): number[] | undefined {
    if (wire.length < 3 || (wire.length - 1) % 2 !== 0 || wire.charCodeAt(0) !== 0x23) {
      return undefined;
    }
    const out: number[] = [];
    for (let i = 1; i < wire.length; i += 2) {
      const hi: number = this.hexNibble(wire.charCodeAt(i));
      const lo: number = this.hexNibble(wire.charCodeAt(i + 1));
      if (hi < 0 || lo < 0) {
        return undefined;
      }
      out.push(((hi << 4) | lo) & 0xFF);
    }
    return out;
  }

  /** Text payload uses actual UTF8 bytes. */
  private gdsTextBytes(value: string): number[] {
    const context: LayoutContextRecord = { encoding: 'utf8', value: value };
    return contextRecordBytes(context);
  }

  private writeRect(writer: GdsByteWriter, shape: Shape): boolean {
    if (shape.points.length < 2) {
      return false;
    }
    const bounds = this.bounds(shape.points);
    const points: Point[] = [
      { x: bounds.minX, y: bounds.minY },
      { x: bounds.maxX, y: bounds.minY },
      { x: bounds.maxX, y: bounds.maxY },
      { x: bounds.minX, y: bounds.maxY },
      { x: bounds.minX, y: bounds.minY },
    ];
    writer.writeRecord(REC_BOUNDARY);
    writer.writeInt2Record(REC_LAYER, [this.layerNumber(shape)]);
    writer.writeInt2Record(REC_DATATYPE, [this.datatype(shape)]);
    writer.writeInt4Record(REC_XY, this.flattenPoints(points));
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  private writePolygon(writer: GdsByteWriter, shape: Shape): boolean {
    if (shape.points.length < 3) {
      return false;
    }
    const points: Point[] = this.closedPoints(shape.points);
    if (points.length > MAX_ELEMENT_POINTS) {
      return false;
    }
    writer.writeRecord(REC_BOUNDARY);
    writer.writeInt2Record(REC_LAYER, [this.layerNumber(shape)]);
    writer.writeInt2Record(REC_DATATYPE, [this.datatype(shape)]);
    this.writeXY(writer, points);
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  private writePath(writer: GdsByteWriter, shape: Shape): boolean {
    if (shape.points.length < 2 || shape.points.length > MAX_ELEMENT_POINTS) {
      return false;
    }
    writer.writeRecord(REC_PATH);
    writer.writeInt2Record(REC_LAYER, [this.layerNumber(shape)]);
    writer.writeInt2Record(REC_DATATYPE, [this.datatype(shape)]);
    const width: number = shape.pathWidth ?? 1;
    if (width < 0) throw new Error('PATH 宽度无效');
    const pathType: number = shape.pathType ?? 0;
    if (pathType !== 0 && pathType !== 1 && pathType !== 2 && pathType !== 4) throw new Error('PATH 端型无效');
    if (pathType !== 0) {
      writer.writeInt2Record(REC_PATHTYPE, [pathType]);
    }
    writer.writeInt4Record(REC_WIDTH, [this.nmToDbu(shape.pathWidthAbsolute ? -width : width)]);
    if (pathType === 4) {
      writer.writeInt4Record(REC_BGNEXTN, [this.nmToDbu(shape.pathBeginExtension ?? 0)]);
      writer.writeInt4Record(REC_ENDEXTN, [this.nmToDbu(shape.pathEndExtension ?? 0)]);
    }
    this.writeXY(writer, shape.points);
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  private writeText(writer: GdsByteWriter, shape: Shape): boolean {
    if (shape.points.length < 1) {
      return false;
    }
    writer.writeRecord(REC_TEXT);
    writer.writeInt2Record(REC_LAYER, [this.layerNumber(shape)]);
    writer.writeInt2Record(REC_TEXTTYPE, [this.datatype(shape)]);
    if ((shape.textPresentation ?? 0) !== 0) writer.writeInt2Record(REC_PRESENTATION, [shape.textPresentation ?? 0]);
    if ((shape.mirror ?? 0) !== 0) writer.writeInt2Record(REC_STRANS, [0x8000]);
    if ((shape.magnification ?? 1) !== 1) writer.writeReal8Record(REC_MAG, [shape.magnification ?? 1]);
    const textAngle: number = (shape.rotation ?? 0) + (shape.mirror === 2 ? 180 : 0);
    if (textAngle !== 0) writer.writeReal8Record(REC_ANGLE, [textAngle]);
    writer.writeInt4Record(REC_XY, this.flattenPoints([shape.points[0]]));
    writer.writeStringRecord(REC_STRING, this.sanitizeGdsString(shape.text ?? 'TEXT', 'TEXT'));
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  /** NODE 是非绘制元素：保留其 NODETYPE、原始点序列和元素属性。 */
  private writeNode(writer: GdsByteWriter, shape: Shape): boolean {
    if (shape.points.length < 1 || shape.points.length > MAX_ELEMENT_POINTS) {
      return false;
    }
    writer.writeRecord(REC_NODE);
    writer.writeInt2Record(REC_LAYER, [this.layerNumber(shape)]);
    writer.writeInt2Record(REC_NODETYPE, [this.datatype(shape)]);
    this.writeXY(writer, shape.points);
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  private writeInstance(writer: GdsByteWriter, shape: Shape, referenceName?: string): boolean {
    if (shape.points.length < 1) {
      return false;
    }
    const name: string = this.sanitizeGdsName(referenceName ?? shape.cellName ?? `CELL_${shape.cellId ?? shape.id}`, `CELL_${shape.id}`);
    const cols: number = shape.arrayCols ?? 0;
    const rows: number = shape.arrayRows ?? 0;
    const isArray: boolean = cols > 0 && rows > 0;
    if (cols > 32767 || rows > 32767 || (cols > 0) !== (rows > 0) ||
      !Number.isInteger(cols) || !Number.isInteger(rows)) throw new Error('AREF 阵列行列数无效');
    writer.writeRecord(isArray ? REC_AREF : REC_SREF);
    writer.writeStringRecord(REC_SNAME, name);
    // FILE-03: GDSII STRANS 镜像编码
    //   mirror=1 → X 轴翻转（Y 取反）→ STRANS bit15=0x8000
    //   mirror=2 → Y 轴翻转（X 取反）→ 等价于 X 镜像 + 旋转 180°
    //              GDSII 无直接 Y 镜像位，需 STRANS=0x8000 + ANGLE=180
    const mirror: number = shape.mirror ?? 0;
    const rotation: number = shape.rotation ?? 0;
    let effectiveRotation: number = rotation;
    if (mirror === 1) {
      writer.writeInt2Record(REC_STRANS, [0x8000]);
    } else if (mirror === 2) {
      // Y 轴翻转 = X 镜像 + 旋转 180°
      writer.writeInt2Record(REC_STRANS, [0x8000]);
      effectiveRotation = (rotation + 180) % 360;
    }
    const magnification: number = shape.magnification ?? 1;
    if (magnification > 0 && Math.abs(magnification - 1) > 0.000001) {
      writer.writeReal8Record(REC_MAG, [magnification]);
    }
    if (effectiveRotation !== 0) {
      writer.writeReal8Record(REC_ANGLE, [effectiveRotation]);
    }
    const origin: Point = shape.points[0];
    const coords: Point[] = [origin];
    if (isArray) {
      writer.writeInt2Record(REC_COLROW, [cols, rows]);
      coords.push({ x: origin.x + cols * (shape.arrayColStepX ?? 0), y: origin.y + cols * (shape.arrayColStepY ?? 0) });
      coords.push({ x: origin.x + rows * (shape.arrayRowStepX ?? 0), y: origin.y + rows * (shape.arrayRowStepY ?? 0) });
    }
    writer.writeInt4Record(REC_XY, this.flattenPoints(coords));
    this.writePropList(writer, shape.properties);
    writer.writeRecord(REC_ENDEL);
    return true;
  }

  private bounds(points: Point[]): ShapeBoundsForExport {
    let minX: number = points[0].x;
    let maxX: number = points[0].x;
    let minY: number = points[0].y;
    let maxY: number = points[0].y;
    for (let i = 1; i < points.length; i++) {
      minX = Math.min(minX, points[i].x);
      maxX = Math.max(maxX, points[i].x);
      minY = Math.min(minY, points[i].y);
      maxY = Math.max(maxY, points[i].y);
    }
    const result: ShapeBoundsForExport = { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
    return result;
  }

  private closedPoints(points: Point[]): Point[] {
    const out: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push({ x: points[i].x, y: points[i].y });
    }
    const first: Point = out[0];
    const last: Point = out[out.length - 1];
    if (first.x !== last.x || first.y !== last.y) {
      out.push({ x: first.x, y: first.y });
    }
    return out;
  }

  private flattenPoints(points: Point[]): number[] {
    const out: number[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push(this.nmToDbu(points[i].x));
      out.push(this.nmToDbu(points[i].y));
    }
    return out;
  }

  /** KLayout 非标准多 XY 扩展；单条记录最多容纳 8191 个点对（直写 Uint8Array 消除中间数组拆箱）。 */
  private writeXY(writer: GdsByteWriter, points: Point[]): void {
    for (let start = 0; start < points.length; start += MAX_XY_POINTS_PER_RECORD) {
      const count: number = Math.min(MAX_XY_POINTS_PER_RECORD, points.length - start);
      writer.writePointSliceXYRecord(REC_XY, points, start, count, (nm: number): number => this.nmToDbu(nm));
    }
  }

  /** BGNLIB 用：12 个值（修改时间 + 访问时间，各 6 个） */
  private currentDateWords(): number[] {
    const now = new Date();
    const year: number = now.getFullYear();
    const month: number = now.getMonth() + 1;
    const day: number = now.getDate();
    const hour: number = now.getHours();
    const minute: number = now.getMinutes();
    const second: number = now.getSeconds();
    return [year, month, day, hour, minute, second, year, month, day, hour, minute, second];
  }

  /**
   * 递归收集所有层级的子 Cell 名称（L-3: 原实现仅收集顶层 INSTANCE 引用，子 Cell 内部的
   * 嵌套 INSTANCE 引用被静默丢弃，导致导出的 GDSII 仅有一层 SREF 结构）。
   *
   * 递归策略：对每个 Cell 的 shapes，收集其 INSTANCE 引用的 Cell 名，
   * 然后递归到被引用的 ChildCellExport.shapes 继续收集，避免循环引用（用 visited 集合保护）。
   */
  private instanceCellNames(shapes: Shape[], topName: string, childCells?: ChildCellExport[]): string[] {
    const names: string[] = [];
    const seen: Map<string, boolean> = new Map<string, boolean>();
    const visited: Set<string> = new Set<string>();
    this.collectInstanceNamesRecursive(shapes, topName, childCells, names, seen, visited);
    return names;
  }

  private collectInstanceNamesRecursive(
    shapes: Shape[],
    topName: string,
    childCells: ChildCellExport[] | undefined,
    names: string[],
    seen: Map<string, boolean>,
    visited: Set<string>
  ): void {
    for (let i = 0; i < shapes.length; i++) {
      const shape: Shape = shapes[i];
      if (shape.type !== ShapeType.INSTANCE) {
        continue;
      }
      const name: string = this.sanitizeGdsName(shape.cellName ?? `CELL_${shape.cellId ?? shape.id}`, `CELL_${shape.id}`);
      if (name === topName || seen.has(name)) {
        continue;
      }
      seen.set(name, true);
      names.push(name);

      // L-3: 递归收集该子 Cell 内部的嵌套 INSTANCE 引用
      if (visited.has(name)) {
        continue; // 循环引用保护
      }
      visited.add(name);
      if (childCells !== undefined) {
        const childCell: ChildCellExport | undefined = this.findChildCell(childCells, name);
        if (childCell !== undefined) {
          this.collectInstanceNamesRecursive(childCell.shapes, topName, childCells, names, seen, visited);
        }
      }
    }
  }

  /**
   * FILE-02 / EXPORT-1: 按名称查找子 cell 几何。
   * 调用方传入的 name 已经过 sanitizeGdsName 规范化（大写+过滤特殊字符），
   * 但 cells[i].name 来自 CellDef.name（原始名，可能含小写/特殊字符），
   * 因此两侧均需 sanitizeGdsName 后再比较，否则小写 cell 名匹配失败，
   * 子 cell 内部几何被静默丢弃。
   */
  private findChildCell(cells: ChildCellExport[], name: string): ChildCellExport | undefined {
    for (let i = 0; i < cells.length; i++) {
      const sanitizedCellName: string = this.sanitizeGdsName(cells[i].name, cells[i].name);
      if (sanitizedCellName === name) {
        return cells[i];
      }
    }
    return undefined;
  }

  private defaultFileName(input: ExportLayoutInput): string {
    const sourceStem: string = this.fileStem(input.sourcePath);
    const preferred: string = input.topCellName.length > 0 ? input.topCellName :
      (input.libName.length > 0 ? input.libName : sourceStem);
    const stem: string = this.sanitizeFileStem(preferred.length > 0 ? preferred : 'hongtu-layout');
    return `${stem}-edited.gds`;
  }

  /** Picker 返回的目标 URI 通常带最终文件名；若只给 opaque ID，则保留建议名。 */
  private savedDisplayName(uri: string, suggested: string): string {
    const query: number = uri.indexOf('?');
    const withoutQuery: string = query >= 0 ? uri.substring(0, query) : uri;
    const lastSlash: number = Math.max(withoutQuery.lastIndexOf('/'), withoutQuery.lastIndexOf('\\'));
    const encodedName: string = lastSlash >= 0 ? withoutQuery.substring(lastSlash + 1) : withoutQuery;
    let decodedName: string = encodedName;
    try {
      decodedName = decodeURIComponent(encodedName);
    } catch (_error) {
      // URI 中有非标准百分号编码时仍保留原候选名称。
    }
    const name: string = this.fileNameFromUriSegment(decodedName);
    const lower: string = name.toLowerCase();
    return lower.endsWith('.gds') || lower.endsWith('.gdsii') || lower.endsWith('.oas') ||
      lower.endsWith('.oasis') || lower.endsWith('.svg') || lower.endsWith('.png') ? name : suggested;
  }

  private fileNameFromUriSegment(value: string): string {
    const lastSlash: number = Math.max(value.lastIndexOf('/'), value.lastIndexOf('\\'));
    return lastSlash >= 0 ? value.substring(lastSlash + 1) : value;
  }

  private fileStem(path: string): string {
    if (path.length === 0) {
      return '';
    }
    const slash: number = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const fileName: string = slash >= 0 ? path.substring(slash + 1) : path;
    const dot: number = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(0, dot) : fileName;
  }

  private sanitizeFileStem(value: string): string {
    let out: string = '';
    for (let i = 0; i < value.length; i++) {
      const c: string = value.charAt(i);
      const code: number = value.charCodeAt(i);
      if ((code >= 48 && code <= 57) || (code >= 65 && code <= 90) || (code >= 97 && code <= 122)) {
        out += c;
      } else if (c === '_' || c === '-') {
        out += c;
      }
    }
    if (out.length === 0) {
      out = 'hongtu-layout';
    }
    return out;
  }

  private sanitizeGdsName(value: string, fallback: string): string {
    const raw: string = value.length > 0 ? value : fallback;
    if (layoutUtf8Bytes(raw) > 65530 || raw.indexOf('\u0000') >= 0) throw new Error('GDSII 名称无法完整保存');
    return raw;
  }

  private sanitizeGdsString(value: string, fallback: string): string {
    let out: string = '';
    const raw: string = value.length > 0 ? value : fallback;
    for (let i = 0; i < raw.length && out.length < 512; i++) {
      const code: number = raw.charCodeAt(i);
      if (code >= 32 && code <= 126) {
        out += raw.charAt(i);
      } else {
        out += '?';
      }
    }
    if (out.length === 0) {
      return fallback;
    }
    return out;
  }

  private layerNumber(shape: Shape): number {
    if (!Number.isInteger(shape.layerNumber) || shape.layerNumber < 0 || shape.layerNumber > 32767) throw new Error('图层号必须在 0..32767 范围内');
    return shape.layerNumber;
  }

  private datatype(shape: Shape): number {
    if (!Number.isInteger(shape.datatype) || shape.datatype < 0 || shape.datatype > 32767) throw new Error('Datatype 必须在 0..32767 范围内');
    return shape.datatype;
  }

}

export const layoutExportService = new LayoutExportService();
