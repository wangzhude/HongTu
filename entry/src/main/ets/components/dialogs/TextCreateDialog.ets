/**
 * 文本标注创建 CustomDialog 弹窗组件
 *
 * Task 2.4: 用 @CustomDialog 替换 LayoutCanvasView 中的内联 TextCreateDialog @Builder。
 * 保持功能等价：文本内容输入、落点位置展示、取消/插入按钮。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct TextCreateDialog {
  /** 由 CustomDialogController 自动注入，调用 close() 关闭弹窗 */
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  /** 落点 X（用户坐标 nm），仅用于展示 */
  insertX: number = 0;
  /** 落点 Y（用户坐标 nm），仅用于展示 */
  insertY: number = 0;
  /** 确认回调（非空文本时调用，并由本组件负责关闭弹窗） */
  onConfirm: (text: string) => boolean | void = (text: string) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';
  private completed: boolean = false;

  @State textValue: string = '';
  @State error: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.completed = false;
    this.error = '';
  }

  private handleConfirm(): boolean {
    if (this.completed) return false;
    if (this.openedContext !== this.contextProvider()) { this.error = '版图或图层已变化，请重新插入文本'; return false; }
    const txt: string = this.textValue.trim();
    if (txt.length === 0) { this.error = '请输入文本内容'; return false; }
    try {
      if (this.onConfirm(txt) === false) { this.error = '文本未插入，请检查编辑模式、图层锁定和状态栏提示'; return false; }
    } catch (error) {
      this.error = `文本未插入：${String(error)}`;
      return false;
    }
    this.completed = true;
    this.error = '';
    this.controller.close();
    return true;
  }

  private handleCancel(): void {
    this.completed = true;
    this.controller.close();
  }

  private handleInputKey(event: KeyEvent): void {
    event.stopPropagation();
    if (event.type === KeyType.Down && canvasKeyName(event.keyCode, event.keyText) === 'ESCAPE') this.handleCancel();
  }

  private handleSubmit(event: SubmitEvent): void {
    this.textValue = event.text;
    if (!this.handleConfirm()) event.keepEditableState();
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Text('插入文本标注')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: 10 })

      Text(`位置: (${this.insertX}, ${this.insertY}) nm`)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.muted)
        .width('100%')
        .margin({ bottom: 24 })

      Text('文本内容').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').margin({ bottom: 8 })

      TextInput({ text: this.textValue, placeholder: '输入文本内容' })
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .width('100%')
        .height(UI.fieldHeight)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .onChange((value: string) => {
          this.textValue = value;
        })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => this.handleSubmit(event))
        .onKeyEvent((event: KeyEvent) => this.handleInputKey(event))

      if (this.error.length > 0) {
        Text(this.error).fontSize(UI.fontCaption).fontColor(COLORS.danger).width('100%').margin({ top: 8 })
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
            this.handleCancel();
          })
        Blank().width(12)
        Button('插入', { type: ButtonType.Normal })
          .enabled(this.textValue.trim().length > 0)
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
