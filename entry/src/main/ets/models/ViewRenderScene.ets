import type { Shape, Point } from './GdsiiData';
import type { UiLayer } from '../common/types';
import type { ViewAffine } from './ViewWorkspace';
import type { LayerRenderStyle } from '../common/MaterialTokens';

export const SCENE_TEXT_FONT_SIZE: number = 12;
export const SCENE_TEXT_LINE_HEIGHT: number = 22;
export interface ViewSceneTextMetrics { width: number; height: number; padding: number; }

/** A borrowed display checkpoint. No geometry or editing state is owned here. */
export interface ViewSceneSource {
  sourceId: string;
  sourceDocumentId: string;
  revision: number;
  shapes: Shape[];
  cellNames: string[];
  layers: UiLayer[];
  cellId: number;
  topCellId: number;
  depth: number;
  transform: ViewAffine;
  opacity: number;
  readOnly: boolean;
}

/** Fully transformed, read-only display primitive; never passed to EditService. */
export interface ViewScenePrimitive {
  key: string;
  sourceId: string;
  sourceDocumentId: string;
  kind: string;
  /** A presentation-only outline for descendants stopped by hierarchyDepth. */
  hierarchyFrame?: boolean;
  layerNumber: number;
  datatype: number;
  points: Point[];
  text: string;
  textTransform: ViewAffine;
  textWidth: number;
  textHeight: number;
  color: string;
  style: LayerRenderStyle;
  opacity: number;
}

export interface ViewSceneDrawResult {
  primitives: ViewScenePrimitive[];
  overflow: boolean;
  limit: number;
  message: string;
}
