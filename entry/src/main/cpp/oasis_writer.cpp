/**
 * 鸿图 OASIS 结构化写出实现
 *
 * 编码要点（与 oasis_reader 的解码语义严格互逆）：
 * - 按 ownerCellId 一次性 O(N_cells + N_shapes) 预分组，根除大版图多 Cell O(N_cells × N_shapes) 退化
 * - 支持标准 SEMI P39 CBLOCK(34, comp-type=0 RFC1951 raw DEFLATE) 记录块压缩（CELL/START/END 保持顶层）
 * - 变长无符号整数 LSB-first 续位；有符号 bit0 符号位
 * - real：整数值走类型 0/1，非整数走类型 7（IEEE float64 LE）
 * - 点列表统一 type 4（g-delta 双整数形式），顶点数 = 顶点总数 - 1
 * - PLACEMENT 17 的 AA 位承载 0/90/180/270；其余走 18 的 real mag/angle
 * - END：'2' + padding a-string + scheme(1) + CRC32(文件首字节..scheme 含) LE
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#include "oasis_writer.h"
#include "layout_context.h"
#include "layout_port_codec.h"
#include "checksums.h"

#if !defined(HONGTU_NO_ZLIB) && __has_include(<zlib.h>)
#include <zlib.h>
#define HONGTU_OASIS_HAS_ZLIB 1
#else
#define HONGTU_OASIS_HAS_ZLIB 0
#endif

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <string>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace hongtu {

namespace {

class OasisByteWriter {
public:
    std::vector<uint8_t> buffer;

    void byte(uint8_t b) { buffer.push_back(b); }

    void unsignedInt(uint64_t value) {
        do {
            uint8_t b = static_cast<uint8_t>(value & 0x7F);
            value >>= 7;
            if (value != 0) {
                b |= 0x80;
            }
            buffer.push_back(b);
        } while (value != 0);
    }

    void signedInt(int64_t value) {
        const uint64_t encoded = value < 0
            ? (static_cast<uint64_t>(-value) << 1) | 1u
            : static_cast<uint64_t>(value) << 1;
        unsignedInt(encoded);
    }

    void stringField(const std::string& s) {
        unsignedInt(s.size());
        buffer.insert(buffer.end(), s.begin(), s.end());
    }

    void real(double v) {
        if (std::isfinite(v) && v == std::floor(v) && std::fabs(v) < 1e15) {
            if (v >= 0) {
                unsignedInt(0);
                unsignedInt(static_cast<uint64_t>(v));
            } else {
                unsignedInt(1);
                unsignedInt(static_cast<uint64_t>(-v));
            }
            return;
        }
        unsignedInt(7);
        uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(v), "double size");
        std::memcpy(&bits, &v, sizeof(bits));
        for (int i = 0; i < 8; i++) {
            buffer.push_back(static_cast<uint8_t>((bits >> (i * 8)) & 0xFF));
        }
    }

    void gDelta(int64_t dx, int64_t dy) {
        const uint64_t mag = static_cast<uint64_t>(dx < 0 ? -dx : dx);
        unsignedInt((mag << 2) | (dx < 0 ? 2u : 0u) | 1u);
        signedInt(dy);
    }
};

#if HONGTU_OASIS_HAS_ZLIB
bool DeflateRawBlock(const uint8_t* src, size_t srcLen, std::vector<uint8_t>& outComp, int level) {
    outComp.clear();
    if (src == nullptr || srcLen == 0) return false;
    const int clampedLevel = (level < 1 || level > 9) ? Z_DEFAULT_COMPRESSION : level;
    z_stream zs{};
    if (deflateInit2(&zs, clampedLevel, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY) != Z_OK) {
        return false;
    }
    struct DeflateGuard {
        z_stream* stream;
        ~DeflateGuard() { if (stream) deflateEnd(stream); }
    } guard{&zs};

    const uLong bound = deflateBound(&zs, static_cast<uLong>(srcLen));
    outComp.resize(static_cast<size_t>(bound) + 16);
    zs.next_in = const_cast<Bytef*>(reinterpret_cast<const Bytef*>(src));
    zs.avail_in = static_cast<uInt>(srcLen);
    zs.next_out = reinterpret_cast<Bytef*>(outComp.data());
    zs.avail_out = static_cast<uInt>(outComp.size());

    const int ret = deflate(&zs, Z_FINISH);
    if (ret != Z_STREAM_END || zs.avail_in != 0) {
        outComp.clear();
        return false;
    }
    const size_t produced = outComp.size() - static_cast<size_t>(zs.avail_out);
    if (produced == 0) {
        outComp.clear();
        return false;
    }
    outComp.resize(produced);
    return true;
}
#endif

/**
 * 将记录对齐的 Cell 内部几何缓冲写出到主字节流：
 * 遵循 SEMI P39 §16，START / CELL(13) / END 始终位于顶层，仅将 Cell 内完整记录序列封装为 CBLOCK(34)。
 */
void FlushCellRecords(OasisByteWriter& dst, std::vector<uint8_t>& cellRecords,
                      const OasisWriteOptions& options) {
    if (cellRecords.empty()) return;
#if HONGTU_OASIS_HAS_ZLIB
    constexpr size_t kMaxSingleCBlock = 16u * 1024u * 1024u;
    if (options.useCBlock && cellRecords.size() >= options.cblockMinBytes &&
        cellRecords.size() <= kMaxSingleCBlock) {
        std::vector<uint8_t> compressed;
        if (DeflateRawBlock(cellRecords.data(), cellRecords.size(), compressed, options.compressionLevel)) {
            const bool forceEmit = (options.cblockMinBytes == 0);
            if (forceEmit || compressed.size() + 12 < cellRecords.size()) {
                dst.unsignedInt(34); // CBLOCK
                dst.unsignedInt(0);  // comp-type 0 = RFC1951 raw DEFLATE
                dst.unsignedInt(cellRecords.size());
                dst.unsignedInt(compressed.size());
                dst.buffer.insert(dst.buffer.end(), compressed.begin(), compressed.end());
                cellRecords.clear();
                return;
            }
        }
    }
#else
    (void)options;
#endif
    dst.buffer.insert(dst.buffer.end(), cellRecords.begin(), cellRecords.end());
    cellRecords.clear();
}

inline void writePropertyHeader(OasisByteWriter& w,size_t count,const std::string& name,bool standard=false){
    w.unsignedInt(28);w.byte(static_cast<uint8_t>((std::min<size_t>(count,15)<<4)|0x04|(standard?1:0)));
    w.stringField(name);if(count>=15)w.unsignedInt(count);
}
inline void writePropValue(OasisByteWriter& w,const LayoutProperty& p){
    if(p.dtype>=128&&p.dtype<=140){
        const unsigned kind=p.dtype-128;
        if(kind<=7){size_t used=0;const double v=std::stod(p.value,&used);if(used!=p.value.size()||!std::isfinite(v))throw std::runtime_error("Invalid OASIS real property");w.real(v);}
        else if(kind==8){size_t used=0;if(p.value.empty()||p.value[0]=='-')throw std::runtime_error("Invalid OASIS unsigned property");const auto v=std::stoull(p.value,&used);if(used!=p.value.size())throw std::runtime_error("Invalid OASIS unsigned property");w.unsignedInt(8);w.unsignedInt(v);}
        else if(kind==9){size_t used=0;const auto v=std::stoll(p.value,&used);if(used!=p.value.size()||v==INT64_MIN)throw std::runtime_error("Invalid OASIS signed property");w.unsignedInt(9);w.signedInt(v);}
        else{w.unsignedInt(kind);w.stringField(p.value);}
    }else if(p.dtype==6){w.unsignedInt(10);w.stringField(p.value);}
    else throw std::runtime_error("OASIS cannot preserve this property type");
}
inline void writeProperties(OasisByteWriter& w,const std::vector<LayoutProperty>& props){
    if(props.size()>64)throw std::invalid_argument("Ordinary property owner exceeds 64 records");
    for(size_t i=0;i<props.size();){
        const auto& p=props[i];
        if(p.name.empty()){
            if(p.attr<0)throw std::runtime_error("OASIS cannot preserve a negative GDS property key");
            writePropertyHeader(w,2,"S_GDS_PROPERTY",true);w.unsignedInt(8);w.unsignedInt(static_cast<uint16_t>(p.attr));writePropValue(w,p);++i;
        }else{
            size_t end=i+1;while(end<props.size()&&props[end].name==p.name)++end;
            if(p.dtype==0){if(end!=i+1)throw std::runtime_error("Ambiguous OASIS empty property list");writePropertyHeader(w,0,p.name);}
            else{writePropertyHeader(w,end-i,p.name);for(size_t j=i;j<end;++j)writePropValue(w,props[j]);}
            i=end;
        }
    }
}
inline void writeContext(OasisByteWriter& w,const std::vector<std::string>& records){
    if(records.empty())return;
    writePropertyHeader(w,records.size(),"KLAYOUT_CONTEXT");
    for(const auto& s:records){w.unsignedInt(11);w.stringField(s);}
}

} // namespace

GdsiiWriteResult WriteOasisToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out,
                                    const OasisWriteOptions& options) {
    GdsiiWriteResult result;
    out.clear();
    const double nmPerUnit = (layout.physicalUnits > 0 ? layout.physicalUnits : 1e-9) * 1e9;
    if (!std::isfinite(nmPerUnit) || !(nmPerUnit > 0)) {
        result.errorMessage = "Invalid OASIS database unit";
        return result;
    }
    result.quantization.dbuNm = nmPerUnit;
    port_codec::ContextPayload context;
    try {
        layout_context::Validate(layout);
        layout_context::ValidateOrdinaryProperties(layout);
        context=port_codec::Encode(layout);
        OasisByteWriter check;
        writeProperties(check,layout.libProperties);
        for(const auto& cell:layout.cells)writeProperties(check,cell.properties);
        for(const auto& shape:layout.shapes)writeProperties(check,shape.properties);
    } catch(const std::exception& error) { result.errorMessage=error.what(); return result; }
    uint64_t expandedCount = 0;
    for (const auto& s : layout.shapes) {
        auto representable = [nmPerUnit](double value) {
            return std::isfinite(value) && std::abs(value / nmPerUnit) < 4503599627370496.0;
        };
        for (const auto& point : s.points) {
            if (!representable(point.x) || !representable(point.y)) {
                result.errorMessage = "OASIS coordinate is nonfinite or exceeds precise integer range";
                return result;
            }
        }
        if (!representable(s.pathWidth) || !representable(s.pathBeginExtension) ||
            !representable(s.pathEndExtension) || !std::isfinite(s.magnification) ||
            !std::isfinite(s.rotation) || s.magnification <= 0) {
            result.errorMessage = "OASIS width/extension/transform is invalid";
            return result;
        }
        if (s.arrayCols < 0 || s.arrayRows < 0 ||
            (s.arrayCols > 0) != (s.arrayRows > 0) ||
            (s.type != "instance" && (s.arrayCols > 0 || s.arrayRows > 0))) {
            result.errorMessage = "OASIS array counts require a complete instance array";
            return result;
        }
        const bool isArray = s.arrayCols > 0;
        const uint64_t count = isArray
            ? static_cast<uint64_t>(s.arrayCols) * static_cast<uint64_t>(s.arrayRows) : 1;
        constexpr uint64_t kMaxExpandedObjects = 1000000;
        if (count > kMaxExpandedObjects - expandedCount) {
            result.errorMessage = "OASIS export exceeds one million logical placements; save GDSII";
            return result;
        }
        expandedCount += count;
        if (isArray) {
            if (!representable(s.arrayColStepX) || !representable(s.arrayColStepY) ||
                !representable(s.arrayRowStepX) || !representable(s.arrayRowStepY)) {
                result.errorMessage = "OASIS array vector is nonfinite or exceeds precise integer range";
                return result;
            }
            if ((s.arrayCols == 1 && s.arrayRows == 1) ||
                (s.arrayCols == 1 && (s.arrayColStepX != 0 || s.arrayColStepY != 0)) ||
                (s.arrayRows == 1 && (s.arrayRowStepX != 0 || s.arrayRowStepY != 0))) {
                result.errorMessage = "OASIS cannot preserve singleton array identity or inactive vectors; save GDSII";
                return result;
            }
            if ((s.arrayCols > 1 && s.arrayColStepX == 0 && s.arrayColStepY == 0) ||
                (s.arrayRows > 1 && s.arrayRowStepX == 0 && s.arrayRowStepY == 0)) {
                result.errorMessage = "OASIS target reader cannot preserve source zero-vector array counts; save GDSII";
                return result;
            }
            if (s.arrayRows == 1 && (s.arrayColStepX != 0 || s.arrayColStepY <= 0)) {
                result.errorMessage = "OASIS cannot preserve this column-only array dimension; save GDSII";
                return result;
            }
            const int64_t ax = std::llround(s.arrayColStepX / nmPerUnit);
            const int64_t ay = std::llround(s.arrayColStepY / nmPerUnit);
            const int64_t bx = std::llround(s.arrayRowStepX / nmPerUnit);
            const int64_t by = std::llround(s.arrayRowStepY / nmPerUnit);
            if ((s.arrayCols > 1 && ax == 0 && ay == 0) ||
                (s.arrayRows > 1 && bx == 0 && by == 0)) {
                if (s.arrayCols > 1) {
                    result.quantization.observe(s.arrayColStepX, ax * nmPerUnit);
                    result.quantization.observe(s.arrayColStepY, ay * nmPerUnit);
                }
                if (s.arrayRows > 1) {
                    result.quantization.observe(s.arrayRowStepX, bx * nmPerUnit);
                    result.quantization.observe(s.arrayRowStepY, by * nmPerUnit);
                }
                if (result.quantization.quantizedValueCount > 0) ++result.quantization.quantizedShapeCount;
                result.errorMessage = "OASIS array vector quantizes to zero and target reader would change counts; save GDSII";
                return result;
            }
            if (!s.points.empty()) {
                const auto precise = [](long double dbu) {
                    return std::isfinite(dbu) && std::abs(dbu) < 4503599627370496.0L;
                };
                const int64_t x = std::llround(s.points[0].x / nmPerUnit);
                const int64_t y = std::llround(s.points[0].y / nmPerUnit);
                for (const int col : {0, s.arrayCols - 1}) {
                    for (const int row : {0, s.arrayRows - 1}) {
                        const long double sourceX = (static_cast<long double>(s.points[0].x) +
                            col * static_cast<long double>(s.arrayColStepX) +
                            row * static_cast<long double>(s.arrayRowStepX)) / nmPerUnit;
                        const long double sourceY = (static_cast<long double>(s.points[0].y) +
                            col * static_cast<long double>(s.arrayColStepY) +
                            row * static_cast<long double>(s.arrayRowStepY)) / nmPerUnit;
                        const long double storedX = x + col * static_cast<long double>(ax) +
                            row * static_cast<long double>(bx);
                        const long double storedY = y + col * static_cast<long double>(ay) +
                            row * static_cast<long double>(by);
                        if (!precise(sourceX) || !precise(sourceY) ||
                            !precise(storedX) || !precise(storedY)) {
                            result.errorMessage = "OASIS array member exceeds precise integer range";
                            return result;
                        }
                    }
                }
            }
        }
        if (s.type == "path" && (s.pathWidthAbsolute || s.pathType == 1)) {
            result.errorMessage = "OASIS cannot preserve absolute-width or round-cap PATHs; save GDSII";
            return result;
        }
        if (s.type == "text" && (s.textPresentation != 0 || s.rotation != 0 || s.mirror != 0 || s.magnification != 1)) {
            result.errorMessage = "OASIS TEXT export cannot preserve GDS presentation/transform; save GDSII";
            return result;
        }
    }
    OasisByteWriter w;

    // ---------- 魔数 + START ----------
    static const char kMagic[] = "%SEMI-OASIS\r\n";
    w.buffer.insert(w.buffer.end(), kMagic, kMagic + sizeof(kMagic) - 1);

    w.unsignedInt(1); // START
    w.stringField("1.0");
    const double physical = layout.physicalUnits > 0 ? layout.physicalUnits : 1e-9;
    const double nmPerDbu = physical * 1e9;
    result.quantization.dbuNm = nmPerDbu;
    auto toDbu = [&](double nm, double impact = 1) {
        const int64_t stored = static_cast<int64_t>(std::llround(nm / nmPerDbu));
        result.quantization.observe(nm * impact, stored * nmPerDbu * impact);
        return stored;
    };
    w.real(1e-6 / physical);
    w.unsignedInt(0); // 偏移表内联
    for (int i = 0; i < 12; i++) {
        w.unsignedInt(0);
    }

    writeProperties(w, layout.libProperties);
    writeContext(w, context.layout);

    const auto writeInterval = [&](const LayerNameInterval& interval) {
        if (interval.type > 4 || interval.lower > interval.upper) return false;
        w.unsignedInt(interval.type);
        if (interval.type == 1) w.unsignedInt(interval.upper);
        else if (interval.type == 2 || interval.type == 3) w.unsignedInt(interval.lower);
        else if (interval.type == 4) { w.unsignedInt(interval.lower); w.unsignedInt(interval.upper); }
        return true;
    };
    for (const auto& definition : layout.layerDefinitions) {
        if (definition.name.find('\0') != std::string::npos || definition.name.size() > 65535) {
            result.errorMessage = "OASIS layer name is invalid"; return result;
        }
        w.unsignedInt(definition.textLayer ? 12 : 11);
        w.stringField(definition.name);
        if (!writeInterval(definition.layer) || !writeInterval(definition.datatype)) {
            result.errorMessage = "OASIS layer-name interval is invalid"; return result;
        }
    }
    std::vector<LayerInfo> exportLayers=layout.allLayers;
    for(const auto& port:layout.ports)if(std::none_of(exportLayers.begin(),exportLayers.end(),[&](const LayerInfo& layer){return layer.layerNumber==port.layerNumber&&layer.datatype==port.datatype;}))exportLayers.push_back({port.layerNumber,port.datatype,0});
    for (const auto& layer : exportLayers) {
        if (layer.layerNumber < 0 || layer.datatype < 0) { result.errorMessage = "Invalid OASIS layer"; return result; }
        const bool covered = std::any_of(layout.layerDefinitions.begin(), layout.layerDefinitions.end(), [&](const SourceLayerDefinition& definition) {
            return static_cast<uint32_t>(layer.layerNumber) >= definition.layer.lower && static_cast<uint32_t>(layer.layerNumber) <= definition.layer.upper &&
                static_cast<uint32_t>(layer.datatype) >= definition.datatype.lower && static_cast<uint32_t>(layer.datatype) <= definition.datatype.upper;
        });
        if (!covered && (!layer.sourceName.empty() || layer.elementCount == 0)) {
            w.unsignedInt(11); w.stringField(layer.sourceName);
            w.unsignedInt(3); w.unsignedInt(static_cast<uint32_t>(layer.layerNumber));
            w.unsignedInt(3); w.unsignedInt(static_cast<uint32_t>(layer.datatype));
        }
    }

    // ---------- 名称表 ----------
    for (const auto& cell : layout.cells) {
        w.unsignedInt(3);
        w.stringField(cell.name.empty() ? "CELL" : cell.name);
    }
    std::unordered_map<std::string, uint64_t> textRef;
    textRef.reserve(64);
    for (const auto& s : layout.shapes) {
        if (s.type == "text" && textRef.find(s.text) == textRef.end()) {
            const uint64_t ref = textRef.size();
            textRef.emplace(s.text, ref);
            w.unsignedInt(5);
            w.stringField(s.text);
        }
    }
    std::unordered_map<std::string, int> cellIdByName;
    cellIdByName.reserve(layout.cells.size());
    for (size_t i = 0; i < layout.cells.size(); i++) {
        cellIdByName[layout.cells[i].name] = static_cast<int>(i);
    }

    // ---------- 按 ownerCellId 一次性 O(N_cells + N_shapes) 预分组 ----------
    std::vector<std::vector<const LayoutShape*>> shapesByCell(layout.cells.size());
    for (const auto& s : layout.shapes) {
        const int owner = s.ownerCellId >= 0 ? s.ownerCellId : layout.primaryTopCellId;
        if (owner >= 0 && static_cast<size_t>(owner) < layout.cells.size()) {
            shapesByCell[static_cast<size_t>(owner)].push_back(&s);
        } else {
            result.skippedShapes++;
        }
    }

    // ---------- 逐 Cell 写出（支持记录对齐的 CBLOCK 压缩） ----------
    constexpr size_t kCBlockChunkTarget = 4u * 1024u * 1024u;
    OasisByteWriter cw;
    for (size_t ci = 0; ci < layout.cells.size(); ci++) {
        w.unsignedInt(13); // CELL by refnum（始终位于顶层流）
        w.unsignedInt(ci);
        result.writtenCells++;
        writeProperties(w, layout.cells[ci].properties);
        writeContext(w, context.cells.at(ci));

        cw.buffer.clear();
        int64_t modalLayer = -1;
        int64_t modalDatatype = -1;

        for (const LayoutShape* sp : shapesByCell[ci]) {
            const LayoutShape& s = *sp;
            struct ShapeAudit {
                QuantizationReport& report;
                uint64_t before;
                ~ShapeAudit() { if (report.quantizedValueCount > before) ++report.quantizedShapeCount; }
            } shapeAudit{result.quantization, result.quantization.quantizedValueCount};

            if (s.type == "rect") {
                if (s.points.size() < 2) {
                    result.skippedShapes++;
                    continue;
                }
                double minX = s.points.front().x, maxX = minX;
                double minY = s.points.front().y, maxY = minY;
                for (const auto& point : s.points) {
                    minX = std::min(minX, point.x);
                    maxX = std::max(maxX, point.x);
                    minY = std::min(minY, point.y);
                    maxY = std::max(maxY, point.y);
                }
                const int64_t x0 = toDbu(minX);
                const int64_t y0 = toDbu(minY);
                const int64_t x1 = toDbu(maxX);
                const int64_t y1 = toDbu(maxY);
                const bool needL = s.layerNumber != modalLayer;
                const bool needD = s.datatype != modalDatatype;
                uint8_t info = 0x40 | 0x20 | 0x10 | 0x08;
                if (needD) info |= 0x02;
                if (needL) info |= 0x01;
                cw.unsignedInt(20);
                cw.byte(info);
                if (needL) {
                    cw.unsignedInt(static_cast<uint64_t>(s.layerNumber));
                    modalLayer = s.layerNumber;
                }
                if (needD) {
                    cw.unsignedInt(static_cast<uint64_t>(s.datatype));
                    modalDatatype = s.datatype;
                }
                cw.unsignedInt(static_cast<uint64_t>(x1 - x0));
                cw.unsignedInt(static_cast<uint64_t>(y1 - y0));
                cw.signedInt(x0);
                cw.signedInt(y0);
                result.writtenShapes++;
            } else if (s.type == "polygon") {
                if (s.points.size() < 3) {
                    result.skippedShapes++;
                    continue;
                }
                const bool needL = s.layerNumber != modalLayer;
                const bool needD = s.datatype != modalDatatype;
                uint8_t info = 0x20 | 0x10 | 0x08;
                if (needD) info |= 0x02;
                if (needL) info |= 0x01;
                cw.unsignedInt(21);
                cw.byte(info);
                if (needL) {
                    cw.unsignedInt(static_cast<uint64_t>(s.layerNumber));
                    modalLayer = s.layerNumber;
                }
                if (needD) {
                    cw.unsignedInt(static_cast<uint64_t>(s.datatype));
                    modalDatatype = s.datatype;
                }
                cw.unsignedInt(4);
                cw.unsignedInt(s.points.size() - 1);
                int64_t px = toDbu(s.points[0].x);
                int64_t py = toDbu(s.points[0].y);
                const int64_t startX = px;
                const int64_t startY = py;
                for (size_t i = 1; i < s.points.size(); i++) {
                    const int64_t nx = toDbu(s.points[i].x);
                    const int64_t ny = toDbu(s.points[i].y);
                    cw.gDelta(nx - px, ny - py);
                    px = nx;
                    py = ny;
                }
                cw.signedInt(startX);
                cw.signedInt(startY);
                result.writtenShapes++;
            } else if (s.type == "path") {
                if (s.points.size() < 2) {
                    result.skippedShapes++;
                    continue;
                }
                const bool needL = s.layerNumber != modalLayer;
                const bool needD = s.datatype != modalDatatype;
                uint8_t info = 0x80 | 0x40 | 0x20 | 0x10 | 0x08;
                if (needD) info |= 0x02;
                if (needL) info |= 0x01;
                cw.unsignedInt(22);
                cw.byte(info);
                if (needL) {
                    cw.unsignedInt(static_cast<uint64_t>(s.layerNumber));
                    modalLayer = s.layerNumber;
                }
                if (needD) {
                    cw.unsignedInt(static_cast<uint64_t>(s.datatype));
                    modalDatatype = s.datatype;
                }
                const int64_t halfWidth = toDbu(s.pathWidth * 0.5, 2);
                if (std::abs(halfWidth * nmPerDbu - s.pathWidth * 0.5) > 1e-8 || halfWidth < 0) {
                    result.errorMessage = "OASIS PATH width requires an even number of DBU; save GDSII";
                    return result;
                }
                cw.unsignedInt(static_cast<uint64_t>(halfWidth));
                if (s.pathType == 4) {
                    cw.unsignedInt(15);
                    cw.signedInt(toDbu(s.pathBeginExtension));
                    cw.signedInt(toDbu(s.pathEndExtension));
                } else {
                    cw.unsignedInt(s.pathType == 2 ? 10 : 5);
                }
                cw.unsignedInt(4);
                cw.unsignedInt(s.points.size() - 1);
                int64_t px = toDbu(s.points[0].x);
                int64_t py = toDbu(s.points[0].y);
                const int64_t startX = px;
                const int64_t startY = py;
                for (size_t i = 1; i < s.points.size(); i++) {
                    const int64_t nx = toDbu(s.points[i].x);
                    const int64_t ny = toDbu(s.points[i].y);
                    cw.gDelta(nx - px, ny - py);
                    px = nx;
                    py = ny;
                }
                cw.signedInt(startX);
                cw.signedInt(startY);
                result.writtenShapes++;
            } else if (s.type == "text") {
                if (s.points.empty()) {
                    result.skippedShapes++;
                    continue;
                }
                auto it = textRef.find(s.text);
                if (it == textRef.end()) {
                    result.skippedShapes++;
                    continue;
                }
                cw.unsignedInt(19);
                cw.byte(0x40 | 0x20 | 0x10 | 0x08 | 0x02 | 0x01);
                cw.unsignedInt(it->second);
                cw.unsignedInt(static_cast<uint64_t>(s.layerNumber));
                cw.unsignedInt(static_cast<uint64_t>(s.datatype));
                cw.signedInt(toDbu(s.points[0].x));
                cw.signedInt(toDbu(s.points[0].y));
                result.writtenShapes++;
            } else if (s.type == "instance") {
                if (s.points.empty()) {
                    result.skippedShapes++;
                    continue;
                }
                int refCell = s.cellId;
                if (refCell < 0) {
                    auto nameIt = cellIdByName.find(s.cellName);
                    refCell = nameIt != cellIdByName.end() ? nameIt->second : -1;
                }
                if (refCell < 0 || refCell >= static_cast<int>(layout.cells.size())) {
                    result.skippedShapes++;
                    continue;
                }
                const double mag = s.magnification;
                const double rot = std::fmod(std::fmod(s.rotation, 360) +
                    (s.mirror == 2 ? 180 : 0) + 360, 360);
                const bool isArray = s.arrayCols > 0;
                const int64_t x = toDbu(s.points[0].x);
                const int64_t y = toDbu(s.points[0].y);
                int64_t ax = 0, ay = 0, bx = 0, by = 0;
                if (isArray) {
                    if (s.arrayCols > 1) {
                        ax = toDbu(s.arrayColStepX);
                        ay = toDbu(s.arrayColStepY);
                    }
                    if (s.arrayRows > 1) {
                        bx = toDbu(s.arrayRowStepX);
                        by = toDbu(s.arrayRowStepY);
                    }
                    const int colEnds = s.arrayCols > 1 ? 2 : 1;
                    const int rowEnds = s.arrayRows > 1 ? 2 : 1;
                    for (int cIdx = 0; cIdx < colEnds; ++cIdx) {
                        for (int rIdx = 0; rIdx < rowEnds; ++rIdx) {
                            if (cIdx == 0 && rIdx == 0) continue;
                            const int col = cIdx * (s.arrayCols - 1);
                            const int row = rIdx * (s.arrayRows - 1);
                            const double sourceX = s.points[0].x + col * s.arrayColStepX + row * s.arrayRowStepX;
                            const double sourceY = s.points[0].y + col * s.arrayColStepY + row * s.arrayRowStepY;
                            const int64_t storedX = x + static_cast<int64_t>(col) * ax + static_cast<int64_t>(row) * bx;
                            const int64_t storedY = y + static_cast<int64_t>(col) * ay + static_cast<int64_t>(row) * by;
                            result.quantization.observe(sourceX, storedX * nmPerDbu);
                            result.quantization.observe(sourceY, storedY * nmPerDbu);
                        }
                    }
                }
                const bool rightAngle =
                    (rot == 0.0 || rot == 90.0 || rot == 180.0 || rot == 270.0);
                if (rightAngle && mag == 1.0) {
                    uint8_t info = 0x80 | 0x40 | 0x20 | 0x10;
                    if (isArray) info |= 0x08;
                    info |= static_cast<uint8_t>((static_cast<int>(rot) / 90) & 3) << 1;
                    if (s.mirror != 0) {
                        info |= 0x01;
                    }
                    cw.unsignedInt(17);
                    cw.byte(info);
                    cw.unsignedInt(static_cast<uint64_t>(refCell));
                    cw.signedInt(x);
                    cw.signedInt(y);
                } else {
                    uint8_t info = 0x80 | 0x40 | 0x20 | 0x10 | 0x04 | 0x02;
                    if (isArray) info |= 0x08;
                    if (s.mirror != 0) {
                        info |= 0x01;
                    }
                    cw.unsignedInt(18);
                    cw.byte(info);
                    cw.unsignedInt(static_cast<uint64_t>(refCell));
                    cw.real(mag);
                    cw.real(rot);
                    cw.signedInt(x);
                    cw.signedInt(y);
                }
                if (isArray) {
                    if (s.arrayCols > 1 && s.arrayRows > 1) {
                        cw.unsignedInt(8);
                        cw.unsignedInt(static_cast<uint64_t>(s.arrayRows - 2));
                        cw.unsignedInt(static_cast<uint64_t>(s.arrayCols - 2));
                        cw.gDelta(bx, by);
                        cw.gDelta(ax, ay);
                    } else if (s.arrayRows > 1) {
                        cw.unsignedInt(9);
                        cw.unsignedInt(static_cast<uint64_t>(s.arrayRows - 2));
                        cw.gDelta(bx, by);
                    } else {
                        cw.unsignedInt(3);
                        cw.unsignedInt(static_cast<uint64_t>(s.arrayCols - 2));
                        cw.unsignedInt(static_cast<uint64_t>(ay));
                    }
                }
                result.writtenShapes++;
            } else {
                result.skippedShapes++;
                continue;
            }
            writeProperties(cw, s.properties);
            if (cw.buffer.size() >= kCBlockChunkTarget) {
                FlushCellRecords(w, cw.buffer, options);
            }
        }
        FlushCellRecords(w, cw.buffer, options);
    }

    // ---------- END（规范 256 字节 + CRC32） ----------
    w.unsignedInt(2);
    w.unsignedInt(248);
    for (int i = 0; i < 248; i++) {
        w.byte(0);
    }
    w.unsignedInt(1); // validation-scheme = CRC32
    const uint32_t crc = checksums::Crc32(w.buffer.data(), w.buffer.size());
    for (int i = 0; i < 4; i++) {
        w.byte(static_cast<uint8_t>((crc >> (i * 8)) & 0xFF));
    }

    if (result.skippedShapes > 0) {
        result.errorMessage = "OASIS export refused: unsupported or invalid shapes";
        return result;
    }
    out = std::move(w.buffer);
    result.success = true;
    result.bytes = out.size();
    return result;
}

GdsiiWriteResult WriteOasisToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out) {
    return WriteOasisToBuffer(layout, out, OasisWriteOptions{});
}

GdsiiWriteResult WriteOasis(const GdsiiParseResult& layout, const std::string& filePath,
                            const OasisWriteOptions& options) {
    std::vector<uint8_t> buffer;
    GdsiiWriteResult result = WriteOasisToBuffer(layout, buffer, options);
    if (!result.success) {
        return result;
    }
    std::ofstream file(filePath, std::ios::binary);
    if (!file.is_open()) {
        result.success = false;
        result.errorMessage = "无法创建文件: " + filePath;
        return result;
    }
    file.write(reinterpret_cast<const char*>(buffer.data()),
               static_cast<std::streamsize>(buffer.size()));
    if (!file.good()) {
        result.success = false;
        result.errorMessage = "写入文件失败: " + filePath;
        return result;
    }
    return result;
}

GdsiiWriteResult WriteOasis(const GdsiiParseResult& layout, const std::string& filePath) {
    return WriteOasis(layout, filePath, OasisWriteOptions{});
}

} // namespace hongtu
