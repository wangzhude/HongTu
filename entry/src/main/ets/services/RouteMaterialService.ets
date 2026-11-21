import { ShapeType } from '../models/GdsiiData';
import type { Point, Shape } from '../models/GdsiiData';
import type { LayoutCrossSection, ResolvedPort } from '../models/LayoutPort';
import type { RouteMaterialStrip, RouteMaterialDescriptor, RouteLayerPair, RouteTaperRule, RouteViaRule,
  RouteTransitionRule, RouteMaterialBudget, RouteMaterialInspectRequest, RouteMaterialRequest,
  RouteMaterialBand, RouteMaterialProfile, RouteMaterialCap, RouteMaterialResult, RouteMaterialExecution, RouteMaterialBboxSection } from '../models/RouteMaterial';
import { cloneStructured } from '../common/CloneUtils';

interface ForeignSectionRow { layerNumber: number; datatype: number; minNm?: number; maxNm: number; }
interface ForeignBboxRow { layerNumber: number; datatype: number; offsetNm: number; }
interface ForeignEnclosure { name: string; sections: ForeignSectionRow[]; bboxSections?: ForeignBboxRow[]; }
interface ForeignDescriptor {
  schemaVersion: number; kind: string; widthNm: number; layerNumber: number; datatype: number;
  enclosure: ForeignEnclosure; sectionMinNm?: number; sectionMaxNm?: number;
  sections?: ForeignSectionRow[]; radiusNm?: number; radiusMinNm?: number;
}
interface NormalizedDescriptor {
  schema: string; primary: string; bands: RouteMaterialBand[]; bbox: ForeignBboxRow[];
  minimumRadiusNm: number; symmetricBranches: boolean;
}
interface MaterialInspection {
  profile: RouteMaterialProfile; start: NormalizedDescriptor; end: NormalizedDescriptor; rule?: RouteTransitionRule;
}
interface LineMetrics { points: Point[]; distances: number[]; length: number; }

const MAX_INT32: number = 2147483647;
const MAX_TEXT_BYTES: number = 256 * 1024;
const EPSILON: number = 1e-9;

function message(error: string): never { throw new Error('布线材料：' + error); }
function finite(value: number, label: string, positive: boolean = false): void {
  if (!Number.isFinite(value) || (positive && value <= 0)) message(label + (positive ? '必须是有限正数' : '必须是有限数'));
}
function layer(layerNumber: number, datatype: number): void {
  if (!Number.isInteger(layerNumber) || !Number.isInteger(datatype) || layerNumber < 0 || datatype < 0 ||
    layerNumber > 32767 || datatype > 32767) message('图层号和 datatype 必须为 0–32767 整数');
}
function name(value: string): void {
  if (typeof value !== 'string' || value.length < 1 || value.length > 512 || value.includes('\0')) message('材料标识无效');
}
function close(a: number, b: number): boolean { return Math.abs(a - b) <= Math.max(Number.MIN_VALUE, Math.abs(a), Math.abs(b)) * 1e-10; }
function pair(layerNumber: number, datatype: number): string { return `${layerNumber}/${datatype}`; }
function sameLayer(aLayer: number, aDatatype: number, bLayer: number, bDatatype: number): boolean { return aLayer === bLayer && aDatatype === bDatatype; }
function layerPair(layerNumber: number, datatype: number): RouteLayerPair { return { layerNumber: layerNumber, datatype: datatype }; }
function clonePoint(p: Point): Point { return { x: p.x, y: p.y }; }
function subtract(a: Point, b: Point): Point { return { x: a.x - b.x, y: a.y - b.y }; }
function length(vector: Point): number { return Math.hypot(vector.x, vector.y); }
function direction(a: Point, b: Point): Point {
  const d: Point = subtract(b, a); const size: number = length(d);
  if (!Number.isFinite(size) || size <= 0) message('中心线含重复点或非有限线段');
  return { x: d.x / size, y: d.y / size };
}
function normal(d: Point): Point { return { x: -d.y, y: d.x }; }
function dot(a: Point, b: Point): number { return a.x * b.x + a.y * b.y; }
function cross(a: Point, b: Point): number { return a.x * b.y - a.y * b.x; }
function shifted(p: Point, n: Point, amount: number): Point { return { x: p.x + n.x * amount, y: p.y + n.y * amount }; }
function keys(object: Object, allowed: string[], label: string): void {
  if (object === null || typeof object !== 'object' || Array.isArray(object)) message(label + '必须是对象');
  for (const key of Object.keys(object)) if (allowed.indexOf(key) < 0) message(label + '含不可解释字段 ' + key);
}
function parseJson(text: string): Object {
  if (typeof text !== 'string' || text.length === 0 || text.length > MAX_TEXT_BYTES) message('描述符文本超出预算或为空');
  let bytes: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 128) bytes++;
    else if (code < 2048) bytes += 2;
    else if (code >= 0xd800 && code <= 0xdbff) {
      const low: number = text.charCodeAt(++i);
      if (!(low >= 0xdc00 && low <= 0xdfff)) message('描述符包含无效 UTF-16'); bytes += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) message('描述符包含无效 UTF-16');
    else bytes += 3;
    if (bytes > MAX_TEXT_BYTES) message('描述符 UTF-8 超过 256 KiB');
  }
  const object: Object = JSON.parse(text) as Object;
  if (object === null || typeof object !== 'object' || Array.isArray(object)) message('描述符必须是对象');
  keys(object, Object.keys(object), '描述符');
  const queue: Object[] = [object], depths: number[] = [0];
  for (let at: number = 0; at < queue.length; at++) {
    if (depths[at] > 16 || at >= 8192) message('描述符嵌套或节点超过执行预算');
    const item: Object = queue[at];
    if (typeof item === 'number' && !Number.isFinite(item as number)) message('描述符包含非有限数');
    if (item === null || typeof item !== 'object') continue;
    const record: Record<string, Object> = item as Record<string, Object>;
    for (const key of Object.keys(item)) {
      if (key === '__proto__' || key === 'prototype' || key === 'constructor') message('描述符包含保留键');
      queue.push(record[key]); depths.push(depths[at] + 1);
    }
  }
  return object;
}
function gridIndex(value: number, dbu: number, label: string): number {
  finite(value, label); const index: number = value / dbu; const rounded: number = Math.round(index);
  // Floating arithmetic tolerance is less than 1e-5 DBU even near int32 limits.
  if (!Number.isFinite(index) || Math.abs(rounded) > MAX_INT32 || Math.abs(index - rounded) > Math.max(1e-8, Math.abs(index) * Number.EPSILON * 16)) {
    message(label + '必须精确落在文档 DBU/int32 内');
  }
  return rounded;
}
function exactPoint(p: Point, dbu: number, label: string): Point {
  if (p === null || p === undefined) message(label + '为空');
  return { x: gridIndex(p.x, dbu, label + '.x') * dbu, y: gridIndex(p.y, dbu, label + '.y') * dbu };
}
function band(id: string, layerNumber: number, datatype: number, minimumNm: number, maximumNm: number): RouteMaterialBand {
  name(id); layer(layerNumber, datatype); finite(minimumNm, 'section minimum'); finite(maximumNm, 'section maximum');
  if (!(maximumNm > minimumNm)) message('材料 section 必须具有正宽度');
  return { id: id, layerNumber: layerNumber, datatype: datatype, minimumNm: minimumNm, maximumNm: maximumNm };
}
function ownDescriptor(object: RouteMaterialDescriptor): NormalizedDescriptor {
  keys(object, ['schema', 'primaryStripId', 'strips', 'minimumBendRadiusNm'], '鸿图材料描述符'); name(object.primaryStripId);
  if (!Array.isArray(object.strips) || object.strips.length === 0 || object.strips.length > 128) message('材料条数须为 1–128');
  const ids: Set<string> = new Set<string>(), bands: RouteMaterialBand[] = [];
  for (const strip of object.strips) {
    keys(strip, ['id', 'layerNumber', 'datatype', 'widthNm', 'offsetNm'], '材料 strip');
    name(strip.id); finite(strip.widthNm, '材料 width', true); finite(strip.offsetNm, '材料 offset');
    if (ids.has(strip.id)) message('材料 strip id 重复'); ids.add(strip.id);
    bands.push(band(strip.id, strip.layerNumber, strip.datatype, strip.offsetNm - strip.widthNm / 2, strip.offsetNm + strip.widthNm / 2));
  }
  const main: RouteMaterialBand | undefined = bands.find((row: RouteMaterialBand): boolean => row.id === object.primaryStripId);
  if (main === undefined || !close(main.minimumNm + main.maximumNm, 0)) message('鸿图主 strip 必须存在并以端口中心线居中');
  if (object.minimumBendRadiusNm !== undefined) finite(object.minimumBendRadiusNm, 'minimumBendRadiusNm', true);
  return { schema: object.schema, primary: object.primaryStripId, bands: bands, bbox: [], minimumRadiusNm: object.minimumBendRadiusNm ?? 0, symmetricBranches: false };
}
function foreignDescriptor(object: ForeignDescriptor): NormalizedDescriptor {
  keys(object, ['schemaVersion', 'kind', 'widthNm', 'layerNumber', 'datatype', 'enclosure', 'sectionMinNm', 'sectionMaxNm',
    'sections', 'radiusNm', 'radiusMinNm'], '外部 CrossSection');
  if (object.schemaVersion !== 1 || (object.kind !== 'symmetric' && object.kind !== 'asymmetric')) message('opaque/未知 CrossSection 仅能保存，不能执行材料');
  finite(object.widthNm, 'CrossSection width', true); layer(object.layerNumber, object.datatype);
  keys(object.enclosure, ['name', 'sections', 'bboxSections'], 'CrossSection enclosure'); name(object.enclosure.name);
  if (!Array.isArray(object.enclosure.sections) || object.enclosure.sections.length > 64) message('enclosure sections 超出预算或无效');
  const rows: ForeignSectionRow[] = object.kind === 'asymmetric' ? object.sections ?? object.enclosure.sections : object.enclosure.sections;
  if (!Array.isArray(rows) || rows.length > 64) message('CrossSection sections 超出预算或无效');
  const bands: RouteMaterialBand[] = [];
  if (object.kind === 'symmetric') {
    if (object.sectionMinNm !== undefined || object.sectionMaxNm !== undefined || object.sections !== undefined) message('symmetric 含不可解释的 asymmetric fields');
    bands.push(band('main', object.layerNumber, object.datatype, -object.widthNm / 2, object.widthNm / 2));
    for (let i: number = 0; i < rows.length; i++) {
      const row: ForeignSectionRow = rows[i]; keys(row, ['layerNumber', 'datatype', 'minNm', 'maxNm'], 'symmetric section');
      finite(row.maxNm, 'enclosure max'); layer(row.layerNumber, row.datatype);
      const outer: number = object.widthNm / 2 + row.maxNm;
      if (!(outer > 0)) message('enclosure 收缩后材料为空，不能隐式丢层');
      if (row.minNm === undefined) bands.push(band('section-' + i, row.layerNumber, row.datatype, -outer, outer));
      else {
        finite(row.minNm, 'enclosure min'); if (!(row.maxNm > row.minNm)) message('enclosure max 必须大于 min');
        const inner: number = object.widthNm / 2 + row.minNm;
        if (inner < 0) message('负的 enclosure 内宽语义不能执行');
        if (inner === 0) bands.push(band('section-' + i, row.layerNumber, row.datatype, -outer, outer));
        else {
          bands.push(band('section-' + i + ':negative', row.layerNumber, row.datatype, -outer, -inner));
          bands.push(band('section-' + i + ':positive', row.layerNumber, row.datatype, inner, outer));
        }
      }
    }
  } else {
    if (object.sectionMinNm === undefined || object.sectionMaxNm === undefined || !close(object.sectionMaxNm - object.sectionMinNm, object.widthNm)) message('asymmetric 主 strip 边界与 width 不一致');
    bands.push(band('main', object.layerNumber, object.datatype, object.sectionMinNm, object.sectionMaxNm));
    for (let i: number = 0; i < rows.length; i++) {
      const row: ForeignSectionRow = rows[i]; keys(row, ['layerNumber', 'datatype', 'minNm', 'maxNm'], 'asymmetric section');
      if (row.minNm === undefined) message('asymmetric section 缺少 minNm');
      bands.push(band('section-' + i, row.layerNumber, row.datatype, row.minNm, row.maxNm));
    }
    // The interop model contains an enclosure mirror of the independent strips.
    if (object.sections !== undefined && JSON.stringify(object.sections) !== JSON.stringify(object.enclosure.sections)) message('asymmetric sections 与 enclosure 互相矛盾');
  }
  const bbox: ForeignBboxRow[] = object.enclosure.bboxSections ?? [];
  if (!Array.isArray(bbox) || bbox.length > 64) message('bboxSections 超出预算或无效');
  const bboxLayers: Set<string> = new Set<string>();
  for (const row of bbox) {
    keys(row, ['layerNumber', 'datatype', 'offsetNm'], 'bbox section'); layer(row.layerNumber, row.datatype); finite(row.offsetNm, 'bbox offset');
    if (bboxLayers.has(pair(row.layerNumber, row.datatype))) message('bbox section 图层重复'); bboxLayers.add(pair(row.layerNumber, row.datatype));
  }
  if (object.radiusNm !== undefined) finite(object.radiusNm, 'radiusNm', true);
  if (object.radiusMinNm !== undefined) finite(object.radiusMinNm, 'radiusMinNm', true);
  return { schema: 'foreign-' + object.kind + '/v1', primary: 'main', bands: bands, bbox: cloneStructured(bbox) as ForeignBboxRow[],
    minimumRadiusNm: object.radiusMinNm ?? object.radiusNm ?? 0, symmetricBranches: object.kind === 'symmetric' };
}
function descriptor(text: string): NormalizedDescriptor {
  const object: Object = parseJson(text); const record: Record<string, Object> = object as Record<string, Object>;
  return record['schema'] === 'hongtu-route-material/v1' ? ownDescriptor(object as RouteMaterialDescriptor) : foreignDescriptor(object as ForeignDescriptor);
}
function endpointDescriptor(port: ResolvedPort, section: LayoutCrossSection | undefined, text: string | undefined): NormalizedDescriptor {
  const definition = port.definition;
  if (definition.crossSectionKey !== undefined) {
    if (section === undefined || section.key !== definition.crossSectionKey || section.version !== definition.crossSectionVersion) message('必须提供端口引用的真实 CrossSection 版本');
  } else if (section !== undefined) message('CrossSection 未被该端口引用，不能替换端口语义');
  let result: NormalizedDescriptor;
  if (section !== undefined) {
    result = descriptor(section.definitionJson);
    if (text !== undefined && JSON.stringify(descriptor(text)) !== JSON.stringify(result)) message('显式描述符与端口 CrossSection 不一致');
  } else if (text !== undefined) result = descriptor(text);
  else result = { schema: 'port-primary/v1', primary: 'main',
    bands: [band('main', definition.layerNumber, definition.datatype, -definition.widthNm / 2, definition.widthNm / 2)],
    bbox: [], minimumRadiusNm: 0, symmetricBranches: false };
  const primary: RouteMaterialBand | undefined = result.bands.find((row: RouteMaterialBand): boolean => row.id === result.primary);
  if (primary === undefined || !sameLayer(primary.layerNumber, primary.datatype, definition.layerNumber, definition.datatype) || !close(primary.maximumNm - primary.minimumNm, definition.widthNm)) message('CrossSection 主材料与端口 width/layer/datatype 不一致');
  return result;
}
function resolved(port: ResolvedPort, dbu: number, continuous: boolean = false): void {
  if (port === null || port === undefined || port.definition === null || port.definition === undefined) message('端点为空');
  name(port.definition.id);
  if (continuous) {
    finite(port.centerNm.x, '光学连续端点 X'); finite(port.centerNm.y, '光学连续端点 Y');
    if (port.definition.portType !== 'optical' || Math.abs(port.centerNm.x / dbu) > 2147483647 || Math.abs(port.centerNm.y / dbu) > 2147483647) message('连续端点只允许明确光学端口且须在实际 DBU/int32 范围');
  } else exactPoint(port.centerNm, dbu, '端点 center');
  finite(port.orientationDeg, '端点 orientation');
  finite(port.frameMagnification, '端点 MAG', true); finite(port.effectiveWidthNm, '端点有效 width', true);
  finite(port.definition.widthNm, '端口 width', true); layer(port.definition.layerNumber, port.definition.datatype);
  if (typeof port.frameMirror !== 'boolean' || !close(port.definition.widthNm * port.frameMagnification, port.effectiveWidthNm)) message('端点完整 frame 与有效 width 不一致');
}
function framed(source: NormalizedDescriptor, port: ResolvedPort, atStart: boolean): NormalizedDescriptor {
  const factor: number = port.frameMagnification * (port.frameMirror ? -1 : 1) * (atStart ? 1 : -1);
  const bands: RouteMaterialBand[] = source.bands.map((row: RouteMaterialBand): RouteMaterialBand => {
    const low: number = row.minimumNm * factor, high: number = row.maximumNm * factor;
    let id: string = row.id;
    if (source.symmetricBranches && factor < 0) {
      if (id.endsWith(':negative')) id = id.substring(0, id.length - 9) + ':positive';
      else if (id.endsWith(':positive')) id = id.substring(0, id.length - 9) + ':negative';
    }
    return band(id, row.layerNumber, row.datatype, Math.min(low, high), Math.max(low, high));
  }).sort((a: RouteMaterialBand, b: RouteMaterialBand): number => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  return { schema: source.schema, primary: source.primary, bands: bands,
    bbox: source.bbox.map((row: ForeignBboxRow): ForeignBboxRow => ({ layerNumber: row.layerNumber, datatype: row.datatype, offsetNm: row.offsetNm * port.frameMagnification })),
    minimumRadiusNm: source.minimumRadiusNm * port.frameMagnification, symmetricBranches: source.symmetricBranches };
}
function transition(text: string | undefined): RouteTransitionRule | undefined {
  if (text === undefined) return undefined;
  const object: Object = parseJson(text); const record: Record<string, Object> = object as Record<string, Object>;
  if (record['schema'] !== 'hongtu-route-transition/v1') message('未知 transition schema，未执行');
  if (record['kind'] === 'linear-taper') {
    const rule: RouteTaperRule = object as RouteTaperRule;
    keys(rule, ['schema', 'kind', 'minimumLengthNm', 'maximumEdgeSlope'], 'linear-taper rule');
    finite(rule.minimumLengthNm, 'taper minimumLengthNm', true); finite(rule.maximumEdgeSlope, 'taper maximumEdgeSlope', true); return rule;
  }
  if (record['kind'] !== 'via') message('未知 transition kind，未执行');
  const rule: RouteViaRule = object as RouteViaRule;
  keys(rule, ['schema', 'kind', 'technologyId', 'technologyVersion', 'lowerLayerNumber', 'lowerDatatype', 'upperLayerNumber', 'upperDatatype',
    'cutLayerNumber', 'cutDatatype', 'stationNm', 'cutWidthNm', 'cutHeightNm', 'columns', 'rows', 'gapXNm', 'gapYNm',
    'lowerEnclosureXNm', 'lowerEnclosureYNm', 'upperEnclosureXNm', 'upperEnclosureYNm', 'auxiliaryTaperMinimumLengthNm', 'auxiliaryMaximumEdgeSlope'], 'via rule');
  name(rule.technologyId); name(rule.technologyVersion);
  layer(rule.lowerLayerNumber, rule.lowerDatatype); layer(rule.upperLayerNumber, rule.upperDatatype); layer(rule.cutLayerNumber, rule.cutDatatype);
  if (rule.lowerLayerNumber === rule.upperLayerNumber || rule.cutLayerNumber === rule.lowerLayerNumber || rule.cutLayerNumber === rule.upperLayerNumber) message('via cut/上下导体必须是不同层号');
  finite(rule.stationNm, 'via station', true); finite(rule.cutWidthNm, 'cutWidthNm', true); finite(rule.cutHeightNm, 'cutHeightNm', true);
  for (const value of [rule.gapXNm, rule.gapYNm, rule.lowerEnclosureXNm, rule.lowerEnclosureYNm, rule.upperEnclosureXNm, rule.upperEnclosureYNm]) {
    finite(value, 'via gap/enclosure'); if (value < 0) message('via gap/enclosure 不得为负');
  }
  if (!Number.isInteger(rule.columns) || !Number.isInteger(rule.rows) || rule.columns < 1 || rule.rows < 1 || rule.columns * rule.rows > 4096) message('via rows/columns 须为正整数且 cut 数不超过 4096');
  if ((rule.auxiliaryTaperMinimumLengthNm === undefined) !== (rule.auxiliaryMaximumEdgeSlope === undefined)) message('辅助 taper 长度/斜率须成对声明');
  if (rule.auxiliaryTaperMinimumLengthNm !== undefined) finite(rule.auxiliaryTaperMinimumLengthNm, 'auxiliary taper length', true);
  if (rule.auxiliaryMaximumEdgeSlope !== undefined) finite(rule.auxiliaryMaximumEdgeSlope, 'auxiliary taper slope', true);
  return rule;
}
function primary(source: NormalizedDescriptor): RouteMaterialBand { return source.bands.find((row: RouteMaterialBand): boolean => row.id === source.primary) as RouteMaterialBand; }
function inspect(request: RouteMaterialInspectRequest): MaterialInspection {
  if (request.portCoordinatePolicy !== undefined && request.portCoordinatePolicy !== 'strict' && request.portCoordinatePolicy !== 'continuous-for-optical') message('未知端点坐标政策');
  finite(request.dbuNm, '文档 DBU', true); resolved(request.start, request.dbuNm, request.portCoordinatePolicy === 'continuous-for-optical');
  resolved(request.end, request.dbuNm, request.portCoordinatePolicy === 'continuous-for-optical');
  if (request.start.definition.portType !== request.end.definition.portType) message('端口 type 不一致');
  const start: NormalizedDescriptor = framed(endpointDescriptor(request.start, request.startCrossSection, request.descriptorJson), request.start, true);
  const end: NormalizedDescriptor = framed(endpointDescriptor(request.end, request.endCrossSection, request.endDescriptorJson ?? request.descriptorJson), request.end, false);
  if (start.primary !== end.primary || start.bands.length !== end.bands.length || start.bands.some((row: RouteMaterialBand, i: number): boolean => row.id !== end.bands[i].id)) message('两端材料拓扑/strip id 不同，缺少明确材料映射');
  if (JSON.stringify(start.bbox) !== JSON.stringify(end.bbox)) message('两端 bboxSections 不一致，缺少明确 bbox 过渡语义');
  const a: RouteMaterialBand = primary(start), b: RouteMaterialBand = primary(end);
  const rule: RouteTransitionRule | undefined = transition(request.transitionRuleJson);
  let differs: boolean = false;
  for (let i: number = 0; i < start.bands.length; i++) {
    const left: RouteMaterialBand = start.bands[i], right: RouteMaterialBand = end.bands[i];
    const sizeChange: boolean = !close(left.minimumNm, right.minimumNm) || !close(left.maximumNm, right.maximumNm);
    if (!sameLayer(left.layerNumber, left.datatype, right.layerNumber, right.datatype)) {
      if (left.id !== start.primary || rule?.kind !== 'via') message('材料层差需要明确 via rule；当前 rule 只能切换主材料层');
    }
    if (sizeChange || !sameLayer(left.layerNumber, left.datatype, right.layerNumber, right.datatype)) differs = true;
    if (sizeChange && left.id !== start.primary && rule?.kind === 'via' && rule.auxiliaryTaperMinimumLengthNm === undefined) message('辅助 strip 偏移/宽度变化需要明确 auxiliary taper rule');
  }
  if (differs && rule === undefined) message('width/offset/mirror/MAG/layer 差异必须使用明确 transition rule');
  if (rule?.kind === 'linear-taper' && !sameLayer(a.layerNumber, a.datatype, b.layerNumber, b.datatype)) message('linear-taper 不能跨图层连接');
  let viaRadius: number = 0;
  if (rule?.kind === 'via') {
    const lower: RouteLayerPair = { layerNumber: rule.lowerLayerNumber, datatype: rule.lowerDatatype };
    const upper: RouteLayerPair = { layerNumber: rule.upperLayerNumber, datatype: rule.upperDatatype };
    if (!((sameLayer(a.layerNumber, a.datatype, lower.layerNumber, lower.datatype) && sameLayer(b.layerNumber, b.datatype, upper.layerNumber, upper.datatype)) ||
      (sameLayer(a.layerNumber, a.datatype, upper.layerNumber, upper.datatype) && sameLayer(b.layerNumber, b.datatype, lower.layerNumber, lower.datatype)))) message('via rule 上下层与实际端口不对应');
    const technology = request.technology;
    if (technology === undefined || technology.schema !== 'hongtu-technology/v1' || technology.id !== rule.technologyId || technology.version !== rule.technologyVersion ||
      !Array.isArray(technology.viaLayers) || !technology.viaLayers.some((item): boolean => item.viaLayer === rule.cutLayerNumber && item.viaDatatype === rule.cutDatatype &&
        item.lowerLayer === rule.lowerLayerNumber && item.lowerDatatype === rule.lowerDatatype && item.upperLayer === rule.upperLayerNumber && item.upperDatatype === rule.upperDatatype)) message('via 必须匹配当前真实工艺 id/version/viaLayers 连通项；没有尺寸规则时不猜 PDK');
    const requiredLayers: RouteLayerPair[] = [lower, upper, layerPair(rule.cutLayerNumber, rule.cutDatatype)];
    if (!Array.isArray(technology.layers) || requiredLayers.some((row: RouteLayerPair): boolean =>
      !technology.layers.some((item): boolean => sameLayer(row.layerNumber, row.datatype, item.layerNumber, item.datatype)))) message('via 引用了当前工艺未声明的 layer/datatype');
    const halfX: number = (rule.columns * rule.cutWidthNm + (rule.columns - 1) * rule.gapXNm) / 2;
    const halfY: number = (rule.rows * rule.cutHeightNm + (rule.rows - 1) * rule.gapYNm) / 2;
    viaRadius = Math.hypot(halfX + Math.max(rule.lowerEnclosureXNm, rule.upperEnclosureXNm), halfY + Math.max(rule.lowerEnclosureYNm, rule.upperEnclosureYNm));
    finite(viaRadius, 'via pad envelope', true);
  }
  const layers: Map<string, RouteLayerPair> = new Map<string, RouteLayerPair>();
  let min: number = 0, max: number = 0;
  for (const row of start.bands.concat(end.bands)) {
    min = Math.min(min, row.minimumNm); max = Math.max(max, row.maximumNm);
    layers.set(pair(row.layerNumber, row.datatype), layerPair(row.layerNumber, row.datatype));
  }
  for (const row of start.bbox) layers.set(pair(row.layerNumber, row.datatype), layerPair(row.layerNumber, row.datatype));
  if (rule?.kind === 'via') layers.set(`${rule.cutLayerNumber}/${rule.cutDatatype}`, { layerNumber: rule.cutLayerNumber, datatype: rule.cutDatatype });
  const bboxGrowth: number = start.bbox.reduce((value: number, row: ForeignBboxRow): number => Math.max(value, row.offsetNm), 0);
  const envelope: number = Math.max(Math.abs(min), Math.abs(max)) + bboxGrowth;
  const profile: RouteMaterialProfile = { descriptorSchemas: [start.schema, end.schema], transitionKind: rule?.kind ?? 'uniform',
    startBands: start.bands, endBands: end.bands, primaryStripId: start.primary,
    startPrimaryLayer: { layerNumber: a.layerNumber, datatype: a.datatype }, endPrimaryLayer: { layerNumber: b.layerNumber, datatype: b.datatype },
    startWidthNm: a.maximumNm - a.minimumNm, endWidthNm: b.maximumNm - b.minimumNm,
    maximumPrimaryWidthNm: Math.max(a.maximumNm - a.minimumNm, b.maximumNm - b.minimumNm), envelopeMinimumNm: min, envelopeMaximumNm: max,
    obstacleEnvelopeWidthNm: 2 * Math.max(envelope, viaRadius), routeLayerPairs: Array.from(layers.values()),
    minimumBendRadiusNm: Math.max(start.minimumRadiusNm, end.minimumRadiusNm), viaPadRadiusNm: viaRadius };
  return { profile: profile, start: start, end: end, rule: rule };
}

class MaterialBuilder {
  private request: RouteMaterialRequest;
  private budget: RouteMaterialBudget;
  private work: number = 0;
  private vertices: number = 0;
  private shapes: Shape[] = [];
  private quantized: number = 0;
  private quantizationError: number = 0;
  private materialIds: number[] = [];
  private cutIds: number[] = [];
  private padIds: number[] = [];

  constructor(request: RouteMaterialRequest) {
    this.request = request;
    const value: RouteMaterialBudget = request.budget ?? {};
    this.budget = { maximumCenterlinePoints: value.maximumCenterlinePoints ?? 2048, maximumMaterials: value.maximumMaterials ?? 128,
      maximumShapes: value.maximumShapes ?? 8192, maximumVertices: value.maximumVertices ?? 65536,
      maximumWork: value.maximumWork ?? 2000000, maximumMiterRatio: value.maximumMiterRatio ?? 8 };
    const counts: number[] = [this.budget.maximumCenterlinePoints ?? 0, this.budget.maximumMaterials ?? 0,
      this.budget.maximumShapes ?? 0, this.budget.maximumVertices ?? 0, this.budget.maximumWork ?? 0];
    const limits: number[] = [8192, 256, 16384, 131072, 10000000];
    for (let i: number = 0; i < counts.length; i++) {
      if (!Number.isInteger(counts[i]) || counts[i] < 1 || counts[i] > limits[i]) message('执行预算无效或超过硬上限');
    }
    finite(this.budget.maximumMiterRatio ?? 0, 'maximumMiterRatio', true);
    if ((this.budget.maximumMiterRatio ?? 0) > 64) message('miter ratio 超过硬上限');
  }
  private charge(count: number = 1): void {
    this.work += count; if (this.work > (this.budget.maximumWork ?? 0)) message('几何执行 work 超出预算；未发布部分材料');
  }
  private coordinate(p: Point, exact: boolean): Point {
    this.charge();
    if (exact || this.request.coordinatePolicy !== 'quantize-interior') return exactPoint(p, this.request.dbuNm, exact ? '端口 cap' : '材料顶点');
    const point: Point = { x: Math.round(p.x / this.request.dbuNm) * this.request.dbuNm, y: Math.round(p.y / this.request.dbuNm) * this.request.dbuNm };
    exactPoint(point, this.request.dbuNm, '量化材料顶点');
    const delta: number = length(subtract(point, p));
    if (delta > this.request.dbuNm * Math.SQRT1_2 + this.request.dbuNm * 1e-7) message('材料量化误差超出半 DBU 对角线');
    if (delta > this.request.dbuNm * 1e-8) { this.quantized++; this.quantizationError = Math.max(this.quantizationError, delta); }
    return point;
  }
  private metrics(points: Point[]): LineMetrics {
    if (!Array.isArray(points) || points.length < 2 || points.length > (this.budget.maximumCenterlinePoints ?? 0)) message('中心线点数超出预算或少于 2');
    const result: Point[] = [], distances: number[] = [0]; let total: number = 0;
    for (const point of points) {
      this.charge(); result.push(exactPoint(point, this.request.dbuNm, '中心线'));
      if (result.length > 1) {
        const size: number = length(subtract(result[result.length - 1], result[result.length - 2]));
        if (!Number.isFinite(size) || size <= this.request.dbuNm * 1e-8) message('中心线含重复点或非有限线段');
        total += size; finite(total, '中心线长度', true); distances.push(total);
      }
    }
    return { points: result, distances: distances, length: total };
  }
  private checkAngles(line: LineMetrics, minimumRadius: number): void {
    const first: Point = line.points[0], last: Point = line.points[line.points.length - 1];
    const startCenter: Point = exactPoint(this.request.start.centerNm, this.request.dbuNm, 'start center');
    const endCenter: Point = exactPoint(this.request.end.centerNm, this.request.dbuNm, 'end center');
    if (first.x !== startCenter.x || first.y !== startCenter.y || last.x !== endCenter.x || last.y !== endCenter.y) message('中心线没有精确连接实际端口中心');
    const outward = (port: ResolvedPort): Point => { const angle: number = port.orientationDeg * Math.PI / 180; return { x: Math.cos(angle), y: Math.sin(angle) }; };
    if (dot(direction(first, line.points[1]), outward(this.request.start)) < 1 - 1e-10 ||
      dot(direction(last, line.points[line.points.length - 2]), outward(this.request.end)) < 1 - 1e-10) message('首末中心线切线与端口 outward frame 不一致');
    for (let i: number = 1; i < line.points.length - 1; i++) {
      this.charge();
      const incoming: Point = direction(line.points[i - 1], line.points[i]), outgoing: Point = direction(line.points[i], line.points[i + 1]);
      if (dot(incoming, outgoing) < -1 + 1e-10) message('中心线含 180° 反折');
      if (minimumRadius > 0 && Math.abs(cross(incoming, outgoing)) > 1e-10) {
        if (this.request.bendModel !== 'sampled-curve') message('CrossSection radius 要求真实圆滑采样曲线，不能用尖角 miter 替代');
        const a: number = length(subtract(line.points[i], line.points[i - 1])), b: number = length(subtract(line.points[i + 1], line.points[i]));
        const c: number = length(subtract(line.points[i + 1], line.points[i - 1]));
        const radius: number = c / (2 * Math.abs(cross(incoming, outgoing)));
        if (!Number.isFinite(a * b) || radius + this.request.dbuNm < minimumRadius) message('采样曲线实际局部半径小于 CrossSection 最小半径');
      }
    }
  }
  private offsetBoundary(line: LineMetrics, start: number, end: number): Point[] {
    const values: number[] = line.distances.map((distance: number): number => start + (end - start) * distance / line.length);
    const left: Point[] = [], right: Point[] = [];
    for (let i: number = 1; i < line.points.length; i++) {
      this.charge(); const n: Point = normal(direction(line.points[i - 1], line.points[i]));
      left.push(shifted(line.points[i - 1], n, values[i - 1])); right.push(shifted(line.points[i], n, values[i]));
    }
    const result: Point[] = [left[0]];
    for (let i: number = 1; i < line.points.length - 1; i++) {
      const incoming: Point = subtract(right[i - 1], left[i - 1]), outgoing: Point = subtract(right[i], left[i]);
      const denominator: number = cross(incoming, outgoing);
      const threshold: number = length(incoming) * length(outgoing) * 1e-12;
      let vertex: Point;
      if (Math.abs(denominator) <= threshold) {
        if (length(subtract(right[i - 1], left[i])) > this.request.dbuNm * 1e-6) message('相邻 offset 材料边界平行但不连续');
        vertex = right[i - 1];
      } else {
        const t: number = cross(subtract(left[i], left[i - 1]), outgoing) / denominator;
        vertex = { x: left[i - 1].x + incoming.x * t, y: left[i - 1].y + incoming.y * t };
      }
      const distance: number = length(subtract(vertex, line.points[i]));
      if (distance > Math.max(this.request.dbuNm, Math.abs(values[i])) * (this.budget.maximumMiterRatio ?? 0)) message('弯角材料 miter 超出明确预算');
      result.push(vertex);
    }
    result.push(right[right.length - 1]); return result;
  }
  private intersects(a: Point, b: Point, c: Point, d: Point): boolean {
    this.charge();
    if (Math.max(a.x, b.x) < Math.min(c.x, d.x) || Math.max(c.x, d.x) < Math.min(a.x, b.x) ||
      Math.max(a.y, b.y) < Math.min(c.y, d.y) || Math.max(c.y, d.y) < Math.min(a.y, b.y)) return false;
    const ab: Point = subtract(b, a), cd: Point = subtract(d, c);
    const orientation = (u: Point, v: Point): number => {
      const value: number = cross(u, v); const error: number = length(u) * length(v) * Number.EPSILON * 16;
      return Math.abs(value) <= error ? 0 : value < 0 ? -1 : 1;
    };
    return orientation(ab, subtract(c, a)) * orientation(ab, subtract(d, a)) <= 0 &&
      orientation(cd, subtract(a, c)) * orientation(cd, subtract(b, c)) <= 0;
  }
  private polygon(points: Point[], row: RouteLayerPair, category: 'material' | 'cut' | 'pad', capIndices: number[] = []): Shape {
    if (this.shapes.length >= (this.budget.maximumShapes ?? 0)) message('材料 shapes 超过预算');
    layer(row.layerNumber, row.datatype);
    const clean: Point[] = [];
    for (let i: number = 0; i < points.length; i++) {
      const p: Point = this.coordinate(points[i], capIndices.indexOf(i) >= 0);
      if (clean.length === 0 || p.x !== clean[clean.length - 1].x || p.y !== clean[clean.length - 1].y) clean.push(p);
    }
    if (clean.length > 1 && clean[0].x === clean[clean.length - 1].x && clean[0].y === clean[clean.length - 1].y) clean.pop();
    if (clean.length < 3) message('DBU 材料量化后退化为无面积图形');
    this.vertices += clean.length; if (this.vertices > (this.budget.maximumVertices ?? 0) || clean.length > 8190) message('材料顶点超过保存预算');
    let twiceArea: number = 0;
    const origin: Point = clean[0];
    for (let i: number = 0; i < clean.length; i++) {
      this.charge(); const a: Point = subtract(clean[i], origin), b: Point = subtract(clean[(i + 1) % clean.length], origin); twiceArea += cross(a, b);
      for (let j: number = i + 2; j < clean.length; j++) {
        if (i === 0 && j === clean.length - 1) continue;
        if (this.intersects(clean[i], clean[(i + 1) % clean.length], clean[j], clean[(j + 1) % clean.length])) message('材料 polygon 自交/自接触；弯角、宽度或 DBU 无法安全执行');
      }
    }
    if (!Number.isFinite(twiceArea) || Math.abs(twiceArea) < this.request.dbuNm * this.request.dbuNm * 1e-8) message('材料 polygon 没有有限正面积');
    if (twiceArea < 0) clean.reverse();
    const id: number = this.request.firstShapeId + this.shapes.length;
    if (!Number.isSafeInteger(id)) message('候选 shape ID 超出安全整数');
    const shape: Shape = { id: id, type: ShapeType.POLYGON, layerNumber: row.layerNumber, datatype: row.datatype,
      points: clean, selected: false, ownerCellId: this.request.ownerCellId };
    this.shapes.push(shape);
    if (category === 'material') this.materialIds.push(id); else if (category === 'cut') this.cutIds.push(id); else this.padIds.push(id);
    return shape;
  }
  private strip(line: LineMetrics, start: RouteMaterialBand, end: RouteMaterialBand): Shape {
    const low: Point[] = this.offsetBoundary(line, start.minimumNm, end.minimumNm), high: Point[] = this.offsetBoundary(line, start.maximumNm, end.maximumNm);
    const points: Point[] = low.concat(high.slice().reverse());
    return this.polygon(points, layerPair(start.layerNumber, start.datatype), 'material', [0, low.length - 1, low.length, points.length - 1]);
  }
  private rectangle(center: Point, halfX: number, halfY: number, row: RouteLayerPair, category: 'cut' | 'pad'): Shape {
    if (!(halfX > 0) || !(halfY > 0)) message('via cut/pad 没有正面积');
    const points: Point[] = [{ x: center.x - halfX, y: center.y - halfY }, { x: center.x + halfX, y: center.y - halfY },
      { x: center.x + halfX, y: center.y + halfY }, { x: center.x - halfX, y: center.y + halfY }];
    return this.polygon(points, row, category, [0, 1, 2, 3]);
  }
  private padContact(line: LineMetrics, row: RouteMaterialBand, halfX: number, halfY: number, atStart: boolean): void {
    const index: number = atStart ? 0 : line.points.length - 2;
    const n: Point = normal(direction(line.points[index], line.points[index + 1]));
    const extent: number = Math.min(Math.abs(n.x) < 1e-12 ? Infinity : halfX / Math.abs(n.x),
      Math.abs(n.y) < 1e-12 ? Infinity : halfY / Math.abs(n.y));
    if (!(Math.min(row.maximumNm, extent) > Math.max(row.minimumNm, -extent))) message('via pad 没有接触实际主材料；不能只画悬空 cut');
  }
  private split(line: LineMetrics, station: number): LineMetrics[] {
    let index: number = 1; while (index < line.distances.length && line.distances[index] < station) index++;
    if (index >= line.points.length || !(station > 0) || !(station < line.length)) message('via station 必须严格位于中心线内部');
    const ratio: number = (station - line.distances[index - 1]) / (line.distances[index] - line.distances[index - 1]);
    const p: Point = exactPoint({ x: line.points[index - 1].x + (line.points[index].x - line.points[index - 1].x) * ratio,
      y: line.points[index - 1].y + (line.points[index].y - line.points[index - 1].y) * ratio }, this.request.dbuNm, 'via station center');
    const before: Point[] = line.points.slice(0, index), after: Point[] = line.points.slice(index);
    if (before[before.length - 1].x !== p.x || before[before.length - 1].y !== p.y) before.push(p);
    if (after[0].x !== p.x || after[0].y !== p.y) after.unshift(p);
    return [this.metrics(before), this.metrics(after)];
  }
  private taper(line: LineMetrics, start: RouteMaterialBand, end: RouteMaterialBand, minimumLength: number, slope: number): void {
    if (line.length + this.request.dbuNm * 1e-8 < minimumLength ||
      Math.max(Math.abs(end.minimumNm - start.minimumNm), Math.abs(end.maximumNm - start.maximumNm)) / line.length > slope + 1e-12) message('taper 实际弧长/材料边缘斜率不满足明确规则');
  }
  private cap(port: ResolvedPort, d: Point, row: RouteMaterialBand): RouteMaterialCap {
    const n: Point = normal(d), low: Point = exactPoint(shifted(port.centerNm, n, row.minimumNm), this.request.dbuNm, '主材料端口 lower cap');
    const high: Point = exactPoint(shifted(port.centerNm, n, row.maximumNm), this.request.dbuNm, '主材料端口 upper cap');
    const actual: number = length(subtract(high, low));
    if (!close(actual, port.effectiveWidthNm)) message('实际端面宽度与端口有效 width 不一致');
    return { portId: port.definition.id, centerNm: clonePoint(port.centerNm), lowerEdgeNm: low, upperEdgeNm: high,
      layerNumber: row.layerNumber, datatype: row.datatype, expectedWidthNm: port.effectiveWidthNm, actualWidthNm: actual };
  }
  build(): RouteMaterialResult {
    if (!Number.isInteger(this.request.ownerCellId) || this.request.ownerCellId < 0 || !Number.isSafeInteger(this.request.firstShapeId) || this.request.firstShapeId < 1) message('输出归属 Cell/首 shape ID 无效');
    if (this.request.coordinatePolicy !== undefined && this.request.coordinatePolicy !== 'strict' && this.request.coordinatePolicy !== 'quantize-interior') message('未知材料坐标策略');
    if (this.request.bendModel !== undefined && this.request.bendModel !== 'miter-polyline' && this.request.bendModel !== 'sampled-curve') message('未知中心线 bendModel');
    const state: MaterialInspection = inspect(this.request);
    if (state.start.bands.length > (this.budget.maximumMaterials ?? 0)) message('材料数量超过执行预算');
    const line: LineMetrics = this.metrics(this.request.centerlineNm); this.checkAngles(line, state.profile.minimumBendRadiusNm);
    const startPrimary: RouteMaterialBand = primary(state.start), endPrimary: RouteMaterialBand = primary(state.end);
    const caps: RouteMaterialCap[] = [this.cap(this.request.start, direction(line.points[0], line.points[1]), startPrimary),
      this.cap(this.request.end, direction(line.points[line.points.length - 2], line.points[line.points.length - 1]), endPrimary)];
    const rule: RouteTransitionRule | undefined = state.rule;
    let split: LineMetrics[] | undefined;
    if (rule?.kind === 'via') {
      split = this.split(line, rule.stationNm);
      if (rule.stationNm <= state.profile.viaPadRadiusNm || line.length - rule.stationNm <= state.profile.viaPadRadiusNm) message('via pad 太靠近端口，不能保持 flush 端面');
    }
    const primaryIds: Set<number> = new Set<number>();
    for (let i: number = 0; i < state.start.bands.length; i++) {
      const a: RouteMaterialBand = state.start.bands[i], b: RouteMaterialBand = state.end.bands[i];
      if (a.id === state.start.primary && rule?.kind === 'via') {
        primaryIds.add(this.strip((split as LineMetrics[])[0], a, a).id); primaryIds.add(this.strip((split as LineMetrics[])[1], b, b).id);
      } else {
        const change: boolean = !close(a.minimumNm, b.minimumNm) || !close(a.maximumNm, b.maximumNm);
        if (rule?.kind === 'linear-taper') this.taper(line, a, b, rule.minimumLengthNm, rule.maximumEdgeSlope);
        else if (change && rule?.kind === 'via') this.taper(line, a, b, rule.auxiliaryTaperMinimumLengthNm as number, rule.auxiliaryMaximumEdgeSlope as number);
        const shape: Shape = this.strip(line, a, b); if (a.id === state.start.primary) primaryIds.add(shape.id);
      }
    }
    if (rule?.kind === 'via') {
      const center: Point = (split as LineMetrics[])[0].points[(split as LineMetrics[])[0].points.length - 1];
      const pitchX: number = rule.cutWidthNm + rule.gapXNm, pitchY: number = rule.cutHeightNm + rule.gapYNm;
      const halfX: number = (rule.columns * rule.cutWidthNm + (rule.columns - 1) * rule.gapXNm) / 2;
      const halfY: number = (rule.rows * rule.cutHeightNm + (rule.rows - 1) * rule.gapYNm) / 2;
      const startOnLower: boolean = startPrimary.layerNumber === rule.lowerLayerNumber && startPrimary.datatype === rule.lowerDatatype;
      this.padContact((split as LineMetrics[])[0], startPrimary,
        halfX + (startOnLower ? rule.lowerEnclosureXNm : rule.upperEnclosureXNm), halfY + (startOnLower ? rule.lowerEnclosureYNm : rule.upperEnclosureYNm), false);
      this.padContact((split as LineMetrics[])[1], endPrimary,
        halfX + (startOnLower ? rule.upperEnclosureXNm : rule.lowerEnclosureXNm), halfY + (startOnLower ? rule.upperEnclosureYNm : rule.lowerEnclosureYNm), true);
      for (let row: number = 0; row < rule.rows; row++) for (let col: number = 0; col < rule.columns; col++) {
        this.rectangle({ x: center.x + (col - (rule.columns - 1) / 2) * pitchX, y: center.y + (row - (rule.rows - 1) / 2) * pitchY },
          rule.cutWidthNm / 2, rule.cutHeightNm / 2, { layerNumber: rule.cutLayerNumber, datatype: rule.cutDatatype }, 'cut');
      }
      this.rectangle(center, halfX + rule.lowerEnclosureXNm, halfY + rule.lowerEnclosureYNm,
        { layerNumber: rule.lowerLayerNumber, datatype: rule.lowerDatatype }, 'pad');
      this.rectangle(center, halfX + rule.upperEnclosureXNm, halfY + rule.upperEnclosureYNm,
        { layerNumber: rule.upperLayerNumber, datatype: rule.upperDatatype }, 'pad');
    }
    // KFactory bbox sections are the axis-aligned bbox of the primary strip,
    // grown/shrunk by the declared offset. They are actual geometry, not a strip.
    if (state.start.bbox.length > 0) {
      let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
      for (const shape of this.shapes) if (primaryIds.has(shape.id)) for (const p of shape.points) {
        this.charge(); minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y);
      }
      for (const row of state.start.bbox) {
        const box: Point[] = [{ x: minX - row.offsetNm, y: minY - row.offsetNm }, { x: maxX + row.offsetNm, y: minY - row.offsetNm },
          { x: maxX + row.offsetNm, y: maxY + row.offsetNm }, { x: minX - row.offsetNm, y: maxY + row.offsetNm }];
        if (!(box[1].x > box[0].x) || !(box[2].y > box[0].y)) message('bboxSections 收缩后为空，未隐式丢材料');
        this.polygon(box, layerPair(row.layerNumber, row.datatype), 'material', [0, 1, 2, 3]);
      }
    }
    return { shapes: this.shapes, profile: state.profile, endpointCaps: caps, centerlineLengthNm: line.length,
      quantizedInteriorVertices: this.quantized, maximumQuantizationErrorNm: this.quantizationError,
      transitionRule: rule, materialShapeIds: this.materialIds, cutShapeIds: this.cutIds, padShapeIds: this.padIds,
      warnings: state.start.bbox.length > 0 ? ['bboxSections 生成整个主材料包围盒；事务必须对最终全部 polygon 再检查障碍物'] : [], workUsed: this.work };
  }
}

/** Pure, all-or-nothing material execution. Caller seals endpoints and commits
 * all returned shapes in one existing EditService structure transaction. */
export class RouteMaterialService {
  inspect(request: RouteMaterialInspectRequest): RouteMaterialProfile { return inspect(request).profile; }
  inspectExecution(request: RouteMaterialInspectRequest): RouteMaterialExecution {
    const state: MaterialInspection = inspect(request);
    return { profile: state.profile, bboxSections: cloneStructured(state.start.bbox) as RouteMaterialBboxSection[], transitionRule: state.rule };
  }
  build(request: RouteMaterialRequest): RouteMaterialResult { return new MaterialBuilder(request).build(); }
}
export const routeMaterialService: RouteMaterialService = new RouteMaterialService();
