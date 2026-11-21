import { nativeHongTuService } from './NativeHongTuService';
import { LayerRegionAdapter, LayerRegionOp, LayerRegionResult } from './LayerExpressionService';
import type { BooleanOpType } from '../../cpp/types/libhongtu/Index';
import type { Shape } from '../models/GdsiiData';
import { shapeRegionAdapterService, ShapeRegionResult } from './ShapeRegionAdapterService';
import type { HierarchyClipRegionAdapter } from './HierarchyClipSessionService';

/** Explicit adapter class also satisfies ArkTS callable-interface restrictions. */
export class NativeLayerRegionAdapter implements LayerRegionAdapter, HierarchyClipRegionAdapter {
  shape(shape: Shape, gridNm: number, worldScale: number = 1): LayerRegionResult {
    const result: ShapeRegionResult = shapeRegionAdapterService.shape(shape, gridNm, worldScale);
    return { ok: result.ok, polygons: result.polygons, message: result.message, roundCapErrorNm: result.roundCapErrorNm };
  }
  expressionPath(shape: Shape, gridNm: number, worldScale: number): LayerRegionResult {
    const points: number[] = [];
    for (const point of shape.points) { points.push(point.x); points.push(point.y); }
    const computed = nativeHongTuService.pathRegionWholeDPathSimple(points, shape.pathWidth ?? 0,
      shape.pathType ?? 0, shape.pathBeginExtension ?? 0, shape.pathEndExtension ?? 0,
      worldScale, shape.pathWidthAbsolute ?? false, gridNm);
    return { ok: computed.success, polygons: computed.polygons, message: computed.errorMessage, roundCapErrorNm: computed.roundCapErrorNm };
  }
  boolean(subject: number[][], clip: number[][], op: LayerRegionOp, gridNm: number): LayerRegionResult {
    const kind: BooleanOpType = op === 'intersection' ? 0 : op === 'union' ? 1 : op === 'difference' ? 2 : 3;
    const computed = nativeHongTuService.regionBooleanForEdit(subject, clip, kind, gridNm);
    return { ok: computed.success, polygons: computed.polygons, message: computed.errorMessage };
  }
}
