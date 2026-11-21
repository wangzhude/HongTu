import { hongTuThemeState, Radius } from '../../store/ThemeStore';
/**
 * 视图预设保存 CustomDialog 弹窗组件
 *
 * Task 2.5: 用 @CustomDialog 替换 WorkbenchSidebar 中的内联预设保存弹窗。
 * 保持功能等价：预设名称输入、空名校验、确认回调。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS } from '../../common/constants';
import { WorkbenchIcon } from '../workbench/WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct PresetSaveDialog {
  /** 由 CustomDialogController 自动注入，调用 close() 关闭弹窗 */
  controller: CustomDialogController;
  private modalGateToken: number = 0;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
  }
  /** Only a successful verified save closes this dialog. */
  onConfirm: (name: string) => boolean = (_name: string) => false;
  errorProvider: () => string = () => '';

  @State nameValue: string = '';
  @State error: string = '';

  private handleConfirm(): void {
    const name: string = this.nameValue.trim();
    if (name.length === 0) {
      this.error = '预设名称不能为空';
      return;
    }
    this.error = '';
    try {
      if (this.onConfirm(name) !== true) {
        this.error = this.errorProvider() || '预设未保存，请检查存储后重试';
        return;
      }
      this.controller.close();
    } catch (failure) { this.error = `预设未保存：${String(failure)}`; }
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
      // 标题栏（单一右上角关闭入口）
      Row() {
        Text('保存视图预设')
          .fontSize(UI.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
        Blank()
        Button({ type: ButtonType.Circle }) {
          WorkbenchIcon({ name: 'close', iconSize: 15, color: COLORS.ink })
        }
          .width(34)
          .height(34)
          .padding(0)
          .borderRadius(Radius.pill)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .accessibilityText('关闭保存预设')
          .onClick(() => {
            this.handleCancel();
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding })
      .border({ width: { bottom: 0.75 }, color: COLORS.border })

      // 内容区
      Column() {
        Text('预设名称')
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .width('100%')
        TextInput({ text: this.nameValue, placeholder: '输入预设名称' })
          .defaultFocus(true)
          .onFocus(() => { resetModifierKeys(); })
          .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
          .onSubmit(() => { this.handleConfirm(); })
          .width('100%')
          .height(UI.fieldHeight)
          .margin({ top: 8 })
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .placeholderColor(COLORS.muted)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onChange((value: string) => {
            this.nameValue = value;
            this.error = '';
          })

        if (this.error.length > 0) {
          Text(this.error)
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.danger)
            .width('100%')
            .margin({ top: 10 })
        }
      }
      .width('100%')
      .padding(UI.dialogPadding)
      .alignItems(HorizontalAlign.Start)

      // 单一保存入口
      Row() {
        Button('确认保存', { type: ButtonType.Normal })
          .width('100%')
          .enabled(this.nameValue.trim().length > 0)
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .height(UI.controlHeight)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding, top: 16, bottom: UI.dialogPadding })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(360)
    .constraintSize({ maxWidth: '94%' })
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
