import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';

export async function readAutomationText(context: common.UIAbilityContext, filter: string): Promise<string | null> {
  const uris = await new picker.DocumentViewPicker(context).select({ fileSuffixFilters: [filter], maxSelectNumber: 1 });
  if (uris.length === 0) return null;
  const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
  try {
    const size: number = fs.statSync(file.fd).size;
    if (!Number.isSafeInteger(size) || size < 0 || size > 1024 * 1024) throw new Error('文件长度无效或超过 1 MiB 读取预算');
    const bytes = new Uint8Array(size);
    let position: number = 0;
    while (position < size) {
      const buffer = new ArrayBuffer(Math.min(65536, size - position));
      const count: number = fs.readSync(file.fd, buffer, { length: buffer.byteLength });
      if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('文件读取不完整');
      bytes.set(new Uint8Array(buffer, 0, count), position); position += count;
    }
    if (fs.statSync(file.fd).size !== size) throw new Error('文件在读取期间发生变化，请重新选择');
    return new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(bytes).replace(/^\uFEFF/, '');
  } finally { fs.closeSync(file); }
}

export async function saveAutomationText(context: common.UIAbilityContext, name: string, text: string,
  canPublish: () => boolean = () => true): Promise<boolean> {
  if (!canPublish()) throw new Error('导出内容已变化，请重新导出');
  const uris = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
  if (uris.length === 0) return false;
  if (!canPublish()) throw new Error('选择位置期间导出内容已变化，目标文件未写入');
  const bytes = new util.TextEncoder().encodeInto(text);
  safeFilePublishService.configureRecoveryDirectory(context.filesDir);
  safeFilePublishService.publishBuffer(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength), uris[0], context.cacheDir);
  return true;
}
