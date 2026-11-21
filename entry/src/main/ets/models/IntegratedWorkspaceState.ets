/** One private outer record; nested JSON strings retain their exact codec bytes. */
export interface IntegratedWorkspaceLiveSlots {
  viewJson?: string;
  waiverJson?: string;
  layoutMappingsJson?: string;
}

export interface IntegratedWorkspaceSlots extends IntegratedWorkspaceLiveSlots {
  /** Historical B receipt. Ordinary live publications never regenerate this field. */
  engineeringReceipt?: string;
}

export interface IntegratedWorkspaceState extends IntegratedWorkspaceSlots {
  schema: 'hongtu-integrated-workspace/v1';
  version: 1;
  revision: number;
}

/** CAS must compare exact complete bytes under the physical store's exclusive lock.
 * next=undefined restores the genuinely absent file, including engineering rollback.
 * Native path validation, locking, atomic publication and full readback belong here.
 */
export interface IntegratedWorkspaceAtomicStore {
  configure?: (filesDir: string) => void;
  read: () => string | undefined;
  compareAndSwap: (expected: string | undefined, next: string | undefined) => void;
}

export interface IntegratedWorkspaceProjectionStore {
  configure: (filesDir: string) => void;
  read: () => string | undefined;
  compareAndSwap: (expected: string | undefined, next: string | undefined) => void;
}

export type IntegratedWorkspaceMutableSlot = 'viewJson' | 'waiverJson' | 'layoutMappingsJson';
export type IntegratedWorkspaceSlot = IntegratedWorkspaceMutableSlot | 'engineeringReceipt';

/** Root runs actual B/C/View codecs and returns the complete desired live slots.
 * A missing optional field stays absent; this callback must not publish runtime state.
 */
export type IntegratedEngineeringProjector =
  (nextReceipt: string, before: IntegratedWorkspaceSlots) => IntegratedWorkspaceLiveSlots;

/** Limits may be lowered for a constrained caller, never raised above module budgets. */
export interface IntegratedWorkspaceLimits {
  maximumBytes: number;
  viewBytes: number;
  waiverBytes: number;
  engineeringBytes: number;
  layoutMappingsBytes: number;
}

export const INTEGRATED_WORKSPACE_MAXIMUM_BYTES: number = 512 * 1024 * 1024;
export function integratedWorkspaceDefaultLimits(): IntegratedWorkspaceLimits {
  return { maximumBytes: INTEGRATED_WORKSPACE_MAXIMUM_BYTES, viewBytes: 2 * 1024 * 1024,
    waiverBytes: 128 * 1024 * 1024, engineeringBytes: 120 * 1024 * 1024,
    layoutMappingsBytes: 100 * 1024 * 1024 };
}
