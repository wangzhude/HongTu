#ifndef HONGTU_HIERARCHY_RENDER_BATCHES_H
#define HONGTU_HIERARCHY_RENDER_BATCHES_H

#include "scene_graph.h"
#include "gl_renderer.h"
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <unordered_set>

namespace hongtu {

struct HierarchyLayerStyle {
    bool visible = true;
    bool strokeOnly = false;
    int fillPattern = 0;
    std::array<float, 4> color = {{0.18f, 0.43f, 0.96f, 0.62f}};
};
using HierarchyLayerStyles = std::unordered_map<LayerKey, HierarchyLayerStyle, LayerKeyHash>;

struct HierarchyRenderSource {
    GeometryEngine::Transform2D transform;
    double opacity = 1;
    int sourceOrder = 0;
};

/** Camera-Relative 双精度批次局部参考原点（世界坐标 nm，通常取当前裁剪视口中心） */
struct HierarchyRenderOrigin {
    double x = 0.0;
    double y = 0.0;
};

// Shared across every source: exceeding a limit rejects the whole unpublished scene.
struct HierarchyRenderBudget {
    size_t primitives = 0, vertices = 0;
    size_t maxPrimitives = 2500000, maxVertices = 16000000;
    void consume(size_t points) {
        if (primitives >= maxPrimitives || points > maxVertices - vertices)
            throw std::length_error("Composite scene exceeds aggregate visible geometry budget (2500000 primitives / 16000000 vertices)");
        ++primitives; vertices += points;
    }
};

inline GeometryEngine::Transform2D HierarchyExplicitInverse(const GeometryEngine::Transform2D& t) {
    for (double value : {t.a, t.b, t.c, t.d, t.tx, t.ty})
        if (!std::isfinite(value)) throw std::invalid_argument("Composite source requires six finite affine coefficients");
    const double determinant = t.determinant();
    if (!std::isfinite(determinant) || determinant == 0)
        throw std::invalid_argument("Composite source requires a finite nonzero affine determinant");
    GeometryEngine::Transform2D inverse;
    // Divide each numerator directly. A reciprocal can overflow even when every
    // actual inverse coefficient is finite (e.g. a=d=1e-160, det~=1e-320).
    inverse.a = t.d / determinant; inverse.b = -t.b / determinant;
    inverse.c = -t.c / determinant; inverse.d = t.a / determinant;
    // Use the same numerator/division sequence as the shared ETS contract.
    // Algebraically regrouping these terms changes overflow acceptance.
    inverse.tx = (t.b * t.ty - t.d * t.tx) / determinant;
    inverse.ty = (t.c * t.tx - t.a * t.ty) / determinant;
    for (double value : {inverse.a, inverse.b, inverse.c, inverse.d, inverse.tx, inverse.ty})
        if (!std::isfinite(value)) throw std::invalid_argument("Composite source requires six finite inverse affine coefficients");
    return inverse;
}

inline void ValidateHierarchyRenderSource(const HierarchyRenderSource& source) {
    if (!std::isfinite(source.opacity) || source.opacity < 0 || source.opacity > 1 || source.sourceOrder < 0)
        throw std::invalid_argument("Composite source requires opacity in 0..1 and a valid source order");
    HierarchyExplicitInverse(source.transform);
}

inline BBox HierarchyInverseViewport(const BBox& viewport, const GeometryEngine::Transform2D& transform) {
    const auto inverse = HierarchyExplicitInverse(transform);
    BBox result;
    for (const Vec2 point : {Vec2{viewport.minX, viewport.minY}, Vec2{viewport.maxX, viewport.minY},
                            Vec2{viewport.maxX, viewport.maxY}, Vec2{viewport.minX, viewport.maxY}}) {
        const auto local = inverse.apply(point);
        if (!std::isfinite(local.x) || !std::isfinite(local.y))
            throw std::invalid_argument("Composite source inverse viewport is not finite");
        result = result.unite(BBox(local.x, local.y, local.x, local.y));
    }
    return result;
}

inline const char* HierarchyPrimitiveName(GLPrimitiveType type) {
    switch (type) {
        case GLPrimitiveType::RECT_FILLED: return "rectFilled";
        case GLPrimitiveType::RECT_OUTLINE: return "rectOutline";
        case GLPrimitiveType::POLYGON_FILLED: return "polygonFilled";
        case GLPrimitiveType::POLYGON_OUTLINE: return "polygonOutline";
        case GLPrimitiveType::LINE_STRIP: return "lineStrip";
        case GLPrimitiveType::SELECTION_BOX: return "selectionBox";
    }
    return "polygonFilled";
}

inline uint64_t HashRelativeContourTemplate(const std::vector<Vec2>& pts) {
    if (pts.size() < 3) return 0;
    uint64_t h = 1469598103934665603ULL ^ static_cast<uint64_t>(pts.size());
    const double x0 = pts[0].x;
    const double y0 = pts[0].y;
    for (size_t i = 1; i < pts.size(); ++i) {
        const int64_t qx = static_cast<int64_t>(std::llround((pts[i].x - x0) * 16.0));
        const int64_t qy = static_cast<int64_t>(std::llround((pts[i].y - y0) * 16.0));
        h ^= static_cast<uint64_t>(qx) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
        h *= 1099511628211ULL;
        h ^= static_cast<uint64_t>(qy) + 0x9e3779b97f4a7c15ULL + (h << 6) + (h >> 2);
        h *= 1099511628211ULL;
    }
    return h;
}

inline bool SameRelativeContourTemplate(const std::vector<Vec2>& a, const std::vector<Vec2>& b) {
    if (a.size() != b.size() || a.empty()) return false;
    const double ax0 = a[0].x, ay0 = a[0].y;
    const double bx0 = b[0].x, by0 = b[0].y;
    for (size_t i = 1; i < a.size(); ++i) {
        if (std::fabs((a[i].x - ax0) - (b[i].x - bx0)) > 1e-6 ||
            std::fabs((a[i].y - ay0) - (b[i].y - by0)) > 1e-6) {
            return false;
        }
    }
    return true;
}

/** Shared geometry for both JS-batch compatibility and direct surface submission.
 * Includes KLayout-style screen-space sub-pixel LOD proxy, half-pixel overdraw culling,
 * relative-contour triangulation template reuse across flat repeated shapes, and
 * unexpanded child instance bounding-box outlines.
 */
inline std::vector<RenderBatch> BuildHierarchyRenderBatches(const Layout& layout, int cellId, int hierarchyDepth,
    const BBox* viewport = nullptr, const HierarchyLayerStyles* styles = nullptr,
    const HierarchyRenderSource* source = nullptr, HierarchyRenderBudget* budget = nullptr,
    const HierarchyRenderOrigin* origin = nullptr) {
    std::vector<RenderBatch> batches;
    std::unordered_map<uint64_t, size_t> mergeIndex;
    const HierarchyLayerStyle defaultStyle;
    const double originX = (origin && std::isfinite(origin->x)) ? origin->x : 0.0;
    const double originY = (origin && std::isfinite(origin->y)) ? origin->y : 0.0;
    BBox localViewport;
    const BBox* traversalViewport = viewport;
    if (source) {
        ValidateHierarchyRenderSource(*source);
        if (source->opacity == 0) return batches;
        if (viewport) { localViewport = HierarchyInverseViewport(*viewport, source->transform); traversalViewport = &localViewport; }
    }

    // An all-hidden layer table is a successful empty submission, not a fallback.
    // Check stored leaves and instances once before potentially expanding large arrays.
    if (styles) {
        bool visibleGeometry = !layout.instances.empty();
        if (!visibleGeometry) {
            for (const auto& shape : layout.shapes) {
                if (shape.type == ShapeType::INSTANCE || shape.type == ShapeType::NODE) continue;
                const auto found = styles->find(shape.layerKey);
                if (found == styles->end() || found->second.visible) { visibleGeometry = true; break; }
            }
        }
        if (!visibleGeometry) return batches;
    }

    // Conservative screen-space pixel span (nm per pixel on a 3200px reference viewport).
    double pixelSpanNm = 0.0;
    if (viewport && viewport->valid()) {
        const double span = std::max((viewport->maxX - viewport->minX), (viewport->maxY - viewport->minY));
        if (std::isfinite(span) && span > 0.0) {
            pixelSpanNm = span / 3200.0;
        }
    }
    const double subpixelCellNm = pixelSpanNm > 0.0 ? std::max(1e-6, 0.5 * pixelSpanNm) : 0.0;

    // Half-pixel occupancy set per (layer, datatype, gx, gy) to eliminate millions of
    // redundant sub-pixel photonic-crystal / array overdraws at wafer-level zoom.
    std::unordered_set<uint64_t> subpixelOccupied;

    struct CachedShapeGeometry {
        std::vector<Vec2> localPoints;
        std::vector<uint32_t> triangleIndices;
        BBox localBox;
        bool contourReady = false;
        bool triangulationAttempted = false;
        bool triangulated = false;
    };
    std::unordered_map<const SceneShape*, CachedShapeGeometry> shapeCache;

    struct RelativeTemplateEntry {
        const std::vector<Vec2>* samplePoints = nullptr;
        std::vector<uint32_t> triangleIndices;
        bool triangulated = false;
    };
    std::unordered_map<uint64_t, std::vector<RelativeTemplateEntry>> relativeTemplates;

    auto validateWorldCoord = [&](double wx, double wy) {
        if (!std::isfinite(wx) || !std::isfinite(wy) ||
            std::abs(wx) > std::numeric_limits<float>::max() ||
            std::abs(wy) > std::numeric_limits<float>::max())
            throw std::runtime_error("Hierarchy render contains non-finite/out-of-range coordinates");
        const double relX = wx - originX;
        const double relY = wy - originY;
        if (!std::isfinite(relX) || !std::isfinite(relY) ||
            std::abs(relX) > std::numeric_limits<float>::max() ||
            std::abs(relY) > std::numeric_limits<float>::max())
            throw std::runtime_error("Hierarchy render contains non-finite/out-of-range coordinates");
    };

    auto getOrCreateMergedRectBatch = [&](GLPrimitiveType rectType, int16_t layer, int16_t datatype,
                                          int fillPattern, const std::array<float, 4>& baseColor,
                                          uint16_t tag = 0) -> RenderBatch& {
        const uint64_t key = (uint64_t(tag) << 56) |
            (uint64_t(uint8_t(fillPattern)) << 48) |
            (uint64_t(rectType) << 32) |
            (uint64_t(uint16_t(layer)) << 16) |
            uint16_t(datatype);
        const auto found = mergeIndex.find(key);
        if (found != mergeIndex.end()) {
            return batches[found->second];
        }
        mergeIndex[key] = batches.size();
        RenderBatch batch{};
        batch.type = rectType;
        batch.layerNumber = layer;
        batch.datatype = datatype;
        batch.fillPattern = fillPattern;
        std::copy(baseColor.begin(), baseColor.end(), batch.color);
        if (source) {
            batch.sourceOrder = source->sourceOrder;
            batch.preserveOpacity = true;
            batch.color[3] *= static_cast<float>(source->opacity);
        }
        batches.push_back(std::move(batch));
        return batches.back();
    };

    auto appendAxisAlignedBox = [&](RenderBatch& target, double minX, double minY, double maxX, double maxY) {
        validateWorldCoord(minX, minY);
        validateWorldCoord(maxX, maxY);
        if (budget) budget->consume(4);
        const float x0 = static_cast<float>(minX - originX);
        const float y0 = static_cast<float>(minY - originY);
        const float x1 = static_cast<float>(maxX - originX);
        const float y1 = static_cast<float>(maxY - originY);
        target.vertices.push_back({x0, y0});
        target.vertices.push_back({x1, y0});
        target.vertices.push_back({x1, y1});
        target.vertices.push_back({x0, y1});
        if (target.vertices.size() > size_t(std::numeric_limits<int>::max()))
            throw std::runtime_error("Hierarchy render vertex count exceeds renderer range");
        target.vertexCount = static_cast<int>(target.vertices.size());
    };

    std::function<void(const BBox&)> onStoppedInstanceBox = [&](const BBox& localBox) {
        if (!localBox.valid()) return;
        BBox worldBox;
        if (source) {
            for (const Vec2 c : {Vec2{localBox.minX, localBox.minY}, Vec2{localBox.maxX, localBox.minY},
                                 Vec2{localBox.maxX, localBox.maxY}, Vec2{localBox.minX, localBox.maxY}}) {
                const Vec2 w = source->transform.apply(c);
                if (!std::isfinite(w.x) || !std::isfinite(w.y)) return;
                worldBox = worldBox.unite(BBox(w.x, w.y, w.x, w.y));
            }
        } else {
            worldBox = localBox;
        }
        if (!worldBox.valid()) return;
        if (viewport && !worldBox.intersects(*viewport)) return;
        if (pixelSpanNm > 0.0 && std::max((worldBox.maxX - worldBox.minX), (worldBox.maxY - worldBox.minY)) < 0.75 * pixelSpanNm) return;
        static const std::array<float, 4> frameColor = {{0.506f, 0.573f, 0.651f, 0.55f}};
        RenderBatch& frameBatch = getOrCreateMergedRectBatch(GLPrimitiveType::RECT_OUTLINE, 0, 0, 0, frameColor, 1);
        appendAxisAlignedBox(frameBatch, worldBox.minX, worldBox.minY, worldBox.maxX, worldBox.maxY);
    };

    layout.flattenHierarchy(cellId, hierarchyDepth,
        [&](const SceneShape& shape, const GeometryEngine::Transform2D& transform) {
            if (shape.type == ShapeType::NODE || shape.type == ShapeType::TEXT) return;
            const HierarchyLayerStyle* style = &defaultStyle;
            if (styles) {
                const auto found = styles->find(shape.layerKey);
                if (found != styles->end()) style = &found->second;
                if (!style->visible) return;
            }

            const bool cacheableShape =
                (shape.type == ShapeType::POLYGON && shape.points.size() >= 3) ||
                (shape.type == ShapeType::PATH && !shape.pathWidthAbsolute);
            CachedShapeGeometry* cachedGeom = nullptr;

            // Fast pre-transform bounding-box cull & KLayout sub-pixel proxy before transforming N vertices.
            if (cacheableShape) {
                cachedGeom = &shapeCache[&shape];
                if (!cachedGeom->contourReady) {
                    cachedGeom->localPoints = (shape.type == ShapeType::PATH)
                        ? effectivePolygon(shape)
                        : shape.points;
                    for (const auto& lp : cachedGeom->localPoints) {
                        if (std::isfinite(lp.x) && std::isfinite(lp.y)) {
                            cachedGeom->localBox = cachedGeom->localBox.unite(BBox(lp.x, lp.y, lp.x, lp.y));
                        }
                    }
                    cachedGeom->contourReady = true;
                }
                if (cachedGeom->localPoints.empty()) return;

                if (viewport && cachedGeom->localBox.valid()) {
                    BBox approxWorldBox;
                    bool approxFinite = true;
                    const BBox& lb = cachedGeom->localBox;
                    for (const Vec2 corner : {Vec2{lb.minX, lb.minY}, Vec2{lb.maxX, lb.minY},
                                              Vec2{lb.maxX, lb.maxY}, Vec2{lb.minX, lb.maxY}}) {
                        Vec2 wp = transform.apply(corner);
                        if (source) wp = source->transform.apply(wp);
                        if (!std::isfinite(wp.x) || !std::isfinite(wp.y)) {
                            approxFinite = false;
                            break;
                        }
                        approxWorldBox = approxWorldBox.unite(BBox(wp.x, wp.y, wp.x, wp.y));
                    }
                    if (approxFinite && approxWorldBox.valid()) {
                        if (!approxWorldBox.intersects(*viewport)) return;

                        const double maxDim = std::max((approxWorldBox.maxX - approxWorldBox.minX), (approxWorldBox.maxY - approxWorldBox.minY));
                        if (pixelSpanNm > 0.0 && maxDim <= 1.6 * pixelSpanNm && cachedGeom->localPoints.size() > 4) {
                            const double cx = 0.5 * (approxWorldBox.minX + approxWorldBox.maxX);
                            const double cy = 0.5 * (approxWorldBox.minY + approxWorldBox.maxY);
                            if (subpixelCellNm > 0.0 && maxDim <= 0.85 * pixelSpanNm) {
                                const int64_t gx = static_cast<int64_t>(std::floor((cx - originX) / subpixelCellNm));
                                const int64_t gy = static_cast<int64_t>(std::floor((cy - originY) / subpixelCellNm));
                                uint64_t cellKey = (uint64_t(uint16_t(shape.layerKey.layer)) << 48) |
                                                   (uint64_t(uint16_t(shape.layerKey.datatype)) << 32) |
                                                   ((uint64_t(uint32_t(gx)) * 2654435761ULL) ^ uint64_t(uint32_t(gy)));
                                if (!subpixelOccupied.insert(cellKey).second) {
                                    return;
                                }
                            }
                            const double minHalf = 0.38 * pixelSpanNm;
                            const double halfW = std::max(0.5 * (approxWorldBox.maxX - approxWorldBox.minX), minHalf);
                            const double halfH = std::max(0.5 * (approxWorldBox.maxY - approxWorldBox.minY), minHalf);
                            const GLPrimitiveType proxyType = (style->strokeOnly && style->fillPattern == 0)
                                ? GLPrimitiveType::RECT_OUTLINE
                                : GLPrimitiveType::RECT_FILLED;
                            RenderBatch& proxyBatch = getOrCreateMergedRectBatch(
                                proxyType, shape.layerKey.layer, shape.layerKey.datatype,
                                style->fillPattern, style->color, 0);
                            appendAxisAlignedBox(proxyBatch, cx - halfW, cy - halfH, cx + halfW, cy + halfH);
                            return;
                        }
                    }
                }
            }

            std::vector<Vec2> points;
            if ((shape.type == ShapeType::RECT || shape.type == ShapeType::BOX) && shape.points.size() == 2) {
                const auto& a = shape.points[0]; const auto& b = shape.points[1];
                points = transform.applyToPolygon({{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, b.y}});
            } else if (cachedGeom != nullptr) {
                points = transform.applyToPolygon(cachedGeom->localPoints);
            } else {
                points = shape.type == ShapeType::PATH
                    ? effectivePolygonTransformed(shape, transform) : transform.applyToPolygon(shape.points);
            }
            if (points.empty()) return;

            if (source) points = source->transform.applyToPolygon(points);
            BBox box;
            for (const auto& point : points) {
                validateWorldCoord(point.x, point.y);
                box = box.unite(BBox(point.x, point.y, point.x, point.y));
            }
            if (viewport && !box.intersects(*viewport)) return;

            // Screen-space sub-pixel chord decimation for dense curved polygons/rings at any zoom.
            bool decimated = false;
            if (pixelSpanNm > 0.0 && points.size() >= 24) {
                const double minChordSq = (0.50 * pixelSpanNm) * (0.50 * pixelSpanNm);
                std::vector<Vec2> simplified;
                simplified.reserve(points.size());
                simplified.push_back(points[0]);
                for (size_t i = 1; i + 1 < points.size(); ++i) {
                    const double dx = points[i].x - simplified.back().x;
                    const double dy = points[i].y - simplified.back().y;
                    if (dx * dx + dy * dy >= minChordSq) {
                        simplified.push_back(points[i]);
                    }
                }
                simplified.push_back(points.back());
                if (simplified.size() >= 6 && simplified.size() + 6 < points.size()) {
                    points = std::move(simplified);
                    decimated = true;
                }
            }

            if (budget) budget->consume(points.size());

            GLPrimitiveType type = GLPrimitiveType::POLYGON_FILLED;
            if (shape.type == ShapeType::PATH) {
                if (points.size() < 3) return;
            } else if (shape.type == ShapeType::TEXT) {
                type = GLPrimitiveType::RECT_OUTLINE;
            } else if (points.size() == 4) {
                const bool axisAligned =
                    (std::fabs(points[0].x - points[3].x) < 1e-6 && std::fabs(points[1].x - points[2].x) < 1e-6 &&
                     std::fabs(points[0].y - points[1].y) < 1e-6 && std::fabs(points[2].y - points[3].y) < 1e-6) ||
                    (std::fabs(points[0].y - points[3].y) < 1e-6 && std::fabs(points[1].y - points[2].y) < 1e-6 &&
                     std::fabs(points[0].x - points[1].x) < 1e-6 && std::fabs(points[2].x - points[3].x) < 1e-6);
                if (axisAligned) type = GLPrimitiveType::RECT_FILLED;
            }
            const GLPrimitiveType geometryType = type;
            if (style->strokeOnly && style->fillPattern == 0) {
                if (type == GLPrimitiveType::RECT_FILLED) type = GLPrimitiveType::RECT_OUTLINE;
                if (type == GLPrimitiveType::POLYGON_FILLED) type = GLPrimitiveType::POLYGON_OUTLINE;
            }
            const bool canMerge = type == GLPrimitiveType::RECT_FILLED || type == GLPrimitiveType::RECT_OUTLINE;
            RenderBatch* target = nullptr;
            if (canMerge) {
                target = &getOrCreateMergedRectBatch(
                    geometryType == GLPrimitiveType::RECT_OUTLINE || type == GLPrimitiveType::RECT_OUTLINE
                        ? type : geometryType,
                    shape.layerKey.layer, shape.layerKey.datatype, style->fillPattern, style->color, 0);
                target->type = type;
            } else {
                RenderBatch batch{};
                batch.type = type; batch.layerNumber = shape.layerKey.layer; batch.datatype = shape.layerKey.datatype;
                batch.fillPattern = style->fillPattern;
                std::copy(style->color.begin(), style->color.end(), batch.color);
                if (source) {
                    batch.sourceOrder = source->sourceOrder;
                    batch.preserveOpacity = true;
                    batch.color[3] *= static_cast<float>(source->opacity);
                }
                batches.push_back(std::move(batch)); target = &batches.back();
            }

            if (type == GLPrimitiveType::POLYGON_FILLED && decimated) {
                Triangulator::triangulate(points, target->triangleIndices);
            } else if (type == GLPrimitiveType::POLYGON_FILLED && cachedGeom != nullptr) {
                if (!cachedGeom->triangulationAttempted) {
                    cachedGeom->triangulationAttempted = true;
                    if (cachedGeom->localPoints.size() == 3) {
                        cachedGeom->triangleIndices = {0u, 1u, 2u};
                        cachedGeom->triangulated = true;
                    } else {
                    const uint64_t tplHash = HashRelativeContourTemplate(cachedGeom->localPoints);
                    auto& bucket = relativeTemplates[tplHash];
                    bool matchedTemplate = false;
                    for (const auto& entry : bucket) {
                        if (entry.samplePoints != nullptr &&
                            SameRelativeContourTemplate(*entry.samplePoints, cachedGeom->localPoints)) {
                            cachedGeom->triangleIndices = entry.triangleIndices;
                            cachedGeom->triangulated = entry.triangulated;
                            matchedTemplate = true;
                            break;
                        }
                    }
                    if (!matchedTemplate) {
                        cachedGeom->triangulated =
                            Triangulator::triangulate(cachedGeom->localPoints, cachedGeom->triangleIndices) &&
                            cachedGeom->triangleIndices.size() >= 3;
                        if (bucket.size() < 8) {
                            bucket.push_back({&cachedGeom->localPoints, cachedGeom->triangleIndices, cachedGeom->triangulated});
                        }
                    }
                    }
                }
                if (cachedGeom->triangulated) {
                    double det = transform.determinant();
                    if (source) det *= source->transform.determinant();
                    if (det < 0.0) {
                        target->triangleIndices.reserve(cachedGeom->triangleIndices.size());
                        for (size_t t = 0; t + 2 < cachedGeom->triangleIndices.size(); t += 3) {
                            target->triangleIndices.push_back(cachedGeom->triangleIndices[t]);
                            target->triangleIndices.push_back(cachedGeom->triangleIndices[t + 2]);
                            target->triangleIndices.push_back(cachedGeom->triangleIndices[t + 1]);
                        }
                    } else {
                        target->triangleIndices = cachedGeom->triangleIndices;
                    }
                }
            }

            for (const auto& point : points) {
                target->vertices.push_back({
                    static_cast<float>(point.x - originX),
                    static_cast<float>(point.y - originY)
                });
            }
            if (target->vertices.size() > size_t(std::numeric_limits<int>::max()))
                throw std::runtime_error("Hierarchy render vertex count exceeds renderer range");
            target->vertexCount = static_cast<int>(target->vertices.size());
        }, traversalViewport, nullptr, nullptr, &onStoppedInstanceBox);
    return batches;
}

} // namespace hongtu
#endif
