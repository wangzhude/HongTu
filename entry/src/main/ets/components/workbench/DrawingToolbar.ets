import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { FONT_MONO } from '../../common/Fonts';
import { ActiveTool } from '../../workbench/WorkbenchModels';
import { WorkbenchIcon } from './WorkbenchIcon';
import { menuIcon, menuStyle, MENU_ITEM_STYLE } from '../../common/WorkbenchMenuStyle';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState } from '../../store/ThemeStore';

/**
 * 鸿图绘制工具栏（Phase 6：曲线工具默认进入画布直接磁吸拖拽模式，同时保留精确参数对话框入口；
 * 全量工具按钮设为 focusable(false)，确保点击切换工具不抢夺画布键盘焦点）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

interface DrawingToolDef {
  tool: ActiveTool;
  icon: string;
  label: string;
  key: string;
}

const DRAWING_TOOLS: DrawingToolDef[] = [
  { tool: ActiveTool.Select, icon: 'select', label: '选择', key: 'S' },
  { tool: ActiveTool.Pan, icon: 'pan', label: '漫游', key: 'H' },
  { tool: ActiveTool.Measure, icon: 'measure', label: '测量', key: 'R' },
  { tool: ActiveTool.Rect, icon: 'rect', label: '矩形', key: 'B' },
  { tool: ActiveTool.Polygon, icon: 'polygon', label: '多边形', key: 'P' },
  { tool: ActiveTool.Path, icon: 'path', label: '路径', key: 'L' },
  { tool: ActiveTool.Text, icon: 'text', label: '文本', key: 'X' },
  { tool: ActiveTool.Instance, icon: 'instance', label: '实例', key: 'I' },
];

interface CurveToolDef { name: string; label: string; commands: string; }
const CURVE_TOOLS: CurveToolDef[] = [
  { name: 'CIRCLE', label: '圆形', commands: 'M20 12A8 8 0 1 1 4 12A8 8 0 1 1 20 12Z' },
  { name: 'ELLIPSE', label: '椭圆', commands: 'M22 12A10 6 0 1 1 2 12A10 6 0 1 1 22 12Z' },
  { name: 'DONUT', label: '圆环', commands: 'M21 12A9 9 0 1 1 3 12A9 9 0 1 1 21 12ZM17 12A5 5 0 1 1 7 12A5 5 0 1 1 17 12Z' },
  { name: 'ARC', label: '圆弧', commands: 'M3 16A10 10 0 0 1 20 5M6 16A7 7 0 0 1 18 8M3 16L6 16M20 5L18 8' },
];

@Component
export struct DrawingToolbar {
  @Prop currentTool: ActiveTool = ActiveTool.Select;
  @Prop activeCurveKind: string = '';
  @Prop editable: boolean = true;
  @Prop isCompact: boolean = false;
  @Prop vertical: boolean = false;
  @Prop availableHeight: number = 344;
  selectToolAction: (tool: ActiveTool, label: string) => void = () => {};
  interactiveCurveAction: (curveKind: string) => void = (_k: string) => {};
  curveAction: (pcellName: string) => void = () => {};

  private toolEnabled(tool: ActiveTool): boolean {
    return this.editable || tool === ActiveTool.Select || tool === ActiveTool.Pan || tool === ActiveTool.Measure;
  }

  private isCurveActive(): boolean {
    return this.activeCurveKind.length > 0;
  }

  private activeCurveCommands(): string {
    for (let i = 0; i < CURVE_TOOLS.length; i++) {
      if (CURVE_TOOLS[i].name === this.activeCurveKind) {
        return CURVE_TOOLS[i].commands;
      }
    }
    return CURVE_TOOLS[0].commands;
  }

  private activeCurveButtonLabel(): string {
    for (let i = 0; i < CURVE_TOOLS.length; i++) {
      if (CURVE_TOOLS[i].name === this.activeCurveKind) {
        return CURVE_TOOLS[i].label;
      }
    }
    return '曲线';
  }

  @Builder
  private curveMenu() {
    Menu() {
      MenuItem({ content: '画布拖拽圆形', symbolStartIcon: menuIcon('pcell') }).attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.editable).onClick(() => this.interactiveCurveAction('CIRCLE'))
      MenuItem({ content: '画布拖拽圆环', symbolStartIcon: menuIcon('pcell') }).attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.editable).onClick(() => this.interactiveCurveAction('DONUT'))
      MenuItem({ content: '画布拖拽椭圆', symbolStartIcon: menuIcon('pcell') }).attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.editable).onClick(() => this.interactiveCurveAction('ELLIPSE'))
      MenuItem({ content: '画布拖拽圆弧', symbolStartIcon: menuIcon('pcell') }).attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.editable).onClick(() => this.interactiveCurveAction('ARC'))
      MenuItem({ content: '精确参数输入…', symbolStartIcon: menuIcon('edit') }).attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.editable).onClick(() => this.curveAction(this.activeCurveKind.length > 0 ? this.activeCurveKind : 'CIRCLE'))
    }.attributeModifier(menuStyle([
      { content: '画布拖拽圆形', symbolStartIcon: menuIcon('pcell') },
      { content: '画布拖拽圆环', symbolStartIcon: menuIcon('pcell') },
      { content: '画布拖拽椭圆', symbolStartIcon: menuIcon('pcell') },
      { content: '画布拖拽圆弧', symbolStartIcon: menuIcon('pcell') },
      { content: '精确参数输入…', symbolStartIcon: menuIcon('edit') }
    ], this.getUIContext()))
  }

  @Builder
  private curveMenuButton() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        Shape() {
          Path().commands(this.activeCurveCommands()).fill(Color.Transparent)
            .stroke(this.isCurveActive() ? COLORS.primary : COLORS.ink).strokeWidth('1.6px')
        }.width(22).height(22).viewPort({ x: '0px', y: '0px', width: '24px', height: '24px' })
        if (!this.vertical) {
          Text(this.activeCurveButtonLabel())
            .fontSize(UI.fontBody)
            .fontColor(this.isCurveActive() ? COLORS.primary : COLORS.ink)
            .fontWeight(this.isCurveActive() ? FontWeight.Bold : FontWeight.Medium)
        }
      }
    }
    .id('curve-tools-menu')
    .height(this.vertical ? UI.controlHeight : UI.compactControlHeight)
    .constraintSize({ minWidth: this.vertical ? 40 : 64, maxWidth: this.vertical ? 40 : 120 })
    .padding({ left: 6, right: 6 })
    .backgroundColor(this.isCurveActive() ? COLORS.primarySoft : Color.Transparent)
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.editable)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText('曲线工具')
    .accessibilitySelected(this.isCurveActive())
    .bindTips('画布拖拽绘制圆形、圆环、椭圆、圆弧，或输入精确参数')
    .bindMenu(this.curveMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
  }

  build() {
    if (this.vertical) {
      Scroll() {
        Column({ space: 4 }) {
          ForEach(DRAWING_TOOLS, (item: DrawingToolDef) => {
            DrawingToolButton({
              icon: item.icon,
              label: item.label,
              shortcutKey: item.key,
              active: !this.isCurveActive() && this.currentTool === item.tool,
              actionEnabled: this.toolEnabled(item.tool),
              vertical: true,
              activateAction: () => {
                this.selectToolAction(item.tool, item.label);
              }
            })
          }, (item: DrawingToolDef) => item.tool)
          Row().width(26).height(1).backgroundColor(COLORS.border).margin({ top: 3, bottom: 3 })
          this.curveMenuButton()
        }
      }
      .scrollable(ScrollDirection.Vertical)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .width(48)
      .height(Math.min(392, Math.max(80, this.availableHeight)))
      .padding(4)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
    } else {
      Scroll() {
        Row() {
          ForEach(DRAWING_TOOLS, (item: DrawingToolDef) => {
            DrawingToolButton({
              label: item.label,
              shortcutKey: item.key,
              active: !this.isCurveActive() && this.currentTool === item.tool,
              actionEnabled: this.toolEnabled(item.tool),
              activateAction: () => {
                this.selectToolAction(item.tool, item.label);
              }
            })
          }, (item: DrawingToolDef) => item.tool)
          Row().width(1).height(24).backgroundColor(COLORS.border).margin({ left: 4, right: 4 })
          this.curveMenuButton()
        }
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .height(UI.controlHeight)
      .width('100%')
      .padding({ left: 8, right: 8 })
      .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
        ? hongTuThemeState.luminous.translucentCardColor
        : COLORS.surface)
      .border({ width: { bottom: 0.8 }, color: COLORS.border })
    }
  }
}

@Component
struct DrawingToolButton {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop shortcutKey: string = '';
  @Prop active: boolean = false;
  @Prop vertical: boolean = false;
  @Prop actionEnabled: boolean = true;
  activateAction: () => void = () => {};

  private activate(): void {
    if (this.actionEnabled) this.activateAction();
  }

  build() {
    if (this.vertical) {
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: this.icon, iconSize: 22, color: this.active ? COLORS.primary : COLORS.ink })
      }
      .width(40)
      .height(UI.controlHeight)
      .padding(0)
      .borderRadius(UI.controlRadius)
      .animation(null)
      .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
      .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
      .animation(null)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .stateEffect(true)
      .enabled(this.actionEnabled).hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText(`${this.label} ${this.shortcutKey}`)
      .accessibilityDescription(`${this.label} (${this.shortcutKey})`)
      .accessibilitySelected(this.active)
      .bindTips(`${this.label} (${this.shortcutKey})`)
      .onClick(() => this.activate())
    } else {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 4 }) {
          Text(this.label)
            .fontSize(UI.fontBody)
            .fontColor(this.active ? COLORS.primary : COLORS.ink)
            .fontWeight(this.active ? FontWeight.Bold : FontWeight.Medium)
          Text(this.shortcutKey)
            .fontSize(UI.fontCaption)
            .fontColor(this.active ? COLORS.primary : COLORS.muted)
            .fontFamily(FONT_MONO)
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(UI.compactControlHeight)
      .padding({ left: 10, right: 10 })
      .margin({ right: 3 })
      .borderRadius(UI.controlRadius)
      .animation(null)
      .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
      .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
      .animation(null)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .stateEffect(true)
      .enabled(this.actionEnabled).hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText(`${this.label} ${this.shortcutKey}`)
      .accessibilityDescription(`${this.label} (${this.shortcutKey})`)
      .accessibilitySelected(this.active)
      .bindTips(`${this.label} (${this.shortcutKey})`)
      .onClick(() => this.activate())
    }
  }
}
