/** Painted GDS PATH -> independently filled editor polygons, in physical nm.
 * Normal width follows MAG; negative/absolute WIDTH is divided by accumulated
 * worldScale when constructing local geometry. TYPE4 extensions still scale.
 * Round caps retain the renderer's 8 segments per semicircle. Their geometric
 * sagitta bound is halfWidth*(1-cos(pi/16)), plus grid quantization.
 */
#ifndef HONGTU_PATH_EDIT_REGION_H
#define HONGTU_PATH_EDIT_REGION_H
#include "grid_edit_region.h"
#include "whole_dpath_region.h"

namespace hongtu { namespace clipper {
class PathEditRegion {
public:
    using Point = std::array<double, 2>;
    using Ring = GridEditRegion::Ring;
    using Region = GridEditRegion::Region;
    static Region execute(const Ring& input, double widthNm, int pathType,
                          double beginExtensionNm, double endExtensionNm,
                          double worldScale, bool widthAbsolute, double gridNm) {
        if (!std::isfinite(gridNm) || gridNm <= 0 || !std::isfinite(widthNm) || widthNm <= 0 ||
            !std::isfinite(worldScale) || worldScale <= 0 ||
            !std::isfinite(beginExtensionNm) || !std::isfinite(endExtensionNm))
            throw std::invalid_argument("path-region-invalid-width-scale-grid-or-extension");
        if (pathType != 0 && pathType != 1 && pathType != 2 && pathType != 4)
            throw std::invalid_argument("path-region-unsupported-path-type");
        if (input.size() < 2 || input.size() > EditRegion::kMaxVertices)
            throw std::invalid_argument("path-region-spine-budget-or-incomplete");
        const double width = widthAbsolute ? widthNm / worldScale : widthNm;
        if (!std::isfinite(width) || !(width > 0))
            throw std::invalid_argument("path-region-effective-width-overflow");
        const double half = width * 0.5;
        Ring points;
        for (const auto& p : input) {
            checkPoint(p, gridNm);
            if (points.empty() || p[0] != points.back()[0] || p[1] != points.back()[1]) points.push_back(p);
        }
        if (points.size() < 2) throw std::invalid_argument("path-region-degenerate-spine");
        // Strip and join vertices are accounted before allocation, not after a
        // possibly unbounded offset operation. Repeated points cost no work.
        const size_t estimate = 4 * (points.size() - 1) + 4 * (points.size() - 2) + (pathType == 1 ? 20 : 0);
        if (estimate > EditRegion::kMaxVertices)
            throw std::invalid_argument("path-region-generated-vertex-budget");
        std::vector<Point> directions;
        directions.reserve(points.size() - 1);
        for (size_t i = 1; i < points.size(); ++i) directions.push_back(unit(sub(points[i], points[i-1])));
        double begin = pathType == 2 ? half : (pathType == 4 ? beginExtensionNm : 0);
        double end = pathType == 2 ? half : (pathType == 4 ? endExtensionNm : 0);
        // A trim that passes an adjacent corner reverses the end segment and
        // would fabricate a different painted path. Reject atomically.
        if (pathType == 4) {
            const double firstLength = length(sub(points[1], points[0]));
            const double lastLength = length(sub(points.back(), points[points.size()-2]));
            if ((begin < 0 && -begin >= firstLength) || (end < 0 && -end >= lastLength) ||
                (points.size() == 2 && firstLength + begin + end <= 0))
                throw std::invalid_argument("path-region-extension-collapses-or-reverses-spine");
        }
        points.front() = add(points.front(), mul(directions.front(), -begin));
        points.back() = add(points.back(), mul(directions.back(), end));
        checkPoint(points.front(), gridNm); checkPoint(points.back(), gridNm);
        Region painted;
        painted.reserve(points.size() * 2);
        for (size_t i = 0; i < directions.size(); ++i) {
            const Point n = normal(directions[i]);
            painted.push_back({add(points[i], mul(n, half)), add(points[i+1], mul(n, half)),
                               add(points[i+1], mul(n, -half)), add(points[i], mul(n, -half))});
        }
        for (size_t i = 1; i + 1 < points.size(); ++i) {
            const auto& incoming = directions[i-1]; const auto& outgoing = directions[i];
            const double cross = incoming[0] * outgoing[1] - incoming[1] * outgoing[0];
            if (std::abs(cross) < 1e-14) continue; // Straight/retraced strips already describe the filled region.
            const Point sum = add(incoming, outgoing);
            const Point tangent = unit(sum);
            const double cosine = tangent[0] * incoming[0] + tangent[1] * incoming[1];
            if (!(cosine > 0) || !std::isfinite(half / cosine))
                throw std::invalid_argument("path-region-invalid-miter");
            const double side = cross > 0 ? -1 : 1;
            const Point miter = add(points[i], mul(normal(tangent), side * half / cosine));
            checkPoint(miter, gridNm);
            painted.push_back({points[i], add(points[i], mul(normal(incoming), side * half)),
                               miter, add(points[i], mul(normal(outgoing), side * half))});
        }
        if (pathType == 1) {
            painted.push_back(cap(points.front(), directions.front(), half, true));
            painted.push_back(cap(points.back(), directions.back(), half, false));
        }
        // Independent strips merge with union semantics: self crossing and
        // retracing must not cancel overlap as a single even-odd ribbon can.
        return GridEditRegion::execute(painted, {}, ClipType::UNION, gridNm);
    }
    // Explicit interoperability mode. Existing execute() keeps its declared
    // material-union behavior. Callers must opt in and show rejection reasons;
    // Complex inputs never silently fall back under a whole-DPath label.
    static Region executeWholeDPathSimple(const Ring& input, double widthNm, int pathType,
                                         double beginExtensionNm, double endExtensionNm,
                                         double worldScale, bool widthAbsolute, double gridNm) {
        Region output;
        if (!WholeDPathRegion::trySimple(input, widthNm, pathType,
                beginExtensionNm, endExtensionNm, worldScale, widthAbsolute, gridNm, output))
            throw std::invalid_argument("path-region-dpath-mode-complex-contour-not-supported");
        return output;
    }
    static double roundCapErrorNm(double width, double worldScale, bool absolute, double grid) {
        constexpr double pi = 3.1415926535897932384626433832795;
        return (absolute ? width / worldScale : width) * 0.5 * (1 - std::cos(pi / 16)) + grid / std::sqrt(2.0);
    }
private:
    static Point add(Point a, Point b) { return {a[0]+b[0],a[1]+b[1]}; }
    static Point sub(Point a, Point b) { return {a[0]-b[0],a[1]-b[1]}; }
    static Point mul(Point a, double value) { return {a[0]*value,a[1]*value}; }
    static Point normal(Point a) { return {-a[1],a[0]}; }
    static double length(Point a) { return std::hypot(a[0],a[1]); }
    static Point unit(Point a) {
        const double n = length(a);
        if (!std::isfinite(n) || !(n > 0)) throw std::invalid_argument("path-region-degenerate-or-overflow-segment");
        return {a[0]/n,a[1]/n};
    }
    static void checkPoint(const Point& p, double grid) {
        for (double c : p) {
            const long double q = static_cast<long double>(c) / grid;
            if (!std::isfinite(q) || std::abs(q) > GeneralClipper::kCoordLimit)
                throw std::invalid_argument("path-region-coordinate-grid-range");
        }
    }
    static Ring cap(Point center, Point direction, double half, bool start) {
        constexpr double pi = 3.1415926535897932384626433832795;
        const double a0 = start ? std::atan2(-direction[0], direction[1]) : std::atan2(direction[0], -direction[1]);
        Ring ring{center};
        for (int i = 0; i <= 8; ++i) {
            const double angle = a0 - pi * i / 8;
            ring.push_back(add(center, {std::cos(angle)*half,std::sin(angle)*half}));
        }
        return ring;
    }
};
}}
#endif
