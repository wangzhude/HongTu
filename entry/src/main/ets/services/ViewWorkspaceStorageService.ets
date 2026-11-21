import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';
import type { ViewWorkspaceStore } from '../models/ViewWorkspace';

/** Metadata only. The persistent lock inode is never removed while other callers may hold it. */
export class ViewWorkspaceStorageService implements ViewWorkspaceStore {
  private directory: string = '';
  private path: string = '';
  private readonly byteBudget: number = 2 * 1024 * 1024;

  configure(filesDir: string): void {
    if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
      !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
      filesDir.split(/[\\/]+/).some((part: string): boolean => part === '..' || part === '.')) throw new Error('视图库需要应用私有绝对目录');
    const rootStat = fs.lstatSync(filesDir);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('视图库私有根目录不是普通目录');
    const directory: string = `${filesDir.replace(/[\\/]$/, '')}/hongtu-views`;
    if (this.directory.length > 0 && this.directory !== directory) throw new Error('视图库目录已绑定，不能重定向');
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const directoryStat = fs.lstatSync(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) throw new Error('视图库目录不是普通目录');
    this.directory = directory;
    this.path = `${directory}/views.json`;
  }

  read(): string | undefined {
    this.requireConfigured();
    if (!fs.accessSync(this.path)) return undefined;
    const pathStat = fs.lstatSync(this.path);
    if (!pathStat.isFile() || pathStat.isSymbolicLink()) throw new Error('视图库不是普通文件');
    const file = fs.openSync(this.path, fs.OpenMode.READ_ONLY);
    try {
      const bytes: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > this.byteBudget) throw new Error('视图库超过2MiB预算');
      const decoder = new util.TextDecoder('utf-8', { fatal: true });
      const chunks: string[] = [];
      let position: number = 0;
      while (position < bytes) {
        const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, bytes - position));
        const count: number = fs.readSync(file.fd, buffer, { offset: position, length: buffer.byteLength });
        if (count <= 0 || count > buffer.byteLength) throw new Error('视图库读取不完整');
        chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true }));
        position += count;
      }
      if (fs.statSync(file.fd).size !== bytes) throw new Error('视图库读取期间发生变化');
      chunks.push(decoder.decodeToString(new Uint8Array(0)));
      return chunks.join('');
    } finally { fs.closeSync(file); }
  }

  compareAndSwap(expected: string | undefined, next: string | undefined): void {
    this.requireConfigured();
    if (fs.accessSync(`${this.directory}/views.lock`) && fs.lstatSync(`${this.directory}/views.lock`).isSymbolicLink()) throw new Error('视图库锁文件不能是链接');
    const lock = fs.openSync(`${this.directory}/views.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let locked: boolean = false;
    try {
      lock.tryLock(true); locked = true;
      if (this.read() !== expected) throw new Error('视图库已由其他操作改变，请重新载入');
      if (next === undefined) {
        if (expected !== undefined) fs.unlinkSync(this.path);
      } else {
        const bytes: Uint8Array = new util.TextEncoder().encodeInto(next);
        if (bytes.byteLength > this.byteBudget) throw new Error('视图库超过2MiB预算，未保存');
        const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        safeFilePublishService.publishBuffer(buffer, this.path, this.directory);
      }
      if (this.read() !== next) throw new Error('视图库完整回读不一致');
    } finally {
      try { if (locked) lock.unlock(); } finally { fs.closeSync(lock); }
    }
  }

  private requireConfigured(): void {
    if (this.path.length === 0) throw new Error('视图库尚未绑定应用私有目录');
  }
}

export const viewWorkspaceStorageService = new ViewWorkspaceStorageService();
