/**
 * 鸿图字体注册
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { font } from '@kit.ArkUI';

/** 已注册的字体族名常量 */
export const FONT_MONO = 'HongTuMono';
export const FONT_SANS = 'HongTuSans';

/** 注册自定义字体，需在 EntryAbility 启动时调用一次 */
export function registerFonts(context: Context): void {
  // JetBrainsMono 用于坐标/数值显示
  font.registerFont({
    familyName: FONT_MONO,
    familySrc: '/rawfile/docs/_shared/fonts/JetBrainsMono-Regular.ttf'
  });
  // InstrumentSans 用于 UI 文本
  font.registerFont({
    familyName: FONT_SANS,
    familySrc: '/rawfile/docs/_shared/fonts/InstrumentSans-Regular.ttf'
  });
}
