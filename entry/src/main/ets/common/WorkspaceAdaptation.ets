/**
 * 鸿图工作台桌面/移动壳层一多形态判定
 *
 * 1. 默认仅在真实 `2in1` / `pc` 设备（或用户显式开启手动桌面模式开关）时启用左侧窄轨 `hongtuDesktopWorkspace`；
 * 2. 阔折叠 1:1 外屏、直板机横竖屏、双折叠/三折叠（F·M·G）展开态及平板统一保留底部悬浮 `HdsTabs`；
 * 3. 始终保持系统原生像素密度，不再对非 2in1 设备强行按 0.8 缩小 `customDensity`。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

export const HONGTU_FORCE_DESKTOP_MODE_KEY: string = 'hongtuForceDesktopMode';

export interface WorkspaceAdaptation {
  desktop: boolean;
  density: number;
}

export function resolveSystemDensity(windowDensity: number, displayDensity: number): number {
  if (Number.isFinite(windowDensity) && windowDensity > 0) {
    return windowDensity;
  }
  return Number.isFinite(displayDensity) && displayDensity > 0 ? displayDensity : 1;
}

export function adaptWorkspace(
  _widthPx: number,
  _heightPx: number,
  systemDensity: number,
  deviceType: string,
  forceDesktopMode: boolean = false
): WorkspaceAdaptation {
  const density: number = Number.isFinite(systemDensity) && systemDensity > 0 ? systemDensity : 1;
  const nativeDesktop: boolean = deviceType === '2in1' || deviceType === 'pc';
  const desktop: boolean = nativeDesktop || forceDesktopMode === true;
  return {
    desktop: desktop,
    density: density
  };
}
