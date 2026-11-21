import { ShapeType } from '../models/GdsiiData';
import type { Point, Shape } from '../models/GdsiiData';
import type { ResolvedPort } from '../models/LayoutPort';
import type { RouteMaterialBand, RouteMaterialProfile, RouteMaterialCap } from '../models/RouteMaterial';
import type { OpticalRouteRequest, OpticalRouteResult, OpticalRouteGeometry, OpticalCurvePrimitive,
  OpticalCurveSample, OpticalRouteBudget, OpticalPortError, OpticalMaterialSource, OpticalBendRequest,
  OpticalBendGeometry, OpticalRouteObstacle, OpticalRouteCertificate } from '../models/OpticalRoute';
import { cloneStructured } from '../common/CloneUtils';

interface CurveValue { point: Point; heading: number; curvature: number; }
interface Candidate { primitives: OpticalCurvePrimitive[]; mode: string; length: number; }
interface TurnSpec { turn: number; straight: number; kind: 'straight' | 'circular' | 'euler'; }
interface RootValue { residual: number; straight: number; secondTurn: number; valid: boolean; }
interface Sampling { samples: OpticalCurveSample[]; error: number; integration: number; }
interface CapOutput { caps: RouteMaterialCap[]; errors: OpticalPortError[]; }
interface MaterialOutput { shapes: Shape[]; sources: OpticalMaterialSource[]; }
const TAU: number = 2 * Math.PI;
const MAX_INT32: number = 2147483647;
function fail(message: string): never { throw new Error('光学布线：' + message); }
function finite(value: number, label: string, positive: boolean = false): void {
  if (!Number.isFinite(value) || (positive && value <= 0)) fail(label + (positive ? '必须为有限正数' : '必须为有限数'));
}
function add(a: Point, b: Point): Point { return { x: a.x + b.x, y: a.y + b.y }; }
function sub(a: Point, b: Point): Point { return { x: a.x - b.x, y: a.y - b.y }; }
function times(a: Point, scale: number): Point { return { x: a.x * scale, y: a.y * scale }; }
function distance(a: Point, b: Point): number { return Math.hypot(a.x - b.x, a.y - b.y); }
function dot(a: Point, b: Point): number { return a.x * b.x + a.y * b.y; }
function cross(a: Point, b: Point): number { return a.x * b.y - a.y * b.x; }
function rotate(p: Point, angle: number): Point {
  const c: number = Math.cos(angle), s: number = Math.sin(angle); return { x: p.x * c - p.y * s, y: p.x * s + p.y * c };
}
function unit(angle: number): Point { return { x: Math.cos(angle), y: Math.sin(angle) }; }
function mod(angle: number): number { return ((angle % TAU) + TAU) % TAU; }
function signed(angle: number): number { return mod(angle + Math.PI) - Math.PI; }
function close(a: number, b: number): boolean { return Math.abs(a - b) <= Math.max(1, Math.abs(a), Math.abs(b)) * 1e-10; }
function layer(number: number, datatype: number): void {
  if (!Number.isInteger(number) || !Number.isInteger(datatype) || number < 0 || datatype < 0 || number > 32767 || datatype > 32767) fail('图层号/datatype 必须为 0–32767 整数');
}
function point(p: Point, dbu: number): void {
  if (p === null || p === undefined) fail('坐标为空'); finite(p.x, 'X'); finite(p.y, 'Y');
  if (Math.abs(p.x / dbu) > MAX_INT32 || Math.abs(p.y / dbu) > MAX_INT32) fail('坐标超过 GDS int32/DBU 范围');
}
function exact(value: number, dbu: number): number {
  const q: number = Math.round(value / dbu);
  if (Math.abs(value / dbu - q) > Math.max(1e-8, Math.abs(value / dbu) * Number.EPSILON * 32)) fail('端面/坐标无法精确落在 DBU；可明确指定端口量化误差政策');
  return q * dbu;
}
function frame(port: ResolvedPort, dbu: number): void {
  if (port === null || port === undefined || port.definition === null || port.definition === undefined) fail('端口为空');
  point(port.centerNm, dbu); finite(port.orientationDeg, '端口方向'); finite(port.effectiveWidthNm, '实际孔径', true);
  finite(port.frameMagnification, '完整 MAG', true); finite(port.definition.widthNm, '固有孔径', true);
  if (typeof port.frameMirror !== 'boolean' || !close(port.definition.widthNm * port.frameMagnification, port.effectiveWidthNm)) fail('端口完整 frame 与实际孔径不一致');
  if (port.definition.portType !== 'optical') fail('必须使用实际 optical 端口');
  layer(port.definition.layerNumber, port.definition.datatype);
}

/** Fresnel power series, evaluated before mirroring. The largest phase is pi.
 * Forty terms make truncation < 1e-45 at that phase; floating error is accounted
 * separately. This is an actual integral of unit-speed tangent, not a fitted arc. */
function clothoid(s: number, radius: number, rampLength: number): Point {
  if (s === 0) return { x: 0, y: 0 };
  const phase: number = s * s / (2 * radius * rampLength);
  let cosine: number = 1, sine: number = phase, x: number = 0, y: number = 0;
  for (let n: number = 0; n < 40; n++) {
    x += cosine / (4 * n + 1); y += sine / (4 * n + 3);
    cosine *= -phase * phase / ((2 * n + 1) * (2 * n + 2));
    sine *= -phase * phase / ((2 * n + 2) * (2 * n + 3));
  }
  return { x: s * x, y: s * y };
}
function bendValue(kind: 'circular' | 'euler', radius: number, turn: number, fraction: number, station: number): CurveValue {
  const sign: number = turn < 0 ? -1 : 1, angle: number = Math.abs(turn);
  const length: number = angle * radius * (kind === 'euler' ? 1 + fraction : 1);
  const s: number = Math.min(length, Math.max(0, station));
  if (kind === 'circular' || fraction === 0) {
    const theta: number = s / radius;
    return { point: { x: radius * Math.sin(theta), y: sign * 2 * radius * Math.sin(theta / 2) ** 2 }, heading: sign * theta, curvature: sign / radius };
  }
  const ramp: number = fraction * angle * radius, arcLength: number = (1 - fraction) * angle * radius;
  const first: Point = clothoid(ramp, radius, ramp), firstHeading: number = fraction * angle / 2;
  const middle: Point = rotate({ x: radius * Math.sin(arcLength / radius), y: 2 * radius * Math.sin(arcLength / radius / 2) ** 2 }, firstHeading);
  const end: Point = add(add(first, middle), rotate({ x: first.x, y: -first.y }, angle));
  let value: Point, heading: number, curvature: number;
  if (s <= ramp) { value = clothoid(s, radius, ramp); heading = s * s / (2 * radius * ramp); curvature = s / (radius * ramp); }
  else if (s <= ramp + arcLength) {
    const theta: number = (s - ramp) / radius;
    value = add(first, rotate({ x: radius * Math.sin(theta), y: 2 * radius * Math.sin(theta / 2) ** 2 }, firstHeading));
    heading = firstHeading + theta; curvature = 1 / radius;
  } else {
    const remaining: number = length - s, tail: Point = clothoid(remaining, radius, ramp);
    value = sub(end, rotate({ x: tail.x, y: -tail.y }, angle));
    heading = angle - remaining * remaining / (2 * radius * ramp); curvature = remaining / (radius * ramp);
  }
  return { point: { x: value.x, y: sign * value.y }, heading: sign * heading, curvature: sign * curvature };
}
function evaluate(primitive: OpticalCurvePrimitive, station: number): CurveValue {
  if (primitive.kind === 'straight') return { point: add(primitive.startNm, times(unit(primitive.startHeadingRad), station)), heading: primitive.startHeadingRad, curvature: 0 };
  const value: CurveValue = bendValue(primitive.kind, primitive.minimumRadiusNm, primitive.turnRad, primitive.eulerFraction, station);
  return { point: add(primitive.startNm, rotate(value.point, primitive.startHeadingRad)), heading: primitive.startHeadingRad + value.heading, curvature: value.curvature };
}
function sequence(start: Point, heading: number, specs: TurnSpec[], radius: number, fraction: number, mode: string): Candidate {
  let current: Point = { x: start.x, y: start.y }, angle: number = heading, length: number = 0;
  const primitives: OpticalCurvePrimitive[] = [];
  for (const spec of specs) {
    const size: number = spec.kind === 'straight' ? spec.straight : Math.abs(spec.turn) * radius * (spec.kind === 'euler' ? 1 + fraction : 1);
    if (size <= Math.max(1, radius) * 1e-13) continue;
    const primitive: OpticalCurvePrimitive = { kind: spec.kind, startNm: current, startHeadingRad: angle, lengthNm: size,
      turnRad: spec.turn, minimumRadiusNm: spec.kind === 'straight' ? 0 : radius, eulerFraction: spec.kind === 'euler' ? fraction : 0, startStationNm: length };
    primitives.push(primitive); const end: CurveValue = evaluate(primitive, size); current = end.point; angle = end.heading; length += size;
  }
  return { primitives: primitives, mode: mode, length: length };
}
function straightSpec(length: number): TurnSpec { return { turn: 0, straight: length, kind: 'straight' }; }
function turnSpec(turn: number, kind: 'circular' | 'euler'): TurnSpec { return { turn: turn, straight: 0, kind: kind }; }

class OpticalWorker {
  private work: number = 0;
  private maximumWork: number = 20000000;
  private maximumSamples: number = 4094;
  private maximumVertices: number = 131072;
  private maximumMaterials: number = 128;
  private solverIntervals: number = 256;
  private quantizationError: number = 0;
  private vertices: number = 0;
  private radius: number = 0;
  private fraction: number = 0.5;
  constructor(budget: OpticalRouteBudget | undefined) {
    if (budget === undefined) return;
    const values: number[] = [budget.maximumWork ?? this.maximumWork, budget.maximumSamples ?? this.maximumSamples,
      budget.maximumVertices ?? this.maximumVertices, budget.maximumMaterials ?? this.maximumMaterials, budget.maximumSolverIntervals ?? this.solverIntervals];
    const limits: number[] = [100000000, 32768, 1000000, 256, 4096];
    for (let i: number = 0; i < values.length; i++) if (!Number.isSafeInteger(values[i]) || values[i] < 1 || values[i] > limits[i]) fail('几何/求解预算无效或超过硬上限');
    this.maximumWork = values[0]; this.maximumSamples = values[1]; this.maximumVertices = values[2]; this.maximumMaterials = values[3]; this.solverIntervals = values[4];
  }
  private charge(count: number = 1): void { this.work += count; if (this.work > this.maximumWork) fail('几何执行超过明确工作预算，未发布部分结果'); }
  private numericalError(length: number, coordinate: number = 0): number {
    return Math.max(1, length, coordinate) * Number.EPSILON * 256;
  }
  private sampling(candidate: Candidate, tolerance: number, maximumOffset: number = 0, maximumOffsetSlope: number = 0): Sampling {
    const samples: OpticalCurveSample[] = [];
    let error: number = 0;
    for (const primitive of candidate.primitives) {
      const curvature: number = primitive.kind === 'straight' ? 0 : 1 / primitive.minimumRadiusNm;
      const derivative: number = primitive.kind === 'euler' && primitive.eulerFraction > 0 ?
        1 / (primitive.minimumRadiusNm * primitive.eulerFraction * Math.abs(primitive.turnRad) * primitive.minimumRadiusNm) : 0;
      const secondDerivative: number = curvature * (1 + maximumOffset * curvature) + 2 * maximumOffsetSlope * curvature + maximumOffset * derivative;
      const step: number = secondDerivative === 0 ? primitive.lengthNm : Math.sqrt(8 * tolerance / secondDerivative);
      const stops: number[] = [0];
      if (primitive.kind === 'euler' && primitive.eulerFraction > 0) {
        const ramp: number = primitive.eulerFraction * Math.abs(primitive.turnRad) * primitive.minimumRadiusNm;
        stops.push(ramp); if (primitive.eulerFraction < 1) stops.push(primitive.lengthNm - ramp);
      }
      stops.push(primitive.lengthNm);
      for (let at: number = 0; at < stops.length - 1; at++) {
        const span: number = stops[at + 1] - stops[at], count: number = Math.max(1, Math.ceil(span / step));
        if (samples.length + count > this.maximumSamples) fail('曲线精度需要超过明确取样预算');
        error = Math.max(error, secondDerivative * (span / count) ** 2 / 8);
        for (let i: number = samples.length === 0 ? 0 : 1; i <= count; i++) {
          this.charge(primitive.kind === 'euler' ? 40 : 1);
          const s: number = stops[at] + span * i / count, value: CurveValue = evaluate(primitive, s);
          samples.push({ pointNm: value.point, stationNm: primitive.startStationNm + s, headingRad: value.heading, curvaturePerNm: value.curvature });
        }
      }
    }
    if (samples.length < 2) fail('布线需要不同的完整端口 pose，零长度不可生成材料');
    const maximumCoordinate: number = samples.reduce((maximum: number, sample: OpticalCurveSample): number => Math.max(maximum, Math.abs(sample.pointNm.x), Math.abs(sample.pointNm.y)), 0);
    return { samples: samples, error: error, integration: this.numericalError(candidate.length, maximumCoordinate) * (1 + candidate.primitives.length / 8) };
  }
  private circularCandidates(start: Point, end: Point, startHeading: number, endHeading: number): Candidate[] {
    const local: Point = times(rotate(sub(end, start), -startHeading), 1 / this.radius);
    const bearing: number = Math.atan2(local.y, local.x), a: number = mod(-bearing), b: number = mod(endHeading - startHeading - bearing), d: number = Math.hypot(local.x, local.y);
    const sa: number = Math.sin(a), sb: number = Math.sin(b), ca: number = Math.cos(a), cb: number = Math.cos(b), cab: number = Math.cos(a - b);
    const candidates: Candidate[] = [];
    const append = (code: string, first: number, middle: number, last: number): void => {
      if (![first, middle, last].every((value: number): boolean => Number.isFinite(value) && value >= 0)) return;
      const specs: TurnSpec[] = [turnSpec(code[0] === 'L' ? first : -first, 'circular'), code[1] === 'S' ? straightSpec(middle * this.radius) : turnSpec(code[1] === 'L' ? middle : -middle, 'circular'), turnSpec(code[2] === 'L' ? last : -last, 'circular')];
      candidates.push(sequence(start, startHeading, specs, this.radius, 0, 'circular-' + code));
    };
    let squared: number = 2 + d * d - 2 * cab + 2 * d * (sa - sb);
    if (squared >= -1e-12) { const phi: number = Math.atan2(cb - ca, d + sa - sb); append('LSL', mod(-a + phi), Math.sqrt(Math.max(0, squared)), mod(b - phi)); }
    squared = 2 + d * d - 2 * cab + 2 * d * (sb - sa);
    if (squared >= -1e-12) { const phi: number = Math.atan2(ca - cb, d - sa + sb); append('RSR', mod(a - phi), Math.sqrt(Math.max(0, squared)), mod(-b + phi)); }
    squared = -2 + d * d + 2 * cab + 2 * d * (sa + sb);
    if (squared >= -1e-12) { const length: number = Math.sqrt(Math.max(0, squared)), phi: number = Math.atan2(-ca - cb, d + sa + sb) - Math.atan2(-2, length); append('LSR', mod(-a + phi), length, mod(-b + phi)); }
    squared = -2 + d * d + 2 * cab - 2 * d * (sa + sb);
    if (squared >= -1e-12) { const length: number = Math.sqrt(Math.max(0, squared)), phi: number = Math.atan2(ca + cb, d - sa - sb) - Math.atan2(2, length); append('RSL', mod(a - phi), length, mod(b - phi)); }
    let cosine: number = (6 - d * d + 2 * cab + 2 * d * (sa - sb)) / 8;
    if (Math.abs(cosine) <= 1 + 1e-12) { const middle: number = mod(TAU - Math.acos(Math.max(-1, Math.min(1, cosine)))), first: number = mod(a - Math.atan2(ca - cb, d - sa + sb) + middle / 2); append('RLR', first, middle, mod(a - b - first + middle)); }
    cosine = (6 - d * d + 2 * cab + 2 * d * (-sa + sb)) / 8;
    if (Math.abs(cosine) <= 1 + 1e-12) { const middle: number = mod(TAU - Math.acos(Math.max(-1, Math.min(1, cosine)))), first: number = mod(-a - Math.atan2(ca - cb, d + sa - sb) + middle / 2); append('LRL', first, middle, mod(b - a - first + middle)); }
    this.charge(6); return candidates;
  }
  private eulerCandidates(start: Point, end: Point, startHeading: number, endHeading: number, sbend: boolean): Candidate[] {
    const target: Point = rotate(sub(end, start), -startHeading), delta: number = signed(endHeading - startHeading), result: Candidate[] = [];
    const maximumAngle: number = sbend ? Math.PI / 2 : TAU;
    if (sbend && Math.abs(delta) > 1e-10) fail('S-bend 要求相向端口，即中心线首末切向平行');
    for (const firstSign of [1, -1]) for (const secondSign of [1, -1]) {
      if (sbend && firstSign === secondSign) continue;
      for (let winding: number = -2; winding <= 2; winding++) {
        if (sbend && winding !== 0) continue;
        const totalHeading: number = delta + TAU * winding;
        const intervalA: number = totalHeading / firstSign, intervalB: number = (totalHeading - secondSign * maximumAngle) / firstSign;
        const low: number = Math.max(0, Math.min(intervalA, intervalB)), high: number = Math.min(maximumAngle, Math.max(intervalA, intervalB));
        if (high < low) continue;
        const value = (angle: number): RootValue => {
          this.charge(80);
          const second: number = (totalHeading - firstSign * angle) / secondSign;
          if (second < -1e-10 || second > maximumAngle + 1e-10) return { residual: 0, straight: 0, secondTurn: second, valid: false };
          const a: number = firstSign * angle, b: number = secondSign * Math.max(0, second);
          const first: CurveValue = angle === 0 ? { point: { x: 0, y: 0 }, heading: 0, curvature: 0 } : bendValue('euler', this.radius, a, this.fraction, Math.abs(a) * this.radius * (1 + this.fraction));
          const last: CurveValue = Math.abs(b) < 1e-15 ? { point: { x: 0, y: 0 }, heading: 0, curvature: 0 } : bendValue('euler', this.radius, b, this.fraction, Math.abs(b) * this.radius * (1 + this.fraction));
          const remaining: Point = sub(target, add(first.point, rotate(last.point, a))), direction: Point = unit(a);
          return { residual: cross(remaining, direction), straight: dot(remaining, direction), secondTurn: b, valid: true };
        };
        const addRoot = (angle: number): void => {
          const solved: RootValue = value(angle);
          if (!solved.valid || solved.straight < -this.numericalError(distance(start, end)) || Math.abs(solved.residual) > this.numericalError(distance(start, end)) * 8) return;
          const candidate: Candidate = sequence(start, startHeading, [turnSpec(firstSign * angle, 'euler'), straightSpec(Math.max(0, solved.straight)), turnSpec(solved.secondTurn, 'euler')], this.radius, this.fraction,
            (sbend ? 's-bend-' : 'euler-') + (firstSign > 0 ? 'L' : 'R') + 'S' + (secondSign > 0 ? 'L' : 'R'));
          if (!result.some((old: Candidate): boolean => close(old.length, candidate.length) && old.mode === candidate.mode)) result.push(candidate);
        };
        let previousAngle: number = low, previous: RootValue = value(low);
        if (previous.valid && Math.abs(previous.residual) < this.numericalError(distance(start, end)) * 8) addRoot(low);
        for (let index: number = 1; index <= this.solverIntervals; index++) {
          const angle: number = low + (high - low) * index / this.solverIntervals, current: RootValue = value(angle);
          if (current.valid && Math.abs(current.residual) < this.numericalError(distance(start, end)) * 8) addRoot(angle);
          if (previous.valid && current.valid && previous.residual * current.residual < 0) {
            let left: number = previousAngle, right: number = angle, leftValue: number = previous.residual;
            for (let iteration: number = 0; iteration < 64; iteration++) {
              const middle: number = (left + right) / 2, mid: RootValue = value(middle);
              if (leftValue * mid.residual <= 0) right = middle; else { left = middle; leftValue = mid.residual; }
            }
            addRoot((left + right) / 2);
          }
          previousAngle = angle; previous = current;
        }
      }
    }
    return result;
  }
  private backbone(request: OpticalRouteRequest, kind: 'circular' | 'euler'): Candidate {
    const points: Point[] = request.backboneNm ?? [];
    if (points.length < 2 || points.length > 1024) fail('圆滑骨架须为 2–1024 个控制点');
    for (const p of points) point(p, request.dbuNm);
    if (distance(points[0], request.start.centerNm) > this.numericalError(distance(points[0], points[points.length - 1])) ||
      distance(points[points.length - 1], request.end.centerNm) > this.numericalError(distance(points[0], points[points.length - 1]))) fail('骨架必须连接真实端口中心');
    const headings: number[] = [], lengths: number[] = [];
    for (let i: number = 1; i < points.length; i++) {
      const vector: Point = sub(points[i], points[i - 1]), length: number = distance(points[i], points[i - 1]);
      if (length <= this.numericalError(this.radius)) fail('骨架含重复控制点'); headings.push(Math.atan2(vector.y, vector.x)); lengths.push(length);
    }
    if (Math.abs(signed(headings[0] - request.start.orientationDeg * Math.PI / 180)) > 1e-10 ||
      Math.abs(signed(headings[headings.length - 1] - (request.end.orientationDeg + 180) * Math.PI / 180)) > 1e-10) fail('骨架首末方向与真实端口不一致');
    const setbacks: number[] = [0], turns: number[] = [0];
    for (let i: number = 1; i < points.length - 1; i++) {
      const turn: number = signed(headings[i] - headings[i - 1]);
      if (Math.abs(turn) > Math.PI - 1e-8) fail('180° 骨架回折不能局部剪角，须用 pose 求解或提供真实回环空间');
      const end: CurveValue = Math.abs(turn) < 1e-12 ? { point: { x: 0, y: 0 }, heading: 0, curvature: 0 } : bendValue(kind, this.radius, turn, this.fraction, Math.abs(turn) * this.radius * (kind === 'euler' ? 1 + this.fraction : 1));
      const setback: number = Math.abs(turn) < 1e-12 ? 0 : end.point.x / (1 + Math.cos(turn));
      finite(setback, '弯曲实际切线占用'); setbacks.push(setback); turns.push(turn);
    }
    setbacks.push(0); turns.push(0);
    const specs: TurnSpec[] = [];
    for (let i: number = 0; i < lengths.length; i++) {
      const available: number = lengths[i] - setbacks[i] - setbacks[i + 1];
      if (available < -this.numericalError(lengths[i])) fail('骨架直线不足以容纳指定最小半径的真实弯曲占用');
      if (i === 0 && available + this.numericalError(lengths[i]) < (request.startLeadNm ?? 0)) fail('起点直线不满足明确 lead');
      if (i === lengths.length - 1 && available + this.numericalError(lengths[i]) < (request.endLeadNm ?? 0)) fail('终点直线不满足明确 lead');
      specs.push(straightSpec(Math.max(0, available))); if (i < lengths.length - 1) specs.push(turnSpec(turns[i + 1], kind));
    }
    return sequence(points[0], headings[0], specs, this.radius, this.fraction, kind + '-rounded-backbone');
  }
  /** Replace a real straight by four equal turns and three real straights.
   * For a bend endpoint (dx,dy), the four-turn family has displacement
   * (4dx + 2A cos(theta) + H, 0), and added arc length
   * 4Lbend - 4dx + 2A(1-cos(theta)). All values are geometry parameters. */
  private matchedCandidates(request: OpticalRouteRequest, original: Candidate[]): Candidate[] {
    if (request.targetLengthNm === undefined) return original;
    const target: number = request.targetLengthNm, tolerance: number = request.lengthToleranceNm ?? request.dbuNm;
    const kind: 'circular' | 'euler' = request.bend === 'circular' ? 'circular' : 'euler', result: Candidate[] = [];
    for (const candidate of original) {
      if (Math.abs(candidate.length - target) <= tolerance) { result.push(candidate); continue; }
      const delta: number = target - candidate.length;
      if (delta <= 0) continue;
      for (let index: number = 0; index < candidate.primitives.length; index++) {
        const straight: OpticalCurvePrimitive = candidate.primitives[index]; if (straight.kind !== 'straight') continue;
        // Preserve the entire explicit finite source-owner lead corridors.
        if ((index === 0 && (request.startLeadNm ?? 0) > 0) || (index === candidate.primitives.length - 1 && (request.endLeadNm ?? 0) > 0)) continue;
        const span: number = straight.lengthNm;
        const endpoint = (angle: number): CurveValue => {
          this.charge(40); return bendValue(kind, this.radius, angle, this.fraction, angle * this.radius * (kind === 'euler' ? 1 + this.fraction : 1));
        };
        let maximumAngle: number = Math.PI / 2;
        if (4 * endpoint(maximumAngle).point.x > span) {
          let low: number = 0, high: number = maximumAngle;
          for (let iteration: number = 0; iteration < 64; iteration++) { const middle: number = (low + high) / 2; if (4 * endpoint(middle).point.x <= span) low = middle; else high = middle; }
          maximumAngle = low;
        }
        if (maximumAngle <= 1e-10) continue;
        const baseExtra = (angle: number): number => {
          const length: number = angle * this.radius * (kind === 'euler' ? 1 + this.fraction : 1);
          return 4 * length - 4 * endpoint(angle).point.x;
        };
        // Include the compact A=0 solution for any small target delta.
        if (baseExtra(maximumAngle) >= delta) {
          let low: number = 0, high: number = maximumAngle;
          for (let iteration: number = 0; iteration < 64; iteration++) { const middle: number = (low + high) / 2; if (baseExtra(middle) <= delta) low = middle; else high = middle; }
          maximumAngle = (low + high) / 2;
        }
        for (let at: number = 1; at <= 16; at++) {
          const angle: number = maximumAngle * at / 16, bend: CurveValue = endpoint(angle);
          const length: number = angle * this.radius * (kind === 'euler' ? 1 + this.fraction : 1), extra: number = 4 * length - 4 * bend.point.x;
          const denominator: number = 4 * Math.sin(angle / 2) ** 2;
          const arm: number = (delta - extra) / denominator, horizontal: number = span - 4 * bend.point.x - 2 * arm * Math.cos(angle);
          if (!Number.isFinite(arm) || !Number.isFinite(horizontal) || arm < -this.numericalError(target) || horizontal < -this.numericalError(target)) continue;
          for (const side of [1, -1]) {
            const turn: number = angle * side, specs: TurnSpec[] = [];
            for (let before: number = 0; before < index; before++) { const p: OpticalCurvePrimitive = candidate.primitives[before]; specs.push(p.kind === 'straight' ? straightSpec(p.lengthNm) : turnSpec(p.turnRad, p.kind)); }
            specs.push(turnSpec(turn, kind), straightSpec(Math.max(0, arm)), turnSpec(-turn, kind), straightSpec(Math.max(0, horizontal)),
              turnSpec(-turn, kind), straightSpec(Math.max(0, arm)), turnSpec(turn, kind));
            for (let after: number = index + 1; after < candidate.primitives.length; after++) { const p: OpticalCurvePrimitive = candidate.primitives[after]; specs.push(p.kind === 'straight' ? straightSpec(p.lengthNm) : turnSpec(p.turnRad, p.kind)); }
            const first: OpticalCurvePrimitive = candidate.primitives[0];
            const matched: Candidate = sequence(first.startNm, first.startHeadingRad, specs, this.radius, this.fraction, candidate.mode + '-physical-meander-' + index + (side > 0 ? '-left' : '-right'));
            if (Math.abs(matched.length - target) <= tolerance + this.numericalError(target) * 8) result.push(matched);
          }
        }
      }
    }
    return result;
  }
  private profile(request: OpticalRouteRequest): RouteMaterialProfile {
    const profile: RouteMaterialProfile = request.materialProfile;
    if (profile === null || profile === undefined || profile.transitionKind === 'via') fail('光学材料须有真实截面；via 器件须显式分段及过渡，不能伪装连续波导');
    if (profile.transitionKind !== 'uniform' && profile.transitionKind !== 'linear-taper') fail('未知光学材料过渡');
    if (!Array.isArray(profile.startBands) || !Array.isArray(profile.endBands) || profile.startBands.length === 0 ||
      profile.startBands.length !== profile.endBands.length || profile.startBands.length > this.maximumMaterials) fail('起终材料条数不同或超过预算');
    const ids: Set<string> = new Set<string>();
    for (const start of profile.startBands) {
      this.charge(); layer(start.layerNumber, start.datatype); finite(start.minimumNm, '材料下界'); finite(start.maximumNm, '材料上界');
      if (typeof start.id !== 'string' || start.id.length === 0 || ids.has(start.id) || start.maximumNm <= start.minimumNm) fail('材料 strip 标识/宽度无效'); ids.add(start.id);
      const end: RouteMaterialBand | undefined = profile.endBands.find((band: RouteMaterialBand): boolean => band.id === start.id);
      if (end === undefined || end.layerNumber !== start.layerNumber || end.datatype !== start.datatype) fail('光学材料必须按同 id/真实 layer 匹配，跨层要显式器件');
      finite(end.minimumNm, '终材料下界'); finite(end.maximumNm, '终材料上界'); if (end.maximumNm <= end.minimumNm) fail('终材料无正宽度');
      if (profile.transitionKind === 'uniform' && (!close(start.minimumNm, end.minimumNm) || !close(start.maximumNm, end.maximumNm))) fail('uniform 材料世界 frame 不一致，不能忽略镜像/截面过渡');
    }
    const primary: RouteMaterialBand | undefined = profile.startBands.find((band: RouteMaterialBand): boolean => band.id === profile.primaryStripId);
    const last: RouteMaterialBand | undefined = profile.endBands.find((band: RouteMaterialBand): boolean => band.id === profile.primaryStripId);
    if (primary === undefined || last === undefined || primary.layerNumber !== request.start.definition.layerNumber || primary.datatype !== request.start.definition.datatype ||
      last.layerNumber !== request.end.definition.layerNumber || last.datatype !== request.end.definition.datatype ||
      !close(primary.maximumNm - primary.minimumNm, request.start.effectiveWidthNm) || !close(last.maximumNm - last.minimumNm, request.end.effectiveWidthNm)) fail('主材料实际孔径/图层与端口不一致');
    finite(profile.minimumBendRadiusNm, '截面最小半径'); if (profile.minimumBendRadiusNm < 0) fail('截面最小半径不能为负');
    return cloneStructured(profile) as RouteMaterialProfile;
  }
  private coordinate(p: Point, request: OpticalRouteRequest, cap: boolean): Point {
    point(p, request.dbuNm); this.charge();
    if (request.coordinatePolicy === 'strict' || (cap && request.coordinatePolicy !== 'quantize-with-port-tolerance')) return { x: exact(p.x, request.dbuNm), y: exact(p.y, request.dbuNm) };
    const q: Point = { x: Math.round(p.x / request.dbuNm) * request.dbuNm, y: Math.round(p.y / request.dbuNm) * request.dbuNm };
    this.quantizationError = Math.max(this.quantizationError, distance(p, q)); point(q, request.dbuNm); return q;
  }
  private intersection(a: Point, b: Point, c: Point, d: Point): boolean {
    this.charge();
    if (Math.max(a.x, b.x) < Math.min(c.x, d.x) || Math.max(c.x, d.x) < Math.min(a.x, b.x) || Math.max(a.y, b.y) < Math.min(c.y, d.y) || Math.max(c.y, d.y) < Math.min(a.y, b.y)) return false;
    const orientation = (u: Point, v: Point): number => {
      const value: number = cross(u, v), error: number = Math.hypot(u.x, u.y) * Math.hypot(v.x, v.y) * Number.EPSILON * 32;
      return Math.abs(value) <= error ? 0 : value < 0 ? -1 : 1;
    };
    const ab: Point = sub(b, a), cd: Point = sub(d, c);
    return orientation(ab, sub(c, a)) * orientation(ab, sub(d, a)) <= 0 && orientation(cd, sub(a, c)) * orientation(cd, sub(b, c)) <= 0;
  }
  private simple(points: Point[]): void {
    if (points.length < 3 || points.length > 8190) fail('物理 polygon 顶点不足或超过 GDS 保存预算');
    const origin: Point = points[0]; let area: number = 0;
    const order: number[] = points.map((_p: Point, index: number): number => index).sort((a: number, b: number): number =>
      Math.min(points[a].x, points[(a + 1) % points.length].x) - Math.min(points[b].x, points[(b + 1) % points.length].x));
    for (let index: number = 0; index < points.length; index++) {
      this.charge(); area += cross(sub(points[index], origin), sub(points[(index + 1) % points.length], origin));
      const i: number = order[index], a: Point = points[i], b: Point = points[(i + 1) % points.length];
      for (let next: number = index + 1; next < order.length; next++) {
        const j: number = order[next], c: Point = points[j], d: Point = points[(j + 1) % points.length];
        this.charge(); if (Math.min(c.x, d.x) > Math.max(a.x, b.x)) break;
        if (j === i || (i + 1) % points.length === j || (j + 1) % points.length === i) continue;
        if (this.intersection(a, b, c, d)) fail('真实材料自交/自接触；半径、宽度、回折或量化不可安全执行');
      }
    }
    if (!Number.isFinite(area) || Math.abs(area) < Number.EPSILON) fail('量化材料无正面积');
  }
  private polygon(points: Point[], request: OpticalRouteRequest, shapeId: number, layerNumber: number, datatype: number): Shape {
    const clean: Point[] = [];
    for (const p of points) if (clean.length === 0 || distance(clean[clean.length - 1], p) > 0) clean.push(p);
    if (clean.length > 1 && distance(clean[0], clean[clean.length - 1]) === 0) clean.pop();
    this.vertices += clean.length; if (this.vertices > this.maximumVertices) fail('材料总顶点超过明确预算'); this.simple(clean);
    return { id: shapeId, type: ShapeType.POLYGON, layerNumber: layerNumber, datatype: datatype, points: clean, selected: false, ownerCellId: request.ownerCellId };
  }
  private caps(request: OpticalRouteRequest, profile: RouteMaterialProfile): CapOutput {
    const caps: RouteMaterialCap[] = [], errors: OpticalPortError[] = [];
    for (let at: number = 0; at < 2; at++) {
      const port: ResolvedPort = at === 0 ? request.start : request.end;
      const bands: RouteMaterialBand[] = at === 0 ? profile.startBands : profile.endBands;
      const main: RouteMaterialBand | undefined = bands.find((row: RouteMaterialBand): boolean => row.id === profile.primaryStripId);
      if (main === undefined) fail('主材料端面缺失');
      const heading: number = (port.orientationDeg + (at === 0 ? 0 : 180)) * Math.PI / 180, normal: Point = rotate(unit(heading), Math.PI / 2);
      const low: Point = this.coordinate(add(port.centerNm, times(normal, main.minimumNm)), request, true);
      const high: Point = this.coordinate(add(port.centerNm, times(normal, main.maximumNm)), request, true);
      const vector: Point = sub(high, low), width: number = Math.hypot(vector.x, vector.y);
      if (width <= 0) fail('量化端面孔径退化');
      const actualMidpoint: Point = times(add(low, high), 0.5), expectedMidpoint: Point = add(port.centerNm, times(normal, (main.minimumNm + main.maximumNm) / 2));
      const error: OpticalPortError = { portId: port.definition.id, centerErrorNm: distance(actualMidpoint, expectedMidpoint),
        angleErrorDeg: Math.abs(signed(Math.atan2(vector.y, vector.x) - Math.atan2(normal.y, normal.x))) * 180 / Math.PI,
        widthErrorNm: Math.abs(width - port.effectiveWidthNm) };
      if (request.coordinatePolicy === 'quantize-with-port-tolerance') {
        const tolerance = request.portTolerance;
        if (tolerance === undefined || error.centerErrorNm > tolerance.maximumCenterErrorNm + this.numericalError(width) ||
          error.angleErrorDeg > tolerance.maximumAngleErrorDeg + 1e-9 || error.widthErrorNm > tolerance.maximumWidthErrorNm + this.numericalError(width)) fail('实际写入端面中心/方向/孔径误差超过明确端口容差');
      } else if (error.centerErrorNm > this.numericalError(width) || error.angleErrorDeg > 1e-8 || error.widthErrorNm > this.numericalError(width)) fail('严格端面误差无法满足');
      caps.push({ portId: port.definition.id, centerNm: { x: port.centerNm.x, y: port.centerNm.y }, lowerEdgeNm: low, upperEdgeNm: high,
        layerNumber: main.layerNumber, datatype: main.datatype, expectedWidthNm: port.effectiveWidthNm, actualWidthNm: width }); errors.push(error);
    }
    return { caps: caps, errors: errors };
  }
  private material(request: OpticalRouteRequest, profile: RouteMaterialProfile, candidate: Candidate, sampling: Sampling): MaterialOutput {
    const shapes: Shape[] = [], sources: OpticalMaterialSource[] = [];
    for (const start of profile.startBands) {
      const end: RouteMaterialBand | undefined = profile.endBands.find((row: RouteMaterialBand): boolean => row.id === start.id);
      if (end === undefined) fail('终端材料缺失');
      const lows: Point[] = [], highs: Point[] = [];
      for (let at: number = 0; at < sampling.samples.length; at++) {
        this.charge(); const sample: OpticalCurveSample = sampling.samples[at], proportion: number = sample.stationNm / candidate.length;
        const low: number = start.minimumNm + (end.minimumNm - start.minimumNm) * proportion, high: number = start.maximumNm + (end.maximumNm - start.maximumNm) * proportion;
        if (Math.min(1 - low * sample.curvaturePerNm, 1 - high * sample.curvaturePerNm) <= 1e-8) fail('材料 offset × 曲率产生内侧奇异/回折');
        const normal: Point = rotate(unit(sample.headingRad), Math.PI / 2), terminal: boolean = at === 0 || at === sampling.samples.length - 1;
        const center: Point = at === 0 ? request.start.centerNm : at === sampling.samples.length - 1 ? request.end.centerNm : sample.pointNm;
        const direction: Point = terminal ? rotate(unit((at === 0 ? request.start.orientationDeg : request.end.orientationDeg + 180) * Math.PI / 180), Math.PI / 2) : normal;
        lows.push(this.coordinate(add(center, times(direction, low)), request, terminal)); highs.push(this.coordinate(add(center, times(direction, high)), request, terminal));
      }
      const shape: Shape = this.polygon(lows.concat(highs.reverse()), request, request.firstShapeId + shapes.length, start.layerNumber, start.datatype);
      shapes.push(shape); sources.push({ shapeId: shape.id, materialId: start.id, kind: 'strip' });
    }
    const bbox = request.bboxSections ?? [];
    if (bbox.length + shapes.length > this.maximumMaterials) fail('bbox/strip 总数超过明确预算');
    if (bbox.length > 0) {
      let minX: number = Number.POSITIVE_INFINITY, minY: number = Number.POSITIVE_INFINITY, maxX: number = Number.NEGATIVE_INFINITY, maxY: number = Number.NEGATIVE_INFINITY;
      for (let index: number = 0; index < shapes.length; index++) if (sources[index].materialId === profile.primaryStripId) for (const p of shapes[index].points) {
        this.charge(); minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y);
      }
      const layers: Set<string> = new Set<string>();
      for (let at: number = 0; at < bbox.length; at++) {
        const row = bbox[at]; layer(row.layerNumber, row.datatype); finite(row.offsetNm, 'bbox 偏移');
        const key: string = row.layerNumber + '/' + row.datatype; if (layers.has(key)) fail('bbox 图层重复'); layers.add(key);
        if (maxX + row.offsetNm <= minX - row.offsetNm || maxY + row.offsetNm <= minY - row.offsetNm) fail('bbox 收缩后无正面积');
        const corners: Point[] = [{ x: minX - row.offsetNm, y: minY - row.offsetNm }, { x: maxX + row.offsetNm, y: minY - row.offsetNm },
          { x: maxX + row.offsetNm, y: maxY + row.offsetNm }, { x: minX - row.offsetNm, y: maxY + row.offsetNm }];
        const shape: Shape = this.polygon(corners.map((p: Point): Point => this.coordinate(p, request, false)), request, request.firstShapeId + shapes.length, row.layerNumber, row.datatype);
        shapes.push(shape); sources.push({ shapeId: shape.id, materialId: 'bbox-' + at, kind: 'bbox' });
      }
    }
    return { shapes: shapes, sources: sources };
  }
  private inside(p: Point, polygon: Point[]): boolean {
    let inside: boolean = false;
    for (let i: number = 0, j: number = polygon.length - 1; i < polygon.length; j = i++) {
      this.charge(); const a: Point = polygon[i], b: Point = polygon[j];
      if ((a.y > p.y) !== (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) inside = !inside;
    }
    return inside;
  }
  private segmentDistance(p: Point, a: Point, b: Point): number {
    this.charge(); const ab: Point = sub(b, a), squared: number = dot(ab, ab);
    if (squared <= 0) return distance(p, a); return distance(p, add(a, times(ab, Math.max(0, Math.min(1, dot(sub(p, a), ab) / squared)))));
  }
  private collision(shapes: Shape[], obstacles: OpticalRouteObstacle[], clearance: number, deviation: number): void {
    for (const shape of shapes) for (const obstacle of obstacles) {
      if (shape.layerNumber !== obstacle.layerNumber || shape.datatype !== obstacle.datatype) continue;
      const required: number = (obstacle.clearanceNm ?? clearance) + deviation;
      if (this.inside(shape.points[0], obstacle.pointsNm) || this.inside(obstacle.pointsNm[0], shape.points)) fail('实际材料与障碍重叠');
      for (let i: number = 0; i < shape.points.length; i++) for (let j: number = 0; j < obstacle.pointsNm.length; j++) {
        const a: Point = shape.points[i], b: Point = shape.points[(i + 1) % shape.points.length], c: Point = obstacle.pointsNm[j], d: Point = obstacle.pointsNm[(j + 1) % obstacle.pointsNm.length];
        if (this.intersection(a, b, c, d) || Math.min(this.segmentDistance(a, c, d), this.segmentDistance(b, c, d), this.segmentDistance(c, a, b), this.segmentDistance(d, a, b)) < required) fail('实际材料/偏差包络侵入障碍净距');
      }
    }
  }
  /** Offset is linear in true global arc length, curvature is piecewise linear.
   * Their product is quadratic; test its extrema rather than rejecting a safe
   * large enclosure which only becomes wide after the bend. */
  private maximumOffsetCurvature(primitive: OpticalCurvePrimitive, startOffset: number, endOffset: number, totalLength: number): number {
    if (primitive.kind === 'straight') return 0;
    const stops: number[] = [0];
    if (primitive.kind === 'euler') {
      const ramp: number = primitive.eulerFraction * Math.abs(primitive.turnRad) * primitive.minimumRadiusNm;
      stops.push(ramp); if (primitive.eulerFraction < 1) stops.push(primitive.lengthNm - ramp);
    }
    stops.push(primitive.lengthNm);
    const slope: number = (endOffset - startOffset) / totalLength;
    let maximum: number = Number.NEGATIVE_INFINITY;
    for (let at: number = 0; at < stops.length - 1; at++) {
      this.charge(); const left: number = stops[at], right: number = stops[at + 1];
      const low: CurveValue = evaluate(primitive, left), high: CurveValue = evaluate(primitive, right);
      const o: number = startOffset + slope * (primitive.startStationNm + left), derivative: number = (high.curvature - low.curvature) / (right - left);
      const quadratic: number = slope * derivative, linear: number = o * derivative + slope * low.curvature, constant: number = o * low.curvature;
      const span: number = right - left;
      maximum = Math.max(maximum, constant, constant + linear * span + quadratic * span * span);
      if (quadratic < 0) { const peak: number = -linear / (2 * quadratic); if (peak > 0 && peak < span) maximum = Math.max(maximum, constant + linear * peak + quadratic * peak * peak); }
    }
    return maximum;
  }
  route(request: OpticalRouteRequest): OpticalRouteGeometry {
    finite(request.dbuNm, '文档 DBU', true); frame(request.start, request.dbuNm); frame(request.end, request.dbuNm);
    if (request.bend !== 'circular' && request.bend !== 'euler' && request.bend !== 's-bend') fail('未知弯曲模式');
    finite(request.minimumRadiusNm, '最小曲率半径', true); finite(request.maximumDeviationNm, '最大物理近似偏差', true);
    if (!Number.isInteger(request.ownerCellId) || request.ownerCellId < 0 || !Number.isSafeInteger(request.firstShapeId) || request.firstShapeId < 1 || request.firstShapeId > Number.MAX_SAFE_INTEGER - this.maximumMaterials) fail('输出归属/shape ID 无效');
    const policy: string = request.coordinatePolicy ?? 'quantize-interior';
    if (policy !== 'strict' && policy !== 'quantize-interior' && policy !== 'quantize-with-port-tolerance') fail('未知坐标政策');
    if (policy === 'quantize-with-port-tolerance') {
      const tolerance = request.portTolerance; if (tolerance === undefined) fail('端口量化必须显式提供中心/方向/孔径容差');
      for (const value of [tolerance.maximumCenterErrorNm, tolerance.maximumAngleErrorDeg, tolerance.maximumWidthErrorNm]) { finite(value, '端面容差'); if (value < 0) fail('端面容差不能为负'); }
      if (tolerance.maximumAngleErrorDeg >= 90) fail('端面方向容差必须小于 90°');
    } else { exact(request.start.centerNm.x, request.dbuNm); exact(request.start.centerNm.y, request.dbuNm); exact(request.end.centerNm.x, request.dbuNm); exact(request.end.centerNm.y, request.dbuNm); }
    this.fraction = request.eulerFraction ?? (request.bend === 's-bend' ? 1 : 0.5);
    finite(this.fraction, 'Euler 比例'); if (this.fraction <= 0 || this.fraction > 1) fail('Euler 比例须在 (0,1]，圆弯请明确选 circular');
    const profile: RouteMaterialProfile = this.profile(request); this.radius = Math.max(request.minimumRadiusNm, profile.minimumBendRadiusNm);
    if (profile.transitionKind === 'linear-taper') {
      const rule = request.taperRule;
      if (rule === undefined || rule.schema !== 'hongtu-route-transition/v1' || rule.kind !== 'linear-taper') fail('线性截面过渡必须提供真实 taperRule');
      finite(rule.minimumLengthNm, 'taper 最小长度', true); finite(rule.maximumEdgeSlope, 'taper 最大边缘斜率', true);
    } else if (request.taperRule !== undefined) fail('uniform profile 与 taperRule 互相矛盾');
    const startLead: number = request.startLeadNm ?? 0, endLead: number = request.endLeadNm ?? 0, clearance: number = request.clearanceNm ?? 0;
    for (const value of [startLead, endLead, clearance]) { finite(value, 'lead/净距'); if (value < 0) fail('lead/净距不能为负'); }
    if (request.targetLengthNm !== undefined) { finite(request.targetLengthNm, '真实目标弧长', true); finite(request.lengthToleranceNm ?? request.dbuNm, '目标长度容差'); if ((request.lengthToleranceNm ?? request.dbuNm) < 0) fail('目标长度容差不能为负'); }
    else if (request.lengthToleranceNm !== undefined) fail('目标容差缺少真实目标弧长');
    const obstacles: OpticalRouteObstacle[] = request.obstacles ?? [];
    if (!Array.isArray(obstacles) || obstacles.length > 100000) fail('障碍集合超出预算');
    for (const obstacle of obstacles) {
      layer(obstacle.layerNumber, obstacle.datatype); if (!Array.isArray(obstacle.pointsNm) || obstacle.pointsNm.length < 3 || obstacle.pointsNm.length > 8190) fail('障碍必须为完整连续 polygon');
      if (obstacle.clearanceNm !== undefined) { finite(obstacle.clearanceNm, '障碍独立净距'); if (obstacle.clearanceNm < 0) fail('障碍独立净距不能为负'); }
      for (const p of obstacle.pointsNm) point(p, request.dbuNm); this.simple(obstacle.pointsNm);
    }
    const bounds = request.boundsNm;
    if (bounds !== undefined) { for (const value of [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY]) finite(value, '搜索边界'); if (bounds.maxX <= bounds.minX || bounds.maxY <= bounds.minY) fail('搜索边界须有正面积'); }
    const startHeading: number = request.start.orientationDeg * Math.PI / 180, endHeading: number = (request.end.orientationDeg + 180) * Math.PI / 180;
    let candidates: Candidate[];
    if (request.backboneNm !== undefined) candidates = [this.backbone(request, request.bend === 'circular' ? 'circular' : 'euler')];
    else {
      const start: Point = add(request.start.centerNm, times(unit(startHeading), startLead)), end: Point = sub(request.end.centerNm, times(unit(endHeading), endLead));
      candidates = request.bend === 'circular' ? this.circularCandidates(start, end, startHeading, endHeading) : this.eulerCandidates(start, end, startHeading, endHeading, request.bend === 's-bend');
      for (const candidate of candidates) {
        const specs: TurnSpec[] = [straightSpec(startLead)];
        for (const primitive of candidate.primitives) specs.push(primitive.kind === 'straight' ? straightSpec(primitive.lengthNm) : turnSpec(primitive.turnRad, primitive.kind));
        specs.push(straightSpec(endLead)); const full: Candidate = sequence(request.start.centerNm, startHeading, specs, this.radius, this.fraction, candidate.mode);
        candidate.primitives = full.primitives; candidate.length = full.length;
      }
    }
    candidates = this.matchedCandidates(request, candidates);
    candidates.sort((a: Candidate, b: Candidate): number => a.length - b.length);
    let rejected: number = 0, rejection: string = '';
    for (const candidate of candidates) {
      this.quantizationError = 0; this.vertices = 0;
      try {
        if (candidate.primitives.length === 0) fail('零长度 pose 无法生成波导');
        const final: OpticalCurvePrimitive = candidate.primitives[candidate.primitives.length - 1], end: CurveValue = evaluate(final, final.lengthNm);
        const poseError: number = distance(end.point, request.end.centerNm);
        if (poseError > this.numericalError(candidate.length, Math.max(Math.abs(end.point.x), Math.abs(end.point.y))) * 8 || Math.abs(signed(end.heading - endHeading)) > 1e-9) fail('连续曲线未闭合真实端口位置/切向');
        let maxOffset: number = 0, maxSlope: number = 0;
        for (const band of profile.startBands) {
          const last: RouteMaterialBand | undefined = profile.endBands.find((row: RouteMaterialBand): boolean => row.id === band.id); if (last === undefined) fail('材料未匹配');
          maxOffset = Math.max(maxOffset, Math.abs(band.minimumNm), Math.abs(band.maximumNm), Math.abs(last.minimumNm), Math.abs(last.maximumNm));
          maxSlope = Math.max(maxSlope, Math.abs(last.minimumNm - band.minimumNm) / candidate.length, Math.abs(last.maximumNm - band.maximumNm) / candidate.length);
        }
        if (profile.transitionKind === 'linear-taper') {
          const rule = request.taperRule; if (rule === undefined) fail('taper rule 缺失');
          if (candidate.length < rule.minimumLengthNm || maxSlope > rule.maximumEdgeSlope) fail('真实连续弧长/材料边缘斜率不满足 taper rule');
        }
        for (const primitive of candidate.primitives) if (primitive.kind !== 'straight') for (const band of profile.startBands) {
          const last: RouteMaterialBand | undefined = profile.endBands.find((row: RouteMaterialBand): boolean => row.id === band.id); if (last === undefined) fail('材料未匹配');
          const inner: number = Math.max(this.maximumOffsetCurvature(primitive, band.minimumNm, last.minimumNm, candidate.length),
            this.maximumOffsetCurvature(primitive, band.maximumNm, last.maximumNm, candidate.length));
          if (inner >= 1 - 1e-8) fail('材料内侧 offset × 曲率达到奇异/回折');
        }
        const quantizationBound: number = policy === 'strict' ? 0 : request.dbuNm * Math.SQRT1_2;
        const numeric: number = this.numericalError(candidate.length, Math.max(Math.abs(request.start.centerNm.x), Math.abs(request.end.centerNm.x), Math.abs(request.start.centerNm.y), Math.abs(request.end.centerNm.y))) + poseError;
        const available: number = request.maximumDeviationNm - quantizationBound - numeric;
        if (available <= 0) fail('要求偏差小于 DBU 量化/数值下界；须提高精度或明确增大允许偏差');
        const sampling: Sampling = this.sampling(candidate, available * 0.95, maxOffset, maxSlope);
        const capResult = this.caps(request, profile), material = this.material(request, profile, candidate, sampling);
        const deviation: number = sampling.error + sampling.integration + this.quantizationError + poseError;
        if (deviation > request.maximumDeviationNm + this.numericalError(candidate.length)) fail('物理材料实际近似偏差超过请求');
        if (bounds !== undefined) for (const shape of material.shapes) for (const p of shape.points) {
          this.charge(); if (p.x - deviation < bounds.minX || p.x + deviation > bounds.maxX || p.y - deviation < bounds.minY || p.y + deviation > bounds.maxY) fail('真实材料及近似误差包络超出搜索边界');
        }
        this.collision(material.shapes, obstacles, clearance, deviation);
        let polylineLength: number = 0; for (let i: number = 1; i < sampling.samples.length; i++) polylineLength += distance(sampling.samples[i - 1].pointNm, sampling.samples[i].pointNm);
        const warnings: string[] = ['连续弧长与导出版图折线长度分别报告；复杂障碍全局搜索尚未证明完备。'];
        if (request.bend !== 'circular') warnings.push('自由 pose Euler 当前为真实 CSC 数值候选，尚不包含 Euler CCC。');
        if (request.coordinatePolicy === 'quantize-with-port-tolerance') warnings.push('端面已按明确容差量化；实际中心、方向及孔径误差见 endpointErrors。');
        if ((request.bboxSections ?? []).length > 0) warnings.push('bbox enclosure 明确按实际写入主 strip 外接框生成，参与完整障碍检查。');
        return { shapes: material.shapes, profile: profile, endpointCaps: capResult.caps, endpointErrors: capResult.errors, materialSources: material.sources,
          centerlineNm: sampling.samples.map((sample: OpticalCurveSample): Point => sample.pointNm), samples: sampling.samples, primitives: candidate.primitives,
          continuousLengthNm: candidate.length, sampledLengthNm: polylineLength, minimumRadiusNm: candidate.primitives.some((p: OpticalCurvePrimitive): boolean => p.kind !== 'straight') ? this.radius : undefined,
          maximumCurvaturePerNm: candidate.primitives.some((p: OpticalCurvePrimitive): boolean => p.kind !== 'straight') ? 1 / this.radius : 0,
          curvatureContinuous: candidate.primitives.every((p: OpticalCurvePrimitive): boolean => p.kind !== 'circular'), maximumDeviationNm: deviation,
          samplingErrorNm: sampling.error, integrationErrorNm: sampling.integration, quantizationErrorNm: this.quantizationError, poseClosureErrorNm: poseError,
          solverMode: candidate.mode, candidateCount: candidates.length, rejectedCandidates: rejected, workUsed: this.work, warnings: warnings };
      } catch (error) {
        const message: string = error instanceof Error ? error.message : String(error);
        if (message.includes('预算')) fail(message);
        rejected++; rejection = message;
      }
    }
    fail('在已求解的真实曲线候选中未找到满足半径、材料、端面、边界/障碍的路线；不代表全局无解。' + (rejection.length > 0 ? ' 最后拒绝原因：' + rejection : ''));
  }
  certify(request: OpticalRouteRequest, geometry: OpticalRouteGeometry): number {
    finite(request.dbuNm, 'DBU', true); frame(request.start, request.dbuNm); frame(request.end, request.dbuNm);
    finite(request.minimumRadiusNm, '证书最小半径', true); finite(request.maximumDeviationNm, '证书允许偏差', true);
    if (!Number.isInteger(request.ownerCellId) || request.ownerCellId < 0 || !Number.isSafeInteger(request.firstShapeId) || request.firstShapeId < 1 || request.firstShapeId > Number.MAX_SAFE_INTEGER - this.maximumMaterials) fail('证书输出归属/ID无效');
    if (request.bend !== 'circular' && request.bend !== 'euler' && request.bend !== 's-bend') fail('证书弯曲模式无效');
    const fraction: number = request.eulerFraction ?? (request.bend === 's-bend' ? 1 : 0.5);
    finite(fraction, '证书 Euler 比例'); if (fraction <= 0 || fraction > 1) fail('证书 Euler 比例无效');
    const policy: string = request.coordinatePolicy ?? 'quantize-interior';
    if (policy !== 'strict' && policy !== 'quantize-interior' && policy !== 'quantize-with-port-tolerance') fail('证书坐标政策无效');
    if (policy === 'quantize-with-port-tolerance') {
      const tolerance = request.portTolerance; if (tolerance === undefined) fail('证书端面缺少明确容差');
      for (const value of [tolerance.maximumCenterErrorNm, tolerance.maximumAngleErrorDeg, tolerance.maximumWidthErrorNm]) { finite(value, '证书端面容差'); if (value < 0) fail('证书端面容差不能为负'); }
      if (tolerance.maximumAngleErrorDeg >= 90) fail('证书端面角度容差必须小于90°');
    } else { exact(request.start.centerNm.x, request.dbuNm); exact(request.start.centerNm.y, request.dbuNm); exact(request.end.centerNm.x, request.dbuNm); exact(request.end.centerNm.y, request.dbuNm); }
    for (const value of [request.startLeadNm ?? 0, request.endLeadNm ?? 0, request.clearanceNm ?? 0]) { finite(value, '证书lead/净距'); if (value < 0) fail('证书lead/净距不能为负'); }
    if (request.targetLengthNm !== undefined) { finite(request.targetLengthNm, '证书目标', true); finite(request.lengthToleranceNm ?? request.dbuNm, '证书长度容差'); if ((request.lengthToleranceNm ?? request.dbuNm) < 0) fail('证书长度容差不能为负'); }
    else if (request.lengthToleranceNm !== undefined) fail('证书长度容差缺少目标');
    const boundsCheck = request.boundsNm;
    if (boundsCheck !== undefined) { for (const value of [boundsCheck.minX, boundsCheck.minY, boundsCheck.maxX, boundsCheck.maxY]) finite(value, '证书边界'); if (boundsCheck.maxX <= boundsCheck.minX || boundsCheck.maxY <= boundsCheck.minY) fail('证书边界无正面积'); }
    const obstacleCheck: OpticalRouteObstacle[] = request.obstacles ?? [];
    if (!Array.isArray(obstacleCheck) || obstacleCheck.length > 100000) fail('证书障碍集合无效');
    for (const obstacle of obstacleCheck) {
      layer(obstacle.layerNumber, obstacle.datatype); if (!Array.isArray(obstacle.pointsNm) || obstacle.pointsNm.length < 3 || obstacle.pointsNm.length > 8190) fail('证书障碍不是完整polygon');
      for (const p of obstacle.pointsNm) point(p, request.dbuNm); this.simple(obstacle.pointsNm);
      if (obstacle.clearanceNm !== undefined) { finite(obstacle.clearanceNm, '证书障碍独立净距'); if (obstacle.clearanceNm < 0) fail('证书障碍净距为负'); }
    }
    const profile: RouteMaterialProfile = this.profile(request);
    if (profile.transitionKind === 'linear-taper') { const rule = request.taperRule; if (rule === undefined || rule.kind !== 'linear-taper' || rule.schema !== 'hongtu-route-transition/v1') fail('证书缺少真实 taperRule'); finite(rule.minimumLengthNm, '证书taper长度', true); finite(rule.maximumEdgeSlope, '证书taper斜率', true); }
    else if (request.taperRule !== undefined) fail('证书uniform/taperRule矛盾');
    if (geometry === null || geometry === undefined || !Array.isArray(geometry.primitives) || geometry.primitives.length === 0 || geometry.primitives.length > 4096) fail('证书缺少真实 primitive');
    let length: number = 0, maximumCurvature: number = 0, minimumRadius: number | undefined = undefined;
    let end: CurveValue = { point: request.start.centerNm, heading: request.start.orientationDeg * Math.PI / 180, curvature: 0 };
    for (const primitive of geometry.primitives) {
      this.charge(); point(primitive.startNm, request.dbuNm); finite(primitive.startHeadingRad, 'primitive 方向'); finite(primitive.lengthNm, 'primitive 长度', true); finite(primitive.turnRad, 'primitive 转角');
      if (distance(primitive.startNm, end.point) > this.numericalError(length, Math.max(Math.abs(end.point.x), Math.abs(end.point.y))) * 8 || Math.abs(signed(primitive.startHeadingRad - end.heading)) > 1e-9 || !close(primitive.startStationNm, length)) fail('primitive pose/弧长连接不连续');
      if (primitive.kind === 'straight') { if (primitive.turnRad !== 0 || primitive.minimumRadiusNm !== 0 || primitive.eulerFraction !== 0) fail('straight 的真实曲率参数矛盾'); }
      else if (primitive.kind === 'circular' || primitive.kind === 'euler') {
        finite(primitive.minimumRadiusNm, 'primitive 半径', true); finite(primitive.eulerFraction, 'primitive Euler 比例');
        if (Math.abs(primitive.turnRad) <= 1e-13 || Math.abs(primitive.turnRad) > TAU + 1e-10 || primitive.minimumRadiusNm < Math.max(request.minimumRadiusNm, profile.minimumBendRadiusNm)) fail('primitive 转角/半径约束失效');
        if (primitive.kind === 'circular' ? primitive.eulerFraction !== 0 : primitive.eulerFraction <= 0 || primitive.eulerFraction > 1) fail('primitive 曲率 ramp 参数无效');
        if ((request.bend === 'circular') !== (primitive.kind === 'circular') || (primitive.kind === 'euler' && !close(primitive.eulerFraction, fraction))) fail('证书primitive与请求弯曲模型/比例不一致');
        const actualLength: number = Math.abs(primitive.turnRad) * primitive.minimumRadiusNm * (primitive.kind === 'euler' ? 1 + primitive.eulerFraction : 1);
        if (!close(actualLength, primitive.lengthNm)) fail('primitive 长度没有来自真实解析曲线');
        minimumRadius = minimumRadius === undefined ? primitive.minimumRadiusNm : Math.min(minimumRadius, primitive.minimumRadiusNm); maximumCurvature = Math.max(maximumCurvature, 1 / primitive.minimumRadiusNm);
      } else fail('证书含未知 primitive');
      length += primitive.lengthNm; end = evaluate(primitive, primitive.lengthNm);
    }
    const poseError: number = distance(end.point, request.end.centerNm), first: OpticalCurvePrimitive = geometry.primitives[0], last: OpticalCurvePrimitive = geometry.primitives[geometry.primitives.length - 1];
    if (poseError > this.numericalError(length, Math.max(Math.abs(end.point.x), Math.abs(end.point.y))) * 8 || Math.abs(signed(end.heading - (request.end.orientationDeg + 180) * Math.PI / 180)) > 1e-9) fail('证书没有连续连接真实终端 pose');
    if ((request.startLeadNm ?? 0) > 0 && (first.kind !== 'straight' || first.lengthNm + this.numericalError(length) < (request.startLeadNm ?? 0))) fail('证书起点真实 lead 不足');
    if ((request.endLeadNm ?? 0) > 0 && (last.kind !== 'straight' || last.lengthNm + this.numericalError(length) < (request.endLeadNm ?? 0))) fail('证书终点真实 lead 不足');
    if (!close(geometry.continuousLengthNm, length) || !close(geometry.maximumCurvaturePerNm, maximumCurvature) || geometry.minimumRadiusNm !== minimumRadius) fail('报告弧长/曲率/最小半径与真实 primitive 矛盾');
    if (request.targetLengthNm !== undefined && Math.abs(length - request.targetLengthNm) > (request.lengthToleranceNm ?? request.dbuNm) + this.numericalError(length) * 8) fail('真实连续长度未达到目标容差');
    let maximumOffset: number = 0, maximumSlope: number = 0;
    for (const band of profile.startBands) {
      const terminal: RouteMaterialBand | undefined = profile.endBands.find((row: RouteMaterialBand): boolean => row.id === band.id); if (terminal === undefined) fail('证书材料无法匹配');
      maximumOffset = Math.max(maximumOffset, Math.abs(band.minimumNm), Math.abs(band.maximumNm), Math.abs(terminal.minimumNm), Math.abs(terminal.maximumNm));
      maximumSlope = Math.max(maximumSlope, Math.abs(terminal.minimumNm - band.minimumNm) / length, Math.abs(terminal.maximumNm - band.maximumNm) / length);
      for (const primitive of geometry.primitives) if (Math.max(this.maximumOffsetCurvature(primitive, band.minimumNm, terminal.minimumNm, length), this.maximumOffsetCurvature(primitive, band.maximumNm, terminal.maximumNm, length)) >= 1 - 1e-8) fail('证书实际 offset/曲率发生奇异');
    }
    if (profile.transitionKind === 'linear-taper') { const rule = request.taperRule; if (rule === undefined || rule.kind !== 'linear-taper' || rule.schema !== 'hongtu-route-transition/v1' || length < rule.minimumLengthNm || maximumSlope > rule.maximumEdgeSlope) fail('证书未满足真实 taper rule'); }
    const candidate: Candidate = { primitives: geometry.primitives, mode: geometry.solverMode, length: length };
    const quantizationBound: number = request.coordinatePolicy === 'strict' ? 0 : request.dbuNm * Math.SQRT1_2;
    const numeric: number = this.numericalError(length, Math.max(Math.abs(request.start.centerNm.x), Math.abs(request.end.centerNm.x), Math.abs(request.start.centerNm.y), Math.abs(request.end.centerNm.y))) + poseError;
    const available: number = request.maximumDeviationNm - quantizationBound - numeric;
    if (available <= 0) fail('证书精度低于物理 DBU/数值下界');
    const sampling: Sampling = this.sampling(candidate, available * 0.95, maximumOffset, maximumSlope);
    const caps: CapOutput = this.caps(request, profile), material: MaterialOutput = this.material(request, profile, candidate, sampling);
    // Rebuild actual physical meshes from the validated curve and original
    // signed world bands. This is not a checksum of the supplied report.
    if (JSON.stringify(sampling.samples) !== JSON.stringify(geometry.samples) || JSON.stringify(sampling.samples.map((sample: OpticalCurveSample): Point => sample.pointNm)) !== JSON.stringify(geometry.centerlineNm)) fail('实际 samples/中心线没有来自证书解析曲线');
    if (JSON.stringify(caps.caps) !== JSON.stringify(geometry.endpointCaps) || JSON.stringify(caps.errors) !== JSON.stringify(geometry.endpointErrors)) fail('端面实际 frame/孔径/量化误差与证书不符');
    if (JSON.stringify(material.shapes) !== JSON.stringify(geometry.shapes) || JSON.stringify(material.sources) !== JSON.stringify(geometry.materialSources) || JSON.stringify(profile) !== JSON.stringify(geometry.profile)) fail('实际物理 strip/bbox/图层/DBU 顶点与证书材料不符');
    let sampled: number = 0; for (let i: number = 1; i < sampling.samples.length; i++) sampled += distance(sampling.samples[i - 1].pointNm, sampling.samples[i].pointNm);
    const deviation: number = sampling.error + sampling.integration + this.quantizationError + poseError;
    if (!close(sampled, geometry.sampledLengthNm) || !close(sampling.error, geometry.samplingErrorNm) || !close(sampling.integration, geometry.integrationErrorNm) ||
      !close(this.quantizationError, geometry.quantizationErrorNm) || !close(poseError, geometry.poseClosureErrorNm) || !close(deviation, geometry.maximumDeviationNm) || deviation > request.maximumDeviationNm + this.numericalError(length)) fail('实际取样/量化/位姿误差包络与证书不符');
    if (geometry.curvatureContinuous !== geometry.primitives.every((p: OpticalCurvePrimitive): boolean => p.kind !== 'circular')) fail('曲率连续性报告不真实');
    const bounds = request.boundsNm;
    if (bounds !== undefined) for (const shape of material.shapes) for (const p of shape.points) if (p.x - deviation < bounds.minX || p.x + deviation > bounds.maxX || p.y - deviation < bounds.minY || p.y + deviation > bounds.maxY) fail('证书实际材料/误差包络越界');
    this.collision(material.shapes, request.obstacles ?? [], request.clearanceNm ?? 0, deviation);
    return this.work;
  }
  bend(request: OpticalBendRequest): OpticalBendGeometry {
    if (request.kind !== 'circular' && request.kind !== 'euler') fail('未知 primitive');
    finite(request.minimumRadiusNm, '最小半径', true); finite(request.turnDeg, '转角'); finite(request.maximumDeviationNm, '偏差', true);
    if (Math.abs(request.turnDeg) <= 1e-10 || Math.abs(request.turnDeg) > 360) fail('真实弯曲转角须在 (0,360]°');
    const fraction: number = request.eulerFraction ?? 0.5; finite(fraction, 'Euler 比例'); if (fraction <= 0 || fraction > 1) fail('Euler 比例须在 (0,1]');
    const angle: number = request.turnDeg * Math.PI / 180;
    const candidate: Candidate = sequence({ x: 0, y: 0 }, 0, [turnSpec(angle, request.kind)], request.minimumRadiusNm, fraction, request.kind + '-primitive');
    const sampling: Sampling = this.sampling(candidate, request.maximumDeviationNm * 0.95);
    const last: Point = sampling.samples[sampling.samples.length - 1].pointNm;
    const setback: number | undefined = Math.abs(angle) < Math.PI - 1e-8 ? last.x / (1 + Math.cos(angle)) : undefined;
    const effective: number | undefined = Math.abs(Math.sin(angle / 2)) > 1e-8 ? Math.hypot(last.x, last.y) / (2 * Math.abs(Math.sin(angle / 2))) : undefined;
    if (sampling.error + sampling.integration > request.maximumDeviationNm) fail('primitive 数值/取样偏差超过要求');
    return { samples: sampling.samples, primitive: candidate.primitives[0], continuousLengthNm: candidate.length, minimumRadiusNm: request.minimumRadiusNm,
      effectiveRadiusNm: effective, tangentSetbackNm: setback, samplingErrorNm: sampling.error, integrationErrorNm: sampling.integration };
  }
}

/** Side-effect-free optical geometry. Caller validates current structure, layers,
 * source-port owner corridors and commits all physical polygons in one transaction. */
export class OpticalRouteService {
  route(request: OpticalRouteRequest): OpticalRouteResult {
    try { const geometry: OpticalRouteGeometry = new OpticalWorker(request.budget).route(request); return { ok: true, message: '真实光学曲线与材料已生成', route: geometry }; }
    catch (error) { return { ok: false, message: error instanceof Error ? error.message : String(error) }; }
  }
  bend(request: OpticalBendRequest): OpticalBendGeometry { return new OpticalWorker(request.budget).bend(request); }
  certifyGeometry(request: OpticalRouteRequest, geometry: OpticalRouteGeometry): OpticalRouteCertificate {
    try { const work: number = new OpticalWorker(request.budget).certify(request, geometry); return { ok: true, message: '真实 primitive、端面及物理材料已重算验证', workUsed: work }; }
    catch (error) { return { ok: false, message: error instanceof Error ? error.message : String(error), workUsed: 0 }; }
  }
}
export const opticalRouteService: OpticalRouteService = new OpticalRouteService();
