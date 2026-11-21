import { KeyCode } from '@kit.InputKit';

/** Physical SDK codes stay reliable when Ctrl turns keyText into a control character. */
export function canvasKeyName(keyCode: number, keyText: string): string {
  if (keyCode >= KeyCode.KEYCODE_A && keyCode <= KeyCode.KEYCODE_Z) {
    return String.fromCharCode(65 + keyCode - KeyCode.KEYCODE_A);
  }
  switch (keyCode) {
    case KeyCode.KEYCODE_CTRL_LEFT:
    case KeyCode.KEYCODE_CTRL_RIGHT: return 'CTRL';
    case KeyCode.KEYCODE_SHIFT_LEFT:
    case KeyCode.KEYCODE_SHIFT_RIGHT: return 'SHIFT';
    case KeyCode.KEYCODE_SPACE: return 'SPACE';
    case KeyCode.KEYCODE_TAB: return 'TAB';
    case KeyCode.KEYCODE_ESCAPE: return 'ESCAPE';
    case KeyCode.KEYCODE_FORWARD_DEL: return 'DELETE';
    case KeyCode.KEYCODE_DEL: return 'BACKSPACE';
    case KeyCode.KEYCODE_ENTER:
    case KeyCode.KEYCODE_NUMPAD_ENTER: return 'ENTER';
    case KeyCode.KEYCODE_DPAD_UP: return 'ARROWUP';
    case KeyCode.KEYCODE_DPAD_DOWN: return 'ARROWDOWN';
    case KeyCode.KEYCODE_DPAD_LEFT: return 'ARROWLEFT';
    case KeyCode.KEYCODE_DPAD_RIGHT: return 'ARROWRIGHT';
    case KeyCode.KEYCODE_EQUALS:
    case KeyCode.KEYCODE_NUMPAD_ADD: return '+';
    case KeyCode.KEYCODE_MINUS:
    case KeyCode.KEYCODE_NUMPAD_SUBTRACT: return '-';
  }
  const text: string = keyText.toUpperCase();
  if (text === 'CONTROL' || text === 'CTRLLEFT' || text === 'CTRLRIGHT' ||
    text === 'CTRL_LEFT' || text === 'CTRL_RIGHT') return 'CTRL';
  if (text === 'SHIFTLEFT' || text === 'SHIFTRIGHT' ||
    text === 'SHIFT_LEFT' || text === 'SHIFT_RIGHT') return 'SHIFT';
  if (text === 'ESC') return 'ESCAPE';
  if (text === 'DEL') return 'DELETE';
  if (text === '=') return '+';
  if (text === '_') return '-';
  return text;
}
