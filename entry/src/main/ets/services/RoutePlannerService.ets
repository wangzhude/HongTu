/** Physical-nm, bounded obstacle-aware routing. This module only plans geometry;
 * it never moves a component or mutates the document. Licensed under GPLv3.
 * The caller must supply complete material contours of the relevant hierarchy.
 * Sharp centerlines are electrical routes, not Euler/optical bend factories. */
import type { Point } from '../models/GdsiiData';

export interface RouteBounds { minX: number; minY: number; maxX: number; maxY: number; }
export interface RouteLayerPair { layerNumber: number; datatype: number; }
export interface RouteLayerBand extends RouteLayerPair { minimumNm: number; maximumNm: number; }
export interface RouteTerminal {
  key: string; centerNm: Point; orientationDeg: number; widthNm: number;
  layerNumber: number; datatype: number; portType: string;
  /** Only the terminal's initial outward escape may intersect this material.
   * The escape must leave it completely; all later segments still avoid it. */
  ownerObstacleKeys?: string[];
}
/** Execution profile for this pair. Bundle members keep their own physical
 * widths and occupied layers; request-level defaults serve legacy callers. */
export interface RoutePairMaterial {
  widthNm: number; materialEnvelopeWidthNm: number;
  routeLayerNumber: number; routeDatatype: number; routeLayerPairs: RouteLayerPair[];
  allowLayerTransition: boolean; allowWidthTransition: boolean;
  /** Exact uniform swept bands, in the directed route's left normal frame.
   * Omit when a taper/via/bbox cannot be represented by uniform bands. */
  layerBands?: RouteLayerBand[];
}
export interface RoutePair {
  key: string; start: RouteTerminal; end: RouteTerminal;
  waypointsNm?: Point[]; targetLengthNm?: number; material?: RoutePairMaterial;
}
export interface RouteObstacle {
  /** polygon is an actual filled simple ring. Existing transformed material
   * has continuous physical-nm vertices; only new route geometry is DBU exact.
   * path explicitly denotes a
   * round-sweep/capsule union, NOT a raw GDS PATHTYPE/miter/extension record.
   * Imported PATH material must first be converted to its real polygons. */
  key: string; pointsNm: Point[]; kind: 'polygon' | 'path'; widthNm?: number;
  layerNumber: number; datatype: number;
}
export interface RoutePlannerBudget {
  maxPairs?: number; maxObstacles?: number; maxVertices?: number;
  maxNodes?: number; maxExpanded?: number; maxWork?: number;
  maxWaypoints?: number; maxOutputPoints?: number; maxLeadProbes?: number;
  maxMatchLoops?: number; maxOrderAttempts?: number;
}
export interface RoutePlannerRequest {
  pairs: RoutePair[]; obstacles: RouteObstacle[]; dbuNm: number;
  widthNm: number; clearanceNm: number; separationNm: number;
  /** Minimum outward lead; it may extend further to leave owner material. */
  leadNm: number; gridNm: number; boundsNm: RouteBounds;
  matchLengths: boolean; targetLengthNm?: number; lengthToleranceNm?: number;
  /** Explicit execution instructions, validated/materialized by the caller.
   * False/omitted rejects a mismatch; the planner never invents a transition. */
  routeLayerNumber?: number; routeDatatype?: number;
  allowLayerTransition?: boolean; allowWidthTransition?: boolean;
  /** Full transverse material envelope including offset auxiliary sections.
   * Main PATH width remains widthNm. Avoidance reserves every listed layer. */
  materialEnvelopeWidthNm?: number; routeLayerPairs?: RouteLayerPair[];
  /** Geometric corner-fit search constraint, never a fictitious material width. */
  minimumTurnRunNm?: number;
  budget?: RoutePlannerBudget;
}
export interface PlannedRoute {
  pairKey: string; startKey: string; endKey: string; pointsNm: Point[];
  lengthNm: number; baseLengthNm: number; addedLengthNm: number;
  widthNm: number; layerNumber: number; datatype: number;
  envelopeWidthNm: number; layerPairs: RouteLayerPair[];
  layerBands?: RouteLayerBand[];
}
export interface RoutePlannerStats {
  expandedNodes: number; collisionChecks: number; work: number;
  orderAttempts: number; lengthMatchCandidates: number;
}
export interface RoutePlannerResult {
  ok: boolean; message: string; routes: PlannedRoute[]; stats: RoutePlannerStats;
}
interface RouteLimits {
  pairs: number; obstacles: number; vertices: number; nodes: number;
  expanded: number; work: number; waypoints: number; output: number;
  leadProbes: number; matchLoops: number; orders: number;
}
interface RouteMaterial {
  key: string; points: Point[]; polygon: boolean; radius: number;
  layer: number; datatype: number; bounds: RouteBounds;
}
interface RouteHeapEntry { state: number; score: number; distance: number; }
interface RouteLead { point: Point; horizontal: boolean; }
interface RouteInterval { low: number; high: number; }
interface RouteNumberOption { value: number; label: string; }
interface RouteSearchContext {
  request: RoutePlannerRequest; limits: RouteLimits; stats: RoutePlannerStats;
  material: RouteMaterial[]; epsilon: number;
  priorMaterial: Map<string, RouteMaterial[]>;
}

function copyPoint(point: Point): Point { return { x: point.x, y: point.y }; }
function samePoint(a: Point, b: Point): boolean { return a.x === b.x && a.y === b.y; }
function pointKey(point: Point): string { return `${point.x}/${point.y}`; }
function envelope(request: RoutePlannerRequest): number { return request.materialEnvelopeWidthNm ?? request.widthNm; }
function pairContext(pair: RoutePair, context: RouteSearchContext): RouteSearchContext {
  const material: RoutePairMaterial | undefined = pair.material;
  if (material === undefined) return context;
  const source: RoutePlannerRequest = context.request;
  const request: RoutePlannerRequest = { pairs: source.pairs, obstacles: source.obstacles, dbuNm: source.dbuNm,
    widthNm: material.widthNm, materialEnvelopeWidthNm: material.materialEnvelopeWidthNm,
    routeLayerNumber: material.routeLayerNumber, routeDatatype: material.routeDatatype,
    routeLayerPairs: material.routeLayerPairs, allowLayerTransition: material.allowLayerTransition,
    allowWidthTransition: material.allowWidthTransition, clearanceNm: source.clearanceNm, separationNm: source.separationNm,
    leadNm: source.leadNm, gridNm: source.gridNm, boundsNm: source.boundsNm, matchLengths: source.matchLengths,
    targetLengthNm: source.targetLengthNm, lengthToleranceNm: source.lengthToleranceNm, minimumTurnRunNm: source.minimumTurnRunNm, budget: source.budget };
  return { request: request, limits: context.limits, stats: context.stats, material: context.material, epsilon: context.epsilon,
    priorMaterial: context.priorMaterial };
}
function mainLayer(pair: RoutePair, request: RoutePlannerRequest): RouteLayerPair {
  return { layerNumber: request.routeLayerNumber ?? pair.start.layerNumber, datatype: request.routeDatatype ?? pair.start.datatype };
}
function routeLayers(pair: RoutePair, request: RoutePlannerRequest): RouteLayerPair[] {
  return request.routeLayerPairs ?? [mainLayer(pair, request)];
}
function onRouteLayer(material: RouteMaterial, pair: RoutePair, request: RoutePlannerRequest): boolean {
  return routeLayers(pair, request).some((layer: RouteLayerPair): boolean => layer.layerNumber === material.layer && layer.datatype === material.datatype);
}
function shareLayer(route: PlannedRoute, pair: RoutePair, request: RoutePlannerRequest): boolean {
  return routeLayers(pair, request).some((layer: RouteLayerPair): boolean => route.layerPairs.some((other: RouteLayerPair): boolean =>
    layer.layerNumber === other.layerNumber && layer.datatype === other.datatype));
}
function finite(value: number, label: string): void {
  if (!Number.isFinite(value)) throw new Error(`${label} 必须是有限数`);
}
function exactDbu(value: number, dbu: number, label: string): number {
  finite(value, label);
  const units: number = value / dbu, rounded: number = Math.round(units);
  if (Math.abs(units) > 2147483647 || Math.abs(units - rounded) > Math.max(1, Math.abs(units)) * Number.EPSILON * 16)
    throw new Error(`${label} 必须精确落在 signed-32-bit 文档 DBU，未进行静默量化`);
  return rounded * dbu;
}
function exactPoint(point: Point, dbu: number, label: string): Point {
  if (point === null || point === undefined) throw new Error(`${label} 缺少坐标`);
  return { x: exactDbu(point.x, dbu, `${label} X`), y: exactDbu(point.y, dbu, `${label} Y`) };
}
function continuousMaterialPoint(point: Point, dbu: number): Point {
  if (point === null || point === undefined || !Number.isFinite(point.x) || !Number.isFinite(point.y) ||
    Math.abs(point.x / dbu) > 2147483647 || Math.abs(point.y / dbu) > 2147483647)
    throw new Error('真实障碍材料顶点必须是有限 signed-32-bit 文档 DBU 范围内的连续坐标');
  return copyPoint(point);
}
function limit(value: number | undefined, fallback: number, maximum: number, label: string): number {
  const chosen: number = value === undefined ? fallback : value;
  if (!Number.isInteger(chosen) || chosen < 1 || chosen > maximum) throw new Error(`${label} 预算须为 1–${maximum} 的整数`);
  return chosen;
}
function budgets(source: RoutePlannerBudget | undefined): RouteLimits {
  const b: RoutePlannerBudget = source ?? {};
  return { pairs: limit(b.maxPairs, 32, 128, '配对'), obstacles: limit(b.maxObstacles, 2048, 8192, '障碍'),
    vertices: limit(b.maxVertices, 16384, 65536, '障碍顶点'), nodes: limit(b.maxNodes, 60000, 200000, '网格节点'),
    expanded: limit(b.maxExpanded, 150000, 1000000, 'A* 展开'), work: limit(b.maxWork, 4000000, 20000000, '几何工作'),
    waypoints: limit(b.maxWaypoints, 128, 1024, '途经点'), output: limit(b.maxOutputPoints, 8192, 65536, '输出顶点'),
    leadProbes: limit(b.maxLeadProbes, 4096, 32768, '端口引出'), matchLoops: limit(b.maxMatchLoops, 12, 64, '长度匹配回环'),
    orders: limit(b.maxOrderAttempts, 4, 16, '束线顺序') };
}
function spend(context: RouteSearchContext, amount: number = 1): void {
  context.stats.work += amount;
  if (context.stats.work > context.limits.work) throw new Error('布线几何工作预算耗尽，未发布部分路线');
}
function bounds(points: Point[]): RouteBounds {
  const result: RouteBounds = { minX: points[0].x, minY: points[0].y, maxX: points[0].x, maxY: points[0].y };
  for (const point of points) {
    result.minX = Math.min(result.minX, point.x); result.maxX = Math.max(result.maxX, point.x);
    result.minY = Math.min(result.minY, point.y); result.maxY = Math.max(result.maxY, point.y);
  }
  return result;
}
function segmentBounds(a: Point, b: Point): RouteBounds {
  return { minX: Math.min(a.x, b.x), minY: Math.min(a.y, b.y), maxX: Math.max(a.x, b.x), maxY: Math.max(a.y, b.y) };
}
function boxesApart(a: RouteBounds, b: RouteBounds, radius: number): boolean {
  return a.maxX + radius < b.minX || b.maxX + radius < a.minX || a.maxY + radius < b.minY || b.maxY + radius < a.minY;
}
function pointDistance(point: Point, a: Point, b: Point): number {
  const x: number = b.x - a.x, y: number = b.y - a.y, square: number = x * x + y * y;
  if (square === 0) return Math.hypot(point.x - a.x, point.y - a.y);
  const fraction: number = Math.max(0, Math.min(1, ((point.x - a.x) * x + (point.y - a.y) * y) / square));
  return Math.hypot(point.x - (a.x + fraction * x), point.y - (a.y + fraction * y));
}
function cross(a: Point, b: Point, c: Point): number {
  const first: number = (b.x - a.x) * (c.y - a.y), second: number = (b.y - a.y) * (c.x - a.x);
  const value: number = first - second, uncertainty: number = (Math.abs(first) + Math.abs(second)) * Number.EPSILON * 16;
  // Treat an uncertain near-collinear result conservatively as contact. The
  // interval test below still rejects disjoint collinear segments.
  return Math.abs(value) <= uncertainty ? 0 : value;
}
function intersect(a: Point, b: Point, c: Point, d: Point, epsilon: number): boolean {
  if (boxesApart(segmentBounds(a, b), segmentBounds(c, d), epsilon)) return false;
  const c1: number = cross(a, b, c), c2: number = cross(a, b, d), c3: number = cross(c, d, a), c4: number = cross(c, d, b);
  return ((c1 <= 0 && c2 >= 0) || (c1 >= 0 && c2 <= 0)) && ((c3 <= 0 && c4 >= 0) || (c3 >= 0 && c4 <= 0));
}
function segmentDistance(a: Point, b: Point, c: Point, d: Point, epsilon: number): number {
  if (intersect(a, b, c, d, epsilon)) return 0;
  return Math.min(pointDistance(a, c, d), pointDistance(b, c, d), pointDistance(c, a, b), pointDistance(d, a, b));
}
function inside(point: Point, polygon: Point[], epsilon: number, context: RouteSearchContext): boolean {
  let result: boolean = false;
  for (let index: number = 0, prior: number = polygon.length - 1; index < polygon.length; prior = index++) {
    spend(context);
    const a: Point = polygon[prior], b: Point = polygon[index];
    if (pointDistance(point, a, b) <= epsilon) return true;
    if ((a.y > point.y) !== (b.y > point.y)) {
      const crossing: number = a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y);
      if (point.x < crossing) result = !result;
    }
  }
  return result;
}
function hits(a: Point, b: Point, material: RouteMaterial, radius: number, context: RouteSearchContext): boolean {
  spend(context); context.stats.collisionChecks++;
  const clearance: number = radius + material.radius, epsilon: number = context.epsilon;
  if (boxesApart(segmentBounds(a, b), material.bounds, clearance + epsilon)) return false;
  if (material.polygon && (inside(a, material.points, epsilon, context) || inside(b, material.points, epsilon, context))) return true;
  const count: number = material.polygon ? material.points.length : material.points.length - 1;
  for (let index: number = 0; index < count; index++) {
    spend(context);
    const next: number = (index + 1) % material.points.length;
    if (segmentDistance(a, b, material.points[index], material.points[next], epsilon) < clearance + epsilon) return true;
  }
  return false;
}
function polygonsHit(first: Point[], second: RouteMaterial, gap: number, context: RouteSearchContext): boolean {
  spend(context); context.stats.collisionChecks++;
  if (boxesApart(bounds(first), second.bounds, gap + context.epsilon)) return false;
  if ((second.polygon && inside(first[0], second.points, context.epsilon, context)) || inside(second.points[0], first, context.epsilon, context)) return true;
  const count: number = second.polygon ? second.points.length : second.points.length - 1;
  for (let i: number = 0; i < first.length; i++) for (let j: number = 0; j < count; j++) {
    spend(context);
    if (segmentDistance(first[i], first[(i + 1) % first.length], second.points[j], second.points[(j + 1) % second.points.length], context.epsilon) < gap + second.radius + context.epsilon) return true;
  }
  return false;
}
function bandOffset(points: Point[], value: number, context: RouteSearchContext): Point[] {
  const normals: Point[] = [];
  for (let i: number = 1; i < points.length; i++) {
    spend(context); const dx: number = points[i].x - points[i - 1].x, dy: number = points[i].y - points[i - 1].y, distance: number = Math.hypot(dx, dy);
    if (distance === 0) throw new Error('逐层真实材料包含零长 segment');
    normals.push({ x: -dy / distance, y: dx / distance });
  }
  return points.map((point: Point, i: number): Point => {
    const a: Point = normals[Math.max(0, i - 1)], b: Point = normals[Math.min(normals.length - 1, i)];
    const divisor: number = 1 + a.x * b.x + a.y * b.y;
    if (divisor < 1e-10) throw new Error('逐层真实材料方向折返或 miter 数值不确定');
    const x: number = point.x + value * (a.x + b.x) / divisor, y: number = point.y + value * (a.y + b.y) / divisor;
    if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error('逐层真实材料 miter 非有限');
    return { x: x, y: y };
  });
}
function bandMaterial(points: Point[], band: RouteLayerBand, key: string, context: RouteSearchContext): RouteMaterial {
  const lower: Point[] = bandOffset(points, band.minimumNm, context), upper: Point[] = bandOffset(points, band.maximumNm, context);
  const ring: Point[] = lower.concat(upper.reverse());
  return { key: key, points: ring, polygon: true, radius: 0, layer: band.layerNumber, datatype: band.datatype, bounds: bounds(ring) };
}
function reservedMaterial(route: PlannedRoute, context: RouteSearchContext): RouteMaterial[] {
  const key: string = `${route.pairKey}|${route.pointsNm.map((point: Point): string => pointKey(point)).join(';')}`;
  const cached: RouteMaterial[] | undefined = context.priorMaterial.get(key);
  if (cached !== undefined) return cached;
  const bands: RouteLayerBand[] = route.layerBands ?? route.layerPairs.map((layer: RouteLayerPair): RouteLayerBand =>
    ({ layerNumber: layer.layerNumber, datatype: layer.datatype, minimumNm: -route.envelopeWidthNm / 2, maximumNm: route.envelopeWidthNm / 2 }));
  const result: RouteMaterial[] = bands.map((band: RouteLayerBand): RouteMaterial => bandMaterial(route.pointsNm, band, route.pairKey, context));
  context.priorMaterial.set(key, result); return result;
}
function clearBands(points: Point[], pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext, escapeKeys: string[]): boolean {
  const bands: RouteLayerBand[] = pair.material?.layerBands ?? [];
  for (const band of bands) {
    const piece: RouteMaterial = bandMaterial(points, band, pair.key, context);
    for (const material of context.material) {
      if (band.layerNumber !== material.layer || band.datatype !== material.datatype || escapeKeys.includes(material.key)) continue;
      if (polygonsHit(piece.points, material, context.request.clearanceNm, context)) return false;
    }
    for (const route of prior) for (const material of reservedMaterial(route, context)) {
      if (band.layerNumber !== material.layer || band.datatype !== material.datatype) continue;
      if (polygonsHit(piece.points, material, context.request.separationNm, context)) return false;
    }
  }
  return true;
}
function clippedLinear(interval: RouteInterval, value: number, delta: number, low: number, high: number): RouteInterval | undefined {
  if (delta === 0) return value >= low && value <= high ? interval : undefined;
  const first: number = (low - value) / delta, second: number = (high - value) / delta;
  const next: RouteInterval = { low: Math.max(interval.low, Math.min(first, second)), high: Math.min(interval.high, Math.max(first, second)) };
  return next.low <= next.high ? next : undefined;
}
function circleInterval(origin: Point, direction: Point, center: Point, radius: number): RouteInterval | undefined {
  const dx: number = origin.x - center.x, dy: number = origin.y - center.y;
  const a: number = direction.x * direction.x + direction.y * direction.y, b: number = 2 * (dx * direction.x + dy * direction.y), c: number = dx * dx + dy * dy - radius * radius;
  const determinant: number = b * b - 4 * a * c;
  if (determinant < -(Math.abs(b * b) + Math.abs(4 * a * c)) * Number.EPSILON * 32) return undefined;
  const square: number = Math.sqrt(Math.max(0, determinant)), interval: RouteInterval = { low: Math.max(0, (-b - square) / (2 * a)), high: Math.min(1, (-b + square) / (2 * a)) };
  return interval.low <= interval.high ? interval : undefined;
}
/** Certified owner escape is a single occupied prefix along the outward ray.
 * Its width/clearance-expanded material may not be re-entered after leaving.
 * Thus a terminal key cannot exempt an unrelated remote part of a device. */
function ownerEscapeAllowed(origin: Point, exit: Point, material: RouteMaterial, context: RouteSearchContext): boolean {
  const direction: Point = { x: exit.x - origin.x, y: exit.y - origin.y }, intervals: RouteInterval[] = [];
  const radius: number = envelope(context.request) / 2 + context.request.clearanceNm + material.radius + context.epsilon;
  const count: number = material.polygon ? material.points.length : material.points.length - 1;
  const critical: number[] = [0, 1], lengthSquared: number = direction.x * direction.x + direction.y * direction.y;
  if (lengthSquared === 0) return false;
  for (let index: number = 0; index < count; index++) {
    spend(context);
    const a: Point = material.points[index], b: Point = material.points[(index + 1) % material.points.length];
    const ex: number = b.x - a.x, ey: number = b.y - a.y, distance: number = Math.hypot(ex, ey);
    if (distance === 0) return false;
    let body: RouteInterval | undefined = clippedLinear({ low: 0, high: 1 }, ((origin.x - a.x) * ex + (origin.y - a.y) * ey) / distance,
      (direction.x * ex + direction.y * ey) / distance, 0, distance);
    if (body !== undefined) body = clippedLinear(body, (ex * (origin.y - a.y) - ey * (origin.x - a.x)) / distance,
      (ex * direction.y - ey * direction.x) / distance, -radius, radius);
    if (body !== undefined) intervals.push(body);
    for (const center of [a, b]) { const circle: RouteInterval | undefined = circleInterval(origin, direction, center, radius); if (circle !== undefined) intervals.push(circle); }
    if (material.polygon) {
      const determinant: number = direction.x * ey - direction.y * ex;
      if (determinant !== 0) {
        const x: number = a.x - origin.x, y: number = a.y - origin.y;
        const ray: number = (x * ey - y * ex) / determinant, edge: number = (x * direction.y - y * direction.x) / determinant;
        if (ray >= 0 && ray <= 1 && edge >= 0 && edge <= 1) critical.push(ray);
      } else {
        for (const point of [a, b]) {
          const projected: number = ((point.x - origin.x) * direction.x + (point.y - origin.y) * direction.y) / lengthSquared;
          if (projected > 0 && projected < 1) critical.push(projected);
        }
      }
    }
  }
  if (material.polygon) {
    const cuts: number[] = Array.from(new Set<number>(critical)).sort((a: number, b: number): number => a - b);
    for (let index: number = 1; index < cuts.length; index++) {
      const middle: number = (cuts[index - 1] + cuts[index]) / 2;
      if (inside({ x: origin.x + middle * direction.x, y: origin.y + middle * direction.y }, material.points, context.epsilon, context)) intervals.push({ low: cuts[index - 1], high: cuts[index] });
    }
  }
  intervals.sort((a: RouteInterval, b: RouteInterval): number => a.low - b.low);
  const uncertainty: number = context.epsilon / Math.sqrt(lengthSquared);
  let end: number = -1;
  for (const interval of intervals) {
    if (end < 0) { if (interval.low > uncertainty) return false; end = interval.high; }
    else if (interval.low > end + uncertainty) return false;
    else end = Math.max(end, interval.high);
  }
  return end < 1 - uncertainty;
}
function pointInBounds(point: Point, request: RoutePlannerRequest): boolean {
  const b: RouteBounds = request.boundsNm, radius: number = envelope(request) / 2;
  return point.x >= b.minX + radius && point.x <= b.maxX - radius && point.y >= b.minY + radius && point.y <= b.maxY - radius;
}
function clear(a: Point, b: Point, pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext,
  escapeKeys: string[] = []): boolean {
  if (!pointInBounds(a, context.request) || !pointInBounds(b, context.request)) return false;
  if (pair.material?.layerBands !== undefined) return clearBands([a, b], pair, prior, context, escapeKeys);
  const radius: number = envelope(context.request) / 2 + context.request.clearanceNm;
  for (const material of context.material) {
    if (!onRouteLayer(material, pair, context.request) || escapeKeys.includes(material.key)) continue;
    if (hits(a, b, material, radius, context)) return false;
  }
  for (const route of prior) {
    if (!shareLayer(route, pair, context.request)) continue;
    if (route.layerBands !== undefined) {
      for (const material of reservedMaterial(route, context)) {
        if (!onRouteLayer(material, pair, context.request)) continue;
        if (hits(a, b, material, envelope(context.request) / 2 + context.request.separationNm, context)) return false;
      }
      continue;
    }
    const minimum: number = (envelope(context.request) + route.envelopeWidthNm) / 2 + context.request.separationNm;
    for (let index: number = 1; index < route.pointsNm.length; index++) {
      spend(context); context.stats.collisionChecks++;
      if (segmentDistance(a, b, route.pointsNm[index - 1], route.pointsNm[index], context.epsilon) < minimum + context.epsilon) return false;
    }
  }
  return true;
}
function normalize(points: Point[], anchors: Set<string> = new Set<string>()): Point[] {
  const result: Point[] = [];
  for (const point of points) {
    if (result.length > 0 && samePoint(point, result[result.length - 1])) continue;
    while (result.length >= 2 && !anchors.has(pointKey(result[result.length - 1]))) {
      const a: Point = result[result.length - 2], b: Point = result[result.length - 1];
      if (cross(a, b, point) !== 0 || (b.x - a.x) * (point.x - b.x) + (b.y - a.y) * (point.y - b.y) <= 0) break;
      result.pop();
    }
    result.push(copyPoint(point));
  }
  return result;
}
function length(points: Point[]): number {
  let result: number = 0;
  for (let index: number = 1; index < points.length; index++) result += Math.hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y);
  return result;
}
function selfClear(points: Point[], context: RouteSearchContext): boolean {
  const line: Point[] = normalize(points), minimum: number = envelope(context.request) + context.request.clearanceNm;
  for (let index: number = 1; index < line.length; index++) for (let other: number = index + 2; other < line.length; other++) {
    spend(context);
    if (segmentDistance(line[index - 1], line[index], line[other - 1], line[other], context.epsilon) < minimum + context.epsilon) return false;
  }
  // Adjacent segments may meet, but may never reverse and retrace a conductor.
  for (let index: number = 1; index < line.length - 1; index++) {
    const a: Point = line[index - 1], b: Point = line[index], c: Point = line[index + 1];
    if (cross(a, b, c) === 0 && (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) <= 0) return false;
  }
  return true;
}
function terminalLead(terminal: RouteTerminal, pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext): RouteLead {
  const request: RoutePlannerRequest = context.request, center: Point = exactPoint(terminal.centerNm, request.dbuNm, terminal.key);
  const radians: number = ((terminal.orientationDeg % 360 + 360) % 360) * Math.PI / 180;
  const rawX: number = Math.cos(radians), rawY: number = Math.sin(radians);
  const ux: number = Math.abs(rawX) < 1e-12 ? 0 : rawX, uy: number = Math.abs(rawY) < 1e-12 ? 0 : rawY;
  const horizontal: boolean = Math.abs(ux) >= Math.abs(uy), component: number = horizontal ? ux : uy;
  const axis: number = horizontal ? center.x : center.y, sign: number = component > 0 ? 1 : -1;
  const first: number = sign > 0 ? Math.ceil((axis + request.leadNm * component) / request.gridNm) : Math.floor((axis + request.leadNm * component) / request.gridNm);
  const owner: string[] = terminal.ownerObstacleKeys ?? [];
  for (let probe: number = 0; probe < context.limits.leadProbes; probe++) {
    spend(context);
    const coordinate: number = (first + sign * probe) * request.gridNm, distance: number = (coordinate - axis) / component;
    if (distance < request.leadNm - context.epsilon || distance <= 0) continue;
    const raw: Point = { x: center.x + distance * ux, y: center.y + distance * uy };
    const xUnits: number = raw.x / request.dbuNm, yUnits: number = raw.y / request.dbuNm;
    if (Math.abs(xUnits - Math.round(xUnits)) > Math.max(1, Math.abs(xUnits)) * Number.EPSILON * 64 ||
      Math.abs(yUnits - Math.round(yUnits)) > Math.max(1, Math.abs(yUnits)) * Number.EPSILON * 64) continue;
    const point: Point = exactPoint({ x: Math.round(xUnits) * request.dbuNm, y: Math.round(yUnits) * request.dbuNm }, request.dbuNm, '端口引出');
    if (!pointInBounds(point, request)) break;
    if (!clear(center, point, pair, prior, context, owner)) continue;
    let escaped: boolean = true;
    for (const material of context.material) if (owner.includes(material.key) && onRouteLayer(material, pair, request) &&
      (hits(point, point, material, envelope(request) / 2 + request.clearanceNm, context) || !ownerEscapeAllowed(center, point, material, context))) { escaped = false; break; }
    if (!escaped) continue;
    // DBU rounding is allowed only when it preserves the exact outward ray
    // within floating-point arithmetic, never as an angular approximation.
    const dxUnits: number = Math.round(point.x / request.dbuNm) - Math.round(center.x / request.dbuNm),
      dyUnits: number = Math.round(point.y / request.dbuNm) - Math.round(center.y / request.dbuNm);
    const error: number = Math.abs(dxUnits * uy - dyUnits * ux);
    if (error > Math.max(1, Math.abs(dxUnits), Math.abs(dyUnits)) * Number.EPSILON * 128) continue;
    return { point: point, horizontal: horizontal };
  }
  throw new Error(`端口 ${terminal.key} 在引出预算/区域内没有精确 DBU 外向射线出口（任意角需合法格点），未改动端口`);
}
function heapPush(heap: RouteHeapEntry[], entry: RouteHeapEntry): void {
  heap.push(entry); let at: number = heap.length - 1;
  while (at > 0) {
    const parent: number = Math.floor((at - 1) / 2);
    if (heap[parent].score <= entry.score) break;
    heap[at] = heap[parent]; at = parent;
  }
  heap[at] = entry;
}
function heapPop(heap: RouteHeapEntry[]): RouteHeapEntry {
  const result: RouteHeapEntry = heap[0], end: RouteHeapEntry = heap.pop() as RouteHeapEntry;
  if (heap.length === 0) return result;
  let at: number = 0;
  while (at * 2 + 1 < heap.length) {
    let child: number = at * 2 + 1;
    if (child + 1 < heap.length && heap[child + 1].score < heap[child].score) child++;
    if (heap[child].score >= end.score) break;
    heap[at] = heap[child]; at = child;
  }
  heap[at] = end; return result;
}
function gridCoordinates(a: Point, b: Point, pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext): number[][] {
  const request: RoutePlannerRequest = context.request, radius: number = envelope(request) / 2 + request.clearanceNm;
  const xs: number[] = [a.x, b.x], ys: number[] = [a.y, b.y];
  // Space for a legitimate U/J turn exists even in an otherwise empty region.
  // Obstacle-only coordinates can otherwise force a sub-width short jog.
  const pitch: number = Math.ceil(Math.max(envelope(request) + request.clearanceNm + context.epsilon, request.minimumTurnRunNm ?? 0) / request.dbuNm) * request.dbuNm;
  for (const point of [a, b]) {
    xs.push(Math.floor((point.x - pitch) / request.gridNm) * request.gridNm, Math.ceil((point.x + pitch) / request.gridNm) * request.gridNm);
    ys.push(Math.floor((point.y - pitch) / request.gridNm) * request.gridNm, Math.ceil((point.y + pitch) / request.gridNm) * request.gridNm);
  }
  const add: (point: Point, extra: number) => void = (point: Point, extra: number): void => {
    const pad: number = radius + extra + context.epsilon;
    xs.push(Math.floor((point.x - pad) / request.gridNm) * request.gridNm, Math.ceil((point.x + pad) / request.gridNm) * request.gridNm);
    ys.push(Math.floor((point.y - pad) / request.gridNm) * request.gridNm, Math.ceil((point.y + pad) / request.gridNm) * request.gridNm);
  };
  for (const material of context.material) {
    if (!onRouteLayer(material, pair, request)) continue;
    for (const point of material.points) { spend(context); add(point, material.radius); }
  }
  for (const route of prior) if (shareLayer(route, pair, request))
    for (const point of route.pointsNm) { spend(context); add(point, route.envelopeWidthNm / 2 + request.separationNm - request.clearanceNm); }
  const border: number = envelope(request) / 2 + context.epsilon, box: RouteBounds = request.boundsNm;
  xs.push(Math.ceil((box.minX + border) / request.gridNm) * request.gridNm, Math.floor((box.maxX - border) / request.gridNm) * request.gridNm);
  ys.push(Math.ceil((box.minY + border) / request.gridNm) * request.gridNm, Math.floor((box.maxY - border) / request.gridNm) * request.gridNm);
  const sortX: number[] = Array.from(new Set<number>(xs.filter((value: number): boolean => value >= box.minX + border && value <= box.maxX - border))).sort((first: number, second: number): number => first - second);
  const sortY: number[] = Array.from(new Set<number>(ys.filter((value: number): boolean => value >= box.minY + border && value <= box.maxY - border))).sort((first: number, second: number): number => first - second);
  if (sortX.length * sortY.length > context.limits.nodes) throw new Error(`压缩正交网格 ${sortX.length}×${sortY.length} 超过节点预算，未发布部分路线`);
  return [sortX, sortY];
}
function findPath(a: Point, b: Point, pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext,
  startTerminal: RouteTerminal | undefined = undefined, endTerminal: RouteTerminal | undefined = undefined): Point[] {
  if (samePoint(a, b)) return [copyPoint(a)];
  const coordinate: number[][] = gridCoordinates(a, b, pair, prior, context), xs: number[] = coordinate[0], ys: number[] = coordinate[1];
  const width: number = xs.length, start: number = ys.indexOf(a.y) * width + xs.indexOf(a.x), goal: number = ys.indexOf(b.y) * width + xs.indexOf(b.x);
  if (xs.indexOf(a.x) < 0 || xs.indexOf(b.x) < 0 || ys.indexOf(a.y) < 0 || ys.indexOf(b.y) < 0) throw new Error('引出点或途经点未落在可布线区域内');
  // Five states per node: incoming +/-X, +/-Y, or the initial no-direction
  // state. Visibility jumps span whole straight segments, so each accepted
  // interior edge is long enough for the physical conductor to turn again.
  const distances: number[] = new Array<number>(width * ys.length * 5).fill(Infinity), previous: number[] = new Array<number>(width * ys.length * 5).fill(-1);
  const heap: RouteHeapEntry[] = [], edgeCache: Map<string, boolean> = new Map<string, boolean>();
  const at: (index: number) => Point = (index: number): Point => ({ x: xs[index % width], y: ys[Math.floor(index / width)] });
  const initial: number = start * 5 + 4;
  distances[initial] = 0; heapPush(heap, { state: initial, score: Math.abs(a.x - b.x) + Math.abs(a.y - b.y), distance: 0 });
  const pitch: number = Math.max(envelope(context.request) + context.request.clearanceNm + context.epsilon, context.request.minimumTurnRunNm ?? 0);
  let found: number = -1;
  while (heap.length > 0) {
    const current: RouteHeapEntry = heapPop(heap);
    if (current.distance !== distances[current.state]) continue;
    if (++context.stats.expandedNodes > context.limits.expanded) throw new Error('A* 展开预算耗尽，未发布部分路线');
    const node: number = Math.floor(current.state / 5), direction: number = current.state % 5;
    if (node === goal) { found = current.state; break; }
    const xIndex: number = node % width, yIndex: number = Math.floor(node / width), from: Point = at(node);
    const neighbors: number[] = [];
    if (direction === 4 || direction >= 2) for (let x: number = 0; x < width; x++) if (x !== xIndex) neighbors.push(yIndex * width + x);
    if (direction === 4 || direction < 2) for (let y: number = 0; y < ys.length; y++) if (y !== yIndex) neighbors.push(y * width + xIndex);
    for (const nextNode of neighbors) {
      spend(context); const to: Point = at(nextNode), dx: number = to.x - from.x, dy: number = to.y - from.y;
      const nextDirection: number = dx > 0 ? 0 : dx < 0 ? 1 : dy > 0 ? 2 : 3;
      const distance: number = Math.abs(dx) + Math.abs(dy), cost: number = current.distance + distance, next: number = nextNode * 5 + nextDirection;
      if (cost >= distances[next]) continue;
      let extended: number = distance;
      if (node === start && startTerminal !== undefined) {
        const radians: number = startTerminal.orientationDeg * Math.PI / 180, ux: number = Math.cos(radians), uy: number = Math.sin(radians);
        const dot: number = dx * ux + dy * uy;
        if (dot < -context.epsilon) continue;
        if (Math.abs(dx * uy - dy * ux) < context.epsilon && dot > 0) extended += Math.hypot(a.x - startTerminal.centerNm.x, a.y - startTerminal.centerNm.y);
      }
      if (nextNode === goal && endTerminal !== undefined) {
        const radians: number = endTerminal.orientationDeg * Math.PI / 180, ux: number = Math.cos(radians), uy: number = Math.sin(radians);
        const dot: number = dx * ux + dy * uy;
        if (dot > context.epsilon) continue;
        if (Math.abs(dx * uy - dy * ux) < context.epsilon && dot < 0) extended += Math.hypot(b.x - endTerminal.centerNm.x, b.y - endTerminal.centerNm.y);
      }
      if (extended < pitch && !(node === start && nextNode === goal)) continue;
      // Signed offset strips occupy opposite sides when an edge reverses.
      // A symmetric visibility cache would reuse the wrong physical material.
      const cacheKey: string = pair.material?.layerBands !== undefined ? `${node}/${nextNode}` :
        node < nextNode ? `${node}/${nextNode}` : `${nextNode}/${node}`;
      let valid: boolean | undefined = edgeCache.get(cacheKey);
      if (valid === undefined) { valid = clear(from, to, pair, prior, context); edgeCache.set(cacheKey, valid); }
      if (!valid) continue;
      distances[next] = cost; previous[next] = current.state;
      heapPush(heap, { state: next, distance: cost, score: cost + Math.abs(to.x - b.x) + Math.abs(to.y - b.y) });
    }
  }
  if (found < 0) throw new Error(`配对 ${pair.key} 在给定区域/网格、方向和真实回折间距内无可达路径`);
  const reversed: Point[] = [];
  for (let state: number = found; state >= 0; state = previous[state]) { reversed.push(at(Math.floor(state / 5))); if (state === initial) break; }
  reversed.reverse(); return normalize(reversed);
}
function validateLine(points: Point[], pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext): boolean {
  if (points.length < 2 || points.length > context.limits.output || !selfClear(points, context)) return false;
  for (let index: number = 1; index < points.length; index++) {
    const escape: string[] = index === 1 ? (pair.start.ownerObstacleKeys ?? []) : index === points.length - 1 ? (pair.end.ownerObstacleKeys ?? []) : [];
    if (!clear(points[index - 1], points[index], pair, prior, context, escape)) return false;
    if (escape.length > 0) {
      const origin: Point = index === 1 ? points[index - 1] : points[index], exit: Point = index === 1 ? points[index] : points[index - 1];
      for (const material of context.material) if (escape.includes(material.key) && onRouteLayer(material, pair, context.request) && !ownerEscapeAllowed(origin, exit, material, context)) return false;
    }
  }
  if (pair.material?.layerBands !== undefined) {
    // Segment checks alone miss the actual outside miter at a turn. Check
    // complete swept material against prior routes; source-owner contacts
    // are still checked by the certified finite segment escapes above.
    for (const band of pair.material.layerBands) {
      const piece: RouteMaterial = bandMaterial(points, band, pair.key, context);
      for (const route of prior) for (const material of reservedMaterial(route, context))
        if (band.layerNumber === material.layer && band.datatype === material.datatype && polygonsHit(piece.points, material, context.request.separationNm, context)) return false;
      for (let at: number = 1; at < points.length - 1; at++) {
        const around: Point[] = [points[at - 1], points[at], points[at + 1]];
        for (const value of [band.minimumNm, band.maximumNm]) {
          const joined: Point = bandOffset(around, value, context)[1];
          const incoming: Point = bandOffset(around.slice(0, 2), value, context)[1], outgoing: Point = bandOffset(around.slice(1), value, context)[0];
          const triangle: Point[] = [incoming, joined, outgoing];
          if (Math.abs(cross(incoming, joined, outgoing)) <= context.epsilon * context.epsilon) continue;
          for (const material of context.material) if (band.layerNumber === material.layer && band.datatype === material.datatype &&
            polygonsHit(triangle, material, context.request.clearanceNm, context)) return false;
        }
      }
    }
  }
  return true;
}
function planPair(pair: RoutePair, prior: PlannedRoute[], context: RouteSearchContext): PlannedRoute {
  const start: RouteLead = terminalLead(pair.start, pair, prior, context), end: RouteLead = terminalLead(pair.end, pair, prior, context);
  const anchors: Point[] = [start.point].concat((pair.waypointsNm ?? []).map((point: Point): Point => exactPoint(point, context.request.dbuNm, '途经点'))).concat([end.point]);
  const protectedKeys: Set<string> = new Set<string>(anchors.map((point: Point): string => pointKey(point)));
  let points: Point[] = [exactPoint(pair.start.centerNm, context.request.dbuNm, pair.start.key), copyPoint(start.point)];
  for (let index: number = 1; index < anchors.length; index++) points = points.concat(findPath(anchors[index - 1], anchors[index], pair, prior, context,
    index === 1 ? pair.start : undefined, index === anchors.length - 1 ? pair.end : undefined).slice(1));
  points.push(exactPoint(pair.end.centerNm, context.request.dbuNm, pair.end.key)); points = normalize(points, protectedKeys);
  if (!validateLine(points, pair, prior, context)) throw new Error(`配对 ${pair.key} 路线自交、折返或不满足实际间距，未发布部分路线`);
  const distance: number = length(points);
  const layer: RouteLayerPair = mainLayer(pair, context.request);
  return { pairKey: pair.key, startKey: pair.start.key, endKey: pair.end.key, pointsNm: points,
    lengthNm: distance, baseLengthNm: distance, addedLengthNm: 0, widthNm: context.request.widthNm,
    layerNumber: layer.layerNumber, datatype: layer.datatype, envelopeWidthNm: envelope(context.request),
    layerPairs: routeLayers(pair, context.request).map((item: RouteLayerPair): RouteLayerPair => ({ layerNumber: item.layerNumber, datatype: item.datatype })),
    layerBands: pair.material?.layerBands?.map((band: RouteLayerBand): RouteLayerBand => ({ layerNumber: band.layerNumber, datatype: band.datatype, minimumNm: band.minimumNm, maximumNm: band.maximumNm })) };
}
function matchRoute(route: PlannedRoute, pair: RoutePair, others: PlannedRoute[], target: number, context: RouteSearchContext): PlannedRoute {
  const tolerance: number = context.request.lengthToleranceNm ?? context.request.dbuNm * 1e-6, delta: number = target - route.lengthNm;
  if (delta < -tolerance) throw new Error(`配对 ${pair.key} 的已避障路径 ${route.lengthNm} nm 长于目标 ${target} nm，无法通过加蛇形缩短`);
  if (Math.abs(delta) <= tolerance) return route;
  const unit: number = context.request.dbuNm, halfUnits: number = delta / (2 * unit), total: number = Math.round(halfUnits);
  if (Math.abs(total * 2 * unit - delta) > tolerance) throw new Error(`配对 ${pair.key} 的目标长度差不满足精确 DBU 正交回环步长 2×DBU`);
  const pitch: number = Math.ceil((envelope(context.request) + Math.max(context.request.clearanceNm, context.request.separationNm) + context.epsilon) / unit) * unit;
  for (let index: number = 1; index < route.pointsNm.length - 2; index++) {
    const a: Point = route.pointsNm[index], b: Point = route.pointsNm[index + 1];
    if (a.x !== b.x && a.y !== b.y) continue;
    const horizontal: boolean = a.y === b.y, run: number = Math.abs(horizontal ? b.x - a.x : b.y - a.y), sign: number = (horizontal ? b.x - a.x : b.y - a.y) > 0 ? 1 : -1;
    for (let loops: number = 1; loops <= context.limits.matchLoops; loops++) {
      if ((loops * 2 + 1) * pitch > run || Math.floor(total / loops) * unit < pitch) continue;
      for (const side of [-1, 1]) {
        spend(context); context.stats.lengthMatchCandidates++;
        const replacement: Point[] = [copyPoint(a)]; let forward: number = pitch;
        const local: (travel: number, away: number) => Point = (travel: number, away: number): Point => horizontal ?
          ({ x: a.x + sign * travel, y: a.y + side * away }) : ({ x: a.x + side * away, y: a.y + sign * travel });
        replacement.push(local(forward, 0));
        for (let loop: number = 0; loop < loops; loop++) {
          const height: number = (Math.floor(total / loops) + (loop < total % loops ? 1 : 0)) * unit;
          replacement.push(local(forward, height)); forward += pitch; replacement.push(local(forward, height)); replacement.push(local(forward, 0));
          if (loop + 1 < loops) { forward += pitch; replacement.push(local(forward, 0)); }
        }
        replacement.push(copyPoint(b));
        const candidate: Point[] = route.pointsNm.slice(0, index).concat(replacement).concat(route.pointsNm.slice(index + 2));
        if (!validateLine(candidate, pair, others, context)) continue;
        const measured: number = length(candidate);
        if (Math.abs(measured - target) > tolerance) continue;
        const matched: PlannedRoute = { pairKey: route.pairKey, startKey: route.startKey, endKey: route.endKey, pointsNm: candidate,
          lengthNm: measured, baseLengthNm: route.baseLengthNm, addedLengthNm: measured - route.baseLengthNm,
          widthNm: route.widthNm, layerNumber: route.layerNumber, datatype: route.datatype,
          envelopeWidthNm: route.envelopeWidthNm, layerPairs: route.layerPairs.map((item: RouteLayerPair): RouteLayerPair => ({ layerNumber: item.layerNumber, datatype: item.datatype })),
          layerBands: route.layerBands };
        return matched;
      }
    }
  }
  throw new Error(`配对 ${pair.key} 没有容纳目标长度蛇形的合法空间/回环预算，未用估计长度冒充匹配`);
}
function validateMaterial(request: RoutePlannerRequest): void {
  exactDbu(request.widthNm, request.dbuNm, '线宽');
  if (request.widthNm <= 0) throw new Error('线宽须大于 0');
  exactDbu(envelope(request), request.dbuNm, '材料包络宽度');
  if (envelope(request) < request.widthNm) throw new Error('实际材料包络不得小于主线宽度');
  if ((request.routeLayerNumber === undefined) !== (request.routeDatatype === undefined)) throw new Error('主布线 Layer/Datatype 须同时明确');
  for (const value of [request.routeLayerNumber, request.routeDatatype]) if (value !== undefined && (!Number.isInteger(value) || value < 0 || value > 32767)) throw new Error('主布线图层无效');
  for (const flag of [request.allowLayerTransition, request.allowWidthTransition]) if (flag !== undefined && typeof flag !== 'boolean') throw new Error('过渡授权须为明确布尔值');
  if (request.routeLayerPairs !== undefined) {
    if (!Array.isArray(request.routeLayerPairs) || request.routeLayerPairs.length < 1 || request.routeLayerPairs.length > 128) throw new Error('材料图层集合无效/超出预算');
    const keys: Set<string> = new Set<string>();
    for (const item of request.routeLayerPairs) {
      if (item === null || item === undefined) throw new Error('材料图层集合含空值');
      for (const value of [item.layerNumber, item.datatype]) if (!Number.isInteger(value) || value < 0 || value > 32767) throw new Error('材料图层无效');
      const key: string = `${item.layerNumber}/${item.datatype}`; if (keys.has(key)) throw new Error('材料图层重复'); keys.add(key);
    }
  }
  const b: RouteBounds = request.boundsNm;
  if (b === null || b === undefined) throw new Error('必须给出有限的布线区域');
  for (const value of [b.minX, b.minY, b.maxX, b.maxY]) exactDbu(value, request.dbuNm, '布线区域');
  if (b.maxX - b.minX <= envelope(request) || b.maxY - b.minY <= envelope(request)) throw new Error('布线区域无法容纳真实材料包络');
}
function validateRequest(request: RoutePlannerRequest, context: RouteSearchContext): void {
  if (!Array.isArray(request.pairs) || request.pairs.length < 1 || request.pairs.length > context.limits.pairs ||
    !Array.isArray(request.obstacles) || request.obstacles.length > context.limits.obstacles) throw new Error('布线配对/障碍为空、无效或超过预算');
  finite(request.dbuNm, 'DBU'); if (request.dbuNm <= 0) throw new Error('DBU 须大于 0');
  const positive: RouteNumberOption[] = [{ value: request.gridNm, label: '布线网格' }, { value: request.leadNm, label: '引出长度' }];
  for (const item of positive) {
    exactDbu(item.value, request.dbuNm, item.label); if (item.value <= 0) throw new Error(`${item.label} 须大于 0`);
  }
  const spacing: RouteNumberOption[] = [{ value: request.clearanceNm, label: '障碍间距' }, { value: request.separationNm, label: '束线边缘间距' }];
  for (const item of spacing) {
    exactDbu(item.value, request.dbuNm, item.label); if (item.value < 0) throw new Error(`${item.label} 不得为负`);
  }
  validateMaterial(request);
  if (request.minimumTurnRunNm !== undefined) {
    exactDbu(request.minimumTurnRunNm, request.dbuNm, '最小转弯内部直线占用');
    if (request.minimumTurnRunNm < 0) throw new Error('最小转弯内部直线占用不得为负');
  }
  if (typeof request.matchLengths !== 'boolean') throw new Error('长度匹配须明确启用或关闭');
  if (request.lengthToleranceNm !== undefined && (!Number.isFinite(request.lengthToleranceNm) || request.lengthToleranceNm < 0 || request.lengthToleranceNm > request.dbuNm / 100)) throw new Error('长度容差须为 0–DBU/100，不接受近似长度冒充精确匹配');
  const pairKeys: Set<string> = new Set<string>(), terminalKeys: Set<string> = new Set<string>(), obstacleKeys: Set<string> = new Set<string>();
  let vertices: number = 0;
  for (const obstacle of request.obstacles) {
    if (obstacle === null || typeof obstacle.key !== 'string' || obstacle.key.length < 1 || obstacleKeys.has(obstacle.key) ||
      !Array.isArray(obstacle.pointsNm) || obstacle.pointsNm.length < (obstacle.kind === 'polygon' ? 3 : 2) ||
      (obstacle.kind !== 'polygon' && obstacle.kind !== 'path')) throw new Error('障碍身份、类型或顶点无效/重复');
    obstacleKeys.add(obstacle.key); vertices += obstacle.pointsNm.length;
    if (vertices > context.limits.vertices) throw new Error('布线障碍顶点预算耗尽');
    for (const value of [obstacle.layerNumber, obstacle.datatype]) if (!Number.isInteger(value) || value < 0 || value > 32767) throw new Error('障碍图层/Datatype 无效');
    const points: Point[] = obstacle.pointsNm.map((point: Point): Point => continuousMaterialPoint(point, request.dbuNm));
    for (const point of points) context.epsilon = Math.max(context.epsilon, Math.abs(point.x) * Number.EPSILON * 64, Math.abs(point.y) * Number.EPSILON * 64);
    if (samePoint(points[0], points[points.length - 1])) points.pop();
    if (points.length < (obstacle.kind === 'polygon' ? 3 : 2)) throw new Error('障碍轮廓退化');
    for (let index: number = 1; index < points.length; index++) if (samePoint(points[index - 1], points[index])) throw new Error('障碍含重复连续顶点');
    let radius: number = 0;
    if (obstacle.kind === 'path') {
      if (obstacle.widthNm === undefined || obstacle.widthNm <= 0) throw new Error('PATH 障碍缺少真实正线宽');
      if (!Number.isFinite(obstacle.widthNm) || obstacle.widthNm / request.dbuNm > 2147483647) throw new Error('连续 PATH 障碍线宽非有限或超过坐标范围');
      radius = obstacle.widthNm / 2;
    } else {
      let area: number = 0;
      for (let index: number = 0; index < points.length; index++) {
        const next: number = (index + 1) % points.length;
        area += (points[index].x - points[0].x) * (points[next].y - points[0].y) - (points[index].y - points[0].y) * (points[next].x - points[0].x);
        for (let other: number = index + 2; other < points.length; other++) {
          if (index === 0 && other === points.length - 1) continue;
          spend(context);
          if (intersect(points[index], points[next], points[other], points[(other + 1) % points.length], context.epsilon)) throw new Error('障碍多边形自交或数值不确定，须先按真实材料分解');
        }
      }
      if (Math.abs(area) <= context.epsilon * context.epsilon) throw new Error('障碍多边形零面积');
    }
    context.material.push({ key: obstacle.key, points: points, polygon: obstacle.kind === 'polygon', radius: radius,
      layer: obstacle.layerNumber, datatype: obstacle.datatype, bounds: bounds(points) });
  }
  for (const pair of request.pairs) {
    if (pair === null || typeof pair.key !== 'string' || pair.key.length < 1 || pairKeys.has(pair.key)) throw new Error('布线配对身份无效/重复');
    pairKeys.add(pair.key);
    if (pair.material !== undefined && (pair.material === null ||
      typeof pair.material.allowLayerTransition !== 'boolean' || typeof pair.material.allowWidthTransition !== 'boolean' ||
      pair.material.routeLayerNumber === undefined || pair.material.routeDatatype === undefined || pair.material.routeLayerPairs === undefined))
      throw new Error('逐对材料须含完整真实主层、材料层及明确过渡授权');
    const scoped: RoutePlannerRequest = pairContext(pair, context).request;
    validateMaterial(scoped);
    if (pair.material?.layerBands !== undefined) {
      const bands: RouteLayerBand[] = pair.material.layerBands;
      if (!Array.isArray(bands) || bands.length < 1 || bands.length > 128) throw new Error('逐层真实带边界无效/超出预算');
      for (const band of bands) {
        if (band === null || !Number.isFinite(band.minimumNm) || !Number.isFinite(band.maximumNm) || band.maximumNm <= band.minimumNm ||
          Math.max(Math.abs(band.minimumNm), Math.abs(band.maximumNm)) > envelope(scoped) / 2 ||
          !routeLayers(pair, scoped).some((layer: RouteLayerPair): boolean => layer.layerNumber === band.layerNumber && layer.datatype === band.datatype))
          throw new Error('逐层真实带须有有限正宽，包含于该对真实包络及材料图层');
      }
      if (routeLayers(pair, scoped).some((layer: RouteLayerPair): boolean => !bands.some((band: RouteLayerBand): boolean => layer.layerNumber === band.layerNumber && layer.datatype === band.datatype)))
        throw new Error('逐层真实带遗漏已声明材料图层');
      const main: RouteLayerPair = mainLayer(pair, scoped), primary: RouteInterval[] = bands.filter((band: RouteLayerBand): boolean =>
        band.layerNumber === main.layerNumber && band.datatype === main.datatype).map((band: RouteLayerBand): RouteInterval =>
        ({ low: band.minimumNm, high: band.maximumNm })).sort((a: RouteInterval, b: RouteInterval): number => a.low - b.low);
      let covered: number = -scoped.widthNm / 2;
      for (const interval of primary) {
        if (interval.low > covered + context.epsilon) break;
        covered = Math.max(covered, interval.high);
      }
      if (covered + context.epsilon < scoped.widthNm / 2) throw new Error('逐层真实带未完整覆盖居中的最大主材料宽度');
    }
    for (const terminal of [pair.start, pair.end]) {
      if (terminal === null || terminal === undefined || typeof terminal.key !== 'string' || terminal.key.length < 1 || terminalKeys.has(terminal.key)) throw new Error('束线须显式一对一映射，端口身份不得重复');
      terminalKeys.add(terminal.key); exactPoint(terminal.centerNm, request.dbuNm, '端口'); finite(terminal.orientationDeg, '端口方向');
      exactDbu(terminal.widthNm, request.dbuNm, '端口有效线宽');
      if (terminal.widthNm <= 0 || (terminal.widthNm !== scoped.widthNm && scoped.allowWidthTransition !== true)) throw new Error('端口有效线宽与路线不一致，须先指定真实宽度过渡');
      if (terminal.widthNm > envelope(scoped)) throw new Error('真实材料包络必须覆盖端口及宽度过渡的最大有效宽度');
      for (const value of [terminal.layerNumber, terminal.datatype]) if (!Number.isInteger(value) || value < 0 || value > 32767) throw new Error('端口图层/Datatype 无效');
      if (typeof terminal.portType !== 'string' || terminal.portType.length < 1) throw new Error('端口类型无效');
      if (!pointInBounds(terminal.centerNm, scoped)) throw new Error('端口导体超出布线区域');
      if (terminal.ownerObstacleKeys !== undefined && (!Array.isArray(terminal.ownerObstacleKeys) || terminal.ownerObstacleKeys.length > context.limits.obstacles ||
        terminal.ownerObstacleKeys.some((key: string): boolean => !obstacleKeys.has(key)))) throw new Error('端口引出 owner 障碍身份无效');
    }
    const main: RouteLayerPair = mainLayer(pair, scoped);
    if (pair.start.portType !== pair.end.portType) throw new Error('路线两端端口类型不兼容');
    if (scoped.allowLayerTransition !== true && [pair.start, pair.end].some((terminal: RouteTerminal): boolean => terminal.layerNumber !== main.layerNumber || terminal.datatype !== main.datatype)) throw new Error('路线两端图层/Datatype 不兼容，未暗加跨层器件');
    if (!routeLayers(pair, scoped).some((item: RouteLayerPair): boolean => item.layerNumber === main.layerNumber && item.datatype === main.datatype)) throw new Error('材料图层集合必须包含真实主线图层');
    if (samePoint(pair.start.centerNm, pair.end.centerNm)) throw new Error('路线两端坐标重合，不能生成零长/闭合假路线');
    if ((pair.waypointsNm ?? []).length > context.limits.waypoints) throw new Error('手动途经点预算耗尽');
    for (const point of pair.waypointsNm ?? []) { exactPoint(point, request.dbuNm, '途经点'); if (!pointInBounds(point, scoped)) throw new Error('途经点超出布线区域'); }
    if (pair.targetLengthNm !== undefined && (!Number.isFinite(pair.targetLengthNm) || pair.targetLengthNm <= 0)) throw new Error('配对目标长度须为正有限数');
  }
  if (request.targetLengthNm !== undefined && (!Number.isFinite(request.targetLengthNm) || request.targetLengthNm <= 0)) throw new Error('目标长度须为正有限数');
}

export class RoutePlannerService {
  plan(request: RoutePlannerRequest): RoutePlannerResult {
    const stats: RoutePlannerStats = { expandedNodes: 0, collisionChecks: 0, work: 0, orderAttempts: 0, lengthMatchCandidates: 0 };
    try {
      const limits: RouteLimits = budgets(request.budget);
      const magnitude: number = request.boundsNm === undefined || request.boundsNm === null ? 1 : Math.max(1, Math.abs(request.boundsNm.minX), Math.abs(request.boundsNm.minY), Math.abs(request.boundsNm.maxX), Math.abs(request.boundsNm.maxY));
      const context: RouteSearchContext = { request: request, limits: limits, stats: stats, material: [], epsilon: Math.max(request.dbuNm * 1e-8, magnitude * Number.EPSILON * 64), priorMaterial: new Map<string, RouteMaterial[]>() };
      validateRequest(request, context);
      const orders: number[][] = [], original: number[] = request.pairs.map((_pair: RoutePair, index: number): number => index);
      orders.push(original);
      if (original.length > 1) orders.push(original.slice().reverse());
      for (let offset: number = 1; offset < original.length && orders.length < limits.orders; offset++) orders.push(original.slice(offset).concat(original.slice(0, offset)));
      let lastError: string = '没有可用束线顺序';
      for (const order of orders.slice(0, limits.orders)) {
        stats.orderAttempts++;
        try {
          const planned: PlannedRoute[] = [];
          for (const index of order) planned.push(planPair(request.pairs[index], planned, pairContext(request.pairs[index], context)));
          const routes: PlannedRoute[] = request.pairs.map((pair: RoutePair): PlannedRoute => planned.find((route: PlannedRoute): boolean => route.pairKey === pair.key) as PlannedRoute);
          let common: number | undefined = request.targetLengthNm;
          if (request.matchLengths) {
            const specified: number[] = request.pairs.filter((pair: RoutePair): boolean => pair.targetLengthNm !== undefined).map((pair: RoutePair): number => pair.targetLengthNm as number);
            if (common === undefined && specified.length > 0) common = specified[0];
            if (common === undefined) common = Math.max(...routes.map((route: PlannedRoute): number => route.lengthNm));
            const tolerance: number = request.lengthToleranceNm ?? request.dbuNm * 1e-6;
            if (specified.some((value: number): boolean => Math.abs(value - (common as number)) > tolerance)) throw new Error('束线长度匹配的各配对目标必须一致');
          }
          for (let index: number = 0; index < routes.length; index++) {
            const target: number | undefined = request.matchLengths ? common : request.pairs[index].targetLengthNm ?? common;
            if (target !== undefined) routes[index] = matchRoute(routes[index], request.pairs[index], routes.filter((_route: PlannedRoute, other: number): boolean => other !== index), target, pairContext(request.pairs[index], context));
          }
          let output: number = 0;
          for (let index: number = 0; index < routes.length; index++) {
            output += routes[index].pointsNm.length;
            if (output > limits.output || !validateLine(routes[index].pointsNm, request.pairs[index], routes.filter((_route: PlannedRoute, other: number): boolean => other !== index), pairContext(request.pairs[index], context))) throw new Error('完整束线复核失败或输出超过预算，未发布部分路线');
          }
          return { ok: true, message: `已规划 ${routes.length} 条真实避障路线${request.matchLengths ? '并完成几何长度匹配' : ''}；未移动原实例`, routes: routes, stats: stats };
        } catch (error) {
          lastError = (error as Error).message;
          if (stats.work > limits.work || stats.expandedNodes > limits.expanded) throw new Error((error as Error).message);
        }
      }
      throw new Error(lastError);
    } catch (error) {
      return { ok: false, message: (error as Error).message, routes: [], stats: stats };
    }
  }
}
export const routePlannerService: RoutePlannerService = new RoutePlannerService();
