/**
 * 鸿图 OpenGL ES 渲染器
 *
 * 基于 OpenGL ES 3.0 实现高性能版图渲染：
 * - Camera-Relative 双精度局部原点顶点缓冲对象 (VBO) 批量绘制
 * - 独立 C++ 渲染线程无锁快照交换（UI 线程零 glBufferData / 零 eglSwapBuffers 阻塞）
 * - 图层颜色与图案着色器
 * - 选中高亮描边
 * - 视口变换（双精度相对偏移合并 + 原生 glViewport 比例自适应校正）
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
    int sourceOrder = 0;
    bool preserveOpacity = false;
    bool mayHaveKeyholeBridge = true;
    float pathWidth = 0.0f;
    int pathType = 0;
    double pathBeginExtension = 0;
    double pathEndExtension = 0;
    int fillPattern = 0;
    std::vector<uint32_t> triangleIndices;
};

/** 相机参数（双精度保真，支持毫米/晶圆级大版图纳米级缩放零相消抖动） */
struct Camera {
    double scaleX = 1.0;
    double scaleY = 1.0;
    double offsetX = 0.0;
    double offsetY = 0.0;
    int viewportWidth = 800;
    int viewportHeight = 600;
    double worldOffsetX = 0.0;
    double worldOffsetY = 0.0;
    bool hasWorldOffset = false;
};

/** OpenGL ES 渲染器 */
class GLRenderer {
public:
    struct DrawCommand {
        GLenum mode;
        GLint first;
        GLsizei count;
        bool fill;
        int fillPattern = 0;
        float color[4];
    };

    /** 供独立渲染线程在锁外执行 GPU 提交与交换的帧快照 */
    struct FrameSnapshot {
        bool uploadVertices = false;
        std::vector<GLVertex> vertices;
        std::vector<DrawCommand> commands;
        double originX = 0.0;
        double originY = 0.0;
        Camera camera;
        int surfaceViewportWidth = 0;
        int surfaceViewportHeight = 0;
        float backgroundColor[4] = {1.0f, 1.0f, 1.0f, 1.0f};
        int preparedPrimitiveCount = 0;
        int preparedBatchCount = 0;
    };

    struct FrameMetrics {
        int primitiveCount = 0;
        int vertexCount = 0;
        int batchCount = 0;
        int drawCallCount = 0;
        size_t uploadedBytes = 0;
        float frameTimeMs = 0.0f;
    };

    GLRenderer();
    ~GLRenderer();

    bool initialize();
    void cleanup();
    bool isReady() const { return ready_; }

    void setRenderData(const std::vector<RenderBatch>& batches, bool layoutLayerOrder = false,
                       double originX = 0.0, double originY = 0.0);

    uint64_t setCachedLayoutRenderData(const std::vector<RenderBatch>& batches, uint64_t expectedPublication,
                                       double originX = 0.0, double originY = 0.0);
    uint64_t getRenderDataPublication() const { return renderDataPublication_; }

    void setRenderOrigin(double originX, double originY) {
        originX_ = originX;
        originY_ = originY;
    }
    double getOriginX() const { return originX_; }
    double getOriginY() const { return originY_; }

    void setCamera(const Camera& camera);
    const Camera& getCamera() const { return camera_; }
    const float* getMvpMatrix() const { return mvpMatrix_; }

    void setBackgroundColor(float r, float g, float b, float a);
    void render();

    /** 持锁捕获微秒级 CPU 帧快照（仅在 uploadPending_ 时转移顶点数组），随后可在锁外执行 renderSnapshot */
    void captureFrameSnapshot(FrameSnapshot& out);
    /** 在独立渲染线程锁外执行 GL 绘制，避免 eglSwapBuffers / glBufferData 阻塞 ArkUI 主线程 */
    void renderSnapshot(const FrameSnapshot& snapshot, FrameMetrics& metricsOut);
    /** 持锁回写最近一帧 GPU 提交指标 */
    void commitFrameMetrics(const FrameMetrics& metrics);
    /** Surface 重建后强制下一帧重新上传保留的 CPU 顶点至新 VBO */
    void markUploadPending() { uploadPending_ = true; }

    void onViewportChanged(int width, int height);
    void setSurfaceViewportSize(int width, int height);
    int getSurfaceViewportWidth() const { return surfaceViewportWidth_; }
    int getSurfaceViewportHeight() const { return surfaceViewportHeight_; }

    void computeMVPMatrix(float outMvp[9]);
    void computeMVPMatrixFor(const Camera& cam, double originX, double originY,
                             int surfW, int surfH, float outMvp[9]);

    int getLastPrimitiveCount() const { return lastPrimitiveCount_; }
    int getLastVertexCount() const { return lastVertexCount_; }
    float getLastFrameTime() const { return lastFrameTime_; }
    int getLastBatchCount() const { return lastBatchCount_; }
    int getLastDrawCallCount() const { return lastDrawCallCount_; }
    size_t getLastUploadedBytes() const { return lastUploadedBytes_; }
    float getLastPrepareTime() const { return lastPrepareTime_; }

private:
    void setLayoutRenderData(const std::vector<RenderBatch>& batches, double originX, double originY);
    GLuint shaderProgram_;
    GLuint lineShaderProgram_;

    GLuint vbo_;
    GLuint vao_;

    GLint mvpLocation_;
    GLint colorLocation_;
    GLint fillPatternLocation_;
    GLint lineMvpLocation_;
    GLint lineColorLocation_;

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
    float backgroundColor_[4] = {1.0f, 1.0f, 1.0f, 1.0f};

    struct CachedPolygonTriangulation {
        uint64_t hash = 0;
        std::vector<GLVertex> relativeContour;
        std::vector<uint32_t> indices;
    };
    std::vector<CachedPolygonTriangulation> triangulationCache_;
    std::unordered_multimap<uint64_t, size_t> triangulationIndex_;

    bool ready_;
    int lastPrimitiveCount_;
    int lastVertexCount_;
    float lastFrameTime_;
    int lastBatchCount_ = 0;
    int lastDrawCallCount_ = 0;
    size_t lastUploadedBytes_ = 0;
    float lastPrepareTime_ = 0;
    float maxSupportedLineWidth_;

    const char* vertexShaderSource_ = nullptr;
    const char* fragmentShaderSource_ = nullptr;
    const char* lineVertexShaderSource_ = nullptr;
    const char* lineFragmentShaderSource_ = nullptr;

    GLuint compileShader(GLenum type, const char* source);
    GLuint linkProgram(GLuint vertShader, GLuint fragShader);
    void updateMVP(GLint location);
    void drawCommand(const DrawCommand& command);
    void drawCommandWithMvp(const DrawCommand& command, const float mvp[9]);
    bool triangulatePolygonCached(const std::vector<GLVertex>& verts, int n,
                                  const std::vector<uint32_t>& precomputedIndices,
                                  std::vector<GLVertex>& outVerts);
    void applyStrokeWidth(float desiredPx);
};

} // namespace hongtu
