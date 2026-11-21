import type { RdbItem, RdbItemQuery, RdbFramePath, RdbBounds } from './RdbData';

/** Source identity belongs to the report session, never to the currently open layout. */
export interface RdbReviewSource { identity: string; name: string; }
export type RdbReviewSort = 'index' | 'category' | 'cell' | 'multiplicity' | 'value';
export interface RdbReviewFilter {
  query: RdbItemQuery; waived?: boolean; important?: boolean;
  /** Union within each list; intersection with query and the other filters. Empty list selects nothing. */
  categories?: string[][]; cells?: string[]; sortBy?: RdbReviewSort; descending?: boolean;
}
export interface RdbReviewRow { index: number; item: RdbItem; waived: boolean; important: boolean; }
export interface RdbReviewPage {
  pageIndex: number; pageSize: number; totalItems: number; filteredCount: number; pageCount: number;
  rows: RdbReviewRow[];
}
export interface RdbReviewPatch { comment?: string; visited?: boolean; waived?: boolean; important?: boolean; }
export interface RdbReviewCounts {
  items: number; visited: number; waived: number; important: number;
  /** Exact decimal strings: sums of individually safe multiplicities may exceed JS integer precision. */
  multiplicity: string; visitedMultiplicity: string; waivedMultiplicity: string; importantMultiplicity: string;
}
export interface RdbReviewStatistics { all: RdbReviewCounts; filtered: RdbReviewCounts; }
export interface RdbReviewSaveTicket { token: string; revision: number; sourceIdentity: string; xml: string; }
export interface RdbReviewFrameSelection { itemIndex: number; targetCell: string; pathIndex: number; path: RdbFramePath; }
/** Explicit caller-established mapping to one current layout Cell. Name guesses are not mappings. */
export interface RdbReviewLayoutMapping {
  reportSourceIdentity: string; reportCell: string;
  layoutDocumentId: string; layoutRevision: number; layoutCellId: number; layoutCellKey: string;
}
export interface RdbReviewLocationPlan {
  contextToken: string; itemIndex: number; mapping: RdbReviewLayoutMapping; pathIndex: number;
  path: RdbFramePath; boundsNm?: RdbBounds; labelAnchorOnly: boolean; conservativePath: boolean;
}
export interface RdbReviewSnapshot {
  loaded: boolean; source?: RdbReviewSource; revision: number; dirty: boolean; totalItems: number;
  /** Generated report has not yet been acknowledged by an external save. Absent on legacy/file reports. */
  pendingExport?: boolean;
  filter: RdbReviewFilter; pageIndex: number; pageSize: number; filteredCount: number; selectedIndex: number;
  /** Reachable report coordinate frame, including a target awaiting a concrete path. */
  frameTarget?: string;
  frame?: RdbReviewFrameSelection;
}
export interface RdbReviewRecovery {
  schemaVersion: 1; source: RdbReviewSource; currentXml: string; savedXml: string;
  /** Does not alter RDB XML. Both XML baselines remain valid even before the first external save. */
  pendingExport?: boolean;
  filter: RdbReviewFilter; pageIndex: number; pageSize: number; selectedIndex: number;
  /** Optional for legacy recovery; a concrete frame also implies its target. */
  frameTarget?: string;
  frame?: RdbReviewFrameSelection;
}
