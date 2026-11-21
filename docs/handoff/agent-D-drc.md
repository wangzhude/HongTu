# Agent D — 原生 DRC 层级展开（KLayout flattened 语义）交接

日期：2026-09  ·  范围：`drc_engine.h` / `napi_init_v2.cpp`（仅 runDrc 段）/ `Index.d.ts`（仅 runDrc 相关）/ `DrcService.ets` / `tools/drc_smoke.cpp`
门禁：`run_native_smoke.ps1` 全绿（drc_smoke 断言 11 → **36**）；`NATIVE_OUT=/tmp/nb_d bash tools/native_build.sh` 链接 `libhongtu.so` 成功。
未跑：hvigor / assembleHap（ArkTS 由中心编译）；未改 `scene_graph.h`、未改 `run_native_smoke.ps1`。

## 1. 做了什么

native DRC 内核以前只在**各 Cell 的本地几何**上测量，SREF/AREF 实例里的真实几何完全不参与检查。
现在 `DrcConfig::hierarchyDepth` 控制展开深度，几何集合改由 `Layout::flattenHierarchy`
（scene_graph.h 既有路径，含 AREF 阵列展开与 ancestors 环剪枝）产出，每个图形按其到根 Cell
的累计矩阵（mag→mirrorX→rot→trans，Y 轴向下不翻转）变换后再测量。遍历逻辑零重写。

- `entry/src/main/cpp/drc_engine.h:108` `DrcConfig`：新增 `hierarchyDepth`（0=旧的本地口径 / 1=KLayout 风格默认 / 更大更深，`<0` 归一为 0）、`rootCellId`、`maxCheckedShapes`（默认 200000，组合爆炸上限）。
- `drc_engine.h:132` 新增 `DrcRunStats`（`checkedShapes/instanceShapes/skippedOverCap/truncated/hierarchyApplied/effectiveDepth/rootCellId`）+ `DrcEngine::lastRunStats()`（`drc_engine.h:170`）。
- `drc_engine.h:387` `buildLayerIndices()`：根 Cell 解析次序 `rootCellId → ownerCellFilter → layout.topCellId()`；depth≥1 走 `flattenHierarchy(root, depth+1, …)`（其 UI 深度语义 1=仅本地，故 +1 换算）；不可展开（depth=0 或根解析失败）时**逐字节退回旧本地口径**（`ownerCellFilter==-1` 仍覆盖全部 Cell）。`Layout::findCell` 无非 const 重载，故用 `layout.cells` 自查根是否存在（`drc_engine.h:400`）。
- `drc_engine.h:337` `CheckShape` + `LayerIndex::shapes`：检查器改为吃自包含的“已变换图形”记录（shapeId/layer/datatype/type/折算后 pathWidth/ownerCellId/viaInstance/变换后重算 bbox/多边形），不再回查 `Layout::shapes`。bbox 由**变换后顶点重算**（旋转后不能变换原 bbox 角点）。
- PATH 线宽按 `sqrt(|det|)`（= magnification）折算；恒等矩阵不重复变换。
- `drc_engine.h:212`（`kTruncationRuleId`，声明在 `:149`）命中 `maxCheckedShapes` 时在违规列表**首位**插入 `ruleId="DRC.TRUNC"` 的完整性告警（不静默漏检），并 `stats().truncated=true`。
- `drc_engine.h:486` `addViolation(..., const CheckShape* src, const CheckShape* src2)`：违规带 `fromInstance` / `sourceCellId`，实例命中的 message 追加 `" [via instance]"`。
- `entry/src/main/cpp/napi_init_v2.cpp:1394`（runDrc 段）：`argc` 2 → 3，尾选 `hierarchyDepth`（省略=0，**完全向后兼容**；负数=0，上限 16 层）；违规对象新增 `fromInstance/sourceCellId/bboxMinX/bboxMinY/bboxMaxX/bboxMaxY`。descriptor 条目（文件末尾 `{"runDrc", nullptr, NapiSafe<NapiRunDrc>, …}`）未动。
- `entry/src/main/cpp/types/libhongtu/Index.d.ts:427` `runDrc(rules, ownerCellId?, hierarchyDepth?)`；`Index.d.ts:169` `NativeDrcViolation` 新增 4 个 bbox 字段 + `fromInstance?`/`sourceCellId?`（全为可选，旧调用零影响）。
- `entry/src/main/ets/services/DrcService.ets:366` `runDrc(shapes, onProgress?, useNative=false, ownerCellId=-1, hierarchyDepth=-1)`（尾选参数，`-1` = 用 `this.hierarchyDepth`，服务默认 **1**）；`DrcService.ets:523` 私有 `runNativeDrc()`（`:119` 直取 native 模块）：因 `NativeHongTuService.runDrc` 只转发 2 参且该文件不在我的所有权内，改由本文件按 `GlCanvas.ets:20` 既有写法直接 `import hongtu from 'libhongtu.so'` 取 3 参入口，模块不可用时回退 `nativeHongTuService.runDrc`（此时 native 按 depth 0 处理）。
- `DrcService.ets:131` `hierarchyDepth` 字段 + `:216` `setHierarchyDepth()`；`:207` `setDeepMode(v)` 不再只是标志位：`true→max(1,depth)`、`false→0`，与 `deepMode` 双向同步（WorkbenchInspector 的 Toggle 因此变成真开关）。
- `DrcService.ets:88`/`:90` `DrcResult` 新增 `hierarchyDepthApplied` / `arkFallbackRules`；`:480` 当 native 展开确实生效却仍有规则走不展开的 ArkTS 补检时，追加一条 `ruleId="DRC.NOHIER"` 的 WARNING（纯 ArkTS 结果则由 `hierarchyDepthApplied=0` 表达），**绝不把回退结果标成已展开**。ArkTS AABB 检查器本身未改（它拿不到实例展开几何）。

## 2. 旧引擎漏掉的 concrete example（现已断言）

`TOP` 本地只有一条远离战区的 L6 长条；`SUB` 内有 `0,0-1000,100` 与 `0,160-1000,260` 两条长条（净距 60nm，M1.S=90 规则必违）。
`TOP` 里放 `SUB` 的 SREF（rot 90° + trans(5000,0)）与另一个 mirrorX 的 SREF。
旧引擎（depth 0 / filter=TOP）报 **0 项**，UI 显示“DRC 干净”；KLayout 会报 2 项。
现在 depth 1 报 2 项，位置分别在 **(4870,500)**（旋转后）与 **(500,-130)**（镜像后），
即实例变换后的坐标，而不是子 Cell 局部的 (500,130)。`tools/drc_smoke.cpp` 断言 (a)-(e) 全部覆盖。

## 3. UI 集成需求（我无权改 pages/Index.ets 与 WorkbenchInspector.ets，请据此接线）

1. **展示本次口径**：`DrcResult.hierarchyDepthApplied`（0/≥1）与 `arkFallbackRules`。
   建议状态栏在现有 `DRC 完成: …` 后追加 `· 层级 N/未展开`；`arkFallbackRules>0` 时追加 `· 部分未展开`。
   文案必须保持「快速几何预检查，非签核」（gap-matrix §尾 已有硬约束）。
2. **深度输入**：DRC 面板加一个 0/1/2/… 的选择器 → `drcService.setHierarchyDepth(n)`；
   现有「深度模式」Toggle（`WorkbenchInspector.ets:327`）已自动与 `hierarchyDepth` 同步，无需改语义。
3. **两条伪违规要在列表里显眼**（它们不是规则违例，是结果完整性告警）：
   `ruleId === 'DRC.TRUNC'`（native 展开触顶，结果不完整）、`ruleId === 'DRC.NOHIER'`
   （部分规则未展开）。建议用 warning 底色 + 不参与 `passed` 判定。
4. **定位**：`fromInstance === true` 的违规，其 `shapeIds` 属于**子 Cell**，在当前 Cell 的图形表里
   `findShape` 查不到 → 「定位/高亮」必须走 `x/y`（native 已回传 `bboxMinX/…/bboxMaxY`，
   当前值为命中点 ±50nm，可按需换成真实违规区域）。`sourceCellId` 可用于提示“位于 X 的实例内”。
5. `entry/src/main/cpp/types/libhongtu/Index.d.ts` 与 `NapiRunDrc` 的注释已同步，不需要额外改 native 声明。

## 4. 仍未对齐 KLayout 之处（保持「非签核」措辞，不得弱化）

- **无布尔合并**：同层多边形仍是逐图形测量。KLayout 的 `width/spacing` 对 *merged* region 计算，
  故「三根条合并后才有 90nm 以下 neck」这类缺陷这里仍会漏。要补需接 clipper2 union + 对合并轮廓做测量。
- **逐实例重复报告**：同一子 Cell 实例化 N 次会产出 N 份同样几何的报告；KLayout hierarchical DRC
  在子 Cell 上跑一次再映射结果。当前 flattened 近似只在图形数可控时可接受。
- **展开根唯一**：一次 run 只检查一个根 Cell（`ownerCellFilter==-1 && depth>=1` 时取 top cell），
  其余 top cell 不会被自动跑一遍；旧行为（一次覆盖全部 Cell 本地几何）在 depth=0 保留。
- **实例内 TEXT/INSTANCE 元素不参与**（沿用旧过滤）；密度窗口、enclosure/overlap、派生层布尔
  仍依赖 experimental clipper，均为近似。
- **truncation 只报“丢弃了多少图形”**，不报被截断的具体区域。
- **DRC 结果无增量/无缓存**：depth≥1 的展开集合每次重算，大设计需自行限制深度或用 tiling。
- ArkTS 回退路径（文档 dirty 时）**仍完全不展开**，其结果口径由 `DrcResult` 字段如实标注。

## 5. 复验命令

```bash
powershell -ExecutionPolicy Bypass -File tools/run_native_smoke.ps1 -OutputRoot 'C:/Users/28384/AppData/Local/Temp/ht-smoke-D'
NATIVE_OUT=/tmp/nb_d bash tools/native_build.sh
```

## 6. 文档需同步（我无权改 README / docs/roadmaps）

- `README.md:20` 与 `README.md:174`、`README.md:7`：把「不展开实例层级」改为「**深度可控的实例层级展开**
  （`hierarchyDepth`，默认 1 层）；仍为逐图形快速预检查、非签核」。
- `README.md:91`：`drc_smoke.cpp # 原生 DRC 内核（11 项断言）` → **36 项断言**（含层级展开/环剪枝/
  变换坐标/AREF 阵列/截断告警）。
- `docs/roadmaps/klayout-feature-gap-matrix.md:93`（§7 DRC 行）：删除「不展开层级」，改为
  「◐ v0.4：原生内核主路径 + **深度可控层级展开**（SREF/AREF 变换到根 Cell 后测量，触顶报 DRC.TRUNC）；
  逐图形无布尔合并 → 快速预检查，禁止当签核」；§3 层级相关行（`:114`、`:123`）可把 DRC 从
  「未展开」缺口中移除，渲染/导出侧的层级签核仍未完成。
