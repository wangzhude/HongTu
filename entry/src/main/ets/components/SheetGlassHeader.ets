/**
 * 轻量二级半模态全透明玻璃顶栏（`SheetGlassHeader`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 不套 HdsNavigation 的中小型半模态顶部栏保持 `backgroundColor(Color.Transparent)`、
 * 无底部分割线、无二次模糊，支持可选右上角单一主操作按钮与无副标紧凑单行排版，
 * 让宿主 `buildLuminousSheetOptions` 的整块玻璃材质浑然一体。
 */

import { FontWeightTokens, hongTuThemeState, Radius, ThemeState, TypeScale } from '../store/ThemeStore';

@Component
export struct SheetGlassHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop showBack: boolean = false;
  @Prop showClose: boolean = true;
  @Prop primaryLabel: string = '';
  @Prop primaryEnabled: boolean = true;
  @Consume themeState: ThemeState;
  onBack: () => void = () => {};
  onClose: () => void = () => {};
  onPrimary: () => void = () => {};

  private hasSubtitle(): boolean {
    return this.subtitle.trim().length > 0;
  }

  private hasPrimaryAction(): boolean {
    return this.primaryLabel.trim().length > 0;
  }

  build() {
    Row({ space: 10 }) {
      if (this.showBack) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(18)
            .fontColor([(this.themeState ?? hongTuThemeState).colors.text])
        }
        .width(36)
        .height(36)
        .backgroundColor((this.themeState ?? hongTuThemeState).colors.controlSurface)
        .border({ width: 0.8, color: (this.themeState ?? hongTuThemeState).colors.border })
        .borderRadius(Radius.pill)
        .accessibilityText('返回')
        .onClick(() => this.onBack())
      }

      Column({ space: this.hasSubtitle() ? 3 : 0 }) {
        Text(this.title)
          .fontSize(TypeScale.sectionTitle)
          .fontWeight(FontWeightTokens.strong)
          .fontFamily((this.themeState ?? hongTuThemeState).fontFamily)
          .fontColor((this.themeState ?? hongTuThemeState).colors.text)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.hasSubtitle()) {
          Text(this.subtitle)
            .fontSize(TypeScale.caption)
            .fontFamily((this.themeState ?? hongTuThemeState).fontFamily)
            .fontColor((this.themeState ?? hongTuThemeState).colors.textSecondary)
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
          .fontSize(TypeScale.meta)
          .fontWeight(FontWeightTokens.semibold)
          .fontFamily((this.themeState ?? hongTuThemeState).fontFamily)
          .fontColor('#FFFFFF')
          .backgroundColor((this.themeState ?? hongTuThemeState).colors.primary)
          .enabled(this.primaryEnabled)
          .opacity(this.primaryEnabled ? 1.0 : 0.45)
          .attributeModifier((this.themeState ?? hongTuThemeState).luminousPointLightModifier())
          .accessibilityText(this.primaryLabel)
          .onClick(() => {
            if (this.primaryEnabled) {
              this.onPrimary();
            }
          })
      }

      if (this.showClose) {
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([(this.themeState ?? hongTuThemeState).colors.text])
        }
        .width(36)
        .height(36)
        .backgroundColor((this.themeState ?? hongTuThemeState).colors.controlSurface)
        .border({ width: 0.8, color: (this.themeState ?? hongTuThemeState).colors.border })
        .borderRadius(Radius.pill)
        .accessibilityText(`关闭${this.title}`)
        .onClick(() => this.onClose())
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.hasSubtitle() ? 52 : 46 })
    .padding({
      left: 20,
      right: 20,
      top: this.hasSubtitle() ? 14 : 12,
      bottom: this.hasSubtitle() ? 8 : 6
    })
    .backgroundColor(Color.Transparent)
    .alignItems(VerticalAlign.Center)
  }
}
