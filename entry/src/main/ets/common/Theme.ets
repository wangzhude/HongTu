/**
 * 主题色管理模块 —— 「四层沉浸光感 × 深浅色同构工作台」
 *
 * 桥接全局 `@Observed ThemeState`（`store/ThemeStore.ets`）与工作台 `@ObservedV2 ThemeColors`：
 * - 支持「跟随系统 / 浅色 / 深色」三态实时切换与四档全局沉浸光感（默认「强」）；
 * - 深色模式严格遵循逐级提亮（`#0F141B -> #1A222D -> #222C39`）与纯实色回退底；
 * - 辅助浅底在深色下统一采用 14%~18% 同色相透明叠加，避免刺眼亮斑；
 * - 版图视口在深色下保持 `#070A10` 高对比专业黑底，浅色下保持 `#FFFFFF` 几何白底。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { AppStorageV2, CustomTheme } from '@kit.ArkUI';
import type { ColorPalette } from './constants';
import {
  DEFAULT_LUMINOUS_BACKGROUND_PRESET,
  HONGTU_LUMINOUS_BG_ENABLED_KEY,
  HONGTU_LUMINOUS_BG_PRESET_KEY,
  HONGTU_LUMINOUS_INTENSITY_KEY,
  HONGTU_THEME_MODE_KEY,
  hongTuThemeState,
  LuminousBackgroundPreset,
  normalizeLuminousBackgroundPreset,
  normalizeThemeMode,
  ThemeMode
} from '../store/ThemeStore';
import {
  DEFAULT_LUMINOUS_INTENSITY_PRESET,
  LuminousIntensityPreset,
  normalizeLuminousIntensityPreset
} from '../store/LuminousMaterial';

/** 鸿蒙品牌色常量（对齐 WCAG AA 4.5:1 对比度） */
export const HARMONY_BLUE: string = '#0A73F6';
export const HARMONY_BLUE_BRIGHT: string = '#2984FF';
export const HARMONY_RED: string = '#E84026';

/**
 * 主题色集合，对应 ColorPalette 接口（common/constants.ets），与 hongTuThemeState 实时同步。
 */
@ObservedV2
export class ThemeColors implements ColorPalette {
  @Trace primary: string = HARMONY_BLUE_BRIGHT;
  @Trace primarySoft: string = 'rgba(41,132,255,0.16)';
  @Trace accent: string = '#5B9EFF';
  @Trace accentSoft: string = 'rgba(91,158,255,0.15)';
  @Trace success: string = '#45C96E';
  @Trace warning: string = '#E8A23C';
  @Trace danger: string = '#F2604D';
  @Trace dangerSoft: string = 'rgba(242,96,77,0.16)';
  @Trace teal: string = '#35B8AB';
  @Trace bg: string = '#0F141B';
  @Trace surface: string = '#1A222D';
  @Trace surfaceMuted: string = '#222C39';
  @Trace border: string = '#2A3646';
  @Trace ink: string = '#ECF1F6';
  @Trace muted: string = '#A6B4C2';
  @Trace canvasBg: string = '#070A10';
  @Trace canvasGrid: string = 'rgba(255,255,255,0.038)';
  @Trace canvasGridMajor: string = 'rgba(255,255,255,0.085)';

  /** 切换到深色专业工作台主题（逐级提亮实色基底） */
  applyDark(): void {
    this.primary = HARMONY_BLUE_BRIGHT;
    this.primarySoft = 'rgba(41,132,255,0.16)';
    this.accent = '#5B9EFF';
    this.accentSoft = 'rgba(91,158,255,0.15)';
    this.success = '#45C96E';
    this.warning = '#E8A23C';
    this.danger = '#F2604D';
    this.dangerSoft = 'rgba(242,96,77,0.16)';
    this.teal = '#35B8AB';
    this.bg = '#0F141B';
    this.surface = '#1A222D';
    this.surfaceMuted = '#222C39';
    this.border = '#2A3646';
    this.ink = '#ECF1F6';
    this.muted = '#A6B4C2';
    this.canvasBg = '#070A10';
    this.canvasGrid = 'rgba(255,255,255,0.038)';
    this.canvasGridMajor = 'rgba(255,255,255,0.085)';
  }

  /** 切换到鸿蒙浅色光感工作台主题 */
  applyLight(): void {
    this.primary = HARMONY_BLUE;
    this.primarySoft = 'rgba(10,115,246,0.12)';
    this.accent = '#075CC8';
    this.accentSoft = 'rgba(10,115,246,0.09)';
    this.success = '#1F9D63';
    this.warning = '#D97706';
    this.danger = HARMONY_RED;
    this.dangerSoft = '#FCE8ED';
    this.teal = '#149E92';
    this.bg = '#F3F6FA';
    this.surface = '#FFFFFF';
    this.surfaceMuted = '#EEF3F8';
    this.border = '#DCE5F0';
    this.ink = '#111827';
    this.muted = '#536171';
    this.canvasBg = '#FFFFFF';
    this.canvasGrid = 'rgba(29,78,128,0.065)';
    this.canvasGridMajor = 'rgba(29,78,128,0.14)';
  }
}

/** 全局主题单例，统一协调 AppStorageV2 ThemeColors 与光感 ThemeState */
export class ThemeManager {
  static readonly STORAGE_KEY: string = 'theme_colors';
  static readonly MODE_KEY: string = HONGTU_THEME_MODE_KEY;
  private static bridgeBound: boolean = false;
  private static persistenceInitialized: boolean = false;

  private static bindBridge(): void {
    if (ThemeManager.bridgeBound) {
      return;
    }
    ThemeManager.bridgeBound = true;
    hongTuThemeState.onSchemeChanged((isDark: boolean): void => {
      const target: ThemeColors = ThemeManager.get();
      if (isDark) {
        target.applyDark();
      } else {
        target.applyLight();
      }
    });
  }

  /** 在页面挂载后同步持久化外观与四档光感偏好（默认深色工程态兼容 + 最强光感档）。 */
  static syncPersistence(): void {
    ThemeManager.bindBridge();
    if (!ThemeManager.persistenceInitialized) {
      try {
        PersistentStorage.persistProp<string>(HONGTU_THEME_MODE_KEY, 'system');
        PersistentStorage.persistProp<string>(HONGTU_LUMINOUS_INTENSITY_KEY, DEFAULT_LUMINOUS_INTENSITY_PRESET);
        PersistentStorage.persistProp<boolean>(HONGTU_LUMINOUS_BG_ENABLED_KEY, true);
        PersistentStorage.persistProp<string>(HONGTU_LUMINOUS_BG_PRESET_KEY, DEFAULT_LUMINOUS_BACKGROUND_PRESET);
        ThemeManager.persistenceInitialized = true;
      } catch (_err) {
      }
    }
    try {
      const savedMode: ThemeMode = normalizeThemeMode(AppStorage.get<string>(HONGTU_THEME_MODE_KEY) ?? 'system');
      const savedIntensity: LuminousIntensityPreset = normalizeLuminousIntensityPreset(
        AppStorage.get<string>(HONGTU_LUMINOUS_INTENSITY_KEY) ?? DEFAULT_LUMINOUS_INTENSITY_PRESET
      );
      const savedBgEnabled: boolean = AppStorage.get<boolean>(HONGTU_LUMINOUS_BG_ENABLED_KEY) !== false;
      const savedBgPreset: LuminousBackgroundPreset = normalizeLuminousBackgroundPreset(
        AppStorage.get<string>(HONGTU_LUMINOUS_BG_PRESET_KEY) ?? DEFAULT_LUMINOUS_BACKGROUND_PRESET
      );
      hongTuThemeState.luminousIntensityPreset = savedIntensity;
      hongTuThemeState.luminousMaterialEnabled = savedBgEnabled;
      hongTuThemeState.luminousBackgroundPreset = savedBgPreset;
      hongTuThemeState.themeMode = savedMode;
      hongTuThemeState.applyColorScheme();
    } catch (_err) {
      hongTuThemeState.applyColorScheme();
    }
  }

  static init(): ThemeColors {
    ThemeManager.bindBridge();
    const colors = AppStorageV2.connect(ThemeColors, ThemeManager.STORAGE_KEY, (): ThemeColors => new ThemeColors());
    const resolved: ThemeColors = colors ?? new ThemeColors();
    if (!ThemeManager.persistenceInitialized) {
      // 关键修复：切勿在 PersistentStorage.persistProp 绑定磁盘前调用 setThemeMode('dark') 写入 AppStorage，
      // 否则 AppStorage 已存在的 'dark' 会在冷启动/恢复时反向覆盖用户持久化的 'light' 浅色模式！
      const preSaved: string | undefined = AppStorage.get<string>(HONGTU_THEME_MODE_KEY);
      if (preSaved === 'dark') {
        resolved.applyDark();
      } else if (preSaved === 'light') {
        resolved.applyLight();
      } else if (hongTuThemeState.isDark) {
        resolved.applyDark();
      } else {
        resolved.applyLight();
      }
    } else if (hongTuThemeState.isDark) {
      resolved.applyDark();
    } else {
      resolved.applyLight();
    }
    return resolved;
  }

  static get(): ThemeColors {
    ThemeManager.bindBridge();
    const colors = AppStorageV2.connect(ThemeColors, ThemeManager.STORAGE_KEY, (): ThemeColors => new ThemeColors());
    return colors ?? new ThemeColors();
  }

  static isDark(): boolean {
    return hongTuThemeState.isDark;
  }

  static colorMode(): ThemeColorMode {
    if (hongTuThemeState.themeMode === 'dark') {
      return ThemeColorMode.DARK;
    }
    if (hongTuThemeState.themeMode === 'light') {
      return ThemeColorMode.LIGHT;
    }
    return hongTuThemeState.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT;
  }

  /** ArkUI 原生控件与菜单共享同一套语义色彩令牌。 */
  static nativeTheme(): CustomTheme {
    const colors: ThemeColors = ThemeManager.get();
    return {
      colors: {
        brand: colors.primary,
        warning: colors.warning,
        alert: colors.danger,
        confirm: colors.success,
        fontPrimary: colors.ink,
        fontSecondary: colors.muted,
        fontTertiary: colors.muted,
        fontEmphasize: colors.primary,
        iconPrimary: colors.ink,
        iconSecondary: colors.muted,
        iconEmphasize: colors.primary,
        backgroundPrimary: colors.bg,
        backgroundSecondary: colors.surface,
        compBackgroundPrimary: colors.surfaceMuted,
        compBackgroundSecondary: colors.surfaceMuted,
        compBackgroundTertiary: colors.surfaceMuted,
        compBackgroundEmphasize: colors.primary,
        compEmphasizeSecondary: colors.primarySoft,
        compDivider: colors.border,
        interactiveSelect: colors.primarySoft,
        interactiveFocus: colors.primary
      }
    };
  }

  static setMode(mode: ThemeMode): void {
    hongTuThemeState.setThemeMode(mode);
  }

  static toggleDark(isDark: boolean): void {
    hongTuThemeState.setThemeMode(isDark ? 'dark' : 'light');
  }
}
