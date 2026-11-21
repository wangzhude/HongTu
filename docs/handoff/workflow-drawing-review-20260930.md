# 绘制与编辑动作流程复查（2026-09-30）

范围：既有 LayoutCanvasView / GlCanvas / ShapePropertiesPopover、EditService / AdvancedEditService / SnapService 和既有微调弹窗。沿用现有 UI shell；没有新增页面。Index、共享枚举与键盘映射由 root 接线；Cell 结构历史由 root 处理。

## 动作矩阵

| 工具 / 动作 | 完整流程与本轮处理 | 验证 |
|---|---|---|
| RECT | 按下吸附起点→拖动预览→Up 用 changedTouches 终点提交；不再拒绝 1 nm 矩形；单点不创建 | drawing：释放点、1 nm；取消、多指中断 |
| POLYGON | 点击加点、移动鼠标显示下一段橡皮筋；双击或完成按钮或 Enter 完成；Backspace/“退一点”移除末点；Esc/取消丢弃草稿 | drawing：退点/完成/取消、预览不落库 |
| POLYGON 合法性 | 首尾闭合点去重；拒绝自交、零边、共线零面积；无效轮廓保留草稿并显示原因 | drawing：闭合点、共线三角形；原顶点检查继续适用 |
| PATH | 与 Polygon 共用加点/完成/退点；允许开放路径自交；宽度必须完整、有限、正数，错误保留草稿 | drawing：空串、前缀、Infinity、0 拒绝及 0.5 nm 成功 |
| PATH 端型 | 原生渲染读取 PATH0/1/2/4；ArkUI 叠加/降级路径补 Butt/Round/Square 与 PATH4 signed 扩展；命中包括实际端部延伸 | drawing：扩展/缩短命中、重复端点与 signed 扩展显示；SDK/triangulator 源码核对 |
| TEXT | 点画布吸附落点→既有输入框→确认创建；切文档/工具关闭旧输入；属性和变换读取 rotation/mirror/MAG；文字叠加层补相同矩阵 | drawing：TEXT 变换数据与 glyph 矩阵；设备文字外观待 root |
| TEXT 精确输入 | Enter 用 SubmitEvent 最终文本调用同一确认方法；boolean 失败/异常/空白保留窗口和编辑状态，成功只创建一次；上下文复用 Index 参数窗口 token 并包含工具/图层，切页/改 Cell/修订/选择/模式或工具、只读往返都拒绝旧回调 | precision_input：实际 Dialog→Canvas→Index→EditService 链，锁层失败保留原输入、亚 nm 落点、一次 undo、过期/重复确认 |
| INSTANCE / AREF | 使用既有放置弹窗；本轮补选择后旋转/镜像/缩放，同步 MAG 和父 Cell 坐标系的两个阵列步进向量 | drawing：AREF 旋转向量、两次异轴镜像、实例缩放/撤销 |
| 单选（GL / fallback） | 中央 hitVisibleShape→Up 选中，覆盖没有 ShapeNode 的 GL-only 图元。递归命中实际可见子轮廓并返回当前 Cell 根实例 ID，双击仍走原进入 Cell 流程；保留显式实例 marker 入口 | drawing：GL-only、远离锚点的叶图形→根实例、双击进入、当前 Cell 隔离、root 锁层 |
| 实例点命中 | 同一层级索引与变换缓存筛选；bbox 仅排除候选，polygon/RECT 真轮廓、PATH 原生端帽与 miter 判定；AREF 逆步进矩阵找附近行列，零步进副本合并，退化步进投影范围并受预算控制 | drawing：旋转/镜像/MAG/多级 AREF；donut 空洞/阵列缝隙不命中；百万斜阵列仅 20 节点预算可查询；退化预算/循环失败保留旧选择 |
| 光标命中读数 | Measure 使用同一点查询；返回根对象 ID，显示被命中叶图形的真实 layer/datatype；显示层级/可见性/文档修订使缓存失效 | drawing：真实 trackCursorHit 根 ID 与叶图层读数 |
| 多选 / 框选 | Shift 点击加减一次；无初始选中时可从空白拖框；左→右包含，右→左相交；Up 更新末帧，即使未收到 Move。实例递归合并当前深度可见子图形的变换后边界，不使用锚点/LOD 框；预算/循环/坐标失败保留旧选择 | drawing：空选框、方向、Shift、无 Move、远离锚点的子图形、失败原子性、缓存失效 |
| 选中拖动 | 从多选中的任何成员开始→预览全选集→一次事务提交；单击不因网格把图形移位；保留亚 nm 位移 | drawing：多选成员、网格点击、亚 nm |
| Move 工具 | 拖动吸附基点/终点并一次提交；慢速拖动不再误弹微调；只有原地长按打开微调 | drawing：慢拖与原地长按 |
| 精确位移 | 既有弹窗保留样式；允许正负小数；空串、数值前缀、Infinity 均保持窗口并提示；输入键盘事件隔离 | drawing：真实弹窗 handleConfirm 抽取 |
| 顶点移动 / 只读 | Up 消费实际终帧坐标后提交，避免快速拖拽缺少 Move 时保存旧点；Canvas editable 变化撤销手势、解绑顶点并关闭编辑弹窗；只读仍可选择/测量/框选放大 | drawing：无 Move 的终点提交及一次 undo、已经开始的顶点编辑被只读拒绝；root 接可编辑状态 |
| Measure | Shift 限制同时作用于橡皮筋预览和第二点击确认；可在完成后立即开始下一条测量 | drawing：实际 MeasureStore 与 Canvas 预览/完成坐标一致 |
| 吸附 | 已有顶点→交点→中点→中心→边优先级；层级展开真几何、上限与排除移动对象；命中容差现在随缩放保持屏幕大小 | editor：角点、交点、中点、真实层级几何；设备吸附反馈待 root |
| 框选放大 | BOX_ZOOM 进入专用工具→拖框→按画布比例放大并居中→回 Select；不改选区/图形/undo | drawing：实际缩放与平移回调；root 已接枚举与完成回调 |
| 复制 / 粘贴 | 深复制字段、新 ID、默认偏移 20 nm；先检查所有目标图层、有限点、递归环/展开预算，再一次事务提交 | drawing：父引用粘进子 Cell 拒绝、属性保留、一撤销 |
| 阵列复制 | 行列整数、pitch 有限；提前限制基础图形和 points；最终检查递归展开预算（不是只数压缩 AREF）；整体成功或零创建 | drawing：非法数量、Infinity、溢出、AREF 预算、属性/undo |
| 实例放置入口 | 完整数值校验并保留负数/小数坐标；服务预查有限变换、root 0/0 图层锁、直接/间接循环、基础图形/顶点预算及每 Cell 总展开预算；成功才消耗 ID | drawing：TOP→TOP、子→父环、600k+600k 累计展开拒绝，失败 session/ID/redo 不变；合法空 Cell 实例一次 undo |
| 编辑弹窗上下文 | Array/Size/Instance/PCell 记录打开时上下文；提交前变化直接拒绝。前三个确认支持 boolean/void，false 或服务异常显示错误并保持窗口；严格 Number 拒绝空白、数字前缀和 Infinity | drawing：抽取实际四弹窗方法，signed 小数、数量边界、context 改变、false/throw；Index 提供文档/修订/Cell/选区 token 由 automation 接线并独立验证 |
| Cell 名称 | 新建/重命名失败返回 boolean 并保留弹窗及名称；Enter 使用最终输入文本，失败保持编辑，Esc 取消且阻止延迟确认；上下文绑定文档/修订/Cell/选区/模式和命名目标。候选异常前置拒绝，结构提交异常沿用完整回滚；同名重命名成功但不新增历史 | index_workspace：真实 Dialog→Index→Workspace/Edit 链，新建/重命名一次 undo、重复/空白/过期/只读拒绝、快照与结构回调异常回滚、Esc 和 void 兼容 |
| Cell 树行刷新 | root 设备发现 TOP→INVERTER 后保存数据/面包屑正确而 Sidebar 旧行不刷新。根/子 ForEach 现以路径+完整有限子树显示内容+当前 Cell 生成渲染键，保留业务路径身份；展开操作按当前树路径修改并发布新数组，不依赖 plain class 深层字段观察 | cell_tree_refresh：实际 Index 构树/Sidebar 键函数 + ForEach 保留键模型，先红 TOP≠INVERTER，后根/共享子 Cell 重命名、引用变化、展开/当前节点、循环预算、稳定键 7 项 |
| 旋转 / 镜像 / 缩放 | 菜单仍逐对象自身中心；显式服务可给固定中心；预计算全批结果后提交。任意角 RECT 转四角 POLYGON；TEXT/INSTANCE 的 STRANS 与点一起更新 | drawing：矩形真实角点、类型 undo/redo、文字、AREF、镜像组合、锁层/溢出原子拒绝 |
| PATH 缩放 | 显式编辑缩放线宽及 signed 扩展；absolute-width 标记保留。该标记只抵抗实例 MAG，不阻止显式修改 PATH 自身尺寸 | drawing + layer：PATH4 scale/undo/redo；native reader/scene/triangulator 语义核对 |
| 对齐 / 分布 | 实例使用递归可见几何边界，PATH 使用与原生轮廓一致的端型/miter/带符号延伸边界；忽略隐藏子几何但包含锁定且可见子几何。中心等距分布仍固定首尾；预校验整批；零位移/浮点舍入尾差不增历史 | drawing：真实实例边界对齐/中心分布、一撤销、低深度/隐藏/循环/预算原子拒绝；PATH flush/round/square/custom端 |
| 布尔 / 尺寸调整 | 沿用真实 native 几何事务；无效/失败先拒绝，孔洞/多轮廓保留；不把 native 失败当空结果 | editing_geometry：真实 C++ 19 项 |
| 批量属性 | 同类完整字段、跨类公共字段；锁层/非法值全批拒绝，一步 undo；用户属性不覆盖 PCell marker；实例含四向阵列间距 | features_editor：既有 34 项复跑；本轮未改属性面板 |
| 属性精确输入 | Esc 在叶输入先恢复源值、清 changed，再移除焦点，避免 onBlur 意外提交；Enter/失焦共用 commit 防重复；同值提交直接返回，保留验证、native 缓存、AI 撤销和 redo | precision_input：同步失焦与 clearFocus 异常、同值/修改值、SDK 键码和快捷键隔离 |
| 中断 / 文档切换 | Cancel、第二指、Esc、切工具清未提交手势；documentKey 与 Cell 上下文变化清草稿、拖动、旧弹窗和双击缓存 | drawing：第二指/文档中断；root 接 documentKey |
| 面板键盘隔离 | 新增 keyboardBlocked，面板打开时画布即使保留焦点也不消费 Enter/Backspace/Escape 或转发 root 快捷键；关闭后恢复绘制 | drawing：实际 Canvas 方法阻止完成/删点/取消/root 转发，关闭后 Enter 正常创建；root 负责面板状态接线 |
| 撤销 / 重做 | 一次拖动/批量变换/复制/阵列为一条；旋转 0/360 或缩放 1 保留 redo；RECT/POLYGON 类型随历史恢复 | drawing + geometry + layer；Cell metadata 历史另由 root 测试 |
| 图层可见 / 锁定 | root 修 cloneLayerWithVisible 丢 locked；layer_access 改为抽取实际 WorkbenchData 克隆，移除 spread 替身；真实 LYP 入口验证 locked true/false 和所有显示字段 | 新回归先红（结果缺 locked），源修后 LYP 12/12；layer 29/29 |

## 主要实现位置

- `LayoutCanvasView.ets`：`onDocumentChanged`、`handleCanvasKeyEvent`、`finishPolyDraw`、`handleTouch`、`onDown/onMove/onUp`、`commitPendingShapeClick`、`polyPreviewPoints`、`textTransform`、`pathDisplayPoints`、`visibleShapeBounds/finishBoxSelect`、`getHierarchyBoundsResolver/hitVisibleShape/trackCursorHit`。
- `EditService.ets`：`createShapeCopies`、`transformShapes/transformedShape`、PATH 命中分支、`moveShape` 有限坐标检查；modify 的类型恢复由本轮补齐，其他结构 metadata 历史由 root 接续。
- `AdvancedEditService.ets`：三个选区变换入口、`checkOutline` 零面积检查、`alignSelection`、`arraySelection`。
- `MoveFineTuneDialog.ets`：严格 Number/finite 校验与键盘隔离。
- `ArrayCopyDialog.ets`、`SizeOffsetDialog.ets`、`PlaceInstanceDialog.ets`：严格有限输入、失败保留窗口、打开时上下文保护与输入事件隔离；`PlacePCellDialog.ets` 补相同上下文保护，沿用此前参数范围/boolean 确认。
- `HierarchyExpandService.ets`：`HierarchyBoundsResolver` 使用现有 HierarchyIndex 与实例矩阵，按 Cell/深度/线性变换/祖先路径缓存；旋转真实顶点后合并 bbox，AREF 的父坐标系步进用解析极值合并，不逐副本分配。上限 100 万展开图形、400 万访问顶点；native SREF 的 0×0 COLROW 归一为单实例。
- `HierarchyBoundsResolver.hitTestCell`：一次命中查询总计 10 万节点、40 万叶顶点预算。先按当前 Cell 根对象绘制逆序筛选，再递归真正轮廓；错误无 marker/bbox 兜底，禁止将不完整查询当作命中。root 对象仍受可见/可选/锁层规则限制，子几何用可见性筛选。
- `PathBoundsService.ets`：独立纯几何 helper，按 native `Triangulator::pathOutline` 的端型、8 段圆帽、miter、重复点/负延伸规则流式输出有序轮廓点，复用于边界与 `pathGeometryContains` 点内/世界坐标边距判定。普通 PATH 先轮廓后变换；absolute WIDTH 先变换中心线、保持线宽、延伸跟随 MAG。由 engineering 独立差分审查。

## 验证与边界

新增 `tools/drawing_workflow_host_check.mjs` 执行生产 Edit/Advanced 服务和抽取的实际 Canvas/Dialog 方法。平台事件、渲染回调、matrix4 构造是最小 stub；不是设备手势或像素证据。它已加入 `tools/check_all.sh`。

实例点选/PATH 收口后结果：drawing 57/57、editor 37/37、真实 native editing geometry 19/19、layer access 29/29、import ownership 10/10、canvas geometry 9/9、Y-up canvas 18/18、GL lazy fallback 28/28、fallback capacity 11/11、hierarchy culling 12/12、canvas keyboard 11/11 全部通过。日志在 `artifacts/workflow-completion-20260930/editor-*.log`（例如 `editor-drawing_workflow.log`、`editor-features_editor.log`）。10 套 Hierarchy host staging 都加载真实新 PathBoundsService，公共辅助为 `tools/stage_path_bounds.mjs`，没有用 stub 避开新实现。

后续普通编辑交互复查收口：drawing 增至 **68/68**（原 57 + 顶点/只读/测量 3 + 实例服务和四弹窗 8）；同轮复跑 editor **40/40**、layer **29/29**、macro document scope **9/9**、Index workspace **38/38**、真实 native geometry **19/19**、Y-up **18/18** 全绿。对应 `editor-drawing_workflow.log`、`editor-features_editor.log`、`editor-layer_access.log`、`editor-macro_document_scope.log`、`editor-index_workspace.log`、`editor-editing_geometry.log`、`editor-y_up_canvas.log` 已更新。失败基线 `editor-drawing-regressions-before.log` 保留原始顶点终帧丢失的断言：预期 (120,140)，实际 (100,100)。这些是实际源方法/服务 host 证据，设备复杂参考图复画与最终 HAP 仍由 root 独立执行。

精确录入复查后，新增 `tools/precision_input_host_check.mjs` **13 项**，已接入 `check_all.sh`。它把 `precision-input-readonly.log` 的修复前诊断转为真实源方法/服务回归：SDK CanvasKeyboard 解码、属性叶组件、TextCreateDialog、Canvas 确认、Index 属性/文本创建与同步以及真实 EditService。最新日志 `precision-input-final.log`；同轮 drawing **68**、editor **44**、Index workspace **41**、keyboard **11**、Y-up **18** 全绿，日志 `precision-*.log`。修复前的只读诊断脚本/日志是历史证据，不在当前门禁运行。

SDK 明确 TextInput 在非 TV 设备按 Enter 默认失焦；因此曾怀疑的“提交后仍焦点导致后续输入丢失”没有作为确认缺陷，也未据此改变组件焦点生命周期。失败的文本 Enter 显式使用 `SubmitEvent.keepEditableState()`，成功照常关闭。原生键盘/IME 和视觉行为仍由 root 的设备文字步骤最终验证。

Cell 命名同类缺陷先用真实方法复现：新建重复 `TOP` 后原编辑 session 保持不变，但弹窗错误关闭（`cell-name-before.log` 的 close=1 失败断言）。修复后 `index_workspace_host_check` 从 41 增至 **49/49**，新增 8 项完整命名流程；日志 `cell-name-final.log`。同轮 editor **44/44**、precision_input **13/13**、keyboard **11/11** 复跑通过（`cell-name-*.log`）。新增逻辑只修改既有 CellNameDialog 和 Index 命名结果接线；不影响设备当前手绘、构建 helper 或导出比较流程。

Sidebar 重命名显示复查单独新增 `tools/cell_tree_refresh_host_check.mjs` **7/7** 并接入 check_all。修复前因果日志 `cell-tree-refresh-before.log`，修复后 `cell-tree-refresh-final.log`；layer **29/29**、Index workspace **49/49**、editor **44/44** 同轮复跑，日志 `cell-tree-*.log`。只有 WorkbenchSidebar 生产文件变化，不修改 CellTreeNode 的业务 key，不修改 Index 保存/最近文件。ForEach 项缓存是显式 host 模型，真实设备旧行证据由 root 的 `artifacts/manual-redraw-20260930/rename-success.jpeg` / `manual-gds-saved.jpeg` 提供；最终修复后的原生行刷新仍待 root 小增量包设备确认。两处右键/长按 `.bindContextMenu(this.buildCellContextMenu(node), ...)` 原样保留。

PATH 独立原生差分 448 例 + 5 退化/越界/精确端点断言通过，覆盖四端型、重复点、近回折 miter、正负延伸、镜像/旋转/MAG/一般 affine、absolute WIDTH；日志和重放 cpp/mjs 位于 `artifacts/feature-completion-20260930/path-bounds-native-diff.*`。差分对照为实际 `effectivePolygonTransformed`。LYP/KLayout 12/12 在本次实例补丁前已复跑通过，相关源未改。drawing 与 LYP 已在 check_all 门禁。统一 ArkTS build / 安装 / 截图由 root 执行，本交接不宣称已设备验收。

点命中 helper 另有 `tools/path_geometry_host_check.mjs` 16/16（实际服务代码）及 336 组原生轮廓 × 84 点查询 = 28,224 次点内/欧氏边距差分全通过；重构后边界 453 断言复跑通过。最终日志在 `artifacts/workflow-completion-20260930/path-geometry-host.log`、`path-hit-native-diff.log`、`path-bounds-native-diff-final.log`，由 engineering 执行。

PATH 语义核对了 `cpp/triangulator.h` 的 0/1/2/4 端型及 signed extension、`gdsii_reader.h` 的 negative WIDTH 注释、`scene_graph.h` 的 absolute-width 变换分支；AREF 步进为父 Cell 坐标向量，依据 `HierarchyExpandService.ets` 与 `scene_graph.h`；TEXT 变换矩阵依据本机 SDK `@ohos.matrix4.d.ts` 列主序 `init` 定义，LineCapStyle 依据 SDK `enums.d.ts`。未查阅不相关网络资料。

仍需诚实呈现的范围：

- 实例框选/对齐/分布使用递归可见几何的轴对齐边界；右→左框选仍按边界交集判定，不是多边形精确相交。点选已经使用实际子轮廓，保留根 marker 的既有点击入口。文字尺寸仍是便于阅读的 UI 字体，不是严格 GDS font mask；TEXT bounds 和点选仍采用锚点及既有 16 nm 读数区域。
- 点查询预算是整个当前 Cell 查询的总预算，复杂退化阵列或超大平铺文件可能明确报告未完成查询；不会用整实例 bbox 或部分展开的结果伪造命中。正常指针容差按屏幕像素换算到世界坐标，边缘附近可命中属于既有容差行为。
- ArkUI PATH 叠加使用 stroke，native 主路径用三角化；尖角 join 与极端缩放的视觉一致性需设备截图确认，host 算法测试无法代替。
- 同一 Cell 中鼠标/触控 first-click 选中后再拖动；未添加未选图形一次按下即移动的独立手势行为。
- 磁吸的预算溢出仍明确退回局部几何/无候选，不从 LOD 假矩形吸附；没有新增全库无限展开。
- 本轮没有更换 shell、新增页面或生成模板；后续若新增页面，遵守用户最新模板要求。
