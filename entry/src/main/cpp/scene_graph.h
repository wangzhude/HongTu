/**
 * HongTu EDA - Scene Graph
 * Hierarchical cell/instance management with transform propagation.
 * Supports KLayout-style cell hierarchy: Cell → shapes + instances → child Cells,
 * persistent hierarchy index/subtree bounds caching, analytical AREF viewport clipping,
 * and sub-pixel whole-instance / dense-array LOD proxy collapse.
 */
#ifndef HONGTU_SCENE_GRAPH_H
#define HONGTU_SCENE_GRAPH_H

#include "spatial_index.h"
#include "geometry_engine.h"
#include "triangulator.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
#include "layout_port.h"

namespace hongtu {

// Shape types matching GDSII/OASIS
enum class ShapeType : uint8_t {
    RECT = 0,
    POLYGON = 1,
    PATH = 2,
    TEXT = 3,
    INSTANCE = 4,  // SREF/AREF
    BOX = 5,
    NODE = 6
};

// Layer key: (layer_number, datatype)
struct LayerKey {
    int16_t layer;
    int16_t datatype;

    bool operator==(const LayerKey& o) const {
        return layer == o.layer && datatype == o.datatype;
    }
};

struct LayerKeyHash {
    size_t operator()(const LayerKey& k) const {
        return std::hash<int32_t>()((int32_t)k.layer << 16 | (uint16_t)k.datatype);
    }
};

struct SceneProperty {
    int attr = 0;
    std::string name;
    std::string value;
    uint8_t dtype = 6;
};

inline const SceneProperty* findProperty(const std::vector<SceneProperty>& props, int attr) {
    for (const auto& p : props) {
        if (p.attr == attr) {
            return &p;
        }
    }
    return nullptr;
}

inline const SceneProperty* findProperty(const std::vector<SceneProperty>& props,
                                         const std::string& name) {
    for (const auto& p : props) {
        if (p.name == name) {
            return &p;
        }
    }
    return nullptr;
}

// A single geometric shape in the layout
struct SceneShape {
    int64_t id;
    ShapeType type;
    LayerKey layerKey;
    std::vector<Vec2> points;     // Geometry vertices (nm)
    double pathWidth = 0.0;       // For PATH type (nm)
    int pathType = 0;             // 0=flush, 1=round, 2=extended
    double pathBeginExtension = 0.0;
    double pathEndExtension = 0.0;
    bool pathWidthAbsolute = false;
    std::string text;             // For TEXT type
    int textPresentation = 0;     // Font/justification
    double textRotation = 0, textMagnification = 1;
    int textMirror = 0;
    int ownerCellId;              // Cell that owns this shape

    // Properties (GDSII PROPATTR/PROPVALUE, OASIS PROPERTY)
    std::vector<SceneProperty> properties;

    // Persistent render-time local contour BBox & ear-clipping index cache (computed lazily once per immutable SceneShape)
    mutable BBox cachedRenderLocalBox;
    mutable std::vector<uint32_t> cachedRenderTriangles;
    mutable uint8_t renderCacheFlags = 0; // bit0: localBox ready, bit1: triangulation attempted, bit2: triangulated

    BBox bbox() const {
        BBox box;
        for (const auto& p : points) {
            box.minX = std::min(box.minX, p.x);
            box.minY = std::min(box.minY, p.y);
            box.maxX = std::max(box.maxX, p.x);
            box.maxY = std::max(box.maxY, p.y);
        }
        if (type == ShapeType::PATH && pathWidth > 0) {
            double hw = pathWidth * 0.5;
            box = box.expand(pathType == 4 ? hw + std::max(std::abs(pathBeginExtension), std::abs(pathEndExtension)) : (pathType == 0 ? hw : pathWidth));
        }
        return box;
    }
};

inline std::vector<Vec2> effectivePolygon(const SceneShape& shape) {
    if (shape.type == ShapeType::NODE) {
        return {};
    }
    if (shape.type == ShapeType::PATH) {
        return Triangulator::pathOutline(shape.points, shape.pathWidth, shape.pathType,
            shape.pathBeginExtension, shape.pathEndExtension);
    }
    if ((shape.type == ShapeType::RECT || shape.type == ShapeType::BOX) &&
        shape.points.size() == 2) {
        const double x0 = std::min(shape.points[0].x, shape.points[1].x);
        const double y0 = std::min(shape.points[0].y, shape.points[1].y);
        const double x1 = std::max(shape.points[0].x, shape.points[1].x);
        const double y1 = std::max(shape.points[0].y, shape.points[1].y);
        return {{x0, y0}, {x1, y0}, {x1, y1}, {x0, y1}};
    }
    if (shape.points.size() < 3) {
        return {};
    }
    return shape.points;
}

inline std::vector<Vec2> effectivePolygonTransformed(const SceneShape& shape, const GeometryEngine::Transform2D& xf) {
    if (shape.type == ShapeType::PATH && shape.pathWidthAbsolute) {
        const double scale = std::sqrt(std::abs(xf.determinant()));
        return Triangulator::pathOutline(xf.applyToPolygon(shape.points), shape.pathWidth,
            shape.pathType, shape.pathBeginExtension * scale, shape.pathEndExtension * scale);
    }
    return xf.applyToPolygon(effectivePolygon(shape));
}

// Instance transform (SREF/AREF)
struct InstanceTransform {
    double x = 0, y = 0;         // Position (nm)
    double rotation = 0;          // Degrees (0, 90, 180, 270 typical)
    double magnification = 1.0;
    bool mirrorX = false;         // Mirror about X axis before rotation

    // Array parameters (AREF)
    int arrayCols = 0;            // 0 = not an array
    int arrayRows = 0;
    double arrayPitchX = 0;      // Spacing between columns (nm)
    double arrayPitchY = 0;      // Spacing between rows (nm)
    double arrayColStepY = 0;    // Cross-axis components, permitting skewed/rotated arrays
    double arrayRowStepX = 0;

    bool isArray() const { return arrayCols > 0 && arrayRows > 0; }

    GeometryEngine::Transform2D toMatrix() const {
        GeometryEngine::Transform2D mat = GeometryEngine::Transform2D::identity();
        if (magnification != 1.0) {
            mat = GeometryEngine::Transform2D::scaling(magnification, magnification).multiply(mat);
        }
        if (mirrorX) {
            mat = GeometryEngine::Transform2D::mirrorX().multiply(mat);
        }
        if (rotation != 0) {
            mat = GeometryEngine::Transform2D::rotation(rotation).multiply(mat);
        }
        mat = GeometryEngine::Transform2D::translation(x, y).multiply(mat);
        return mat;
    }
};

// A cell instance (reference to another cell)
struct CellInstance {
    int64_t id;
    int referencedCellId;
    std::string referencedCellName;
    InstanceTransform transform;
    int ownerCellId;
    std::vector<SceneProperty> properties;

    BBox bbox(const struct Cell* referencedCell) const;
};

// A cell in the hierarchy
struct Cell {
    int id;
    std::string name;
    std::vector<int64_t> shapeIds;      // Indices into Layout::shapes
    std::vector<int64_t> instanceIds;   // Indices into Layout::instances
    bool isTopCell = false;

    // PCell parameters (if parameterized)
    bool isPCell = false;
    std::string pcellLibrary;
    std::string pcellName;
    std::vector<std::pair<std::string, std::string>> pcellParams;

    std::vector<SceneProperty> properties;
    std::vector<std::string> contextRecords;
};

struct ViewProjection {
    double originX = 0;
    double originY = 0;
    double scale = 1;

    double toPixelX(double x) const { return (x - originX) * scale; }
    double toPixelY(double y) const { return (originY - y) * scale; }
    double toWorldX(double px) const { return originX + px / scale; }
    double toWorldY(double py) const { return originY - py / scale; }

    static ViewProjection fitting(const BBox& region, double outW, double outH) {
        ViewProjection p;
        double designW = region.maxX - region.minX;
        double designH = region.maxY - region.minY;
        if (!(designW > 0)) designW = 1;
        if (!(designH > 0)) designH = 1;
        p.scale = std::min(outW / designW, outH / designH);
        if (!std::isfinite(p.scale) || p.scale <= 0) p.scale = 1;
        p.originX = region.minX;
        p.originY = region.maxY;
        return p;
    }
};

// Layer display properties
struct LayerProperties {
    LayerKey key;
    std::string name;
    uint32_t fillColor;       // RGBA
    uint32_t lineColor;       // RGBA
    uint8_t fillPattern;      // 0=solid, 1=hollow, 2-17 stipple patterns
    uint8_t lineStyle;        // 0=solid, 1=dashed, 2=dotted
    float lineWidth;
    float transparency;       // 0.0-1.0
    bool visible;
    bool selectable;
    bool valid;               // Layer is active

    LayerProperties() : fillColor(0xFF00FF00), lineColor(0xFFFFFFFF),
                       fillPattern(0), lineStyle(0), lineWidth(1.0f),
                       transparency(0.5f), visible(true), selectable(true), valid(true) {}
};

class Layout {
public:
    Layout() : nextShapeId_(1), nextInstanceId_(1), nextCellId_(1), topCellId_(-1) {}
    enum class SpatialIndexBuild { Immediate, Deferred };

    std::vector<SceneShape> shapes;
    std::vector<CellInstance> instances;
    std::vector<Cell> cells;
    std::unordered_map<LayerKey, LayerProperties, LayerKeyHash> layerProps;

    std::string libName;
    std::vector<std::string> layoutContextRecords;
    std::vector<SceneProperty> libProperties;
    std::vector<std::string> cellKeys;
    std::vector<LayoutPort> ports;
    std::vector<LayoutCrossSection> crossSections;
    double dbUnit = 1e-9;
    double userUnit = 1e-6;
    int64_t modTime = 0;
    int64_t accessTime = 0;

    int topCellId() const { return topCellId_; }
    void setTopCell(int id) { topCellId_ = id; ++hierarchyMutationEpoch_; }

    int64_t addShape(const SceneShape& shape, SpatialIndexBuild spatialIndexBuild = SpatialIndexBuild::Immediate) {
        int64_t id = shape.id > 0 ? shape.id : nextShapeId_++;
        SceneShape s = shape;
        s.id = id;
        shapes.push_back(s);
        ++hierarchyMutationEpoch_;

        if (spatialIndexBuild == SpatialIndexBuild::Deferred) {
            spatialDirty_ = true;
        } else {
            BBox box = s.bbox();
            if (box.valid()) spatialIndex_.insert((int)shapes.size() - 1, box);
        }

        if (Cell* owner = findCell(s.ownerCellId)) {
            owner->shapeIds.push_back(id);
        }

        registerLayer(s.layerKey);

        if (id >= nextShapeId_) nextShapeId_ = id + 1;
        return id;
    }

    void removeShape(int64_t id) {
        for (int i = 0; i < (int)shapes.size(); i++) {
            if (shapes[i].id == id) {
                shapes.erase(shapes.begin() + i);
                spatialDirty_ = true;
                ++hierarchyMutationEpoch_;
                return;
            }
        }
    }

    SceneShape* findShape(int64_t id) {
        ++hierarchyMutationEpoch_;
        for (auto& s : shapes) {
            if (s.id == id) return &s;
        }
        return nullptr;
    }

    int64_t addInstance(const CellInstance& inst) {
        int64_t id = inst.id > 0 ? inst.id : nextInstanceId_++;
        CellInstance ci = inst;
        ci.id = id;
        instances.push_back(ci);
        ++hierarchyMutationEpoch_;

        if (Cell* owner = findCell(ci.ownerCellId)) {
            owner->instanceIds.push_back(id);
        }

        if (id >= nextInstanceId_) nextInstanceId_ = id + 1;
        return id;
    }

    CellInstance* findInstance(int64_t id) {
        ++hierarchyMutationEpoch_;
        for (auto& inst : instances) {
            if (inst.id == id) return &inst;
        }
        return nullptr;
    }

    int addCell(const std::string& name) {
        int id = nextCellId_++;
        Cell cell;
        cell.id = id;
        cell.name = name;
        cells.push_back(cell);
        ++hierarchyMutationEpoch_;
        return id;
    }

    int addCellWithId(int id, const std::string& name) {
        if (id < 0) {
            return addCell(name);
        }
        for (auto& c : cells) {
            if (c.id == id) {
                c.name = name;
                if (id >= nextCellId_) {
                    nextCellId_ = id + 1;
                }
                ++hierarchyMutationEpoch_;
                return id;
            }
        }
        Cell cell;
        cell.id = id;
        cell.name = name;
        cells.push_back(cell);
        if (id >= nextCellId_) {
            nextCellId_ = id + 1;
        }
        ++hierarchyMutationEpoch_;
        return id;
    }

    Cell* findCell(int id) {
        for (auto& c : cells) {
            if (c.id == id) return &c;
        }
        return nullptr;
    }

    const Cell* findCell(int id) const {
        for (const auto& c : cells) {
            if (c.id == id) return &c;
        }
        return nullptr;
    }

    Cell* findCellByName(const std::string& name) {
        for (auto& c : cells) {
            if (c.name == name) return &c;
        }
        return nullptr;
    }

    void resolveTopCell() {
        std::vector<bool> referenced(cells.size(), false);
        for (const auto& inst : instances) {
            for (int i = 0; i < (int)cells.size(); i++) {
                if (cells[i].id == inst.referencedCellId) {
                    referenced[i] = true;
                    break;
                }
            }
        }

        std::vector<int> topCandidates;
        for (int i = 0; i < (int)cells.size(); i++) {
            if (!referenced[i]) {
                topCandidates.push_back(i);
                cells[i].isTopCell = true;
            }
        }

        if (!topCandidates.empty()) {
            int best = topCandidates[0];
            size_t maxShapes = 0;
            for (int idx : topCandidates) {
                size_t total = cells[idx].shapeIds.size() + cells[idx].instanceIds.size();
                if (total > maxShapes) {
                    maxShapes = total;
                    best = idx;
                }
            }
            topCellId_ = cells[best].id;
        }
        ++hierarchyMutationEpoch_;
    }

    std::vector<int> queryPoint(double x, double y) const {
        ensureSpatialIndex();
        return spatialIndex_.queryPoint(x, y);
    }

    bool spatialIndexReady() const { return !spatialDirty_; }

    void ensureSpatialIndex() const {
        if (spatialDirty_) {
            rebuildSpatialIndex();
        }
    }

    std::vector<int> queryRange(const BBox& box) const {
        ensureSpatialIndex();
        return spatialIndex_.queryRange(box);
    }

    std::vector<int> queryNearest(double x, double y, int k) const {
        ensureSpatialIndex();
        return spatialIndex_.queryNearest(x, y, k);
    }

    struct HierarchyTraversalStats {
        uint64_t visitedCells = 0;
        uint64_t prunedCells = 0;
        uint64_t candidateShapes = 0;
        uint64_t emittedShapes = 0;
        uint64_t candidateInstances = 0;
        uint64_t prunedInstanceGroups = 0;
        uint64_t collapsedSubpixelInstances = 0;
    };

    void invalidateHierarchyCache() const {
        cachedHierarchyValid_ = false;
    }

    void flattenHierarchy(int cellId, int hierarchyDepth,
                         std::function<void(const SceneShape&, const GeometryEngine::Transform2D&)> callback,
                         const BBox* viewport = nullptr, HierarchyTraversalStats* stats = nullptr,
                         std::function<void()> checkpoint = nullptr,
                         const std::function<void(const BBox&)>* stoppedInstanceBoxCallback = nullptr,
                         double subpixelInstanceSpanNm = 0.0,
                         const std::function<void(int, const BBox&)>* subpixelInstanceCallback = nullptr) const {
        const int maxRecursion = hierarchyDepth < 0 ? -1 : std::max(0, hierarchyDepth - 1);
        ensureHierarchyCache(checkpoint);
        HierarchyTraversalContext context{
            std::move(checkpoint),
            cachedOwners_,
            cachedBounds_,
            viewport && finiteBox(*viewport) ? viewport : nullptr,
            stats,
            stoppedInstanceBoxCallback,
            subpixelInstanceSpanNm,
            subpixelInstanceCallback
        };
        if (stats) *stats = {};
        std::vector<int> ancestors;
        flattenRecursive(cellId, GeometryEngine::Transform2D::identity(), maxRecursion, 0,
                         ancestors, callback, context);
    }

    std::vector<const SceneShape*> getCellShapes(int cellId) const {
        std::vector<const SceneShape*> result;
        for (const auto& s : shapes) {
            if (s.ownerCellId == cellId) {
                result.push_back(&s);
            }
        }
        return result;
    }

    std::vector<const CellInstance*> getCellInstances(int cellId) const {
        std::vector<const CellInstance*> result;
        for (const auto& inst : instances) {
            if (inst.ownerCellId == cellId) {
                result.push_back(&inst);
            }
        }
        return result;
    }

    void registerLayer(const LayerKey& key) {
        if (layerProps.find(key) == layerProps.end()) {
            LayerProperties lp;
            lp.key = key;
            lp.name = "L" + std::to_string(key.layer) + "/" + std::to_string(key.datatype);
            assignDefaultColor(lp);
            layerProps[key] = lp;
        }
    }

    std::vector<LayerKey> allLayers() const {
        std::vector<LayerKey> keys;
        keys.reserve(layerProps.size());
        for (const auto& [key, _] : layerProps) {
            keys.push_back(key);
        }
        std::sort(keys.begin(), keys.end(), [](const LayerKey& a, const LayerKey& b) {
            return a.layer < b.layer || (a.layer == b.layer && a.datatype < b.datatype);
        });
        return keys;
    }

    struct Stats {
        size_t totalShapes = 0;
        size_t totalInstances = 0;
        size_t totalCells = 0;
        size_t totalLayers = 0;
        BBox designBBox;
        size_t spatialIndexNodes = 0;
    };

    Stats getStats() const {
        Stats s;
        s.totalShapes = shapes.size();
        s.totalInstances = instances.size();
        s.totalCells = cells.size();
        s.totalLayers = layerProps.size();

        for (const auto& shape : shapes) {
            s.designBBox = s.designBBox.unite(shape.bbox());
        }

        auto idxStats = spatialIndex_.getStats();
        s.spatialIndexNodes = idxStats.totalNodes;
        return s;
    }

    void rebuildSpatialIndex() const {
        spatialDirty_ = true;
        spatialIndex_.clear();
        std::vector<std::pair<int, BBox>> items;
        items.reserve(shapes.size());
        for (int i = 0; i < (int)shapes.size(); i++) {
            BBox box = shapes[i].bbox();
            if (box.valid()) {
                items.push_back({i, box});
            }
        }
        spatialIndex_.bulkLoad(items);
        spatialDirty_ = false;
    }

    void clear() {
        shapes.clear();
        instances.clear();
        cells.clear();
        layerProps.clear();
        spatialIndex_.clear();
        cachedOwners_.clear();
        cachedBounds_.clear();
        cachedHierarchyValid_ = false;
        ++hierarchyMutationEpoch_;
        nextShapeId_ = 1;
        nextInstanceId_ = 1;
        nextCellId_ = 1;
        topCellId_ = -1;
    }

private:
    mutable RTree<int> spatialIndex_;
    mutable bool spatialDirty_ = true;
    int64_t nextShapeId_;
    int64_t nextInstanceId_;
    int nextCellId_;
    int topCellId_;

    /// 单个 AREF 阵列展开的实例上限（与 gdsii_reader COLROW DoS 防护同值；开启亚像素折叠时整阵可直接 O(1) 折叠）
    static constexpr int64_t kMaxArrayInstances = 10000000;

    struct HierarchyOwner {
        std::vector<const SceneShape*> shapes;
        std::vector<const CellInstance*> instances;
    };
    struct HierarchyBounds {
        BBox box;
        bool known = true;
    };

    mutable uint64_t hierarchyMutationEpoch_ = 1;
    mutable bool cachedHierarchyValid_ = false;
    mutable uint64_t cachedEpoch_ = 0;
    mutable const SceneShape* cachedShapesData_ = nullptr;
    mutable size_t cachedShapesSize_ = 0;
    mutable const CellInstance* cachedInstancesData_ = nullptr;
    mutable size_t cachedInstancesSize_ = 0;
    mutable size_t cachedCellsSize_ = 0;
    mutable std::unordered_map<int, HierarchyOwner> cachedOwners_;
    mutable std::unordered_map<int, HierarchyBounds> cachedBounds_;

    struct HierarchyTraversalContext {
        std::function<void()> checkpoint;
        const std::unordered_map<int, HierarchyOwner>& owners;
        const std::unordered_map<int, HierarchyBounds>& bounds;
        const BBox* viewport = nullptr;
        HierarchyTraversalStats* stats = nullptr;
        const std::function<void(const BBox&)>* stoppedInstanceBoxCallback = nullptr;
        double subpixelInstanceSpanNm = 0.0;
        const std::function<void(int, const BBox&)>* subpixelInstanceCallback = nullptr;
    };

    static bool finiteBox(const BBox& box) {
        return box.valid() && std::isfinite(box.minX) && std::isfinite(box.minY) &&
            std::isfinite(box.maxX) && std::isfinite(box.maxY);
    }

    static HierarchyBounds transformedBounds(const HierarchyBounds& local,
                                             const GeometryEngine::Transform2D& transform) {
        if (!local.known || !local.box.valid()) return local;
        HierarchyBounds result;
        for (const auto& p : std::array<Vec2, 4>{{{local.box.minX, local.box.minY}, {local.box.maxX, local.box.minY},
                                                {local.box.maxX, local.box.maxY}, {local.box.minX, local.box.maxY}}}) {
            const auto q = transform.apply(p);
            if (!std::isfinite(q.x) || !std::isfinite(q.y)) { result.known = false; return result; }
            result.box = result.box.unite(BBox(q.x, q.y, q.x, q.y));
        }
        return result;
    }

    static HierarchyBounds instanceBounds(const CellInstance& instance, const HierarchyBounds& child) {
        auto result = transformedBounds(child, instance.transform.toMatrix());
        if (!result.known || !result.box.valid() || !instance.transform.isArray()) return result;
        const auto& t = instance.transform;
        const double col = std::max(0, t.arrayCols - 1), row = std::max(0, t.arrayRows - 1);
        const BBox base = result.box;
        for (const auto& offset : std::array<Vec2, 3>{{{col * t.arrayPitchX, col * t.arrayColStepY},
                {row * t.arrayRowStepX, row * t.arrayPitchY},
                {col * t.arrayPitchX + row * t.arrayRowStepX, col * t.arrayColStepY + row * t.arrayPitchY}}}) {
            const BBox shifted(base.minX + offset.x, base.minY + offset.y, base.maxX + offset.x, base.maxY + offset.y);
            if (!finiteBox(shifted)) { result.known = false; return result; }
            result.box = result.box.unite(shifted);
        }
        return result;
    }

    static HierarchyBounds computeSubtreeBounds(
        int cellId,
        const std::unordered_map<int, HierarchyOwner>& owners,
        std::unordered_map<int, HierarchyBounds>& bounds,
        std::unordered_map<int, int>& boundState,
        const std::function<void()>& checkpoint) {
        if (checkpoint) checkpoint();
        auto stateIt = boundState.find(cellId);
        if (stateIt != boundState.end()) {
            if (stateIt->second == 2) return bounds[cellId];
            if (stateIt->second == 1) return {BBox(), false};
        }
        boundState[cellId] = 1;
        HierarchyBounds result;
        const auto owner = owners.find(cellId);
        if (owner != owners.end()) {
            for (const auto* shape : owner->second.shapes) {
                if (checkpoint) checkpoint();
                if (shape->type == ShapeType::INSTANCE || shape->type == ShapeType::NODE) continue;
                if (shape->type == ShapeType::PATH && shape->pathWidthAbsolute) result.known = false;
                if (shape->type == ShapeType::POLYGON && (shape->renderCacheFlags & 1u) != 0u) {
                    if (shape->cachedRenderLocalBox.valid()) {
                        result.box = result.box.unite(shape->cachedRenderLocalBox);
                    }
                    continue;
                }
                if ((shape->type == ShapeType::RECT || shape->type == ShapeType::BOX) && shape->points.size() == 2) {
                    const double x0 = std::min(shape->points[0].x, shape->points[1].x);
                    const double y0 = std::min(shape->points[0].y, shape->points[1].y);
                    const double x1 = std::max(shape->points[0].x, shape->points[1].x);
                    const double y1 = std::max(shape->points[0].y, shape->points[1].y);
                    if (!std::isfinite(x0) || !std::isfinite(y0) || !std::isfinite(x1) || !std::isfinite(y1)) {
                        result.known = false;
                    } else {
                        result.box = result.box.unite(BBox(x0, y0, x1, y1));
                    }
                    continue;
                }
                if (shape->type == ShapeType::POLYGON) {
                    BBox lb;
                    bool polyFinite = true;
                    for (const auto& p : shape->points) {
                        if (!std::isfinite(p.x) || !std::isfinite(p.y)) { polyFinite = false; result.known = false; continue; }
                        lb = lb.unite(BBox(p.x, p.y, p.x, p.y));
                    }
                    if (polyFinite) {
                        shape->cachedRenderLocalBox = lb;
                        shape->renderCacheFlags |= 1u;
                    }
                    if (lb.valid()) result.box = result.box.unite(lb);
                    continue;
                }
                auto points = shape->type == ShapeType::PATH ? effectivePolygon(*shape) : shape->points;
                for (const auto& p : points) {
                    if (!std::isfinite(p.x) || !std::isfinite(p.y)) { result.known = false; continue; }
                    result.box = result.box.unite(BBox(p.x, p.y, p.x, p.y));
                }
            }
            for (const auto* instance : owner->second.instances) {
                if (checkpoint) checkpoint();
                if (instance->referencedCellId < 0) continue;
                const auto child = instanceBounds(*instance,
                    computeSubtreeBounds(instance->referencedCellId, owners, bounds, boundState, checkpoint));
                result.known = result.known && child.known;
                result.box = result.box.unite(child.box);
            }
        }
        bounds[cellId] = result;
        boundState[cellId] = 2;
        return result;
    }

    void ensureHierarchyCache(const std::function<void()>& checkpoint) const {
        const SceneShape* sPtr = shapes.empty() ? nullptr : shapes.data();
        const CellInstance* iPtr = instances.empty() ? nullptr : instances.data();
        if (cachedHierarchyValid_ &&
            cachedEpoch_ == hierarchyMutationEpoch_ &&
            cachedShapesData_ == sPtr &&
            cachedShapesSize_ == shapes.size() &&
            cachedInstancesData_ == iPtr &&
            cachedInstancesSize_ == instances.size() &&
            cachedCellsSize_ == cells.size()) {
            return;
        }
        cachedOwners_.clear();
        cachedBounds_.clear();
        cachedOwners_.reserve(cells.size() + 8);
        cachedBounds_.reserve(cells.size() + 8);
        for (const auto& shape : shapes) {
            if (checkpoint) checkpoint();
            cachedOwners_[shape.ownerCellId].shapes.push_back(&shape);
        }
        for (const auto& instance : instances) {
            if (checkpoint) checkpoint();
            cachedOwners_[instance.ownerCellId].instances.push_back(&instance);
        }
        std::unordered_map<int, int> boundState;
        boundState.reserve(cells.size() + 8);
        for (const auto& cell : cells) {
            computeSubtreeBounds(cell.id, cachedOwners_, cachedBounds_, boundState, checkpoint);
        }
        for (const auto& kv : cachedOwners_) {
            if (boundState.find(kv.first) == boundState.end()) {
                computeSubtreeBounds(kv.first, cachedOwners_, cachedBounds_, boundState, checkpoint);
            }
        }
        cachedEpoch_ = hierarchyMutationEpoch_;
        cachedShapesData_ = sPtr;
        cachedShapesSize_ = shapes.size();
        cachedInstancesData_ = iPtr;
        cachedInstancesSize_ = instances.size();
        cachedCellsSize_ = cells.size();
        cachedHierarchyValid_ = true;
    }

    static HierarchyBounds lookupBounds(int cellId, const HierarchyTraversalContext& context) {
        const auto it = context.bounds.find(cellId);
        if (it != context.bounds.end()) return it->second;
        return {BBox(), true};
    }

    static bool outsideViewport(const HierarchyBounds& bound, const GeometryEngine::Transform2D& transform,
                                const BBox& viewport) {
        if (!bound.known) return false;
        if (!bound.box.valid()) return true;
        const auto world = transformedBounds(bound, transform);
        if (!world.known || !finiteBox(world.box)) return false;
        const double magnitude = std::max({1.0, std::abs(world.box.minX), std::abs(world.box.maxX),
            std::abs(world.box.minY), std::abs(world.box.maxY)});
        return !world.box.expand(1e-7 + magnitude * 1e-12).intersects(viewport);
    }

    /**
     * Analytically clip AREF [0..cols-1] x [0..rows-1] indices against the world viewport
     * by inverting the 2D lattice basis in world space. Avoids O(rows * cols) loops when
     * zoomed into a small region of a million-element photonic crystal or memory array.
     */
    static bool clipArrayIndexRange(const CellInstance& inst,
                                    const HierarchyBounds& childBound,
                                    const GeometryEngine::Transform2D& parentTransform,
                                    const BBox& viewport,
                                    int cols, int rows,
                                    int& outColMin, int& outColMax,
                                    int& outRowMin, int& outRowMax) {
        outColMin = 0; outColMax = cols - 1;
        outRowMin = 0; outRowMax = rows - 1;
        if (!childBound.known || !childBound.box.valid()) return true;
        const auto baseWorld = transformedBounds(childBound, parentTransform.multiply(inst.transform.toMatrix()));
        if (!baseWorld.known || !finiteBox(baseWorld.box)) return true;

        // Column and row step vectors transformed into world space (linear part only).
        const Vec2 originWorld = parentTransform.apply({0.0, 0.0});
        const Vec2 colEndWorld = parentTransform.apply({inst.transform.arrayPitchX, inst.transform.arrayColStepY});
        const Vec2 rowEndWorld = parentTransform.apply({inst.transform.arrayRowStepX, inst.transform.arrayPitchY});
        const double ux = colEndWorld.x - originWorld.x;
        const double uy = colEndWorld.y - originWorld.y;
        const double vx = rowEndWorld.x - originWorld.x;
        const double vy = rowEndWorld.y - originWorld.y;
        if (!std::isfinite(ux) || !std::isfinite(uy) || !std::isfinite(vx) || !std::isfinite(vy)) return true;

        // Target displacement Delta = col * U + row * V must bring baseWorld into viewport:
        // viewport.min - baseWorld.max <= Delta <= viewport.max - baseWorld.min
        const double dxMin = viewport.minX - baseWorld.box.maxX;
        const double dxMax = viewport.maxX - baseWorld.box.minX;
        const double dyMin = viewport.minY - baseWorld.box.maxY;
        const double dyMax = viewport.maxY - baseWorld.box.minY;
        if (!std::isfinite(dxMin) || !std::isfinite(dxMax) || !std::isfinite(dyMin) || !std::isfinite(dyMax)) return true;

        const double det = ux * vy - uy * vx;
        const double normSq = (ux * ux + uy * uy) * (vx * vx + vy * vy);
        if (normSq > 0.0 && det * det > 1e-18 * normSq) {
            double cMin = std::numeric_limits<double>::infinity();
            double cMax = -std::numeric_limits<double>::infinity();
            double rMin = std::numeric_limits<double>::infinity();
            double rMax = -std::numeric_limits<double>::infinity();
            for (const Vec2 d : std::array<Vec2, 4>{{{dxMin, dyMin}, {dxMax, dyMin}, {dxMax, dyMax}, {dxMin, dyMax}}}) {
                const double c = (d.x * vy - d.y * vx) / det;
                const double r = (ux * d.y - uy * d.x) / det;
                if (!std::isfinite(c) || !std::isfinite(r)) return true;
                cMin = std::min(cMin, c); cMax = std::max(cMax, c);
                rMin = std::min(rMin, r); rMax = std::max(rMax, r);
            }
            const int loC = static_cast<int>(std::max<double>(0.0, std::floor(cMin - 1e-6)));
            const int hiC = static_cast<int>(std::min<double>(static_cast<double>(cols - 1), std::ceil(cMax + 1e-6)));
            const int loR = static_cast<int>(std::max<double>(0.0, std::floor(rMin - 1e-6)));
            const int hiR = static_cast<int>(std::min<double>(static_cast<double>(rows - 1), std::ceil(rMax + 1e-6)));
            if (loC > hiC || loR > hiR) return false;
            outColMin = loC; outColMax = hiC;
            outRowMin = loR; outRowMax = hiR;
            return true;
        }
        return true;
    }

    void flattenRecursive(int cellId, const GeometryEngine::Transform2D& parentTransform,
                         int maxRecursion, int currentDepth, std::vector<int>& ancestors,
                         std::function<void(const SceneShape&, const GeometryEngine::Transform2D&)>& callback,
                         HierarchyTraversalContext& context) const {
        if (context.checkpoint) context.checkpoint();
        for (int c : ancestors) {
            if (c == cellId) return;
        }
        if (context.stats) ++context.stats->visitedCells;
        const auto cellBound = lookupBounds(cellId, context);
        if (context.viewport && outsideViewport(cellBound, parentTransform, *context.viewport)) {
            if (context.stats) ++context.stats->prunedCells;
            return;
        }
        const auto owner = context.owners.find(cellId);
        if (owner == context.owners.end()) return;
        ancestors.push_back(cellId);

        for (const auto* shape : owner->second.shapes) {
            if (context.checkpoint) context.checkpoint();
            if (context.stats) ++context.stats->candidateShapes;
            if (shape->type != ShapeType::INSTANCE) {
                callback(*shape, parentTransform);
                if (context.stats) ++context.stats->emittedShapes;
            }
        }

        if (maxRecursion >= 0 && currentDepth >= maxRecursion) {
            if (context.stoppedInstanceBoxCallback != nullptr) {
                for (const auto* instance : owner->second.instances) {
                    if (context.checkpoint) context.checkpoint();
                    const auto& inst = *instance;
                    if (inst.referencedCellId < 0) continue;
                    const auto childBound = lookupBounds(inst.referencedCellId, context);
                    if (!childBound.known || !childBound.box.valid()) continue;
                    if (context.viewport && outsideViewport(instanceBounds(inst, childBound), parentTransform, *context.viewport)) continue;
                    if (inst.transform.isArray()) {
                        const int cols = std::max(1, inst.transform.arrayCols);
                        const int rows = std::max(1, inst.transform.arrayRows);
                        int colMin = 0, colMax = cols - 1, rowMin = 0, rowMax = rows - 1;
                        if (context.viewport && !clipArrayIndexRange(inst, childBound, parentTransform, *context.viewport,
                                                                     cols, rows, colMin, colMax, rowMin, rowMax)) {
                            continue;
                        }
                        const int64_t visibleCount = static_cast<int64_t>(colMax - colMin + 1) * (rowMax - rowMin + 1);
                        if (visibleCount > 4096) {
                            const auto groupWorld = transformedBounds(instanceBounds(inst, childBound), parentTransform);
                            if (groupWorld.known && finiteBox(groupWorld.box)) {
                                (*context.stoppedInstanceBoxCallback)(groupWorld.box);
                            }
                            continue;
                        }
                        for (int row = rowMin; row <= rowMax; row++) {
                            for (int col = colMin; col <= colMax; col++) {
                                if (context.checkpoint) context.checkpoint();
                                InstanceTransform elem = inst.transform;
                                elem.x += col * inst.transform.arrayPitchX + row * inst.transform.arrayRowStepX;
                                elem.y += col * inst.transform.arrayColStepY + row * inst.transform.arrayPitchY;
                                elem.arrayCols = 0;
                                elem.arrayRows = 0;
                                auto elemTransform = parentTransform.multiply(elem.toMatrix());
                                const auto elemWorld = transformedBounds(childBound, elemTransform);
                                if (elemWorld.known && finiteBox(elemWorld.box) &&
                                    (!context.viewport || elemWorld.box.intersects(*context.viewport))) {
                                    (*context.stoppedInstanceBoxCallback)(elemWorld.box);
                                }
                            }
                        }
                    } else {
                        auto instTransform = parentTransform.multiply(inst.transform.toMatrix());
                        const auto instWorld = transformedBounds(childBound, instTransform);
                        if (instWorld.known && finiteBox(instWorld.box)) {
                            (*context.stoppedInstanceBoxCallback)(instWorld.box);
                        }
                    }
                }
            }
            ancestors.pop_back();
            return;
        }

        for (const auto* instance : owner->second.instances) {
            if (context.checkpoint) context.checkpoint();
            const auto& inst = *instance;
            if (context.stats) ++context.stats->candidateInstances;
            if (inst.referencedCellId < 0) continue;
            const auto childBound = lookupBounds(inst.referencedCellId, context);
            const auto groupLocalBound = instanceBounds(inst, childBound);
            if (context.viewport && outsideViewport(groupLocalBound, parentTransform, *context.viewport)) {
                if (context.stats) ++context.stats->prunedInstanceGroups;
                continue;
            }

            auto instTransform = parentTransform.multiply(inst.transform.toMatrix());
            const bool canCollapseSubpixel = context.subpixelInstanceCallback != nullptr &&
                context.subpixelInstanceSpanNm > 0.0 && childBound.known && childBound.box.valid();

            if (inst.transform.isArray()) {
                const int cols = std::max(1, inst.transform.arrayCols);
                const int rows = std::max(1, inst.transform.arrayRows);
                int colMin = 0, colMax = cols - 1, rowMin = 0, rowMax = rows - 1;
                if (context.viewport && !clipArrayIndexRange(inst, childBound, parentTransform, *context.viewport,
                                                             cols, rows, colMin, colMax, rowMin, rowMax)) {
                    if (context.stats) ++context.stats->prunedInstanceGroups;
                    continue;
                }

                // O(1) Sub-pixel Dense Lattice Collapse: when both array pitch vectors and unit-cell
                // bounding box project below a pixel in world space (e.g. 2000x2000 photonic crystal
                // lattice or memory array at full-chip zoom), collapse the visible slice into ONE solid
                // proxy rectangle without looping millions of elements!
                if (canCollapseSubpixel) {
                    const auto elemBaseWorld = transformedBounds(childBound, instTransform);
                    const Vec2 oW = parentTransform.apply({0.0, 0.0});
                    const Vec2 cW = parentTransform.apply({inst.transform.arrayPitchX, inst.transform.arrayColStepY});
                    const Vec2 rW = parentTransform.apply({inst.transform.arrayRowStepX, inst.transform.arrayPitchY});
                    const double colStepSpan = std::hypot(cW.x - oW.x, cW.y - oW.y);
                    const double rowStepSpan = std::hypot(rW.x - oW.x, rW.y - oW.y);
                    const double unitSpan = elemBaseWorld.known && finiteBox(elemBaseWorld.box)
                        ? std::max(elemBaseWorld.box.maxX - elemBaseWorld.box.minX,
                                   elemBaseWorld.box.maxY - elemBaseWorld.box.minY)
                        : std::numeric_limits<double>::infinity();
                    if (unitSpan <= context.subpixelInstanceSpanNm &&
                        colStepSpan <= context.subpixelInstanceSpanNm &&
                        rowStepSpan <= context.subpixelInstanceSpanNm) {
                        BBox sliceWorld;
                        const double ux = cW.x - oW.x, uy = cW.y - oW.y;
                        const double vx = rW.x - oW.x, vy = rW.y - oW.y;
                        for (const int cc : {colMin, colMax}) {
                            for (const int rr : {rowMin, rowMax}) {
                                const double ox = cc * ux + rr * vx;
                                const double oy = cc * uy + rr * vy;
                                sliceWorld = sliceWorld.unite(BBox(
                                    elemBaseWorld.box.minX + ox, elemBaseWorld.box.minY + oy,
                                    elemBaseWorld.box.maxX + ox, elemBaseWorld.box.maxY + oy));
                            }
                        }
                        if (context.viewport && sliceWorld.valid()) {
                            sliceWorld.minX = std::max(sliceWorld.minX, context.viewport->minX);
                            sliceWorld.minY = std::max(sliceWorld.minY, context.viewport->minY);
                            sliceWorld.maxX = std::min(sliceWorld.maxX, context.viewport->maxX);
                            sliceWorld.maxY = std::min(sliceWorld.maxY, context.viewport->maxY);
                        }
                        if (finiteBox(sliceWorld)) {
                            (*context.subpixelInstanceCallback)(inst.referencedCellId, sliceWorld);
                            if (context.stats) {
                                context.stats->collapsedSubpixelInstances +=
                                    static_cast<uint64_t>(colMax - colMin + 1) * (rowMax - rowMin + 1);
                            }
                            continue;
                        }
                    }
                }

                const int spanCols = colMax - colMin + 1;
                const int spanRows = rowMax - rowMin + 1;
                const int64_t visibleProduct = static_cast<int64_t>(spanCols) * spanRows;
                const int clampedRowMax = visibleProduct > kMaxArrayInstances
                    ? rowMin + static_cast<int>(std::max<int64_t>(1, kMaxArrayInstances / std::max(1, spanCols))) - 1
                    : rowMax;

                for (int row = rowMin; row <= clampedRowMax; row++) {
                    for (int col = colMin; col <= colMax; col++) {
                        if (context.checkpoint) context.checkpoint();
                        InstanceTransform elem = inst.transform;
                        elem.x += col * inst.transform.arrayPitchX + row * inst.transform.arrayRowStepX;
                        elem.y += col * inst.transform.arrayColStepY + row * inst.transform.arrayPitchY;
                        elem.arrayCols = 0;
                        elem.arrayRows = 0;
                        auto elemTransform = parentTransform.multiply(elem.toMatrix());
                        if (canCollapseSubpixel) {
                            const auto elemWorld = transformedBounds(childBound, elemTransform);
                            if (elemWorld.known && finiteBox(elemWorld.box)) {
                                if (context.viewport && !elemWorld.box.intersects(*context.viewport)) continue;
                                const double span = std::max(elemWorld.box.maxX - elemWorld.box.minX,
                                                             elemWorld.box.maxY - elemWorld.box.minY);
                                if (span <= context.subpixelInstanceSpanNm) {
                                    (*context.subpixelInstanceCallback)(inst.referencedCellId, elemWorld.box);
                                    if (context.stats) ++context.stats->collapsedSubpixelInstances;
                                    continue;
                                }
                            }
                        }
                        flattenRecursive(inst.referencedCellId, elemTransform,
                                       maxRecursion, currentDepth + 1, ancestors, callback, context);
                    }
                }
            } else {
                if (canCollapseSubpixel) {
                    const auto instWorld = transformedBounds(childBound, instTransform);
                    if (instWorld.known && finiteBox(instWorld.box)) {
                        const double span = std::max(instWorld.box.maxX - instWorld.box.minX,
                                                     instWorld.box.maxY - instWorld.box.minY);
                        if (span <= context.subpixelInstanceSpanNm) {
                            (*context.subpixelInstanceCallback)(inst.referencedCellId, instWorld.box);
                            if (context.stats) ++context.stats->collapsedSubpixelInstances;
                            continue;
                        }
                    }
                }
                flattenRecursive(inst.referencedCellId, instTransform,
                               maxRecursion, currentDepth + 1, ancestors, callback, context);
            }
        }

        ancestors.pop_back();
    }

    void assignDefaultColor(LayerProperties& lp) {
        static const uint32_t defaultColors[] = {
            0xFFFF0000, 0xFF00FF00, 0xFF0000FF, 0xFFFFFF00,
            0xFFFF00FF, 0xFF00FFFF, 0xFFFF8000, 0xFF8000FF,
            0xFF00FF80, 0xFF8080FF, 0xFFFF8080, 0xFF80FF80,
            0xFF808080, 0xFFC0C000, 0xFF00C0C0, 0xFFC000C0
        };
        int idx = std::abs(lp.key.layer) % 16;
        lp.fillColor = defaultColors[idx];
        lp.lineColor = 0xFFFFFFFF;
    }
};

inline BBox CellInstance::bbox(const Cell* /*referencedCell*/) const {
    return BBox(transform.x, transform.y, transform.x, transform.y);
}

} // namespace hongtu

#endif // HONGTU_SCENE_GRAPH_H
