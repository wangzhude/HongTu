import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { safeFilePublishService } from './SafeFilePublishService';

/** Private waiver/workspace envelope. Never delete the lock inode while callers may hold it. */
export class RdbWaiverStorageService {
  private root: string = '';
  private directory: string = '';
  private path: string = '';
  private rootIdentity: string = '';
  private directoryIdentity: string = '';
  private lockIdentity: string = '';
  // One CAS includes the full 96 MiB report workspace and up to 32 MiB of reusable rules.
  private readonly maximumBytes: number = 128 * 1024 * 1024;

  configure(filesDir: string): void {
    if (typeof filesDir !== 'string' || filesDir.length === 0 || filesDir.includes('://') || filesDir.includes('\0') ||
      !(/^[\\/]/.test(filesDir) || /^[A-Za-z]:[\\/]/.test(filesDir)) ||
      filesDir.split(/[\\/]+/).some((part: string): boolean => part === '..' || part === '.')) {
      throw new Error('豁免库需要应用私有绝对目录');
    }
    let root: string = filesDir.replace(/\\/g, '/').replace(/\/+$/, '');
    if (root.length === 0) root = '/';
    if (/^[A-Za-z]:$/.test(root)) root += '/';
    const directory: string = `${root}${root.endsWith('/') ? '' : '/'}hongtu-rdb-waiver`;
    if (this.directory.length > 0) {
      if (root !== this.root || directory !== this.directory) throw new Error('豁免库目录不能重定向');
      this.validateDirectory();
      return;
    }
    const rootStat = fs.lstatSync(root);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) throw new Error('豁免库私有根目录无效');
    if (!fs.accessSync(directory)) fs.mkdirSync(directory);
    const directoryStat = fs.lstatSync(directory);
    if (!directoryStat.isDirectory() || directoryStat.isSymbolicLink()) throw new Error('豁免库目录无效');
    if (fs.lstatSync(root).ino !== rootStat.ino) throw new Error('豁免库私有根目录已改变');
    const lockPath: string = `${directory}/library.lock`;
    let lockIdentity: string = '';
    if (fs.accessSync(lockPath)) {
      const lockStat = fs.lstatSync(lockPath);
      if (!lockStat.isFile() || lockStat.isSymbolicLink()) throw new Error('豁免库锁必须是普通文件');
      lockIdentity = lockStat.ino.toString();
    }
    this.root = root;
    this.directory = directory;
    this.path = `${directory}/library.json`;
    this.rootIdentity = rootStat.ino.toString();
    this.directoryIdentity = directoryStat.ino.toString();
    this.lockIdentity = lockIdentity;
    this.validateDirectory();
  }

  private validateDirectory(): void {
    if (this.path.length === 0) throw new Error('豁免库尚未配置');
    const root = fs.lstatSync(this.root), directory = fs.lstatSync(this.directory);
    if (!root.isDirectory() || root.isSymbolicLink() || root.ino.toString() !== this.rootIdentity ||
      !directory.isDirectory() || directory.isSymbolicLink() || directory.ino.toString() !== this.directoryIdentity) {
      throw new Error('豁免库目录已改变，拒绝读取或覆盖');
    }
  }

  private fileStamp(stat: fs.Stat): string {
    const modified: string = stat.mtimeNs === undefined ? String(stat.mtime) : stat.mtimeNs.toString();
    const changed: string = stat.ctimeNs === undefined ? String(stat.ctime) : stat.ctimeNs.toString();
    return `${stat.ino.toString()}:${stat.size}:${modified}:${changed}`;
  }

  private readComplete(fd: number, size: number): string {
    const decoder = new util.TextDecoder('utf-8', { fatal: true });
    const chunks: string[] = [];
    let position: number = 0;
    while (position < size) {
      const buffer = new ArrayBuffer(Math.min(65536, size - position));
      const count: number = fs.readSync(fd, buffer, { offset: position, length: buffer.byteLength });
      if (!Number.isSafeInteger(count) || count <= 0 || count > buffer.byteLength) throw new Error('豁免库读取不完整');
      chunks.push(decoder.decodeToString(new Uint8Array(buffer, 0, count), { stream: true }));
      position += count;
    }
    chunks.push(decoder.decodeToString(new Uint8Array(0)));
    return chunks.join('');
  }

  read(): string | undefined {
    this.validateDirectory();
    if (!fs.accessSync(this.path)) {
      this.validateDirectory();
      return undefined;
    }
    const pathStat = fs.lstatSync(this.path);
    if (!pathStat.isFile() || pathStat.isSymbolicLink()) throw new Error('豁免库不是普通文件');
    const file = fs.openSync(this.path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW);
    try {
      const opened = fs.statSync(file.fd);
      if (!opened.isFile() || opened.ino !== pathStat.ino || this.fileStamp(opened) !== this.fileStamp(pathStat)) {
        throw new Error('豁免库读取路径已改变');
      }
      const size: number = opened.size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > this.maximumBytes) throw new Error('豁免库与报告工作区超出 128 MiB 预算');
      const stamp: string = this.fileStamp(opened);
      const text: string = this.readComplete(file.fd, size);
      const after = fs.statSync(file.fd), current = fs.lstatSync(this.path);
      if (!after.isFile() || !current.isFile() || current.isSymbolicLink() ||
        this.fileStamp(after) !== stamp || this.fileStamp(current) !== stamp) {
        throw new Error('豁免库读取时文件或长度已改变');
      }
      // API 9–14 Stat only promises whole-second mtime/ctime; equal-length writes can
      // preserve these stamps. Reread the complete content instead of trusting them.
      if (opened.mtimeNs === undefined || opened.ctimeNs === undefined) {
        if (this.readComplete(file.fd, size) !== text) throw new Error('豁免库完整复读内容已改变');
        const reread = fs.statSync(file.fd), rereadPath = fs.lstatSync(this.path);
        if (!reread.isFile() || !rereadPath.isFile() || rereadPath.isSymbolicLink() ||
          this.fileStamp(reread) !== stamp || this.fileStamp(rereadPath) !== stamp) {
          throw new Error('豁免库完整复读时文件或长度已改变');
        }
      }
      this.validateDirectory();
      return text;
    } finally { fs.closeSync(file); }
  }

  compareAndSwap(expected: string | undefined, next: string): void {
    this.validateDirectory();
    if ((expected !== undefined && typeof expected !== 'string') || typeof next !== 'string') {
      throw new Error('豁免库存储需要完整字符串');
    }
    const bytes: Uint8Array = new util.TextEncoder().encodeInto(next);
    if (bytes.byteLength === 0 || bytes.byteLength > this.maximumBytes) throw new Error('豁免库与报告工作区超出 128 MiB 存储预算，未修改');
    // Reject lossy UTF-8 encoding (for example an unpaired UTF-16 surrogate) before touching storage.
    if (new util.TextDecoder('utf-8', { fatal: true }).decodeToString(bytes) !== next) {
      throw new Error('豁免库包含不能完整编码的文字，未修改');
    }
    const lockPath: string = `${this.directory}/library.lock`;
    let beforeIdentity: string = '';
    if (fs.accessSync(lockPath)) {
      const stat = fs.lstatSync(lockPath);
      if (!stat.isFile() || stat.isSymbolicLink()) throw new Error('豁免库锁必须是普通文件');
      beforeIdentity = stat.ino.toString();
      if (this.lockIdentity.length > 0 && beforeIdentity !== this.lockIdentity) throw new Error('豁免库锁已改变');
    } else if (this.lockIdentity.length > 0) throw new Error('豁免库锁已被移除');
    const lock = fs.openSync(lockPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.NOFOLLOW);
    let locked: boolean = false;
    try {
      lock.tryLock(true);
      locked = true;
      this.validateDirectory();
      const held = fs.statSync(lock.fd), current = fs.lstatSync(lockPath);
      if (!held.isFile() || !current.isFile() || current.isSymbolicLink() || held.ino !== current.ino ||
        (beforeIdentity.length > 0 && held.ino.toString() !== beforeIdentity)) throw new Error('豁免库锁已改变');
      this.lockIdentity = held.ino.toString();
      if (this.read() !== expected) throw new Error('豁免库已由另一操作改变，未覆盖');
      this.validateDirectory();
      if (fs.lstatSync(lockPath).ino !== held.ino) throw new Error('豁免库锁已改变，未覆盖');
      const buffer: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      safeFilePublishService.publishBuffer(buffer, this.path, this.directory);
      if (this.read() !== next) throw new Error('豁免库完整回读不一致，未采用新状态');
      if (fs.lstatSync(lockPath).ino !== held.ino) throw new Error('豁免库发布时锁已改变，未采用新状态');
    } finally {
      try { if (locked) lock.unlock(); } finally { fs.closeSync(lock); }
    }
  }
}
