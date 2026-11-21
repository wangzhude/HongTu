/**
 * 鸿图 GDSII 文件解析器实现
 *
 * This file is part of HongTu, licensed under GPLv3.
 * Original KLayout concepts by Matthias Koefferlein.
 */

#include "gdsii_reader.h"
#include "layout_context.h"
#include "layout_port_codec.h"
#include <cmath>
#include <cstring>
#include <algorithm>
#include <sstream>
#include <iomanip>
#include <utility>

namespace hongtu {

GdsiiReader::GdsiiReader() {}

GdsiiReader::~GdsiiReader() {}

namespace {

bool SamePoint(const GdsPoint& a, const GdsPoint& b) {
    return std::abs(a.x - b.x) < 1e-9 && std::abs(a.y - b.y) < 1e-9;
}

std::vector<GdsPoint> RemoveDuplicateClosingPoint(const std::vector<GdsPoint>& points) {
    std::vector<GdsPoint> result = points;
    if (result.size() > 1 && SamePoint(result.front(), result.back())) {
        result.pop_back();
    }
    return result;
}

bool IsRectLike(const std::vector<GdsPoint>& points) {
    if (points.size() != 4) {
        return false;
    }
    double minX = points[0].x;
    double maxX = points[0].x;
    double minY = points[0].y;
    double maxY = points[0].y;
    for (const auto& p : points) {
        minX = std::min(minX, p.x);
        maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y);
        maxY = std::max(maxY, p.y);
    }
    if (std::abs(maxX - minX) < 1e-9 || std::abs(maxY - minY) < 1e-9) {
        return false;
    }
    bool hasMinMin = false;
    bool hasMinMax = false;
    bool hasMaxMin = false;
    bool hasMaxMax = false;
    for (const auto& p : points) {
        const bool isMinX = std::abs(p.x - minX) < 1e-9;
        const bool isMaxX = std::abs(p.x - maxX) < 1e-9;
        const bool isMinY = std::abs(p.y - minY) < 1e-9;
        const bool isMaxY = std::abs(p.y - maxY) < 1e-9;
        if (isMinX && isMinY) hasMinMin = true;
        if (isMinX && isMaxY) hasMinMax = true;
        if (isMaxX && isMinY) hasMaxMin = true;
        if (isMaxX && isMaxY) hasMaxMax = true;
    }
    return hasMinMin && hasMinMax && hasMaxMin && hasMaxMax;
}

std::vector<GdsPoint> RectCornersFromBounds(const std::vector<GdsPoint>& points) {
    double minX = points[0].x;
    double maxX = points[0].x;
    double minY = points[0].y;
    double maxY = points[0].y;
    for (const auto& p : points) {
        minX = std::min(minX, p.x);
        maxX = std::max(maxX, p.x);
        minY = std::min(minY, p.y);
        maxY = std::max(maxY, p.y);
    }
    return {{minX, minY}, {maxX, maxY}};
}

int ResolveCellId(const GdsiiParseResult& result, const std::string& cellName) {
    if (cellName.empty()) {
        return -1;
    }
    for (size_t i = 0; i < result.cells.size(); i++) {
        if (result.cells[i].name == cellName) {
            return static_cast<int>(i);
        }
    }
    return -1;
}

void ResolveInstanceCellIds(GdsiiParseResult& result, const NativeJobControl* control) {
    for (auto& shape : result.shapes) {
        if (control) control->check();
        if (shape.type == "instance" && shape.cellId < 0) {
            shape.cellId = ResolveCellId(result, shape.cellName);
        }
    }
}

} // namespace

void ResolveHierarchyMetadata(GdsiiParseResult& result, const NativeJobControl* control) {
    if (control) control->report("resolving");
    ResolveInstanceCellIds(result, control);
    result.topCellIds.clear();
    result.primaryTopCellId = -1;

    if (result.cells.empty()) {
        return;
    }

    std::vector<bool> referenced(result.cells.size(), false);
    for (const auto& shape : result.shapes) {
        if (control) control->check();
        if (shape.type == "instance" && shape.cellId >= 0 &&
            static_cast<size_t>(shape.cellId) < referenced.size()) {
            referenced[static_cast<size_t>(shape.cellId)] = true;
        }
    }

    for (size_t i = 0; i < referenced.size(); i++) {
        if (!referenced[i]) {
            result.topCellIds.push_back(static_cast<int>(i));
        }
    }

    // 循环引用或损坏文件可能没有未引用 Cell。保留稳定回退值，
    // 但调用方仍可通过只有一个候选且为 0 识别这是兼容性回退。
    if (result.topCellIds.empty()) {
        result.topCellIds.push_back(0);
    }

    // 当存在多个未被引用的根 Cell（例如正在单独绘制尚未放入顶层的新像元 Cell）时，
    // 优先选择真正包含子层级实例树的装配顶层 Cell，并按子树展开规模与层级深度排序，
    // 防止孤立的新叶子 Cell 因局部多边形较多而抢占 primaryTopCellId。
    const size_t cellCount = result.cells.size();
    struct ChildRef { int childId; uint64_t copies; };
    std::vector<std::vector<ChildRef>> childrenByCell(cellCount);
    std::vector<uint64_t> directGeomByCell(cellCount, 0);
    for (const auto& shape : result.shapes) {
        if (control) control->check();
        const int owner = shape.ownerCellId;
        if (owner < 0 || static_cast<size_t>(owner) >= cellCount) continue;
        if (shape.type == "instance" && shape.cellId >= 0 && static_cast<size_t>(shape.cellId) < cellCount) {
            const uint64_t cols = static_cast<uint64_t>(std::max(1, shape.arrayCols));
            const uint64_t rows = static_cast<uint64_t>(std::max(1, shape.arrayRows));
            childrenByCell[static_cast<size_t>(owner)].push_back({shape.cellId, cols * rows});
        } else {
            directGeomByCell[static_cast<size_t>(owner)]++;
        }
    }

    static constexpr uint64_t kMaxExpandedScore = 1000000000000000ULL;
    std::vector<int> memoDepth(cellCount, -1);
    std::vector<uint64_t> memoExpanded(cellCount, 0);
    std::vector<uint8_t> visitState(cellCount, 0);
    auto evaluateCell = [&](auto& self, int cid) -> void {
        const size_t idx = static_cast<size_t>(cid);
        if (visitState[idx] == 2) return;
        if (visitState[idx] == 1) {
            memoDepth[idx] = 0;
            memoExpanded[idx] = directGeomByCell[idx];
            return;
        }
        visitState[idx] = 1;
        int maxChildDepth = -1;
        uint64_t expanded = std::max<uint64_t>(
            directGeomByCell[idx],
            static_cast<uint64_t>(std::max(0, result.cells[idx].elementCount)));
        for (const auto& ref : childrenByCell[idx]) {
            const size_t cIdx = static_cast<size_t>(ref.childId);
            if (visitState[cIdx] != 2) self(self, ref.childId);
            if (visitState[cIdx] == 1) continue;
            maxChildDepth = std::max(maxChildDepth, memoDepth[cIdx]);
            const uint64_t childCost = std::max<uint64_t>(1ULL, memoExpanded[cIdx]);
            const uint64_t prod = (ref.copies > kMaxExpandedScore / childCost)
                ? kMaxExpandedScore : (ref.copies * childCost);
            expanded = (expanded > kMaxExpandedScore - prod) ? kMaxExpandedScore : (expanded + prod);
        }
        memoDepth[idx] = maxChildDepth + 1;
        memoExpanded[idx] = expanded;
        visitState[idx] = 2;
    };
    for (int cid : result.topCellIds) {
        if (cid >= 0 && static_cast<size_t>(cid) < cellCount) {
            evaluateCell(evaluateCell, cid);
        }
    }

    auto betterTopCandidate = [&](int lhs, int rhs) -> bool {
        const size_t l = static_cast<size_t>(lhs);
        const size_t r = static_cast<size_t>(rhs);
        const bool lHasChildren = memoDepth[l] > 0;
        const bool rHasChildren = memoDepth[r] > 0;
        if (lHasChildren != rHasChildren) return lHasChildren;
        if (memoExpanded[l] != memoExpanded[r]) return memoExpanded[l] > memoExpanded[r];
        if (memoDepth[l] != memoDepth[r]) return memoDepth[l] > memoDepth[r];
        return result.cells[l].elementCount > result.cells[r].elementCount;
    };

    int bestCellId = result.topCellIds[0];
    for (size_t i = 1; i < result.topCellIds.size(); i++) {
        const int candidateId = result.topCellIds[i];
        if (betterTopCandidate(candidateId, bestCellId)) {
            bestCellId = candidateId;
        }
    }
    result.primaryTopCellId = bestCellId;
}

uint16_t GdsiiReader::swap16(uint16_t val) {
    return (val >> 8) | (val << 8);
}

const std::string* FindPropertyValue(const std::vector<LayoutProperty>& props, int16_t attr) {
    for (const auto& p : props) {
        if (p.attr == attr) {
            return &p.value;
        }
    }
    return nullptr;
}

const std::string* FindNamedProperty(const std::vector<LayoutProperty>& props,
                                     const std::string& name) {
    for (const auto& p : props) {
        if (p.name == name) {
            return &p.value;
        }
    }
    return nullptr;
}

uint32_t GdsiiReader::swap32(uint32_t val) {
    return ((val >> 24) & 0xFF) |
           ((val >> 8)  & 0xFF00) |
           ((val << 8)  & 0xFF0000) |
           ((val << 24) & 0xFF000000);
}

double GdsiiReader::gdsiiFloatToDouble(const uint8_t* bytes) {
    // GDSII 8字节浮点格式：
    // 位 0: 符号 (1=负)
    // 位 1-7: 指数 (7位，余64)
    // 位 8-63: 尾数 (56位)
    int sign = (bytes[0] & 0x80) ? -1 : 1;
    int exponent = (bytes[0] & 0x7F) - 64;
    uint64_t mantissa = 0;
    for (int i = 1; i < 8; i++) {
        mantissa = (mantissa << 8) | bytes[i];
    }
    // 尾数是 56 位整数，隐含小数点在最高位前
    double result = static_cast<double>(mantissa);
    result = result * std::pow(16.0, exponent - 14);
    return sign * result;
}

bool GdsiiReader::readRecordHeader(std::ifstream& file, uint16_t& length,
                                    uint8_t& type, uint8_t& dataType) {
    uint8_t header[4];
    file.read(reinterpret_cast<char*>(header), 4);
    if (file.gcount() < 4) {
        return false;
    }
    // 大端序 16 位长度
    length = (static_cast<uint16_t>(header[0]) << 8) | header[1];
    type = header[2];
    dataType = header[3];
    return true;
}

int16_t GdsiiReader::readInt16(std::ifstream& file) {
    uint8_t buf[2] = {0, 0};  // 零初始化：截断短读时得确定值而非未初始化垃圾（UB）
    file.read(reinterpret_cast<char*>(buf), 2);
    return static_cast<int16_t>((static_cast<uint16_t>(buf[0]) << 8) | buf[1]);
}

int32_t GdsiiReader::readInt32(std::ifstream& file) {
    uint8_t buf[4] = {0, 0, 0, 0};
    file.read(reinterpret_cast<char*>(buf), 4);
    return static_cast<int32_t>(
        (static_cast<uint32_t>(buf[0]) << 24) |
        (static_cast<uint32_t>(buf[1]) << 16) |
        (static_cast<uint32_t>(buf[2]) << 8) |
        buf[3]
    );
}

double GdsiiReader::readFloat64(std::ifstream& file) {
    uint8_t buf[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    file.read(reinterpret_cast<char*>(buf), 8);
    return gdsiiFloatToDouble(buf);
}

std::string GdsiiReader::readString(std::ifstream& file, int length) {
    if (length <= 0) return "";
    std::vector<char> buf(length);
    file.read(buf.data(), length);
    // GDSII 字符串可能以 null 填充
    int actualLen = length;
    while (actualLen > 0 && buf[actualLen - 1] == '\0') {
        actualLen--;
    }
    return std::string(buf.data(), actualLen);
}

void GdsiiReader::skipRecord(std::ifstream& file, int dataLength) {
    if (dataLength > 0) {
        file.seekg(dataLength, std::ios::cur);
    }
}

GdsiiParseResult GdsiiReader::parse(const std::string& filePath, const NativeJobControl* control) {
    if (control) control->report("reading");
    GdsiiParseResult result;
    result.success = false;
    result.filePath = filePath;
    result.version = 0;
    result.cellCount = 0;
    result.totalElements = 0;
    result.layerCount = 0;
    result.userUnits = 1e-9;  // 默认 nm
    result.physicalUnits = 1e-9;
    double coordinateScaleNm = result.physicalUnits * 1e9;

    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        result.errorMessage = "无法打开文件: " + filePath;
        return result;
    }

    auto endPos = file.tellg();
    result.fileSize = static_cast<int64_t>(endPos);
    file.seekg(0, std::ios::beg);

    // 记录头解析主循环
    uint16_t recLen;
    uint8_t recType, recDataType;
    int dataLen;

    CellInfo* currentCell = nullptr;
    int currentCellId = -1;
    LayerInfo* currentLayer = nullptr;
    bool inElement = false;
    uint8_t currentElementType = 0;
    int currentElementLayer = -1;
    int currentElementDatatype = -1;
    double currentPathWidth = 0.0;
    bool currentPathWidthAbsolute = false;
    int currentPathType = 0;
    double currentBgnExtNm = 0.0;
    double currentEndExtNm = 0.0;
    int currentArrayColumns = 1;
    int currentArrayRows = 1;
    int currentMirror = 0;
    int currentTextPresentation = 0;
    double currentRotation = 0.0;
    double currentMagnification = 1.0;
    std::string currentText;
    std::string currentSName;
    std::vector<GdsPoint> currentElementPoints;
    int nextShapeId = 1;

    // ---------- 属性（PROPATTR/PROPVALUE）状态 ----------
    // 单条记录数据段天然 ≤ 65531 字节（16 位记录头），故只需限制「条数」与「总量」两档：
    // Exceeding any public property budget rejects the import before publication.
    std::vector<LayoutProperty> currentProps;
    bool pendingPropAttr = false;
    int16_t pendingPropAttrCode = 0;
    constexpr size_t kMaxPropsPerOwner = 64;
    constexpr size_t kMaxPropBytes = 32u * 1024 * 1024;
    size_t propBytesStored = 0;
    size_t contextBytesStored = 0;
    std::map<std::string, std::vector<std::string>> contextHooks;
    const auto inContext = [&]() { return currentCellId == 0 && currentCell && currentCell->name == "$$$CONTEXT_INFO$$$"; };

    auto storeProperty = [&](LayoutProperty&& prop) {
        const size_t cost = prop.value.size();
        if (inContext() && inElement) {
            if (cost > layout_context::kMaxGdsWireBytes - std::min(contextBytesStored, layout_context::kMaxGdsWireBytes) || currentProps.size() >= layout_context::kMaxGdsWireRecords) {
                result.errorMessage = "KLayout context budget exceeded"; return;
            }
            contextBytesStored += cost; currentProps.push_back(std::move(prop)); return;
        }
        if (cost > kMaxPropBytes - std::min(propBytesStored, kMaxPropBytes)) {
            result.errorMessage = "GDSII property byte budget exceeded; incomplete properties cannot be imported";
            return;
        }
        if (inElement) {
            if (currentProps.size() < (inContext() ? layout_context::kMaxRecords : kMaxPropsPerOwner)) {
                propBytesStored += cost;
                currentProps.push_back(std::move(prop));
            } else result.errorMessage = "GDSII property owner budget exceeded";
        } else if (currentCell) {
            if (currentCell->properties.size() < kMaxPropsPerOwner) {
                propBytesStored += cost;
                currentCell->properties.push_back(std::move(prop));
            } else result.errorMessage = "GDSII property owner budget exceeded";
        } else {
            if (result.libProperties.size() < kMaxPropsPerOwner) {
                propBytesStored += cost;
                result.libProperties.push_back(std::move(prop));
            } else result.errorMessage = "GDSII property owner budget exceeded";
        }
    };

    // 用于去重图层汇总
    struct LayerKey {
        int layer;
        int datatype;
        bool operator==(const LayerKey& o) const {
            return layer == o.layer && datatype == o.datatype;
        }
    };
    std::vector<LayerKey> seenLayers;
    std::vector<std::pair<LayerKey, int>> layerCounts;

    while (readRecordHeader(file, recLen, recType, recDataType)) {
        if (control) control->report("parsing", static_cast<uint64_t>(file.tellg()), result.fileSize);
        dataLen = recLen - 4;  // 记录头本身 4 字节

        switch (recType) {
            case static_cast<uint8_t>(GdsRecordType::HEADER): {
                if (dataLen >= 2) {
                    result.version = readInt16(file);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::BGNLIB): {
                // 跳过时间戳（12 字节：4 个 2 字节日期时间）
                skipRecord(file, dataLen);
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::LIBNAME): {
                result.libName = readString(file, dataLen);
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::UNITS): {
                if (dataLen >= 16) {
                    result.userUnits = readFloat64(file);
                    result.physicalUnits = readFloat64(file);
                    coordinateScaleNm = result.physicalUnits * 1e9;
                    if (!(result.userUnits > 0) || !(result.physicalUnits > 0) ||
                        !std::isfinite(coordinateScaleNm)) {
                        result.errorMessage = "Invalid GDSII UNITS";
                        return result;
                    }
                    // 生成单位描述
                    std::ostringstream oss;
                    oss << std::setprecision(3) << std::scientific;
                    if (result.physicalUnits >= 1e-3) {
                        oss << (result.physicalUnits * 1e3) << " mm/unit";
                    } else if (result.physicalUnits >= 1e-6) {
                        oss << (result.physicalUnits * 1e6) << " um/unit";
                    } else if (result.physicalUnits >= 1e-9) {
                        oss << (result.physicalUnits * 1e9) << " nm/unit";
                    } else {
                        oss << result.physicalUnits << " m/unit";
                    }
                    result.unitDescription = oss.str();
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::BGNSTR): {
                skipRecord(file, dataLen);
                result.cells.push_back(CellInfo());
                currentCell = &result.cells.back();
                currentCellId = static_cast<int>(result.cells.size()) - 1;
                currentCell->elementCount = 0;
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::STRNAME): {
                if (currentCell) {
                    currentCell->name = readString(file, dataLen);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::ENDSTR): {
                result.cellCount++;
                currentCell = nullptr;
                currentCellId = -1;
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::BOUNDARY):
            case static_cast<uint8_t>(GdsRecordType::PATH):
            case static_cast<uint8_t>(GdsRecordType::SREF):
            case static_cast<uint8_t>(GdsRecordType::AREF):
            case static_cast<uint8_t>(GdsRecordType::TEXT):
            case static_cast<uint8_t>(GdsRecordType::NODE):
            case static_cast<uint8_t>(GdsRecordType::BOX): {
                inElement = true;
                currentElementType = recType;
                currentElementLayer = -1;
                currentElementDatatype = -1;
                currentPathWidth = 0.0;
                currentPathWidthAbsolute = false;
                currentPathType = 0;
                currentBgnExtNm = 0.0;
                currentEndExtNm = 0.0;
                currentArrayColumns = 1;
                currentArrayRows = 1;
                currentMirror = 0;
                currentTextPresentation = 0;
                currentRotation = 0.0;
                currentMagnification = 1.0;
                currentText.clear();
                currentSName.clear();
                currentElementPoints.clear();
                currentProps.clear();
                pendingPropAttr = false;
                if (currentCell && !inContext()) {
                    currentCell->elementCount++;
                }
                if (!inContext()) result.totalElements++;
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::LAYER): {
                if (dataLen >= 2 && inElement) {
                    currentElementLayer = readInt16(file);
                    skipRecord(file, dataLen - 2);
                    if (currentElementLayer < 0) {
                        result.errorMessage = "Layer numbers above 32767 are not supported";
                        return result;
                    }
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::DATATYPE):
            case static_cast<uint8_t>(GdsRecordType::TEXTTYPE):
            case static_cast<uint8_t>(GdsRecordType::NODETYPE):
            case static_cast<uint8_t>(GdsRecordType::BOXTYPE): {
                if (dataLen >= 2 && inElement) {
                    currentElementDatatype = readInt16(file);
                    skipRecord(file, dataLen - 2);
                    if (currentElementDatatype < 0) {
                        result.errorMessage = "Datatypes above 32767 are not supported";
                        return result;
                    }
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            // 端型：独立记录 PATHTYPE(33/0x21)，2 字节有符号；0 flush / 1 round /
            // 2 半宽方端 / 4 变长方端。规范外值按 flush 处理（与 KLayout 同口径）。
            case static_cast<uint8_t>(GdsRecordType::PATHTYPE): {
                if (inElement && dataLen >= 2) {
                    const int16_t t = readInt16(file);
                    currentPathType = (t == 1 || t == 2 || t == 4) ? static_cast<int>(t) : 0;
                    skipRecord(file, dataLen - 2);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }
            // 端长：BGNEXTN(48/0x30)/ENDEXTN(49/0x31)，仅对 PATHTYPE=4 有意义；
            // Preserve signed lengths through LayoutShape, native geometry and both writers.
            case static_cast<uint8_t>(GdsRecordType::BGNEXTN):
            case static_cast<uint8_t>(GdsRecordType::ENDEXTN): {
                if (inElement && dataLen >= 4) {
                    const double ext = static_cast<double>(readInt32(file)) * coordinateScaleNm;
                    if (recType == static_cast<uint8_t>(GdsRecordType::BGNEXTN)) {
                        currentBgnExtNm = ext;
                    } else {
                        currentEndExtNm = ext;
                    }
                    skipRecord(file, dataLen - 4);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::PRESENTATION): {
                if (dataLen >= 2 && inElement) {
                    currentTextPresentation = static_cast<uint16_t>(readInt16(file));
                    skipRecord(file, dataLen - 2);
                } else skipRecord(file, dataLen);
                break;
            }
            case static_cast<uint8_t>(GdsRecordType::WIDTH): {
                if (dataLen >= 4 && inElement) {
                    const int32_t rawWidth = readInt32(file);
                    currentPathWidthAbsolute = rawWidth < 0;
                    currentPathWidth = std::abs(static_cast<double>(rawWidth)) * coordinateScaleNm;
                    skipRecord(file, dataLen - 4);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::XY): {
                // 兼容 KLayout 的非标准多 XY 扩展：一个元素可跨连续 XY 记录，
                // 故这里**累加**而不是清空——元素起始处已清过一次（见 BOUNDARY/PATH 分支）。
                // 早先在此 clear() 会让第二条 XY 记录覆盖前一条，多分片多边形的顶点被静默丢弃。
                //
                // 坐标本身是完整 32 位有符号数：GDSII 的 PATH 端型不在 XY 里，
                // 而是独立记录 PATHTYPE(33/0x21) 与 BGNEXTN(48/0x30)/ENDEXTN(49/0x31)，
                // 见下方 case；不得对 X 字做位剥离（会把 1,000,000 折成 16,960）。
                if (inElement && dataLen >= 8) {
                    const int pairCount = dataLen / 8;
                    for (int i = 0; i < pairCount; i++) {
                        const int32_t x = readInt32(file);
                        const int32_t y = readInt32(file);
                        currentElementPoints.push_back({
                            static_cast<double>(x) * coordinateScaleNm,
                            static_cast<double>(y) * coordinateScaleNm
                        });
                    }
                    skipRecord(file, dataLen - pairCount * 8);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::SNAME): {
                if (inElement) {
                    currentSName = readString(file, dataLen);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::STRANS): {
                if (dataLen >= 2 && inElement) {
                    const uint16_t strans = static_cast<uint16_t>(readInt16(file));
                    currentMirror = (strans & 0x8000U) != 0 ? 1 : 0;
                    skipRecord(file, dataLen - 2);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::MAG): {
                if (dataLen >= 8 && inElement) {
                    currentMagnification = readFloat64(file);
                    skipRecord(file, dataLen - 8);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::ANGLE): {
                if (dataLen >= 8 && inElement) {
                    currentRotation = readFloat64(file);
                    skipRecord(file, dataLen - 8);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::COLROW): {
                if (dataLen >= 4 && inElement &&
                    currentElementType == static_cast<uint8_t>(GdsRecordType::AREF)) {
                    currentArrayColumns = readInt16(file);
                    currentArrayRows = readInt16(file);
                    if (currentArrayColumns < 1 || currentArrayRows < 1) {
                        result.errorMessage = "Invalid AREF COLROW";
                        return result;
                    }
                    // Keep compressed AREF dimensions exactly. Traversal budgets belong
                    // to rendering/analysis, never to the document or its saved geometry.
                    skipRecord(file, dataLen - 4);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::STRING): {
                if (inElement) {
                    currentText = readString(file, dataLen);
                } else {
                    skipRecord(file, dataLen);
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::PROPATTR): {
                // 属性码：2 字节整数。坏长度（<2）只丢这一条属性，不影响记录流对齐。
                if (dataLen >= 2) {
                    pendingPropAttrCode = readInt16(file);
                    pendingPropAttr = true;
                    skipRecord(file, dataLen - 2);
                } else {
                    skipRecord(file, dataLen > 0 ? dataLen : 0);
                    pendingPropAttr = false;
                }
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::PROPVALUE): {
                // 值段按原始字节整段保留（写回时逐字节复现）。
                // 无前置 PROPATTR 的孤立值：attr 留 0 —— 数据不丢，但不臆造属性码。
                LayoutProperty prop;
                prop.dtype = recDataType;
                if (pendingPropAttr) {
                    prop.attr = pendingPropAttrCode;
                    pendingPropAttr = false;
                }
                if (dataLen > 0) {
                    std::string raw(static_cast<size_t>(dataLen), '\0');
                    file.read(&raw[0], dataLen);
                    const std::streamsize got = file.gcount();
                    if (got > 0) {
                        raw.resize(static_cast<size_t>(got));
                    } else {
                        raw.clear();
                    }
                    prop.value = std::move(raw);
                }
                storeProperty(std::move(prop));
                if (!result.errorMessage.empty()) return result;
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::ENDEL): {
                if (inElement && inContext()) {
                    try {
                        const bool global = currentElementType == static_cast<uint8_t>(GdsRecordType::BOUNDARY);
                        const bool cell = currentElementType == static_cast<uint8_t>(GdsRecordType::SREF);
                        if ((!global && !cell) || currentElementPoints.empty() ||
                            (cell && (currentSName.empty() || currentElementPoints.size() != 1 || currentMirror != 0 || currentRotation != 0 || currentMagnification != 1)) ||
                            (global && (currentElementLayer != 0 || currentElementDatatype != 0)))
                            throw std::invalid_argument("Invalid KLayout context hook");
                        for (const auto& point : currentElementPoints) if (point.x != 0 || point.y != 0) throw std::invalid_argument("Context hook coordinates must be zero");
                        const std::string target = cell ? currentSName : std::string();
                        if (!contextHooks.emplace(target, layout_context::DecodeGdsHook(currentProps)).second)
                            throw std::invalid_argument("Duplicate KLayout context hook");
                    } catch (const std::exception& e) { result.errorMessage = e.what(); return result; }
                    inElement = false; currentElementPoints.clear(); currentProps.clear(); pendingPropAttr = false;
                    currentText.clear(); currentSName.clear(); break;
                }
                if (inElement && currentElementType == static_cast<uint8_t>(GdsRecordType::AREF) &&
                    currentElementPoints.size() != 3) {
                    result.errorMessage = "AREF requires exactly three XY points";
                    return result;
                }
                if (inElement && currentElementType == static_cast<uint8_t>(GdsRecordType::NODE) &&
                    currentElementPoints.empty()) {
                    result.errorMessage = "NODE 缺少 XY 坐标，无法无损导入";
                    return result;
                }
                if (inElement && !currentElementPoints.empty()) {
                    LayoutShape shape;
                    shape.id = nextShapeId++;
                    shape.layerNumber = currentElementLayer >= 0 ? currentElementLayer : 0;
                    shape.datatype = currentElementDatatype >= 0 ? currentElementDatatype : 0;
                    shape.pathWidth = currentPathWidth;
                    shape.pathType = currentPathType;
                    shape.pathBeginExtension = currentBgnExtNm;
                    shape.pathEndExtension = currentEndExtNm;
                    shape.pathWidthAbsolute = currentPathWidthAbsolute;
                    shape.text = currentText;
                    shape.textPresentation = currentTextPresentation;
                    shape.cellName = currentSName;
                    shape.ownerCellId = currentCellId;
                    shape.cellId = ResolveCellId(result, currentSName);
                    shape.rotation = currentRotation;
                    shape.mirror = currentMirror;
                    shape.magnification = currentMagnification > 0.0 ? currentMagnification : 1.0;
                    // 元素级属性：随 ENDEL 落到图元上（AREF 展开的每个副本共享同一属性集）
                    if (!currentProps.empty()) {
                        shape.properties = currentProps;
                    }

                    if (currentElementType == static_cast<uint8_t>(GdsRecordType::PATH)) {
                        shape.type = "path";
                        shape.points = currentElementPoints;
                    } else if (currentElementType == static_cast<uint8_t>(GdsRecordType::NODE)) {
                        // NODE is a sequence of net coordinates, not a closed polygon.
                        // datatype carries NODETYPE through the common shape model.
                        shape.type = "node";
                        shape.points = currentElementPoints;
                    } else if (currentElementType == static_cast<uint8_t>(GdsRecordType::TEXT)) {
                        shape.type = "text";
                        shape.points.push_back(currentElementPoints[0]);
                    } else if (currentElementType == static_cast<uint8_t>(GdsRecordType::SREF) ||
                               currentElementType == static_cast<uint8_t>(GdsRecordType::AREF)) {
                        shape.type = "instance";
                        if (currentElementType == static_cast<uint8_t>(GdsRecordType::AREF) &&
                            currentElementPoints.size() >= 3) {
                            // GDSII XY endpoints are origin + count * step (NOT count-1).
                            const GdsPoint origin = currentElementPoints[0];
                            shape.arrayCols = currentArrayColumns;
                            shape.arrayRows = currentArrayRows;
                            shape.arrayColStepX = (currentElementPoints[1].x - origin.x) / currentArrayColumns;
                            shape.arrayColStepY = (currentElementPoints[1].y - origin.y) / currentArrayColumns;
                            shape.arrayRowStepX = (currentElementPoints[2].x - origin.x) / currentArrayRows;
                            shape.arrayRowStepY = (currentElementPoints[2].y - origin.y) / currentArrayRows;
                            shape.points.push_back(origin);
                        } else {
                            shape.points.push_back(currentElementPoints[0]);
                        }
                    } else if (currentElementType == static_cast<uint8_t>(GdsRecordType::BOUNDARY) ||
                               currentElementType == static_cast<uint8_t>(GdsRecordType::BOX)) {
                        std::vector<GdsPoint> polygon = RemoveDuplicateClosingPoint(currentElementPoints);
                        if (polygon.size() >= 4 && IsRectLike(polygon)) {
                            shape.type = "rect";
                            shape.points = RectCornersFromBounds(polygon);
                        } else if (polygon.size() >= 3) {
                            shape.type = "polygon";
                            shape.points = polygon;
                        }
                    }

                    if (!shape.type.empty()) {
                        result.shapes.push_back(shape);
                    }
                }
                // 元素结束，记录图层统计
                if (currentElementLayer >= 0) {
                    LayerKey key{currentElementLayer, currentElementDatatype};
                    bool found = false;
                    for (auto& lc : layerCounts) {
                        if (lc.first == key) {
                            lc.second++;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        layerCounts.push_back({key, 1});
                        seenLayers.push_back(key);
                    }
                    if (currentCell) {
                        bool cellLayerFound = false;
                        for (auto& layer : currentCell->layers) {
                            if (layer.layerNumber == currentElementLayer && layer.datatype == currentElementDatatype) {
                                layer.elementCount++;
                                cellLayerFound = true;
                                break;
                            }
                        }
                        if (!cellLayerFound) {
                            LayerInfo cellLayer;
                            cellLayer.layerNumber = currentElementLayer;
                            cellLayer.datatype = currentElementDatatype;
                            cellLayer.elementCount = 1;
                            currentCell->layers.push_back(cellLayer);
                        }
                    }
                }
                inElement = false;
                currentElementPoints.clear();
                currentProps.clear();
                pendingPropAttr = false;
                currentText.clear();
                currentSName.clear();
                break;
            }

            case static_cast<uint8_t>(GdsRecordType::ENDLIB): {
                if (!result.cells.empty() && result.cells[0].name == "$$$CONTEXT_INFO$$$") {
                    try {
                        result.cells.erase(result.cells.begin()); --result.cellCount;
                        for (auto& shape : result.shapes) { if (shape.ownerCellId <= 0) throw std::invalid_argument("Visible geometry in KLayout context container"); --shape.ownerCellId; shape.cellId = ResolveCellId(result, shape.cellName); }
                        result.cellContextRecords.resize(result.cells.size());
                        for (const auto& hook : contextHooks) {
                            if (hook.first.empty()) result.layoutContextRecords = hook.second;
                            else { const int id = ResolveCellId(result, hook.first); if (id < 0) throw std::invalid_argument("KLayout context hook references a missing Cell"); result.cellContextRecords[static_cast<size_t>(id)] = hook.second; }
                        }
                        layout_context::Validate(result);
                    } catch (const std::exception& e) { result.errorMessage = e.what(); return result; }
                }
                // 汇总图层信息
                result.layerCount = static_cast<int>(layerCounts.size());
                for (const auto& lc : layerCounts) {
                    LayerInfo li;
                    li.layerNumber = lc.first.layer;
                    li.datatype = lc.first.datatype;
                    li.elementCount = lc.second;
                    result.allLayers.push_back(li);
                }
                ResolveHierarchyMetadata(result, control);
                try { layout_context::ValidateOrdinaryProperties(result); port_codec::Decode(result); }
                catch (const std::exception& e) { result.errorMessage=e.what(); return result; }
                result.success = true;
                file.close();
                return result;
            }

            default: {
                skipRecord(file, dataLen);
                break;
            }
        }
    }

    // 文件读取完毕但未遇到 ENDLIB：视为截断/损坏，不伪成功
    result.layerCount = static_cast<int>(layerCounts.size());
    for (const auto& lc : layerCounts) {
        LayerInfo li;
        li.layerNumber = lc.first.layer;
        li.datatype = lc.first.datatype;
        li.elementCount = lc.second;
        result.allLayers.push_back(li);
    }
    ResolveHierarchyMetadata(result, control);
    if (result.cells.empty() && result.shapes.empty()) {
        result.success = false;
        result.errorMessage = "文件不完整：未找到 ENDLIB，且未解析到任何 Cell/图形";
    } else {
        result.success = false;
        result.errorMessage =
            "文件不完整：未找到 ENDLIB（可能截断或损坏）。已部分解析 "
            + std::to_string(result.cells.size()) + " 个 Cell / "
            + std::to_string(result.shapes.size()) + " 个图形，结果不可用于签核";
        // 保留 partial 数据供诊断，但 success=false 禁止下游当成功打开
    }
    file.close();
    return result;
}

GdsiiParseResult GdsiiReader::quickInfo(const std::string& filePath, const NativeJobControl* control) {
    if (control) control->report("reading");
    GdsiiParseResult result;
    result.success = false;
    result.filePath = filePath;

    std::ifstream file(filePath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        result.errorMessage = "无法打开文件: " + filePath;
        return result;
    }

    auto endPos = file.tellg();
    result.fileSize = static_cast<int64_t>(endPos);
    file.seekg(0, std::ios::beg);

    uint16_t recLen;
    uint8_t recType, recDataType;
    int cellCount = 0;

    // 只读前几个记录获取概要信息
    while (readRecordHeader(file, recLen, recType, recDataType)) {
        if (control) control->report("parsing", static_cast<uint64_t>(file.tellg()), result.fileSize);
        int dataLen = recLen - 4;

        if (recType == static_cast<uint8_t>(GdsRecordType::HEADER)) {
            if (dataLen >= 2) result.version = readInt16(file);
            else skipRecord(file, dataLen);
        } else if (recType == static_cast<uint8_t>(GdsRecordType::LIBNAME)) {
            result.libName = readString(file, dataLen);
        } else if (recType == static_cast<uint8_t>(GdsRecordType::BGNSTR)) {
            cellCount++;
            skipRecord(file, dataLen);
        } else if (recType == static_cast<uint8_t>(GdsRecordType::UNITS)) {
            if (dataLen >= 16) {
                result.userUnits = readFloat64(file);
                result.physicalUnits = readFloat64(file);
            } else {
                skipRecord(file, dataLen);
            }
        } else if (recType == static_cast<uint8_t>(GdsRecordType::ENDLIB)) {
            break;
        } else {
            skipRecord(file, dataLen);
        }
    }

    result.cellCount = cellCount;
    result.success = true;
    file.close();
    return result;
}

} // namespace hongtu
