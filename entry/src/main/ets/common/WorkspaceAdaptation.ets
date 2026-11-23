/**
 * 鸿图工作台桌面/移动壳层一多形态与快捷 DPI 缩放控制中心
 *
 * 1. `2in1` / `pc` 设备默认启用桌面工作台壳层；
 * 2. 手机 / 折叠屏 / 平板旋转至横屏时，若开启 `hongtuAutoLandscapeDesktop`（默认开启），自动切换为与 PC 一致的完整桌面工作台布局；
 * 3. 支持顶栏一键快捷切换界面缩放比例（DPI：自动 / 65% / 75% / 80% / 90% / 100% / 115% / 125%）与横竖屏方向，实时调用 `setCustomDensity` 生效。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

export const HONGTU_FORCE_DESKTOP_MODE_KEY: string = 'hongtuForceDesktopMode';
export const HONGTU_AUTO_LANDSCAPE_DESKTOP_KEY: string = 'hongtuAutoLandscapeDesktop';
export const HONGTU_CUSTOM_DPI_SCALE_KEY: string = 'hongtuCustomDpiScale';
export const HONGTU_EFFECTIVE_DPI_SCALE_KEY: string = 'hongtuEffectiveDpiScale';
export const HONGTU_WINDOW_IS_LANDSCAPE_KEY: string = 'hongtuWindowIsLandscape';

export interface DpiScalePreset {
  scale: number;
  label: string;
  desc: string;
}

export const HONGTU_DPI_PRESETS: DpiScalePreset[] = [
  { scale: 0, label: '自动适配', desc: '手机横屏 80% · 竖屏/PC 100%' },
  { scale: 0.65, label: '65%', desc: '超紧凑桌面视野' },
  { scale: 0.75, label: '75%', desc: '紧凑多栏工作台' },
  { scale: 0.80, label: '80%', desc: '手机横屏推荐' },
  { scale: 0.90, label: '90%', desc: '适中精细排布' },
  { scale: 1.00, label: '100%', desc: '系统标准原生比例' },
  { scale: 1.15, label: '115%', desc: '适度放大触控' },
  { scale: 1.25, label: '125%', desc: '大字宽距模式' }
];

export interface WorkspaceAdaptation {
  desktop: boolean;
  density: number;
  effectiveScale: number;
  isLandscape: boolean;
}

export interface WindowDisplayController {
  reapplyAdaptation: () => void;
  toggleOrientation: () => void;
}

let activeDisplayController: WindowDisplayController | null = null;

export function bindWindowDisplayController(controller: WindowDisplayController | null): void {
  activeDisplayController = controller;
}

export function setWorkspaceCustomDpiScale(scale: number): void {
  const normalized: number = (Number.isFinite(scale) && scale >= 0.55 && scale <= 1.5)
    ? Math.round(scale * 100) / 100
    : 0;
  try {
    AppStorage.setOrCreate<number>(HONGTU_CUSTOM_DPI_SCALE_KEY, normalized);
  } catch (_) {}
  activeDisplayController?.reapplyAdaptation();
}

export function setWorkspaceAutoLandscapeDesktop(enabled: boolean): void {
  try {
    AppStorage.setOrCreate<boolean>(HONGTU_AUTO_LANDSCAPE_DESKTOP_KEY, enabled);
  } catch (_) {}
  activeDisplayController?.reapplyAdaptation();
}

export function setWorkspaceForceDesktopMode(enabled: boolean): void {
  try {
    AppStorage.setOrCreate<boolean>(HONGTU_FORCE_DESKTOP_MODE_KEY, enabled);
  } catch (_) {}
  activeDisplayController?.reapplyAdaptation();
}

export function toggleWorkspaceOrientation(): void {
  activeDisplayController?.toggleOrientation();
}

export function resolveSystemDensity(windowDensity: number, displayDensity: number): number {
  if (Number.isFinite(windowDensity) && windowDensity > 0) {
    return windowDensity;
  }
  return Number.isFinite(displayDensity) && displayDensity > 0 ? displayDensity : 1;
}

export function adaptWorkspace(
  widthPx: number,
  heightPx: number,
  systemDensity: number,
  deviceType: string,
  forceDesktopMode: boolean = false,
  autoLandscapeDesktop: boolean = false,
  customDpiScale: number = 0
): WorkspaceAdaptation {
  const baseDensity: number = Number.isFinite(systemDensity) && systemDensity > 0 ? systemDensity : 1;
  const nativeDesktop: boolean = deviceType === '2in1' || deviceType === 'pc';
  const isLandscape: boolean = Number.isFinite(widthPx) && Number.isFinite(heightPx) &&
    widthPx > 0 && heightPx > 0 && widthPx > heightPx * 1.12;
  const desktop: boolean = nativeDesktop || forceDesktopMode === true || (autoLandscapeDesktop === true && isLandscape);

  let effectiveScale: number = 1.0;
  if (Number.isFinite(customDpiScale) && customDpiScale >= 0.55 && customDpiScale <= 1.5) {
    effectiveScale = Math.round(customDpiScale * 100) / 100;
  } else if (!nativeDesktop && desktop && isLandscape) {
    const rawSpanVp: number = widthPx / baseDensity;
    if (rawSpanVp < 980) {
      effectiveScale = 0.80;
    }
  }

  const effectiveDensity: number = Math.max(0.75, Math.round(baseDensity * effectiveScale * 1000) / 1000);
  return {
    desktop,
    density: effectiveDensity,
    effectiveScale,
    isLandscape
  };
}
