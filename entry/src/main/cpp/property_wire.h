/**
 * GDSII property bytes across the native/ArkTS document boundary.
 * Kept independent of NAPI so host tests can exercise the exact conversion.
 */
#ifndef HONGTU_PROPERTY_WIRE_H
#define HONGTU_PROPERTY_WIRE_H

#include "gdsii_reader.h"
#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>

namespace hongtu {
namespace property_wire {

// GDS record length includes a 4-byte header and must be even.
constexpr size_t kMaxPropValueBytesWire = 65530;

inline std::string TrimTrailingNul(const std::string& s) {
    size_t n = s.size();
    while (n > 0 && s[n - 1] == '\0') {
        --n;
    }
    return s.substr(0, n);
}

inline bool IsTextSafeBytes(const std::string& s) {
    for (unsigned char c : s) {
        if (c < 0x20 || c > 0x7E) {
            return false;
        }
    }
    return true;
}

inline int HexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

inline std::string ToHexWire(const std::string& raw) {
    static const char* kDigits = "0123456789ABCDEF";
    std::string out;
    out.reserve(raw.size() * 2 + 1);
    out.push_back('#');
    for (unsigned char c : raw) {
        out.push_back(kDigits[c >> 4]);
        out.push_back(kDigits[c & 0x0F]);
    }
    return out;
}

inline bool FromHexWire(const std::string& wire, std::string& out) {
    out.clear();
    if (wire.size() < 3 || wire[0] != '#' || ((wire.size() - 1) % 2) != 0) {
        return false;
    }
    out.reserve((wire.size() - 1) / 2);
    for (size_t i = 1; i < wire.size(); i += 2) {
        const int hi = HexNibble(wire[i]);
        const int lo = HexNibble(wire[i + 1]);
        if (hi < 0 || lo < 0) {
            return false;
        }
        out.push_back(static_cast<char>((hi << 4) | lo));
    }
    return true;
}

/** dtype 7 is an internal byte carrier for a GDSII ASCII property. */
inline void EncodePropertyWire(const LayoutProperty& p, int32_t& dtypeOut, std::string& valueOut) {
    if (p.dtype >= 128 && p.dtype <= 143) {
        dtypeOut = p.dtype; valueOut = p.dtype == 139 ? ToHexWire(p.value) : p.value; return;
    }
    if (p.dtype == 0) {
        dtypeOut = 0;
        valueOut.clear();
        return;
    }
    // Numeric/real values are binary even when their bytes happen to be printable.
    if (p.dtype == 2 || p.dtype == 3 || p.dtype == 4 || p.dtype == 5) {
        dtypeOut = static_cast<int32_t>(p.dtype);
        valueOut = ToHexWire(p.value);
        return;
    }
    if (p.dtype == 6 && IsTextSafeBytes(p.value)) {
        dtypeOut = 6;
        valueOut = p.value;
        return;
    }
    dtypeOut = 7;
    valueOut = ToHexWire(p.value);
}

inline bool DecodePropertyWire(int32_t attr, int32_t dtype, const std::string& name,
                               const std::string& value, LayoutProperty& out) {
    if (attr < -32768 || attr > 32767 || dtype < 0 || dtype > 255) {
        return false;
    }
    std::string bytes;
    int32_t dt = dtype;
    if (dt >= 128 && dt <= 140) {
        if (dt == 139) { if (!FromHexWire(value, bytes)) return false; }
        else bytes = value;
    } else if (dt == 0) {
        bytes.clear();
    } else if (dt == 7 || dt == 2 || dt == 3 || dt == 4 || dt == 5) {
        if (dt == 7) {
            dt = 6;
            if (!FromHexWire(value, bytes)) return false;
        } else if (!value.empty() && value[0] == '#') {
            if (!FromHexWire(value, bytes)) return false;
        } else {
            bytes = value;
        }
    } else {
        dt = 6;
        bytes = TrimTrailingNul(value);
    }
    if (bytes.size() > kMaxPropValueBytesWire) return false;
    out.attr = static_cast<int16_t>(attr);
    out.dtype = static_cast<uint8_t>(dt);
    out.name = name;
    out.value = std::move(bytes);
    return true;
}

}  // namespace property_wire
}  // namespace hongtu

#endif  // HONGTU_PROPERTY_WIRE_H
