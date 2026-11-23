import { KeyCode } from '@kit.InputKit';

/** Physical SDK codes stay reliable when Ctrl turns keyText into a control character. */
export function canvasKeyName(keyCode: number, keyText: string): string {
  if (keyCode >= KeyCode.KEYCODE_A && keyCode <= KeyCode.KEYCODE_Z) {
    return String.fromCharCode(65 + keyCode - KeyCode.KEYCODE_A);
  }
  if (keyCode >= KeyCode.KEYCODE_0 && keyCode <= KeyCode.KEYCODE_9) {
    return String.fromCharCode(48 + keyCode - KeyCode.KEYCODE_0);
  }
  if (keyCode >= KeyCode.KEYCODE_NUMPAD_0 && keyCode <= KeyCode.KEYCODE_NUMPAD_9) {
    return String.fromCharCode(48 + keyCode - KeyCode.KEYCODE_NUMPAD_0);
  }
  switch (keyCode) {
    case KeyCode.KEYCODE_CTRL_LEFT:
    case KeyCode.KEYCODE_CTRL_RIGHT: return 'CTRL';
    case KeyCode.KEYCODE_SHIFT_LEFT:
    case KeyCode.KEYCODE_SHIFT_RIGHT: return 'SHIFT';
    case KeyCode.KEYCODE_ALT_LEFT:
    case KeyCode.KEYCODE_ALT_RIGHT: return 'ALT';
    case KeyCode.KEYCODE_SPACE: return 'SPACE';
    case KeyCode.KEYCODE_TAB: return 'TAB';
    case KeyCode.KEYCODE_ESCAPE: return 'ESCAPE';
    case KeyCode.KEYCODE_FORWARD_DEL: return 'DELETE';
    case KeyCode.KEYCODE_DEL: return 'BACKSPACE';
    case KeyCode.KEYCODE_ENTER:
    case KeyCode.KEYCODE_NUMPAD_ENTER: return 'ENTER';
    case KeyCode.KEYCODE_F2: return 'F2';
    case KeyCode.KEYCODE_MOVE_HOME: return 'HOME';
    case KeyCode.KEYCODE_DPAD_UP: return 'ARROWUP';
    case KeyCode.KEYCODE_DPAD_DOWN: return 'ARROWDOWN';
    case KeyCode.KEYCODE_DPAD_LEFT: return 'ARROWLEFT';
    case KeyCode.KEYCODE_DPAD_RIGHT: return 'ARROWRIGHT';
    case KeyCode.KEYCODE_EQUALS:
    case KeyCode.KEYCODE_NUMPAD_ADD: return '+';
    case KeyCode.KEYCODE_MINUS:
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT: return '-';
    case KeyCode.KEYCODE_STAR:
    case KeyCode.KEYCODE_NUMPAD_MULTIPLY: return '*';
    case KeyCode.KEYCODE_LEFT_BRACKET: return '[';
    case KeyCode.KEYCODE_RIGHT_BRACKET: return ']';
  }
  const text: string = keyText.toUpperCase();
  if (text === 'CONTROL' || text === 'CTRLLEFT' || text === 'CTRLRIGHT' ||
    text === 'CTRL_LEFT' || text === 'CTRL_RIGHT') return 'CTRL';
  if (text === 'SHIFTLEFT' || text === 'SHIFTRIGHT' ||
    text === 'SHIFT_LEFT' || text === 'SHIFT_RIGHT') return 'SHIFT';
  if (text === 'ALTLEFT' || text === 'ALTRIGHT' ||
    text === 'ALT_LEFT' || text === 'ALT_RIGHT') return 'ALT';
  if (text === 'ESC') return 'ESCAPE';
  if (text === 'DEL') return 'DELETE';
  if (text === '=') return '+';
  if (text === '_') return '-';
  return text;
}
