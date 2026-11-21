# 普通 Python worker 真取消交接

本批实现发生在已验收的 HAP 14 之后。HAP 14 的 AI、会话与压缩证据不能作为本批取消功能的原生验收；本批未重启共享 7865/7863，未操作设备或运行完整 gate。最终统一构建、伴随服务重启和原生交互验收由「评估 KLayout 痛点」会话的统一 owner 安排。

## 协议

- 原 `POST /v1/generate`、`POST /v1/verify` 保持同步、兼容不带 `jobId` 的旧请求。可选 `jobId` 必须为 32 位小写十六进制，一次执行用一个随机 ID；这是控制信封字段，桥接层剥离后才交给既有严格请求校验和 worker。未扩大脚本权限。
- 新能力声明：`/health.capabilities` 包含 `job-cancellation-v1`。新客户端先协商；旧服务只取消等待，明确后台执行尚未确认停止。
- `POST /v1/jobs/<jobId>/cancel`，JSON body 必须为 `{}`，最多 1024 字节。返回直接 `PythonJobStatus` 对象，200 为终态，202 为取消处理中。
- `GET /v1/jobs/<jobId>` 返回直接状态对象；未知或过期为 404。身份验证、Origin 拒绝、Cache-Control 与现有桥接策略一致。
- 新同步回复附带 `jobId` 与 `jobStatus`。状态包含 `jobId`、`state`、`terminal`、`workerStopped`，可选固定简短 `error`。state 为 `starting | running | cancelling | cancelled | succeeded | failed | timed_out`。
- 取消成功回复 `success:false`，生成不携带 GDS/预览；验证为 `complete:false/passed:false` 且无 markers/devices。成功先完成时仍为 `succeeded`，原同步结果保留，不能改写为已取消。

## 生命周期与边界

`JobRegistry` 最多保留 256 条小状态记录，终态保留 300 秒；不驱逐活动任务，也不保存源码、凭据、GDS、临时路径或 PID。终态清除 Popen 引用，避免间接保留 communicate 的完整输入。相同 ID 在保留期内不重新执行。

取消早于原 POST 上传或登记时，创建取消记录，随后同 ID 请求不能启动。普通请求上传设 20 秒总时限，防止慢上传越过取消记录的保留期；Assistant SDK 的流和上传分支不变。

登记先于 Popen，进程创建与 Windows Job 归属绑定由同一锁保护。取消只操作已经持有的进程/Job 句柄，不按用户 PID、进程名或系统命令清理。实际 terminate、wait/reap、输入管道关闭和临时目录退出后，生产请求处理器先释放普通任务锁，再发布终态。目录仍在清理时只能报告 `cancelling`。如果操作系统不能确认 worker 停止，保留非终态和 busy 槽位，不能接受另一个普通 worker 或宣称取消成功。

普通生成/验证沿用原 15/90 秒执行预算。`limits.py`、脚本 policy、worker.py 和 Assistant SDK 实现未由本批修改。Assistant 调用的原 `generate(...)` 不带 control，未加入普通 HTTP job registry；本批不扩称已经终止 Assistant 的内部工具线程。

## 前端 API

保留既有 generate/verify/产物下载入口，增加：

```ts
createOperation(kind: 'generate' | 'verify'): PythonOperationHandle
generate(script, context, options, operation?): Promise<PythonLayoutArtifact>
verify(options, operation?): Promise<PythonVerificationResult>
cancelOperation(operation): Promise<PythonCancellationResult>
```

两个现有面板持有自己的 handle。独立 cancel/status HTTP 不使用原执行请求的 activeRequest；新服务保留同步执行通道以接收“完成先赢”的真实结果。旧的无参数 cancelGeneration 仅处理 legacy 操作/SDK 产物下载，不得中断显式 owned handle。取消只停止当前项及后续扫参，已完成结果可保留原有 history；不修改 PythonWorkspaceService 的 schema。关闭时保存草稿失败仍执行所属任务取消。Index 接口接入交由其 owner，不在本批编辑。

## 文件和验证

后端：`python/hongtu/jobs.py`、`bridge.py`、`verification.py`；新回归 `python/tests/test_job_cancel.py`。

前端：`PythonBridgeService.ets`、现有 `PythonLayoutPanel.ets`、`VerificationPanel.ets`；新增 `tools/python_job_cancellation_host_check.mjs`，并更新四个受影响的现有 host fixture。

后端新回归 **17/17**，8.152 秒，实际临时 HTTP、CPython worker、Windows Job：生成/验证取消和回收、保护无关自建进程、取消后立即执行、启动中取消、清理等待、提前取消、完成先赢、重复 ID、busy、超时、断开连接、失败/慢上传与鉴权边界。日志：`artifacts/ai-autodraw-20260930/python-owned-cancel-http.log`。

必要兼容回归一次 **87/87**，49.277 秒：GeneratedLayouts 14、Workspace 6、Verification 7、Generic CMOS 8、Assistant SDK 42、Assistant HTTP 10。日志：`artifacts/ai-autodraw-20260930/python-owned-cancel-compatibility.log`。合计 Python 104 项，不是完整 gate，也未调用真实远程模型。只读 peer 审核未发现后端确定阻断。

前端生产代码与定向回归已冻结，5 套独立 host 共 **84/84 项通过**：job cancellation 23、Python panel workflow 13、engineering panel context 20、input cleanup 9、layer metadata 19。后加四项直接串联真实 Bridge 与两个 Panel，确认旧服务或取消请求网络失败后，晚到执行 HTTP 异常不会把“未确认/后台可能仍在运行”改成确认停止；原生产代码已在 service 层处理，无须重复面板实现。独立 host 日志：`artifacts/ai-autodraw-20260930/python-owned-cancellation-host-final.log`；前端交接：`docs/handoff/python-owned-cancellation-20261001.md`。

本批独立检查合计 **188 项（Python 104 + host 84）**。机器可读记录和冻结源文件 SHA-256 在 `artifacts/ai-autodraw-20260930/python-owned-cancellation-summary.json`，可用同目录 `summarize-python-owned-cancellation.py` 从实际日志重算。构建/原生验收仍待「评估 KLayout 痛点」会话的统一 owner；不把先前 HAP 14 的结果倒算到新取消代码。

后续完整 gate 需由其 owner 将 `tools/python_job_cancellation_host_check.mjs` 加入 HOST_CHECKS，并将 `test_job_cancel` 加入现有 Python unittest 模块列表。本批未编辑共享 gate，避免并行收尾冲突。
