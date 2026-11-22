/** Convert a signed region into filled editor polygons, uniting each perforated
 * outer contour with its holes via optimal GDSII keyhole cutlines (<= 8190 pts).
 */
#ifndef HONGTU_EDIT_REGION_H
#define HONGTU_EDIT_REGION_H
#include <algorithm>
#include <array>
#include <cmath>
#include <limits>
#include <map>
#include <numeric>
#include <set>
#include <stdexcept>
#include <vector>
#include "clipper_engine.h"
#include "vendor/earcut/earcut.hpp"

namespace hongtu { namespace clipper {
class EditRegion {
public:
    // Editing has a separate resource ceiling: triangulation can expand shape count.
    static constexpr size_t kMaxVertices = 20000;
    static constexpr size_t kMaxPieces = 40000;
    // Standard GDSII BOUNDARY record limit is 8191 XY points (8190 unique + closing repeat).
    static constexpr size_t kMaxGdsPolygonVertices = 8190;

    static Paths fracture(const GeneralClipper::Output& source) {
        if (source.approximated) throw std::runtime_error(source.note);
        if (source.contours.empty()) return {};
        // Existing simple outer rings already satisfy the editor contract.
        // Re-clipping can remove an integer-grid spike around a previously
        // rounded intersection; do not change geometry merely to copy it.
        bool alreadySimple = true;
        size_t inputVertices = 0;
        for (const auto& p : source.contours) {
            inputVertices += p.size();
            if (inputVertices > kMaxVertices) throw std::runtime_error("edit-region-vertex-limit");
            alreadySimple = alreadySimple && p.size() <= kMaxGdsPolygonVertices &&
                            GeneralClipper::ringArea2(p) > 0 && distinct(p);
        }
        if (alreadySimple) return source.contours;

        size_t vertices = 0;
        Clipper2Lib::Paths64 paths;
        for (const auto& ring : source.contours) {
            vertices += ring.size();
            if (vertices > kMaxVertices) throw std::runtime_error("edit-region-vertex-limit");
            Clipper2Lib::Path64 p;
            for (const auto& q : ring) p.emplace_back(q.x, q.y);
            paths.push_back(std::move(p));
        }
        Clipper2Lib::Clipper64 engine;
        engine.AddSubject(paths);
        Clipper2Lib::PolyTree64 tree;
        if (!engine.Execute(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, tree)
            || engine.ErrorCode()) throw std::runtime_error("edit-region-tree-error");

        auto verifyPieces = [&](const Paths& candidate) -> bool {
            if (candidate.empty()) return false;
            for (const auto& p : candidate) {
                if (p.size() < 3 || p.size() > kMaxVertices) return false;
            }
            auto united = GeneralClipper::executeNZ(candidate, {}, ClipType::UNION);
            auto parity = GeneralClipper::execute(candidate, {}, ClipType::UNION);
            auto difference = GeneralClipper::executeNZ(source.contours, united.contours, ClipType::XOR);
            auto overlap = GeneralClipper::executeNZ(united.contours, parity.contours, ClipType::XOR);
            return !united.approximated && !parity.approximated && !difference.approximated &&
                   !overlap.approximated && difference.contours.empty() && overlap.contours.empty();
        };

        // Primary path: represent each outer contour + its interior holes as ONE single
        // GDSII-compliant keyhole-bridged polygon whenever total vertices <= 8190.
        Paths keyholePieces;
        bool allKeyholed = true;
        try {
            allKeyholed = visitKeyhole(tree, keyholePieces);
        } catch (...) {
            allKeyholed = false;
        }
        if (allKeyholed && !keyholePieces.empty() && verifyPieces(keyholePieces)) {
            return keyholePieces;
        }

        // Fallback path (e.g., > 8190 vertices in a single multi-hole contour or degenerate touch):
        // earcut tessellation + thin-piece recovery + simple-piece coalescing capped at 8190 pts.
        Paths pieces;
        visitTriangulated(tree, pieces);
        coalesceThinPieces(pieces);
        if (pieces.size() > 1) {
            Paths mergedCandidate = pieces;
            try {
                coalesceSimplePieces(mergedCandidate);
                if (verifyPieces(mergedCandidate)) {
                    return mergedCandidate;
                }
            } catch (...) {
                // Fall back to exact earcut + thin-piece coalesced pieces below.
            }
        }
        if (!verifyPieces(pieces))
            throw std::runtime_error("edit-region-decomposition-mismatch");
        return pieces;
    }

private:
    using Edge = std::array<int64_t, 4>;
    static Edge edge(const IntPoint& a, const IntPoint& b) { return {a.x, a.y, b.x, b.y}; }
    static bool same(const IntPoint& a, const IntPoint& b) { return a.x == b.x && a.y == b.y; }

    static WideInt cross3(const IntPoint& o, const IntPoint& a, const IntPoint& b) {
        const WideInt ax = static_cast<WideInt>(a.x) - o.x;
        const WideInt ay = static_cast<WideInt>(a.y) - o.y;
        const WideInt bx = static_cast<WideInt>(b.x) - o.x;
        const WideInt by = static_cast<WideInt>(b.y) - o.y;
        return ax * by - ay * bx;
    }

    static int orientSign(const IntPoint& o, const IntPoint& a, const IntPoint& b) {
        const WideInt c = cross3(o, a, b);
        return (c > 0) ? 1 : ((c < 0) ? -1 : 0);
    }

    static bool onSegmentInclusive(const IntPoint& a, const IntPoint& p, const IntPoint& b) {
        return p.x >= std::min(a.x, b.x) && p.x <= std::max(a.x, b.x) &&
               p.y >= std::min(a.y, b.y) && p.y <= std::max(a.y, b.y) &&
               orientSign(a, b, p) == 0;
    }

    static bool segmentsProperOrTouch(const IntPoint& a, const IntPoint& b,
                                      const IntPoint& c, const IntPoint& d) {
        if (std::max(a.x, b.x) < std::min(c.x, d.x) || std::max(c.x, d.x) < std::min(a.x, b.x) ||
            std::max(a.y, b.y) < std::min(c.y, d.y) || std::max(c.y, d.y) < std::min(a.y, b.y)) {
            return false;
        }
        const int o1 = orientSign(a, b, c);
        const int o2 = orientSign(a, b, d);
        const int o3 = orientSign(c, d, a);
        const int o4 = orientSign(c, d, b);
        if (o1 == 0 && onSegmentInclusive(a, c, b)) return true;
        if (o2 == 0 && onSegmentInclusive(a, d, b)) return true;
        if (o3 == 0 && onSegmentInclusive(c, a, d)) return true;
        if (o4 == 0 && onSegmentInclusive(c, b, d)) return true;
        return (o1 > 0) != (o2 > 0) && (o3 > 0) != (o4 > 0);
    }

    // Check whether directed ray p -> target lies strictly inside the CCW interior sector
    // at corner (prev -> p -> next). Works for both convex (cross > 0) and reflex (cross <= 0) corners.
    static bool rayStrictlyInInteriorCone(const IntPoint& prev, const IntPoint& p,
                                          const IntPoint& next, const IntPoint& target) {
        if (same(p, target) || same(prev, p) || same(next, p)) return false;
        // Reject collinear overlap with either incident boundary edge (p->next or p->prev)
        if (orientSign(p, next, target) == 0) {
            const WideInt dx1 = static_cast<WideInt>(next.x) - p.x;
            const WideInt dy1 = static_cast<WideInt>(next.y) - p.y;
            const WideInt dx2 = static_cast<WideInt>(target.x) - p.x;
            const WideInt dy2 = static_cast<WideInt>(target.y) - p.y;
            if (dx1 * dx2 + dy1 * dy2 >= 0) return false;
        }
        if (orientSign(p, prev, target) == 0) {
            const WideInt dx1 = static_cast<WideInt>(prev.x) - p.x;
            const WideInt dy1 = static_cast<WideInt>(prev.y) - p.y;
            const WideInt dx2 = static_cast<WideInt>(target.x) - p.x;
            const WideInt dy2 = static_cast<WideInt>(target.y) - p.y;
            if (dx1 * dx2 + dy1 * dy2 >= 0) return false;
        }
        const WideInt turn = cross3(prev, p, next);
        const WideInt cIn = cross3(prev, p, target);   // > 0 means target is to the left of prev->p
        const WideInt cOut = cross3(p, next, target);  // > 0 means target is to the left of p->next
        if (turn > 0) {
            // Convex CCW corner (< 180 deg interior): must be strictly left of both edges
            return cIn > 0 && cOut > 0;
        } else {
            // Reflex or straight CCW corner (>= 180 deg interior): outside is the right-hand wedge
            // where cIn <= 0 && cOut <= 0; everything else not on boundary rays is strictly interior.
            return !(cIn <= 0 && cOut <= 0);
        }
    }

    static Path cleanRing(const Path& raw) {
        Path out;
        out.reserve(raw.size());
        for (const auto& q : raw) {
            if (out.empty() || !same(out.back(), q)) out.push_back(q);
        }
        while (out.size() > 1 && same(out.front(), out.back())) out.pop_back();
        return out;
    }

    // Connect outer (CCW) and holes (CW) into a single keyhole-bridged polygon.
    static bool bridgeOuterWithHoles(Path outer, std::vector<Path> holes, Path& outMerged) {
        outer = cleanRing(outer);
        if (outer.size() < 3) return false;
        if (GeneralClipper::ringArea2(outer) < 0) std::reverse(outer.begin(), outer.end());

        std::vector<Path> validHoles;
        validHoles.reserve(holes.size());
        size_t estimatedVerts = outer.size();
        for (auto& h : holes) {
            Path ch = cleanRing(h);
            if (ch.size() < 3) continue;
            if (GeneralClipper::ringArea2(ch) > 0) std::reverse(ch.begin(), ch.end());
            estimatedVerts += ch.size() + 3; // +2 bridge duplicates, +1 optional orthogonal Steiner point
            validHoles.push_back(std::move(ch));
        }
        if (validHoles.empty()) {
            if (outer.size() > kMaxGdsPolygonVertices) return false;
            outMerged = std::move(outer);
            return true;
        }
        if (estimatedVerts > kMaxGdsPolygonVertices + validHoles.size()) {
            // May still fit if no Steiner points are added; check exact bound below.
            size_t minVerts = outer.size();
            for (const auto& h : validHoles) minVerts += h.size() + 2;
            if (minVerts > kMaxGdsPolygonVertices) return false;
        }

        // Sort holes by rightmost X descending (tie-break by Y ascending) so +X visibility
        // from each hole's rightmost vertex naturally reaches outer or already-merged rings.
        struct HoleEntry {
            size_t idx;
            size_t rightVert;
            int64_t maxX;
            int64_t minYAtMaxX;
        };
        std::vector<HoleEntry> order;
        order.reserve(validHoles.size());
        for (size_t i = 0; i < validHoles.size(); ++i) {
            const auto& h = validHoles[i];
            size_t best = 0;
            for (size_t k = 1; k < h.size(); ++k) {
                if (h[k].x > h[best].x || (h[k].x == h[best].x && h[k].y < h[best].y)) {
                    best = k;
                }
            }
            order.push_back({i, best, h[best].x, h[best].y});
        }
        std::sort(order.begin(), order.end(), [](const HoleEntry& a, const HoleEntry& b) {
            if (a.maxX != b.maxX) return a.maxX > b.maxX;
            return a.minYAtMaxX < b.minYAtMaxX;
        });

        Path merged = std::move(outer);
        std::vector<bool> holeMerged(validHoles.size(), false);

        // Check that open/closed bridge segment (mPt <-> anchorPt) hits no non-incident edge
        // of `merged` (ignoring edges incident to anchorPt) and no edge of any unmerged hole
        // (ignoring edges of `curHoleIdx` incident to `mVertIdx`).
        auto bridgeIsClear = [&](const IntPoint& mPt, size_t curHoleIdx, size_t mVertIdx,
                                 const IntPoint& anchorPt, int splitMergedEdgeIdx) -> bool {
            const size_t mn = merged.size();
            for (size_t e = 0; e < mn; ++e) {
                if (static_cast<int>(e) == splitMergedEdgeIdx) continue;
                const IntPoint& a = merged[e];
                const IntPoint& b = merged[(e + 1) % mn];
                if (same(a, anchorPt) || same(b, anchorPt)) {
                    // Still reject if mPt lies directly on an edge incident to anchorPt
                    if (!same(mPt, anchorPt) && onSegmentInclusive(a, mPt, b)) return false;
                    continue;
                }
                if (same(a, mPt) || same(b, mPt)) continue;
                if (segmentsProperOrTouch(mPt, anchorPt, a, b)) return false;
            }
            for (size_t hi = 0; hi < validHoles.size(); ++hi) {
                if (holeMerged[hi]) continue;
                const auto& h = validHoles[hi];
                const size_t hn = h.size();
                for (size_t e = 0; e < hn; ++e) {
                    const size_t eNext = (e + 1) % hn;
                    if (hi == curHoleIdx && (e == mVertIdx || eNext == mVertIdx)) {
                        if (!same(anchorPt, mPt) && onSegmentInclusive(h[e], anchorPt, h[eNext])) return false;
                        continue;
                    }
                    if (segmentsProperOrTouch(mPt, anchorPt, h[e], h[eNext])) return false;
                }
            }
            return true;
        };

        for (const auto& item : order) {
            const size_t hi = item.idx;
            const Path& hole = validHoles[hi];
            const size_t hn = hole.size();
            const size_t hStart = item.rightVert;
            const IntPoint mPt = hole[hStart];
            const IntPoint hPrev = hole[(hStart + hn - 1) % hn];
            const IntPoint hNext = hole[(hStart + 1) % hn];

            bool connected = false;

            // Strategy A (Shared vertex): if mPt (or any hole vertex) already coincides with a
            // vertex of `merged` whose interior cone admits the hole's edges, splice directly.
            for (size_t hk = 0; hk < hn && !connected; ++hk) {
                const size_t hv = (hStart + hk) % hn;
                const IntPoint& hp = hole[hv];
                const IntPoint& hpNext = hole[(hv + 1) % hn];
                const IntPoint& hpPrev = hole[(hv + hn - 1) % hn];
                for (size_t mv = 0; mv < merged.size(); ++mv) {
                    if (!same(merged[mv], hp)) continue;
                    const IntPoint& mPrev = merged[(mv + merged.size() - 1) % merged.size()];
                    const IntPoint& mNext = merged[(mv + 1) % merged.size()];
                    if (rayStrictlyInInteriorCone(mPrev, merged[mv], mNext, hpNext) &&
                        rayStrictlyInInteriorCone(mPrev, merged[mv], mNext, hpPrev)) {
                        Path nextMerged;
                        nextMerged.reserve(merged.size() + hn + 1);
                        for (size_t i = 0; i <= mv; ++i) nextMerged.push_back(merged[i]);
                        for (size_t i = 1; i < hn; ++i) nextMerged.push_back(hole[(hv + i) % hn]);
                        nextMerged.push_back(merged[mv]);
                        for (size_t i = mv + 1; i < merged.size(); ++i) nextMerged.push_back(merged[i]);
                        merged = std::move(nextMerged);
                        connected = true;
                        break;
                    }
                }
            }

            // Strategy B (Orthogonal horizontal +X keyhole cut onto a vertical edge of `merged`):
            // Produces textbook Manhattan horizontal keyhole slits (e.g. square minus circle -> y = cy).
            if (!connected && merged.size() + hn + 3 <= kMaxGdsPolygonVertices) {
                int bestEdge = -1;
                int64_t bestIx = std::numeric_limits<int64_t>::max();
                const size_t mn = merged.size();
                for (size_t e = 0; e < mn; ++e) {
                    const IntPoint& a = merged[e];
                    const IntPoint& b = merged[(e + 1) % mn];
                    if (a.x != b.x || a.x <= mPt.x) continue;
                    // For a CCW filled region on the left of directed edge a -> b, a +X ray from inside
                    // the region hits an upward vertical edge (a.y < mPt.y < b.y).
                    if (a.y < mPt.y && mPt.y < b.y && a.x < bestIx) {
                        const IntPoint proj{a.x, mPt.y};
                        if (rayStrictlyInInteriorCone(hPrev, mPt, hNext, proj) &&
                            bridgeIsClear(mPt, hi, hStart, proj, static_cast<int>(e))) {
                            bestIx = a.x;
                            bestEdge = static_cast<int>(e);
                        }
                    }
                }
                if (bestEdge >= 0) {
                    const IntPoint proj{bestIx, mPt.y};
                    Path nextMerged;
                    nextMerged.reserve(merged.size() + hn + 3);
                    for (size_t i = 0; i <= static_cast<size_t>(bestEdge); ++i) {
                        nextMerged.push_back(merged[i]);
                    }
                    nextMerged.push_back(proj);
                    for (size_t i = 0; i <= hn; ++i) {
                        nextMerged.push_back(hole[(hStart + i) % hn]);
                    }
                    nextMerged.push_back(proj);
                    for (size_t i = static_cast<size_t>(bestEdge) + 1; i < merged.size(); ++i) {
                        nextMerged.push_back(merged[i]);
                    }
                    merged = std::move(nextMerged);
                    connected = true;
                }
            }

            // Strategy C (Shortest visible vertex-to-vertex bridge from hole to `merged`):
            // Tests mPt first, then other hole extremal vertices if needed, against all vertices of `merged`.
            if (!connected && merged.size() + hn + 2 <= kMaxGdsPolygonVertices) {
                std::vector<size_t> candidateHoleVerts = {hStart};
                // Add top/bottom/left extrema of hole as backup origins in case mPt is locally grazing
                size_t hTop = 0, hBot = 0, hLeft = 0;
                for (size_t k = 1; k < hn; ++k) {
                    if (hole[k].y > hole[hTop].y) hTop = k;
                    if (hole[k].y < hole[hBot].y) hBot = k;
                    if (hole[k].x < hole[hLeft].x) hLeft = k;
                }
                for (size_t extra : {hTop, hBot, hLeft}) {
                    if (std::find(candidateHoleVerts.begin(), candidateHoleVerts.end(), extra) == candidateHoleVerts.end()) {
                        candidateHoleVerts.push_back(extra);
                    }
                }

                struct VertexBridge {
                    double score;
                    size_t mIdx;
                    size_t hIdx;
                };
                VertexBridge best{std::numeric_limits<double>::infinity(), 0, 0};
                bool foundBridge = false;
                const size_t mn = merged.size();

                for (size_t hv : candidateHoleVerts) {
                    const IntPoint& hp = hole[hv];
                    const IntPoint& hpPrev = hole[(hv + hn - 1) % hn];
                    const IntPoint& hpNext = hole[(hv + 1) % hn];
                    for (size_t mv = 0; mv < mn; ++mv) {
                        const IntPoint& mp = merged[mv];
                        if (same(hp, mp)) continue;
                        const IntPoint& mpPrev = merged[(mv + mn - 1) % mn];
                        const IntPoint& mpNext = merged[(mv + 1) % mn];
                        if (!rayStrictlyInInteriorCone(hpPrev, hp, hpNext, mp)) continue;
                        if (!rayStrictlyInInteriorCone(mpPrev, mp, mpNext, hp)) continue;

                        const double dx = static_cast<double>(mp.x) - static_cast<double>(hp.x);
                        const double dy = static_cast<double>(mp.y) - static_cast<double>(hp.y);
                        double distSq = dx * dx + dy * dy;
                        // Slightly prefer orthogonal (horizontal/vertical) bridges when distances are comparable
                        if (mp.x == hp.x || mp.y == hp.y) distSq *= 0.85;
                        if (distSq >= best.score) continue;

                        if (bridgeIsClear(hp, hi, hv, mp, -1)) {
                            best = {distSq, mv, hv};
                            foundBridge = true;
                        }
                    }
                    if (foundBridge && hv == hStart) break;
                }

                if (foundBridge) {
                    Path nextMerged;
                    nextMerged.reserve(merged.size() + hn + 2);
                    for (size_t i = 0; i <= best.mIdx; ++i) nextMerged.push_back(merged[i]);
                    for (size_t i = 0; i <= hn; ++i) nextMerged.push_back(hole[(best.hIdx + i) % hn]);
                    nextMerged.push_back(merged[best.mIdx]);
                    for (size_t i = best.mIdx + 1; i < merged.size(); ++i) nextMerged.push_back(merged[i]);
                    merged = std::move(nextMerged);
                    connected = true;
                }
            }

            if (!connected || merged.size() > kMaxGdsPolygonVertices) {
                return false;
            }
            holeMerged[hi] = true;
        }

        outMerged = std::move(merged);
        return true;
    }

    static bool visitKeyhole(const Clipper2Lib::PolyPath64& node, Paths& outPieces) {
        for (const auto& child : node) {
            if (!child->IsHole()) {
                Path outer = path(child->Polygon());
                if (child->Count() == 0) {
                    outer = cleanRing(outer);
                    if (outer.size() < 3 || outer.size() > kMaxGdsPolygonVertices || !distinct(outer)) {
                        return false;
                    }
                    if (GeneralClipper::ringArea2(outer) < 0) std::reverse(outer.begin(), outer.end());
                    outPieces.push_back(std::move(outer));
                } else {
                    std::vector<Path> holes;
                    holes.reserve(child->Count());
                    for (const auto& holeNode : *child) {
                        holes.push_back(path(holeNode->Polygon()));
                    }
                    Path bridged;
                    if (!bridgeOuterWithHoles(std::move(outer), std::move(holes), bridged)) {
                        return false;
                    }
                    outPieces.push_back(std::move(bridged));
                }
                if (outPieces.size() > kMaxPieces) throw std::runtime_error("edit-region-piece-limit");
            }
            if (!visitKeyhole(*child, outPieces)) return false; // detached islands nested inside holes
        }
        return true;
    }

    static bool filled(const Path& p) {
        const auto result = GeneralClipper::execute({p}, {}, ClipType::UNION);
        if (result.approximated) throw std::runtime_error(result.note);
        return !result.contours.empty();
    }

    static void coalesceThinPieces(Paths& pieces) {
        std::map<Edge, std::vector<size_t>> edges;
        std::vector<bool> removed(pieces.size(), false);
        size_t indexedEdges = 0;
        auto index = [&](size_t i) {
            const auto& p = pieces[i];
            if (p.size() > 1000000 - indexedEdges) throw std::runtime_error("edit-region-coalesce-edge-budget");
            indexedEdges += p.size();
            for (size_t k = 0; k < p.size(); ++k) edges[edge(p[k], p[(k + 1) % p.size()])].push_back(i);
        };
        for (size_t i = 0; i < pieces.size(); ++i) index(i);
        size_t probes = 0;
        for (size_t i = 0; i < pieces.size(); ++i) {
            if (removed[i]) continue;
            while (!filled(pieces[i])) {
                bool joined = false;
                const auto original = pieces[i];
                for (size_t a = 0; a < original.size() && !joined; ++a) {
                    const auto found = edges.find(edge(original[(a + 1) % original.size()], original[a]));
                    if (found == edges.end()) continue;
                    for (size_t other : found->second) {
                        if (++probes > 2000000) throw std::runtime_error("edit-region-coalesce-budget");
                        if (other == i || removed[other]) continue;
                        const auto& neighbour = pieces[other];
                        for (size_t b = 0; b < neighbour.size() && !joined; ++b) {
                            if (!same(original[a], neighbour[(b + 1) % neighbour.size()]) ||
                                !same(original[(a + 1) % original.size()], neighbour[b])) continue;
                            Path merged;
                            for (size_t k = 0; k < original.size(); ++k) merged.push_back(original[(a + 1 + k) % original.size()]);
                            for (size_t k = 1; k + 1 < neighbour.size(); ++k) merged.push_back(neighbour[(b + 1 + k) % neighbour.size()]);
                            if (merged.size() > kMaxGdsPolygonVertices || !distinct(merged) ||
                                GeneralClipper::ringArea2(merged) != GeneralClipper::ringArea2(original) + GeneralClipper::ringArea2(neighbour)) continue;
                            pieces[i] = std::move(merged); removed[other] = true; index(i); joined = true;
                        }
                        if (joined) break;
                    }
                }
                if (!joined) throw std::runtime_error("edit-region-unrepresentable-thin-piece");
            }
        }
        Paths output;
        for (size_t i = 0; i < pieces.size(); ++i) if (!removed[i]) output.push_back(std::move(pieces[i]));
        pieces = std::move(output);
    }

    static double edgeLenSq(const IntPoint& a, const IntPoint& b) {
        const double dx = static_cast<double>(a.x) - static_cast<double>(b.x);
        const double dy = static_cast<double>(a.y) - static_cast<double>(b.y);
        return dx * dx + dy * dy;
    }

    static void coalesceSimplePieces(Paths& pieces) {
        static constexpr size_t kMaxMergeChecks = 32768;
        size_t mergeChecks = 0;
        bool progress = true;
        while (progress && pieces.size() > 1 && mergeChecks < kMaxMergeChecks) {
            progress = false;
            std::map<Edge, std::vector<size_t>> edgeOwners;
            std::vector<bool> removed(pieces.size(), false);
            auto indexPiece = [&](size_t idx) {
                const auto& p = pieces[idx];
                for (size_t k = 0; k < p.size(); ++k) {
                    edgeOwners[edge(p[k], p[(k + 1) % p.size()])].push_back(idx);
                }
            };
            for (size_t i = 0; i < pieces.size(); ++i) indexPiece(i);

            struct Candidate {
                double lenSq;
                size_t i;
                size_t other;
                IntPoint u;
                IntPoint v;
            };
            std::vector<Candidate> candidates;
            for (size_t i = 0; i < pieces.size(); ++i) {
                const auto& p = pieces[i];
                for (size_t a = 0; a < p.size(); ++a) {
                    const IntPoint u = p[a];
                    const IntPoint v = p[(a + 1) % p.size()];
                    const auto it = edgeOwners.find(edge(v, u));
                    if (it == edgeOwners.end()) continue;
                    for (size_t other : it->second) {
                        if (other > i) {
                            candidates.push_back({edgeLenSq(u, v), i, other, u, v});
                        }
                    }
                }
            }
            std::sort(candidates.begin(), candidates.end(), [](const Candidate& lhs, const Candidate& rhs) {
                if (lhs.lenSq != rhs.lenSq) return lhs.lenSq > rhs.lenSq;
                return lhs.i != rhs.i ? lhs.i < rhs.i : lhs.other < rhs.other;
            });

            for (const auto& cand : candidates) {
                if (mergeChecks >= kMaxMergeChecks) break;
                if (removed[cand.i] || removed[cand.other]) continue;
                const auto& original = pieces[cand.i];
                const auto& neighbour = pieces[cand.other];
                if (original.size() + neighbour.size() - 2 > kMaxGdsPolygonVertices) continue;
                size_t aPos = original.size();
                for (size_t a = 0; a < original.size(); ++a) {
                    if (same(original[a], cand.u) && same(original[(a + 1) % original.size()], cand.v)) {
                        aPos = a;
                        break;
                    }
                }
                if (aPos == original.size()) continue;
                size_t bPos = neighbour.size();
                for (size_t b = 0; b < neighbour.size(); ++b) {
                    if (same(neighbour[b], cand.v) && same(neighbour[(b + 1) % neighbour.size()], cand.u)) {
                        bPos = b;
                        break;
                    }
                }
                if (bPos == neighbour.size()) continue;

                Path merged;
                merged.reserve(original.size() + neighbour.size() - 2);
                for (size_t k = 0; k < original.size(); ++k) {
                    merged.push_back(original[(aPos + 1 + k) % original.size()]);
                }
                for (size_t k = 1; k + 1 < neighbour.size(); ++k) {
                    merged.push_back(neighbour[(bPos + 1 + k) % neighbour.size()]);
                }
                if (!distinct(merged)) continue;
                const auto expectedArea2 = GeneralClipper::ringArea2(original) + GeneralClipper::ringArea2(neighbour);
                if (expectedArea2 <= 0 || GeneralClipper::ringArea2(merged) != expectedArea2) continue;
                ++mergeChecks;
                const auto check = GeneralClipper::execute({merged}, {}, ClipType::UNION);
                if (check.approximated || check.contours.size() != 1 ||
                    GeneralClipper::ringArea2(check.contours[0]) != expectedArea2) {
                    continue;
                }
                pieces[cand.i] = std::move(merged);
                removed[cand.other] = true;
                indexPiece(cand.i);
                progress = true;
            }
            if (progress) {
                Paths compacted;
                compacted.reserve(pieces.size());
                for (size_t i = 0; i < pieces.size(); ++i) {
                    if (!removed[i]) compacted.push_back(std::move(pieces[i]));
                }
                pieces = std::move(compacted);
            }
        }
    }

    static Path path(const Clipper2Lib::Path64& p) {
        Path out;
        out.reserve(p.size());
        for (const auto& q : p) out.push_back({q.x, q.y});
        return out;
    }

    static bool distinct(const Path& p) {
        std::set<std::pair<int64_t, int64_t>> seen;
        for (const auto& q : p) if (!seen.emplace(q.x, q.y).second) return false;
        return true;
    }

    static void visitTriangulated(const Clipper2Lib::PolyPath64& node, Paths& pieces) {
        for (const auto& child : node) {
            if (!child->IsHole()) {
                Path outer = path(child->Polygon());
                if (child->Count() == 0 && outer.size() <= kMaxGdsPolygonVertices && distinct(outer)) {
                    pieces.push_back(std::move(outer));
                } else {
                    const IntPoint origin = outer.front();
                    std::vector<std::vector<std::array<double, 2>>> polygon;
                    Path flattened;
                    auto addRing = [&](const Path& ring) {
                        std::vector<std::array<double, 2>> coordinates;
                        for (const auto& q : ring) {
                            coordinates.push_back({double(q.x - origin.x), double(q.y - origin.y)});
                            flattened.push_back(q);
                        }
                        polygon.push_back(std::move(coordinates));
                    };
                    addRing(outer);
                    for (const auto& hole : *child) addRing(path(hole->Polygon()));
                    const auto indices = mapbox::earcut<uint32_t>(polygon);
                    if (indices.empty() || indices.size() % 3) throw std::runtime_error("edit-region-triangulation-error");
                    for (size_t i = 0; i < indices.size(); i += 3) {
                        if (indices[i] >= flattened.size() || indices[i + 1] >= flattened.size() ||
                            indices[i + 2] >= flattened.size()) throw std::runtime_error("edit-region-index-error");
                        Path triangle{flattened[indices[i]], flattened[indices[i + 1]], flattened[indices[i + 2]]};
                        const auto area = GeneralClipper::ringArea2(triangle);
                        if (area == 0) continue;
                        if (area < 0) std::reverse(triangle.begin(), triangle.end());
                        pieces.push_back(std::move(triangle));
                    }
                }
                if (pieces.size() > kMaxPieces) throw std::runtime_error("edit-region-piece-limit");
            }
            visitTriangulated(*child, pieces);
        }
    }
};
}}
#endif
