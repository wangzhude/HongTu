# 中心集成状态（2026-09-19，主控代理）

范围：本文件只记录**中心侧已落地/在途/待办**，供 `/goal resume` 后无缝接续。
验收口径始终是 `bash tools/check_all.sh`（四层 + 两个前置层），设备/模拟器签核按用户指示**不在范围内**。

## 1. 本轮中心侧已落地（都有代码证据；验证状态逐条标注）

| 项 | 落点 | 验证状态 |
|----|------|----------|
| 导出样式不再被硬编码覆盖：`ApplyLayerStyles` 去掉无条件 `transparency=0.35f`，改为「给了才覆盖」 | `napi_init_v2.cpp:2148+` | NDK 链 `libhongtu.so` ✓ |
| 上条的**自身回归**修复：`napi_has_named_property` 对「键存在但值为 undefined」返回 true，于是 `transparency: undefined` 被读成 0（全不透明）、`lineStyle: undefined` 被读成 solid、`visible: undefined` 被预置成 true（强制显示隐藏层）。统一改走 `napi_typeof` 判定，新增 `ReadDoubleProp`，与文件里 `ReadIntProp:1858` 早已写明的口径一致 | `napi_init_v2.cpp` `ReadDoubleProp` + `ApplyLayerStyles` | 跨编译器 ✓、NDK ✓ |
| `ExportLayerStyle` 补齐 `transparency/lineWidth/lineStyle`，ArkTS 侧 0–100 → native 0–1 在边界换算，线型字符串→0..3 码 | `types/libhongtu/Index.d.ts:303`、`pages/Index.ets` `lineStyleCode()` + 导出映射 | 跨编译器 ✓ |
| LVS 两处口径统一：「载入提取网表」此前按深度 0 导出、而「运行 LVS」按画布深度比对 ⇒ 整片假开路 | `pages/Index.ets:3803` | ArkTS 编译待中心复跑（见 §3） |
| `runDrc` 规则类型上界由字面量 9 改为取自枚举末位（`MIN_EXTENSION(10)/DENSITY_UNIFORMITY(11)` 此前会静默按 MIN_WIDTH 跑出无关违规）；`NativeDrcRuleType` 同步到 0..11 | `napi_init_v2.cpp:1793+`、`Index.d.ts:194` | NDK ✓ |
| **PATH 端型（pathType）保存链路贯通**——见 §2，这是本轮最重要的数据保真修复 | 8 处 | 跨编译器 ✓、NDK 待复跑、ArkTS 待复跑 |
| mirror 码 2（Y 轴）在 in-memory 快照与展开路径里塌成 X 镜像（少转 180°）；写出侧本来就正确，故只修两个消费者 | `napi_init_v2.cpp:487`、`HierarchyExpandService.instanceTransformMat` | 跨编译器 ✓、NDK/ArkTS 待复跑 |
| 门禁新增第 10 项：`Index.d.ts` 声明面字段 native 从不按名读/写 ⇒ 判失败（幽灵字段）。调试中修掉两类自身假阳性：多行方法签名的参数被当字段（改按括号深度=0 认字段）、CRLF 与缩进空白未去 | `tools/check_docs_claims.sh` | 本层 ✓（当前 1 项失败见 §4） |
| 文档纠偏：矩阵 §5「线型/填充/.lyp：弱/无」过期口径改写；§10 断言数 220→362；§10 新增**宽度口径定案** | `docs/roadmaps/klayout-feature-gap-matrix.md` | — |

## 2. pathType 为什么改了 8 处（下次别再只改两处）

native 侧一直是对的：`gdsii_reader.cpp:650`→`LayoutShape.pathType`→`napi:402` 回传→`SceneShape`→`Triangulator::pathOutline`→`gdsii_writer.cpp:316` 发 PATHTYPE。
断掉的是 ArkTS 这一侧：**只要不经它**，「打开→改一笔→保存」就把 round/extended 抹成 flush（两端各短 `pathWidth/2`），且画布/DRC 轮廓与磁盘文件不一致。补齐点：
`Index.d.ts` NativeShape、`GdsiiData.ets` Shape 声明 + parse→Shape 转换、
`EditService.cloneShape:187`（撤销/移动/复制的唯一出口）、
`AdvancedEditService.cloneShape:1044`（阵列/缩放）、`Index.ets:3213`（带矩阵粘贴）、
`HierarchyExpandService:195`（实例展开）、`LayoutExportService.buildNativeDocument`、
`napi_init_v2.cpp:1321`（写侧读取）。
**教训**：修一条保真链路时必须 grep 全部「逐字段手搓 clone」的点，只补头尾两处会在使用中静默复发。

## 3. 在途（不要与它们抢文件）

- **子代理 J（`boolean_smoke.cpp` / `clipper_engine.h` / `geometry_engine.h` / `drc_engine.h` / `napi_init_v2.cpp`）——已在 150 轮上限被终止，未写交接文档，但代码状态是完成的**：`boolean_smoke` 71/0 通过并已接入两个 runner（详见 §4）。**中心侧尚未核实的是它的「UI 接线」是否落地**：`mergeSameLayer` 现出现在 `drc_engine.h`、`napi_init_v2.cpp`、`Index.d.ts`，但 `DrcService.ets` 里有没有开关把它传下去、WorkbenchInspector 有没有呈现「本次为合并区域口径」，都要逐一确认——没有 UI 入口就等于功能不可达（本项目反复踩过的口径）。另外 J 未写 `docs/handoff/agent-J-*.md`，其布尔/offset 与 KLayout 的逐例一致性仍是 UNVERIFIED。
- **子代理 L（`DrcService.ets` / `drcRulesets.ets` / `drcRuleText.ets` / `WorkbenchInspector.ets`）——同样在 150 轮上限被终止**，它把 DRC 规则清单可配置化 + 结果按规则分组基本做完（`parseRuleSetText`、`getRuleGroups`、面板接线、`completenessNotices` 分离告警），但**留下编译不过的工程**；中心侧已收口并全四层转绿（见 §4）。**唯一确证的缺口：它答应写的 host 断言脚本没写**（临终停在 "Now the host assertion script:"），所以 `parseRuleSetText` 的 JSON/CSV 与分组计数目前只有编译级验证。另外它没写 `docs/handoff/agent-L-*.md`。

## 4. 门禁状态：**14:22 全四层通过 `########## 全部门禁通过 ##########`**

```
0    跨编译器（clang++/libc++）      ✓
0a2  脚本自身解析（ps1 + bash -n）    ✓
0b   文档口径 10 项机械核对            ✓
1    host 冒烟 16 套、实测 433 断言 = README 声称 433 ✓
2    NDK 链 libhongtu.so               ✓
3    ArkTS 编译 + HAP 打包             ✓（entry-default-unsigned.hap 14:22:01）
```

- **子代理 L 也在 150 轮上限被终止**，且它留下的是**编译不过的工程**（4 条错：`drcRuleText.ets:584` 实参个数、`WorkbenchInspector.ets` 三处找不到名字）。中心侧收口的做法：`failResult` 调用补齐第三参 `[]`；**把它只差没写完的 `DrcRuleGroupTable` 组件补上**（它的 14 个入参、`DrcService.getRuleGroups()`、父组件 12 个 `@State group*` 与 `locateGroupSample` 都已由 L 就位，只有 struct 本体缺失）——**没有**删除它的调用点，因为那不是"半成品"而是"差最后一块"。
- 仍与 J/L 无关但**未验证**的部分：L 的规则清单解析器（`parseRuleSetText`/CSV/JSON 路径）只过了 ArkTS 编译，**它计划要写的 host 断言脚本没来得及写**（临终输出停在 "Now the host assertion script:"）。⇒ 待办：为 `drcRuleText.ets` 的解析/分组补 host 纯逻辑断言（H 的 `.lyp` 有先例：`node --experimental-strip-types`），负例至少要有「坏规则文本必须报错而不是产出半套」「TRUNC/NOHIER 不得计入任何规则命中」。
- 中心侧本轮改的 ArkTS/声明文件（`GdsiiData.ets`/`LayoutExportService.ets`/`EditService.ets`/`AdvancedEditService.ets`/`HierarchyExpandService.ets`/`Index.ets`/`Index.d.ts`）随这次全模块编译**一并通过**，可视为已编译验证（仍非设备验证）。
- 误判记录（值得留着）：14:09 我曾用 `tools/run_one_smoke.ps1 -Name roundtrip_smoke` 看到 `LNK1120 4 个无法解析的外部符号`，误报为「引擎被改坏、roundtrip/engine 冒烟编译失败」。真实原因在**我自己的隔离脚本**：它没带上 `gdsii_reader.cpp`/`gdsii_writer.cpp` 两个 TU（缺失符号正是 `GdsiiReader::parse`、`WriteGdsii`），共享 runner 会带。**How to apply**：判定回归要用权威层（`run_native_smoke.ps1` / `check_all.sh`），辅助脚本报错先怀疑脚本自己。→ 待办：给 `run_one_smoke.ps1` 自动附带这两个 TU 或加 `ExtraSources` 参数。
- 其余层：跨编译器 ✓、NDK 链 `libhongtu.so` ✓、脚本解析 ✓、文档口径 ✓（README 计数与幽灵字段两项均已一致）。
- 复跑命令（隔离目录，避免与 L 互踩）：

```bash
cd /d/HongTu/hongtu
bash tools/check_all.sh                     # 权威四层（含 hvigor assembleHap）
powershell -File tools/run_one_smoke.ps1 -Name <suite>   # 注意上面的隔离脚本坑
```



## 5. 待办（按价值排序，均已建 task）

1. **#21 层号三套真相**（比样式丢失更严重）：`VerifyService.ets:74` 的 `DEFAULT_VIA_LAYERS` 顶层 `{12,3,4}` 把 layer 4 当 M4，而 `constants.ets:54` 定义 4=Poly、5=AA，`pcell_framework.h:638,700` 又用 ACTIVE=4/VIA1=5 ⇒ 默认口径下 M3 可能被桥到 Poly/有源区，**LVS 假连通**；PCell 产出的 via 不参与连接。先只读核实"本仓库读取器真实产出哪些层号"再收敛到单一真源，**不得凭猜改默认表**。
2. **#22 NAPI 边界零测试覆盖**：`roundtrip_smoke.cpp:515` 明确把 `napi_init_v2.cpp` 排除在 host 冒烟外，故本轮所有边界缺陷（含我自己引入的那个）都在全绿断言下存活。建议把「参数装配」从 napi 依赖中拆成纯函数（props map → 引擎配置），对「缺失 / undefined / 类型错」三种输入差分断言"不得覆盖原值"。
3. **#20** 两条样式通道：`RenderBatch.pathWidth`（GL 主路径 PATH 现为 hairline）、导出侧 `fillPattern`（.lyp 的 hollow/cross/diagonal 导出成实心）。
4. **#19 收尾**：本轮已实现，待 ArkTS 编译复跑 + 矩阵 §2 PATH 行更新（"保存链路已贯通"）；`BGNEXTN/ENDEXTN` 每端长度仍无字段承载，保持"子集"措辞。
5. 图层 `locked/selectable` 目前**只是显示层**：`locked` 仅被 `WorkbenchSidebar` 用于图标/菜单文案，`selectable` 无任何消费者 ⇒ 锁定图层上的图形仍可被选中/编辑。修法已在 `EditService:1000` 的 `setLayerVisibleProvider` 旁同构加一个 provider，并在 `hitTest` 两处（:649/:663）消费。

## 6. 仍然不得被弱化的口径

- DRC/LVS 皆为连通性/逐图形级**快速预检查，非签核**；布尔与 offset 不可签核（J 的 merged-region 落地后仍不得升格为"签核"）。
- 设备/模拟器签核全部未做（用户本轮明确选择"跳过设备，只做三层构建验证"）。
- 与 KLayout 的"逐例一致"未经参考实现比对；宽度口径是**文档推演**，非本机实测。
