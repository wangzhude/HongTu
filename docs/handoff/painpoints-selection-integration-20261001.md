# Selection, instance path and array integration (2026-10-01)

Owner edited only `EditService.ets`, `HierarchyExpandService.ets`, `LayoutCanvasView.ets` and related host tests. Existing APIs remain compatible. No new page or sheet, no device commands, no build or Git commit.

## Existing Canvas props and callbacks to wire in Index

```ts
import type { InstancePathStep, IndependentPathResult, FlattenEstimate } from '../services/EditService';
import type { HierarchyHitCandidate, HierarchyCandidatesResult } from '../services/HierarchyExpandService';

@State pickedPlacement: HierarchyHitCandidate | null = null;
private pickedPlacementRevision: number = -1;

// In LayoutCanvasView({...})
displayGridNm: this.displayGridNm, // optional; -1 falls back to old gridSize
drawStepNm: this.drawStepNm,       // optional; -1 falls back to old gridSize
geometrySnapEnabled: this.geometrySnapEnabled,
geometrySnapKinds: this.geometrySnapKinds,
selectionLayerFilter: this.selectionLayerFilter,       // -1 = all
selectionDatatypeFilter: this.selectionDatatypeFilter, // -1 = all
selectionTypeFilter: this.selectionTypeFilter,         // [] = all
onPickCandidate: (candidate: HierarchyHitCandidate): void => {
  this.pickedPlacement = candidate;
  this.pickedPlacementRevision = editService.getSessionRevision();
},
onHitCandidates: (result: HierarchyCandidatesResult, activeIndex: number): void => {
  // Optional external inspector: result.complete=false means capped candidates;
  // result.ok=false must never be presented as a complete list or select partial results.
},
onEnterInstancePath: (path: InstancePathStep[]): boolean => {
  if (!editService.enterInstancePath(path)) return false;
  this.syncShapesFromEditService(); this.fitAllShapes();
  this.statusText = `已进入 ${this.cellName(editService.getCurrentCellId())}；正在编辑共享定义`;
  return true;
},
```

Canvas automatically shows a bounded overlap list (64 items), supports Tab/Shift+Tab and previous/next buttons, highlights the chosen leaf's world bounds, and reports root, leaf, layer/datatype and last member indices. Candidate selection changes selection only, with no geometry/history. Existing double-click fallback still invokes `onEnterCell` if concrete-path callback is not wired.

## Shared impact and independent editing

`editService.getSharedImpact(cellId, rootCellId?, limit?)` separates direct reference records, distinct parent Cells and concrete placements below the chosen root. `bounded=true` means placements is a lower-bound cap, not an exact number; failure includes a reason. Display these labels separately. Current Cell tree `×n` is still direct-record count until root changes its labels.

In `cellStructureState()` include `navigationPath: editService.getNavigationPath()` so undo restores concrete navigation alongside the old Cell stack. Ordinary property edits modify the shared Cell definition; show its impact near the persistent Cell name.

```ts
private makePickedPlacementIndependent(): void {
  const picked: HierarchyHitCandidate | null = this.pickedPlacement;
  if (picked === null || picked.path.length === 0 || this.pickedPlacementRevision !== editService.getSessionRevision()) {
    this.statusText = '版图或选择已变化，请重新点选具体实例'; return;
  }
  const prefix: InstancePathStep[] = editService.getNavigationPath();
  // A legacy definition-only navigation has no placement prefix: return to Top and choose an actual placement.
  if (editService.getCurrentCellStack().length > 1 && prefix.length === 0) {
    this.statusText = '请返回顶层并从具体实例进入，以确定仅修改此处的范围'; return;
  }
  const result: IndependentPathResult = editService.makePathIndependent(prefix.concat(picked.path), this.cellStructureState());
  if (!result.ok) { this.statusText = result.message; return; }
  this.pickedPlacement = null;
  this.nativeSnapshotCurrent = false;
  this.readPCellVariants(); this.syncShapesFromEditService(); this.rebuildCellTree(); this.fitAllShapes();
  this.statusText = result.message;
}
```

The operation copies each ancestor definition along the exact path, replaces only the chosen placement and enters the new target Cell. Array members are split into one single SREF plus at most four compressed remainder arrays; all geometry and properties stay in their original world locations. Remaining members and unrelated references retain their original definitions. Geometry changes, new definitions, metadata and navigation are one structural undo/redo item.

For `extractArrayMember(instanceId, row, col, this.cellStructureState())`, the operation stays in the current definition and extracts only that definition's member without copying the referenced child Cell. This is appropriate for moving one member of the current array; it still affects references to the current parent Cell. State this scope. `result.instanceId` identifies the extracted SREF; select it after success and refresh. Rows/cols are zero-based in APIs and one-based in UI.

Do not use an old candidate after revision or document changes. Reset pickedPlacement after edits, document switches and undo/redo. Structure operations need this app's existing structural restore callback wired. Existing geometry budgets (1 million stored shapes / 4 million points) and path maximum 32 levels apply; locked involved layers reject the entire operation before changing data.

## Navigation and persistence

`editService.navigateToStackIndex(index)` replaces the old exitToTop + enterCell loop and preserves concrete path prefixes. Refresh/focus/fit as before. Backspace should use it too.

Workspace changes are owned by root/data owner: optionally persist `navigationPath: InstancePathStep[]`. Older documents continue loading from `cellStack`. After restoring the old stack call `editService.restoreNavigationPath(doc.navigationPath ?? [])`; it revalidates IDs, members and fresh transforms and fails safely for stale paths. `captureSession/restoreSession` already carry navigationPath for in-memory tabs.

## Flatten preview

Before `flattenInstanceList(ids)`, call `editService.estimateFlatten(instanceIds)`. It returns `removedReferences`, `createdObjects`, `remainingChildReferences`, `estimatedBytes`, `ok/message`. It estimates ONE LEVEL; remaining child instances keep references. Bytes describe estimated geometry storage, not guaranteed process memory.

Show a saved preview dialog/card containing the counts, operation scope and cancel/confirm. Freeze document ID + getSessionRevision + current Cell when opening, compare before confirmation, then reuse the existing flatten implementation (complete transaction). An over-budget or locked estimate rejects without mutation. No additional confirmation should be invented beyond this concrete operation preview.

## Lock and touch semantics

`canSelectLayer` now checks visibility, selectable and valid layer/datatype, so locked layers remain readable. `canEditLayer` still gates mutation, undo/redo and independent/Flatten operations. Canvas vertex handles and drag reject locked objects; mixed locked/editable move selection rejects the entire gesture before touching data.

Raw second-finger Down, pinch and two-finger-pan cancel drafts/drag/pending selection. Remaining contacts cannot start or commit a new edit until all fingers lift. Cancellation leaves geometry, selection, dirty, history and revision unchanged.

## Host evidence

Run `node --experimental-transform-types tools/selection_hierarchy_painpoints_host_check.mjs`, `tools/drawing_workflow_host_check.mjs`, `tools/layer_access_host_check.mjs`.

New service checks exercise overlapping roots/leaves and filters, explicit cap/failure, mirrored oblique nested path transforms, sessions, reference records versus concrete member counts, exact AREF split geometry/properties, isolated nested editing and full undo/redo, atomic stale/locked rejection, Flatten counts, and geometry revision monotonicity. New Canvas checks exercise Tab cycling/preview, stale candidates, second-finger cancellation with all remaining input, and mixed read-only move atomicity. These are host checks with platform rendering/input stubbed; final ArkTS compilation and actual keyboard/touch device tasks remain root-owned acceptance.

The selection/hierarchy runner now has 19 passing checks. Nine additional checks extract the current production `Index.ets` instance helpers and candidate callbacks and execute them with the real `EditService`; only dialogs, rendering and persistence are stubbed. Clearing selection, empty hits, replacing a single/multiple selection and entering/returning through the Cell tree retain the same service revision and cannot reuse an old AREF member. A late candidate from another Cell is rejected. Confirmation rejects a changed selection/document, while valid member extraction preserves painted geometry and has one undo transaction. Shared-definition entry from a non-Top Cell follows the relative child path without exiting to Top, and an already-entered concrete placement remains eligible for local isolation without a new leaf candidate. These checks verify root's selection-context fixes and are not device interaction evidence.
