/**
 * HongTu EDA - High-Performance OpenGL ES 3.0 Renderer
 * Retained-mode rendering with:
 * - VBO batching (single draw call per layer)
 * - Frustum culling via spatial index
 * - Level-of-detail (LOD) simplification
 * - Hierarchical cell rendering with transform stack
 * - Stipple pattern fills (KLayout-style layer patterns)
 * - Anti-aliased lines (wide lines via geometry shader emulation)
 * - Text glyph rendering (bitmap font atlas)
 */
#ifndef HONGTU_GL_RENDERER_V2_H
#define HONGTU_GL_RENDERER_V2_H

#include <GLES3/gl3.h>
#include <vector>
#include <string>
#include <unordered_map>
#include <cmath>
#include "scene_graph.h"
#include "triangulator.h"
#include "spatial_index.h"

namespace hongtu {

// ==================== Shader Sources ====================

static const char* VERTEX_SHADER_SRC = R"(#version 300 es
precision highp float;

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec4 aColor;
layout(location = 2) in float aPattern;  // stipple pattern index

uniform mat3 uMVP;
uniform float uOpacity;

out vec4 vColor;
out float vPattern;
out vec2 vScreenPos;

void main() {
    vec3 pos = uMVP * vec3(aPosition, 1.0);
    gl_Position = vec4(pos.xy, 0.0, 1.0);
    vColor = aColor;
    vColor.a *= uOpacity;
    vPattern = aPattern;
    vScreenPos = pos.xy * 0.5 + 0.5;  // NDC to [0,1]
}
)";

static const char* FRAGMENT_SHADER_SRC = R"(#version 300 es
precision mediump float;

in vec4 vColor;
in float vPattern;
in vec2 vScreenPos;

uniform float uPatternScale;  // pixels per pattern cell

out vec4 fragColor;

// 8x8 stipple patterns (KLayout-style)
const uint patterns[18] = uint[18](
    0xFFFFFFFFu,  // 0: solid
    0x00000000u,  // 1: hollow
    0x55555555u,  // 2: horizontal lines
    0xAAAAAAAAu,  // 3: vertical lines (approx)
    0x0F0F0F0Fu,  // 4: grid
    0xF0F0F0F0u,  // 5: diagonal right
    0x33333333u,  // 6: diagonal left
    0xCCCCCCCCu,  // 7: cross-hatch
    0x88888888u,  // 8: dots sparse
    0x11111111u,  // 9: dots dense
    0x77777777u,  // 10: checker 2x2
    0xDDDDDDDDu,  // 11: checker 4x4
    0xEEEEEEEEu,  // 12: horizontal thick
    0x99999999u,  // 13: vertical thick
    0x66666666u,  // 14: diagonal sparse
    0xBBBBBBBBu,  // 15: triangle
    0xF1F1F1F1u,  // 16: zigzag
    0x18181818u   // 17: diamond
);

bool getPatternBit(int patternIdx, int x, int y) {
    if (patternIdx < 0 || patternIdx > 17) return true;
    uint p = patterns[patternIdx];
    int bit = (y * 8 + x) % 32;
    return ((p >> bit) & 1u) != 0u;
}

void main() {
    int patIdx = int(vPattern + 0.5);
    if (patIdx == 1) {
        // Hollow: discard interior
        discard;
    }
    if (patIdx > 1) {
        // Apply stipple pattern based on screen position
        vec2 screenCoord = vScreenPos * uPatternScale;
        int px = int(mod(screenCoord.x, 8.0));
        int py = int(mod(screenCoord.y, 8.0));
        if (!getPatternBit(patIdx, px, py)) {
            discard;
        }
    }
    fragColor = vColor;
}
)";

// Line shader (wide lines via screen-space expansion)
static const char* LINE_VERTEX_SHADER_SRC = R"(#version 300 es
precision highp float;

layout(location = 0) in vec2 aPosition;
layout(location = 1) in vec2 aDirection;  // line direction for width expansion
layout(location = 2) in float aSide;      // -1 or +1
layout(location = 3) in vec4 aColor;

uniform mat3 uMVP;
uniform float uLineWidth;
uniform vec2 uScreenSize;

out vec4 vColor;

void main() {
    vec3 pos = uMVP * vec3(aPosition, 1.0);
    // Expand line width in screen space
    vec2 dir = normalize((uMVP * vec3(aDirection, 0.0)).xy);
    vec2 normal = vec2(-dir.y, dir.x);
    vec2 offset = normal * aSide * uLineWidth / uScreenSize;
    pos.xy += offset;
    gl_Position = vec4(pos.xy, 0.0, 1.0);
    vColor = aColor;
}
)";

static const char* LINE_FRAGMENT_SHADER_SRC = R"(#version 300 es
precision mediump float;
in vec4 vColor;
out vec4 fragColor;
void main() {
    fragColor = vColor;
}
)";

// ==================== Render Structures ====================

struct RenderVertex {
    float x, y;           // Position (nm)
    float r, g, b, a;    // Color
    float pattern;        // Stipple pattern index
};

struct LineVertex {
    float x, y;
    float dx, dy;        // Direction
    float side;          // -1 or +1
    float r, g, b, a;
};

// Per-layer render batch (pre-triangulated, ready for VBO upload)
struct LayerRenderBatch {
    LayerKey layerKey;
    std::vector<RenderVertex> fillVertices;   // GL_TRIANGLES
    std::vector<LineVertex> lineVertices;     // Wide lines
    BBox bbox;                                 // Combined bbox for culling
    int shapeCount;
    bool dirty;  // Needs VBO re-upload

    LayerRenderBatch() : shapeCount(0), dirty(true) {}
};

// Camera state
struct Camera {
    double centerX = 0, centerY = 0;  // World center (nm)
    double scale = 1.0;                // Pixels per nm
    int viewportW = 1920, viewportH = 1080;

    BBox visibleBBox() const {
        double halfW = viewportW * 0.5 / scale;
        double halfH = viewportH * 0.5 / scale;
        return BBox(centerX - halfW, centerY - halfH, centerX + halfW, centerY + halfH);
    }

    void getMVP(float* mvp) const {
        // World (nm) → NDC [-1, 1]
        double sx = 2.0 * scale / viewportW;
        double sy = 2.0 * scale / viewportH;
        double tx = -centerX * sx;
        double ty = -centerY * sy;

        // Column-major 3x3 (for uniform upload)
        mvp[0] = (float)sx;  mvp[1] = 0;        mvp[2] = 0;
        mvp[3] = 0;          mvp[4] = (float)sy; mvp[5] = 0;
        mvp[6] = (float)tx;  mvp[7] = (float)ty; mvp[8] = 1;
    }
};

// Render statistics
struct RenderStatsV2 {
    int totalShapes = 0;
    int visibleShapes = 0;
    int culledShapes = 0;
    int drawCalls = 0;
    int totalVertices = 0;
    int totalTriangles = 0;
    float frameTimeMs = 0;
    float uploadTimeMs = 0;
    int vboCount = 0;
    size_t vboMemoryBytes = 0;
    int lodLevel = 0;
};

/**
 * GLRendererV2: High-performance retained-mode renderer.
 */
class GLRendererV2 {
public:
    GLRendererV2() : initialized_(false), layout_(nullptr) {}
    ~GLRendererV2() { cleanup(); }

    // ==================== Lifecycle ====================

    bool init(int viewportW, int viewportH) {
        if (initialized_) return true;

        camera_.viewportW = viewportW;
        camera_.viewportH = viewportH;

        // Compile shaders
        fillProgram_ = compileProgram(VERTEX_SHADER_SRC, FRAGMENT_SHADER_SRC);
        if (!fillProgram_) return false;

        lineProgram_ = compileProgram(LINE_VERTEX_SHADER_SRC, LINE_FRAGMENT_SHADER_SRC);
        if (!lineProgram_) return false;

        // Get uniform locations
        uMVP_ = glGetUniformLocation(fillProgram_, "uMVP");
        uOpacity_ = glGetUniformLocation(fillProgram_, "uOpacity");
        uPatternScale_ = glGetUniformLocation(fillProgram_, "uPatternScale");

        uLineMVP_ = glGetUniformLocation(lineProgram_, "uMVP");
        uLineWidth_ = glGetUniformLocation(lineProgram_, "uLineWidth");
        uScreenSize_ = glGetUniformLocation(lineProgram_, "uScreenSize");

        // Create VAO
        glGenVertexArrays(1, &vao_);

        // Enable blending
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

        initialized_ = true;
        return true;
    }

    void cleanup() {
        if (!initialized_) return;

        // Delete VBOs
        for (auto& [key, vbo] : layerVBOs_) {
            glDeleteBuffers(1, &vbo.fillVBO);
            if (vbo.lineVBO) glDeleteBuffers(1, &vbo.lineVBO);
        }
        layerVBOs_.clear();

        if (vao_) glDeleteVertexArrays(1, &vao_);
        if (fillProgram_) glDeleteProgram(fillProgram_);
        if (lineProgram_) glDeleteProgram(lineProgram_);

        initialized_ = false;
    }

    void setLayout(Layout* layout) {
        layout_ = layout;
        invalidateAll();
    }

    // ==================== Rendering ====================

    void render() {
        if (!initialized_ || !layout_) return;

        auto startTime = std::chrono::high_resolution_clock::now();

        glClearColor(0.05f, 0.05f, 0.08f, 1.0f);  // Dark background
        glClear(GL_COLOR_BUFFER_BIT);

        // Compute visible region
        BBox visible = camera_.visibleBBox();
        float mvp[9];
        camera_.getMVP(mvp);

        // Determine LOD level based on zoom
        int lodLevel = computeLOD();
        stats_.lodLevel = lodLevel;

        // Reset stats
        stats_.drawCalls = 0;
        stats_.totalVertices = 0;
        stats_.totalTriangles = 0;
        stats_.visibleShapes = 0;
        stats_.culledShapes = 0;

        // Render each visible layer
        auto layers = layout_->allLayers();
        for (const auto& layerKey : layers) {
            auto it = layout_->layerProps.find(layerKey);
            if (it == layout_->layerProps.end()) continue;
            const LayerProperties& lp = it->second;
            if (!lp.visible) continue;

            renderLayer(layerKey, lp, visible, mvp, lodLevel);
        }

        // Render selection overlay
        renderSelectionOverlay(mvp);

        auto endTime = std::chrono::high_resolution_clock::now();
        stats_.frameTimeMs = std::chrono::duration<float, std::milli>(endTime - startTime).count();
    }

    // ==================== Scene Update ====================

    /**
     * Rebuild render batches for a specific layer.
     * Called when shapes are added/removed/modified.
     */
    void invalidateLayer(const LayerKey& layerKey) {
        auto it = layerBatches_.find(layerKey);
        if (it != layerBatches_.end()) {
            it->second.dirty = true;
        } else {
            LayerRenderBatch batch;
            batch.layerKey = layerKey;
            batch.dirty = true;
            layerBatches_[layerKey] = std::move(batch);
        }
    }

    void invalidateAll() {
        for (auto& [key, batch] : layerBatches_) {
            batch.dirty = true;
        }
        needsFullRebuild_ = true;
    }

    /**
     * Full scene rebuild: re-triangulate all shapes.
     * Called after file load or major edit.
     */
    void rebuildScene() {
        layerBatches_.clear();

        if (!layout_) return;

        // Group shapes by layer and triangulate
        for (const auto& shape : layout_->shapes) {
            auto it = layout_->layerProps.find(shape.layerKey);
            if (it == layout_->layerProps.end()) continue;

            LayerRenderBatch& batch = layerBatches_[shape.layerKey];
            batch.layerKey = shape.layerKey;
            addShapeToBatch(shape, it->second, batch);
            batch.bbox = batch.bbox.unite(shape.bbox());
            batch.shapeCount++;
        }

        // Mark all for VBO upload
        for (auto& [key, batch] : layerBatches_) {
            batch.dirty = true;
        }

        needsFullRebuild_ = false;
        stats_.totalShapes = (int)layout_->shapes.size();
    }

    // ==================== Camera ====================

    void setCamera(double centerX, double centerY, double scale) {
        camera_.centerX = centerX;
        camera_.centerY = centerY;
        camera_.scale = scale;
    }

    void setViewport(int w, int h) {
        camera_.viewportW = w;
        camera_.viewportH = h;
        glViewport(0, 0, w, h);
    }

    Camera& camera() { return camera_; }
    const Camera& camera() const { return camera_; }

    void fitToContent(const BBox& contentBBox) {
        if (!contentBBox.valid()) return;
        double w = contentBBox.maxX - contentBBox.minX;
        double h = contentBBox.maxY - contentBBox.minY;
        if (w < 1e-6 || h < 1e-6) return;

        camera_.centerX = (contentBBox.minX + contentBBox.maxX) * 0.5;
        camera_.centerY = (contentBBox.minY + contentBBox.maxY) * 0.5;

        double scaleX = camera_.viewportW * 0.9 / w;
        double scaleY = camera_.viewportH * 0.9 / h;
        camera_.scale = std::min(scaleX, scaleY);
    }

    // ==================== Selection ====================

    void setSelection(const std::vector<int64_t>& selectedIds) {
        selectedIds_ = selectedIds;
    }

    void clearSelection() {
        selectedIds_.clear();
    }

    // ==================== Stats ====================

    const RenderStatsV2& stats() const { return stats_; }

private:
    bool initialized_;
    Layout* layout_;
    Camera camera_;
    RenderStatsV2 stats_;

    GLuint fillProgram_ = 0;
    GLuint lineProgram_ = 0;
    GLuint vao_ = 0;

    GLint uMVP_ = -1, uOpacity_ = -1, uPatternScale_ = -1;
    GLint uLineMVP_ = -1, uLineWidth_ = -1, uScreenSize_ = -1;

    std::unordered_map<LayerKey, LayerRenderBatch, LayerKeyHash> layerBatches_;

    struct LayerVBO {
        GLuint fillVBO = 0;
        GLuint lineVBO = 0;
        int fillVertexCount = 0;
        int lineVertexCount = 0;
    };
    std::unordered_map<LayerKey, LayerVBO, LayerKeyHash> layerVBOs_;

    std::vector<int64_t> selectedIds_;
    bool needsFullRebuild_ = true;

    // ==================== Shape Tessellation ====================

    void addShapeToBatch(const SceneShape& shape, const LayerProperties& lp,
                        LayerRenderBatch& batch) {
        float r = ((lp.fillColor >> 24) & 0xFF) / 255.0f;
        float g = ((lp.fillColor >> 16) & 0xFF) / 255.0f;
        float b = ((lp.fillColor >> 8) & 0xFF) / 255.0f;
        float a = lp.transparency;
        float pattern = (float)lp.fillPattern;

        switch (shape.type) {
            case ShapeType::RECT:
            case ShapeType::BOX:
            case ShapeType::POLYGON: {
                // Triangulate polygon
                std::vector<Vec2> poly;
                poly.reserve(shape.points.size());
                for (const auto& p : shape.points) {
                    poly.push_back(p);
                }
                // Remove duplicate closing point
                if (poly.size() > 1 &&
                    std::abs(poly.front().x - poly.back().x) < 1e-6 &&
                    std::abs(poly.front().y - poly.back().y) < 1e-6) {
                    poly.pop_back();
                }

                auto triVerts = Triangulator::triangulateToVertices(poly);
                for (size_t i = 0; i + 1 < triVerts.size(); i += 2) {
                    RenderVertex v;
                    v.x = triVerts[i];
                    v.y = triVerts[i + 1];
                    v.r = r; v.g = g; v.b = b; v.a = a;
                    v.pattern = pattern;
                    batch.fillVertices.push_back(v);
                }

                // Add outline for line rendering
                addOutlineToBatch(shape.points, lp, batch);
                break;
            }

            case ShapeType::PATH: {
                if (shape.points.size() >= 2 && shape.pathWidth > 0) {
                    std::vector<Vec2> pathPts;
                    pathPts.reserve(shape.points.size());
                    for (const auto& p : shape.points) {
                        pathPts.push_back(p);
                    }

                    bool roundCaps = (shape.pathType == 1);
                    auto pathVerts = Triangulator::triangulatePath(pathPts, shape.pathWidth, roundCaps);
                    for (size_t i = 0; i + 1 < pathVerts.size(); i += 2) {
                        RenderVertex v;
                        v.x = pathVerts[i];
                        v.y = pathVerts[i + 1];
                        v.r = r; v.g = g; v.b = b; v.a = a;
                        v.pattern = pattern;
                        batch.fillVertices.push_back(v);
                    }
                }
                break;
            }

            case ShapeType::TEXT: {
                // Render text as bounding box outline (glyph rendering is separate)
                if (!shape.points.empty()) {
                    BBox box = shape.bbox();
                    std::vector<Vec2> rect = {
                        {box.minX, box.minY}, {box.maxX, box.minY},
                        {box.maxX, box.maxY}, {box.minX, box.maxY}
                    };
                    // Add as line outline
                    for (int i = 0; i < 4; i++) {
                        int j = (i + 1) % 4;
                        addLineSegment(rect[i], rect[j], lp, batch);
                    }
                }
                break;
            }

            case ShapeType::INSTANCE: {
                // Instance bbox outline
                BBox box = shape.bbox();
                if (box.valid()) {
                    std::vector<Vec2> rect = {
                        {box.minX, box.minY}, {box.maxX, box.minY},
                        {box.maxX, box.maxY}, {box.minX, box.maxY}
                    };
                    for (int i = 0; i < 4; i++) {
                        int j = (i + 1) % 4;
                        addLineSegment(rect[i], rect[j], lp, batch);
                    }
                }
                break;
            }

            default:
                break;
        }
    }

    void addOutlineToBatch(const std::vector<Vec2>& points,
                          const LayerProperties& lp, LayerRenderBatch& batch) {
        float r = ((lp.lineColor >> 24) & 0xFF) / 255.0f;
        float g = ((lp.lineColor >> 16) & 0xFF) / 255.0f;
        float b = ((lp.lineColor >> 8) & 0xFF) / 255.0f;
        float a = 0.8f;

        int n = (int)points.size();
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            addLineSegment(points[i], points[j], lp, batch);
        }
    }

    void addLineSegment(const Vec2& p0, const Vec2& p1,
                       const LayerProperties& lp, LayerRenderBatch& batch) {
        float r = ((lp.lineColor >> 24) & 0xFF) / 255.0f;
        float g = ((lp.lineColor >> 16) & 0xFF) / 255.0f;
        float b = ((lp.lineColor >> 8) & 0xFF) / 255.0f;
        float a = 0.9f;

        Vec2 dir = p1 - p0;
        double len = dir.length();
        if (len < 1e-12) return;
        dir.x /= len; dir.y /= len;

        // Two vertices per endpoint (for width expansion in shader)
        LineVertex v0, v1;
        v0.x = (float)p0.x; v0.y = (float)p0.y;
        v0.dx = (float)dir.x; v0.dy = (float)dir.y;
        v0.r = r; v0.g = g; v0.b = b; v0.a = a;

        v1.x = (float)p1.x; v1.y = (float)p1.y;
        v1.dx = (float)dir.x; v1.dy = (float)dir.y;
        v1.r = r; v1.g = g; v1.b = b; v1.a = a;

        // Side -1
        v0.side = -1.0f;
        v1.side = -1.0f;
        batch.lineVertices.push_back(v0);
        batch.lineVertices.push_back(v1);

        // Side +1
        v0.side = 1.0f;
        v1.side = 1.0f;
        batch.lineVertices.push_back(v0);
        batch.lineVertices.push_back(v1);
    }

    // ==================== Layer Rendering ====================

    void renderLayer(const LayerKey& layerKey, const LayerProperties& lp,
                    const BBox& visible, const float* mvp, int lodLevel) {
        // Check if layer has any visible content
        auto batchIt = layerBatches_.find(layerKey);
        if (batchIt == layerBatches_.end()) return;

        LayerRenderBatch& batch = batchIt->second;

        // Frustum culling: skip if layer bbox doesn't intersect viewport
        if (batch.bbox.valid() && !batch.bbox.intersects(visible)) {
            stats_.culledShapes += batch.shapeCount;
            return;
        }

        // Upload VBO if dirty
        if (batch.dirty) {
            uploadLayerVBO(layerKey, batch);
            batch.dirty = false;
        }

        auto vboIt = layerVBOs_.find(layerKey);
        if (vboIt == layerVBOs_.end()) return;

        LayerVBO& vbo = vboIt->second;

        // Draw fill
        if (vbo.fillVertexCount > 0) {
            glUseProgram(fillProgram_);
            glUniformMatrix3fv(uMVP_, 1, GL_FALSE, mvp);
            glUniform1f(uOpacity_, lp.transparency);
            glUniform1f(uPatternScale_, (float)std::max(camera_.viewportW, camera_.viewportH));

            glBindVertexArray(vao_);
            glBindBuffer(GL_ARRAY_BUFFER, vbo.fillVBO);

            // Vertex attributes: position(2f) + color(4f) + pattern(1f) = 7 floats
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)0);
            glEnableVertexAttribArray(1);
            glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)(2 * sizeof(float)));
            glEnableVertexAttribArray(2);
            glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)(6 * sizeof(float)));

            glDrawArrays(GL_TRIANGLES, 0, vbo.fillVertexCount);

            stats_.drawCalls++;
            stats_.totalVertices += vbo.fillVertexCount;
            stats_.totalTriangles += vbo.fillVertexCount / 3;
        }

        // Draw lines
        if (vbo.lineVertexCount > 0) {
            glUseProgram(lineProgram_);
            glUniformMatrix3fv(uLineMVP_, 1, GL_FALSE, mvp);
            glUniform1f(uLineWidth_, lp.lineWidth);
            glUniform2f(uScreenSize_, (float)camera_.viewportW, (float)camera_.viewportH);

            glBindVertexArray(vao_);
            glBindBuffer(GL_ARRAY_BUFFER, vbo.lineVBO);

            // LineVertex: pos(2f) + dir(2f) + side(1f) + color(4f) = 9 floats
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(LineVertex), (void*)0);
            glEnableVertexAttribArray(1);
            glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(LineVertex), (void*)(2 * sizeof(float)));
            glEnableVertexAttribArray(2);
            glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, sizeof(LineVertex), (void*)(4 * sizeof(float)));
            glEnableVertexAttribArray(3);
            glVertexAttribPointer(3, 4, GL_FLOAT, GL_FALSE, sizeof(LineVertex), (void*)(5 * sizeof(float)));

            glDrawArrays(GL_LINES, 0, vbo.lineVertexCount);

            stats_.drawCalls++;
            stats_.totalVertices += vbo.lineVertexCount;
        }

        stats_.visibleShapes += batch.shapeCount;
        glBindVertexArray(0);
    }

    void renderSelectionOverlay(const float* mvp) {
        if (selectedIds_.empty() || !layout_) return;

        // Draw selection highlight (bright outline)
        glUseProgram(fillProgram_);
        glUniformMatrix3fv(uMVP_, 1, GL_FALSE, mvp);
        glUniform1f(uOpacity_, 0.3f);
        glUniform1f(uPatternScale_, (float)camera_.viewportW);

        // Build selection vertices on-the-fly (small set)
        std::vector<RenderVertex> selVerts;
        for (int64_t id : selectedIds_) {
            SceneShape* shape = layout_->findShape(id);
            if (!shape) continue;

            BBox box = shape->bbox();
            if (!box.valid()) continue;

            // Highlight rectangle
            float r = 1.0f, g = 1.0f, b = 0.0f, a = 0.3f;
            std::vector<Vec2> rect = {
                {box.minX, box.minY}, {box.maxX, box.minY},
                {box.maxX, box.maxY}, {box.minX, box.maxY}
            };
            auto tris = Triangulator::triangulateToVertices(rect);
            for (size_t i = 0; i + 1 < tris.size(); i += 2) {
                RenderVertex v;
                v.x = tris[i]; v.y = tris[i+1];
                v.r = r; v.g = g; v.b = b; v.a = a;
                v.pattern = 0;
                selVerts.push_back(v);
            }
        }

        if (selVerts.empty()) return;

        GLuint selVBO;
        glGenBuffers(1, &selVBO);
        glBindBuffer(GL_ARRAY_BUFFER, selVBO);
        glBufferData(GL_ARRAY_BUFFER, selVerts.size() * sizeof(RenderVertex),
                    selVerts.data(), GL_STREAM_DRAW);

        glBindVertexArray(vao_);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 4, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)(2 * sizeof(float)));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, sizeof(RenderVertex), (void*)(6 * sizeof(float)));

        glDrawArrays(GL_TRIANGLES, 0, (GLsizei)selVerts.size());

        glDeleteBuffers(1, &selVBO);
        glBindVertexArray(0);
        stats_.drawCalls++;
    }

    // ==================== VBO Management ====================

    void uploadLayerVBO(const LayerKey& layerKey, const LayerRenderBatch& batch) {
        LayerVBO& vbo = layerVBOs_[layerKey];

        // Fill VBO
        if (!batch.fillVertices.empty()) {
            if (!vbo.fillVBO) glGenBuffers(1, &vbo.fillVBO);
            glBindBuffer(GL_ARRAY_BUFFER, vbo.fillVBO);
            glBufferData(GL_ARRAY_BUFFER,
                        batch.fillVertices.size() * sizeof(RenderVertex),
                        batch.fillVertices.data(), GL_STATIC_DRAW);
            vbo.fillVertexCount = (int)batch.fillVertices.size();
        } else {
            vbo.fillVertexCount = 0;
        }

        // Line VBO
        if (!batch.lineVertices.empty()) {
            if (!vbo.lineVBO) glGenBuffers(1, &vbo.lineVBO);
            glBindBuffer(GL_ARRAY_BUFFER, vbo.lineVBO);
            glBufferData(GL_ARRAY_BUFFER,
                        batch.lineVertices.size() * sizeof(LineVertex),
                        batch.lineVertices.data(), GL_STATIC_DRAW);
            vbo.lineVertexCount = (int)batch.lineVertices.size();
        } else {
            vbo.lineVertexCount = 0;
        }

        stats_.vboMemoryBytes += batch.fillVertices.size() * sizeof(RenderVertex) +
                                 batch.lineVertices.size() * sizeof(LineVertex);
    }

    // ==================== LOD ====================

    int computeLOD() const {
        // LOD based on pixels-per-nm
        // Level 0: full detail (scale > 0.1 px/nm)
        // Level 1: simplified (scale > 0.01)
        // Level 2: bbox only (scale > 0.001)
        // Level 3: dots only (scale <= 0.001)
        double s = camera_.scale;
        if (s > 0.1) return 0;
        if (s > 0.01) return 1;
        if (s > 0.001) return 2;
        return 3;
    }

    // ==================== Shader Compilation ====================

    GLuint compileShader(GLenum type, const char* source) {
        GLuint shader = glCreateShader(type);
        glShaderSource(shader, 1, &source, nullptr);
        glCompileShader(shader);

        GLint compiled;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled) {
            char log[512];
            glGetShaderInfoLog(shader, sizeof(log), nullptr, log);
            // Log error (would use HiLog in production)
            glDeleteShader(shader);
            return 0;
        }
        return shader;
    }

    GLuint compileProgram(const char* vertSrc, const char* fragSrc) {
        GLuint vert = compileShader(GL_VERTEX_SHADER, vertSrc);
        GLuint frag = compileShader(GL_FRAGMENT_SHADER, fragSrc);
        if (!vert || !frag) return 0;

        GLuint program = glCreateProgram();
        glAttachShader(program, vert);
        glAttachShader(program, frag);
        glLinkProgram(program);

        GLint linked;
        glGetProgramiv(program, GL_LINK_STATUS, &linked);
        if (!linked) {
            char log[512];
            glGetProgramInfoLog(program, sizeof(log), nullptr, log);
            glDeleteProgram(program);
            return 0;
        }

        glDeleteShader(vert);
        glDeleteShader(frag);
        return program;
    }
};

} // namespace hongtu

#endif // HONGTU_GL_RENDERER_V2_H
