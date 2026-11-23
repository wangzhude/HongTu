import { COLORS } from '../../common/constants';
import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { WorkModule } from '../../workbench/WorkbenchModels';
import { WorkspaceTab } from '../../services/WorkspaceService';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { menuIcon, menuSubmenuArrow, menuCheckIcon, menuStyle, MENU_ITEM_STYLE } from '../../common/WorkbenchMenuStyle';
import { feedbackCurve, MOTION, motionDuration, MotionSettings, USER_REDUCE_MOTION_KEY } from '../../common/Motion';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { hongTuThemeState, LuminousLightLevel } from '../../store/ThemeStore';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { WorkbenchIcon } from './WorkbenchIcon';
import {
  DpiScalePreset,
  HONGTU_AUTO_LANDSCAPE_DESKTOP_KEY,
  HONGTU_CUSTOM_DPI_SCALE_KEY,
  HONGTU_DPI_PRESETS,
  HONGTU_EFFECTIVE_DPI_SCALE_KEY,
  HONGTU_FORCE_DESKTOP_MODE_KEY,
  HONGTU_WINDOW_IS_LANDSCAPE_KEY,
  setWorkspaceAutoLandscapeDesktop,
  setWorkspaceCustomDpiScale,
  setWorkspaceForceDesktopMode,
  toggleWorkspaceOrientation
} from '../../common/WorkspaceAdaptation';

/**
 * 鸿图主界面一体化高密度原生顶栏（v8 上侧空间全面利用版）
 *
 * 1. 桌面/平板横屏模式下将多文档标签栏（`tabs`）直接内联进顶栏左侧，省去原先整整一行 40vp 空白标签条；
 * 2. 将原先 600vp+ 闲置空白区升级为高频工程快操带：打开、保存（带未保存脏标记）、器件库、端侧 Python、一键 DRC（带违规计数徽章）、全局命令搜索（Ctrl+K）；
 * 3. 左右侧边栏开关统一采用鸿蒙原生分栏符号（`rectangle_lefthalf_inset_filled` / `rectangle_righthalf_inset_filled`）；
 * 4. 竖屏触控模式下直显当前文档与编辑 Cell 身份胶囊及打开/保存/Python/DRC 一键入口。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct WorkbenchTitleBar {
  @StorageProp(USER_REDUCE_MOTION_KEY) userReduceMotion: boolean = false;
  @StorageProp(HONGTU_CUSTOM_DPI_SCALE_KEY) customDpiScale: number = 0;
  @StorageProp(HONGTU_EFFECTIVE_DPI_SCALE_KEY) effectiveDpiScale: number = 1;
  @StorageProp(HONGTU_AUTO_LANDSCAPE_DESKTOP_KEY) autoLandscapeDesktop: boolean = true;
  @StorageProp(HONGTU_FORCE_DESKTOP_MODE_KEY) forceDesktopMode: boolean = false;
  @StorageProp(HONGTU_WINDOW_IS_LANDSCAPE_KEY) windowIsLandscape: boolean = false;
  @Prop showAiPanel: boolean = false;
  @Prop aiRunning: boolean = false;
  @Prop aiPending: boolean = false;
  @Prop showMacroPanel: boolean = false;
  @Prop showPythonPanel: boolean = false;
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
  @Prop @Watch('onTabsOrActiveTabChanged') tabs: WorkspaceTab[] = [];
  @Prop @Watch('onTabsOrActiveTabChanged') activeTabId: string = '';
  private tabScroller: Scroller = new Scroller();

  onTabsOrActiveTabChanged(): void {
    const activeIdx: number = this.tabs.findIndex((t: WorkspaceTab): boolean => t.id === this.activeTabId);
    if (activeIdx < 0) return;
    setTimeout(() => {
      try {
        if (activeIdx === this.tabs.length - 1) {
          this.tabScroller.scrollEdge(Edge.End);
        } else if (activeIdx === 0) {
          this.tabScroller.scrollEdge(Edge.Start);
        }
      } catch (_) {}
    }, 16);
  }

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
  openPythonAction: () => void = () => {};
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
  selectTabAction: (id: string) => void = (_id: string) => {};
  closeTabAction: (id: string) => void = (_id: string) => {};

  private touchModuleTitle(): string {
    if (this.currentModule === WorkModule.Verify) {
      return '验证';
    }
    if (this.currentModule === WorkModule.Data) {
      return '数据';
    }
    return '版图';
  }

  private dpiBadgeLabel(): string {
    const pct: number = Math.round((this.effectiveDpiScale > 0 ? this.effectiveDpiScale : 1) * 100);
    return `${pct}%`;
  }

  private isPresetSelected(presetScale: number): boolean {
    if (presetScale === 0) {
      return this.customDpiScale === 0;
    }
    return Math.abs(this.customDpiScale - presetScale) < 0.01;
  }

  private dpiMenuSizing(): MenuItemOptions[] {
    const items: MenuItemOptions[] = HONGTU_DPI_PRESETS.map((p: DpiScalePreset): MenuItemOptions => ({
      content: p.scale === 0 ? `${p.label}（当前 ${this.dpiBadgeLabel()}）` : `缩放 ${p.label}`,
      labelInfo: p.desc,
      symbolStartIcon: menuIcon('view'),
      symbolEndIcon: menuCheckIcon(this.isPresetSelected(p.scale))
    }));
    items.push({
      content: '旋转横屏自动切换 PC 桌面布局',
      symbolStartIcon: menuIcon('layout'),
      symbolEndIcon: menuCheckIcon(this.autoLandscapeDesktop)
    });
    items.push({
      content: this.windowIsLandscape ? '切换回竖屏触控方向' : '一键横屏进入 PC 桌面布局',
      symbolStartIcon: menuIcon('reset')
    });
    items.push({
      content: '竖屏也强制启用 PC 桌面布局',
      symbolStartIcon: menuIcon('sidebar'),
      symbolEndIcon: menuCheckIcon(this.forceDesktopMode)
    });
    return items;
  }

  @Builder
  private dpiQuickMenu() {
    Menu() {
      MenuItemGroup({ header: '界面缩放 (DPI) 快捷调节' }) {
        ForEach(HONGTU_DPI_PRESETS, (preset: DpiScalePreset) => {
          MenuItem({
            content: preset.scale === 0 ? `${preset.label}（当前 ${this.dpiBadgeLabel()}）` : `缩放 ${preset.label}`,
            labelInfo: preset.desc,
            symbolStartIcon: menuIcon('view'),
            symbolEndIcon: menuCheckIcon(this.isPresetSelected(preset.scale))
          })
            .attributeModifier(MENU_ITEM_STYLE)
            .selected(this.isPresetSelected(preset.scale))
            .onClick(() => {
              setWorkspaceCustomDpiScale(preset.scale);
            })
        }, (preset: DpiScalePreset): string => `dpi_${preset.scale}_${this.customDpiScale}_${this.effectiveDpiScale}`)
      }
      MenuItemGroup({ header: '横竖屏与 PC 工作台布局' }) {
        MenuItem({
          content: '旋转横屏自动切换 PC 桌面布局',
          symbolStartIcon: menuIcon('layout'),
          symbolEndIcon: menuCheckIcon(this.autoLandscapeDesktop)
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.autoLandscapeDesktop)
          .onClick(() => {
            setWorkspaceAutoLandscapeDesktop(!this.autoLandscapeDesktop);
          })
        MenuItem({
          content: this.windowIsLandscape ? '切换回竖屏触控方向' : '一键横屏进入 PC 桌面布局',
          symbolStartIcon: menuIcon('reset')
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => {
            toggleWorkspaceOrientation();
          })
        MenuItem({
          content: '竖屏也强制启用 PC 桌面布局',
          symbolStartIcon: menuIcon('sidebar'),
          symbolEndIcon: menuCheckIcon(this.forceDesktopMode)
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.forceDesktopMode)
          .onClick(() => {
            setWorkspaceForceDesktopMode(!this.forceDesktopMode);
          })
      }
    }
    .attributeModifier(menuStyle(this.dpiMenuSizing(), this.getUIContext()))
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
      MenuItem({ content: '脚本与辅助', symbolStartIcon: menuIcon('appearance'), builder: this.assistantMenu, symbolEndIcon: menuSubmenuArrow() })
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
      { content: '脚本与辅助', symbolStartIcon: menuIcon('appearance'), builder: this.assistantMenu, symbolEndIcon: menuSubmenuArrow() }
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
      MenuItemGroup({ header: '智能与脚本工作台' }) {
        MenuItem({ content: 'AI 视觉助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.showAiPanel) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.showAiPanel).onClick(() => this.toggleAiAction())
        MenuItem({ content: '端侧 Python 3 脚本台', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.showPythonPanel) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.showPythonPanel).onClick(() => this.openPythonAction())
        MenuItem({ content: '宏录制与批处理', symbolStartIcon: menuIcon('library'), symbolEndIcon: menuCheckIcon(this.showMacroPanel) })
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
      { content: 'AI 视觉助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.showAiPanel) },
      { content: '端侧 Python 3 脚本台', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.showPythonPanel) },
      { content: '宏录制与批处理', symbolStartIcon: menuIcon('library'), symbolEndIcon: menuCheckIcon(this.showMacroPanel) },
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
        MenuItem({ content: '左侧图层 / Cell 面板',
          symbolStartIcon: menuIcon('sidebar'), symbolEndIcon: menuCheckIcon(this.sidebarVisible) })
          .attributeModifier(MENU_ITEM_STYLE).selected(this.sidebarVisible).onClick(() => this.toggleSidebarAction())
        MenuItem({ content: '右侧属性面板',
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
      { content: '左侧图层 / Cell 面板', symbolStartIcon: menuIcon('sidebar'), symbolEndIcon: menuCheckIcon(this.sidebarVisible) },
      { content: '右侧属性面板', symbolStartIcon: menuIcon('inspector'), symbolEndIcon: menuCheckIcon(this.inspectorVisible) }
    ];
  }

  @Builder
  private inlineDocumentTabs() {
    Row({ space: 5 }) {
      Scroll(this.tabScroller) {
        Row({ space: 4 }) {
          ForEach(this.tabs, (tab: WorkspaceTab) => {
            Row({ space: 2 }) {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 5 }) {
                  WorkbenchIcon({
                    name: 'layout',
                    iconSize: 13,
                    color: tab.id === this.activeTabId ? COLORS.primary : COLORS.muted
                  })
                  Text(tab.title)
                    .fontSize(12)
                    .fontWeight(tab.id === this.activeTabId ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(tab.id === this.activeTabId ? COLORS.primary : COLORS.ink)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .constraintSize({ maxWidth: tab.id === this.activeTabId ? 196 : 144 })
                  if (tab.dirty) {
                    DrawnStatusIcon({ kind: 'dirty', iconSize: 8, strokeColor: COLORS.warning, showSoftPlate: false })
                  }
                }.alignItems(VerticalAlign.Center)
              }
              .height(30)
              .padding({ left: 9, right: 4 })
              .backgroundColor(Color.Transparent)
              .focusable(false)
              .accessibilityText(`切换文档 ${tab.title}`)
              .bindTips(tab.title)
              .onClick(() => this.selectTabAction(tab.id))

              if (this.tabs.length > 1) {
                Button({ type: ButtonType.Normal }) {
                  WorkbenchIcon({ name: 'close', iconSize: 11, color: COLORS.muted })
                }
                .width(22)
                .height(22)
                .padding(0)
                .margin({ right: 3 })
                .backgroundColor(Color.Transparent)
                .borderRadius(5)
                .focusable(false)
                .accessibilityText(`关闭 ${tab.title}`)
                .onClick(() => this.closeTabAction(tab.id))
              } else {
                Row().width(4)
              }
            }
            .height(32)
            .alignItems(VerticalAlign.Center)
            .backgroundColor(tab.id === this.activeTabId ? COLORS.primarySoft : COLORS.surfaceMuted)
            .border({
              width: 0.8,
              color: tab.id === this.activeTabId ? COLORS.primary : COLORS.border
            })
            .borderRadius(UI.controlRadius)
          }, (tab: WorkspaceTab): string => `${tab.id}:${tab.title}:${tab.dirty}:${this.activeTabId}:${this.tabs.length}`)
        }
        .padding({ right: 4 })
        .alignItems(VerticalAlign.Center)
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .layoutWeight(1)
      .align(Alignment.Start)

      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: 'plus', iconSize: 15, color: COLORS.muted })
      }
      .width(30)
      .height(30)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .focusable(false)
      .accessibilityText('新建或切换工程版图')
      .bindTips('新建版图 / 工程与历史')
      .onClick(() => this.newFileAction())
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
    .margin({ left: 10, right: 8 })
  }

  @Builder
  private quickHeaderPill(icon: string, label: string, active: boolean, showLabel: boolean, badgeText: string, onTap: () => void) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 4 }) {
        WorkbenchIcon({ name: icon, iconSize: 15, color: active ? COLORS.primary : COLORS.ink })
        if (showLabel) {
          Text(label)
            .fontSize(12)
            .fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
            .fontColor(active ? COLORS.primary : COLORS.ink)
            .maxLines(1)
        }
        if (badgeText.length > 0) {
          Text(badgeText)
            .fontSize(9.5)
            .fontFamily(FONT_MONO)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .backgroundColor(COLORS.danger)
            .borderRadius(999)
        }
      }.alignItems(VerticalAlign.Center)
    }
    .height(32)
    .padding({ left: 8, right: 8 })
    .backgroundColor(active ? COLORS.primarySoft : COLORS.surfaceMuted)
    .border({ width: 0.8, color: active ? COLORS.primary : COLORS.border })
    .borderRadius(UI.controlRadius)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .focusable(false)
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(label)
    .bindTips(label)
    .onClick(() => onTap())
  }

  @Builder
  private desktopBar() {
    Row({ space: 6 }) {
      // 1. 紧凑品牌徽标
      Row({ space: 7 }) {
        Row() {
          WorkbenchIcon({ name: 'layout', iconSize: 17, color: '#FFFFFF' })
        }
        .width(28)
        .height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .linearGradient({ angle: 135, colors: [['#0A73F6', 0.0], ['#2984FF', 1.0]] })
        .borderRadius(7)
        Text('鸿图')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
      }
      .alignItems(VerticalAlign.Center)

      // 2. 内联多文档标签栏（彻底吃掉原先空白横条，释放整行 40vp 垂直高度）
      if (this.currentModule !== WorkModule.Data && this.tabs.length > 0) {
        this.inlineDocumentTabs()
      } else {
        Blank()
      }

      // 3. 上侧高频工程快操组（填补原先顶栏中部大面积空白）
      Row({ space: 5 }) {
        this.quickHeaderPill('open', '打开', false, !this.narrowWindow, '', () => { this.openFileAction(); })
        this.quickHeaderPill('save', this.documentDirty ? '保存*' : '保存', this.documentDirty, !this.narrowWindow, '', () => { this.saveAction(); })
        if (this.currentModule !== WorkModule.Data) {
          this.quickHeaderPill('cell', '器件库', false, !this.narrowWindow, '', () => { this.libraryAction(); })
          this.quickHeaderPill('python', 'Python', this.showPythonPanel, !this.narrowWindow, '', () => { this.openPythonAction(); })
          this.quickHeaderPill(
            'verify',
            'DRC',
            this.drcIssueCount > 0,
            !this.narrowWindow,
            this.drcIssueCount > 0 ? String(Math.min(99, this.drcIssueCount)) : '',
            () => { this.runDrcAction(); }
          )
          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              WorkbenchIcon({ name: 'search', iconSize: 15, color: COLORS.muted })
              if (!this.narrowWindow) {
                Text('命令')
                  .fontSize(12)
                  .fontColor(COLORS.muted)
                Text('Ctrl+K')
                  .fontSize(9.5)
                  .fontFamily(FONT_MONO)
                  .fontColor(COLORS.muted)
              }
            }.alignItems(VerticalAlign.Center)
          }
          .height(32)
          .padding({ left: 9, right: 9 })
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 0.8, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .focusable(false)
          .hoverEffect(HoverEffect.Highlight)
          .accessibilityText('搜索命令 Ctrl+K')
          .bindTips('全局命令面板 (Ctrl+K)')
          .onClick(() => this.commandSearchAction())
        }
      }
      .alignItems(VerticalAlign.Center)

      Divider().vertical(true).height(18).color(COLORS.border).margin({ left: 2, right: 2 })

      // 4. 左右侧栏原生显隐开关 + AI 视觉助手 + DPI + 外观 + 全量菜单
      if (this.currentModule !== WorkModule.Data) {
        PanelToggle({ active: this.sidebarVisible, flip: false, activateAction: this.toggleSidebarAction })
        PanelToggle({ active: this.inspectorVisible, flip: true, activateAction: this.toggleInspectorAction })
      }

      Button({ type: ButtonType.Normal }) {
        Row({ space: 6 }) {
          if (this.aiRunning) {
            LoadingProgress().width(14).height(14).color(COLORS.primary)
          } else {
            WorkbenchIcon({ name: 'ai', iconSize: 16, color: (this.showAiPanel || this.aiPending) ? COLORS.primary : COLORS.ink })
          }
          Text(this.aiRunning ? 'AI 运行中' : (this.aiPending ? 'AI 待确认' : 'AI 助手'))
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primary : COLORS.ink)
          if (this.aiPending && !this.aiRunning) {
            Circle({ width: 6, height: 6 }).fill('#14B8A6')
          }
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(32)
      .padding({ left: 11, right: 11 })
      .borderRadius(UI.controlRadius)
      .animation(null)
      .backgroundColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primarySoft : COLORS.surfaceMuted)
      .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
      .animation(null)
      .border({ width: 0.9, color: (this.showAiPanel || this.aiRunning) ? COLORS.primary : (this.aiPending ? '#14B8A6' : COLORS.border) })
      .attributeModifier(hongTuThemeState.luminousPointLightModifier(LuminousLightLevel.EMPHASIS))
      .stateEffect(true)
      .hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText('AI 助手')
      .accessibilitySelected(this.showAiPanel)
      .bindTips('AI 视觉助手（支持截图自检、自动化与内置 Python）')
      .onClick(() => this.toggleAiAction())

      Button({ type: ButtonType.Normal }) {
        Row({ space: 4 }) {
          WorkbenchIcon({ name: 'dpi', iconSize: 14, color: this.customDpiScale > 0 ? COLORS.primary : COLORS.ink })
          Text(this.dpiBadgeLabel())
            .fontSize(10.5)
            .fontFamily(FONT_MONO)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customDpiScale > 0 ? COLORS.primary : COLORS.ink)
        }.alignItems(VerticalAlign.Center)
      }
      .id('titlebar-dpi-quick-btn')
      .height(32)
      .padding({ left: 8, right: 8 })
      .backgroundColor(this.customDpiScale > 0 ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 0.8, color: this.customDpiScale > 0 ? COLORS.primary : COLORS.border })
      .borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .focusable(false)
      .accessibilityText('快捷调节界面 DPI 缩放与横竖屏布局')
      .bindTips('快捷调节界面 DPI 缩放与横屏桌面布局')
      .bindMenu(this.dpiQuickMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'appearance', iconSize: 16, color: COLORS.ink })
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .focusable(false)
      .accessibilityText('外观与沉浸光感')
      .bindTips('外观与沉浸光感')
      .onClick(() => this.openAppearanceAction())

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'menu', iconSize: 18, color: COLORS.ink })
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .focusable(false)
      .accessibilityText('更多功能')
      .bindTips('更多功能')
      .stateEffect(true)
      .hoverEffect(HoverEffect.Highlight)
      .bindMenu(this.desktopMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .height(46)
    .width('100%')
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { bottom: 0.8 }, color: COLORS.border })
  }

  @Builder
  private touchBar() {
    Row({ space: 6 }) {
      // 左侧紧凑展示当前模块 + 当前文档/编辑 Cell 身份胶囊（点击切换工程/最近文件）
      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          Text(this.touchModuleTitle())
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(COLORS.ink)
          if (this.currentModule !== WorkModule.Data) {
            Text('·')
              .fontSize(13)
              .fontColor(COLORS.muted)
            Text(this.cellName.length > 0 ? this.cellName : (this.fileName.length > 0 ? this.fileName : 'TOP'))
              .fontSize(12)
              .fontFamily(FONT_MONO)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.primary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.documentDirty) {
              DrawnStatusIcon({ kind: 'dirty', iconSize: 8, strokeColor: COLORS.warning, showSoftPlate: false })
            }
          }
        }.alignItems(VerticalAlign.Center)
      }
      .height(34)
      .padding({ left: 4, right: 6 })
      .backgroundColor(Color.Transparent)
      .borderRadius(UI.controlRadius)
      .layoutWeight(1)
      .focusable(false)
      .onClick(() => this.projectAction())

      if (this.currentModule !== WorkModule.Data) {
        PanelToggle({ active: this.sidebarVisible, flip: false, activateAction: this.toggleSidebarAction })
      }
      GhostCommand({ icon: 'open', label: '打开', showLabel: false, activateAction: this.openFileAction })
      if (this.currentModule !== WorkModule.Data) {
        GhostCommand({ icon: 'save', label: '保存', showLabel: false, activateAction: this.saveAction })
        GhostCommand({ icon: 'python', label: 'Python', showLabel: false, activateAction: this.openPythonAction })
      }

      Button({ type: ButtonType.Normal }) {
        Row({ space: 2 }) {
          WorkbenchIcon({ name: 'dpi', iconSize: 13, color: this.customDpiScale > 0 ? COLORS.primary : COLORS.ink })
          Text(this.dpiBadgeLabel())
            .fontSize(9.5)
            .fontFamily(FONT_MONO)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.customDpiScale > 0 ? COLORS.primary : COLORS.ink)
        }.alignItems(VerticalAlign.Center)
      }
      .id('touchbar-dpi-quick-btn')
      .height(32)
      .padding({ left: 7, right: 7 })
      .backgroundColor(this.customDpiScale > 0 ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 0.8, color: this.customDpiScale > 0 ? COLORS.primary : COLORS.border })
      .borderRadius(999)
      .focusable(false)
      .accessibilityText('DPI 缩放与横屏桌面布局')
      .bindMenu(this.dpiQuickMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))

      Button({ type: ButtonType.Circle }) {
        if (this.aiRunning) {
          LoadingProgress().width(15).height(15).color(COLORS.primary)
        } else {
          WorkbenchIcon({ name: 'ai', iconSize: 17, color: (this.showAiPanel || this.aiPending) ? COLORS.primary : COLORS.ink })
        }
      }
      .width(34)
      .height(34)
      .padding(0)
      .backgroundColor((this.showAiPanel || this.aiRunning || this.aiPending) ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 0.8, color: (this.showAiPanel || this.aiRunning) ? COLORS.primary : (this.aiPending ? '#14B8A6' : COLORS.border) })
      .focusable(false)
      .accessibilityText('AI 助手')
      .onClick(() => this.toggleAiAction())

      Button({ type: ButtonType.Circle }) {
        WorkbenchIcon({ name: 'menu', iconSize: 18, color: COLORS.ink })
      }
      .width(34)
      .height(34)
      .padding(0)
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: 0.8, color: COLORS.border })
      .focusable(false)
      .accessibilityText('更多功能')
      .bindMenu(this.desktopMenu, buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius))
    }
    .width('100%')
    .height(50)
    .padding({ left: 10, right: 10 })
    .alignItems(VerticalAlign.Center)
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
        name: this.flip ? 'inspector' : 'sidebar',
        iconSize: 17,
        color: this.active ? COLORS.primary : COLORS.muted
      })
    }
    .width(32)
    .height(32)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .animation(null)
    .backgroundColor(this.active ? COLORS.primarySoft : COLORS.surfaceMuted)
    .border({ width: 0.8, color: this.active ? COLORS.primary : COLORS.border })
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(this.flip ? '右侧属性面板' : '左侧图层与 Cell 面板')
    .accessibilitySelected(this.active)
    .bindTips(this.flip ? '显示或收起右侧属性面板' : '显示或收起左侧图层与 Cell 面板')
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
        WorkbenchIcon({ name: this.icon, iconSize: 16, color: COLORS.ink })
        if (this.showLabel) {
          Text(this.label)
            .fontSize(12)
            .fontColor(COLORS.ink)
            .fontWeight(FontWeight.Medium)
        }
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(32)
    .constraintSize({ minWidth: 32 })
    .padding({ left: 7, right: 7 })
    .borderRadius(UI.controlRadius)
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 0.8, color: COLORS.border })
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(this.label)
    .bindTips(this.label)
    .onClick(() => this.activateAction())
  }
}
