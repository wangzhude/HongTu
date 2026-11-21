/**
 * 鸿图 TaskPool 后台并发序列化与二进制编码引擎
 *
 * 严格遵循华为官方《TaskPool 简介》与《应用并发设计最佳实践》：
 * 1. 所有 `@Concurrent` 函数均为模块顶层纯函数，仅访问入参、局部变量及通过 `import` 引入的无状态/Sendable 符号；
 * 2. 主线程投递前统一调用 `unwrapObserved` 剥离 V1/V2 观察代理，防止跨线程结构化克隆抛出代理不可序列化异常；
 * 3. 返回值统一采用 `@Sendable` 载体（`SendableEncodedJson`）或默认零拷贝转移的 `ArrayBuffer`，避免大字符串重复拷贝；
 * 4. 当版图图形数量超过单次跨线程 16MB 安全阈值（或 >15,000 图元）时，自动拆分为 `@Concurrent` 分片并行编码并在后台统计 UTF-8 预算，
 *    即使在宿主预览器（Previewer）无 TaskPool 环境时也采用异步分片协作让步流式拼接，彻底消除 >60,000 图元在 UI 主线程同步阻塞。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { taskpool, util } from '@kit.ArkTS';
import { SendableJsonBudgetSpec, SendableEncodedJson } from '../models/LayoutSendablePayload';
import { unwrapObserved } from '../common/CloneUtils';

/** 单次整包直投 TaskPool 的安全图形与顶点上限（兼顾高顶点数光子晶体/曲线多边形） */
const TASKPOOL_SAFE_PAYLOAD_SHAPES: number = 2500;
const TASKPOOL_SAFE_PAYLOAD_POINTS: number = 32000;
/** 超大版图分片并发编码每片最大图形数与最大顶点数（保证单分片恒 < 4MB，绝不触碰 TaskPool 16MB 上限） */
const TASKPOOL_SHAPE_CHUNK_SIZE: number = 4000;
const TASKPOOL_SHAPE_CHUNK_MAX_POINTS: number = 80000;
/** 主线程协作让步的最小分片粒度 */
const COOPERATIVE_YIELD_SLICE_SHAPES: number = 4000;
/** 单次整串 UTF-8 TaskPool 二进制编码的安全字节上限（12 MiB） */
const TASKPOOL_SAFE_UTF8_BYTES: number = 12 * 1024 * 1024;
/** 异步流式 UTF-8 编码每批字符跨度（约 256 Ki UTF-16 单元，在代理对边界对齐） */
const UTF8_ENCODE_CHAR_SLICE: number = 262144;
/** 用于定位 shapes 数组插入槽位的唯一无碰撞哨兵 */
const SHAPES_SPLICE_SENTINEL: string = '__HONGTU_SHAPES_CHUNK_SPLICE_V3_9f83c4e2__';

function yieldToEventLoop(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(resolve, 0);
  });
}

@Concurrent
export function encodePlainObjectWithBudgetConcurrent(
  plainTarget: Object,
  spec: SendableJsonBudgetSpec
): SendableEncodedJson {
  try {
    const encoded: string = JSON.stringify(plainTarget);
    const limit: number = spec.maxUtf8Bytes;
    if (encoded.length > limit) {
      return new SendableEncodedJson(false, '', encoded.length, '文本超过文件读取预算');
    }
    let bytes: number = 0;
    for (let i: number = 0; i < encoded.length; i++) {
      const code: number = encoded.charCodeAt(i);
      if (code < 0x80) {
        bytes++;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (
        code >= 0xd800 &&
        code <= 0xdbff &&
        i + 1 < encoded.length &&
        encoded.charCodeAt(i + 1) >= 0xdc00 &&
        encoded.charCodeAt(i + 1) <= 0xdfff
      ) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
      if (bytes > limit) {
        return new SendableEncodedJson(false, '', bytes, '文本超过文件读取预算');
      }
    }
    return new SendableEncodedJson(true, encoded, bytes, '');
  } catch (err) {
    return new SendableEncodedJson(false, '', 0, String(err));
  }
}

@Concurrent
export function encodeShapeSliceWithBudgetConcurrent(
  shapesChunk: Object[],
  maxUtf8Bytes: number
): SendableEncodedJson {
  try {
    const arrayJson: string = JSON.stringify(shapesChunk);
    const inner: string = arrayJson.length >= 2 ? arrayJson.substring(1, arrayJson.length - 1) : '';
    if (inner.length > maxUtf8Bytes) {
      return new SendableEncodedJson(false, '', inner.length, '文本超过文件读取预算');
    }
    let bytes: number = 0;
    for (let i: number = 0; i < inner.length; i++) {
      const code: number = inner.charCodeAt(i);
      if (code < 0x80) {
        bytes++;
      } else if (code < 0x800) {
        bytes += 2;
      } else if (
        code >= 0xd800 &&
        code <= 0xdbff &&
        i + 1 < inner.length &&
        inner.charCodeAt(i + 1) >= 0xdc00 &&
        inner.charCodeAt(i + 1) <= 0xdfff
      ) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
      if (bytes > maxUtf8Bytes) {
        return new SendableEncodedJson(false, '', bytes, '文本超过文件读取预算');
      }
    }
    return new SendableEncodedJson(true, inner, bytes, '');
  } catch (err) {
    return new SendableEncodedJson(false, '', 0, String(err));
  }
}

@Concurrent
export function encodeSendableJsonToUtf8BufferConcurrent(payload: SendableEncodedJson): ArrayBuffer {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const encodedBytes: Uint8Array = encoder.encodeInto(payload.encoded);
  return encodedBytes.buffer.slice(encodedBytes.byteOffset, encodedBytes.byteOffset + encodedBytes.byteLength);
}

function measureUtf8ChunkSync(raw: string, currentBytes: number, limit: number): number {
  if (currentBytes + raw.length > limit) {
    throw new Error('文本超过文件读取预算');
  }
  let bytes: number = currentBytes;
  for (let i: number = 0; i < raw.length; i++) {
    const code: number = raw.charCodeAt(i);
    if (code < 0x80) {
      bytes++;
    } else if (code < 0x800) {
      bytes += 2;
    } else if (
      code >= 0xd800 &&
      code <= 0xdbff &&
      i + 1 < raw.length &&
      raw.charCodeAt(i + 1) >= 0xdc00 &&
      raw.charCodeAt(i + 1) <= 0xdfff
    ) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (bytes > limit) {
      throw new Error('文本超过文件读取预算');
    }
  }
  return bytes;
}

export class LayoutConcurrencyService {
  private shapeItemPointCount(item: Object): number {
    if (item === null || typeof item !== 'object') {
      return 0;
    }
    const rec: Record<string, Object> = unwrapObserved(item) as Record<string, Object>;
    const pts: Object | undefined = rec['points'];
    if (Array.isArray(pts)) {
      return (pts as Object[]).length;
    }
    return 1;
  }

  private extractLargeShapesArray(plainTarget: Object): Object[] | null {
    if (plainTarget === null || typeof plainTarget !== 'object' || Array.isArray(plainTarget)) {
      return null;
    }
    const rec: Record<string, Object> = plainTarget as Record<string, Object>;
    const maybeShapes: Object | undefined = unwrapObserved(rec['shapes']);
    if (!Array.isArray(maybeShapes)) {
      return null;
    }
    const arr: Object[] = maybeShapes as Object[];
    if (arr.length > TASKPOOL_SAFE_PAYLOAD_SHAPES) {
      return arr;
    }
    let totalPts: number = 0;
    for (let i = 0; i < arr.length; i++) {
      totalPts += this.shapeItemPointCount(arr[i]);
      if (totalPts > TASKPOOL_SAFE_PAYLOAD_POINTS) {
        return arr;
      }
    }
    return null;
  }

  private buildMetadataShellWithSentinel(plainTarget: Object): Record<string, Object> {
    const src: Record<string, Object> = plainTarget as Record<string, Object>;
    const shell: Record<string, Object> = {};
    const keys: string[] = Object.keys(src);
    for (let i: number = 0; i < keys.length; i++) {
      const key: string = keys[i];
      if (key === 'shapes') {
        shell[key] = SHAPES_SPLICE_SENTINEL as Object;
      } else {
        const val: Object | undefined = src[key];
        if (val !== undefined && typeof val !== 'function') {
          shell[key] = unwrapObserved(val);
        }
      }
    }
    return shell;
  }

  private async unwrapShapeSliceAsync(rawShapes: Object[], start: number, end: number): Promise<Object[]> {
    const count: number = end - start;
    const out: Object[] = new Array<Object>(count);
    for (let i: number = 0; i < count; i++) {
      out[i] = unwrapObserved(rawShapes[start + i]);
      if (i > 0 && i % COOPERATIVE_YIELD_SLICE_SHAPES === 0) {
        await yieldToEventLoop();
      }
    }
    return out;
  }

  private async encodeShapeSliceFallbackAsync(shapesChunk: Object[], maxUtf8Bytes: number): Promise<SendableEncodedJson> {
    const subParts: string[] = [];
    let bytes: number = 0;
    for (let offset: number = 0; offset < shapesChunk.length; offset += COOPERATIVE_YIELD_SLICE_SHAPES) {
      const sub: Object[] = shapesChunk.slice(offset, Math.min(shapesChunk.length, offset + COOPERATIVE_YIELD_SLICE_SHAPES));
      const rawArray: string = JSON.stringify(sub);
      const inner: string = rawArray.length >= 2 ? rawArray.substring(1, rawArray.length - 1) : '';
      if (inner.length > 0) {
        if (subParts.length > 0) {
          bytes = measureUtf8ChunkSync(',', bytes, maxUtf8Bytes);
        }
        bytes = measureUtf8ChunkSync(inner, bytes, maxUtf8Bytes);
        subParts.push(inner);
      }
      await yieldToEventLoop();
    }
    return new SendableEncodedJson(true, subParts.join(','), bytes, '');
  }

  /**
   * 分片并发编码超大版图（shapes > 20,000）：
   * 1. 先序列化除 shapes 外的轻量元数据壳；
   * 2. 按 15,000 图元一片并发投递至 TaskPool（受单次 16MB 限制保护），逐片累计校验 UTF-8 字节上限；
   * 3. 精确回填 `[chunk0,chunk1,...]`，产出与整包 `JSON.stringify` 100% 逐字节等价的 JSON 文本。
   */
  private async encodeLargeDocumentChunkedAsync(
    plainTarget: Object,
    rawShapes: Object[],
    maxUtf8Bytes: number,
    tag: string,
    priority: taskpool.Priority
  ): Promise<SendableEncodedJson> {
    const shellObj: Record<string, Object> = this.buildMetadataShellWithSentinel(plainTarget);
    const sentinelToken: string = `"${SHAPES_SPLICE_SENTINEL}"`;
    let shellEncoded: SendableEncodedJson;
    try {
      const shellTask: taskpool.Task = new taskpool.Task(
        encodePlainObjectWithBudgetConcurrent,
        shellObj,
        new SendableJsonBudgetSpec(maxUtf8Bytes, `${tag}-shell`)
      );
      shellEncoded = (await taskpool.execute(shellTask, priority)) as SendableEncodedJson;
      if (!shellEncoded.ok) {
        throw new Error(shellEncoded.errorMessage || '并发 JSON 编码超出预算');
      }
    } catch (err) {
      const msg: string = String(err);
      if (msg.includes('文本超过文件读取预算') || msg.includes('并发 JSON 编码超出预算')) {
        throw new Error(msg.replace(/^Error:\s*/, ''));
      }
      const shellJson: string = JSON.stringify(shellObj);
      const shellBytes: number = measureUtf8ChunkSync(shellJson, 0, maxUtf8Bytes);
      shellEncoded = new SendableEncodedJson(true, shellJson, shellBytes, '');
    }

    const tokenIdx: number = shellEncoded.encoded.indexOf(sentinelToken);
    if (tokenIdx < 0) {
      throw new Error('分片 JSON 壳结构校验失败');
    }
    const prefix: string = shellEncoded.encoded.substring(0, tokenIdx) + '[';
    const suffix: string = ']' + shellEncoded.encoded.substring(tokenIdx + sentinelToken.length);
    // sentinelToken 为纯 ASCII，替换为 "[]" 后的壳基础 UTF-8 字节数精确可算
    let totalUtf8Bytes: number = shellEncoded.utf8Bytes - sentinelToken.length + 2;
    if (totalUtf8Bytes > maxUtf8Bytes) {
      throw new Error('文本超过文件读取预算');
    }

    const encodedChunks: string[] = [];
    const totalShapes: number = rawShapes.length;
    let taskPoolAvailable: boolean = true;

    let start: number = 0;
    while (start < totalShapes) {
      let end: number = start;
      let chunkPts: number = 0;
      while (end < totalShapes && (end - start) < TASKPOOL_SHAPE_CHUNK_SIZE) {
        const pts: number = this.shapeItemPointCount(rawShapes[end]);
        if (end > start && chunkPts + pts > TASKPOOL_SHAPE_CHUNK_MAX_POINTS) {
          break;
        }
        chunkPts += pts;
        end++;
      }
      const unwrappedSlice: Object[] = await this.unwrapShapeSliceAsync(rawShapes, start, end);
      const remainingBudget: number = maxUtf8Bytes - totalUtf8Bytes - (encodedChunks.length > 0 ? 1 : 0);
      if (remainingBudget < 0) {
        throw new Error('文本超过文件读取预算');
      }

      let sliceResult: SendableEncodedJson | null = null;
      if (taskPoolAvailable) {
        try {
          const sliceTask: taskpool.Task = new taskpool.Task(
            encodeShapeSliceWithBudgetConcurrent,
            unwrappedSlice,
            remainingBudget
          );
          sliceResult = (await taskpool.execute(sliceTask, priority)) as SendableEncodedJson;
          if (!sliceResult.ok) {
            throw new Error(sliceResult.errorMessage || '文本超过文件读取预算');
          }
        } catch (err) {
          const msg: string = String(err);
          if (msg.includes('文本超过文件读取预算') || msg.includes('并发 JSON 编码超出预算')) {
            throw new Error(msg.replace(/^Error:\s*/, ''));
          }
          taskPoolAvailable = false;
          sliceResult = null;
        }
      }

      if (sliceResult === null) {
        sliceResult = await this.encodeShapeSliceFallbackAsync(unwrappedSlice, remainingBudget);
      }

      if (sliceResult.encoded.length > 0) {
        if (encodedChunks.length > 0) {
          totalUtf8Bytes += 1; // ','
        }
        totalUtf8Bytes += sliceResult.utf8Bytes;
        if (totalUtf8Bytes > maxUtf8Bytes) {
          throw new Error('文本超过文件读取预算');
        }
        encodedChunks.push(sliceResult.encoded);
      }
      start = end;
      await yieldToEventLoop();
    }

    const finalJson: string = prefix + encodedChunks.join(',') + suffix;
    return new SendableEncodedJson(true, finalJson, totalUtf8Bytes, '');
  }

  /**
   * 在 TaskPool 工作线程异步执行大对象 JSON 序列化与 UTF-8 字节预算校验。
   */
  async encodeJsonWithBudgetAsync(
    target: Object,
    maxUtf8Bytes: number,
    tag: string = 'workspace-draft',
    priority: taskpool.Priority = taskpool.Priority.MEDIUM
  ): Promise<SendableEncodedJson> {
    const plainTarget: Object = unwrapObserved(target);
    const largeShapes: Object[] | null = this.extractLargeShapesArray(plainTarget);
    if (largeShapes !== null) {
      return await this.encodeLargeDocumentChunkedAsync(plainTarget, largeShapes, maxUtf8Bytes, tag, priority);
    }

    const spec: SendableJsonBudgetSpec = new SendableJsonBudgetSpec(maxUtf8Bytes, tag);
    try {
      const task: taskpool.Task = new taskpool.Task(encodePlainObjectWithBudgetConcurrent, plainTarget, spec);
      const result: SendableEncodedJson = (await taskpool.execute(task, priority)) as SendableEncodedJson;
      if (!result.ok) {
        throw new Error(result.errorMessage || '并发 JSON 编码超出预算');
      }
      return result;
    } catch (err) {
      const msg: string = String(err);
      if (msg.includes('文本超过文件读取预算') || msg.includes('并发 JSON 编码超出预算')) {
        throw new Error(msg.replace(/^Error:\s*/, ''));
      }
    }

    await yieldToEventLoop();
    const fallbackText: string = JSON.stringify(plainTarget);
    let fallbackBytes: number = 0;
    for (let pos: number = 0; pos < fallbackText.length; pos += UTF8_ENCODE_CHAR_SLICE) {
      let end: number = Math.min(fallbackText.length, pos + UTF8_ENCODE_CHAR_SLICE);
      if (end < fallbackText.length) {
        const lastCode: number = fallbackText.charCodeAt(end - 1);
        if (lastCode >= 0xd800 && lastCode <= 0xdbff) {
          end++;
        }
      }
      fallbackBytes = measureUtf8ChunkSync(fallbackText.substring(pos, end), fallbackBytes, maxUtf8Bytes);
      if (end < fallbackText.length) {
        await yieldToEventLoop();
      }
    }
    return new SendableEncodedJson(true, fallbackText, fallbackBytes, '');
  }

  /**
   * 将已完成预算校验的 SendableEncodedJson 编码为 UTF-8 二进制 ArrayBuffer。
   */
  async encodeJsonToUtf8BufferAsync(jsonResult: SendableEncodedJson): Promise<ArrayBuffer> {
    if (jsonResult.utf8Bytes <= TASKPOOL_SAFE_UTF8_BYTES) {
      try {
        const utf8Task: taskpool.Task = new taskpool.Task(encodeSendableJsonToUtf8BufferConcurrent, jsonResult);
        return (await taskpool.execute(utf8Task, taskpool.Priority.MEDIUM)) as ArrayBuffer;
      } catch (_) {
        // Previewer 或受限环境平滑转入下方异步分片编码
      }
    }

    const totalBytes: number = jsonResult.utf8Bytes;
    const output: Uint8Array = new Uint8Array(totalBytes);
    const encoder: util.TextEncoder = new util.TextEncoder();
    const text: string = jsonResult.encoded;
    let writeOffset: number = 0;
    let cursor: number = 0;
    while (cursor < text.length) {
      let nextCursor: number = Math.min(text.length, cursor + UTF8_ENCODE_CHAR_SLICE);
      if (nextCursor < text.length) {
        const trailing: number = text.charCodeAt(nextCursor - 1);
        if (trailing >= 0xd800 && trailing <= 0xdbff) {
          nextCursor++;
        }
      }
      const chunkBytes: Uint8Array = encoder.encodeInto(text.substring(cursor, nextCursor));
      if (writeOffset + chunkBytes.byteLength > output.byteLength) {
        throw new Error('UTF-8 分片编码长度校验不一致');
      }
      output.set(chunkBytes, writeOffset);
      writeOffset += chunkBytes.byteLength;
      cursor = nextCursor;
      if (cursor < text.length) {
        await yieldToEventLoop();
      }
    }
    if (writeOffset !== totalBytes) {
      return output.buffer.slice(0, writeOffset);
    }
    return output.buffer;
  }

  /**
   * 在 TaskPool 工作线程或异步分片流中将 JSON 载荷编码为 UTF-8 二进制 ArrayBuffer。
   */
  async encodeUtf8BufferWithBudgetAsync(
    target: Object,
    maxUtf8Bytes: number,
    tag: string = 'project-export'
  ): Promise<ArrayBuffer> {
    const jsonResult: SendableEncodedJson = await this.encodeJsonWithBudgetAsync(
      target,
      maxUtf8Bytes,
      tag,
      taskpool.Priority.MEDIUM
    );
    return await this.encodeJsonToUtf8BufferAsync(jsonResult);
  }
}

export const layoutConcurrencyService: LayoutConcurrencyService = new LayoutConcurrencyService();
