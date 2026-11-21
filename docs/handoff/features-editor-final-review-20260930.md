# 编辑与工作区功能最终复核（2026-09-30）

本文记录 editing_gaps 负责模块的实现与验证边界，不代替主任务的整体构建、设备验收和发布报告。工作树原有改动保留，未提交。

## 已贯通的使用入口

| 用户入口 | 当前能力 | 使用边界 |
| --- | --- | --- |
| 顶部文件菜单「新建版图」「工程与历史」及标签栏新增 | 独立文档、工程文件、应用内自动草稿、版本副本恢复；标签间保存各自几何、选择、Cell 导航和撤销记录 | 同时最多 8 个活动标签；跨重启草稿恢复几何和状态，不持久化撤销栈 |
| 选中对象后的属性弹层 | 单选/批量位置、图层数据型、宽高、文本内容；PATH 端型/延伸/固定线宽；实例引用、旋转、镜像、倍率、阵列维数与有向步长；TEXT 旋转/镜像/倍率；用户属性 | 混合类型只显示公共字段；每次字段提交是一次整体撤销；修改的 X/Y 是各对象的绝对包围盒位置 |
| 顶部「搜索与筛选」或 Ctrl+F | layer/datatype、类型、尺寸范围、文本包含、当前/全库 Cell 范围、可选对象过滤；点击定位和当前 Cell 批选 | 显示前 200 项，批选覆盖全部匹配项；不会把不同 Cell 的图形混进当前编辑上下文 |
| 放置 PCell 与个人库「修改参数」 | 根据 native 参数声明生成；参数记录随图形保存；对同一变体 Cell 重建，全部引用一起更新，一次撤销还原几何和参数 | 更新会替换该 Cell 的手动几何修改；既有普通 GDS 几何若没有参数记录，不能自动推断为 PCell |
| 顶部「个人器件库」 | 收藏当前 Cell 及递归依赖、收藏 PCell 参数预设、搜索、放置、删除、导入/导出 `.htlib` | 最多 128 项；库导入合并同名同分类时跳过已有项；删除库条目不删除版图中已经放置的实例 |
| 画布绘制、测量、移动和选择拖动 | 精确顶点、交点、中点、包围盒中心、边吸附及网格回退；层级变换后的可见几何参与；移动预览与提交一致 | 视口候选上限 5000，超出时在指针附近重新取候选；交点检测限制在 128 条附近线段，不能声称对任意大版图穷尽全部交点 |

入口核对：`WorkbenchTitleBar.ets` 文件菜单已接四个新增入口，`Index.ets` 已连接 ProjectPanel、ShapeSearchPanel、ComponentLibraryPanel 和批量属性回调。旧的只靠右键发现功能的问题因此有所改善；本文不声称所有旧功能都重新设计了入口。

## 本轮继续发现并修复的问题

1. PATH 宽高之前显示含线宽/延伸的包围盒，却按同一比例缩中心线，输入值和最终显示不一致。现在扣除固定包络后缩中心线，并拒绝线宽以下的尺寸和无法通过缩放改变的零跨度轴。
2. 修改 AREF 行列或实例引用原本可绕过导入预算，编辑成功后自动草稿才失败。现在属性事务提交前验证整个候选层级，采用 native/Workspace 相同的「任一 Cell 最大展开不超过 100 万」口径，拒绝循环和超过 256 层的依赖；不将父子 Cell 重复累加。
3. 有限输入仍可能在坐标运算中产生 Infinity；binary 属性也可能填写非法 hex 或超过 GDS 属性容量。现在提交前拒绝这些结果，原几何与撤销历史不变。
4. 修改或清空用户属性会误删 PCell 参数记录，导致参数编辑入口消失。现在用户属性界面隐藏并保留该记录；`[]` 仅清空用户属性。
5. 批量更新和搜索批选存在逐 ID 扫描全库的重复查找。现在预建索引或单遍筛选；搜索结果标签使用缓存。2000 个搜索结果的批选回归已通过。
6. 同一选择数组因无关页面更新重新生成时，未提交的属性 JSON 草稿会被清空。现在仅在选择身份或原始属性实际变化时重置。
7. TEXT 已有原生变换字段却缺少属性入口。现在提供旋转、镜像、倍率并复用事务校验。
8. 旧 PCell 放置弹窗用 `parseFloat` 接收 `12nm` 等前缀，非法输入则悄悄回退默认值；整数也未严格验证。现改完整 `Number` 校验，遵循 native 的声明范围，严格检查段数/图层整数和有限坐标，并允许合法负角度、负坐标与小数。生成失败返回 false 时保留弹窗及输入。输入事件与画布快捷键隔离。
9. PCell 参数编辑弹窗重置旧定义状态，定义不可用时禁用更新，遵循声明范围，并明确提示重建会替换手动几何修改。

主要源码：`services/ShapePropertyService.ets`、`services/EditService.ets`、`components/workbench/ShapeSearchPanel.ets`、`components/workbench/ShapePropertiesPopover.ets`、`components/dialogs/PlacePCellDialog.ets`、`components/dialogs/PCellEditDialog.ets`。本轮未编辑 Index；root 已将放置回调接为返回 `insertPCell(...)` 的布尔值，源码复核确认。

## 已验证的数据保全

- EditService session 深拷贝形状、撤销/重做、选择和剪贴板，切换后不共享形状引用。首次载入另一文档清空旧剪贴板，避免粘贴旧 Cell ID；切回已存在标签可恢复该标签自己的剪贴板。
- PCell Cell 内容替换先校验全部模板及图层锁，原子提交一条撤销事务；用户属性、PATH 端型和实例变换随 undo/redo 恢复。
- 个人库子集导出重映射连续 Cell ID，保留有效空 Cell 和库/Cell/图形属性。放置先验证当前文档与导入内容的合并预算；中途异常恢复编辑 session、Cell 元信息、库属性和图层。
- Workspace 保存前冻结几何与元数据，短读/短写循环处理 UTF-8；只有完整文件发布后才更新索引，损坏主索引不覆盖有效备份。垃圾清理仅处理本服务生成、且 current/previous/history 均未引用的草稿，清理失败不影响已发布保存。
- 独立 Index 审查复现并协助 root 修复：旧图层过滤新文档选择、异步关闭确认清错标签脏状态、保存期间新空 Cell 被误标干净、恢复标尺 ID 重复、关闭时下一标签激活失败先删掉当前 session，以及 8 份恢复文档被无修改的选择刷新挤成 9 标签。
- 新增宏切页安全钩子回归：抽取实际 `finishMacroRecordingForDocumentChange`，验证 native 激活成功后、替换编辑器状态前保存旧文档录制；同文档调用不停止录制；native 激活失败保留原录制步骤和 UI 状态。此项使用最小 MacroService 替身，验证 Index 调用时机，不代替 MacroService 持久化测试。

## 实际执行的检查

| 检查 | 最近在本代理执行的结果 | 证明范围 |
| --- | --- | --- |
| `tools/features_editor_host_check.mjs` | **34/34 通过** | 生产服务及从实际 UI/Index 源码抽取的控制器；批量事务、PATH 尺寸、TEXT 变换、展开预算、属性编码、搜索批选、PCell 输入/回改/元数据、库放置回滚 |
| `tools/index_workspace_host_check.mjs` | **14/14 通过** | 原 12 项工作区检查 + 2 项宏切页安全检查；实际 Index 方法 + 生产 EditService/WorkspaceService/MeasureStore |
| `tools/workspace_recovery_host_check.mjs`，带 native SRAM fixture | **21/21 通过** | 实际 Workspace/ComponentLibrary 服务；真实磁盘短 IO、故障注入、索引/库恢复、并发写入、保真与预算 |
| `tools/layer_access_host_check.mjs` | 前一阶段 **29/29 通过** | 图层锁定、隐藏、可选权限及现有编辑行为；未在本轮为重复计数再跑 |
| `tools/editing_geometry_host_check.mjs` | 前一阶段 **19/19 通过** | 真实 C++ 几何探针及原有编辑几何；未在本轮为重复计数再跑 |

Node 执行形式：`node --experimental-transform-types --disable-warning=ExperimentalWarning tools/<name>.mjs`。前三项分别运行，不能把控制器宿主测试描述成真实设备点击验收。平台 UI、原生调用运输和必要的文件选择器由替身提供；恢复套件的文件 IO 使用真实临时磁盘并注入短读/短写和发布失败。

SRAM fixture 由当前生产 `gdsii_reader.cpp`、`layout_import_budget.h` 和 `property_wire.h` 导出：公开 `sram22_64x24m4w8.gds`，**4892 Cells、120822 个基础图形、最大单 Cell 展开 550687**。形状、Cell 名及库/Cell 属性深比较完整保留；另有显式图形属性和空 Cell 用例。生成脚本为 `tools/workspace_native_fixture_build.ps1`；工作区套件的 fixture 参数为 `artifacts/editor-features-20260930/native/sram64x24.hongtu`。

`tools/check_all.sh` 已接入编辑、恢复和 Index 工作区检查。最近针对所改源码的 `git diff --check` 无空白错误，仅显示仓库 CRLF 提示。

## 明确的边界与后续验收项

- 本代理没有运行最终 hvigor 构建、安装或设备点击。最新一轮 ArkTS/UI 变更仍由 root 的统一构建和设备验收确认，不把旧构建结果套用到新源码。
- PATH 的属性尺寸沿用模型的保守包围盒定义，不能当作任意圆端/斜线路径的精确多边形测量。搜索尺寸使用本地 shape bounds；实例自身是放置点，尚未以递归实例内容包围盒做尺寸筛选。
- 正常撤销一次库/PCell 放置会撤销几何和实例，新增空 Cell 定义保留；故障回滚则恢复所有新增元数据。
- 内部草稿/库发布提供应用沙箱文件的原子替换；通过系统文件选择器覆盖外部 URI 时，不承诺第三方文档提供方具备同等原子覆盖保证。
- 属性 JSON 为最多 64 项的 GDS 属性记录编辑器，包含内置参数记录的总数限制；不是任意无限大小的用户数据存储。字体/presentation 位、任意控制点编辑等不能被本文“属性增强”误称为全部开放。
- 设备待验：多选字段失焦提交与混合值提示、JSON 输入草稿保留、手机键盘负号/小数输入、搜索定位后 Cell 切换、PCell 生成失败留窗和参数回改、库导入/导出文件选择器、工程恢复与标签关闭对话框。
- ProjectPanel 输入框和面板根键盘隔离、名称首字符规则文案已由 root 修复，本代理按当前源码复核确认。
