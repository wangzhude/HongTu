# AI 会话窗口与官方压缩接线

本轮生产改动：`entry/src/main/ets/services/AiContextBudget.ets`、`AiHarnessService.ets`、`python/hongtu/assistant.py`。配置模型与会话保存归 editing；Index 与原生压缩提交归 root/automation。本记录不代表新 HAP 或真实模型验收已完成。

## 原生接口

```ts
buildAiContextBudget(history, context, prompt, config, summary?: string): AiContextBudget
aiHarnessService.run(prompt, context, config, history, availableTabs, callbacks,
  requiredValidationProfile?, sessionId?: string, summary?: string): Promise<AiHarnessResult>
aiHarnessService.compress(history, config, conversationId, callbacks): Promise<AiHarnessResult>
```

`AiContextBudget` 返回 `estimatedInputTokens`、`estimatedTotalTokens`、`contextWindowTokens`、`reservedOutputTokens`、`systemReserveTokens`、`availableInputTokens`、`threshold`、`shouldCompress`、`exceedsWindow`、`historyMessageCount` 和完整 `messages`。UTF-8/CJK 启发式是预估，不是 provider tokenizer 或账单 token。普通请求预留系统/工具 6000 token，压缩预留 1500，输出严格预留配置的 `maxTokens`。窗口默认 32768，阈值默认 0.8；窗口范围 8192..2097152，阈值 0.5..0.95，输出范围 128..65536。系统与输出预留不能耗尽窗口。

正常发送保留所有提供的 user/assistant 历史和完整消息，不再截最近 12 条或每条 16000 字符。历史工具记录及 `commandStatus` 被附为资料；不发送历史 system 或隐藏 reasoning。若整个请求放不下，抛带 `AiContextBudgetExceeded:` 前缀的错误；HTTP 512 KiB 上限也明确拒绝，不默默删原文。

压缩输入应为旧摘要加未覆盖旧历史；root 保留最近消息并负责成功后更新覆盖索引。不能重建成只有 `role/content/timestamp` 而丢失实际 `commandStatus/tools`。自动压缩由原生基于 `shouldCompress` 发起同一个官方压缩接口。服务不在正常工具回合中另行偷偷更改原生历史。

`compress` 按完整消息分块，最多 8 次，每次调用下述官方 SDK 压缩；前一完整摘要作为下一块低信任资料。单条过长或超过 8 块则整个操作失败，原文不变。`result.text` 仅为最终完整摘要；块间 `onText/onReasoning` 是真实流式过程，可展示但不可作为提交成功的依据。最终摘要最多 6000 字符，`tools/artifacts/commandsJson` 必须为空。取消共享 `cancel()` 与 busy/serial 防晚到机制。

## 官方 SDK 复用与范围

服务使用安装的 Pydantic AI Harness `SummarizingCompaction` + `compact_now`，`keep_messages=0`、`preserve_first_user_message=False`，由其内部专用 Agent 请求真实摘要。固定中文指令只规定版图会话事实、已完成/真实失败、未完成项与 PDK 边界。摘要 Agent 没有绘图/编辑/规划工具。`event_stream_handler` 将真实 SDK 事件交给官方 `AGUIEventStream`，保留 REASONING/TEXT/RUN_FINISHED；只有完整响应才结束成功。

SDK 返回的 `SystemPromptPart` 摘要包装不会回灌正常绘图 Agent。原生传入 `forwardedProps.conversationSummary` 后，服务将摘要作为明确标注的 user 参考资料。相关官方说明：[Compaction](https://pydantic.dev/docs/ai/harness/compaction/)。本轮没有并行接入 SQLite 会话库，避免与原生 OS 持久化的清空、覆盖索引、会话切换发生重复。

`forwardedProps.runKind='compression'` 进入完全独立的压缩分支，不能携带绘图容量/强制几何验证配置；正常省略时兼容 layout。`threadId` 使用真正 conversationId，不再使用全局固定字符串。

`ModelConfig.maxTokens` 与 `timeoutMs` 原样传给官方模型客户端/模型请求，取消过去 8192..16384 和固定 120 秒的隐式覆盖。`timeoutMs` 合法 1000..180000；整个 SDK run 仍有明确 180 秒总上限。因此保存的 2048 现在就代表真实输出预算 2048，不能以旧服务曾偷偷提高预算来推断新行为。

真实设备随后发现极短历史会被旧摘要提示扩写。固定中文提示现要求只保留源文实际出现的信息，未涉及的类别完全省略，短历史优先一至三句，不补写“未知/未涉及PDK”章节。仅官方 SDK **压缩子任务**使用 `model_settings.max_tokens=min(config.maxTokens,max(1024,min(1500,ceil(sourceEstimatedTokens*0.4))))`，为 provider reasoning 保留余量，同时不超过用户输出设置；安装版本没有 `targetTokens` 参数。普通绘图/问答请求仍原样尊重配置。只有 root 比较完整有效历史估算后确认 `after < before` 才应提交摘要；变长、截断或失败都保留原文及原压缩记录。没有禁用供应商 thinking 或接受不完整摘要。

## 用量事件与资料排除

```ts
export interface HarnessContextUsage {
  usedTokens: number;
  windowTokens: number;
  fraction: number;
  estimated: boolean; // 当前始终 true
  basis: 'heuristic' | 'provider_anchored';
  windowSource: 'configured';
}
// AiHarnessCallbacks.onContextUsage?: (usage: HarnessContextUsage) => void
// AiHarnessResult.contextUsage?: HarnessContextUsage
```

由官方 `ReportContextUsage` 产生、应用监听后发 `CUSTOM hongtu.context_usage`。`provider_anchored` 表示官方估算使用之前 provider 用量作锚，后续新增内容依然估算，不能标为精确实测。窗口为用户配置，不声称已探测模型真实容量。普通请求与压缩请求均支持。

`layoutContextIncluded=false` 服务端会清掉版图资料，并明确提示占位 0/空数组不代表空版图，不能用于验证；`selectionContextIncluded=false` 会清选区资料，并提示不能据此推断未选择。两标记只接受布尔值，且固定系统规则承认这个信息边界。

## 回归与部署

`tools/ai_harness_host_check.mjs` 直接执行实际 service/helper：38/38 通过，新增覆盖完整历史、会话 ID、预算、UTF-8/CJK、真实用量元数据、分段、8 段超限、超长单消息、取消和禁止压缩结果带工具/产物。`python/tests/test_assistant.py` 最新 42/42 通过，覆盖官方 compact_now 的真实 SDK 模型/流事件、OpenAI HTTP fixture（正常 stop 与截断 length）和最新简洁摘要提示及子任务预算。助手 HTTP 生命周期套件 10/10 通过。这些是本机确定性 SDK/HTTP fixture，没有调用真实远程模型，不能替代设备压缩验收。

最新日志：`artifacts/ai-autodraw-20260930/assistant-sessions-context-final-native-host.log`、`assistant-sessions-context-final-sdk.log`、`assistant-sessions-context-final-http.log`，汇总为 `assistant-sessions-context-targeted-summary.json`。原有 check_all 已包含这两个 Python 测试入口，无新增 gate 条目。本轮全量门禁因另会话尚未冻结的 PCell 文档计数和 quantization NAPI 接线停止；上述定向结果不是全量门禁通过。peer 对队列取消、完整分块、原文保留做过只读复核，没有发现此层确定阻断。

最新 AI 专项汇总另核对 Index 工作流 67/67、批处理 12/12、会话管理面板 19/19、会话存储 19/19 的实际日志；总计为独立执行的 7 套、207 项（5 套 host 155 项及 2 套 Python 52 项），包含上述原 90 项，不重复相加。typed `AiCompressionNotBeneficialError` 的自动分支仅在原有效历史仍能容纳于窗口时保留原文继续普通请求；手动压缩仍拒绝应用无收益摘要，网络、取消、上下文变更和真正窗口超限仍失败。统一 gate 的 attempt1/attempt2 均为 exit1，后续完整 gate 由并行功能批次收尾；当前记录不宣称 GDS/OASIS、NDK 或最终 HAP 在本轮 gate 中通过。

**部署需要 root 重启自有 7865 伴随服务**：`assistant.py` 是父服务导入缓存，不能因为磁盘代码更新便宣称当前常驻服务已生效。本代理未重启服务、未操作设备、未做全局 HAP 构建。真实模型压缩、会话切换/取消以及最终 HAP 的设备验收仍交 root。
