# 鸿图原生移植版可用性恢复路线

> 状态：执行中  
> 日期：2026-07-11（文档增补 2026-07-21）  
> 范围：仅 `hongtu` HarmonyOS 原生工程，不包含 `hongtu-web`  
> 相关文档：[KLayout 能力差距矩阵](./klayout-feature-gap-matrix.md) · [M1 层级验收清单](../acceptance/m1-hierarchy-checklist.md)

## 1. 结论

当前工程可以构建和启动，但核心工作流仍属于交互原型：

- 仓库没有接入 KLayout `db/tl` 核心源码或库，当前 C++ 层是自研的简化解析、NAPI 和 OpenGL 桥接。
- 主画布默认使用每图形一个 ArkUI 组件的方式渲染，无法承载真实版图的数据规模。
- Cell 层级、实例变换、Top Cell 选择、查看模式和保存往返尚未形成一致的数据模型。
- OASIS、DRC、网络分析只适合演示，不具备工程结果可信度。
- 缺少真实版图测试语料、自动化往返测试、性能基准和正式签名发布链路。

恢复策略不是继续增加外围功能，而是先建立一条可验证的纵向主链：

`真实文件 -> 正确层级 -> 可交互显示 -> 受控编辑 -> 无损保存 -> 重开比对`

## 2. 产品边界

### 2.1 第一目标

第一目标是可用的 **GDSII 查看器**，不是一次完成完整 KLayout 替代品。

MVP-0 只承诺：

- 打开真实 GDSII 文件。
- 正确识别 Top Cell 和 Cell 引用关系。
- 正确显示当前 Cell 的本地几何和实例入口。
- 支持图层显隐、适配、缩放、平移和 Cell 导航。
- 大文件解析期间 UI 不假死，并可取消。
- 失败时给出明确错误，不显示伪成功结果。

### 2.2 暂停范围

以下能力在 MVP-0 完成前冻结：

- AI 指令扩展。
- 宏系统扩展。
- 新增 DRC 规则和 LVS。
- 新增视觉材质、动画和非必要响应式布局调整。
- OASIS 功能宣传和兼容性扩展。

现有代码可以保留，但不再占用恢复主链的开发优先级。

## 3. 七个工作流

### 3.1 文件解析与核心数据模型（P0）

目标：由一个原生文档对象持有库、Cell、Shape、Instance、Layer 和单位信息。

必须完成：

- 评估并接入 KLayout `db/tl` 核心，或选定成熟的 GDS/OASIS C++ 库。
- 在接入成熟库前，把现有自研 reader 明确标记为兼容性过渡层。
- 校验记录长度、数据类型、文件尾、坐标范围和损坏文件。
- 建立 Cell ID、Cell 名称、引用关系、Top Cell 候选和循环引用检测。
- 保留未识别属性，避免读取后静默丢失。

验收：至少 20 个来源不同的真实 GDSII 文件可稳定读取，概要信息与参考工具一致。

### 3.2 Cell 层级与坐标系统（P0）

目标：所有显示、选择、编辑和导出使用同一套层级与变换语义。

必须完成：

- Top Cell 由“未被其他 Cell 引用”的候选集合推导，不再固定为 Cell 0。
- Shape 永远属于明确的 owner Cell。
- SREF/AREF 支持平移、旋转、镜像、缩放和数组步进。
- 当前 Cell 之外的本地图形不得直接叠加到画布。
- 统一 GDS 坐标、屏幕坐标、Y 轴方向、数据库单位和显示单位。
- 层级展开与“进入 Cell 编辑”分离，避免修改错误的 Cell。

验收：多层实例样例在 Top、子 Cell 和返回 Top 三种状态下显示与参考工具一致。

### 3.3 渲染与性能（P0）

目标：真实版图以 GPU retained scene 渲染，ArkUI 只承载工具和浮层。

必须完成：

- OpenGL/XComponent 成为主渲染路径，不再为每个版图图形创建 ArkUI 节点。
- 按图层、图元类型和瓦片构建批次。
- 增加视口裁剪、空间索引、LOD 和增量 GPU 上传。
- 多边形使用可靠三角剖分，凹多边形不得使用单一 triangle fan。
- PATH 使用真实宽度；文本和实例边界按缩放等级显示。
- 解析、场景构建和 GPU 上传不阻塞 UI 线程。

初始性能线：

- 100 万基础图元可完成打开并显示。
- 稳态平移/缩放目标 50 FPS 以上。
- 单次 UI 线程阻塞不超过 100 ms。
- 内存峰值和文件大小、图元数建立可重复基准。

### 3.4 编辑内核（P1）

目标：编辑操作只作用于当前 Cell，并可可靠撤销、重做和保存。

必须完成：

- 当前 Cell 范围内的选择、框选、命中、移动、创建和删除。
- 基于空间索引的命中测试，不再全数组线性扫描。
- 网格、顶点、边和中心吸附使用统一坐标容差。
- 操作以事务记录，批量操作一次撤销。
- 文档 dirty 状态、未保存退出提示和崩溃恢复。
- 查看模式使用只读文档视图，不复制完整可编辑对象。

### 3.5 文件保存与往返（P1）

目标：任何声称“保存成功”的文件都能被参考工具重新打开并保持几何语义。

必须完成：

- 保存时按 owner Cell 写回结构，不把全部图形写入 Top Cell。
- 保留库单位、datatype、PATH/TEXT 属性、实例变换和数组。
- 临时文件写入成功后再原子替换目标文件。
- 保存后立即用独立 reader 重开并执行结构摘要比对。
- 建立 `input -> open -> save -> reopen -> compare` 黄金测试。

### 3.6 DRC 与分析（P2）

目标：分析结果有明确适用范围和可复现性。

必须完成：

- DRC 转入原生几何内核，使用布尔运算和空间索引。
- 规则集带工艺来源、版本和单位。
- 结果与 KLayout/参考 deck 建立黄金对比。
- 在完成精确几何前，现有包围盒 DRC 标记为“快速预检查”，不得作为签核结果。

### 3.7 测试、发布与 HarmonyOS 体验（贯穿）

必须完成：

- 原生 reader 单元测试、损坏文件测试和 fuzz 入口。
- ArkTS 服务测试、端到端打开/导航/保存测试。
- 真实设备和模拟器截图、手势与窗口尺寸回归。
- debug/release 签名、安装、升级、权限和崩溃日志链路。
- README 的能力描述必须由自动化验收结果支撑。

## 4. 目标架构

```text
ArkUI Workbench
  |-- commands / selection / panels
  |-- read-only view state
  v
NAPI asynchronous facade
  |-- open / cancel / query scene
  |-- edit transaction / save
  v
Native document core
  |-- LayoutDocument / Cell graph / Shape store
  |-- spatial index / hierarchy transforms
  |-- reader / writer / validation
  v
GPU scene renderer
  |-- culling / LOD / layer batches
  |-- incremental upload / picking IDs
```

关键边界：ArkTS 不持有百万级 Shape 对象副本；大数据、层级遍历、空间查询和渲染批次留在 C++。

## 5. 里程碑

### M0：基线与防误判

- 建立恢复路线文档和验收表。
- 建立可重复运行的 native smoke 命令。
- 收集首批真实 GDSII fixture 和参考摘要。
- 修复 Top Cell 固定为 0、跨 Cell 图形叠加和跨 Cell 命中。
- OASIS 明确显示“实验性/不支持”的失败状态。

退出条件：多 Cell GDS 可以按 Cell 浏览，不再把所有本地图形叠在一起。

### M1：可用 GDS 查看器

- 异步打开、取消和错误反馈。
- 原生场景树和层级变换。
- **KLayout 语义：`hierarchyDepth = N` 时递归展开子 Cell 几何并施加 SREF/AREF 变换后绘制**（不得仅显示 INSTANCE 占位框）。验收见 [m1-hierarchy-checklist](../acceptance/m1-hierarchy-checklist.md)。
- GPU 主渲染、裁剪、LOD 和性能面板。
- 图层管理、Top Cell 选择、Cell 导航。

退出条件：真实中型 GDS 连续操作 30 分钟无崩溃、无明显错图；同文件 depth=1/2/3 与 KLayout 轮廓对齐（允许颜色/线型差异）。

### M2：基础编辑与保存

- 当前 Cell 编辑、事务撤销重做、dirty 状态。
- GDS 结构化导出和往返测试。
- 自动恢复和保存失败保护。

退出条件：支持的图元子集可稳定往返，差异报告为零。

### M3：OASIS 与验证

- 成熟 OASIS reader/writer、CBLOCK 和 modal state。
- 原生 DRC 内核和参考结果比对。
- 性能、签名、发布和用户文档收口。

## 6. 当前迭代

本轮已完成 M0 的第一个纵向切片：

- [x] 从实例引用关系推导 Top Cell 候选。
- [x] 选择确定的 Top Cell 作为初始浏览上下文。
- [x] 画布只显示、命中、选择、DRC 和网络追踪当前 Cell 所拥有的 Shape。
- [x] 新建和粘贴图形自动归属当前 Cell。
- [x] 用双 Cell + SREF 的 native smoke 用例验证归属和 Top Cell 推导。
- [x] 修复系统文件选择器 URI 复制，文档 URI 先打开为只读 FD 再复制到沙箱。
- [x] 双击实例进入子 Cell，面包屑可返回并自动重新适配当前 Cell。
- [x] 完成 ArkTS 检查、正式 SDK HAP 构建、安装和模拟器端到端验证。

本轮验证结果：

- `tools/run_native_smoke.ps1`：GDSII 与 OASIS smoke 全部通过。
- 正式 DevEco SDK `hvigorw assembleHap`：构建成功。
- `MateBook Pro` 模拟器：`gdsii_smoke.gds` 可从系统选择器导入；TOP 仅显示 CHILD 实例入口；双击后仅显示 CHILD 的 L7 矩形；点击 Top 返回后重新居中显示实例。

### 2026-07-21：M1 层级几何展开（实现切片）

- [x] ArkTS `HierarchyExpandService`：hierarchyDepth 下 mag→mirror→rot→trans 展开子几何。
- [x] `LayoutCanvasView.displayShapesForRender()`：depth≥2 绘制展开几何 + INSTANCE 入口。
- [x] `fitAllShapes` 按展开后可见几何适配。
- [x] `scene_graph.h`：`toMatrix` 顺序与 `flattenHierarchy` 深度语义对齐 KLayout。
- [x] NAPI v2 补回同步 `parseGdsii/quickInfo/parseOasis/quickOasisInfo`；新增 `expandHierarchy`；Layout 填充使用 `ownerCellId`。
- [x] `tools/hierarchy_smoke.cpp` 接入 `run_native_smoke.ps1`。
- [ ] 设备端 depth=1/2/3 与 KLayout 轮廓对照（见验收清单）。
- [x] Phase C：展开几何 → `setRenderData` GPU 主路径；GL 失败回退 ShapeNode；相机与 ShapeNode 对齐（Y 翻转）。
- [x] 视口裁剪：`cullShapesToViewport` / `expandAndCullCellShapes`；native `expandHierarchyToBatches` 可选 bbox 裁剪。
- [x] Native 直出 batch：`expandHierarchyToBatches` + GlCanvas 优先路径（失败回退 ArkTS 展开）。

### 2026-07-26：v0.4 能力扩展（M3 主体落地）

全部条目有 host 冒烟断言支撑（`tools/run_native_smoke.ps1` 8 套全绿）；
HAP 构建全绿（signingConfigs 留空产出未签名包）；模拟器（MateBook Pro）安装启动
并验证 Cell 树/新建 Cell/dirty 标记端到端。

- [x] **OASIS 读取器重写为 SEMI P39 完整实现**：modal 状态机全集、名称表前向引用、
      6 种点列表、12 种 repetition、CTRAPEZOID 26 种、PLACEMENT 17/18、
      CBLOCK DEFLATE（内置 RFC1951 解码器 `inflate_tiny.h`）、DoS 上限；
      oasis_smoke 24 项 + 健壮性 14 例。
- [x] **原生 DRC 内核接线**（experimental → 主目录）：R-Tree 按层索引 + 真实边到边
      距离；RECT 归一化/PATH 轮廓化；NAPI runDrc(ownerCellId)；DrcService native
      主路径 + dirty 回退；定位快速预检查。drc_smoke 11 项。
- [x] **图像导出接线**：SVG（按层分组）+ PNG（软件光栅 + 自包含编码 `png_writer.h`）；
      NAPI exportSvg/exportPng + 图层样式；UI picker 导出。image_export_smoke 15 项
      （含 inflate 像素闭环）。
- [x] **CIF/DXF 读取器**（草案模型脱节，按现行模型重写）：CIF 全命令 + C 调用变换
      分解；DXF R12 子集；NAPI parseCif/parseDxf + 扩展名分发。format_readers_smoke 20 项。
- [x] **PCell 框架接线** + Basic 库（CIRCLE/DONUT/ARC）：NAPI listPCells/generatePCell
      （临时 Layout 生成，ArkTS 文档接管）；动态参数表单弹窗；插入 = 变体 Cell +
      实例（单批撤销）。pcell_smoke 17 项。
- [x] **工作台补全**：Cell 树（引用关系构建/右键管理/新建/重命名/删除防护/打平含
      嵌套实例变换合成）、阵列复制、尺寸调整、布尔运算菜单（native clipper）、
      修饰键全局状态、绘图工具栏。
- [x] 构建收口：signingConfigs 留空 → 未签名 HAP 全绿构建；开发者模式模拟器可安装。
- [x] 版本 0.4.0（oh-package ×2 + AppScope）。
- 明确 defer：LVS 接线、脚本引擎（Ruby/Python 内嵌）、retained 渲染器 v2、LEF/DEF、
  OASIS 写出、CRC 校验。

### 2026-07-21：M2 结构化保存切片（Phase D 起步）

- [x] `LayoutExportService.buildStructuredByOwner`：按 `ownerCellId` 分组写出 BGNSTR；Top 不再吞全库图形。
- [x] 导入 `applyParsedResult` → `advEditService.loadCellsFromImport` 同步 Cell 表。
- [x] 导出传 `cellNames` / `topCellId` / `userUnits` / `physicalUnits`。
- [x] Dirty：`EditService.isDirty` + 状态栏「● 未保存」+ 标题文件名 `*`；保存成功 `markClean`。
- [x] 验收清单：[m2-save-roundtrip-checklist.md](../acceptance/m2-save-roundtrip-checklist.md)。
- [x] C++ `gdsii_writer`：按 ownerCell 结构化写出 BOUNDARY/PATH/TEXT/SREF + UNITS。
- [x] Host `tools/roundtrip_smoke.cpp` 接入 `run_native_smoke.ps1`（parse→write→reparse）。
- [x] NAPI `writeGdsii` + `NativeHongTuService`；保存未 dirty 时优先 native，失败回退 ArkTS。
- [x] 简单 LOD：`applyLodToShapes` + GlCanvas 远景 batch 简化 / 低缩放跳过 native 全精度。
- [x] P0 审查修复：`writeRecord` 失败上抛；INSTANCE 仅入 `instances`；dirty 用 editDepth 与 undo 对齐。
- [x] `writeGdsiiDocument`：编辑后 shapes 经 NAPI 写出并刷新 `g_layout`。
- [x] 未保存确认：打开 / 最近文件 / 返回键（AlertDialog）。
- [x] 导出 `copyFileToUri` 1MiB 分块 / copyFile，降低大 GDS 内存峰值。
- [x] `writeGdsiiDocument` 仅 Write 成功后 commit `g_layout`（避免写失败污染快照）。
- [x] `editDepth` 与 undo 栈丢弃对齐；未保存两轮确认含「保存并继续」。
- [x] 保存 skippedShapes 强提示。
- [x] ArkTS 回退写出分块 writeSync（1MiB）。
- [ ] 设备端 open→save→reopen + KLayout 对照签核。
- [ ] Ability 进程被杀无法拦截（系统限制）。

## 7. KLayout 语义对齐（2026-07-21）

完整能力对照与 defer 列表见 [klayout-feature-gap-matrix.md](./klayout-feature-gap-matrix.md)。

与官方 [KLayout Basics](https://www.klayout.de/doc-qt5/manual/basic.html) 对照后的主链结论：

| 优先级 | 缺口 | 对应 Phase / 里程碑 |
|--------|------|---------------------|
| **P0 #1** | hierarchy depth **不展开子几何**，仅 INSTANCE 框 | Phase B → **M1 必达** |
| P0 | GPU retained scene 未成主路径；每图元 ArkUI 节点 | Phase C → M1 |
| P1 | GDS 结构化保存 + open→save→reopen 黄金测试 | Phase D → M2 |
| P2+ | OASIS 宣传、可信 DRC、LVS、.lyp、PCell、Ruby/Python | Phase E → M3+ |

**完善顺序（禁止用外围功能冒充完善）：**

```text
真实 GDS → 正确层级模型 → depth 下变换展开显示 → GPU 可交互
  → 当前 Cell 受控编辑 → 无损保存 → 重开比对
```

M0 已完成「按 Cell 浏览、不叠错图」。  
**2026-07-21 已落地 Phase B + C + 视口裁剪/native batch：**  
`expand → (viewport cull) → setRenderData`，native `expandHierarchyToBatches` 优先，ArkTS 路径回退。  
**同日 M2 起步：** 按 ownerCell 结构化导出 + dirty + 导入同步 Cell 表；设备往返签核仍待做。  
下一步：设备端 M1/M2 签核、LOD、C++ writer 与黄金往返 smoke。  
实现：`HierarchyExpandService`、`GlCanvas`、`LayoutExportService.buildStructuredByOwner`、`EditService.isDirty`。

## 8. 决策记录

- 2026-07-11：Web 原型退出范围，只维护 HarmonyOS 原生工程。
- 2026-07-11：MVP-0 定义为 GDSII 查看器，OASIS、DRC、AI 和宏后置。
- 2026-07-11：现有 UI 外壳、文件选择器、NAPI/XComponent 框架可保留；核心文档、层级、渲染、保存和 DRC 按新架构逐步替换。
- 2026-07-11：任何“已支持”声明必须有真实 fixture、参考摘要和自动化验证支撑。
- 2026-07-21：对照 KLayout 官方文档固化差距矩阵与 M1 层级验收清单；确认 hierarchy expansion 为 M1 必达语义，MVP 前继续冻结 AI/宏/新 DRC/OASIS 宣传。
