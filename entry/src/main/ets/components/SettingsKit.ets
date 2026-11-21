/**
 * 统一设置套件（`SettingsKit`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * - `SettingsScrollPage`：限宽 `720vp` 居中，支持无极半模态 `.align(Alignment.Top)`；
 * - `SettingsSection`：`26vp` 圆角轻通透/光学分组卡，分割线从文字起点缩进 `60vp`（`16 + 32 + 12`）；
 * - `SettingsRow` / `SettingsToggleRow` / `SettingsChoiceRow`：内部原生 `Toggle` 与 `Radio`（`RadioIndicatorType.TICK`）
 *   统一设 `.hitTestBehavior(HitTestMode.None)`，由整行容器接管按压态、无障碍角色语义与点击热区；
 * - 不依赖 `@Consume` 祖先注入，可在 `bindSheet`、工作台浮层及 `@CustomDialog` 独立子树中安全复用。
 */

import {
  AnimDuration,
  AnimPress,
  GravityCurve,
  resolveMotionCurve
} from '../store/AnimationTokens';
import {
  FontWeightTokens,
  HONGTU_LUMINOUS_INTENSITY_KEY,
  hongTuThemeState,
  Radius,
  Spacing,
  ThemeState,
  TypeScale
} from '../store/ThemeStore';
import { isReduceMotionEnabled } from '../common/Motion';

const SECTION_DIVIDER_START_VP: number = 60;
const ICON_BADGE_SIZE_VP: number = 32;

@Component
export struct SettingsScrollPage {
  scroller: Scroller = new Scroller();
  @Prop bottomSpacerVp: number = 48;
  @BuilderParam content: () => void = this.emptyBuilder;

  @Builder
  emptyBuilder() {}

  build() {
    Scroll(this.scroller) {
      Column({ space: Spacing.lg }) {
        Column({ space: Spacing.lg }) {
          this.content()
        }
        .width('100%')
        .constraintSize({ maxWidth: 720 })

        Blank().height(this.bottomSpacerVp)
      }
      .width('100%')
      .padding({ left: Spacing.pageGutter, right: Spacing.pageGutter, top: Spacing.sm })
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .scrollable(ScrollDirection.Vertical)
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .clipContent(ContentClipMode.SAFE_AREA)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}

@Component
export struct SettingsSection {
  @Prop title: string = '';
  @Prop footer: string = '';
  @Prop inSheet: boolean = true;
  @StorageProp('effectiveIsDark') effectiveIsDark: boolean = false;
  @StorageProp(HONGTU_LUMINOUS_INTENSITY_KEY) luminousPresetKey: string = 'strong';
  @BuilderParam content: () => void = this.emptyBuilder;

  @Builder
  emptyBuilder() {}

  private activeTheme(): ThemeState {
    void this.effectiveIsDark;
    void this.luminousPresetKey;
    return hongTuThemeState;
  }

  build() {
    Column({ space: Spacing.xs }) {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(TypeScale.meta)
          .fontWeight(FontWeightTokens.semibold)
          .fontFamily(this.activeTheme().fontFamily)
          .fontColor(this.activeTheme().colors.textSecondary)
          .padding({ left: 12, bottom: 2 })
          .width('100%')
      }

      Column() {
        this.content()
      }
      .width('100%')
      .clip(true)
      .borderRadius(Radius.xl)
      .attributeModifier(this.inSheet
        ? this.activeTheme().luminousSheetSurfaceModifier(Radius.xl)
        : this.activeTheme().luminousFloatingModifier(Radius.xl, 'regular'))

      if (this.footer.trim().length > 0) {
        Text(this.footer)
          .fontSize(TypeScale.caption)
          .fontFamily(this.activeTheme().fontFamily)
          .fontColor(this.activeTheme().colors.textTertiary)
          .padding({ left: 12, right: 12, top: 2 })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct SettingsDivider {
  @Prop hasIcon: boolean = true;
  @StorageProp('effectiveIsDark') effectiveIsDark: boolean = false;

  private activeTheme(): ThemeState {
    void this.effectiveIsDark;
    return hongTuThemeState;
  }

  build() {
    Row() {
      Divider()
        .vertical(false)
        .strokeWidth(0.6)
        .color(this.activeTheme().colors.divider)
    }
    .width('100%')
    .padding({ left: this.hasIcon ? SECTION_DIVIDER_START_VP : 16, right: 16 })
  }
}

@Component
export struct SettingsRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop valueText: string = '';
  @Prop iconSymbol?: Resource = undefined;
  @Prop iconTint: string = '';
  @Prop showChevron: boolean = true;
  @Prop showDivider: boolean = false;
  @Prop enabledState: boolean = true;
  @StorageProp('effectiveIsDark') effectiveIsDark: boolean = false;
  onPress: () => void = () => {};
  @State private pressed: boolean = false;

  private activeTheme(): ThemeState {
    void this.effectiveIsDark;
    return hongTuThemeState;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.iconSymbol !== undefined) {
          Row() {
            SymbolGlyph(this.iconSymbol)
              .fontSize(17)
              .fontColor([this.iconTint.length > 0
                ? this.iconTint
                : this.activeTheme().colors.primary])
          }
          .width(ICON_BADGE_SIZE_VP)
          .height(ICON_BADGE_SIZE_VP)
          .borderRadius(Radius.sm)
          .backgroundColor(this.activeTheme().colors.accentSoft)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }

        Column({ space: this.subtitle.trim().length > 0 ? 3 : 0 }) {
          Text(this.title)
            .fontSize(TypeScale.body)
            .fontWeight(FontWeightTokens.medium)
            .fontFamily(this.activeTheme().fontFamily)
            .fontColor(this.activeTheme().colors.text)
          if (this.subtitle.trim().length > 0) {
            Text(this.subtitle)
              .fontSize(TypeScale.caption)
              .fontFamily(this.activeTheme().fontFamily)
              .fontColor(this.activeTheme().colors.textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.valueText.length > 0) {
          Text(this.valueText)
            .fontSize(TypeScale.meta)
            .fontFamily(this.activeTheme().fontFamily)
            .fontColor(this.activeTheme().colors.textSecondary)
        }
        if (this.showChevron) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(15)
            .fontColor([this.activeTheme().colors.textTertiary])
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .animation(null)
      .opacity(this.enabledState ? 1.0 : 0.45)
      .backgroundColor(this.pressed
        ? this.activeTheme().colors.accentSoft
        : Color.Transparent)
      .scale({ x: this.pressed ? AnimPress.rowScale : 1, y: this.pressed ? AnimPress.rowScale : 1 })
      .animation({
        duration: isReduceMotionEnabled() ? 0 : AnimDuration.fast,
        curve: resolveMotionCurve(GravityCurve.standard, isReduceMotionEnabled())
      })
      .attributeModifier(this.activeTheme().luminousPointLightModifier())
      .enabled(this.enabledState)
      .accessibilityRole(AccessibilityRoleType.BUTTON)
      .accessibilityText(this.valueText.length > 0 ? `${this.title}，${this.valueText}` : this.title)
      .onTouch((event?: TouchEvent) => {
        if (!event || !this.enabledState) return;
        if (event.type === TouchType.Down) this.pressed = true;
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false;
      })
      .onClick(() => {
        if (this.enabledState) this.onPress();
      })

      if (this.showDivider) {
        SettingsDivider({ hasIcon: this.iconSymbol !== undefined })
      }
    }
    .width('100%')
  }
}

@Component
export struct SettingsToggleRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  @Prop iconSymbol?: Resource = undefined;
  @Prop iconTint: string = '';
  @Prop showDivider: boolean = false;
  @Prop enabledState: boolean = true;
  @Prop compact: boolean = false;
  @StorageProp('effectiveIsDark') effectiveIsDark: boolean = false;
  onToggle: (nextValue: boolean) => void = () => {};
  @State private pressed: boolean = false;

  private activeTheme(): ThemeState {
    void this.effectiveIsDark;
    return hongTuThemeState;
  }

  build() {
    Column() {
      Row({ space: this.compact ? 8 : 12 }) {
        if (this.iconSymbol !== undefined) {
          Row() {
            SymbolGlyph(this.iconSymbol)
              .fontSize(17)
              .fontColor([this.iconTint.length > 0
                ? this.iconTint
                : this.activeTheme().colors.primary])
          }
          .width(ICON_BADGE_SIZE_VP)
          .height(ICON_BADGE_SIZE_VP)
          .borderRadius(Radius.sm)
          .backgroundColor(this.activeTheme().colors.accentSoft)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }

        Column({ space: this.subtitle.trim().length > 0 ? 3 : 0 }) {
          Text(this.title)
            .fontSize(this.compact ? TypeScale.meta : TypeScale.body)
            .fontWeight(FontWeightTokens.medium)
            .fontFamily(this.activeTheme().fontFamily)
            .fontColor(this.activeTheme().colors.text)
          if (this.subtitle.trim().length > 0) {
            Text(this.subtitle)
              .fontSize(TypeScale.caption)
              .fontFamily(this.activeTheme().fontFamily)
              .fontColor(this.activeTheme().colors.textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.isOn })
          .selectedColor(this.activeTheme().colors.primary)
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .constraintSize({ minHeight: this.compact ? 42 : 54 })
      .padding(this.compact
        ? { left: 10, right: 10, top: 6, bottom: 6 }
        : { left: 16, right: 16, top: 10, bottom: 10 })
      .borderRadius(this.compact ? Radius.md : 0)
      .animation(null)
      .opacity(this.enabledState ? 1.0 : 0.45)
      .backgroundColor(this.pressed
        ? this.activeTheme().colors.accentSoft
        : (this.compact ? this.activeTheme().colors.surfaceSoft : Color.Transparent))
      .scale({ x: this.pressed ? AnimPress.rowScale : 1, y: this.pressed ? AnimPress.rowScale : 1 })
      .animation({
        duration: isReduceMotionEnabled() ? 0 : AnimDuration.fast,
        curve: resolveMotionCurve(GravityCurve.standard, isReduceMotionEnabled())
      })
      .attributeModifier(this.activeTheme().luminousPointLightModifier())
      .enabled(this.enabledState)
      .accessibilityRole(AccessibilityRoleType.TOGGLER)
      .accessibilityChecked(this.isOn)
      .accessibilityText(this.title)
      .onTouch((event?: TouchEvent) => {
        if (!event || !this.enabledState) return;
        if (event.type === TouchType.Down) this.pressed = true;
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false;
      })
      .onClick(() => {
        if (this.enabledState) {
          this.onToggle(!this.isOn);
        }
      })

      if (this.showDivider) {
        SettingsDivider({ hasIcon: this.iconSymbol !== undefined })
      }
    }
    .width('100%')
  }
}

@Component
export struct SettingsChoiceRow {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop groupName: string = 'settingsChoiceGroup';
  @Prop valueKey: string = '';
  @Prop checked: boolean = false;
  @Prop iconSymbol?: Resource = undefined;
  @Prop iconTint: string = '';
  @Prop showDivider: boolean = false;
  @StorageProp('effectiveIsDark') effectiveIsDark: boolean = false;
  onSelect: () => void = () => {};
  @State private pressed: boolean = false;

  private activeTheme(): ThemeState {
    void this.effectiveIsDark;
    return hongTuThemeState;
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.iconSymbol !== undefined) {
          Row() {
            SymbolGlyph(this.iconSymbol)
              .fontSize(17)
              .fontColor([this.iconTint.length > 0
                ? this.iconTint
                : this.activeTheme().colors.primary])
          }
          .width(ICON_BADGE_SIZE_VP)
          .height(ICON_BADGE_SIZE_VP)
          .borderRadius(Radius.sm)
          .backgroundColor(this.activeTheme().colors.accentSoft)
          .justifyContent(FlexAlign.Center)
          .alignItems(VerticalAlign.Center)
        }

        Column({ space: this.subtitle.trim().length > 0 ? 3 : 0 }) {
          Text(this.title)
            .fontSize(TypeScale.body)
            .fontWeight(this.checked ? FontWeightTokens.semibold : FontWeightTokens.medium)
            .fontFamily(this.activeTheme().fontFamily)
            .fontColor(this.checked
              ? this.activeTheme().colors.primary
              : this.activeTheme().colors.text)
          if (this.subtitle.trim().length > 0) {
            Text(this.subtitle)
              .fontSize(TypeScale.caption)
              .fontFamily(this.activeTheme().fontFamily)
              .fontColor(this.activeTheme().colors.textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Radio({
          value: this.valueKey,
          group: this.groupName,
          indicatorType: RadioIndicatorType.TICK
        })
          .checked(this.checked)
          .radioStyle({
            checkedBackgroundColor: this.activeTheme().colors.primary
          })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .constraintSize({ minHeight: 54 })
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .animation(null)
      .backgroundColor(this.pressed
        ? this.activeTheme().colors.accentSoft
        : Color.Transparent)
      .scale({ x: this.pressed ? AnimPress.rowScale : 1, y: this.pressed ? AnimPress.rowScale : 1 })
      .animation({
        duration: isReduceMotionEnabled() ? 0 : AnimDuration.fast,
        curve: resolveMotionCurve(GravityCurve.standard, isReduceMotionEnabled())
      })
      .attributeModifier(this.activeTheme().luminousPointLightModifier())
      .accessibilityRole(AccessibilityRoleType.RADIO)
      .accessibilityChecked(this.checked)
      .accessibilityText(this.title)
      .onTouch((event?: TouchEvent) => {
        if (!event) return;
        if (event.type === TouchType.Down) this.pressed = true;
        else if (event.type === TouchType.Up || event.type === TouchType.Cancel) this.pressed = false;
      })
      .onClick(() => {
        if (!this.checked) {
          this.onSelect();
        }
      })

      if (this.showDivider) {
        SettingsDivider({ hasIcon: this.iconSymbol !== undefined })
      }
    }
    .width('100%')
  }
}
