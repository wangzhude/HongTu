import { Shape, ShapeType, Point, getShapeBounds } from '../models/GdsiiData';
import type { AiContext, AiCellInfo } from './AiService';
import { cloneStructured } from '../common/CloneUtils';

export interface AiEditorQuery {
  kind: string; cellId?: number; layer?: number; datatype?: number; shapeIds?: number[];
  minX?: number; minY?: number; maxX?: number; maxY?: number; offset?: number; limit?: number;
  category?: string; toolName?: string; argumentsJson?: string;
}
export interface AiQuerySource {
  context: AiContext; shapes: Shape[]; cells: AiCellInfo[]; drc: Object[]; rules: Object[]; ports: Object[];
  drcCurrent: boolean; ruleSource: string;
}
export interface AiQueryItem { data: Object; geometryComplete?: boolean; regionMatch?: string; }
interface AiWorkflowCapabilities { workflows: string[]; semantics: string; }
export interface AiEditorReply {
  success: boolean; error?: string; documentIdentity?: string; documentRevision?: number;
  coordinateUnit: string; dbuNm?: number; source: string; total: number; offset: number;
  nextOffset?: number; truncated: boolean; items: AiQueryItem[];
}

/** Read fresh local state only. Never changes selection, tools, document or verification state. */
export function queryAiWorkbench(query: AiEditorQuery, source: AiQuerySource): AiEditorReply {
  const reply: AiEditorReply = { success: true, documentIdentity: source.context.documentIdentity,
    documentRevision: source.context.documentRevision, coordinateUnit: 'nm', dbuNm: source.context.dbuNm,
    source: query.kind, total: 0, offset: query.offset ?? 0, truncated: false, items: [] };
  if (source.context.layoutContextIncluded === false) throw new Error('用户没有发送当前版图资料');
  if (!['shapes', 'cells', 'drc', 'rules', 'ports', 'capabilities'].includes(query.kind)) throw new Error('不支持的编辑器查询');
  const limit: number = query.limit ?? 24;
  if (!Number.isSafeInteger(reply.offset) || reply.offset < 0 || reply.offset > 1000000 ||
    !Number.isSafeInteger(limit) || limit < 1 || limit > 64) throw new Error('查询分页参数无效');
  for (const value of [query.cellId, query.layer, query.datatype]) {
    if (value !== undefined && (!Number.isSafeInteger(value) || value < 0)) throw new Error('查询标识必须为非负整数');
  }
  if ((query.layer ?? 0) > 32767 || (query.datatype ?? 0) > 32767) throw new Error('查询图层超出范围');
  if (query.shapeIds !== undefined && (!Array.isArray(query.shapeIds) || query.shapeIds.length > 64 ||
    query.shapeIds.some((id: number): boolean => !Number.isSafeInteger(id) || id < 0))) throw new Error('查询对象ID无效');
  const bounds: Array<number | undefined> = [query.minX, query.minY, query.maxX, query.maxY];
  const region: boolean = bounds.some((v: number | undefined): boolean => v !== undefined);
  if (region && (bounds.some((v: number | undefined): boolean => v === undefined || !Number.isFinite(v)) ||
    query.minX! > query.maxX! || query.minY! > query.maxY!)) throw new Error('查询区域需要完整有效的四个边界');
  let rows: AiQueryItem[] = [];
  if (query.kind === 'shapes') {
    const cell: number = query.cellId ?? source.context.currentCell?.id ?? source.context.topCellId ?? 0;
    // Keep only a bounded page in memory even for million-shape documents.
    let matched: number = 0;
    for (const shape of source.shapes) {
      if ((shape.ownerCellId ?? source.context.topCellId ?? 0) !== cell ||
        (query.layer !== undefined && shape.layerNumber !== query.layer) ||
        (query.datatype !== undefined && shape.datatype !== query.datatype) ||
        (query.shapeIds !== undefined && !query.shapeIds.includes(shape.id))) continue;
      const box = getShapeBounds(shape);
      if (region && shape.type !== ShapeType.INSTANCE &&
        (box.maxX < query.minX! || box.minX > query.maxX! || box.maxY < query.minY! || box.minY > query.maxY!)) continue;
      const position: number = matched++;
      if (position < reply.offset || rows.length >= limit) continue;
      const copy: Shape = { id: shape.id, type: shape.type, layerNumber: shape.layerNumber, datatype: shape.datatype,
        ownerCellId: shape.ownerCellId, cellId: shape.cellId, points: shape.points.slice(0, 128).map((point: Point): Point => ({ x: point.x, y: point.y })), selected: false,
        pathWidth: shape.pathWidth, pathType: shape.pathType, pathBeginExtension: shape.pathBeginExtension,
        pathEndExtension: shape.pathEndExtension, pathWidthAbsolute: shape.pathWidthAbsolute,
        text: shape.text?.substring(0, 1024), rotation: shape.rotation, mirror: shape.mirror, magnification: shape.magnification,
        arrayCols: shape.arrayCols, arrayRows: shape.arrayRows, arrayColStepX: shape.arrayColStepX,
        arrayColStepY: shape.arrayColStepY, arrayRowStepX: shape.arrayRowStepX, arrayRowStepY: shape.arrayRowStepY };
      rows.push({ data: copy, geometryComplete: shape.points.length <= 128 && shape.type !== ShapeType.INSTANCE,
        regionMatch: region ? (shape.type === ShapeType.INSTANCE ? 'instance_extent_not_expanded' : 'aabb_candidate') : undefined });
    }
    reply.total = matched;
    reply.source = `当前文档 / Cell ${cell}；直接图形，未展开实例；区域查询为包围盒候选`;
  } else {
    let values: Object[] = [];
    if (query.kind !== 'shapes' && (query.layer !== undefined || query.datatype !== undefined || query.shapeIds !== undefined || region)) {
      throw new Error('图层、对象和区域过滤仅支持 shapes 查询');
    }
    if (query.cellId !== undefined && !['cells', 'ports'].includes(query.kind)) throw new Error('当前查询不支持 Cell 过滤');
    if (query.kind === 'cells') values = source.cells.filter((cell: AiCellInfo): boolean => query.cellId === undefined || cell.id === query.cellId);
    else if (query.kind === 'drc') {
      if (!source.drcCurrent) throw new Error('当前文档版本没有有效DRC结果，请先运行检查');
      values = source.drc; reply.source = source.ruleSource;
    } else if (query.kind === 'rules') { values = source.rules; reply.source = source.ruleSource; }
    else if (query.kind === 'ports') values = source.ports;
    else {
      const capabilities: AiWorkflowCapabilities = { workflows: ['pcell', 'ports', 'route', 'boolean_union', 'boolean_intersection', 'boolean_difference', 'cell_hierarchy'],
        semantics: '可请求的入口；具体可用性由当前选择、工艺与编辑权限检查。打开原生参数与预览流程，仍需确认；不代表操作已执行' };
      values = [capabilities];
    }
    reply.total = values.length;
    rows = values.slice(reply.offset, reply.offset + limit).map((data: Object): AiQueryItem => ({ data: cloneStructured(data) as Object }));
  }
  for (const row of rows) {
    const candidate: AiQueryItem[] = reply.items.concat([row]);
    if (JSON.stringify(candidate).length * 3 > 80000) break;
    reply.items.push(row);
  }
  if (reply.items.length === 0 && reply.offset < reply.total) throw new Error('单条查询结果超过传输预算，请缩小查询内容');
  const next: number = reply.offset + reply.items.length;
  reply.truncated = next < reply.total;
  if (reply.truncated) reply.nextOffset = next;
  return reply;
}
