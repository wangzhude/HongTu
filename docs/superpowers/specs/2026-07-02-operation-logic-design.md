# 操作逻辑优化设计

> 针对 KLayout 操作痛点（综合官方论坛/GitHub/CSDN 调研 + 《KLayout 操作痛点调研报告》PDF），优化鸿蒙版操作流程。不改 UI 三栏布局，只改交互逻辑。

## 背景痛点（综合 web 调研 + PDF 报告，按"操作场景"分类）

> 数据来源：KLayout 官方论坛 discussion/2858/2860/2862-2872、GitHub issue #864、CSDN 综述，以及 `KLayout 操作痛点调研报告.pdf`（10 页，7 大痛点维度）。

### A. 本次设计覆盖的痛点（用户已选 4 类）

| 痛点 | KLayout 现状（web 调研） | PDF 报告补充 | 鸿蒙版目标 |
|------|-------------|-----------|-----------|
| 移动图形 | 只有 Move by 相对位移，用户心算位移 | PDF#2：拖器件需先点 MOVE 按钮才跟随鼠标，与商业软件不同 | 两点移动 + 输入框微调组合 |
| 对齐分布 | 无一等公民菜单，靠脚本 | — | 多选一键左/右/上/下对齐、等距分布 |
| 选中命中 | 过滤器状态脱钩、文字命中区极小 | PDF#3：无效图层上的图形无法选中；select_all 行为不一致；选择受缩放级别影响；需 RecursiveShapeIterator 遍历 | 过滤器状态即真实、命中区触屏友好、无效图层显式提示 |
| 图层批量 | 搜索不持久、无右键改层、无分组预设 | PDF#4：大文件需手动关闭图层降渲染压力，无组合预设 | 搜索持久、多选右键改层、显隐预设 |
| DRC 配置 | 写 Ruby 脚本，无 GUI | PDF#7：KLayout 是批处理式验证，无实时 DRC（商业工具有） | GUI 开关配置规则、预设规则集 |
| DRC 跳转 | marker 导航断链 | PDF#5：0.29.7/0.29.8 DRC 段错误 bug 影响结果可信度 | marker 点击跳转定位 |

### B. PDF 报告独有痛点（本次设计补充处理）

| 痛点 | PDF 来源 | 处理方式 |
|------|---------|---------|
| **Cell 层级显示控制** | PDF#3：引用子 Cell "明明引用了却看不到图形"，需用层级滑块/F11/Show as New Top，过度使用致视图混乱 | **纳入**：层级显示默认 2 级 + 画布提供层级滑块控件（触屏友好大滑块）+ "重置视图"按钮 |
| **实例放置流程** | PDF#3：忘记回车确认、混淆相对/绝对坐标、旋转角度正负规则 | **纳入**：实例放置走 GUI 弹窗（选 Cell + 坐标输入 + 旋转下拉），不靠命令行回车 |
| **功能入口深** | PDF#2：常用功能在多层菜单深处，新用户找不到 | **纳入**：右键上下文菜单统一入口（已在本设计） |
| **学习曲线陡峭** | PDF#1：繁杂工具栏菜单，新手不知从何入手 | **部分纳入**：工具栏只保留高频工具 + 拼音快捷键标注降低记忆负担 |
| **大文件加载性能** | PDF#4：大 GDSII 加载缓慢/卡顿 | **标注为 Phase 2**：鸿蒙版当前是 demo 数据，真实大文件优化待 native reader 成熟后做（关闭图层/部分加载/缓存配置） |
| **稳定性/崩溃** | PDF#5：版本兼容、内存限制、脚本崩溃、插件冲突 | **不纳入**：属工程稳定性范畴，非操作逻辑 |
| **OASIS 格式** | PDF#4：OASIS 比 GDSII 小 40-60%，快 30% | **标注为 Phase 2**：native 已有 oasis_reader.cpp，待接通 |
| **实时 DRC** | PDF#7：商业工具有实时 DRC，KLayout 无 | **标注为 Phase 2**：机会点，但当前 DRC 引擎性能不足以支撑实时 |
| **签核级验证/生态** | PDF#7：与 Cadence/Synopsys 差距 | **不纳入**：超出开源工具定位 |

### C. 设计哲学差异（PDF + web 调研共识）

KLayout 是德国工程师风格：精确、命令行、代码优先、把控制权交给用户。这导致：
- DRC 是全功能 Ruby 脚本而非 GUI 配置器（作者明确表态）
- 只有"Move by 相对位移"没有"移动到绝对坐标"
- 快捷键靠用户自定义，默认不全
- LVS/DRC 结果走 CLI 工具链思维

鸿蒙版的翻译策略：**在脚本能力之上包一层 GUI**，不抛弃能力，只降低门槛。

## 设计

### 1. 移动图形：两点移动 + 输入框组合

**操作流程**：
1. 选中图形
2. 工具切到"移动"（右键菜单或工具栏 `YD` 拼音快捷）
3. 手指/鼠标点基点（图形上任意点或空白处）
4. 拖拽到目标点 → 释放，图形移动到位
5. **可选**：释放时若长按 >500ms，弹出输入框显示当前位移 `(dx, dy)`，可手动微调精确值后确认

**实现**：
- `EditService` 新增 `moveShapeAbsolute(id, fromX, fromY, toX, toY)` —— 内部算 `(toX-fromX, toY-fromY)` 调现有 `moveShape(id, dx, dy)`，记录 undo 栈
- `LayoutCanvasView` 新增 `ActiveTool.Move` 工具态，onTouch 处理两点移动 + 长按弹框
- 与现有拖拽移动（Select 工具下直接拖）区分：Select 拖拽是快速调整，Move 工具是精确定位

**不做什么**：
- 不做命令行输入坐标
- 不做绝对坐标输入（输入框只显示位移 dx/dy，非目标坐标）—— 用户已选"两点+输入框组合"

### 2. 对齐分布：多选一键对齐

**操作流程**：
1. 框选多个图形（现有框选逻辑需确认是否支持，不支持则用 Ctrl 多选替代）
2. 右键菜单 → "对齐" → 子菜单：左对齐/右对齐/上对齐/下对齐/水平居中/垂直居中/水平等距/垂直等距
3. 或工具栏对齐按钮组（现有 EditorToolbar 已有 alignLeftAction 等，从桩改为真实调用）

**实现**：
- `AdvancedEditService.alignSelection(type: AlignType)` 已存在且真实实现
- `AdvancedEditService` 新增 `distributeSelection(type: DistributeType)` —— 水平/垂直等距分布，算法：按 x/y 排序，首尾固定，中间均匀分布
- `EditService` 需支持多选（当前是单选 `selectedId`）—— 新增 `selectedIds: Set<number>`，`selectShape` 改为支持累加选择
- 主页面 Index.ets 的 `alignLeftAction` 等从桩改为调 `advancedEditService.alignSelection(type)`
- 右键菜单新增"对齐"子菜单项

**多选支持**（这是对齐的前提）：
- `EditService` 新增 `selectMultiple(ids: number[])` / `addToSelection(id)` / `clearSelection`
- `getSelectedShapes()` 返回所有选中（当前返回数组但最多 1 个）
- 触屏框选：LayoutCanvasView 的 onTouch 在 Select 工具下，空白处按下拖拽画选择框，释放时选中框内所有图形

### 3. 选中与命中优化

**选中过滤器状态同步**：
- 鸿蒙版当前没有 Select Filter UI，不会继承 KLayout 的状态脱钩 bug
- 但需确保：选中行为可预测 —— Select 工具下点击命中即选中，不命中的点不算选中
- 新增"选中过滤器"轻量面板（右键菜单或 Inspector 内）：按图层/类型过滤可选中对象，状态即真实状态

**命中区触屏友好**：
- `EditService.hitTest(x, y)` 当前用 `getShapeBounds` 边界框，对小图形/文字命中区不足
- 新增命中容差参数：`hitTest(x, y, tolerance = 8)` —— 8nm 容差（触屏下适当放大到 15nm）
- 文字对象：ShapeType.TEXT 的命中区扩展为 bounds + padding
- 选中态视觉：选中框描边加粗 + 4 个角控制点（handle）放大到 16px（触屏友好）

### 4. 图层批量操作

**搜索持久化**：
- WorkbenchSidebar 的图层搜索框输入值存到 `AppStorage`（`layerSearchKey`），重启恢复
- "区分大小写"等偏好存 `PersistentStorage`

**多选图形右键改层**：
- 选中多个图形 → 右键 → "改图层" → 子菜单列出所有图层 → 点击目标图层
- `EditService` 新增 `changeLayer(ids: number[], newLayerNumber: number)` —— 批量改 layerNumber，记 undo 栈
- 主页面 Index.ets 新增 `changeLayerAction(targetLayer)`

**图层显隐预设**：
- 新增"视图预设"概念：当前所有图层 visible 状态可保存为预设（如"只看金属层"、"只看掺杂层"）
- `ViewService` 新增 `saveLayerPreset(name)` / `applyLayerPreset(name)` / `listLayerPresets()`
- WorkbenchSidebar 底部新增预设下拉 + 保存按钮
- 预设存 `PersistentStorage`

### 5. DRC 配置 GUI 化

**规则配置面板**：
- WorkbenchInspector 的 DRC 模块新增"规则配置"区域
- 28nm 默认 9 条规则，每条显示为开关 + 参数输入框：
  - `MIN_WIDTH L1 [开关] [90] nm`
  - `MIN_SPACING L2 [开关] [100] nm`
  - `MIN_AREA L1 [开关] [8100] nm²`
  - ...
- 开关控制 `rule.enabled`，输入框改 `rule.value`
- 顶部"规则集"下拉：28nm默认 / 14nm默认 / 自定义 —— 切换时调 `drcService.setRules(ruleset)`
- `DrcService` 新增 `setRules(rules: DrcRule[])` / `getRules()` / `setEnabled(ruleId, enabled)` / `setValue(ruleId, value)`

**规则集预设**：
- `DrcService` 新增 `createRuleset(process: string): DrcRule[]` —— 支持 '28nm'/'14nm'/'7nm'
- 规则集定义放 `common/drcRulesets.ets`

### 6. DRC marker 跳转定位

**操作流程**：
1. 运行 DRC（右键菜单或 `YY` 快捷键）
2. 结果显示在 WorkbenchInspector DRC 列表
3. 点击某条 violation → 画布跳转到该位置并高亮

**实现**：
- `DrcViolation` 已含 `x/y/width/height`（位置信息）
- 主页面 Index.ets 新增 `locateViolation(violation)` 方法：
  - 设置画布 offset/zoom 使 violation 居中并放大到合适比例
  - 设置 `highlightedViolationId`，LayoutCanvasView 高亮显示该区域（红色闪烁框）
- WorkbenchInspector 的 DrcIssueRow 点击回调 `locateIssueAction(issue)`

### 7. Cell 层级显示控制（PDF#3 痛点）

**痛点**：KLayout 引用子 Cell 时"明明引用了却看不到图形"，需手动调层级滑块/F11；过度用 Show as New Top 致视图混乱。

**设计**：
- `ViewService` 新增 `hierarchyDepth: number` 状态，**默认 2**（显示两级嵌套，避免"引用了看不到"）
- 画布顶部浮动控件新增"层级"大滑块（触屏友好，1-5 级），拖动实时改 `hierarchyDepth` 触发重绘
- 新增"重置视图"按钮（右键菜单 + 工具栏），一键恢复默认层级/缩放/居中
- 不做 "Show as New Top"（易致视图混乱，PDF 已证实是坑），改为"进入子 Cell 编辑"明确入口：双击实例 → 进入该 Cell 独立编辑视图，顶部显示面包屑（Top > SubCell），有"返回顶层"按钮

**实现**：
- `ViewService` 新增 `setHierarchyDepth(n)` / `resetView()`
- `LayoutCanvasView` 渲染时按 `hierarchyDepth` 过滤实例递归深度
- `EditService` 新增 `enterCell(cellId)` / `exitToTop()`，维护 `currentCellStack: number[]`

### 8. 实例放置 GUI 化（PDF#3 痛点）

**痛点**：KLayout 实例放置靠命令行回车确认，易忘；混淆相对/绝对坐标；旋转角度正负规则易错。

**设计**：
- 工具栏新增"放置实例"工具（`SF` 实例拼音首字母）
- 点击后弹出 GUI 弹窗（非命令行）：
  - Cell 选择下拉（列出当前文件所有 Cell）
  - 坐标输入框（**绝对坐标**，标注"目标位置"，不搞相对/绝对混淆）
  - 旋转下拉：0° / 90° / 180° / 270°（按钮组，不输入正负数）
  - 镜像开关：无 / X / Y
  - 确认/取消按钮
- 确认后在画布放置实例，记 undo 栈

**实现**：
- `EditService` 新增 `createInstance(cellId, x, y, rotation, mirror): number`
- 新建 `components/workbench/InstancePlaceDialog.ets` —— GUI 弹窗组件
- 主页面 Index.ets 新增 `placeInstanceAction()`

## 涉及文件

| 文件 | 改动类型 | 内容 |
|------|---------|------|
| `services/EditService.ets` | 增强 | 多选支持、moveShapeAbsolute、changeLayer、hitTest 容差、enterCell/exitToTop、createInstance |
| `services/AdvancedEditService.ets` | 增强 | distributeSelection 新增 |
| `services/DrcService.ets` | 增强 | setRules/getRules/setEnabled/setValue、createRuleset |
| `services/ViewService.ets` | 增强 | saveLayerPreset/applyLayerPreset/listLayerPresets、setHierarchyDepth/resetView |
| `common/drcRulesets.ets` | 新建 | 28nm/14nm/7nm 规则集定义 |
| `components/workbench/LayoutCanvasView.ets` | 增强 | Move工具两点移动+长按弹框、框选多选、命中容差、violation高亮、层级滑块控件、面包屑导航 |
| `components/workbench/WorkbenchSidebar.ets` | 增强 | 图层搜索持久化、显隐预设下拉 |
| `components/workbench/WorkbenchInspector.ets` | 增强 | DRC规则配置面板、规则集下拉 |
| `components/workbench/ContextMenu.ets` | 新建 | 右键上下文菜单组件（编辑/复制/测量/对齐/改图层/DRC/删除/重置视图/进入子Cell） |
| `components/workbench/InstancePlaceDialog.ets` | 新建 | 实例放置 GUI 弹窗（Cell选择+绝对坐标+旋转按钮组+镜像开关） |
| `pages/Index.ets` | 增强 | 接通所有新 action、locateViolation、changeLayerAction、placeInstanceAction、框选逻辑、enterCell导航 |

## 不做什么

- 不改三栏布局（已合理）
- 不加命令行输入（用户未选）
- 不加鼠标手势（用户未选）
- 不做 DRC 脚本编辑器（GUI 配置已足够）
- 不做 LVS（范围外）
- 不改 GL 渲染（独立任务）
- 不做"Show as New Top"（PDF 证实易致视图混乱，改为明确的进入/退出子 Cell）
- 不做大文件性能优化（Phase 2，待 native reader 成熟）
- 不做实时 DRC（Phase 2，DRC 引擎性能不足）
- 不做 OASIS 接通（Phase 2，native 已有 reader 待集成）

## 验证标准

- 两点移动：选中→Move工具→点A→拖到B→图形移动，长按B弹框可微调
- 对齐：框选3+图形→右键对齐→左对齐生效
- 命中：小图形/文字触屏可点中
- 图层：搜索"金属"→重启仍在；选2图形右键改层→两图形图层都变
- DRC配置：规则面板开关关掉一条→运行DRC→该规则不检查
- DRC跳转：运行DRC→点violation→画布跳转高亮
- Cell层级：引用子Cell默认可见；层级滑块拖到1→子Cell隐藏；重置视图恢复
- 实例放置：工具栏放实例→弹窗选Cell+输坐标+点旋转→确认后画布出现实例
- `hvigorw assembleHap` 编译通过
