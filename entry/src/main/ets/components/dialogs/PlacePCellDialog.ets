/**
 * PCell 放置弹窗（KLayout: Instance > PCell）
 *
 * 从 native listPCells 拉取内置参数化单元清单，按参数声明动态生成表单
 * （int/double → 数字输入，boolean → 开关，string → 文本），
 * 确认后回调（名称 + 参数 + 放置坐标）。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { hongTuThemeState } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { PanelHeading } from '../workbench/PanelHeading';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { Point } from '../../models/GdsiiData';
import { dialogTransition, feedbackCurve, motionDuration, MOTION } from '../../common/Motion';
import { nativeHongTuService } from '../../services/NativeHongTuService';
import type { PCellInfo, PCellParamInfo } from '../../../cpp/types/libhongtu/Index';
import { PCellPlacementOptions, isCurvePCell, curveApproximation } from '../../services/CurveDrawingService';
import { quantizationText } from '../../services/PrecisionService';
import { technologyService } from '../../services/TechnologyService';
import type { TechnologyDevice } from '../../common/technologyPackage';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

@CustomDialog
export struct PlacePCellDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  @Prop initialPCellName: string = '';
  @Prop initialLayerNumber: number = 1;
  @Prop initialDatatype: number = 0;
  @Prop initialOutputMode: string = 'instance';
  @Prop dbuNm: number = 1;
  viewportCenterProvider: () => Point = () => ({ x: 0, y: 0 });
  /** 确认回调 */
  onConfirm: (pcellName: string, params: Record<string, number | string | boolean>,
              x: number, y: number, options?: PCellPlacementOptions, deviceName?: string) => boolean | void =
    (_n: string, _p: Record<string, number | string | boolean>, _x: number, _y: number) => {};
  /** 进入画布 120fps 幽灵预览交互点放模式 */
  onStartInteractiveStamp: (pcellName: string, params: Record<string, number | string | boolean>,
              options: PCellPlacementOptions, deviceName: string) => boolean | void =
    (_n: string, _p: Record<string, number | string | boolean>, _o: PCellPlacementOptions, _d: string) => {};
  contextProvider: () => string = () => '';
  private openedContext: string = '';

  @State pcells: PCellInfo[] = [];
  @State selectedIndex: number = 0;
  /** 参数文本值（按参数名索引；boolean 存 'true'/'false'） */
  @State paramTexts: Record<string, string> = {};
  @State posXText: string = '0';
  @State posYText: string = '0';
  @State error: string = '';
  @State outputMode: string = 'instance';
  @State datatypeText: string = '0';
  @State devices: TechnologyDevice[] = [];
  @State deviceName: string = '';
  @State deviceIndex: number = 0;
  @State deviceModel: string = '';

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.openedContext = this.contextProvider();
    this.pcells = nativeHongTuService.listPCells();
    this.devices = this.initialPCellName.length === 0 ? technologyService.getDevices() : [];
    this.deviceName = ''; this.deviceModel = ''; this.deviceIndex = 0;
    const initial: number = this.pcells.findIndex((pcell: PCellInfo) => pcell.name === this.initialPCellName);
    this.selectedIndex = initial >= 0 ? initial : 0;
    this.outputMode = this.initialOutputMode === 'polygon' ? 'polygon' : 'instance';
    this.datatypeText = String(this.initialDatatype);
    this.resetParamsFor(this.selectedIndex);
  }

  private resetParamsFor(index: number): void {
    this.error = '';
    const texts: Record<string, string> = {};
    if (index >= 0 && index < this.pcells.length) {
      const params = this.pcells[index].params;
      for (let i = 0; i < params.length; i++) {
        texts[params[i].name] = String(params[i].defaultValue);
      }
      if (texts['layer'] !== undefined) texts['layer'] = String(this.initialLayerNumber);
      if (texts['datatype'] !== undefined) texts['datatype'] = this.datatypeText;
    }
    this.paramTexts = texts;
  }

  private currentPCell(): PCellInfo | undefined {
    return this.selectedIndex >= 0 && this.selectedIndex < this.pcells.length
      ? this.pcells[this.selectedIndex]
      : undefined;
  }

  private fillViewportCenter(): void {
    const center: Point = this.viewportCenterProvider();
    const step: number = Number.isFinite(this.dbuNm) && this.dbuNm > 0 ? this.dbuNm : 1;
    const cx: number = Math.round(center.x / step) * step;
    const cy: number = Math.round(center.y / step) * step;
    this.posXText = String(Number(cx.toFixed(4)));
    this.posYText = String(Number(cy.toFixed(4)));
    this.error = '';
  }

  private deviceOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '内置 PCell（不绑定工艺器件）' }];
    for (const device of this.devices) options.push({ value: device.name });
    return options;
  }

  private selectDevice(index: number): void {
    if (index === 0) {
      this.deviceName = ''; this.deviceModel = ''; this.deviceIndex = 0;
      this.resetParamsFor(this.selectedIndex); return;
    }
    const device: TechnologyDevice | undefined = this.devices[index - 1];
    if (device === undefined) return;
    try {
      const resolved = technologyService.resolveDevice(device.name, this.pcells);
      const pcellIndex: number = this.pcells.findIndex((pcell: PCellInfo): boolean => pcell.name === resolved.pcell);
      const texts: Record<string, string> = {};
      for (const key of Object.keys(resolved.parameters)) texts[key] = String(resolved.parameters[key]);
      this.selectedIndex = pcellIndex; this.paramTexts = texts;
      this.datatypeText = String(resolved.parameters['datatype'] ?? this.initialDatatype);
      this.deviceName = device.name; this.deviceModel = resolved.model; this.deviceIndex = index;
      this.outputMode = 'instance'; this.error = '';
    } catch (error) { this.error = String(error); }
  }

  private displayParams(): PCellParamInfo[] {
    return (this.currentPCell()?.params ?? []).filter((param: PCellParamInfo) => param.name !== 'datatype');
  }

  private approximationText(): string {
    const name: string = this.currentPCell()?.name ?? '';
    if (!isCurvePCell(name)) return '';
    try {
      const params: Record<string, number | string | boolean> = {};
      Object.keys(this.paramTexts).forEach((key: string) => { params[key] = Number(this.paramTexts[key]); });
      const result = curveApproximation(name, params);
      return result === null ? '' : `预估 ${result.segments} 段 / ${result.pointCount} 顶点 · 偏差 ≤ ${Number(result.errorNm.toPrecision(4))} nm`;
    } catch (error) { return String(error); }
  }

  private positionQuantization(): string {
    if (this.posXText.trim().length === 0 || this.posYText.trim().length === 0) return '';
    try { return `X ${quantizationText(Number(this.posXText), this.dbuNm)}\nY ${quantizationText(Number(this.posYText), this.dbuNm)}`; }
    catch (error) { return ''; }
  }

  private handleConfirm(): void {
    if (this.openedContext !== this.contextProvider()) { this.error = '版图已变化，请重新打开放置器件'; return; }
    const pcell = this.currentPCell();
    if (pcell === undefined) {
      this.error = '当前 PCell 定义不可用';
      return;
    }
    const values: Record<string, number | string | boolean> = {};
    for (let i = 0; i < pcell.params.length; i++) {
      const p = pcell.params[i];
      const text: string = p.name === 'datatype' ? this.datatypeText : (this.paramTexts[p.name] ?? String(p.defaultValue));
      if (p.type === 'int' || p.type === 'double' || p.type === 'layer') {
        const v: number = Number(text);
        if (text.trim().length === 0 || !Number.isFinite(v) ||
          ((p.type === 'int' || p.type === 'layer') && !Number.isInteger(v)) ||
          (p.type === 'layer' && (v < 0 || v > 32767))) {
          this.error = `${p.displayName} 需要完整的有限${p.type === 'double' ? '数值' : '整数'}`; return;
        }
        if ((typeof p.minValue === 'number' && v < p.minValue) || (typeof p.maxValue === 'number' && v > p.maxValue)) {
          this.error = `${p.displayName} 超出允许范围 ${p.minValue}–${p.maxValue}`; return;
        }
        values[p.name] = v;
      } else if (p.type === 'boolean') {
        values[p.name] = text === 'true';
      } else {
        values[p.name] = text;
      }
    }
    const px: number = Number(this.posXText);
    const py: number = Number(this.posYText);
    if (this.posXText.trim().length === 0 || this.posYText.trim().length === 0 || !Number.isFinite(px) || !Number.isFinite(py)) {
      this.error = '放置坐标需要完整的有限数值（nm）'; return;
    }
    const datatype: number = Number(this.datatypeText);
    if (this.datatypeText.trim().length === 0 || !Number.isInteger(datatype) || datatype < 0 || datatype > 32767) {
      this.error = '数据类型须为 0–32767 的整数'; return;
    }
    try { curveApproximation(pcell.name, values); }
    catch (error) { this.error = String(error); return; }
    const options: PCellPlacementOptions = { outputMode: this.outputMode, datatype,
      maxErrorNm: Number(values['max_error'] ?? 0) };
    this.error = '';
    try {
      if (this.deviceName.length > 0 && this.outputMode !== 'instance') { this.error = '工艺器件需保留参数化实例和模型身份，请选择参数化实例'; return; }
      if (this.onConfirm(pcell.name, values, px, py, options, this.deviceName) === false) {
        this.error = '器件未生成或放置，请检查参数关系、图层锁定和状态栏提示'; return;
      }
    } catch (error) { this.error = `器件未放置：${String(error)}`; return; }
    this.controller.close();
  }

  private handleStartInteractiveStamp(): void {
    if (this.openedContext !== this.contextProvider()) { this.error = '版图已变化，请重新打开放置器件'; return; }
    const pcell = this.currentPCell();
    if (pcell === undefined) {
      this.error = '当前 PCell 定义不可用';
      return;
    }
    const values: Record<string, number | string | boolean> = {};
    for (let i = 0; i < pcell.params.length; i++) {
      const p = pcell.params[i];
      const text: string = p.name === 'datatype' ? this.datatypeText : (this.paramTexts[p.name] ?? String(p.defaultValue));
      if (p.type === 'int' || p.type === 'double' || p.type === 'layer') {
        const v: number = Number(text);
        if (text.trim().length === 0 || !Number.isFinite(v) ||
          ((p.type === 'int' || p.type === 'layer') && !Number.isInteger(v)) ||
          (p.type === 'layer' && (v < 0 || v > 32767))) {
          this.error = `${p.displayName} 需要完整的有限${p.type === 'double' ? '数值' : '整数'}`; return;
        }
        if ((typeof p.minValue === 'number' && v < p.minValue) || (typeof p.maxValue === 'number' && v > p.maxValue)) {
          this.error = `${p.displayName} 超出允许范围 ${p.minValue}–${p.maxValue}`; return;
        }
        values[p.name] = v;
      } else if (p.type === 'boolean') {
        values[p.name] = text === 'true';
      } else {
        values[p.name] = text;
      }
    }
    const datatype: number = Number(this.datatypeText);
    if (this.datatypeText.trim().length === 0 || !Number.isInteger(datatype) || datatype < 0 || datatype > 32767) {
      this.error = '数据类型须为 0–32767 的整数'; return;
    }
    try { curveApproximation(pcell.name, values); }
    catch (error) { this.error = String(error); return; }
    if (this.deviceName.length > 0 && this.outputMode !== 'instance') {
      this.error = '工艺器件需保留参数化实例和模型身份，请选择参数化实例'; return;
    }
    const options: PCellPlacementOptions = {
      outputMode: this.outputMode,
      datatype,
      maxErrorNm: Number(values['max_error'] ?? 0)
    };
    this.error = '';
    try {
      if (this.onStartInteractiveStamp(pcell.name, values, options, this.deviceName) === false) {
        this.error = '无法启动器件画布点放，请检查图层锁定或参数约束';
        return;
      }
    } catch (error) {
      this.error = `器件点放未启动：${String(error)}`;
      return;
    }
    this.controller.close();
  }

  @Builder
  PCellContent() {
    Column({ space: 12 }) {
      if (this.pcells.length === 0) {
        Text('PCell 库不可用（native 未加载）').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%')
      } else {
        if (this.devices.length > 0) {
          Text('工艺器件').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
          Select(this.deviceOptions()).selected(this.deviceIndex).value(this.deviceIndex === 0 ? '内置 PCell（不绑定工艺器件）' : this.deviceName)
            .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
            .onSelect((index: number) => this.selectDevice(index))
          if (this.deviceName.length > 0) {
            Text(`工艺模型：${this.deviceModel}`)
              .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
          }
        }
        Text(this.initialPCellName.length > 0 ? '曲线类型' : '器件类型')
          .fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        Scroll() {
          Row({ space: 8 }) {
            ForEach(this.pcells, (item: PCellInfo, index: number) => {
              Button(item.displayName, { type: ButtonType.Normal })
                .height(UI.compactControlHeight).fontSize(UI.fontBody)
                .fontColor(index === this.selectedIndex ? COLORS.primary : COLORS.ink)
                .padding({ left: 12, right: 12 }).borderRadius(UI.controlRadius)
                .animation(null)
                .backgroundColor(index === this.selectedIndex ? COLORS.primarySoft : COLORS.surfaceMuted)
                .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
                .onClick(() => {
                  this.deviceName = ''; this.deviceModel = ''; this.deviceIndex = 0;
                  this.selectedIndex = index;
                  this.resetParamsFor(index);
                })
            }, (item: PCellInfo) => item.name)
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).width('100%').height(UI.compactControlHeight).clip(true)

        Column({ space: 8 }) {
          Text('输出类型').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          StableSegmentButton({
            items: [{ text: '普通图形' }, { text: '参数化实例' }] as [
              SegmentButtonTextItem,
              SegmentButtonTextItem
            ] as SegmentButtonItemTuple,
            selectedIndex: this.outputMode === 'polygon' ? 0 : 1,
            onItemClicked: (idx: number) => {
              const nextMode: string = idx === 0 ? 'polygon' : 'instance';
              if (this.outputMode !== nextMode) {
                this.outputMode = nextMode;
                this.error = '';
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
        }.width('100%')
        Row({ space: 12 }) {
          if (this.initialPCellName.length > 0) {
            Text('数据类型').fontSize(UI.fontBody).fontColor(COLORS.ink).width(132)
          }
          Column({ space: 8 }) {
            if (this.initialPCellName.length === 0) {
              Text('数据类型').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
            }
            TextInput({ text: this.datatypeText }).width('100%').height(UI.fieldHeight).fontSize(UI.fontBody)
              .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((value: string) => {
                if (this.datatypeText !== value) { this.datatypeText = value; this.error = ''; }
              })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        }.width('100%').alignItems(VerticalAlign.Center)

        Text('参数设置').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
          .padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border })
        Column({ space: 12 }) {
          ForEach(this.displayParams(), (p: PCellParamInfo) => {
            Row({ space: 12 }) {
              if (this.initialPCellName.length > 0) {
                Text(p.unit.length > 0 ? `${p.displayName} (${p.unit})` : p.displayName)
                  .fontSize(UI.fontBody).fontColor(COLORS.ink).width(132)
              }
              Column({ space: 8 }) {
                if (this.initialPCellName.length === 0) {
                  Text(p.unit.length > 0 ? `${p.displayName} (${p.unit})` : p.displayName)
                    .fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
                }
                if (p.type === 'boolean') {
                  Toggle({ type: ToggleType.Switch, isOn: this.paramTexts[p.name] === 'true' })
                    .onChange((on: boolean) => {
                      if ((this.paramTexts[p.name] === 'true') !== on) { this.paramTexts[p.name] = on ? 'true' : 'false'; this.error = ''; }
                    })
                } else {
                  TextInput({ text: this.paramTexts[p.name] ?? '' }).width('100%').height(UI.fieldHeight)
                    .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted).type(InputType.Normal)
                    .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                    .onFocus(() => { resetModifierKeys(); })
                    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                    .onChange((v: string) => {
                      if ((this.paramTexts[p.name] ?? '') !== v) { this.paramTexts[p.name] = v; this.error = ''; }
                    })
                }
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
            }.width('100%').alignItems(VerticalAlign.Center)
          }, (p: PCellParamInfo) => p.name)
        }.width('100%')

        if (isCurvePCell(this.currentPCell()?.name ?? '')) {
          Text(this.approximationText()).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            .padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
        }

        Row({ space: 8 }) {
          Text('放置位置').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
          Button('取视口中心', { type: ButtonType.Normal })
            .height(26).padding({ left: 10, right: 10 }).fontSize(UI.fontCaption)
            .fontColor(COLORS.primary).backgroundColor(COLORS.primarySoft)
            .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
            .onClick(() => this.fillViewportCenter())
          Button('归零 (0,0)', { type: ButtonType.Normal })
            .height(26).padding({ left: 10, right: 10 }).fontSize(UI.fontCaption)
            .fontColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .onClick(() => { this.posXText = '0'; this.posYText = '0'; this.error = ''; })
        }.width('100%').padding({ top: 16 }).border({ width: { top: 1 }, color: COLORS.border }).alignItems(VerticalAlign.Center)

        Row({ space: 12 }) {
          Column({ space: 8 }) {
            Text('X (nm)').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
            TextInput({ text: this.posXText, placeholder: 'X' }).width('100%').height(UI.fieldHeight)
              .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted).type(InputType.Normal)
              .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((v: string) => {
                if (this.posXText !== v) { this.posXText = v; this.error = ''; }
              })
          }.layoutWeight(1)
          Column({ space: 8 }) {
            Text('Y (nm)').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
            TextInput({ text: this.posYText, placeholder: 'Y' }).width('100%').height(UI.fieldHeight)
              .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted).type(InputType.Normal)
              .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((v: string) => {
                if (this.posYText !== v) { this.posYText = v; this.error = ''; }
              })
          }.layoutWeight(1)
        }.width('100%')
        if (this.positionQuantization().length > 0) {
          Text(this.positionQuantization()).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        }
      }

    }.width('100%').padding({ right: 4, bottom: 8 }).alignItems(HorizontalAlign.Start)
  }

  aboutToDisappear(): void {
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column({ space: 12 }) {
      PanelHeading({
        title: this.initialPCellName.length > 0 ? '绘制曲线' : '放置参数化器件',
        subtitle: '可输入精确坐标落点，或进入画布实时磁吸点放',
        closeAction: () => { this.controller.close(); }
      })
      Scroll() {
        this.PCellContent()
      }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
      if (this.error.length > 0) Text(this.error).fontSize(UI.fontBody).fontColor(COLORS.danger).width('100%')
      Row({ space: 12 }) {
        Blank()
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody)
          .padding({ left: 18, right: 18 }).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => { this.controller.close(); })
        Button('按坐标放置', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody)
          .padding({ left: 18, right: 18 }).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.primary)
          .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).enabled(this.pcells.length > 0)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => { this.handleConfirm(); })
        Button('画布磁吸点放', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody)
          .padding({ left: 20, right: 20 }).backgroundColor(COLORS.primary).fontColor(Color.White)
          .borderRadius(UI.controlRadius).enabled(this.pcells.length > 0)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => { this.handleStartInteractiveStamp(); })
      }.width('100%').padding({ top: 14 }).border({ width: { top: 1 }, color: COLORS.border }).margin({ top: 4 })
    }.width(540).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 820 }).padding(UI.dialogPadding)
      .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}
