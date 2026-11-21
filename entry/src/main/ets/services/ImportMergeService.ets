import { Shape, ShapeType, Point, LayoutDocument } from '../models/GdsiiData';
import { editService } from './EditService';
import type { EditStructureState, EditSessionState } from './EditService';
import { validatePropertyHierarchy } from './ShapePropertyService';
import type { LayoutPropRecord, SourceLayerDefinition, LayerNameInterval } from '../../cpp/types/libhongtu/Index';
import { normalizeLayoutSemantics, mergeLayoutSemantics, canonicalCellPortSemantics, remapPortLayers } from '../models/LayoutPort';
import type { LayoutSemanticState, LayoutPort } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneShapeArray, cloneShapeModel, cloneStructured, computeShapeDigest } from '../common/CloneUtils';
import { cleanDbuNm } from './PrecisionService';

/** Readers have already converted database coordinates to nm. DBU is export metadata. */
export interface ImportMergeSource extends LayoutSemanticState {
  coordinateUnit: 'nm';
  shapes: Shape[];
  cellNames: string[];
  cellProperties?: LayoutPropRecord[][];
  libProperties?: LayoutPropRecord[];
  layerDefinitions?: SourceLayerDefinition[];
  topCellId: number;
  userUnits: number;
  physicalUnits: number;
}
export interface ImportLayerMapping {
  sourceLayer: number;
  sourceDatatype: number;
  action: 'map' | 'drop';
  targetLayer?: number;
  targetDatatype?: number;
}
export interface ImportCellMapping {
  sourceCellId: number;
  action: 'rename' | 'reuse';
  targetName?: string;
  targetCellId?: number;
}
export interface ImportRootPlacement {
  sourceCellId: number;
  targetCellId: number;
  xNm: number;
  yNm: number;
  layer: number;
  datatype: number;
  rotation?: number;
  mirror?: number;
  magnification?: number;
}
export interface ImportMergeOptions {
  layerMappings?: ImportLayerMapping[];
  cellMappings?: ImportCellMapping[];
  /** Omitted imports the whole library. Supplied roots import their dependency closure. */
  sourceRootIds?: number[];
  collisionPolicy?: 'rename' | 'reject';
  /** Default keeps the target library attributes and reports omitted source attributes. */
  libraryProperties?: 'merge' | 'keep-target';
  /** Default keeps the existing/first name for a mapped purpose and reports conflicts. */
  layerNameConflictPolicy?: 'keep-target' | 'reject';
  placements?: ImportRootPlacement[];
}
export interface ImportMergedCell {
  sourceCellId: number;
  sourceName: string;
  targetCellId: number;
  targetName: string;
  action: 'new' | 'reuse';
}
export interface ImportMergePreview {
  token: number;
  cells: ImportMergedCell[];
  addedCells: number;
  reusedCells: number;
  importedObjects: number;
  droppedObjects: number;
  placements: number;
  sourceDbuNm: number;
  targetDbuNm: number;
  offGridCoordinateCount: number;
  maxExportQuantizationNm: number;
  warnings: string[];
  importedPorts?: number;
  droppedPorts?: number;
}
export interface ImportMergeResult { ok: boolean; message: string; preview?: ImportMergePreview; addedIds?: number[]; }
interface PreparedMerge {
  token: number;
  documentIdentity: string;
  revision: number;
  cellId: number;
  fingerprint: string;
  before: EditStructureState;
  after: EditStructureState;
  shapes: Shape[];
  addedIds: number[];
}

export function importMergeSourceFromLayout(document: LayoutDocument): ImportMergeSource {
  return { cellKeys: document.cellKeys, ports: document.ports, crossSections: document.crossSections,
    layoutContextRecords: document.layoutContextRecords, cellContextRecords: document.cellContextRecords,
    coordinateUnit: 'nm', shapes: document.shapes, cellNames: document.cells.map((cell): string => cell.name),
    cellProperties: document.cells.map((cell): LayoutPropRecord[] => cell.properties ?? []),
    libProperties: document.libProperties, layerDefinitions: document.layerDefinitions, topCellId: document.primaryTopCellId,
    userUnits: document.userUnits, physicalUnits: document.physicalUnits };
}

function cloneShape(shape: Shape): Shape { return cloneShapeModel(shape, true) as Shape; }
function cloneStructure(state: EditStructureState): EditStructureState { return cloneEditStructureModel(state, true) as EditStructureState; }
function cloneProperty(property: LayoutPropRecord): LayoutPropRecord {
  return { attr: property.attr, dtype: property.dtype, name: property.name, value: property.value };
}
function pair(layer: number, datatype: number): string { return `${layer}/${datatype}`; }
function validLayer(value: number): boolean { return Number.isInteger(value) && value >= 0 && value <= 32767; }
function validCellName(name: string): boolean { return typeof name === 'string' && name.length > 0 && name.length <= 512 && !name.includes('\0'); }
function validCellId(id: number, size: number): boolean { return Number.isInteger(id) && id >= 0 && id < size; }
function validateProperties(records: LayoutPropRecord[] | undefined): void {
  if (records === undefined) return;
  if (!Array.isArray(records) || records.length > 64) throw new Error('属性集合无效或超过 64 项预算');
  for (const record of records) {
    if (record === null || !Number.isInteger(record.attr) || record.attr < -32768 || record.attr > 32767 ||
      !Number.isInteger(record.dtype) || record.dtype < 0 || record.dtype > 255 || typeof record.name !== 'string' ||
      typeof record.value !== 'string' || record.name.length > 65536 || record.value.length > 1048576) throw new Error('属性记录无效');
  }
}
function validateInterval(interval: LayerNameInterval): void {
  if (interval === undefined || interval === null || !Number.isInteger(interval.type) || interval.type < 0 || interval.type > 4 ||
    !Number.isInteger(interval.lower) || !Number.isInteger(interval.upper) || interval.lower < 0 || interval.upper > 4294967295 ||
    interval.lower > interval.upper || (interval.type === 0 && (interval.lower !== 0 || interval.upper !== 4294967295)) ||
    (interval.type === 1 && interval.lower !== 0) || (interval.type === 2 && interval.upper !== 4294967295) ||
    (interval.type === 3 && interval.lower !== interval.upper)) throw new Error('源图层名称区间无效');
}
function validateDefinitions(definitions: SourceLayerDefinition[] | undefined): void {
  if (definitions === undefined) return;
  if (!Array.isArray(definitions) || definitions.length > 100000) throw new Error('图层名称定义超过预算');
  for (const definition of definitions) {
    if (definition === null || typeof definition.name !== 'string' || definition.name.length > 65535 ||
      definition.name.includes('\0') || typeof definition.textLayer !== 'boolean') throw new Error('源图层名称定义无效');
    validateInterval(definition.layer); validateInterval(definition.datatype);
  }
}

/** Validation happens before dropping/mapping, so a malformed hidden source cannot pass silently. */
function validateSource(source: ImportMergeSource): void {
  if (source === null || source.coordinateUnit !== 'nm' || !Array.isArray(source.shapes) || source.shapes.length > 2000000 ||
    !Array.isArray(source.cellNames) || source.cellNames.length === 0 || source.cellNames.length > 100000 ||
    !validCellId(source.topCellId, source.cellNames.length) || !Number.isFinite(source.userUnits) || source.userUnits <= 0 ||
    !Number.isFinite(source.physicalUnits) || source.physicalUnits <= 0 || !Number.isFinite(source.physicalUnits * 1e9) ||
    source.cellNames.some((name: string): boolean => !validCellName(name)) || new Set<string>(source.cellNames).size !== source.cellNames.length) {
    throw new Error('导入文档单位、Cell 或对象预算无效');
  }
  const semantic: LayoutSemanticState = cloneStructured(source) as LayoutSemanticState;
  normalizeLayoutSemantics(semantic, source.cellNames.length);
  if (source.cellProperties !== undefined && (!Array.isArray(source.cellProperties) || source.cellProperties.length > source.cellNames.length)) {
    throw new Error('源 Cell 属性索引无效');
  }
  for (const properties of source.cellProperties ?? []) validateProperties(properties);
  validateProperties(source.libProperties); validateDefinitions(source.layerDefinitions);
  const ids: Set<number> = new Set<number>();
  let pointCount: number = 0;
  for (const shape of source.shapes) {
    if (shape === null || !Number.isSafeInteger(shape.id) || shape.id <= 0 || ids.has(shape.id) ||
      !validLayer(shape.layerNumber) || !validLayer(shape.datatype) || !Array.isArray(shape.points) || shape.points.length === 0 ||
      [ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH, ShapeType.TEXT, ShapeType.INSTANCE, ShapeType.NODE].indexOf(shape.type) < 0 ||
      !validCellId(shape.ownerCellId ?? source.topCellId, source.cellNames.length)) throw new Error('源文档含无效图形或 Cell 归属');
    ids.add(shape.id); pointCount += shape.points.length;
    if (pointCount > 25000000) throw new Error('源顶点超过 2500 万预算');
    if (shape.points.some((point: Point): boolean => point === null || !Number.isFinite(point.x) || !Number.isFinite(point.y))) throw new Error('源文档含非有限坐标');
    if ((shape.type === ShapeType.RECT && shape.points.length < 2) || (shape.type === ShapeType.POLYGON && shape.points.length < 3) ||
      (shape.type === ShapeType.PATH && (shape.points.length < 2 || shape.pathWidth === undefined ||
        !Number.isFinite(shape.pathWidth) || shape.pathWidth < 0))) throw new Error('源图形几何不完整');
    if (shape.type === ShapeType.INSTANCE && (!validCellId(shape.cellId ?? -1, source.cellNames.length) ||
      (shape.cellName !== undefined && shape.cellName !== source.cellNames[shape.cellId as number]))) throw new Error('源实例引用 Cell 无效或名称不一致');
    if (shape.text !== undefined && typeof shape.text !== 'string') throw new Error('源文字无效');
    if (shape.pathType !== undefined && [0, 1, 2, 4].indexOf(shape.pathType) < 0) throw new Error('源路径端型无效');
    const numbers: (number | undefined)[] = [shape.pathBeginExtension, shape.pathEndExtension, shape.rotation, shape.magnification,
      shape.arrayColStepX, shape.arrayColStepY, shape.arrayRowStepX, shape.arrayRowStepY];
    if (numbers.some((value: number | undefined): boolean => value !== undefined && !Number.isFinite(value)) ||
      (shape.magnification !== undefined && shape.magnification <= 0) ||
      (shape.mirror !== undefined && [0, 1, 2].indexOf(shape.mirror) < 0) ||
      (shape.pathWidthAbsolute !== undefined && typeof shape.pathWidthAbsolute !== 'boolean')) throw new Error('源路径或变换参数无效');
    for (const count of [shape.arrayCols, shape.arrayRows]) if (count !== undefined &&
      (!Number.isInteger(count) || count < 0 || count > 32767)) throw new Error('源阵列维数无效');
    validateProperties(shape.properties);
  }
  const hierarchyError: string = validatePropertyHierarchy(source.shapes, source.topCellId);
  if (hierarchyError.length > 0) throw new Error(hierarchyError);
}

/** File imports validate a complete isolated parse before publishing even its metadata. */
export function validateImportMergeSource(source: ImportMergeSource): string {
  try { validateSource(source); return ''; }
  catch (error) { return error instanceof Error ? error.message : String(error); }
}

function structureSource(shapes: Shape[], structure: EditStructureState): ImportMergeSource {
  return { cellKeys: structure.cellKeys, ports: structure.ports, crossSections: structure.crossSections,
    layoutContextRecords: structure.layoutContextRecords, cellContextRecords: structure.cellContextRecords,
    coordinateUnit: 'nm', shapes: shapes, cellNames: structure.cellNames, cellProperties: structure.cellProperties,
    libProperties: structure.libProperties, layerDefinitions: structure.layerDefinitions, topCellId: structure.topCellId,
    userUnits: structure.userUnits ?? 0.001, physicalUnits: structure.physicalUnits ?? 1e-9 };
}
function canonicalShape(shape: Shape, names: string[]): string {
  const copy: Shape = cloneShape(shape); copy.id = 1; copy.selected = false; copy.ownerCellId = 0;
  if (copy.type === ShapeType.INSTANCE) copy.cellName = names[copy.cellId as number];
  // Stable field ordering is independent of parser/editor object insertion order.
  return JSON.stringify([copy.type, copy.layerNumber, copy.datatype, copy.points.map((point: Point): number[] => [point.x, point.y]), copy.pathWidth, copy.pathType,
    copy.pathBeginExtension, copy.pathEndExtension, copy.pathWidthAbsolute, copy.text, copy.textPresentation,
    copy.cellId, copy.cellName, copy.rotation, copy.mirror, copy.magnification, copy.arrayCols, copy.arrayRows,
    copy.arrayColStepX, copy.arrayColStepY, copy.arrayRowStepX, copy.arrayRowStepY, canonicalProperties(copy.properties)]);
}
function canonicalProperties(properties: LayoutPropRecord[] | undefined): string {
  return JSON.stringify((properties ?? []).map((property: LayoutPropRecord): string =>
    JSON.stringify([property.attr, property.dtype, property.name, property.value])));
}
function mergeLibraryProperties(target: LayoutPropRecord[], source: LayoutPropRecord[]): LayoutPropRecord[] {
  const result: LayoutPropRecord[] = target.map((property: LayoutPropRecord): LayoutPropRecord => cloneProperty(property));
  for (const property of source) {
    const previous: LayoutPropRecord | undefined = result.find((item: LayoutPropRecord): boolean =>
      item.attr === property.attr && item.dtype === property.dtype && item.name === property.name);
    if (previous !== undefined && previous.value !== property.value) throw new Error('源与目标库属性冲突；请选择保留目标库属性或修改源文件');
    if (previous === undefined) result.push(cloneProperty(property));
  }
  validateProperties(result); return result;
}

/** A sealed candidate, exact document context and one structural transaction form the import boundary. */
export class ImportMergeService {
  private serial: number = 0;
  private pending: PreparedMerge | null = null;

  /** O(N) 零大字符串分配上下文指纹，替代对百万顶点执行 JSON.stringify 导致的 UI 冻屏 */
  private computeContextFingerprint(shapes: Shape[], structure: EditStructureState): string {
    let h1: number = 0x811c9dc5;
    let h2: number = 0x9e3779b9;
    let totalPts: number = 0;
    for (let i = 0; i < shapes.length; i++) {
      const s: Shape = shapes[i];
      const d: number = computeShapeDigest(s);
      const lo: number = d | 0;
      const hi: number = Math.floor(d / 4294967296) | 0;
      h1 = Math.imul(h1 ^ lo, 16777619) | 0;
      h2 = Math.imul(h2 ^ hi ^ s.id, 1597334677) | 0;
      totalPts += s.points.length;
    }
    return `${shapes.length}:${totalPts}:${h1 >>> 0}:${h2 >>> 0}:${JSON.stringify(structure)}`;
  }

  cancel(preview?: ImportMergePreview): void {
    if (preview === undefined || this.pending?.token === preview.token) this.pending = null;
  }

  /** Read-only preview data; callers can render it but cannot edit the sealed transaction. */
  getPreviewSnapshot(preview: ImportMergePreview): ImportMergeSource | null {
    if (this.pending === null || preview === null || preview.token !== this.pending.token) return null;
    return cloneStructured(structureSource(this.pending.shapes, this.pending.after)) as ImportMergeSource;
  }

  prepare(source: ImportMergeSource, structure: EditStructureState, options: ImportMergeOptions,
    documentIdentity: string): ImportMergeResult {
    this.pending = null;
    try {
      if (typeof documentIdentity !== 'string' || documentIdentity.length === 0) throw new Error('文档身份为空');
      if (options === null || (options.collisionPolicy !== undefined && options.collisionPolicy !== 'rename' && options.collisionPolicy !== 'reject') ||
        (options.libraryProperties !== undefined && options.libraryProperties !== 'merge' && options.libraryProperties !== 'keep-target') ||
        (options.layerNameConflictPolicy !== undefined && options.layerNameConflictPolicy !== 'keep-target' && options.layerNameConflictPolicy !== 'reject')) throw new Error('导入策略无效');
      validateSource(source);
      source = cloneStructured(source) as ImportMergeSource;
      normalizeLayoutSemantics(source, source.cellNames.length);
      const existing: Shape[] = editService.getShapes();
      validateSource(structureSource(existing, structure));
      if (structure.topCellId !== editService.getTopCellId() || structure.cellStack[structure.cellStack.length - 1] !== editService.getCurrentCellId()) {
        throw new Error('目标 Cell 结构与编辑上下文不一致');
      }
      const layerMappings: Map<string, ImportLayerMapping> = new Map<string, ImportLayerMapping>();
      if (!Array.isArray(options.layerMappings ?? []) || (options.layerMappings?.length ?? 0) > 65536) throw new Error('层映射超过预算');
      for (const mapping of options.layerMappings ?? []) {
        if (mapping === null || !validLayer(mapping.sourceLayer) || !validLayer(mapping.sourceDatatype) ||
          (mapping.action !== 'map' && mapping.action !== 'drop') || layerMappings.has(pair(mapping.sourceLayer, mapping.sourceDatatype)) ||
          (mapping.action === 'map' && (!validLayer(mapping.targetLayer as number) || !validLayer(mapping.targetDatatype as number)))) throw new Error('层映射无效或重复');
        layerMappings.set(pair(mapping.sourceLayer, mapping.sourceDatatype), mapping);
      }
      const included: Set<number> = new Set<number>();
      const byOwner: Map<number, Shape[]> = new Map<number, Shape[]>();
      for (const shape of source.shapes) {
        const owner: number = shape.ownerCellId ?? source.topCellId;
        let list: Shape[] | undefined = byOwner.get(owner); if (list === undefined) { list = []; byOwner.set(owner, list); }
        list.push(shape);
      }
      if (options.sourceRootIds === undefined) for (let id: number = 0; id < source.cellNames.length; id++) included.add(id);
      else {
        if (!Array.isArray(options.sourceRootIds) || options.sourceRootIds.length === 0 || options.sourceRootIds.length > source.cellNames.length ||
          new Set<number>(options.sourceRootIds).size !== options.sourceRootIds.length) throw new Error('源根 Cell 选择无效');
        const pending: number[] = options.sourceRootIds.slice();
        while (pending.length > 0) {
          const id: number = pending.pop() as number;
          if (!validCellId(id, source.cellNames.length)) throw new Error('源根 Cell 不存在');
          if (included.has(id)) continue; included.add(id);
          for (const shape of byOwner.get(id) ?? []) if (shape.type === ShapeType.INSTANCE) pending.push(shape.cellId as number);
        }
      }
      const cellMappings: Map<number, ImportCellMapping> = new Map<number, ImportCellMapping>();
      if (!Array.isArray(options.cellMappings ?? []) || (options.cellMappings?.length ?? 0) > source.cellNames.length) throw new Error('Cell 映射超过预算');
      for (const mapping of options.cellMappings ?? []) {
        if (mapping === null || !included.has(mapping.sourceCellId) || cellMappings.has(mapping.sourceCellId) ||
          (mapping.action !== 'rename' && mapping.action !== 'reuse') || (mapping.action === 'rename' && !validCellName(mapping.targetName as string)) ||
          (mapping.action === 'reuse' && !validCellId(mapping.targetCellId as number, structure.cellNames.length))) throw new Error('Cell 映射无效、未选择或重复');
        cellMappings.set(mapping.sourceCellId, mapping);
      }
      const after: EditStructureState = cloneStructure(structure);
      normalizeLayoutSemantics(after, after.cellNames.length);
      while (after.cellProperties.length < after.cellNames.length) after.cellProperties.push([]);
      const names: Set<string> = new Set<string>(after.cellNames);
      const cells: ImportMergedCell[] = [];
      const ids: Map<number, number> = new Map<number, number>();
      for (let sourceId: number = 0; sourceId < source.cellNames.length; sourceId++) {
        if (!included.has(sourceId)) continue;
        const mapping: ImportCellMapping | undefined = cellMappings.get(sourceId);
        if (mapping?.action === 'reuse') {
          const targetId: number = mapping.targetCellId as number; ids.set(sourceId, targetId);
          cells.push({ sourceCellId: sourceId, sourceName: source.cellNames[sourceId], targetCellId: targetId,
            targetName: after.cellNames[targetId], action: 'reuse' }); continue;
        }
        let name: string = mapping?.targetName ?? source.cellNames[sourceId];
        if (names.has(name)) {
          if (mapping !== undefined || options.collisionPolicy === 'reject') throw new Error(`Cell 名称冲突：${name}`);
          const base: string = name.slice(0, 490); let suffix: number = 1;
          do { name = `${base}_import${suffix++}`; } while (names.has(name));
        }
        if (after.cellNames.length >= 100000) throw new Error('合并后 Cell 超过 10 万预算');
        const targetId: number = after.cellNames.length;
        names.add(name); ids.set(sourceId, targetId); after.cellNames.push(name);
        after.cellProperties.push((source.cellProperties?.[sourceId] ?? []).map((property: LayoutPropRecord): LayoutPropRecord => cloneProperty(property)));
        cells.push({ sourceCellId: sourceId, sourceName: source.cellNames[sourceId], targetCellId: targetId, targetName: name, action: 'new' });
      }
      const mapped: Map<number, Shape[]> = new Map<number, Shape[]>();
      const droppedPorts: number = remapPortLayers(source, options.layerMappings ?? []);
      let dropped: number = 0;
      for (const shape of source.shapes) {
        const owner: number = shape.ownerCellId ?? source.topCellId; if (!included.has(owner)) continue;
        const mapping: ImportLayerMapping | undefined = shape.type === ShapeType.INSTANCE ? undefined : layerMappings.get(pair(shape.layerNumber, shape.datatype));
        if (mapping?.action === 'drop') { dropped++; continue; }
        const copy: Shape = cloneShape(shape); copy.selected = false; copy.ownerCellId = ids.get(owner) as number;
        if (mapping?.action === 'map') { copy.layerNumber = mapping.targetLayer as number; copy.datatype = mapping.targetDatatype as number; }
        if (copy.type === ShapeType.INSTANCE) { copy.cellId = ids.get(copy.cellId as number) as number; copy.cellName = after.cellNames[copy.cellId]; }
        let list: Shape[] | undefined = mapped.get(owner); if (list === undefined) { list = []; mapped.set(owner, list); } list.push(copy);
      }
      const existingByCell: Map<number, string[]> = new Map<number, string[]>();
      const reused: Set<number> = new Set<number>(cells.filter((cell: ImportMergedCell): boolean => cell.action === 'reuse')
        .map((cell: ImportMergedCell): number => cell.targetCellId));
      for (const shape of existing) {
        const owner: number = shape.ownerCellId ?? structure.topCellId;
        if (!reused.has(owner)) continue;
        let list: string[] | undefined = existingByCell.get(owner); if (list === undefined) { list = []; existingByCell.set(owner, list); }
        list.push(canonicalShape(shape, after.cellNames));
      }
      const candidate: Shape[] = existing.slice(); const addedIds: number[] = [];
      let nextId: number = editService.getNextShapeId(); let imported: number = 0;
      let candidatePoints: number = existing.reduce((count: number, shape: Shape): number => count + shape.points.length, 0);
      for (const cell of cells) {
        const shapes: Shape[] = mapped.get(cell.sourceCellId) ?? [];
        if (cell.action === 'reuse') {
          const original: string[] = (existingByCell.get(cell.targetCellId) ?? []).slice().sort();
          const incoming: string[] = shapes.map((shape: Shape): string => canonicalShape(shape, after.cellNames)).sort();
          if (canonicalCellPortSemantics(source, cell.sourceCellId) !== canonicalCellPortSemantics(after, cell.targetCellId)) throw new Error(`复用 Cell ${cell.targetName} 端口、CrossSection 或 context 不同；请改为重命名导入`);
          if (JSON.stringify(original) !== JSON.stringify(incoming) || canonicalProperties(source.cellProperties?.[cell.sourceCellId]) !==
            canonicalProperties(structure.cellProperties[cell.targetCellId])) throw new Error(`复用 Cell ${cell.targetName} 内容或属性不同；请改为重命名导入`);
          continue;
        }
        for (const shape of shapes) {
          candidatePoints += shape.points.length;
          if (candidate.length >= 2000000 || candidatePoints > 25000000) throw new Error('合并后对象或顶点超过编辑预算');
          if (!Number.isSafeInteger(nextId) || nextId <= 0 || nextId >= Number.MAX_SAFE_INTEGER) throw new Error('图形 ID 超出安全范围');
          if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error(`导入输出层 ${pair(shape.layerNumber, shape.datatype)} 已锁定`);
          shape.id = nextId++; candidate.push(shape); addedIds.push(shape.id); imported++;
        }
      }
      const semanticMapping: number[] = source.cellNames.map((name: string, id: number): number =>
        ids.has(id) && cellMappings.get(id)?.action !== 'reuse' ? ids.get(id) as number : -1);
      const previousPortCount: number = (after.ports ?? []).length;
      mergeLayoutSemantics(after, source, semanticMapping);
      const importedPorts: number = (after.ports ?? []).length - previousPortCount;
      for (const port of (after.ports ?? []).slice(previousPortCount)) if (!editService.canEditLayer(port.layerNumber, port.datatype)) throw new Error('导入端口输出图层已锁定');
      // A legacy pure reuse is still a no-op. Allocate persisted v2 identities at
      // migration, rather than recording a hidden migration as an import edit.
      if (structure.cellKeys === undefined && after.cellNames.length === structure.cellNames.length &&
        (after.ports ?? []).length === 0 && (after.crossSections ?? []).length === 0 && (after.layoutContextRecords ?? []).length === 0 &&
        (after.cellContextRecords ?? []).every((records): boolean => records.length === 0)) {
        after.cellKeys = undefined; after.ports = undefined; after.crossSections = undefined;
        after.layoutContextRecords = undefined; after.cellContextRecords = undefined;
      }
      if (!Array.isArray(options.placements ?? []) || (options.placements?.length ?? 0) > 1000000) throw new Error('根 Cell 放置超过预算');
      for (const placement of options.placements ?? []) {
        if (candidate.length >= 2000000 || ++candidatePoints > 25000000) throw new Error('合并后对象或顶点超过编辑预算');
        if (placement === null || !included.has(placement.sourceCellId) || !validCellId(placement.targetCellId, structure.cellNames.length) ||
          !Number.isFinite(placement.xNm) || !Number.isFinite(placement.yNm) || !validLayer(placement.layer) || !validLayer(placement.datatype) ||
          (placement.rotation !== undefined && !Number.isFinite(placement.rotation)) ||
          (placement.mirror !== undefined && [0, 1, 2].indexOf(placement.mirror) < 0) ||
          (placement.magnification !== undefined && (!Number.isFinite(placement.magnification) || placement.magnification <= 0))) throw new Error('根 Cell 放置参数无效');
        if (!editService.canEditLayer(placement.layer, placement.datatype)) throw new Error('放置实例的图层已锁定');
        if (!Number.isSafeInteger(nextId) || nextId <= 0 || nextId >= Number.MAX_SAFE_INTEGER) throw new Error('图形 ID 超出安全范围');
        const cellId: number = ids.get(placement.sourceCellId) as number;
        candidate.push({ id: nextId, type: ShapeType.INSTANCE, layerNumber: placement.layer, datatype: placement.datatype,
          ownerCellId: placement.targetCellId, cellId: cellId, cellName: after.cellNames[cellId], selected: false,
          points: [{ x: placement.xNm, y: placement.yNm }], rotation: placement.rotation, mirror: placement.mirror,
          magnification: placement.magnification }); addedIds.push(nextId++);
      }
      const libraryProperties: LayoutPropRecord[] = options.libraryProperties !== 'merge' ? (after.libProperties ?? []) :
        mergeLibraryProperties(after.libProperties ?? [], source.libProperties ?? []);
      if (libraryProperties.length > 0 || after.libProperties !== undefined) after.libProperties = libraryProperties;
      const warnings: string[] = [];
      if (droppedPorts > 0) warnings.push(`显式图层丢弃将移除 ${droppedPorts} 个端口定义`);
      if (importedPorts > 0) warnings.push(`将导入 ${importedPorts} 个独立端口及完整 CrossSection/context`);
      if (options.libraryProperties !== 'merge' && (source.libProperties?.length ?? 0) > 0) warnings.push('源库属性未导入，保留目标库属性');
      const definitions: SourceLayerDefinition[] = this.mergeDefinitions(after.layerDefinitions ?? [], source.layerDefinitions ?? [], source.shapes,
        included, source.topCellId, layerMappings, warnings, options.layerNameConflictPolicy === 'reject');
      if (definitions.length > 0 || after.layerDefinitions !== undefined) after.layerDefinitions = definitions;
      validateSource(structureSource(candidate, after));
      const targetDbuNm: number = cleanDbuNm(structure.physicalUnits ?? 1e-9);
      let offGrid: number = 0; let maxError: number = 0;
      const inspect = (value: number | undefined): void => {
        if (value === undefined) return;
        const error: number = Math.abs(value - Math.round(value / targetDbuNm) * targetDbuNm);
        if (!Number.isFinite(error)) throw new Error('目标 DBU 无法表示源坐标');
        if (error > targetDbuNm * 1e-9) { offGrid++; maxError = Math.max(maxError, error); }
      };
      for (const shape of candidate.slice(existing.length)) {
        for (const point of shape.points) { inspect(point.x); inspect(point.y); }
        if (shape.type === ShapeType.PATH) { inspect(shape.pathWidth); inspect(shape.pathBeginExtension); inspect(shape.pathEndExtension); }
        if (shape.type === ShapeType.INSTANCE && (shape.arrayCols ?? 0) > 0 && (shape.arrayRows ?? 0) > 0) {
          const origin: Point = shape.points[0];
          inspect(origin.x + (shape.arrayCols ?? 0) * (shape.arrayColStepX ?? 0));
          inspect(origin.y + (shape.arrayCols ?? 0) * (shape.arrayColStepY ?? 0));
          inspect(origin.x + (shape.arrayRows ?? 0) * (shape.arrayRowStepX ?? 0));
          inspect(origin.y + (shape.arrayRows ?? 0) * (shape.arrayRowStepY ?? 0));
        }
      }
      if (offGrid > 0) warnings.push(`保持源 nm 坐标；按目标 DBU 保存时需确认量化，最大 ${Number(maxError.toPrecision(4))} nm`);
      const token: number = ++this.serial;
      this.pending = { token: token, documentIdentity: documentIdentity, revision: editService.getSessionRevision(),
        cellId: editService.getCurrentCellId(), fingerprint: this.computeContextFingerprint(existing, structure), before: cloneStructure(structure),
        after: after, shapes: candidate.map((shape: Shape): Shape => cloneShape(shape)), addedIds: addedIds.slice() };
      const preview: ImportMergePreview = { token: token, cells: cells, addedCells: cells.filter((cell: ImportMergedCell): boolean => cell.action === 'new').length,
        reusedCells: cells.filter((cell: ImportMergedCell): boolean => cell.action === 'reuse').length, importedObjects: imported,
        droppedObjects: dropped, placements: options.placements?.length ?? 0, sourceDbuNm: cleanDbuNm(source.physicalUnits),
        targetDbuNm: targetDbuNm, offGridCoordinateCount: offGrid, maxExportQuantizationNm: maxError, warnings: warnings,
        importedPorts: importedPorts, droppedPorts: droppedPorts };
      return { ok: true, message: `导入预览：${preview.addedCells} 个新 Cell、${imported} 个对象、${preview.placements} 个根实例`, preview: preview };
    } catch (error) { this.pending = null; return { ok: false, message: error instanceof Error ? error.message : String(error) }; }
  }

  apply(preview: ImportMergePreview, structure: EditStructureState, documentIdentity: string,
    rollbackStructure?: (state: EditStructureState) => void): ImportMergeResult {
    const pending: PreparedMerge | null = this.pending;
    if (pending === null || preview === null || pending.token !== preview.token) return { ok: false, message: '导入预览已取消或失效，请重新生成' };
    if (pending.documentIdentity !== documentIdentity || pending.revision !== editService.getSessionRevision() ||
      pending.cellId !== editService.getCurrentCellId() || pending.fingerprint !== this.computeContextFingerprint(editService.getShapes(), structure)) {
      this.pending = null; return { ok: false, message: '文档或 Cell 内容已变化，请重新生成导入预览' };
    }
    const added: Set<number> = new Set<number>(pending.addedIds);
    for (const shape of pending.shapes) if (added.has(shape.id) && !editService.canEditLayer(shape.layerNumber, shape.datatype)) {
      return { ok: false, message: '导入目标图层已锁定，请解锁后重新应用' };
    }
    const oldPorts: Set<string> = new Set<string>((pending.before.ports ?? []).map((port: LayoutPort): string => port.id));
    for (const port of pending.after.ports ?? []) if (!oldPorts.has(port.id) && !editService.canEditLayer(port.layerNumber, port.datatype)) {
      return { ok: false, message: '导入端口图层已锁定，请解锁后重新应用' };
    }
    const previous: EditSessionState = editService.captureSession();
    try {
      if (!editService.applyDocumentStructure(pending.shapes, pending.before, pending.after, `导入合并 · ${pending.addedIds.length} 个对象`)) {
        return { ok: false, message: '导入事务提交被拒绝，目标文档保留' };
      }
    } catch (error) {
      editService.restoreSession(previous); this.pending = null;
      let recovery: string = '';
      try {
        if (rollbackStructure !== undefined) rollbackStructure(cloneStructure(pending.before));
        else recovery = '；请刷新 Cell 结构后再试';
      } catch (failure) { recovery = `；Cell 结构恢复失败：${String(failure)}`; }
      return { ok: false, message: `导入事务失败，编辑会话已恢复：${String(error)}${recovery}` };
    }
    this.pending = null;
    return { ok: true, message: '导入合并已应用，可一次撤销', addedIds: pending.addedIds.slice() };
  }

  private mergeDefinitions(target: SourceLayerDefinition[], source: SourceLayerDefinition[], shapes: Shape[], included: Set<number>,
    top: number, mappings: Map<string, ImportLayerMapping>, warnings: string[], rejectConflicts: boolean): SourceLayerDefinition[] {
    const result: SourceLayerDefinition[] = target.map((definition: SourceLayerDefinition): SourceLayerDefinition => ({
      name: definition.name, textLayer: definition.textLayer,
      layer: { type: definition.layer.type, lower: definition.layer.lower, upper: definition.layer.upper },
      datatype: { type: definition.datatype.type, lower: definition.datatype.lower, upper: definition.datatype.upper } }));
    const known: Set<string> = new Set<string>(result.map((definition: SourceLayerDefinition): string => JSON.stringify(definition)));
    const sourceExact: Map<string, SourceLayerDefinition[]> = new Map<string, SourceLayerDefinition[]>();
    const sourceRanges: SourceLayerDefinition[] = [];
    const targetExact: Map<string, Set<string>> = new Map<string, Set<string>>();
    const targetRanges: SourceLayerDefinition[] = [];
    const definitionKey = (layer: number, datatype: number, text: boolean): string => `${pair(layer, datatype)}/${text ? 1 : 0}`;
    for (const definition of source) {
      if (definition.layer.lower !== definition.layer.upper || definition.datatype.lower !== definition.datatype.upper) { sourceRanges.push(definition); continue; }
      const key: string = definitionKey(definition.layer.lower, definition.datatype.lower, definition.textLayer);
      let list: SourceLayerDefinition[] | undefined = sourceExact.get(key);
      if (list === undefined) { list = []; sourceExact.set(key, list); } list.push(definition);
    }
    for (const definition of target) {
      if (definition.layer.lower !== definition.layer.upper || definition.datatype.lower !== definition.datatype.upper) { targetRanges.push(definition); continue; }
      const key: string = definitionKey(definition.layer.lower, definition.datatype.lower, definition.textLayer);
      let names: Set<string> | undefined = targetExact.get(key);
      if (names === undefined) { names = new Set<string>(); targetExact.set(key, names); } names.add(definition.name);
    }
    const pairs: Set<string> = new Set<string>();
    let comparisons: number = 0; let conflicts: number = 0;
    for (const shape of shapes) {
      if (!included.has(shape.ownerCellId ?? top) || shape.type === ShapeType.INSTANCE) continue;
      const key: string = `${pair(shape.layerNumber, shape.datatype)}/${shape.type === ShapeType.TEXT ? 1 : 0}`;
      if (pairs.has(key)) continue; pairs.add(key);
      const mapping: ImportLayerMapping | undefined = mappings.get(pair(shape.layerNumber, shape.datatype));
      if (mapping?.action === 'drop') continue;
      const matches: SourceLayerDefinition[] = (sourceExact.get(key) ?? []).slice();
      for (const definition of sourceRanges) {
        if (++comparisons > 2000000) throw new Error('图层名称区间匹配超过 200 万预算，请减少区间或分批导入');
        if (definition.textLayer === (shape.type === ShapeType.TEXT) && shape.layerNumber >= definition.layer.lower &&
          shape.layerNumber <= definition.layer.upper && shape.datatype >= definition.datatype.lower && shape.datatype <= definition.datatype.upper) matches.push(definition);
      }
      for (const definition of matches) {
        const layer: number = mapping?.targetLayer ?? shape.layerNumber; const datatype: number = mapping?.targetDatatype ?? shape.datatype;
        const targetKey: string = definitionKey(layer, datatype, definition.textLayer);
        let names: Set<string> | undefined = targetExact.get(targetKey);
        if (names === undefined) { names = new Set<string>(); targetExact.set(targetKey, names); }
        let conflict: boolean = Array.from(names).some((name: string): boolean => name !== definition.name);
        for (const previous of targetRanges) {
          if (++comparisons > 2000000) throw new Error('图层名称区间匹配超过 200 万预算，请减少区间或分批导入');
          if (previous.textLayer === definition.textLayer && layer >= previous.layer.lower && layer <= previous.layer.upper &&
            datatype >= previous.datatype.lower && datatype <= previous.datatype.upper && previous.name !== definition.name) conflict = true;
        }
        if (conflict) {
          if (rejectConflicts) throw new Error(`映射后的图层名称冲突：${pair(layer, datatype)}`);
          conflicts++; continue;
        }
        const next: SourceLayerDefinition = { name: definition.name, textLayer: definition.textLayer,
          layer: { type: 3, lower: layer, upper: layer }, datatype: { type: 3, lower: datatype, upper: datatype } };
        const encoded: string = JSON.stringify(next); if (known.has(encoded)) continue;
        if (result.length >= 100000) throw new Error('合并后图层名称定义超过预算');
        known.add(encoded); names.add(definition.name); result.push(next);
      }
    }
    if (source.some((definition: SourceLayerDefinition): boolean => definition.layer.type !== 3 || definition.datatype.type !== 3)) {
      warnings.push('源图层名称区间按已导入的实际 purpose 转为精确名称定义；未使用区间不导入');
    }
    if (conflicts > 0) warnings.push(`${conflicts} 项映射后图层名称冲突；保留目标或先出现的名称`);
    return result;
  }
}
export const importMergeService: ImportMergeService = new ImportMergeService();
