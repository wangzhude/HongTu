import type { ViewLayerVisibility } from './ViewWorkspace';

/** Choices are snapshots of actually opened databases; the root owns their context stamp. */
export interface ViewOverlayCellChoice { key: string; name: string; }
export interface ViewOverlayDocumentChoice {
  documentId: string;
  title: string;
  revision: number;
  cells: ViewOverlayCellChoice[];
  layers: ViewLayerVisibility[];
}
export interface ViewOverlayDiagnostic { overlayId: string; message: string; }

/** Keep literal input, including invalid values, until an explicit successful save or reread. */
export interface ViewOverlayEditDraft {
  documentId: string;
  viewId: string;
  overlayId: string;
  context: string;
  opacity: string;
  a: string;
  b: string;
  c: string;
  d: string;
  tx: string;
  ty: string;
}
