/**
 * HongTu EDA - 图像导出引擎（SVG / PNG）
 *
 * 从 native Layout 渲染版图为图像：
 * - SVG：矢量输出（文档/分享），按图层分组、可选网格
 * - PNG：软件光栅化（扫描线填充，无 GL 依赖）+ 自包含 PNG 编码
 *   （png_writer.h，stored-deflate zlib，标准解码器可读）
 * - 区域导出（bbox）/ 图层筛选 / 明暗背景
 *
 * 几何归一化：RECT/BOX 2 点对角线展开 4 角；PATH 按 pathWidth 轮廓化为描边等宽
 * 多边形（与 DRC/LVS 内核同口径，共用 Triangulator::pathOutline）。
 * 导出几何 = 自顶层 Cell 的层级展开结果（TEXT/INSTANCE 框不渲染），
 * 因此与画布所见一致；顶层未知时退回各 Cell 本地图形。
 *
 * 坐标口径：世界(nm) → 像素一律走 ViewProjection（世界 Y 向上，像素行号向下），
 * 与 ArkTS LayoutCanvasView.worldToScreenX/Y 同向 —— 导出图与屏幕所见上下不颠倒。
 *
 * 经 NAPI exportSvg/exportPng 暴露；host 冒烟 tools/image_export_smoke.cpp
 * 用 inflate_tiny 解回 IDAT 像素验证光栅正确性。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */
#ifndef HONGTU_IMAGE_EXPORT_H
#define HONGTU_IMAGE_EXPORT_H

#include "scene_graph.h"
#include "triangulator.h"
#include "png_writer.h"
#include <string>
#include <vector>
#include <sstream>
#include <iomanip>
#include <cmath>
#include <algorithm>
#include <fstream>
#include <cstdio>
#include <stdexcept>

namespace hongtu {

namespace imagedetail {

/** 与 DRC/LVS 同口径：直接复用 scene_graph.h 的 RECT/BOX 展开 + PATH 轮廓化 */
inline std::vector<Vec2> localContour(const SceneShape& shape) {
    return hongtu::effectivePolygon(shape);
}

inline bool isIdentityTransform(const GeometryEngine::Transform2D& xf) {
    return std::fabs(xf.a - 1.0) < 1e-12 && std::fabs(xf.b) < 1e-12 &&
           std::fabs(xf.c) < 1e-12 && std::fabs(xf.d - 1.0) < 1e-12 &&
           std::fabs(xf.tx) < 1e-12 && std::fabs(xf.ty) < 1e-12;
}

/** 一个待渲染轮廓（世界坐标 nm） */
struct Contour {
    LayerKey layer;
    std::vector<Vec2> points;
};

/**
 * 导出几何 = 自顶层 Cell 的层级展开结果（含 SREF/AREF 变换、PATH 轮廓）。
 * 顶层未知时退回各 Cell 本地图形，保证永不导出空图。
 */
inline std::vector<Contour> collectContours(const Layout& layout) {
    std::vector<Contour> out;
    auto emit = [&out](const SceneShape& s, const GeometryEngine::Transform2D& xf) {
        if (s.type == ShapeType::INSTANCE || s.type == ShapeType::TEXT) {
            return;
        }
        std::vector<Vec2> poly = hongtu::effectivePolygonTransformed(s, xf);
        if (poly.size() < 3) {
            return;
        }
        out.push_back(Contour{s.layerKey, std::move(poly)});
    };

    const int top = layout.topCellId();
    if (top >= 0) {
        layout.flattenHierarchy(top, -1, emit);
    }
    if (out.empty()) {
        // 顶层未知/顶层无几何：退回各 Cell 本地图形，保证不导出空图
        const GeometryEngine::Transform2D id = GeometryEngine::Transform2D::identity();
        for (const auto& s : layout.shapes) {
            emit(s, id);
        }
    }
    return out;
}

/** double → int 钳制：极端坐标下直接 static_cast<int> 是 UB，先隔离再取整 */
inline int clampToInt(double v, int lo, int hi) {
    if (!std::isfinite(v)) return lo;
    if (v <= static_cast<double>(lo)) return lo;
    if (v >= static_cast<double>(hi)) return hi;
    return static_cast<int>(v);
}

inline std::string rgbaToHex(uint32_t rgba) {
    const unsigned r = (rgba >> 24) & 0xFF;
    const unsigned g = (rgba >> 16) & 0xFF;
    const unsigned b = (rgba >> 8) & 0xFF;
    std::ostringstream ss;
    ss << "#" << std::hex << std::setfill('0')
       << std::setw(2) << r << std::setw(2) << g << std::setw(2) << b;
    return ss.str();
}

/**
 * 图层样式 → 导出侧的映射表（单一真源：LayerProperties；面板/.lyp 写入的同一批字段）。
 * 与 ArkTS 侧 MaterialTokens.layerRenderStyle() 同口径，改一处要同步另一处：
 *   lineStyle:   0=solid 1=dashed 2=dotted 3=dotdash
 *   fillPattern: 0=solid 1=hollow(只描边) 2=diagonal hatch 3=cross hatch
 *                (4..17 的 KLayout stipple 序号本模型未细分，按 diagonal 近似并在注释留痕)
 */
inline const char* dashArrayForLineStyle(uint8_t lineStyle) {
    switch (lineStyle) {
        case 1: return "6,4";
        case 2: return "2,2";
        case 3: return "6,2,2,2";
        default: return nullptr;   // 0 / 未知 = 实线（不伪造点阵）
    }
}

/** 0=实心填充 1=只描边（hollow/outline） 2=对角 hatch 3=十字 hatch */
inline int fillKindForPattern(uint8_t fillPattern) {
    if (fillPattern == 0) return 0;
    if (fillPattern == 1) return 1;
    if (fillPattern == 3) return 3;
    return 2;
}

inline double clamp01(double v) {
    if (!std::isfinite(v)) return 0.0;
    if (v < 0.0) return 0.0;
    if (v > 1.0) return 1.0;
    return v;
}

/** SVG 属性数值：去掉 float 噪声（0.6500000357 → "0.65"），便于稳定断言与 diff */
inline std::string svgNum(double v) {
    if (!std::isfinite(v)) return "0";
    char buf[32];
    std::snprintf(buf, sizeof(buf), "%.3f", v);
    std::string out(buf);
    while (out.size() > 1 && out.back() == '0') out.pop_back();
    if (!out.empty() && out.back() == '.') out.pop_back();
    return out.empty() ? std::string("0") : out;
}

/**
 * 图案填充 tile（SVG 原生支持；ArkUI ShapeNode / GLES3 都无图案刷，故只有导出能看到真 hatch）。
 * id 内含颜色，避免不同图层共用同一种 hatch 时串色。
 */
inline std::string hatchPatternDef(const std::string& id, int kind, const std::string& color) {
    // 用 raw string 承载属性引号，避免反斜杠转义在跨工具编辑中丢字符。
    const std::string openTag = R"(<pattern id=")";
    const std::string attrMid = R"(" width="8" height="8" patternUnits="userSpaceOnUse">)";
    const std::string diagHead = R"(<path d="M-2,2 L2,-2 M0,8 L8,0 M6,10 L10,6" stroke=")";
    const std::string crossHead = R"(<path d="M-2,6 L2,10 M0,0 L8,8 M6,-2 L10,2" stroke=")";
    const std::string pathTail = R"(" stroke-width="1" fill="none"/>)";
    std::ostringstream ss;
    ss << openTag << id << attrMid;
    ss << diagHead << color << pathTail;
    if (kind == 3) {
        ss << crossHead << color << pathTail;
    }
    ss << "</pattern>";
    return ss.str();
}

/** hatch 图层组用的 pattern id（同一 kind+颜色只生成一次） */
inline std::string hatchId(int kind, const std::string& hex) {
    return std::string("hongtu-hatch-") + (kind == 3 ? "cross-" : "diag-") + hex.substr(1);
}

inline std::string escapeXml(const std::string& s) {
    std::string result;
    result.reserve(s.size());
    for (char c : s) {
        switch (c) {
            case '&': result += "&amp;"; break;
            case '<': result += "&lt;"; break;
            case '>': result += "&gt;"; break;
            case '"': result += "&quot;"; break;
            default: result += c;
        }
    }
    return result;
}

} // namespace imagedetail

// ==================== SVG Export ====================

class SvgExporter {
public:
    struct ExportOptions {
        BBox region;              // 导出区域 (nm)；invalid = 全设计
        double scale = 1.0;       // 像素/nm
        int maxWidth = 4096;      // 输出宽上限 (px)
        int maxHeight = 4096;
        bool showGrid = false;
        double gridSpacing = 100; // nm
        std::vector<int> visibleLayers;  // 空 = 全部图层
        bool darkBackground = true;
        std::string title;
    };

    static std::string exportSvg(const Layout& layout, const ExportOptions& opts) {
        std::ostringstream svg;

        const std::vector<imagedetail::Contour> contours = imagedetail::collectContours(layout);

        BBox region = opts.region;
        if (!region.valid()) {
            for (const auto& c : contours) {
                region = region.unite(GeometryEngine::computeBBox(c.points));
            }
        }
        if (!region.valid()) {
            region = BBox(0, 0, 1000, 1000);
        }

        double designW = region.maxX - region.minX;
        double designH = region.maxY - region.minY;
        if (designW <= 0) designW = 1;
        if (designH <= 0) designH = 1;

        double scale = opts.scale > 0 ? opts.scale : 1.0;
        if (designW * scale > opts.maxWidth) scale = opts.maxWidth / designW;
        if (designH * scale > opts.maxHeight) scale = opts.maxHeight / designH;
        if (scale <= 0 || !std::isfinite(scale)) scale = 1.0;

        const int outW = std::max(1, static_cast<int>(designW * scale));
        const int outH = std::max(1, static_cast<int>(designH * scale));

        // 头/体分开缓冲：hatch pattern 在遍历图层时才确定，需要回填到 <defs>。
        std::ostringstream head;
        std::ostringstream body;
        std::vector<std::string> hatchIds;    // 已登记的 pattern id（去重用）
        std::vector<std::string> hatchDefs;   // 与 hatchIds 同序的 <pattern> 定义串

        head << "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n";
        head << "<svg xmlns=\"http://www.w3.org/2000/svg\" "
             << "width=\"" << outW << "\" height=\"" << outH << "\" "
             << "viewBox=\"0 0 " << outW << " " << outH << "\">\n";

        if (!opts.title.empty()) {
            head << "  <title>" << imagedetail::escapeXml(opts.title) << "</title>\n";
        }
        head << "  <desc>Generated by HongTu EDA</desc>\n";

        const char* bgColor = opts.darkBackground ? "#0d0d14" : "#ffffff";
        head << "  <rect width=\"100%\" height=\"100%\" fill=\"" << bgColor << "\"/>\n";

        // world (nm) → 图像像素：世界 Y 向上，region.maxY 在图像顶部。
        const ViewProjection proj{region.minX, region.maxY, scale};
        const auto toSvgX = [&](double x) { return proj.toPixelX(x); };
        const auto toSvgY = [&](double y) { return proj.toPixelY(y); };

        if (opts.showGrid && opts.gridSpacing > 0) {
            body << "  <g stroke=\"#333\" stroke-width=\"0.5\" opacity=\"0.3\">\n";
            for (double gx = std::ceil(region.minX / opts.gridSpacing) * opts.gridSpacing;
                 gx <= region.maxX; gx += opts.gridSpacing) {
                const double sx = toSvgX(gx);
                body << "    <line x1=\"" << sx << "\" y1=\"0\" x2=\"" << sx
                     << "\" y2=\"" << outH << "\"/>\n";
            }
            for (double gy = std::ceil(region.minY / opts.gridSpacing) * opts.gridSpacing;
                 gy <= region.maxY; gy += opts.gridSpacing) {
                const double sy = toSvgY(gy);
                body << "    <line x1=\"0\" y1=\"" << sy << "\" x2=\"" << outW
                     << "\" y2=\"" << sy << "\"/>\n";
            }
            body << "  </g>\n";
        }

        // 按图层分组渲染
        std::unordered_map<LayerKey, std::vector<const imagedetail::Contour*>, LayerKeyHash> byLayer;
        for (const auto& c : contours) {
            byLayer[c.layer].push_back(&c);
        }

        for (const auto& layerKey : layout.allLayers()) {
            if (!opts.visibleLayers.empty() &&
                std::find(opts.visibleLayers.begin(), opts.visibleLayers.end(),
                          layerKey.layer) == opts.visibleLayers.end()) {
                continue;
            }
            auto lpIt = layout.layerProps.find(layerKey);
            if (lpIt == layout.layerProps.end()) continue;
            const LayerProperties& lp = lpIt->second;
            if (!lp.visible) continue;

            // 图层样式全部来自 LayerProperties（与画布同源）：
            //   transparency → fill-opacity / stroke-opacity
            //   lineStyle    → stroke-dasharray
            //   lineWidth    → stroke-width
            //   fillPattern  → fill="<hex>" | "none" | url(#hatch)
            const std::string fillHex = imagedetail::rgbaToHex(lp.fillColor);
            const std::string strokeHex = imagedetail::rgbaToHex(lp.lineColor);
            const int fillKind = imagedetail::fillKindForPattern(lp.fillPattern);
            const double opacity = imagedetail::clamp01(1.0 - static_cast<double>(lp.transparency));
            double strokeW = std::isfinite(lp.lineWidth) && lp.lineWidth > 0.0f
                ? static_cast<double>(lp.lineWidth) : 0.5;
            if (strokeW > 64.0) strokeW = 64.0;

            std::string fillAttr;
            if (fillKind == 1) {
                fillAttr = "fill=\"none\"";            // hollow / outline：只描边
            } else if (fillKind == 2 || fillKind == 3) {
                const std::string id = imagedetail::hatchId(fillKind, fillHex);
                if (std::find(hatchIds.begin(), hatchIds.end(), id) == hatchIds.end()) {
                    hatchIds.push_back(id);
                    hatchDefs.push_back(imagedetail::hatchPatternDef(id, fillKind, fillHex));
                }
                fillAttr = "fill=\"url(#" + id + ")\"";
            } else {
                fillAttr = "fill=\"" + fillHex + "\"";
            }

            body << "  <g id=\"layer_" << layerKey.layer << "_" << layerKey.datatype
                 << "\" " << fillAttr
                 << " fill-opacity=\"" << imagedetail::svgNum(opacity)
                 << "\" stroke=\"" << strokeHex
                 << "\" stroke-opacity=\"" << imagedetail::svgNum(opacity)
                 << "\" stroke-width=\"" << imagedetail::svgNum(strokeW) << "\"";
            if (const char* dash = imagedetail::dashArrayForLineStyle(lp.lineStyle)) {
                body << " stroke-dasharray=\"" << dash << "\"";
            }
            body << ">\n";

            auto groupIt = byLayer.find(layerKey);
            if (groupIt != byLayer.end()) {
                for (const auto* c : groupIt->second) {
                    if (!GeometryEngine::computeBBox(c->points).intersects(region)) continue;
                    body << "    <polygon points=\"";
                    for (size_t i = 0; i < c->points.size(); i++) {
                        if (i > 0) body << " ";
                        body << toSvgX(c->points[i].x) << "," << toSvgY(c->points[i].y);
                    }
                    body << "\"/>\n";
                }
            }
            body << "  </g>\n";
        }

        svg << head.str();
        if (!hatchDefs.empty()) {
            svg << "  <defs>\n";
            for (const auto& def : hatchDefs) {
                svg << "    " << def << "\n";
            }
            svg << "  </defs>\n";
        }
        svg << body.str();
        svg << "</svg>\n";
        return svg.str();
    }

    static bool saveToFile(const Layout& layout, const std::string& filePath,
                           const ExportOptions& opts) {
        const std::string svgContent = exportSvg(layout, opts);
        std::ofstream file(filePath, std::ios::binary);
        if (!file.is_open()) return false;
        file << svgContent;
        return file.good();
    }
};

// ==================== PNG Export (Software Rasterizer) ====================

class PngExporter {
public:
    struct PngOptions {
        int width = 1920;
        int height = 1080;
        BBox region;              // invalid = 全设计
        bool darkBackground = true;
        std::vector<int> visibleLayers;
    };

    /** 渲染为 RGBA 缓冲（width*height*4） */
    static std::vector<uint8_t> renderToBuffer(const Layout& layout, const PngOptions& opts) {
        const int w = std::max(1, opts.width);
        const int h = std::max(1, opts.height);
        if (w > 8192 || h > 8192) throw std::invalid_argument("PNG dimensions exceed 8192 pixels");
        std::vector<uint8_t> pixels(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);

        const uint8_t bgR = opts.darkBackground ? 13 : 255;
        const uint8_t bgG = opts.darkBackground ? 13 : 255;
        const uint8_t bgB = opts.darkBackground ? 20 : 255;
        for (size_t i = 0; i < static_cast<size_t>(w) * static_cast<size_t>(h); i++) {
            pixels[i * 4 + 0] = bgR;
            pixels[i * 4 + 1] = bgG;
            pixels[i * 4 + 2] = bgB;
            pixels[i * 4 + 3] = 255;
        }

        const std::vector<imagedetail::Contour> contours = imagedetail::collectContours(layout);

        BBox region = opts.region;
        if (!region.valid()) {
            for (const auto& c : contours) {
                region = region.unite(GeometryEngine::computeBBox(c.points));
            }
        }
        if (!region.valid()) {
            return pixels;
        }

        // 世界 → 像素：等比铺满，世界 Y 向上（与画布/SVG 同一 ViewProjection）
        const ViewProjection proj = ViewProjection::fitting(region, w, h);
        if (proj.scale <= 0 || !std::isfinite(proj.scale)) {
            return pixels;
        }

        size_t strokeWork = 0;
        for (const auto& c : contours) {
            auto lpIt = layout.layerProps.find(c.layer);
            if (lpIt == layout.layerProps.end()) continue;
            if (!lpIt->second.visible) continue;
            if (!opts.visibleLayers.empty() &&
                std::find(opts.visibleLayers.begin(), opts.visibleLayers.end(),
                          c.layer.layer) == opts.visibleLayers.end()) {
                continue;
            }
            if (!GeometryEngine::computeBBox(c.points).intersects(region)) continue;

            const uint32_t color = lpIt->second.fillColor;
            const uint8_t r = (color >> 24) & 0xFF;
            const uint8_t g = (color >> 16) & 0xFF;
            const uint8_t b = (color >> 8) & 0xFF;
            // transparency（0–1，与 SVG 的 fill-opacity 同口径）→ 像素 alpha
            const uint8_t a = static_cast<uint8_t>(imagedetail::clamp01(
                1.0 - static_cast<double>(lpIt->second.transparency)) * 255.0);
            // fillStyle → PNG：hollow 只描边；diagonal/cross 用像素级点阵（与 SVG 的
            // <pattern> 同语义，栅格化端没有矢量图案可用）。lineWidth 决定描边粗细。
            const int fillKind = imagedetail::fillKindForPattern(lpIt->second.fillPattern);
            const double lw = std::isfinite(lpIt->second.lineWidth) && lpIt->second.lineWidth > 0.0f
                ? static_cast<double>(lpIt->second.lineWidth) : 1.0;
            const int strokePx = std::max(1, imagedetail::clampToInt(lw, 1, 32));

            if (fillKind != 1) {
                fillPolygon(pixels, w, h, c.points, proj, r, g, b, a, fillKind, strokePx);
            }
            const uint32_t lineColor = lpIt->second.lineColor;
            strokePolygon(pixels, w, h, c.points, proj,
                static_cast<uint8_t>((lineColor >> 24) & 0xFF),
                static_cast<uint8_t>((lineColor >> 16) & 0xFF),
                static_cast<uint8_t>((lineColor >> 8) & 0xFF), a, strokePx,
                lpIt->second.lineStyle, strokeWork);
        }

        return pixels;
    }

    /** 渲染并保存为 PNG（自包含编码，无外部依赖） */
    static bool saveAsPng(const Layout& layout, const std::string& filePath,
                          const PngOptions& opts) {
        const int w = std::max(1, opts.width);
        const int h = std::max(1, opts.height);
        const std::vector<uint8_t> pixels = renderToBuffer(layout, opts);
        return pngwriter::saveRgba(filePath, pixels, w, h);
    }

private:
    /** 像素级 hatch 判定：45° 对角（cross 时再加 135°），6px 周期 */
    static bool onHatchLine(int x, int y, int width, bool cross) {
        // 6px 周期；不用 lambda 捕获（MSVC 对块级 constexpr 的隐式捕获判定更严）
        for (int k = 0; k < width; k++) {
            if ((((y + x + k) % 6) + 6) % 6 == 0) return true;
            if (cross && ((((y - x + k) % 6) + 6) % 6 == 0)) return true;
        }
        return false;
    }

    /** 混色：源色 × alpha + 底色 × (1-alpha) */
    static void blendPixel(std::vector<uint8_t>& pixels, int w, int h, int x, int y,
                           uint8_t r, uint8_t g, uint8_t b, float alpha) {
        if (x < 0 || y < 0 || x >= w || y >= h || alpha <= 0.0f) return;
        const size_t idx = (static_cast<size_t>(y) * static_cast<size_t>(w) +
                            static_cast<size_t>(x)) * 4;
        pixels[idx + 0] = static_cast<uint8_t>(r * alpha + pixels[idx + 0] * (1 - alpha));
        pixels[idx + 1] = static_cast<uint8_t>(g * alpha + pixels[idx + 1] * (1 - alpha));
        pixels[idx + 2] = static_cast<uint8_t>(b * alpha + pixels[idx + 2] * (1 - alpha));
    }

    static double strokeDashPeriod(uint8_t style) {
        return style == 1 ? 10.0 : (style == 2 ? 4.0 : (style == 3 ? 12.0 : 0.0));
    }

    static bool onStrokeDash(double phase, uint8_t style) {
        if (style == 1) return phase < 6.0;
        if (style == 2) return phase < 2.0;
        if (style == 3) return phase < 6.0 || (phase >= 8.0 && phase < 10.0);
        return true;
    }

    /** Clip before integer conversion/stepping; retain the original arc-length phase. */
    static bool clipStrokeSegment(double x0, double y0, double dx, double dy,
                                  double left, double top, double right, double bottom,
                                  double& first, double& last) {
        first = 0.0; last = 1.0;
        const auto bound = [&](double p, double q) {
            if (p == 0.0) return q >= 0.0;
            const double ratio = q / p;
            if (p < 0.0) first = std::max(first, ratio);
            else last = std::min(last, ratio);
            return first <= last;
        };
        return bound(-dx, x0 - left) && bound(dx, right - x0) &&
               bound(-dy, y0 - top) && bound(dy, bottom - y0);
    }

    /** Independent stroke for every fill kind; dash phase continues around the contour. */
    static void strokePolygon(std::vector<uint8_t>& pixels, int w, int h,
                              const std::vector<Vec2>& points,
                              const ViewProjection& proj,
                              uint8_t r, uint8_t g, uint8_t b, uint8_t a, int strokePx,
                              uint8_t lineStyle, size_t& strokeWork) {
        if (points.size() < 3 || a == 0) return;
        const float alpha = a / 255.0f;
        const int low = (strokePx - 1) / 2;
        const int high = strokePx / 2;
        double minX = INFINITY, minY = INFINITY, maxX = -INFINITY, maxY = -INFINITY;
        for (const auto& p : points) {
            const double x = proj.toPixelX(p.x), y = proj.toPixelY(p.y);
            if (!std::isfinite(x) || !std::isfinite(y)) throw std::invalid_argument("PNG stroke coordinates are not finite");
            minX = std::min(minX, x); maxX = std::max(maxX, x);
            minY = std::min(minY, y); maxY = std::max(maxY, y);
        }
        // Fitting projects the region's right/bottom boundary to w/h; retain that
        // boundary on the last raster column/row, without admitting farther edges.
        // Preserve x=w/y=h for thin fitted outlines. Wider strokes need only
        // the last raster sample plus their negative brush radius; accepting
        // one extra center and clamping it inward would create a border ghost.
        const double clipRight = std::max(static_cast<double>(w), static_cast<double>(w - 1 + low));
        const double clipBottom = std::max(static_cast<double>(h), static_cast<double>(h - 1 + low));
        if (maxX < -high || maxY < -high || minX > clipRight || minY > clipBottom) return;
        const int boxLeft = imagedetail::clampToInt(std::floor(minX) - low, 0, w - 1);
        const int boxTop = imagedetail::clampToInt(std::floor(minY) - low, 0, h - 1);
        const int boxRight = imagedetail::clampToInt(std::ceil(maxX) + high, 0, w - 1);
        const int boxBottom = imagedetail::clampToInt(std::ceil(maxY) + high, 0, h - 1);
        const size_t boxWidth = static_cast<size_t>(boxRight - boxLeft + 1);
        const size_t boxPixels = boxWidth * static_cast<size_t>(boxBottom - boxTop + 1);
        // One bit per cropped output pixel avoids repeated alpha at joins/overlapping stamps.
        std::vector<uint8_t> coverage((boxPixels + 7) / 8, 0);
        const double period = strokeDashPeriod(lineStyle);
        double phase = 0.0;
        constexpr size_t workLimit = 128u * 1024u * 1024u;
        for (size_t i = 0; i < points.size(); i++) {
            const size_t j = (i + 1) % points.size();
            const double x0 = proj.toPixelX(points[i].x);
            const double y0 = proj.toPixelY(points[i].y);
            const double x1 = proj.toPixelX(points[j].x);
            const double y1 = proj.toPixelY(points[j].y);
            const double dx = x1 - x0, dy = y1 - y0;
            const double len = std::hypot(dx, dy);
            if (!std::isfinite(len)) throw std::invalid_argument("PNG stroke length is not finite");
            double first = 0.0, last = 1.0;
            const bool visible = clipStrokeSegment(x0, y0, dx, dy, -high, -high,
                clipRight, clipBottom, first, last);
            const double nextPhase = period > 0.0 ? std::fmod(phase + std::fmod(len, period), period) : 0.0;
            if (!visible) { phase = nextPhase; continue; }
            const double cx0 = x0 + dx * first, cy0 = y0 + dy * first;
            const double cx1 = x0 + dx * last, cy1 = y0 + dy * last;
            const double clippedLength = std::hypot(cx1 - cx0, cy1 - cy0);
            if (!std::isfinite(clippedLength) || clippedLength > std::hypot(w + strokePx, h + strokePx) + 1.0)
                throw std::invalid_argument("PNG stroke clipping is not representable");
            const int steps = std::max(1, static_cast<int>(std::ceil(clippedLength)));
            const size_t work = static_cast<size_t>(steps + 1) * static_cast<size_t>(strokePx * strokePx);
            if (work > workLimit - strokeWork) throw std::runtime_error("PNG stroke exceeds complete-output budget");
            strokeWork += work;
            const double startPhase = period > 0.0 ? std::fmod(phase + std::fmod(len * first, period), period) : 0.0;
            const double unitX = len > 0.0 ? dx / len : 0.0;
            const double unitY = len > 0.0 ? dy / len : 0.0;
            for (int k = 0; k <= steps; k++) {
                const double t = static_cast<double>(k) / steps;
                const int px = imagedetail::clampToInt(std::floor(cx0 + (cx1 - cx0) * t + 0.5), -high, w - 1 + low);
                const int py = imagedetail::clampToInt(std::floor(cy0 + (cy1 - cy0) * t + 0.5), -high, h - 1 + low);
                for (int oy = -low; oy <= high; oy++) {
                    for (int ox = -low; ox <= high; ox++) {
                        const int x = px + ox, y = py + oy;
                        if (x < boxLeft || y < boxTop || x > boxRight || y > boxBottom) continue;
                        // Classify the output pixel by tangent distance, rather than
                        // expanding an on-dash sample into adjacent off-dash pixels.
                        // This keeps gaps open for thick dashed/dotted outlines.
                        if (period > 0.0) {
                            const double along = (x - cx0) * unitX + (y - cy0) * unitY;
                            if (along < 0.0 || along > clippedLength) continue;
                            if (!onStrokeDash(std::fmod(startPhase + along, period), lineStyle)) continue;
                        }
                        const size_t bit = static_cast<size_t>(y - boxTop) * boxWidth + static_cast<size_t>(x - boxLeft);
                        const uint8_t mask = static_cast<uint8_t>(1u << (bit % 8));
                        if ((coverage[bit / 8] & mask) != 0) continue;
                        coverage[bit / 8] |= mask;
                        blendPixel(pixels, w, h, x, y, r, g, b, alpha);
                    }
                }
            }
            phase = nextPhase;
        }
    }

    /**
     * pattern: 0=实心 2=对角 hatch 3=十字 hatch（6px 间距，与 SVG pattern 的 8px tile 同量级）
     * strokePx: hatch 线宽（来自 LayerProperties.lineWidth）
     */
    static void fillPolygon(std::vector<uint8_t>& pixels, int w, int h,
                            const std::vector<Vec2>& points,
                            const ViewProjection& proj,
                            uint8_t r, uint8_t g, uint8_t b, uint8_t a,
                            int pattern = 0, int strokePx = 1) {
        if (points.size() < 3) return;

        // 顶点保留 double，扫描线用几何相交避免整型除零/精度问题
        std::vector<double> xs;
        std::vector<double> ys;
        xs.reserve(points.size());
        ys.reserve(points.size());
        double minYf = 1e30;
        double maxYf = -1e30;
        for (const auto& p : points) {
            const double px = proj.toPixelX(p.x);
            const double py = proj.toPixelY(p.y);
            if (!std::isfinite(px) || !std::isfinite(py)) {
                return;   // 病态变换产出 NaN：整条轮廓放弃，不写脏像素
            }
            xs.push_back(px);
            ys.push_back(py);
            minYf = std::min(minYf, py);
            maxYf = std::max(maxYf, py);
        }

        const int minY = imagedetail::clampToInt(std::floor(minYf), 0, h - 1);
        const int maxY = imagedetail::clampToInt(std::ceil(maxYf), 0, h - 1);
        const int n = static_cast<int>(points.size());
        const float alpha = a / 255.0f;

        std::vector<double> intersections;
        for (int y = minY; y <= maxY; y++) {
            const double scanY = y + 0.5;
            intersections.clear();
            for (int i = 0; i < n; i++) {
                const int j = (i + 1) % n;
                const double y0 = ys[i];
                const double y1 = ys[j];
                if ((y0 <= scanY && y1 > scanY) || (y1 <= scanY && y0 > scanY)) {
                    const double t = (scanY - y0) / (y1 - y0);
                    intersections.push_back(xs[i] + t * (xs[j] - xs[i]));
                }
            }
            std::sort(intersections.begin(), intersections.end());

            for (size_t i = 0; i + 1 < intersections.size(); i += 2) {
                const double first = std::ceil(intersections[i] - 0.5);
                const double last = std::floor(intersections[i + 1] - 0.5);
                if (last < 0 || first > w - 1 || first > last) continue;
                const int xStart = imagedetail::clampToInt(first, 0, w - 1);
                const int xEnd = imagedetail::clampToInt(last, 0, w - 1);
                // hatch 线宽跟随 LayerProperties.lineWidth（钳到 1–3px，栅格端不至于糊死）
                const int hatchW = (pattern == 0) ? 1 : std::max(1, std::min(3, strokePx));
                for (int x = xStart; x <= xEnd; x++) {
                    // 图案填充：只保留落在对角/十字线上的像素
                    if (pattern == 2 && !onHatchLine(x, y, hatchW, false)) continue;
                    if (pattern == 3 && !onHatchLine(x, y, hatchW, true)) continue;
                    blendPixel(pixels, w, h, x, y, r, g, b, alpha);
                }
            }
        }
    }
};

} // namespace hongtu

#endif // HONGTU_IMAGE_EXPORT_H
