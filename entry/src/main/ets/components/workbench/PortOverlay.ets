import { COLORS, worldToScreenPx, worldToScreenYpx } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PortEndpoint, ResolvedPort } from '../../models/LayoutPort';

interface PortLabelBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

@Component
export struct PortOverlay {
  @Prop @Watch('redraw') ports: ResolvedPort[] = [];
  @Prop @Watch('redraw') zoomPercent: number = 100;
  @Prop @Watch('redraw') viewOffsetX: number = 0;
  @Prop @Watch('redraw') viewOffsetY: number = 0;
  @Prop @Watch('redraw') canvasWidth: number = 0;
  @Prop @Watch('redraw') canvasHeight: number = 0;
  @Prop pickAllowed: boolean = false;
  onPick: (endpoint: PortEndpoint) => void = (_endpoint: PortEndpoint) => {};
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private x(port: ResolvedPort): number { return worldToScreenPx(port.centerNm.x, this.zoomPercent, this.viewOffsetX); }
  private y(port: ResolvedPort): number { return worldToScreenYpx(port.centerNm.y, this.zoomPercent, this.viewOffsetY); }
  private visibleCenters(): ResolvedPort[] {
    return this.ports.filter((port: ResolvedPort): boolean => this.x(port) >= 0 && this.x(port) <= this.canvasWidth &&
      this.y(port) >= 0 && this.y(port) <= this.canvasHeight);
  }
  private portIdentity(port: ResolvedPort): string {
    return `${port.definition.id}:${port.endpoint.path.map((step): string => `${step.instanceId}/${step.row}/${step.col}`).join('>')}`;
  }
  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    ctx.font = `${UI.fontCaption}vp sans-serif`;
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    const whiteCanvas: boolean = COLORS.canvasBg === '#FFFFFF';
    const labels: PortLabelBounds[] = [];
    for (const port of this.ports) {
      const x: number = this.x(port);
      const y: number = this.y(port);
      const radians: number = port.orientationDeg * Math.PI / 180;
      const nx: number = Math.cos(radians);
      const ny: number = -Math.sin(radians);
      const half: number = Math.abs(worldToScreenPx(port.effectiveWidthNm / 2, this.zoomPercent, 0) - worldToScreenPx(0, this.zoomPercent, 0));
      if (x + half < 0 || y + half < 0 || x - half > ctx.width || y - half > ctx.height) continue;
      const strokeColor: string = port.endpoint.path.length === 0 ? COLORS.primary : COLORS.teal;
      ctx.strokeStyle = strokeColor;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(x - ny * half, y + nx * half);
      ctx.lineTo(x + ny * half, y - nx * half);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(x, y);
      ctx.lineTo(x + nx * 18, y + ny * 18);
      ctx.moveTo(x + nx * 12 + ny * 4, y + ny * 12 - nx * 4);
      ctx.lineTo(x + nx * 18, y + ny * 18);
      ctx.lineTo(x + nx * 12 - ny * 4, y + ny * 12 + nx * 4);
      ctx.stroke();
      const textWidth: number = ctx.measureText(port.definition.name).width;
      const label: PortLabelBounds = {
        x: x + 8,
        y: y - 10 - UI.fontCaption,
        width: textWidth + 8,
        height: UI.fontCaption + 6
      };
      // Avoid canvas edges, top-left floating HUD/rail, and label collisions.
      const hitsTopLeftHud: boolean = label.x < 250 && label.y < 52;
      if (hitsTopLeftHud || label.x < 4 || label.y < 4 || label.x + label.width > ctx.width - 4 ||
        label.y + label.height > ctx.height - 4 || labels.some((placed: PortLabelBounds): boolean =>
          label.x < placed.x + placed.width + 4 && label.x + label.width + 4 > placed.x &&
          label.y < placed.y + placed.height + 4 && label.y + label.height + 4 > placed.y)) continue;
      ctx.fillStyle = whiteCanvas ? 'rgba(255, 255, 255, 0.88)' : 'rgba(11, 14, 20, 0.82)';
      ctx.fillRect(label.x, label.y, label.width, label.height);
      ctx.fillStyle = whiteCanvas ? strokeColor : (port.endpoint.path.length === 0 ? '#60A5FA' : '#5EEAD4');
      ctx.fillText(port.definition.name, label.x + 4, label.y + 3);
      labels.push(label);
    }
  }
  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Canvas(this.context).width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .onReady(() => { this.ready = true; this.redraw(); }).onAreaChange(() => this.redraw())
      if (this.pickAllowed) {
        ForEach(this.visibleCenters(), (port: ResolvedPort) => {
          Button('·', { type: ButtonType.Normal }).width(32).height(32).fontSize(24).fontColor(Color.Transparent)
            .backgroundColor(Color.Transparent).borderRadius(UI.controlRadius).position({ x: this.x(port) - 16, y: this.y(port) - 16 })
            .accessibilityText(`端口 ${port.definition.name} ${port.endpoint.path.length > 0 ? '实例' : '定义'}`)
            .onClick(() => this.onPick(port.endpoint))
        }, (port: ResolvedPort): string => this.portIdentity(port))
      }
    }.width('100%').height('100%')
  }
}
