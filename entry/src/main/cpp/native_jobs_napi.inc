// Included after document snapshot helpers. All JS access stays on the NAPI thread.
static NativeJobRegistry g_nativeJobs;
static void CleanupNativeJobs(void* environment) {
    g_nativeJobs.removeEnvironment(reinterpret_cast<uintptr_t>(environment));
}
static bool GetJobBool(napi_env env, napi_value object, const char* name, bool fallback) {
    napi_value value = nullptr; bool out = fallback;
    if (napi_get_named_property(env, object, name, &value) == napi_ok) napi_get_value_bool(env, value, &out);
    return out;
}

struct NativeAsyncJobData {
    std::shared_ptr<NativeJobState> state;
    NativeJobControl control;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string path, documentId, error, format;
    double inputVersion = 0;
    bool isOasis = false, quickScan = false, drc = false, publishToActive = true;
    GdsiiParseResult parsed;
    std::unique_ptr<Layout> stagedLayout;
    InteractiveImportEstimate estimate;
    std::vector<DrcRule> rules;
    DrcConfig config;
    std::vector<DrcViolation> violations;
    DrcRunStats stats;
    std::string status = "running";
};

static napi_value CreateNativeJobProgress(napi_env env, const NativeJobProgress& p) {
    napi_value out; napi_create_object(env, &out);
    SetProp(env, out, "jobId", CreateString(env, p.jobId));
    SetProp(env, out, "scope", CreateString(env, p.scope));
    SetProp(env, out, "kind", CreateString(env, p.kind));
    SetProp(env, out, "stage", CreateString(env, p.stage));
    SetProp(env, out, "status", CreateString(env, p.status));
    SetProp(env, out, "completed", CreateDouble(env, p.completed));
    SetProp(env, out, "total", CreateDouble(env, p.total));
    SetProp(env, out, "cancelRequested", CreateBool(env, p.cancelRequested));
    SetProp(env, out, "terminal", CreateBool(env, p.terminal));
    SetProp(env, out, "workerStarted", CreateBool(env, p.workerStarted));
    SetProp(env, out, "workerStopped", CreateBool(env, p.workerStopped));
    SetProp(env, out, "message", CreateString(env, p.message));
    return out;
}

static napi_value CreateImportEstimate(napi_env env, const InteractiveImportEstimate& e) {
    napi_value out; napi_create_object(env, &out);
    SetProp(env, out, "storedShapes", CreateDouble(env, e.storedShapes));
    SetProp(env, out, "coordinates", CreateDouble(env, e.coordinates));
    SetProp(env, out, "instanceRecords", CreateDouble(env, e.instanceRecords));
    SetProp(env, out, "arrayMembers", CreateDouble(env, e.arrayMembers));
    SetProp(env, out, "expandedObjects", CreateDouble(env, e.expandedObjects));
    SetProp(env, out, "expandedPlacements", CreateDouble(env, e.expandedPlacements));
    SetProp(env, out, "geometryBytes", CreateDouble(env, e.geometryBytes));
    SetProp(env, out, "bounded", CreateBool(env, e.bounded));
    SetProp(env, out, "withinBudget", CreateBool(env, e.withinBudget));
    SetProp(env, out, "message", CreateString(env, e.message));
    return out;
}

static std::vector<DrcRule> ReadJobRules(napi_env env, napi_value array) {
    uint32_t count = 0;
    if (napi_get_array_length(env, array, &count) != napi_ok || count > 10000)
        throw std::invalid_argument("DRC 规则必须为不超过 10000 项的数组");
    std::vector<DrcRule> rules; rules.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        napi_value r = nullptr; napi_get_element(env, array, i, &r);
        DrcRule rule;
        rule.id = GetObjString(env, r, "id", ""); rule.name = GetObjString(env, r, "name", "");
        const int type = GetObjInt(env, r, "type", -1);
        // 与同步 NapiRunDrc 对齐：完整接纳 0..DENSITY_UNIFORMITY 枚举值，
        // 交由 DrcEngine::run 按 enabled 状态执行并在未实现规则上生成结构化 DRC.EXEC 告警，
        // 避免混入 MIN_EXTENSION / DENSITY_UNIFORMITY 时抛异常中断整批后台 DRC 作业。
        if (type < 0 || type > static_cast<int>(DrcRuleType::DENSITY_UNIFORMITY))
            throw std::invalid_argument("DRC 规则类型无效");
        rule.type = static_cast<DrcRuleType>(type);
        rule.layer1 = GetObjInt(env, r, "layer1", 0); rule.datatype1 = GetObjInt(env, r, "datatype1", 0);
        rule.layer2 = GetObjInt(env, r, "layer2", 0); rule.datatype2 = GetObjInt(env, r, "datatype2", 0);
        rule.value = GetObjDouble(env, r, "value", 0); rule.value2 = GetObjDouble(env, r, "value2", 0);
        rule.enabled = GetJobBool(env, r, "enabled", true);
        rule.exactDatatype1 = GetJobBool(env, r, "exactDatatype1", false);
        rule.exactDatatype2 = GetJobBool(env, r, "exactDatatype2", false);
        if (!std::isfinite(rule.value) || !std::isfinite(rule.value2)) throw std::invalid_argument("DRC 规则数值无效");
        rules.push_back(std::move(rule));
    }
    return rules;
}

static napi_value CreateJobViolations(napi_env env, const std::vector<DrcViolation>& violations, const DrcRunStats& st);

static void NativeJobExecute(napi_env, void* payload) {
    auto* job = static_cast<NativeAsyncJobData*>(payload);
    NativeJobExecutionGuard execution(job->state);
    try {
        job->control.check();
        if (!job->drc) {
            if (job->format == "cif") { CifReader r; job->parsed = r.parse(job->path, &job->control); }
            else if (job->format == "dxf") { DxfReader r; job->parsed = r.parse(job->path, &job->control); }
            else if (job->isOasis) { OasisReader r; job->parsed = job->quickScan ? r.quickInfo(job->path, &job->control) : r.parse(job->path, &job->control); }
            else { GdsiiReader r; job->parsed = job->quickScan ? r.quickInfo(job->path, &job->control) : r.parse(job->path, &job->control); }
            if (!job->parsed.success) throw std::runtime_error(job->parsed.errorMessage);
        }
        if (!job->quickScan) {
            job->control.report("budget");
            job->estimate = EstimateInteractiveImport(job->parsed, &job->control);
            if (!job->estimate.withinBudget) throw std::runtime_error(job->estimate.message);
            job->control.report("indexing", 0, job->parsed.shapes.size());
            job->stagedLayout = BuildSceneLayoutFromParseResult(job->parsed, &job->control);
        }
        if (job->drc) {
            DrcEngine engine; for (const auto& rule : job->rules) engine.addRule(rule);
            job->config.checkpoint = job->control.checkpoint;
            job->control.report("checking", 0, 100);
            job->violations = engine.run(*job->stagedLayout, job->config,
                [job](int p, const std::string&) { job->control.report("checking", p, 100); });
            job->stats = engine.lastRunStats();
        }
        job->control.report("publishing");
        job->status = "succeeded";
    } catch (const NativeJobCancelled& e) { job->status = "cancelled"; job->error = e.what(); }
    catch (const std::exception& e) { job->status = "failed"; job->error = e.what(); }
    catch (...) { job->status = "failed"; job->error = "后台作业发生未知异常"; }
}

static void NativeJobComplete(napi_env env, napi_status status, void* payload) {
    std::unique_ptr<NativeAsyncJobData> job(static_cast<NativeAsyncJobData*>(payload));
    job->state->markWorkerStopped();
    napi_value out = nullptr;
    try {
        if (status != napi_ok) { job->status = job->state->cancellation.load() ? "cancelled" : "failed"; job->error = "后台任务调度已停止"; }
        if (job->status == "succeeded") job->state->check();
        napi_create_object(env, &out);
        napi_value result = nullptr;
        if (job->status == "succeeded") {
            if (job->drc) result = CreateJobViolations(env, job->violations, job->stats);
            else result = CreateFullParseResult(env, job->parsed);
        }
        {
            std::lock_guard<std::mutex> publication(job->state->mutex);
            if (job->status == "succeeded") {
                job->state->check();
                if (!job->drc && !job->quickScan && job->publishToActive) {
                    std::lock_guard<std::mutex> layoutLock(g_layoutMutex);
                    g_layout = std::move(job->stagedLayout); g_lastParseResult = std::move(job->parsed); g_hasLastParseResult = true;
                }
            }
            job->state->progress.status = job->status; job->state->progress.stage = job->status; job->state->progress.message = job->error;
        }
        if (result && job->status == "succeeded") SetProp(env, out, job->drc ? "violations" : "result", result);
        if (!job->quickScan) SetProp(env, out, "budget", CreateImportEstimate(env, job->estimate));
        SetProp(env, out, "inputVersion", CreateDouble(env, job->inputVersion));
        SetProp(env, out, "documentId", CreateString(env, job->documentId));
        SetProp(env, out, "ownerCellId", CreateInt(env, job->config.ownerCellFilter));
        SetProp(env, out, "hierarchyDepthApplied", CreateInt(env, job->stats.effectiveDepth));
    } catch (const NativeJobCancelled& e) { job->status = "cancelled"; job->error = e.what(); job->state->finish(job->status, job->error); out = nullptr; }
    catch (const std::exception& e) { job->status = "failed"; job->error = e.what(); job->state->finish(job->status, job->error); out = nullptr; }
    catch (...) { job->status = "failed"; job->error = "结果发布失败"; job->state->finish(job->status, job->error); out = nullptr; }
    if (!out) napi_create_object(env, &out);
    SetProp(env, out, "jobId", CreateString(env, job->state->progress.jobId));
    SetProp(env, out, "scope", CreateString(env, job->state->progress.scope));
    SetProp(env, out, "status", CreateString(env, job->status));
    SetProp(env, out, "message", CreateString(env, job->error));
    SetProp(env, out, "terminal", CreateBool(env, job->status != "running"));
    SetProp(env, out, "workerStopped", CreateBool(env, job->state->workerStopped.load(std::memory_order_acquire)));
    napi_resolve_deferred(env, job->deferred, out);
    napi_delete_async_work(env, job->work);
}

static napi_value QueueNativeJob(napi_env env, std::unique_ptr<NativeAsyncJobData> job) {
    napi_value completion = nullptr, resource = CreateString(env, job->drc ? "hongtuDrcJob" : "hongtuParseJob");
    if (napi_create_promise(env, &job->deferred, &completion) != napi_ok) { job->state->markWorkerStopped(); job->state->finish("failed", "创建 Promise 失败"); throw std::runtime_error("创建作业 Promise 失败"); }
    const auto created = napi_create_async_work(env, nullptr, resource, NativeJobExecute, NativeJobComplete, job.get(), &job->work);
    if (created != napi_ok || napi_queue_async_work(env, job->work) != napi_ok) {
        job->state->markWorkerStopped();
        job->state->finish("failed", "作业调度失败");
        if (job->work) napi_delete_async_work(env, job->work);
        throw std::runtime_error("后台作业调度失败");
    }
    napi_value handle; napi_create_object(env, &handle);
    SetProp(env, handle, "jobId", CreateString(env, job->state->progress.jobId));
    SetProp(env, handle, "scope", CreateString(env, job->state->progress.scope));
    SetProp(env, handle, "completion", completion);
    job.release(); return handle;
}

static napi_value NapiStartParseJob(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2] = {}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) throw std::invalid_argument("startParseJob 需要文件路径及 scope 配置");
    auto job = std::make_unique<NativeAsyncJobData>();
    job->path = ReadStringArg(env, args[0]); job->quickScan = GetJobBool(env, args[1], "quickScan", false);
    job->isOasis = GetJobBool(env, args[1], "isOasis", false);
    job->publishToActive = GetJobBool(env, args[1], "publishToActive", true);
    auto ext = job->path.substr(job->path.find_last_of('.') + 1); std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext == "oas" || ext == "oasis") job->isOasis = true;
    if (ext != "oas" && ext != "oasis" && ext != "gds" && ext != "gdsii" && ext != "cif" && ext != "dxf")
        throw std::invalid_argument("可取消导入支持 GDSII/OASIS/CIF/DXF");
    if (ext == "cif" || ext == "dxf") {
        job->format = ext;
        if (job->quickScan) throw std::invalid_argument("CIF/DXF 后台导入暂不支持 quickScan；请完整读取并校验预算");
        if (job->isOasis) throw std::invalid_argument("CIF/DXF 文件不能使用 OASIS 解析配置");
    }
    job->state = g_nativeJobs.create(reinterpret_cast<uintptr_t>(env), GetObjString(env, args[1], "scope", ""), "parse");
    job->control = job->state->control(); return QueueNativeJob(env, std::move(job));
}

static napi_value NapiStartDrcJob(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3] = {}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) throw std::invalid_argument("startDrcJob 需要文档快照、规则和 scope 配置");
    auto job = std::make_unique<NativeAsyncJobData>(); job->drc = true;
    job->parsed = ReadLayoutDocumentSnapshot(env, args[0]); job->rules = ReadJobRules(env, args[1]);
    job->documentId = GetObjString(env, args[2], "documentId", ""); job->inputVersion = GetObjDouble(env, args[2], "inputVersion", -1);
    if (job->documentId.empty() || !std::isfinite(job->inputVersion) || job->inputVersion < 0 || std::floor(job->inputVersion) != job->inputVersion)
        throw std::invalid_argument("DRC 输入文档及版本无效");
    job->config.ownerCellFilter = GetObjInt(env, args[2], "ownerCellId", -1);
    if (job->config.ownerCellFilter < -1 || job->config.ownerCellFilter >= static_cast<int>(job->parsed.cells.size()))
        throw std::invalid_argument("DRC Cell 范围不存在");
    job->config.hierarchyDepth = std::max(0, std::min(16, GetObjInt(env, args[2], "hierarchyDepth", 0)));
    job->config.mergeSameLayer = GetJobBool(env, args[2], "mergeSameLayer", false);
    napi_value box = nullptr; bool has = false; napi_has_named_property(env, args[2], "scopeBox", &has);
    if (has) {
        napi_get_named_property(env, args[2], "scopeBox", &box);
        napi_valuetype boxType = napi_undefined; napi_typeof(env, box, &boxType);
        if (boxType != napi_object && boxType != napi_undefined) throw std::invalid_argument("DRC 范围必须为坐标对象");
        if (boxType == napi_object) {
        job->config.scopeBox = BBox(GetObjDouble(env, box, "minX", NAN), GetObjDouble(env, box, "minY", NAN), GetObjDouble(env, box, "maxX", NAN), GetObjDouble(env, box, "maxY", NAN));
        const auto& b = job->config.scopeBox;
        if (!b.valid() || !std::isfinite(b.minX) || !std::isfinite(b.minY) || !std::isfinite(b.maxX) || !std::isfinite(b.maxY)) throw std::invalid_argument("DRC 范围无效");
        job->config.hasScopeBox = true;
        }
    }
    job->state = g_nativeJobs.create(reinterpret_cast<uintptr_t>(env), GetObjString(env, args[2], "scope", ""), "drc");
    job->control = job->state->control(); return QueueNativeJob(env, std::move(job));
}

static napi_value NapiGetJobProgress(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2] = {}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) throw std::invalid_argument("getJobProgress 需要 jobId 与 scope");
    auto state = g_nativeJobs.find(reinterpret_cast<uintptr_t>(env), ReadStringArg(env, args[0]), ReadStringArg(env, args[1]));
    if (!state) { napi_value value; napi_get_undefined(env, &value); return value; }
    return CreateNativeJobProgress(env, state->snapshot());
}
static napi_value NapiCancelJob(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2] = {}; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) return CreateBool(env, false);
    auto state = g_nativeJobs.find(reinterpret_cast<uintptr_t>(env), ReadStringArg(env, args[0]), ReadStringArg(env, args[1]));
    return CreateBool(env, state && state->requestCancel());
}

static napi_value CreateJobViolations(napi_env env, const std::vector<DrcViolation>& violations, const DrcRunStats& st) {
    napi_value result;
    const std::string mode = st.mergedRegions
        ? (st.mergeSkipped ? "merged-region+mixed" : "merged-region")
        : std::string("per-shape");

    napi_create_array_with_length(env, violations.size(), &result);
    for (size_t i = 0; i < violations.size(); i++) {
        const auto& v = violations[i];
        napi_value obj;
        napi_create_object(env, &obj);
        SetProp(env, obj, "id", CreateInt64(env, v.id));
        SetProp(env, obj, "ruleName", CreateString(env, v.ruleName));
        SetProp(env, obj, "ruleId", CreateString(env, v.ruleId));
        SetProp(env, obj, "message", CreateString(env, v.message));
        SetProp(env, obj, "measureMode", CreateString(env, mode));
        SetProp(env, obj, "mergedRegion",
                CreateBool(env, v.message.find("merged region") != std::string::npos));
        SetProp(env, obj, "mergeSkipped", CreateBool(env, st.mergeSkipped));
        SetProp(env, obj, "mergedRegionCount", CreateInt(env, st.mergedRegionCount));
        SetProp(env, obj, "x", CreateDouble(env, v.x));
        SetProp(env, obj, "y", CreateDouble(env, v.y));
        SetProp(env, obj, "value", CreateDouble(env, v.value));
        SetProp(env, obj, "limit", CreateDouble(env, v.limit));
        SetProp(env, obj, "layer", CreateInt(env, v.layer));
        SetProp(env, obj, "datatype", CreateInt(env, v.datatype));
        SetProp(env, obj, "shapeId1", CreateInt64(env, v.shapeId1));
        SetProp(env, obj, "shapeId2", CreateInt64(env, v.shapeId2));
        SetProp(env, obj, "fromInstance", CreateBool(env, v.fromInstance));
        SetProp(env, obj, "sourceCellId", CreateInt(env, v.sourceCellId));
        SetProp(env, obj, "bboxMinX", CreateDouble(env, v.bbox.minX));
        SetProp(env, obj, "bboxMinY", CreateDouble(env, v.bbox.minY));
        SetProp(env, obj, "bboxMaxX", CreateDouble(env, v.bbox.maxX));
        SetProp(env, obj, "bboxMaxY", CreateDouble(env, v.bbox.maxY));
        napi_set_element(env, result, i, obj);
    }
    return result;
}
