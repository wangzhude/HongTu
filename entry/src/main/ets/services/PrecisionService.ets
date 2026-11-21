import { Point } from '../models/GdsiiData';

/** All values are nanometres; display and placement are intentionally independent. */
export interface PrecisionSettings {
  dbuNm: number;
  drawStepNm: number;
  displayGridNm: number;
  geometrySnapEnabled: boolean;
  geometrySnapKinds: string[];
}

export interface QuantizedValue {
  requestedNm: number;
  writtenNm: number;
  databaseValue: number;
  deltaNm: number;
  changed: boolean;
}

export interface QuantizationReport {
  count: number;
  changedCount: number;
  maxDeltaNm: number;
  firstChange?: QuantizedValue;
}

export const GEOMETRY_SNAP_KINDS: string[] = ['顶点', '交点', '中点', '包围盒中心', '边'];

/** Documents saved before precision settings used one grid for drawing and display. */
export function legacyDocumentPrecision(physicalUnits: number, gridSize: number): PrecisionSettings {
  return {
    dbuNm: physicalUnits * 1e9,
    drawStepNm: gridSize,
    displayGridNm: gridSize,
    geometrySnapEnabled: true,
    geometrySnapKinds: GEOMETRY_SNAP_KINDS.slice()
  };
}

export function validatePrecision(settings: PrecisionSettings): string {
  if (!Number.isFinite(settings.dbuNm) || settings.dbuNm <= 0 || settings.dbuNm > 1000000) return '文件 DBU 须为正有限数，最大 1000000 nm';
  if (!Number.isFinite(settings.drawStepNm) || settings.drawStepNm < 0 || settings.drawStepNm > 1000000) return '绘制步长须为 0–1000000 nm，0 表示关闭网格吸附';
  if (!Number.isFinite(settings.displayGridNm) || settings.displayGridNm <= 0 || settings.displayGridNm > 1000000) return '显示网格须为正有限数，最大 1000000 nm';
  if (settings.geometrySnapKinds.some((kind: string) => GEOMETRY_SNAP_KINDS.indexOf(kind) < 0)) return '吸附类型无效';
  if (settings.geometrySnapEnabled && settings.geometrySnapKinds.length === 0) return '请至少选择一种几何吸附目标';
  return '';
}

/** Match native llround/GDS writer: half DBUs are rounded away from zero. */
export function quantizeToDbu(requestedNm: number, dbuNm: number): QuantizedValue {
  if (!Number.isFinite(requestedNm) || !Number.isFinite(dbuNm) || dbuNm <= 0) throw new Error('坐标与 DBU 必须为有限值，DBU 必须大于 0');
  const raw: number = requestedNm / dbuNm;
  const databaseValue: number = raw < 0 ? -Math.round(-raw) : Math.round(raw);
  if (!Number.isSafeInteger(databaseValue)) throw new Error('坐标超出可精确表达的数据库单位范围');
  const writtenNm: number = databaseValue * dbuNm;
  const deltaNm: number = writtenNm - requestedNm;
  return { requestedNm, writtenNm, databaseValue, deltaNm, changed: Math.abs(deltaNm) > Math.max(1e-12, Math.abs(requestedNm) * Number.EPSILON * 4) };
}

export function quantizePoint(point: Point, dbuNm: number): Point {
  return { x: quantizeToDbu(point.x, dbuNm).writtenNm, y: quantizeToDbu(point.y, dbuNm).writtenNm };
}

export function quantizationReport(valuesNm: number[], dbuNm: number): QuantizationReport {
  const report: QuantizationReport = { count: valuesNm.length, changedCount: 0, maxDeltaNm: 0 };
  for (let i = 0; i < valuesNm.length; i++) {
    const value: QuantizedValue = quantizeToDbu(valuesNm[i], dbuNm);
    if (value.changed) {
      report.changedCount++;
      report.maxDeltaNm = Math.max(report.maxDeltaNm, Math.abs(value.deltaNm));
      if (report.firstChange === undefined) report.firstChange = value;
    }
  }
  return report;
}

/** 消除 physicalUnits * 1e9（如 1e-7 * 1e9 = 100.00000000000001）的 IEEE-754 尾数噪音 */
export function cleanMetricNumber(value: number): number {
  if (!Number.isFinite(value)) {
    return value;
  }
  return Number(value.toPrecision(12));
}

export function cleanDbuNm(physicalUnitsMeters: number): number {
  return cleanMetricNumber(physicalUnitsMeters * 1e9);
}

export function quantizationText(requestedNm: number, dbuNm: number): string {
  const cleanDbu: number = cleanMetricNumber(dbuNm);
  const value: QuantizedValue = quantizeToDbu(requestedNm, cleanDbu);
  return `输入 ${cleanMetricNumber(value.requestedNm)} / 写入 ${cleanMetricNumber(value.writtenNm)} nm · 偏差 ${Number(value.deltaNm.toPrecision(4))} nm`;
}
