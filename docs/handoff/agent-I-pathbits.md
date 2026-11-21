# Agent I — GDSII PATH/AREA 的 XY「X 字塞 presentation 标志位」判定 + 修复方案

日期：2026-09-19　切片：`gdsii_reader.cpp` case XY 上那条「规范符合性存疑（未验证，勿凭猜改）」注释
状态：**问题已定案（结论与注释里的假设相反）**；探针已写好并**在本机真跑过**；修复 diff 只写不落地（按约定：reader/writer 由中央集成方在其它 agent 落地后再改）

---

## 0. 一句话结论

**XY 记录的 X 字没有任何标志位可剥。当前 `readInt32` + `static_cast<double>(x) * coordinateScaleNm` 是正确的，加掩码/移位反而会把真实几何搬走。**
真正的缺陷是：reader **完全没有 `PATHTYPE [0x21]` / `BGNEXTN [0x30]` / `ENDEXTN [0x31]` 的 case**，它们落进 `default: skipRecord()`（`gdsii_reader.cpp:743`），且 `LayoutShape` 根本没有 `pathType` 字段 —— 所以 `SceneShape::pathType` 永远是 0（flush），端头/延伸在真实文件上全部丢失。写出侧同理从不发 PATHTYPE，故自家 round-trip 结构上看不见这个洞。

GDSII 规范里**不存在 AREA 元素、不存在 extrusion**（Release 5.1 / 6.0 全文零命中，见 §1 行号），也不存在「首点/中间点取位不同」这回事。

---

## 1. 证据链（我实际读到的原文，按要求的优先级）

**P0 — Calma GDSII Stream Format Manual（一手规范）**

| 出处 | 原文/结论 |
|---|---|
| Release 6.0（Feb 1987）**record 16 XY [1003]，p.4-6** | "Contains an array of XY coordinates in database units. **Each X or Y coordinate is four bytes long.** … A path must have at least 2, and a boundary at least 4 pairs of coordinates." 全段无任何 flag/presentation 字句 |
| 同文档 **§Data Type Description, p.3-2** | "4-byte integer = 2 word **2s-complement** representation. The range of four-byte signed integers is −2,147,483,648 to 2,147,483,647." → 坐标占满 32 位，不是 16 位也不是 24 位子域 |
| 同文档 **record 9 PATH [0900]，p.4-4** | "No Data Present — Marks the beginning of a path element."（PATH 记录本身不带数据） |
| 同文档 **§BNF p.5-2** | `<path> ::= PATH [ELFLAGS] [PLEX] LAYER DATATYPE `**`[PATHTYPE] [WIDTH] [BGNEXTN] [ENDEXTN]`**` XY` |
| 同文档 **record 33 PATHTYPE [2102]，p.4-12/4-13 + Figure 4-5** | "0 for **square-ended paths that end flush** with their endpoints, 1 for **round-ended** paths, and 2 for **square-ended paths that extend a half-width** beyond their endpoints. Pathtype 4 (CustomPlus only) signifies a path with **variable square-end extensions** (see records 48 and 49). If not specified, a Pathtype of **0 is assumed**." 另注 "Path type 1 is a view feature only" |
| 同文档 **records 48/49 BGNEXTN [3003] / ENDEXTN [3103]，p.4-17** | "Applies to Pathtype 4 … extension of a path outline beyond the **first** / **last** point of the path. Value can be negative." |
| 同文档 **record 23 PRESENTATION [1701]，p.4-8 + Figure 4-3** | 规范里**唯一**叫 "presentation" 的位域：TEXT 的字库/对齐，**独立记录、1 个 bit-array 字**，bits 10-15 有意义，"Bits 0 through 9 are reserved for future use and must be cleared" → 这是把「presentation 位」和 XY 联系起来的混淆源头 |
| 全文 grep | `AREA`、`extrusion`、`stage`、`taper` 在 **Release 6.0 与 Release 5.1（Aug 1984）文本层中零命中**（我用 pymupdf 解出全文后 grep；5.1 的 `<path>::= PATH [ELFLAGS][PLEX] LAYER DATATYPE [PATHTYPE][WIDTH][BGNEXTN][ENDEXTN] XY`，p.2 亦无 XY 塞位） |

（PDF 原文：`bitsavers.informatik.uni-stuttgart.de/pdf/calma/GDS_II_Stream_Format_Manual_6.0_Feb87.pdf`、`…_5.1_Aug84.pdf`；页码为文档自印页号。）

**P1 — KLayout 的 GDSII importer**（要求里点名的 `gsiGDSII.cc` **在 v0.28.17 与 master 的 git tree 里都不存在**；我用 GitHub trees API 全仓核对过，现行/近 8 年的 importer 都在 gds2 插件里，下面即为该文件）

| 位置 | 事实 |
|---|---|
| `src/plugins/streamers/gds2/db_plugin/dbGDS2ReaderBase.cc:137-143` `pt_conv()` | `int x = (p.x[0]<<24)\|(p.x[1]<<16)\|(p.x[2]<<8)\|p.x[3];` —— **整 32 位有符号，零掩码**，PATH/BOUNDARY/TEXT/SREF 共用同一函数（`read_boundary` 538-686、`read_path` 688-810） |
| 同文件 `read_path():706-745` | `if (rec_id == sPATHTYPE) { type = get_ushort(); }`、`sBGNEXTN`/`sENDEXTN` 取 `bgn_ext`/`end_ext`；`type∉{0,1,2,4}` → 告警 "Unsupported PATHTYPE" 并归 0；`type==1\|\|2` 且无 BGNEXTN 时 `bgn_ext = end_ext = w/2` |
| 同文件 `:788` | `path.width(w); path.extensions(bgn_ext, end_ext); path.round(type == 1);` |
| `dbGDS2WriterBase.cc:781-856` `write_path()` | 写 `sPATH/sLAYER/sDATATYPE` → `write_record(sPATHTYPE); write_short(type)`（type 由 round/extensions 反推 0/1/2/4）→ `sWIDTH` →（仅 type==4）`sBGNEXTN`/`sENDEXTN` → `write_record(sXY); write_int(x); write_int(y);` **XY 一律裸坐标** |
| `dbGDS2.h:40-86` | 记录码：`sPATH=0x0900 sXY=0x1003 sPATHTYPE=0x2102 sBGNEXTN=0x3003 sENDEXTN=0x3103 sBOUNDARY=0x0800 sBOX=0x2d00 sBOXTYPE=0x2e02 sPROPATTR=0x2b02 sPROPVALUE=0x2c06 sPLEX=0x2f03 sNODE=0x1500` |
| Changelog 全文 | 无 `extrusion`/`AREA`/`PATHTYPE` 任何一条 |

**P2 — gdstk**（要求里的 `src/gds.c` 已在重构后变成 `src/library.cpp` + `include/gdstk/gdsii.hpp`）

| 位置 | 事实 |
|---|---|
| `src/library.cpp:1143-1171`（`case GdsiiRecord::XY`） | 裸 `int32_t` → `factor * data32[i]`，**PATH 首点用 `data32[0]/data32[1]` 原值**；无剥位、无首点/中间点分支 |
| `src/library.cpp:1297-1313`（`case GdsiiRecord::PATHTYPE`） | 0→`EndType::Flush`，1→`Round`，2→`HalfWidth`，`default`→`Extended` |
| `src/library.cpp:1329-1334` | `BGNEXTN`/`ENDEXTN` → `end_extensions.u/v` |
| `src/flexpath.cpp:804-833, 876-896`（写出） | `buffer1[] = {6, 0x2102, end_type, 8, 0x0F03}` —— Round→1、HalfWidth→2、Extended→4（+`0x3003`/`0x3103`）、其余→0；随后 `uint16_t buffer_pts[] = {…, 0x1003}` 写**裸 int32 坐标** |
| `include/gdstk/gdsii.hpp:19-82` | `XY=0x10 PATHTYPE=0x21 BGNEXTN=0x30 ENDEXTN=0x31 NODE=0x15 PROPATTR=0x2B PROPVALUE=0x2C BOX=0x2D BOXTYPE=0x2E PLEX=0x2F` |

**P3 — 其它实现/文档（交叉印证，无一行支持 XY 塞位）**

- python-gdsii（fork `eugmes/python-gdsii` `gdsii/elements.py:175-205`）：`Path = PATH [ELFLAGS][PLEX] LAYER DATATYPE [PATHTYPE][WIDTH][BGNEXTN][ENDEXTN] XY`，`path_type/width/bgn_extn/end_extn` 是独立字段。
- TU Wien 论文附录 B.2（引 Calma 原文）：PATHTYPE/WIDTH 是 "Prior to the XY record" 的**可选记录**。
- Artwork Conversion《All About Calma's GDSII Stream Format》p.4（Cyril Jefferies 公司的 Steve DiBartolomeo，即当年转写规范的人）："The **path record has a flag**… 0=Flush 1=Half Round Extension 2=Half Width Extension 4=Custom Extension"。
- klaasholwerda GDSII BNF 页、nanyte GDSII 记录表（PATHTYPE 33/0x21、PROPATTR 43/0x2B、PROPVALUE 44/0x2C）同口径。

**冲突/未知**：见 §7。没有任何一手来源支持「PATH/AREA 的 X 字高位是 flag」，也没有任何一家实现剥位；故该假设**判为不成立**。

---

## 2. 逐条回答 (a)–(d)

**(a) 首点 vs 中间点怎么取位？**
两者**完全相同**：X/Y 各是整个 4 字节 2 补码有符号数（Manual 6.0 p.4-6 + p.3-2；`pt_conv()`；gdstk `case XY`）。既不是「符号扩展低 16 位」也不是「24 位域 + 上方 flag」，也**没有**「中间点 bits 0-7 变成 mag/stage 码」这回事——「后续点」概念只存在于 XY 的**增量编码变体**（GDS 家族里没有；OASIS P39 才有 delta），与本条无关。
危险提示：合法坐标本身就会点亮假说里的 flag 位——`x=1000=0x3E8` 的 bit8=1、bits9-11=1；若真按假说 A 剥掉高 16 位，`x=1,000,000 → 16,960`（DBU，1 nm DBU 下即 983 µm 的位移）。这正是「宁可 UNKNOWN 也不搬顶点」要防的事。

**(b) path/boundary type 的位序/极性？**
无位序可言：**端型是独立记录 PATHTYPE [0x21]，2 字节有符号整数**，值域 0/1/2/4（3 未定义；>4 各家按 0 处理：KLayout `read_path():712-716` 告警后归 0，gdstk `default: Extended`）。
映射到我们的模型（`scene_graph.h:88` `pathType`，`triangulator.h:293-302` capMode）：

| GDSII PATHTYPE | 规范语义 | 我们的 `SceneShape::pathType` | 备注 |
|---|---|---|---|
| 缺省 | flush | 0 | 规范 "If not specified, a Pathtype of 0 is assumed" |
| 0 | 方端齐平 | 0 | 与现 `pathOutline` 的 0 同义 |
| 1 | 半圆端 | 1 | **规范注为 "view feature only"**（DRC 口径是否含圆端属工具选择，见 §7-U3） |
| 2 | 方端外伸 width/2 | 2 | 与我们 2 的定义逐字相同 |
| 4 | CustomPlus 变长方端，长度在 BGNEXTN/ENDEXTN | **4**（现 `pathOutline` 把非 1/2 一律当 0 → 端长丢失） | 需要 §4 的可选扩展字段才不丢 |
「中间顶点上的 beginning/end 码」= **不存在**（AREA/extrusion 无一手依据）。

**(c) extrusion 位怎么办？**
KLayout：**根本不读**（`pt_conv()` 无 flag 分支，全文件无 "extrusion" 字样，Changelog 全文无命中）；它把「方向/镜像」放在 STRANS [0x1A]、缩放放在 MAG [0x1B]、旋转放在 ANGLE [0x1C] 三条独立记录（`dbGDS2ReaderBase.cc:873-889, 1018-1031`）。gdstk 同。→ 没有可映射的东西，**不要**把它接到 STRANS 上（语义不同：STRANS 只作用于 SREF/AREF/TEXT，规范 p.4-7）。

**(d) 合规 writer 对「半圆端 PATH」必须发什么？**
按规范 BNF 顺序：`PATH` → `LAYER` → `DATATYPE` → **`PATHTYPE (2 字节 = 1)`** → `WIDTH (4 字节，绝对宽度时取负)` →（仅 type 4 才发 `BGNEXTN`/`ENDEXTN`）→ `XY（裸 int32 对）` → 属性 → `ENDEL`。
KLayout `write_path():788-856` 与 gdstk `FlexPath::write_gds():804-896` 就是这么发的。**绝不**在 XY 里塞任何位。我们的 `writePath()` 现在不发 PATHTYPE ⇒ round/extended 端在自家文件里永久退化成 flush。

---

## 3. 探针 `tools/pathbits_probe.cpp`（自包含、只有一个 main、不进任何 runner）

```
SDK="/d/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
"$SDK/llvm/bin/clang++.exe" --target=aarch64-unknown-linux-ohos --sysroot="$SDK/sysroot" \
  -std=c++17 -Wall -Wextra -fsyntax-only -Ientry/src/main/cpp tools/pathbits_probe.cpp
```
**实测**：`rc=0`，唯一告警来自被测文件自身 `gdsii_reader.cpp:279: unused variable 'currentLayer'`（我没碰它）。

我还**真的构建并运行了一遍**（host MSVC，仿 `run_engine_smoke.ps1` 的调用，输出目录在 `%TEMP%\probebuild`，仓库未被写任何东西）：
`cl /nologo /utf-8 /EHsc /std=c++17 /W3 /I"entry\src\main\cpp" … tools\pathbits_probe.cpp` → 编译链接零 error/warning；`pathbits_probe.exe` → **exit=7**（7 处「真实 reader vs 规范参考」分歧）。它把每条构造好的流写成临时 `.gds`，交给**真实的** `GdsiiReader::parse` 跑一遍，再和参考解码对账。

六个用例（case1-5 是任务要求的 5 个 + case6 相邻缺陷）：

| # | 用例 | 当前代码给出 | 规范正确解码给出 | 判定 |
|---|---|---|---|---|
| 1 | flush PATH（PATHTYPE=0） | 点 `(0,0)(1000,0)(1000,500)(0,500)`，w=200，pathType **无** | 同点同宽，pathType=0 | 坐标**无差**；仅端型丢 |
| 2 | round-ended PATH（PATHTYPE=1） | 点/宽同上，pathType **丢** | pathType=1 | 端头少画 width/2；实测 `pathOutline` x 范围 0..1000（应 -100..1100）→ **两端各少 100 nm** |
| 3 | extended PATH（PATHTYPE=2；及 3b：PATHTYPE=4 + BGNEXTN=150/ENDEXTN=250） | pathType/ext **全丢**（`recordsDropped=1/3`） | pathType=2 / 4，bgn=150 end=250 | 同上；type=4 还需新字段才不丢 |
| 4 | 假说形态：中间点 X 字 = `(0x0203<<16)\|2000`（含 mag/stage+type+extrusion） | 当前解出 `X=33,753,040` | 规范同值（因为规范说整字就是坐标）；假说 A/B/C 分别给出 `2000` / `198,608` / `515` | **三种假说互斥**且都无一手依据 ⇒ 剥位=掷硬币，禁止 |
| 5 | 假说 AREA 形态（BOUNDARY 承载塞位 X 字） | 首点 `X=16,908,688` | 同值；假说 A/B/C → `400` / `131,472` / `258` | 同上；且**规范里根本没有 AREA 记录码**，该用例天生是虚构 |
| 6 | （相邻）同一 PATH 拆成两条 XY（KLayout/gdstk >8190 点必发） | **只剩后 2 点**（`currentElementPoints.clear()` 在 case XY 内，`gdsii_reader.cpp:480`） | 4 点齐全 | 真 bug：大图元静默截断，与本洞同处一个 case |

探针末尾还打印「合法坐标点亮假说位」对照表（`x=1/300/1000/40000/1000000/-1000000` → A/B/C 各自折成什么）与 `pathOutline` 端型 bbox（0:x[0..1000] 1:x[-100..1100] 2:x[-100..1100] 4:退回 flush）。

---

## 4. 建议的最小 diff（我只写不改；行号为 2026-09-19 现状）

> **前提（阻塞项，对应任务 #11）**：`gdsii_reader.h:61-65` 现在是 `NODE=0x2C PROPATTR=0x2D PROPVALUE=0x2E BOX=0x2F BOXTYPE=0x30`。规范与 KLayout/gdstk 一致为 `NODE=0x15 PROPATTR=0x2B PROPVALUE=0x2C BOX=0x2D BOXTYPE=0x2E PLEX=0x2F BGNEXTN=0x30 ENDEXTN=0x31`（Manual 6.0 p.4-14/15/16/17 与 p.47 worked example "the PROPATTR (2B hex) record"）。
> 本 diff 要加的 `case BGNEXTN` 与现有 `case BOXTYPE` **同为 0x30 ⇒ 同一 switch 里重复 case 值，编译直接失败**（C2196 / clang duplicate case）。所以 **必须先把记录码纠正到规范值，再落本 diff**；两者要么同一个 commit，要么 #11 先行。

### 4.1 `entry/src/main/cpp/gdsii_reader.h`

```diff
@@ 枚举（配合任务 #11 的码纠正）  ~L53-L65
     NODE      = 0x15,
     PROPATTR  = 0x2B,
     PROPVALUE = 0x2C,
     BOX       = 0x2D,
     BOXTYPE   = 0x2E,
+    // PATH 端型 / 端长（Calma 6.0 record 33、48、49）
+    PATHTYPE  = 0x21,
+    BGNEXTN   = 0x30,
+    ENDEXTN   = 0x31,

@@ struct LayoutShape  L141
     double pathWidth = 1.0;
+    // GDSII 端型来自**独立 PATHTYPE 记录**（XY 里没有位！）：0 flush / 1 round / 2 半宽方端 / 4 变长方端
+    int pathType = 0;
+    double pathBeginExtension = 0.0;  // BGNEXTN（仅 pathType==4 有效），nm
+    double pathEndExtension = 0.0;    // ENDEXTN，nm
```

### 4.2 `entry/src/main/cpp/gdsii_reader.cpp`

```diff
@@ L284（状态声明区）
     double currentPathWidth = 1.0;
+    int currentPathType = 0;
+    double currentBgnExtNm = 0.0;
+    double currentEndExtNm = 0.0;

@@ L423（元素起始复位，紧跟 currentPathWidth = 1.0;）
                 currentPathWidth = 1.0;
+                currentPathType = 0;
+                currentBgnExtNm = 0.0;
+                currentEndExtNm = 0.0;

@@ L461 之后（WIDTH case 之前）—— 新增两个 case
+            // 端型：规范 record 33 PATHTYPE [2102]（2 字节有符号），与 XY 无关
+            case static_cast<uint8_t>(GdsRecordType::PATHTYPE): {
+                if (inElement && dataLen >= 2) {
+                    const int16_t t = readInt16(file);
+                    // 规范值域 0/1/2/4；其余按 0（与 KLayout read_path 的告警归零同口径）
+                    currentPathType = (t == 1 || t == 2 || t == 4) ? static_cast<int>(t) : 0;
+                    skipRecord(file, dataLen - 2);
+                } else {
+                    skipRecord(file, dataLen);
+                }
+                break;
+            }
+            // 端长：record 48/49 BGNEXTN/ENDEXTN [3003]/[3103]，只对 PATHTYPE=4 有意义
+            case static_cast<uint8_t>(GdsRecordType::BGNEXTN):
+            case static_cast<uint8_t>(GdsRecordType::ENDEXTN): {
+                if (inElement && dataLen >= 4) {
+                    const double ext = static_cast<double>(readInt32(file)) * coordinateScaleNm;
+                    if (recType == static_cast<uint8_t>(GdsRecordType::BGNEXTN)) {
+                        currentBgnExtNm = ext;
+                    } else {
+                        currentEndExtNm = ext;
+                    }
+                    skipRecord(file, dataLen - 4);
+                } else {
+                    skipRecord(file, dataLen);
+                }
+                break;
+            }

@@ L472-L495（case XY）—— 只换注释 + 删掉那条 clear，取位一字不改
             case static_cast<uint8_t>(GdsRecordType::XY): {
-                // 规范符合性存疑（未验证，勿凭猜改）：… （整段旧注释）
+                // 已核实（勿再加掩码/移位）：XY [1003] 的 X/Y 各为**完整 4 字节 2 补码坐标**
+                // ——GDSII Stream Format Manual 6.0 §record 16 XY (p.4-6) + §Data Types (p.3-2)。
+                // PATH 端型在**独立记录 PATHTYPE [2102]**，端长在 BGNEXTN [3003]/ENDEXTN [3103]；
+                // 规范全文无 AREA / extrusion，也没有「首点/中间点取位不同」的条文。
+                // KLayout dbGDS2ReaderBase.cc pt_conv() 与 gdstk src/library.cpp case XY 同为整字取坐标。
+                // 剥「高位 flag」会把 |X|>=32768 的正常坐标折成小值（真·搬顶点），故禁止。
+                // 证据与实测：docs/handoff/agent-I-pathbits.md、tools/pathbits_probe.cpp。
                 if (inElement && dataLen >= 8) {
-                    currentElementPoints.clear();
+                    // 多条 XY = 规范外但实际存在的大图元分片（KLayout/gdstk 都会发）：累加，不清空。
+                    // 起始复位在元素 case（L431），ENDEL 后 L719 已清空。
                     const int pairCount = dataLen / 8;
                     for (int i = 0; i < pairCount; i++) {
                         const int32_t x = readInt32(file);   // 原样，不掩码
                         const int32_t y = readInt32(file);

@@ L610（ENDEL 里 shape.pathWidth 之后）
                     shape.pathWidth = currentPathWidth > 0 ? currentPathWidth : 1.0;
+                    shape.pathType = currentPathType;
+                    shape.pathBeginExtension = currentBgnExtNm;
+                    shape.pathEndExtension = currentEndExtNm;
```

可选（同 case，保守）：对 **PATH/BOUNDARY 元素** 的 XY，若 `x` 的高位超出 ±(2^31-1) 之外的形态无需检查；若担心假说形态真实存在，**只诊断不改值**——把 `bool sawHighBits` 挂到 `GdsiiParseResult` 的一个计数字段并在 ArkTS 提示，几何保持不动。这是「永不静默搬顶点」的唯一安全实现。

### 4.3 `entry/src/main/cpp/gdsii_writer.cpp`（`writePath` L269-L289）

```diff
     if (!writeRecord(out, 0x0E, 0x02, int2Payload({clampLayer(shape.datatype)}))) return false;
+    // 规范 BNF：PATH LAYER DATATYPE [PATHTYPE] [WIDTH] [BGNEXTN] [ENDEXTN] XY
+    int ptype = shape.pathType;
+    if (ptype != 1 && ptype != 2 && ptype != 4) {
+        ptype = 0;                       // 规范缺省即 0
+    }
+    if (!writeRecord(out, 0x21, 0x02, int2Payload({static_cast<int16_t>(ptype)}))) return false;
     if (!writeRecord(out, 0x0F, 0x03, int4Payload({width}))) return false;
+    if (ptype == 4) {                    // 仅 CustomPlus 变长端需要端长记录
+        if (!writeRecord(out, 0x30, 0x03, int4Payload({nmToDbu(shape.pathBeginExtension)}))) return false;
+        if (!writeRecord(out, 0x31, 0x03, int4Payload({nmToDbu(shape.pathEndExtension)}))) return false;
+    }
     if (!writeRecord(out, 0x10, 0x03, int4Payload(xy))) return false;   // 坐标保持裸 int32
```
（`0x21/0x30/0x31` 用字面量即可，与现有 `0x0F`/`0x10` 风格一致；写侧不引用枚举，避免和任务 #11 的枚举纠正互相牵制。）

### 4.4 NAPI 贯通（native 侧闭环即可影响 DRC/渲染/导出；ArkTS 只是面板字段）

`entry/src/main/cpp/napi_init_v2.cpp`（行号随其它 agent 变动，按锚点找）：
- `shape.pathWidth = s.pathWidth;`（LayoutShape→SceneShape，现 ~L461）后加 `shape.pathType = s.pathType;`
- `ls.pathWidth = s.pathWidth;`（SceneShape→LayoutShape，现 ~L999）后加 `ls.pathType = s.pathType; ls.pathBeginExtension = s.pathBeginExtension; ls.pathEndExtension = s.pathEndExtension;`
- `ls.pathWidth = GetObjDouble(env, sObj, "pathWidth", 1.0);`（JS→LayoutShape，现 ~L1318）后加 `ls.pathType = GetObjInt(env, sObj, "pathType", 0);`
- 三处出 JS 的地方（现 ~L401、~L1541、~L2429）加 `SetProp(env, …, "pathType", CreateInt(env, s.pathType))`
- 可选 ArkTS：`entry/src/main/ets/models/GdsiiData.ets:43` 旁加 `pathType?: number;`、`175` 旁 `shape.pathType = native.pathType ?? 0;`，并同步 `types/libhongtu/Index.d.ts`。
- `triangulator.h:297-301` 目前把非 1/2 全归 0 ⇒ `pathType==4` 的变长端仍会画成 flush。要么在 `pathOutline` 接受 `bgnExt/endExt`（签名变更，波及 `scene_graph.h:122`、`gl_renderer`、`image_export`、`drc_engine`，建议另开切片），要么在 4.2 落 `pathType` 时把 4 **显式降级并记录诊断**（推荐：`pathType = (t==4) ? 0 : t` + 一个计数），别让 UI 显示「已支持」。

---

### 4.5 行号会漂 + 顺带替任务 #11 收尾（重要）

* 上面所有行号取自我读取时的状态（其它 agent 正在并发改 `gdsii_reader.h/.cpp`，例如枚举上方的注释块已被改写）。落地时**按锚点文本定位**（`currentPathWidth = 1.0;`、`case …::XY): {`、`shape.pathWidth = currentPathWidth > 0 ? …`、`currentElementPoints.clear();`），别照抄行号。
* 交付前最后一次复检：全部锚点仍逐字命中：`.cpp` L284 / L423 / L431 / L462 / L472 / L480 / L610 / L719 / L743，`.h` L61-65 / L141。
* `gdsii_reader.h:52-60` 新写的注释「已对照规范确认：SPACING 0x2B / NODE 0x2C / PROPATTR 0x2D / PROPVALUE 0x2E」**仍与规范不符**，且它留的「⚠ 未确认：BOX=0x2F/BOXTYPE=0x30 无规范出处；记录号 47/48 另有其名（REFLIB / BGNEXTN 一类）」这个问题我这边有确切答案，可直接采信：
  - Manual 6.0 p.4-14~4-17 记录表：`42 NODETYPE [2A02] / 43 PROPATTR [2B02] / 44 PROPVALUE [2C06] / 45 BOX [2D00] / 46 BOXTYPE [2E02] / 47 PLEX [2F03] / 48 BGNEXTN [3003] / 49 ENDEXTN [3103]`，且 **p.47 的 worked example 逐字节印着 `0006 2B02 0002 = PROPATTR (2B hex)` 与 `000A 2C06 … = PROPVALUE (2C hex)`**（正好是任务 #11 的争议点，也是 §4 里 `case BGNEXTN` 与 `case BOXTYPE` 撞 0x30 的根因）。
  - 同表：`21 NODE [1500]`、`18 SPACING` 在 6.0 中「Discontinued」（p.4-9），record 31 才是 `REFLIBS [1F06]`。
  - 独立印证：KLayout `dbGDS2.h:40-86`、gdstk `gdsii.hpp:41-82`、nanyte 记录表（PROPATTR 43/0x2B、PROPVALUE 44/0x2C）。
  → 正确码表：`NODE=0x15 PROPATTR=0x2B PROPVALUE=0x2C BOX=0x2D BOXTYPE=0x2E PLEX=0x2F BGNEXTN=0x30 ENDEXTN=0x31 PATHTYPE=0x21`。写出侧 `gdsii_writer.cpp:214/217` 现在发的 `0x2D/0x2E` 在合规 reader 眼里是 **BOX + BOXTYPE**（=凭空多出矩形图元），属同一处必修。

## 5. 修好后要加进 `tools/gdsii_smoke.cpp` 的断言（手工构造字节，不能只靠自家 round-trip）

现 `gdsii_smoke.cpp` 已有 `pushU16/pushI16/pushI32/gdsReal8/int2Payload/int4Payload/real8Payload/buildSmokeGds`（L12-L103），直接复用；新增一个 `rec(type,dtype,payload)` 小 helper 即可逐条拼流：

1. **端型贯通**：构造 `PATH/LAYER/DATATYPE/PATHTYPE(1)/WIDTH(200)/XY/ENDEL` ⇒ 断言 `shape.pathType == 1`；`PATHTYPE(2)` ⇒ `== 2`；无 PATHTYPE 记录 ⇒ `== 0`；`PATHTYPE(7)` ⇒ `== 0`（非法值归零，不崩不错）。
2. **PATHTYPE 位置容错**：`PATHTYPE` 在 `WIDTH` 之前/之后各一份流（规范顺序 vs 部分工具的 WIDTH→PATHTYPE），两者都须解出同一 pathType。
3. **端长**：`PATHTYPE(4)+BGNEXTN(150)+ENDEXTN(250)` ⇒ `pathBeginExtension/pathEndExtension == 150/250`（nm 口径，UNITS=1e-9）；`BGNEXTN` 为负值（`-100`）时不错号。
4. **XY 取位不变性（关键回归锁）**：同一份**合规** PATH 流，在 X 字里按假说 A/B/C 分别置位（`|0x0203<<16|`、`|0x02<<24|`、`|0x0203&0xFFFF…|`）——**断言 reader 仍返回整字坐标**（当前 33,753,040 这类值），即「不剥位」被锁进测试；注释直接指向本文件，避免后人又「修回去」。
5. **端型影响渲染/DRC**：`SceneShape{type=PATH, pathType=1, pathWidth=200}` 的 `effectivePolygon()` bbox x 范围 `[-100,1100]`，`pathType=0` 为 `[0,1000]`（与 `coordinate_smoke.cpp:377-386` 同一口径，防两测试互相漂移）。
6. **自家 round-trip 现在才真正有意义**：`pathType=1` 的 PATH → `WriteGdsiiToBuffer` → 重解析 ⇒ `pathType` 仍为 1、XY 逐点相等；并断言字节流里出现 `0x21 0x02` 记录且**不含** `0x30/0x31`（type≠4 时不发）。
7. **multi-XY 累加**（case6 那条）：两条 XY 各 2 点的 PATH ⇒ `points.size()==4`；BOUNDARY 分片同理（含闭合点不重复计数）。
8. **码表纠正的连带**（配合任务 #11）：真 `PROPATTR/PROPVALUE`（0x2B/0x2C）被收进 `shape.properties`；真 `BOX/BOXTYPE`（0x2D/0x2E）被当 BOX 而非属性；`BGNEXTN(0x30)` 不再与 BOXTYPE 撞 `case`（编译期即验证）。

---

## 6. 我证明了什么 / 没证明什么

- **只靠编译证明**：探针在仓库现行 SDK clang++ + `-Wall -Wextra` 下语法/类型全通（唯一告警来自被测文件 `gdsii_reader.cpp:279`）。
- **真跑证明**（host MSVC，产物在 `%TEMP%`，未写仓库、未碰 runner）：6 条构造流跑通真实 `GdsiiReader::parse`，`exit=7`，逐案打印「当前 / 规范 / 三种假说」坐标。据此可复算：case1-3 坐标零偏移、端型全丢；case4/5 证明假说互斥且当前整字读法是自洽的；case6 暴露 multi-XY 截断。
- **探针与真码是有意强耦合的**：本探针 `#include` 了 `gdsii_reader.h` + `gdsii_reader.cpp` + `triangulator.h`（只读引用，未改一字），因为它要测的是**真 reader**而不是复刻。副作用：若 `gdsii_reader.cpp` 在并发改动中暂时编译不过，本探针会连带报错——那是它的信号，不是探针的毛病；那条 `-Wunused-variable currentLayer` 告警同理来自被测文件。

**未在设备上/真机上验证**：鸿蒙端渲染/DRC 端到端（按项目约定以编译门为bar，不做设备验证）。
- **没做的事**：未改 reader/writer/NAPI/ets/runner（硬约束）；未跑 `check_all.sh`/hvigor；无 git 写操作。

## 7. 剩余未知（附决定性实验）

| # | 未知 | 影响的决定 | 能一次性判定的实验 |
|---|---|---|---|
| U1 | 「PATH/AREA 的 X 字塞 presentation/extrusion/mag-stage 位」这一说法的**一手出处**我没能取到：O'Reilly《The Design Analysis Code Pack》ch.13（`oreilly.com/openbook/daj/ch13_01.html` 现 404、Wayback CDX 无快照）；`gdskit`（唯一公开宣称支持 AREA/extrusion 的 C 库）不在 GitHub（`hezel/gdstk`、`Stockmeyer/*` 均 404） | 若某天真出现一个会置位的上游工具，本判定要重开 | 拿到该文原文逐字比对；或**直接对真实样本做统计**：把 `tools/pathbits_probe.cpp` 的记录游标改造成扫描器，跑客户/合作方 3-5 个真 `.gds`，统计 PATH/BOUNDARY 的 X 字里 top16/top8 非零的比例。**若非零率≈0，则本问题永久关闭**；若某工具的文件里非零且**首点/中间点形态与坐标连续性一致**（例如高位恒等于该点 mag/stage 且剥位后 x 序列更平滑），才需要按该工具单独适配 |
| U2 | AREA 元素的**记录码**（若存在） | 若要支持 AREA，必须先知道码；我构造的 case5 用的是 BOUNDARY 载体，明确标 HYPOTHETICAL | 同上：扫真文件的「未识别记录码直方图」（`default:` 分支加一次性日志），或找 GDS-II CustomPlus / STICKS 手册（6.0 p.4-13 只提到 CustomPlus 的 Pathtype 4 + BGNEXTN/ENDEXTN，未提 AREA） |
| U3 | PATHTYPE=1 圆端**是否计入 DRC**（规范注 "Path type 1 is a view feature only"；KLayout 把 path 展成含圆端的 polygon 参与 DRC） | 我们的 `effectivePolygon()` 目前对 1/2 都按含端头的轮廓算间距 | 与签核口径对齐：拿同一份 round-path GDS 用 KLayout `strm2gds`/DRC 与我们的 `drc_smoke` 对最小间距，差异 > 0 即需二选一（建议跟 KLayout：计入） |
| U4 | PATHTYPE=4 的 `BGNEXTN/ENDEXTN` 与 `width` 的绝对/负号（WIDTH 负值=绝对宽，`gdsii_reader.cpp:464` 已 `std::abs`）在 mag≠1 时的组合语义 | 影响带 MAG 的 SREF 里 PATH 的实测宽 | 造 `SREF(MAG=2)+PATH(WIDTH=-200, PATHTYPE=4)` 的流，与 KLayout flatten 结果逐点对 |
| U5 | 任务 #11 的码表纠正与我的 0x30 case **有编译期冲突**（§4 前提） | 落地顺序 | 见 §4 前言；两者同一 commit 或 #11 先行 |

**给中央集成方的落地顺序建议**：① 任务 #11 记录码纠正（reader+writer 同步，附真 PROPATTR/BOX 样例断言）→ ② 本文件 §4.1/§4.2（端型/端长 + multi-XY 累加 + 注释替换）→ ③ §4.3 writer → ④ §4.4 三行 NAPI 贯通 → ⑤ §5 断言。全程不动 `ets/`、不动 runner；PATHTYPE=4 先显式降级为 flush + 诊断，不做半套端长渲染。
