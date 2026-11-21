import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { RdbItem, RdbTransform } from '../../models/RdbData';
import { RdbMarkerGeometry, RdbMarkerPointNm, RdbMarkerPolygonNm } from '../../models/RdbMarkerGeometry';
import { rdbIdentityTransform } from '../../services/RdbService';
import { planRdbMarkerGeometry } from '../../services/RdbMarkerGeometryService';

/** Report markers are display-only. The editor database and undo history are never accessed. */
@Component
export struct RdbMarkerOverlay {
  @Prop @Watch('rebuild') item: RdbItem | null = null;
  @Prop @Watch('rebuild') frame: RdbTransform = rdbIdentityTransform();
  @Prop @Watch('redraw') zoomPercent: number = 100;
  @Prop @Watch('redraw') viewOffsetX: number = 0;
  @Prop @Watch('redraw') viewOffsetY: number = 0;
  @Prop @Watch('redraw') preview: boolean = false;
  @State notice: string = '';
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private geometry: RdbMarkerGeometry | null = null;
  private pixelScale: number = 1;
  private offsetX: number = 0;
  private offsetY: number = 0;

  private rebuild(): void {
    this.geometry = null; this.notice = '';
    if (this.item !== null) {
      const result = planRdbMarkerGeometry(this.item, this.frame);
      if (result.ok && result.geometry !== undefined) {
        this.geometry = result.geometry;
        this.notice = result.geometry.hasGeometry ? result.geometry.notices.join('；') : '此标记没有非空几何';
      } else { this.notice = result.message; }
    }
    this.redraw();
  }

  private x(point: RdbMarkerPointNm): number { return (point.x + this.offsetX) * this.pixelScale; }
  private y(point: RdbMarkerPointNm): number { return (this.offsetY - point.y) * this.pixelScale; }

  private polygon(value: RdbMarkerPolygonNm): void {
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.beginPath();
    for (const ring of value.rings) {
      if (ring.length === 0) continue;
      ctx.moveTo(this.x(ring[0]), this.y(ring[0]));
      for (let i: number = 1; i < ring.length; i++) ctx.lineTo(this.x(ring[i]), this.y(ring[i]));
      if (ring.length > 2) ctx.closePath();
    }
    ctx.fill(value.fillRule); ctx.stroke();
  }

  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    const geometry: RdbMarkerGeometry | null = this.geometry;
    if (geometry === null || !geometry.hasGeometry || ctx.width <= 0 || ctx.height <= 0) return;
    this.pixelScale = this.zoomPercent / 100; this.offsetX = this.viewOffsetX; this.offsetY = this.viewOffsetY;
    if (this.preview && geometry.cameraBoundsNm !== undefined) {
      const bounds = geometry.cameraBoundsNm;
      this.pixelScale = Math.min(Math.max(1, ctx.width - 24) / Math.max(1, bounds.maxX - bounds.minX),
        Math.max(1, ctx.height - 24) / Math.max(1, bounds.maxY - bounds.minY));
      this.offsetX = ctx.width / (2 * this.pixelScale) - (bounds.minX + bounds.maxX) / 2;
      this.offsetY = ctx.height / (2 * this.pixelScale) + (bounds.minY + bounds.maxY) / 2;
    }
    if (!Number.isFinite(this.pixelScale) || this.pixelScale <= 0) return;
    ctx.save(); ctx.strokeStyle = '#D52C66'; ctx.fillStyle = '#33D52C66'; ctx.lineWidth = 1.5;
    for (const polygon of geometry.polygons) this.polygon(polygon);
    for (const polygon of geometry.pathOutlines) this.polygon(polygon);
    for (const segment of geometry.segments) {
      if (segment.points.length === 0) continue;
      ctx.beginPath(); ctx.moveTo(this.x(segment.points[0]), this.y(segment.points[0]));
      for (let i: number = 1; i < segment.points.length; i++) ctx.lineTo(this.x(segment.points[i]), this.y(segment.points[i]));
      ctx.stroke();
    }
    for (const label of geometry.labels) {
      ctx.save(); ctx.translate(this.x(label.anchorNm), this.y(label.anchorNm));
      ctx.rotate(-label.rotationDeg * Math.PI / 180);
      if (label.mirror) ctx.scale(1, -1);
      // Label anchor/frame are exact. A readable UI font is not the report's measured font bbox.
      const fontSize: number = label.sourceSizeNm > 0 ? Math.max(10, Math.min(48, label.sourceSizeNm * this.pixelScale)) : 12;
      ctx.font = `${fontSize}px sans-serif`; ctx.fillStyle = '#D52C66';
      ctx.textAlign = label.horizontalAlignment === 'c' ? 'center' : label.horizontalAlignment === 'r' ? 'right' : 'left';
      ctx.textBaseline = label.verticalAlignment === 't' ? 'top' : label.verticalAlignment === 'c' ? 'middle' : 'bottom';
      ctx.fillText(label.text, 0, 0); ctx.restore();
    }
    ctx.restore();
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.context).width('100%').height('100%')
        .onReady(() => { this.ready = true; this.rebuild(); }).onAreaChange(() => this.redraw())
      if (this.preview && this.notice.length > 0) {
        Text(this.notice).fontSize(UI.fontCaption).fontColor(COLORS.muted).padding(4).width('100%')
      }
    }.width('100%').height('100%').clip(true).hitTestBehavior(HitTestMode.None)
  }
}
