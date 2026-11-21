import { AiNativeCall, AiNativeResult, AiNativeData, aiNativeResult, aiNativeData } from './AiNativeTools';
import { editService, EditStructureState, InstancePathStep } from './EditService';
import { advEditService, AlignType, DistributeType } from './AdvancedEditService';
import { Shape, ShapeType, getShapeBounds, Point } from '../models/GdsiiData';
import { PropertyCellOption } from './ShapePropertyService';
import { booleanPreviewService, BooleanPreviewOptions } from './BooleanPreviewService';
import { layerExpressionService, LayerExpressionOptions } from './LayerExpressionService';
import { NativeLayerRegionAdapter } from './NativeLayerRegionAdapter';
import { hierarchyClipSessionService, createRegionHierarchyClipAdapter } from './HierarchyClipSessionService';
import { HierarchyClipOptions } from './HierarchyClipService';
import { hierarchyFillSessionService } from './HierarchyFillSessionService';
import { HierarchyFillOptions } from './HierarchyFillService';
import { cellMaintenanceService, CellMaintenanceRequest } from './CellMaintenanceService';
import { portService, PortRequest, PortContext } from './PortService';
import { routeSessionService, RouteSessionService, RouteSessionContext, RouteSessionRequest } from './RouteSessionService';
import { nativeHongTuService } from './NativeHongTuService';
import { flattenPreviewService } from './FlattenPreviewService';
import { WorkspaceDocument } from './WorkspaceService';
import { cloneStructured } from '../common/CloneUtils';

export interface AiGeometryContext {
  documentIdentity: string; structure: EditStructureState; technologyJson: string;
  hierarchyDepth: number; cells: PropertyCellOption[]; document: WorkspaceDocument;
}

/** Explicit targets prevent a stale/hidden selection from becoming authority. */
export function selectAiNativeTargets(ids: number[], editable: boolean = false): Shape[] {
  if (!Array.isArray(ids) || !ids.length || new Set<number>(ids).size !== ids.length) throw new Error('需要明确且不重复的对象 ID');
  const selected: Shape[] = ids.map((id: number): Shape => {
    const shape: Shape | undefined = editService.getShapes().find((entry: Shape): boolean => entry.id === id);
    if (shape === undefined || (shape.ownerCellId ?? editService.getTopCellId()) !== editService.getCurrentCellId() ||
      !editService.canSelectLayer(shape.layerNumber, shape.datatype)) throw new Error(`对象 ${id} 不存在、不可选择或不在当前 Cell`);
    if (editable && !editService.canEditLayer(shape.layerNumber,shape.datatype)) throw new Error(`对象 ${id} 所在图层已锁定`);
    return shape;
  });
  editService.selectMultiple(ids);
  return selected;
}

/** No UI event simulation and no name-to-method reflection. Native services
 * own their geometry validation, preview sealing, locks and resource budgets. */
export function runAiNativeGeometry(call: AiNativeCall, context: AiGeometryContext): AiNativeResult | undefined {
  const args: Record<string, Object> = call.arguments;
  const structure: EditStructureState = context.structure;
  if (structure.physicalUnits === undefined) throw new Error('文档 DBU 未设置');
  const dbuNm: number = structure.physicalUnits * 1e9;
  const serviceContext: PortContext = { documentIdentity: context.documentIdentity, structure };
  const routeContext: RouteSessionContext = { documentIdentity: context.documentIdentity, structure, technologyJson: context.technologyJson };
  let selected: Shape[] = [];
  if (call.name.startsWith('selection.') && call.name !== 'selection.set' && call.name !== 'selection.all') {
    selected = selectAiNativeTargets(args['shapeIds'] as number[], true);
    if (selected.some((shape: Shape): boolean => !editService.canEditLayer(shape.layerNumber, shape.datatype))) throw new Error('选区包含锁定图层');
  }
  switch (call.name) {
    case 'selection.align': return aiNativeResult(advEditService.alignSelection(args['alignment'] as AlignType, context.hierarchyDepth), '对齐操作');
    case 'selection.distribute': return aiNativeResult(advEditService.distributeSelection(args['direction'] as DistributeType, context.hierarchyDepth), '等距分布操作');
    case 'selection.offset': {
      const ok: boolean = advEditService.sizeSelection(args['offsetNm'] as number, structure);
      return aiNativeResult(ok, ok ? '尺寸偏移已应用' : advEditService.getLastGeometryError());
    }
    case 'selection.round': {
      for (const shape of selected) {
        const preview = advEditService.prepareRoundedCorners(shape.id, args['radiusNm'] as number, args['maxErrorNm'] as number);
        if (!preview.ok || !advEditService.applyRoundedCorners(preview)) return aiNativeResult(false, preview.message);
      }
      return aiNativeResult(true, `已处理 ${selected.length} 个图形的圆角`);
    }
    case 'selection.layer': {
      for (const shape of selected) if (!editService.updateShape(shape.id, args['layer'] as number, 0, 0, args['datatype'] as number)) return aiNativeResult(false, '图层修改失败');
      return aiNativeResult(true, `已修改 ${selected.length} 个对象的图层`);
    }
    case 'selection.property': {
      const result = editService.updateProperties(args['shapeIds'] as number[], args['property'] as string, args['value'] as string, context.cells);
      return aiNativeResult(result.ok, result.message, result);
    }
    case 'vertex.move': case 'vertex.insert': case 'vertex.delete': {
      selectAiNativeTargets([args['shapeId'] as number], true);
      const id: number = args['shapeId'] as number, index: number = args['index'] as number;
      const ok: boolean = call.name === 'vertex.move' ? advEditService.moveVertex(id,index,args['x'] as number,args['y'] as number) :
        call.name === 'vertex.insert' ? advEditService.insertVertex(id,index,args['x'] as number,args['y'] as number) : advEditService.deleteVertex(id,index);
      return aiNativeResult(ok, ok ? '顶点修改已应用' : '顶点修改被原生几何校验拒绝');
    }
    case 'boolean.apply': {
      const prepared = booleanPreviewService.prepare(args as Object as BooleanPreviewOptions);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = booleanPreviewService.apply(prepared.preview, structure);
      return aiNativeResult(applied.ok, applied.message, aiNativeData({ outputObjects: prepared.preview.outputs.length, areaNm2: prepared.preview.areaNm2 }));
    }
    case 'layers.expression': {
      const options: LayerExpressionOptions = { expression: args['expression'] as string, outputLayer: args['outputLayer'] as number,
        outputDatatype: args['outputDatatype'] as number, keepSources: args['keepSources'] as boolean,
        hierarchyDepth: args['hierarchyDepth'] as number, documentIdentity: context.documentIdentity, gridNm: dbuNm };
      const prepared = layerExpressionService.prepare(options, new NativeLayerRegionAdapter(), structure);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = layerExpressionService.apply(prepared.preview, structure, context.documentIdentity);
      return aiNativeResult(applied.ok, applied.message, aiNativeData({ outputObjects: prepared.preview.outputs.length, areaNm2: prepared.preview.areaNm2 }));
    }
    case 'hierarchy.clip': {
      const options: HierarchyClipOptions = cloneStructured(args) as Object as HierarchyClipOptions;
      options.dbuNm = dbuNm;
      const prepared = hierarchyClipSessionService.prepare({ documentIdentity: context.documentIdentity, structure }, options, createRegionHierarchyClipAdapter(new NativeLayerRegionAdapter()));
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = hierarchyClipSessionService.apply(prepared.preview.id, { documentIdentity: context.documentIdentity, structure });
      return aiNativeResult(applied.ok, applied.message);
    }
    case 'hierarchy.fill': {
      const options: HierarchyFillOptions = cloneStructured(args) as Object as HierarchyFillOptions;
      options.dbuNm = dbuNm;
      const prepared = hierarchyFillSessionService.prepare({ documentIdentity: context.documentIdentity, structure }, options, new NativeLayerRegionAdapter());
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = hierarchyFillSessionService.apply(prepared.preview.id, { documentIdentity: context.documentIdentity, structure });
      return aiNativeResult(applied.ok, applied.message, aiNativeData({ placedInstances: applied.placedInstances ?? 0, addedShapes: applied.addedShapes ?? 0 }));
    }
    case 'cell.origin': case 'cell.relink': case 'cell.prune': {
      const request: Record<string, Object> = cloneStructured(args) as Record<string, Object>;
      request['kind'] = call.name.substring(5); request['dbuNm'] = dbuNm;
      const prepared = cellMaintenanceService.prepare({ documentIdentity: context.documentIdentity, structure }, request as Object as CellMaintenanceRequest);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = cellMaintenanceService.apply(prepared.preview.id, { documentIdentity: context.documentIdentity, structure });
      return aiNativeResult(applied.ok, applied.message, applied.preview);
    }
    case 'ports.add': case 'ports.update': case 'ports.remove': case 'ports.copy': case 'ports.connect': {
      const request: Record<string, Object> = cloneStructured(args) as Record<string, Object>;
      request['kind'] = call.name.substring(6);
      const prepared = portService.prepare(serviceContext, request as Object as PortRequest);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = portService.apply(prepared.preview.id, serviceContext);
      return aiNativeResult(applied.ok, applied.message, applied.preview);
    }
    case 'route.apply': case 'route.preview': {
      const routes: RouteSessionService = call.name === 'route.preview' ? new RouteSessionService() : routeSessionService;
      const prepared = routes.prepare(routeContext, args as Object as RouteSessionRequest);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const preview = prepared.preview;
      // Full polygons remain native; the model gets real checks and lengths.
      const data: AiNativeData = { routes: preview.routes, profiles: preview.profiles, warnings: preview.warnings,
        obstacleCount: preview.obstacleCount, outputObjects: preview.shapes.length,
        maximumApproximationErrorNm: preview.maximumApproximationErrorNm, lengthDefinition: preview.lengthDefinition,
        opticalRoutes: preview.opticalRoutes?.map((row): AiNativeData => ({ pairKey: row.pairKey,
          continuousLengthNm: row.geometry.continuousLengthNm,sampledLengthNm: row.geometry.sampledLengthNm,
          minimumRadiusNm: row.geometry.minimumRadiusNm,maximumCurvaturePerNm: row.geometry.maximumCurvaturePerNm,
          endpointErrors: row.geometry.endpointErrors,samplingErrorNm: row.geometry.samplingErrorNm,
          integrationErrorNm: row.geometry.integrationErrorNm,quantizationErrorNm: row.geometry.quantizationErrorNm,
          poseClosureErrorNm: row.geometry.poseClosureErrorNm })) };
      if (call.name === 'route.preview') { routes.cancel(preview.id); return aiNativeResult(true, prepared.message, data, 'read_only'); }
      const applied = routes.apply(preview.id, routeContext);
      return aiNativeResult(applied.ok, applied.message, data);
    }
    case 'instance.flatten': {
      selectAiNativeTargets(args['shapeIds'] as number[]);
      const prepared = flattenPreviewService.prepare(context.document, args['shapeIds'] as number[]);
      if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false, prepared.message);
      const applied = flattenPreviewService.apply(prepared.preview, context.document, structure);
      return aiNativeResult(applied.ok, applied.message, applied.estimate);
    }
    case 'instance.independent': {
      const result = editService.makePathIndependent(args['path'] as InstancePathStep[], structure);
      return aiNativeResult(result.ok, result.message);
    }
    case 'instance.extract_member': {
      const result = editService.extractArrayMember(args['instanceId'] as number, args['row'] as number, args['col'] as number, structure);
      return aiNativeResult(result.ok, result.message);
    }
    case 'geometry.measure': {
      const ids: number[] = args['shapeIds'] as number[];
      const shapes: Shape[] = ids.map((id: number): Shape => {
        const shape: Shape | undefined = editService.getShapes().find((s: Shape): boolean => s.id === id);
        if (shape === undefined) throw new Error(`对象 ${id} 已不存在`);
        return shape;
      });
      const rows: Object[] = shapes.map((shape: Shape): AiNativeData => {
        const b = getShapeBounds(shape);
        const flat: number[] = []; for (const p of shape.points) flat.push(p.x,p.y);
        return { id: shape.id, bounds: b, widthNm: b.maxX-b.minX, heightNm: b.maxY-b.minY,
          areaNm2: shape.type === ShapeType.RECT ? (b.maxX-b.minX)*(b.maxY-b.minY) : shape.type === ShapeType.POLYGON ? nativeHongTuService.polygonArea(flat) : undefined,
          boundsOnly: shape.type === ShapeType.INSTANCE };
      });
      return aiNativeResult(true, '尺寸单位 nm，面积单位 nm²；实例未展开时仅返回包围盒', rows, 'read_only');
    }
    default: return undefined;
  }
}
