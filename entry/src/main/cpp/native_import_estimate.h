#ifndef HONGTU_NATIVE_IMPORT_ESTIMATE_H
#define HONGTU_NATIVE_IMPORT_ESTIMATE_H
#include "gdsii_reader.h"
#include <algorithm>
#include <functional>
#include <stdexcept>
namespace hongtu {

constexpr uint64_t kMaxInteractiveStoredShapes = 2000000ULL;
constexpr uint64_t kMaxInteractiveCoordinates = 25000000ULL;
constexpr uint64_t kMaxInteractiveExpandedObjects = 10000000ULL;

struct InteractiveImportEstimate {
    uint64_t storedShapes = 0, coordinates = 0, instanceRecords = 0, arrayMembers = 0;
    uint64_t expandedObjects = 0, expandedPlacements = 0, geometryBytes = 0;
    bool bounded = false, withinBudget = true;
    std::string message;
};

// Largest Cell expansion scope. Counts are analytic; arrays remain compressed.
// geometryBytes estimates only stored geometry payload, never process peak RAM.
inline InteractiveImportEstimate EstimateInteractiveImport(const GdsiiParseResult& parsed,
                                                            const NativeJobControl* control = nullptr) {
    constexpr uint64_t countCap = 1000000000000ULL;
    InteractiveImportEstimate out;
    out.storedShapes = parsed.shapes.size();
    std::vector<uint64_t> local(parsed.cells.size(), 0), memo(parsed.cells.size(), 0), placements(parsed.cells.size(), 0);
    std::vector<int> visiting(parsed.cells.size(), 0);
    std::vector<std::vector<const LayoutShape*>> children(parsed.cells.size());
    auto add = [&](uint64_t a, uint64_t b) { if (b > countCap - std::min(a, countCap)) { out.bounded = true; return countCap; } return a + b; };
    auto multiply = [&](uint64_t a, uint64_t b) { if (a && b > countCap / a) { out.bounded = true; return countCap; } return a * b; };
    for (const auto& shape : parsed.shapes) {
        if (control) control->check();
        out.coordinates = add(out.coordinates, shape.points.size());
        if (shape.type == "instance") {
            ++out.instanceRecords;
            out.arrayMembers = add(out.arrayMembers, multiply(std::max(1, shape.arrayCols), std::max(1, shape.arrayRows)));
        }
        const int owner = shape.ownerCellId >= 0 ? shape.ownerCellId : parsed.primaryTopCellId;
        if (owner < 0 || owner >= static_cast<int>(local.size())) continue;
        if (shape.type == "instance") children[owner].push_back(&shape); else ++local[owner];
    }
    std::function<uint64_t(int, int)> count = [&](int cell, int depth) -> uint64_t {
        if (control) control->check();
        if (depth > 256) throw std::runtime_error("交互导入超过 256 层层级上限，当前文档未更改");
        if (visiting[cell] == 1) throw std::runtime_error("检测到循环 Cell 引用，当前文档未更改");
        if (visiting[cell] == 2) return memo[cell];
        visiting[cell] = 1;
        uint64_t total = local[cell], nested = 0;
        for (const auto* instance : children[cell]) {
            if (control) control->check();
            const uint64_t repeats = multiply(std::max(1, instance->arrayCols), std::max(1, instance->arrayRows));
            uint64_t child = 1, childPlacements = 0;
            if (instance->cellId >= 0 && instance->cellId < static_cast<int>(local.size())) {
                child = std::max<uint64_t>(1, count(instance->cellId, depth + 1)); childPlacements = placements[instance->cellId];
            }
            total = add(total, multiply(repeats, child));
            nested = add(nested, multiply(repeats, add(1, childPlacements)));
        }
        visiting[cell] = 2; placements[cell] = nested; return memo[cell] = total;
    };
    for (size_t cell = 0; cell < parsed.cells.size(); ++cell) {
        out.expandedObjects = std::max(out.expandedObjects, count(static_cast<int>(cell), 0));
        out.expandedPlacements = std::max(out.expandedPlacements, placements[cell]);
    }
    out.geometryBytes = out.storedShapes * 256 + out.coordinates * 16;
    out.withinBudget = out.storedShapes <= kMaxInteractiveStoredShapes &&
                       out.coordinates <= kMaxInteractiveCoordinates &&
                       out.expandedObjects <= kMaxInteractiveExpandedObjects;
    out.message = out.withinBudget ? "几何载荷估算不含文件缓冲、名称/属性、空间索引、JS 对象和运行时开销，不保证峰值内存" :
        "超过交互预算（存储图形 200 万、坐标 2500 万或最大 Cell 展开 1000 万），请拆分版图；当前文档未更改";
    return out;
}
}
#endif
