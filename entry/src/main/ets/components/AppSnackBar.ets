/**
 * 全局统一原生通知与轻提示（`HdsSnackBar` + `openToast` 双通道收口）
 *
 * This file is part of HongTu, licensed under GPLv3.
 *
 * 1. 可交互提示（如删除图形一键撤销、导出完成、DRC 通知）优先走 `@kit.UIDesignKit` 的 `HdsSnackBar`，
 *    配置 `BlurStrategy.ADAPTIVE`、跟随 `hongTuThemeState.isDark` 的 `themeColorMode`，并做状态签名去重防闪烁；
 * 2. 轻量状态提示或模拟器回退统一走 `uiContext.getPromptAction().openToast`，默认避开底部悬浮 `HdsTabs`（`92vp`）。
 */

import {
  BlurStrategy,
  HdsSnackBar,
  SnackBarIconOptions,
  SnackBarMessageOptions,
  SnackBarOperationOptions,
  SnackBarOperationType,
  SnackBarStyleOptions
} from '@kit.UIDesignKit';
import { UIContext } from '@kit.ArkUI';
import { hongTuThemeState } from '../store/ThemeStore';

export interface AppSnackBarOptions {
  content?: string;
  icon?: Resource;
  duration?: number;
  actionText?: string;
  onAction?: () => void;
}

export enum AppToastDuration {
  SHORT = 1500,
  NORMAL = 2000,
  LONG = 2600
}

export const APP_TOAST_BOTTOM_TAB: number = 92;
export const APP_TOAST_BOTTOM_ACTION_BAR: number = 120;

let lastSnackSignature: string = '';
let lastSnackTimestamp: number = 0;

export function showAppToast(
  uiContext: UIContext,
  message: string,
  duration: number = AppToastDuration.NORMAL,
  bottom: number = APP_TOAST_BOTTOM_TAB
): void {
  if (message.length === 0) {
    return;
  }
  try {
    uiContext.getPromptAction().openToast({ message, duration, bottom }).catch((): void => {});
  } catch (_err) {
  }
}

export function showAppSnackBar(
  uiContext: UIContext,
  title: string,
  options?: AppSnackBarOptions
): void {
  if (title.length === 0) {
    return;
  }
  const now: number = Date.now();
  const signature: string = `${title}|${options?.content ?? ''}|${options?.actionText ?? ''}`;
  if (signature === lastSnackSignature && now - lastSnackTimestamp < 850) {
    return;
  }
  lastSnackSignature = signature;
  lastSnackTimestamp = now;

  const duration: number = options?.duration ?? AppToastDuration.NORMAL;
  try {
    const snackBar: HdsSnackBar = new HdsSnackBar(uiContext);
    const iconOpts: SnackBarIconOptions = {
      icon: options?.icon ?? $r('sys.symbol.checkmark_circle')
    };
    const msgOpts: SnackBarMessageOptions = options?.content !== undefined && options.content.length > 0
      ? { title: title, content: options.content }
      : { title: title };
    const opOpts: SnackBarOperationOptions = options?.actionText !== undefined && options.onAction !== undefined
      ? {
        operationType: SnackBarOperationType.TEXT_ONLY,
        content: options.actionText,
        onContentClick: () => {
          options.onAction?.();
        }
      }
      : {};
    const styleOpts: SnackBarStyleOptions = {
      duration: duration,
      blurStrategy: BlurStrategy.ADAPTIVE,
      themeColorMode: hongTuThemeState.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    };
    snackBar.show(iconOpts, msgOpts, opOpts, styleOpts);
  } catch (_err) {
    showAppToast(uiContext, title, duration);
  }
}
