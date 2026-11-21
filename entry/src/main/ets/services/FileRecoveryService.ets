import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import type { FileRecoveryMetadata } from './SafeFilePublishService';
import { MAX_RECOVERY_BYTES, safeFilePublishService, safeRecoveryTarget } from './SafeFilePublishService';

export interface FileRecoveryEntry extends FileRecoveryMetadata { metadataMissing?: boolean; }

/** Recovery bytes are data only. They are never opened as a script or written to the old target. */
export class FileRecoveryService {
  private validBackupName(name: string): boolean {
    if (!/^hongtu-publish-\d{13}-\d{1,12}\.backup$/.test(name)) return false;
    const createdAt: number = Number(name.split('-')[2]);
    return createdAt > 0 && createdAt <= Date.now() + 86400000;
  }
  private fileSize(path: string, limit: number): number {
    const stat = fs.lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink() || !Number.isSafeInteger(stat.size) || stat.size < 0 || stat.size > limit) {
      throw new Error('恢复文件不是合法的应用普通文件或超出预算');
    }
    return stat.size;
  }
  private readMetadata(path: string): FileRecoveryMetadata {
    const size: number = this.fileSize(path, 16384);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const bytes: Uint8Array = new Uint8Array(size);
      let position: number = 0;
      while (position < size) {
        const buffer: ArrayBuffer = new ArrayBuffer(size - position);
        const count: number = fs.readSync(file.fd, buffer, { length: buffer.byteLength });
        if (count <= 0 || count > buffer.byteLength) throw new Error('恢复索引读取不完整');
        bytes.set(new Uint8Array(buffer, 0, count), position); position += count;
      }
      if (fs.statSync(file.fd).size !== size) throw new Error('恢复索引在读取期间改变');
      return JSON.parse(new util.TextDecoder('utf-8', { fatal: true }).decodeWithStream(bytes)) as FileRecoveryMetadata;
    } finally { fs.closeSync(file); }
  }
  list(context: common.UIAbilityContext): FileRecoveryEntry[] {
    const directory: string = safeFilePublishService.configureRecoveryDirectory(context.filesDir);
    const names: string[] = fs.listFileSync(directory, { recursion: false });
    const entries: FileRecoveryEntry[] = [];
    for (const name of names.filter((item: string) => this.validBackupName(item)).sort().reverse().slice(0, 1024)) {
      const backupPath: string = `${directory}/${name}`;
      try {
        const bytes: number = this.fileSize(backupPath, MAX_RECOVERY_BYTES);
        let entry: FileRecoveryEntry = { backupPath, targetUri: '', name: '未完成保存的安全副本', bytes,
          createdAt: Number(name.split('-')[2]), metadataMissing: true };
        try {
          const metadata: FileRecoveryMetadata = this.readMetadata(`${backupPath}.json`);
          if (metadata.backupPath !== backupPath || metadata.bytes !== bytes ||
            typeof metadata.targetUri !== 'string' || metadata.targetUri.length > 4096 || metadata.targetUri.includes('\0') ||
            safeRecoveryTarget(metadata.targetUri) !== metadata.targetUri ||
            typeof metadata.name !== 'string' || metadata.name.length === 0 || metadata.name.length > 240 || /[\u0000-\u001f\u007f]/.test(metadata.name) ||
            !Number.isSafeInteger(metadata.createdAt) || metadata.createdAt <= 0 || metadata.createdAt > Date.now() + 86400000) {
            throw new Error('恢复索引身份不符');
          }
          entry = { backupPath, targetUri: metadata.targetUri, name: metadata.name, bytes, createdAt: metadata.createdAt };
        } catch (_) { /* A verified ordinary orphan remains discoverable when its sidecar failed. */ }
        entries.push(entry);
      } catch (_) { /* Reject links, directories, missing files and size violations individually. */ }
    }
    return entries.sort((a: FileRecoveryEntry, b: FileRecoveryEntry) => b.createdAt - a.createdAt);
  }
  async exportBackup(context: common.UIAbilityContext, entry: FileRecoveryEntry, protectedTargets: string[] = []): Promise<string> {
    const current: FileRecoveryEntry | undefined = this.list(context).find((item: FileRecoveryEntry) => item.backupPath === entry.backupPath);
    if (current === undefined || current.bytes !== entry.bytes) throw new Error('此安全副本已改变或不属于当前应用');
    const base: string = current.name.replace(/[\\/:*?"<>|\u0000-\u001f\u007f]/g, '_').replace(/^\.+/, '').substring(0, 180) || '恢复副本.bin';
    const dot: number = base.lastIndexOf('.');
    const newName: string = dot > 0 ? `${base.substring(0, dot)}-恢复副本-${Date.now()}${base.substring(dot)}` : `${base}-恢复副本-${Date.now()}.bin`;
    const uris: string[] = await new picker.DocumentViewPicker(context).save({ newFileNames: [newName] });
    if (uris.length === 0) throw new Error('未选择安全副本保存位置');
    const target: string = uris[0];
    const identity: string = safeRecoveryTarget(target);
    if (identity.length === 0 || identity === current.targetUri || target === current.backupPath ||
      protectedTargets.some((item: string) => safeRecoveryTarget(item) === identity)) throw new Error('请选择新的副本位置，不能覆盖原目标或正在使用的工程');
    if (fs.accessSync(target)) {
      const file = fs.openSync(target, fs.OpenMode.READ_ONLY);
      try { if (fs.statSync(file.fd).size !== 0) throw new Error('安全副本只能保存为新文件，请重新选择位置'); }
      finally { fs.closeSync(file); }
    }
    // Recheck after the picker wait. Keep the recovery source after success and after every failure.
    const latest: FileRecoveryEntry | undefined = this.list(context).find((item: FileRecoveryEntry) => item.backupPath === current.backupPath);
    if (latest === undefined || latest.bytes !== current.bytes) throw new Error('安全副本在选择位置期间发生变化');
    safeFilePublishService.publishFile(current.backupPath, target, context.cacheDir);
    return target;
  }
}
export const fileRecoveryService = new FileRecoveryService();
