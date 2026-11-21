# Agent K — 图层显示样式真正驱动渲染（gap-matrix §5 线型/填充/透明度/动画）

上游：`docs/handoff/agent-H-lyp.md`（.lyp 导入/导出已落地，但样式字段无人消费）。
本切片把 **消费端**接上：ArkUI ShapeNode 回退路径、SVG/PNG 导出、GL 主路径（在其能力范围内），
并保证不 fork 第二套图层真相。

## 1. 逐路径审计（改造前 → 改造后）

`●` 消费 / `○` 完全没读 / `◐` 读但被上游掐断

| UiLayer 字段 | GL 主路径（GlCanvas + gl_renderer） | ArkUI ShapeNode（LayoutCanvasView） | SVG/PNG 导出（image_export.h） |
|---|---|---|---|
| `color` | ● 改前即有（`GlCanvas.layerColor`） | ● 改前即有（`LayoutCanvasView.colorForLayer`，改前 1755） | ● 改前即有（`rgbaToHex(lp.fillColor)`） |
| `visible` | ● 改前即有（`GlCanvas.isLayerVisible`） | ● 改前即有（`visibleLayerNumbers` → `isLayerVisible`） | ● 改前即有（`lp.visible`，SVG 220 / PNG 306） |
| `transparency` | ○ **改前**：`colorToRgba` 硬编码 `selected?0.92:0.62`，且 `gl_renderer.drawBatch` 又把 alpha 覆盖成 0.35/0.6/1.0 | ○ **改前**：`fillOpacity` 硬编码 0.58/0.62/0.88/0.92 | ◐ **改前**：SVG `fill-opacity` / PNG alpha 读 `lp.transparency`，但 ArkTS→native 的 `ApplyLayerStyles`（napi_init_v2.cpp:2185）把 transparency 一律写死 0.35 ⇒ 面板值到不了导出 |
| `lineStyle` | ○ 全链路无人读 | ○ 全链路无人读（仅测量线用固定 `[6,4]`） | ○ `LayerProperties.lineStyle` 存在但导出只输出实线 |
| `fillStyle` | ○ 填充/轮廓只由 `selected` 决定 | ○ 一律实心填充 | ○ `fillPattern` 无人读（PNG 永远整面填充） |
| `lineWidth` | ○ `glLineWidth(2.0f)` 写死 | ○ `strokeWidth` 写死 1/2 | ○ SVG `stroke-width="0.5"` 写死 |
| `highlighted` | ○ | ○ | ○ |
| `animated` | ○ | ○（仅 DRC violation 有闪烁，LayoutCanvasView 372） | ○ |
| `selectable` / `group` | 与画布绘制无关（命中/面板归类语义） | 同左 | 同左 |

注：GDS 图形自带的 `pathWidth`（PATH 真实线宽）是**几何语义**，不是图层显示样式；改前 GL/ShapeNode/导出各自已按自己的口径实现，本切片未改其口径，只让图层 `lineWidth` 作为**下限**叠加（不会把粗路径削细）。

## 2. 本切片改了什么

| 文件 | 变更 |
|---|---|
| `entry/src/main/ets/common/MaterialTokens.ets`（+125，纯增量） | **单一真源**：`LayerRenderStyle` + `layerRenderStyle(layer: UiLayer \| undefined)` + `dashArrayForLineStyle()`。三处消费端（GL / ShapeNode / 提示）共用同一派生，dash 映射 dashed→`[6,4]`、dotted→`[2,2]`、dotdash→`[6,2,2,2]`；`transparency`→`fillOpacity=1-t/100`，描边地板 0.85；`highlighted`→+0.25 不透明度与 +1px；`outline/hollow/cross/diagonal`→`strokeOnly`。**不拷贝图层列表**，直接读面板那批对象 |
| `entry/src/main/ets/components/workbench/LayoutCanvasView.ets` | ShapeNode 新增 `@Prop style: LayerRenderStyle` + `@Prop blink`，POLYGON/PATH/INSTANCE/RECT 全部按样式给 `fillOpacity / strokeOpacity / strokeWidth / strokeDashArray`；TEXT 给 `opacity`；`cross/diagonal` 在无图案刷的 ArkUI 上退化为只描边（注释说明，不谎称 hatch）。新增动画层闪烁：`@Watch('onLayersChange')` + `layerBlinkOpacity`（`animateTo` 循环，aboutToAppear/Disappear 同步启停，与既有 violation 闪烁同一实现语言） |
| `entry/src/main/ets/components/GlCanvas.ets` | `applyFillStyle()`：`strokeOnly` 图层把 `rectFilled/polygonFilled` 切成 `*_outline`（走已有两条着色器，真实空心）；`colorToRgba` 的 alpha 改由 `LayerRenderStyle` 提供 ⇒ transparency/highlighted 在 GPU 上生效；新增 `hasUnrenderableStyle()` + 画布上的 `GL_STYLE_LIMITS` 真话提示（GL 画不了线型/图案/动画时明确告诉用户改用回退路径或 SVG） |
| `entry/src/main/cpp/gl_renderer.{h,cpp}` | `drawBatch` 不再覆盖批次 alpha（填充用 `batch.color[3]`，描边用 `max(0.85, color[3])`，与 ArkTS 的 STROKE_OPACITY_FLOOR 同口径）；新增 `applyStrokeWidth()` + `maxSupportedLineWidth_`（`GL_ALIASED_LINE_WIDTH_RANGE` 探测，探测失败保持改前 2.0f 行为）；文件头新增**能力边界注释块**，逐条写明 GL 不能做什么、为什么 |
| `entry/src/main/cpp/image_export.h` | **导出成为样式忠实路径**：`imagedetail::dashArrayForLineStyle()/fillKindForPattern()/svgNum()/hatchPatternDef()/hatchId()` 映射表；SVG 图层组输出 `stroke-dasharray` / `stroke-width=lineWidth` / `fill-opacity`+`stroke-opacity` / `fill="none"`（hollow）/ `fill="url(#hongtu-hatch-{diag,cross}-<hex>)"` 并把 `<pattern>` 收进 `<defs>`；PNG 光栅新增 `strokePolygon()`（hollow 只描边）、`onHatchLine()`（diagonal/cross 像素级点阵，线宽随 `lineWidth`），alpha 统一走 `clamp01(1-transparency)`。数值统一 `svgNum()` 去 float 噪声（0.6500000357→`0.65`）便于稳定断言 |
| `tools/image_export_smoke.cpp` | +24 项断言（总数 38），见 §4 |

`services/HierarchyExpandService.ets` **未改**：它只产出几何批次、不含任何样式槽位，改它反而会造出第二套图层状态。

## 3. GL 路径做不到什么（且没有伪造）

1. **线型（dashed/dotted/dotdash）**：OpenGL ES 3.0 核心**没有** `glLineStipple`（桌面 GL 1.1/EXT 能力，GLES 规范未收录）。fragment shader 里做 dash 需要沿路径的弧长 varying（第二顶点属性），而 ArkTS→native 的 `RenderBatch` 契约（`entry/src/main/cpp/types/libhongtu/Index.d.ts:148`，本切片禁改）只有 `type/layerNumber/datatype/vertices/color/selected`。CPU 侧把每条边切等长 dash 段技术上可行（`xcomponent_plugin.cpp` 可扩），但没有样式输入就是死代码 ⇒ 不写。
2. **cross/diagonal 图案填充**：需纹理/图案刷或模板缓冲，同一契约无槽位 ⇒ 退化成只描边。
3. **animated 闪烁**：GL 侧是「数据变化才重传」的事件驱动，无逐帧回调 ⇒ 只做在 ArkUI 回退路径。
4. **lineWidth**：受 `GL_ALIASED_LINE_WIDTH_RANGE` 上限钳制（GLES 只保证 1px），所以 GL 上粗线仍可能观感为细线；PATH 的真实宽度靠 `buildPathRibbon()` 轮廓化条带，与 `lineWidth` 无关。

诚实出口：`MaterialTokens.GL_STYLE_LIMITS` 文案在 GL 模式下、且确有可见层带 GL 无法呈现的样式时显示在画布左上角。

## 4. 正确性守卫（新断言 24 项，总数 38）

同一份几何只改 `LayerProperties` 样式字段 ⇒ 文档/像素必须随之改变：

- SVG：实线层**不含** `stroke-dasharray`；dashed→`6,4`、dotted→`2,2`、dotdash→`6,2,2,2`；`dashed != solid`；`lineWidth=3`→`stroke-width="3"`；hollow→`fill="none"` 且 `hollow != solid`；diagonal→`<pattern id="hongtu-hatch-diag-ff0000"` + `fill="url(#…)"` + 落入 `<defs>`，且与 solid/hollow 两个文档都不同；cross→十字 pattern；`transparency=0/0.5/0.75`→`fill-opacity="1"/"0.5"/"0.25"` 并同步 `stroke-opacity`。
- PNG（`renderToBuffer` 直取像素）：实心层中心像素=图层色；hollow 中心像素=背景（13,13,20）；红像素数 `hollow < diagonal hatch < solid`；`transparency=0.5` 中心像素按 alpha 混色（既非纯红也非背景）。

未新建 `tools/layerstyle_smoke.cpp`：按 briefing 的经济性要求，扩到**已双端接线**的 `image_export_smoke.cpp`，因此 `tools/run_smoke.sh` 与 `tools/run_native_smoke.ps1` **一行未动**（避免与并发 agent 抢这两个文件）。

## 5. 验证（证据层级：仅编译 + host 冒烟，**无设备**）

- `powershell tools/run_native_smoke.ps1 -OutputRoot 'C:/Users/28384/AppData/Local/Temp/ht-smoke-K'`
  → **RC=0，`All native smoke tests passed`**（334 行 PASS，含 image_export_smoke 的 38 项）。
  单独再用 MSVC `cl /std:c++17 /W3` 编译运行 `tools/image_export_smoke.cpp`：0 warning、0 failure。
- `NATIVE_OUT=/tmp/nb_k bash tools/native_build.sh`：本切片的 TU 全部干净
  （`gl_renderer.cpp.o`、`xcomponent_plugin.cpp.o` 均编译通过；残留 4 条 `-Wunused-private-field`
  是 `gl_renderer.h` 改造前既有的着色器源码指针字段）。
  **但整包目前为红**，失败 TU 只有一个：`napi_init_v2.cpp.o`，错误行**全部**落在并发 agent 正在改的
  `entry/src/main/cpp/geometry_engine.h`（此前一次运行是 `clipper_engine.h:177/186`），
  与本切片无关，本切片也不得触碰那两个头。
- 另用 NDK clang `--target=x86_64-linux-ohos -Wall -Wextra -fsyntax-only` 单独编译包含
  `image_export.h` 的探针 TU：通过，`image_export.h` 自身 0 warning。
- `bash tools/check_portable.sh quiet`：末次运行为红，红点同样是 `geometry_engine.h`
  （`invalid operands to binary expression ('const hongtu::Vec2' …)`），非本切片引入；
  我这边最后一次改完 cpp 后的运行里，跨编译器失败项中没有任何一条指向我拥有的文件。
- ArkTS：**本环境无编译器可跑**，三处 .ets 改动只做了人工严格性自查（显式类型、无 any、无未用
  import、`Number.isFinite` 沿用仓内既有写法、@Prop 传对象沿用同文件 `@Prop shape: Shape` 先例、
  @Watch 方法名无重名、新代码不含 `null` 联合与结构体字面量越界）。**未编译验证**，
  若 hvigor 报错请按 §2 表格定位。

## 6. 剩余球（按性价比排序）

1. **导出样式的运输通道**（决定「导出图==画布」能否真成立）：`ExportLayerStyle`（Index.d.ts:303）需加 `transparency?/lineStyle?/fillStyle?/lineWidth?`，`ApplyLayerStyles`（napi_init_v2.cpp:2145）需把它们写进 `LayerProperties`，并删掉那句 `it->second.transparency = 0.35f` 硬编码；`LayoutExportService`/`Index.ets` 传 `layers` 时字段即已具备（`layersWithCounts` 已全字段透传）。导出端消费逻辑本切片已就绪并有断言。
2. **GL 线型槽位**：`RenderBatch` 加 `dashPeriod?: number`（Index.d.ts）→ `xcomponent_plugin.cpp` 可选读 → `gl_renderer` 的 LINE_STRIP 分支 CPU 切段（弧长累加即可，无需新着色器）。
3. ArkUI/GLES 的真 hatch：ArkUI 形状填充无图案刷，需位图资源 + `ImageBrush(Repeat)`（要加 media 资源，超出本切片文件所有权）。
4. `selectable` 细化（KLayout 0/1/2/3）与 `animated` 周期参数：模型仍是布尔，见 agent-H §跟进 3。
