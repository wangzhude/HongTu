# Editor feature integration — 2026-09-30

Implemented in the current dirty working tree. No commits. No native/shared Shape model changes.

## Property editing

`services/ShapePropertyService.ets` exports `PropertyCellOption { id, name }`, `PropertyEditResult { ok, changed, message }`, field definitions/value accessors, and preflight validation. `EditService.updateProperties(ids, property, value, cells = [])` validates every target before mutating, then commits one undo transaction. Invalid/locked/incompatible targets reject the whole batch. A no-op preserves redo.

Fields: `x`, `y`, `width`, `height`, `layerKey` (`68/20`), `text`, `pathWidth`, `pathType` (`0/1/2/4`), `pathBeginExtension`, `pathEndExtension`, `pathWidthAbsolute` (`0/1`), `cellId`, `rotation`, `mirror` (`0/1/2`), `magnification`, `arrayCols`, `arrayRows`, `arrayColStepX/Y`, `arrayRowStepX/Y`, `properties` (JSON LayoutPropRecord array). Changing extensions sets PATH type 4. Cell references synchronize names and reject cycles. Property JSON replaces the selected owners' records; `[]` clears them.

`ShapePropertiesPopover` keeps previous props/actions and adds:

```ts
selectedShapes: Shape[]
cells: PropertyCellOption[]
onPropertiesSubmit: ((ids: number[], property: string, value: string) => string) | null
```

Pass all selected shapes, and return an error string or an empty string on successful submission. Existing root method `updateShapeProperty()` can stay for the mobile inspector or be routed through the unified method.

```ts
// imports
import { PropertyEditResult } from '../services/ShapePropertyService';

// ShapePropertiesPopover call, alongside existing props
selectedShapes: this.shapes.filter((s: Shape) => editService.getSelectedIds().indexOf(s.id) >= 0),
cells: this.placeableCells,
onPropertiesSubmit: (ids: number[], property: string, value: string): string => {
  if (!this.assertEditMode()) return '当前为只读模式';
  const result: PropertyEditResult = editService.updateProperties(ids, property, value, this.placeableCells);
  if (!result.ok) return result.message;
  if (result.changed > 0) {
    this.syncShapesFromEditService();
    this.rebuildCellTree();
  }
  this.statusText = result.message;
  return '';
},
```

Single field changes intentionally apply the same absolute value to every selected object. Blank mixed fields are not submitted until actually edited. Selection keys prevent late input/blur events from modifying a new selection. A scrollable details section contains instance/PATH/user attributes; previous pin/close/copy/delete remain.

## Shape search

New `components/workbench/ShapeSearchPanel.ets`. Props and callbacks:

```ts
shapes: Shape[]
currentCellId: number
documentKey: string // use the current tab ID, so stale results clear on tab switch
locateAction: (id: number) => void
selectAction: (ids: number[]) => void
closeAction: () => void
```

The component searches exact layer/datatype, type, width/height intervals (nm), case-insensitive text, current Cell/all cells, and selectable-only. Results refresh after geometry edits. List display is bounded to 200 entries, while select matches acts on all current Cell results and reapplies visibility/lock/selectable guards. Cross-cell results can be located individually; bulk selection never silently changes edit context.

```ts
import { ShapeSearchPanel } from '../components/workbench/ShapeSearchPanel';
@State showShapeSearch: boolean = false;

// reachable menu/toolbar action: this.showShapeSearch = true;
if (this.showShapeSearch) {
  ShapeSearchPanel({
    shapes: this.shapes,
    currentCellId: editService.getCurrentCellId(),
    documentKey: this.currentFilePath, // substitute activeTabId after multi-document integration
    locateAction: (id: number) => {
      const s: Shape | undefined = this.shapes.find((item: Shape) => item.id === id);
      if (s === undefined) return;
      const owner: number = s.ownerCellId ?? editService.getTopCellId();
      if (owner !== editService.getCurrentCellId()) this.enterCell(owner);
      editService.selectShape(id);
      this.syncShapesFromEditService();
      // Center camera on actual getShapeBounds(s); do not fit the entire cell.
      const b = getShapeBounds(s);
      this.viewOffsetX = this.canvasViewportWidth * 50 / this.zoomPercent - (b.minX + b.maxX) / 2;
      this.viewOffsetY = this.canvasViewportHeight * 50 / this.zoomPercent + (b.minY + b.maxY) / 2;
      // Adapt canvasViewportWidth/Height to Index's actual camera field names.
    },
    selectAction: (ids: number[]) => {
      editService.selectMultiple(ids);
      this.syncShapesFromEditService();
      this.propertyPanelClosed = false;
    },
    closeAction: () => { this.showShapeSearch = false; }
  })
}
```

## Snapping and related selection correction

`SnapService.snapToGeometry` provides vertices → intersections → midpoints → bounding-box centers → edges. Rectangles stored as two diagonal points now expose all four corners. Intersections are exact within the local edge set, bounded to 128 nearby segments to avoid quadratic work over an entire document. No LOD rectangle is used as snap geometry.

`LayoutCanvasView` now provides visible hierarchy-expanded exact candidates, with a 5,000-shape viewport cache and cursor-local bounded expansion if the viewport overflows. Moving selection definitions are excluded, including moved Cell references, so geometry does not snap to its own old position. Drawing, measuring, Move, and selection dragging use the same target computation. Move previews match the committed snapped position. Status readout identifies snap target type outside measurement mode. These changes need no new Index props.

Found and corrected a separate existing selection bug: normalized positive selection-box width erased drag direction, so right-to-left crossing selection always became containment selection. Direction is now recorded separately.

## Multi-document/PCell service hooks requested by root

`EditService` exports:

```ts
export interface EditSessionState {
  shapes: Shape[];
  nextId: number;
  undoStack: EditAction[];
  redoStack: EditAction[];
  selectedId: number;
  selectedIds: number[];
  topCellId: number;
  currentCellStack: number[];
  clipboard: Shape[];
  dirty: boolean;
  editDepth: number;
  cleanBaselineReachable: boolean;
}
captureSession(): EditSessionState
restoreSession(state: EditSessionState): void
getSessionRevision(): number
replaceCellContents(cellId: number, templates: Shape[]): number[]
```

Capture closes pending transactions, then deep-copies geometry, history and clipboard. Restore deep-copies again and preserves existing layer providers; root should restore document layers, call `refreshLayerAccess()` and normal `syncShapesFromEditService()` after switching. Native snapshot freshness and native spatial-index synchronization belong to Index as before. Snap cache includes session revision.

`replaceCellContents` preflights source/target locks and finite nonempty template geometry before any deletion, assigns fresh IDs/owner IDs, and replaces the Cell in one undo transaction. Valid empty replacement returns `[]`; invalid/locked templates throw Error. Native metadata and PCell parameter mappings remain root-owned.

## Validation

Executed actual production service sources with Node's TypeScript transform (only native transport and Harmony UI dependencies stubbed):

- `node --experimental-transform-types --disable-warning=ExperimentalWarning tools/features_editor_host_check.mjs`: **25/25 passed** (including actual extracted Index PCell/library methods).
- `... tools/layer_access_host_check.mjs`: **29/29 passed**.
- `... tools/editing_geometry_host_check.mjs`: **19/19 passed**, uses the existing real C++ geometry probe.

Existing test staging in `layer_access_host_check`, `editing_geometry_host_check`, and `import_ownership_host_check` was updated for the new pure property service dependency.

No complete hvigor build, install or device acceptance performed by this agent. Root owns the shared build/device run. UI files were frozen on request while another chat owned the emulator/release build. Devices still need batch property entry, keyboard isolation, scrolling details, search locate/select, and drag snapping verification.

## PCell and component library integration

At root's request, Index methods between `insertPCell` and `applyArrayCopy` now implement PCell edit and the component-library UI callbacks. `cloneDocumentSubset(source: WorkspaceDocument, rootCellId: number, rootShapeIds?: number[]): WorkspaceDocument` keeps a selected root subset (when supplied) and all recursively referenced child contents, remaps IDs contiguously, and preserves empty Cells and library/cell/element properties. `insertLibraryEntry(entry, x = 0, y = 0): boolean` is usable by Python result merge; it validates the combined current/imported expanded hierarchy before mutation and restores session and metadata if creation fails.

Generated PCells carry an ASCII-safe JSON marker `HONGTU_PCELL_V1:` in the first shape's attr 126/dtype 6 value; `name` is not used for recovery. Parameter edits replace Cell contents atomically and recover their previous parameter record from geometry on undo. All references to the same Cell update together. A normal placement undo removes its geometry/placement in one step; empty Cell definitions are retained, consistent with existing placement behavior.

## Workspace and library persistence hardening

`WorkspaceService` freezes both geometry and metadata before queueing, verifies every recovery reference, preserves valid empty Cells and all three property levels (signed int16 attr matching the native wire codec), validates compressed AREF products/cycles/point budgets before publication, and uses the native per-Cell maximum-expanded-count convention. UTF-8 byte budgets match disk read limits. Short reads use one open descriptor and streaming decoding. Backups are replaced only by a valid primary index. Best-effort snapshot cleanup retains current/previous/history references and never changes the result of a published save.

`ComponentLibraryService` serializes add/remove/import against the latest committed list, publishes memory only after atomic file success, deep-copies exposed snapshots, validates parameter/geometry budgets, and can restore a backup when the primary is absent or corrupt.

`node --experimental-transform-types --disable-warning=ExperimentalWarning tools/workspace_recovery_host_check.mjs artifacts/editor-features-20260930/native/sram64x24.hongtu`: **21/21 passed**. The optional fixture is exported using the production native GDS reader, import-budget validator, and property-wire codec via `tools/workspace_native_fixture_build.ps1`. The public SRAM64x24 fixture has **4892 Cells, 120822 stored shapes, 550687 maximum expanded shapes**; every shape, Cell name, library property and Cell property is deep-compared. Existing host checks also cover element properties, empty Cells, short UTF-8 IO, interrupted publication, corruption recovery, concurrent library additions, strict cleanup, compressed expansion limits and metadata isolation.

## Independent Index workspace review

`node --experimental-transform-types --disable-warning=ExperimentalWarning tools/index_workspace_host_check.mjs`: **14/14 passed**, now included in `tools/check_all.sh`. This harness extracts the actual Index workspace, close-confirmation, Cell-creation and macro document-change methods and runs the production EditService, WorkspaceService and MeasureStore with platform/native/IO/render callbacks and a minimal MacroService test double. The two added checks verify saving old-document recording before editor replacement and retaining it after native activation failure.

The review reproduced and root fixed: incoming selection filtered by the previous tab's layers; asynchronous close confirmation cleaning another tab; a new empty Cell being marked clean by an older save snapshot; ruler IDs repeating after recovery; closing a tab deleting its session before the next native activation succeeded; and a clean selection-only revision change producing nine tabs from eight recovered documents. EditService `adoptShapes` now clears the previous document clipboard, while `restoreSession` keeps each existing tab's own clipboard. Tests also verify geometry/metadata/undo isolation, native-activation rejection, cross-tab save guards, history restoration as an isolated copy, and preservation of edits made during recovery.

WorkspaceService's build diagnostics were fixed with an explicit WorkspaceTab map return type and an Error rethrow; its 21 checks passed again afterwards. UI/native device acceptance remains root-owned.
