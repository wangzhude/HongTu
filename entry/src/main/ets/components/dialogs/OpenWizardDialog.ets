/**
 * 大版图打开向导 CustomDialog 弹窗组件
 *
 * Task 2.2: 用 @CustomDialog 替换 Index.ets 中的内联 OpenWizardDialog @Builder。
 * 保持功能等价：文件名/大小展示、超大文件警告、查看/编辑模式二选一、确认回调。
 *
 * 两种模式使用同一解析器，差异为编辑权限；AREF 保留压缩引用。
 * 资源估算区分存储和层级展开预算，不承诺按需读取或峰值内存。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { COLORS, formatFileSize, HUGE_FILE_THRESHOLD_BYTES } from '../../common/constants';
import { ViewMode } from '../../common/types';
import { withAlpha } from '../../common/MaterialTokens';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

interface OpenWizardMetricParams {
  label: string;
  value: number;
}

@CustomDialog
export struct OpenWizardDialog {
  /** 由 CustomDialogController 自动注入，调用 close() 关闭弹窗 */
  controller: CustomDialogController;
  private modalGateToken: number = 0;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
  }
  /** 待打开的文件名（由父组件 Index 在打开前传入） */
  @Prop fileName: string = '';
  /** 待打开的文件大小（字节，由父组件 Index 在打开前传入） */
  @Prop fileSize: number = 0;
  @Prop storedShapes: number = -1;
  @Prop coordinateCount: number = -1;
  @Prop expandedPlacements: number = -1;
  @Prop geometryBytes: number = -1;
  @Prop budgetMessage: string = '';
  /** 紧凑模式（sm 手机端）：弹窗宽度收窄，适配窄屏 */
  @Prop isCompact: boolean = false;
  /** 确认回调：用户选择查看/编辑模式后调用，并由本组件负责关闭弹窗 */
  onSelect: (mode: ViewMode) => void = (mode: ViewMode) => {};

  private handleSelect(mode: ViewMode): void {
    this.onSelect(mode);
    this.controller.close();
  }

  @Builder
  buildMetric(params: OpenWizardMetricParams) {
    Column({ space: 8 }) {
      Text(params.label).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').maxLines(2)
      Text(params.value >= 0 ? params.value.toString() : '未估算').fontSize(UI.titleSize).fontWeight(FontWeight.Medium)
        .fontFamily('monospace').fontColor(COLORS.ink).width('100%')
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column({ space: 16 }) {
      Text('大版图打开向导').fontSize(UI.titleSize).fontWeight(FontWeight.Medium)
        .fontColor(COLORS.ink).width('100%').margin({ bottom: 8 })

      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('文件：').fontSize(UI.fontBody).fontColor(COLORS.muted)
          Text(this.fileName).fontSize(UI.fontBody).fontColor(COLORS.ink)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        }.width('100%')
        Row({ space: 8 }) {
          Text('大小：').fontSize(UI.fontBody).fontColor(COLORS.muted)
          Text(formatFileSize(this.fileSize)).fontSize(UI.fontBody).fontColor(COLORS.ink)
          Blank()
          if (this.fileSize >= HUGE_FILE_THRESHOLD_BYTES) {
            Text('超大文件（≥200MB）').fontSize(UI.fontCaption).fontColor(COLORS.warning)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(withAlpha(COLORS.warning, 0.1)).borderRadius(UI.chipRadius)
          }
        }.width('100%')
      }.width('100%').padding(16).backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .alignItems(HorizontalAlign.Start)

      if (this.storedShapes >= 0) {
        Column({ space: 10 }) {
          Text('数据规模').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
          Row({ space: 12 }) {
            this.buildMetric({ label: '存储图形', value: this.storedShapes })
            Row().width(1).height(44).backgroundColor(COLORS.border)
            this.buildMetric({ label: '坐标数', value: this.coordinateCount })
            Row().width(1).height(44).backgroundColor(COLORS.border)
            this.buildMetric({ label: '最大层级实例', value: this.expandedPlacements })
          }.width('100%').padding(16).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        }.width('100%')
      }
      if (this.geometryBytes >= 0) {
        Text(`几何载荷：约 ${formatFileSize(this.geometryBytes)}`)
          .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      }
      if (this.budgetMessage.length > 0) {
        Text(this.budgetMessage).fontSize(UI.fontCaption).fontColor(COLORS.warning).width('100%')
      }

      Row() {
        Button('编辑模式', { type: ButtonType.Normal }).height(UI.controlHeight).layoutWeight(1)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).fontSize(UI.fontBody)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .onClick(() => { this.handleSelect(ViewMode.EDIT); })
        Blank().width(12)
        Button('查看模式（推荐）', { type: ButtonType.Normal }).defaultFocus(true).height(UI.controlHeight).layoutWeight(1)
          .backgroundColor(COLORS.primary).fontColor(Color.White).fontSize(UI.fontBody).borderRadius(UI.controlRadius)
          .onClick(() => { this.handleSelect(ViewMode.VIEWER); })
      }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(this.isCompact ? '88%' : 520).constraintSize({ maxWidth: '94%' }).padding(UI.dialogPadding)
      .alignItems(HorizontalAlign.Start).backgroundColor(COLORS.surface)
      .borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
