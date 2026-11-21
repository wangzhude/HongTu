# Agent F — 属性保留与写回（GDSII PROPATTR/PROPVALUE · OASIS PROPERTY）

日期：2026-09-19 切片：gap matrix §2 `PROPATTR/PROPVALUE`（P2）+ §7 `open→save→reopen 黄金测试`
状态：**native 层已闭环**（读→模型→写→重解析），两层验证均绿；**ArkTS/NAPI 侧未接线**（见 §5，需中央落地）

---

## 1. 值此前在哪里被丢弃（改前 file:line）

| 位置 | 行为 |
|------|------|
| `entry/src/main/cpp/gdsii_reader.h:52-53` | `BOXTYPE=0x2D / BOX=0x2E` —— **与规范 PROPATTR/PROPVALUE 记录码正面冲突**。真实 GDS 的属性对被读成「BOXTYPE 设 datatype」+「BOX 元素起点」（造出假图元、图层统计错位），这就是 §2 那行「正确跳过不错位」在 GDS 侧其实不成立的原因 |
| `gdsii_reader.cpp:638-641`（改前） | `PROPATTR(0x2D)/PROPVALUE(0x2E)` 没有任何 case，全部落 `default: skipRecord()` → 值被丢弃 |
| `gdsii_writer.cpp:226-306`（改前） | `writeBoundary/writePath/writeText/writeInstance` 从 XY/STRING 直接跳到 ENDEL，从不写属性；结构级/库级同理 |
| `oasis_reader.cpp:1443-1476`（改前） | `parseProperty()` 把 PROPNAME refnum、内联名、每个值全部 `(void)` 丢弃（注释「值解析但不保留」）；`oasis_reader.h:25,32` 明文声明不保留 |
| `oasis_writer.cpp` | 记录 28 从不写出 |
| `scene_graph.h:61` | `SceneShape::properties` 是**死字段**：全仓零引用（无 reader/NAPI/writer 填充） |

## 2. 模型与代价（ADDITIVE）

```cpp
struct LayoutProperty {         // gdsii_reader.h（GDSII/OASIS reader+writer 共用）
    int16_t attr;   // GDSII PROPATTR 码；0 = 孤立值（无前置 PROPATTR）
    uint8_t dtype;  // GDSII: PROPVALUE 记录数据类型；OASIS: 原始 P39 kind（诊断/UI 用）
    std::string value;  // GDSII: PROPVALUE 数据段原始字节；OASIS: 解码后的文本值
    std::string name;   // OASIS PROPNAME；GDSII 恒空
};
```
挂载点：`LayoutShape::properties`（元素级）、`CellInfo::properties`（结构/Cell 级）、
`GdsiiParseResult::libProperties`（库/数据库级）。
`scene_graph.h`：新增 `SceneProperty{attr,name,value}` + `findProperty()`（按 attr / 按名两个重载）；
`SceneShape::properties` 由死字段 `vector<pair<int,string>>` 换型为 `vector<SceneProperty>`
（`std::vector` 尺寸不变 → **SceneShape/Cell 的字段布局与大小零变化**）；`Cell::properties` 追加在末尾，
`hierarchy_smoke.cpp` 的 9 元位置化聚合初始化仍然合法（已编译验证）。

代价：只在尾部加 vector 成员，热路径（DRC / `flattenRecursive` / `InstanceTransform::toMatrix` /
`ViewProjection`）**一行未动**；无属性时只是一个空 vector，不新增循环、不参与 bbox/三角化/展开。
（未给 `CellInstance` 加属性：实例在读取模型里就是带属性的 `LayoutShape`，避免百万实例每个 +24B。）

## 3. 写出的记录编码

**GDSII**（规范码：`NODE 0x2C / PROPATTR 0x2D / PROPVALUE 0x2E / BOX 0x2F / BOXTYPE 0x30`，已按规范纠正）
- 每条属性 = `PROPATTR(0x2D, dt=2, 属性码 int16)` **紧邻** `PROPVALUE(0x2E, 原 dtype, 原字节)`
- 位置：元素内 → 坐标/STRING 记录**之后**、ENDEL **之前**（BOUNDARY/PATH/TEXT/SREF/AREF 全覆盖）；
  结构级 → STRNAME 之后、首个元素之前；库级 → UNITS 之后、首个 BGNSTR 之前
- 值段逐字节复现（含 GDS 偶数长度补 0、8 字节 real 编码）；非法 dtype 归一为 ASCII、
  dtype 0 写 4 字节空头记录、超 16 位记录长的单条属性丢弃但保住几何

**OASIS（SEMI P39，记录 28）**
- 元素属性：`info = 值个数<<4`（C=0，规范上无名），紧跟所属元素记录
- 一般属性：`info = 0x04 | 值个数<<4`（C=1，N=0 → 名字内联），Cell 级紧跟 CELL 记录、
  数据库级写在名称表之后首个 CELL 之前；同名多值合并进一条记录
- 值一律 `kind 10 + 内联 a-string`（长度前缀自描述，绝不与后续记录打架）；
  个数 >14 走 `bits=15 + 显式 unsigned-integer 个数`（往返测试已覆盖 16 值）

## 4. 守卫的敌意输入（`tools/parser_robustness_smoke.cpp`）

GDSII：无数据段的坏 PROPATTR、无前置 PROPATTR 的孤立 PROPVALUE（attr=0，值仍留、流不错位）、
ENDSTR 之后的越位属性对、EOF 落在 PROPVALUE 中间的截断、声明长度 0xFFFF 的荒谬值段
（读到 EOF 即止，不越界不伪元素）、**5000 条属性对**（钳制到 64 条/归属者 + 32MB 总字节预算，图元与解析结果不受影响）。
OASIS：值个数上限（256）→ `PROPERTY 值个数超限` 优雅失败；无所属元素的孤立元素属性 → 安全丢弃且后续几何正常解析、
数据库级一般属性仍保住名与值；`beginCell()` 关闭回贴窗口，属性不会跨 Cell 泄漏。
记录属性上限常量：GDS `kMaxPropsPerOwner=64 / kMaxPropBytes=32MB`；OASIS `kMaxPropertyValues=256 / kMaxPropsPerOwner=64`。

## 5. 需要中央落地的 ArkTS / NAPI 改动（我未碰 `napi_init_v2.cpp`、`Index.d.ts`、`ets/`）

1. `napi_init_v2.cpp` 里 `LayoutShape → SceneShape` 的映射处补一段（每个图元仅在有属性时分配）：
   ```cpp
   for (const auto& lp : ls.properties) {
       hongtu::SceneProperty sp;
       sp.attr = lp.attr; sp.name = lp.name;
       // dtype 6（ASCII）需剥掉 GDS 偶数填充：去掉尾部 '\0' 再给 UI 显示
       sp.value = (lp.dtype == 6) ? trimTrailingNul(lp.value) : lp.value;
       ss.properties.push_back(std::move(sp));
   }
   ```
   Cell 侧同理：`CellInfo::properties → Cell::properties`；库级 `GdsiiParseResult::libProperties`。
2. `types/libhongtu/Index.d.ts`：shape/cell 记录类型加可选字段
   `properties?: Array<{ attr: number; name: string; value: string }>`；
   若要给属性面板用，另加 `getShapeProperties(shapeId: number): Array<{...}>` /
   `setShapeProperty(shapeId, attr, value)`（setter 需要 native 侧写回 `LayoutShape::properties`）。
3. **任何在 ArkTS 侧重建 `GdsiiParseResult` 的编辑/导出路径必须把 `properties` 带过去**，
   否则「编辑后保存」仍会丢属性（native 直写路径 `writeGdsii/writeOasis` 已保真）。

## 6. 新增断言（都接在既有 smoke 二进制里，未动 runner 脚本）

| 文件 | 新增属性断言 |
|------|--------------|
| `tools/roundtrip_smoke.cpp` | **+17**（首解析读侧 9：库/结构/SREF/PATH 双属性/BOUNDARY 无数据属性/污染对照；重解析等值 8：条数+attr+dtype+原始字节逐项相等、图元数不因 0x2E 变多） |
| `tools/gdsii_smoke.cpp` | **+5**（结构+NODE 属性、SREF 未被串位污染、AREF 展开 6 副本共享属性、孤立值 attr=0、属性不跨结构泄漏） |
| `tools/parser_robustness_smoke.cpp` | **+6**（§4 全部敌意例；GDS 10 例 / OASIS 10 例，退出码风格不变） |
| `tools/oasis_smoke.cpp` | **+5**（元素属性 2 值、邻接图形不受污染、Cell 一般属性名+值、PROPNAME/PROPSTRING refnum 解析出名与值、CHILD 无泄漏） |
| `tools/oasis_roundtrip_smoke.cpp` | **+9**（库级/Cell 级往返、矩形 2 值、多边形、16 值显式个数、实例属性、无属性 text/邻接实例不被污染） |

合计 **+42** 条属性断言。未新增 smoke 二进制、未改 `run_smoke.sh` / `run_native_smoke.ps1`。

## 7. 验证输出尾部

```
roundtrip_smoke PASS write_cells=2 write_shapes=4 reopen_shapes=4 props=1+1+1+2+1 prop_pairs=9+8 bytes=482
All native smoke tests passed.
...
  [PASS] 16 值元素属性（info 15 + 显式个数）往返 got=16
  [PASS] 无属性文本图元不被污染
  [PASS] 直角实例（PLACEMENT 17）元素属性往返
  [PASS] 相邻实例不被串位污染
  [PASS] 篡改字节后解析失败（CRC32 或结构校验兜住）
OASIS roundtrip smoke passed: 7 shapes, CRC verified
  [PASS] OASIS 巨量属性值：上限报错优雅失败 got=PROPERTY 值个数超限 1000000000
  [PASS] OASIS 无所属元素的属性安全丢弃；数据库级一般属性保住值
parser robustness smoke: ALL PASS
coordinate smoke passed (49 assertions)          # 变换/坐标口径未被触碰，仍绿
== native build artifact: /tmp/nb_f/obj/libhongtu.so ==   # NATIVE_OUT=/tmp/nb_f bash tools/native_build.sh
```

## 8. 有意留下的缺口（不在本切片，需后续/签核）

- **NODE 几何不解析**：NODE(0x2C) 元素本身不产生图元，其属性回贴到所属结构（值不丢，归属变粗）。
  要做真 NODE 需先实现 NODE 元素模型。
- **跨格式保存的归一化损失**（已按格式语义取舍）：
  GDSII→OASIS 时元素属性只能无名（P39 语义），PROPATTR 数字码丢失；GDS 结构属性若无 `name`，
  写 OASIS 一般属性时被跳过（P39 要求有名）。OASIS→GDSII 时 `name` 无法用数字属性码表达。
- **OASIS 值的类型编码归一**：读取保留原始 kind 于 `dtype`，但再存盘统一为 kind 10 文本
  （数值用 `%.17g`，double 可无损回转）；不重建 PROPNAME/PROPSTRING 表（名字一律内联）。
- **OASIS `CELLPROPERTY` 一类扩展记录 / XNAME·XELEMENT 属性**：现有 reader 不解析这些记录，故无从保留。
- **CIF/DXF/LEF-DEF 不臆造属性支持**（按任务边界）。
- **属性编辑 UI / 属性面板、`.lyp` 关联、真机 open→save→reopen 设备签核**：未做。
- gap matrix §2 第 35 行与 §7 第 91 行的文案需中央更新（我无 `docs/roadmaps/*` 写权限）。
