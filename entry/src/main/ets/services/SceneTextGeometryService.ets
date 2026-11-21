import type { Shape, Point, ShapeBounds } from '../models/GdsiiData';
import type { ViewAffine } from '../models/ViewWorkspace';
import { SCENE_TEXT_LINE_HEIGHT } from '../models/ViewRenderScene';
import type { ViewSceneTextMetrics } from '../models/ViewRenderScene';

/** The measured top-left Text box shared by scene painting and hierarchy picks.
 * The intrinsic GDS matrix is supplied by the existing instance transform helper,
 * so this service does not import hierarchy traversal or duplicate STRANS rules. */
export class SceneTextGeometryService {
  private metrics: Map<string, ViewSceneTextMetrics> = new Map<string, ViewSceneTextMetrics>();
  private transformShape: (shape: Shape) => ViewAffine;
  private measureTextWidth: (text: string) => number;

  constructor(transformShape: (shape: Shape) => ViewAffine,
    measureTextWidth: (text: string) => number = (text: string): number => text.length * 24) {
    this.transformShape = transformShape;
    this.measureTextWidth = measureTextWidth;
  }

  clear(): void { this.metrics.clear(); }

  metricsFor(text: string): ViewSceneTextMetrics {
    const cached: ViewSceneTextMetrics | undefined = this.metrics.get(text);
    if (cached !== undefined) return cached;
    const lines: string[] = text.split(/\r\n|[\n\r\u2028\u2029]/);
    let width: number = 1;
    for (const line of lines) {
      const measured: number = this.measureTextWidth(line);
      if (!Number.isFinite(measured) || measured < 0) throw new Error('文字测量范围无效');
      width = Math.max(width, measured);
    }
    // Same fixed-font box as ViewSceneNode: guard wrapping/overhang with two EM.
    const metrics: ViewSceneTextMetrics = { width: width + 24, height: lines.length * SCENE_TEXT_LINE_HEIGHT, padding: 24 };
    if (this.metrics.size >= 512) this.metrics.clear();
    this.metrics.set(text, metrics);
    return metrics;
  }

  glyphTransform(shape: Shape, combined: ViewAffine): ViewAffine {
    const intrinsic: ViewAffine = this.transformShape(shape);
    // Translation belongs to the transformed anchor; only the linear glyph
    // matrix includes intrinsic MAG/mirror/rotation and all ancestor matrices.
    return { a: combined.a * intrinsic.a + combined.b * intrinsic.c,
      b: combined.a * intrinsic.b + combined.b * intrinsic.d,
      c: combined.c * intrinsic.a + combined.d * intrinsic.c,
      d: combined.c * intrinsic.b + combined.d * intrinsic.d, tx: 0, ty: 0 };
  }

  glyphBounds(anchor: Point, transform: ViewAffine, metrics: ViewSceneTextMetrics,
    includePadding: boolean = true): ShapeBounds {
    const p: number = includePadding ? metrics.padding : 0;
    // ArkUI Text starts at the top left and points down; world Y points up.
    const corners: Point[] = [{ x: -p, y: p }, { x: metrics.width + p, y: p },
      { x: metrics.width + p, y: -metrics.height - p }, { x: -p, y: -metrics.height - p }];
    const bounds: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    for (const corner of corners) {
      const x: number = transform.a * corner.x + transform.b * corner.y + anchor.x;
      const y: number = transform.c * corner.x + transform.d * corner.y + anchor.y;
      if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error('文字变换范围溢出');
      bounds.minX = Math.min(bounds.minX, x); bounds.maxX = Math.max(bounds.maxX, x);
      bounds.minY = Math.min(bounds.minY, y); bounds.maxY = Math.max(bounds.maxY, y);
    }
    return bounds;
  }

  boundsForShape(shape: Shape, combined: ViewAffine, includePadding: boolean = false): ShapeBounds {
    if (shape.points.length === 0) throw new Error('文字缺少锚点');
    const local: Point = shape.points[0];
    const anchor: Point = { x: combined.a * local.x + combined.b * local.y + combined.tx,
      y: combined.c * local.x + combined.d * local.y + combined.ty };
    return this.glyphBounds(anchor, this.glyphTransform(shape, combined), this.metricsFor(shape.text ?? ''), includePadding);
  }
}
