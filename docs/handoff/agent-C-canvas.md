# Agent C 交接 · 画布测量 / 标尺（gap-matrix §5 + §3）

> 范围：仅 ArkTS 画布层。本文件记录**边界外**需要别人落地的改动。
> 状态：测量与标尺已在画布内闭环可用，**无需** `pages/Index.ets` 改动即可运行。

## 1. 本轮已落地的文件（我的边界内，无需交接）

| 文件 | 变更要点 |
|------|----------|
| `common/constants.ets` | 单位与变换唯一出口：`NM_PER_UM` / `nmToUm()` / `umText()` / `worldToScreenPx()` / `screenToWorldPx()` / `canvasTransformConsistent()` |
| `common/UiStores.ets` | `CursorStore` 增 `shapeId`/`layerNumber`/`readout` 及 `setHit()`/`setReadout()`（值不变不赋值）；新增 `@Observed MeasureStore` + `RulerLine` |
| `services/SnapService.ets` | 新增 `snapToEdge()`（边上垂足）；`snapToVertex()` 加包围盒粗筛 + 平方距离比较（SNAP-2） |
| `components/workbench/LayoutCanvasView.ets` | 测量态由 4 个 `@State` 迁到 `MeasureStore`；实时橡皮筋、第三次点击重开测量、顶点/边/网格三级吸附、Shift 锁 45°、持久标尺（拖拽定向 + 清除）、光标命中读数、`aboutToAppear` 坐标自检；新增叶子组件 `MeasureLayer` / `MeasureModeButton` |
| `components/workbench/StatusBar.ets` | X/Y 改 µm 显示、增「光标层」指标、增测量读数位 |
| `components/workbench/DrawingToolbar.ets` | 仅注释更正（标尺与测量在触屏上合并为同一入口） |

## 2. 单位 / 轴向契约（后续所有读数必须遵守）

- 世界坐标内部**一律 nm**：native 读取器已做 `dbu * physicalUnits * 1e9` 归一
  （`cpp/gdsii_reader.cpp` 的 `coordinateScaleNm`），ArkTS 侧**不得**再做第二次 DBU 换算。
- 显示 µm 只允许经 `common/constants.umText(nm)`（默认 3 位小数 = 1nm 分辨率）。
- 屏幕变换只允许经 `worldToScreenPx` / `screenToWorldPx`：
  `pixel = (world + offset) * zoomPercent / 100`，X/Y 同式不翻转（与 ArkUI Y 向下、
  GL 相机 `ndc_y = 1 - 2*pixel/h`、`worldViewportFromCamera()` 同口径）。
  `LayoutCanvasView` 的私有同名方法与 `MeasureLayer` 均已委托该实现。
- `canvasTransformConsistent()` 在画布 `aboutToAppear` 自检一次（互逆 + 轴向 + µm 换算），
  ArkTS 侧无测试框架，沿用 `console.warn('[Module] ...')` 惯例。
  与 native 侧新增的 `tools/coordinate_smoke.cpp`（断言 `toPixelY` 随世界 Y 单调递增、Y 向下不翻转）
  同一口径：任一侧引入翻转，两侧的自检会同时报警。
- `services/AdvancedEditService.ets` 的 `Ruler` / `createRuler()` / `getRulers()` / `deleteRuler()` /
  `clearRulers()` 仍是**零调用**的死 API（其 label 也写死 `${Math.round(dist)}nm`）。本轮画布改用
  `MeasureStore`（`@Observed`，可被 UI 观察），未复用该服务：非响应式 + 无调用方 + 单位口径不符。
  后续要么把标尺模型收敛到它并改成 `µm`，要么删除该段死代码，避免"两套标尺真相"。

## 3. 需要边界外落地的改动

### 3.1 `workbench/WorkbenchModels.ets` + `pages/Index.ets`：把标尺升为独立工具（可选）

当前 `DrawTool.RULER = 7` 只有名字没有行为：`Index.drawToolToActiveTool()` 无 RULER 分支，
落到 `return ActiveTool.Select`；`ActiveTool` 也没有 Ruler 成员。标尺现已作为「测量」工具内的
模式开关可用（画布底部模式条），若要独立工具位：

1. `entry/src/main/ets/workbench/WorkbenchModels.ets` 的 `enum ActiveTool` 增一行：
   `Ruler = 'ruler',`
2. `pages/Index.ets` 的 `drawToolToActiveTool()`（约 3687 行）在 MEASURE 分支后增一行：
   `if (tool === DrawTool.RULER) { return ActiveTool.Ruler; }`
3. 画布侧随后把 `onMeasureDown()` 等处的 `s.rulerMode` 判定改为
   `this.currentTool === ActiveTool.Ruler || s.rulerMode`（本 Agent 边界内，一行改动，
   等第 1/2 步合入后进行）。

### 3.2 `pages/Index.ets`：状态栏提示位同步（可选，非必需）

读数已通过 `CursorStore.readout` 直接显示在状态栏。若还想让 `statusText` 播报测量结果，
在 `LayoutCanvasView({...})`（约 805 行）的入参里补一行回调即可（画布侧需另加同名回调属性并在
`syncReadout()` 内调用）：

`measureChangeAction: (text: string) => { this.statusText = text; },`

### 3.3 `common/UiStores.ets` + `pages/Index.ets`：标尺跨页面常驻（可选）

`MeasureStore` 现为 `LayoutCanvasView` 的私有实例，组件销毁即清空。若要求标尺跨 Cell 导航 /
页面重建保留：在 `UiStores.ets` 导出 `export const measureStore: MeasureStore = new MeasureStore();`，
`Index.ets` 以 `@State measureStoreRef: MeasureStore = measureStore;` 持有并透传，
画布侧把 `private measureStore` 改为接收 `@ObjectLink`。

## 4. 未验证项（务必由中央确认）

- **ArkTS 编译**：本 Agent 无编译器，未跑 `hvigor CompileArkTS`（按指示不尝试运行）。
  需重点确认：`MeasureLayer` / `MeasureModeButton` 以父组件**普通成员**
  （`private measureStore: MeasureStore = new MeasureStore()`）作为 `@ObjectLink` 数据源是否通过。
  若被判非法，退路是把该成员改 `@State`（只在工具切换时重建整树，拖动仍只写 store 内部属性），
  或按 3.3 由 `Index.ets` 持有后透传。
- 设备/模拟器行为：吸附手感、标尺拖拽定向、GL 降级路径下覆盖层与几何是否对齐。
- `tools/run_native_smoke.ps1 -OutputRoot ...` 在本机报 `NamedParameterNotFound`：脚本第 3 行为
  中文注释且文件无 UTF-8 BOM，Windows PowerShell 5.1 按 ANSI 码页解码后吞掉了紧随其后的
  `[string]$OutputRoot` 声明。加 BOM（或该注释改英文）即可，文件不在本 Agent 边界内。
  本轮未改任何 native 代码，未跑 `tools/native_build.sh`。
