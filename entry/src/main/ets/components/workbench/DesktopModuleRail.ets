import { COLORS } from '../../common/constants';
import { ColorMetrics, LengthMetrics } from '@kit.ArkUI';
import { UI } from '../../common/UiTokens';
import { feedbackCurve, MOTION, motionDuration } from '../../common/Motion';
import { hongTuThemeState } from '../../store/ThemeStore';
import { WorkModule } from '../../workbench/WorkbenchModels';
import { WorkbenchIcon } from './WorkbenchIcon';

/**
 * 桌面紧凑型左侧模块导航窄轨（压缩冗余高度与内边距，释放画布与侧栏视野）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
@Component
export struct DesktopModuleRail {
  @Prop currentModule: WorkModule = WorkModule.Layout;
  @Prop drcIssueCount: number = 0;
  @Prop railWidth: number = 48;
  selectModuleAction: (module: WorkModule, label: string) => void = () => {};
  projectAction: () => void = () => {};
  shortcutAction: () => void = () => {};
  openAppearanceAction: () => void = () => {};

  build() {
    Column({ space: 4 }) {
      this.moduleButton(WorkModule.Layout, '版图', '版图编辑')
      this.moduleButton(WorkModule.Verify, '验证', '验证检查')
      this.moduleButton(WorkModule.Data, '数据', '数据管理')
      Blank()
      this.utilityButton('appearance', '光感', '外观与沉浸光感', this.openAppearanceAction)
      this.utilityButton('open', '工程', '工程与历史', this.projectAction)
      this.utilityButton('info', '快捷键', '打开快捷键设置', this.shortcutAction)
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
          .height(24)
          .justifyContent(FlexAlign.Center)
        }
        Text(shortLabel)
          .fontSize(11)
          .fontWeight(this.currentModule === module ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.currentModule === module ? COLORS.primary : COLORS.ink)
      }
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height(50)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .animation(null)
    .backgroundColor(this.currentModule === module ? COLORS.primarySoft : Color.Transparent)
    .animation({ duration: motionDuration(MOTION.feedback), curve: feedbackCurve() })
    .animation(null)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .stateEffect(true)
    .hoverEffect(HoverEffect.Highlight)
    .focusable(true)
    .focusBox({ strokeColor: ColorMetrics.resourceColor(COLORS.primary), strokeWidth: LengthMetrics.vp(2) })
    .accessibilityText(actionLabel)
    .accessibilitySelected(this.currentModule === module)
    .bindTips(actionLabel)
    .onClick(() => this.selectModuleAction(module, actionLabel))
  }

  @Builder
  private utilityButton(icon: string, label: string, accessibleLabel: string, action: () => void) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 3 }) {
        WorkbenchIcon({ name: icon, iconSize: 18, color: COLORS.muted })
        Text(label).fontSize(10).fontColor(COLORS.muted)
      }.justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .height(44)
    .padding(0)
    .borderRadius(UI.controlRadius)
    .backgroundColor(Color.Transparent)
    .attributeModifier(hongTuThemeState.luminousPointLightModifier())
    .hoverEffect(HoverEffect.Highlight)
    .accessibilityText(accessibleLabel)
    .bindTips(accessibleLabel)
    .onClick(() => action())
  }

  @Builder
  private moduleIcon(module: WorkModule) {
    WorkbenchIcon({
      name: module === WorkModule.Layout ? 'layout' : module === WorkModule.Verify ? 'verify' : 'data',
      iconSize: 20,
      color: this.currentModule === module ? COLORS.primary : COLORS.ink
    })
  }
}
