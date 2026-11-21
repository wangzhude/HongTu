/** Preview/commit ownership for hierarchy-preserving Clip. The candidate never
 * leaves this service: UI receives a summary and an opaque, single-use ID.
 * All geometry remains in physical nm; DBU is the declared region adapter grid.
 * Licensed under GPLv3.
 */
import { Shape, ShapeBounds, ShapeType, Point } from '../models/GdsiiData';
import { EditService, editService } from './EditService';
import type { EditStructureState } from './EditService';
import type { LayoutPort } from '../models/LayoutPort';
import { hierarchyClipService } from './HierarchyClipService';
import type { HierarchyClipAdapter, HierarchyClipGeometryResult, HierarchyClipOptions, HierarchyClipPlan, HierarchyClipResult } from './HierarchyClipService';
import type { LayerRegionAdapter, LayerRegionResult } from './LayerExpressionService';
import { cloneEditStructureModel, cloneShapeArray, cloneShapeModel, cloneStructured } from '../common/CloneUtils';

export interface HierarchyClipRegionAdapter extends LayerRegionAdapter {
  shape(shape: Shape, gridNm: number, worldScale: number): LayerRegionResult;
}

/** Shared native region entry: PATH outlines, polygon holes and clipping use the
 * same filled-region engine. The local grid and absolute WIDTH scale stay explicit. */
export function createRegionHierarchyClipAdapter(regionAdapter: HierarchyClipRegionAdapter): HierarchyClipAdapter {
  return (shape: Shape, clip: Point[], gridNm: number, worldScale: number): HierarchyClipGeometryResult => {
    const region: LayerRegionResult = regionAdapter.shape(shape, gridNm, worldScale);
    if (!region.ok) return { ok: false, message: region.message, unchanged: false, polygons: [] };
    const clipRing: number[] = [];
    for (const point of clip) { clipRing.push(point.x); clipRing.push(point.y); }
    const intersection: LayerRegionResult = regionAdapter.boolean(region.polygons, [clipRing], 'intersection', gridNm);
    if (!intersection.ok) return { ok: false, message: intersection.message, unchanged: false, polygons: [] };
    const polygons: Point[][] = intersection.polygons.map((ring: number[]): Point[] => {
      if (ring.length < 6 || ring.length % 2 !== 0) throw new Error('区域裁剪返回了不完整的坐标对');
      const points: Point[] = [];
      for (let index: number = 0; index < ring.length; index += 2) points.push({ x: ring[index], y: ring[index + 1] });
      return points;
    });
    // Fully contained originals are retained by the planner's conservative
    // painted-bounds fast path. Partial placements use an independent variant;
    // computing/fracturing an unrelated complement adds no Clip geometry.
    return { ok: true, message: '', unchanged: false, polygons: polygons };
  };
}

export interface HierarchyClipContext { documentIdentity: string; structure: EditStructureState; }
export interface HierarchyClipPreview {
  id: string;
  sourceCellId: number;
  outputCellId: number;
  outputCellName: string;
  bounds: ShapeBounds;
  dbuNm: number;
  addedCells: number;
  addedShapes: number;
  keptReferences: number;
  clippedObjects: number;
  addedPorts: number;
  droppedPorts: number;
  visitedPlacements: number;
}
export interface HierarchyClipSessionResult {
  ok: boolean;
  message: string;
  preview?: HierarchyClipPreview;
  outputCellId?: number;
  addedCells?: number;
  addedShapes?: number;
}
interface PendingHierarchyClip {
  id: string;
  documentIdentity: string;
  revision: number;
  sourceCellId: number;
  structureFingerprint: string;
  geometryFingerprint: string;
  planFingerprint: string;
  before: EditStructureState;
  plan: HierarchyClipPlan;
}

function geometryFingerprint(shapes: Shape[]): string {
  // Selecting a different object is allowed while the preview is open. Every
  // persisted field, object order and definition outside the source is checked.
  const content: Shape[] = shapes.map((shape: Shape): Shape => {
    const copy: Shape = cloneShapeModel(shape, true) as Shape; copy.selected = false; return copy;
  });
  return JSON.stringify(content);
}

export class HierarchyClipSessionService {
  private static nextServiceId: number = 0;
  private edit: EditService;
  private serviceId: number;
  private generation: number = 0;
  private pending: PendingHierarchyClip | null = null;

  constructor(edit: EditService = editService) { this.edit = edit; this.serviceId = ++HierarchyClipSessionService.nextServiceId; }

  /** Cancelling an old dialog cannot cancel a newer dialog's candidate. */
  cancel(previewId?: string): void {
    if (previewId === undefined || this.pending?.id === previewId) this.pending = null;
  }

  /** Owned copies of the actual candidate library for hierarchy-aware rendering.
   * Changing the returned shapes cannot change the privately sealed commit plan. */
  getPreviewShapes(previewId: string): Shape[] {
    const pending: PendingHierarchyClip | null = this.pending;
    if (pending === null || pending.id !== previewId || this.edit.getSessionRevision() !== pending.revision ||
      this.edit.getCurrentCellId() !== pending.sourceCellId || geometryFingerprint(this.edit.getShapes()) !== pending.geometryFingerprint) return [];
    return cloneShapeArray(pending.plan.shapes, true) as Shape[];
  }

  private contextError(context: HierarchyClipContext): string {
    if (typeof context.documentIdentity !== 'string' || context.documentIdentity.length === 0 ||
      context.documentIdentity.length > 4096 || /[\x00-\x1f]/.test(context.documentIdentity)) return '缺少有效文档身份，无法建立 Clip 会话';
    if (context.structure.topCellId !== this.edit.getTopCellId() ||
      JSON.stringify(context.structure.cellStack) !== JSON.stringify(this.edit.getCurrentCellStack()) ||
      JSON.stringify(context.structure.navigationPath ?? []) !== JSON.stringify(this.edit.getNavigationPath())) return 'Cell 导航结构已变化，请重新生成 Clip 预览';
    return '';
  }

  prepare(context: HierarchyClipContext, options: HierarchyClipOptions, adapter: HierarchyClipAdapter): HierarchyClipSessionResult {
    this.pending = null;
    try {
      const contextMessage: string = this.contextError(context);
      if (contextMessage.length > 0) return { ok: false, message: contextMessage };
      const sourceCellId: number = this.edit.getCurrentCellId();
      if (options.sourceCellId !== sourceCellId) return { ok: false, message: 'Clip 来源必须为当前 Cell，请重新选择范围' };
      const revision: number = this.edit.getSessionRevision();
      const structureFingerprint: string = JSON.stringify(context.structure);
      const fingerprint: string = geometryFingerprint(this.edit.getShapes());
      const nextId: number = this.edit.getNextShapeId();
      if (!Number.isSafeInteger(nextId) || nextId < 1) return { ok: false, message: 'Clip 对象 ID 超出安全范围' };
      const ownedOptions: HierarchyClipOptions = cloneStructured(options) as HierarchyClipOptions;
      ownedOptions.nextShapeId = nextId;
      const ownedStructure: EditStructureState = JSON.parse(structureFingerprint) as EditStructureState;
      const sourceShapes: Shape[] = cloneShapeArray(this.edit.getShapes(), true) as Shape[];
      const result: HierarchyClipResult = hierarchyClipService.createPlan(sourceShapes, ownedStructure, ownedOptions, adapter);
      if (!result.ok || result.plan === undefined) return { ok: false, message: result.message };
      if (revision !== this.edit.getSessionRevision() || sourceCellId !== this.edit.getCurrentCellId() ||
        this.contextError(context).length > 0 || JSON.stringify(context.structure) !== structureFingerprint ||
        geometryFingerprint(this.edit.getShapes()) !== fingerprint) return { ok: false, message: '文档在 Clip 计算期间变化，请重新预览' };
      const plan: HierarchyClipPlan = result.plan;
      if (!Number.isSafeInteger(nextId + plan.addedShapes)) return { ok: false, message: 'Clip 结果超过对象 ID 预算，原图已保留' };
      const oldIds: Set<number> = new Set<number>(this.edit.getShapes().map((shape: Shape): number => shape.id));
      if (plan.shapes.some((shape: Shape): boolean => !oldIds.has(shape.id) && !this.edit.canEditLayer(shape.layerNumber, shape.datatype))) return { ok: false, message: 'Clip 输出含锁定图层，请解锁后重新预览' };
      const oldPorts: Set<string> = new Set<string>((ownedStructure.ports ?? []).map((port: LayoutPort): string => port.id));
      if ((plan.structure.ports ?? []).some((port: LayoutPort): boolean => !oldPorts.has(port.id) && !this.edit.canEditLayer(port.layerNumber, port.datatype))) return { ok: false, message: 'Clip 端口输出含锁定图层，请解锁后重新预览' };
      if (!Number.isSafeInteger(this.generation + 1)) return { ok: false, message: 'Clip 会话计数超出安全范围' };
      const id: string = `hierarchy-clip-${this.serviceId}-${++this.generation}`;
      this.pending = { id: id, documentIdentity: context.documentIdentity, revision: revision, sourceCellId: sourceCellId,
        structureFingerprint: structureFingerprint, geometryFingerprint: fingerprint, planFingerprint: JSON.stringify(plan),
        before: ownedStructure, plan: plan };
      const preview: HierarchyClipPreview = { id: id, sourceCellId: sourceCellId, outputCellId: plan.outputCellId,
        outputCellName: plan.structure.cellNames[plan.outputCellId], bounds: { minX: ownedOptions.bounds.minX, minY: ownedOptions.bounds.minY,
          maxX: ownedOptions.bounds.maxX, maxY: ownedOptions.bounds.maxY }, dbuNm: ownedOptions.dbuNm,
        addedCells: plan.addedCells, addedShapes: plan.addedShapes, keptReferences: plan.keptReferences,
        clippedObjects: plan.clippedObjects, visitedPlacements: plan.visitedPlacements,
        addedPorts: plan.addedPorts, droppedPorts: plan.droppedPorts };
      return { ok: true, message: result.message, preview: preview };
    } catch (error) { return { ok: false, message: `Clip 预览失败：${String(error)}，原图已保留` }; }
  }

  apply(previewId: string, context: HierarchyClipContext): HierarchyClipSessionResult {
    const pending: PendingHierarchyClip | null = this.pending;
    if (pending === null || pending.id !== previewId) return { ok: false, message: 'Clip 预览已取消、过期或不是本会话，请重新生成' };
    try {
      if (context.documentIdentity !== pending.documentIdentity || this.contextError(context).length > 0 ||
        this.edit.getSessionRevision() !== pending.revision || this.edit.getCurrentCellId() !== pending.sourceCellId ||
        JSON.stringify(context.structure) !== pending.structureFingerprint ||
        geometryFingerprint(this.edit.getShapes()) !== pending.geometryFingerprint ||
        JSON.stringify(pending.plan) !== pending.planFingerprint) {
        this.pending = null; return { ok: false, message: '文档、层级或 Clip 预览已变化，请重新生成' };
      }
      const plan: HierarchyClipPlan = pending.plan;
      const current: Map<number, Shape> = new Map<number, Shape>();
      for (const shape of this.edit.getShapes()) current.set(shape.id, shape);
      const candidate: Shape[] = plan.shapes.map((shape: Shape): Shape => {
        const copy: Shape = cloneShapeModel(shape, true) as Shape;
        const original: Shape | undefined = current.get(shape.id);
        if (original !== undefined) copy.selected = original.selected;
        return copy;
      });
      for (const shape of candidate) {
        if (!current.has(shape.id) && !this.edit.canEditLayer(shape.layerNumber, shape.datatype)) return { ok: false, message: 'Clip 输出图层已锁定，原图已保留' };
      }
      const oldPorts: Set<string> = new Set<string>((pending.before.ports ?? []).map((port: LayoutPort): string => port.id));
      for (const port of plan.structure.ports ?? []) if (!oldPorts.has(port.id) && !this.edit.canEditLayer(port.layerNumber, port.datatype)) return { ok: false, message: 'Clip 端口输出图层已锁定，原图已保留' };
      // A definition has no fabricated placement path. Keep the library's Top
      // so legacy owner-less shapes retain their meaning, and use the existing
      // definition navigation semantics to view the new standalone Cell.
      // Undo/redo restores this navigation with the same structural history item.
      const after: EditStructureState = cloneEditStructureModel(plan.structure, true) as EditStructureState;
      after.cellStack = [after.topCellId, plan.outputCellId]; after.navigationPath = [];
      const visibleIds: number[] = candidate.filter((shape: Shape): boolean => shape.ownerCellId === plan.outputCellId && shape.type !== ShapeType.NODE)
        .map((shape: Shape): number => shape.id);
      if (!this.edit.applyDocumentStructure(candidate, pending.before, after,
        `层级 Clip ${after.cellNames[plan.outputCellId]} · ${plan.addedCells} 个 Cell / ${plan.addedShapes} 个对象`, true, visibleIds)) return { ok: false, message: 'Clip 提交被拒绝，原图已保留' };
      this.pending = null;
      return { ok: true, message: `已创建 ${after.cellNames[plan.outputCellId]}，保留源层级，可一次撤销`,
        outputCellId: plan.outputCellId, addedCells: plan.addedCells, addedShapes: plan.addedShapes };
    } catch (error) { return { ok: false, message: `Clip 提交异常：${String(error)}` }; }
  }
}
export const hierarchyClipSessionService: HierarchyClipSessionService = new HierarchyClipSessionService();
