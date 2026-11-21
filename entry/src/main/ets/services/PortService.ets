import { Shape, ShapeType, Point } from '../models/GdsiiData';
import { LayoutPort, LayoutPortDraft, PortEndpoint, ResolvedPort, newLayoutIdentity, portFromDraft, portDraft,
  normalizeLayoutSemantics, validateLayoutSemantics, normalizePortAngle, reconcilePortCrossSection, assertPortRemovalSafe } from '../models/LayoutPort';
import { EditService, editService } from './EditService';
import type { EditStructureState, InstancePathStep, IndependentPathPlanResult, IndependentPathRemap, IndependentPathPiece } from './EditService';
import { instanceTransformMat, Mat2D } from './HierarchyExpandService';
import { validatePropertyHierarchy } from './ShapePropertyService';
import { cloneEditStructureModel, clonePortEndpointModel, cloneShapeArray, cloneStructured } from '../common/CloneUtils';

export interface PortContext { documentIdentity: string; structure: EditStructureState; }
export interface PortAddRequest { kind: 'add'; ownerCellId: number; draft: LayoutPortDraft; }
export interface PortUpdateRequest { kind: 'update'; portId: string; draft: LayoutPortDraft; }
export interface PortRemoveRequest { kind: 'remove'; portId: string; }
export interface PortCopyRequest { kind: 'copy'; endpoint: PortEndpoint; name: string; }
export interface PortConnectRequest { kind: 'connect'; moving: PortEndpoint; target: PortEndpoint; overlapNm?: number; }
export type PortRequest = PortAddRequest | PortUpdateRequest | PortRemoveRequest | PortCopyRequest | PortConnectRequest;
export interface PortPreview {
  id: string; kind: 'add' | 'update' | 'remove' | 'copy' | 'connect'; addedPorts: number; removedPorts: number;
  updatedPorts: number; clonedCells: number; isolatedArrayMembers: number; movedInstanceId?: number; warnings: string[];
  movingEndpoint?: PortEndpoint; targetEndpoint?: PortEndpoint; resolvedBefore?: ResolvedPort; resolvedAfter?: ResolvedPort;
  affectedPortIds?: string[];
}
export interface PortResult { ok: boolean; message: string; preview?: PortPreview; }
interface PortPlan { shapes: Shape[]; structure: EditStructureState; preview: PortPreview; }
interface PortPending { id: string; documentIdentity: string; before: EditStructureState; source: string; candidate: string; plan: PortPlan; }
function cloneStructure(state: EditStructureState): EditStructureState { return cloneEditStructureModel(state, true) as EditStructureState; }
function identity(): Mat2D { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }
function compose(left: Mat2D, right: Mat2D): Mat2D {
  return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
    c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
    tx: left.a * right.tx + left.b * right.ty + left.tx, ty: left.c * right.tx + left.d * right.ty + left.ty };
}
function point(matrix: Mat2D, local: Point): Point { return { x: matrix.a * local.x + matrix.b * local.y + matrix.tx,
  y: matrix.c * local.x + matrix.d * local.y + matrix.ty }; }
function inverse(matrix: Mat2D): Mat2D {
  const determinant: number = matrix.a * matrix.d - matrix.b * matrix.c;
  if (!Number.isFinite(determinant) || determinant === 0) throw new Error('实例 frame 不可逆');
  const a: number = matrix.d / determinant, b: number = -matrix.b / determinant, c: number = -matrix.c / determinant, d: number = matrix.a / determinant;
  return { a, b, c, d, tx: -a * matrix.tx - b * matrix.ty, ty: -c * matrix.tx - d * matrix.ty };
}
function grid(value: number, dbu: number): void {
  if (!Number.isFinite(value) || !Number.isFinite(dbu) || dbu <= 0 || Math.abs(value / dbu - Math.round(value / dbu)) >
    Math.max(1, Math.abs(value / dbu)) * 1e-10 || Math.abs(value / dbu) > 2147483647) throw new Error('端口或连接 placement 必须精确落在文档 DBU 内，未进行静默量化');
}
function memberMatrix(shape: Shape, row: number, col: number): Mat2D {
  const matrix: Mat2D = instanceTransformMat(shape);
  matrix.tx += col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0);
  matrix.ty += col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0); return matrix;
}
function resolveMatrix(endpoint: PortEndpoint, shapes: Shape[], structure: EditStructureState): Mat2D {
  if (endpoint === null || !Number.isInteger(endpoint.rootCellId) || endpoint.rootCellId < 0 || endpoint.rootCellId >= structure.cellNames.length ||
    (structure.cellKeys ?? [])[endpoint.rootCellId] !== endpoint.rootCellKey || !Array.isArray(endpoint.path) || endpoint.path.length > 32) throw new Error('端点坐标根或具体路径无效');
  let owner: number = endpoint.rootCellId, matrix: Mat2D = identity(); const visited: Set<number> = new Set<number>([owner]);
  for (const step of endpoint.path) {
    const instance: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === step.instanceId);
    if (instance === undefined || instance.type !== ShapeType.INSTANCE || (instance.ownerCellId ?? structure.topCellId) !== owner ||
      step.parentCellId !== owner || instance.cellId !== step.cellId || visited.has(step.cellId) ||
      !Number.isInteger(step.row) || !Number.isInteger(step.col) || step.row < 0 || step.col < 0 ||
      step.row >= Math.max(1, instance.arrayRows ?? 1) || step.col >= Math.max(1, instance.arrayCols ?? 1)) throw new Error('端点路径或阵列成员已失效');
    matrix = compose(matrix, memberMatrix(instance, step.row, step.col));
    if (![matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].every((n: number): boolean => Number.isFinite(n))) throw new Error('端口投影超出有限数值');
    owner = step.cellId; visited.add(owner);
  }
  const port: LayoutPort | undefined = (structure.ports ?? []).find((item: LayoutPort): boolean => item.id === endpoint.portId);
  if (port === undefined || port.ownerCellId !== owner || port.ownerCellKey !== (structure.cellKeys ?? [])[owner]) throw new Error('端口定义与端点 owner 不一致');
  return matrix;
}
export function resolveLayoutPort(endpoint: PortEndpoint, shapes: Shape[], structure: EditStructureState): ResolvedPort {
  const matrix: Mat2D = resolveMatrix(endpoint, shapes, structure);
  const definition: LayoutPort = cloneStructured((structure.ports ?? []).find((item: LayoutPort): boolean => item.id === endpoint.portId)) as LayoutPort;
  const determinant: number = matrix.a * matrix.d - matrix.b * matrix.c;
  const mirror: boolean = determinant < 0, angle: number = Math.atan2(matrix.c, matrix.a) * 180 / Math.PI;
  const magnification: number = Math.sqrt(Math.abs(determinant)) * definition.frameMagnification;
  const center: Point = point(matrix, { x: definition.centerNm.x, y: definition.centerNm.y });
  if (!Number.isFinite(center.x) || !Number.isFinite(center.y) || !Number.isFinite(magnification) || magnification <= 0 ||
    !Number.isFinite(definition.widthNm * magnification)) throw new Error('端口投影 frame 越界');
  return { definition: definition, endpoint: clonePortEndpointModel(endpoint) as PortEndpoint, centerNm: center,
    orientationDeg: normalizePortAngle(angle + (mirror ? -definition.orientationDeg : definition.orientationDeg)),
    frameMirror: mirror !== definition.frameMirror, frameMagnification: magnification, effectiveWidthNm: definition.widthNm * magnification };
}

export function projectLayoutPorts(shapes: Shape[], structure: EditStructureState, rootCellId: number,
  maxDepth: number = 32, maxPlacements: number = 100000): ResolvedPort[] {
  validateLayoutSemantics(structure, structure.cellNames.length);
  if (!Number.isInteger(maxDepth) || maxDepth < 1 || maxDepth > 32 || !Number.isInteger(maxPlacements) || maxPlacements < 1 || maxPlacements > 100000) throw new Error('端口投影预算无效');
  const result: ResolvedPort[] = []; let placements: number = 0;
  const portsByCell: Map<number, LayoutPort[]> = new Map<number, LayoutPort[]>(), instancesByCell: Map<number, Shape[]> = new Map<number, Shape[]>();
  for (const port of structure.ports ?? []) { const group: LayoutPort[] = portsByCell.get(port.ownerCellId) ?? []; group.push(port); portsByCell.set(port.ownerCellId, group); }
  for (const shape of shapes) if (shape.type === ShapeType.INSTANCE) { const owner: number = shape.ownerCellId ?? structure.topCellId;
    const group: Shape[] = instancesByCell.get(owner) ?? []; group.push(shape); instancesByCell.set(owner, group); }
  const visit = (cell: number, path: InstancePathStep[], ancestors: number[]): void => {
    if (ancestors.indexOf(cell) >= 0 || path.length > maxDepth) throw new Error('端口层级循环或超过投影深度预算');
    for (const port of portsByCell.get(cell) ?? []) {
      if (result.length >= 100000) throw new Error('投影端点超过 10 万预算');
      result.push(resolveLayoutPort({ portId: port.id, rootCellId: rootCellId, rootCellKey: (structure.cellKeys ?? [])[rootCellId], path: path }, shapes, structure));
    }
    for (const shape of instancesByCell.get(cell) ?? []) {
      for (let row: number = 0; row < Math.max(1, shape.arrayRows ?? 1); row++) for (let col: number = 0; col < Math.max(1, shape.arrayCols ?? 1); col++) {
        if (++placements > maxPlacements) throw new Error('端口层级 placement 超过投影预算');
        const step: InstancePathStep = { parentCellId: cell, cellId: shape.cellId ?? -1, instanceId: shape.id, row: row, col: col,
          transform: { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 } };
        visit(step.cellId, path.concat([step]), ancestors.concat([cell]));
      }
    }
  };
  if (!Number.isInteger(rootCellId) || rootCellId < 0 || rootCellId >= structure.cellNames.length) throw new Error('端口投影根 Cell 无效');
  visit(rootCellId, [], []); return result;
}

function remapEndpoint(endpoint: PortEndpoint, definition: LayoutPort, plan: IndependentPathPlanResult): PortEndpoint {
  const shapes: Shape[] = plan.shapes ?? [], structure: EditStructureState | undefined = plan.structure;
  if (structure === undefined) throw new Error('隔离路径缺少结构候选');
  const copy: PortEndpoint = clonePortEndpointModel(endpoint) as PortEndpoint;
  let owner: number = copy.rootCellId, activeShapeMap: number[][] = [];
  for (const step of copy.path) {
    const sourceId: number = step.instanceId;
    const mapped: number[] | undefined = activeShapeMap.find((pair: number[]): boolean => pair[0] === sourceId);
    let id: number = mapped?.[1] ?? sourceId;
    const remap: IndependentPathRemap | undefined = (plan.remaps ?? []).find((item: IndependentPathRemap): boolean =>
      item.sourceInstanceId === sourceId && item.sourceOwnerCellId === step.parentCellId && item.targetOwnerCellId === owner);
    if (remap !== undefined) {
      const piece: IndependentPathPiece | undefined = remap.pieces.find((item: IndependentPathPiece): boolean =>
        step.row >= item.row && step.row < item.row + item.rows && step.col >= item.col && step.col < item.col + item.cols);
      if (piece === undefined) throw new Error('目标阵列成员没有保留到隔离候选');
      id = piece.instanceId; step.row -= piece.row; step.col -= piece.col;
      // Only the selected piece references the cloned definition. Other pieces
      // retain the original child and its object identities.
      const placement: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === id);
      activeShapeMap = placement?.cellId === remap.targetCellId ? remap.shapeIds : [];
    } else activeShapeMap = [];
    const instance: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === id);
    if (instance === undefined || instance.type !== ShapeType.INSTANCE || (instance.ownerCellId ?? structure.topCellId) !== owner) throw new Error('连接目标路径重绑定失败');
    step.instanceId = id; step.parentCellId = owner; step.cellId = instance.cellId ?? -1; owner = step.cellId;
  }
  const port: LayoutPort | undefined = (structure.ports ?? []).find((item: LayoutPort): boolean => item.ownerCellId === owner && item.name === definition.name && item.portType === definition.portType);
  if (port === undefined) throw new Error('连接目标端口重绑定失败');
  copy.portId = port.id; return copy;
}

/** All geometry/metadata are sealed together and commit through the existing structure history. */
export class PortService {
  private edit: EditService;
  private pending: PortPending | null = null;
  constructor(edit: EditService = editService) { this.edit = edit; }
  private fingerprint(context: PortContext): string {
    return JSON.stringify([context.documentIdentity, context.structure, this.edit.getSessionRevision(), this.edit.getCurrentCellId(),
      this.edit.getSelectionIdentity(), this.edit.getShapes(), this.edit.getNextShapeId()]);
  }
  private context(context: PortContext): void {
    if (context === null || typeof context.documentIdentity !== 'string' || context.documentIdentity.length < 1 ||
      context.documentIdentity.length > 4096 || context.structure.topCellId !== this.edit.getTopCellId() ||
      JSON.stringify(context.structure.cellStack) !== JSON.stringify(this.edit.getCurrentCellStack())) throw new Error('端口文档或 Cell 上下文已变化');
    validateLayoutSemantics(context.structure, context.structure.cellNames.length);
    const hierarchyError: string = validatePropertyHierarchy(this.edit.getShapes(), context.structure.topCellId);
    if (hierarchyError.length > 0) throw new Error(hierarchyError);
  }
  resolve(endpoint: PortEndpoint, context: PortContext): ResolvedPort { this.context(context); return resolveLayoutPort(endpoint, this.edit.getShapes(), context.structure); }
  project(rootCellId: number, context: PortContext): ResolvedPort[] { this.context(context); return projectLayoutPorts(this.edit.getShapes(), context.structure, rootCellId); }
  cancel(id?: string): void { if (id === undefined || this.pending?.id === id) this.pending = null; }
  private live(pending: PortPending): boolean {
    return pending.source === this.fingerprint({ documentIdentity: pending.documentIdentity, structure: pending.before }) &&
      pending.candidate === JSON.stringify(pending.plan);
  }
  getPreviewShapes(id: string): Shape[] {
    const pending: PortPending | null = this.pending;
    return pending === null || pending.id !== id || !this.live(pending) ? [] : cloneShapeArray(pending.plan.shapes, true) as Shape[];
  }
  getPreviewStructure(id: string): EditStructureState | undefined {
    const pending: PortPending | null = this.pending;
    return pending === null || pending.id !== id || !this.live(pending) ? undefined : cloneStructure(pending.plan.structure);
  }
  resolvePreview(id: string, endpoint: PortEndpoint): ResolvedPort {
    const pending: PortPending | null = this.pending;
    if (pending === null || pending.id !== id || !this.live(pending)) throw new Error('端口预览已过期');
    return resolveLayoutPort(endpoint, pending.plan.shapes, pending.plan.structure);
  }
  /** Validate the sealed snapshot once for a synchronous bounded UI batch. */
  resolvePreviewBatch(id: string, endpoints: PortEndpoint[]): ResolvedPort[] {
    const pending: PortPending | null = this.pending;
    if (pending === null || pending.id !== id || !this.live(pending)) throw new Error('端口预览已过期');
    if (!Array.isArray(endpoints) || endpoints.length > 2000) throw new Error('候选端口显示预算无效');
    return endpoints.map((endpoint: PortEndpoint): ResolvedPort => resolveLayoutPort(endpoint, pending.plan.shapes, pending.plan.structure));
  }
  private checkPortLayer(port: LayoutPort): void { if (!this.edit.canEditLayer(port.layerNumber, port.datatype)) throw new Error(`端口 L${port.layerNumber}/D${port.datatype} 已锁定`); }
  prepare(context: PortContext, request: PortRequest): PortResult {
    this.pending = null;
    try {
      this.context(context); const source: string = this.fingerprint(context);
      let shapes: Shape[] = cloneShapeArray(this.edit.getShapes(), true) as Shape[];
      let after: EditStructureState = cloneStructure(context.structure); normalizeLayoutSemantics(after, after.cellNames.length);
      const current: number = this.edit.getCurrentCellId(), dbu: number = after.physicalUnits === undefined ? (after.precision?.dbuNm ?? 1) : after.physicalUnits * 1e9;
      const preview: PortPreview = { id: newLayoutIdentity('port-preview'), kind: request.kind, addedPorts: 0, removedPorts: 0,
        updatedPorts: 0, clonedCells: 0, isolatedArrayMembers: 0, warnings: [], affectedPortIds: [] };
      if (request.kind === 'add' || request.kind === 'update') {
        const previous: LayoutPort | undefined = request.kind === 'update' ? (after.ports ?? []).find((port: LayoutPort): boolean => port.id === request.portId) : undefined;
        const owner: number = request.kind === 'add' ? request.ownerCellId : (previous?.ownerCellId ?? -1);
        if (owner !== current || (request.kind === 'update' && previous === undefined)) throw new Error('请选择当前 Cell 的端口定义');
        if (previous !== undefined) this.checkPortLayer(previous);
        const draft: LayoutPortDraft = reconcilePortCrossSection(after, previous, request.draft);
        const port: LayoutPort = portFromDraft(previous?.id ?? newLayoutIdentity('port'), owner, (after.cellKeys ?? [])[owner], draft);
        preview.affectedPortIds = [port.id];
        this.checkPortLayer(port); grid(port.centerNm.x, dbu); grid(port.centerNm.y, dbu); grid(port.widthNm, dbu);
        if (previous === undefined) { (after.ports ?? []).push(port); preview.addedPorts = 1; }
        else { if (JSON.stringify(previous) === JSON.stringify(port)) throw new Error('端口内容未变化');
          after.ports = (after.ports ?? []).map((item: LayoutPort): LayoutPort => item.id === port.id ? port : item); preview.updatedPorts = 1; }
      } else if (request.kind === 'remove') {
        const previous: LayoutPort | undefined = (after.ports ?? []).find((port: LayoutPort): boolean => port.id === request.portId);
        if (previous === undefined || previous.ownerCellId !== current) throw new Error('请选择当前 Cell 的端口定义');
        this.checkPortLayer(previous); assertPortRemovalSafe(after, previous);
        preview.affectedPortIds = [previous.id];
        after.ports = (after.ports ?? []).filter((port: LayoutPort): boolean => port.id !== request.portId); preview.removedPorts = 1;
      } else if (request.kind === 'copy') {
        const resolved: ResolvedPort = resolveLayoutPort(request.endpoint, shapes, after);
        if (request.endpoint.rootCellId !== current || request.endpoint.path.length === 0) throw new Error('请选择当前 Cell 中的具体实例端口');
        const draft: LayoutPortDraft = portDraft(resolved.definition); draft.name = request.name; draft.centerNm = resolved.centerNm;
        draft.orientationDeg = resolved.orientationDeg; draft.frameMirror = resolved.frameMirror; draft.frameMagnification = resolved.frameMagnification;
        draft.provenance = JSON.stringify({ kind: 'instance-snapshot', sourcePortId: resolved.definition.id, sourceCellKey: resolved.definition.ownerCellKey,
          path: request.endpoint.path.map((step: InstancePathStep): number[] => [step.instanceId, step.row, step.col]) });
        const copy: LayoutPort = portFromDraft(newLayoutIdentity('port'), current, (after.cellKeys ?? [])[current], draft);
        preview.affectedPortIds = [copy.id];
        this.checkPortLayer(copy); grid(copy.centerNm.x, dbu); grid(copy.centerNm.y, dbu); (after.ports ?? []).push(copy); preview.addedPorts = 1;
        preview.warnings.push('已准备独立父 Cell 快照；后续源端口或实例变化不会更新该定义');
      } else if (request.kind === 'connect') {
        const moving: ResolvedPort = resolveLayoutPort(request.moving, shapes, after), target: ResolvedPort = resolveLayoutPort(request.target, shapes, after);
        if (request.moving.rootCellId !== current || request.target.rootCellId !== current || request.moving.rootCellKey !== request.target.rootCellKey ||
          request.moving.path.length === 0) throw new Error('连接需在同一当前 Cell 根下选择具体移动实例端点');
        this.checkPortLayer(moving.definition); this.checkPortLayer(target.definition);
        if (moving.definition.portType !== target.definition.portType || moving.definition.layerNumber !== target.definition.layerNumber ||
          moving.definition.datatype !== target.definition.datatype || Math.abs(moving.effectiveWidthNm - target.effectiveWidthNm) >
            Math.max(1, moving.effectiveWidthNm, target.effectiveWidthNm) * 1e-10 ||
          moving.definition.crossSectionKey !== target.definition.crossSectionKey || moving.definition.crossSectionVersion !== target.definition.crossSectionVersion) throw new Error('端口 type/layer/effective width/CrossSection 不兼容；未进行自动缩放');
        const overlap: number = request.overlapNm ?? 0; grid(overlap, dbu);
        if (request.target.path.length >= request.moving.path.length && request.moving.path.every((step: InstancePathStep, index: number): boolean => {
          const other: InstancePathStep = request.target.path[index]; return step.instanceId === other.instanceId && step.row === other.row && step.col === other.col;
        })) throw new Error('目标端点位于同一移动实例内部，不能作为固定连接目标');
        let movingEndpoint: PortEndpoint = clonePortEndpointModel(request.moving) as PortEndpoint;
        let targetEndpoint: PortEndpoint = clonePortEndpointModel(request.target) as PortEndpoint;
        const first: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === request.moving.path[0].instanceId);
        if (first === undefined) throw new Error('移动实例已失效');
        if (request.moving.path.length > 1 || Math.max(1, first.arrayCols ?? 1) * Math.max(1, first.arrayRows ?? 1) > 1) {
          const isolate: IndependentPathPlanResult = this.edit.planPathIndependent(request.moving.path, context.structure, request.moving.path.length > 1);
          if (!isolate.ok || isolate.shapes === undefined || isolate.structure === undefined) throw new Error(isolate.message);
          shapes = isolate.shapes; after = isolate.structure; preview.clonedCells = isolate.clonedCells;
          preview.addedPorts = (after.ports ?? []).length - (context.structure.ports ?? []).length;
          preview.isolatedArrayMembers = request.moving.path.filter((step: InstancePathStep): boolean => {
            const shape: Shape | undefined = this.edit.getShapes().find((item: Shape): boolean => item.id === step.instanceId);
            return shape !== undefined && Math.max(1, shape.arrayCols ?? 1) * Math.max(1, shape.arrayRows ?? 1) > 1;
          }).length;
          const leaf: InstancePathStep = isolate.path[isolate.path.length - 1];
          const copiedPort: LayoutPort | undefined = (after.ports ?? []).find((port: LayoutPort): boolean => port.ownerCellId === leaf.cellId &&
            port.name === moving.definition.name && port.portType === moving.definition.portType);
          if (copiedPort === undefined) throw new Error('隔离路径未保留端口定义');
          movingEndpoint.portId = copiedPort.id; movingEndpoint.path = isolate.path;
          targetEndpoint = remapEndpoint(request.target, target.definition, isolate);
          const preservedTarget: ResolvedPort = resolveLayoutPort(targetEndpoint, shapes, after);
          if (Math.abs(preservedTarget.centerNm.x - target.centerNm.x) > 1e-8 || Math.abs(preservedTarget.centerNm.y - target.centerNm.y) > 1e-8) throw new Error('路径隔离改变了固定目标的世界位置');
          after.cellStack = context.structure.cellStack.slice(); after.navigationPath = cloneStructured(context.structure.navigationPath ?? []);
        }
        const path: InstancePathStep[] = movingEndpoint.path, leaf: InstancePathStep = path[path.length - 1];
        const instance: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === leaf.instanceId);
        if (instance === undefined || !this.edit.canEditLayer(instance.layerNumber, instance.datatype)) throw new Error('移动实例图层已锁定');
        const definition: LayoutPort | undefined = (after.ports ?? []).find((port: LayoutPort): boolean => port.id === movingEndpoint.portId);
        if (definition === undefined) throw new Error('移动端口已失效');
        let parent: Mat2D = identity();
        for (const step of path.slice(0, -1)) {
          const ancestor: Shape | undefined = shapes.find((shape: Shape): boolean => shape.id === step.instanceId);
          if (ancestor === undefined || !this.edit.canEditLayer(ancestor.layerNumber, ancestor.datatype)) throw new Error('共享祖先实例已锁定');
          parent = compose(parent, memberMatrix(ancestor, step.row, step.col));
        }
        const angle: number = normalizePortAngle(target.orientationDeg + 180 - moving.orientationDeg);
        const determinant: number = parent.a * parent.d - parent.b * parent.c;
        instance.rotation = normalizePortAngle((instance.rotation ?? 0) + (determinant < 0 ? -angle : angle));
        const targetAngle: number = target.orientationDeg * Math.PI / 180;
        const destination: Point = { x: target.centerNm.x - overlap * Math.cos(targetAngle), y: target.centerNm.y - overlap * Math.sin(targetAngle) };
        grid(destination.x, dbu); grid(destination.y, dbu);
        const localDestination: Point = point(inverse(parent), destination), linear: Mat2D = instanceTransformMat(instance);
        const x: number = localDestination.x - linear.a * definition.centerNm.x - linear.b * definition.centerNm.y;
        const y: number = localDestination.y - linear.c * definition.centerNm.x - linear.d * definition.centerNm.y;
        grid(x, dbu); grid(y, dbu); instance.points = [{ x: x, y: y }];
        const aligned: ResolvedPort = resolveLayoutPort(movingEndpoint, shapes, after);
        if (Math.abs(aligned.centerNm.x - destination.x) > Math.max(1, Math.abs(destination.x)) * 1e-10 ||
          Math.abs(aligned.centerNm.y - destination.y) > Math.max(1, Math.abs(destination.y)) * 1e-10 ||
          Math.abs(Math.sin((aligned.orientationDeg - target.orientationDeg - 180) * Math.PI / 180)) > 1e-10 ||
          Math.cos((aligned.orientationDeg - target.orientationDeg) * Math.PI / 180) > -1 + 1e-10) throw new Error('连接 frame 对齐验证失败');
        preview.movedInstanceId = instance.id; preview.movingEndpoint = movingEndpoint; preview.targetEndpoint = targetEndpoint;
        preview.resolvedBefore = moving; preview.resolvedAfter = aligned;
        preview.warnings.push('连接仅对齐端点中心和相反方向；未验证 LVS 或光学模式。正 overlap 沿目标端口内侧偏移中心');
      } else throw new Error('端口操作类型无效');
      validateLayoutSemantics(after, after.cellNames.length);
      const error: string = validatePropertyHierarchy(shapes, after.topCellId); if (error.length > 0) throw new Error(error);
      if (this.fingerprint(context) !== source) throw new Error('端口准备期间文档发生变化');
      const plan: PortPlan = { shapes: shapes, structure: after, preview: preview };
      this.pending = { id: preview.id, documentIdentity: context.documentIdentity, before: cloneStructure(context.structure),
        source: source, candidate: JSON.stringify(plan), plan: plan };
      return { ok: true, message: '端口操作已预检；应用后可一次撤销', preview: cloneStructured(preview) as PortPreview };
    } catch (error) { this.pending = null; return { ok: false, message: `端口操作未准备：${String(error)}` }; }
  }
  apply(id: string, context: PortContext): PortResult {
    const pending: PortPending | null = this.pending; this.pending = null;
    try {
      if (pending === null || pending.id !== id || pending.source !== this.fingerprint(context) || pending.candidate !== JSON.stringify(pending.plan)) throw new Error('端口预览已取消、已使用或已过期');
      this.context(context);
      for (const port of context.structure.ports ?? []) if (!(pending.plan.structure.ports ?? []).some((next: LayoutPort): boolean => JSON.stringify(next) === JSON.stringify(port))) this.checkPortLayer(port);
      for (const port of pending.plan.structure.ports ?? []) if (!(context.structure.ports ?? []).some((old: LayoutPort): boolean => JSON.stringify(old) === JSON.stringify(port))) this.checkPortLayer(port);
      if (!this.edit.applyDocumentStructure(pending.plan.shapes, context.structure, pending.plan.structure, `端口 ${pending.plan.preview.kind}`, true)) throw new Error('端口结构事务被拒绝');
      return { ok: true, message: '端口操作已应用，可一次撤销', preview: cloneStructured(pending.plan.preview) as PortPreview };
    } catch (error) { return { ok: false, message: `端口操作未应用，原文档已保留：${String(error)}` }; }
  }
}
export const portService: PortService = new PortService();
