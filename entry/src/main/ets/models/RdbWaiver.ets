import type { RdbTagRef } from './RdbData';
import type { RdbReviewWorkspaceService } from '../services/RdbReviewWorkspaceService';

/** Host proof, never inferred from file/Cell display names. Technology identity is the
 * exact active rule/process configuration; stable keys survive report reruns. */
export interface RdbWaiverCellBinding { reportCell: string; stableCellKey: string; }
export interface RdbWaiverQualification {
  layoutIdentity: string; technologyIdentity: string; cells: RdbWaiverCellBinding[];
}
export interface RdbWaiverContext {
  workspaceToken: string; reportId: string; reportContext: string; reportContentToken: string;
  configurationToken: string; layoutRevision: number; qualification: RdbWaiverQualification;
}
export interface RdbWaiverOrigin {
  sourceIdentity: string; sourceName: string; originalFile: string; generator: string;
  reportContext: string; itemIndex: number; layoutRevision: number; capturedAt: string;
}
/** One fully validated marker XML retains complete ordered typed values and source
 * category/Cell definitions. No display text, bbox or approximate coordinates form a key. */
export interface RdbWaiverRule {
  id: string; name: string; rationale: string; origin: RdbWaiverOrigin;
  layoutIdentity: string; technologyIdentity: string; stableCellKey: string; markerXml: string;
}
export interface RdbWaiverApplication {
  id: string; ruleId: string; ruleName: string; reportId: string; sourceIdentity: string;
  itemIndex: number; markerKey: string; beforeTags: RdbTagRef[]; afterTags: RdbTagRef[];
  /** Any external review/content change abandons ownership conservatively. */
  active: boolean;
}
/** Single durable aggregate: report draft and flag ownership cannot commit separately. */
export interface RdbWaiverEnvelope {
  schema: 'hongtu-rdb-waiver/v1'; revision: number; serial: number;
  workspaceJson: string; rules: RdbWaiverRule[]; applications: RdbWaiverApplication[];
}
export interface RdbWaiverPortable { schema: 'hongtu-rdb-waiver-library/v1'; rules: RdbWaiverRule[]; }
export interface RdbWaiverStore { read(): string | undefined; compareAndSwap(expected: string | undefined, next: string): void; }
export interface RdbWaiverLimits {
  maximumRules: number; maximumApplications: number; maximumLibraryCharacters: number;
  maximumWork: number; maximumItems: number;
}
export interface RdbWaiverRuleRow {
  id: string; name: string; rationale: string; sourceName: string; cell: string;
  valueCount: number; capturedAt: string; applications: number;
}
export interface RdbWaiverLibrarySnapshot {
  version: string; revision: number; rules: RdbWaiverRuleRow[]; activeApplications: number;
  abandonedApplications: number; ruleLimit: number;
}
export type RdbWaiverStatus = 'match' | 'already-waived' | 'unmatched' | 'uncertain' | 'conflict' | 'remove';
export interface RdbWaiverPreviewRow {
  itemIndex: number; ruleIds: string[]; ruleNames: string[]; status: RdbWaiverStatus; reason: string;
}
export interface RdbWaiverSummary {
  items: number; changed: number; alreadyWaived: number; unmatched: number; uncertain: number; conflicts: number;
}
export interface RdbWaiverPreview {
  id: string; libraryVersion: string; context: RdbWaiverContext; ruleIds: string[];
  operation: 'apply' | 'remove'; summary: RdbWaiverSummary; rows: RdbWaiverPreviewRow[];
  canApply: boolean; message: string;
}
/** Full engine rows stay in the service; every row is reachable by pagination. */
export interface RdbWaiverUiPreview extends RdbWaiverPreview {
  pageIndex: number; pageSize: number; pageCount: number; totalRows: number;
}
export interface RdbWaiverUiRequest {
  context: RdbWaiverContext; libraryVersion: string; ruleIds: string[]; operation: 'apply' | 'remove';
}
export interface RdbWaiverCaptureRequest {
  context: RdbWaiverContext; libraryVersion: string; itemIndex: number; name: string; rationale: string;
}
export interface RdbWaiverFileRequest { kind: 'import' | 'export'; libraryVersion: string; workspaceToken: string; }
export interface RdbWaiverCommit {
  workspace: RdbReviewWorkspaceService; workspaceJson: string; summary: RdbWaiverSummary;
}
export interface RdbWaiverTagChange { index: number; beforeTags: RdbTagRef[]; afterTags: RdbTagRef[]; }
