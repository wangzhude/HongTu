export interface PCellPlacementOptions {
  outputMode: string; // 'instance' or 'polygon'
  datatype: number;
  maxErrorNm: number;
}

export interface CurveApproximation {
  segments: number;
  errorNm: number;
  pointCount: number;
}

export function isCurvePCell(name: string): boolean {
  return ['CIRCLE', 'ELLIPSE', 'DONUT', 'ARC'].indexOf(name) >= 0;
}

/** Same conservative chord bound as native. DBU rounding is an additional error. */
export function curveApproximation(name: string, params: Record<string, number | string | boolean>): CurveApproximation | null {
  if (!isCurvePCell(name)) return null;
  const radius: number = name === 'CIRCLE' ? Number(params['radius']) : name === 'ELLIPSE'
    ? Math.max(Number(params['radius_x']), Number(params['radius_y'])) : Number(params['outer_radius']);
  let sweep: number = 2 * Math.PI;
  if (name === 'ARC') {
    let degrees: number = Number(params['end_angle']) - Number(params['start_angle']);
    if (degrees <= 0) degrees += 360;
    if (degrees <= 0 || degrees > 360) throw new Error('圆弧角度跨度必须在 0–360° 之间');
    sweep = degrees * Math.PI / 180;
  }
  const minimum: number = Number(params['segments']);
  const maxError: number = Number(params['max_error'] ?? 0);
  if (!Number.isFinite(radius) || radius <= 0 || !Number.isInteger(minimum) || minimum < (name === 'ARC' ? 4 : 8) ||
    !Number.isFinite(maxError) || maxError < 0) throw new Error('曲线尺寸、边数与近似偏差无效');
  let segments: number = minimum;
  if (maxError > 0) {
    const halfStep: number = Math.acos(1 - Math.min(1, maxError / radius));
    if (!(halfStep > 0)) throw new Error('近似精度过小，无法可靠计算边数');
    segments = Math.max(segments, Math.ceil(sweep / (2 * halfStep)));
  }
  if (name === 'ELLIPSE') segments = Math.ceil(segments / 4) * 4;
  if (segments > 4096) throw new Error('近似精度需要超过 4096 段，请增大允许偏差');
  return { segments, errorNm: radius * (1 - Math.cos(sweep / (2 * segments))),
    pointCount: name === 'DONUT' || name === 'ARC' ? (segments + 1) * 2 : segments };
}
