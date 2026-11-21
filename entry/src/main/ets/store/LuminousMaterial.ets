/**
 * 鸿图全局光感材质系统 — 决策层与四档强度模型（纯逻辑）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 1. 将「光感效果模式（官材/毛玻璃/点光源）」与「光感氛围背景模式」解耦；
 * 2. 提供全局沉浸光感四档位（强 strong [默认] / 均衡 balanced / 弱 weak / 跟随系统 system），
 *    统一映射 HDS 系统材质等级（EXQUISITE / GENTLE / SMOOTH / ADAPTIVE）、API 26 ImmersiveStyle、
 *    内容区光学玻璃模糊半径倍率与 hdsEffect 按压点光源强度；
 * 3. 对 API 23–25（含 API 24 2in1 模拟器）自动平滑回退至自适应毛玻璃。
 */

import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { hdsMaterial, SystemMaterialParams } from '@kit.UIDesignKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export enum LuminousRenderMode {
  MATERIAL = 'material',
  FALLBACK = 'fallback'
}

export type LuminousIntensityPreset = 'strong' | 'balanced' | 'weak' | 'system';

export const DEFAULT_LUMINOUS_INTENSITY_PRESET: LuminousIntensityPreset = 'strong';

export const LUMINOUS_INTENSITY_PRESETS: LuminousIntensityPreset[] = [
  'strong',
  'balanced',
  'weak',
  'system'
];

export function isLuminousIntensityPreset(value: string): boolean {
  return value === 'strong' || value === 'balanced' || value === 'weak' || value === 'system';
}

export function normalizeLuminousIntensityPreset(value: string | null | undefined): LuminousIntensityPreset {
  if (typeof value === 'string' && isLuminousIntensityPreset(value)) {
    return value as LuminousIntensityPreset;
  }
  return DEFAULT_LUMINOUS_INTENSITY_PRESET;
}

export function getLuminousIntensityPresetLabel(preset: LuminousIntensityPreset): string {
  if (preset === 'strong') {
    return '强';
  }
  if (preset === 'balanced') {
    return '均衡';
  }
  if (preset === 'weak') {
    return '弱';
  }
  return '跟随系统';
}

export function getLuminousIntensityPresetSubtitle(preset: LuminousIntensityPreset): string {
  if (preset === 'strong') {
    return '最强档（默认）：启用精美级沉浸折射、高倍光学玻璃模糊与高对比琉璃高光细边。';
  }
  if (preset === 'balanced') {
    return '均衡档：启用轻柔级沉浸材质与标准模糊半径，兼顾工程工作台通透感与低功耗。';
  }
  if (preset === 'weak') {
    return '弱档：收敛模糊半径与点光源强度，在大版图高频交互下进一步降低合成开销。';
  }
  return '跟随系统：自动对齐 HarmonyOS 系统沉浸光感档位与设备算力策略。';
}

export interface LuminousIntensityTuning {
  readonly preset: LuminousIntensityPreset;
  readonly blurMultiplier: number;
  readonly saturationDelta: number;
  readonly pointLightScale: number;
  readonly borderWidthDelta: number;
}

export function getLuminousIntensityTuning(preset: LuminousIntensityPreset): LuminousIntensityTuning {
  if (preset === 'strong') {
    return {
      preset: 'strong',
      blurMultiplier: 1.24,
      saturationDelta: 0.10,
      pointLightScale: 1.20,
      borderWidthDelta: 0.10
    };
  }
  if (preset === 'weak') {
    return {
      preset: 'weak',
      blurMultiplier: 0.62,
      saturationDelta: -0.14,
      pointLightScale: 0.65,
      borderWidthDelta: -0.10
    };
  }
  if (preset === 'system') {
    const immersiveSupported: boolean = ImmersiveHdsCapability.isSupported() || ImmersiveSystemCapability.isAvailable();
    return immersiveSupported ? {
      preset: 'system',
      blurMultiplier: 1.12,
      saturationDelta: 0.05,
      pointLightScale: 1.08,
      borderWidthDelta: 0.05
    } : {
      preset: 'system',
      blurMultiplier: 0.88,
      saturationDelta: -0.05,
      pointLightScale: 0.88,
      borderWidthDelta: -0.03
    };
  }
  return {
    preset: 'balanced',
    blurMultiplier: 1.0,
    saturationDelta: 0,
    pointLightScale: 1.0,
    borderWidthDelta: 0
  };
}

export interface LuminousCapabilitySnapshot {
  readonly materialSupported: boolean;
}

export interface LuminousResolveInput {
  readonly toggleEnabled: boolean;
  readonly capability: LuminousCapabilitySnapshot;
}

export class LuminousMaterialResolver {
  static resolveMode(input: LuminousResolveInput): LuminousRenderMode {
    if (!input.toggleEnabled || !input.capability.materialSupported) {
      return LuminousRenderMode.FALLBACK;
    }
    return LuminousRenderMode.MATERIAL;
  }

  static resolveEffectMode(capability: LuminousCapabilitySnapshot): LuminousRenderMode {
    return capability.materialSupported ? LuminousRenderMode.MATERIAL : LuminousRenderMode.FALLBACK;
  }
}

export class LuminousCapability {
  private static snapshot: LuminousCapabilitySnapshot | null = null;
  private static readonly UNSUPPORTED_DEVICE_TYPES: ReadonlyArray<string> = ['wearable', 'liteWearable'];

  static get(): LuminousCapabilitySnapshot {
    if (LuminousCapability.snapshot !== null) {
      return LuminousCapability.snapshot;
    }
    try {
      const supported: boolean = !LuminousCapability.UNSUPPORTED_DEVICE_TYPES.includes(deviceInfo.deviceType);
      LuminousCapability.snapshot = { materialSupported: supported };
    } catch (_err) {
      LuminousCapability.snapshot = { materialSupported: false };
    }
    return LuminousCapability.snapshot;
  }

  static isSupported(): boolean {
    return LuminousCapability.get().materialSupported;
  }

  static reset(): void {
    LuminousCapability.snapshot = null;
  }
}

export class ImmersiveHdsCapability {
  private static cachedSupported: boolean | null = null;

  static isSupported(): boolean {
    if (ImmersiveHdsCapability.cachedSupported !== null) {
      return ImmersiveHdsCapability.cachedSupported;
    }
    try {
      let hdsReady: boolean = true;
      try {
        hdsReady = deviceInfo.apiAvailable('6.1.0');
      } catch (_apiErr) {
        hdsReady = deviceInfo.sdkApiVersion >= 23;
      }
      if (!hdsReady) {
        ImmersiveHdsCapability.cachedSupported = false;
        return false;
      }
      const types: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      const supported: boolean = Array.isArray(types) && types.includes(hdsMaterial.MaterialType.IMMERSIVE);
      ImmersiveHdsCapability.cachedSupported = supported;
      return supported;
    } catch (_err) {
      ImmersiveHdsCapability.cachedSupported = false;
      return false;
    }
  }

  static reset(): void {
    ImmersiveHdsCapability.cachedSupported = null;
  }
}

export function resolveHdsSystemMaterialEffect(preset: LuminousIntensityPreset): SystemMaterialParams {
  if (preset === 'system') {
    return {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
    };
  }
  if (preset === 'weak') {
    return {
      materialType: hdsMaterial.MaterialType.ADAPTIVE,
      materialLevel: hdsMaterial.MaterialLevel.SMOOTH
    };
  }
  if (ImmersiveHdsCapability.isSupported()) {
    return {
      materialType: hdsMaterial.MaterialType.IMMERSIVE,
      materialLevel: preset === 'strong'
        ? hdsMaterial.MaterialLevel.EXQUISITE
        : hdsMaterial.MaterialLevel.GENTLE
    };
  }
  return {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: preset === 'strong'
      ? hdsMaterial.MaterialLevel.ADAPTIVE
      : hdsMaterial.MaterialLevel.SMOOTH
  };
}

export class ImmersiveSystemCapability {
  private static cachedAvailable: boolean | null = null;
  private static cachedApi26Ready: boolean | null = null;

  static isApi26Ready(): boolean {
    if (ImmersiveSystemCapability.cachedApi26Ready !== null) {
      return ImmersiveSystemCapability.cachedApi26Ready;
    }
    try {
      ImmersiveSystemCapability.cachedApi26Ready = deviceInfo.apiAvailable('26.0.0');
    } catch (_apiErr) {
      try {
        ImmersiveSystemCapability.cachedApi26Ready = deviceInfo.sdkApiVersion >= 26;
      } catch (_inner) {
        ImmersiveSystemCapability.cachedApi26Ready = false;
      }
    }
    return ImmersiveSystemCapability.cachedApi26Ready;
  }

  static isAvailable(): boolean {
    if (ImmersiveSystemCapability.cachedAvailable !== null) {
      return ImmersiveSystemCapability.cachedAvailable;
    }
    try {
      if (!ImmersiveSystemCapability.isApi26Ready() || !uiMaterial.isImmersiveMaterialSupported()) {
        ImmersiveSystemCapability.cachedAvailable = false;
        return false;
      }
      const info = uiMaterial.getMaterialInfo();
      hilog.info(0x0000, 'HongTu',
        'ImmersiveMaterial state=%{public}d type=%{public}d', info.state as number, info.type as number);
      ImmersiveSystemCapability.cachedAvailable = info.state !== uiMaterial.MaterialState.DISABLE;
      return ImmersiveSystemCapability.cachedAvailable;
    } catch (_err) {
      ImmersiveSystemCapability.cachedAvailable = false;
      return false;
    }
  }

  static reset(): void {
    ImmersiveSystemCapability.cachedAvailable = null;
    ImmersiveSystemCapability.cachedApi26Ready = null;
  }
}

export function getEmptySystemMaterial(): uiMaterial.Material | undefined {
  if (ImmersiveSystemCapability.isApi26Ready()) {
    return uiMaterial.Material.empty;
  }
  return undefined;
}

const SYSTEM_IMMERSIVE_MATERIAL_CACHE: Map<string, uiMaterial.Material> = new Map<string, uiMaterial.Material>();

export function clearSystemImmersiveMaterialCache(): void {
  SYSTEM_IMMERSIVE_MATERIAL_CACHE.clear();
}

export function buildSystemImmersiveMaterial(
  style: uiMaterial.ImmersiveStyle,
  interactive: boolean,
  materialColor?: ResourceColor,
  applyShadow: boolean = true,
  lightEffect?: uiMaterial.LightEffectOptions | null,
  colorInvert: boolean = false
): uiMaterial.Material {
  const effectiveInvert: boolean = colorInvert &&
    (style === uiMaterial.ImmersiveStyle.THIN || style === uiMaterial.ImmersiveStyle.ULTRA_THIN);
  const canCache: boolean = typeof materialColor !== 'object' && (lightEffect === null || lightEffect === undefined);
  const colorKey: string = typeof materialColor + ':' + String(materialColor);
  const lightKey: string = lightEffect === null ? 'null' : 'default';
  const key: string = [String(style), String(interactive), colorKey, String(applyShadow), lightKey, String(effectiveInvert)].join('|');
  if (canCache) {
    const hit: uiMaterial.Material | undefined = SYSTEM_IMMERSIVE_MATERIAL_CACHE.get(key);
    if (hit !== undefined) return hit;
  }
  const created: uiMaterial.Material = new uiMaterial.ImmersiveMaterial({
    style: style,
    materialColor: materialColor,
    applyShadow: applyShadow,
    interactive: interactive,
    lightEffect: lightEffect,
    colorInvert: effectiveInvert
  });
  if (canCache) SYSTEM_IMMERSIVE_MATERIAL_CACHE.set(key, created);
  return created;
}
