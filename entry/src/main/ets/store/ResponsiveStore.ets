/**
 * 鸿图一多响应式断点、UIContext 原生二维断点、三折叠 F·M·G 姿态与动态安全区快照
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { display, uiAppearance, UIContext } from '@kit.ArkUI';

export const RESPONSIVE_WINDOW_WIDTH_KEY: string = 'responsive.windowWidth';
export const RESPONSIVE_WINDOW_HEIGHT_KEY: string = 'responsive.windowHeight';
export const RESPONSIVE_WIDTH_CLASS_KEY: string = 'responsive.widthClass';
export const RESPONSIVE_HEIGHT_CLASS_KEY: string = 'responsive.heightClass';
export const RESPONSIVE_IS_FOLDABLE_KEY: string = 'responsive.isFoldable';
export const RESPONSIVE_FOLD_STATUS_KEY: string = 'responsive.foldStatus';
export const RESPONSIVE_TRIFOLD_POSTURE_KEY: string = 'responsive.triFoldPosture';
export const RESPONSIVE_ASPECT_CLASS_KEY: string = 'responsive.aspectClass';
export const RESPONSIVE_FONT_SCALE_KEY: string = 'responsive.fontScale';
export const RESPONSIVE_COMPACT_SQUARE_KEY: string = 'responsive.compactSquare';
export const RESPONSIVE_IS_FLOATING_WINDOW_KEY: string = 'responsive.isFloatingWindow';

export const SAFE_AREA_TOP_VP_KEY: string = 'hongtuSafeAreaTopVp';
export const SAFE_AREA_BOTTOM_VP_KEY: string = 'hongtuSafeAreaBottomVp';
export const SAFE_AREA_LEFT_VP_KEY: string = 'hongtuSafeAreaLeftVp';
export const SAFE_AREA_RIGHT_VP_KEY: string = 'hongtuSafeAreaRightVp';

/** 内部类型名保持 Responsive* 前缀，严禁遮蔽 ArkUI 全局 WidthBreakpoint / HeightBreakpoint 枚举。 */
export type ResponsiveWidthClass = 'xs' | 'sm' | 'md' | 'lg' | 'xl';
export type ResponsiveHeightClass = 'short' | 'regular' | 'tall';
export type ResponsiveAspectClass = 'square' | 'tall' | 'wide' | 'ultrawide';

/**
 * 折叠与三折叠（Mate XT / XTs / XT 2）姿态语义枚举：
 * - SINGLE_F：单屏折叠态（F / N 态，典型 sm*lg）
 * - DUAL_M：双屏展开态（M / LM / RM 态，典型 md*md）
 * - TRIPLE_G：三屏全展态（G 态，典型 lg*sm）
 * - BI_EXPANDED：常规双折叠完全展开态
 * - HALF_FOLDED：悬停半折态（含双轴半折组合）
 */
export enum TriFoldPosture {
  NONE = 'none',
  SINGLE_F = 'single_f',
  DUAL_M = 'dual_m',
  TRIPLE_G = 'triple_g',
  BI_EXPANDED = 'bi_expanded',
  HALF_FOLDED = 'half_folded'
}

export interface SafeAreaInsetsVp {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

export interface ResponsiveSnapshot {
  windowWidth: number;
  windowHeight: number;
  widthClass: ResponsiveWidthClass;
  heightClass: ResponsiveHeightClass;
  isFoldable: boolean;
  foldStatus: number;
  triFoldPosture: TriFoldPosture;
  aspectClass: ResponsiveAspectClass;
  fontScale: number;
  compactSquare: boolean;
}

export const DEFAULT_RESPONSIVE_SNAPSHOT: ResponsiveSnapshot = {
  windowWidth: 1280,
  windowHeight: 800,
  widthClass: 'lg',
  heightClass: 'regular',
  isFoldable: false,
  foldStatus: 0,
  triFoldPosture: TriFoldPosture.NONE,
  aspectClass: 'wide',
  fontScale: 1,
  compactSquare: false
};

// HarmonyOS @ohos.display FoldStatus 标准数值常量（兼容 API 15+ 双轴三折叠枚举）
const FOLD_STATUS_EXPANDED_CODE: number = 1;
const FOLD_STATUS_FOLDED_CODE: number = 2;
const FOLD_STATUS_HALF_FOLDED_CODE: number = 3;
const FOLD_STATUS_TRIPLE_EXPANDED_G_CODE: number = 11; // FOLD_STATUS_EXPANDED_WITH_SECOND_EXPANDED
const FOLD_STATUS_DUAL_M_CODE: number = 12;            // FOLD_STATUS_FOLDED_WITH_SECOND_EXPANDED
const FOLD_STATUS_HALF_FIRST_SECOND_EXPANDED_CODE: number = 13; // FOLD_STATUS_HALF_FOLDED_WITH_SECOND_EXPANDED
const FOLD_STATUS_FIRST_EXPANDED_SECOND_FOLDED_CODE: number = 14;
const FOLD_STATUS_EXPANDED_SECOND_HALF_CODE: number = 21;       // FOLD_STATUS_EXPANDED_WITH_SECOND_HALF_FOLDED
const FOLD_STATUS_FOLDED_SECOND_HALF_CODE: number = 22;         // FOLD_STATUS_FOLDED_WITH_SECOND_HALF_FOLDED
const FOLD_STATUS_BOTH_HALF_FOLDED_CODE: number = 23;           // FOLD_STATUS_HALF_FOLDED_WITH_SECOND_HALF_FOLDED

let boundUIContext: UIContext | undefined = undefined;

/** 在 EntryAbility.loadContent 成功后绑定主窗口 UIContext，启用系统原生横纵断点查询。 */
export function bindResponsiveUIContext(context: UIContext | undefined): void {
  boundUIContext = context;
}

export function clearResponsiveUIContext(): void {
  boundUIContext = undefined;
}

function sanitizeDim(val: number, fallback: number): number {
  return Number.isFinite(val) && val > 0 ? val : fallback;
}

/** 纯函数宽度断点回退（无 UIContext 或单元测试环境下使用）。 */
export function getWidthClass(widthVp: number): ResponsiveWidthClass {
  if (widthVp < 320) return 'xs';
  if (widthVp < 600) return 'sm';
  if (widthVp < 840) return 'md';
  if (widthVp < 1440) return 'lg';
  return 'xl';
}

/** 纯函数高度断点回退（无 UIContext 或单元测试环境下使用）。 */
export function getHeightClass(heightVp: number): ResponsiveHeightClass {
  if (heightVp < 480) return 'short';
  if (heightVp < 820) return 'regular';
  return 'tall';
}

function resolveWidthClassWithUIContext(widthVp: number, uiContext?: UIContext): ResponsiveWidthClass {
  const ctx: UIContext | undefined = uiContext ?? boundUIContext;
  if (ctx !== undefined) {
    try {
      const bp: WidthBreakpoint = ctx.getWindowWidthBreakpoint();
      if (bp === WidthBreakpoint.WIDTH_XS) return 'xs';
      if (bp === WidthBreakpoint.WIDTH_SM) return 'sm';
      if (bp === WidthBreakpoint.WIDTH_MD) return 'md';
      if (bp === WidthBreakpoint.WIDTH_LG) {
        return widthVp >= 1440 ? 'xl' : 'lg';
      }
      if (bp === WidthBreakpoint.WIDTH_XL) return 'xl';
    } catch (_err) {
    }
  }
  return getWidthClass(widthVp);
}

function resolveHeightClassWithUIContext(
  widthVp: number,
  heightVp: number,
  uiContext?: UIContext
): ResponsiveHeightClass {
  if (heightVp < 480) {
    return 'short';
  }
  const ctx: UIContext | undefined = uiContext ?? boundUIContext;
  if (ctx !== undefined) {
    try {
      const hBp: HeightBreakpoint = ctx.getWindowHeightBreakpoint();
      if (hBp === HeightBreakpoint.HEIGHT_SM) return 'short';
      if (hBp === HeightBreakpoint.HEIGHT_MD) return 'regular';
      if (hBp === HeightBreakpoint.HEIGHT_LG) return 'tall';
    } catch (_err) {
    }
  }
  const ratio: number = heightVp / Math.max(1, widthVp);
  if (ratio < 0.8) return 'short';
  if (ratio < 1.2) return 'regular';
  return getHeightClass(heightVp);
}

export function getAspectClass(widthVp: number, heightVp: number): ResponsiveAspectClass {
  const ratio: number = widthVp / Math.max(1, heightVp);
  if (ratio < 0.75) return 'tall';
  if (ratio < 1.35) return 'square';
  if (ratio < 2.05) return 'wide';
  return 'ultrawide';
}

/** 识别双轴三折叠（F 单屏 / M 双屏 / G 三屏）及常规双折叠姿态。 */
export function resolveTriFoldPosture(
  isFoldable: boolean,
  foldStatus: number,
  widthClass: ResponsiveWidthClass = 'sm',
  heightClass: ResponsiveHeightClass = 'tall'
): TriFoldPosture {
  if (!isFoldable || foldStatus <= 0) {
    return TriFoldPosture.NONE;
  }
  if (foldStatus === FOLD_STATUS_TRIPLE_EXPANDED_G_CODE) {
    return TriFoldPosture.TRIPLE_G;
  }
  if (foldStatus === FOLD_STATUS_DUAL_M_CODE || foldStatus === FOLD_STATUS_FIRST_EXPANDED_SECOND_FOLDED_CODE) {
    return TriFoldPosture.DUAL_M;
  }
  if (
    foldStatus === FOLD_STATUS_HALF_FOLDED_CODE ||
    foldStatus === FOLD_STATUS_HALF_FIRST_SECOND_EXPANDED_CODE ||
    foldStatus === FOLD_STATUS_EXPANDED_SECOND_HALF_CODE ||
    foldStatus === FOLD_STATUS_FOLDED_SECOND_HALF_CODE ||
    foldStatus === FOLD_STATUS_BOTH_HALF_FOLDED_CODE
  ) {
    if (foldStatus === FOLD_STATUS_HALF_FIRST_SECOND_EXPANDED_CODE && widthClass === 'md') {
      return TriFoldPosture.DUAL_M;
    }
    return TriFoldPosture.HALF_FOLDED;
  }
  if (foldStatus === FOLD_STATUS_FOLDED_CODE) {
    return TriFoldPosture.SINGLE_F;
  }
  if (foldStatus === FOLD_STATUS_EXPANDED_CODE) {
    if ((widthClass === 'lg' || widthClass === 'xl') && heightClass === 'short') {
      return TriFoldPosture.TRIPLE_G;
    }
    return TriFoldPosture.BI_EXPANDED;
  }
  return TriFoldPosture.NONE;
}

/** 双栏布局仅在 wide / ultrawide 开启；大折叠旋转至接近正方形（square）时退回单栏免挤压。 */
export function shouldUseDualColumnLayout(widthClass: ResponsiveWidthClass, aspectClass: ResponsiveAspectClass): boolean {
  return (widthClass === 'md' || widthClass === 'lg' || widthClass === 'xl') &&
    (aspectClass === 'wide' || aspectClass === 'ultrawide');
}

/** 阔折叠 1:1 外屏（sm*md）或中小方形视口紧凑降级判定。 */
export function isCompactSquareScreen(
  widthVp: number,
  heightVp: number,
  isFoldable: boolean = false,
  foldStatus: number = 0,
  uiContext?: UIContext
): boolean {
  const ctx: UIContext | undefined = uiContext ?? boundUIContext;
  if (ctx !== undefined) {
    try {
      const wBp: WidthBreakpoint = ctx.getWindowWidthBreakpoint();
      const hBp: HeightBreakpoint = ctx.getWindowHeightBreakpoint();
      if (wBp === WidthBreakpoint.WIDTH_SM && hBp === HeightBreakpoint.HEIGHT_MD && heightVp <= 560) {
        return true;
      }
    } catch (_err) {
    }
  }
  const aspect: ResponsiveAspectClass = getAspectClass(widthVp, heightVp);
  if (aspect !== 'square') return false;
  const foldedOuter: boolean = isFoldable && foldStatus === (display.FoldStatus.FOLD_STATUS_FOLDED as number);
  return foldedOuter || (widthVp <= 520 && heightVp <= 520);
}

function readIsFoldable(): boolean {
  try {
    return display.isFoldable();
  } catch (_err) {
    return false;
  }
}

function readFoldStatus(): number {
  try {
    return display.getFoldStatus() as number;
  } catch (_err) {
    return 0;
  }
}

function readFontScale(): number {
  try {
    const scale: number = uiAppearance.getFontScale();
    return Number.isFinite(scale) && scale > 0 ? scale : 1;
  } catch (_err) {
    return 1;
  }
}

export function createResponsiveSnapshot(
  widthVp: number,
  heightVp: number,
  uiContext?: UIContext
): ResponsiveSnapshot {
  const w: number = sanitizeDim(widthVp, 1280);
  const h: number = sanitizeDim(heightVp, 800);
  const foldable: boolean = readIsFoldable();
  const foldStatus: number = readFoldStatus();
  const widthClass: ResponsiveWidthClass = resolveWidthClassWithUIContext(w, uiContext);
  const heightClass: ResponsiveHeightClass = resolveHeightClassWithUIContext(w, h, uiContext);
  return {
    windowWidth: w,
    windowHeight: h,
    widthClass: widthClass,
    heightClass: heightClass,
    isFoldable: foldable,
    foldStatus: foldStatus,
    triFoldPosture: resolveTriFoldPosture(foldable, foldStatus, widthClass, heightClass),
    aspectClass: getAspectClass(w, h),
    fontScale: readFontScale(),
    compactSquare: isCompactSquareScreen(w, h, foldable, foldStatus, uiContext)
  };
}

export function publishResponsiveSnapshot(snapshot: ResponsiveSnapshot): void {
  try {
    AppStorage.setOrCreate<number>(RESPONSIVE_WINDOW_WIDTH_KEY, snapshot.windowWidth);
    AppStorage.setOrCreate<number>(RESPONSIVE_WINDOW_HEIGHT_KEY, snapshot.windowHeight);
    AppStorage.setOrCreate<string>(RESPONSIVE_WIDTH_CLASS_KEY, snapshot.widthClass);
    AppStorage.setOrCreate<string>(RESPONSIVE_HEIGHT_CLASS_KEY, snapshot.heightClass);
    AppStorage.setOrCreate<boolean>(RESPONSIVE_IS_FOLDABLE_KEY, snapshot.isFoldable);
    AppStorage.setOrCreate<number>(RESPONSIVE_FOLD_STATUS_KEY, snapshot.foldStatus);
    AppStorage.setOrCreate<string>(RESPONSIVE_TRIFOLD_POSTURE_KEY, snapshot.triFoldPosture);
    AppStorage.setOrCreate<string>(RESPONSIVE_ASPECT_CLASS_KEY, snapshot.aspectClass);
    AppStorage.setOrCreate<number>(RESPONSIVE_FONT_SCALE_KEY, snapshot.fontScale);
    AppStorage.setOrCreate<boolean>(RESPONSIVE_COMPACT_SQUARE_KEY, snapshot.compactSquare);
  } catch (_err) {
  }
}

export function publishSafeAreaInsetsVp(insets: SafeAreaInsetsVp): void {
  try {
    AppStorage.setOrCreate<number>(SAFE_AREA_TOP_VP_KEY, Math.max(0, Math.round(insets.top * 10) / 10));
    AppStorage.setOrCreate<number>(SAFE_AREA_BOTTOM_VP_KEY, Math.max(0, Math.round(insets.bottom * 10) / 10));
    AppStorage.setOrCreate<number>(SAFE_AREA_LEFT_VP_KEY, Math.max(0, Math.round(insets.left * 10) / 10));
    AppStorage.setOrCreate<number>(SAFE_AREA_RIGHT_VP_KEY, Math.max(0, Math.round(insets.right * 10) / 10));
  } catch (_err) {
  }
}

export function registerFoldStatusListener(onChange: (status: display.FoldStatus) => void): boolean {
  try {
    display.on('foldStatusChange', onChange);
    return true;
  } catch (_err) {
    return false;
  }
}

export function unregisterFoldStatusListener(onChange: (status: display.FoldStatus) => void): void {
  try {
    display.off('foldStatusChange', onChange);
  } catch (_err) {
  }
}

export function getNavigationBlurRadius(widthClass: ResponsiveWidthClass): number {
  if (widthClass === 'lg' || widthClass === 'xl') return 16;
  if (widthClass === 'md') return 14;
  return 12;
}

export function getNavigationMaskExtraHeight(widthClass: ResponsiveWidthClass): number {
  if (widthClass === 'lg' || widthClass === 'xl') return 4;
  if (widthClass === 'md') return 6;
  return 8;
}

export function getNavigationBlurEndOffset(widthClass: ResponsiveWidthClass): number {
  return widthClass === 'xs' || widthClass === 'sm' ? 28 : 36;
}

export function getFloatingTabBottomSpacer(heightClass: ResponsiveHeightClass, fontScale: number = 1): number {
  const base: number = heightClass === 'short' ? 76 : 86;
  const bottomSafeVp: number = AppStorage.get<number>(SAFE_AREA_BOTTOM_VP_KEY) ?? 0;
  return Math.round(base * Math.min(1.2, Math.max(1, fontScale)) + Math.max(0, bottomSafeVp));
}

export function publishFloatingWindowStatus(isFloating: boolean): void {
  try {
    AppStorage.setOrCreate<boolean>(RESPONSIVE_IS_FLOATING_WINDOW_KEY, isFloating);
  } catch (_err) {
  }
}
