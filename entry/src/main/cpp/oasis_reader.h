/**
 * 鸿图 OASIS 格式解析器（SEMI P39 完整实现）
 *
 * OASIS (Open Artwork System Interchange Standard, SEMI P39) 是 GDSII 的现代继任者：
 * 二进制格式，使用变长整数、delta 编码点列表、modal 状态机与 CBLOCK 压缩。
 *
 * 已实现（对齐 SEMI P39-0304）：
 * - 文件魔数 "%SEMI-OASIS\r\n"；START/END 记录（含 real 型 unit 与偏移表）
 * - 全部 8 种 real 编码（正/负整数、倒数、比值、float32/float64）
 * - 名称表：CELLNAME/TEXTSTRING/PROPNAME/PROPSTRING（隐式自增 + 显式 refnum，
 *   支持前向引用，解析结束统一回填）
 * - LAYERNAME 记录（interval 编码正确跳过）
 * - CELL（记录 13 按 refnum / 记录 14 按名称）；每 Cell modal 状态复位
 * - modal 状态机：layer/datatype/text-layer/text-type/xy-mode/geometry-x/y、
 *   placement-x/y、text-x/y、geometry-w/h、path-halfwidth/extension、
 *   polygon/path point-list、ctrapezoid-type、circle-radius、repetition
 * - XYABSOLUTE / XYRELATIVE 坐标模式
 * - 几何记录：RECTANGLE(20，含 S 方形)、POLYGON(21)、PATH(22，含 extension scheme)、
 *   TRAPEZOID(23/24/25，水平/垂直)、CTRAPEZOID(26，26 种)、
 *   CIRCLE(27，弦高误差自适应多边形离散，保底 32 段、上限 4096 段)、TEXT(19)、XGEOMETRY(33，跳过)
 * - PLACEMENT(17 直角旋转 / 18 任意角度+缩放，real 编码)
 * - 点列表全部 6 种：1-delta(h/v 首发，多边形隐式闭合)、2-delta、3-delta、
 *   g-delta、双 g-delta
 * - repetition 全部 12 种（0 复用 modal；1-11 网格/不等距/任意向量）；
 *   PLACEMENT 的 regular 1/2/3/8/9 保留一个 instance array，其余元素按位移展开
 * - PROPERTY(28/29) 全部 value 类型解析并保留；XNAME/XELEMENT 跳过
 * - CBLOCK(34) DEFLATE 解压（优先走系统 zlib 高速流式解压，保留内置解码器兜底）
 *
 * This file is part of HongTu, licensed under GPLv3.
 * OASIS spec: SEMI P39; 参考 KLayout dbOASISReader 语义。
 */

#pragma once

#include <string>
#include "gdsii_reader.h"  // 复用 LayerInfo, CellInfo, GdsiiParseResult, LayoutShape

namespace hongtu {

/**
 * OASIS 解析器（无状态外壳；每次调用内部新建解析会话）
 */
class OasisReader {
public:
    OasisReader() = default;
    ~OasisReader() = default;

    GdsiiParseResult quickInfo(const std::string& filePath, const NativeJobControl* control = nullptr);
    GdsiiParseResult parse(const std::string& filePath, const NativeJobControl* control = nullptr);
};

} // namespace hongtu
