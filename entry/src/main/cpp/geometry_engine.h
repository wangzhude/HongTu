/**
 * HongTu EDA - Geometry Engine
 * Core computational geometry: boolean operations (vendored Clipper2),
 * polygon offset, true edge-to-edge distance, intersection detection,
 * convex hull, and affine transforms.
 */
#ifndef HONGTU_GEOMETRY_ENGINE_H
#define HONGTU_GEOMETRY_ENGINE_H

#include "triangulator.h"
#include "spatial_index.h"
#include "clipper_engine.h"   // clipper::GeneralClipper — booleanOp()/mergePolygons() 后端
#include <vector>
#include <cmath>
#include <algorithm>
#include <cstdint>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace hongtu {

/**
 * Integer-based polygon representation for exact boolean operations.
 * Coordinates in database units (typically nm or 0.1nm).
 */
using IntPoint = struct { int64_t x, y; };
using IntPath = std::vector<IntPoint>;
using IntPaths = std::vector<IntPath>;

enum class ClipType { INTERSECTION, UNION, DIFFERENCE, XOR };
enum class JoinType { SQUARE, ROUND, MITER };
enum class EndType { CLOSED, BUTT, SQUARE, ROUND };

/**
 * GeometryEngine: static utility class for all geometric computations.
 */
class GeometryEngine {
public:
    // ==================== Point-in-Polygon ====================

    /**
     * Ray-casting point-in-polygon test.
     * Returns: +1 inside, -1 outside, 0 on boundary.
     */
    static int pointInPolygon(const Vec2& point, const std::vector<Vec2>& polygon) {
        int n = (int)polygon.size();
        if (n < 3) return -1;

        bool inside = false;
        for (int i = 0, j = n - 1; i < n; j = i++) {
            const Vec2& vi = polygon[i];
            const Vec2& vj = polygon[j];

            // Check if point is on edge
            if (pointOnSegment(point, vi, vj, 1e-9)) return 0;

            if ((vi.y > point.y) != (vj.y > point.y)) {
                double xIntersect = vi.x + (point.y - vi.y) / (vj.y - vi.y) * (vj.x - vi.x);
                if (point.x < xIntersect) {
                    inside = !inside;
                }
            }
        }
        return inside ? 1 : -1;
    }

    // ==================== Distance Calculations ====================

    static double pointToSegmentDistance(const Vec2& p, const Vec2& a, const Vec2& b) {
        Vec2 ab = b - a;
        Vec2 ap = p - a;
        double lenSq = ab.lengthSq();
        if (lenSq < 1e-18) return ap.length();

        double t = std::max(0.0, std::min(1.0, ap.dot(ab) / lenSq));
        Vec2 projection = a + ab * t;
        return (p - projection).length();
    }

    static double pointToPolygonDistance(const Vec2& p, const std::vector<Vec2>& polygon) {
        double minDist = 1e18;
        int n = (int)polygon.size();
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            minDist = std::min(minDist, pointToSegmentDistance(p, polygon[i], polygon[j]));
        }
        return minDist;
    }

    /**
     * True edge-to-edge distance between two polygons.
     * Returns 0 if they overlap.
     */
    static double polygonToPolygonDistance(const std::vector<Vec2>& polyA,
                                           const std::vector<Vec2>& polyB) {
        // Quick reject: bbox distance
        BBox bboxA = computeBBox(polyA);
        BBox bboxB = computeBBox(polyB);
        double bboxDist = bboxA.distanceTo(bboxB);
        if (bboxDist > 0) {
            // BBoxes don't overlap, but we still need edge-edge check
            // for accuracy (bbox distance is a lower bound)
        }

        // Check if any vertex of A is inside B or vice versa
        if (!polyA.empty() && pointInPolygon(polyA[0], polyB) >= 0) return 0.0;
        if (!polyB.empty() && pointInPolygon(polyB[0], polyA) >= 0) return 0.0;

        // Edge-edge minimum distance
        double minDist = 1e18;
        int nA = (int)polyA.size();
        int nB = (int)polyB.size();

        for (int i = 0; i < nA; i++) {
            int i2 = (i + 1) % nA;
            for (int j = 0; j < nB; j++) {
                int j2 = (j + 1) % nB;
                double d = segmentToSegmentDistance(polyA[i], polyA[i2], polyB[j], polyB[j2]);
                minDist = std::min(minDist, d);
                if (minDist < 1e-12) return 0.0;
            }
        }
        return minDist;
    }

    static double segmentToSegmentDistance(const Vec2& p1, const Vec2& p2,
                                           const Vec2& q1, const Vec2& q2) {
        // Check intersection first
        if (segmentsIntersect(p1, p2, q1, q2)) return 0.0;

        double d1 = pointToSegmentDistance(p1, q1, q2);
        double d2 = pointToSegmentDistance(p2, q1, q2);
        double d3 = pointToSegmentDistance(q1, p1, p2);
        double d4 = pointToSegmentDistance(q2, p1, p2);

        return std::min({d1, d2, d3, d4});
    }

    // ==================== Intersection Tests ====================

    static bool segmentsIntersect(const Vec2& a, const Vec2& b,
                                  const Vec2& c, const Vec2& d) {
        double d1 = cross(c, d, a);
        double d2 = cross(c, d, b);
        double d3 = cross(a, b, c);
        double d4 = cross(a, b, d);

        if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
            ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) {
            return true;
        }

        if (std::abs(d1) < 1e-12 && onSegment(c, d, a)) return true;
        if (std::abs(d2) < 1e-12 && onSegment(c, d, b)) return true;
        if (std::abs(d3) < 1e-12 && onSegment(a, b, c)) return true;
        if (std::abs(d4) < 1e-12 && onSegment(a, b, d)) return true;

        return false;
    }

    /**
     * Test if two polygons intersect (overlap or touch).
     */
    static bool polygonsIntersect(const std::vector<Vec2>& polyA,
                                  const std::vector<Vec2>& polyB) {
        // Quick bbox reject
        BBox bboxA = computeBBox(polyA);
        BBox bboxB = computeBBox(polyB);
        if (!bboxA.intersects(bboxB)) return false;

        // Check containment
        if (!polyA.empty() && pointInPolygon(polyA[0], polyB) >= 0) return true;
        if (!polyB.empty() && pointInPolygon(polyB[0], polyA) >= 0) return true;

        // Check edge intersections
        int nA = (int)polyA.size();
        int nB = (int)polyB.size();
        for (int i = 0; i < nA; i++) {
            int i2 = (i + 1) % nA;
            for (int j = 0; j < nB; j++) {
                int j2 = (j + 1) % nB;
                if (segmentsIntersect(polyA[i], polyA[i2], polyB[j], polyB[j2])) {
                    return true;
                }
            }
        }
        return false;
    }

    // ==================== Polygon Area & Properties ====================

    static double polygonArea(const std::vector<Vec2>& polygon) {
        double area = 0;
        int n = (int)polygon.size();
        if (n < 3) return 0;
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            area += (polygon[i] - polygon[0]).cross(polygon[j] - polygon[0]);
        }
        return std::abs(area) * 0.5;
    }

    static Vec2 polygonCentroid(const std::vector<Vec2>& polygon) {
        double cx = 0, cy = 0, area = 0;
        int n = (int)polygon.size();
        if (n == 0) {
            return {0, 0};  // 空多边形：避免后续 avg/=n 除零得 NaN
        }
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            const Vec2 a = polygon[i] - polygon[0], b = polygon[j] - polygon[0];
            double cross = a.cross(b);
            cx += (a.x + b.x) * cross;
            cy += (a.y + b.y) * cross;
            area += cross;
        }
        area *= 0.5;
        if (std::abs(area) < 1e-18) {
            // Degenerate: return average of points
            Vec2 avg;
            for (const auto& p : polygon) { avg.x += p.x; avg.y += p.y; }
            avg.x /= n; avg.y /= n;
            return avg;
        }
        cx /= (6.0 * area);
        cy /= (6.0 * area);
        return {cx + polygon[0].x, cy + polygon[0].y};
    }

    static BBox computeBBox(const std::vector<Vec2>& polygon) {
        BBox box;
        for (const auto& p : polygon) {
            box.minX = std::min(box.minX, p.x);
            box.minY = std::min(box.minY, p.y);
            box.maxX = std::max(box.maxX, p.x);
            box.maxY = std::max(box.maxY, p.y);
        }
        return box;
    }

    // ==================== Polygon Offset (Size/Shrink) ====================

    /**
     * Offset a polygon by delta (positive = grow, negative = shrink).
     * Uses miter join with configurable limit.
     */
    // Compatibility API returns the largest contour. Call offsetPolygons for
    // shrink operations that can split material or for outputs containing holes.
    static std::vector<Vec2> offsetPolygon(const std::vector<Vec2>& polygon,
                                            double delta, JoinType join = JoinType::MITER,
                                            double miterLimit = 2.0, int arcSegments = 16) {
        auto contours = offsetPolygons(polygon, delta, join, miterLimit, arcSegments);
        return contours.empty() ? std::vector<Vec2>{} : contours.front();
    }

    static std::vector<std::vector<Vec2>> offsetPolygons(const std::vector<Vec2>& polygon,
                                            double delta, JoinType join = JoinType::MITER,
                                            double miterLimit = 2.0, int arcSegments = 16) {
        clipper::Path path;
        for (const auto& p : polygon) {
            if (!std::isfinite(p.x) || !std::isfinite(p.y) ||
                std::abs(p.x) > clipper::GeneralClipper::kCoordLimit ||
                std::abs(p.y) > clipper::GeneralClipper::kCoordLimit) return {};
            path.push_back({std::llround(p.x), std::llround(p.y)});
        }
        const auto jt = join == JoinType::ROUND ? clipper::JoinType::ROUND :
                        join == JoinType::SQUARE ? clipper::JoinType::SQUARE : clipper::JoinType::MITER;
        const double tolerance = arcSegments > 2 ?
            std::abs(delta) * (1 - std::cos(M_PI / std::max(3, arcSegments))) : 0;
        const auto out = clipper::GeneralClipper::offset({path}, delta, jt,
            clipper::EndType::POLYGON, miterLimit, tolerance);
        std::vector<std::vector<Vec2>> result;
        for (const auto& ring : out.contours) {
            std::vector<Vec2> contour;
            for (const auto& p : ring) contour.push_back({(double)p.x, (double)p.y});
            result.push_back(std::move(contour));
        }
        return result;
    }

    // ==================== Convex Hull ====================

    static std::vector<Vec2> convexHull(std::vector<Vec2> points) {
        int n = (int)points.size();
        if (n < 3) return points;

        std::sort(points.begin(), points.end(), [](const Vec2& a, const Vec2& b) {
            return a.x < b.x || (a.x == b.x && a.y < b.y);
        });

        std::vector<Vec2> hull(2 * n);
        int k = 0;

        // Lower hull
        for (int i = 0; i < n; i++) {
            while (k >= 2 && cross(hull[k-2], hull[k-1], points[i]) <= 0) k--;
            hull[k++] = points[i];
        }

        // Upper hull
        int lower_size = k + 1;
        for (int i = n - 2; i >= 0; i--) {
            while (k >= lower_size && cross(hull[k-2], hull[k-1], points[i]) <= 0) k--;
            hull[k++] = points[i];
        }

        hull.resize(k - 1);
        return hull;
    }

    // ==================== Polygon Boolean Operations ====================
    // Integer-DBU clipping through the vendored Clipper2 adapter.

    /**
     * Boolean operation on two polygons.
     *
     * Delegates to the Clipper2-backed GeneralClipper adapter in clipper_engine.h.
     *
     * Coordinates are rounded to the integer DBU lattice the engine works on;
     * `exact` reports accepted input and completed execution. DBU quantization
     * still applies; this flag is not a manufacturing or sign-off certificate.
     */
    struct BooleanResult {
        std::vector<std::vector<Vec2>> polygons;
        bool exact;        // false → degenerate input / non-finite coordinates
        bool empty() const { return polygons.empty(); }
    };

    static BooleanResult booleanOp(const std::vector<Vec2>& subject,
                                   const std::vector<Vec2>& clip,
                                   ClipType op) {
        BooleanResult result;
        result.exact = true;

        auto toIntPath = [&result](const std::vector<Vec2>& src) {
            clipper::Path p;
            for (const Vec2& v : src) {
                if (!std::isfinite(v.x) || !std::isfinite(v.y) ||
                    std::abs(v.x) > clipper::GeneralClipper::kCoordLimit ||
                    std::abs(v.y) > clipper::GeneralClipper::kCoordLimit) {
                    result.exact = false; return clipper::Path{};
                }
                p.push_back({(int64_t)std::llround(v.x), (int64_t)std::llround(v.y)});
            }
            return p;
        };
        clipper::Paths subj, clp;
        const clipper::Path sp = toIntPath(subject);
        const clipper::Path cp = toIntPath(clip);
        if (sp.size() >= 3) subj.push_back(sp);
        if (cp.size() >= 3) clp.push_back(cp);
        if (!result.exact) return result;

        const clipper::GeneralClipper::Output out =
            clipper::GeneralClipper::execute(subj, clp, static_cast<clipper::ClipType>(op));
        result.exact = result.exact && !out.approximated;
        for (const clipper::Path& c : out.contours) {
            std::vector<Vec2> poly;
            poly.reserve(c.size());
            for (const clipper::IntPoint& p : c) poly.push_back({(double)p.x, (double)p.y});
            if (poly.size() >= 3) result.polygons.push_back(std::move(poly));
        }
        return result;
    }

    /** Multi-contour union used by the merged-region DRC path (see drc_engine.h). */
    static BooleanResult mergePolygons(const std::vector<std::vector<Vec2>>& polys) {
        BooleanResult result;
        result.exact = true;
        clipper::Paths set;
        for (const auto& src : polys) {
            clipper::Path p;
            for (const Vec2& v : src) {
                if (!std::isfinite(v.x) || !std::isfinite(v.y) ||
                    std::abs(v.x) > clipper::GeneralClipper::kCoordLimit ||
                    std::abs(v.y) > clipper::GeneralClipper::kCoordLimit) {
                    result.exact = false; return result;
                }
                p.push_back({(int64_t)std::llround(v.x), (int64_t)std::llround(v.y)});
            }
            if (p.size() >= 3) set.push_back(p);
        }
        const clipper::GeneralClipper::Output out = clipper::GeneralClipper::unite(set);
        result.exact = result.exact && !out.approximated;
        for (const clipper::Path& c : out.contours) {
            std::vector<Vec2> poly;
            poly.reserve(c.size());
            for (const clipper::IntPoint& p : c) poly.push_back({(double)p.x, (double)p.y});
            if (poly.size() >= 3) result.polygons.push_back(std::move(poly));
        }
        return result;
    }

    // ==================== Affine Transforms ====================

    struct Transform2D {
        // 3x3 affine matrix (row-major): [a b tx; c d ty; 0 0 1]
        double a = 1, b = 0, tx = 0;
        double c = 0, d = 1, ty = 0;

        static Transform2D identity() { return {}; }

        static Transform2D translation(double dx, double dy) {
            Transform2D t;
            t.tx = dx; t.ty = dy;
            return t;
        }

        static Transform2D rotation(double angleDeg) {
            double rad = angleDeg * M_PI / 180.0;
            double cosA = std::cos(rad), sinA = std::sin(rad);
            Transform2D t;
            t.a = cosA; t.b = -sinA;
            t.c = sinA; t.d = cosA;
            return t;
        }

        static Transform2D scaling(double sx, double sy) {
            Transform2D t;
            t.a = sx; t.d = sy;
            return t;
        }

        static Transform2D mirrorX() {
            Transform2D t;
            t.d = -1;
            return t;
        }

        static Transform2D mirrorY() {
            Transform2D t;
            t.a = -1;
            return t;
        }

        Transform2D multiply(const Transform2D& o) const {
            Transform2D r;
            r.a = a * o.a + b * o.c;
            r.b = a * o.b + b * o.d;
            r.tx = a * o.tx + b * o.ty + tx;
            r.c = c * o.a + d * o.c;
            r.d = c * o.b + d * o.d;
            r.ty = c * o.tx + d * o.ty + ty;
            return r;
        }

        Vec2 apply(const Vec2& p) const {
            return {a * p.x + b * p.y + tx, c * p.x + d * p.y + ty};
        }

        std::vector<Vec2> applyToPolygon(const std::vector<Vec2>& poly) const {
            std::vector<Vec2> result;
            result.reserve(poly.size());
            for (const auto& p : poly) {
                result.push_back(apply(p));
            }
            return result;
        }

        double determinant() const { return a * d - b * c; }

        Transform2D inverse() const {
            double det = determinant();
            if (std::abs(det) < 1e-18) return identity();
            double invDet = 1.0 / det;
            Transform2D r;
            r.a = d * invDet;
            r.b = -b * invDet;
            r.c = -c * invDet;
            r.d = a * invDet;
            r.tx = -(r.a * tx + r.b * ty);
            r.ty = -(r.c * tx + r.d * ty);
            return r;
        }
    };

    // ==================== Width/Spacing Measurement ====================

    /**
     * 合并区域（region-on-left 轮廓集：外轮廓 + 孔）的最小宽度。
     *
     * 逐图形口径用的 measureMinWidth() 走**凸包**，对凹形/合并后的区域天然失效
     * （三根条拼出的 neck 在凸包上被填平），所以合并区域必须换度量。本函数取两类
     * 候选的最小值：
     *   (1) 面对面（反平行 + 投影重叠 + 不相邻）的边对之间的垂距 —— 直通道/细腰的
     *       精确宽度；同向平行的边对被排除（它们分属两条臂，不是宽度）。
     *   (2) 从每个顶点与每条边中点沿**内法线**发射的射线到边界的首个命中距离 ——
     *       覆盖非平行的收窄（射线方向上的截线可能斜切，故这是一致偏大的近似）。
     * Rectilinear public-rule fixtures are compared with KLayout width_check.
     * Arbitrary-angle width is still a sampling pre-check, not a rule-deck match.
     * 复杂度 O(E²)：顶点数超过 kRegionWidthVertexCap 时退化为 measureMinWidth 并在
     * out 参数上回报 capped=true，调用方必须如实标注。
     */
    static constexpr int kRegionWidthVertexCap = 1500;

    static double measureRegionMinWidth(const std::vector<std::vector<Vec2>>& contours,
                                         bool* capped = nullptr) {
        if (capped) *capped = false;
        struct Seg { Vec2 a, b; int ring; };
        auto same = [](const Vec2& p, const Vec2& q) { return p.x == q.x && p.y == q.y; };

        std::vector<Seg> segs;
        for (size_t ci = 0; ci < contours.size(); ++ci) {
            const std::vector<Vec2>& c = contours[ci];
            const int n = (int)c.size();
            if (n < 3) continue;
            for (int i = 0; i < n; ++i) segs.push_back({c[i], c[(i + 1) % n], (int)ci});
        }
        if ((int)segs.size() > kRegionWidthVertexCap) {
            if (capped) *capped = true;
            std::vector<Vec2> all;
            for (const Seg& s : segs) { all.push_back(s.a); all.push_back(s.b); }
            return measureMinWidth(all);
        }
        if (segs.empty()) return 0;
        const bool rectilinear = std::all_of(segs.begin(), segs.end(), [](const Seg& s) {
            return s.a.x == s.b.x || s.a.y == s.b.y;
        });

        auto adjacent = [&same](const Seg& s, const Seg& t) {
            return same(s.a, t.a) || same(s.a, t.b) || same(s.b, t.a) || same(s.b, t.b);
        };
        auto touches = [&same](const Vec2& p, const Seg& s) {
            return same(p, s.a) || same(p, s.b);
        };

        double best = 1e18;

        auto inRegion = [&contours](const Vec2& p) {
            int n = 0;
            for (const std::vector<Vec2>& c : contours) {
                if (c.size() >= 3 && pointInPolygon(p, c) >= 0) n++;
            }
            return (n & 1) != 0;
        };

        // (1) facing (antiparallel, projection-overlapping) edge pairs whose connector
        //     actually runs THROUGH material — otherwise the "gap" is an exterior slot
        //     (a U's pocket, the space between two tabs) and is not a width at all.
        for (size_t i = 0; i < segs.size(); ++i) {
            const Vec2 ui = segs[i].b - segs[i].a;
            const double li = ui.length();
            if (li < 1e-12) continue;
            const Vec2 ni{ -ui.y / li, ui.x / li };          // unit normal of i
            for (size_t j = i + 1; j < segs.size(); ++j) {
                const Vec2 uj = segs[j].b - segs[j].a;
                const double lj = uj.length();
                if (lj < 1e-12) continue;
                if (std::fabs(ui.cross(uj)) > 1e-6 * li * lj) continue;      // not parallel
                if (ui.dot(uj) >= 0) continue;                               // same way → not facing
                if (adjacent(segs[i], segs[j])) continue;
                const double d = std::fabs(ui.cross(segs[j].a - segs[i].a)) / li;
                if (d >= best) continue;                                     // cannot win anyway
                // Overlap of the two projections measured ON EDGE i's span [0, li].
                const Vec2 v = segs[j].a - segs[i].a;
                const double p0 = v.dot(ui) / li;
                const double p1 = (v + uj).dot(ui) / li;
                const double lo = std::max(std::min(p0, p1), 0.0);
                const double hi = std::min(std::max(p0, p1), li);
                Vec2 from, to;
                if (hi > lo + 1e-9) {
                    from = segs[i].a + ui * ((lo + hi) * 0.5 / li);
                    to = from + ni * ((segs[j].a-from).dot(ni));
                } else {
                    // Euclidean corner-to-corner width in an oblique neck made
                    // from Manhattan shapes. Projection-only tests miss this.
                    double nearest = 1e18;
                    for (const Vec2& a : {segs[i].a,segs[i].b})
                        for (const Vec2& b : {segs[j].a,segs[j].b})
                            if ((a-b).lengthSq() < nearest) {nearest=(a-b).lengthSq();from=a;to=b;}
                }
                const Vec2 connector=to-from;
                const double distance=connector.length();
                // Both left normals must point INTO the connector. Merely
                // finding material at its midpoint can measure across a notch.
                const Vec2 nj{-uj.y/lj,uj.x/lj};
                if(ni.dot(connector) <= 1e-9 || nj.dot(connector*-1.0) <= 1e-9) continue;
                const Vec2 probe=(from+to)*0.5;
                if (!inRegion(probe)) continue;
                best = std::min(best, distance);
            }
        }
        // For Manhattan polygons the facing-edge measurement is complete.
        // Corner rays across reflex vertices can leave the material and create
        // false narrow widths; they are only a fallback for oblique boundaries.
        if (rectilinear) return best >= 1e17 ? 0.0 : best;

        // (2) inward ray casts: edge normal at the midpoint and at both ends
        auto rayHit = [&segs, &touches](const Vec2& o, const Vec2& dir, int skip) {
            double hit = 1e18;
            for (size_t si = 0; si < segs.size(); ++si) {
                if ((int)si == skip) continue;
                const Seg& s = segs[si];
                if (touches(o, s)) continue;              // adjacent: trivially distance 0
                const Vec2 e = s.b - s.a;
                const double den = dir.cross(e);
                if (std::fabs(den) < 1e-12) continue;     // ray parallel to the edge
                const Vec2 w = s.a - o;
                const double t = w.cross(e) / den;        // distance along the ray
                const double u = w.cross(dir) / den;      // position along the segment
                if (t > 1e-9 && u >= 0.0 && u <= 1.0) hit = std::min(hit, t);
            }
            return hit;
        };
        for (size_t i = 0; i < segs.size(); ++i) {
            const Vec2 u = segs[i].b - segs[i].a;
            const double len = u.length();
            if (len < 1e-12) continue;
            const Vec2 nrm{ -u.y / len, u.x / len };      // region lies to the LEFT
            const Vec2 mid{ (segs[i].a.x + segs[i].b.x) * 0.5,
                            (segs[i].a.y + segs[i].b.y) * 0.5 };
            best = std::min(best, rayHit(mid, nrm, (int)i));
            best = std::min(best, rayHit(segs[i].a, nrm, (int)i));
            best = std::min(best, rayHit(segs[i].b, nrm, (int)i));
        }
        // (3) corner bisector rays: the narrow section of an oblique neck sits at a corner
        for (size_t i = 0; i < segs.size(); ++i) {
            const size_t prev = (i == 0) ? segs.size() - 1 : i - 1;
            if (segs[prev].ring != segs[i].ring) continue;
            if (!same(segs[prev].b, segs[i].a)) continue;   // not consecutive in that ring
            const Vec2 u0 = segs[prev].b - segs[prev].a;
            const Vec2 u1 = segs[i].b - segs[i].a;
            const double l0 = u0.length(), l1 = u1.length();
            if (l0 < 1e-12 || l1 < 1e-12) continue;
            Vec2 bis{ -u0.y / l0 - u1.y / l1, u0.x / l0 + u1.x / l1 };
            const double bl = bis.length();
            if (bl < 1e-9) continue;                        // 180° reversal: no bisector
            bis = bis * (1.0 / bl);
            best = std::min(best, rayHit(segs[i].a, bis, -1));
        }
        return best >= 1e17 ? 0.0 : best;
    }

    // Minimum empty-space gap within one connected region, including slots and
    // holes. Edge normals must face away from the connector (material is LEFT).
    // Shared corners are excluded: an ordinary polygon corner is not a notch.
    static double measureRegionMinSpacing(const std::vector<std::vector<Vec2>>& contours,
                                           bool* capped = nullptr) {
        if (capped) *capped = false;
        struct Seg { Vec2 a, b; };
        std::vector<Seg> edges;
        for (const auto& p : contours) for (size_t i = 0; i < p.size(); ++i)
            edges.push_back({p[i], p[(i+1)%p.size()]});
        if (edges.size() > static_cast<size_t>(kRegionWidthVertexCap)) {
            if (capped) *capped = true;
            return 1e18;
        }
        auto same = [](const Vec2& a, const Vec2& b) { return a.x == b.x && a.y == b.y; };
        auto projection = [](const Vec2& p, const Seg& e) {
            const Vec2 u = e.b-e.a;
            const double t = std::clamp((p-e.a).dot(u) / u.lengthSq(), 0.0, 1.0);
            return e.a + u*t;
        };
        double best = 1e18;
        for (size_t i = 0; i < edges.size(); ++i) for (size_t j = i+1; j < edges.size(); ++j) {
            const auto& a = edges[i]; const auto& b = edges[j];
            if (same(a.a,b.a)||same(a.a,b.b)||same(a.b,b.a)||same(a.b,b.b)) continue;
            const Vec2 u = a.b-a.a, v = b.b-b.a;
            const double lu = u.length(), lv = v.length();
            if (lu < 1e-12 || lv < 1e-12) continue;
            Vec2 p, q;
            if (std::abs(u.cross(v)) < 1e-9*lu*lv) {
                const double x0 = (b.a-a.a).dot(u)/lu, x1 = (b.b-a.a).dot(u)/lu;
                const double lo = std::max(0.0,std::min(x0,x1)), hi=std::min(lu,std::max(x0,x1));
                if (hi > lo) { p = a.a + u*((lo+hi)*0.5/lu); q = projection(p,b); }
                else {
                    double nearest=1e18;
                    for(const Vec2& x:{a.a,a.b}) for(const Vec2& y:{b.a,b.b})
                        if((x-y).lengthSq()<nearest){nearest=(x-y).lengthSq();p=x;q=y;}
                }
            } else {
                double nearest = 1e18;
                auto consider = [&](const Vec2& x, const Vec2& y) {
                    const double d=(x-y).lengthSq(); if(d<nearest){nearest=d;p=x;q=y;}
                };
                consider(a.a,projection(a.a,b)); consider(a.b,projection(a.b,b));
                consider(projection(b.a,a),b.a); consider(projection(b.b,a),b.b);
            }
            const Vec2 d=q-p;
            const double distance=d.length();
            if(distance < 1e-9 || distance >= best) continue;
            if(Vec2{-u.y/lu,u.x/lu}.dot(d) >= -1e-9 ||
               Vec2{-v.y/lv,v.x/lv}.dot(d*-1.0) >= -1e-9) continue;
            const Vec2 mid=(p+q)*0.5;
            int inside=0;
            for(const auto& ring:contours) if(pointInPolygon(mid,ring)>=0) ++inside;
            if(inside%2 == 0) best=distance;
        }
        return best;
    }

    /**
     * 两个区域（各自为 region-on-left 轮廓集：外轮廓 + 孔）之间的最小**边界到边界**
     * 距离 = 全部轮廓两两的边到边距离最小值。
     *
     * 不能用 polygonToPolygonDistance：它把「一个多边形包含另一个」判成距离 0，
     * 于是「湖中的岛」会被报成 0 间距（假违例），而 A 的外轮廓包住 B 时也一样。
     * 不同区域的轮廓互不相交，故纯边到边即为真实间距。
     */
    static double regionToRegionDistance(const std::vector<std::vector<Vec2>>& a,
                                        const std::vector<std::vector<Vec2>>& b) {
        double best = 1e18;
        for (const auto& ca : a) {
            const int na = (int)ca.size();
            if (na < 3) continue;
            for (const auto& cb : b) {
                const int nb = (int)cb.size();
                if (nb < 3) continue;
                for (int i = 0; i < na; ++i) {
                    const int i2 = (i + 1) % na;
                    for (int j = 0; j < nb; ++j) {
                        const int j2 = (j + 1) % nb;
                        best = std::min(best, segmentToSegmentDistance(
                                                 ca[i], ca[i2], cb[j], cb[j2]));
                    }
                }
            }
        }
        return best >= 1e17 ? 0.0 : best;
    }

    /**
     * 区域的真实面积：必须按**有符号** shoelace 求和（外轮廓正、孔负），最后取绝对值。
     * 不能用 polygonArea()——它返回绝对值，于是孔会被当成实材料加回去
     * （140x140 方框 + 60x60 孔会得到 19600+3600=23200 而不是 16000）。
     */
    static double regionArea(const std::vector<std::vector<Vec2>>& contours) {
        double acc = 0;
        for (const auto& c : contours) {
            const int n = (int)c.size();
            double a = 0;
            for (int i = 0; i < n; ++i) {
                const int j = (i + 1) % n;
                a += (c[i]-c[0]).cross(c[j]-c[0]);
            }
            acc += a * 0.5;
        }
        return std::fabs(acc);
    }

    /**
     * Measure minimum width of a polygon (minimum edge-to-opposite-edge distance).
     * Uses rotating calipers on convex hull for convex polygons,
     * sampling for concave.
     *
     * ⚠ 凸包口径：对凹形与合并区域会**系统性偏大**（凹口/细腰被凸包填平）。
     *   合并区域请改用 measureRegionMinWidth()。
     */
    static double measureMinWidth(const std::vector<Vec2>& polygon) {
        if (polygon.size() < 3) return 0;

        auto hull = convexHull(polygon);
        int n = (int)hull.size();
        if (n < 3) return 0;

        double minWidth = 1e18;

        // For each edge, find minimum distance from opposite vertices
        for (int i = 0; i < n; i++) {
            int j = (i + 1) % n;
            Vec2 edge = hull[j] - hull[i];
            double edgeLen = edge.length();
            if (edgeLen < 1e-12) continue;

            Vec2 normal = {-edge.y / edgeLen, edge.x / edgeLen};

            double minProj = 1e18, maxProj = -1e18;
            for (int k = 0; k < n; k++) {
                // 投影全部顶点：边端点 i、j 投影为 0（宽度基线），不可跳过，
                // 否则三角形每条边只剩一个对顶点 → minProj==maxProj → 宽度恒 0。
                double proj = (hull[k] - hull[i]).dot(normal);
                minProj = std::min(minProj, proj);
                maxProj = std::max(maxProj, proj);
            }

            double width = maxProj - minProj;
            minWidth = std::min(minWidth, std::abs(width));
        }

        return minWidth;
    }

    // ==================== Utility ====================

    static bool isRect(const std::vector<Vec2>& poly) {
        if (poly.size() != 4 && poly.size() != 5) return false;
        int n = (poly.size() == 5 &&
                 std::abs(poly[0].x - poly[4].x) < 1e-9 &&
                 std::abs(poly[0].y - poly[4].y) < 1e-9) ? 4 : (int)poly.size();
        if (n != 4) return false;

        // Check all angles are 90 degrees
        for (int i = 0; i < 4; i++) {
            Vec2 e1 = poly[(i+1)%4] - poly[i];
            Vec2 e2 = poly[(i+2)%4] - poly[(i+1)%4];
            if (std::abs(e1.dot(e2)) > 1e-6 * e1.length() * e2.length()) return false;
        }
        return true;
    }

    static bool pointOnSegment(const Vec2& p, const Vec2& a, const Vec2& b, double eps) {
        double cross = (p - a).cross(b - a);
        if (std::abs(cross) > eps) return false;
        double dot = (p - a).dot(b - a);
        double lenSq = (b - a).lengthSq();
        return dot >= -eps && dot <= lenSq + eps;
    }

private:
    static double cross(const Vec2& o, const Vec2& a, const Vec2& b) {
        return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
    }

    static bool onSegment(const Vec2& a, const Vec2& b, const Vec2& p) {
        return std::min(a.x, b.x) <= p.x && p.x <= std::max(a.x, b.x) &&
               std::min(a.y, b.y) <= p.y && p.y <= std::max(a.y, b.y);
    }

    static std::vector<Vec2> bboxToPolygon(const BBox& box) {
        return {{box.minX, box.minY}, {box.maxX, box.minY},
                {box.maxX, box.maxY}, {box.minX, box.maxY}};
    }

    static std::vector<std::vector<Vec2>> rectBoolean(const std::vector<Vec2>& s,
                                                      const std::vector<Vec2>& c,
                                                      ClipType op) {
        BBox bs = computeBBox(s);
        BBox bc = computeBBox(c);
        std::vector<std::vector<Vec2>> result;

        switch (op) {
            case ClipType::INTERSECTION: {
                BBox inter(
                    std::max(bs.minX, bc.minX), std::max(bs.minY, bc.minY),
                    std::min(bs.maxX, bc.maxX), std::min(bs.maxY, bc.maxY)
                );
                if (inter.valid()) result.push_back(bboxToPolygon(inter));
                break;
            }
            case ClipType::UNION: {
                // Rect union may produce L/T shapes - approximate with bbox
                BBox united = bs.unite(bc);
                result.push_back(bboxToPolygon(united));
                break;
            }
            case ClipType::DIFFERENCE: {
                // Simple case: if clip fully inside subject, create hole
                // Otherwise return subject (approximation)
                if (!bs.intersects(bc)) {
                    result.push_back(s);
                } else if (bc.contains(bs)) {
                    // Subject fully inside clip - nothing remains
                } else {
                    result.push_back(s);  // Approximation
                }
                break;
            }
            case ClipType::XOR: {
                if (!bs.intersects(bc)) {
                    result.push_back(s);
                    result.push_back(c);
                }
                break;
            }
        }
        return result;
    }

    // Sutherland-Hodgman polygon clipping (exact for convex clip polygon)
    static std::vector<Vec2> sutherlandHodgman(const std::vector<Vec2>& subject,
                                               const std::vector<Vec2>& clip) {
        std::vector<Vec2> output = subject;
        int clipN = (int)clip.size();

        for (int i = 0; i < clipN && !output.empty(); i++) {
            std::vector<Vec2> input = output;
            output.clear();

            Vec2 edgeStart = clip[i];
            Vec2 edgeEnd = clip[(i + 1) % clipN];

            for (int j = 0; j < (int)input.size(); j++) {
                Vec2 current = input[j];
                Vec2 prev = input[(j + input.size() - 1) % input.size()];

                bool currInside = cross(edgeStart, edgeEnd, current) >= 0;
                bool prevInside = cross(edgeStart, edgeEnd, prev) >= 0;

                if (currInside) {
                    if (!prevInside) {
                        output.push_back(lineIntersect(prev, current, edgeStart, edgeEnd));
                    }
                    output.push_back(current);
                } else if (prevInside) {
                    output.push_back(lineIntersect(prev, current, edgeStart, edgeEnd));
                }
            }
        }
        return output;
    }

    static Vec2 lineIntersect(const Vec2& p1, const Vec2& p2,
                              const Vec2& p3, const Vec2& p4) {
        double x1 = p1.x, y1 = p1.y, x2 = p2.x, y2 = p2.y;
        double x3 = p3.x, y3 = p3.y, x4 = p4.x, y4 = p4.y;

        double denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4);
        if (std::abs(denom) < 1e-18) return p1;

        double t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom;
        return {x1 + t * (x2 - x1), y1 + t * (y2 - y1)};
    }
};

} // namespace hongtu

#endif // HONGTU_GEOMETRY_ENGINE_H
