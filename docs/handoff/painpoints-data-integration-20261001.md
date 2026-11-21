# 数据安全、源图层元数据与量化报告集成记录

日期：2026-10-01。工作区：`D:\HongTu\hongtu`。本批没有 git commit，没有运行 HAP、全量门禁或设备 5555。既有修改全部保留。本文件描述实际代码和针对性验证；端到端界面和 provider URI 行为由 root 的构建/设备批次继续验收。

## 保存发布接口和边界

新增 `SafeFilePublishService.ets`，单例 `safeFilePublishService`：

```ts
publishFile(source: string, destination: string, backupDirectory: string): FilePublishResult
publishBuffer(buffer: ArrayBuffer, destination: string, backupDirectory: string): FilePublishResult
interface FilePublishResult {
  bytes: number;
  strategy: 'atomic-rename' | 'backup-and-verify';
  backupPath?: string;
}
```

普通路径写入同目录唯一 `.pending-*` 文件，完成写入、fsync、逐字节比较后 rename 发布。若旧目标存在，先在应用目录保存完整、逐字节校验的 `.backup`，并在发布前重查旧目标未被他人修改。provider URI 无 rename 时使用同一备份前置条件，再写入、fsync、逐字节回读验证。短读/短写被完整处理；零读/写、flush、close、回读不一致都视为失败。URI 覆盖失败会恢复旧备份并再次逐字节比较；恢复失败保留旧内容 `.backup`，错误包含路径。access/read 失败不会被当成无旧文件而允许覆盖。同一服务对同一目标拒绝并行保存。

调用已覆盖 `LayoutExportService` 的 GDS 原样复制、native GDS、ArkTS GDS fallback、OASIS、SVG/PNG 外部导出，以及 `WorkspaceService.exportProject` 的 `.hongtu`、`LypService.pickAndWriteLyp`。内部 workspace `.pending` + rename 路径保留。发生目标发布失败后不会静默换另一 writer 再覆盖目标。调用者仍应只在成功时清除 dirty。

不能把 provider 备份发布称为原子事务：进程强杀或断电可能中断 provider 写入；留下的备份提供恢复原内容的材料。第二批已经新增持久恢复索引和 FileRecoveryService，详见下文；Root 接启动发现和 ProjectPanel 操作入口。cache 只用于新内容 staging，旧文件备份在配置后统一进入 filesDir/hongtu-file-recovery。

第二批已将 `EngineeringFileService.saveText` 与 `AutomationFiles.saveAutomationText` 接入 SafePublish，并在调用时配置 filesDir。`ComponentLibraryService.export` 的 Workspace.writeAllToUri 普通路径分支由 root/precision owner接安全发布（该文件本批未编辑）。

## 源图层定义贯通

native `gdsii_reader.h` 新类型，以及 `libhongtu/Index.d.ts` 的对应声明：

```ts
interface LayerNameInterval { type: number; lower: number; upper: number; }
interface SourceLayerDefinition {
  name: string;
  textLayer: boolean;
  layer: LayerNameInterval;
  datatype: LayerNameInterval;
}
```

区间类型遵循 OASIS/KLayout reader：0 是任意值（0..4294967295），1 是 <= upper（lower=0），2 是 >= lower（upper=4294967295），3 是单值（lower=upper），4 是闭区间。保存完整区间表，保留 geometry/text layer 区别；不会把大范围/无限范围展开成海量假层。单值 layer/datatype 的 LAYERNAME 创建 elementCount=0 的空层。来源名称保存在 `LayerInfo.sourceName?: string` / `UiLayer.sourceName?: string`，独立于 `chineseName` / `englishName` 显示名称。

`GdsiiResult`、`LayoutDocument`、`WorkspaceDocument`、`ExportLayoutInput` 的字段均为 `layerDefinitions?: SourceLayerDefinition[]`。native parser -> NAPI -> `parseResultToDocument` -> workspace 草稿/工程 -> `buildNativeDocument` -> NAPI `ReadLayoutDocumentSnapshot` -> native OASIS writer 的链路已实现。OASIS writer 写出原定义表，并为新空层或带 sourceName 的未覆盖数值层补单值定义。GDS 格式本身不承载 OASIS LAYERNAME，源元数据须由 `.hongtu` 或 `.lyp` 同伴文件保留，不能宣称裸 GDS 保存这些信息。

Root 的 Index 可将内存状态命名为 `sourceLayerDefinitions`，但序列化/导出对象必须传 `layerDefinitions`：

1. import result 转文档后捕获 `doc.layerDefinitions ?? []`；新建空文档清空该表。
2. capture WorkspaceDocument 和构建 ExportLayoutInput 时包含该表。
3. restore workspace 时恢复该表。
4. 普通显示名称修改不覆写 sourceName；样式 clone 已保留 sourceName。
5. LYP 导入应用 `result.layerDefinitions`，LYP 导出传第二个参数。

Native 读区间参考了 KLayout 官方 reader 的 LAYERNAME 语义：`https://raw.githubusercontent.com/KLayout/klayout/master/src/plugins/streamers/oasis/db_plugin/dbOASISReader.cc`。

## LYP 同伴元数据

`formatLyp(entries: LypLayerEntry[], layerDefinitions: SourceLayerDefinition[] = []): string` 保留标准 XML 字段，同时以 XML 注释 `hongtu-source-layers-v1` 保存源名称/空层身份/完整定义表。内容为 UTF-16 hex 编码 JSON，避免 XML 文字转义和 `--` 注释终止问题。`parseLyp` 返回 `layerDefinitions?: SourceLayerDefinition[]`，其 `layers` 条目可带 `sourceName?: string`、`declaredEmpty?: boolean`。扩展错误只警告，不污染标准字段。`mergeLypIntoLayers` 可恢复带扩展身份的空层；普通外部 LYP 的不匹配条目仍按原行为警告，不制造数据层。

该扩展由鸿图自己回读；KLayout 正常读取并忽略注释、保留标准显示字段。经过其他软件重新序列化的 LYP 若丢弃注释，鸿图扩展数据也可能被移除，应优先以 `.hongtu` 存完整工程。

## 量化报告

native `GdsiiWriteResult.quantization?: QuantizationReport`、ArkTS `LayoutExportResult.quantization?: QuantizationReport`：

```ts
interface QuantizationReport {
  dbuNm: number;
  examinedValueCount: number;
  quantizedValueCount: number;
  quantizedShapeCount: number;
  maximumDeviationNm: number;
}
```

上述类型来自 `libhongtu.so`；`PrecisionService` 也有同名 QuantizationReport，root 引入时须 alias（如 `NativeQuantizationReport`），不要混用字段。

`layoutExportService.analyzeQuantization(input)` 是写出前的轻量预检：原坐标、PATH 宽/扩展、AREF 实际编码端点，负半格与 native llround 一致，报告不会修改几何。native 和 ArkTS writer 在实际 `nmToDbu`/`toDbu` 处报告量化，输出警告和正式报告供精度栏/保存结果使用。正式计数按序列化数值字段（含多边形闭合端点），因此可与预检原值数量不同；两者的最大偏差/受影响对象表达保持一致。OASIS odd halfwidth 无法表达时保留原来的拒绝行为，并报告完整宽度的偏差，不能用 warning 替代保存失败。

## Workspace 新可选字段

`precision?: PrecisionSettings` 引入 `./PrecisionService`，shape/kinds/bool 验证后复用 `validatePrecision`，且 dbuNm 必须与 `physicalUnits * 1e9` 匹配。旧工程无此字段可读。

`navigationPath?: InstancePathStep[]` 引入 `./EditService`。非空路径长度必须等于 `cellStack.length - 1`，父/子 cell 必须与 stack 对应，instanceId 指向已有 INSTANCE，owner/cellId 对应，row/col 在成员范围，transform 六项均为有限数。root 恢复时用 `editService.restoreNavigationPath` 从真实 instance 重新计算 transform，不能信任存盘矩阵做编辑。`engineering?: EngineeringProjectBundle` 已由 root/precision owner 集成，Workspace 使用实际 `engineeringProjectService.validateBundle` 校验。

## 已运行的针对性验证

| 检查 | 结果 | 覆盖 |
| --- | --- | --- |
| `tools/safe_publish_host_check.mjs` | 14/14 | URI 备份/恢复、短 IO、open/read/write/flush/close/access 故障、相同长度内容损坏、恢复失败保留旧备份、rename 失败 |
| `tools/export_fallback_host_check.mjs` | 41/41 | 多 MiB 完整发布、原样源复制条件、dirty 当前快照、失败不报告成功、元数据 native 输入、预检/实际量化报告 |
| `tools/workspace_recovery_host_check.mjs` | 27/27 | 既有恢复/历史/预算 + 源名/空层/区间/精度/成员路径回读及畸形拒绝；真实 Safe/ComponentLibrary 外部普通路径 UTF-8、rename 故障保留旧目标、自有 atomicWrite |
| `tools/index_workspace_host_check.mjs` | 51/51 | 真实 Index/Edit/Workspace 提取；新增 precisionSettings 依赖和真实 validatePrecision stage；结构历史/Cell/多工程回归 |
| `tools/lyp_standard_host_check.mjs` | 14/14 | 扩展元数据和空层恢复、错误扩展隔离、真实 KLayout 对 29 对 layer/datatype 的标准字段互读（包含扩展注释） |
| `tools/layer_metadata_quantization_smoke.cpp` | 11/11 | MSVC 构建实际 native reader/writers，OASIS definition/text/range/empty 回读、GDS/OASIS 量化、odd-width 拒绝 |
| 真实 `klayout.db.Layout.read(metadata.oas)` | 通过 | DBU 0.001 µm、TOP、68/20 met1 drawing、93/0 empty mask 零图形、68/5 label 零图形 |

保存证据目录：`artifacts/painpoints-data-20261001`。host harness 运行实际生产源，仅平台/API stub；没有替换 parser/writer 实现。NAPI/ArkTS 编译和设备体验由 root/另一会话构建批次确认。本批于安全服务 catch unknown 编译修复后再次 freeze。

## 第二批：持久恢复索引与全部文本入口

`safeFilePublishService.configureRecoveryDirectory(context.filesDir)` 校验绝对路径、普通目录和非符号链接，并创建固定 `filesDir/hongtu-file-recovery`。配置后所有格式旧备份使用此持久目录，传入 cacheDirectory 仅作新内容 staging。未配置时 provider URI 的已有目标覆盖在修改前拒绝，不会悄悄退回 cache 备份。Root 在启动/能力上下文可用时先调用 `fileRecoveryService.list(context)`；它同时配置 SafePublish，启动异常应保留错误提示而非继续未经初始化的覆盖。

完整旧内容备份经过逐字节比较后，先 fsync 并 rename 发布小 sidecar `{backupPath,targetUri,name,bytes,createdAt}`，随后才允许修改目标。targetUri 只存移除 query、fragment、userinfo 后的描述；原含授权 token 的 URI仅在当前 IO 调用内存使用。sidecar 写入/flush/close/rename失败会中止目标发布并保留合法命名的孤立 backup，启动扫描仍能发现。正常发布或成功恢复旧目标后清除 backup/sidecar；恢复失败或进程中断保留材料。

新增 `FileRecoveryService.ets`：

```ts
interface FileRecoveryEntry {
  backupPath: string;
  targetUri: string;
  name: string;
  bytes: number;
  createdAt: number;
  metadataMissing?: boolean;
}
fileRecoveryService.list(context): FileRecoveryEntry[]
fileRecoveryService.exportBackup(context, entry, protectedTargets: string[] = []): Promise<string>
```

list 只扫描固定持久目录里合法的 `hongtu-publish-<13位时间>-<序号>.backup` 普通文件，忽略符号链接、目录、越界路径/不匹配索引/不合理未来时间，单backup上限1TiB，sidecar上限16KiB，最多最近1024条。坏或缺少sidecar时不信任target/name，而按“未完成保存的安全副本”返回合法孤立backup。读取sidecar检查大小稳定性、身份与长度匹配，绝不依据sidecar路径读其他位置。

exportBackup 再验证 entry 来源和大小，系统 picker 选择新的副本名称，拒绝原target、protectedTargets、恢复backup本身和任何已有非空目标；picker预建的空新文件可写。Root须将所有已打开工程的 sourcePath/saveUri/projectUri 放入 protectedTargets。picker等待结束后重查备份。成功/失败都保留恢复源及sidecar，操作仅导出数据，不打开或执行脚本，不向旧目标回写，无删除入口。

precision owner 已加入 ProjectPanel 的轻量 `recoveryEntries: ProjectRecoveryEntry[]`（extends FileRecoveryEntry）与 `recoverAction(item)`，文案“导出安全副本”；Root统一接 Index 状态和回调。在任何保存成功/失败后刷新 list，保证新失败材料及时可见；重启启动时扫描，保证跨重启可见。

新增 `tools/file_recovery_host_check.mjs` 已通过18项真实文件IO检查：持久成功清理、未初始化时拒绝provider覆盖、恢复失败重启发现、metadata write/flush/close/rename失败旧目标不动且孤立backup可查、来源/目录/符号链接/大小/未来时间错误隔离、导出副本保留材料、受保护目标拒绝、复制失败保留材料、Engineering/Automation UTF-8短IO成功和保存失败。既有Safe14、export41、workspace27、LYP14、Index51、Engineering3、Automation9同时回归通过。Windows无文件symlink权限，链接测试使用真实目录junction（lstat识别符号链接）检查同一拒绝分支。

## 第三批：主页面真实接线与宿主依赖

`tools/stage_engineering_project.mjs` 和 `tools/stage_engineering_tools.mjs` 机械重映射完整生产模块的 import，保留实际工程包校验、DRC 规则、Python 模板、宏和工艺逻辑；native worker/picker/timers 由宿主传输模拟。Workspace 和 Index fixture 使用真实 `validatePrecision`、实际工程包 parser，不以零值或默认通过 stub 替换业务方法。

`tools/index_engineering_recovery_host_check.mjs` 11/11：实际 Index 保存工程工具快照、按文档过滤宏、待恢复 bundle 原样保留、打开 bundle 不自动覆盖草稿/宏/DRC、technologyJson 不能绕过显式恢复；完整 prevalidate、过期上下文拒绝、空规则/空宏不回退内置、Python 容量失败无先行修改；恢复副本传入当前和所有非活动文档的 source/save/project 保护集合，失败保留源。

`tools/index_save_snapshot_host_check.mjs` 19/19：新增真实 `parseImportJob` 生命周期和真实 `LayoutExportService.analyzeQuantization` / Index `confirmExportQuantization` 提取。整数不弹框，分数报告具体对象数/写出值数/最大偏差，取消/关闭不开始 picker/写入，过期确认拒绝，继续写出捕获的快照而保留编辑分数坐标，非法 DBU/坐标不开始外部写入，所有保存结束刷新恢复材料；recent quick/full 走实际后台方法，cancelled 终态即便携带成功 payload 也不采用。

`tools/index_native_jobs_host_check.mjs` 10/10：使用实际 Index 生命周期、实际 EditService 版本、完整 DrcService 的后台规则快照/类型映射/结果验收，覆盖 scoped 进度、取消拒绝与幂等、旧 finally 不清新作业、取消导入不采用预算、busy/启动失败、geometry/rules 传输快照隔离、doc/revision/cell/depth/tiling/tileSize/rules/technology 过期拒绝、失败/取消保留旧 DRC、空规则明确未检查。执行中 ruleFilter 变化的过期回归在 root production 修复后通过。

两项新 Index fixture 已挂 `tools/check_all.sh`，原有 flatten fixture 重复项去重。最终逐个运行该列表的 46 个 Node host 脚本，46/46 全通过，exit code manifest 为 `artifacts/painpoints-data-20261001/host-current/results.json`。`index_ai_circuit_host_check.mjs` 新依赖已改为真实 cancel/precision/工程 parser staging，67/67。每个脚本日志位于同目录。本批不触及 Index/Workspace 生产，不运行 HAP、全量门禁或设备。
