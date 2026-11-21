# 鸿图 vs KLayout：能力差距矩阵

2026-10-01 新一批补齐和四款同类工具对照已单独整理：以[当前结构树](../software-structure-tree.md)、[31 组差距进度](../validation/feature-closure-20261001/gap-progress.md)和[首批验证](../validation/feature-closure-20261001/report.md)查看最新增量；下文保留原矩阵及历史证据。

> 状态：对照文档（随实现更新）  
> 日期：2026-09-30（工作区、PCell、比较、工艺与自动化之后继续逐动作复查；最终开发 HAP 已安装，历史设备证据分批保留）
> 关联：[native-port-recovery-roadmap](./2026-07-11-native-port-recovery-roadmap.md) · [M1 层级验收清单](../acceptance/m1-hierarchy-checklist.md) · [M2 保存往返清单](../acceptance/m2-save-roundtrip-checklist.md)  
> 官方参考：[KLayout Documentation](https://www.klayout.de/doc.html) · [User Manual Basics](https://www.klayout.de/doc-qt5/manual/basic.html)

最新 [手工复画工作流验收](../validation/manual-redraw-workflow-20260930.md) 已完成官方 INVERTER 的30步真实UI复画、37个BOX/TEXT图形与11对layer/datatype；GDS/OASIS保存重开严格比较、Recent覆盖保存读回、Cell菜单/名称及侧栏/面包屑刷新通过。最终26套宿主574项、Python23、20套原生与格式保真、NDK及Release HAP通过，交互目标为API24 x86_64 2in1；不包含源文件不存在的PATH/层级实例，也不等于完整PDK或真机签核。

先前 [完整操作流程复查](../validation/workflow-completion-20260930.md) 的24套宿主506项及其逐动作矩阵作为历史批次保留，不与最新计数混用。

## 1. 定位

| | KLayout | 鸿图 |
|--|---------|------|
| 平台 | 桌面（Qt） | HarmonyOS NEXT 原生 |
| 核心 | 成熟 Layout Viewer And Editor | 自研 C++ 解析 + NAPI + ArkTS 工作台 |
| 近期目标 | 全功能 EDA 工具链 | GDSII/OASIS 查看与受控编辑、真实 Python 伴随服务、公开工艺子集验证；尚未达到完整工业签核能力 |

**层级展开与剩余验收范围：**

KLayout 的 hierarchy depth 会把子 Cell 几何按 SREF/AREF 变换**展开绘制**；鸿图已落地 ArkTS/native 展开 + GPU 批次。2026-09-30 的 API24 x86_64 2in1 模拟器已完成真实 AI 生成 12×12 AREF、载入、X 方向移动 120 nm、保存和 picker 重开；独立 KLayout 读回的几何 XOR 为 0。此为指定样本和操作的验收，全部深度/变换组合、API26/arm64 真机、大版图性能及完整格式签核仍未完成。见 [本轮设备与独立对照报告](../validation/industrial-foundation-20260930.md)。

其后 [复杂版图专项](../validation/complex-layout-20260930.md) 已覆盖 64×24 SRAM 的完整层级 504,628 个非文字几何显示、编辑保存与独立读回；约 190 万展开几何的另一宏明确拒绝，保留资源预算。下表新增工作区、比较与工艺等功能的设备验收与这些历史样本分开记录，见 [功能补全报告](../validation/feature-completion-20260930.md)。

图例：`●` 可用/可信 · `◐` 部分/演示 · `○` 缺失或仅头文件 · `P0–P3` 相对 MVP 主链优先级

---

## 2. 文件与格式

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| GDSII 读 | 成熟全要素 | 自研 reader：BOUNDARY/BOX/PATH/TEXT/SREF/AREF/NODE；NODE 作为非绘制元素保留 NODETYPE、XY 坐标序列和属性，缺 XY 时拒绝可编辑导入；Top Cell 推导；smoke 通过 | P0 |
| GDSII 写 / 往返 | 结构化写出 | C++ writer + NAPI writeGdsii/Document + ArkTS 回退；合法NODE/属性贯通。工作区保存从固定当前文档快照写出；服务保留显式确认源一致时的原文件复制能力。历史API24 AREF位移及带孔布尔/侵蚀保存重开XOR为0；新工作区保存另作设备验收，完整格式/设备范围仍待做 | ◐ P1 |
| OASIS 读 | 工业级 | 已接入 modal/名称表前向引用/6 种点列表/12 种 repetition/CTRAPEZOID 26 种/PLACEMENT 17+18/CBLOCK DEFLATE/DoS 防护；标准 END 检查和独立读回案例通过；未完成整个 SEMI P39 的一致性认证，限制见本轮保真报告 | ◐ 已有专项验证 |
| OASIS 写 | 工业级 | **● 已接线**（`oasis_writer`，END 256B + CRC32 生成；写→读回往返 smoke） | 已达（子集） |
| DXF / CIF | 支持 | **● 已接线**（CIF 全命令+变换分解；DXF R12 子集，LWPOLYLINE 与 POLYLINE+VERTEX 的 BULGE 弓形均按圆弧采样，以「内点共圆 + 半圆顶高度 + 符号分侧 + 退化不崩」断言锁定）；`format_readers_smoke` 32 项断言 | 已达（子集） |
| LEF-DEF | 支持 | 无（defer，与查看器主链无关） | P3 |
| 损坏校验 / 取消加载 | 强 | 健壮性 smoke 14 例（截断/噪声/repetition 炸弹/解压炸弹优雅失败）；取消加载骨架 | ◐ P1 |
| PROPATTR/PROPVALUE | 保留 | **● 已保真（规范码核对后）**（GDSII PROPATTR 43/0x2B + PROPVALUE 44/0x2C + OASIS record 28 读→模型→写→重读等值；此处曾两连击：初版用 BOXTYPE/BOX 占掉属性码，「纠正」时又整体右移两格，reader/writer/fixture 同源自洽令 42 项断言全绿而真实文件照旧丢属性——现按规范表取值且 fixture 写真实码，见下方两行）；ArkTS 编辑保存桥接已接通，API24 专项确认 NODE 的 attr50 在连续保存后保留，其他属性类别的设备专项仍待覆盖 | 已达（native/ArkTS）/◐（设备范围） |
| PATH 端型（PATHTYPE） | 完整支持 | PATHTYPE(33/0x21) 与 BGNEXTN(48/0x30)/ENDEXTN(49/0x31) 为独立记录。2026-09-30 已用 `pathBeginExtension/pathEndExtension` 保留 type 4 的有符号每端长度，`pathWidthAbsolute` 保留负 WIDTH；native/NAPI/ArkTS、克隆/撤销和两条 GDS 写出路径均贯通，写出顺序已修为 PATHTYPE 在 WIDTH 前。官方 KLayout 生成→鸿图编辑→KLayout 重读专项验证通过，详见 [格式保真报告](../validation/format-fidelity-20260930.md)。此前“无字段、按半宽近似”描述已失效；round 轮廓仍为离散近似，全部 PATH 设备交互组合尚未验收 | ● GDS 专项 / ◐ 显示与设备范围 |
| 大多边形写出 | 支持多 XY 扩展 | **◐ 修复真实丢图元**：单条 XY 记录长度字段只有 2 字节（≤8191 点对），旧 writer 一次性写一条并 `>8190 即 return false` ⇒ **保存时静默丢弃**顶点更多的图元；现兼容 KLayout 的[**非标准多 XY 扩展**](https://www.klayout.de/forum/discussion/54/max-vertices)，分片写出并跨记录累加读取。该扩展可能与其他 GDS 工具不兼容，跨工具往返尚未签核；4M 点上限作为 DoS 兜底 | ◐ 兼容性待验 |
| GDSII 记录码正确性 | — | **● 双源核对纠正两轮错误**：真实码为 NODE 21/0x15、PATHTYPE 33/0x21、PROPATTR 43/0x2B、PROPVALUE 44/0x2C、BOX 45/0x2D、BOXTYPE 46/0x2E、PLEX 47/0x2F。初版把 BOXTYPE/BOX 记成 0x2D/0x2E 占掉属性码；上一轮「纠正」又整体右移两格，于是 reader/writer/**冒烟 fixture** 三者继续自洽、断言全绿，而真实 GDS 的属性对（0x2B/0x2C）照旧被丢、真 BOX 元素被当属性对。现全部按规范表取值，fixture 改写真实码；本轮另以合法 NODE 样本验证 XY、NODETYPE 和元素属性，避免只核对记录号 | 已达（教训见 §10） |

## 3. 层级与坐标（MVP 核心）

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| Top Cell 选择 | 候选 + 用户选 | `topCellIds` / `primaryTopCellId` | ● 基础已有 |
| 进入子 Cell / 面包屑 | Descend with context | 双击 INSTANCE + 面包屑 | ● 已有 |
| **Hierarchy depth 展开几何** | 按深度递归变换绘制 | ArkTS/native 展开与原生直接渲染提交；API24 的 AREF 和 64×24 SRAM 全层级 504,628 几何显示/编辑保存已有证据，全部变换组合和更大预算仍待覆盖 | ◐ 有设备专项 |
| SREF 变换（xy/rot/mirror/mag） | 完整 | 展开路径 mag→mirror→rot→trans | ◐ |
| AREF 阵列 | 原生阵列语义 | 压缩阵列贯通 reader/NAPI/ArkTS/native writer/回退 writer；按列数/行数恢复间距，保存保留 AREF；含倾斜向量和嵌套变换的独立 KLayout 对照通过。API24 2in1 的 AI 12×12 阵列移动 `(120,0)` nm 后保存重开，结构保留且 XOR=0 | ● GDS 与指定设备流程已验证 |
| **统一 DBU/屏幕/Y 轴** | 严格 | 世界坐标一律 nm（读取器单次归一 `dbu×physical×1e9`）；X 向右、Y 向上，与 GDS/KLayout 一致；GL、ArkUI 与 SVG/PNG 显示方向统一。`tools/coordinate_smoke.cpp` 55 断言及 `tools/y_up_canvas_host_check.mjs` 17 检查覆盖相机/逆变换/覆盖层/抬起与取消/非对称图像。历史 API24 的 X+120 nm 保存重开已验；本次 Y 轴修复的完整设备验收另见 2026-09-30 复杂版图报告 | ● 契约 / ◐ 设备覆盖 |
| 隐藏 Cell / 库视图 | 有 | 无/弱 | P2 |

## 4. 渲染与性能

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| GPU retained scene | 是 | GlCanvas 主路径 + ShapeNode 叠加/回退 | ◐ M1 |
| 视口裁剪 / LOD / 空间索引 | 是 | 视口裁剪 + native batch；简单 LOD 已做；**R-Tree 点/范围查询已与暴力枚举做随机差分测试（一致）；kNN 已修正**——旧实现按「攒够 k*2 候选」提前终止、无剪枝判据，随机版图上与暴力不符率约 47%（表现为磁吸吸到远处图形）。另修 `Layout::removeShape` 每次删除都整体重建索引（批量删除退化 O(N²)），改为标脏 + 查询前惰性重建一次；`tools/spatial_smoke.cpp` 已接入 Windows/Linux 两个 runner，本轮 host 日志通过 | ◐ P0–P1 |
| PATH 真实线宽 / 凹多边形三角化 | 是 | **● 已落地**：`Triangulator::pathOutline` 按 `pathWidth`+`pathType`（flush/round/extended）出轮廓，DRC 间距实测、SVG/PNG 导出、GL 条带共用同一函数；round 端头自交已修（简单多边形断言） | 已达 |
| 大版图与百万图元交互 | 是 | 64×24 SRAM 全层级 504,628 个非文字几何已有设备显示及编辑保存证据；约 190 万展开几何明确拒绝，未声称百万级流畅交互。参见复杂版图报告 | ◐ 有界验证 / P1 |

## 5. 图层与视图（Basics）

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| 图层显隐 / 颜色 | 完整 | layer/datatype 双键贯通计数、颜色、显隐与锁定。API24 打开 SKY130 inverter（54 图形/22 对），67/44 与 67/20 各 6 图形，显隐及锁定独立；标准 LYP 显示名和颜色实测 | ● 指定样本已验 |
| 线型 / 填充 / 动画层 / .lyp | 有 | 标准 KLayout LYP 导入/导出，兼容旧鸿图格式读取。Host 29 对与设备导出 22 对的层号、datatype、名称、两种颜色、线宽、可见性均经真实 KLayout reader 核对；未匹配图层保留。组拍平、百分比透明度转布尔、自定义线/填充默认化、锁定/VAS/动画未完整映射均提示。应用样式到 ArkUI/GL/SVG/PNG 的共用路径已有 smoke，PNG 不表达 dash，GL 不支持效果会回退；完整样式/动画设备组合未验 | ◐ 已有互通与设备专项 |
| 层级深度 UI | 配置 | 可选展开深度与完整层级；64×24 SRAM 全层级显示已验；循环/展开预算显式限制，全部切换和变换组合仍待验收 | ◐ |
| 缩放/平移/Fit / 框选放大 | 有 | 原交互 + 专用框选放大；上下文菜单和KF可达，拖框缩放/居中并回Select，不改几何。旧自定义快捷键保留；设备100%→205.7759%，显示205.8%避免换行 | ● 指定流程 |
| 多文档 Session / 工作区 | 有 | 新建文档、多标签、独立编辑/撤销会话、工程文件、自动草稿恢复和版本副本已接线；本批最终 HAP 已安装，API24 2in1 重启恢复 5 标签草稿，版本恢复打开副本；实际 Index 方法 14 项通过，完整平台范围尚未验收 | ● 指定流程 / ◐ 平台范围 |
| 全局旋转/翻转、视图书签 | 有 | 尚无完整交互 | P2–P3 |
| **测量 / 标尺** | 成熟 | **● 已落地**：实时橡皮筋 + 第三次点击重开、顶点→边→网格三级吸附、Shift 锁 45°、拖拽定向的常驻 H/V 标尺、µm 读数（dx/dy/距离）经 `constants.umText()` 唯一出口；`AdvancedEditService` 的重复标尺死 API 已删除（消除两套真相） | 已达（手感需设备复核） |
| 导航器缩略图 | 有 | `ViewService` 有数据 | P1 |

## 6. 选择与编辑

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| 点选 / 框选（当前 Cell） | 有 | GL-only统一命中；实例点选真实可见子几何，空洞/阵列缝隙不误选，返回根实例可双击进入；旋转/镜像/MAG/AREF有界查询。框选实例使用真实可见范围，右→左按bbox相交；循环/预算失败不给假命中 | ● 回归与指定设备 / ◐ 完整交互 |
| 创建 Rect/Poly/Path/Text | 有 | Enter完成、Backspace退点、切页/取消清草稿；1nm矩形与有限小数PATH宽度；无效轮廓保留提示；TEXT显示STRANS但UI字体不是mask font。绘制专项57项，设备矩形/多边形路径已验 | ● 核心 / ◐ 全组合 |
| 移动 / 删除 / 多选 | 有 | 有 | ● |
| 查找定位 / 批量属性 | 有 | 按 Cell、layer/datatype、类型、文本查找并定位；属性批改遵守层锁、数据校验和批次撤销；本批 HAP 与实际服务 host 检查通过 | ◐ 待设备验收 |
| **撤销重做** | 有 | **● 事务化**：一次手势=1条；微移400ms合并并在切页/撤销前flush。Cell结构、引用/栈/属性、库/PCell依赖也一并undo/redo；可选字段undefined和RECT/POLYGON类型正确恢复；零变换保留redo。设备Cell/PCell数量1→2→undo1→redo2 | ● 指定流程 / ◐ 全组合 |
| **顶点编辑** / 对齐 / 变换 | 有 | **● 顶点编辑已落地（ArkTS 编译验证，行为未经设备复核）**：选中图形显示手柄、拖拽改形（RECT 对角锚定、POLY/PATH 自由）、边上插点、删除顶点，全部过 `checkOutline`（有限值/零长边/<3 distinct/自交拒绝）；`AdvancedEditService` 的原零调用死 API 已改造为纯函数提交路径 | 已达 |
| **Cells Tab / Cell 树** | 有 | 引用树、新建/重命名/删除/进入；默认TOP真实存在，结构历史原子恢复并重映射剪贴板引用；删除校验当前栈/引用/最后Cell。实际Index36项；本轮设备新增Cell、undo及实例双击/返回已复验 | ● 指定流程 / ◐ 全组合 |
| **Flatten 打平** | 有 | **● v0.4：选中实例/整 Cell 全部实例**（嵌套实例变换合成，可撤销） | 已达 |
| 阵列复制 / 尺寸调整 | Make Array / Size | 对话框 + 批量撤销；Clipper2 2.0.1 偏移支持 join/end/miter 参数，非法输入整体拒绝。API24 对带孔环整体侵蚀 -100 nm 后保存重开，面积 1,800,000 nm²、1 孔，独立 KLayout XOR=0 | ● 核心与指定设备流程已验证 |
| **布尔运算（编辑）** | Merge/Sub/And/Xor | native Clipper2 2.0.1；host 与 OHOS x86_64 的 KLayout/GEOS 对照各 1833 例（833 精确 + 1000 预定量化界），核心/编辑输出分别验证。API24 相减得环、保存重开，面积 3,000,000 nm²、1 孔，KLayout XOR=0。详情与界限见 [几何报告](../validation/geometry-20260930.md) | ● 有界验证与设备专项 |
| **PCell** | Basic 库 + 脚本 | **内置 12 种（含 ELLIPSE）**；参数更新全部引用、工程/marker/器件库持久化；插入/undo/redo完整包括Cell和依赖，不只几何。设备参数500→750→undo500及Cell数1→2→undo1→redo2已验；新椭圆与其他器件组合仍需分别验收，动态脚本注册仍defer | ● 指定流程 / ◐ 其他器件组合 |
| Dirty / 未保存退出 | 有 | 按文档ID+revision保存，异步切页/编辑不清新版本dirty；自动草稿、版本副本；本轮真实GDS保存重开保真、最终覆盖安装恢复3标签；新建OASIS导出后仍保持未保存 | ● 指定流程 / ◐ 平台范围 |

## 7. 保存与验证

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| 按 Cell 结构保存 | 有 | ownerCell + writeGdsii / writeGdsiiDocument；API24 生成的 2 Cell/12×12 AREF 在编辑保存后经 KLayout 重读仍保留结构 | ◐ 指定流程已验 |
| open→save→reopen 黄金测试 | 工程实践 | 历史 NODE/AREF/属性样本专项保留；2026-09-30 新增 API24 2in1 的真实 AI AREF 位移、环相减和后续侵蚀的保存/picker 重开，三个输出对各自预期的 KLayout XOR 均为 0；API26/arm64 与任意文件/异常退出仍未签核 | ◐ P1 |
| 工程、普通保存/另存、恢复 | 有 | `.hongtu` 工程保存几何及PCell/图层/标尺/视图元数据；普通 GDS 保存复用目标、另存使用 picker；自动草稿与版本副本、暂存写出失败保护已接线。恢复/异步保存 host 通过，异常退出/长期运行设备覆盖待完成 | ◐ 已实现 / 待设备验收 |
| 版图 A/B 比较 | 几何 XOR / 结构 Diff | 独立导入 B，保留 A；按 layer/datatype 合并后真实几何 XOR 与 A/B 独有面积，含完整所选层级、对齐偏移和显式网格；全库结构 Diff、Cell/差异高亮定位与 JSON 报告。失效版本不用于定位，过大预览显示完整bbox而不补画假区域 | ◐ native/host通过 / 待设备验收 |
| DRC | 工业 DRC 语言 | 原生内核与有界层级展开；运行前同步当前dirty文档，失败/回退与触顶保留完整性告警。SKY130 met1三规则已有独立对照；新增电脑已注册deck运行和报告面板，内置仍仅met1子集。完整目标PDK规则未安装/未验收，禁止当签核 | ◐ 子集与扩展接口 |
| **图像导出 SVG/PNG、OASIS** | 有 | native 渲染/结构化导出；当前dirty/new文档先同步，picker返回后再次检查版本；期间切换/编辑取消过期导出。SVG/PNG编码已有smoke，新同步/异步守卫host通过 | ◐ 新流程待设备验收 |
| **LVS / Net Tracing** | 完整 | **◐ 连通性级预检查 + 实例层级展开**（`lvs_engine`：默认仅同层交叠/PATH 轮廓提取；仅显式传入工艺 via 表才跨层连通，内置演示表仅定义 Via1(10: M1↔M2)、Via2(11: M2↔M3)，Via3(12) 因无 M4 定义不自动连通；连通分量由 BFS 提取、TEXT 标签命名、与 SPICE 按名比对分开路/短路/多余网络、`exportSpiceNetlist`；导入 GDS/OASIS 保留原始层号，不能套用演示层表；`hierarchyDepth` 与画布同口径，SREF/AREF 内几何与标签一并变换到被检查 Cell——不展开时实例内部连通不参与，会整片误报开路；触顶置 `truncated` 不得当通过）；UI 可达；**依赖版图标签、非签核** | 已达（受限） |
| 工艺器件 LVS | 提取与网表等价 | 电脑端真实 KLayout MOS4演示工艺提取+SPICE比较，提供器件/网络数、完整性与报告；工艺包关联本机注册的hash固定deck。设备原生路径仍只做几何连通性预检查，UI不混称器件LVS。真实MOS4 pass/fail与HTTP检查通过 | ◐ 演示工艺已验证 / 完整PDK待验 |

## 8. 脚本与扩展

| 能力 | KLayout | 鸿图现状 | 优先级 |
|------|---------|----------|--------|
| Ruby/Python API | 核心 | 真实CPython+官方klayout.db伴随服务；新增当前dirty文档/选区快照输入、参数模板、有限扫参、历史、预览与版本保护的载入/合并，输出依赖Cell改名避免覆盖；受限执行边界保留。完整可信CLI已有，HarmonyOS内嵌解释器/Ruby/动态PCell注册未实现 | ◐ 新流程host/HTTP通过 / 待设备验收 |
| PCell / Library / Package | 有 | 内置参数持久化、再次编辑及重生成；可保存参数预设或当前Cell+依赖到持久器件库，导入/导出后插入、冲突Cell改名并可撤销。器件默认层号仍为演示映射，须按实际PDK绑定；动态脚本PCell defer | ◐ 已构建 / 待设备验收 |
| Technology Manager | 有 | `hongtu-technology/v1` JSON导入导出，统一layer/datatype用途/颜色、精确通孔连接、DRC规则、器件参数及PDK/deck关联；包校验失败保留旧配置，按文档持久化；注册deck仅在电脑端运行且强制报告实际规则范围 | ◐ 工艺包可用 / 完整PDK待验 |
| 宏 / 拼音快捷键 | 有 | 宏记录/执行之外新增持久化管理、重命名/删除、导入导出和批次撤销；快捷键已有。新管理与执行事务host通过，设备端仍待专项 | ◐ 新管理已构建 |
| AI 助手 | 无 | 真实模型→Python→电脑伴随服务执行→SVG 预览→载入流程已设备验证；AI JSON 命令保留 datatype，非零类型文档不走旧 Demo 图层捷径 | ◐ 生成结果须独立验证 |

---

## 9. 完善主链（Phase）

```text
真实 GDS
  → 正确库/Cell/Shape/Instance（C++ 真源）
  → hierarchy depth 下变换展开几何显示   ← 已实现，继续扩展组合与设备覆盖
  → GPU / 空间索引可交互
  → 当前 Cell 受控编辑
  → 结构化保存 + 重开比对
```

| Phase | 里程碑 | 目标 |
|-------|--------|------|
| A | M0 | 防误判收口 + fixture/验收表规范 |
| B | M1 | **层级几何展开**（对齐 KLayout hierarchy depth） |
| C | M1 | GPU 主路径 + 裁剪/LOD |
| D | M2 | 编辑事务 + GDS 往返黄金测试 |
| E | M3+ | OASIS、可信 DRC、脚本/PCell 等 |

### 明确 defer

- layer animation、视图书签、image landmarks 等 Basics 长尾；工作区Session已经接入
- 动态脚本PCell/Ruby内嵌、完整目标PDK DRC/LVS与签核能力
- 图形界面完成度不能替代层级、格式和数值验证

### 复用点（实现时）

`scene_graph.h` · `spatial_index` · `geometry_engine` · `NativeHongTuService` · `EditService` Cell 栈 · `ViewService.hierarchyDepth` · `LayoutCanvasView` 面包屑 · `gdsii_reader` Top Cell

### 关键实现文件（Phase B）

- `entry/src/main/cpp/gdsii_reader.*` · `scene_graph.h` · `napi_init_v2.cpp`
- `entry/src/main/cpp/types/libhongtu/Index.d.ts`
- `entry/src/main/ets/services/NativeHongTuService.ets` · `ViewService.ets`
- `entry/src/main/ets/components/workbench/LayoutCanvasView.ets` · `GlCanvas.ets`
- `entry/src/main/ets/pages/Index.ets`
- `tools/gdsii_smoke.cpp` · `tools/run_native_smoke.ps1`

---

## 10. 2026-09-19 收口、2026-09-23 核对与剩余门禁

本节保留 **2026-09-23 的历史构建、计数与设备范围**，不是 2026-09-30 最终包记录；本轮新增设备证据见 §11。不得将不同批次的冒烟计数合并解释。

历史 PATH/XY 写出记录中的 `roundtrip_smoke` 为 36 项断言点，其中端型/XY 分片专项 5 项；该计数按原批次保留，不能当作本轮全部保真验证的数量。

**2026-09-19 已收口的能力曾经四层门禁验证；截至 2026-09-23，本轮 Windows MSVC 与 WSL g++ host 冒烟均为 17 套、462 项通过，`bash tools/check_all.sh` 文档/脚本、host、x86_64 NDK、ArkTS/HAP 四层门禁退出 0。以下是本轮证据：**

| 项 | 证据 |
|----|------|
| §3 统一 DBU/屏幕/Y 轴口径契约 | `tools/coordinate_smoke.cpp`（49 断言，含 SVG/PNG 与画布同向逐点比对） |
| §4 PATH 真实线宽（flush/round/extended） | 同上：DRC 间距实测、SVG 轮廓、round 端头简单多边形断言 |
| §3 层级变换合成顺序（SREF/AREF/嵌套/循环引用） | 同上：`mag→mirrorX→rot→trans` 与 ArkTS 参考实现逐点比对 90 例 |
| §7 LVS 连通性预检查（UI 可达） | `tools/lvs_smoke.cpp`（第四轮日志 99 项通过，含同名断网 open、畸形/未支持网表拒绝、标签导出保护；89 个静态断言调用点，循环带来更多运行检查） |
| §2/§7 GDS NODE 与保存专项 | native `gdsii_smoke`/`roundtrip_smoke`、ArkTS 回退 host 检查；API24 x86_64 模拟器以合法 NODE/AREF/属性样本打开、另存、编辑连续保存及 picker 重开第二份保存文件；缺 XY 的旧样本被严格拒绝，不用作无损往返证据 |
| 默认图层选择 | 最终 HAP 重装后打开合法 NODE/AREF 样本，默认选择可绘制 L7 而非 NODE 所在 L9；API24 模拟器实测能画 L7 矩形 |
| 工具栏与顶栏菜单 | 最终 HAP 在 API24 模拟器横向滚动后可点“实例”并打开 Cell 弹窗；顶栏适配/重置/DRC/AI/宏五项入口可点击（仅入口检查，功能结果另计） |
| §5 测量 / 持久标尺 | ArkTS 层；`constants.canvasTransformConsistent()` 画布自检 |
| NAPI 层编译覆盖 | `tools/native_build.sh`（此前无任何命令检查 `napi_init_v2.cpp` 能否编译） |
| CI g++ 路径可信度 | `tools/check_portable.sh`（clang++/libc++ 代理；发现并记录 `plugin_system.h` 9 处模型偏离） |

API24 专项的未编辑另存 `validcopy.gds` 与 436B 源文件 SHA-256 同为 `76AD9893A74E67ECCFBCDDDCF8379FA7DC5A90FA7061E38E9616E218A0D57A79`，原始 TOP SREF/AREF/NODE 及属性记录逐字节保留。新增矩形后的两次保存各为 692B、10 图形；独立解析均得 TOP SREF7+NODE1+BOUNDARY1、CHILD BOUNDARY1，NODE 的 LAYER9/NODETYPE5/XY 两点/attr50 保留。第二次保存的 SHA-256 为 `7418B83971AFCE8E042EAF6A2742639F4FC7F2EBC5676B3A74B3011007B1E4A1`，与 436B 源文件不同；两次编辑后输出仅 BGNLIB/BGNSTR 时间戳记录不同，不能称逐字节相同。

统一门禁产出的 unsigned HAP 为 `entry/build/default/outputs/default/entry-default-unsigned.hap`（15,964,577 字节，SHA-256 `11AB12FBEBF148F286A1899763E2F5B7E189B22CA71FF2A83D2194AB6B65734E`）；包内同时含 arm64-v8a 与 x86_64 库，本轮仅在 HarmonyOS 6.1.0.117 API24 x86_64 模拟器做设备专项。

**2026-09-23 当时的剩余门禁（2026-09-30 增量见 §11）：**

- **截至 2026-09-23，API24 模拟器只完成上述 GDS、默认图层与菜单入口专项**。2026-09-30 已增加指定 AREF 展示/编辑和 LYP 显示/导出验证；API26/arm64 真机、全部层级组合、GPU 主路径真机帧率、测量吸附手感、完整样式/动画、顶点编辑手势仍待验收，相关行继续标 `◐`。
- §4 百万图元流畅交互（TypedArray/数据下沉）、§2 其他属性类别的设备专项、LEF-DEF（P3 defer）。
- 布尔/offset 与 DRC/LVS 均**不可签核**，此定位不得在文档或 UI 中被弱化。
**教训（写死在这里，避免第三次）**：记录号/枚举值这类"对外契约"不能靠 reader↔writer↔fixture 三处互相印证——它们同源于同一个错误假设时，全套断言依然全绿。必须以规范/参考实现为准，并让 fixture 使用**真实码**。

### 宽度口径定案（merged-region DRC 用；一手资料裁定，非本机推演）
争点：两个 100×100 方块错位 (60,60) 的阶梯并集，min-width=70 时该报 40 还是 40√2≈56.57。
**KLayout 的 width 检查不是 size/offset 口径**，而是"朝向彼此的边（back-to-back）之间的距离"：
`klayout.de/doc/about/drc_ref_layer.html`（"If two edges form a 'back to back' relation … their distance is less than the specified value, an error shape is generated"，并明示 "Merge semantics applies … disconnected polygons are merged before the width is checked"）；
`klayout.de/doc/code/class_Region.html` 的 `width_check(d, whole_edges, Metrics metrics = Euclidian, …)` 给出三种度量：Euclidian `sqrt(dx²+dy²)`、Square `max(|dx|,|dy|)`、Projection（要求两边互有投影）。
⇒ **默认（Euclidian）口径下本例应为 40√2≈56.57 且必须报**；40 是 `square` 度量的结果（也即"内缩到断裂"口径），不是默认行为。对角细腰确实在检测范围内（论坛 #1250 明确 `width()`/`square`/`euclidian` 都会报、只有 `projection` 不报；#1912 补充默认 `angle_limit(90)` 只查夹角小于 90° 的对面角对；issue #281 与 0.28.16 changelog 记录非共线/非曼哈顿配置下的 kissing corner 也已被检测）。`space` 检查同族（"face to face" + merged semantics）。
**证据更新（2026-09-30）**：本机现有真实 KLayout 0.30.12，已完成合并区域 width/spacing/area 的独立对照；上文特定 70 nm 阈值例子的数值陈述仍属于文档推演，不能拿其它案例的报告替代该例实测。
**因此本仓库口径**：`mergeSameLayer` 路径按 **Euclidian 边对距离**测并与 KLayout 默认对齐；若要复现 40 需显式走 square；断言文案必须写清度量名。现有 DRC 报告仅验证每个布局的违例有无，不声称标记数量/位置逐项一致，也不把 Manhattan 随机集外推为任意角度规则签核。

## 11. 2026-09-30 增量设备证据与当前边界

本轮真实应用操作运行于 **HarmonyOS API24、x86_64、MateBook 2in1 模拟器**。设备交互与随后在电脑上使用官方 KLayout 的独立读回分别记账：

| 设备操作 | 独立读回结果 | 机器可读证据 |
|---|---|---|
| 实际 AI 生成 12×12 AREF → 执行 → 预览 → 载入 → X+120 nm → 保存/picker 重开 | 2 Cell、12×12 AREF 与步进保留，和预期平移的 XOR 面积为 0 | `artifacts/industrial-foundation-20260930/ai-ui-roundtrip.json` |
| SKY130 inverter 显示 54 图形/22 对；导入标准 LYP；67/44 显隐/锁定与 67/20 独立；导出标准 LYP | KLayout 读出 22 对，名称、frame/fill 颜色、宽度、可见性符合预期；隐藏 67/44 未隐藏 67/20 | 同目录 `device-lyp-report.json`；锁定 UI 证据 `mcon-locked.json` / `li1-unlocked.json` |
| 两个方形相减得环，保存并重开；再对整个选中环侵蚀 -100 nm，保存并重开 | 两次面积分别为 3,000,000 与 1,800,000 nm²，均保留 1 孔，分别与预期 KLayout XOR=0 | 同目录 `device-geometry-roundtrip.json` |

1,833 例几何差分与 DRC 随机布局对照是不同测试集。几何中的斜边使用预定 DBU 量化界；DRC 仅覆盖 SKY130 met1 三规则、检查违例有无，固定案例跨批次重复。详细计数、种子、范围和完整性限制均以 [几何与 DRC 报告](../validation/geometry-20260930.md) 为准，不能简单相加成独立案例总数。§10 的历史冒烟计数保持原值。

这些专项关闭了对应的“全部设备待测”描述，未完成的门禁仍包括 API26/arm64 真机、百万图元交互性能、全部格式/层级组合、长期编辑和异常退出/掉电恢复、完整目标 PDK DRC 与工艺器件 LVS 提取及签核。本轮公开样本与有界数值对照**不构成工业生产签核**。

## 12. 本轮功能补全与验收分界

最终 release HAP 已构建并覆盖安装；新增工作区/恢复、搜索与批量属性、持久PCell器件库、独立A/B比较、工艺包与验证、当前编辑态原生操作、Python输入/模板/扫参和宏管理均已有代码与UI接线。最终源码 15 套宿主回归 220 项通过，指定设备流程包括恢复、搜索/库、PCell更新撤销、Python副本和公开子集DRC修正复检。A/B最终设备运算、部分picker与完整平台范围仍未验收；完成记录与包版本由 [功能补全报告](../validation/feature-completion-20260930.md) 单独记录，不借用 §10/§11 的历史包结论。

- 原生比较有实际区域集合/孔/重复覆盖、layer/datatype隔离、严格结构差异、失败不报等价和精确通孔用途的有界验证。
- 保存测试直接执行当前Index方法，覆盖异步编辑/切页、完整输入深拷贝、失败保留dirty、重入拒绝；工艺包与结果定位检查覆盖非法包不污染旧配置、请求Cell与报告/定位一致、过期版本拒绝。
- 电脑Python套件实际执行KLayout DRC pass/fail、MOS4提取及网表不匹配、hash固定本机deck、HTTP认证/Origin与未知deck拒绝；这些结果证明所测范围，不构成完整PDK签核。

仍未完成：API26/arm64与本批完整交互验收、长期异常退出/掉电可靠性、百万级流畅交互、全格式与变换组合、动态脚本PCell/Ruby内嵌、完整目标PDK与foundry签核。统一工艺包提供关联和运行接口，不会自动取得、安装或验证未提供的完整工艺规则。
