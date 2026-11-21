#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace hongtu {
// Pure geometry helpers shared by the renderer and host tests. Every four input
// vertices form an independent rectangle; no edge/triangle crosses a rectangle.
template<typename Vertex>
inline bool finiteRectangle(const std::vector<Vertex>& vertices, size_t offset) {
    for (size_t i = 0; i < 4; ++i) {
        if (!std::isfinite(vertices[offset + i].x) || !std::isfinite(vertices[offset + i].y)) return false;
    }
    return true;
}

template<typename Vertex>
inline size_t appendRectangleTriangles(const std::vector<Vertex>& vertices, size_t count,
                                      std::vector<Vertex>& output) {
    const size_t end = std::min(count, vertices.size()) / 4 * 4;
    size_t rectangles = 0;
    constexpr size_t indices[] = {0, 1, 2, 0, 2, 3};
    for (size_t first = 0; first < end; first += 4) {
        if (!finiteRectangle(vertices, first)) continue;
        for (size_t index : indices) output.push_back(vertices[first + index]);
        ++rectangles;
    }
    return rectangles;
}

template<typename Vertex>
inline size_t appendRectangleEdges(const std::vector<Vertex>& vertices, size_t count,
                                  std::vector<Vertex>& output) {
    const size_t end = std::min(count, vertices.size()) / 4 * 4;
    size_t rectangles = 0;
    constexpr size_t indices[] = {0, 1, 1, 2, 2, 3, 3, 0};
    for (size_t first = 0; first < end; first += 4) {
        if (!finiteRectangle(vertices, first)) continue;
        for (size_t index : indices) output.push_back(vertices[first + index]);
        ++rectangles;
    }
    return rectangles;
}
} // namespace hongtu
