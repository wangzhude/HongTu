/**
 * 纯矢量抗锯齿状态图标组件（`DrawnStatusIcon`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 严格遵循零 Emoji / 零内联特殊符号政策：
 * - 开启 `RenderingContextSettings(true)` 抗锯齿；
 * - 圆头线帽（`lineCap = 'round'`、`lineJoin = 'round'`）；
 * - 线宽随尺寸自适应 `Math.max(1.35, size * 0.092)`；
 * - 根据 `#RRGGBB` 主色自动派生 `rgba(r, g, b, 0.14)` 柔和同色系底色，并随 `@Watch` 即时重绘。
 */

export type DrawnStatusKind = 'warning' | 'success' | 'error' | 'dirty' | 'active' | 'radio';

function buildSoftTint(hexColor: string, alpha: number = 0.14): string {
  if (hexColor.startsWith('#') && hexColor.length >= 7) {
    const r: number = parseInt(hexColor.substring(1, 3), 16);
    const g: number = parseInt(hexColor.substring(3, 5), 16);
    const b: number = parseInt(hexColor.substring(5, 7), 16);
    if (Number.isFinite(r) && Number.isFinite(g) && Number.isFinite(b)) {
      return `rgba(${r}, ${g}, ${b}, ${alpha})`;
    }
  }
  return 'rgba(41, 132, 255, 0.14)';
}

@Component
export struct DrawnStatusIcon {
  @Prop @Watch('redraw') kind: DrawnStatusKind = 'warning';
  @Prop @Watch('redraw') iconSize: number = 16;
  @Prop @Watch('redraw') strokeColor: string = '#E8A23C';
  @Prop @Watch('redraw') showSoftPlate: boolean = true;

  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private canvasReady: boolean = false;

  private redraw(): void {
    if (!this.canvasReady) {
      return;
    }
    const s: number = Math.max(10, this.iconSize);
    const c: CanvasRenderingContext2D = this.ctx;
    c.clearRect(0, 0, s, s);
    c.lineCap = 'round';
    c.lineJoin = 'round';
    const lw: number = Math.max(1.35, s * 0.092);
    c.lineWidth = lw;
    c.strokeStyle = this.strokeColor;
    const cx: number = s * 0.5;
    const cy: number = s * 0.5;

    if (this.showSoftPlate) {
      c.fillStyle = buildSoftTint(this.strokeColor, 0.14);
      c.beginPath();
      c.arc(cx, cy, s * 0.45, 0, Math.PI * 2);
      c.fill();
    }

    if (this.kind === 'warning') {
      const topY: number = s * 0.19;
      const botY: number = s * 0.79;
      const halfW: number = s * 0.34;
      c.beginPath();
      c.moveTo(cx, topY);
      c.lineTo(cx + halfW, botY);
      c.lineTo(cx - halfW, botY);
      c.closePath();
      c.stroke();

      c.beginPath();
      c.moveTo(cx, s * 0.41);
      c.lineTo(cx, s * 0.58);
      c.stroke();

      c.fillStyle = this.strokeColor;
      c.beginPath();
      c.arc(cx, s * 0.69, Math.max(1.0, lw * 0.56), 0, Math.PI * 2);
      c.fill();
    } else if (this.kind === 'success') {
      c.beginPath();
      c.moveTo(s * 0.27, s * 0.52);
      c.lineTo(s * 0.44, s * 0.69);
      c.lineTo(s * 0.75, s * 0.34);
      c.stroke();
    } else if (this.kind === 'error') {
      c.beginPath();
      c.moveTo(s * 0.32, s * 0.32);
      c.lineTo(s * 0.68, s * 0.68);
      c.moveTo(s * 0.68, s * 0.32);
      c.lineTo(s * 0.32, s * 0.68);
      c.stroke();
    } else if (this.kind === 'dirty' || this.kind === 'active') {
      c.fillStyle = this.strokeColor;
      c.beginPath();
      c.arc(cx, cy, s * 0.26, 0, Math.PI * 2);
      c.fill();
    } else if (this.kind === 'radio') {
      c.beginPath();
      c.arc(cx, cy, s * 0.36, 0, Math.PI * 2);
      c.stroke();
      c.fillStyle = this.strokeColor;
      c.beginPath();
      c.arc(cx, cy, s * 0.18, 0, Math.PI * 2);
      c.fill();
    }
  }

  build() {
    Canvas(this.ctx)
      .width(this.iconSize)
      .height(this.iconSize)
      .renderGroup(true)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no')
      .onReady(() => {
        this.canvasReady = true;
        this.redraw();
      })
  }
}
