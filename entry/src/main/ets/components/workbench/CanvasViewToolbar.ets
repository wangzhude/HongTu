import {
  AccessibilitySelectedType,
  Chip,
  ChipSize,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { COLORS, formatZoomPercent } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { menuIcon, MENU_ITEM_STYLE, menuStyle, menuCheckIcon } from '../../common/WorkbenchMenuStyle';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面/平板画布顶栏工具条（Phase 6 双技能合规版）
 *
 * 绘制辅助开关（网格吸附 / 几何磁吸 / 正交锁角）全面采用 `@kit.ArkUI` 官方 `Chip`（`ChipSize.SMALL`），
 * 置于 `Row({ space: 6 })` 容器内，严守华为官方「不在 `Chip` 上链式设置通用属性/事件」规范。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

@Component
export struct CanvasToolbarIconButton {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop actionEnabled: boolean = false;
  activateAction: () => void = () => {};

  private activate(): void {
    if (this.actionEnabled) this.activateAction();
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      WorkbenchIcon({ name: this.icon, iconSize: 18, color: this.actionEnabled ? COLORS.ink : COLORS.muted })
    }
    .width(32).height(32).padding(0).backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.actionEnabled).opacity(this.actionEnabled ? 1 : 0.4).hoverEffect(HoverEffect.Highlight)
    .accessibilityText(this.label).accessibilityDescription(this.label).bindTips(this.label).onClick(() => this.activate())
  }
}

@Component
export struct CanvasViewToolbar {
  @Prop viewMode: string = '编辑';
  @Prop zoomPercent: number = 100;
  @Prop canUndo: boolean = false;
  @Prop canRedo: boolean = false;
  @Prop scopeText: string = '';
  @Prop compactMode: boolean = false;
  @Prop gridSnapEnabled: boolean = true;
  @Prop geometrySnapEnabled: boolean = true;
  @Prop routingModeLabel: string = '90°正交';
  @Prop routingLocked: boolean = true;
  @Prop multiSelectAdditive: boolean = false;
  undoAction: () => void = () => {};
  redoAction: () => void = () => {};
  zoomAction: (delta: number) => void = () => {};
  fitAction: () => void = () => {};
  modeAction: (mode: string) => void = () => {};
  toggleGridSnapAction: () => void = () => {};
  toggleGeometrySnapAction: () => void = () => {};
  cycleRoutingModeAction: () => void = () => {};
  toggleMultiSelectAdditiveAction: () => void = () => {};

  @Builder
  private modeMenu() {
    Menu() {
      MenuItem({ content: '编辑模式', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode === '编辑') })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewMode === '编辑')
        .onClick(() => this.modeAction('编辑'))
      MenuItem({ content: '只读查看', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.viewMode === '查看') })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewMode === '查看')
        .onClick(() => this.modeAction('查看'))
    }.attributeModifier(menuStyle([
      { content: '编辑模式', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode === '编辑') },
      { content: '只读查看', symbolStartIcon: menuIcon('eye'), symbolEndIcon: menuCheckIcon(this.viewMode === '查看') }
    ], this.getUIContext()))
  }

  build() {
    Row({ space: this.compactMode ? 4 : 8 }) {
      Button({ type: ButtonType.Normal }) {
        Row({ space: 8 }) {
          Row() { WorkbenchIcon({ name: this.viewMode === '查看' ? 'eye' : 'edit', iconSize: 18, color: COLORS.primary }) }
            .width(28).height(28).justifyContent(FlexAlign.Center).backgroundColor(COLORS.primarySoft).borderRadius(6)
          Text(this.viewMode).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink)
          WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
        }
      }
      .height(36).padding({ left: 6, right: 10 })
      .backgroundColor(COLORS.surface)
      .border({ width: 1, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .bindTips(this.scopeText)
      .accessibilityText(`视图模式：${this.viewMode}`)
      .accessibilityDescription('打开模式菜单，选择只读查看或编辑模式')
      .bindMenu(this.modeMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))

      CanvasToolbarIconButton({ icon: 'undo', label: '撤销 Ctrl+Z', actionEnabled: this.canUndo, activateAction: this.undoAction }).width(32).height(32)
      CanvasToolbarIconButton({ icon: 'redo', label: '重做 Ctrl+Shift+Z', actionEnabled: this.canRedo, activateAction: this.redoAction }).width(32).height(32)
      Row().width(1).height(22).backgroundColor(COLORS.border).margin({ left: 4, right: 4 })
      Row({ space: 2 }) {
        CanvasToolbarIconButton({ icon: 'minus', label: '缩小', actionEnabled: true, activateAction: () => this.zoomAction(-1) }).width(32).height(32)
        Text(formatZoomPercent(this.zoomPercent)).fontSize(13).fontColor(COLORS.ink).width(64).textAlign(TextAlign.Center)
        CanvasToolbarIconButton({ icon: 'plus', label: '放大', actionEnabled: true, activateAction: () => this.zoomAction(1) }).width(32).height(32)
      }.height(36).padding({ left: 4, right: 4 }).backgroundColor(COLORS.surface)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          WorkbenchIcon({ name: 'fit', iconSize: 18, color: COLORS.ink })
          if (!this.compactMode) { Text('适配').fontSize(13).fontColor(COLORS.ink) }
        }
      }
      .height(36).padding({ left: 10, right: 10 }).backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .accessibilityText('适配全部版图').onClick(this.fitAction)

      Row().width(1).height(22).backgroundColor(COLORS.border).margin({ left: 2, right: 2 })

      // 绘制辅助快捷组：使用官方 ArkUI Chip 组件承载开关胶囊（外层 Row 控制间距，避免挂载通用属性生成 __Common__ 节点）
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
          accessibilityDescription: '免按 Shift 键连续点选加减选与累加框选',
          onClicked: () => {
            this.toggleMultiSelectAdditiveAction();
          }
        })

        Chip({
          prefixSymbol: {
            normal: new SymbolGlyphModifier($r('sys.symbol.grid')).fontSize(14).fontColor([COLORS.muted]),
            activated: new SymbolGlyphModifier($r('sys.symbol.grid')).fontSize(14).fontColor([COLORS.primary])
          },
          label: {
            text: '网格',
            fontSize: 12,
            fontColor: COLORS.ink,
            activatedFontColor: COLORS.primary
          },
          size: ChipSize.SMALL,
          allowClose: false,
          activated: this.gridSnapEnabled,
          backgroundColor: COLORS.surfaceMuted,
          activatedBackgroundColor: COLORS.primarySoft,
          borderRadius: UI.controlRadius,
          maxFontScale: 1.3,
          accessibilitySelectedType: AccessibilitySelectedType.CHECKED,
          accessibilityDescription: '网格步长吸附开关',
          onClicked: () => {
            this.toggleGridSnapAction();
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
          accessibilityDescription: '几何靶标磁吸（顶点、中点、交点、边）与智能十字对齐线',
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
      }
      .alignItems(VerticalAlign.Center)
    }.height(44).padding({ left: 8, right: 4 }).alignItems(VerticalAlign.Center)
  }
}
