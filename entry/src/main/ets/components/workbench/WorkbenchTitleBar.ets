import { COLORS } from '../../common/constants';
import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { WorkModule } from '../../workbench/WorkbenchModels';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { menuIcon, menuSubmenuArrow, menuCheckIcon, menuStyle, MENU_ITEM_STYLE } from '../../common/WorkbenchMenuStyle';
import { feedbackCurve, MOTION, motionDuration, MotionSettings, USER_REDUCE_MOTION_KEY } from '../../common/Motion';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState, LuminousLightLevel } from '../../store/ThemeStore';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 鸿图主界面标题栏（四层沉浸光感材质 × 按模块收敛控件 × 原生菜单收口）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct WorkbenchTitleBar {
  @StorageProp(USER_REDUCE_MOTION_KEY) userReduceMotion: boolean = false;
  @Prop showAiPanel: boolean = false;
  @Prop aiRunning: boolean = false;
  @Prop aiPending: boolean = false;
  @Prop showMacroPanel: boolean = false;
  @Prop currentModule: WorkModule = WorkModule.Layout;
  @Prop drcIssueCount: number = 0;
  @Prop viewMode: string = '编辑';
  @Prop isCompact: boolean = false;
  @Prop isDesktop: boolean = false;
  @Prop narrowWindow: boolean = false;
  @Prop fileName: string = '';
  @Prop cellName: string = '';
  @Prop documentDirty: boolean = false;
  @Prop sidebarVisible: boolean = true;
  @Prop inspectorVisible: boolean = true;
  @Prop zoomPercent: number = 100;
  @Prop canUndo: boolean = false;
  @Prop canRedo: boolean = false;
  undoAction: () => void = () => {};
  redoAction: () => void = () => {};
  zoomAction: (delta: number) => void = () => {};
  newFileAction: () => void = () => {};
  openFileAction: () => void = () => {};
  recentFilesAction: () => void = () => {};
  saveAction: () => void = () => {};
  saveAsAction: () => void = () => {};
  shareLayoutAction: () => void = () => {};
  projectAction: () => void = () => {};
  searchAction: () => void = () => {};
  commandSearchAction: () => void = () => {};
  libraryAction: () => void = () => {};
  compareAction: () => void = () => {};
  technologyAction: () => void = () => {};
  verificationAction: () => void = () => {};
  fitAction: () => void = () => {};
  runDrcAction: () => void = () => {};
  toggleMacroAction: () => void = () => {};
  toggleAiAction: () => void = () => {};
  openAppearanceAction: () => void = () => {};
  selectModuleAction: (module: WorkModule, label: string) => void = () => {};
  setViewModeAction: (mode: string) => void = () => {};
  resetViewAction: () => void = () => {};
  savePresetAction: () => void = () => {};
  viewWorkspaceAction: () => void = () => {};
  rdbReviewAction: () => void = () => {};
  toggleSidebarAction: () => void = () => {};
  toggleInspectorAction: () => void = () => {};

  private touchModuleTitle(): string {
    if (this.currentModule === WorkModule.Verify) {
      return '验证';
    }
    if (this.currentModule === WorkModule.Data) {
      return '数据';
    }
    return '版图';
  }

  @Builder
  private desktopMenu() {
    Menu() {
      MenuItem({ content: '文档与工程', symbolStartIcon: menuIcon('document'), builder: this.documentMenu, symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '查找与器件', symbolStartIcon: menuIcon('search'), builder: this.searchMenu, symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '工艺与验证', symbolStartIcon: menuIcon('verify'), builder: this.verificationMenu, symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '辅助与外观', symbolStartIcon: menuIcon('appearance'), builder: this.assistantMenu, symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      if (this.currentModule !== WorkModule.Data) {
        MenuItem({ content: '视图与面板', symbolStartIcon: menuIcon('view'), builder: this.viewMenu, symbolEndIcon: menuSubmenuArrow() })
          .attributeModifier(MENU_ITEM_STYLE)
      }
    }
    .attributeModifier(menuStyle(this.desktopMenuSizingItems(), this.getUIContext(), this.desktopMenuSizingChildren()))
  }

  private desktopMenuSizingItems(): MenuItemOptions[] {
    const items: MenuItemOptions[] = [
      { content: '文档与工程', symbolStartIcon: menuIcon('document'), builder: this.documentMenu, symbolEndIcon: menuSubmenuArrow() },
      { content: '查找与器件', symbolStartIcon: menuIcon('search'), builder: this.searchMenu, symbolEndIcon: menuSubmenuArrow() },
      { content: '工艺与验证', symbolStartIcon: menuIcon('verify'), builder: this.verificationMenu, symbolEndIcon: menuSubmenuArrow() },
      { content: '辅助与外观', symbolStartIcon: menuIcon('appearance'), builder: this.assistantMenu, symbolEndIcon: menuSubmenuArrow() }
    ];
    if (this.currentModule !== WorkModule.Data) {
      items.push({ content: '视图与面板', symbolStartIcon: menuIcon('view'), builder: this.viewMenu, symbolEndIcon: menuSubmenuArrow() });
    }
    return items;
  }

  private desktopMenuSizingChildren(): MenuItemOptions[][] {
    const children: MenuItemOptions[][] = [
      this.documentMenuSizing(), this.searchMenuSizing(),
      this.verificationMenuSizing(), this.assistantMenuSizing()
    ];
    if (this.currentModule !== WorkModule.Data) {
      children.push(this.viewMenuSizing());
    }
    return children;
  }

  @Builder
  private documentMenu() {
    Menu() {
      MenuItemGroup({ header: '打开与新建' }) {
        MenuItem({ content: '新建版图', symbolStartIcon: menuIcon('new') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.newFileAction())
        MenuItem({ content: '打开版图…', labelInfo: 'Ctrl+O', symbolStartIcon: menuIcon('open') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.openFileAction())
        MenuItem({ content: '最近打开', symbolStartIcon: menuIcon('recent') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.recentFilesAction())
      }
      MenuItemGroup({ header: '保存与工程' }) {
        MenuItem({ content: '保存版图', labelInfo: 'Ctrl+S', symbolStartIcon: menuIcon('save') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.saveAction())
        MenuItem({ content: '版图另存为…', labelInfo: 'Ctrl+Shift+S', symbolStartIcon: menuIcon('saveAs') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.saveAsAction())
        MenuItem({ content: '分享版图快照…', symbolStartIcon: menuIcon('export') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.shareLayoutAction())
        MenuItem({ content: '工程与历史', labelInfo: 'Ctrl+N', symbolStartIcon: menuIcon('project') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.projectAction())
      }
    }
    .attributeModifier(menuStyle(this.documentMenuSizing(), this.getUIContext()))
  }

  private documentMenuSizing(): MenuItemOptions[] {
    return [
      { content: '新建版图', symbolStartIcon: menuIcon('new') },
      { content: '打开版图…', labelInfo: 'Ctrl+O', symbolStartIcon: menuIcon('open') },
      { content: '最近打开', symbolStartIcon: menuIcon('recent') },
      { content: '保存版图', labelInfo: 'Ctrl+S', symbolStartIcon: menuIcon('save') },
      { content: '版图另存为…', labelInfo: 'Ctrl+Shift+S', symbolStartIcon: menuIcon('saveAs') },
      { content: '分享版图快照…', symbolStartIcon: menuIcon('export') },
      { content: '工程与历史', labelInfo: 'Ctrl+N', symbolStartIcon: menuIcon('project') }
    ];
  }

  @Builder
  private searchMenu() {
    Menu() {
      MenuItemGroup({ header: '查找' }) {
        MenuItem({ content: '搜索与筛选', labelInfo: 'Ctrl+F', symbolStartIcon: menuIcon('search') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.searchAction())
        MenuItem({ content: '搜索命令…', labelInfo: 'Ctrl+K', symbolStartIcon: menuIcon('command') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.commandSearchAction())
      }
      MenuItemGroup({ header: '器件库' }) {
        MenuItem({ content: '个人器件库', symbolStartIcon: menuIcon('library') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.libraryAction())
      }
    }
    .attributeModifier(menuStyle(this.searchMenuSizing(), this.getUIContext()))
  }

  private searchMenuSizing(): MenuItemOptions[] {
    return [
      { content: '搜索与筛选', labelInfo: 'Ctrl+F', symbolStartIcon: menuIcon('search') },
      { content: '搜索命令…', labelInfo: 'Ctrl+K', symbolStartIcon: menuIcon('command') },
      { content: '个人器件库', symbolStartIcon: menuIcon('library') }
    ];
  }

  @Builder
  private verificationMenu() {
    Menu() {
      MenuItemGroup({ header: '工艺与规则' }) {
        MenuItem({ content: '工艺管理', symbolStartIcon: menuIcon('technology') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.technologyAction())
        MenuItem({ content: '工艺 DRC / LVS', symbolStartIcon: menuIcon('verify') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.verificationAction())
      }
      MenuItemGroup({ header: '检查与比较' }) {
        MenuItem({ content: '运行 DRC', symbolStartIcon: menuIcon('verify') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.runDrcAction())
        MenuItem({ content: 'RDB 报告审阅…', symbolStartIcon: menuIcon('verify') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.rdbReviewAction())
        MenuItem({ content: '版图比较', symbolStartIcon: menuIcon('compare') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.compareAction())
      }
    }
    .attributeModifier(menuStyle(this.verificationMenuSizing(), this.getUIContext()))
  }

  private verificationMenuSizing(): MenuItemOptions[] {
    return [
      { content: '工艺管理', symbolStartIcon: menuIcon('technology') },
      { content: '工艺 DRC / LVS', symbolStartIcon: menuIcon('verify') },
      { content: '运行 DRC', symbolStartIcon: menuIcon('verify') },
      { content: 'RDB 报告审阅…', symbolStartIcon: menuIcon('verify') },
      { content: '版图比较', symbolStartIcon: menuIcon('compare') }
    ];
  }

  @Builder
  private assistantMenu() {
    Menu() {
      MenuItemGroup({ header: '辅助面板' }) {
        MenuItem({ content: 'AI 助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.showAiPanel) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.showAiPanel).onClick(() => this.toggleAiAction())
        MenuItem({ content: '宏面板', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.showMacroPanel) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.showMacroPanel).onClick(() => this.toggleMacroAction())
      }
      MenuItemGroup({ header: '外观与光感' }) {
        MenuItem({ content: '外观与沉浸光感…', symbolStartIcon: menuIcon('sparkles') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.openAppearanceAction())
        MenuItem({ content: '减少动态效果', symbolStartIcon: menuIcon('view'), symbolEndIcon: menuCheckIcon(this.userReduceMotion) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.userReduceMotion).id('reduce-motion')
          .onClick(() => MotionSettings.setUserReduced(!this.userReduceMotion))
      }
    }
    .attributeModifier(menuStyle(this.assistantMenuSizing(), this.getUIContext()))
  }

  private assistantMenuSizing(): MenuItemOptions[] {
    return [
      { content: 'AI 助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.showAiPanel) },
      { content: '宏面板', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.showMacroPanel) },
      { content: '外观与沉浸光感…', symbolStartIcon: menuIcon('sparkles') },
      { content: '减少动态效果', symbolStartIcon: menuIcon('view'), symbolEndIcon: menuCheckIcon(this.userReduceMotion) }
    ];
  }

  @Builder
  private viewMenu() {
    Menu() {
      MenuItemGroup({ header: '视图' }) {
        MenuItem({ content: '编辑模式', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode !== '查看') })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.viewMode !== '查看')
          .onClick(() => this.setViewModeAction(this.viewMode === '查看' ? '编辑' : '查看'))
        MenuItem({ content: '适配全部', labelInfo: 'F', symbolStartIcon: menuIcon('view') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.fitAction())
        MenuItem({ content: '重置视图', symbolStartIcon: menuIcon('reset') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.resetViewAction())
        MenuItem({ content: '保存视图预设…', symbolStartIcon: menuIcon('preset') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.savePresetAction())
        MenuItem({ content: '视图与书签…', symbolStartIcon: menuIcon('view') })
          .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.viewWorkspaceAction())
      }
      MenuItemGroup({ header: '面板' }) {
        MenuItem({ content: '图层 / Cell 面板',
          symbolStartIcon: menuIcon('sidebar'), symbolEndIcon: menuCheckIcon(this.sidebarVisible) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.sidebarVisible).onClick(() => this.toggleSidebarAction())
        MenuItem({ content: '属性面板',
          symbolStartIcon: menuIcon('inspector'), symbolEndIcon: menuCheckIcon(this.inspectorVisible) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.inspectorVisible).onClick(() => this.toggleInspectorAction())
      }
    }
    .attributeModifier(menuStyle(this.viewMenuSizing(), this.getUIContext()))
  }

  private viewMenuSizing(): MenuItemOptions[] {
    return [
      { content: '编辑模式', symbolStartIcon: menuIcon('edit'), symbolEndIcon: menuCheckIcon(this.viewMode !== '查看') },
      { content: '适配全部', labelInfo: 'F', symbolStartIcon: menuIcon('view') },
      { content: '重置视图', symbolStartIcon: menuIcon('reset') },
      { content: '保存视图预设…', symbolStartIcon: menuIcon('preset') },
      { content: '视图与书签…', symbolStartIcon: menuIcon('view') },
      { content: '图层 / Cell 面板', symbolStartIcon: menuIcon('sidebar'), symbolEndIcon: menuCheckIcon(this.sidebarVisible) },
      { content: '属性面板', symbolStartIcon: menuIcon('inspector'), symbolEndIcon: menuCheckIcon(this.inspectorVisible) }
    ];
  }

  @Builder
  private desktopBar() {
    Row() {
      Row({ space: 9 }) {
        Row() {
          WorkbenchIcon({ name: 'layout', iconSize: 20, color: '#FFFFFF' })
        }
        .width(32)
        .height(32)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .linearGradient({ angle: 135, colors: [['#0A73F6', 0.0], ['#2984FF', 1.0]] })
        .borderRadius(UI.controlRadius)
        Text('鸿图').fontSize(18).fontWeight(FontWeight.Bold).fontColor(COLORS.ink)
        if (!this.narrowWindow) {
          Text('HongTu EDA').fontSize(15).fontWeight(FontWeight.Medium).fontColor(COLORS.muted)
        }
      }
      .alignItems(VerticalAlign.Center)

      Blank()

      if (this.currentModule !== WorkModule.Data) {
        PanelToggle({ active: this.sidebarVisible, flip: false, activateAction: this.toggleSidebarAction })
          .margin({ right: 6 })
        PanelToggle({ active: this.inspectorVisible, flip: true, activateAction: this.toggleInspectorAction })
          .margin({ right: 12 })
        Button({ type: ButtonType.Normal }) {
          Row({ space: 8 }) {
            WorkbenchIcon({ name: 'search', iconSize: 16, color: COLORS.muted })
            if (!this.narrowWindow) {
              Text('搜索命令（层、选择、测量…）').fontSize(UI.fontBody).fontColor(COLORS.muted)
              Text('Ctrl+K').fontSize(10).fontFamily(FONT_MONO).fontColor(COLORS.muted)
            }
          }
        }
        .height(UI.controlHeight)
        .padding({ left: 12, right: 12 })
        .margin({ right: 12 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .attributeModifier(hongTuThemeState.luminousPointLightModifier())
        .hoverEffect(HoverEffect.Highlight)
        .accessibilityText('搜索命令 Ctrl+K')
        .onClick(() => this.commandSearchAction())
      }

      Button({ type: ButtonType.Normal }) {
        Row({ space: 7 }) {
          if (this.aiRunning) {
            LoadingProgress().width(15).height(15).color(COLORS.primary)
          } else {
            WorkbenchIcon({ name: 'ai', iconSize: 18, color: (this.showAiPanel || this.aiPending) ? COLORS.primary : COLORS.ink })
          }
          Text(this.aiRunning ? 'AI 绘图中' : (this.aiPending ? 'AI 待确认' : 'AI 助手'))
            .fontSize(UI.fontBody)
            .fontWeight(FontWeight.Medium)
            .fontColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primary : COLORS.ink)
          if (this.aiPending && !this.aiRunning) {
            Circle({ width: 6, height: 6 }).fill('#14B8A6')
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(UI.controlHeight)
      .padding({ left: 14, right: 14 })
      .borderRadius(UI.controlRadius)
      .animation(null)
      .backgroundColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primarySoft : COLORS.surfaceMuted)
      .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
      .animation(null)
      .border({ width: 1, color: (this.showAiPanel || this.aiRunning) ? COLORS.primary : (this.aiPending ? '#14B8A6' : COLORS.border) })
      .borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier(LuminousLightLevel.EMPHASIS))
      .stateEffect(true)
      .hoverEffect(HoverEffect.Highlight)
      .focusable(true)
      .focusBox({ strokeColor: ColorMetrics.resourceColor(COLORS.primary), strokeWidth: LengthMetrics.vp(2) })
      .accessibilityText('AI 助手')
      .accessibilitySelected(this.showAiPanel)
      .bindTips('AI 助手')
      .onClick(() => this.toggleAiAction())

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'appearance', iconSize: 18, color: COLORS.ink })
      }
      .width(UI.controlHeight)
      .height(UI.controlHeight)
      .padding(0)
      .margin({ left: 10 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .accessibilityText('外观与沉浸光感')
      .bindTips('外观与沉浸光感')
      .onClick(() => this.openAppearanceAction())

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'menu', iconSize: 20, color: COLORS.ink })
      }
      .width(UI.controlHeight)
      .height(UI.controlHeight)
      .padding(0)
      .margin({ left: 8 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .accessibilityText('更多功能')
      .bindTips('更多功能')
      .stateEffect(true)
      .hoverEffect(HoverEffect.Highlight)
      .focusable(true)
      .focusBox({ strokeColor: ColorMetrics.resourceColor(COLORS.primary), strokeWidth: LengthMetrics.vp(2) })
      .bindMenu(this.desktopMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .height(UI.titleBarHeight)
    .width('100%')
    .padding({ left: 18, right: 16 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }

  @Builder
  private touchBar() {
    Row({ space: 8 }) {
      Text(this.touchModuleTitle())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLORS.ink)
        .layoutWeight(1)
        .maxLines(1)
      GhostCommand({ icon: 'open', label: '打开', showLabel: !this.isCompact, activateAction: this.openFileAction })
      if (this.currentModule !== WorkModule.Data) {
        GhostCommand({ icon: 'search', label: '搜索命令', showLabel: false, activateAction: this.commandSearchAction })
        GhostCommand({ icon: 'save', label: '保存', showLabel: false, activateAction: this.saveAction })
      }
      Button({ type: ButtonType.Circle }) {
        if (this.aiRunning) {
          LoadingProgress().width(16).height(16).color(COLORS.primary)
        } else {
          WorkbenchIcon({ name: 'ai', iconSize: 18, color: (this.showAiPanel || this.aiPending) ? COLORS.primary : COLORS.ink })
        }
      }
      .width(UI.controlHeight)
      .height(UI.controlHeight)
      .padding(0)
      .backgroundColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 1, color: (this.showAiPanel || this.aiRunning) ? COLORS.primary : (this.aiPending ? '#14B8A6' : COLORS.border) })
      .accessibilityText('AI 助手')
      .onClick(() => this.toggleAiAction())
      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'appearance', iconSize: 18, color: COLORS.ink })
      }
      .width(UI.controlHeight)
      .height(UI.controlHeight)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .accessibilityText('外观与沉浸光感')
      .onClick(() => this.openAppearanceAction())
      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'menu', iconSize: 20, color: COLORS.ink })
      }
      .width(UI.controlHeight)
      .height(UI.controlHeight)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border })
      .accessibilityText('更多功能')
      .bindMenu(this.desktopMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }

  build() {
    if (this.isDesktop) {
      this.desktopBar()
    } else {
      this.touchBar()
    }
  }
}

@Component
struct PanelToggle {
  @Prop active: boolean = false;
  @Prop flip: boolean = false;
  activateAction: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      WorkbenchIcon({
        name: this.flip ? (this.active ? 'chevronLeft' : 'chevronRight') : 'menu',
        iconSize: 18,
        color: this.active ? COLORS.primary : COLORS.muted
      })
    }
    .width(UI.compactControlHeight)
    .height(UI.compactControlHeight)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .animation(null)
    .backgroundColor(this.active ? COLORS.primarySoft : Color.Transparent)
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(true)
    .focusBox({ strokeColor: ColorMetrics.resourceColor(COLORS.primary), strokeWidth: LengthMetrics.vp(2) })
    .accessibilityText(this.flip ? '属性面板' : '图层与 Cell 面板')
    .accessibilitySelected(this.active)
    .bindTips(this.flip ? '显示或收起属性面板' : '显示或收起图层与 Cell 面板')
    .onClick(() => this.activateAction())
  }
}

@Component
struct GhostCommand {
  @Prop icon: string = '';
  @Prop label: string = '';
  @Prop showLabel: boolean = true;
  activateAction: () => void = () => {};

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        WorkbenchIcon({ name: this.icon, iconSize: 18, color: COLORS.ink })
        if (this.showLabel) {
          Text(this.label)
            .fontSize(UI.fontBody)
            .fontColor(COLORS.ink)
            .fontWeight(FontWeight.Medium)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(UI.compactControlHeight)
    .constraintSize({ minWidth: UI.compactControlHeight })
    .padding({ left: 9, right: 9 })
    .borderRadius(UI.controlRadius)
    .backgroundColor(Color.Transparent)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(true)
    .focusBox({ strokeColor: ColorMetrics.resourceColor(COLORS.primary), strokeWidth: LengthMetrics.vp(2) })
    .accessibilityText(this.label)
    .bindTips(this.label)
    .onClick(() => this.activateAction())
  }
}
