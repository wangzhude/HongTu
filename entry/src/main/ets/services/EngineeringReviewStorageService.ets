import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';
import type { EngineeringReviewStore } from '../models/EngineeringReviewBundle';

/** One private CAS record, atomic rename and complete read-back. Persistent lock inode retained. */
export class EngineeringReviewStorageService implements EngineeringReviewStore {
  private directory: string = '';
  private root: string = '';
  private path: string = '';
  private readonly byteBudget: number = 120 * 1024 * 1024;
  configure(filesDir: string): void {
    if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
      !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
      filesDir.split(/[\\/]+/).some((part: string): boolean => part === '..' || part === '.')) throw new Error('工程恢复需要应用私有绝对目录');
    const rootStat = fs.lstatSync(filesDir);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('工程恢复私有根目录不是普通目录');
    const directory: string = `${filesDir.replace(/[\\/]$/, '')}/hongtu-engineering-review`;
    if (this.directory.length > 0 && this.directory !== directory) throw new Error('工程恢复目录已绑定，不能重定向');
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('工程恢复目录不是普通目录');
    this.root = filesDir; this.directory = directory; this.path = `${directory}/restore.json`;
  }
  read(): string | undefined {
    this.requireConfigured(); if (!fs.accessSync(this.path)) return undefined;
    const stat = fs.lstatSync(this.path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('工程恢复记录不是普通文件');
    const file = fs.openSync(this.path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size < 0 || size > this.byteBudget) throw new Error('工程恢复记录超过120MiB预算');
      const decoder = new util.TextDecoder('utf-8', { fatal: true });
      const chunks: string[] = []; let position: number = 0;
      while (position < size) {
        const buffer: ArrayBuffer = new ArrayBuffer(Math.min(65536, size - position));
        const count: number = fs.readSync(file.fd, buffer, { offset: position, length: buffer.byteLength });
        if (count <= 0 || count > buffer.byteLength) throw new Error('工程恢复读取不完整');
        chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true })); position += count;
      }
      if (fs.statSync(file.fd).size !== size) throw new Error('工程恢复读取期间长度改变');
      chunks.push(decoder.decodeToString(new Uint8Array(0))); return chunks.join('');
    } finally { fs.closeSync(file); }
  }
  compareAndSwap(expected: string | undefined, next: string | undefined): void {
    this.requireConfigured();
    const lockPath: string = `${this.directory}/restore.lock`;
    if (fs.accessSync(lockPath) && fs.lstatSync(lockPath).isSymbolicLink()) throw new Error('工程恢复锁不能是链接');
    const lock = fs.openSync(lockPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let locked: boolean = false;
    try {
      lock.tryLock(true); locked = true;
      if (this.read() !== expected) throw new Error('工程恢复CAS基线已改变');
      if (next === undefined) { if (expected !== undefined) fs.unlinkSync(this.path); }
      else {
        const bytes: Uint8Array = new util.TextEncoder().encodeInto(next);
        if (bytes.byteLength > this.byteBudget) throw new Error('工程恢复记录超过120MiB预算');
        const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        safeFilePublishService.publishBuffer(buffer, this.path, this.directory);
      }
      if (this.read() !== next) throw new Error('工程恢复写后完整回读不一致');
    } finally { try { if (locked) lock.unlock(); } finally { fs.closeSync(lock); } }
  }
  private requireConfigured(): void {
    if (this.path.length === 0) throw new Error('工程恢复尚未绑定应用私有目录');
    const root = fs.lstatSync(this.root), directory = fs.lstatSync(this.directory);
    if (!root.isDirectory() || root.isSymbolicLink() || !directory.isDirectory() || directory.isSymbolicLink()) throw new Error('工程恢复私有目录已改变');
  }
}
