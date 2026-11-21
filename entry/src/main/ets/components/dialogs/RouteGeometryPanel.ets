import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { Shape, Point } from '../../models/GdsiiData';
import { ResolvedPort } from '../../models/LayoutPort';
import { PlannedRoute } from '../../services/RoutePlannerService';

/** Draw the candidate's actual material polygons and measured centerlines. */
@Component
export struct RouteGeometryPanel {
  @Prop @Watch('redraw') shapes: Shape[] = [];
  @Prop @Watch('redraw') ports: ResolvedPort[] = [];
  @Prop @Watch('redraw') routes: PlannedRoute[] = [];
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.context;
    const width: number = ctx.width, height: number = ctx.height;
    ctx.clearRect(0, 0, width, height);
    const points: Point[] = [];
    for (const shape of this.shapes) for (const point of shape.points) points.push(point);
    for (const port of this.ports) points.push(port.centerNm);
    if (!points.length || width <= 56 || height <= 48) return;
    let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
    for (const p of points) { minX = Math.min(minX, p.x); minY = Math.min(minY, p.y); maxX = Math.max(maxX, p.x); maxY = Math.max(maxY, p.y); }
    const scale: number = Math.min((width - 56) / Math.max(1, maxX - minX), (height - 48) / Math.max(1, maxY - minY));
    const ox: number = (width - (maxX - minX) * scale) / 2, oy: number = (height - (maxY - minY) * scale) / 2;
    const x = (p: Point): number => ox + (p.x - minX) * scale;
    const y = (p: Point): number => height - oy - (p.y - minY) * scale;
    const palette: string[] = [COLORS.primary, COLORS.success, COLORS.warning, COLORS.ink];
    const pairs: string[] = [];
    for (const shape of this.shapes) {
      if (shape.points.length < 3) continue;
      const pair: string = `${shape.layerNumber}/${shape.datatype}`;
      let index: number = pairs.indexOf(pair); if (index < 0) { index = pairs.length; pairs.push(pair); }
      const layerColor: string = palette[index % palette.length];
      ctx.strokeStyle = layerColor;
      ctx.fillStyle = layerColor;
      ctx.globalAlpha = 0.24;
      ctx.beginPath(); ctx.moveTo(x(shape.points[0]), y(shape.points[0]));
      for (let i: number = 1; i < shape.points.length; i++) ctx.lineTo(x(shape.points[i]), y(shape.points[i]));
      ctx.closePath(); ctx.fill(); ctx.globalAlpha = 1; ctx.lineWidth = 1; ctx.stroke();
    }
    ctx.strokeStyle = COLORS.primary; ctx.lineWidth = 1.5;
    for (const route of this.routes) {
      if (!route.pointsNm.length) continue;
      ctx.beginPath(); ctx.moveTo(x(route.pointsNm[0]), y(route.pointsNm[0]));
      for (let i: number = 1; i < route.pointsNm.length; i++) ctx.lineTo(x(route.pointsNm[i]), y(route.pointsNm[i]));
      ctx.stroke();
    }
    const inkColor: string = COLORS.ink;
    ctx.strokeStyle = inkColor; ctx.fillStyle = inkColor;
    for (const port of this.ports) {
      const px: number = x(port.centerNm), py: number = y(port.centerNm), radians: number = port.orientationDeg * Math.PI / 180;
      ctx.beginPath(); ctx.arc(px, py, 3, 0, 2 * Math.PI); ctx.fill();
      ctx.beginPath(); ctx.moveTo(px, py); ctx.lineTo(px + Math.cos(radians) * 18, py - Math.sin(radians) * 18); ctx.stroke();
      ctx.font = '11vp sans-serif'; ctx.fillText(port.definition.name, Math.max(4, Math.min(width - 64, px + 6)), Math.max(14, py - 8));
    }
  }
  build() {
    Column({ space: 8 }) {
      Text(this.shapes.length ? '实际候选材料' : '端点与候选材料').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Canvas(this.context).width('100%').height(220).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        .onReady(() => { this.ready = true; this.redraw(); }).onAreaChange(() => this.redraw())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
