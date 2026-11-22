/**
 * HongTu EDA - Scene Graph
 * Hierarchical cell/instance management with transform propagation.
 * Supports KLayout-style cell hierarchy: Cell → shapes + instances → child Cells.
 */
#ifndef HONGTU_SCENE_GRAPH_H
#define HONGTU_SCENE_GRAPH_H

#include "spatial_index.h"
#include "geometry_engine.h"
#include "triangulator.h"
#include <string>
#include <vector>
#include "layout_port.h"
#include <unordered_map>
#include <memory>
#include <functional>

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

// 元素/结构属性：GDSII PROPATTR/PROPVALUE 与 OASIS PROPERTY 的统一内存表示。
//   attr  : GDSII 属性码（OASIS 一般属性恒 0）
//   name  : OASIS 属性名（GDSII 为空）
//   value : 面向 UI/查询的文本值
// 空 vector = 无属性；std::vector 尺寸固定，故本结构不改变 SceneShape 的字段布局与大小，
// DRC / 层级展开热路径只读 points/bbox，不触及属性。
struct SceneProperty {
    int attr = 0;
    std::string name;
    std::string value;
    uint8_t dtype = 6;
};

/** 按 GDSII 属性码查值；未找到返回 nullptr。 */
inline const SceneProperty* findProperty(const std::vector<SceneProperty>& props, int attr) {
    for (const auto& p : props) {
        if (p.attr == attr) {
            return &p;
        }
    }
    return nullptr;
}

/** 按 OASIS 属性名查值；未找到返回 nullptr。 */
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
    // 必须显式零初始化：reader/NAPI 只填 pathWidth，未初始化会把垃圾值当线宽用于轮廓化
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
        // Expand for path width（起止延伸的斜 45° 路径最多多出 0.41w，按整宽保守）
        if (type == ShapeType::PATH && pathWidth > 0) {
            double hw = pathWidth * 0.5;
            box = box.expand(pathType == 4 ? hw + std::max(std::abs(pathBeginExtension), std::abs(pathEndExtension)) : (pathType == 0 ? hw : pathWidth));
        }
        return box;
    }
};

/**
 * SceneShape → 测量/渲染用有效多边形（世界坐标 nm）：
 * RECT/BOX 的 2 点对角线展成 4 角；PATH 中心线按 pathWidth + pathType 轮廓化；
 * 其余（POLYGON 等）原样返回；退化图形返回空（调用方据此跳过）。
 *
 * DRC / 图像导出 / GL 条带共用此单一口径，禁止各自复制一份轮廓逻辑。
 */
inline std::vector<Vec2> effectivePolygon(const SceneShape& shape) {
    if (shape.type == ShapeType::NODE) {
        return {}; // Circuit metadata has coordinates but no filled geometry.
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

/** Transform the centerline first for absolute-width PATHs: MAG changes positions,
 * but must not multiply negative GDS WIDTH. Explicit extensions still follow MAG. */
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

    /**
     * GDSII / KLayout-compatible instance matrix.
     * Application order on a local point: Mag → MirrorX → Rotation → Translation.
     * With multiply(A,B) meaning "apply B then A", we build:
     *   T * R * M * S
     */
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

    /// 结构级属性（GDSII 结构 PROPATTR/PROPVALUE / OASIS 一般属性）。
    /// 新增字段，追加在末尾：既有聚合初始化（如 Cell{0,"TOP",{},{},...}）仍然合法。
    std::vector<SceneProperty> properties;
    std::vector<std::string> contextRecords;
};

/**
 * 世界(nm) → 图像像素 的统一映射。
 *
 * 与 ArkTS LayoutCanvasView.worldToScreenX/worldToScreenY 严格同口径：
 *   pixelX=(worldX+viewOffsetX)*z；pixelY=(viewOffsetY-worldY)*z。
 * 世界 Y 向上，图像像素行号向下；SVG/PNG 在此统一翻转显示 Y。
 * GL 顶点仍是原始世界坐标，ArkTS 相机将它映射到同样 Y 向上的 NDC。
 */
struct ViewProjection {
    double originX = 0;   // 图像第 0 列/行对应的世界坐标（= region.minX / maxY）
    double originY = 0;
    double scale = 1;     // 像素 / nm

    double toPixelX(double x) const { return (x - originX) * scale; }
    double toPixelY(double y) const { return (originY - y) * scale; }
    double toWorldX(double px) const { return originX + px / scale; }
    double toWorldY(double py) const { return originY - py / scale; }

    /** 等比铺满：把 region 放进 outW×outH 画布（世界 Y 向上，与画布一致） */
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

/**
 * Layout: the complete design database.
 * Owns all shapes, instances, cells, and layer properties.
 * Provides spatial indexing for fast queries.
 */
class Layout {
public:
    Layout() : nextShapeId_(1), nextInstanceId_(1), nextCellId_(1), topCellId_(-1) {}
    enum class SpatialIndexBuild { Immediate, Deferred };

    // ==================== Data Access ====================

    std::vector<SceneShape> shapes;
    std::vector<CellInstance> instances;
    std::vector<Cell> cells;
    std::unordered_map<LayerKey, LayerProperties, LayerKeyHash> layerProps;

    // Metadata
    std::string libName;
    std::vector<std::string> layoutContextRecords;
    std::vector<SceneProperty> libProperties;
    std::vector<std::string> cellKeys;
    std::vector<LayoutPort> ports;
    std::vector<LayoutCrossSection> crossSections;
    // 单位元数据必须有确定初值：未解析到 UNITS 的 Layout 曾被读到栈垃圾
    double dbUnit = 1e-9;       // Database unit in meters (e.g., 1e-9 = 1nm)
    double userUnit = 1e-6;     // User unit in meters (e.g., 1e-6 = 1um)
    int64_t modTime = 0;
    int64_t accessTime = 0;

    int topCellId() const { return topCellId_; }
    void setTopCell(int id) { topCellId_ = id; }

    // ==================== Shape Management ====================

    int64_t addShape(const SceneShape& shape, SpatialIndexBuild spatialIndexBuild = SpatialIndexBuild::Immediate) {
        int64_t id = shape.id > 0 ? shape.id : nextShapeId_++;
        SceneShape s = shape;
        s.id = id;
        shapes.push_back(s);

        // Readonly scene construction retains all geometry but does not need a
        // spatial tree. Actual queries rebuild it through ensureSpatialIndex.
        if (spatialIndexBuild == SpatialIndexBuild::Deferred) {
            spatialDirty_ = true;
        } else {
            BBox box = s.bbox();
            if (box.valid()) spatialIndex_.insert((int)shapes.size() - 1, box);
        }

        // Update cell membership by cell.id（非 vector 下标）
        if (Cell* owner = findCell(s.ownerCellId)) {
            owner->shapeIds.push_back(id);
        }

        // Register layer
        registerLayer(s.layerKey);

        if (id >= nextShapeId_) nextShapeId_ = id + 1;
        return id;
    }

    void removeShape(int64_t id) {
        for (int i = 0; i < (int)shapes.size(); i++) {
            if (shapes[i].id == id) {
                shapes.erase(shapes.begin() + i);
                // 索引以 vector 下标为 key，erase 之后其后的 id 全部左移，
                // 只能整体重建。但逐次重建会让 N 次删除退化成 O(N²)（批量删除、
                // 宏回放尤其明显）——这里只标脏，下一次查询前惰性重建一次。
                spatialDirty_ = true;
                return;
            }
        }
    }

    SceneShape* findShape(int64_t id) {
        for (auto& s : shapes) {
            if (s.id == id) return &s;
        }
        return nullptr;
    }

    // ==================== Instance Management ====================

    int64_t addInstance(const CellInstance& inst) {
        int64_t id = inst.id > 0 ? inst.id : nextInstanceId_++;
        CellInstance ci = inst;
        ci.id = id;
        instances.push_back(ci);

        if (Cell* owner = findCell(ci.ownerCellId)) {
            owner->instanceIds.push_back(id);
        }

        if (id >= nextInstanceId_) nextInstanceId_ = id + 1;
        return id;
    }

    CellInstance* findInstance(int64_t id) {
        for (auto& inst : instances) {
            if (inst.id == id) return &inst;
        }
        return nullptr;
    }

    // ==================== Cell Management ====================

    int addCell(const std::string& name) {
        int id = nextCellId_++;
        Cell cell;
        cell.id = id;
        cell.name = name;
        cells.push_back(cell);
        return id;
    }

    /**
     * 按稳定 id 添加 Cell（与 GDS reader 的 cells[] 下标对齐）。
     * 若 id 已存在则更新名称并返回该 id；并保证 nextCellId_ > id。
     */
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

    // ==================== Top Cell Resolution ====================

    void resolveTopCell() {
        // Top cell = cell not referenced by any instance
        std::vector<bool> referenced(cells.size(), false);
        for (const auto& inst : instances) {
            for (int i = 0; i < (int)cells.size(); i++) {
                if (cells[i].id == inst.referencedCellId) {
                    referenced[i] = true;
                    break;
                }
            }
        }

        // Find unreferenced cells
        std::vector<int> topCandidates;
        for (int i = 0; i < (int)cells.size(); i++) {
            if (!referenced[i]) {
                topCandidates.push_back(i);
                cells[i].isTopCell = true;
            }
        }

        // If multiple candidates, pick the one with most shapes
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
    }

    // ==================== Spatial Queries ====================

    std::vector<int> queryPoint(double x, double y) const {
        ensureSpatialIndex();
        return spatialIndex_.queryPoint(x, y);
    }

    /** Non-query observation; an empty tree can also be ready after rebuild. */
    bool spatialIndexReady() const { return !spatialDirty_; }

    /** 索引标脏时先重建一次（仅在实际查询时），保证删除风暴不退化为 O(N²) */
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

    // ==================== Hierarchy Traversal ====================

    /**
     * Flatten hierarchy: collect all shapes visible from a cell,
     * applying instance transforms recursively.
     *
     * Depth model (aligned with KLayout hierarchy levels / UI slider):
     *   hierarchyDepth=1 → only local geometry of cellId (no child expansion)
     *   hierarchyDepth=2 → local + one level of referenced cell geometry
     *   hierarchyDepth=N → recurse N-1 levels
     *
     * @param cellId Starting cell
     * @param hierarchyDepth UI depth 1..N (-1 = unlimited)
     * @param callback Called for each non-instance shape with its accumulated transform
     */
    struct HierarchyTraversalStats {
        uint64_t visitedCells = 0;
        uint64_t prunedCells = 0;
        uint64_t candidateShapes = 0;
        uint64_t emittedShapes = 0;
        uint64_t candidateInstances = 0;
        uint64_t prunedInstanceGroups = 0;
    };

    void flattenHierarchy(int cellId, int hierarchyDepth,
                         std::function<void(const SceneShape&, const GeometryEngine::Transform2D&)> callback,
                         const BBox* viewport = nullptr, HierarchyTraversalStats* stats = nullptr,
                         std::function<void()> checkpoint = nullptr,
                         const std::function<void(const BBox&)>* stoppedInstanceBoxCallback = nullptr) const {
        // Convert UI depth to max child recursion depth
        const int maxRecursion = hierarchyDepth < 0 ? -1 : std::max(0, hierarchyDepth - 1);
        // Build a traversal-local owner index: public vectors can be changed directly,
        // so retaining a cache across edits would risk stale geometry/ownership.
        HierarchyTraversalContext context;
        context.checkpoint = std::move(checkpoint);
        context.viewport = viewport && finiteBox(*viewport) ? viewport : nullptr;
        context.stats = stats;
        context.stoppedInstanceBoxCallback = stoppedInstanceBoxCallback;
        if (stats) *stats = {};
        for (const auto& shape : shapes) { if (context.checkpoint) context.checkpoint(); context.owners[shape.ownerCellId].shapes.push_back(&shape); }
        for (const auto& instance : instances) { if (context.checkpoint) context.checkpoint(); context.owners[instance.ownerCellId].instances.push_back(&instance); }
        if (context.viewport || stoppedInstanceBoxCallback != nullptr) subtreeBounds(cellId, context);
        std::vector<int> ancestors;
        flattenRecursive(cellId, GeometryEngine::Transform2D::identity(), maxRecursion, 0,
                         ancestors, callback, context);
    }

    /**
     * Get all shapes in a cell (non-recursive, only direct ownership).
     */
    std::vector<const SceneShape*> getCellShapes(int cellId) const {
        std::vector<const SceneShape*> result;
        for (const auto& s : shapes) {
            if (s.ownerCellId == cellId) {
                result.push_back(&s);
            }
        }
        return result;
    }

    /**
     * Get all instances in a cell.
     */
    std::vector<const CellInstance*> getCellInstances(int cellId) const {
        std::vector<const CellInstance*> result;
        for (const auto& inst : instances) {
            if (inst.ownerCellId == cellId) {
                result.push_back(&inst);
            }
        }
        return result;
    }

    // ==================== Layer Management ====================

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

    // ==================== Statistics ====================

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

    // ==================== Bulk Operations ====================

    void rebuildSpatialIndex() const {
        // A failed lazy build must remain dirty so the next query can retry.
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
        nextShapeId_ = 1;
        nextInstanceId_ = 1;
        nextCellId_ = 1;
        topCellId_ = -1;
    }

private:
    mutable RTree<int> spatialIndex_;
    mutable bool spatialDirty_ = true;   // 初始为空树，首次查询时建
    int64_t nextShapeId_;
    int64_t nextInstanceId_;
    int nextCellId_;
    int topCellId_;

    /// 单个 AREF 阵列展开的实例上限（与 gdsii_reader COLROW DoS 防护同值）
    static constexpr int64_t kMaxArrayInstances = 1000000;

    struct HierarchyOwner {
        std::vector<const SceneShape*> shapes;
        std::vector<const CellInstance*> instances;
    };
    struct HierarchyBounds {
        BBox box;
        bool known = true;
    };
    struct HierarchyTraversalContext {
        std::function<void()> checkpoint;
        std::unordered_map<int, HierarchyOwner> owners;
        std::unordered_map<int, HierarchyBounds> bounds;
        std::unordered_map<int, int> boundState;
        const BBox* viewport = nullptr;
        HierarchyTraversalStats* stats = nullptr;
        const std::function<void(const BBox&)>* stoppedInstanceBoxCallback = nullptr;
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

    // Covers an entire AREF without expanding each member. Array vectors are in
    // the parent coordinate system, independent of the referenced cell transform.
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

    static HierarchyBounds subtreeBounds(int cellId, HierarchyTraversalContext& context) {
        if (context.checkpoint) context.checkpoint();
        if (context.boundState[cellId] == 2) return context.bounds[cellId];
        if (context.boundState[cellId] == 1) return {BBox(), false}; // Cyclic graph: never use an incomplete bound.
        context.boundState[cellId] = 1;
        HierarchyBounds result;
        const auto owner = context.owners.find(cellId);
        if (owner != context.owners.end()) {
            for (const auto* shape : owner->second.shapes) {
                if (context.checkpoint) context.checkpoint();
                if (shape->type == ShapeType::INSTANCE) continue;
                // Absolute GDS WIDTH is invariant under accumulated magnification.
                // A local box is unsafe under shrinking parents; leave this branch uncullable.
                if (shape->type == ShapeType::PATH && shape->pathWidthAbsolute) result.known = false;
                auto points = shape->type == ShapeType::PATH ? effectivePolygon(*shape) : shape->points;
                for (const auto& p : points) {
                    if (!std::isfinite(p.x) || !std::isfinite(p.y)) { result.known = false; continue; }
                    result.box = result.box.unite(BBox(p.x, p.y, p.x, p.y));
                }
            }
            for (const auto* instance : owner->second.instances) {
                if (context.checkpoint) context.checkpoint();
                if (instance->referencedCellId < 0) continue;
                const auto child = instanceBounds(*instance, subtreeBounds(instance->referencedCellId, context));
                result.known = result.known && child.known;
                result.box = result.box.unite(child.box);
            }
        }
        context.bounds[cellId] = result;
        context.boundState[cellId] = 2;
        return result;
    }

    static bool outsideViewport(const HierarchyBounds& bound, const GeometryEngine::Transform2D& transform,
                                const BBox& viewport) {
        if (!bound.known) return false;
        if (!bound.box.valid()) return true;
        const auto world = transformedBounds(bound, transform);
        if (!world.known || !finiteBox(world.box)) return false;
        const double magnitude = std::max({1.0, std::abs(world.box.minX), std::abs(world.box.maxX),
            std::abs(world.box.minY), std::abs(world.box.maxY)});
        // Guard floating point rotation at touching boundaries. Over-inclusion is safe.
        return !world.box.expand(1e-7 + magnitude * 1e-12).intersects(viewport);
    }

    void flattenRecursive(int cellId, const GeometryEngine::Transform2D& parentTransform,
                         int maxRecursion, int currentDepth, std::vector<int>& ancestors,
                         std::function<void(const SceneShape&, const GeometryEngine::Transform2D&)>& callback,
                         HierarchyTraversalContext& context) const {
        if (context.checkpoint) context.checkpoint();
        // 循环引用（A→B→A / A→A）必须剪枝，否则 maxRecursion<0 时无限递归栈溢出；
        // 与 ArkTS HierarchyExpandService 的 visiting 栈同语义。
        for (int c : ancestors) {
            if (c == cellId) return;
        }
        if (context.stats) ++context.stats->visitedCells;
        if (context.viewport && outsideViewport(subtreeBounds(cellId, context), parentTransform, *context.viewport)) {
            if (context.stats) ++context.stats->prunedCells;
            return;
        }
        const auto owner = context.owners.find(cellId);
        if (owner == context.owners.end()) return;
        ancestors.push_back(cellId);

        // Emit local geometry at every visited level (currentDepth is child-recursion level)
        for (const auto* shape : owner->second.shapes) {
            if (context.checkpoint) context.checkpoint();
            if (context.stats) ++context.stats->candidateShapes;
            if (shape->type != ShapeType::INSTANCE) {
                callback(*shape, parentTransform);
                if (context.stats) ++context.stats->emittedShapes;
            }
        }

        // Descend into instances only while remaining recursion budget allows
        if (maxRecursion >= 0 && currentDepth >= maxRecursion) {
            if (context.stoppedInstanceBoxCallback != nullptr) {
                for (const auto* instance : owner->second.instances) {
                    if (context.checkpoint) context.checkpoint();
                    const auto& inst = *instance;
                    if (inst.referencedCellId < 0) continue;
                    const auto childBound = subtreeBounds(inst.referencedCellId, context);
                    if (!childBound.known || !childBound.box.valid()) continue;
                    if (context.viewport && outsideViewport(instanceBounds(inst, childBound), parentTransform, *context.viewport)) continue;
                    if (inst.transform.isArray()) {
                        const int cols = std::max(1, inst.transform.arrayCols);
                        const int rows = std::max(1, inst.transform.arrayRows);
                        const int64_t product = static_cast<int64_t>(cols) * rows;
                        if (product > 4096) {
                            const auto groupWorld = transformedBounds(instanceBounds(inst, childBound), parentTransform);
                            if (groupWorld.known && finiteBox(groupWorld.box)) {
                                (*context.stoppedInstanceBoxCallback)(groupWorld.box);
                            }
                            continue;
                        }
                        for (int row = 0; row < rows; row++) {
                            for (int col = 0; col < cols; col++) {
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
            if (context.viewport && outsideViewport(instanceBounds(inst, subtreeBounds(inst.referencedCellId, context)),
                                                    parentTransform, *context.viewport)) {
                if (context.stats) ++context.stats->prunedInstanceGroups;
                continue;
            }

            // parent * instance: apply instance first, then parent
            auto instTransform = parentTransform.multiply(inst.transform.toMatrix());

            if (inst.transform.isArray()) {
                // DoS 防护：与 gdsii_reader COLROW 同一硬上限
                const int cols = std::max(1, inst.transform.arrayCols);
                const int rows = std::max(1, inst.transform.arrayRows);
                const int64_t product = static_cast<int64_t>(cols) * rows;
                const int clampedRows = product > kMaxArrayInstances
                    ? static_cast<int>(std::max<int64_t>(1, kMaxArrayInstances / cols)) : rows;
                for (int row = 0; row < clampedRows; row++) {
                    for (int col = 0; col < cols; col++) {
                        if (context.checkpoint) context.checkpoint();
                        // 阵列步长在**父坐标系**中平移（GDSII AREF DX/DY 不随实例
                        // 旋转/镜像/放大）：改写 origin 后复用同一 toMatrix() 合成，
                        // 保证与单层 SREF 完全同序（mag→mirrorX→rot→trans）。
                        InstanceTransform elem = inst.transform;
                        elem.x += col * inst.transform.arrayPitchX + row * inst.transform.arrayRowStepX;
                        elem.y += col * inst.transform.arrayColStepY + row * inst.transform.arrayPitchY;
                        elem.arrayCols = 0;      // 本元素已展开，禁止递归再走阵列分支
                        elem.arrayRows = 0;
                        auto elemTransform = parentTransform.multiply(elem.toMatrix());
                        flattenRecursive(inst.referencedCellId, elemTransform,
                                       maxRecursion, currentDepth + 1, ancestors, callback, context);
                    }
                }
            } else {
                flattenRecursive(inst.referencedCellId, instTransform,
                               maxRecursion, currentDepth + 1, ancestors, callback, context);
            }
        }

        ancestors.pop_back();
    }

    void assignDefaultColor(LayerProperties& lp) {
        // KLayout-style default colors based on layer number
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

// Inline implementation of CellInstance::bbox
inline BBox CellInstance::bbox(const Cell* referencedCell) const {
    // Would need access to the referenced cell's bbox
    // For now, return a point bbox at the instance position
    return BBox(transform.x, transform.y, transform.x, transform.y);
}

} // namespace hongtu

#endif // HONGTU_SCENE_GRAPH_H
