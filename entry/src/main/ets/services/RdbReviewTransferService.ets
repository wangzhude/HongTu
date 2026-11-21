import type { RdbDocument, RdbItem, RdbValue, RdbCell, RdbReference, RdbCategory, RdbPoint, RdbTransform, RdbTagRef, RdbTag } from '../models/RdbData';
import type { RdbReviewTransferFields, RdbReviewTransferOptions, RdbReviewTransferLimits, RdbReviewTransferChanges,
  RdbReviewTransferRow, RdbReviewTransferSummary, RdbReviewTransferPlan, RdbReviewTransferPreviewResult,
  RdbReviewTransferApplyResult } from '../models/RdbReviewTransfer';
import { serializeRdb, serializeRdbValue, rdbCellQName } from './RdbService';

export function defaultRdbReviewTransferOptions(): RdbReviewTransferOptions {
  return { fields: { comment: true, visited: true, waived: true, important: true, userTags: false, image: false },
    duplicatePolicy: 'reject', targetConflictPolicy: 'reject', blockedPolicy: 'reject' };
}
export function defaultRdbReviewTransferLimits(): RdbReviewTransferLimits {
  return { maximumItems: 200000, maximumValues: 1000000, maximumKeyCharacters: 33554432, maximumWork: 10000000 };
}
function fail(message: string): never { throw new Error('RDB审阅继承：' + message); }
function keys(value: Object, allowed: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).some((key: string): boolean => !allowed.includes(key))) fail(label + '字段无效');
}
function positive(value: number, label: string): void {
  if (!Number.isSafeInteger(value) || value <= 0) fail(label + '必须为正安全整数');
}
function copyOptions(value: RdbReviewTransferOptions): RdbReviewTransferOptions {
  keys(value, ['fields', 'duplicatePolicy', 'targetConflictPolicy', 'blockedPolicy'], 'options');
  keys(value.fields, ['comment', 'visited', 'waived', 'important', 'userTags', 'image'], 'fields');
  const f: RdbReviewTransferFields = value.fields;
  for (const flag of [f.comment, f.visited, f.waived, f.important, f.userTags, f.image]) {
    if (typeof flag !== 'boolean') fail('六个字段开关必须为布尔值');
  }
  if (![f.comment, f.visited, f.waived, f.important, f.userTags, f.image].some((flag: boolean): boolean => flag)) fail('至少选择一个转移字段');
  if (!['reject', 'consensus'].includes(value.duplicatePolicy) || !['reject', 'overwrite'].includes(value.targetConflictPolicy) ||
    !['reject', 'skip'].includes(value.blockedPolicy)) fail('转移策略无效');
  return { fields: { comment: f.comment, visited: f.visited, waived: f.waived, important: f.important, userTags: f.userTags, image: f.image },
    duplicatePolicy: value.duplicatePolicy, targetConflictPolicy: value.targetConflictPolicy, blockedPolicy: value.blockedPolicy };
}
class TransferBudget {
  work: number = 0; values: number = 0; characters: number = 0;
  limits: RdbReviewTransferLimits;
  constructor(value: RdbReviewTransferLimits) {
    keys(value, ['maximumItems', 'maximumValues', 'maximumKeyCharacters', 'maximumWork'], 'limits');
    for (const n of [value.maximumItems, value.maximumValues, value.maximumKeyCharacters, value.maximumWork]) positive(n, '预算');
    this.limits = { maximumItems: value.maximumItems, maximumValues: value.maximumValues,
      maximumKeyCharacters: value.maximumKeyCharacters, maximumWork: value.maximumWork };
  }
  spend(count: number = 1): void { this.work += count; if (this.work > this.limits.maximumWork) fail('工作预算超限，没有发布截断预览'); }
  value(): void { this.values++; this.spend(); if (this.values > this.limits.maximumValues) fail('完整value数量超预算'); }
  text(text: string): string { this.characters += text.length; this.spend(); if (this.characters > this.limits.maximumKeyCharacters) fail('匹配key字符预算超限'); return text; }
}
function transform(t: RdbTransform): RdbTransform {
  return { rotationDeg: t.rotationDeg, mirror: t.mirror, magnification: t.magnification, x: t.x, y: t.y };
}
function points(p: RdbPoint[]): RdbPoint[] { return p.map((q: RdbPoint): RdbPoint => ({ x: q.x, y: q.y })); }
function tags(t: RdbTagRef[]): RdbTagRef[] { return t.map((q: RdbTagRef): RdbTagRef => ({ name: q.name, user: q.user })); }
function value(v: RdbValue): RdbValue {
  const out: RdbValue = { kind: v.kind };
  if (v.tag !== undefined) out.tag = { name: v.tag.name, user: v.tag.user };
  if (v.text !== undefined) out.text = v.text;
  if (v.number !== undefined) out.number = v.number;
  if (v.specialNumber !== undefined) out.specialNumber = v.specialNumber;
  if (v.points !== undefined) out.points = points(v.points);
  if (v.holes !== undefined) out.holes = v.holes.map((hole: RdbPoint[]): RdbPoint[] => points(hole));
  if (v.symmetric !== undefined) out.symmetric = v.symmetric;
  if (v.width !== undefined) out.width = v.width;
  if (v.beginExtension !== undefined) out.beginExtension = v.beginExtension;
  if (v.endExtension !== undefined) out.endExtension = v.endExtension;
  if (v.round !== undefined) out.round = v.round;
  if (v.transform !== undefined) out.transform = transform(v.transform);
  if (v.size !== undefined) out.size = v.size;
  if (v.font !== undefined) out.font = v.font;
  if (v.horizontalAlignment !== undefined) out.horizontalAlignment = v.horizontalAlignment;
  if (v.verticalAlignment !== undefined) out.verticalAlignment = v.verticalAlignment;
  return out;
}
function category(c: RdbCategory): RdbCategory {
  return { name: c.name, description: c.description, categories: c.categories.map((q: RdbCategory): RdbCategory => category(q)) };
}
function copyDocument(d: RdbDocument): RdbDocument {
  return { schemaVersion: 1, coordinateUnit: 'um', description: d.description, originalFile: d.originalFile,
    generator: d.generator, topCell: d.topCell, tags: d.tags.map((t: RdbTag): RdbTag => ({ name: t.name, description: t.description })),
    categories: d.categories.map((c: RdbCategory): RdbCategory => category(c)),
    cells: d.cells.map((c: RdbCell): RdbCell => ({ name: c.name, variant: c.variant, layoutName: c.layoutName,
      references: c.references.map((r: RdbReference): RdbReference => ({ parentCell: r.parentCell, transform: transform(r.transform) })) })),
    items: d.items.map((i: RdbItem): RdbItem => ({ cell: i.cell, category: i.category.slice(), tags: tags(i.tags), visited: i.visited,
      multiplicity: i.multiplicity, comment: i.comment, image: i.image, values: i.values.map((v: RdbValue): RdbValue => value(v)) })) };
}
function state(item: RdbItem, name: string): boolean { return item.tags.some((tag: RdbTagRef): boolean => !tag.user && tag.name === name); }
function userTags(item: RdbItem): RdbTagRef[] { return tags(item.tags.filter((tag: RdbTagRef): boolean => tag.user)); }
function reviewKey(item: RdbItem, fields: RdbReviewTransferFields): string {
  return JSON.stringify([fields.comment ? item.comment : null, fields.visited ? item.visited : null,
    fields.waived ? state(item, 'waived') : null, fields.important ? state(item, 'important') : null,
    fields.userTags ? userTags(item) : null, fields.image ? item.image : null]);
}
function markerKey(item: RdbItem, budget: TransferBudget): string {
  const values: string[] = [];
  for (const v of item.values) {
    const encoded = serializeRdbValue(v);
    if (!encoded.ok || encoded.xml === undefined) fail(encoded.message);
    values.push(encoded.xml);
  }
  return budget.text(JSON.stringify([item.cell, item.category, values]));
}
/** Reject resource exhaustion before constructing the full codec snapshots. */
function preflightValues(document: RdbDocument, budget: TransferBudget): void {
  for (const item of document.items) {
    budget.spend(); if (!Array.isArray(item.values)) fail('item values无效');
    for (const v of item.values) {
      budget.value();
      if (v.points !== undefined) { if (!Array.isArray(v.points)) fail('points无效'); budget.spend(v.points.length); }
      if (v.holes !== undefined) {
        if (!Array.isArray(v.holes)) fail('holes无效'); budget.spend(v.holes.length);
        for (const hole of v.holes) { if (!Array.isArray(hole)) fail('hole无效'); budget.spend(hole.length); }
      }
    }
  }
}
/** Exact reachable reference DAG and explicit Cell identity; array order is irrelevant, duplicates remain counted. */
function cellContexts(document: RdbDocument, budget: TransferBudget): Map<string, string> {
  const cells: Map<string, RdbCell> = new Map<string, RdbCell>();
  for (const c of document.cells) { budget.spend(); cells.set(rdbCellQName(c), c); }
  const contexts: Map<string, string> = new Map<string, string>();
  for (const item of document.items) {
    if (contexts.has(item.cell)) continue;
    const seen: Set<string> = new Set<string>(); const entries: string[] = [];
    const visit = (name: string): void => {
      budget.spend(); if (seen.has(name)) return; seen.add(name);
      const c: RdbCell | undefined = cells.get(name); if (c === undefined) fail('悬空Cell context');
      const refs: string[] = [];
      for (const r of c.references) {
        budget.spend(); refs.push(JSON.stringify([r.parentCell, r.transform.rotationDeg, r.transform.mirror,
          r.transform.magnification, r.transform.x, r.transform.y])); visit(r.parentCell);
      }
      refs.sort(); entries.push(JSON.stringify([c.name, c.variant, c.layoutName, refs]));
    };
    visit(item.cell); entries.sort(); contexts.set(item.cell, budget.text(JSON.stringify([document.topCell, entries])));
  }
  return contexts;
}
function changes(target: RdbItem, source: RdbItem, fields: RdbReviewTransferFields): RdbReviewTransferChanges {
  const result: RdbReviewTransferChanges = {};
  if (fields.comment && target.comment !== source.comment) result.comment = { before: target.comment, after: source.comment };
  if (fields.visited && target.visited !== source.visited) result.visited = { before: target.visited, after: source.visited };
  if (fields.waived && state(target, 'waived') !== state(source, 'waived')) result.waived = { before: state(target, 'waived'), after: state(source, 'waived') };
  if (fields.important && state(target, 'important') !== state(source, 'important')) result.important = { before: state(target, 'important'), after: state(source, 'important') };
  if (fields.userTags && JSON.stringify(userTags(target)) !== JSON.stringify(userTags(source))) result.userTags = { before: userTags(target), after: userTags(source) };
  if (fields.image && target.image !== source.image) result.image = { before: target.image, after: source.image };
  return result;
}
function overwriteConflict(change: RdbReviewTransferChanges): boolean {
  return (change.comment !== undefined && change.comment.before.length > 0) ||
    (change.visited !== undefined && change.visited.before) || (change.waived !== undefined && change.waived.before) ||
    (change.important !== undefined && change.important.before) ||
    (change.userTags !== undefined && change.userTags.before.length > 0) || (change.image !== undefined && change.image.before.length > 0);
}
function userTagDeclarationConflict(source: RdbDocument, target: RdbDocument, item: RdbItem, budget: TransferBudget): string {
  for (const tag of userTags(item)) {
    budget.spend();
    const a: Set<string> = new Set<string>(); const b: Set<string> = new Set<string>();
    for (const declaration of source.tags) { budget.spend(); if (declaration.name === tag.name) a.add(declaration.description); }
    for (const declaration of target.tags) { budget.spend(); if (declaration.name === tag.name) b.add(declaration.description); }
    if (a.size > 1 || b.size > 1) return '用户标签有同名不同描述，无法确定含义：' + tag.name;
    if (a.size === 1 && b.size === 1 && Array.from(a)[0] !== Array.from(b)[0]) return '两份报告对同名用户标签的描述不同：' + tag.name;
  }
  return '';
}
interface TagUses { system: boolean; user: boolean; value: boolean; }
function targetTagUses(target: RdbDocument, budget: TransferBudget): Map<string, TagUses> {
  const uses: Map<string, TagUses> = new Map<string, TagUses>();
  const mark = (name: string, isUser: boolean, isValue: boolean): void => {
    budget.spend(); const entry: TagUses = uses.get(name) ?? { system: false, user: false, value: false };
    if (isValue) entry.value = true; else if (isUser) entry.user = true; else entry.system = true;
    uses.set(name, entry);
  };
  for (const item of target.items) {
    budget.spend(); for (const v of item.values) { budget.spend(); if (v.tag !== undefined) mark(v.tag.name, v.tag.user, true); }
    for (const tag of item.tags) mark(tag.name, tag.user, false);
  }
  return uses;
}
function addedDeclarationConflict(source: RdbDocument, target: RdbDocument, change: RdbReviewTransferChanges,
  uses: Map<string, TagUses>, budget: TransferBudget): string {
  const incoming: RdbTagRef[] = [];
  if (change.userTags !== undefined) incoming.push(...change.userTags.after);
  for (const tag of incoming) {
    budget.spend(); if (target.tags.some((t: RdbTag): boolean => t.name === tag.name)) continue;
    const existing: TagUses | undefined = uses.get(tag.name);
    // Existing undefined user vocabulary keeps its absence; standard review flags need no XML definition.
    if (existing !== undefined && existing.user && !existing.system && !existing.value) continue;
    const meanings: Set<string> = new Set<string>();
    for (const declaration of source.tags) { budget.spend(); if (declaration.name === tag.name) meanings.add(declaration.description); }
    if (meanings.size > 1) return '来源对待新增的同名标签有不同描述，无法确定定义：' + tag.name;
    if (existing !== undefined && existing.value) return '新标签定义会改变目标已有标记值标签的含义：' + tag.name;
    if (existing !== undefined && existing.system && tag.user) return '新用户标签定义与目标已有系统标签同名，无法确定含义：' + tag.name;
    if ((tag.name === 'waived' && change.waived !== undefined && change.waived.after) ||
      (tag.name === 'important' && change.important !== undefined && change.important.after)) return '新用户标签定义与将继承的系统审阅标签同名，无法确定定义含义：' + tag.name;
  }
  return '';
}
function bucket(keys: string[]): Map<string, number[]> {
  const map: Map<string, number[]> = new Map<string, number[]>();
  for (let i: number = 0; i < keys.length; i++) { const indices = map.get(keys[i]); if (indices === undefined) map.set(keys[i], [i]); else indices.push(i); }
  return map;
}
export function previewRdbReviewTransfer(source: RdbDocument, target: RdbDocument,
  options: RdbReviewTransferOptions = defaultRdbReviewTransferOptions(),
  limits: RdbReviewTransferLimits = defaultRdbReviewTransferLimits()): RdbReviewTransferPreviewResult {
  try {
    const opts: RdbReviewTransferOptions = copyOptions(options); const budget: TransferBudget = new TransferBudget(limits);
    if (source === null || target === null || !Array.isArray(source.items) || !Array.isArray(target.items) ||
      source.items.length + target.items.length > limits.maximumItems) fail('source/target item超预算或无效');
    preflightValues(source, budget); preflightValues(target, budget);
    // Validate and bind the complete reports. No unknown field or malformed typed value can enter a match.
    const sourceEncoded = serializeRdb(source), targetEncoded = serializeRdb(target);
    if (!sourceEncoded.ok || sourceEncoded.xml === undefined) fail(sourceEncoded.message);
    if (!targetEncoded.ok || targetEncoded.xml === undefined) fail(targetEncoded.message);
    const sourceKeys: string[] = source.items.map((item: RdbItem): string => markerKey(item, budget));
    const targetKeys: string[] = target.items.map((item: RdbItem): string => markerKey(item, budget));
    const sourceReviewKeys: string[] = source.items.map((item: RdbItem): string => budget.text(reviewKey(item, opts.fields)));
    const donors = bucket(sourceKeys), recipients = bucket(targetKeys);
    const protectedTagUses: Map<string, TagUses> = targetTagUses(target, budget);
    const sourceContexts = cellContexts(source, budget), targetContexts = cellContexts(target, budget);
    const rows: RdbReviewTransferRow[] = []; const used: Set<number> = new Set<number>();
    const summary: RdbReviewTransferSummary = { sourceItems: source.items.length, targetItems: target.items.length,
      matched: 0, noChanges: 0, changed: 0, unmatched: 0, ambiguous: 0, referenceMismatch: 0, conflict: 0, blocked: 0, unusedSourceItems: 0 };
    for (let index: number = 0; index < target.items.length; index++) {
      budget.spend(); const item: RdbItem = target.items[index], candidates: number[] = donors.get(targetKeys[index]) ?? [];
      const row: RdbReviewTransferRow = { targetIndex: index, sourceIndices: candidates.slice(), status: 'unmatched',
        reason: '来源中没有单元变体、完整类别路径和全部有序标记值都相同的记录', applicable: false };
      if (candidates.length === 0) { summary.unmatched++; rows.push(row); continue; }
      if (sourceContexts.get(item.cell) !== targetContexts.get(item.cell)) {
        row.status = 'reference-mismatch'; row.reason = '单元名称、变体、版图名称、顶层单元或祖先引用坐标不同，不能直接继承';
        summary.referenceMismatch++; summary.blocked++; rows.push(row); continue;
      }
      const targetDuplicates: number = recipients.get(targetKeys[index])!.length;
      if (opts.duplicatePolicy === 'reject' && (candidates.length > 1 || targetDuplicates > 1)) {
        row.status = 'ambiguous'; row.reason = '存在完整相同的重复标记，默认不任取来源或按顺序配对';
        summary.ambiguous++; summary.blocked++; rows.push(row); continue;
      }
      const donor: RdbItem = source.items[candidates[0]];
      const donorState: string = sourceReviewKeys[candidates[0]]; let conflict: boolean = false;
      for (const candidate of candidates) { budget.spend(); if (sourceReviewKeys[candidate] !== donorState) conflict = true; }
      if (conflict) {
        row.status = 'conflict'; row.reason = '重复来源的所选审阅内容不同，共识策略也无法确定来源';
        summary.conflict++; summary.blocked++; rows.push(row); continue;
      }
      const change: RdbReviewTransferChanges = changes(item, donor, opts.fields);
      let declarationConflict: string = opts.fields.userTags ? userTagDeclarationConflict(source, target, donor, budget) : '';
      if (declarationConflict.length === 0) declarationConflict = addedDeclarationConflict(source, target, change, protectedTagUses, budget);
      if (declarationConflict.length > 0 || (opts.targetConflictPolicy === 'reject' && overwriteConflict(change))) {
        row.status = 'conflict'; row.reason = declarationConflict.length > 0 ? declarationConflict : '目标已有不同的所选审阅内容；未明确允许覆盖';
        row.changes = change; summary.conflict++; summary.blocked++; rows.push(row); continue;
      }
      row.status = 'matched'; row.applicable = true; row.changes = change;
      row.reason = candidates.length > 1 || targetDuplicates > 1 ? '标记内容和引用坐标一致，重复来源的所选内容全部相同，可按明确选择的共识策略继承' : '来源唯一，完整标记内容和引用坐标一致，可继承所选字段';
      summary.matched++; if (Object.keys(change).length === 0) summary.noChanges++; else summary.changed++;
      for (const candidate of candidates) used.add(candidate); rows.push(row);
    }
    summary.unusedSourceItems = source.items.length - used.size;
    const plan: RdbReviewTransferPlan = { schemaVersion: 1, matchSemantics: 'strict-typed-local-frame-v1',
      sourceXml: sourceEncoded.xml, targetXml: targetEncoded.xml, options: opts, limits: budget.limits, rows: rows, summary: summary,
      canApply: summary.blocked === 0 || opts.blockedPolicy === 'skip', notices: [
        '严格完整typed values/标签身份/顺序和完整report-local reference图匹配；不使用bbox或index匹配。',
        '与KLayout apply的范围不同：它会忽略部分unknown value tags/refs并在重复来源任取，本引擎显式拒绝这些歧义。',
        'visited是本引擎显式审阅转移字段；KLayout apply不转移visited。原字体/不同frame转换/几何拓扑等价不猜测。',
        '只返回新target候选文档；调用方必须保留savedXml及双方报告身份/context，并通过既有持久化事务接受。' ] };
    return { ok: true, message: plan.canApply ? '完整预览已生成；尚未写入审阅内容' : '完整预览存在阻断项；默认整批拒绝', plan: plan };
  } catch (error) { return { ok: false, message: (error as Error).message }; }
}
function setFlag(item: RdbItem, name: string, on: boolean): void {
  if (state(item, name) === on) return;
  item.tags = item.tags.filter((tag: RdbTagRef): boolean => tag.user || tag.name !== name);
  if (on) item.tags.push({ name: name, user: false });
}
function addDeclaration(document: RdbDocument, source: RdbDocument, name: string): void {
  if (document.tags.some((tag: RdbTag): boolean => tag.name === name)) return;
  const incoming = source.tags.filter((tag: RdbTag): boolean => tag.name === name);
  if (incoming.length === 0) document.tags.push({ name: name, description: '' });
  else document.tags.push({ name: incoming[0].name, description: incoming[0].description });
}
export function applyRdbReviewTransfer(source: RdbDocument, target: RdbDocument,
  plan: RdbReviewTransferPlan): RdbReviewTransferApplyResult {
  try {
    const regenerated = previewRdbReviewTransfer(source, target, plan.options, plan.limits);
    if (!regenerated.ok || regenerated.plan === undefined) fail(regenerated.message);
    if (JSON.stringify(regenerated.plan) !== JSON.stringify(plan)) fail('来源/目标/预览规则或行已改变；旧或被修改的预览未应用');
    if (!regenerated.plan.canApply) fail('存在歧义、引用坐标差异或审阅冲突，默认整批未应用；须明确选择跳过阻断项');
    const candidate: RdbDocument = copyDocument(target); const applied: number[] = [], skipped: number[] = [];
    const existingUserNames: Set<string> = new Set<string>();
    for (const old of target.items) for (const tag of old.tags) if (tag.user) existingUserNames.add(tag.name);
    for (const row of regenerated.plan.rows) {
      if (!row.applicable || row.changes === undefined) { skipped.push(row.targetIndex); continue; }
      const change: RdbReviewTransferChanges = row.changes; if (Object.keys(change).length === 0) continue;
      const item: RdbItem = candidate.items[row.targetIndex];
      if (change.comment !== undefined) item.comment = change.comment.after;
      if (change.visited !== undefined) item.visited = change.visited.after;
      if (change.waived !== undefined) setFlag(item, 'waived', change.waived.after);
      if (change.important !== undefined) setFlag(item, 'important', change.important.after);
      if (change.userTags !== undefined) {
        item.tags = tags(item.tags.filter((tag: RdbTagRef): boolean => !tag.user)).concat(tags(change.userTags.after));
        for (const tag of change.userTags.after) {
          if (!existingUserNames.has(tag.name)) addDeclaration(candidate, source, tag.name);
        }
      }
      if (change.image !== undefined) item.image = change.image.after;
      applied.push(row.targetIndex);
    }
    const encoded = serializeRdb(candidate); if (!encoded.ok || encoded.xml === undefined) fail(encoded.message);
    return { ok: true, message: '已生成新的目标报告，实际变化' + applied.length + '项，跳过' + skipped.length + '项；尚未保存或修改版图',
      document: candidate, summary: regenerated.plan.summary, appliedTargetIndices: applied, skippedTargetIndices: skipped };
  } catch (error) { return { ok: false, message: (error as Error).message }; }
}
export class RdbReviewTransferService {
  preview(source: RdbDocument, target: RdbDocument, options?: RdbReviewTransferOptions, limits?: RdbReviewTransferLimits): RdbReviewTransferPreviewResult {
    return previewRdbReviewTransfer(source, target, options, limits);
  }
  apply(source: RdbDocument, target: RdbDocument, plan: RdbReviewTransferPlan): RdbReviewTransferApplyResult { return applyRdbReviewTransfer(source, target, plan); }
}
export const rdbReviewTransferService: RdbReviewTransferService = new RdbReviewTransferService();
