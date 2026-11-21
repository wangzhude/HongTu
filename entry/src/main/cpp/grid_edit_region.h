/** Whole regions use an explicit physical nm grid, including sub-nm DBU.
 * Every input is an independently filled polygon. Holes in results are
 * fractured into independently filled editor polygons. No partial result.
 */
#ifndef HONGTU_GRID_EDIT_REGION_H
#define HONGTU_GRID_EDIT_REGION_H
#include <array>
#include <set>
#include "edit_region.h"

namespace hongtu { namespace clipper {
class GridEditRegion {
public:
    using Ring = std::vector<std::array<double, 2>>;
    using Region = std::vector<Ring>;

    static Region execute(const Region& subject, const Region& clip,
                          ClipType operation, double gridNm) {
        if (!std::isfinite(gridNm) || gridNm <= 0)
            throw std::invalid_argument("region-grid-must-be-positive-finite");
        if (static_cast<int>(operation) < 0 || static_cast<int>(operation) > 3)
            throw std::invalid_argument("region-operation-invalid");
        size_t vertices = 0;
        const auto a = encode(subject, gridNm, vertices);
        const auto b = encode(clip, gridNm, vertices);
        // Normalize each filled shape before combining signed regions.
        // Even-odd over all input shapes would cancel their overlaps.
        const auto ua = GeneralClipper::unite(a);
        const auto ub = GeneralClipper::unite(b);
        if (ua.approximated || ub.approximated)
            throw std::runtime_error(ua.approximated ? ua.note : ub.note);
        if (ua.droppedRings || ub.droppedRings)
            throw std::invalid_argument("region-grid-collapsed-polygon");
        const auto result = GeneralClipper::executeNZ(ua.contours, ub.contours, operation);
        const auto pieces = EditRegion::fracture(result);
        Region output;
        for (const auto& piece : pieces) {
            Ring ring;
            for (const auto& p : piece) {
                const double x = static_cast<double>(p.x) * gridNm;
                const double y = static_cast<double>(p.y) * gridNm;
                if (!std::isfinite(x) || !std::isfinite(y))
                    throw std::runtime_error("region-output-overflow");
                ring.push_back({x, y});
            }
            output.push_back(std::move(ring));
        }
        return output;
    }
private:
    static Paths encode(const Region& input, double grid, size_t& vertices) {
        if (input.size() > EditRegion::kMaxPieces)
            throw std::invalid_argument("region-piece-limit");
        Paths output;
        for (const auto& ring : input) {
            if (ring.size() < 3 || ring.size() > EditRegion::kMaxVertices - vertices)
                throw std::invalid_argument("region-vertex-limit-or-incomplete-polygon");
            vertices += ring.size();
            Path path;
            std::set<std::pair<int64_t,int64_t>> distinct;
            for (const auto& p : ring) {
                const long double x = static_cast<long double>(p[0]) / grid;
                const long double y = static_cast<long double>(p[1]) / grid;
                if (!std::isfinite(x) || !std::isfinite(y) ||
                    std::abs(x) > GeneralClipper::kCoordLimit ||
                    std::abs(y) > GeneralClipper::kCoordLimit)
                    throw std::invalid_argument("region-coordinate-grid-range");
                const IntPoint q{std::llround(x),std::llround(y)};
                if (path.empty() || path.back().x != q.x || path.back().y != q.y)
                    path.push_back(q);
                distinct.emplace(q.x,q.y);
            }
            if (path.size() > 1 && path.front().x == path.back().x && path.front().y == path.back().y)
                path.pop_back();
            if (distinct.size() < 3)
                throw std::invalid_argument("region-grid-collapsed-polygon");
            const auto filled = GeneralClipper::execute({path},{},ClipType::UNION);
            if (filled.approximated || filled.contours.empty())
                throw std::invalid_argument("region-grid-collapsed-or-invalid-polygon");
            output.push_back(std::move(path));
        }
        return output;
    }
};
}}
#endif
