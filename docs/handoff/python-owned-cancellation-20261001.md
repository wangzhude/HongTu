# 普通 Python / 工艺验证：按任务归属取消

日期：2026-10-01。此记录只说明前端实现与宿主测试；未把宿主结果称为设备验收。本代理没有重启伴随服务、操作设备或构建 HAP。

## 接口与执行规则

- `PythonBridgeService.createOperation('generate' | 'verify')` 生成本地归属句柄和随机 32 位小写十六进制 `jobId`。句柄一次性使用，复制出来的对象不能冒充原归属。
- `generate(script, context, options, operation?)` 与 `verify(options, operation?)` 保持原有无句柄调用兼容。显式句柄请求先检查 `/health` 的 `job-cancellation-v1`，只有服务支持时才发送 `jobId`。
- `cancelOperation(handle)` 只操作该句柄。新服务另发 `POST /v1/jobs/<id>/cancel`，必要时最多三次 `GET /v1/jobs/<id>`；独立请求读超时 15 秒。`terminal` 与 `workerStopped` 都通过校验才显示已停止；状态缺失、身份不符、仍在运行或网络失败均不冒充终止。
- 新服务取消保留原同步生成/验证 HTTP，以处理“执行先完成”的竞争。取消成功不返回可载入产物；执行先成功则仍验证、写入结果。旧服务销毁等待中的请求，并明确说明后台可能仍在运行。
- Index 现有 `cancelGeneration()` 仍同步使无句柄请求与 SDK 产物下载失效，不先等待健康查询或服务端确认。它不能误取消显式面板任务；面板关闭也不能取消其他面板或 SDK 下载。

## 面板生命周期与用户结果

Python 面板每个扫参项独立创建句柄。取消后不启动后续项；执行先完成的当前项仍按真实结果写入既有运行历史，但不自动载入或显示预览。已关闭面板不再更新界面。草稿保存抛错仍在 `finally` 中取消归属任务。执行成功但历史保存失败时保留可载入产物，并显示具体失败，不再把成功执行记录成运行失败。

工艺验证在快照准备阶段取消时不启动验证；发出验证后只取消归属任务。取消后任何迟到结果都不发布标记或报告。如果同步结果证明验证已先完成，会明确说明结果未应用。输入快照始终在本次请求/取消处理结束后清理，输出与历史文件保持不变。

## 实际测试证据

命令均为 `node --experimental-transform-types --disable-warning=ExperimentalWarning <suite>`，载入实际生产类/方法；仅替换设备 HTTP、文件系统及 UI 平台边界。没有以空方法替代取消实现。

| 套件 | 通过项 |
| --- | ---: |
| `tools/python_job_cancellation_host_check.mjs` | 23 |
| `tools/python_panel_workflow_host_check.mjs` | 13 |
| `tools/engineering_panel_context_host_check.mjs` | 20 |
| `tools/python_input_cleanup_host_check.mjs` | 9 |
| `tools/python_layer_metadata_host_check.mjs` | 19 |
| 合计 | 84 |

日志：`artifacts/ai-autodraw-20260930/python-owned-cancellation-host-final.log`，最终运行退出 0。

新增服务套件覆盖：取消前不启动、健康查询中取消、跨句柄/伪造句柄隔离、全局旧入口与显式归属隔离、独立控制 HTTP、重复取消合并、有界非终态轮询、完成先赢、取消先赢、网络失败后迟到真实终态、未回收进程状态拒绝、旧服务格式、终态与任务身份/结果一致性、验证取消、SDK 产物下载同步取消及面板不能误取消下载。面板套件覆盖关闭保存异常、扫参停止、历史真实性、结果未应用与快照清理。

冻结后的独立复核曾提出“晚到 transport 异常可能覆盖取消未确认提示”。追踪实际 Bridge 的 `generate` / `verify` catch 后，确认原实现已经把异常映射到取消结果，因此无需再次修改生产代码。另增四项实际 Bridge → Python/Verification 面板串联测试，分别执行旧服务销毁请求、取消 HTTP 网络失败后原请求迟到异常；最终界面和 Python 历史均保留“取消等待/未确认、后台可能仍在运行”，全部通过。此处不是依赖面板模拟错误来宣称真实链路正确。

后端真实 HTTP / Popen / Windows Job 测试由 engineering 代理维护；以其独立日志与统一门禁结果为准。本记录不将前端传输替身测试解释为真实终止进程或设备上的取消已经验收。

## 源码范围与交接

生产修改仅 `PythonBridgeService.ets`、`PythonLayoutPanel.ets`、`VerificationPanel.ets`。Index、AI SDK、Python 历史 schema、凭据与设备均未更改。新增 job suite 需由统一入口 owner 纳入 `tools/check_all.sh`，其余四套原已在入口中。前端源码与上述测试已冻结并交给“评估 KLayout 痛点”会话的统一 owner，后续由其安排完整门禁、构建与原生交互检查。
