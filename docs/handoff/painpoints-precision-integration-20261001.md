# 精度、图层、曲线集成交接（2026-10-01）

本代理只修改 PrecisionService、CurveDrawingService、SnapService、StatusBar、DrawingToolbar、WorkbenchSidebar、PlacePCellDialog、pcell_framework，以及 WorkbenchOverlays 的 LayerStylePanel 局部及 UiLayer.sourceName 类型。Index、Canvas、EditService、Workspace 和导出链路由 root/其他代理接线。本批未执行 HAP 构建/设备验证/提交。

## 精度与吸附

`PrecisionSettings` 在 `services/PrecisionService.ets`：

```ts
{ dbuNm, drawStepNm, displayGridNm, geometrySnapEnabled, geometrySnapKinds }
```

WorkbenchStatusBar 新增同名 props；`drawStepNm=-1`、`displayGridNm=-1` 为向后兼容、回退旧 gridSize。`precisionChangeAction(settings):boolean|void` 提交精度；`precisionContextProvider():string` 绑定文档与版本，弹层拒绝过期提交。新的 popup 使用现有状态栏入口，包含实际 DBU、绘制步长（0关闭网格吸附）、显示网格、几何吸附开关与目标类型。

Index 接线：保存/恢复独立 displayGridNm 与 drawStepNm；原 gridSize 可继续视为 drawStepNm 的兼容字段。不要把 drawStep=0 写进原 Workspace.gridSize（旧校验必须 >0）；确保迁移旧工程时使用旧 gridSize 初始化两者。DBU 对应 physicalUnits=dbuNm*1e-9、userUnits=dbuNm/1000。DBU 变化应作为文档事务，先使用 `quantizationReport` 对现有坐标/宽度/延伸/AREF步向量等将写入的字段检查；有偏差展示影响数量、最大偏差及示例，再由 root 的现有确认/版本记录流程处理。

`quantizeToDbu(requestedNm,dbuNm)` 的负半单位舍入与 native llround、ArkTS GDS writer 一致（远离0）。`quantizationReport(valuesNm,dbuNm)` 返回 count/changedCount/maxDeltaNm/firstChange；`quantizationText` 可接属性录入和保存提示。它报告偏差，不自动静默修改几何；GDS 32位范围仍须由 writer 检查。

Canvas 分别接 `displayGridNm` 用于显示网格，`drawStepNm` 用于snapToGrid和微移。`SnapService.snapToGeometry` 可选第5参数 `kinds:string[]`，名称为 `顶点/交点/中点/包围盒中心/边`，空数组关闭几何。旧4参调用行为不变。请显示测量与绘制的吸附类型，并保留原始/落点/DBU写入值区分。

## 图层

WorkbenchSidebar 新增 `selectableLayerAction(layerNumber,datatype,selectable)`；图层行有独立显示（眼睛）、选择（选）和编辑（改/锁）入口及右键/长按菜单。Index 创建替换 UiLayer 数组、刷新access与style revision、保存草稿；只改变访问权限和显示配置，不改变L/D身份或几何。

LayerStylePanel 新增 `actualLayer:UiLayer|undefined`、`changeStyleAction(nextLayer)`；实际读取线型/填充/透明度、显示别名与sourceName，不再硬编码值。未加载actualLayer时显示缺失说明。样式提交使用完整JSON克隆，保留sourceName和未知可序列化元数据。`UiLayer.sourceName?:string` 表示文件真实名称，独立于chineseName/englishName显示别名；其他clone函数请保留此字段。

Selection代理负责让锁定层可只读选择、检查，任何变更入口仍要求canEditLayer。不要用selectable=true解除编辑锁定。

## 曲线

DrawingToolbar 新增 `curveAction(name)`，4种值 CIRCLE/ELLIPSE/DONUT/ARC。竖向浮动栏高度从284增到444（内容可滚动）；若父布局空间受限，请约束为可见高度而非遮挡状态栏。

PlacePCellDialog props：`initialPCellName`（预选曲线）、`initialLayerNumber`、`initialDatatype`、`initialOutputMode`（instance默认/polygon直接）、`dbuNm`。现有onConfirm的前4参保持兼容，第5参数是 `PCellPlacementOptions`（services/CurveDrawingService.ets）：

```ts
{ outputMode: 'instance' | 'polygon', datatype, maxErrorNm }
```

root的curveAction应设置initialPCellName=name/initialOutputMode='polygon'，再打开原有dialog；现有“放置参数化器件”入口仍默认instance。onConfirm实例模式复用现有insertPCell；polygon模式调用native生成几何，先验证全部图形/锁层/坐标/预算，再将位移后的普通图形作为当前Cell单一事务插入，不创建变体Cell/实例或参数marker。多图形器件也可选择普通图形输出，应保留其真实layer并根据显式datatype落数据。

Native新增 ELLIPSE（radius_x/radius_y半轴、segments、layer/datatype/max_error），所有4种曲线新增datatype和max_error。max_error=0按边数；>0使用保守弦偏差界自动增加采样，最多4096段，超限明确拒绝。椭圆采样段数取4的倍数保留轴向极值；圆/环/弧原max_error=0默认几何保持原行为。曲线最大偏差与DBU量化误差分别显示，不能把曲线误差当总导出误差。NAPI已有默认合并与validateParams流程，无需新增桥接字段。

## 验证

- `node tools/precision_curve_host_check.mjs`：9项通过，运行生产helper和状态栏/现有dialog/样式真实提交方法，覆盖负半DBU、偏差报告、独立配置、目标筛选、曲线误差、stale context、callback拒绝和保留真实层元数据。
- WSL Ubuntu g++17/O2 `tools/curve_precision_smoke.cpp`：43项通过，4种曲线非零datatype、0.1nm弦误差界、椭圆轴极值及方程、预算、无效datatype/NaN/不可达精度/720°弧拒绝。
- WSL g++17/O2 `tools/pcell_smoke.cpp`：原54项通过，registry更新12种/Basic9种。
- 旧drawing_workflow fixture曾因同时在修改的Canvas新增hitVisibleCandidates依赖未抽取而失败；已告知Selection代理同步更新fixture，并非此代理的曲线算法失败。统一门禁需使用最终集成源码再跑。
- `git diff --check`针对本批生产文件通过（仅Git CRLF提示）。HAP/实际布局/触控/参数化转普通图形后的bool/export需要root后续构建和目标设备验收。
