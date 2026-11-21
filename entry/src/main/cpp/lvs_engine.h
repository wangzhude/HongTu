/**
 * HongTu EDA - LVS 网表提取与比对引擎
 *
 * - 连通性提取：同层交叠（R-Tree 邻域）+ via/contact 跨层（R-Tree 加速）
 *   → BFS 连通分量成网；TEXT 标签命名网络
 * - 网表比对（layout vs. SPICE 参考）：开路/短路/计数
 * - SPICE/CDL 网表导出；MOSFET 器件粗提取（poly∩active）
 *
 * 几何口径：RECT/BOX 2 点对角线归一化 4 角、PATH 轮廓化（与 DRC 内核一致）。
 *
 * ⚠ 定位（诚实声明）：**连通性级 LVS 预检查**，非签核。器件提取为
 * 简化启发式（无阱/注入识别，S/D 未解析）；比对按网名（依赖版图标签）。
 * 经 NAPI extractNets/runLvs/exportSpiceNetlist 暴露；
 * host 冒烟 tools/lvs_smoke.cpp。
 *
 * 结果状态（LvsResult::status，供 UI 区分「未运行」与「不匹配」）：
 *   not-run / no-netlist / empty-schematic / invalid-schematic /
 *   unsupported-schematic / empty-layout / truncated / pass / mismatch
 * **空网表、零网络一律判为不通过**（空结果永不得记为 LVS PASS）。
 */
#ifndef HONGTU_LVS_ENGINE_H
#define HONGTU_LVS_ENGINE_H

#include "demo_layers.h"

#include "scene_graph.h"
#include "geometry_engine.h"
#include "spatial_index.h"
#include "triangulator.h"
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <queue>
#include <algorithm>
#include <sstream>
#include <stdexcept>

namespace hongtu {

// A net in the extracted netlist
struct Net {
    int64_t id;
    std::string name;
    /** 落在该网上的全部「不同」TEXT 标签名（按版图出现顺序）；>1 即潜在短路 */
    std::vector<std::string> labels;
    std::vector<int64_t> shapeIds;    // Shapes belonging to this net
    std::vector<int> layers;          // Layers this net spans
    BBox bbox;
    int pinCount;                     // Number of pins/terminals
    bool fromInstance = false;        // 成员含展开实例；定位使用根 Cell 坐标 bbox

    Net() : id(0), pinCount(0) {}

    /** 匿名网：未被任何 TEXT 标签命名（对应 KLayout 的 N$ 内部网络） */
    bool isAnonymous() const { return labels.empty(); }
};

// A device extracted from layout
struct ExtractedDevice {
    std::string type;       // "NMOS", "PMOS", "RES", "CAP", "DIODE"
    int64_t id;
    int64_t gateNet;        // Net connected to gate
    int64_t sourceNet;      // Net connected to source
    int64_t drainNet;       // Net connected to drain
    int64_t bulkNet;        // Net connected to bulk/body
    double width;           // Device width (nm)
    double length;          // Device length (nm)
    BBox bbox;

    ExtractedDevice()
        : id(0), gateNet(-1), sourceNet(-1), drainNet(-1), bulkNet(-1),
          width(0), length(0) {}
};

// Via/contact layer configuration
struct ViaLayerConfig {
    int viaLayer;           // Via/contact layer number
    int lowerLayer;         // Layer below
    int upperLayer;         // Layer above
    int viaDatatype = -1;
    int lowerDatatype = -1;
    int upperDatatype = -1;
};

// LVS configuration
struct LvsConfig {
    std::vector<ViaLayerConfig> viaLayers;
    std::vector<int> deviceLayers;    // Layers that form devices
    std::string schematicNetlist;     // Reference netlist (SPICE format)
    bool extractParasitics = false;   // Extract parasitic R/C
    /**
     * 连通合并容差（同层与 via 判定共用）：0 = 仅真实交叠/接触算连通（默认，
     * 严格贴合版图数据）；> 0 时额外把间隙 ≤ 容差的图形并入同一网络。
     */
    double mergeTolerance = 0.0;
    int ownerCellFilter = -1;         // 仅提取指定 Cell 的本地几何（-1 = 全部）

    /**
     * 层级展开深度：0 = 只取本地几何（旧口径，默认，保持既有行为）；
     * ≥1 = 把 SREF/AREF 实例内几何按 mag→mirror→rot→trans 变换到被检查 Cell 后
     * 一并提取（对齐 KLayout flattened netlist）。
     *
     * 不展开会给出**假结论**：标准单元经 SREF 放置时，其内部连通关系完全不可见，
     * 与参考网表比对会整片报开路；反之两图形仅在展开后相交时会漏报短路。
     */
    int hierarchyDepth = 0;
    /** 组合爆炸上限（实例深嵌套时展开图形数）；触顶置 truncated，绝不静默少提 */
    int maxWorkShapes = 200000;
};

// LVS result
struct LvsResult {
    bool matched = false;
    /** 是否真正执行了比对：false = 前置条件不满足（无布局/无网表），结果不可信 */
    bool ran = false;
    /** 机器可读状态：not-run / no-netlist / empty-schematic / empty-layout / pass / mismatch */
    std::string status = "not-run";
    /** 未运行原因（status 为 pass / mismatch 时为空） */
    std::string error;
    int layoutNetCount = 0;
    int schematicNetCount = 0;
    int matchedNets = 0;
    std::vector<std::string> shortNets;   // 一个物理网承载 ≥2 个参考网名（真实短路）
    std::vector<std::string> openNets;    // 参考网表有、版图无的网络（开路）
    std::vector<std::string> extraNets;   // 版图具名、参考网表无的网络（多余）
    std::vector<std::string> messages;
};

/**
 * LvsEngine: Layout connectivity extraction and verification.
 */
class LvsEngine {
public:
    LvsEngine() : nextNetId_(1) {}

    // ==================== Configuration ====================

    void setConfig(const LvsConfig& config) {
        config_ = config;
    }

    void addViaLayer(int viaLayer, int lowerLayer, int upperLayer,
                     int viaDatatype = -1, int lowerDatatype = -1, int upperDatatype = -1) {
        // 拒绝退化/非法配置：via 层不得与上下层同号（否则会把同层两座桥接成假连通）
        if (viaLayer < 0 || lowerLayer < 0 || upperLayer < 0) {
            return;
        }
        if (viaLayer == lowerLayer || viaLayer == upperLayer) {
            return;
        }
        config_.viaLayers.push_back({viaLayer, lowerLayer, upperLayer, viaDatatype, lowerDatatype, upperDatatype});
    }

    /** 整体替换连通表 */
    void setViaLayers(const std::vector<ViaLayerConfig>& viaLayers) {
        config_.viaLayers = viaLayers;
    }

    /**
     * 内置演示互连表（必须由调用方显式启用）。真实 GDS/OASIS 层号
     * 不作工艺推断；LvsEngine 构造后 viaLayers 为空，仅同层连通。
     * Via3=12 尚无上层金属定义，不能把 Poly=4 当 M4。
     */
    static std::vector<ViaLayerConfig> defaultInterconnectStack() {
        return {{demo_layers::kVia1, demo_layers::kMetal1, demo_layers::kMetal2},
                {demo_layers::kVia2, demo_layers::kMetal2, demo_layers::kMetal3}};
    }

    /** 仅提取指定 Cell 本地几何（与 UI「当前 Cell」语义对齐）；-1 = 全部 */
    void setOwnerCellFilter(int cellId) {
        config_.ownerCellFilter = cellId;
    }

    /** 设置层级展开深度（负数归一为 0 = 不展开） */
    void setHierarchyDepth(int depth) {
        config_.hierarchyDepth = depth > 0 ? depth : 0;
    }
    /** 展开图形数上限；收紧后可验证「截断必须可见」 */
    void setMaxWorkShapes(int n) {
        config_.maxWorkShapes = n > 0 ? n : 1;
    }

    /** 上一次提取是否因图形数上限而截断（结果不完整，调用方必须提示） */
    bool lastExtractionTruncated() const { return workTruncated_; }

    /** 图形是否参与提取（类型 + owner 过滤统一判定，**在提取之前**生效） */
    bool shapeEligible(const SceneShape& shape) const {
        if (shape.type == ShapeType::INSTANCE || shape.type == ShapeType::TEXT ||
            shape.type == ShapeType::NODE) {
            return false;
        }
        if (config_.ownerCellFilter >= 0 && shape.ownerCellId != config_.ownerCellFilter) {
            return false;
        }
        return true;
    }

    // ==================== Net Extraction ====================

    /**
     * Extract connectivity from layout geometry.
     * Algorithm:
     * 1. 按层收集可测图形（owner/type 过滤 + 几何归一化）并建 R-Tree（**仅一次**）
     * 2. Same-layer connectivity: shapes on the same layer that overlap/touch
     * 3. Cross-layer connectivity through via/contact layers（可传递：
     *    M1-via1-M2-via2-M3 归为同一网，因为连通图是全局邻接表上的单次 BFS）
     * 4. BFS 求连通分量成网；TEXT 标签命名
     * 退化图形（无法轮廓化，如零宽 PATH）不产生几何，故不入网。
     */
    std::vector<Net> extractNets(const Layout& layout) {
        nets_.clear();
        nextNetId_ = 1;

        // 按层分桶（几何归一化 + R-Tree）——同层连通、via 连通、标签命名共用
        std::unordered_map<int, LayerBucket> buckets = collectLayerBuckets(layout);

        // id → bucket 内下标（判定「可测」+ 命名定位归属网）
        std::unordered_map<int64_t, ShapeRef> refOfShape;
        for (const auto& layerEntry : buckets) {
            (void)layerEntry;
            const LayerBucket& b = layerEntry.second;
            for (size_t i = 0; i < b.shapes.size(); i++) {
                refOfShape[b.shapes[i]->id] = {layerEntry.first, (int)i};
            }
        }

        // Build shape adjacency
        std::unordered_map<int64_t, std::vector<int64_t>> adjacency;

        // Same-layer connectivity
        buildSameLayerConnectivity(buckets, adjacency);

        // Cross-layer connectivity (vias)
        buildViaConnectivity(buckets, adjacency);

        // Find connected components (nets) via BFS
        std::unordered_set<int64_t> visited;

        for (const WorkShape& w : work_) {
            const SceneShape& shape = w.shape;
            // 只从「参与提取且有可测几何」的图形起网
            if (!shapeEligible(shape)) continue;
            if (!refOfShape.count(shape.id)) continue;
            if (visited.count(shape.id)) continue;

            // BFS from this shape
            Net net;
            net.id = nextNetId_++;
            net.name = "N$" + std::to_string(net.id);

            std::queue<int64_t> bfsQueue;
            bfsQueue.push(shape.id);
            visited.insert(shape.id);

            while (!bfsQueue.empty()) {
                int64_t currentId = bfsQueue.front();
                bfsQueue.pop();

                net.shapeIds.push_back(currentId);

                auto refIt = refOfShape.find(currentId);
                if (refIt != refOfShape.end()) {
                    auto bit = buckets.find(refIt->second.layer);
                    if (bit != buckets.end()) {
                        const LayerBucket& b = bit->second;
                        const size_t bi = (size_t)refIt->second.index;
                        const SceneShape& currentShape = *b.shapes[bi];
                        net.bbox = net.bbox.unite(b.boxes[bi]);
                        const int layerNum = currentShape.layerKey.layer;
                        if (std::find(net.layers.begin(), net.layers.end(), layerNum) ==
                            net.layers.end()) {
                            net.layers.push_back(layerNum);
                        }
                    }
                }

                // Visit neighbors
                auto adjIt = adjacency.find(currentId);
                if (adjIt != adjacency.end()) {
                    for (int64_t neighborId : adjIt->second) {
                        if (!visited.count(neighborId)) {
                            visited.insert(neighborId);
                            bfsQueue.push(neighborId);
                        }
                    }
                }
            }

            if (!net.shapeIds.empty()) {
                nets_.push_back(net);
            }
        }

        // 图形 id → 所属网下标（命名与查询共用）
        shapeToNet_.clear();
        for (size_t n = 0; n < nets_.size(); n++) {
            for (int64_t sid : nets_[n].shapeIds) {
                shapeToNet_[sid] = n;
            }
        }

        // 原始 shape ID 不能表达实例路径。保留成员来源标记，UI 对实例网
        // 必须用根 Cell 坐标 bbox 定位，不把子 Cell ID 当作本地可选图形。
        {
            std::unordered_map<int64_t, int64_t> uidToReal;
            std::unordered_set<int64_t> instanceUids;
            for (const WorkShape& w : work_) {
                uidToReal[w.shape.id] = w.realId;
                if (w.fromInstance) instanceUids.insert(w.shape.id);
            }
            for (Net& net : nets_) {
                std::vector<int64_t> real;
                std::unordered_set<int64_t> seen;
                real.reserve(net.shapeIds.size());
                for (int64_t uid : net.shapeIds) {
                    if (instanceUids.count(uid) > 0) net.fromInstance = true;
                    auto it = uidToReal.find(uid);
                    const int64_t rid = it == uidToReal.end() ? uid : it->second;
                    if (seen.insert(rid).second) {
                        real.push_back(rid);
                    }
                }
                net.shapeIds = std::move(real);
            }
        }

        // Name nets by pin labels (TEXT shapes)
        assignNetNames(layout, buckets, shapeToNet_);

        return nets_;
    }

    // ==================== Device Extraction ====================

    /**
     * Extract MOSFET devices from layout.
     * Simplified: identifies gate (poly over active) regions.
     *
     * 默认层号与 ArkTS `LAYER_NAME_MAP` 对齐（4=Poly，5=AA）。
     * 与网络提取同口径：仅取 shapeEligible（含 ownerCellFilter）且有可测几何的图形。
     */
    std::vector<ExtractedDevice> extractDevices(const Layout& layout,
                                                 int polyLayer = 4,
                                                 int activeLayer = 5) {
        std::vector<ExtractedDevice> devices;

        // 复用与网络提取相同的分桶（含 owner 过滤 + 几何归一化 + R-Tree）
        std::unordered_map<int, LayerBucket> buckets = collectLayerBuckets(layout);
        auto polyIt = buckets.find(polyLayer);
        auto activeIt = buckets.find(activeLayer);
        if (polyIt == buckets.end() || activeIt == buckets.end()) {
            return devices;
        }
        const LayerBucket& polys = polyIt->second;
        const LayerBucket& actives = activeIt->second;

        int64_t devId = 1;
        for (size_t p = 0; p < polys.shapes.size(); p++) {
            const std::vector<Vec2>& polyPts = polys.polys[p];
            // 只以 bbox 粗筛，真实相交/面积判定在下方（O(P×A) 最坏，
            // 器件提取为启发式且不在 NAPI 主路径上，先保证正确性）
            for (size_t a = 0; a < actives.shapes.size(); a++) {
                if (!polys.boxes[p].intersects(actives.boxes[a])) continue;
                const std::vector<Vec2>& activePts = actives.polys[a];
                if (GeometryEngine::polygonsIntersect(polyPts, activePts)) {
                    // Intersection forms the gate region
                    auto intersection = GeometryEngine::booleanOp(
                        polyPts, activePts, ClipType::INTERSECTION);

                    for (const auto& gatePoly : intersection.polygons) {
                        ExtractedDevice dev;
                        dev.id = devId++;
                        dev.type = "NMOS";  // Would need well info for PMOS
                        dev.bbox = GeometryEngine::computeBBox(gatePoly);
                        if (!dev.bbox.valid()) continue;

                        // Width = longer dimension, Length = shorter（沟道）
                        const double w = dev.bbox.maxX - dev.bbox.minX;
                        const double h = dev.bbox.maxY - dev.bbox.minY;
                        dev.width = std::max(w, h);
                        dev.length = std::min(w, h);

                        // Find connected nets（S/D/B 需扩散区分析，未解析 = -1）
                        dev.gateNet = findNetContaining(polys.shapes[p]->id);
                        dev.sourceNet = -1;
                        dev.drainNet = -1;
                        dev.bulkNet = -1;

                        devices.push_back(dev);
                    }
                }
            }
        }

        return devices;
    }

    // ==================== LVS Comparison ====================

    /**
     * Compare extracted netlist against reference schematic.
     *
     * 保守判定原则：**任何前置条件缺失都不得记为通过**。
     * - 参考网表为空 / 解析不出网络（畸形）→ status = no-netlist / empty-schematic
     * - 版图中当前过滤范围提取到 0 网 → status = empty-layout
     * - 一个物理网承载 ≥2 个参考网名 → 判为短路（shortNets），非开路
     */
    LvsResult compare(const Layout& layout, const std::string& schematicNetlist) {
        LvsResult result;

        // 前置条件 1：参考网表必须非空且能解析出网络
        std::string trimmed;
        trimmed.reserve(schematicNetlist.size());
        for (char c : schematicNetlist) {
            if (c != ' ' && c != '\t' && c != '\r' && c != '\n') trimmed.push_back(c);
        }
        if (trimmed.empty()) {
            result.ran = false;
            result.status = "no-netlist";
            result.error = "缺少参考网表：LVS 需要 SPICE/CDL 参考网表才能比对";
            result.messages.push_back("LVS NOT RUN: " + result.error);
            return result;
        }

        std::string parseError, parseStatus;
        auto schematicNets = parseSpiceNetlist(schematicNetlist, parseError, parseStatus);
        if (!parseError.empty()) {
            result.status = parseStatus;
            result.error = parseError;
            result.messages.push_back("LVS NOT RUN: " + result.error);
            return result;
        }
        result.schematicNetCount = (int)schematicNets.size();
        if (schematicNets.empty()) {
            result.ran = false;
            result.status = "empty-schematic";
            result.error = "参考网表未解析出任何网络（格式不支持或内容畸形）";
            result.messages.push_back("LVS NOT RUN: " + result.error);
            return result;
        }

        // Extract layout nets
        auto layoutNets = extractNets(layout);
        result.layoutNetCount = (int)layoutNets.size();
        if (workTruncated_) {
            result.matched = false;
            result.ran = false;
            result.status = "truncated";
            result.error = "Network extraction is incomplete (work budget or invalid hierarchy root)";
            result.messages.push_back("LVS INCOMPLETE: " + result.error);
            return result;
        }
        if (layoutNets.empty()) {
            result.ran = false;
            result.status = "empty-layout";
            result.error = "版图在当前过滤范围内未提取到任何网络"
                           "（空布局、Cell 过滤不匹配或全为不可测图形）";
            result.messages.push_back("LVS NOT RUN: " + result.error);
            return result;
        }
        result.ran = true;

        // Compare net counts
        if (layoutNets.size() != schematicNets.size()) {
            result.messages.push_back(
                "Net count mismatch: layout=" + std::to_string(layoutNets.size()) +
                " schematic=" + std::to_string(schematicNets.size()));
        }

        // Match nets by name
        std::unordered_map<std::string, size_t> layoutNetMap;  // name → 网下标
        std::unordered_set<std::string> fragmentedNames;
        for (size_t i = 0; i < layoutNets.size(); i++) {
            for (const std::string& label : layoutNets[i].labels) {
                // Disconnected conductors sharing a reference name are a split
                // net (open), not a physical short between distinct nets.
                if (layoutNetMap.count(label)) {
                    fragmentedNames.insert(label);
                    continue;
                }
                layoutNetMap[label] = i;
            }
        }

        std::unordered_set<std::string> schNetSet(schematicNets.begin(), schematicNets.end());

        for (const auto& schNet : schematicNets) {
            auto it = layoutNetMap.find(schNet);
            if (it != layoutNetMap.end() && !fragmentedNames.count(schNet)) {
                result.matchedNets++;
            } else {
                result.openNets.push_back(schNet);
            }
        }

        // 真实短路：一个物理网上挂了 ≥2 个不同的参考网名（VDD 与 GND 被并成一座导体）
        for (const auto& net : layoutNets) {
            std::vector<std::string> onSchematic;
            for (const std::string& label : net.labels) {
                if (schNetSet.count(label)) onSchematic.push_back(label);
            }
            if (onSchematic.size() >= 2) {
                std::string key;
                for (size_t i = 0; i < onSchematic.size(); i++) {
                    if (i) key += "<->";
                    key += onSchematic[i];
                }
                if (std::find(result.shortNets.begin(), result.shortNets.end(), key) ==
                    result.shortNets.end()) {
                    result.shortNets.push_back(key);
                }
            }
        }

        // 版图多余具名网络（参考网表中不存在）
        for (const auto& net : layoutNets) {
            if (net.isAnonymous()) continue;
            for (const std::string& label : net.labels) {
                if (!schNetSet.count(label)) {
                    result.extraNets.push_back(label);
                }
            }
        }

        // 保守判定：开路/短路/多余全空 **且** 网数相等才算通过
        result.matched = result.ran &&
                         result.openNets.empty() && result.shortNets.empty() &&
                         result.extraNets.empty() &&
                         layoutNets.size() == schematicNets.size();
        result.status = result.matched ? "pass" : "mismatch";

        if (result.matched) {
            result.messages.push_back(
                "LVS PASS（连通性级预检查，非签核）: " +
                std::to_string(result.matchedNets) + " 个网络全部按名匹配");
        } else {
            result.messages.push_back("LVS FAIL: " +
                std::to_string(result.openNets.size()) + " 开路, " +
                std::to_string(result.shortNets.size()) + " 短路, " +
                std::to_string(result.extraNets.size()) + " 多余网络（连通性级预检查，非签核）");
        }

        return result;
    }

    // ==================== Netlist Export ====================

    /**
     * Export extracted netlist as SPICE format.
     *
     * 诚实性约束：器件 S/D/B 端子未解析（简化启发式）时，该器件以**注释行**
     * 输出而非伪造 `0` 端子的设备行——避免产出一份看起来合法、实则短接到
     * 地的网表被下游误用。
     */
    std::string exportSpice(const Layout& layout) {
        auto nets = extractNets(layout);
        if (workTruncated_) throw std::runtime_error("Cannot export incomplete network extraction");
        auto devices = extractDevices(layout);
        if (workTruncated_) throw std::runtime_error("Cannot export incomplete device extraction");
        validateSpiceNames(layout, nets);

        std::ostringstream ss;
        ss << "* HongTu LVS Netlist (连通性级提取，非签核)\n";
        ss << "* Generated from layout: " << layout.libName << "\n";
        ss << "* Nets: " << nets.size() << ", Devices: " << devices.size() << "\n";
        ss << "* 器件仅解析栅极所在网，S/D/B 需扩散区分析（未接线）\n\n";

        ss << ".SUBCKT " << (layout.libName.empty() ? "TOP" : layout.libName);

        // List named nets as ports
        for (const auto& net : nets) {
            if (!net.isAnonymous()) {
                ss << " " << net.name;
            }
        }
        ss << "\n\n";

        for (const auto& net : nets) {
            ss << "* NET " << net.name << " shapes=" << net.shapeIds.size()
               << " layers=" << net.layers.size() << "\n";
        }
        ss << "\n";

        // Devices
        for (const auto& dev : devices) {
            const bool terminalsResolved =
                dev.sourceNet >= 0 && dev.drainNet >= 0 && dev.bulkNet >= 0;
            std::ostringstream body;
            body << (dev.type == "PMOS" ? "PMOS" : "NMOS")
                 << " W=" << dev.width << "n L=" << dev.length << "n";
            if (terminalsResolved) {
                ss << "M" << dev.id << " "
                   << getNetName(dev.drainNet) << " "
                   << getNetName(dev.gateNet) << " "
                   << getNetName(dev.sourceNet) << " "
                   << getNetName(dev.bulkNet) << " " << body.str() << "\n";
            } else {
                ss << "* TODO M" << dev.id << " gate=" << getNetName(dev.gateNet)
                   << " (S/D/B 未解析) " << body.str() << "\n";
            }
        }

        ss << "\n.ENDS\n";
        return ss.str();
    }

    /**
     * Export as CDL (Circuit Description Language) format.
     */
    std::string exportCdl(const Layout& layout) {
        auto nets = extractNets(layout);
        if (workTruncated_) throw std::runtime_error("Cannot export incomplete network extraction");
        auto devices = extractDevices(layout);
        if (workTruncated_) throw std::runtime_error("Cannot export incomplete device extraction");
        validateSpiceNames(layout, nets);

        std::ostringstream ss;
        ss << "* CDL Netlist - HongTu LVS (连通性级提取，非签核)\n";
        ss << ".SUBCKT " << (layout.libName.empty() ? "TOP" : layout.libName) << "\n";
        ss << "+ ";

        for (const auto& net : nets) {
            if (!net.isAnonymous()) {
                ss << net.name << " ";
            }
        }
        ss << "\n\n";

        for (const auto& net : nets) {
            ss << "* NET " << net.name << "\n";
        }

        for (const auto& dev : devices) {
            const bool terminalsResolved =
                dev.sourceNet >= 0 && dev.drainNet >= 0 && dev.bulkNet >= 0;
            std::ostringstream body;
            body << dev.type << " W=" << dev.width / 1000.0 << "u L="
                 << dev.length / 1000.0 << "u";
            if (terminalsResolved) {
                ss << "M" << dev.id << " "
                   << getNetName(dev.drainNet) << " "
                   << getNetName(dev.gateNet) << " "
                   << getNetName(dev.sourceNet) << " "
                   << getNetName(dev.bulkNet) << " " << body.str() << "\n";
            } else {
                ss << "* TODO M" << dev.id << " gate=" << getNetName(dev.gateNet)
                   << " (S/D/B 未解析) " << body.str() << "\n";
            }
        }

        ss << ".ENDS\n";
        return ss.str();
    }

    // ==================== Net Queries ====================

    const std::vector<Net>& nets() const { return nets_; }

    const Net* findNetByName(const std::string& name) const {
        for (const auto& net : nets_) {
            if (net.name == name) return &net;
            for (const std::string& label : net.labels) {
                if (label == name) return &net;
            }
        }
        return nullptr;
    }

    /**
     * Highlight a net: return all shape IDs belonging to it.
     */
    std::vector<int64_t> highlightNet(const std::string& netName) const {
        const Net* net = findNetByName(netName);
        return net ? net->shapeIds : std::vector<int64_t>();
    }

private:
    LvsConfig config_;
    std::vector<Net> nets_;
    int64_t nextNetId_;
    /** shapeId → nets_ 下标（extractNets 时重建） */
    std::unordered_map<int64_t, size_t> shapeToNet_;

    /** RECT/BOX 2 点对角线归一化 4 角、PATH 轮廓化（与 DRC 内核同口径） */
    static std::vector<Vec2> effectivePolygon(const SceneShape& shape) {
        if (shape.type == ShapeType::NODE) {
            return {};
        }
        if (shape.type == ShapeType::PATH) {
            return hongtu::effectivePolygon(shape);
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

    /** 图形在层桶中的定位 */
    struct ShapeRef {
        int layer;
        int index;
    };

    /**
     * 参与本次提取的工作图形：shape.id 被改写成引擎内唯一键 uid，realId 保留原图形 id
     * 供 Net.shapeIds / UI 定位回填。depth≥1 时实例内图形与其 TEXT 标签一并展开到
     * 根 Cell 坐标系（flattenHierarchy 已含 AREF 阵列与循环引用剪枝，遍历逻辑零重写）。
     *
     * RECT 只存两个对角点：先展开成四角再变换，避免任意角度下把变换后的两点当成新对角。
     */
    struct WorkShape {
        SceneShape shape;
        int64_t realId = 0;
        bool fromInstance = false;
    };
    std::vector<WorkShape> work_;
    bool workTruncated_ = false;

    /** 按层收集图形并归一化多边形 + 建 R-Tree（连通性/命名/器件共享结构） */
    struct LayerBucket {
        std::vector<const SceneShape*> shapes;
        std::vector<std::vector<Vec2>> polys;
        std::vector<BBox> boxes;    // 与 polys 平行，仅计算一次
        RTree<int> index;

        void finalize() {
            boxes.clear();
            boxes.reserve(polys.size());
            std::vector<std::pair<int, BBox>> items;
            items.reserve(polys.size());
            for (size_t i = 0; i < polys.size(); i++) {
                BBox box = GeometryEngine::computeBBox(polys[i]);
                boxes.push_back(box);
                if (!box.valid()) continue;   // 退化多边形不入索引
                items.push_back({(int)i, box});
            }
            index.bulkLoad(items);
        }
    };


    /** 构造工作图形集（见 WorkShape 注释）：depth 0 = 本地原样，≥1 = 展开到根 Cell 坐标系 */
    void buildWorkShapes(const Layout& layout) {
        work_.clear();
        workTruncated_ = false;
        const int depth = config_.hierarchyDepth;
        int64_t uid = 1;

        if (depth <= 0) {
            work_.reserve(std::min(layout.shapes.size(), static_cast<size_t>(config_.maxWorkShapes)));
            for (const auto& src : layout.shapes) {
                if (src.type == ShapeType::NODE || src.type == ShapeType::INSTANCE) continue;
                if (config_.ownerCellFilter >= 0 && src.ownerCellId != config_.ownerCellFilter) continue;
                if ((int)work_.size() >= config_.maxWorkShapes) { workTruncated_ = true; break; }
                WorkShape w;
                w.shape = src;
                w.realId = src.id;
                w.shape.id = uid++;
                work_.push_back(std::move(w));
            }
            return;
        }

        int root = config_.ownerCellFilter;
        if (root < 0) {
            root = layout.topCellId();
        }
        if (root < 0) {
            // No root is valid for a truly empty document. Never recurse with
            // unchanged depth when a malformed nonempty layout lacks Cells.
            workTruncated_ = !layout.shapes.empty();
            return;
        }

        layout.flattenHierarchy(root, depth + 1,
                                [&](const SceneShape& src,
                                    const GeometryEngine::Transform2D& xf) {
            if (src.type == ShapeType::INSTANCE || src.type == ShapeType::NODE) return;
            if ((int)work_.size() >= config_.maxWorkShapes) {
                workTruncated_ = true;
                return;
            }
            WorkShape w;
            w.shape = src;
            w.realId = src.id;
            w.fromInstance = src.ownerCellId != root;
            w.shape.ownerCellId = root;
            w.shape.id = uid++;
            std::vector<Vec2> pts = src.points;
            if (src.type == ShapeType::RECT && pts.size() == 2) {
                pts = {{pts[0].x, pts[0].y}, {pts[1].x, pts[0].y},
                       {pts[1].x, pts[1].y}, {pts[0].x, pts[1].y}};
            }
            std::vector<Vec2> out;
            out.reserve(pts.size());
            for (const auto& q : pts) {
                out.push_back(xf.apply(q));   // 恒等变换下逐点等值
            }
            w.shape.points = std::move(out);
            if (src.type == ShapeType::PATH) {
                const double scale = std::sqrt(std::abs(xf.determinant()));
                if (!src.pathWidthAbsolute) w.shape.pathWidth *= scale;
                w.shape.pathBeginExtension *= scale;
                w.shape.pathEndExtension *= scale;
            }
            work_.push_back(std::move(w));
        });
    }
    /**
     * 按层分桶：owner/type 过滤 → 几何归一化 → bbox 缓存 → R-Tree。
     * **过滤发生在提取之前**（不在结果上二次裁剪），因此被过滤掉的 Cell
     * 不会产生任何几何，compare() 会据此返回 empty-layout 而非「通过」。
     */
    std::unordered_map<int, LayerBucket> collectLayerBuckets(const Layout& layout) {
        buildWorkShapes(layout);
        std::unordered_map<int, LayerBucket> buckets;
        std::unordered_set<int64_t> seenIds;   // 防御：重复 id 入库会造成自环/成员重复
        for (const WorkShape& w : work_) {
            const SceneShape& shape = w.shape;
            if (!shapeEligible(shape)) continue;
            // 去重仅在**不展开**时按原 id 生效（那是同一份数据里的重复记录）；
            // 展开后同一子 Cell 图形的多次实例化是不同物理图形，必须各自参与连通。
            if (config_.hierarchyDepth == 0 && !seenIds.insert(w.realId).second) continue;
            std::vector<Vec2> poly = effectivePolygon(shape);
            if (poly.size() < 3) continue;     // 不可测几何（零宽 PATH / 退化多边形）
            LayerBucket& b = buckets[shape.layerKey.layer];
            b.shapes.push_back(&shape);
            b.polys.push_back(std::move(poly));
        }
        for (auto& entry : buckets) {
            entry.second.finalize();
        }
        return buckets;
    }

    // ==================== Connectivity Building ====================

    /** 容差感知的连通判定：真实交叠/接触恒连通；mergeTolerance > 0 时间隙亦连通 */
    bool connectedWithin(const std::vector<Vec2>& a, const std::vector<Vec2>& b,
                         const BBox& boxA, const BBox& boxB) const {
        if (GeometryEngine::polygonsIntersect(a, b)) return true;
        const double tol = config_.mergeTolerance;
        if (!(tol > 0.0)) return false;
        if (boxA.distanceTo(boxB) > tol) return false;   // bbox 间隙下界快速拒绝
        return GeometryEngine::polygonToPolygonDistance(a, b) <= tol;
    }

    void buildSameLayerConnectivity(
        const std::unordered_map<int, LayerBucket>& buckets,
        std::unordered_map<int64_t, std::vector<int64_t>>& adjacency) const {
        const double tol = config_.mergeTolerance > 0.0 ? config_.mergeTolerance : 0.0;
        for (const auto& entry : buckets) {
            const LayerBucket& b = entry.second;
            for (size_t i = 0; i < b.shapes.size(); i++) {
                auto neighbors = b.index.queryRange(b.boxes[i].expand(tol));
                for (int j : neighbors) {
                    if (j <= (int)i) continue;   // 成对只判一次（含自身）
                    const size_t jj = (size_t)j;
                    // Drawing and annotation purposes sharing a layer number are distinct conductors.
                    if (b.shapes[i]->layerKey.datatype != b.shapes[jj]->layerKey.datatype) continue;
                    if (connectedWithin(b.polys[i], b.polys[jj], b.boxes[i], b.boxes[jj])) {
                        const int64_t aId = b.shapes[i]->id;
                        const int64_t bId = b.shapes[jj]->id;
                        if (aId == bId) continue;
                        adjacency[aId].push_back(bId);
                        adjacency[bId].push_back(aId);
                    }
                }
            }
        }
    }

    /**
     * via/contact 跨层连通：via ↔ 下层、via ↔ 上层各建边。
     * 传递性由「全局邻接表 + 单次 BFS」保证：M1-via1-M2 与 M2-via2-M3
     * 会在同一次 BFS 中并入同一网络（无需在 via 层之间显式建边）。
     */
    void buildViaConnectivity(
        const std::unordered_map<int, LayerBucket>& buckets,
        std::unordered_map<int64_t, std::vector<int64_t>>& adjacency) const {
        if (config_.viaLayers.empty()) {
            return; // 无 via 配置：仅同层连通（调用方可显式提供工艺连通表）
        }
        const double tol = config_.mergeTolerance > 0.0 ? config_.mergeTolerance : 0.0;

        auto connectVia = [&](const LayerBucket& vias, const LayerBucket& target, size_t viaIdx, int targetDatatype) {
            auto hits = target.index.queryRange(vias.boxes[viaIdx].expand(tol));
            for (int t : hits) {
                if (t < 0 || (size_t)t >= target.shapes.size()) continue;
                if (targetDatatype >= 0 && target.shapes[(size_t)t]->layerKey.datatype != targetDatatype) continue;
                const int64_t viaId = vias.shapes[viaIdx]->id;
                const int64_t targetId = target.shapes[(size_t)t]->id;
                if (viaId == targetId) continue;
                if (connectedWithin(vias.polys[viaIdx], target.polys[(size_t)t],
                                    vias.boxes[viaIdx], target.boxes[(size_t)t])) {
                    adjacency[viaId].push_back(targetId);
                    adjacency[targetId].push_back(viaId);
                }
            }
        };

        for (const auto& viaConfig : config_.viaLayers) {
            auto viaIt = buckets.find(viaConfig.viaLayer);
            if (viaIt == buckets.end()) continue;
            auto lowerIt = buckets.find(viaConfig.lowerLayer);
            auto upperIt = buckets.find(viaConfig.upperLayer);

            for (size_t v = 0; v < viaIt->second.shapes.size(); v++) {
                if (viaConfig.viaDatatype >= 0 && viaIt->second.shapes[v]->layerKey.datatype != viaConfig.viaDatatype) continue;
                if (lowerIt != buckets.end() && viaConfig.lowerLayer != viaConfig.viaLayer) {
                    connectVia(viaIt->second, lowerIt->second, v, viaConfig.lowerDatatype);
                }
                if (upperIt != buckets.end() && viaConfig.upperLayer != viaConfig.viaLayer) {
                    connectVia(viaIt->second, upperIt->second, v, viaConfig.upperDatatype);
                }
            }
        }
    }

    // ==================== Net Naming ====================

    /**
     * 用 TEXT 标签给网络命名（标签同样受 owner 过滤）。
     * 候选来自层桶 R-Tree（O(log n)），并按 shape id 升序取首个真实包含落点的
     * 图形——避免遍历全表带来的 O(标签×图形) 退化与哈希序不确定性。
     * 一个网可有多个标签：首个标签定为 name（不再被后续标签覆盖），
     * 全部不同名记入 labels，供 compare() 识别「一网多网名 = 短路」。
     */
    void assignNetNames(
        const Layout& layout,
        const std::unordered_map<int, LayerBucket>& buckets,
        const std::unordered_map<int64_t, size_t>& netOfShape) {
        for (const WorkShape& lw : work_) {
            const SceneShape& label = lw.shape;
            if (label.type != ShapeType::TEXT || label.text.empty() || label.points.empty()) {
                continue;
            }
            if (config_.ownerCellFilter >= 0 && label.ownerCellId != config_.ownerCellFilter) {
                continue;
            }
            auto bit = buckets.find(label.layerKey.layer);
            if (bit == buckets.end()) continue;
            const LayerBucket& b = bit->second;

            std::vector<int> hits = b.index.queryPoint(label.points[0].x, label.points[0].y);
            std::sort(hits.begin(), hits.end(), [&b](int lhs, int rhs) {
                return b.shapes[(size_t)lhs]->id < b.shapes[(size_t)rhs]->id;
            });

            for (int idx : hits) {
                if (idx < 0 || (size_t)idx >= b.shapes.size()) continue;
                if (GeometryEngine::pointInPolygon(label.points[0], b.polys[(size_t)idx]) < 0) {
                    continue;   // 仅落在 bbox 内而不在多边形内
                }
                auto nit = netOfShape.find(b.shapes[(size_t)idx]->id);
                if (nit == netOfShape.end() || nit->second >= nets_.size()) continue;
                Net& net = nets_[nit->second];
                net.pinCount++;
                if (std::find(net.labels.begin(), net.labels.end(), label.text) ==
                    net.labels.end()) {
                    const bool firstLabel = net.labels.empty();
                    net.labels.push_back(label.text);
                    if (firstLabel) {
                        net.name = label.text;
                    }
                }
                break;
            }
        }
    }

    int64_t findNetContaining(int64_t shapeId) const {
        auto it = shapeToNet_.find(shapeId);
        if (it == shapeToNet_.end() || it->second >= nets_.size()) return -1;
        return nets_[it->second].id;
    }

    std::string getNetName(int64_t netId) const {
        if (netId < 0) return "0";  // Ground
        for (const auto& net : nets_) {
            if (net.id == netId) return net.name;
        }
        return "N$" + std::to_string(netId);
    }

    // ==================== SPICE Parser ====================

    /** 两端空白裁剪 */
    static std::string trimWs(const std::string& s) {
        size_t b = 0;
        size_t e = s.size();
        while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) b++;
        while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' ||
                         s[e - 1] == '\r' || s[e - 1] == '\n')) e--;
        return s.substr(b, e - b);
    }

    static char upperChar(char c) {
        return (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c;
    }

    /**
     * 器件类型 → 端子（网络）个数。
     * 未知/非器件返回 0（该行不参与网络收集）。
     * 注意：Q(BJT) 按 3 端子解析，衬底极需 SPICE 变体识别——预检查口径。
     */
    static size_t deviceTerminalCount(char typeChar) {
        switch (upperChar(typeChar)) {
            case 'M': return 4;   // D G B S
            case 'Q': return 3;   // C B E
            case 'R': case 'C': case 'L':
            case 'D': case 'V': case 'I':
                return 2;
            default:
                return 0;
        }
    }

    /**
     * 解析 SPICE/CDL 参考网表，收集网络名。
     * 支持：`.SUBCKT` 端口（含 `+` 续行）、器件行按类型取端子数、大小写不敏感、
     * 行首空白、`*` 与 `//` 注释、参数列（含 `=`）与模型名不并入网络。
     * 约定：地节点 `0` 不参与按名比对（版图 TEXT 不会命名网络为 0，
     * 否则每个参考网表都会凭空多出一条假开路）。
     */
    static bool validSpiceName(const std::string& name) {
        if (name.empty() || name[0] == '*' || name[0] == '$' || name[0] == '.' ||
            name[0] == '+' || name.compare(0, 2, "//") == 0) return false;
        for (unsigned char c : name) {
            if (c <= 32 || c == 127 || c == '=' || c == ';') return false;
        }
        return true;
    }

    static void validateSpiceNames(const Layout& layout, const std::vector<Net>& nets) {
        if (!layout.libName.empty() && !validSpiceName(layout.libName))
            throw std::runtime_error("SPICE export requires a single-token library name without control/comment syntax");
        for (const auto& net : nets) {
            for (const auto& label : net.labels) {
                if (!validSpiceName(label))
                    throw std::runtime_error("SPICE export requires single-token net labels without control/comment syntax; labels were not renamed");
            }
        }
    }

    std::vector<std::string> parseSpiceNetlist(const std::string& netlist,
            std::string& error, std::string& status) const {
        std::vector<std::string> netNames;
        auto reject = [&](const std::string& message, bool unsupported = false) {
            error = message;
            status = unsupported ? "unsupported-schematic" : "invalid-schematic";
            return std::vector<std::string>{};
        };
        auto addNet = [&netNames](const std::string& token) {
            if (token.empty() || token == "0") return;
            if (std::find(netNames.begin(), netNames.end(), token) == netNames.end()) {
                netNames.push_back(token);
            }
        };

        // 1. 合并续行为逻辑行（跳过注释/空行，容忍 \r\n 与行首空白）
        std::vector<std::string> logicalLines;
        {
            std::istringstream ss(netlist);
            std::string raw;
            std::string acc;
            while (std::getline(ss, raw)) {
                std::string body = trimWs(raw);
                if (body.empty()) continue;
                if (acc.empty() && body[0] == '+')
                    return reject("参考网表含无前置记录的续行，未进行比较");
                if (body[0] == '*') continue;
                if (body.size() >= 2 && body[0] == '/' && body[1] == '/') continue;
                // SPICE/CDL end-of-line comments must not become SUBCKT pins.
                for (size_t pos = 0; pos < body.size(); ++pos) {
                    if ((pos == 0 || body[pos - 1] == ' ' || body[pos - 1] == '\t') &&
                        (body[pos] == '$' || body[pos] == ';' || body.compare(pos, 2, "//") == 0)) {
                        body = trimWs(body.substr(0, pos));
                        break;
                    }
                }
                if (body.empty()) continue;
                if (!acc.empty() && body[0] == '+') {
                    acc += " " + trimWs(body.substr(1));
                    continue;
                }
                if (!acc.empty()) logicalLines.push_back(acc);
                acc = body;
            }
            if (!acc.empty()) logicalLines.push_back(acc);
        }

        // 2. 逐逻辑行取 token
        bool hasSubckt = false, inSubckt = false, scopeEnded = false;
        for (const std::string& line : logicalLines) {
            std::istringstream ls(line);
            std::vector<std::string> tokens;
            std::string token;
            while (ls >> token) tokens.push_back(token);
            if (tokens.empty()) continue;

            const char first = tokens[0][0];
            if (first == '.') {
                // 仅 .SUBCKT 提供端口名；其余指令（.PARAM/.END/.GLOBAL/…）跳过
                std::string kw;
                for (char c : tokens[0]) kw.push_back(upperChar(c));
                if (kw == ".INCLUDE" || kw == ".INC" || kw == ".LIB" || kw == ".GLOBAL")
                    return reject("连通性预检查不展开外部文件或全局节点指令，请提供独立平坦参考网表", true);
                if (kw == ".ENDS") {
                    if (!inSubckt) return reject("参考网表含无对应 SUBCKT 的 ENDS");
                    inSubckt = false; scopeEnded = true; continue;
                }
                if (kw != ".SUBCKT") continue;
                if (hasSubckt) return reject("连通性预检查不能合并多个 SUBCKT 的局部网名，请使用工艺器件 LVS", true);
                if (tokens.size() < 2 || !validSpiceName(tokens[1]))
                    return reject("参考网表 SUBCKT 缺少合法名称");
                hasSubckt = true; inSubckt = true;
                for (size_t i = 2; i < tokens.size(); i++) {
                    const std::string& pin = tokens[i];
                    std::string keyword;
                    for (char c : pin) keyword.push_back(upperChar(c));
                    if (pin.empty() || pin[0] == '.' || pin[0] == '*' ||
                        keyword == "PARAMS:" || keyword == "PARAMS" ||
                        keyword.compare(0, 7, "PARAMS:") == 0 ||
                        pin.find('=') != std::string::npos ||
                        (i + 1 < tokens.size() && !tokens[i + 1].empty() && tokens[i + 1][0] == '=')) break;
                    if (!validSpiceName(pin)) return reject("参考网表端口名无效");
                    addNet(pin);
                }
                continue;
            }

            const size_t terminals = deviceTerminalCount(first);
            if (terminals == 0)
                return reject("连通性预检查不支持该器件/层级记录：" + tokens[0] + "，请使用工艺器件 LVS", true);
            if (scopeEnded) return reject("参考网表含 SUBCKT 范围之外的器件，无法确定唯一网络范围", true);
            if (tokens.size() < terminals + 2)
                return reject("参考器件端子或模型/值不完整：" + tokens[0]);
            for (size_t i = 1; i <= terminals; i++) {
                const std::string& t = tokens[i];
                if (!validSpiceName(t)) return reject("参考器件端子名无效：" + tokens[0]);
                addNet(t);
            }
        }
        if (inSubckt) return reject("参考网表 SUBCKT 未由 ENDS 结束");

        return netNames;
    }
};

} // namespace hongtu

#endif // HONGTU_LVS_ENGINE_H
