/**
 * 鸿图 XComponent 插件实现（独立 C++ 渲染线程 + OH_NativeVSync 硬件垂直同步）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#include "xcomponent_plugin.h"
#include "hierarchy_render_batches.h"
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <hilog/log.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>

namespace {
constexpr unsigned int HONGTU_LOG_DOMAIN = 0x3200;
constexpr const char* HONGTU_XCOMP_TAG = "HongTuXComp";
constexpr const char* HONGTU_VSYNC_NAME = "HongTuGL";
}

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, HONGTU_LOG_DOMAIN, HONGTU_XCOMP_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, HONGTU_LOG_DOMAIN, HONGTU_XCOMP_TAG, __VA_ARGS__)

namespace hongtu {

XComponentPlugin& XComponentPlugin::getInstance() {
    static XComponentPlugin instance;
    return instance;
}

XComponentPlugin::XComponentPlugin()
    : renderer_(std::make_unique<GLRenderer>()),
      needRedraw_(false), eglWindow_(nullptr),
      surfaceWidth_(0), surfaceHeight_(0),
      eglDisplay_(EGL_NO_DISPLAY), eglSurface_(EGL_NO_SURFACE),
      eglContext_(EGL_NO_CONTEXT), eglConfig_(nullptr) {}

XComponentPlugin::~XComponentPlugin() {
    stopRenderThread();
}

OH_NativeXComponent* XComponentPlugin::getRegisteredComponent() {
    std::lock_guard<std::mutex> lock(mutex_);
    return registeredComponent_;
}

bool XComponentPlugin::rememberRegisteredComponent(OH_NativeXComponent* component) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (component == nullptr || (activeComponent_ != nullptr && activeComponent_ != component)) return false;
    registeredComponent_ = component;
    return true;
}

bool XComponentPlugin::isReadyLocked() const {
    return registeredComponent_ != nullptr && activeComponent_ == registeredComponent_ &&
        eglWindow_ != nullptr && renderer_ != nullptr && renderThreadRunning_ && renderThreadEglReady_;
}

void XComponentPlugin::OnVsyncCallback(long long /*timestamp*/, void* data) {
    auto* plugin = static_cast<XComponentPlugin*>(data);
    if (plugin == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(plugin->mutex_);
        plugin->vsyncRequested_ = false;
        if (plugin->needRedraw_) {
            plugin->vsyncReadyToDraw_ = true;
        }
    }
    plugin->renderCv_.notify_one();
}

void XComponentPlugin::scheduleFrameLocked(bool immediateWake) {
    needRedraw_ = true;
    if (!renderThreadRunning_ || !renderThreadEglReady_) {
        return;
    }
    if (immediateWake || nativeVsync_ == nullptr) {
        vsyncReadyToDraw_ = true;
        renderCv_.notify_one();
        return;
    }
    if (!vsyncRequested_) {
        const int ret = OH_NativeVSync_RequestFrame(nativeVsync_, &XComponentPlugin::OnVsyncCallback, this);
        if (ret == 0) {
            vsyncRequested_ = true;
        } else {
            vsyncReadyToDraw_ = true;
            renderCv_.notify_one();
        }
    }
}

void XComponentPlugin::stopRenderThread() {
    std::thread worker;
    OH_NativeVSync* vsyncToDestroy = nullptr;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        renderThreadStop_ = true;
        vsyncReadyToDraw_ = true;
        vsyncRequested_ = false;
        if (renderThread_.joinable()) {
            worker = std::move(renderThread_);
        }
        renderThreadRunning_ = false;
        renderThreadEglReady_ = false;
        vsyncToDestroy = nativeVsync_;
        nativeVsync_ = nullptr;
    }
    renderCv_.notify_all();
    if (worker.joinable()) {
        worker.join();
    }
    if (vsyncToDestroy != nullptr) {
        OH_NativeVSync_Destroy(vsyncToDestroy);
    }
}

void XComponentPlugin::startRenderThreadForWindow(OH_NativeXComponent* component, void* window,
                                                  int width, int height) {
    stopRenderThread();

    std::unique_lock<std::mutex> lock(mutex_);
    if (registeredComponent_ == nullptr) {
        registeredComponent_ = component;
    }
    activeComponent_ = component;
    eglWindow_ = window;
    if (width > 0 && height > 0) {
        surfaceWidth_ = width;
        surfaceHeight_ = height;
        if (renderer_) {
            renderer_->setSurfaceViewportSize(surfaceWidth_, surfaceHeight_);
        }
    }
    if (nativeVsync_ == nullptr) {
        nativeVsync_ = OH_NativeVSync_Create(HONGTU_VSYNC_NAME, static_cast<unsigned int>(std::strlen(HONGTU_VSYNC_NAME)));
    }
    if (renderer_) {
        renderer_->markUploadPending();
    }
    renderThreadStop_ = false;
    renderThreadInitDone_ = false;
    renderThreadEglReady_ = false;
    renderThreadRunning_ = true;
    needRedraw_ = true;
    vsyncRequested_ = false;
    vsyncReadyToDraw_ = true;
    const uint64_t token = ++renderThreadToken_;
    renderThread_ = std::thread(&XComponentPlugin::renderThreadLoop, this, window, token);

    // 等待独立渲染线程完成 EGL 创建与首帧清屏（通常 1~3ms），保证 OnSurfaceCreated 返回后立即可用且绝不闪黑屏
    initCv_.wait_for(lock, std::chrono::milliseconds(500), [this, token]() {
        return renderThreadInitDone_ || renderThreadToken_ != token;
    });
    if (renderThreadEglReady_) {
        ++surfaceGeneration_;
    }
}

void XComponentPlugin::renderThreadLoop(void* window, uint64_t token) {
    const bool eglOk = createEGLContextOnRenderThread(window);
    bool glOk = false;
    if (eglOk) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (renderer_) {
            glOk = renderer_->initialize();
            if (glOk) {
                renderer_->onViewportChanged(surfaceWidth_, surfaceHeight_);
                renderer_->markUploadPending();
            }
        }
        renderThreadEglReady_ = glOk;
        renderThreadInitDone_ = true;
        initCv_.notify_all();

        if (glOk && renderer_) {
            GLRenderer::FrameSnapshot initialSnap;
            renderer_->captureFrameSnapshot(initialSnap);
            needRedraw_ = false;
            vsyncReadyToDraw_ = false;
            lock.unlock();

            GLRenderer::FrameMetrics metrics;
            renderer_->renderSnapshot(initialSnap, metrics);
            eglSwapBuffers(eglDisplay_, eglSurface_);

            lock.lock();
            if (renderer_) {
                renderer_->commitFrameMetrics(metrics);
            }
        }
    } else {
        std::lock_guard<std::mutex> lock(mutex_);
        renderThreadEglReady_ = false;
        renderThreadInitDone_ = true;
        initCv_.notify_all();
    }

    if (!eglOk || !glOk) {
        if (eglOk) {
            destroyEGLContextOnRenderThread();
        }
        std::lock_guard<std::mutex> lock(mutex_);
        if (renderThreadToken_ == token) {
            renderThreadRunning_ = false;
            renderThreadEglReady_ = false;
        }
        return;
    }

    while (true) {
        GLRenderer::FrameSnapshot snapshot;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            renderCv_.wait(lock, [this, token]() {
                return renderThreadStop_ || renderThreadToken_ != token || (needRedraw_ && vsyncReadyToDraw_);
            });
            if (renderThreadStop_ || renderThreadToken_ != token || !renderer_) {
                break;
            }
            renderer_->captureFrameSnapshot(snapshot);
            needRedraw_ = false;
            vsyncReadyToDraw_ = false;
        }

        // 完全在 mutex_ 之外执行 GPU VBO 上传、DrawCalls 与 eglSwapBuffers，ArkUI 主线程零阻塞！
        GLRenderer::FrameMetrics metrics;
        renderer_->renderSnapshot(snapshot, metrics);
        const EGLBoolean swapped = eglSwapBuffers(eglDisplay_, eglSurface_);
        if (swapped != EGL_TRUE) {
            const EGLint err = eglGetError();
            LOGE("渲染线程 eglSwapBuffers 异常: 0x%{public}x", err);
            if (err == EGL_CONTEXT_LOST || err == EGL_BAD_SURFACE) {
                renderer_->cleanup();
                destroyEGLContextOnRenderThread();
                if (createEGLContextOnRenderThread(window) && renderer_->initialize()) {
                    std::lock_guard<std::mutex> lock(mutex_);
                    renderer_->onViewportChanged(surfaceWidth_, surfaceHeight_);
                    renderer_->markUploadPending();
                    scheduleFrameLocked(true);
                    continue;
                }
                break;
            }
        }

        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (renderer_) {
                renderer_->commitFrameMetrics(metrics);
            }
            // 若在当前帧交换期间又有新的平移/数据请求到达且未挂起 VSync，立即续约下一帧 VSync
            if (needRedraw_ && !vsyncRequested_ && !vsyncReadyToDraw_) {
                scheduleFrameLocked(false);
            }
        }
    }

    // 在创建 EGLContext 的同一渲染线程安全释放全部 GL 与 EGL 资源
    if (renderer_) {
        renderer_->cleanup();
    }
    destroyEGLContextOnRenderThread();

    std::lock_guard<std::mutex> lock(mutex_);
    if (renderThreadToken_ == token) {
        renderThreadRunning_ = false;
        renderThreadEglReady_ = false;
    }
}

void XComponentPlugin::OnSurfaceCreated(OH_NativeXComponent* component, void* window) {
    LOGI("Surface 创建");
    auto& plugin = XComponentPlugin::getInstance();

    uint64_t width = 0, height = 0;
    int ret = OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);

    {
        std::lock_guard<std::mutex> lock(plugin.mutex_);
        if (plugin.activeComponent_ != nullptr && plugin.activeComponent_ != component) {
            LOGE("忽略非当前 XComponent 的 Surface 创建");
            return;
        }
        if (plugin.activeComponent_ == component && plugin.eglWindow_ == window &&
            plugin.renderThreadRunning_ && plugin.renderThreadEglReady_) {
            if (plugin.registeredComponent_ == nullptr) {
                plugin.registeredComponent_ = component;
            }
            return;
        }
    }

    plugin.startRenderThreadForWindow(
        component,
        window,
        ret == 0 ? static_cast<int>(width) : 0,
        ret == 0 ? static_cast<int>(height) : 0);
}

void XComponentPlugin::OnSurfaceChanged(OH_NativeXComponent* component, void* window) {
    auto& plugin = XComponentPlugin::getInstance();
    uint64_t width = 0, height = 0;
    int ret = OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    std::lock_guard<std::mutex> lock(plugin.mutex_);
    if (component != plugin.activeComponent_ || window != plugin.eglWindow_) return;
    if (ret == 0 && plugin.renderer_) {
        plugin.surfaceWidth_ = static_cast<int>(width);
        plugin.surfaceHeight_ = static_cast<int>(height);
        plugin.renderer_->setSurfaceViewportSize(plugin.surfaceWidth_, plugin.surfaceHeight_);
        plugin.scheduleFrameLocked(true);
        LOGI("Surface 尺寸变更: %dx%d", plugin.surfaceWidth_, plugin.surfaceHeight_);
    }
}

void XComponentPlugin::OnSurfaceDestroyed(OH_NativeXComponent* component, void* window) {
    LOGI("Surface 销毁");
    auto& plugin = XComponentPlugin::getInstance();
    {
        std::lock_guard<std::mutex> lock(plugin.mutex_);
        if (component != plugin.activeComponent_ || window != plugin.eglWindow_) {
            if (plugin.activeComponent_ == nullptr && plugin.registeredComponent_ == component) {
                plugin.registeredComponent_ = nullptr;
            }
            return;
        }
    }
    plugin.stopRenderThread();
    {
        std::lock_guard<std::mutex> lock(plugin.mutex_);
        if (plugin.registeredComponent_ == component) {
            plugin.registeredComponent_ = nullptr;
        }
        plugin.eglWindow_ = nullptr;
        plugin.activeComponent_ = nullptr;
        plugin.needRedraw_ = false;
    }
}

void XComponentPlugin::DispatchTouchEvent(OH_NativeXComponent* component, void* window) {
    OH_NativeXComponent_TouchEvent touchEvent;
    int ret = OH_NativeXComponent_GetTouchEvent(component, window, &touchEvent);
    if (ret != 0) return;

    auto& plugin = XComponentPlugin::getInstance();
    std::lock_guard<std::mutex> lock(plugin.mutex_);
    TouchEvent event;
    event.x = touchEvent.x;
    event.y = touchEvent.y;
    event.timestamp = touchEvent.timeStamp;

    switch (touchEvent.type) {
        case OH_NATIVEXCOMPONENT_DOWN:
            event.type = TouchEventType::DOWN;
            break;
        case OH_NATIVEXCOMPONENT_MOVE:
            event.type = TouchEventType::MOVE;
            break;
        case OH_NATIVEXCOMPONENT_UP:
            event.type = TouchEventType::UP;
            break;
        default:
            return;
    }

    plugin.touchQueue_.push(event);
    while (plugin.touchQueue_.size() > 64) {
        plugin.touchQueue_.pop();
    }
}

void XComponentPlugin::OnFrameCallback(OH_NativeXComponent* component, uint64_t /*timestamp*/, uint64_t /*targetTimestamp*/) {
    auto& plugin = XComponentPlugin::getInstance();
    bool shouldWake = false;
    {
        std::lock_guard<std::mutex> lock(plugin.mutex_);
        if (component == plugin.activeComponent_ && plugin.needRedraw_ && !plugin.vsyncRequested_) {
            plugin.vsyncReadyToDraw_ = true;
            shouldWake = true;
        }
    }
    if (shouldWake) {
        plugin.renderCv_.notify_one();
    }
}

void XComponentPlugin::requestRedraw() {
    std::lock_guard<std::mutex> lock(mutex_);
    scheduleFrameLocked(false);
}

void XComponentPlugin::setRenderData(const std::vector<RenderBatch>& batches, double originX, double originY) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderer_) {
        renderer_->setRenderData(batches, false, originX, originY);
        scheduleFrameLocked(true);
    }
}

bool XComponentPlugin::submitHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                                 double originX, double originY) {
    uint64_t appliedPublication = 0;
    return submitCachedHierarchyRenderData(batches, 0, appliedPublication, originX, originY);
}

bool XComponentPlugin::submitCachedHierarchyRenderData(const std::vector<RenderBatch>& batches,
                                                      uint64_t expectedPublication, uint64_t& appliedPublication,
                                                      double originX, double originY) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!isReadyLocked()) return false;
    appliedPublication = renderer_->setCachedLayoutRenderData(batches, expectedPublication, originX, originY);
    scheduleFrameLocked(true);
    return true;
}

bool XComponentPlugin::clearRenderScene() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderer_) renderer_->setRenderData({}, true, 0.0, 0.0);
    if (isReadyLocked()) {
        scheduleFrameLocked(true);
        return true;
    }
    needRedraw_ = true;
    return false;
}

void XComponentPlugin::setCamera(double scaleX, double scaleY, double offsetX, double offsetY,
                                  int viewportW, int viewportH,
                                  double worldOffsetX, double worldOffsetY, bool hasWorldOffset) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderer_) {
        Camera cam;
        cam.scaleX = scaleX;
        cam.scaleY = scaleY;
        cam.offsetX = offsetX;
        cam.offsetY = offsetY;
        cam.viewportWidth = viewportW;
        cam.viewportHeight = viewportH;
        cam.worldOffsetX = worldOffsetX;
        cam.worldOffsetY = worldOffsetY;
        cam.hasWorldOffset = hasWorldOffset;
        renderer_->setCamera(cam);
        scheduleFrameLocked(false);
    }
}

void XComponentPlugin::setBackgroundColor(float r, float g, float b, float a) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (renderer_) {
        renderer_->setBackgroundColor(r, g, b, a);
        scheduleFrameLocked(true);
    }
}

// ===== EGL 上下文管理（独立渲染线程独占） =====

bool XComponentPlugin::createEGLContextOnRenderThread(void* window) {
    eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay 失败");
        return false;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(eglDisplay_, &major, &minor)) {
        LOGE("eglInitialize 失败");
        eglDisplay_ = EGL_NO_DISPLAY;
        return false;
    }

    const EGLint multisampleAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SAMPLE_BUFFERS, 1,
        EGL_SAMPLES, 4,
        EGL_NONE
    };
    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    const EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    for (int attempt = 0; attempt < 2; ++attempt) {
        const bool preferMsaa = attempt == 0;
        const EGLint* attributes = preferMsaa ? multisampleAttribs : configAttribs;
        EGLint numConfigs = 0;
        eglConfig_ = nullptr;
        if (!eglChooseConfig(eglDisplay_, attributes, &eglConfig_, 1, &numConfigs) || numConfigs == 0) {
            continue;
        }

        EGLint configSampleBuffers = -1, configSamples = -1;
        const bool buffersKnown = eglGetConfigAttrib(eglDisplay_, eglConfig_,
                                                     EGL_SAMPLE_BUFFERS, &configSampleBuffers) == EGL_TRUE;
        const bool samplesKnown = eglGetConfigAttrib(eglDisplay_, eglConfig_, EGL_SAMPLES, &configSamples) == EGL_TRUE;
        if (preferMsaa && (!buffersKnown || !samplesKnown || configSampleBuffers < 1 || configSamples < 4)) {
            continue;
        }

        eglSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_,
                                             reinterpret_cast<EGLNativeWindowType>(window), nullptr);
        if (eglSurface_ == EGL_NO_SURFACE) {
            continue;
        }

        eglContext_ = eglCreateContext(eglDisplay_, eglConfig_, EGL_NO_CONTEXT, contextAttribs);
        if (eglContext_ == EGL_NO_CONTEXT) {
            eglDestroySurface(eglDisplay_, eglSurface_);
            eglSurface_ = EGL_NO_SURFACE;
            continue;
        }

        if (!eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_)) {
            eglDestroyContext(eglDisplay_, eglContext_);
            eglDestroySurface(eglDisplay_, eglSurface_);
            eglContext_ = EGL_NO_CONTEXT;
            eglSurface_ = EGL_NO_SURFACE;
            continue;
        }

        // 关闭多余阻塞等待（由 OH_NativeVSync 精准控制垂直同步节拍）
        eglSwapInterval(eglDisplay_, 1);
        LOGI("独立渲染线程 EGL 就绪 %{public}d.%{public}d (MSAA=%{public}d)",
             major, minor, preferMsaa ? 4 : 0);
        return true;
    }

    LOGE("EGL MSAA 与标准配置初始化均失败");
    eglTerminate(eglDisplay_);
    eglDisplay_ = EGL_NO_DISPLAY;
    eglConfig_ = nullptr;
    return false;
}

void XComponentPlugin::destroyEGLContextOnRenderThread() {
    if (eglDisplay_ == EGL_NO_DISPLAY) return;

    eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    if (eglContext_ != EGL_NO_CONTEXT) {
        eglDestroyContext(eglDisplay_, eglContext_);
        eglContext_ = EGL_NO_CONTEXT;
    }
    if (eglSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglSurface_);
        eglSurface_ = EGL_NO_SURFACE;
    }
    eglTerminate(eglDisplay_);
    eglDisplay_ = EGL_NO_DISPLAY;
    LOGI("独立渲染线程 EGL 上下文已销毁");
}

// ===== NAPI 接口 =====

static GLPrimitiveType parsePrimitiveType(const std::string& s) {
    if (s == "rectFilled")      return GLPrimitiveType::RECT_FILLED;
    if (s == "rectOutline")     return GLPrimitiveType::RECT_OUTLINE;
    if (s == "polygonFilled")   return GLPrimitiveType::POLYGON_FILLED;
    if (s == "polygonOutline")  return GLPrimitiveType::POLYGON_OUTLINE;
    if (s == "lineStrip")       return GLPrimitiveType::LINE_STRIP;
    if (s == "selectionBox")    return GLPrimitiveType::SELECTION_BOX;
    return GLPrimitiveType::RECT_FILLED;
}

static napi_value NapiSetRenderData(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "需要传入 RenderBatch 数组");
        return nullptr;
    }

    bool isArray = false;
    napi_is_array(env, args[0], &isArray);
    if (!isArray) {
        napi_throw_type_error(env, nullptr, "参数必须是 RenderBatch 数组");
        return nullptr;
    }

    uint32_t batchCount = 0;
    napi_get_array_length(env, args[0], &batchCount);

    constexpr uint32_t kMaxBatchCount = 10'000'000;
    if (batchCount > kMaxBatchCount) {
        napi_throw_range_error(env, nullptr, "RenderBatch 数组过大");
        return nullptr;
    }

    std::vector<RenderBatch> batches;
    std::vector<std::vector<double>> rawBatchCoords;
    batches.reserve(batchCount);
    rawBatchCoords.reserve(batchCount);

    double boundsMinX = std::numeric_limits<double>::infinity();
    double boundsMinY = std::numeric_limits<double>::infinity();
    double boundsMaxX = -std::numeric_limits<double>::infinity();
    double boundsMaxY = -std::numeric_limits<double>::infinity();
    bool hasBounds = false;

    auto observePoint = [&](double dx, double dy) {
        boundsMinX = std::min(boundsMinX, dx);
        boundsMaxX = std::max(boundsMaxX, dx);
        boundsMinY = std::min(boundsMinY, dy);
        boundsMaxY = std::max(boundsMaxY, dy);
        hasBounds = true;
    };

    for (uint32_t i = 0; i < batchCount; i++) {
        napi_value element;
        napi_get_element(env, args[0], i, &element);

        RenderBatch batch;
        batch.vertexCount = 0;
        batch.selected = false;
        batch.layerNumber = 0;
        batch.datatype = 0;
        batch.color[0] = 1.0f; batch.color[1] = 1.0f;
        batch.color[2] = 1.0f; batch.color[3] = 1.0f;
        batch.type = GLPrimitiveType::RECT_FILLED;

        napi_value typeVal;
        napi_get_named_property(env, element, "type", &typeVal);
        napi_valuetype typeVt;
        napi_typeof(env, typeVal, &typeVt);
        if (typeVt == napi_string) {
            size_t typeLen = 0;
            napi_get_value_string_utf8(env, typeVal, nullptr, 0, &typeLen);
            std::string typeStr(typeLen, '\0');
            napi_get_value_string_utf8(env, typeVal, typeStr.data(), typeLen + 1, &typeLen);
            batch.type = parsePrimitiveType(typeStr);
        }

        napi_value layerVal;
        napi_get_named_property(env, element, "layerNumber", &layerVal);
        napi_get_value_int32(env, layerVal, &batch.layerNumber);

        napi_value datatypeVal;
        if (napi_get_named_property(env, element, "datatype", &datatypeVal) == napi_ok) {
            napi_get_value_int32(env, datatypeVal, &batch.datatype);
        }

        napi_value colorVal;
        napi_get_named_property(env, element, "color", &colorVal);
        bool colorIsTyped = false;
        napi_is_typedarray(env, colorVal, &colorIsTyped);
        if (colorIsTyped) {
            napi_typedarray_type cType = napi_float32_array;
            size_t cLen = 0;
            void* cData = nullptr;
            napi_value cBuf = nullptr;
            size_t cOffset = 0;
            if (napi_get_typedarray_info(env, colorVal, &cType, &cLen, &cData, &cBuf, &cOffset) == napi_ok &&
                cData != nullptr && cType == napi_float32_array) {
                const float* cFloats = static_cast<const float*>(cData);
                for (size_t c = 0; c < cLen && c < 4; ++c) {
                    if (std::isfinite(cFloats[c])) batch.color[c] = cFloats[c];
                }
            }
        } else {
            bool colorIsArray = false;
            napi_is_array(env, colorVal, &colorIsArray);
            if (colorIsArray) {
                uint32_t colorLen = 0;
                napi_get_array_length(env, colorVal, &colorLen);
                for (uint32_t c = 0; c < colorLen && c < 4; c++) {
                    napi_value cVal;
                    napi_get_element(env, colorVal, c, &cVal);
                    double cv = 0.0;
                    napi_get_value_double(env, cVal, &cv);
                    batch.color[c] = static_cast<float>(cv);
                }
            }
        }

        std::vector<double> doubleCoords;
        napi_value vertVal;
        napi_get_named_property(env, element, "vertices", &vertVal);
        bool vertIsTyped = false;
        napi_is_typedarray(env, vertVal, &vertIsTyped);
        if (vertIsTyped) {
            napi_typedarray_type typedType = napi_float32_array;
            size_t elemLen = 0;
            void* rawData = nullptr;
            napi_value arrayBuffer = nullptr;
            size_t byteOffset = 0;
            if (napi_get_typedarray_info(env, vertVal, &typedType, &elemLen, &rawData, &arrayBuffer, &byteOffset) == napi_ok &&
                rawData != nullptr && elemLen >= 2) {
                const size_t vertexCount = elemLen / 2;
                constexpr size_t kMaxVerticesPerBatch = 24'000'000;
                if (vertexCount <= kMaxVerticesPerBatch) {
                    if (typedType == napi_float32_array) {
                        const float* coords = static_cast<const float*>(rawData);
                        bool finiteOk = true;
                        doubleCoords.resize(vertexCount * 2);
                        for (size_t v = 0; v < vertexCount; ++v) {
                            const double dx = static_cast<double>(coords[v * 2]);
                            const double dy = static_cast<double>(coords[v * 2 + 1]);
                            if (!std::isfinite(dx) || !std::isfinite(dy)) {
                                finiteOk = false;
                                break;
                            }
                            doubleCoords[v * 2] = dx;
                            doubleCoords[v * 2 + 1] = dy;
                            observePoint(dx, dy);
                        }
                        if (!finiteOk) doubleCoords.clear();
                    } else if (typedType == napi_float64_array) {
                        const double* coords = static_cast<const double*>(rawData);
                        bool finiteOk = true;
                        doubleCoords.resize(vertexCount * 2);
                        for (size_t v = 0; v < vertexCount; ++v) {
                            const double dx = coords[v * 2];
                            const double dy = coords[v * 2 + 1];
                            if (!std::isfinite(dx) || !std::isfinite(dy)) {
                                finiteOk = false;
                                break;
                            }
                            doubleCoords[v * 2] = dx;
                            doubleCoords[v * 2 + 1] = dy;
                            observePoint(dx, dy);
                        }
                        if (!finiteOk) doubleCoords.clear();
                    }
                }
            }
        } else {
            bool vertIsArray = false;
            napi_is_array(env, vertVal, &vertIsArray);
            if (vertIsArray) {
                uint32_t vertLen = 0;
                napi_get_array_length(env, vertVal, &vertLen);
                uint32_t vertexCount = vertLen / 2;
                bool finiteOk = true;
                doubleCoords.reserve(static_cast<size_t>(vertexCount) * 2);
                for (uint32_t v = 0; v < vertexCount; v++) {
                    napi_value xv, yv;
                    napi_get_element(env, vertVal, v * 2, &xv);
                    napi_get_element(env, vertVal, v * 2 + 1, &yv);
                    double dx = 0.0, dy = 0.0;
                    napi_get_value_double(env, xv, &dx);
                    napi_get_value_double(env, yv, &dy);
                    if (!std::isfinite(dx) || !std::isfinite(dy)) {
                        finiteOk = false;
                        break;
                    }
                    doubleCoords.push_back(dx);
                    doubleCoords.push_back(dy);
                    observePoint(dx, dy);
                }
                if (!finiteOk) doubleCoords.clear();
            }
        }

        napi_value selVal;
        napi_get_named_property(env, element, "selected", &selVal);
        napi_get_value_bool(env, selVal, &batch.selected);

        napi_value pwVal;
        if (napi_get_named_property(env, element, "pathWidth", &pwVal) == napi_ok) {
            napi_valuetype pwT;
            if (napi_typeof(env, pwVal, &pwT) == napi_ok && pwT == napi_number) {
                double pw = 0.0;
                if (napi_get_value_double(env, pwVal, &pw) == napi_ok &&
                    std::isfinite(pw) && pw > 0.0) {
                    batch.pathWidth = static_cast<float>(pw);
                }
            }
        }

        napi_value pathTypeValue;
        if (napi_get_named_property(env, element, "pathType", &pathTypeValue) == napi_ok) {
            napi_get_value_int32(env, pathTypeValue, &batch.pathType);
        }
        napi_value fillPatternValue;
        if (napi_get_named_property(env, element, "fillPattern", &fillPatternValue) == napi_ok) {
            int32_t fp = 0;
            if (napi_get_value_int32(env, fillPatternValue, &fp) == napi_ok && fp >= 0 && fp <= 3) {
                batch.fillPattern = static_cast<int>(fp);
            }
        }
        for (const auto& extension : {std::pair<const char*, double*>("pathBeginExtension", &batch.pathBeginExtension),
                                     std::pair<const char*, double*>("pathEndExtension", &batch.pathEndExtension)}) {
            napi_value value;
            double number = 0;
            if (napi_get_named_property(env, element, extension.first, &value) == napi_ok &&
                napi_get_value_double(env, value, &number) == napi_ok && std::isfinite(number)) {
                *extension.second = number;
            }
        }
        batches.push_back(std::move(batch));
        rawBatchCoords.push_back(std::move(doubleCoords));
    }

    const double originX = hasBounds ? (0.5 * boundsMinX + 0.5 * boundsMaxX) : 0.0;
    const double originY = hasBounds ? (0.5 * boundsMinY + 0.5 * boundsMaxY) : 0.0;
    for (size_t i = 0; i < batches.size(); ++i) {
        const auto& coords = rawBatchCoords[i];
        const size_t vCount = coords.size() / 2;
        batches[i].vertices.resize(vCount);
        for (size_t v = 0; v < vCount; ++v) {
            batches[i].vertices[v] = GLVertex{
                static_cast<float>(coords[v * 2] - originX),
                static_cast<float>(coords[v * 2 + 1] - originY)
            };
        }
        batches[i].vertexCount = static_cast<int>(vCount);
    }

    XComponentPlugin::getInstance().setRenderData(batches, originX, originY);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiSetCamera(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 6) {
        napi_throw_type_error(env, nullptr, "需要 6 个参数: scaleX, scaleY, offsetX, offsetY, w, h");
        return nullptr;
    }

    double scaleX = 0.0, scaleY = 0.0, offsetX = 0.0, offsetY = 0.0;
    int32_t w = 0, h = 0;
    napi_get_value_double(env, args[0], &scaleX);
    napi_get_value_double(env, args[1], &scaleY);
    napi_get_value_double(env, args[2], &offsetX);
    napi_get_value_double(env, args[3], &offsetY);
    napi_get_value_int32(env, args[4], &w);
    napi_get_value_int32(env, args[5], &h);

    double worldOffsetX = 0.0, worldOffsetY = 0.0;
    bool hasWorldOffset = false;
    if (argc >= 8 && args[6] != nullptr && args[7] != nullptr) {
        napi_valuetype t6 = napi_undefined, t7 = napi_undefined;
        if (napi_typeof(env, args[6], &t6) == napi_ok && t6 == napi_number &&
            napi_typeof(env, args[7], &t7) == napi_ok && t7 == napi_number &&
            napi_get_value_double(env, args[6], &worldOffsetX) == napi_ok &&
            napi_get_value_double(env, args[7], &worldOffsetY) == napi_ok &&
            std::isfinite(worldOffsetX) && std::isfinite(worldOffsetY)) {
            hasWorldOffset = true;
        }
    }

    XComponentPlugin::getInstance().setCamera(
        scaleX, scaleY, offsetX, offsetY, w, h,
        worldOffsetX, worldOffsetY, hasWorldOffset);

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiSetBackgroundColor(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_type_error(env, nullptr, "需要 4 个参数: r, g, b, a");
        return nullptr;
    }
    double color[4];
    for (size_t i = 0; i < 4; ++i) {
        if (napi_get_value_double(env, args[i], &color[i]) != napi_ok ||
            !std::isfinite(color[i]) || color[i] < 0.0 || color[i] > 1.0) {
            napi_throw_range_error(env, nullptr, "背景色分量必须是 0 到 1 的有限数值");
            return nullptr;
        }
    }
    XComponentPlugin::getInstance().setBackgroundColor(
        static_cast<float>(color[0]), static_cast<float>(color[1]),
        static_cast<float>(color[2]), static_cast<float>(color[3]));
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiRequestRedraw(napi_env env, napi_callback_info /*info*/) {
    XComponentPlugin::getInstance().requestRedraw();

    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

static napi_value NapiGetRenderStats(napi_env env, napi_callback_info /*info*/) {
    auto& plugin = XComponentPlugin::getInstance();
    int32_t primitives = 0, vertices = 0, batches = 0, drawCalls = 0;
    double frameTime = 0.0, prepareTime = 0.0, uploadedBytes = 0.0;
    bool ready = false;
    {
        std::lock_guard<std::mutex> lock(plugin.getMutex());
        auto* renderer = plugin.getRenderer();
        if (renderer) {
            primitives = renderer->getLastPrimitiveCount();
            vertices = renderer->getLastVertexCount();
            frameTime = renderer->getLastFrameTime();
            batches = renderer->getLastBatchCount();
            drawCalls = renderer->getLastDrawCallCount();
            prepareTime = renderer->getLastPrepareTime();
            uploadedBytes = static_cast<double>(renderer->getLastUploadedBytes());
        }
        ready = plugin.isReadyLocked();
    }

    napi_value obj;
    napi_create_object(env, &obj);
    napi_value primitivesVal, verticesVal, frameTimeVal;
    napi_create_int32(env, primitives, &primitivesVal);
    napi_create_int32(env, vertices, &verticesVal);
    napi_create_double(env, frameTime, &frameTimeVal);
    napi_set_named_property(env, obj, "primitives", primitivesVal);
    napi_set_named_property(env, obj, "vertices", verticesVal);
    napi_set_named_property(env, obj, "frameTimeMs", frameTimeVal);
    napi_value readyVal, batchesVal, drawCallsVal, prepareTimeVal, uploadedBytesVal;
    napi_get_boolean(env, ready, &readyVal);
    napi_create_int32(env, batches, &batchesVal);
    napi_create_int32(env, drawCalls, &drawCallsVal);
    napi_create_double(env, prepareTime, &prepareTimeVal);
    napi_create_double(env, uploadedBytes, &uploadedBytesVal);
    napi_set_named_property(env, obj, "ready", readyVal);
    napi_set_named_property(env, obj, "batches", batchesVal);
    napi_set_named_property(env, obj, "drawCalls", drawCallsVal);
    napi_set_named_property(env, obj, "prepareTime", prepareTimeVal);
    napi_set_named_property(env, obj, "uploadedBytes", uploadedBytesVal);
    const HierarchyLodStatsSnapshot lodStats = ReadHierarchyLodStats();
    napi_value lodProxiesVal = nullptr, lodDedupedVal = nullptr, lodScaleVal = nullptr;
    napi_create_double(env, static_cast<double>(lodStats.proxiedCount), &lodProxiesVal);
    napi_create_double(env, static_cast<double>(lodStats.dedupedCount), &lodDedupedVal);
    napi_create_double(env, lodStats.maxLodScale, &lodScaleVal);
    napi_set_named_property(env, obj, "lodProxies", lodProxiesVal);
    napi_set_named_property(env, obj, "lodDeduped", lodDedupedVal);
    napi_set_named_property(env, obj, "lodScale", lodScaleVal);

    return obj;
}

static bool RegisterXComponentCallbacks(OH_NativeXComponent* nativeXComponent) {
    if (nativeXComponent == nullptr) return false;
    auto& plugin = XComponentPlugin::getInstance();
    OH_NativeXComponent* registered = plugin.getRegisteredComponent();
    if (registered == nativeXComponent) return true;
    if (registered != nullptr) return false;

    static OH_NativeXComponent_Callback callback = {};
    callback.OnSurfaceCreated   = &XComponentPlugin::OnSurfaceCreated;
    callback.OnSurfaceChanged   = &XComponentPlugin::OnSurfaceChanged;
    callback.OnSurfaceDestroyed = &XComponentPlugin::OnSurfaceDestroyed;
    callback.DispatchTouchEvent = &XComponentPlugin::DispatchTouchEvent;

    int32_t ret = OH_NativeXComponent_RegisterCallback(nativeXComponent, &callback);
    if (ret != 0) {
        LOGE("OH_NativeXComponent_RegisterCallback 失败: %d", ret);
        return false;
    }

    ret = OH_NativeXComponent_RegisterOnFrameCallback(nativeXComponent,
                                                       &XComponentPlugin::OnFrameCallback);
    if (ret != 0) {
        LOGE("OH_NativeXComponent_RegisterOnFrameCallback 失败: %d", ret);
        return false;
    }
    return plugin.rememberRegisteredComponent(nativeXComponent);
}

static OH_NativeXComponent* ExtractNativeXComponent(napi_env env, napi_value obj) {
    if (obj == nullptr) return nullptr;
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, obj, &type) != napi_ok || (type != napi_object && type != napi_function)) return nullptr;
    bool hasComponent = false;
    if (napi_has_named_property(env, obj, OH_NATIVE_XCOMPONENT_OBJ, &hasComponent) != napi_ok || !hasComponent) return nullptr;
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, obj, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok) {
        return nullptr;
    }
    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) != napi_ok) return nullptr;
    return nativeXComponent;
}

static napi_value NapiRegisterXComponent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_value thisArg = nullptr;
    napi_get_cb_info(env, info, &argc, args, &thisArg, nullptr);

    OH_NativeXComponent* nativeXComponent = nullptr;

    if (argc >= 1) {
        nativeXComponent = ExtractNativeXComponent(env, args[0]);
    }
    if (nativeXComponent == nullptr && thisArg != nullptr) {
        nativeXComponent = ExtractNativeXComponent(env, thisArg);
    }
    if (nativeXComponent == nullptr) {
        nativeXComponent = XComponentPlugin::getInstance().getRegisteredComponent();
    }

    if (nativeXComponent == nullptr) {
        napi_throw_type_error(env, nullptr,
            "无法获取原生 OH_NativeXComponent,请确保 XComponent(libraryname='hongtu') 已创建");
        return nullptr;
    }

    if (!RegisterXComponentCallbacks(nativeXComponent)) {
        napi_throw_type_error(env, nullptr, "注册 XComponent surface 回调失败");
        return nullptr;
    }

    LOGI("XComponent 回调注册成功(onLoad 后备路径)");
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    return undefined;
}

template <napi_value (*Impl)(napi_env, napi_callback_info)>
static napi_value NapiSafe(napi_env env, napi_callback_info info) {
    try {
        return Impl(env, info);
    } catch (const std::exception& e) {
        napi_throw_error(env, nullptr, e.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "HongTu native: unknown exception");
        return nullptr;
    }
}

napi_value XComponentPlugin::Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"registerXComponent", nullptr, NapiSafe<NapiRegisterXComponent>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setRenderData",  nullptr, NapiSafe<NapiSetRenderData>,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCamera",      nullptr, NapiSafe<NapiSetCamera>,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setBackgroundColor", nullptr, NapiSafe<NapiSetBackgroundColor>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"requestRedraw",  nullptr, NapiSafe<NapiRequestRedraw>,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRenderStats", nullptr, NapiSafe<NapiGetRenderStats>, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    OH_NativeXComponent* nativeXComponent = ExtractNativeXComponent(env, exports);
    if (nativeXComponent != nullptr) {
        if (RegisterXComponentCallbacks(nativeXComponent)) {
            LOGI("XComponent 回调自动注册成功(libraryname 注入)");
        }
    } else {
        LOGI("Init 时 exports 上尚无 OH_NATIVE_XCOMPONENT_OBJ,等待 onLoad 后备注册");
    }

    return exports;
}

} // namespace hongtu
