# Official Python agent harness integration

Production entrypoint: `python/hongtu/assistant.py`.

Dependencies are pinned to Pydantic AI Harness 0.52.0, Pydantic AI Slim
`[openai,ag-ui]` 2.52.0, and AG-UI Protocol 0.1.22. Their actual wheel copyright
notices and upstream URLs are retained in `python/THIRD_PARTY_NOTICES.md`.

## HTTP contract

`async encoded_stream(payload: dict)` yields official AG-UI encoded SSE strings.
The HTTP handler owns bearer-token authentication, loopback/origin restrictions,
512 KiB request bounds, heartbeat, cancellation on disconnect and response
headers. The SDK loop receives a 180-second total deadline, at most eight model
requests and sixteen successful tool calls. A tool has a 25-second deadline;
geometry still runs in the existing worker with its 15-second process limit.

Input is the official AG-UI `RunAgentInput`. `forwardedProps` contains:

```json
{
  "modelConfig": {
    "provider": "openai_compatible",
    "endpoint": "http://127.0.0.1:7863/v1/chat/completions",
    "apiKey": "request-memory-only",
    "modelName": "cn:deepseek-v4-flash",
    "temperature": 0.3,
    "maxTokens": 8192,
    "timeoutMs": 120000
  },
  "layoutContext": {
    "layers": [], "currentLayer": 1, "shapeCount": 0, "selectedShape": null
  },
  "availableTabs": 1,
  "originalRequest": "画一个反相器",
  "requiredValidationProfile": "generic_inverter"
}
```

`requiredValidationProfile` is optional and is a trusted native business
constraint, not an agent/router chosen by the model. When set, every geometry
tool must run that fixed validator, and native command proposals are rejected
so they cannot bypass it. All requests still use the real SDK model loop.
The last user message must match `originalRequest` (nonempty, <=16000 chars).
`availableTabs` is an integer 0..8; each run publishes at most one artifact.
Zero slots still permits consultation/native editing, but geometry generation
is rejected before starting the worker.

The module strips model credentials, client-provided tools, state and system
messages from the SDK's run input. The active model client contains request
credentials in RAM and is closed after completion/cancellation. No tracing
exporter is configured. The service may set `PYDANTIC_AI_NO_BANNER=1`.
Literal `localhost` and IPv4/IPv6 loopback endpoints use the official OpenAI
`DefaultAsyncHttpxClient(trust_env=False)` so Windows system proxies cannot
intercept the local relay. Remote endpoints retain the SDK's proxy policy;
hostnames resembling loopback are not treated as literal loopback addresses.

## Tools and official events

The agent uses upstream `Agent`, `Planning`, truncate-only `ToolOutputLimits`,
`AGUIAdapter.run_stream()` and `encode_stream()`. There is no custom intent,
tool-dispatch or retry loop. SDK `ModelRetry` carries bounded tool failures.
The application capability `CompleteModelResponse` rejects length/content
filter/error termination before dispatch; the SDK otherwise executes complete
tool arguments even when their model turn ends with `finish_reason=length`.

- `inspect_layout`: returns the actual, bounded supplied editor summary.
- `create_cmos_inverter`: calls `db.generic_cmos_inverter` in the existing
  worker, with integer dimensions 100..100000 nm and mandatory fixed validation.
- `execute_layout_python`: executes real restricted KLayout code for a new
  layout. It has no access to current-document geometry absent an explicit
  snapshot contract; the summary is not a geometry snapshot.
- `propose_editor_commands`: validates a bounded typed schema and publishes
  pending native operations. Current document identity/revision/readonly and
  atomic application remain the native editor's responsibility. No LLM
  `batch_operation` or shell is accepted.

New-layout artifacts and current-document command proposals are mutually
exclusive in a run, and at most one command batch is published. Generated and pending statuses do not claim native load or
execution. The model's actual `reasoning_content` is exposed through SDK
`ThinkingPartDelta` -> AG-UI `REASONING_MESSAGE_CONTENT`, separate from text and
tool events. DeepSeek's normalized profile handles vendor reasoning replay;
the exact configured wire model ID (including `cn:`) is preserved. Its thinking
mode is explicitly enabled with low effort; other providers are not given
DeepSeek-specific options. Model output is bounded to 8192..16384 tokens.

Official application custom events:

```text
CUSTOM name=hongtu.artifact
value={artifactId,script,originalRequest,summary,validationProfile}

CUSTOM name=hongtu.commands
value={commands:[{type,params,description},...]}
```

`get_artifact(id)` returns a deep copy of the existing worker JSON reply, plus
`artifactId`, `script`, `originalRequest`, `validationProfile`. IDs are random
32-character lowercase hex. Unknown/expired IDs raise `AssistantError` and
should map to 404. This endpoint requires the same bearer token. The full GDS
is never sent in model context, tool cards, or SSE. The in-memory cache expires
after five minutes and holds at most four records and 32 MiB serialized total;
there is no disk model/config or GDS cache here.

## Verification boundary

`python/tests/test_assistant.py` executes installed official SDK TestModel and
FunctionModel loops, official OpenAI SDK HTTP stream fixtures, and actual
restricted KLayout worker subprocesses. It covers native reasoning/text/tool
events and reasoning replay, positive artifact provenance, fixed-validator
bypass rejection, pending commands, cancellation, deadlines, request budgets,
truncation, confidentiality, schema limits and artifact cache limits.

No live model or Harmony device is used by these tests. Host fixtures prove
protocol/SDK/tool behavior, not real model quality or native UI acceptance.
