# 可取消导入 / 后台 DRC 接线（2026-10-01）

原 `parseAsync`、`runDrc` 均保留。新增接口已写入 `cpp/types/libhongtu/Index.d.ts` 和 `NativeHongTuService.ets`，生产批次正在测试，不要在我 freeze 前构建。

## API

```ts
nativeHongTuService.startParseJob(filePath, {
  scope: uniqueDocumentOperationScope, isOasis: false, quickScan: false
}) // NativeParseJob | null

drcService.startDrcJob(renderSnapshot, {
  scope: uniqueDocumentOperationScope, documentId: currentDocumentKey,
  inputVersion: editService.getSessionRevision(), ownerCellId: currentCellId,
  hierarchyDepth: drcService.hierarchyDepth, mergeSameLayer: false,
  // scopeBox 可选，Cell 坐标系；类型 NativeJobScopeBox
}) // DrcBackgroundJob | null

nativeHongTuService.getJobProgress(job.jobId, job.scope) // NativeJobProgress | undefined
nativeHongTuService.cancelJob(job.jobId, job.scope) // boolean，表示请求已接受，尚不代表 worker 已停
await job.completion
```

每个操作创建唯一 scope（窗口 / 文档 / operation counter），不复用其他会话 scope。native 同时验证 NAPI env + scope，jobId 单独不能授权。完成后仅保留至多 64 个小进度记录，后台 payload/快照/临时索引随 completion 释放；至多 8 个活动作业。

`NativeJobProgress`：`jobId, scope, kind, stage, status, completed, total, cancelRequested, message`。
status 为 `running | succeeded | failed | cancelled`；`cancelRequested=true` 时继续显示“正在取消”，直到 completion.status 为 cancelled 才显示“已取消”。stage 建议映射：queued 排队、reading 读取、parsing 解析、decompressing OAS 压缩块解码、resolving 名称与引用、budget 资源预算、indexing 建立临时索引、checking 规则检查、publishing 生成结果。completed/total 属当前阶段，total=0 表示该阶段无可靠比例。读取/解析为字节计数，checking 为规则阶段百分比；不能拼成伪精确总进度。

`NativeParseJobResult`：`jobId, scope, status, message, result?:GdsiiResult, budget?:NativeImportEstimate`。只在 succeeded 且 result.success 时继续原导入发布流程。取消/失败不返回几何，不替换 native `g_layout/g_lastParseResult`。当前可取消导入只支持 GDSII/OASIS；CIF/DXF 继续现有入口且不得展示“后台可取消”承诺。quickScan 不发布文档，OASIS 仍完整扫描记录并读取文件缓冲；不是按需 viewer。

`DrcBackgroundResult`：`status,message,documentId,inputVersion,result?:DrcResult,rules:DrcRule[],scopeText`。完成后先检查 documentId + inputVersion 仍与活动文档一致，才调用 `drcService.acceptBackgroundResult(output)` 并更新面板；旧版本结果应保留来源提示或拒绝，不能挂到新输入。取消/失败不清除上一次有效 DRC 结果。native 对传入快照独立建模，后台运行不持有全局 layout mutex。

后台内核未映射规则不转入阻塞 JS 回退，而显示完整性告警；分块设置尚未应用时同样告警。scopeBox 按与范围相交的完整图形检查，范围外邻居/边界规则覆盖不完整，会阻止 passed；默认不传 scopeBox 可完整检查所选 Cell 深度内的受支持预检查规则。

## Index 状态与取消入口

增加 `activeNativeJobId/activeNativeJobScope/nativeJobStage/nativeJobCount/nativeJobCancelRequested` 与一个轮询 timer（建议 150–250ms）。导入和 DRC 共享工作条可显示阶段、计数、取消按钮；null handle 显示启动失败。completion 的 finally 清 timer 和 active id，切换文档 / 页面销毁请求 cancel，检查 id+scope 一致才清当前作业状态。不要在旧作业 finally 中清除新作业。

DRC 启动传当前 `NativeRenderSnapshot`（现有 render 快照已给出 cellNames + shapes + topCellId）。输入版本必须启动时捕获，不能完成时重新读取当成来源。只有 accepted background result 再调用现有刷新分组、定位面板逻辑。

## 预算与向导

`NativeImportEstimate`：`storedShapes, coordinates, instanceRecords, arrayMembers, expandedObjects, expandedPlacements, geometryBytes, bounded, withinBudget,message`。
展开数量是最大 Cell 的分析展开成本，不表示实际存储对象；规则 AREF 仍保留。storedShapes ≤100 万、coordinates ≤400 万、expandedObjects ≤100 万为交互发布预算。geometryBytes 仅 `storedShapes*256 + coordinates*16` 粗估几何载荷，不包含整个 OAS 文件缓冲、属性/名称、索引、JS 对象和运行时；不保证峰值内存。

现有 `OpenWizardDialog` 新增可选 props：`storedShapes=-1, coordinateCount=-1, expandedPlacements=-1, geometryBytes=-1, budgetMessage=''`。已移除“查看更低内存更快”“编辑必展开10倍”文案；两模式解析器相同，区别为修改权限。尚未有预算时显示默认文案，不能由文件 MB 推出图形数或必需 RAM。

## 边界

解析、预算、建模、DRC 循环、递归/阵列、OAS 解压均接实际取消 checkpoint。单次分配、文件系统 read、R-Tree 构造及第三方几何/布尔函数仍需该调用返回后才能观察取消。NAPI 开始时读取 JS 快照、完成时生成 JS 对象仍在主线程；不是零主线程成本，也不是低内存/按需读取架构。

## 当前已验证

生产文件已 freeze。OHOS clang 对完整 napi_init_v2.cpp 做 -fsyntax-only 通过；DRC 宿主 106/106（包含 5 个新增后台快照/取消/接受/未映射规则案例）；run_native_jobs_smoke.ps1 的 MSVC 实际 production worker 7/7 通过。Native worker fixture 提取当前 NativeJobExecute 与 BuildSceneLayoutFromParseResult 真代码执行，覆盖 GDS/OAS 中途取消、成功 staging、DRC 中止、分析预算、空阵列取消。测试未执行设备侧 NAPI completion，因此 HAP/设备验收由 root 统一进行。

run_native_smoke.ps1 已接独立 run_native_jobs_smoke.ps1（OutputRoot/native_jobs）及 scope/control 案例，check_all.sh 要求两个完成标识并使用实际 [PASS] 条目计数；不新增未经实测的总数声明。

校验补批也已 freeze：CRC 表使用线程安全 const static 初始化，OAS END CRC/checksum 每 4096 字节检查取消。8 线程首次 CRC 计算均匹配 IEEE 参考值 CBF43926，checksum32 的 123456789=477；两算法的百万字节输入都在第 3 次 checkpoint 中断。native_checksum_cancel_smoke 已加入两套 runner 的必达完成标识；writer 原双参调用保持兼容。

新增实际 direct ReadJobRules 案例接受已实现 type9，明确拒绝10/11；旧同步接口未变。MSVC worker/direct parser 共7项通过。check_all.sh 强制该7项及control/checksum完成标识；已规范LF，bash -n exit0。完整 check_scripts.ps1 在 check_all.sh 规范 LF 后 exit0，script parse check passed。输出中的 BASH FAIL 前缀也会用于无关 WSL localhost stderr warning，实际 fail 变量只按非0退出码判断，本次所有脚本语法检查通过。

portable/CI 补齐实际 fixture staging：prepare_native_jobs_fixture.py 由 check_portable.sh 和 run_smoke.sh 调用，精确抽取当前生产 scene builder、worker 与 direct rule parser。Windows/MSVC 和 WSL Ubuntu g++13 均实际运行同7项通过；OHOS aarch64 + libc++ 对此 fixture 语法检查通过。Linux runner 同时接 control/checksum 回归，未用 stub worker 绕过 missing include。
