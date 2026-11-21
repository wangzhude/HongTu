/**
 * HongTu EDA - R-Tree Spatial Index
 * High-performance spatial indexing for layout shapes.
 * Supports insertion, deletion, point query, range query, and nearest-neighbor.
 * Template parameters: T = shape ID type, D = dimension (default 2)
 */
#ifndef HONGTU_SPATIAL_INDEX_H
#define HONGTU_SPATIAL_INDEX_H

#include <vector>
#include <array>
#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>
#include <cassert>
#include <stack>
#include <queue>

namespace hongtu {

struct BBox {
    double minX, minY, maxX, maxY;

    BBox() : minX(std::numeric_limits<double>::max()),
             minY(std::numeric_limits<double>::max()),
             maxX(std::numeric_limits<double>::lowest()),
             maxY(std::numeric_limits<double>::lowest()) {}

    BBox(double x0, double y0, double x1, double y1)
        : minX(x0), minY(y0), maxX(x1), maxY(y1) {}

    bool valid() const { return minX <= maxX && minY <= maxY; }

    double area() const {
        if (!valid()) return 0.0;
        return (maxX - minX) * (maxY - minY);
    }

    double perimeter() const {
        if (!valid()) return 0.0;
        return 2.0 * ((maxX - minX) + (maxY - minY));
    }

    // Enlargement needed to include other box
    double enlargement(const BBox& other) const {
        BBox combined = unite(other);
        return combined.area() - area();
    }

    BBox unite(const BBox& other) const {
        if (!valid()) return other;
        if (!other.valid()) return *this;
        return BBox(
            std::min(minX, other.minX),
            std::min(minY, other.minY),
            std::max(maxX, other.maxX),
            std::max(maxY, other.maxY)
        );
    }

    bool intersects(const BBox& other) const {
        return minX <= other.maxX && maxX >= other.minX &&
               minY <= other.maxY && maxY >= other.minY;
    }

    bool contains(double x, double y) const {
        return x >= minX && x <= maxX && y >= minY && y <= maxY;
    }

    bool contains(const BBox& other) const {
        return minX <= other.minX && minY <= other.minY &&
               maxX >= other.maxX && maxY >= other.maxY;
    }

    double distanceTo(double x, double y) const {
        double dx = 0.0, dy = 0.0;
        if (x < minX) dx = minX - x;
        else if (x > maxX) dx = x - maxX;
        if (y < minY) dy = minY - y;
        else if (y > maxY) dy = y - maxY;
        return std::sqrt(dx * dx + dy * dy);
    }

    double distanceTo(const BBox& other) const {
        double dx = 0.0, dy = 0.0;
        if (maxX < other.minX) dx = other.minX - maxX;
        else if (other.maxX < minX) dx = minX - other.maxX;
        if (maxY < other.minY) dy = other.minY - maxY;
        else if (other.maxY < minY) dy = minY - other.maxY;
        return std::sqrt(dx * dx + dy * dy);
    }

    BBox expand(double margin) const {
        return BBox(minX - margin, minY - margin, maxX + margin, maxY + margin);
    }

    double centerX() const { return (minX + maxX) * 0.5; }
    double centerY() const { return (minY + maxY) * 0.5; }
};

/**
 * R-Tree with quadratic split (Guttman's algorithm).
 * Optimized for 2D bounding box queries on IC layout data.
 */
template<typename T = int>
class RTree {
public:
    static constexpr int MAX_ENTRIES = 16;  // Max children per node
    static constexpr int MIN_ENTRIES = 6;   // Min children (40% fill)

    struct Entry {
        BBox bbox;
        T id;           // Shape ID (leaf only)
        int childIdx;   // Child node index (internal only)
    };

    struct Node {
        std::vector<Entry> entries;
        bool isLeaf;
        int level;  // 0 = leaf

        Node(bool leaf = true, int lvl = 0) : isLeaf(leaf), level(lvl) {
            entries.reserve(MAX_ENTRIES + 1);
        }

        BBox computeBBox() const {
            BBox box;
            for (const auto& e : entries) {
                box = box.unite(e.bbox);
            }
            return box;
        }
    };

private:
    std::vector<Node> nodes_;
    int rootIdx_;
    size_t size_;

public:
    RTree() : rootIdx_(-1), size_(0) {
        nodes_.reserve(1024);
    }

    size_t size() const { return size_; }
    bool empty() const { return size_ == 0; }

    void clear() {
        nodes_.clear();
        rootIdx_ = -1;
        size_ = 0;
    }

    // Insert a shape with bounding box
    void insert(T id, const BBox& bbox) {
        if (!bbox.valid()) return;

        if (rootIdx_ < 0) {
            rootIdx_ = allocNode(true, 0);
        }

        Entry entry;
        entry.bbox = bbox;
        entry.id = id;
        entry.childIdx = -1;

        int splitNode = insertRecursive(rootIdx_, entry);

        if (splitNode >= 0) {
            // Root was split, create new root
            int newRoot = allocNode(false, nodes_[rootIdx_].level + 1);
            Entry e1;
            e1.bbox = nodes_[rootIdx_].computeBBox();
            e1.childIdx = rootIdx_;
            e1.id = T{};
            Entry e2;
            e2.bbox = nodes_[splitNode].computeBBox();
            e2.childIdx = splitNode;
            e2.id = T{};
            nodes_[newRoot].entries.push_back(e1);
            nodes_[newRoot].entries.push_back(e2);
            rootIdx_ = newRoot;
        }
        size_++;
    }

    // Remove a shape by ID (linear scan - acceptable for moderate deletions)
    bool remove(T id) {
        if (rootIdx_ < 0) return false;
        if (removeRecursive(rootIdx_, id)) {
            size_--;
            // Shrink tree if root has single child
            while (!nodes_[rootIdx_].isLeaf && nodes_[rootIdx_].entries.size() == 1) {
                int oldRoot = rootIdx_;
                rootIdx_ = nodes_[rootIdx_].entries[0].childIdx;
                freeNode(oldRoot);
            }
            if (nodes_[rootIdx_].entries.empty()) {
                freeNode(rootIdx_);
                rootIdx_ = -1;
            }
            return true;
        }
        return false;
    }

    // Point query: find all shapes whose bbox contains (x, y)
    std::vector<T> queryPoint(double x, double y) const {
        std::vector<T> results;
        if (rootIdx_ < 0) return results;
        queryPointRecursive(rootIdx_, x, y, results);
        return results;
    }

    // Range query: find all shapes whose bbox intersects the query box
    std::vector<T> queryRange(const BBox& queryBox) const {
        std::vector<T> results;
        if (rootIdx_ < 0) return results;
        queryRangeRecursive(rootIdx_, queryBox, results);
        return results;
    }

    // Range query with callback (avoids allocation for large result sets)
    void queryRange(const BBox& queryBox, std::function<bool(T)> callback) const {
        if (rootIdx_ < 0) return;
        queryRangeCallback(rootIdx_, queryBox, callback);
    }

    // K-nearest neighbors
    /**
     * k 近邻（best-first 遍历 + 标准剪枝）。
     *
     * 旧实现以「攒够 k*2 个候选」为终止条件、且整份吞下先弹出的叶子条目，缺少
     * R*-Tree 的剪枝判据（未探索节点的最小可能距离 > 第 k 近者才可停），会在真正的
     * 近邻仍位于未展开子树时提前返回——随机版图上与暴力枚举不符率约 47%
     * （tools/engine_smoke.cpp 的差分测试即为此而加）。磁吸/最近邻查询因此会吸到远处图形。
     */
    std::vector<T> queryNearest(double x, double y, int k) const {
        std::vector<T> results;
        if (rootIdx_ < 0 || k <= 0) return results;

        // 待探索节点按「到查询点的最小可能距离」升序出队
        using PQItem = std::pair<double, int>;
        std::priority_queue<PQItem, std::vector<PQItem>, std::greater<PQItem>> pq;
        pq.push({nodes_[rootIdx_].computeBBox().distanceTo(x, y), rootIdx_});

        std::vector<std::pair<double, T>> best;   // 至多 k 个，无序

        while (!pq.empty()) {
            const double minDist = pq.top().first;
            const int nodeIdx = pq.top().second;
            pq.pop();

            if ((int)best.size() >= k) {
                double worst = best[0].first;
                for (const auto& c : best) {
                    worst = std::max(worst, c.first);
                }
                if (minDist > worst) break;   // 队列按距离升序，余下皆不可能更近
            }
            if (nodeIdx < 0 || nodeIdx >= (int)nodes_.size()) continue;

            const Node& node = nodes_[nodeIdx];
            if (node.isLeaf) {
                for (const auto& e : node.entries) {
                    const double d = e.bbox.distanceTo(x, y);
                    if ((int)best.size() < k) {
                        best.push_back({d, e.id});
                        continue;
                    }
                    size_t wi = 0;
                    for (size_t j = 1; j < best.size(); j++) {
                        if (best[j].first > best[wi].first) wi = j;
                    }
                    if (d < best[wi].first) best[wi] = {d, e.id};
                }
            } else {
                for (const auto& e : node.entries) {
                    if (e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                        pq.push({nodes_[e.childIdx].computeBBox().distanceTo(x, y), e.childIdx});
                    }
                }
            }
        }

        std::sort(best.begin(), best.end());
        for (const auto& c : best) {
            results.push_back(c.second);
        }
        return results;
    }

    // Get all shape IDs
    std::vector<T> allIds() const {
        std::vector<T> results;
        results.reserve(size_);
        if (rootIdx_ < 0) return results;
        collectAll(rootIdx_, results);
        return results;
    }

    // Bulk load using Sort-Tile-Recursive (STR) for optimal packing
    void bulkLoad(const std::vector<std::pair<T, BBox>>& items) {
        clear();
        if (items.empty()) return;

        // For small datasets, simple insertion is fine
        if (items.size() < 100) {
            for (const auto& [id, bbox] : items) {
                insert(id, bbox);
            }
            return;
        }

        // STR bulk loading
        std::vector<std::pair<T, BBox>> sorted = items;
        // Sort by X center
        std::sort(sorted.begin(), sorted.end(),
            [](const auto& a, const auto& b) {
                return a.second.centerX() < b.second.centerX();
            });

        // Create leaf nodes
        int numLeaves = (int)((sorted.size() + MAX_ENTRIES - 1) / MAX_ENTRIES);
        int sliceSize = (int)std::ceil(std::sqrt((double)numLeaves));
        int itemsPerSlice = sliceSize * MAX_ENTRIES;

        std::vector<int> leafNodes;

        for (size_t i = 0; i < sorted.size(); i += itemsPerSlice) {
            size_t sliceEnd = std::min(i + itemsPerSlice, sorted.size());
            // Sort slice by Y center
            std::sort(sorted.begin() + i, sorted.begin() + sliceEnd,
                [](const auto& a, const auto& b) {
                    return a.second.centerY() < b.second.centerY();
                });

            // Pack into leaf nodes
            for (size_t j = i; j < sliceEnd; j += MAX_ENTRIES) {
                int nodeIdx = allocNode(true, 0);
                Node& node = nodes_[nodeIdx];
                size_t end = std::min(j + MAX_ENTRIES, sliceEnd);
                for (size_t k = j; k < end; k++) {
                    Entry e;
                    e.bbox = sorted[k].second;
                    e.id = sorted[k].first;
                    e.childIdx = -1;
                    node.entries.push_back(e);
                }
                leafNodes.push_back(nodeIdx);
            }
        }

        // Build internal levels bottom-up
        std::vector<int> currentLevel = leafNodes;
        int level = 1;

        while (currentLevel.size() > 1) {
            std::vector<int> nextLevel;
            for (size_t i = 0; i < currentLevel.size(); i += MAX_ENTRIES) {
                int parentIdx = allocNode(false, level);
                Node& parent = nodes_[parentIdx];
                size_t end = std::min(i + MAX_ENTRIES, currentLevel.size());
                for (size_t j = i; j < end; j++) {
                    Entry e;
                    e.bbox = nodes_[currentLevel[j]].computeBBox();
                    e.childIdx = currentLevel[j];
                    e.id = T{};
                    parent.entries.push_back(e);
                }
                nextLevel.push_back(parentIdx);
            }
            currentLevel = nextLevel;
            level++;
        }

        rootIdx_ = currentLevel[0];
        size_ = items.size();
    }

    // Statistics for debugging
    struct Stats {
        int totalNodes = 0;
        int leafNodes = 0;
        int maxDepth = 0;
        double avgFill = 0.0;
    };

    Stats getStats() const {
        Stats s;
        if (rootIdx_ < 0) return s;
        computeStats(rootIdx_, s, 0);
        if (s.leafNodes > 0) {
            s.avgFill = (double)size_ / (s.leafNodes * MAX_ENTRIES);
        }
        return s;
    }

private:
    int allocNode(bool isLeaf, int level) {
        int idx = (int)nodes_.size();
        nodes_.emplace_back(isLeaf, level);
        return idx;
    }

    void freeNode(int idx) {
        // Mark as empty (tombstone) - we don't reclaim for simplicity
        if (idx >= 0 && idx < (int)nodes_.size()) {
            nodes_[idx].entries.clear();
        }
    }

    int insertRecursive(int nodeIdx, const Entry& entry) {
        if (nodes_[nodeIdx].isLeaf) {
            nodes_[nodeIdx].entries.push_back(entry);
            if ((int)nodes_[nodeIdx].entries.size() > MAX_ENTRIES) {
                return splitNode(nodeIdx);
            }
            return -1;
        }

        // Choose subtree: minimum enlargement
        int bestChild = 0;
        double bestEnlargement = std::numeric_limits<double>::max();
        double bestArea = std::numeric_limits<double>::max();

        for (int i = 0; i < (int)nodes_[nodeIdx].entries.size(); i++) {
            double enlargement = nodes_[nodeIdx].entries[i].bbox.enlargement(entry.bbox);
            double area = nodes_[nodeIdx].entries[i].bbox.area();
            if (enlargement < bestEnlargement ||
                (enlargement == bestEnlargement && area < bestArea)) {
                bestEnlargement = enlargement;
                bestArea = area;
                bestChild = i;
            }
        }

        int childIdx = nodes_[nodeIdx].entries[bestChild].childIdx;
        int splitResult = insertRecursive(childIdx, entry);

        // Re-fetch reference (vector may have reallocated during recursion)
        nodes_[nodeIdx].entries[bestChild].bbox = nodes_[childIdx].computeBBox();

        if (splitResult >= 0) {
            // Child was split, add new entry
            Entry newEntry;
            newEntry.bbox = nodes_[splitResult].computeBBox();
            newEntry.childIdx = splitResult;
            newEntry.id = T{};
            nodes_[nodeIdx].entries.push_back(newEntry);

            if ((int)nodes_[nodeIdx].entries.size() > MAX_ENTRIES) {
                return splitNode(nodeIdx);
            }
        }

        return -1;
    }

    // Quadratic split (Guttman)
    int splitNode(int nodeIdx) {
        std::vector<Entry> entries = std::move(nodes_[nodeIdx].entries);
        nodes_[nodeIdx].entries.clear();
        bool isLeaf = nodes_[nodeIdx].isLeaf;
        int level = nodes_[nodeIdx].level;

        // Pick seeds: maximum wasted area
        int seed1 = 0, seed2 = 1;
        double worstWaste = std::numeric_limits<double>::lowest();

        for (int i = 0; i < (int)entries.size(); i++) {
            for (int j = i + 1; j < (int)entries.size(); j++) {
                BBox combined = entries[i].bbox.unite(entries[j].bbox);
                double waste = combined.area() - entries[i].bbox.area() - entries[j].bbox.area();
                if (waste > worstWaste) {
                    worstWaste = waste;
                    seed1 = i;
                    seed2 = j;
                }
            }
        }

        int newNodeIdx = allocNode(isLeaf, level);
        // NOTE: allocNode may reallocate nodes_, so don't hold references across it

        nodes_[nodeIdx].entries.push_back(entries[seed1]);
        nodes_[newNodeIdx].entries.push_back(entries[seed2]);

        BBox bbox1 = entries[seed1].bbox;
        BBox bbox2 = entries[seed2].bbox;

        std::vector<bool> assigned(entries.size(), false);
        assigned[seed1] = true;
        assigned[seed2] = true;

        int remaining = (int)entries.size() - 2;

        while (remaining > 0) {
            // Check if one group needs all remaining to meet minimum
            if ((int)nodes_[nodeIdx].entries.size() + remaining <= MIN_ENTRIES) {
                for (int i = 0; i < (int)entries.size(); i++) {
                    if (!assigned[i]) {
                        nodes_[nodeIdx].entries.push_back(entries[i]);
                        bbox1 = bbox1.unite(entries[i].bbox);
                        assigned[i] = true;
                        remaining--;
                    }
                }
                break;
            }
            if ((int)nodes_[newNodeIdx].entries.size() + remaining <= MIN_ENTRIES) {
                for (int i = 0; i < (int)entries.size(); i++) {
                    if (!assigned[i]) {
                        nodes_[newNodeIdx].entries.push_back(entries[i]);
                        bbox2 = bbox2.unite(entries[i].bbox);
                        assigned[i] = true;
                        remaining--;
                    }
                }
                break;
            }

            // Pick next: maximum difference in enlargement
            int bestIdx = -1;
            double bestDiff = std::numeric_limits<double>::lowest();

            for (int i = 0; i < (int)entries.size(); i++) {
                if (assigned[i]) continue;
                double d1 = bbox1.enlargement(entries[i].bbox);
                double d2 = bbox2.enlargement(entries[i].bbox);
                double diff = std::abs(d1 - d2);
                if (diff > bestDiff) {
                    bestDiff = diff;
                    bestIdx = i;
                }
            }

            if (bestIdx < 0) break;

            // Assign to group needing less enlargement
            double d1 = bbox1.enlargement(entries[bestIdx].bbox);
            double d2 = bbox2.enlargement(entries[bestIdx].bbox);

            if (d1 < d2 || (d1 == d2 && bbox1.area() <= bbox2.area())) {
                nodes_[nodeIdx].entries.push_back(entries[bestIdx]);
                bbox1 = bbox1.unite(entries[bestIdx].bbox);
            } else {
                nodes_[newNodeIdx].entries.push_back(entries[bestIdx]);
                bbox2 = bbox2.unite(entries[bestIdx].bbox);
            }
            assigned[bestIdx] = true;
            remaining--;
        }

        return newNodeIdx;
    }

    bool removeRecursive(int nodeIdx, T id) {
        Node& node = nodes_[nodeIdx];

        if (node.isLeaf) {
            for (int i = 0; i < (int)node.entries.size(); i++) {
                if (node.entries[i].id == id) {
                    node.entries.erase(node.entries.begin() + i);
                    return true;
                }
            }
            return false;
        }

        for (int i = 0; i < (int)node.entries.size(); i++) {
            int childIdx = node.entries[i].childIdx;
            if (childIdx >= 0 && removeRecursive(childIdx, id)) {
                if (nodes_[childIdx].entries.empty()) {
                    freeNode(childIdx);
                    node.entries.erase(node.entries.begin() + i);
                } else {
                    node.entries[i].bbox = nodes_[childIdx].computeBBox();
                }
                return true;
            }
        }
        return false;
    }

    void queryPointRecursive(int nodeIdx, double x, double y, std::vector<T>& results) const {
        const Node& node = nodes_[nodeIdx];

        if (node.isLeaf) {
            for (const auto& e : node.entries) {
                if (e.bbox.contains(x, y)) {
                    results.push_back(e.id);
                }
            }
        } else {
            for (const auto& e : node.entries) {
                if (e.bbox.contains(x, y) && e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                    queryPointRecursive(e.childIdx, x, y, results);
                }
            }
        }
    }

    void queryRangeRecursive(int nodeIdx, const BBox& queryBox, std::vector<T>& results) const {
        const Node& node = nodes_[nodeIdx];

        if (node.isLeaf) {
            for (const auto& e : node.entries) {
                if (e.bbox.intersects(queryBox)) {
                    results.push_back(e.id);
                }
            }
        } else {
            for (const auto& e : node.entries) {
                if (e.bbox.intersects(queryBox) && e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                    queryRangeRecursive(e.childIdx, queryBox, results);
                }
            }
        }
    }

    bool queryRangeCallback(int nodeIdx, const BBox& queryBox, std::function<bool(T)>& callback) const {
        const Node& node = nodes_[nodeIdx];

        if (node.isLeaf) {
            for (const auto& e : node.entries) {
                if (e.bbox.intersects(queryBox)) {
                    if (!callback(e.id)) return false;
                }
            }
        } else {
            for (const auto& e : node.entries) {
                if (e.bbox.intersects(queryBox) && e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                    if (!queryRangeCallback(e.childIdx, queryBox, callback)) return false;
                }
            }
        }
        return true;
    }

    void collectAll(int nodeIdx, std::vector<T>& results) const {
        const Node& node = nodes_[nodeIdx];
        if (node.isLeaf) {
            for (const auto& e : node.entries) {
                results.push_back(e.id);
            }
        } else {
            for (const auto& e : node.entries) {
                if (e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                    collectAll(e.childIdx, results);
                }
            }
        }
    }

    void computeStats(int nodeIdx, Stats& s, int depth) const {
        s.totalNodes++;
        s.maxDepth = std::max(s.maxDepth, depth);
        const Node& node = nodes_[nodeIdx];
        if (node.isLeaf) {
            s.leafNodes++;
        } else {
            for (const auto& e : node.entries) {
                if (e.childIdx >= 0 && e.childIdx < (int)nodes_.size()) {
                    computeStats(e.childIdx, s, depth + 1);
                }
            }
        }
    }
};

} // namespace hongtu

#endif // HONGTU_SPATIAL_INDEX_H
