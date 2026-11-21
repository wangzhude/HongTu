/**
 * 共享校验算法 — CRC32 (IEEE 802.3) 与 checksum32（字节和）
 *
 * 使用方：
 * - oasis_reader/oasis_writer：SEMI P39 END 记录 validation-scheme 1/2
 * - png_writer：PNG chunk CRC
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <array>
#include <functional>

namespace hongtu {
namespace checksums {

namespace detail {
inline uint32_t crc32Entry(uint32_t n) {
    uint32_t c = n;
    for (int k = 0; k < 8; k++) {
        c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
    }
    return c;
}
} // namespace detail

/** 标准 CRC32（初值/终值取反已含），返回最终值 */
inline uint32_t Crc32(const uint8_t* data, size_t len, std::function<void()> checkpoint = nullptr) {
    // Function-local const initialization is synchronized by C++11+, including first concurrent use.
    static const std::array<uint32_t, 256> table = []() {
        std::array<uint32_t, 256> out{};
        for (uint32_t n = 0; n < 256; n++) {
            out[n] = detail::crc32Entry(n);
        }
        return out;
    }();
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) {
        if (checkpoint && (i & 4095) == 0) checkpoint();
        crc = table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

/** OASIS validation-scheme 2：全字节无进位求和 mod 2^32 */
inline uint32_t Checksum32(const uint8_t* data, size_t len, std::function<void()> checkpoint = nullptr) {
    uint32_t sum = 0;
    for (size_t i = 0; i < len; i++) {
        if (checkpoint && (i & 4095) == 0) checkpoint();
        sum += data[i];
    }
    return sum;
}

} // namespace checksums
} // namespace hongtu
