import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';

export interface EngineeringPickedFile { path: string; name: string; }
export class EngineeringFileService {
  private temporarySequence: number = 0;
  async pickComparison(context: common.UIAbilityContext): Promise<EngineeringPickedFile> {
    const chooser = new picker.DocumentViewPicker(context);
    const uris: string[] = await chooser.select({ fileSuffixFilters: ['比较版图 B|.gds,.gdsii,.oas,.oasis,.cif,.dxf'], maxSelectNumber: 1 });
    if (uris.length === 0) throw new Error('未选择比较文件');
    const uri: string = uris[0];
    let name: string = uri.split(/[?#]/)[0].split('/').pop() ?? 'comparison.gds';
    try { name = decodeURIComponent(name); } catch (_error) { /* Provider names may contain a literal percent sign. */ }
    const extension: string = name.substring(name.lastIndexOf('.')).toLowerCase();
    if (['.gds', '.gdsii', '.oas', '.oasis', '.cif', '.dxf'].indexOf(extension) < 0) throw new Error('不支持的比较格式');
    const path: string = `${context.cacheDir}/compare-b-${Date.now()}-${++this.temporarySequence}${extension}`;
    const source: fs.File = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      try {
        const bytes: number = fs.statSync(source.fd).size;
        if (!Number.isSafeInteger(bytes) || bytes <= 0 || bytes > 512 * 1024 * 1024) throw new Error('比较文件应为 1 字节至 512 MiB');
        await fs.copyFile(source.fd, path, 0);
        if (fs.statSync(path).size !== bytes) throw new Error('比较文件复制长度不一致');
        return { path: path, name: name };
      } finally { fs.closeSync(source); }
    } catch (error) { this.removeTemporary(path); throw new Error(error instanceof Error ? error.message : String(error)); }
  }
  async pickJson(context: common.UIAbilityContext): Promise<string> {
    return await this.pickText(context, '工艺包|.json');
  }
  async pickText(context: common.UIAbilityContext, filter: string): Promise<string> {
    const chooser = new picker.DocumentViewPicker(context);
    const uris: string[] = await chooser.select({ fileSuffixFilters: [filter], maxSelectNumber: 1 });
    if (uris.length === 0) throw new Error('未选择文件');
    const file: fs.File = await fs.open(uris[0], fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > 2 * 1024 * 1024) throw new Error('文本文件应为非空且不超过 2 MiB');
      const bytes = new Uint8Array(size);
      let offset: number = 0;
      while (offset < size) {
        const buffer = new ArrayBuffer(Math.min(64 * 1024, size - offset));
        const count: number = fs.readSync(file.fd, buffer, { length: buffer.byteLength });
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('文本读取不完整');
        bytes.set(new Uint8Array(buffer, 0, count), offset); offset += count;
      }
      if (fs.statSync(file.fd).size !== size) throw new Error('文本文件在读取期间发生变化，请重新选择');
      return util.TextDecoder.create('utf-8').decodeWithStream(bytes, { stream: false }).replace(/^\uFEFF/, '');
    } finally { fs.closeSync(file); }
  }
  async saveText(context: common.UIAbilityContext, name: string, text: string,
    canPublish: () => boolean = () => true, suffixChoice: string = 'JSON 文件|.json'): Promise<string> {
    if (!canPublish()) throw new Error('报告输入已变化，已取消导出');
    const chooser = new picker.DocumentViewPicker(context);
    const uris: string[] = await chooser.save({ newFileNames: [name], fileSuffixChoices: [suffixChoice] });
    if (!canPublish()) throw new Error('保存期间报告输入已变化，旧报告未保存');
    if (uris.length === 0) throw new Error('未选择保存位置');
    safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(text);
    safeFilePublishService.publishBuffer(bytes.buffer as ArrayBuffer, uris[0], context.cacheDir);
    return uris[0];
  }
  removeTemporary(path: string): void {
    if (path.length === 0) return;
    try { fs.unlinkSync(path); } catch (_error) {}
  }
}
export const engineeringFileService = new EngineeringFileService();
