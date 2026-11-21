import { RdbWaiverStorageService } from './RdbWaiverStorageService';
import { RdbWaiverService } from './RdbWaiverService';
import { RdbReviewStorageService } from './RdbReviewStorageService';

/** Drop-in replacement for Index's report storage. All ordinary report changes and
 * library confirmations now share one locked aggregate CAS. The legacy report file
 * is only read during first migration, never deleted or rewritten. */
export class RdbWaiverWorkspaceStorageService {
  private readonly aggregate: RdbWaiverStorageService = new RdbWaiverStorageService();
  private service: RdbWaiverService | undefined = undefined;
  private filesDir: string = '';

  configure(filesDir: string): void {
    if (this.service !== undefined) {
      if (this.filesDir !== filesDir) throw new Error('豁免工作区不能重定向');
      return;
    }
    this.aggregate.configure(filesDir);
    const service: RdbWaiverService = new RdbWaiverService(this.aggregate);
    let legacy: string | undefined = undefined;
    if (this.aggregate.read() === undefined) {
      const old: RdbReviewStorageService = new RdbReviewStorageService(); old.configure(filesDir); legacy = old.read();
    }
    service.load(legacy); this.service = service; this.filesDir = filesDir;
  }
  read(): string | undefined { return this.library().readWorkspace(); }
  compareAndSwap(expected: string | undefined, next: string): void { this.library().compareAndSwapWorkspace(expected, next); }
  library(): RdbWaiverService {
    if (this.service === undefined) throw new Error('豁免工作区尚未配置'); return this.service;
  }
  /** Explicit recovery after readback/CAS uncertainty. Caller must then read() and
   * restore/adopt that workspace together; do not keep the previous live report. */
  reload(): void { this.library().load(); }
}
