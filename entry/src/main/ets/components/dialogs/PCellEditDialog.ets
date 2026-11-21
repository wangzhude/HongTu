import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { nativeHongTuService } from '../../services/NativeHongTuService';
import type { PCellParamInfo } from '../../../cpp/types/libhongtu/Index';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct PCellEditDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  pcellName: string = '';
  initialParams: Record<string, number | string | boolean> = {};
  applyAction: (params: Record<string, number | string | boolean>) => string = () => '';
  @State fields: PCellParamInfo[] = [];
  @State values: Record<string, string> = {};
  @State error: string = '';
  @State definitionAvailable: boolean = false;
  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.fields = []; this.values = {}; this.error = ''; this.definitionAvailable = false;
    const definition = nativeHongTuService.listPCells().find((item) => item.name === this.pcellName);
    if (definition === undefined) { this.error = '当前 PCell 定义不可用'; return; }
    this.fields = definition.params;
    this.definitionAvailable = true;
    const values: Record<string, string> = {};
    for (const field of definition.params) values[field.name] = String(this.initialParams[field.name] ?? field.defaultValue);
    this.values = values;
  }
  private apply(): void {
    if (!this.definitionAvailable) { this.error = '当前 PCell 定义不可用'; return; }
    const params: Record<string, number | string | boolean> = {};
    for (const field of this.fields) {
      const value: string = this.values[field.name] ?? '';
      if (field.type === 'boolean') params[field.name] = value === 'true';
      else if (field.type === 'string') params[field.name] = value;
      else {
        const number: number = Number(value);
        if (value.trim().length === 0 || !Number.isFinite(number) ||
          ((field.type === 'int' || field.type === 'layer') && !Number.isInteger(number)) ||
          (field.type === 'layer' && (number < 0 || number > 32767))) {
          this.error = `${field.displayName} 需要有效${field.type === 'int' ? '整数' : '数值'}`; return;
        }
        if ((typeof field.minValue === 'number' && number < field.minValue) ||
          (typeof field.maxValue === 'number' && number > field.maxValue)) {
          this.error = `${field.displayName} 超出允许范围 ${field.minValue}–${field.maxValue}`; return;
        }
        params[field.name] = number;
      }
    }
    this.error = this.applyAction(params);
    if (this.error.length === 0) this.controller.close();
  }
  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column({ space: 12 }) {
      Text(`编辑 ${this.pcellName} 参数`).fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      Row().width('100%').height(1).backgroundColor(COLORS.border).margin({ top: 4, bottom: 4 })
      Scroll() {
        Column({ space: 16 }) {
          ForEach(this.fields, (field: PCellParamInfo, index: number) => {
            Column({ space: 8 }) {
              Text(`${field.displayName}${field.unit ? ` (${field.unit})` : ''}`).width('100%').fontSize(UI.fontBody).fontColor(COLORS.ink)
              if (field.type === 'boolean') {
                Toggle({ type: ToggleType.Switch, isOn: this.values[field.name] === 'true' })
                  .onChange((on: boolean) => { this.values[field.name] = on ? 'true' : 'false'; })
              } else {
                TextInput({ text: this.values[field.name] ?? '' }).width('100%')
                  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
                  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                  .defaultFocus(this.fields.findIndex((item: PCellParamInfo) => item.type !== 'boolean') === index)
                  .onFocus(() => { resetModifierKeys(); })
                  .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                  .onChange((value: string) => { this.values[field.name] = value; })
              }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }, (field: PCellParamInfo) => field.name)
        }.width('100%').padding({ right: 2 })
      }.constraintSize({ maxHeight: 360 }).width('100%').align(Alignment.Top).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      if (this.error.length > 0) Text(this.error).fontSize(UI.fontCaption).fontColor(COLORS.danger)
      Row({ space: 12 }) {
        Blank()
        Button('取消', { type: ButtonType.Normal }).padding({ left: 24, right: 24 })
          .height(UI.controlHeight).fontSize(UI.fontBody).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => this.controller.close())
        Button('更新器件', { type: ButtonType.Normal }).padding({ left: 24, right: 24 })
          .height(UI.controlHeight).fontSize(UI.fontBody).borderRadius(UI.controlRadius)
          .backgroundColor(COLORS.primary).fontColor(Color.White)
          .enabled(this.definitionAvailable)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => this.apply())
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border }).margin({ top: 12 })
    }.padding(UI.dialogPadding).width(520).constraintSize({ maxWidth: '94%' })
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius)
      .transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
