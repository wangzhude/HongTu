import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';

/** Single physical record for views, waiver ownership and engineering recovery receipts. Lock inode is never deleted while other callers may hold it. */
export class IntegratedWorkspaceStorageService {
  private directory: string = '';
  private root: string = '';
  private path: string = '';
  private readonly maximumBytes: number = 512 * 1024 * 1024;

  configure(filesDir: string): void {
    if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
      !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
      filesDir.split(/[\\/]+/).some((part: string): boolean => part === '..' || part === '.')) throw new Error('集成工作区需要应用私有绝对目录');
    const root = fs.lstatSync(filesDir);
    if (!root.isDirectory() || root.isSymbolicLink()) throw new Error('集成工作区私有根目录无效');
    const directory: string = `${filesDir.replace(/[\\/]$/, '')}/hongtu-integrated-workspace`;
    if (this.directory.length > 0 && directory !== this.directory) throw new Error('集成工作区目录不能重定向');
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('集成工作区目录无效');
    this.root = filesDir; this.directory = directory; this.path = `${directory}/session.json`;
  }

  private validateDirectory(): void {
    if (this.path.length === 0) throw new Error('集成工作区尚未配置');
    const root = fs.lstatSync(this.root), directory = fs.lstatSync(this.directory);
    if (!root.isDirectory() || root.isSymbolicLink() || !directory.isDirectory() || directory.isSymbolicLink()) {
      throw new Error('集成工作区目录已改变，拒绝读取或覆盖');
    }
  }

  read(): string | undefined {
    this.validateDirectory();
    if (!fs.accessSync(this.path)) return undefined;
    const pathStat = fs.lstatSync(this.path);
    if (!pathStat.isFile() || pathStat.isSymbolicLink()) throw new Error('集成工作区不是普通文件');
    const file = fs.openSync(this.path, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > this.maximumBytes) throw new Error('集成工作区超出 512 MiB 预算');
      const decoder = new util.TextDecoder('utf-8', { fatal: true });
      const chunks: string[] = [];
      let position: number = 0;
      while (position < size) {
        const buffer = new ArrayBuffer(Math.min(65536, size - position));
        const count: number = fs.readSync(file.fd, buffer, { offset: position, length: buffer.byteLength });
        if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('集成工作区读取不完整');
        chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true })); position += count;
      }
      chunks.push(decoder.decodeToString(new Uint8Array(0)));
      if (fs.statSync(file.fd).size !== size) throw new Error('集成工作区读取时长度变化');
      this.validateDirectory();
      return chunks.join('');
    } finally { fs.closeSync(file); }
  }

  compareAndSwap(expected: string | undefined, next: string | undefined): void {
    this.validateDirectory();
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(next === undefined ? '' : next);
    if (next !== undefined && (bytes.byteLength === 0 || bytes.byteLength > this.maximumBytes)) {
      throw new Error('集成工作区超出512 MiB存储预算，未修改');
    }
    const lockPath: string = `${this.directory}/session.lock`;
    if (fs.accessSync(lockPath)) {
      const lockStat = fs.lstatSync(lockPath);
      if (!lockStat.isFile() || lockStat.isSymbolicLink()) throw new Error('集成工作区锁必须是普通文件');
    }
    const lock = fs.openSync(lockPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let locked: boolean = false;
    try {
      lock.tryLock(true); locked = true;
      this.validateDirectory();
      const lockStat = fs.lstatSync(lockPath);
      if (!lockStat.isFile() || lockStat.isSymbolicLink()) throw new Error('集成工作区锁已改变');
      if (this.read() !== expected) throw new Error('集成工作区已由另一操作改变，未覆盖');
      if (next === undefined) {
        if (expected !== undefined) fs.unlinkSync(this.path);
      } else {
        const buffer: ArrayBuffer = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ?
          bytes.buffer as ArrayBuffer : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        safeFilePublishService.publishBuffer(buffer, this.path, this.directory);
      }
      if (this.read() !== next) throw new Error('集成工作区完整回读不一致');
    } finally {
      try { if (locked) lock.unlock(); } finally { fs.closeSync(lock); }
    }
  }
}
