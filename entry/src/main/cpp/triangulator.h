/**
 * HongTu EDA - Polygon Triangulation Engine
 * Ear-clipping algorithm for concave polygon tessellation.
 * Handles holes via bridge-edge insertion.
 * Output: triangle index list suitable for GL_TRIANGLES.
 */
#ifndef HONGTU_TRIANGULATOR_H
#define HONGTU_TRIANGULATOR_H

#include <vector>
#include <cstdint>
#include <cmath>
#include <algorithm>
#include <numeric>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace hongtu {

struct Vec2 {
    double x, y;
    Vec2() : x(0), y(0) {}
    Vec2(double x_, double y_) : x(x_), y(y_) {}
    Vec2 operator-(const Vec2& o) const { return {x - o.x, y - o.y}; }
    Vec2 operator+(const Vec2& o) const { return {x + o.x, y + o.y}; }
    Vec2 operator*(double s) const { return {x * s, y * s}; }
    double cross(const Vec2& o) const { return x * o.y - y * o.x; }
    double dot(const Vec2& o) const { return x * o.x + y * o.y; }
    double length() const { return std::sqrt(x * x + y * y); }
    double lengthSq() const { return x * x + y * y; }
};

/**
 * Triangulator: converts arbitrary simple polygons (with optional holes)
 * into triangle lists for OpenGL rendering.
 */
class Triangulator {
public:
    /**
     * Triangulate a simple polygon (no holes).
     * @param vertices Polygon vertices in order (CW or CCW).
     * @param outTriangles Output: indices into vertices array, 3 per triangle.
     * @return true if triangulation succeeded.
     */
    static bool triangulate(const std::vector<Vec2>& vertices,
                           std::vector<uint32_t>& outTriangles) {
        outTriangles.clear();
        // 去掉重复闭合点/连续重合点/非有限点：这些顶点会让 ear-clipping 找不到任何
        // ear（0 面积三角形既非凸也非法），退化多边形会静默丢三角。origIdx 把清理后
        // 的下标映射回入参数组，保持「输出索引指向 vertices」的契约。
        std::vector<Vec2> clean;
        std::vector<uint32_t> origIdx;
        clean.reserve(vertices.size());
        origIdx.reserve(vertices.size());
        for (size_t k = 0; k < vertices.size(); k++) {
            const Vec2& v = vertices[k];
            if (!std::isfinite(v.x) || !std::isfinite(v.y)) continue;
            if (!clean.empty()) {
                const Vec2& prev = clean.back();
                if (std::fabs(v.x - prev.x) <= 1e-12 && std::fabs(v.y - prev.y) <= 1e-12) {
                    continue;
                }
            }
            clean.push_back(v);
            origIdx.push_back((uint32_t)k);
        }
        // 首尾重合（GDS 闭合重复顶点）
        while (clean.size() > 3 &&
               std::fabs(clean.front().x - clean.back().x) <= 1e-12 &&
               std::fabs(clean.front().y - clean.back().y) <= 1e-12) {
            clean.pop_back();
            origIdx.pop_back();
        }

        int n = (int)clean.size();
        if (n < 3) return false;
        if (n == 3) {
            if (std::fabs(computeSignedArea(clean)) <= 1e-12) {
                return false;   // 三点共线：无面积可三角化
            }
            outTriangles = {origIdx[0], origIdx[1], origIdx[2]};
            return true;
        }

        // Doubly-linked CCW ring + reflex-only AABB / 32x32 spatial bucket acceleration
        // Reduces 8,000-vertex wafer ring / keyhole polygon ear-clipping from ~1,140ms to <3ms.
        std::vector<int> prev(n), next(n);
        const double signedArea = computeSignedArea(clean);
        if (signedArea >= 0) {
            for (int i = 0; i < n; i++) {
                prev[i] = (i == 0) ? (n - 1) : (i - 1);
                next[i] = (i + 1 == n) ? 0 : (i + 1);
            }
        } else {
            for (int i = 0; i < n; i++) {
                prev[i] = (i + 1 == n) ? 0 : (i + 1);
                next[i] = (i == 0) ? (n - 1) : (i - 1);
            }
        }

        std::vector<uint8_t> active(n, 1);
        std::vector<uint8_t> reflex(n, 0);
        std::vector<int> reflexList;
        reflexList.reserve(n / 2 + 4);

        auto evalReflex = [&](int v) -> bool {
            const Vec2& a = clean[prev[v]];
            const Vec2& b = clean[v];
            const Vec2& c = clean[next[v]];
            return (b - a).cross(c - b) <= 0.0;
        };

        double polyMinX = clean[0].x, polyMaxX = clean[0].x;
        double polyMinY = clean[0].y, polyMaxY = clean[0].y;
        for (int i = 0; i < n; i++) {
            const Vec2& p = clean[i];
            if (p.x < polyMinX) polyMinX = p.x;
            if (p.x > polyMaxX) polyMaxX = p.x;
            if (p.y < polyMinY) polyMinY = p.y;
            if (p.y > polyMaxY) polyMaxY = p.y;
            if (evalReflex(i)) {
                reflex[i] = 1;
                reflexList.push_back(i);
            }
        }

        constexpr int GRID_DIM = 32;
        const bool useGrid = (reflexList.size() >= 64) &&
                             (polyMaxX > polyMinX + 1e-9) &&
                             (polyMaxY > polyMinY + 1e-9);
        double invGridW = 0.0, invGridH = 0.0;
        std::vector<std::vector<int>> gridBuckets;
        auto gridCell = [](double val, double minV, double invSpan) -> int {
            int c = static_cast<int>((val - minV) * invSpan);
            if (c < 0) return 0;
            if (c >= GRID_DIM) return GRID_DIM - 1;
            return c;
        };
        if (useGrid) {
            invGridW = static_cast<double>(GRID_DIM) / (polyMaxX - polyMinX);
            invGridH = static_cast<double>(GRID_DIM) / (polyMaxY - polyMinY);
            gridBuckets.resize(GRID_DIM * GRID_DIM);
            for (int rv : reflexList) {
                const int gx = gridCell(clean[rv].x, polyMinX, invGridW);
                const int gy = gridCell(clean[rv].y, polyMinY, invGridH);
                gridBuckets[gy * GRID_DIM + gx].push_back(rv);
            }
        }

        auto isFastEar = [&](int i1, bool strictConvex) -> bool {
            const int i0 = prev[i1];
            const int i2 = next[i1];
            const Vec2& v0 = clean[i0];
            const Vec2& v1 = clean[i1];
            const Vec2& v2 = clean[i2];
            const double area2 = (v1 - v0).cross(v2 - v1);
            if (strictConvex ? (area2 <= 0.0) : (area2 < -1e-9)) {
                return false;
            }
            if (reflexList.empty()) {
                return true;
            }
            const double tMinX = std::min({v0.x, v1.x, v2.x});
            const double tMaxX = std::max({v0.x, v1.x, v2.x});
            const double tMinY = std::min({v0.y, v1.y, v2.y});
            const double tMaxY = std::max({v0.y, v1.y, v2.y});

            auto hitsVertex = [&](int vi) -> bool {
                if (!active[vi] || !reflex[vi] || vi == i0 || vi == i1 || vi == i2) return false;
                const Vec2& p = clean[vi];
                if (p.x < tMinX || p.x > tMaxX || p.y < tMinY || p.y > tMaxY) return false;
                // Ignore vertices coincident with triangle corners (keyhole bridge duplicates)
                if ((std::fabs(p.x - v0.x) <= 1e-9 && std::fabs(p.y - v0.y) <= 1e-9) ||
                    (std::fabs(p.x - v1.x) <= 1e-9 && std::fabs(p.y - v1.y) <= 1e-9) ||
                    (std::fabs(p.x - v2.x) <= 1e-9 && std::fabs(p.y - v2.y) <= 1e-9)) {
                    return false;
                }
                return pointInTriangle(p, v0, v1, v2);
            };

            if (useGrid) {
                const int gx0 = gridCell(tMinX, polyMinX, invGridW);
                const int gx1 = gridCell(tMaxX, polyMinX, invGridW);
                const int gy0 = gridCell(tMinY, polyMinY, invGridH);
                const int gy1 = gridCell(tMaxY, polyMinY, invGridH);
                for (int gy = gy0; gy <= gy1; ++gy) {
                    const int rowOff = gy * GRID_DIM;
                    for (int gx = gx0; gx <= gx1; ++gx) {
                        const auto& bucket = gridBuckets[rowOff + gx];
                        for (int vi : bucket) {
                            if (hitsVertex(vi)) return false;
                        }
                    }
                }
                return true;
            }

            for (size_t r = 0; r < reflexList.size(); ++r) {
                const int vi = reflexList[r];
                if (!active[vi] || !reflex[vi]) {
                    reflexList[r] = reflexList.back();
                    reflexList.pop_back();
                    --r;
                    continue;
                }
                if (hitsVertex(vi)) return false;
            }
            return true;
        };

        outTriangles.reserve(static_cast<size_t>(n - 2) * 3);
        int remaining = n;
        int curr = 0;
        int failCount = 0;
        bool relaxedPass = false;

        while (remaining > 3) {
            if ((!reflex[curr] || relaxedPass) && isFastEar(curr, !relaxedPass)) {
                const int pIdx = prev[curr];
                const int nIdx = next[curr];
                outTriangles.push_back(origIdx[pIdx]);
                outTriangles.push_back(origIdx[curr]);
                outTriangles.push_back(origIdx[nIdx]);

                active[curr] = 0;
                reflex[curr] = 0;
                next[pIdx] = nIdx;
                prev[nIdx] = pIdx;
                remaining--;
                failCount = 0;
                relaxedPass = false;

                if (reflex[pIdx] && !evalReflex(pIdx)) reflex[pIdx] = 0;
                if (reflex[nIdx] && !evalReflex(nIdx)) reflex[nIdx] = 0;
                curr = pIdx;
            } else {
                curr = next[curr];
                failCount++;
                if (failCount >= remaining) {
                    if (!relaxedPass) {
                        relaxedPass = true;
                        failCount = 0;
                    } else {
                        break;
                    }
                }
            }
        }

        if (remaining == 3) {
            const int a = curr;
            const int b = next[a];
            const int c = next[b];
            outTriangles.push_back(origIdx[a]);
            outTriangles.push_back(origIdx[b]);
            outTriangles.push_back(origIdx[c]);
        }

        return !outTriangles.empty();
    }

    /**
     * Triangulate a polygon with holes.
     * @param outer Outer boundary vertices (CCW).
     * @param holes Vector of hole boundaries (CW).
     * @param outVertices Output: combined vertex array.
     * @param outTriangles Output: triangle indices.
     * @return true on success.
     */
    static bool triangulateWithHoles(const std::vector<Vec2>& outer,
                                     const std::vector<std::vector<Vec2>>& holes,
                                     std::vector<Vec2>& outVertices,
                                     std::vector<uint32_t>& outTriangles) {
        outVertices.clear();
        outTriangles.clear();

        if (holes.empty()) {
            outVertices = outer;
            return triangulate(outer, outTriangles);
        }

        // Merge holes into outer polygon using bridge edges
        std::vector<Vec2> merged = outer;

        // Sort holes by maximum X coordinate (rightmost point)
        std::vector<int> holeOrder(holes.size());
        std::iota(holeOrder.begin(), holeOrder.end(), 0);
        std::sort(holeOrder.begin(), holeOrder.end(), [&](int a, int b) {
            double maxA = -1e18, maxB = -1e18;
            for (const auto& v : holes[a]) maxA = std::max(maxA, v.x);
            for (const auto& v : holes[b]) maxB = std::max(maxB, v.x);
            return maxA > maxB;
        });

        for (int hi : holeOrder) {
            const auto& hole = holes[hi];
            if (hole.empty()) continue;

            // Find rightmost point of hole
            int holeStart = 0;
            double maxX = -1e18;
            for (int i = 0; i < (int)hole.size(); i++) {
                if (hole[i].x > maxX) {
                    maxX = hole[i].x;
                    holeStart = i;
                }
            }

            // Find visible vertex in merged polygon (ray cast to the right)
            int bridgeIdx = findBridgeVertex(merged, hole[holeStart]);
            if (bridgeIdx < 0) bridgeIdx = 0;

            // Insert hole into merged polygon with bridge edges
            std::vector<Vec2> newMerged;
            newMerged.reserve(merged.size() + hole.size() + 2);

            for (int i = 0; i <= bridgeIdx; i++) {
                newMerged.push_back(merged[i]);
            }
            // Insert hole starting from holeStart, wrapping around
            for (int i = 0; i <= (int)hole.size(); i++) {
                newMerged.push_back(hole[(holeStart + i) % hole.size()]);
            }
            // Bridge back
            newMerged.push_back(merged[bridgeIdx]);
            for (int i = bridgeIdx + 1; i < (int)merged.size(); i++) {
                newMerged.push_back(merged[i]);
            }

            merged = newMerged;
        }

        outVertices = merged;
        return triangulate(merged, outTriangles);
    }

    /**
     * Generate vertices for GL_TRIANGLES directly (interleaved x,y).
     * More efficient than index-based for one-shot rendering.
     */
    static std::vector<float> triangulateToVertices(const std::vector<Vec2>& polygon) {
        std::vector<uint32_t> indices;
        triangulate(polygon, indices);

        std::vector<float> verts;
        verts.reserve(indices.size() * 2);
        for (uint32_t idx : indices) {
            if (idx < polygon.size()) {
                verts.push_back((float)polygon[idx].x);
                verts.push_back((float)polygon[idx].y);
            }
        }
        return verts;
    }

    /**
     * Triangulate a path (polyline with width) into a triangle strip.
     * Supports round and square end caps.
     */
    static std::vector<float> triangulatePath(const std::vector<Vec2>& points,
                                              double width,
                                              bool roundCaps = false,
                                              int capSegments = 8) {
        std::vector<float> verts;
        if (points.size() < 2 || width <= 0) return verts;

        double halfW = width * 0.5;

        // Generate outline of the path
        std::vector<Vec2> outline = pathToOutline(points, halfW, roundCaps ? 1 : 0, capSegments);
        if (outline.size() < 3) return verts;

        return triangulateToVertices(outline);
    }

    /**
     * Tessellate a circle/arc into triangle fan vertices.
     */
    static std::vector<float> triangulateCircle(double cx, double cy, double radius,
                                                 int segments = 32) {
        std::vector<float> verts;
        if (radius <= 0 || segments < 3) return verts;

        verts.reserve((segments + 1) * 2 * 3);  // triangles
        for (int i = 0; i < segments; i++) {
            double a0 = 2.0 * M_PI * i / segments;
            double a1 = 2.0 * M_PI * (i + 1) / segments;

            // Center
            verts.push_back((float)cx);
            verts.push_back((float)cy);
            // Edge point 0
            verts.push_back((float)(cx + radius * std::cos(a0)));
            verts.push_back((float)(cy + radius * std::sin(a0)));
            // Edge point 1
            verts.push_back((float)(cx + radius * std::cos(a1)));
            verts.push_back((float)(cy + radius * std::sin(a1)));
        }
        return verts;
    }

    /**
     * Tessellate a trapezoid (OASIS TRAPEZOID record).
     * Types: horizontal (delta-y top/bottom) or vertical (delta-x left/right).
     */
    static std::vector<float> triangulateTrapezoid(double x, double y,
                                                    double w, double h,
                                                    double deltaA, double deltaB,
                                                    bool horizontal) {
        std::vector<Vec2> poly(4);
        if (horizontal) {
            // Bottom edge at y, top edge at y+h
            // deltaA shifts bottom-left, deltaB shifts bottom-right
            poly[0] = {x + deltaA, y};
            poly[1] = {x + w + deltaB, y};
            poly[2] = {x + w, y + h};
            poly[3] = {x, y + h};
        } else {
            // Left edge at x, right edge at x+w
            poly[0] = {x, y + deltaA};
            poly[1] = {x, y + h + deltaB};
            poly[2] = {x + w, y + h};
            poly[3] = {x + w, y};
        }
        return triangulateToVertices(poly);
    }

    /** 路径中心线 → 外轮廓多边形（DRC/几何检查/导出/GL 条带共用；width 为全宽）
     *  pathType 同 SceneShape::pathType：0=flush 齐平端，1=round 半圆端，2=extended 方端
     *  —— 1/2 端头向外延伸 width/2（GDSII STYPE 0/1 语义）。
     */
    static std::vector<Vec2> pathOutline(const std::vector<Vec2>& points, double width,
                                         int pathType = 0, double beginExtension = 0,
                                         double endExtension = 0) {
        if (points.size() < 2 || !(width > 0)) {
            return {};
        }
        const int capMode = (pathType == 1) ? 1 : (pathType == 2 ? 2 : 0);
        if (pathType == 4) {
            std::vector<Vec2> extended = points;
            size_t first = 1, last = points.size() - 2;
            while (first < points.size() && (points[first] - points.front()).lengthSq() < 1e-24) ++first;
            while (last > 0 && (points.back() - points[last]).lengthSq() < 1e-24) --last;
            if (first >= points.size()) return {};
            const Vec2 beginDir = unitOr(points[first] - points.front(), 1, 0);
            const Vec2 endDir = unitOr(points.back() - points[last], 1, 0);
            extended.erase(extended.begin(), extended.begin() + static_cast<std::ptrdiff_t>(first - 1));
            while (extended.size() > 2 && (extended.back() - extended[extended.size()-2]).lengthSq() < 1e-24) extended.pop_back();
            extended.front() = points.front() - beginDir * beginExtension;
            extended.back() = points.back() + endDir * endExtension;
            return pathToOutline(extended, width * 0.5, 0, 8);
        }
        return pathToOutline(points, width * 0.5, capMode, 8);
    }

private:
    static double computeSignedArea(const std::vector<Vec2>& poly) {
        double area = 0;
        int n = (int)poly.size();
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            area += poly[i].cross(poly[j]);
        }
        return area * 0.5;
    }

    static bool isConvex(const Vec2& a, const Vec2& b, const Vec2& c) {
        return (b - a).cross(c - b) > 0;
    }

    static bool pointInTriangle(const Vec2& p, const Vec2& a, const Vec2& b, const Vec2& c) {
        double d1 = (b - a).cross(p - a);
        double d2 = (c - b).cross(p - b);
        double d3 = (a - c).cross(p - c);
        bool hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
        bool hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
        return !(hasNeg && hasPos);
    }

    [[maybe_unused]] static bool isEar(const std::vector<Vec2>& vertices,
                      const std::vector<int>& indices,
                      int remaining, int idx) {
        int i0 = indices[idx % remaining];
        int i1 = indices[(idx + 1) % remaining];
        int i2 = indices[(idx + 2) % remaining];

        const Vec2& v0 = vertices[i0];
        const Vec2& v1 = vertices[i1];
        const Vec2& v2 = vertices[i2];

        // Must be convex
        if (!isConvex(v0, v1, v2)) return false;

        // No other vertex inside the triangle
        for (int i = 0; i < remaining; i++) {
            int vi = indices[i];
            if (vi == i0 || vi == i1 || vi == i2) continue;
            if (pointInTriangle(vertices[vi], v0, v1, v2)) {
                return false;
            }
        }
        return true;
    }

    static int findBridgeVertex(const std::vector<Vec2>& polygon, const Vec2& holePoint) {
        // Cast ray to the right from holePoint, find closest intersection
        int bestIdx = -1;
        double bestDist = 1e18;

        int n = (int)polygon.size();
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            const Vec2& a = polygon[i];
            const Vec2& b = polygon[j];

            // Check if edge crosses the horizontal ray from holePoint
            if ((a.y <= holePoint.y && b.y > holePoint.y) ||
                (b.y <= holePoint.y && a.y > holePoint.y)) {
                double t = (holePoint.y - a.y) / (b.y - a.y);
                double ix = a.x + t * (b.x - a.x);
                if (ix >= holePoint.x) {
                    double dist = ix - holePoint.x;
                    if (dist < bestDist) {
                        bestDist = dist;
                        // Choose the vertex closer to intersection
                        bestIdx = (std::abs(a.x - ix) < std::abs(b.x - ix)) ? i : j;
                    }
                }
            }
        }

        // Fallback: closest vertex
        if (bestIdx < 0) {
            for (int i = 0; i < n; i++) {
                double d = (polygon[i] - holePoint).lengthSq();
                if (d < bestDist) {
                    bestDist = d;
                    bestIdx = i;
                }
            }
        }
        return bestIdx;
    }

    /** 单位化切向；零长/溢出（极端坐标）时退回给定方向，避免产出 NaN 顶点 */
    static Vec2 unitOr(const Vec2& d, double fx, double fy) {
        const double len = d.length();
        if (!(len > 1e-12) || !std::isfinite(len)) {
            return {fx, fy};
        }
        return d * (1.0 / len);
    }

    /** capMode: 0=butt 齐平, 1=round 半圆端, 2=square 方端（1/2 端头外延 halfW） */
    static std::vector<Vec2> pathToOutline(const std::vector<Vec2>& points,
                                            double halfW, int capMode,
                                            int capSegments) {
        // 剔除连续重合/非有限顶点：GDS 中心线常带重复点，重复点会让该处切向退化
        // 成 (0,0) 兜底方向，在轮廓上打出一个假尖角。
        std::vector<Vec2> pts;
        pts.reserve(points.size());
        for (const auto& p : points) {
            if (!std::isfinite(p.x) || !std::isfinite(p.y)) continue;
            if (!pts.empty() && std::fabs(p.x - pts.back().x) <= 1e-12 &&
                std::fabs(p.y - pts.back().y) <= 1e-12) {
                continue;
            }
            pts.push_back(p);
        }

        const int n = (int)pts.size();
        if (n < 2 || !(halfW > 0) || !std::isfinite(halfW)) {
            return {};
        }

        std::vector<Vec2> left, right, dirs;
        left.reserve(n);
        right.reserve(n);
        dirs.reserve(n);
        for (int i = 0; i < n; i++) {
            Vec2 dir;
            double offsetLength = halfW;
            if (i == 0) {
                dir = pts[1] - pts[0];
            } else if (i == n - 1) {
                dir = pts[i] - pts[i - 1];
            } else {
                const Vec2 incoming = unitOr(pts[i] - pts[i - 1], 1, 0);
                const Vec2 outgoing = unitOr(pts[i + 1] - pts[i], incoming.x, incoming.y);
                dir = unitOr(incoming + outgoing, outgoing.x, outgoing.y);
                const double cosine = dir.x * incoming.x + dir.y * incoming.y;
                if (std::abs(cosine) > 1e-12) offsetLength = halfW / cosine;
            }
            dir = unitOr(dir, 1.0, 0.0);

            // Normal (perpendicular)
            Vec2 normal = {-dir.y, dir.x};

            left.push_back(pts[i] + normal * offsetLength);
            right.push_back(pts[i] - normal * offsetLength);
            dirs.push_back(dir);
        }

        // Build outline: left side forward, right side backward
        std::vector<Vec2> outline;
        const int segs = std::max(2, capSegments);
        outline.reserve(n * 2 + (capMode == 1 ? segs * 2 : 2));

        if (capMode == 1) {
            // 起始半圆：从 right[0] 经 -dir 外侧扫到 left[0]（顺时针，角度递减）
            double a0 = std::atan2(-dirs[0].x, dirs[0].y);
            for (int i = 0; i <= segs; i++) {
                double a = a0 - M_PI * i / segs;
                outline.push_back(pts[0] + Vec2{std::cos(a), std::sin(a)} * halfW);
            }
        } else if (capMode == 2) {
            outline.push_back(left[0] - dirs[0] * halfW);
        }

        // Left side
        for (int i = 0; i < n; i++) {
            outline.push_back(left[i]);
        }

        if (capMode == 1) {
            // 终止半圆：从 left[n-1] 经 +dir 外侧扫到 right[n-1]
            const Vec2& de = dirs[n - 1];
            double a0 = std::atan2(de.x, -de.y);
            for (int i = 0; i <= segs; i++) {
                double a = a0 - M_PI * i / segs;
                outline.push_back(pts[n - 1] + Vec2{std::cos(a), std::sin(a)} * halfW);
            }
        } else if (capMode == 2) {
            const Vec2 ext = dirs[n - 1] * halfW;
            outline.push_back(left[n - 1] + ext);
            outline.push_back(right[n - 1] + ext);
        }

        // Right side (reversed)
        for (int i = n - 1; i >= 0; i--) {
            outline.push_back(right[i]);
        }

        if (capMode == 2) {
            outline.push_back(right[0] - dirs[0] * halfW);
        }

        return outline;
    }
};

} // namespace hongtu

#endif // HONGTU_TRIANGULATOR_H
