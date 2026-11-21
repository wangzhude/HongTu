#ifndef HONGTU_NATIVE_JOB_CONTROL_H
#define HONGTU_NATIVE_JOB_CONTROL_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <unordered_map>

namespace hongtu {
class NativeJobCancelled : public std::exception {
public:
    const char* what() const noexcept override { return "作业已取消，未发布结果"; }
};

// Optional readers/engine control. No NAPI calls are made from worker threads.
struct NativeJobControl {
    std::function<void()> checkpoint;
    std::function<void(const std::string&, uint64_t, uint64_t)> progress;
    void check() const { if (checkpoint) checkpoint(); }
    void report(const std::string& stage, uint64_t completed = 0, uint64_t total = 0) const {
        check(); if (progress) progress(stage, completed, total);
    }
};

struct NativeJobProgress {
    std::string jobId, scope, kind, stage = "queued", status = "running", message;
    uint64_t completed = 0, total = 0;
    bool cancelRequested = false;
    bool terminal = false, workerStarted = false, workerStopped = false;
};

class NativeJobState {
public:
    const uintptr_t environment;
    mutable std::mutex mutex;
    std::atomic<bool> cancellation{false};
    std::atomic<bool> workerStarted{false}, workerStopped{false};
    NativeJobProgress progress;
    NativeJobState(uintptr_t env, const std::string& id, const std::string& scope, const std::string& kind)
        : environment(env) { progress.jobId = id; progress.scope = scope; progress.kind = kind; }
    void check() const { if (cancellation.load(std::memory_order_relaxed)) throw NativeJobCancelled(); }
    bool requestCancel() {
        std::lock_guard<std::mutex> lock(mutex);
        if (progress.status != "running") return false;
        cancellation.store(true, std::memory_order_relaxed); progress.cancelRequested = true; return true;
    }
    NativeJobProgress snapshot() const {
        std::lock_guard<std::mutex> lock(mutex); auto out=progress;
        out.terminal=out.status!="running";
        out.workerStarted=workerStarted.load(std::memory_order_acquire);
        out.workerStopped=workerStopped.load(std::memory_order_acquire);
        return out;
    }
    void markWorkerStarted() { workerStarted.store(true,std::memory_order_release); }
    void markWorkerStopped() { workerStopped.store(true,std::memory_order_release); }
    void report(const std::string& stage, uint64_t done, uint64_t total) {
        check(); std::lock_guard<std::mutex> lock(mutex);
        progress.stage = stage; progress.completed = done; progress.total = total;
    }
    void finish(const std::string& status, const std::string& message = "") {
        std::lock_guard<std::mutex> lock(mutex);
        progress.status = status; progress.stage = status; progress.message = message;
    }
    NativeJobControl control() {
        NativeJobControl out;
        out.checkpoint = [this]() { check(); };
        out.progress = [this](const std::string& s, uint64_t d, uint64_t t) { report(s, d, t); };
        return out;
    }
};

// The execution callback owns this guard. It does not turn a cancellation
// request into a stopped worker; only an exited callback sets workerStopped.
class NativeJobExecutionGuard {
    std::shared_ptr<NativeJobState> state;
public:
    explicit NativeJobExecutionGuard(std::shared_ptr<NativeJobState> value):state(std::move(value)) { state->markWorkerStarted(); }
    ~NativeJobExecutionGuard() { state->markWorkerStopped(); }
};

// Environment + caller scope are both required. A job ID alone never authorizes polling/cancellation.
// Only small progress records are retained after completion; async payloads are independently released.
class NativeJobRegistry {
    std::mutex mutex;
    uint64_t nextId = 0;
    std::unordered_map<std::string, std::shared_ptr<NativeJobState>> jobs;
public:
    std::shared_ptr<NativeJobState> create(uintptr_t env, const std::string& scope, const std::string& kind) {
        if (scope.empty() || scope.size() > 256) throw std::runtime_error("作业 scope 无效");
        std::lock_guard<std::mutex> lock(mutex);
        size_t active = 0;
        for (auto it = jobs.begin(); it != jobs.end();) {
            const auto s = it->second->snapshot();
            if (s.status == "running") { ++active; ++it; }
            else if (jobs.size() >= 64) it = jobs.erase(it);
            else ++it;
        }
        if (active >= 8) throw std::runtime_error("后台作业已达 8 个上限");
        const std::string id = "hongtu-job-" + std::to_string(++nextId);
        auto state = std::make_shared<NativeJobState>(env, id, scope, kind); jobs[id] = state; return state;
    }
    std::shared_ptr<NativeJobState> find(uintptr_t env, const std::string& id, const std::string& scope) {
        std::lock_guard<std::mutex> lock(mutex);
        auto it = jobs.find(id);
        if (it == jobs.end() || it->second->environment != env || it->second->progress.scope != scope) return nullptr;
        return it->second;
    }
    void removeEnvironment(uintptr_t env) {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto it = jobs.begin(); it != jobs.end();) {
            if (it->second->environment != env) { ++it; continue; }
            it->second->requestCancel(); it = jobs.erase(it);
        }
    }
};
}
#endif
