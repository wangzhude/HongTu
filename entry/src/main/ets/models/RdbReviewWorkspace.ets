import type { RdbReviewRecovery, RdbReviewSource } from './RdbReview';

export interface RdbReviewWorkspaceLimits {
  maximumReports: number;
  maximumXmlCharacters: number;
  maximumSerializedBytes: number;
  maximumItems: number;
}
export interface RdbReviewWorkspaceEntry { id: string; uri: string; recovery: RdbReviewRecovery; }
export interface RdbReviewWorkspaceRecovery {
  schema: 'hongtu-rdb-review/v2'; serial: number; activeReportId: string; reports: RdbReviewWorkspaceEntry[];
}
export interface RdbReviewWorkspaceLegacyRecovery {
  schema: 'hongtu-rdb-review/v1'; uri: string; recovery: RdbReviewRecovery;
}
export interface RdbReviewWorkspaceReport {
  id: string; name: string; uri: string; dirty: boolean; items: number;
  source: RdbReviewSource; contextToken: string;
}
export interface RdbReviewWorkspaceSnapshot {
  contextToken: string; activeReportId: string; reports: RdbReviewWorkspaceReport[];
  dirtyReports: number; items: number; xmlCharacters: number; serializedBytes: number;
}
/** Issued by this in-memory workspace lineage; navigation and active-report changes do not alter its content binding. */
export interface RdbReviewWorkspaceSaveTicket {
  token: string; reportId: string; contentToken: string; sourceIdentity: string; xml: string;
}
/** Ordered merge input binding owned by the workspace, independent of detached session instance tokens. */
export interface RdbReviewWorkspaceSourceBinding {
  reportId: string; sourceIdentity: string; contentToken: string;
}
