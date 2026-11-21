import { Shape, ShapeType, Point } from '../models/GdsiiData';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import { instanceTransformMat } from './HierarchyExpandService';
import type { Mat2D } from './HierarchyExpandService';
import { workspaceService } from './WorkspaceService';
import type { WorkspaceDocument } from './WorkspaceService';
import { editService } from './EditService';
import type { EditStructureState, EditSessionState } from './EditService';
import { resolveLayoutPort } from './PortService';
import { portDraft, portFromDraft, newLayoutIdentity } from '../models/LayoutPort';
import type { PortEndpoint, LayoutPort, LayoutPortDraft, ResolvedPort } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneShapeArray, cloneStructured } from '../common/CloneUtils';
import { legacyDocumentPrecision } from './PrecisionService';
import type { PrecisionSettings } from './PrecisionService';

export interface FlattenEstimate {
  instanceCount: number; arrayMembers: number; createdObjects: number; removedObjects: number;
  resultingObjects: number; resultingPoints: number; nestedInstances: number; warnings: string[];
  promotedPorts?: number; portNameConflicts?: number;
}
export interface FlattenPreview {
  documentId: string; revision: number; cellId: number; nextShapeId: number;
  instanceIds: number[]; createdIds: number[]; estimate: FlattenEstimate;
  sourceFingerprint: string; candidateFingerprint: string; candidate: WorkspaceDocument;
}
export interface FlattenPreviewResult { ok: boolean; message: string; estimate?: FlattenEstimate; preview?: FlattenPreview; }

const MAX_CREATED: number = 100000;

function documentFingerprint(doc: WorkspaceDocument): string {
  // View, timestamps and selected IDs may change while a confirmation is visible.
  return JSON.stringify([doc.id, doc.shapes, doc.cellNames, doc.cellProperties, doc.libProperties,
    doc.topCellId, doc.cellStack, doc.navigationPath, doc.userUnits, doc.physicalUnits, doc.precision, doc.pcells,
    doc.cellKeys, doc.ports, doc.crossSections, doc.layoutContextRecords, doc.cellContextRecords]);
}

function references(doc: WorkspaceDocument, ids: number[]): Shape[] {
  if (!Array.isArray(ids) || ids.length === 0 || ids.length > MAX_CREATED || new Set<number>(ids).size !== ids.length) throw new Error('展开需要明确且不重复的实例 ID');
  const byId: Map<number, Shape> = new Map<number, Shape>();
  for (const shape of doc.shapes) byId.set(shape.id, shape);
  return ids.map((id: number): Shape => {
    const item: Shape | undefined = byId.get(id);
    if (!Number.isSafeInteger(id) || item === undefined || item.type !== ShapeType.INSTANCE || item.cellId === undefined ||
      item.cellId < 0 || item.cellId >= doc.cellNames.length || item.cellId === (item.ownerCellId ?? doc.topCellId)) throw new Error('实例已失效或含自引用，请重新选择');
    return item;
  });
}

/** Count one-level output before allocating geometry. Nested references remain references. */
export function estimateFlatten(doc: WorkspaceDocument, ids: number[]): FlattenEstimate {
  const selected: Shape[] = references(doc, ids);
  const local: Map<number, Shape[]> = new Map<number, Shape[]>();
  let originalPoints: number = 0;
  for (const shape of doc.shapes) {
    const owner: number = shape.ownerCellId ?? doc.topCellId;
    const bucket: Shape[] = local.get(owner) ?? []; bucket.push(shape); local.set(owner, bucket);
    originalPoints += shape.points.length;
  }
  const estimate: FlattenEstimate = { instanceCount: selected.length, arrayMembers: 0, createdObjects: 0, removedObjects: selected.length,
    resultingObjects: doc.shapes.length - selected.length, resultingPoints: originalPoints, nestedInstances: 0, warnings: [] };
  for (const instance of selected) {
    if ([instance.arrayCols ?? 1, instance.arrayRows ?? 1].some((n: number): boolean => !Number.isInteger(n) || n < 0 || n > 32767)) throw new Error('阵列数量须为 0–32767 整数');
    const members: number = Math.max(1, instance.arrayCols ?? 1) * Math.max(1, instance.arrayRows ?? 1);
    if (!Number.isSafeInteger(members) || members < 1) throw new Error('阵列成员数量无效');
    estimate.arrayMembers += members;
    estimate.resultingPoints -= instance.points.length;
    for (const child of local.get(instance.cellId ?? -1) ?? []) {
      estimate.createdObjects += members;
      estimate.resultingPoints += members * (child.type === ShapeType.RECT && child.points.length === 2 ? 4 : child.points.length);
      if (child.type === ShapeType.INSTANCE) estimate.nestedInstances += members;
    }
  }
  estimate.resultingObjects += estimate.createdObjects;
  if (![estimate.arrayMembers, estimate.createdObjects, estimate.resultingObjects, estimate.resultingPoints].every((n: number): boolean => Number.isSafeInteger(n))) throw new Error('展开数量超出可靠计数范围');
  if (estimate.createdObjects > 10000) estimate.warnings.push(`将创建 ${estimate.createdObjects} 个对象，准备与保存会占用更多内存`);
  if (estimate.createdObjects > MAX_CREATED) estimate.warnings.push('超过单次 10 万新对象预算，请减少实例或阵列成员');
  if (estimate.nestedInstances > 0) estimate.warnings.push(`仅展开一层，保留 ${estimate.nestedInstances} 个嵌套实例`);
  if (estimate.createdObjects === 0) estimate.warnings.push('目标 Cell 没有本地对象；应用只会删除这些空引用');
  return estimate;
}

function cloneTemplate(source: Shape): Shape {
  const copy: Shape = cloneStructured(source) as Shape;
  copy.id = 0; copy.selected = false;
  const properties: LayoutPropRecord[] = (copy.properties ?? []).filter((item: LayoutPropRecord): boolean => !item.value.startsWith('HONGTU_PCELL_V1:'));
  copy.properties = properties.length === 0 ? undefined : properties;
  return copy;
}

/** Preserve primitive metadata while applying the same GDS transform as the existing editor. */
export function transformFlattenPrimitive(source: Shape, matrix: Mat2D): Shape {
  const copy: Shape = cloneTemplate(source);
  let points: Point[] = source.points;
  if (source.type === ShapeType.RECT && points.length === 2) {
    const a: Point = points[0]; const b: Point = points[1];
    points = [{ x: a.x, y: a.y }, { x: b.x, y: a.y }, { x: b.x, y: b.y }, { x: a.x, y: b.y }];
  }
  copy.type = source.type === ShapeType.RECT ? ShapeType.POLYGON : source.type;
  copy.points = points.map((point: Point): Point => ({ x: matrix.a * point.x + matrix.b * point.y + matrix.tx,
    y: matrix.c * point.x + matrix.d * point.y + matrix.ty }));
  const determinant: number = matrix.a * matrix.d - matrix.b * matrix.c;
  const scale: number = Math.sqrt(Math.abs(determinant));
  if (source.pathWidth !== undefined) copy.pathWidth = source.pathWidthAbsolute ? source.pathWidth : source.pathWidth * scale;
  if (source.pathBeginExtension !== undefined) copy.pathBeginExtension = source.pathBeginExtension * scale;
  if (source.pathEndExtension !== undefined) copy.pathEndExtension = source.pathEndExtension * scale;
  if (source.type === ShapeType.TEXT) {
    const parentAngle: number = Math.atan2(matrix.c, matrix.a) * 180 / Math.PI;
    const childAngle: number = (source.rotation ?? 0) + (source.mirror === 2 ? 180 : 0);
    copy.rotation = parentAngle + (determinant < 0 ? -childAngle : childAngle);
    copy.mirror = (determinant < 0) !== ((source.mirror ?? 0) !== 0) ? 1 : 0;
    copy.magnification = (source.magnification ?? 1) * scale;
  }
  return copy;
}

export function composeFlattenInstance(parent: Shape, child: Shape, matrix: Mat2D): Shape {
  const copy: Shape = cloneTemplate(child);
  const pMirror: boolean = (parent.mirror ?? 0) !== 0; const cMirror: boolean = (child.mirror ?? 0) !== 0;
  const pRotation: number = (parent.rotation ?? 0) + (parent.mirror === 2 ? 180 : 0);
  const cRotation: number = (child.rotation ?? 0) + (child.mirror === 2 ? 180 : 0);
  const rotation: number = pMirror ? pRotation - cRotation : pRotation + cRotation;
  const origin: Point = child.points[0];
  copy.points = [{ x: matrix.a * origin.x + matrix.b * origin.y + matrix.tx, y: matrix.c * origin.x + matrix.d * origin.y + matrix.ty }];
  copy.rotation = ((rotation % 360) + 360) % 360; copy.mirror = pMirror !== cMirror ? 1 : 0;
  copy.magnification = (parent.magnification ?? 1) * (child.magnification ?? 1);
  copy.arrayColStepX = matrix.a * (child.arrayColStepX ?? 0) + matrix.b * (child.arrayColStepY ?? 0);
  copy.arrayColStepY = matrix.c * (child.arrayColStepX ?? 0) + matrix.d * (child.arrayColStepY ?? 0);
  copy.arrayRowStepX = matrix.a * (child.arrayRowStepX ?? 0) + matrix.b * (child.arrayRowStepY ?? 0);
  copy.arrayRowStepY = matrix.c * (child.arrayRowStepX ?? 0) + matrix.d * (child.arrayRowStepY ?? 0);
  return copy;
}

export class FlattenPreviewService {
  estimate(doc: WorkspaceDocument, ids: number[]): FlattenPreviewResult {
    try { const estimate: FlattenEstimate = estimateFlatten(doc, ids); return { ok: true, message: `${estimate.instanceCount} 条实例记录 → ${estimate.createdObjects} 个新对象`, estimate }; }
    catch (error) { return { ok: false, message: String(error) }; }
  }

  prepare(doc: WorkspaceDocument, ids: number[]): FlattenPreviewResult {
    try {
      const source: WorkspaceDocument = workspaceService.cloneValidatedDocument(doc);
      if (source.viewMode === 'viewer') throw new Error('只读文档不能展开实例');
      if (JSON.stringify(source.shapes) !== JSON.stringify(cloneShapeArray(editService.getShapes(), true))) throw new Error('文档几何已变化，请重新准备展开');
      const estimate: FlattenEstimate = estimateFlatten(source, ids);
      if (estimate.createdObjects > MAX_CREATED || estimate.resultingObjects > 1000000 || estimate.resultingPoints > 4000000) return { ok: false, message: '展开超过对象或顶点预算，原图已保留', estimate };
      const selected: Shape[] = references(source, ids);
      const local: Map<number, Shape[]> = new Map<number, Shape[]>();
      for (const shape of source.shapes) {
        const owner: number = shape.ownerCellId ?? source.topCellId;
        const bucket: Shape[] = local.get(owner) ?? []; bucket.push(shape); local.set(owner, bucket);
      }
      let nextId: number = editService.getNextShapeId();
      if (!Number.isSafeInteger(nextId) || nextId <= 0 || source.shapes.some((shape: Shape): boolean => shape.id >= nextId) || !Number.isSafeInteger(nextId + estimate.createdObjects)) throw new Error('新对象 ID 分配状态无效');
      const candidate: WorkspaceDocument = cloneStructured(source) as WorkspaceDocument;
      const portStructure: EditStructureState = { cellNames: source.cellNames, cellProperties: source.cellProperties, topCellId: source.topCellId,
        cellStack: source.cellStack, cellKeys: source.cellKeys, ports: source.ports, crossSections: source.crossSections,
        layoutContextRecords: source.layoutContextRecords, cellContextRecords: source.cellContextRecords };
      estimate.promotedPorts = 0; estimate.portNameConflicts = 0;
      const removed: Set<number> = new Set<number>(ids); const createdIds: number[] = [];
      candidate.shapes = candidate.shapes.filter((shape: Shape): boolean => !removed.has(shape.id));
      for (const instance of selected) {
        if (!editService.canEditLayer(instance.layerNumber, instance.datatype)) throw new Error(`实例 L${instance.layerNumber}/D${instance.datatype} 已锁定`);
        const matrix: Mat2D = instanceTransformMat(instance);
        const children: Shape[] = local.get(instance.cellId ?? -1) ?? [];
        const owner: number = instance.ownerCellId ?? source.topCellId;
        for (const port of source.ports ?? []) if (port.ownerCellId === instance.cellId) {
          if (!editService.canEditLayer(port.layerNumber, port.datatype)) throw new Error('展开端口输出图层已锁定');
          for (let row: number = 0; row < Math.max(1, instance.arrayRows ?? 1); row++) for (let col: number = 0; col < Math.max(1, instance.arrayCols ?? 1); col++) {
            const endpoint: PortEndpoint = { portId: port.id, rootCellId: owner, rootCellKey: (source.cellKeys ?? [])[owner],
              path: [{ parentCellId: owner, cellId: port.ownerCellId, instanceId: instance.id, row: row, col: col,
                transform: { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 } }] };
            const resolved: ResolvedPort = resolveLayoutPort(endpoint, source.shapes, portStructure);
            const draft: LayoutPortDraft = portDraft(port); draft.centerNm = resolved.centerNm; draft.orientationDeg = resolved.orientationDeg;
            draft.frameMirror = resolved.frameMirror; draft.frameMagnification = resolved.frameMagnification;
            const base: string = `${port.name.slice(0, 360)}_i${instance.id}_r${row}_c${col}`; let name: string = base; let suffix: number = 1;
            while ((candidate.ports ?? []).some((item: LayoutPort): boolean => item.ownerCellId === owner && item.name === name)) {
              name = `${base}_${suffix++}`; estimate.portNameConflicts = (estimate.portNameConflicts ?? 0) + 1;
            }
            draft.name = name; draft.provenance = JSON.stringify({ kind: 'flatten-snapshot', sourcePortId: port.id, sourceCellKey: port.ownerCellKey,
              instanceId: instance.id, row: row, col: col, previous: port.provenance ?? '' });
            (candidate.ports ?? []).push(portFromDraft(newLayoutIdentity('port'), owner, (candidate.cellKeys ?? [])[owner], draft));
            estimate.promotedPorts = (estimate.promotedPorts ?? 0) + 1;
            if ((candidate.ports ?? []).length > 100000) throw new Error('展开后端口超过 10 万预算');
          }
        }
        for (const child of children) {
          if (!editService.canEditLayer(child.layerNumber, child.datatype)) throw new Error(`子对象 L${child.layerNumber}/D${child.datatype} 已锁定`);
          for (let row: number = 0; row < Math.max(1, instance.arrayRows ?? 1); row++) {
            for (let col: number = 0; col < Math.max(1, instance.arrayCols ?? 1); col++) {
              const element: Mat2D = { a: matrix.a, b: matrix.b, c: matrix.c, d: matrix.d,
                tx: matrix.tx + col * (instance.arrayColStepX ?? 0) + row * (instance.arrayRowStepX ?? 0),
                ty: matrix.ty + col * (instance.arrayColStepY ?? 0) + row * (instance.arrayRowStepY ?? 0) };
              const copy: Shape = child.type === ShapeType.INSTANCE ? composeFlattenInstance(instance, child, element) : transformFlattenPrimitive(child, element);
              copy.id = nextId++; copy.ownerCellId = instance.ownerCellId ?? source.topCellId;
              candidate.shapes.push(copy); createdIds.push(copy.id);
            }
          }
        }
      }
      candidate.selectedIds = candidate.selectedIds.filter((id: number): boolean => !removed.has(id));
      const validated: WorkspaceDocument = workspaceService.cloneValidatedDocument(candidate);
      if ((estimate.promotedPorts ?? 0) > 0) estimate.warnings.push(`将提升 ${estimate.promotedPorts} 个独立端口快照；名称冲突 ${estimate.portNameConflicts} 次`);
      const preview: FlattenPreview = { documentId: source.id, revision: editService.getSessionRevision(), cellId: editService.getCurrentCellId(),
        nextShapeId: editService.getNextShapeId(), instanceIds: ids.slice(), createdIds, estimate, sourceFingerprint: documentFingerprint(source),
        candidateFingerprint: documentFingerprint(validated), candidate: validated };
      return { ok: true, message: `${estimate.instanceCount} 条实例记录展开为 ${estimate.createdObjects} 个对象，可一次撤销`, estimate, preview };
    } catch (error) { return { ok: false, message: `展开准备失败，原图已保留：${String(error)}` }; }
  }

  apply(preview: FlattenPreview, current: WorkspaceDocument, structure: EditStructureState): FlattenPreviewResult {
    let previous: EditSessionState | undefined;
    try {
      if (preview.documentId !== current.id || preview.revision !== editService.getSessionRevision() || preview.cellId !== editService.getCurrentCellId() ||
        preview.nextShapeId !== editService.getNextShapeId()) throw new Error('文档、编辑范围或版本已变化，请重新准备展开');
      const source: WorkspaceDocument = workspaceService.cloneValidatedDocument(current);
      if (source.viewMode === 'viewer' || documentFingerprint(source) !== preview.sourceFingerprint || JSON.stringify(source.shapes) !== JSON.stringify(cloneShapeArray(editService.getShapes(), true))) throw new Error('原对象或文档结构已变化，请重新准备展开');
      const expectedPrecision: PrecisionSettings = source.precision ?? legacyDocumentPrecision(source.physicalUnits, source.gridSize);
      const currentPrecision: PrecisionSettings | undefined = structure.precision;
      const precisionChanged: boolean = currentPrecision !== undefined &&
        (currentPrecision.dbuNm !== expectedPrecision.dbuNm ||
          currentPrecision.drawStepNm !== expectedPrecision.drawStepNm ||
          currentPrecision.displayGridNm !== expectedPrecision.displayGridNm ||
          currentPrecision.geometrySnapEnabled !== expectedPrecision.geometrySnapEnabled ||
          JSON.stringify(currentPrecision.geometrySnapKinds) !== JSON.stringify(expectedPrecision.geometrySnapKinds));
      if (JSON.stringify(structure.cellNames) !== JSON.stringify(source.cellNames) || JSON.stringify(structure.cellProperties) !== JSON.stringify(source.cellProperties) ||
        JSON.stringify(structure.libProperties ?? []) !== JSON.stringify(source.libProperties) || structure.topCellId !== source.topCellId ||
        JSON.stringify(structure.cellStack) !== JSON.stringify(source.cellStack) || JSON.stringify(structure.navigationPath ?? []) !== JSON.stringify(source.navigationPath ?? []) ||
        (structure.userUnits !== undefined && structure.userUnits !== source.userUnits) || (structure.physicalUnits !== undefined && structure.physicalUnits !== source.physicalUnits) ||
        precisionChanged) throw new Error('事务结构与当前文档不一致，请重新准备展开');
      if (documentFingerprint(preview.candidate) !== preview.candidateFingerprint) throw new Error('预览内容已变化，请重新准备展开');
      const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(preview.candidate);
      for (const field of ['cellKeys', 'ports', 'crossSections', 'layoutContextRecords', 'cellContextRecords']) {
        const old: Record<string, Object> = structure as Object as Record<string, Object>;
        const live: Record<string, Object> = source as Object as Record<string, Object>;
        if (old[field] !== undefined && JSON.stringify(old[field]) !== JSON.stringify(live[field])) throw new Error('端口或 context 已变化，请重新准备展开');
      }
      // Reject changed locks before captureSession/apply can close an unrelated pending transaction.
      for (const shape of references(source, preview.instanceIds)) if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error('实例图层已锁定');
      const created: Set<number> = new Set<number>(preview.createdIds);
      for (const shape of candidate.shapes) if (created.has(shape.id) && !editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error('展开输出图层已锁定');
      const oldPorts: Set<string> = new Set<string>((source.ports ?? []).map((port: LayoutPort): string => port.id));
      for (const port of candidate.ports ?? []) if (!oldPorts.has(port.id) && !editService.canEditLayer(port.layerNumber, port.datatype)) throw new Error('展开端口输出图层已锁定');
      previous = editService.captureSession();
      const after: EditStructureState = cloneEditStructureModel(structure, true) as EditStructureState;
      after.cellKeys = candidate.cellKeys; after.ports = candidate.ports; after.crossSections = candidate.crossSections;
      after.layoutContextRecords = candidate.layoutContextRecords; after.cellContextRecords = candidate.cellContextRecords;
      if (!editService.applyDocumentStructure(candidate.shapes, structure, after, `展开 ${preview.estimate.instanceCount} 条实例 → ${preview.estimate.createdObjects} 个对象`, true, [])) throw new Error('展开事务提交被拒绝');
      editService.clearSelection();
      return { ok: true, message: `已展开 ${preview.estimate.instanceCount} 条实例，新增 ${preview.estimate.createdObjects} 个对象，可一次撤销`, estimate: preview.estimate };
    } catch (error) {
      if (previous !== undefined) editService.restoreSession(previous);
      return { ok: false, message: `展开未提交，原图已保留：${String(error)}` };
    }
  }
}
export const flattenPreviewService: FlattenPreviewService = new FlattenPreviewService();
