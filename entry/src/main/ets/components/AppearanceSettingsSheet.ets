/**
 * 外观与全局沉浸光感设置半模态（`AppearanceSettingsSheet`）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 极简无冗余副标单行设置页，根节点双向延伸系统安全区，配合 `SettingsScrollPage` 实现零白边沉浸滚动。
 */

import {
  getLuminousIntensityPresetLabel,
  LUMINOUS_INTENSITY_PRESETS,
  LuminousIntensityPreset
} from '../store/LuminousMaterial';
import { ThemeManager } from '../common/Theme';
import {
  FontWeightTokens,
  getLuminousBackgroundSwatchGradient,
  getLuminousBackgroundPresetLabel,
  hongTuThemeState,
  LUMINOUS_BACKGROUND_PRESETS,
  LuminousBackgroundPreset,
  Radius,
  Spacing,
  ThemeMode,
  ThemeState,
  TypeScale
} from '../store/ThemeStore';
import { MotionSettings, USER_REDUCE_MOTION_KEY } from '../common/Motion';
import { SheetGlassHeader } from './SheetGlassHeader';
import {
  SettingsChoiceRow,
  SettingsScrollPage,
  SettingsSection,
  SettingsToggleRow
} from './SettingsKit';

@Component
export struct AppearanceSettingsSheet {
  @Consume themeState: ThemeState;
  @StorageProp(USER_REDUCE_MOTION_KEY) userReduceMotion: boolean = false;
  onClose: () => void = () => {};
  private sheetScroller: Scroller = new Scroller();

  private activeTheme(): ThemeState {
    return this.themeState ?? hongTuThemeState;
  }

  build() {
    WithTheme({
      theme: ThemeManager.nativeTheme(),
      colorMode: this.activeTheme().isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    }) {
    Column() {
      SheetGlassHeader({
        title: '外观与沉浸光感',
        showClose: true,
        onClose: () => this.onClose()
      })

      SettingsScrollPage({ scroller: this.sheetScroller, bottomSpacerVp: 36 }) {
        SettingsSection({
          title: '色彩模式',
          inSheet: true
        }) {
          SettingsChoiceRow({
            title: '跟随系统',
            groupName: 'hongtuThemeModeGroup',
            valueKey: 'system',
            checked: this.activeTheme().themeMode === 'system',
            iconSymbol: $r('sys.symbol.circle_lefthalf_inset_filled'),
            showDivider: true,
            onSelect: () => this.activeTheme().setThemeMode('system' as ThemeMode)
          })
          SettingsChoiceRow({
            title: '深色工作台',
            groupName: 'hongtuThemeModeGroup',
            valueKey: 'dark',
            checked: this.activeTheme().themeMode === 'dark',
            iconSymbol: $r('sys.symbol.moon'),
            showDivider: true,
            onSelect: () => this.activeTheme().setThemeMode('dark' as ThemeMode)
          })
          SettingsChoiceRow({
            title: '浅色工作台',
            groupName: 'hongtuThemeModeGroup',
            valueKey: 'light',
            checked: this.activeTheme().themeMode === 'light',
            iconSymbol: $r('sys.symbol.sun_max'),
            showDivider: false,
            onSelect: () => this.activeTheme().setThemeMode('light' as ThemeMode)
          })
        }

        SettingsSection({
          title: '沉浸光感档位',
          inSheet: true
        }) {
          ForEach(LUMINOUS_INTENSITY_PRESETS, (preset: LuminousIntensityPreset, index: number) => {
            SettingsChoiceRow({
              title: preset === 'strong'
                ? `${getLuminousIntensityPresetLabel(preset)}（默认）`
                : getLuminousIntensityPresetLabel(preset),
              groupName: 'hongtuLuminousIntensityGroup',
              valueKey: preset,
              checked: this.activeTheme().luminousIntensityPreset === preset,
              iconSymbol: $r('sys.symbol.wand_and_stars'),
              showDivider: index < LUMINOUS_INTENSITY_PRESETS.length - 1,
              onSelect: () => this.activeTheme().setLuminousIntensityPreset(preset)
            })
          }, (preset: LuminousIntensityPreset) => preset)
        }

        SettingsSection({
          title: '光感氛围背景',
          inSheet: true
        }) {
          SettingsToggleRow({
            title: '开启光感氛围背景',
            isOn: this.activeTheme().luminousMaterialEnabled,
            iconSymbol: $r('sys.symbol.paintpalette'),
            showDivider: this.activeTheme().luminousMaterialEnabled,
            onToggle: (next: boolean) => this.activeTheme().setLuminousMaterialEnabled(next)
          })

          if (this.activeTheme().luminousMaterialEnabled) {
            Column({ space: Spacing.sm }) {
              Text('氛围色系')
                .fontSize(TypeScale.caption)
                .fontWeight(FontWeightTokens.medium)
                .fontFamily(this.activeTheme().fontFamily)
                .fontColor(this.activeTheme().colors.textSecondary)
                .width('100%')

              Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
                ForEach(LUMINOUS_BACKGROUND_PRESETS, (preset: LuminousBackgroundPreset) => {
                  Row({ space: 8 }) {
                    Row()
                      .width(18)
                      .height(18)
                      .borderRadius(9)
                      .linearGradient({
                        angle: 135,
                        colors: getLuminousBackgroundSwatchGradient(preset)
                      })
                      .border({
                        width: 1,
                        color: this.activeTheme().luminous.floatingBorderColor
                      })
                    Text(getLuminousBackgroundPresetLabel(preset))
                      .fontSize(TypeScale.caption)
                      .fontWeight(this.activeTheme().luminousBackgroundPreset === preset
                        ? FontWeightTokens.semibold
                        : FontWeightTokens.regular)
                      .fontFamily(this.activeTheme().fontFamily)
                      .fontColor(this.activeTheme().luminousBackgroundPreset === preset
                        ? this.activeTheme().colors.primary
                        : this.activeTheme().colors.text)
                      .maxLines(1)
                  }
                  .width('48%')
                  .height(40)
                  .padding({ left: 10, right: 10 })
                  .margin({ bottom: 8 })
                  .borderRadius(Radius.md)
                  .backgroundColor(this.activeTheme().luminousBackgroundPreset === preset
                    ? this.activeTheme().colors.accentSoft
                    : Color.Transparent)
                  .border({
                    width: 1,
                    color: this.activeTheme().luminousBackgroundPreset === preset
                      ? this.activeTheme().colors.primary
                      : this.activeTheme().colors.border
                  })
                  .attributeModifier(this.activeTheme().luminousPointLightModifier())
                  .alignItems(VerticalAlign.Center)
                  .accessibilityRole(AccessibilityRoleType.RADIO)
                  .accessibilityChecked(this.activeTheme().luminousBackgroundPreset === preset)
                  .accessibilityText(getLuminousBackgroundPresetLabel(preset))
                  .onClick(() => this.activeTheme().setLuminousBackgroundPreset(preset))
                }, (preset: LuminousBackgroundPreset) => preset)
              }
              .width('100%')
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 8 })
          }
        }

        SettingsSection({
          title: '动效与无障碍',
          inSheet: true
        }) {
          SettingsToggleRow({
            title: '减少动态效果',
            isOn: this.userReduceMotion,
            iconSymbol: $r('sys.symbol.figure_arms_open'),
            showDivider: false,
            onToggle: (next: boolean) => MotionSettings.setUserReduced(next)
          })
        }
      }
    }
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .backgroundColor(Color.Transparent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
