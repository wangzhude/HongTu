import type { RdbTagRef, RdbFramePath } from './RdbData';
import type { RdbReviewFilter, RdbReviewPage, RdbReviewRow, RdbReviewStatistics, RdbReviewRecovery } from './RdbReview';
import type { RdbReviewWorkspaceReport } from './RdbReviewWorkspace';
import type { RdbWaiverLibrarySnapshot, RdbWaiverContext, RdbWaiverUiPreview } from './RdbWaiver';
import type { RdbMergeOptions, RdbMergeRow, RdbMergeSummary } from './RdbMerge';
import type { RdbReviewTransferOptions, RdbReviewTransferSummary, RdbReviewTransferStatus,
  RdbReviewTransferTextChange, RdbReviewTransferFlagChange, RdbReviewTransferTagsChange } from './RdbReviewTransfer';

export interface RdbReviewCategoryChoice { path: string[]; label: string; description: string; count: number; }
export interface RdbReviewCellChoice { qname: string; name: string; variant: string; layoutName: string; count: number; }
export interface RdbReviewTagChoice { tag: RdbTagRef; label: string; }
export interface RdbReviewLayoutCell { id: number; key: string; name: string; }
export interface RdbReviewStoredSession { schema: 'hongtu-rdb-review/v1'; uri: string; recovery: RdbReviewRecovery; }
export interface RdbTransferUiRequest {
  workspaceToken: string; sourceReportId: string; targetReportId: string;
  sourceContext: string; targetContext: string; options: RdbReviewTransferOptions;
}
/** Attachment payload stays in the host's immutable plan, never in this UI projection. */
export interface RdbTransferUiImageChange { beforeCharacters: number; afterCharacters: number; }
export interface RdbTransferUiChanges {
  comment?: RdbReviewTransferTextChange; visited?: RdbReviewTransferFlagChange;
  waived?: RdbReviewTransferFlagChange; important?: RdbReviewTransferFlagChange;
  userTags?: RdbReviewTransferTagsChange; image?: RdbTransferUiImageChange;
}
export interface RdbTransferUiRow {
  targetIndex: number; sourceIndices: number[]; status: RdbReviewTransferStatus; reason: string;
  applicable: boolean; changes?: RdbTransferUiChanges;
}
/** The host retains the full engine plan; every row is reachable through this page projection. */
export interface RdbTransferUiPreview {
  id: string; request: RdbTransferUiRequest; summary: RdbReviewTransferSummary;
  pageIndex: number; pageSize: number; totalRows: number; pageCount: number; rows: RdbTransferUiRow[];
  canApply: boolean; message: string;
}
/** UI snapshot guards only; the host captures stable content bindings for the engine. */
export interface RdbMergeUiSource { reportId: string; sourceIdentity: string; reportContext: string; }
export interface RdbMergeUiRequest {
  workspaceToken: string; sources: RdbMergeUiSource[]; options: RdbMergeOptions;
}
/** Complete engine rows remain in the host and are reachable through these pages. No XML payload is projected. */
export interface RdbMergeUiPreview {
  id: string; request: RdbMergeUiRequest; summary: RdbMergeSummary;
  pageIndex: number; pageSize: number; totalRows: number; pageCount: number; rows: RdbMergeRow[];
  canApply: boolean; message: string; notices: string[];
}
/** Immutable UI snapshot. The session and layout remain owned by the host. */
export interface RdbReviewUiState {
  workspaceToken: string; activeReportId: string; reports: RdbReviewWorkspaceReport[]; reportLimit: number;
  transferPreview: RdbTransferUiPreview | null;
  mergePreview: RdbMergeUiPreview | null;
  waiverLibrary?: RdbWaiverLibrarySnapshot | null;
  waiverContext?: RdbWaiverContext | null;
  waiverPreview?: RdbWaiverUiPreview | null;
  token: string; loaded: boolean; dirty: boolean; sourceName: string;
  description: string; originalFile: string; generator: string; topCell: string;
  categories: RdbReviewCategoryChoice[]; cells: RdbReviewCellChoice[]; tags: RdbReviewTagChoice[];
  filter: RdbReviewFilter; page: RdbReviewPage; selected: RdbReviewRow | null;
  frameTarget: string; frames: RdbFramePath[]; frameIndex: number; frameMessage: string;
  layoutCells: RdbReviewLayoutCell[]; layoutDocumentTitle: string;
  boundLayoutCellId: number; mappingCurrent: boolean; canLocate: boolean;
  imageSource: string; imageNotice: string;
  statistics?: RdbReviewStatistics;
}

export function emptyRdbReviewUiState(): RdbReviewUiState {
  return { workspaceToken: '', activeReportId: '', reports: [], reportLimit: 256, transferPreview: null, mergePreview: null,
    token: '', loaded: false, dirty: false, sourceName: '', description: '', originalFile: '', generator: '', topCell: '',
    categories: [], cells: [], tags: [], filter: { query: {} },
    page: { pageIndex: 0, pageSize: 50, totalItems: 0, filteredCount: 0, pageCount: 0, rows: [] }, selected: null,
    frameTarget: '', frames: [], frameIndex: -1, frameMessage: '', layoutCells: [], layoutDocumentTitle: '',
    boundLayoutCellId: -1, mappingCurrent: false, canLocate: false, imageSource: '', imageNotice: '' };
}
