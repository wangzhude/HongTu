/**
 * 自包含 RFC1951 (raw DEFLATE) 解压器 — OASIS CBLOCK 专用
 *
 * 为什么不直接用 zlib：
 * - 设备端虽有 libz.so，但 host 冒烟测试（tools/run_native_smoke.ps1 用 MSVC cl 直接
 *   编译 oasis_reader.cpp）没有 zlib 头/库；内置实现让解析器在两端行为一致、可测。
 * - 实现按 Mark Adler 的 puff.c 参考算法（逐位霍夫曼解码），正确性优先于吞吐；
 *   OASIS CBLOCK 通常为几十 KB 级，性能足够。
 *
 * 支持: stored (BTYPE=00) / fixed Huffman (01) / dynamic Huffman (10) 块。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#pragma once

#include <cstdint>
#include <cstddef>
#include <vector>
#include <functional>

namespace hongtu {
namespace tinyinflate {

namespace detail {

struct BitStream {
    const uint8_t* data;
    size_t size;
    size_t pos = 0;
    uint32_t bitBuf = 0;
    int bitCnt = 0;
    std::function<void()> checkpoint;
    uint64_t ticks = 0;

    /** 取 k 位（LSB-first）；数据耗尽返回 -1 */
    int bits(int k) {
        if (checkpoint && (++ticks & 1023) == 0) checkpoint();
        while (bitCnt < k) {
            if (pos >= size) {
                return -1;
            }
            bitBuf |= static_cast<uint32_t>(data[pos++]) << bitCnt;
            bitCnt += 8;
        }
        const int v = static_cast<int>(bitBuf & ((1u << k) - 1u));
        bitBuf >>= k;
        bitCnt -= k;
        return v;
    }

    /** 丢弃到字节边界（stored 块前） */
    void alignByte() {
        const int drop = bitCnt & 7;
        bitBuf >>= drop;
        bitCnt -= drop;
    }
};

struct Huffman {
    int count[16] = {0};   // 每个码长的码数
    int symbol[320] = {0}; // 按码长排序的符号
};

/** 从码长表构建 canonical 霍夫曼表。返回 0=完备, >0=不完备(允许单码), <0=超额(损坏) */
inline int buildHuffman(Huffman& h, const uint8_t* lengths, int n) {
    for (int i = 0; i < 16; i++) {
        h.count[i] = 0;
    }
    for (int i = 0; i < n; i++) {
        h.count[lengths[i]]++;
    }
    if (h.count[0] == n) {
        return 0; // 无码（合法：空表）
    }
    int left = 1;
    for (int len = 1; len <= 15; len++) {
        left <<= 1;
        left -= h.count[len];
        if (left < 0) {
            return left; // 超额分配 → 损坏
        }
    }
    int offs[16];
    offs[1] = 0;
    for (int len = 1; len < 15; len++) {
        offs[len + 1] = offs[len] + h.count[len];
    }
    for (int sym = 0; sym < n; sym++) {
        if (lengths[sym] != 0) {
            h.symbol[offs[lengths[sym]]++] = sym;
        }
    }
    return left;
}

/** 逐位解码一个符号；失败返回 -1 */
inline int decodeSymbol(BitStream& s, const Huffman& h) {
    int code = 0;
    int first = 0;
    int index = 0;
    for (int len = 1; len <= 15; len++) {
        const int b = s.bits(1);
        if (b < 0) {
            return -1;
        }
        code |= b;
        const int cnt = h.count[len];
        if (code - first < cnt) {
            return h.symbol[index + (code - first)];
        }
        index += cnt;
        first += cnt;
        first <<= 1;
        code <<= 1;
    }
    return -1;
}

/** 解 literal/length + distance 编码块主体 */
inline bool inflateCodes(BitStream& s, const Huffman& lenTab, const Huffman& distTab,
                         std::vector<uint8_t>& out, size_t maxOut) {
    static const int kLenBase[29] = {
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258};
    static const int kLenExtra[29] = {
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0};
    static const int kDistBase[30] = {
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
        8193, 12289, 16385, 24577};
    static const int kDistExtra[30] = {
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13};

    while (true) {
        int sym = decodeSymbol(s, lenTab);
        if (sym < 0) {
            return false;
        }
        if (sym < 256) {
            if (out.size() >= maxOut) {
                return false;
            }
            out.push_back(static_cast<uint8_t>(sym));
        } else if (sym == 256) {
            return true; // 块结束
        } else {
            sym -= 257;
            if (sym >= 29) {
                return false;
            }
            const int eb = s.bits(kLenExtra[sym]);
            if (eb < 0) {
                return false;
            }
            const int length = kLenBase[sym] + eb;

            const int dsym = decodeSymbol(s, distTab);
            if (dsym < 0 || dsym >= 30) {
                return false;
            }
            const int deb = s.bits(kDistExtra[dsym]);
            if (deb < 0) {
                return false;
            }
            const size_t dist = static_cast<size_t>(kDistBase[dsym]) + static_cast<size_t>(deb);
            if (dist > out.size()) {
                return false; // 引用越过窗口起点 → 损坏
            }
            if (out.size() + static_cast<size_t>(length) > maxOut) {
                return false;
            }
            size_t from = out.size() - dist;
            for (int i = 0; i < length; i++) {
                out.push_back(out[from++]);
            }
        }
    }
}

inline bool inflateStored(BitStream& s, std::vector<uint8_t>& out, size_t maxOut) {
    s.alignByte();
    // LEN + NLEN（各 2 字节 LE）— 经位流读取保证 pos 同步
    const int l0 = s.bits(8), l1 = s.bits(8), n0 = s.bits(8), n1 = s.bits(8);
    if (l0 < 0 || l1 < 0 || n0 < 0 || n1 < 0) {
        return false;
    }
    const unsigned len = static_cast<unsigned>(l0) | (static_cast<unsigned>(l1) << 8);
    const unsigned nlen = static_cast<unsigned>(n0) | (static_cast<unsigned>(n1) << 8);
    if ((len ^ 0xFFFFu) != nlen) {
        return false;
    }
    if (out.size() + len > maxOut) {
        return false;
    }
    for (unsigned i = 0; i < len; i++) {
        const int b = s.bits(8);
        if (b < 0) {
            return false;
        }
        out.push_back(static_cast<uint8_t>(b));
    }
    return true;
}

inline bool inflateFixed(BitStream& s, std::vector<uint8_t>& out, size_t maxOut) {
    uint8_t litLens[288];
    for (int i = 0; i < 144; i++) litLens[i] = 8;
    for (int i = 144; i < 256; i++) litLens[i] = 9;
    for (int i = 256; i < 280; i++) litLens[i] = 7;
    for (int i = 280; i < 288; i++) litLens[i] = 8;
    uint8_t distLens[30];
    for (int i = 0; i < 30; i++) distLens[i] = 5;

    Huffman lenTab, distTab;
    if (buildHuffman(lenTab, litLens, 288) < 0) return false;
    if (buildHuffman(distTab, distLens, 30) < 0) return false;
    return inflateCodes(s, lenTab, distTab, out, maxOut);
}

inline bool inflateDynamic(BitStream& s, std::vector<uint8_t>& out, size_t maxOut) {
    static const int kOrder[19] = {16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15};

    const int hlit = s.bits(5);
    const int hdist = s.bits(5);
    const int hclen = s.bits(4);
    if (hlit < 0 || hdist < 0 || hclen < 0) {
        return false;
    }
    const int nlen = hlit + 257;
    const int ndist = hdist + 1;
    const int ncode = hclen + 4;
    if (nlen > 288 || ndist > 30) {
        return false;
    }

    uint8_t clLens[19] = {0};
    for (int i = 0; i < ncode; i++) {
        const int v = s.bits(3);
        if (v < 0) {
            return false;
        }
        clLens[kOrder[i]] = static_cast<uint8_t>(v);
    }
    Huffman clTab;
    if (buildHuffman(clTab, clLens, 19) < 0) {
        return false;
    }

    uint8_t lens[288 + 30] = {0};
    int idx = 0;
    while (idx < nlen + ndist) {
        const int sym = decodeSymbol(s, clTab);
        if (sym < 0) {
            return false;
        }
        if (sym < 16) {
            lens[idx++] = static_cast<uint8_t>(sym);
        } else if (sym == 16) {
            if (idx == 0) {
                return false;
            }
            const int rep = s.bits(2);
            if (rep < 0) return false;
            const uint8_t prev = lens[idx - 1];
            for (int i = 0; i < rep + 3 && idx < nlen + ndist; i++) {
                lens[idx++] = prev;
            }
        } else if (sym == 17) {
            const int rep = s.bits(3);
            if (rep < 0) return false;
            for (int i = 0; i < rep + 3 && idx < nlen + ndist; i++) {
                lens[idx++] = 0;
            }
        } else { // 18
            const int rep = s.bits(7);
            if (rep < 0) return false;
            for (int i = 0; i < rep + 11 && idx < nlen + ndist; i++) {
                lens[idx++] = 0;
            }
        }
    }
    if (lens[256] == 0) {
        return false; // 必须有块结束码
    }

    Huffman lenTab, distTab;
    if (buildHuffman(lenTab, lens, nlen) < 0) {
        return false;
    }
    if (buildHuffman(distTab, lens + nlen, ndist) < 0) {
        return false;
    }
    return inflateCodes(s, lenTab, distTab, out, maxOut);
}

} // namespace detail

/**
 * 解压 raw DEFLATE 流（无 zlib 头）。
 * @param src 压缩数据
 * @param srcLen 压缩数据长度
 * @param out 输出缓冲（追加写入；调用方通常传空 vector）
 * @param maxOut 允许的最大输出字节数（防解压炸弹）
 * @return 成功返回 true
 */
inline bool InflateRaw(const uint8_t* src, size_t srcLen, std::vector<uint8_t>& out, size_t maxOut,
                       std::function<void()> checkpoint = nullptr) {
    if (checkpoint) checkpoint();
    if (src == nullptr || srcLen == 0) {
        return false;
    }
    detail::BitStream s{src, srcLen};
    s.checkpoint = std::move(checkpoint);
    while (true) {
        const int bfinal = s.bits(1);
        const int btype = s.bits(2);
        if (bfinal < 0 || btype < 0) {
            return false;
        }
        bool ok = false;
        if (btype == 0) {
            ok = detail::inflateStored(s, out, maxOut);
        } else if (btype == 1) {
            ok = detail::inflateFixed(s, out, maxOut);
        } else if (btype == 2) {
            ok = detail::inflateDynamic(s, out, maxOut);
        } else {
            return false; // BTYPE=11 保留
        }
        if (!ok) {
            return false;
        }
        if (bfinal == 1) {
            return true;
        }
    }
}

} // namespace tinyinflate
} // namespace hongtu
