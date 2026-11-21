/** Physical process metadata. Layout XY remains nm; unit applies to stack
 * heights, bias and process distances only. Unknown JSON fields are retained. */
export interface PhysicalMaterial {
  id: string; name: string; color: string;
  relativePermittivity?: number; conductivitySm?: number; infoJson?: string;
}
export interface PhysicalBiasPoint { fraction: number; bias: number; }
export interface PhysicalLayerLevel {
  id: string; name: string; layerNumber: number; datatype: number;
  sourceExpression: string; materialId: string; zmin: number; thickness: number;
  sidewallAngleDeg: number; widthToZ: number; bias: number;
  zToBias?: PhysicalBiasPoint[]; meshOrder: number;
  background: boolean; backgroundExcludeExpressions?: string[]; infoJson?: string;
}
/** Ordered grow adds a mask volume to the declared target level. Etch removes
 * its mask from every target at that physical z interval. Neither edits GDS. */
export interface PhysicalProcessStep {
  id: string; kind: 'grow' | 'etch'; sourceExpression: string;
  targetLevelIds: string[]; zmin: number; thickness: number; infoJson?: string;
}
export interface PhysicalLayerStack {
  schema: string; id: string; name: string; unit: 'nm' | 'um';
  materials: PhysicalMaterial[]; levels: PhysicalLayerLevel[];
  processes: PhysicalProcessStep[]; infoJson?: string;
}
export interface PhysicalStackParseResult {
  ok: boolean; message: string; executable: boolean; stack?: PhysicalLayerStack; migrated: boolean;
}
export interface StackLayerPair { layerNumber: number; datatype: number; }
export type StackBooleanOp = 'union' | 'difference' | 'intersection' | 'xor';
export interface StackExpressionInstruction { pairKey: string; operation?: StackBooleanOp; }
export interface StackExpression { pairs: StackLayerPair[]; instructions: StackExpressionInstruction[]; }
export const PHYSICAL_LAYER_STACK_SCHEMA: string = 'hongtu-layer-stack/v1';

function text(value: string, label: string, maximum: number = 120): void {
  if (typeof value !== 'string' || value.length < 1 || value.length > maximum || value.includes('\0')) throw new Error(`${label} 文本无效`);
}
function finite(value: number, label: string): void {
  if (!Number.isFinite(value) || Math.abs(value) > 1e12) throw new Error(`${label} 必须为有限物理数值`);
}
function layer(value: number): void {
  if (!Number.isInteger(value) || value < 0 || value > 32767) throw new Error('物理层绑定须为 0–32767 的真实 layer/datatype');
}
function information(value: string | undefined): void {
  if (value === undefined) return;
  if (typeof value !== 'string' || value.length > 65536) throw new Error('层栈 infoJson 超过文本预算');
  const decoded: Object = JSON.parse(value) as Object;
  if (decoded === null || typeof decoded !== 'object' || Array.isArray(decoded)) throw new Error('infoJson 必须是惰性 JSON 对象');
}
function inert(value: Object): void {
  const queue: Object[] = [value], depths: number[] = [0];
  for (let at: number = 0; at < queue.length; at++) {
    if (at >= 200000 || depths[at] > 64) throw new Error('层栈 JSON 节点/深度预算不足');
    const current: Object = queue[at];
    if (typeof current === 'number' && !Number.isFinite(current as number)) throw new Error('层栈含非有限数值');
    if (current === null || current === undefined || ['string','number','boolean'].includes(typeof current)) continue;
    if (typeof current !== 'object') throw new Error('层栈只接受惰性 JSON');
    const row: Record<string,Object> = current as Record<string,Object>;
    for (const key of Object.keys(current)) { queue.push(row[key]); depths.push(depths[at]+1); }
  }
}
function precedence(operation: StackBooleanOp): number {
  return operation === 'intersection' ? 4 : operation === 'difference' ? 3 : operation === 'xor' ? 2 : 1;
}
/** Exact, bounded explicit pair expression; no UI names or wildcard binding. */
export function parseStackExpression(expression: string): StackExpression {
  text(expression,'sourceExpression',4096);
  const pairs: StackLayerPair[] = [], instructions: StackExpressionInstruction[] = [], operators: string[] = [];
  let at: number = 0, needSource: boolean = true, tokens: number = 0, depth: number = 0;
  const emit = (): void => {
    const operation: string | undefined = operators.pop();
    if (operation === undefined || operation === '(') throw new Error('层栈表达式括号/运算符无效');
    instructions.push({ pairKey:'',operation:operation as StackBooleanOp });
  };
  while (at < expression.length) {
    const rest: string = expression.slice(at), space: RegExpMatchArray | null = rest.match(/^\s+/);
    if (space !== null) { at += space[0].length; continue; }
    if (++tokens > 512) throw new Error('层栈表达式超过 512 语法项');
    if (rest[0] === '(') {
      if (!needSource || ++depth > 64) throw new Error('层栈表达式括号无效或超过深度');
      operators.push('('); at++; continue;
    }
    if (rest[0] === ')') {
      if (needSource || depth <= 0) throw new Error('层栈表达式空/不配对括号');
      while (operators[operators.length-1] !== '(') emit();
      operators.pop(); depth--; at++; continue;
    }
    const source: RegExpMatchArray | null = rest.match(/^(\d+)\s*\/\s*(\d+)/);
    if (source !== null) {
      if (!needSource) throw new Error('源层之间缺少布尔运算符');
      const first: number = Number(source[1]),second: number = Number(source[2]);layer(first);layer(second);
      const key: string = `${first}/${second}`;
      if (!pairs.some((pair: StackLayerPair): boolean => pair.layerNumber === first && pair.datatype === second)) {
        if (pairs.length >= 64) throw new Error('层栈表达式源层超过 64 个');
        pairs.push({layerNumber:first,datatype:second});
      }
      instructions.push({pairKey:key}); needSource=false; at+=source[0].length; continue;
    }
    const operator: RegExpMatchArray | null = rest.match(/^(union|or|difference|subtract|diff|intersection|intersect|and|xor)\b|^[|+\-&^]/i);
    if (operator === null || needSource) throw new Error('层栈源请写完整 layer/datatype 与合法布尔表达式');
    const word: string = operator[0].toLowerCase();
    const operation: StackBooleanOp = ['&','intersection','intersect','and'].includes(word)?'intersection':
      ['-','difference','subtract','diff'].includes(word)?'difference':['^','xor'].includes(word)?'xor':'union';
    while (operators.length > 0 && operators[operators.length-1] !== '(' && precedence(operators[operators.length-1] as StackBooleanOp) >= precedence(operation)) emit();
    operators.push(operation);needSource=true;at+=operator[0].length;
  }
  if (needSource || depth !== 0) throw new Error('层栈表达式不完整');
  while (operators.length > 0) emit();
  return {pairs:pairs,instructions:instructions};
}
export function validatePhysicalLayerStack(stack: PhysicalLayerStack, bindings?: StackLayerPair[]): void {
  inert(stack as Object);text(stack.schema,'schema',120);
  if (stack.schema !== PHYSICAL_LAYER_STACK_SCHEMA) throw new Error(`未知物理层栈 schema ${stack.schema} 只可保留，不能执行`);
  text(stack.id,'stack.id',80);text(stack.name,'stack.name');
  if (!['nm','um'].includes(stack.unit)) throw new Error('层栈 unit 必须明确为 nm 或 um');
  const scale: number = stack.unit === 'um'?1000:1;
  information(stack.infoJson);
  if (!Array.isArray(stack.materials)||stack.materials.length<1||stack.materials.length>256) throw new Error('层栈材料需要 1–256 项');
  const materialIds: Set<string> = new Set<string>();
  for (const material of stack.materials) {
    text(material.id,'material.id',80);text(material.name,'material.name');information(material.infoJson);
    if (materialIds.has(material.id)||!/^#[0-9a-fA-F]{6}$/.test(material.color)) throw new Error('重复材料或 color 非 #RRGGBB');
    materialIds.add(material.id);
    if (material.relativePermittivity !== undefined && (!Number.isFinite(material.relativePermittivity)||material.relativePermittivity<=0)) throw new Error('材料相对介电常数须为正有限数');
    if (material.conductivitySm !== undefined && (!Number.isFinite(material.conductivitySm)||material.conductivitySm<0)) throw new Error('材料电导率须非负有限');
  }
  if (!Array.isArray(stack.levels)||stack.levels.length<1||stack.levels.length>256) throw new Error('物理层栈需要 1–256 levels');
  const levelIds: Set<string> = new Set<string>();
  const checkExpression = (expression: string): void => {
    const parsed: StackExpression = parseStackExpression(expression);
    if (bindings !== undefined) for (const pair of parsed.pairs) if (!bindings.some((declared: StackLayerPair): boolean => declared.layerNumber===pair.layerNumber&&declared.datatype===pair.datatype)) throw new Error(`层栈源 ${pair.layerNumber}/${pair.datatype} 未绑定到当前工艺`);
  };
  for (const level of stack.levels) {
    text(level.id,'level.id',80);text(level.name,'level.name');information(level.infoJson);layer(level.layerNumber);layer(level.datatype);
    if (levelIds.has(level.id)||!materialIds.has(level.materialId)) throw new Error('重复 level 或材料身份缺失');
    levelIds.add(level.id);checkExpression(level.sourceExpression);
    if (bindings!==undefined&&!bindings.some((pair:StackLayerPair):boolean=>pair.layerNumber===level.layerNumber&&pair.datatype===level.datatype)) throw new Error('物理输出层未绑定到当前工艺');
    finite(level.zmin*scale,'zmin');finite(level.thickness*scale,'thickness');finite((level.zmin+level.thickness)*scale,'zmax');finite(level.bias*scale,'bias');
    if (!(level.thickness>0)||!Number.isFinite(level.sidewallAngleDeg)||Math.abs(level.sidewallAngleDeg)>=89||!Number.isFinite(level.widthToZ)||level.widthToZ<0||level.widthToZ>1||typeof level.background!=='boolean'||!Number.isSafeInteger(level.meshOrder)||level.meshOrder<1||level.meshOrder>100000) throw new Error('层栈厚度、侧壁、参考高度、背景或优先级无效');
    if (level.zToBias!==undefined) {
      if (!Array.isArray(level.zToBias)||level.zToBias.length<2||level.zToBias.length>64||level.zToBias[0].fraction!==0||level.zToBias[level.zToBias.length-1].fraction!==1||level.sidewallAngleDeg!==0) throw new Error('zToBias 需完整0→1且与侧壁角互斥');
      let previous:number=-1;
      for(const point of level.zToBias){if(!Number.isFinite(point.fraction)||point.fraction<=previous||point.fraction<0||point.fraction>1)throw new Error('zToBias fraction须严格递增');finite(point.bias*scale,'zToBias.bias');previous=point.fraction;}
    }
    if(level.backgroundExcludeExpressions!==undefined){if(!Array.isArray(level.backgroundExcludeExpressions)||level.backgroundExcludeExpressions.length>64)throw new Error('背景排除超过预算');for(const expression of level.backgroundExcludeExpressions)checkExpression(expression);}
  }
  if (!Array.isArray(stack.processes)||stack.processes.length>256) throw new Error('工艺步骤最多256项');
  const processIds:Set<string>=new Set<string>();
  for(const step of stack.processes){text(step.id,'process.id',80);information(step.infoJson);checkExpression(step.sourceExpression);
    if(processIds.has(step.id)||!['grow','etch'].includes(step.kind)||!Array.isArray(step.targetLevelIds)||step.targetLevelIds.length<1||step.targetLevelIds.length>256||new Set<string>(step.targetLevelIds).size!==step.targetLevelIds.length||step.targetLevelIds.some((id:string):boolean=>!levelIds.has(id)))throw new Error('工艺步骤身份、种类或目标无效');
    processIds.add(step.id);finite(step.zmin*scale,'process.zmin');finite(step.thickness*scale,'process.thickness');finite((step.zmin+step.thickness)*scale,'process.zmax');if(!(step.thickness>0))throw new Error('工艺步骤必须有真实正厚度');
  }
}
/** Known v0 lengths were explicit nanometers. Migration keeps every unknown
 * field and never fabricates heights/materials for a legacy technology. */
export function parsePhysicalLayerStack(json: string, bindings?: StackLayerPair[]): PhysicalStackParseResult {
  try {
    if(typeof json!=='string'||json.length>2*1024*1024)throw new Error('物理层栈超过2MiB文本预算');
    const stack:PhysicalLayerStack=JSON.parse(json) as PhysicalLayerStack;inert(stack as Object);
    if(stack===null||typeof stack!=='object'||Array.isArray(stack))throw new Error('物理层栈须JSON对象');text(stack.schema,'schema',120);
    let migrated:boolean=false;
    if(stack.schema==='hongtu-layer-stack/v0'){stack.schema=PHYSICAL_LAYER_STACK_SCHEMA;stack.unit=stack.unit??'nm';stack.processes=stack.processes??[];
      for(const level of stack.levels){level.sourceExpression=level.sourceExpression??`${level.layerNumber}/${level.datatype}`;level.sidewallAngleDeg=level.sidewallAngleDeg??0;level.widthToZ=level.widthToZ??0;level.bias=level.bias??0;level.meshOrder=level.meshOrder??3;level.background=level.background??false;}migrated=true;}
    if(stack.schema!==PHYSICAL_LAYER_STACK_SCHEMA)return{ok:true,message:'未知schema已惰性保留；执行需对应实现',executable:false,stack:stack,migrated:false};
    validatePhysicalLayerStack(stack,bindings);return{ok:true,message:'',executable:true,stack:stack,migrated:migrated};
  }catch(error){return{ok:false,message:(error as Error).message,executable:false,migrated:false};}
}
export function serializePhysicalLayerStack(stack:PhysicalLayerStack):string{
  inert(stack as Object);const parsed:PhysicalStackParseResult=parsePhysicalLayerStack(JSON.stringify(stack));if(!parsed.ok||parsed.stack===undefined)throw new Error(parsed.message);return JSON.stringify(parsed.stack,null,2);
}
