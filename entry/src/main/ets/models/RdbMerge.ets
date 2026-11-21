import type { RdbDocument, RdbLimits, RdbTag } from './RdbData';

/** Pure merge. Inputs are ordered, independent reports; the layout database is never edited. */
export type RdbMergeStructurePolicy = 'reuse-identical' | 'namespace-sources';
export interface RdbMergeOptions {
  structurePolicy: RdbMergeStructurePolicy;
  outputName: string;
  outputDescription: string;
}
export interface RdbMergeInput {
  reportId: string;
  sourceIdentity: string;
  contentToken: string;
  document: RdbDocument;
}
export interface RdbMergeLimits {
  maximumSources: number;
  maximumInputCharacters: number;
  maximumPlanRows: number;
  maximumWork: number;
  codec: RdbLimits;
}
export type RdbMergeRowKind = 'metadata' | 'cell' | 'category' | 'tag' | 'item' | 'issue';
export type RdbMergeRowStatus = 'preserved' | 'reused' | 'renamed' | 'conflict' | 'notice';
/** Every input item and every structure mapping has a row. The UI may page these, never truncate them. */
export interface RdbMergeRow {
  kind: RdbMergeRowKind;
  status: RdbMergeRowStatus;
  sourceIndex: number;
  reportId: string;
  sourceLabel: string;
  outputLabel: string;
  sourceItemIndex: number;
  outputItemIndex: number;
  reason: string;
}
export interface RdbMergeSummary {
  sources: number;
  inputItems: number;
  outputItems: number;
  values: number;
  cells: number;
  categories: number;
  tagDefinitions: number;
  preserved: number;
  reused: number;
  renamed: number;
  conflicts: number;
  notices: number;
}
export interface RdbMergeSourceBinding {
  reportId: string;
  sourceIdentity: string;
  contentToken: string;
  canonicalXml: string;
}
/** Metadata is retained visibly in the new report description as a JSON provenance block. */
export interface RdbMergeSourceProvenance {
  sourceIndex: number;
  reportId: string;
  sourceIdentity: string;
  namespace: string;
  description: string;
  originalFile: string;
  generator: string;
  topCell: string;
  mappedTopCell: string;
  tagDefinitions: RdbTag[];
  cellMappings: RdbMergeMapping[];
  categoryMappings: RdbMergeMapping[];
  tagMappings: RdbMergeMapping[];
}
export interface RdbMergeMapping {
  sourceLabel: string;
  outputLabel: string;
  usage?: 'declaration' | 'system-item' | 'user-item' | 'system-value' | 'user-value' | 'namespace-root';
}
export interface RdbMergePlan {
  schemaVersion: 1;
  mergeSemantics: 'hongtu-lossless-rdb-merge/v1';
  options: RdbMergeOptions;
  limits: RdbMergeLimits;
  sources: RdbMergeSourceBinding[];
  provenance: RdbMergeSourceProvenance[];
  rows: RdbMergeRow[];
  summary: RdbMergeSummary;
  canApply: boolean;
  /** Complete prospective output codec snapshot; empty only when conflicts block the entire merge. */
  outputXml: string;
  notices: string[];
}
export interface RdbMergePreviewResult { ok: boolean; message: string; plan?: RdbMergePlan; }
export interface RdbMergeApplyResult {
  ok: boolean;
  message: string;
  document?: RdbDocument;
  outputName?: string;
  summary?: RdbMergeSummary;
}
