/** Sealed, single-use Fill preview ownership and one structural Undo/Redo.
 * Licensed under GPLv3. */
import { Shape, ShapeBounds } from '../models/GdsiiData';
import { EditService, editService } from './EditService';
import type { EditStructureState } from './EditService';
import { hierarchyFillService } from './HierarchyFillService';
import type { HierarchyFillOptions, HierarchyFillPlan, HierarchyFillResult } from './HierarchyFillService';
import type { LayerRegionAdapter } from './LayerExpressionService';
import { cloneShapeArray, cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface HierarchyFillContext { documentIdentity: string; structure: EditStructureState; }
export interface HierarchyFillPreview {
  id: string; targetCellId: number; fillCellId: number; footprint: ShapeBounds; dbuNm: number;
  placedInstances: number; addedShapes: number; consideredCandidates: number;
  rejectedOutside: number; rejectedExcluded: number; rejectedOverlap: number;
  visitedPlacements: number; conservativeExclusionCount: number;
}
export interface HierarchyFillSessionResult { ok: boolean; message: string; preview?: HierarchyFillPreview; placedInstances?: number; addedShapes?: number; }
interface PendingFill {
  id: string; documentIdentity: string; revision: number; cellId: number;
  geometryFingerprint: string; structureFingerprint: string; planFingerprint: string;
  before: EditStructureState; plan: HierarchyFillPlan;
}
function geometryFingerprint(shapes: Shape[]): string {
  return JSON.stringify(shapes.map((shape: Shape): Shape => {
    const copy: Shape = cloneShapeModel(shape, true) as Shape; copy.selected = false; return copy;
  }));
}

export class HierarchyFillSessionService {
  private static nextServiceId: number = 0;
  private edit: EditService; private serviceId: number; private generation: number = 0;
  private pending: PendingFill | null = null;
  constructor(edit: EditService = editService) { this.edit = edit; this.serviceId = ++HierarchyFillSessionService.nextServiceId; }
  cancel(previewId?: string): void { if (previewId === undefined || this.pending?.id === previewId) this.pending = null; }
  getPreviewShapes(previewId: string): Shape[] {
    const pending: PendingFill | null = this.pending;
    if (pending === null || pending.id !== previewId || pending.revision !== this.edit.getSessionRevision() ||
      pending.cellId !== this.edit.getCurrentCellId() || geometryFingerprint(this.edit.getShapes()) !== pending.geometryFingerprint) return [];
    return cloneShapeArray(pending.plan.shapes, true) as Shape[];
  }
  private contextError(context: HierarchyFillContext): string {
    if (typeof context.documentIdentity !== 'string' || context.documentIdentity.length < 1 || context.documentIdentity.length > 4096 ||
      /[\x00-\x1f]/.test(context.documentIdentity)) return 'Fill 文档身份无效';
    if (context.structure.topCellId !== this.edit.getTopCellId() || JSON.stringify(context.structure.cellStack) !== JSON.stringify(this.edit.getCurrentCellStack()) ||
      JSON.stringify(context.structure.navigationPath ?? []) !== JSON.stringify(this.edit.getNavigationPath())) return 'Fill 当前导航结构已变化';
    return '';
  }
  prepare(context: HierarchyFillContext, options: HierarchyFillOptions, adapter?: LayerRegionAdapter): HierarchyFillSessionResult {
    this.pending = null;
    try {
      const error: string = this.contextError(context); if (error.length > 0) return { ok: false, message: error };
      const cellId: number = this.edit.getCurrentCellId();
      if (options.targetCellId !== cellId) return { ok: false, message: 'Fill 目标必须为当前 Cell' };
      const revision: number = this.edit.getSessionRevision(), fingerprint: string = geometryFingerprint(this.edit.getShapes()),
        structureFingerprint: string = JSON.stringify(context.structure), nextId: number = this.edit.getNextShapeId();
      const ownedOptions: HierarchyFillOptions = cloneStructured(options) as HierarchyFillOptions; ownedOptions.nextShapeId = nextId;
      const before: EditStructureState = JSON.parse(structureFingerprint) as EditStructureState;
      const result: HierarchyFillResult = hierarchyFillService.createPlan(cloneShapeArray(this.edit.getShapes(), true) as Shape[], before, ownedOptions, adapter);
      if (!result.ok || result.plan === undefined) return { ok: false, message: result.message };
      if (revision !== this.edit.getSessionRevision() || cellId !== this.edit.getCurrentCellId() || this.contextError(context).length > 0 ||
        structureFingerprint !== JSON.stringify(context.structure) || fingerprint !== geometryFingerprint(this.edit.getShapes())) return { ok: false, message: 'Fill 计算期间文档变化，请重新生成预览' };
      if (!this.edit.canEditLayer(ownedOptions.instanceLayer, ownedOptions.instanceDatatype)) return { ok: false, message: 'Fill 输出实例图层已锁定' };
      const plan: HierarchyFillPlan = result.plan;
      if (!Number.isSafeInteger(nextId + plan.addedShapes) || !Number.isSafeInteger(this.generation + 1)) return { ok: false, message: 'Fill ID 或会话计数超过预算' };
      const id: string = `hierarchy-fill-${this.serviceId}-${++this.generation}`;
      this.pending = { id: id, documentIdentity: context.documentIdentity, revision: revision, cellId: cellId,
        geometryFingerprint: fingerprint, structureFingerprint: structureFingerprint, planFingerprint: JSON.stringify(plan), before: before, plan: plan };
      return { ok: true, message: result.message, preview: { id: id, targetCellId: cellId, fillCellId: plan.fillCellId,
        footprint: { minX: plan.footprint.minX, minY: plan.footprint.minY, maxX: plan.footprint.maxX, maxY: plan.footprint.maxY }, dbuNm: options.dbuNm,
        placedInstances: plan.placedInstances, addedShapes: plan.addedShapes, consideredCandidates: plan.consideredCandidates,
        rejectedOutside: plan.rejectedOutside, rejectedExcluded: plan.rejectedExcluded, rejectedOverlap: plan.rejectedOverlap,
        visitedPlacements: plan.visitedPlacements, conservativeExclusionCount: plan.conservativeExclusionCount } };
    } catch (error) { return { ok: false, message: `Fill 预览失败：${String(error)}，原图已保留` }; }
  }
  apply(previewId: string, context: HierarchyFillContext): HierarchyFillSessionResult {
    const pending: PendingFill | null = this.pending;
    if (pending === null || pending.id !== previewId) return { ok: false, message: 'Fill 预览已取消、过期或属于其它会话' };
    try {
      if (context.documentIdentity !== pending.documentIdentity || this.contextError(context).length > 0 ||
        this.edit.getSessionRevision() !== pending.revision || this.edit.getCurrentCellId() !== pending.cellId ||
        JSON.stringify(context.structure) !== pending.structureFingerprint || geometryFingerprint(this.edit.getShapes()) !== pending.geometryFingerprint ||
        JSON.stringify(pending.plan) !== pending.planFingerprint) {
        this.pending = null; return { ok: false, message: '文档、层级或 Fill 预览变化，请重新生成' };
      }
      const plan: HierarchyFillPlan = pending.plan;
      if (plan.placedInstances < 1) return { ok: false, message: '没有可放置实例，原图已保留' };
      const existing: Map<number, Shape> = new Map<number, Shape>(); for (const shape of this.edit.getShapes()) existing.set(shape.id, shape);
      const candidate: Shape[] = plan.shapes.map((shape: Shape): Shape => {
        const copy: Shape = cloneShapeModel(shape, true) as Shape, current: Shape | undefined = existing.get(shape.id);
        if (current !== undefined) copy.selected = current.selected;
        return copy;
      });
      for (const shape of candidate) if (!existing.has(shape.id) && !this.edit.canEditLayer(shape.layerNumber, shape.datatype)) return { ok: false, message: 'Fill 输出图层已锁定，原图已保留' };
      const ids: number[] = candidate.filter((shape: Shape): boolean => !existing.has(shape.id)).map((shape: Shape): number => shape.id);
      if (!this.edit.applyDocumentStructure(candidate, pending.before, plan.structure,
        `填充 ${plan.structure.cellNames[plan.fillCellId]} · ${plan.placedInstances} 个实例 / ${plan.addedShapes} 个引用`, true, ids)) return { ok: false, message: 'Fill 结构事务被拒绝，原图已保留' };
      this.pending = null;
      return { ok: true, message: `已放置 ${plan.placedInstances} 个 Fill 实例，源 Cell 与共享层级保留，可一次撤销`, placedInstances: plan.placedInstances, addedShapes: plan.addedShapes };
    } catch (error) { return { ok: false, message: `Fill 提交异常：${String(error)}` }; }
  }
}
export const hierarchyFillSessionService: HierarchyFillSessionService = new HierarchyFillSessionService();
