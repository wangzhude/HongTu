import type { Shape, Point } from '../models/GdsiiData';
import { parsePhysicalLayerStack, parseStackExpression, serializePhysicalLayerStack } from '../models/PhysicalLayerStack';
import type { PhysicalLayerStack, PhysicalLayerLevel, PhysicalStackParseResult, StackLayerPair, StackBooleanOp, StackExpression, PhysicalProcessStep } from '../models/PhysicalLayerStack';
import type { BooleanOpType } from '../../cpp/types/libhongtu/Index';
import type { EditStructureState } from './EditService';
import { routeObstacleService } from './RouteObstacleService';
import type { RouteObstacleRequest, RouteObstacleResult, RouteObstacleBudget } from './RouteObstacleService';
import type { RouteLayerPair, RouteBounds } from './RoutePlannerService';
import { nativeHongTuService } from './NativeHongTuService';

export interface LayerStackBounds { minX:number;minY:number;maxX:number;maxY:number; }
export interface LayerStackSectionLine { startNm:Point;endNm:Point; }
export interface LayerStackBudget {
  maxLevels?:number;maxSourcePolygons?:number;maxVertices?:number;
  maxSlabs?:number;maxTriangles?:number;maxWork?:number;maxPlacements?:number;maxDepth?:number;
}
export interface LayerStackRequest {
  stack:PhysicalLayerStack;shapes:Shape[];structure:EditStructureState;rootCellId:number;
  dbuNm:number;precisionNm:number;boundsNm:LayerStackBounds;
  /** Explicit source rounding policy. Collapsed/invalid material always fails. */
  coordinatePolicy:'strict'|'quantize';sectionLine?:LayerStackSectionLine;budget?:LayerStackBudget;
}
export interface LayerStackVertex { xNm:number;yNm:number;zNm:number; }
export interface LayerStackTriangle { a:number;b:number;c:number; }
export interface LayerStackMesh {
  levelId:string;materialId:string;layerNumber:number;datatype:number;
  vertices:LayerStackVertex[];triangles:LayerStackTriangle[];volumeNm3:number;
  /** Closed slab area includes both caps; adjacent slabs retain their internal interface caps. */
  surfaceAreaNm2:number;zminNm:number;zmaxNm:number;
}
export interface LayerStackSlice {
  levelId:string;materialId:string;layerNumber:number;datatype:number;zNm:number;polygonsNm:Point[][];areaNm2:number;
}
export interface LayerStackSectionPolygon { levelId:string;materialId:string;pointsNm:Point[];areaNm2:number; }
export interface LayerStackPreview {
  schema:string;stackJson:string;unit:'nm';precisionNm:number;sourceCoordinatePolicy:'strict'|'quantize';
  boundsNm:LayerStackBounds;sectionLine?:LayerStackSectionLine;rootCellId:number;dbuNm:number;
  meshes:LayerStackMesh[];slices:LayerStackSlice[];section:LayerStackSectionPolygon[];
  sectionLengthNm:number;totalVolumeNm3:number;sourcePolygons:number;placements:number;
  work:number;warnings:string[];
}
export interface LayerStackResult { ok:boolean;message:string;preview?:LayerStackPreview; }
export interface LayerStackRegionProvider { boolean(subject:Point[][],clip:Point[][],operation:StackBooleanOp,precisionNm:number):Point[][]; }
export interface LayerStackSourceProvider { collect(request:RouteObstacleRequest):RouteObstacleResult; }
export interface LayerStackDependencies { region?:LayerStackRegionProvider;sources?:LayerStackSourceProvider; }
interface GeometryContext { work:number;maximum:number;vertices:number;vertexMaximum:number;triangles:number;triangleMaximum:number;precision:number; }
interface LevelGeometry { level:PhysicalLayerLevel;loops:Point[][];scale:number; }
interface MaterialSlab { level:PhysicalLayerLevel;bottom:Point[][];top:Point[][];z0:number;z1:number; }

function fail(message:string):never{throw new Error(message);}
function spend(context:GeometryContext,amount:number=1):void{context.work+=amount;if(context.work>context.maximum)fail('物理层栈工作预算耗尽，未发布部分模型');}
function limit(value:number|undefined,fallback:number,maximum:number):number{const count:number=value??fallback;if(!Number.isSafeInteger(count)||count<1||count>maximum)fail('层栈预算无效');return count;}
function clonePoint(p:Point):Point{return{x:p.x,y:p.y};}
function same(a:Point,b:Point):boolean{return a.x===b.x&&a.y===b.y;}
function cross(a:Point,b:Point,c:Point):number{return(b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x);}
function area(ring:Point[]):number{let sum:number=0;for(let i:number=0;i<ring.length;i++){const b:Point=ring[(i+1)%ring.length];sum+=(ring[i].x-ring[0].x)*(b.y-ring[0].y)-(ring[i].y-ring[0].y)*(b.x-ring[0].x);}return sum/2;}
function on(p:Point,a:Point,b:Point,epsilon:number):boolean{return Math.abs(cross(a,b,p))<=epsilon*Math.max(1,Math.hypot(b.x-a.x,b.y-a.y))&&p.x>=Math.min(a.x,b.x)-epsilon&&p.x<=Math.max(a.x,b.x)+epsilon&&p.y>=Math.min(a.y,b.y)-epsilon&&p.y<=Math.max(a.y,b.y)+epsilon;}
function intersects(a:Point,b:Point,c:Point,d:Point,epsilon:number):boolean{
  if(Math.max(a.x,b.x)+epsilon<Math.min(c.x,d.x)||Math.max(c.x,d.x)+epsilon<Math.min(a.x,b.x)||Math.max(a.y,b.y)+epsilon<Math.min(c.y,d.y)||Math.max(c.y,d.y)+epsilon<Math.min(a.y,b.y))return false;
  const x:number=cross(a,b,c),y:number=cross(a,b,d),z:number=cross(c,d,a),w:number=cross(c,d,b);
  if(![x,y,z,w].every((v:number):boolean=>Number.isFinite(v)))fail('层栈几何方向溢出');
  return Math.min(x,y)<=epsilon&&Math.max(x,y)>=-epsilon&&Math.min(z,w)<=epsilon&&Math.max(z,w)>=-epsilon;
}
function inside(point:Point,ring:Point[],epsilon:number):boolean{let result:boolean=false;for(let i:number=0,j:number=ring.length-1;i<ring.length;j=i++){const a:Point=ring[j],b:Point=ring[i];if(on(point,a,b,epsilon))return true;if((a.y>point.y)!==(b.y>point.y)&&point.x<(b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x)result=!result;}return result;}
function checked(ring:Point[],context:GeometryContext):Point[]{
  if(!Array.isArray(ring)||ring.length<3)fail('层栈材料缺少完整polygon');spend(context,ring.length);
  if(ring.some((p:Point,i:number):boolean=>p===null||!Number.isFinite(p.x)||!Number.isFinite(p.y)||Math.abs(p.x/context.precision)>1e14||Math.abs(p.y/context.precision)>1e14||same(p,ring[(i+1)%ring.length])))fail('层栈材料无效/坍缩/超出坐标精度范围');
  const size:number=area(ring);if(!Number.isFinite(size)||size===0)fail('层栈材料零面积或溢出');
  for(let a:number=0;a<ring.length;a++)for(let b:number=a+1;b<ring.length;b++){if(b===a+1||(a===0&&b===ring.length-1))continue;spend(context);if(intersects(ring[a],ring[(a+1)%ring.length],ring[b],ring[(b+1)%ring.length],0))fail('层栈连续材料自交/自触，不能发布损坏模型');}
  return ring.map((p:Point):Point=>clonePoint(p));
}
function encode(rings:Point[][]):number[][]{return rings.map((ring:Point[]):number[]=>{const flat:number[]=[];for(const point of ring)flat.push(point.x,point.y);return flat;});}
function pointKey(point:Point):string{return `${point.x},${point.y}`;}
function simplified(input:Point[]):Point[]{const ring:Point[]=input.map((p:Point):Point=>clonePoint(p));let change:boolean=true;while(change&&ring.length>3){change=false;for(let i:number=0;i<ring.length;i++){const a:Point=ring[(i+ring.length-1)%ring.length],b:Point=ring[i],c:Point=ring[(i+1)%ring.length];if(cross(a,b,c)===0&&on(b,a,c,0)){ring.splice(i,1);change=true;break;}}}return ring;}
/** Recover true outer/hole boundaries from disjoint native filled pieces.
 * Split T junctions before canceling reversed internal edges. */
function boundaries(pieces:Point[][],context:GeometryContext):Point[][]{
  const all:Map<string,Point>=new Map<string,Point>();for(const ring of pieces)for(const point of ring)all.set(pointKey(point),point);
  const points:Point[]=Array.from(all.values()),edges:Map<string,Point[]>=new Map<string,Point[]>();
  for(const original of pieces){const ring:Point[]=area(original)>0?original:original.slice().reverse();for(let at:number=0;at<ring.length;at++){
    const a:Point=ring[at],b:Point=ring[(at+1)%ring.length],dx:number=b.x-a.x,dy:number=b.y-a.y,squared:number=dx*dx+dy*dy;
    const cuts:Point[]=[];for(const p of points){spend(context);if(on(p,a,b,0))cuts.push(p);}cuts.sort((p:Point,q:Point):number=>((p.x-a.x)*dx+(p.y-a.y)*dy-(q.x-a.x)*dx-(q.y-a.y)*dy)/squared);
    for(let i:number=1;i<cuts.length;i++){const first:Point=cuts[i-1],second:Point=cuts[i],key:string=`${pointKey(first)}|${pointKey(second)}`,reverse:string=`${pointKey(second)}|${pointKey(first)}`;
      if(edges.has(reverse))edges.delete(reverse);else{if(edges.has(key))fail('层栈区域分解重叠，未取得真实材料边界');edges.set(key,[first,second]);}}
  }}
  const outgoing:Map<string,Point>=new Map<string,Point>(),incoming:Set<string>=new Set<string>();
  for(const edge of edges.values()){const key:string=pointKey(edge[0]);if(outgoing.has(key)||incoming.has(pointKey(edge[1])))fail('层栈区域触点拓扑不唯一，须先分开材料');outgoing.set(key,edge[1]);incoming.add(pointKey(edge[1]));}
  const loops:Point[][]=[];while(outgoing.size>0){const first:string=Array.from(outgoing.keys())[0];let key:string=first;const loop:Point[]=[];
    do{spend(context);const next:Point|undefined=outgoing.get(key),point:Point|undefined=all.get(key);if(next===undefined||point===undefined)fail('层栈边界不闭合');loop.push(clonePoint(point as Point));outgoing.delete(key);key=pointKey(next as Point);}while(key!==first);
    loops.push(checked(simplified(loop),context));
  }return loops;
}
function offsetLoops(loops:Point[][],delta:number,context:GeometryContext):Point[][]{
  if(delta===0)return loops.map((ring:Point[]):Point[]=>ring.map((p:Point):Point=>clonePoint(p)));
  return loops.map((ring:Point[]):Point[]=>{const result:Point[]=[];for(let at:number=0;at<ring.length;at++){
    spend(context);const a:Point=ring[(at+ring.length-1)%ring.length],b:Point=ring[at],c:Point=ring[(at+1)%ring.length],one:number=Math.hypot(b.x-a.x,b.y-a.y),two:number=Math.hypot(c.x-b.x,c.y-b.y);
    const nx:number=(b.y-a.y)/one,ny:number=-(b.x-a.x)/one,mx:number=(c.y-b.y)/two,my:number=-(c.x-b.x)/two,divisor:number=1+nx*mx+ny*my;
    if(!(divisor>1e-10))fail('层栈侧壁miter接近反向，不能生成有限体积');result.push({x:b.x+delta*(nx+mx)/divisor,y:b.y+delta*(ny+my)/divisor});
  }return checked(result,context);});
}
function bias(level:PhysicalLayerLevel,z:number,scale:number):number{
  const fraction:number=(z-level.zmin*scale)/(level.thickness*scale);
  if(level.zToBias!==undefined){const rows=level.zToBias;for(let at:number=1;at<rows.length;at++)if(fraction<=rows[at].fraction+1e-12){const low=rows[at-1],high=rows[at],t:number=(fraction-low.fraction)/(high.fraction-low.fraction);return(level.bias+low.bias+(high.bias-low.bias)*t)*scale;}return(level.bias+rows[rows.length-1].bias)*scale;}
  return level.bias*scale+(level.widthToZ-fraction)*level.thickness*scale*Math.tan(level.sidewallAngleDeg*Math.PI/180);
}
function matched(bottom:Point[][],top:Point[][],context:GeometryContext):Point[][]{
  if(bottom.length!==top.length)fail('层栈z间拓扑改变，不能闭合loft；缩小工艺高度区间或改变precision');
  const used:Set<number>=new Set<number>(),result:Point[][]=[];
  for(const lower of bottom){let best:number=Infinity,chosen:number=-1,rotation:number=0;
    for(let at:number=0;at<top.length;at++){const upper:Point[]=top[at];if(used.has(at)||upper.length!==lower.length||area(lower)*area(upper)<=0)continue;
      for(let offset:number=0;offset<upper.length;offset++){let distance:number=0;for(let i:number=0;i<lower.length;i++){spend(context);const p:Point=upper[(i+offset)%upper.length];distance+=(p.x-lower[i].x)**2+(p.y-lower[i].y)**2;}if(distance<best){best=distance;chosen=at;rotation=offset;}}
    }if(chosen<0)fail('层栈边界顶点对应改变，未发布部分侧壁');used.add(chosen);result.push(top[chosen].map((p:Point,i:number):Point=>clonePoint(top[chosen][(i+rotation)%top[chosen].length])));
  }return result;
}
function interpolated(a:Point,b:Point,t:number):Point{return{x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t};}
function polynomialRoots(first:number,middle:number,last:number):number[]{
  const quadratic:number=2*(last+first-2*middle),linear:number=last-first-quadratic,constant:number=first,tolerance:number=Math.max(1,Math.abs(first),Math.abs(middle),Math.abs(last))*Number.EPSILON*128;
  if(![quadratic,linear,constant].every((n:number):boolean=>Number.isFinite(n)))fail('层栈连续z拓扑证书数值溢出');
  if(Math.abs(quadratic)<=tolerance)return Math.abs(linear)<=tolerance?[]:[-constant/linear];
  const discriminant:number=linear*linear-4*quadratic*constant;if(discriminant<0)return[];const root:number=Math.sqrt(discriminant);return[(-linear-root)/(2*quadratic),(-linear+root)/(2*quadratic)];
}
/** Every offset edge direction is constant within a profile interval. Boundary
 * arrangement can change only at its quadratic orientation/linear contact
 * events. Check these events and the open intervals, including hidden masks. */
function eventParameters(bottom:Point[][],top:Point[][],context:GeometryContext):number[]{
  if(bottom.length!==top.length||bottom.some((ring:Point[],index:number):boolean=>ring.length!==top[index].length))fail('连续z输入边界没有完整对应');
  const result:Set<number>=new Set<number>([0,.5,1]),first:Point[][]=[],last:Point[][]=[];
  for(let loop:number=0;loop<bottom.length;loop++)for(let at:number=0;at<bottom[loop].length;at++){first.push([bottom[loop][at],bottom[loop][(at+1)%bottom[loop].length]]);last.push([top[loop][at],top[loop][(at+1)%top[loop].length]]);}
  const add=(t:number):void=>{if(Number.isFinite(t)&&t>1e-9&&t<1-1e-9)result.add(t);};
  for(let one:number=0;one<first.length;one++)for(let two:number=one+1;two<first.length;two++){
    spend(context);for(const order of [[0,1,2],[0,1,3],[2,3,0],[2,3,1]]){const a:Point[]=first[one].concat(first[two]),b:Point[]=last[one].concat(last[two]),values:number[]=[0,.5,1].map((t:number):number=>cross(interpolated(a[order[0]],b[order[0]],t),interpolated(a[order[1]],b[order[1]],t),interpolated(a[order[2]],b[order[2]],t)));for(const root of polynomialRoots(values[0],values[1],values[2]))add(root);}
    for(const a of [0,1])for(const b of [0,1])for(const coordinate of [true,false]){const initial:number=coordinate?first[one][a].x-first[two][b].x:first[one][a].y-first[two][b].y,final:number=coordinate?last[one][a].x-last[two][b].x:last[one][a].y-last[two][b].y;if(final!==initial)add(-initial/(final-initial));}
  }
  const sorted:number[]=Array.from(result).sort((a:number,b:number):number=>a-b),complete:Set<number>=new Set<number>(sorted);for(let at:number=1;at<sorted.length;at++)complete.add(sorted[at-1]/2+sorted[at]/2);return Array.from(complete).sort((a:number,b:number):number=>a-b);
}
function certifyLoft(bottom:Point[][],top:Point[][],context:GeometryContext):void{
  const parameters:number[]=eventParameters(bottom,top,context);
  for(const t of parameters){const loops:Point[][]=bottom.map((ring:Point[],loop:number):Point[]=>checked(ring.map((p:Point,at:number):Point=>interpolated(p,top[loop][at],t)),context));
    for(let one:number=0;one<loops.length;one++)for(let two:number=one+1;two<loops.length;two++)for(let a:number=0;a<loops[one].length;a++)for(let b:number=0;b<loops[two].length;b++){spend(context);if(intersects(loops[one][a],loops[one][(a+1)%loops[one].length],loops[two][b],loops[two][(b+1)%loops[two].length],context.precision*context.precision*1e-10))fail('侧壁连续z区间出现接触/交叉，不能发布自交volume');}
  }
}
/** Ear clipping of a simple native filled piece; holes have already been
 * fractured by the actual region provider. No fan triangulation of concavity. */
function triangulated(input:Point[],context:GeometryContext):number[][]{
  const ring:Point[]=input,active:number[]=[],triangles:number[][]=[];
  for(let index:number=0;index<ring.length;index++)active.push(index);
  const sign:number=area(ring)>0?1:-1;let iterations:number=0;
  while(active.length>3){let found:boolean=false;for(let at:number=0;at<active.length;at++){
    spend(context);if(++iterations>ring.length*ring.length*2)fail('层栈三角剖分未收敛');const a:number=active[(at+active.length-1)%active.length],b:number=active[at],c:number=active[(at+1)%active.length];
    if(sign*cross(ring[a],ring[b],ring[c])<=0)continue;let occupied:boolean=false;
    for(const index of active){spend(context);if(index===a||index===b||index===c)continue;const p:Point=ring[index];if(sign*cross(ring[a],ring[b],p)>=0&&sign*cross(ring[b],ring[c],p)>=0&&sign*cross(ring[c],ring[a],p)>=0){occupied=true;break;}}
    if(occupied)continue;triangles.push(sign>0?[a,b,c]:[c,b,a]);active.splice(at,1);found=true;break;
  }if(!found)fail('层栈真实材料不能完整三角剖分');}
  triangles.push(sign>0?[active[0],active[1],active[2]]:[active[2],active[1],active[0]]);return triangles;
}
function triangleArea(a:LayerStackVertex,b:LayerStackVertex,c:LayerStackVertex):number{
  const x:number=b.xNm-a.xNm,y:number=b.yNm-a.yNm,z:number=b.zNm-a.zNm,u:number=c.xNm-a.xNm,v:number=c.yNm-a.yNm,w:number=c.zNm-a.zNm;return Math.hypot(y*w-z*v,z*u-x*w,x*v-y*u)/2;
}
function conformed(mesh:LayerStackMesh,context:GeometryContext):void{
  const pending:LayerStackTriangle[]=mesh.triangles.slice(),result:LayerStackTriangle[]=[];
  while(pending.length>0){const triangle:LayerStackTriangle=pending.pop() as LayerStackTriangle,row:number[]=[triangle.a,triangle.b,triangle.c];let divided:boolean=false;
    for(let edge:number=0;edge<3&&!divided;edge++){const first:number=row[edge],second:number=row[(edge+1)%3],opposite:number=row[(edge+2)%3],a:LayerStackVertex=mesh.vertices[first],b:LayerStackVertex=mesh.vertices[second],dx:number=b.xNm-a.xNm,dy:number=b.yNm-a.yNm,dz:number=b.zNm-a.zNm,squared:number=dx*dx+dy*dy+dz*dz,cuts:number[]=[];
      for(let at:number=0;at<mesh.vertices.length;at++){spend(context);if(at===first||at===second||at===opposite)continue;const p:LayerStackVertex=mesh.vertices[at],t:number=((p.xNm-a.xNm)*dx+(p.yNm-a.yNm)*dy+(p.zNm-a.zNm)*dz)/squared;
        if(t>1e-10&&t<1-1e-10&&Math.hypot(p.xNm-a.xNm-t*dx,p.yNm-a.yNm-t*dy,p.zNm-a.zNm-t*dz)<=context.precision*1e-8)cuts.push(at);}
      if(cuts.length>0){cuts.sort((one:number,two:number):number=>{const p:LayerStackVertex=mesh.vertices[one],q:LayerStackVertex=mesh.vertices[two];return(p.xNm-q.xNm)*dx+(p.yNm-q.yNm)*dy+(p.zNm-q.zNm)*dz;});const path:number[]=[first].concat(cuts,[second]);for(let at:number=1;at<path.length;at++)pending.push({a:path[at-1],b:path[at],c:opposite});divided=true;}
    }
    if(!divided){if(!(triangleArea(mesh.vertices[triangle.a],mesh.vertices[triangle.b],mesh.vertices[triangle.c])>0))fail('三维材料triangle退化');result.push(triangle);}
    if(pending.length+result.length>context.triangleMaximum)fail('层栈完整triangle预算不足');
  }mesh.triangles=result;
  const edges:Map<string,number>=new Map<string,number>(),edgeCounts:Map<string,number>=new Map<string,number>();for(const triangle of result){const row:number[]=[triangle.a,triangle.b,triangle.c];for(let at:number=0;at<3;at++){const a:number=row[at],b:number=row[(at+1)%3],key:string=a<b?`${a}/${b}`:`${b}/${a}`;edges.set(key,(edges.get(key)??0)+(a<b?1:-1));edgeCounts.set(key,(edgeCounts.get(key)??0)+1);}}
  if(Array.from(edges.values()).some((count:number):boolean=>count!==0)||Array.from(edgeCounts.values()).some((count:number):boolean=>count!==2))fail('三维网格未闭合或非manifold，未发布部分volume');
  const reference:LayerStackVertex=mesh.vertices[0];let volume:number=0,surface:number=0;
  for(const triangle of result){spend(context);const a:LayerStackVertex=mesh.vertices[triangle.a],b:LayerStackVertex=mesh.vertices[triangle.b],c:LayerStackVertex=mesh.vertices[triangle.c],ax:number=a.xNm-reference.xNm,ay:number=a.yNm-reference.yNm,az:number=a.zNm-reference.zNm,bx:number=b.xNm-reference.xNm,by:number=b.yNm-reference.yNm,bz:number=b.zNm-reference.zNm,cx:number=c.xNm-reference.xNm,cy:number=c.yNm-reference.yNm,cz:number=c.zNm-reference.zNm;
    volume+=(ax*(by*cz-bz*cy)+ay*(bz*cx-bx*cz)+az*(bx*cy-by*cx))/6;surface+=triangleArea(a,b,c);
  }if(!(volume>0)||!Number.isFinite(volume)||!Number.isFinite(surface))fail('层栈三维体积非正或数值溢出');mesh.volumeNm3=volume;mesh.surfaceAreaNm2=surface;
  context.vertices+=mesh.vertices.length;context.triangles+=mesh.triangles.length;if(context.vertices>context.vertexMaximum||context.triangles>context.triangleMaximum)fail('完整三维材料vertex/triangle预算不足');
}
function sectionMesh(mesh:LayerStackMesh,line:LayerStackSectionLine,context:GeometryContext):LayerStackSectionPolygon[]{
  const length:number=Math.hypot(line.endNm.x-line.startNm.x,line.endNm.y-line.startNm.y);if(!(length>0)||!Number.isFinite(length))fail('物理截线须为真实非退化有限线段');
  const ux:number=(line.endNm.x-line.startNm.x)/length,uy:number=(line.endNm.y-line.startNm.y)/length,tolerance:number=context.precision*1e-8;
  const points:Map<string,Point>=new Map<string,Point>(),edges:Map<string,Point[]>=new Map<string,Point[]>(),counts:Map<string,number>=new Map<string,number>(),ordinary:Set<string>=new Set<string>();
  const key=(p:Point):string=>`${Math.round(p.x/tolerance)},${Math.round(p.y/tolerance)}`;
  const add=(a:Point,b:Point,coplanar:boolean):void=>{if(Math.hypot(a.x-b.x,a.y-b.y)<=tolerance)return;const first:string=key(a),second:string=key(b),edge:string=first<second?`${first}|${second}`:`${second}|${first}`;points.set(first,a);points.set(second,b);edges.set(edge,[a,b]);counts.set(edge,(counts.get(edge)??0)+1);if(!coplanar)ordinary.add(edge);};
  const projected=(p:LayerStackVertex):Point=>({x:(p.xNm-line.startNm.x)*ux+(p.yNm-line.startNm.y)*uy,y:p.zNm});
  for(const triangle of mesh.triangles){spend(context);const row:LayerStackVertex[]=[mesh.vertices[triangle.a],mesh.vertices[triangle.b],mesh.vertices[triangle.c]],dist:number[]=row.map((p:LayerStackVertex):number=>-(p.xNm-line.startNm.x)*uy+(p.yNm-line.startNm.y)*ux),hits:Point[]=[];
    if(dist.every((v:number):boolean=>Math.abs(v)<=tolerance)){for(let at:number=0;at<3;at++)add(projected(row[at]),projected(row[(at+1)%3]),true);continue;}
    for(let at:number=0;at<3;at++){const next:number=(at+1)%3;if(Math.abs(dist[at])<=tolerance)hits.push(projected(row[at]));if(dist[at]*dist[next]<0){const t:number=dist[at]/(dist[at]-dist[next]);hits.push(projected({xNm:row[at].xNm+(row[next].xNm-row[at].xNm)*t,yNm:row[at].yNm+(row[next].yNm-row[at].yNm)*t,zNm:row[at].zNm+(row[next].zNm-row[at].zNm)*t}));}}
    const unique:Point[]=Array.from(new Map<string,Point>(hits.map((p:Point):[string,Point]=>[key(p),p])).values());if(unique.length===2)add(unique[0],unique[1],false);else if(unique.length>2)fail('截面triangle交点不唯一');
  }
  const adjacency:Map<string,string[]>=new Map<string,string[]>();for(const edge of edges.keys()){const row:Point[]=edges.get(edge) as Point[];if((counts.get(edge)??0)>1&&!ordinary.has(edge))continue;const a:string=key(row[0]),b:string=key(row[1]);adjacency.set(a,(adjacency.get(a)??[]).concat([b]));adjacency.set(b,(adjacency.get(b)??[]).concat([a]));}
  const visited:Set<string>=new Set<string>(),result:LayerStackSectionPolygon[]=[];
  for(const first of adjacency.keys()){if(visited.has(first))continue;let previous:string='',current:string=first;const ring:Point[]=[];
    do{spend(context);const next:string[]=adjacency.get(current)??[];if(next.length!==2)fail('物理截面触点/拓扑不闭合，未发布部分剖面');visited.add(current);ring.push(clonePoint(points.get(current) as Point));const following:string=next[0]===previous?next[1]:next[0];previous=current;current=following;}while(current!==first);
    let clipped:Point[]=simplified(ring);for(const end of [false,true]){const output:Point[]=[];for(let at:number=0;at<clipped.length;at++){const a:Point=clipped[at],b:Point=clipped[(at+1)%clipped.length],aIn:boolean=end?a.x<=length:a.x>=0,bIn:boolean=end?b.x<=length:b.x>=0;if(aIn)output.push(a);if(aIn!==bIn){const x:number=end?length:0,t:number=(x-a.x)/(b.x-a.x);output.push({x:x,y:a.y+(b.y-a.y)*t});}}clipped=output;}
    if(clipped.length>=3&&Math.abs(area(clipped))>tolerance*tolerance){clipped=checked(simplified(clipped),context);result.push({levelId:mesh.levelId,materialId:mesh.materialId,pointsNm:clipped,areaNm2:Math.abs(area(clipped))});}
  }return result;
}
class NativeLayerStackRegionProvider implements LayerStackRegionProvider {
  boolean(subject:Point[][],clip:Point[][],operation:StackBooleanOp,precisionNm:number):Point[][]{
    const kind:BooleanOpType=operation==='intersection'?0:operation==='union'?1:operation==='difference'?2:3;
    const result=nativeHongTuService.regionBooleanForEdit(encode(subject),encode(clip),kind,precisionNm);
    if(!result.success)fail(`层栈真实区域布尔失败：${result.errorMessage}`);
    return result.polygons.map((flat:number[]):Point[]=>{if(flat.length<6||flat.length%2!==0)fail('层栈区域内核返回不完整轮廓');const ring:Point[]=[];for(let i:number=0;i<flat.length;i+=2)ring.push({x:flat[i],y:flat[i+1]});return ring;});
  }
}

/** Complete, bounded fabrication geometry. Preview never edits layout/ports.
 * The explicit XY precision defines the piecewise-linear physical model;
 * exported volume/section are measured from that closed model, not estimates. */
export class LayerStackService {
  private region:LayerStackRegionProvider;private sources:LayerStackSourceProvider;
  constructor(dependencies:LayerStackDependencies={}){this.region=dependencies.region??new NativeLayerStackRegionProvider();this.sources=dependencies.sources??routeObstacleService;}
  parse(json:string,bindings?:StackLayerPair[]):PhysicalStackParseResult{return parsePhysicalLayerStack(json,bindings);}
  serialize(stack:PhysicalLayerStack):string{return serializePhysicalLayerStack(stack);}
  private operation(a:Point[][],b:Point[][],kind:StackBooleanOp,context:GeometryContext):Point[][]{
    spend(context,a.reduce((sum:number,ring:Point[]):number=>sum+ring.length,0)+b.reduce((sum:number,ring:Point[]):number=>sum+ring.length,0)+1);
    const result:Point[][]=this.region.boolean(a,b,kind,context.precision);if(!Array.isArray(result)||result.length>40000)fail('层栈区域数量超预算');let count:number=0;
    return result.map((ring:Point[]):Point[]=>{count+=ring.length;if(count>context.vertexMaximum)fail('层栈区域完整顶点超预算');const checkedRing:Point[]=checked(ring,context);for(const p of checkedRing){const x:number=p.x/context.precision,y:number=p.y/context.precision;if(Math.abs(x-Math.round(x))>1e-6||Math.abs(y-Math.round(y))>1e-6)fail('区域内核返回未落在物理precision网格的材料');}return checkedRing;});
  }
  private filled(loops:Point[][],context:GeometryContext):Point[][]{
    const outers:Point[][]=loops.filter((ring:Point[]):boolean=>area(ring)>0),holes:Point[][]=loops.filter((ring:Point[]):boolean=>area(ring)<0);let result:Point[][]=[];
    for(const hole of holes)if(!outers.some((ring:Point[]):boolean=>inside(hole[0],ring,0)))fail('侧壁孔洞越出外轮廓，模型拓扑改变');
    for(const outer of outers){const inner:Point[][]=holes.filter((ring:Point[]):boolean=>inside(ring[0],outer,0));const piece:Point[][]=this.operation([outer],inner,'difference',context);result=this.operation(result,piece,'union',context);}return result;
  }
  private expression(expression:string,sources:Map<string,Point[][]>,context:GeometryContext):Point[][]{
    const parsed:StackExpression=parseStackExpression(expression),stack:Point[][][]=[];
    for(const instruction of parsed.instructions){spend(context);if(instruction.operation===undefined)stack.push(sources.get(instruction.pairKey)??[]);else{const b:Point[][]|undefined=stack.pop(),a:Point[][]|undefined=stack.pop();if(a===undefined||b===undefined)fail('派生物理层缺少源材料');stack.push(this.operation(a as Point[][],b as Point[][],instruction.operation,context));}}
    if(stack.length!==1)fail('派生物理层表达式未完整执行');return this.operation(stack[0],[],'union',context);
  }
  private at(geometries:LevelGeometry[],sources:Map<string,Point[][]>,steps:PhysicalProcessStep[],z:number,active:number,scale:number,domain:Point[][],context:GeometryContext):Map<string,Point[][]>{
    const resolved:Map<string,Point[][]>=new Map<string,Point[][]>();let occupied:Point[][]=[];
    for(const geometry of geometries){const level:PhysicalLayerLevel=geometry.level;let pieces:Point[][]=[];
      if(active>=level.zmin*scale&&active<(level.zmin+level.thickness)*scale)pieces=this.filled(offsetLoops(geometry.loops,bias(level,z,scale),context),context);
      for(const step of steps)if(step.targetLevelIds.includes(level.id)&&active>=step.zmin*scale&&active<(step.zmin+step.thickness)*scale){const mask:Point[][]=this.expression(step.sourceExpression,sources,context);pieces=this.operation(pieces,mask,step.kind==='grow'?'union':'difference',context);}
      pieces=this.operation(pieces,domain,'intersection',context);pieces=this.operation(pieces,occupied,'difference',context);resolved.set(level.id,pieces);occupied=this.operation(occupied,pieces,'union',context);
    }return resolved;
  }
  private mesh(slab:MaterialSlab,context:GeometryContext):LayerStackMesh{
    const mesh:LayerStackMesh={levelId:slab.level.id,materialId:slab.level.materialId,layerNumber:slab.level.layerNumber,datatype:slab.level.datatype,vertices:[],triangles:[],volumeNm3:0,surfaceAreaNm2:0,zminNm:slab.z0,zmaxNm:slab.z1},indices:Map<string,number>=new Map<string,number>();
    const vertex=(point:Point,z:number):number=>{const key:string=`${point.x},${point.y},${z}`,known:number|undefined=indices.get(key);if(known!==undefined)return known;const index:number=mesh.vertices.length;mesh.vertices.push({xNm:point.x,yNm:point.y,zNm:z});indices.set(key,index);return index;};
    const bottomPieces:Point[][]=this.filled(slab.bottom,context),topPieces:Point[][]=this.filled(slab.top,context);
    for(const top of [false,true])for(const ring of top?topPieces:bottomPieces){const faces:number[][]=triangulated(simplified(ring),context),points:Point[]=simplified(ring),row:number[]=points.map((point:Point):number=>vertex(point,top?slab.z1:slab.z0));for(const face of faces)mesh.triangles.push(top?{a:row[face[0]],b:row[face[1]],c:row[face[2]]}:{a:row[face[2]],b:row[face[1]],c:row[face[0]]});}
    for(let loop:number=0;loop<slab.bottom.length;loop++){const a:Point[]=slab.bottom[loop],b:Point[]=slab.top[loop];for(let at:number=0;at<a.length;at++){const next:number=(at+1)%a.length,low:number=vertex(a[at],slab.z0),lowNext:number=vertex(a[next],slab.z0),high:number=vertex(b[at],slab.z1),highNext:number=vertex(b[next],slab.z1);mesh.triangles.push({a:low,b:lowNext,c:highNext},{a:low,b:highNext,c:high});}}
    conformed(mesh,context);return mesh;
  }
  build(request:LayerStackRequest):LayerStackResult{
    try{
      const parsed=parsePhysicalLayerStack(serializePhysicalLayerStack(request.stack));if(!parsed.ok||!parsed.executable||parsed.stack===undefined)fail(parsed.message||'未知层栈schema不能执行');const stack:PhysicalLayerStack=parsed.stack as PhysicalLayerStack,scale:number=stack.unit==='um'?1000:1;
      if(!Number.isFinite(request.dbuNm)||request.dbuNm<=0||!Number.isFinite(request.precisionNm)||request.precisionNm<=0||!['strict','quantize'].includes(request.coordinatePolicy))fail('真实DBU、precision或坐标政策无效');
      const b:LayerStackBounds=request.boundsNm;if(![b.minX,b.minY,b.maxX,b.maxY].every((n:number):boolean=>Number.isFinite(n))||b.minX>=b.maxX||b.minY>=b.maxY)fail('物理模型需要明确有限ROI');
      if(request.sectionLine!==undefined){const line:LayerStackSectionLine=request.sectionLine;if(![line.startNm.x,line.startNm.y,line.endNm.x,line.endNm.y].every((n:number):boolean=>Number.isFinite(n)&&Math.abs(n/request.precisionNm)<=1e14)||!(Math.hypot(line.endNm.x-line.startNm.x,line.endNm.y-line.startNm.y)>0))fail('物理截线须为precision范围内真实非退化有限线段');}
      const budget:LayerStackBudget=request.budget??{},context:GeometryContext={work:0,maximum:limit(budget.maxWork,4000000,20000000),vertices:0,vertexMaximum:limit(budget.maxVertices,400000,2000000),triangles:0,triangleMaximum:limit(budget.maxTriangles,200000,1000000),precision:request.precisionNm};
      if(stack.levels.length>limit(budget.maxLevels,256,256))fail('完整物理层数超过预算');const slabMaximum:number=limit(budget.maxSlabs,512,4096),sourceMaximum:number=limit(budget.maxSourcePolygons,40000,100000);
      const pairs:Map<string,StackLayerPair>=new Map<string,StackLayerPair>();for(const level of stack.levels)for(const expression of [level.sourceExpression].concat(level.backgroundExcludeExpressions??[]))for(const pair of parseStackExpression(expression).pairs)pairs.set(`${pair.layerNumber}/${pair.datatype}`,pair);
      for(const step of stack.processes)for(const pair of parseStackExpression(step.sourceExpression).pairs)pairs.set(`${pair.layerNumber}/${pair.datatype}`,pair);
      const sourceBudget:RouteObstacleBudget={placements:limit(budget.maxPlacements,50000,1000000),polygons:sourceMaximum,vertices:context.vertexMaximum,work:Math.min(context.maximum,10000000),depth:limit(budget.maxDepth,32,32)};
      const sourceLayers:RouteLayerPair[]=Array.from(pairs.values()).map((pair:StackLayerPair):RouteLayerPair=>({layerNumber:pair.layerNumber,datatype:pair.datatype}));
      const sourceBounds:RouteBounds={minX:b.minX,minY:b.minY,maxX:b.maxX,maxY:b.maxY};
      const sourceRequest:RouteObstacleRequest={shapes:request.shapes,structure:request.structure,rootCellId:request.rootCellId,layers:sourceLayers,dbuNm:request.dbuNm,boundsNm:sourceBounds,budget:sourceBudget};
      const collected:RouteObstacleResult=this.sources.collect(sourceRequest);
      if(collected.obstacles.length>sourceMaximum||!Number.isSafeInteger(collected.work)||collected.work<0||!Number.isSafeInteger(collected.placements)||collected.placements<0||!Number.isFinite(collected.maximumApproximationErrorNm)||collected.maximumApproximationErrorNm<0)fail('源实际材料不完整或误差/计数无效');spend(context,collected.work);
      const sourceMap:Map<string,Point[][]>=new Map<string,Point[][]>(),roi:Point[][]=[[{x:b.minX,y:b.minY},{x:b.maxX,y:b.minY},{x:b.maxX,y:b.maxY},{x:b.minX,y:b.maxY}]],warnings:string[]=[];
      for(const point of roi[0])if(Math.abs(point.x/context.precision-Math.round(point.x/context.precision))>1e-6||Math.abs(point.y/context.precision-Math.round(point.y/context.precision))>1e-6)fail('物理ROI边界须明确落在precision网格；调整边界或细化precision');
      for(const obstacle of collected.obstacles){if(obstacle.kind!=='polygon')fail('物理层源必须是完整真实painted材料');const ring:Point[]=checked(obstacle.pointsNm,context),rounded:Point[]=ring.map((p:Point):Point=>({x:Math.round(p.x/context.precision)*context.precision,y:Math.round(p.y/context.precision)*context.precision}));
        if(request.coordinatePolicy==='strict'&&ring.some((p:Point,at:number):boolean=>Math.hypot(p.x-rounded[at].x,p.y-rounded[at].y)>Math.max(context.precision*1e-8,Math.abs(p.x)*Number.EPSILON*8,Math.abs(p.y)*Number.EPSILON*8)))fail('严格物理source含off-grid连续坐标；显式选quantize或更细precision');
        checked(rounded,context);const key:string=`${obstacle.layerNumber}/${obstacle.datatype}`;sourceMap.set(key,(sourceMap.get(key)??[]).concat([rounded]));
      }
      // Preserve complete masks before bias: cropping first would create an
      // artificial sidewall at the ROI and erase outside material that grows in.
      for(const pair of pairs.keys())sourceMap.set(pair,this.operation(sourceMap.get(pair)??[],[],'union',context));
      const geometries:LevelGeometry[]=[],breaks:Set<number>=new Set<number>();
      for(const level of stack.levels){let pieces:Point[][]=level.background?this.operation(roi,[],'union',context):this.expression(level.sourceExpression,sourceMap,context);
        for(const exclusion of level.backgroundExcludeExpressions??[])pieces=this.operation(pieces,this.expression(exclusion,sourceMap,context),'difference',context);
        geometries.push({level:level,loops:boundaries(pieces,context),scale:scale});breaks.add(level.zmin*scale);breaks.add((level.zmin+level.thickness)*scale);for(const point of level.zToBias??[])breaks.add((level.zmin+level.thickness*point.fraction)*scale);
      }
      geometries.sort((a:LevelGeometry,b:LevelGeometry):number=>a.level.meshOrder-b.level.meshOrder||stack.levels.indexOf(a.level)-stack.levels.indexOf(b.level));for(const step of stack.processes){breaks.add(step.zmin*scale);breaks.add((step.zmin+step.thickness)*scale);}
      const heights:number[]=Array.from(breaks).sort((a:number,b:number):number=>a-b);if(heights.length-1>slabMaximum)fail('工艺真实z分段超过完整预算');const meshes:LayerStackMesh[]=[],slices:LayerStackSlice[]=[],section:LayerStackSectionPolygon[]=[];let totalVolume:number=0;
      for(let at:number=1;at<heights.length;at++){const z0:number=heights[at-1],z1:number=heights[at],middle:number=z0/2+z1/2,bottom=this.at(geometries,sourceMap,stack.processes,z0,middle,scale,roi,context),top=this.at(geometries,sourceMap,stack.processes,z1,middle,scale,roi,context),mid=this.at(geometries,sourceMap,stack.processes,middle,middle,scale,roi,context);
        const rawBottom:Point[][]=roi.map((ring:Point[]):Point[]=>ring.slice()),rawTop:Point[][]=roi.map((ring:Point[]):Point[]=>ring.slice());for(const geometry of geometries)if(middle>=geometry.level.zmin*scale&&middle<(geometry.level.zmin+geometry.level.thickness)*scale){rawBottom.push(...offsetLoops(geometry.loops,bias(geometry.level,z0,scale),context));rawTop.push(...offsetLoops(geometry.loops,bias(geometry.level,z1,scale),context));}
        for(const step of stack.processes)if(middle>=step.zmin*scale&&middle<(step.zmin+step.thickness)*scale){const loops:Point[][]=boundaries(this.expression(step.sourceExpression,sourceMap,context),context);rawBottom.push(...loops);rawTop.push(...loops);}
        const parameters:number[]=eventParameters(rawBottom,rawTop,context);if(parameters.length>slabMaximum)fail('物理z拓扑事件超过完整预算');
        for(const geometry of geometries){const level:PhysicalLayerLevel=geometry.level,a:Point[][]=bottom.get(level.id)??[],b:Point[][]=top.get(level.id)??[];if(a.length===0&&b.length===0){for(const fraction of parameters)if(fraction>0&&fraction<1&&(this.at(geometries,sourceMap,stack.processes,z0+(z1-z0)*fraction,middle,scale,roi,context).get(level.id)??[]).length>0)fail('z事件区间材料出现/消失，不能省略真实体积');continue;}
          const first:Point[][]=boundaries(a,context),last:Point[][]=matched(first,boundaries(b,context),context),expected:Point[][]=first.map((ring:Point[],loop:number):Point[]=>ring.map((p:Point,index:number):Point=>({x:p.x/2+last[loop][index].x/2,y:p.y/2+last[loop][index].y/2}))),estimated:Point[][]=this.filled(expected,context),difference:Point[][]=this.operation(estimated,mid.get(level.id)??[],'xor',context);
          if(difference.length>0)fail('侧壁/材料优先z轨迹不满足precision内线性loft；须拆分高度或细化模型');
          certifyLoft(first,last,context);
          for(const fraction of parameters)if(fraction>0&&fraction<1&&fraction!==.5){const actual:Point[][]=this.at(geometries,sourceMap,stack.processes,z0+(z1-z0)*fraction,middle,scale,roi,context).get(level.id)??[],expectedLoops:Point[][]=first.map((ring:Point[],loop:number):Point[]=>ring.map((p:Point,index:number):Point=>interpolated(p,last[loop][index],fraction)));
            if(this.operation(this.filled(expectedLoops,context),actual,'xor',context).length>0)fail('真实工艺mask在z事件区间改变拓扑，不能遗漏中间材料');}
          const mesh:LayerStackMesh=this.mesh({level:level,bottom:first,top:last,z0:z0,z1:z1},context);meshes.push(mesh);totalVolume+=mesh.volumeNm3;if(request.sectionLine!==undefined)section.push(...sectionMesh(mesh,request.sectionLine,context));
          for(const upper of [false,true]){const material:Point[][]=upper?b:a;slices.push({levelId:level.id,materialId:level.materialId,layerNumber:level.layerNumber,datatype:level.datatype,zNm:upper?z1:z0,polygonsNm:material,areaNm2:material.reduce((sum:number,ring:Point[]):number=>sum+Math.abs(area(ring)),0)});}
        }
      }
      if(!Number.isFinite(totalVolume))fail('整个层栈体积溢出');if(meshes.length===0)warnings.push('所选root/ROI与工艺mask没有物理材料');
      warnings.push(`物理几何采用明确XY precision ${request.precisionNm} nm；source政策 ${request.coordinatePolicy}，ROI内生成，不改写GDS或端口`);
      if(collected.maximumApproximationErrorNm>0)warnings.push(`源round PATH外包轮廓上界 ${collected.maximumApproximationErrorNm} nm；未伪称理想圆端精确体积`);
      warnings.push('surfaceAreaNm2 是每个闭合z分段的面积，包含相邻分段内部端面；其合计不能当作层栈外表面积');
      warnings.push('层栈参数与生成几何属于用户工艺模型；不构成foundry签核、3D电磁或制造收敛证据');
      return{ok:true,message:'完整派生/工艺几何与闭合体积已生成',preview:{schema:'hongtu-layer-stack-geometry/v1',stackJson:JSON.stringify(stack),unit:'nm',precisionNm:request.precisionNm,sourceCoordinatePolicy:request.coordinatePolicy,boundsNm:{minX:b.minX,minY:b.minY,maxX:b.maxX,maxY:b.maxY},sectionLine:request.sectionLine===undefined?undefined:{startNm:clonePoint(request.sectionLine.startNm),endNm:clonePoint(request.sectionLine.endNm)},rootCellId:request.rootCellId,dbuNm:request.dbuNm,meshes:meshes,slices:slices,section:section,sectionLengthNm:request.sectionLine===undefined?0:Math.hypot(request.sectionLine.endNm.x-request.sectionLine.startNm.x,request.sectionLine.endNm.y-request.sectionLine.startNm.y),totalVolumeNm3:totalVolume,sourcePolygons:collected.obstacles.length,placements:collected.placements,work:context.work,warnings:warnings}};
    }catch(error){return{ok:false,message:`物理层栈未生成：${(error as Error).message}`};}
  }
}
export const layerStackService:LayerStackService=new LayerStackService();
