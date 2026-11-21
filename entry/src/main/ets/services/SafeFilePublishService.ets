import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export const MAX_RECOVERY_BYTES: number = 1024 * 1024 * 1024 * 1024;
export interface FileRecoveryMetadata {
  backupPath: string;
  targetUri: string;
  name: string;
  bytes: number;
  createdAt: number;
}
export function recoveryDirectoryFor(filesDir: string): string {
  if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
    !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
    filesDir.split(/[\\/]+/).some((part: string) => part === '..' || part === '.')) throw new Error('恢复目录必须位于应用持久 filesDir');
  return `${filesDir.replace(/[\\/]+$/, '')}/hongtu-file-recovery`;
}
/** Description only. Never persist picker query tokens or URI credentials. */
export function safeRecoveryTarget(uri: string): string {
  const plain: string = uri.split(/[?#]/)[0];
  return plain.replace(/^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)[^/]*@/, '$1');
}

export interface FilePublishResult {
  bytes: number;
  strategy: 'atomic-rename' | 'backup-and-verify';
  backupPath?: string;
}

/** A provider URI cannot be renamed. Never truncate it before a verified backup exists. */
export class SafeFilePublishService {
  private sequence: number = 0;
  private active: Set<string> = new Set<string>();
  private recoveryDirectory: string = '';
  configureRecoveryDirectory(filesDir: string): string {
    const directory: string = recoveryDirectoryFor(filesDir);
    const rootStat = fs.lstatSync(filesDir);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('应用持久目录无效');
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('恢复目录不是应用普通目录');
    this.recoveryDirectory = directory;
    try {
      const entries: string[] = fs.listFileSync(directory, { recursion: false });
      for (let i: number = 0; i < entries.length; i++) {
        const entry: string = entries[i];
        if (entry.endsWith('.json.pending') || entry.endsWith('.ready')) {
          this.remove(`${directory}/${entry}`);
        }
      }
    } catch (_) {}
    return directory;
  }
  private nextPath(directory: string, suffix: string): string {
    if (directory.length === 0 || directory.includes('://')) throw new Error('安全保存需要应用缓存目录');
    for (let attempt: number = 0; attempt < 100; attempt++) {
      const path: string = `${directory.replace(/[\\/]$/, '')}/hongtu-publish-${Date.now()}-${++this.sequence}${suffix}`;
      if (!fs.accessSync(path)) return path;
    }
    throw new Error('无法生成独立保存文件');
  }
  private size(path: string): number {
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size < 0) throw new Error('文件长度无效');
      return size;
    } finally { fs.closeSync(file); }
  }
  private writeAll(fd: number, buffer: ArrayBuffer): void {
    let position: number = 0;
    while (position < buffer.byteLength) {
      const part: ArrayBuffer = buffer.slice(position);
      const count: number = fs.writeSync(fd, part, { length: part.byteLength });
      if (count <= 0 || count > part.byteLength) throw new Error('安全保存遇到不完整写入');
      position += count;
    }
  }
  private copy(source: string, destination: string): void {
    const input = fs.openSync(source, fs.OpenMode.READ_ONLY);
    try {
      const expected: number = fs.statSync(input.fd).size;
      if (!Number.isSafeInteger(expected) || expected < 0) throw new Error('源文件长度无效');
      const output = fs.openSync(destination, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        let position: number = 0;
        while (position < expected) {
          const block: ArrayBuffer = new ArrayBuffer(Math.min(1024 * 1024, expected - position));
          const count: number = fs.readSync(input.fd, block, { length: block.byteLength });
          if (count <= 0 || count > block.byteLength) throw new Error('安全保存遇到不完整读取');
          this.writeAll(output.fd, count === block.byteLength ? block : block.slice(0, count));
          position += count;
        }
        if (fs.statSync(input.fd).size !== expected || fs.statSync(output.fd).size !== expected) {
          throw new Error('安全保存期间文件长度改变');
        }
        fs.fsyncSync(output.fd);
      } finally { fs.closeSync(output); }
    } finally { fs.closeSync(input); }
  }
  private equal(left: string, right: string): boolean {
    const a = fs.openSync(left, fs.OpenMode.READ_ONLY);
    try {
      const b = fs.openSync(right, fs.OpenMode.READ_ONLY);
      try {
        const size: number = fs.statSync(a.fd).size;
        if (!Number.isSafeInteger(size) || size < 0 || fs.statSync(b.fd).size !== size) return false;
        let position: number = 0;
        while (position < size) {
          const length: number = Math.min(1024 * 1024, size - position);
          const x: Uint8Array = new Uint8Array(length);
          const y: Uint8Array = new Uint8Array(length);
          // Explicit offsets make comparison correct even when providers perform short reads.
          let readA: number = 0;
          let readB: number = 0;
          while (readA < length) {
            const part: ArrayBuffer = new ArrayBuffer(length - readA);
            const n: number = fs.readSync(a.fd, part, { offset: position + readA, length: part.byteLength });
            if (n <= 0 || n > part.byteLength) throw new Error('备份校验读取不完整');
            x.set(new Uint8Array(part, 0, n), readA); readA += n;
          }
          while (readB < length) {
            const part: ArrayBuffer = new ArrayBuffer(length - readB);
            const n: number = fs.readSync(b.fd, part, { offset: position + readB, length: part.byteLength });
            if (n <= 0 || n > part.byteLength) throw new Error('保存校验读取不完整');
            y.set(new Uint8Array(part, 0, n), readB); readB += n;
          }
          for (let i: number = 0; i < length; i++) if (x[i] !== y[i]) return false;
          position += length;
        }
        return fs.statSync(a.fd).size === size && fs.statSync(b.fd).size === size;
      } finally { fs.closeSync(b); }
    } finally { fs.closeSync(a); }
  }
  private remove(path: string): void { try { fs.unlinkSync(path); } catch (_) {} }
  private writeMetadata(backup: string, destination: string): void {
    const targetUri: string = safeRecoveryTarget(destination);
    let name: string = targetUri.split(/[\\/]/).pop() ?? '恢复副本';
    try { name = decodeURIComponent(name); } catch (_) {}
    name = name.replace(/[\u0000-\u001f\u007f]/g, '').substring(0, 240) || '恢复副本';
    const metadata: FileRecoveryMetadata = { backupPath: backup, targetUri: targetUri.substring(0, 4096),
      name, bytes: this.size(backup), createdAt: Date.now() };
    if (metadata.bytes > MAX_RECOVERY_BYTES) throw new Error('旧文件超过 1 TiB 安全恢复预算');
    const encodedBytes: Uint8Array = new util.TextEncoder().encodeInto(JSON.stringify(metadata));
    const buffer: ArrayBuffer = encodedBytes.buffer.slice(encodedBytes.byteOffset, encodedBytes.byteOffset + encodedBytes.byteLength);
    const pending: string = `${backup}.json.pending`;
    try {
      const file = fs.openSync(pending, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try { this.writeAll(file.fd, buffer); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
      if (this.size(pending) !== buffer.byteLength) throw new Error('恢复索引写入不完整');
      fs.renameSync(pending, `${backup}.json`);
    } finally { this.remove(pending); }
  }
  private removeBackup(backup: string): void {
    if (backup.length === 0) return;
    // Remove metadata only after the recoverable bytes were removed.
    try { fs.unlinkSync(backup); this.remove(`${backup}.json`); } catch (_) {}
  }
  publishFile(source: string, destination: string, backupDirectory: string): FilePublishResult {
    if (source === destination || destination.length === 0) throw new Error('安全保存的源和目标必须不同且非空');
    if (this.active.has(destination)) throw new Error('此文件正在保存，请稍候');
    this.active.add(destination);
    let backup: string = '';
    let touched: boolean = false;
    let existed: boolean = false;
    let retainBackup: boolean = false;
    try {
      const bytes: number = this.size(source);
      // access failures are not permission to overwrite an unreadable old file.
      existed = fs.accessSync(destination);
      if (existed) {
        if (destination.includes('://') && this.recoveryDirectory.length === 0) throw new Error('安全覆盖需要先初始化应用持久恢复目录');
        backup = this.nextPath(this.recoveryDirectory || backupDirectory, '.backup');
        this.copy(destination, backup);
        if (!this.equal(destination, backup)) throw new Error('旧文件备份校验失败，未覆盖目标');
        if (this.recoveryDirectory.length > 0) {
          try { this.writeMetadata(backup, destination); }
          catch (metadataError) {
            retainBackup = true;
            throw new Error(`恢复索引写入失败，未覆盖旧目标；完整备份可从恢复目录发现：${backup}。${String(metadataError)}`);
          }
        }
      }
      if (!destination.includes('://')) {
        const stage: string = `${destination}.pending-${Date.now()}-${++this.sequence}`;
        try {
          this.copy(source, stage);
          if (!this.equal(source, stage)) throw new Error('待发布文件校验失败，未覆盖目标');
          if (existed && !this.equal(destination, backup)) throw new Error('目标在保存期间发生变化，未覆盖');
          fs.renameSync(stage, destination);
          this.removeBackup(backup);
          return { bytes, strategy: 'atomic-rename' };
        } finally { this.remove(stage); }
      }
      if (existed && !this.equal(destination, backup)) throw new Error('目标在保存期间发生变化，未覆盖');
      touched = true;
      this.copy(source, destination);
      if (!this.equal(source, destination)) throw new Error('新文件回读校验失败');
      this.removeBackup(backup);
      return { bytes, strategy: 'backup-and-verify' };
    } catch (error) {
      if (touched && existed && backup.length > 0) {
        try {
          this.copy(backup, destination);
          if (!this.equal(backup, destination)) throw new Error('恢复校验失败');
        } catch (restoreError) {
          // A recovery copy is never removed on restoration failure.
          throw new Error(`保存失败且目标恢复未完成；旧内容完整备份保留在 ${backup}。原因：${String(error)}；恢复：${String(restoreError)}`);
        }
        this.removeBackup(backup);
        throw new Error(`保存失败，旧文件已恢复：${String(error)}`);
      }
      if (!touched && !retainBackup) this.removeBackup(backup);
      if (touched && !existed) this.remove(destination);
      throw new Error(`保存失败，未发布新内容：${String(error)}`);
    } finally { this.active.delete(destination); }
  }
  publishBuffer(buffer: ArrayBuffer, destination: string, backupDirectory: string): FilePublishResult {
    const source: string = this.nextPath(backupDirectory, '.ready');
    try {
      const file = fs.openSync(source, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try { this.writeAll(file.fd, buffer); fs.fsyncSync(file.fd); } finally { fs.closeSync(file); }
      if (this.size(source) !== buffer.byteLength) throw new Error('待保存内容长度校验失败');
      return this.publishFile(source, destination, backupDirectory);
    } finally { this.remove(source); }
  }
}

export const safeFilePublishService = new SafeFilePublishService();
