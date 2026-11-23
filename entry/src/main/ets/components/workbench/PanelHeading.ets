import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';

/**
 * 统一原生半模态/面板透明玻璃头部（对齐 SheetGlassHeader 规范：透明背景、无冗余重分割线、原生 SymbolGlyph 关闭圆钮）
 */
@Component
export struct PanelHeading {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop canClose: boolean = true;
  @Prop primaryLabel: string = '';
  @Prop primaryEnabled: boolean = true;
  closeAction: () => void = () => {};
  primaryAction: () => void = () => {};

  private hasSubtitle(): boolean {
    return this.subtitle.trim().length > 0;
  }

  private hasPrimaryAction(): boolean {
    return this.primaryLabel.trim().length > 0;
  }

  build() {
    Row({ space: 10 }) {
      Column({ space: this.hasSubtitle() ? 3 : 0 }) {
        Text(this.title)
          .fontSize(UI.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.hasSubtitle()) {
          Text(this.subtitle)
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.muted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.hasPrimaryAction()) {
        Button(this.primaryLabel, { type: ButtonType.Capsule })
          .height(34)
          .padding({ left: 14, right: 14 })
          .fontSize(UI.fontCaption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(COLORS.primary)
          .enabled(this.primaryEnabled)
          .opacity(this.primaryEnabled ? 1.0 : 0.45)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .accessibilityText(this.primaryLabel)
          .onClick(() => {
            if (this.primaryEnabled) {
              this.primaryAction();
            }
          })
      }

      if (this.canClose) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([COLORS.ink])
            .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        }
        .width(34)
        .height(34)
        .padding(0)
        .borderRadius(Radius.pill)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .hoverEffect(HoverEffect.Highlight)
        .accessibilityText(`关闭${this.title}`)
        .bindTips('关闭')
        .onClick(() => this.closeAction())
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.hasSubtitle() ? 46 : 40 })
    .padding({ top: 4, bottom: 8 })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
  }
}
