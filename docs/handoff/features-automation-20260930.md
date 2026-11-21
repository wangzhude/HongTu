# Automation implementation handoff — 2026-09-30

## Status and ownership

AI context/prompt/ID selection, Python isolated document/selection input, personal templates,
bounded parameter sweeps, persistent run history, script import/export and macro manager source
are implemented. Macro management is already reachable from `MacroPanel` via its new custom dialog.
`Index.ets`, editor models and native document integration remain owned by the root task.
Existing dirty changes were preserved; nothing was committed.

## Index wiring: AI

`AiService.ets` exports optional backward-compatible context fields:

```typescript
interface AiCellInfo { id: number; name: string; shapeCount: number; children: number[]; }
interface AiIssueInfo { id: string; rule: string; message: string; x: number; y: number; shapeIds: number[]; }
interface AiNetInfo { name: string; shapeIds: number[]; layerNumbers: number[]; }
// AiSelectedShape adds optional id, cellId, points:Point[], text.
// AiContext adds selectedShapes, currentCell, cells, drcIssues, nets.
```

Populate the fields in `buildAiContext()` from the live document. Bound geometry before copying:
64 selected shapes, e.g. 128 points per shape, 128 cells, 64 DRC issues, 32 networks/256 members per network.
Include `viewport` and `drcSummary`; the prompt now actually consumes both. Do not interpret empty
DRC data as a pass. Network data should state whether it is current and what extraction scope it covers.
Set optional `topCellId` so preview ownership of legacy shapes without `ownerCellId` matches EditService.

`select_shape` accepts `{shapeIds: [id1,id2], focus:true}`. The executor validates every target is live
and selectable in the current Cell before selection. `ViewAction.focusBounds` contains
`{minX,minY,maxX,maxY}`; handle this in `applyViewAction` using the same fit-to-world-box helper as DRC.
The field also survives `AiCommandExecutor.mergeViewActions` for macro playback.
`AiCommandPreview.ets` now projects ID selection/focus without touching services. It validates the
entire requested ID set belongs to the current Cell, rejects stale IDs and NODE metadata, preserves
datatype and all geometry/instance/property metadata when copying, and uses execution's layer defaults.

The model is instructed to select exact IDs, propose the smallest justified edit and append `run_drc`.
For a guaranteed UI workflow, root should recompute DRC after any successfully applied AI edit batch,
using the existing current-document path; retain the existing preview, revision/selection gate and undo.

## Index wiring: Python

`PythonLayoutPanel` adds:

```typescript
documentProvider: (mode: PythonInputMode) => Promise<PythonDocumentInput>;
loadResultAction?: (artifact: PythonLayoutArtifact,
  mode: 'replace' | 'merge', sourceRevision: number) => Promise<boolean>;

interface PythonDocumentInput {
  path: string; // current document GDS snapshot, including dirty edits
  selectionPath?: string; // selection snapshot, needed only for selection mode
  currentCellName?: string;
  revision: number;
  documentId?: string; // stable document/workspace identity, required for safe history replay
}
```

Suggested component bindings:

```typescript
documentProvider: (mode: PythonInputMode) => this.createPythonSnapshot(mode),
loadResultAction: (artifact: PythonLayoutArtifact, mode: 'replace' | 'merge', revision: number) =>
  this.applyPythonResult(artifact, mode, revision),
```

Snapshots must be separate app-owned temporary files, preserve DBU/layers/datatype/hierarchy and
must not mark the original document clean. The service checks complete GDS framing and an 8 MiB limit.
For selection mode it only sends `selectionPath`; whole-document mode only sends `path`.

The returned artifact preserves `sourceRevision`, `sourceDocumentId`, and `inputMode`.
Before applying a document/selection-derived result, check both identity and revision against the
current workspace; reject stale/reopened history results. The parent owns validated atomic replace
and merge. A failed parse must not lose current geometry or change native snapshot ownership.
For new results, `sourceRevision` is absent. The final Index implementation opens `replace` results
in a **new workspace tab**, preserving the source tab; it does not overwrite the current document.
The panel intentionally hides merge for whole-document results to prevent accidental duplication.
Selection merge adds the result as a referenced Cell. Multiple independent output tops are rejected
by merge with a prompt to open a new tab, which preserves the whole library. Replacing only the
selected source geometry is not implemented.

Python code receives `params`. Document mode injects `source_layout`, `layout` (a deep copy), and
`current_cell`; selection mode injects `selection_layout`, `layout` (a deep copy), and `current_cell`.
No paths or read/write APIs are exposed to generated code. All file decoding and writing happen in
the trusted worker supervisor. Existing AST whitelist, subprocess resource limits, loopback binding,
Bearer authentication and browser-origin rejection remain active.

The panel supports 1–16 numeric sweep values. Every sweep run uses the same captured input snapshot,
not the previous run's output. It stops on first failure; completed artifacts remain in history.
Templates retain script, input mode and parameter JSON. Run history retains the latest 40 results,
including failed runs and source identity. User scripts can be imported/exported with the system picker.

## Registered verification integration

`POST /v1/verify` delegates to engineering-owned `hongtu.verification`:
`validate_verification_request(body)` and `run_verification(body)`. It uses the same auth, Origin,
body-size and single-job gates as generation.

`pythonBridgeService.verify(options:PythonVerificationOptions)` encodes a validated document snapshot:

```typescript
interface PythonVerificationOptions {
  kind:'drc'|'lvs'; technologyId:string; deckId:string;
  document:PythonDocumentInput; referenceSpice?:string; cellName?:string;
}
```

Verification accepts up to 32 MiB GDS (generation remains 8 MiB), with a 46 MiB HTTP request cap and
a 100-second client read timeout covering the supervisor's 90-second worker budget.
The typed result includes success/complete/passed, scope, engine, `foundrySignoff`, reportText,
violations (rule, exact layer/datatype, nm bounding box, message), devices (name/model/numeric
parameters), netCount, violationCount and markersTruncated. UI should display scope/completeness
and must not equate a passing public subset with foundry signoff. Only local administrator-registered
decks may execute; clients cannot upload executable verification code.

## New UI/service files

- `services/AutomationFiles.ets`: bounded UTF-8 system-picker import/export.
- `services/PythonWorkspaceService.ets`: validated parameters, templates and run history.
- `components/dialogs/MacroManagerDialog.ets`: rename, step JSON editor, duplicate, delete, file import/export.
- `MacroService.ets`: validates imported/edited steps and validates entire collections before mutation.

## Validation performed

- `python/.venv/Scripts/python.exe -m unittest discover -s python/tests -p test_workspace.py -v`: 6/6.
  Real KLayout: document and selection geometry, array preservation, independent sweep inputs,
  original-file invariance on failure, forbidden filesystem APIs, malformed input, authenticated HTTP.
  The verification HTTP case executes real SKY130 met1 violations and rejects missing auth, browser
  Origin, uploaded code and concurrent jobs; scope/completeness/signoff fields are asserted.
- Existing `test_bridge.GeneratedLayouts`: 5/5, including timeout termination, all example GDS/OASIS
  geometry roundtrips and unsafe-code rejection. The old externally running HTTP service was not restarted.
- `node --experimental-transform-types --disable-warning=ExperimentalWarning tools/ai_datatype_host_check.mjs`: 14/14.
  Actual AI service/executor source: datatype contracts, populated evidence prompt, ID selection/stale rejection.
- `node --experimental-transform-types --disable-warning=ExperimentalWarning tools/automation_workspace_host_check.mjs`: 6/6.
  Actual macro/template/history service source with isolated platform storage: persistence, immutable builtins,
  JSON collection roundtrip, atomic validation rejection, sweep validation, retained source identity.
- `node --experimental-transform-types --disable-warning=ExperimentalWarning tools/shared_shape_readonly_host_check.mjs`: 9/9.
  Includes ID/focus projections, foreign-Cell/stale-ID rejection, datatype defaults, PATH extension bounds,
  and deeply frozen inputs proving no shared source geometry or selected-ID array mutation.

ArkTS build, file-picker/device interaction and Index integration require root's unified verification.
UI freeze was released by root. New secondary buttons now follow UiTokens/Normal/surfaceMuted/ink;
selection uses primarySoft/primary. Python input/template/history controls are disabled during execution;
cancel is shown only for execution, not during file picking or applying a result.

## Final independent review and regression (2026-09-30)

Runtime input snapshots are now disposed by `PythonBridgeService.disposeDocumentInput(document,context)`
after the entire sweep/verification finishes, fails, is cancelled or loses its panel. Only direct children
of `context.cacheDir` with an exact `python-input/selection-{13 digit date}-{positive serial}.gds` name
are eligible; generated output and history artifacts are retained. Index cleans partial snapshots if
the provider fails before returning. `python_input_cleanup_host_check.mjs`: 9/9, including path traversal,
outside-directory, trailing-newline, history preservation and late panel closure checks.

The final review corrected these behavior differences:

- AI preview uses the same raw-point transform center as editing, preserves fractional scaling and
  scales PATH4 start/end extensions. Duplicate explicit IDs transform once; NODE IDs cannot be selected.
- Empty sweep entries such as `10,,20` now fail instead of silently introducing a zero-valued run;
  adding a 65th parameter is rejected before execution.
- `AiCommandExecutor.executeBatch` stops on the first failed result and still closes its batch.
- Root's `Index.applyAiCommands` captures a real editing session, stops on failure and rolls the whole
  batch back. View actions publish only after success; failed batches do not advertise an AI undo or DRC
  completion. Successful geometry changes trigger current-document DRC.

`index_ai_batch_host_check.mjs` extracts the actual Index method and runs production AiCommandExecutor
and EditService. All 6 cases pass: stale select before delete, created geometry followed by invalid
selection, thrown execution, successful single-undo + DRC, view-only failure, and viewer-mode rejection.
Failure cases compare the complete real session, including selection, undo/redo stacks, clipboard,
dirty baseline and ID allocator. It is included in `check_all.sh`.

Latest scoped rerun: AI datatype/executor 16, readonly preview 10, automation workspace 7, input cleanup 9,
layer access 29, Index AI batch 6: **77 checks passed**. A later macro ownership correction adds another
7 actual-service checks (below); automation workspace and layer access were rerun after that correction.

### Macro document ownership correction

`Macro.originDocumentId` now survives recording, persistence, rename, single/collection JSON transfer
and the manager's Save Copy action. `startRecording(name, documentId?)` captures it.
`executeMacro(id, context?, documentId?)` checks the entire macro before opening a batch or parsing
commands with side effects: `move_shape`, `delete_shapes`, `change_layer` and `create_instance` require
a matching origin. Legacy or imported sensitive macros without an origin are rejected with zero
executed steps. Pure creation macros remain portable; the legacy third-argument layer array remains
accepted. Editing or copying a macro does not silently rebind its IDs.

Index supplies `activeWorkspaceId` at recording/playback and saves an active recording before an
actual workspace switch or parsed import replaces the current document. Failed workspace activation
keeps the recording in its original document. Optional `recordStep(..., currentDocumentId)` also stops
and saves a recording before a supplied foreign-document step can be added.

`macro_document_scope_host_check.mjs`: **7/7**, using production MacroService, AiCommandParser and
EditService plus the actual manager save method. Tests cover all four sensitive commands, zero-effect
whole-batch rejection, legacy/imported/persisted unbound macros, valid same-document execution,
persistence/transfers/copy, portable creation, malformed origin rejection and mixed-recording refusal.
The suite is part of `check_all.sh`. Cross-document ID remapping is intentionally not implemented.

### Actual user paths and remaining scope

- **More → AI assistant**: use current selection/Cell/DRC/network evidence, inspect a pure geometric
  preview, apply a guarded batch, undo once or inspect the new DRC result. Arbitrary instance transforms
  and hit-test-dependent preview bounds are explicitly marked as omitted; the preview is a bounds
  overlay, not a second complete renderer. This agent has not verified live model responses on-device.
- **AI assistant → Python layout**: new/document/selection scope; run or request AI-generated Python;
  preview; open result in a new tab or merge eligible results; template and execution-history controls
  restore the script/scope/parameters. Sweeps vary **one numeric parameter**, 1–16 values, not a Cartesian
  sweep of multiple parameters. Templates retain 32 items and history retains 40; output files are not
  automatically deleted when an entry falls out of history.
- **More → Macro panel → Manage · Edit / Import / Export**: rename, step JSON editing/reordering,
  copy builtins, delete custom macros, import/export through the system file picker. This is a JSON
  command editor, not a graphical step designer or arbitrary Python interpreter. Recorded
  `move_shape`, `delete_shapes`, `change_layer` and `create_instance` commands are bound to their
  source workspace; a missing/mismatched origin rejects the whole batch. Return to the original
  workspace or record the actions again in the desired document. Cross-document ID rebinding remains
  unsupported. Geometry-creation-only macros can be replayed across documents.

Real device, file-picker/credential interactions and live AI service acceptance remain root's evidence
to report. Host checks do not establish those outcomes.
