/**
 * 键盘修饰键状态追踪与模态弹窗键盘门控（全局共享）
 *
 * 由 Index.ets / LayoutCanvasView.ets 更新或拦截，各输入型弹窗与面板在开关及获焦时同步重置，
 * 彻底消除 2in1 物理键盘修饰键粘滞与弹窗期间按键穿透画布的问题。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

/** Shift 键是否按下（全局状态，由画布键盘入口维护） */
let _shiftHeld: boolean = false;

/** Ctrl 键是否按下 */
let _ctrlHeld: boolean = false;

/** Alt 键是否按下（按住 Alt 支持临时从中心向外绘制矩形/图形，对齐 KLayout/PS/AE 习惯） */
let _altHeld: boolean = false;

/** 当前打开的模态输入弹窗令牌集合（防重复关闭或重叠打开导致计数漂移） */
let _nextModalGateToken: number = 1;
const _activeModalGateTokens: Set<number> = new Set<number>();

export function setShiftHeld(value: boolean): void {
  _shiftHeld = value;
}

export function isShiftHeld(): boolean {
  return _shiftHeld;
}

export function setCtrlHeld(value: boolean): void {
  _ctrlHeld = value;
}

export function isCtrlHeld(): boolean {
  return _ctrlHeld;
}

export function setAltHeld(value: boolean): void {
  _altHeld = value;
}

export function isAltHeld(): boolean {
  return _altHeld;
}

/** 重置可能因弹窗弹出、焦点切换或快捷键组合遗留的粘滞修饰键 */
export function resetModifierKeys(): void {
  _shiftHeld = false;
  _ctrlHeld = false;
  _altHeld = false;
}

/**
 * 模态 @CustomDialog 打开时注册键盘门控并清空粘滞修饰键，返回唯一实例令牌。
 */
export function acquireModalKeyboardGate(): number {
  resetModifierKeys();
  const token: number = _nextModalGateToken++;
  _activeModalGateTokens.add(token);
  return token;
}

/**
 * 模态 @CustomDialog 关闭销毁时释放对应门控令牌，并再次重置修饰键状态。
 */
export function releaseModalKeyboardGate(token: number): void {
  if (token > 0) {
    _activeModalGateTokens.delete(token);
  }
  resetModifierKeys();
}

/** 当前是否存在活动模态弹窗门控（供画布键盘入口统一拦截穿透按键） */
export function isModalKeyboardBlocked(): boolean {
  return _activeModalGateTokens.size > 0;
}
