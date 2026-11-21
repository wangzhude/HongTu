import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { resetModifierKeys } from '../../common/ModifierKeys';

/** Live component props prevent numeric Builder arguments capturing old state. */
@Component
export struct GeometryNumberField {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop inputAllowed: boolean = true;
  onValueChange: (value: string) => void = (_value: string) => {};
  build() {
    Column({ space: 8 }) {
      Text(this.label).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      TextInput({ text: this.value }).height(UI.fieldHeight).width('100%')
        .fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(this.inputAllowed)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .onChange((value: string) => { if (this.inputAllowed && value !== this.value) this.onValueChange(value); })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
