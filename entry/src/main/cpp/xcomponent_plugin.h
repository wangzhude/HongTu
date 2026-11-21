/**
 * 鸿图 XComponent 插件
 *
 * 管理 XComponent 的 EGL 渲染生命周期：
 * - surface 创建 / 销毁 / 重建恢复
 * - 每帧渲染回调与 EGL 上下文绑定校验
 * - 触摸事件处理
 *
 * 通过 NAPI 注册到 ArkTS 层，由 XComponent 组件驱动。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include "napi/native_api.h"
#include "gl_renderer.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <EGL/egl.h>
#include <memory>
#include <mutex>
#include <queue>

namespace hongtu {

/** 触摸事件类型 */
enum class TouchEventType {
    DOWN,
    MOVE,
    UP,
};

/** 触摸事件数据 */
struct TouchEvent {
    TouchEventType type;
    float x;
    float y;
    int64_t timestamp;
};

/**
 * XComponent 渲染插件
 */
class XComponentPlugin {
public:
    static XComponentPlugin& getInstance();

    /** NAPI 初始化 */
    static napi_value Init(napi_env env, napi_value exports);

    // XComponent 生命周期回调
    static void OnSurfaceCreated(OH_NativeXComponent* component, void* window);
    static void OnSurfaceChanged(OH_NativeXComponent* component, void* window);
    static void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window);
    static void DispatchTouchEvent(OH_NativeXComponent* component, void* window);

    // 每帧渲染回调（OH_NativeXComponent_RegisterOnFrameCallback 要求的签名）
    static void OnFrameCallback(OH_NativeXComponent* component, uint64_t timestamp, uint64_t targetTimestamp);

    /** 获取渲染器 */
    GLRenderer* getRenderer() { return renderer_.get(); }

    /** 获取渲染互斥锁（NAPI 层读取渲染统计时需持锁，避免与渲染线程竞争） */
    std::mutex& getMutex() { return mutex_; }

    /** Only a fully registered, not-yet-destroyed handle may be reused by onLoad. */
    OH_NativeXComponent* getRegisteredComponent();
    bool rememberRegisteredComponent(OH_NativeXComponent* component);
    /** Caller holds getMutex(). EGL/resource readiness, not registration alone. */
    bool isReadyLocked() const;
    uint64_t getSurfaceGenerationLocked() const { return surfaceGeneration_; }

    /** 请求重绘 */
    void requestRedraw();

    /** 设置渲染数据（从 ArkTS 调用，附带 Camera-Relative 双精度世界参考原点） */
    void setRenderData(const std::vector<RenderBatch>& batches, double originX = 0.0, double originY = 0.0);

    /** Native hierarchy fast path: false if the actual surface is not ready.
     * A valid empty batch list clears the surface. Does not construct a renderer. */
    bool submitHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                   double originX = 0.0, double originY = 0.0);

    /** Expected token must name this renderer's complete current CPU frame.
     * Comparison and optional preparation use the same surface mutex. */
    bool submitCachedHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                        uint64_t expectedPublication, uint64_t& appliedPublication,
                                        double originX = 0.0, double originY = 0.0);

    /** Release prepared CPU geometry even while the surface is unavailable.
     * Returns whether a ready surface can present the empty frame. */
    bool clearRenderScene();

    /** 设置相机参数（从 ArkTS 调用，double 保留高精度世界平移偏移） */
    void setCamera(double scaleX, double scaleY, double offsetX, double offsetY,
                   int viewportW, int viewportH,
                   double worldOffsetX = 0.0, double worldOffsetY = 0.0, bool hasWorldOffset = false);

    /** 设置画布清屏色并请求下一帧重绘。 */
    void setBackgroundColor(float r, float g, float b, float a);

private:
    XComponentPlugin();
    ~XComponentPlugin();

    bool createEGLContext(void* window);
    void destroyEGLContext();
    /** 持锁校验当前线程 EGL 上下文与绘制表面绑定，解绑时自动执行 eglMakeCurrent 恢复 */
    bool ensureEGLContextLocked();

    std::unique_ptr<GLRenderer> renderer_;
    std::mutex mutex_;
    bool needRedraw_;
    void* eglWindow_;
    int surfaceWidth_;
    int surfaceHeight_;
    uint64_t surfaceGeneration_ = 0;
    OH_NativeXComponent* registeredComponent_ = nullptr;
    OH_NativeXComponent* activeComponent_ = nullptr;

    // EGL 上下文
    EGLDisplay eglDisplay_;
    EGLSurface eglSurface_;
    EGLContext eglContext_;
    EGLConfig  eglConfig_;

    // 触摸事件队列
    std::queue<TouchEvent> touchQueue_;
};

} // namespace hongtu
