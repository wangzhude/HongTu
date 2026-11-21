// Context-dependent implementation fragment, included after the document/parse
// helpers in napi_init_v2.cpp. This is deliberately not a standalone header.
#include "layout_compare.h"
#include <cctype>

static napi_value MakeSyncResult(napi_env env, bool success, const std::string& error) {
    napi_value result; napi_create_object(env,&result);
    SetProp(env,result,"success",CreateBool(env,success));
    SetProp(env,result,"errorMessage",CreateString(env,error));
    return result;
}
static napi_value NapiSyncDocument(napi_env env,napi_callback_info info) {
    size_t argc=1; napi_value args[1]; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc<1) return MakeSyncResult(env,false,"syncDocument expects document");
    try {
        auto parsed=ReadLayoutDocumentSnapshot(env,args[0]);
        auto next=BuildSceneLayoutFromParseResult(parsed);
        auto result=MakeSyncResult(env,true,"");
        napi_value diagnostics;napi_create_array_with_length(env,parsed.portCapabilityDiagnostics.size(),&diagnostics);
        for(size_t i=0;i<parsed.portCapabilityDiagnostics.size();++i){ParseResultHandleScope handles(env);napi_set_element(env,diagnostics,i,CreateString(env,parsed.portCapabilityDiagnostics[i]));}
        SetProp(env,result,"portCapabilityDiagnostics",diagnostics);
        bool pending=false; napi_is_exception_pending(env,&pending);
        if(pending) return nullptr;
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        g_lastParseResult=std::move(parsed); g_layout=std::move(next); g_hasLastParseResult=true;
        return result;
    } catch(const std::exception& e) { return MakeSyncResult(env,false,e.what()); }
}
static napi_value MakeLayoutCompareResult(napi_env env,const LayoutCompareResult& r) {
    napi_value result; napi_create_object(env,&result);
    SetProp(env,result,"success",CreateBool(env,r.success));
    SetProp(env,result,"complete",CreateBool(env,r.complete));
    SetProp(env,result,"geometryEqual",CreateBool(env,r.geometryEqual));
    SetProp(env,result,"structureEqual",CreateBool(env,r.structureEqual));
    SetProp(env,result,"errorMessage",CreateString(env,r.errorMessage));
    SetProp(env,result,"cellA",CreateString(env,r.cellA)); SetProp(env,result,"cellB",CreateString(env,r.cellB));
    SetProp(env,result,"gridNm",CreateDouble(env,r.gridNm));
    SetProp(env,result,"elapsedMs",CreateDouble(env,r.elapsedMs));
    SetProp(env,result,"comparedLayers",CreateInt64(env,r.comparedLayers));
    napi_value layers; napi_create_array_with_length(env,r.layers.size(),&layers);
    for(size_t i=0;i<r.layers.size();++i) {
        ParseResultHandleScope handles(env);
        const auto& l=r.layers[i]; napi_value obj; napi_create_object(env,&obj);
        SetProp(env,obj,"layerNumber",CreateInt(env,l.layerNumber)); SetProp(env,obj,"datatype",CreateInt(env,l.datatype));
        SetProp(env,obj,"areaOnlyA",CreateDouble(env,l.areaOnlyA)); SetProp(env,obj,"areaOnlyB",CreateDouble(env,l.areaOnlyB));
        SetProp(env,obj,"xorArea",CreateDouble(env,l.xorArea));
        SetProp(env,obj,"minX",CreateDouble(env,l.bounds.minX)); SetProp(env,obj,"minY",CreateDouble(env,l.bounds.minY));
        SetProp(env,obj,"maxX",CreateDouble(env,l.bounds.maxX)); SetProp(env,obj,"maxY",CreateDouble(env,l.bounds.maxY));
        SetProp(env,obj,"contourCount",CreateInt64(env,l.contourCount));
        SetProp(env,obj,"previewTruncated",CreateBool(env,l.previewTruncated));
        napi_value contours; napi_create_array_with_length(env,l.contours.size(),&contours);
        for(size_t j=0;j<l.contours.size();++j) {
            ParseResultHandleScope ringHandles(env);
            napi_value points; napi_create_array_with_length(env,l.contours[j].size(),&points);
            for(size_t k=0;k<l.contours[j].size();++k) {
                ParseResultHandleScope pointHandles(env);
                napi_value p; napi_create_object(env,&p);
                SetProp(env,p,"x",CreateDouble(env,l.contours[j][k].x)); SetProp(env,p,"y",CreateDouble(env,l.contours[j][k].y));
                napi_set_element(env,points,k,p);
            }
            napi_set_element(env,contours,j,points);
        }
        SetProp(env,obj,"contours",contours); napi_set_element(env,layers,i,obj);
    }
    SetProp(env,result,"layers",layers);
    napi_value diffs; napi_create_array_with_length(env,r.structureDifferences.size(),&diffs);
    for(size_t i=0;i<r.structureDifferences.size();++i) {
        ParseResultHandleScope handles(env);
        const auto& d=r.structureDifferences[i]; napi_value obj; napi_create_object(env,&obj);
        SetProp(env,obj,"cellName",CreateString(env,d.cellName)); SetProp(env,obj,"category",CreateString(env,d.category));
        SetProp(env,obj,"onlyInA",CreateInt64(env,d.onlyInA)); SetProp(env,obj,"onlyInB",CreateInt64(env,d.onlyInB));
        napi_set_element(env,diffs,i,obj);
    }
    SetProp(env,result,"structureDifferences",diffs); return result;
}
struct CompareAsyncData {
    napi_async_work work=nullptr; napi_deferred deferred=nullptr;
    GdsiiParseResult source; std::string path; LayoutCompareOptions options; LayoutCompareResult result;
    std::shared_ptr<NativeJobState> state;
    NativeJobControl control;
    std::string status="running", error;
    bool returnJob=false;
};
static void ExecuteLayoutCompare(napi_env,void* data) {
    auto& request=*static_cast<CompareAsyncData*>(data);
    NativeJobExecutionGuard execution(request.state);
    const auto start=std::chrono::steady_clock::now();
    try {
        request.control.report("reading_B");
        std::string path=request.path; std::transform(path.begin(),path.end(),path.begin(),[](unsigned char c){return char(std::tolower(c));});
        const auto suffix=[&](const char* ext){const std::string s(ext);return path.size()>=s.size()&&path.compare(path.size()-s.size(),s.size(),s)==0;};
        GdsiiParseResult other;
        if(suffix(".oas")||suffix(".oasis")) other=OasisReader().parse(request.path,&request.control);
        else if(suffix(".cif")) other=CifReader().parse(request.path,&request.control);
        else if(suffix(".dxf")) other=DxfReader().parse(request.path,&request.control);
        else other=GdsiiReader().parse(request.path,&request.control);
        if(!other.success) throw std::runtime_error(other.errorMessage);
        // Both scenes are independent. No parse/commit/global snapshot call is permitted here.
        request.control.report("indexing_A",0,request.source.shapes.size());
        auto a=BuildSceneLayoutFromParseResult(request.source,&request.control);
        request.control.report("indexing_B",0,other.shapes.size());
        auto b=BuildSceneLayoutFromParseResult(other,&request.control);
        request.result=CompareLayouts(request.source,*a,other,*b,request.options,&request.control);
        request.control.check();
        if(!request.result.success||!request.result.complete) throw std::runtime_error(request.result.errorMessage);
        request.control.report("publishing");
        request.status="succeeded";
    } catch(const NativeJobCancelled& e) { request.status="cancelled"; request.error=e.what(); request.result={}; request.result.errorMessage=request.error; }
    catch(const std::exception& e) { request.status="failed"; request.error=e.what(); request.result={}; request.result.errorMessage=request.error; }
    catch(...) { request.status="failed"; request.error="Comparison worker failed"; request.result={}; request.result.errorMessage=request.error; }
    request.result.elapsedMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
}
static void CompleteLayoutCompare(napi_env env,napi_status status,void* data) {
    std::unique_ptr<CompareAsyncData> request(static_cast<CompareAsyncData*>(data));
    request->state->markWorkerStopped();
    try {
        if(status!=napi_ok) { request->status=request->state->cancellation.load()?"cancelled":"failed"; request->error="Comparison scheduling stopped"; }
        try { if(request->status=="succeeded") request->state->check(); }
        catch(const NativeJobCancelled& e) { request->status="cancelled"; request->error=e.what(); }
        if(request->status!="succeeded") { request->result={}; request->result.errorMessage=request->error; }
        napi_value result=MakeLayoutCompareResult(env,request->result);
        napi_value out=result;
        if(request->returnJob) {
            napi_create_object(env,&out);
            if(request->status=="succeeded") SetProp(env,out,"result",result);
            SetProp(env,out,"jobId",CreateString(env,request->state->progress.jobId));
            SetProp(env,out,"scope",CreateString(env,request->state->progress.scope));
            SetProp(env,out,"terminal",CreateBool(env,true));
            SetProp(env,out,"workerStopped",CreateBool(env,true));
        }
        {
            std::lock_guard<std::mutex> publication(request->state->mutex);
            // Both cancellation and publication use this mutex. NAPI result
            // allocation above cannot authorize a result after cancellation.
            if(request->status=="succeeded" && request->state->cancellation.load()) {
                request->status="cancelled"; request->error="作业已取消，未发布结果";
            }
            request->state->progress.status=request->status;
            request->state->progress.stage=request->status;
            request->state->progress.message=request->error;
        }
        if(request->status=="cancelled") {
            request->result={}; request->result.errorMessage=request->error;
            if(request->returnJob) {
                // Discard an already allocated success envelope entirely.
                napi_create_object(env,&out);
                SetProp(env,out,"jobId",CreateString(env,request->state->progress.jobId));
                SetProp(env,out,"scope",CreateString(env,request->state->progress.scope));
                SetProp(env,out,"terminal",CreateBool(env,true));
                SetProp(env,out,"workerStopped",CreateBool(env,true));
            } else out=MakeLayoutCompareResult(env,request->result);
        }
        if(request->returnJob) {
            SetProp(env,out,"status",CreateString(env,request->status));
            SetProp(env,out,"message",CreateString(env,request->error));
        }
        bool pending=false; napi_is_exception_pending(env,&pending);
        if(pending || napi_resolve_deferred(env,request->deferred,out)!=napi_ok) throw std::runtime_error("Comparison promise publication failed");
    } catch(...) {
        // No C++ exception may cross an async callback, including allocation
        // failure while producing the small cancellation/error envelope.
        try { request->state->finish("failed","publish error"); } catch(...) {}
        napi_value error=nullptr; napi_get_and_clear_last_exception(env,&error);
        if(!error) napi_create_string_utf8(env,"Comparison result could not be allocated",NAPI_AUTO_LENGTH,&error);
        napi_reject_deferred(env,request->deferred,error);
    }
    napi_delete_async_work(env,request->work);
}
static napi_value StartLayoutCompare(napi_env env,napi_callback_info info,bool returnJob) {
    size_t argc=3; napi_value args[3]={}; napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    auto request=std::make_unique<CompareAsyncData>();
    request->returnJob=returnJob;
    napi_value promise=nullptr,handle=nullptr;
    try {
        if(argc<(returnJob?3u:2u)) throw std::invalid_argument("compareLayout expects current document, comparison file and job scope options");
        request->source=ReadLayoutDocumentSnapshot(env,args[0]); request->path=ReadStringArg(env,args[1]);
        if(argc>=3) {
            request->options.cellA=GetObjString(env,args[2],"cellA",""); request->options.cellB=GetObjString(env,args[2],"cellB","");
            request->options.offsetX=GetObjDouble(env,args[2],"offsetX",0); request->options.offsetY=GetObjDouble(env,args[2],"offsetY",0);
            request->options.gridNm=GetObjDouble(env,args[2],"gridNm",0);
        }
        request->state=g_nativeJobs.create(reinterpret_cast<uintptr_t>(env),returnJob?GetObjString(env,args[2],"scope",""):"legacy-comparison","compare");
        request->control=request->state->control();
        if(napi_create_promise(env,&request->deferred,&promise)!=napi_ok) throw std::runtime_error("Could not create comparison Promise");
        handle=promise;
        if(returnJob) {
            if(napi_create_object(env,&handle)!=napi_ok) throw std::runtime_error("Could not create comparison job handle");
            SetProp(env,handle,"jobId",CreateString(env,request->state->progress.jobId));
            SetProp(env,handle,"scope",CreateString(env,request->state->progress.scope));
            SetProp(env,handle,"completion",promise);
        }
        bool pending=false;
        if(napi_is_exception_pending(env,&pending)!=napi_ok || pending)
            throw std::runtime_error("Could not allocate comparison job handle");
        const auto name=CreateString(env,"HongTuLayoutCompare");
        if(napi_create_async_work(env,nullptr,name,ExecuteLayoutCompare,CompleteLayoutCompare,request.get(),&request->work)!=napi_ok)
            throw std::runtime_error("Could not create comparison worker");
        if(napi_queue_async_work(env,request->work)!=napi_ok) {
            napi_delete_async_work(env,request->work); request->work=nullptr;
            throw std::runtime_error("Could not queue comparison worker");
        }
        request.release();
        return handle;
    } catch(const std::exception& e) {
        if(request->state) { request->state->markWorkerStopped(); request->state->finish("failed",e.what()); }
        if(returnJob && !promise) throw;
        if(!promise && napi_create_promise(env,&request->deferred,&promise)!=napi_ok) throw;
        if(returnJob) {
            // Scheduling failed after a handle was allocated, so settle that
            // exact completion with the true terminal/no-worker state.
            napi_value out; napi_create_object(env,&out);
            SetProp(env,out,"jobId",CreateString(env,request->state->progress.jobId));
            SetProp(env,out,"scope",CreateString(env,request->state->progress.scope));
            SetProp(env,out,"status",CreateString(env,"failed")); SetProp(env,out,"message",CreateString(env,e.what()));
            SetProp(env,out,"terminal",CreateBool(env,true)); SetProp(env,out,"workerStopped",CreateBool(env,true));
            bool pending=false; napi_is_exception_pending(env,&pending);
            if(pending || !handle || handle==promise) {
                napi_value error=nullptr; napi_get_and_clear_last_exception(env,&error);
                if(!error) napi_create_string_utf8(env,e.what(),NAPI_AUTO_LENGTH,&error);
                napi_reject_deferred(env,request->deferred,error);
                throw;
            }
            if(napi_resolve_deferred(env,request->deferred,out)!=napi_ok) throw;
            return handle;
        }
        request->result.errorMessage=e.what();
        napi_resolve_deferred(env,request->deferred,MakeLayoutCompareResult(env,request->result));
    }
    return promise;
}
static napi_value NapiCompareLayout(napi_env env,napi_callback_info info) { return StartLayoutCompare(env,info,false); }
static napi_value NapiStartCompareJob(napi_env env,napi_callback_info info) { return StartLayoutCompare(env,info,true); }
