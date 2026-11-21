/**
 * Cell 名称输入弹窗（新建 / 重命名共用）
 *
 * 对齐 KLayout Cells Tab 的 New Cell / Rename Cell 操作。
 * 名称唯一性由调用方校验，本组件只保证非空。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { canvasKeyName } from '../../common/CanvasKeyboard';

@CustomDialog
export struct CellNameDialog {
  /** 由 CustomDialogController 自动注入 */
  controller: CustomDialogController;
  /** 弹窗标题（如「新建 Cell」/「重命名 Cell」） */
  title: string = '新建 Cell';
  /** 初始名称（重命名时为原名） */
  initialName: string = '';
  /** 确认回调（非空名称时调用） */
  onConfirm: (name: string) => boolean | void = (_name: string) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';
  private completed: boolean = false;

  @State nameValue: string = '';
  @State error: string = '';

  aboutToAppear(): void {
    this.nameValue = this.initialName;
    this.openedContext = this.contextProvider();
    this.completed = false;
    this.error = '';
  }

  private handleConfirm(): boolean {
    if (this.completed) return false;
    if (this.openedContext !== this.contextProvider()) { this.error = '版图或操作目标已变化，请重新打开 Cell 命名'; return false; }
    const name: string = this.nameValue.trim();
    if (name.length === 0) { this.error = '请输入 Cell 名称'; return false; }
    try {
      if (this.onConfirm(name) === false) { this.error = '名称未保存，请检查重名、编辑模式或状态栏提示'; return false; }
    } catch (error) {
      this.error = `名称未保存：${String(error)}`; return false;
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
    this.nameValue = event.text;
    if (!this.handleConfirm()) event.keepEditableState();
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: 24 })

      Text('Cell 名称').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').margin({ bottom: 8 })

      TextInput({ text: this.nameValue, placeholder: '输入 Cell 名称' })
        .width('100%')
        .height(UI.fieldHeight)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .onChange((value: string) => {
          this.nameValue = value;
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
        Button('确定', { type: ButtonType.Normal })
          .enabled(this.nameValue.trim().length > 0)
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
  }
}
