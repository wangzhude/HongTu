import type { RdbDocument, RdbTagRef } from './RdbData';

/** Strict report-local equality. No bbox/nearest/index matching, no implicit frame conversion. */
export interface RdbReviewTransferFields {
  comment: boolean; visited: boolean; waived: boolean; important: boolean; userTags: boolean; image: boolean;
}
export interface RdbReviewTransferOptions {
  fields: RdbReviewTransferFields;
  duplicatePolicy: 'reject' | 'consensus';
  targetConflictPolicy: 'reject' | 'overwrite';
  /** Unmatched new markers always remain unchanged. Other blocked rows reject the batch by default. */
  blockedPolicy: 'reject' | 'skip';
}
export interface RdbReviewTransferLimits {
  maximumItems: number; maximumValues: number; maximumKeyCharacters: number; maximumWork: number;
}
export interface RdbReviewTransferTextChange { before: string; after: string; }
export interface RdbReviewTransferFlagChange { before: boolean; after: boolean; }
export interface RdbReviewTransferTagsChange { before: RdbTagRef[]; after: RdbTagRef[]; }
export interface RdbReviewTransferChanges {
  comment?: RdbReviewTransferTextChange; visited?: RdbReviewTransferFlagChange;
  waived?: RdbReviewTransferFlagChange; important?: RdbReviewTransferFlagChange;
  userTags?: RdbReviewTransferTagsChange; image?: RdbReviewTransferTextChange;
}
export type RdbReviewTransferStatus = 'matched' | 'unmatched' | 'ambiguous' | 'reference-mismatch' | 'conflict';
export interface RdbReviewTransferRow {
  targetIndex: number; sourceIndices: number[]; status: RdbReviewTransferStatus; reason: string;
  applicable: boolean; changes?: RdbReviewTransferChanges;
}
export interface RdbReviewTransferSummary {
  sourceItems: number; targetItems: number; matched: number; noChanges: number; changed: number;
  unmatched: number; ambiguous: number; referenceMismatch: number; conflict: number; blocked: number;
  unusedSourceItems: number;
}
export interface RdbReviewTransferPlan {
  schemaVersion: 1;
  matchSemantics: 'strict-typed-local-frame-v1';
  /** Exact codec snapshots bind all fields, review state and metadata for confirm-time regeneration. */
  sourceXml: string; targetXml: string;
  options: RdbReviewTransferOptions; limits: RdbReviewTransferLimits;
  rows: RdbReviewTransferRow[]; summary: RdbReviewTransferSummary;
  canApply: boolean; notices: string[];
}
export interface RdbReviewTransferPreviewResult { ok: boolean; message: string; plan?: RdbReviewTransferPlan; }
export interface RdbReviewTransferApplyResult {
  ok: boolean; message: string; document?: RdbDocument; summary?: RdbReviewTransferSummary;
  appliedTargetIndices?: number[]; skippedTargetIndices?: number[];
}
