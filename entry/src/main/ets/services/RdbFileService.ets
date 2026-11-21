import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface RdbPickedReport { uri: string; name: string; xml: string; }
/** Report files are independent documents. Reads never activate or mutate a layout. */
export class RdbFileService {
  async pick(context: common.UIAbilityContext): Promise<RdbPickedReport> {
    const chooser = new picker.DocumentViewPicker(context);
    const uris: string[] = await chooser.select({ fileSuffixFilters: ['KLayout 报告数据库|.lyrdb,.xml'], maxSelectNumber: 1 });
    if (uris.length === 0) throw new Error('未选择报告');
    return await this.read(uris[0]);
  }

  async read(uri: string): Promise<RdbPickedReport> {
    if (typeof uri !== 'string' || uri.length === 0 || /^https?:/i.test(uri)) throw new Error('报告来源不是本地已选择文件');
    const file: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      // The core permits 16 Mi UTF-16 code units. Its UTF-8 input may use up to four bytes per scalar.
      if (!Number.isSafeInteger(size) || size <= 0 || size > 64 * 1024 * 1024) throw new Error('RDB 文件应为非空且不超过 64 MiB');
      const decoder = new util.TextDecoder('utf-8', { fatal: true });
      const chunks: string[] = [];
      let position: number = 0, characters: number = 0;
      while (position < size) {
        const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, size - position));
        const count: number = fs.readSync(file.fd, buffer, { offset: position, length: buffer.byteLength });
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('报告读取不完整');
        const text: string = decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true });
        characters += text.length;
        if (characters > 16 * 1024 * 1024) throw new Error('RDB 文本超过 16 Mi 字符预算，未载入');
        chunks.push(text); position += count;
      }
      const tail: string = decoder.decodeToString(new Uint8Array(0));
      if (characters + tail.length > 16 * 1024 * 1024) throw new Error('RDB 文本超过字符预算，未载入');
      chunks.push(tail);
      if (fs.statSync(file.fd).size !== size) throw new Error('报告读取期间文件长度变化，请重新载入');
      let name: string = uri.split(/[?#]/)[0].split('/').pop() ?? 'report.lyrdb';
      try { name = decodeURIComponent(name); } catch (_) { /* Keep provider literal name. */ }
      return { uri, name, xml: chunks.join('').replace(/^\uFEFF/, '') };
    } finally { fs.closeSync(file); }
  }
}

export const rdbFileService = new RdbFileService();
