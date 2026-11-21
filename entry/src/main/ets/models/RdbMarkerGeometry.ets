import type { RdbBounds, RdbTransform } from './RdbData';

/** Mathematical, Y-up nanometres. Projection into screen pixels belongs to the overlay. */
export interface RdbMarkerPointNm { x: number; y: number; }
export interface RdbMarkerSegmentNm {
  valueIndex: number;
  partIndex: number;
  kind: 'edge' | 'edge-pair';
  points: RdbMarkerPointNm[];
  symmetric: boolean;
}
export interface RdbMarkerPolygonNm {
  valueIndex: number;
  kind: 'box' | 'polygon' | 'path-outline';
  /** Hull first, holes afterwards. Closed implicitly; degenerate rings are retained. */
  rings: RdbMarkerPointNm[][];
  /** Use Canvas fill('evenodd') for polygon holes. Path outlines use winding fill. */
  fillRule: 'evenodd' | 'nonzero';
  maximumDeviationNm: number;
}
export interface RdbMarkerPathNm {
  valueIndex: number;
  spineNm: RdbMarkerPointNm[];
  widthNm: number;
  beginExtensionNm: number;
  endExtensionNm: number;
  round: boolean;
  /** Draw pathOutlines, not a generic SVG stroke: KLayout clips sharp mitres and supports elliptical caps. */
  rendering: 'outlined-klayout-path';
  capSegmentsPerHalf: number;
  maximumCapDeviationNm: number;
}
export interface RdbMarkerLabelNm {
  valueIndex: number;
  text: string;
  anchorNm: RdbMarkerPointNm;
  rotationDeg: number;
  mirror: boolean;
  magnification: number;
  sourceSizeNm: number;
  font: number;
  horizontalAlignment: 'none' | 'l' | 'c' | 'r';
  verticalAlignment: 'none' | 'b' | 'c' | 't';
  fontBoundsMeasured: false;
}
export interface RdbMarkerGeometryLimits {
  maximumValues: number;
  maximumInputPoints: number;
  maximumOutputPoints: number;
  maximumPrimitives: number;
  maximumWork: number;
  /** Maximum circumscribed round-cap error after frame magnification, in nm. */
  curveToleranceNm: number;
}
export interface RdbMarkerGeometry {
  schemaVersion: 1;
  coordinateUnit: 'nm';
  frame: RdbTransform;
  segments: RdbMarkerSegmentNm[];
  polygons: RdbMarkerPolygonNm[];
  pathOutlines: RdbMarkerPolygonNm[];
  paths: RdbMarkerPathNm[];
  labels: RdbMarkerLabelNm[];
  /** Existing core bounds are for camera positioning only, never marker polygons. */
  cameraBoundsNm?: RdbBounds;
  cameraBoundsRole: 'camera-only';
  labelAnchorOnly: boolean;
  conservativePathBounds: boolean;
  outputPointCount: number;
  maximumDeviationNm: number;
  hasGeometry: boolean;
  notices: string[];
}
export interface RdbMarkerGeometryResult { ok: boolean; message: string; geometry?: RdbMarkerGeometry; }
export interface RdbMarkerImageLimits {
  maximumEncodedCharacters: number;
  maximumDecodedBytes: number;
  maximumDimension: number;
  maximumPixels: number;
}
export interface RdbMarkerImage {
  mimeType: 'image/png' | 'image/jpeg' | 'image/gif' | 'image/webp' | 'image/bmp';
  width: number;
  height: number;
  decodedBytes: number;
  /** Original payload is unchanged, including permitted ASCII whitespace. No URL is fetched. */
  dataUri: string;
  originalBase64: string;
  headerValidated: true;
  decodeVerified: false;
  networkLoading: false;
}
export interface RdbMarkerImageResult { ok: boolean; message: string; image?: RdbMarkerImage; }
