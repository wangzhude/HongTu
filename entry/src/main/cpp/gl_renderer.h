/**
 * 鸿图 OpenGL ES 渲染器
 *
 * 基于 OpenGL ES 3.0 实现高性能版图渲染：
 * - Camera-Relative 双精度局部原点顶点缓冲对象 (VBO) 批量绘制
 * - 图层颜色与图案着色器
 * - 选中高亮描边
 * - 视口变换（双精度相对偏移合并 + 原生 glViewport 比例自适应校正）
 *
 * 通过 XComponent 的 EGL 环境进行渲染，替代 ArkUI 基础图形。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include <GLES3/gl3.h>
#include <vector>
#include <string>
#include <memory>
#include <cstdint>
#include <unordered_map>

namespace hongtu {

/** 渲染图元类型 */
enum class GLPrimitiveType {
    RECT_FILLED,
    RECT_OUTLINE,
    POLYGON_FILLED,
    POLYGON_OUTLINE,
    LINE_STRIP,
    SELECTION_BOX,
};

/** 填充图案编码（与片元着色器 u_fillPattern 保持一致） */
enum class GLFillPattern : int {
    SOLID = 0,
    DIAGONAL = 1,
    CROSS = 2,
    STIPPLE = 3,
};

/** 顶点数据（相对于批次局部原点 (originX_, originY_) 的二维偏移坐标，紧凑双 float 供 GPU 直读） */
struct GLVertex {
    float x;
    float y;
};
static_assert(sizeof(GLVertex) == 2 * sizeof(float), "GLVertex must remain tightly packed float2");

/** 渲染批次（一个图层的一组同类型图元） */
struct RenderBatch {
    GLPrimitiveType type;
    int layerNumber;
    int datatype;
    float color[4];       // RGBA
    std::vector<GLVertex> vertices;
    int vertexCount;
    bool selected;
    // A scene's source order is more significant than its internal layer order.
    // Default zero preserves the existing single-layout contract.
    int sourceOrder = 0;
    bool preserveOpacity = false;
    /**
     * LINE_STRIP（PATH）的真实线宽，世界坐标 nm。
     * 0 = 无宽度（hairline 描边）。GLES 的 glLineWidth 通常只保证 1px，
     * 线宽必须走轮廓化条带，不能靠 glLineWidth。
     */
    float pathWidth = 0.0f;
    int pathType = 0;
    double pathBeginExtension = 0;
    double pathEndExtension = 0;
    /** 填充图案槽位：0=实心，1=45°斜线(diagonal)，2=交叉网格(cross)，3=点阵(stipple) */
    int fillPattern = 0;
    /**
     * 可选预计算多边形耳切三角化索引（指向 vertices[0..vertexCount-1]）。
     * 子 Cell 多边形在局部坐标系下完成一次耳切后跨实例复用索引，避免每帧重复 O(N^2) 三角剖分。
     */
    std::vector<uint32_t> triangleIndices;
};

/**
 * 相机参数（双精度保真，支持毫米/晶圆级大版图纳米级缩放零相消抖动）
 *
 * 顶点生成时已在 double 下减去批次参考原点 (originX_, originY_)；
 * ArkTS 侧一次性编码 pixel→NDC 映射（JS number 为 IEEE-754 double）：
 *   scaleX = 2z/w, scaleY = 2z/h, offsetX = 2z*viewOffsetX/w - 1,
 *   offsetY = 1 - 2z*viewOffsetY/h        (z = zoomPercent/100)
 * 世界 Y 与 NDC Y 同向；ArkUI 覆盖层与 SVG/PNG 在世界到像素时翻转 Y。
 * native updateMVP 先在 double 精度下合并 (cameraWorldOffset + origin) 的微小相对偏移，
 * 并结合原生 glViewport 实际宽高比修正正交投影比例，再生成 float mat3 u_mvp。
 */
struct Camera {
    double scaleX = 1.0;     // 用户坐标 → 归一化坐标的缩放
    double scaleY = 1.0;
    double offsetX = 0.0;    // 屏幕偏移（归一化，double 保留高精度平移分量）
    double offsetY = 0.0;
    int viewportWidth = 800;
    int viewportHeight = 600;
    double worldOffsetX = 0.0; // 可选显式相机世界偏移 X（nm，与 viewOffsetX 同号）
    double worldOffsetY = 0.0; // 可选显式相机世界偏移 Y（nm，与 viewOffsetY 同号）
    bool hasWorldOffset = false;
};

/**
 * OpenGL ES 渲染器
 */
class GLRenderer {
public:
    GLRenderer();
    ~GLRenderer();

    /** 初始化 OpenGL 资源（着色器、VBO） */
    bool initialize();

    /** 释放资源 */
    void cleanup();

    /** 是否已初始化 */
    bool isReady() const { return ready_; }

    /**
     * 设置渲染数据（支持 Camera-Relative 双精度局部参考原点）
     * @param batches 渲染批次列表（顶点为相对 (originX, originY) 的局部 float 偏移）
     * @param layoutLayerOrder 按 (sourceOrder, layer, datatype) 合成；来源内先填充再描边。
     * @param originX 当前 VBO 批次对应的双精度世界参考原点 X (nm)
     * @param originY 当前 VBO 批次对应的双精度世界参考原点 Y (nm)
     */
    void setRenderData(const std::vector<RenderBatch>& batches, bool layoutLayerOrder = false,
                       double originX = 0.0, double originY = 0.0);

    /** Reuse only the exact successful publication owned by this renderer.
     * Tokens are process-wide and never reused across renderer instances;
     * zero always forces preparation. Caller serializes all renderer access. */
    uint64_t setCachedLayoutRenderData(const std::vector<RenderBatch>& batches, uint64_t expectedPublication,
                                       double originX = 0.0, double originY = 0.0);
    uint64_t getRenderDataPublication() const { return renderDataPublication_; }

    /** 显式更新当前 VBO 批次的世界参考原点（nm） */
    void setRenderOrigin(double originX, double originY) {
        originX_ = originX;
        originY_ = originY;
    }
    double getOriginX() const { return originX_; }
    double getOriginY() const { return originY_; }

    /**
     * 设置相机参数
     */
    void setCamera(const Camera& camera);
    const Camera& getCamera() const { return camera_; }
    const float* getMvpMatrix() const { return mvpMatrix_; }

    /** 设置清屏色；调用方与 render() 使用同一互斥锁，不在此调用 GL。 */
    void setBackgroundColor(float r, float g, float b, float a);

    /**
     * 执行一帧渲染
     */
    void render();

    /**
     * 原生 Surface / glViewport 视口大小变化（保留 camera_ 的逻辑视口基准以修正分屏拖拽宽高比）
     */
    void onViewportChanged(int width, int height);

    /** 仅记录原生 Surface 尺寸（供无当前 EGL 上下文时延迟至帧回调同步 glViewport） */
    void setSurfaceViewportSize(int width, int height);
    int getSurfaceViewportWidth() const { return surfaceViewportWidth_; }
    int getSurfaceViewportHeight() const { return surfaceViewportHeight_; }

    /** 计算当前状态对应的 3x3 列主序 MVP 矩阵并写入 mvpMatrix_ */
    void computeMVPMatrix(float outMvp[9]);

    /** Source shapes submitted in the last frame (a rectangle batch can contain many). */
    int getLastPrimitiveCount() const { return lastPrimitiveCount_; }

    /** GPU vertices submitted, including decomposed triangles and independent edges. */
    int getLastVertexCount() const { return lastVertexCount_; }

    /** CPU submission time only: excludes ArkTS/NAPI preparation and GPU completion. */
    float getLastFrameTime() const { return lastFrameTime_; }
    /** Prepared render groups, not raw input count. */
    int getLastBatchCount() const { return lastBatchCount_; }
    int getLastDrawCallCount() const { return lastDrawCallCount_; }
    size_t getLastUploadedBytes() const { return lastUploadedBytes_; }
    float getLastPrepareTime() const { return lastPrepareTime_; }

private:
    void setLayoutRenderData(const std::vector<RenderBatch>& batches, double originX, double originY);
    // 着色器程序
    GLuint shaderProgram_;
    GLuint lineShaderProgram_;

    // 顶点缓冲对象
    GLuint vbo_;
    GLuint vao_;

    // uniform 位置
    GLint mvpLocation_;
    GLint colorLocation_;
    GLint fillPatternLocation_;
    GLint lineMvpLocation_;
    GLint lineColorLocation_;

    // 渲染数据
    struct DrawCommand {
        GLenum mode;
        GLint first;
        GLsizei count;
        bool fill;
        int fillPattern = 0;
        float color[4];
    };
    // Prepared only at data submission; one persistent VBO is reused by camera frames.
    std::vector<GLVertex> cachedVertices_;
    std::vector<DrawCommand> drawCommands_;
    bool uploadPending_ = true;
    uint64_t renderDataPublication_ = 0;
    int preparedPrimitiveCount_ = 0;
    int preparedBatchCount_ = 0;
    double originX_ = 0.0;
    double originY_ = 0.0;
    Camera camera_;
    int surfaceViewportWidth_ = 0;
    int surfaceViewportHeight_ = 0;
    double displayDensity_ = 1.0;
    bool densityCalibrated_ = false;
    float mvpMatrix_[9] = {1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f};
    float backgroundColor_[4] = {0.118f, 0.118f, 0.180f, 1.0f};

    // 多边形耳切三角化索引缓存（复用平移全等的子 Cell 多边形剖分索引）
    struct CachedPolygonTriangulation {
        uint64_t hash = 0;
        std::vector<GLVertex> relativeContour;
        std::vector<uint32_t> indices;
    };
    std::vector<CachedPolygonTriangulation> triangulationCache_;
    std::unordered_multimap<uint64_t, size_t> triangulationIndex_;

    // 状态
    bool ready_;
    int lastPrimitiveCount_;
    int lastVertexCount_;
    float lastFrameTime_;
    int lastBatchCount_ = 0;
    int lastDrawCallCount_ = 0;
    size_t lastUploadedBytes_ = 0;
    float lastPrepareTime_ = 0;
    /** 线宽上限（GL_ALIASED_LINE_WIDTH_RANGE 探测，缺省 2.0f = 改造前请求值） */
    float maxSupportedLineWidth_;

    // 着色器源码
    const char* vertexShaderSource_ = nullptr;
    const char* fragmentShaderSource_ = nullptr;
    const char* lineVertexShaderSource_ = nullptr;
    const char* lineFragmentShaderSource_ = nullptr;

    // 内部方法
    GLuint compileShader(GLenum type, const char* source);
    GLuint linkProgram(GLuint vertShader, GLuint fragShader);
    void updateMVP(GLint location);
    void drawCommand(const DrawCommand& command);
    bool triangulatePolygonCached(const std::vector<GLVertex>& verts, int n,
                                  const std::vector<uint32_t>& precomputedIndices,
                                  std::vector<GLVertex>& outVerts);
    /** 按上下文支持的线宽上限钳制后设置 glLineWidth */
    void applyStrokeWidth(float desiredPx);
};

} // namespace hongtu
