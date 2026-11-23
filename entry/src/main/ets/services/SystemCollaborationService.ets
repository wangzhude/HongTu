/**
 * 鸿图全场景协同与原生分享服务（UDMF 统一拖拽 + Share Kit 系统分享 & 碰一碰流转）
 *
 * 官方规范依据：
 * - UDMF 统一拖拽：https://developer.huawei.com/consumer/cn/doc/best-practices/bpta-unified-drag-and-drop
 * - Share Kit 系统分享：https://developer.huawei.com/consumer/cn/doc/harmonyos-references/share-system-share
 * - 碰一碰文件分享：https://developer.huawei.com/consumer/en/doc/best-practices/bpta-application-knock-file-share
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { common } from '@kit.AbilityKit';
import { unifiedDataChannel, uniformDataStruct, uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { harmonyShare, systemShare } from '@kit.ShareKit';

export type DroppedAssetKind = 'layout' | 'lyp' | 'rdb';

export interface DroppedHongTuAsset {
  kind: DroppedAssetKind;
  uri: string;
  fileName: string;
}

export interface KnockSharePayload {
  sandboxPath: string;
  fileName: string;
  title: string;
  description: string;
  thumbnailSandboxPath?: string;
}

/**
 * 工作台根容器允许拖入的标准化数据类型集合。
 * 覆盖文件管理拖入文件 URI、通用二进制文件、KLayout XML (.lyp / .lyrdb) 与纯文本路径。
 */
export const HONGTU_ALLOWED_DROP_TYPES: Array<utd.UniformDataType> = [
  utd.UniformDataType.FILE_URI,
  utd.UniformDataType.FILE,
  utd.UniformDataType.XML,
  utd.UniformDataType.PLAIN_TEXT,
];

export const HONGTU_AI_CHAT_DROP_TYPES: Array<utd.UniformDataType> = [
  utd.UniformDataType.IMAGE,
  utd.UniformDataType.FILE_URI,
  utd.UniformDataType.FILE,
  utd.UniformDataType.XML,
  utd.UniformDataType.PLAIN_TEXT,
];

export function extractDroppedRawUris(event: DragEvent | undefined): string[] {
  if (event === undefined) {
    return [];
  }
  const out: string[] = [];
  const seen: Set<string> = new Set<string>();
  try {
    const dragData: unifiedDataChannel.UnifiedData = event.getData();
    if (dragData === undefined || dragData === null) {
      return [];
    }
    const records: Array<unifiedDataChannel.UnifiedRecord> = dragData.getRecords();
    for (let i = 0; i < records.length; i++) {
      const record: unifiedDataChannel.UnifiedRecord = records[i];
      let candidate: string = '';
      try {
        const types: string[] = record.getTypes();
        if (types.includes(utd.UniformDataType.FILE_URI)) {
          const entry = record.getEntry(utd.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
          if (entry !== undefined && typeof entry.oriUri === 'string') {
            candidate = entry.oriUri.trim();
          }
        }
        if (candidate.length === 0 && types.includes(utd.UniformDataType.PLAIN_TEXT)) {
          const textEntry = record.getEntry(utd.UniformDataType.PLAIN_TEXT) as uniformDataStruct.PlainText;
          if (textEntry !== undefined && typeof textEntry.textContent === 'string' && textEntry.textContent.startsWith('file://')) {
            candidate = textEntry.textContent.trim();
          }
        }
      } catch (_e) {}
      if (candidate.length === 0) {
        const legacy: LegacyFileRecord = record as Object as LegacyFileRecord;
        if (typeof legacy.oriUri === 'string' && legacy.oriUri.length > 0) {
          candidate = legacy.oriUri.trim();
        } else if (typeof legacy.uri === 'string' && legacy.uri.length > 0) {
          candidate = legacy.uri.trim();
        }
      }
      if (candidate.length > 0 && !seen.has(candidate)) {
        seen.add(candidate);
        out.push(candidate);
      }
    }
  } catch (_err) {}
  return out;
}

function decodeDisplayFileName(uri: string): string {
  const clean: string = uri.split(/[?#]/)[0];
  const slash: number = clean.lastIndexOf('/');
  const rawName: string = slash >= 0 ? clean.substring(slash + 1) : clean;
  try {
    return decodeURIComponent(rawName);
  } catch (_error) {
    return rawName;
  }
}

export function classifyHongTuUri(uri: string): DroppedHongTuAsset | null {
  if (typeof uri !== 'string') {
    return null;
  }
  const trimmed: string = uri.trim();
  if (trimmed.length === 0) {
    return null;
  }
  const fileName: string = decodeDisplayFileName(trimmed);
  const lower: string = fileName.toLowerCase();
  if (
    lower.endsWith('.gds') ||
    lower.endsWith('.gdsii') ||
    lower.endsWith('.oas') ||
    lower.endsWith('.oasis') ||
    lower.endsWith('.cif') ||
    lower.endsWith('.dxf')
  ) {
    return { kind: 'layout', uri: trimmed, fileName: fileName };
  }
  if (lower.endsWith('.lyp')) {
    return { kind: 'lyp', uri: trimmed, fileName: fileName };
  }
  if (lower.endsWith('.lyrdb') || lower.endsWith('.rdb') || lower.endsWith('.xml')) {
    return { kind: 'rdb', uri: trimmed, fileName: fileName };
  }
  return null;
}

interface LegacyFileRecord {
  uri?: string;
  oriUri?: string;
}

export class SystemCollaborationService {
  private knockRegistered: boolean = false;
  private knockPayloadProvider: (() => KnockSharePayload | null) | null = null;
  private shareCacheSeq: number = 0;

  private readonly knockShareCallback: (target: harmonyShare.SharableTarget) => void =
    (target: harmonyShare.SharableTarget): void => {
      if (this.knockPayloadProvider === null) {
        return;
      }
      try {
        const payload: KnockSharePayload | null = this.knockPayloadProvider();
        if (payload === null || payload.sandboxPath.length === 0) {
          return;
        }
        const shareData: systemShare.SharedData = this.buildSharedDataFromSandbox(
          payload.sandboxPath,
          payload.fileName,
          payload.title,
          payload.description,
          payload.thumbnailSandboxPath
        );
        target.share(shareData);
      } catch (error) {
        console.warn(`[SystemCollaboration] 碰一碰分享构建失败: ${String(error)}`);
      }
    };

  /**
   * 从 ArkUI DragEvent 中提取所有可由鸿图识别的版图 / 工艺层 / DRC 报告 URI。
   */
  extractDroppedAssets(event: DragEvent | undefined): DroppedHongTuAsset[] {
    if (event === undefined) {
      return [];
    }
    const candidates: string[] = [];
    try {
      const dragData: unifiedDataChannel.UnifiedData = event.getData();
      if (dragData === undefined || dragData === null) {
        return [];
      }
      const records: Array<unifiedDataChannel.UnifiedRecord> = dragData.getRecords();
      for (let i: number = 0; i < records.length; i++) {
        const record: unifiedDataChannel.UnifiedRecord = records[i];
        let extracted: boolean = false;
        try {
          const types: string[] = record.getTypes();
          if (types.includes(utd.UniformDataType.FILE_URI)) {
            const entry = record.getEntry(utd.UniformDataType.FILE_URI) as uniformDataStruct.FileUri;
            if (entry !== undefined && typeof entry.oriUri === 'string' && entry.oriUri.length > 0) {
              candidates.push(entry.oriUri);
              extracted = true;
            }
          }
          if (!extracted && types.includes(utd.UniformDataType.PLAIN_TEXT)) {
            const textEntry = record.getEntry(utd.UniformDataType.PLAIN_TEXT) as uniformDataStruct.PlainText;
            if (textEntry !== undefined && typeof textEntry.textContent === 'string' && textEntry.textContent.startsWith('file://')) {
              candidates.push(textEntry.textContent.trim());
              extracted = true;
            }
          }
        } catch (_entryErr) {
          // 兼容旧版 File 子类记录读取
        }
        if (!extracted) {
          const legacy: LegacyFileRecord = record as Object as LegacyFileRecord;
          if (typeof legacy.oriUri === 'string' && legacy.oriUri.length > 0) {
            candidates.push(legacy.oriUri);
          } else if (typeof legacy.uri === 'string' && legacy.uri.length > 0) {
            candidates.push(legacy.uri);
          }
        }
      }
    } catch (error) {
      console.warn(`[SystemCollaboration] 读取拖拽数据失败: ${String(error)}`);
      return [];
    }

    const results: DroppedHongTuAsset[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < candidates.length; i++) {
      const classified: DroppedHongTuAsset | null = classifyHongTuUri(candidates[i]);
      if (classified !== null && !seen.has(classified.uri)) {
        seen.add(classified.uri);
        results.push(classified);
      }
    }
    return results;
  }

  private resolveUtdForFileName(fileName: string): string {
    const dot: number = fileName.lastIndexOf('.');
    const ext: string = dot >= 0 ? fileName.substring(dot).toLowerCase() : '';
    if (ext === '.png') {
      try {
        return utd.getUniformDataTypeByFilenameExtension('.png', utd.UniformDataType.IMAGE);
      } catch (_e) {
        return utd.UniformDataType.IMAGE;
      }
    }
    if (ext === '.svg') {
      try {
        return utd.getUniformDataTypeByFilenameExtension('.svg', utd.UniformDataType.IMAGE);
      } catch (_e) {
        return utd.UniformDataType.FILE;
      }
    }
    if (ext === '.xml' || ext === '.lyp' || ext === '.lyrdb') {
      return utd.UniformDataType.XML;
    }
    if (ext.length > 1) {
      try {
        const matched: string = utd.getUniformDataTypeByFilenameExtension(ext, utd.UniformDataType.FILE);
        if (matched && matched.length > 0) {
          return matched;
        }
      } catch (_e) {
        // 自定义 EDA 后缀（.gds / .oas）回退标准 general.file
      }
    }
    return utd.UniformDataType.FILE;
  }

  private buildSharedDataFromSandbox(
    sandboxPath: string,
    fileName: string,
    title: string,
    description: string,
    thumbnailSandboxPath?: string
  ): systemShare.SharedData {
    const shareUri: string = fileUri.getUriFromPath(sandboxPath);
    const utdId: string = this.resolveUtdForFileName(fileName);
    const record: systemShare.SharedRecord = {
      utd: utdId,
      uri: shareUri,
      title: title,
      description: description,
      thumbnailUri: thumbnailSandboxPath !== undefined && thumbnailSandboxPath.length > 0
        ? fileUri.getUriFromPath(thumbnailSandboxPath)
        : (fileName.toLowerCase().endsWith('.png') ? shareUri : undefined),
    };
    return new systemShare.SharedData(record);
  }

  /**
   * 拉起系统原生分享面板分享应用沙箱内已生成的导出文件。
   */
  async shareSandboxFile(
    context: common.UIAbilityContext,
    sandboxPath: string,
    fileName: string,
    description: string,
    thumbnailSandboxPath?: string
  ): Promise<void> {
    const shareData: systemShare.SharedData = this.buildSharedDataFromSandbox(
      sandboxPath,
      fileName,
      fileName,
      description,
      thumbnailSandboxPath
    );
    const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT,
    });
  }

  /**
   * 将用户通过 DocumentViewPicker 导出的外部 URI 安全暂存至沙箱分享目录后拉起 Share Kit，
   * 避免外部 Picker URI 直接跨应用传递时接收方缺少文件读取授权。
   */
  async shareExternalUriViaCache(
    context: common.UIAbilityContext,
    sourceUri: string,
    fileName: string,
    description: string
  ): Promise<void> {
    const shareDir: string = `${context.cacheDir}/hongtu_share_stage`;
    try {
      if (!fs.accessSync(shareDir)) {
        fs.mkdirSync(shareDir);
      }
    } catch (_mkdirErr) {
      try { fs.mkdirSync(shareDir); } catch (_ignore) {}
    }
    this.pruneDirectory(shareDir, 6);
    const safeBase: string = fileName.replace(/[^a-zA-Z0-9._\-一-龥]/g, '_');
    const stagedPath: string = `${shareDir}/${Date.now()}_${++this.shareCacheSeq}_${safeBase.length > 0 ? safeBase : 'export.dat'}`;
    const srcFile: fs.File = await fs.open(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      const size: number = fs.statSync(srcFile.fd).size;
      if (!Number.isSafeInteger(size) || size <= 0 || size > 256 * 1024 * 1024) {
        throw new Error('分享文件为空或超出 256 MiB 限制');
      }
      await fs.copyFile(srcFile.fd, stagedPath, 0);
    } finally {
      fs.closeSync(srcFile);
    }
    await this.shareSandboxFile(context, stagedPath, fileName, description);
  }

  pruneDirectory(dirPath: string, keepCount: number): void {
    try {
      const names: string[] = fs.listFileSync(dirPath).sort();
      if (names.length <= keepCount) {
        return;
      }
      const removeTotal: number = names.length - keepCount;
      for (let i: number = 0; i < removeTotal; i++) {
        try {
          fs.unlinkSync(`${dirPath}/${names[i]}`);
        } catch (_unlinkErr) {}
      }
    } catch (_listErr) {}
  }

  /**
   * 注册华为分享「碰一碰文件流转」监听（离开页面时务必调用 unregisterKnockShare 释放）。
   */
  registerKnockShare(provider: () => KnockSharePayload | null): void {
    this.knockPayloadProvider = provider;
    if (this.knockRegistered) {
      return;
    }
    try {
      harmonyShare.on('knockShare', this.knockShareCallback);
      this.knockRegistered = true;
    } catch (error) {
      // 模拟器或不支持碰一碰的设备静默降级，不影响主界面正常使用
      console.info(`[SystemCollaboration] 当前环境未启用 knockShare: ${String(error)}`);
    }
  }

  unregisterKnockShare(): void {
    this.knockPayloadProvider = null;
    if (!this.knockRegistered) {
      return;
    }
    try {
      harmonyShare.off('knockShare', this.knockShareCallback);
    } catch (_error) {
      // 忽略反注册异常
    } finally {
      this.knockRegistered = false;
    }
  }
}

export const systemCollaborationService: SystemCollaborationService = new SystemCollaborationService();
