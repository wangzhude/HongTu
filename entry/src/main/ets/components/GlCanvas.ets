/**
   * 鸿图 OpenGL ES 画布组件
   *
   * 通过 XComponent 接入 C++ 层的 OpenGL ES 渲染器，
   * 实现高性能版图渲染（Camera-Relative 双精度原点 VBO 批量绘制 + 着色器）。
   *
   * 渲染策略（Phase C）：
   * - useGL = true + GL 可用：展开后的版图几何由 GPU 主路径绘制
   * - useGL = true + GL 不可用 / 连续失败：降级 FALLBACK，由外层 ShapeNode 绘制
   * - useGL = false：不渲染
   *
   * 相机与 LayoutCanvasView ShapeNode 对齐：
   *   pixelX = (worldX + viewOffsetX) * z；pixelY = (viewOffsetY - worldY) * z
   *   ndc_x = 2*pixel/width - 1
   *   ndc_y = 1 - 2*pixel/height   (OpenGL Y 向上，ArkUI Y 向下)
   *
   * This file is part of HongTu, licensed under GPLv3.
   */

import hongtu from 'libhongtu.so';
import type { HongTuNative, RenderBatch, RenderStats, GLPrimitiveType, NativeLayerRenderStyle, NativeRenderSnapshot } from '../../cpp/types/libhongtu/Index';
import { Shape, ShapeType, Point, ShapeBounds, getShapeBounds } from '../models/GdsiiData';
import { UiLayer } from '../common/types';
import { fillPatternForHatch, GL_STYLE_LIMITS, LayerRenderStyle, layerRenderStyle, RADIUS } from '../common/MaterialTokens';
import { nativeHongTuService } from '../services/NativeHongTuService';
import { worldViewportFromCamera, WorldViewport } from '../services/HierarchyExpandService';
import type { ViewSceneSource, ViewScenePrimitive, ViewSceneDrawResult } from '../models/ViewRenderScene';
import { ViewRenderSceneService, sceneViewportFromCamera } from '../services/ViewRenderSceneService';
import { SCENE_TEXT_FONT_SIZE } from '../models/ViewRenderScene';
import { FONT_MONO } from '../common/Fonts';

/** GL 渲染模式 */
export enum RenderMode {
  /** 使用 XComponent + OpenGL ES */
  GL = 'gl',
  /** 降级到 ArkUI 基础图形 */
  FALLBACK = 'fallback',
}

@Component
export struct GlCanvas {
  @Prop @Watch('onDataChange') shapes: Shape[] = [];
  @Prop @Watch('onLayersPropChange') layers: UiLayer[] = [];
  private lastLayerStyleSignature: string = '';
  @Prop @Watch('onCameraChange') zoomScale: number = 100;
  @Prop @Watch('onCameraChange') offsetX: number = 0;
  @Prop @Watch('onCameraChange') offsetY: number = 0;
  @Prop @Watch('onCameraChange') canvasWidth: number = 800;
  @Prop @Watch('onCameraChange') canvasHeight: number = 600;
  @Prop useGL: boolean = true;
  @Prop @Watch('onBackgroundChange') lightBackground: boolean = false;
  /** 开发调试时可显式打开，工作界面默认不显示渲染实现统计。 */
  @Prop showRenderStats: boolean = false;
  /** 当前浏览 Cell（用于 native expandHierarchyToBatches） */
  @Prop @Watch('onDataChange') currentCellId: number = 0;
  /** 层级深度（KLayout 语义） */
  @Prop @Watch('onDataChange') hierarchyDepth: number = 2;
  /** true：优先 native 展开批次；false/失败：用 props.shapes（ArkTS 已展开） */
  @Prop @Watch('onDataChange') preferNativeExpand: boolean = true;
  /** Fetch stored definitions only when drawing; @Prop would deep-copy the whole library. */
  renderSnapshotProvider: () => NativeRenderSnapshot | null = () => null;
  /** 当 GL 主路径可用/降级时通知父组件，用于切换 ShapeNode 全量/叠加模式 */
  onGlActiveChange: (active: boolean) => void = (_active: boolean) => {};
  /** Compute the hierarchy only if native expansion fails, avoiding a duplicate clean traversal. */
  fallbackShapesProvider: () => Shape[] = () => [];
  fallbackOverflowProvider: () => boolean = () => false;
  /** Borrow all databases through a provider; never deep-copy them into props. */
  renderSceneProvider: (() => ViewSceneSource[]) | null = null;
  @Prop @Watch('onDataChange') sceneRevision: number = 0;
  private sceneService: ViewRenderSceneService = new ViewRenderSceneService((text: string): number => this.measureSceneText(text));

  @State renderMode: RenderMode = RenderMode.FALLBACK;
  @State renderStats: RenderStats = { primitives: 0, vertices: 0, frameTimeMs: 0 };
  /** 渲染错误信息（非空时在画布右上角提示用户，避免静默失败） */
  @State renderError: string = '';
  @State sceneStyleLimited: boolean = false;
  /** 连续渲染失败计数：超过阈值则降级到 FALLBACK，避免反复抛错 */
  private failureCount: number = 0;
  @State capacityFallbackActive: boolean = false;
  /** 标记当前降级仅因原生 Surface 尚未完成异步创建或刚经历销毁重建，以便就绪后自动恢复 */
  private surfacePendingRecovery: boolean = false;
  private surfaceAlive: boolean = false;
  private disappearing: boolean = false;

  /** 已上传 VBO 的视口扩边缓存与 Camera-Relative 参考原点状态（解耦纯平移缩放与全量几何重传） */
  private geometryCacheValid: boolean = false;
  private dataDirty: boolean = true;
  private cachedUnculledFullScene: boolean = false;
  private cachedViewportMinX: number = 0;
  private cachedViewportMinY: number = 0;
  private cachedViewportMaxX: number = 0;
  private cachedViewportMaxY: number = 0;
  private cachedOriginX: number = 0;
  private cachedOriginY: number = 0;
  private cachedZoomScale: number = 100;
  private cachedSingleCleanMain: boolean = false;

  private nativeModule: HongTuNative = hongtu;
  private xcomponentId: string = 'hongtu-gl-canvas';
  private dataRefreshTimer: number = -1;
  private surfaceRecoveryTimer: number = -1;
  private surfaceRecoveryAttempts: number = 0;
  private statsTimer: number = -1;

  private setRenderMode(mode: RenderMode): void {
    if (this.renderMode === mode) {
      return;
    }
    this.renderMode = mode;
    this.onGlActiveChange(mode === RenderMode.GL && !this.capacityFallbackActive);
  }

  aboutToAppear() {
    this.disappearing = false;
    if (!this.useGL) {
      this.setRenderMode(RenderMode.FALLBACK);
      return;
    }
    this.lastLayerStyleSignature = this.computeLayerStyleSignature(this.layers);
    this.initNativeGL();
  }

  /**
   * G-2: 组件销毁前清理 GL 资源。
   */
  aboutToDisappear() {
    this.disappearing = true;
    this.cancelPendingTimers();
    this.geometryCacheValid = false;
    this.surfaceAlive = false;
    if (this.renderSceneProvider) {
      this.sceneService.clear();
      try { this.clearSceneSurface(); }
      catch (e) { console.error('[GlCanvas] 场景销毁清理失败:', e); }
      this.setRenderMode(RenderMode.FALLBACK);
      return;
    }
    if (this.renderMode !== RenderMode.GL) {
      return;
    }
    try {
      this.nativeModule.setRenderData([]);
      this.nativeModule.requestRedraw();
    } catch (e) {
      console.error('[GlCanvas] aboutToDisappear 清理 GL 资源失败:', e);
    }
    this.setRenderMode(RenderMode.FALLBACK);
  }

  private cancelPendingTimers(): void {
    if (this.dataRefreshTimer !== -1) {
      clearTimeout(this.dataRefreshTimer);
      this.dataRefreshTimer = -1;
    }
    if (this.surfaceRecoveryTimer !== -1) {
      clearTimeout(this.surfaceRecoveryTimer);
      this.surfaceRecoveryTimer = -1;
    }
    if (this.statsTimer !== -1) {
      clearTimeout(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  private initNativeGL() {
    try {
      const v: string = this.nativeModule.version();
      if (v && v.length > 0) {
        this.updateGLBackground();
        this.setRenderMode(RenderMode.GL);
      } else {
        this.setRenderMode(RenderMode.FALLBACK);
      }
    } catch (e) {
      console.error('[GlCanvas] initNativeGL 失败,降级 FALLBACK:', e);
      this.setRenderMode(RenderMode.FALLBACK);
    }
  }

  private computeLayerStyleSignature(items: UiLayer[]): string {
    const parts: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const l: UiLayer = items[i];
      parts.push(`${l.layerNumber}:${l.datatype}:${l.visible !== false ? 1 : 0}:${l.color}:${l.transparency ?? ''}:${l.fillStyle ?? ''}:${l.lineStyle ?? ''}:${l.lineWidth ?? ''}:${l.highlighted ? 1 : 0}:${l.animated ? 1 : 0}`);
    }
    return parts.join('|');
  }

  onLayersPropChange(): void {
    const sig: string = this.computeLayerStyleSignature(this.layers);
    if (sig === this.lastLayerStyleSignature) {
      return;
    }
    this.lastLayerStyleSignature = sig;
    this.onDataChange();
  }

  /** @Watch 回调：图形/图层/Cell/深度/场景版本变化时标记几何失效并同帧合并上传（非饥饿调度） */
  onDataChange(): void {
    this.geometryCacheValid = false;
    this.dataDirty = true;
    if (this.renderMode !== RenderMode.GL) return;
    this.scheduleDataFlush();
  }

  /** 非重置式微批合并：同一事件循环内的多 @Prop 更新合并为一次上传，且连续交互绝不饥饿 */
  private scheduleDataFlush(): void {
    if (this.dataRefreshTimer !== -1) {
      return;
    }
    this.dataRefreshTimer = setTimeout(() => {
      this.dataRefreshTimer = -1;
      this.flushDataChange();
    }, 0);
  }

  private flushDataChange(): void {
    if (this.renderMode !== RenderMode.GL || this.disappearing) {
      return;
    }
    try {
      this.updateGLCamera();
      this.updateGLRenderData();
      this.failureCount = 0;
    } catch (e) {
      this.geometryCacheValid = false;
      if (this.renderSceneProvider) {
        this.sceneService.clear();
        this.clearSceneSurface();
        if (!this.capacityFallbackActive) this.onGlActiveChange(false);
        this.capacityFallbackActive = true;
        this.surfacePendingRecovery = false;
      }
      this.failureCount++;
      this.renderError = `GL 渲染数据更新失败（第 ${this.failureCount} 次）：${e}`;
      console.error('[GlCanvas] onDataChange 更新渲染数据失败:', e);
      if (this.failureCount >= 3) {
        this.setRenderMode(RenderMode.FALLBACK);
        this.renderError = `GL 渲染连续失败 ${this.failureCount} 次，已降级到内置渲染`;
      }
    }
  }

  /**
   * 判定当前可见视口是否完全落在已缓存 VBO 视口扩边范围内，且局部 float 坐标保持亚像素精度。
   * 满足条件时平移/缩放/分屏拖拽仅需实时更新相机 MVP 矩阵，零主线程几何重算与零 glBufferData。
   */
  private canReuseCachedGeometry(): boolean {
    if (!this.geometryCacheValid || this.dataDirty || this.capacityFallbackActive || !this.surfaceAlive) {
      return false;
    }
    const w: number = Math.max(1, this.canvasWidth);
    const h: number = Math.max(1, this.canvasHeight);
    if (!(this.zoomScale > 0) || !Number.isFinite(this.zoomScale) ||
        !Number.isFinite(this.offsetX) || !Number.isFinite(this.offsetY)) {
      return false;
    }
    let visVp: WorldViewport;
    try {
      visVp = this.renderSceneProvider
        ? sceneViewportFromCamera(w, h, this.zoomScale, this.offsetX, this.offsetY, 96)
        : worldViewportFromCamera(w, h, this.zoomScale, this.offsetX, this.offsetY, 96);
    } catch (_) {
      return false;
    }
    if (!this.cachedUnculledFullScene) {
      if (visVp.minX < this.cachedViewportMinX || visVp.maxX > this.cachedViewportMaxX ||
          visVp.minY < this.cachedViewportMinY || visVp.maxY > this.cachedViewportMaxY) {
        return false;
      }
    }
    // 多源场景在大幅缩小时屏幕字号文本包围盒在世界域会放大；单源 C++ 直通路径无该膨胀，放宽复用窗口至扩边视口边界
    if (this.renderSceneProvider !== null && !this.cachedSingleCleanMain && this.zoomScale < this.cachedZoomScale * 0.5) {
      return false;
    }
    // 鸟瞰态子像素代理矩形在放大超过 2.4 倍后触发增量补精，确保曲线波导/光栅边缘恢复完整矢量细节
    if (this.cachedZoomScale < 25 && this.zoomScale > this.cachedZoomScale * 2.4) {
      return false;
    }
    // 亚像素精度守卫：确保已上传 VBO 的局部原点在当前缩放率下最大 FP32 量化误差 <= 0.015 vp
    const z: number = Math.max(0.0001, this.zoomScale / 100);
    const maxDistNm: number = Math.max(
      Math.abs(visVp.minX - this.cachedOriginX),
      Math.abs(visVp.maxX - this.cachedOriginX),
      Math.abs(visVp.minY - this.cachedOriginY),
      Math.abs(visVp.maxY - this.cachedOriginY)
    );
    if (!Number.isFinite(maxDistNm) || maxDistNm * z > 262144) {
      return false;
    }
    return true;
  }

  /**
   * @Watch 回调：取消 16ms 重置式 setTimeout 防抖，实时下发 setCamera 跟手渲染；
   * 仅当平移/缩放越出已缓存扩边视口或需重锚定局部原点时，才触发非饥饿几何刷新。
   */
  onCameraChange(): void {
    if (this.renderMode !== RenderMode.GL || this.disappearing) {
      return;
    }
    try {
      this.updateGLCamera();
    } catch (e) {
      console.error('[GlCanvas] 实时更新相机失败:', e);
    }
    if (this.canReuseCachedGeometry()) {
      return;
    }
    this.scheduleDataFlush();
  }

  onBackgroundChange(): void {
    if (this.renderMode !== RenderMode.GL) {
      return;
    }
    try {
      this.updateGLBackground();
      if (this.renderSceneProvider) this.onDataChange();
    } catch (e) {
      console.error('[GlCanvas] 更新画布背景失败，降级到内置渲染:', e);
      this.setRenderMode(RenderMode.FALLBACK);
    }
  }

  build() {
    Stack() {
      if (this.useGL && this.renderMode === RenderMode.GL) {
        XComponent({ id: this.xcomponentId, type: XComponentType.SURFACE, libraryname: 'hongtu' })
          .width('100%')
          .height('100%')
          .opacity(this.capacityFallbackActive ? 0 : 1)
          .backgroundColor(this.lightBackground ? '#FFFFFF' : '#070A10')
          .onLoad((context?: object) => {
            this.onXComponentLoad(context);
          })
          .onDestroy(() => {
            this.onSceneSurfaceDestroy();
          })

        if (this.showRenderStats) {
          Row() {
            Text(`GL: ${this.renderStats.primitives} 图元 / ${this.renderStats.vertices} 顶点 / CPU提交 ${this.renderStats.frameTimeMs.toFixed(1)}ms`)
              .fontSize(9)
              .fontColor(this.lightBackground ? '#21823B' : 'rgba(0,255,100,0.6)')
              .fontFamily('monospace')
          }
          .position({ x: 8, y: 8 })
          .hitTestBehavior(HitTestMode.None)
        }

        if (this.hasUnrenderableStyle()) {
          Text(this.renderSceneProvider ? '场景动画采用静态显示' : GL_STYLE_LIMITS)
            .fontSize(9)
            .fontColor(this.lightBackground ? '#956500' : 'rgba(255,196,0,0.75)')
            .fontFamily('monospace')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .position({ x: 8, y: 46 })
            .hitTestBehavior(HitTestMode.None)
        }

      }
      if (this.renderError.length > 0) {
          Text(this.renderError)
            .fontSize(11)
            .fontColor(this.lightBackground ? '#B42318' : '#FF8A80')
            .backgroundColor(this.lightBackground ? 'rgba(254, 243, 242, 0.95)' : 'rgba(40, 12, 14, 0.88)')
            .border({ width: 1, color: this.lightBackground ? 'rgba(217, 45, 32, 0.28)' : 'rgba(255, 107, 107, 0.32)' })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(RADIUS.sm)
            .constraintSize({ maxWidth: '72%' })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .position({ x: 76, y: 56 })
            .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.lightBackground ? '#FFFFFF' : '#070A10')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = Math.round(newArea.width as number);
      const h: number = Math.round(newArea.height as number);
      if (w > 0 && h > 0 && this.renderMode === RenderMode.GL && !this.disappearing) {
        if (this.surfacePendingRecovery) {
          this.tryRecoverSurfaceScene();
        }
      }
    })
  }

  /** XComponent 加载完成：注册回调并初始化相机与渲染数据（含 Surface 异步就绪自愈） */
  private onXComponentLoad(context?: object) {
    try {
      this.failureCount = 0;
      this.surfaceAlive = true;
      this.geometryCacheValid = false;
      this.dataDirty = true;
      this.updateGLBackground();
      this.nativeModule.registerXComponent(context);
      this.setRenderMode(RenderMode.GL);
      this.updateGLCamera();
      this.updateGLRenderData();
      const stats: RenderStats = this.nativeModule.getRenderStats();
      console.info('[GlCanvas] native surface ready: ' + JSON.stringify(stats));
      if (stats.ready !== true) {
        this.scheduleSurfaceRecovery();
      }
    } catch (e) {
      console.error('[GlCanvas] onXComponentLoad 注册/初始化失败,降级 FALLBACK:', e);
      this.setRenderMode(RenderMode.FALLBACK);
    }
  }

  /** 当 XComponent.onLoad 早于原生 OnSurfaceCreated 或经历窗口重建时，轮询等待 EGL 就绪后自动恢复场景 */
  private scheduleSurfaceRecovery(): void {
    this.surfacePendingRecovery = true;
    if (this.surfaceRecoveryTimer !== -1 || this.disappearing) {
      return;
    }
    this.surfaceRecoveryAttempts = 0;
    const poll = () => {
      this.surfaceRecoveryTimer = -1;
      if (this.disappearing || !this.useGL || this.renderMode !== RenderMode.GL) {
        return;
      }
      if (this.tryRecoverSurfaceScene()) {
        return;
      }
      this.surfaceRecoveryAttempts++;
      if (this.surfaceRecoveryAttempts < 30) {
        this.surfaceRecoveryTimer = setTimeout(poll, 16);
      }
    };
    this.surfaceRecoveryTimer = setTimeout(poll, 16);
  }

  private tryRecoverSurfaceScene(): boolean {
    try {
      const stats: RenderStats = this.nativeModule.getRenderStats();
      if (stats.ready === true) {
        this.surfaceAlive = true;
        this.surfacePendingRecovery = false;
        this.geometryCacheValid = false;
        this.dataDirty = true;
        this.flushDataChange();
        return true;
      }
    } catch (_) {
      // Ignore transient query errors while surface is still initializing
    }
    return false;
  }

  private updateGLBackground(): void {
    if (this.lightBackground) {
      this.nativeModule.setBackgroundColor(1, 1, 1, 1);
    } else {
      this.nativeModule.setBackgroundColor(0.027, 0.039, 0.063, 1);
    }
  }

  /**
   * 实时更新 GL 相机（IEEE-754 double 直传 C++ NapiSetCamera，零 setTimeout 延迟）。
   */
  private updateGLCamera() {
    const w: number = Math.max(1, this.canvasWidth);
    const h: number = Math.max(1, this.canvasHeight);
    const z: number = this.zoomScale / 100;
    const scaleX: number = 2 * z / w;
    const scaleY: number = 2 * z / h;
    const offsetX: number = 2 * z * this.offsetX / w - 1;
    const offsetY: number = 1 - 2 * z * this.offsetY / h;
    this.nativeModule.setCamera(scaleX, scaleY, offsetX, offsetY, w, h);
    if (!this.renderSceneProvider || (this.geometryCacheValid && !this.capacityFallbackActive)) {
      this.nativeModule.requestRedraw();
    }
  }

  private recordCachedViewport(vp: WorldViewport, unculledFull: boolean,
                               originX?: number, originY?: number): void {
    this.cachedViewportMinX = vp.minX;
    this.cachedViewportMinY = vp.minY;
    this.cachedViewportMaxX = vp.maxX;
    this.cachedViewportMaxY = vp.maxY;
    this.cachedOriginX = originX !== undefined ? originX : (0.5 * vp.minX + 0.5 * vp.maxX);
    this.cachedOriginY = originY !== undefined ? originY : (0.5 * vp.minY + 0.5 * vp.maxY);
    this.cachedZoomScale = this.zoomScale;
    this.cachedUnculledFullScene = unculledFull;
    this.geometryCacheValid = true;
    this.dataDirty = false;
    this.surfacePendingRecovery = false;
  }

  private computeOverscanMarginPx(): number {
    return Math.max(256, Math.round(Math.max(this.canvasWidth, this.canvasHeight) * 0.75));
  }

  /** 更新 GL 渲染数据：优先扩边视口 native 直通表面，平移/缩放时复用 VBO */
  private updateGLRenderData() {
    if (this.renderSceneProvider) {
      this.updateGLScene();
      return;
    }
    let batches: RenderBatch[] = [];
    let nativeSucceeded: boolean = false;
    const renderSnapshot: NativeRenderSnapshot | null = this.renderSnapshotProvider();
    const useNative: boolean = this.preferNativeExpand || renderSnapshot !== null;
    const tightVp: WorldViewport = worldViewportFromCamera(
      this.canvasWidth,
      this.canvasHeight,
      this.zoomScale,
      this.offsetX,
      this.offsetY,
      96
    );
    const overscanVp: WorldViewport = worldViewportFromCamera(
      this.canvasWidth,
      this.canvasHeight,
      this.zoomScale,
      this.offsetX,
      this.offsetY,
      this.computeOverscanMarginPx()
    );

    if (useNative) {
      const styles: NativeLayerRenderStyle[] = this.nativeLayerStyles();
      let direct: boolean | null = nativeHongTuService.renderHierarchyToSurface(
        this.currentCellId, this.hierarchyDepth,
        overscanVp.minX, overscanVp.minY, overscanVp.maxX, overscanVp.maxY,
        styles, renderSnapshot ?? undefined);
      let appliedVp: WorldViewport = overscanVp;
      if (direct !== true) {
        direct = nativeHongTuService.renderHierarchyToSurface(
          this.currentCellId, this.hierarchyDepth,
          tightVp.minX, tightVp.minY, tightVp.maxX, tightVp.maxY,
          styles, renderSnapshot ?? undefined);
        appliedVp = tightVp;
      }
      if (direct === true) {
        this.surfaceAlive = true;
        this.recordCachedViewport(appliedVp, false);
        this.restoreCompleteGlFrame();
        this.refreshRenderStats();
        return;
      }
      if (direct === false) {
        const stats: RenderStats = this.nativeModule.getRenderStats();
        if (stats.ready !== true) {
          this.scheduleSurfaceRecovery();
        }
      }
      const nativeBatches: RenderBatch[] | null = renderSnapshot !== null ? null : nativeHongTuService.expandHierarchyToBatches(
        this.currentCellId,
        this.hierarchyDepth,
        tightVp.minX,
        tightVp.minY,
        tightVp.maxX,
        tightVp.maxY
      );
      if (nativeBatches !== null) {
        nativeSucceeded = true;
        batches = this.recolorBatches(nativeBatches);
      }
    }
    let usedVp: WorldViewport = tightVp;
    if (!nativeSucceeded) {
      const fallback: Shape[] = useNative ? this.fallbackShapesProvider() : this.shapes;
      if (useNative && this.fallbackOverflowProvider()) {
        this.nativeModule.setRenderData([]);
        this.nativeModule.requestRedraw();
        if (this.statsTimer !== -1) clearTimeout(this.statsTimer);
        this.statsTimer = -1;
        this.geometryCacheValid = false;
        this.renderError = '当前视口无法完整绘制，请放大局部或降低层级';
        if (!this.capacityFallbackActive) this.onGlActiveChange(false);
        this.capacityFallbackActive = true;
        return;
      }
      usedVp = useNative ? tightVp : overscanVp;
      batches = this.shapesToBatches(fallback, useNative ? undefined : overscanVp);
    }
    this.nativeModule.setRenderData(batches);
    this.nativeModule.requestRedraw();
    this.surfaceAlive = true;
    this.recordCachedViewport(usedVp, false);
    this.restoreCompleteGlFrame();
    this.refreshRenderStats();
  }

  private clearSceneSurface(): void {
    this.geometryCacheValid = false;
    if (this.nativeModule.clearRenderScene !== undefined) this.nativeModule.clearRenderScene();
    else {
      this.nativeModule.setRenderData([]);
      this.nativeModule.requestRedraw();
    }
    if (this.statsTimer !== -1) clearTimeout(this.statsTimer);
    this.statsTimer = -1;
  }

  private measureSceneText(text: string): number {
    const context = this.getUIContext();
    const widthPx: number = context.getMeasureUtils().measureText({ textContent: text,
      fontSize: `${SCENE_TEXT_FONT_SIZE}vp`, fontFamily: FONT_MONO, fontWeight: FontWeight.Medium });
    return context.px2vp(widthPx);
  }

  /**
   * 多源场景 Surface 销毁处理：释放旧 GPU/缓存资源并标记 surfacePendingRecovery，
   * 当 XComponent 重建完成或原生 OnSurfaceCreated 重新就绪时自动恢复完整 GL 场景，消除黑屏。
   */
  private onSceneSurfaceDestroy(): void {
    this.surfaceAlive = false;
    this.geometryCacheValid = false;
    this.dataDirty = true;
    if (this.dataRefreshTimer !== -1) {
      clearTimeout(this.dataRefreshTimer);
      this.dataRefreshTimer = -1;
    }
    if (!this.renderSceneProvider) {
      if (!this.disappearing) {
        this.surfacePendingRecovery = true;
      }
      return;
    }
    this.sceneService.clear();
    try { this.clearSceneSurface(); }
    catch (e) { this.renderError = `场景表面销毁清理失败：${e}`; }
    if (!this.capacityFallbackActive) this.onGlActiveChange(false);
    this.capacityFallbackActive = true;
    if (!this.disappearing) {
      this.scheduleSurfaceRecovery();
    }
  }

  /** 多源复合场景上传：优先扩边视口提交并在 Surface 尚未就绪时挂起自愈恢复 */
  private updateGLScene(): void {
    if (!this.renderSceneProvider) return;
    try {
      const sources: ViewSceneSource[] = this.renderSceneProvider();
      const tightVp: WorldViewport = sceneViewportFromCamera(this.canvasWidth, this.canvasHeight,
        this.zoomScale, this.offsetX, this.offsetY, 96);
      const overscanVp: WorldViewport = sceneViewportFromCamera(this.canvasWidth, this.canvasHeight,
        this.zoomScale, this.offsetX, this.offsetY, this.computeOverscanMarginPx());

      // 单活动文档未编辑直通快路径：直接复用 C++ g_layout 零拷贝提交，免除 ReadonlySceneCache 双份 Layout 内存（省 ~110MB）
      const hasVisibleDashLayer: boolean = sources.length === 1 &&
        sources[0].layers.some((l: UiLayer): boolean => l.visible !== false && layerRenderStyle(l).dashArray.length > 0);
      const singleCleanMain: boolean =
        sources.length === 1 &&
        !sources[0].readOnly &&
        this.preferNativeExpand &&
        sources[0].opacity === 1 &&
        sources[0].transform.a === 1 &&
        sources[0].transform.b === 0 &&
        sources[0].transform.c === 0 &&
        sources[0].transform.d === 1 &&
        sources[0].transform.tx === 0 &&
        sources[0].transform.ty === 0 &&
        (!hasVisibleDashLayer || sources[0].shapes.length > 2000);
      if (singleCleanMain) {
        const s0: ViewSceneSource = sources[0];
        this.sceneStyleLimited = hasVisibleDashLayer || s0.layers.some((l: UiLayer): boolean => l.visible && l.animated === true);
        if (this.nativeModule.clearRenderScene !== undefined && this.sceneService !== undefined) {
          this.sceneService.clear();
        }
        const styles: NativeLayerRenderStyle[] = this.nativeLayerStyles();
        let direct: boolean | null = nativeHongTuService.renderHierarchyToSurface(
          s0.cellId, s0.depth, overscanVp.minX, overscanVp.minY, overscanVp.maxX, overscanVp.maxY, styles);
        let usedVp: WorldViewport = overscanVp;
        if (direct !== true) {
          direct = nativeHongTuService.renderHierarchyToSurface(
            s0.cellId, s0.depth, tightVp.minX, tightVp.minY, tightVp.maxX, tightVp.maxY, styles);
          usedVp = tightVp;
        }
        if (direct === true) {
          this.surfaceAlive = true;
          this.cachedSingleCleanMain = true;
          this.recordCachedViewport(usedVp, false);
          this.restoreCompleteGlFrame();
          this.refreshRenderStats();
          return;
        }
      }

      this.cachedSingleCleanMain = false;
      const nativeSources = this.sceneService.nativeSources(sources);
      this.sceneStyleLimited = sources.some((source: ViewSceneSource): boolean => source.opacity > 0 &&
        source.layers.some((l: UiLayer): boolean => l.visible &&
          l.animated === true));
      const potentialStyledGeometry: boolean = sources.some((source: ViewSceneSource): boolean => source.opacity > 0 &&
        source.layers.some((l: UiLayer): boolean => l.visible !== false &&
          layerRenderStyle(l).dashArray.length > 0));
      const styledScene: ViewSceneDrawResult | undefined = potentialStyledGeometry
        ? this.sceneService.draw(sources, tightVp, 2000, this.zoomScale) : undefined;
      // 仅当视口图元在 ArkUI 2000 节点容量内且确实存在虚线描边时才走 ArkUI 样式叠层；超出容量时优先保住 OpenGL 完整几何
      const needsStyledArkUi: boolean = styledScene !== undefined && !styledScene.overflow &&
        styledScene.primitives.some((p: ViewScenePrimitive): boolean => p.kind !== 'text' && p.hierarchyFrame !== true &&
          p.opacity > 0 && p.style.dashArray.length > 0 && p.style.strokeOpacity > 0);
      const needsArkUiTight: boolean = needsStyledArkUi || this.sceneService.requiresArkUi(sources, tightVp, this.zoomScale);

      let nativeError: string = '';
      let rendered: boolean = false;
      let appliedVp: WorldViewport = tightVp;

      if (!needsArkUiTight) {
        const canTryOverscan: boolean = !potentialStyledGeometry &&
          !this.sceneService.requiresArkUi(sources, overscanVp, this.zoomScale);
        if (canTryOverscan) {
          try {
            rendered = this.nativeModule.renderSceneToSurface(
              nativeSources, overscanVp.minX, overscanVp.minY, overscanVp.maxX, overscanVp.maxY);
            if (rendered) {
              appliedVp = overscanVp;
            }
          } catch (_) {
            rendered = false;
          }
        }
        if (!rendered) {
          try {
            rendered = this.nativeModule.renderSceneToSurface(
              nativeSources, tightVp.minX, tightVp.minY, tightVp.maxX, tightVp.maxY);
            appliedVp = tightVp;
          } catch (e) {
            nativeError = `原生场景提交失败：${e}`;
          }
        }
      }

      if (rendered && !needsArkUiTight) {
        this.surfaceAlive = true;
        this.recordCachedViewport(appliedVp, false);
        this.restoreCompleteGlFrame();
        this.refreshRenderStats();
        return;
      }

      const stats: RenderStats = this.nativeModule.getRenderStats();
      const surfaceNotReady: boolean = !needsArkUiTight && nativeError.length === 0 && stats.ready !== true;

      // 当原生 XComponent Surface 正在异步初始化（首帧约 2~16ms）且版图超过 2000 图元时，
      // 严禁回退执行主线程 50 万节点 JS 遍历或闪出“超过 2000 图元预算”报错，直接等待下一帧 EGL 就绪自愈！
      let totalSourceShapes: number = 0;
      for (let i = 0; i < sources.length; i++) {
        totalSourceShapes += sources[i].shapes.length;
      }
      if (surfaceNotReady && totalSourceShapes > 2000 && this.surfaceRecoveryAttempts < 30 && !this.disappearing) {
        this.renderError = '';
        this.scheduleSurfaceRecovery();
        return;
      }

      this.clearSceneSurface();
      const fallback = styledScene ?? this.sceneService.draw(sources, tightVp, 2000, this.zoomScale);
      this.renderError = fallback.overflow ? fallback.message : (nativeError.length > 0 ? nativeError :
        (needsArkUiTight || surfaceNotReady ? '' : '原生场景不可用，使用内置绘制'));
      if (!this.capacityFallbackActive) this.onGlActiveChange(false);
      this.capacityFallbackActive = true;

      if (surfaceNotReady && !this.disappearing) {
        this.scheduleSurfaceRecovery();
      }
    } catch (e) {
      this.sceneService.clear();
      this.clearSceneSurface();
      this.renderError = `当前来源无法完整绘制：${e}`;
      this.sceneStyleLimited = false;
      if (!this.capacityFallbackActive) this.onGlActiveChange(false);
      this.capacityFallbackActive = true;
    }
  }

  private restoreCompleteGlFrame(): void {
    this.renderError = '';
    this.surfacePendingRecovery = false;
    if (this.capacityFallbackActive) {
      this.capacityFallbackActive = false;
      this.onGlActiveChange(true);
    }
  }

  private refreshRenderStats(): void {
    try {
      const stats: RenderStats = this.nativeModule.getRenderStats();
      this.renderStats = {
        primitives: stats.primitives,
        vertices: stats.vertices,
        frameTimeMs: stats.frameTimeMs,
      };
    } catch (e) {
      console.error('[GlCanvas] 获取渲染统计失败:', e);
    }
    if (this.statsTimer !== -1) clearTimeout(this.statsTimer);
    this.statsTimer = setTimeout(() => {
      this.statsTimer = -1;
      if (this.renderMode !== RenderMode.GL) return;
      const stats: RenderStats = this.nativeModule.getRenderStats();
      console.info('[HongTuRenderStats] ' + JSON.stringify(stats)
        + ` cell=${this.currentCellId} depth=${this.hierarchyDepth} zoom=${this.zoomScale}`);
    }, 200);
  }

  private nativeLayerStyles(): NativeLayerRenderStyle[] {
    const styles: NativeLayerRenderStyle[] = [];
    for (const layer of this.layers) {
      const style: LayerRenderStyle = layerRenderStyle(layer);
      const fillPattern: number = fillPatternForHatch(style.hatch);
      const glStrokeOnly: boolean = style.strokeOnly && fillPattern === 0;
      styles.push({
        layerNumber: layer.layerNumber,
        datatype: layer.datatype,
        visible: layer.visible,
        color: this.colorToRgba(layer.color, false, style, fillPattern),
        strokeOnly: glStrokeOnly,
        fillPattern: fillPattern,
      });
    }
    return styles;
  }

  private recolorBatches(batches: RenderBatch[]): RenderBatch[] {
    const out: RenderBatch[] = [];
    for (let i = 0; i < batches.length; i++) {
      const b: RenderBatch = batches[i];
      if (!this.isLayerVisible(b.layerNumber, b.datatype)) {
        continue;
      }
      const hex: string = this.layerColor(b.layerNumber, b.datatype);
      const style: LayerRenderStyle = this.styleForLayer(b.layerNumber, b.datatype);
      const fillPattern: number = fillPatternForHatch(style.hatch);
      const colored: RenderBatch = {
        type: this.applyFillStyle(b.type, style, fillPattern),
        layerNumber: b.layerNumber,
        datatype: b.datatype,
        vertices: b.vertices,
        color: this.colorToRgba(hex, b.selected, style, fillPattern),
        selected: b.selected,
        fillPattern: fillPattern,
      };
      out.push(colored);
    }
    return out;
  }

  private shapeIntersectsViewport(shape: Shape, vp: WorldViewport): boolean {
    if (shape.points.length === 0) return false;
    const b: ShapeBounds = getShapeBounds(shape);
    const pad: number = (shape.pathWidth ?? 0) + Math.max(
      Math.abs(shape.pathBeginExtension ?? 0),
      Math.abs(shape.pathEndExtension ?? 0),
      64
    );
    return (b.minX - pad) <= vp.maxX && (b.maxX + pad) >= vp.minX &&
           (b.minY - pad) <= vp.maxY && (b.maxY + pad) >= vp.minY;
  }

  /**
   * Shape[] -> RenderBatch[]。
   * 对扩边视口裁剪并在大坐标 (>65536nm) 下传双精度 number[]，交由 C++ NapiSetRenderData
   * 在 double 下先减局部包围盒原点再转 float，彻底消除回退路径大坐标抖动。
   */
  private shapesToBatches(sourceShapes: Shape[], cullViewport?: WorldViewport): RenderBatch[] {
    const batches: RenderBatch[] = [];
    for (let i = 0; i < sourceShapes.length; i++) {
      const shape: Shape = sourceShapes[i];
      if (!this.isLayerVisible(shape.layerNumber, shape.datatype)) {
        continue;
      }
      if (shape.type === ShapeType.NODE) {
        continue;
      }
      if (cullViewport !== undefined && !this.shapeIntersectsViewport(shape, cullViewport)) {
        continue;
      }
      const vertices: Float32Array | number[] = this.shapeToVertices(shape);
      if (vertices.length < 2) {
        continue;
      }
      const hex: string = this.layerColor(shape.layerNumber, shape.datatype);
      const style: LayerRenderStyle = this.styleForLayer(shape.layerNumber, shape.datatype);
      const fillPattern: number = fillPatternForHatch(style.hatch);
      const color: number[] = this.colorToRgba(hex, shape.selected, style, fillPattern);

      let type: GLPrimitiveType;
      if (shape.type === ShapeType.RECT) {
        type = shape.selected ? 'rectOutline' : 'rectFilled';
      } else if (shape.type === ShapeType.POLYGON) {
        type = shape.selected ? 'polygonOutline' : 'polygonFilled';
      } else if (shape.type === ShapeType.PATH) {
        type = 'lineStrip';
      } else if (shape.type === ShapeType.TEXT) {
        type = 'rectOutline';
      } else if (shape.type === ShapeType.INSTANCE) {
        type = 'rectOutline';
      } else {
        type = 'rectFilled';
      }

      batches.push({
        type: this.applyFillStyle(type, style, fillPattern),
        layerNumber: shape.layerNumber,
        datatype: shape.datatype,
        color: color,
        vertices: vertices,
        selected: shape.selected,
        fillPattern: fillPattern,
        pathWidth: shape.pathWidth ?? 0,
        pathType: shape.pathType ?? 0,
        pathBeginExtension: shape.pathBeginExtension ?? 0,
        pathEndExtension: shape.pathEndExtension ?? 0,
      });
    }
    return batches;
  }

  /** 小坐标走 Float32Array 零拆箱快速路径；大坐标 (>65536nm) 走双精度 number[] 交由 C++ 局部原点化 */
  private shapeToVertices(shape: Shape): Float32Array | number[] {
    const needsDoubleOriginShift = (pts: Point[]): boolean => {
      for (let i = 0; i < pts.length; i++) {
        if (Math.abs(pts[i].x) > 65536 || Math.abs(pts[i].y) > 65536) {
          return true;
        }
      }
      return false;
    };
    const highPrecision: boolean = needsDoubleOriginShift(shape.points);

    if (shape.type === ShapeType.RECT && shape.points.length >= 2) {
      const b = getShapeBounds(shape);
      if (highPrecision) {
        return [b.minX, b.minY, b.maxX, b.minY, b.maxX, b.maxY, b.minX, b.maxY];
      }
      const out: Float32Array = new Float32Array(8);
      out[0] = b.minX; out[1] = b.minY;
      out[2] = b.maxX; out[3] = b.minY;
      out[4] = b.maxX; out[5] = b.maxY;
      out[6] = b.minX; out[7] = b.maxY;
      return out;
    }
    if (shape.type === ShapeType.INSTANCE && shape.points.length >= 1) {
      const p0: Point = shape.points[0];
      const mag: number = shape.magnification ?? 1;
      const p1: Point = shape.points.length >= 2
        ? shape.points[1]
        : { x: p0.x + 72 * mag, y: p0.y + 24 * mag };
      if (highPrecision) {
        return [p0.x, p0.y, p1.x, p0.y, p1.x, p1.y, p0.x, p1.y];
      }
      const out: Float32Array = new Float32Array(8);
      out[0] = p0.x; out[1] = p0.y;
      out[2] = p1.x; out[3] = p0.y;
      out[4] = p1.x; out[5] = p1.y;
      out[6] = p0.x; out[7] = p1.y;
      return out;
    }
    if (shape.type === ShapeType.TEXT) {
      const anchor: Point = shape.points.length > 0 ? shape.points[0] : { x: 0, y: 0 };
      const w: number = 48;
      const h: number = 22;
      if (highPrecision) {
        return [anchor.x, anchor.y, anchor.x + w, anchor.y, anchor.x + w, anchor.y + h, anchor.x, anchor.y + h];
      }
      const out: Float32Array = new Float32Array(8);
      out[0] = anchor.x;     out[1] = anchor.y;
      out[2] = anchor.x + w; out[3] = anchor.y;
      out[4] = anchor.x + w; out[5] = anchor.y + h;
      out[6] = anchor.x;     out[7] = anchor.y + h;
      return out;
    }
    const n: number = shape.points.length;
    if (highPrecision) {
      const arr: number[] = [];
      for (let i = 0; i < n; i++) {
        arr.push(shape.points[i].x);
        arr.push(shape.points[i].y);
      }
      return arr;
    }
    const out: Float32Array = new Float32Array(n * 2);
    for (let i = 0; i < n; i++) {
      out[i * 2] = shape.points[i].x;
      out[i * 2 + 1] = shape.points[i].y;
    }
    return out;
  }

  private isLayerVisible(layerNumber: number, datatype: number): boolean {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        return this.layers[i].visible;
      }
    }
    return true;
  }

  private layerColor(layerNumber: number, datatype: number): string {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        return this.layers[i].color;
      }
    }
    return '#2F6DF6';
  }

  private findLayer(layerNumber: number, datatype: number): UiLayer | undefined {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        return this.layers[i];
      }
    }
    return undefined;
  }

  private styleForLayer(layerNumber: number, datatype: number): LayerRenderStyle {
    return layerRenderStyle(this.findLayer(layerNumber, datatype));
  }

  private hasUnrenderableStyle(): boolean {
    if (this.renderSceneProvider) return this.sceneStyleLimited;
    for (let i = 0; i < this.layers.length; i++) {
      const l: UiLayer = this.layers[i];
      if (!l.visible) {
        continue;
      }
      const st: LayerRenderStyle = this.styleForLayer(l.layerNumber, l.datatype);
      if (st.dashArray.length > 0 || l.animated === true) {
        return true;
      }
    }
    return false;
  }

  private applyFillStyle(type: GLPrimitiveType, style: LayerRenderStyle, fillPattern: number = 0): GLPrimitiveType {
    if (!style.strokeOnly || fillPattern > 0) {
      return type;
    }
    if (type === 'rectFilled') {
      return 'rectOutline';
    }
    if (type === 'polygonFilled') {
      return 'polygonOutline';
    }
    return type;
  }

  private colorToRgba(hex: string, selected: boolean, style: LayerRenderStyle, fillPattern: number = 0): number[] {
    let r: number = 0.18;
    let g: number = 0.43;
    let b: number = 0.96;
    if (hex !== undefined && hex.length >= 7 && hex.charAt(0) === '#') {
      const pr: number = parseInt(hex.substring(1, 3), 16);
      const pg: number = parseInt(hex.substring(3, 5), 16);
      const pb: number = parseInt(hex.substring(5, 7), 16);
      if (!isNaN(pr) && !isNaN(pg) && !isNaN(pb)) {
        r = pr / 255;
        g = pg / 255;
        b = pb / 255;
      }
    }
    const glStrokeOnly: boolean = style.strokeOnly && fillPattern === 0;
    const base: number = glStrokeOnly ? style.strokeOpacity : style.fillOpacity;
    let a: number = selected ? Math.max(0.92, base) : base;
    if (!Number.isFinite(a)) {
      a = 0.62;
    }
    a = Math.min(1, Math.max(0, a));
    const rgba: number[] = [r, g, b, a];
    return rgba;
  }
}
