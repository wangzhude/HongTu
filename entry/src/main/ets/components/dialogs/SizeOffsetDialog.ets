/**
 * 尺寸调整弹窗（KLayout: Edit > Selection > Size Shapes）
 *
 * 输入各边偏移量（nm，正=扩大 负=缩小），确认后由调用方执行。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct SizeOffsetDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  title: string = '尺寸调整';
  hint: string = '';
  fieldLabel: string = '偏移量 (nm)';
  positiveOnly: boolean = false;
  /** 确认回调（offset 单位 nm，正=扩大，负=缩小） */
  onConfirm: (offset: number) => boolean | void = (_offset: number) => {};
  contextProvider: () => string = () => '';
  failureMessageProvider: () => string = () => '';
  private openedContext: string = '';

  @State offsetText: string = '10';
  @State error: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.error = '';
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) { this.error = `版图或选择已变化，请重新打开${this.title}`; return; }
    const v: number = this.offsetText.trim().length > 0 ? Number(this.offsetText) : Number.NaN;
    if (!Number.isFinite(v) || v === 0 || (this.positiveOnly && v < 0)) { this.error = this.positiveOnly ? '请输入完整的正数' : '请输入完整的非零有限数值，负数表示缩小'; return; }
    try {
      if (this.onConfirm(v) === false) {
        const reason: string = this.failureMessageProvider().trim();
        this.error = reason.length > 0 ? reason : `${this.title}未完成，请检查图形类型、选择或锁定图层`;
        return;
      }
    } catch (error) { this.error = `${this.title}未完成：${String(error)}`; return; }
    this.error = '';
    this.controller.close();
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: this.hint.trim().length > 0 ? 6 : 18 })
      if (this.hint.trim().length > 0) {
        Text(this.hint)
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .width('100%')
          .margin({ bottom: 18 })
      }

      Text(this.fieldLabel).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').margin({ bottom: 8 })

      TextInput({ text: this.offsetText, placeholder: this.fieldLabel })
        .type(InputType.Normal)
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .width('100%')
        .height(UI.fieldHeight)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .onChange((value: string) => {
          this.offsetText = value;
          this.error = '';
        })

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
          .onClick(() => {
            this.controller.close();
          })
        Blank().width(12)
        Button('应用', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 24, right: 24 })
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .borderRadius(UI.controlRadius)
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .padding({ top: 16 })
      .border({ width: { top: 1 }, color: COLORS.border })
      .margin({ top: 24 })
    }
    .width(360)
    .constraintSize({ maxWidth: '94%' })
    .padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
