/**
 * HongTu EDA - CIF / DXF 读取器（对齐现行 GdsiiParseResult 数据模型）
 *
 * CIF (Caltech Intermediate Form)：
 * - DS/DF 符号定义（含 a/b 缩放、`9 name;` 符号命名扩展）、C 调用
 *   （T/M/R 变换组合→分解为平移/旋转/镜像）、L 图层、B 盒（含方向向量
 *   旋转）、P 多边形、W 线（路径）、R 圆（32 边形近似）、括号注释（可嵌套）、
 *   数字用户命令跳过
 * - 单位：厘微米（0.01µm）→ nm ×10；图层名按出现顺序映射编号 1..N
 *
 * DXF (AutoCAD R12 ASCII 子集)：
 * - BLOCKS（→ Cell）与 ENTITIES（→ 隐式 MODEL 顶层）
 * - LINE / LWPOLYLINE / POLYLINE+VERTEX（闭合→多边形，开放→路径）/
 *   CIRCLE（32 边形）/ ARC（折线近似）/ TEXT / INSERT（→ 实例，含
 *   缩放/旋转）
 * - 单位：默认 1 DXF 单位 = 1µm → nm ×1000；图层名按出现顺序映射编号
 *
 * 简化声明（诚实边界）：
 * - CIF：不支持 DD/删除命令；箭头方向仅取整角度到最近 1°
 * - DXF：R2000+ 二进制/实体子集外的记录跳过；BULGE 弓形段按圆弧采样（LWPOLYLINE 与 POLYLINE+VERTEX 同一条展开路径）
 * - LEF/DEF 明确 defer（抽象视图/布线数据与查看器主链无关）
 *
 * host 冒烟：tools/format_readers_smoke.cpp
 * This file is part of HongTu, licensed under GPLv3.
 */
#ifndef HONGTU_FORMAT_READERS_H
#define HONGTU_FORMAT_READERS_H

#include "gdsii_reader.h"
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

namespace hongtu {

namespace formatdetail {

constexpr double kPi = 3.14159265358979323846;
constexpr int kCircleSegments = 32;

/**
 * DXF LWPOLYLINE/POLYLINE 的弓形（bulge）段 → 圆弧采样点。
 *
 * bulge = tan(θ/4)，θ 为包含角，正号逆时针。旧实现把带 bulge 的段当直线连，
 * 于是 CAD 导出的圆角/圆弧被压成折弦（几何失真，不是精度问题）。
 *
 * 做法：由 bulge 得弓高点 q = 弦中点 + bulge·(弦长/2)·左法向；
 * 外接圆心即 (a,q,b) 三点外心，扫掠角 θ = 4·atan(bulge)（有界，|bulge|→∞ 时 →2π）。
 * 只输出中间点，两端顶点由调用方按序补齐。
 */
template <typename PointT>
inline void appendBulgeArc(std::vector<PointT>& out, double ax, double ay,
                            double bx, double by, double bulge, int segments = 16) {
    if (!std::isfinite(bulge) || std::fabs(bulge) < 1e-9) {
        return;                     // 无弓形 = 直线段
    }
    const double dx = bx - ax;
    const double dy = by - ay;
    if (dx * dx + dy * dy <= 0.0) {
        return;                     // 重合顶点
    }
    const double mx = (ax + bx) / 2.0;
    const double my = (ay + by) / 2.0;
    const double qx = mx - bulge * dy / 2.0;
    const double qy = my + bulge * dx / 2.0;

    const double e1x = bx - ax, e1y = by - ay;
    const double e2x = qx - ax, e2y = qy - ay;
    const double det = 2.0 * (e1x * e2y - e1y * e2x);
    if (std::fabs(det) < 1e-15) {
        return;                     // 三点近共线：退化，保守按直线处理
    }
    const double c1 = e1x * e1x + e1y * e1y;
    const double c2 = e2x * e2x + e2y * e2y;
    // 外心相对 a 的偏移（标准三点外心式；写错一项会让圆心跑到弦外）
    const double ux = (c1 * e2y - c2 * e1y) / det;
    const double uy = (e1x * c2 - e2x * c1) / det;
    const double r = std::sqrt(ux * ux + uy * uy);
    if (!(r > 0.0) || !std::isfinite(r)) {
        return;
    }
    const double cx = ax + ux;
    const double cy = ay + uy;
    const double sa = std::atan2(ay - cy, ax - cx);
    const double sweep = 4.0 * std::atan(bulge);
    const int n = std::max(2, std::min(256, segments));
    for (int k = 1; k < n; k++) {
        const double ang = sa + sweep * static_cast<double>(k) / static_cast<double>(n);
        const double px = cx + r * std::cos(ang);
        const double py = cy + r * std::sin(ang);
        if (std::isfinite(px) && std::isfinite(py)) {
            out.push_back({px, py});
        }
    }
}

constexpr size_t kMaxShapes = 4u * 1000 * 1000;
constexpr std::streamsize kMaxTextFileBytes = 512ll * 1024 * 1024;

inline void appendCirclePolygon(std::vector<GdsPoint>& pts, double cx, double cy, double r) {
    for (int i = 0; i < kCircleSegments; i++) {
        const double a = 2.0 * kPi * i / kCircleSegments;
        pts.push_back({cx + r * std::cos(a), cy + r * std::sin(a)});
    }
}

/** 图层名 → 编号：按首次出现顺序 1..N（CIF/DXF 无通用数字映射约定） */
class LayerNameMap {
public:
    int idFor(const std::string& name) {
        auto it = map_.find(name);
        if (it != map_.end()) {
            return it->second;
        }
        const int id = static_cast<int>(map_.size()) + 1;
        map_[name] = id;
        return id;
    }

private:
    std::map<std::string, int> map_;
};

} // namespace formatdetail

// ==================== CIF Reader ====================

class CifReader {
public:
    GdsiiParseResult parse(const std::string& filePath, const NativeJobControl* control = nullptr) {
        control_ = control;
        if (control_) control_->report("parsing");
        GdsiiParseResult result;
        result.filePath = filePath;
        result.libName = "CIF_IMPORT";
        result.userUnits = 0.001;
        result.physicalUnits = 1e-9; // 输出坐标统一 nm

        std::ifstream file(filePath, std::ios::binary | std::ios::ate);
        if (!file.is_open()) {
            result.errorMessage = "无法打开 CIF 文件: " + filePath;
            return result;
        }
        const std::streamsize size = file.tellg();
        if (size < 0 || size > formatdetail::kMaxTextFileBytes) {
            result.errorMessage = "CIF 文本文件长度无效或超过 512 MiB 读取预算";
            return result;
        }
        file.seekg(0);
        std::string text(static_cast<size_t>(size), '\0');
        for (std::streamsize offset = 0; offset < size;) {
            if (control_) control_->report("parsing", static_cast<uint64_t>(offset), static_cast<uint64_t>(size));
            const auto count = std::min<std::streamsize>(1024 * 1024, size - offset);
            if (!file.read(&text[static_cast<size_t>(offset)], count)) {
                result.errorMessage = "读取 CIF 文件失败";
                return result;
            }
            offset += count;
        }
        result.fileSize = static_cast<int64_t>(size);

        try {
            parseText(std::move(text), result);
        } catch (const NativeJobCancelled&) { throw;
        } catch (const std::exception& e) {
            result.success = false;
            result.errorMessage = std::string("CIF 解析失败: ") + e.what();
            return result;
        }
        result.success = true;
        if (control_) control_->check();
        ResolveHierarchyMetadata(result);
        return result;
    }

private:
    struct Transform2 {
        // 2x2 线性 + 平移（CIF 变换按命令序列左乘组合）
        double a = 1, b = 0, c = 0, d = 1, tx = 0, ty = 0;

        void applyTranslate(double x, double y) { tx += x; ty += y; }
        void applyMirrorX() { a = -a; b = -b; tx = -tx; }   // M X: x → -x
        void applyMirrorY() { c = -c; d = -d; ty = -ty; }   // M Y: y → -y
        void applyRotate(double dirX, double dirY) {
            const double len = std::sqrt(dirX * dirX + dirY * dirY);
            if (len <= 0) {
                return;
            }
            const double ca = dirX / len;
            const double sa = dirY / len;
            const double na = ca * a - sa * c;
            const double nb = ca * b - sa * d;
            const double nc = sa * a + ca * c;
            const double nd = sa * b + ca * d;
            const double ntx = ca * tx - sa * ty;
            const double nty = sa * tx + ca * ty;
            a = na; b = nb; c = nc; d = nd; tx = ntx; ty = nty;
        }
    };

    size_t pos_ = 0;
    std::string text_;
    const NativeJobControl* control_ = nullptr;

    bool eof() const {
        if (control_ && (pos_ & 4095) == 0) control_->check();
        return pos_ >= text_.size();
    }
    char peek() const { return eof() ? '\0' : text_[pos_]; }

    void skipBlanksAndComments() {
        while (!eof()) {
            const char ch = text_[pos_];
            if (ch == '(') {
                int depth = 0;
                while (!eof()) {
                    const char c2 = text_[pos_++];
                    if (c2 == '(') depth++;
                    else if (c2 == ')') {
                        depth--;
                        if (depth == 0) break;
                    }
                }
                continue;
            }
            if (std::isspace(static_cast<unsigned char>(ch)) || ch == ',') {
                pos_++;
                continue;
            }
            break;
        }
    }

    /** CIF 整数：分隔符宽松（任意非数字非负号跳过到数字） */
    long long readInt() {
        skipBlanksAndComments();
        bool neg = false;
        while (!eof() && !std::isdigit(static_cast<unsigned char>(peek())) && peek() != '-') {
            if (peek() == ';') {
                throw std::runtime_error("整数缺失（遇到 ;）");
            }
            pos_++;
        }
        if (peek() == '-') {
            neg = true;
            pos_++;
        }
        long long v = 0;
        bool any = false;
        while (!eof() && std::isdigit(static_cast<unsigned char>(peek()))) {
            v = v * 10 + (text_[pos_++] - '0');
            any = true;
        }
        if (!any) {
            throw std::runtime_error("整数缺失");
        }
        return neg ? -v : v;
    }

    bool nextIsNumber() {
        skipBlanksAndComments();
        return !eof() && (std::isdigit(static_cast<unsigned char>(peek())) || peek() == '-');
    }

    void skipToSemicolon() {
        while (!eof() && text_[pos_] != ';') {
            if (text_[pos_] == '(') {
                skipBlanksAndComments();
                continue;
            }
            pos_++;
        }
        if (!eof()) {
            pos_++;
        }
    }

    void expectSemicolon() { skipToSemicolon(); }

    std::string readName() {
        skipBlanksAndComments();
        std::string s;
        while (!eof() && !std::isspace(static_cast<unsigned char>(peek())) && peek() != ';') {
            s += text_[pos_++];
        }
        return s;
    }

    void parseText(std::string text, GdsiiParseResult& result) {
        text_ = std::move(text);
        pos_ = 0;

        formatdetail::LayerNameMap layerMap;
        int nextShapeId = 1;

        // 隐式顶层 cell 0；符号从 1 开始
        CellInfo topCell;
        topCell.name = "CIF_TOP";
        result.cells.push_back(topCell);

        std::map<long long, int> symbolIdToCell; // CIF DS id → cellId
        int currentCell = 0;      // 0 = 顶层
        bool inSymbol = false;
        double scaleNum = 1.0;    // DS a/b
        double scaleDen = 1.0;
        int currentLayer = 1;
        bool topHasContent = false;

        // 厘微米 → nm
        auto toNm = [&](long long v) {
            return static_cast<double>(v) * 10.0 * scaleNum / scaleDen;
        };
        auto addLayerCount = [&](int layer) {
            for (auto& l : result.allLayers) {
                if (l.layerNumber == layer && l.datatype == 0) {
                    l.elementCount++;
                    return;
                }
            }
            result.allLayers.push_back({layer, 0, 1});
        };
        auto emit = [&](LayoutShape&& s) {
            if (result.shapes.size() >= formatdetail::kMaxShapes) {
                throw std::runtime_error("图形数超过上限");
            }
            s.id = nextShapeId++;
            s.ownerCellId = currentCell;
            result.cells[static_cast<size_t>(currentCell)].elementCount++;
            result.totalElements++;
            if (s.type != "instance") {
                addLayerCount(s.layerNumber);
            }
            if (currentCell == 0) {
                topHasContent = true;
            }
            result.shapes.push_back(std::move(s));
        };

        while (true) {
            skipBlanksAndComments();
            if (eof()) {
                break;
            }
            const char cmd = text_[pos_++];
            if (cmd == ';') {
                continue;
            }
            const char upper = static_cast<char>(std::toupper(static_cast<unsigned char>(cmd)));
            switch (upper) {
                case 'D': { // DS / DF / DD
                    skipBlanksAndComments();
                    const char sub = static_cast<char>(std::toupper(static_cast<unsigned char>(peek())));
                    pos_++;
                    if (sub == 'S') {
                        const long long id = readInt();
                        double a = 1;
                        double b = 1;
                        if (nextIsNumber()) {
                            a = static_cast<double>(readInt());
                            if (nextIsNumber()) {
                                b = static_cast<double>(readInt());
                            }
                        }
                        expectSemicolon();
                        CellInfo cell;
                        cell.name = "S" + std::to_string(id);
                        result.cells.push_back(cell);
                        currentCell = static_cast<int>(result.cells.size()) - 1;
                        symbolIdToCell[id] = currentCell;
                        inSymbol = true;
                        scaleNum = a > 0 ? a : 1;
                        scaleDen = b > 0 ? b : 1;
                    } else if (sub == 'F') {
                        expectSemicolon();
                        currentCell = 0;
                        inSymbol = false;
                        scaleNum = 1;
                        scaleDen = 1;
                    } else { // DD 等
                        expectSemicolon();
                    }
                    break;
                }
                case 'L': {
                    const std::string name = readName();
                    expectSemicolon();
                    currentLayer = layerMap.idFor(name.empty() ? "L" : name);
                    break;
                }
                case 'B': { // B length width cx cy [dirX dirY]
                    const double len = toNm(readInt());
                    const double wid = toNm(readInt());
                    const double cx = toNm(readInt());
                    const double cy = toNm(readInt());
                    double dirX = 1;
                    double dirY = 0;
                    if (nextIsNumber()) {
                        dirX = static_cast<double>(readInt());
                        if (nextIsNumber()) {
                            dirY = static_cast<double>(readInt());
                        }
                    }
                    expectSemicolon();
                    LayoutShape s;
                    s.layerNumber = currentLayer;
                    s.datatype = 0;
                    if (dirY == 0 && dirX >= 0) {
                        s.type = "rect";
                        s.points.push_back({cx - len / 2, cy - wid / 2});
                        s.points.push_back({cx + len / 2, cy + wid / 2});
                    } else {
                        // 旋转盒 → 多边形
                        const double dl = std::sqrt(dirX * dirX + dirY * dirY);
                        const double ca = dl > 0 ? dirX / dl : 1;
                        const double sa = dl > 0 ? dirY / dl : 0;
                        const double hx = len / 2;
                        const double hy = wid / 2;
                        const double cornersX[4] = {-hx, hx, hx, -hx};
                        const double cornersY[4] = {-hy, -hy, hy, hy};
                        s.type = "polygon";
                        for (int i = 0; i < 4; i++) {
                            s.points.push_back({cx + cornersX[i] * ca - cornersY[i] * sa,
                                                cy + cornersX[i] * sa + cornersY[i] * ca});
                        }
                    }
                    emit(std::move(s));
                    break;
                }
                case 'P': { // P x y ...
                    LayoutShape s;
                    s.type = "polygon";
                    s.layerNumber = currentLayer;
                    s.datatype = 0;
                    while (nextIsNumber()) {
                        const double x = toNm(readInt());
                        const double y = toNm(readInt());
                        s.points.push_back({x, y});
                    }
                    expectSemicolon();
                    if (s.points.size() >= 3) {
                        emit(std::move(s));
                    }
                    break;
                }
                case 'W': { // W width x y ...
                    LayoutShape s;
                    s.type = "path";
                    s.layerNumber = currentLayer;
                    s.datatype = 0;
                    s.pathWidth = std::max(1.0, toNm(readInt()));
                    while (nextIsNumber()) {
                        const double x = toNm(readInt());
                        const double y = toNm(readInt());
                        s.points.push_back({x, y});
                    }
                    expectSemicolon();
                    if (s.points.size() >= 2) {
                        emit(std::move(s));
                    }
                    break;
                }
                case 'R': { // R diameter x y（圆）
                    const double dia = toNm(readInt());
                    const double cx = toNm(readInt());
                    const double cy = toNm(readInt());
                    expectSemicolon();
                    LayoutShape s;
                    s.type = "polygon";
                    s.layerNumber = currentLayer;
                    s.datatype = 0;
                    formatdetail::appendCirclePolygon(s.points, cx, cy, dia / 2);
                    emit(std::move(s));
                    break;
                }
                case 'C': { // C id [T x y | M X | M Y | R a b]...
                    const long long id = readInt();
                    Transform2 t;
                    while (true) {
                        skipBlanksAndComments();
                        if (eof() || peek() == ';') {
                            break;
                        }
                        const char tc = static_cast<char>(std::toupper(static_cast<unsigned char>(text_[pos_++])));
                        if (tc == 'T') {
                            const double x = toNm(readInt());
                            const double y = toNm(readInt());
                            t.applyTranslate(x, y);
                        } else if (tc == 'M') {
                            skipBlanksAndComments();
                            const char axis = static_cast<char>(std::toupper(static_cast<unsigned char>(text_[pos_++])));
                            if (axis == 'X') {
                                t.applyMirrorX();
                            } else {
                                t.applyMirrorY();
                            }
                        } else if (tc == 'R') {
                            const double dx = static_cast<double>(readInt());
                            const double dy = static_cast<double>(readInt());
                            t.applyRotate(dx, dy);
                        } else {
                            break;
                        }
                    }
                    expectSemicolon();

                    // 分解为实例字段：det<0 → 关于 X 轴镜像 + 旋转
                    // 实例语义（与 scene_graph InstanceTransform::toMatrix 同序）为
                    //   m·R(θ)·Fx = [m·cosθ, m·sinθ; m·sinθ, -m·cosθ]（镜像分支）
                    //   m·R(θ)    = [m·cosθ, -m·sinθ; m·sinθ, m·cosθ]（纯旋转分支）
                    // 两分支取角度的分量不同：镜像看 b（=m·sinθ），纯旋转看 c（=m·sinθ）。
                    LayoutShape s;
                    s.type = "instance";
                    s.layerNumber = 0;
                    s.datatype = 0;
                    s.cellName = "S" + std::to_string(id);
                    const double det = t.a * t.d - t.b * t.c;
                    s.mirror = det < 0 ? 1 : 0;
                    const double angle = std::atan2(s.mirror != 0 ? t.b : t.c, t.a);
                    s.rotation = std::round(angle * 180.0 / formatdetail::kPi);
                    if (s.rotation < 0) {
                        s.rotation += 360;
                    }
                    s.magnification = std::sqrt(std::fabs(det));
                    if (s.magnification <= 0) {
                        s.magnification = 1.0;
                    }
                    s.points.push_back({t.tx, t.ty});
                    emit(std::move(s));
                    break;
                }
                case 'E':
                    skipToSemicolon();
                    goto done;
                case '9': { // 符号命名扩展：9 name;
                    const std::string name = readName();
                    expectSemicolon();
                    if (inSymbol && !name.empty()) {
                        result.cells[static_cast<size_t>(currentCell)].name = name;
                        // 同步已发射实例引用名（按旧名匹配的后续在 Resolve 时按新名做不到，
                        // 因此命名命令要求出现在任何 C 调用引用之前；符合 KLayout 输出习惯）
                    }
                    break;
                }
                default:
                    if (std::isdigit(static_cast<unsigned char>(cmd))) {
                        skipToSemicolon(); // 其他数字用户命令
                    } else {
                        skipToSemicolon(); // 未知命令，容错跳过
                    }
                    break;
            }
        }
    done:
        // 实例引用名解析：C id 引用的符号若被 `9 name` 改名，按 id 映射修正
        for (auto& shape : result.shapes) {
            if (shape.type != "instance") {
                continue;
            }
            if (shape.cellName.size() > 1 && shape.cellName[0] == 'S') {
                try {
                    const long long id = std::stoll(shape.cellName.substr(1));
                    auto it = symbolIdToCell.find(id);
                    if (it != symbolIdToCell.end()) {
                        shape.cellName = result.cells[static_cast<size_t>(it->second)].name;
                        shape.cellId = it->second;
                    }
                } catch (...) {
                    // 名称不是 S<id> 形式，保留
                }
            }
        }
        // 顶层无内容且存在符号 → 移除占位顶层？保留（Resolve 会选无引用符号为主顶层，
        // 空 CIF_TOP elementCount=0 不干扰 primary 选择——除非全部符号都被引用。
        // 为避免空顶层成为唯一候选的歧义：顶层无内容时把它标记为已引用不可行，
        // 简化：顶层无内容时仍保留（primaryTop 按 elementCount 择优）。
        (void)topHasContent;

        result.cellCount = static_cast<int>(result.cells.size());
        result.layerCount = static_cast<int>(result.allLayers.size());
        result.unitDescription = "CIF centi-micron → nm (x10)";
        for (auto& cell : result.cells) {
            cell.layers = result.allLayers;
        }
    }
};

// ==================== DXF Reader ====================

class DxfReader {
public:
    /** scale：DXF 单位 → nm（默认 1 单位 = 1µm） */
    explicit DxfReader(double scale = 1000.0) : scale_(scale) {}

    GdsiiParseResult parse(const std::string& filePath, const NativeJobControl* control = nullptr) {
        control_ = control;
        if (control_) control_->report("parsing");
        GdsiiParseResult result;
        result.filePath = filePath;
        result.libName = "DXF_IMPORT";
        result.userUnits = 0.001;
        result.physicalUnits = 1e-9;

        std::ifstream file(filePath, std::ios::binary);
        if (!file.is_open()) {
            result.errorMessage = "无法打开 DXF 文件: " + filePath;
            return result;
        }
        file.seekg(0, std::ios::end);
        const auto bytes = file.tellg();
        if (bytes < 0 || bytes > formatdetail::kMaxTextFileBytes) {
            result.errorMessage = "DXF 文本文件长度无效或超过 512 MiB 读取预算";
            return result;
        }
        file.seekg(0);

        try {
            parseStream(file, result);
        } catch (const NativeJobCancelled&) { throw;
        } catch (const std::exception& e) {
            result.success = false;
            result.errorMessage = std::string("DXF 解析失败: ") + e.what();
            return result;
        }

        file.clear();
        file.seekg(0, std::ios::end);
        result.fileSize = static_cast<int64_t>(file.tellg());
        result.success = true;
        if (control_) control_->check();
        ResolveHierarchyMetadata(result);
        return result;
    }

private:
    double scale_;
    const NativeJobControl* control_ = nullptr;

    struct Pair {
        int code = -1;
        std::string value;
        bool ok = false;
    };

    static std::string trim(const std::string& s) {
        const size_t b = s.find_first_not_of(" \t\r\n");
        if (b == std::string::npos) {
            return "";
        }
        const size_t e = s.find_last_not_of(" \t\r\n");
        return s.substr(b, e - b + 1);
    }

    bool readLine(std::istream& in, std::string& line) {
        char c = 0;
        while (in.get(c)) {
            if (control_ && (line.size() & 4095) == 0) control_->check();
            if (c == '\n') return true;
            if (line.size() >= 1024 * 1024) throw std::runtime_error("DXF 单行超过 1 MiB 读取预算");
            line.push_back(c);
        }
        return !line.empty();
    }

    Pair readPair(std::istream& in) {
        if (control_) control_->check();
        Pair p;
        std::string codeLine;
        if (!readLine(in, codeLine)) {
            return p;
        }
        std::string valueLine;
        if (!readLine(in, valueLine)) {
            return p;
        }
        try {
            p.code = std::stoi(trim(codeLine));
        } catch (...) {
            p.code = -1;
        }
        p.value = trim(valueLine);
        p.ok = true;
        return p;
    }

    void parseStream(std::istream& in, GdsiiParseResult& result) {
        formatdetail::LayerNameMap layerMap;
        int nextShapeId = 1;

        CellInfo model;
        model.name = "MODEL";
        result.cells.push_back(model);
        std::map<std::string, int> blockCells;

        int currentCell = 0;

        auto addLayerCount = [&](int layer) {
            for (auto& l : result.allLayers) {
                if (l.layerNumber == layer && l.datatype == 0) {
                    l.elementCount++;
                    return;
                }
            }
            result.allLayers.push_back({layer, 0, 1});
        };
        auto emit = [&](LayoutShape&& s) {
            if (result.shapes.size() >= formatdetail::kMaxShapes) {
                throw std::runtime_error("图形数超过上限");
            }
            s.id = nextShapeId++;
            s.ownerCellId = currentCell;
            result.cells[static_cast<size_t>(currentCell)].elementCount++;
            result.totalElements++;
            if (s.type != "instance") {
                addLayerCount(s.layerNumber);
            }
            result.shapes.push_back(std::move(s));
        };

        // 实体解析：进入时已读到 `0 <EntityName>`；返回吃掉的下一个 pair（供上层继续）
        // 统一模式：循环读 pair 收集本实体字段，遇 code 0 返回
        auto parseEntity = [&](const std::string& entity, Pair& carry) {
            std::vector<double> xs;
            std::vector<double> ys;
            std::vector<double> bulges;   // 与顶点平行：第 i 个 bulge 描述 i→i+1 段
            double x0 = 0, y0 = 0, x1 = 0, y1 = 0;
            double cx = 0, cy = 0, radius = 0;
            double a0 = 0, a1 = 0;
            double constWidth = 0;
            double rotation = 0;
            double scaleX = 1;
            std::string layerName = "0";
            std::string refName;
            std::string textValue;
            bool closed = false;

            while (true) {
                const Pair p = readPair(*inPtr_);
                if (!p.ok) {
                    carry.ok = false;
                    break;
                }
                if (p.code == 0) {
                    carry = p;
                    break;
                }
                switch (p.code) {
                    case 8: layerName = p.value; break;
                    case 10: {
                        const double v = toD(p.value);
                        x0 = v;
                        cx = v;
                        xs.push_back(v);
                        break;
                    }
                    case 20: {
                        const double v = toD(p.value);
                        y0 = v;
                        cy = v;
                        ys.push_back(v);
                        break;
                    }
                    case 11: x1 = toD(p.value); break;
                    case 21: y1 = toD(p.value); break;
                    case 40: radius = toD(p.value); break;
                    case 43: constWidth = toD(p.value); break;
                    case 42: bulges.push_back(toD(p.value)); break;
                    case 50: a0 = toD(p.value); rotation = toD(p.value); break;
                    case 51: a1 = toD(p.value); break;
                    case 41: scaleX = toD(p.value); break;
                    case 70: closed = (std::stoi("0" + p.value) & 1) != 0; break;
                    case 1: textValue = p.value; break;
                    case 2: refName = p.value; break;
                    default: break;
                }
            }

            const int layer = layerMap.idFor(layerName);
            if (entity == "LINE") {
                LayoutShape s;
                s.type = "path";
                s.layerNumber = layer;
                s.datatype = 0;
                s.pathWidth = 1.0;
                s.points.push_back({x0 * scale_, y0 * scale_});
                s.points.push_back({x1 * scale_, y1 * scale_});
                emit(std::move(s));
            } else if (entity == "LWPOLYLINE") {
                LayoutShape s;
                s.layerNumber = layer;
                s.datatype = 0;
                const size_t n = std::min(xs.size(), ys.size());
                auto bulgeAt = [&](size_t i) -> double {
                    return i < bulges.size() ? bulges[i] : 0.0;
                };
                for (size_t i = 0; i + 1 < n; i++) {
                    s.points.push_back({xs[i] * scale_, ys[i] * scale_});
                    formatdetail::appendBulgeArc(s.points, xs[i] * scale_, ys[i] * scale_,
                                   xs[i + 1] * scale_, ys[i + 1] * scale_, bulgeAt(i));
                }
                if (n > 0) {
                    s.points.push_back({xs[n - 1] * scale_, ys[n - 1] * scale_});
                }
                // 闭合折线：末点→首点这段同样可带弓形
                if (closed && n >= 2) {
                    formatdetail::appendBulgeArc(s.points, xs[n - 1] * scale_, ys[n - 1] * scale_,
                                   xs[0] * scale_, ys[0] * scale_, bulgeAt(n - 1));
                }
                if (closed && s.points.size() >= 3) {
                    s.type = "polygon";
                    emit(std::move(s));
                } else if (s.points.size() >= 2) {
                    s.type = "path";
                    s.pathWidth = std::max(1.0, constWidth * scale_);
                    emit(std::move(s));
                }
            } else if (entity == "CIRCLE") {
                LayoutShape s;
                s.type = "polygon";
                s.layerNumber = layer;
                s.datatype = 0;
                formatdetail::appendCirclePolygon(s.points, cx * scale_, cy * scale_, radius * scale_);
                emit(std::move(s));
            } else if (entity == "ARC") {
                LayoutShape s;
                s.type = "path";
                s.layerNumber = layer;
                s.datatype = 0;
                s.pathWidth = 1.0;
                double start = a0 * formatdetail::kPi / 180.0;
                double end = a1 * formatdetail::kPi / 180.0;
                if (end <= start) {
                    end += 2 * formatdetail::kPi;
                }
                const int segs = 16;
                for (int i = 0; i <= segs; i++) {
                    const double a = start + (end - start) * i / segs;
                    s.points.push_back({(cx + radius * std::cos(a)) * scale_,
                                        (cy + radius * std::sin(a)) * scale_});
                }
                emit(std::move(s));
            } else if (entity == "TEXT" || entity == "MTEXT") {
                LayoutShape s;
                s.type = "text";
                s.layerNumber = layer;
                s.datatype = 0;
                s.text = textValue;
                s.points.push_back({x0 * scale_, y0 * scale_});
                emit(std::move(s));
            } else if (entity == "INSERT") {
                LayoutShape s;
                s.type = "instance";
                s.layerNumber = 0;
                s.datatype = 0;
                s.cellName = refName;
                // DXF 负 X 比例是「关于 Y 轴镜像」，且 DXF 顺序为先缩放后旋转：
                //   R(θ)·Fy == R(θ+180°)·Fx（实例语义只有 X 镜像可用），
                // 否则镜像被静默丢弃、几何左右反置。
                s.mirror = scaleX < 0 ? 1 : 0;
                s.rotation = s.mirror != 0
                    ? std::fmod(rotation + 540.0, 360.0)
                    : rotation;
                s.magnification = std::fabs(scaleX) > 0 ? std::fabs(scaleX) : 1.0;
                s.points.push_back({x0 * scale_, y0 * scale_});
                emit(std::move(s));
            } else if (entity == "POLYLINE") {
                // 顶点跟随 VERTEX 实体直到 SEQEND
                LayoutShape s;
                s.layerNumber = layer;
                s.datatype = 0;
                bool polyClosed = closed;
                std::vector<double> pvx;
                std::vector<double> pvy;
                std::vector<double> pvb;   // 第 i 个顶点的 bulge 描述 i→i+1 段
                while (carry.ok && carry.code == 0 && carry.value == "VERTEX") {
                    double vx = 0;
                    double vy = 0;
                    double vb = 0;
                    while (true) {
                        const Pair vp = readPair(*inPtr_);
                        if (!vp.ok) {
                            carry.ok = false;
                            break;
                        }
                        if (vp.code == 0) {
                            carry = vp;
                            break;
                        }
                        if (vp.code == 10) vx = toD(vp.value);
                        if (vp.code == 20) vy = toD(vp.value);
                        if (vp.code == 42) vb = toD(vp.value);
                    }
                    pvx.push_back(vx * scale_);
                    pvy.push_back(vy * scale_);
                    pvb.push_back(vb);
                }
                if (carry.ok && carry.code == 0 && carry.value == "SEQEND") {
                    // 吃掉 SEQEND 的字段直到下一个 0
                    while (true) {
                        const Pair sp = readPair(*inPtr_);
                        if (!sp.ok) {
                            carry.ok = false;
                            break;
                        }
                        if (sp.code == 0) {
                            carry = sp;
                            break;
                        }
                    }
                }
                // 与 LWPOLYLINE 同一套弓形展开：旧实现只连折弦，圆角被压平
                {
                    const size_t pn = pvx.size();
                    for (size_t i = 0; i + 1 < pn; i++) {
                        s.points.push_back({pvx[i], pvy[i]});
                        formatdetail::appendBulgeArc(s.points, pvx[i], pvy[i],
                                                     pvx[i + 1], pvy[i + 1], pvb[i]);
                    }
                    if (pn > 0) {
                        s.points.push_back({pvx[pn - 1], pvy[pn - 1]});
                    }
                    if (polyClosed && pn >= 2) {
                        formatdetail::appendBulgeArc(s.points, pvx[pn - 1], pvy[pn - 1],
                                                      pvx[0], pvy[0], pvb[pn - 1]);
                    }
                }
                if (polyClosed && s.points.size() >= 3) {
                    s.type = "polygon";
                    emit(std::move(s));
                } else if (s.points.size() >= 2) {
                    s.type = "path";
                    s.pathWidth = 1.0;
                    emit(std::move(s));
                }
            }
        };

        std::istream& in2 = in;
        inPtr_ = &in2;

        Pair p = readPair(in2);
        while (p.ok) {
            if (p.code == 0 && p.value == "BLOCK") {
                // 读块头拿名字
                std::string blockName;
                Pair q = readPair(in2);
                while (q.ok && q.code != 0) {
                    if (q.code == 2) {
                        blockName = q.value;
                    }
                    q = readPair(in2);
                }
                CellInfo cell;
                cell.name = blockName.empty() ? ("BLOCK_" + std::to_string(result.cells.size())) : blockName;
                result.cells.push_back(cell);
                currentCell = static_cast<int>(result.cells.size()) - 1;
                blockCells[cell.name] = currentCell;
                // 块内实体
                while (q.ok && !(q.code == 0 && q.value == "ENDBLK")) {
                    if (q.code == 0) {
                        Pair carry;
                        carry.ok = false;
                        parseEntity(q.value, carry);
                        if (carry.ok) {
                            q = carry;
                            continue;
                        }
                        q.ok = false;
                        break;
                    }
                    q = readPair(in2);
                }
                currentCell = 0;
                p = q.ok ? readPair(in2) : q;
                continue;
            }
            if (p.code == 0 && (p.value == "LINE" || p.value == "LWPOLYLINE" ||
                                p.value == "CIRCLE" || p.value == "ARC" ||
                                p.value == "TEXT" || p.value == "MTEXT" ||
                                p.value == "INSERT" || p.value == "POLYLINE")) {
                Pair carry;
                carry.ok = false;
                parseEntity(p.value, carry);
                if (carry.ok) {
                    p = carry;
                    continue;
                }
                break;
            }
            if (p.code == 0 && p.value == "EOF") {
                break;
            }
            p = readPair(in2);
        }

        result.cellCount = static_cast<int>(result.cells.size());
        result.layerCount = static_cast<int>(result.allLayers.size());
        result.unitDescription = "DXF unit = 1um → nm (x1000)";
        for (auto& cell : result.cells) {
            cell.layers = result.allLayers;
        }
    }

    static double toD(const std::string& s) {
        try {
            return std::stod(s);
        } catch (...) {
            return 0.0;
        }
    }

    std::istream* inPtr_ = nullptr;
};

} // namespace hongtu

#endif // HONGTU_FORMAT_READERS_H
