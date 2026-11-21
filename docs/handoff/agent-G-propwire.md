# Agent G — 属性贯通：元素/结构/库级属性跨 NAPI + ArkTS 模型存活到写盘

日期：2026-09-19 切片：`agent-F-props.md` §5（ArkTS/NAPI 接线）+ gap matrix §2 `PROPATTR/PROPVALUE`
前置：F 已在 native 引擎闭环（读→模型→写→重解析）。本切片只补 **UI 的 edit→save 通路**。
状态：**四层已改完，两条验证均绿**（host 冒烟 + NDK 链接）；ArkTS 由中央编译，本文件 §4 列出**必须**由中央落地的 3 处禁改文件改动。

---

## 1. 五跳链路（改前 file:line → 现状）

| # | 跳 | 改前位置 | 改前行为 | 现状 |
|---|----|----------|----------|------|
| 1 | native 解析结果 → JS 对象 | `napi_init_v2.cpp:138-228` `CreateFullParseResult`（shapes 198-225 / cells 156-173 / 无库级） | 只发几何字段，`LayoutShape::properties`、`CellInfo::properties`、`libProperties` 全部不进 JS | **已闭**：图元 `properties`、结构 `properties`、库级 `libProperties`（均「空则省略字段」） |
| 1b | 解析结果 → 文档模型镜像 | `napi_init_v2.cpp:231-300` `PopulateLayoutFromParseResult` | `SceneShape::properties` / `Cell::properties` 恒空（F §5.1） | **已闭**（F §5.1 原样落地，含 dtype 6 剥尾 NUL） |
| 2 | 类型声明 | `types/libhongtu/Index.d.ts` `NativeShape:34-48` / `CellInfo:18-25` / `GdsiiResult:51-86` | 无属性字段 | **已闭**：新增 `LayoutPropRecord` + 三处可选字段 + `writeGdsiiDocument` 文档串 |
| 3 | ArkTS 模型 | `NativeHongTuService.ets:75-135`（逐字段**原样透传** native 结果，无需改）→ `GdsiiData.ets:107-151` `nativeShapesToShapes` / `:170-259` `parseResultToDocument` | 逐字段重建 `Shape`/`CellModel`，属性无处可去 | **已闭**：`Shape.properties?`、`CellModel.properties?`、`LayoutDocument.libProperties?` + `normalizePropRecords()` 守卫 |
| 4 | 导出构造文档 | `LayoutExportService.ets:488-529` `buildNativeDocument` | 只发 type/layer/points/… | **已闭**：`shapes[].properties`、`cellProperties[][]`、`libProperties`（`propsToWire()`） |
| 5 | JS 文档 → native 写盘 | `napi_init_v2.cpp:935-1029` `NapiWriteGdsiiDocument` | 只读 12 个几何/元字段，属性无处可回 | **已闭**：三处可选字段回读进 `LayoutShape`/`CellInfo`/`GdsiiParseResult`，仍走同一个 `WriteGdsii` |
| 6 | ArkTS 回退字节流（native 不可用/写失败时） | `LayoutExportService.ets:795-907` `writeRect/writePolygon/writePath/writeText/writeInstance` + 两个 builder | 从不写 PROPATTR/PROPVALUE | **已闭**：`writePropList()` 在 ENDEL 前 / STRNAME 后 / UNITS 后写出，与 native 解码同语义 |

入口确认：`pages/Index.ets:2204-2246` `applyParsedResult` 用 `nativeShapesToShapes(parsed.shapes)`→`editService.setShapes`；
`pages/Index.ets:3466-3479` `saveCurrentLayout` 用 `editService.getShapes()`→`buildNativeDocument`。
即「打开→改一个矩形→保存」的图元级属性现在**全程有路**。

## 2. 线上格式（ADDITIVE，全部可选）

```ts
LayoutPropRecord = { attr: number; dtype: number; name: string; value: string }
```
- 出站：`result.shapes[].properties?`、`result.cells[].properties?`、`result.libProperties?`；
  **空属性 ⇒ 整个键省略**（不发空数组），旧输出对象与今日逐键一致。
- 入站（`writeGdsiiDocument`）：`shapes[].properties?`、`cellProperties?: LayoutPropRecord[][]`（与 `cellNames` 同索引）、`libProperties?`。旧文档不含这些键 ⇒ 走原路径，零行为变化（`roundtrip_smoke` 断言 3 of `legacyDocChecks` 逐字节核对流里无 0x2D/0x2E 记录）。
- `value` 载体（`napi_init_v2.cpp` 的 `EncodePropertyWire`/`DecodePropertyWire`，ArkTS 回退路径 `writePropList` 同语义）：
  - `dtype 6`（ASCII）→ 原文，**已剥 GDS 偶数长度尾 NUL**；写盘时由 writer 重新补齐 ⇒ 重解析逐字节复原，反复保存不累积填充。
  - `dtype 0` → 恒空串（写为 4 字节空头 PROPVALUE）。
  - `dtype 2/3/4/5` → 值段若全为可见 ASCII 则原文；含二进制字节则 `"#"`+大写十六进制（可逆，逐字节复原）。
  - `dtype 7`（规范外保留码，仅作**载体标记**）→ ASCII 槽位里装着非文本字节；回读还原为 dtype 6 + 十六进制解码。
  - 解码规则**只看 dtype，不看内容** ⇒ `dtype 6` 的值 `"#FF00"`（颜色串）永不被误解码。
- `name` 只有 OASIS 有值（GDSII 按数字属性码索引）。

## 3. 敌意输入守卫（与 parser 同口径）

- 每归属者 **64 条**（`kMaxPropsPerOwnerWire` == reader `kMaxPropsPerOwner` == ArkTS `MAX_PROPS_PER_OWNER`），超出截断。
- 单条值段 > 65534 字节 → 忽略该条（写出端本就写不下）；一次调用共享 **32MB** 总字节预算。
- 条目非对象 / `attr`、`dtype` 不是 number / 自称十六进制却解不出 / 属性码越 int16 → **逐条忽略**，不抛、不错位；几何与已读属性不受影响。
- 全部新代码在既有 `NapiSafe<>` 包装内（`napi_init_v2.cpp:2137-2144` 注册表未动），C++ 异常不穿越边界；`GetObjNumberField` 先 `napi_typeof` 再取值，避免对非数值调 `napi_get_value_int32` 触发挂起的 JS 异常。
- 三层容量一致：`normalizePropRecords`（ArkTS）→ `ReadPropertyArrayList`（NAPI）→ reader 钳制，不会某层静默截而另一层不截。

## 4. 必须由中央落地（本切片禁改文件）

1. **`services/EditService.ets:174-199` `cloneShape` 丢 `properties`**（最高优先，会真丢数据）。
   撤销/重做的 **create/delete**（`restored`@1098、`recreated`@1158）、粘贴/复制（`cloned`@469）都用它重建图元，
   克隆出来的 `Shape` 没有 properties ⇒ 这些图形属性在保存时消失。改法（照 `text` 那行的写法）：
   ```ts
   // EditService.ets cloneShape 末尾（return copy 之前）
   if (s.properties !== undefined) {
     copy.properties = normalizePropRecords(s.properties);   // 从 '../models/GdsiiData' 引入
   }
   ```
   （用 `normalizePropRecords` 而非直接赋引用，避免撤销栈与实图共用一个数组。）
2. **`services/AdvancedEditService.ets:1031-1060` `cloneShape`**：同样补上（布尔/打平/实例化会经它）。
   `services/VerifyService.ets:477` 的 `cloneShape` 只服务 diff 展示，可选。
3. **`pages/Index.ets`**：结构级 + 库级属性的入参与传参（各 2 行；`ExportLayoutInput` 已把它们做成可选字段，不加也不会编译失败，只是这两级属性仍会在 dirty 保存时丢）。
   ```ts
   // 成员声明处
   private docLibProperties: LayoutPropRecord[] = [];
   private docCellProperties: LayoutPropRecord[][] = [];
   // applyParsedResult 内，紧跟 2215-2218 的 cellNames 循环
   this.docLibProperties = parsed.libProperties !== undefined ? parsed.libProperties : [];
   const cellProps: LayoutPropRecord[][] = [];
   for (let i = 0; i < parsed.cells.length; i++) {
     cellProps.push(parsed.cells[i].properties !== undefined ? parsed.cells[i].properties : []);
   }
   this.docCellProperties = cellProps;
   // saveCurrentLayout 的 exportGdsWithPicker({...}) 里（约 3477 行）
   cellProperties: this.docCellProperties,
   libProperties: this.docLibProperties,
   ```
   （`import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';`）
4. 文档口径：`README.md` 的「35 个 NAPI 导出函数」不变；§2 属性行可从「值不保留」升为「读取+写出+UI 通路已接线，属性面板未做」；
   gap matrix `docs/roadmaps/klayout-feature-gap-matrix.md:35` 文案同样待中央更新。
5. `check_all.sh` 的 `[PASS]` 计数：**本切片未新增 `[PASS]` 行**（`roundtrip_smoke` 只打印一行 `roundtrip_smoke PASS ...`，不计入），README 的 287 仍成立。

## 5. 新增断言（tools/roundtrip_smoke.cpp，+14）

| 组 | 条数 | 覆盖 |
|----|------|------|
| `docPropChecks`（退出码 22） | **11** | 手工构造「JS 文档读出的形状」（cellNames/cellProperties/shapes[].properties/libProperties）→ **同一个** `WriteGdsii` → 重解析：写出成功、可重解析、库级保住、结构名表不受影响、结构属性逐字节往返、无属性结构仍空、SREF（int32 二进制值段）往返、PATH 双属性顺序 + real8 逐字节、dtype 0 仍成对复现、无属性图元不被串位污染、属性不造假图元 |
| `legacyDocChecks`（退出码 23） | **3** | 旧调用方形态（文档里根本没有 properties 键）→ 写出成功 / 三层属性皆空 / **字节流里 0 条 0x2D·0x2E 记录** |

**没有 host 接缝的那半程**：`napi_init_v2.cpp` 的 JS↔C++ 编解码（`CreatePropertyArray`/`ReadPropertyArrayList`）
不参与 host 冒烟构建（该文件 `#include <napi/native_api.h>`，host 无此头，见 README 门禁表），
因此**未**为其伪造测试；它由 NDK 编译层（`native_build.sh`）+ ArkTS 类型声明 + 上表的结构半程断言共同夹住。
同理 ArkTS 回退字节流（`writePropList`）只有 ArkTS 编译保证，无运行期断言。
若要真测这两处，需把 `PropRecord` 编解码从 `napi_init_v2.cpp` 抽到一个不含 napi 头的纯函数头（例如新加 `cpp/prop_wire.h`，
本切片无权新建文件），再由 `roundtrip_smoke` 断言 `decode(encode(x)) == x`。这是最有价值的后续 30 行。

## 6. 用户现在看得见 / 看不见

**看得见**：打开带属性的 GDS/OASIS → 移动/缩放/改顶点/旋转任意图形 → 保存（native document 与 ArkTS 回退两条路都走）→ 重开，
**图元级 PROPATTR/PROPVALUE 逐字节仍在**（此前这一步会静默删掉全版图属性）。
**看不见**：任何属性面板/检视器 UI（本切片明确不做），属性值也不会出现在状态栏或导出报告里。

## 7. 仍然会丢（直言）

1. **删除后撤销、粘贴/阵列复制出来的图形**：属性被 `EditService/AdvancedEditService.cloneShape` 抹掉（§4.1、§4.2 落地即闭合）。
2. **结构级 + 库级属性**：通路已建好、两条写盘路径都会写，但 `Index.ets` 尚未传 `cellProperties`/`libProperties`（§4.3）⇒ dirty 保存仍丢这两级；未编辑的快照路径（`writeGdsii`/`writeOasis`）不受影响。
3. **`expandHierarchy` / RenderBatch 的图元不带属性**：`SceneProperty` 无 `dtype` 字段（`scene_graph.h` 本切片禁改），无法忠实上线；画布/LOD/DRC/LVS 路径看不到属性。要补需先给 `SceneProperty` 加 `uint8_t dtype`。
4. **实例（CellInstance）在文档模型里没有属性字段**：`g_layout` 里 SREF/AREF 的属性缺失（F 同意取舍）；快照与 document 保存路径不受影响。
5. 无解析快照时的兜底 `LayoutToParseResult`：`SceneProperty`→`LayoutProperty` 一律记 dtype 6，二进制值的 dtype 退化。
6. F §8 原样保留：NODE 属性归属变粗、GDS↔OASIS 跨格式归一化（P39 元素属性无名、GDS 无法表达名字）、OASIS 值统一为 kind 10 文本、CELLPROPERTY/XNAME 不解析、CIF/DXF/LEF-DEF 无属性。
7. **真机 open→save→reopen 仍未签核**（本仓库统一不做设备验证）。

## 8. 验证输出尾部

```
roundtrip_smoke PASS write_cells=2 write_shapes=4 reopen_shapes=4 props=1+1+1+2+1 prop_pairs=9+8+11+3 bytes=482
All native smoke tests passed.
                                                        # powershell -File tools/run_native_smoke.ps1 -OutputRoot 'C:/Users/28384/AppData/Local/Temp/ht-smoke-G'
[8/8] Linking CXX shared library obj\libhongtu.so
== native build artifact: /tmp/nb_g/obj/libhongtu.so ==   # NATIVE_OUT=/tmp/nb_g bash tools/native_build.sh
```
`napi_init_v2.cpp` 重编译后仅剩两条**既有**告警（`geometry_engine.h:287`、`pcell_framework.h:698` 的 unused variable），本切片零新增告警。

> 复跑提醒：上面两条命令是 10:40（host 全套）与 10:44（NDK 链接）跑的，均绿。
> 10:43–10:49 另一代理正在改 `entry/src/main/cpp/lvs_engine.h` 与 `tools/lvs_smoke.cpp`（非本切片所有权、且不参与任何本切片文件的编译），
> 期间 `run_native_smoke.ps1` 会在 `lvs_smoke` 处中断（退出码在 2 与 1 之间跳动 = 源码正在被改），导致后续 `roundtrip_smoke` 不再被跑到。
> 本切片的二进制单独复跑仍绿：`roundtrip/roundtrip_smoke.exe roundtrip_smoke` → `prop_pairs=9+8+11+3`，exit=0。
> 中央合并时请按 LVS 代理修好后的**全套**结果记账。
