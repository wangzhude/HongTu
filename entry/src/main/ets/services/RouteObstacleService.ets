import { Shape, ShapeType, Point } from '../models/GdsiiData';
import type { EditStructureState, InstancePathStep } from './EditService';
import type { PortEndpoint } from '../models/LayoutPort';
import type { RouteObstacle, RouteBounds, RouteLayerPair } from './RoutePlannerService';
import { instanceTransformMat, Mat2D } from './HierarchyExpandService';
import { shapeRegionAdapterService } from './ShapeRegionAdapterService';
import type { ShapeRegionResult } from './ShapeRegionAdapterService';

export interface RouteRegionProvider { shape(shape: Shape, gridNm: number, worldScale: number): ShapeRegionResult; }
export interface RouteObstacleBudget { placements?: number; polygons?: number; vertices?: number; work?: number; depth?: number; }
export interface RouteObstacleRequest {
  shapes: Shape[]; structure: EditStructureState; rootCellId: number; layers: RouteLayerPair[];
  dbuNm: number; boundsNm: RouteBounds; budget?: RouteObstacleBudget;
}
export interface RouteObstacleResult {
  obstacles: RouteObstacle[]; maximumApproximationErrorNm: number;
  placements: number; polygons: number; vertices: number; work: number;
}
interface ContinuousMaterial { rings: Point[][]; errorNm: number; minimumLegNm?: number; }
function finitePoint(point: Point): boolean { return point !== undefined && point !== null && Number.isFinite(point.x) && Number.isFinite(point.y); }
function equalPoint(a: Point, b: Point): boolean { return a.x === b.x && a.y === b.y; }
function subtractPoint(a: Point, b: Point): Point { return { x: a.x-b.x, y:a.y-b.y }; }
function addScaledPoint(a: Point, b: Point, amount: number): Point { return { x: a.x+b.x*amount, y:a.y+b.y*amount }; }
function vectorLength(point: Point): number { return Math.hypot(point.x,point.y); }
function unitPoint(point: Point): Point {
  const length: number = vectorLength(point);
  if (!(length > 0) || !Number.isFinite(length)) throw new Error('连续 PATH 方向退化或非有限');
  return { x:point.x/length,y:point.y/length };
}
function normalPoint(point: Point): Point { return { x:-point.y,y:point.x }; }
function orientation(a: Point, b: Point, c: Point): number {
  const first: number = (b.x-a.x)*(c.y-a.y), second: number = (b.y-a.y)*(c.x-a.x), value: number = first-second;
  if (!Number.isFinite(value)) throw new Error('连续材料边界方向溢出');
  if (value !== 0 && Math.abs(value) <= (Math.abs(first)+Math.abs(second))*Number.EPSILON*32)
    throw new Error('连续材料边界接近共线，无法证明拓扑');
  return value;
}
function crossed(a: Point, b: Point, c: Point, d: Point): boolean {
  if (Math.max(a.x,b.x) < Math.min(c.x,d.x) || Math.max(c.x,d.x) < Math.min(a.x,b.x) ||
    Math.max(a.y,b.y) < Math.min(c.y,d.y) || Math.max(c.y,d.y) < Math.min(a.y,b.y)) return false;
  const one: number = orientation(a,b,c), two: number = orientation(a,b,d), three: number = orientation(c,d,a), four: number = orientation(c,d,b);
  return ((one<=0&&two>=0)||(one>=0&&two<=0))&&((three<=0&&four>=0)||(three>=0&&four<=0));
}
/** Keep source material continuous; integer union can erase a long sub-DBU arm.
 * A simple ring is certified before projection; ambiguous/self-crossing sources
 * fail explicitly rather than substituting their bbox or a partial native union. */
function checkedRing(input: Point[], spend: (amount?: number) => void): Point[] {
  const ring: Point[] = [];
  for (const point of input) {
    spend(); if (!finitePoint(point)) throw new Error('真实连续材料顶点非有限');
    if (!ring.length || !equalPoint(point,ring[ring.length-1])) ring.push({ x:point.x,y:point.y });
  }
  if (ring.length > 1 && equalPoint(ring[0],ring[ring.length-1])) ring.pop();
  if (ring.length < 3) throw new Error('真实连续材料轮廓退化');
  let area: number = 0, magnitude: number = 0;
  for (let index: number = 0; index < ring.length; index++) {
    const next: number = (index+1)%ring.length;
    const following: number = (index+2)%ring.length;
    if (orientation(ring[index],ring[next],ring[following])===0 &&
      (ring[next].x-ring[index].x)*(ring[following].x-ring[next].x)+
      (ring[next].y-ring[index].y)*(ring[following].y-ring[next].y)<0)
      throw new Error('源材料 POLYGON 相邻边回退自触');
    const first: number = (ring[index].x-ring[0].x)*(ring[next].y-ring[0].y), second: number = (ring[index].y-ring[0].y)*(ring[next].x-ring[0].x);
    area += first-second; magnitude += Math.abs(first)+Math.abs(second);
    for (let other: number = index+2; other < ring.length; other++) {
      if (index===0&&other===ring.length-1) continue;
      spend(); if (crossed(ring[index],ring[next],ring[other],ring[(other+1)%ring.length])) throw new Error('源材料 POLYGON 自交/自触，须先取得连续真实材料分解');
    }
  }
  if (!Number.isFinite(area) || Math.abs(area) <= magnitude*Number.EPSILON*64 || area === 0) throw new Error('源连续材料零面积或数值不确定');
  return ring;
}
function continuousArea(shape: Shape, spend: (amount?: number) => void): ContinuousMaterial {
  if (!Array.isArray(shape.points) || shape.points.length < 2) throw new Error('源连续材料缺少真实坐标');
  if (shape.type===ShapeType.POLYGON) return { rings:[checkedRing(shape.points,spend)],errorNm:0 };
  let minX: number = Infinity,minY: number = Infinity,maxX: number = -Infinity,maxY: number = -Infinity;
  for (const point of shape.points) {
    spend(); if (!finitePoint(point)) throw new Error('源 RECT 坐标非有限');
    minX=Math.min(minX,point.x);minY=Math.min(minY,point.y);maxX=Math.max(maxX,point.x);maxY=Math.max(maxY,point.y);
  }
  if (!(minX<maxX&&minY<maxY)) throw new Error('源 RECT 面积退化');
  return {rings:[[{x:minX,y:minY},{x:maxX,y:minY},{x:maxX,y:maxY},{x:minX,y:maxY}]],errorNm:0};
}
/** Continuous painted GDS PATH pieces mirror PathEditRegion's strip/miter/
 * extension and absolute-WIDTH semantics. Overlapping pieces are independent
 * filled obstacles, so retracing/self-crossing cannot erase material. Round
 * semicircles are circumscribed, never inscribed; error records outer excess. */
function continuousPath(shape: Shape, scale: number, spend: (amount?: number) => void): ContinuousMaterial {
  const width: number = shape.pathWidth ?? 0, type: number = shape.pathType ?? 0,
    beginValue: number = shape.pathBeginExtension ?? 0,endValue: number = shape.pathEndExtension ?? 0;
  if (!Number.isFinite(width)||width<=0||![0,1,2,4].includes(type)||!Number.isFinite(beginValue)||!Number.isFinite(endValue)||
    (shape.pathWidthAbsolute!==undefined&&typeof shape.pathWidthAbsolute!=='boolean')) throw new Error('连续 PATH 宽度、端型、extension 或 absolute WIDTH 无效');
  const localWidth: number = shape.pathWidthAbsolute===true ? width/scale : width, half: number = localWidth/2;
  if (!Number.isFinite(localWidth)||localWidth<=0) throw new Error('连续 PATH 有效线宽非有限');
  const points: Point[] = [];
  for (const point of shape.points) { spend();if(!finitePoint(point))throw new Error('连续 PATH spine 非有限');if(!points.length||!equalPoint(point,points[points.length-1]))points.push({x:point.x,y:point.y}); }
  if (points.length<2)throw new Error('连续 PATH spine 退化');
  const directions: Point[] = [];
  for(let index:number=1;index<points.length;index++){spend();directions.push(unitPoint(subtractPoint(points[index],points[index-1])));}
  const begin:number=type===2?half:type===4?beginValue:0,end:number=type===2?half:type===4?endValue:0;
  if(type===4&&((begin<0&&-begin>=vectorLength(subtractPoint(points[1],points[0])))||
    (end<0&&-end>=vectorLength(subtractPoint(points[points.length-1],points[points.length-2])))||
    (points.length===2&&vectorLength(subtractPoint(points[1],points[0]))+begin+end<=0)))throw new Error('连续 PATH signed extension 跨过相邻corner或反转spine');
  points[0]=addScaledPoint(points[0],directions[0],-begin);points[points.length-1]=addScaledPoint(points[points.length-1],directions[directions.length-1],end);
  let minimumLeg:number=Infinity;
  for(let index:number=1;index<points.length;index++)minimumLeg=Math.min(minimumLeg,vectorLength(subtractPoint(points[index],points[index-1])));
  if(!(minimumLeg>0)||!Number.isFinite(minimumLeg))throw new Error('连续 PATH trimmed spine 数值退化');
  const rings:Point[][]=[];
  for(let index:number=0;index<directions.length;index++){
    const n:Point=normalPoint(directions[index]);
    rings.push(checkedRing([addScaledPoint(points[index],n,half),addScaledPoint(points[index+1],n,half),
      addScaledPoint(points[index+1],n,-half),addScaledPoint(points[index],n,-half)],spend));
  }
  for(let index:number=1;index<points.length-1;index++){
    spend();const incoming:Point=directions[index-1],outgoing:Point=directions[index],turn:number=incoming.x*outgoing.y-incoming.y*outgoing.x;
    if(turn===0)continue;
    if(Math.abs(turn)<=Number.EPSILON*64)throw new Error('连续 PATH 转角数值不确定，未遗漏miter');
    const sum:Point={x:incoming.x+outgoing.x,y:incoming.y+outgoing.y};
    if(vectorLength(sum)<=Number.EPSILON*64)throw new Error('连续 PATH 接近反向miter，无法证明有限材料');
    const tangent:Point=unitPoint(sum),cosine:number=tangent.x*incoming.x+tangent.y*incoming.y;
    if(!(cosine>Number.EPSILON*64)||!Number.isFinite(half/cosine))throw new Error('连续 PATH miter非有限');
    const side:number=turn>0?-1:1;
    rings.push(checkedRing([points[index],addScaledPoint(points[index],normalPoint(incoming),side*half),
      addScaledPoint(points[index],normalPoint(tangent),side*half/cosine),addScaledPoint(points[index],normalPoint(outgoing),side*half)],spend));
  }
  let error:number=0;
  if(type===1){
    const sectors:number=8,step:number=Math.PI/sectors,factor:number=1/Math.cos(step/2);
    error=half*(factor-1);
    for(const endpoint of [0,points.length-1]){
      const direction:Point=endpoint===0?directions[0]:directions[directions.length-1];
      const n:Point=normalPoint(direction),first:Point=endpoint===0?{x:-n.x,y:-n.y}:n;
      const center:Point=points[endpoint],ring:Point[]=[addScaledPoint(center,first,half)];
      for(let at:number=0;at<sectors;at++){
        spend();const angle:number=(at+.5)*step,cosine:number=Math.cos(angle),sine:number=Math.sin(angle);
        ring.push(addScaledPoint(center,{x:cosine*first.x+sine*first.y,y:-sine*first.x+cosine*first.y},half*factor));
      }
      ring.push(addScaledPoint(center,first,-half));
      rings.push(checkedRing(ring,spend));
    }
  }
  return {rings:rings,errorNm:error,minimumLegNm:minimumLeg};
}
function compose(a: Mat2D, b: Mat2D): Mat2D {
  return { a: a.a*b.a+a.b*b.c, b: a.a*b.b+a.b*b.d, c: a.c*b.a+a.d*b.c, d: a.c*b.b+a.d*b.d,
    tx: a.a*b.tx+a.b*b.ty+a.tx, ty: a.c*b.tx+a.d*b.ty+a.ty };
}
function project(m: Mat2D, x: number, y: number): Point { return { x: m.a*x+m.b*y+m.tx, y: m.c*x+m.d*y+m.ty }; }
function checkedBudget(value: number | undefined, fallback: number, maximum: number): number {
  const count: number = value ?? fallback;
  if (!Number.isSafeInteger(count) || count < 1 || count > maximum) throw new Error('布线障碍预算无效');
  return count;
}
export function routeOccurrenceKey(rootKey: string, path: InstancePathStep[]): string {
  return `${rootKey}|${path.map((p: InstancePathStep): string => `${p.instanceId}[${p.row},${p.col}]`).join('/')}`;
}
export function routeEndpointOwnerKey(endpoint: PortEndpoint): string { return routeOccurrenceKey(endpoint.rootCellKey, endpoint.path); }

/** Complete routing material traversal. Display caps/representative members never enter this API. */
export class RouteObstacleService {
  private region: RouteRegionProvider;
  constructor(region: RouteRegionProvider = shapeRegionAdapterService) { this.region = region; }
  collect(request: RouteObstacleRequest): RouteObstacleResult {
    const state: EditStructureState = request.structure;
    const count: number = state.cellNames.length, root: number = request.rootCellId;
    if (!Number.isInteger(root) || root < 0 || root >= count || (state.cellKeys ?? []).length !== count ||
      !Number.isFinite(request.dbuNm) || request.dbuNm <= 0 || !Array.isArray(request.layers) || !request.layers.length)
      throw new Error('布线障碍根、材料层或 DBU 无效');
    const bounds: RouteBounds = request.boundsNm;
    if (![bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].every((n: number): boolean => Number.isFinite(n)) ||
      bounds.minX >= bounds.maxX || bounds.minY >= bounds.maxY) throw new Error('布线障碍范围无效');
    const budget: RouteObstacleBudget = request.budget ?? {};
    const placementsMax: number = checkedBudget(budget.placements, 50000, 1000000);
    const polygonsMax: number = checkedBudget(budget.polygons, 100000, 1000000);
    const verticesMax: number = checkedBudget(budget.vertices, 1000000, 4000000);
    const workMax: number = checkedBudget(budget.work, 2000000, 10000000);
    const depthMax: number = checkedBudget(budget.depth, 32, 32);
    const layers: Set<string> = new Set<string>();
    for (const layer of request.layers) {
      if (!Number.isInteger(layer.layerNumber) || layer.layerNumber < 0 || layer.layerNumber > 32767 ||
        !Number.isInteger(layer.datatype) || layer.datatype < 0 || layer.datatype > 32767) throw new Error('布线材料层号无效');
      layers.add(`${layer.layerNumber}/${layer.datatype}`);
    }
    const byCell: Map<number, Shape[]> = new Map<number, Shape[]>();
    let work: number = 0, placements: number = 0, polygons: number = 0, vertices: number = 0, error: number = 0;
    const spend = (amount: number = 1): void => { work += amount; if (work > workMax) throw new Error('完整布线障碍遍历超过工作预算，未采用部分结果'); };
    const ids: Set<number> = new Set<number>();
    for (const shape of request.shapes) {
      spend(); const owner: number = shape.ownerCellId ?? state.topCellId;
      if (!Number.isSafeInteger(shape.id) || shape.id < 1 || ids.has(shape.id) || !Number.isInteger(owner) || owner < 0 || owner >= count)
        throw new Error('障碍对象身份或 owner 无效');
      ids.add(shape.id); const group: Shape[] = byCell.get(owner) ?? []; group.push(shape); byCell.set(owner, group);
    }
    const colors: Map<number, number> = new Map<number, number>(), relevant: Map<number, boolean> = new Map<number, boolean>();
    const hasMaterial = (cell: number, depth: number): boolean => {
      spend(); if (depth > depthMax || colors.get(cell) === 1) throw new Error('布线障碍 Cell 循环或超过完整深度预算');
      if (colors.get(cell) === 2) return relevant.get(cell) === true;
      colors.set(cell, 1); let found: boolean = false;
      for (const shape of byCell.get(cell) ?? []) {
        spend();
        if (shape.type === ShapeType.INSTANCE) {
          const child: number = shape.cellId ?? -1;
          if (!Number.isInteger(child) || child < 0 || child >= count) throw new Error('障碍引用缺少真实子 Cell');
          if (hasMaterial(child, depth+1)) found = true;
        } else if ([ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH].indexOf(shape.type) >= 0 &&
          layers.has(`${shape.layerNumber}/${shape.datatype}`)) found = true;
      }
      colors.set(cell, 2); relevant.set(cell, found); return found;
    };
    hasMaterial(root, 0);
    const output: RouteObstacle[] = [];
    const walk = (cell: number, matrix: Mat2D, path: InstancePathStep[]): void => {
      spend(); if (path.length > depthMax) throw new Error('完整障碍层级超过深度预算');
      for (const shape of byCell.get(cell) ?? []) {
        spend();
        if (shape.type === ShapeType.INSTANCE) {
          const child: number = shape.cellId ?? -1; if (!relevant.get(child)) continue;
          const rawRows: number = shape.arrayRows ?? 0, rawCols: number = shape.arrayCols ?? 0;
          // GDS SREF and independently extracted AREF members retain explicit zero array dimensions.
          if (!Number.isSafeInteger(rawRows) || !Number.isSafeInteger(rawCols) || rawRows < 0 || rawCols < 0)
            throw new Error('障碍阵列行列无效');
          const rows: number = Math.max(1, rawRows), cols: number = Math.max(1, rawCols);
          if (!Number.isSafeInteger(rows*cols) || rows*cols > placementsMax-placements)
            throw new Error('完整布线阵列材料超过 placement 预算，未使用代表成员');
          if (shape.magnification !== undefined && (!Number.isFinite(shape.magnification) || shape.magnification <= 0))
            throw new Error('障碍实例 MAG 无效');
          if (!shape.points.length || ![shape.points[0].x, shape.points[0].y, shape.rotation ?? 0,
            shape.arrayColStepX ?? 0, shape.arrayColStepY ?? 0, shape.arrayRowStepX ?? 0, shape.arrayRowStepY ?? 0]
            .every((n: number): boolean => Number.isFinite(n)) || [0, 1, 2].indexOf(shape.mirror ?? 0) < 0)
            throw new Error('障碍实例 frame 或阵列步长无效');
          const base: Mat2D = instanceTransformMat(shape);
          for (let row: number = 0; row < rows; row++) for (let col: number = 0; col < cols; col++) {
            spend(); placements++;
            const member: Mat2D = { a: base.a, b: base.b, c: base.c, d: base.d,
              tx: base.tx+col*(shape.arrayColStepX ?? 0)+row*(shape.arrayRowStepX ?? 0),
              ty: base.ty+col*(shape.arrayColStepY ?? 0)+row*(shape.arrayRowStepY ?? 0) };
            const next: Mat2D = compose(matrix, member);
            if (![next.a,next.b,next.c,next.d,next.tx,next.ty].every((n: number): boolean => Number.isFinite(n)))
              throw new Error('障碍实例世界坐标非有限');
            const step: InstancePathStep = { instanceId: shape.id, parentCellId: cell, cellId: child, row: row, col: col,
              transform: { a: next.a, b: next.b, c: next.c, d: next.d, tx: next.tx, ty: next.ty } };
            walk(child, next, path.concat([step]));
          }
          continue;
        }
        if ([ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH].indexOf(shape.type) < 0 ||
          !layers.has(`${shape.layerNumber}/${shape.datatype}`)) continue;
        const scale: number = Math.sqrt(Math.abs(matrix.a*matrix.d-matrix.b*matrix.c));
        if (!Number.isFinite(scale) || scale <= 0) throw new Error('障碍世界 frame 无效');
        const material: ContinuousMaterial = shape.type===ShapeType.PATH?continuousPath(shape,scale,spend):continuousArea(shape,spend);
        if (shape.type===ShapeType.PATH) {
          // The actual adapter still checks the real PATH parameters/availability.
          // Its integer union is secondary evidence, never our coverage source.
          const effectiveWidth:number=shape.pathWidthAbsolute===true?(shape.pathWidth??0)/scale:(shape.pathWidth??0);
          const minimumLeg:number=material.minimumLegNm??0;
          const localGrid:number=Math.min(request.dbuNm/scale/64,effectiveWidth/64,minimumLeg/64);
          if(!(localGrid>0)||!Number.isFinite(localGrid))throw new Error('PATH 独立材料核对网格非有限');
          const region:ShapeRegionResult=this.region.shape(shape,localGrid,scale);
          if(!region.ok||!region.polygons.length)throw new Error(`完整障碍 #${shape.id} 未取得实际 PATH 核对材料：${region.message}`);
          const declared:number=region.roundCapErrorNm??0;
          if(!Number.isFinite(declared)||declared<0)throw new Error('障碍轮廓误差界无效');
          let providerVertices:number=0;
          for(const flat of region.polygons){
            spend(flat.length/2);providerVertices+=flat.length/2;
            if(flat.length<6||flat.length%2!==0||!flat.every((n:number):boolean=>Number.isFinite(n))||providerVertices>verticesMax||region.polygons.length>polygonsMax)
              throw new Error('独立 PATH 核对轮廓无效或超过预算');
          }
        }
        error = Math.max(error,material.errorNm*scale);
        for (let part: number = 0; part < material.rings.length; part++) {
          const ring:Point[]=material.rings[part];spend(ring.length);
          if (++polygons > polygonsMax || (vertices += ring.length) > verticesMax) throw new Error('完整障碍材料/点预算不足');
          const points: Point[] = [];
          for (const point of ring) {
            const p: Point = project(matrix,point.x,point.y);
            if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) throw new Error('实际障碍投影非有限'); points.push(p);
          }
          // A finite translated double can still collapse a thin edge. Reject
          // unprovable world topology rather than dropping continuous material.
          const worldRing:Point[]=checkedRing(points,spend);
          if(worldRing.length!==points.length)throw new Error('世界障碍投影丢失真实顶点');
          const key: string = routeOccurrenceKey((state.cellKeys ?? [])[root],path);
          output.push({ key: `${key}#${shape.id}:${part}`, pointsNm: worldRing, kind: 'polygon',
            layerNumber: shape.layerNumber, datatype: shape.datatype });
        }
      }
    };
    walk(root,{ a:1,b:0,c:0,d:1,tx:0,ty:0 },[]);
    return { obstacles:output, maximumApproximationErrorNm:error, placements:placements, polygons:polygons, vertices:vertices, work:work };
  }
}
export const routeObstacleService: RouteObstacleService = new RouteObstacleService();
