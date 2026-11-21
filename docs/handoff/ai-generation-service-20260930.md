# AI creation service handoff — 2026-09-30

## Scope and contracts

This change owns `AiService.ets`, `AiCommandParser.ets` and the new `tools/ai_generation_host_check.mjs`. It does not edit Index, UI, the Python worker/bridge, device state or build helpers. Existing demo geometry is retained only in explicit demo mode; no reference GDS is imported to impersonate model generation.

- `aiService.isCircuitCreationRequest(prompt: string): boolean` accepts explicit Chinese/English draw/create/generate/build requests for inverter, NAND/NOR, SRAM and transmission gate. Explanations, tutorials, hypotheticals, negatives, deletion and a bare circuit name do not qualify. This is deliberately conservative; it is the caller's gate for automatic circuit generation, not a general language intent guarantee.
- `aiService.recordPythonLayoutResult(request: string, message: string, success: boolean): void` appends one user/assistant pair, with the assistant marked executed/failed, then trims and persists history. The caller invokes it once after its final result and owns stale-document/cancellation policy.
- Existing `generatePythonScript(request, context, onChunk?, inputMode='new')` and `cancelPythonGeneration()` signatures/ownership remain intact. Late replies after cancellation reject and release loading state.

## Behavior

Configured real providers no longer take the six-rectangle local circuit shortcut. Question/negative requests suppress model edit commands; bare circuit names cannot become creation commands. The new-layout Python prompt requires `db.LayerInfo(layer, datatype, name)`, separate meaningful layers, complete generic CMOS geometry including PMOS/NMOS, common gate/input and drain/output, contacts, well/taps, rails and IN/OUT/VDD/VSS text. Without an explicitly chosen PDK it requires an honest generic geometry example, never claims DRC/LVS/electrical/manufacturing success, and forbids reading an existing layout/template/reference file. Document/selection mode preserves the input layout rather than applying new-layout defaults.

The JSON executor rejects non-number/nonfinite numeric values, nonpositive rectangle dimensions or PATH width, invalid point/text payloads, noninteger/out-of-range arrays and nonfinite array endpoints before allocation. Requests are bounded to 256 commands, 10,000 newly created shapes and 100,000 new points; documents are bounded to 1,000,000 shapes and 4,000,000 points. Array axes are 1..1000 and individual point lists are at most 10,000. The model JSON parser rejects macro-internal `batch_operation`; internal macro acknowledgements require an explicit `ok` and nonempty message, and an empty acknowledgement fails.

Existing Index atomic batch rollback remains its own mechanism. Explicit layer metadata publication, automatic result loading, view/state updates and device acceptance are owned by the other agents.

## Evidence and boundaries

- `artifacts/ai-inverter-20260930/ai-generation-host.log`: 19 tests execute actual AiService, DemoParseStrategies, AiCommandParser and EditService, including remote-route choice, negative/question handling, generated prompt delivery, cancellation, result history, malformed geometry rejection without dirty/session changes, aggregate budgets and one-step undo for a valid batch.
- `ai-datatype-host.log`: 16/16 existing AI datatype/selection contracts.
- `macro-scope-host.log`: 9/9 document-scoped macro cases.
- `automation-host.log`: 9/9 automation/template persistence cases.

Network/storage/native UI are isolated in these host tests. They prove dispatch, prompt and execution contracts, not actual model geometry quality, electrical connectivity, device visuals or successful installation. The root task owns the real app request “画一个反相器”, output inspection and final build/device evidence. Index AI batch tests are being updated by the agent that owns the new main-chat routing.

## Real-stream failure follow-up

The root task reported a real 2048-token probe for the same request: HTTP 200, reasoning content but no final content, and `finish_reason=length`. The former stream parser also collected legal `: heartbeat` comments as an error body, masking that diagnosis.

Python generation now requests an exclusive, capped 12,288 output tokens through an optional private transport argument; the user's saved configuration and ordinary chat budget remain unchanged. JSON and SSE transports reject `length`, `content_filter`, tool-call and other abnormal completion reasons even when partial content looks executable. SSE comments and event/id/retry fields are ignored; reasoning is tracked only as a presence flag and never appended to script text. Missing content, reasoning-only replies, API errors, malformed streams and missing terminal markers have separate errors. The Python prompt explicitly rules out private identifiers, decorators, `**`, and nonexistent `hongtu.output`.

`tools/ai_transport_host_check.mjs` executes the actual transport methods with HTTP/SSE event fixtures, rather than replacing `callLLM`. Its 18 cases cover heartbeat/reasoning/content, both completion orderings, UTF-8/JSON fragmentation, tail frames, truncation/filter/tool failures, empty/API errors, cancellation/cleanup and request-only budgets. Log: `artifacts/ai-autodraw-20260930/ai-transport-host.log`. Generation 19/19 and datatype 16/16 were rerun after this patch. These fixtures are not a substitute for the root task's new real-device generation attempt.

## Reasoning and timeout correction after the second real attempt

The root's 12,288-token probe still exhausted the budget in reasoning and took about 50.6 seconds. Read-only inspection found the running 7863 relay is `workbuddy-manager-v1.0.74/.../upstream/wb2api.exe`; its sibling source `internal/upstream/thinking.go:156–185` injects DeepSeek thinking plus high effort by default, but explicitly preserves `thinking.type=disabled` and removes conflicting effort fields. This agrees with the [official DeepSeek thinking-mode protocol](https://api-docs.deepseek.com/guides/thinking_mode/). The root's disabled-mode probe then returned HTTP 200, 4,102 content characters, no reasoning, and a normal stop in about 7.5 seconds. These are the root's separate live probe results, not fixture output.

Only Python requests for recognized OpenAI-compatible DeepSeek V4/flash names (including `cn:` and `global:` prefixes) now send `thinking: {type: 'disabled'}`. Unrelated models, Ollama and ordinary chat receive no vendor-specific field; saved configuration is unchanged. The 12,288 budget was not raised again. Python streaming keeps a 30-second idle timer and 120-second total timer, while setting the underlying HTTP read timeout to 120 seconds so a continuously active stream is not cut at 30 seconds. Nonstream Python requests also use the 120-second deadline. The transport suite is now 21/21, adding vendor scoping, request-body/config independence and actual timer/HTTP-option checks.

The final new-layout prompt also explicitly requires bulk CMOS implant polarity: PMOS active in NWELL covered by PPLUS, NMOS outside NWELL covered by NPLUS, NWELL NPLUS tap to VDD, substrate PPLUS tap to VSS, and no gate crossing through tap active. The generation suite remains 19/19 with these prompt constraints checked. This does not claim a PDK or manufacturing signoff.
