/** Integer-DBU polygons backed by vendored Clipper2 2.0.1 (Boost license).
 * See vendor/clipper2/UPSTREAM.md. Output: outer CCW, holes CW.
 * Vertices/intersections remain quantized to DBU. approximated=false means
 * completion, not absence of rounding or manufacturing qualification.
 */
#ifndef HONGTU_CLIPPER_ENGINE_H
#define HONGTU_CLIPPER_ENGINE_H
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <functional>
#include <string>
#include <vector>
#include "vendor/clipper2/include/clipper2/clipper.engine.h"
#include "vendor/clipper2/include/clipper2/clipper.offset.h"
#include "vendor/clipper2/include/clipper2/clipper.minkowski.h"

namespace hongtu { namespace clipper {
struct IntPoint { int64_t x, y; };
using Path = std::vector<IntPoint>;
using Paths = std::vector<Path>;
#if defined(__SIZEOF_INT128__)
using WideInt = __int128;
#else
// Diagnostic helpers only; Clipper2 uses its own portable robust predicates.
using WideInt = long double;
#endif
inline int64_t saturateToInt64(WideInt v) {
    if (v >= static_cast<WideInt>(INT64_MAX)) return INT64_MAX;
    if (v <= static_cast<WideInt>(INT64_MIN)) return INT64_MIN;
    return static_cast<int64_t>(v);
}
inline int64_t safeCross(const IntPoint& o, const IntPoint& a, const IntPoint& b) {
    const WideInt ax = static_cast<WideInt>(a.x) - o.x, ay = static_cast<WideInt>(a.y) - o.y;
    const WideInt bx = static_cast<WideInt>(b.x) - o.x, by = static_cast<WideInt>(b.y) - o.y;
    return saturateToInt64(ax * by - ay * bx);
}
enum class ClipType { INTERSECTION, UNION, DIFFERENCE, XOR };
enum class FillRule { EVEN_ODD, NON_ZERO, POSITIVE, NEGATIVE };
enum class JoinType { MITER, SQUARE, ROUND };
enum class EndType { POLYGON, JOINED, BUTT, SQUARE, ROUND };

class GeneralClipper {
public:
    // Resource boundary, replacing the old O(E^2) 4,000-edge limitation.
    static constexpr int kMaxEdges = 1000000;
    // Below Clipper2's documented 1e15 precision degradation threshold.
    // Covers the entire signed 32-bit GDS coordinate range.
    static constexpr int64_t kCoordLimit = 100000000000000LL;
    struct Output {
        Paths contours;
        bool approximated = false; // rejection/failure; no partial geometry
        int droppedRings = 0;      // fewer than 3 consecutive distinct vertices
        int edgesSeen = 0;         // input vertices accepted
        int onLineProbes = 0;      // compatibility only; no side-probe algorithm
        std::string note;
    };
    static Output execute(const Paths& a, const Paths& b, ClipType op) {
        return executeWithRule(a, b, op, FillRule::EVEN_ODD);
    }
    static Output executeNZ(const Paths& a, const Paths& b, ClipType op,
                            const std::function<void()>& checkpoint = {}) {
        return executeWithRule(a, b, op, FillRule::NON_ZERO, checkpoint);
    }
    static Output executeWithRule(const Paths& a, const Paths& b, ClipType op, FillRule rule,
                                 const std::function<void()>& checkpoint = {}) {
        Output out;
        Clipper2Lib::CheckpointContext control{checkpoint};
        control.Check("clipper-validation", true);
        if (!validate(a, b, out, &control)) return out;
        Clipper2Lib::Clipper64 engine;
        engine.SetCheckpoint(checkpoint);
        engine.PreserveCollinear(false);
        engine.AddSubject(toNative(a, out, true, &control));
        engine.AddClip(toNative(b, out, true, &control));
        Clipper2Lib::Paths64 result;
        if (!engine.Execute(nativeOp(op), nativeRule(rule), result) || engine.ErrorCode()) {
            fail(out, "clipper2-boolean-error"); return out;
        }
        out.contours = fromNative(result, &control);
        control.Check("clipper-complete", true);
        return out;
    }
    // Independently filled shapes. Normalize EACH source first so opposite
    // windings and self-crossings cannot cancel another source's material.
    // For a region encoded by separate outer + hole contours use executeNZ.
    static Output unite(const Paths& shapes, const std::function<void()>& checkpoint = {}) {
        Output out;
        Clipper2Lib::CheckpointContext control{checkpoint};
        control.Check("clipper-validation", true);
        if (!validate(shapes, {}, out, &control)) return out;
        Clipper2Lib::Paths64 normalized;
        for (const auto& p : shapes) {
            control.Check("clipper-normalizing");
            Clipper2Lib::Clipper64 one;
            one.SetCheckpoint(checkpoint);
            one.PreserveCollinear(false);
            one.AddSubject(toNative({p}, out, true, &control));
            Clipper2Lib::Paths64 result;
            if (!one.Execute(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::EvenOdd, result)
                || one.ErrorCode()) { fail(out, "clipper2-merge-input-error"); return out; }
            for (auto& ring : result) {
                control.Check("clipper-normalizing");
                normalized.push_back(std::move(ring));
            }
        }
        Clipper2Lib::Clipper64 engine;
        engine.SetCheckpoint(checkpoint);
        engine.PreserveCollinear(false);
        engine.AddSubject(normalized);
        Clipper2Lib::Paths64 result;
        if (!engine.Execute(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, result)
            || engine.ErrorCode()) { fail(out, "clipper2-merge-error"); return out; }
        out.contours = fromNative(result, &control);
        control.Check("clipper-complete", true);
        return out;
    }
    static Output size(const Paths& paths, int64_t delta) {
        return offset(paths, static_cast<double>(delta));
    }
    // NON_ZERO polygon region: holes wind opposite to outers; entirely reversed
    // regions work too. Pre-union resolves crossings and same-winding overlaps.
    static Output offset(const Paths& paths, double delta, JoinType join = JoinType::MITER,
                         EndType end = EndType::POLYGON, double miterLimit = 2.0,
                         double arcTolerance = 0.0) {
        Output out;
        if (!validate(paths, {}, out)) return out;
        if (!std::isfinite(delta) || !std::isfinite(miterLimit) || !std::isfinite(arcTolerance)
            || miterLimit < 1 || arcTolerance < 0 || std::abs(delta) > kCoordLimit
            || (end != EndType::POLYGON && delta < 0)) {
            fail(out, "invalid-offset-parameters"); return out;
        }
        const double margin = std::abs(delta) * std::max(2.0, miterLimit);
        for (const auto& p : paths) for (const auto& v : p)
            if (std::abs(static_cast<double>(v.x)) + margin > kCoordLimit ||
                std::abs(static_cast<double>(v.y)) + margin > kCoordLimit) {
                fail(out, "offset-coordinate-range"); return out;
            }
        Clipper2Lib::Paths64 native;
        if (end == EndType::POLYGON) {
            auto normalized = executeNZ(paths, {}, ClipType::UNION);
            if (normalized.approximated) return normalized;
            native = toNative(normalized.contours, out);
        } else native = toNative(paths, out, false);
        Clipper2Lib::ClipperOffset engine(miterLimit, arcTolerance);
        const auto jt = join == JoinType::ROUND ? Clipper2Lib::JoinType::Round :
                        join == JoinType::SQUARE ? Clipper2Lib::JoinType::Square :
                                                 Clipper2Lib::JoinType::Miter;
        const auto et = end == EndType::BUTT ? Clipper2Lib::EndType::Butt :
                        end == EndType::SQUARE ? Clipper2Lib::EndType::Square :
                        end == EndType::ROUND ? Clipper2Lib::EndType::Round :
                        end == EndType::JOINED ? Clipper2Lib::EndType::Joined :
                                                Clipper2Lib::EndType::Polygon;
        engine.AddPaths(native, jt, et);
        Clipper2Lib::Paths64 result;
        engine.Execute(delta, result);
        if (engine.ErrorCode()) { fail(out, "clipper2-offset-error"); return out; }
        out.contours = fromNative(result);
        return out;
    }
    static Paths debugPieces(const Paths& a, const Paths& b, ClipType op) {
        Paths edges;
        for (const auto& p : execute(a, b, op).contours)
            for (size_t i = 0; i < p.size(); ++i) edges.push_back({p[i], p[(i+1) % p.size()]});
        return edges;
    }
    static int64_t ringArea2(const Path& p) { return saturateToInt64(area2(p)); }
    static int64_t ringArea(const Path& p) { return saturateToInt64(area2(p) / 2); }
    static int64_t signedAreaSum2(const Paths& paths) {
        WideInt a = 0; for (const auto& p : paths) a += area2(p); return saturateToInt64(a);
    }
    static int64_t signedAreaSum(const Paths& paths) {
        WideInt a = 0; for (const auto& p : paths) a += area2(p); return saturateToInt64(a / 2);
    }
private:
    static WideInt area2(const Path& p, const Clipper2Lib::CheckpointContext* control = nullptr) {
        WideInt a = 0;
        if (p.size() < 3) return a;
        // Translation avoids cancellation in the MSVC host area diagnostic.
        for (size_t i = 1; i + 1 < p.size(); ++i) {
            Clipper2Lib::Checkpoint(control, "clipper-output-area");
            const WideInt ax = static_cast<WideInt>(p[i].x) - p[0].x;
            const WideInt ay = static_cast<WideInt>(p[i].y) - p[0].y;
            const WideInt bx = static_cast<WideInt>(p[i+1].x) - p[0].x;
            const WideInt by = static_cast<WideInt>(p[i+1].y) - p[0].y;
            a += ax * by - ay * bx;
        }
        return a;
    }
    static void fail(Output& out, const char* why) {
        out.approximated = true; out.note = why; out.contours.clear();
    }
    static bool validate(const Paths& a, const Paths& b, Output& out,
                         const Clipper2Lib::CheckpointContext* control = nullptr) {
        size_t count = 0;
        for (const auto* set : {&a, &b}) for (const auto& p : *set) {
            Clipper2Lib::Checkpoint(control, "clipper-validation");
            if (p.size() > static_cast<size_t>(kMaxEdges) - count) {
                fail(out, "edge-cap"); return false;
            }
            count += p.size();
            for (const auto& v : p) {
              Clipper2Lib::Checkpoint(control, "clipper-validation");
              if (v.x < -kCoordLimit || v.x > kCoordLimit ||
                                        v.y < -kCoordLimit || v.y > kCoordLimit) {
                fail(out, "coordinate-range"); return false;
              }
            }
        }
        out.edgesSeen = static_cast<int>(count); return true;
    }
    static Clipper2Lib::ClipType nativeOp(ClipType op) {
        switch (op) {
            case ClipType::INTERSECTION: return Clipper2Lib::ClipType::Intersection;
            case ClipType::UNION: return Clipper2Lib::ClipType::Union;
            case ClipType::DIFFERENCE: return Clipper2Lib::ClipType::Difference;
            default: return Clipper2Lib::ClipType::Xor;
        }
    }
    static Clipper2Lib::FillRule nativeRule(FillRule rule) {
        switch (rule) {
            case FillRule::NON_ZERO: return Clipper2Lib::FillRule::NonZero;
            case FillRule::POSITIVE: return Clipper2Lib::FillRule::Positive;
            case FillRule::NEGATIVE: return Clipper2Lib::FillRule::Negative;
            default: return Clipper2Lib::FillRule::EvenOdd;
        }
    }
    static Clipper2Lib::Paths64 toNative(const Paths& paths, Output& out, bool closed = true,
                                       const Clipper2Lib::CheckpointContext* control = nullptr) {
        Clipper2Lib::Paths64 result; result.reserve(paths.size());
        for (const auto& p : paths) {
            Clipper2Lib::Checkpoint(control, "clipper-converting-input");
            Clipper2Lib::Path64 converted; converted.reserve(p.size());
            for (const auto& v : p) {
                Clipper2Lib::Checkpoint(control, "clipper-converting-input");
                if (converted.empty() || converted.back().x != v.x || converted.back().y != v.y)
                    converted.emplace_back(v.x, v.y);
            }
            if (closed && converted.size() > 1 && converted.front() == converted.back()) converted.pop_back();
            if (converted.size() < (closed ? 3u : 1u)) { ++out.droppedRings; continue; }
            result.push_back(std::move(converted));
        }
        return result;
    }
    static Paths fromNative(const Clipper2Lib::Paths64& paths,
                            const Clipper2Lib::CheckpointContext* control = nullptr) {
        Paths result; result.reserve(paths.size());
        for (const auto& p : paths) {
            Clipper2Lib::Checkpoint(control, "clipper-converting-output");
            Path converted; converted.reserve(p.size());
            for (const auto& v : p) {
                Clipper2Lib::Checkpoint(control, "clipper-converting-output");
                converted.push_back({v.x, v.y});
            }
            if (converted.size() >= 3) result.push_back(std::move(converted));
        }
        std::stable_sort(result.begin(), result.end(), [control](const Path& a, const Path& b) {
            Clipper2Lib::Checkpoint(control, "clipper-sorting-output");
            return std::fabs(static_cast<long double>(area2(a, control))) >
                   std::fabs(static_cast<long double>(area2(b, control)));
        });
        return result;
    }
};

class ClipperEngine {
public:
    static bool execute(const Paths& a, const Paths& b, ClipType op, FillRule rule, Paths& solution) {
        const auto out = GeneralClipper::executeWithRule(a, b, op, rule);
        solution = out.contours; return !out.approximated;
    }
    static GeneralClipper::Output booleanEx(const Paths& a, const Paths& b, ClipType op) {
        return GeneralClipper::execute(a, b, op);
    }
    static GeneralClipper::Output mergeEx(const Paths& paths) { return GeneralClipper::unite(paths); }
    static Paths clipPair(const Path& a, const Path& b, ClipType op) { return booleanEx({a}, {b}, op).contours; }
    static Paths offset(const Paths& paths, double delta, JoinType join = JoinType::MITER,
                        EndType end = EndType::POLYGON, double miterLimit = 2.0,
                        double arcTolerance = 0.0) {
        return GeneralClipper::offset(paths, delta, join, end, miterLimit, arcTolerance).contours;
    }
    static GeneralClipper::Output offsetEx(const Paths& paths, double delta) {
        return GeneralClipper::offset(paths, delta);
    }
    static Paths minkowskiSum(const Path& pattern, const Path& path, bool isSum) {
        Clipper2Lib::Path64 pat, src;
        for (const auto& p : pattern) {
            if (std::abs(static_cast<long double>(p.x)) > GeneralClipper::kCoordLimit / 2 ||
                std::abs(static_cast<long double>(p.y)) > GeneralClipper::kCoordLimit / 2) return {};
            pat.emplace_back(p.x, p.y);
        }
        for (const auto& p : path) {
            if (std::abs(static_cast<long double>(p.x)) > GeneralClipper::kCoordLimit / 2 ||
                std::abs(static_cast<long double>(p.y)) > GeneralClipper::kCoordLimit / 2) return {};
            src.emplace_back(p.x, p.y);
        }
        if (pat.size() < 3 || src.empty()) return {};
        const auto native = isSum ? Clipper2Lib::MinkowskiSum(pat, src, true) :
                                    Clipper2Lib::MinkowskiDiff(pat, src, true);
        Paths result;
        for (const auto& p : native) {
            Path out; for (const auto& v : p) out.push_back({v.x, v.y}); result.push_back(std::move(out));
        }
        return result;
    }
    static int64_t pathArea(const Path& path) { return GeneralClipper::ringArea(path); }
    static bool pointInPath(const IntPoint& pt, const Path& path) {
        Clipper2Lib::Path64 p; for (const auto& v : path) p.emplace_back(v.x, v.y);
        return Clipper2Lib::PointInPolygon(Clipper2Lib::Point64(pt.x, pt.y), p) !=
               Clipper2Lib::PointInPolygonResult::IsOutside;
    }
    static IntPoint pathCentroid(const Path& path) {
        if (path.empty()) return {0, 0};
        WideInt x = 0, y = 0;
        for (const auto& p : path) { x += p.x; y += p.y; }
        return {saturateToInt64(x / path.size()), saturateToInt64(y / path.size())};
    }
    static Path simplify(const Path& path, double epsilon = 1.0) {
        if (path.size() < 3 || !std::isfinite(epsilon) || epsilon < 0) return path;
        Path result;
        for (size_t i = 0; i < path.size(); ++i) {
            const auto& prev = path[(i + path.size() - 1) % path.size()];
            const auto& p = path[i];
            const double dx = static_cast<double>(p.x) - prev.x, dy = static_cast<double>(p.y) - prev.y;
            if (dx * dx + dy * dy < epsilon * epsilon) continue;
            if (std::abs(static_cast<long double>(safeCross(prev, p, path[(i+1) % path.size()]))) <
                epsilon * epsilon) continue;
            result.push_back(p);
        }
        return result.size() >= 3 ? result : path;
    }
};
} } // hongtu::clipper
#endif
