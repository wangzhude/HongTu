/**
 * 鸿图引力动效体系与材质合成层保活 Token
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 参数对齐华为官方 HMOS 代码工坊（sample_in_harmonyos）物理弹簧体系与多形态转场标准：
 * - standard (288/30)：微交互按压回弹；
 * - transition (342/38)：临界阻尼浮层/面板进出场，干脆落定不过冲；
 * - content (195/23)：列表与内容位移；
 * - 全屏/模块转场分形态时长（UX 2.1.5.2.2）：手机 220ms、平板 260ms、2in1/大屏 320ms；
 * - 光感材质节点起始透明度保活下限 0.92，防止 opacity=0 触发合成层回收首帧闪屏；
 * - 开启「减弱动态效果」时强制将弹簧切换为 Curve.Linear（弹簧忽略 duration=0）。
 */

import { curves, FrameCallback } from '@kit.ArkUI';
import { RESPONSIVE_WIDTH_CLASS_KEY, ResponsiveWidthClass } from './ResponsiveStore';

export class NextFrameCallback extends FrameCallback {
  private readonly action: () => void;

  constructor(action: () => void) {
    super();
    this.action = action;
  }

  onFrame(_frameTimeInNano: number): void {
    this.action();
  }
}

export class AnimDuration {
  static readonly instant: number = 80;
  static readonly fast: number = 150;
  static readonly transition: number = 220;
  static readonly normal: number = 250;
  static readonly fullscreenPhone: number = 220;
  static readonly fullscreenTablet: number = 260;
  static readonly fullscreenDesktop: number = 320;
  static readonly desktopFadeExit: number = 120;
  static readonly entrance: number = 300;
  static readonly slow: number = 400;
  static readonly tabSwitch: number = 0;
}

export class GravityCurve {
  static readonly standard: curves.ICurve = curves.interpolatingSpring(0, 1, 288, 30);
  static readonly transition: curves.ICurve = curves.interpolatingSpring(0, 1, 342, 38);
  static readonly content: curves.ICurve = curves.interpolatingSpring(0, 1, 195, 23);
  static readonly page: curves.ICurve = curves.interpolatingSpring(-1, 1, 228, 30);
}

export class AnimSpring {
  static readonly motion: curves.ICurve = curves.springMotion();
  static readonly quick: curves.ICurve = curves.springMotion(0.4, 0.8);
  static readonly gentle: curves.ICurve = curves.springMotion(0.5, 1.0);
  static readonly bouncy: curves.ICurve = curves.springMotion(0.38, 0.7);
  static readonly follow: curves.ICurve = curves.responsiveSpringMotion();
}

export class AnimPress {
  static readonly cardScale: number = 0.985;
  static readonly rowScale: number = 0.99;
  static readonly tileScale: number = 0.96;
  static readonly buttonScale: number = 0.94;
  static readonly fabScale: number = 0.90;
}

/** 含 systemMaterial / backgroundEffect 的光感节点入场透明度下限，严禁设为 0。 */
export const MATERIAL_ENTRANCE_MIN_OPACITY: number = 0.92;

export class GravityGesture {
  static rubberBand(offset: number, limit: number, coefficient: number = 0.55): number {
    if (!Number.isFinite(offset) || offset === 0 || limit <= 0) {
      return 0;
    }
    const distance: number = Math.abs(offset);
    const damped: number = (1 - 1 / (distance * coefficient / limit + 1)) * limit;
    return offset > 0 ? damped : -damped;
  }
}

/** 开启减弱动态效果时物理弹簧必须降级为 Curve.Linear（弹簧曲线忽略 duration=0）。 */
export function resolveMotionCurve(springCurve: Curve | ICurve, reduceMotion: boolean): Curve | ICurve {
  return reduceMotion ? Curve.Linear : springCurve;
}

function normalizeWidthClass(raw: string | undefined): ResponsiveWidthClass {
  if (raw === 'xs' || raw === 'sm' || raw === 'md' || raw === 'lg' || raw === 'xl') {
    return raw;
  }
  return 'sm';
}

/**
 * 按 ResponsiveStore 断点与设备形态解析全屏/一级模块转场时长（UX 2.1.5.2.2）：
 * - reduceMotion 开启时强制返回 0；
 * - 2in1 桌面宿主或大屏（lg / xl）：320ms；
 * - 平板与折叠展开中屏（md）：260ms；
 * - 手机与紧凑窄屏（xs / sm）：220ms。
 */
export function resolveFullscreenTransitionDuration(
  widthClass?: ResponsiveWidthClass,
  isDesktop2in1: boolean = false,
  reduceMotion: boolean = false
): number {
  if (reduceMotion) {
    return 0;
  }
  if (isDesktop2in1) {
    return AnimDuration.fullscreenDesktop;
  }
  const resolved: ResponsiveWidthClass = widthClass !== undefined
    ? widthClass
    : normalizeWidthClass(AppStorage.get<string>(RESPONSIVE_WIDTH_CLASS_KEY));
  if (resolved === 'lg' || resolved === 'xl') {
    return AnimDuration.fullscreenDesktop;
  }
  if (resolved === 'md') {
    return AnimDuration.fullscreenTablet;
  }
  return AnimDuration.fullscreenPhone;
}
