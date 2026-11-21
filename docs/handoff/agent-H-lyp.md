# Agent H — KLayout .lyp 图层属性文件互通（gap-matrix §5）

## 交付物

| 文件 | 变更 |
|---|---|
| `entry/src/main/ets/services/LypService.ets` | 新建。手写 .lyp XML 解析/序列化（纯字符串函数，零依赖 picker/UI）+ 文件 IO（picker 读/写，复用 FileImportService/LayoutExportService 模式）+ `lypSelfCheck()` |
| `entry/src/main/ets/pages/Index.ets` | ① import LypService 导出 ② `aboutToAppear` 调 `lypSelfCheck()`（与 `canvasTransformConsistent` 同先例，失败仅 console.warn）③ 新方法 `importLypFile()/exportLypFile()/lypBaseName()`（插在 `applyLayerPresetToLayers` 之后）④ WorkbenchSidebar 调用处新增 `importLypAction/exportLypAction` 回调 |
| `entry/src/main/ets/components/workbench/WorkbenchSidebar.ets` | 「图层」Tab 搜索框下新增「⤓ 导入 .lyp」入口行（点击=导入；长按/右键菜单含导入+导出两项，导出需菜单显式触发防误写盘）。样式沿用底部快捷键入口行 + 既有 Menu/MenuItem 语言，未引入新组件 |

types.ets / constants.ets / UiStores.ets **未改**（现有模型字段已够用，见下）。

## 单一真源

导入应用走与现有 UI 完全相同的状态路径：`mergeLypIntoLayers(this.layers, entries)` 返回全新
`UiLayer[]` → `this.layers = ...` → `syncLayerVisibilityMirror()` → `refreshLayerCounts()`。
画布经 `layersForDisplay()` 拾取；未 fork 第二真源。合并逐层走
`cloneLayerWithVisible`（WorkbenchData.ets:50，全字段保真克隆）。

## 模型能表达 vs .lyp 表达（lossy 清单，`lypFeatureGaps()` 同源）

已接通（导入即生效于画布）：**颜色**（frame/fill hex/色名 → `UiLayer.color`）、**可见性**
（frame/fill properties 位 → `visible`）、**组**（`<layer-group><name>` 匹配鸿图 4 个固定
LayerGroup 枚举值时精确映射）。
已存入模型但画布尚未消费（字段存在于 types.ets:81-94，导入后随 @State 往返，渲染属 §5 动画/线型层）：
`transparency`、`lineWidth`、`lineStyle`（linetype 0-3 近似）、`fillStyle`（areastyle I/X/V 近似）、
`selectable`（select>0）、`highlighted`（bold）、`animated`（animation 开关）。

无法表达（导入时记警告并 console.warn，不伪造）：
1. brightness/contrast/saturation/hue HSV 调色（非 128 时丢弃+警告）
2. `<vas>` 区域阴影（仅往返导出保留）
3. 动画参数（周期/颜色）——只有 animated 布尔开关，无闪烁渲染
4. 组嵌套层级拍平为最内层名；任意组名 ∉ 4 固定枚举 → 归「其他」+警告
5. 复合 linetype/areastyle 参数串（"a:b:c"）→ 近似 + 警告
6. GDS 库前缀层源 "LIB""1"/0 → 忽略库名
7. `<layer-text>` 紧凑文本格式不支持（按未知元素警告）
8. 层号+datatype 未命中当前文档图层 → 不新增图层，仅警告（鸿图 layers 由文档派生）

## 解析容忍度（均有断言/烟测）

UTF-8 BOM、CRLF、`<!--注释-->`、`<![CDATA[]]>`、属性形式 `<layer source=".." frame="1"/>`、
`<fill transparent="1 50">` 元素属性、未知元素跳过、交错/未闭合标签、乱码输入
（`''`、`'not xml'`、`'<<<>>>'`、半截标签——Node 烟测全通过，不抛异常）。
导出确定性：按（组名,层号,datatype) 排序，槽位无空洞，`parse→format→parse` 逐字段稳定。

## 验证方式

- 无 ArkTS 编译器可用 → 将 LypService.ets 纯函数段（删 @kit import，注入 stub）以
  `node --experimental-strip-types` 实际执行 `lypSelfCheck()`：**PASS**。断言：
  噪声样例解析出 3 层、1/0 帧色 #c80000/填充色 #ff0000/透明 50/dashed/lw2/select2/组互连层、
  嵌套组拍平 M1、属性形式 44/0、export→import 逐字段一致、UiLayer 往返一致、
  未命中条目 3 条警告齐全。
- 真机侧：启动时 aboutToAppear 自检失败仅 console.warn（同 canvasTransformConsistent 先例）。
- native 构建：未触碰 cpp；NATIVE_OUT=/tmp/nb_h tools/native_build.sh 结果见交接当次运行日志。

## 跟进项（其他 agent 的球）

1. **画布消费可选样式**（LayoutCanvasView agent）：layersForDisplay()/layersWithCounts
   （Index.ets:1445-1459）重建 UiLayer 时**丢弃全部可选字段**（lineStyle/fillStyle/transparency/
   lineWidth/...）。需在该函数把可选字段透传（或整体改用 cloneLayerWithVisible），
   否则 .lyp 导入的透明度/线型到不了画布——这是 §5 线型/填充渲染任务的天然一部分。
2. Inspector「图层显示设置」若加 per-layer 透明度/线型编辑控件，可直接读写同一批
   UiLayer 可选字段（LypService 已保证往返）。
3. `<select>` 完整语义（KLayout 0=不可选/1=框/2=填充/3=两者）vs 鸿图仅布尔 selectable；
   细化时从 LypLayerEntry.selectMode 接。
4. 若要「导入时文档缺层自动建层」：mergeLypIntoLayers 预留了未命中警告位，改成 push 新
   UiLayer 即可（需与 layersWithCounts 的文档派生层去重逻辑协调）。
5. WorkbenchInspector.ets 未挂载 .lyp 入口（仅侧栏）；如 Inspector 成为主图层面板可复制
   同样的两个回调。
