/**
 * 鸿图统一导航顶栏壳层（基于 `@kit.UIDesignKit` `HdsNavigation`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 对齐华为官方 HdsNavigation 规范与真机避坑：
 * 1. 可滚动页面初始 `originalStyle.blurRadius = 0`，避免静止态顶部出现雾白条，上滑后渐入 `$r('sys.color.comp_background_gray')` 沉浸光感模糊；
 * 2. 挂载 `bottomBuilder`（如分段切换器）且紧邻正文卡片时，强制 `maskExtraHeight = 0` 并切换 `ScrollEffectType.GRADIENT_BLUR`，防止模糊溢出刷糊首张卡片；
 * 3. 半模态内开启 `modalSheetStyle: true` 时设置 `avoidLayoutSafeArea: false`，避免状态栏双重下压；
 * 4. 菜单与返回圆钮统一采用 `$r('sys.color.comp_background_tertiary')`。
 */

import {
  HdsNavigation,
  HdsNavigationBackgroundStyle,
  HdsNavigationIconItemStyle,
  HdsNavigationMenuItemOptions,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTitleBarContentStyle,
  HideMode,
  ScrollEffectType,
  SystemMaterialParams,
  TitleSize
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { HONGTU_LUMINOUS_INTENSITY_KEY, hongTuThemeState, ThemeState } from '../store/ThemeStore';
import {
  DEFAULT_LUMINOUS_INTENSITY_PRESET,
  getLuminousIntensityTuning,
  normalizeLuminousIntensityPreset,
  resolveHdsSystemMaterialEffect
} from '../store/LuminousMaterial';
import {
  DEFAULT_RESPONSIVE_SNAPSHOT,
  getNavigationBlurEndOffset,
  getNavigationBlurRadius,
  getNavigationMaskExtraHeight,
  ResponsiveWidthClass,
  RESPONSIVE_WIDTH_CLASS_KEY
} from '../store/ResponsiveStore';

const DEFAULT_MENU_MAX_COUNT: number = 3;

@Component
export struct AppNavigationShell {
  @Prop title: string = '';
  @Prop subTitle: string = '';
  @Prop largeTitle: boolean = false;
  @Prop compactTitle: boolean = false;
  @Prop modalSheetStyle: boolean = false;
  @Prop showBack: boolean = false;
  @Prop staticBlur: boolean = false;
  @Prop passThroughTouches: boolean = false;
  @Prop transparentBackground: boolean = true;
  @Prop enableLuminousScrollEffect: boolean = true;
  @Prop showBottomContent: boolean = false;
  @Prop bottomContentHeight: number = 48;
  @Prop hideTitleOnScroll: boolean = false;
  @Prop keepBottomContentOnScroll: boolean = true;
  @Prop dynamicHideOffset: number = 16;
  @Prop dynamicHideRatio: number = 2;
  @Prop menuMaxCount: number = DEFAULT_MENU_MAX_COUNT;
  menuItems: HdsNavigationMenuItemOptions[] = [];
  scroller: Scroller = new Scroller();
  scrollables: Scroller[] = [];
  @Consume themeState: ThemeState;
  @BuilderParam content: () => void = this.emptyBuilder;
  bottomContent: () => void = this.emptyBuilder;
  onBack: () => void = () => {};

  @StorageProp(HONGTU_LUMINOUS_INTENSITY_KEY) luminousIntensityPresetValue: string = DEFAULT_LUMINOUS_INTENSITY_PRESET;
  @StorageProp(RESPONSIVE_WIDTH_CLASS_KEY) responsiveWidthClass: ResponsiveWidthClass = DEFAULT_RESPONSIVE_SNAPSHOT.widthClass;

  @Builder
  emptyBuilder() {}

  private getBoundScrollables(): Scroller[] {
    return this.scrollables.length > 0 ? this.scrollables : [this.scroller];
  }

  private getSystemMaterialEffect(): SystemMaterialParams {
    return resolveHdsSystemMaterialEffect(normalizeLuminousIntensityPreset(this.luminousIntensityPresetValue));
  }

  private getShellBackgroundColor(): ResourceColor {
    const activeTheme: ThemeState = this.themeState ?? hongTuThemeState;
    return this.transparentBackground || activeTheme.isLuminousMaterialEnabled()
      ? Color.Transparent
      : activeTheme.colors.background;
  }

  private getMenuStyle(): HdsNavigationIconItemStyle {
    return {
      backgroundColor: $r('sys.color.comp_background_tertiary'),
      iconColor: $r('sys.color.icon_primary'),
      textColor: $r('sys.color.font_primary')
    };
  }

  private getTitleBarOptions(): HdsNavigationTitleBarOptions {
    const activeTheme: ThemeState = this.themeState ?? hongTuThemeState;
    const luminousOn: boolean = activeTheme.isLuminousMaterialEnabled();
    const baseMaskExtraHeight: number = getNavigationMaskExtraHeight(this.responsiveWidthClass);
    const containSwitcherBlur: boolean = this.showBottomContent && !this.passThroughTouches;
    const effectiveMaskExtraHeight: number = containSwitcherBlur
      ? 0
      : (this.showBottomContent ? Math.max(baseMaskExtraHeight, this.bottomContentHeight) : baseMaskExtraHeight);
    const intensityTuning = getLuminousIntensityTuning(
      normalizeLuminousIntensityPreset(this.luminousIntensityPresetValue)
    );
    const rawBlurRadius: number = getNavigationBlurRadius(this.responsiveWidthClass);
    const scrollBlurRadius: number = (luminousOn && !this.enableLuminousScrollEffect && !this.staticBlur)
      ? 0
      : Math.max(10, Math.round(rawBlurRadius * intensityTuning.blurMultiplier));

    const originalBackgroundStyle: HdsNavigationBackgroundStyle = {
      backgroundColor: this.staticBlur && luminousOn
        ? $r('sys.color.comp_background_gray')
        : $r('sys.color.ohos_id_color_background_transparent'),
      maskExtraHeight: effectiveMaskExtraHeight,
      blurRadius: this.staticBlur ? scrollBlurRadius : 0
    };
    const scrollBackgroundStyle: HdsNavigationBackgroundStyle = {
      backgroundColor: luminousOn
        ? $r('sys.color.comp_background_gray')
        : $r('sys.color.ohos_id_color_background_transparent'),
      maskExtraHeight: effectiveMaskExtraHeight,
      blurRadius: scrollBlurRadius
    };
    const contentStyle: HdsTitleBarContentStyle = {
      titleStyle: {
        mainTitleColor: $r('sys.color.font_primary'),
        subTitleColor: $r('sys.color.font_secondary')
      },
      menuStyle: this.getMenuStyle(),
      backIconStyle: {
        backgroundColor: $r('sys.color.comp_background_tertiary'),
        iconColor: $r('sys.color.icon_primary')
      }
    };

    return {
      padding: {
        start: LengthMetrics.vp(16),
        end: LengthMetrics.vp(16)
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: !this.staticBlur && (!luminousOn || this.enableLuminousScrollEffect),
          scrollEffectType: containSwitcherBlur
            ? ScrollEffectType.GRADIENT_BLUR
            : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(getNavigationBlurEndOffset(this.responsiveWidthClass))
        },
        originalStyle: {
          backgroundStyle: originalBackgroundStyle,
          contentStyle
        },
        scrollEffectStyle: {
          backgroundStyle: scrollBackgroundStyle,
          contentStyle
        },
        systemMaterialEffect: this.getSystemMaterialEffect()
      },
      content: {
        title: {
          mainTitle: this.title,
          subTitle: this.subTitle.length > 0 ? this.subTitle : undefined,
          mainTitleSize: this.largeTitle ? TitleSize.TITLE_ML : TitleSize.TITLE_S
        },
        menu: {
          value: this.menuItems,
          maxCount: this.menuItems.length > 0 ? this.menuMaxCount : 0
        },
        backIcon: {
          label: '返回',
          isEnabled: this.showBack,
          action: () => { this.onBack(); }
        },
        bottomBuilder: this.showBottomContent
          ? {
            builder: (): void => { this.bottomContent(); },
            height: this.bottomContentHeight
          }
          : undefined
      },
      avoidLayoutSafeArea: !this.modalSheetStyle,
      enableComponentSafeArea: true
    };
  }

  build() {
    HdsNavigation() {
      this.content()
    }
    .width('100%')
    .height('100%')
    .mode(NavigationMode.Stack)
    .titleMode(this.compactTitle
      ? HdsNavigationTitleMode.MINI
      : (this.modalSheetStyle ? HdsNavigationTitleMode.MODAL : HdsNavigationTitleMode.MINI))
    .titleBar(this.getTitleBarOptions())
    .hideBackButton(!this.showBack)
    .hideToolBar(true)
    .bindToScrollable(this.getBoundScrollables())
    .dynamicHideTitleBar({
      hideTitleArea: this.hideTitleOnScroll,
      hideBottomBuilder: this.hideTitleOnScroll && !this.keepBottomContentOnScroll,
      hideStatusBar: false,
      mode: HideMode.SCROLL_UP_TO,
      hideOffset: this.dynamicHideOffset,
      hideRatio: this.dynamicHideRatio
    })
    .ignoreLayoutSafeArea(
      this.modalSheetStyle ? [] : [LayoutSafeAreaType.SYSTEM],
      this.modalSheetStyle ? [] : [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM]
    )
    .expandSafeArea(
      this.modalSheetStyle ? [] : [SafeAreaType.SYSTEM],
      this.modalSheetStyle ? [] : [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM]
    )
    .backgroundColor(this.getShellBackgroundColor())
    .hitTestBehavior(this.passThroughTouches ? HitTestMode.Transparent : HitTestMode.Default)
  }
}
