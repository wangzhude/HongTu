/**
 * Profile 导入 CustomDialog 弹窗组件
 *
 * Task 2.6: 用 @CustomDialog 替换 WorkbenchOverlays 中 ShortcutPanel 的内联 Profile 导入弹窗。
 * 保持功能等价：JSON 文本输入、空内容校验、调用 shortcutService.importProfile、错误内联展示。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { hongTuThemeState } from '../../store/ThemeStore';
import { pasteboard } from '@kit.BasicServicesKit';
import { COLORS } from '../../common/constants';
import { shortcutService } from '../../services/ShortcutService';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct ProfileImportDialog {
  /** 由 CustomDialogController 自动注入，调用 close() 关闭弹窗 */
  controller: CustomDialogController;
  private modalGateToken: number = 0;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
  }
  /** 导入成功回调（由父组件刷新列表 / 显示状态文本） */
  onSuccess: () => void = () => {};

  @State importJson: string = '';
  @State importError: string = '';

  private handleConfirm(): void {
    const trimmed: string = this.importJson.trim();
    // 空内容校验：与原内联弹窗行为一致，直接交由 service 返回错误信息
    const result = shortcutService.importProfile(trimmed);
    if (result.ok) {
      this.onSuccess();
      this.controller.close();
    } else {
      this.importError = result.error ?? '导入失败';
    }
  }

  private handleCancel(): void {
    this.controller.close();
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Text('粘贴 Profile JSON')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink)
        .width('100%')
        .margin({ bottom: 24 })

      Row({ space: 8 }) {
        Text('Profile JSON').fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
        // 严守官方规范：PasteButton 不挂载通用属性修饰器，保持高对比实色背景与字色
        Row() {
          PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
            .fontSize(12)
            .fontColor(Color.White)
            .iconColor(Color.White)
            .backgroundColor(COLORS.primary)
            .padding({ top: 7, bottom: 7, left: 12, right: 12 })
            .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                pasteboard.getSystemPasteboard().getData().then((data) => {
                  const pasted: string = data.getPrimaryText() ?? '';
                  if (pasted.trim().length > 0) {
                    this.importJson = pasted;
                    this.importError = '';
                  } else {
                    this.importError = '剪贴板中暂无 JSON 文本';
                  }
                }).catch(() => {
                  this.importError = '剪贴板读取未完成，请手动长按粘贴';
                });
              }
            })
        }
      }.width('100%').alignItems(VerticalAlign.Center).margin({ bottom: 8 })

      TextArea({ text: this.importJson, placeholder: '{ "switch_tool|0": "XZ", ... }' })
        .defaultFocus(true)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .width('100%')
        .height(220)
        .fontSize(UI.fontBody)
        .fontFamily('monospace')
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .onChange((value: string) => {
          this.importJson = value;
        })

      if (this.importError.length > 0) {
        Text(this.importError)
          .fontSize(UI.fontBody)
          .fontColor(COLORS.danger)
          .width('100%')
          .margin({ top: 6 })
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
            this.handleCancel();
          })
        Blank().width(12)
        Button('确认导入', { type: ButtonType.Normal })
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
    .width(440)
    .constraintSize({ maxWidth: '94%' })
    .padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
