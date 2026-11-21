/**
 * HongTu 内置演示层号；与 ArkTS common/constants.ets::DemoLayerNumber 对齐。
 * GDS/OASIS 读取器保留文件原始 layer/datatype，绝不按本表重映射。
 * 导入版图的工艺语义须由用户提供，不能把本表当成任意 PDK 的层表。
 */
#ifndef HONGTU_DEMO_LAYERS_H
#define HONGTU_DEMO_LAYERS_H

namespace hongtu::demo_layers {
constexpr int kMetal1 = 1;
constexpr int kMetal2 = 2;
constexpr int kMetal3 = 3;
constexpr int kPoly = 4;
constexpr int kActive = 5;
constexpr int kVia1 = 10;
constexpr int kVia2 = 11;
constexpr int kVia3 = 12; // 演示层名预留；没有定义 M4，故不自动跨层连通。
} // namespace hongtu::demo_layers

#endif // HONGTU_DEMO_LAYERS_H
