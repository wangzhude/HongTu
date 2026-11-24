import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { MENU_ITEM_STYLE, menuCheckIcon, menuIcon, menuStyle, workbenchLuminousMenuOptions } from '../../common/WorkbenchMenuStyle';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkModule } from '../../workbench/WorkbenchModels';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面专业 EDA 左侧导航侧轨（对齐参考布局：版图编辑 / 验证(DRC) / 数据 / 脚本 / 工艺 / 工具集 / 设置）
 *
 * - 当前主模块（如「版图编辑」）采用高识别度主色实心圆角方块 + 纯白图标与标签；
 * - 辅助抽屉收敛至「脚本」「工艺」「工具集」与底部「设置」，消除杂乱堆叠，保留 100% 业务直达能力。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct DesktopModuleRail {
  @Prop currentModule: WorkModule = WorkModule.Layout;
  @Prop drcIssueCount: number = 0;
  @Prop railWidth: number = UI.railWidth;
  @Prop searchActive: boolean = false;
  @Prop libraryActive: boolean = false;
  @Prop pythonActive: boolean = false;
  @Prop techActive: boolean = false;
  @Prop compareActive: boolean = false;
  @Prop aiActive: boolean = false;
  @Prop macroActive: boolean = false;

  selectModuleAction: (module: WorkModule, label: string) => void = () => {};
  searchAction: () => void = () => {};
  libraryAction: () => void = () => {};
  pythonAction: () => void = () => {};
  technologyAction: () => void = () => {};
  compareAction: () => void = () => {};
  aiAction: () => void = () => {};
  macroAction: () => void = () => {};
  projectAction: () => void = () => {};
  shortcutAction: () => void = () => {};
  openAppearanceAction: () => void = () => {};
  rdbReviewAction: () => void = () => {};
  viewWorkspaceAction: () => void = () => {};

  private isToolkitActive(): boolean {
    return this.searchActive || this.libraryActive || this.compareActive || this.macroActive;
  }

  private toolkitMenuSizing(): MenuItemOptions[] {
    return [
      { content: '搜索与筛选图形', labelInfo: 'Ctrl+F', symbolStartIcon: menuIcon('search'), symbolEndIcon: menuCheckIcon(this.searchActive) },
      { content: '个人器件库与 PCell', symbolStartIcon: menuIcon('pcell'), symbolEndIcon: menuCheckIcon(this.libraryActive) },
      { content: '版图 XOR 差异比较', symbolStartIcon: menuIcon('compare'), symbolEndIcon: menuCheckIcon(this.compareActive) },
      { content: 'RDB 验证报告审阅…', symbolStartIcon: menuIcon('verify') },
      { content: '宏录制与批处理', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.macroActive) },
      { content: '视图与书签工作区…', symbolStartIcon: menuIcon('view') },
      { content: 'AI 视觉智能助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.aiActive) }
    ];
  }

  @Builder
  private buildToolkitMenu() {
    Menu() {
      MenuItemGroup({ header: '查找与器件' }) {
        MenuItem({ content: '搜索与筛选图形', labelInfo: 'Ctrl+F', symbolStartIcon: menuIcon('search'), symbolEndIcon: menuCheckIcon(this.searchActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.searchActive)
          .onClick(() => this.searchAction())
        MenuItem({ content: '个人器件库与 PCell', symbolStartIcon: menuIcon('pcell'), symbolEndIcon: menuCheckIcon(this.libraryActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.libraryActive)
          .onClick(() => this.libraryAction())
      }
      MenuItemGroup({ header: '分析与自动化' }) {
        MenuItem({ content: '版图 XOR 差异比较', symbolStartIcon: menuIcon('compare'), symbolEndIcon: menuCheckIcon(this.compareActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.compareActive)
          .onClick(() => this.compareAction())
        MenuItem({ content: 'RDB 验证报告审阅…', symbolStartIcon: menuIcon('verify') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.rdbReviewAction())
        MenuItem({ content: '宏录制与批处理', symbolStartIcon: menuIcon('macro'), symbolEndIcon: menuCheckIcon(this.macroActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.macroActive)
          .onClick(() => this.macroAction())
        MenuItem({ content: '视图与书签工作区…', symbolStartIcon: menuIcon('view') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.viewWorkspaceAction())
        MenuItem({ content: 'AI 视觉智能助手', symbolStartIcon: menuIcon('ai'), symbolEndIcon: menuCheckIcon(this.aiActive) })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(this.aiActive)
          .onClick(() => this.aiAction())
      }
    }
    .attributeModifier(menuStyle(this.toolkitMenuSizing(), this.getUIContext()))
  }

  private settingsMenuSizing(): MenuItemOptions[] {
    return [
      { content: '外观与沉浸光感设置…', symbolStartIcon: menuIcon('appearance') },
      { content: '工程与历史快照', labelInfo: 'Ctrl+N', symbolStartIcon: menuIcon('project') },
      { content: '键盘快捷键与助记码', symbolStartIcon: menuIcon('command') }
    ];
  }

  @Builder
  private buildSettingsMenu() {
    Menu() {
      MenuItemGroup({ header: '工作台偏好与工程' }) {
        MenuItem({ content: '外观与沉浸光感设置…', symbolStartIcon: menuIcon('appearance') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.openAppearanceAction())
        MenuItem({ content: '工程与历史快照', labelInfo: 'Ctrl+N', symbolStartIcon: menuIcon('project') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.projectAction())
        MenuItem({ content: '键盘快捷键与助记码', symbolStartIcon: menuIcon('command') })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => this.shortcutAction())
      }
    }
    .attributeModifier(menuStyle(this.settingsMenuSizing(), this.getUIContext()))
  }

  build() {
    Column({ space: 6 }) {
      Scroll() {
        Column({ space: 8 }) {
          this.moduleButton(WorkModule.Layout, '版图编辑', '版图编辑工作区', 'layout')
          this.moduleButton(WorkModule.Verify, '验证\n(DRC)', 'DRC / LVS 验证工作区', 'drcShield')
          this.moduleButton(WorkModule.Data, '数据', '版图文件与单元库总览', 'data')

          this.railActionButton('python', '脚本', '端侧内置 Python 3 脚本工作台', this.pythonActive, () => {
            this.pythonAction();
          })

          this.railActionButton('layers', '工艺', '工艺文件管理与 2.5D 截面叠层', this.techActive, () => {
            this.technologyAction();
          })

          Button({ type: ButtonType.Normal }) {
            Column({ space: 4 }) {
              WorkbenchIcon({
                name: 'tools',
                iconSize: 19,
                color: this.isToolkitActive() ? COLORS.primary : COLORS.ink
              })
              Text('工具集')
                .fontSize(10.5)
                .fontWeight(this.isToolkitActive() ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(this.isToolkitActive() ? COLORS.primary : COLORS.ink)
            }
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
          .width(48)
          .height(50)
          .padding(0)
          .borderRadius(10)
          .backgroundColor(this.isToolkitActive() ? COLORS.primarySoft : Color.Transparent)
          .border({ width: this.isToolkitActive() ? 0.8 : 0, color: this.isToolkitActive() ? COLORS.primary : Color.Transparent })
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .hoverEffect(HoverEffect.Highlight)
          .focusable(false)
          .accessibilityText('版图工具集')
          .bindTips('查找筛选、器件库、版图比较、宏与 AI 助手')
          .bindMenu(this.buildToolkitMenu, workbenchLuminousMenuOptions())
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
      }
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.Top)
      .layoutWeight(1)
      .width('100%')

      Button({ type: ButtonType.Normal }) {
        Column({ space: 4 }) {
          WorkbenchIcon({ name: 'settings', iconSize: 19, color: COLORS.ink })
          Text('设置')
            .fontSize(10.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.ink)
        }
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
      .width(48)
      .height(48)
      .padding(0)
      .borderRadius(10)
      .backgroundColor(Color.Transparent)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .hoverEffect(HoverEffect.Highlight)
      .focusable(false)
      .accessibilityText('设置与工作台偏好')
      .bindTips('外观光感、工程快照与快捷键设置')
      .bindMenu(this.buildSettingsMenu, workbenchLuminousMenuOptions())
    }
    .width(this.railWidth)
    .height('100%')
    .padding({ left: 4, right: 4, top: 8, bottom: 8 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { right: 0.8 }, color: COLORS.border })
  }

  @Builder
  private moduleButton(module: WorkModule, shortLabel: string, actionLabel: string, iconName: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 3 }) {
        Badge({
          count: module === WorkModule.Verify ? this.drcIssueCount : 0,
          maxCount: 99,
          position: BadgePosition.RightTop,
          style: { badgeColor: COLORS.danger, fontSize: 9, badgeSize: 14, color: Color.White }
        }) {
          Row() {
            WorkbenchIcon({
              name: iconName,
              iconSize: 20,
              color: this.currentModule === module ? '#FFFFFF' : COLORS.ink
            })
          }
          .width(34)
          .height(22)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }
        Text(shortLabel)
          .fontSize(10)
          .lineHeight(12)
          .textAlign(TextAlign.Center)
          .fontWeight(this.currentModule === module ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.currentModule === module ? '#FFFFFF' : COLORS.ink)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(48)
    .height(module === WorkModule.Verify ? 56 : 52)
    .padding({ left: 2, right: 2 })
    .borderRadius(10)
    .animation(null)
    .backgroundColor(this.currentModule === module ? COLORS.primary : Color.Transparent)
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(actionLabel)
    .accessibilitySelected(this.currentModule === module)
    .bindTips(actionLabel)
    .onClick(() => this.selectModuleAction(module, actionLabel))
  }

  @Builder
  private railActionButton(icon: string, label: string, accessibleLabel: string, active: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        WorkbenchIcon({ name: icon, iconSize: 19, color: active ? COLORS.primary : COLORS.ink })
        Text(label)
          .fontSize(10.5)
          .fontWeight(active ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(active ? COLORS.primary : COLORS.ink)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width(48)
    .height(50)
    .padding(0)
    .borderRadius(10)
    .backgroundColor(active ? COLORS.primarySoft : Color.Transparent)
    .border({ width: active ? 0.8 : 0, color: active ? COLORS.primary : Color.Transparent })
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(accessibleLabel)
    .accessibilitySelected(active)
    .bindTips(accessibleLabel)
    .onClick(() => action())
  }
}
