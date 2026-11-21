/**
 * 移动微调 CustomDialog 弹窗组件
 *
 * Task 2.3: 用 @CustomDialog 替换 LayoutCanvasView 中的内联 MoveFineTuneDialog @Builder。
 * 保持功能等价：dx/dy 数字输入、无效输入/未选中图形时显示错误提示且不关闭、取消/确认按钮。
 *
 * Move 工具长按精确调整：解决 KLayout 纯拖拽难以精确到 nm 的痛点。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct MoveFineTuneDialog {
  /** 由 CustomDialogController 自动注入，调用 close() 关闭弹窗 */
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  /** 初始 dx（nm），由父组件在打开前传入（拖拽位移量） */
  dxStr: string = '0';
  /** 初始 dy（nm），由父组件在打开前传入（拖拽位移量） */
  dyStr: string = '0';
  /** 是否存在待移动的选中图形（无则确认时提示错误） */
  hasSelection: boolean = false;
  /** 确认回调（校验通过后调用，并由本组件负责关闭弹窗） */
  onConfirm: (dx: number, dy: number) => boolean | void = (dx: number, dy: number) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';

  @State dxValue: string = '0';
  @State dyValue: string = '0';
  @State error: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    // 以父组件传入的初始值初始化可编辑工作副本
    this.dxValue = this.dxStr;
    this.dyValue = this.dyStr;
    this.error = '';
    this.openedContext = this.contextProvider();
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) {
      this.error = '版图或选择已变化，请重新长按打开微调';
      return;
    }
    const dx: number = this.dxValue.trim().length > 0 ? Number(this.dxValue) : Number.NaN;
    const dy: number = this.dyValue.trim().length > 0 ? Number(this.dyValue) : Number.NaN;
    // CANVAS-11: 无效输入时不关闭弹框，显示错误提示
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) {
      this.error = '请输入有效的数字';
      return;
    }
    if (!this.hasSelection) {
      this.error = '未选中任何图形';
      return;
    }
    this.error = '';
    try {
      if (this.onConfirm(dx, dy) === false) {
        this.error = '图形未移动，请检查选区、图层锁定和版图状态';
        return;
      }
    } catch (error) { this.error = `位移未应用：${String(error)}`; return; }
    this.controller.close();
  }

  private handleCancel(): void {
    this.error = '';
    this.controller.close();
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Text('微调位移')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: 24 })

      // dx 输入
      Column({ space: 8 }) {
        Text('X 位移 (nm)')
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .width('100%')
        TextInput({ text: this.dxValue })
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
            this.dxValue = value;
          })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      // dy 输入
      Column({ space: 8 }) {
        Text('Y 位移 (nm)')
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .width('100%')
        TextInput({ text: this.dyValue })
          .type(InputType.Normal)
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
            this.dyValue = value;
          })
      }
      .width('100%')
      .margin({ top: 16 })
      .alignItems(HorizontalAlign.Start)

      // CANVAS-11: 无效输入时显示错误提示
      if (this.error.length > 0) {
        Text(this.error)
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.danger)
          .margin({ top: 10 })
      }

      Row() {
        Button('取消', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .layoutWeight(1)
          .padding({ left: 24, right: 24 })
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.ink)
          .fontSize(UI.fontBody)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onClick(() => {
            this.handleCancel();
          })
        Blank().width(12)
        Button('确认', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .layoutWeight(1)
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
