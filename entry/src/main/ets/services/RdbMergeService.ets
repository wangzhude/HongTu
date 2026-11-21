import type { RdbDocument, RdbLimits, RdbCategory, RdbCell, RdbTag, RdbTagRef, RdbValue,
  RdbItem, RdbPoint, RdbTransform, RdbReference } from '../models/RdbData';
import type { RdbMergeInput, RdbMergeOptions, RdbMergeLimits, RdbMergePlan, RdbMergeRow,
  RdbMergeRowKind, RdbMergeRowStatus, RdbMergeSummary, RdbMergeSourceProvenance,
  RdbMergePreviewResult, RdbMergeApplyResult } from '../models/RdbMerge';
import { defaultRdbLimits, serializeRdb, rdbCellQName, rdbCategoryPath } from './RdbService';

/** Lossless union of report records, deliberately stricter than KLayout ReportDatabase.merge.
 * Canonical XML is a codec snapshot, not a promise of original XML bytes or tag-description identity. */
export function defaultRdbMergeOptions(): RdbMergeOptions {
  return { structurePolicy: 'reuse-identical', outputName: '合并报告', outputDescription: '' };
}
export function defaultRdbMergeLimits(): RdbMergeLimits {
  return { maximumSources: 256, maximumInputCharacters: 67108864, maximumPlanRows: 500000,
    maximumWork: 10000000, codec: defaultRdbLimits() };
}
function fail(message: string): never { throw new Error('RDB合并：' + message); }
function keys(value: Object, allowed: string[], label: string): void {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
    Object.keys(value).some((key: string): boolean => !allowed.includes(key))) fail(label + '含未知字段');
}
function text(value: string, label: string, nonempty: boolean = false): void {
  if (typeof value !== 'string' || (nonempty && value.trim() === '')) fail(label + '不能为空');
}
function positive(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0) fail('预算必须为正安全整数');
}
function copyOptions(o: RdbMergeOptions): RdbMergeOptions {
  keys(o, ['structurePolicy', 'outputName', 'outputDescription'], '合并选项');
  if (!['reuse-identical', 'namespace-sources'].includes(o.structurePolicy)) fail('结构策略无效');
  text(o.outputName, '新报告名称', true); text(o.outputDescription, '新报告说明');
  if (o.outputName.length > 1024) fail('新报告名称过长');
  if (/[\x00-\x1f\x7f]/.test(o.outputName)) fail('新报告名称不能含换行或控制字符');
  return { structurePolicy: o.structurePolicy, outputName: o.outputName, outputDescription: o.outputDescription };
}
function copyLimits(l: RdbMergeLimits): RdbMergeLimits {
  keys(l, ['maximumSources', 'maximumInputCharacters', 'maximumPlanRows', 'maximumWork', 'codec'], '合并预算');
  keys(l.codec, ['maximumCharacters', 'maximumNodes', 'maximumDepth', 'maximumItems', 'maximumValues',
    'maximumPoints', 'maximumFramePaths', 'maximumWork'], '报告预算');
  for (const n of [l.maximumSources, l.maximumInputCharacters, l.maximumPlanRows, l.maximumWork,
    l.codec.maximumCharacters, l.codec.maximumNodes, l.codec.maximumDepth, l.codec.maximumItems,
    l.codec.maximumValues, l.codec.maximumPoints, l.codec.maximumFramePaths, l.codec.maximumWork]) positive(n);
  const c: RdbLimits = l.codec;
  return { maximumSources: l.maximumSources, maximumInputCharacters: l.maximumInputCharacters,
    maximumPlanRows: l.maximumPlanRows, maximumWork: l.maximumWork,
    codec: { maximumCharacters: c.maximumCharacters, maximumNodes: c.maximumNodes, maximumDepth: c.maximumDepth,
      maximumItems: c.maximumItems, maximumValues: c.maximumValues, maximumPoints: c.maximumPoints,
      maximumFramePaths: c.maximumFramePaths, maximumWork: c.maximumWork } };
}
class MergeBudget {
  work: number = 0; characters: number = 0;
  limits: RdbMergeLimits;
  constructor(limits: RdbMergeLimits) { this.limits = limits; }
  spend(n: number = 1): void { this.work += n; if (this.work > this.limits.maximumWork) fail('工作预算超限；没有生成截断报告'); }
  input(xml: string): void {
    this.characters += xml.length;
    if (this.characters > this.limits.maximumInputCharacters) fail('来源报告合计字符预算超限');
  }
}
function transform(t: RdbTransform): RdbTransform {
  return { rotationDeg: t.rotationDeg, mirror: t.mirror, magnification: t.magnification, x: t.x, y: t.y };
}
function points(p: RdbPoint[]): RdbPoint[] { return p.map((q: RdbPoint): RdbPoint => ({ x: q.x, y: q.y })); }
function value(v: RdbValue, prefix: string): RdbValue {
  const out: RdbValue = { kind: v.kind };
  if (v.tag !== undefined) out.tag = { name: prefix + v.tag.name, user: v.tag.user };
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
function mappedItemTag(tag: RdbTagRef, prefix: string): RdbTagRef {
  const standard: boolean = !tag.user && (tag.name === 'waived' || tag.name === 'important');
  return { name: standard ? tag.name : prefix + tag.name, user: tag.user };
}
function same(a: Object, b: Object): boolean { return JSON.stringify(a) === JSON.stringify(b); }
function summary(): RdbMergeSummary {
  return { sources: 0, inputItems: 0, outputItems: 0, values: 0, cells: 0, categories: 0,
    tagDefinitions: 0, preserved: 0, reused: 0, renamed: 0, conflicts: 0, notices: 0 };
}
interface MergeBuild { plan: RdbMergePlan; document: RdbDocument; }
function build(inputs: RdbMergeInput[], requestedOptions: RdbMergeOptions, requestedLimits: RdbMergeLimits): MergeBuild {
  const options: RdbMergeOptions = copyOptions(requestedOptions), limits: RdbMergeLimits = copyLimits(requestedLimits);
  if (!Array.isArray(inputs) || inputs.length < 2 || inputs.length > limits.maximumSources) fail('请选择至少两个不同来源，且不能超过来源预算');
  const budget: MergeBudget = new MergeBudget(limits), ids: Set<string> = new Set<string>();
  const plan: RdbMergePlan = { schemaVersion: 1, mergeSemantics: 'hongtu-lossless-rdb-merge/v1', options, limits,
    sources: [], provenance: [], rows: [], summary: summary(), canApply: false, outputXml: '',
    notices: ['全部标记按来源顺序保留，重复标记与不同审阅状态分别保留；没有去重或自动采纳某个状态。',
      '原始单值说明、文件、生成器、顶层 Cell 和结构映射保存在新报告说明的来源清单中。',
      'KLayout XML 的标签声明不区分系统与用户身份；声明文本得以保留，但不能保证外部软件把描述关联到同名用户标签。',
      '本合并保留 visited，且严格检查同名定义；不宣称与 KLayout merge 的逐项行为完全相同。'] };
  const out: RdbDocument = { schemaVersion: 1, coordinateUnit: 'um', description: '', originalFile: '',
    generator: 'HongTu lossless RDB merge v1', topCell: '', tags: [], categories: [], cells: [], items: [] };
  const cellDefs: Map<string, RdbCell> = new Map<string, RdbCell>();
  const categoryDefs: Map<string, RdbCategory> = new Map<string, RdbCategory>();
  const tagDefs: Map<string, RdbTag[]> = new Map<string, RdbTag[]>();
  const tagMeanings: Map<string, string[]> = new Map<string, string[]>();
  const row = (kind: RdbMergeRowKind, status: RdbMergeRowStatus, sourceIndex: number, sourceLabel: string,
    outputLabel: string, reason: string, sourceItemIndex: number = -1, outputItemIndex: number = -1): void => {
    budget.spend();
    if (plan.rows.length >= limits.maximumPlanRows) fail('完整预览行超过预算；没有截断预览');
    plan.rows.push({ kind, status, sourceIndex, reportId: inputs[sourceIndex].reportId,
      sourceLabel, outputLabel, reason, sourceItemIndex, outputItemIndex });
    if (status === 'preserved') plan.summary.preserved++;
    else if (status === 'reused') plan.summary.reused++;
    else if (status === 'renamed') plan.summary.renamed++;
    else if (status === 'conflict') plan.summary.conflicts++;
    else plan.summary.notices++;
  };
  // Validate all complete inputs before assigning structures or records.
  for (const input of inputs) {
    keys(input, ['reportId', 'sourceIdentity', 'contentToken', 'document'], '来源');
    for (const t of [input.reportId, input.sourceIdentity, input.contentToken]) text(t, '来源身份', true);
    if (ids.has(input.reportId)) fail('同一报告不能重复选择'); ids.add(input.reportId);
    const encoded = serializeRdb(input.document, limits.codec);
    if (!encoded.ok || encoded.xml === undefined) fail('来源报告无效：' + encoded.message);
    budget.input(encoded.xml); budget.spend(input.document.items.length + input.document.cells.length);
    plan.sources.push({ reportId: input.reportId, sourceIdentity: input.sourceIdentity,
      contentToken: input.contentToken, canonicalXml: encoded.xml });
    plan.summary.inputItems += input.document.items.length;
  }
  if (plan.summary.inputItems > limits.codec.maximumItems) fail('全部来源标记合计超过新报告预算；没有丢弃标记');
  plan.summary.sources = inputs.length;
  const namespace: boolean = options.structurePolicy === 'namespace-sources';
  if (!namespace) {
    out.topCell = inputs[0].document.topCell;
    for (let s: number = 1; s < inputs.length; s++) {
      if (inputs[s].document.topCell !== out.topCell) row('issue', 'conflict', s, inputs[s].document.topCell,
        out.topCell, '各报告的顶层 Cell 不一致；请选择按报告隔离，避免猜测共同坐标来源。');
    }
  }
  for (let s: number = 0; s < inputs.length; s++) {
    const input: RdbMergeInput = inputs[s], d: RdbDocument = input.document;
    const ns: string = namespace ? 'source-' + String(s + 1) : '', prefix: string = namespace ? ns + '/' : '';
    const cellMap: Map<string, string> = new Map<string, string>();
    for (const c of d.cells) cellMap.set(rdbCellQName(c), prefix + rdbCellQName(c));
    const p: RdbMergeSourceProvenance = { sourceIndex: s, reportId: input.reportId, sourceIdentity: input.sourceIdentity,
      namespace: ns, description: d.description, originalFile: d.originalFile, generator: d.generator,
      topCell: d.topCell, mappedTopCell: d.topCell === '' ? '' : prefix + d.topCell,
      tagDefinitions: d.tags.map((t: RdbTag): RdbTag => ({ name: t.name, description: t.description })),
      cellMappings: [], categoryMappings: [], tagMappings: [] };
    plan.provenance.push(p);
    row('metadata', 'preserved', s, '说明 / 文件 / 生成器 / 顶层 Cell', '新报告说明的来源清单', '各来源单值字段完整保留，没有任取第一份报告覆盖其它来源。');
    if (namespace && d.topCell !== '' && !cellMap.has(d.topCell)) row('issue', 'notice', s, d.topCell,
      p.mappedTopCell, '原报告顶层名称没有对应 Cell 记录；来源名称保留，不伪造引用或可定位的顶层结构。');
    for (const c of d.cells) {
      const oldName: string = rdbCellQName(c), newName: string = cellMap.get(oldName)!;
      const mapped: RdbCell = { name: prefix + c.name, variant: c.variant, layoutName: c.layoutName,
        references: c.references.map((ref: RdbReference): RdbReference =>
          ({ parentCell: cellMap.get(ref.parentCell)!, transform: transform(ref.transform) })) };
      p.cellMappings.push({ sourceLabel: oldName, outputLabel: newName });
      const existing: RdbCell | undefined = cellDefs.get(newName);
      if (existing === undefined) {
        cellDefs.set(newName, mapped); out.cells.push(mapped);
        row('cell', namespace ? 'renamed' : 'preserved', s, oldName, newName, '原始名称、变体、版图映射及全部有序引用保留；未建立跨来源引用。');
      } else if (same(existing, mapped)) row('cell', 'reused', s, oldName, newName, '完整 Cell 定义和引用一致，显式复用同一结构。');
      else row('cell', 'conflict', s, oldName, newName, '同名 Cell 的原始名称、变体、版图映射或引用不同；请选择按报告隔离。');
    }
    let categoryRoot: RdbCategory[] = out.categories;
    if (namespace) {
      const sourceCategory: RdbCategory = { name: ns, description: '来源 ' + input.reportId, categories: [] };
      out.categories.push(sourceCategory); categoryRoot = sourceCategory.categories;
      p.categoryMappings.push({ sourceLabel: '', outputLabel: rdbCategoryPath([ns]), usage: 'namespace-root' });
      row('category', 'renamed', s, '来源类别根', rdbCategoryPath([ns]),
        '新建来源隔离根，原类别作为子类别；没有修改来源报告或伪造原始类别说明。');
    }
    const categories = (source: RdbCategory[], target: RdbCategory[], originalPath: string[], outputPath: string[]): void => {
      for (const c of source) {
        const oldPath: string[] = originalPath.concat([c.name]), newPath: string[] = outputPath.concat([c.name]);
        const oldLabel: string = rdbCategoryPath(oldPath), newLabel: string = rdbCategoryPath(newPath);
        p.categoryMappings.push({ sourceLabel: oldLabel, outputLabel: newLabel });
        let mapped: RdbCategory | undefined = categoryDefs.get(newLabel);
        if (mapped === undefined) {
          mapped = { name: c.name, description: c.description, categories: [] };
          categoryDefs.set(newLabel, mapped); target.push(mapped);
          row('category', namespace ? 'renamed' : 'preserved', s, oldLabel, newLabel, '类别路径和原说明完整保留。');
        } else if (mapped.description === c.description) row('category', 'reused', s, oldLabel, newLabel, '相同类别路径和说明显式复用；子类别分别核对。');
        else row('category', 'conflict', s, oldLabel, newLabel, '相同类别路径的说明不同；请选择按报告隔离以保留两份说明。');
        categories(c.categories, mapped.categories, oldPath, newPath);
      }
    };
    categories(d.categories, categoryRoot, [], namespace ? [ns] : []);
    // Exact declaration multiplicity/order is retained per source. Shared names may be reused only as identical groups.
    const currentTags: Map<string, RdbTag[]> = new Map<string, RdbTag[]>();
    for (const tag of d.tags) {
      const group: RdbTag[] = currentTags.get(tag.name) ?? [];
      group.push({ name: tag.name, description: tag.description }); currentTags.set(tag.name, group);
    }
    const meanings: Map<string, Set<string>> = new Map<string, Set<string>>();
    const meaning = (name: string, kind: string): void => {
      const set: Set<string> = meanings.get(name) ?? new Set<string>(); set.add(kind); meanings.set(name, set);
    };
    for (const item of d.items) {
      for (const t of item.tags) meaning(t.name, t.user ? '用户标记' : '系统标记');
      for (const v of item.values) {
        budget.spend(); plan.summary.values++;
        if (plan.summary.values > limits.codec.maximumValues) fail('完整值数量超过新报告预算');
        if (v.tag !== undefined) meaning(v.tag.name, v.tag.user ? '用户值标签' : '系统值标签');
      }
    }
    // Referenced-but-undeclared names and the user/system/value identity are visible mappings too.
    const referenceMappings: Set<string> = new Set<string>();
    for (const item of d.items) {
      for (const t of item.tags) {
        const identity: string = (t.user ? 'user-item:' : 'system-item:') + t.name;
        if (referenceMappings.has(identity)) continue; referenceMappings.add(identity);
        const mapped: RdbTagRef = mappedItemTag(t, prefix);
        p.tagMappings.push({ sourceLabel: t.name, outputLabel: mapped.name, usage: t.user ? 'user-item' : 'system-item' });
        row('tag', mapped.name === t.name ? 'preserved' : 'renamed', s,
          (t.user ? '用户标记 ' : '系统标记 ') + t.name, mapped.name,
          !t.user && (t.name === 'waived' || t.name === 'important') ?
            '标准审阅系统标志保持固定语义；不会新增或改写标签声明。' :
            '标记引用的名称和系统/用户身份分别映射；无声明的名称仍无声明。');
      }
      for (const v of item.values) {
        if (v.tag === undefined) continue;
        const identity: string = (v.tag.user ? 'user-value:' : 'system-value:') + v.tag.name;
        if (referenceMappings.has(identity)) continue; referenceMappings.add(identity);
        const newName: string = prefix + v.tag.name;
        p.tagMappings.push({ sourceLabel: v.tag.name, outputLabel: newName, usage: v.tag.user ? 'user-value' : 'system-value' });
        row('tag', newName === v.tag.name ? 'preserved' : 'renamed', s,
          (v.tag.user ? '用户值标签 ' : '系统值标签 ') + v.tag.name, newName,
          '值标签属于完整有序值，明确保留其名称与系统/用户身份；不当作审阅开关。');
      }
    }
    if (!namespace) {
      for (const name of meanings.keys()) {
        const kinds: string[] = Array.from(meanings.get(name)!).sort();
        const existing: string[] | undefined = tagMeanings.get(name);
        const standardReviewOnly: boolean = (name === 'waived' || name === 'important') &&
          kinds.every((kind: string): boolean => kind === '用户标记' || kind === '系统标记') &&
          (existing === undefined || existing.every((kind: string): boolean => kind === '用户标记' || kind === '系统标记'));
        if (existing !== undefined && !same(existing, kinds) && !standardReviewOnly) row('tag', 'conflict', s, name, name,
          '同名标签在来源中分别用于不同身份或值含义；请选择按报告隔离。');
        else if (existing === undefined) tagMeanings.set(name, kinds);
      }
    }
    const groupStatuses: Map<string, RdbMergeRowStatus> = new Map<string, RdbMergeRowStatus>();
    for (const tag of d.tags) {
      const newName: string = prefix + tag.name;
      p.tagMappings.push({ sourceLabel: tag.name, outputLabel: newName, usage: 'declaration' });
      if (namespace) {
        out.tags.push({ name: newName, description: tag.description });
        row('tag', 'renamed', s, tag.name, newName, '标签声明的描述和重复顺序保留；标准 waived / important 系统标志仍使用固定语义。');
      } else {
        let status: RdbMergeRowStatus | undefined = groupStatuses.get(tag.name);
        if (status === undefined) {
          const group: RdbTag[] = currentTags.get(tag.name)!, prior: RdbTag[] | undefined = tagDefs.get(tag.name);
          if (prior === undefined) { tagDefs.set(tag.name, group); status = 'preserved'; }
          else { budget.spend(prior.length + group.length); status = same(prior, group) ? 'reused' : 'conflict'; }
          groupStatuses.set(tag.name, status);
        }
        if (status === 'preserved') {
          out.tags.push({ name: tag.name, description: tag.description });
          row('tag', 'preserved', s, tag.name, newName, '有序声明及描述保留，包括同名重复声明。');
        } else if (status === 'reused') row('tag', 'reused', s, tag.name, newName, '同名声明的完整有序描述一致，显式复用。');
        else row('tag', 'conflict', s, tag.name, newName, '同名标签的描述或声明数量不同；请选择按报告隔离。');
      }
    }
    for (let i: number = 0; i < d.items.length; i++) {
      const item: RdbItem = d.items[i];
      const mapped: RdbItem = { cell: cellMap.get(item.cell)!, category: namespace ? [ns].concat(item.category) : item.category.slice(),
        tags: item.tags.map((t: RdbTagRef): RdbTagRef => mappedItemTag(t, prefix)), visited: item.visited,
        multiplicity: item.multiplicity, comment: item.comment, image: item.image,
        values: item.values.map((v: RdbValue): RdbValue => value(v, prefix)) };
      const outputIndex: number = out.items.length; out.items.push(mapped);
      row('item', 'preserved', s, '标记 ' + String(i + 1), '标记 ' + String(outputIndex + 1),
        '全部有序值、图片、数量、评论、已访问状态及系统/用户标签分别保留；重复记录不合并。', i, outputIndex);
    }
  }
  plan.summary.outputItems = out.items.length; plan.summary.cells = out.cells.length;
  plan.summary.categories = categoryDefs.size + (namespace ? inputs.length : 0);
  plan.summary.tagDefinitions = out.tags.length;
  out.description = options.outputDescription + (options.outputDescription === '' ? '' : '\n\n') +
    '[HongTu RDB merge provenance / 来源清单 v1]\n' + JSON.stringify({
      schema: 'hongtu-rdb-merge-provenance/v1', outputName: options.outputName,
      structurePolicy: options.structurePolicy, sources: plan.provenance, notices: plan.notices });
  plan.canApply = plan.summary.conflicts === 0;
  if (plan.canApply) {
    const encoded = serializeRdb(out, limits.codec);
    if (!encoded.ok) fail('完整合并报告无法保存：' + encoded.message);
    plan.outputXml = encoded.xml!;
  }
  return { plan, document: out };
}
export function previewRdbMerge(inputs: RdbMergeInput[], options: RdbMergeOptions,
  limits: RdbMergeLimits = defaultRdbMergeLimits()): RdbMergePreviewResult {
  try {
    const result: MergeBuild = build(inputs, options, limits);
    return { ok: true, message: result.plan.canApply ? '完整合并预览已生成；全部来源保持原样。' :
      '合并存在结构冲突，尚未创建报告；可改为按报告隔离后重新预览。', plan: result.plan };
  } catch (error) { return { ok: false, message: (error as Error).message }; }
}
export function applyRdbMerge(inputs: RdbMergeInput[], plan: RdbMergePlan): RdbMergeApplyResult {
  try {
    if (plan === null || plan === undefined || plan.schemaVersion !== 1 || plan.mergeSemantics !== 'hongtu-lossless-rdb-merge/v1') fail('合并预览格式无效');
    const fresh: MergeBuild = build(inputs, plan.options, plan.limits);
    if (!same(fresh.plan, plan)) fail('来源内容、顺序、选项或预览已改变；请重新预览');
    if (!fresh.plan.canApply) fail('结构冲突尚未解决，没有创建合并报告');
    return { ok: true, message: '已生成独立合并报告；所有来源保持原样，新报告仍需保存。',
      document: fresh.document, outputName: fresh.plan.options.outputName, summary: fresh.plan.summary };
  } catch (error) { return { ok: false, message: (error as Error).message }; }
}
export class RdbMergeService {
  preview(inputs: RdbMergeInput[], options: RdbMergeOptions, limits?: RdbMergeLimits): RdbMergePreviewResult {
    return previewRdbMerge(inputs, options, limits);
  }
  apply(inputs: RdbMergeInput[], plan: RdbMergePlan): RdbMergeApplyResult { return applyRdbMerge(inputs, plan); }
}
export const rdbMergeService: RdbMergeService = new RdbMergeService();
