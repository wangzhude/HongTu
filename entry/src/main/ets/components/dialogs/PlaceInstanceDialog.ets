/**
 * 实例与阵列放置 CustomDialog 弹窗组件（对齐 KLayout Instance SREF / AREF 完整工作流）
 *
 * 1. 支持直接单击胶囊选择可放置子 Cell，自动排除自身及循环引用祖先 Cell；
 * 2. 原生支持「单个实例 (SREF)」与「行列阵列 (AREF：列数 Cols × 行数 Rows + 列步进 Pitch X / 行步进 Pitch Y)」；
 * 3. 支持一键读取目标子 Cell 包围盒尺寸并自动加上设定的间距（如 +100nm 间隙）填充阵列步进 Pitch！
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { hongTuThemeState, Radius } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
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
  cellSpanProvider?: (cellId: number) => Point | null;
  viewportCenterProvider: () => Point = () => ({ x: 0, y: 0 });

  onConfirm: (cellId: number, x: number, y: number, rotation: number, mirror: number,
    arrayCols?: number, arrayRows?: number, pitchX?: number, pitchY?: number) => boolean | void =
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
  /** false=单个实例 (SREF), true=行列阵列 (AREF) */
  @State useArrayMode: boolean = false;
  @State colsStr: string = '5';
  @State rowsStr: string = '5';
  @State pitchXStr: string = '1000';
  @State pitchYStr: string = '1000';
  @State autoGapStr: string = '100';
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
    this.tryAutoFillPitchFromCell(false);
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

  private tryAutoFillPitchFromCell(reportIfEmpty: boolean): void {
    if (this.cellSpanProvider === undefined || this.selectedCellId < 0) return;
    const span: Point | null = this.cellSpanProvider(this.selectedCellId);
    if (span === null || span.x <= 0 || span.y <= 0) {
      if (reportIfEmpty) {
        this.errorMsg = '所选子 Cell 当前尚无几何图形，请先进入该子 Cell 绘制结构或手动输入步进间距';
      }
      return;
    }
    const gap: number = Number(this.autoGapStr.trim());
    const safeGap: number = Number.isFinite(gap) ? gap : 0;
    this.pitchXStr = String(Math.round(span.x + safeGap));
    this.pitchYStr = String(Math.round(span.y + safeGap));
    this.errorMsg = '';
  }

  private selectCellByIndex(index: number): void {
    if (index < 0 || index >= this.availableCells.length) return;
    this.selectedCellIndex = index;
    this.selectedCellId = this.availableCells[index].id;
    this.errorMsg = '';
    this.tryAutoFillPitchFromCell(false);
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
    return '请选择子 Cell';
  }

  private totalArrayUnitsText(): string {
    const c: number = Math.max(1, Math.floor(Number(this.colsStr) || 1));
    const r: number = Math.max(1, Math.floor(Number(this.rowsStr) || 1));
    return `共 ${c} × ${r} = ${c * r} 个单元 (GDSII AREF)`;
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) {
      this.errorMsg = '版图已变化，请重新打开放置实例';
      return;
    }
    if (this.selectedCellId < 0 || !this.availableCells.some((cell: CellInfo) => cell.id === this.selectedCellId)) {
      this.errorMsg = '请先选择一个要引用的子 Cell';
      return;
    }
    const x: number = this.posXStr.trim().length > 0 ? Number(this.posXStr) : Number.NaN;
    const y: number = this.posYStr.trim().length > 0 ? Number(this.posYStr) : Number.NaN;
    if (!Number.isFinite(x) || !Number.isFinite(y) || !Number.isFinite(this.rotation) || [0, 1, 2].indexOf(this.mirror) < 0) {
      this.errorMsg = '坐标输入无效，请输入数字（单位 nm）';
      return;
    }
    let cols: number = 1;
    let rows: number = 1;
    let pitchX: number = 0;
    let pitchY: number = 0;
    if (this.useArrayMode) {
      cols = Number(this.colsStr.trim());
      rows = Number(this.rowsStr.trim());
      pitchX = Number(this.pitchXStr.trim());
      pitchY = Number(this.pitchYStr.trim());
      if (!Number.isInteger(cols) || cols < 1 || cols > 32767 ||
        !Number.isInteger(rows) || rows < 1 || rows > 32767) {
        this.errorMsg = '阵列列数与行数须为 1~32767 的整数';
        return;
      }
      if (!Number.isFinite(pitchX) || !Number.isFinite(pitchY)) {
        this.errorMsg = '阵列步进间距 Pitch X / Y 须为有效数字（nm）';
        return;
      }
      if ((cols > 1 && Math.abs(pitchX) < 1e-6) || (rows > 1 && Math.abs(pitchY) < 1e-6)) {
        this.errorMsg = '多列或多行阵列对应的步进间距不能为 0，否则所有单元将完全重叠';
        return;
      }
    }
    try {
      if (this.onConfirm(this.selectedCellId, x, y, this.rotation, this.mirror, cols, rows, pitchX, pitchY) === false) {
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
        Text('引用子单元 / 行列阵列')
          .fontSize(UI.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
        Blank()
        Button({ type: ButtonType.Circle }) {
          WorkbenchIcon({ name: 'close', iconSize: 15, color: COLORS.ink })
        }
          .width(32)
          .height(32)
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
      .height(52)
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding })
      .border({ width: { bottom: 0.75 }, color: COLORS.border })

      Scroll() {
        Column({ space: 10 }) {
          Column({ space: 6 }) {
            Text('选择要引用的子 Cell')
              .fontSize(UI.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .width('100%')

            if (this.availableCells.length === 0) {
              Text('当前没有可引用的子 Cell（不能引用自身或祖先 Cell）。请先在左侧「单元 Cells」点击「+ 新建」画好单元结构，回到顶层后再点击引用。')
                .fontSize(11.5)
                .fontColor(COLORS.muted)
                .padding(10)
                .backgroundColor(COLORS.surfaceMuted)
                .borderRadius(UI.controlRadius)
                .width('100%')
            }

            if (this.availableCells.length > 0 && this.availableCells.length <= 16) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.availableCells, (cell: CellInfo, idx: number) => {
                  Button(cell.name, { type: ButtonType.Normal })
                    .height(UI.compactControlHeight)
                    .fontSize(UI.fontBody)
                    .fontColor(cell.id === this.selectedCellId ? COLORS.primary : COLORS.ink)
                    .padding({ left: 12, right: 12 })
                    .margin({ right: 8, bottom: 6 })
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

            if (this.availableCells.length > 6) {
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

          // 单个实例 vs 行列阵列 (AREF) 切换
          Column({ space: 8 }) {
            Text('放置形式')
              .fontSize(UI.fontBody)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .width('100%')
            StableSegmentButton({
              items: [
                { text: '单个实例 (SREF)' },
                { text: '行列阵列 (AREF)' }
              ] as [SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
              selectedIndex: this.useArrayMode ? 1 : 0,
              onItemClicked: (idx: number) => {
                this.useArrayMode = idx === 1;
                if (this.useArrayMode) {
                  this.tryAutoFillPitchFromCell(false);
                }
              },
              fontColor: COLORS.muted,
              selectedFontColor: COLORS.primary,
              capsuleBackgroundColor: COLORS.surfaceMuted,
              selectedBackgroundColor: COLORS.primarySoft,
              fontSizeFp: UI.fontBody,
              capsuleBorderRadius: UI.controlRadius,
              buttonMinHeight: 36,
              itemMinHeight: 30
            })

            if (this.useArrayMode) {
              Column({ space: 8 }) {
                Row({ space: 8 }) {
                  Text(this.totalArrayUnitsText())
                    .fontSize(11.5)
                    .fontFamily(FONT_MONO)
                    .fontColor(COLORS.primary)
                    .layoutWeight(1)
                }.width('100%')

                Row({ space: 10 }) {
                  Column({ space: 4 }) {
                    Text('列数 (Cols)').fontSize(11).fontColor(COLORS.muted)
                    TextInput({ text: this.colsStr, placeholder: '列数' })
                      .type(InputType.Number)
                      .onFocus(() => resetModifierKeys())
                      .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                      .height(34).fontSize(UI.fontBody).fontColor(COLORS.ink)
                      .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                      .onChange((v: string) => { this.colsStr = v; this.errorMsg = ''; })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                  Column({ space: 4 }) {
                    Text('行数 (Rows)').fontSize(11).fontColor(COLORS.muted)
                    TextInput({ text: this.rowsStr, placeholder: '行数' })
                      .type(InputType.Number)
                      .onFocus(() => resetModifierKeys())
                      .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                      .height(34).fontSize(UI.fontBody).fontColor(COLORS.ink)
                      .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                      .onChange((v: string) => { this.rowsStr = v; this.errorMsg = ''; })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')

                Row({ space: 10 }) {
                  Column({ space: 4 }) {
                    Text('列步进 Pitch X (nm)').fontSize(11).fontColor(COLORS.muted)
                    TextInput({ text: this.pitchXStr, placeholder: '中心距 X (nm)' })
                      .type(InputType.Normal)
                      .onFocus(() => resetModifierKeys())
                      .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                      .height(34).fontSize(UI.fontBody).fontColor(COLORS.ink)
                      .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                      .onChange((v: string) => { this.pitchXStr = v; this.errorMsg = ''; })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)

                  Column({ space: 4 }) {
                    Text('行步进 Pitch Y (nm)').fontSize(11).fontColor(COLORS.muted)
                    TextInput({ text: this.pitchYStr, placeholder: '中心距 Y (nm)' })
                      .type(InputType.Normal)
                      .onFocus(() => resetModifierKeys())
                      .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                      .height(34).fontSize(UI.fontBody).fontColor(COLORS.ink)
                      .backgroundColor(COLORS.surface).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                      .onChange((v: string) => { this.pitchYStr = v; this.errorMsg = ''; })
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                }.width('100%')

                Row({ space: 6 }) {
                  Text('单元净间距 (nm):').fontSize(11).fontColor(COLORS.muted)
                  TextInput({ text: this.autoGapStr })
                    .width(68).height(28).fontSize(11.5).padding({ left: 6, right: 6 })
                    .onFocus(() => resetModifierKeys())
                    .onKeyEvent((e: KeyEvent) => e.stopPropagation())
                    .backgroundColor(COLORS.surface).fontColor(COLORS.ink)
                    .border({ width: 1, color: COLORS.border }).borderRadius(6)
                    .onChange((v: string) => { this.autoGapStr = v; })
                  Button('按单元尺寸自动算步进', { type: ButtonType.Normal })
                    .height(28).fontSize(11).padding({ left: 10, right: 10 })
                    .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
                    .border({ width: 1, color: COLORS.primary }).borderRadius(6).focusable(false)
                    .onClick(() => this.tryAutoFillPitchFromCell(true))
                }.width('100%').alignItems(VerticalAlign.Center)
              }
              .width('100%')
              .padding(10)
              .backgroundColor(COLORS.surfaceMuted)
              .borderRadius(UI.controlRadius)
            }
          }
          .width('100%')

          Row({ space: 8 }) {
            Text(this.useArrayMode ? '阵列起点坐标 (nm)' : '放置锚点坐标 (nm)')
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
            Column({ space: 4 }) {
              Text('起点 X (nm)').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
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
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)

            Column({ space: 4 }) {
              Text('起点 Y (nm)').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
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
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }
          .width('100%')

          Row({ space: 10 }) {
            Column({ space: 6 }) {
              Text('旋转角度').fontSize(12).fontColor(COLORS.ink).width('100%')
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
                fontSizeFp: 11,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 34,
                itemMinHeight: 28
              })
            }.layoutWeight(3)

            Column({ space: 6 }) {
              Text('镜像').fontSize(12).fontColor(COLORS.ink).width('100%')
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
                fontSizeFp: 11,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 34,
                itemMinHeight: 28
              })
            }.layoutWeight(2)
          }.width('100%')

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
      .constraintSize({ maxHeight: 500 })
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      Row({ space: 10 }) {
        Blank()
        if (!this.useArrayMode) {
          Button('画布磁吸点放', { type: ButtonType.Normal })
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
              this.handleStartInteractiveStamp();
            })
        }
        Button(this.useArrayMode ? '生成行列阵列' : '按坐标放置', { type: ButtonType.Normal })
          .backgroundColor(COLORS.primary)
          .fontColor(Color.White)
          .fontSize(UI.fontBody)
          .height(UI.controlHeight)
          .padding({ left: 18, right: 18 })
          .borderRadius(UI.controlRadius)
          .enabled(this.availableCells.length > 0)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.handleConfirm();
          })
      }
      .width('100%')
      .padding({ left: UI.dialogPadding, right: UI.dialogPadding, top: 12, bottom: UI.dialogPadding })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(this.isCompact ? 344 : 500)
    .constraintSize({ maxWidth: '94%', maxHeight: '90%' })
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
    .transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
