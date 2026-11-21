import { util } from '@kit.ArkTS';
import { LayoutSemanticState, LayoutPort, LayoutCrossSection, LayoutContextRecord, validateLayoutSemantics, layoutUtf8Bytes } from '../models/LayoutPort';

interface SectionRow { layerNumber: number; datatype: number; minNm?: number; maxNm: number; }
interface BboxRow { layerNumber: number; datatype: number; offsetNm: number; }
interface EnclosureDefinition { name: string; sections: SectionRow[]; bboxSections?: BboxRow[]; }
interface CrossSectionDefinition {
  schemaVersion: number; kind: string; widthNm: number; layerNumber: number; datatype: number;
  enclosure: EnclosureDefinition; sectionMinNm?: number; sectionMaxNm?: number; radiusNm?: number; radiusMinNm?: number;
  sections?: SectionRow[];
}
interface ForeignPortProvenance { kind: string; format?: string; metaFormat?: string; metaName?: string; portIndex?: number; ownerCellKey?: string; }
interface CellLineage { schemaVersion: number; kind: string; sourceCellKey?: string; }
interface OwnedPortsEnvelope { schemaVersion: number; ports: LayoutPort[]; }
interface OwnedCrossSectionsEnvelope { schemaVersion: number; crossSections: LayoutCrossSection[]; }
export interface PortContextPayload { layout: LayoutContextRecord[]; cells: LayoutContextRecord[][]; }

export function contextRecordBytes(record: LayoutContextRecord): number[] {
  if (record.encoding === 'utf8') {
    layoutUtf8Bytes(record.value);
    return Array.from(new util.TextEncoder().encodeInto(record.value));
  }
  if (record.encoding !== 'hex' || !/^(?:[0-9a-fA-F]{2})*$/.test(record.value)) throw new Error('context 十六进制无效');
  const bytes: number[] = [];
  for (let i: number = 0; i < record.value.length; i += 2) bytes.push(Number.parseInt(record.value.substring(i, i + 2), 16));
  return bytes;
}
export function contextRecordText(record: LayoutContextRecord): string {
  if (record.encoding === 'utf8') return record.value;
  try { return new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(new Uint8Array(contextRecordBytes(record))); }
  catch (_error) { return ''; } // Binary unknown records are retained, never interpreted.
}
export function variantString(value: string): string {
  let out: string = "'";
  for (const byte of new util.TextEncoder().encodeInto(value)) {
    if (byte === 39 || byte === 92) out += '\\' + String.fromCharCode(byte);
    else if (byte < 32 || byte >= 127) out += '\\' + byte.toString(8).padStart(3, '0');
    else out += String.fromCharCode(byte);
  }
  return out + "'";
}
function variant(value: Object): string {
  if (value === null) return 'nil';
  if (typeof value === 'string') return variantString(value as string);
  if (typeof value === 'number') {
    const n: number = value as number;
    if (!Number.isFinite(n)) throw new Error('META 含非有限数值');
    return (Number.isInteger(n) ? '#' : '##') + n.toString();
  }
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (Array.isArray(value)) return '(' + (value as Object[]).map((item: Object): string => variant(item)).join(',') + ')';
  const record: Record<string, Object> = value as Record<string, Object>;
  return '{' + Object.keys(value).map((key: string): string => variantString(key) + '=>' + variant(record[key])).join(',') + '}';
}
/** Same generated-owned JSON depth/node limits as the production native reader. */
export function ownedMetadataJson(value: Object): string {
  const json: string = JSON.stringify(value); let nodes: number = 0;
  const visit: (entry: Object, depth: number) => void = (entry: Object, depth: number): void => {
    if (depth > 32 || ++nodes > 300000) throw new Error('生成端口 META JSON 嵌套/节点预算超限');
    if (Array.isArray(entry)) { for (const item of entry as Object[]) visit(item, depth + 1); }
    else if (entry !== null && typeof entry === 'object') {
      const record: Record<string, Object> = entry as Record<string, Object>;
      for (const key of Object.keys(record)) visit(record[key], depth + 1);
    }
  };
  visit(JSON.parse(json) as Object, 0); return json;
}
/** Extract only the META key. Unknown values and Variant classes remain opaque. */
function metaKey(record: LayoutContextRecord): string {
  const text: string = contextRecordText(record);
  const match: RegExpMatchArray | null = text.match(/^META\((?:'((?:\\.|[^'])*)'|"((?:\\.|[^"])*)"|([^,)]+))(?:,[^)]*)?\)=/);
  if (match === null) return '';
  return match[1] ?? match[2] ?? match[3] ?? '';
}
/** Structural budget scan of a generated TL value; strings/typed tokens are inert atoms. */
function validateGeneratedVariant(raw: string): void {
  let at: number = 0, nodes: number = 0;
  const space: () => void = (): void => { while (at < raw.length && /\s/.test(raw[at])) at++; };
  const read: (depth: number) => void = (depth: number): void => {
    space(); if (depth > 32 || ++nodes > 300000 || at >= raw.length) throw new Error('生成 META Variant 嵌套/节点预算超限');
    const start: string = raw[at++];
    if (start === "'" || start === '"') {
      while (at < raw.length) { const token: string = raw[at++]; if (token === start) return; if (token === '\\') at++; }
      throw new Error('生成 META 字符串无效');
    }
    if (start === '[') { const end: number = raw.indexOf(']', at); if (end < 0 || end - at > 4096) throw new Error('生成 META typed atom 无效'); at = end + 1; return; }
    if (start === '{' || start === '(') {
      const end: string = start === '{' ? '}' : ')'; space(); if (raw[at] === end) { at++; return; }
      while (at < raw.length) {
        read(depth + 1); space();
        if (start === '{') { if (raw.substring(at, at + 2) !== '=>') throw new Error('生成 META 字典无效'); at += 2; read(depth + 1); space(); }
        if (raw[at] === end) { at++; return; }
        if (raw[at++] !== ',') throw new Error('生成 META 容器无效');
      }
      throw new Error('生成 META 容器未闭合');
    }
    if (',)}'.includes(start)) throw new Error('生成 META 值无效');
    while (at < raw.length && !/[\s,)}]/.test(raw[at])) at++;
  };
  read(0); space(); if (at !== raw.length) throw new Error('生成 META 尾部无效');
}
function replace(records: LayoutContextRecord[], key: string, rawValue: string): void {
  validateGeneratedVariant(rawValue);
  const replacement: LayoutContextRecord = { encoding: 'utf8', value: 'META(' + variantString(key) + ')=' + rawValue };
  let replaced: boolean = false;
  for (let i: number = 0; i < records.length; i++) {
    if (metaKey(records[i]) !== key) continue;
    if (replaced) throw new Error('已知 META key 重复');
    records[i] = replacement; replaced = true;
  }
  if (!replaced) records.push(replacement);
}
function variantValue(records: LayoutContextRecord[], key: string): string {
  let value: string = '', found: boolean = false;
  for (const row of records) if (metaKey(row) === key) {
    if (found) throw new Error('已知 META key 重复'); found = true;
    const text: string = contextRecordText(row), at: number = text.indexOf(')=');
    if (at < 0) throw new Error('已知 META 无效'); value = text.substring(at + 2);
  }
  return value;
}
function dictionaryFields(raw: string): string[] {
  if (raw.length === 0) return [];
  if (!raw.startsWith('{') || !raw.endsWith('}')) throw new Error('已知 META 须为 Variant 字典');
  const fields: string[] = []; let start: number = 1, depth: number = 0, quote: string = '', escaped: boolean = false;
  for (let i: number = 1; i < raw.length - 1; i++) {
    const c: string = raw[i];
    if (escaped) { escaped = false; continue; }
    if (c === '\\' && quote.length > 0) { escaped = true; continue; }
    if (quote.length > 0) { if (c === quote) quote = ''; continue; }
    if (c === "'" || c === '"') { quote = c; continue; }
    if ('{(['.includes(c)) depth++; else if ('})]'.includes(c)) depth--;
    if (depth < 0) throw new Error('META 字典嵌套无效');
    if (c === ',' && depth === 0) { fields.push(raw.substring(start, i)); start = i + 1; }
  }
  if (depth !== 0 || quote.length > 0 || escaped) throw new Error('META 字典嵌套无效');
  if (raw.substring(start, raw.length - 1).trim().length > 0) fields.push(raw.substring(start, raw.length - 1));
  return fields;
}
function fieldKey(field: string): string { return field.match(/^\s*'((?:\\.|[^'])*)'\s*=>/)?.[1] ?? ''; }
function mergeDictionary(original: string, updates: string, removed: string[] = []): string {
  const replacement: Map<string, string> = new Map<string, string>();
  for (const field of dictionaryFields(updates)) { const key: string = fieldKey(field); if (key.length === 0 || replacement.has(key)) throw new Error('META 字典更新无效'); replacement.set(key, field); }
  const out: string[] = [], seen: Set<string> = new Set<string>();
  for (const field of dictionaryFields(original)) {
    const key: string = fieldKey(field);
    if (key.length > 0 && seen.has(key)) throw new Error('META 字典 key 重复'); seen.add(key);
    if (removed.includes(key)) continue;
    out.push(replacement.get(key) ?? field); replacement.delete(key);
  }
  replacement.forEach((field: string): void => { out.push(field); });
  return '{' + out.join(',') + '}';
}
function replaceDictionary(records: LayoutContextRecord[], key: string, updates: string, removed: string[] = [], source?: LayoutContextRecord[]): void {
  replace(records, key, mergeDictionary(variantValue(source ?? records, key), updates, removed));
}
function grid(value: number, dbu: number): number {
  const rounded: number = Math.round(value / dbu);
  if (!Number.isFinite(value) || Math.abs(value - rounded * dbu) > Math.max(1e-8, Math.abs(value) * 1e-12) || Math.abs(rounded) > 2147483647) {
    throw new Error('CrossSection 尺寸不能按当前 DBU 无损保存');
  }
  return rounded;
}
function layer(layerNumber: number, datatype: number): string {
  if (!Number.isInteger(layerNumber) || layerNumber < 0 || layerNumber > 32767 || !Number.isInteger(datatype) || datatype < 0 || datatype > 32767) throw new Error('CrossSection 图层无效');
  return '[layer:' + layerNumber + '/' + datatype + ']';
}
function bbox(rows: BboxRow[] | undefined, dbu: number): string {
  const keys: Set<string> = new Set<string>();
  return '{' + (rows ?? []).map((row: BboxRow): string => {
    const key: string = layer(row.layerNumber, row.datatype);
    if (keys.has(key)) throw new Error('CrossSection bbox 图层重复'); keys.add(key);
    return key + '=>#' + grid(row.offsetNm, dbu);
  }).join(',') + '}';
}
function identity(value: string): string {
  // Portable stable name; semantic identities remain the document's actual keys.
  let a: number = 2166136261, b: number = 2654435761;
  for (let i: number = 0; i < value.length; i++) { a = Math.imul(a ^ value.charCodeAt(i), 16777619); b = Math.imul(b ^ value.charCodeAt(i), 2246822519); }
  return (a >>> 0).toString(16) + (b >>> 0).toString(16);
}
function exportSection(payload: PortContextPayload, name: string, def: CrossSectionDefinition, dbu: number): void {
  if (def.schemaVersion !== 1 || (def.kind !== 'symmetric' && def.kind !== 'asymmetric') || def.enclosure === undefined || !Array.isArray(def.enclosure.sections)) {
    throw new Error('未知 CrossSection 描述仅保留原上下文，当前不能生成 KF registry');
  }
  const main: string = layer(def.layerNumber, def.datatype);
  let xs: string = '{';
  if (def.kind === 'symmetric') {
    const xsKey: string = 'kfactory:cross_section:' + name;
    const originalXs: string = variantValue(payload.layout, xsKey);
    const oldEnclosure: string = originalXs.match(/'layer_enclosure'=>'((?:\\.|[^'])*)'/)?.[1] ?? '';
    let enclosure: string = oldEnclosure.length > 0 ? oldEnclosure : 'ht-enclosure-' + identity(name);
    const rows: string[] = def.enclosure.sections.map((row: SectionRow): string =>
      '(' + layer(row.layerNumber, row.datatype) + (row.minNm !== undefined ? ',#' + grid(row.minNm, dbu) : '') + ',#' + grid(row.maxNm, dbu) + ')');
    let e: string = "{'name'=>" + variantString(enclosure) + ",'main_layer'=>" + main + ",'sections'=>(" + rows.join(',') + ')';
    if ((def.enclosure.bboxSections ?? []).length > 0) e += ",'bbox_sections'=>" + bbox(def.enclosure.bboxSections, dbu);
    const originalE: string = variantValue(payload.layout, 'kfactory:layer_enclosure:' + enclosure);
    const oldMain: string = dictionaryFields(originalE).find((field: string): boolean => fieldKey(field) === 'main_layer') ?? '';
    const oldSections: string = dictionaryFields(originalE).find((field: string): boolean => fieldKey(field) === 'sections') ?? '';
    if (oldMain.length > 0 && (oldMain.trim() !== "'main_layer'=>" + main || oldSections.trim() !== "'sections'=>(" + rows.join(',') + ')')) {
      enclosure = 'ht-enclosure-' + identity(name + JSON.stringify(def));
      e = e.replace(/^{\x27name\x27=>\x27(?:\\.|[^'])*\x27,/, "{'name'=>" + variantString(enclosure) + ',');
    }
    replace(payload.layout, 'kfactory:layer_enclosure:' + enclosure, mergeDictionary(originalE, e + '}'));
    xs += "'width'=>#" + grid(def.widthNm, dbu) + ",'layer_enclosure'=>" + variantString(enclosure);
  } else {
    if (def.sectionMinNm === undefined || def.sectionMaxNm === undefined || Math.abs(def.sectionMaxNm - def.sectionMinNm - def.widthNm) > Math.max(1e-8, def.widthNm * 1e-12)) throw new Error('非对称 CrossSection 宽度无效');
    xs += "'layer'=>" + main + ",'section_min'=>#" + grid(def.sectionMinNm, dbu) + ",'section_max'=>#" + grid(def.sectionMaxNm, dbu);
    xs += ",'sections'=>(" + (def.sections ?? def.enclosure.sections).map((row: SectionRow): string => {
      if (row.minNm === undefined) throw new Error('非对称 section 缺少 minNm');
      return "{'layer'=>" + layer(row.layerNumber, row.datatype) + ",'section_min'=>#" + grid(row.minNm, dbu) + ",'section_max'=>#" + grid(row.maxNm, dbu) + '}';
    }).join(',') + "),'bbox_sections'=>" + bbox(def.enclosure.bboxSections, dbu);
  }
  if (def.radiusNm !== undefined) xs += ",'radius'=>#" + grid(def.radiusNm, dbu);
  if (def.radiusMinNm !== undefined) xs += ",'radius_min'=>#" + grid(def.radiusMinNm, dbu);
  replaceDictionary(payload.layout, (def.kind === 'symmetric' ? 'kfactory:cross_section:' : 'kfactory:asymmetrical_cross_section:') + name, xs + '}');
}
function sourceIndex(port: LayoutPort): number {
  if (port.provenance === undefined) return -1;
  const provenance: ForeignPortProvenance = JSON.parse(port.provenance) as ForeignPortProvenance;
  if (provenance.kind !== 'foreign' || provenance.format !== 'kfactory' || provenance.metaFormat !== 'v3' || provenance.ownerCellKey !== port.ownerCellKey) return -1;
  const index: number = provenance.portIndex ?? -1;
  if (!Number.isSafeInteger(index) || index < 0 || index > 2147483647 || provenance.metaName !== 'kfactory:ports:' + index) throw new Error('KF 端口编号 provenance 无效');
  return index;
}
function cloneRecords(rows: LayoutContextRecord[]): LayoutContextRecord[] {
  return rows.map((row: LayoutContextRecord): LayoutContextRecord => ({ encoding: row.encoding, value: row.value }));
}
function quotedMetaValue(record: LayoutContextRecord): string {
  const text: string = contextRecordText(record);
  const position: number = text.indexOf(')=');
  const raw: string = position >= 0 ? text.substring(position + 2) : '';
  if (!/^'(?:\\.|[^'])*'$/.test(raw)) throw new Error('已知 META 字符串无效');
  const bytes: number[] = [];
  for (let i: number = 1; i < raw.length - 1; i++) {
    const c: string = raw[i];
    if (c !== '\\') { const encoded: number[] = contextRecordBytes({ encoding: 'utf8', value: c }); bytes.push(...encoded); continue; }
    const next: string = raw[++i];
    if (/[0-7]/.test(next)) {
      let octal: string = next;
      for (let n: number = 1; n < 3 && i + 1 < raw.length - 1 && /[0-7]/.test(raw[i + 1]); n++) octal += raw[++i];
      const byte: number = Number.parseInt(octal, 8); if (byte > 255) throw new Error('META 八进制无效'); bytes.push(byte);
    } else if (next === '\\' || next === "'") bytes.push(next.charCodeAt(0));
    else if (next === 'n') bytes.push(10); else if (next === 'r') bytes.push(13); else if (next === 't') bytes.push(9);
    else throw new Error('META 字符串转义无效');
  }
  return new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(new Uint8Array(bytes));
}
/** Full typed truth drives both canonical META and the real fixed KF v3 registry. */
export function buildPortContextPayload(state: LayoutSemanticState, cellCount: number, dbuNm: number): PortContextPayload {
  const payload: PortContextPayload = { layout: cloneRecords(state.layoutContextRecords ?? []),
    cells: Array.from({ length: cellCount }, (_unused: Object, index: number): LayoutContextRecord[] => cloneRecords((state.cellContextRecords ?? [])[index] ?? [])) };
  if (state.cellKeys === undefined) {
    if ((state.ports ?? []).length > 0 || (state.crossSections ?? []).length > 0) throw new Error('端口保存缺少稳定 Cell key');
    return payload;
  }
  validateLayoutSemantics(state, cellCount);
  if (!Number.isFinite(dbuNm) || dbuNm <= 0) throw new Error('端口 DBU 无效');
  const ports: LayoutPort[] = state.ports ?? [], descriptors: LayoutCrossSection[] = state.crossSections ?? [];
  for (let ci: number = 0; ci < cellCount; ci++) {
    const body: OwnedPortsEnvelope = { schemaVersion: 1, ports: ports.filter((port: LayoutPort): boolean => port.ownerCellId === ci) };
    ownedMetadataJson(body);
  }
  let version: string = '', format: string = '';
  for (const row of payload.layout) {
    if (metaKey(row) === 'kfactory:settings:version') version = quotedMetaValue(row);
    if (metaKey(row) === 'kfactory:settings:meta_format') format = quotedMetaValue(row);
  }
  const hasForeign: boolean = version.length > 0 || format.length > 0, fixed: boolean = version === '3.0.4' && format === 'v3';
  if (hasForeign && !fixed && (ports.length > 0 || descriptors.length > 0)) throw new Error('未知 KF 版本上下文不可改写');
  const sectionBody: OwnedCrossSectionsEnvelope = { schemaVersion: 1, crossSections: descriptors };
  replace(payload.layout, 'hongtu:cross_sections:v1', variantString(ownedMetadataJson(sectionBody)));
  const names: Map<string, string> = new Map<string, string>(), sections: Map<string, LayoutCrossSection> = new Map<string, LayoutCrossSection>();
  const used: Set<string> = new Set<string>();
  for (const xs of descriptors) {
    const key: string = xs.key + ':' + xs.version;
    const name: string = used.has(xs.name) ? 'ht-xs-' + identity(key) : xs.name;
    names.set(key, name); sections.set(key, xs); used.add(name);
  }
  const portNames: string[] = [], exported: Set<string> = new Set<string>();
  for (const xs of descriptors) {
    const def: CrossSectionDefinition = JSON.parse(xs.definitionJson) as CrossSectionDefinition;
    if (def.schemaVersion === 1 && (def.kind === 'symmetric' || def.kind === 'asymmetric')) {
      const name: string = names.get(xs.key + ':' + xs.version) ?? '';
      if (!exported.has(name)) { exportSection(payload, name, def, dbuNm); exported.add(name); }
    }
  }
  for (const port of ports) {
    let def: CrossSectionDefinition; let name: string;
    if (port.crossSectionKey !== undefined) {
      const key: string = port.crossSectionKey + ':' + port.crossSectionVersion;
      const section: LayoutCrossSection | undefined = sections.get(key);
      if (section === undefined) throw new Error('CrossSection 引用缺失');
      def = JSON.parse(section.definitionJson) as CrossSectionDefinition; name = names.get(key) ?? '';
    } else {
      const enclosure: EnclosureDefinition = { name: '', sections: [], bboxSections: [] };
      def = { schemaVersion: 1, kind: 'symmetric', widthNm: port.widthNm, layerNumber: port.layerNumber, datatype: port.datatype, enclosure: enclosure };
      name = 'ht-xs-' + identity(JSON.stringify(def));
    }
    if (Math.abs(def.widthNm - port.widthNm) > Math.max(1e-8, port.widthNm * 1e-12) || def.layerNumber !== port.layerNumber || def.datatype !== port.datatype) throw new Error('端口宽度/图层与 CrossSection 冲突');
    portNames.push(name); if (!exported.has(name)) { exportSection(payload, name, def, dbuNm); exported.add(name); }
  }
  if (exported.size > 0) {
    replace(payload.layout, 'kfactory:settings:version', variantString('3.0.4'));
    replace(payload.layout, 'kfactory:settings:meta_format', variantString('v3'));
    replace(payload.layout, 'kfactory:settings:klayout_version', variantString('0.30.12'));
  }
  for (let ci: number = 0; ci < cellCount; ci++) {
    const mapping: Map<number, number> = new Map<number, number>(), indices: Set<number> = new Set<number>();
    for (let pi: number = 0; pi < ports.length; pi++) if (ports[pi].ownerCellId === ci) {
      const index: number = sourceIndex(ports[pi]);
      if (index >= 0) { if (indices.has(index)) throw new Error('KF 端口编号重复'); mapping.set(pi, index); indices.add(index); }
    }
    let staticCell: boolean = false, hasPins: boolean = false;
    for (const row of payload.cells[ci]) {
      const key: string = metaKey(row);
      if (key === 'hongtu:cell_lineage:v1') {
        const lineage: CellLineage = JSON.parse(quotedMetaValue(row)) as CellLineage;
        if (lineage.schemaVersion !== 1) throw new Error('Cell lineage 版本无效');
        staticCell = ['clip-static', 'flatten-static', 'snapshot-static', 'subset-static'].includes(lineage.kind);
      }
      if (key.startsWith('kfactory:pin')) {
        hasPins = true;
        if (!fixed) throw new Error('未知 KF Pin 版本');
        const raw: string = contextRecordText(row), match: RegExpMatchArray | null = raw.match(/'ports'=>\(((?:#[0-9]+(?:,#[0-9]+)*)?)\)/);
        if (match === null) throw new Error('KF Pin 引用格式不受支持，需显式事务');
        for (const item of match[1].length > 0 ? match[1].split(',') : []) if (!indices.has(Number.parseInt(item.substring(1), 10))) throw new Error('删除/重新分配被 Pin 引用端口需 Pin 事务');
      }
    }
    if (hasPins && ports.some((port: LayoutPort): boolean => port.ownerCellId === ci && sourceIndex(port) < 0)) throw new Error('KF Pin Cell 新增/复制端口编号需完整 Pin 事务');
    if (staticCell && payload.cells[ci].some((row: LayoutContextRecord): boolean => /^(PCELL|CELL)=/.test(contextRecordText(row)))) throw new Error('静态 Cell 尚有 active foreign PCell/CELL recipe，需显式解除');
    let next: number = 0;
    for (let pi: number = 0; pi < ports.length; pi++) if (ports[pi].ownerCellId === ci && !mapping.has(pi)) {
      while (indices.has(next)) next++; mapping.set(pi, next); indices.add(next++);
    }
    const originalRecords: LayoutContextRecord[] = cloneRecords(payload.cells[ci]);
    if (fixed || !hasForeign) payload.cells[ci] = payload.cells[ci].filter((row: LayoutContextRecord): boolean => !metaKey(row).startsWith('kfactory:ports:'));
    const cellPorts: LayoutPort[] = [];
    mapping.forEach((index: number, pi: number): void => {
      const port: LayoutPort = ports[pi]; cellPorts.push(port);
      const transform: string = '[dcplxtrans:' + (port.frameMirror ? 'm' : 'r') + (((port.orientationDeg % 360) + 360) % 360 / (port.frameMirror ? 2 : 1)) +
        ' *' + port.frameMagnification + ' ' + (port.centerNm.x / 1000) + ',' + (port.centerNm.y / 1000) + ']';
      replaceDictionary(payload.cells[ci], 'kfactory:ports:' + index, "{'name'=>" + variantString(port.name) + ",'cross_section'=>" + variantString(portNames[pi]) +
        ",'port_type'=>" + variantString(port.portType) + ",'info'=>" + variant(JSON.parse(port.infoJson) as Object) + ",'dcplx_trans'=>" + transform + '}', ['trans'], sourceIndex(port) >= 0 ? originalRecords : []);
    });
    replace(payload.cells[ci], 'hongtu:cell_key:v1', variantString((state.cellKeys ?? [])[ci]));
    const portBody: OwnedPortsEnvelope = { schemaVersion: 1, ports: cellPorts };
    replace(payload.cells[ci], 'hongtu:ports:v1', variantString(ownedMetadataJson(portBody)));
  }
  let bytes: number = 0;
  for (const group of [payload.layout, ...payload.cells]) {
    if (group.length > 65536) throw new Error('context 条目超出预算');
    for (const row of group) { const size: number = contextRecordBytes(row).length; bytes += size; if (size > 8 * 1024 * 1024 || bytes > 64 * 1024 * 1024) throw new Error('context 字节超出预算'); }
  }
  const serialized: LayoutSemanticState = { cellKeys: state.cellKeys, ports: state.ports, crossSections: state.crossSections,
    layoutContextRecords: payload.layout, cellContextRecords: payload.cells };
  validateLayoutSemantics(serialized, cellCount);
  return payload;
}
