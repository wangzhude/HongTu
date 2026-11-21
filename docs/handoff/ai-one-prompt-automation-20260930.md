# 主聊天开源 Harness 接线与宿主回归（2026-09-30）

本文件记录当前实现。先前的客户端电路判路由与最多两次脚本修复循环已被主聊天移除。旧的 32 项测试日志保留在 `artifacts/ai-one-prompt-20260930/`，不作为新 SDK 链路计数。

## 当前用户路径

真实 provider 的全部主聊天需求均经 `Index.handleAiPromptFull()` → `AiHarnessService.run()` → 官方 Pydantic AI Harness / AG-UI 服务。客户端不以关键词替代 SDK 工具路由、不自建修复循环。DEMO 保留原本地演示路径并明确标识；手动 Python 面板保持原服务。

同一个实时助手气泡显示实际正文；只有收到真实 reasoning 才显示可展开的思考，新请求默认折叠。工具卡显示实际名称、运行中/已完成/失败状态，展开查看参数和结果；相同 ID 的更新替换原卡片，渲染键包含完整内容，避免同长度结果更新丢失。桌面及紧凑布局均接入正文、思考、工具、取消与待确认卡片。发送/取消继续受同一 inflight 状态控制。

- 纯回答保存正文、真实思考、工具轨迹，不显示“命令已执行”。
- `commandsJson` 由实际 `AiService.parseText()` 解析后进入现有预览确认，历史先标 pending；无效 JSON 不回退成本地演示命令。
- 单个 artifact 经认证接口下载，校验下载脚本与事件清单一致、原始需求与本请求一致，再原子载入独立新标签、运行当前规则检查并适配画布。原稿及撤销历史保留。多产物和 commands/artifact 混合结果在下载前防御性拒绝；工具完成不等于已载入。

明确且单独的反相器创建动作仅正向传入 `run()` 最后一个参数 `requiredValidationProfile: generic_inverter`，不据此改写 SDK 路由。解释、否定或包含其他电路的需求不误用专用约束；下载的显式反相器产物缺该 profile 时拒绝发布。简化 CMOS 一致性检查不是完整电气正确、foundry DRC/LVS 或签核；历史有接线问题的 32 图元模型产物保留，不追认为正确。

## 上下文与持久化

请求序号、文档 ID、revision、Cell、选区、layer/datatype、编辑模式与 workspaceReady 贯穿 SDK、下载、native parse 三次 await，每次完成及流式回调均检查。取消 SDK 调用 `aiHarnessService.cancel()`，下载时调用 `pythonBridgeService.cancelGeneration()`；native parse 期间拒绝后续发布。取消后持有发送锁直至 Promise 收尾，保留已收到的真实流内容到失败历史。

满八标签仍可问答，产物新建则拒绝；下载及载入前再次检查容量。`applyPythonResult()` 校验完整 WorkspaceDocument、native 激活成功后才发布，失败恢复当前 native snapshot。命名/空图层、Cell/库属性、旧 artifact 兼容与文档模式脚本的层样式保护延续。

`AiService.recordHarnessResult(prompt,text,reasoning,tools,success,commandStatus?)` 一次保存用户和助手消息、独立拷贝工具快照；更新命令状态保留 reasoning/tools，重新创建服务可以从持久化历史恢复。

成功下载的 artifact、完整脚本和原始需求进入 Python 运行历史；只有用户未打开编辑器、未改草稿时才更新 Python 编辑草稿。下载后取消/上下文变化/载入失败仍保留可复查 artifact，消息明确未载入。SDK 产物生成前失败不会伪造 Python 脚本或空运行历史，错误和真实工具记录保存在聊天。历史/草稿存储故障仅追加提示，不把已发布文档改报失败。

DRC 文案区分 errors、warnings 和完整性提示；没有执行规则时明确说明未检查、不能判定通过。验证区展开后的实际 viewport 回调触发一秒内有限窗口重新适配；尺寸不变也在下一事件循环适配。文档、请求或用户视图变化使待适配失效。

## 当前宿主证据

以下均为本轮重跑且退出码为 0：

| 测试入口 | 项数 | 日志 |
| --- | ---: | --- |
| `index_ai_circuit_host_check.mjs`（现为 SDK 工作流） | 42 | [主聊天工作流、实时绑定与运行步骤](../../artifacts/ai-autodraw-20260930/index-runtime-timeline-host.log) |
| `index_ai_batch_host_check.mjs` | 10 | [原子命令批量](../../artifacts/ai-harness-20260930/index-ai-batch-host.log) |
| `index_workspace_host_check.mjs` | 51 | [工作区与 Cell](../../artifacts/ai-harness-20260930/index-workspace-host.log) |
| `ai_generation_host_check.mjs` | 19 | [既有服务兼容](../../artifacts/ai-harness-20260930/ai-generation-host.log) |
| `ai_datatype_host_check.mjs` | 16 | [精确 layer/datatype](../../artifacts/ai-harness-20260930/ai-datatype-host.log) |
| `python_panel_workflow_host_check.mjs` | 7 | [手动 Python 流程](../../artifacts/ai-harness-20260930/python-panel-workflow-host.log) |

主聊天现 42 项使用实际 Index、AiService JSON/历史、EditService、WorkspaceService、PythonWorkspaceService、图层默认、画布 fit 与 Python 面板生命周期。网络/native I/O 和 SDK 调用边界替换为契约回调，不冒称执行了官方 SDK。组件发送、折叠/展开、气泡数据和新请求重置执行实际方法，实时 Builder 的绑定表达式与运行步骤/计划数据另有专项；两个布局 Builder 可达性另作静态断言，不冒充 ArkUI 渲染。官方 AG-UI 事件解码、Python SDK/工具执行和下载由 root、editing、engineering 各自专项证明。

覆盖三个 await 的八类上下文变化、三个阶段取消、容量并发、无自造重试、manifest/原始需求/profile 保护、空结果/元数据/native 拒绝、JSON 待确认、正文与思考工具持久重开、用户草稿保护与存储故障。原有批量回滚、一次撤销、DRC、跨文档保护继续通过；统一 gate 沿用原测试入口。

本代理未操作设备或运行共享 HAP 构建。真实模型流式 UI、出图与图层、工具事件/取消、保存重开和质量检查以 root 的本轮设备及独立产物证据为准；这些宿主回归不代表工艺签核。


## 最终接线复核补充

再次只读核对真实事件链：没有 REASONING_MESSAGE_CONTENT 的 provider 会保留空 reasoning，UI 不显示思考按钮；TEXT_MESSAGE_CONTENT 每段经回调追加到 @State，再由两个布局相同气泡展示。取消按独占的当前阶段中断 SDK 或 artifact 请求，finally 清掉加载/取消标志和所有临时正文、思考、工具状态；由于两个阶段顺序执行，不会同时取消共享手动 Python 请求。native parse 的取消仅阻止发布。当前 32 项专项仍覆盖这三阶段取消和迟到结果。

发现并已修 Index 的两处旧显示口径：runDrc 的 toast 与命令执行后的复检文本现在与最终 AI 结果共用 errors/warnings/完整性提示和 executedRules 口径。新增实际 runDrc 方法回归（零规则、仅警告、错误与警告并存），不再将提示行数称作违规数；原子批量测试也断言无规则后的消息不称 1 项违规。随后长正文 UI 回归加入后，现 SDK 工作流 32、原子批量 10 项再次退出 0，原列六套合计 135 项。

真实 SDK ModelRetry 事件另存 [sdk-modelretry-fixture.json](../../artifacts/ai-harness-20260930/sdk-modelretry-fixture.json)：实际官方 AGUIAdapter/FunctionModel 调用实际脚本策略，拒绝 import os，未联网或执行 worker。官方 RetryPromptPart.model_response() 给 JSON 错误追加固定英文重试尾句；原客户端 JSON.parse 整段会失败，从而误标 completed。这一确定发现已交 root 修 AiHarnessService 并补官方事件回归，不能用旧裸 JSON fixture 代替。模型/设备端到端状态以 root 新证据为准，本复核未宣称已经通过真实模型出图。


真实设备长回复截图 `artifacts/ai-autodraw-20260930/sdk-live-stream.jpeg` 暴露重复完成正文：ChatMessage 后又无条件显示相同 lastResult，自动滚到底会停在第二遍长正文，思考/工具卡被滚到上方。两个布局已改为仅在没有历史且没有实时气泡时显示 lastResult 兼容文本；AI 撤销入口独立保留。Index 状态栏改为短业务摘要，完整回答继续在唯一聊天消息中保存。新 32 项回归验证长正文完整保存、状态小于 200 字、fallback 与两布局撤销可达；不得把宿主断言称作这次 UI 修补已经完成设备验证，root 负责安装后复核。

ModelRetry 状态修复现已由 root 写入 AiHarnessService，JSON 与非 JSON 官方 RetryPromptPart 尾句都有专项。此处保留发现经过与真实 fixture，最终工具卡可见性仍以 root 新包为准。


## 原生 Markdown 渲染接线

用户指出模型回复仍显示 Markdown 标记后，root 选择 `@luvi/lv-markdown-in` 精确版本 3.4.7；依赖安装、许可证和包来源由 editing 负责。新增 `AiMarkdownBody` 仅封装官方 `Markdown` / `MarkdownController`，没有自写 Markdown 解析器或 WebView。

助手正文和展开的 reasoning 使用原生 renderer。工具参数/结果只作 JSON 缩进排版或原文代码块包裹，原始工具记录不变；代码中包含 fence 时选择更长 fence，不能逃逸为伪造的 Markdown 工具结果。普通用户消息仍用小型原生 Text。现成标题、段落、列表、表格、inline/fenced code 解析来自依赖；表格横向 List 与代码横向 Scroll 的库源码/API 由 editing 审核，实际排版仍需设备证明。

wrapper 每 64ms 合并流式内容，完成时立即 flush，卸载取消 timer；同一个 controller 保持不变。工具 ForEach 使用稳定 tool ID，显示字段从当前 live @Prop 数组读取，避免每段 token 都销毁代码 renderer。完成消息仍仅显示一个聊天气泡，fallback 与 AI 撤销保护延续。

按现有 COLORS/UI 配置正文、标题、引用、表格和代码主题。代码复制接系统剪贴板并反馈成功/失败。HTML 预览、预览 JavaScript、Mermaid、预热 Web 池全部显式关闭；图片加载代理返回空值、图片/链接点击被拦截。库的 `$rawfile(` 图片特殊路径早于代理识别，因此仅在渲染副本中插入零宽分隔；聊天持久化不改，工具代码复制使用未改动的完整缩进文本，包含该特殊字串的 JSON 值也可精确复制。

新增 `tools/ai_markdown_host_check.mjs` 已加入统一入口，12 项通过，日志 [ai-markdown-wrapper-host.log](../../artifacts/ai-harness-20260930/ai-markdown-wrapper-host.log)。测试执行实际 wrapper 生命周期、节流/flush/卸载、installed controller API 名称、安全配置、代码/JSON保真、复制成功失败，以及正文/思考/工具接线与稳定 ID；不把 mock controller 称作原生视觉验证。主聊天工作流 32 项再次通过。此时原列六套 135 项加 wrapper 12 项合计 147 项，不含 root transport 与 editing 安装/来源专项，避免重复计数。

本代理的生产源码已冻结。root 统一构建并验证标题、粗体、列表、表格、代码复制/横滚、长回复与展开思考/工具；这里不宣称宿主通过等于这些设备行为已通过。

### 首次空白截图的只读复核

`markdown-first-rendered.jpeg` 中用户 Text 已出现，助手 Markdown 仅剩空气泡内边距。截图约为打开面板后的 1–2 秒，随后 root 观察到本机模拟器进程退出；现有证据不能断言空白持续，也不能把模拟器退出归因于 renderer。

本次使用本地 SDK `ark_disasm.exe` 检查实际安装的 **3.4.7 HAR** `ets/modules.abc`（SHA-256 `C81F1C25037F825CF6BA96638BA06420416E2927180DA47F61B3E47EDEE0B546`），结果保存为 [markdown-3.4.7-disassembly.txt](../../artifacts/ai-autodraw-20260930/markdown-3.4.7-disassembly.txt)，没有把公开 3.4.6 source snapshot 当作 3.4.7 的实现证明。

- wrapper 在 `aboutToAppear` 同步配置 controller 并 flush 当前正文；HAR 构造器为 `text` 注册 `_parseMarkdown` watcher（反汇编 72263 附近），`aboutToAppear` 也主动调用 `handleLodeType → _parseMarkdown`（72845 / 76025）。没有发现首个 @Prop 必须变更才开始解析的缺口。
- 实际 controller 默认 `threadRenderEnable=true`、`lazyRender=false`（54846–54849）。后台为共享单例 WorkerManager，不是每条消息创建一个 Worker。Hvigor 的 release `compileContextInfo.json` 已列入 `&@luvi/lv-markdown-in/src/main/ets/workers/worker&3.4.7`，不能称 Worker 被漏打包。
- 确认一个失效处理缺口：`_parseMarkdown` 先置 `parseInFlight=true` 再发 worker 消息（72647）；worker 分支没有 catch 或回复超时。`createWorker` 只设置 `onmessage` / `onmessageerror`，后者仅记录日志，没有 `onerror` 恢复（100498）。因此线程若未成功回包，当前气泡可以保持空白，后续更新只标记 pending；这是代码支持的失效路径，尚无本次 hilog 证明它被触发。
- worker 内部语法解析异常会回 `error:true`，但 `handleWorkerMessage` 只跳过渲染并 `onParseSettled`（76403），未把该错误转发给外部 `callback.fail`。仅给 wrapper 加 fail callback 不足以覆盖此分支。

只读复核后 wrapper 宿主仍为 12 项通过，未修改生产文件。建议 root 恢复独占设备后抓取 `LV-MARKDOWN-IN` / worker 启动日志；若需控制变量对照，可在首次渲染前显式调用官方 `setThreadRenderEnable(false)`，继续使用 HAR 自有 MainReader 与原生组件。该对照尚未实施，不能据此宣布修复或视觉通过。

### 冷启动后的真实渲染证据

root 保留 userdata 冷启动自有 `HongTuWorkflow_20260930`，核验 `127.0.0.1:5555` 为 API 24 / 2in1 后复现。本代理仅通过 HDC 读取日志，不操作 UI；应用 PID 7502 保持存活，筛选日志在 23:21:38 记录到 10 次实际 Markdown `aboutToAppear` 的 `Thank you for using`。本次未捕获该进程的 Worker、JS 崩溃或解析异常；普通解析耗时日志在库的 release 构建中默认不输出，不能仅凭没有错误认定解析完成。只保存白名单筛选结果 [markdown-restored-filtered-hilog.log](../../artifacts/ai-autodraw-20260930/markdown-restored-filtered-hilog.log)，未输出或保存原始 HTTP / 凭据。

随后 root 实际截图 [markdown-scroll-later.jpeg](../../artifacts/ai-autodraw-20260930/markdown-scroll-later.jpeg) 已显示原生表格、编号列表、Python 语法高亮代码块、链接和引用，底部也有 `查看思考` 控件。本代理已独立查看该截图，并在 [markdown-sample-rendered-tree.json](../../artifacts/ai-autodraw-20260930/markdown-sample-rendered-tree.json) 核对相应内容。这证实当前默认 Worker 模式可以完成真实内容渲染，**不需要关闭 Worker**，没有实施上述对照或其他生产修改。

最初空气泡可能属于异步首帧尚未完成，且当时同时发生宿主模拟器整体退出；目前没有故障因果证据，不能把它记为已定位的 renderer Bug，也不能将潜在 Worker 失效路径当成本次原因。代码复制、横向滚动及新的实时流式内容仍由 root 分别验收；本节只确认截图中已出现的渲染结果。

### 实时消息首次只有思考的绑定修复

后续 60 行表格实时测试与先前首次空气泡是两个不同观察：[markdown-stream-proof-2.jpeg](../../artifacts/ai-autodraw-20260930/markdown-stream-proof-2.jpeg) 在生成中只显示 AI 标签与思考按钮，连正文气泡背景都不存在。单独 HTTP 探针收到正文增量不能替代这一次设备事件记录；同时，此 UI 特征提示正文组件尚未创建，不能仅归因于后台 Markdown 解析耗时。

实际 release 编译产物确认应用绑定缺口：`ChatMessageRow(this.liveAssistantMessage())` 将临时对象传入普通 Builder；子 `If`、Markdown paramsLambda、reasoning 参数、工具 ForEach 均闭包捕获第一次 `msg`。首次只有 reasoning 时，`msg.content=''`，后续保持 live 条件为真不会重建整个分支，子表达式也未直接读取流式 @Prop。旧编译方法已保存 [markdown-live-snapshot-before-compiled.txt](../../artifacts/ai-autodraw-20260930/markdown-live-snapshot-before-compiled.txt)。此前 ToolCard 的 latest lookup 只能刷新已经存在的工具，不能解决空数组首次未创建工具的问题。

现在两个布局使用无参数 `LiveAssistantRow()`：正文可见性与内容直接读 `streamingText`，思考可见性与内容直接读 `reasoningText`，工具 ForEach 直接读 `toolCalls`，每张既有卡片继续通过稳定 ID 读取最新状态。移除临时 `liveAssistantMessage` 快照；历史消息仍用原 ChatMessageRow，折叠、完整历史与用户 Text 保持原行为。未改 Markdown wrapper、Worker 模式或 Index，便于 root 用同一真实流式请求独立判断此修补。

主聊天实际方法及源码绑定回归现 34 项通过，新增用持续存在的绑定闭包验证「先思考、后正文、新工具与完成状态」以及「先正文、后思考、完成清临时内容」。代理记录初次空正文时表达式确实读取三个可观察字段，后续更新无需重建快照。测试未运行 ArkUI 调度，不冒称设备流式验收。既有 wrapper/链接 16 项也通过；root 统一构建并负责实际 partial UI 验证。

另一个已确认但尚不能认定本次触发的库内部路径：HAR `handleWorkerMessage` 先安排 `renderTreeNodeWithLatex` 的 Promise 绘制，再同步 `onParseSettled → _parseMarkdown`。若存在 pending，新解析递增 ID 会令前一个 Promise 绘制作废，持续快更新可饥饿至停流。官方 `callback.complete` 在该版本来自根 Stack.onAppear，不能当作每次解析 ACK。当前没有同时修改解析模式；仅当直接绑定修复后的设备证据仍指向该路径，再评估实时实例使用官方 MainReader 及大文本刷新频率，历史 Worker 保留。

### 逐步运行与真实计划

用户进一步要求像 Codex 一样在运行时逐步显示。面板现将实时工具步骤置于回复正文之前，真实工具开始时即可显示原生 LoadingProgress、中文动作、状态与连接线；已有步骤继续按 ID 读取最新 live @Prop，完成与失败不等整轮结束才更新。参数和结果默认折叠，点击才显示原始详情。历史保存的同一工具记录继续可查看；历史中未结束的 running 记录标为“未完成”，不会假装仍在运行。

中文标题覆盖读取版图、绘制反相器、执行脚本、提出修改和官方计划工具；未知名称原样保留。root 加入同一数组的“下载并校验版图 / 解析图形与图层 / 打开独立版图 / 检查当前规则”仅在真实阶段开始出现，面板显示其简短实际结果，保留“无规则未执行”的边界。待确认修改明确需要应用前确认，工具完成不等于已应用命令。

官方 Planning 此版实际使用 `write_plan / read_plan / update_task_status`。从真实 AG-UI 记录只摘出 8 条计划工具结果及参数，保存在 [assistant_plan_tool_events.json](../../tools/fixtures/assistant_plan_tool_events.json)，没有复制 reasoning 或 provider 凭据。计划 checklist 仅接受完整返回的 header、连续编号、状态符号与相符 footer 计数；截断、多行歧义、重复 ID、普通工具伪装或数量不一致均降级为可展开原始详情。只有 `Updated step '…' status to '…'.` 的成功返回且任务内容唯一匹配，才更新那个计划状态；参数中提出 completed 不算成功。真实模型曾猜错 ID 返回 `Step with id '1' not found.`，面板会将这一步显示为失败并保留原计划。取消、受阻、待执行与完成分别显示，不自动补齐或推断完成。

本次合并回归为 42 项：此前 34 项、root 本地实际阶段 3 项、本代理运行步骤及计划 5 项；日志为 [index-runtime-timeline-host.log](../../artifacts/ai-autodraw-20260930/index-runtime-timeline-host.log)。wrapper / 链接 16 项兼容回归也通过。无数据模型扩展，无 Markdown Worker 模式变更；生产仅改本代理持有的 WorkbenchOverlays，root 独立持有 Index 阶段接线。源码已冻结，构建及真实动态步骤效果由 root 统一验收。
