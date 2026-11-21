/**
 * 鸿图 GDSII 结构化写出实现
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#include "gdsii_writer.h"
#include "layout_context.h"
#include "layout_port_codec.h"

#include <algorithm>
#include <cmath>
#include <ctime>
#include <fstream>
#include <map>
#include <set>
#include <stdexcept>

namespace hongtu {
namespace {

void pushU8(std::vector<uint8_t>& out, uint8_t v) {
    out.push_back(v);
}

void pushU16(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(v & 0xFF));
}

void pushI16(std::vector<uint8_t>& out, int16_t v) {
    pushU16(out, static_cast<uint16_t>(v));
}

void pushI32(std::vector<uint8_t>& out, int32_t v) {
    const uint32_t u = static_cast<uint32_t>(v);
    out.push_back(static_cast<uint8_t>((u >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((u >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((u >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(u & 0xFF));
}

/** 写入一条 GDS 记录。payload 过大时返回 false（不写半截记录）。 */
bool writeRecord(std::vector<uint8_t>& out, uint8_t type, uint8_t dataType,
                 const std::vector<uint8_t>& payload = {}) {
    const size_t len = payload.size() + 4;
    if (len > 65535) {
        return false;
    }
    pushU16(out, static_cast<uint16_t>(len));
    pushU8(out, type);
    pushU8(out, dataType);
    out.insert(out.end(), payload.begin(), payload.end());
    return true;
}

std::vector<uint8_t> int2Payload(const std::vector<int16_t>& values) {
    std::vector<uint8_t> p;
    p.reserve(values.size() * 2);
    for (int16_t v : values) {
        pushI16(p, v);
    }
    return p;
}

std::vector<uint8_t> int4Payload(const std::vector<int32_t>& values) {
    std::vector<uint8_t> p;
    p.reserve(values.size() * 4);
    for (int32_t v : values) {
        pushI32(p, v);
    }
    return p;
}

std::vector<uint8_t> stringPayload(std::string value) {
    if ((value.size() % 2) != 0) {
        value.push_back('\0');
    }
    return std::vector<uint8_t>(value.begin(), value.end());
}

std::vector<uint8_t> gdsReal8(double value) {
    std::vector<uint8_t> bytes(8, 0);
    if (value == 0.0 || !std::isfinite(value)) {
        return bytes;
    }
    const bool negative = value < 0.0;
    double normalized = std::fabs(value);
    int exponent = 64;
    while (normalized >= 1.0) {
        normalized /= 16.0;
        exponent++;
    }
    while (normalized < 0.0625) {
        normalized *= 16.0;
        exponent--;
    }
    constexpr double mantissaScale = 72057594037927936.0;
    uint64_t mantissa = static_cast<uint64_t>(normalized * mantissaScale + 0.5);
    if (mantissa >= (1ULL << 56)) {
        mantissa >>= 4;
        exponent++;
    }
    bytes[0] = static_cast<uint8_t>(exponent & 0x7F);
    if (negative) {
        bytes[0] |= 0x80;
    }
    for (int i = 7; i >= 1; --i) {
        bytes[static_cast<size_t>(i)] = static_cast<uint8_t>(mantissa & 0xFF);
        mantissa >>= 8;
    }
    return bytes;
}

std::vector<uint8_t> real8Payload(const std::vector<double>& values) {
    std::vector<uint8_t> p;
    p.reserve(values.size() * 8);
    for (double v : values) {
        const auto b = gdsReal8(v);
        p.insert(p.end(), b.begin(), b.end());
    }
    return p;
}

std::vector<int16_t> dateWords() {
    std::time_t t = std::time(nullptr);
    std::tm tm{};
#if defined(_WIN32)
    localtime_s(&tm, &t);
#else
    localtime_r(&t, &tm);
#endif
    const int y = tm.tm_year + 1900;
    const int mo = tm.tm_mon + 1;
    const int d = tm.tm_mday;
    const int h = tm.tm_hour;
    const int mi = tm.tm_min;
    const int s = tm.tm_sec;
    return {
        static_cast<int16_t>(y), static_cast<int16_t>(mo), static_cast<int16_t>(d),
        static_cast<int16_t>(h), static_cast<int16_t>(mi), static_cast<int16_t>(s),
        static_cast<int16_t>(y), static_cast<int16_t>(mo), static_cast<int16_t>(d),
        static_cast<int16_t>(h), static_cast<int16_t>(mi), static_cast<int16_t>(s),
    };
}

std::string sanitizeName(const std::string& raw, const std::string& fallback) {
    const std::string& src = raw.empty() ? fallback : raw;
    if (src.size() > 65530 || src.find('\0') != std::string::npos) {
        throw std::runtime_error("GDSII name cannot be represented without loss");
    }
    return src;
}

int32_t clampI32(double v) {
    if (!std::isfinite(v) || std::round(v) > 2147483647.0 || std::round(v) < -2147483648.0) {
        throw std::runtime_error("GDSII coordinate/width exceeds signed 32-bit database units");
    }
    return static_cast<int32_t>(std::llround(v));
}

thread_local double g_nmToDbuScale = 1.0;
thread_local QuantizationReport g_quantization;

int32_t nmToDbu(double nm) {
    const int32_t stored = clampI32(nm * g_nmToDbuScale);
    g_quantization.observe(nm, stored / g_nmToDbuScale);
    return stored;
}

int16_t clampLayer(int v) {
    if (v < 0 || v > 32767) throw std::runtime_error("GDSII layer/datatype out of supported range 0..32767");
    return static_cast<int16_t>(v);
}

bool writeXY(std::vector<uint8_t>& out, const std::vector<int32_t>& xy) {
    const size_t maxPairs = 8191;
    const size_t pairs = xy.size() / 2;
    if (pairs == 0) {
        return false;
    }
    for (size_t start = 0; start < pairs; start += maxPairs) {
        const size_t count = std::min(maxPairs, pairs - start);
        std::vector<int32_t> chunk;
        chunk.reserve(count * 2);
        for (size_t k = 0; k < count; k++) {
            chunk.push_back(xy[(start + k) * 2]);
            chunk.push_back(xy[(start + k) * 2 + 1]);
        }
        if (!writeRecord(out, 0x10, 0x03, int4Payload(chunk))) {
            return false;
        }
    }
    return true;
}

bool writeProperties(std::vector<uint8_t>& out, const std::vector<LayoutProperty>& props) {
    for (const auto& p : props) {
        if (p.dtype >= 128 || !p.name.empty() || p.attr<-32768 || p.attr>32767) return false;
        uint8_t dt = p.dtype;
        if (dt != 0 && dt != 2 && dt != 3 && dt != 4 && dt != 5 && dt != 6) {
            return false;
        }
        std::vector<uint8_t> payload(p.value.begin(), p.value.end());
        if (dt == 0) {
            payload.clear();
        } else if ((payload.size() % 2) != 0) {
            payload.push_back(0);
        }
        if (payload.size() + 4 > 65535) {
            return false;
        }
        if (!writeRecord(out, static_cast<uint8_t>(GdsRecordType::PROPATTR), 0x02, int2Payload({p.attr}))) {
            return false;
        }
        if (!writeRecord(out, static_cast<uint8_t>(GdsRecordType::PROPVALUE), dt, payload)) {
            return false;
        }
    }
    return true;
}

bool writeContextCell(std::vector<uint8_t>& out, const GdsiiParseResult& layout, const port_codec::ContextPayload& context, const std::map<int,std::string>& names) {
    bool any = !context.layout.empty();
    for (const auto& group : context.cells) any = any || !group.empty();
    if (!any) return true;
    for (const auto& cell : layout.cells) if (cell.name == "$$$CONTEXT_INFO$$$") throw std::invalid_argument("Reserved KLayout context Cell name collision");
    if (!writeRecord(out,0x05,0x02,int2Payload(dateWords())) || !writeRecord(out,0x06,0x06,stringPayload("$$$CONTEXT_INFO$$$"))) return false;
    auto hook = [&](const std::vector<std::string>& records, const std::string* cell) {
        if(records.empty()) return true;
        if(cell){if(!writeRecord(out,0x0a,0)||!writeRecord(out,0x12,6,stringPayload(*cell))||!writeXY(out,{0,0}))return false;}
        else{if(!writeRecord(out,0x08,0)||!writeRecord(out,0x0d,2,int2Payload({0}))||!writeRecord(out,0x0e,2,int2Payload({0}))||!writeXY(out,{0,0,0,0,0,0,0,0,0,0}))return false;}
        return writeProperties(out,layout_context::EncodeGdsHook(records)) && writeRecord(out,0x11,0);
    };
    if(!hook(context.layout,nullptr))return false;
    for(size_t c=0;c<context.cells.size();++c){auto found=names.find(static_cast<int>(c));if(found==names.end())throw std::invalid_argument("Missing context Cell name");if(!hook(context.cells[c],&found->second))return false;}
    return writeRecord(out,0x07,0);
}

constexpr size_t kMaxElementPoints = 4u * 1000u * 1000u;

bool writeBoundary(std::vector<uint8_t>& out, const LayoutShape& shape) {
    std::vector<int32_t> xy;
    if (shape.type == "rect" && shape.points.size() >= 2) {
        double minX = shape.points.front().x;
        double maxX = minX;
        double minY = shape.points.front().y;
        double maxY = minY;
        for (const auto& point : shape.points) {
            if (!std::isfinite(point.x) || !std::isfinite(point.y)) {
                throw std::invalid_argument("RECT coordinate is nonfinite");
            }
            minX = std::min(minX, point.x);
            maxX = std::max(maxX, point.x);
            minY = std::min(minY, point.y);
            maxY = std::max(maxY, point.y);
        }
        xy = {
            nmToDbu(minX), nmToDbu(minY),
            nmToDbu(maxX), nmToDbu(minY),
            nmToDbu(maxX), nmToDbu(maxY),
            nmToDbu(minX), nmToDbu(maxY),
            nmToDbu(minX), nmToDbu(minY),
        };
    } else if (shape.points.size() >= 3) {
        xy.reserve((shape.points.size() + 1) * 2);
        for (const auto& p : shape.points) {
            xy.push_back(nmToDbu(p.x));
            xy.push_back(nmToDbu(p.y));
        }
        if (shape.points.front().x != shape.points.back().x ||
            shape.points.front().y != shape.points.back().y) {
            xy.push_back(nmToDbu(shape.points.front().x));
            xy.push_back(nmToDbu(shape.points.front().y));
        }
        if (xy.size() / 2 > kMaxElementPoints) {
            return false;
        }
    } else {
        return false;
    }
    if (!writeRecord(out, 0x08, 0x00)) return false; // BOUNDARY
    if (!writeRecord(out, 0x0D, 0x02, int2Payload({clampLayer(shape.layerNumber)}))) return false;
    if (!writeRecord(out, 0x0E, 0x02, int2Payload({clampLayer(shape.datatype)}))) return false;
    if (!writeXY(out, xy)) return false;
    if (!writeProperties(out, shape.properties)) return false;
    if (!writeRecord(out, 0x11, 0x00)) return false; // ENDEL
    return true;
}

bool writePath(std::vector<uint8_t>& out, const LayoutShape& shape) {
    if (shape.points.size() < 2 || shape.points.size() > kMaxElementPoints) {
        return false;
    }
    std::vector<int32_t> xy;
    xy.reserve(shape.points.size() * 2);
    for (const auto& p : shape.points) {
        xy.push_back(nmToDbu(p.x));
        xy.push_back(nmToDbu(p.y));
    }
    if (shape.pathWidth < 0 || (shape.pathType != 0 && shape.pathType != 1 &&
        shape.pathType != 2 && shape.pathType != 4)) return false;
    const int32_t width = nmToDbu(shape.pathWidthAbsolute ? -shape.pathWidth : shape.pathWidth);
    if (!writeRecord(out, 0x09, 0x00)) return false; // PATH
    if (!writeRecord(out, 0x0D, 0x02, int2Payload({clampLayer(shape.layerNumber)}))) return false;
    if (!writeRecord(out, 0x0E, 0x02, int2Payload({clampLayer(shape.datatype)}))) return false;
    if (shape.pathType != 0 &&
        !writeRecord(out, static_cast<uint8_t>(GdsRecordType::PATHTYPE), 0x02,
                     int2Payload({static_cast<short>(shape.pathType)}))) {
        return false;
    }
    if (!writeRecord(out, 0x0F, 0x03, int4Payload({width}))) return false;
    if (shape.pathType == 4) {
        if (!writeRecord(out, 0x30, 0x03, int4Payload({nmToDbu(shape.pathBeginExtension)}))) return false;
        if (!writeRecord(out, 0x31, 0x03, int4Payload({nmToDbu(shape.pathEndExtension)}))) return false;
    }
    if (!writeXY(out, xy)) return false;
    if (!writeProperties(out, shape.properties)) return false;
    if (!writeRecord(out, 0x11, 0x00)) return false;
    return true;
}

bool writeNode(std::vector<uint8_t>& out, const LayoutShape& shape) {
    if (shape.points.empty() || shape.points.size() > kMaxElementPoints) {
        return false;
    }
    std::vector<int32_t> xy;
    xy.reserve(shape.points.size() * 2);
    for (const auto& p : shape.points) {
        xy.push_back(nmToDbu(p.x));
        xy.push_back(nmToDbu(p.y));
    }
    if (!writeRecord(out, static_cast<uint8_t>(GdsRecordType::NODE), 0x00)) return false;
    if (!writeRecord(out, 0x0D, 0x02, int2Payload({clampLayer(shape.layerNumber)}))) return false;
    if (!writeRecord(out, static_cast<uint8_t>(GdsRecordType::NODETYPE), 0x02,
                     int2Payload({clampLayer(shape.datatype)}))) return false;
    if (!writeXY(out, xy)) return false;
    if (!writeProperties(out, shape.properties)) return false;
    if (!writeRecord(out, 0x11, 0x00)) return false;
    return true;
}

bool writeText(std::vector<uint8_t>& out, const LayoutShape& shape) {
    if (shape.points.empty()) {
        return false;
    }
    const std::string& text = shape.text;
    if (!writeRecord(out, 0x0C, 0x00)) return false; // TEXT
    if (!writeRecord(out, 0x0D, 0x02, int2Payload({clampLayer(shape.layerNumber)}))) return false;
    if (!writeRecord(out, 0x16, 0x02, int2Payload({clampLayer(shape.datatype)}))) return false;
    if (shape.textPresentation != 0 && !writeRecord(out, 0x17, 0x01,
        int2Payload({static_cast<int16_t>(shape.textPresentation)}))) return false;
    if (shape.mirror != 0 && !writeRecord(out, 0x1A, 0x01,
        int2Payload({static_cast<int16_t>(0x8000)}))) return false;
    if (std::abs(shape.magnification - 1) > 1e-12 &&
        !writeRecord(out, 0x1B, 0x05, real8Payload({shape.magnification}))) return false;
    const double angle = shape.rotation + (shape.mirror == 2 ? 180 : 0);
    if (std::abs(angle) > 1e-12 && !writeRecord(out, 0x1C, 0x05, real8Payload({angle}))) return false;
    if (!writeRecord(out, 0x10, 0x03, int4Payload({nmToDbu(shape.points[0].x), nmToDbu(shape.points[0].y)}))) {
        return false;
    }
    if (!writeRecord(out, 0x19, 0x06, stringPayload(text))) return false;
    if (!writeProperties(out, shape.properties)) return false;
    if (!writeRecord(out, 0x11, 0x00)) return false;
    return true;
}

bool writeInstance(std::vector<uint8_t>& out, const LayoutShape& shape,
                   const std::map<int, std::string>& idToName) {
    if (shape.points.empty()) {
        return false;
    }
    std::string sname;
    if (shape.cellId >= 0) {
        const auto it = idToName.find(shape.cellId);
        if (it != idToName.end()) {
            sname = it->second;
        }
    }
    if (sname.empty()) {
        sname = sanitizeName(shape.cellName, "CELL");
    }
    const bool isArray = shape.arrayCols > 0 && shape.arrayRows > 0;
    if (shape.arrayCols > 32767 || shape.arrayRows > 32767 ||
        (shape.arrayCols > 0) != (shape.arrayRows > 0)) return false;
    if (!writeRecord(out, isArray ? 0x0B : 0x0A, 0x00)) return false;
    if (!writeRecord(out, 0x12, 0x06, stringPayload(sname))) return false;
    int mirror = shape.mirror;
    double rot = shape.rotation;
    if (mirror == 1) {
        if (!writeRecord(out, 0x1A, 0x01, int2Payload({static_cast<int16_t>(0x8000)}))) return false;
    } else if (mirror == 2) {
        if (!writeRecord(out, 0x1A, 0x01, int2Payload({static_cast<int16_t>(0x8000)}))) return false;
        rot = std::fmod(rot + 180.0, 360.0);
    }
    if (shape.magnification > 0.0 && std::fabs(shape.magnification - 1.0) > 1e-9) {
        if (!writeRecord(out, 0x1B, 0x05, real8Payload({shape.magnification}))) return false;
    }
    if (std::fabs(rot) > 1e-9) {
        if (!writeRecord(out, 0x1C, 0x05, real8Payload({rot}))) return false;
    }
    std::vector<int32_t> xy = {nmToDbu(shape.points[0].x), nmToDbu(shape.points[0].y)};
    if (isArray) {
        if (!writeRecord(out, 0x13, 0x02, int2Payload({static_cast<int16_t>(shape.arrayCols),
            static_cast<int16_t>(shape.arrayRows)}))) return false;
        xy.push_back(nmToDbu(shape.points[0].x + shape.arrayCols * shape.arrayColStepX));
        xy.push_back(nmToDbu(shape.points[0].y + shape.arrayCols * shape.arrayColStepY));
        xy.push_back(nmToDbu(shape.points[0].x + shape.arrayRows * shape.arrayRowStepX));
        xy.push_back(nmToDbu(shape.points[0].y + shape.arrayRows * shape.arrayRowStepY));
    }
    if (!writeRecord(out, 0x10, 0x03, int4Payload(xy))) return false;
    if (!writeProperties(out, shape.properties)) return false;
    if (!writeRecord(out, 0x11, 0x00)) return false;
    return true;
}

bool writeShape(std::vector<uint8_t>& out, const LayoutShape& shape,
                const std::map<int, std::string>& idToName) {
    if (!std::isfinite(shape.rotation) || !std::isfinite(shape.magnification) || shape.magnification <= 0) return false;
    if (shape.type == "instance") {
        return writeInstance(out, shape, idToName);
    }
    if (shape.type == "path") {
        return writePath(out, shape);
    }
    if (shape.type == "node") {
        return writeNode(out, shape);
    }
    if (shape.type == "text") {
        return writeText(out, shape);
    }
    if (shape.type == "rect" || shape.type == "polygon" || shape.type == "box") {
        return writeBoundary(out, shape);
    }
    return false;
}

} // namespace

static GdsiiWriteResult WriteGdsiiToBufferImpl(const GdsiiParseResult& layout, std::vector<uint8_t>& out) {
    GdsiiWriteResult result;
    out.clear();

    if (layout.cells.empty() && layout.shapes.empty()) {
        result.errorMessage = "empty layout";
        return result;
    }

    out.reserve(256 + layout.cells.size() * 64 + layout.shapes.size() * 48);

    const int topId = layout.primaryTopCellId >= 0 ? layout.primaryTopCellId : 0;
    std::map<int, std::string> idToName;
    for (size_t i = 0; i < layout.cells.size(); ++i) {
        idToName[static_cast<int>(i)] = sanitizeName(layout.cells[i].name, "CELL_" + std::to_string(i));
    }
    if (idToName.find(topId) == idToName.end()) {
        idToName[topId] = sanitizeName(layout.libName.empty() ? "TOP" : layout.libName, "TOP");
    }

    std::map<int, std::vector<const LayoutShape*>> byOwner;
    for (const auto& s : layout.shapes) {
        int owner = s.ownerCellId >= 0 ? s.ownerCellId : topId;
        byOwner[owner].push_back(&s);
        if (idToName.find(owner) == idToName.end()) {
            idToName[owner] = "CELL_" + std::to_string(owner);
        }
        if (s.type == "instance" && s.cellId >= 0 && idToName.find(s.cellId) == idToName.end()) {
            idToName[s.cellId] = sanitizeName(s.cellName, "CELL_" + std::to_string(s.cellId));
        }
    }

    for (size_t i = 0; i < layout.cells.size(); ++i) {
        const int id = static_cast<int>(i);
        if (byOwner.find(id) == byOwner.end()) {
            byOwner[id] = {};
        }
    }

    std::vector<int> writeOrder;
    std::set<std::string> names;
    for (const auto& kv : idToName) {
        if (!names.insert(kv.second).second) {
            result.errorMessage = "Duplicate GDSII cell name: " + kv.second;
            return result;
        }
        if (kv.first != topId) {
            writeOrder.push_back(kv.first);
        }
    }
    std::sort(writeOrder.begin(), writeOrder.end());
    writeOrder.push_back(topId);

    const std::string libName = sanitizeName(layout.libName, "HONGTU_LIB");
    const double userUnits = layout.userUnits > 0 ? layout.userUnits : 0.001;
    const double physicalUnits = layout.physicalUnits > 0 ? layout.physicalUnits : 1e-9;
    const double scaleNm = physicalUnits * 1e9;
    if (!std::isfinite(scaleNm) || !std::isfinite(userUnits)) {
        result.errorMessage = "Invalid GDSII units";
        return result;
    }
    g_nmToDbuScale = (scaleNm > 0.0) ? (1.0 / scaleNm) : 1.0;
    g_quantization = QuantizationReport{};
    g_quantization.dbuNm = scaleNm;

    if (!writeRecord(out, 0x00, 0x02, int2Payload({600})) ||
        !writeRecord(out, 0x01, 0x02, int2Payload(dateWords())) ||
        !writeRecord(out, 0x02, 0x06, stringPayload(libName)) ||
        !writeRecord(out, 0x03, 0x05, real8Payload({userUnits, physicalUnits}))) {
        result.success = false;
        result.errorMessage = "failed to write GDSII header";
        return result;
    }

    if (!writeProperties(out, layout.libProperties)) {
        result.success = false;
        result.errorMessage = "failed to write GDSII library properties";
        return result;
    }

    int writtenShapes = 0;
    int skipped = 0;
    int writtenCells = 0;
    bool structuralOk = true;
    try { layout_context::ValidateOrdinaryProperties(layout,true); layout_context::Validate(layout); const auto context=port_codec::Encode(layout); if(!writeContextCell(out,layout,context,idToName)) throw std::invalid_argument("Failed to write KLayout context container"); }
    catch(const std::exception& e){result.errorMessage=e.what();out.clear();return result;}

    for (int cellId : writeOrder) {
        const std::string cellName = idToName[cellId];
        if (!writeRecord(out, 0x05, 0x02, int2Payload(dateWords())) ||
            !writeRecord(out, 0x06, 0x06, stringPayload(cellName))) {
            structuralOk = false;
            break;
        }
        if (cellId >= 0 && cellId < static_cast<int>(layout.cells.size()) &&
            !writeProperties(out, layout.cells[static_cast<size_t>(cellId)].properties)) {
            structuralOk = false;
            break;
        }
        const auto it = byOwner.find(cellId);
        if (it != byOwner.end()) {
            for (const LayoutShape* sp : it->second) {
                const uint64_t before = g_quantization.quantizedValueCount;
                if (writeShape(out, *sp, idToName)) {
                    writtenShapes++;
                    if (g_quantization.quantizedValueCount > before) ++g_quantization.quantizedShapeCount;
                } else {
                    skipped++;
                }
            }
        }
        if (!writeRecord(out, 0x07, 0x00)) {
            structuralOk = false;
            break;
        }
        writtenCells++;
    }

    if (structuralOk && !writeRecord(out, 0x04, 0x00)) {
        structuralOk = false;
    }

    result.writtenCells = writtenCells;
    result.writtenShapes = writtenShapes;
    result.skippedShapes = skipped;
    result.bytes = out.size();
    result.quantization = g_quantization;
    if (!structuralOk) {
        result.success = false;
        result.errorMessage = "GDSII record too large or structural write failed";
        return result;
    }
    result.success = skipped == 0 && (writtenCells > 0 || layout.cells.empty());
    if (!result.success) {
        result.errorMessage = skipped > 0 ? "GDSII save rejected: unrepresentable shape or property" : "no cells written";
        out.clear();
    }
    return result;
}

GdsiiWriteResult WriteGdsiiToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out) {
    try {
        return WriteGdsiiToBufferImpl(layout, out);
    } catch (const std::exception& error) {
        out.clear();
        GdsiiWriteResult result;
        result.errorMessage = error.what();
        return result;
    }
}

GdsiiWriteResult WriteGdsii(const GdsiiParseResult& layout, const std::string& filePath) {
    std::vector<uint8_t> buf;
    GdsiiWriteResult r = WriteGdsiiToBuffer(layout, buf);
    if (!r.success) {
        return r;
    }
    std::ofstream file(filePath, std::ios::binary);
    if (!file) {
        r.success = false;
        r.errorMessage = "cannot open for write: " + filePath;
        return r;
    }
    file.write(reinterpret_cast<const char*>(buf.data()), static_cast<std::streamsize>(buf.size()));
    if (!file) {
        r.success = false;
        r.errorMessage = "write failed: " + filePath;
        return r;
    }
    return r;
}

} // namespace hongtu
