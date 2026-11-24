/**
 * 鸿图 (HongTu EDA) 端侧内置完整 Python 3 版图脚本引擎
 *
 * 双层原生架构（无需外部桌面 Python 伴随服务即可在鸿蒙手机/平板/折叠屏/PC 端侧离线运行）：
 * 1. Tier 1（可选增强动态层）：运行时通过 dlopen 自动探测应用沙箱 / libs 下的完整 CPython 3.12/3.11
 *    (`libpython3.12.so` + 标准库)，支持完整 CPython 生态与 C 扩展；
 * 2. Tier 2（零配置开箱内置层）：直接编译进 `libhongtu.so` 的 PocketPy v2.2.0 (C11 Python 3.x VM，
 *    含字节码看门狗防死循环) + 原生 C++ Clipper2 多边形布尔/偏置内核 + 原生 GDSII 读写与 SVG 预览渲染器，
 *    完整提供 `import hongtu as db`、`import klayout.db as db`、`import pya`、`db.Layout`、`db.Cell`、
 *    `db.Box`/`DBox`、`db.Polygon`/`DPolygon`、`db.Path`/`DPath`、`db.Text`、`db.Trans`、
 *    `db.CellInstArray` (SREF/AREF)、`db.Region` (Clipper2 布尔并/交/差/异或与尺寸偏置)、
 *    `generic_cmos_inverter` 与语义端口接口。
 *
 * This file is part of HongTu, licensed under GPLv3 (PocketPy under MIT, Clipper2 under BSL-1.0).
 */
#ifndef HONGTU_EMBEDDED_PYTHON_RUNTIME_H
#define HONGTU_EMBEDDED_PYTHON_RUNTIME_H

#include <cstdint>
#include <string>
#include <vector>

namespace hongtu {

struct EmbeddedPythonLayerDef {
    int layerNumber = 0;
    int datatype = 0;
    std::string name;
};

struct EmbeddedPythonPortDef {
    std::string id;
    int ownerCellId = 0;
    std::string ownerCellKey;
    std::string name;
    double xNm = 0.0;
    double yNm = 0.0;
    double orientationDeg = 0.0;
    double widthNm = 100.0;
    int layerNumber = 1;
    int datatype = 0;
    std::string portType = "electrical";
};

struct EmbeddedPythonRequest {
    std::string script;
    std::string inputMode = "new"; // "new" | "document" | "selection"
    std::string sourceGdsPath;
    std::string selectionGdsPath;
    std::string currentCellName;
    std::string parametersJson = "{}";
    std::string outputGdsPath;
    std::string outputSvgPath;
    std::string cpythonHomeDir;
    int64_t timeoutMs = 15000;
    bool inspectOnly = false;
};

struct EmbeddedPythonResult {
    bool success = false;
    std::string engineTier;    // "cpython-native" | "pocketpy-native"
    std::string engineVersion; // e.g. "PocketPy 2.2.0 + HongTu C++ Clipper2"
    std::string errorMessage;
    std::string fileName = "python-generated.gds";
    std::string outputGdsPath;
    std::string outputSvgPath;
    std::string previewSvg;
    std::string stdoutText;
    int cellCount = 0;
    int shapeCount = 0;
    int expandedShapeCount = 0;
    int layerCount = 0;
    size_t gdsBytes = 0;
    std::vector<EmbeddedPythonLayerDef> layerDefinitions;
    std::vector<EmbeddedPythonPortDef> ports;
    std::vector<std::string> cellNames;
};

struct EmbeddedPythonRuntimeInfo {
    bool available = true;
    bool hasCPython = false;
    std::string activeTier;
    std::string version;
    std::string summary;
};

class EmbeddedPythonRuntime {
public:
    static EmbeddedPythonRuntimeInfo queryInfo(const std::string& cpythonHomeDir = "");
    static EmbeddedPythonResult execute(const EmbeddedPythonRequest& req);
};

} // namespace hongtu

#endif // HONGTU_EMBEDDED_PYTHON_RUNTIME_H
