/**
 * 鸿图 OASIS 格式解析器实现（SEMI P39 完整状态机）
 *
 * 文件结构:
 *   "%SEMI-OASIS\r\n" [START] { NAME / CELL / CBLOCK ... } [END]
 *
 * 变长无符号整数 (unsigned-integer):
 *   每字节低 7 位数据、最高位续位；LSB-first。
 * 变长有符号整数 (signed-integer):
 *   无符号编码的 bit0 为符号位，其余右移一位为幅值。
 *
 * modal 状态机、点列表、repetition、CBLOCK 语义见 oasis_reader.h 头注释。
 *
 * This file is part of HongTu, licensed under GPLv3.
 * 参考: SEMI P39 spec / KLayout dbOASISReader 语义。
 */

#include "oasis_reader.h"
#include "layout_context.h"
#include "layout_port_codec.h"
#include "inflate_tiny.h"
#include "checksums.h"

#if !defined(HONGTU_NO_ZLIB) && __has_include(<zlib.h>)
#include <zlib.h>
#define HONGTU_OASIS_HAS_ZLIB 1
#else
#define HONGTU_OASIS_HAS_ZLIB 0
#endif

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <stdexcept>
#include <utility>
#include <vector>

namespace hongtu {

namespace {

// ==================== 常量与错误 ====================

constexpr int64_t kMaxFileSize = static_cast<int64_t>(4) * 1024 * 1024 * 1024; // 4GB
constexpr uint64_t kMaxRepetition = 1u << 20;      // 单条 repetition 最大展开数
constexpr uint64_t kMaxPointCount = 1u << 20;      // 单个点列表最大点数
constexpr size_t kMaxTotalShapes = 8u * 1000 * 1000; // 总图形上限
constexpr uint64_t kMaxCblockUncompressed = 256u * 1024 * 1024; // CBLOCK 解压上限 256MB
constexpr int kMinCirclePolygonSegments = 32;
constexpr int kMaxCirclePolygonSegments = 4096;

/**
 * 弦高误差（sagitta）自适应计算原生 CIRCLE 离散分段数：
 * 保底 32 段保持旧用例向后兼容，向上取 4 的倍数保留正交极值点，上限 4096 段防止极大圆顶点爆炸。
 */
int AdaptiveCircleSegments(double radiusDbu, double physicalUnitMeters) {
    if (!std::isfinite(radiusDbu) || radiusDbu <= 0.0) {
        return kMinCirclePolygonSegments;
    }
    const double nmPerDbu = (std::isfinite(physicalUnitMeters) && physicalUnitMeters > 0.0)
        ? (physicalUnitMeters * 1e9)
        : 1.0;
    const double maxSagittaDbu = std::max(1.0, 0.5 / std::max(1e-6, nmPerDbu));
    if (radiusDbu <= maxSagittaDbu) {
        return kMinCirclePolygonSegments;
    }
    const double ratio = std::min(1.0, maxSagittaDbu / radiusDbu);
    const double halfStep = std::acos(1.0 - ratio);
    if (!(halfStep > 0.0) || !std::isfinite(halfStep)) {
        return kMaxCirclePolygonSegments;
    }
    const double rawNeeded = std::ceil(3.14159265358979323846 / halfStep);
    if (!std::isfinite(rawNeeded) || rawNeeded >= static_cast<double>(kMaxCirclePolygonSegments)) {
        return kMaxCirclePolygonSegments;
    }
    int seg = std::max(kMinCirclePolygonSegments, static_cast<int>(rawNeeded));
    seg = ((seg + 3) / 4) * 4;
    return std::min(kMaxCirclePolygonSegments, seg);
}

struct OasisError : std::runtime_error {
    explicit OasisError(const std::string& msg) : std::runtime_error(msg) {}
};

/** real → 文本：%.17g 保证 double 可无损回转（OASIS 属性值在内存中以文本保真） */
std::string RealToText(double v) {
    if (!std::isfinite(v)) {
        return "0";
    }
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%.17g", v);
    return std::string(buf);
}

struct GDelta {
    int64_t x = 0;
    int64_t y = 0;
};

bool RepetitionProduct(int64_t value, uint64_t count, int64_t& product) {
    if (count == 0) { product = 0; return true; }
    const int64_t factor = static_cast<int64_t>(count); // Repetition dimensions are capped at 2^20.
    if ((value > 0 && value > INT64_MAX / factor) ||
        (value < 0 && value < INT64_MIN / factor)) return false;
    product = value * factor;
    return true;
}

double RepetitionOffset(uint64_t column, int64_t columnStep, uint64_t row, int64_t rowStep) {
    int64_t a = 0, b = 0;
    if (RepetitionProduct(columnStep, column, a) && RepetitionProduct(rowStep, row, b) &&
        !((b > 0 && a > INT64_MAX - b) || (b < 0 && a < INT64_MIN - b))) {
        // Add signed offsets before converting to double, preserving cancellation near 2^53.
        return static_cast<double>(a + b);
    }
    // Public coordinates are doubles. Avoid signed UB if an expanded span exceeds int64.
    return static_cast<double>(column) * columnStep + static_cast<double>(row) * rowStep;
}

/** Regular repetitions keep their owner-coordinate lattice; irregular ones keep offsets. */
struct Repetition {
    std::vector<GDelta> offsets;
    bool regular = false;
    uint64_t columns = 1;
    uint64_t rows = 1;
    GDelta columnStep;
    GDelta rowStep;
    bool valid = false;

    uint64_t count() const {
        return regular ? columns * rows : static_cast<uint64_t>(offsets.size());
    }
};

/** modal 状态（每个 CELL 记录开始时复位） */
struct ModalState {
    bool xyRelative = false;

    int64_t placementX = 0;
    int64_t placementY = 0;
    int64_t geometryX = 0;
    int64_t geometryY = 0;
    int64_t textX = 0;
    int64_t textY = 0;

    uint64_t layer = 0;
    bool layerSet = false;
    uint64_t datatype = 0;
    bool datatypeSet = false;
    uint64_t textLayer = 0;
    bool textLayerSet = false;
    uint64_t textType = 0;
    bool textTypeSet = false;

    // placement-cell：literal 或待回填 refnum
    std::string placementCellName;
    uint64_t placementCellRef = 0;
    bool placementCellIsRef = false;
    bool placementCellSet = false;

    // text-string：literal 或待回填 refnum
    std::string textString;
    uint64_t textStringRef = 0;
    bool textStringIsRef = false;
    bool textStringSet = false;

    uint64_t geometryW = 0;
    bool geometryWSet = false;
    uint64_t geometryH = 0;
    bool geometryHSet = false;

    uint64_t pathHalfWidth = 0;
    bool pathHalfWidthSet = false;
    int64_t pathStartExt = 0;
    int64_t pathEndExt = 0;
    bool pathExtSet = false;

    std::vector<GDelta> polygonPointList;
    bool polygonPointListSet = false;
    std::vector<GDelta> pathPointList;
    bool pathPointListSet = false;

    uint64_t ctrapType = 0;
    bool ctrapTypeSet = false;
    uint64_t circleRadius = 0;
    bool circleRadiusSet = false;

    Repetition repetition;
};

/** 流帧：顶层文件缓冲或 CBLOCK 解压缓冲 */
struct StreamFrame {
    std::vector<uint8_t> owned; // CBLOCK 解压数据；顶层帧为空（引用外部）
    const uint8_t* data = nullptr;
    size_t size = 0;
    size_t pos = 0;
};

// ==================== 解析会话 ====================

class Parser {
public:
    Parser(std::string filePath, bool collectShapes, const NativeJobControl* control)
        : filePath_(std::move(filePath)), collectShapes_(collectShapes), control_(control) {}

    GdsiiParseResult run() {
        try {
            if (!readFile()) return buildResult(false, "无法打开文件: " + filePath_);
            checkMagic();
            parseRecords();
            if (control_) control_->report("resolving");
            resolveNames();
        } catch (const NativeJobCancelled&) {
            throw;
        } catch (const OasisError& e) {
            return buildResult(false, e.what());
        } catch (const std::exception& e) {
            return buildResult(false, std::string("OASIS 解析异常: ") + e.what());
        } catch (...) {
            return buildResult(false, "OASIS 解析异常");
        }
        return buildResult(true);
    }

private:
    // ---------- 输入 ----------
    std::string filePath_;
    bool collectShapes_;
    const NativeJobControl* control_ = nullptr;
    uint64_t readTicks_ = 0;
    std::vector<uint8_t> fileBuf_;
    size_t fileSize_ = 0;
    std::vector<StreamFrame> frames_;

    // ---------- 名称表 ----------
    std::map<uint64_t, std::string> cellNameTable_;
    std::map<uint64_t, std::string> textStringTable_;
    std::map<uint64_t, std::string> propNameTable_;
    std::map<uint64_t, std::string> propStringTable_;
    uint64_t implicitCellName_ = 0;
    uint64_t implicitTextString_ = 0;
    uint64_t implicitPropName_ = 0;
    uint64_t implicitPropString_ = 0;

    // ---------- 文档状态 ----------
    std::string libName_ = "OASIS_LIB";
    double physicalUnit_ = 1e-9; // 米 / 数据库单位
    bool offsetTableInEnd_ = false; // START offset-flag==1 → 偏移表在 END 记录内
    std::vector<CellInfo> cells_;
    std::vector<LayoutShape> shapes_;
    std::vector<LayerInfo> allLayers_;
    std::vector<SourceLayerDefinition> layerDefinitions_;
    int64_t totalElements_ = 0;
    int nextShapeId_ = 1;
    int currentCell_ = -1;
    ModalState modal_;

    // 前向引用回填
    struct PendingRef {
        size_t index; // cells_ 或 shapes_ 下标
        uint64_t refnum;
    };
    std::vector<PendingRef> pendingCellNames_;      // cells_[i].name
    std::vector<PendingRef> pendingPlacementCells_; // shapes_[i].cellName
    std::vector<PendingRef> pendingTexts_;          // shapes_[i].text

    // ---------- 属性（PROPERTY 记录 28） ----------
    // OASIS 元素属性紧跟所属元素，而本 reader 在几何记录内即已发射图形，
    // 故记录最近一个元素在 shapes_ 中的区间，PROPERTY 到来时回贴到这些图形上。
    size_t lastEmitBegin_ = 0;
    size_t lastEmitCount_ = 0;
    /// V 位（值列表省略）复用：上一条 PROPERTY 解析出的值序列
    std::vector<LayoutProperty> modalProps_;
    std::string modalPropertyName_;
    bool modalPropertyNameSet_=false;
    bool modalPropertyValuesSet_=false;
    bool modalPropertyStandard_=false;
    enum class PropertyTarget { Document, Cell, Element, None };
    PropertyTarget propertyTarget_=PropertyTarget::Document;
    /// 数据库级一般属性（首个 CELL 之前的 PROPERTY）
    std::vector<LayoutProperty> libProps_;
    std::vector<std::string> layoutContextRecords_;
    std::vector<std::vector<std::string>> cellContextRecords_;
    size_t propertyBytesStored_ = 0;

    // ==================== 底层读取 ====================

    bool readFile() {
        if (control_) control_->report("reading");
        std::ifstream file(filePath_, std::ios::binary | std::ios::ate);
        if (!file.is_open()) {
            return false;
        }
        const int64_t size = static_cast<int64_t>(file.tellg());
        if (size < 0 || size > kMaxFileSize) {
            return false;
        }
        fileSize_ = static_cast<size_t>(size);
        file.seekg(0, std::ios::beg);
        fileBuf_.resize(fileSize_);
        for (size_t offset = 0; offset < fileSize_;) {
            if (control_) control_->report("reading", offset, fileSize_);
            const size_t chunk = std::min<size_t>(1024 * 1024, fileSize_ - offset);
            if (!file.read(reinterpret_cast<char*>(fileBuf_.data() + offset), static_cast<std::streamsize>(chunk))) return false;
            offset += chunk;
        }
        StreamFrame top;
        top.data = fileBuf_.data();
        top.size = fileBuf_.size();
        top.pos = 0;
        frames_.clear();
        frames_.push_back(std::move(top));
        return true;
    }

    StreamFrame& frame() { return frames_.back(); }

    bool insideCblock() const { return frames_.size() > 1; }

    /** 记录边界处调用：弹出已耗尽的 CBLOCK 帧 */
    void popExhaustedFrames() {
        while (frames_.size() > 1 && frames_.back().pos >= frames_.back().size) {
            frames_.pop_back();
        }
    }

    bool atTopEof() {
        popExhaustedFrames();
        return frames_.size() == 1 && frames_.back().pos >= frames_.back().size;
    }

    uint8_t readByte() {
        if (control_ && (++readTicks_ & 1023) == 0) control_->check();
        StreamFrame& f = frame();
        if (f.pos >= f.size) {
            throw OasisError("OASIS 文件截断（记录中途结束）");
        }
        return f.data[f.pos++];
    }

    /** 变长无符号整数；>10 字节视为损坏 */
    uint64_t readUnsigned() {
        uint64_t value = 0;
        int shift = 0;
        for (int i = 0; i < 10; i++) {
            const uint8_t b = readByte();
            value |= static_cast<uint64_t>(b & 0x7F) << shift;
            if ((b & 0x80) == 0) {
                return value;
            }
            shift += 7;
        }
        throw OasisError("变长整数超长（文件损坏，offset=" + std::to_string(frame().pos) + "）");
    }

    int64_t readSigned() {
        const uint64_t raw = readUnsigned();
        const int64_t magnitude = static_cast<int64_t>(raw >> 1);
        return (raw & 1u) != 0 ? -magnitude : magnitude;
    }

    /** OASIS real：8 种编码 */
    double readRealOfType(uint64_t type) {
        switch (type) {
            case 0:
                return static_cast<double>(readUnsigned());
            case 1:
                return -static_cast<double>(readUnsigned());
            case 2: {
                const double d = static_cast<double>(readUnsigned());
                if (d == 0.0) {
                    throw OasisError("real 倒数分母为 0");
                }
                return 1.0 / d;
            }
            case 3: {
                const double d = static_cast<double>(readUnsigned());
                if (d == 0.0) {
                    throw OasisError("real 倒数分母为 0");
                }
                return -1.0 / d;
            }
            case 4: {
                const double a = static_cast<double>(readUnsigned());
                const double b = static_cast<double>(readUnsigned());
                if (b == 0.0) {
                    throw OasisError("real 比值分母为 0");
                }
                return a / b;
            }
            case 5: {
                const double a = static_cast<double>(readUnsigned());
                const double b = static_cast<double>(readUnsigned());
                if (b == 0.0) {
                    throw OasisError("real 比值分母为 0");
                }
                return -a / b;
            }
            case 6: {
                uint32_t bits = 0;
                for (int i = 0; i < 4; i++) {
                    bits |= static_cast<uint32_t>(readByte()) << (i * 8);
                }
                float f = 0.0f;
                std::memcpy(&f, &bits, sizeof(f));
                return static_cast<double>(f);
            }
            case 7: {
                uint64_t bits = 0;
                for (int i = 0; i < 8; i++) {
                    bits |= static_cast<uint64_t>(readByte()) << (i * 8);
                }
                double d = 0.0;
                std::memcpy(&d, &bits, sizeof(d));
                return d;
            }
            default:
                throw OasisError("未知 real 编码类型 " + std::to_string(type));
        }
    }

    double readReal() { return readRealOfType(readUnsigned()); }

    std::string readString() {
        const uint64_t len = readUnsigned();
        StreamFrame& f = frame();
        if (len > f.size - f.pos) {
            throw OasisError("字符串长度越界（文件损坏）");
        }
        std::string s(reinterpret_cast<const char*>(f.data + f.pos), static_cast<size_t>(len));
        f.pos += static_cast<size_t>(len);
        return s;
    }

    // ==================== 文件级解析 ====================

    void checkMagic() {
        static const char kMagic[] = "%SEMI-OASIS\r\n";
        const size_t magicLen = sizeof(kMagic) - 1;
        StreamFrame& f = frame();
        if (f.size < magicLen || std::memcmp(f.data, kMagic, magicLen) != 0) {
            throw OasisError("无效的 OASIS 文件签名（应为 %SEMI-OASIS）");
        }
        f.pos = magicLen;
    }

    void parseRecords() {
        bool startSeen = false;
        while (!atTopEof()) {
            if (control_) control_->report("parsing", frames_.front().pos, fileSize_);
            const uint64_t rec = readUnsigned();
            if (!startSeen && rec != 1 && rec != 0) {
                throw OasisError("OASIS 首记录必须为 START");
            }
            if((rec>=3&&rec<=12)||(rec>=30&&rec<=33))propertyTarget_=PropertyTarget::None;
            else if(rec==13||rec==14)propertyTarget_=PropertyTarget::Cell;
            else if(rec>=17&&rec<=27)propertyTarget_=PropertyTarget::Element;
            switch (rec) {
                case 0: // PAD
                    break;
                case 1: // START
                    parseStart();
                    startSeen = true;
                    break;
                case 2: // END
                    validateEndRecord();
                    return;
                case 3:
                    cellNameTable_[implicitCellName_++] = readString();
                    break;
                case 4: {
                    std::string name = readString();
                    const uint64_t ref = readUnsigned();
                    cellNameTable_[ref] = std::move(name);
                    break;
                }
                case 5:
                    textStringTable_[implicitTextString_++] = readString();
                    break;
                case 6: {
                    std::string s = readString();
                    const uint64_t ref = readUnsigned();
                    textStringTable_[ref] = std::move(s);
                    break;
                }
                case 7:
                    propNameTable_[implicitPropName_++] = readString();
                    break;
                case 8: {
                    std::string s = readString();
                    const uint64_t ref = readUnsigned();
                    propNameTable_[ref] = std::move(s);
                    break;
                }
                case 9:
                    propStringTable_[implicitPropString_++] = readString();
                    break;
                case 10: {
                    std::string s = readString();
                    const uint64_t ref = readUnsigned();
                    propStringTable_[ref] = std::move(s);
                    break;
                }
                case 11: // LAYERNAME (geometry)
                case 12: // LAYERNAME (text)
                    parseLayerName(rec == 12);
                    break;
                case 13: { // CELL by refnum
                    const uint64_t ref = readUnsigned();
                    beginCell();
                    auto it = cellNameTable_.find(ref);
                    if (it != cellNameTable_.end()) {
                        cells_.back().name = it->second;
                    } else {
                        cells_.back().name = "CELL_" + std::to_string(ref);
                        pendingCellNames_.push_back({cells_.size() - 1, ref});
                    }
                    break;
                }
                case 14: { // CELL by name
                    std::string name = readString();
                    beginCell();
                    cells_.back().name = std::move(name);
                    break;
                }
                case 15: // XYABSOLUTE
                    modal_.xyRelative = false;
                    break;
                case 16: // XYRELATIVE
                    modal_.xyRelative = true;
                    break;
                case 17:
                    parsePlacement(false);
                    break;
                case 18:
                    parsePlacement(true);
                    break;
                case 19:
                    parseText();
                    break;
                case 20:
                    parseRectangle();
                    break;
                case 21:
                    parsePolygon();
                    break;
                case 22:
                    parsePath();
                    break;
                case 23:
                    parseTrapezoid(true, true);
                    break;
                case 24:
                    parseTrapezoid(true, false);
                    break;
                case 25:
                    parseTrapezoid(false, true);
                    break;
                case 26:
                    parseCTrapezoid();
                    break;
                case 27:
                    parseCircle();
                    break;
                case 28:
                    parseProperty();
                    break;
                case 29:
                    if(!modalPropertyNameSet_||!modalPropertyValuesSet_)throw OasisError("PROPERTY29 modal undefined");
                    attachProperties(modalProps_,128);
                    break;
                case 30: // XNAME（隐式 refnum）
                    (void)readUnsigned();
                    (void)readString();
                    break;
                case 31: // XNAME + refnum
                    (void)readUnsigned();
                    (void)readString();
                    (void)readUnsigned();
                    break;
                case 32: // XELEMENT
                    (void)readUnsigned();
                    (void)readString();
                    break;
                case 33:
                    parseXGeometry();
                    break;
                case 34:
                    parseCBlock();
                    break;
                default:
                    throw OasisError("未知 OASIS 记录类型 " + std::to_string(rec));
            }
        }
        // 容忍缺失 END（宽松处理，与 GDSII reader 行为一致）
    }

    void parseStart() {
        const std::string version = readString();
        (void)version;
        // unit：每微米的数据库单位数（如 1000 → 1nm）
        const double unitsPerMicron = readReal();
        if (!std::isfinite(unitsPerMicron) || unitsPerMicron <= 0.0) {
            throw OasisError("START 记录 unit 非法");
        }
        physicalUnit_ = 1e-6 / unitsPerMicron;
        const uint64_t offsetFlag = readUnsigned();
        if (offsetFlag == 0) {
            // 偏移表内联：6 个 (is-strict, offset) 对
            for (int i = 0; i < 12; i++) {
                (void)readUnsigned();
            }
        }
        // offsetFlag==1：偏移表在 END（顺序扫描不需要，但 END 校验解析需知晓）
        offsetTableInEnd_ = (offsetFlag == 1);
    }

    void parseLayerName(bool textLayer) {
        SourceLayerDefinition definition;
        definition.name = readString();
        definition.textLayer = textLayer;
        definition.layer = readInterval();
        definition.datatype = readInterval();
        if (layerDefinitions_.size() >= 100000) throw OasisError("LAYERNAME 定义超过预算");
        layerDefinitions_.push_back(std::move(definition));
    }

    /**
     * END 记录校验（SEMI P39）：END 从记录字节起必须恰为 256 字节，
     * 结构为 [偏移表(若 START 声明)] padding-string validation-scheme [4 字节签名]。
     * scheme 1=CRC32、2=checksum32，覆盖文件首字节至 scheme 字节（含）。
     * 非 256 字节的 END（遗留/手工文件）宽松跳过校验。
     */
    void validateEndRecord() {
        if (insideCblock()) {
            throw OasisError("END 记录不允许出现在 CBLOCK 内");
        }
        StreamFrame& f = frame();
        const size_t endStart = f.pos - 1; // '2' 记录字节位置
        if (f.size - endStart != 256) {
            return; // 非标准长度 END：跳过校验（宽松）
        }
        if (offsetTableInEnd_) {
            for (int i = 0; i < 12; i++) {
                (void)readUnsigned();
            }
        }
        // P39 permits the padding string's zero length to use redundant varint
        // zero groups to make END exactly 256 bytes (KLayout uses this form).
        uint64_t paddingSize=0;unsigned paddingShift=0;bool paddingDone=false;
        for(size_t i=0;i<256&&f.pos<f.size;++i){
            const uint8_t byte=readByte();const uint64_t group=byte&127;
            if(paddingShift>=64){if(group!=0)throw OasisError("END padding length overflow");}
            else {if(paddingShift==63&&group>1)throw OasisError("END padding length overflow");paddingSize|=group<<paddingShift;}
            if(!(byte&128)){paddingDone=true;break;}
            paddingShift=std::min<unsigned>(64,paddingShift+7);
        }
        if(!paddingDone||paddingSize>f.size-f.pos)throw OasisError("END padding truncated");
        f.pos+=static_cast<size_t>(paddingSize);
        const uint64_t scheme = readUnsigned();
        if (scheme == 0) {
            return;
        }
        if (scheme > 2) {
            throw OasisError("END 校验方案非法 " + std::to_string(scheme));
        }
        if (f.size - f.pos != 4) {
            throw OasisError("END 校验签名长度错误");
        }
        const uint32_t stored = static_cast<uint32_t>(f.data[f.pos]) |
                                (static_cast<uint32_t>(f.data[f.pos + 1]) << 8) |
                                (static_cast<uint32_t>(f.data[f.pos + 2]) << 16) |
                                (static_cast<uint32_t>(f.data[f.pos + 3]) << 24);
        const uint32_t actual = (scheme == 1)
            ? checksums::Crc32(f.data, f.pos, control_ ? control_->checkpoint : nullptr)
            : checksums::Checksum32(f.data, f.pos, control_ ? control_->checkpoint : nullptr);
        if (stored != actual) {
            throw OasisError(scheme == 1 ? "OASIS CRC32 校验不匹配（文件损坏）"
                                         : "OASIS checksum 校验不匹配（文件损坏）");
        }
    }

    LayerNameInterval readInterval() {
        LayerNameInterval interval;
        const uint64_t type = readUnsigned();
        interval.type = static_cast<uint32_t>(type);
        const auto bound = [&]() {
            const uint64_t value = readUnsigned();
            if (value > UINT32_MAX) throw OasisError("LAYERNAME interval 越界");
            return static_cast<uint32_t>(value);
        };
        switch (type) {
            case 0:
                break;
            case 1: interval.upper = bound(); break;
            case 2: interval.lower = bound(); break;
            case 3: interval.lower = bound(); interval.upper = interval.lower; break;
            case 4:
                interval.lower = bound();
                interval.upper = bound();
                if (interval.lower > interval.upper) throw OasisError("LAYERNAME interval 上下界颠倒");
                break;
            default:
                throw OasisError("LAYERNAME interval 类型非法");
        }
        return interval;
    }

    void beginCell() {
        CellInfo cell;
        cell.elementCount = 0;
        cells_.push_back(std::move(cell));
        currentCell_ = static_cast<int>(cells_.size()) - 1;
        modal_ = ModalState(); // 每 Cell modal 复位（含 xy-mode → absolute）
        // 元素属性只能贴到本 Cell 内的元素：新 Cell 必须清空回贴窗口与 modal 值列表
        lastEmitBegin_ = shapes_.size();
        lastEmitCount_ = 0;
        modalProps_.clear();modalPropertyName_.clear();modalPropertyNameSet_=false;modalPropertyValuesSet_=false;modalPropertyStandard_=false;
    }

    // ==================== 坐标 / 点列表 / repetition ====================

    /** 按 xy-mode 读取显式坐标并更新对应 modal 值 */
    void applyXY(bool hasX, bool hasY, int64_t& mx, int64_t& my) {
        if (hasX) {
            const int64_t v = readSigned();
            mx = modal_.xyRelative ? mx + v : v;
        }
        if (hasY) {
            const int64_t v = readSigned();
            my = modal_.xyRelative ? my + v : v;
        }
    }

    GDelta readGDelta() {
        const uint64_t u = readUnsigned();
        GDelta d;
        if ((u & 1u) == 0) {
            // 单整数形式：八方向 + 幅值
            const uint64_t dir = (u >> 1) & 7u;
            const int64_t m = static_cast<int64_t>(u >> 4);
            switch (dir) {
                case 0: d.x = m; d.y = 0; break;          // E
                case 1: d.x = 0; d.y = m; break;          // N
                case 2: d.x = -m; d.y = 0; break;         // W
                case 3: d.x = 0; d.y = -m; break;         // S
                case 4: d.x = m; d.y = m; break;          // NE
                case 5: d.x = -m; d.y = m; break;         // NW
                case 6: d.x = -m; d.y = -m; break;        // SW
                default: d.x = m; d.y = -m; break;        // SE
            }
        } else {
            // 双整数形式：x 内嵌符号，y 为标准有符号整数
            const int64_t mag = static_cast<int64_t>(u >> 2);
            d.x = (u & 2u) != 0 ? -mag : mag;
            d.y = readSigned();
        }
        return d;
    }

    /**
     * 点列表：type + count + deltas。
     * 返回相对首顶点的顶点列表（首元素恒为 (0,0)）。
     * forPolygon 时对 1-delta 列表补隐式闭合顶点。
     */
    std::vector<GDelta> readPointList(bool forPolygon) {
        const uint64_t type = readUnsigned();
        const uint64_t count = readUnsigned();
        if (count > kMaxPointCount) {
            throw OasisError("点列表过大（超过 DoS 上限）");
        }
        std::vector<GDelta> pts;
        pts.reserve(static_cast<size_t>(count) + 2);
        pts.push_back({0, 0});
        int64_t x = 0;
        int64_t y = 0;
        switch (type) {
            case 0:   // 1-delta，水平先行
            case 1: { // 1-delta，垂直先行
                bool horizontal = (type == 0);
                for (uint64_t i = 0; i < count; i++) {
                    const int64_t d = readSigned();
                    if (horizontal) {
                        x += d;
                    } else {
                        y += d;
                    }
                    pts.push_back({x, y});
                    horizontal = !horizontal;
                }
                if (forPolygon && count > 0) {
                    // 曼哈顿隐式闭合：补一个隐式拐角顶点回到首点；
                    // 若隐式顶点与首点重合（路径已对齐），则无需额外顶点
                    const bool lastWasHorizontal =
                        (type == 0) ? (count % 2 == 1) : (count % 2 == 0);
                    const GDelta closing = lastWasHorizontal ? GDelta{x, 0} : GDelta{0, y};
                    if (closing.x != 0 || closing.y != 0) {
                        pts.push_back(closing);
                    }
                }
                break;
            }
            case 2: { // 2-delta：四方向
                for (uint64_t i = 0; i < count; i++) {
                    const uint64_t u = readUnsigned();
                    const int64_t m = static_cast<int64_t>(u >> 2);
                    switch (u & 3u) {
                        case 0: x += m; break;
                        case 1: y += m; break;
                        case 2: x -= m; break;
                        default: y -= m; break;
                    }
                    pts.push_back({x, y});
                }
                break;
            }
            case 3: { // 3-delta：八方向
                for (uint64_t i = 0; i < count; i++) {
                    const uint64_t u = readUnsigned();
                    const int64_t m = static_cast<int64_t>(u >> 3);
                    switch (u & 7u) {
                        case 0: x += m; break;
                        case 1: y += m; break;
                        case 2: x -= m; break;
                        case 3: y -= m; break;
                        case 4: x += m; y += m; break;
                        case 5: x -= m; y += m; break;
                        case 6: x -= m; y -= m; break;
                        default: x += m; y -= m; break;
                    }
                    pts.push_back({x, y});
                }
                break;
            }
            case 4: { // g-delta
                for (uint64_t i = 0; i < count; i++) {
                    const GDelta g = readGDelta();
                    x += g.x;
                    y += g.y;
                    pts.push_back({x, y});
                }
                break;
            }
            case 5: { // 双 g-delta（二阶差分）
                GDelta run{0, 0};
                for (uint64_t i = 0; i < count; i++) {
                    const GDelta g = readGDelta();
                    run.x += g.x;
                    run.y += g.y;
                    x += run.x;
                    y += run.y;
                    pts.push_back({x, y});
                }
                break;
            }
            default:
                throw OasisError("点列表类型非法 " + std::to_string(type));
        }
        return pts;
    }

    Repetition noRepetition() {
        Repetition r;
        r.valid = true;
        r.offsets.push_back({0, 0});
        return r;
    }

    void guardRepetition(uint64_t n) {
        if (n > kMaxRepetition) {
            throw OasisError("repetition 展开数过大（超过 DoS 上限）");
        }
    }

    uint64_t readRepetitionDimension() {
        const uint64_t encoded = readUnsigned();
        if (encoded > kMaxRepetition - 2) {
            throw OasisError("repetition 展开数过大（超过 DoS 上限）");
        }
        return encoded + 2;
    }

    int64_t readRepetitionSpacing() {
        const uint64_t spacing = readUnsigned();
        if (spacing > static_cast<uint64_t>(INT64_MAX)) {
            throw OasisError("repetition 间距超过坐标范围");
        }
        return static_cast<int64_t>(spacing);
    }

    Repetition readRepetition() {
        const uint64_t type = readUnsigned();
        if (type == 0) {
            if (!modal_.repetition.valid) {
                throw OasisError("repetition 复用 modal 但 modal 未定义");
            }
            return modal_.repetition;
        }
        Repetition rep;
        rep.valid = true;
        switch (type) {
            case 1: {
                const uint64_t nx = readRepetitionDimension();
                const uint64_t ny = readRepetitionDimension();
                const int64_t dx = readRepetitionSpacing();
                const int64_t dy = readRepetitionSpacing();
                guardRepetition(nx * ny);
                rep.regular = true;
                rep.columns = nx;
                rep.rows = ny;
                rep.columnStep = {dx, 0};
                rep.rowStep = {0, dy};
                break;
            }
            case 2: {
                const uint64_t n = readRepetitionDimension();
                const int64_t dx = readRepetitionSpacing();
                guardRepetition(n);
                rep.regular = true;
                rep.columns = n;
                rep.columnStep = {dx, 0};
                break;
            }
            case 3: {
                const uint64_t n = readRepetitionDimension();
                const int64_t dy = readRepetitionSpacing();
                guardRepetition(n);
                rep.regular = true;
                rep.rows = n;
                rep.rowStep = {0, dy};
                break;
            }
            case 4:
            case 5: {
                const uint64_t n = readRepetitionDimension();
                guardRepetition(n);
                const int64_t grid = (type == 5) ? static_cast<int64_t>(readUnsigned()) : 1;
                int64_t acc = 0;
                rep.offsets.push_back({0, 0});
                for (uint64_t i = 1; i < n; i++) {
                    acc += static_cast<int64_t>(readUnsigned()) * grid;
                    rep.offsets.push_back({acc, 0});
                }
                break;
            }
            case 6:
            case 7: {
                const uint64_t n = readRepetitionDimension();
                guardRepetition(n);
                const int64_t grid = (type == 7) ? static_cast<int64_t>(readUnsigned()) : 1;
                int64_t acc = 0;
                rep.offsets.push_back({0, 0});
                for (uint64_t i = 1; i < n; i++) {
                    acc += static_cast<int64_t>(readUnsigned()) * grid;
                    rep.offsets.push_back({0, acc});
                }
                break;
            }
            case 8: {
                const uint64_t n = readRepetitionDimension();
                const uint64_t m = readRepetitionDimension();
                const GDelta g1 = readGDelta();
                const GDelta g2 = readGDelta();
                guardRepetition(n * m);
                rep.regular = true;
                rep.columns = n;
                rep.rows = m;
                rep.columnStep = g1;
                rep.rowStep = g2;
                break;
            }
            case 9: {
                const uint64_t n = readRepetitionDimension();
                const GDelta g = readGDelta();
                guardRepetition(n);
                rep.regular = true;
                rep.columns = n;
                rep.columnStep = g;
                break;
            }
            case 10:
            case 11: {
                const uint64_t n = readRepetitionDimension();
                guardRepetition(n);
                const int64_t grid = (type == 11) ? static_cast<int64_t>(readUnsigned()) : 1;
                GDelta acc{0, 0};
                rep.offsets.push_back({0, 0});
                for (uint64_t i = 1; i < n; i++) {
                    const GDelta g = readGDelta();
                    acc.x += g.x * grid;
                    acc.y += g.y * grid;
                    rep.offsets.push_back(acc);
                }
                break;
            }
            default:
                throw OasisError("repetition 类型非法 " + std::to_string(type));
        }
        modal_.repetition = rep;
        return rep;
    }

    // ==================== 图形发射 ====================

    void requireModal(bool condition, const char* what) {
        if (!condition) {
            throw OasisError(std::string("modal 变量未初始化: ") + what);
        }
    }

    void countLayerElements(int layerNumber, int datatype, uint64_t count) {
        for (auto& layer : allLayers_) {
            if (layer.layerNumber == layerNumber && layer.datatype == datatype) {
                layer.elementCount += static_cast<int>(count);
                return;
            }
        }
        allLayers_.push_back({layerNumber, datatype, static_cast<int>(count)});
    }

    /**
     * Regular placements retain one array; geometry and irregular placements expand.
     * Counts use expanded multiplicity; only full parsing has the 8M import guard.
     * pendingText / pendingCell：refnum 待回填时为对应表的 refnum，否则为 -1。
     */
    void emitShapes(const LayoutShape& base, const Repetition& rep,
                    bool countLayer, int64_t pendingTextRef, int64_t pendingCellRef) {
        lastEmitBegin_ = shapes_.size();
        lastEmitCount_ = 0;
        const uint64_t expanded = rep.count();
        const uint64_t countLimit = collectShapes_ ? kMaxTotalShapes : static_cast<uint64_t>(INT32_MAX);
        if (expanded > countLimit - static_cast<uint64_t>(totalElements_)) {
            if (!collectShapes_) throw OasisError("元素统计超过整数范围");
            throw OasisError("图形总数超过上限（文件过大）");
        }
        totalElements_ += static_cast<int64_t>(expanded);
        if (currentCell_ >= 0) {
            cells_[static_cast<size_t>(currentCell_)].elementCount += static_cast<int>(expanded);
        }
        if (countLayer) countLayerElements(base.layerNumber, base.datatype, expanded);
        if (!collectShapes_) return;

        auto emit = [&](LayoutShape copy, double offsetX, double offsetY) {
            if (control_) control_->check();
            if (shapes_.size() >= kMaxTotalShapes) {
                throw OasisError("图形总数超过上限（文件过大）");
            }
            copy.id = nextShapeId_++;
            for (auto& p : copy.points) {
                p.x += offsetX;
                p.y += offsetY;
            }
            shapes_.push_back(std::move(copy));
            lastEmitCount_++;
            if (pendingTextRef >= 0) {
                pendingTexts_.push_back({shapes_.size() - 1, static_cast<uint64_t>(pendingTextRef)});
            }
            if (pendingCellRef >= 0) {
                pendingPlacementCells_.push_back({shapes_.size() - 1, static_cast<uint64_t>(pendingCellRef)});
            }
        };
        if (rep.regular && base.type == "instance") {
            LayoutShape array = base;
            // Native axes follow GDS COLROW/XY: OAS first repetition axis is native row B.
            array.arrayCols = static_cast<int>(rep.rows);
            array.arrayRows = static_cast<int>(rep.columns);
            array.arrayColStepX = static_cast<double>(rep.rowStep.x);
            array.arrayColStepY = static_cast<double>(rep.rowStep.y);
            array.arrayRowStepX = static_cast<double>(rep.columnStep.x);
            array.arrayRowStepY = static_cast<double>(rep.columnStep.y);
            emit(std::move(array), 0.0, 0.0);
        } else if (rep.regular) {
            for (uint64_t row = 0; row < rep.rows; ++row) {
                for (uint64_t column = 0; column < rep.columns; ++column) {
                    emit(base, RepetitionOffset(column, rep.columnStep.x, row, rep.rowStep.x),
                         RepetitionOffset(column, rep.columnStep.y, row, rep.rowStep.y));
                }
            }
        } else {
            for (const GDelta& off : rep.offsets) emit(base, static_cast<double>(off.x), static_cast<double>(off.y));
        }
    }

    LayoutShape makeShapeBase(const char* type, int layer, int datatype) {
        LayoutShape s;
        s.id = 0;
        s.type = type;
        s.layerNumber = layer;
        s.datatype = datatype;
        s.pathWidth = 1.0;
        s.ownerCellId = currentCell_;
        s.cellId = -1;
        s.rotation = 0.0;
        s.mirror = 0;
        s.magnification = 1.0;
        return s;
    }

    // ==================== 几何记录 ====================

    void parseRectangle() {
        const uint8_t info = readByte();
        const bool S = (info & 0x80) != 0;
        const bool W = (info & 0x40) != 0;
        const bool H = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (S && H) {
            throw OasisError("RECTANGLE 方形标志与 H 字段冲突");
        }
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (W) {
            modal_.geometryW = readUnsigned();
            modal_.geometryWSet = true;
        }
        if (H) {
            modal_.geometryH = readUnsigned();
            modal_.geometryHSet = true;
        }
        if (S) {
            requireModal(modal_.geometryWSet, "geometry-w (SQUARE)");
            modal_.geometryH = modal_.geometryW;
            modal_.geometryHSet = true;
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.geometryWSet, "geometry-w");
        requireModal(modal_.geometryHSet, "geometry-h");

        LayoutShape base = makeShapeBase("rect",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        const double x0 = static_cast<double>(modal_.geometryX);
        const double y0 = static_cast<double>(modal_.geometryY);
        base.points.push_back({x0, y0});
        base.points.push_back({x0 + static_cast<double>(modal_.geometryW),
                               y0 + static_cast<double>(modal_.geometryH)});
        emitShapes(base, rep, true, -1, -1);
    }

    void parsePolygon() {
        const uint8_t info = readByte();
        const bool P = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (P) {
            modal_.polygonPointList = readPointList(true);
            modal_.polygonPointListSet = true;
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.polygonPointListSet, "polygon-point-list");
        if (modal_.polygonPointList.size() < 3) {
            throw OasisError("POLYGON 顶点数不足 3");
        }

        LayoutShape base = makeShapeBase("polygon",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        base.points.reserve(modal_.polygonPointList.size());
        for (const GDelta& p : modal_.polygonPointList) {
            base.points.push_back({static_cast<double>(modal_.geometryX + p.x),
                                   static_cast<double>(modal_.geometryY + p.y)});
        }
        emitShapes(base, rep, true, -1, -1);
    }

    void parsePath() {
        const uint8_t info = readByte();
        const bool E = (info & 0x80) != 0;
        const bool W = (info & 0x40) != 0;
        const bool P = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (W) {
            modal_.pathHalfWidth = readUnsigned();
            modal_.pathHalfWidthSet = true;
        }
        if (E) {
            const uint64_t scheme = readUnsigned();
            const uint64_t ss = (scheme >> 2) & 3u;
            const uint64_t ee = scheme & 3u;
            if (ss == 1) {
                modal_.pathStartExt = 0;
            } else if (ss == 2) {
                modal_.pathStartExt = static_cast<int64_t>(modal_.pathHalfWidth);
            } else if (ss == 3) {
                modal_.pathStartExt = readSigned();
            }
            if (ee == 1) {
                modal_.pathEndExt = 0;
            } else if (ee == 2) {
                modal_.pathEndExt = static_cast<int64_t>(modal_.pathHalfWidth);
            } else if (ee == 3) {
                modal_.pathEndExt = readSigned();
            }
            modal_.pathExtSet = true;
        }
        if (P) {
            modal_.pathPointList = readPointList(false);
            modal_.pathPointListSet = true;
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.pathHalfWidthSet, "path-halfwidth");
        requireModal(modal_.pathPointListSet, "path-point-list");
        if (modal_.pathPointList.size() < 2) {
            throw OasisError("PATH 顶点数不足 2");
        }

        LayoutShape base = makeShapeBase("path",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        base.pathWidth = static_cast<double>(modal_.pathHalfWidth) * 2.0;
        base.pathType = (modal_.pathStartExt != 0 || modal_.pathEndExt != 0) ? 4 : 0;
        base.pathBeginExtension = static_cast<double>(modal_.pathStartExt);
        base.pathEndExtension = static_cast<double>(modal_.pathEndExt);
        base.points.reserve(modal_.pathPointList.size());
        for (const GDelta& p : modal_.pathPointList) {
            base.points.push_back({static_cast<double>(modal_.geometryX + p.x),
                                   static_cast<double>(modal_.geometryY + p.y)});
        }
        // Explicit signed lengths are converted from DBU to nm in buildResult().
        emitShapes(base, rep, true, -1, -1);
    }

    /** TRAPEZOID 23/24/25：hasDeltaA/hasDeltaB 标识记录变体 */
    void parseTrapezoid(bool hasDeltaA, bool hasDeltaB) {
        const uint8_t info = readByte();
        const bool O = (info & 0x80) != 0; // 1=垂直（平行边为竖直）
        const bool W = (info & 0x40) != 0;
        const bool H = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (W) {
            modal_.geometryW = readUnsigned();
            modal_.geometryWSet = true;
        }
        if (H) {
            modal_.geometryH = readUnsigned();
            modal_.geometryHSet = true;
        }
        int64_t da = 0;
        int64_t db = 0;
        if (hasDeltaA) {
            da = readSigned();
        }
        if (hasDeltaB) {
            db = readSigned();
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.geometryWSet, "geometry-w");
        requireModal(modal_.geometryHSet, "geometry-h");

        const double w = static_cast<double>(modal_.geometryW);
        const double h = static_cast<double>(modal_.geometryH);
        const double gx = static_cast<double>(modal_.geometryX);
        const double gy = static_cast<double>(modal_.geometryY);
        const double dda = static_cast<double>(da);
        const double ddb = static_cast<double>(db);

        LayoutShape base = makeShapeBase("polygon",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        if (!O) {
            // 水平：平行边为上下两条水平边
            // delta-a = 顶左相对底左的 x 位移；delta-b = 顶右相对底右的 x 位移
            base.points.push_back({gx + std::max(-dda, 0.0), gy});           // 底左
            base.points.push_back({gx + w + std::min(-ddb, 0.0), gy});       // 底右
            base.points.push_back({gx + w + std::min(ddb, 0.0), gy + h});    // 顶右
            base.points.push_back({gx + std::max(dda, 0.0), gy + h});        // 顶左
        } else {
            // 垂直：平行边为左右两条竖直边（水平情形沿对角线转置）
            base.points.push_back({gx, gy + std::max(-dda, 0.0)});           // 左下
            base.points.push_back({gx + w, gy + std::max(dda, 0.0)});        // 右下
            base.points.push_back({gx + w, gy + h + std::min(ddb, 0.0)});    // 右上
            base.points.push_back({gx, gy + h + std::min(-ddb, 0.0)});       // 左上
        }
        emitShapes(base, rep, true, -1, -1);
    }

    void parseCTrapezoid() {
        const uint8_t info = readByte();
        const bool T = (info & 0x80) != 0;
        const bool W = (info & 0x40) != 0;
        const bool H = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (T) {
            modal_.ctrapType = readUnsigned();
            modal_.ctrapTypeSet = true;
        }
        if (W) {
            modal_.geometryW = readUnsigned();
            modal_.geometryWSet = true;
        }
        if (H) {
            modal_.geometryH = readUnsigned();
            modal_.geometryHSet = true;
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.ctrapTypeSet, "ctrapezoid-type");
        const uint64_t t = modal_.ctrapType;
        if (t > 25) {
            throw OasisError("CTRAPEZOID 类型非法 " + std::to_string(t));
        }
        requireModal(modal_.geometryWSet, "geometry-w");
        // 类型 20-23（等腰直角三角形）与 25（正方形）高度隐含 = 宽度
        const bool impliedH = (t >= 20 && t <= 23) || t == 25;
        if (!impliedH) {
            requireModal(modal_.geometryHSet, "geometry-h");
        }
        const double w = static_cast<double>(modal_.geometryW);
        const double h = impliedH ? w : static_cast<double>(modal_.geometryH);

        std::vector<GDelta> rel = ctrapezoidVertices(t, static_cast<int64_t>(w), static_cast<int64_t>(h));
        LayoutShape base = makeShapeBase(t == 24 || t == 25 ? "rect" : "polygon",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        if (t == 24 || t == 25) {
            base.points.push_back({static_cast<double>(modal_.geometryX),
                                   static_cast<double>(modal_.geometryY)});
            base.points.push_back({static_cast<double>(modal_.geometryX) + w,
                                   static_cast<double>(modal_.geometryY) + h});
        } else {
            for (const GDelta& p : rel) {
                base.points.push_back({static_cast<double>(modal_.geometryX + p.x),
                                       static_cast<double>(modal_.geometryY + p.y)});
            }
        }
        emitShapes(base, rep, true, -1, -1);
    }

    /**
     * CTRAPEZOID 顶点表（类型 0-23；24/25 由调用方按矩形处理）。
     * 0-7: 水平梯形（上下边平行，45° 斜边）；8-15: 垂直梯形（0-7 沿对角线转置）；
     * 16-19: 直角三角形；20-23: 等腰直角三角形（h=w）。
     */
    std::vector<GDelta> ctrapezoidVertices(uint64_t t, int64_t w, int64_t h) {
        auto make = [](std::initializer_list<GDelta> pts) {
            return std::vector<GDelta>(pts);
        };
        switch (t) {
            case 0: return make({{0, 0}, {w, 0}, {w - h, h}, {0, h}});       // 顶右 45°
            case 1: return make({{0, 0}, {w - h, 0}, {w, h}, {0, h}});       // 底右 45°
            case 2: return make({{0, 0}, {w, 0}, {w, h}, {h, h}});           // 顶左 45°
            case 3: return make({{h, 0}, {w, 0}, {w, h}, {0, h}});           // 底左 45°
            case 4: return make({{0, 0}, {w, 0}, {w - h, h}, {h, h}});       // 顶部两角
            case 5: return make({{h, 0}, {w - h, 0}, {w, h}, {0, h}});       // 底部两角
            case 6: return make({{h, 0}, {w, 0}, {w - h, h}, {0, h}});       // 顶右+底左
            case 7: return make({{0, 0}, {w - h, 0}, {w, h}, {h, h}});       // 顶左+底右
            default:
                break;
        }
        if (t >= 8 && t <= 15) {
            // 垂直族 = 水平族沿对角线转置（(x,y)→(y,x)，w/h 互换）
            std::vector<GDelta> base = ctrapezoidVertices(t - 8, h, w);
            std::vector<GDelta> out;
            out.reserve(base.size());
            // 转置后顶点顺序反转以保持环绕方向
            for (auto it = base.rbegin(); it != base.rend(); ++it) {
                out.push_back({it->y, it->x});
            }
            return out;
        }
        switch (t) {
            case 16: return make({{0, 0}, {w, 0}, {0, h}});
            case 17: return make({{0, 0}, {w, 0}, {w, h}});
            case 18: return make({{0, 0}, {w, h}, {0, h}});
            case 19: return make({{w, 0}, {w, h}, {0, h}});
            case 20: return make({{0, 0}, {w, 0}, {0, w}});
            case 21: return make({{0, 0}, {w, 0}, {w, w}});
            case 22: return make({{0, 0}, {w, w}, {0, w}});
            case 23: return make({{w, 0}, {w, w}, {0, w}});
            default:
                return make({{0, 0}, {w, 0}, {w, h}, {0, h}});
        }
    }

    void parseCircle() {
        const uint8_t info = readByte();
        const bool r = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        if (r) {
            modal_.circleRadius = readUnsigned();
            modal_.circleRadiusSet = true;
        }
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.layerSet, "layer");
        requireModal(modal_.datatypeSet, "datatype");
        requireModal(modal_.circleRadiusSet, "circle-radius");

        const double radius = static_cast<double>(modal_.circleRadius);
        const double cx = static_cast<double>(modal_.geometryX);
        const double cy = static_cast<double>(modal_.geometryY);
        LayoutShape base = makeShapeBase("polygon",
            static_cast<int>(modal_.layer), static_cast<int>(modal_.datatype));
        const int circleSegments = AdaptiveCircleSegments(radius, physicalUnit_);
        base.points.reserve(static_cast<size_t>(circleSegments));
        for (int i = 0; i < circleSegments; i++) {
            const double a = 2.0 * 3.14159265358979323846 * i / circleSegments;
            base.points.push_back({cx + radius * std::cos(a), cy + radius * std::sin(a)});
        }
        emitShapes(base, rep, true, -1, -1);
    }

    void parseText() {
        const uint8_t info = readByte();
        const bool C = (info & 0x40) != 0;
        const bool N = (info & 0x20) != 0;
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool T = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        if (C) {
            if (N) {
                modal_.textStringRef = readUnsigned();
                modal_.textStringIsRef = true;
                auto it = textStringTable_.find(modal_.textStringRef);
                modal_.textString = (it != textStringTable_.end()) ? it->second : std::string();
            } else {
                modal_.textString = readString();
                modal_.textStringIsRef = false;
            }
            modal_.textStringSet = true;
        }
        if (L) {
            modal_.textLayer = readUnsigned();
            modal_.textLayerSet = true;
        }
        if (T) {
            modal_.textType = readUnsigned();
            modal_.textTypeSet = true;
        }
        applyXY(X, Y, modal_.textX, modal_.textY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.textStringSet, "text-string");
        requireModal(modal_.textLayerSet, "text-layer");
        requireModal(modal_.textTypeSet, "text-type");

        LayoutShape base = makeShapeBase("text",
            static_cast<int>(modal_.textLayer), static_cast<int>(modal_.textType));
        base.text = modal_.textString;
        base.points.push_back({static_cast<double>(modal_.textX),
                               static_cast<double>(modal_.textY)});
        // 字符串引用未命中时记录待回填
        const bool needsResolve = modal_.textStringIsRef && modal_.textString.empty();
        emitShapes(base, rep, true,
                   needsResolve ? static_cast<int64_t>(modal_.textStringRef) : -1, -1);
    }

    void parsePlacement(bool withMagAngle) {
        const uint8_t info = readByte();
        const bool C = (info & 0x80) != 0;
        const bool N = (info & 0x40) != 0;
        const bool X = (info & 0x20) != 0;
        const bool Y = (info & 0x10) != 0;
        const bool R = (info & 0x08) != 0;
        const bool F = (info & 0x01) != 0;

        if (C) {
            if (N) {
                modal_.placementCellRef = readUnsigned();
                modal_.placementCellIsRef = true;
                auto it = cellNameTable_.find(modal_.placementCellRef);
                modal_.placementCellName =
                    (it != cellNameTable_.end()) ? it->second : std::string();
            } else {
                modal_.placementCellName = readString();
                modal_.placementCellIsRef = false;
            }
            modal_.placementCellSet = true;
        }

        double magnification = 1.0;
        double angle = 0.0;
        if (withMagAngle) {
            if ((info & 0x04) != 0) {
                magnification = readReal();
                if (!std::isfinite(magnification) || magnification <= 0.0) {
                    magnification = 1.0;
                }
            }
            if ((info & 0x02) != 0) {
                angle = readReal();
                if (!std::isfinite(angle)) {
                    angle = 0.0;
                }
            }
        } else {
            angle = static_cast<double>((info >> 1) & 3u) * 90.0;
        }

        applyXY(X, Y, modal_.placementX, modal_.placementY);
        const Repetition rep = R ? readRepetition() : noRepetition();

        requireModal(modal_.placementCellSet, "placement-cell");

        LayoutShape base = makeShapeBase("instance", 0, 0);
        base.cellName = modal_.placementCellName.empty()
            ? ("CELL_" + std::to_string(modal_.placementCellRef))
            : modal_.placementCellName;
        base.rotation = angle;
        base.mirror = F ? 1 : 0;
        base.magnification = magnification;
        base.points.push_back({static_cast<double>(modal_.placementX),
                               static_cast<double>(modal_.placementY)});
        const bool needsResolve = modal_.placementCellIsRef && modal_.placementCellName.empty();
        emitShapes(base, rep, false, -1,
                   needsResolve ? static_cast<int64_t>(modal_.placementCellRef) : -1);
    }

    void parseXGeometry() {
        const uint8_t info = readByte();
        const bool X = (info & 0x10) != 0;
        const bool Y = (info & 0x08) != 0;
        const bool R = (info & 0x04) != 0;
        const bool D = (info & 0x02) != 0;
        const bool L = (info & 0x01) != 0;
        (void)readUnsigned(); // attribute
        if (L) {
            modal_.layer = readUnsigned();
            modal_.layerSet = true;
        }
        if (D) {
            modal_.datatype = readUnsigned();
            modal_.datatypeSet = true;
        }
        (void)readString(); // 扩展几何数据（未知语义，正确跳过）
        applyXY(X, Y, modal_.geometryX, modal_.geometryY);
        if (R) {
            (void)readRepetition();
        }
    }


    // KLayout v0.30.12 read_properties: bits 4..7=count, V=8, C=4,
    // N=2, S=1. Ownership follows the preceding record, never C.
    void parseProperty(){
        const uint8_t info=readByte();const bool explicitName=(info&4)!=0;
        if(explicitName){
            if(info&2)modalPropertyName_=std::string("\x1fNAME:")+std::to_string(readUnsigned());
            else modalPropertyName_=readString();
            modalPropertyNameSet_=true;
        }
        if(!modalPropertyNameSet_)throw OasisError("PROPERTY name modal undefined");
        modalPropertyStandard_=(info&1)!=0;
        const std::string name=modalPropertyName_;
        std::vector<LayoutProperty> props;
        if(info&8){
            if(!modalPropertyValuesSet_)throw OasisError("PROPERTY values modal undefined");
            props=modalProps_;for(auto& p:props)p.name=name;
        }else{
            const uint64_t bits=(info>>4)&15,count=bits==15?readUnsigned():bits;
            if(count>layout_context::kMaxRecords)throw OasisError("PROPERTY value count exceeds budget");
            for(uint64_t i=0;i<count;++i){
                const uint64_t kind=readUnsigned();LayoutProperty p;p.name=name;
                if(kind<=7)p.value=RealToText(readRealOfType(kind));
                else if(kind==8)p.value=std::to_string(readUnsigned());
                else if(kind==9)p.value=std::to_string(readSigned());
                else if(kind<=12)p.value=readString();
                else if(kind<=15)p.value=std::string("\x1fSTRING:")+std::to_string(readUnsigned());
                else throw OasisError("PROPERTY invalid value kind");
                p.dtype=static_cast<uint8_t>(128+kind);props.push_back(std::move(p));
            }
            if(props.empty()){LayoutProperty p;p.name=name;p.dtype=0;props.push_back(p);}
            modalPropertyValuesSet_=true;
        }
        if(modalPropertyStandard_){
            const size_t count=props.size()==1&&props[0].dtype==0?0:props.size();
            for(auto& p:props)p.name=std::string("\x1fSTD:")+std::to_string(count)+":"+p.name;
        }
        modalProps_=props;attachProperties(props,layout_context::kMaxRecords);
    }
    void attachProperties(const std::vector<LayoutProperty>& props,size_t maxPerOwner){
        if(propertyTarget_==PropertyTarget::None)return;
        auto append=[&](std::vector<LayoutProperty>& target){
            if(target.size()+props.size()>maxPerOwner)throw OasisError("PROPERTY owner budget exceeded");
            // Temporary names, standard hints and reference carriers are not raw
            // public payload. Final resolved ordinary/context budgets are checked
            // independently in buildResult before semantic decoding/publication.
            constexpr size_t transportBudget = 128u * 1024u * 1024u;
            for (const auto& p : props) { const size_t cost = p.value.size() + p.name.size() + 16; if (cost > transportBudget - std::min(propertyBytesStored_, transportBudget)) throw OasisError("PROPERTY transport byte budget exceeded"); propertyBytesStored_ += cost; }
            target.insert(target.end(),props.begin(),props.end());
        };
        if(propertyTarget_==PropertyTarget::Element){
            if(!collectShapes_)return;
            const size_t end=std::min(lastEmitBegin_+lastEmitCount_,shapes_.size());
            for(size_t i=lastEmitBegin_;i<end;++i)append(shapes_[i].properties);
        }else if(propertyTarget_==PropertyTarget::Cell&&currentCell_>=0)append(cells_[currentCell_].properties);
        else append(libProps_);
    }
    void resolveProperties(std::vector<LayoutProperty>& props, std::vector<std::string>* context = nullptr){
        std::vector<LayoutProperty> result;
        for(size_t i=0;i<props.size();++i){
            LayoutProperty p=props[i];const bool standard=p.name.rfind("\x1fSTD:",0)==0;
            size_t standardCount=0;
            if(standard){p.name.erase(0,5);const size_t colon=p.name.find(':');
                if(colon==std::string::npos)throw OasisError("Invalid standard PROPERTY list");
                standardCount=static_cast<size_t>(std::stoull(p.name.substr(0,colon)));p.name.erase(0,colon+1);
            }
            if(p.name.rfind("\x1fNAME:",0)==0){
                const auto found=propNameTable_.find(std::stoull(p.name.substr(6)));
                if(found==propNameTable_.end())throw OasisError("PROPERTY name reference missing");p.name=found->second;
            }
            if(p.dtype>=141&&p.dtype<=143){
                const auto found=propStringTable_.find(std::stoull(p.value.substr(8)));
                if(found==propStringTable_.end())throw OasisError("PROPERTY string reference missing");
                p.value=found->second;p.dtype=static_cast<uint8_t>(p.dtype-3);
            }
            if (!standard && p.name == "KLAYOUT_CONTEXT") {
                if (!context) throw OasisError("KLAYOUT_CONTEXT must belong to layout or Cell");
                if (p.dtype == 0) continue;
                if (p.dtype < 138 || p.dtype > 140 || p.value.size() > layout_context::kMaxStringBytes) throw OasisError("Invalid KLAYOUT_CONTEXT string value");
                context->push_back(std::move(p.value));
            } else if(standard&&p.name=="S_GDS_PROPERTY"){
                if(standardCount!=2||p.dtype!=136||i+1>=props.size())throw OasisError("Invalid S_GDS_PROPERTY key/list");
                const uint64_t attr=std::stoull(p.value);if(attr>32767)throw OasisError("S_GDS_PROPERTY key out of range");
                LayoutProperty value=props[++i];
                if(value.dtype>=141&&value.dtype<=143){
                    const auto found=propStringTable_.find(std::stoull(value.value.substr(8)));
                    if(found==propStringTable_.end())throw OasisError("PROPERTY string reference missing");
                    value.value=found->second;value.dtype=static_cast<uint8_t>(value.dtype-3);
                }
                value.attr=static_cast<int16_t>(attr);value.name.clear();if(value.dtype==138)value.dtype=6;
                result.push_back(std::move(value));
            }else if(standard){
                // These are regenerated structural hints, not user property data.
                const bool hint=p.name=="S_CELL_OFFSET"||p.name=="S_MAX_SIGNED_INTEGER_WIDTH"||
                    p.name=="S_MAX_UNSIGNED_INTEGER_WIDTH"||p.name=="S_TOP_CELL"||
                    p.name=="S_BOUNDING_BOXES_AVAILABLE"||p.name=="S_BOUNDING_BOX"||p.name=="S_MAX_STRING_LENGTH";
                if(!hint)throw OasisError("Unsupported standard PROPERTY "+p.name);
            }else result.push_back(std::move(p));
        }
        if(result.size()>64)throw OasisError("PROPERTY owner budget exceeded");
        props=std::move(result);
    }

    void parseCBlock() {
        if (insideCblock()) {
            throw OasisError("CBLOCK 不允许嵌套");
        }
        const uint64_t compType = readUnsigned();
        const uint64_t uncompCount = readUnsigned();
        const uint64_t compCount = readUnsigned();
        if (compType != 0) {
            throw OasisError("CBLOCK 压缩类型不支持 " + std::to_string(compType));
        }
        if (uncompCount > kMaxCblockUncompressed) {
            throw OasisError("CBLOCK 解压尺寸超过上限");
        }
        StreamFrame& f = frame();
        if (compCount > f.size - f.pos) {
            throw OasisError("CBLOCK 压缩数据越界（文件截断）");
        }
        const uint8_t* compData = f.data + f.pos;
        f.pos += static_cast<size_t>(compCount);

        StreamFrame sub;
        if (control_) control_->report("decompressing", 0, uncompCount);
#if HONGTU_OASIS_HAS_ZLIB
        {
            z_stream zs{};
            if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) {
                throw OasisError("CBLOCK zlib 初始化失败");
            }
            struct InflateGuard {
                z_stream* stream;
                ~InflateGuard() { if (stream) inflateEnd(stream); }
            } guard{&zs};

            sub.owned.resize(static_cast<size_t>(uncompCount));
            size_t inOffset = 0;
            size_t outOffset = 0;
            const size_t totalIn = static_cast<size_t>(compCount);
            const size_t totalOut = static_cast<size_t>(uncompCount);
            constexpr size_t kChunkBytes = 1024u * 1024u;
            uint8_t emptyScratch = 0;
            int zret = Z_OK;

            while (true) {
                if (control_) control_->check();
                if (zs.avail_in == 0 && inOffset < totalIn) {
                    const size_t inChunk = std::min(kChunkBytes, totalIn - inOffset);
                    zs.next_in = const_cast<Bytef*>(reinterpret_cast<const Bytef*>(compData + inOffset));
                    zs.avail_in = static_cast<uInt>(inChunk);
                    inOffset += inChunk;
                }
                if (totalOut == 0) {
                    zs.next_out = reinterpret_cast<Bytef*>(&emptyScratch);
                    zs.avail_out = 1;
                } else {
                    const size_t remOut = totalOut - outOffset;
                    const size_t outChunk = std::min(kChunkBytes, remOut);
                    zs.next_out = reinterpret_cast<Bytef*>(sub.owned.data() + outOffset);
                    zs.avail_out = static_cast<uInt>(outChunk);
                    const uInt beforeOut = zs.avail_out;
                    zret = inflate(&zs, Z_NO_FLUSH);
                    outOffset += static_cast<size_t>(beforeOut - zs.avail_out);
                }
                if (totalOut == 0) {
                    zret = inflate(&zs, Z_FINISH);
                    if (zs.avail_out != 1) {
                        throw OasisError("CBLOCK 解压长度不符");
                    }
                }
                if (zret == Z_STREAM_END) {
                    break;
                }
                if (zret != Z_OK) {
                    throw OasisError("CBLOCK DEFLATE 解压失败");
                }
                if (outOffset >= totalOut && zs.avail_in == 0 && inOffset >= totalIn) {
                    // 尝试再推一步确认流尾标记 Z_STREAM_END
                    zs.next_out = reinterpret_cast<Bytef*>(&emptyScratch);
                    zs.avail_out = 1;
                    zret = inflate(&zs, Z_FINISH);
                    if (zret == Z_STREAM_END && zs.avail_out == 1) {
                        break;
                    }
                    throw OasisError("CBLOCK DEFLATE 解压未正常结束");
                }
                if (outOffset == totalOut && (zs.avail_in > 0 || inOffset < totalIn)) {
                    zs.next_out = reinterpret_cast<Bytef*>(&emptyScratch);
                    zs.avail_out = 1;
                    zret = inflate(&zs, Z_NO_FLUSH);
                    if (zret == Z_STREAM_END && zs.avail_out == 1) {
                        break;
                    }
                    throw OasisError("CBLOCK 解压尺寸超过声明长度");
                }
            }
            if (outOffset != totalOut || zs.avail_in != 0 || inOffset != totalIn) {
                throw OasisError("CBLOCK 解压长度不符");
            }
        }
#else
        sub.owned.reserve(static_cast<size_t>(uncompCount));
        if (!tinyinflate::InflateRaw(compData, static_cast<size_t>(compCount),
                                     sub.owned, static_cast<size_t>(uncompCount),
                                     control_ ? control_->checkpoint : nullptr)) {
            throw OasisError("CBLOCK DEFLATE 解压失败");
        }
        if (sub.owned.size() != uncompCount) {
            throw OasisError("CBLOCK 解压长度不符");
        }
#endif
        sub.data = sub.owned.data();
        sub.size = sub.owned.size();
        sub.pos = 0;
        frames_.push_back(std::move(sub));
    }

    // ==================== 收尾 ====================

    void resolveNames() {
        resolveProperties(libProps_, &layoutContextRecords_);
        cellContextRecords_.resize(cells_.size());
        for(size_t i=0;i<cells_.size();++i)resolveProperties(cells_[i].properties, &cellContextRecords_[i]);
        for(auto& shape:shapes_)resolveProperties(shape.properties);
        for (const PendingRef& p : pendingCellNames_) {
            if (control_) control_->check();
            auto it = cellNameTable_.find(p.refnum);
            if (it != cellNameTable_.end() && p.index < cells_.size()) {
                cells_[p.index].name = it->second;
            }
        }
        for (const PendingRef& p : pendingPlacementCells_) {
            if (control_) control_->check();
            auto it = cellNameTable_.find(p.refnum);
            if (it != cellNameTable_.end() && p.index < shapes_.size()) {
                shapes_[p.index].cellName = it->second;
            }
        }
        for (const PendingRef& p : pendingTexts_) {
            if (control_) control_->check();
            auto it = textStringTable_.find(p.refnum);
            if (it != textStringTable_.end() && p.index < shapes_.size()) {
                shapes_[p.index].text = it->second;
            }
        }
    }

    GdsiiParseResult buildResult(bool success, const std::string& error = "") {
        // Do not expand unbounded/range declarations into millions of empty UI layers.
        // Singleton definitions explicitly retain empty layers, as KLayout does.
        for (const auto& definition : layerDefinitions_) {
            if (definition.layer.lower == definition.layer.upper &&
                definition.datatype.lower == definition.datatype.upper &&
                definition.layer.lower <= INT32_MAX && definition.datatype.lower <= INT32_MAX) {
                const int layer = static_cast<int>(definition.layer.lower);
                const int datatype = static_cast<int>(definition.datatype.lower);
                const auto found = std::find_if(allLayers_.begin(), allLayers_.end(), [&](const LayerInfo& info) {
                    return info.layerNumber == layer && info.datatype == datatype;
                });
                if (found == allLayers_.end()) allLayers_.push_back({layer, datatype, 0});
            }
        }
        for (auto& info : allLayers_) {
            info.sourceName.clear();
            for (const auto& definition : layerDefinitions_) {
                if (info.layerNumber < 0 || info.datatype < 0) continue;
                if (static_cast<uint32_t>(info.layerNumber) >= definition.layer.lower &&
                    static_cast<uint32_t>(info.layerNumber) <= definition.layer.upper &&
                    static_cast<uint32_t>(info.datatype) >= definition.datatype.lower &&
                    static_cast<uint32_t>(info.datatype) <= definition.datatype.upper) {
                    if (!info.sourceName.empty()) info.sourceName += ";";
                    info.sourceName += definition.name;
                }
            }
        }
        GdsiiParseResult result;
        result.success = success;
        result.errorMessage = error;
        result.filePath = filePath_;
        result.fileSize = static_cast<int64_t>(fileSize_);
        result.version = 0;
        result.libName = libName_;
        result.cellCount = static_cast<int>(cells_.size());
        result.totalElements = static_cast<int>(totalElements_);
        result.layerCount = static_cast<int>(allLayers_.size());
        // OASIS 无 GDS 式「用户单位」概念；沿用工程默认 0.001（1 用户单位 = 1000 dbu）
        result.userUnits = 0.001;
        result.physicalUnits = physicalUnit_;
        result.unitDescription = "1 OASIS db unit = " + std::to_string(physicalUnit_) + " m";
        // 简化：每个 Cell 的图层列表引用全局汇总（与 GDSII reader 现状一致）
        for (auto& cell : cells_) {
            cell.layers = allLayers_;
        }
        result.cells = cells_;
        result.allLayers = allLayers_;
        result.layerDefinitions = layerDefinitions_;
        result.shapes = shapes_;
        // Public/native/ArkTS geometry uses nm, irrespective of OASIS file DBU.
        const double scaleNm = physicalUnit_ * 1e9;
        for (auto& shape : result.shapes) {
            if (control_) control_->check();
            for (auto& point : shape.points) { point.x *= scaleNm; point.y *= scaleNm; }
            shape.pathWidth *= scaleNm;
            shape.pathBeginExtension *= scaleNm;
            shape.pathEndExtension *= scaleNm;
            shape.arrayColStepX *= scaleNm;
            shape.arrayColStepY *= scaleNm;
            shape.arrayRowStepX *= scaleNm;
            shape.arrayRowStepY *= scaleNm;
        }
        result.libProperties = libProps_;
        result.layoutContextRecords = layoutContextRecords_;
        result.cellContextRecords = cellContextRecords_;
        if (success) {
            try { layout_context::Validate(result); layout_context::ValidateOrdinaryProperties(result); port_codec::Decode(result); }
            catch(const std::exception& e) { result.success=false; result.errorMessage=e.what(); }
        }
        ResolveHierarchyMetadata(result, control_);
        return result;
    }
};

} // namespace

// ==================== 公共 API ====================

GdsiiParseResult OasisReader::parse(const std::string& filePath, const NativeJobControl* control) {
    Parser parser(filePath, true, control);
    return parser.run();
}

GdsiiParseResult OasisReader::quickInfo(const std::string& filePath, const NativeJobControl* control) {
    Parser parser(filePath, false, control);
    return parser.run();
}

} // namespace hongtu
