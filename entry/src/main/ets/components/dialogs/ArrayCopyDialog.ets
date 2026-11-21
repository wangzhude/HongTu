/**
 * 阵列复制弹窗（KLayout: Edit > Selection > Make Array）
 *
 * 输入行数/列数与 X/Y 间距（nm），确认后由调用方执行阵列复制。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { hongTuThemeState } from '../../store/ThemeStore';
import { CounterComponent, CounterType } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

interface ArrayPitchFieldParams {
  label: string;
  value: string;
  autoFocus?: boolean;
  onChange: (v: string) => void;
}

@CustomDialog
export struct ArrayCopyDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  /** 确认回调 */
  onConfirm: (rows: number, cols: number, pitchX: number, pitchY: number) => boolean | void =
    (_rows: number, _cols: number, _pitchX: number, _pitchY: number) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';

  @State rowsText: string = '2';
  @State colsText: string = '2';
  @State pitchXText: string = '1000';
  @State pitchYText: string = '1000';
  @State error: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.error = '';
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) { this.error = '版图或选择已变化，请重新打开阵列复制'; return; }
    const rows: number = this.rowsText.trim().length > 0 ? Number(this.rowsText) : Number.NaN;
    const cols: number = this.colsText.trim().length > 0 ? Number(this.colsText) : Number.NaN;
    const pitchX: number = this.pitchXText.trim().length > 0 ? Number(this.pitchXText) : Number.NaN;
    const pitchY: number = this.pitchYText.trim().length > 0 ? Number(this.pitchYText) : Number.NaN;
    if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1 || rows * cols <= 1 || rows * cols > 1000000) {
      this.error = '行列数须为正整数，乘积须为 2–1000000'; return;
    }
    if (!Number.isFinite(pitchX) || !Number.isFinite(pitchY)) { this.error = '间距须为完整的有限数值，可填负数或小数'; return; }
    try {
      if (this.onConfirm(rows, cols, pitchX, pitchY) === false) { this.error = '阵列未完成，请检查选择、锁定图层或数量预算'; return; }
    } catch (error) { this.error = `阵列未完成：${String(error)}`; return; }
    this.error = '';
    this.controller.close();
  }

  @Builder
  buildField(params: ArrayPitchFieldParams) {
    Column() {
      Text(params.label)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .margin({ bottom: 8 })
        .alignSelf(ItemAlign.Start)
      TextInput({ text: params.value })
        .width('100%')
        .height(UI.fieldHeight)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .type(InputType.Normal)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .defaultFocus(params.autoFocus === true)
        .onFocus(() => { resetModifierKeys(); })
        .onChange((v: string) => params.onChange(v))
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
    .layoutWeight(1)
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Text('阵列复制')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: 18 })

      Row() {
        Column({ space: 8 }) {
          Text('行数').fontSize(UI.fontBody).fontColor(COLORS.ink).alignSelf(ItemAlign.Start)
          // 严守官方规范：CounterComponent 自身不链式追加通用属性，由外层 Column 承载布局
          Column() {
            CounterComponent({
              options: {
                type: CounterType.INLINE,
                inlineOptions: {
                  value: Math.max(1, Number.parseInt(this.rowsText) || 2),
                  min: 1,
                  max: 1000,
                  step: 1,
                  textWidth: 54,
                  onChange: (val: number) => { this.rowsText = `${val}`; }
                }
              }
            })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Blank().width(12)
        Column({ space: 8 }) {
          Text('列数').fontSize(UI.fontBody).fontColor(COLORS.ink).alignSelf(ItemAlign.Start)
          Column() {
            CounterComponent({
              options: {
                type: CounterType.INLINE,
                inlineOptions: {
                  value: Math.max(1, Number.parseInt(this.colsText) || 2),
                  min: 1,
                  max: 1000,
                  step: 1,
                  textWidth: 54,
                  onChange: (val: number) => { this.colsText = `${val}`; }
                }
              }
            })
          }
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .margin({ bottom: 16 })

      Row() {
        this.buildField({ label: 'X 间距 (nm)', value: this.pitchXText, autoFocus: true, onChange: (v: string) => { this.pitchXText = v; } })
        Blank().width(12)
        this.buildField({ label: 'Y 间距 (nm)', value: this.pitchYText, onChange: (v: string) => { this.pitchYText = v; } })
      }
      .width('100%')

      if (this.error.length > 0) {
        Text(this.error).fontSize(UI.fontCaption).fontColor(COLORS.danger).width('100%').margin({ top: 10 })
      }

      Row() {
        Blank()
        Button('取消', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 24, right: 24 })
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .fontSize(UI.fontBody)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.controller.close();
          })
        Blank().width(12)
        Button('复制', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 24, right: 24 })
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .padding({ top: 16 })
      .border({ width: { top: 1 }, color: COLORS.border })
      .margin({ top: 24 })
    }
    .width(420)
    .constraintSize({ maxWidth: '94%' })
    .padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
