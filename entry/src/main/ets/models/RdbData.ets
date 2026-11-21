/** KLayout .lyrdb interchange data. All geometric coordinates and lengths are micrometres.
 * A report is metadata/markers; it never asserts DRC/LVS acceptance or edits a layout. */
export type RdbValueKind = 'text' | 'float' | 'box' | 'edge' | 'edge-pair' | 'polygon' | 'path' | 'label';
export interface RdbPoint { x: number; y: number; }
/** Mirror at X first, then rotate, scale and translate. rotationDeg is NOT a mirror-axis angle. */
export interface RdbTransform { rotationDeg: number; mirror: boolean; magnification: number; x: number; y: number; }
export interface RdbTag { name: string; description: string; }
export interface RdbTagRef { name: string; user: boolean; }
export interface RdbCategory { name: string; description: string; categories: RdbCategory[]; }
export interface RdbReference { parentCell: string; transform: RdbTransform; }
export interface RdbCell { name: string; variant: string; layoutName: string; references: RdbReference[]; }
/** Only fields appropriate to kind may be present; validation rejects conflicting/unknown fields. */
export interface RdbValue {
  kind: RdbValueKind;
  tag?: RdbTagRef;
  text?: string;
  number?: number;
  specialNumber?: 'nan' | 'inf' | '-inf';
  /** box: [] is empty, otherwise two corners; edge/edge-pair: two/four endpoints.
   * polygon: hull; path: centerline. Degenerate/empty KLayout objects remain representable. */
  points?: RdbPoint[];
  holes?: RdbPoint[][];
  /** edge-pair '/' is ordered/asymmetric; '|' is symmetric. */
  symmetric?: boolean;
  width?: number;
  beginExtension?: number;
  endExtension?: number;
  round?: boolean;
  transform?: RdbTransform;
  size?: number;
  font?: number;
  horizontalAlignment?: 'none' | 'l' | 'c' | 'r';
  verticalAlignment?: 'none' | 'b' | 'c' | 't';
}
export interface RdbItem {
  /** Exact qualified cell name (name + ':' + nonempty variant). Never split on ':' blindly. */
  cell: string;
  category: string[];
  tags: RdbTagRef[];
  visited: boolean;
  multiplicity: number;
  comment: string;
  /** Opaque standard base64 image payload; round-tripped, not decoded/rendered by the core. */
  image: string;
  values: RdbValue[];
}
export interface RdbDocument {
  schemaVersion: 1;
  coordinateUnit: 'um';
  description: string;
  originalFile: string;
  generator: string;
  topCell: string;
  tags: RdbTag[];
  categories: RdbCategory[];
  cells: RdbCell[];
  items: RdbItem[];
}
export interface RdbLimits {
  maximumCharacters: number;
  maximumNodes: number;
  maximumDepth: number;
  maximumItems: number;
  maximumValues: number;
  maximumPoints: number;
  maximumFramePaths: number;
  maximumWork: number;
}
export interface RdbReadResult { ok: boolean; message: string; document?: RdbDocument; }
export interface RdbWriteResult { ok: boolean; message: string; xml?: string; }
export interface RdbValueResult { ok: boolean; message: string; value?: RdbValue; }
export interface RdbFramePath { cells: string[]; transform: RdbTransform; }
export interface RdbFrameResult { ok: boolean; message: string; paths: RdbFramePath[]; }
export interface RdbItemQuery {
  category?: string[];
  includeDescendants?: boolean;
  cell?: string;
  tags?: RdbTagRef[];
  visited?: boolean;
  text?: string;
}
export interface RdbQueryResult { ok: boolean; message: string; indices: number[]; }
export interface RdbBounds { minX: number; minY: number; maxX: number; maxY: number; }
export interface RdbBoundsResult {
  ok: boolean; message: string; boundsNm?: RdbBounds;
  /** label bbox is an anchor: font rendering is deliberately not guessed. */
  labelAnchorOnly: boolean;
  /** Path bounds conservatively include width/extensions/round caps, not a tessellated path polygon. */
  conservativePath: boolean;
}
/** Structural adapter for current DrcViolation without importing the runtime DrcService. */
export interface RdbViolation {
  id: number; ruleId: string; ruleName: string; type: string; severity: string; layerNumber: number;
  x: number; y: number; width: number; height: number; message: string; shapeIds: number[]; fromInstance?: boolean;
}
export interface RdbViolationReport {
  description: string; originalFile: string; generator: string; cellName: string;
  /** Already published DRC coordinate frame; x/y/width/height are nm in this cell. */
  violations: RdbViolation[];
  /** Explicit run/completeness notice retained as text, never converted into a pass/fail claim. */
  runNotice: string;
}
