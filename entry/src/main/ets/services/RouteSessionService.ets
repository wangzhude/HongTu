import { ShapeType } from '../models/GdsiiData';
import type { Shape, Point } from '../models/GdsiiData';
import { validateLayoutSemantics, newLayoutIdentity, layoutUtf8Bytes } from '../models/LayoutPort';
import type { ResolvedPort, LayoutCrossSection } from '../models/LayoutPort';
import type { RouteSessionContext, RouteSessionRequest, RouteSessionPair, RouteSessionPreview, RouteSessionResult, RouteSessionBudget, RouteSessionOpticalSettings, RouteSessionOpticalRoute } from '../models/RouteSession';
import type { RouteMaterialInspectRequest, RouteMaterialRequest, RouteMaterialProfile, RouteMaterialResult, RouteMaterialBand, RouteMaterialCap, RouteMaterialExecution, RouteTaperRule } from '../models/RouteMaterial';
import type { TechnologyPackage } from '../common/technologyPackage';
import { EditService, editService } from './EditService';
import type { EditStructureState } from './EditService';
import { resolveLayoutPort } from './PortService';
import { validatePropertyHierarchy } from './ShapePropertyService';
import { routePlannerService } from './RoutePlannerService';
import type { RoutePlannerRequest, RoutePlannerResult, RoutePlannerStats, RoutePair, RoutePairMaterial, RouteLayerBand, RouteTerminal, RouteObstacle, RouteLayerPair, PlannedRoute, RouteBounds } from './RoutePlannerService';
import { routeMaterialService } from './RouteMaterialService';
import { routeObstacleService, routeEndpointOwnerKey } from './RouteObstacleService';
import type { RouteObstacleRequest, RouteObstacleResult } from './RouteObstacleService';
import { nativeHongTuService } from './NativeHongTuService';
import { opticalRouteService } from './OpticalRouteService';
import type { OpticalRouteRequest, OpticalRouteResult, OpticalRouteGeometry, OpticalRouteObstacle, OpticalBboxSection, OpticalRouteBounds } from '../models/OpticalRoute';
import type { BooleanOpType } from '../../cpp/types/libhongtu/Index';
import { cloneEditStructureModel, cloneShapeArray, cloneStructured } from '../common/CloneUtils';
export type { RouteSessionContext, RouteSessionRequest, RouteSessionPair, RouteSessionPreview, RouteSessionResult, RouteSessionBudget, RouteSessionOpticalSettings, RouteSessionOpticalRoute } from '../models/RouteSession';

export interface RoutePlanningProvider { plan(request: RoutePlannerRequest): RoutePlannerResult; }
export interface RouteMaterialProvider {
  inspect(request: RouteMaterialInspectRequest): RouteMaterialProfile;
  build(request: RouteMaterialRequest): RouteMaterialResult;
  inspectExecution?(request: RouteMaterialInspectRequest): RouteMaterialExecution;
}
export interface RouteOpticalProvider { route(request: OpticalRouteRequest): OpticalRouteResult; }
export interface RouteObstacleProvider { collect(request: RouteObstacleRequest): RouteObstacleResult; }
class CurrentRoutePlanningProvider implements RoutePlanningProvider {
  plan(request: RoutePlannerRequest): RoutePlannerResult { return routePlannerService.plan(request); }
}
class CurrentRouteMaterialProvider implements RouteMaterialProvider {
  inspect(request: RouteMaterialInspectRequest): RouteMaterialProfile { return routeMaterialService.inspect(request); }
  build(request: RouteMaterialRequest): RouteMaterialResult { return routeMaterialService.build(request); }
  inspectExecution(request: RouteMaterialInspectRequest): RouteMaterialExecution { return routeMaterialService.inspectExecution(request); }
}
class CurrentRouteOpticalProvider implements RouteOpticalProvider {
  route(request: OpticalRouteRequest): OpticalRouteResult { return opticalRouteService.route(request); }
}
class CurrentRouteObstacleProvider implements RouteObstacleProvider {
  collect(request: RouteObstacleRequest): RouteObstacleResult { return routeObstacleService.collect(request); }
}
export interface RouteSessionRegionProvider {
  difference(subject: Point[], clips: Point[][], gridNm: number): Point[][];
}
export interface RouteSessionDependencies {
  edit?: EditService; planner?: RoutePlanningProvider; material?: RouteMaterialProvider;
  obstacles?: RouteObstacleProvider; region?: RouteSessionRegionProvider;
  optical?: RouteOpticalProvider;
}
interface RouteSessionLimits { sourceShapes: number; sourcePoints: number; shapes: number; vertices: number; work: number; }
interface RouteInspection { pair: RouteSessionPair; input: RouteMaterialInspectRequest; profile: RouteMaterialProfile; execution?: RouteMaterialExecution; }
interface RouteOpticalPreparedInput { pairKey: string; input: OpticalRouteRequest; }
interface RoutePreparedBundle {
  routes: PlannedRoute[]; materials: RouteMaterialResult[]; profiles: RouteMaterialProfile[]; warnings: string[];
  opticalRoutes: RouteSessionOpticalRoute[]; opticalInputs: RouteOpticalPreparedInput[]; plannerStats: RoutePlannerStats;
}
interface RouteSessionPlan {
  request: RouteSessionRequest; before: EditStructureState; after: EditStructureState; sourceShapes: Shape[];
  candidateShapes: Shape[]; inspections: RouteInspection[]; obstacles: RouteObstacleResult;
  preview: RouteSessionPreview; dbuNm: number; limits: RouteSessionLimits;
  opticalInputs?: RouteOpticalPreparedInput[];
}
interface RouteSessionPending { id: string; source: string; candidate: string; plan: RouteSessionPlan; }
interface RouteGeometryWork { used: number; maximum: number; }
interface RouteContactCorridor { ownerPrefix: string; points: Point[]; origin: Point; end: Point; halfWidth: number; }
interface RouteRayInterval { minimum: number; maximum: number; }

function fail(message: string): never { throw new Error(message); }
function copyPoint(point: Point): Point { return { x: point.x, y: point.y }; }
function limit(value: number | undefined, fallback: number, maximum: number): number {
  const result: number = value ?? fallback;
  if (!Number.isSafeInteger(result) || result < 1 || result > maximum) fail('布线事务预算无效');
  return result;
}
function limits(budget: RouteSessionBudget | undefined): RouteSessionLimits {
  const b: RouteSessionBudget = budget ?? {};
  return { sourceShapes: limit(b.maximumSourceShapes, 100000, 1000000), sourcePoints: limit(b.maximumSourcePoints, 1000000, 4000000),
    shapes: limit(b.maximumCandidateShapes, 20000, 100000), vertices: limit(b.maximumCandidateVertices, 200000, 1000000),
    work: limit(b.maximumValidationWork, 4000000, 20000000) };
}
/** Validate before JSON cloning: nonfinite input must not silently become null. */
function inert(value: Object, maximum: number = 20000000): void {
  const queue: Object[] = [value], depths: number[] = [0];
  for (let at: number = 0; at < queue.length; at++) {
    if (at >= maximum || depths[at] > 64) fail('布线事务输入超出节点/深度预算');
    const item: Object = queue[at];
    if (typeof item === 'number' && !Number.isFinite(item as number)) fail('布线输入含非有限数值，未进行 JSON 空值替换');
    if (item === null || item === undefined || typeof item === 'string' || typeof item === 'boolean' || typeof item === 'number') continue;
    if (typeof item !== 'object') fail('布线事务仅接受惰性数据');
    const record: Record<string, Object> = item as Record<string, Object>;
    for (const key of Object.keys(item)) {
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') fail('布线输入含保留键');
      queue.push(record[key]); depths.push(depths[at] + 1);
    }
  }
}
function exact(value: number, dbu: number, label: string): void {
  const units: number = value / dbu;
  if (!Number.isFinite(value) || !Number.isFinite(dbu) || dbu <= 0 || !Number.isFinite(units) || Math.abs(units) > 2147483647 ||
    Math.abs(units - Math.round(units)) > Math.max(1, Math.abs(units)) * Number.EPSILON * 128) fail(`${label} 必须精确落在实际文档 DBU/int32 范围`);
}
function spend(work: RouteGeometryWork, amount: number = 1): void {
  work.used += amount;
  if (work.used > work.maximum) fail('最终真实材料几何校验超过工作预算，未发布部分路线');
}
function pairKey(layer: number, datatype: number): string { return `${layer}/${datatype}`; }
function planningMaterial(profile: RouteMaterialProfile, dbu: number): RoutePairMaterial {
  const exactBands: boolean = profile.transitionKind === 'uniform' && profile.descriptorSchemas.every((schema: string): boolean =>
    schema === 'port-primary/v1' || schema === 'hongtu-route-material/v1');
  return { widthNm: profile.maximumPrimaryWidthNm, materialEnvelopeWidthNm: Math.ceil(profile.obstacleEnvelopeWidthNm / dbu) * dbu,
    routeLayerNumber: profile.startPrimaryLayer.layerNumber, routeDatatype: profile.startPrimaryLayer.datatype,
    routeLayerPairs: profile.routeLayerPairs.map((layer): RouteLayerPair => ({ layerNumber: layer.layerNumber, datatype: layer.datatype })),
    allowWidthTransition: profile.transitionKind !== 'uniform', allowLayerTransition: profile.transitionKind === 'via',
    layerBands: exactBands ? profile.startBands.map((band: RouteMaterialBand): RouteLayerBand =>
      ({ layerNumber: band.layerNumber, datatype: band.datatype, minimumNm: band.minimumNm, maximumNm: band.maximumNm })) : undefined };
}
function bounds(points: Point[], work: RouteGeometryWork): RouteBounds {
  let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
  for (const p of points) { spend(work); minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
  return { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
}
function cross(a: Point, b: Point, c: Point): number { return (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x); }
function pointDistance(p: Point, a: Point, b: Point): number {
  const dx: number = b.x - a.x, dy: number = b.y - a.y, length: number = dx * dx + dy * dy;
  if (!(length > 0) || !Number.isFinite(length)) fail('最终材料边退化或数值越界');
  const t: number = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length));
  return Math.hypot(p.x - a.x - t * dx, p.y - a.y - t * dy);
}
function intersects(a: Point, b: Point, c: Point, d: Point, epsilon: number): boolean {
  const ab: number = Math.hypot(b.x - a.x, b.y - a.y), cd: number = Math.hypot(d.x - c.x, d.y - c.y);
  if (Math.max(a.x, b.x) + epsilon < Math.min(c.x, d.x) || Math.max(c.x, d.x) + epsilon < Math.min(a.x, b.x) ||
    Math.max(a.y, b.y) + epsilon < Math.min(c.y, d.y) || Math.max(c.y, d.y) + epsilon < Math.min(a.y, b.y)) return false;
  return Math.min(cross(a, b, c), cross(a, b, d)) <= epsilon * ab && Math.max(cross(a, b, c), cross(a, b, d)) >= -epsilon * ab &&
    Math.min(cross(c, d, a), cross(c, d, b)) <= epsilon * cd && Math.max(cross(c, d, a), cross(c, d, b)) >= -epsilon * cd;
}
function inside(p: Point, ring: Point[], epsilon: number, work: RouteGeometryWork): boolean {
  let result: boolean = false;
  for (let i: number = 0, j: number = ring.length - 1; i < ring.length; j = i++) {
    spend(work); const a: Point = ring[j], b: Point = ring[i];
    if (pointDistance(p, a, b) <= epsilon) return true;
    if ((a.y > p.y) !== (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) result = !result;
  }
  return result;
}
function collision(a: Point[], b: Point[], clearance: number, epsilon: number, work: RouteGeometryWork): boolean {
  const x: RouteBounds = bounds(a, work), y: RouteBounds = bounds(b, work);
  if (x.maxX + clearance + epsilon < y.minX || y.maxX + clearance + epsilon < x.minX ||
    x.maxY + clearance + epsilon < y.minY || y.maxY + clearance + epsilon < x.minY) return false;
  for (let i: number = 0; i < a.length; i++) for (let j: number = 0; j < b.length; j++) {
    spend(work); const aa: Point = a[i], ab: Point = a[(i + 1) % a.length], ba: Point = b[j], bb: Point = b[(j + 1) % b.length];
    if (intersects(aa, ab, ba, bb, epsilon)) return true;
    if (Math.min(pointDistance(aa, ba, bb), pointDistance(ab, ba, bb), pointDistance(ba, aa, ab), pointDistance(bb, aa, ab)) + epsilon < clearance) return true;
  }
  return inside(a[0], b, epsilon, work) || inside(b[0], a, epsilon, work);
}
function polygon(ring: Point[], work: RouteGeometryWork): void {
  if (!Array.isArray(ring) || ring.length < 3) fail('实际材料 polygon 缺少完整轮廓');
  let area: number = 0;
  for (let i: number = 0; i < ring.length; i++) {
    spend(work); const a: Point = ring[i], b: Point = ring[(i + 1) % ring.length];
    if (a === null || !Number.isFinite(a.x) || !Number.isFinite(a.y) || (a.x === b.x && a.y === b.y)) fail('实际材料 polygon 非有限或有退化边');
    area += (a.x - ring[0].x) * (b.y - ring[0].y) - (a.y - ring[0].y) * (b.x - ring[0].x);
  }
  if (!Number.isFinite(area) || area === 0) fail('实际材料 polygon 面积退化或越界');
}
function simplePolygon(ring: Point[], epsilon: number, work: RouteGeometryWork): void {
  polygon(ring, work);
  for (let at: number = 0; at < ring.length; at++) {
    spend(work); const a: Point = ring[(at + ring.length - 1) % ring.length], b: Point = ring[at], c: Point = ring[(at + 1) % ring.length];
    const length: number = Math.hypot(b.x - a.x, b.y - a.y) + Math.hypot(c.x - b.x, c.y - b.y);
    if (Math.abs(cross(a, b, c)) <= epsilon * length && (b.x - a.x) * (c.x - b.x) + (b.y - a.y) * (c.y - b.y) < 0) fail('追加材料 polygon 有反折重叠边');
  }
  for (let a: number = 0; a < ring.length; a++) for (let b: number = a + 1; b < ring.length; b++) {
    if (b === a + 1 || (a === 0 && b === ring.length - 1)) continue;
    spend(work);
    if (intersects(ring[a], ring[(a + 1) % ring.length], ring[b], ring[(b + 1) % ring.length], epsilon)) fail('追加材料 polygon 自交或非相邻边接触');
  }
}
function closePoint(a: Point, b: Point, epsilon: number): boolean { return Math.hypot(a.x - b.x, a.y - b.y) <= epsilon; }
function corridor(owner: string, a: Point, b: Point, half: number): RouteContactCorridor {
  const length: number = Math.hypot(b.x - a.x, b.y - a.y);
  if (!Number.isFinite(length) || length <= 0 || !Number.isFinite(half) || half <= 0) fail('具体端点引出 corridor 无效');
  const nx: number = -(b.y - a.y) / length * half, ny: number = (b.x - a.x) / length * half;
  return { ownerPrefix: owner + '#', origin: copyPoint(a), end: copyPoint(b), halfWidth: half, points: [{ x: a.x + nx, y: a.y + ny }, { x: b.x + nx, y: b.y + ny },
    { x: b.x - nx, y: b.y - ny }, { x: a.x - nx, y: a.y - ny }] };
}
/** The curve solver checks its complete polygon against obstacles. Remove only
 * the clearance neighbourhood of an independently certified finite contact,
 * including the contacting cap's backside. The final transaction validator
 * still clips the actual route to the original corridor and checks every
 * unmodified source polygon, so this cannot excuse remote owner or reentry. */
function contactClearanceClip(contact: RouteContactCorridor, padding: number): Point[] {
  const length: number = Math.hypot(contact.end.x - contact.origin.x, contact.end.y - contact.origin.y);
  const dx: number = (contact.end.x - contact.origin.x) / length, dy: number = (contact.end.y - contact.origin.y) / length;
  const a: Point = { x: contact.origin.x - dx * padding, y: contact.origin.y - dy * padding };
  const b: Point = { x: contact.end.x + dx * padding, y: contact.end.y + dy * padding };
  const half: number = contact.halfWidth + padding, nx: number = -dy * half, ny: number = dx * half;
  return [{ x: a.x + nx, y: a.y + ny }, { x: b.x + nx, y: b.y + ny },
    { x: b.x - nx, y: b.y - ny }, { x: a.x - nx, y: a.y - ny }];
}
/** Exact filled-polygon ray plus edge capsules must occupy one origin-prefix.
 * This independently rejects remote same-owner material and exit/re-entry;
 * the finite rectangle alone is never a general owner-shape exemption. */
function ownerPrefix(obstacle: Point[], contact: RouteContactCorridor, clearance: number, epsilon: number, work: RouteGeometryWork): boolean {
  const length: number = Math.hypot(contact.end.x - contact.origin.x, contact.end.y - contact.origin.y);
  const dx: number = (contact.end.x - contact.origin.x) / length, dy: number = (contact.end.y - contact.origin.y) / length;
  const radius: number = contact.halfWidth + clearance + epsilon, intervals: RouteRayInterval[] = [], events: number[] = [0, length];
  const local: Point[] = obstacle.map((p: Point): Point => ({ x: (p.x - contact.origin.x) * dx + (p.y - contact.origin.y) * dy,
    y: -(p.x - contact.origin.x) * dy + (p.y - contact.origin.y) * dx }));
  const add = (minimum: number, maximum: number): void => {
    spend(work); const low: number = Math.max(0, minimum), high: number = Math.min(length, maximum);
    if (!Number.isFinite(minimum) || !Number.isFinite(maximum)) fail('owner 引出证书数值越界');
    if (high >= low) intervals.push({ minimum: low, maximum: high });
  };
  for (let at: number = 0; at < local.length; at++) {
    spend(work); const a: Point = local[at], b: Point = local[(at + 1) % local.length];
    if ((a.y > 0) !== (b.y > 0)) {
      const x: number = a.x + (b.x - a.x) * -a.y / (b.y - a.y); if (x > 0 && x < length) events.push(x);
    }
    for (const point of [a, b]) if (Math.abs(point.y) <= radius) {
      const half: number = Math.sqrt(Math.max(0, radius * radius - point.y * point.y)); add(point.x - half, point.x + half);
    }
    const ex: number = b.x - a.x, ey: number = b.y - a.y, squared: number = ex * ex + ey * ey;
    let low: number = 0, high: number = length;
    const linear = (coefficient: number, constant: number, minimum: number, maximum: number): void => {
      if (coefficient === 0) { if (constant < minimum || constant > maximum) high = -1; return; }
      const first: number = (minimum - constant) / coefficient, second: number = (maximum - constant) / coefficient;
      low = Math.max(low, Math.min(first, second)); high = Math.min(high, Math.max(first, second));
    };
    linear(-ey, ey * a.x - ex * a.y, -radius * Math.sqrt(squared), radius * Math.sqrt(squared));
    linear(ex, -ex * a.x - ey * a.y, 0, squared);
    if (high >= low) add(low, high);
  }
  events.sort((a: number, b: number): number => a - b);
  for (let at: number = 1; at < events.length; at++) {
    spend(work); const low: number = events[at - 1], high: number = events[at]; if (high <= low) continue;
    const middle: number = low / 2 + high / 2, p: Point = { x: contact.origin.x + dx * middle, y: contact.origin.y + dy * middle };
    if (inside(p, obstacle, epsilon, work)) add(low, high);
  }
  if (intervals.length === 0) return false;
  intervals.sort((a: RouteRayInterval, b: RouteRayInterval): number => a.minimum - b.minimum);
  if (intervals[0].minimum > epsilon) return false;
  let occupied: number = intervals[0].maximum;
  for (let at: number = 1; at < intervals.length; at++) {
    spend(work); if (intervals[at].minimum > occupied + epsilon) return false; occupied = Math.max(occupied, intervals[at].maximum);
  }
  return occupied + epsilon < length;
}
class NativeRouteSessionRegionProvider implements RouteSessionRegionProvider {
  difference(subject: Point[], clips: Point[][], gridNm: number): Point[][] {
    const flatSubject: number[] = []; for (const p of subject) flatSubject.push(p.x, p.y);
    const flatClips: number[][] = clips.map((ring: Point[]): number[] => { const flat: number[] = []; for (const p of ring) flat.push(p.x, p.y); return flat; });
    const nativeSubjects: number[][] = [flatSubject], kind: BooleanOpType = 2;
    const result = nativeHongTuService.regionBooleanForEdit(nativeSubjects, flatClips, kind, gridNm);
    if (!result.success) fail(`真实 owner corridor 差集失败：${result.errorMessage}`);
    return result.polygons.map((flat: number[]): Point[] => {
      if (flat.length < 6 || flat.length % 2 !== 0) fail('真实 corridor 差集返回无效轮廓');
      const ring: Point[] = []; for (let at: number = 0; at < flat.length; at += 2) ring.push({ x: flat[at], y: flat[at + 1] }); return ring;
    });
  }
}

/** Pure sealed planning, followed by one existing geometry/metadata transaction. */
export class RouteSessionService {
  private edit: EditService; private planner: RoutePlanningProvider; private material: RouteMaterialProvider;
  private obstacles: RouteObstacleProvider; private region: RouteSessionRegionProvider;
  private optical: RouteOpticalProvider;
  private pending: RouteSessionPending | null = null;
  constructor(dependencies: RouteSessionDependencies = {}) {
    this.edit = dependencies.edit ?? editService; this.planner = dependencies.planner ?? new CurrentRoutePlanningProvider();
    this.material = dependencies.material ?? new CurrentRouteMaterialProvider(); this.obstacles = dependencies.obstacles ?? new CurrentRouteObstacleProvider();
    this.optical = dependencies.optical ?? new CurrentRouteOpticalProvider();
    this.region = dependencies.region ?? new NativeRouteSessionRegionProvider();
  }
  private fingerprint(context: RouteSessionContext): string {
    inert(context as Object); inert(this.edit.getShapes() as Object);
    return JSON.stringify([context.documentIdentity, context.structure, context.technologyJson, this.edit.getSessionRevision(),
      this.edit.getCurrentCellId(), this.edit.getSelectionIdentity(), this.edit.getShapes(), this.edit.getNextShapeId()]);
  }
  private context(context: RouteSessionContext): number {
    inert(context as Object);
    if (this.edit.isTransactionOpen()) fail('请先结束当前编辑批次，再准备或应用布线');
    if (context === null || typeof context.documentIdentity !== 'string' || context.documentIdentity.length < 1 || context.documentIdentity.length > 4096 ||
      typeof context.technologyJson !== 'string' || layoutUtf8Bytes(context.technologyJson) > 8 * 1024 * 1024 ||
      context.structure.topCellId !== this.edit.getTopCellId() || JSON.stringify(context.structure.cellStack) !== JSON.stringify(this.edit.getCurrentCellStack()) ||
      JSON.stringify(context.structure.navigationPath ?? []) !== JSON.stringify(this.edit.getNavigationPath())) fail('布线文档、当前 Cell 或导航上下文已变化');
    validateLayoutSemantics(context.structure, context.structure.cellNames.length);
    const error: string = validatePropertyHierarchy(this.edit.getShapes(), context.structure.topCellId); if (error.length > 0) fail(error);
    const dbu: number = context.structure.physicalUnits === undefined ? context.structure.precision?.dbuNm ?? 1 : context.structure.physicalUnits * 1e9;
    if (!Number.isFinite(dbu) || dbu <= 0) fail('文档实际 DBU 无效'); return dbu;
  }
  cancel(id?: string): void { if (id === undefined || this.pending?.id === id) this.pending = null; }
  getPreview(id: string, context: RouteSessionContext): RouteSessionPreview | undefined {
    try {
      const pending: RouteSessionPending | null = this.pending;
      if (pending === null || pending.id !== id || pending.source !== this.fingerprint(context) || pending.candidate !== JSON.stringify(pending.plan)) return undefined;
      this.context(context); for (const inspection of pending.plan.inspections) this.editable(inspection.profile);
      return cloneStructured(pending.plan.preview) as RouteSessionPreview;
    } catch (_) { return undefined; }
  }
  getPreviewShapes(id: string, context: RouteSessionContext): Shape[] { return this.getPreview(id, context)?.shapes ?? []; }
  private section(port: ResolvedPort, state: EditStructureState): LayoutCrossSection | undefined {
    return port.definition.crossSectionKey === undefined ? undefined : (state.crossSections ?? []).find((row: LayoutCrossSection): boolean =>
      row.key === port.definition.crossSectionKey && row.version === port.definition.crossSectionVersion);
  }
  private editable(profile: RouteMaterialProfile): void {
    for (const layer of profile.routeLayerPairs) if (!this.edit.canEditLayer(layer.layerNumber, layer.datatype)) fail(`布线材料 L${layer.layerNumber}/D${layer.datatype} 已锁定`);
  }
  private terminal(port: ResolvedPort, obstacles: RouteObstacle[]): RouteTerminal {
    const owner: string = routeEndpointOwnerKey(port.endpoint) + '#';
    return { key: `${routeEndpointOwnerKey(port.endpoint)}@${port.definition.id}`, centerNm: copyPoint(port.centerNm), orientationDeg: port.orientationDeg,
      widthNm: port.effectiveWidthNm, layerNumber: port.definition.layerNumber, datatype: port.definition.datatype, portType: port.definition.portType,
      ownerObstacleKeys: obstacles.filter((shape: RouteObstacle): boolean => shape.key.startsWith(owner)).map((shape: RouteObstacle): string => shape.key) };
  }
  private opticalInput(inspection: RouteInspection, request: RouteSessionRequest, collected: RouteObstacleResult,
    previous: RouteMaterialResult[], previousOptical: RouteSessionOpticalRoute[], currentCell: number, firstShapeId: number, dbu: number): OpticalRouteRequest {
    const settings: RouteSessionOpticalSettings | undefined = request.optical;
    if (settings === undefined || inspection.execution === undefined) fail('optical 端口需要明确真实曲线设置及截面执行来源');
    const options: RouteSessionOpticalSettings = settings as RouteSessionOpticalSettings;
    const execution: RouteMaterialExecution = inspection.execution as RouteMaterialExecution;
    const ports: ResolvedPort[] = [inspection.input.start, inspection.input.end], clipGrid: number = dbu / 16;
    const half: number = inspection.profile.obstacleEnvelopeWidthNm / 2 + options.maximumDeviationNm;
    const corridors: RouteContactCorridor[] = ports.map((port: ResolvedPort): RouteContactCorridor => {
      const radians: number = port.orientationDeg * Math.PI / 180;
      const exit: Point = { x: port.centerNm.x + Math.cos(radians) * request.leadNm, y: port.centerNm.y + Math.sin(radians) * request.leadNm };
      return corridor(routeEndpointOwnerKey(port.endpoint), port.centerNm, exit, half);
    });
    const layers: Set<string> = new Set<string>(inspection.profile.routeLayerPairs.map((layer): string => pairKey(layer.layerNumber, layer.datatype)));
    const obstacles: OpticalRouteObstacle[] = [], work: RouteGeometryWork = { used: 0, maximum: limits(request.sessionBudget).work };
    const sourceGap: number = request.clearanceNm + collected.maximumApproximationErrorNm + clipGrid / Math.sqrt(2);
    for (const obstacle of collected.obstacles) {
      if (!layers.has(pairKey(obstacle.layerNumber, obstacle.datatype))) continue;
      const padding: number = Math.ceil((sourceGap + options.maximumDeviationNm + clipGrid / Math.sqrt(2) + dbu * 1e-6) / clipGrid) * clipGrid;
      const clips: Point[][] = corridors.filter((c: RouteContactCorridor): boolean => obstacle.key.startsWith(c.ownerPrefix) &&
        ownerPrefix(obstacle.pointsNm, c, sourceGap, dbu * 1e-7, work)).map((c: RouteContactCorridor): Point[] => contactClearanceClip(c, padding));
      const rings: Point[][] = clips.length === 0 ? [obstacle.pointsNm] : this.region.difference(obstacle.pointsNm, clips, clipGrid);
      if (rings.length > limits(request.sessionBudget).shapes) fail('光学 owner 有限 corridor 差集超过完整预算');
      for (let at: number = 0; at < rings.length; at++) {
        polygon(rings[at], work);
        obstacles.push({ key: `${obstacle.key}:finite-corridor:${at}`, pointsNm: rings[at], layerNumber: obstacle.layerNumber, datatype: obstacle.datatype,
          clearanceNm: sourceGap });
      }
    }
    for (let index: number = 0; index < previous.length; index++) {
      const earlier: RouteSessionOpticalRoute | undefined = previousOptical.find((row: RouteSessionOpticalRoute): boolean =>
        row.geometry.shapes.some((shape: Shape): boolean => shape.id === previous[index].shapes[0].id));
      const extra: number = earlier?.geometry.maximumDeviationNm ?? 0;
      for (const shape of previous[index].shapes) if (layers.has(pairKey(shape.layerNumber, shape.datatype)))
        obstacles.push({ key: `prior-route:${index}#${shape.id}`, pointsNm: shape.points, layerNumber: shape.layerNumber, datatype: shape.datatype,
          clearanceNm: request.separationNm + extra });
    }
    const bboxSections: OpticalBboxSection[] = execution.bboxSections.map((row): OpticalBboxSection =>
      ({ layerNumber: row.layerNumber, datatype: row.datatype, offsetNm: row.offsetNm }));
    const opticalBounds: OpticalRouteBounds = { minX: request.boundsNm.minX, minY: request.boundsNm.minY,
      maxX: request.boundsNm.maxX, maxY: request.boundsNm.maxY };
    let taperRule: RouteTaperRule | undefined = undefined;
    if (execution.transitionRule !== undefined && execution.transitionRule.kind === 'linear-taper') {
      const sourceRule: RouteTaperRule = execution.transitionRule as RouteTaperRule;
      taperRule = { schema: 'hongtu-route-transition/v1', kind: 'linear-taper',
        minimumLengthNm: sourceRule.minimumLengthNm, maximumEdgeSlope: sourceRule.maximumEdgeSlope };
    }
    const input: OpticalRouteRequest = { start: inspection.input.start, end: inspection.input.end, dbuNm: dbu, ownerCellId: currentCell, firstShapeId: firstShapeId,
      materialProfile: inspection.profile, bend: options.bend, minimumRadiusNm: options.minimumRadiusNm, eulerFraction: options.eulerFraction,
      maximumDeviationNm: options.maximumDeviationNm, coordinatePolicy: options.coordinatePolicy ?? 'quantize-interior', portTolerance: options.portTolerance,
      startLeadNm: request.leadNm, endLeadNm: request.leadNm, boundsNm: opticalBounds, obstacles: obstacles,
      clearanceNm: sourceGap, bboxSections: bboxSections, taperRule: taperRule,
      budget: options.budget };
    return input;
  }
  private opticalBackbone(inspection: RouteInspection, request: RouteSessionRequest, collected: RouteObstacleResult, dbu: number): Point[] {
    const settings: RouteSessionOpticalSettings = request.optical as RouteSessionOpticalSettings;
    const radius: number = Math.max(settings.minimumRadiusNm, inspection.profile.minimumBendRadiusNm);
    const bend = opticalRouteService.bend({ kind: settings.bend === 'circular' ? 'circular' : 'euler', minimumRadiusNm: radius,
      turnDeg: 90, eulerFraction: settings.eulerFraction, maximumDeviationNm: settings.maximumDeviationNm, budget: settings.budget });
    const setback: number = bend.tangentSetbackNm ?? radius;
    const reserved: number = Math.ceil(inspection.profile.obstacleEnvelopeWidthNm / dbu) * dbu;
    const pair: RoutePair = { key: inspection.pair.key, start: this.terminal(inspection.input.start, collected.obstacles), end: this.terminal(inspection.input.end, collected.obstacles),
      waypointsNm: inspection.pair.waypointsNm, material: { widthNm: inspection.profile.maximumPrimaryWidthNm, materialEnvelopeWidthNm: reserved,
        routeLayerNumber: inspection.profile.startPrimaryLayer.layerNumber, routeDatatype: inspection.profile.startPrimaryLayer.datatype,
        routeLayerPairs: inspection.profile.routeLayerPairs.map((layer): RouteLayerPair => ({ layerNumber: layer.layerNumber, datatype: layer.datatype })),
        allowWidthTransition: inspection.profile.transitionKind !== 'uniform', allowLayerTransition: false } };
    const plannerRequest: RoutePlannerRequest = { pairs: [pair], obstacles: collected.obstacles, dbuNm: dbu, widthNm: inspection.profile.maximumPrimaryWidthNm,
      clearanceNm: Math.ceil((request.clearanceNm + collected.maximumApproximationErrorNm) / dbu) * dbu, separationNm: request.separationNm,
      leadNm: Math.ceil((request.leadNm + setback) / dbu) * dbu, gridNm: request.gridNm, boundsNm: request.boundsNm,
      minimumTurnRunNm: Math.ceil((2 * setback + 2 * settings.maximumDeviationNm) / dbu) * dbu,
      matchLengths: false, budget: request.plannerBudget };
    const planned: RoutePlannerResult = this.planner.plan(plannerRequest);
    if (!planned.ok || planned.routes.length !== 1) fail('当前有限避障骨架候选未找到可剪圆路径：' + planned.message);
    const points: Point[] = planned.routes[0].pointsNm, result: Point[] = [];
    for (const point of points) {
      while (result.length >= 2) {
        const a: Point = result[result.length - 2], b: Point = result[result.length - 1];
        if (Math.abs(cross(a, b, point)) > dbu * dbu * 1e-8 || (b.x - a.x) * (point.x - b.x) + (b.y - a.y) * (point.y - b.y) <= 0) break;
        result.pop();
      }
      result.push(point);
    }
    return result;
  }
  private cap(port: ResolvedPort, cap: RouteMaterialCap, band: RouteMaterialBand, a: Point, b: Point,
    material: RouteMaterialResult, dbu: number, epsilon: number, work: RouteGeometryWork): void {
    const length: number = Math.hypot(b.x - a.x, b.y - a.y);
    if (!(length > 0) || !Number.isFinite(length)) fail('端点主材料切线退化');
    const normal: Point = { x: -(b.y - a.y) / length, y: (b.x - a.x) / length };
    const lower: Point = { x: port.centerNm.x + normal.x * band.minimumNm, y: port.centerNm.y + normal.y * band.minimumNm };
    const upper: Point = { x: port.centerNm.x + normal.x * band.maximumNm, y: port.centerNm.y + normal.y * band.maximumNm };
    for (const point of [cap.centerNm, cap.lowerEdgeNm, cap.upperEdgeNm, lower, upper]) {
      exact(point.x, dbu, '端面 X'); exact(point.y, dbu, '端面 Y');
    }
    if (cap.portId !== port.definition.id || cap.layerNumber !== port.definition.layerNumber || cap.datatype !== port.definition.datatype ||
      !closePoint(cap.centerNm, port.centerNm, epsilon) || !closePoint(cap.lowerEdgeNm, lower, epsilon) || !closePoint(cap.upperEdgeNm, upper, epsilon) ||
      Math.abs(cap.expectedWidthNm - port.effectiveWidthNm) > epsilon || Math.abs(cap.actualWidthNm - port.effectiveWidthNm) > epsilon ||
      Math.abs(Math.hypot(upper.x - lower.x, upper.y - lower.y) - port.effectiveWidthNm) > epsilon) fail('真实材料端帽未匹配端口完整 frame/有效宽度/材料层');
    let found: boolean = false;
    for (const shape of material.shapes) {
      if (shape.layerNumber !== cap.layerNumber || shape.datatype !== cap.datatype) continue;
      for (let at: number = 0; at < shape.points.length; at++) {
        spend(work); const p: Point = shape.points[at], q: Point = shape.points[(at + 1) % shape.points.length];
        if ((closePoint(p, lower, epsilon) && closePoint(q, upper, epsilon)) || (closePoint(p, upper, epsilon) && closePoint(q, lower, epsilon))) found = true;
      }
    }
    if (!found) fail('真实 polygon 未包含报告的严格 flush 端面边');
  }
  private opticalCap(port: ResolvedPort, cap: RouteMaterialCap, band: RouteMaterialBand, atStart: boolean,
    geometry: OpticalRouteGeometry, request: OpticalRouteRequest, epsilon: number, work: RouteGeometryWork): void {
    const radians: number = (port.orientationDeg + (atStart ? 0 : 180)) * Math.PI / 180;
    const normal: Point = { x: -Math.sin(radians), y: Math.cos(radians) };
    const idealLower: Point = { x: port.centerNm.x + normal.x * band.minimumNm, y: port.centerNm.y + normal.y * band.minimumNm };
    const idealUpper: Point = { x: port.centerNm.x + normal.x * band.maximumNm, y: port.centerNm.y + normal.y * band.maximumNm };
    exact(cap.lowerEdgeNm.x, request.dbuNm, '光学端面 X'); exact(cap.lowerEdgeNm.y, request.dbuNm, '光学端面 Y');
    exact(cap.upperEdgeNm.x, request.dbuNm, '光学端面 X'); exact(cap.upperEdgeNm.y, request.dbuNm, '光学端面 Y');
    const width: number = Math.hypot(cap.upperEdgeNm.x - cap.lowerEdgeNm.x, cap.upperEdgeNm.y - cap.lowerEdgeNm.y);
    if (!(width > 0) || !Number.isFinite(width) || cap.portId !== port.definition.id || cap.layerNumber !== port.definition.layerNumber || cap.datatype !== port.definition.datatype ||
      !closePoint(cap.centerNm, port.centerNm, epsilon) || Math.abs(cap.actualWidthNm - width) > epsilon || Math.abs(cap.expectedWidthNm - port.effectiveWidthNm) > epsilon) fail('真实光学端面身份、frame 或孔径报告不一致');
    const centerError: number = Math.hypot((cap.lowerEdgeNm.x + cap.upperEdgeNm.x - idealLower.x - idealUpper.x) / 2,
      (cap.lowerEdgeNm.y + cap.upperEdgeNm.y - idealLower.y - idealUpper.y) / 2);
    const angle: number = Math.atan2(cap.upperEdgeNm.y - cap.lowerEdgeNm.y, cap.upperEdgeNm.x - cap.lowerEdgeNm.x) - Math.atan2(normal.y, normal.x);
    const angleError: number = Math.abs(Math.atan2(Math.sin(angle), Math.cos(angle))) * 180 / Math.PI, widthError: number = Math.abs(width - port.effectiveWidthNm);
    const recorded = geometry.endpointErrors[atStart ? 0 : 1];
    if (recorded === undefined || recorded.portId !== port.definition.id || Math.abs(recorded.centerErrorNm - centerError) > epsilon ||
      Math.abs(recorded.angleErrorDeg - angleError) > 1e-8 || Math.abs(recorded.widthErrorNm - widthError) > epsilon) fail('光学端面误差未按实际 DBU polygon 边独立报告');
    const tolerance = request.coordinatePolicy === 'quantize-with-port-tolerance' ? request.portTolerance : undefined;
    if (request.coordinatePolicy === 'quantize-with-port-tolerance' && tolerance === undefined) fail('量化光学端面必须给出明确物理容差');
    if (centerError > (tolerance?.maximumCenterErrorNm ?? 0) + epsilon || angleError > (tolerance?.maximumAngleErrorDeg ?? 0) + 1e-8 ||
      widthError > (tolerance?.maximumWidthErrorNm ?? 0) + epsilon) fail('实际写入光学端面中心/方向/孔径超过明确容差');
    let found: boolean = false;
    for (const shape of geometry.shapes) if (shape.layerNumber === cap.layerNumber && shape.datatype === cap.datatype)
      for (let at: number = 0; at < shape.points.length; at++) {
        spend(work); const a: Point = shape.points[at], b: Point = shape.points[(at + 1) % shape.points.length];
        if ((closePoint(a, cap.lowerEdgeNm, epsilon) && closePoint(b, cap.upperEdgeNm, epsilon)) ||
          (closePoint(b, cap.lowerEdgeNm, epsilon) && closePoint(a, cap.upperEdgeNm, epsilon))) found = true;
      }
    if (!found) fail('实际 optical polygon 未包含报告的 flush 端面实边');
  }
  private validateOptical(geometry: OpticalRouteGeometry, input: OpticalRouteRequest, sampledLength: number, work: RouteGeometryWork, epsilon: number): number {
    const certificate = opticalRouteService.certifyGeometry(input, geometry);
    if (!certificate.ok) fail('光学候选不符合真实 primitive/材料重生成：' + certificate.message);
    spend(work, certificate.workUsed);
    let continuous: number = 0, maximum: number = 0;
    for (const primitive of geometry.primitives) {
      spend(work);
      if (!Number.isFinite(primitive.lengthNm) || primitive.lengthNm <= 0 || Math.abs(primitive.startStationNm - continuous) > epsilon) fail('光学 primitive 弧长 station/正长度无效');
      let length: number = primitive.lengthNm;
      if (primitive.kind !== 'straight') {
        if (primitive.kind !== 'circular' && primitive.kind !== 'euler') fail('未知光学 primitive');
        if (!(primitive.minimumRadiusNm >= Math.max(input.minimumRadiusNm, input.materialProfile.minimumBendRadiusNm)) || !Number.isFinite(primitive.turnRad)) fail('真实光学曲率半径小于明确截面/路线最小半径');
        length = Math.abs(primitive.turnRad) * primitive.minimumRadiusNm * (primitive.kind === 'euler' ? 1 + primitive.eulerFraction : 1);
        maximum = Math.max(maximum, 1 / primitive.minimumRadiusNm);
        if (Math.abs(length - primitive.lengthNm) > Math.max(epsilon, length * Number.EPSILON * 256)) fail('真实光学 primitive 连续弧长公式不一致');
      }
      continuous += length;
    }
    const tolerance: number = Math.max(epsilon, continuous * Number.EPSILON * 512);
    if (Math.abs(continuous - geometry.continuousLengthNm) > tolerance || Math.abs(sampledLength - geometry.sampledLengthNm) > tolerance ||
      Math.abs(maximum - geometry.maximumCurvaturePerNm) > 1e-10 || geometry.maximumDeviationNm > input.maximumDeviationNm + epsilon) fail('光学连续弧长/真实取样长度/曲率/误差界报告不一致');
    if (geometry.materialSources.length !== geometry.shapes.length || new Set<number>(geometry.materialSources.map((row): number => row.shapeId)).size !== geometry.shapes.length ||
      geometry.shapes.some((shape: Shape): boolean => !geometry.materialSources.some((row): boolean => row.shapeId === shape.id))) fail('光学真实 strip/bbox 材料身份不完整');
    return continuous;
  }
  private buildBundle(inspections: RouteInspection[], request: RouteSessionRequest, collected: RouteObstacleResult,
    currentCell: number, dbu: number, commonTarget: number | undefined): RoutePreparedBundle {
    const electrical: RouteInspection[] = inspections.filter((row: RouteInspection): boolean => row.input.start.definition.portType === 'electrical');
    const hasOptical: boolean = electrical.length !== inspections.length;
    let planned: RoutePlannerResult = { ok: true, message: '', routes: [], stats: { expandedNodes: 0, collisionChecks: 0, work: 0, orderAttempts: 0, lengthMatchCandidates: 0 } };
    if (electrical.length > 0) {
      const pairs: RoutePair[] = electrical.map((row: RouteInspection): RoutePair => ({ key: row.pair.key, start: this.terminal(row.input.start, collected.obstacles),
        end: this.terminal(row.input.end, collected.obstacles), waypointsNm: row.pair.waypointsNm, targetLengthNm: row.pair.targetLengthNm,
        material: planningMaterial(row.profile, dbu) }));
      const plannerInput: RoutePlannerRequest = { pairs: pairs, obstacles: collected.obstacles, dbuNm: dbu, widthNm: electrical[0].profile.maximumPrimaryWidthNm,
        clearanceNm: Math.ceil((request.clearanceNm + collected.maximumApproximationErrorNm) / dbu) * dbu, separationNm: request.separationNm,
        leadNm: request.leadNm, gridNm: request.gridNm, boundsNm: request.boundsNm,
        matchLengths: request.matchLengths && (!hasOptical || commonTarget !== undefined), targetLengthNm: commonTarget ?? request.targetLengthNm,
        lengthToleranceNm: request.lengthToleranceNm, budget: request.plannerBudget };
      planned = this.planner.plan(plannerInput); inert(planned as Object);
      if (!planned.ok || planned.routes.length !== electrical.length) fail(planned.message || '没有生成全部真实电气配对');
    }
    const routes: PlannedRoute[] = [], materials: RouteMaterialResult[] = [], profiles: RouteMaterialProfile[] = [], warnings: string[] = [];
    const opticalRoutes: RouteSessionOpticalRoute[] = [], opticalInputs: RouteOpticalPreparedInput[] = [];
    const keys: Set<string> = new Set<string>(); let nextId: number = this.edit.getNextShapeId();
    for (const inspected of inspections) {
      if (keys.has(inspected.pair.key)) fail('配对身份重复'); keys.add(inspected.pair.key);
      let route: PlannedRoute, material: RouteMaterialResult;
      if (inspected.input.start.definition.portType === 'electrical') {
        const known: PlannedRoute | undefined = planned.routes.find((row: PlannedRoute): boolean => row.pairKey === inspected.pair.key);
        if (known === undefined) fail('规划返回未知/遗漏电气配对'); route = known as PlannedRoute;
        const materialInput: RouteMaterialRequest = { start: inspected.input.start, end: inspected.input.end, dbuNm: dbu,
          startCrossSection: inspected.input.startCrossSection, endCrossSection: inspected.input.endCrossSection,
          descriptorJson: inspected.input.descriptorJson, endDescriptorJson: inspected.input.endDescriptorJson, transitionRuleJson: inspected.input.transitionRuleJson,
          technology: inspected.input.technology, budget: request.materialBudget, centerlineNm: route.pointsNm, ownerCellId: currentCell, firstShapeId: nextId,
          bendModel: 'miter-polyline', coordinatePolicy: request.coordinatePolicy ?? 'strict' };
        material = this.material.build(materialInput);
      } else {
        const input: OpticalRouteRequest = this.opticalInput(inspected, request, collected, materials, opticalRoutes, currentCell, nextId, dbu);
        input.targetLengthNm = request.matchLengths ? commonTarget : inspected.pair.targetLengthNm ?? request.targetLengthNm;
        input.lengthToleranceNm = input.targetLengthNm === undefined ? undefined : request.lengthToleranceNm ?? dbu * 1e-6;
        if ((inspected.pair.waypointsNm ?? []).length > 0) input.backboneNm = this.opticalBackbone(inspected, request, collected, dbu);
        let result: OpticalRouteResult = this.optical.route(cloneStructured(input) as OpticalRouteRequest);
        if (!result.ok && input.backboneNm === undefined) {
          const automatic: string = result.message;
          try {
            input.backboneNm = this.opticalBackbone(inspected, request, collected, dbu);
            result = this.optical.route(cloneStructured(input) as OpticalRouteRequest);
          } catch (error) { fail(`当前自动曲线与有限骨架候选未生成安全光学材料（未证明全局无解）：${automatic}；${String(error)}`); }
        }
        inert(result as Object);
        if (!result.ok || result.route === undefined) fail(result.message || '光学真实曲线未生成');
        const geometry: OpticalRouteGeometry = result.route as OpticalRouteGeometry, expected: RoutePairMaterial = planningMaterial(inspected.profile, dbu);
        route = { pairKey: inspected.pair.key, startKey: this.terminal(inspected.input.start, collected.obstacles).key, endKey: this.terminal(inspected.input.end, collected.obstacles).key,
          pointsNm: geometry.centerlineNm, lengthNm: geometry.continuousLengthNm, baseLengthNm: geometry.continuousLengthNm, addedLengthNm: 0,
          widthNm: expected.widthNm, layerNumber: expected.routeLayerNumber, datatype: expected.routeDatatype, envelopeWidthNm: expected.materialEnvelopeWidthNm,
          layerPairs: expected.routeLayerPairs, layerBands: expected.layerBands };
        material = { shapes: geometry.shapes, profile: geometry.profile, endpointCaps: geometry.endpointCaps, centerlineLengthNm: geometry.continuousLengthNm,
          quantizedInteriorVertices: 0, maximumQuantizationErrorNm: geometry.quantizationErrorNm,
          transitionRule: inspected.execution?.transitionRule, materialShapeIds: geometry.shapes.map((shape: Shape): number => shape.id), cutShapeIds: [], padShapeIds: [],
          warnings: geometry.warnings, workUsed: geometry.workUsed };
        opticalRoutes.push({ pairKey: inspected.pair.key, geometry: geometry }); opticalInputs.push({ pairKey: inspected.pair.key, input: input });
      }
      inert(material as Object);
      if (material.shapes.length === 0 || material.endpointCaps.length !== 2) fail('真实材料或两个严格端帽未生成');
      for (const shape of material.shapes) nextId = Math.max(nextId, shape.id + 1);
      routes.push(route); materials.push(material); profiles.push(material.profile); warnings.push(...material.warnings);
    }
    return { routes: routes, materials: materials, profiles: profiles, warnings: warnings, opticalRoutes: opticalRoutes, opticalInputs: opticalInputs, plannerStats: planned.stats };
  }
  private validatePlan(plan: RouteSessionPlan): number {
    const work: RouteGeometryWork = { used: 0, maximum: plan.limits.work };
    if (JSON.stringify(plan.after) !== JSON.stringify(plan.before) || JSON.stringify(plan.candidateShapes.slice(0, plan.sourceShapes.length)) !== JSON.stringify(plan.sourceShapes) ||
      plan.candidateShapes.length !== plan.sourceShapes.length + plan.preview.shapes.length) fail('布线候选改写了原图、实例或端口/XS/context 元数据');
    validateLayoutSemantics(plan.after, plan.after.cellNames.length);
    const hierarchy: string = validatePropertyHierarchy(plan.candidateShapes, plan.after.topCellId); if (hierarchy.length > 0) fail(hierarchy);
    const epsilon: number = plan.dbuNm * 1e-7, clipGrid: number = plan.dbuNm / 16;
    let vertices: number = 0;
    if (plan.preview.shapes.length < 1 || plan.preview.shapes.length > plan.limits.shapes) fail('布线候选材料数量为空或超过预算');
    const ids: Set<number> = new Set<number>(plan.sourceShapes.map((shape: Shape): number => shape.id));
    for (const shape of plan.preview.shapes) {
      if (shape.type !== ShapeType.POLYGON || shape.ownerCellId !== plan.preview.ownerCellId || !Number.isSafeInteger(shape.id) || shape.id < 1 || shape.id > 2147483647 || ids.has(shape.id) || shape.selected) fail('布线只允许在当前 Cell 追加独立实际 polygon');
      ids.add(shape.id); if (!this.edit.canEditLayer(shape.layerNumber, shape.datatype)) fail(`布线材料 L${shape.layerNumber}/D${shape.datatype} 已锁定`);
      simplePolygon(shape.points, epsilon, work); vertices += shape.points.length; if (vertices > plan.limits.vertices) fail('布线完整材料顶点预算不足');
      for (const p of shape.points) { exact(p.x, plan.dbuNm, '材料 X'); exact(p.y, plan.dbuNm, '材料 Y');
        const b: RouteBounds = plan.request.boundsNm; if (p.x < b.minX || p.x > b.maxX || p.y < b.minY || p.y > b.maxY) fail('实际布线材料超出指定区域'); }
    }
    if (JSON.stringify(plan.candidateShapes.slice(plan.sourceShapes.length)) !== JSON.stringify(plan.preview.shapes)) fail('候选材料与实际提交几何不一致');
    const flattened: Shape[] = [];
    for (const material of plan.preview.materials) flattened.push(...material.shapes);
    if (JSON.stringify(flattened) !== JSON.stringify(plan.preview.shapes) || plan.preview.materials.length !== plan.inspections.length || plan.preview.routes.length !== plan.inspections.length) fail('实际材料列表、配对及提交几何不一致');
    const error: number = plan.obstacles.maximumApproximationErrorNm;
    if (!Number.isFinite(error) || error < 0) fail('完整障碍误差界无效');
    for (const obstacle of plan.obstacles.obstacles) { if (obstacle.kind !== 'polygon') fail('完整障碍必须来自真实面积轮廓，未将 GDS PATH 误作 capsule'); polygon(obstacle.pointsNm, work); }
    const actualLengths: Map<string, number> = new Map<string, number>();
    const opticalKeys: Set<string> = new Set<string>();
    for (const row of plan.preview.opticalRoutes ?? []) { if (opticalKeys.has(row.pairKey)) fail('重复光学配对身份'); opticalKeys.add(row.pairKey); }
    for (let index: number = 0; index < plan.preview.routes.length; index++) {
      const route: PlannedRoute = plan.preview.routes[index], inspection: RouteInspection | undefined = plan.inspections.find((item: RouteInspection): boolean => item.pair.key === route.pairKey);
      if (inspection === undefined || route.pointsNm.length < 2) fail('候选配对或实际引出路径缺失');
      const source: RouteInspection = inspection as RouteInspection, material: RouteMaterialResult = plan.preview.materials[index]; this.editable(source.profile);
      const optical: RouteSessionOpticalRoute | undefined = (plan.preview.opticalRoutes ?? []).find((row: RouteSessionOpticalRoute): boolean => row.pairKey === route.pairKey);
      const opticalInput: RouteOpticalPreparedInput | undefined = (plan.opticalInputs ?? []).find((row: RouteOpticalPreparedInput): boolean => row.pairKey === route.pairKey);
      if ((source.input.start.definition.portType === 'optical') !== (optical !== undefined) || (optical !== undefined && opticalInput === undefined)) fail('配对端口类型与实际光学执行来源不一致');
      const deviation: number = optical?.geometry.maximumDeviationNm ?? 0;
      if (!Number.isFinite(deviation) || deviation < 0) fail('光学实际物理偏差界无效');
      const expected: RoutePairMaterial = planningMaterial(source.profile, plan.dbuNm);
      if (route.widthNm !== expected.widthNm || route.envelopeWidthNm !== expected.materialEnvelopeWidthNm ||
        route.layerNumber !== expected.routeLayerNumber || route.datatype !== expected.routeDatatype ||
        JSON.stringify(route.layerPairs) !== JSON.stringify(expected.routeLayerPairs) || JSON.stringify(route.layerBands) !== JSON.stringify(expected.layerBands))
        fail('规划报告没有保留该配对真实主宽、材料包络及逐层材料身份');
      if (JSON.stringify(material.profile) !== JSON.stringify(source.profile)) fail('实际材料 profile 与 inspect 包络不一致');
      const materialLayers: Set<string> = new Set<string>(source.profile.routeLayerPairs.map((layer): string => pairKey(layer.layerNumber, layer.datatype)));
      const classified: number[] = material.materialShapeIds.concat(material.cutShapeIds, material.padShapeIds);
      if (classified.length !== material.shapes.length || new Set<number>(classified).size !== classified.length ||
        material.shapes.some((shape: Shape): boolean => classified.indexOf(shape.id) < 0 || !materialLayers.has(pairKey(shape.layerNumber, shape.datatype)))) fail('实际材料层或 strip/cut/pad 完整身份不符合 inspect');
      const start: ResolvedPort = source.input.start, end: ResolvedPort = source.input.end, points: Point[] = route.pointsNm;
      if (Math.hypot(points[0].x - start.centerNm.x, points[0].y - start.centerNm.y) > epsilon ||
        Math.hypot(points[points.length - 1].x - end.centerNm.x, points[points.length - 1].y - end.centerNm.y) > epsilon) fail('布线真实中心线未连接完整端点 frame');
      let length: number = 0;
      for (let at: number = 1; at < points.length; at++) {
        spend(work); if (optical === undefined) { exact(points[at - 1].x, plan.dbuNm, '路线 X'); exact(points[at - 1].y, plan.dbuNm, '路线 Y'); }
        const segment: number = Math.hypot(points[at].x - points[at - 1].x, points[at].y - points[at - 1].y);
        if (!(segment > 0) || !Number.isFinite(segment)) fail('真实中心线有退化或非有限 segment'); length += segment;
      }
      if (optical === undefined) { exact(points[points.length - 1].x, plan.dbuNm, '路线末端 X'); exact(points[points.length - 1].y, plan.dbuNm, '路线末端 Y'); }
      if (optical !== undefined) {
        const input: OpticalRouteRequest = (opticalInput as RouteOpticalPreparedInput).input;
        if (JSON.stringify(input.start) !== JSON.stringify(source.input.start) || JSON.stringify(input.end) !== JSON.stringify(source.input.end) ||
          JSON.stringify(input.materialProfile) !== JSON.stringify(source.profile) || JSON.stringify(optical.geometry.shapes) !== JSON.stringify(material.shapes) ||
          JSON.stringify(optical.geometry.centerlineNm) !== JSON.stringify(points)) fail('真实光学端点/截面/材料/取样来源不一致');
        length = this.validateOptical(optical.geometry, input, length, work, epsilon);
      }
      const tolerance: number = Math.max(epsilon, length * Number.EPSILON * 128);
      if (!Number.isFinite(length) || Math.abs(length - route.lengthNm) > tolerance || Math.abs(length - material.centerlineLengthNm) > tolerance) fail('路线/材料报告长度与真实中心线长度不一致');
      actualLengths.set(route.pairKey, length);
      const radians: number = Math.PI / 180, last: number = points.length - 1;
      for (const endpoint of [start, end]) {
        const isStart: boolean = endpoint === start, origin: Point = isStart ? points[0] : points[last], lead: Point = isStart ? points[1] : points[last - 1];
        const leadLength: number = Math.hypot(lead.x - origin.x, lead.y - origin.y);
        if (leadLength + epsilon < plan.request.leadNm || Math.hypot((lead.x - origin.x) / leadLength - Math.cos(endpoint.orientationDeg * radians),
          (lead.y - origin.y) / leadLength - Math.sin(endpoint.orientationDeg * radians)) > 1e-10) fail('首/末有限引出段未保持端口完整 outward frame/最小 lead');
      }
      const startBand: RouteMaterialBand | undefined = source.profile.startBands.find((row: RouteMaterialBand): boolean => row.id === source.profile.primaryStripId);
      const endBand: RouteMaterialBand | undefined = source.profile.endBands.find((row: RouteMaterialBand): boolean => row.id === source.profile.primaryStripId);
      if (startBand === undefined || endBand === undefined || material.endpointCaps.length !== 2) fail('主材料端帽或截面缺失');
      if (optical === undefined) {
        this.cap(start, material.endpointCaps[0], startBand as RouteMaterialBand, points[0], points[1], material, plan.dbuNm, epsilon, work);
        this.cap(end, material.endpointCaps[1], endBand as RouteMaterialBand, points[last - 1], points[last], material, plan.dbuNm, epsilon, work);
      } else {
        this.opticalCap(start, material.endpointCaps[0], startBand as RouteMaterialBand, true, optical.geometry, (opticalInput as RouteOpticalPreparedInput).input, epsilon, work);
        this.opticalCap(end, material.endpointCaps[1], endBand as RouteMaterialBand, false, optical.geometry, (opticalInput as RouteOpticalPreparedInput).input, epsilon, work);
      }
      const corridors: RouteContactCorridor[] = [corridor(routeEndpointOwnerKey(start.endpoint), points[0], points[1], source.profile.obstacleEnvelopeWidthNm / 2 + deviation),
        corridor(routeEndpointOwnerKey(end.endpoint), points[points.length - 1], points[points.length - 2], source.profile.obstacleEnvelopeWidthNm / 2 + deviation)];
      for (const shape of material.shapes) for (const obstacle of plan.obstacles.obstacles) {
        spend(work); if (pairKey(shape.layerNumber, shape.datatype) !== pairKey(obstacle.layerNumber, obstacle.datatype)) continue;
        if (!collision(shape.points, obstacle.pointsNm, plan.request.clearanceNm + error + deviation, epsilon, work)) continue;
        const clips: Point[][] = corridors.filter((c: RouteContactCorridor): boolean => obstacle.key.startsWith(c.ownerPrefix) &&
          ownerPrefix(obstacle.pointsNm, c, plan.request.clearanceNm + error + deviation, epsilon, work)).map((c: RouteContactCorridor): Point[] => c.points);
        if (clips.length === 0) fail(`实际布线材料 #${shape.id} 碰撞/净距不足：${obstacle.key}`);
        const remaining: Point[][] = this.region.difference(shape.points, clips, clipGrid);
        if (!Array.isArray(remaining) || remaining.length > plan.limits.shapes) fail('owner corridor 差集超出完整预算');
        for (const ring of remaining) { polygon(ring, work); vertices += ring.length; if (vertices > plan.limits.vertices) fail('owner corridor 差集顶点预算不足');
          if (collision(ring, obstacle.pointsNm, plan.request.clearanceNm + error + deviation + clipGrid / Math.sqrt(2), epsilon, work)) fail(`路线在有效引出 corridor 外再次碰撞 source owner：${obstacle.key}`); }
      }
      for (let earlier: number = 0; earlier < index; earlier++) for (const a of material.shapes) for (const b of plan.preview.materials[earlier].shapes) {
        const earlierOptical: RouteSessionOpticalRoute | undefined = (plan.preview.opticalRoutes ?? []).find((row: RouteSessionOpticalRoute): boolean => row.pairKey === plan.preview.routes[earlier].pairKey);
        const netGap: number = plan.request.separationNm + deviation + (earlierOptical?.geometry.maximumDeviationNm ?? 0);
        spend(work); if (pairKey(a.layerNumber, a.datatype) === pairKey(b.layerNumber, b.datatype) && collision(a.points, b.points, netGap, epsilon, work)) fail('最终真实多层束线材料相交或互距不足');
      }
    }
    const tolerance: number = plan.request.lengthToleranceNm ?? plan.dbuNm * 1e-6;
    let common: number | undefined = plan.request.targetLengthNm;
    if (plan.request.matchLengths) {
      const specified: number[] = plan.request.pairs.filter((pair: RouteSessionPair): boolean => pair.targetLengthNm !== undefined)
        .map((pair: RouteSessionPair): number => pair.targetLengthNm as number);
      common = common ?? (specified.length > 0 ? specified[0] : undefined);
      if (common === undefined) common = Math.max(...Array.from(actualLengths.values()));
      if (specified.some((target: number): boolean => Math.abs(target - (common as number)) > tolerance)) fail('束线逐对目标与共同真实长度不一致');
    }
    for (const pair of plan.request.pairs) {
      const target: number | undefined = plan.request.matchLengths ? common : pair.targetLengthNm ?? common;
      const actual: number | undefined = actualLengths.get(pair.key);
      if (actual === undefined || (target !== undefined && Math.abs(actual - target) > tolerance)) fail('最终实际材料中心线未满足已请求的严格长度匹配');
    }
    return work.used;
  }
  prepare(context: RouteSessionContext, request: RouteSessionRequest): RouteSessionResult {
    this.pending = null;
    try {
      inert(request as Object); const dbu: number = this.context(context), source: string = this.fingerprint(context);
      const input: RouteSessionRequest = cloneStructured(request) as RouteSessionRequest, budget: RouteSessionLimits = limits(input.sessionBudget);
      exact(input.clearanceNm, dbu, '障碍净距'); exact(input.separationNm, dbu, '束线净距'); exact(input.leadNm, dbu, '引出长度'); exact(input.gridNm, dbu, '规划网格');
      if (input.clearanceNm < 0 || input.separationNm < 0 || input.leadNm <= 0 || input.gridNm <= 0 || typeof input.matchLengths !== 'boolean') fail('布线距离、网格或长度模式无效');
      for (const coordinate of [input.boundsNm.minX, input.boundsNm.minY, input.boundsNm.maxX, input.boundsNm.maxY]) exact(coordinate, dbu, '规划区域');
      const before: EditStructureState = cloneEditStructureModel(context.structure, true) as EditStructureState;
      const shapes: Shape[] = cloneShapeArray(this.edit.getShapes(), true) as Shape[];
      if (shapes.length > budget.sourceShapes || shapes.reduce((sum: number, shape: Shape): number => sum + shape.points.length, 0) > budget.sourcePoints) fail('源文档超过布线事务完整预算');
      if (!Array.isArray(input.pairs) || input.pairs.length < 1 || input.pairs.length > 128) fail('布线配对必须为完整非空列表，最多 128 对');
      const current: number = this.edit.getCurrentCellId(), technology: TechnologyPackage | undefined = context.technologyJson.length > 0 ? JSON.parse(context.technologyJson) as TechnologyPackage : undefined;
      if (technology !== undefined) inert(technology as Object);
      const inspections: RouteInspection[] = [], ports: ResolvedPort[] = [], allLayers: Map<string, RouteLayerPair> = new Map<string, RouteLayerPair>();
      const pairKeys: Set<string> = new Set<string>(), terminalKeys: Set<string> = new Set<string>();
      for (const pair of input.pairs) {
        if (pair === null || pair.start.rootCellId !== current || pair.end.rootCellId !== current) fail('路线全部端点必须位于同一当前 Cell 根坐标');
        if (typeof pair.key !== 'string' || pair.key.length === 0 || pairKeys.has(pair.key)) fail('布线配对身份无效/重复'); pairKeys.add(pair.key);
        const start: ResolvedPort = resolveLayoutPort(pair.start, shapes, before), end: ResolvedPort = resolveLayoutPort(pair.end, shapes, before);
        if (start.definition.portType !== end.definition.portType || (start.definition.portType !== 'electrical' && start.definition.portType !== 'optical')) fail('路线两端需同为明确电气或光学端口');
        if (start.definition.portType === 'optical' && input.optical === undefined) fail('光学端口须明确启用真实曲线模式、最小曲率半径与物理偏差界');
        for (const port of [start, end]) {
          const key: string = `${routeEndpointOwnerKey(port.endpoint)}@${port.definition.id}`;
          if (terminalKeys.has(key)) fail('束线须显式一对一映射，端口身份不得重复'); terminalKeys.add(key);
        }
        const inspectInput: RouteMaterialInspectRequest = { start: start, end: end, dbuNm: dbu, startCrossSection: this.section(start, before), endCrossSection: this.section(end, before),
          descriptorJson: pair.descriptorJson, endDescriptorJson: pair.endDescriptorJson, transitionRuleJson: pair.transitionRuleJson, technology: technology, budget: input.materialBudget,
          portCoordinatePolicy: start.definition.portType === 'optical' && input.optical?.coordinatePolicy === 'quantize-with-port-tolerance' ? 'continuous-for-optical' : 'strict' };
        const profile: RouteMaterialProfile = this.material.inspect(inspectInput); inert(profile as Object); this.editable(profile);
        const execution: RouteMaterialExecution | undefined = start.definition.portType === 'optical' ?
          (this.material.inspectExecution === undefined ? routeMaterialService.inspectExecution(inspectInput) : this.material.inspectExecution(inspectInput)) : undefined;
        if (execution !== undefined && JSON.stringify(execution.profile) !== JSON.stringify(profile)) fail('光学材料执行来源与真实 inspect profile 不一致');
        for (const layer of profile.routeLayerPairs) {
          const plannerLayer: RouteLayerPair = { layerNumber: layer.layerNumber, datatype: layer.datatype };
          allLayers.set(pairKey(layer.layerNumber, layer.datatype), plannerLayer);
        }
        inspections.push({ pair: pair, input: inspectInput, profile: profile, execution: execution }); ports.push(start, end);
      }
      const obstacleInput: RouteObstacleRequest = { shapes: shapes, structure: before, rootCellId: current, layers: Array.from(allLayers.values()), dbuNm: dbu, boundsNm: input.boundsNm, budget: input.obstacleBudget };
      const obstacleResult: RouteObstacleResult = this.obstacles.collect(obstacleInput); inert(obstacleResult as Object);
      const error: number = obstacleResult.maximumApproximationErrorNm; if (!Number.isFinite(error) || error < 0) fail('障碍轮廓误差界无效');
      if (input.pairs.length > limit(input.plannerBudget?.maxPairs, 32, 128)) fail('完整布线配对超过明确预算');
      const tolerance: number = input.lengthToleranceNm ?? dbu * 1e-6;
      if (!Number.isFinite(tolerance) || tolerance < 0 || tolerance > dbu / 100) fail('长度容差须为 0–DBU/100，不以近似长度替代真实匹配');
      const specified: number[] = input.pairs.filter((pair: RouteSessionPair): boolean => pair.targetLengthNm !== undefined).map((pair: RouteSessionPair): number => pair.targetLengthNm as number);
      for (const target of specified.concat(input.targetLengthNm === undefined ? [] : [input.targetLengthNm])) if (!Number.isFinite(target) || target <= 0) fail('真实路线目标长度必须为正有限数');
      let common: number | undefined = input.targetLengthNm;
      if (input.matchLengths) {
        common = common ?? (specified.length > 0 ? specified[0] : undefined);
        if (common !== undefined && specified.some((target: number): boolean => Math.abs(target - (common as number)) > tolerance)) fail('束线逐对目标与共同真实长度不一致');
      }
      let bundle: RoutePreparedBundle = this.buildBundle(inspections, input, obstacleResult, current, dbu, input.matchLengths ? common : undefined);
      if (input.matchLengths && common === undefined && bundle.opticalRoutes.length > 0) {
        common = Math.max(...bundle.routes.map((route: PlannedRoute): number => route.lengthNm));
        bundle = this.buildBundle(inspections, input, obstacleResult, current, dbu, common);
      }
      const added: Shape[] = [], materials: RouteMaterialResult[] = bundle.materials, profiles: RouteMaterialProfile[] = bundle.profiles, warnings: string[] = bundle.warnings;
      for (const material of materials) added.push(...material.shapes);
      if (error > 0) warnings.push(`障碍轮廓最大误差 ${error} nm 已纳入保守规划与最终材料净距`);
      warnings.push('材料与物理几何已验证；不代表光学模式/相位、通用 PDK DRC/LVS 或整组工艺布线资格');
      const preview: RouteSessionPreview = { id: newLayoutIdentity('route-preview'), shapes: added, ports: ports, routes: bundle.routes, profiles: profiles, materials: materials, warnings: warnings,
        obstacleCount: obstacleResult.obstacles.length, maximumApproximationErrorNm: error, plannerStats: bundle.plannerStats, validationWork: 0,
        ownerCellId: current, ownerCellKey: (before.cellKeys ?? [])[current], lengthDefinition: bundle.opticalRoutes.length > 0 ? '光学路线为真实连续曲线弧长；电气路线为实际折线长度。光学导出取样折线长另列，不推断相位。' : '实际电气折线中心线长度（nm；非光学弯曲/相位长度）',
        opticalRoutes: bundle.opticalRoutes.length > 0 ? bundle.opticalRoutes : undefined };
      const rawPlan: RouteSessionPlan = { request: input, before: before, after: before, sourceShapes: shapes, candidateShapes: shapes.concat(added),
        inspections: inspections, obstacles: obstacleResult, preview: preview, dbuNm: dbu, limits: budget, opticalInputs: bundle.opticalInputs };
      const plan: RouteSessionPlan = cloneStructured(rawPlan) as RouteSessionPlan;
      plan.preview.validationWork = this.validatePlan(plan);
      if (source !== this.fingerprint(context)) fail('布线准备期间文档、技术或选区已变化');
      this.pending = { id: plan.preview.id, source: source, candidate: JSON.stringify(plan), plan: plan };
      return { ok: true, message: '完整材料已预检；预览未修改文档，应用后可一次撤销', preview: cloneStructured(plan.preview) as RouteSessionPreview };
    } catch (error) { this.pending = null; return { ok: false, message: `布线未准备：${String(error)}` }; }
  }
  apply(id: string, context: RouteSessionContext): RouteSessionResult {
    const pending: RouteSessionPending | null = this.pending; this.pending = null;
    try {
      if (pending === null || pending.id !== id || pending.source !== this.fingerprint(context) || pending.candidate !== JSON.stringify(pending.plan)) fail('布线预览已取消、已使用、被修改或已过期');
      this.context(context); this.validatePlan(pending.plan);
      this.context(context);
      if (pending.source !== this.fingerprint(context) || pending.candidate !== JSON.stringify(pending.plan)) fail('最终几何校验期间源或候选发生变化');
      if (!this.edit.applyDocumentStructure(pending.plan.candidateShapes, context.structure, pending.plan.after, '端口布线：完整物理材料', true)) fail('布线单次结构事务被拒绝');
      return { ok: true, message: '真实布线材料已一次提交，可一次撤销；原端口和共享实例未移动', preview: cloneStructured(pending.plan.preview) as RouteSessionPreview };
    } catch (error) { return { ok: false, message: `布线未应用，原文档已保留：${String(error)}` }; }
  }
}
export const routeSessionService: RouteSessionService = new RouteSessionService();
