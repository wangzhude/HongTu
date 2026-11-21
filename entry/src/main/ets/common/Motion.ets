import { accessibility } from '@kit.AccessibilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  AnimDuration,
  GravityCurve,
  MATERIAL_ENTRANCE_MIN_OPACITY,
  resolveFullscreenTransitionDuration,
  resolveMotionCurve
} from '../store/AnimationTokens';
import { ResponsiveWidthClass } from '../store/ResponsiveStore';

export const REDUCE_MOTION_KEY: string = 'hongtuReduceMotion';
export const USER_REDUCE_MOTION_KEY: string = 'hongtuUserReduceMotion';
export const DESKTOP_WORKSPACE_KEY: string = 'hongtuDesktopWorkspace';
export const PANEL_EXIT_DURATION_MS: number = 75;

export interface WorkbenchMotionTokens {
  feedback: number;
  panel: number;
  dialog: number;
}

export const MOTION: WorkbenchMotionTokens = {
  feedback: AnimDuration.fast,
  panel: AnimDuration.transition,
  dialog: AnimDuration.normal
};

/** One listener per mounted workbench, with the same callback used for cleanup. */
export class MotionSettings {
  private static listening: boolean = false;
  private static systemReduced: boolean = false;

  private static updateEffectiveState(): void {
    AppStorage.setOrCreate<boolean>(REDUCE_MOTION_KEY,
      MotionSettings.systemReduced || AppStorage.get<boolean>(USER_REDUCE_MOTION_KEY) === true);
  }

  static setUserReduced(enabled: boolean): void {
    AppStorage.setOrCreate<boolean>(USER_REDUCE_MOTION_KEY, enabled);
    MotionSettings.updateEffectiveState();
  }

  private static handleReduceState(enabled: boolean): void {
    MotionSettings.systemReduced = enabled;
    MotionSettings.updateEffectiveState();
  }

  static start(): void {
    if (MotionSettings.listening) return;
    PersistentStorage.persistProp(USER_REDUCE_MOTION_KEY, false);
    MotionSettings.systemReduced = false;
    MotionSettings.updateEffectiveState();
    if (deviceInfo.sdkApiVersion < 23) return;
    try {
      MotionSettings.handleReduceState(accessibility.isAnimationReduceEnabledSync());
      accessibility.onAnimationReduceStateChange(MotionSettings.handleReduceState);
      MotionSettings.listening = true;
    } catch (_) {
    }
  }

  static stop(): void {
    if (!MotionSettings.listening) return;
    try {
      accessibility.offAnimationReduceStateChange(MotionSettings.handleReduceState);
    } catch (_) {}
    MotionSettings.listening = false;
  }
}

export function isReduceMotionEnabled(): boolean {
  return AppStorage.get<boolean>(REDUCE_MOTION_KEY) === true;
}

export function isDesktop2in1MotionHost(): boolean {
  return AppStorage.get<boolean>(DESKTOP_WORKSPACE_KEY) === true;
}

export function motionDuration(milliseconds: number): number {
  return isReduceMotionEnabled() ? 0 : milliseconds;
}

/**
 * 全屏与一级工作台模块切换时长（UX 2.1.5.2.2）：
 * 手机 220ms、平板 260ms、2in1/大屏 320ms；开启减弱动态效果时为 0ms。
 */
export function fullscreenTransitionDuration(
  widthClass?: ResponsiveWidthClass,
  isDesktop2in1?: boolean
): number {
  const desktop: boolean = isDesktop2in1 ?? isDesktop2in1MotionHost();
  return resolveFullscreenTransitionDuration(widthClass, desktop, isReduceMotionEnabled());
}

/** 物理弹簧曲线，开启减弱动态效果时强制降级为 Curve.Linear（弹簧曲线忽略 duration=0）。 */
export function feedbackCurve(): Curve | ICurve {
  return resolveMotionCurve(GravityCurve.standard, isReduceMotionEnabled());
}

/**
 * 2in1 淡入淡出层级过渡（UX 2.1.5.1.1）：
 * 大屏/2in1 避免大跨度横向或纵向平移造成视觉眩晕，采用温和透明度交叉过渡；
 * 含光感材质节点默认保持 0.92 起始透明度保活，普通层级视图可传 keepMaterialAlive = false。
 */
export function desktopFadeTransition(
  keepMaterialAlive: boolean = true,
  widthClass?: ResponsiveWidthClass
): TransitionEffect {
  const reduced: boolean = isReduceMotionEnabled();
  if (reduced) {
    return TransitionEffect.opacity(1).animation({ duration: 0, curve: Curve.Linear });
  }
  const startOpacity: number = keepMaterialAlive ? MATERIAL_ENTRANCE_MIN_OPACITY : 0;
  const appearDuration: number = resolveFullscreenTransitionDuration(widthClass, true, false);
  const appearEffect: TransitionEffect = TransitionEffect.opacity(startOpacity)
    .animation({ duration: appearDuration, curve: Curve.Friction });
  const disappearEffect: TransitionEffect = TransitionEffect.opacity(0)
    .animation({ duration: keepMaterialAlive ? PANEL_EXIT_DURATION_MS : AnimDuration.desktopFadeExit, curve: Curve.Linear });
  return TransitionEffect.asymmetric(appearEffect, disappearEffect);
}

/**
 * 一级模块/视图层级过渡（UX 2.1.5.1.1 + 2.1.5.2.2）：
 * - 2in1 桌面态使用 320ms 淡入淡出层级过渡；
 * - 手机（220ms）与平板（260ms）采用按断点时长的非对称阻尼入场 + 75ms 快收退场。
 */
export function hierarchyTransition(
  edge: TransitionEdge = TransitionEdge.BOTTOM,
  isDesktop2in1?: boolean,
  widthClass?: ResponsiveWidthClass
): TransitionEffect {
  const reduced: boolean = isReduceMotionEnabled();
  if (reduced) {
    return TransitionEffect.opacity(1).animation({ duration: 0, curve: Curve.Linear });
  }
  const desktop: boolean = isDesktop2in1 ?? isDesktop2in1MotionHost();
  if (desktop) {
    return desktopFadeTransition(false, widthClass);
  }
  const x: number = edge === TransitionEdge.START ? -14 : (edge === TransitionEdge.END ? 14 : 0);
  const y: number = edge === TransitionEdge.TOP ? -10 : (edge === TransitionEdge.BOTTOM ? 10 : 0);
  const durationMs: number = resolveFullscreenTransitionDuration(widthClass, false, false);
  const appearEffect: TransitionEffect = TransitionEffect.opacity(MATERIAL_ENTRANCE_MIN_OPACITY)
    .combine(TransitionEffect.translate({ x, y }))
    .animation({ duration: durationMs, curve: resolveMotionCurve(GravityCurve.transition, false) });
  const disappearEffect: TransitionEffect = TransitionEffect.opacity(0)
    .animation({ duration: PANEL_EXIT_DURATION_MS, curve: Curve.Linear });
  return TransitionEffect.asymmetric(appearEffect, disappearEffect);
}

/**
 * 浮层与条件显隐工具条非对称动效：
 * 1. 入场采用 HMOS 代码工坊临界阻尼弹簧 `GravityCurve.transition`，起始透明度守住 `0.92` 保活光感材质合成层；
 * 2. 2in1 桌面态支持纯淡入淡出（无跨屏位移眩晕），移动端/平板带轻量边缘引导位移；
 * 3. 退场采用 `75ms` 线性快收直退 `opacity: 0`，彻底消除工具条或面板收起时悬停半秒滞留；
 * 4. 开启减弱动态效果时切换为 `0ms Curve.Linear`。
 */
export function panelTransition(edge: TransitionEdge, preferDesktopFade?: boolean): TransitionEffect {
  const reduced: boolean = isReduceMotionEnabled();
  if (reduced) {
    return TransitionEffect.opacity(1).animation({ duration: 0, curve: Curve.Linear });
  }
  const useFadeOnly: boolean = preferDesktopFade ?? isDesktop2in1MotionHost();
  if (useFadeOnly) {
    return desktopFadeTransition(true);
  }
  const x: number = edge === TransitionEdge.START ? -14 : (edge === TransitionEdge.END ? 14 : 0);
  const y: number = edge === TransitionEdge.TOP ? -10 : (edge === TransitionEdge.BOTTOM ? 10 : 0);
  const appearEffect: TransitionEffect = TransitionEffect.opacity(MATERIAL_ENTRANCE_MIN_OPACITY)
    .combine(TransitionEffect.translate({ x, y }))
    .animation({ duration: MOTION.panel, curve: resolveMotionCurve(GravityCurve.transition, false) });
  const disappearEffect: TransitionEffect = TransitionEffect.opacity(0)
    .animation({ duration: PANEL_EXIT_DURATION_MS, curve: Curve.Linear });
  return TransitionEffect.asymmetric(appearEffect, disappearEffect);
}

export function dialogTransition(preferDesktopFade?: boolean): TransitionEffect {
  const reduced: boolean = isReduceMotionEnabled();
  if (reduced) {
    return TransitionEffect.opacity(1).animation({ duration: 0, curve: Curve.Linear });
  }
  const useFadeOnly: boolean = preferDesktopFade ?? isDesktop2in1MotionHost();
  const durationMs: number = useFadeOnly ? fullscreenTransitionDuration(undefined, true) : MOTION.dialog;
  const appearEffect: TransitionEffect = useFadeOnly
    ? TransitionEffect.opacity(MATERIAL_ENTRANCE_MIN_OPACITY)
        .animation({ duration: durationMs, curve: Curve.Friction })
    : TransitionEffect.opacity(MATERIAL_ENTRANCE_MIN_OPACITY)
        .combine(TransitionEffect.scale({ x: 0.985, y: 0.985 }))
        .animation({ duration: durationMs, curve: resolveMotionCurve(GravityCurve.transition, false) });
  const disappearEffect: TransitionEffect = useFadeOnly
    ? TransitionEffect.opacity(0)
        .animation({ duration: PANEL_EXIT_DURATION_MS, curve: Curve.Linear })
    : TransitionEffect.opacity(0)
        .combine(TransitionEffect.scale({ x: 0.985, y: 0.985 }))
        .animation({ duration: PANEL_EXIT_DURATION_MS, curve: Curve.Linear });
  return TransitionEffect.asymmetric(appearEffect, disappearEffect);
}
