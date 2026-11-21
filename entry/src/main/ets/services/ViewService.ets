/**
 * 鸿图视图增强服务
 *
 * 提供与 KLayout 对齐的视图操作功能：
 * - 导航器数据（Navigator）— 提供全图概览缩略图数据
 * - 图层显隐预设（LayerPreset）— 保存/应用图层可见性
 * - Cell 层级显示控制 — 默认 2 级，可调 1-32
 * - 视图状态（缩放/偏移）— 由外部同步，resetView 重置为默认值
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape } from '../models/GdsiiData';

/** 图层显隐预设（layerNumber:datatype → visible） */
export interface LayerPreset {
  name: string;
  layerVisibilities: Map<string, boolean>;
}

/** 预设序列化条目（内部使用，Map 无法直接 JSON 序列化，故拆为数组） */
interface LayerVisibilityEntry {
  layerNumber: number;
  datatype?: number;
  visible: boolean;
}

/** 预设序列化结构（内部使用，用于 PersistentStorage 持久化） */
interface LayerPresetSerialized {
  name: string;
  entries: LayerVisibilityEntry[];
}

/** 导航器缩略图数据（所有图形的包围盒） */
export interface NavigatorData {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
  shapeCount: number;
}

/** 视图偏移 */
export interface ViewOffset {
  offsetX: number;
  offsetY: number;
}

/**
 * 视图增强服务
 */
export class ViewService {
  // ===== 图层显隐预设 =====
  // 所有图层预设（持久化到 PersistentStorage）
  private layerPresets: LayerPreset[] = [];
  // 当前图层可见性镜像：由外部通过 setCurrentLayerVisibility 同步，
  // saveLayerPreset 据此快照保存，applyLayerPreset 据此触发回调。
  private currentLayerVisibilities: Map<string, boolean> = new Map<string, boolean>();
  // PersistentStorage 中存储预设的键名
  private static readonly LAYER_PRESETS_KEY: string = 'layerPresets';
  private layerPresetStorageError: string = '';
  private layerPresetStorageReady: boolean = false;
  private layerPresetStorageBaseline: string | undefined = undefined;

  // ===== Cell 层级显示控制 =====
  // 层级深度：对齐 KLayout hierarchy levels
  // depth=1 → 仅当前 Cell 本地几何；depth=N → 递归展开 N-1 层子实例几何（见 HierarchyExpandService）
  private hierarchyDepth: number = 2;
  // 视图默认值（resetView 重置目标，参考现有 zoomPercent=100 / offset=0 居中基准）
  private static readonly DEFAULT_HIERARCHY_DEPTH: number = 2;
  private static readonly DEFAULT_ZOOM_PERCENT: number = 100;
  private static readonly DEFAULT_OFFSET_X: number = 0;
  private static readonly DEFAULT_OFFSET_Y: number = 0;
  // 当前视图状态（缩放/偏移），由外部同步；resetView 重置为默认值
  private viewZoomPercent: number = ViewService.DEFAULT_ZOOM_PERCENT;
  private viewOffsetX: number = ViewService.DEFAULT_OFFSET_X;
  private viewOffsetY: number = ViewService.DEFAULT_OFFSET_Y;

  // ===== 回调机制（供 LayoutCanvasView 等监听） =====
  // 层级深度变化时触发，画布据此重绘（按新深度过滤实例递归）
  onHierarchyDepthChange?: (n: number) => void;
  // applyLayerPreset 改变图层可见性时触发，调用方据此改 UiLayer.visible
  onLayerVisibilityChange?: (visibilities: Map<string, boolean>) => void;
  // resetView 触发，调用方据此重置画布缩放/偏移（含自适应居中逻辑）
  onViewReset?: () => void;

  constructor() {
    this.loadLayerPresets();
  }

  // ===== 导航器 =====

  /** 生成导航器缩略图数据（所有图形的包围盒） */
  getNavigatorData(shapes: Shape[]): NavigatorData {
    if (shapes.length === 0) {
      const empty: NavigatorData = { minX: 0, minY: 0, maxX: 1000, maxY: 1000, shapeCount: 0 };
      return empty;
    }
    let minX: number = Infinity, minY: number = Infinity, maxX: number = -Infinity, maxY: number = -Infinity;
    let hasValidPoints: boolean = false;
    for (const s of shapes) {
      // VIEW-1: 防御空 points 数组导致包围盒保持 Infinity
      if (s.points.length === 0) {
        continue;
      }
      for (const p of s.points) {
        minX = Math.min(minX, p.x);
        minY = Math.min(minY, p.y);
        maxX = Math.max(maxX, p.x);
        maxY = Math.max(maxY, p.y);
        hasValidPoints = true;
      }
    }
    // VIEW-1: 所有图形的 points 都为空时回退到默认包围盒
    if (!hasValidPoints) {
      const fallback: NavigatorData = { minX: 0, minY: 0, maxX: 1000, maxY: 1000, shapeCount: shapes.length };
      return fallback;
    }
    const result: NavigatorData = { minX: minX, minY: minY, maxX: maxX, maxY: maxY, shapeCount: shapes.length };
    return result;
  }

  // ===== 图层显隐预设 =====

  /**
   * 同步单个图层的可见性到服务镜像。
   * 外部（如 Index.ets 的 setLayerVisible）在改变 UiLayer.visible 时调用，
   * 使 saveLayerPreset 能捕获最新状态。
   */
  setCurrentLayerVisibility(layerNumber: number, visible: boolean, datatype: number = 0): void {
    this.currentLayerVisibilities.set(`${layerNumber}:${datatype}`, visible);
  }

  /**
   * 批量同步图层可见性镜像（替换式）。
   * 用于初始化或加载新文件后整体同步。
   */
  setCurrentLayerVisibilities(visibilities: Map<string, boolean>): void {
    this.currentLayerVisibilities = new Map<string, boolean>(visibilities);
  }

  /** 获取当前图层可见性镜像（VIEW-1: 返回副本，避免外部修改污染内部状态） */
  getCurrentLayerVisibilities(): Map<string, boolean> {
    return new Map<string, boolean>(this.currentLayerVisibilities);
  }

  /**
   * 保存当前所有图层 visible 状态为预设。
   * 同名预设将被覆盖。保存后立即持久化到 PersistentStorage。
   * @return 保存成功返回 true
   */
  saveLayerPreset(name: string): boolean {
    this.layerPresetStorageError = '';
    if (typeof name !== 'string' || name.trim().length === 0 || name.length > 512 || /[\x00-\x1f]/.test(name)) {
      this.layerPresetStorageError = '预设名称须为 1–512 个字符且不含控制字符';
      return false;
    }
    // 深拷贝当前镜像，避免后续镜像变化影响已存预设
    const snapshot: Map<string, boolean> = new Map<string, boolean>(this.currentLayerVisibilities);
    const preset: LayerPreset = { name, layerVisibilities: snapshot };
    const candidate: LayerPreset[] = this.layerPresets.slice();
    const existingIdx = candidate.findIndex(p => p.name === name);
    if (existingIdx >= 0) {
      candidate[existingIdx] = preset;
    } else {
      candidate.push(preset);
    }
    return this.persistLayerPresets(candidate);
  }

  /**
   * 应用预设：将预设中的可见性写回当前镜像，并通过 onLayerVisibilityChange 回调
   * 通知调用方更新 UiLayer.visible（即"改图层 visible"）。
   * @return 找不到预设返回 false
   */
  applyLayerPreset(name: string): boolean {
    const preset = this.layerPresets.find(p => p.name === name);
    if (!preset) {
      return false;
    }
    const previous: Map<string, boolean> = new Map<string, boolean>(this.currentLayerVisibilities);
    try {
      // 深拷贝预设到当前镜像，避免预设被外部修改
      this.currentLayerVisibilities = new Map<string, boolean>(preset.layerVisibilities);
      if (this.onLayerVisibilityChange) {
        // VIEW-1: 传副本而非内部引用，避免回调方误写污染 currentLayerVisibilities
        this.onLayerVisibilityChange(new Map<string, boolean>(this.currentLayerVisibilities));
      }
      return true;
    } catch (failure) {
      this.currentLayerVisibilities = previous;
      let restoreError: string = '';
      if (this.onLayerVisibilityChange) {
        try { this.onLayerVisibilityChange(new Map<string, boolean>(previous)); }
        catch (rollbackFailure) { restoreError = `；图层显示恢复回调失败：${String(rollbackFailure)}`; }
      }
      // A display callback may itself resynchronize the service mirror. Keep
      // the exact prior service state even if that recovery callback fails.
      this.currentLayerVisibilities = new Map<string, boolean>(previous);
      throw new Error(`预设应用未完成：${String(failure)}；可见性镜像已恢复${restoreError}`);
    }
  }

  /**
   * 删除预设。删除后立即持久化。
   * @return 找不到预设返回 false
   */
  deleteLayerPreset(name: string): boolean {
    this.layerPresetStorageError = '';
    const idx = this.layerPresets.findIndex(p => p.name === name);
    if (idx < 0) {
      this.layerPresetStorageError = '预设不存在，请刷新列表';
      return false;
    }
    const candidate: LayerPreset[] = this.layerPresets.slice();
    candidate.splice(idx, 1);
    return this.persistLayerPresets(candidate);
  }

  /** Failure text is read by the existing dialog/status surface. */
  getLayerPresetError(): string { return this.layerPresetStorageError; }

  /** 返回所有预设名 */
  listLayerPresets(): string[] {
    return this.layerPresets.map(p => p.name);
  }

  /** 按名称获取预设（主要用于调试/展示；返回值为副本） */
  getLayerPreset(name: string): LayerPreset | undefined {
    const preset = this.layerPresets.find(p => p.name === name);
    if (!preset) {
      return undefined;
    }
    return {
      name: preset.name,
      layerVisibilities: new Map<string, boolean>(preset.layerVisibilities),
    };
  }

  /**
   * 持久化预设到 PersistentStorage。
   * Map 无法直接 JSON 序列化（会变成空对象），故先转成 entries 数组。
   */
  private serializeLayerPresets(presets: LayerPreset[]): string {
    const serialized: LayerPresetSerialized[] = [];
    for (const preset of presets) {
      const entries: LayerVisibilityEntry[] = [];
      preset.layerVisibilities.forEach((visible: boolean, key: string) => {
        const parts: string[] = key.split(':');
        const entry: LayerVisibilityEntry = { layerNumber: Number(parts[0]), datatype: Number(parts[1] ?? 0), visible: visible };
        if (parts.length > 2 || !Number.isInteger(entry.layerNumber) || entry.layerNumber < 0 || entry.layerNumber > 32767 ||
          !Number.isInteger(entry.datatype ?? 0) || (entry.datatype ?? 0) < 0 || (entry.datatype ?? 0) > 32767 || typeof visible !== 'boolean') throw new Error('图层预设包含无效的 layer/datatype 或可见性');
        entries.push(entry);
      });
      const item: LayerPresetSerialized = { name: preset.name, entries };
      serialized.push(item);
    }
    return JSON.stringify(serialized);
  }

  private writeLayerPresetStorage(value: string): void {
    // SDK AppStorage.setOrCreate returns void; success is proved by exact
    // readback. Preserve an explicit false returned by a rejecting adapter,
    // while a legitimate void return is never treated as failure by truthiness.
    const write: (value: string) => boolean | void = (next: string): boolean | void =>
      AppStorage.setOrCreate<string>(ViewService.LAYER_PRESETS_KEY, next);
    const accepted: boolean | void = write(value);
    if (accepted === false) throw new Error('预设存储拒绝写入');
    if (AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY) !== value) throw new Error('预设存储回读不一致');
  }

  private restoreLayerPresetStorage(previous: string | undefined): boolean {
    try {
      if (AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY) === previous) return true;
      if (previous === undefined) {
        AppStorage.delete(ViewService.LAYER_PRESETS_KEY);
        return AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY) === undefined;
      }
      this.writeLayerPresetStorage(previous);
      return true;
    } catch (_) {
      // Even a throwing backend may have written the original value. Only an
      // actual readback can confirm that recovery completed.
      try { return AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY) === previous; }
      catch (_) { return false; }
    }
  }

  /** Publish memory only after the entire candidate string is accepted and
   * reread. On failure restore the prior storage without changing live presets. */
  private persistLayerPresets(candidate: LayerPreset[]): boolean {
    if (!this.layerPresetStorageReady) { this.layerPresetStorageError = '预设存储尚未正确载入，原内容已保留'; return false; }
    let previous: string | undefined = undefined;
    let attempted: boolean = false;
    try {
      const encoded: string = this.serializeLayerPresets(candidate);
      previous = AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY);
      if (previous !== this.layerPresetStorageBaseline) throw new Error('预设存储已由其他操作改变，请重新载入后保存');
      attempted = true;
      this.writeLayerPresetStorage(encoded);
      this.layerPresets = candidate;
      this.layerPresetStorageBaseline = encoded;
      this.layerPresetStorageError = '';
      return true;
    } catch (error) {
      const restored: boolean = !attempted || this.restoreLayerPresetStorage(previous);
      this.layerPresetStorageError = `图层预设未保存：${String(error)}；${restored ? '原内容已保留' : '存储回滚未完成，内存预设已保留'}`;
      console.error(`[ViewService] ${this.layerPresetStorageError}`);
      return false;
    }
  }

  /**
   * 从 PersistentStorage 加载预设。
   * 首次调用 persistProp 建立 AppStorage 键与持久化存储的绑定；
   * 之后通过 AppStorage.get 读取已持久化的 JSON 字符串并反序列化。
   */
  private loadLayerPresets(): void {
    try {
      PersistentStorage.persistProp(ViewService.LAYER_PRESETS_KEY, JSON.stringify([]));
      const stored: string | undefined = AppStorage.get<string>(ViewService.LAYER_PRESETS_KEY);
      const raw: string = stored ?? '[]';
      const arr: LayerPresetSerialized[] = JSON.parse(raw) as LayerPresetSerialized[];
      const presets: LayerPreset[] = [];
      for (const p of arr) {
        const m: Map<string, boolean> = new Map<string, boolean>();
        if (p && p.entries) {
          for (const e of p.entries) {
            m.set(`${e.layerNumber}:${e.datatype ?? 0}`, e.visible);
          }
        }
        const preset: LayerPreset = { name: p ? p.name : '', layerVisibilities: m };
        if (preset.name.length > 0) {
          presets.push(preset);
        }
      }
      this.layerPresets = presets;
      this.layerPresetStorageBaseline = stored;
      this.layerPresetStorageReady = true;
      this.layerPresetStorageError = '';
    } catch (e) {
      // 反序列化失败时回退到空预设列表，不影响其他功能
      this.layerPresets = [];
      this.layerPresetStorageReady = false;
      this.layerPresetStorageError = `图层预设读取失败：${String(e)}，原存储未改动`;
      console.error(`[ViewService] 加载图层预设失败: ${e}`);
    }
  }

  // ===== Cell 层级显示控制 =====

  /** 获取当前层级深度（默认 2） */
  getHierarchyDepth(): number {
    return this.hierarchyDepth;
  }

  /**
   * 设置层级深度（1-32 范围校验）。
   * 超出范围返回 false 且不改变状态；与当前值相同则直接返回 true 不触发回调。
   * 修改成功后通过 onHierarchyDepthChange 回调通知 LayoutCanvasView 重绘。
   */
  setHierarchyDepth(n: number): boolean {
    if (!Number.isInteger(n) || n < 1 || n > 32) {
      return false;
    }
    if (n === this.hierarchyDepth) {
      return true;
    }
    this.hierarchyDepth = n;
    if (this.onHierarchyDepthChange) {
      this.onHierarchyDepthChange(n);
    }
    return true;
  }

  /** 获取当前缩放百分比（与 LayoutCanvasView 的 zoomPercent 对齐，默认 100） */
  getViewZoomPercent(): number {
    return this.viewZoomPercent;
  }

  /** 同步当前缩放百分比（外部 zoom 变化时调用） */
  setViewZoomPercent(value: number): void {
    // VS-M6: 校验输入为正有限数，避免 NaN/Infinity/0 导致后续渲染除零
    if (!Number.isFinite(value) || value <= 0) {
      return;
    }
    this.viewZoomPercent = value;
  }

  /** 相机偏移：pixelX=(worldX+offsetX)*z；pixelY=(offsetY-worldY)*z。 */
  getViewOffset(): ViewOffset {
    const offset: ViewOffset = { offsetX: this.viewOffsetX, offsetY: this.viewOffsetY };
    return offset;
  }

  /** 同步当前偏移（外部 pan 变化时调用） */
  setViewOffset(offsetX: number, offsetY: number): void {
    // VS-M6: 校验输入为有限数，避免 NaN/Infinity 污染视图状态
    if (!Number.isFinite(offsetX) || !Number.isFinite(offsetY)) {
      return;
    }
    this.viewOffsetX = offsetX;
    this.viewOffsetY = offsetY;
  }

  /**
   * 重置视图：
   * - hierarchyDepth = 2（默认）
   * - 缩放 = 默认（100%）
   * - offset = 居中基准（0,0，画布可在此基础上做自适应居中）
   * 重置后依次触发 onHierarchyDepthChange 与 onViewReset 回调，
   * 供 LayoutCanvasView 据此重绘并居中。
   */
  resetView(): void {
    this.hierarchyDepth = ViewService.DEFAULT_HIERARCHY_DEPTH;
    this.viewZoomPercent = ViewService.DEFAULT_ZOOM_PERCENT;
    this.viewOffsetX = ViewService.DEFAULT_OFFSET_X;
    this.viewOffsetY = ViewService.DEFAULT_OFFSET_Y;
    if (this.onHierarchyDepthChange) {
      this.onHierarchyDepthChange(this.hierarchyDepth);
    }
    if (this.onViewReset) {
      this.onViewReset();
    }
  }
}

/** 视图服务单例 */
export const viewService = new ViewService();
