import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';

export interface RdbWaiverPickedLibrary { uri: string; json: string; }
/** System-picker transport only. The library service validates every portable field
 * before CAS import. A caller guard must bind page/workspace/library/config versions. */
export class RdbWaiverFileService {
  private readonly maximumBytes: number = 128 * 1024 * 1024;
  private readonly maximumCharacters: number = 32 * 1024 * 1024;
  private check(current: () => boolean): void { if (!current()) throw new Error('豁免文件操作来源已改变，拒绝旧操作'); }
  private uri(uri: string): void {
    if (typeof uri !== 'string' || uri.length === 0 || uri.length > 4096 || /[\x00-\x1f]/.test(uri) ||
      !(/^[A-Za-z]:[\\/]/.test(uri) || /^[\\/]/.test(uri) || /^(file|datashare):\/\/.+/i.test(uri))) throw new Error('豁免库需要系统选择的本地文件');
  }
  async pick(context: common.UIAbilityContext, current: () => boolean): Promise<RdbWaiverPickedLibrary | undefined> {
    this.check(current); const chooser = new picker.DocumentViewPicker(context);
    const uris: string[] = await chooser.select({ fileSuffixFilters: ['鸿图豁免库|.json'], maxSelectNumber: 1 });
    this.check(current); if (uris.length === 0) return undefined; return this.read(uris[0], current);
  }
  read(uri: string, current: () => boolean): RdbWaiverPickedLibrary {
    this.check(current); this.uri(uri); const file: fs.File = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > this.maximumBytes) throw new Error('豁免JSON文件为空或超出128MiB预算');
      const decoder = new util.TextDecoder('utf-8', { fatal: true }); const chunks: string[] = [];
      let position: number = 0, characters: number = 0;
      while (position < size) {
        this.check(current); const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, size - position));
        const count: number = fs.readSync(file.fd, buffer, { offset: position, length: buffer.byteLength });
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('豁免JSON读取不完整');
        const text: string = decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true });
        characters += text.length; if (characters > this.maximumCharacters) throw new Error('豁免JSON超过32Mi字符预算');
        chunks.push(text); position += count;
      }
      const tail: string = decoder.decodeToString(new Uint8Array(0));
      if (characters + tail.length > this.maximumCharacters || fs.statSync(file.fd).size !== size) throw new Error('豁免JSON预算或读取长度变化');
      chunks.push(tail); this.check(current); return { uri, json: chunks.join('').replace(/^\uFEFF/, '') };
    } finally { fs.closeSync(file); }
  }
  async save(context: common.UIAbilityContext, json: string, current: () => boolean): Promise<string | undefined> {
    this.check(current);
    if (typeof json !== 'string' || json.length === 0 || json.length > this.maximumCharacters) throw new Error('导出豁免JSON预算无效');
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(json);
    if (bytes.byteLength === 0 || bytes.byteLength > this.maximumBytes) throw new Error('导出豁免UTF8字节超预算');
    if (new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes) !== json) throw new Error('导出JSON含无配对Unicode，未写入');
    const cache: string = context.cacheDir;
    const directory = fs.lstatSync(cache);
    if (!directory.isDirectory() || directory.isSymbolicLink()) throw new Error('豁免导出缓存目录无效');
    safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    const stage: string = `${cache.replace(/[\\/]$/, '')}/hongtu-waiver-${util.generateRandomUUID()}.ready`;
    if (fs.accessSync(stage)) throw new Error('豁免导出暂存身份冲突');
    try {
      const file: fs.File = fs.openSync(stage, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        let position: number = 0;
        while (position < bytes.byteLength) {
          this.check(current); const length: number = Math.min(65536, bytes.byteLength - position);
          const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset + position, bytes.byteOffset + position + length);
          const count: number = fs.writeSync(file.fd, buffer, { offset: position, length });
          if (!Number.isSafeInteger(count) || count <= 0 || count > length) throw new Error('导出豁免JSON暂存不完整'); position += count;
        }
        fs.fsyncSync(file.fd); this.check(current);
      } finally { fs.closeSync(file); }
      if (this.read(stage, current).json !== json) throw new Error('豁免JSON暂存完整回读不一致');
      const chooser = new picker.DocumentViewPicker(context);
      const uris: string[] = await chooser.save({ newFileNames: ['hongtu-waiver-library.json'], fileSuffixChoices: ['鸿图豁免库|.json'] });
      this.check(current); if (uris.length === 0) return undefined; const uri: string = uris[0]; this.uri(uri);
      safeFilePublishService.publishFile(stage, uri, cache);
      if (this.read(uri, current).json !== json) throw new Error('导出豁免JSON完整回读不一致'); return uri;
    } finally { try { if (fs.accessSync(stage)) fs.unlinkSync(stage); } catch (_) {} }
  }
}
export const rdbWaiverFileService: RdbWaiverFileService = new RdbWaiverFileService();
