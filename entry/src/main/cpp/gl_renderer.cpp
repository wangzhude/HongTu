/**
 * 鸿图 OpenGL ES 渲染器实现
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#include "gl_renderer.h"
#include <atomic>
#include "gl_batch_geometry.h"
#include "triangulator.h"
#include <hilog/log.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <algorithm>
#include <limits>
#include <stdexcept>
#include <unordered_map>

namespace {
constexpr unsigned int HONGTU_LOG_DOMAIN = 0x3200;
constexpr const char* HONGTU_GL_TAG = "HongTuGL";
}

#define LOGI(...) OH_LOG_Print(LOG_APP, LOG_INFO, HONGTU_LOG_DOMAIN, HONGTU_GL_TAG, __VA_ARGS__)
#define LOGE(...) OH_LOG_Print(LOG_APP, LOG_ERROR, HONGTU_LOG_DOMAIN, HONGTU_GL_TAG, __VA_ARGS__)

namespace hongtu {

static const char* kFillVertexShader = R"(
#version 300 es
precision highp float;
layout(location = 0) in vec2 a_position;
uniform mat3 u_mvp;
void main() {
    vec3 pos = u_mvp * vec3(a_position, 1.0);
    gl_Position = vec4(pos.xy, 0.0, 1.0);
}
)";

static const char* kFillFragmentShader = R"(
#version 300 es
precision highp float;
uniform vec4 u_color;
uniform int u_fillPattern;
out vec4 fragColor;
void main() {
    if (u_fillPattern == 1) {
        float d = mod(gl_FragCoord.x - gl_FragCoord.y, 8.0);
        float mask = d < 1.6 ? 1.0 : 0.14;
        fragColor = vec4(u_color.rgb, u_color.a * mask);
    } else if (u_fillPattern == 2) {
        float d1 = mod(gl_FragCoord.x - gl_FragCoord.y, 8.0);
        float d2 = mod(gl_FragCoord.x + gl_FragCoord.y, 8.0);
        float mask = (d1 < 1.5 || d2 < 1.5) ? 1.0 : 0.12;
        fragColor = vec4(u_color.rgb, u_color.a * mask);
    } else if (u_fillPattern == 3) {
        vec2 cell = mod(gl_FragCoord.xy, 6.0) - vec2(3.0);
        float mask = dot(cell, cell) <= 1.6 ? 1.0 : 0.10;
        fragColor = vec4(u_color.rgb, u_color.a * mask);
    } else {
        fragColor = u_color;
    }
}
)";

static const char* kLineVertexShader = R"(
#version 300 es
precision highp float;
layout(location = 0) in vec2 a_position;
uniform mat3 u_mvp;
void main() {
    vec3 pos = u_mvp * vec3(a_position, 1.0);
    gl_Position = vec4(pos.xy, 0.0, 1.0);
}
)";

static const char* kLineFragmentShader = R"(
#version 300 es
precision highp float;
uniform vec4 u_color;
out vec4 fragColor;
void main() {
    fragColor = u_color;
}
)";

GLRenderer::GLRenderer()
    : shaderProgram_(0), lineShaderProgram_(0),
      vbo_(0), vao_(0),
      mvpLocation_(-1), colorLocation_(-1), fillPatternLocation_(-1),
      lineMvpLocation_(-1), lineColorLocation_(-1),
      ready_(false), lastPrimitiveCount_(0), lastVertexCount_(0),
      lastFrameTime_(0.0f), maxSupportedLineWidth_(2.0f) {
    camera_ = {1.0, 1.0, 0.0, 0.0, 800, 600};
}

GLRenderer::~GLRenderer() {
    cleanup();
}

bool GLRenderer::initialize() {
    GLuint fillVS = compileShader(GL_VERTEX_SHADER, kFillVertexShader);
    GLuint fillFS = compileShader(GL_FRAGMENT_SHADER, kFillFragmentShader);
    if (fillVS == 0 || fillFS == 0) {
        LOGE("填充着色器编译失败");
        return false;
    }
    shaderProgram_ = linkProgram(fillVS, fillFS);
    glDeleteShader(fillVS);
    glDeleteShader(fillFS);
    if (shaderProgram_ == 0) {
        LOGE("填充着色器程序链接失败");
        return false;
    }

    GLuint lineVS = compileShader(GL_VERTEX_SHADER, kLineVertexShader);
    GLuint lineFS = compileShader(GL_FRAGMENT_SHADER, kLineFragmentShader);
    if (lineVS == 0 || lineFS == 0) {
        LOGE("线框着色器编译失败");
        return false;
    }
    lineShaderProgram_ = linkProgram(lineVS, lineFS);
    glDeleteShader(lineVS);
    glDeleteShader(lineFS);
    if (lineShaderProgram_ == 0) {
        LOGE("线框着色器程序链接失败");
        return false;
    }

    mvpLocation_ = glGetUniformLocation(shaderProgram_, "u_mvp");
    colorLocation_ = glGetUniformLocation(shaderProgram_, "u_color");
    fillPatternLocation_ = glGetUniformLocation(shaderProgram_, "u_fillPattern");
    lineMvpLocation_ = glGetUniformLocation(lineShaderProgram_, "u_mvp");
    lineColorLocation_ = glGetUniformLocation(lineShaderProgram_, "u_color");

    GLfloat widthRange[2] = {maxSupportedLineWidth_, maxSupportedLineWidth_};
    glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE, widthRange);
    if (std::isfinite(widthRange[1]) && widthRange[1] >= 1.0f) {
        maxSupportedLineWidth_ = std::min(maxSupportedLineWidth_, widthRange[1]);
    }
    LOGI("GL 线宽上限: %{public}f px", maxSupportedLineWidth_);

    glGenVertexArrays(1, &vao_);
    glGenBuffers(1, &vbo_);
    uploadPending_ = true;

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    ready_ = true;
    LOGI("OpenGL ES 渲染器初始化成功");
    return true;
}

void GLRenderer::cleanup() {
    if (shaderProgram_) { glDeleteProgram(shaderProgram_); shaderProgram_ = 0; }
    if (lineShaderProgram_) { glDeleteProgram(lineShaderProgram_); lineShaderProgram_ = 0; }
    if (vbo_) { glDeleteBuffers(1, &vbo_); vbo_ = 0; }
    if (vao_) { glDeleteVertexArrays(1, &vao_); vao_ = 0; }
    triangulationCache_.clear();
    triangulationIndex_.clear();
    uploadPending_ = true;
    ready_ = false;
}

void GLRenderer::setCamera(const Camera& camera) {
    camera_ = camera;
}

void GLRenderer::setBackgroundColor(float r, float g, float b, float a) {
    backgroundColor_[0] = r;
    backgroundColor_[1] = g;
    backgroundColor_[2] = b;
    backgroundColor_[3] = a;
}

void GLRenderer::setSurfaceViewportSize(int width, int height) {
    if (width > 0 && height > 0) {
        surfaceViewportWidth_ = width;
        surfaceViewportHeight_ = height;
    }
}

void GLRenderer::onViewportChanged(int width, int height) {
    if (width > 0 && height > 0) {
        surfaceViewportWidth_ = width;
        surfaceViewportHeight_ = height;
        glViewport(0, 0, width, height);
    }
}

void GLRenderer::captureFrameSnapshot(FrameSnapshot& out) {
    out.uploadVertices = uploadPending_;
    if (uploadPending_) {
        out.vertices = cachedVertices_;
        uploadPending_ = false;
    } else {
        out.vertices.clear();
    }
    out.commands = drawCommands_;
    out.originX = originX_;
    out.originY = originY_;
    out.camera = camera_;
    out.surfaceViewportWidth = surfaceViewportWidth_;
    out.surfaceViewportHeight = surfaceViewportHeight_;
    std::copy(backgroundColor_, backgroundColor_ + 4, out.backgroundColor);
    out.preparedPrimitiveCount = preparedPrimitiveCount_;
    out.preparedBatchCount = preparedBatchCount_;
}

void GLRenderer::renderSnapshot(const FrameSnapshot& snapshot, FrameMetrics& metricsOut) {
    metricsOut = {};
    if (!ready_) return;

    const auto startTime = std::chrono::high_resolution_clock::now();

    int surfW = snapshot.surfaceViewportWidth;
    int surfH = snapshot.surfaceViewportHeight;
    if (surfW > 0 && surfH > 0) {
        glViewport(0, 0, surfW, surfH);
    } else {
        GLint vp[4] = {0, 0, 0, 0};
        glGetIntegerv(GL_VIEWPORT, vp);
        if (vp[2] > 0 && vp[3] > 0) {
            surfW = vp[2];
            surfH = vp[3];
        }
    }

    glClearColor(snapshot.backgroundColor[0], snapshot.backgroundColor[1],
                 snapshot.backgroundColor[2], snapshot.backgroundColor[3]);
    glClear(GL_COLOR_BUFFER_BIT);

    glBindVertexArray(vao_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    if (snapshot.uploadVertices) {
        metricsOut.uploadedBytes = snapshot.vertices.size() * sizeof(GLVertex);
        glBufferData(GL_ARRAY_BUFFER, static_cast<GLsizeiptr>(metricsOut.uploadedBytes),
                     snapshot.vertices.empty() ? nullptr : snapshot.vertices.data(), GL_DYNAMIC_DRAW);
    }

    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(GLVertex), (void*)0);
    glEnableVertexAttribArray(0);

    float mvp[9] = {1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 1.0f};
    computeMVPMatrixFor(snapshot.camera, snapshot.originX, snapshot.originY, surfW, surfH, mvp);

    for (const auto& command : snapshot.commands) {
        drawCommandWithMvp(command, mvp);
        ++metricsOut.drawCallCount;
        metricsOut.vertexCount += command.count;
    }
    metricsOut.primitiveCount = snapshot.preparedPrimitiveCount;
    metricsOut.batchCount = snapshot.preparedBatchCount;

    glBindVertexArray(0);

    const auto endTime = std::chrono::high_resolution_clock::now();
    metricsOut.frameTimeMs = std::chrono::duration<float, std::milli>(endTime - startTime).count();
}

void GLRenderer::commitFrameMetrics(const FrameMetrics& metrics) {
    lastPrimitiveCount_ = metrics.primitiveCount;
    lastVertexCount_ = metrics.vertexCount;
    lastBatchCount_ = metrics.batchCount;
    lastDrawCallCount_ = metrics.drawCallCount;
    if (metrics.uploadedBytes > 0) {
        lastUploadedBytes_ = metrics.uploadedBytes;
    }
    lastFrameTime_ = metrics.frameTimeMs;
}

void GLRenderer::render() {
    if (!ready_) return;
    FrameSnapshot snapshot;
    captureFrameSnapshot(snapshot);
    FrameMetrics metrics;
    renderSnapshot(snapshot, metrics);
    commitFrameMetrics(metrics);
}

GLuint GLRenderer::compileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint success;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &success);
    if (!success) {
        char log[512];
        glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
        LOGE("着色器编译错误: %s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint GLRenderer::linkProgram(GLuint vertShader, GLuint fragShader) {
    GLuint program = glCreateProgram();
    glAttachShader(program, vertShader);
    glAttachShader(program, fragShader);
    glLinkProgram(program);

    GLint success;
    glGetProgramiv(program, GL_LINK_STATUS, &success);
    if (!success) {
        char log[512];
        glGetProgramInfoLog(program, sizeof(log), nullptr, log);
        LOGE("着色器程序链接错误: %s", log);
        glDeleteProgram(program);
        return 0;
    }
    return program;
}

void GLRenderer::computeMVPMatrixFor(const Camera& cam, double rawOriginX, double rawOriginY,
                                     int surfW, int surfH, float outMvp[9]) {
    double effScaleX = cam.scaleX;
    double effScaleY = cam.scaleY;

    if (surfW > 0 && surfH > 0 &&
        cam.viewportWidth > 0 && cam.viewportHeight > 0 &&
        effScaleX > 0.0 && effScaleY > 0.0 &&
        std::isfinite(effScaleX) && std::isfinite(effScaleY)) {
        const double camTwoZX = effScaleX * static_cast<double>(cam.viewportWidth);
        const double camTwoZY = effScaleY * static_cast<double>(cam.viewportHeight);
        const double maxTwoZ = std::max(camTwoZX, camTwoZY);
        const bool isotropicCamera = maxTwoZ > 0.0 &&
            std::abs(camTwoZX - camTwoZY) <= 1e-3 * maxTwoZ;
        if (isotropicCamera) {
            const double rx = static_cast<double>(surfW) / static_cast<double>(cam.viewportWidth);
            const double ry = static_cast<double>(surfH) / static_cast<double>(cam.viewportHeight);
            const double maxRatio = std::max(rx, ry);
            if (maxRatio > 0.0 && std::abs(rx - ry) <= 0.02 * maxRatio) {
                displayDensity_ = 0.5 * (rx + ry);
                densityCalibrated_ = true;
            } else if (maxRatio > 0.0) {
                const double density = (densityCalibrated_ && displayDensity_ > 0.0)
                    ? displayDensity_
                    : (ry > 0.0 ? ry : 1.0);
                const double effVpW = static_cast<double>(surfW) / density;
                const double effVpH = static_cast<double>(surfH) / density;
                const double twoZ = 0.5 * (camTwoZX + camTwoZY);
                if (effVpW > 0.0 && effVpH > 0.0) {
                    effScaleX = twoZ / effVpW;
                    effScaleY = twoZ / effVpH;
                }
            }
        }
    }

    const double originX = std::isfinite(rawOriginX) ? rawOriginX : 0.0;
    const double originY = std::isfinite(rawOriginY) ? rawOriginY : 0.0;

    double ndcOffsetX = cam.offsetX + effScaleX * originX;
    double ndcOffsetY = cam.offsetY + effScaleY * originY;

    if (cam.hasWorldOffset || (std::abs(cam.scaleX) > 1e-30 && std::isfinite(cam.scaleX))) {
        const double viewOffsetX = cam.hasWorldOffset
            ? cam.worldOffsetX
            : ((cam.offsetX + 1.0) / cam.scaleX);
        const double relWorldX = viewOffsetX + originX;
        ndcOffsetX = effScaleX * relWorldX - 1.0;
    }
    if (cam.hasWorldOffset || (std::abs(cam.scaleY) > 1e-30 && std::isfinite(cam.scaleY))) {
        const double viewOffsetY = cam.hasWorldOffset
            ? cam.worldOffsetY
            : ((1.0 - cam.offsetY) / cam.scaleY);
        const double relWorldY = originY - viewOffsetY;
        ndcOffsetY = 1.0 + effScaleY * relWorldY;
    }

    outMvp[0] = static_cast<float>(effScaleX);
    outMvp[1] = 0.0f;
    outMvp[2] = 0.0f;
    outMvp[3] = 0.0f;
    outMvp[4] = static_cast<float>(effScaleY);
    outMvp[5] = 0.0f;
    outMvp[6] = static_cast<float>(ndcOffsetX);
    outMvp[7] = static_cast<float>(ndcOffsetY);
    outMvp[8] = 1.0f;
}

void GLRenderer::computeMVPMatrix(float outMvp[9]) {
    computeMVPMatrixFor(camera_, originX_, originY_, surfaceViewportWidth_, surfaceViewportHeight_, outMvp);
}

void GLRenderer::updateMVP(GLint location) {
    computeMVPMatrix(mvpMatrix_);
    if (location >= 0) glUniformMatrix3fv(location, 1, GL_FALSE, mvpMatrix_);
}

namespace {
uint64_t HashRelativePolygon(const std::vector<GLVertex>& verts, int n) {
    uint64_t h = 14695981039346656037ULL;
    h ^= static_cast<uint64_t>(n);
    h *= 1099511628211ULL;
    const float x0 = verts[0].x;
    const float y0 = verts[0].y;
    for (int i = 1; i < n; ++i) {
        const int64_t qx = static_cast<int64_t>(std::llround(static_cast<double>(verts[i].x - x0) * 1024.0));
        const int64_t qy = static_cast<int64_t>(std::llround(static_cast<double>(verts[i].y - y0) * 1024.0));
        h ^= static_cast<uint64_t>(qx);
        h *= 1099511628211ULL;
        h ^= static_cast<uint64_t>(qy);
        h *= 1099511628211ULL;
    }
    return h;
}
} // namespace

bool GLRenderer::triangulatePolygonCached(const std::vector<GLVertex>& verts, int n,
                                          const std::vector<uint32_t>& precomputedIndices,
                                          std::vector<GLVertex>& outVerts) {
    if (n < 3 || n > static_cast<int>(verts.size())) return false;

    if (precomputedIndices.size() >= 3 && (precomputedIndices.size() % 3) == 0) {
        outVerts.clear();
        outVerts.reserve(precomputedIndices.size());
        for (uint32_t idx : precomputedIndices) {
            if (idx >= static_cast<uint32_t>(n)) {
                outVerts.clear();
                break;
            }
            outVerts.push_back(verts[idx]);
        }
        if (outVerts.size() >= 3) {
            return true;
        }
    }

    if (n == 3) {
        if (!std::isfinite(verts[0].x) || !std::isfinite(verts[0].y) ||
            !std::isfinite(verts[1].x) || !std::isfinite(verts[1].y) ||
            !std::isfinite(verts[2].x) || !std::isfinite(verts[2].y)) {
            return false;
        }
        const double cross2 =
            (static_cast<double>(verts[1].x) - static_cast<double>(verts[0].x)) *
            (static_cast<double>(verts[2].y) - static_cast<double>(verts[0].y)) -
            (static_cast<double>(verts[1].y) - static_cast<double>(verts[0].y)) *
            (static_cast<double>(verts[2].x) - static_cast<double>(verts[0].x));
        if (!(std::abs(cross2) > 1e-12)) return false;
        outVerts.clear();
        outVerts.push_back(verts[0]);
        outVerts.push_back(verts[1]);
        outVerts.push_back(verts[2]);
        return true;
    }

    const bool cacheable = (n >= 4 && n <= 8192 && std::isfinite(verts[0].x) && std::isfinite(verts[0].y));
    uint64_t hash = 0;
    if (cacheable) {
        hash = HashRelativePolygon(verts, n);
        const float x0 = verts[0].x;
        const float y0 = verts[0].y;
        const auto range = triangulationIndex_.equal_range(hash);
        for (auto it = range.first; it != range.second; ++it) {
            const size_t idxSlot = it->second;
            if (idxSlot >= triangulationCache_.size()) continue;
            const auto& entry = triangulationCache_[idxSlot];
            if (entry.hash != hash || static_cast<int>(entry.relativeContour.size()) != n) continue;
            bool match = true;
            for (int i = 1; i < n; ++i) {
                const float dx = (verts[i].x - x0) - entry.relativeContour[static_cast<size_t>(i)].x;
                const float dy = (verts[i].y - y0) - entry.relativeContour[static_cast<size_t>(i)].y;
                if (std::abs(dx) > 1e-3f || std::abs(dy) > 1e-3f) {
                    match = false;
                    break;
                }
            }
            if (match && entry.indices.size() >= 3) {
                outVerts.clear();
                outVerts.reserve(entry.indices.size());
                for (uint32_t idx : entry.indices) {
                    if (idx < static_cast<uint32_t>(n)) outVerts.push_back(verts[idx]);
                }
                if (outVerts.size() >= 3) return true;
            }
        }
    }

    std::vector<Vec2> poly;
    poly.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) {
        poly.emplace_back(static_cast<double>(verts[i].x),
                          static_cast<double>(verts[i].y));
    }
    std::vector<uint32_t> tris;
    if (!Triangulator::triangulate(poly, tris) || tris.empty()) {
        return false;
    }
    outVerts.clear();
    outVerts.reserve(tris.size());
    for (uint32_t idx : tris) {
        if (idx < static_cast<uint32_t>(n)) {
            outVerts.push_back(verts[idx]);
        }
    }
    if (outVerts.size() < 3) {
        return false;
    }

    if (cacheable) {
        constexpr size_t kMaxCachedPolygons = 1024;
        if (triangulationCache_.size() >= kMaxCachedPolygons) {
            triangulationCache_.erase(triangulationCache_.begin(),
                                      triangulationCache_.begin() + (kMaxCachedPolygons / 4));
            triangulationIndex_.clear();
            for (size_t idxSlot = 0; idxSlot < triangulationCache_.size(); ++idxSlot) {
                triangulationIndex_.emplace(triangulationCache_[idxSlot].hash, idxSlot);
            }
        }
        CachedPolygonTriangulation entry;
        entry.hash = hash;
        entry.relativeContour.resize(static_cast<size_t>(n));
        const float x0 = verts[0].x;
        const float y0 = verts[0].y;
        entry.relativeContour[0] = {0.0f, 0.0f};
        for (int i = 1; i < n; ++i) {
            entry.relativeContour[static_cast<size_t>(i)] = {verts[i].x - x0, verts[i].y - y0};
        }
        entry.indices = std::move(tris);
        const size_t newSlot = triangulationCache_.size();
        triangulationCache_.push_back(std::move(entry));
        triangulationIndex_.emplace(hash, newSlot);
    }
    return true;
}

static bool buildPathRibbon(const std::vector<GLVertex>& verts, int n, float pathWidth,
                            std::vector<GLVertex>& outVerts, int pathType,
                            double beginExtension, double endExtension,
                            std::vector<uint32_t>& scratchIndices) {
    if (n < 2 || !(pathWidth > 0.0f) || !std::isfinite(pathWidth)) return false;
    std::vector<Vec2> center;
    center.reserve(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) {
        if (!std::isfinite(verts[i].x) || !std::isfinite(verts[i].y)) return false;
        center.emplace_back(static_cast<double>(verts[i].x),
                            static_cast<double>(verts[i].y));
    }
    const std::vector<Vec2> outline = Triangulator::pathOutline(center, pathWidth,
        pathType, beginExtension, endExtension);
    if (outline.size() < 3) return false;
    for (const auto& p : outline) {
        if (!std::isfinite(p.x) || !std::isfinite(p.y)) return false;
    }
    scratchIndices.clear();
    if (!Triangulator::triangulate(outline, scratchIndices) || scratchIndices.size() < 3) {
        return false;
    }
    outVerts.clear();
    outVerts.reserve(scratchIndices.size());
    for (uint32_t idx : scratchIndices) {
        if (idx < outline.size()) {
            outVerts.push_back(GLVertex{static_cast<float>(outline[idx].x),
                                        static_cast<float>(outline[idx].y)});
        }
    }
    return outVerts.size() >= 3;
}

void GLRenderer::applyStrokeWidth(float desiredPx) {
    if (!std::isfinite(desiredPx) || desiredPx <= 0.0f) {
        desiredPx = 1.0f;
    }
    const float w = std::min(desiredPx, maxSupportedLineWidth_);
    if (w >= 0.0f) {
        glLineWidth(w);
    }
}

static uint64_t packVertexKey(const GLVertex& v) noexcept {
    uint32_t bx = 0, by = 0;
    std::memcpy(&bx, &v.x, sizeof(uint32_t));
    std::memcpy(&by, &v.y, sizeof(uint32_t));
    if (bx == 0x80000000u) bx = 0u;
    if (by == 0x80000000u) by = 0u;
    return (static_cast<uint64_t>(bx) << 32) | static_cast<uint64_t>(by);
}

struct DirectedEdgeKey {
    uint64_t u;
    uint64_t v;
    bool operator==(const DirectedEdgeKey& o) const noexcept { return u == o.u && v == o.v; }
};

struct DirectedEdgeKeyHash {
    size_t operator()(const DirectedEdgeKey& k) const noexcept {
        uint64_t h = k.u ^ (k.v + 0x9e3779b97f4a7c15ULL + (k.u << 6) + (k.u >> 2));
        return static_cast<size_t>(h);
    }
};

static void appendPolygonOutlineEdges(const std::vector<GLVertex>& verts, size_t n,
                                      std::vector<GLVertex>& outEdges,
                                      bool mayHaveKeyholeBridge = true) {
    if (n < 2) return;
    while (n > 2 && packVertexKey(verts[n - 1]) == packVertexKey(verts[0])) {
        --n;
    }
    if (n < 2) return;
    if (!mayHaveKeyholeBridge || n < 6) {
        for (size_t p = 0; p < n; ++p) {
            outEdges.push_back(verts[p]);
            outEdges.push_back(verts[(p + 1) % n]);
        }
        return;
    }

    constexpr uint32_t kCap = 32768u;
    constexpr uint32_t kMask = kCap - 1u;
    thread_local uint64_t tlVertKeys[kCap];
    thread_local uint32_t tlVertStamp[kCap] = {};
    thread_local uint32_t tlGen = 1u;

    bool hasDupVert = (n > 16384);
    if (!hasDupVert) {
        ++tlGen;
        if (tlGen == 0u) {
            std::memset(tlVertStamp, 0, sizeof(tlVertStamp));
            tlGen = 1u;
        }
        for (size_t p = 0; p < n; ++p) {
            const uint64_t k = packVertexKey(verts[p]);
            uint32_t slot = static_cast<uint32_t>((k ^ (k >> 32)) * 2654435761u) & kMask;
            while (tlVertStamp[slot] == tlGen) {
                if (tlVertKeys[slot] == k) {
                    hasDupVert = true;
                    break;
                }
                slot = (slot + 1u) & kMask;
            }
            if (hasDupVert) break;
            tlVertStamp[slot] = tlGen;
            tlVertKeys[slot] = k;
        }
    }

    if (!hasDupVert) {
        for (size_t p = 0; p < n; ++p) {
            outEdges.push_back(verts[p]);
            outEdges.push_back(verts[(p + 1) % n]);
        }
        return;
    }

    if (n <= 16384) {
        thread_local uint64_t tlEdgeU[kCap];
        thread_local uint64_t tlEdgeV[kCap];
        thread_local int32_t tlEdgeIdx[kCap];
        thread_local uint32_t tlEdgeStamp[kCap] = {};
        thread_local uint8_t tlSkip[16384];
        thread_local uint32_t tlEdgeGen = 1u;
        ++tlEdgeGen;
        if (tlEdgeGen == 0u) {
            std::memset(tlEdgeStamp, 0, sizeof(tlEdgeStamp));
            tlEdgeGen = 1u;
        }
        std::memset(tlSkip, 0, n);
        bool anyCancelled = false;
        for (size_t p = 0; p < n; ++p) {
            const uint64_t ku = packVertexKey(verts[p]);
            const uint64_t kv = packVertexKey(verts[(p + 1) % n]);
            if (ku == kv) {
                tlSkip[p] = 1;
                anyCancelled = true;
                continue;
            }
            const uint64_t revHash = kv ^ (ku + 0x9e3779b97f4a7c15ULL + (kv << 6) + (kv >> 2));
            uint32_t rSlot = static_cast<uint32_t>(revHash ^ (revHash >> 32)) & kMask;
            bool matched = false;
            while (tlEdgeStamp[rSlot] == tlEdgeGen) {
                if (tlEdgeIdx[rSlot] >= 0 && tlEdgeU[rSlot] == kv && tlEdgeV[rSlot] == ku) {
                    tlSkip[tlEdgeIdx[rSlot]] = 1;
                    tlSkip[p] = 1;
                    tlEdgeIdx[rSlot] = -1;
                    anyCancelled = true;
                    matched = true;
                    break;
                }
                rSlot = (rSlot + 1u) & kMask;
            }
            if (!matched) {
                const uint64_t fwdHash = ku ^ (kv + 0x9e3779b97f4a7c15ULL + (ku << 6) + (ku >> 2));
                uint32_t fSlot = static_cast<uint32_t>(fwdHash ^ (fwdHash >> 32)) & kMask;
                while (tlEdgeStamp[fSlot] == tlEdgeGen && tlEdgeIdx[fSlot] >= 0) {
                    fSlot = (fSlot + 1u) & kMask;
                }
                tlEdgeStamp[fSlot] = tlEdgeGen;
                tlEdgeU[fSlot] = ku;
                tlEdgeV[fSlot] = kv;
                tlEdgeIdx[fSlot] = static_cast<int32_t>(p);
            }
        }
        for (size_t p = 0; p < n; ++p) {
            if (!anyCancelled || !tlSkip[p]) {
                outEdges.push_back(verts[p]);
                outEdges.push_back(verts[(p + 1) % n]);
            }
        }
        return;
    }

    std::vector<uint8_t> skipEdge(n, 0);
    std::unordered_map<DirectedEdgeKey, std::vector<size_t>, DirectedEdgeKeyHash> firstIndices;
    firstIndices.reserve(n);
    bool anyCancelled = false;
    for (size_t p = 0; p < n; ++p) {
        const uint64_t ku = packVertexKey(verts[p]);
        const uint64_t kv = packVertexKey(verts[(p + 1) % n]);
        if (ku == kv) {
            skipEdge[p] = 1;
            anyCancelled = true;
            continue;
        }
        auto revIt = firstIndices.find({kv, ku});
        if (revIt != firstIndices.end() && !revIt->second.empty()) {
            const size_t partner = revIt->second.back();
            revIt->second.pop_back();
            skipEdge[partner] = 1;
            skipEdge[p] = 1;
            anyCancelled = true;
        } else {
            firstIndices[{ku, kv}].push_back(p);
        }
    }
    for (size_t p = 0; p < n; ++p) {
        if (!anyCancelled || !skipEdge[p]) {
            outEdges.push_back(verts[p]);
            outEdges.push_back(verts[(p + 1) % n]);
        }
    }
}

static uint64_t NextRenderDataPublication() {
    static std::atomic<uint64_t> last{0};
    auto previous = last.load(std::memory_order_relaxed);
    while (previous != std::numeric_limits<uint64_t>::max()) {
        if (last.compare_exchange_weak(previous, previous + 1, std::memory_order_relaxed))
            return previous + 1;
    }
    return 0;
}

uint64_t GLRenderer::setCachedLayoutRenderData(const std::vector<RenderBatch>& batches,
                                               uint64_t expectedPublication,
                                               double originX, double originY) {
    if (expectedPublication != 0 && expectedPublication == renderDataPublication_ &&
        originX == originX_ && originY == originY_) {
        return renderDataPublication_;
    }
    setRenderData(batches, true, originX, originY);
    return renderDataPublication_;
}

void GLRenderer::setRenderData(const std::vector<RenderBatch>& batches, bool layoutLayerOrder,
                               double originX, double originY) {
    if (layoutLayerOrder) {
        setLayoutRenderData(batches, originX, originY);
        return;
    }
    const auto startTime = std::chrono::high_resolution_clock::now();
    std::vector<GLVertex> nextVertices;
    std::vector<DrawCommand> nextCommands;
    std::vector<uint32_t> scratchIndices;
    int primitiveCount = 0;
    int batchCount = 0;
    size_t estimatedVertices = 0;
    const size_t maxVertices = static_cast<size_t>(std::numeric_limits<GLsizei>::max());
    for (const auto& batch : batches) {
        const size_t n = batch.vertexCount > 0
            ? std::min(batch.vertices.size(), static_cast<size_t>(batch.vertexCount)) : 0;
        const size_t estimate = batch.type == GLPrimitiveType::RECT_FILLED ? (n / 4) * 14
            : batch.type == GLPrimitiveType::RECT_OUTLINE ? (n / 4) * 8
            : batch.type == GLPrimitiveType::POLYGON_FILLED ? (n > 2 ? (n - 2) * 3 : 0) + n * 2
            : n * 2;
        if (estimate > maxVertices - estimatedVertices)
            throw std::length_error("Prepared GL geometry exceeds vertex index limit");
        estimatedVertices += estimate;
    }
    nextVertices.reserve(estimatedVertices);
    nextCommands.reserve(std::min<size_t>(batches.size(), 4096));
    auto compatibleRectangles = [](const RenderBatch& a, const RenderBatch& b) {
        return a.sourceOrder == b.sourceOrder && a.preserveOpacity == b.preserveOpacity &&
            a.type == b.type && a.layerNumber == b.layerNumber && a.datatype == b.datatype &&
            a.selected == b.selected && a.fillPattern == b.fillPattern &&
            std::equal(a.color, a.color + 4, b.color) &&
            a.pathWidth == b.pathWidth && a.pathType == b.pathType &&
            a.pathBeginExtension == b.pathBeginExtension && a.pathEndExtension == b.pathEndExtension;
    };
    for (size_t batchIndex = 0; batchIndex < batches.size();) {
        const size_t groupBegin = batchIndex;
        const auto& batch = batches[batchIndex++];
        const bool rectangleGroup = batch.type == GLPrimitiveType::RECT_FILLED ||
                                    batch.type == GLPrimitiveType::RECT_OUTLINE;
        if (rectangleGroup) {
            while (batchIndex < batches.size() && compatibleRectangles(batch, batches[batchIndex])) ++batchIndex;
        }
        const int n = batch.vertexCount > 0
            ? static_cast<int>(std::min(batch.vertices.size(), static_cast<size_t>(batch.vertexCount))) : 0;
        if (n <= 0 && !rectangleGroup) continue;
        const size_t firstCommand = nextCommands.size();
        auto emit = [&](GLenum mode, bool fill, size_t first) {
            const size_t count = nextVertices.size() - first;
            if (count == 0) return;
            if (nextVertices.size() > maxVertices)
                throw std::length_error("Prepared GL geometry exceeds vertex index limit");
            DrawCommand command{};
            command.mode = mode;
            command.first = static_cast<GLint>(first);
            command.count = static_cast<GLsizei>(count);
            command.fill = fill;
            command.fillPattern = fill ? batch.fillPattern : 0;
            std::copy(batch.color, batch.color + 4, command.color);
            if (fill) {
                command.color[3] = batch.selected && batch.type != GLPrimitiveType::LINE_STRIP
                    ? std::min(1.0f, batch.color[3] + 0.1f) : batch.color[3];
            } else if (!batch.preserveOpacity && batch.type != GLPrimitiveType::LINE_STRIP) {
                command.color[3] = std::min(1.0f, std::max(0.85f, batch.color[3]));
                if (batch.type == GLPrimitiveType::SELECTION_BOX) {
                    command.color[0] = 0.184f; command.color[1] = 0.427f;
                    command.color[2] = 0.965f; command.color[3] = 1.0f;
                }
            }
            nextCommands.push_back(command);
        };
        if (rectangleGroup) {
            if (batch.type == GLPrimitiveType::RECT_FILLED) {
                const size_t first = nextVertices.size();
                for (size_t i = groupBegin; i < batchIndex; ++i) {
                    const auto& source = batches[i];
                    appendRectangleTriangles(source.vertices, source.vertexCount > 0
                        ? static_cast<size_t>(source.vertexCount) : 0, nextVertices);
                }
                emit(GL_TRIANGLES, true, first);
            }
            const size_t first = nextVertices.size();
            size_t rectangles = 0;
            for (size_t i = groupBegin; i < batchIndex; ++i) {
                const auto& source = batches[i];
                rectangles += appendRectangleEdges(source.vertices, source.vertexCount > 0
                    ? static_cast<size_t>(source.vertexCount) : 0, nextVertices);
            }
            emit(GL_LINES, false, first);
            primitiveCount += static_cast<int>(rectangles);
        } else if (batch.type == GLPrimitiveType::LINE_STRIP) {
            std::vector<GLVertex> ribbon;
            const size_t first = nextVertices.size();
            if (buildPathRibbon(batch.vertices, n, batch.pathWidth, ribbon, batch.pathType,
                                batch.pathBeginExtension, batch.pathEndExtension, scratchIndices)) {
                nextVertices.insert(nextVertices.end(), ribbon.begin(), ribbon.end());
                emit(GL_TRIANGLES, true, first);
            } else {
                nextVertices.insert(nextVertices.end(), batch.vertices.begin(), batch.vertices.begin() + n);
                emit(GL_LINE_STRIP, false, first);
            }
            ++primitiveCount;
        } else {
            if (batch.type == GLPrimitiveType::POLYGON_FILLED) {
                std::vector<GLVertex> triangles;
                const size_t first = nextVertices.size();
                if (triangulatePolygonCached(batch.vertices, n, batch.triangleIndices, triangles)) {
                    nextVertices.insert(nextVertices.end(), triangles.begin(), triangles.end());
                    emit(GL_TRIANGLES, true, first);
                } else {
                    nextVertices.insert(nextVertices.end(), batch.vertices.begin(), batch.vertices.begin() + n);
                    emit(GL_TRIANGLE_FAN, true, first);
                }
            }
            const size_t first = nextVertices.size();
            appendPolygonOutlineEdges(batch.vertices, n, nextVertices, batch.mayHaveKeyholeBridge);
            emit(GL_LINES, false, first);
            ++primitiveCount;
        }
        if (nextCommands.size() != firstCommand) ++batchCount;
    }
    cachedVertices_.swap(nextVertices);
    drawCommands_.swap(nextCommands);
    originX_ = std::isfinite(originX) ? originX : 0.0;
    originY_ = std::isfinite(originY) ? originY : 0.0;
    renderDataPublication_ = NextRenderDataPublication();
    preparedPrimitiveCount_ = primitiveCount;
    preparedBatchCount_ = batchCount;
    uploadPending_ = true;
    lastPrepareTime_ = std::chrono::duration<float, std::milli>(
        std::chrono::high_resolution_clock::now() - startTime).count();
}

void GLRenderer::setLayoutRenderData(const std::vector<RenderBatch>& batches,
                                     double originX, double originY) {
    const auto startTime = std::chrono::high_resolution_clock::now();
    std::vector<const RenderBatch*> ordered;
    ordered.reserve(batches.size());
    for (const auto& batch : batches) ordered.push_back(&batch);
    auto batchLess = [](const RenderBatch* a, const RenderBatch* b) {
        if (a->sourceOrder != b->sourceOrder) return a->sourceOrder < b->sourceOrder;
        return a->layerNumber != b->layerNumber ? a->layerNumber < b->layerNumber : a->datatype < b->datatype;
    };
    if (!std::is_sorted(ordered.begin(), ordered.end(), batchLess)) {
        std::stable_sort(ordered.begin(), ordered.end(), batchLess);
    }
    auto styleDomain = [](GLPrimitiveType type) {
        switch (type) {
            case GLPrimitiveType::RECT_FILLED: case GLPrimitiveType::POLYGON_FILLED: return 0;
            case GLPrimitiveType::RECT_OUTLINE: case GLPrimitiveType::POLYGON_OUTLINE: return 1;
            case GLPrimitiveType::LINE_STRIP: return 2;
            default: return 3;
        }
    };
    auto compatible = [&](const RenderBatch& a, const RenderBatch& b) {
        return a.sourceOrder == b.sourceOrder && a.preserveOpacity == b.preserveOpacity &&
            a.layerNumber == b.layerNumber && a.datatype == b.datatype &&
            styleDomain(a.type) == styleDomain(b.type) && a.selected == b.selected &&
            a.fillPattern == b.fillPattern &&
            std::equal(a.color, a.color + 4, b.color) && a.pathWidth == b.pathWidth &&
            a.pathType == b.pathType && a.pathBeginExtension == b.pathBeginExtension &&
            a.pathEndExtension == b.pathEndExtension;
    };
    std::vector<GLVertex> nextVertices;
    std::vector<GLVertex> edges;
    std::vector<GLVertex> triangles;
    std::vector<uint32_t> scratchIndices;
    std::vector<DrawCommand> nextCommands;
    const size_t maxVertices = static_cast<size_t>(std::numeric_limits<GLsizei>::max());
    size_t estimatedVertices = 0;
    for (const RenderBatch* batch : ordered) {
        const size_t n = batch->vertexCount > 0
            ? std::min(batch->vertices.size(), static_cast<size_t>(batch->vertexCount)) : 0;
        const size_t estimate = batch->type == GLPrimitiveType::RECT_FILLED ? (n / 4) * 14
            : batch->type == GLPrimitiveType::RECT_OUTLINE ? (n / 4) * 8
            : batch->type == GLPrimitiveType::POLYGON_FILLED ? (n > 2 ? (n - 2) * 3 : 0) + n * 2
            : n * 2;
        if (estimate > maxVertices - estimatedVertices)
            throw std::length_error("Prepared GL geometry exceeds vertex index limit");
        estimatedVertices += estimate;
    }
    nextVertices.reserve(estimatedVertices);
    edges.reserve(std::min<size_t>(estimatedVertices / 2 + 64, 262144));
    triangles.reserve(512);
    nextCommands.reserve(std::min<size_t>(batches.size(), 4096));
    int primitiveCount = 0;
    int batchCount = 0;
    auto checkSize = [&]() {
        if (nextVertices.size() > maxVertices || edges.size() > maxVertices - nextVertices.size())
            throw std::length_error("Prepared GL geometry exceeds vertex index limit");
    };
    for (size_t begin = 0; begin < ordered.size();) {
        size_t end = begin + 1;
        const RenderBatch& style = *ordered[begin];
        while (end < ordered.size() && compatible(style, *ordered[end])) ++end;
        const size_t firstFill = nextVertices.size();
        edges.clear();
        for (size_t i = begin; i < end; ++i) {
            const RenderBatch& batch = *ordered[i];
            const size_t n = batch.vertexCount > 0
                ? std::min(batch.vertices.size(), static_cast<size_t>(batch.vertexCount)) : 0;
            if (n == 0) continue;
            if (batch.type == GLPrimitiveType::RECT_FILLED || batch.type == GLPrimitiveType::RECT_OUTLINE) {
                if (batch.type == GLPrimitiveType::RECT_FILLED)
                    appendRectangleTriangles(batch.vertices, n, nextVertices);
                primitiveCount += static_cast<int>(appendRectangleEdges(batch.vertices, n, edges));
            } else if (batch.type == GLPrimitiveType::LINE_STRIP) {
                triangles.clear();
                if (buildPathRibbon(batch.vertices, static_cast<int>(n), batch.pathWidth, triangles,
                                    batch.pathType, batch.pathBeginExtension, batch.pathEndExtension,
                                    scratchIndices)) {
                    nextVertices.insert(nextVertices.end(), triangles.begin(), triangles.end());
                } else {
                    for (size_t p = 1; p < n; ++p) {
                        edges.push_back(batch.vertices[p - 1]); edges.push_back(batch.vertices[p]);
                    }
                }
                ++primitiveCount;
            } else {
                if (batch.type == GLPrimitiveType::POLYGON_FILLED) {
                    triangles.clear();
                    if (triangulatePolygonCached(batch.vertices, static_cast<int>(n),
                                                 batch.triangleIndices, triangles)) {
                        nextVertices.insert(nextVertices.end(), triangles.begin(), triangles.end());
                    } else {
                        for (size_t p = 1; p + 1 < n; ++p) {
                            nextVertices.push_back(batch.vertices[0]);
                            nextVertices.push_back(batch.vertices[p]);
                            nextVertices.push_back(batch.vertices[p + 1]);
                        }
                    }
                }
                appendPolygonOutlineEdges(batch.vertices, n, edges, batch.mayHaveKeyholeBridge);
                ++primitiveCount;
            }
            checkSize();
        }
        auto emit = [&](bool fill, size_t first) {
            const size_t count = nextVertices.size() - first;
            if (count == 0) return;
            DrawCommand command{};
            command.mode = fill ? GL_TRIANGLES : GL_LINES;
            command.first = static_cast<GLint>(first);
            command.count = static_cast<GLsizei>(count);
            command.fill = fill;
            command.fillPattern = fill ? style.fillPattern : 0;
            std::copy(style.color, style.color + 4, command.color);
            if (fill) {
                command.color[3] = style.selected && style.type != GLPrimitiveType::LINE_STRIP
                    ? std::min(1.0f, style.color[3] + 0.1f) : style.color[3];
            } else if (!style.preserveOpacity && style.type != GLPrimitiveType::LINE_STRIP) {
                command.color[3] = std::min(1.0f, std::max(0.85f, style.color[3]));
                if (style.type == GLPrimitiveType::SELECTION_BOX) {
                    command.color[0] = 0.184f; command.color[1] = 0.427f;
                    command.color[2] = 0.965f; command.color[3] = 1.0f;
                }
            }
            nextCommands.push_back(command);
        };
        const size_t firstCommand = nextCommands.size();
        emit(true, firstFill);
        const size_t firstEdge = nextVertices.size();
        nextVertices.insert(nextVertices.end(), edges.begin(), edges.end());
        emit(false, firstEdge);
        if (nextCommands.size() != firstCommand) ++batchCount;
        begin = end;
    }
    cachedVertices_.swap(nextVertices);
    drawCommands_.swap(nextCommands);
    originX_ = std::isfinite(originX) ? originX : 0.0;
    originY_ = std::isfinite(originY) ? originY : 0.0;
    renderDataPublication_ = NextRenderDataPublication();
    preparedPrimitiveCount_ = primitiveCount;
    preparedBatchCount_ = batchCount;
    uploadPending_ = true;
    lastPrepareTime_ = std::chrono::duration<float, std::milli>(
        std::chrono::high_resolution_clock::now() - startTime).count();
}

void GLRenderer::drawCommandWithMvp(const DrawCommand& command, const float mvp[9]) {
    glUseProgram(command.fill ? shaderProgram_ : lineShaderProgram_);
    const GLint mvpLoc = command.fill ? mvpLocation_ : lineMvpLocation_;
    if (mvpLoc >= 0) glUniformMatrix3fv(mvpLoc, 1, GL_FALSE, mvp);
    glUniform4fv(command.fill ? colorLocation_ : lineColorLocation_, 1, command.color);
    if (command.fill && fillPatternLocation_ >= 0) {
        glUniform1i(fillPatternLocation_, command.fillPattern);
    }
    if (!command.fill) applyStrokeWidth(2.0f);
    glDrawArrays(command.mode, command.first, command.count);
}

void GLRenderer::drawCommand(const DrawCommand& command) {
    drawCommandWithMvp(command, mvpMatrix_);
}

} // namespace hongtu
