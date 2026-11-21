import { AI_NATIVE_CATALOG_JSON } from './AiNativeCatalog';

export interface AiToolSchema {
  type?: string; properties?: Record<string, AiToolSchema>; required?: string[];
  additionalProperties?: boolean | AiToolSchema; items?: AiToolSchema; oneOf?: AiToolSchema[];
  enum?: Object[]; minimum?: number; maximum?: number;
  minLength?: number; maxLength?: number; minItems?: number; maxItems?: number;
}
export interface AiNativeTool {
  name: string; title: string; category: string; mode: string; requiresLayout: boolean;
  owner: string; parameters: AiToolSchema;
}
interface AiNativeCatalog { version: string; coordinateUnit: string; tools: AiNativeTool[]; }
export interface AiNativeCall { name: string; arguments: Record<string, Object>; }
export interface AiNativeResult {
  success: boolean; status: string; message: string; data?: Object;
  documentIdentity?: string; documentRevision?: number; coordinateUnit?: string;
}
export interface AiNativeToolSummary {
  name: string; title: string; category: string; mode: string; requiresLayout: boolean;
}
export interface AiNativeToolPage {
  success: boolean; version: string; coordinateUnit: string; total: number; offset: number;
  nextOffset?: number; categories: string[]; tools: AiNativeToolSummary[]; tool?: AiNativeTool;
}

const catalog: AiNativeCatalog = JSON.parse(AI_NATIVE_CATALOG_JSON) as AiNativeCatalog;

export function aiNativeTool(name: string): AiNativeTool {
  const tool: AiNativeTool | undefined = catalog.tools.find((entry: AiNativeTool): boolean => entry.name === name);
  if (tool === undefined) throw new Error(`未注册的原生工具：${name}`);
  return tool;
}

export function aiNativeTools(category: string = '', offset: number = 0, name: string = ''): AiNativeToolPage {
  if (!Number.isSafeInteger(offset) || offset < 0) throw new Error('工具分页无效');
  const tools: AiNativeTool[] = catalog.tools.filter((entry: AiNativeTool): boolean => !category || entry.category === category);
  return { success: true, version: catalog.version, coordinateUnit: catalog.coordinateUnit, total: tools.length, offset,
    categories: Array.from(new Set<string>(catalog.tools.map((entry: AiNativeTool): string => entry.category))),
    nextOffset: offset + 24 < tools.length ? offset + 24 : undefined,
    tools: tools.slice(offset, offset + 24).map((entry: AiNativeTool): AiNativeToolSummary => ({ name: entry.name,
      title: entry.title, category: entry.category, mode: entry.mode, requiresLayout: entry.requiresLayout })),
    tool: name ? aiNativeTool(name) : undefined };
}

/** The wire is untrusted even when a provider used function calling. Reject
 * unknown fields and non-finite values before reaching any native operation. */
export function validateAiNativeValue(value: Object, schema: AiToolSchema, path: string = 'arguments', depth: number = 0): void {
  if (depth > 16 || value === null || value === undefined) throw new Error(`${path} 为空或层级过深`);
  if (schema.oneOf !== undefined) {
    let matches: number = 0;
    for (const candidate of schema.oneOf) {
      try { validateAiNativeValue(value, candidate, path, depth + 1); matches++; } catch (_) {}
    }
    if (matches !== 1) throw new Error(`${path} 类型不匹配`);
    return;
  }
  if (schema.enum !== undefined && !schema.enum.some((entry: Object): boolean => entry === value)) throw new Error(`${path} 不在允许值中`);
  if (schema.type === 'object') {
    if (typeof value !== 'object' || Array.isArray(value)) throw new Error(`${path} 必须是对象`);
    const record: Record<string, Object> = value as Record<string, Object>;
    const properties: Record<string, AiToolSchema> = schema.properties ?? {};
    const keys: string[] = Object.keys(record);
    if (keys.length > 128) throw new Error(`${path} 字段过多`);
    for (const required of schema.required ?? []) if (!keys.includes(required)) throw new Error(`${path}.${required} 缺失`);
    for (const key of keys) {
      if (['__proto__', 'constructor', 'prototype'].includes(key)) throw new Error(`${path} 字段无效`);
      const field: AiToolSchema | undefined = properties[key];
      if (field !== undefined) validateAiNativeValue(record[key], field, `${path}.${key}`, depth + 1);
      else if (typeof schema.additionalProperties === 'object') validateAiNativeValue(record[key], schema.additionalProperties, `${path}.${key}`, depth + 1);
      else throw new Error(`${path}.${key} 未注册`);
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value)) throw new Error(`${path} 必须是数组`);
    const values: Object[] = value as Object[];
    if (values.length < (schema.minItems ?? 0) || values.length > (schema.maxItems ?? 512)) throw new Error(`${path} 数量越界`);
    if (schema.items === undefined) throw new Error('缺少数组参数协议');
    values.forEach((item: Object, index: number): void => validateAiNativeValue(item, schema.items!, `${path}[${index}]`, depth + 1));
  } else if (schema.type === 'number' || schema.type === 'integer') {
    if (typeof value !== 'number' || !Number.isFinite(value as number)) throw new Error(`${path} 必须是有限数值`);
    const number: number = value as number;
    if ((schema.type === 'integer' && !Number.isSafeInteger(number)) || number < (schema.minimum ?? -1e9) || number > (schema.maximum ?? 1e9)) throw new Error(`${path} 数值越界`);
  } else if (schema.type === 'string') {
    if (typeof value !== 'string' || (value as string).length < (schema.minLength ?? 0) || (value as string).length > (schema.maxLength ?? 60000)) throw new Error(`${path} 文本无效`);
  } else if (schema.type === 'boolean') {
    if (typeof value !== 'boolean') throw new Error(`${path} 必须是布尔值`);
  } else throw new Error(`${path} 缺少参数协议`);
}

export function parseAiNativeCall(name: string, argumentsJson: string): AiNativeCall {
  if (argumentsJson.length > 60000) throw new Error('原生工具参数超过 60000 字符');
  const tool: AiNativeTool = aiNativeTool(name);
  const args: Record<string, Object> = JSON.parse(argumentsJson) as Record<string, Object>;
  validateAiNativeValue(args, tool.parameters);
  return { name, arguments: args };
}

export function validateAiNativeBatch(calls: AiNativeCall[]): void {
  if (calls.length < 1 || calls.length > 32) throw new Error('每批原生操作须为 1–32 项');
  for (const call of calls) validateAiNativeValue(call.arguments, aiNativeTool(call.name).parameters);
  if (calls.some((call: AiNativeCall): boolean => aiNativeTool(call.name).mode === 'read')) throw new Error('只读工具请直接查询，不加入修改方案');
  if (calls.length > 1 && calls.some((call: AiNativeCall): boolean => aiNativeTool(call.name).mode !== 'edit')) throw new Error('文档切换、设置和文件操作须逐项执行并核对结果');
}

export function aiNativeResult(ok: boolean, message: string, data?: Object, status: string = ''): AiNativeResult {
  return { success: ok, status: status || (ok ? 'executed' : 'failed'), message, data };
}

/** Bounded public result fields; platform/private storage objects are not a
 * response schema. Individual tools publish only the fields they measured. */
export interface AiNativeData {
  total?: number; offset?: number; nextOffset?: number; truncated?: boolean; items?: Object[];
  active?: Object; activeId?: string; ruleSource?: string; rules?: Object; tabs?: Object; history?: Object;
  views?: Object; bookmarks?: Object; id?: string | number; documentId?: string; title?: string; createdAt?: number;
  category?: string; pcellName?: string; params?: Object; drc?: string; lvsCurrent?: boolean; lvs?: Object; nets?: Object;
  reports?: Object; statistics?: Object; page?: Object; loaded?: boolean;
  outputObjects?: number; areaNm2?: number; placedInstances?: number; addedShapes?: number;
  routes?: Object; profiles?: Object; warnings?: string[]; obstacleCount?: number; maximumApproximationErrorNm?: number; lengthDefinition?: string;
  bounds?: Object; widthNm?: number; heightNm?: number; boundsOnly?: boolean; spice?: string; boundary?: string;
  totalVolumeNm3?: number; sourcePolygons?: number; placements?: number; meshes?: Object;
  levelId?: string; materialId?: string; volumeNm3?: number; surfaceAreaNm2?: number;
  draft?: Object; templates?: Object; timestamp?: number; inputMode?: string; success?: boolean; message?: string;
  text?: string; stepCount?: number; transfer?: Object; merge?: Object; waiver?: Object;
  selectionToken?: number; fileName?: string; sourceDbuNm?: number; topCellId?: number; cells?: Object; layers?: Object;
  opticalRoutes?: Object; pairKey?: string; continuousLengthNm?: number; sampledLengthNm?: number;
  minimumRadiusNm?: number; maximumCurvaturePerNm?: number; endpointErrors?: Object;
  samplingErrorNm?: number; integrationErrorNm?: number; quantizationErrorNm?: number; poseClosureErrorNm?: number;
}
export function aiNativeData(data: AiNativeData): Object { return data; }
