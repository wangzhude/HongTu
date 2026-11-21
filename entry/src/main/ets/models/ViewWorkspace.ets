import type { Shape } from './GdsiiData';
import type { UiLayer } from '../common/types';

export interface ViewCameraState { centerXNm: number; centerYNm: number; zoomPercent: number; }
export interface ViewCanvasCamera { zoomPercent: number; offsetX: number; offsetY: number; }
export interface ViewLayerVisibility { layerNumber: number; datatype: number; visible: boolean; }
export interface ViewPlacementRef { parentCellKey: string; cellKey: string; instanceId: number; row: number; col: number; }
export interface ViewLocation { cellStackKeys: string[]; placements: ViewPlacementRef[]; }
export interface ViewAffine { a: number; b: number; c: number; d: number; tx: number; ty: number; }
export interface ViewResolvedPlacement { parentCellId: number; cellId: number; instanceId: number; row: number; col: number; transform: ViewAffine; }
export interface ViewResolvedLocation { cellStack: number[]; navigationPath: ViewResolvedPlacement[]; }
export interface ViewPresentation {
  camera: ViewCameraState;
  location: ViewLocation;
  hierarchyDepth: number;
  layerVisibilities: ViewLayerVisibility[];
}
export interface ViewOverlayState {
  id: string;
  sourceDocumentId: string;
  cellKey: string;
  visible: boolean;
  opacity: number;
  transform: ViewAffine;
  layerVisibilities: ViewLayerVisibility[];
}
export interface ViewRecord { id: string; name: string; presentation: ViewPresentation; overlays: ViewOverlayState[]; }
export interface ViewBookmark { id: string; name: string; presentation: ViewPresentation; }
export interface ViewDocumentState { documentId: string; activeViewId: string; views: ViewRecord[]; bookmarks: ViewBookmark[]; }
export interface ViewWorkspaceState { schema: 'hongtu-view-workspace/v1'; serial: number; documents: ViewDocumentState[]; }
export interface ViewBookmarkFile { schema: 'hongtu-view-bookmarks/v1'; documentId: string; bookmarks: ViewBookmark[]; }

/** Shape arrays and Cell metadata belong to the real database, never to a ViewRecord. */
export interface ViewDatabaseSnapshot {
  documentId: string;
  revision: number;
  dirty: boolean;
  historyToken: string;
  shapes: Shape[];
  cellKeys: string[];
  topCellKey: string;
  /** Live/checkpoint display data, never serialized into the view library. */
  cellNames?: string[];
  layers?: UiLayer[];
}
export interface ViewDatabaseSource { documentId: string; read: () => ViewDatabaseSnapshot; }
export interface ViewWorkspaceStore {
  configure?: (filesDir: string) => void;
  read: () => string | undefined;
  compareAndSwap: (expected: string | undefined, next: string | undefined) => void;
}
/** Root owns the actual editor-navigation checkpoint, including rollback. */
export interface ViewRuntime {
  documentId: () => string;
  viewId: () => string;
  contextToken: () => string;
  isIdle: () => boolean;
  /** Include the complete current document layer list, even currently hidden or empty layers. */
  capturePresentation: () => ViewPresentation;
  applyPresentation: (presentation: ViewPresentation, location: ViewResolvedLocation, viewId: string) => void;
  rollbackPresentation: (presentation: ViewPresentation, viewId: string) => void;
}
export interface ViewRenderSource {
  sourceId?: string;
  sourceDocumentId: string;
  cellId: number;
  snapshot: ViewDatabaseSnapshot;
  transform: ViewAffine;
  opacity: number;
  layerVisibilities: ViewLayerVisibility[];
  readOnly: boolean;
}
export interface ViewRenderDiagnostic { overlayId: string; message: string; }
export interface ViewRenderResolution { sources: ViewRenderSource[]; diagnostics: ViewRenderDiagnostic[]; }
