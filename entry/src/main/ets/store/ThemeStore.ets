/**
 * 鸿图统一设计语言 Token、深浅色同构体系与四层光感 AttributeModifier
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 1. 深浅色语义同构（深色遵循纯实色逐级提亮 #0F141B -> #1A222D -> #222C39 -> #2A3542）；
 * 2. 四层光感表面修饰器（API 26 沉浸系统材质复用、高饱和 backgroundEffect 光学浮窗、
 *    零模糊轻通透列表卡、仅按压瞬间点亮的 hdsEffect 点光源）；
 * 3. 屏幕物理像素密度换算阴影 shadowVp() 与全局无冲突叠放层级 ZIndexTokens。
 */

import { hdsEffect } from '@kit.UIDesignKit';
import { display, window } from '@kit.ArkUI';
import {
  buildSystemImmersiveMaterial,
  clearSystemImmersiveMaterialCache,
  DEFAULT_LUMINOUS_INTENSITY_PRESET,
  getLuminousIntensityPresetLabel,
  getLuminousIntensityPresetSubtitle,
  getLuminousIntensityTuning,
  ImmersiveSystemCapability,
  isLuminousIntensityPreset,
  LUMINOUS_INTENSITY_PRESETS,
  LuminousCapability,
  LuminousIntensityPreset,
  LuminousMaterialResolver,
  LuminousRenderMode,
  normalizeLuminousIntensityPreset
} from './LuminousMaterial';

export {
  buildSystemImmersiveMaterial,
  clearSystemImmersiveMaterialCache,
  DEFAULT_LUMINOUS_INTENSITY_PRESET,
  getLuminousIntensityPresetLabel,
  getLuminousIntensityPresetSubtitle,
  isLuminousIntensityPreset,
  LUMINOUS_INTENSITY_PRESETS,
  LuminousIntensityPreset,
  normalizeLuminousIntensityPreset
};

export type ThemeMode = 'light' | 'dark' | 'system';

export type LuminousBackgroundPreset = 'aqua' | 'morning' | 'mint' | 'violet' | 'deep' | 'orange';

export type LuminousFloatingBlurTier = 'thin' | 'regular' | 'thick' | 'ultraThick';

export const DEFAULT_LUMINOUS_BACKGROUND_PRESET: LuminousBackgroundPreset = 'aqua';
export const LUMINOUS_BACKGROUND_PRESETS: LuminousBackgroundPreset[] = [
  'aqua', 'morning', 'mint', 'violet', 'deep', 'orange'
];

export const HONGTU_THEME_MODE_KEY: string = 'hongtuThemeMode';
export const HONGTU_LUMINOUS_INTENSITY_KEY: string = 'luminousIntensityPreset';
export const HONGTU_LUMINOUS_BG_ENABLED_KEY: string = 'hongtuLuminousBgEnabled';
export const HONGTU_LUMINOUS_BG_PRESET_KEY: string = 'hongtuLuminousBgPreset';

/** 全局浮层与全屏遮罩层级语义常量（杜绝 Index.ets 18 个工作台浮层撞号遮挡）。 */
export class ZIndexTokens {
  static readonly ambientBackdrop: number = 0;
  static readonly workbenchShell: number = 10;
  static readonly canvasHud: number = 120;
  static readonly floatingToolbar: number = 140;
  static readonly liveJobCapsule: number = 180;
  static readonly drcRulesPopover: number = 210;
  static readonly shapeSearchPanel: number = 230;
  static readonly aiAssistantPanel: number = 260;
  static readonly pythonLayoutPanel: number = 270;
  static readonly viewWorkspacePanel: number = 280;
  static readonly comparePanel: number = 290;
  static readonly technologyPanel: number = 300;
  static readonly verificationPanel: number = 310;
  static readonly lvsPanel: number = 320;
  static readonly projectPanel: number = 330;
  static readonly libraryPanel: number = 340;
  static readonly layerStackPanel: number = 350;
  static readonly rdbReviewPanel: number = 360;
  static readonly engineeringRestorePanel: number = 370;
  static readonly modalOverlayBackdrop: number = 500;
  static readonly modalUtilityPanel: number = 520;
}

export function isThemeMode(value: string): boolean {
  return value === 'light' || value === 'dark' || value === 'system';
}

export function normalizeThemeMode(value: string | null | undefined): ThemeMode {
  if (typeof value === 'string' && isThemeMode(value)) {
    return value as ThemeMode;
  }
  return 'system';
}

export function isLuminousBackgroundPreset(value: string): boolean {
  return value === 'aqua' || value === 'morning' || value === 'mint' ||
    value === 'violet' || value === 'deep' || value === 'orange';
}

export function normalizeLuminousBackgroundPreset(value: string | null | undefined): LuminousBackgroundPreset {
  if (typeof value === 'string' && isLuminousBackgroundPreset(value)) {
    return value as LuminousBackgroundPreset;
  }
  return DEFAULT_LUMINOUS_BACKGROUND_PRESET;
}

export function getLuminousBackgroundPresetLabel(preset: LuminousBackgroundPreset): string {
  if (preset === 'morning') return '晨光青雾';
  if (preset === 'mint') return '薄荷流光';
  if (preset === 'violet') return '星云暮紫';
  if (preset === 'deep') return '晶圆深海';
  if (preset === 'orange') return '暖金霞光';
  return '冰晶海蓝';
}

export function getLuminousBackgroundPresetGradient(
  preset: LuminousBackgroundPreset,
  isDark: boolean
): Array<[ResourceColor, number]> {
  if (isDark) {
    if (preset === 'morning') {
      return [['#162A3B', 0], ['#133346', 0.36], ['#0E2233', 0.72], ['#0B1119', 1]];
    }
    if (preset === 'mint') {
      return [['#113136', 0], ['#0E3D40', 0.36], ['#0B2630', 0.72], ['#0A1118', 1]];
    }
    if (preset === 'violet') {
      return [['#212647', 0], ['#1E2F52', 0.36], ['#131F3A', 0.72], ['#0B101D', 1]];
    }
    if (preset === 'deep') {
      return [['#0F2844', 0], ['#0C3352', 0.36], ['#092036', 0.72], ['#080F1A', 1]];
    }
    if (preset === 'orange') {
      return [['#311E17', 0], ['#3C2218', 0.36], ['#261618', 0.72], ['#110D12', 1]];
    }
    return [['#13283F', 0], ['#103352', 0.36], ['#0C1F34', 0.72], ['#0B1018', 1]];
  }
  if (preset === 'morning') {
    return [['#F2F9FF', 0], ['#E3F6EF', 0.36], ['#CEE7F8', 0.72], ['#B8D8F0', 1]];
  }
  if (preset === 'mint') {
    return [['#EFFDF9', 0], ['#DCF9F1', 0.36], ['#BCECE9', 0.72], ['#9CD8E8', 1]];
  }
  if (preset === 'violet') {
    return [['#F4F5FF', 0], ['#EAE4FC', 0.36], ['#D1D9F7', 0.72], ['#B6C6EE', 1]];
  }
  if (preset === 'deep') {
    return [['#E8F4FF', 0], ['#CFE4F5', 0.36], ['#AED0EA', 0.72], ['#8EBBE0', 1]];
  }
  if (preset === 'orange') {
    return [['#FFF6EC', 0], ['#FFE0C4', 0.36], ['#F9C2A8', 0.72], ['#EBA8B2', 1]];
  }
  return [['#EAF4FF', 0], ['#DCF4FA', 0.36], ['#BBE2F6', 0.72], ['#9CCDF0', 1]];
}

export function getLuminousBackgroundSwatchGradient(
  preset: LuminousBackgroundPreset
): Array<[ResourceColor, number]> {
  if (preset === 'morning') {
    return [['#0EA5E9', 0], ['#2DD4BF', 0.55], ['#6EE7B7', 1]];
  }
  if (preset === 'mint') {
    return [['#059669', 0], ['#14B8A6', 0.55], ['#5EEAD4', 1]];
  }
  if (preset === 'violet') {
    return [['#6366F1', 0], ['#8B5CF6', 0.55], ['#D8B4FE', 1]];
  }
  if (preset === 'deep') {
    return [['#1D4ED8', 0], ['#2563EB', 0.55], ['#60A5FA', 1]];
  }
  if (preset === 'orange') {
    return [['#EA580C', 0], ['#F59E0B', 0.55], ['#FB7185', 1]];
  }
  return [['#0A73F6', 0], ['#0284C7', 0.55], ['#38BDF8', 1]];
}

export function getLuminousBackgroundPresetBottomColor(
  preset: LuminousBackgroundPreset,
  isDark: boolean
): ResourceColor {
  const stops = getLuminousBackgroundPresetGradient(preset, isDark);
  return stops[stops.length - 1][0];
}

export function getLuminousAmbientOrbColors(
  preset: LuminousBackgroundPreset,
  isDark: boolean
): [string, string, string] {
  if (isDark) {
    if (preset === 'violet') {
      return ['rgba(124, 98, 255, 0.28)', 'rgba(56, 152, 255, 0.24)', 'rgba(45, 212, 191, 0.18)'];
    }
    if (preset === 'mint') {
      return ['rgba(45, 212, 191, 0.28)', 'rgba(56, 189, 248, 0.24)', 'rgba(99, 102, 241, 0.16)'];
    }
    if (preset === 'orange') {
      return ['rgba(251, 146, 60, 0.26)', 'rgba(244, 114, 182, 0.22)', 'rgba(96, 165, 250, 0.16)'];
    }
    return ['rgba(41, 132, 255, 0.30)', 'rgba(56, 189, 248, 0.24)', 'rgba(45, 212, 191, 0.18)'];
  }
  if (preset === 'violet') {
    return ['rgba(139, 92, 246, 0.34)', 'rgba(59, 130, 246, 0.28)', 'rgba(45, 212, 191, 0.22)'];
  }
  if (preset === 'mint') {
    return ['rgba(20, 184, 166, 0.34)', 'rgba(14, 165, 233, 0.28)', 'rgba(99, 102, 241, 0.20)'];
  }
  if (preset === 'orange') {
    return ['rgba(251, 146, 60, 0.36)', 'rgba(244, 114, 182, 0.28)', 'rgba(59, 130, 246, 0.20)'];
  }
  return ['rgba(10, 115, 246, 0.36)', 'rgba(34, 211, 238, 0.30)', 'rgba(52, 211, 153, 0.22)'];
}

export interface SemanticThemePalette {
  readonly background: string;
  readonly backgroundAccent: string;
  readonly backgroundCool: string;
  readonly surface: string;
  readonly surfaceSoft: string;
  readonly controlSurface: string;
  readonly border: string;
  readonly divider: string;
  readonly controlBorder: string;
  readonly primary: string;
  readonly primaryDeep: string;
  readonly primarySoft: string;
  readonly accent: string;
  readonly accentSoft: string;
  readonly success: string;
  readonly successSoft: string;
  readonly warning: string;
  readonly warningSoft: string;
  readonly danger: string;
  readonly dangerSoft: string;
  readonly teal: string;
  readonly tealSoft: string;
  readonly text: string;
  readonly textSecondary: string;
  readonly textTertiary: string;
  readonly textMuted: string;
  readonly shadowSoft: string;
  readonly canvasBg: string;
  readonly canvasGrid: string;
  readonly canvasGridMajor: string;
}

export const LIGHT_SEMANTIC_PALETTE: SemanticThemePalette = {
  background: '#F2F6FA',
  backgroundAccent: '#E4EFFB',
  backgroundCool: '#E8F4F8',
  surface: '#FFFFFF',
  surfaceSoft: '#F5F8FC',
  controlSurface: '#EDF2F7',
  border: '#DCE4EE',
  divider: 'rgba(29, 78, 128, 0.10)',
  controlBorder: '#CBD5E1',
  primary: '#0A73F6',
  primaryDeep: '#075CC8',
  primarySoft: 'rgba(10, 115, 246, 0.12)',
  accent: '#0E93AD',
  accentSoft: '#E6F7FA',
  success: '#1E8E5A',
  successSoft: '#E8F8F0',
  warning: '#D97706',
  warningSoft: '#FEF3C7',
  danger: '#E53935',
  dangerSoft: '#FCE8EA',
  teal: '#0D9488',
  tealSoft: '#E9FBF6',
  text: '#111827',
  textSecondary: '#536171',
  textTertiary: '#8A99A8',
  textMuted: '#8A99A8',
  shadowSoft: 'rgba(29, 78, 128, 0.13)',
  canvasBg: '#FFFFFF',
  canvasGrid: 'rgba(42, 68, 103, 0.065)',
  canvasGridMajor: 'rgba(42, 68, 103, 0.14)'
};

export const DARK_SEMANTIC_PALETTE: SemanticThemePalette = {
  background: '#0F141B',
  backgroundAccent: '#1B2A40',
  backgroundCool: '#16262E',
  surface: '#1A222D',
  surfaceSoft: '#222C39',
  controlSurface: '#2A3542',
  border: '#2E3B4B',
  divider: 'rgba(255, 255, 255, 0.10)',
  controlBorder: '#38475A',
  primary: '#2984FF',
  primaryDeep: '#5CA3FF',
  primarySoft: 'rgba(41, 132, 255, 0.18)',
  accent: '#57D5E5',
  accentSoft: 'rgba(87, 213, 229, 0.15)',
  success: '#38C976',
  successSoft: 'rgba(56, 201, 118, 0.16)',
  warning: '#F59E0B',
  warningSoft: 'rgba(245, 158, 11, 0.16)',
  danger: '#F87171',
  dangerSoft: 'rgba(248, 113, 113, 0.16)',
  teal: '#2DD4BF',
  tealSoft: 'rgba(45, 212, 191, 0.15)',
  text: '#ECF1F6',
  textSecondary: '#A6B4C2',
  textTertiary: '#73828F',
  textMuted: '#73828F',
  shadowSoft: 'rgba(0, 0, 0, 0.40)',
  canvasBg: '#070A10',
  canvasGrid: 'rgba(255, 255, 255, 0.04)',
  canvasGridMajor: 'rgba(255, 255, 255, 0.09)'
};

export interface LuminousMaterialTokens {
  readonly sheetMaskColor: ResourceColor;
  readonly opaqueFallbackColor: ResourceColor;
  readonly translucentCardColor: ResourceColor;
  readonly sheetCardColor: ResourceColor;
  readonly floatingGlassColor: ResourceColor;
  readonly floatingBorderColor: ResourceColor;
  readonly borderColor: ResourceColor;
  readonly opaqueFallbackBorderColor: ResourceColor;
  readonly borderWidth: number;
  readonly pointLightColor: ResourceColor;
  readonly pointLightActiveColor: ResourceColor;
  readonly pointLightReceiverColor: ResourceColor;
}

export const LuminousMaterialTokens_LIGHT: LuminousMaterialTokens = {
  sheetMaskColor: 'rgba(17, 24, 39, 0.14)',
  opaqueFallbackColor: '#FFFFFF',
  translucentCardColor: 'rgba(255, 255, 255, 0.56)',
  sheetCardColor: 'rgba(255, 255, 255, 0.46)',
  floatingGlassColor: 'rgba(255, 255, 255, 0.30)',
  floatingBorderColor: 'rgba(255, 255, 255, 0.84)',
  borderColor: 'rgba(255, 255, 255, 0.78)',
  opaqueFallbackBorderColor: 'rgba(29, 78, 128, 0.10)',
  borderWidth: 0.85,
  pointLightColor: 'rgba(184, 229, 255, 0.42)',
  pointLightActiveColor: 'rgba(255, 255, 255, 0.72)',
  pointLightReceiverColor: 'rgba(205, 238, 255, 0.22)'
};

export const LuminousMaterialTokens_DARK: LuminousMaterialTokens = {
  sheetMaskColor: 'rgba(0, 0, 0, 0.24)',
  opaqueFallbackColor: '#1A222D',
  translucentCardColor: 'rgba(20, 30, 44, 0.58)',
  sheetCardColor: 'rgba(30, 42, 58, 0.52)',
  floatingGlassColor: 'rgba(18, 28, 42, 0.38)',
  floatingBorderColor: 'rgba(255, 255, 255, 0.28)',
  borderColor: 'rgba(255, 255, 255, 0.22)',
  opaqueFallbackBorderColor: 'rgba(255, 255, 255, 0.16)',
  borderWidth: 0.80,
  pointLightColor: 'rgba(148, 215, 255, 0.44)',
  pointLightActiveColor: 'rgba(222, 242, 255, 0.70)',
  pointLightReceiverColor: 'rgba(150, 220, 255, 0.18)'
};

export enum LuminousLightRole {
  SOURCE = 'source',
  RECEIVER = 'receiver',
  MIXED = 'mixed'
}

export enum LuminousLightLevel {
  SUBTLE = 'subtle',
  NORMAL = 'normal',
  EMPHASIS = 'emphasis'
}

export interface LuminousLightState {
  readonly enabled: boolean;
  readonly role: LuminousLightRole;
  readonly level: LuminousLightLevel;
  readonly active: boolean;
  readonly pressed: boolean;
  readonly intensityScale?: number;
}

export class LuminousPointLightFactory {
  static build(tokens: LuminousMaterialTokens, state: LuminousLightState): VisualEffect {
    const enabled: boolean = state.enabled;
    const sourceEnabled: boolean = enabled &&
      (state.role === LuminousLightRole.SOURCE || state.role === LuminousLightRole.MIXED);
    const receiverEnabled: boolean = enabled &&
      (state.role === LuminousLightRole.RECEIVER || state.role === LuminousLightRole.MIXED);
    const color: ResourceColor = state.pressed ? tokens.pointLightActiveColor :
      (receiverEnabled && !sourceEnabled ? tokens.pointLightReceiverColor : tokens.pointLightColor);

    return new hdsEffect.HdsEffectBuilder()
      .pressShadow(state.pressed ? hdsEffect.PressShadowType.BLEND_WHITE : hdsEffect.PressShadowType.NONE)
      .pointLight({
        sourceType: LuminousPointLightFactory.resolveSourceType(sourceEnabled, state),
        illuminatedType: LuminousPointLightFactory.resolveIlluminatedType(receiverEnabled, sourceEnabled, state),
        options: {
          color: color,
          intensity: LuminousPointLightFactory.resolveIntensity(state),
          height: LuminousPointLightFactory.resolveHeight(state),
          bloom: LuminousPointLightFactory.resolveBloom(state)
        }
      })
      .buildEffect();
  }

  private static resolveSourceType(sourceEnabled: boolean, state: LuminousLightState): hdsEffect.PointLightSourceType {
    if (!sourceEnabled || !state.pressed) {
      return hdsEffect.PointLightSourceType.NONE;
    }
    return state.level === LuminousLightLevel.EMPHASIS
      ? hdsEffect.PointLightSourceType.BRIGHT
      : hdsEffect.PointLightSourceType.SOFT;
  }

  private static resolveIlluminatedType(
    receiverEnabled: boolean,
    sourceEnabled: boolean,
    state: LuminousLightState
  ): hdsEffect.PointLightIlluminatedType {
    if ((!receiverEnabled && !sourceEnabled) || !state.pressed) {
      return hdsEffect.PointLightIlluminatedType.NONE;
    }
    return state.level === LuminousLightLevel.EMPHASIS
      ? hdsEffect.PointLightIlluminatedType.BORDER_CONTENT
      : hdsEffect.PointLightIlluminatedType.DEFAULT_FEATHERING_BORDER;
  }

  private static resolveIntensity(state: LuminousLightState): number {
    if (!state.enabled || !state.pressed) return 0;
    const base: number = state.level === LuminousLightLevel.EMPHASIS ? 0.42 : 0.28;
    const scale: number = state.intensityScale ?? 1.0;
    return Math.min(0.68, Number((base * scale).toFixed(3)));
  }

  private static resolveHeight(state: LuminousLightState): Dimension {
    if (!state.enabled || !state.pressed) return 0;
    return state.level === LuminousLightLevel.EMPHASIS ? 52 : 38;
  }

  private static resolveBloom(state: LuminousLightState): number {
    if (!state.enabled || !state.pressed) return 0;
    return state.level === LuminousLightLevel.EMPHASIS ? 0.32 : 0.18;
  }
}

export class LuminousPointLightModifier implements AttributeModifier<CommonAttribute> {
  private readonly tokens: LuminousMaterialTokens;
  private readonly enabled: boolean;
  private readonly role: LuminousLightRole;
  private readonly level: LuminousLightLevel;
  private readonly intensityScale: number;

  constructor(
    tokens: LuminousMaterialTokens,
    enabled: boolean,
    role: LuminousLightRole = LuminousLightRole.SOURCE,
    level: LuminousLightLevel = LuminousLightLevel.NORMAL,
    intensityScale: number = 1.0
  ) {
    this.tokens = tokens;
    this.enabled = enabled;
    this.role = role;
    this.level = level;
    this.intensityScale = intensityScale;
  }

  private applyLight(instance: CommonAttribute, pressed: boolean): void {
    instance.visualEffect(LuminousPointLightFactory.build(this.tokens, {
      enabled: this.enabled,
      role: this.role,
      level: this.level,
      active: false,
      pressed: pressed,
      intensityScale: this.intensityScale
    }));
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    this.applyLight(instance, false);
  }

  applyPressedAttribute(instance: CommonAttribute): void {
    this.applyLight(instance, true);
  }

  applyFocusedAttribute(instance: CommonAttribute): void {
    this.applyLight(instance, false);
  }

  applyDisabledAttribute(instance: CommonAttribute): void {
    this.applyLight(instance, false);
  }

  applySelectedAttribute(instance: CommonAttribute): void {
    this.applyLight(instance, false);
  }
}


export class LuminousSurfaceModifier implements AttributeModifier<CommonAttribute> {
  private readonly tokens: LuminousMaterialTokens;
  private readonly cornerRadius: number;
  private readonly shadow: ShadowOptions;
  private readonly opaqueBorderVisible: boolean;
  private readonly fallbackColorOverride?: ResourceColor;
  private readonly translucentBackdrop: boolean;
  private readonly clickScale: number;
  private readonly clickLevel: ClickEffectLevel;

  constructor(
    tokens: LuminousMaterialTokens,
    cornerRadius: number,
    shadow: ShadowOptions,
    translucentBackdrop: boolean = false,
    opaqueBorderVisible: boolean = true,
    fallbackColorOverride?: ResourceColor,
    clickScale: number = 0,
    clickLevel: ClickEffectLevel = ClickEffectLevel.LIGHT
  ) {
    this.tokens = tokens;
    this.cornerRadius = cornerRadius;
    this.shadow = shadow;
    this.translucentBackdrop = translucentBackdrop;
    this.opaqueBorderVisible = opaqueBorderVisible;
    this.fallbackColorOverride = fallbackColorOverride;
    this.clickScale = clickScale;
    this.clickLevel = clickLevel;
  }

  private applySurface(instance: CommonAttribute): void {
    if (this.clickScale > 0) {
      instance.clickEffect({ level: this.clickLevel, scale: this.clickScale });
    }
    const surfaceColor: ResourceColor = this.fallbackColorOverride
      ?? (this.translucentBackdrop ? this.tokens.translucentCardColor : this.tokens.opaqueFallbackColor);
    const strokeColor: ResourceColor = this.translucentBackdrop
      ? this.tokens.borderColor
      : (this.opaqueBorderVisible ? this.tokens.opaqueFallbackBorderColor : this.tokens.borderColor);

    instance.shadow(this.shadow);
    instance.border({
      width: this.tokens.borderWidth,
      color: strokeColor,
      radius: this.cornerRadius
    });
    instance.borderRadius(this.cornerRadius);
    instance.backgroundColor(surfaceColor);
    instance.backgroundBlurStyle(BlurStyle.NONE);
    instance.backgroundEffect(undefined);
    instance.linearGradient(undefined);
  }

  applyNormalAttribute(instance: CommonAttribute): void { this.applySurface(instance); }
  applyPressedAttribute(instance: CommonAttribute): void { this.applySurface(instance); }
  applyFocusedAttribute(instance: CommonAttribute): void { this.applySurface(instance); }
  applyDisabledAttribute(instance: CommonAttribute): void { this.applySurface(instance); }
  applySelectedAttribute(instance: CommonAttribute): void { this.applySurface(instance); }
}

function resolveFloatingBlurRadiusVp(
  tier: LuminousFloatingBlurTier,
  preset: LuminousIntensityPreset = DEFAULT_LUMINOUS_INTENSITY_PRESET,
  epochOffset: number = 0
): number {
  let base: number = 36;
  if (tier === 'thin') base = 18;
  else if (tier === 'regular') base = 26;
  else if (tier === 'ultraThick') base = 48;
  const tuning = getLuminousIntensityTuning(preset);
  return Math.max(10, Math.round(base * tuning.blurMultiplier)) + (epochOffset % 2) * 0.02;
}

export function buildIntensityAdjustedTokens(
  isDark: boolean,
  preset: LuminousIntensityPreset
): LuminousMaterialTokens {
  const base: LuminousMaterialTokens = isDark ? LuminousMaterialTokens_DARK : LuminousMaterialTokens_LIGHT;
  if (preset === 'strong') {
    return isDark ? {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(18, 28, 42, 0.50)',
      sheetCardColor: 'rgba(28, 40, 56, 0.44)',
      floatingGlassColor: 'rgba(18, 26, 38, 0.90)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.36)',
      borderColor: 'rgba(255, 255, 255, 0.28)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.92,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    } : {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(255, 255, 255, 0.48)',
      sheetCardColor: 'rgba(255, 255, 255, 0.38)',
      floatingGlassColor: 'rgba(255, 255, 255, 0.90)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.92)',
      borderColor: 'rgba(255, 255, 255, 0.86)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.95,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    };
  }
  if (preset === 'weak') {
    return isDark ? {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(22, 32, 46, 0.74)',
      sheetCardColor: 'rgba(30, 42, 58, 0.68)',
      floatingGlassColor: 'rgba(20, 30, 44, 0.94)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.18)',
      borderColor: 'rgba(255, 255, 255, 0.14)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.70,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    } : {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(255, 255, 255, 0.74)',
      sheetCardColor: 'rgba(255, 255, 255, 0.64)',
      floatingGlassColor: 'rgba(255, 255, 255, 0.94)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.68)',
      borderColor: 'rgba(255, 255, 255, 0.62)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.72,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    };
  }
  if (preset === 'system') {
    const highTier: boolean = ImmersiveSystemCapability.isAvailable();
    if (highTier) {
      return isDark ? {
        sheetMaskColor: base.sheetMaskColor,
        opaqueFallbackColor: base.opaqueFallbackColor,
        translucentCardColor: 'rgba(19, 29, 43, 0.54)',
        sheetCardColor: 'rgba(29, 41, 57, 0.48)',
        floatingGlassColor: 'rgba(18, 27, 40, 0.90)',
        floatingBorderColor: 'rgba(255, 255, 255, 0.32)',
        borderColor: 'rgba(255, 255, 255, 0.25)',
        opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
        borderWidth: 0.86,
        pointLightColor: base.pointLightColor,
        pointLightActiveColor: base.pointLightActiveColor,
        pointLightReceiverColor: base.pointLightReceiverColor
      } : {
        sheetMaskColor: base.sheetMaskColor,
        opaqueFallbackColor: base.opaqueFallbackColor,
        translucentCardColor: 'rgba(255, 255, 255, 0.52)',
        sheetCardColor: 'rgba(255, 255, 255, 0.42)',
        floatingGlassColor: 'rgba(255, 255, 255, 0.90)',
        floatingBorderColor: 'rgba(255, 255, 255, 0.88)',
        borderColor: 'rgba(255, 255, 255, 0.82)',
        opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
        borderWidth: 0.90,
        pointLightColor: base.pointLightColor,
        pointLightActiveColor: base.pointLightActiveColor,
        pointLightReceiverColor: base.pointLightReceiverColor
      };
    }
    return isDark ? {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(21, 31, 45, 0.64)',
      sheetCardColor: 'rgba(30, 42, 58, 0.58)',
      floatingGlassColor: 'rgba(19, 29, 43, 0.92)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.24)',
      borderColor: 'rgba(255, 255, 255, 0.19)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.76,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    } : {
      sheetMaskColor: base.sheetMaskColor,
      opaqueFallbackColor: base.opaqueFallbackColor,
      translucentCardColor: 'rgba(255, 255, 255, 0.64)',
      sheetCardColor: 'rgba(255, 255, 255, 0.54)',
      floatingGlassColor: 'rgba(255, 255, 255, 0.92)',
      floatingBorderColor: 'rgba(255, 255, 255, 0.76)',
      borderColor: 'rgba(255, 255, 255, 0.70)',
      opaqueFallbackBorderColor: base.opaqueFallbackBorderColor,
      borderWidth: 0.80,
      pointLightColor: base.pointLightColor,
      pointLightActiveColor: base.pointLightActiveColor,
      pointLightReceiverColor: base.pointLightReceiverColor
    };
  }
  return base;
}

export class LuminousFloatingSurfaceModifier implements AttributeModifier<CommonAttribute> {
  private readonly tokens: LuminousMaterialTokens;
  private readonly materialEnabled: boolean;
  private readonly isDark: boolean;
  private readonly cornerRadius: number;
  private readonly tier: LuminousFloatingBlurTier;
  private readonly shadow: ShadowOptions;
  private readonly interactiveScale: number;
  private readonly intensityPreset: LuminousIntensityPreset;
  private readonly glassEpoch: number;

  constructor(
    tokens: LuminousMaterialTokens,
    materialEnabled: boolean,
    isDark: boolean,
    cornerRadius: number,
    tier: LuminousFloatingBlurTier,
    shadow: ShadowOptions,
    interactiveScale: number = 0,
    intensityPreset: LuminousIntensityPreset = DEFAULT_LUMINOUS_INTENSITY_PRESET,
    glassEpoch: number = 0
  ) {
    this.tokens = tokens;
    this.materialEnabled = materialEnabled;
    this.isDark = isDark;
    this.cornerRadius = cornerRadius;
    this.tier = tier;
    this.shadow = shadow;
    this.interactiveScale = interactiveScale;
    this.intensityPreset = intensityPreset;
    this.glassEpoch = glassEpoch;
  }

  private applyFloating(instance: CommonAttribute, pressed: boolean): void {
    if (this.interactiveScale > 0) {
      instance.clickEffect({ level: ClickEffectLevel.LIGHT, scale: this.interactiveScale });
    }
    instance.linearGradient(undefined);

    if (this.materialEnabled) {
      const tuning = getLuminousIntensityTuning(this.intensityPreset);
      instance.shadow(this.shadow);
      instance.backgroundColor(Color.Transparent);
      // 严守红线：正常态分支绝不同帧混调 systemMaterial(empty) 或 BlurStyle.NONE，防止冲掉背景滤镜。
      instance.backgroundEffect({
        radius: resolveFloatingBlurRadiusVp(this.tier, this.intensityPreset, this.glassEpoch),
        saturation: Math.max(1.05, (this.isDark ? 1.35 : 1.42) + tuning.saturationDelta),
        brightness: this.isDark ? 0.92 : 1.05,
        color: this.tokens.floatingGlassColor,
        adaptiveColor: AdaptiveColor.DEFAULT
      });
      instance.border({
        width: Math.max(0.65, 0.75 + tuning.borderWidthDelta * 0.5),
        color: this.tokens.floatingBorderColor,
        radius: this.cornerRadius
      });
      instance.borderRadius(this.cornerRadius);
      if (this.interactiveScale > 0) {
        instance.visualEffect(LuminousPointLightFactory.build(this.tokens, {
          enabled: true,
          role: LuminousLightRole.SOURCE,
          level: LuminousLightLevel.SUBTLE,
          active: false,
          pressed: pressed,
          intensityScale: tuning.pointLightScale
        }));
      }
      return;
    }

    instance.shadow(this.shadow);
    instance.backgroundEffect(undefined);
    instance.backgroundBlurStyle(BlurStyle.NONE);
    instance.backgroundColor(this.tokens.opaqueFallbackColor);
    instance.border({
      width: this.tokens.borderWidth,
      color: this.tokens.opaqueFallbackBorderColor,
      radius: this.cornerRadius
    });
    instance.borderRadius(this.cornerRadius);
  }

  applyNormalAttribute(instance: CommonAttribute): void { this.applyFloating(instance, false); }
  applyPressedAttribute(instance: CommonAttribute): void { this.applyFloating(instance, true); }
  applyFocusedAttribute(instance: CommonAttribute): void { this.applyFloating(instance, false); }
  applyDisabledAttribute(instance: CommonAttribute): void { this.applyFloating(instance, false); }
  applySelectedAttribute(instance: CommonAttribute): void { this.applyFloating(instance, false); }
}

export class Spacing {
  static readonly xs: number = 6;
  static readonly sm: number = 10;
  static readonly md: number = 14;
  static readonly lg: number = 18;
  static readonly xl: number = 24;
  static readonly xxl: number = 32;
  static readonly xxxl: number = 40;
  static readonly pageGutter: number = 20;
}

export class TypeScale {
  static readonly pageTitle: number = 24;
  static readonly sectionTitle: number = 20;
  static readonly cardTitle: number = 17;
  static readonly button: number = 17;
  static readonly body: number = 15;
  static readonly meta: number = 13;
  static readonly caption: number = 12;
  static readonly metric: number = 26;
  static readonly heroMetric: number = 58;
}

export class Radius {
  static readonly sm: number = 8;
  static readonly md: number = 12;
  static readonly lg: number = 18;
  static readonly xl: number = 26;
  static readonly sheet: number = 32;
  static readonly pill: number = 999;
}

export class AppButtonHeight {
  static readonly compact: number = 48;
  static readonly regular: number = 54;
  static readonly hero: number = 64;
}

export class FontWeightTokens {
  static readonly light: number = 300;
  static readonly regular: number = 400;
  static readonly medium: number = 500;
  static readonly semibold: number = 600;
  static readonly strong: number = 700;
  static readonly emphasis: number = 800;
  static readonly title: number = 850;
  static readonly hero: number = 900;
}

let cachedShadowDensity: number = -1;

export function resolveShadowDensity(explicitDensity?: number): number {
  if (explicitDensity !== undefined && Number.isFinite(explicitDensity) && explicitDensity > 0) {
    return explicitDensity;
  }
  try {
    const winDensity: number | undefined = AppStorage.get<number>('hongtuWindowDensity');
    if (winDensity !== undefined && Number.isFinite(winDensity) && winDensity > 0) {
      cachedShadowDensity = winDensity;
      return winDensity;
    }
  } catch (_err) {
  }
  try {
    const density: number = display.getDefaultDisplaySync().densityPixels;
    if (Number.isFinite(density) && density > 0) {
      cachedShadowDensity = density;
      return density;
    }
  } catch (_err) {
  }
  return cachedShadowDensity > 0 ? cachedShadowDensity : 3;
}

/** 将设计 vp 值按当前屏幕实时像素密度换算为 ArkUI ShadowOptions 所需的物理像素 px。 */
export function shadowVp(vpValue: number, densityOverride?: number): number {
  const density: number = resolveShadowDensity(densityOverride);
  return Math.max(1, Math.round(vpValue * density));
}

export class ShadowTokens {
  static get smRadius(): number { return shadowVp(6); }
  static get smOffsetY(): number { return shadowVp(2); }
  static get mdRadius(): number { return shadowVp(10); }
  static get mdOffsetY(): number { return shadowVp(4); }
  static get lgRadius(): number { return shadowVp(16); }
  static get lgOffsetY(): number { return shadowVp(6); }
  static get xlRadius(): number { return shadowVp(22); }
  static get xlOffsetY(): number { return shadowVp(9); }
  static get overlayRadius(): number { return shadowVp(30); }
  static get overlayOffsetY(): number { return shadowVp(12); }
}

@Observed
export class ThemeState {
  colors: SemanticThemePalette = LIGHT_SEMANTIC_PALETTE;
  fontFamily: string = 'HarmonyOS Sans';
  themeMode: ThemeMode = 'system';
  systemIsDark: boolean = false;
  isDark: boolean = false;
  luminousIntensityPreset: LuminousIntensityPreset = DEFAULT_LUMINOUS_INTENSITY_PRESET;
  luminous: LuminousMaterialTokens = buildIntensityAdjustedTokens(false, DEFAULT_LUMINOUS_INTENSITY_PRESET);
  luminousMaterialEnabled: boolean = true;
  luminousBackgroundPreset: LuminousBackgroundPreset = DEFAULT_LUMINOUS_BACKGROUND_PRESET;
  glassEpoch: number = 0;

  displayDensity: number = resolveShadowDensity();

  private _mainWindow: window.Window | undefined = undefined;
  private _cardCache: Map<string, LuminousSurfaceModifier> = new Map<string, LuminousSurfaceModifier>();
  private _floatingCache: Map<string, LuminousFloatingSurfaceModifier> = new Map<string, LuminousFloatingSurfaceModifier>();
  private _pointLightCache: Map<string, LuminousPointLightModifier> = new Map<string, LuminousPointLightModifier>();
  private _onSchemeChangeCallbacks: Array<(isDark: boolean) => void> = [];

  bindMainWindow(win: window.Window | undefined): void {
    this._mainWindow = win;
    this.syncWindowSystemBar();
  }

  getMainWindow(): window.Window | undefined {
    return this._mainWindow;
  }

  unbindMainWindow(win?: window.Window): void {
    if (win === undefined || this._mainWindow === win) {
      this._mainWindow = undefined;
    }
  }

  updateDisplayDensity(density: number): void {
    if (!Number.isFinite(density) || density <= 0) {
      return;
    }
    cachedShadowDensity = density;
    if (Math.abs(this.displayDensity - density) > 0.01) {
      this.displayDensity = density;
      this.clearCaches();
    }
  }

  /** 同步刷新窗口纯实色基底与全透明状态栏/底部导航指示条，彻底根除底部安全区泛白。 */
  syncWindowSystemBar(): void {
    const win: window.Window | undefined = this._mainWindow;
    if (win === undefined) {
      return;
    }
    try {
      win.setWindowBackgroundColor(this.colors.background);
    } catch (_bgErr) {
    }
    const contentColor: string = this.isDark ? '#ECF1F6' : '#111827';
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      }).catch((): void => {});
    } catch (_barErr) {
    }
  }

  onSchemeChanged(listener: (isDark: boolean) => void): void {
    if (this._onSchemeChangeCallbacks.indexOf(listener) < 0) {
      this._onSchemeChangeCallbacks.push(listener);
    }
  }

  private resolveIsDark(): boolean {
    if (this.themeMode === 'dark') return true;
    if (this.themeMode === 'light') return false;
    return this.systemIsDark;
  }

  private clearCaches(): void {
    clearSystemImmersiveMaterialCache();
    this._cardCache.clear();
    this._floatingCache.clear();
    this._pointLightCache.clear();
    this.glassEpoch++;
  }

  applyColorScheme(): void {
    const nextDark: boolean = this.resolveIsDark();
    this.isDark = nextDark;
    this.colors = nextDark ? DARK_SEMANTIC_PALETTE : LIGHT_SEMANTIC_PALETTE;
    this.luminous = buildIntensityAdjustedTokens(nextDark, this.luminousIntensityPreset);
    this.clearCaches();
    try {
      AppStorage.setOrCreate<boolean>('effectiveIsDark', nextDark);
      AppStorage.setOrCreate<string>(HONGTU_THEME_MODE_KEY, this.themeMode);
      AppStorage.setOrCreate<string>(HONGTU_LUMINOUS_INTENSITY_KEY, this.luminousIntensityPreset);
      AppStorage.setOrCreate<boolean>(HONGTU_LUMINOUS_BG_ENABLED_KEY, this.luminousMaterialEnabled);
      AppStorage.setOrCreate<string>(HONGTU_LUMINOUS_BG_PRESET_KEY, this.luminousBackgroundPreset);
    } catch (_err) {
    }
    this.syncWindowSystemBar();
    for (let i = 0; i < this._onSchemeChangeCallbacks.length; i++) {
      this._onSchemeChangeCallbacks[i](nextDark);
    }
  }

  setThemeMode(mode: ThemeMode): void {
    const normalized: ThemeMode = normalizeThemeMode(mode);
    if (this.themeMode === normalized && this.isDark === this.resolveIsDark()) {
      return;
    }
    this.themeMode = normalized;
    this.applyColorScheme();
  }

  setSystemIsDark(isDark: boolean): void {
    if (this.systemIsDark === isDark) return;
    this.systemIsDark = isDark;
    if (this.themeMode === 'system') {
      this.applyColorScheme();
    }
  }

  setLuminousIntensityPreset(preset: LuminousIntensityPreset): void {
    const normalized: LuminousIntensityPreset = normalizeLuminousIntensityPreset(preset);
    if (this.luminousIntensityPreset === normalized) return;
    this.luminousIntensityPreset = normalized;
    this.luminous = buildIntensityAdjustedTokens(this.isDark, normalized);
    this.clearCaches();
    try {
      AppStorage.setOrCreate<string>(HONGTU_LUMINOUS_INTENSITY_KEY, normalized);
    } catch (_err) {
    }
    for (let i = 0; i < this._onSchemeChangeCallbacks.length; i++) {
      this._onSchemeChangeCallbacks[i](this.isDark);
    }
  }

  setLuminousMaterialEnabled(enabled: boolean): void {
    if (this.luminousMaterialEnabled === enabled) return;
    this.luminousMaterialEnabled = enabled;
    this.clearCaches();
    try {
      AppStorage.setOrCreate<boolean>(HONGTU_LUMINOUS_BG_ENABLED_KEY, enabled);
    } catch (_err) {
    }
  }

  setLuminousBackgroundPreset(preset: LuminousBackgroundPreset): void {
    const normalized: LuminousBackgroundPreset = normalizeLuminousBackgroundPreset(preset);
    if (this.luminousBackgroundPreset === normalized) return;
    this.luminousBackgroundPreset = normalized;
    try {
      AppStorage.setOrCreate<string>(HONGTU_LUMINOUS_BG_PRESET_KEY, normalized);
    } catch (_err) {
    }
  }

  bumpGlassEpoch(): void {
    this.glassEpoch++;
    this._floatingCache.clear();
  }

  elevation(level: 'sm' | 'md' | 'lg' | 'xl' | 'overlay'): ShadowOptions {
    let radius: number = ShadowTokens.mdRadius;
    let offsetY: number = ShadowTokens.mdOffsetY;
    if (level === 'sm') {
      radius = ShadowTokens.smRadius;
      offsetY = ShadowTokens.smOffsetY;
    } else if (level === 'lg') {
      radius = ShadowTokens.lgRadius;
      offsetY = ShadowTokens.lgOffsetY;
    } else if (level === 'xl') {
      radius = ShadowTokens.xlRadius;
      offsetY = ShadowTokens.xlOffsetY;
    } else if (level === 'overlay') {
      radius = ShadowTokens.overlayRadius;
      offsetY = ShadowTokens.overlayOffsetY;
    }
    return { radius: radius, color: this.colors.shadowSoft, offsetX: 0, offsetY: offsetY };
  }

  resolveLuminousRenderMode(): LuminousRenderMode {
    return LuminousMaterialResolver.resolveEffectMode(LuminousCapability.get());
  }

  isLuminousMaterialEnabled(): boolean {
    return this.resolveLuminousRenderMode() === LuminousRenderMode.MATERIAL;
  }

  resolveLuminousBackgroundMode(): LuminousRenderMode {
    return LuminousMaterialResolver.resolveMode({
      toggleEnabled: this.luminousMaterialEnabled,
      capability: LuminousCapability.get()
    });
  }

  isLuminousBackgroundEnabled(): boolean {
    return this.resolveLuminousBackgroundMode() === LuminousRenderMode.MATERIAL;
  }

  useSystemImmersiveMaterial(): boolean {
    return this.isLuminousMaterialEnabled() && ImmersiveSystemCapability.isAvailable();
  }

  luminousCardModifier(
    cornerRadius: number = Radius.lg,
    shadow?: ShadowOptions,
    clickScale: number = 0
  ): LuminousSurfaceModifier {
    const resolvedShadow: ShadowOptions = shadow ?? this.elevation('md');
    const translucent: boolean = this.isLuminousBackgroundEnabled();
    const key: string = `card_${cornerRadius}_${resolvedShadow.radius}_${translucent}_${clickScale}_${this.isDark}_${this.luminousIntensityPreset}`;
    const cached = this._cardCache.get(key);
    if (cached !== undefined) return cached;
    const mod = new LuminousSurfaceModifier(this.luminous, cornerRadius, resolvedShadow, translucent, true, undefined, clickScale);
    this._cardCache.set(key, mod);
    return mod;
  }

  luminousSheetSurfaceModifier(
    cornerRadius: number = Radius.lg,
    shadow?: ShadowOptions,
    clickScale: number = 0
  ): LuminousSurfaceModifier {
    const resolvedShadow: ShadowOptions = shadow ?? this.elevation('sm');
    const materialOn: boolean = this.isLuminousMaterialEnabled();
    const overrideColor: ResourceColor = materialOn ? this.luminous.sheetCardColor : this.luminous.opaqueFallbackColor;
    const key: string = `sheet_${cornerRadius}_${resolvedShadow.radius}_${materialOn}_${clickScale}_${this.isDark}_${this.luminousIntensityPreset}`;
    const cached = this._cardCache.get(key);
    if (cached !== undefined) return cached;
    const mod = new LuminousSurfaceModifier(this.luminous, cornerRadius, resolvedShadow, false, !materialOn, overrideColor, clickScale);
    this._cardCache.set(key, mod);
    return mod;
  }

  luminousFloatingModifier(
    cornerRadius: number = Radius.lg,
    tier: LuminousFloatingBlurTier = 'thick',
    shadow?: ShadowOptions,
    interactiveScale: number = 0
  ): LuminousFloatingSurfaceModifier {
    const resolvedShadow: ShadowOptions = shadow ?? this.elevation('overlay');
    const materialOn: boolean = this.isLuminousMaterialEnabled();
    const key: string = `float_${cornerRadius}_${tier}_${resolvedShadow.radius}_${interactiveScale}_${materialOn}_${this.isDark}_${this.luminousIntensityPreset}_${this.glassEpoch % 2}`;
    const cached = this._floatingCache.get(key);
    if (cached !== undefined) return cached;
    const mod = new LuminousFloatingSurfaceModifier(
      this.luminous, materialOn, this.isDark, cornerRadius, tier, resolvedShadow,
      interactiveScale, this.luminousIntensityPreset, this.glassEpoch
    );
    this._floatingCache.set(key, mod);
    return mod;
  }

  luminousPointLightModifier(level: LuminousLightLevel = LuminousLightLevel.NORMAL): LuminousPointLightModifier {
    const enabled: boolean = this.isLuminousMaterialEnabled();
    const key: string = `pl_${level}_${enabled}_${this.isDark}_${this.luminousIntensityPreset}`;
    const cached: LuminousPointLightModifier | undefined = this._pointLightCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const scale: number = getLuminousIntensityTuning(this.luminousIntensityPreset).pointLightScale;
    const created: LuminousPointLightModifier = new LuminousPointLightModifier(
      this.luminous, enabled, LuminousLightRole.SOURCE, level, scale
    );
    this._pointLightCache.set(key, created);
    return created;
  }

  getLuminousBackgroundColors(): Array<[ResourceColor, number]> {
    return getLuminousBackgroundPresetGradient(this.luminousBackgroundPreset, this.isDark);
  }

  getLuminousBackgroundBottomColor(): ResourceColor {
    return getLuminousBackgroundPresetBottomColor(this.luminousBackgroundPreset, this.isDark);
  }

  getLuminousAmbientOrbs(): [string, string, string] {
    return getLuminousAmbientOrbColors(this.luminousBackgroundPreset, this.isDark);
  }
}

export const hongTuThemeState: ThemeState = new ThemeState();
