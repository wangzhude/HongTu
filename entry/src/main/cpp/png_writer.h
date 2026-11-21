/**
 * 自包含 PNG 编码器 — 图像导出专用
 *
 * 无外部依赖：zlib 流用自带 DEFLATE（固定哈夫曼 + LZ77，收益不足时退回 stored 块），
 * 输出为完全合规的 PNG（8-bit RGBA, color type 6），任何解码器可读。
 * 版图截图多为大片同色，长匹配 + 固定哈夫曼通常能压到 stored 的几十分之一。
 *
 * 自检闭环：tools/image_export_smoke.cpp 用 inflate_tiny 解回 IDAT
 * 像素数据验证往返一致。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <fstream>
#include <string>
#include <vector>

#include "checksums.h"

namespace hongtu {
namespace pngwriter {

namespace detail {

inline uint32_t adler32(const uint8_t* data, size_t len) {
    uint32_t a = 1;
    uint32_t b = 0;
    for (size_t i = 0; i < len; i++) {
        a = (a + data[i]) % 65521u;
        b = (b + a) % 65521u;
    }
    return (b << 16) | a;
}

inline void pushU32BE(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(v & 0xFF));
}

inline void writeChunk(std::vector<uint8_t>& out, const char type[4],
                       const std::vector<uint8_t>& data) {
    pushU32BE(out, static_cast<uint32_t>(data.size()));
    std::vector<uint8_t> typeAndData;
    typeAndData.reserve(4 + data.size());
    typeAndData.insert(typeAndData.end(), type, type + 4);
    typeAndData.insert(typeAndData.end(), data.begin(), data.end());
    out.insert(out.end(), typeAndData.begin(), typeAndData.end());
    pushU32BE(out, checksums::Crc32(typeAndData.data(), typeAndData.size()));
}

/** raw → zlib 流（stored DEFLATE 块 ≤65535 字节切分 + adler32） */
inline std::vector<uint8_t> zlibStored(const std::vector<uint8_t>& raw) {
    std::vector<uint8_t> z;
    z.push_back(0x78); // CMF: deflate, 32K window
    z.push_back(0x01); // FLG: no dict, fastest（校验位合法：0x7801 % 31 == 0）
    size_t pos = 0;
    const size_t kBlock = 65535;
    do {
        const size_t n = raw.size() - pos < kBlock ? raw.size() - pos : kBlock;
        const bool last = pos + n >= raw.size();
        z.push_back(last ? 0x01 : 0x00); // BFINAL + BTYPE=00
        z.push_back(static_cast<uint8_t>(n & 0xFF));
        z.push_back(static_cast<uint8_t>((n >> 8) & 0xFF));
        z.push_back(static_cast<uint8_t>(~n & 0xFF));
        z.push_back(static_cast<uint8_t>((~n >> 8) & 0xFF));
        z.insert(z.end(), raw.begin() + static_cast<long>(pos),
                 raw.begin() + static_cast<long>(pos + n));
        pos += n;
    } while (pos < raw.size());
    pushU32BE(z, adler32(raw.data(), raw.size()));
    return z;
}

/**
 * raw → zlib 流：真正的 DEFLATE（fixed Huffman + LZ77 贪心匹配），
 * 压缩无效时自动退回 stored 块——版图截图是大片同色，固定哈夫曼 + 长匹配收益明显。
 *
 * 正确性由独立解码器闭环验证：tools/image_export_smoke.cpp 用 inflate_tiny
 * 解开 IDAT 还原扫描线并逐像素断言颜色（不是拿本文件的编码器自证）。
 */
namespace zdetail {

/** LSB-first 位流；哈夫曼码需先反转再喂入（RFC1951 §3.1.1 与 §3.2.2 的组合规定） */
struct BitWriter {
    std::vector<uint8_t>& out;
    uint32_t buf = 0;
    int nbits = 0;
    explicit BitWriter(std::vector<uint8_t>& o) : out(o) {}
    void put(uint32_t v, int n) {
        buf |= (v & ((n >= 32) ? 0xFFFFFFFFu : ((1u << n) - 1u))) << nbits;
        nbits += n;
        while (nbits >= 8) {
            out.push_back(static_cast<uint8_t>(buf & 0xFFu));
            buf >>= 8;
            nbits -= 8;
        }
    }
    void finish() {
        if (nbits > 0) {
            out.push_back(static_cast<uint8_t>(buf & 0xFFu));
        }
        buf = 0;
        nbits = 0;
    }
};

inline int reverseBits(uint32_t v, int n) {
    int r = 0;
    for (int i = 0; i < n; i++) {
        r = (r << 1) | static_cast<int>((v >> i) & 1u);
    }
    return r;
}

inline void emitLit(BitWriter& bw, uint32_t lit) {
    if (lit < 144) {
        bw.put(static_cast<uint32_t>(reverseBits(0x30 + lit, 8)), 8);
    } else {
        bw.put(static_cast<uint32_t>(reverseBits(0x190 + (lit - 144), 9)), 9);
    }
}

/** 长度码 257..285（基数 + 附加位），RFC1951 §3.2.5 表 */
inline void emitLen(BitWriter& bw, uint32_t len) {
    static const uint16_t base[29] = {3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
                                     31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
    static const uint8_t extra[29] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
                                      2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
    int idx = 28;
    for (int i = 0; i < 29; i++) {
        if (len < base[i]) {
            idx = i - 1;
            break;
        }
    }
    if (len >= 258) {
        idx = 28;
    }
    const uint32_t code = 257 + static_cast<uint32_t>(idx);
    const int lenBits = (code <= 279) ? 7 : 8;
    const uint32_t start = (code <= 279) ? 0x00u : 0xC0u;
    bw.put(static_cast<uint32_t>(reverseBits(start + (code - ((code <= 279) ? 256u : 280u)), lenBits)), lenBits);
    const uint32_t delta = len - base[idx];
    if (extra[idx] > 0) {
        bw.put(delta, extra[idx]);
    }
}

/** 距离码 0..29，固定哈夫曼下恒为 5 位 */
inline void emitDist(BitWriter& bw, uint32_t dist) {
    static const uint16_t base[30] = {1,     2,     3,     4,     5,     7,     9,     13,
                                      17,    25,    33,    49,    65,    97,    129,   193,
                                      257,   385,   513,   769,   1025,  1537,  2049,  3073,
                                      4097,  6145,  8193,  12289, 16385, 24577};
    static const uint8_t extra[30] = {0, 0, 0,  0,  1,  1,  2,  2,  3,  3,
                                      4, 4, 5,  5,  6,  6,  7,  7,  8,  8,
                                      9, 9, 10, 10, 11, 11, 12, 12, 13, 13};
    int idx = 29;
    for (int i = 0; i < 30; i++) {
        if (dist < base[i]) {
            idx = i - 1;
            break;
        }
    }
    bw.put(static_cast<uint32_t>(reverseBits(static_cast<uint32_t>(idx), 5)), 5);
    if (extra[idx] > 0) {
        bw.put(dist - base[idx], extra[idx]);
    }
}

} // namespace zdetail

inline std::vector<uint8_t> zlibDeflate(const std::vector<uint8_t>& raw) {
    using namespace zdetail;
    std::vector<uint8_t> z;
    z.push_back(0x78);
    z.push_back(0x01);
    BitWriter bw(z);
    bw.put(1, 1);   // BFINAL
    bw.put(1, 2);   // BTYPE = 01 固定哈夫曼

    const size_t n = raw.size();
    std::vector<int> head(1 << 15, -1);
    std::vector<int> prev(n, -1);
    auto hash3 = [&raw](size_t i) -> size_t {
        const uint32_t a = raw[i], b = raw[i + 1], c = raw[i + 2];
        return ((a * 19777u + b * 4224u + c * 2053u) >> 2) & 0x7FFFu;
    };
    size_t i = 0;
    while (i < n) {
        int bestLen = 0;
        int bestDist = 0;
        if (i + 3 <= n) {
            const size_t hv = hash3(i);
            int cand = head[hv];
            int tries = 0;
            while (cand >= 0 && i - static_cast<size_t>(cand) <= 32768 && tries < 64) {
                int l = 0;
                const size_t maxLen = std::min<size_t>(258, n - i);
                while (l < static_cast<int>(maxLen) &&
                       raw[static_cast<size_t>(cand) + l] == raw[i + l]) {
                    l++;
                }
                if (l > bestLen) {
                    bestLen = l;
                    bestDist = static_cast<int>(i - static_cast<size_t>(cand));
                    if (l >= 258) {
                        break;
                    }
                }
                cand = prev[static_cast<size_t>(cand)];
                tries++;
            }
        }
        if (bestLen >= 3) {
            emitLen(bw, static_cast<uint32_t>(bestLen));
            emitDist(bw, static_cast<uint32_t>(bestDist));
            for (int k = 0; k < bestLen; k++) {
                const size_t p = i + static_cast<size_t>(k);
                if (p + 3 <= n) {
                    const size_t hv = hash3(p);
                    prev[p] = head[hv];
                    head[hv] = static_cast<int>(p);
                }
            }
            i += static_cast<size_t>(bestLen);
        } else {
            emitLit(bw, raw[i]);
            if (i + 3 <= n) {
                const size_t hv = hash3(i);
                prev[i] = head[hv];
                head[hv] = static_cast<int>(i);
            }
            i++;
        }
    }
    bw.put(static_cast<uint32_t>(reverseBits(0x00, 7)), 7);   // EOB (256)
    bw.finish();
    pushU32BE(z, adler32(raw.data(), raw.size()));

    // 极端情况下（随机字节）压缩反而更大：退回 stored，保证不比原样差
    if (z.size() >= raw.size() + 64) {
        return zlibStored(raw);
    }
    return z;
}

} // namespace detail

/**
 * 将 RGBA 像素缓冲编码为 PNG 字节流。
 * @param pixels RGBA，按行主序，width*height*4 字节
 */
inline std::vector<uint8_t> encodeRgba(const std::vector<uint8_t>& pixels,
                                       int width, int height) {
    std::vector<uint8_t> out;
    if (width <= 0 || height <= 0 ||
        pixels.size() < static_cast<size_t>(width) * static_cast<size_t>(height) * 4) {
        return out;
    }

    static const uint8_t kSignature[8] = {0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    out.insert(out.end(), kSignature, kSignature + 8);

    // IHDR
    std::vector<uint8_t> ihdr;
    detail::pushU32BE(ihdr, static_cast<uint32_t>(width));
    detail::pushU32BE(ihdr, static_cast<uint32_t>(height));
    ihdr.push_back(8);  // bit depth
    ihdr.push_back(6);  // color type RGBA
    ihdr.push_back(0);  // compression
    ihdr.push_back(0);  // filter
    ihdr.push_back(0);  // interlace
    detail::writeChunk(out, "IHDR", ihdr);

    // IDAT：每行前置 filter 0 字节
    std::vector<uint8_t> raw;
    raw.reserve(static_cast<size_t>(height) * (static_cast<size_t>(width) * 4 + 1));
    for (int y = 0; y < height; y++) {
        raw.push_back(0); // filter: None
        const size_t rowStart = static_cast<size_t>(y) * static_cast<size_t>(width) * 4;
        raw.insert(raw.end(), pixels.begin() + static_cast<long>(rowStart),
                   pixels.begin() + static_cast<long>(rowStart + static_cast<size_t>(width) * 4));
    }
    detail::writeChunk(out, "IDAT", detail::zlibDeflate(raw));

    // IEND
    detail::writeChunk(out, "IEND", {});
    return out;
}

/** 编码并写文件 */
inline bool saveRgba(const std::string& filePath, const std::vector<uint8_t>& pixels,
                     int width, int height) {
    const std::vector<uint8_t> png = encodeRgba(pixels, width, height);
    if (png.empty()) {
        return false;
    }
    std::ofstream file(filePath, std::ios::binary);
    if (!file.is_open()) {
        return false;
    }
    file.write(reinterpret_cast<const char*>(png.data()),
               static_cast<std::streamsize>(png.size()));
    return file.good();
}

} // namespace pngwriter
} // namespace hongtu
