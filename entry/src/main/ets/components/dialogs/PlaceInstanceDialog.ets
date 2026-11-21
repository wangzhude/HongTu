/**
 * 实例放置 CustomDialog 弹窗组件
 *
 * 支持直接单击胶囊选择可放置子 Cell（与下拉菜单双向同步），自动排除自身及循环引用祖先 Cell，
 * 并提供取视口中心 / 归零快捷坐标填入与回车直接放置。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { WorkbenchIcon } from '../workbench/WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { Point } from '../../models/GdsiiData';
import { dialogTransition, feedbackCurve, motionDuration, MOTION } from '../../common/Motion';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

/** Cell 简要信息（用于实例放置选择） */
export interface CellInfo {
  id: number;
  name: string;
}

@CustomDialog
export struct PlaceInstanceDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  /** 可安全放置的 Cell 列表（兼容直接传 @Prop 与动态闭包拉取） */
  @Prop cells: CellInfo[] = [];
  @Prop initialCellId: number = -1;
  @Prop dbuNm: number = 1;
  @Prop isCompact: boolean = false;
  cellsProvider?: () => CellInfo[];
  initialCellIdProvider?: () => number;
  dbuProvider?: () => number;
  viewportCenterProvider: () => Point = () => ({ x: 0, y: 0 });

  onConfirm: (cellId: number, x: number, y: number, rotation: number, mirror: number) => boolean | void =
    (_cellId: number, _x: number, _y: number, _rotation: number, _mirror: number) => {};
  onStartInteractiveStamp: (cellId: number, rotation: number, mirror: number) => boolean | void =
    (_cellId: number, _rotation: number, _mirror: number) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';

  @State availableCells: CellInfo[] = [];
  @State effectiveDbuNm: number = 1;
  @State selectedCellId: number = -1;
  @State selectedCellIndex: number = 0;
  @State posXStr: string = '0';
  @State posYStr: string = '0';
  @State rotation: number = 0;
  @State mirror: number = 0;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.errorMsg = '';
    this.availableCells = this.cellsProvider !== undefined ? this.cellsProvider() : this.cells.slice();
    this.effectiveDbuNm = this.dbuProvider !== undefined ? this.dbuProvider() : this.dbuNm;
    const preferred: number = this.initialCellIdProvider !== undefined ? this.initialCellIdProvider() : this.initialCellId;
    if (preferred >= 0) {
      this.selectedCellId = preferred;
    }
    this.ensureDefaultSelection();
  }

  private ensureDefaultSelection(): void {
    if (this.selectedCellId >= 0) {
      let found: boolean = false;
      for (let i = 0; i < this.availableCells.length; i++) {
        if (this.availableCells[i].id === this.selectedCellId) {
          found = true;
          this.selectedCellIndex = i;
          break;
        }
      }
      if (!found) {
        this.selectedCellId = -1;
        this.selectedCellIndex = 0;
      }
    }
    if (this.availableCells.length > 0 && this.selectedCellId < 0) {
      this.selectedCellIndex = 0;
      this.selectedCellId = this.availableCells[0].id;
    }
  }

  private selectCellByIndex(index: number): void {
    if (index < 0 || index >= this.availableCells.length) return;
    this.selectedCellIndex = index;
    this.selectedCellId = this.availableCells[index].id;
    this.errorMsg = '';
  }

  private fillViewportCenter(): void {
    const center: Point = this.viewportCenterProvider();
    const step: number = Number.isFinite(this.effectiveDbuNm) && this.effectiveDbuNm > 0 ? this.effectiveDbuNm : 1;
    const cx: number = Math.round(center.x / step) * step;
    const cy: number = Math.round(center.y / step) * step;
    this.posXStr = String(Number(cx.toFixed(4)));
    this.posYStr = String(Number(cy.toFixed(4)));
    this.errorMsg = '';
  }

  private cellOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < this.availableCells.length; i++) {
      options.push({ value: this.availableCells[i].name });
    }
    return options;
  }

  private currentCellName(): string {
    if (this.selectedCellIndex >= 0 && this.selectedCellIndex < this.availableCells.length) {
      return this.availableCells[this.selectedCellIndex].name;
    }
    return '请选择 Cell';
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) {
      this.errorMsg = '版图已变化，请重新打开放置实例';
      return;
    }
    if (this.selectedCellId < 0 || !this.availableCells.some((cell: CellInfo) => cell.id === this.selectedCellId)) {
      this.errorMsg = '请先选择一个 Cell';
      return;
    }
    const x: number = this.posXStr.trim().length > 0 ? Number(this.posXStr) : Number.NaN;
    const y: number = this.posYStr.trim().length > 0 ? Number(this.posYStr) : Number.NaN;
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(this.rotation) || [0, 1, 2].indexOf(this.mirror) < 0) {
      this.errorMsg = '坐标输入无效，请输入数字（单位 nm）';
      return;
    }
    try {
      if (this.onConfirm(this.selectedCellId, x, y, this.rotation, this.mirror) === false) {
        this.errorMsg = '实例未放置，请检查编辑模式、锁定状态或循环引用';
        return;
      }
    } catch (error) {
      this.errorMsg = `实例未放置：${String(error)}`;
      return;
    }
    this.errorMsg = '';
    this.controller.close();
  }

  private handleStartInteractiveStamp(): void {
    if (this.openedContext !== this.contextProvider()) {
      this.errorMsg = '版图已变化，请重新打开放置实例';
      return;
    }
    if (this.selectedCellId < 0 || !this.availableCells.some((cell: CellInfo) => cell.id === this.selectedCellId)) {
      this.errorMsg = '请先选择一个要放置的 Cell';
      return;
    }
    if (!Number.isFinite(this.rotation) || [0, 1, 2].indexOf(this.mirror) < 0) {
      this.errorMsg = '旋转或镜像参数无效';
      return;
    }
    try {
      if (this.onStartInteractiveStamp(this.selectedCellId, this.rotation, this.mirror) === false) {
        this.errorMsg = '该 Cell 不能放入当前上下文（可能引起层级循环引用或只读锁定）';
        return;
      }
    } catch (error) {
      this.errorMsg = `无法启动画布点放：${String(error)}`;
      return;
    }
    this.errorMsg = '';
    this.controller.close();
  }

  private handleCancel(): void {
    this.errorMsg = '';
    this.controller.close();
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column() {
      Row() {
        Text('放置实例')
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
          .focusable(false)
          .accessibilityText('关闭实例放置')
          .onClick(() => {
            this.handleCancel();
          })
      }
      .width('100%')
      .height(58)
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding })
      .border({ width: { bottom: 0.75 }, color: COLORS.border })

      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 8 }) {
            Text('目标 Cell')
              .fontSize(UI.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .width('100%')

            if (this.availableCells.length > 0 && this.availableCells.length <= 16) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.availableCells, (cell: CellInfo, idx: number) => {
                  Button(cell.name, { type: ButtonType.Normal })
                    .height(UI.compactControlHeight)
                    .fontSize(UI.fontBody)
                    .fontColor(cell.id === this.selectedCellId ? COLORS.primary : COLORS.ink)
                    .padding({ left: 12, right: 12 })
                    .margin({ right: 8, bottom: 8 })
                    .borderRadius(UI.controlRadius)
                    .border({ width: 1, color: cell.id === this.selectedCellId ? COLORS.primary : COLORS.border })
                    .animation(null)
                    .backgroundColor(cell.id === this.selectedCellId ? COLORS.primarySoft : COLORS.surfaceMuted)
                    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
                    .focusable(false)
                    .onClick(() => {
                      this.selectCellByIndex(idx);
                    })
                }, (cell: CellInfo) => `${cell.id}:${cell.name}`)
              }
              .width('100%')
            }

            if (this.availableCells.length > 6 || this.availableCells.length === 0) {
              Select(this.cellOptions())
                .selected(this.selectedCellIndex)
                .value(this.currentCellName())
                .width('100%')
                .height(UI.fieldHeight)
                .font({ size: UI.fontBody })
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .focusable(false)
                .onSelect((index: number) => {
                  this.selectCellByIndex(index);
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Row({ space: 8 }) {
            Text('位置坐标 (nm)')
              .fontSize(UI.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            Button('取视口中心', { type: ButtonType.Normal })
              .height(26)
              .padding({ left: 10, right: 10 })
              .fontSize(UI.fontCaption)
              .fontColor(COLORS.primary)
              .backgroundColor(COLORS.primarySoft)
              .border({ width: 1, color: COLORS.primary })
              .borderRadius(UI.controlRadius)
              .focusable(false)
              .onClick(() => this.fillViewportCenter())
            Button('归零 (0,0)', { type: ButtonType.Normal })
              .height(26)
              .padding({ left: 10, right: 10 })
              .fontSize(UI.fontCaption)
              .fontColor(COLORS.muted)
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border })
              .borderRadius(UI.controlRadius)
              .focusable(false)
              .onClick(() => {
                this.posXStr = '0';
                this.posYStr = '0';
                this.errorMsg = '';
              })
          }
          .width('100%')
          .padding({ top: 8 })
          .border({ width: { top: 1 }, color: COLORS.border })
          .alignItems(VerticalAlign.Center)

          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('X')
                .fontSize(UI.fontCaption)
                .fontColor(COLORS.muted)
                .width('100%')
              TextInput({ text: this.posXStr, placeholder: 'X (nm)' })
                .type(InputType.Normal)
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .onSubmit(() => { this.handleConfirm(); })
                .width('100%')
                .height(UI.fieldHeight)
                .fontSize(UI.fontBody)
                .fontColor(COLORS.ink)
                .placeholderColor(COLORS.muted)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onChange((value: string) => {
                  this.posXStr = value;
                  this.errorMsg = '';
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Column({ space: 6 }) {
              Text('Y')
                .fontSize(UI.fontCaption)
                .fontColor(COLORS.muted)
                .width('100%')
              TextInput({ text: this.posYStr, placeholder: 'Y (nm)' })
                .type(InputType.Normal)
                .onFocus(() => { resetModifierKeys(); })
                .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .onSubmit(() => { this.handleConfirm(); })
                .width('100%')
                .height(UI.fieldHeight)
                .fontSize(UI.fontBody)
                .fontColor(COLORS.ink)
                .placeholderColor(COLORS.muted)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onChange((value: string) => {
                  this.posYStr = value;
                  this.errorMsg = '';
                })
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Column({ space: 8 }) {
            Text('旋转角度')
              .fontSize(UI.fontBody)
              .fontColor(COLORS.ink)
              .width('100%')
            StableSegmentButton({
              items: [
                { text: '0°' },
                { text: '90°' },
                { text: '180°' },
                { text: '270°' }
              ] as [
                SegmentButtonTextItem,
                SegmentButtonTextItem,
                SegmentButtonTextItem,
                SegmentButtonTextItem
              ] as SegmentButtonItemTuple,
              selectedIndex: [0, 90, 180, 270].indexOf(this.rotation) >= 0 ? [0, 90, 180, 270].indexOf(this.rotation) : 0,
              onItemClicked: (idx: number) => {
                const angles: number[] = [0, 90, 180, 270];
                if (idx >= 0 && idx < angles.length) {
                  this.rotation = angles[idx];
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: UI.fontBody,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: UI.controlHeight,
              itemMinHeight: UI.controlHeight - 6
            })
          }
          .width('100%')

          Column({ space: 8 }) {
            Text('镜像')
              .fontSize(UI.fontBody)
              .fontColor(COLORS.ink)
              .width('100%')
            StableSegmentButton({
              items: [
                { text: '无' },
                { text: 'X' },
                { text: 'Y' }
              ] as [
                SegmentButtonTextItem,
                SegmentButtonTextItem,
                SegmentButtonTextItem
              ] as SegmentButtonItemTuple,
              selectedIndex: [0, 1, 2].indexOf(this.mirror) >= 0 ? this.mirror : 0,
              onItemClicked: (idx: number) => {
                if (idx === 0 || idx === 1 || idx === 2) {
                  this.mirror = idx;
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: UI.fontBody,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: UI.controlHeight,
              itemMinHeight: UI.controlHeight - 6
            })
          }
          .width('100%')

          if (this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(UI.fontCaption)
              .fontColor(COLORS.danger)
              .width('100%')
          }
        }
        .width('100%')
        .padding(UI.dialogPadding)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 520 })
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      Row({ space: 10 }) {
        Blank()
        Button('坐标放置', { type: ButtonType.Normal })
          .backgroundColor(COLORS.surfaceMuted)
          .fontColor(COLORS.primary)
          .fontSize(UI.fontBody)
          .height(UI.controlHeight)
          .padding({ left: 16, right: 16 })
          .border({ width: 1, color: COLORS.primary })
          .borderRadius(UI.controlRadius)
          .enabled(this.availableCells.length > 0)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleConfirm();
          })
        Button('画布磁吸点放', { type: ButtonType.Normal })
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .height(UI.controlHeight)
          .padding({ left: 18, right: 18 })
          .borderRadius(UI.controlRadius)
          .enabled(this.availableCells.length > 0)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleStartInteractiveStamp();
          })
      }
      .width('100%')
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding, top: 14, bottom: UI.dialogPadding })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(this.isCompact ? 336 : 480)
    .constraintSize({ maxWidth: '94%', maxHeight: '88%' })
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
