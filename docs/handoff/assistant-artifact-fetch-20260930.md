# Assistant artifact fetch bridge

`pythonBridgeService.loadAssistantArtifact(artifactId, context): Promise<PythonLayoutArtifact>` is ready for the new SDK event path. The method reads only the existing Python bridge endpoint and token, and never loads the model API key.

- GET `/v1/assistant/artifacts/<id>` with Authorization; connect timeout 5 seconds, read timeout 25 seconds, response limit 14 MiB.
- IDs must contain 16–64 hex/hyphen characters with hex at both ends. The server currently generates 32 lowercase hex. Reply `artifactId` must equal the requested ID.
- 404 and 410 produce “助手产物已过期或不存在，请重新生成”; 401/429 and malformed/failed replies remain explicit failures.
- Script must be nonempty and at most 65536 UTF-8 bytes; original request must be nonempty and at most 16000 characters/65536 UTF-8 bytes. The server's stricter 8000-character request limit fits this contract. Optional wire profile is empty or `generic_inverter` only.
- The same private `parseGenerateReply` and `materializeArtifact` functions now serve both POST generation and GET fetch. Both use identical GDS size/record validation, statistics, typed layer metadata, strict-profile attestation and local transaction handling. Partial GDS or UTF-8 SVG writes remove only that transaction's newly created output paths.
- `cancelGeneration()` invalidates this fetch via the existing ticket and destroys its active request. A late reply cannot create files. The existing shared active-operation lock remains held until this request completes or unwinds, so cancellation does not release another operation's lock prematurely.

Returned artifact fields:

- Existing `path`, `name`, `previewPath`, `summary`, `stdout`, `layerDefinitions`, optional `reviewSummary`.
- Optional provenance fields `artifactId`, `script`, `originalRequest`, `validationProfile` (`generic_inverter`). Empty wire profile maps to undefined.
- `inputMode='new'`; `sourceDocumentId` and `sourceRevision` are undefined. The Index caller must retain its own originating-document/revision guard while fetching and loading.

Validation: `tools/python_layer_metadata_host_check.mjs` **19/19** (existing 12 plus 7 artifact cases), output `artifacts/ai-autodraw-20260930/assistant-artifact-bridge-host.log`. Actual production service methods are exercised with isolated HTTP/filesystem mocks; this is not live server/device acceptance. Existing input cleanup host **9/9** also passed. No assistant.py, HTTP owner, Index, model configuration or device state was changed by this patch.
