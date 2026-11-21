import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { credentialStore } from './CredentialStore';
import type { LayoutPort, LayoutCrossSection, LayoutSemanticState } from '../models/LayoutPort';
import { validateLayoutSemantics, layoutUtf8Bytes } from '../models/LayoutPort';
import type { LayoutContextRecord } from '../../cpp/types/libhongtu/Index';
import { cloneStructured } from '../common/CloneUtils';

export interface PythonBridgeConfig { endpoint: string; token: string; caPath?: string; }
export const PYTHON_BRIDGE_DEFAULT_ENDPOINT: string = 'http://127.0.0.1:7865';
export const PYTHON_VERIFY_MAX_RESPONSE_BYTES: number = 16 * 1024 * 1024;
export const PYTHON_ARTIFACT_ID_REGEX: RegExp =
  /^(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/;
export const PYTHON_ARTIFACT_MAX_AGE_MS: number = 24 * 60 * 60 * 1000;
export const PYTHON_ARTIFACT_MAX_GROUPS: number = 40;
export const PYTHON_ARTIFACT_MAX_TOTAL_BYTES: number = 128 * 1024 * 1024;
export const PYTHON_CACHE_INPUT_MAX_AGE_MS: number = 30 * 60 * 1000;
export const PYTHON_CACHE_INPUT_MAX_FILES: number = 16;
export const PYTHON_CACHE_INPUT_MAX_TOTAL_BYTES: number = 64 * 1024 * 1024;

const PYTHON_ENDPOINT_STORAGE_KEY: string = 'hongtu_python_endpoint';
const PYTHON_CA_PATH_STORAGE_KEY: string = 'hongtu_python_ca_path';
const PYTHON_TOKEN_ALIAS: string = 'hongtu-python-bridge-token';

/**
 * 统一跨端 artifactId 校验与归一化：允许 32 位小写 hex 或标准 36 位小写带连字符 UUID，
 * 归一化为 32 位小写 hex 与 Python 端 ArtifactCache 严格对齐。
 */
export function normalizePythonArtifactId(artifactId: string): string {
  if (typeof artifactId !== 'string' || !PYTHON_ARTIFACT_ID_REGEX.test(artifactId)) {
    throw new Error('助手产物标识无效');
  }
  return artifactId.replace(/-/g, '');
}

function isValidIpv4Host(host: string): boolean {
  const parts: string[] = host.split('.');
  if (parts.length !== 4 || host === '0.0.0.0') return false;
  for (let i: number = 0; i < 4; i++) {
    const part: string = parts[i];
    if (!/^(?:0|[1-9]\d{0,2})$/.test(part)) return false;
    const octet: number = Number(part);
    if (octet < 0 || octet > 255) return false;
  }
  return true;
}

function isValidHttpsHost(host: string): boolean {
  if (host.length === 0 || host.length > 253) return false;
  if (host.startsWith('[') && host.endsWith(']')) {
    const inner: string = host.substring(1, host.length - 1);
    return inner.length >= 2 && inner.includes(':') && /^[0-9a-fA-F:]+$/.test(inner) && inner !== '::';
  }
  if (/^\d+(?:\.\d+)*$/.test(host)) {
    return isValidIpv4Host(host);
  }
  if (host === 'localhost') return true;
  const labels: string[] = host.split('.');
  return labels.every((label: string): boolean =>
    label.length >= 1 && label.length <= 63 && /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(label));
}

/**
 * 校验伴随端地址：保留本机回环 HTTP 支持，同时允许合法的局域网/远程 HTTPS 端点（真机无线联调）。
 */
export function validatePythonBridgeEndpoint(value: string): string {
  if (typeof value !== 'string') {
    throw new Error('Python 服务须使用本机回环 HTTP 或合法 HTTPS 地址');
  }
  const cleaned: string = value.trim().replace(/\/+$/, '');
  const loopbackHttp: RegExpMatchArray | null =
    cleaned.match(/^http:\/\/(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})$/);
  if (loopbackHttp !== null) {
    const port: number = Number(loopbackHttp[2]);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      throw new Error('Python 服务端口须在 1–65535 之间');
    }
    return cleaned;
  }
  const httpsMatch: RegExpMatchArray | null =
    cleaned.match(/^https:\/\/(\[[0-9a-fA-F:]+\]|[^/:?#\s@]+)(?::(\d{1,5}))?$/);
  if (httpsMatch !== null) {
    const host: string = httpsMatch[1];
    if (!isValidHttpsHost(host)) {
      throw new Error('HTTPS 伴随服务主机名或局域网 IP 无效');
    }
    if (httpsMatch[2] !== undefined) {
      const port: number = Number(httpsMatch[2]);
      if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error('Python 服务端口须在 1–65535 之间');
      }
    }
    return cleaned;
  }
  throw new Error('Python 服务须使用本机回环地址（如 http://127.0.0.1:7865）或局域网 HTTPS 地址（如 https://192.168.1.10:7865）');
}

/**
 * 校验可选自定义根证书路径（caPath），供真机连接局域网自签名 HTTPS 伴随端使用。
 */
export function normalizePythonBridgeCaPath(caPath?: string): string | undefined {
  if (caPath === undefined) return undefined;
  const trimmed: string = caPath.trim();
  if (trimmed.length === 0) return undefined;
  if (!trimmed.startsWith('/') || trimmed.length > 1024 || trimmed.includes('\\') ||
    /[\u0000-\u001F\u007F]/.test(trimmed) ||
    trimmed.split('/').some((part: string): boolean => part === '.' || part === '..') ||
    !/\.(?:pem|crt|cer)$/i.test(trimmed)) {
    throw new Error('自定义 CA 证书路径须为合法的绝对证书文件路径（.pem/.crt/.cer）');
  }
  return trimmed;
}

interface TempFileEntry {
  fullPath: string;
  groupKey: string;
  timestampMs: number;
  sizeBytes: number;
  referencedInHistory: boolean;
}

interface ArtifactGroupBucket {
  groupKey: string;
  timestampMs: number;
  referencedInHistory: boolean;
  totalBytes: number;
  files: TempFileEntry[];
}

export type PythonJobState = 'starting' | 'running' | 'cancelling' | 'cancelled' | 'succeeded' | 'failed' | 'timed_out';
export interface PythonJobStatus { jobId: string; state: PythonJobState; terminal: boolean; workerStopped: boolean; error?: string; }
export interface PythonOperationHandle { operationId: string; jobId: string; kind: 'generate' | 'verify'; }
export interface PythonCancellationResult { confirmed: boolean; message: string; jobStatus?: PythonJobStatus; }
interface PythonOwnedOperation {
  handle: PythonOperationHandle; started: boolean; dispatched: boolean; cancelRequested: boolean;
  config?: PythonBridgeConfig; supportsCancellation: boolean; result?: PythonJobStatus;
  cancellation?: Promise<PythonCancellationResult>;
}
interface PythonJobEnvelope { jobId?: string; jobStatus?: PythonJobStatus; success?: boolean; }
export type PythonInputMode = 'new' | 'document' | 'selection';
export interface PythonDocumentInput { path: string; selectionPath?: string; currentCellName?: string; revision: number; documentId?: string; }
export interface PythonParameter { name: string; value: number | string | boolean; }
export interface PythonLayerDefinition { layerNumber: number; datatype: number; name: string; }
export interface PythonPortMetadata {
  schemaVersion: 1; cellNames: string[]; cellKeys: string[]; ports: LayoutPort[];
  crossSections: LayoutCrossSection[]; layoutContextRecords: LayoutContextRecord[];
  cellContextRecords: LayoutContextRecord[][]; diagnostics: string[];
}
export interface PythonRunOptions { inputMode: PythonInputMode; document?: PythonDocumentInput; parameters?: PythonParameter[]; validationProfile?: 'generic_inverter'; }
export interface PythonVerificationOptions {
  kind: 'drc' | 'lvs'; technologyId: string; deckId: string; document: PythonDocumentInput;
  referenceSpice?: string; cellName?: string;
}
interface PythonVerificationRequest {
  jobId?: string;
  kind: 'drc' | 'lvs'; technologyId: string; deckId: string; documentGds: string;
  referenceSpice?: string; cellName?: string;
}
export interface PythonViolation {
  rule: string; layerNumber: number; datatype: number; minX: number; minY: number; maxX: number; maxY: number; message: string;
}
export interface PythonVerifiedDevice { name: string; model: string; parameters: Record<string, number>; }
export interface PythonVerificationResult {
  success: boolean; complete: boolean; passed: boolean; kind: string; technologyId: string; deckId: string;
  engine: string; scope: string; foundrySignoff: boolean; netCount: number; reportText: string; error?: string;
  violations: PythonViolation[]; devices: PythonVerifiedDevice[]; violationCount: number; markersTruncated: boolean;
}
interface PythonVerificationReport {
  schema: string; inputSha256: string; cellName: string; technologyId: string; deckId: string;
  engine: string; foundrySignoff: boolean; details: PythonVerificationReportDetails;
}
interface PythonVerificationReportDetails {
  complete: boolean; passed: boolean; scope: string; netCount: number; violationCount: number; markersTruncated: boolean;
  violations: PythonViolation[]; devices: PythonVerifiedDevice[];
}
interface GenerateRequest {
  jobId?: string;
  script: string;
  inputMode: PythonInputMode;
  documentGds?: string;
  selectionGds?: string;
  currentCellName?: string;
  parameters: Record<string, number | string | boolean>;
  validationProfile?: 'generic_inverter';
}
interface BridgeHealth { ok: boolean; service: string; execution: string; capabilities?: string[]; }
interface BridgeReply {
  success: boolean;
  error?: string;
  fileName: string;
  gdsBase64: string;
  cellCount: number;
  shapeCount: number;
  expandedShapeCount?: number;
  layerCount: number;
  layerDefinitions: PythonLayerDefinition[];
  stdout: string;
  previewSvg?: string;
  previewTruncated?: boolean;
  reviewSummary?: string;
  portMetadata?: PythonPortMetadata;
}
interface AssistantArtifactReply extends BridgeReply {
  artifactId: string;
  script: string;
  originalRequest: string;
  validationProfile?: 'generic_inverter' | '';
}
export interface PythonLayoutArtifact {
  path: string;
  name: string;
  previewPath: string;
  summary: string;
  stdout: string;
  sourceRevision?: number;
  sourceDocumentId?: string;
  inputMode?: PythonInputMode;
  /** Optional only for artifacts saved by older versions of the execution history. */
  layerDefinitions?: PythonLayerDefinition[];
  reviewSummary?: string;
  artifactId?: string;
  script?: string;
  originalRequest?: string;
  validationProfile?: 'generic_inverter';
  /** Immutable semantic sidecar also retained in the real execution history. */
  portMetadata?: PythonPortMetadata;
}

interface StoredRunHistoryItem {
  artifact?: PythonLayoutArtifact;
}

export class PythonBridgeService {
  private activeRequest: http.HttpRequest | null = null;
  private activeGeneration: boolean = false;
  private configMutationBusy: boolean = false;
  private connectionUsers: number = 0;
  private generation: number = 0;
  private serial: number = 0;
  private ownedOperations: Map<string, PythonOwnedOperation> = new Map();
  private activeOwner: string = '';
  private startupCleanupDoneDirs: Set<string> = new Set();

  private safeDirectory(rawDir: string | undefined): string {
    if (typeof rawDir !== 'string') return '';
    const directory: string = rawDir.replace(/\/+$/, '');
    if (!directory.startsWith('/') || directory.length < 2 || directory.includes('\\') ||
      directory.split('/').some((part: string): boolean => part === '.' || part === '..')) {
      return '';
    }
    return directory;
  }

  private collectHistoryArtifactPaths(): Set<string> {
    const paths: Set<string> = new Set<string>();
    try {
      const rawHistory: string | undefined = AppStorage.get<string>('hongtu_python_history');
      if (typeof rawHistory === 'string' && rawHistory.length > 0) {
        const records: StoredRunHistoryItem[] = JSON.parse(rawHistory) as StoredRunHistoryItem[];
        if (Array.isArray(records)) {
          for (const item of records.slice(0, 40)) {
            const p1: string | undefined = item?.artifact?.path;
            const p2: string | undefined = item?.artifact?.previewPath;
            if (typeof p1 === 'string' && p1.length > 0) paths.add(p1);
            if (typeof p2 === 'string' && p2.length > 0) paths.add(p2);
          }
        }
      }
    } catch (_) {
      // Non-UI test environments or uninitialized AppStorage safely yield an empty set.
    }
    return paths;
  }

  /**
   * 同步清理 cacheDir 与 filesDir 下超期/超量的 python-*.gds 与 python-*.svg 临时文件，
   * 绝不触碰非 python-* 命名文件、子目录或当次正在生成的受保护文件。
   */
  cleanupTemporaryFiles(context: common.UIAbilityContext, nowMs: number = Date.now(),
    protectedPaths: string[] = []): number {
    const protectedSet: Set<string> = new Set<string>(protectedPaths);
    let removedCount: number = 0;

    const cacheDir: string = this.safeDirectory(context?.cacheDir);
    if (cacheDir.length > 0) {
      removedCount += this.pruneCacheDirectory(cacheDir, nowMs, protectedSet);
    }

    const filesDir: string = this.safeDirectory(context?.filesDir);
    if (filesDir.length > 0) {
      removedCount += this.pruneFilesDirectory(filesDir, nowMs, protectedSet, this.collectHistoryArtifactPaths());
    }

    if (cacheDir.length > 0 || filesDir.length > 0) {
      this.startupCleanupDoneDirs.add(`${cacheDir}|${filesDir}`);
    }
    return removedCount;
  }

  private ensureStartupCleanup(context: common.UIAbilityContext, protectedPaths: string[] = []): void {
    const key: string = `${this.safeDirectory(context?.cacheDir)}|${this.safeDirectory(context?.filesDir)}`;
    if (key === '|' || this.startupCleanupDoneDirs.has(key)) return;
    this.cleanupTemporaryFiles(context, Date.now(), protectedPaths);
  }

  private pruneCacheDirectory(cacheDir: string, nowMs: number, protectedSet: Set<string>): number {
    let names: string[] = [];
    try { names = fs.listFileSync(cacheDir); } catch (_) { return 0; }
    const entries: TempFileEntry[] = [];
    for (const name of names) {
      const match: RegExpMatchArray | null =
        name.match(/^python-(?:(?:input|selection)-)?(\d{13})-([1-9]\d*)(?:-[A-Za-z0-9_.-]+)?\.(?:gds|svg)$/);
      if (match === null) continue;
      const fullPath: string = `${cacheDir}/${name}`;
      if (protectedSet.has(fullPath)) continue;
      try {
        const st = fs.statSync(fullPath);
        if (!st.isFile()) continue;
        const parsedTs: number = Number(match[1]);
        const ts: number = Number.isFinite(parsedTs) ? parsedTs : st.mtime * 1000;
        entries.push({ fullPath, groupKey: `${match[1]}-${match[2]}`, timestampMs: ts,
          sizeBytes: Math.max(0, st.size), referencedInHistory: false });
      } catch (_) {}
    }
    let removed: number = 0;
    const survivors: TempFileEntry[] = [];
    for (const entry of entries) {
      if (nowMs - entry.timestampMs > PYTHON_CACHE_INPUT_MAX_AGE_MS) {
        if (this.tryUnlinkSync(entry.fullPath)) removed++;
      } else {
        survivors.push(entry);
      }
    }
    survivors.sort((a: TempFileEntry, b: TempFileEntry): number => a.timestampMs - b.timestampMs);
    let totalBytes: number = survivors.reduce((acc: number, item: TempFileEntry): number => acc + item.sizeBytes, 0);
    while (survivors.length > PYTHON_CACHE_INPUT_MAX_FILES || totalBytes > PYTHON_CACHE_INPUT_MAX_TOTAL_BYTES) {
      const victim: TempFileEntry | undefined = survivors.shift();
      if (victim === undefined) break;
      totalBytes -= victim.sizeBytes;
      if (this.tryUnlinkSync(victim.fullPath)) removed++;
    }
    return removed;
  }

  private pruneFilesDirectory(filesDir: string, nowMs: number, protectedSet: Set<string>,
    historyPaths: Set<string>): number {
    let names: string[] = [];
    try { names = fs.listFileSync(filesDir); } catch (_) { return 0; }
    const groups: Map<string, ArtifactGroupBucket> = new Map<string, ArtifactGroupBucket>();
    for (const name of names) {
      const match: RegExpMatchArray | null =
        name.match(/^python-(\d{13})-([1-9]\d*)(?:-[A-Za-z0-9_.-]+)?\.(?:gds|svg)$/);
      if (match === null) continue;
      const fullPath: string = `${filesDir}/${name}`;
      if (protectedSet.has(fullPath)) continue;
      try {
        const st = fs.statSync(fullPath);
        if (!st.isFile()) continue;
        const groupKey: string = `${match[1]}-${match[2]}`;
        const parsedTs: number = Number(match[1]);
        const ts: number = Number.isFinite(parsedTs) ? parsedTs : st.mtime * 1000;
        const inHistory: boolean = historyPaths.has(fullPath);
        const entry: TempFileEntry = {
          fullPath, groupKey, timestampMs: ts, sizeBytes: Math.max(0, st.size), referencedInHistory: inHistory
        };
        let bucket: ArtifactGroupBucket | undefined = groups.get(groupKey);
        if (bucket === undefined) {
          bucket = { groupKey, timestampMs: ts, referencedInHistory: inHistory, totalBytes: 0, files: [] };
          groups.set(groupKey, bucket);
        }
        bucket.timestampMs = Math.max(bucket.timestampMs, ts);
        bucket.referencedInHistory = bucket.referencedInHistory || inHistory;
        bucket.totalBytes += entry.sizeBytes;
        bucket.files.push(entry);
      } catch (_) {}
    }

    let removed: number = 0;
    const activeBuckets: ArtifactGroupBucket[] = [];
    groups.forEach((bucket: ArtifactGroupBucket): void => {
      if (nowMs - bucket.timestampMs > PYTHON_ARTIFACT_MAX_AGE_MS) {
        for (const f of bucket.files) {
          if (this.tryUnlinkSync(f.fullPath)) removed++;
        }
      } else {
        activeBuckets.push(bucket);
      }
    });

    // Unreferenced orphan artifacts evict before active run-history items, oldest first.
    activeBuckets.sort((a: ArtifactGroupBucket, b: ArtifactGroupBucket): number => {
      if (a.referencedInHistory !== b.referencedInHistory) {
        return a.referencedInHistory ? 1 : -1;
      }
      return a.timestampMs - b.timestampMs;
    });

    let totalBytes: number = activeBuckets.reduce((sum: number, b: ArtifactGroupBucket): number => sum + b.totalBytes, 0);
    while (activeBuckets.length > PYTHON_ARTIFACT_MAX_GROUPS || totalBytes > PYTHON_ARTIFACT_MAX_TOTAL_BYTES) {
      const victim: ArtifactGroupBucket | undefined = activeBuckets.shift();
      if (victim === undefined) break;
      totalBytes -= victim.totalBytes;
      for (const f of victim.files) {
        if (this.tryUnlinkSync(f.fullPath)) removed++;
      }
    }
    return removed;
  }

  private tryUnlinkSync(path: string): boolean {
    try {
      fs.unlinkSync(path);
      return true;
    } catch (_) {
      return false;
    }
  }

  private buildRequestOptions(config: PythonBridgeConfig, resolvedEndpoint: string,
    options: http.HttpRequestOptions): http.HttpRequestOptions {
    const caPath: string | undefined = normalizePythonBridgeCaPath(config.caPath);
    if (caPath !== undefined && resolvedEndpoint.startsWith('https://')) {
      options.caPath = caPath;
    }
    return options;
  }

  createOperation(kind: 'generate' | 'verify'): PythonOperationHandle {
    const jobId: string = util.generateRandomUUID().replace(/-/g, '').toLowerCase();
    if (!/^[0-9a-f]{32}$/.test(jobId)) throw new Error('无法创建 Python 任务标识');
    if (this.ownedOperations.size >= 64) {
      for (const key of this.ownedOperations.keys()) {
        if (key !== this.activeOwner) { this.ownedOperations.delete(key); break; }
      }
    }
    const handle: PythonOperationHandle = { operationId: jobId, jobId, kind };
    const operation: PythonOwnedOperation = { handle, started: false, dispatched: false,
      cancelRequested: false, supportsCancellation: false };
    this.ownedOperations.set(handle.operationId, operation);
    return handle;
  }

  private owned(handle: PythonOperationHandle): PythonOwnedOperation {
    const value: PythonOwnedOperation | undefined = this.ownedOperations.get(handle.operationId);
    if (value === undefined || value.handle !== handle) throw new Error('Python 任务已过期或不属于此操作');
    return value;
  }

  private claim(handle: PythonOperationHandle | undefined, kind: 'generate' | 'verify'): PythonOwnedOperation | undefined {
    if (handle === undefined) return undefined;
    const value: PythonOwnedOperation = this.owned(handle);
    if (handle.kind !== kind || value.started) throw new Error('Python 任务标识不能重复使用');
    if (value.cancelRequested) throw new Error('Python 任务已取消，未启动执行');
    value.started = true;
    this.activeOwner = handle.operationId;
    return value;
  }

  private jobStatus(value: PythonJobStatus | undefined, id: string): PythonJobStatus {
    if (value === undefined || value.jobId !== id ||
      !['starting', 'running', 'cancelling', 'cancelled', 'succeeded', 'failed', 'timed_out'].includes(value.state) ||
      typeof value.terminal !== 'boolean' || typeof value.workerStopped !== 'boolean') throw new Error('Python 任务状态响应无效');
    const terminal: boolean = ['cancelled', 'succeeded', 'failed', 'timed_out'].includes(value.state);
    if (terminal !== value.terminal || (terminal && !value.workerStopped)) throw new Error('Python 服务未确认工作进程停止');
    return { jobId: id, state: value.state, terminal, workerStopped: value.workerStopped };
  }

  private cancellationResult(status: PythonJobStatus): PythonCancellationResult {
    let message: string = '取消请求已发送，尚未确认 Python 工作进程停止';
    if (status.terminal && status.workerStopped) {
      if (status.state === 'cancelled') message = 'Python 任务已终止，工作进程已停止';
      else if (status.state === 'succeeded') message = 'Python 已先于取消完成，本次执行结果有效';
      else if (status.state === 'timed_out') message = 'Python 执行超时，工作进程已停止';
      else message = 'Python 执行失败，工作进程已停止';
    }
    return { confirmed: status.terminal && status.workerStopped, message, jobStatus: status };
  }

  private async discoverCancellation(value: PythonOwnedOperation | undefined, config: PythonBridgeConfig, ticket: number): Promise<void> {
    if (value === undefined) return;
    value.config = config;
    const request = http.createHttp();
    this.activeRequest = request;
    try {
      const baseEndpoint: string = this.endpoint(config.endpoint);
      const response = await request.request(`${baseEndpoint}/health`, this.buildRequestOptions(config, baseEndpoint, {
        method: http.RequestMethod.GET, header: { Authorization: `Bearer ${config.token}` },
        expectDataType: http.HttpDataType.STRING, connectTimeout: 5000, readTimeout: 5000, maxLimit: 65536
      }));
      this.assertCurrent(ticket);
      if (response.responseCode !== 200) throw new Error('无法读取 Python 服务能力，请检查连接设置');
      const health = JSON.parse(response.result as string) as BridgeHealth;
      if (health.ok !== true || health.service !== 'hongtu-python-bridge' || health.execution !== 'host-companion') {
        throw new Error('该地址不是鸿图 Python 执行服务');
      }
      value.supportsCancellation = Array.isArray(health.capabilities) && health.capabilities.includes('job-cancellation-v1');
    } finally {
      try { request.destroy(); } catch (_) {}
      if (this.activeRequest === request) this.activeRequest = null;
    }
  }

  private acceptJobReply(value: PythonOwnedOperation | undefined, text: string, status: number): void {
    if (value === undefined || !value.supportsCancellation) return;
    let body: PythonJobEnvelope;
    try { body = JSON.parse(text) as PythonJobEnvelope; } catch (_) { throw new Error('Python 任务回复格式无效'); }
    if (body.jobStatus === undefined && status !== 200) return;
    if (body.jobId !== value.handle.jobId) throw new Error('Python 回复与本次任务不一致');
    const terminal: PythonJobStatus = this.jobStatus(body.jobStatus, value.handle.jobId);
    if (!terminal.terminal) throw new Error('Python 执行尚未完成，未载入结果');
    if ((terminal.state === 'succeeded') !== (body.success === true)) throw new Error('Python 任务终态与执行结果不一致');
    value.result = terminal;
    if (value.result.state === 'cancelled') throw new Error(this.cancellationResult(value.result).message);
  }

  async cancelOperation(handle: PythonOperationHandle): Promise<PythonCancellationResult> {
    const value: PythonOwnedOperation = this.owned(handle);
    if (value.result !== undefined) return this.cancellationResult(value.result);
    if (value.cancellation !== undefined) return value.cancellation;
    value.cancelRequested = true;
    value.cancellation = this.cancelOwnedOperation(value);
    return value.cancellation;
  }

  private async cancelOwnedOperation(value: PythonOwnedOperation): Promise<PythonCancellationResult> {
    if (!value.dispatched || !value.supportsCancellation) {
      if (this.activeOwner === value.handle.operationId) this.cancelActiveTransport();
      if (!value.dispatched) {
        value.result = { jobId: value.handle.jobId, state: 'cancelled', terminal: true, workerStopped: true };
        return { confirmed: true, message: '已取消，Python 工作进程尚未启动', jobStatus: value.result };
      }
      return { confirmed: false, message: '已取消等待；旧服务不支持终止任务，后台可能仍在运行' };
    }
    const config: PythonBridgeConfig | undefined = value.config;
    if (config === undefined) return { confirmed: false, message: '无法确认取消结果，后台可能仍在运行' };
    const baseEndpoint: string = this.endpoint(config.endpoint);
    // Keep the original result channel alive: success may win before cancellation.
    for (let attempt: number = 0; attempt < 4; attempt++) {
      const request = http.createHttp();
      try {
        const response = await request.request(
          `${baseEndpoint}/v1/jobs/${value.handle.jobId}${attempt === 0 ? '/cancel' : ''}`,
          this.buildRequestOptions(config, baseEndpoint, {
            method: attempt === 0 ? http.RequestMethod.POST : http.RequestMethod.GET,
            header: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}` },
            extraData: attempt === 0 ? '{}' : undefined, expectDataType: http.HttpDataType.STRING,
            connectTimeout: 5000, readTimeout: 15000, maxLimit: 65536
          })
        );
        if (response.responseCode !== 200 && response.responseCode !== 202) throw new Error('取消状态不可用');
        const status: PythonJobStatus = this.jobStatus(JSON.parse(response.result as string) as PythonJobStatus, value.handle.jobId);
        if (status.terminal) { value.result = status; return this.cancellationResult(status); }
      } catch (_) {
        if (value.result !== undefined) return this.cancellationResult(value.result);
        return { confirmed: false, message: '取消未获服务端确认，后台可能仍在运行；请等待本次任务返回' };
      } finally { try { request.destroy(); } catch (_) {} }
      if (value.result !== undefined) return this.cancellationResult(value.result);
      if (attempt < 3) await new Promise<void>((resolve: () => void): void => { setTimeout(resolve, 200); });
    }
    return { confirmed: false, message: '取消请求已发送，尚未确认工作进程停止；请等待本次任务返回' };
  }

  /** Release app-created input snapshots and sweep expired/excess orphan Python files in cacheDir and filesDir. */
  async disposeDocumentInput(document: PythonDocumentInput, context: common.UIAbilityContext): Promise<void> {
    const directory: string = this.safeDirectory(context?.cacheDir);
    if (directory.length > 0) {
      const paths: string[] = [document.path];
      if (document.selectionPath !== undefined && document.selectionPath !== document.path) paths.push(document.selectionPath);
      for (const path of paths) {
        if (!path.startsWith(`${directory}/`)) continue;
        const name: string = path.substring(directory.length + 1);
        if (!name.endsWith('.gds') || !/^python-(input|selection)-\d{13}-[1-9]\d*\.gds$/.test(name)) continue;
        try { await fs.unlink(path); } catch (_) { /* Missing/cache-evicted files never invalidate the run. */ }
      }
    }
    try {
      this.cleanupTemporaryFiles(context);
    } catch (_) {}
  }

  /** Legacy AI/download cancellation must not abort an explicitly owned panel task. */
  cancelGeneration(): void {
    if (this.activeOwner.length > 0) return;
    this.cancelActiveTransport();
  }

  private cancelActiveTransport(): void {
    this.generation++;
    const request: http.HttpRequest | null = this.activeRequest;
    this.activeRequest = null;
    if (request !== null) {
      try { request.destroy(); } catch (_) { /* Already completed. */ }
    }
  }

  private assertCurrent(ticket: number): void {
    if (ticket !== this.generation) throw new Error('Python 生成已取消');
  }

  private validCount(value: number, max: number): boolean {
    return typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value) && value >= 0 && value <= max;
  }

  private validateGds(bytes: Uint8Array, maxBytes: number = 8 * 1024 * 1024): void {
    if (bytes.length < 10 || bytes.length > maxBytes ||
      bytes[0] !== 0 || bytes[1] !== 6 || bytes[2] !== 0 || bytes[3] !== 2) {
      throw new Error('执行器返回的文件不是有效大小的 GDSII');
    }
    let offset: number = 0;
    let ended: boolean = false;
    while (offset < bytes.length) {
      if (offset + 4 > bytes.length) throw new Error('GDSII 记录头被截断');
      const size: number = bytes[offset] * 256 + bytes[offset + 1];
      if (size < 4 || size % 2 !== 0 || offset + size > bytes.length) throw new Error('GDSII 记录长度无效');
      if (bytes[offset + 2] === 4) {
        if (size !== 4 || bytes[offset + 3] !== 0 || offset + size !== bytes.length) throw new Error('GDSII ENDLIB 无效');
        ended = true;
      }
      offset += size;
    }
    if (!ended) throw new Error('GDSII 文件没有完整结束');
  }

  async loadConfig(): Promise<PythonBridgeConfig> {
    if (this.configMutationBusy) throw new Error('Python 连接设置正在保存，请等待完成');
    return this.readStoredConfig();
  }

  private async readStoredConfig(): Promise<PythonBridgeConfig> {
    PersistentStorage.persistProp(PYTHON_ENDPOINT_STORAGE_KEY, PYTHON_BRIDGE_DEFAULT_ENDPOINT);
    PersistentStorage.persistProp(PYTHON_CA_PATH_STORAGE_KEY, '');
    const config: PythonBridgeConfig = {
      endpoint: AppStorage.get<string>(PYTHON_ENDPOINT_STORAGE_KEY) ?? PYTHON_BRIDGE_DEFAULT_ENDPOINT,
      token: await credentialStore.get(PYTHON_TOKEN_ALIAS)
    };
    const storedCaPath: string = (AppStorage.get<string>(PYTHON_CA_PATH_STORAGE_KEY) ?? '').trim();
    if (storedCaPath.length > 0) {
      config.caPath = storedCaPath;
    }
    return config;
  }

  /** Keep connection credentials stable for an entire Agent run or health check. */
  beginConnectionUse(): void {
    if (this.configMutationBusy) throw new Error('Python 连接设置正在保存，请等待完成');
    this.connectionUsers++;
  }

  endConnectionUse(): void { if (this.connectionUsers > 0) this.connectionUsers--; }

  private endpoint(value: string): string {
    return validatePythonBridgeEndpoint(value);
  }

  async saveConfig(config: PythonBridgeConfig): Promise<void> {
    const endpoint: string = this.endpoint(config.endpoint);
    if (!/^[A-Za-z0-9_-]{32,256}$/.test(config.token.trim())) throw new Error('请填写启动脚本生成的访问令牌');
    const caPath: string | undefined = normalizePythonBridgeCaPath(config.caPath);
    if (caPath !== undefined && !endpoint.startsWith('https://')) {
      throw new Error('自定义 CA 证书路径仅适用于 HTTPS 伴随服务连接');
    }
    const nextConfig: PythonBridgeConfig = { endpoint, token: config.token.trim() };
    if (caPath !== undefined) nextConfig.caPath = caPath;
    await this.updateConnection(nextConfig, '保存');
  }

  async clearConnection(): Promise<PythonBridgeConfig> {
    return this.updateConnection({ endpoint: PYTHON_BRIDGE_DEFAULT_ENDPOINT, token: '' }, '清除');
  }

  private async updateConnection(config: PythonBridgeConfig, action: string): Promise<PythonBridgeConfig> {
    if (this.configMutationBusy || this.activeGeneration || this.connectionUsers > 0) {
      throw new Error('Python 或 Agent 正在使用连接，请等待任务结束后再修改');
    }
    this.configMutationBusy = true;
    try {
      const previous: PythonBridgeConfig = await this.readStoredConfig();
      const targetCa: string = config.caPath ?? '';
      const previousCa: string = previous.caPath ?? '';
      try {
        await credentialStore.put(PYTHON_TOKEN_ALIAS, config.token);
        AppStorage.setOrCreate<string>(PYTHON_ENDPOINT_STORAGE_KEY, config.endpoint);
        AppStorage.setOrCreate<string>(PYTHON_CA_PATH_STORAGE_KEY, targetCa);
        const saved: PythonBridgeConfig = await this.readStoredConfig();
        if (saved.endpoint !== config.endpoint || saved.token !== config.token || (saved.caPath ?? '') !== targetCa) {
          throw new Error('连接存储回读不一致');
        }
        return saved;
      } catch (_) {
        // Verify restoration rather than trusting a void return or an exception, and never echo credential data.
        try { await credentialStore.put(PYTHON_TOKEN_ALIAS, previous.token); } catch (_) {}
        try { AppStorage.setOrCreate<string>(PYTHON_ENDPOINT_STORAGE_KEY, previous.endpoint); } catch (_) {}
        try { AppStorage.setOrCreate<string>(PYTHON_CA_PATH_STORAGE_KEY, previousCa); } catch (_) {}
        let restored: boolean = false;
        try {
          const current: PythonBridgeConfig = await this.readStoredConfig();
          restored = current.endpoint === previous.endpoint && current.token === previous.token &&
            (current.caPath ?? '') === previousCa;
        } catch (_) {}
        throw new Error(restored ? `Python 连接${action}失败，已恢复原地址和凭据` :
          `Python 连接${action}失败，原配置恢复未确认；请重新打开连接设置检查地址和令牌`);
      }
    } finally { this.configMutationBusy = false; }
  }

  async checkConnection(requireAssistant: boolean = false): Promise<void> {
    this.beginConnectionUse();
    let request: http.HttpRequest | null = null;
    try {
      const config: PythonBridgeConfig = await this.loadConfig();
      const baseEndpoint: string = this.endpoint(config.endpoint);
      request = http.createHttp();
      const response = await request.request(`${baseEndpoint}/health`, this.buildRequestOptions(config, baseEndpoint, {
        method: http.RequestMethod.GET, header: { Authorization: `Bearer ${config.token}` },
        expectDataType: http.HttpDataType.STRING, connectTimeout: 5000, readTimeout: 5000, maxLimit: 65536
      }));
      if (response.responseCode === 401) throw new Error('Python 服务令牌无效，请更新连接设置');
      if (response.responseCode !== 200) throw new Error(`Python 服务连接失败（HTTP ${response.responseCode}）`);
      let health: BridgeHealth;
      try { health = JSON.parse(response.result as string) as BridgeHealth; } catch (_) {
        throw new Error('该地址未返回鸿图 Python 服务状态');
      }
      if (health.ok !== true || health.service !== 'hongtu-python-bridge' || health.execution !== 'host-companion') {
        throw new Error('该地址不是鸿图伴随 Python 执行服务');
      }
      if (requireAssistant && (!Array.isArray(health.capabilities) || !health.capabilities.includes('assistant-ag-ui'))) {
        throw new Error('该伴随服务未提供 Agent 协议，请更新服务后重新检查连接');
      }
    } finally {
      try { if (request !== null) request.destroy(); } finally { this.endConnectionUse(); }
    }
  }

  async generate(script: string, context: common.UIAbilityContext,
    options: PythonRunOptions = { inputMode: 'new' }, operation?: PythonOperationHandle): Promise<PythonLayoutArtifact> {
    if (this.activeGeneration || this.configMutationBusy) throw new Error('Python 正在处理其他请求或连接设置');
    if (script.length > 65536 || script.trim().length === 0 || new util.TextEncoder().encodeInto(script).byteLength > 65536) {
      throw new Error('脚本不能为空或超过 64 KiB UTF-8');
    }
    const protectedInputs: string[] = [];
    if (options.document?.path) protectedInputs.push(options.document.path);
    if (options.document?.selectionPath) protectedInputs.push(options.document.selectionPath);
    this.ensureStartupCleanup(context, protectedInputs);
    const owned: PythonOwnedOperation | undefined = this.claim(operation, 'generate');
    this.activeGeneration = true;
    const ticket: number = ++this.generation;
    try { return await this.generateArtifact(script, context, ticket, options, owned); } catch (error) {
      if (owned?.cancelRequested && owned.cancellation !== undefined) {
        const cancellation: PythonCancellationResult = await owned.cancellation;
        if (owned.result?.state !== 'succeeded') {
          throw new Error(owned.dispatched && owned.result !== undefined ? this.cancellationResult(owned.result).message : cancellation.message);
        }
      }
      this.assertCurrent(ticket);
      throw new Error(error instanceof Error ? error.message : 'Python 生成失败');
    } finally { this.activeGeneration = false; this.activeOwner = ''; }
  }

  /** Fetch only an owned server artifact, then use the same verified local materialization as generate. */
  async loadAssistantArtifact(artifactId: string, context: common.UIAbilityContext): Promise<PythonLayoutArtifact> {
    if (this.activeGeneration || this.configMutationBusy) throw new Error('Python 正在处理其他请求或连接设置');
    const normalizedId: string = normalizePythonArtifactId(artifactId);
    this.ensureStartupCleanup(context);
    this.activeGeneration = true;
    const ticket: number = ++this.generation;
    let request: http.HttpRequest | null = null;
    try {
      const config: PythonBridgeConfig = await this.loadConfig();
      this.assertCurrent(ticket);
      if (config.token.length === 0) throw new Error('请先配置 Python 执行服务');
      const baseEndpoint: string = this.endpoint(config.endpoint);
      request = http.createHttp();
      this.activeRequest = request;
      const response = await request.request(
        `${baseEndpoint}/v1/assistant/artifacts/${normalizedId}`,
        this.buildRequestOptions(config, baseEndpoint, {
          method: http.RequestMethod.GET, header: { Authorization: `Bearer ${config.token}` },
          expectDataType: http.HttpDataType.STRING, connectTimeout: 5000, readTimeout: 25000,
          maxLimit: 14 * 1024 * 1024
        })
      );
      this.assertCurrent(ticket);
      if (response.responseCode === 404 || response.responseCode === 410) {
        throw new Error('助手产物已过期或不存在，请重新生成');
      }
      const reply: AssistantArtifactReply = this.parseGenerateReply(response.responseCode,
        response.result as string, config.token) as AssistantArtifactReply;
      let replyIdNormalized: string = '';
      try {
        replyIdNormalized = normalizePythonArtifactId(reply.artifactId);
      } catch (_) {
        replyIdNormalized = '';
      }
      if (replyIdNormalized !== normalizedId || typeof reply.script !== 'string' || reply.script.trim().length === 0 ||
        reply.script.length > 65536 || new util.TextEncoder().encodeInto(reply.script).byteLength > 65536 ||
        typeof reply.originalRequest !== 'string' || reply.originalRequest.trim().length === 0 ||
        reply.originalRequest.length > 16000 || new util.TextEncoder().encodeInto(reply.originalRequest).byteLength > 65536 ||
        (reply.validationProfile !== undefined && reply.validationProfile !== '' && reply.validationProfile !== 'generic_inverter')) {
        throw new Error('助手产物身份、生成脚本或请求信息无效');
      }
      const options: PythonRunOptions = { inputMode: 'new' };
      if (reply.validationProfile === 'generic_inverter') options.validationProfile = 'generic_inverter';
      const artifact: PythonLayoutArtifact = this.materializeArtifact(reply, context, ticket, options);
      artifact.artifactId = normalizedId;
      artifact.script = reply.script;
      artifact.originalRequest = reply.originalRequest;
      artifact.validationProfile = options.validationProfile;
      return artifact;
    } catch (error) {
      this.assertCurrent(ticket);
      throw new Error(error instanceof Error ? error.message : '助手产物读取失败');
    } finally {
      try { if (request !== null) request.destroy(); } catch (_) { /* Cancellation may have already destroyed this request. */ }
      if (this.activeRequest === request) this.activeRequest = null;
      this.activeGeneration = false;
    }
  }

  async verify(options: PythonVerificationOptions, operation?: PythonOperationHandle): Promise<PythonVerificationResult> {
    if (this.activeGeneration || this.configMutationBusy) throw new Error('Python 正在处理其他请求或连接设置');
    const owned: PythonOwnedOperation | undefined = this.claim(operation, 'verify');
    this.activeGeneration = true;
    const ticket: number = ++this.generation;
    let request: http.HttpRequest | null = null;
    try {
      const config = await this.loadConfig();
      this.assertCurrent(ticket);
      if (!config.token) throw new Error('请先配置 Python 执行服务');
      await this.discoverCancellation(owned, config, ticket);
      this.assertCurrent(ticket);
      const body: PythonVerificationRequest = { kind: options.kind, technologyId: options.technologyId,
        deckId: options.deckId, documentGds: this.encodeSnapshot(options.document.path, 32 * 1024 * 1024),
        referenceSpice: options.referenceSpice, cellName: options.cellName };
      if (owned?.supportsCancellation) body.jobId = owned.handle.jobId;
      const baseEndpoint: string = this.endpoint(config.endpoint);
      request = http.createHttp(); this.activeRequest = request;
      if (owned !== undefined) owned.dispatched = true;
      const response = await request.request(`${baseEndpoint}/v1/verify`, this.buildRequestOptions(config, baseEndpoint, {
        method: http.RequestMethod.POST, header: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}` },
        extraData: JSON.stringify(body), expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000, readTimeout: 100000, maxLimit: PYTHON_VERIFY_MAX_RESPONSE_BYTES
      }));
      this.assertCurrent(ticket);
      this.acceptJobReply(owned, response.result as string, response.responseCode);
      if (response.responseCode !== 200) throw new Error(`工艺验证请求失败（HTTP ${response.responseCode}）`);
      const result = JSON.parse(response.result as string) as PythonVerificationResult;
      if (result === null || typeof result !== 'object' || Array.isArray(result) ||
        typeof result.success !== 'boolean' || (result.success &&
        (typeof result.complete !== 'boolean' || typeof result.passed !== 'boolean' || typeof result.reportText !== 'string'))) {
        throw new Error('工艺验证响应格式无效');
      }
      if (!result.success && (result.passed === true || result.complete === true))
        throw new Error('工艺验证失败响应包含矛盾的完成/通过结论');
      if (!result.success) {
        if ((result.kind !== undefined && result.kind !== body.kind) ||
          (result.technologyId !== undefined && result.technologyId !== body.technologyId) ||
          (result.deckId !== undefined && result.deckId !== body.deckId))
          throw new Error('工艺验证失败响应身份与本次请求不一致');
        return { success: false, complete: false, passed: false, kind: body.kind,
          technologyId: body.technologyId, deckId: body.deckId,
          engine: typeof result.engine === 'string' ? result.engine : '',
          scope: typeof result.scope === 'string' ? result.scope.substring(0, 2000) : '',
          foundrySignoff: false, netCount: 0, reportText: '',
          error: typeof result.error === 'string' ? result.error.substring(0, 1200) : '电脑工艺验证未完成',
          violations: [], devices: [], violationCount: 0, markersTruncated: false };
      }
      if (result.success) {
        if (result.kind !== body.kind || result.technologyId !== body.technologyId || result.deckId !== body.deckId)
          throw new Error('工艺验证响应身份与本次检查种类/工艺/deck 不一致');
        if (result.passed && !result.complete)
          throw new Error('工艺验证不完整，响应不得包含通过结论');
        if (result.foundrySignoff !== false)
          throw new Error('当前伴随验证协议不支持工业签核结论');
        if (!Array.isArray(result.violations) || !Array.isArray(result.devices) ||
          result.violations.length > 5000 || result.devices.length > 50000 ||
          typeof result.engine !== 'string' || result.engine.length === 0 ||
          typeof result.scope !== 'string' || result.scope.length > 2000 || typeof result.markersTruncated !== 'boolean')
          throw new Error('工艺验证响应结果列表/范围格式无效');
        if (!Number.isSafeInteger(result.violationCount) || result.violationCount < result.violations.length ||
          !Number.isSafeInteger(result.netCount) || result.netCount < 0)
          throw new Error('工艺验证响应计数无效');
        if (result.violationCount > result.violations.length && !result.markersTruncated)
          throw new Error('工艺验证标记计数需要明确截断提示');
        if (result.passed && result.violationCount > 0)
          throw new Error('工艺验证有违规，响应不得包含通过结论');
        for (const marker of result.violations) {
          if (marker === null || typeof marker !== 'object' ||
            typeof marker.rule !== 'string' || marker.rule.length > 2000 ||
            typeof marker.message !== 'string' || marker.message.length > 2000 ||
            !Number.isInteger(marker.layerNumber) || marker.layerNumber < 0 || marker.layerNumber > 65535 ||
            !Number.isInteger(marker.datatype) || marker.datatype < 0 || marker.datatype > 65535 ||
            ![marker.minX, marker.minY, marker.maxX, marker.maxY].every((n: number): boolean => typeof n === 'number' && Number.isFinite(n)) ||
            marker.minX > marker.maxX || marker.minY > marker.maxY)
            throw new Error('工艺验证响应位置标记无效');
        }
        for (const device of result.devices) {
          if (device === null || typeof device !== 'object' || typeof device.name !== 'string' || device.name.length > 2000 ||
            typeof device.model !== 'string' || device.model.length > 2000 || device.parameters === null ||
            typeof device.parameters !== 'object' || Array.isArray(device.parameters))
            throw new Error('工艺验证响应器件格式无效');
          const parameterNames: string[] = Object.keys(device.parameters);
          if (parameterNames.length > 1024 || !parameterNames.every((key: string): boolean => key.length <= 512 &&
            typeof device.parameters[key] === 'number' && Number.isFinite(device.parameters[key])))
            throw new Error('工艺验证响应器件参数无效');
        }
        let report: PythonVerificationReport;
        try { report = JSON.parse(result.reportText) as PythonVerificationReport; }
        catch (_) { throw new Error('工艺验证报告不是有效 JSON'); }
        if (report === null || typeof report !== 'object' || report.schema !== 'hongtu-verification/v1' ||
          typeof report.inputSha256 !== 'string' || !/^[a-f0-9]{64}$/.test(report.inputSha256) ||
          report.cellName !== (body.cellName ?? '') || report.technologyId !== body.technologyId || report.deckId !== body.deckId)
          throw new Error('工艺验证报告身份与所选 Cell/工艺/deck 不一致');
        const details: PythonVerificationReportDetails = report.details;
        if (details === null || typeof details !== 'object') throw new Error('工艺验证报告缺少检查结论');
        const sameMarkers: boolean = Array.isArray(details.violations) && details.violations.length === result.violations.length &&
          details.violations.every((marker: PythonViolation, index: number): boolean => {
            const original: PythonViolation = result.violations[index];
            return marker !== null && typeof marker === 'object' && marker.rule === original.rule && marker.message === original.message &&
              marker.layerNumber === original.layerNumber && marker.datatype === original.datatype &&
              marker.minX === original.minX && marker.minY === original.minY && marker.maxX === original.maxX && marker.maxY === original.maxY;
          });
        const sameDevices: boolean = Array.isArray(details.devices) && details.devices.length === result.devices.length &&
          details.devices.every((device: PythonVerifiedDevice, index: number): boolean => {
            const original: PythonVerifiedDevice = result.devices[index];
            if (device === null || typeof device !== 'object' || device.name !== original.name || device.model !== original.model ||
              device.parameters === null || typeof device.parameters !== 'object' || Array.isArray(device.parameters)) return false;
            const names: string[] = Object.keys(device.parameters);
            const originalNames: string[] = Object.keys(original.parameters);
            return names.length === originalNames.length && names.every((key: string): boolean =>
              originalNames.indexOf(key) >= 0 && device.parameters[key] === original.parameters[key]);
          });
        if (details === null || typeof details !== 'object' || report.engine !== result.engine || report.foundrySignoff !== false ||
          details.complete !== result.complete || details.passed !== result.passed || details.scope !== result.scope ||
          details.violationCount !== result.violationCount || details.markersTruncated !== result.markersTruncated ||
          details.netCount !== result.netCount || !sameMarkers || !sameDevices)
          throw new Error('工艺验证报告结论/标记与本次响应不一致');
      }
      return result;
    } catch (error) {
      if (owned?.cancelRequested && owned.cancellation !== undefined) {
        const cancellation: PythonCancellationResult = await owned.cancellation;
        if (owned.result?.state !== 'succeeded') {
          throw new Error(owned.dispatched && owned.result !== undefined ? this.cancellationResult(owned.result).message : cancellation.message);
        }
      }
      throw new Error(error instanceof Error ? error.message : '工艺验证失败');
    } finally {
      try { if (request !== null) request.destroy(); } catch (_) {}
      if (this.activeRequest === request) this.activeRequest = null;
      this.activeGeneration = false;
      this.activeOwner = '';
    }
  }

  private encodeSnapshot(path: string, maxBytes: number = 8 * 1024 * 1024): string {
    const size: number = fs.statSync(path).size;
    if (size < 10 || size > maxBytes) throw new Error(`版图快照需在 ${maxBytes / 1024 / 1024} MiB 以内`);
    const bytes = new ArrayBuffer(size);
    const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
    try {
      if (fs.readSync(file.fd, bytes) !== size) throw new Error('版图快照读取不完整');
    } finally { fs.closeSync(file); }
    this.validateGds(new Uint8Array(bytes), maxBytes);
    return new util.Base64Helper().encodeToStringSync(new Uint8Array(bytes));
  }

  private validatedLayerDefinitions(definitions: PythonLayerDefinition[] | undefined,
                                    expectedCount: number): PythonLayerDefinition[] {
    if (!Array.isArray(definitions)) throw new Error('Python 服务未返回图层定义，请更新伴随服务后重试');
    if (definitions.length < 1 || definitions.length > 256 || definitions.length !== expectedCount) {
      throw new Error('Python 返回的图层定义数量无效');
    }
    const result: PythonLayerDefinition[] = [];
    const seen: Set<string> = new Set<string>();
    for (const definition of definitions) {
      if (definition === null || typeof definition !== 'object' ||
        !Number.isInteger(definition.layerNumber) || definition.layerNumber < 0 || definition.layerNumber > 32767 ||
        !Number.isInteger(definition.datatype) || definition.datatype < 0 || definition.datatype > 32767 ||
        typeof definition.name !== 'string' || /[\u0000-\u001F\u007F-\u009F]/.test(definition.name) ||
        (definition.name.length > 0 && new util.TextEncoder().encodeInto(definition.name).byteLength > 256)) {
        throw new Error('Python 返回的图层号、用途或名称无效');
      }
      const key: string = `${definition.layerNumber}/${definition.datatype}`;
      if (seen.has(key)) throw new Error('Python 返回了重复的图层定义');
      seen.add(key);
      result.push({ layerNumber: definition.layerNumber, datatype: definition.datatype, name: definition.name });
    }
    return result;
  }

  private validatedPortMetadata(value: PythonPortMetadata | undefined, cellCount: number): PythonPortMetadata | undefined {
    // Older saved artifacts/companions can still be opened through the real GDS reader.
    if (value === undefined) return undefined;
    if (value === null || typeof value !== 'object' || value.schemaVersion !== 1 ||
      !Array.isArray(value.cellNames) || value.cellNames.length !== cellCount ||
      new Set<string>(value.cellNames).size !== cellCount || value.cellNames.some((name: string): boolean =>
        typeof name !== 'string' || !name.length || name.includes('\u0000') || layoutUtf8Bytes(name) > 256) ||
      !Array.isArray(value.diagnostics) || value.diagnostics.length > 2000 || value.diagnostics.some((item: string): boolean =>
        typeof item !== 'string' || item.includes('\u0000') || layoutUtf8Bytes(item) > 1024)) {
      throw new Error('Python 端口元数据 schema、Cell 名称或诊断无效');
    }
    if (!Array.isArray(value.cellKeys) || !Array.isArray(value.ports) || !Array.isArray(value.crossSections) ||
      !Array.isArray(value.layoutContextRecords) || !Array.isArray(value.cellContextRecords)) {
      throw new Error('Python 端口元数据缺少完整结构字段');
    }
    const semanticState: LayoutSemanticState = { cellKeys: value.cellKeys, ports: value.ports,
      crossSections: value.crossSections, layoutContextRecords: value.layoutContextRecords,
      cellContextRecords: value.cellContextRecords };
    validateLayoutSemantics(semanticState, cellCount);
    if (layoutUtf8Bytes(JSON.stringify(value)) > 8 * 1024 * 1024) throw new Error('Python 端口元数据超过 8 MiB 预算');
    return cloneStructured(value) as PythonPortMetadata;
  }

  private async generateArtifact(script: string, context: common.UIAbilityContext, ticket: number,
    options: PythonRunOptions, owned?: PythonOwnedOperation): Promise<PythonLayoutArtifact> {
    const config: PythonBridgeConfig = await this.loadConfig();
    this.assertCurrent(ticket);
    if (config.token.length === 0) throw new Error('请先配置 Python 执行服务');
    await this.discoverCancellation(owned, config, ticket);
    this.assertCurrent(ticket);
    const baseEndpoint: string = this.endpoint(config.endpoint);
    const request = http.createHttp();
    this.activeRequest = request;
    let reply: BridgeReply;
    try {
      const parameters: Record<string, number | string | boolean> = {};
      for (const item of options.parameters ?? []) {
        if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(item.name)) throw new Error('参数名称须为字母开头的标识符');
        if (typeof item.value === 'number' && (!Number.isFinite(item.value) || Math.abs(item.value) > 1e12)) {
          throw new Error('参数数值超出范围');
        }
        parameters[item.name] = item.value;
      }
      const body: GenerateRequest = { script, inputMode: options.inputMode, parameters };
      if (owned?.supportsCancellation) body.jobId = owned.handle.jobId;
      if (options.validationProfile !== undefined) {
        if (options.validationProfile !== 'generic_inverter' || options.inputMode !== 'new') {
          throw new Error('通用反相器检查只支持新建版图');
        }
        body.validationProfile = options.validationProfile;
      }
      if (options.inputMode !== 'new') {
        if (options.document === undefined) throw new Error('当前版图快照不可用');
        if (options.inputMode === 'document') body.documentGds = this.encodeSnapshot(options.document.path);
        else {
          if (!options.document.selectionPath) throw new Error('请先选中图形，或改为当前文档范围');
          body.selectionGds = this.encodeSnapshot(options.document.selectionPath);
        }
        body.currentCellName = options.document.currentCellName ?? '';
      }
      if (owned !== undefined) owned.dispatched = true;
      const response = await request.request(`${baseEndpoint}/v1/generate`, this.buildRequestOptions(config, baseEndpoint, {
        method: http.RequestMethod.POST,
        header: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}` },
        extraData: JSON.stringify(body), expectDataType: http.HttpDataType.STRING,
        connectTimeout: 5000, readTimeout: 25000, maxLimit: 14 * 1024 * 1024
      }));
      this.assertCurrent(ticket);
      this.acceptJobReply(owned, response.result as string, response.responseCode);
      reply = this.parseGenerateReply(response.responseCode, response.result as string, config.token);
    } finally {
      try { request.destroy(); } catch (_) {}
      if (this.activeRequest === request) this.activeRequest = null;
    }
    return this.materializeArtifact(reply, context, ticket, options);
  }

  private parseGenerateReply(status: number, result: string, token: string): BridgeReply {
    if (status === 401) throw new Error('Python 服务令牌无效，请更新连接设置');
    if (status === 429) throw new Error('Python 执行器仍在处理任务，请稍后重试');
    let reply: BridgeReply;
    try { reply = JSON.parse(result) as BridgeReply; } catch (_) {
      throw new Error(`Python 服务返回了无效响应（HTTP ${status}）`);
    }
    if (reply === null || typeof reply !== 'object' || Array.isArray(reply)) {
      throw new Error('Python 服务返回了无效响应');
    }
    if (status !== 200 || reply.success !== true) {
      const message: string = typeof reply.error === 'string' ? reply.error.substring(0,
        reply.error.startsWith('GenericInverterError:') ? 3000 : 1200) : '';
      throw new Error(message.length > 0 ? message.split(token).join('[已隐藏凭据]') : `Python 执行失败（HTTP ${status}）`);
    }
    return reply;
  }

  private materializeArtifact(reply: BridgeReply, context: common.UIAbilityContext, ticket: number,
    options: PythonRunOptions): PythonLayoutArtifact {
    this.assertCurrent(ticket);
    if (typeof reply.gdsBase64 !== 'string' || reply.gdsBase64.length === 0 ||
      reply.gdsBase64.length > 4 * Math.ceil(8 * 1024 * 1024 / 3) ||
      !/^[A-Za-z0-9+/]*={0,2}$/.test(reply.gdsBase64) || reply.gdsBase64.length % 4 !== 0) {
      throw new Error('Python 返回的版图编码或大小超出限制');
    }
    if (!this.validCount(reply.cellCount, 2000) || !this.validCount(reply.shapeCount, 200000) ||
      !this.validCount(reply.layerCount, 256) || (reply.expandedShapeCount !== undefined &&
      !this.validCount(reply.expandedShapeCount, 200000))) throw new Error('Python 返回的版图统计无效');
    const layerDefinitions: PythonLayerDefinition[] = this.validatedLayerDefinitions(reply.layerDefinitions, reply.layerCount);
    const portMetadata: PythonPortMetadata | undefined = this.validatedPortMetadata(reply.portMetadata, reply.cellCount);
    const reviewSummary: string | undefined = typeof reply.reviewSummary === 'string' && reply.reviewSummary.length <= 512 ?
      reply.reviewSummary : undefined;
    if (options.validationProfile === 'generic_inverter' && (reviewSummary === undefined ||
      !reviewSummary.startsWith('generic_inverter: consistent;') || !reviewSummary.includes('formalLvs=false') ||
      !reviewSummary.includes('foundrySignoff=false'))) {
      throw new Error('Python 服务未返回通用反相器检查结果，请更新并重启服务');
    }
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(reply.gdsBase64);
    reply.gdsBase64 = '';
    this.validateGds(bytes);
    const suppliedName: string = typeof reply.fileName === 'string' ? reply.fileName : 'python-layout.gds';
    const name: string = suppliedName.replace(/[^a-zA-Z0-9_.-]/g, '_').substring(0, 100) || 'python-layout.gds';
    const diskSuffix: string = name.toLowerCase().endsWith('.gds') ? name : `${name}.gds`;
    const prefix: string = `${context.filesDir}/python-${Date.now()}-${++this.serial}`;
    const path: string = `${prefix}-${diskSuffix}`;
    let previewPath: string = '';
    try {
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        if (fs.writeSync(file.fd, bytes.buffer) !== bytes.byteLength) throw new Error('GDSII 文件写入不完整');
      } finally { fs.closeSync(file); }
      const svg: string = typeof reply.previewSvg === 'string' ? reply.previewSvg : '';
      if (svg.length > 0 && svg.length <= 1500000 && /^\s*<svg\b/i.test(svg) &&
        !/<!|<\?(?:xml-stylesheet)|<(?:script|foreignObject|image|use|iframe|style|animate|set)\b|(?:xlink:)?href\s*=|url\s*\(|\bon\w+\s*=/i.test(svg)) {
        previewPath = `${prefix}.svg`;
        const preview = fs.openSync(previewPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
        try {
          if (fs.writeSync(preview.fd, svg) !== new util.TextEncoder().encodeInto(svg).byteLength) {
            throw new Error('SVG 预览写入不完整');
          }
        } finally { fs.closeSync(preview); }
      }
    } catch (error) {
      // Only this transaction's new paths are removed; no previous document is touched.
      try { fs.unlinkSync(path); } catch (_) { /* Not created. */ }
      if (previewPath.length > 0) { try { fs.unlinkSync(previewPath); } catch (_) { /* Not created. */ } }
      throw new Error(error instanceof Error ? error.message : 'Python 结果保存失败');
    }
    const protectedArtifacts: string[] = [path];
    if (previewPath.length > 0) protectedArtifacts.push(previewPath);
    if (options.document?.path) protectedArtifacts.push(options.document.path);
    if (options.document?.selectionPath) protectedArtifacts.push(options.document.selectionPath);
    try {
      this.cleanupTemporaryFiles(context, Date.now(), protectedArtifacts);
    } catch (_) {}
    return { path, name, previewPath, layerDefinitions, reviewSummary, portMetadata, sourceRevision: options.document?.revision,
      sourceDocumentId: options.document?.documentId, inputMode: options.inputMode,
      stdout: typeof reply.stdout === 'string' ? reply.stdout.substring(0, 16000) : '',
      summary: `${reply.cellCount} 个 Cell · ${reply.shapeCount} 个定义图元 · 展开 ${reply.expandedShapeCount ?? reply.shapeCount} 个 · ${reply.layerCount} 个图层` +
        (portMetadata !== undefined ? ` · ${portMetadata.ports.length} 个端口` : '') +
        (reply.previewTruncated ? ' · 缩略图仅显示部分图元，GDS 完整保留' : '') };
  }
}

export const pythonBridgeService = new PythonBridgeService();
