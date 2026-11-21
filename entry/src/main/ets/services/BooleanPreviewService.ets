import { Shape, ShapeType, Point, getShapeBounds, normalizePropRecords } from '../models/GdsiiData';
import { editService } from './EditService';
import type { EditStructureState } from './EditService';
import { nativeHongTuService } from './NativeHongTuService';
import { mergeBooleanSourceProperties } from './ShapePropertyService';
import type { BooleanOpType } from '../../cpp/types/libhongtu/Index';

export type PreviewBooleanOp = 'merge' | 'subtract' | 'intersect' | 'xor';
export interface BooleanPreviewOptions {
  op: PreviewBooleanOp;
  sourceAId: number;
  sourceBId: number;
  outputLayer: number;
  outputDatatype: number;
  keepSources: boolean;
}
export interface BooleanPreview {
  options: BooleanPreviewOptions;
  sourceA: Shape;
  sourceB: Shape;
  outputs: Shape[];
  revision: number;
  cellId: number;
  sourceFingerprint: string;
  areaNm2: number;
}
export interface BooleanPreviewResult { ok: boolean; message: string; preview?: BooleanPreview; }

function yieldForPreview(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 0);
  });
}

interface QuantizedFlatPolygon {
  coords: number[];
  quantizedCount: number;
}

function polygonCoordinatesQuantized(shape: Shape): QuantizedFlatPolygon | null {
  if (shape.type === ShapeType.RECT) {
    const b = getShapeBounds(shape);
    const raw: number[] = [b.minX, b.minY, b.maxX, b.minY, b.maxX, b.maxY, b.minX, b.maxY];
    let quantizedCount: number = 0;
    const out: number[] = [];
    for (const v of raw) {
      if (!Number.isFinite(v) || Math.abs(v) > 1e14) return null;
      const rounded: number = Math.round(v);
      if (!Number.isSafeInteger(rounded)) return null;
      if (rounded !== v) quantizedCount++;
      out.push(rounded);
    }
    return { coords: out, quantizedCount: quantizedCount };
  }
  let points: Point[] = shape.points;
  if (points.length > 3 && points[0].x === points[points.length - 1].x && points[0].y === points[points.length - 1].y) {
    points = points.slice(0, -1);
  }
  let quantizedCount: number = 0;
  const dedup: Point[] = [];
  for (const point of points) {
    if (!Number.isFinite(point.x) || !Number.isFinite(point.y) ||
        Math.abs(point.x) > 1e14 || Math.abs(point.y) > 1e14) {
      return null;
    }
    const qx: number = Math.round(point.x);
    const qy: number = Math.round(point.y);
    if (!Number.isSafeInteger(qx) || !Number.isSafeInteger(qy)) return null;
    if (qx !== point.x) quantizedCount++;
    if (qy !== point.y) quantizedCount++;
    if (dedup.length === 0 || dedup[dedup.length - 1].x !== qx || dedup[dedup.length - 1].y !== qy) {
      dedup.push({ x: qx, y: qy });
    }
  }
  while (dedup.length > 3 && dedup[0].x === dedup[dedup.length - 1].x && dedup[0].y === dedup[dedup.length - 1].y) {
    dedup.pop();
  }
  const result: number[] = [];
  for (const p of dedup) result.push(p.x, p.y);
  return { coords: result, quantizedCount: quantizedCount };
}

interface BooleanValidationResult {
  error?: string;
  sourceA?: Shape;
  sourceB?: Shape;
  flatA?: number[];
  flatB?: number[];
  cellId?: number;
  revision?: number;
  quantizedCount?: number;
}

/** Preview computes without mutating the document; apply rechecks the exact source and revision. */
export class BooleanPreviewService {
  private validateInputs(options: BooleanPreviewOptions): BooleanValidationResult {
    if (options.sourceAId === options.sourceBId) return { error: 'A 和 B 必须是两个不同对象' };
    if (!Number.isInteger(options.outputLayer) || !Number.isInteger(options.outputDatatype) ||
      options.outputLayer < 0 || options.outputLayer > 32767 || options.outputDatatype < 0 || options.outputDatatype > 32767) {
      return { error: '输出 layer/datatype 必须为 0–32767 的整数' };
    }
    if (!editService.canEditLayer(options.outputLayer, options.outputDatatype)) {
      return { error: '输出图层不可编辑，请解除锁定或选择其它层' };
    }
    const shapes: Shape[] = editService.getShapes();
    const sourceA: Shape | undefined = shapes.find((shape: Shape) => shape.id === options.sourceAId);
    const sourceB: Shape | undefined = shapes.find((shape: Shape) => shape.id === options.sourceBId);
    if (sourceA === undefined || sourceB === undefined) return { error: '源对象已不存在，请重新选择' };
    const cellId: number = editService.getCurrentCellId();
    const flats: number[][] = [];
    let quantizedTotal: number = 0;
    for (const shape of [sourceA, sourceB]) {
      if ((shape.ownerCellId ?? editService.getTopCellId()) !== cellId) {
        return { error: 'A/B 必须在当前 Cell，跨层级对象请先进入目标 Cell' };
      }
      if (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON) {
        return { error: '仅支持矩形和普通多边形；实例请先转换为图形' };
      }
      if (!options.keepSources && !editService.canEditLayer(shape.layerNumber, shape.datatype)) {
        return { error: '源图层已锁定；可保留原图输出到可编辑层' };
      }
      const qPoly: QuantizedFlatPolygon | null = polygonCoordinatesQuantized(shape);
      if (qPoly === null || qPoly.coords.length < 6) {
        return { error: '几何坐标无效或顶点数不足，原图已保留' };
      }
      quantizedTotal += qPoly.quantizedCount;
      flats.push(qPoly.coords);
    }
    return {
      sourceA,
      sourceB,
      flatA: flats[0],
      flatB: flats[1],
      cellId,
      revision: editService.getSessionRevision(),
      quantizedCount: quantizedTotal,
    };
  }

  private buildPreviewOutputs(
    options: BooleanPreviewOptions,
    sourceA: Shape,
    sourceB: Shape,
    polygons: number[][],
    cellId: number,
    revision: number,
    quantizedCount: number = 0
  ): BooleanPreviewResult {
    const mergedProps = mergeBooleanSourceProperties(sourceA.properties, sourceB.properties);
    const outputs: Shape[] = [];
    let areaNm2: number = 0;
    for (const flat of polygons) {
      if (flat.length < 6 || flat.length % 2 !== 0 || flat.some((value: number) => !Number.isSafeInteger(value))) {
        return { ok: false, message: '预览返回了不完整的几何，原图已保留' };
      }
      const points: Point[] = [];
      for (let i: number = 0; i < flat.length; i += 2) points.push({ x: flat[i], y: flat[i + 1] });
      let twiceArea: number = 0;
      const origin: Point = points[0];
      for (let i: number = 0; i < points.length; i++) {
        const a: Point = points[i]; const b: Point = points[(i + 1) % points.length];
        twiceArea += (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y);
      }
      areaNm2 += Math.abs(twiceArea) / 2;
      outputs.push({
        id: 0,
        type: ShapeType.POLYGON,
        layerNumber: options.outputLayer,
        datatype: options.outputDatatype,
        ownerCellId: cellId,
        points: points,
        selected: false,
        properties: normalizePropRecords(mergedProps),
      });
    }
    const preview: BooleanPreview = {
      options: {
        op: options.op,
        sourceAId: options.sourceAId,
        sourceBId: options.sourceBId,
        outputLayer: options.outputLayer,
        outputDatatype: options.outputDatatype,
        keepSources: options.keepSources,
      },
      sourceA: sourceA,
      sourceB: sourceB,
      outputs: outputs,
      revision: revision,
      cellId: cellId,
      sourceFingerprint: JSON.stringify([sourceA, sourceB]),
      areaNm2: areaNm2,
    };
    return {
      ok: true,
      message: outputs.length === 0
        ? '结果为空；应用后按保留原图选项处理源对象'
        : `预览 ${outputs.length} 个多边形${quantizedCount > 0 ? `（已按 1 nm 网格对齐 ${quantizedCount} 个浮点坐标）` : ''}`,
      preview: preview,
    };
  }

  prepare(options: BooleanPreviewOptions): BooleanPreviewResult {
    const validated = this.validateInputs(options);
    if (validated.error !== undefined) return { ok: false, message: validated.error };
    const op: BooleanOpType = options.op === 'intersect' ? 0 : options.op === 'merge' ? 1 : options.op === 'subtract' ? 2 : 3;
    const computed = nativeHongTuService.booleanOpForEdit(validated.flatA!, validated.flatB!, op);
    if (!computed.success) return { ok: false, message: `布尔预览失败：${computed.errorMessage}` };
    return this.buildPreviewOutputs(
      options,
      validated.sourceA!,
      validated.sourceB!,
      computed.polygons,
      validated.cellId!,
      validated.revision!,
      validated.quantizedCount ?? 0
    );
  }

  /**
   * 异步分片布尔预览：在多边形裁剪与海量输出轮廓重建间协作让出事件循环，
   * 并在提交预览前复核会话修订版本，避免复杂多边形阻塞 UI 帧刷新。
   */
  async prepareAsync(options: BooleanPreviewOptions): Promise<BooleanPreviewResult> {
    const validated = this.validateInputs(options);
    if (validated.error !== undefined) return { ok: false, message: validated.error };
    const startRevision: number = validated.revision!;
    const startCellId: number = validated.cellId!;
    await yieldForPreview();
    if (startRevision !== editService.getSessionRevision() || startCellId !== editService.getCurrentCellId()) {
      return { ok: false, message: '文档或编辑范围已变化，请重新生成预览' };
    }
    const op: BooleanOpType = options.op === 'intersect' ? 0 : options.op === 'merge' ? 1 : options.op === 'subtract' ? 2 : 3;
    const computed = nativeHongTuService.booleanOpForEdit(validated.flatA!, validated.flatB!, op);
    if (!computed.success) return { ok: false, message: `布尔预览失败：${computed.errorMessage}` };
    if (computed.polygons.length > 256) {
      await yieldForPreview();
      if (startRevision !== editService.getSessionRevision() || startCellId !== editService.getCurrentCellId()) {
        return { ok: false, message: '文档或编辑范围已变化，请重新生成预览' };
      }
    }
    return this.buildPreviewOutputs(
      options,
      validated.sourceA!,
      validated.sourceB!,
      computed.polygons,
      startCellId,
      startRevision,
      validated.quantizedCount ?? 0
    );
  }

  apply(preview: BooleanPreview, structure: EditStructureState): BooleanPreviewResult {
    if (preview.revision !== editService.getSessionRevision() || preview.cellId !== editService.getCurrentCellId()) {
      return { ok: false, message: '文档或编辑范围已变化，请重新生成预览' };
    }
    const all: Shape[] = editService.getShapes();
    const a: Shape | undefined = all.find((shape: Shape) => shape.id === preview.options.sourceAId);
    const b: Shape | undefined = all.find((shape: Shape) => shape.id === preview.options.sourceBId);
    if (a === undefined || b === undefined || JSON.stringify([a, b]) !== preview.sourceFingerprint) return { ok: false, message: 'A/B 已变化，请重新生成预览' };
    if (!editService.canEditLayer(preview.options.outputLayer, preview.options.outputDatatype) ||
      (!preview.options.keepSources && (!editService.canEditLayer(a.layerNumber, a.datatype) || !editService.canEditLayer(b.layerNumber, b.datatype)))) {
      return { ok: false, message: '图层状态已变化，请检查源图层和输出图层' };
    }
    if (preview.options.keepSources && preview.outputs.length === 0) {
      return { ok: true, message: '布尔结果为空，已保留原图；未产生编辑' };
    }
    const candidate: Shape[] = preview.options.keepSources ? all.slice() : all.filter((shape: Shape) => shape.id !== a.id && shape.id !== b.id);
    if (candidate.length + preview.outputs.length > 1000000) return { ok: false, message: '结果超过编辑对象预算，原图已保留' };
    let totalPoints: number = 0;
    for (const existing of candidate) totalPoints += existing.points.length;
    for (const out of preview.outputs) totalPoints += out.points.length;
    if (totalPoints > 4000000) return { ok: false, message: '结果超过 400 万坐标点预算，原图已保留' };
    let nextId: number = editService.getNextShapeId();
    const ids: number[] = [];
    for (const output of preview.outputs) {
      const copy: Shape = { id: nextId++, type: ShapeType.POLYGON, layerNumber: output.layerNumber, datatype: output.datatype,
        ownerCellId: preview.cellId, points: output.points.map((point: Point): Point => ({ x: point.x, y: point.y })),
        selected: false, properties: normalizePropRecords(output.properties) };
      candidate.push(copy); ids.push(copy.id);
    }
    if (!editService.applyDocumentStructure(candidate, structure, structure,
      `布尔 ${preview.options.op} → L${preview.options.outputLayer}/D${preview.options.outputDatatype} · ${ids.length} 个结果`, true, ids)) return { ok: false, message: '提交被拒绝，原图已保留' };
    return { ok: true, message: `布尔结果已应用：${ids.length} 个对象，可一次撤销` };
  }
}
export const booleanPreviewService: BooleanPreviewService = new BooleanPreviewService();
