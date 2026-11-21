import type { ViewDocumentState, ViewWorkspaceState, ViewDatabaseSnapshot } from './ViewWorkspace';
import type { RdbReviewWorkspaceRecovery } from './RdbReviewWorkspace';
import type { RdbReviewLayoutMapping } from './RdbReview';
import type { EngineeringProjectBundle, EngineeringRestorePayload } from '../services/EngineeringProjectService';

/** References describe identity, never grant access to an external file. */
export interface EngineeringReviewSource {
  documentId: string; cellKeys: string[]; topCellKey: string; originUri?: string;
}
export interface EngineeringReviewBundle {
  schema: 'hongtu-engineering-review/v1'; workspaceId: string;
  sources: EngineeringReviewSource[];
  /** Missing and explicit null remain distinct; neither requests deletion on restore. */
  views?: ViewDocumentState | null;
  reports?: RdbReviewWorkspaceRecovery | null;
  layoutMappings?: RdbReviewLayoutMapping[] | null;
}
export interface EngineeringDocumentMapping { sourceDocumentId: string; targetDocumentId: string; }
export interface EngineeringIdentityMapping { sourceId: string; targetId: string; }
export interface EngineeringReviewDiagnostic { code: string; message: string; sourceDocumentId?: string; cellKey?: string; }
export interface EngineeringReviewRestorePreview {
  token: string; sourceWorkspaceId: string; targetWorkspaceId: string;
  mappings: EngineeringDocumentMapping[]; viewIds: EngineeringIdentityMapping[];
  bookmarkIds: EngineeringIdentityMapping[]; reportIds: EngineeringIdentityMapping[];
  diagnostics: EngineeringReviewDiagnostic[]; canRestore: boolean;
  viewCount: number; bookmarkCount: number; overlayCount: number; reportCount: number; dirtyReportCount: number;
}
export interface EngineeringReviewRuntimeState { views: ViewWorkspaceState; reports: RdbReviewWorkspaceRecovery; layoutMappings?: RdbReviewLayoutMapping[]; }
export interface EngineeringReportOrigin { reportId: string; sourceReportId: string; uri: string; }
/** One durable record contains every part of a confirmed restore. */
export interface EngineeringReviewRestoreState {
  schema: 'hongtu-engineering-restore/v1'; project: EngineeringProjectBundle;
  targetWorkspaceId: string; tools: EngineeringRestorePayload; state: EngineeringReviewRuntimeState;
  mappings: EngineeringDocumentMapping[]; viewIds: EngineeringIdentityMapping[];
  bookmarkIds: EngineeringIdentityMapping[]; reportIds: EngineeringIdentityMapping[];
  reportOrigins: EngineeringReportOrigin[];
}
export interface EngineeringReviewStore {
  read: () => string | undefined;
  compareAndSwap: (expected: string | undefined, next: string | undefined) => void;
}
/** Root captures tools/navigation/dirty/ownership and replaces all live references synchronously.
 * publish must not mark a report exported or a layout clean. rollback restores that full checkpoint.
 * readSources includes the imported target database before it is shown in the editor.
 * contextToken binds page generation, document/revision, tools, views and report navigation/content.
 */
export interface EngineeringReviewRuntime {
  contextToken: () => string; isIdle: () => boolean;
  /** Page generation/document identity only; unchanged by successful metadata adoption. */
  lifecycleToken: () => string;
  readSources: () => ViewDatabaseSnapshot[];
  readState: () => EngineeringReviewRuntimeState;
  capture: () => Object;
  publish: (candidate: EngineeringReviewRestoreState) => void;
  rollback: (checkpoint: Object) => void;
}
export interface EngineeringReviewRestoreOptions {
  mappings: EngineeringDocumentMapping[];
  /** Explicitly displayed in preview; replacing an existing target requires opt-in. */
  replaceTargetViews: boolean;
}
