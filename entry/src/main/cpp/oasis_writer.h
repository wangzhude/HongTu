/**
 * 鸿图 OASIS 结构化写出（SEMI P39）
 *
 * 按 ownerCellId 预分组（O(N_cells + N_shapes)）将 LayoutShape 写回 OASIS：
 * - CELLNAME / TEXTSTRING 名称表（隐式 refnum，与 reader 的表语义对齐）
 * - 每 Cell 独立顶层 CELL(13) 记录；几何体支持标准 CBLOCK(34, RFC1951 raw DEFLATE) 压缩
 * - layer/datatype 走 modal（变化时才发射）
 * - RECTANGLE / POLYGON(g-delta) / PATH(halfwidth+flush 延伸) / TEXT(refnum)
 * - PLACEMENT：直角且无缩放走 17（AA 位），任意角度/缩放走 18（real）
 * - regular AREF 保留为一个 PLACEMENT + 标准 repetition（双维 type 8、行向 type 9）
 * - 规范 256 字节 END 记录 + CRC32 校验签名（validation-scheme 1）
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#ifndef OASIS_WRITER_H
#define OASIS_WRITER_H

#include "gdsii_writer.h" // 复用 GdsiiWriteResult / GdsiiParseResult

namespace hongtu {

/** OASIS 写出选项（默认启用标准 SEMI P39 CBLOCK 压缩，在压缩净收益为正时自动封装 Cell 记录块） */
struct OasisWriteOptions {
    bool useCBlock = true;
    size_t cblockMinBytes = 64;
    int compressionLevel = 6;
};

/**
 * 将解析结果按 Cell 结构写出为 OASIS 文件。
 * 单位：doc.physicalUnits（米/dbu）→ START unit（dbu/µm）。
 */
GdsiiWriteResult WriteOasis(const GdsiiParseResult& layout, const std::string& filePath);
GdsiiWriteResult WriteOasis(const GdsiiParseResult& layout, const std::string& filePath,
                            const OasisWriteOptions& options);

/** 写出到内存缓冲区（便于测试）。 */
GdsiiWriteResult WriteOasisToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out);
GdsiiWriteResult WriteOasisToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out,
                                    const OasisWriteOptions& options);

} // namespace hongtu

#endif // OASIS_WRITER_H
