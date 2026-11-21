/**
 * 鸿图全局光感材质系统 — bindSheet / bindMenu / bindContextMenu 统一收口构造函数
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 全工程所有 `.bindSheet`、`.bindMenu` 与 `.bindContextMenu` 统一经过本模块收口：
 * - API 26+ 支持官材时挂载 `uiMaterial.ImmersiveMaterial`，清空冲突背景/边框/阴影；
 * - API 23–25（含 API 24 模拟器）回退为 `Color.Transparent` + 自适应厚毛玻璃；
 * - 半模态默认设 `preferType: SheetType.POPUP`（手机底部半屏 / 平板与折叠展开跟手居中）与
 *   `ScrollSizeMode.CONTINUOUS` 无极跟手过渡及 `32vp` 圆角。
 */

import { uiMaterial } from '@kit.ArkUI';
import {
  DEFAULT_LUMINOUS_INTENSITY_PRESET,
  getEmptySystemMaterial,
  ImmersiveHdsCapability,
  ImmersiveSystemCapability,
  LuminousCapability,
  LuminousIntensityPreset,
  LuminousMaterialResolver,
  LuminousRenderMode,
  normalizeLuminousIntensityPreset
} from './LuminousMaterial';
import {
  buildSystemImmersiveMaterial,
  HONGTU_LUMINOUS_INTENSITY_KEY,
  hongTuThemeState,
  LuminousMaterialTokens,
  Radius
} from './ThemeStore';

const DEFAULT_SHEET_CORNER_RADIUS: number = Radius.sheet;
const DEFAULT_CONTEXT_MENU_RADIUS: number = Radius.lg;

function getActiveIntensityPreset(explicitPreset?: LuminousIntensityPreset): LuminousIntensityPreset {
  if (explicitPreset !== undefined) {
    return explicitPreset;
  }
  try {
    const raw: string | undefined = AppStorage.get<string>(HONGTU_LUMINOUS_INTENSITY_KEY);
    if (raw !== undefined) {
      return normalizeLuminousIntensityPreset(raw);
    }
  } catch (_err) {
  }
  return hongTuThemeState.luminousIntensityPreset ?? DEFAULT_LUMINOUS_INTENSITY_PRESET;
}

function useSystemMaterialBackend(mode: LuminousRenderMode, systemAvailable?: boolean): boolean {
  if (mode !== LuminousRenderMode.MATERIAL) {
    return false;
  }
  return systemAvailable ?? ImmersiveSystemCapability.isAvailable();
}

export function resolveImmersiveStyleForPreset(preset: LuminousIntensityPreset): uiMaterial.ImmersiveStyle {
  if (preset === 'strong') {
    return uiMaterial.ImmersiveStyle.ULTRA_THICK;
  }
  if (preset === 'weak') {
    return uiMaterial.ImmersiveStyle.REGULAR;
  }
  if (preset === 'system') {
    return ImmersiveHdsCapability.isSupported()
      ? uiMaterial.ImmersiveStyle.ULTRA_THICK
      : uiMaterial.ImmersiveStyle.THICK;
  }
  return uiMaterial.ImmersiveStyle.THICK;
}

export function resolveFallbackBlurStyleForPreset(preset: LuminousIntensityPreset): BlurStyle {
  if (preset === 'strong') {
    return BlurStyle.BACKGROUND_ULTRA_THICK;
  }
  if (preset === 'weak') {
    return BlurStyle.BACKGROUND_THIN;
  }
  if (preset === 'system') {
    return ImmersiveHdsCapability.isSupported()
      ? BlurStyle.BACKGROUND_ULTRA_THICK
      : BlurStyle.BACKGROUND_REGULAR;
  }
  return BlurStyle.BACKGROUND_THICK;
}

function resolveFallbackSheetBackdropColor(isDark: boolean, mismatchWithSystem: boolean = false): ResourceColor {
  if (mismatchWithSystem) {
    return isDark ? 'rgba(16, 23, 33, 0.96)' : 'rgba(250, 252, 255, 0.97)';
  }
  return isDark ? 'rgba(18, 25, 36, 0.88)' : 'rgba(250, 252, 255, 0.94)';
}

function resolveFallbackMenuBackdropColor(isDark: boolean): ResourceColor {
  return isDark ? 'rgba(20, 28, 40, 0.88)' : 'rgba(246, 250, 254, 0.90)';
}

export function buildLuminousSheetOptions(
  base: SheetOptions,
  tokens: LuminousMaterialTokens = hongTuThemeState.luminous,
  mode: LuminousRenderMode = hongTuThemeState.resolveLuminousRenderMode(),
  cornerRadius?: number,
  systemAvailable?: boolean,
  intensityPreset?: LuminousIntensityPreset
): SheetOptions {
  const preset: LuminousIntensityPreset = getActiveIntensityPreset(intensityPreset);
  if (base.preferType === undefined) {
    base.preferType = SheetType.POPUP;
  }
  if (mode === LuminousRenderMode.MATERIAL) {
    if (!base.enableOutsideInteractive) {
      base.maskColor = tokens.sheetMaskColor;
    }
    if (useSystemMaterialBackend(mode, systemAvailable)) {
      base.backgroundColor = undefined;
      base.blurStyle = undefined;
      base.borderWidth = undefined;
      base.borderColor = undefined;
      base.shadow = undefined;
      base.systemMaterial = buildSystemImmersiveMaterial(resolveImmersiveStyleForPreset(preset), false);
    } else {
      // SheetOptions 无独立 blurStyleOptions.colorMode，当应用内浅色/深色与系统深浅色不一致时，
      // 系统级 BACKGROUND_ULTRA_THICK 会叠加系统深灰底导致浅色半模态发灰；此时采用高纯度柔光透白基底避免串色
      const schemeMismatch: boolean = hongTuThemeState.isDark !== hongTuThemeState.systemIsDark;
      base.backgroundColor = resolveFallbackSheetBackdropColor(hongTuThemeState.isDark, schemeMismatch);
      base.blurStyle = schemeMismatch ? BlurStyle.NONE : resolveFallbackBlurStyleForPreset(preset);
      base.borderWidth = 0.8;
      base.borderColor = tokens.floatingBorderColor;
      base.shadow = undefined;
      base.systemMaterial = getEmptySystemMaterial();
    }
  } else {
    if (base.backgroundColor === undefined) {
      base.backgroundColor = tokens.opaqueFallbackColor;
    }
    base.blurStyle = BlurStyle.NONE;
    base.systemMaterial = getEmptySystemMaterial();
  }
  const resolvedRadius: number = cornerRadius ?? DEFAULT_SHEET_CORNER_RADIUS;
  base.radius = {
    topLeft: resolvedRadius,
    topRight: resolvedRadius,
    bottomLeft: resolvedRadius,
    bottomRight: resolvedRadius
  };
  if (
    base.scrollSizeMode === undefined &&
    base.preferType !== SheetType.SIDE &&
    base.preferType !== SheetType.CONTENT_COVER
  ) {
    base.scrollSizeMode = ScrollSizeMode.CONTINUOUS;
  }
  return base;
}

export function buildLuminousMenuOptions(
  base?: MenuOptions,
  tokens: LuminousMaterialTokens = hongTuThemeState.luminous,
  mode: LuminousRenderMode = hongTuThemeState.resolveLuminousRenderMode(),
  cornerRadius?: number,
  systemAvailable?: boolean,
  intensityPreset?: LuminousIntensityPreset
): MenuOptions {
  const target: MenuOptions = base ?? {};
  const preset: LuminousIntensityPreset = getActiveIntensityPreset(intensityPreset);
  if (mode === LuminousRenderMode.MATERIAL) {
    if (useSystemMaterialBackend(mode, systemAvailable)) {
      target.backgroundColor = undefined;
      target.backgroundBlurStyle = undefined;
      target.backgroundBlurStyleOptions = undefined;
      target.backgroundEffect = undefined;
      target.systemMaterial = buildSystemImmersiveMaterial(resolveImmersiveStyleForPreset(preset), false);
    } else {
      target.backgroundColor = resolveFallbackMenuBackdropColor(hongTuThemeState.isDark);
      target.backgroundBlurStyle = resolveFallbackBlurStyleForPreset(preset);
      target.backgroundBlurStyleOptions = {
        colorMode: hongTuThemeState.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
      };
      target.backgroundEffect = undefined;
      target.systemMaterial = getEmptySystemMaterial();
    }
  } else {
    target.backgroundColor = tokens.opaqueFallbackColor;
    target.backgroundBlurStyle = BlurStyle.NONE;
    target.backgroundBlurStyleOptions = undefined;
    target.backgroundEffect = undefined;
    target.systemMaterial = getEmptySystemMaterial();
  }
  if (cornerRadius !== undefined) {
    target.borderRadius = cornerRadius;
  }
  return target;
}

/**
 * 为右键 / 长按上下文菜单（`.bindContextMenu`）构建统一四档沉浸光感 `ContextMenuOptions`。
 */
export function buildLuminousContextMenuOptions(
  base?: ContextMenuOptions,
  tokens: LuminousMaterialTokens = hongTuThemeState.luminous,
  mode: LuminousRenderMode = hongTuThemeState.resolveLuminousRenderMode(),
  cornerRadius: number = DEFAULT_CONTEXT_MENU_RADIUS,
  systemAvailable?: boolean,
  intensityPreset?: LuminousIntensityPreset
): ContextMenuOptions {
  const target: ContextMenuOptions = base ?? {};
  const preset: LuminousIntensityPreset = getActiveIntensityPreset(intensityPreset);
  if (mode === LuminousRenderMode.MATERIAL) {
    if (useSystemMaterialBackend(mode, systemAvailable)) {
      target.backgroundColor = undefined;
      target.backgroundBlurStyle = undefined;
      target.backgroundBlurStyleOptions = undefined;
      target.backgroundEffect = undefined;
      target.systemMaterial = buildSystemImmersiveMaterial(resolveImmersiveStyleForPreset(preset), false);
    } else {
      target.backgroundColor = resolveFallbackMenuBackdropColor(hongTuThemeState.isDark);
      target.backgroundBlurStyle = resolveFallbackBlurStyleForPreset(preset);
      target.backgroundBlurStyleOptions = {
        colorMode: hongTuThemeState.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
      };
      target.backgroundEffect = undefined;
      target.systemMaterial = getEmptySystemMaterial();
    }
  } else {
    target.backgroundColor = tokens.opaqueFallbackColor;
    target.backgroundBlurStyle = BlurStyle.NONE;
    target.backgroundBlurStyleOptions = undefined;
    target.backgroundEffect = undefined;
    target.systemMaterial = getEmptySystemMaterial();
  }
  target.borderRadius = cornerRadius;
  return target;
}

export function resolveLuminousMode(): LuminousRenderMode {
  return LuminousMaterialResolver.resolveEffectMode(LuminousCapability.get());
}
