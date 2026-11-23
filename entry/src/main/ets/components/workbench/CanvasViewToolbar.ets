import {
  AccessibilitySelectedType,
  Chip,
  ChipSize,
  SegmentButtonItemTuple,
  SegmentButtonTextItem,
  SymbolGlyphModifier
} from '@kit.ArkUI';
import { COLORS, formatZoomPercent } from '../../common/constants';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { menuIcon, MENU_ITEM_STYLE, menuStyle } from '../../common/WorkbenchMenuStyle';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState } from '../../store/ThemeStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面/平板上侧全功能 CAD 命令带（v8 上侧空间全面利用 × 鸿蒙原生分段器/Chip/菜单版）
 *
 * 1. 模式切换升级为官方受控 `StableSegmentButton`（编辑 | 只读）；
 * 2. 补齐原先桌面端被隐藏的全部高频几何编辑动作：复制+1、删除、移动、旋转90°、水平/垂直镜像、6向对齐原生菜单、布尔合并/相减原生菜单、网络追踪；
 * 3. 绘制辅助开关保持官方 `@kit.ArkUI` `Chip`（`ChipSize.SMALL`），严守不在 `Chip` 上链式挂载通用属性的约束；
 * 4. 右侧直显当前激活绘制层色块与层号胶囊，点击直接调节当前层样式。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

@Component
export struct CanvasToolbarIconButton {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop actionEnabled: boolean = false;
  @Prop active: boolean = false;
  @Prop danger: boolean = false;
  activateAction: () => void = () => {};

  private activate(): void {
    if (this.actionEnabled) this.activateAction();
  }

  build() {
    Button({ type: ButtonType.Normal }) {
      WorkbenchIcon({
        name: this.icon,
        iconSize: 16,
        color: !this.actionEnabled
          ? COLORS.muted
          : (this.danger ? COLORS.danger : (this.active ? COLORS.primary : COLORS.ink))
      })
    }
    .width(30)
    .height(30)
    .padding(0)
    .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
    .border({ width: this.active ? 0.8 : 0, color: this.active ? COLORS.primary : Color.Transparent })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .enabled(this.actionEnabled)
    .opacity(this.actionEnabled ? 1 : 0.36)
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(this.label)
    .accessibilityDescription(this.label)
    .bindTips(this.label)
    .onClick(() => this.activate())
  }
}

@Component
export struct CanvasViewToolbar {
  @Prop viewMode: string = '编辑';
  @Prop zoomPercent: number = 100;
  @Prop canUndo: boolean = false;
  @Prop canRedo: boolean = false;
  @Prop editable: boolean = true;
  @Prop hasSelection: boolean = false;
  @Prop selectionCount: number = 0;
  @Prop moveToolActive: boolean = false;
  @Prop activeLayerNumber: number = 1;
  @Prop activeDatatype: number = 0;
  @Prop activeLayerColor: string = '#2984FF';
  @Prop activeLayerLabel: string = '';
  @Prop scopeText: string = '';
  @Prop compactMode: boolean = false;
  @Prop gridSnapEnabled: boolean = true;
  @Prop geometrySnapEnabled: boolean = true;
  @Prop routingModeLabel: string = '90°正交';
  @Prop routingLocked: boolean = true;
  @Prop multiSelectAdditive: boolean = false;

  undoAction: () => void = () => {};
  redoAction: () => void = () => {};
  duplicateAction: () => void = () => {};
  deleteAction: () => void = () => {};
  moveToolAction: () => void = () => {};
  rotate90Action: () => void = () => {};
  mirrorHAction: () => void = () => {};
  mirrorVAction: () => void = () => {};
  alignAction: (mode: string) => void = (_m: string) => {};
  booleanAction: (op: 'merge' | 'subtract' | 'dialog') => void = (_op: 'merge' | 'subtract' | 'dialog') => {};
  traceAction: () => void = () => {};
  openLayerStyleAction: () => void = () => {};
  zoomAction: (delta: number) => void = () => {};
  fitAction: () => void = () => {};
  modeAction: (mode: string) => void = () => {};
  toggleGridSnapAction: () => void = () => {};
  toggleGeometrySnapAction: () => void = () => {};
  cycleRoutingModeAction: () => void = () => {};
  toggleMultiSelectAdditiveAction: () => void = () => {};

  private buildModeItems(): SegmentButtonItemTuple {
    const items: [SegmentButtonTextItem, SegmentButtonTextItem] = [
      { text: '编辑' },
      { text: '只读' }
    ];
    return items;
  }

  private alignMenuSizing(): MenuItemOptions[] {
    return [
      { content: '左对齐', symbolStartIcon: menuIcon('alignLeft') },
      { content: '水平居中', symbolStartIcon: menuIcon('alignCenter') },
      { content: '右对齐', symbolStartIcon: menuIcon('alignRight') },
      { content: '上对齐', symbolStartIcon: menuIcon('alignTop') },
      { content: '垂直居中', symbolStartIcon: menuIcon('alignMiddle') },
      { content: '下对齐', symbolStartIcon: menuIcon('alignBottom') }
    ];
  }

  @Builder
  private alignQuickMenu() {
    Menu() {
      MenuItemGroup({ header: '多图形对齐（需选中 ≥2 项）' }) {
        MenuItem({ content: '左对齐', symbolStartIcon: menuIcon('alignLeft') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('left'))
        MenuItem({ content: '水平居中', symbolStartIcon: menuIcon('alignCenter') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('center_h'))
        MenuItem({ content: '右对齐', symbolStartIcon: menuIcon('alignRight') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('right'))
        MenuItem({ content: '上对齐', symbolStartIcon: menuIcon('alignTop') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('top'))
        MenuItem({ content: '垂直居中', symbolStartIcon: menuIcon('alignMiddle') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('center_v'))
        MenuItem({ content: '下对齐', symbolStartIcon: menuIcon('alignBottom') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.alignAction('bottom'))
      }
    }
    .attributeModifier(menuStyle(this.alignMenuSizing(), this.getUIContext()))
  }

  private booleanMenuSizing(): MenuItemOptions[] {
    return [
      { content: '布尔合并 (Union)', symbolStartIcon: menuIcon('union') },
      { content: '布尔相减 (Subtract)', symbolStartIcon: menuIcon('subtract') },
      { content: '精确布尔预览与图层表达式…', symbolStartIcon: menuIcon('intersect') }
    ];
  }

  @Builder
  private booleanQuickMenu() {
    Menu() {
      MenuItemGroup({ header: '多边形布尔运算' }) {
        MenuItem({ content: '布尔合并 (Union)', symbolStartIcon: menuIcon('union') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable && this.selectionCount >= 2)
          .onClick(() => this.booleanAction('merge'))
        MenuItem({ content: '布尔相减 (Subtract)', symbolStartIcon: menuIcon('subtract') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable && this.selectionCount >= 2)
          .onClick(() => this.booleanAction('subtract'))
        MenuItem({ content: '精确布尔预览与图层表达式…', symbolStartIcon: menuIcon('intersect') })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.editable)
          .onClick(() => this.booleanAction('dialog'))
      }
    }
    .attributeModifier(menuStyle(this.booleanMenuSizing(), this.getUIContext()))
  }

  build() {
    Scroll() {
      Row({ space: 5 }) {
        // 1. 原生受控模式分段按钮（编辑 | 只读）
        Row() {
          StableSegmentButton({
            items: this.buildModeItems(),
            selectedIndex: this.viewMode === '查看' ? 1 : 0,
            onItemClicked: (idx: number) => {
              this.modeAction(idx === 1 ? '查看' : '编辑');
            },
            fontColor: COLORS.muted,
            selectedFontColor: COLORS.primary,
            capsuleBackgroundColor: COLORS.surfaceMuted,
            selectedBackgroundColor: COLORS.primarySoft,
            fontSizeFp: 11.5,
            capsuleBorderRadius: UI.controlRadius,
            buttonMinHeight: 30,
            itemMinHeight: 24,
            itemPaddingHorizontal: 9,
            itemPaddingVertical: 2
          })
        }
        .width(104)
        .bindTips(this.scopeText)

        // 2. 撤销 / 重做 / 复制+1 / 删除
        CanvasToolbarIconButton({
          icon: 'undo',
          label: '撤销 Ctrl+Z',
          actionEnabled: this.canUndo,
          activateAction: this.undoAction
        })
        CanvasToolbarIconButton({
          icon: 'redo',
          label: '重做 Ctrl+Shift+Z',
          actionEnabled: this.canRedo,
          activateAction: this.redoAction
        })
        CanvasToolbarIconButton({
          icon: 'duplicate',
          label: '原位复制选区 Ctrl+D',
          actionEnabled: this.editable && this.hasSelection,
          activateAction: this.duplicateAction
        })
        CanvasToolbarIconButton({
          icon: 'delete',
          label: '删除选中图形 Delete',
          actionEnabled: this.editable && this.hasSelection,
          danger: true,
          activateAction: this.deleteAction
        })

        Divider().vertical(true).height(18).color(COLORS.border)

        // 3. 缩放步进与全图适配
        Row({ space: 1 }) {
          CanvasToolbarIconButton({
            icon: 'minus',
            label: '缩小 [',
            actionEnabled: true,
            activateAction: () => this.zoomAction(-1)
          })
          Text(formatZoomPercent(this.zoomPercent))
            .fontSize(11.5)
            .fontFamily(FONT_MONO)
            .fontColor(COLORS.ink)
            .width(52)
            .textAlign(TextAlign.Center)
          CanvasToolbarIconButton({
            icon: 'plus',
            label: '放大 ]',
            actionEnabled: true,
            activateAction: () => this.zoomAction(1)
          })
        }
        .height(30)
        .padding({ left: 2, right: 2 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(UI.controlRadius)

        Button({ type: ButtonType.Normal }) {
          Row({ space: 4 }) {
            WorkbenchIcon({ name: 'fit', iconSize: 15, color: COLORS.ink })
            if (!this.compactMode) {
              Text('适配')
                .fontSize(12)
                .fontColor(COLORS.ink)
            }
          }.alignItems(VerticalAlign.Center)
        }
        .height(30)
        .padding({ left: 8, right: 8 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .attributeModifier(hongTuThemeState.luminousPointLightModifier())
        .focusable(false)
        .accessibilityText('适配全部版图 (F)')
        .bindTips('适配全部版图 (F / 滚轮中键双击)')
        .onClick(this.fitAction)

        Divider().vertical(true).height(18).color(COLORS.border)

        // 4. 选区变换 / 对齐 / 布尔 / 网络追踪（桌面端补齐！）
        CanvasToolbarIconButton({
          icon: 'move',
          label: '移动图形 (M)',
          actionEnabled: this.editable,
          active: this.moveToolActive,
          activateAction: this.moveToolAction
        })
        CanvasToolbarIconButton({
          icon: 'rotate',
          label: '逆时针旋转 90° (R)',
          actionEnabled: this.editable && this.hasSelection,
          activateAction: this.rotate90Action
        })
        CanvasToolbarIconButton({
          icon: 'mirror',
          label: '水平镜像翻转',
          actionEnabled: this.editable && this.hasSelection,
          activateAction: this.mirrorHAction
        })
        CanvasToolbarIconButton({
          icon: 'mirrorV',
          label: '垂直镜像翻转',
          actionEnabled: this.editable && this.hasSelection,
          activateAction: this.mirrorVAction
        })

        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            WorkbenchIcon({
              name: 'alignCenter',
              iconSize: 15,
              color: this.editable && this.selectionCount >= 2 ? COLORS.ink : COLORS.muted
            })
            if (!this.compactMode) {
              Text('对齐')
                .fontSize(12)
                .fontColor(this.editable && this.selectionCount >= 2 ? COLORS.ink : COLORS.muted)
            }
            WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
          }.alignItems(VerticalAlign.Center)
        }
        .height(30)
        .padding({ left: 7, right: 7 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .enabled(this.editable && this.selectionCount >= 2)
        .opacity(this.editable && this.selectionCount >= 2 ? 1 : 0.42)
        .focusable(false)
        .bindTips('选中至少 2 个图形后执行左/中/右/上/下对齐')
        .bindMenu(this.alignQuickMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))

        Button({ type: ButtonType.Normal }) {
          Row({ space: 3 }) {
            WorkbenchIcon({ name: 'union', iconSize: 15, color: this.editable ? COLORS.ink : COLORS.muted })
            if (!this.compactMode) {
              Text('布尔')
                .fontSize(12)
                .fontColor(this.editable ? COLORS.ink : COLORS.muted)
            }
            WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
          }.alignItems(VerticalAlign.Center)
        }
        .height(30)
        .padding({ left: 7, right: 7 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 0.8, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .enabled(this.editable)
        .opacity(this.editable ? 1 : 0.42)
        .focusable(false)
        .bindTips('多边形布尔合并 / 相减 / 预览')
        .bindMenu(this.booleanQuickMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))

        CanvasToolbarIconButton({
          icon: 'trace',
          label: '电气网络连通追踪',
          actionEnabled: true,
          activateAction: this.traceAction
        })

        Divider().vertical(true).height(18).color(COLORS.border)

        // 5. 官方 ArkUI Chip 绘制辅助开关组（外层 Row 承载间距，不挂载通用属性）
        Row({ space: 5 }) {
          Chip({
            prefixSymbol: {
              normal: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')).fontSize(13).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.checkmark_circle')).fontSize(13).fontColor([COLORS.primary])
            },
            label: {
              text: '加选',
              fontSize: 11.5,
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
              normal: new SymbolGlyphModifier($r('sys.symbol.grid')).fontSize(13).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.grid')).fontSize(13).fontColor([COLORS.primary])
            },
            label: {
              text: '网格',
              fontSize: 11.5,
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
              normal: new SymbolGlyphModifier($r('sys.symbol.scope')).fontSize(13).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.scope')).fontSize(13).fontColor([COLORS.primary])
            },
            label: {
              text: '磁吸',
              fontSize: 11.5,
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
              normal: new SymbolGlyphModifier($r('sys.symbol.stroke_path')).fontSize(13).fontColor([COLORS.muted]),
              activated: new SymbolGlyphModifier($r('sys.symbol.stroke_path')).fontSize(13).fontColor([COLORS.primary])
            },
            label: {
              text: this.routingModeLabel,
              fontSize: 11.5,
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

        // 6. 当前激活绘制层指示胶囊（直显层色与层号，点击调整图层样式）
        if (this.activeLayerNumber >= 0) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              Row()
                .width(10)
                .height(10)
                .borderRadius(2.5)
                .backgroundColor(this.activeLayerColor)
                .border({ width: 0.8, color: COLORS.border })
              Text(`L${this.activeLayerNumber}/${this.activeDatatype}`)
                .fontSize(11)
                .fontFamily(FONT_MONO)
                .fontWeight(FontWeight.Medium)
                .fontColor(COLORS.primary)
              if (!this.compactMode && this.activeLayerLabel.length > 0) {
                Text(this.activeLayerLabel)
                  .fontSize(11)
                  .fontColor(COLORS.ink)
                  .maxLines(1)
                  .constraintSize({ maxWidth: 72 })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
              }
            }.alignItems(VerticalAlign.Center)
          }
          .height(30)
          .padding({ left: 8, right: 8 })
          .backgroundColor(COLORS.primarySoft)
          .border({ width: 0.8, color: COLORS.primary })
          .borderRadius(UI.controlRadius)
          .focusable(false)
          .bindTips('当前绘制图层（点击打开图层颜色与填充样式面板）')
          .onClick(() => this.openLayerStyleAction())
        }
      }
      .height(40)
      .padding({ left: 8, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .layoutWeight(1)
    .align(Alignment.Start)
  }
}
