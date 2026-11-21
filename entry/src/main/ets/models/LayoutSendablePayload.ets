/**
 * 鸿图跨线程零拷贝传输载体（@Sendable DTO）
 *
 * 严格遵循华为官方《Sendable 对象简介》与《TaskPool 简介》规范：
 * 1. 本文件仅声明 @Sendable 数据类，严禁混入 @Observed / @ObservedV2 / UI 组件装饰器；
 * 2. 所有成员属性均为基础可共享类型（boolean / number / string），杜绝闭包捕获与非 Sendable 引用；
 * 3. 供 LayoutConcurrencyService 中的顶层 @Concurrent 函数通过 import 直接引用，实现主线程与工作线程间零拷贝传递。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

@Sendable
export class SendableJsonBudgetSpec {
  readonly maxUtf8Bytes: number;
  readonly tag: string;

  constructor(maxUtf8Bytes: number, tag: string = 'hongtu-snapshot') {
    this.maxUtf8Bytes = maxUtf8Bytes;
    this.tag = tag;
  }
}

@Sendable
export class SendableEncodedJson {
  readonly ok: boolean;
  readonly encoded: string;
  readonly utf8Bytes: number;
  readonly errorMessage: string;

  constructor(ok: boolean, encoded: string, utf8Bytes: number, errorMessage: string = '') {
    this.ok = ok;
    this.encoded = encoded;
    this.utf8Bytes = utf8Bytes;
    this.errorMessage = errorMessage;
  }
}
