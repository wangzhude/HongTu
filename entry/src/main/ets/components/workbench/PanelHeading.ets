import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { WorkbenchIcon } from './WorkbenchIcon';

/** Shared compact title, optional primary action, and system-styled circular close affordance for utility panels. */
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
      Column({ space: this.hasSubtitle() ? 4 : 0 }) {
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
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.hasPrimaryAction()) {
        Button(this.primaryLabel, { type: ButtonType.Capsule })
          .height(32)
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

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'close', iconSize: 15, color: COLORS.ink })
      }
      .width(34)
      .height(34)
      .padding(0)
      .borderRadius(Radius.pill)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .enabled(this.canClose)
      .hoverEffect(HoverEffect.Highlight)
      .accessibilityText(`关闭${this.title}`)
      .bindTips('关闭')
      .onClick(() => this.closeAction())
    }
    .width('100%')
    .constraintSize({ minHeight: this.hasSubtitle() ? 46 : 38 })
    .padding({ bottom: this.hasSubtitle() ? 10 : 8 })
    .margin({ bottom: 2 })
    .border({ width: { bottom: 0.75 }, color: COLORS.border })
  }
}
