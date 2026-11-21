/**
 * 鸿图材质令牌与图层渲染样式派生
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 1. 阴影统一按屏幕像素密度 `shadowVp` 换算为物理像素 `px`，杜绝高分屏阴影贴死或脏黑边；
 * 2. 圆角对齐 `8 / 12 / 18 / 26 / 999` 设计语言规范；
 * 3. 完整保留版图 `layerRenderStyle` 与 `GL_STYLE_LIMITS` 几何渲染契约。
 */

import { UiLayer } from './types';
import { ThemeManager } from './Theme';
import { hongTuThemeState, Radius, ShadowTokens, shadowVp } from '../store/ThemeStore';

/** 材质层级枚举（对应离散空间高度） */
export enum Elevation {
  NONE,
  XS,
  SM,
  MD,
  LG,
  FLOATING_SM,
  FLOATING_MD,
}

/**
 * 兼容旧版 ShadowStyle 枚举查询；新浮窗与面板优先调用 `elevationShadow(Elevation.*)` 获取密度换算 `px` 阴影。
 */
export const SHADOW_BY_ELEVATION: Map<Elevation, ShadowStyle | undefined> = new Map<Elevation, ShadowStyle | undefined>([
  [Elevation.NONE, undefined],
  [Elevation.XS, ShadowStyle.OUTER_DEFAULT_XS],
  [Elevation.SM, ShadowStyle.OUTER_DEFAULT_SM],
  [Elevation.MD, ShadowStyle.OUTER_DEFAULT_MD],
  [Elevation.LG, ShadowStyle.OUTER_DEFAULT_LG],
  [Elevation.FLOATING_SM, ShadowStyle.OUTER_FLOATING_SM],
  [Elevation.FLOATING_MD, ShadowStyle.OUTER_FLOATING_MD],
]);

/** 动态读取屏幕物理像素密度换算的柔和阴影（浅色冷蓝投影 0.13 / 深色纯黑投影 0.40）。 */
export function elevationShadow(level: Elevation, densityOverride?: number): ShadowOptions | undefined {
  if (level === Elevation.NONE) {
    return undefined;
  }
  const color: ResourceColor = hongTuThemeState.colors.shadowSoft;
  if (densityOverride !== undefined) {
    if (level === Elevation.XS || level === Elevation.SM) {
      return { radius: shadowVp(6, densityOverride), color: color, offsetX: 0, offsetY: shadowVp(2, densityOverride) };
    }
    if (level === Elevation.MD || level === Elevation.FLOATING_SM) {
      return { radius: shadowVp(10, densityOverride), color: color, offsetX: 0, offsetY: shadowVp(4, densityOverride) };
    }
    if (level === Elevation.FLOATING_MD) {
      return { radius: shadowVp(16, densityOverride), color: color, offsetX: 0, offsetY: shadowVp(6, densityOverride) };
    }
    return { radius: shadowVp(30, densityOverride), color: color, offsetX: 0, offsetY: shadowVp(12, densityOverride) };
  }
  if (level === Elevation.XS || level === Elevation.SM) {
    return { radius: ShadowTokens.smRadius, color: color, offsetX: 0, offsetY: ShadowTokens.smOffsetY };
  }
  if (level === Elevation.MD || level === Elevation.FLOATING_SM) {
    return { radius: ShadowTokens.mdRadius, color: color, offsetX: 0, offsetY: ShadowTokens.mdOffsetY };
  }
  if (level === Elevation.FLOATING_MD) {
    return { radius: ShadowTokens.lgRadius, color: color, offsetX: 0, offsetY: ShadowTokens.lgOffsetY };
  }
  return { radius: ShadowTokens.overlayRadius, color: color, offsetX: 0, offsetY: ShadowTokens.overlayOffsetY };
}

/** 材质模糊令牌接口（按 UI 层级回退映射） */
export interface BlurByLayer {
  STATUS_BAR: BlurStyle;
  TITLE_BAR: BlurStyle;
  TOOLBAR: BlurStyle;
  SIDEBAR: BlurStyle;
  INSPECTOR: BlurStyle;
  HUD: BlurStyle;
  CONTEXT_MENU: BlurStyle;
  POPOVER: BlurStyle;
  DIALOG_MASK: BlurStyle;
  SHEET: BlurStyle;
}

export const BLUR_BY_LAYER: BlurByLayer = {
  STATUS_BAR: BlurStyle.COMPONENT_THIN,
  TITLE_BAR: BlurStyle.COMPONENT_THIN,
  TOOLBAR: BlurStyle.COMPONENT_THIN,
  SIDEBAR: BlurStyle.COMPONENT_REGULAR,
  INSPECTOR: BlurStyle.COMPONENT_REGULAR,
  HUD: BlurStyle.COMPONENT_THIN,
  CONTEXT_MENU: BlurStyle.COMPONENT_THICK,
  POPOVER: BlurStyle.COMPONENT_THICK,
  DIALOG_MASK: BlurStyle.BACKGROUND_ULTRA_THICK,
  SHEET: BlurStyle.COMPONENT_THICK,
};

/** 圆角令牌接口（对齐 8/12/18/26/999 规范） */
export interface RadiusTokens {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
  capsule: number;
}

export const RADIUS: RadiusTokens = {
  xs: 6,
  sm: Radius.sm,
  md: Radius.md,
  lg: Radius.lg,
  xl: Radius.xl,
  capsule: Radius.pill,
};

export interface AlphaTokens {
  OVERLAY_STRONG: number;
  OVERLAY_MEDIUM: number;
  OVERLAY_LIGHT: number;
  DISABLED: number;
  HOVER: number;
  SELECTED: number;
  FOCUS: number;
}

export const ALPHA: AlphaTokens = {
  OVERLAY_STRONG: 0.5,
  OVERLAY_MEDIUM: 0.36,
  OVERLAY_LIGHT: 0.22,
  DISABLED: 0.4,
  HOVER: 0.08,
  SELECTED: 0.14,
  FOCUS: 0.18,
};

/** 工具：从 hex 或 rgba 颜色与 alpha 安全生成 rgba 字符串 */
export function withAlpha(colorText: string, alpha: number): string {
  if (colorText.startsWith('#') && colorText.length >= 7) {
    const r: number = parseInt(colorText.substring(1, 3), 16);
    const g: number = parseInt(colorText.substring(3, 5), 16);
    const b: number = parseInt(colorText.substring(5, 7), 16);
    return `rgba(${r},${g},${b},${alpha})`;
  }
  return colorText;
}

// ==================== 图层显示样式（线型 / 填充 / 透明度 / 动画） ====================

const DASH_NONE: string = '';
const LINE_STYLE_DASHED: string = 'dashed';
const LINE_STYLE_DOTTED: string = 'dotted';
const LINE_STYLE_DOTDASH: string = 'dotdash';

const FILL_STYLE_OUTLINE: string = 'outline';
const FILL_STYLE_HOLLOW: string = 'hollow';
const FILL_STYLE_CROSS: string = 'cross';
const FILL_STYLE_DIAGONAL: string = 'diagonal';
const FILL_STYLE_STIPPLE: string = 'stipple';

const DEFAULT_LAYER_FILL_OPACITY: number = 0.62;
const HIGHLIGHT_OPACITY_BOOST: number = 0.25;
const STROKE_OPACITY_FLOOR: number = 0.85;
const MIN_STROKE_WIDTH_PX: number = 0.5;
const MAX_STROKE_WIDTH_PX: number = 12;

export interface LayerRenderStyle {
  fillOpacity: number;
  strokeOpacity: number;
  strokeOnly: boolean;
  hatch: string;
  dashArray: number[];
  strokeWidth: number;
  highlighted: boolean;
  animated: boolean;
}

function clampUnit(v: number): number {
  if (!Number.isFinite(v)) {
    return 0;
  }
  if (v < 0) {
    return 0;
  }
  return v > 1 ? 1 : v;
}

export function dashArrayForLineStyle(lineStyle: string | undefined): number[] {
  if (lineStyle === LINE_STYLE_DASHED) {
    return [6, 4];
  }
  if (lineStyle === LINE_STYLE_DOTTED) {
    return [2, 2];
  }
  if (lineStyle === LINE_STYLE_DOTDASH) {
    return [6, 2, 2, 2];
  }
  return [];
}

export function layerRenderStyle(layer: UiLayer | undefined): LayerRenderStyle {
  const transparency: number | undefined = layer?.transparency;
  const base: number = transparency === undefined
    ? (ThemeManager.get().canvasBg === '#FFFFFF' ? 0.22 : DEFAULT_LAYER_FILL_OPACITY)
    : clampUnit(1 - transparency / 100);
  const highlighted: boolean = layer?.highlighted === true;
  const fillOpacity: number = highlighted ? clampUnit(base + HIGHLIGHT_OPACITY_BOOST) : base;
  const fillStyle: string | undefined = layer?.fillStyle;
  const hatch: string = fillStyle === FILL_STYLE_CROSS
    ? FILL_STYLE_CROSS
    : (fillStyle === FILL_STYLE_DIAGONAL
      ? FILL_STYLE_DIAGONAL
      : (fillStyle === FILL_STYLE_STIPPLE ? FILL_STYLE_STIPPLE : DASH_NONE));
  const strokeOnly: boolean = fillStyle === FILL_STYLE_OUTLINE || fillStyle === FILL_STYLE_HOLLOW ||
    hatch !== DASH_NONE;
  const lineWidth: number | undefined = layer?.lineWidth;
  let strokeWidth: number = lineWidth === undefined ? 1 : lineWidth;
  if (!Number.isFinite(strokeWidth) || strokeWidth <= 0) {
    strokeWidth = 1;
  }
  if (highlighted) {
    strokeWidth = strokeWidth + 1;
  }
  strokeWidth = Math.min(MAX_STROKE_WIDTH_PX, Math.max(MIN_STROKE_WIDTH_PX, strokeWidth));
  const style: LayerRenderStyle = {
    fillOpacity: fillOpacity,
    strokeOpacity: Math.max(STROKE_OPACITY_FLOOR, fillOpacity),
    strokeOnly: strokeOnly,
    hatch: hatch,
    dashArray: dashArrayForLineStyle(layer?.lineStyle),
    strokeWidth: strokeWidth,
    highlighted: highlighted,
    animated: layer?.animated === true,
  };
  return style;
}

/** 将图层 hatch 名称映射为 OpenGL ES 3.0 片元着色器图案槽位编码（0=实心，1=斜线，2=交叉，3=点阵）。 */
export function fillPatternForHatch(hatch: string): number {
  if (hatch === FILL_STYLE_DIAGONAL) {
    return 1;
  }
  if (hatch === FILL_STYLE_CROSS) {
    return 2;
  }
  if (hatch === FILL_STYLE_STIPPLE) {
    return 3;
  }
  return 0;
}

export const GL_STYLE_LIMITS: string =
  'GL 主路径已原生承载 cross/diagonal/stipple 填充图案，但暂不承载虚线（GLES3 无线划 stipple）；' +
  '需要看虚线线型请用有序 ArkUI 场景或 SVG 导出。';
