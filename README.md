# 鸿图 (HongTu)

2026-10-01 首批补齐：见[当前软件结构树](docs/software-structure-tree.md)、[实现与验证记录](docs/validation/feature-closure-20261001/report.md)及[31 组竞品差距进度](docs/validation/feature-closure-20261001/gap-progress.md)。这些记录明确区分已补叶子、剩余范围和模拟器验收。

> 参考 KLayout 版图模型与交互语义的 HarmonyOS NEXT 芯片版图编辑器（v0.4.0）

鸿图是一款面向 HarmonyOS NEXT 平台的芯片版图编辑器。设备端以 C++17、NAPI 和 ArkTS 实现；电脑伴随服务使用真实 CPython 与官方 `klayout.db`，提供 Python 版图生成、独立读写验证和公开工艺验证示例。布尔与偏移运算采用 vendored Clipper2 2.0.1。

AI 助手可保存多个供应商及每个供应商的多个模型，通过“供应商/模型”管理和一键获取接口模型列表。多轮 Agent 使用电脑 Python 伴随服务；设置、任务计划、工具结果、修改确认与恢复方法见 [AI 助手使用说明](docs/ai-assistant-guide.md)。

> **状态：开发与公开样本验证阶段。** GDSII/OASIS 读写、CIF/DXF 导入、层级与编辑、图像导出、PCell、DRC/LVS 预检查及电脑 Python 伴随服务已接入。2026-09-30 已在 MateBook 2in1 模拟器验证真实 DeepSeek Python 生成、预览、编辑保存和 KLayout 独立读回。不能据此认定已满足工业生产签核。最新流程证据见 [手工复画报告](docs/validation/manual-redraw-workflow-20260930.md)，Python与公开工艺基础证据见 [基础验证报告](docs/validation/industrial-foundation-20260930.md)，逐项功能见 [差距矩阵](docs/roadmaps/klayout-feature-gap-matrix.md)。

2026-10-01 的 AI 多会话与上下文功能已完成本文所列模拟器交互，见 [会话与压缩验证记录](docs/validation/ai-sessions-context-20261001.md)：旧记录迁移、会话隔离 / 搜索 / 重命名、设置保存与真实模型摘要回忆已实测；最终 build 14 验证摘要降低估算占用，并拒绝没有收益的极短摘要，原聊天保留。AI 专项7套207项通过；完整门禁由并行批次后续统一，不宣称全过或物理设备验收。此前 Markdown、逐步工具显示与网格的 HAP 5 / 8 / 9 证据保留在 [独立历史记录](docs/validation/ai-harness-markdown-20260930.md)，不与新批次混算。

## 2026-09-30：最新手工复画工作流验收

已通过真实 UI 完成官方 INVERTER 的 30 步复画：33 BOX + 4 TEXT、11 对 layer/datatype；GDS/OASIS 经系统选择器保存重开后独立严格比较通过，Recent 覆盖保存读回、Cell 菜单/名称及侧栏/面包屑刷新均已实测。最终 **26 套宿主 574 项**、Python/KLayout 23 项、20 套原生及格式保真、NDK 和 Release HAP 通过；指定 API24 x86_64 2in1 完成交互，5555 仅覆盖安装，不代表真机或完整 PDK 签核。最终包、哈希、比较结果与边界见 [手工复画报告](docs/validation/manual-redraw-workflow-20260930.md)。下列章节保留各历史批次的原计数。

## 2026-09-30：Python 与公开样本验证

- 顶栏「AI 助手 → Python 版图」：DeepSeek 编写真实 Python、运行、SVG 预览、载入为独立文档。电脑需运行 `tools/start_python_bridge.ps1`；解释器在电脑伴随进程中，未嵌入 HarmonyOS。
- 完整可信脚本 API、受限 AI 执行接口、启动方法、限制与示例见 [Python API](docs/python-api.md)。密钥迁移至 HarmonyOS AssetStore；普通设置不再保存混淆后的密钥。
- GDS 编辑保存保留 AREF 阵列、PATH4 延伸/绝对宽度和 TEXT 变换/定位；公开 SKY130 inverter/NAND2、KLayout ring oscillator 与生成样本经独立 KLayout 读回核对。
- 「SKY130 M1子集」只检查 68/20 的 m1.1、m1.2、m1.6；Python 侧提供对应 KLayout 对照和官方演示工艺的真实 MOS4 LVS。设备原生 LVS 仍为连通性预检查。
- 以上用于开发与公开样本验证。完整 PDK 规则、工艺器件提取、foundry 签核、arm64 真机和工业规模性能验收尚未完成。

## 2026-09-30：工作区、工艺与自动化增量

本轮新增入口与服务已完成 release HAP 构建及 API24 2in1 覆盖安装；最终源码 15 套宿主回归共 220 项通过，另有键盘专项 10 项及真实 KLayout/Python 18 项通过。设备已验证草稿恢复、搜索、器件库、PCell 更新/撤销、Python 文档副本、版本副本与公开子集 DRC 失败后修正复检。各流程证据和尚未覆盖的交互见 [功能补全报告](docs/validation/feature-completion-20260930.md)。

- 新建文档、多标签工作区、每页独立编辑会话；普通保存/另存、工程文件、自动草稿恢复与版本副本。保存期间继续编辑或切换页签不会清除另一版本的 dirty 状态。
- 按 Cell、图层、datatype、图形类型与文本查找定位；批量改属性保留事务撤销、层锁与完整性校验。PCell 参数随工程保存、重新打开后可编辑；持久器件库保存参数预设或 Cell 及其依赖。
- 版图 A/B 比较独立读取参考 B，按 layer/datatype 计算真实区域 XOR 和独有面积，另提供严格结构记录 Diff、差异覆盖层、Cell 定位与 JSON 报告。
- 工艺包统一管理图层用途、精确 datatype 通孔连接、DRC 规则、器件参数与 PDK/deck 关联，支持 JSON 导入导出。工艺验证面板使用当前编辑态快照运行电脑端已注册规则；内置仅为 SKY130 met1 三规则与 KLayout MOS4 演示工艺，注册接口不等于已安装完整 PDK。
- DRC、几何网络追踪、连通性预检查、SVG/PNG/OASIS 导出先同步当前编辑文档，无需先保存。选择导出目标期间切换或修改文档会拒绝过期导出。
- Python 支持新建/当前文档/选区输入、参数模板、单参数有限扫参、执行历史、预览和受保护载入/合并；宏管理支持查看、重命名、删除、导入导出和批次撤销。固定图形/Cell ID 宏绑定录制文档，切页先保存录制，错误来源整批拒绝；未实现跨文档 ID 重映射。解释器继续运行在电脑伴随服务中。

## 2026-09-30：完整操作流程复查

沿新建 / 导入、绘图、选区、变换、Cell / 器件、验证、保存 / 导出及重新打开继续修复细节。最终 24 套宿主回归共 506 项、Python/KLayout 23 项、20 套原生与格式保真检查、NDK 和 Release HAP 构建通过；独立 API24 2in1 已验证绘图退点与完成、Cell / PCell 结构撤销、GDS 保存重开、实例内部点选 / 双击、KF 框选放大及未保存新建版图导出。逐动作、证据和边界见 [流程复查报告](docs/validation/workflow-completion-20260930.md)。

- 绘图支持 Enter 完成、Backspace 退点、中断 / 切页取消，属性浮层不会遮挡继续绘图；实例使用真实可见叶几何点选，空洞与阵列缝隙不误选。
- 任意角 RECT 转真实 POLYGON；TEXT / INSTANCE 变换、AREF 步进、PATH 端帽 / 延伸 / 绝对宽度贯通命中、范围及撤销。对齐和框选使用真实可见层级范围，有显式预算。
- Cell 管理和库 / PCell 插入完整记录结构历史；图层显隐保留锁定。框选放大与新建导出补齐入口，旧快捷键配置保留自定义映射。
- 导入 / 比较 / 工艺 / 验证过期回调不应用；DRC 显式 datatype0 精确匹配；未运行、超预算及提取异常不会发布通过。电脑 Python 超时等待实际 owned 进程退出后清理临时目录。

## 功能特性

### 已实现

**核心引擎（C++17 NAPI，`entry/src/main/cpp/`）**
- GDSII 二进制解析与**结构化写出**（`gdsii_reader` / `gdsii_writer`）— NODE/属性保留；AREF 压缩阵列、PATH4 有符号延伸和绝对宽度、TEXT 变换与对齐贯通 reader→NAPI→ArkTS→native/ArkTS writer；工作区保存固定当前文档快照，服务仍保留显式确认源文件一致时的逐字节复制能力。编辑后按结构和几何等价验证，不承诺二进制逐字节相同。
- **OASIS 解析**（`oasis_reader`，SEMI P39）— modal 状态、名称表前向引用回填、6 种点列表 / 12 种 repetition、TRAPEZOID/CTRAPEZOID(26 种)/CIRCLE、PLACEMENT 17/18（real 缩放/任意角度）、**CBLOCK DEFLATE 解压**（内置 RFC1951 解码器 `inflate_tiny.h`，host/设备一致）、DoS 上限防护；未宣称完整标准认证。
- **CIF / DXF 导入**（`format_readers.h`）— CIF 符号/调用变换分解/厘微米换算；DXF R12 子集（BLOCK/LWPOLYLINE/CIRCLE/ARC/INSERT）；LEF/DEF defer
- 文档模型 `scene_graph.h`（Layout/Cell/Instance）+ KLayout 语义层级展开（`expandHierarchy`，深度可控）
- R-Tree 空间索引 `spatial_index.h`（Guttman 二次分裂 + STR 批量加载）— 点/范围/最近邻查询；kNN 为 best-first + 标准剪枝，与暴力枚举做随机差分测试（`engine_smoke`）
- 几何引擎 `geometry_engine.h`（面积/质心/点到多边形距离/仿射变换）+ 三角化 `triangulator.h`（ear-clipping）+ Clipper2 2.0.1 布尔/偏移适配 `clipper_engine.h`。KLayout/GEOS 差分覆盖整数精确例与斜边 DBU 量化界；这不等于工艺签核。
- **原生 DRC 内核**（`drc_engine.h`）— R-Tree 按层索引 + 真实边到边距离；宽度/间距/面积/包围/交叠/密度/凹口检查；RECT 归一化、PATH 轮廓化；深度可控的实例层级展开。公开 SKY130 met1 子集启用同层区域合并，其余规则仍按逐图形预检查口径。展开、合并或区域测量超限时显式报告结果不完整，**快速预检查不可作签核**。
- **图像导出**（`image_export.h` + `png_writer.h`）— SVG 矢量（按层分组）与 PNG 软件光栅（自包含编码，任何解码器可读）
- **PCell 框架**（`pcell_framework.h`）— 参数声明/校验、Basic 库 8 种（CIRCLE/DONUT/ARC/**NOPATH/NPATH/MEANDER/STAR/COMB**，参考 KLayout Basic）+ 器件库（MOSFET/VIA_STACK/GUARD_RING）、instantiate/regenerate；条带轮廓共用 `Triangulator::pathOutline`，参数经 `listPCells` 驱动 UI 动态表单；内置层号仅供演示，MOSFET 接触层须按 PDK 显式指定
- **连通性提取 / LVS 预检查**（`lvs_engine.h`）— 默认仅同层几何连通；跨层连通需要显式工艺 via 表（内置演示表只定义 Via1 与 Via2，Via3 不自动连接）。网络由 BFS 提取，TEXT 标签命名，与参考 SPICE 网表按名比对（开路/短路/多余网络三分类），`exportSpiceNetlist` 反向导出；**深度可控的实例层级展开**（`setHierarchyDepth`，与画布同一层级深度：不展开时实例内连通不参与提取）；仍为连通性级预检查、依赖版图标签，**不可作签核**
- **坐标口径契约**（gap-matrix §3 P0）— 世界坐标一律 nm（读取器单次归一 `dbu×physical×1e9`），X 向右、Y 向上，与 GDS/KLayout 一致；GL、ArkUI 覆盖层、SVG/PNG 导出共用同一显示方向。`tools/coordinate_smoke.cpp` 55 项断言与 `tools/y_up_canvas_host_check.mjs` 17 项检查覆盖相机、交互和非对称图像导出
- OpenGL ES 3.0 渲染 `gl_renderer.cpp` — VBO 批量绘制、填充/线框双着色器、凹多边形三角化填充、3x3 MVP 变换；PATH 按 `pathWidth`+`pathType` 轮廓化（flush/round/extended 三端型，与 DRC/导出共用 `Triangulator::pathOutline`）
- XComponent 渲染插件 `xcomponent_plugin.cpp` — EGL 生命周期、逐帧回调（线程安全）、触摸事件
- **52 个 NAPI 导出函数**：`napi_init_v2.cpp` 46 个（解析/写出/异步/层级展开/**renderHierarchyToSurface**/**renderSceneToSurface**/**clearRenderScene**/空间查询/布尔与几何/**regionBooleanForEdit**/**pathRegionForEdit**/**syncDocument**/**compareLayout**/**startCompareJob**/**runDrc**/**exportSvg**/**exportPng**/**listPCells**/**generatePCell**/**extractNets**/**runLvs**/**exportSpiceNetlist** 等；精确名单以 `Index.d.ts` 与注册表为准）+ `xcomponent_plugin.cpp` 6 个
- 全部 NAPI 回调含异常守卫（`NapiSafe<>`），C++ 异常不穿越边界

**工作台 UI（ArkTS，`entry/src/main/ets/`）**
- 画布优先工作台 `pages/Index.ets` — 顶栏 + 左侧工具/图层/Cell 树 + 白色画布 + 按需对象属性浮层 + DRC 底部结果区 + AI/Python 面板
- **Cell 树管理** — 按 INSTANCE 引用关系构建层级树，双击进入、右键新建/重命名/删除/**打平**（含嵌套实例变换合成，可撤销）
- **KLayout 对齐编辑** — 阵列复制、尺寸调整、布尔运算（并/差/交/异或，经 native clipper）、对齐/分布、**PCell 放置**（动态参数表单）、**顶点编辑**（选中图形出手柄：拖拽改形、边上插点、删除顶点，提交前过零长边/退化/自交检查）
- GL 画布 `components/GlCanvas.ets` — XComponent + OpenGL ES 主路径，连续失败自动降级 ArkUI ShapeNode
- 层级展开服务 `services/HierarchyExpandService.ets` — 展开 + 视口裁剪 + 双级 LOD
- 编辑服务 `services/EditService.ets` — 创建/选中/移动/删除、命中测试（native R-Tree）、**事务化撤销/重做**（一次手势 = 一条记录，连按微调 400ms 合并，无变化不压栈，撤销后清理悬空选中）、Cell 导航
- 高频状态隔离 `common/UiStores.ets` — `@Observed` CursorStore/PanelStore/ToolbarStore/LayerDisplayCache，光标 60fps 更新仅刷新状态栏/HUD，不触发整树重渲染
- DRC（`DrcService`，**native 内核主路径 + 可选实例层级展开** + ArkTS AABB 回退；运行前 `syncDocument` 同步当前编辑态，dirty 本身不再迫使回退；状态栏如实显示「层级 N / 未展开」与未展开规则数，`DRC.TRUNC`/`DRC.NOHIER` 以「结果不完整」告警呈现）、**LVS 预检查**（`VerifyService.runLvsNative` → native `runLvs`；采用绑定工艺的精确通孔用途映射；提取深度跟随画布层级，触顶判为 `truncated` 而非通过）、图像导出（SVG/PNG）、AI 助手（`AiService`）、宏（`MacroService`）、拼音快捷键（`ShortcutService`）、多设备断点（`BreakpointManager`）
- **测量 / 持久标尺**（`MeasureLayer` 叶子组件 + `MeasureStore`）— 实时橡皮筋、第三次点击重开、顶点→边→网格三级吸附、Shift 锁 45°、拖拽定向的常驻 H/V 标尺、µm 单位读数（dx/dy/距离）；状态由页面 `@State` 持有、`@ObjectLink` 透传，端点拖动只重绘覆盖层不重建画布整树

### 草案 / 未接线（`entry/src/main/cpp/experimental/`）

脚本引擎（Ruby/Python 内嵌，defer）、插件系统、retained-mode 渲染器（v2）。这些头文件**未加入构建、未被编译**，接线前需先编译验证并对齐现行数据模型，详见该目录 README（含 v0.4 已接线迁出清单，以及 `plugin_system.h` 与现行模型的 9 处偏离清单）。

## 技术架构

```
┌──────────────────────────────────────────────┐
│            ArkUI 工作台界面层                  │  ArkTS / 声明式 UI
│  WorkbenchTitleBar · WorkbenchSidebar          │
│  LayoutCanvasView · GlCanvas · WorkbenchInspector │
│  StatusBar · UiStores(状态隔离)                 │
├──────────────────────────────────────────────┤
│            NAPI 桥接层（46 函数）              │  napi_init_v2.cpp
│  解析/写出 · 层级展开 · 空间查询 · 几何 · 渲染   │  xcomponent_plugin.cpp
├──────────────────────────────────────────────┤
│      C++ 核心引擎 (参考 KLayout 语义, C++17)   │
│  · scene_graph.h     文档模型 + 层级展开        │
│  · spatial_index.h   R-Tree 空间索引            │
│  · geometry_engine.h 几何运算                   │
│  · triangulator.h    凹多边形三角化             │
│  · clipper_engine.h  Clipper2 布尔与偏移        │
│  · gdsii_reader/writer.cpp  GDSII 读写往返      │
│  · oasis_reader.cpp  OASIS 读写（已接线）        │
│  · gl_renderer.cpp   OpenGL ES 渲染            │
│  · experimental/     未接线草案模块             │
├──────────────────────────────────────────────┤
│         HarmonyOS NEXT Runtime                 │
└──────────────────────────────────────────────┘
```

## 项目结构

```
hongtu/
├── build-profile.json5              # 根构建配置（签名材料不入库，本地自动签名回填）
├── oh-package.json5                 # 包配置（v0.3.0）
├── LICENSE                          # GPLv3 许可证
├── README.md
├── docs/
│   ├── acceptance/                  # M1 层级 / M2 保存往返验收清单
│   └── roadmaps/                    # KLayout 功能差距矩阵 / 原生移植恢复路线图
├── tools/                           # host 冒烟测试（可用 MSVC/g++ 复现）
│   ├── engine_smoke.cpp             # R-Tree/三角化/几何/布尔/场景图（16 项断言）
│   ├── gdsii_smoke.cpp              # GDSII 解析（SREF/AREF/NODE/top-cell）
│   ├── oasis_smoke.cpp              # OASIS SEMI P39（modal/CBLOCK/repetition，24 项断言）
│   ├── oasis_roundtrip_smoke.cpp    # OASIS 写出→读回（含 END CRC32 篡改检测）
│   ├── parser_robustness_smoke.cpp  # 畸形输入/DoS 炸弹不崩溃（14 例）
│   ├── hierarchy_smoke.cpp          # 层级展开
│   ├── roundtrip_smoke.cpp          # parse→write→reparse 往返
│   ├── drc_smoke.cpp                # 原生 DRC 内核（36 项断言，含层级展开/变换坐标/AREF/环剪枝/截断告警）
│   ├── image_export_smoke.cpp       # SVG/PNG（含 PNG 像素 inflate 闭环，15 项）
│   ├── format_readers_smoke.cpp     # CIF/DXF（20 项断言）
│   ├── pcell_smoke.cpp              # PCell 框架（17 项断言）
│   ├── deflate_smoke.cpp            # PNG zlib 编码器闭环（22 项，独立 inflate 解回）
│   ├── spatial_smoke.cpp              # R-Tree/Layout 删除-查询差分
│   ├── property_wire_smoke.cpp        # GDSII 属性字段跨层编码往返
│   ├── lvs_smoke.cpp                # LVS 提取/比对（含 R1–R9 空版图不得静默通过等回归，65 项）
│   ├── coordinate_smoke.cpp         # 坐标口径/PATH 线宽/变换合成/退化几何（49 项断言）
│   ├── run_one_smoke.ps1            # 单套件：只编译跑一个 *_smoke，避免被他人中间态污染
│   ├── run_engine_smoke.ps1         # 引擎冒烟运行器（vswhere→vcvars64→cl）
│   ├── run_native_smoke.ps1         # 引擎+解析器+内核冒烟运行器（可 -OutputRoot 并行）
│   ├── native_build.sh              # OHOS NDK 编译 NAPI 层（多代理可 NATIVE_OUT 并行）
│   ├── check_docs_claims.sh         # README/矩阵数字与状态断言 vs 代码（防文档说谎）
│   ├── check_scripts.ps1            # 工具脚本自身解析检查（缺括号不再等到构建才炸）
│   ├── check_portable.sh            # clang++/libc++ 语法检查（代理 CI 的 g++ 路径）
│   ├── check_all.sh                 # 一键四层门禁：可移植性→冒烟→NDK→ArkTS/HAP
│   └── run_smoke.sh                 # Linux/macOS g++ 冒烟运行器（CI 用）
└── entry/                           # 主模块
    ├── build-profile.json5
    ├── oh-package.json5
    └── src/main/
        ├── module.json5
        ├── cpp/                     # C++ 原生层
        │   ├── CMakeLists.txt       # 编译 6 个 cpp + 链接 NAPI/EGL/GLESv3/XComponent/zlib
│   ├── napi_init_v2.cpp     # NAPI 桥接（46 函数）
        │   ├── scene_graph.h / spatial_index.h / geometry_engine.h
        │   ├── triangulator.h / clipper_engine.h
        │   ├── gdsii_reader.* / gdsii_writer.* / oasis_reader.*
        │   ├── gl_renderer.* / xcomponent_plugin.*
        │   ├── experimental/        # 9 个未接线草案模块（见其 README）
        │   └── types/libhongtu/Index.d.ts
        ├── ets/                     # ArkTS 界面层
        │   ├── common/              # UiStores / Theme / MaterialTokens / types ...
        │   ├── models/GdsiiData.ets
        │   ├── services/            # Edit/Drc/Ai/Macro/Verify/View/FileImport/...
        │   ├── components/          # GlCanvas + workbench/* + dialogs/* + segments/*
        │   ├── entryability/EntryAbility.ets
        │   └── pages/Index.ets      # 画布优先工作台主页
        └── resources/base/
```

## 开发环境

- **IDE**: DevEco Studio（HarmonyOS NEXT）
- **SDK**: targetSdkVersion 6.1.1(24)，compatibleSdkVersion 5.0.0(12)
- **语言**: ArkTS / C++17
- **构建**: CMake + hvigor（hvigorw 由 DevEco Studio 在 Sync 时提供）；`signingConfigs` 留空时产出未签名 HAP（开发者模式模拟器可直接安装）

## 构建与运行

1. 使用 DevEco Studio 打开 `hongtu/` 目录，等待 Sync 完成（自动下载依赖、配置 CMake）
2. 首次构建在 File → Project Structure → Signing Configs 勾选 "Automatically generate signature" 生成本地签名（签名材料不入库）
3. 连接 HarmonyOS NEXT 设备或启动模拟器，点击 Run（或终端 `hvigorw assembleHap`）

### 验证门禁（无需设备即可复现的四层检查）

`tools/check_all.sh` 一键跑完四层，任一层失败即退出——这是本仓库判定"改坏了没有"的唯一口径：

```bash
bash tools/check_all.sh              # 0 跨编译器 → 1 host 冒烟 → 2 NDK 编译 → 3 ArkTS + HAP
bash tools/check_all.sh --skip-hap   # 只跑前三层（不打包 HAP，最快）
```

| 层 | 脚本 | 覆盖 | 为什么需要 |
|----|------|------|------------|
| 跨编译器 | `tools/check_portable.sh` | clang++/libc++ 对全部引擎头 + 冒烟单元 `-fsyntax-only` | CI 用 g++，本机用 MSVC；只过 MSVC 不代表过 g++（传递包含、MSVCism） |
| 文档口径 | `tools/check_docs_claims.sh` | README/差距矩阵里可机械判定的数字与"已接线/无"状态逐条对撞代码；另核对「`Index.d.ts` 声明了的字段 native 是否按名读/写」（声明了却没人读＝幽灵字段）与「每个 `*_smoke` 是否真被两个 runner 接入」（写了从不跑的测试是假安全感） | 曾同时存在 35/24/19 三个矛盾的 NAPI 计数与"OASIS 写：无"（实现早已入库）；`ApplyLayerStyles` 曾只读 color/visible 而从不读 transparency；文档说谎等于伪造完成度 |
| host 冒烟 | `tools/run_native_smoke.ps1` / `tools/run_smoke.sh` | Windows MSVC 与 WSL g++ 真跑二进制；新增保真套件和几何回归的具体批次、数量见本轮验证报告 | 引擎与解析器的行为正确性 |
| native 编译 | `tools/native_build.sh` | NAPI 桥接 + GL/XComponent，链出 `libhongtu.so` | 冒烟测试不含 `napi_init_v2.cpp`，NAPI 层只有 NDK 编译才检查得到 |
| ArkTS/HAP | `hvigor assembleHap` | ArkTS 严格编译 + 打包 | `@ObjectLink`/`@State` 一类的装饰器规则只有编译器能判 |

单个代理并行自检时用隔离目录，避免互相踩踏：
`NATIVE_OUT=/tmp/nb_x bash tools/native_build.sh`、`run_native_smoke.ps1 -OutputRoot 'C:\temp\ht-smoke-x'`。

2026-09-23 统一门禁产出的 unsigned HAP 为 `entry/build/default/outputs/default/entry-default-unsigned.hap`（15,964,577 字节，SHA-256 `11AB12FBEBF148F286A1899763E2F5B7E189B22CA71FF2A83D2194AB6B65734E`）；包含 arm64-v8a 与 x86_64 库，本轮设备实测仅覆盖 API24 x86_64 模拟器。

## 关键技术决策

| 决策点 | 方案 | 理由 |
|--------|------|------|
| 核心引擎语言 | C++17（部分 header-only 引擎模块） | 当前为自研实现；header-only 模块便于冒烟测试直接 include |
| UI 框架 | ArkUI 声明式 | HarmonyOS NEXT 原生框架 |
| 桥接层 | NAPI（统一异常守卫） | 官方 C++ 互操作；异常不穿越边界 |
| 渲染方案 | OpenGL ES 主路径 + ArkUI 降级 | GPU 批量绘制大版图；失败自动降级保证可见 |
| 高频状态 | `@Observed` Store 隔离 | 光标/缩放等 60fps 更新不触发整树重渲染 |
| 许可证 | GPLv3 或更新版本 | 本项目贡献者的许可证选择；KLayout C++ 源码尚未接入本仓库 |

## 已知局限

- 布尔/offset 已接入 Clipper2；公开 SKY130 met1 三条规则使用同层合并区域，其余 DRC 规则仍为逐图形预检查。层级/形状/边数达到限制时必须读取完整性告警；没有 foundry 规则签核或百万图元性能保证。
- LVS 为**连通性级预检查**：网络命名依赖版图 TEXT 标签，无标签几何只成匿名网，与参考网表比对时按"多余网络"计——**不可作签核**，也不能替代真正的器件级 LVS
- **设备验证范围**：2026-09-30 的 MateBook 2in1 x86_64 模拟器已完成真实 AI Python 生成 12×12 阵列、载入、平移编辑、GDS 保存及 picker 重开；独立 KLayout 确认 AREF 保留且与预期移动结果 XOR 为零。公开 SKY130 inverter、met1 三条规则、22 对 layer/datatype 的标准 LYP 互通，以及带孔区域相减和 −100 nm 缩边后的保存重开也已实测；两份环形 GDS 与独立预期 XOR 均为零。arm64 真机、GPU 真机帧率、工业规模长时间运行和完整设备签核尚未完成。
- GDSII 大多边形采用 KLayout 支持的[非标准多 XY 扩展](https://www.klayout.de/forum/discussion/54/max-vertices)以避免保存时静默丢图元；其他 GDS 工具的兼容性尚未签核
- GDSII PATH4 的 BGNEXTN/ENDEXTN 已贯通存储和保存；曲线/圆帽仍以有限边数近似绘制，几何容差需按工艺确认。
- OASIS 读已校验 END CRC32（写出亦生成），但**逐记录 CBLOCK 校验和仍不校验**
- CIF/DXF 图层名按出现顺序映射编号；DXF 仅 R12 ASCII 子集（BULGE 弓形段已按圆弧采样并做共圆/弧顶断言，LWPOLYLINE 与 POLYLINE+VERTEX 共用同一条展开路径）
- PNG 的 IDAT 用自带 DEFLATE（固定哈夫曼 + 贪心 LZ77，收益不足时自动退回 stored 块）；圆类几何以 32 边形近似
- 真实 Python API 通过电脑伴随服务提供；AI 接口限制可用语法/API/资源，可信本地 CLI 支持完整 KLayout 数据库 API。HarmonyOS 内嵌 Ruby/Python 和 PCell 注册未实现，`experimental/` 的旧脚本草案未使用。
- 复杂层级已有原生直接提交渲染路径，避免展开坐标往返跨 NAPI。64×24 SRAM 全层级 504,628 个非文字几何显示与编辑保存已有有界设备证据；约 190 万展开几何的样本按预算明确拒绝，不能据此声称百万图元流畅交互。详情见 [复杂版图报告](docs/validation/complex-layout-20260930.md)。

## 许可证

本项目采用 [GPLv3 或更新版本](./LICENSE) 许可证。

鸿图参考 [KLayout](https://github.com/KLayout/klayout) 的版图模型和交互语义。设备端未嵌入其 C++ 库；电脑伴随服务依赖官方 `klayout.db` Python 包。KLayout 的[官方许可说明](https://www.klayout.de/license.html)为 GPLv2 或更新版本；vendored Clipper2 使用 Boost Software License 1.0，见 `entry/src/main/cpp/vendor/clipper2/LICENSE`。孔洞分解使用 Mapbox earcut v2.2.4（ISC），固定版本与哈希见 `entry/src/main/cpp/vendor/earcut/UPSTREAM.md`，许可见同目录 `LICENSE`。

## 致谢

- [KLayout](https://github.com/KLayout/klayout) — Matthias Koefferlein 开发的开源版图查看与编辑工具
- [HarmonyOS NEXT](https://www.harmonyos.com/) — 华为鸿蒙操作系统
