import type { RdbItem, RdbValue, RdbPoint, RdbTransform, RdbBoundsResult } from '../models/RdbData';
import type { RdbMarkerPointNm, RdbMarkerSegmentNm, RdbMarkerPolygonNm, RdbMarkerPathNm,
  RdbMarkerLabelNm, RdbMarkerGeometryLimits, RdbMarkerGeometry, RdbMarkerGeometryResult,
  RdbMarkerImageLimits, RdbMarkerImage, RdbMarkerImageResult } from '../models/RdbMarkerGeometry';
import { rdbIdentityTransform, rdbTransformPoint, composeRdbTransforms, rdbItemBoundsNm } from './RdbService';

export function defaultRdbMarkerGeometryLimits(): RdbMarkerGeometryLimits {
  return { maximumValues: 10000, maximumInputPoints: 200000, maximumOutputPoints: 400000,
    maximumPrimitives: 100000, maximumWork: 2000000, curveToleranceNm: 0.25 };
}
export function defaultRdbMarkerImageLimits(): RdbMarkerImageLimits {
  return { maximumEncodedCharacters: 8388608, maximumDecodedBytes: 6291456,
    maximumDimension: 16384, maximumPixels: 16777216 };
}
function fail(message: string): never { throw new Error('RDB marker：' + message); }
function finite(value: number, name: string): void {
  if (typeof value !== 'number' || !Number.isFinite(value)) fail(name + ' 必须为有限数');
}
function positiveInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) fail(name + ' 必须为正安全整数');
}
function errorText(error: Error): string { return error.message; }
class GeometryBudget {
  inputPoints: number = 0;
  outputPoints: number = 0;
  primitives: number = 0;
  work: number = 0;
  limits: RdbMarkerGeometryLimits;
  constructor(limits: RdbMarkerGeometryLimits) {
    this.limits = limits;
    positiveInteger(limits.maximumValues, 'maximumValues');
    positiveInteger(limits.maximumInputPoints, 'maximumInputPoints');
    positiveInteger(limits.maximumOutputPoints, 'maximumOutputPoints');
    positiveInteger(limits.maximumPrimitives, 'maximumPrimitives');
    positiveInteger(limits.maximumWork, 'maximumWork');
    finite(limits.curveToleranceNm, 'curveToleranceNm');
    if (limits.curveToleranceNm <= 0) fail('curveToleranceNm 必须大于零');
  }
  spend(count: number = 1): void {
    this.work += count;
    if (this.work > this.limits.maximumWork) fail('工作预算超限，未返回截断几何');
  }
  input(count: number): void {
    this.inputPoints += count;
    if (this.inputPoints > this.limits.maximumInputPoints) fail('输入点预算超限');
    this.spend(count);
  }
  output(): void {
    this.outputPoints++;
    if (this.outputPoints > this.limits.maximumOutputPoints) fail('输出点预算超限，未返回部分几何');
    this.spend();
  }
  primitive(): void {
    this.primitives++;
    if (this.primitives > this.limits.maximumPrimitives) fail('primitive预算超限');
    this.spend();
  }
}
function copyPoint(point: RdbPoint): RdbPoint { return { x: point.x, y: point.y }; }
function nmPoint(point: RdbPoint, frame: RdbTransform, budget: GeometryBudget): RdbMarkerPointNm {
  budget.output();
  const q: RdbPoint = rdbTransformPoint(point, frame);
  const out: RdbMarkerPointNm = { x: q.x * 1000, y: q.y * 1000 };
  finite(out.x, 'nm X'); finite(out.y, 'nm Y');
  return out;
}
function transformRing(points: RdbPoint[], frame: RdbTransform, budget: GeometryBudget): RdbMarkerPointNm[] {
  const out: RdbMarkerPointNm[] = [];
  for (const point of points) out.push(nmPoint(point, frame, budget));
  return out;
}
function cross(a: RdbPoint, b: RdbPoint): number { return a.x * b.y - a.y * b.x; }
function subtract(a: RdbPoint, b: RdbPoint): RdbPoint { return { x: a.x - b.x, y: a.y - b.y }; }
function direction(a: RdbPoint, b: RdbPoint): RdbPoint {
  const x: number = b.x - a.x, y: number = b.y - a.y;
  const length: number = Math.hypot(x, y);
  if (!(length > 0) || !Number.isFinite(length)) fail('path方向不可表示');
  return { x: x / length, y: y / length };
}
function offset(point: RdbPoint, d: RdbPoint, along: number, normal: number): RdbPoint {
  const out: RdbPoint = { x: point.x + d.x * along - d.y * normal,
    y: point.y + d.y * along + d.x * normal };
  finite(out.x, 'path X'); finite(out.y, 'path Y'); return out;
}
/** Remove repeated/forward-collinear vertices; reversals are intentionally retained. */
function pathSpine(points: RdbPoint[], budget: GeometryBudget): RdbPoint[] {
  const out: RdbPoint[] = [];
  for (const point of points) {
    budget.spend();
    const previous: RdbPoint | undefined = out[out.length - 1];
    if (previous !== undefined && previous.x === point.x && previous.y === point.y) continue;
    while (out.length >= 2) {
      const a: RdbPoint = out[out.length - 2], b: RdbPoint = out[out.length - 1];
      const ab: RdbPoint = subtract(b, a), ac: RdbPoint = subtract(point, a);
      const determinant: number = cross(ab, ac);
      const between: number = (b.x - a.x) * (b.x - point.x) + (b.y - a.y) * (b.y - point.y);
      if (determinant !== 0 || between > 0) break;
      out.pop(); budget.spend();
    }
    out.push(copyPoint(point));
  }
  return out;
}
function capSegments(radiusNm: number, toleranceNm: number, budget: GeometryBudget): number {
  if (radiusNm === 0) return 2;
  // Circumscribed ellipse vertices have error <= max(axis)*(sec(pi/(2*n))-1).
  const angle: number = Math.acos(1 / (1 + toleranceNm / radiusNm));
  if (!(angle > 0)) fail('圆端精度超出浮点分辨率');
  let count: number = Math.max(2, Math.ceil(Math.PI / (2 * angle)));
  if (count % 2 !== 0) count++;
  if (!Number.isSafeInteger(count) || count * 2 > budget.limits.maximumOutputPoints) fail('圆端精度超过输出点预算');
  return count;
}
function capError(radiusNm: number, segments: number): number {
  return radiusNm * (1 / Math.cos(Math.PI / (2 * segments)) - 1);
}
function appendCap(out: RdbPoint[], point: RdbPoint, d: RdbPoint, radius: number,
  extension: number, start: boolean, segments: number, budget: GeometryBudget): void {
  const step: number = Math.PI / (2 * segments), correction: number = 1 / Math.cos(step);
  for (let i: number = 0; i < segments / 2; i++) {
    budget.spend();
    const angle: number = (start ? 2 * i + 1 : segments - 1 - 2 * i) * step;
    out.push(offset(point, d, (start ? -extension : extension) * Math.cos(angle) * correction,
      radius * Math.sin(angle) * correction));
  }
}
/** Offset-line intersections with finite sharp-corner/reflection limits, not generic SVG mitres. */
function pathSide(points: RdbPoint[], width: number, begin: number, end: number,
  round: boolean, segments: number, budget: GeometryBudget): RdbPoint[] {
  const out: RdbPoint[] = [], radius: number = width / 2;
  if (points.length === 0) return out;
  const first: RdbPoint = points[0], last: RdbPoint = points[points.length - 1];
  const firstDirection: RdbPoint = points.length === 1 ? { x: 1, y: 0 } : direction(first, points[1]);
  const lastDirection: RdbPoint = points.length === 1 ? firstDirection : direction(points[points.length - 2], last);
  if (round) appendCap(out, first, firstDirection, radius, begin, true, segments, budget);
  else out.push(offset(first, firstDirection, -begin, radius));
  for (let i: number = 1; i + 1 < points.length; i++) {
    budget.spend();
    const p: RdbPoint = points[i], incoming: RdbPoint = direction(points[i - 1], p);
    const outgoing: RdbPoint = direction(p, points[i + 1]);
    const n1: RdbPoint = { x: -incoming.y * radius, y: incoming.x * radius };
    const n2: RdbPoint = { x: -outgoing.y * radius, y: outgoing.x * radius };
    const determinant: number = cross(incoming, outgoing);
    if (determinant !== 0) {
      const t1: number = cross(subtract(n2, n1), outgoing) / determinant;
      const t2: number = cross(subtract(n1, n2), incoming) / determinant;
      const min1: number = -Math.hypot(p.x - points[i - 1].x, p.y - points[i - 1].y) - radius;
      const min2: number = -Math.hypot(points[i + 1].x - p.x, points[i + 1].y - p.y) - radius;
      if (t1 < min1 || t2 < min2) {
        out.push(offset(p, incoming, 0, radius), copyPoint(p), offset(p, outgoing, 0, radius));
      } else if (t1 <= radius && t2 <= radius) {
        out.push(offset(p, incoming, t1, radius));
      } else {
        out.push(offset(p, incoming, Math.min(radius, t1), radius),
          offset(p, outgoing, -Math.min(radius, t2), radius));
      }
    } else if (incoming.x * outgoing.x + incoming.y * outgoing.y < 0) {
      out.push(offset(p, incoming, radius, radius), offset(p, outgoing, -radius, radius));
    }
  }
  if (round) appendCap(out, last, lastDirection, radius, end, false, segments, budget);
  else out.push(offset(last, lastDirection, end, radius));
  return out;
}
function reversePathSide(points: RdbPoint[], width: number, begin: number, end: number,
  round: boolean, segments: number, budget: GeometryBudget): RdbPoint[] {
  if (points.length !== 1) return pathSide(points.slice().reverse(), width, end, begin, round, segments, budget);
  // A singleton has native +X direction on the forward side and -X on the reverse side.
  const p: RdbPoint = points[0], opposite: RdbPoint = { x: -1, y: 0 }, out: RdbPoint[] = [];
  if (round) {
    appendCap(out, p, opposite, width / 2, end, true, segments, budget);
    appendCap(out, p, opposite, width / 2, begin, false, segments, budget);
  } else out.push(offset(p, opposite, -end, width / 2), offset(p, opposite, begin, width / 2));
  return out;
}
function signedArea(points: RdbMarkerPointNm[]): number {
  if (points.length < 3) return 0;
  const anchor: RdbMarkerPointNm = points[0]; let area: number = 0;
  for (let i: number = 1; i + 1 < points.length; i++) {
    area += (points[i].x - anchor.x) * (points[i + 1].y - anchor.y) -
      (points[i].y - anchor.y) * (points[i + 1].x - anchor.x);
  }
  finite(area, 'polygon面积'); return area / 2;
}
function normalizedRing(points: RdbPoint[], frame: RdbTransform, budget: GeometryBudget,
  hole: boolean): RdbMarkerPointNm[] {
  budget.spend();
  const out: RdbMarkerPointNm[] = transformRing(points, frame, budget);
  const area: number = signedArea(out);
  if ((hole && area > 0) || (!hole && area < 0)) out.reverse();
  return out;
}
function countInput(value: RdbValue, budget: GeometryBudget): void {
  if (value.points !== undefined) budget.input(value.points.length);
  if (value.holes !== undefined) for (const hole of value.holes) { budget.spend(); budget.input(hole.length); }
}
export function planRdbMarkerGeometry(item: RdbItem, frame: RdbTransform = rdbIdentityTransform(),
  limits: RdbMarkerGeometryLimits = defaultRdbMarkerGeometryLimits()): RdbMarkerGeometryResult {
  try {
    const budget: GeometryBudget = new GeometryBudget(limits);
    if (item === null || !Array.isArray(item.values) || item.values.length > limits.maximumValues) fail('item/values无效或超预算');
    for (const value of item.values) { countInput(value, budget); budget.spend(); }
    // Core validates all value fields and transform semantics. A camera bbox is never used as drawing geometry.
    const bounds: RdbBoundsResult = rdbItemBoundsNm(item, frame);
    if (!bounds.ok) fail(bounds.message);
    const geometry: RdbMarkerGeometry = { schemaVersion: 1, coordinateUnit: 'nm',
      frame: { rotationDeg: frame.rotationDeg, mirror: frame.mirror, magnification: frame.magnification, x: frame.x, y: frame.y },
      segments: [], polygons: [], pathOutlines: [], paths: [], labels: [], cameraBoundsNm: bounds.boundsNm,
      cameraBoundsRole: 'camera-only', labelAnchorOnly: bounds.labelAnchorOnly,
      conservativePathBounds: bounds.conservativePath, outputPointCount: 0, maximumDeviationNm: 0,
      hasGeometry: false, notices: [] };
    for (let index: number = 0; index < item.values.length; index++) {
      const value: RdbValue = item.values[index]; budget.spend();
      if (value.kind === 'text' || value.kind === 'float') continue;
      if (value.kind === 'edge' || value.kind === 'edge-pair') {
        const count: number = value.kind === 'edge' ? 1 : 2;
        for (let part: number = 0; part < count; part++) {
          budget.primitive();
          const segment: RdbMarkerSegmentNm = { valueIndex: index, partIndex: part, kind: value.kind,
            points: transformRing(value.points!.slice(part * 2, part * 2 + 2), frame, budget),
            symmetric: value.kind === 'edge-pair' && value.symmetric === true };
          geometry.segments.push(segment);
        }
      } else if (value.kind === 'box') {
        if (value.points!.length === 0) continue;
        budget.primitive(); const a: RdbPoint = value.points![0], z: RdbPoint = value.points![1];
        const ring: RdbPoint[] = [{ x: a.x, y: a.y }, { x: z.x, y: a.y }, { x: z.x, y: z.y }, { x: a.x, y: z.y }];
        geometry.polygons.push({ valueIndex: index, kind: 'box', rings: [normalizedRing(ring, frame, budget, false)], fillRule: 'evenodd', maximumDeviationNm: 0 });
      } else if (value.kind === 'polygon') {
        if (value.points!.length === 0 && value.holes!.every((hole: RdbPoint[]): boolean => hole.length === 0)) continue;
        budget.primitive();
        const rings: RdbMarkerPointNm[][] = [normalizedRing(value.points!, frame, budget, false)];
        for (const hole of value.holes!) rings.push(normalizedRing(hole, frame, budget, true));
        geometry.polygons.push({ valueIndex: index, kind: 'polygon', rings: rings, fillRule: 'evenodd', maximumDeviationNm: 0 });
      } else if (value.kind === 'path') {
        const spine: RdbPoint[] = pathSpine(value.points!, budget);
        if (spine.length === 0) continue;
        budget.primitive();
        const radiusNm: number = Math.max(value.width! / 2, Math.abs(value.beginExtension!), Math.abs(value.endExtension!)) * frame.magnification * 1000;
        finite(radiusNm, 'path尺寸');
        const segments: number = value.round! ? capSegments(radiusNm, limits.curveToleranceNm, budget) : 2;
        const error: number = value.round! ? capError(radiusNm, segments) : 0;
        if (error > limits.curveToleranceNm * (1 + 1e-10)) fail('圆端误差无法满足预算');
        const outline: RdbPoint[] = pathSide(spine, value.width!, value.beginExtension!, value.endExtension!, value.round!, segments, budget)
          .concat(reversePathSide(spine, value.width!, value.beginExtension!, value.endExtension!, value.round!, segments, budget));
        const path: RdbMarkerPathNm = { valueIndex: index, spineNm: transformRing(value.points!, frame, budget),
          widthNm: value.width! * frame.magnification * 1000, beginExtensionNm: value.beginExtension! * frame.magnification * 1000,
          endExtensionNm: value.endExtension! * frame.magnification * 1000, round: value.round!, rendering: 'outlined-klayout-path',
          capSegmentsPerHalf: segments, maximumCapDeviationNm: error };
        finite(path.widthNm, 'path宽度'); finite(path.beginExtensionNm, 'path起端'); finite(path.endExtensionNm, 'path末端');
        geometry.paths.push(path);
        geometry.pathOutlines.push({ valueIndex: index, kind: 'path-outline', rings: [transformRing(outline, frame, budget)], fillRule: 'nonzero', maximumDeviationNm: error });
        geometry.maximumDeviationNm = Math.max(geometry.maximumDeviationNm, error);
      } else if (value.kind === 'label') {
        budget.primitive();
        const combined: RdbTransform = composeRdbTransforms(frame, value.transform!);
        const label: RdbMarkerLabelNm = { valueIndex: index, text: value.text!,
          anchorNm: nmPoint({ x: value.transform!.x, y: value.transform!.y }, frame, budget),
          rotationDeg: combined.rotationDeg, mirror: combined.mirror, magnification: combined.magnification,
          sourceSizeNm: value.size! * frame.magnification * 1000, font: value.font!,
          horizontalAlignment: value.horizontalAlignment!, verticalAlignment: value.verticalAlignment!, fontBoundsMeasured: false };
        finite(label.sourceSizeNm, 'label size'); geometry.labels.push(label);
      }
    }
    geometry.outputPointCount = budget.outputPoints;
    geometry.hasGeometry = geometry.segments.length + geometry.polygons.length + geometry.pathOutlines.length + geometry.labels.length > 0;
    if (geometry.labels.length > 0) geometry.notices.push('label只提供字锚点/变换/原始字体属性；没有测量原字体字形范围');
    if (geometry.paths.some((path: RdbMarkerPathNm): boolean => path.round &&
      (path.beginExtensionNm !== path.widthNm / 2 || path.endExtensionNm !== path.widthNm / 2))) {
      geometry.notices.push('非半宽round端按报告extension构造椭圆端；其它工具的解释可能不同');
    }
    return { ok: true, message: geometry.hasGeometry ? '完整nm marker几何；camera范围不是绘图材料' : 'item仅含信息或空几何', geometry: geometry };
  } catch (error) { return { ok: false, message: errorText(error as Error) }; }
}

function decodeBase64(original: string, limits: RdbMarkerImageLimits): Uint8Array {
  if (typeof original !== 'string' || original.length === 0 || original.length > limits.maximumEncodedCharacters) fail('image为空或超字符预算');
  if (/[^A-Za-z0-9+/=\t\n\r ]/.test(original)) fail('image不是标准base64；不加载URL/SVG');
  const compact: string = original.replace(/[\t\n\r ]/g, '');
  if (compact.length === 0 || compact.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(compact)) fail('base64长度或padding非法');
  const padding: number = compact.endsWith('==') ? 2 : compact.endsWith('=') ? 1 : 0;
  const length: number = compact.length / 4 * 3 - padding;
  if (length > limits.maximumDecodedBytes) fail('image解码字节超预算');
  const alphabet: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const bytes: Uint8Array = new Uint8Array(length); let position: number = 0;
  for (let i: number = 0; i < compact.length; i += 4) {
    const a: number = alphabet.indexOf(compact[i]), b: number = alphabet.indexOf(compact[i + 1]);
    const c: number = compact[i + 2] === '=' ? 0 : alphabet.indexOf(compact[i + 2]);
    const d: number = compact[i + 3] === '=' ? 0 : alphabet.indexOf(compact[i + 3]);
    if (i + 4 === compact.length && ((padding === 2 && (b & 15) !== 0) || (padding === 1 && (c & 3) !== 0))) fail('base64尾部未使用位非零');
    const word: number = a * 262144 + b * 4096 + c * 64 + d;
    if (position < length) bytes[position++] = (word >>> 16) & 255;
    if (position < length) bytes[position++] = (word >>> 8) & 255;
    if (position < length) bytes[position++] = word & 255;
  }
  return bytes;
}
function bytesText(bytes: Uint8Array, offset: number, length: number): string {
  let out: string = ''; for (let i: number = 0; i < length; i++) out += String.fromCharCode(bytes[offset + i]); return out;
}
function u16(bytes: Uint8Array, offset: number, little: boolean): number {
  if (offset + 2 > bytes.length) fail('image header被截断');
  return little ? bytes[offset] + bytes[offset + 1] * 256 : bytes[offset] * 256 + bytes[offset + 1];
}
function u32(bytes: Uint8Array, offset: number, little: boolean): number {
  if (offset + 4 > bytes.length) fail('image header被截断');
  return little ? bytes[offset] + bytes[offset + 1] * 256 + bytes[offset + 2] * 65536 + bytes[offset + 3] * 16777216
    : bytes[offset] * 16777216 + bytes[offset + 1] * 65536 + bytes[offset + 2] * 256 + bytes[offset + 3];
}
interface ImageHeader { mimeType: 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp' | 'image/bmp'; width: number; height: number; }
function imageHeader(bytes: Uint8Array): ImageHeader {
  if (bytes.length >= 24 && bytes[0] === 137 && bytesText(bytes, 1, 3) === 'PNG' &&
    bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10) {
    if (u32(bytes, 8, false) !== 13 || bytesText(bytes, 12, 4) !== 'IHDR' || bytes.length < 33) fail('PNG IHDR被截断或非法');
    return { mimeType: 'image/png', width: u32(bytes, 16, false), height: u32(bytes, 20, false) };
  }
  if (bytes.length >= 13 && (bytesText(bytes, 0, 6) === 'GIF87a' || bytesText(bytes, 0, 6) === 'GIF89a')) {
    return { mimeType: 'image/gif', width: u16(bytes, 6, true), height: u16(bytes, 8, true) };
  }
  if (bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216) {
    let position: number = 2;
    while (position < bytes.length) {
      if (bytes[position++] !== 255) fail('JPEG segment header非法');
      while (position < bytes.length && bytes[position] === 255) position++;
      if (position >= bytes.length) fail('JPEG marker被截断');
      const marker: number = bytes[position++];
      if (marker === 217 || marker === 218) break;
      if (marker === 1 || (marker >= 208 && marker <= 215)) continue;
      const length: number = u16(bytes, position, false);
      if (length < 2 || position + length > bytes.length) fail('JPEG segment长度非法');
      if ([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].indexOf(marker) >= 0) {
        if (length < 8) fail('JPEG frame header被截断');
        return { mimeType: 'image/jpeg', width: u16(bytes, position + 5, false), height: u16(bytes, position + 3, false) };
      }
      position += length;
    }
    fail('JPEG缺少可读frame尺寸');
  }
  if (bytes.length >= 25 && bytesText(bytes, 0, 4) === 'RIFF' && bytesText(bytes, 8, 4) === 'WEBP') {
    if (u32(bytes, 4, true) + 8 > bytes.length) fail('WebP容器被截断');
    const kind: string = bytesText(bytes, 12, 4);
    const chunkLength: number = u32(bytes, 16, true);
    if (20 + chunkLength + chunkLength % 2 > bytes.length) fail('WebP chunk被截断');
    if (kind === 'VP8X' && chunkLength >= 10 && bytes.length >= 30) {
      return { mimeType: 'image/webp', width: 1 + bytes[24] + bytes[25] * 256 + bytes[26] * 65536,
        height: 1 + bytes[27] + bytes[28] * 256 + bytes[29] * 65536 };
    }
    if (kind === 'VP8L' && chunkLength >= 5 && bytes[20] === 47) {
      const packed: number = u32(bytes, 21, true);
      return { mimeType: 'image/webp', width: (packed & 16383) + 1, height: ((packed >>> 14) & 16383) + 1 };
    }
    if (kind === 'VP8 ' && chunkLength >= 10 && bytes.length >= 30 && bytes[23] === 157 && bytes[24] === 1 && bytes[25] === 42) {
      return { mimeType: 'image/webp', width: u16(bytes, 26, true) & 16383, height: u16(bytes, 28, true) & 16383 };
    }
    fail('WebP尺寸header不支持或非法');
  }
  if (bytes.length >= 26 && bytesText(bytes, 0, 2) === 'BM') {
    const size: number = u32(bytes, 14, true);
    if (size === 12) return { mimeType: 'image/bmp', width: u16(bytes, 18, true), height: u16(bytes, 20, true) };
    if (size >= 40 && bytes.length >= 54) {
      const width: number = u32(bytes, 18, true), rawHeight: number = u32(bytes, 22, true);
      return { mimeType: 'image/bmp', width: width < 2147483648 ? width : width - 4294967296,
        height: Math.abs(rawHeight < 2147483648 ? rawHeight : rawHeight - 4294967296) };
    }
    fail('BMP尺寸header不支持或被截断');
  }
  fail('image header不支持；保留原base64但不展示未知/SVG内容');
}
export function describeRdbMarkerImage(base64: string,
  limits: RdbMarkerImageLimits = defaultRdbMarkerImageLimits()): RdbMarkerImageResult {
  try {
    positiveInteger(limits.maximumEncodedCharacters, 'maximumEncodedCharacters');
    positiveInteger(limits.maximumDecodedBytes, 'maximumDecodedBytes');
    positiveInteger(limits.maximumDimension, 'maximumDimension'); positiveInteger(limits.maximumPixels, 'maximumPixels');
    const bytes: Uint8Array = decodeBase64(base64, limits), header: ImageHeader = imageHeader(bytes);
    positiveInteger(header.width, 'image width'); positiveInteger(header.height, 'image height');
    if (header.width > limits.maximumDimension || header.height > limits.maximumDimension ||
      header.width * header.height > limits.maximumPixels) fail('image尺寸/像素超展示预算');
    const image: RdbMarkerImage = { mimeType: header.mimeType, width: header.width, height: header.height,
      decodedBytes: bytes.length, dataUri: 'data:' + header.mimeType + ';base64,' + base64, originalBase64: base64,
      headerValidated: true, decodeVerified: false, networkLoading: false };
    return { ok: true, message: '仅验证格式header/预算；ArkUI解码失败须显示错误并保留原image文本', image: image };
  } catch (error) { return { ok: false, message: errorText(error as Error) }; }
}
export class RdbMarkerGeometryService {
  plan(item: RdbItem, frame?: RdbTransform, limits?: RdbMarkerGeometryLimits): RdbMarkerGeometryResult {
    return planRdbMarkerGeometry(item, frame, limits);
  }
  image(base64: string, limits?: RdbMarkerImageLimits): RdbMarkerImageResult { return describeRdbMarkerImage(base64, limits); }
}
export const rdbMarkerGeometryService: RdbMarkerGeometryService = new RdbMarkerGeometryService();
