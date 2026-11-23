import { COLORS } from '../../common/constants';
import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkModule } from '../../workbench/WorkbenchModels';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面全功能左侧活动侧轨（v8 Studio 级高密度抽屉直达版）
 *
 * 彻底利用原先左侧侧轨中部 400vp+ 闲置空白区：
 * - 顶部：版图 / 验证（带 DRC 实时计数徽章）/ 数据 三大工作区；
 * - 中部：查找筛选、器件库/PCell、端侧 Python 3、工艺叠层、版图比较、AI 视觉助手 一键抽屉开关（带激活高亮）；
 * - 底部：宏录制、工程历史、光感外观、快捷键（原生键盘符号）。
 * 外层包裹无滚动条弹簧 Scroll，在矮窗口横屏下同样完整可达、绝不裁切。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct DesktopModuleRail {
  @Prop currentModule: WorkModule = WorkModule.Layout;
  @Prop drcIssueCount: number = 0;
  @Prop railWidth: number = 48;
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

  build() {
    Column({ space: 3 }) {
      Scroll() {
        Column({ space: 3 }) {
          this.moduleButton(WorkModule.Layout, '版图', '版图编辑工作区')
          this.moduleButton(WorkModule.Verify, '验证', 'DRC / LVS 验证工作区')
          this.moduleButton(WorkModule.Data, '数据', '版图文件与单元库总览')

          Divider()
            .width(26)
            .color(COLORS.border)
            .margin({ top: 3, bottom: 3 })

          this.drawerButton('search', '查找', '搜索与筛选图形 (Ctrl+F)', this.searchActive, this.searchAction)
          this.drawerButton('cell', '器件', '个人器件库与参数化 PCell', this.libraryActive, this.libraryAction)
          this.drawerButton('python', '脚本', '端侧内置 Python 3 脚本工作台', this.pythonActive, this.pythonAction)
          this.drawerButton('stack', '工艺', '工艺文件管理与 2.5D 截面叠层', this.techActive, this.technologyAction)
          this.drawerButton('compare', '比较', '版图 XOR 差异比较', this.compareActive, this.compareAction)
          this.drawerButton('ai', 'AI', '鸿图视觉 Harness 智能助手', this.aiActive, this.aiAction)
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

      Divider()
        .width(26)
        .color(COLORS.border)
        .margin({ top: 2, bottom: 2 })

      this.drawerButton('macro', '宏', '录制与运行批处理宏', this.macroActive, this.macroAction)
      this.utilityButton('project', '工程', '工程与历史快照 (Ctrl+N)', this.projectAction)
      this.utilityButton('appearance', '光感', '外观与沉浸光感设置', this.openAppearanceAction)
      this.utilityButton('keyboard', '热键', '键盘快捷键与助记码设置', this.shortcutAction)
    }
    .width(this.railWidth)
    .height('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 6 })
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.bg)
    .border({ width: { right: 0.8 }, color: COLORS.border })
  }

  @Builder
  private moduleButton(module: WorkModule, shortLabel: string, actionLabel: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 2 }) {
        Badge({
          count: module === WorkModule.Verify ? this.drcIssueCount : 0,
          maxCount: 99,
          position: BadgePosition.RightTop,
          style: { badgeColor: COLORS.danger, fontSize: 9, badgeSize: 14, color: Color.White }
        }) {
          Row() {
            this.moduleIcon(module)
          }
          .width(34)
          .height(22)
          .justifyContent(FlexAlign.Center)
        }
        Text(shortLabel)
          .fontSize(10.5)
          .fontWeight(this.currentModule === module ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.currentModule === module ? COLORS.primary : COLORS.ink)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height(46)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .animation(null)
    .backgroundColor(this.currentModule === module ? COLORS.primarySoft : Color.Transparent)
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
  private drawerButton(icon: string, label: string, accessibleLabel: string, active: boolean, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 2 }) {
        WorkbenchIcon({ name: icon, iconSize: 17, color: active ? COLORS.primary : COLORS.ink })
        Text(label)
          .fontSize(10)
          .fontWeight(active ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(active ? COLORS.primary : COLORS.muted)
      }.justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height(42)
    .padding(0)
    .borderRadius(UI.controlRadius)
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

  @Builder
  private utilityButton(icon: string, label: string, accessibleLabel: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 2 }) {
        WorkbenchIcon({ name: icon, iconSize: 16, color: COLORS.muted })
        Text(label).fontSize(9.5).fontColor(COLORS.muted)
      }.justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height(40)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .backgroundColor(Color.Transparent)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .hoverEffect(HoverEffect.Highlight)
    .focusable(false)
    .accessibilityText(accessibleLabel)
    .bindTips(accessibleLabel)
    .onClick(() => action())
  }

  @Builder
  private moduleIcon(module: WorkModule) {
    WorkbenchIcon({
      name: module === WorkModule.Layout ? 'layout' : module === WorkModule.Verify ? 'verify' : 'data',
      iconSize: 19,
      color: this.currentModule === module ? COLORS.primary : COLORS.ink
    })
  }
}
