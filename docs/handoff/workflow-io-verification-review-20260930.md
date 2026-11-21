# 导入、检查、比较与输出流程复查（2026-09-30）

本轮针对既有服务和面板修复，不新增页面，不使用 5555 设备，也未运行共享 HAP/native build。以下是实际代码回归与隔离原生编译证据；不能替代本轮 HAP 和设备交互验收。

## 1. 导入与错误恢复

`FileImportService.pickAndScan` 现在在复制前检查有限整数大小、非空及 512 MiB 上限；复制后核对长度再 quick scan。复制失败、长度不一致、扫描异常和扫描失败均关闭源描述符、移除 staging。扫描空错误文字提供可读兜底。

URI 先剥离 query/fragment，再解码扩展名，避免 `layout%2Eoas?grant=...` 被当成 GDS。时间戳加服务序号，解决同毫秒并发导入的临时文件冲突。空文件拒绝；合法空 Cell 文档仍可保存。

Index 的解析 ticket、导入忙锁、切页与 native 恢复由 root 修改。原因是 CIF/DXF quick scan 和完整 parse 均可能更新全局 native 布局；服务成功不等于调用者仍持有同一工作区。导入回归仅证明服务的 provider/大小/复制/扫描/解析边界，不宣称 Index 已完成设备验证。

## 2. 工艺配置、比较、伴随验证

- `TechnologyPanel` 新增 `revisionProvider: () => string`。打开时捕获 document/revision；导入返回、应用、解绑前校验，避免 A 面板在切到 B 后写入。无效工艺导入保留原 draft，关闭后的 picker 回调不改面板。root 负责接同一 workspace ID + editor revision provider。
- `LayoutComparePanel` 的 B picker 采用 busy/ticket，禁止并发选择；关闭后返回的 B 与旧 B 均按归属清理。比较数字使用完整十进制校验，空白、`0x10`、带单位尾缀不能静默成为零或可用值。既有完成请求 Cell/revision 定位保护保留。
- `VerificationPanel` 新增请求 generation 与 `cancelRun`。在创建快照时取消，不再继续发起 verify；已发出请求取消后，即使收到成功响应也不应用。快照 finally 清理并释放 busy；关闭后的网表 picker/报告回调不改面板。文件选择期间禁止新的验证；切页后的参考网表不覆盖原输入。
- `EngineeringFileService` 检查有限文件长度及短读/短写边界，并给比较 staging 添加序号。原有 2 MiB 文本和 512 MiB 比较文件限制保留。

## 3. DRC 不完整结果与精确用途层

实际复现并修复：没有任何启用/过滤匹配的规则、单规则抛异常、请求层级却全部走不展开的 ArkTS 路径，之前都可能显示通过。现在使用 `DRC.EXEC` / `DRC.NOHIER` 完整性通知阻止通过；规则分组也使用同一通知判定。

规则 datatype 现在只有“未声明”表示任意；显式 `0` 精确匹配，和非零用途一致。CSV/JSON 解析、文本往返、层文字、ArkTS 检查、native 映射均保留这个区别。NAPI 的 `NativeDrcRule` 新增可选 `exactDatatype1` / `exactDatatype2`；未给新字段的旧 native 调用仍保持零通配语义。没有新增 NAPI 导出函数（仍 43）。WorkbenchInspector 既有 `0=任意` 文案及 `0` 显示为 `*` 的两处由 root 协调同步。

原生各单层检查及包围/重叠候选都过滤 exact datatype。包围层完全不存在时不得跳过检查；只有错误用途的材料不能满足包围；一个正确的大包围不再被另一个余量较小的候选否定。ArkTS 包围回退同样检查缺失材料，并按任意合法候选判定。原生标记保留实际被检查图形的 layer/datatype，包围违例落在被包围图形上。

这仍是有明确范围的几何预检查。ArkTS 非矩形包围使用已有 bbox 近似，原生几何规则与注册电脑 deck 也不据此扩展为完整 PDK 签核。

## 4. 网络提取与 LVS

`LvsEngine.buildWorkShapes` 在无 Cell 且 hierarchyDepth > 0 时曾以相同参数递归自身；现空文档直接结束，非空但没有可用根明确标成不完整。

既有 200,000 work-shape 预算现在同时适用于本地和展开检查；本地先过滤 owner Cell，其他 Cell 不消耗当前 Cell 预算。`compare` 在提取不完整时返回 `status=truncated / ran=false / matched=false`，不把部分网络当成完成的比较。`exportSpice` 拒绝导出不完整网络或器件提取结果，NAPI `extractNets` 也拒绝交回部分数组。

`NativeHongTuService.extractNets` 对实际 native 异常向上抛出可读错误，模块不可用仍返回 null。这样 Index 既有 try/catch 会显示失败，不会因预算失败又进入昂贵的简化本地回退。没有改变几何连通预检查与电脑端器件 LVS 的范围区别。

## 5. GDS / OASIS / SVG / PNG 输出

- native 输出字节数必须为正整数并与实际 staging 长度一致，再复制到目标。原 GDS 源文件直拷也做长度检查。
- OASIS `success=true` 但 `skippedShapes>0` 时明确失败，目标不接受残缺输出。
- 四类 native staging 统一由 finally 清理，覆盖 native 写失败、目标复制失败及成功路径；同毫秒并发输出使用独立序号路径。
- SVG/PNG 只接受已知格式与 1–8192 的整数像素宽高，避免原生自动回退尺寸造成“请求与输出不符”。
- GDS 既有 native → ArkTS 完整回退、所有权快照、短读短写补齐、失败保留 dirty 的 Index 契约继续保留。对外部 document URI 不声明事务回滚能力；失败必须明确反馈且不能 markClean。
- 合法空文档和多独立顶层 Cell 的记录均保留。GDS 的 Cell 记录顺序不是顶层优先承诺；测试按 Cell 集合与 native cellNames 检查，未把排序差异判成丢失。

## 6. 本轮实际验证

| 测试 | 通过项 | 证据文件（artifacts/feature-completion-20260930/） |
|---|---:|---|
| export_fallback_host_check | 39 | workflow-export_fallback_host_check.log |
| engineering_panel_context_host_check | 12 | workflow-engineering_panel_context_host_check.log |
| workflow_import_host_check（新增） | 8 | workflow-workflow_import_host_check.log |
| drc_rules_host_check | 101 | workflow-drc_rules_host_check.log |
| engineering_file_host_check | 3 | workflow-engineering_file_host_check.log |
| python_input_cleanup_host_check | 9 | workflow-python_input_cleanup_host_check.log |
| technology_package_host_check | 21 | workflow-technology_package_host_check.log |
| native drc_smoke | 47 | workflow-drc-native.log |
| native lvs_smoke | 72 | workflow-lvs-native.log |

两个 native 套件用 WSL g++ C++17 在 `/tmp/hongtu-workflow-*` 独立目录编译。对应可复现命令保存在同 artifact 目录 `workflow-drc-native-run.sh` / `workflow-lvs-native-run.sh`，不占共享 build。`check_docs_claims.sh` 本轮也通过；HAP/NDK 全量 gate 与设备交互由 root 在最终集成后统一执行。

root 需将新增 `tools/workflow_import_host_check.mjs` 及现有 `tools/drc_rules_host_check.mjs` 纳入统一 host gate，并验证上述 Index 接线。此前完成的构建/设备报告不能自动当成这些后续改动的验证结果。

## 7. 层级编辑范围复核协作

只读复核 editing_gaps 新增的 `HierarchyBoundsResolver` 后，确认普通 native SREF 的 `arrayCols/arrayRows=0` 被当作无效 AREF 拒绝，以及 PATH 沿各轴统一 padding 会使 flush 端对齐发生可见偏移。SREF 归一和 resolver/Canvas 接线由 editing_gaps 修改。

按协作授权新增独立 `PathBoundsService.ets`：按 `Triangulator::pathOutline` 累计实际轮廓极值，覆盖 miter、8 段圆端、方端、正负显式延伸、重复点以及变换。普通宽度在本地轮廓完成后应用矩阵；绝对宽度先变换中心线，显式延伸跟随 `sqrt(abs(det))`。退化轮廓返回 undefined；非有限数返回非有限 bounds，由调用方拒绝操作。

`path-bounds-native-diff.log` 记录对真实 `effectivePolygonTransformed` 的 **448 例差分**及 **5 例退化/非有限/flush 端点断言**全部通过。对应 `path-bounds-native-diff.cpp` 与 `.mjs` 保存在同 artifact 目录，使用独立 WSL g++ 二进制；未运行共享 HAP 构建或设备操作。近 180° miter 的差分曾揭示单位化运算顺序误差，已改为与 native 同样乘以 `1 / length` 后重跑通过。
