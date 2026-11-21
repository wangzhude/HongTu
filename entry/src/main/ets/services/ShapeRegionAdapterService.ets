import { Shape, ShapeType, getShapeBounds } from '../models/GdsiiData';
import { nativeHongTuService } from './NativeHongTuService';
import type { GeometryEditResult } from './NativeHongTuService';

export interface ShapeRegionResult {
  ok: boolean;
  polygons: number[][];
  message: string;
  /** Local nm round-cap sagitta bound plus quantization displacement. */
  roundCapErrorNm?: number;
}

/** Converts actual filled geometry; geometry is returned in the source Cell's
 * local nm coordinates. worldScale is the accumulated instance MAG and matters
 * only for absolute/negative GDS WIDTH. Source objects are never modified. */
export class ShapeRegionAdapterService {
  shape(shape: Shape, gridNm: number, worldScale: number = 1): ShapeRegionResult {
    if (!Number.isFinite(gridNm) || gridNm <= 0 || !Number.isFinite(worldScale) || worldScale <= 0) {
      return { ok: false, polygons: [], message: 'PATH 区域需要正的有限 DBU 与累计实例缩放' };
    }
    if (shape.points.length > 20000 || shape.points.some((p): boolean =>
      !Number.isFinite(p.x) || !Number.isFinite(p.y))) {
      return { ok: false, polygons: [], message: `对象 #${shape.id} 的坐标无效或超过区域预算` };
    }
    let computed: GeometryEditResult;
    if (shape.type === ShapeType.PATH) {
      const points: number[] = [];
      shape.points.forEach((point): void => { points.push(point.x, point.y); });
      computed = nativeHongTuService.pathRegionForEdit(points, shape.pathWidth ?? 0, shape.pathType ?? 0,
        shape.pathBeginExtension ?? 0, shape.pathEndExtension ?? 0, worldScale,
        shape.pathWidthAbsolute === true, gridNm);
    } else if (shape.type === ShapeType.RECT || shape.type === ShapeType.POLYGON) {
      let polygon: number[] = [];
      if (shape.type === ShapeType.RECT) {
        if (shape.points.length < 2) return { ok: false, polygons: [], message: `矩形 #${shape.id} 缺少坐标` };
        const bounds = getShapeBounds(shape);
        polygon = [bounds.minX, bounds.minY, bounds.maxX, bounds.minY,
          bounds.maxX, bounds.maxY, bounds.minX, bounds.maxY];
      } else {
        shape.points.forEach((point): void => { polygon.push(point.x, point.y); });
      }
      computed = nativeHongTuService.regionBooleanForEdit([polygon], [], 1, gridNm);
    } else {
      return { ok: false, polygons: [], message: `对象 #${shape.id} 不属于 RECT/POLYGON/PATH 面积几何` };
    }
    if (!computed.success) return { ok: false, polygons: [], message: computed.errorMessage };
    let pointsCount: number = 0;
    if ((shape.type === ShapeType.PATH && computed.polygons.length === 0) || computed.polygons.length > 40000 || computed.polygons.some((polygon: number[]): boolean => {
      if (!Array.isArray(polygon)) return true;
      pointsCount += polygon.length / 2;
      if (!Array.isArray(polygon) || polygon.length < 6 || polygon.length % 2 !== 0 || pointsCount > 400000) return true;
      let area: number = 0;
      for (let i: number = 0; i < polygon.length; i += 2) {
        const next: number = (i + 2) % polygon.length;
        area += (polygon[i] - polygon[0]) * (polygon[next + 1] - polygon[1]) -
          (polygon[next] - polygon[0]) * (polygon[i + 1] - polygon[1]);
      }
      return !Number.isFinite(area) || area === 0 || polygon.some((coordinate: number): boolean => {
          const units: number = coordinate / gridNm;
          return !Number.isFinite(units) || Math.abs(units) > 1e14 ||
            Math.abs(coordinate - Math.round(units) * gridNm) >
              Math.max(1e-10, Math.abs(coordinate) * Number.EPSILON * 4);
        });
    })) return { ok: false, polygons: [], message: '几何模块返回无效、超预算或未量化的 PATH 区域；原图已保留' };
    return { ok: true, polygons: computed.polygons, message: '', roundCapErrorNm: computed.roundCapErrorNm };
  }
}

export const shapeRegionAdapterService: ShapeRegionAdapterService = new ShapeRegionAdapterService();
