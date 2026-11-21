#ifndef HONGTU_READONLY_SCENE_CACHE_H
#define HONGTU_READONLY_SCENE_CACHE_H

#ifndef HONGTU_READONLY_SCENE_HOST_NAPI
#include <napi/native_api.h>
#endif
#include "hierarchy_render_batches.h"
#include "native_import_estimate.h"
#include <memory>
#include <sstream>

namespace hongtu {

// Geometry arrays belong to the workspace. A retained NAPI identity plus the
// monotonic workspace checkpoint revision protects cached immutable layouts.
// Cell names and document metadata are independently compared on every request.
// In-place geometry edits MUST advance revision; callers already own that CAS.
struct ReadonlySceneMetadata {
    std::vector<std::string> cells;
    std::string libName;
    double physicalUnits = 0, userUnits = 0;
    int topCellId = 0;
    bool operator==(const ReadonlySceneMetadata& other) const {
        return cells == other.cells && libName == other.libName && physicalUnits == other.physicalUnits &&
            userUnits == other.userUnits && topCellId == other.topCellId;
    }
};

class ReadonlySceneCache {
public:
    struct Entry {
        double revision = 0;
        napi_ref shapes = nullptr;
        ReadonlySceneMetadata metadata;
        std::shared_ptr<Layout> layout;
        InteractiveImportEstimate estimate;
        uint64_t generation = 0;
    };
    explicit ReadonlySceneCache(napi_env env) : env_(env) {}
    ~ReadonlySceneCache() { clear(); }
    ReadonlySceneCache(const ReadonlySceneCache&) = delete;
    ReadonlySceneCache& operator=(const ReadonlySceneCache&) = delete;
    std::unordered_map<std::string, Entry> entries;
    std::string sceneFingerprint;
    std::vector<RenderBatch> sceneBatches;
    double sceneOriginX = 0.0;
    double sceneOriginY = 0.0;
    uint64_t appliedRendererPublication = 0;
    uint64_t layoutBuilds = 0, layoutHits = 0, sceneHits = 0;

    Entry* find(const std::string& id, double revision, napi_value shapes, const ReadonlySceneMetadata& metadata) {
        const auto found = entries.find(id);
        if (found == entries.end()) return nullptr;
        auto& entry = found->second;
        napi_value retained = nullptr;
        bool same = false;
        if (entry.revision == revision && entry.metadata == metadata &&
            napi_get_reference_value(env_, entry.shapes, &retained) == napi_ok &&
            napi_strict_equals(env_, retained, shapes, &same) == napi_ok && same) {
            ++layoutHits; return &entry;
        }
        return nullptr;
    }
    Entry& store(const std::string& id, double revision, napi_value shapes, ReadonlySceneMetadata metadata,
                 std::unique_ptr<Layout> layout, const InteractiveImportEstimate& estimate) {
        napi_ref retained = nullptr;
        if (napi_create_reference(env_, shapes, 1, &retained) != napi_ok)
            throw std::runtime_error("Composite source geometry identity cannot be retained");
        auto found = entries.find(id);
        if (found != entries.end()) release(found->second);
        else if (entries.size() >= 65) {
            auto victim = entries.begin(); release(victim->second); entries.erase(victim);
        }
        auto& entry = entries[id];
        entry.revision = revision; entry.shapes = retained; entry.metadata = std::move(metadata);
        entry.layout = std::move(layout); entry.estimate = estimate; entry.generation = ++layoutBuilds;
        return entry;
    }
    void prune(const std::unordered_map<std::string, bool>& current) {
        for (auto it = entries.begin(); it != entries.end();) {
            if (current.find(it->first) == current.end()) { release(it->second); it = entries.erase(it); }
            else ++it;
        }
    }
    void invalidateScene() {
        sceneFingerprint.clear();
        sceneBatches.clear();
        sceneOriginX = 0.0;
        sceneOriginY = 0.0;
        appliedRendererPublication = 0;
    }
    void clear() {
        invalidateScene();
        std::vector<RenderBatch>().swap(sceneBatches);
        for (auto& entry : entries) release(entry.second);
        entries.clear();
    }
private:
    napi_env env_;
    void release(Entry& entry) {
        if (entry.shapes) napi_delete_reference(env_, entry.shapes);
        entry.shapes = nullptr;
    }
};

inline std::unordered_map<napi_env, std::unique_ptr<ReadonlySceneCache>>& ReadonlySceneCaches() {
    static thread_local std::unordered_map<napi_env, std::unique_ptr<ReadonlySceneCache>> caches;
    return caches;
}
inline void CleanupReadonlySceneCache(void* data) {
    ReadonlySceneCaches().erase(static_cast<napi_env>(data));
}
inline ReadonlySceneCache& GetReadonlySceneCache(napi_env env) {
    auto& caches = ReadonlySceneCaches();
    auto found = caches.find(env);
    if (found != caches.end()) return *found->second;
    if (napi_add_env_cleanup_hook(env, CleanupReadonlySceneCache, env) != napi_ok)
        throw std::runtime_error("Composite scene cache cleanup cannot be registered");
    auto& cache = caches[env]; cache = std::make_unique<ReadonlySceneCache>(env); return *cache;
}

inline void AppendReadonlySceneFingerprint(std::ostringstream& out, const std::string& id,
    const ReadonlySceneCache::Entry& entry, int cell, int depth, const HierarchyRenderSource& source,
    const HierarchyLayerStyles& styles) {
    const auto& t = source.transform;
    out << id.size() << ':' << id << ':' << entry.generation << ':' << cell << ':' << depth << ':' << source.sourceOrder
        << ':' << std::hexfloat << t.a << ':' << t.b << ':' << t.c << ':' << t.d << ':' << t.tx << ':' << t.ty << ':' << source.opacity << ';';
    std::vector<std::pair<LayerKey, HierarchyLayerStyle>> ordered(styles.begin(), styles.end());
    std::sort(ordered.begin(), ordered.end(), [](const auto& a, const auto& b) {
        return a.first.layer != b.first.layer ? a.first.layer < b.first.layer : a.first.datatype < b.first.datatype;
    });
    for (const auto& item : ordered) {
        out << item.first.layer << '/' << item.first.datatype << ':' << item.second.visible
            << ':' << item.second.strokeOnly << ':' << item.second.fillPattern;
        for (float color : item.second.color) out << ':' << color;
        out << ';';
    }
}

} // namespace hongtu
#endif
