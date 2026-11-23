/**
 * 鸿蒙原生状态指示组件（`DrawnStatusIcon`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 全面移除旧版命令式 `CanvasRenderingContext2D` 实例（消除列表与标签栏每行创建 2D 画布上下文的开销），
 * 统一采用 HarmonyOS 官方 `SymbolGlyph` 与声明式原生图形原语（`Stack` / `Circle`）承载状态语义。
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
  @Prop kind: DrawnStatusKind = 'warning';
  @Prop iconSize: number = 16;
  @Prop strokeColor: string = '#E8A23C';
  @Prop showSoftPlate: boolean = true;

  private symbolForKind(): Resource {
    if (this.kind === 'success') {
      return $r('sys.symbol.checkmark_circle');
    }
    if (this.kind === 'error') {
      return $r('sys.symbol.xmark_square');
    }
    return $r('sys.symbol.exclamationmark_triangle');
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.showSoftPlate) {
        Circle({ width: Math.max(10, this.iconSize), height: Math.max(10, this.iconSize) })
          .fill(buildSoftTint(this.strokeColor, 0.14))
      }

      if (this.kind === 'warning' || this.kind === 'success' || this.kind === 'error') {
        SymbolGlyph(this.symbolForKind())
          .fontSize(this.showSoftPlate ? Math.max(9, Math.round(this.iconSize * 0.68)) : Math.max(10, this.iconSize))
          .fontColor([this.strokeColor])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
      } else if (this.kind === 'radio') {
        Stack({ alignContent: Alignment.Center }) {
          Circle({
            width: Math.max(7, Math.round(this.iconSize * 0.76)),
            height: Math.max(7, Math.round(this.iconSize * 0.76))
          })
            .fill(Color.Transparent)
            .stroke(this.strokeColor)
            .strokeWidth(Math.max(1.2, this.iconSize * 0.12))
          Circle({
            width: Math.max(3.5, Math.round(this.iconSize * 0.38)),
            height: Math.max(3.5, Math.round(this.iconSize * 0.38))
          })
            .fill(this.strokeColor)
        }
      } else {
        Circle({
          width: Math.max(5, Math.round(this.iconSize * 0.56)),
          height: Math.max(5, Math.round(this.iconSize * 0.56))
        })
          .fill(this.strokeColor)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no')
  }
}
