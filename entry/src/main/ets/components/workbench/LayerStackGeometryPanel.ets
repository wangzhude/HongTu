import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { LengthMetricsUnit } from '@kit.ArkUI';
import type { Point } from '../../models/GdsiiData';
import type { PhysicalLayerStack } from '../../models/PhysicalLayerStack';
import type { LayerStackPreview, LayerStackVertex } from '../../services/LayerStackService';

interface StackDisplayFace { materialId: string; points: Point[]; depth: number; }

export interface LayerStackRasterVertex {
  xPx: number; yPx: number;
  /** Camera-space coordinate increasing towards the observer. */
  depth: number;
  /** 1 for orthographic projection; 1 / positive clip W for perspective. */
  reciprocalW: number;
}
export interface LayerStackRasterTriangle {
  a: LayerStackRasterVertex; b: LayerStackRasterVertex; c: LayerStackRasterVertex; colorRgb: number;
}
export interface LayerStackRasterBudget { maxPixels?: number; maxPixelTests?: number; maxTriangles?: number; }
export interface LayerStackRasterResult {
  rgba: Uint8ClampedArray; depths: Float64Array;
  pixels: number; pixelTests: number; drawnTriangles: number;
}

function rasterLimit(value: number | undefined, fallback: number, maximum: number): number {
  const limit: number = value ?? fallback;
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > maximum) throw new Error('三维显示预算无效');
  return limit;
}

/** Rasterize complete projected triangles at physical pixel centres. Camera-space
 * attributes need perspective correction; post-divide NDC Z must not be supplied
 * as that attribute. Perspective callers must clip against their positive near
 * plane before calling. This component uses an orthographic camera (W = 1).
 * No triangle thinning or partial buffer is published on budget failure. */
export function rasterizeLayerStackTriangles(triangles: LayerStackRasterTriangle[], width: number, height: number,
  budget: LayerStackRasterBudget = {}): LayerStackRasterResult {
  const pixelMaximum: number = rasterLimit(budget.maxPixels, 4000000, 4000000);
  const testMaximum: number = rasterLimit(budget.maxPixelTests, 32000000, 64000000);
  const triangleMaximum: number = rasterLimit(budget.maxTriangles, 200000, 1000000);
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width < 1 || height < 1 ||
    width > 8192 || height > 8192 || width * height > pixelMaximum) throw new Error('三维视图像素超过交互预算；缩小视图后重试');
  if (triangles.length > triangleMaximum) throw new Error('完整三角网格超过交互预算；截面与完整导出仍可用');
  const rgba: Uint8ClampedArray = new Uint8ClampedArray(width * height * 4);
  const depths: Float64Array = new Float64Array(width * height); depths.fill(-Infinity);
  const colors: Uint32Array = new Uint32Array(width * height);
  let pixels: number = 0, pixelTests: number = 0, drawnTriangles: number = 0;
  for (const triangle of triangles) {
    const a: LayerStackRasterVertex = triangle.a, b: LayerStackRasterVertex = triangle.b, c: LayerStackRasterVertex = triangle.c;
    for (const p of [a, b, c]) if (!Number.isFinite(p.xPx) || !Number.isFinite(p.yPx) || !Number.isFinite(p.depth) ||
      !Number.isFinite(p.reciprocalW) || p.reciprocalW <= 0) throw new Error('三维投影存在无效坐标或未裁剪的近裁面');
    if (!Number.isSafeInteger(triangle.colorRgb) || triangle.colorRgb < 0 || triangle.colorRgb > 0xFFFFFF) throw new Error('三维材料颜色无效');
    const area: number = (b.xPx - a.xPx) * (c.yPx - a.yPx) - (b.yPx - a.yPx) * (c.xPx - a.xPx);
    if (!Number.isFinite(area)) throw new Error('三维投影面积溢出');
    if (area === 0) continue; // A genuinely edge-on face has no covered pixel.
    const left: number = Math.max(0, Math.ceil(Math.min(a.xPx, b.xPx, c.xPx) - 0.5));
    const right: number = Math.min(width - 1, Math.floor(Math.max(a.xPx, b.xPx, c.xPx) - 0.5));
    const top: number = Math.max(0, Math.ceil(Math.min(a.yPx, b.yPx, c.yPx) - 0.5));
    const bottom: number = Math.min(height - 1, Math.floor(Math.max(a.yPx, b.yPx, c.yPx) - 0.5));
    if (right < left || bottom < top) continue;
    const work: number = (right - left + 1) * (bottom - top + 1);
    if (work > testMaximum - pixelTests) throw new Error('完整网格深度计算超过交互预算；截面与完整导出仍可用');
    pixelTests += work; drawnTriangles++;
    const ax: number = (b.yPx - c.yPx) / area, ay: number = (c.xPx - b.xPx) / area;
    const bx: number = (c.yPx - a.yPx) / area, by: number = (a.xPx - c.xPx) / area;
    for (let y: number = top; y <= bottom; y++) {
      let wa: number = ax * (left + 0.5 - c.xPx) + ay * (y + 0.5 - c.yPx);
      let wb: number = bx * (left + 0.5 - c.xPx) + by * (y + 0.5 - c.yPx);
      for (let x: number = left; x <= right; x++, wa += ax, wb += bx) {
        const wc: number = 1 - wa - wb;
        if (wa < -1e-10 || wb < -1e-10 || wc < -1e-10) continue;
        const reciprocalW: number = wa * a.reciprocalW + wb * b.reciprocalW + wc * c.reciprocalW;
        const depth: number = (wa * a.depth * a.reciprocalW + wb * b.depth * b.reciprocalW + wc * c.depth * c.reciprocalW) / reciprocalW;
        if (!Number.isFinite(depth) || !(reciprocalW > 0)) throw new Error('三维深度插值溢出');
        const at: number = y * width + x, old: number = depths[at];
        const epsilon: number = Number.EPSILON * 16 * Math.max(1, Math.abs(depth), Number.isFinite(old) ? Math.abs(old) : 0);
        if (Number.isFinite(old) && (depth < old - epsilon || (Math.abs(depth - old) <= epsilon && triangle.colorRgb >= colors[at]))) continue;
        if (!Number.isFinite(old)) pixels++;
        depths[at] = depth; colors[at] = triangle.colorRgb;
        rgba[at * 4] = (triangle.colorRgb >>> 16) & 255;
        rgba[at * 4 + 1] = (triangle.colorRgb >>> 8) & 255;
        rgba[at * 4 + 2] = triangle.colorRgb & 255; rgba[at * 4 + 3] = 255;
      }
    }
  }
  return { rgba: rgba, depths: depths, pixels: pixels, pixelTests: pixelTests, drawnTriangles: drawnTriangles };
}

/** Native Canvas projection of the service's actual closed triangles/section. */
@Component
export struct LayerStackGeometryPanel {
  @Prop @Watch('redraw') preview: LayerStackPreview | undefined = undefined;
  @Prop @Watch('redraw') mode: number = 0;
  @State yaw: number = 35;
  @State pitch: number = 25;
  @State notice: string = '';
  // Canvas and ImageData both use physical PX, so a vp/density conversion cannot
  // silently change raster dimensions or depth-buffer indexing.
  private canvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true), LengthMetricsUnit.PX);
  private ready: boolean = false;
  private rotateView(yaw: number, pitch: number): void { this.yaw += yaw; this.pitch = Math.max(-80, Math.min(80, this.pitch + pitch)); this.redraw(); }
  private color(materialId: string, stack: PhysicalLayerStack): string {
    return stack.materials.find((material): boolean => material.id === materialId)?.color ?? COLORS.primary;
  }
  private drawMesh(result: LayerStackPreview, stack: PhysicalLayerStack, width: number, height: number): void {
    let minX: number = Infinity, minY: number = Infinity, minZ: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity, maxZ: number = -Infinity;
    let count: number = 0;
    for (const mesh of result.meshes) {
      count += mesh.triangles.length;
      if (count > 200000) throw new Error('完整三角网格超过交互预算；截面与完整导出仍可用');
      for (const p of mesh.vertices) {
        if (!Number.isFinite(p.xNm) || !Number.isFinite(p.yNm) || !Number.isFinite(p.zNm)) throw new Error('三维材料坐标无效');
        minX = Math.min(minX, p.xNm); maxX = Math.max(maxX, p.xNm); minY = Math.min(minY, p.yNm); maxY = Math.max(maxY, p.yNm); minZ = Math.min(minZ, p.zNm); maxZ = Math.max(maxZ, p.zNm);
      }
    }
    if (!count) { this.notice = '当前 ROI 内没有物理材料'; return; }
    const cx: number = minX / 2 + maxX / 2, cy: number = minY / 2 + maxY / 2, cz: number = minZ / 2 + maxZ / 2;
    const yaw: number = this.yaw * Math.PI / 180, pitch: number = this.pitch * Math.PI / 180;
    const project = (p: LayerStackVertex): LayerStackRasterVertex => {
      const x: number = p.xNm - cx, y: number = p.yNm - cy, z: number = p.zNm - cz;
      return { xPx: x * Math.cos(yaw) - y * Math.sin(yaw),
        yPx: (x * Math.sin(yaw) + y * Math.cos(yaw)) * Math.sin(pitch) + z * Math.cos(pitch),
        depth: (x * Math.sin(yaw) + y * Math.cos(yaw)) * Math.cos(pitch) - z * Math.sin(pitch), reciprocalW: 1 };
    };
    const triangles: LayerStackRasterTriangle[] = [];
    let sx: number = Infinity, ex: number = -Infinity, sy: number = Infinity, ey: number = -Infinity;
    for (const mesh of result.meshes) {
      const color: string = this.color(mesh.materialId, stack);
      if (!/^#[0-9a-fA-F]{6}$/.test(color)) throw new Error('三维材料颜色须为 #RRGGBB');
      const rgb: number = Number.parseInt(color.substring(1), 16);
      for (const triangle of mesh.triangles) {
        if (![triangle.a, triangle.b, triangle.c].every((index: number): boolean => Number.isSafeInteger(index) && index >= 0 && index < mesh.vertices.length)) throw new Error('三维triangle索引无效');
        const a: LayerStackRasterVertex = project(mesh.vertices[triangle.a]), b: LayerStackRasterVertex = project(mesh.vertices[triangle.b]), c: LayerStackRasterVertex = project(mesh.vertices[triangle.c]);
        triangles.push({ a: a, b: b, c: c, colorRgb: rgb });
        for (const p of [a, b, c]) { sx = Math.min(sx, p.xPx); ex = Math.max(ex, p.xPx); sy = Math.min(sy, p.yPx); ey = Math.max(ey, p.yPx); }
      }
    }
    const scale: number = Math.min((width - 64) / Math.max(1, ex - sx), (height - 64) / Math.max(1, ey - sy));
    const ox: number = (width - (ex - sx) * scale) / 2, oy: number = (height - (ey - sy) * scale) / 2;
    for (const triangle of triangles) for (const p of [triangle.a, triangle.b, triangle.c]) {
      p.xPx = ox + (p.xPx - sx) * scale; p.yPx = height - oy - (p.yPx - sy) * scale;
    }
    const raster: LayerStackRasterResult = rasterizeLayerStackTriangles(triangles, Math.floor(width), Math.floor(height));
    const image: ImageData = new ImageData(Math.floor(width), Math.floor(height), raster.rgba, LengthMetricsUnit.PX);
    if (image.width !== Math.floor(width) || image.height !== Math.floor(height) || image.data.length !== raster.rgba.length) throw new Error('Canvas ImageData 像素单位不匹配');
    this.canvas.putImageData(image, 0, 0);
    if (count > 30000) this.notice = `逐像素深度显示全部 ${count} 个三角形；导出保留完整网格`;
  }
  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.canvas, width: number = ctx.width, height: number = ctx.height;
    ctx.clearRect(0, 0, width, height); this.notice = '';
    const result: LayerStackPreview | undefined = this.preview;
    if (result === undefined || width <= 60 || height <= 60) return;
    const stack: PhysicalLayerStack = JSON.parse(result.stackJson) as PhysicalLayerStack;
    const faces: StackDisplayFace[] = [];
    if (this.mode === 0) {
      for (const polygon of result.section) faces.push({ materialId: polygon.materialId, points: polygon.pointsNm, depth: 0 });
      if (faces.length === 0) { this.notice = '截线与材料没有交集'; return; }
    } else {
      try { this.drawMesh(result, stack, width, height); }
      catch (error) { this.notice = `${String(error)}；未显示部分三维模型`; }
      ctx.fillStyle = COLORS.muted; ctx.font = '11px sans-serif';
      ctx.fillText('实际三角网格正交投影（nm，等比例，逐像素深度）', 12, height - 12);
      return;
    }
    let minX: number = Infinity, maxX: number = -Infinity, minY: number = Infinity, maxY: number = -Infinity;
    for (const face of faces) for (const p of face.points) { minX = Math.min(minX, p.x); maxX = Math.max(maxX, p.x); minY = Math.min(minY, p.y); maxY = Math.max(maxY, p.y); }
    if (!faces.length) { this.notice = '当前 ROI 内没有物理材料'; return; }
    const scale: number = Math.min((width - 64) / Math.max(1, maxX - minX), (height - 64) / Math.max(1, maxY - minY));
    const ox: number = (width - (maxX - minX) * scale) / 2, oy: number = (height - (maxY - minY) * scale) / 2;
    for (const face of faces) {
      ctx.fillStyle = this.color(face.materialId, stack); ctx.strokeStyle = COLORS.ink; ctx.lineWidth = this.mode === 0 ? 0.8 : 0.25;
      ctx.beginPath(); ctx.moveTo(ox + (face.points[0].x - minX) * scale, height - oy - (face.points[0].y - minY) * scale);
      for (let index: number = 1; index < face.points.length; index++) ctx.lineTo(ox + (face.points[index].x - minX) * scale, height - oy - (face.points[index].y - minY) * scale);
      ctx.closePath(); ctx.fill(); ctx.stroke();
    }
    ctx.fillStyle = COLORS.muted; ctx.font = '11px sans-serif';
    ctx.fillText(this.mode === 0 ? '沿截线距离 / z（nm，等比例）' : '实际三角网格正交投影（nm，等比例）', 12, height - 12);
  }
  build() {
    Column({ space: 8 }) {
      Canvas(this.canvas).width('100%').height(300).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        .onReady(() => { this.ready = true; this.redraw(); }).onAreaChange(() => this.redraw())
      if (this.mode === 1) {
        Row({ space: 8 }) {
          Button('左转', { type: ButtonType.Normal }).stackViewButton().onClick(() => this.rotateView(-15, 0))
          Button('右转', { type: ButtonType.Normal }).stackViewButton().onClick(() => this.rotateView(15, 0))
          Button('俯视', { type: ButtonType.Normal }).stackViewButton().onClick(() => this.rotateView(0, 15))
          Button('仰视', { type: ButtonType.Normal }).stackViewButton().onClick(() => this.rotateView(0, -15))
        }.width('100%')
      }
      if (this.notice.length > 0) Text(this.notice).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
    }.width('100%')
  }
}
@Extend(Button)
function stackViewButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
    .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}
