import { util } from '@kit.ArkTS';
import type { NativeLayoutPort, NativeLayoutCrossSection, LayoutContextRecord } from '../../cpp/types/libhongtu/Index';
import type { InstancePathStep } from '../services/EditService';
import type { Point } from './GdsiiData';
import { clonePortModel, cloneStructured } from '../common/CloneUtils';
export type { LayoutContextRecord } from '../../cpp/types/libhongtu/Index';

export interface LayoutPort extends NativeLayoutPort {}
export interface LayoutCrossSection extends NativeLayoutCrossSection {}
export interface LayoutPortDraft {
  name: string; centerNm: Point; orientationDeg: number; widthNm: number;
  layerNumber: number; datatype: number; portType: string;
  frameMirror: boolean; frameMagnification: number;
  crossSectionKey?: string; crossSectionVersion?: number; infoJson: string; provenance?: string;
}
export interface PortEndpoint { portId: string; rootCellId: number; rootCellKey: string; path: InstancePathStep[]; }
export interface ResolvedPort {
  definition: LayoutPort; endpoint: PortEndpoint; centerNm: Point; orientationDeg: number;
  frameMirror: boolean; frameMagnification: number; effectiveWidthNm: number;
}
/** Optional only at legacy, in-memory call boundaries. Persisted Workspace v2 is strict. */
export interface LayoutSemanticState {
  cellKeys?: string[]; ports?: LayoutPort[]; crossSections?: LayoutCrossSection[];
  layoutContextRecords?: LayoutContextRecord[]; cellContextRecords?: LayoutContextRecord[][];
}
export const MAX_LAYOUT_PORTS: number = 100000;
export const MAX_CROSS_SECTIONS: number = 4096;
export const CELL_KEY_META_NAME: string = 'hongtu:cell_key:v1';
export const CELL_PORTS_META_NAME: string = 'hongtu:ports:v1';
export const CROSS_SECTIONS_META_NAME: string = 'hongtu:cross_sections:v1';
export const CELL_LINEAGE_META_NAME: string = 'hongtu:cell_lineage:v1';

export function newLayoutIdentity(prefix: string = 'cell'): string { return `${prefix}-${util.generateRandomUUID(true)}`; }
export function clonePort(port: LayoutPort): LayoutPort { return clonePortModel(port) as LayoutPort; }
export function cloneSemanticState(source: LayoutSemanticState): LayoutSemanticState {
  return cloneStructured(source) as LayoutSemanticState;
}
export function normalizePortAngle(degrees: number): number { return ((degrees % 360) + 360) % 360; }
/** Count actual UTF-8 bytes and reject lone UTF-16 surrogates before native encoding. */
export function layoutUtf8Bytes(value: string): number {
  let size: number = 0;
  for (let i: number = 0; i < value.length; i++) {
    const code: number = value.charCodeAt(i);
    if (code < 128) size++;
    else if (code < 2048) size += 2;
    else if (code >= 0xd800 && code <= 0xdbff) {
      const low: number = value.charCodeAt(++i);
      if (!(low >= 0xdc00 && low <= 0xdfff)) throw new Error('元数据含无效 UTF-16 字符');
      size += 4;
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('元数据含无效 UTF-16 字符');
    else size += 3;
  }
  return size;
}
function text(value: string, maxBytes: number, allowEmpty: boolean = false): boolean {
  return typeof value === 'string' && (allowEmpty || value.length > 0) && !value.includes('\u0000') && layoutUtf8Bytes(value) <= maxBytes;
}
function jsonObject(value: string, maxBytes: number, maxDepth: number = 32): void {
  if (!text(value, maxBytes)) throw new Error('端口 JSON 元数据超出预算或无效');
  const parsed: Object = JSON.parse(value) as Object;
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('端口元数据须为 JSON 对象');
  // Match native inert JSON: the root is depth zero, dictionary keys do not
  // count, and every value (including scalar/null) consumes one node.
  const queue: Object[] = [parsed]; const depths: number[] = [0]; let visited: number = 0;
  for (let at: number = 0; at < queue.length; at++) {
    if (depths[at] > maxDepth || ++visited > 8192) throw new Error('端口 JSON 嵌套或节点超出可保存预算');
    const item: Object = queue[at];
    if (typeof item === 'number' && !Number.isFinite(item as number)) throw new Error('端口 JSON 含非有限数值');
    if (item === null || typeof item !== 'object') continue;
    const record: Record<string, Object> = item as Record<string, Object>;
    for (const key of Object.keys(item)) {
      if (key === '__proto__' || key === 'constructor' || key === 'prototype') throw new Error('端口 JSON 含保留键');
      const child: Object = record[key];
      queue.push(child); depths.push(depths[at] + 1);
    }
  }
}
export function validatePortDraft(port: LayoutPortDraft): void {
  if (port === null || !text(port.name, 512) || port.centerNm === null || port.centerNm === undefined ||
    !Number.isFinite(port.centerNm.x) || !Number.isFinite(port.centerNm.y) ||
    !Number.isFinite(port.orientationDeg) || !Number.isFinite(port.widthNm) || port.widthNm <= 0 ||
    !Number.isInteger(port.layerNumber) || port.layerNumber < 0 || port.layerNumber > 32767 ||
    !Number.isInteger(port.datatype) || port.datatype < 0 || port.datatype > 32767 || !text(port.portType, 128) ||
    typeof port.frameMirror !== 'boolean' || !Number.isFinite(port.frameMagnification) || port.frameMagnification <= 0 ||
    !Number.isFinite(port.widthNm * port.frameMagnification)) throw new Error('端口名称、坐标、图层或完整 frame 无效');
  if ((port.crossSectionKey === undefined) !== (port.crossSectionVersion === undefined) ||
    (port.crossSectionKey !== undefined && (!text(port.crossSectionKey, 512) || !Number.isSafeInteger(port.crossSectionVersion) ||
      (port.crossSectionVersion as number) < 1))) throw new Error('端口 CrossSection 引用无效');
  // Generated KF port metadata wraps info in one outer dictionary. Its reader
  // permits depth32, leaving depth31 for the independently parsed info value.
  jsonObject(port.infoJson, 64 * 1024, 31);
  if (port.provenance !== undefined) jsonObject(port.provenance, 64 * 1024);
}
export function portDraft(port: LayoutPort): LayoutPortDraft {
  return { name: port.name, centerNm: { x: port.centerNm.x, y: port.centerNm.y }, orientationDeg: port.orientationDeg,
    widthNm: port.widthNm, layerNumber: port.layerNumber, datatype: port.datatype, portType: port.portType,
    frameMirror: port.frameMirror, frameMagnification: port.frameMagnification, crossSectionKey: port.crossSectionKey,
    crossSectionVersion: port.crossSectionVersion, infoJson: port.infoJson, provenance: port.provenance };
}
export function portFromDraft(id: string, ownerCellId: number, ownerCellKey: string, draft: LayoutPortDraft): LayoutPort {
  validatePortDraft(draft);
  const port: LayoutPort = { id: id, ownerCellId: ownerCellId, ownerCellKey: ownerCellKey, name: draft.name,
    centerNm: { x: draft.centerNm.x, y: draft.centerNm.y }, orientationDeg: normalizePortAngle(draft.orientationDeg),
    widthNm: draft.widthNm, layerNumber: draft.layerNumber, datatype: draft.datatype, portType: draft.portType,
    frameMirror: draft.frameMirror, frameMagnification: draft.frameMagnification, infoJson: draft.infoJson };
  if (draft.crossSectionKey !== undefined) { port.crossSectionKey = draft.crossSectionKey; port.crossSectionVersion = draft.crossSectionVersion; }
  if (draft.provenance !== undefined) port.provenance = draft.provenance;
  return port;
}
export function normalizeLayoutSemantics(state: LayoutSemanticState, cellCount: number, strict: boolean = false): void {
  if (strict && (state.cellKeys === undefined || state.ports === undefined || state.crossSections === undefined ||
    state.layoutContextRecords === undefined || state.cellContextRecords === undefined)) throw new Error('工程 v2 缺少稳定 Cell/Port/context 元数据');
  if (state.cellKeys === undefined) {
    state.cellKeys = [];
    for (let index: number = 0; index < cellCount; index++) state.cellKeys.push(newLayoutIdentity());
  }
  if (state.ports === undefined) state.ports = [];
  if (state.crossSections === undefined) state.crossSections = [];
  if (state.layoutContextRecords === undefined) state.layoutContextRecords = [];
  if (state.cellContextRecords === undefined) {
    state.cellContextRecords = [];
    for (let index: number = 0; index < cellCount; index++) state.cellContextRecords.push([]);
  }
  validateLayoutSemantics(state, cellCount);
}
export function validateLayoutSemantics(state: LayoutSemanticState, cellCount: number): void {
  const keys: string[] = state.cellKeys ?? [], ports: LayoutPort[] = state.ports ?? [], sections: LayoutCrossSection[] = state.crossSections ?? [];
  if (!Array.isArray(keys) || keys.length !== cellCount || keys.some((key: string): boolean => !text(key, 512)) ||
    new Set<string>(keys).size !== keys.length || !Array.isArray(ports) || ports.length > MAX_LAYOUT_PORTS ||
    !Array.isArray(sections) || sections.length > MAX_CROSS_SECTIONS) throw new Error('稳定 Cell 身份或端口集合无效');
  const xs: Set<string> = new Set<string>();
  const definitions: Map<string, Record<string, Object>> = new Map<string, Record<string, Object>>();
  let bytes: number = layoutUtf8Bytes(JSON.stringify(keys));
  for (const section of sections) {
    if (section === null || !text(section.key, 512) || !Number.isSafeInteger(section.version) || section.version < 1 ||
      !text(section.name, 512) || xs.has(`${section.key}:${section.version}`)) throw new Error('CrossSection 身份无效或重复');
    jsonObject(section.definitionJson, 256 * 1024); xs.add(`${section.key}:${section.version}`);
    definitions.set(`${section.key}:${section.version}`, JSON.parse(section.definitionJson) as Record<string, Object>);
    bytes += layoutUtf8Bytes(JSON.stringify(section));
    if (section.sourceFormat !== undefined && !text(section.sourceFormat, 128)) throw new Error('CrossSection 来源格式无效');
    if (section.sourceVersion !== undefined && !text(section.sourceVersion, 128)) throw new Error('CrossSection 来源版本无效');
  }
  const ids: Set<string> = new Set<string>(), names: Set<string> = new Set<string>();
  for (const port of ports) {
    if (port === null || !text(port.id, 512) || ids.has(port.id) || !Number.isInteger(port.ownerCellId) || port.ownerCellId < 0 ||
      port.ownerCellId >= cellCount || port.ownerCellKey !== keys[port.ownerCellId] || names.has(`${port.ownerCellKey}\u0000${port.name}`)) throw new Error('端口身份、Cell 归属或名称重复');
    validatePortDraft(portDraft(port)); ids.add(port.id); names.add(`${port.ownerCellKey}\u0000${port.name}`);
    if (port.crossSectionKey !== undefined && !xs.has(`${port.crossSectionKey}:${port.crossSectionVersion}`)) throw new Error('端口引用缺失 CrossSection');
    if (port.crossSectionKey !== undefined) {
      const definition: Record<string, Object> | undefined = definitions.get(`${port.crossSectionKey}:${port.crossSectionVersion}`);
      if (definition !== undefined && definition['schemaVersion'] === 1 && (definition['kind'] === 'symmetric' || definition['kind'] === 'asymmetric') &&
        (definition['widthNm'] !== port.widthNm || definition['layerNumber'] !== port.layerNumber || definition['datatype'] !== port.datatype)) throw new Error('端口宽度或主图层与 CrossSection 描述符不一致');
    }
    bytes += layoutUtf8Bytes(JSON.stringify(port));
  }
  if (!Array.isArray(state.layoutContextRecords) || !Array.isArray(state.cellContextRecords) || state.cellContextRecords.length !== cellCount) throw new Error('context 归属索引无效');
  if (bytes > 64 * 1024 * 1024) throw new Error('端口与 context 总字节超过 64 MiB 预算');
  for (const records of [state.layoutContextRecords].concat(state.cellContextRecords)) {
    if (!Array.isArray(records) || records.length > 65536) throw new Error('context 记录数超出预算');
    for (const record of records) {
      if (record === null || typeof record.value !== 'string' || (record.encoding !== 'utf8' && record.encoding !== 'hex') ||
        (record.encoding === 'hex' && (record.value.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(record.value)))) throw new Error('context 字节编码无效');
      const size: number = record.encoding === 'hex' ? record.value.length / 2 : layoutUtf8Bytes(record.value);
      if (size > 8 * 1024 * 1024) throw new Error('单条 context 超出 8 MiB 预算');
      bytes += size; if (bytes > 64 * 1024 * 1024) throw new Error('context 总字节超过 64 MiB 预算');
    }
  }
}
/** Append an independent Cell definition. Geometry caller has already appended its name/properties. */
export function appendCellSemantics(state: LayoutSemanticState, sourceCellId?: number, provenanceKind: string = 'duplicate',
  includePort?: (port: LayoutPort) => boolean): Map<string, string> {
  const keys: string[] = state.cellKeys ?? [], records: LayoutContextRecord[][] = state.cellContextRecords ?? [], ports: LayoutPort[] = state.ports ?? [];
  const target: number = keys.length, key: string = newLayoutIdentity(); keys.push(key);
  records.push(sourceCellId === undefined ? [] : cloneStructured(records[sourceCellId] ?? []) as LayoutContextRecord[]);
  const mapping: Map<string, string> = new Map<string, string>();
  for (const port of ports.slice()) {
    if (port.ownerCellId !== sourceCellId || (includePort !== undefined && !includePort(port))) continue;
    const copy: LayoutPort = clonePort(port); copy.id = newLayoutIdentity('port'); copy.ownerCellId = target; copy.ownerCellKey = key;
    copy.provenance = JSON.stringify({ kind: provenanceKind, sourcePortId: port.id, sourceCellKey: port.ownerCellKey, previous: port.provenance ?? '' });
    if (provenanceKind !== 'clip-static' && provenanceKind !== 'subset-static' && port.provenance !== undefined) {
      const source: Record<string, Object> = JSON.parse(port.provenance) as Record<string, Object>;
      if (source['kind'] === 'pcell-generated') copy.provenance = JSON.stringify({ kind: 'pcell-generated', lineageKind: provenanceKind,
        sourcePortId: port.id, sourceCellKey: port.ownerCellKey, previous: port.provenance });
    }
    mapping.set(port.id, copy.id); ports.push(copy);
  }
  state.cellKeys = keys; state.cellContextRecords = records; state.ports = ports;
  if (sourceCellId !== undefined) markCellLineage(state, target, provenanceKind, keys[sourceCellId]);
  return mapping;
}
/** Reindex using numeric mapping, while keeping stable identities and context payload/order. */
export function remapCellSemantics(state: LayoutSemanticState, mapping: number[]): void {
  const sourceKeys: string[] = state.cellKeys ?? [], sourceRecords: LayoutContextRecord[][] = state.cellContextRecords ?? [];
  const keys: string[] = [], records: LayoutContextRecord[][] = [];
  for (let old: number = 0; old < mapping.length; old++) if (mapping[old] >= 0) { keys[mapping[old]] = sourceKeys[old]; records[mapping[old]] = sourceRecords[old] ?? []; }
  state.ports = (state.ports ?? []).filter((port: LayoutPort): boolean => mapping[port.ownerCellId] >= 0).map((port: LayoutPort): LayoutPort => {
    const copy: LayoutPort = clonePort(port); copy.ownerCellId = mapping[port.ownerCellId]; copy.ownerCellKey = keys[copy.ownerCellId]; return copy;
  });
  state.cellKeys = keys; state.cellContextRecords = records;
}

/** Generated endpoints are explicit generator output, never inferred from arbitrary TEXT. */
export function reconcileGeneratedPorts(state: LayoutSemanticState, ownerCellId: number, generated: LayoutPortDraft[]): void {
  const key: string = (state.cellKeys ?? [])[ownerCellId];
  if (key === undefined || !Array.isArray(generated) || generated.length > MAX_LAYOUT_PORTS) throw new Error('PCell 端口生成上下文无效');
  const previous: Map<string, LayoutPort> = new Map<string, LayoutPort>();
  const retained: LayoutPort[] = [];
  for (const port of state.ports ?? []) {
    let generatedHere: boolean = false;
    if (port.ownerCellId === ownerCellId && port.provenance !== undefined) {
      const provenance: Record<string, Object> = JSON.parse(port.provenance) as Record<string, Object>;
      generatedHere = provenance['kind'] === 'pcell-generated';
    }
    if (generatedHere) previous.set(`${port.portType}\u0000${port.name}`, port); else retained.push(port);
  }
  for (const draft of generated) {
    const old: LayoutPort | undefined = previous.get(`${draft.portType}\u0000${draft.name}`);
    const copy: LayoutPort = portFromDraft(old?.id ?? newLayoutIdentity('port'), ownerCellId, key, draft);
    copy.provenance = JSON.stringify({ kind: 'pcell-generated', semanticKey: `${draft.portType}:${draft.name}`, generatorProvenance: draft.provenance ?? '' });
    retained.push(copy);
  }
  state.ports = retained; validateLayoutSemantics(state, (state.cellKeys ?? []).length);
}

export interface PortCrossSectionDefinition {
  schemaVersion: number; kind: string; widthNm: number; layerNumber: number; datatype: number;
  sectionMinNm?: number; sectionMaxNm?: number;
}
/** Known descriptor edits create a new version; opaque foreign definitions are retained and refused. */
export function reconcilePortCrossSection(state: LayoutSemanticState, previous: LayoutPort | undefined, draft: LayoutPortDraft): LayoutPortDraft {
  const result: LayoutPortDraft = cloneStructured(draft) as LayoutPortDraft;
  if (draft.crossSectionKey === undefined) return result;
  const section: LayoutCrossSection | undefined = (state.crossSections ?? []).find((item: LayoutCrossSection): boolean =>
    item.key === draft.crossSectionKey && item.version === draft.crossSectionVersion);
  if (section === undefined) throw new Error('端口缺少 CrossSection 定义');
  const definition: PortCrossSectionDefinition = JSON.parse(section.definitionJson) as PortCrossSectionDefinition;
  const known: boolean = definition.schemaVersion === 1 && (definition.kind === 'symmetric' || definition.kind === 'asymmetric') &&
    Number.isFinite(definition.widthNm) && Number.isInteger(definition.layerNumber) && Number.isInteger(definition.datatype);
  if (!known) {
    if (previous === undefined || previous.crossSectionKey !== draft.crossSectionKey || previous.crossSectionVersion !== draft.crossSectionVersion ||
      previous.widthNm !== draft.widthNm || previous.layerNumber !== draft.layerNumber || previous.datatype !== draft.datatype) {
      throw new Error('未知 CrossSection 仅可保持原 width/layer；不能产生陈旧描述符');
    }
    return result;
  }
  if (definition.widthNm === draft.widthNm && definition.layerNumber === draft.layerNumber && definition.datatype === draft.datatype) return result;
  if (definition.kind === 'asymmetric' && draft.widthNm !== definition.widthNm) throw new Error('非对称 CrossSection 改宽需显式更新全部 section 定义');
  const updated: Record<string, Object> = JSON.parse(section.definitionJson) as Record<string, Object>;
  updated['widthNm'] = draft.widthNm; updated['layerNumber'] = draft.layerNumber; updated['datatype'] = draft.datatype;
  const version: number = (state.crossSections ?? []).filter((item: LayoutCrossSection): boolean => item.key === section.key)
    .reduce((maximum: number, item: LayoutCrossSection): number => Math.max(maximum, item.version), 0) + 1;
  const copy: LayoutCrossSection = cloneStructured(section) as LayoutCrossSection;
  copy.version = version; copy.definitionJson = JSON.stringify(updated); (state.crossSections ?? []).push(copy);
  result.crossSectionVersion = version; return result;
}

export interface SemanticMergeResult { portIds: Map<string, string>; crossSectionKeys: Map<string, string>; }
/** Target Cell identities are allocated by the owning structural planner. */
export function mergeLayoutSemantics(target: LayoutSemanticState, source: LayoutSemanticState, mapping: number[],
  includePort?: (port: LayoutPort) => boolean): SemanticMergeResult {
  const incoming: LayoutSemanticState = cloneSemanticState(source); normalizeLayoutSemantics(incoming, mapping.length);
  const keys: string[] = target.cellKeys ?? [], records: LayoutContextRecord[][] = target.cellContextRecords ?? [];
  let count: number = keys.length;
  for (const id of mapping) count = Math.max(count, id + 1);
  while (keys.length < count) keys.push(newLayoutIdentity());
  while (records.length < count) records.push([]);
  target.cellKeys = keys; target.cellContextRecords = records;
  if (target.ports === undefined) target.ports = [];
  if (target.crossSections === undefined) target.crossSections = [];
  if (target.layoutContextRecords === undefined) target.layoutContextRecords = [];
  const sectionKeys: Map<string, string> = new Map<string, string>(), portIds: Map<string, string> = new Map<string, string>();
  for (const section of incoming.crossSections ?? []) {
    const identity: string = `${section.key}:${section.version}`;
    const existing: LayoutCrossSection | undefined = target.crossSections.find((item: LayoutCrossSection): boolean => item.key === section.key && item.version === section.version);
    if (existing !== undefined && JSON.stringify(existing) === JSON.stringify(section)) { sectionKeys.set(identity, existing.key); continue; }
    const copy: LayoutCrossSection = cloneStructured(section) as LayoutCrossSection;
    if (existing !== undefined) copy.key = newLayoutIdentity('xs');
    target.crossSections.push(copy); sectionKeys.set(identity, copy.key);
  }
  const populated: Set<number> = new Set<number>();
  for (let sourceId: number = 0; sourceId < mapping.length; sourceId++) {
    const id: number = mapping[sourceId]; if (id < 0) continue;
    if (!Number.isInteger(id) || id >= count || populated.has(id)) throw new Error('语义导入 Cell 映射无效或重复');
    populated.add(id); records[id] = records[id].concat(cloneStructured((incoming.cellContextRecords ?? [])[sourceId] ?? []) as LayoutContextRecord[]);
  }
  for (const port of incoming.ports ?? []) {
    const owner: number = mapping[port.ownerCellId]; if (owner < 0 || (includePort !== undefined && !includePort(port))) continue;
    const copy: LayoutPort = clonePort(port); copy.id = newLayoutIdentity('port'); copy.ownerCellId = owner; copy.ownerCellKey = keys[owner];
    if (copy.crossSectionKey !== undefined) copy.crossSectionKey = sectionKeys.get(`${copy.crossSectionKey}:${copy.crossSectionVersion}`) as string;
    copy.provenance = JSON.stringify({ kind: 'import-snapshot', sourcePortId: port.id, sourceCellKey: port.ownerCellKey, previous: port.provenance ?? '' });
    target.ports.push(copy); portIds.set(port.id, copy.id);
  }
  target.layoutContextRecords = target.layoutContextRecords.concat(incoming.layoutContextRecords ?? []);
  validateLayoutSemantics(target, count); return { portIds: portIds, crossSectionKeys: sectionKeys };
}

export function canonicalCellPortSemantics(state: LayoutSemanticState, cellId: number): string {
  const ports: string[] = (state.ports ?? []).filter((port: LayoutPort): boolean => port.ownerCellId === cellId).map((port: LayoutPort): string => {
    const section: LayoutCrossSection | undefined = (state.crossSections ?? []).find((item: LayoutCrossSection): boolean =>
      item.key === port.crossSectionKey && item.version === port.crossSectionVersion);
    return JSON.stringify([port.name, port.centerNm, port.orientationDeg, port.widthNm, port.layerNumber, port.datatype, port.portType,
      port.frameMirror, port.frameMagnification, port.infoJson, section?.definitionJson, section?.sourceFormat, section?.sourceVersion, port.provenance]);
  }).sort();
  return JSON.stringify([ports, (state.cellContextRecords ?? [])[cellId] ?? []]);
}

export interface PortLayerMapping { sourceLayer: number; sourceDatatype: number; action: 'map' | 'drop'; targetLayer?: number; targetDatatype?: number; }
/** Apply an explicit import layer map to endpoints and every known descriptor section. */
export function remapPortLayers(state: LayoutSemanticState, mappings: PortLayerMapping[]): number {
  const byLayer: Map<string, PortLayerMapping> = new Map<string, PortLayerMapping>();
  for (const mapping of mappings) byLayer.set(`${mapping.sourceLayer}/${mapping.sourceDatatype}`, mapping);
  const retained: LayoutPort[] = []; let dropped: number = 0;
  const changedSections: Set<string> = new Set<string>();
  for (const port of state.ports ?? []) {
    const mapping: PortLayerMapping | undefined = byLayer.get(`${port.layerNumber}/${port.datatype}`);
    if (mapping?.action === 'drop') { assertPortRemovalSafe(state, port); dropped++; continue; }
    if (mapping?.action === 'map') {
      if (port.crossSectionKey !== undefined) changedSections.add(`${port.crossSectionKey}:${port.crossSectionVersion}`);
      port.layerNumber = mapping.targetLayer as number; port.datatype = mapping.targetDatatype as number;
    }
    retained.push(port);
  }
  state.ports = retained;
  state.crossSections = (state.crossSections ?? []).filter((section: LayoutCrossSection): boolean => {
    const object: Record<string, Object> = JSON.parse(section.definitionJson) as Record<string, Object>;
    const known: boolean = object['schemaVersion'] === 1 && (object['kind'] === 'symmetric' || object['kind'] === 'asymmetric');
    if (!known) { if (changedSections.has(`${section.key}:${section.version}`)) throw new Error('未知 CrossSection 不能随图层映射产生陈旧描述符'); return true; }
    const primary: PortLayerMapping | undefined = byLayer.get(`${object['layerNumber']}/${object['datatype']}`);
    if (primary?.action === 'drop') {
      if (retained.some((port: LayoutPort): boolean => port.crossSectionKey === section.key && port.crossSectionVersion === section.version)) throw new Error('丢弃 CrossSection 主层会留下端口引用');
      return false;
    }
    const queue: Object[] = [object];
    for (let at: number = 0; at < queue.length; at++) {
      const record: Record<string, Object> = queue[at] as Record<string, Object>;
      if (!Array.isArray(record) && typeof record['layerNumber'] === 'number' && typeof record['datatype'] === 'number') {
        const mapping: PortLayerMapping | undefined = byLayer.get(`${record['layerNumber']}/${record['datatype']}`);
        if (mapping?.action === 'map') { record['layerNumber'] = mapping.targetLayer as number; record['datatype'] = mapping.targetDatatype as number; }
      }
      for (const key of Object.keys(record)) {
        const child: Object = record[key];
        if (Array.isArray(child)) {
          const items: Object[] = child as Object[];
          record[key] = items.filter((item: Object): boolean => {
            if (item === null || typeof item !== 'object') return true;
            const value: Record<string, Object> = item as Record<string, Object>;
            return byLayer.get(`${value['layerNumber']}/${value['datatype']}`)?.action !== 'drop';
          });
          for (const item of record[key] as Object[]) if (item !== null && typeof item === 'object') queue.push(item);
        } else if (child !== null && typeof child === 'object') queue.push(child);
      }
    }
    section.definitionJson = JSON.stringify(object); return true;
  });
  return dropped;
}

function variantQuoted(value: string): string { return `'${value.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`; }
/** Exact KLayout Variant string syntax, independently consumed by the fixed codec. */
export function markCellLineage(state: LayoutSemanticState, cellId: number, kind: string, sourceCellKey: string): void {
  if (!text(kind, 128) || !text(sourceCellKey, 512) || !Number.isInteger(cellId) || cellId < 0 ||
    cellId >= (state.cellKeys ?? []).length) throw new Error('Cell lineage 归属无效');
  const records: LayoutContextRecord[][] = state.cellContextRecords ?? [];
  const prefix: string = `META('${CELL_LINEAGE_META_NAME}')=`;
  const current: LayoutContextRecord[] = records[cellId] ?? [];
  const old: LayoutContextRecord[] = current.filter((record: LayoutContextRecord): boolean => record.encoding === 'utf8' && record.value.startsWith(prefix));
  if (old.length > 1) throw new Error('Cell lineage META 重复');
  const payload: string = JSON.stringify({ schemaVersion: 1, kind: kind, sourceCellKey: sourceCellKey });
  const record: LayoutContextRecord = { encoding: 'utf8', value: prefix + variantQuoted(payload) };
  if (old.length === 1) records[cellId] = current.map((item: LayoutContextRecord): LayoutContextRecord => item === old[0] ? record : item);
  else records[cellId] = current.concat([record]);
  state.cellContextRecords = records;
}

/** Existing foreign pins are not a port-list editing permission. Preserve them
 * and reject deletion until the pinned index can be changed in a complete pin transaction. */
export function assertPortRemovalSafe(state: LayoutSemanticState, port: LayoutPort): void {
  if (port.provenance === undefined) return;
  const source: Record<string, Object> = JSON.parse(port.provenance) as Record<string, Object>;
  if (source['kind'] !== 'foreign' || source['format'] !== 'kfactory') return;
  for (const record of (state.cellContextRecords ?? [])[port.ownerCellId] ?? []) {
    let raw: string = record.value;
    if (record.encoding === 'hex') { raw = ''; for (let index: number = 0; index < record.value.length; index += 2) raw += String.fromCharCode(parseInt(record.value.substring(index, index + 2), 16)); }
    if (raw.startsWith("META('kfactory:pins:") || raw.startsWith('META("kfactory:pins:')) throw new Error('Cell 含 foreign KFactory pins；删除端口需完整 pin 索引事务，原端口与上下文已保留');
  }
}
