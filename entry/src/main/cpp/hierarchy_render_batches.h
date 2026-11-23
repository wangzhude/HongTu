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

// Shared across every source: adaptive sub-pixel coarsening kicks in well before
// approaching GPU vertex limits so large chip scenes never crash back to JS fallback.
struct HierarchyRenderBudget {
    size_t primitives = 0, vertices = 0;
    size_t maxPrimitives = 4000000, maxVertices = 24000000;
    bool tryConsume(size_t points) noexcept {
        if (primitives >= maxPrimitives || points > maxVertices - vertices) {
            return false;
        }
        ++primitives;
        vertices += points;
        return true;
    }
    void consume(size_t points) {
        if (!tryConsume(points)) {
            throw std::length_error("Composite scene exceeds aggregate visible geometry budget (4000000 primitives / 24000000 vertices)");
        }
    }
};

inline GeometryEngine::Transform2D HierarchyExplicitInverse(const GeometryEngine::Transform2D& t) {
    for (double value : {t.a, t.b, t.c, t.d, t.tx, t.ty})
        if (!std::isfinite(value)) throw std::invalid_argument("Composite source requires six finite affine coefficients");
    const double determinant = t.determinant();
    if (!std::isfinite(determinant) || determinant == 0)
        throw std::invalid_argument("Composite source requires a finite nonzero affine determinant");
    GeometryEngine::Transform2D inverse;
    inverse.a = t.d / determinant; inverse.b = -t.b / determinant;
    inverse.c = -t.c / determinant; inverse.d = t.a / determinant;
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
 * Includes KLayout-style screen-space sub-pixel LOD proxy (covering ALL primitives
 * including 4-vertex rectangles/BOXes + sub-pixel child instances + dense AREF lattices),
 * adaptive half-pixel overdraw deduplication, relative-contour triangulation template reuse,
 * and unexpanded child instance bounding-box outlines.
 */
inline std::vector<RenderBatch> BuildHierarchyRenderBatches(const Layout& layout, int cellId, int hierarchyDepth,
    const BBox* viewport = nullptr, const HierarchyLayerStyles* styles = nullptr,
    const HierarchyRenderSource* source = nullptr, HierarchyRenderBudget* budget = nullptr,
    const HierarchyRenderOrigin* origin = nullptr) {
    std::vector<RenderBatch> batches;
    batches.reserve(std::min<size_t>(layout.shapes.size() + 16, 16384));
    std::unordered_map<uint64_t, size_t> mergeIndex;
    const HierarchyLayerStyle defaultStyle;
    HierarchyRenderBudget localBudget;
    HierarchyRenderBudget* activeBudget = budget ? budget : &localBudget;
    const double originX = (origin && std::isfinite(origin->x)) ? origin->x : 0.0;
    const double originY = (origin && std::isfinite(origin->y)) ? origin->y : 0.0;
    BBox localViewport;
    const BBox* traversalViewport = viewport;
    double sourceScale = 1.0;
    if (source) {
        ValidateHierarchyRenderSource(*source);
        if (source->opacity == 0) return batches;
        const double det = std::abs(source->transform.determinant());
        if (std::isfinite(det) && det > 0.0) sourceScale = std::sqrt(det);
        if (viewport) { localViewport = HierarchyInverseViewport(*viewport, source->transform); traversalViewport = &localViewport; }
    }

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

    // Conservative screen-space pixel span (nm per pixel on a 2560px reference viewport).
    double pixelSpanNm = 0.0;
    if (viewport && viewport->valid()) {
        const double span = std::max((viewport->maxX - viewport->minX), (viewport->maxY - viewport->minY));
        if (std::isfinite(span) && span > 0.0) {
            pixelSpanNm = span / 2560.0;
        }
    }
    const double baseSubpixelCellNm = pixelSpanNm > 0.0 ? std::max(1e-6, 0.55 * pixelSpanNm) : 0.0;

    // Representative visible LayerKey per cell so collapsed sub-pixel instances/arrays
    // inherit authentic layer color/style instead of expanding millions of hidden/tiny leaves.
    struct CellProxyLayerInfo {
        bool resolved = false;
        bool hasVisible = false;
        LayerKey key{1, 0};
    };
    std::unordered_map<int, CellProxyLayerInfo> cellProxyLayers;
    cellProxyLayers.reserve(layout.cells.size() + 8);
    if (pixelSpanNm > 0.0 && !layout.instances.empty()) {
        std::unordered_map<int, std::vector<LayerKey>> directVisibleLayers;
        std::unordered_map<int, std::vector<int>> childRefs;
        for (const auto& s : layout.shapes) {
            if (s.type == ShapeType::INSTANCE || s.type == ShapeType::NODE || s.type == ShapeType::TEXT) continue;
            if (styles) {
                const auto found = styles->find(s.layerKey);
                if (found != styles->end() && !found->second.visible) continue;
            }
            auto& vec = directVisibleLayers[s.ownerCellId];
            if (vec.empty()) vec.push_back(s.layerKey);
        }
        for (const auto& inst : layout.instances) {
            if (inst.referencedCellId >= 0) {
                childRefs[inst.ownerCellId].push_back(inst.referencedCellId);
            }
        }
        std::unordered_map<int, int> state;
        std::function<CellProxyLayerInfo(int)> resolveLayer = [&](int cid) -> CellProxyLayerInfo {
            auto stIt = state.find(cid);
            if (stIt != state.end()) {
                if (stIt->second == 2) return cellProxyLayers[cid];
                return {true, false, {1, 0}};
            }
            state[cid] = 1;
            CellProxyLayerInfo info{true, false, {1, 0}};
            auto dirIt = directVisibleLayers.find(cid);
            if (dirIt != directVisibleLayers.end() && !dirIt->second.empty()) {
                info.hasVisible = true;
                info.key = dirIt->second.front();
            } else {
                auto chIt = childRefs.find(cid);
                if (chIt != childRefs.end()) {
                    for (int refId : chIt->second) {
                        const auto childInfo = resolveLayer(refId);
                        if (childInfo.hasVisible) {
                            info = childInfo;
                            break;
                        }
                    }
                }
            }
            cellProxyLayers[cid] = info;
            state[cid] = 2;
            return info;
        };
        for (const auto& c : layout.cells) {
            resolveLayer(c.id);
        }
    }

    // Half-pixel occupancy set per (layer, datatype, gx, gy) to eliminate millions of
    // redundant sub-pixel standard-cell / photonic-crystal overdraws at wafer-level zoom.
    std::unordered_set<uint64_t> subpixelOccupied;
    if (pixelSpanNm > 0.0) {
        subpixelOccupied.reserve(32768);
    }

    // Adaptive LOD scale: if primitive count already exceeds 1.5M on ultra-dense full-chip views,
    // progressively coarsen sub-pixel grid cell size (1x -> 2x -> 4x) so OpenGL stays fast and complete
    // without ever throwing std::length_error to the 2000-node ArkUI fallback.
    auto currentLodMultiplier = [&]() noexcept -> double {
        if (activeBudget->primitives >= 2600000 || activeBudget->vertices >= 16000000) return 4.0;
        if (activeBudget->primitives >= 1400000 || activeBudget->vertices >= 9000000) return 2.0;
        return 1.0;
    };

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
        if (!activeBudget->tryConsume(4)) {
            if (budget && pixelSpanNm <= 0.0) {
                budget->consume(4);
            }
            return;
        }
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

    auto emitSubpixelProxyBox = [&](LayerKey lk, const HierarchyLayerStyle& st, const BBox& worldBox) {
        const double lodMul = currentLodMultiplier();
        const double cellNm = baseSubpixelCellNm * lodMul;
        const double maxDim = std::max((worldBox.maxX - worldBox.minX), (worldBox.maxY - worldBox.minY));
        const double cx = 0.5 * (worldBox.minX + worldBox.maxX);
        const double cy = 0.5 * (worldBox.minY + worldBox.maxY);
        if (cellNm > 0.0 && maxDim <= 1.25 * pixelSpanNm * lodMul) {
            const int64_t gx = static_cast<int64_t>(std::floor((cx - originX) / cellNm));
            const int64_t gy = static_cast<int64_t>(std::floor((cy - originY) / cellNm));
            const uint64_t cellKey = (uint64_t(uint16_t(lk.layer)) << 48) |
                                     (uint64_t(uint16_t(lk.datatype)) << 32) |
                                     ((uint64_t(uint32_t(gx)) * 2654435761ULL) ^ uint64_t(uint32_t(gy)));
            if (!subpixelOccupied.insert(cellKey).second) {
                return;
            }
        }
        const double minHalf = 0.40 * pixelSpanNm;
        const double halfW = std::max(0.5 * (worldBox.maxX - worldBox.minX), minHalf);
        const double halfH = std::max(0.5 * (worldBox.maxY - worldBox.minY), minHalf);
        const GLPrimitiveType proxyType = (st.strokeOnly && st.fillPattern == 0)
            ? GLPrimitiveType::RECT_OUTLINE
            : GLPrimitiveType::RECT_FILLED;
        RenderBatch& proxyBatch = getOrCreateMergedRectBatch(
            proxyType, lk.layer, lk.datatype, st.fillPattern, st.color, 0);
        appendAxisAlignedBox(proxyBatch, cx - halfW, cy - halfH, cx + halfW, cy + halfH);
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

    std::function<void(int, const BBox&)> onSubpixelInstance = [&](int refCellId, const BBox& localBox) {
        if (!localBox.valid()) return;
        const auto layerIt = cellProxyLayers.find(refCellId);
        if (layerIt == cellProxyLayers.end() || !layerIt->second.hasVisible) return;
        const LayerKey lk = layerIt->second.key;
        const HierarchyLayerStyle* st = &defaultStyle;
        if (styles) {
            const auto found = styles->find(lk);
            if (found != styles->end()) st = &found->second;
            if (!st->visible) return;
        }
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
        if (!worldBox.valid() || (viewport && !worldBox.intersects(*viewport))) return;
        emitSubpixelProxyBox(lk, *st, worldBox);
    };

    const double localSubpixelInstanceSpanNm =
        (pixelSpanNm > 0.0 && sourceScale > 0.0) ? (1.35 * pixelSpanNm / sourceScale) : 0.0;

    layout.flattenHierarchy(cellId, hierarchyDepth,
        [&](const SceneShape& shape, const GeometryEngine::Transform2D& transform) {
            if (shape.type == ShapeType::NODE || shape.type == ShapeType::TEXT) return;
            const HierarchyLayerStyle* style = &defaultStyle;
            if (styles) {
                const auto found = styles->find(shape.layerKey);
                if (found != styles->end()) style = &found->second;
                if (!style->visible) return;
            }

            const bool isRectBox = (shape.type == ShapeType::RECT || shape.type == ShapeType::BOX) && shape.points.size() == 2;
            const bool directPolygonCache = (shape.type == ShapeType::POLYGON && shape.points.size() >= 3);
            const bool cacheableShape = directPolygonCache || (shape.type == ShapeType::PATH && !shape.pathWidthAbsolute);
            CachedShapeGeometry* cachedGeom = nullptr;

            BBox rectLocalBox;
            const BBox* preCullLocalBox = nullptr;

            if (isRectBox) {
                const double x0 = std::min(shape.points[0].x, shape.points[1].x);
                const double y0 = std::min(shape.points[0].y, shape.points[1].y);
                const double x1 = std::max(shape.points[0].x, shape.points[1].x);
                const double y1 = std::max(shape.points[0].y, shape.points[1].y);
                if (std::isfinite(x0) && std::isfinite(y0) && std::isfinite(x1) && std::isfinite(y1)) {
                    rectLocalBox = BBox(x0, y0, x1, y1);
                    preCullLocalBox = &rectLocalBox;
                }
            } else if (directPolygonCache) {
                if ((shape.renderCacheFlags & 1u) == 0u) {
                    BBox lb;
                    for (const auto& lp : shape.points) {
                        if (std::isfinite(lp.x) && std::isfinite(lp.y)) {
                            lb = lb.unite(BBox(lp.x, lp.y, lp.x, lp.y));
                        }
                    }
                    shape.cachedRenderLocalBox = lb;
                    shape.renderCacheFlags |= 1u;
                }
                preCullLocalBox = &shape.cachedRenderLocalBox;
            } else if (cacheableShape) {
                cachedGeom = &shapeCache[&shape];
                if (!cachedGeom->contourReady) {
                    cachedGeom->localPoints = effectivePolygon(shape);
                    for (const auto& lp : cachedGeom->localPoints) {
                        if (std::isfinite(lp.x) && std::isfinite(lp.y)) {
                            cachedGeom->localBox = cachedGeom->localBox.unite(BBox(lp.x, lp.y, lp.x, lp.y));
                        }
                    }
                    cachedGeom->contourReady = true;
                }
                if (cachedGeom->localPoints.empty()) return;
                preCullLocalBox = &cachedGeom->localBox;
            }

            if (preCullLocalBox != nullptr && viewport && preCullLocalBox->valid()) {
                BBox approxWorldBox;
                bool approxFinite = true;
                const BBox& lb = *preCullLocalBox;
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

                    const double lodMul = currentLodMultiplier();
                    const double maxDim = std::max((approxWorldBox.maxX - approxWorldBox.minX), (approxWorldBox.maxY - approxWorldBox.minY));
                    // Apply sub-pixel proxy & occupancy deduplication to ALL shapes (including 4-pt rectangles/BOXes)!
                    const double proxyThreshold = (isRectBox ? 1.35 : 2.4) * pixelSpanNm * lodMul;
                    if (pixelSpanNm > 0.0 && maxDim <= proxyThreshold) {
                        emitSubpixelProxyBox(shape.layerKey, *style, approxWorldBox);
                        return;
                    }
                }
            }

            std::vector<Vec2> points;
            if (isRectBox) {
                const auto& a = shape.points[0]; const auto& b = shape.points[1];
                points = transform.applyToPolygon({{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, b.y}});
            } else if (directPolygonCache) {
                const bool isIdentity = transform.a == 1.0 && transform.b == 0.0 &&
                                        transform.c == 0.0 && transform.d == 1.0 &&
                                        transform.tx == 0.0 && transform.ty == 0.0;
                points = isIdentity ? shape.points : transform.applyToPolygon(shape.points);
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
                if (simplified.size() >= 4 && simplified.size() <= 512 && simplified.size() * 2 <= points.size()) {
                    points = std::move(simplified);
                    decimated = true;
                }
            }

            if (!activeBudget->tryConsume(points.size())) {
                if (pixelSpanNm > 0.0) {
                    emitSubpixelProxyBox(shape.layerKey, *style, box);
                    return;
                }
                if (budget) budget->consume(points.size());
                return;
            }

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
            } else if (type == GLPrimitiveType::POLYGON_FILLED && directPolygonCache) {
                if ((shape.renderCacheFlags & 2u) == 0u) {
                    shape.renderCacheFlags |= 2u;
                    if (shape.points.size() == 3) {
                        shape.cachedRenderTriangles = {0u, 1u, 2u};
                        shape.renderCacheFlags |= 4u;
                    } else {
                        const uint64_t tplHash = HashRelativeContourTemplate(shape.points);
                        auto& bucket = relativeTemplates[tplHash];
                        bool matchedTemplate = false;
                        for (const auto& entry : bucket) {
                            if (entry.samplePoints != nullptr &&
                                SameRelativeContourTemplate(*entry.samplePoints, shape.points)) {
                                shape.cachedRenderTriangles = entry.triangleIndices;
                                if (entry.triangulated) shape.renderCacheFlags |= 4u;
                                matchedTemplate = true;
                                break;
                            }
                        }
                        if (!matchedTemplate) {
                            const bool okTri =
                                Triangulator::triangulate(shape.points, shape.cachedRenderTriangles) &&
                                shape.cachedRenderTriangles.size() >= 3;
                            if (okTri) shape.renderCacheFlags |= 4u;
                            if (bucket.size() < 8) {
                                bucket.push_back({&shape.points, shape.cachedRenderTriangles, okTri});
                            }
                        }
                    }
                }
                if ((shape.renderCacheFlags & 4u) != 0u) {
                    double det = transform.determinant();
                    if (source) det *= source->transform.determinant();
                    if (det < 0.0) {
                        target->triangleIndices.reserve(shape.cachedRenderTriangles.size());
                        for (size_t t = 0; t + 2 < shape.cachedRenderTriangles.size(); t += 3) {
                            target->triangleIndices.push_back(shape.cachedRenderTriangles[t]);
                            target->triangleIndices.push_back(shape.cachedRenderTriangles[t + 2]);
                            target->triangleIndices.push_back(shape.cachedRenderTriangles[t + 1]);
                        }
                    } else {
                        target->triangleIndices = shape.cachedRenderTriangles;
                    }
                }
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
        },
        traversalViewport, nullptr, nullptr, &onStoppedInstanceBox,
        localSubpixelInstanceSpanNm,
        localSubpixelInstanceSpanNm > 0.0 ? &onSubpixelInstance : nullptr);
    return batches;
}

} // namespace hongtu
#endif
