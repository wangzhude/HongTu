/**
 * HongTu EDA - NAPI Module (v2)
 * Exposes the engine to ArkTS:
 * - File parsing (GDSII/OASIS) with async worker threads
 * - Scene graph / hierarchy expand (KLayout depth)
 * - Spatial queries (point, range, nearest)
 * - GDSII structured write (writeGdsii / writeGdsiiDocument)
 * - GL rendering control via XComponentPlugin
 *
 * experimental（不可签核）:
 * - DRC/LVS 是预检查；booleanOp / offsetPolygon 已接入官方 Clipper2
 * - OASIS 完整几何兼容
 *
 * 注意：编辑后 g_layout 仅在 writeGdsiiDocument 成功后刷新；
 * dirty 状态下 UI 必须 preferNativeExpand=false，走 ArkTS 展开。
 */
#include <napi/native_api.h>
#include <hilog/log.h>
#include <string>
#include <vector>
#include <memory>
#include <mutex>
#include <thread>
#include <chrono>
#include <algorithm>
#include <unordered_map>
#include <functional>
#include <cmath>
#include <stdexcept>

#include "scene_graph.h"
#include "hierarchy_render_batches.h"
#include "readonly_scene_cache.h"
#include "spatial_index.h"
#include "geometry_engine.h"
#include "triangulator.h"
#include "clipper_engine.h"
#include "edit_region.h"
#include "grid_edit_region.h"
#include "path_edit_region.h"
#include "gdsii_reader.h"
#include "layout_import_budget.h"
#include "property_wire.h"
#include "layout_context.h"
#include "layout_port_codec.h"
#include "gdsii_writer.h"
#include "oasis_reader.h"
#include "oasis_writer.h"
#include "drc_engine.h"
#include "lvs_engine.h"
#include "image_export.h"
#include "format_readers.h"
#include "pcell_framework.h"
#include "embedded_python_runtime.h"

// Forward declare XComponent plugin
#include "xcomponent_plugin.h"

// hilog/log.h 会以 #define 提供 LOG_TAG/LOG_DOMAIN 空实现，直接重定义会触发
// -Wmacro-redefined；先 #undef 再定义，保证日志标签唯一且构建零告警。
#ifdef LOG_TAG
#undef LOG_TAG
#endif
#ifdef LOG_DOMAIN
#undef LOG_DOMAIN
#endif
#define LOG_TAG "HongTuNative"
#define LOG_DOMAIN 0x0001

using namespace hongtu;
using namespace hongtu::property_wire;

// ==================== Global State ====================

static std::unique_ptr<Layout> g_layout;
static std::mutex g_layoutMutex;
static std::string g_lastError;
/** 最近一次成功完整解析的结果，供 writeGdsii 无编辑往返 */
static GdsiiParseResult g_lastParseResult;
static bool g_hasLastParseResult = false;

// ==================== Helper Functions ====================

static std::string ReadStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    napi_get_value_string_utf8(env, value, nullptr, 0, &len);
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, value, &result[0], len + 1, &len);
    return result;
}

static int32_t ReadIntArg(napi_env env, napi_value value) {
    int32_t result = 0;
    napi_get_value_int32(env, value, &result);
    return result;
}

/**
 * int64 入参读取（与 CreateInt64 对称）。
 * 当前无调用点（跨边界的 id 均为 int32 范围内的顺序自增值），
 * 保留为 int64 入参的统一入口，标注 maybe_unused 以免 -Wunused-function。
 */
[[maybe_unused]] static int64_t ReadInt64Arg(napi_env env, napi_value value) {
    int64_t result = 0;
    napi_get_value_int64(env, value, &result);
    return result;
}

static double ReadDoubleArg(napi_env env, napi_value value) {
    double result = 0;
    napi_get_value_double(env, value, &result);
    return result;
}

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.size(), &result);
    return result;
}

static napi_value CreateInt(napi_env env, int32_t val) {
    napi_value result;
    napi_create_int32(env, val, &result);
    return result;
}

static napi_value CreateInt64(napi_env env, int64_t val) {
    napi_value result;
    napi_create_int64(env, val, &result);
    return result;
}

static napi_value CreateDouble(napi_env env, double val) {
    napi_value result;
    napi_create_double(env, val, &result);
    return result;
}

static napi_value CreateBool(napi_env env, bool val) {
    napi_value result;
    napi_get_boolean(env, val, &result);
    return result;
}

static void SetProp(napi_env env, napi_value obj, const char* name, napi_value value) {
    napi_set_named_property(env, obj, name, value);
}

static napi_value CreateQuantization(napi_env env, const QuantizationReport& report) {
    napi_value obj; napi_create_object(env, &obj);
    SetProp(env, obj, "dbuNm", CreateDouble(env, report.dbuNm));
    SetProp(env, obj, "examinedValueCount", CreateInt64(env, report.examinedValueCount));
    SetProp(env, obj, "quantizedValueCount", CreateInt64(env, report.quantizedValueCount));
    SetProp(env, obj, "quantizedShapeCount", CreateInt64(env, report.quantizedShapeCount));
    SetProp(env, obj, "maximumDeviationNm", CreateDouble(env, report.maximumDeviationNm));
    return obj;
}

static napi_value CreateLayerInterval(napi_env env, const LayerNameInterval& interval) {
    napi_value obj; napi_create_object(env, &obj);
    SetProp(env, obj, "type", CreateInt(env, interval.type));
    SetProp(env, obj, "lower", CreateDouble(env, interval.lower));
    SetProp(env, obj, "upper", CreateDouble(env, interval.upper));
    return obj;
}

// ==================== LayoutProperty ⇄ JS 线上编解码 ====================
/**
 * 属性以**可选**字段跨边界流动，线上格式（ADDITIVE，旧调用方/旧文档零影响）：
 *   图元：shapeObj.properties   = PropRecord[]（空则整个字段省略，不写空数组）
 *   结构：cellObj.properties   = PropRecord[]
 *   库级：result.libProperties = PropRecord[]
 *   PropRecord = { attr:number, dtype:number, name:string, value:string }
 *
 * value 载体按「是否可安全承载于 JS 字符串」选择，且**由 dtype 决定回读方式**，故无歧义：
 *   dtype 6 / 可打印且无 NUL 的字节 → 原文
 *   dtype 0（无数据属性）   → 恒空串
 *   dtype 2..5 的值字节 → "#" + 大写十六进制（含尾零，回读逐字节复原）
 *   dtype 7（规范外保留码，仅作载体标记）→ ASCII 槽位里装着控制字节/NUL，回读还原为 dtype 6 + 十六进制解码
 *
 * 越界/畸形条目一律**忽略**（不抛异常、不错位），并按归属者钳制条数与总字节，
 * 与 gdsii_reader 的 kMaxPropsPerOwner / kMaxPropBytes 口径一致。
 */
static const size_t kMaxPropsPerOwnerWire = 64;        // 每图元/每结构/库级条数上限
static const size_t kMaxPropTotalBytesWire = 32u << 20; // 一次调用跨边界的属性总字节预算

/** 属性数组 → JS 数组；空则返回 nullptr（调用方省略该字段，保证旧输出对象字节级不变）。 */
static napi_value CreatePropertyArray(napi_env env, const std::vector<LayoutProperty>& props) {
    if (props.empty()) {
        return nullptr;
    }
    if (props.size() > kMaxPropsPerOwnerWire) throw std::invalid_argument("Property owner budget exceeded");
    const size_t count = props.size();
    napi_value arr;
    if (napi_create_array_with_length(env, count, &arr) != napi_ok) {
        return nullptr;
    }
    for (size_t i = 0; i < count; i++) {
        napi_value o;
        if (napi_create_object(env, &o) != napi_ok) {
            break;
        }
        int32_t dtype = 6;
        std::string value;
        EncodePropertyWire(props[i], dtype, value);
        SetProp(env, o, "attr", CreateInt(env, props[i].attr));
        SetProp(env, o, "dtype", CreateInt(env, dtype));
        SetProp(env, o, "name", CreateString(env, props[i].name));
        SetProp(env, o, "value", CreateString(env, value));
        napi_set_element(env, arr, static_cast<uint32_t>(i), o);
    }
    return arr;
}

static void SetPropertyField(napi_env env, napi_value obj, const char* field,
                             const std::vector<LayoutProperty>& props) {
    napi_value arr = CreatePropertyArray(env, props);
    if (arr != nullptr) {
        SetProp(env, obj, field, arr);
    }
}

/** LayoutProperty → SceneProperty（场景镜像；无 dtype 字段，故 ASCII 剥填充、二进制原样保留）。 */
static void AppendSceneProperties(std::vector<SceneProperty>& dst,
                                  const std::vector<LayoutProperty>& src) {
    if (src.empty()) {
        return;
    }
    if (src.size() > kMaxPropsPerOwnerWire) throw std::invalid_argument("Property owner budget exceeded");
    const size_t n = src.size();
    dst.reserve(dst.size() + n);
    for (size_t i = 0; i < n; i++) {
        SceneProperty sp;
        sp.attr = src[i].attr;
        sp.name = src[i].name;
        sp.value = src[i].value;
        sp.dtype = src[i].dtype;
        dst.push_back(std::move(sp));
    }
}

// Release temporary NAPI handles per stored definition. The result array keeps
// its objects alive, but intermediate handles need not root every allocation
// until a whole 100k-definition file has been converted.
class ParseResultHandleScope {
public:
    explicit ParseResultHandleScope(napi_env env) : env_(env) {
        if (napi_open_handle_scope(env_, &scope_) != napi_ok)
            throw std::runtime_error("Cannot open parse result handle scope");
    }
    ~ParseResultHandleScope() { napi_close_handle_scope(env_, scope_); }
    ParseResultHandleScope(const ParseResultHandleScope&) = delete;
    ParseResultHandleScope& operator=(const ParseResultHandleScope&) = delete;
private:
    napi_env env_;
    napi_handle_scope scope_ = nullptr;
};

static napi_value CreateContextArray(napi_env env, const std::vector<std::string>& records) {
    napi_value arr; napi_create_array_with_length(env, records.size(), &arr);
    for(size_t i=0;i<records.size();++i){
        ParseResultHandleScope handles(env); napi_value record; napi_create_object(env,&record);
        const bool utf8=layout_context::ValidUtf8(records[i]);
        SetProp(env,record,"encoding",CreateString(env,utf8?"utf8":"hex"));
        SetProp(env,record,"value",CreateString(env,utf8?records[i]:property_wire::ToHexWire(records[i]).substr(1)));
        napi_set_element(env,arr,static_cast<uint32_t>(i),record);
    }return arr;
}

static napi_value CreateNativePort(napi_env env,const LayoutPort& p){
    napi_value v,c;napi_create_object(env,&v);napi_create_object(env,&c);
    SetProp(env,v,"id",CreateString(env,p.id));SetProp(env,v,"ownerCellId",CreateInt(env,p.ownerCellId));SetProp(env,v,"ownerCellKey",CreateString(env,p.ownerCellKey));SetProp(env,v,"name",CreateString(env,p.name));
    SetProp(env,c,"x",CreateDouble(env,p.xNm));SetProp(env,c,"y",CreateDouble(env,p.yNm));SetProp(env,v,"centerNm",c);
    SetProp(env,v,"orientationDeg",CreateDouble(env,p.orientationDeg));SetProp(env,v,"widthNm",CreateDouble(env,p.widthNm));SetProp(env,v,"layerNumber",CreateInt(env,p.layerNumber));SetProp(env,v,"datatype",CreateInt(env,p.datatype));SetProp(env,v,"portType",CreateString(env,p.portType));SetProp(env,v,"frameMirror",CreateBool(env,p.frameMirror));SetProp(env,v,"frameMagnification",CreateDouble(env,p.frameMagnification));SetProp(env,v,"infoJson",CreateString(env,p.infoJson));
    if(!p.crossSectionKey.empty()){SetProp(env,v,"crossSectionKey",CreateString(env,p.crossSectionKey));SetProp(env,v,"crossSectionVersion",CreateInt(env,p.crossSectionVersion));}if(!p.provenance.empty())SetProp(env,v,"provenance",CreateString(env,p.provenance));return v;
}
static void SetContextFields(napi_env env,napi_value obj,const GdsiiParseResult& result){
    SetProp(env,obj,"layoutContextRecords",CreateContextArray(env,result.layoutContextRecords));
    napi_value groups;napi_create_array_with_length(env,result.cells.size(),&groups);
    for(size_t i=0;i<result.cells.size();++i){ParseResultHandleScope handles(env);napi_set_element(env,groups,static_cast<uint32_t>(i),CreateContextArray(env,layout_context::CellRecords(result,i)));}
    SetProp(env,obj,"cellContextRecords",groups);
    const size_t keyCount=result.cellKeys.empty()?result.cells.size():result.cellKeys.size();
    napi_value keys,ports,sections,diagnostics;napi_create_array_with_length(env,keyCount,&keys);napi_create_array_with_length(env,result.ports.size(),&ports);napi_create_array_with_length(env,result.crossSections.size(),&sections);napi_create_array_with_length(env,result.portCapabilityDiagnostics.size(),&diagnostics);
    for(size_t i=0;i<keyCount;++i){ParseResultHandleScope handles(env);napi_set_element(env,keys,i,CreateString(env,result.cellKeys.empty()?port_codec::identity("foreign-cell",result.cells[i].name):result.cellKeys[i]));}
    for(size_t i=0;i<result.ports.size();++i){ParseResultHandleScope handles(env);napi_set_element(env,ports,i,CreateNativePort(env,result.ports[i]));}
    for(size_t i=0;i<result.crossSections.size();++i){ParseResultHandleScope handles(env);const auto& xs=result.crossSections[i];napi_value v;napi_create_object(env,&v);SetProp(env,v,"key",CreateString(env,xs.key));SetProp(env,v,"version",CreateInt(env,xs.version));SetProp(env,v,"name",CreateString(env,xs.name));SetProp(env,v,"definitionJson",CreateString(env,xs.definitionJson));if(!xs.sourceFormat.empty())SetProp(env,v,"sourceFormat",CreateString(env,xs.sourceFormat));if(!xs.sourceVersion.empty())SetProp(env,v,"sourceVersion",CreateString(env,xs.sourceVersion));napi_set_element(env,sections,i,v);}
    for(size_t i=0;i<result.portCapabilityDiagnostics.size();++i){ParseResultHandleScope handles(env);napi_set_element(env,diagnostics,i,CreateString(env,result.portCapabilityDiagnostics[i]));}
    SetProp(env,obj,"cellKeys",keys);SetProp(env,obj,"ports",ports);SetProp(env,obj,"crossSections",sections);SetProp(env,obj,"portCapabilityDiagnostics",diagnostics);
}

// Build full GdsiiResult object matching Index.d.ts (sync path used by UI)
static napi_value CreateFullParseResult(napi_env env, const GdsiiParseResult& result) {
    napi_value obj;
    napi_create_object(env, &obj);
    SetProp(env, obj, "success", CreateBool(env, result.success));
    SetProp(env, obj, "errorMessage", CreateString(env, result.errorMessage));
    SetProp(env, obj, "filePath", CreateString(env, result.filePath));
    SetContextFields(env,obj,result);
    SetProp(env, obj, "fileSize", CreateInt64(env, result.fileSize));
    SetProp(env, obj, "version", CreateInt(env, result.version));
    SetProp(env, obj, "libName", CreateString(env, result.libName));
    SetProp(env, obj, "cellCount", CreateInt(env, result.cellCount));
    SetProp(env, obj, "totalElements", CreateInt(env, result.totalElements));
    SetProp(env, obj, "layerCount", CreateInt(env, result.layerCount));
    SetProp(env, obj, "userUnits", CreateDouble(env, result.userUnits));
    SetProp(env, obj, "physicalUnits", CreateDouble(env, result.physicalUnits));
    SetProp(env, obj, "unitDescription", CreateString(env, result.unitDescription));
    // 库/数据库级属性（可选字段：无属性时完全省略，旧输出对象不变）
    SetPropertyField(env, obj, "libProperties", result.libProperties);

    napi_value cells;
    napi_create_array_with_length(env, result.cells.size(), &cells);
    for (size_t i = 0; i < result.cells.size(); i++) {
        ParseResultHandleScope handles(env);
        napi_value cellObj;
        napi_create_object(env, &cellObj);
        SetProp(env, cellObj, "name", CreateString(env, result.cells[i].name));
        SetProp(env, cellObj, "elementCount", CreateInt(env, result.cells[i].elementCount));
        SetPropertyField(env, cellObj, "properties", result.cells[i].properties);
        napi_value layers;
        napi_create_array_with_length(env, result.cells[i].layers.size(), &layers);
        for (size_t j = 0; j < result.cells[i].layers.size(); j++) {
            napi_value layerObj;
            napi_create_object(env, &layerObj);
            SetProp(env, layerObj, "layerNumber", CreateInt(env, result.cells[i].layers[j].layerNumber));
            SetProp(env, layerObj, "datatype", CreateInt(env, result.cells[i].layers[j].datatype));
            SetProp(env, layerObj, "elementCount", CreateInt(env, result.cells[i].layers[j].elementCount));
            SetProp(env, layerObj, "sourceName", CreateString(env, result.cells[i].layers[j].sourceName));
            napi_set_element(env, layers, j, layerObj);
        }
        SetProp(env, cellObj, "layers", layers);
        napi_set_element(env, cells, i, cellObj);
    }
    SetProp(env, obj, "cells", cells);

    napi_value topCellIds;
    napi_create_array_with_length(env, result.topCellIds.size(), &topCellIds);
    for (size_t i = 0; i < result.topCellIds.size(); i++) {
        napi_set_element(env, topCellIds, i, CreateInt(env, result.topCellIds[i]));
    }
    SetProp(env, obj, "topCellIds", topCellIds);
    SetProp(env, obj, "primaryTopCellId", CreateInt(env, result.primaryTopCellId));

    napi_value allLayers;
    napi_create_array_with_length(env, result.allLayers.size(), &allLayers);
    for (size_t i = 0; i < result.allLayers.size(); i++) {
        napi_value layerObj;
        napi_create_object(env, &layerObj);
        SetProp(env, layerObj, "layerNumber", CreateInt(env, result.allLayers[i].layerNumber));
        SetProp(env, layerObj, "datatype", CreateInt(env, result.allLayers[i].datatype));
        SetProp(env, layerObj, "elementCount", CreateInt(env, result.allLayers[i].elementCount));
        SetProp(env, layerObj, "sourceName", CreateString(env, result.allLayers[i].sourceName));
        napi_set_element(env, allLayers, i, layerObj);
    }
    SetProp(env, obj, "allLayers", allLayers);
    napi_value layerDefinitions; napi_create_array_with_length(env, result.layerDefinitions.size(), &layerDefinitions);
    for (size_t i = 0; i < result.layerDefinitions.size(); ++i) {
        napi_value definition; napi_create_object(env, &definition);
        SetProp(env, definition, "name", CreateString(env, result.layerDefinitions[i].name));
        SetProp(env, definition, "textLayer", CreateBool(env, result.layerDefinitions[i].textLayer));
        SetProp(env, definition, "layer", CreateLayerInterval(env, result.layerDefinitions[i].layer));
        SetProp(env, definition, "datatype", CreateLayerInterval(env, result.layerDefinitions[i].datatype));
        napi_set_element(env, layerDefinitions, i, definition);
    }
    SetProp(env, obj, "layerDefinitions", layerDefinitions);

    uint64_t totalCoords = 0;
    for (const auto& s : result.shapes) {
        totalCoords += s.points.size();
    }
    bool usePackedCoords = (totalCoords > 8192ULL && result.shapes.size() <= static_cast<size_t>(INT32_MAX) &&
                            totalCoords <= static_cast<uint64_t>(INT32_MAX));
    double* packedCoordPtr = nullptr;
    int32_t* pointOffsetsPtr = nullptr;
    int32_t* pointCountsPtr = nullptr;
    napi_value sharedEmptyPoints = nullptr;
    if (usePackedCoords) {
        void* coordBufData = nullptr;
        void* offsetsBufData = nullptr;
        void* countsBufData = nullptr;
        napi_value coordAb = nullptr, offsetsAb = nullptr, countsAb = nullptr;
        napi_value coordTa = nullptr, offsetsTa = nullptr, countsTa = nullptr;
        const size_t doubleLen = static_cast<size_t>(totalCoords) * 2;
        const size_t shapeCount = result.shapes.size();
        if (napi_create_arraybuffer(env, doubleLen * sizeof(double), &coordBufData, &coordAb) == napi_ok &&
            napi_create_typedarray(env, napi_float64_array, doubleLen, coordAb, 0, &coordTa) == napi_ok &&
            napi_create_arraybuffer(env, shapeCount * sizeof(int32_t), &offsetsBufData, &offsetsAb) == napi_ok &&
            napi_create_typedarray(env, napi_int32_array, shapeCount, offsetsAb, 0, &offsetsTa) == napi_ok &&
            napi_create_arraybuffer(env, shapeCount * sizeof(int32_t), &countsBufData, &countsAb) == napi_ok &&
            napi_create_typedarray(env, napi_int32_array, shapeCount, countsAb, 0, &countsTa) == napi_ok &&
            coordBufData != nullptr && offsetsBufData != nullptr && countsBufData != nullptr) {
            packedCoordPtr = static_cast<double*>(coordBufData);
            pointOffsetsPtr = static_cast<int32_t*>(offsetsBufData);
            pointCountsPtr = static_cast<int32_t*>(countsBufData);
            SetProp(env, obj, "packedCoords", coordTa);
            SetProp(env, obj, "shapePointOffsets", offsetsTa);
            SetProp(env, obj, "shapePointCounts", countsTa);
            napi_create_array_with_length(env, 0, &sharedEmptyPoints);
        } else {
            usePackedCoords = false;
        }
    }

    int32_t runningPointOffset = 0;
    napi_value shapes;
    napi_create_array_with_length(env, result.shapes.size(), &shapes);
    for (size_t i = 0; i < result.shapes.size(); i++) {
        ParseResultHandleScope handles(env);
        const auto& s = result.shapes[i];
        napi_value shapeObj;
        napi_create_object(env, &shapeObj);
        SetProp(env, shapeObj, "id", CreateInt(env, s.id));
        SetProp(env, shapeObj, "type", CreateString(env, s.type));
        SetProp(env, shapeObj, "layerNumber", CreateInt(env, s.layerNumber));
        SetProp(env, shapeObj, "datatype", CreateInt(env, s.datatype));
        SetProp(env, shapeObj, "pathWidth", CreateDouble(env, s.pathWidth));
        SetProp(env, shapeObj, "pathType", CreateInt(env, s.pathType));
        SetProp(env, shapeObj, "pathBeginExtension", CreateDouble(env, s.pathBeginExtension));
        SetProp(env, shapeObj, "pathEndExtension", CreateDouble(env, s.pathEndExtension));
        SetProp(env, shapeObj, "pathWidthAbsolute", CreateBool(env, s.pathWidthAbsolute));
        SetProp(env, shapeObj, "arrayCols", CreateInt(env, s.arrayCols));
        SetProp(env, shapeObj, "arrayRows", CreateInt(env, s.arrayRows));
        SetProp(env, shapeObj, "arrayColStepX", CreateDouble(env, s.arrayColStepX));
        SetProp(env, shapeObj, "arrayColStepY", CreateDouble(env, s.arrayColStepY));
        SetProp(env, shapeObj, "arrayRowStepX", CreateDouble(env, s.arrayRowStepX));
        SetProp(env, shapeObj, "arrayRowStepY", CreateDouble(env, s.arrayRowStepY));
        SetProp(env, shapeObj, "text", CreateString(env, s.text));
        SetProp(env, shapeObj, "textPresentation", CreateInt(env, s.textPresentation));
        SetProp(env, shapeObj, "cellName", CreateString(env, s.cellName));
        SetProp(env, shapeObj, "ownerCellId", CreateInt(env, s.ownerCellId));
        SetProp(env, shapeObj, "cellId", CreateInt(env, s.cellId));
        SetProp(env, shapeObj, "rotation", CreateDouble(env, s.rotation));
        SetProp(env, shapeObj, "mirror", CreateInt(env, s.mirror));
        SetProp(env, shapeObj, "magnification", CreateDouble(env, s.magnification));
        SetPropertyField(env, shapeObj, "properties", s.properties);
        if (usePackedCoords) {
            const int32_t ptCount = static_cast<int32_t>(s.points.size());
            pointOffsetsPtr[i] = runningPointOffset;
            pointCountsPtr[i] = ptCount;
            double* dst = packedCoordPtr + static_cast<size_t>(runningPointOffset) * 2;
            for (size_t j = 0; j < s.points.size(); j++) {
                dst[j * 2] = s.points[j].x;
                dst[j * 2 + 1] = s.points[j].y;
            }
            runningPointOffset += ptCount;
            SetProp(env, shapeObj, "points", sharedEmptyPoints);
        } else {
            napi_value points;
            napi_create_array_with_length(env, s.points.size(), &points);
            for (size_t j = 0; j < s.points.size(); j++) {
                napi_value pt;
                napi_create_object(env, &pt);
                SetProp(env, pt, "x", CreateDouble(env, s.points[j].x));
                SetProp(env, pt, "y", CreateDouble(env, s.points[j].y));
                napi_set_element(env, points, j, pt);
            }
            SetProp(env, shapeObj, "points", points);
        }
        napi_set_element(env, shapes, i, shapeObj);
    }
    SetProp(env, obj, "shapes", shapes);
    return obj;
}

/** Bound interactive expansion without enumerating arrays (including nested products).
 * Full import is transactional; quickScan can still inspect oversized files. */
/** Fill g_layout from parse result with correct ownerCellId and instance refs. */
static std::unique_ptr<Layout> BuildSceneLayoutFromParseResult(const GdsiiParseResult& parseResult,
                                                            const NativeJobControl* control = nullptr,
                                                            Layout::SpatialIndexBuild spatialIndexBuild = Layout::SpatialIndexBuild::Immediate) {
    ValidateInteractiveImportBudget(parseResult, control);
    auto nextLayout = std::make_unique<Layout>();
    nextLayout->libName = parseResult.libName;
    nextLayout->dbUnit = parseResult.physicalUnits;
    nextLayout->userUnit = parseResult.userUnits;
    nextLayout->layoutContextRecords = parseResult.layoutContextRecords;
    nextLayout->cellKeys=parseResult.cellKeys;nextLayout->ports=parseResult.ports;nextLayout->crossSections=parseResult.crossSections;
    AppendSceneProperties(nextLayout->libProperties, parseResult.libProperties);

    // Cell index in parseResult.cells is the stable ownerCellId used by UI
    for (size_t ci = 0; ci < parseResult.cells.size(); ci++) {
        if (control) control->check();
        const int cellId = static_cast<int>(ci);
        nextLayout->addCellWithId(cellId, parseResult.cells[ci].name);
        Cell* cell = nextLayout->findCell(cellId);
        if (cell == nullptr) {
            continue;
        }
        bool isTop = std::find(parseResult.topCellIds.begin(), parseResult.topCellIds.end(),
                               cellId) != parseResult.topCellIds.end();
        if (isTop) {
            cell->isTopCell = true;
        }
        // 结构级属性镜像进文档模型（供 findProperty / 后续属性面板；无属性时不分配）
        AppendSceneProperties(cell->properties, parseResult.cells[ci].properties);
        cell->contextRecords = layout_context::CellRecords(parseResult,ci);
    }
    if (parseResult.primaryTopCellId >= 0) {
        nextLayout->setTopCell(parseResult.primaryTopCellId);
    }

    for (const auto& s : parseResult.shapes) {
        if (control) control->check();
        SceneShape shape;
        shape.id = s.id;
        shape.layerKey = {static_cast<int16_t>(s.layerNumber), static_cast<int16_t>(s.datatype)};
        // Prefer ownerCellId from reader (correct); fall back to cellId only for legacy.
        shape.ownerCellId = s.ownerCellId >= 0 ? s.ownerCellId : s.cellId;
        shape.pathWidth = s.pathWidth;
        shape.pathType = s.pathType;   // 端型随几何一同进 native 模型（渲染/导出/DRC 共用）
        shape.pathBeginExtension = s.pathBeginExtension;
        shape.pathEndExtension = s.pathEndExtension;
        shape.pathWidthAbsolute = s.pathWidthAbsolute;
        shape.text = s.text;
        shape.textPresentation = s.textPresentation;
        shape.textRotation = s.rotation;
        shape.textMagnification = s.magnification;
        shape.textMirror = s.mirror;

        if (s.type == "rect") shape.type = ShapeType::RECT;
        else if (s.type == "polygon") shape.type = ShapeType::POLYGON;
        else if (s.type == "path") shape.type = ShapeType::PATH;
        else if (s.type == "text") shape.type = ShapeType::TEXT;
        else if (s.type == "instance") shape.type = ShapeType::INSTANCE;
        else if (s.type == "node") shape.type = ShapeType::NODE;
        else shape.type = ShapeType::POLYGON;

        for (const auto& p : s.points) {
            if (control) control->check();
            shape.points.push_back({p.x, p.y});
        }

        if (shape.type == ShapeType::INSTANCE) {
            // P0: INSTANCE 只进 instances 表，不进几何 shapes，避免 flatten 双轨/占空间索引
            CellInstance inst;
            inst.referencedCellName = s.cellName;
            inst.referencedCellId = s.cellId;
            inst.ownerCellId = shape.ownerCellId;
            inst.transform.x = shape.points.empty() ? 0 : shape.points[0].x;
            inst.transform.y = shape.points.empty() ? 0 : shape.points[0].y;
            inst.transform.rotation = s.rotation;
            inst.transform.magnification = s.magnification > 0 ? s.magnification : 1.0;
            inst.transform.arrayCols = s.arrayCols;
            inst.transform.arrayRows = s.arrayRows;
            inst.transform.arrayPitchX = s.arrayColStepX;
            inst.transform.arrayColStepY = s.arrayColStepY;
            inst.transform.arrayRowStepX = s.arrayRowStepX;
            inst.transform.arrayPitchY = s.arrayRowStepY;
            AppendSceneProperties(inst.properties, s.properties);
            // ArkTS 的 mirror 码：0=无 1=X 轴 2=Y 轴。GDS 只有一个 X 镜像位，
            // Y 镜像等价于「X 镜像 + 180°」——写出侧 gdsii_writer.cpp:361 正是这么归一的。
            // 读取/重建快照必须同样折算，否则 UI 里做一次纵向镜像后，
            // native 的 DRC/LVS/层级展开几何与刚落盘的文件差 180°（重载才自洽）。
            inst.transform.mirrorX = (s.mirror == 1 || s.mirror == 2);
            if (s.mirror == 2) {
                inst.transform.rotation = std::fmod(inst.transform.rotation + 180.0, 360.0);
            }
            if (inst.referencedCellId < 0 && !s.cellName.empty()) {
                if (Cell* c = nextLayout->findCellByName(s.cellName)) {
                    inst.referencedCellId = c->id;
                }
            }
            nextLayout->addInstance(inst);
        } else {
            // 元素级属性镜像进文档模型。实例（CellInstance）在文档模型里无属性字段
            // （见 docs/handoff/agent-F-props.md §2），其属性仍完整保留在
            // g_lastParseResult / 写出路径里，不经过此处。
            AppendSceneProperties(shape.properties, s.properties);
            nextLayout->addShape(shape, spatialIndexBuild);
        }
    }

    if (spatialIndexBuild == Layout::SpatialIndexBuild::Immediate) nextLayout->rebuildSpatialIndex();
    if (control) control->check();
    return nextLayout;
}

static void PopulateLayoutFromParseResult(const GdsiiParseResult& parseResult) {
    auto nextLayout = BuildSceneLayoutFromParseResult(parseResult);
    GdsiiParseResult nextParseResult = parseResult;
    g_lastParseResult = std::move(nextParseResult);
    g_layout = std::move(nextLayout);
    g_hasLastParseResult = parseResult.success;
}

static napi_value CreateAndCommitParseResult(napi_env env, GdsiiParseResult& parsed) {
    try {
        // Reject oversized hierarchies before constructing hundreds of thousands
        // of JS objects. The active document is still untouched at this point.
        if (parsed.success) ValidateInteractiveImportBudget(parsed);
        napi_value result = CreateFullParseResult(env, parsed);
        if (parsed.success) {
            std::lock_guard<std::mutex> lock(g_layoutMutex);
            PopulateLayoutFromParseResult(parsed);
        }
        return result;
    } catch (const std::exception& error) {
        parsed.success = false;
        parsed.errorMessage = error.what();
        parsed.shapes.clear();
        parsed.cells.clear();
        parsed.allLayers.clear();
        parsed.topCellIds.clear();
        return CreateFullParseResult(env, parsed);
    }
}

// ==================== File Parsing (Async) ====================

struct ParseAsyncData {
    std::string filePath;
    bool isOasis;
    bool quickScan;
    // Results
    GdsiiParseResult parseResult;
    std::string error;
    bool success;
    // NAPI
    napi_async_work work;
    napi_deferred deferred;
};

static void ParseExecute(napi_env env, void* data) {
    auto* asyncData = static_cast<ParseAsyncData*>(data);

    try {
        if (asyncData->isOasis) {
            OasisReader reader;
            if (asyncData->quickScan) {
                asyncData->parseResult = reader.quickInfo(asyncData->filePath);
            } else {
                asyncData->parseResult = reader.parse(asyncData->filePath);
            }
        } else {
            GdsiiReader reader;
            if (asyncData->quickScan) {
                asyncData->parseResult = reader.quickInfo(asyncData->filePath);
            } else {
                asyncData->parseResult = reader.parse(asyncData->filePath);
            }
        }
        asyncData->success = asyncData->parseResult.success;
        asyncData->error = asyncData->parseResult.errorMessage;
    } catch (const std::exception& e) {
        asyncData->success = false;
        asyncData->error = std::string("Parse exception: ") + e.what();
    }
}

static void ParseComplete(napi_env env, napi_status status, void* data) {
    auto* asyncData = static_cast<ParseAsyncData*>(data);
    if (status != napi_ok) {
        asyncData->success = false;
        asyncData->parseResult.success = false;
        asyncData->parseResult.errorMessage = "Async parse cancelled or failed";
    }

    napi_value result = nullptr;
    try {
        if (asyncData->success && !asyncData->quickScan && status == napi_ok)
            ValidateInteractiveImportBudget(asyncData->parseResult);
        // 与同步 parseGdsii 统一：始终返回完整 GdsiiResult 字段（Index.d.ts）
        result = CreateFullParseResult(env, asyncData->parseResult);
        if (asyncData->success && !asyncData->quickScan && status == napi_ok) {
            std::lock_guard<std::mutex> lock(g_layoutMutex);
            PopulateLayoutFromParseResult(asyncData->parseResult);
        } else if (asyncData->parseResult.errorMessage.empty() && !asyncData->error.empty()) {
            asyncData->parseResult.errorMessage = asyncData->error;
            asyncData->parseResult.success = false;
        }

        // async 工作线程异常时保证 success=false
        if (!asyncData->success && asyncData->parseResult.success) {
            SetProp(env, result, "success", CreateBool(env, false));
            SetProp(env, result, "errorMessage", CreateString(env, asyncData->error));
        }
    } catch (const std::exception& e) {
        // Populate/Create 抛出（如 bad_alloc）：回退为失败结果，避免异常穿越 NAPI 边界崩溃
        asyncData->error = std::string("Parse complete exception: ") + e.what();
        napi_value fallback;
        if (napi_create_object(env, &fallback) == napi_ok) {
            SetProp(env, fallback, "success", CreateBool(env, false));
            SetProp(env, fallback, "errorMessage", CreateString(env, asyncData->error));
            result = fallback;
        }
    } catch (...) {
        napi_value fallback;
        if (napi_create_object(env, &fallback) == napi_ok) {
            SetProp(env, fallback, "success", CreateBool(env, false));
            SetProp(env, fallback, "errorMessage",
                    CreateString(env, "Parse complete: unknown exception"));
            result = fallback;
        }
    }

    // 无论成功失败都必须 resolve 并清理，避免 Promise 悬挂与内存泄漏
    if (result != nullptr) {
        napi_resolve_deferred(env, asyncData->deferred, result);
    } else {
        napi_value undef;
        napi_get_undefined(env, &undef);
        napi_resolve_deferred(env, asyncData->deferred, undef);
    }
    napi_delete_async_work(env, asyncData->work);
    delete asyncData;
}

// Async parse: returns Promise<GdsiiResult>
static napi_value NapiParseAsync(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto* asyncData = new ParseAsyncData();
    asyncData->filePath = ReadStringArg(env, args[0]);
    asyncData->isOasis = false;
    asyncData->quickScan = false;

    if (argc > 1) {
        napi_valuetype type;
        napi_typeof(env, args[1], &type);
        if (type == napi_object) {
            napi_value isOasisVal, quickVal;
            napi_get_named_property(env, args[1], "isOasis", &isOasisVal);
            napi_get_named_property(env, args[1], "quickScan", &quickVal);
            napi_get_value_bool(env, isOasisVal, &asyncData->isOasis);
            napi_get_value_bool(env, quickVal, &asyncData->quickScan);
        }
    }

    // Detect format from extension
    std::string ext = asyncData->filePath.substr(asyncData->filePath.find_last_of('.') + 1);
    if (ext == "oas" || ext == "oasis" || ext == "OAS" || ext == "OASIS") {
        asyncData->isOasis = true;
    }

    napi_value promise;
    napi_create_promise(env, &asyncData->deferred, &promise);

    napi_value resourceName;
    napi_create_string_utf8(env, "parseLayout", NAPI_AUTO_LENGTH, &resourceName);
    napi_status createStatus = napi_create_async_work(env, nullptr, resourceName, ParseExecute,
                          ParseComplete, asyncData, &asyncData->work);
    if (createStatus != napi_ok) {
        // 创建失败：先保存 deferred 句柄，再释放 asyncData，最后 reject，避免泄漏/悬挂/UAF
        napi_deferred deferred = asyncData->deferred;
        delete asyncData;
        napi_value err;
        napi_create_error(env, nullptr, CreateString(env, "Failed to create async work"), &err);
        napi_reject_deferred(env, deferred, err);
        return promise;
    }
    napi_status queueStatus = napi_queue_async_work(env, asyncData->work);
    if (queueStatus != napi_ok) {
        napi_delete_async_work(env, asyncData->work);
        napi_value err;
        napi_create_error(env, nullptr, CreateString(env, "Failed to queue async work"), &err);
        napi_reject_deferred(env, asyncData->deferred, err);
        delete asyncData;
    }

    return promise;
}

// ==================== Spatial Queries ====================

// queryPoint(x, y) → shape IDs
static napi_value NapiQueryPoint(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double x = ReadDoubleArg(env, args[0]);
    double y = ReadDoubleArg(env, args[1]);

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    napi_value result;
    napi_create_array(env, &result);

    if (g_layout) {
        auto ids = g_layout->queryPoint(x, y);
        napi_create_array_with_length(env, ids.size(), &result);
        for (size_t i = 0; i < ids.size(); i++) {
            if (ids[i] >= 0 && ids[i] < (int)g_layout->shapes.size()) {
                napi_set_element(env, result, i,
                    CreateInt64(env, g_layout->shapes[ids[i]].id));
            }
        }
    }
    return result;
}

// queryRange(x0, y0, x1, y1) → shape IDs
static napi_value NapiQueryRange(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    BBox box(ReadDoubleArg(env, args[0]), ReadDoubleArg(env, args[1]),
             ReadDoubleArg(env, args[2]), ReadDoubleArg(env, args[3]));

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    napi_value result;
    napi_create_array(env, &result);

    if (g_layout) {
        auto ids = g_layout->queryRange(box);
        napi_create_array_with_length(env, ids.size(), &result);
        for (size_t i = 0; i < ids.size(); i++) {
            if (ids[i] >= 0 && ids[i] < (int)g_layout->shapes.size()) {
                napi_set_element(env, result, i, CreateInt64(env, g_layout->shapes[ids[i]].id));
            }
        }
    }
    return result;
}

// queryNearest(x, y, k) → shape IDs
static napi_value NapiQueryNearest(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double x = ReadDoubleArg(env, args[0]);
    double y = ReadDoubleArg(env, args[1]);
    int k = ReadIntArg(env, args[2]);

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    napi_value result;
    napi_create_array(env, &result);

    if (g_layout) {
        auto ids = g_layout->queryNearest(x, y, k);
        napi_create_array_with_length(env, ids.size(), &result);
        for (size_t i = 0; i < ids.size(); i++) {
            if (ids[i] >= 0 && ids[i] < (int)g_layout->shapes.size()) {
                napi_set_element(env, result, i, CreateInt64(env, g_layout->shapes[ids[i]].id));
            }
        }
    }
    return result;
}

// ==================== Boolean Operations ====================
// Validate before conversion. Dropping a bad vertex changes topology and must
// never turn malformed input into a plausible successful result.
static clipper::Path ReadGeometryPath(napi_env env, napi_value value, bool requireGrid = false) {
    bool isArray = false;
    uint32_t len = 0;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, value, &len) != napi_ok || (len % 2) != 0 ||
        len > static_cast<uint32_t>(clipper::GeneralClipper::kMaxEdges) * 2)
        throw std::invalid_argument("Geometry expects an even-length bounded coordinate array");
    clipper::Path path;
    path.reserve(len / 2);
    for (uint32_t i = 0; i < len; i += 2) {
        napi_value xv = nullptr, yv = nullptr;
        double x = 0, y = 0;
        if (napi_get_element(env, value, i, &xv) != napi_ok ||
            napi_get_element(env, value, i + 1, &yv) != napi_ok ||
            napi_get_value_double(env, xv, &x) != napi_ok ||
            napi_get_value_double(env, yv, &y) != napi_ok ||
            !std::isfinite(x) || !std::isfinite(y) ||
            std::abs(x) > clipper::GeneralClipper::kCoordLimit ||
            std::abs(y) > clipper::GeneralClipper::kCoordLimit)
            throw std::invalid_argument("Geometry coordinates must be finite numbers in the supported DBU range");
        if (requireGrid && (std::floor(x) != x || std::floor(y) != y))
            throw std::invalid_argument("Editing geometry requires integer nm coordinates; sub-nm input was preserved without editing");
        path.push_back({std::llround(x), std::llround(y)});
    }
    return path;
}

static double ReadGeometryNumber(napi_env env, napi_value value) {
    double n = 0;
    if (napi_get_value_double(env, value, &n) != napi_ok || !std::isfinite(n))
        throw std::invalid_argument("Geometry parameter must be a finite number");
    return n;
}

static int ReadGeometryEnum(napi_env env, napi_value value, int max) {
    const double n = ReadGeometryNumber(env, value);
    if (n < 0 || n > max || std::floor(n) != n)
        throw std::invalid_argument("Geometry operation/join enum is out of range");
    return static_cast<int>(n);
}

static napi_value WriteGeometryPaths(napi_env env, const clipper::Paths& paths) {
    napi_value out;
    napi_create_array_with_length(env, paths.size(), &out);
    for (size_t i = 0; i < paths.size(); ++i) {
        napi_value poly;
        napi_create_array_with_length(env, paths[i].size() * 2, &poly);
        for (size_t j = 0; j < paths[i].size(); ++j) {
            napi_set_element(env, poly, j * 2, CreateDouble(env, (double)paths[i][j].x));
            napi_set_element(env, poly, j * 2 + 1, CreateDouble(env, (double)paths[i][j].y));
        }
        napi_set_element(env, out, i, poly);
    }
    return out;
}

// booleanOp and booleanOpEx share the same even-odd operand semantics.
static napi_value NapiBooleanOp(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "parseAsync expects filePath");
        return nullptr;
    }
    if (argc != 3) throw std::invalid_argument("booleanOp expects subject, clip, operation");
    const auto a = ReadGeometryPath(env, args[0]);
    const auto b = ReadGeometryPath(env, args[1]);
    const auto op = static_cast<clipper::ClipType>(ReadGeometryEnum(env, args[2], 3));
    const auto result = clipper::GeneralClipper::execute({a}, {b}, op);
    if (result.approximated) throw std::runtime_error(result.note);
    return WriteGeometryPaths(env, result.contours);
}

// Legacy singular result; offsetPolygons preserves every island/hole.
static napi_value NapiOffsetPolygon(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 3) throw std::invalid_argument("offsetPolygon expects points, delta, join");
    const auto path = ReadGeometryPath(env, args[0]);
    const double delta = ReadGeometryNumber(env, args[1]);
    const auto join = static_cast<clipper::JoinType>(ReadGeometryEnum(env, args[2], 2));
    const auto result = clipper::GeneralClipper::offset({path}, delta, join);
    if (result.approximated) throw std::runtime_error(result.note);
    napi_value out;
    napi_create_array(env, &out);
    if (!result.contours.empty()) {
        const auto& p = result.contours.front();
        for (size_t i = 0; i < p.size(); ++i) {
            napi_set_element(env, out, i * 2, CreateDouble(env, (double)p[i].x));
            napi_set_element(env, out, i * 2 + 1, CreateDouble(env, (double)p[i].y));
        }
    }
    return out;
}

static napi_value NapiBooleanOpEx(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 3) throw std::invalid_argument("booleanOpEx expects subject, clip, operation");
    const auto a = ReadGeometryPath(env, args[0]);
    const auto b = ReadGeometryPath(env, args[1]);
    const auto op = static_cast<clipper::ClipType>(ReadGeometryEnum(env, args[2], 3));
    const auto res = clipper::GeneralClipper::execute({a}, {b}, op);
    napi_value obj;
    napi_create_object(env, &obj);
    SetProp(env, obj, "contours", WriteGeometryPaths(env, res.contours));
    SetProp(env, obj, "approximated", CreateBool(env, res.approximated));
    SetProp(env, obj, "note", CreateString(env, res.note));
    SetProp(env, obj, "droppedRings", CreateInt(env, res.droppedRings));
    return obj;
}

static napi_value NapiOffsetPolygons(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 3) throw std::invalid_argument("offsetPolygons expects points, delta, join");
    const auto path = ReadGeometryPath(env, args[0]);
    const double delta = ReadGeometryNumber(env, args[1]);
    const auto join = static_cast<clipper::JoinType>(ReadGeometryEnum(env, args[2], 2));
    const auto result = clipper::GeneralClipper::offset({path}, delta, join);
    if (result.approximated) throw std::runtime_error(result.note);
    return WriteGeometryPaths(env, result.contours);
}

// ==================== Geometry Queries ====================
// Dedicated editor endpoints return independent filled shapes, not signed rings.
static napi_value NapiBooleanOpForEdit(napi_env env, napi_callback_info info) {
    size_t argc=3; napi_value args[3]={nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=3) throw std::invalid_argument("booleanOpForEdit expects subject, clip, operation");
    const auto a=ReadGeometryPath(env,args[0],true), b=ReadGeometryPath(env,args[1],true);
    if(a.size()<3 || b.size()<3) throw std::invalid_argument("Editing requires polygon operands");
    const auto op=static_cast<clipper::ClipType>(ReadGeometryEnum(env,args[2],3));
    return WriteGeometryPaths(env,clipper::EditRegion::fracture(clipper::GeneralClipper::execute({a},{b},op)));
}

static napi_value NapiRegionBooleanForEdit(napi_env env, napi_callback_info info) {
    size_t argc=4; napi_value args[4]={nullptr,nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=4) throw std::invalid_argument("regionBooleanForEdit expects subject, clip, operation, nm grid");
    size_t vertices=0;
    auto read = [&](napi_value value) {
        bool array=false; uint32_t count=0;
        if(napi_is_array(env,value,&array)!=napi_ok || !array ||
           napi_get_array_length(env,value,&count)!=napi_ok || count>clipper::EditRegion::kMaxPieces)
            throw std::invalid_argument("Region expects a bounded polygon array");
        clipper::GridEditRegion::Region region;
        for(uint32_t i=0;i<count;++i) {
            napi_value item=nullptr; napi_get_element(env,value,i,&item);
            uint32_t len=0; array=false;
            if(napi_is_array(env,item,&array)!=napi_ok || !array ||
               napi_get_array_length(env,item,&len)!=napi_ok || len<6 || len%2 ||
               len/2>clipper::EditRegion::kMaxVertices-vertices)
                throw std::invalid_argument("Region vertex limit or incomplete polygon");
            vertices+=len/2;
            clipper::GridEditRegion::Ring ring;
            for(uint32_t j=0;j<len;j+=2) {
                napi_value x=nullptr,y=nullptr;
                napi_get_element(env,item,j,&x); napi_get_element(env,item,j+1,&y);
                ring.push_back({ReadGeometryNumber(env,x),ReadGeometryNumber(env,y)});
            }
            region.push_back(std::move(ring));
        }
        return region;
    };
    const auto subject=read(args[0]),clip=read(args[1]);
    const auto op=static_cast<clipper::ClipType>(ReadGeometryEnum(env,args[2],3));
    const auto result=clipper::GridEditRegion::execute(subject,clip,op,ReadGeometryNumber(env,args[3]));
    napi_value out; napi_create_array_with_length(env,result.size(),&out);
    for(size_t i=0;i<result.size();++i) {
        napi_value ring; napi_create_array_with_length(env,result[i].size()*2,&ring);
        for(size_t j=0;j<result[i].size();++j) {
            napi_set_element(env,ring,j*2,CreateDouble(env,result[i][j][0]));
            napi_set_element(env,ring,j*2+1,CreateDouble(env,result[i][j][1]));
        }
        napi_set_element(env,out,i,ring);
    }
    return out;
}

#include "path_region_whole_dpath_napi.h"

static napi_value NapiPathRegionForEdit(napi_env env, napi_callback_info info) {
    size_t argc=8; napi_value args[8]={nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=8) throw std::invalid_argument("pathRegionForEdit expects spine, width, type, begin, end, worldScale, absolute, grid");
    bool array=false; uint32_t len=0;
    if(napi_is_array(env,args[0],&array)!=napi_ok || !array ||
       napi_get_array_length(env,args[0],&len)!=napi_ok || len<4 || len%2 ||
       len/2>clipper::EditRegion::kMaxVertices)
        throw std::invalid_argument("PATH expects a bounded complete coordinate array");
    clipper::PathEditRegion::Ring spine;
    spine.reserve(len/2);
    for(uint32_t j=0;j<len;j+=2) {
        napi_value x=nullptr,y=nullptr;
        napi_get_element(env,args[0],j,&x); napi_get_element(env,args[0],j+1,&y);
        spine.push_back({ReadGeometryNumber(env,x),ReadGeometryNumber(env,y)});
    }
    bool absolute=false;
    if(napi_get_value_bool(env,args[6],&absolute)!=napi_ok)
        throw std::invalid_argument("PATH absolute WIDTH must be boolean");
    const auto result=clipper::PathEditRegion::execute(spine,ReadGeometryNumber(env,args[1]),
        ReadGeometryEnum(env,args[2],4),ReadGeometryNumber(env,args[3]),ReadGeometryNumber(env,args[4]),
        ReadGeometryNumber(env,args[5]),absolute,ReadGeometryNumber(env,args[7]));
    napi_value out; napi_create_array_with_length(env,result.size(),&out);
    for(size_t i=0;i<result.size();++i) {
        napi_value ring; napi_create_array_with_length(env,result[i].size()*2,&ring);
        for(size_t j=0;j<result[i].size();++j) {
            napi_set_element(env,ring,j*2,CreateDouble(env,result[i][j][0]));
            napi_set_element(env,ring,j*2+1,CreateDouble(env,result[i][j][1]));
        }
        napi_set_element(env,out,i,ring);
    }
    return out;
}

static napi_value NapiOffsetPolygonsForEdit(napi_env env, napi_callback_info info) {
    size_t argc=3; napi_value args[3]={nullptr,nullptr,nullptr};
    napi_get_cb_info(env,info,&argc,args,nullptr,nullptr);
    if(argc!=3) throw std::invalid_argument("offsetPolygonsForEdit expects points, delta, join");
    bool isArray=false;uint32_t count=0;
    if(napi_is_array(env,args[0],&isArray)!=napi_ok || !isArray ||
       napi_get_array_length(env,args[0],&count)!=napi_ok || count>clipper::EditRegion::kMaxPieces)
        throw std::invalid_argument("Editing offset requires a bounded polygon array");
    clipper::Paths paths;size_t vertices=0;
    for(uint32_t i=0;i<count;++i){napi_value value; napi_get_element(env,args[0],i,&value);
        auto p=ReadGeometryPath(env,value,true);vertices+=p.size();
        if(p.size()<3 || vertices>clipper::EditRegion::kMaxVertices)
            throw std::invalid_argument("Editing offset polygon/vertex limit");
        paths.push_back(std::move(p));}
    const double delta=ReadGeometryNumber(env,args[1]);
    const auto join=static_cast<clipper::JoinType>(ReadGeometryEnum(env,args[2],2));
    const auto region=clipper::GeneralClipper::unite(paths);
    if(region.approximated)throw std::runtime_error(region.note);
    return WriteGeometryPaths(env,clipper::EditRegion::fracture(clipper::GeneralClipper::offset(region.contours,delta,join)));
}

// polygonDistance(pointsA, pointsB) → distance
static napi_value NapiPolygonDistance(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    auto parseVec2Array = [&](napi_value arr) -> std::vector<Vec2> {
        std::vector<Vec2> pts;
        uint32_t len;
        napi_get_array_length(env, arr, &len);
        for (uint32_t i = 0; i + 1 < len; i += 2) {
            napi_value xVal, yVal;
            napi_get_element(env, arr, i, &xVal);
            napi_get_element(env, arr, i + 1, &yVal);
            double x, y;
            napi_get_value_double(env, xVal, &x);
            napi_get_value_double(env, yVal, &y);
            pts.push_back({x, y});
        }
        return pts;
    };

    auto polyA = parseVec2Array(args[0]);
    auto polyB = parseVec2Array(args[1]);

    double dist = GeometryEngine::polygonToPolygonDistance(polyA, polyB);
    return CreateDouble(env, dist);
}

// polygonArea(points) → area
static napi_value NapiPolygonArea(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::vector<Vec2> poly;
    uint32_t len;
    napi_get_array_length(env, args[0], &len);
    for (uint32_t i = 0; i + 1 < len; i += 2) {
        napi_value xVal, yVal;
        napi_get_element(env, args[0], i, &xVal);
        napi_get_element(env, args[0], i + 1, &yVal);
        double x, y;
        napi_get_value_double(env, xVal, &x);
        napi_get_value_double(env, yVal, &y);
        poly.push_back({x, y});
    }

    return CreateDouble(env, GeometryEngine::polygonArea(poly));
}

// pointInPolygon(x, y, points) → -1/0/+1
static napi_value NapiPointInPolygon(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    double px = ReadDoubleArg(env, args[0]);
    double py = ReadDoubleArg(env, args[1]);

    std::vector<Vec2> poly;
    uint32_t len;
    napi_get_array_length(env, args[2], &len);
    for (uint32_t i = 0; i + 1 < len; i += 2) {
        napi_value xVal, yVal;
        napi_get_element(env, args[2], i, &xVal);
        napi_get_element(env, args[2], i + 1, &yVal);
        double x, y;
        napi_get_value_double(env, xVal, &x);
        napi_get_value_double(env, yVal, &y);
        poly.push_back({x, y});
    }

    int result = GeometryEngine::pointInPolygon({px, py}, poly);
    return CreateInt(env, result);
}

// ==================== Layout Stats ====================

static napi_value NapiGetLayoutStats(napi_env env, napi_callback_info info) {
    std::lock_guard<std::mutex> lock(g_layoutMutex);

    napi_value result;
    napi_create_object(env, &result);

    if (g_layout) {
        auto stats = g_layout->getStats();
        SetProp(env, result, "totalShapes", CreateInt(env, (int)stats.totalShapes));
        SetProp(env, result, "totalInstances", CreateInt(env, (int)stats.totalInstances));
        SetProp(env, result, "totalCells", CreateInt(env, (int)stats.totalCells));
        SetProp(env, result, "totalLayers", CreateInt(env, (int)stats.totalLayers));
        SetProp(env, result, "bboxMinX", CreateDouble(env, stats.designBBox.minX));
        SetProp(env, result, "bboxMinY", CreateDouble(env, stats.designBBox.minY));
        SetProp(env, result, "bboxMaxX", CreateDouble(env, stats.designBBox.maxX));
        SetProp(env, result, "bboxMaxY", CreateDouble(env, stats.designBBox.maxY));
        SetProp(env, result, "topCellId", CreateInt(env, g_layout->topCellId()));
    } else {
        SetProp(env, result, "totalShapes", CreateInt(env, 0));
        SetProp(env, result, "loaded", CreateBool(env, false));
    }

    return result;
}

// ==================== Version ====================

static napi_value NapiVersion(napi_env env, napi_callback_info info) {
    return CreateString(env, "0.3.5-contract-fix");
}

/**
 * 从 g_layout 重建 GdsiiParseResult（编辑后若未同步 g_lastParseResult 的兜底）。
 * 实例来自 Layout::instances；几何来自 Layout::shapes。
 */
/**
 * SceneProperty → LayoutProperty（无解析快照时 writeGdsii/writeOasis 的回读路径）。
 * SceneProperty 没有 dtype 字段（scene_graph.h 本切片禁改），故值一律按 ASCII 槽位表达：
 * 文本值逐字节无损；只有「快照缺失 + 原值为二进制」这一极少见分支会把 dtype 记成 6。
 */
static void AppendReadProperties(std::vector<LayoutProperty>& dst,
                                 const std::vector<SceneProperty>& src) {
    if (src.empty()) {
        return;
    }
    if (src.size() > kMaxPropsPerOwnerWire) throw std::invalid_argument("Property owner budget exceeded");
    const size_t n = src.size();
    dst.reserve(dst.size() + n);
    for (size_t i = 0; i < n; i++) {
        LayoutProperty lp;
        lp.attr = static_cast<int16_t>(src[i].attr);
        lp.dtype = src[i].dtype;
        lp.name = src[i].name;
        lp.value = src[i].value;
        dst.push_back(std::move(lp));
    }
}

static GdsiiParseResult LayoutToParseResult(const Layout& layout) {
    GdsiiParseResult r;
    r.success = true;
    r.libName = layout.libName;
    r.userUnits = layout.userUnit > 0 ? layout.userUnit : 0.001;
    r.physicalUnits = layout.dbUnit > 0 ? layout.dbUnit : 1e-9;
    r.layoutContextRecords = layout.layoutContextRecords;
    r.cellKeys=layout.cellKeys;r.ports=layout.ports;r.crossSections=layout.crossSections;
    AppendReadProperties(r.libProperties, layout.libProperties);
    r.primaryTopCellId = layout.topCellId();
    r.cellCount = static_cast<int>(layout.cells.size());
    for (const auto& c : layout.cells) {
        CellInfo ci;
        ci.name = c.name;
        ci.elementCount = static_cast<int>(c.shapeIds.size() + c.instanceIds.size());
        AppendReadProperties(ci.properties, c.properties);
        r.cellContextRecords.push_back(c.contextRecords);
        r.cells.push_back(ci);
        if (c.isTopCell) {
            r.topCellIds.push_back(c.id);
        }
    }
    if (r.topCellIds.empty() && r.primaryTopCellId >= 0) {
        r.topCellIds.push_back(r.primaryTopCellId);
    }

    int nextId = 1;
    for (const auto& s : layout.shapes) {
        if (s.type == ShapeType::INSTANCE) {
            continue; // instances 单独从 instances 写出，避免重复
        }
        LayoutShape ls;
        ls.id = s.id > 0 ? static_cast<int>(s.id) : nextId++;
        ls.layerNumber = s.layerKey.layer;
        ls.datatype = s.layerKey.datatype;
        ls.ownerCellId = s.ownerCellId;
        ls.pathWidth = s.pathWidth;
        ls.pathType = s.pathType;
        ls.pathBeginExtension = s.pathBeginExtension;
        ls.pathEndExtension = s.pathEndExtension;
        ls.pathWidthAbsolute = s.pathWidthAbsolute;
        ls.text = s.text;
        ls.textPresentation = s.textPresentation;
        if (s.type == ShapeType::TEXT) {
            ls.rotation = s.textRotation;
            ls.magnification = s.textMagnification;
            ls.mirror = s.textMirror;
        }
        switch (s.type) {
            case ShapeType::RECT: ls.type = "rect"; break;
            case ShapeType::PATH: ls.type = "path"; break;
            case ShapeType::TEXT: ls.type = "text"; break;
            case ShapeType::NODE: ls.type = "node"; break;
            case ShapeType::BOX: ls.type = "rect"; break;
            default: ls.type = "polygon"; break;
        }
        for (const auto& p : s.points) {
            ls.points.push_back({p.x, p.y});
        }
        AppendReadProperties(ls.properties, s.properties);
        r.shapes.push_back(ls);
    }
    for (const auto& inst : layout.instances) {
        LayoutShape ls;
        ls.id = nextId++;
        ls.type = "instance";
        ls.ownerCellId = inst.ownerCellId;
        ls.cellId = inst.referencedCellId;
        ls.cellName = inst.referencedCellName;
        ls.rotation = inst.transform.rotation;
        ls.magnification = inst.transform.magnification > 0 ? inst.transform.magnification : 1.0;
        ls.mirror = inst.transform.mirrorX ? 1 : 0;
        ls.arrayCols = inst.transform.arrayCols;
        ls.arrayRows = inst.transform.arrayRows;
        ls.arrayColStepX = inst.transform.arrayPitchX;
        ls.arrayColStepY = inst.transform.arrayColStepY;
        ls.arrayRowStepX = inst.transform.arrayRowStepX;
        ls.arrayRowStepY = inst.transform.arrayPitchY;
        AppendReadProperties(ls.properties, inst.properties);
        ls.points.push_back({inst.transform.x, inst.transform.y});
        r.shapes.push_back(ls);
    }
    r.totalElements = static_cast<int>(r.shapes.size());
    return r;
}

/**
 * writeGdsii(filePath) → 用 g_lastParseResult / g_layout 快照写出（未编辑路径）
 * writeGdsiiDocument(filePath, document) → 用 ArkTS 传入的 cell/shapes 写出（含编辑）
 */
static napi_value NapiWriteGdsii(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "writeGdsii expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);

    GdsiiWriteResult wr;
    {
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        if (g_hasLastParseResult && g_lastParseResult.success) {
            wr = WriteGdsii(g_lastParseResult, path);
        } else if (g_layout) {
            GdsiiParseResult rebuilt = LayoutToParseResult(*g_layout);
            wr = WriteGdsii(rebuilt, path);
        } else {
            wr.success = false;
            wr.errorMessage = "no layout loaded; open a GDS first";
        }
    }

    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "success", CreateBool(env, wr.success));
    napi_set_named_property(env, obj, "errorMessage", CreateString(env, wr.errorMessage));
    napi_set_named_property(env, obj, "writtenCells", CreateInt(env, wr.writtenCells));
    napi_set_named_property(env, obj, "writtenShapes", CreateInt(env, wr.writtenShapes));
    napi_set_named_property(env, obj, "skippedShapes", CreateInt(env, wr.skippedShapes));
    napi_set_named_property(env, obj, "bytes", CreateInt64(env, static_cast<int64_t>(wr.bytes)));
    SetProp(env, obj, "quantization", CreateQuantization(env, wr.quantization));
    return obj;
}

/**
 * writeOasis(filePath) → 将最近解析结果 / g_layout 快照写出为 OASIS
 * （含名称表、modal 压缩、PLACEMENT 17/18、规范 END + CRC32）。
 */
static napi_value NapiWriteOasis(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "writeOasis expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);

    GdsiiWriteResult wr;
    {
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        if (g_hasLastParseResult && g_lastParseResult.success) {
            wr = WriteOasis(g_lastParseResult, path);
        } else if (g_layout) {
            GdsiiParseResult rebuilt = LayoutToParseResult(*g_layout);
            wr = WriteOasis(rebuilt, path);
        } else {
            wr.success = false;
            wr.errorMessage = "no layout loaded; open a file first";
        }
    }

    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "success", CreateBool(env, wr.success));
    napi_set_named_property(env, obj, "errorMessage", CreateString(env, wr.errorMessage));
    napi_set_named_property(env, obj, "writtenCells", CreateInt(env, wr.writtenCells));
    napi_set_named_property(env, obj, "writtenShapes", CreateInt(env, wr.writtenShapes));
    napi_set_named_property(env, obj, "skippedShapes", CreateInt(env, wr.skippedShapes));
    napi_set_named_property(env, obj, "bytes", CreateInt64(env, static_cast<int64_t>(wr.bytes)));
    SetProp(env, obj, "quantization", CreateQuantization(env, wr.quantization));
    return obj;
}

static bool GetObjProp(napi_env env, napi_value obj, const char* name, napi_value* out) {
    bool has = false;
    napi_has_named_property(env, obj, name, &has);
    if (!has) {
        return false;
    }
    return napi_get_named_property(env, obj, name, out) == napi_ok;
}

static std::string GetObjString(napi_env env, napi_value obj, const char* name, const std::string& def) {
    napi_value v;
    if (!GetObjProp(env, obj, name, &v)) {
        return def;
    }
    napi_valuetype t = napi_undefined;
    napi_typeof(env, v, &t);
    if (t != napi_string) {
        return def;
    }
    return ReadStringArg(env, v);
}

static std::vector<std::string> ReadContextArray(napi_env env,napi_value arr,size_t& budget){
    bool isArray=false;napi_is_array(env,arr,&isArray);uint32_t n=0;
    if(!isArray||napi_get_array_length(env,arr,&n)!=napi_ok||n>layout_context::kMaxRecords)throw std::invalid_argument("Invalid context record array");
    std::vector<std::string> records;records.reserve(n);
    for(uint32_t i=0;i<n;++i){
        ParseResultHandleScope handles(env);napi_value record,value,encoding;napi_valuetype type=napi_undefined;
        if(napi_get_element(env,arr,i,&record)!=napi_ok||!GetObjProp(env,record,"value",&value)||!GetObjProp(env,record,"encoding",&encoding))throw std::invalid_argument("Invalid context record");
        napi_typeof(env,value,&type);if(type!=napi_string)throw std::invalid_argument("Context value must be a string");napi_typeof(env,encoding,&type);if(type!=napi_string)throw std::invalid_argument("Context encoding must be a string");
        std::string bytes=ReadStringArg(env,value),mode=ReadStringArg(env,encoding);
        if(mode=="hex"){std::string decoded;if(!bytes.empty()&&!property_wire::FromHexWire("#"+bytes,decoded))throw std::invalid_argument("Invalid context hex bytes");bytes=std::move(decoded);}
        else if(mode!="utf8"||!layout_context::ValidUtf8(bytes))throw std::invalid_argument("Invalid UTF-8 context bytes");
        if(bytes.size()>layout_context::kMaxStringBytes||bytes.size()>layout_context::kMaxBytes-budget)throw std::invalid_argument("Context byte budget exceeded");budget+=bytes.size();records.push_back(std::move(bytes));
    }return records;
}

static void ReadContextFields(napi_env env,napi_value doc,GdsiiParseResult& layout){
    size_t budget=0;napi_value records;
    if(GetObjProp(env,doc,"layoutContextRecords",&records))layout.layoutContextRecords=ReadContextArray(env,records,budget);
    if(GetObjProp(env,doc,"cellContextRecords",&records)){
        bool array=false;napi_is_array(env,records,&array);uint32_t count=0;
        if(!array||napi_get_array_length(env,records,&count)!=napi_ok||count!=layout.cells.size())throw std::invalid_argument("Cell context records must match the Cell table");
        for(uint32_t i=0;i<count;++i){ParseResultHandleScope handles(env);napi_value group;if(napi_get_element(env,records,i,&group)!=napi_ok)throw std::invalid_argument("Unreadable Cell context records");layout.cellContextRecords.push_back(ReadContextArray(env,group,budget));}
    }
    layout_context::Validate(layout);
}

static double GetObjDouble(napi_env env, napi_value obj, const char* name, double def) {
    napi_value v;
    if (!GetObjProp(env, obj, name, &v)) {
        return def;
    }
    double d = def;
    napi_get_value_double(env, v, &d);
    return d;
}

static int32_t GetObjInt(napi_env env, napi_value obj, const char* name, int32_t def) {
    napi_value v;
    if (!GetObjProp(env, obj, name, &v)) {
        return def;
    }
    int32_t i = def;
    napi_get_value_int32(env, v, &i);
    return i;
}

/** 数值字段：缺省 → 用默认值；存在但类型不是 number → false（调用方忽略该条目）。 */
static bool GetObjNumberField(napi_env env, napi_value obj, const char* name, int32_t def,
                              int32_t& out) {
    napi_value v;
    if (!GetObjProp(env, obj, name, &v)) {
        out = def;
        return true;
    }
    napi_valuetype t = napi_undefined;
    napi_typeof(env, v, &t);
    if (t != napi_number) {
        return false;
    }
    double raw=0;if(napi_get_value_double(env,v,&raw)!=napi_ok||!std::isfinite(raw)||std::floor(raw)!=raw||raw<INT32_MIN||raw>INT32_MAX)return false;
    out = static_cast<int32_t>(raw);
    return true;
}

/** 单个属性条目对象 → LayoutProperty；畸形条目返回 false（忽略，不抛）。 */
static bool ReadPropertyEntry(napi_env env, napi_value el, LayoutProperty& out, size_t& budget) {
    napi_valuetype t = napi_undefined;
    if (napi_typeof(env, el, &t) != napi_ok || t != napi_object) {
        return false;
    }
    int32_t attr = 0;
    int32_t dtype = 6;
    if (!GetObjNumberField(env, el, "attr", 0, attr) ||
        !GetObjNumberField(env, el, "dtype", 6, dtype)) {
        return false;
    }
    for(const char* field:{"name","value"}){napi_value value;if(GetObjProp(env,el,field,&value)){napi_valuetype kind=napi_undefined;napi_typeof(env,value,&kind);if(kind!=napi_string)return false;}}
    LayoutProperty lp;
    if (!DecodePropertyWire(attr, dtype, GetObjString(env, el, "name", ""),
                            GetObjString(env, el, "value", ""), lp)) {
        return false;
    }
    if (budget + lp.value.size() > kMaxPropTotalBytesWire) {
        throw std::invalid_argument("Property byte budget exceeded");
    }
    budget += lp.value.size();
    out = std::move(lp);
    return true;
}

/**
 * 读一个属性数组（元素为 PropRecord 对象）。
 * 已提供的属性必须完整可保留；非数组、畸形条目和预算超限均拒绝。
 */
static void ReadPropertyArrayList(napi_env env, napi_value arr, std::vector<LayoutProperty>& out,
                                  size_t& budget) {
    bool isArr = false;
    napi_is_array(env, arr, &isArr);
    if (!isArr) {
        throw std::invalid_argument("Property list must be an array");
    }
    uint32_t n = 0;
    napi_get_array_length(env, arr, &n);
    if(n>kMaxPropsPerOwnerWire)throw std::invalid_argument("Property owner budget exceeded");
    for (uint32_t i = 0; i < n; i++) {
        if (out.size() >= kMaxPropsPerOwnerWire) {
            throw std::invalid_argument("Property owner budget exceeded");
        }
        napi_value el = nullptr;
        if (napi_get_element(env, arr, i, &el) != napi_ok || el == nullptr) {
            continue;
        }
        LayoutProperty lp;
        if (!ReadPropertyEntry(env, el, lp, budget)) {
            throw std::invalid_argument("Property record cannot be preserved");
        }
        out.push_back(std::move(lp));
    }
}

/** Optional typed slots can exist as undefined at the ArkTS/NAPI boundary.
 * Missing/undefined means absent; null and every other non-array remain errors. */
static void ReadPropertyArrayField(napi_env env, napi_value parent, const char* field,
                                   std::vector<LayoutProperty>& out, size_t& budget) {
    napi_value arr = nullptr;
    if (!GetObjProp(env, parent, field, &arr)) {
        return;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, arr, &type) != napi_ok) throw std::invalid_argument("Property field is unreadable");
    if (type == napi_undefined) return;
    ReadPropertyArrayList(env, arr, out, budget);
}

/**
 * writeGdsiiDocument(filePath, document)
 * document: {
 *   libName, userUnits, physicalUnits, topCellId,
 *   cellNames: string[],
 *   libProperties?: PropRecord[],                 // 可选：库级属性
 *   cellProperties?: PropRecord[][],              // 可选：与 cellNames 同索引的结构级属性
 *   shapes: [{ type, layerNumber, datatype, ownerCellId, cellId, cellName,
 *              rotation, mirror, magnification, pathWidth, text,
 *              properties?: PropRecord[],          // 可选：元素级属性
 *              points: number[] flat [x0,y0,...] }]
 * }
 * PropRecord = { attr, dtype, name, value }（见上方「线上编解码」；全部字段可选）
 */
static port_codec::Value ReadSemanticObject(napi_env env,napi_value object,size_t& budget){
    napi_value global,json,stringify,encoded;napi_get_global(env,&global);
    if(napi_get_named_property(env,global,"JSON",&json)!=napi_ok||napi_get_named_property(env,json,"stringify",&stringify)!=napi_ok||napi_call_function(env,json,stringify,1,&object,&encoded)!=napi_ok)throw std::invalid_argument("Cannot serialize semantic metadata");
    size_t bytes=0;if(napi_get_value_string_utf8(env,encoded,nullptr,0,&bytes)!=napi_ok||bytes>2u*1024u*1024u||budget+bytes>64u*1024u*1024u)throw std::invalid_argument("Semantic metadata byte budget exceeded");budget+=bytes;
    std::string value(bytes+1,'\0');size_t written=0;if(napi_get_value_string_utf8(env,encoded,&value[0],value.size(),&written)!=napi_ok||written!=bytes)throw std::invalid_argument("Semantic metadata is unreadable");value.resize(bytes);return port_codec::Parser(value,true).finish();
}
// JSON validation is inert and bounded, but JSON.stringify encodes -0 as 0.
// Retain the original finite NAPI number after validating the same numeric value.
// A getter/toJSON changing the value between the two reads is refused.
static double ReadSemanticPortNumber(napi_env env,napi_value object,const char* field,double validated){
    napi_value value=nullptr;napi_valuetype type=napi_undefined;double number=0;
    if(napi_get_named_property(env,object,field,&value)!=napi_ok||
        napi_typeof(env,value,&type)!=napi_ok||type!=napi_number||
        napi_get_value_double(env,value,&number)!=napi_ok||!std::isfinite(number)||number!=validated)
        throw std::invalid_argument("Port numeric field differs from its validated JSON value");
    return number;
}
static LayoutPort ReadSemanticPort(napi_env env,napi_value object,const port_codec::Value& validated){
    LayoutPort port=port_codec::readPort(validated);napi_value center=nullptr;
    if(napi_get_named_property(env,object,"centerNm",&center)!=napi_ok)
        throw std::invalid_argument("Port center is unreadable");
    port.xNm=ReadSemanticPortNumber(env,center,"x",port.xNm);
    port.yNm=ReadSemanticPortNumber(env,center,"y",port.yNm);
    port.orientationDeg=ReadSemanticPortNumber(env,object,"orientationDeg",port.orientationDeg);
    port.widthNm=ReadSemanticPortNumber(env,object,"widthNm",port.widthNm);
    port.frameMagnification=ReadSemanticPortNumber(env,object,"frameMagnification",port.frameMagnification);
    return port;
}
static void ReadSemanticFields(napi_env env,napi_value doc,GdsiiParseResult& layout){
    napi_value keys=nullptr;if(!GetObjProp(env,doc,"cellKeys",&keys)){port_codec::Decode(layout);return;}
    bool array=false;uint32_t n=0;if(napi_is_array(env,keys,&array)!=napi_ok||!array||napi_get_array_length(env,keys,&n)!=napi_ok||n!=layout.cells.size())throw std::invalid_argument("Stable Cell keys must match the complete Cell table");
    for(uint32_t i=0;i<n;++i){ParseResultHandleScope handles(env);napi_value key;napi_get_element(env,keys,i,&key);napi_valuetype type=napi_undefined;napi_typeof(env,key,&type);if(type!=napi_string)throw std::invalid_argument("Cell key must be a string");layout.cellKeys.push_back(ReadStringArg(env,key));}
    size_t budget=0;auto read=[&](const char* field,uint32_t limit,bool ports){napi_value rows=nullptr;if(!GetObjProp(env,doc,field,&rows))return;array=false;n=0;if(napi_is_array(env,rows,&array)!=napi_ok||!array||napi_get_array_length(env,rows,&n)!=napi_ok||n>limit)throw std::invalid_argument("Invalid semantic metadata collection");for(uint32_t i=0;i<n;++i){ParseResultHandleScope handles(env);napi_value row;napi_get_element(env,rows,i,&row);auto value=ReadSemanticObject(env,row,budget);if(ports)layout.ports.push_back(ReadSemanticPort(env,row,value));else layout.crossSections.push_back(port_codec::readSection(value));}};
    read("ports",100000,true);read("crossSections",4096,false);port_codec::Validate(layout);layout.portCapabilityDiagnostics=port_codec::Diagnostics(layout);
}
static GdsiiParseResult ReadLayoutDocumentSnapshot(napi_env env, napi_value doc) {
    // ArkUI observed arrays can be Proxy objects at the NAPI boundary. Read the
    // bounded array-like contract explicitly instead of treating a failed
    // napi_get_array_length as an empty document.
    const auto arrayLength = [&](napi_value value, uint32_t limit, const char* message) {
        uint32_t length = 0;
        if (napi_get_array_length(env, value, &length) != napi_ok) {
            const double raw = GetObjDouble(env, value, "length", -1);
            if (!std::isfinite(raw) || raw < 0 || raw != std::floor(raw) || raw > limit)
                throw std::invalid_argument(message);
            length = static_cast<uint32_t>(raw);
        }
        if (length > limit) throw std::invalid_argument(message);
        return length;
    };
    const auto element = [&](napi_value value, uint32_t index) {
        napi_value item = nullptr;
        if (napi_get_element(env, value, index, &item) != napi_ok &&
            napi_get_named_property(env, value, std::to_string(index).c_str(), &item) != napi_ok)
            throw std::invalid_argument("Document array entry is unreadable");
        return item;
    };
    GdsiiParseResult layout;
    layout.success = true;
    layout.libName = GetObjString(env, doc, "libName", "HONGTU_LIB");
    layout.userUnits = GetObjDouble(env, doc, "userUnits", 0.001);
    layout.physicalUnits = GetObjDouble(env, doc, "physicalUnits", 1e-9);
    layout.primaryTopCellId = GetObjInt(env, doc, "topCellId", 0);

    const auto readInterval = [&](napi_value value) {
        LayerNameInterval interval;
        const double type = GetObjDouble(env, value, "type", -1);
        const double lower = GetObjDouble(env, value, "lower", -1);
        const double upper = GetObjDouble(env, value, "upper", -1);
        if (type < 0 || type > 4 || type != std::floor(type) || !std::isfinite(lower) || !std::isfinite(upper) ||
            lower < 0 || upper > UINT32_MAX || lower > upper || lower != std::floor(lower) || upper != std::floor(upper))
            throw std::invalid_argument("Invalid source layer-name interval");
        interval.type = static_cast<uint32_t>(type); interval.lower = static_cast<uint32_t>(lower); interval.upper = static_cast<uint32_t>(upper);
        if ((interval.type == 0 && (interval.lower != 0 || interval.upper != UINT32_MAX)) ||
            (interval.type == 1 && interval.lower != 0) || (interval.type == 2 && interval.upper != UINT32_MAX) ||
            (interval.type == 3 && interval.lower != interval.upper)) throw std::invalid_argument("Noncanonical source layer-name interval");
        return interval;
    };
    napi_value definitions;
    if (GetObjProp(env, doc, "layerDefinitions", &definitions)) {
        const uint32_t count = arrayLength(definitions, 100000, "Layer definitions exceed budget");
        for (uint32_t index = 0; index < count; ++index) {
            napi_value item = element(definitions, index), layer, datatype;
            SourceLayerDefinition definition;
            definition.name = GetObjString(env, item, "name", "");
            if (definition.name.size() > 65535 || definition.name.find('\0') != std::string::npos) throw std::invalid_argument("Invalid source layer name");
            napi_value textValue;
            if (GetObjProp(env, item, "textLayer", &textValue) && napi_get_value_bool(env, textValue, &definition.textLayer) != napi_ok)
                throw std::invalid_argument("Source layer definition textLayer must be boolean");
            if (!GetObjProp(env, item, "layer", &layer) || !GetObjProp(env, item, "datatype", &datatype))
                throw std::invalid_argument("Source layer definition needs intervals");
            definition.layer = readInterval(layer); definition.datatype = readInterval(datatype);
            layout.layerDefinitions.push_back(std::move(definition));
        }
    }
    napi_value layerList;
    if (GetObjProp(env, doc, "layers", &layerList)) {
        const uint32_t count = arrayLength(layerList, 100000, "Layer list exceeds budget");
        for (uint32_t index = 0; index < count; ++index) {
            napi_value item = element(layerList, index);
            LayerInfo layer;
            layer.layerNumber = GetObjInt(env, item, "layerNumber", -1);
            layer.datatype = GetObjInt(env, item, "datatype", -1);
            layer.sourceName = GetObjString(env, item, "sourceName", "");
            if (layer.layerNumber < 0 || layer.datatype < 0 || layer.sourceName.size() > 65535 || layer.sourceName.find('\0') != std::string::npos)
                throw std::invalid_argument("Invalid source layer metadata");
            layout.allLayers.push_back(std::move(layer));
        }
    }

    // 属性守卫：一次调用共享的总字节预算（旧文档无这些字段 → 全程不触及，行为与今日一致）
    size_t propBudget = 0;
    ReadPropertyArrayField(env, doc, "libProperties", layout.libProperties, propBudget);

    // cellProperties?: PropRecord[][] —— 与 cellNames 同索引的结构级属性（可选）
    napi_value cellPropsVal = nullptr;
    bool hasCellProps = false;
    if (GetObjProp(env, doc, "cellProperties", &cellPropsVal)) {
        napi_valuetype type = napi_undefined;
        if (napi_typeof(env, cellPropsVal, &type) != napi_ok) throw std::invalid_argument("Cell property field is unreadable");
        if (type != napi_undefined && (napi_is_array(env, cellPropsVal, &hasCellProps) != napi_ok || !hasCellProps))
            throw std::invalid_argument("Cell property list must be an array");
    }

    napi_value cellNamesVal;
    if (GetObjProp(env, doc, "cellNames", &cellNamesVal)) {
        const uint32_t n = arrayLength(cellNamesVal, 1000000, "Document cell names exceed supported budget or are unreadable");
        for (uint32_t i = 0; i < n; i++) {
            ParseResultHandleScope handles(env);
            napi_value el = element(cellNamesVal, i);
            CellInfo ci;
            ci.name = ReadStringArg(env, el);
            if (hasCellProps) {
                napi_value group = nullptr;
                if (napi_get_element(env, cellPropsVal, i, &group) == napi_ok && group != nullptr) {
                    ReadPropertyArrayList(env, group, ci.properties, propBudget);
                }
            }
            layout.cells.push_back(ci);
        }
    }
    layout.cellCount = static_cast<int>(layout.cells.size());
    ReadContextFields(env,doc,layout);
    ReadSemanticFields(env,doc,layout);
    if (layout.primaryTopCellId >= 0 &&
        layout.primaryTopCellId < static_cast<int>(layout.cells.size())) {
        layout.topCellIds.push_back(layout.primaryTopCellId);
    }

    const double* docPackedCoords = nullptr;
    size_t docPackedDoubleLen = 0;
    const int32_t* docPointOffsets = nullptr;
    size_t docOffsetsLen = 0;
    const int32_t* docPointCounts = nullptr;
    size_t docCountsLen = 0;
    {
        napi_value packedVal = nullptr, offsetsVal = nullptr, countsVal = nullptr;
        const bool hasPacked = GetObjProp(env, doc, "packedCoords", &packedVal);
        auto readPacked = [&](napi_value value, napi_typedarray_type expectedType,
                              size_t bytesPerValue, void** raw, size_t* count) {
            bool isBuffer = false;
            if (napi_is_arraybuffer(env, value, &isBuffer) == napi_ok && isBuffer) {
                size_t bytes = 0;
                if (napi_get_arraybuffer_info(env, value, raw, &bytes) != napi_ok || bytes % bytesPerValue != 0)
                    return false;
                *count = bytes / bytesPerValue;
                return *raw != nullptr;
            }
            napi_typedarray_type type = napi_int8_array;
            napi_value backing = nullptr;
            size_t byteOffset = 0;
            return napi_get_typedarray_info(env, value, &type, count, raw, &backing, &byteOffset) == napi_ok &&
                type == expectedType && *raw != nullptr;
        };
        if (hasPacked) {
            napi_valuetype packedType = napi_undefined;
            napi_typeof(env, packedVal, &packedType);
            if (packedType != napi_undefined) {
                void* coords = nullptr;
                void* offsets = nullptr;
                void* counts = nullptr;
                if (!GetObjProp(env, doc, "shapePointOffsets", &offsetsVal) ||
                    !GetObjProp(env, doc, "shapePointCounts", &countsVal) ||
                    !readPacked(packedVal, napi_float64_array, sizeof(double), &coords, &docPackedDoubleLen) ||
                    !readPacked(offsetsVal, napi_int32_array, sizeof(int32_t), &offsets, &docOffsetsLen) ||
                    !readPacked(countsVal, napi_int32_array, sizeof(int32_t), &counts, &docCountsLen)) {
                    throw std::invalid_argument("Document packed coordinates are invalid");
                }
                docPackedCoords = static_cast<const double*>(coords);
                docPointOffsets = static_cast<const int32_t*>(offsets);
                docPointCounts = static_cast<const int32_t*>(counts);
            }
        }
    }

    napi_value shapesVal;
    if (GetObjProp(env, doc, "shapes", &shapesVal)) {
        const uint32_t n = arrayLength(shapesVal, 2000000, "Document shapes exceed supported budget or are unreadable");
        const bool hasDocPacked = docPackedCoords != nullptr;
        if (hasDocPacked && (docOffsetsLen != n || docCountsLen != n))
            throw std::invalid_argument("Document packed coordinate index does not match shape count");
        for (uint32_t i = 0; i < n; i++) {
            ParseResultHandleScope handles(env);
            napi_value sObj = element(shapesVal, i);
            LayoutShape ls;
            ls.id = GetObjInt(env, sObj, "id", static_cast<int>(i + 1));
            ls.type = GetObjString(env, sObj, "type", "polygon");
            ls.layerNumber = GetObjInt(env, sObj, "layerNumber", 0);
            ls.datatype = GetObjInt(env, sObj, "datatype", 0);
            ls.ownerCellId = GetObjInt(env, sObj, "ownerCellId", layout.primaryTopCellId);
            ls.cellId = GetObjInt(env, sObj, "cellId", -1);
            ls.cellName = GetObjString(env, sObj, "cellName", "");
            ls.rotation = GetObjDouble(env, sObj, "rotation", 0);
            ls.mirror = GetObjInt(env, sObj, "mirror", 0);
            ls.magnification = GetObjDouble(env, sObj, "magnification", 1.0);
            ls.pathWidth = GetObjDouble(env, sObj, "pathWidth", 1.0);
            // 端型必须由 ArkTS 侧带上来：ArkTS 的 Shape 是保存时的唯一真相，
            // 不读这个键则 round/extended 端一律塌成 0(flush)，两端各短 pathWidth/2
            ls.pathType = GetObjInt(env, sObj, "pathType", ls.pathType);
            ls.pathBeginExtension = GetObjDouble(env, sObj, "pathBeginExtension", 0);
            ls.pathEndExtension = GetObjDouble(env, sObj, "pathEndExtension", 0);
            napi_value absoluteWidthValue;
            if (GetObjProp(env, sObj, "pathWidthAbsolute", &absoluteWidthValue)) {
                napi_get_value_bool(env, absoluteWidthValue, &ls.pathWidthAbsolute);
            }
            ls.arrayCols = GetObjInt(env, sObj, "arrayCols", 0);
            ls.arrayRows = GetObjInt(env, sObj, "arrayRows", 0);
            ls.arrayColStepX = GetObjDouble(env, sObj, "arrayColStepX", 0);
            ls.arrayColStepY = GetObjDouble(env, sObj, "arrayColStepY", 0);
            ls.arrayRowStepX = GetObjDouble(env, sObj, "arrayRowStepX", 0);
            ls.arrayRowStepY = GetObjDouble(env, sObj, "arrayRowStepY", 0);
            ls.text = GetObjString(env, sObj, "text", "");
            ls.textPresentation = GetObjInt(env, sObj, "textPresentation", 0);
            // 元素级属性（可选字段：省略 → 与今日一致，写出端不产生属性记录）
            ReadPropertyArrayField(env, sObj, "properties", ls.properties, propBudget);
            napi_value ptsVal;
            if (hasDocPacked) {
                const int32_t ptOffset = docPointOffsets[i];
                const int32_t ptCount = docPointCounts[i];
                if (ptOffset < 0 || ptCount < 0 ||
                    (static_cast<uint64_t>(ptOffset) + static_cast<uint64_t>(ptCount)) * 2ULL > docPackedDoubleLen) {
                    throw std::invalid_argument("Document packed coordinate slice is out of bounds");
                }
                ls.points.reserve(static_cast<size_t>(ptCount));
                const double* src = docPackedCoords + static_cast<size_t>(ptOffset) * 2;
                for (int32_t k = 0; k < ptCount; ++k) {
                    const double x = src[static_cast<size_t>(k) * 2];
                    const double y = src[static_cast<size_t>(k) * 2 + 1];
                    if (!std::isfinite(x) || !std::isfinite(y)) throw std::invalid_argument("Document point must be finite");
                    ls.points.push_back({x, y});
                }
            } else if (GetObjProp(env, sObj, "points", &ptsVal)) {
                const uint32_t pn = arrayLength(ptsVal, 16000000, "Document point array exceeds supported budget or is unreadable");
                napi_value first = nullptr;
                napi_valuetype pointType = napi_undefined;
                if (pn > 0) {
                    first = element(ptsVal, 0);
                    napi_typeof(env, first, &pointType);
                }
                if (pointType == napi_object) {
                    ls.points.reserve(pn);
                    for (uint32_t k = 0; k < pn; ++k) {
                        ParseResultHandleScope pointHandles(env);
                        napi_value point = element(ptsVal, k);
                        const double x = GetObjDouble(env, point, "x", std::numeric_limits<double>::quiet_NaN());
                        const double y = GetObjDouble(env, point, "y", std::numeric_limits<double>::quiet_NaN());
                        if (!std::isfinite(x) || !std::isfinite(y)) throw std::invalid_argument("Document point must be finite");
                        ls.points.push_back({x, y});
                    }
                } else {
                    if ((pn % 2) != 0) throw std::invalid_argument("Document point array must contain XY pairs");
                    ls.points.reserve(pn / 2);
                    for (uint32_t k = 0; k + 1 < pn; k += 2) {
                        ParseResultHandleScope pointHandles(env);
                        napi_value xv = element(ptsVal, k), yv = element(ptsVal, k + 1);
                        double x = 0, y = 0;
                        if (napi_get_value_double(env, xv, &x) != napi_ok || napi_get_value_double(env, yv, &y) != napi_ok ||
                            !std::isfinite(x) || !std::isfinite(y)) throw std::invalid_argument("Document point must be finite");
                        ls.points.push_back({x, y});
                    }
                }
            }
            if (ls.points.empty()) throw std::invalid_argument("Document shape has no coordinates");
            layout.shapes.push_back(std::move(ls));
        }
    }
    layout.totalElements = static_cast<int>(layout.shapes.size());
    for (const auto& shape : layout.shapes) {
        if (shape.type == "instance") continue;
        auto layer = std::find_if(layout.allLayers.begin(), layout.allLayers.end(), [&](const LayerInfo& info) {
            return info.layerNumber == shape.layerNumber && info.datatype == shape.datatype;
        });
        if (layer == layout.allLayers.end()) layout.allLayers.push_back({shape.layerNumber, shape.datatype, 1});
        else ++layer->elementCount;
    }
    port_codec::ResolvePortLayers(layout);
    layout.layerCount = static_cast<int>(layout.allLayers.size());
    // Resolve name-only references before evaluating nested-array import budgets.
    // The renderer must not discover additional child geometry after validation.
    std::unordered_map<std::string, int> cellsByName;
    for (size_t index = 0; index < layout.cells.size(); ++index)
        cellsByName[layout.cells[index].name] = static_cast<int>(index);
    for (auto& shape : layout.shapes) {
        if (shape.type != "instance" || shape.cellId >= 0) continue;
        const auto found = cellsByName.find(shape.cellName);
        if (found != cellsByName.end()) shape.cellId = found->second;
    }
    return layout;
}

static napi_value NapiWriteGdsiiDocument(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "writeGdsiiDocument expects filePath, document");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    napi_value doc = args[1];

    auto layout = ReadLayoutDocumentSnapshot(env, doc);


    // 先写文件；仅成功后再 commit g_layout，避免写失败污染 native 快照
    GdsiiWriteResult wr;
    try {
        ValidateInteractiveImportBudget(layout);
        wr = WriteGdsii(layout, path);
        if (wr.success) {
            std::lock_guard<std::mutex> lock(g_layoutMutex);
            PopulateLayoutFromParseResult(layout);
        }
    } catch (const std::exception& error) {
        wr.success = false;
        wr.errorMessage = error.what();
    }

    napi_value obj;
    napi_create_object(env, &obj);
    napi_set_named_property(env, obj, "success", CreateBool(env, wr.success));
    napi_set_named_property(env, obj, "errorMessage", CreateString(env, wr.errorMessage));
    napi_set_named_property(env, obj, "writtenCells", CreateInt(env, wr.writtenCells));
    napi_set_named_property(env, obj, "writtenShapes", CreateInt(env, wr.writtenShapes));
    napi_set_named_property(env, obj, "skippedShapes", CreateInt(env, wr.skippedShapes));
    napi_set_named_property(env, obj, "bytes", CreateInt64(env, static_cast<int64_t>(wr.bytes)));
    SetProp(env, obj, "quantization", CreateQuantization(env, wr.quantization));
    return obj;
}

// ==================== Sync parse + hierarchy expand ====================

static napi_value NapiParseGdsii(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "parseGdsii expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    GdsiiReader reader;
    auto result = reader.parse(path);
    return CreateAndCommitParseResult(env, result);
}

/** parseCif(filePath) — CIF 文本格式解析（成功后填充 g_layout） */
static napi_value NapiParseCif(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "parseCif expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    CifReader reader;
    auto result = reader.parse(path);
    return CreateAndCommitParseResult(env, result);
}

/** parseDxf(filePath) — DXF R12 ASCII 子集解析（成功后填充 g_layout） */
static napi_value NapiParseDxf(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "parseDxf expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    DxfReader reader;
    auto result = reader.parse(path);
    return CreateAndCommitParseResult(env, result);
}

static napi_value NapiQuickInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "quickInfo expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    GdsiiReader reader;
    return CreateFullParseResult(env, reader.quickInfo(path));
}

static napi_value NapiParseOasis(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "parseOasis expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    OasisReader reader;
    auto result = reader.parse(path);
    return CreateAndCommitParseResult(env, result);
}

static napi_value NapiQuickOasisInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "quickOasisInfo expects filePath");
        return nullptr;
    }
    std::string path = ReadStringArg(env, args[0]);
    OasisReader reader;
    return CreateFullParseResult(env, reader.quickInfo(path));
}

/**
 * expandHierarchy(cellId, hierarchyDepth) → NativeShape[]
 * KLayout-style: depth=1 local only; depth=N expands N-1 instance levels with transforms.
 */
static napi_value NapiExpandHierarchy(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int cellId = argc > 0 ? ReadIntArg(env, args[0]) : 0;
    int hierarchyDepth = argc > 1 ? ReadIntArg(env, args[1]) : 2;
    if (hierarchyDepth < 1) hierarchyDepth = 1;
    if (hierarchyDepth > 32) hierarchyDepth = 32;

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    napi_value arr;
    napi_create_array(env, &arr);
    if (!g_layout) {
        return arr;
    }

    struct Expanded {
        SceneShape shape;
        GeometryEngine::Transform2D xf;
    };
    std::vector<Expanded> expanded;
    g_layout->flattenHierarchy(cellId, hierarchyDepth,
        [&](const SceneShape& shape, const GeometryEngine::Transform2D& xf) {
            expanded.push_back({shape, xf});
        });

    // 合成 id 起点与 ArkTS HierarchyExpandService.EXPANDED_SHAPE_ID_BASE 对齐，避免与真实 shape.id 冲突
    constexpr int64_t kExpandedIdBase = 1000000000LL;
    napi_create_array_with_length(env, expanded.size(), &arr);
    for (size_t i = 0; i < expanded.size(); i++) {
        const auto& e = expanded[i];
        std::vector<Vec2> localPts = e.shape.points;
        // RECT 存对角两点：先展成 4 角再变换，避免非单位变换后仍当轴对齐 rect
        if ((e.shape.type == ShapeType::RECT || e.shape.type == ShapeType::BOX) &&
            e.shape.points.size() == 2) {
            const auto& a = e.shape.points[0];
            const auto& b = e.shape.points[1];
            localPts = {{a.x, a.y}, {b.x, a.y}, {b.x, b.y}, {a.x, b.y}};
        }
        auto pts = e.xf.applyToPolygon(localPts);
        const bool isIdentity =
            std::fabs(e.xf.a - 1.0) < 1e-12 && std::fabs(e.xf.b) < 1e-12 &&
            std::fabs(e.xf.c) < 1e-12 && std::fabs(e.xf.d - 1.0) < 1e-12 &&
            std::fabs(e.xf.tx) < 1e-12 && std::fabs(e.xf.ty) < 1e-12;
        // 当前 Cell 本地图形保留源 id；变换后的展开几何用合成 id
        const int64_t outId = isIdentity ? e.shape.id : (kExpandedIdBase + static_cast<int64_t>(i));

        napi_value shapeObj;
        napi_create_object(env, &shapeObj);
        SetProp(env, shapeObj, "id", CreateInt64(env, outId));
        const char* typeName = "polygon";
        switch (e.shape.type) {
            case ShapeType::RECT:
            case ShapeType::BOX:
                // 非单位变换后 4 点不再保证轴对齐，一律 polygon
                typeName = isIdentity ? "rect" : "polygon";
                break;
            case ShapeType::POLYGON: typeName = "polygon"; break;
            case ShapeType::PATH: typeName = "path"; break;
            case ShapeType::TEXT: typeName = "text"; break;
            case ShapeType::INSTANCE: typeName = "instance"; break;
            case ShapeType::NODE: typeName = "node"; break;
            default: break;
        }
        SetProp(env, shapeObj, "type", CreateString(env, typeName));
        SetProp(env, shapeObj, "layerNumber", CreateInt(env, e.shape.layerKey.layer));
        SetProp(env, shapeObj, "datatype", CreateInt(env, e.shape.layerKey.datatype));
        // pathWidth 随均匀缩放近似
        double pathWidth = e.shape.pathWidth;
        if (pathWidth > 0 && !isIdentity && !e.shape.pathWidthAbsolute) {
            const double det = e.xf.determinant();
            pathWidth = std::max(0.1, pathWidth * std::sqrt(std::fabs(det)));
        }
        SetProp(env, shapeObj, "pathWidth", CreateDouble(env, pathWidth));
        const double pathScale = std::sqrt(std::fabs(e.xf.determinant()));
        SetProp(env, shapeObj, "pathType", CreateInt(env, e.shape.pathType));
        SetProp(env, shapeObj, "pathBeginExtension", CreateDouble(env, e.shape.pathBeginExtension * pathScale));
        SetProp(env, shapeObj, "pathEndExtension", CreateDouble(env, e.shape.pathEndExtension * pathScale));
        SetProp(env, shapeObj, "pathWidthAbsolute", CreateBool(env, e.shape.pathWidthAbsolute));
        SetProp(env, shapeObj, "text", CreateString(env, e.shape.text));
        SetProp(env, shapeObj, "cellName", CreateString(env, ""));
        SetProp(env, shapeObj, "ownerCellId", CreateInt(env, cellId));
        SetProp(env, shapeObj, "cellId", CreateInt(env, -1));
        SetProp(env, shapeObj, "rotation", CreateDouble(env, 0));
        SetProp(env, shapeObj, "mirror", CreateInt(env, 0));
        SetProp(env, shapeObj, "magnification", CreateDouble(env, 1.0));

        // 单位变换下的 rect 仍可回传对角两点
        if (isIdentity && (e.shape.type == ShapeType::RECT || e.shape.type == ShapeType::BOX) &&
            e.shape.points.size() == 2) {
            pts = e.shape.points;
        }

        napi_value points;
        napi_create_array_with_length(env, pts.size(), &points);
        for (size_t j = 0; j < pts.size(); j++) {
            napi_value pt;
            napi_create_object(env, &pt);
            SetProp(env, pt, "x", CreateDouble(env, pts[j].x));
            SetProp(env, pt, "y", CreateDouble(env, pts[j].y));
            napi_set_element(env, points, j, pt);
        }
        SetProp(env, shapeObj, "points", points);
        napi_set_element(env, arr, i, shapeObj);
    }
    return arr;
}

/**
 * expandHierarchyToBatches(cellId, hierarchyDepth, minX, minY, maxX, maxY) → RenderBatch-like objects
 * Flattens hierarchy, applies viewport cull, emits flat vertices ready for setRenderData.
 * Optional viewport: pass minX>maxX to disable culling.
 */
static napi_value NapiExpandHierarchyToBatches(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    const int cellId = argc > 0 ? ReadIntArg(env, args[0]) : 0;
    const int depth = std::max(1, std::min(32, argc > 1 ? ReadIntArg(env, args[1]) : 2));
    BBox viewport;
    bool useViewport = false;
    if (argc >= 6) {
        viewport = BBox(ReadDoubleArg(env, args[2]), ReadDoubleArg(env, args[3]),
                        ReadDoubleArg(env, args[4]), ReadDoubleArg(env, args[5]));
        useViewport = viewport.valid() && std::isfinite(viewport.minX) && std::isfinite(viewport.minY) &&
            std::isfinite(viewport.maxX) && std::isfinite(viewport.maxY);
    }
    HierarchyRenderOrigin batchOrigin{0.0, 0.0};
    if (useViewport) {
        batchOrigin.x = 0.5 * viewport.minX + 0.5 * viewport.maxX;
        batchOrigin.y = 0.5 * viewport.minY + 0.5 * viewport.maxY;
    }
    const bool highPrecisionCoords = std::abs(batchOrigin.x) > 65536.0 || std::abs(batchOrigin.y) > 65536.0;
    std::vector<RenderBatch> batches;
    {
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        if (g_layout) {
            batches = BuildHierarchyRenderBatches(
                *g_layout, cellId, depth, useViewport ? &viewport : nullptr,
                nullptr, nullptr, nullptr, useViewport ? &batchOrigin : nullptr);
        }
    }
    napi_value arr;
    napi_create_array_with_length(env, batches.size(), &arr);
    for (size_t i = 0; i < batches.size(); ++i) {
        const auto& batch = batches[i];
        napi_value object, color, vertices;
        napi_create_object(env, &object);
        SetProp(env, object, "type", CreateString(env, HierarchyPrimitiveName(batch.type)));
        SetProp(env, object, "layerNumber", CreateInt(env, batch.layerNumber));
        SetProp(env, object, "datatype", CreateInt(env, batch.datatype));
        SetProp(env, object, "selected", CreateBool(env, batch.selected));
        napi_create_array_with_length(env, 4, &color);
        for (size_t channel = 0; channel < 4; ++channel)
            napi_set_element(env, color, channel, CreateDouble(env, batch.color[channel]));
        SetProp(env, object, "color", color);
        const size_t floatCount = batch.vertices.size() * 2;
        const size_t byteLength = batch.vertices.size() * sizeof(GLVertex);
        void* bufferData = nullptr;
        napi_value arrayBuffer = nullptr;
        if (!highPrecisionCoords &&
            napi_create_arraybuffer(env, byteLength, &bufferData, &arrayBuffer) == napi_ok &&
            napi_create_typedarray(env, napi_float32_array, floatCount, arrayBuffer, 0, &vertices) == napi_ok) {
            if (byteLength > 0 && bufferData != nullptr) {
                std::memcpy(bufferData, batch.vertices.data(), byteLength);
            }
        } else {
            napi_create_array_with_length(env, floatCount, &vertices);
            for (size_t vertex = 0; vertex < batch.vertices.size(); ++vertex) {
                napi_set_element(env, vertices, vertex * 2,
                    CreateDouble(env, static_cast<double>(batch.vertices[vertex].x) + batchOrigin.x));
                napi_set_element(env, vertices, vertex * 2 + 1,
                    CreateDouble(env, static_cast<double>(batch.vertices[vertex].y) + batchOrigin.y));
            }
        }
        SetProp(env, object, "vertices", vertices);
        SetProp(env, object, "fillPattern", CreateInt(env, batch.fillPattern));
        napi_set_element(env, arr, i, object);
    }
    return arr;
}

static double ReadHierarchyRenderNumber(napi_env env, napi_value value, const char* field) {
    double number = 0;
    if (!value || napi_get_value_double(env, value, &number) != napi_ok || !std::isfinite(number))
        throw std::invalid_argument(std::string("renderHierarchyToSurface requires finite ") + field);
    return number;
}

static napi_value ReadHierarchyRenderField(napi_env env, napi_value object, const char* field) {
    napi_value value = nullptr;
    if (!object || napi_get_named_property(env, object, field, &value) != napi_ok || !value)
        throw std::invalid_argument(std::string("renderHierarchyToSurface missing style field ") + field);
    return value;
}

static HierarchyLayerStyles ReadHierarchyRenderStyles(napi_env env, napi_value array) {
    bool isArray = false;
    uint32_t count = 0;
    if (napi_is_array(env, array, &isArray) != napi_ok || !isArray ||
        napi_get_array_length(env, array, &count) != napi_ok || count > 1000000)
        throw std::invalid_argument("renderHierarchyToSurface requires a bounded layer style array");
    HierarchyLayerStyles styles;
    styles.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        napi_value item = nullptr;
        if (napi_get_element(env, array, index, &item) != napi_ok)
            throw std::invalid_argument("renderHierarchyToSurface invalid layer style");
        const double layer = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "layerNumber"), "layerNumber");
        const double datatype = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "datatype"), "datatype");
        if (layer < 0 || layer > 32767 || layer != std::floor(layer) ||
            datatype < 0 || datatype > 32767 || datatype != std::floor(datatype))
            throw std::invalid_argument("renderHierarchyToSurface layer/datatype must be integers in 0..32767");
        HierarchyLayerStyle style;
        if (napi_get_value_bool(env, ReadHierarchyRenderField(env, item, "visible"), &style.visible) != napi_ok ||
            napi_get_value_bool(env, ReadHierarchyRenderField(env, item, "strokeOnly"), &style.strokeOnly) != napi_ok)
            throw std::invalid_argument("renderHierarchyToSurface visibility/strokeOnly must be boolean");
        napi_value fpValue = nullptr;
        if (napi_get_named_property(env, item, "fillPattern", &fpValue) == napi_ok && fpValue != nullptr) {
            napi_valuetype fpType = napi_undefined;
            if (napi_typeof(env, fpValue, &fpType) == napi_ok && fpType != napi_undefined && fpType != napi_null) {
                const double fpNum = ReadHierarchyRenderNumber(env, fpValue, "fillPattern");
                if (fpNum < 0 || fpNum > 3 || fpNum != std::floor(fpNum))
                    throw std::invalid_argument("renderHierarchyToSurface fillPattern must be an integer in 0..3");
                style.fillPattern = static_cast<int>(fpNum);
            }
        }
        napi_value color = ReadHierarchyRenderField(env, item, "color");
        bool colorArray = false;
        uint32_t channels = 0;
        if (napi_is_array(env, color, &colorArray) != napi_ok || !colorArray ||
            napi_get_array_length(env, color, &channels) != napi_ok || channels != 4)
            throw std::invalid_argument("renderHierarchyToSurface color must contain 4 channels");
        for (uint32_t channel = 0; channel < 4; ++channel) {
            napi_value value = nullptr;
            if (napi_get_element(env, color, channel, &value) != napi_ok)
                throw std::invalid_argument("renderHierarchyToSurface invalid color channel");
            const double number = ReadHierarchyRenderNumber(env, value, "color channel");
            if (number < 0 || number > 1) throw std::invalid_argument("renderHierarchyToSurface color must be in 0..1");
            style.color[channel] = static_cast<float>(number);
        }
        styles[{static_cast<int16_t>(layer), static_cast<int16_t>(datatype)}] = style;
    }
    return styles;
}

/** Direct C++ geometry → existing surface; no coordinate arrays cross the JS bridge.
 * Returns false only when no usable document/cell/surface exists. A valid empty or
 * all-hidden view submits an empty batch vector, clears the surface and returns true.
 */
static napi_value NapiRenderHierarchyToSurface(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8] = {};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 7) throw std::invalid_argument("renderHierarchyToSurface expects cell, depth, viewport and styles");
    const double cell = ReadHierarchyRenderNumber(env, args[0], "cellId");
    const double requestedDepth = ReadHierarchyRenderNumber(env, args[1], "depth");
    if (cell < 0 || cell > std::numeric_limits<int>::max() || cell != std::floor(cell) ||
        requestedDepth != std::floor(requestedDepth))
        throw std::invalid_argument("renderHierarchyToSurface cell and depth must be integers");
    const int depth = static_cast<int>(std::max(1.0, std::min(32.0, requestedDepth)));
    const BBox viewport(ReadHierarchyRenderNumber(env, args[2], "minX"), ReadHierarchyRenderNumber(env, args[3], "minY"),
                        ReadHierarchyRenderNumber(env, args[4], "maxX"), ReadHierarchyRenderNumber(env, args[5], "maxY"));
    if (!viewport.valid()) throw std::invalid_argument("renderHierarchyToSurface requires an ordered viewport");
    const auto styles = ReadHierarchyRenderStyles(env, args[6]);
    auto& plugin = XComponentPlugin::getInstance();
    {
        std::lock_guard<std::mutex> lock(plugin.getMutex());
        if (!plugin.isReadyLocked()) return CreateBool(env, false);
    }
    const HierarchyRenderOrigin origin{
        0.5 * viewport.minX + 0.5 * viewport.maxX,
        0.5 * viewport.minY + 0.5 * viewport.maxY
    };
    std::vector<RenderBatch> batches;
    napi_valuetype snapshotType = napi_undefined;
    if (argc >= 8 && args[7]) napi_typeof(env, args[7], &snapshotType);
    if (snapshotType != napi_undefined && snapshotType != napi_null) {
        if (snapshotType != napi_object) throw std::invalid_argument("Render snapshot must be a document object");
        auto snapshot = ReadLayoutDocumentSnapshot(env, args[7]);
        for (const auto& shape : snapshot.shapes) {
            if (shape.ownerCellId < 0 || shape.ownerCellId >= static_cast<int>(snapshot.cells.size()))
                throw std::invalid_argument("Render snapshot contains an invalid ownerCellId");
            if (shape.type == "instance" && (shape.cellId < 0 || shape.cellId >= static_cast<int>(snapshot.cells.size())))
                throw std::invalid_argument("Render snapshot contains an unresolved Cell reference");
        }
        auto temporaryLayout = BuildSceneLayoutFromParseResult(snapshot, nullptr, Layout::SpatialIndexBuild::Deferred);
        if (!temporaryLayout->findCell(static_cast<int>(cell))) return CreateBool(env, false);
        batches = BuildHierarchyRenderBatches(*temporaryLayout, static_cast<int>(cell), depth, &viewport, &styles,
                                              nullptr, nullptr, &origin);
    } else {
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        if (!g_layout || !g_layout->findCell(static_cast<int>(cell))) return CreateBool(env, false);
        batches = BuildHierarchyRenderBatches(*g_layout, static_cast<int>(cell), depth, &viewport, &styles,
                                              nullptr, nullptr, &origin);
    }
    // Never hold the document and surface mutexes simultaneously. The submission
    // helper rechecks readiness in case the surface was destroyed during traversal.
    return CreateBool(env, plugin.submitHierarchyRenderData(batches, origin.x, origin.y));
}

static ReadonlySceneMetadata ReadReadonlySceneMetadata(napi_env env, napi_value document) {
    ReadonlySceneMetadata metadata;
    metadata.libName = GetObjString(env, document, "libName", "HONGTU_LIB");
    metadata.physicalUnits = GetObjDouble(env, document, "physicalUnits", 1e-9);
    metadata.userUnits = GetObjDouble(env, document, "userUnits", .001);
    metadata.topCellId = GetObjInt(env, document, "topCellId", 0);
    if (!std::isfinite(metadata.physicalUnits) || !std::isfinite(metadata.userUnits) ||
        metadata.physicalUnits <= 0 || metadata.userUnits <= 0 || metadata.libName.size() > 65535)
        throw std::invalid_argument("Composite source has invalid document metadata");
    napi_value names = ReadHierarchyRenderField(env, document, "cellNames");
    uint32_t count = 0;
    if (napi_get_array_length(env, names, &count) != napi_ok) {
        const double length = GetObjDouble(env, names, "length", -1);
        if (!std::isfinite(length) || length < 0 || length > 1000000 || length != std::floor(length))
            throw std::invalid_argument("Composite source has an unreadable Cell table");
        count = static_cast<uint32_t>(length);
    }
    if (count > 1000000) throw std::length_error("Composite Cell table exceeds budget");
    metadata.cells.reserve(count);
    for (uint32_t index = 0; index < count; ++index) {
        ParseResultHandleScope handles(env);
        napi_value value = nullptr;
        if (napi_get_element(env, names, index, &value) != napi_ok &&
            napi_get_named_property(env, names, std::to_string(index).c_str(), &value) != napi_ok)
            throw std::invalid_argument("Composite Cell table entry is unreadable");
        napi_valuetype type = napi_undefined; napi_typeof(env, value, &type);
        if (type != napi_string) throw std::invalid_argument("Composite Cell name must be a string");
        auto name = ReadStringArg(env, value);
        if (name.empty() || name.size() > 65535 || name.find('\0') != std::string::npos)
            throw std::invalid_argument("Composite Cell name must be bounded and nonempty");
        metadata.cells.push_back(std::move(name));
    }
    return metadata;
}

/** Complete scene submission. All source layouts are cached immutable checkpoints;
 * g_layout, g_lastParseResult and the editor's spatial/history state are untouched.
 * Cache keys include retained geometry-array identity, checkpoint revision and
 * independently read Cell/metadata values; display cache includes the whole scene.
 */
static napi_value NapiClearRenderScene(napi_env env, napi_callback_info info) {
    // Cache ownership is independent of EGL readiness. Clear it first so TEXT,
    // preparation failures and a destroyed surface cannot pin closed sources.
    const auto existing = ReadonlySceneCaches().find(env);
    if (existing != ReadonlySceneCaches().end()) existing->second->clear();
    return CreateBool(env, XComponentPlugin::getInstance().clearRenderScene());
}

static napi_value NapiRenderSceneToSurface(napi_env env, napi_callback_info info) {
    auto& plugin = XComponentPlugin::getInstance();
    ReadonlySceneCache* sceneCache = nullptr;
    try {
        size_t argc = 5;
        napi_value args[5] = {};
        napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
        if (argc != 5) throw std::invalid_argument("renderSceneToSurface expects sources and viewport");
        const BBox viewport(ReadHierarchyRenderNumber(env, args[1], "minX"), ReadHierarchyRenderNumber(env, args[2], "minY"),
                            ReadHierarchyRenderNumber(env, args[3], "maxX"), ReadHierarchyRenderNumber(env, args[4], "maxY"));
        if (!viewport.valid()) throw std::invalid_argument("renderSceneToSurface requires an ordered viewport");
        bool isArray = false;
        uint32_t count = 0;
        if (napi_is_array(env, args[0], &isArray) != napi_ok || !isArray ||
            napi_get_array_length(env, args[0], &count) != napi_ok || count > 65)
            throw std::invalid_argument("renderSceneToSurface requires at most 65 sources including the active document");
        {
            std::lock_guard<std::mutex> lock(plugin.getMutex());
            if (!plugin.isReadyLocked()) return CreateBool(env, false);
        }
        std::unordered_map<std::string, bool> identities;
        sceneCache = &GetReadonlySceneCache(env);
        struct Request {
            std::shared_ptr<Layout> layout;
            HierarchyRenderSource source;
            HierarchyLayerStyles styles;
            int cell = 0, depth = 1;
        };
        std::vector<Request> requests;
        requests.reserve(count);
        std::ostringstream fingerprint;
        fingerprint << std::hexfloat << viewport.minX << ':' << viewport.minY << ':' << viewport.maxX << ':' << viewport.maxY << ';';
        uint64_t storedShapes = 0, storedCoordinates = 0, expandedObjects = 0;
        for (uint32_t index = 0; index < count; ++index) {
            ParseResultHandleScope handles(env);
            napi_value item = nullptr;
            if (napi_get_element(env, args[0], index, &item) != napi_ok)
                throw std::invalid_argument("renderSceneToSurface source is unreadable");
            napi_valuetype type = napi_undefined;
            napi_value identity = ReadHierarchyRenderField(env, item, "sourceId");
            napi_typeof(env, identity, &type);
            if (type != napi_string) throw std::invalid_argument("Composite sourceId must be a string");
            const std::string id = ReadStringArg(env, identity);
            if (id.empty() || id.size() > 4096 || id.find('\0') != std::string::npos || !identities.emplace(id, true).second)
                throw std::invalid_argument("Composite sourceId must be bounded, nonempty and unique");
            const double revision = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "revision"), "revision");
            const double cell = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "cellId"), "cellId");
            const double depth = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "depth"), "depth");
            if (revision < 0 || revision > 9007199254740991.0 || revision != std::floor(revision) ||
                cell < 0 || cell > std::numeric_limits<int>::max() || cell != std::floor(cell) ||
                depth < 1 || depth > 32 || depth != std::floor(depth))
                throw std::invalid_argument("Composite source revision/cell/depth must be supported integers");
            HierarchyRenderSource source;
            source.sourceOrder = static_cast<int>(index);
            source.opacity = ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, item, "opacity"), "opacity");
            napi_value matrix = ReadHierarchyRenderField(env, item, "transform");
            auto component = [&](const char* name) { return ReadHierarchyRenderNumber(env, ReadHierarchyRenderField(env, matrix, name), name); };
            source.transform.a = component("a"); source.transform.b = component("b");
            source.transform.c = component("c"); source.transform.d = component("d");
            source.transform.tx = component("tx"); source.transform.ty = component("ty");
            ValidateHierarchyRenderSource(source);
            const auto styles = ReadHierarchyRenderStyles(env, ReadHierarchyRenderField(env, item, "styles"));
            napi_value document = ReadHierarchyRenderField(env, item, "snapshot");
            napi_typeof(env, document, &type);
            if (type != napi_object) throw std::invalid_argument("Composite snapshot must be a document object");
            napi_value shapes = ReadHierarchyRenderField(env, document, "shapes");
            const auto metadata = ReadReadonlySceneMetadata(env, document);
            auto* cached = sceneCache->find(id, revision, shapes, metadata);
            if (!cached) {
            auto snapshot = ReadLayoutDocumentSnapshot(env, document);
            for (const auto& shape : snapshot.shapes) {
                if (shape.ownerCellId < 0 || shape.ownerCellId >= static_cast<int>(snapshot.cells.size()) ||
                    (shape.type == "instance" && (shape.cellId < 0 || shape.cellId >= static_cast<int>(snapshot.cells.size()))))
                    throw std::invalid_argument("Composite snapshot contains an invalid owner or unresolved Cell");
                if (shape.layerNumber < 0 || shape.layerNumber > 32767 || shape.datatype < 0 || shape.datatype > 32767)
                    throw std::invalid_argument("Composite snapshot layer/datatype out of range");
                for (double value : {shape.rotation, shape.magnification, shape.pathWidth, shape.pathBeginExtension,
                        shape.pathEndExtension, shape.arrayColStepX, shape.arrayColStepY, shape.arrayRowStepX, shape.arrayRowStepY})
                    if (!std::isfinite(value)) throw std::invalid_argument("Composite snapshot has non-finite geometry parameters");
                if (shape.type != "rect" && shape.type != "polygon" && shape.type != "path" &&
                    shape.type != "text" && shape.type != "instance" && shape.type != "node")
                    throw std::invalid_argument("Composite snapshot contains an unsupported primitive");
                if (shape.magnification <= 0 || shape.mirror < 0 || shape.mirror > 2 ||
                    shape.arrayCols < 0 || shape.arrayRows < 0)
                    throw std::invalid_argument("Composite snapshot contains invalid instance parameters");
            }
            const auto estimate = EstimateInteractiveImport(snapshot);
            if (!estimate.withinBudget) throw std::length_error("Composite source exceeds stored/expanded geometry budget");
            auto layout = BuildSceneLayoutFromParseResult(snapshot, nullptr, Layout::SpatialIndexBuild::Deferred);
            cached = &sceneCache->store(id, revision, shapes, metadata, std::move(layout), estimate);
            }
            storedShapes += cached->estimate.storedShapes; storedCoordinates += cached->estimate.coordinates;
            expandedObjects += cached->estimate.expandedObjects;
            if (storedShapes > kMaxInteractiveStoredShapes ||
                storedCoordinates > kMaxInteractiveCoordinates ||
                expandedObjects > kMaxInteractiveExpandedObjects)
                throw std::length_error("Composite scene exceeds aggregate stored/expanded geometry budget (2000000 shapes / 25000000 coordinates / 10000000 expanded objects)");
            if (!cached->layout->findCell(static_cast<int>(cell))) throw std::invalid_argument("Composite source Cell no longer exists");
            AppendReadonlySceneFingerprint(fingerprint, id, *cached, static_cast<int>(cell), static_cast<int>(depth), source, styles);
            requests.push_back({cached->layout, source, styles, static_cast<int>(cell), static_cast<int>(depth)});
        }
        const auto key = fingerprint.str();
        sceneCache->prune(identities);
        if (sceneCache->sceneFingerprint == key) {
            ++sceneCache->sceneHits;
            uint64_t appliedPublication = 0;
            const bool submitted = plugin.submitCachedHierarchyRenderData(sceneCache->sceneBatches,
                sceneCache->appliedRendererPublication, appliedPublication,
                sceneCache->sceneOriginX, sceneCache->sceneOriginY);
            if (submitted) sceneCache->appliedRendererPublication = appliedPublication;
            return CreateBool(env, submitted);
        }
        const HierarchyRenderOrigin origin{
            0.5 * viewport.minX + 0.5 * viewport.maxX,
            0.5 * viewport.minY + 0.5 * viewport.maxY
        };
        std::vector<RenderBatch> scene;
        HierarchyRenderBudget renderBudget;
        for (const auto& request : requests) {
            auto batches = BuildHierarchyRenderBatches(*request.layout, request.cell, request.depth, &viewport,
                                                       &request.styles, &request.source, &renderBudget, &origin);
            for (auto& batch : batches) scene.push_back(std::move(batch));
        }
        // Includes [] and valid all-hidden/offscreen/opacity-zero scenes: one
        // successful empty publication removes every previous source's pixels.
        uint64_t appliedPublication = 0;
        const bool submitted = plugin.submitCachedHierarchyRenderData(scene, 0, appliedPublication,
                                                                      origin.x, origin.y);
        if (submitted) {
            sceneCache->sceneFingerprint = key; sceneCache->sceneBatches = std::move(scene);
            sceneCache->sceneOriginX = origin.x; sceneCache->sceneOriginY = origin.y;
            sceneCache->appliedRendererPublication = appliedPublication;
        }
        return CreateBool(env, submitted);
    } catch (...) {
        // A failed current scene must never masquerade as a still-current old one.
        // Geometry preparation is atomic; discard the entire old scene on failure.
        try { plugin.submitHierarchyRenderData({}); } catch (...) { }
        // Argument/viewport/source-count validation can fail before the cache
        // pointer is initialized. Release a prior environment cache in that case
        // as well, so malformed requests cannot keep old sources pinned.
        const auto existing = ReadonlySceneCaches().find(env);
        if (existing != ReadonlySceneCaches().end()) existing->second->clear();
        throw;
    }
}

// ==================== Native DRC ====================

/**
 * runDrc(rules, ownerCellId?, hierarchyDepth?, mergeSameLayer?) — 在 g_layout 上运行原生 DRC 内核。
 * rules: NativeDrcRule[]；type 编码与 DrcRuleType 枚举顺序一致：
 *   0=MIN_WIDTH 1=MIN_SPACING 2=MAX_WIDTH 3=MIN_AREA 4=MAX_AREA
 *   5=MIN_ENCLOSURE 6=MIN_OVERLAP 7=MAX_DENSITY 8=MIN_DENSITY 9=MIN_NOTCH
 * ownerCellId：仅检查该 Cell 的本地几何（-1 = 全部 Cell）。
 * hierarchyDepth（尾选参数，向后兼容：省略 = 0）：
 *   0 = 仅本地几何（旧行为，快速几何预检查）
 *   ≥1 = 先把 SREF/AREF 实例几何变换到该 Cell 坐标系再检查（1 = KLayout 风格默认）
 *   根 Cell 取 ownerCellId，其次 topCell；不可解析时自动退回 depth=0 本地口径。
 * mergeSameLayer（尾选参数，向后兼容：省略/0 = 关闭）：
 *   1 = **merged-region 口径**：每层（按 datatype 分桶）同层图形先做真实布尔并，再按
 *   合并后的区域测宽度/间距/面积 —— 只有合并后才显现的细腰才会被报出来（例：两个
 *   100×100 方块错位 60 叠成阶梯，逐图形宽 100/100 全过，合并后通道宽 40√2 ≈ 56.6）。
 *   合并没能覆盖的层不静默：额外返回 ruleId='DRC.MERGE' 的告警项，且每条违例带
 *   measureMode='per-shape'|'merged-region'|'mixed' 供 UI 如实标注。
 * 返回 NativeDrcViolation[]（无布局时为空数组）；坐标在**被检查 Cell 的坐标系**下。
 * ⚠ 两种口径都仍是几何近似（布尔依赖 clipper_engine 的 GeneralClipper，非 Clipper2），
 *   **不可作签核**。
 */
static napi_value NapiRunDrc(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    if (argc < 1) {
        napi_create_array_with_length(env, 0, &result);
        return result;
    }

    DrcConfig config;
    if (argc >= 2 && args[1] != nullptr) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[1], &vt);
        if (vt == napi_number) {
            config.ownerCellFilter = ReadIntArg(env, args[1]);
        }
    }
    if (argc >= 3 && args[2] != nullptr) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[2], &vt);
        if (vt == napi_number) {
            // 深度归一：负数 = 0（本地口径），上限 16 层防组合爆炸
            const int requested = ReadIntArg(env, args[2]);
            config.hierarchyDepth = requested < 0 ? 0 : std::min(requested, 16);
        }
    }
    if (argc >= 4 && args[3] != nullptr) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[3], &vt);
        if (vt == napi_boolean) {
            bool on = false;
            napi_get_value_bool(env, args[3], &on);
            config.mergeSameLayer = on;
        } else if (vt == napi_number) {
            config.mergeSameLayer = ReadIntArg(env, args[3]) != 0;
        }
    }

    uint32_t ruleCount = 0;
    napi_get_array_length(env, args[0], &ruleCount);

    DrcEngine engine;
    for (uint32_t i = 0; i < ruleCount; i++) {
        napi_value r = nullptr;
        napi_get_element(env, args[0], i, &r);
        if (r == nullptr) {
            continue;
        }
        auto getProp = [&](const char* name, napi_value* out) -> bool {
            bool has = false;
            napi_has_named_property(env, r, name, &has);
            if (!has) {
                return false;
            }
            return napi_get_named_property(env, r, name, out) == napi_ok;
        };
        DrcRule rule;
        napi_value v = nullptr;
        if (getProp("id", &v)) rule.id = ReadStringArg(env, v);
        if (getProp("name", &v)) rule.name = ReadStringArg(env, v);
        if (getProp("type", &v)) {
            const int t = ReadIntArg(env, v);
            // 上界取自枚举末位而不是字面量 9：写死数字时 MIN_EXTENSION(10)/
            // DENSITY_UNIFORMITY(11) 会被判为越界而不改 rule.type，
            // 于是按 DrcRule 默认的 MIN_WIDTH 跑出与用户规则无关的违规。
            const int lastType = static_cast<int>(DrcRuleType::DENSITY_UNIFORMITY);
            if (t >= 0 && t <= lastType) {
                rule.type = static_cast<DrcRuleType>(t);
            }
        }
        if (getProp("layer1", &v)) rule.layer1 = ReadIntArg(env, v);
        if (getProp("datatype1", &v)) rule.datatype1 = ReadIntArg(env, v);
        if (getProp("layer2", &v)) rule.layer2 = ReadIntArg(env, v);
        if (getProp("datatype2", &v)) rule.datatype2 = ReadIntArg(env, v);
        if (getProp("exactDatatype1", &v)) napi_get_value_bool(env, v, &rule.exactDatatype1);
        if (getProp("exactDatatype2", &v)) napi_get_value_bool(env, v, &rule.exactDatatype2);
        if (getProp("value", &v)) rule.value = ReadDoubleArg(env, v);
        if (getProp("value2", &v)) rule.value2 = ReadDoubleArg(env, v);
        if (getProp("enabled", &v)) {
            bool enabled = true;
            napi_get_value_bool(env, v, &enabled);
            rule.enabled = enabled;
        }
        engine.addRule(rule);
    }

    std::vector<DrcViolation> violations;
    {
        std::lock_guard<std::mutex> lock(g_layoutMutex);
        if (g_layout) {
            violations = engine.run(*g_layout, config);
        }
    }

    // 口径必须能被 UI 如实播报：逐图形 / merged-region / 混合（部分层没能合并）
    const DrcRunStats& st = engine.lastRunStats();
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

// ==================== LVS / Net Extraction ====================

/**
 * 读取对象上的整型属性。
 * 必须显式判定「属性存在且为 number」——napi_get_named_property 对缺失属性同样
 * 返回 napi_ok（值为 undefined），随后 napi_get_value_int32 失败并把 0 留在原地，
 * 于是 `{lowerLayer:1, upperLayer:2}`（漏写 viaLayer）会被静默当成 layer 0，
 * 造出一条根本不存在的 0 层连通规则。
 */
static bool ReadIntProp(napi_env env, napi_value obj, const char* name, int32_t* out) {
    if (obj == nullptr || out == nullptr) {
        return false;
    }
    bool has = false;
    if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has) {
        return false;
    }
    napi_value v = nullptr;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) {
        return false;
    }
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, v, &vt) != napi_ok || vt != napi_number) {
        return false;
    }
    return napi_get_value_int32(env, v, out) == napi_ok;
}

/**
 * 读取对象上的浮点属性；判定口径与 ReadIntProp 完全相同：
 * 「属性存在**且类型是 number**」才返回 true。缺失或显式 undefined 都必须返回 false，
 * 否则调用方会把「未提供」当成 0 写回，反向覆盖引擎里已有的值。
 */
static bool ReadDoubleProp(napi_env env, napi_value obj, const char* name, double* out) {
    if (obj == nullptr || out == nullptr) {
        return false;
    }
    bool has = false;
    if (napi_has_named_property(env, obj, name, &has) != napi_ok || !has) {
        return false;
    }
    napi_value v = nullptr;
    if (napi_get_named_property(env, obj, name, &v) != napi_ok) {
        return false;
    }
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, v, &vt) != napi_ok || vt != napi_number) {
        return false;
    }
    return napi_get_value_double(env, v, out) == napi_ok;
}

/** 读取可选 via 连通配置数组 [{viaLayer, lowerLayer, upperLayer}] */
static void ReadViaLayers(napi_env env, napi_value arr, LvsEngine& engine) {
    bool isArray = false;
    napi_is_array(env, arr, &isArray);
    if (!isArray) {
        return;
    }
    uint32_t count = 0;
    napi_get_array_length(env, arr, &count);
    for (uint32_t i = 0; i < count; i++) {
        napi_value item = nullptr;
        napi_get_element(env, arr, i, &item);
        if (item == nullptr) {
            continue;
        }
        int32_t via = 0;
        int32_t lower = 0;
        int32_t upper = 0;
        if (!ReadIntProp(env, item, "viaLayer", &via) ||
            !ReadIntProp(env, item, "lowerLayer", &lower) ||
            !ReadIntProp(env, item, "upperLayer", &upper)) {
            continue;   // 三字段的连通项才有效，缺项直接跳过（不猜 0 层）
        }
        int32_t viaDatatype=-1, lowerDatatype=-1, upperDatatype=-1;
        ReadIntProp(env,item,"viaDatatype",&viaDatatype);
        ReadIntProp(env,item,"lowerDatatype",&lowerDatatype);
        ReadIntProp(env,item,"upperDatatype",&upperDatatype);
        engine.addViaLayer(via, lower, upper, viaDatatype, lowerDatatype, upperDatatype);
    }
}

/** 可选 number 位置参数读取（未传/非 number → def） */
static int ReadOptionalIntArg(napi_env env, napi_value v, int def) {
    if (v == nullptr) {
        return def;
    }
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, v, &vt) != napi_ok || vt != napi_number) {
        return def;
    }
    int32_t out = 0;
    if (napi_get_value_int32(env, v, &out) != napi_ok) {
        return def;
    }
    return (int)out;
}

/** 可选 string 位置参数读取（未传/非 string → 返回 false） */
static bool ReadStringArgTyped(napi_env env, napi_value v, std::string* out) {
    if (v == nullptr || out == nullptr) {
        return false;
    }
    napi_valuetype vt = napi_undefined;
    if (napi_typeof(env, v, &vt) != napi_ok || vt != napi_string) {
        return false;
    }
    *out = ReadStringArg(env, v);
    return true;
}

/**
 * Net[] → JS 数组。
 * id / shapeIds 为 int64：napi_create_int64 落到 JS 侧是 double，安全整数区间
 * ±2^53；本引擎 shape id / net id 均由 Scene/Layout 顺序自增分配（从 1 起），
 * 不可能越过 2^53，故无静默截断（若日后引入外部 id 需改走 BigInt）。
 */
static napi_value CreateNetArray(napi_env env, const std::vector<Net>& nets) {
    napi_value arr;
    napi_create_array_with_length(env, nets.size(), &arr);
    for (size_t i = 0; i < nets.size(); i++) {
        const Net& net = nets[i];
        napi_value obj;
        napi_create_object(env, &obj);
        SetProp(env, obj, "id", CreateInt64(env, net.id));
        SetProp(env, obj, "name", CreateString(env, net.name));
        SetProp(env, obj, "pinCount", CreateInt(env, net.pinCount));
        SetProp(env, obj, "fromInstance", CreateBool(env, net.fromInstance));
        SetProp(env, obj, "bboxMinX", CreateDouble(env, net.bbox.minX));
        SetProp(env, obj, "bboxMinY", CreateDouble(env, net.bbox.minY));
        SetProp(env, obj, "bboxMaxX", CreateDouble(env, net.bbox.maxX));
        SetProp(env, obj, "bboxMaxY", CreateDouble(env, net.bbox.maxY));
        napi_value shapeIds;
        napi_create_array_with_length(env, net.shapeIds.size(), &shapeIds);
        for (size_t j = 0; j < net.shapeIds.size(); j++) {
            napi_set_element(env, shapeIds, j, CreateInt64(env, net.shapeIds[j]));
        }
        SetProp(env, obj, "shapeIds", shapeIds);
        napi_value layers;
        napi_create_array_with_length(env, net.layers.size(), &layers);
        for (size_t j = 0; j < net.layers.size(); j++) {
            napi_set_element(env, layers, j, CreateInt(env, net.layers[j]));
        }
        SetProp(env, obj, "layers", layers);
        // 该网承载的全部标签名：>1 即「一网多网名」= 潜在短路，UI 需显示
        napi_value labels;
        napi_create_array_with_length(env, net.labels.size(), &labels);
        for (size_t j = 0; j < net.labels.size(); j++) {
            napi_set_element(env, labels, j, CreateString(env, net.labels[j]));
        }
        SetProp(env, obj, "labels", labels);
        napi_set_element(env, arr, i, obj);
    }
    return arr;
}

/** 字符串数组 → JS 数组 */
static napi_value CreateStringArray(napi_env env, const std::vector<std::string>& items) {
    napi_value arr;
    napi_create_array_with_length(env, items.size(), &arr);
    for (size_t i = 0; i < items.size(); i++) {
        napi_set_element(env, arr, i, CreateString(env, items[i]));
    }
    return arr;
}

/** LvsResult → JS 对象（字段与 Index.d.ts::NativeLvsResult 一一对应） */
static napi_value CreateLvsResult(napi_env env, const LvsResult& r) {
    napi_value obj;
    napi_create_object(env, &obj);
    SetProp(env, obj, "matched", CreateBool(env, r.matched));
    SetProp(env, obj, "ran", CreateBool(env, r.ran));
    SetProp(env, obj, "status", CreateString(env, r.status));
    SetProp(env, obj, "error", CreateString(env, r.error));
    SetProp(env, obj, "layoutNetCount", CreateInt(env, r.layoutNetCount));
    SetProp(env, obj, "schematicNetCount", CreateInt(env, r.schematicNetCount));
    SetProp(env, obj, "matchedNets", CreateInt(env, r.matchedNets));
    SetProp(env, obj, "shortNets", CreateStringArray(env, r.shortNets));
    SetProp(env, obj, "openNets", CreateStringArray(env, r.openNets));
    SetProp(env, obj, "extraNets", CreateStringArray(env, r.extraNets));
    SetProp(env, obj, "messages", CreateStringArray(env, r.messages));
    return obj;
}

/** 在 g_layout 上加锁构造引擎并执行提取动作（所有 LVS 入口共用同一把锁） */
static bool WithLayout(const std::function<void(const Layout&)>& action) {
    std::lock_guard<std::mutex> lock(g_layoutMutex);
    if (!g_layout) {
        return false;
    }
    action(*g_layout);
    return true;
}

/**
 * extractNets(viaLayers?, ownerCellId?) → NativeNet[] | undefined
 * 在 g_layout 上提取连通网络（同层交叠 + via 跨层 + TEXT 标签命名）。
 * ownerCellId ≥0 时仅提取该 Cell 本地几何（与 UI 当前 Cell 语义一致）。
 * 无已加载布局时返回 undefined（而非空数组）——ArkTS 侧据此区分
 * 「native 无数据」与「布局确实 0 网」，否则 0 网会被误显示成提取成功。
 */
static napi_value NapiExtractNets(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    LvsEngine engine;
    if (argc >= 1 && args[0] != nullptr) {
        ReadViaLayers(env, args[0], engine);
    }
    engine.setOwnerCellFilter(ReadOptionalIntArg(env, argc >= 2 ? args[1] : nullptr, -1));
    // 尾选 hierarchyDepth：省略 = 0（旧口径）。展开后实例内连通/标签才参与提取。
    engine.setHierarchyDepth(ReadOptionalIntArg(env, argc >= 3 ? args[2] : nullptr, 0));

    std::vector<Net> nets;
    const bool hasLayout = WithLayout([&engine, &nets](const Layout& layout) {
        nets = engine.extractNets(layout);
    });
    if (!hasLayout) {
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        return undef;
    }
    if (engine.lastExtractionTruncated()) {
        napi_throw_error(env, nullptr, "网络提取超出工作预算或缺少有效层级根，未返回不完整结果");
        return nullptr;
    }
    return CreateNetArray(env, nets);
}

/**
 * runLvs(schematicNetlist, viaLayers?, ownerCellId?) → NativeLvsResult
 * 连通性级 LVS 预检查（按网名比对，依赖版图 TEXT 标签；非签核）。
 * 状态机：no-netlist（缺参数/非字符串）/ no-layout（未打开版图）/
 * empty-schematic · empty-layout · pass · mismatch（由引擎给出）。
 * **任何非 pass 都不含「已匹配」语义**，matched 恒为 false。
 */
static napi_value NapiRunLvs(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string schematic;
    if (argc < 1 || !ReadStringArgTyped(env, args[0], &schematic)) {
        LvsResult r;
        r.status = "no-netlist";
        r.error = "缺少参考网表参数（需要 SPICE/CDL 字符串）";
        r.messages.push_back("LVS NOT RUN: " + r.error);
        return CreateLvsResult(env, r);
    }

    LvsEngine engine;
    if (argc >= 2 && args[1] != nullptr) {
        ReadViaLayers(env, args[1], engine);
    }
    engine.setOwnerCellFilter(ReadOptionalIntArg(env, argc >= 3 ? args[2] : nullptr, -1));
    const int lvsDepth = ReadOptionalIntArg(env, argc >= 4 ? args[3] : nullptr, 0);
    engine.setHierarchyDepth(lvsDepth);

    LvsResult r;
    const bool hasLayout = WithLayout([&engine, &schematic, &r](const Layout& layout) {
        r = engine.compare(layout, schematic);
    });
    if (hasLayout && engine.lastExtractionTruncated()) {
        // 展开触顶 ⇒ 网表可能不完整，绝不能被读成「比对通过」
        r.matched = false;
        r.status = "truncated";
        r.messages.push_back("LVS INCOMPLETE: 层级展开触顶（maxWorkShapes），结果不完整");
    }
    if (!hasLayout) {
        r = LvsResult();
        r.status = "no-layout";
        r.error = "没有已加载的版图（LVS 需先在 native 侧解析 GDSII/OASIS）";
        r.messages.push_back("LVS NOT RUN: " + r.error);
    }
    return CreateLvsResult(env, r);
}

/**
 * exportSpiceNetlist(viaLayers?, ownerCellId?) → string | undefined
 * 导出提取网表为 SPICE 文本；无布局时返回 undefined（与 extractNets 同口径）。
 */
static napi_value NapiExportSpiceNetlist(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    LvsEngine engine;
    if (argc >= 1 && args[0] != nullptr) {
        ReadViaLayers(env, args[0], engine);
    }
    engine.setOwnerCellFilter(ReadOptionalIntArg(env, argc >= 2 ? args[1] : nullptr, -1));
    engine.setHierarchyDepth(ReadOptionalIntArg(env, argc >= 3 ? args[2] : nullptr, 0));

    std::string spice;
    const bool hasLayout = WithLayout([&engine, &spice](const Layout& layout) {
        spice = engine.exportSpice(layout);
    });
    if (!hasLayout) {
        napi_value undef = nullptr;
        napi_get_undefined(env, &undef);
        return undef;
    }
    return CreateString(env, spice);
}

// ==================== Image Export ====================

/** 解析 '#RRGGBB' → RGBA（alpha=FF）；非法输入返回 false */
static bool ParseHexColor(const std::string& hex, uint32_t& rgba) {
    if (hex.size() != 7 || hex[0] != '#') {
        return false;
    }
    uint32_t rgb = 0;
    for (int i = 1; i < 7; i++) {
        const char c = hex[static_cast<size_t>(i)];
        uint32_t digit;
        if (c >= '0' && c <= '9') digit = static_cast<uint32_t>(c - '0');
        else if (c >= 'a' && c <= 'f') digit = static_cast<uint32_t>(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') digit = static_cast<uint32_t>(c - 'A' + 10);
        else return false;
        rgb = (rgb << 4) | digit;
    }
    rgba = (rgb << 8) | 0xFF;
    return true;
}

/**
 * 应用 ArkTS 图层样式到 g_layout->layerProps（导出上色/显隐）。
 * styles: [{layerNumber, datatype, color:'#RRGGBB', visible,
 *           transparency:0-1, lineWidth:>0, lineStyle:0=solid 1=dashed 2=dotted 3=dotdash,
 *           fillPattern:0=solid 1=outline/hollow 2=diagonal 3=cross}]
 * 语义：调用方没给的字段保持原值（含 .lyp 导入 / 读取器默认），给了的才覆盖。
 */
static void ApplyLayerStyles(napi_env env, napi_value stylesArr) {
    bool isArray = false;
    napi_is_array(env, stylesArr, &isArray);
    if (!isArray || !g_layout) {
        return;
    }
    uint32_t count = 0;
    napi_get_array_length(env, stylesArr, &count);
    for (uint32_t i = 0; i < count; i++) {
        napi_value item = nullptr;
        napi_get_element(env, stylesArr, i, &item);
        if (item == nullptr) {
            continue;
        }
        napi_value v = nullptr;
        int layerNumber = 0;
        int datatype = 0;
        if (napi_get_named_property(env, item, "layerNumber", &v) == napi_ok) {
            layerNumber = ReadIntArg(env, v);
        }
        bool hasDt = false;
        napi_has_named_property(env, item, "datatype", &hasDt);
        if (hasDt && napi_get_named_property(env, item, "datatype", &v) == napi_ok) {
            datatype = ReadIntArg(env, v);
        }
        const LayerKey key = {static_cast<int16_t>(layerNumber), static_cast<int16_t>(datatype)};
        auto it = g_layout->layerProps.find(key);
        if (it == g_layout->layerProps.end()) {
            continue;
        }
        bool hasColor = false;
        napi_has_named_property(env, item, "color", &hasColor);
        if (hasColor && napi_get_named_property(env, item, "color", &v) == napi_ok) {
            uint32_t rgba = 0;
            if (ParseHexColor(ReadStringArg(env, v), rgba)) {
                it->second.fillColor = rgba;
                it->second.lineColor = rgba;
            }
        }
        // 只覆盖调用方真正给出、且类型正确的字段。两处都是踩过的坑：
        //  1) 无条件写 transparency = 0.35 会抹掉 .lyp 导入的每层透明度；
        //  2) 但 napi_has_named_property 对「键存在、值为 undefined」也返回 true，
        //     随后 ReadDoubleArg 失败并把 0 留在原地——于是 ArkTS 传
        //     `{transparency: undefined}` 会把图层判成「全不透明」、线型判成 solid，
        //     等于把坑 1 换了个数值再踩一次。故统一走 ReadDoubleProp/ReadIntProp。
        double alpha = 0.0;
        if (ReadDoubleProp(env, item, "transparency", &alpha) && std::isfinite(alpha)) {
            it->second.transparency =
                static_cast<float>(alpha < 0.0 ? 0.0 : (alpha > 1.0 ? 1.0 : alpha));
        }
        double width = 0.0;
        if (ReadDoubleProp(env, item, "lineWidth", &width) && std::isfinite(width) && width > 0.0) {
            it->second.lineWidth = static_cast<float>(width);
        }
        int32_t style = 0;
        if (ReadIntProp(env, item, "lineStyle", &style) && style >= 0 && style <= 3) {
            it->second.lineStyle = static_cast<uint8_t>(style);
        }
        double pattern = 0.0;
        if (ReadDoubleProp(env, item, "fillPattern", &pattern) && std::isfinite(pattern) &&
            pattern >= 0.0 && pattern <= 3.0 && std::floor(pattern) == pattern) {
            it->second.fillPattern = static_cast<uint8_t>(pattern);
        }
        bool visible = false;
        bool hasVisible = false;
        napi_has_named_property(env, item, "visible", &hasVisible);
        if (hasVisible && napi_get_named_property(env, item, "visible", &v) == napi_ok) {
            napi_valuetype vt = napi_undefined;
            napi_typeof(env, v, &vt);
            // 只有真的是 boolean 才写：undefined 走 napi_get_value_bool 会失败，
            // 若把 out 预置为 true 就等于「没传 visible」→「强制显示该层」
            if (vt == napi_boolean && napi_get_value_bool(env, v, &visible) == napi_ok) {
                it->second.visible = visible;
            }
        }
    }
}

static napi_value MakeImageExportResult(napi_env env, bool success,
                                        const std::string& error, int64_t bytes) {
    napi_value obj;
    napi_create_object(env, &obj);
    SetProp(env, obj, "success", CreateBool(env, success));
    SetProp(env, obj, "errorMessage", CreateString(env, error));
    SetProp(env, obj, "bytes", CreateInt64(env, bytes));
    return obj;
}

static int64_t FileSizeOf(const std::string& path) {
    std::ifstream f(path, std::ios::binary | std::ios::ate);
    if (!f.is_open()) {
        return 0;
    }
    return static_cast<int64_t>(f.tellg());
}

/** exportSvg(filePath, maxWidth, maxHeight, styles?) → {success, errorMessage, bytes} */
static napi_value NapiExportSvg(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MakeImageExportResult(env, false, "缺少文件路径参数", 0);
    }
    const std::string filePath = ReadStringArg(env, args[0]);

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    if (!g_layout || g_layout->shapes.empty()) {
        return MakeImageExportResult(env, false, "没有已加载的布局可导出", 0);
    }
    if (argc >= 4 && args[3] != nullptr) {
        ApplyLayerStyles(env, args[3]);
    }
    SvgExporter::ExportOptions opts;
    if (argc >= 2) {
        const int mw = ReadIntArg(env, args[1]);
        if (mw > 0) opts.maxWidth = mw;
    }
    if (argc >= 3) {
        const int mh = ReadIntArg(env, args[2]);
        if (mh > 0) opts.maxHeight = mh;
    }
    opts.title = g_layout->libName;
    if (!SvgExporter::saveToFile(*g_layout, filePath, opts)) {
        return MakeImageExportResult(env, false, "SVG 写文件失败: " + filePath, 0);
    }
    return MakeImageExportResult(env, true, "", FileSizeOf(filePath));
}

/** exportPng(filePath, width, height, styles?) → {success, errorMessage, bytes} */
static napi_value NapiExportPng(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        return MakeImageExportResult(env, false, "缺少参数（filePath, width, height）", 0);
    }
    const std::string filePath = ReadStringArg(env, args[0]);

    std::lock_guard<std::mutex> lock(g_layoutMutex);
    if (!g_layout || g_layout->shapes.empty()) {
        return MakeImageExportResult(env, false, "没有已加载的布局可导出", 0);
    }
    if (argc >= 4 && args[3] != nullptr) {
        ApplyLayerStyles(env, args[3]);
    }
    PngExporter::PngOptions opts;
    const int w = ReadIntArg(env, args[1]);
    const int h = ReadIntArg(env, args[2]);
    opts.width = (w > 0 && w <= 8192) ? w : 1920;
    opts.height = (h > 0 && h <= 8192) ? h : 1080;
    if (!PngExporter::saveAsPng(*g_layout, filePath, opts)) {
        return MakeImageExportResult(env, false, "PNG 写文件失败: " + filePath, 0);
    }
    return MakeImageExportResult(env, true, "", FileSizeOf(filePath));
}

// ==================== PCell ====================

static napi_value PCellValueToNapi(napi_env env, const PCellParamValue& v) {
    if (auto* d = std::get_if<double>(&v)) {
        return CreateDouble(env, *d);
    }
    if (auto* i = std::get_if<int64_t>(&v)) {
        return CreateInt64(env, *i);
    }
    if (auto* s = std::get_if<std::string>(&v)) {
        return CreateString(env, *s);
    }
    if (auto* b = std::get_if<bool>(&v)) {
        return CreateBool(env, *b);
    }
    return CreateDouble(env, 0);
}

static const char* PCellTypeName(PCellParamType t) {
    switch (t) {
        case PCellParamType::INT: return "int";
        case PCellParamType::DOUBLE: return "double";
        case PCellParamType::STRING: return "string";
        case PCellParamType::BOOLEAN: return "boolean";
        case PCellParamType::LIST: return "list";
        case PCellParamType::LAYER: return "layer";
        default: return "shape";
    }
}

/** listPCells() → PCellInfo[]（名称/展示名/类目/参数声明） */
static napi_value NapiListPCells(napi_env env, napi_callback_info info) {
    (void)info;
    PCellLibrary& lib = PCellLibrary::instance();
    const auto names = lib.listNames();
    napi_value arr;
    napi_create_array_with_length(env, names.size(), &arr);
    for (size_t i = 0; i < names.size(); i++) {
        auto decl = lib.find(names[i]);
        if (!decl) {
            continue;
        }
        napi_value obj;
        napi_create_object(env, &obj);
        SetProp(env, obj, "name", CreateString(env, decl->name()));
        SetProp(env, obj, "displayName", CreateString(env, decl->displayName()));
        SetProp(env, obj, "description", CreateString(env, decl->description()));
        SetProp(env, obj, "category", CreateString(env, decl->category()));

        const auto params = decl->parameters();
        napi_value paramArr;
        napi_create_array_with_length(env, params.size(), &paramArr);
        for (size_t j = 0; j < params.size(); j++) {
            const PCellParam& p = params[j];
            napi_value pObj;
            napi_create_object(env, &pObj);
            SetProp(env, pObj, "name", CreateString(env, p.name));
            SetProp(env, pObj, "displayName", CreateString(env, p.displayName));
            SetProp(env, pObj, "type", CreateString(env, PCellTypeName(p.type)));
            SetProp(env, pObj, "defaultValue", PCellValueToNapi(env, p.defaultValue));
            SetProp(env, pObj, "minValue", PCellValueToNapi(env, p.minValue));
            SetProp(env, pObj, "maxValue", PCellValueToNapi(env, p.maxValue));
            SetProp(env, pObj, "unit", CreateString(env, p.unit));
            napi_set_element(env, paramArr, j, pObj);
        }
        SetProp(env, obj, "params", paramArr);
        napi_set_element(env, arr, i, obj);
    }
    return arr;
}

/**
 * generatePCell(name, params) → {success, errorMessage, shapes: NativeShape[]}
 * 在临时 Layout 中生成（不触碰 g_layout），图形由 ArkTS 文档接管。
 */
static napi_value NapiGeneratePCell(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result;
    napi_create_object(env, &result);
    auto fail = [&](const std::string& msg) {
        SetProp(env, result, "success", CreateBool(env, false));
        SetProp(env, result, "errorMessage", CreateString(env, msg));
        napi_value empty;
        napi_create_array_with_length(env, 0, &empty);
        SetProp(env, result, "shapes", empty);
        SetProp(env, result, "ports", empty);
        return result;
    };
    if (argc < 1) {
        return fail("缺少 PCell 名称");
    }
    const std::string name = ReadStringArg(env, args[0]);
    PCellLibrary& lib = PCellLibrary::instance();
    auto decl = lib.find(name);
    if (!decl) {
        return fail("未知 PCell: " + name);
    }

    PCellParamSet params = decl->defaultParams();
    if (argc >= 2 && args[1] != nullptr) {
        napi_value keys = nullptr;
        if (napi_get_property_names(env, args[1], &keys) == napi_ok && keys != nullptr) {
            uint32_t keyCount = 0;
            napi_get_array_length(env, keys, &keyCount);
            for (uint32_t i = 0; i < keyCount; i++) {
                napi_value keyVal = nullptr;
                napi_get_element(env, keys, i, &keyVal);
                const std::string key = ReadStringArg(env, keyVal);
                napi_value val = nullptr;
                napi_get_property(env, args[1], keyVal, &val);
                napi_valuetype vt = napi_undefined;
                napi_typeof(env, val, &vt);
                if (vt == napi_number) {
                    params[key] = ReadDoubleArg(env, val);
                } else if (vt == napi_boolean) {
                    bool b = false;
                    napi_get_value_bool(env, val, &b);
                    params[key] = b;
                } else if (vt == napi_string) {
                    params[key] = ReadStringArg(env, val);
                }
            }
        }
    }

    std::string error;
    if (!decl->validateParams(params, error)) {
        return fail("参数非法: " + error);
    }

    Layout scratch;
    const int cellId = scratch.addCell(name);
    decl->generate(params, scratch, cellId);
    const auto generatedPorts=decl->generatePorts(params,cellId);
    napi_value ports;napi_create_array_with_length(env,generatedPorts.size(),&ports);
    for(size_t i=0;i<generatedPorts.size();++i){ParseResultHandleScope handles(env);napi_set_element(env,ports,i,CreateNativePort(env,generatedPorts[i]));}
    SetProp(env,result,"ports",ports);

    napi_value shapes;
    napi_create_array_with_length(env, scratch.shapes.size(), &shapes);
    for (size_t i = 0; i < scratch.shapes.size(); i++) {
        const SceneShape& s = scratch.shapes[i];
        napi_value obj;
        napi_create_object(env, &obj);
        SetProp(env, obj, "id", CreateInt64(env, s.id));
        const char* typeName = "polygon";
        switch (s.type) {
            case ShapeType::RECT: typeName = "rect"; break;
            case ShapeType::POLYGON: typeName = "polygon"; break;
            case ShapeType::PATH: typeName = "path"; break;
            case ShapeType::TEXT: typeName = "text"; break;
            default: break;
        }
        SetProp(env, obj, "type", CreateString(env, typeName));
        SetProp(env, obj, "layerNumber", CreateInt(env, s.layerKey.layer));
        SetProp(env, obj, "datatype", CreateInt(env, s.layerKey.datatype));
        SetProp(env, obj, "pathWidth", CreateDouble(env, s.pathWidth));
        SetProp(env, obj, "text", CreateString(env, s.text));
        SetProp(env, obj, "cellName", CreateString(env, ""));
        SetProp(env, obj, "ownerCellId", CreateInt(env, -1));
        SetProp(env, obj, "cellId", CreateInt(env, -1));
        SetProp(env, obj, "rotation", CreateDouble(env, 0));
        SetProp(env, obj, "mirror", CreateInt(env, 0));
        SetProp(env, obj, "magnification", CreateDouble(env, 1));
        napi_value points;
        napi_create_array_with_length(env, s.points.size(), &points);
        for (size_t j = 0; j < s.points.size(); j++) {
            napi_value pt;
            napi_create_object(env, &pt);
            SetProp(env, pt, "x", CreateDouble(env, s.points[j].x));
            SetProp(env, pt, "y", CreateDouble(env, s.points[j].y));
            napi_set_element(env, points, j, pt);
        }
        SetProp(env, obj, "points", points);
        napi_set_element(env, shapes, i, obj);
    }
    SetProp(env, result, "success", CreateBool(env, true));
    SetProp(env, result, "errorMessage", CreateString(env, ""));
    SetProp(env, result, "shapes", shapes);
    return result;
}

// ==================== Embedded On-Device Python 3 Runtime ====================

struct EmbeddedPythonAsyncData {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    EmbeddedPythonRequest req;
    EmbeddedPythonResult res;
};

static napi_value NapiGetEmbeddedPythonInfo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string homeDir;
    if (argc >= 1 && args[0] != nullptr) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[0], &vt);
        if (vt == napi_string) {
            homeDir = ReadStringArg(env, args[0]);
        }
    }
    const EmbeddedPythonRuntimeInfo rtInfo = EmbeddedPythonRuntime::queryInfo(homeDir);
    napi_value obj = nullptr;
    napi_create_object(env, &obj);
    SetProp(env, obj, "available", CreateBool(env, rtInfo.available));
    SetProp(env, obj, "hasCPython", CreateBool(env, rtInfo.hasCPython));
    SetProp(env, obj, "activeTier", CreateString(env, rtInfo.activeTier));
    SetProp(env, obj, "version", CreateString(env, rtInfo.version));
    SetProp(env, obj, "summary", CreateString(env, rtInfo.summary));
    return obj;
}

static void EmbeddedPythonExecute(napi_env, void* data) {
    auto* asyncData = static_cast<EmbeddedPythonAsyncData*>(data);
    try {
        asyncData->res = EmbeddedPythonRuntime::execute(asyncData->req);
    } catch (const std::exception& e) {
        asyncData->res.success = false;
        asyncData->res.errorMessage = e.what();
    } catch (...) {
        asyncData->res.success = false;
        asyncData->res.errorMessage = "端侧内置 Python 执行发生未知异常";
    }
}

static void EmbeddedPythonComplete(napi_env env, napi_status status, void* data) {
    auto* asyncData = static_cast<EmbeddedPythonAsyncData*>(data);
    if (status != napi_ok) {
        napi_value err = nullptr;
        napi_create_error(env, nullptr, CreateString(env, "异步 Python 工作线程已取消"), &err);
        napi_reject_deferred(env, asyncData->deferred, err);
    } else {
        const EmbeddedPythonResult& r = asyncData->res;
        napi_value obj = nullptr;
        napi_create_object(env, &obj);
        SetProp(env, obj, "success", CreateBool(env, r.success));
        SetProp(env, obj, "engineTier", CreateString(env, r.engineTier));
        SetProp(env, obj, "engineVersion", CreateString(env, r.engineVersion));
        SetProp(env, obj, "errorMessage", CreateString(env, r.errorMessage));
        SetProp(env, obj, "fileName", CreateString(env, r.fileName));
        SetProp(env, obj, "outputGdsPath", CreateString(env, r.outputGdsPath));
        SetProp(env, obj, "outputSvgPath", CreateString(env, r.outputSvgPath));
        SetProp(env, obj, "previewSvg", CreateString(env, r.previewSvg));
        SetProp(env, obj, "stdoutText", CreateString(env, r.stdoutText));
        SetProp(env, obj, "cellCount", CreateInt(env, r.cellCount));
        SetProp(env, obj, "shapeCount", CreateInt(env, r.shapeCount));
        SetProp(env, obj, "expandedShapeCount", CreateInt(env, r.expandedShapeCount));
        SetProp(env, obj, "layerCount", CreateInt(env, r.layerCount));
        SetProp(env, obj, "gdsBytes", CreateInt64(env, static_cast<int64_t>(r.gdsBytes)));
        SetProp(env, obj, "cellNames", CreateStringArray(env, r.cellNames));

        napi_value layerDefs = nullptr;
        napi_create_array_with_length(env, r.layerDefinitions.size(), &layerDefs);
        for (size_t i = 0; i < r.layerDefinitions.size(); ++i) {
            napi_value ld = nullptr;
            napi_create_object(env, &ld);
            SetProp(env, ld, "layerNumber", CreateInt(env, r.layerDefinitions[i].layerNumber));
            SetProp(env, ld, "datatype", CreateInt(env, r.layerDefinitions[i].datatype));
            SetProp(env, ld, "name", CreateString(env, r.layerDefinitions[i].name));
            napi_set_element(env, layerDefs, i, ld);
        }
        SetProp(env, obj, "layerDefinitions", layerDefs);

        napi_value portsArr = nullptr;
        napi_create_array_with_length(env, r.ports.size(), &portsArr);
        for (size_t i = 0; i < r.ports.size(); ++i) {
            const auto& p = r.ports[i];
            napi_value po = nullptr;
            napi_create_object(env, &po);
            SetProp(env, po, "id", CreateString(env, p.id));
            SetProp(env, po, "ownerCellId", CreateInt(env, p.ownerCellId));
            SetProp(env, po, "ownerCellKey", CreateString(env, p.ownerCellKey));
            SetProp(env, po, "name", CreateString(env, p.name));
            SetProp(env, po, "xNm", CreateDouble(env, p.xNm));
            SetProp(env, po, "yNm", CreateDouble(env, p.yNm));
            SetProp(env, po, "orientationDeg", CreateDouble(env, p.orientationDeg));
            SetProp(env, po, "widthNm", CreateDouble(env, p.widthNm));
            SetProp(env, po, "layerNumber", CreateInt(env, p.layerNumber));
            SetProp(env, po, "datatype", CreateInt(env, p.datatype));
            SetProp(env, po, "portType", CreateString(env, p.portType));
            napi_set_element(env, portsArr, i, po);
        }
        SetProp(env, obj, "ports", portsArr);
        napi_resolve_deferred(env, asyncData->deferred, obj);
    }
    napi_delete_async_work(env, asyncData->work);
    delete asyncData;
}

static std::string ReadObjStrProp(napi_env env, napi_value obj, const char* key, const std::string& defVal = "") {
    napi_value v = nullptr;
    if (napi_get_named_property(env, obj, key, &v) != napi_ok || v == nullptr) return defVal;
    napi_valuetype vt = napi_undefined;
    napi_typeof(env, v, &vt);
    if (vt != napi_string) return defVal;
    return ReadStringArg(env, v);
}

static napi_value NapiRunEmbeddedPythonAsync(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto* asyncData = new EmbeddedPythonAsyncData();
    if (argc >= 1 && args[0] != nullptr) {
        napi_valuetype vt = napi_undefined;
        napi_typeof(env, args[0], &vt);
        if (vt == napi_object) {
            asyncData->req.script = ReadObjStrProp(env, args[0], "script");
            asyncData->req.inputMode = ReadObjStrProp(env, args[0], "inputMode", "new");
            asyncData->req.sourceGdsPath = ReadObjStrProp(env, args[0], "sourceGdsPath");
            asyncData->req.selectionGdsPath = ReadObjStrProp(env, args[0], "selectionGdsPath");
            asyncData->req.currentCellName = ReadObjStrProp(env, args[0], "currentCellName");
            asyncData->req.parametersJson = ReadObjStrProp(env, args[0], "parametersJson", "{}");
            asyncData->req.outputGdsPath = ReadObjStrProp(env, args[0], "outputGdsPath");
            asyncData->req.outputSvgPath = ReadObjStrProp(env, args[0], "outputSvgPath");
            asyncData->req.cpythonHomeDir = ReadObjStrProp(env, args[0], "cpythonHomeDir");
            napi_value tmVal = nullptr;
            if (napi_get_named_property(env, args[0], "timeoutMs", &tmVal) == napi_ok && tmVal != nullptr) {
                napi_valuetype tvt = napi_undefined;
                napi_typeof(env, tmVal, &tvt);
                if (tvt == napi_number) {
                    asyncData->req.timeoutMs = static_cast<int64_t>(ReadDoubleArg(env, tmVal));
                }
            }
        }
    }
    napi_value promise = nullptr;
    napi_create_promise(env, &asyncData->deferred, &promise);
    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "runEmbeddedPythonAsync", NAPI_AUTO_LENGTH, &resourceName);
    if (napi_create_async_work(env, nullptr, resourceName, EmbeddedPythonExecute,
                               EmbeddedPythonComplete, asyncData, &asyncData->work) != napi_ok) {
        napi_deferred deferred = asyncData->deferred;
        delete asyncData;
        napi_value err = nullptr;
        napi_create_error(env, nullptr, CreateString(env, "创建端侧 Python 异步任务失败"), &err);
        napi_reject_deferred(env, deferred, err);
        return promise;
    }
    if (napi_queue_async_work(env, asyncData->work) != napi_ok) {
        napi_delete_async_work(env, asyncData->work);
        napi_deferred deferred = asyncData->deferred;
        delete asyncData;
        napi_value err = nullptr;
        napi_create_error(env, nullptr, CreateString(env, "排队端侧 Python 异步任务失败"), &err);
        napi_reject_deferred(env, deferred, err);
    }
    return promise;
}

// ==================== Module Registration ====================

/**
 * NAPI 异常守卫：以回调函数指针作为非类型模板参数，在真实实现外层包裹 try/catch。
 * 任何穿越出来的 C++ 异常（std::bad_alloc、std::length_error 等）都会被转换为
 * napi_throw_error，避免异常穿越 NAPI 边界触发 std::terminate 使进程崩溃。
 * 用法：注册表中以 NapiSafe<NapiXxx> 代替 NapiXxx，无需改动回调函数体。
 */
#include "native_jobs_napi.inc"
#include "layout_compare_napi.inc"

template <napi_value (*Impl)(napi_env, napi_callback_info)>
static napi_value NapiSafe(napi_env env, napi_callback_info info) {
    try {
        return Impl(env, info);
    } catch (const std::exception& e) {
        napi_throw_error(env, nullptr, e.what());
        return nullptr;
    } catch (...) {
        napi_throw_error(env, nullptr, "HongTu native: unknown exception");
        return nullptr;
    }
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_add_env_cleanup_hook(env, CleanupNativeJobs, env);
    napi_property_descriptor desc[] = {
        // Sync file I/O (UI path — matches Index.d.ts / NativeHongTuService)
        {"parseGdsii", nullptr, NapiSafe<NapiParseGdsii>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"quickInfo", nullptr, NapiSafe<NapiQuickInfo>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseOasis", nullptr, NapiSafe<NapiParseOasis>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"quickOasisInfo", nullptr, NapiSafe<NapiQuickOasisInfo>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseCif", nullptr, NapiSafe<NapiParseCif>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseDxf", nullptr, NapiSafe<NapiParseDxf>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeGdsii", nullptr, NapiSafe<NapiWriteGdsii>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeGdsiiDocument", nullptr, NapiSafe<NapiWriteGdsiiDocument>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"syncDocument", nullptr, NapiSafe<NapiSyncDocument>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"compareLayout", nullptr, NapiSafe<NapiCompareLayout>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startCompareJob", nullptr, NapiSafe<NapiStartCompareJob>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"writeOasis", nullptr, NapiSafe<NapiWriteOasis>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // File I/O (async)
        {"parseAsync", nullptr, NapiSafe<NapiParseAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startParseJob", nullptr, NapiSafe<NapiStartParseJob>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startDrcJob", nullptr, NapiSafe<NapiStartDrcJob>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getJobProgress", nullptr, NapiSafe<NapiGetJobProgress>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cancelJob", nullptr, NapiSafe<NapiCancelJob>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Hierarchy expand (KLayout depth semantics)
        {"expandHierarchy", nullptr, NapiSafe<NapiExpandHierarchy>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"expandHierarchyToBatches", nullptr, NapiSafe<NapiExpandHierarchyToBatches>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renderHierarchyToSurface", nullptr, NapiSafe<NapiRenderHierarchyToSurface>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renderSceneToSurface", nullptr, NapiSafe<NapiRenderSceneToSurface>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearRenderScene", nullptr, NapiSafe<NapiClearRenderScene>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Spatial queries
        {"queryPoint", nullptr, NapiSafe<NapiQueryPoint>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryRange", nullptr, NapiSafe<NapiQueryRange>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"queryNearest", nullptr, NapiSafe<NapiQueryNearest>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Boolean operations
        {"booleanOp", nullptr, NapiSafe<NapiBooleanOp>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"booleanOpEx", nullptr, NapiSafe<NapiBooleanOpEx>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"offsetPolygon", nullptr, NapiSafe<NapiOffsetPolygon>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"offsetPolygons", nullptr, NapiSafe<NapiOffsetPolygons>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"booleanOpForEdit", nullptr, NapiSafe<NapiBooleanOpForEdit>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"regionBooleanForEdit", nullptr, NapiSafe<NapiRegionBooleanForEdit>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pathRegionForEdit", nullptr, NapiSafe<NapiPathRegionForEdit>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pathRegionWholeDPathSimple", nullptr, NapiSafe<NapiPathRegionWholeDPathSimple>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"offsetPolygonsForEdit", nullptr, NapiSafe<NapiOffsetPolygonsForEdit>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Geometry
        {"polygonDistance", nullptr, NapiSafe<NapiPolygonDistance>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"polygonArea", nullptr, NapiSafe<NapiPolygonArea>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pointInPolygon", nullptr, NapiSafe<NapiPointInPolygon>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Layout
        {"getLayoutStats", nullptr, NapiSafe<NapiGetLayoutStats>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Native DRC（快速几何预检查，不展开层级，不可作签核）
        {"runDrc", nullptr, NapiSafe<NapiRunDrc>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // LVS / 网络提取（连通性级预检查，非签核）
        {"extractNets", nullptr, NapiSafe<NapiExtractNets>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runLvs", nullptr, NapiSafe<NapiRunLvs>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportSpiceNetlist", nullptr, NapiSafe<NapiExportSpiceNetlist>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // 图像导出（SVG 矢量 / PNG 软件光栅）
        {"exportSvg", nullptr, NapiSafe<NapiExportSvg>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportPng", nullptr, NapiSafe<NapiExportPng>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // PCell（参数化单元：Basic circle/donut/arc + 器件）
        {"listPCells", nullptr, NapiSafe<NapiListPCells>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"generatePCell", nullptr, NapiSafe<NapiGeneratePCell>, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Version & On-Device Embedded Python 3 Runtime (PocketPy 2.2.0 + Clipper2 + CPython dlopen)
        {"version", nullptr, NapiSafe<NapiVersion>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getEmbeddedPythonInfo", nullptr, NapiSafe<NapiGetEmbeddedPythonInfo>, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"runEmbeddedPythonAsync", nullptr, NapiSafe<NapiRunEmbeddedPythonAsync>, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // Initialize XComponent plugin (registers its own NAPI methods)
    XComponentPlugin::Init(env, exports);

    return exports;
}

/**
 * 模块描述符：字段必须**按 napi_module 声明顺序**做指定初始化，
 * 否则 clang 触发 -Wreorder-init-list（原写法只给 nm_modname/nm_register_func
 * 两项且顺序与声明相反）。
 */
static napi_module hongtuModule = {
    .nm_version = NAPI_MODULE_VERSION,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "hongtu",
    .nm_priv = nullptr,
    .reserved = { nullptr },
};

extern "C" __attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&hongtuModule);
}
