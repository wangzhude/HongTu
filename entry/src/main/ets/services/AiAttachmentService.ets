/**
 * 鸿图 Agent 多模态附件与剪贴板协同服务
 *
 * 完整覆盖：
 * 1. 相册选图（PhotoViewPicker）与任意文档/版图/代码文件选择（DocumentViewPicker）；
 * 2. 剪贴板粘贴图片（PixelMap -> PNG 沙箱落盘）、粘贴文件 URI（MIMETYPE_URI）及粘贴文本；
 * 3. 一键复制图片到系统剪贴板（MIMETYPE_PIXELMAP）与复制文件到系统剪贴板（MIMETYPE_URI）；
 * 4. 附件另存到用户目录（DocumentViewPicker.save）与多模态视觉模型 Base64 Data URL 按需编码；
 * 5. 版图附件自动调用 nativeHongTuService.quickScan 提取 Cell/图层快速摘要，代码/网表/规则文本自动提取预览供 Agent 阅读。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { nativeHongTuService } from './NativeHongTuService';

export type AiAttachmentKind = 'image' | 'layout' | 'text' | 'binary';

export interface AiChatAttachment {
  id: string;
  name: string;
  kind: AiAttachmentKind;
  mimeType: string;
  sandboxPath: string;
  fileUriString: string;
  sizeBytes: number;
  width?: number;
  height?: number;
  summary?: string;
  textPreview?: string;
}

export interface AiClipboardPasteResult {
  attachments: AiChatAttachment[];
  pastedText: string;
  statusMessage: string;
}

const MAX_ATTACHMENT_BYTES: number = 128 * 1024 * 1024;
const MAX_VISION_IMAGE_BYTES: number = 8 * 1024 * 1024;
const MAX_TEXT_PREVIEW_CHARS: number = 6000;

export interface AiClassifiedAttachmentType {
  kind: AiAttachmentKind;
  mimeType: string;
}

export function classifyAttachmentByName(fileName: string, explicitMime: string = ''): AiClassifiedAttachmentType {
  const lower: string = fileName.trim().toLowerCase();
  const mimeLower: string = explicitMime.trim().toLowerCase();
  if (mimeLower.startsWith('image/') || /\.(?:png|jpe?g|webp|gif|bmp)$/.test(lower)) {
    if (lower.endsWith('.png') || mimeLower === 'image/png') return { kind: 'image', mimeType: 'image/png' };
    if (lower.endsWith('.webp') || mimeLower === 'image/webp') return { kind: 'image', mimeType: 'image/webp' };
    if (lower.endsWith('.gif') || mimeLower === 'image/gif') return { kind: 'image', mimeType: 'image/gif' };
    if (lower.endsWith('.bmp') || mimeLower === 'image/bmp') return { kind: 'image', mimeType: 'image/bmp' };
    return { kind: 'image', mimeType: 'image/jpeg' };
  }
  if (/\.(?:gds|gds2|gdsii|oas|oasis)$/.test(lower)) {
    return { kind: 'layout', mimeType: lower.includes('.oas') ? 'application/x-oasis' : 'application/x-gdsii' };
  }
  if (
    mimeLower.startsWith('text/') ||
    /\.(?:txt|md|json|json5|lyp|lyt|rdb|sp|spi|spice|cdl|cir|net|v|sv|py|ets|ts|js|cpp|h|hpp|xml|yaml|yml|csv|drc|lvs|log|svg)$/.test(lower)
  ) {
    if (lower.endsWith('.svg')) return { kind: 'text', mimeType: 'image/svg+xml' };
    if (lower.endsWith('.json') || lower.endsWith('.json5')) return { kind: 'text', mimeType: 'application/json' };
    if (lower.endsWith('.py')) return { kind: 'text', mimeType: 'text/x-python' };
    return { kind: 'text', mimeType: 'text/plain' };
  }
  return { kind: 'binary', mimeType: explicitMime.length > 0 ? explicitMime : 'application/octet-stream' };
}

export function formatAttachmentSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
}

function sanitizeAttachmentFileName(rawName: string, fallbackExt: string = '.bin'): string {
  let base: string = rawName.trim().replace(/\\/g, '/');
  const slash: number = base.lastIndexOf('/');
  if (slash >= 0) {
    base = base.substring(slash + 1);
  }
  const qIdx: number = base.indexOf('?');
  if (qIdx >= 0) {
    base = base.substring(0, qIdx);
  }
  try {
    base = decodeURIComponent(base);
  } catch (_) {}
  base = base.replace(/[\u0000-\u001F\u007F<>:"|?*]+/g, '_').trim();
  if (base.length === 0 || base === '.' || base === '..') {
    base = `attachment_${Date.now()}${fallbackExt}`;
  }
  if (base.length > 96) {
    const dot: number = base.lastIndexOf('.');
    const ext: string = dot > 0 ? base.substring(dot) : '';
    base = `${base.substring(0, Math.max(16, 96 - ext.length))}${ext}`;
  }
  return base;
}

export class AiAttachmentService {
  private seq: number = 0;

  private ensureAttachmentDir(context: common.UIAbilityContext): string {
    const dir: string = `${context.filesDir}/ai_attachments`;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (_) {
      try { fs.mkdirSync(dir); } catch (_2) {}
    }
    return dir;
  }

  private nextAttachmentId(prefix: string = 'att'): string {
    this.seq = (this.seq + 1) % 1000000;
    return `${prefix}_${Date.now().toString(36)}_${this.seq}`;
  }

  private copyFdToPath(srcFd: number, dstPath: string): number {
    const outFile = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    let total: number = 0;
    try {
      const chunkSize: number = 256 * 1024;
      const buf: ArrayBuffer = new ArrayBuffer(chunkSize);
      while (true) {
        const readLen: number = fs.readSync(srcFd, buf, { offset: total, length: chunkSize });
        if (readLen <= 0) break;
        total += readLen;
        if (total > MAX_ATTACHMENT_BYTES) {
          throw new Error('单个附件超过 128 MB 上限');
        }
        fs.writeSync(outFile.fd, buf, { length: readLen });
      }
      fs.fsyncSync(outFile.fd);
    } finally {
      try { fs.closeSync(outFile); } catch (_) {}
    }
    return total;
  }

  private enrichAttachmentMetadata(att: AiChatAttachment): AiChatAttachment {
    if (att.kind === 'image') {
      let imgSource: image.ImageSource | null = null;
      try {
        imgSource = image.createImageSource(att.sandboxPath);
        const info: image.ImageInfo = imgSource.getImageInfoSync();
        if (info && info.size) {
          att.width = info.size.width;
          att.height = info.size.height;
          att.summary = `${info.size.width}×${info.size.height} px · ${formatAttachmentSize(att.sizeBytes)}`;
        }
      } catch (_) {
        att.summary = formatAttachmentSize(att.sizeBytes);
      } finally {
        try { if (imgSource !== null) imgSource.release(); } catch (_) {}
      }
      return att;
    }

    if (att.kind === 'layout') {
      try {
        const scan = nativeHongTuService.quickScan(att.sandboxPath);
        if (scan && scan.valid) {
          att.summary = `${scan.format.toUpperCase()} 版图 · ${scan.cellCount} Cells · ${scan.layerCount} Layers · ${formatAttachmentSize(att.sizeBytes)}`;
        } else {
          att.summary = `版图文件 · ${formatAttachmentSize(att.sizeBytes)}`;
        }
      } catch (_) {
        att.summary = `版图文件 · ${formatAttachmentSize(att.sizeBytes)}`;
      }
      return att;
    }

    if (att.kind === 'text') {
      try {
        const preview: string = this.readAttachmentText(att, MAX_TEXT_PREVIEW_CHARS);
        att.textPreview = preview;
        const lines: number = preview.length > 0 ? preview.split('\n').length : 0;
        att.summary = `文本/代码 · ${lines}+ 行 · ${formatAttachmentSize(att.sizeBytes)}`;
      } catch (_) {
        att.summary = formatAttachmentSize(att.sizeBytes);
      }
      return att;
    }

    att.summary = formatAttachmentSize(att.sizeBytes);
    return att;
  }

  ingestUri(context: common.UIAbilityContext, rawUri: string, preferredName: string = '', explicitMime: string = ''): AiChatAttachment {
    const cleanUri: string = rawUri.trim();
    if (cleanUri.length === 0) {
      throw new Error('文件 URI 为空');
    }
    const dir: string = this.ensureAttachmentDir(context);
    const id: string = this.nextAttachmentId('att');
    const inferredName: string = sanitizeAttachmentFileName(preferredName.length > 0 ? preferredName : cleanUri);
    const dstPath: string = `${dir}/${id}_${inferredName}`;

    const srcFile = fs.openSync(cleanUri, fs.OpenMode.READ_ONLY);
    let copiedBytes: number = 0;
    try {
      copiedBytes = this.copyFdToPath(srcFile.fd, dstPath);
    } catch (e) {
      try { fs.unlinkSync(dstPath); } catch (_) {}
      throw e;
    } finally {
      try { fs.closeSync(srcFile); } catch (_) {}
    }

    const cls = classifyAttachmentByName(inferredName, explicitMime);
    const att: AiChatAttachment = {
      id,
      name: inferredName,
      kind: cls.kind,
      mimeType: cls.mimeType,
      sandboxPath: dstPath,
      fileUriString: fileUri.getUriFromPath(dstPath),
      sizeBytes: copiedBytes
    };
    return this.enrichAttachmentMetadata(att);
  }

  adoptSandboxFile(context: common.UIAbilityContext, existingPath: string, displayName: string, explicitMime: string = ''): AiChatAttachment {
    const dir: string = this.ensureAttachmentDir(context);
    const id: string = this.nextAttachmentId('out');
    const safeName: string = sanitizeAttachmentFileName(displayName);
    const dstPath: string = existingPath.startsWith(dir) ? existingPath : `${dir}/${id}_${safeName}`;
    if (dstPath !== existingPath) {
      fs.copyFileSync(existingPath, dstPath);
    }
    const stat = fs.statSync(dstPath);
    const cls = classifyAttachmentByName(safeName, explicitMime);
    const att: AiChatAttachment = {
      id,
      name: safeName,
      kind: cls.kind,
      mimeType: cls.mimeType,
      sandboxPath: dstPath,
      fileUriString: fileUri.getUriFromPath(dstPath),
      sizeBytes: stat.size
    };
    return this.enrichAttachmentMetadata(att);
  }

  writeTextDeliverable(context: common.UIAbilityContext, fileName: string, content: string, explicitMime: string = 'text/plain'): AiChatAttachment {
    const dir: string = this.ensureAttachmentDir(context);
    const id: string = this.nextAttachmentId('doc');
    const safeName: string = sanitizeAttachmentFileName(fileName, '.txt');
    const dstPath: string = `${dir}/${id}_${safeName}`;
    const encoder = new util.TextEncoder();
    const encoded: Uint8Array = encoder.encodeInto(content);
    const outFile = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
    try {
      fs.writeSync(outFile.fd, encoded.buffer, { length: encoded.byteLength });
      fs.fsyncSync(outFile.fd);
    } finally {
      try { fs.closeSync(outFile); } catch (_) {}
    }
    const cls = classifyAttachmentByName(safeName, explicitMime);
    const att: AiChatAttachment = {
      id,
      name: safeName,
      kind: cls.kind,
      mimeType: cls.mimeType,
      sandboxPath: dstPath,
      fileUriString: fileUri.getUriFromPath(dstPath),
      sizeBytes: encoded.byteLength
    };
    return this.enrichAttachmentMetadata(att);
  }

  async savePixelMapAsAttachment(context: common.UIAbilityContext, pixelMap: image.PixelMap, baseName: string = ''): Promise<AiChatAttachment> {
    const dir: string = this.ensureAttachmentDir(context);
    const id: string = this.nextAttachmentId('img');
    const safeName: string = sanitizeAttachmentFileName(
      baseName.trim().length > 0 ? baseName : `pasted_image_${Date.now()}.png`,
      '.png'
    );
    const dstPath: string = `${dir}/${id}_${safeName}`;
    const packer: image.ImagePacker = image.createImagePacker();
    try {
      const packed: ArrayBuffer = await packer.packing(pixelMap, { format: 'image/png', quality: 100 });
      const outFile = fs.openSync(dstPath, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.WRITE_ONLY);
      try {
        fs.writeSync(outFile.fd, packed, { length: packed.byteLength });
        fs.fsyncSync(outFile.fd);
      } finally {
        try { fs.closeSync(outFile); } catch (_) {}
      }
      let w: number | undefined = undefined;
      let h: number | undefined = undefined;
      try {
        const info: image.ImageInfo = await pixelMap.getImageInfo();
        w = info.size.width;
        h = info.size.height;
      } catch (_) {}
      const att: AiChatAttachment = {
        id,
        name: safeName,
        kind: 'image',
        mimeType: 'image/png',
        sandboxPath: dstPath,
        fileUriString: fileUri.getUriFromPath(dstPath),
        sizeBytes: packed.byteLength,
        width: w,
        height: h,
        summary: w !== undefined && h !== undefined
          ? `${w}×${h} px · ${formatAttachmentSize(packed.byteLength)}`
          : formatAttachmentSize(packed.byteLength)
      };
      return att;
    } finally {
      try { await packer.release(); } catch (_) {}
    }
  }

  async pickPhotos(context: common.UIAbilityContext, maxCount: number = 6): Promise<AiChatAttachment[]> {
    const photoPicker = new photoAccessHelper.PhotoViewPicker();
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = Math.max(1, Math.min(9, maxCount));
    const result: photoAccessHelper.PhotoSelectResult = await photoPicker.select(opts);
    const uris: string[] = result?.photoUris ?? [];
    const attachments: AiChatAttachment[] = [];
    for (let i = 0; i < uris.length; i++) {
      if (uris[i] && uris[i].trim().length > 0) {
        attachments.push(this.ingestUri(context, uris[i], '', 'image/*'));
      }
    }
    return attachments;
  }

  async pickFiles(context: common.UIAbilityContext, maxCount: number = 6): Promise<AiChatAttachment[]> {
    const docPicker = new picker.DocumentViewPicker(context);
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = Math.max(1, Math.min(9, maxCount));
    const uris: string[] = await docPicker.select(opts);
    const attachments: AiChatAttachment[] = [];
    for (let i = 0; i < uris.length; i++) {
      if (uris[i] && uris[i].trim().length > 0) {
        attachments.push(this.ingestUri(context, uris[i]));
      }
    }
    return attachments;
  }

  async readClipboard(context: common.UIAbilityContext): Promise<AiClipboardPasteResult> {
    const sysBoard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    if (!sysBoard.hasDataSync()) {
      return { attachments: [], pastedText: '', statusMessage: '剪贴板当前为空' };
    }
    const data: pasteboard.PasteData = await sysBoard.getData();
    const attachments: AiChatAttachment[] = [];
    let pastedText: string = '';

    // 1. Check PixelMap image in clipboard (screenshots / copied photos)
    try {
      if (data.hasType(pasteboard.MIMETYPE_PIXELMAP)) {
        const pm: image.PixelMap | undefined = data.getPrimaryPixelMap();
        if (pm !== undefined && pm !== null) {
          const imgAtt: AiChatAttachment = await this.savePixelMapAsAttachment(context, pm, `clipboard_${Date.now()}.png`);
          attachments.push(imgAtt);
        }
      }
    } catch (_) {}

    // 2. Check copied file URIs in clipboard (Finder / File Manager copied files or photos)
    try {
      const recordCount: number = data.getRecordCount();
      for (let i = 0; i < recordCount; i++) {
        const rec: pasteboard.PasteDataRecord = data.getRecord(i);
        if (rec && typeof rec.uri === 'string' && rec.uri.trim().length > 0) {
          try {
            attachments.push(this.ingestUri(context, rec.uri.trim()));
          } catch (_) {}
        }
      }
      if (attachments.length === 0 && data.hasType(pasteboard.MIMETYPE_URI)) {
        const primaryUri: string = data.getPrimaryUri();
        if (primaryUri && primaryUri.trim().length > 0) {
          attachments.push(this.ingestUri(context, primaryUri.trim()));
        }
      }
    } catch (_) {}

    // 3. Check plain text in clipboard
    try {
      if (data.hasType(pasteboard.MIMETYPE_TEXT_PLAIN)) {
        const txt: string = data.getPrimaryText();
        if (typeof txt === 'string' && txt.length > 0) {
          pastedText = txt;
        }
      }
    } catch (_) {}

    const parts: string[] = [];
    if (attachments.length > 0) parts.push(`已粘贴 ${attachments.length} 个附件`);
    if (pastedText.length > 0) parts.push(`已粘贴文本（${pastedText.length} 字）`);
    return {
      attachments,
      pastedText,
      statusMessage: parts.length > 0 ? parts.join('，') : '剪贴板中未识别到可粘贴的图片、文件或文本'
    };
  }

  async copyAttachmentToClipboard(att: AiChatAttachment): Promise<string> {
    if (!fs.accessSync(att.sandboxPath)) {
      throw new Error('附件文件已不存在');
    }
    const sysBoard: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
    if (att.kind === 'image') {
      let imgSource: image.ImageSource | null = null;
      let pm: image.PixelMap | null = null;
      try {
        imgSource = image.createImageSource(att.sandboxPath);
        pm = await imgSource.createPixelMap();
        const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pm);
        const uriRecord: pasteboard.PasteDataRecord = pasteboard.createRecord(pasteboard.MIMETYPE_URI, att.fileUriString);
        pasteData.addRecord(uriRecord);
        await sysBoard.setData(pasteData);
        return `已复制图片「${att.name}」到剪贴板`;
      } finally {
        try { if (pm !== null) await pm.release(); } catch (_) {}
        try { if (imgSource !== null) await imgSource.release(); } catch (_) {}
      }
    }

    const pasteData: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_URI, att.fileUriString);
    if (att.kind === 'text') {
      try {
        const txt: string = this.readAttachmentText(att, 64000);
        if (txt.length > 0) {
          const textRecord: pasteboard.PasteDataRecord = pasteboard.createRecord(pasteboard.MIMETYPE_TEXT_PLAIN, txt);
          pasteData.addRecord(textRecord);
        }
      } catch (_) {}
    }
    await sysBoard.setData(pasteData);
    return `已复制文件「${att.name}」到剪贴板`;
  }

  async saveAttachmentToUserFile(context: common.UIAbilityContext, att: AiChatAttachment): Promise<string> {
    if (!fs.accessSync(att.sandboxPath)) {
      throw new Error('附件文件已不存在');
    }
    const docPicker = new picker.DocumentViewPicker(context);
    const saveOpts = new picker.DocumentSaveOptions();
    saveOpts.newFileNames = [att.name];
    const uris: string[] = await docPicker.save(saveOpts);
    if (!uris || uris.length === 0 || uris[0].trim().length === 0) {
      return '';
    }
    const srcFile = fs.openSync(att.sandboxPath, fs.OpenMode.READ_ONLY);
    const dstFile = fs.openSync(uris[0], fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
    try {
      const chunk: ArrayBuffer = new ArrayBuffer(256 * 1024);
      let offset: number = 0;
      while (true) {
        const n: number = fs.readSync(srcFile.fd, chunk, { offset, length: 256 * 1024 });
        if (n <= 0) break;
        offset += n;
        fs.writeSync(dstFile.fd, chunk, { length: n });
      }
      fs.fsyncSync(dstFile.fd);
    } finally {
      try { fs.closeSync(dstFile); } catch (_) {}
      try { fs.closeSync(srcFile); } catch (_) {}
    }
    return `已保存「${att.name}」`;
  }

  readAttachmentText(att: AiChatAttachment, maxChars: number = 16000, offsetChars: number = 0): string {
    if (!fs.accessSync(att.sandboxPath)) {
      throw new Error(`附件 ${att.name} 不存在`);
    }
    const stat = fs.statSync(att.sandboxPath);
    const maxReadBytes: number = Math.min(stat.size, 512 * 1024);
    const file = fs.openSync(att.sandboxPath, fs.OpenMode.READ_ONLY);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(maxReadBytes);
      const readLen: number = fs.readSync(file.fd, buf, { offset: 0, length: maxReadBytes });
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      const fullText: string = decoder.decodeToString(new Uint8Array(buf, 0, readLen));
      const safeStart: number = Math.max(0, Math.min(fullText.length, offsetChars));
      const slice: string = fullText.substring(safeStart, safeStart + Math.max(256, maxChars));
      return safeStart + maxChars < fullText.length ? `${slice}\n…（共 ${fullText.length} 字符）` : slice;
    } finally {
      try { fs.closeSync(file); } catch (_) {}
    }
  }

  readImageAsDataUrl(att: AiChatAttachment): string {
    if (att.kind !== 'image' || !fs.accessSync(att.sandboxPath)) {
      return '';
    }
    const stat = fs.statSync(att.sandboxPath);
    if (stat.size <= 0 || stat.size > MAX_VISION_IMAGE_BYTES) {
      return '';
    }
    const file = fs.openSync(att.sandboxPath, fs.OpenMode.READ_ONLY);
    try {
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const readLen: number = fs.readSync(file.fd, buf, { offset: 0, length: stat.size });
      const helper = new util.Base64Helper();
      const b64: string = helper.encodeToStringSync(new Uint8Array(buf, 0, readLen));
      return `data:${att.mimeType};base64,${b64}`;
    } catch (_) {
      return '';
    } finally {
      try { fs.closeSync(file); } catch (_) {}
    }
  }
}

export const aiAttachmentService: AiAttachmentService = new AiAttachmentService();
