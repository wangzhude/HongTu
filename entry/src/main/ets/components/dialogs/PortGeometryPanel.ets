import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { ResolvedPort } from '../../models/LayoutPort';
export { PortUiChoice } from '../../models/PortUiChoice';

/** Render actual projected centers, outward normals and effective widths in Cell coordinates. */
@Component
export struct PortGeometryPanel {
  @Prop title: string = '';
  @Prop @Watch('redraw') ports: ResolvedPort[] = [];
  @Prop @Watch('redraw') extentPorts: ResolvedPort[] = [];
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.context;
    const width: number = ctx.width, height: number = ctx.height;
    ctx.clearRect(0, 0, width, height);
    const extent: ResolvedPort[] = this.extentPorts.length > 0 ? this.extentPorts : this.ports;
    if (extent.length === 0) return;
    let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
    for (const port of extent) {
      const radius: number = Math.max(1, port.effectiveWidthNm);
      minX = Math.min(minX, port.centerNm.x - radius); maxX = Math.max(maxX, port.centerNm.x + radius);
      minY = Math.min(minY, port.centerNm.y - radius); maxY = Math.max(maxY, port.centerNm.y + radius);
    }
    const scale: number = Math.min((width - 56) / Math.max(1, maxX - minX), (height - 42) / Math.max(1, maxY - minY));
    const ox: number = (width - (maxX - minX) * scale) / 2, oy: number = (height - (maxY - minY) * scale) / 2;
    for (let index: number = 0; index < this.ports.length; index++) {
      const port: ResolvedPort = this.ports[index], radians: number = port.orientationDeg * Math.PI / 180;
      const x: number = ox + (port.centerNm.x - minX) * scale, y: number = height - oy - (port.centerNm.y - minY) * scale;
      const nx: number = Math.cos(radians), ny: number = -Math.sin(radians), half: number = Math.max(2, port.effectiveWidthNm * scale / 2);
      const length: number = Math.max(16, Math.min(36, half));
      const color: string = index === 0 ? COLORS.primary : COLORS.ink;
      ctx.strokeStyle = color;
      ctx.fillStyle = color;
      ctx.lineWidth = 2;
      ctx.beginPath(); ctx.moveTo(x - ny * half, y + nx * half); ctx.lineTo(x + ny * half, y - nx * half); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + nx * length, y + ny * length);
      ctx.moveTo(x + nx * length - nx * 7 + ny * 4, y + ny * length - ny * 7 - nx * 4);
      ctx.lineTo(x + nx * length, y + ny * length); ctx.lineTo(x + nx * length - nx * 7 - ny * 4, y + ny * length - ny * 7 + nx * 4); ctx.stroke();
      ctx.beginPath(); ctx.arc(x, y, 2.5, 0, 2 * Math.PI); ctx.fill();
      ctx.font = '12vp sans-serif';
      ctx.fillText(port.definition.name, Math.max(4, Math.min(width - 64, x + 8)), Math.max(14, y - half - 6));
    }
  }
  build() {
    Column({ space: 8 }) {
      Text(this.title).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
      Canvas(this.context).height(148).width('100%').backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        .onReady(() => { this.ready = true; this.redraw(); }).onAreaChange(() => this.redraw())
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
