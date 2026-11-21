import {
  AccessibilitySelectedType,
  Chip,
  ChipSize,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { COLORS, formatZoomPercent } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { IconResource } from '../../common/Icons';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 鸿图主界面编辑工具栏（Phase 6 双技能合规版）
 *
 * 1. 磁吸 / 正交走线 / 指尖放大镜三项筛选状态开关全面升级为 `@kit.ArkUI` 官方 `Chip`（`ChipSize.SMALL`），
 *    统一由外层 `Row({ space: 6 })` 托管布局，杜绝在 `Chip` 上直接链式追加通用属性引发 `__Common__` 节点异常；
 * 2. 开放「移动」工具按钮在未预先框选图形时亦可点击激活（配合画布按下自动拾取未选图形直拖能力）；
 * 3. 全量替换残留的 `Curve.EaseOut` 为 `feedbackCurve()`（`GravityCurve.standard` 引力弹簧 + 减弱动态效果自动降级 `Curve.Linear`）；
 * 4. 所有工具/命令 `Button` 显式设为 `.focusable(false)`，杜绝 2in1 鼠标点击后抢走画布键盘焦点或按 `Space`/`Enter` 误触发命令。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct EditorToolbar {
  @Prop zoomPercent: number = 100;
  @Prop moveToolActive: boolean = false;
  @Prop canUndo: boolean = false;
  @Prop canRedo: boolean = false;
  @Prop editable: boolean = true;
  @Prop hasSelection: boolean = false;
  @Prop selectionCount: number = 0;
  @Prop isCompact: boolean = false;
  @Prop geometrySnapEnabled: boolean = true;
  @Prop routingModeLabel: string = '90°正交';
  @Prop routingLocked: boolean = true;
  @Prop touchLoupeEnabled: boolean = true;
  @Prop multiSelectAdditive: boolean = false;
  undoAction: () => void = () => {};
  redoAction: () => void = () => {};
  duplicateAction: () => void = () => {};
  deleteAction: () => void = () => {};
  moveToolAction: () => void = () => {};
  alignLeftAction: () => void = () => {};
  alignRightAction: () => void = () => {};
  alignTopAction: () => void = () => {};
  alignBottomAction: () => void = () => {};
  alignCenterAction: () => void = () => {};
  alignCenterVAction: () => void = () => {};
  placeInstanceAction: () => void = () => {};
  traceAction: () => void = () => {};
  zoomAction: (delta: number) => void = () => {};
  resetViewAction: () => void = () => {};
  rotate90Action: () => void = () => {};
  mirrorHAction: () => void = () => {};
  toggleGeometrySnapAction: () => void = () => {};
  cycleRoutingModeAction: () => void = () => {};
  toggleTouchLoupeAction: () => void = () => {};
  toggleMultiSelectAdditiveAction: () => void = () => {};

  build() {
    Scroll() {
      Row() {
        ToolbarCommand({ icon: 'undo', label: '撤销', showLabel: !this.isCompact, activateAction: this.undoAction, disabled: !this.editable || !this.canUndo })
        ToolbarCommand({ icon: 'redo', label: '重做', showLabel: !this.isCompact, activateAction: this.redoAction, disabled: !this.editable || !this.canRedo })
        ToolbarCommand({ icon: 'duplicate', label: '复制+1', showLabel: !this.isCompact, activateAction: this.duplicateAction, disabled: !this.editable || !this.hasSelection })
        ToolbarCommand({ icon: 'delete', label: '删除', showLabel: !this.isCompact, activateAction: this.deleteAction, disabled: !this.editable || !this.hasSelection })

        ToolDivider()

        // 触屏绘制辅助三件套：使用官方 ArkUI Chip 组件承载激活态胶囊
        Row({ space: 6 }) {
          Chip({
            prefixSymbol: {
              normal: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')).fontSize(14).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')).fontSize(14).fontColor([COLORS.primary])
            },
            label: {
              text: '加选',
              fontSize: 12,
              fontColor: COLORS.ink,
              activatedFontColor: COLORS.primary
            },
            size: ChipSize.SMALL,
            allowClose: false,
            activated: this.multiSelectAdditive,
            backgroundColor: COLORS.surfaceMuted,
            activatedBackgroundColor: COLORS.primarySoft,
            borderRadius: UI.controlRadius,
            maxFontScale: 1.3,
            accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
            accessibilityDescription: '触屏免键盘加减选与累加框选开关',
            onClicked: () => {
              this.toggleMultiSelectAdditiveAction();
            }
          })

          Chip({
            prefixSymbol: {
              normal: new SymbolGlyphModifier($r('sys.symbol.scope')).fontSize(14).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.scope')).fontSize(14).fontColor([COLORS.primary])
            },
            label: {
              text: '磁吸',
              fontSize: 12,
              fontColor: COLORS.ink,
              activatedFontColor: COLORS.primary
            },
            size: ChipSize.SMALL,
            allowClose: false,
            activated: this.geometrySnapEnabled,
            backgroundColor: COLORS.surfaceMuted,
            activatedBackgroundColor: COLORS.primarySoft,
            borderRadius: UI.controlRadius,
            maxFontScale: 1.3,
            accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
            accessibilityDescription: '几何靶标磁吸与智能对齐参考线开关',
            onClicked: () => {
              this.toggleGeometrySnapAction();
            }
          })

          Chip({
            prefixSymbol: {
              normal: new SymbolGlyphModifier($r('sys.symbol.stroke_path')).fontSize(14).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.stroke_path')).fontSize(14).fontColor([COLORS.primary])
            },
            label: {
              text: this.routingModeLabel,
              fontSize: 12,
              fontColor: COLORS.ink,
              activatedFontColor: COLORS.primary
            },
            size: ChipSize.SMALL,
            allowClose: false,
            activated: this.routingLocked,
            backgroundColor: COLORS.surfaceMuted,
            activatedBackgroundColor: COLORS.primarySoft,
            borderRadius: UI.controlRadius,
            maxFontScale: 1.3,
            accessibilitySelectedType: AccessibilitySelectedType.SELECTED,
            accessibilityDescription: '切换走线约束：90度正交、45度锁角或自由角',
            onClicked: () => {
              this.cycleRoutingModeAction();
            }
          })

          Chip({
            prefixSymbol: {
              normal: new SymbolGlyphModifier($r('sys.symbol.plus_magnifyingglass')).fontSize(14).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.plus_magnifyingglass')).fontSize(14).fontColor([COLORS.primary])
            },
            label: {
              text: '放大镜',
              fontSize: 12,
              fontColor: COLORS.ink,
              activatedFontColor: COLORS.primary
            },
            size: ChipSize.SMALL,
            allowClose: false,
            activated: this.touchLoupeEnabled,
            backgroundColor: COLORS.surfaceMuted,
            activatedBackgroundColor: COLORS.primarySoft,
            borderRadius: UI.controlRadius,
            maxFontScale: 1.3,
            accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
            accessibilityDescription: '触屏指尖高精度准星放大镜开关',
            onClicked: () => {
              this.toggleTouchLoupeAction();
            }
          })
        }
        .alignItems(VerticalAlign.Center)

        ToolDivider()

        ToolbarImageCommand({ imageResource: IconResource.move, label: '移动', showLabel: !this.isCompact, active: this.moveToolActive, activateAction: this.moveToolAction, disabled: !this.editable })
        ToolbarCommand({ icon: 'rotate', label: '旋转90°', showLabel: !this.isCompact, activateAction: this.rotate90Action, disabled: !this.editable || !this.hasSelection })
        ToolbarCommand({ icon: 'mirror', label: '水平镜像', showLabel: !this.isCompact, activateAction: this.mirrorHAction, disabled: !this.editable || !this.hasSelection })
        ToolbarImageCommand({ imageResource: IconResource.placeInstance, label: '放置实例', showLabel: !this.isCompact, activateAction: this.placeInstanceAction, disabled: !this.editable })

        if (!this.isCompact) {
          ToolDivider()

          ToolbarImageCommand({ imageResource: IconResource.alignLeft, label: '左对齐', activateAction: this.alignLeftAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
          ToolbarImageCommand({ imageResource: IconResource.alignRight, label: '右对齐', activateAction: this.alignRightAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
          ToolbarImageCommand({ imageResource: IconResource.alignTop, label: '上对齐', activateAction: this.alignTopAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
          ToolbarImageCommand({ imageResource: IconResource.alignBottom, label: '下对齐', activateAction: this.alignBottomAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
          ToolbarImageCommand({ imageResource: IconResource.alignCenter, label: '水平居中', activateAction: this.alignCenterAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
          ToolbarImageCommand({ imageResource: IconResource.alignMiddle, label: '垂直居中', activateAction: this.alignCenterVAction, disabled: !this.editable || !this.hasSelection || this.selectionCount < 2 })
        }

        ToolDivider()

        ToolbarImageCommand({ imageResource: IconResource.netTrace, label: '网络追踪', showLabel: !this.isCompact, activateAction: this.traceAction })

        Row() {
          ZoomCommand({ icon: 'minus', label: '缩小', delta: -20, zoomAction: this.zoomAction })
          Text(formatZoomPercent(this.zoomPercent))
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.ink)
            .fontFamily(FONT_MONO)
            .textAlign(TextAlign.Center)
            .width(52)
          ZoomCommand({ icon: 'plus', label: '放大', delta: 20, zoomAction: this.zoomAction })
        }
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .padding({ left: 2, right: 2 })
        .margin({ left: 6, right: 4 })
        .alignItems(VerticalAlign.Center)

        ToolbarCommand({ icon: 'reset', label: '重置视图', showLabel: !this.isCompact, activateAction: this.resetViewAction })
      }
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .height(42)
    .width('100%')
    .padding({ left: 10, right: 10 })
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }
}

@Component
struct ToolbarCommand {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop showLabel: boolean = true;
  @Prop active: boolean = false;
  @Prop disabled: boolean = false;
  activateAction: () => void = () => {};

  private activate(): void {
    if (!this.disabled) this.activateAction();
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        WorkbenchIcon({ name: this.icon, iconSize: 18, color: this.icon === 'delete' ? COLORS.danger : (this.active ? COLORS.primary : COLORS.ink) })
        if (this.showLabel) {
          Text(this.label)
            .fontSize(UI.fontBody)
            .fontColor(this.icon === 'delete' ? COLORS.danger : (this.active ? COLORS.primary : COLORS.ink))
            .fontWeight(this.active ? FontWeight.Bold : FontWeight.Medium)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(UI.compactControlHeight)
    .constraintSize({ minWidth: UI.compactControlHeight })
    .padding({ left: 8, right: 8 })
    .animation(null)
    .backgroundColor(this.icon === 'delete' ? COLORS.dangerSoft : (this.active ? COLORS.primarySoft : COLORS.surfaceMuted))
    .border({ width: 1, color: this.icon === 'delete' ? COLORS.dangerSoft : (this.active ? COLORS.primary : COLORS.border) })
    .borderRadius(UI.controlRadius)
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .margin({ right: 3 })
    .opacity(this.disabled ? 0.35 : 1.0)
    .enabled(!this.disabled)
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(this.label)
    .accessibilitySelected(this.active)
    .bindTips(this.label)
    .onClick(() => this.activate())
  }
}

@Component
struct ToolbarImageCommand {
  @Prop imageResource: Resource = $r('app.media.ic_move');
  @Prop label: string = '';
  @Prop showLabel: boolean = true;
  @Prop active: boolean = false;
  @Prop disabled: boolean = false;
  activateAction: () => void = () => {};

  private activate(): void {
    if (!this.disabled) this.activateAction();
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        Image(this.imageResource)
          .width(18)
          .height(18)
          .fillColor(this.active ? COLORS.primary : COLORS.ink)
          .accessibilityLevel('no')
        if (this.showLabel) {
          Text(this.label)
            .fontSize(UI.fontBody)
            .fontColor(this.active ? COLORS.primary : COLORS.ink)
            .fontWeight(this.active ? FontWeight.Bold : FontWeight.Medium)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(UI.compactControlHeight)
    .constraintSize({ minWidth: UI.compactControlHeight })
    .padding({ left: 8, right: 8 })
    .animation(null)
    .backgroundColor(this.active ? COLORS.primarySoft : COLORS.surfaceMuted)
    .border({ width: 1, color: this.active ? COLORS.primary : COLORS.border })
    .borderRadius(UI.controlRadius)
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .margin({ right: 3 })
    .opacity(this.disabled ? 0.35 : 1.0)
    .enabled(!this.disabled)
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(this.label)
    .accessibilitySelected(this.active)
    .bindTips(this.label)
    .onClick(() => this.activate())
  }
}

@Component
struct ZoomCommand {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop delta: number = 0;
  zoomAction: (delta: number) => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      WorkbenchIcon({ name: this.icon, iconSize: 18, color: COLORS.ink })
    }
    .width(UI.compactControlHeight)
    .height(UI.compactControlHeight)
    .padding(0)
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 1, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(this.label)
    .bindTips(this.label)
    .onClick(() => this.zoomAction(this.delta))
  }
}

@Component
struct ToolDivider {
  build() {
    Divider()
      .vertical(true)
      .height(18)
      .color(COLORS.border)
      .margin({ left: 6, right: 6 })
  }
}
