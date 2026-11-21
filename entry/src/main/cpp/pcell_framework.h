/**
 * HongTu EDA - PCell Framework（参数化单元）
 *
 * KLayout 风格 PCell 引擎：参数声明/校验/默认值 + 几何生成回调 + 库管理。
 * 经 NAPI listPCells/generatePCell 暴露给 ArkTS（生成在临时 Layout，
 * 返回图形由 ArkTS 文档接管，保持编辑单一数据源）。
 *
 * 内置库：
 * - Basic（对齐 KLayout Basic 库）：CIRCLE / ELLIPSE / DONUT / ARC / NOPATH / NPATH / MEANDER / STAR / COMB
 * - Devices：MOSFET（多指栅）、GUARD_RING
 * - Connect：VIA_STACK
 *
 * 脚本 PCell（Ruby/Python）明确 defer：HarmonyOS 端内嵌解释器
 * 属独立大工程，当前以 C++ 内置 PCell 提供参数化能力。
 *
 * host 冒烟：tools/pcell_smoke.cpp
 * This file is part of HongTu, licensed under GPLv3.
 */
#ifndef HONGTU_PCELL_FRAMEWORK_H
#define HONGTU_PCELL_FRAMEWORK_H

#include "scene_graph.h"
#include <string>
#include <vector>
#include <variant>
#include <functional>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <cmath>
#include <algorithm>
#include <stdexcept>

#include "triangulator.h"
#include "demo_layers.h"

namespace hongtu {

// ==================== Parameter Types ====================

enum class PCellParamType {
    INT,
    DOUBLE,
    STRING,
    BOOLEAN,
    LIST,       // Dropdown selection
    LAYER,      // Layer selection
    SHAPE,      // Shape parameter
};

// Parameter value variant
using PCellParamValue = std::variant<int64_t, double, std::string, bool>;

// Parameter declaration
struct PCellParam {
    std::string name;
    std::string displayName;
    std::string description;
    PCellParamType type;
    PCellParamValue defaultValue;
    PCellParamValue minValue;   // For INT/DOUBLE
    PCellParamValue maxValue;
    double step;                // For DOUBLE (GUI increment)
    std::vector<std::string> choices;  // For LIST type
    std::string unit;           // Display unit (nm, um, deg, etc.)
    bool hidden;                // Hidden from GUI
    bool readonly;

    PCellParam() : type(PCellParamType::DOUBLE), defaultValue(0.0),
                  minValue(0.0), maxValue(1e9), step(1.0),
                  hidden(false), readonly(false) {}
};

// Parameter set (instance-specific values)
using PCellParamSet = std::unordered_map<std::string, PCellParamValue>;

// ==================== PCell Declaration ====================

/**
 * PCellDeclaration: Base class for parameterized cell definitions.
 * Subclass this to create custom PCells.
 */
class PCellDeclaration {
public:
    virtual ~PCellDeclaration() = default;

    // Identity
    virtual std::string name() const = 0;
    virtual std::string displayName() const { return name(); }
    virtual std::string description() const { return ""; }
    virtual std::string category() const { return "Basic"; }

    // Parameters
    virtual std::vector<PCellParam> parameters() const = 0;

    // Geometry generation
    virtual void generate(const PCellParamSet& params, Layout& layout, int cellId) const = 0;
    // Geometry without an explicitly declared interface has no semantic ports.
    virtual std::vector<LayoutPort> generatePorts(const PCellParamSet&, int) const { return {}; }

    // Validation
    virtual bool validateParams(const PCellParamSet& params, std::string& error) const {
        for (const auto& decl : parameters()) {
            auto it = params.find(decl.name);
            if (it == params.end()) continue;  // Will use default

            if (decl.type == PCellParamType::INT || decl.type == PCellParamType::DOUBLE) {
                if (!std::holds_alternative<double>(it->second) && !std::holds_alternative<int64_t>(it->second)) {
                    error = decl.displayName + " requires a numeric value";
                    return false;
                }
                double val = getDouble(params, decl.name);
                double minV = getDoubleFromValue(decl.minValue);
                double maxV = getDoubleFromValue(decl.maxValue);
                if (!std::isfinite(val) || val < minV || val > maxV ||
                    (decl.type == PCellParamType::INT && std::floor(val) != val)) {
                    error = decl.displayName + " out of range [" +
                           std::to_string(minV) + ", " + std::to_string(maxV) + "]";
                    return false;
                }
            }
        }
        return true;
    }

    // Default parameter set
    PCellParamSet defaultParams() const {
        PCellParamSet params;
        for (const auto& decl : parameters()) {
            params[decl.name] = decl.defaultValue;
        }
        return params;
    }

protected:
    static double getDouble(const PCellParamSet& params, const std::string& name) {
        auto it = params.find(name);
        if (it == params.end()) return 0;
        return getDoubleFromValue(it->second);
    }

    static int64_t getInt(const PCellParamSet& params, const std::string& name) {
        auto it = params.find(name);
        if (it == params.end()) return 0;
        if (auto* v = std::get_if<int64_t>(&it->second)) return *v;
        if (auto* v = std::get_if<double>(&it->second)) return (int64_t)*v;
        return 0;
    }

    static std::string getString(const PCellParamSet& params, const std::string& name) {
        auto it = params.find(name);
        if (it == params.end()) return "";
        if (auto* v = std::get_if<std::string>(&it->second)) return *v;
        return "";
    }

    static bool getBool(const PCellParamSet& params, const std::string& name) {
        auto it = params.find(name);
        if (it == params.end()) return false;
        if (auto* v = std::get_if<bool>(&it->second)) return *v;
        return false;
    }

    static void addRect(Layout& layout, int cellId, int layer, int datatype,
                        double x1, double y1, double x2, double y2) {
        SceneShape shape{};
        shape.type = ShapeType::RECT;
        shape.layerKey = {(int16_t)layer, (int16_t)datatype};
        shape.ownerCellId = cellId;
        shape.pathWidth = 0;
        shape.points = {{x1, y1}, {x2, y1}, {x2, y2}, {x1, y2}};
        layout.addShape(shape);
    }

    static void addPolygon(Layout& layout, int cellId, int layer, int datatype,
                           const std::vector<Vec2>& points) {
        SceneShape shape{};
        shape.type = ShapeType::POLYGON;
        shape.layerKey = {(int16_t)layer, (int16_t)datatype};
        shape.ownerCellId = cellId;
        shape.pathWidth = 0;
        shape.points = points;
        layout.addShape(shape);
    }

    static void addPath(Layout& layout, int cellId, int layer, int datatype,
                        const std::vector<Vec2>& points, double width) {
        SceneShape shape{};
        shape.type = ShapeType::PATH;
        shape.layerKey = {(int16_t)layer, (int16_t)datatype};
        shape.ownerCellId = cellId;
        shape.pathWidth = width;
        shape.points = points;
        layout.addShape(shape);
    }

    static void addInstance(Layout& layout, int cellId, int refCellId,
                            double x, double y, double rotation = 0, bool mirror = false) {
        CellInstance inst{};
        inst.referencedCellId = refCellId;
        inst.ownerCellId = cellId;
        inst.transform.x = x;
        inst.transform.y = y;
        inst.transform.rotation = rotation;
        inst.transform.mirrorX = mirror;
        layout.addInstance(inst);
    }

private:
    static double getDoubleFromValue(const PCellParamValue& v) {
        if (auto* d = std::get_if<double>(&v)) return *d;
        if (auto* i = std::get_if<int64_t>(&v)) return (double)*i;
        return 0;
    }
};

// ==================== Built-in PCells ====================

namespace pcelldetail {
constexpr double kPi = 3.14159265358979323846;
constexpr int64_t kDefaultCurveSegments = 128;
constexpr int64_t kMaxCurveSegments = 4096;

inline PCellParam intParam(const char* name, const char* disp, int64_t def,
                           int64_t lo, int64_t hi) {
    PCellParam p;
    p.name = name;
    p.displayName = disp;
    p.type = PCellParamType::INT;
    p.defaultValue = def;
    p.minValue = lo;
    p.maxValue = hi;
    return p;
}

inline PCellParam dblParam(const char* name, const char* disp, double def,
                           double lo, double hi, double step = 10.0,
                           const char* unit = "nm") {
    PCellParam p;
    p.name = name;
    p.displayName = disp;
    p.type = PCellParamType::DOUBLE;
    p.defaultValue = def;
    p.minValue = lo;
    p.maxValue = hi;
    p.step = step;
    p.unit = unit;
    return p;
}

inline PCellParam layerParam(const char* name = "layer", const char* disp = "图层",
                             int64_t def = 1) {
    return intParam(name, disp, def, 0, 32767);
}

inline PCellParam datatypeParam(const char* name = "datatype", const char* disp = "数据类型",
                                int64_t def = 0) {
    return intParam(name, disp, def, 0, 32767);
}

inline void appendCurveParams(std::vector<PCellParam>& params) {
    params.push_back(datatypeParam());
    params.push_back(dblParam("max_error", "最大近似偏差 (0=按边数)", 0, 0, 1e8, 1));
}

/** Bound chord deviation, including an ellipse under its affine circle map. */
inline int curveSegments(double radius, double sweep, int requested, double maxError) {
    int result = requested;
    if (maxError > 0 && radius > 0) {
        const double ratio = std::min(1.0, maxError / radius);
        const double halfStep = std::acos(1.0 - ratio);
        if (!(halfStep > 0)) throw std::invalid_argument("近似精度过小，无法可靠计算边数");
        const double needed = std::ceil(sweep / (2 * halfStep));
        if (!std::isfinite(needed) || needed > static_cast<double>(kMaxCurveSegments))
            throw std::invalid_argument("近似精度需要超过 4096 段，请增大允许偏差");
        result = std::max(result, static_cast<int>(needed));
    }
    return std::max(4, std::min(static_cast<int>(kMaxCurveSegments), result));
}

inline bool validateCurvePrecision(double radius, double sweep, int requested, double maxError, std::string& error) {
    try { (void)curveSegments(radius, sweep, requested, maxError); return true; }
    catch (const std::exception& e) { error = e.what(); return false; }
}

inline double quantizeCurveNm(double value) {
    return std::isfinite(value) ? static_cast<double>(std::llround(value)) : value;
}

inline Vec2 quantizeCurvePoint(double x, double y) {
    return {quantizeCurveNm(x), quantizeCurveNm(y)};
}

inline std::vector<Vec2> sanitizeQuantizedClosedRing(const std::vector<Vec2>& raw) {
    std::vector<Vec2> out;
    out.reserve(raw.size());
    for (const auto& p : raw) {
        const Vec2 q = quantizeCurvePoint(p.x, p.y);
        if (out.empty() || out.back().x != q.x || out.back().y != q.y) {
            out.push_back(q);
        }
    }
    while (out.size() > 3 && out.front().x == out.back().x && out.front().y == out.back().y) {
        out.pop_back();
    }
    return out.size() >= 3 ? out : raw;
}

inline void appendQuantizedArcChain(std::vector<Vec2>& dst, const std::vector<Vec2>& chain) {
    for (size_t i = 0; i < chain.size(); ++i) {
        const Vec2 q = quantizeCurvePoint(chain[i].x, chain[i].y);
        const bool isEndpoint = (i == 0 || i + 1 == chain.size());
        if (!isEndpoint && !dst.empty() && dst.back().x == q.x && dst.back().y == q.y) {
            continue;
        }
        dst.push_back(q);
    }
}
}

/**
 * CIRCLE PCell（KLayout Basic 库对齐）：圆 → N 边形。
 */
class CirclePCell : public PCellDeclaration {
public:
    std::string name() const override { return "CIRCLE"; }
    std::string displayName() const override { return "圆形"; }
    std::string description() const override { return "圆（N 边形近似），对齐 KLayout Basic.CIRCLE"; }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;
        PCellParam layer;
        layer.name = "layer";
        layer.displayName = "图层";
        layer.type = PCellParamType::INT;
        layer.defaultValue = (int64_t)1;
        layer.minValue = (int64_t)0;
        layer.maxValue = (int64_t)32767;
        params.push_back(layer);

        PCellParam radius;
        radius.name = "radius";
        radius.displayName = "半径";
        radius.type = PCellParamType::DOUBLE;
        radius.defaultValue = 500.0;
        radius.minValue = 1.0;
        radius.maxValue = 1e8;
        radius.step = 10.0;
        radius.unit = "nm";
        params.push_back(radius);

        PCellParam segments;
        segments.name = "segments";
        segments.displayName = "边数";
        segments.type = PCellParamType::INT;
        segments.defaultValue = pcelldetail::kDefaultCurveSegments;
        segments.minValue = (int64_t)8;
        segments.maxValue = pcelldetail::kMaxCurveSegments;
        params.push_back(segments);
        pcelldetail::appendCurveParams(params);
        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        return PCellDeclaration::validateParams(params, error) &&
            pcelldetail::validateCurvePrecision(getDouble(params, "radius"), 2 * pcelldetail::kPi,
                static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error"), error);
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const double radius = getDouble(params, "radius");
        const int segments = std::max(8, pcelldetail::curveSegments(radius, 2 * pcelldetail::kPi,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error")));
        std::vector<Vec2> pts;
        pts.reserve((size_t)segments);
        for (int i = 0; i < segments; i++) {
            const double a = 2.0 * pcelldetail::kPi * i / segments;
            pts.push_back({radius * std::cos(a), radius * std::sin(a)});
        }
        addPolygon(layout, cellId, layer, datatype, pcelldetail::sanitizeQuantizedClosedRing(pts));
    }
};

class EllipsePCell : public PCellDeclaration {
public:
    std::string name() const override { return "ELLIPSE"; }
    std::string displayName() const override { return "椭圆"; }
    std::string description() const override { return "椭圆（X/Y 半轴、多边形近似，中心为放置位置）"; }
    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params = { pcelldetail::layerParam(),
            pcelldetail::dblParam("radius_x", "X 半轴", 500, 1, 1e8),
            pcelldetail::dblParam("radius_y", "Y 半轴", 300, 1, 1e8),
            pcelldetail::intParam("segments", "最少边数", pcelldetail::kDefaultCurveSegments, 8, pcelldetail::kMaxCurveSegments) };
        pcelldetail::appendCurveParams(params);
        return params;
    }
    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        return PCellDeclaration::validateParams(params, error) &&
            pcelldetail::validateCurvePrecision(std::max(getDouble(params, "radius_x"), getDouble(params, "radius_y")),
                2 * pcelldetail::kPi, static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error"), error);
    }
    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const double rx = getDouble(params, "radius_x"), ry = getDouble(params, "radius_y");
        int segments = std::max(8, pcelldetail::curveSegments(std::max(rx, ry), 2 * pcelldetail::kPi,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error")));
        segments = std::min(static_cast<int>(pcelldetail::kMaxCurveSegments), ((segments + 3) / 4) * 4);
        std::vector<Vec2> pts;
        pts.reserve(static_cast<size_t>(segments));
        for (int i = 0; i < segments; ++i) {
            const double angle = 2 * pcelldetail::kPi * i / segments;
            pts.push_back({rx * std::cos(angle), ry * std::sin(angle)});
        }
        addPolygon(layout, cellId, static_cast<int>(getInt(params, "layer")), static_cast<int>(getInt(params, "datatype")),
                   pcelldetail::sanitizeQuantizedClosedRing(pts));
    }
};

/**
 * DONUT PCell（KLayout Basic 库对齐）：圆环。
 */
class DonutPCell : public PCellDeclaration {
public:
    std::string name() const override { return "DONUT"; }
    std::string displayName() const override { return "圆环"; }
    std::string description() const override { return "圆环（内外半径），对齐 KLayout Basic.DONUT"; }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;
        PCellParam layer;
        layer.name = "layer";
        layer.displayName = "图层";
        layer.type = PCellParamType::INT;
        layer.defaultValue = (int64_t)1;
        layer.minValue = (int64_t)0;
        layer.maxValue = (int64_t)32767;
        params.push_back(layer);

        PCellParam r1;
        r1.name = "inner_radius";
        r1.displayName = "内半径";
        r1.type = PCellParamType::DOUBLE;
        r1.defaultValue = 300.0;
        r1.minValue = 1.0;
        r1.maxValue = 1e8;
        r1.unit = "nm";
        params.push_back(r1);

        PCellParam r2;
        r2.name = "outer_radius";
        r2.displayName = "外半径";
        r2.type = PCellParamType::DOUBLE;
        r2.defaultValue = 500.0;
        r2.minValue = 2.0;
        r2.maxValue = 1e8;
        r2.unit = "nm";
        params.push_back(r2);

        PCellParam segments;
        segments.name = "segments";
        segments.displayName = "边数";
        segments.type = PCellParamType::INT;
        segments.defaultValue = pcelldetail::kDefaultCurveSegments;
        segments.minValue = (int64_t)8;
        segments.maxValue = pcelldetail::kMaxCurveSegments;
        params.push_back(segments);
        pcelldetail::appendCurveParams(params);
        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) {
            return false;
        }
        if (getDouble(params, "inner_radius") >= getDouble(params, "outer_radius")) {
            error = "内半径必须小于外半径";
            return false;
        }
        return pcelldetail::validateCurvePrecision(getDouble(params, "outer_radius"), 2 * pcelldetail::kPi,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error"), error);
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const double r1 = getDouble(params, "inner_radius");
        const double r2 = getDouble(params, "outer_radius");
        const int segments = std::max(8, pcelldetail::curveSegments(r2, 2 * pcelldetail::kPi,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error")));
        std::vector<Vec2> outerPts, innerPts, pts;
        outerPts.reserve((size_t)segments + 1);
        innerPts.reserve((size_t)segments + 1);
        pts.reserve((size_t)segments * 2 + 2);
        for (int i = 0; i <= segments; i++) {
            const double a = 2.0 * pcelldetail::kPi * (i % segments) / segments;
            outerPts.push_back({r2 * std::cos(a), r2 * std::sin(a)});
        }
        for (int i = segments; i >= 0; i--) {
            const double a = 2.0 * pcelldetail::kPi * (i % segments) / segments;
            innerPts.push_back({r1 * std::cos(a), r1 * std::sin(a)});
        }
        pcelldetail::appendQuantizedArcChain(pts, outerPts);
        pcelldetail::appendQuantizedArcChain(pts, innerPts);
        addPolygon(layout, cellId, layer, datatype, pts);
    }
};

/**
 * ARC PCell（KLayout Basic 库对齐）：弧带（起止角 + 内外半径）。
 */
class ArcPCell : public PCellDeclaration {
public:
    std::string name() const override { return "ARC"; }
    std::string displayName() const override { return "圆弧"; }
    std::string description() const override { return "弧带（起止角/内外半径），对齐 KLayout Basic.ARC"; }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;
        PCellParam layer;
        layer.name = "layer";
        layer.displayName = "图层";
        layer.type = PCellParamType::INT;
        layer.defaultValue = (int64_t)1;
        layer.minValue = (int64_t)0;
        layer.maxValue = (int64_t)32767;
        params.push_back(layer);

        PCellParam r1;
        r1.name = "inner_radius";
        r1.displayName = "内半径";
        r1.type = PCellParamType::DOUBLE;
        r1.defaultValue = 300.0;
        r1.minValue = 0.0;
        r1.maxValue = 1e8;
        r1.unit = "nm";
        params.push_back(r1);

        PCellParam r2;
        r2.name = "outer_radius";
        r2.displayName = "外半径";
        r2.type = PCellParamType::DOUBLE;
        r2.defaultValue = 500.0;
        r2.minValue = 1.0;
        r2.maxValue = 1e8;
        r2.unit = "nm";
        params.push_back(r2);

        PCellParam a1;
        a1.name = "start_angle";
        a1.displayName = "起始角";
        a1.type = PCellParamType::DOUBLE;
        a1.defaultValue = 0.0;
        a1.minValue = -360.0;
        a1.maxValue = 360.0;
        a1.unit = "deg";
        params.push_back(a1);

        PCellParam a2;
        a2.name = "end_angle";
        a2.displayName = "终止角";
        a2.type = PCellParamType::DOUBLE;
        a2.defaultValue = 90.0;
        a2.minValue = -360.0;
        a2.maxValue = 360.0;
        a2.unit = "deg";
        params.push_back(a2);

        PCellParam segments;
        segments.name = "segments";
        segments.displayName = "边数";
        segments.type = PCellParamType::INT;
        segments.defaultValue = pcelldetail::kDefaultCurveSegments;
        segments.minValue = (int64_t)4;
        segments.maxValue = pcelldetail::kMaxCurveSegments;
        params.push_back(segments);
        pcelldetail::appendCurveParams(params);
        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) {
            return false;
        }
        if (getDouble(params, "inner_radius") >= getDouble(params, "outer_radius")) {
            error = "内半径必须小于外半径";
            return false;
        }
        double sweep = getDouble(params, "end_angle") - getDouble(params, "start_angle");
        if (sweep <= 0) sweep += 360;
        if (sweep <= 0 || sweep > 360) { error = "圆弧角度跨度必须在 0–360° 之间"; return false; }
        return pcelldetail::validateCurvePrecision(getDouble(params, "outer_radius"), sweep * pcelldetail::kPi / 180,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error"), error);
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const double r1 = getDouble(params, "inner_radius");
        const double r2 = getDouble(params, "outer_radius");
        double startDeg = getDouble(params, "start_angle");
        double endDeg = getDouble(params, "end_angle");
        if (endDeg <= startDeg) {
            endDeg += 360.0;
        }
        const double start = startDeg * pcelldetail::kPi / 180.0;
        const double end = endDeg * pcelldetail::kPi / 180.0;
        const int segments = pcelldetail::curveSegments(r2, end - start,
            static_cast<int>(getInt(params, "segments")), getDouble(params, "max_error"));
        std::vector<Vec2> outerPts, innerPts, pts;
        outerPts.reserve((size_t)segments + 1);
        innerPts.reserve((size_t)segments + 1);
        pts.reserve((size_t)(segments + 1) * 2);
        for (int i = 0; i <= segments; i++) {
            const double a = start + (end - start) * i / segments;
            outerPts.push_back({r2 * std::cos(a), r2 * std::sin(a)});
        }
        for (int i = segments; i >= 0; i--) {
            const double a = start + (end - start) * i / segments;
            innerPts.push_back({r1 * std::cos(a), r1 * std::sin(a)});
        }
        pcelldetail::appendQuantizedArcChain(pts, outerPts);
        pcelldetail::appendQuantizedArcChain(pts, innerPts);
        addPolygon(layout, cellId, layer, datatype, pts);
    }
};

/**
 * MOSFET PCell: Parameterized MOS transistor.
 */
class MosfetPCell : public PCellDeclaration {
public:
    std::vector<LayoutPort> generatePorts(const PCellParamSet& params, int cellId) const override {
        const double w=getDouble(params,"w"),l=getDouble(params,"l"),sd=getDouble(params,"sd_width"),pitch=l+sd;
        const int nf=static_cast<int>(getInt(params,"nf"));
        const int dt=static_cast<int>(getInt(params,"datatype"));
        std::vector<LayoutPort> out;
        auto terminal=[&](const std::string& name,double x,double y,double width,int layer,double orientation,const std::string& role){LayoutPort p;p.id="pcell-MOSFET-"+name;p.ownerCellId=cellId;p.ownerCellKey="pcell-generated";p.name=name;p.xNm=x;p.yNm=y;p.widthNm=width;p.layerNumber=layer;p.datatype=dt;p.orientationDeg=orientation;p.portType="electrical";p.infoJson="{\"terminalRole\":\""+role+"\",\"connection\":\"individual-unstrapped\"}";p.provenance="{\"kind\":\"pcell-generated\",\"generator\":\"MOSFET\"}";out.push_back(p);};
        for(int i=0;i<nf;++i)terminal("G"+std::to_string(i),sd+i*pitch+l/2,w+100,l,static_cast<int>(getInt(params,"poly_layer")),90,"gate");
        for(int i=0;i<=nf;++i){double x=(i==0?0:sd+(i-1)*pitch+l)+sd/2;terminal("SD"+std::to_string(i),x,0,sd,static_cast<int>(getInt(params,"metal1_layer")),270,"source-drain");}
        return out;
    }
    std::string name() const override { return "MOSFET"; }
    std::string displayName() const override { return "MOS Transistor"; }
    std::string description() const override { return "Parameterized MOSFET with multi-finger support"; }
    std::string category() const override { return "Devices"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;

        PCellParam w; w.name = "w"; w.displayName = "Width"; w.type = PCellParamType::DOUBLE;
        w.defaultValue = 1000.0; w.minValue = 100.0; w.maxValue = 100000.0; w.step = 10.0; w.unit = "nm";
        params.push_back(w);

        PCellParam l; l.name = "l"; l.displayName = "Length"; l.type = PCellParamType::DOUBLE;
        l.defaultValue = 180.0; l.minValue = 28.0; l.maxValue = 10000.0; l.step = 10.0; l.unit = "nm";
        params.push_back(l);

        PCellParam nf; nf.name = "nf"; nf.displayName = "Fingers"; nf.type = PCellParamType::INT;
        nf.defaultValue = (int64_t)2; nf.minValue = (int64_t)1; nf.maxValue = (int64_t)100;
        params.push_back(nf);

        PCellParam sd; sd.name = "sd_width"; sd.displayName = "S/D Width"; sd.type = PCellParamType::DOUBLE;
        sd.defaultValue = 200.0; sd.minValue = 50.0; sd.maxValue = 5000.0; sd.step = 10.0; sd.unit = "nm";
        params.push_back(sd);

        PCellParam contSize; contSize.name = "cont_size"; contSize.displayName = "Contact Size";
        contSize.type = PCellParamType::DOUBLE; contSize.defaultValue = 80.0;
        contSize.minValue = 40.0; contSize.maxValue = 500.0; contSize.unit = "nm";
        params.push_back(contSize);

        params.push_back(pcelldetail::layerParam("poly_layer", "Poly Layer", demo_layers::kPoly));
        params.push_back(pcelldetail::layerParam("active_layer", "AA Layer", demo_layers::kActive));
        params.push_back(pcelldetail::layerParam("metal1_layer", "Metal Layer", demo_layers::kMetal1));
        params.push_back(pcelldetail::intParam("contact_layer", "Contact Layer (-1=omit)",
                                               -1, -1, 32767));
        params.push_back(pcelldetail::datatypeParam());

        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) return false;
        const int poly = (int)getInt(params, "poly_layer");
        const int active = (int)getInt(params, "active_layer");
        const int metal = (int)getInt(params, "metal1_layer");
        const int contact = (int)getInt(params, "contact_layer");
        if (poly == active || poly == metal || active == metal ||
            (contact >= 0 && (contact == poly || contact == active || contact == metal))) {
            error = "Poly/AA/Metal/Contact layers must be distinct";
            return false;
        }
        return true;
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        double w = getDouble(params, "w");
        double l = getDouble(params, "l");
        int nf = (int)getInt(params, "nf");
        double sdWidth = getDouble(params, "sd_width");
        double contSize = getDouble(params, "cont_size");

        const int POLY = (int)getInt(params, "poly_layer");
        const int ACTIVE = (int)getInt(params, "active_layer");
        const int CONTACT = (int)getInt(params, "contact_layer");
        const int METAL1 = (int)getInt(params, "metal1_layer");
        const int DATATYPE = static_cast<int>(getInt(params, "datatype"));

        double pitch = l + sdWidth;
        double totalWidth = nf * pitch + sdWidth;

        addRect(layout, cellId, ACTIVE, DATATYPE, 0, 0, totalWidth, w);

        for (int i = 0; i < nf; i++) {
            double gateX = sdWidth + i * pitch;
            addRect(layout, cellId, POLY, DATATYPE, gateX, -100, gateX + l, w + 100);
        }

        if (CONTACT >= 0) {
            double contPitch = contSize + 80;
            int contPerRow = std::max(1, (int)((w - 100) / contPitch));

            for (int i = 0; i <= nf; i++) {
                double cx = i * pitch + sdWidth / 2 - contSize / 2;
                if (i > 0) cx = sdWidth + (i - 1) * pitch + l + sdWidth / 2 - contSize / 2;

                for (int j = 0; j < contPerRow; j++) {
                    double cy = 50 + j * contPitch;
                    addRect(layout, cellId, CONTACT, DATATYPE, cx, cy, cx + contSize, cy + contSize);
                }
            }
        }

        for (int i = 0; i <= nf; i++) {
            double mx = (i == 0) ? 0 : sdWidth + (i - 1) * pitch + l;
            addRect(layout, cellId, METAL1, DATATYPE, mx, 0, mx + sdWidth, w);
        }
    }
};

/**
 * Via Stack PCell: Parameterized via array between two metal layers.
 */
class ViaStackPCell : public PCellDeclaration {
public:
    std::string name() const override { return "VIA_STACK"; }
    std::string displayName() const override { return "Via Stack"; }
    std::string category() const override { return "Connect"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;

        PCellParam rows; rows.name = "rows"; rows.displayName = "Rows";
        rows.type = PCellParamType::INT; rows.defaultValue = (int64_t)2;
        rows.minValue = (int64_t)1; rows.maxValue = (int64_t)50;
        params.push_back(rows);

        PCellParam cols; cols.name = "cols"; cols.displayName = "Columns";
        cols.type = PCellParamType::INT; cols.defaultValue = (int64_t)2;
        cols.minValue = (int64_t)1; cols.maxValue = (int64_t)50;
        params.push_back(cols);

        PCellParam size; size.name = "size"; size.displayName = "Via Size";
        size.type = PCellParamType::DOUBLE; size.defaultValue = 80.0;
        size.minValue = 40.0; size.maxValue = 500.0; size.unit = "nm";
        params.push_back(size);

        PCellParam pitch; pitch.name = "pitch"; pitch.displayName = "Pitch";
        pitch.type = PCellParamType::DOUBLE; pitch.defaultValue = 160.0;
        pitch.minValue = 80.0; pitch.maxValue = 2000.0; pitch.unit = "nm";
        params.push_back(pitch);

        PCellParam enc; enc.name = "enclosure"; enc.displayName = "Enclosure";
        enc.type = PCellParamType::DOUBLE; enc.defaultValue = 30.0;
        enc.minValue = 0.0; enc.maxValue = 500.0; enc.unit = "nm";
        params.push_back(enc);

        params.push_back(pcelldetail::layerParam("via_layer", "Via Layer", demo_layers::kVia1));
        params.push_back(pcelldetail::layerParam("lower_layer", "Lower Metal Layer", demo_layers::kMetal1));
        params.push_back(pcelldetail::layerParam("upper_layer", "Upper Metal Layer", demo_layers::kMetal2));
        params.push_back(pcelldetail::datatypeParam());

        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) return false;
        const int via = (int)getInt(params, "via_layer");
        const int lower = (int)getInt(params, "lower_layer");
        const int upper = (int)getInt(params, "upper_layer");
        if (via == lower || via == upper || lower == upper) {
            error = "Via/lower/upper layers must be distinct";
            return false;
        }
        return true;
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        int rows = (int)getInt(params, "rows");
        int cols = (int)getInt(params, "cols");
        double size = getDouble(params, "size");
        double pitch = getDouble(params, "pitch");
        double enc = getDouble(params, "enclosure");

        const int VIA1 = (int)getInt(params, "via_layer");
        const int METAL1 = (int)getInt(params, "lower_layer");
        const int METAL2 = (int)getInt(params, "upper_layer");
        const int DATATYPE = static_cast<int>(getInt(params, "datatype"));

        double totalW = cols * pitch - (pitch - size) + 2 * enc;
        double totalH = rows * pitch - (pitch - size) + 2 * enc;

        addRect(layout, cellId, METAL1, DATATYPE, 0, 0, totalW, totalH);
        addRect(layout, cellId, METAL2, DATATYPE, 0, 0, 0 + totalW, 0 + totalH);

        for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
                double vx = enc + c * pitch;
                double vy = enc + r * pitch;
                addRect(layout, cellId, VIA1, DATATYPE, vx, vy, vx + size, vy + size);
            }
        }
    }
};

/**
 * Guard Ring PCell: Parameterized guard ring (N+ or P+ ring).
 */
class GuardRingPCell : public PCellDeclaration {
public:
    std::string name() const override { return "GUARD_RING"; }
    std::string displayName() const override { return "Guard Ring"; }
    std::string category() const override { return "Analog"; }

    std::vector<PCellParam> parameters() const override {
        std::vector<PCellParam> params;

        PCellParam innerW; innerW.name = "inner_w"; innerW.displayName = "Inner Width";
        innerW.type = PCellParamType::DOUBLE; innerW.defaultValue = 5000.0;
        innerW.minValue = 1000.0; innerW.maxValue = 1000000.0; innerW.unit = "nm";
        params.push_back(innerW);

        PCellParam innerH; innerH.name = "inner_h"; innerH.displayName = "Inner Height";
        innerH.type = PCellParamType::DOUBLE; innerH.defaultValue = 5000.0;
        innerH.minValue = 1000.0; innerH.maxValue = 1000000.0; innerH.unit = "nm";
        params.push_back(innerH);

        PCellParam ringW; ringW.name = "ring_w"; ringW.displayName = "Ring Width";
        ringW.type = PCellParamType::DOUBLE; ringW.defaultValue = 400.0;
        ringW.minValue = 120.0; ringW.maxValue = 10000.0; ringW.unit = "nm";
        params.push_back(ringW);

        params.push_back(pcelldetail::layerParam("active_layer", "AA Layer", demo_layers::kActive));
        params.push_back(pcelldetail::layerParam("metal1_layer", "Metal Layer", demo_layers::kMetal1));
        params.push_back(pcelldetail::datatypeParam());

        return params;
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) return false;
        if (getInt(params, "active_layer") == getInt(params, "metal1_layer")) {
            error = "AA and metal layers must be distinct";
            return false;
        }
        return true;
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        double innerW = getDouble(params, "inner_w");
        double innerH = getDouble(params, "inner_h");
        double ringW = getDouble(params, "ring_w");

        const int ACTIVE = (int)getInt(params, "active_layer");
        const int METAL1 = (int)getInt(params, "metal1_layer");
        const int DATATYPE = static_cast<int>(getInt(params, "datatype"));

        double outerW = innerW + 2 * ringW;
        double outerH = innerH + 2 * ringW;

        addRect(layout, cellId, ACTIVE, DATATYPE, 0, innerH + ringW, outerW, outerH);
        addRect(layout, cellId, ACTIVE, DATATYPE, 0, 0, outerW, ringW);
        addRect(layout, cellId, ACTIVE, DATATYPE, 0, ringW, ringW, innerH + ringW);
        addRect(layout, cellId, ACTIVE, DATATYPE, innerW + ringW, ringW, outerW, innerH + ringW);

        addRect(layout, cellId, METAL1, DATATYPE, 0, innerH + ringW, outerW, outerH);
        addRect(layout, cellId, METAL1, DATATYPE, 0, 0, outerW, ringW);
        addRect(layout, cellId, METAL1, DATATYPE, 0, ringW, ringW, innerH + ringW);
        addRect(layout, cellId, METAL1, DATATYPE, innerW + ringW, ringW, outerW, innerH + ringW);
    }
};

// ==================== KLayout Basic 库对齐：路径族 / 无源器件 PCell ====================

using pcelldetail::intParam;
using pcelldetail::dblParam;
using pcelldetail::layerParam;
using pcelldetail::datatypeParam;

class NoPathPCell : public PCellDeclaration {
public:
    std::string name() const override { return "NOPATH"; }
    std::string displayName() const override { return "变宽路径"; }
    std::string description() const override {
        return "两端宽度不同的水平路径（锥削），对齐 KLayout Basic.NOPATH";
    }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        return { layerParam(),
                 dblParam("length", "长度", 1000, 1, 1e8),
                 dblParam("width_start", "起始宽度", 200, 1, 1e8),
                 dblParam("width_end", "末端宽度", 100, 1, 1e8),
                 datatypeParam() };
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const double len = getDouble(params, "length");
        const double w1 = getDouble(params, "width_start");
        const double w2 = getDouble(params, "width_end");
        addPolygon(layout, cellId, layer, datatype,
                   {{0, -w1 / 2}, {len, -w2 / 2}, {len, w2 / 2}, {0, w1 / 2}});
    }
};

class NPathPCell : public PCellDeclaration {
public:
    std::string name() const override { return "NPATH"; }
    std::string displayName() const override { return "多轨路径"; }
    std::string description() const override {
        return "多条等宽平行轨道（总线），整叠居中，对齐 KLayout Basic.NPATH";
    }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        return { layerParam(),
                 intParam("tracks", "轨道数", 3, 1, 64),
                 dblParam("length", "长度", 1000, 1, 1e8),
                 dblParam("width", "轨宽", 200, 1, 1e8),
                 dblParam("gap", "轨间距", 200, 1, 1e8),
                 datatypeParam() };
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const int64_t tracks = getInt(params, "tracks");
        const double len = getDouble(params, "length");
        const double w = getDouble(params, "width");
        const double gap = getDouble(params, "gap");
        const double stack = tracks * w + (tracks - 1) * gap;
        for (int64_t i = 0; i < tracks; i++) {
            const double y0 = -stack / 2 + i * (w + gap);
            addRect(layout, cellId, layer, datatype, 0, y0, len, y0 + w);
        }
    }
};

class MeanderPCell : public PCellDeclaration {
public:
    std::string name() const override { return "MEANDER"; }
    std::string displayName() const override { return "蛇形走线"; }
    std::string description() const override {
        return "矩形蛇形走线（均衡电阻/蛇形屏蔽），对齐 KLayout Basic.MEANDER";
    }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        return { layerParam(),
                 intParam("runs", "段数", 5, 2, 128),
                 dblParam("length", "单段长度", 2000, 1, 1e8),
                 dblParam("pitch", "行距", 500, 1, 1e8),
                 dblParam("width", "线宽", 200, 1, 1e7),
                 datatypeParam() };
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const int64_t runs = getInt(params, "runs");
        const double len = getDouble(params, "length");
        const double pitch = getDouble(params, "pitch");
        const double w = getDouble(params, "width");
        std::vector<Vec2> center;
        center.reserve((size_t)runs * 2);
        for (int64_t i = 0; i < runs; i++) {
            const double y = i * pitch;
            if (i % 2 == 0) {
                center.push_back({0, y});
                center.push_back({len, y});
            } else {
                center.push_back({len, y});
                center.push_back({0, y});
            }
        }
        const std::vector<Vec2> outline = Triangulator::pathOutline(center, w, 0);
        if (!outline.empty()) {
            addPolygon(layout, cellId, layer, datatype, outline);
        }
    }
};

class StarPCell : public PCellDeclaration {
public:
    std::string name() const override { return "STAR"; }
    std::string displayName() const override { return "星形辐射"; }
    std::string description() const override {
        return "n 条等分角度辐射臂，对齐 KLayout Basic.STAR";
    }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        return { layerParam(),
                 intParam("arms", "臂数", 6, 3, 64),
                 dblParam("inner_radius", "内半径", 200, 0, 1e8),
                 dblParam("outer_radius", "外半径", 1000, 1, 1e8),
                 dblParam("arm_width", "臂宽", 100, 1, 1e7),
                 dblParam("start_angle", "起始角", 0, -360, 360, 1.0, "deg"),
                 datatypeParam() };
    }

    bool validateParams(const PCellParamSet& params, std::string& error) const override {
        if (!PCellDeclaration::validateParams(params, error)) {
            return false;
        }
        if (getDouble(params, "inner_radius") >= getDouble(params, "outer_radius")) {
            error = "inner_radius 必须小于 outer_radius";
            return false;
        }
        return true;
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const int64_t arms = getInt(params, "arms");
        const double r1 = getDouble(params, "inner_radius");
        const double r2 = getDouble(params, "outer_radius");
        const double w = getDouble(params, "arm_width");
        const double a0 = getDouble(params, "start_angle") * pcelldetail::kPi / 180.0;
        for (int64_t i = 0; i < arms; i++) {
            const double a = a0 + 2.0 * pcelldetail::kPi * i / arms;
            const double cx = std::cos(a), cy = std::sin(a);
            const std::vector<Vec2> outline =
                Triangulator::pathOutline({{r1 * cx, r1 * cy}, {r2 * cx, r2 * cy}}, w, 0);
            if (!outline.empty()) {
                addPolygon(layout, cellId, layer, datatype, pcelldetail::sanitizeQuantizedClosedRing(outline));
            }
        }
    }
};

class CombPCell : public PCellDeclaration {
public:
    std::string name() const override { return "COMB"; }
    std::string displayName() const override { return "叉指结构"; }
    std::string description() const override {
        return "两条母线与交替叉指（MIM 电容/传感电极），对齐 KLayout Basic.COMB";
    }
    std::string category() const override { return "Basic"; }

    std::vector<PCellParam> parameters() const override {
        return { layerParam(),
                 intParam("fingers", "叉指数", 6, 2, 256),
                 dblParam("finger_width", "指宽", 200, 1, 1e7),
                 dblParam("finger_gap", "指间隙", 200, 1, 1e7),
                 dblParam("finger_length", "指长", 1000, 1, 1e8),
                 dblParam("spine_width", "母线宽", 300, 1, 1e7),
                 datatypeParam() };
    }

    static double rightSpineX(const PCellParamSet& p) {
        return getDouble(p, "spine_width") + 2.0 * getDouble(p, "finger_length") +
               getDouble(p, "finger_gap");
    }

    void generate(const PCellParamSet& params, Layout& layout, int cellId) const override {
        const int layer = (int)getInt(params, "layer");
        const int datatype = static_cast<int>(getInt(params, "datatype"));
        const int64_t fingers = getInt(params, "fingers");
        const double fw = getDouble(params, "finger_width");
        const double fg = getDouble(params, "finger_gap");
        const double fl = getDouble(params, "finger_length");
        const double sw = getDouble(params, "spine_width");
        const double height = fingers * fw + (fingers - 1) * fg;
        const double rx = rightSpineX(params);

        addRect(layout, cellId, layer, datatype, 0, 0, sw, height);
        addRect(layout, cellId, layer, datatype, rx - sw, 0, rx, height);
        for (int64_t i = 0; i < fingers; i++) {
            const double y0 = i * (fw + fg);
            if (i % 2 == 0) {
                addRect(layout, cellId, layer, datatype, sw, y0, sw + fl, y0 + fw);
            } else {
                addRect(layout, cellId, layer, datatype, rx - sw - fl, y0, rx - sw, y0 + fw);
            }
        }
    }
};

// ==================== PCell Library ====================

/**
 * PCellLibrary: Thread-safe registry of PCell declarations.
 */
class PCellLibrary {
public:
    static PCellLibrary& instance() {
        static std::once_flag initFlag;
        static PCellLibrary* libPtr = nullptr;
        std::call_once(initFlag, []() {
            static PCellLibrary lib;
            libPtr = &lib;
        });
        return *libPtr;
    }

    void registerPCell(std::shared_ptr<PCellDeclaration> decl) {
        if (!decl) return;
        std::lock_guard<std::mutex> lock(mutex_);
        pcells_[decl->name()] = std::move(decl);
    }

    void unregisterPCell(const std::string& name) {
        std::lock_guard<std::mutex> lock(mutex_);
        pcells_.erase(name);
    }

    std::shared_ptr<PCellDeclaration> find(const std::string& name) const {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = pcells_.find(name);
        return (it != pcells_.end()) ? it->second : nullptr;
    }

    std::vector<std::string> listNames() const {
        std::vector<std::string> names;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            names.reserve(pcells_.size());
            for (const auto& [name, _] : pcells_) {
                names.push_back(name);
            }
        }
        std::sort(names.begin(), names.end());
        return names;
    }

    std::vector<std::shared_ptr<PCellDeclaration>> listByCategory(const std::string& category) const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<std::shared_ptr<PCellDeclaration>> result;
        for (const auto& [_, decl] : pcells_) {
            if (decl->category() == category) {
                result.push_back(decl);
            }
        }
        return result;
    }

    int instantiate(const std::string& pcellName, const PCellParamSet& params,
                   Layout& layout, const std::string& cellName = "") {
        auto decl = find(pcellName);
        if (!decl) return -1;

        std::string name = cellName.empty() ?
            (pcellName + "_" + std::to_string(layout.cells.size())) : cellName;

        int cellId = layout.addCell(name);
        Cell* cell = layout.findCell(cellId);
        if (cell) {
            cell->isPCell = true;
            cell->pcellName = pcellName;
            for (const auto& [key, val] : params) {
                std::string valStr;
                if (auto* d = std::get_if<double>(&val)) valStr = std::to_string(*d);
                else if (auto* i = std::get_if<int64_t>(&val)) valStr = std::to_string(*i);
                else if (auto* s = std::get_if<std::string>(&val)) valStr = *s;
                else if (auto* b = std::get_if<bool>(&val)) valStr = *b ? "true" : "false";
                cell->pcellParams.push_back({key, valStr});
            }
        }

        decl->generate(params, layout, cellId);
        return cellId;
    }

    bool regenerate(int cellId, const PCellParamSet& newParams, Layout& layout) {
        Cell* cell = layout.findCell(cellId);
        if (!cell || !cell->isPCell) return false;

        auto decl = find(cell->pcellName);
        if (!decl) return false;

        std::vector<int64_t> toRemove;
        for (const auto& shape : layout.shapes) {
            if (shape.ownerCellId == cellId) {
                toRemove.push_back(shape.id);
            }
        }
        for (int64_t id : toRemove) {
            layout.removeShape(id);
        }

        decl->generate(newParams, layout, cellId);
        return true;
    }

    void registerBuiltins() {
        std::lock_guard<std::mutex> lock(mutex_);
        registerBuiltinsUnlocked();
    }

private:
    PCellLibrary() { registerBuiltinsUnlocked(); }

    void registerBuiltinsUnlocked() {
        pcells_["CIRCLE"] = std::make_shared<CirclePCell>();
        pcells_["ELLIPSE"] = std::make_shared<EllipsePCell>();
        pcells_["DONUT"] = std::make_shared<DonutPCell>();
        pcells_["ARC"] = std::make_shared<ArcPCell>();
        pcells_["NOPATH"] = std::make_shared<NoPathPCell>();
        pcells_["NPATH"] = std::make_shared<NPathPCell>();
        pcells_["MEANDER"] = std::make_shared<MeanderPCell>();
        pcells_["STAR"] = std::make_shared<StarPCell>();
        pcells_["COMB"] = std::make_shared<CombPCell>();
        pcells_["MOSFET"] = std::make_shared<MosfetPCell>();
        pcells_["VIA_STACK"] = std::make_shared<ViaStackPCell>();
        pcells_["GUARD_RING"] = std::make_shared<GuardRingPCell>();
    }

    mutable std::mutex mutex_;
    std::unordered_map<std::string, std::shared_ptr<PCellDeclaration>> pcells_;
};

} // namespace hongtu

#endif // HONGTU_PCELL_FRAMEWORK_H
