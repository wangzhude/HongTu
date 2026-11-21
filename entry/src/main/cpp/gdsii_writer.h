/**
 * 鸿图 GDSII 结构化写出
 *
 * 按 ownerCellId 将 LayoutShape 写回 GDSII Stream：
 * 每个 Cell 独立 BGNSTR/ENDSTR，Top 只含本 Cell 本地几何 + SREF。
 * 用于 host 往返 smoke 与后续 native 保存主路径。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

#ifndef GDSII_WRITER_H
#define GDSII_WRITER_H

#include "gdsii_reader.h"

#include <cstdint>
#include <cmath>
#include <algorithm>
#include <string>
#include <vector>

namespace hongtu {

struct QuantizationReport {
    double dbuNm = 1;
    uint64_t examinedValueCount = 0;
    uint64_t quantizedValueCount = 0;
    uint64_t quantizedShapeCount = 0;
    double maximumDeviationNm = 0;
    void observe(double requestedNm, double storedNm) {
        ++examinedValueCount;
        const double deviation = std::abs(requestedNm - storedNm);
        if (deviation > dbuNm * 1e-9) {
            ++quantizedValueCount;
            maximumDeviationNm = std::max(maximumDeviationNm, deviation);
        }
    }
};

struct GdsiiWriteResult {
    bool success = false;
    std::string errorMessage;
    int writtenCells = 0;
    int writtenShapes = 0;
    int skippedShapes = 0;
    size_t bytes = 0;
    QuantizationReport quantization;
};

/**
 * 将解析结果按 Cell 结构写出到文件。
 * 写出顺序：非 primaryTop 的 Cell 在前，primaryTop 最后。
 * AREF remains a compressed array with its original parent-coordinate step vectors.
 */
GdsiiWriteResult WriteGdsii(const GdsiiParseResult& layout, const std::string& filePath);

/** 写出到内存缓冲区（便于测试）。 */
GdsiiWriteResult WriteGdsiiToBuffer(const GdsiiParseResult& layout, std::vector<uint8_t>& out);

} // namespace hongtu

#endif // GDSII_WRITER_H
