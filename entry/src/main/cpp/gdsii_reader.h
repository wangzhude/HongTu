/**
 * 鸿图 GDSII 文件解析器
 * 
 * 解析 GDSII Stream Format 二进制格式，提取版图元数据：
 * - 库名称、单元列表、图层数量、图形总数
 * - 用户单位、物理单位（米/用户单位）
 * - 文件大小、版本号
 *
 * GDSII 格式参考: https://en.wikipedia.org/wiki/GDSII
 *
 * This file is part of HongTu, licensed under GPLv3.
 * Original KLayout concepts by Matthias Koefferlein.
 */

#ifndef GDSII_READER_H
#define GDSII_READER_H

#include <string>
#include <vector>
#include "layout_port.h"
#include <cstdint>
#include <fstream>
#include "native_job_control.h"

namespace hongtu {

// GDSII 记录类型枚举（主要类型）
enum class GdsRecordType : uint8_t {
    HEADER    = 0x00,
    BGNLIB    = 0x01,
    LIBNAME   = 0x02,
    UNITS     = 0x03,
    ENDLIB    = 0x04,
    BGNSTR    = 0x05,
    STRNAME   = 0x06,
    ENDSTR    = 0x07,
    BOUNDARY  = 0x08,
    PATH      = 0x09,
    SREF      = 0x0A,
    AREF      = 0x0B,
    TEXT      = 0x0C,
    LAYER     = 0x0D,
    DATATYPE  = 0x0E,
    WIDTH     = 0x0F,
    XY        = 0x10,
    ENDEL     = 0x11,
    SNAME     = 0x12,
    COLROW    = 0x13,
    TEXTTYPE  = 0x16,
    PRESENTATION = 0x17,
    STRING    = 0x19,
    STRANS    = 0x1A,
    MAG       = 0x1B,
    ANGLE     = 0x1C,
    // 记录码已按一手资料双源核对（Calma GDSII Stream Format Manual 6.0 记录表，
    // 以及 https://boolean.klaasholwerda.nl/interface/bnf/gdsformat.html 记录号表）：
    //   NODE 21/0x15 · PATHTYPE 33/0x21 · PROPATTR 43/0x2B · PROPVALUE 44/0x2C
    //   BOX 45/0x2D · BOXTYPE 46/0x2E · PLEX 47/0x2F · BGNEXTN 48/0x30 · ENDEXTN 49/0x31
    //
    // 历史坑（两连击，务必别再退回自洽而错的表）：初版把 BOXTYPE/BOX 记成 0x2D/0x2E
    // 恰好占用 PROPATTR/PROPVALUE；上一轮「纠正」时又整体右移两格（PROPATTR 0x2D…），
    // 于是 reader/writer/冒烟 fixture 三者继续自洽，断言全绿，而真实 GDS 的属性对
    // （0x2B/0x2C）照旧落进 default 分支被丢弃，且真 BOX 元素会被当成属性对。
    // ⇒ 结论：属性/元素记录码必须以规范表为准，fixture 要用真实码，不能只跟着枚举走。
    NODE      = 0x15,
    NODETYPE  = 0x2A,
    PATHTYPE  = 0x21,
    PROPATTR  = 0x2B,
    PROPVALUE = 0x2C,
    BOX       = 0x2D,
    BOXTYPE   = 0x2E,
    BGNEXTN   = 0x30,
    ENDEXTN   = 0x31
};

// GDSII 数据类型枚举
enum class GdsDataType : uint8_t {
    NONE      = 0x00,
    BIT_ARRAY = 0x01,
    INT_2     = 0x02,
    INT_4     = 0x03,
    FLOAT_4   = 0x04,
    FLOAT_8   = 0x05,
    STRING    = 0x06,
};

// 图层信息
struct LayerInfo {
    int layerNumber = 0;
    int datatype = 0;
    int elementCount = 0;  // 该图层上的图形数量
    std::string sourceName; // File identity, independent from the UI display label.
};

struct LayerNameInterval {
    uint32_t type = 0; // 0:any, 1:<=upper, 2:>=lower, 3:singleton, 4:closed range
    uint32_t lower = 0;
    uint32_t upper = UINT32_MAX;
};
struct SourceLayerDefinition {
    std::string name;
    bool textLayer = false; // OASIS record 12, versus geometry record 11.
    LayerNameInterval layer;
    LayerNameInterval datatype;
};

/**
 * 元素 / 结构 / 库级属性（GDSII PROPATTR + PROPVALUE 一对 = 一条）。
 *
 * 「原始字节保真」策略：reader 把 PROPVALUE 数据段原样存进 value，writer 原样回写，
 * 因此 写出→重解析 的值逐字节相等（含 GDS 偶数填充与 8 字节 real 编码），
 * 无需在内存里重建 IEEE/GDS 浮点转换，也不会因四舍五入丢值。
 *
 * - attr  : PROPATTR 的 2 字节属性码；0 表示「值没有前置 PROPATTR」（畸形输入，仍不错位）
 * - dtype : PROPVALUE 记录的数据类型码（0 无数据 / 2 int16 / 3 int32 / 4 float4 /
 *           5 float8 / 6 ASCII）；0 表示无数据属性
 * - value : PROPVALUE 数据段原始字节（不含 4 字节记录头）
 *
 * OASIS(SEMI P39) 的 PROPERTY 复用同一结构：attr 恒 0，name 承载 PROPNAME，
 * value 承载解码后的文本值（OASIS 元素属性规范上无名，一般属性有名）。
 */
struct LayoutProperty {
    int16_t attr = 0;
    uint8_t dtype = 6;
    std::string value;
    std::string name;

    bool operator==(const LayoutProperty& o) const {
        return attr == o.attr && dtype == o.dtype && value == o.value && name == o.name;
    }
    bool operator!=(const LayoutProperty& o) const { return !(*this == o); }
};

// 单元信息
struct CellInfo {
    std::string name;
    int elementCount = 0;
    std::vector<LayerInfo> layers;
    /// 结构级属性（BGNSTR/STRNAME 之后、首个元素之前的 PROPATTR/PROPVALUE 对）
    std::vector<LayoutProperty> properties;
};

/** 按 GDSII 属性码查找首个匹配值；未找到返回 nullptr。 */
const std::string* FindPropertyValue(const std::vector<LayoutProperty>& props, int16_t attr);

/** 按 OASIS 属性名查找首个匹配值；未找到返回 nullptr。 */
const std::string* FindNamedProperty(const std::vector<LayoutProperty>& props,
                                     const std::string& name);

// GDSII 解析结果
struct GdsPoint {
    double x = 0.0;
    double y = 0.0;
};

struct LayoutShape {
    int id = 0;
    std::string type;
    int layerNumber = 0;
    int datatype = 0;
    std::vector<GdsPoint> points;
    double pathWidth = 1.0;
    // PATHTYPE: 0 flush / 1 round / 2 half-width square / 4 explicit extensions.
    int pathType = 0;
    double pathBeginExtension = 0.0; // nm, signed, PATHTYPE=4 only
    double pathEndExtension = 0.0;
    bool pathWidthAbsolute = false; // negative GDS WIDTH: unaffected by instance MAG
    std::string text;
    int textPresentation = 0;
    std::string cellName;
    int ownerCellId = -1;
    int cellId = -1;
    double rotation = 0.0;
    int mirror = 0;
    double magnification = 1.0;
    // AREF retained as one instance. Step vectors are in the owner cell's coordinates.
    int arrayCols = 0;
    int arrayRows = 0;
    double arrayColStepX = 0.0, arrayColStepY = 0.0;
    double arrayRowStepX = 0.0, arrayRowStepY = 0.0;
    /// 元素级属性（BOUNDARY/PATH/SREF/AREF/BOX/TEXT/NODE 上的 PROPATTR/PROPVALUE）
    std::vector<LayoutProperty> properties;
};

struct GdsiiParseResult {
    bool success = false;
    std::string errorMessage;

    // 文件信息
    std::string filePath;
    int64_t fileSize = 0;

    // 库信息
    int version = 0;
    std::string libName;
    int cellCount = 0;
    int totalElements = 0;
    int layerCount = 0;

    // 单位信息
    double userUnits = 0.0;     // 用户单位（如 1e-9 = nm）
    double physicalUnits = 0.0; // 物理单位（米/用户单位）
    std::string unitDescription;

    // 单元列表
    std::vector<CellInfo> cells;

    // 未被其他 Cell 引用的顶层候选，以及默认打开的主顶层 Cell
    std::vector<int> topCellIds;
    int primaryTopCellId = -1;

    // 图层列表（去重汇总）
    std::vector<LayerInfo> allLayers;
    std::vector<SourceLayerDefinition> layerDefinitions; // Includes empty layers and range definitions.
    std::vector<LayoutShape> shapes;

    // 时间戳
    std::string modTime;
    std::string accessTime;

    /// 库级属性（HEADER/BGNLIB/LIBNAME/UNITS 之后、首个 BGNSTR 之前的属性对）
    std::vector<LayoutProperty> libProperties;
    // Raw ordered KLayout context strings have a separate bounded budget.
    std::vector<std::string> layoutContextRecords;
    std::vector<std::vector<std::string>> cellContextRecords;
    std::vector<std::string> cellKeys;
    std::vector<LayoutPort> ports;
    std::vector<LayoutCrossSection> crossSections;
    std::vector<std::string> portCapabilityDiagnostics;
};

/** 解析实例引用并推导 Top Cell 候选。GDSII/OASIS reader 共用。 */
void ResolveHierarchyMetadata(GdsiiParseResult& result, const NativeJobControl* control = nullptr);

/**
 * GDSII 文件解析器
 */
class GdsiiReader {
public:
    GdsiiReader();
    ~GdsiiReader();

    /**
     * 解析 GDSII 文件
     * @param filePath 文件路径
     * @return 解析结果
     */
    GdsiiParseResult parse(const std::string& filePath, const NativeJobControl* control = nullptr);

    /**
     * 快速获取文件基本信息（不完全解析）
     * @param filePath 文件路径
     * @return 解析结果（仅含文件大小、库名、单元数等概要信息）
     */
    GdsiiParseResult quickInfo(const std::string& filePath, const NativeJobControl* control = nullptr);

private:
    // 读取 GDSII 记录头
    bool readRecordHeader(std::ifstream& file, uint16_t& length, uint8_t& type, uint8_t& dataType);

    // 读取 2 字节整数（大端序）
    int16_t readInt16(std::ifstream& file);

    // 读取 4 字节整数（大端序）
    int32_t readInt32(std::ifstream& file);

    // 读取 8 字节双精度浮点（GDSII 特殊格式）
    double readFloat64(std::ifstream& file);

    // 读取字符串
    std::string readString(std::ifstream& file, int length);

    // 跳过当前记录的数据部分
    void skipRecord(std::ifstream& file, int dataLength);

    // 大端序转换
    uint16_t swap16(uint16_t val);
    uint32_t swap32(uint32_t val);

    // GDSII 8字节浮点转 IEEE 754 double
    double gdsiiFloatToDouble(const uint8_t* bytes);
};

} // namespace hongtu

#endif // GDSII_READER_H
