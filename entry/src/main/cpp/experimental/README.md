# experimental/ — 未接线的草案引擎模块

本目录下的头文件是引擎的**草案模块**，当前**既未加入 CMake 构建、也未被任何
NAPI 接口或冒烟测试引用**。放在此处是为了：

1. 明确标注"未接线 / 未编译 / 未验证"状态，避免误以为这些功能已交付；
2. 与正在使用的引擎核心物理隔离；
3. 保留设计骨架，供后续接线时参考。

## v0.4 已接线迁出（不再属于本目录）

以下模块已在 v0.4 完成对齐现行数据模型、修复缺陷、补冒烟测试并接入构建/NAPI：

| 模块 | 去向 | 验证 |
|------|------|------|
| `drc_engine.h` | `../drc_engine.h`（NAPI runDrc；DrcService native 主路径） | `tools/drc_smoke.cpp` |
| `image_export.h` | `../image_export.h`（NAPI exportSvg/exportPng + 自包含 `png_writer.h`） | `tools/image_export_smoke.cpp` |
| `pcell_framework.h` | `../pcell_framework.h`（NAPI listPCells/generatePCell + Basic 库） | `tools/pcell_smoke.cpp` |
| `format_readers.h` | 按现行模型重写为 `../format_readers.h`（CIF/DXF；LEF/DEF defer） | `tools/format_readers_smoke.cpp` |
| `oasis_reader_v2.h` | 已删除——`../oasis_reader.cpp` 重写为 SEMI P39 完整实现（草案偏离规范无参考价值） | `tools/oasis_smoke.cpp` |

## 仍在本目录的草案

| 头文件 | 目标能力 | 状态 |
|--------|----------|------|
| `gl_renderer_v2.h` | retained-mode GPU 渲染器（VBO 批处理/视锥裁剪/LOD/native 上色） | 目标架构，未接线；产品当前用上级目录 `gl_renderer.cpp`（immediate-mode） |
| `lvs_engine.h` | LVS 网表提取/比对 | 草案，未接线，O(n²)/O(n³) 复杂度待优化 |
| `script_engine.h` | Python/Ruby 脚本绑定 | 草案，未接线（内嵌 Python API stub 字符串）；HarmonyOS 端内嵌解释器属独立大工程，明确 defer |
| `plugin_system.h` | 插件聚合入口 | 草案，未接线 |

## 接线前必须做的工作

这些模块**从未被编译器编译过**，可能含有编译错误与未发现的缺陷。接线任一模块前：

1. 加入 `CMakeLists.txt` 或冒烟测试，先确保能编译；
2. 对齐现行数据模型（`scene_graph.h` 的 `Layout`/`Cell`/`SceneShape`）；
3. 补齐健壮性（异常守卫、边界检查、资源释放）；
4. 补单元测试与真实 fixture 验证（参考 v0.4 迁出模块的冒烟测试模式）。

## 草案编译状态（由 `tools/check_portable.sh` 机器可读地复核）

`bash tools/check_portable.sh` 用 OHOS NDK 的 clang++/libc++ 对每个草案头做
`-fsyntax-only` 检查，结果以 `[DRIFT]` 上报但**不阻塞门禁**（这些头文件按设计不入库编译）。
最近一次复核（2026-09-19）：

| 头文件 | 语法/语义状态 |
|--------|----------------|
| `gl_renderer_v2.h` | 通过编译（仅骨架，逻辑未验证） |
| `script_engine.h` | 通过编译（Python API 为 stub 字符串） |
| `plugin_system.h` | **9 处与现行数据模型不一致**，接线前必须逐条修正 |

`plugin_system.h` 的具体偏离（接线时按此清单改，勿凭记忆）：

- `222`：用了 `std::cout` 但未 `<iostream>`——本模块是库代码，不应直接写标准输出
- `259/265/268`：引用不存在的类型 `OasisReaderV2`（已删除，见上表）、`LefReader`、`DefReader`（LEF/DEF 仍为 defer）
- `287/288`：`GdsiiParseResult` 无 `databaseUnit`/`userUnit` 字段，现行名为 `userUnits`
- `297`：`LayoutShape` 无 `layer` 字段（现行图层表示已变更，见 `scene_graph.h`）
- `394`：调用 arity 不符（目标函数现需 3 个实参）
- `396`：`PngExporter::saveAsPpm` 不存在（图像导出现走 `image_export.h` + `png_writer.h`）

详见 `docs/roadmaps/klayout-feature-gap-matrix.md`。
