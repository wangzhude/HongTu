/**
 * 鸿图 XComponent 插件
 *
 * 采用华为官方推荐的 XComponent Native Surface + 独立 C++ 渲染线程 + OH_NativeVSync 架构：
 * - EGLContext 常驻独立渲染线程（消除每帧 eglMakeCurrent 驱动锁切换开销）
 * - 锁外执行 glBufferData 与 eglSwapBuffers（彻底解耦 ArkUI 主线程平移/缩放输入）
 * - OH_NativeVSync 硬件垂直同步合批请求（高频触控/鼠标事件自动合并为每帧一次提交）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include "napi/native_api.h"
#include "gl_renderer.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <native_vsync/native_vsync.h>
#include <EGL/egl.h>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <thread>

namespace hongtu {

enum class TouchEventType {
    DOWN,
    MOVE,
    UP,
};

struct TouchEvent {
    TouchEventType type;
    float x;
    float y;
    int64_t timestamp;
};

class XComponentPlugin {
public:
    static XComponentPlugin& getInstance();

    static napi_value Init(napi_env env, napi_value exports);

    static void OnSurfaceCreated(OH_NativeXComponent* component, void* window);
    static void OnSurfaceChanged(OH_NativeXComponent* component, void* window);
    static void OnSurfaceDestroyed(OH_NativeXComponent* component, void* window);
    static void DispatchTouchEvent(OH_NativeXComponent* component, void* window);
    static void OnFrameCallback(OH_NativeXComponent* component, uint64_t timestamp, uint64_t targetTimestamp);
    static void OnVsyncCallback(long long timestamp, void* data);

    GLRenderer* getRenderer() { return renderer_.get(); }
    std::mutex& getMutex() { return mutex_; }

    OH_NativeXComponent* getRegisteredComponent();
    bool rememberRegisteredComponent(OH_NativeXComponent* component);
    bool isReadyLocked() const;
    uint64_t getSurfaceGenerationLocked() const { return surfaceGeneration_; }

    void requestRedraw();
    void setRenderData(const std::vector<RenderBatch>& batches, double originX = 0.0, double originY = 0.0);

    bool submitHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                   double originX = 0.0, double originY = 0.0);

    bool submitCachedHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                        uint64_t expectedPublication, uint64_t& appliedPublication,
                                        double originX = 0.0, double originY = 0.0);

    bool clearRenderScene();

    void setCamera(double scaleX, double scaleY, double offsetX, double offsetY,
                   int viewportW, int viewportH,
                   double worldOffsetX = 0.0, double worldOffsetY = 0.0, bool hasWorldOffset = false);

    void setBackgroundColor(float r, float g, float b, float a);

private:
    XComponentPlugin();
    ~XComponentPlugin();

    bool createEGLContextOnRenderThread(void* window);
    void destroyEGLContextOnRenderThread();
    void startRenderThreadForWindow(OH_NativeXComponent* component, void* window, int width, int height);
    void stopRenderThread();
    void renderThreadLoop(void* window, uint64_t token);
    void scheduleFrameLocked(bool immediateWake);

    std::unique_ptr<GLRenderer> renderer_;
    std::mutex mutex_;
    std::condition_variable renderCv_;
    std::condition_variable initCv_;
    std::thread renderThread_;

    bool needRedraw_;
    bool vsyncRequested_ = false;
    bool vsyncReadyToDraw_ = false;
    bool renderThreadRunning_ = false;
    bool renderThreadStop_ = false;
    bool renderThreadInitDone_ = false;
    bool renderThreadEglReady_ = false;
    uint64_t renderThreadToken_ = 0;

    void* eglWindow_;
    int surfaceWidth_;
    int surfaceHeight_;
    uint64_t surfaceGeneration_ = 0;
    OH_NativeXComponent* registeredComponent_ = nullptr;
    OH_NativeXComponent* activeComponent_ = nullptr;
    OH_NativeVSync* nativeVsync_ = nullptr;

    // EGL 上下文（由独立渲染线程独占绑定与销毁）
    EGLDisplay eglDisplay_;
    EGLSurface eglSurface_;
    EGLContext eglContext_;
    EGLConfig  eglConfig_;

    std::queue<TouchEvent> touchQueue_;
};

} // namespace hongtu
