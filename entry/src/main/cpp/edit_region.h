/** Convert a signed region into independent filled editor shapes, without bridges. */
#ifndef HONGTU_EDIT_REGION_H
#define HONGTU_EDIT_REGION_H
#include <array>
#include <set>
#include <map>
#include <stdexcept>
#include "clipper_engine.h"
#include "vendor/earcut/earcut.hpp"

namespace hongtu { namespace clipper {
class EditRegion {
public:
    // Editing has a separate resource ceiling: triangulation can expand shape count.
    static constexpr size_t kMaxVertices = 20000;
    static constexpr size_t kMaxPieces = 40000;

    static Paths fracture(const GeneralClipper::Output& source) {
        if (source.approximated) throw std::runtime_error(source.note);
        if (source.contours.empty()) return {};
        // Existing simple outer rings already satisfy the editor contract.
        // Re-clipping can remove an integer-grid spike around a previously
        // rounded intersection; do not change geometry merely to copy it.
        bool alreadySimple = true;
        size_t inputVertices=0;
        for (const auto& p:source.contours) {
            inputVertices+=p.size();
            if(inputVertices>kMaxVertices) throw std::runtime_error("edit-region-vertex-limit");
            alreadySimple = alreadySimple && GeneralClipper::ringArea2(p)>0 && distinct(p);
        }
        if (alreadySimple) return source.contours;
        size_t vertices = 0;
        Clipper2Lib::Paths64 paths;
        for (const auto& ring : source.contours) {
            vertices += ring.size();
            if (vertices > kMaxVertices) throw std::runtime_error("edit-region-vertex-limit");
            Clipper2Lib::Path64 p;
            for (const auto& q : ring) p.emplace_back(q.x,q.y);
            paths.push_back(std::move(p));
        }
        Clipper2Lib::Clipper64 engine;
        engine.AddSubject(paths);
        Clipper2Lib::PolyTree64 tree;
        if (!engine.Execute(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, tree)
            || engine.ErrorCode()) throw std::runtime_error("edit-region-tree-error");
        Paths pieces;
        visit(tree,pieces);
        coalesceThinPieces(pieces);
        auto verifyPieces = [&](const Paths& candidate) -> bool {
            auto united = GeneralClipper::executeNZ(candidate,{},ClipType::UNION);
            auto parity = GeneralClipper::execute(candidate,{},ClipType::UNION);
            auto difference = GeneralClipper::executeNZ(source.contours,united.contours,ClipType::XOR);
            auto overlap = GeneralClipper::executeNZ(united.contours,parity.contours,ClipType::XOR);
            return !united.approximated && !parity.approximated && !difference.approximated &&
                   !overlap.approximated && difference.contours.empty() && overlap.contours.empty();
        };
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
        // Spatial equality, not area alone: a missing hole and excess material
        // cannot cancel. Also compare XOR of pieces to catch double coverage.
        if (!verifyPieces(pieces))
            throw std::runtime_error("edit-region-decomposition-mismatch");
        return pieces;
    }
private:
    using Edge = std::array<int64_t,4>;
    static Edge edge(const IntPoint& a,const IntPoint& b) { return {a.x,a.y,b.x,b.y}; }
    static bool same(const IntPoint& a,const IntPoint& b) { return a.x==b.x && a.y==b.y; }
    static bool filled(const Path& p) {
        const auto result=GeneralClipper::execute({p},{},ClipType::UNION);
        if(result.approximated) throw std::runtime_error(result.note);
        return !result.contours.empty();
    }
    // Some integer-grid triangulation faces are thinner than Clipper's
    // minimum standalone polygon tolerance. Discarding one loses real grid
    // material when it is part of a wider region. Join that face with an
    // adjacent face by cancelling only their common reversed edge. This is a
    // topological union, with no clipping, rounding, new vertex or material loss.
    static void coalesceThinPieces(Paths& pieces) {
        std::map<Edge,std::vector<size_t>> edges;
        std::vector<bool> removed(pieces.size(),false);
        size_t indexedEdges=0;
        auto index=[&](size_t i) {
            const auto& p=pieces[i];
            if(p.size()>1000000-indexedEdges) throw std::runtime_error("edit-region-coalesce-edge-budget");
            indexedEdges+=p.size();
            for(size_t k=0;k<p.size();++k) edges[edge(p[k],p[(k+1)%p.size()])].push_back(i);
        };
        for(size_t i=0;i<pieces.size();++i) index(i);
        size_t probes=0;
        for(size_t i=0;i<pieces.size();++i) {
            if(removed[i]) continue;
            while(!filled(pieces[i])) {
                bool joined=false;
                const auto original=pieces[i];
                for(size_t a=0;a<original.size() && !joined;++a) {
                    const auto found=edges.find(edge(original[(a+1)%original.size()],original[a]));
                    if(found==edges.end()) continue;
                    for(size_t other:found->second) {
                        if(++probes>2000000) throw std::runtime_error("edit-region-coalesce-budget");
                        if(other==i || removed[other]) continue;
                        const auto& neighbour=pieces[other];
                        for(size_t b=0;b<neighbour.size() && !joined;++b) {
                            if(!same(original[a],neighbour[(b+1)%neighbour.size()]) ||
                               !same(original[(a+1)%original.size()],neighbour[b])) continue;
                            Path merged;
                            for(size_t k=0;k<original.size();++k) merged.push_back(original[(a+1+k)%original.size()]);
                            for(size_t k=1;k+1<neighbour.size();++k) merged.push_back(neighbour[(b+1+k)%neighbour.size()]);
                            if(merged.size()>kMaxVertices || !distinct(merged) ||
                               GeneralClipper::ringArea2(merged)!=GeneralClipper::ringArea2(original)+GeneralClipper::ringArea2(neighbour)) continue;
                            pieces[i]=std::move(merged);removed[other]=true;index(i);joined=true;
                        }
                        if(joined) break;
                    }
                }
                if(!joined) throw std::runtime_error("edit-region-unrepresentable-thin-piece");
            }
        }
        Paths output;
        for(size_t i=0;i<pieces.size();++i) if(!removed[i]) output.push_back(std::move(pieces[i]));
        pieces=std::move(output);
    }
    static double edgeLenSq(const IntPoint& a, const IntPoint& b) {
        const double dx = static_cast<double>(a.x) - static_cast<double>(b.x);
        const double dy = static_cast<double>(a.y) - static_cast<double>(b.y);
        return dx * dx + dy * dy;
    }
    // Merge adjacent triangulation faces across shared reversed interior diagonals
    // (longest diagonals first) while keeping every resulting piece strictly simple
    // (pairwise distinct vertices, exact additive area, single Clipper contour).
    // For a square with 1 circular hole, this collapses 68 earcut triangles into
    // 2 clean non-self-touching polygons matching KLayout's hole-split count.
    static void coalesceSimplePieces(Paths& pieces) {
        static constexpr size_t kMaxMergeChecks = 4096;
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
                if (original.size() + neighbour.size() - 2 > kMaxVertices) continue;
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
        Path out; for (const auto& q:p) out.push_back({q.x,q.y}); return out;
    }
    static bool distinct(const Path& p) {
        std::set<std::pair<int64_t,int64_t>> seen;
        for (const auto& q:p) if (!seen.emplace(q.x,q.y).second) return false;
        return true;
    }
    static void visit(const Clipper2Lib::PolyPath64& node, Paths& pieces) {
        for (const auto& child:node) {
            if (!child->IsHole()) {
                Path outer = path(child->Polygon());
                if (child->Count()==0 && distinct(outer)) {
                    pieces.push_back(std::move(outer));
                } else {
                    // Translate before floating predicates, preserving small DBU
                    // geometry at large absolute coordinates. No new vertices.
                    const IntPoint origin = outer.front();
                    std::vector<std::vector<std::array<double,2>>> polygon;
                    Path flattened;
                    auto addRing = [&](const Path& ring) {
                        std::vector<std::array<double,2>> coordinates;
                        for (const auto& q:ring) {
                            coordinates.push_back({double(q.x-origin.x),double(q.y-origin.y)});
                            flattened.push_back(q);
                        }
                        polygon.push_back(std::move(coordinates));
                    };
                    addRing(outer);
                    for (const auto& hole:*child) addRing(path(hole->Polygon()));
                    const auto indices = mapbox::earcut<uint32_t>(polygon);
                    if (indices.empty() || indices.size()%3) throw std::runtime_error("edit-region-triangulation-error");
                    for (size_t i=0;i<indices.size();i+=3) {
                        if (indices[i]>=flattened.size() || indices[i+1]>=flattened.size() ||
                            indices[i+2]>=flattened.size()) throw std::runtime_error("edit-region-index-error");
                        Path triangle{flattened[indices[i]],flattened[indices[i+1]],flattened[indices[i+2]]};
                        const auto area = GeneralClipper::ringArea2(triangle);
                        if (area==0) continue;
                        if (area<0) std::reverse(triangle.begin(),triangle.end());
                        pieces.push_back(std::move(triangle));
                    }
                }
                if (pieces.size()>kMaxPieces) throw std::runtime_error("edit-region-piece-limit");
            }
            visit(*child,pieces); // islands nested inside holes
        }
    }
};
}}
#endif
