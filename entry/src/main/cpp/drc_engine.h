/**
 * HongTu EDA - DRC Engine (Native C++)
 *
 * 原生几何 DRC 内核：R-Tree 按层索引 + 真实边到边距离测量 + 深度可控的层级展开。
 * 经 NAPI runDrc(rules, ownerCellId?, hierarchyDepth?) 暴露给 ArkTS DrcService
 * （native 主路径，AABB 预检查为回退）。host 冒烟：tools/drc_smoke.cpp。
 *
 * 能力：
 * - 层级展开：把 SREF/AREF 实例内的真实几何变换到**根 Cell 坐标系**后一并检查。
 *   遍历、实例矩阵合成（mag→mirrorX→rot→trans，世界 Y 轴向上）、AREF 阵列展开、
 *   循环引用剪枝全部复用 scene_graph.h 的 flattenHierarchy —— 本文件不重实现遍历。
 * - 最小/最大线宽（多边形内接宽度；PATH 用 pathWidth，并按实例放大系数折算）
 * - 最小间距（同层，R-Tree 邻域 + polygonToPolygonDistance 边到边）
 * - 最小/最大面积、包围（enclosure）、交叠（overlap）
 * - 窗口密度（min/max）、凹口（notch）
 * - 派生层布尔组合（experimental clipper，非签核）
 *
 * ⚠ 适用范围（诚实声明，必须随结果一起呈现给用户）：
 * - config.hierarchyDepth = 0（默认）→ 仅检查各 Cell 的本地几何，与旧「快速几何预检查」
 *   逐图形同口径；= 1 → 本地 + 一层实例（KLayout 展开语义的默认起点）；更大值继续下钻。
 *   本引擎把 <0 归一为 0，避免调用方误传导致无限展开。
 * - 展开是**逐图形**的（默认口径，config.mergeSameLayer = false）：同层多边形之间不做
 *   布尔合并，因此「只有合并后才暴露」的宽度 / 间距 / 凹口仍会漏检；同一子 Cell 被多次
 *   实例化时按实例重复报告（KLayout flattened 模式同行为，但签核流程通常用 hierarchical
 *   模式 + 实例去重，本引擎不做）。
 * - ⚑ config.mergeSameLayer = true → **merged-region 口径**：每层（按 datatype 分桶）先做
 *   真实布尔并，再按合并后的区域测宽度 / 间距 / 面积，于是只有合并后才显现的 neck 能被
 *   抓到（例：三根条拼出的工字形，合并后细腰 = 连接条的宽度；逐图形口径永远看不到）。
 *   区域宽度改用 GeometryEngine::measureRegionMinWidth（面对面边对 + 内法线射线），
 *   因为凸包口径会把凹口直接填平。没能合并的层插入 ruleId="DRC.MERGE" 告警，
 *   stats().mergedRegions / mergeSkipped / mergedRegionCount 供 UI 如实报告本次口径。
 *   两种口径都仍是几何近似，**不可作签核**。
 * - 布尔 / offset 使用官方 Clipper2。公开met1子集的合并区域宽度/间距/面积已与
 *   KLayout作独立矩形组合对照；斜边宽度与其它检查器仍是预检查，未构成完整工艺规则库。
 * - 展开图形数受 config.maxCheckedShapes 上限约束；命中上限时**不静默**：剩余图形丢弃、
 *   stats().truncated=true，并在违规列表首项插入 ruleId="DRC.TRUNC" 的完整性告警。
 *
 * 结论：本内核定位为「快速几何预检查」，**不可作签核**，与 KLayout 签核级 DRC 有明确差距。
 */
#ifndef HONGTU_DRC_ENGINE_H
#define HONGTU_DRC_ENGINE_H

#include "demo_layers.h"

#include "scene_graph.h"
#include "geometry_engine.h"
#include "spatial_index.h"
#include "clipper_engine.h"
#include "triangulator.h"
#include "native_job_control.h"
#include <string>
#include <vector>
#include <map>
#include <functional>
#include <unordered_map>
#include <algorithm>
#include <cmath>

namespace hongtu {

// DRC violation
struct DrcViolation {
    int64_t id;
    std::string ruleName;
    std::string ruleId;
    std::string message;
    double x, y;           // Location (nm)，坐标系 = 本次检查的根 Cell（未展开时为图形自身 Cell）
    double value;          // Measured value
    double limit;          // Rule limit
    int layer;
    int datatype;
    int64_t shapeId1;      // First shape involved
    int64_t shapeId2;      // Second shape (for spacing)
    bool fromInstance = false;  // true → 图形来自 SREF/AREF 展开，shapeId 属子 Cell
    int sourceCellId = -1;      // 图形真正归属的 Cell id（展开时 = 子 Cell）
    BBox bbox;             // Violation region
};

// DRC rule types
enum class DrcRuleType {
    MIN_WIDTH,
    MIN_SPACING,
    MAX_WIDTH,
    MIN_AREA,
    MAX_AREA,
    MIN_ENCLOSURE,
    MIN_OVERLAP,
    MAX_DENSITY,
    MIN_DENSITY,
    MIN_NOTCH,
    MIN_EXTENSION,
    DENSITY_UNIFORMITY
};

// DRC rule definition
struct DrcRule {
    std::string id;
    std::string name;
    DrcRuleType type;
    int layer1;
    int datatype1;
    int layer2;         // For two-layer rules (enclosure, spacing between layers)
    int datatype2;
    bool exactDatatype1 = false;
    bool exactDatatype2 = false;
    bool matchesDatatype1(int value) const { return (datatype1 == 0 && !exactDatatype1) || value == datatype1; }
    bool matchesDatatype2(int value) const { return (datatype2 == 0 && !exactDatatype2) || value == datatype2; }
    double value;       // Rule limit (nm)
    double value2;      // Secondary parameter (e.g., window size for density)
    bool enabled;
    std::string description;

    DrcRule() : type(DrcRuleType::MIN_WIDTH), layer1(0), datatype1(0),
               layer2(-1), datatype2(0), value(0), value2(0), enabled(true) {}
};

// DRC ruleset
struct DrcRuleset {
    std::string name;
    std::string technology;  // e.g., "28nm", "14nm", "7nm"
    std::vector<DrcRule> rules;
};

// DRC engine configuration
struct DrcConfig {
    std::function<void()> checkpoint;
    bool hasScopeBox = false;
    BBox scopeBox;
    bool hierarchical = false;    // 历史标志：层级展开现由 hierarchyDepth 表达
    bool tiling = false;          // Tile large designs
    double tileSize = 100000;     // Tile size in nm (100um default)
    double tileOverlap = 1000;    // Overlap between tiles (1um)
    int maxViolations = 10000;    // Global display-row budget; completeness notices are reserved
    std::string ruleFilter;       // Filter rules by name substring
    int ownerCellFilter = -1;     // 仅检查指定 Cell 的本地几何（-1 = 全部 Cell）

    // ==================== 层级展开（对齐 KLayout flattened DRC）====================
    /**
     * 展开深度：
     *   0  = 仅本地几何（旧行为，最快预检查）
     *   1  = 本地 + 一层 SREF/AREF（KLayout 风格默认）
     *   n>1= 向下展开 n 层；<0 归一为 0
     */
    int hierarchyDepth = 0;
    /// 展开根 Cell（-1 → ownerCellFilter → layout.topCellId()）
    int rootCellId = -1;
    /// 参与检查的图形总数上限（组合爆炸防护）；超限丢弃余量并上报 DRC.TRUNC
    int maxCheckedShapes = 200000;

    // ==================== 同层布尔合并（merged-region 口径，默认关闭）====================
    /**
     * true → 每一层的同层图形先做**真实布尔并**（clipper_engine.h 的 GeneralClipper），
     * 再按「合并后的区域」测宽度 / 间距 / 面积：于是只有合并后才显现的 neck（三根条
     * 拼出的细腰）与合并后才消失的间距能够暴露出来 —— 这正是逐图形口径漏检的那一类。
     * false（默认）→ 逐图形测量，与旧行为、旧断言完全一致。
     * 合并失败或超过上限时**不会**静默回退：stats().mergeSkipped = true，
     * 违规文本带 [merged region] / [merge skipped] 标注，调用方必须如实呈现。
     */
    bool mergeSameLayer = false;
    /// 单层参与合并的轮廓数上限；总顶点数另受 GeneralClipper::kMaxEdges 限制
    int maxMergeContoursPerLayer = 200000;
};

/** 单次 run() 的展开/完整性统计（调用方据此如实标注结果口径） */
struct DrcRunStats {
    int checkedShapes = 0;        // 实际参与检查的图形数（含展开）
    int instanceShapes = 0;       // 其中来自实例展开的图形数
    int skippedOverCap = 0;       // 因上限被丢弃的图形数
    bool truncated = false;       // true → 结果不完整，任何「0 违规」都不可信
    bool hierarchyApplied = false; // false → 未展开（depth=0 或无根 Cell），仅本地几何
    int requestedDepth = 0;
    int effectiveDepth = 0;
    int rootCellId = -1;

    // ==================== 合并区域口径（UI 必须据此报告"本次跑的是哪种模式"）====
    bool mergedRegions = false;      // true → 宽度/间距/面积按合并后的区域测量
    bool mergeSkipped = false;       // true → 有层未能合并（超限/引擎降级），该层仍逐图形
    int mergedInputContours = 0;     // 参与合并的输入轮廓总数
    int mergedRegionCount = 0;       // 合并后得到的区域总数（含带孔区域）
    std::string mergeNote;           // 机器可读原因：over-cap / approximated / ...
    uint64_t totalViolationRows = 0; // 检查实际产生的行数，包含因展示预算未返回的行
    uint64_t droppedViolationRows = 0;
};

/**
 * DrcEngine: High-performance native DRC checker.
 */
class DrcEngine {
public:
    /// 展开图形数命中上限时插入的完整性告警 ruleId（非规则违例，但必须让用户看到）
    static constexpr const char kTruncationRuleId[] = "DRC.TRUNC";
    /// 请求了 merged-region 口径但某些层没能合并时的告警 ruleId（同样非规则违例）
    static constexpr const char kMergeSkippedRuleId[] = "DRC.MERGE";
    static constexpr const char kMeasurementSkippedRuleId[] = "DRC.MEASURE";
    static constexpr const char kOutputTruncatedRuleId[] = "DRC.OUTPUT";
    static constexpr const char kExecutionSkippedRuleId[] = "DRC.EXEC";

    DrcEngine() : nextViolationId_(1) {}

    // ==================== Rule Management ====================

    void setRuleset(const DrcRuleset& ruleset) {
        ruleset_ = ruleset;
    }

    void addRule(const DrcRule& rule) {
        ruleset_.rules.push_back(rule);
    }

    void clearRules() {
        ruleset_.rules.clear();
    }

    const DrcRuleset& ruleset() const { return ruleset_; }

    /// 最近一次 run() 的展开/完整性统计
    const DrcRunStats& lastRunStats() const { return stats_; }

    // ==================== Execution ====================

    using ProgressCallback = std::function<void(int percent, const std::string& message)>;

    /**
     * Run DRC on the layout.
     * @param layout The design database
     * @param config Engine configuration（hierarchyDepth 控制实例展开）
     * @param progress Optional progress callback
     * @return Vector of violations（hierarchyDepth>0 时坐标在根 Cell 系下）
     */
    std::vector<DrcViolation> run(const Layout& layout, const DrcConfig& config = DrcConfig(),
                                  ProgressCallback progress = nullptr) {
        violations_.clear();
        stats_ = DrcRunStats();
        outputRowCap_ = std::max(0, config.maxViolations);
        outputRows_ = 0;
        checkpoint_ = config.checkpoint;
        checkCancellation();
        nextViolationId_ = 1;

        // Filter rules
        std::vector<const DrcRule*> activeRules;
        for (const auto& rule : ruleset_.rules) {
            checkCancellation();
            if (!rule.enabled) continue;
            if (!config.ruleFilter.empty() &&
                rule.name.find(config.ruleFilter) == std::string::npos &&
                rule.id.find(config.ruleFilter) == std::string::npos) {
                continue;
            }
            activeRules.push_back(&rule);
        }

        int totalRules = (int)activeRules.size();
        if (totalRules == 0) return violations_;

        // Build spatial index per layer for fast queries
        // （图形集合按 config.hierarchyDepth 决定是否包含 SREF/AREF 展开几何）
        buildLayerIndices(layout, config);

        // 完整性告警置于首位：命中上限时结果不完整，绝不能被读成「干净」
        if (stats_.truncated) {
            DrcViolation v;
            v.id = nextViolationId_++;
            v.ruleName = "Hierarchy expansion truncated";
            v.ruleId = kTruncationRuleId;
            v.message = "Expanded shape count hit cap " + std::to_string(config.maxCheckedShapes) +
                        ", " + std::to_string(stats_.skippedOverCap) +
                        " shape(s) NOT checked: result is INCOMPLETE (pre-check only, never signoff)";
            v.x = 0;
            v.y = 0;
            v.value = stats_.checkedShapes;
            v.limit = config.maxCheckedShapes;
            v.layer = 0;
            v.datatype = 0;
            v.shapeId1 = -1;
            v.shapeId2 = -1;
            v.fromInstance = false;
            v.sourceCellId = -1;
            v.bbox = BBox(0, 0, 0, 0);
            violations_.push_back(v);
        }

        // 合并请求没能在所有层上落实 = 结果按混合口径测出，同样绝不静默
        if (stats_.mergeSkipped) {
            DrcViolation v;
            v.id = nextViolationId_++;
            v.ruleName = "Merged-region mode partially skipped";
            v.ruleId = kMergeSkippedRuleId;
            v.message = "Same-layer boolean merge did NOT apply to every layer (" +
                        stats_.mergeNote + "); those layers were measured per-shape, so "
                        "merge-only neck/width defects there are NOT covered";
            v.x = 0;
            v.y = 0;
            v.value = stats_.mergedRegionCount;
            v.limit = stats_.mergedInputContours;
            v.layer = 0;
            v.datatype = 0;
            v.shapeId1 = -1;
            v.shapeId2 = -1;
            v.fromInstance = false;
            v.sourceCellId = -1;
            v.bbox = BBox(0, 0, 0, 0);
            violations_.push_back(v);
        }

        for (int i = 0; i < totalRules; i++) {
            checkCancellation();
            const DrcRule* rule = activeRules[i];

            if (progress) {
                int pct = (i * 100) / totalRules;
                progress(pct, "Checking: " + rule->name);
            }

            try {
                switch (rule->type) {
                    case DrcRuleType::MIN_WIDTH:
                        checkMinWidth(*rule, config);
                        break;
                    case DrcRuleType::MAX_WIDTH:
                        checkMaxWidth(*rule, config);
                        break;
                    case DrcRuleType::MIN_SPACING:
                        checkMinSpacing(*rule, config);
                        break;
                    case DrcRuleType::MIN_AREA:
                        checkMinArea(*rule, config);
                        break;
                    case DrcRuleType::MAX_AREA:
                        checkMaxArea(*rule, config);
                        break;
                    case DrcRuleType::MIN_ENCLOSURE:
                        checkMinEnclosure(*rule, config);
                        break;
                    case DrcRuleType::MIN_OVERLAP:
                        checkMinOverlap(*rule, config);
                        break;
                    case DrcRuleType::MAX_DENSITY:
                    case DrcRuleType::MIN_DENSITY:
                        checkDensity(*rule, config);
                        break;
                    case DrcRuleType::MIN_NOTCH:
                        checkMinNotch(*rule, config);
                        break;
                    default:
                        executionSkipped(*rule, "Rule type is not implemented");
                        break;
                }
            } catch (const NativeJobCancelled&) {
                throw;
            } catch (const std::exception& error) {
                executionSkipped(*rule, std::string("Rule execution failed: ") + error.what());
            } catch (...) {
                executionSkipped(*rule, "Rule execution failed with an unknown exception");
            }
        }

        // Reserved row outside the display budget. Rule checks continue after the
        // budget fills, and a later error must never disappear as a clean result.
        if (stats_.droppedViolationRows > 0) {
            DrcViolation notice{};
            notice.id = nextViolationId_++;
            notice.ruleId = kOutputTruncatedRuleId;
            notice.ruleName = "Violation output truncated";
            notice.message = "Violation display budget " + std::to_string(outputRowCap_) +
                " reached; " + std::to_string(stats_.droppedViolationRows) + " of " +
                std::to_string(stats_.totalViolationRows) +
                " generated row(s) omitted: result is INCOMPLETE, never a clean pass";
            notice.value = static_cast<double>(stats_.totalViolationRows);
            notice.limit = outputRowCap_;
            notice.shapeId1 = -1;
            notice.shapeId2 = -1;
            notice.bbox = BBox(0, 0, 0, 0);
            violations_.push_back(notice);
        }

        if (progress) {
            progress(100, "DRC complete: " + std::to_string(violations_.size()) + " violations");
        }

        return violations_;
    }

    // ==================== Derived Layers ====================

    /**
     * Create a derived layer from boolean operation on two layers.
     * @param layout Source layout
     * @param layerA First layer key
     * @param layerB Second layer key
     * @param op Boolean operation
     * @return Resulting polygons
     */
    std::vector<std::vector<Vec2>> deriveLayer(const Layout& layout,
                                               const LayerKey& layerA,
                                               const LayerKey& layerB,
                                               ClipType op) {
        // Collect polygons from each layer（RECT 归一化为 4 角；不含实例展开）
        auto getLayerPolygons = [&](const LayerKey& key) -> std::vector<std::vector<Vec2>> {
            std::vector<std::vector<Vec2>> polys;
            for (const auto& shape : layout.shapes) {
                checkCancellation();
                if (shape.layerKey == key &&
                    (shape.type == ShapeType::RECT || shape.type == ShapeType::POLYGON || shape.type == ShapeType::BOX)) {
                    std::vector<Vec2> poly = effectivePolygon(shape);
                    if (poly.size() >= 3) {
                        polys.push_back(std::move(poly));
                    }
                }
            }
            return polys;
        };

        auto polysA = getLayerPolygons(layerA);
        auto polysB = getLayerPolygons(layerB);

        // Perform boolean operations pairwise
        std::vector<std::vector<Vec2>> result;

        for (const auto& polyA : polysA) {
            checkCancellation();
            for (const auto& polyB : polysB) {
                checkCancellation();
                auto boolResult = GeometryEngine::booleanOp(polyA, polyB, op);
                result.insert(result.end(), boolResult.polygons.begin(), boolResult.polygons.end());
            }
        }

        return result;
    }

private:
    std::function<void()> checkpoint_;
    void checkCancellation() const { if (checkpoint_) checkpoint_(); }
    /**
     * 参与检查的单个图形（已按实例矩阵变换到根 Cell 坐标系）。
     * 自包含几何 + 元数据，检查器不再回查 Layout::shapes，
     * 这样本地图形与展开图形走完全相同的测量代码。
     */
    struct CheckShape {
        int64_t shapeId = 0;      // 原始 SceneShape::id（展开时 = 子 Cell 图形 id）
        int layer = 0;
        int datatype = 0;
        ShapeType type = ShapeType::POLYGON;
        double pathWidth = 0;     // PATH 线宽（已按实例放大系数折算）
        int ownerCellId = -1;     // 图形真正归属的 Cell
        bool viaInstance = false; // true → 由 SREF/AREF 展开得到
        BBox box;                 // 变换后顶点重算的 bbox（不可变换原 bbox 角点）
        std::vector<Vec2> polygon;

        // ==================== merged-region 口径 ====================
        // merged = true → 本条目不是一个图形，而是**同层布尔并之后的一个区域**：
        // polygon 是外轮廓，holes 是该区域的所有孔轮廓（region-on-left：外 CCW/孔 CW）。
        // shapeId 置 -1（合成条目，画布上无对应图形，定位只能用 x/y/bbox）。
        bool merged = false;
        std::vector<std::vector<Vec2>> holes;
        std::vector<std::vector<Vec2>> connectedOuters;
        bool pointConnected = false;
    };

    /// 一个待检查条目的全部轮廓（逐图形口径 = 单条；合并区域 = 外轮廓 + 孔）
    static std::vector<std::vector<Vec2>> contoursOf(const CheckShape& s) {
        std::vector<std::vector<Vec2>> c;
        c.push_back(s.polygon);
        for (const auto& p : s.connectedOuters) c.push_back(p);
        for (const auto& h : s.holes) c.push_back(h);
        return c;
    }

    // Per-layer spatial indices for fast neighbor queries
    struct LayerIndex {
        RTree<int> index;
        std::vector<CheckShape> shapes;
    };
    std::unordered_map<int, LayerIndex> layerIndices_;  // Key: layer number

    DrcRuleset ruleset_;
    std::vector<DrcViolation> violations_;
    int outputRowCap_ = 10000;
    int outputRows_ = 0;
    int64_t nextViolationId_ = 1;
    DrcRunStats stats_;

    /**
     * 图形 → 用于几何测量的有效多边形：统一走 scene_graph.h 的 hongtu::effectivePolygon
     * （RECT/BOX 展 4 角、PATH 按 pathWidth+pathType 轮廓化），与图像导出同一口径。
     * 空返回表示无法测量（跳过该图形）。
     */
    static std::vector<Vec2> effectivePolygon(const SceneShape& shape) {
        return hongtu::effectivePolygon(shape);
    }

    /// 变换后顶点集 → bbox（旋转/镜像后必须重算，不能变换原 bbox 角点）
    static BBox bboxOf(const std::vector<Vec2>& pts) {
        BBox box;
        for (const auto& p : pts) {
            box.minX = std::min(box.minX, p.x);
            box.minY = std::min(box.minY, p.y);
            box.maxX = std::max(box.maxX, p.x);
            box.maxY = std::max(box.maxY, p.y);
        }
        return box;
    }

    static bool isIdentityTransform(const GeometryEngine::Transform2D& m) {
        return m.a == 1.0 && m.b == 0.0 && m.c == 0.0 && m.d == 1.0 &&
               m.tx == 0.0 && m.ty == 0.0;
    }

    void buildLayerIndices(const Layout& layout, const DrcConfig& config) {
        layerIndices_.clear();
        stats_ = DrcRunStats();
        stats_.requestedDepth = config.hierarchyDepth;

        const int cap = config.maxCheckedShapes > 0 ? config.maxCheckedShapes : 1;
        std::unordered_map<int, std::vector<CheckShape>> layerShapes;

        // 深度归一：<0 视为 0（本引擎不提供无限制展开）
        const int depth = config.hierarchyDepth > 0 ? config.hierarchyDepth : 0;
        int root = config.rootCellId >= 0 ? config.rootCellId : config.ownerCellFilter;
        if (root < 0) root = layout.topCellId();
        // Layout::findCell 只有非 const 重载，这里按 const cells[] 自查（不改 scene_graph.h）
        bool rootExists = false;
        for (const auto& c : layout.cells) {
            checkCancellation();
            if (c.id == root) { rootExists = true; break; }
        }
        const bool canExpand = depth > 0 && root >= 0 && rootExists;

        // 收集一个图形：m 为其到根 Cell 坐标系的累计矩阵（flattenHierarchy 已合成完毕）
        auto accept = [&](const SceneShape& shape, const GeometryEngine::Transform2D& m,
                          bool fromExpansion) {
            checkCancellation();
            if (shape.type == ShapeType::INSTANCE || shape.type == ShapeType::TEXT ||
                shape.type == ShapeType::NODE) return;
            // ownerCellFilter 仅约束本地-only 口径（展开时子 Cell 图形的 ownerCellId
            // 本就不等于根 Cell，过滤会误删刚展开出来的几何）
            if (!fromExpansion && config.ownerCellFilter >= 0 &&
                shape.ownerCellId != config.ownerCellFilter) {
                return;
            }
            if (stats_.checkedShapes >= cap) {
                stats_.skippedOverCap++;
                stats_.truncated = true;
                return;
            }

            std::vector<Vec2> local = effectivePolygon(shape);
            if (local.size() < 3) return;

            const bool transformed = !isIdentityTransform(m);
            std::vector<Vec2> world = transformed ? hongtu::effectivePolygonTransformed(shape, m) : local;
            BBox box = bboxOf(world);
            if (!box.valid()) return;
            if (config.hasScopeBox && !box.intersects(config.scopeBox)) return;

            CheckShape cs;
            cs.shapeId = shape.id;
            cs.layer = shape.layerKey.layer;
            cs.datatype = shape.layerKey.datatype;
            cs.type = shape.type;
            cs.pathWidth = shape.pathWidth;
            cs.ownerCellId = shape.ownerCellId;
            // 归属判定用 ownerCellId 而非矩阵：实例可以放在 (0,0) 不旋不镜，
            // 此时矩阵是恒等，但图形依然来自被引用的子 Cell。
            cs.viaInstance = fromExpansion && shape.ownerCellId != root;
            if (transformed && !shape.pathWidthAbsolute) {
                // GDS 实例矩阵只能是等比放大 + 镜像 + 正交旋转 → sqrt(|det|) 即放大系数，
                // PATH 线宽随其缩放（多边形顶点已变换，此处只补 pathWidth 这一标量元数据）
                const double det = std::fabs(m.determinant());
                cs.pathWidth *= det > 0 ? std::sqrt(det) : 1.0;
            }
            if (cs.viaInstance) stats_.instanceShapes++;
            cs.box = box;
            cs.polygon = std::move(world);

            layerShapes[cs.layer].push_back(std::move(cs));
            stats_.checkedShapes++;
        };

        if (canExpand) {
            // flattenHierarchy 的 UI 深度：1 = 仅本地，n = 本地 + (n-1) 层实例
            layout.flattenHierarchy(root, depth + 1,
                                    [&](const SceneShape& s,
                                        const GeometryEngine::Transform2D& m) {
                                        accept(s, m, true);
                                    }, config.hasScopeBox ? &config.scopeBox : nullptr, nullptr, config.checkpoint);
            stats_.hierarchyApplied = true;
            stats_.effectiveDepth = depth;
            stats_.rootCellId = root;
        } else {
            // 旧口径：逐 Cell 本地几何（ownerCellFilter == -1 时覆盖全部 Cell）
            for (const auto& shape : layout.shapes) {
                checkCancellation();
                accept(shape, GeometryEngine::Transform2D::identity(), false);
            }
            stats_.effectiveDepth = 0;
            stats_.rootCellId = canExpand ? root : -1;
        }

        // 同层布尔合并（merged-region 口径）：把逐图形条目替换为合并后的区域条目。
        // 默认关闭（config.mergeSameLayer = false）→ 下面的 R-Tree 与全部检查器行为
        // 与旧的逐图形口径完全一致。
        if (config.mergeSameLayer) mergeSameLayerShapes(layerShapes, config);

        // Build R-Tree per layer
        for (auto& entry : layerShapes) {
            checkCancellation();
            LayerIndex& li = layerIndices_[entry.first];
            li.shapes = std::move(entry.second);
            std::vector<std::pair<int, BBox>> items;
            items.reserve(li.shapes.size());
            for (int i = 0; i < (int)li.shapes.size(); i++) {
                checkCancellation();
                items.push_back({i, li.shapes[i].box});
            }
            li.index.bulkLoad(items);
        }
    }

    // ==================== merged-region 合并 ====================

    static std::vector<Vec2> toVec2Path(const clipper::Path& c) {
        std::vector<Vec2> v;
        v.reserve(c.size());
        for (const clipper::IntPoint& p : c) v.push_back({(double)p.x, (double)p.y});
        return v;
    }

    /**
     * 把每层（按 datatype 分桶，规则是按 layer+datatype 过滤的，跨 datatype 合并会
     * 造出不存在的区域）的同层图形做一次真实布尔并，再用合并后的区域替换条目。
     *
     * 这一步是「只有合并后才显现」的缺陷能被测到的唯一原因：
     *   三根条 A=[0,100]x[0,20]、B=[40,60]x[20,120]、C=[0,100]x[120,140]（同层同 datatype）
     *   逐图形口径：每根条自身宽度 20 → 任何 min-width>20 的规则都只报 A/C，
     *   而合并后的工字形区域的**细腰 = 20**（B 的宽度）同时也是唯一通路；
     *   更关键的是间距：A 与 C 的逐图形边到边距离是 100（隔着 B 的两条边），
     *   合并后区域与自身孔腔（B 左右两侧形成的两个凹口）之间的间距 = 40。
     * 合并区域的宽度改用 GeometryEngine::measureRegionMinWidth（面对面边对 +
     * 内法线射线），凸包口径的 measureMinWidth 会把 neck 直接填平。
     *
     * 合并失败/超上限时**不静默**：该桶原样保留（仍是逐图形口径），
     * stats().mergeSkipped = true 并记 mergeNote，run() 另外插入 DRC.MERGE 告警项。
     */
    void mergeSameLayerShapes(std::unordered_map<int, std::vector<CheckShape>>& layerShapes,
                              const DrcConfig& config) {
        const int cap = config.maxMergeContoursPerLayer > 0 ? config.maxMergeContoursPerLayer : 1;
        for (auto& entry : layerShapes) {
            checkCancellation();
            std::vector<CheckShape>& shapes = entry.second;
            if (shapes.empty()) continue;

            std::vector<int> datatypes;
            for (const CheckShape& s : shapes) {
                checkCancellation();
                if (std::find(datatypes.begin(), datatypes.end(), s.datatype) == datatypes.end())
                    datatypes.push_back(s.datatype);
            }

            std::vector<CheckShape> rebuilt;
            bool anyMerged = false;
            for (int dt : datatypes) {
                checkCancellation();
                std::vector<const CheckShape*> src;
                clipper::Paths rings;
                for (const CheckShape& s : shapes) {
                    checkCancellation();
                    if (s.datatype != dt) continue;
                    src.push_back(&s);
                    clipper::Path r;
                    r.reserve(s.polygon.size());
                    for (const Vec2& p : s.polygon) r.push_back({std::llround(p.x), std::llround(p.y)});
                    rings.push_back(std::move(r));
                }
                const bool tooBig = (int)rings.size() > cap ||
                                    (clipper::GeneralClipper::kMaxEdges &&
                                     (int)clipperTotalEdges(rings) > clipper::GeneralClipper::kMaxEdges);
                if (tooBig) {
                    stats_.mergeSkipped = true;
                    stats_.mergeNote += "over-cap L" + std::to_string(entry.first) +
                                        "/" + std::to_string(dt) + " ";
                    for (const CheckShape* s : src) rebuilt.push_back(*s);
                    continue;
                }
                const clipper::GeneralClipper::Output m = clipper::GeneralClipper::unite(rings);
                stats_.mergedInputContours += (int)rings.size();
                if (m.approximated || m.contours.empty()) {
                    stats_.mergeSkipped = true;
                    stats_.mergeNote += (m.approximated ? "approximated L" : "empty L") +
                                        std::to_string(entry.first) + "/" + std::to_string(dt) + " ";
                    for (const CheckShape* s : src) rebuilt.push_back(*s);
                    continue;
                }
                appendMergedRegions(rebuilt, m.contours, entry.first, dt, src.front());
                anyMerged = true;
            }
            if (anyMerged) {
                shapes = std::move(rebuilt);
                stats_.mergedRegions = true;
            }
        }
    }

    static size_t clipperTotalEdges(const clipper::Paths& p) {
        size_t n = 0;
        for (const clipper::Path& r : p) n += r.size();
        return n;
    }

    /// 把布尔并的结果轮廓集切分成「区域 = 外轮廓 + 它的孔」并落成 CheckShape
    void appendMergedRegions(std::vector<CheckShape>& out, const clipper::Paths& contours,
                             int layer, int datatype, const CheckShape* proto) {
        std::vector<CheckShape> regions;
        for (const clipper::Path& c : contours) {
            checkCancellation();
            if (clipper::GeneralClipper::ringArea2(c) <= 0) continue;   // 孔稍后归位
            CheckShape cs;
            cs.shapeId = -1;                       // 合成条目，无对应原始图形
            cs.layer = layer;
            cs.datatype = datatype;
            cs.type = ShapeType::POLYGON;
            cs.ownerCellId = proto ? proto->ownerCellId : -1;
            cs.viaInstance = proto ? proto->viaInstance : false;
            cs.merged = true;
            cs.polygon = toVec2Path(c);
            regions.push_back(std::move(cs));
        }
        for (const clipper::Path& c : contours) {
            checkCancellation();
            if (clipper::GeneralClipper::ringArea2(c) > 0) continue;
            std::vector<Vec2> hole = toVec2Path(c);
            if (hole.empty()) continue;
            int best = -1;
            double bestArea = 1e308;
            for (size_t i = 0; i < regions.size(); ++i) {
                checkCancellation();
                if (GeometryEngine::pointInPolygon(hole[0], regions[i].polygon) < 0) continue;
                const double a = std::fabs(GeometryEngine::polygonArea(regions[i].polygon));
                if (a < bestArea) { bestArea = a; best = (int)i; }
            }
            if (best >= 0) regions[best].holes.push_back(std::move(hole));
            else {
                // 孤立孔（理论上不该出现）：翻成正向轮廓单独成区，绝不丢弃几何
                std::reverse(hole.begin(), hole.end());
                CheckShape cs;
                cs.shapeId = -1;
                cs.layer = layer;
                cs.datatype = datatype;
                cs.type = ShapeType::POLYGON;
                cs.ownerCellId = proto ? proto->ownerCellId : -1;
                cs.merged = true;
                cs.polygon = std::move(hole);
                regions.push_back(std::move(cs));
            }
        }
        // Clipper2 emits separate positive contours at point contacts. KLayout's
        // default merged regions consider these one connected area, with zero
        // width/space at the contact. Group via shared vertices in O(V log V).
        std::vector<size_t> parent(regions.size());
        for(size_t i=0;i<parent.size();++i) parent[i]=i;
        auto root = [&parent](size_t i) { while(parent[i]!=i){parent[i]=parent[parent[i]];i=parent[i];}return i; };
        std::map<std::pair<double,double>,size_t> owners;
        for(size_t i=0;i<regions.size();++i) for(const auto& p:regions[i].polygon) {
            const auto key=std::make_pair(p.x,p.y);
            const auto old=owners.find(key);
            if(old==owners.end()) owners[key]=i;
            else {
                if(old->second==i) regions[i].pointConnected=true;
                const size_t a=root(i), b=root(old->second);if(a!=b)parent[a]=b;
            }
        }
        std::vector<CheckShape> coherent;
        std::map<size_t,size_t> groups;
        for(size_t i=0;i<regions.size();++i){
            const size_t owner=root(i);
            auto it=groups.find(owner);
            if(it==groups.end()){groups[owner]=coherent.size();coherent.push_back(std::move(regions[i]));}
            else {
                auto& target=coherent[it->second];
                target.connectedOuters.push_back(std::move(regions[i].polygon));
                for(auto& h:regions[i].holes)target.holes.push_back(std::move(h));
                target.pointConnected=true;
            }
        }
        regions=std::move(coherent);
        for (CheckShape& r : regions) {
            checkCancellation();
            BBox b = bboxOf(r.polygon);
            for (const auto& p : r.connectedOuters) b = b.unite(bboxOf(p));
            for (const auto& h : r.holes) b = b.unite(bboxOf(h));
            r.box = b;
        }
        stats_.mergedRegionCount += (int)regions.size();
        out.insert(out.end(), std::make_move_iterator(regions.begin()),
                   std::make_move_iterator(regions.end()));
    }

    void addViolation(const DrcRule& rule, const std::string& message,
                     double x, double y, double measuredValue,
                     int64_t shapeId1, int64_t shapeId2 = -1,
                     const CheckShape* src = nullptr, const CheckShape* src2 = nullptr) {
        ++stats_.totalViolationRows;
        if (outputRows_ >= outputRowCap_) {
            ++stats_.droppedViolationRows;
            return;
        }
        ++outputRows_;

        DrcViolation v;
        v.id = nextViolationId_++;
        v.ruleName = rule.name;
        v.ruleId = rule.id;
        v.message = message;
        v.x = x;
        v.y = y;
        v.value = measuredValue;
        v.limit = rule.value;
        v.layer = rule.layer1;
        v.datatype = rule.datatype1;
        v.shapeId1 = shapeId1;
        v.shapeId2 = shapeId2;
        if (src != nullptr) {
            v.layer = src->layer;
            v.datatype = src->datatype;
            v.fromInstance = src->viaInstance || (src2 != nullptr && src2->viaInstance);
            v.sourceCellId = src->ownerCellId;
        }
        if (v.fromInstance) {
            // 明确标注该违例位于实例展开后的几何上：shapeId 属于子 Cell，
            // 在当前 Cell 的图形列表里按 id 查不到，定位必须用 x/y/bbox
            v.message += " [via instance]";
        }
        if ((src != nullptr && src->merged) || (src2 != nullptr && src2->merged)) {
            // 合并区域口径的违例：shapeId1/2 为合成值 -1，且测量对象是同层布尔并之后
            // 的区域（含孔），不是任何单个图形 —— UI 必须把这两种口径区分开显示。
            v.message += " [merged region]";
        }
        v.bbox = BBox(x - 50, y - 50, x + 50, y + 50);

        violations_.push_back(v);
    }

    // ==================== Rule Checkers ====================
    void executionSkipped(const DrcRule& rule, const std::string& reason) {
        DrcViolation notice{};
        notice.id = nextViolationId_++;
        notice.ruleId = kExecutionSkippedRuleId;
        notice.ruleName = "Rule execution incomplete";
        notice.message = "Rule " + rule.id + ": " + reason + "; result is INCOMPLETE";
        notice.layer = rule.layer1;
        notice.datatype = rule.datatype1;
        notice.shapeId1 = -1;
        notice.shapeId2 = -1;
        notice.bbox = BBox(0, 0, 0, 0);
        // Execution failures are never consumed by the violation display budget.
        violations_.push_back(notice);
    }

    void measurementSkipped(const DrcRule& rule, const CheckShape& shape) {
        DrcRule notice = rule;
        notice.id = kMeasurementSkippedRuleId;
        notice.name = "Region measurement incomplete";
        const auto p = GeometryEngine::polygonCentroid(shape.polygon);
        addViolation(notice, "Rule " + rule.id + " exceeded region edge measurement cap " +
                     std::to_string(GeometryEngine::kRegionWidthVertexCap) +
                     "; this region was NOT checked for this rule", p.x, p.y, 0, -1, -1, &shape);
    }

    /** 图形有效宽度：PATH 直接取（已折算放大系数的）pathWidth；合并区域走
     *  measureRegionMinWidth（凸包口径会把 neck 填平，绝不可用于区域）；其余用
     *  多边形内接最小宽度。 */
    static double shapeWidth(const CheckShape& shape, bool* approx = nullptr) {
        if (shape.type == ShapeType::PATH && shape.pathWidth > 0) {
            return shape.pathWidth;
        }
        if (shape.merged) {
            if (shape.pointConnected) return 0;
            return GeometryEngine::measureRegionMinWidth(contoursOf(shape), approx);
        }
        return GeometryEngine::measureMinWidth(shape.polygon);
    }

    /// 图形/区域有效面积：合并区域必须把孔从外轮廓里扣掉（polygonArea 只看单条轮廓）
    static double shapeArea(const CheckShape& shape) {
        if (shape.merged) {
            return GeometryEngine::regionArea(contoursOf(shape));
        }
        return GeometryEngine::polygonArea(shape.polygon);
    }

    void checkMinWidth(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;

        for (const auto& shape : li.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;

            bool capped = false;
            double width = shapeWidth(shape, &capped);
            if (capped) { measurementSkipped(rule, shape); continue; }
            if (width < rule.value) {
                Vec2 centroid = GeometryEngine::polygonCentroid(shape.polygon);
                addViolation(rule,
                    "Width " + std::to_string((int)width) + "nm < " + std::to_string((int)rule.value) + "nm",
                    centroid.x, centroid.y, width, shape.shapeId, -1, &shape);
            }
        }
    }

    void checkMaxWidth(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;

        for (const auto& shape : li.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;

            bool capped = false;
            double width = shapeWidth(shape, &capped);
            if (capped) { measurementSkipped(rule, shape); continue; }
            if (width > rule.value) {
                Vec2 centroid = GeometryEngine::polygonCentroid(shape.polygon);
                addViolation(rule,
                    "Width " + std::to_string((int)width) + "nm > " + std::to_string((int)rule.value) + "nm",
                    centroid.x, centroid.y, width, shape.shapeId, -1, &shape);
            }
        }
    }

    void checkMinSpacing(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;
        int n = (int)li.shapes.size();

        // Use spatial index for neighbor queries instead of O(n²)
        for (int i = 0; i < n; i++) {
            checkCancellation();
            const CheckShape& shapeA = li.shapes[i];
            if (!rule.matchesDatatype1(shapeA.datatype)) continue;

            if (shapeA.merged) {
                bool capped = false;
                const double gap = shapeA.pointConnected ? 0 :
                    GeometryEngine::measureRegionMinSpacing(contoursOf(shapeA), &capped);
                if (capped) measurementSkipped(rule, shapeA);
                else if (gap < rule.value) {
                    const Vec2 p = GeometryEngine::polygonCentroid(shapeA.polygon);
                    addViolation(rule, "Internal spacing " + std::to_string(gap) + "nm < " +
                                 std::to_string(rule.value) + "nm", p.x, p.y, gap,
                                 shapeA.shapeId, -1, &shapeA);
                }
            }

            BBox expandedBBox = shapeA.box.expand(rule.value);

            // Query neighbors within rule.value distance
            auto neighbors = li.index.queryRange(expandedBBox);

            for (int neighborLocalIdx : neighbors) {
                checkCancellation();
                if (neighborLocalIdx <= i) continue;  // Avoid duplicates

                const CheckShape& shapeB = li.shapes[neighborLocalIdx];
                if (!rule.matchesDatatype1(shapeB.datatype)) continue;

                // True edge-to-edge distance；合并区域必须按「区域 vs 区域」的全部轮廓
                // 计距（含孔），否则岛/湖关系会按外轮廓算出一个偏大的假间距
                double dist = (shapeA.merged || shapeB.merged)
                    ? GeometryEngine::regionToRegionDistance(contoursOf(shapeA), contoursOf(shapeB))
                    : GeometryEngine::polygonToPolygonDistance(shapeA.polygon, shapeB.polygon);

                if (dist < rule.value && dist > 0) {
                    // Find closest point for violation location
                    Vec2 cA = GeometryEngine::polygonCentroid(shapeA.polygon);
                    Vec2 cB = GeometryEngine::polygonCentroid(shapeB.polygon);
                    double midX = (cA.x + cB.x) * 0.5;
                    double midY = (cA.y + cB.y) * 0.5;

                    addViolation(rule,
                        "Spacing " + std::to_string((int)dist) + "nm < " + std::to_string((int)rule.value) + "nm",
                        midX, midY, dist, shapeA.shapeId, shapeB.shapeId, &shapeA, &shapeB);
                }
            }
        }
    }

    void checkMinArea(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;

        for (const auto& shape : li.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;

            double area = shapeArea(shape);
            if (area < rule.value) {
                Vec2 centroid = GeometryEngine::polygonCentroid(shape.polygon);
                addViolation(rule,
                    "Area " + std::to_string((int)area) + "nm² < " + std::to_string((int)rule.value) + "nm²",
                    centroid.x, centroid.y, area, shape.shapeId, -1, &shape);
            }
        }
    }

    void checkMaxArea(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;

        for (const auto& shape : li.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;

            double area = shapeArea(shape);
            if (area > rule.value) {
                Vec2 centroid = GeometryEngine::polygonCentroid(shape.polygon);
                addViolation(rule,
                    "Area " + std::to_string((int)area) + "nm² > " + std::to_string((int)rule.value) + "nm²",
                    centroid.x, centroid.y, area, shape.shapeId, -1, &shape);
            }
        }
    }

    void checkMinEnclosure(const DrcRule& rule, const DrcConfig& config) {
        // Enclosure: layer2 shapes must be enclosed by layer1 shapes with minimum margin
        auto it1 = layerIndices_.find(rule.layer1);
        auto it2 = layerIndices_.find(rule.layer2);
        if (it2 == layerIndices_.end()) return;

        const LayerIndex emptyLayer;
        const LayerIndex& enclosingLayer = it1 == layerIndices_.end() ? emptyLayer : it1->second;
        const LayerIndex& enclosedLayer = it2->second;

        for (const auto& enclosed : enclosedLayer.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype2(enclosed.datatype)) continue;
            const std::vector<Vec2>& enclosedPoly = enclosed.polygon;

            // Find enclosing shapes nearby
            BBox searchBox = enclosed.box.expand(rule.value * 2);
            auto candidates = enclosingLayer.index.queryRange(searchBox);

            bool properlyEnclosed = false;
            double minMargin = 0;

            for (int candLocalIdx : candidates) {
                checkCancellation();
                if (!rule.matchesDatatype1(enclosingLayer.shapes[candLocalIdx].datatype)) continue;
                const std::vector<Vec2>& enclosingPoly = enclosingLayer.shapes[candLocalIdx].polygon;

                // Check if enclosed is inside enclosing
                if (!enclosedPoly.empty() &&
                    GeometryEngine::pointInPolygon(enclosedPoly[0], enclosingPoly) > 0) {
                    // 逐顶点验证包含并测量到外边界的最小距离
                    bool allInside = true;
                    double minDist = 1e18;
                    for (const auto& pt : enclosedPoly) {
                        checkCancellation();
                        int pip = GeometryEngine::pointInPolygon(pt, enclosingPoly);
                        if (pip < 0) { allInside = false; break; }
                        double d = GeometryEngine::pointToPolygonDistance(pt, enclosingPoly);
                        minDist = std::min(minDist, d);
                    }

                    if (allInside) {
                        properlyEnclosed = true;
                        minMargin = std::max(minMargin, minDist);
                    }
                }
            }

            if (!properlyEnclosed || minMargin < rule.value) {
                Vec2 centroid = GeometryEngine::polygonCentroid(enclosedPoly);
                double measured = properlyEnclosed ? minMargin : 0;
                addViolation(rule,
                    "Enclosure margin " + std::to_string((int)measured) + "nm < " + std::to_string((int)rule.value) + "nm",
                    centroid.x, centroid.y, measured, enclosed.shapeId, -1, &enclosed);
            }
        }
    }

    void checkMinOverlap(const DrcRule& rule, const DrcConfig& config) {
        // Similar to enclosure but checks overlap area
        auto it1 = layerIndices_.find(rule.layer1);
        auto it2 = layerIndices_.find(rule.layer2);
        if (it1 == layerIndices_.end() || it2 == layerIndices_.end()) return;

        // Check that layer2 shapes overlap layer1 shapes by at least rule.value
        const LayerIndex& layer1Idx = it1->second;
        const LayerIndex& layer2Idx = it2->second;

        for (const auto& shape2 : layer2Idx.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype2(shape2.datatype)) continue;
            const std::vector<Vec2>& poly2 = shape2.polygon;
            BBox searchBox = shape2.box.expand(rule.value);
            auto candidates = layer1Idx.index.queryRange(searchBox);

            bool hasOverlap = false;
            for (int candIdx : candidates) {
                checkCancellation();
                if (!rule.matchesDatatype1(layer1Idx.shapes[candIdx].datatype)) continue;
                if (GeometryEngine::polygonsIntersect(layer1Idx.shapes[candIdx].polygon, poly2)) {
                    hasOverlap = true;
                    break;
                }
            }

            if (!hasOverlap) {
                Vec2 centroid = GeometryEngine::polygonCentroid(poly2);
                addViolation(rule, "No overlap with layer " + std::to_string(rule.layer1),
                           centroid.x, centroid.y, 0, shape2.shapeId, -1, &shape2);
            }
        }
    }

    void checkDensity(const DrcRule& rule, const DrcConfig& config) {
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        double windowSize = rule.value2 > 0 ? rule.value2 : rule.value * 20;
        bool isMax = (rule.type == DrcRuleType::MAX_DENSITY);
        if (!std::isfinite(windowSize) || windowSize <= 0 ||
            !std::isfinite(windowSize * windowSize)) {
            executionSkipped(rule, "Density window size is invalid");
            return;
        }

        // Normalize each source region, then union its material. Density measures
        // area occupied once; repeated/contained shapes cannot increase coverage.
        BBox designBBox;
        clipper::Paths material;
        size_t materialEdges = 0;
        for (const auto& shape : it->second.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;
            designBBox = designBBox.unite(shape.box);
            clipper::Paths region;
            for (const auto& contour : contoursOf(shape)) {
                clipper::Path ring;
                for (const Vec2& p : contour) {
                    checkCancellation();
                    if (!std::isfinite(p.x) || !std::isfinite(p.y) ||
                        std::abs(p.x) > clipper::GeneralClipper::kCoordLimit ||
                        std::abs(p.y) > clipper::GeneralClipper::kCoordLimit) {
                        executionSkipped(rule, "Density geometry exceeds coordinate limits");
                        return;
                    }
                    ring.push_back({std::llround(p.x), std::llround(p.y)});
                }
                region.push_back(std::move(ring));
            }
            const auto normalized = shape.merged
                ? clipper::GeneralClipper::executeNZ(region, {}, clipper::ClipType::UNION)
                : clipper::GeneralClipper::unite(region);
            if (normalized.approximated || normalized.droppedRings > 0) {
                executionSkipped(rule, "Density source normalization failed: " + normalized.note);
                return;
            }
            materialEdges += clipperTotalEdges(normalized.contours);
            material.insert(material.end(), normalized.contours.begin(), normalized.contours.end());
            if (materialEdges > static_cast<size_t>(clipper::GeneralClipper::kMaxEdges)) {
                executionSkipped(rule, "Density material exceeds edge budget");
                return;
            }
        }
        if (!designBBox.valid()) return;
        const auto united = clipper::GeneralClipper::executeNZ(material, {}, clipper::ClipType::UNION);
        if (united.approximated || united.droppedRings > 0) {
            executionSkipped(rule, "Density union failed: " + united.note);
            return;
        }
        RTree<int> densityIndex;
        std::vector<std::pair<int, BBox>> densityItems;
        for (size_t i = 0; i < united.contours.size(); ++i) {
            checkCancellation();
            BBox box;
            for (const auto& p : united.contours[i]) box = box.unite(BBox(p.x, p.y, p.x, p.y));
            densityItems.push_back({static_cast<int>(i), box});
        }
        densityIndex.bulkLoad(densityItems);

        // Scan windows
        for (double wy = designBBox.minY; wy < designBBox.maxY; wy += windowSize) {
            checkCancellation();
            for (double wx = designBBox.minX; wx < designBBox.maxX; wx += windowSize) {
                checkCancellation();
                if (std::abs(wx) + windowSize > clipper::GeneralClipper::kCoordLimit ||
                    std::abs(wy) + windowSize > clipper::GeneralClipper::kCoordLimit) {
                    executionSkipped(rule, "Density window exceeds coordinate limits");
                    return;
                }
                clipper::Path window{{std::llround(wx), std::llround(wy)},
                    {std::llround(wx + windowSize), std::llround(wy)},
                    {std::llround(wx + windowSize), std::llround(wy + windowSize)},
                    {std::llround(wx), std::llround(wy + windowSize)}};
                clipper::Paths nearby;
                for (int contourId : densityIndex.queryRange(BBox(wx, wy, wx + windowSize, wy + windowSize))) {
                    checkCancellation();
                    nearby.push_back(united.contours[contourId]);
                }
                const auto clipped = clipper::GeneralClipper::executeNZ(nearby, {window}, clipper::ClipType::INTERSECTION);
                if (clipped.approximated || clipped.droppedRings > 0) {
                    executionSkipped(rule, "Density window clipping failed: " + clipped.note);
                    return;
                }
                std::vector<std::vector<Vec2>> contours;
                for (const auto& ring : clipped.contours) {
                    checkCancellation();
                    std::vector<Vec2> points;
                    for (const auto& p : ring) points.push_back({static_cast<double>(p.x), static_cast<double>(p.y)});
                    contours.push_back(std::move(points));
                }
                const double filledArea = GeometryEngine::regionArea(contours);

                double windowArea = windowSize * windowSize;
                double density = (windowArea > 0) ? filledArea / windowArea : 0;

                if (isMax && density > rule.value / 100.0) {
                    addViolation(rule,
                        "Density " + std::to_string((int)(density * 100)) + "% > " + std::to_string((int)rule.value) + "%",
                        wx + windowSize / 2, wy + windowSize / 2, density * 100, -1);
                } else if (!isMax && density < rule.value / 100.0) {
                    addViolation(rule,
                        "Density " + std::to_string((int)(density * 100)) + "% < " + std::to_string((int)rule.value) + "%",
                        wx + windowSize / 2, wy + windowSize / 2, density * 100, -1);
                }
            }
        }
    }

    void checkMinNotch(const DrcRule& rule, const DrcConfig& config) {
        // Notch check: concave vertices with narrow opening
        auto it = layerIndices_.find(rule.layer1);
        if (it == layerIndices_.end()) return;

        const LayerIndex& li = it->second;
        for (const auto& shape : li.shapes) {
            checkCancellation();
            if (!rule.matchesDatatype1(shape.datatype)) continue;
            const std::vector<Vec2>& poly = shape.polygon;
            if (poly.size() < 4) continue;

            int n = (int)poly.size();
            for (int i = 0; i < n; i++) {
                checkCancellation();
                int prev = (i + n - 1) % n;
                int next = (i + 1) % n;

                // Check if vertex is concave (reflex angle)
                Vec2 e1 = poly[i] - poly[prev];
                Vec2 e2 = poly[next] - poly[i];
                double cross = e1.cross(e2);

                if (cross < 0) {  // Concave vertex
                    // Measure notch width: distance from this vertex to nearest non-adjacent edge
                    double minDist = 1e18;
                    for (int j = 0; j < n; j++) {
                        checkCancellation();
                        if (j == i || j == prev || j == next || j == (next + 1) % n) continue;
                        int j2 = (j + 1) % n;
                        double d = GeometryEngine::pointToSegmentDistance(
                            poly[i], poly[j], poly[j2]);
                        minDist = std::min(minDist, d);
                    }

                    if (minDist < rule.value) {
                        addViolation(rule,
                            "Notch " + std::to_string((int)minDist) + "nm < " + std::to_string((int)rule.value) + "nm",
                            poly[i].x, poly[i].y, minDist, shape.shapeId, -1, &shape);
                    }
                }
            }
        }
    }
};

// ==================== Default Rulesets ====================

/** 内置演示规则集；层号来自 demo_layers，不代表导入文件的真实 PDK。 */
inline DrcRuleset create28nmRuleset() {
    DrcRuleset rs;
    rs.name = "28nm CMOS";
    rs.technology = "28nm";

    auto addRule = [&](const char* id, const char* name, DrcRuleType type,
                      int layer, double value, int layer2 = -1) {
        DrcRule r;
        r.id = id;
        r.name = name;
        r.type = type;
        r.layer1 = layer;
        r.datatype1 = 0;
        r.layer2 = layer2;
        r.value = value;
        r.enabled = true;
        rs.rules.push_back(r);
    };

    // Metal 1 (demo layer 1)
    addRule("M1.W", "M1 Min Width", DrcRuleType::MIN_WIDTH, demo_layers::kMetal1, 90);
    addRule("M1.S", "M1 Min Spacing", DrcRuleType::MIN_SPACING, demo_layers::kMetal1, 90);
    addRule("M1.A", "M1 Min Area", DrcRuleType::MIN_AREA, demo_layers::kMetal1, 202500);  // 450x450

    // Metal 2 (demo layer 2)
    addRule("M2.W", "M2 Min Width", DrcRuleType::MIN_WIDTH, demo_layers::kMetal2, 90);
    addRule("M2.S", "M2 Min Spacing", DrcRuleType::MIN_SPACING, demo_layers::kMetal2, 90);

    // Poly (demo layer 4)
    addRule("POLY.W", "Poly Min Width", DrcRuleType::MIN_WIDTH, demo_layers::kPoly, 100);
    addRule("POLY.S", "Poly Min Spacing", DrcRuleType::MIN_SPACING, demo_layers::kPoly, 160);

    // Active (demo layer 5)
    addRule("AA.W", "Active Min Width", DrcRuleType::MIN_WIDTH, demo_layers::kActive, 120);
    addRule("AA.S", "Active Min Spacing", DrcRuleType::MIN_SPACING, demo_layers::kActive, 140);

    // Via1 (demo layer 10) enclosure by M1
    addRule("V1.ENC", "Via1 Enclosure by M1", DrcRuleType::MIN_ENCLOSURE,
            demo_layers::kMetal1, 30, demo_layers::kVia1);

    // Density
    DrcRule densityRule;
    densityRule.id = "M1.DEN";
    densityRule.name = "M1 Density";
    densityRule.type = DrcRuleType::MAX_DENSITY;
    densityRule.layer1 = demo_layers::kMetal1;
    densityRule.value = 80;  // 80%
    densityRule.value2 = 50000;  // 50um window
    densityRule.enabled = true;
    rs.rules.push_back(densityRule);

    return rs;
}

} // namespace hongtu

#endif // HONGTU_DRC_ENGINE_H
