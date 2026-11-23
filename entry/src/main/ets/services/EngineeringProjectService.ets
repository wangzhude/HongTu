import type { PythonEditorDraft, PythonTemplate } from './PythonWorkspaceService';
import type { PCellVariant } from './WorkspaceService';
import { parseRuleSetText, copyCanonicalDrcRules } from '../common/drcRuleText';
import type { DrcRuleTextResult } from '../common/drcRuleText';
import type { DrcRule } from '../common/drcRulesets';
import { parseTechnologyPackage } from '../common/technologyPackage';
import type { TechnologyPackage, TechnologyParseResult, TechnologyLayer, TechnologyDevice } from '../common/technologyPackage';
import type { NativeViaLayer } from '../../cpp/types/libhongtu/Index';
import { engineeringReviewBundleService, engineeringReviewBytes } from './EngineeringReviewBundleService';
import type { EngineeringReviewBundle } from '../models/EngineeringReviewBundle';
import { cloneStructured } from '../common/CloneUtils';

export interface EngineeringPythonBundle { draft?: PythonEditorDraft; templates: PythonTemplate[]; }
export interface EngineeringDependency { kind: string; name: string; version: string; status: string; message: string; }
export interface EngineeringSourceChecksum { name: string; algorithm: string; value: string; }
export interface EngineeringProjectBundle {
  format: string;
  schemaVersion: number;
  workspaceId: string;
  createdAt: number;
  python: EngineeringPythonBundle;
  macrosJson: string;
  drcDeckJson: string;
  technologyJson: string;
  pcells: PCellVariant[];
  dependencies: EngineeringDependency[];
  sourceChecksums: EngineeringSourceChecksum[];
  review?: EngineeringReviewBundle | null;
}
export interface EngineeringProjectSnapshot {
  workspaceId: string;
  python?: EngineeringPythonBundle;
  macrosJson?: string;
  drcDeckJson?: string;
  technologyJson?: string;
  pcells?: PCellVariant[];
  dependencies?: EngineeringDependency[];
  toolVersions?: Record<string, string>;
  review?: EngineeringReviewBundle | null;
}
export interface EngineeringEnvironment {
  availablePCells: string[];
  pythonAvailable?: boolean;
  pythonEmbedded?: boolean;
  klayoutAvailable?: boolean;
  klayoutEmbeddedCompat?: boolean;
  toolVersions?: Record<string, string>;
  availableDeckIds?: string[];
  verifierAvailable?: boolean;
}
export interface EngineeringDependencyReport {
  dependencies: EngineeringDependency[];
  canView: boolean;
  canEdit: boolean;
  canRegenerate: boolean;
  canVerify: boolean;
  messages: string[];
}
export interface EngineeringRestorePayload {
  python: EngineeringPythonBundle;
  macrosJson: string;
  drcDeckJson: string;
  technologyJson: string;
  sourceWorkspaceId: string;
  targetWorkspaceId: string;
}

interface EngineeringMacroStep { description: string; command: string; type: string; }
interface EngineeringMacro { name: string; description: string; originDocumentId: string; steps: EngineeringMacroStep[]; }
interface EngineeringMacros { format: string; version: string; macros: EngineeringMacro[]; }
interface EngineeringRuleEnvelope { rules?: Object[]; drcRules?: Object[]; }
interface EngineeringDrcDeck { name: string; rules: DrcRule[]; }

const CHANGE_ALGORITHM: string = 'fnv1a32-utf16-change-detection';
const MAX_TOOLS_BYTES: number = 8 * 1024 * 1024;

/** This is a change detector, not a signature, authentication or adversarial integrity check. */
export function engineeringChecksum(text: string): string {
  let hash: number = 2166136261;
  for (let i = 0; i < text.length; i++) { hash ^= text.charCodeAt(i); hash = Math.imul(hash, 16777619); }
  return (hash >>> 0).toString(16).padStart(8, '0');
}

function validText(value: string, maximum: number): boolean { return typeof value === 'string' && value.length <= maximum; }
function validatePython(python: EngineeringPythonBundle): void {
  if (python === null || typeof python !== 'object' || !Array.isArray(python.templates) || python.templates.length > 32) throw new Error('工程 Python 模板结构或数量无效');
  if (python.draft !== undefined) {
    const draft: PythonEditorDraft = python.draft;
    if (draft === null || typeof draft !== 'object' || ['new', 'document', 'selection'].indexOf(draft.inputMode) < 0 ||
      !validText(draft.script, 65536) || !validText(draft.parameters, 512 * 1024) || !validText(draft.request, 16000) ||
      !validText(draft.sweepName, 256) || !validText(draft.sweepValues, 2048) || !validText(draft.templateName, 100)) throw new Error('工程 Python 草稿无效');
  }
  const ids: Set<number> = new Set<number>();
  for (const item of python.templates) {
    if (item === null || typeof item !== 'object' || !Number.isSafeInteger(item.id) || item.id < 0 || ids.has(item.id) ||
      !validText(item.name, 100) || item.name.trim().length === 0 || !validText(item.script, 65536) || item.script.trim().length === 0 ||
      !validText(item.parameters, 512 * 1024) || ['new', 'document', 'selection'].indexOf(item.inputMode) < 0 ||
      (item.sweepName !== undefined && !validText(item.sweepName, 256)) || (item.sweepValues !== undefined && !validText(item.sweepValues, 2048))) throw new Error('工程 Python 模板无效或 ID 重复');
    ids.add(item.id);
  }
}

/** Pick fields explicitly; no provider configuration, credentials, transport state or run history. */
function copyPython(python: EngineeringPythonBundle): EngineeringPythonBundle {
  validatePython(python);
  const result: EngineeringPythonBundle = { templates: python.templates.map((item: PythonTemplate): PythonTemplate => ({
    id: item.id, name: item.name, script: item.script, parameters: item.parameters, inputMode: item.inputMode,
    sweepName: item.sweepName, sweepValues: item.sweepValues })) };
  if (python.draft !== undefined) {
    const draft: PythonEditorDraft = python.draft;
    result.draft = { script: draft.script, parameters: draft.parameters, inputMode: draft.inputMode, request: draft.request,
      sweepName: draft.sweepName, sweepValues: draft.sweepValues, templateName: draft.templateName };
  }
  return result;
}

function validateJson(text: string, title: string): void {
  if (!validText(text, 2 * 1024 * 1024)) throw new Error(`${title}超过工程文本预算`);
  if (text.length === 0) return;
  const value: Object = JSON.parse(text) as Object;
  if (value === null || typeof value !== 'object') throw new Error(`${title}须为 JSON 对象或数组`);
}

function copyDeckJson(text: string): string {
  validateJson(text, 'DRC 规则');
  if (text.length === 0) return '';
  const parsed: EngineeringDrcDeck = JSON.parse(text) as EngineeringDrcDeck;
  const rules: Object[] = Array.isArray(parsed) ? parsed as Object[] : parsed.rules as Object[];
  if (!Array.isArray(rules) || rules.length > 4096) throw new Error('工程 DRC 规则须含最多 4096 项 rules 数组');
  const name: string = Array.isArray(parsed) ? '工程规则' : parsed.name ?? '工程规则';
  if (!validText(name, 256)) throw new Error('工程 DRC 规则名称无效');
  if (rules.length === 0) return JSON.stringify({ name, rules: [] } as EngineeringDrcDeck);
  const incoming: EngineeringDrcDeck = { name, rules: rules as DrcRule[] };
  const result: DrcRuleTextResult = parseRuleSetText(JSON.stringify(incoming), true);
  if (!result.ok) throw new Error(`工程 DRC 规则：${result.error}`);
  return JSON.stringify({ name: result.setName, rules: result.rules } as EngineeringDrcDeck);
}

function copyTechnologyJson(text: string): string {
  validateJson(text, '工艺包');
  if (text.length === 0) return '';
  const result: TechnologyParseResult = parseTechnologyPackage(text);
  if (!result.ok || result.technology === undefined) throw new Error(`工程工艺包：${result.error}`);
  const tech: TechnologyPackage = result.technology;
  // Keep the existing public package export boundary. Unknown root/layer
  // provider fields can contain service credentials and are not exported.
  const selected: TechnologyPackage = { schema: tech.schema, id: tech.id, name: tech.name, version: tech.version,
    source: tech.source, license: tech.license, qualification: tech.qualification,
    layers: tech.layers.map((item: TechnologyLayer): TechnologyLayer => ({ name: item.name, layerNumber: item.layerNumber, datatype: item.datatype, purpose: item.purpose, color: item.color })),
    viaLayers: tech.viaLayers.map((item: NativeViaLayer): NativeViaLayer => ({ viaLayer: item.viaLayer, lowerLayer: item.lowerLayer, upperLayer: item.upperLayer,
      viaDatatype: item.viaDatatype, lowerDatatype: item.lowerDatatype, upperDatatype: item.upperDatatype })),
    drcRules: tech.drcRules,
    devices: tech.devices.map((item: TechnologyDevice): TechnologyDevice => ({ name: item.name, pcell: item.pcell, model: item.model, parameters: item.parameters })),
    drcDeckId: tech.drcDeckId, lvsDeckId: tech.lvsDeckId };
  if (tech.layerStack !== undefined) {
    let work: number = 0;
    const cleanse = (value: Object, depth: number): Object => {
      if (++work > 200000 || depth > 64) throw new Error('工程层栈 metadata 超过完整清理预算');
      if (value === null || typeof value !== 'object') return value;
      if (Array.isArray(value)) return (value as Object[]).map((item: Object): Object => cleanse(item, depth + 1));
      const original: Record<string, Object> = value as Record<string, Object>, safe: Record<string, Object> = {};
      for (const key of Object.keys(original)) {
        const normalized: string = key.replace(/[^a-z0-9]/gi, '').toLowerCase();
        if (['credential', 'credentials', 'token', 'accesstoken', 'refreshtoken', 'password', 'passwd', 'apikey',
          'privatekey', 'clientsecret', 'secret', 'secrets', 'authorization', 'cookie', 'cookies', 'sessionkey',
          'prototype', 'proto', 'constructor'].includes(normalized)) continue;
        const item: Object = original[key];
        if (normalized === 'infojson' && typeof item === 'string') {
          const info: Object = JSON.parse(item as string) as Object;
          if (info === null || typeof info !== 'object' || Array.isArray(info)) throw new Error('工程层栈 infoJson 必须是惰性对象，敏感字段须显式移除');
          safe[key] = JSON.stringify(cleanse(info, depth + 1));
        } else safe[key] = cleanse(item, depth + 1);
      }
      return safe;
    };
    const rawLayerStack: Record<string, Object> = {};
    rawLayerStack['layerStack'] = cleanse(tech.layerStack as Object, 0);
    const payload: TechnologyPackage = cloneStructured(rawLayerStack) as Object as TechnologyPackage;
    selected.layerStack = payload.layerStack;
    const checked: TechnologyParseResult = parseTechnologyPackage(JSON.stringify(selected));
    if (!checked.ok || checked.technology === undefined) throw new Error(`工程层栈清理后无效：${checked.error}`);
  }
  return JSON.stringify(selected);
}

function scopeMacros(json: string, workspaceId: string, importing: boolean): string {
  if (!validText(json, 1024 * 1024)) throw new Error('工程宏超过 1 MiB');
  if (json.length === 0) return '';
  const source: EngineeringMacros = JSON.parse(json) as EngineeringMacros;
  if (source === null || typeof source !== 'object' || !Array.isArray(source.macros) ||
    source.macros.length > (importing ? 100 : 10000)) throw new Error('工程宏集合格式无效或超过预算');
  const macros: EngineeringMacro[] = [];
  for (const macro of source.macros) {
    if (macro === null || typeof macro !== 'object') throw new Error('工程宏无效');
    if (macro.originDocumentId !== workspaceId) {
      if (importing) throw new Error('工程宏包含其他文档或全局宏');
      continue;
    }
    if (macros.length >= 100) throw new Error('当前文档工程宏超过 100 项，未保存工具快照');
    if (!validText(macro.name, 120) || macro.name.trim().length === 0 || !validText(macro.description, 4000) ||
      !Array.isArray(macro.steps) || macro.steps.length === 0 || macro.steps.length > 1000) throw new Error('工程宏名称或步骤无效');
    const steps: EngineeringMacroStep[] = [];
    for (const step of macro.steps) {
      if (step === null || typeof step !== 'object' || !validText(step.description, 1000) || !validText(step.command, 16000) ||
        step.command.trim().length === 0 || ['draw', 'edit', 'layer', 'view', 'drc', 'ai'].indexOf(step.type) < 0) throw new Error('工程宏步骤无效');
      steps.push({ description: step.description, command: step.command, type: step.type });
    }
    macros.push({ name: macro.name, description: macro.description, originDocumentId: workspaceId, steps });
  }
  if (macros.length === 0) return '';
  return JSON.stringify({ format: 'HongTu-Macro-Collection', version: '1.0', macros } as EngineeringMacros);
}

function copyPCell(item: PCellVariant): PCellVariant {
  if (item === null || typeof item !== 'object' || !Number.isSafeInteger(item.cellId) || item.cellId < 0 || item.cellId > 2147483647 ||
    !validText(item.name, 128) || item.name.length === 0 || item.params === null || typeof item.params !== 'object' || Array.isArray(item.params)) throw new Error('工程 PCell 意图无效');
  const params: Record<string, number | string | boolean> = {};
  const keys: string[] = Object.keys(item.params);
  if (keys.length > 128) throw new Error('工程 PCell 参数过多');
  for (const key of keys) {
    const value = item.params[key];
    if (key.length === 0 || key.length > 128 || ['number', 'string', 'boolean'].indexOf(typeof value) < 0 ||
      (typeof value === 'number' && !Number.isFinite(value)) || (typeof value === 'string' && value.length > 4096)) throw new Error('工程 PCell 参数无效');
    params[key] = value;
  }
  for (const text of [item.technologyId, item.technologyVersion, item.deviceName, item.deviceModel]) {
    if (text !== undefined && (!validText(text, 120) || text.length === 0 || text.includes('\0'))) throw new Error('工程 PCell 工艺器件身份无效');
  }
  const selected: PCellVariant = { cellId: item.cellId, name: item.name, params };
  if (item.technologyId !== undefined) selected.technologyId = item.technologyId;
  if (item.technologyVersion !== undefined) selected.technologyVersion = item.technologyVersion;
  if (item.deviceName !== undefined) selected.deviceName = item.deviceName;
  if (item.deviceModel !== undefined) selected.deviceModel = item.deviceModel;
  return selected;
}

function checksums(bundle: EngineeringProjectBundle): EngineeringSourceChecksum[] {
  const values: string[] = [JSON.stringify(bundle.python), bundle.macrosJson, bundle.drcDeckJson, bundle.technologyJson, JSON.stringify(bundle.pcells)];
  const names: string[] = ['python', 'macros', 'drc-deck', 'technology', 'pcell-intent'];
  if (Object.keys(bundle).includes('review')) { values.push(JSON.stringify(bundle.review)); names.push('review'); }
  return names.map((name: string, index: number): EngineeringSourceChecksum => ({ name, algorithm: CHANGE_ALGORITHM, value: engineeringChecksum(values[index]) }));
}

function copyDependency(item: EngineeringDependency): EngineeringDependency {
  if (item === null || typeof item !== 'object' || !validText(item.kind, 64) || item.kind.length === 0 ||
    !validText(item.name, 256) || item.name.length === 0 || !validText(item.version, 128) ||
    ['embedded', 'required', 'missing', 'unknown', 'available'].indexOf(item.status) < 0 || !validText(item.message, 1024)) throw new Error('工程依赖清单无效');
  return { kind: item.kind, name: item.name, version: item.version, status: item.status, message: item.message };
}

function containsRules(text: string): boolean {
  if (text.length === 0) return false;
  const payload: EngineeringRuleEnvelope = JSON.parse(text) as EngineeringRuleEnvelope;
  if (Array.isArray(payload)) return (payload as Object[]).length > 0;
  return (Array.isArray(payload.rules) && payload.rules.length > 0) || (Array.isArray(payload.drcRules) && payload.drcRules.length > 0);
}

export class EngineeringProjectService {
  // Session ownership is deliberately absent from the serialized project schema.
  // Reading a file must never grant permission to replace the user's live tools.
  private sessionToolOwners: Set<string> = new Set<string>();

  canRefreshBundle(workspaceId: string, bundle?: EngineeringProjectBundle): boolean {
    return bundle === undefined || this.sessionToolOwners.has(workspaceId);
  }
  markSessionToolsOwned(workspaceId: string): void {
    if (!validText(workspaceId, 256) || workspaceId.length === 0) throw new Error('工程文档身份无效');
    this.sessionToolOwners.add(workspaceId);
  }
  forgetSessionTools(workspaceId: string): void { this.sessionToolOwners.delete(workspaceId); }
  validateLocalPythonDraft(draft: PythonEditorDraft): PythonEditorDraft {
    return copyPython({ draft, templates: [] }).draft as PythonEditorDraft;
  }
  refreshPythonDraftBundle(input: EngineeringProjectBundle, draft: PythonEditorDraft): EngineeringProjectBundle {
    const current: EngineeringProjectBundle = this.validateBundle(input);
    const updated: EngineeringProjectBundle = this.buildBundle({ workspaceId: current.workspaceId,
      python: { draft: this.validateLocalPythonDraft(draft), templates: current.python.templates },
      macrosJson: current.macrosJson, drcDeckJson: current.drcDeckJson, technologyJson: current.technologyJson,
      pcells: current.pcells, dependencies: current.dependencies, review: current.review });
    updated.createdAt = current.createdAt;
    return updated;
  }
  validateProcessPayload(technologyJson: string, drcDeckJson: string): void {
    copyTechnologyJson(technologyJson); copyDeckJson(drcDeckJson);
  }
  validateRuleState(rules: DrcRule[]): void { copyCanonicalDrcRules(rules); }
  refreshProcessBundle(input: EngineeringProjectBundle, technologyJson: string, drcDeckJson: string): EngineeringProjectBundle {
    const current: EngineeringProjectBundle = this.validateBundle(input);
    const snapshot: EngineeringProjectSnapshot = { workspaceId: current.workspaceId, python: current.python,
      macrosJson: current.macrosJson, technologyJson, drcDeckJson, pcells: current.pcells,
      dependencies: current.dependencies.filter((dependency: EngineeringDependency): boolean => dependency.kind !== 'technology' && dependency.kind !== 'deck'), review: current.review };
    const updated: EngineeringProjectBundle = this.buildBundle(snapshot);
    updated.createdAt = current.createdAt;
    return updated;
  }

  buildBundle(snapshot: EngineeringProjectSnapshot): EngineeringProjectBundle {
    if (snapshot === null || typeof snapshot !== 'object' || !validText(snapshot.workspaceId, 256) || snapshot.workspaceId.length === 0) throw new Error('工程文档身份无效');
    const bundle: EngineeringProjectBundle = { format: 'HongTu-Engineering', schemaVersion: 1,
      workspaceId: snapshot.workspaceId, createdAt: Date.now(), python: copyPython(snapshot.python ?? { templates: [] }),
      macrosJson: scopeMacros(snapshot.macrosJson ?? '', snapshot.workspaceId, false), drcDeckJson: copyDeckJson(snapshot.drcDeckJson ?? ''),
      technologyJson: copyTechnologyJson(snapshot.technologyJson ?? ''), pcells: (snapshot.pcells ?? []).map((item: PCellVariant) => copyPCell(item)),
      dependencies: (snapshot.dependencies ?? []).map((item: EngineeringDependency) => copyDependency(item)), sourceChecksums: [] };
    if (snapshot.review !== undefined) {
      bundle.review = snapshot.review === null ? null : engineeringReviewBundleService.validate(snapshot.review);
      if (bundle.review !== null && bundle.review.workspaceId !== bundle.workspaceId) throw new Error('工程审阅与工具来源文档不一致');
      bundle.schemaVersion = 2;
    }
    const names: string[] = [];
    for (const item of bundle.pcells) {
      if (names.indexOf(item.name) >= 0) continue;
      names.push(item.name);
      if (!bundle.dependencies.some((dep: EngineeringDependency) => dep.kind === 'pcell' && dep.name === item.name)) {
        bundle.dependencies.push({ kind: 'pcell', name: item.name, version: '', status: 'required', message: '几何与参数已保存；重新生成需要同名 PCell 定义' });
      }
    }
    if ((bundle.python.draft?.script.trim().length ?? 0) > 0 || bundle.python.templates.length > 0) {
      for (const name of ['Python', 'KLayout']) {
        if (!bundle.dependencies.some((dep: EngineeringDependency) => dep.kind === 'runtime' && dep.name === name)) {
          bundle.dependencies.push({ kind: 'runtime', name, version: snapshot.toolVersions?.[name] ?? '', status: 'required',
            message: '脚本内容已保存；重新执行需要伴随运行环境。未填写版本表示未实测。' });
        }
      }
    }
    if (bundle.technologyJson.length > 0) {
      const tech: TechnologyPackage = JSON.parse(bundle.technologyJson) as TechnologyPackage;
      if (!bundle.dependencies.some((dep: EngineeringDependency) => dep.kind === 'technology')) {
        bundle.dependencies.push({ kind: 'technology', name: tech.name, version: tech.version, status: 'embedded', message: `已嵌入工艺 JSON · ${tech.qualification}` });
      }
      for (const id of [tech.drcDeckId, tech.lvsDeckId]) {
        if (id.length > 0 && !bundle.dependencies.some((dep: EngineeringDependency) => dep.kind === 'deck' && dep.name === id)) {
          bundle.dependencies.push({ kind: 'deck', name: id, version: '', status: 'required', message: `需要已注册验证 deck ${id}；工程文件未嵌入其执行环境` });
        }
      }
    }
    bundle.sourceChecksums = checksums(bundle);
    return this.validateBundle(bundle);
  }

  validateBundle(input: EngineeringProjectBundle | string): EngineeringProjectBundle {
    const raw: string = typeof input === 'string' ? input : JSON.stringify(input);
    if (!validText(raw, 120 * 1024 * 1024) || engineeringReviewBytes(raw) > 120 * 1024 * 1024) throw new Error('工程内容超过120MiB预算');
    const bundle: EngineeringProjectBundle = JSON.parse(raw) as EngineeringProjectBundle;
    if (bundle === null || typeof bundle !== 'object' || Array.isArray(bundle) || bundle.format !== 'HongTu-Engineering' || (bundle.schemaVersion !== 1 && bundle.schemaVersion !== 2) ||
      !validText(bundle.workspaceId, 256) || bundle.workspaceId.length === 0 || !Number.isFinite(bundle.createdAt) || bundle.createdAt < 0 ||
      !Array.isArray(bundle.pcells) || bundle.pcells.length > 100000 || !Array.isArray(bundle.dependencies) || bundle.dependencies.length > 1024 ||
      !Array.isArray(bundle.sourceChecksums)) throw new Error('工程工具格式或版本无效');
    const hasReview: boolean = Object.keys(bundle).includes('review');
    if ((bundle.schemaVersion === 2) !== hasReview || bundle.sourceChecksums.length !== (hasReview ? 6 : 5)) throw new Error('工程工具格式或版本无效');
    const toolOnly: EngineeringProjectBundle = JSON.parse(raw) as EngineeringProjectBundle;
    toolOnly.review = undefined;
    if (JSON.stringify(toolOnly).length > MAX_TOOLS_BYTES) throw new Error('工程工具内容超过 8 MiB');
    const allowed: string[] = ['format', 'schemaVersion', 'workspaceId', 'createdAt', 'python', 'macrosJson', 'drcDeckJson', 'technologyJson', 'pcells', 'dependencies', 'sourceChecksums', 'review'];
    if (Object.keys(bundle).some((key: string) => allowed.indexOf(key) < 0)) throw new Error('工程工具包含非允许字段');
    bundle.python = copyPython(bundle.python);
    bundle.macrosJson = scopeMacros(bundle.macrosJson, bundle.workspaceId, true);
    validateJson(bundle.drcDeckJson, 'DRC 规则'); validateJson(bundle.technologyJson, '工艺包');
    bundle.pcells = bundle.pcells.map((item: PCellVariant) => copyPCell(item));
    bundle.dependencies = bundle.dependencies.map((item: EngineeringDependency) => copyDependency(item));
    if (hasReview && bundle.review !== null) {
      bundle.review = engineeringReviewBundleService.validate(bundle.review as EngineeringReviewBundle);
      if (bundle.review.workspaceId !== bundle.workspaceId) throw new Error('工程审阅与工具来源文档不一致');
    }
    const expected: EngineeringSourceChecksum[] = checksums(bundle);
    for (const checksum of expected) {
      const saved = bundle.sourceChecksums.find((item: EngineeringSourceChecksum) => item.name === checksum.name);
      if (saved === undefined || saved.algorithm !== CHANGE_ALGORITHM || saved.value !== checksum.value) throw new Error(`工程内容变化校验失败：${checksum.name}`);
    }
    if (copyDeckJson(bundle.drcDeckJson) !== bundle.drcDeckJson || copyTechnologyJson(bundle.technologyJson) !== bundle.technologyJson) throw new Error('工程规则或工艺包包含非允许字段或未规范化内容');
    return bundle;
  }

  /** Add or replace the optional carry snapshot without granting live-tool ownership. */
  refreshReviewBundle(input: EngineeringProjectBundle, review: EngineeringReviewBundle | null): EngineeringProjectBundle {
    const bundle: EngineeringProjectBundle = this.validateBundle(input);
    bundle.review = review === null ? null : engineeringReviewBundleService.validate(review);
    bundle.schemaVersion = 2; bundle.sourceChecksums = checksums(bundle);
    return this.validateBundle(bundle);
  }

  dependencyReport(input: EngineeringProjectBundle, environment: EngineeringEnvironment): EngineeringDependencyReport {
    const bundle: EngineeringProjectBundle = this.validateBundle(input);
    const dependencies: EngineeringDependency[] = bundle.dependencies.map((item: EngineeringDependency) => copyDependency(item));
    for (const item of dependencies) {
      if (item.kind === 'pcell') {
        item.status = environment.availablePCells.indexOf(item.name) >= 0 ? 'available' : 'missing';
        item.message = item.status === 'available' ? '同名 PCell 已提供，仍需核对参数与几何结果' : `缺少 PCell ${item.name}，现有几何可查看与编辑，参数不能重生成`;
      } else if (item.kind === 'runtime') {
        const isEmbedded: boolean = (item.name === 'Python' && environment.pythonEmbedded === true) ||
          (item.name === 'KLayout' && environment.klayoutEmbeddedCompat === true);
        const available: boolean | undefined = item.name === 'Python'
          ? (environment.pythonAvailable ?? (isEmbedded ? true : undefined))
          : item.name === 'KLayout'
            ? (environment.klayoutAvailable ?? (isEmbedded ? true : undefined))
            : undefined;
        const actual: string = environment.toolVersions?.[item.name] ?? '';
        if (item.version.length === 0 && actual.length > 0) {
          item.version = actual;
        }
        if (isEmbedded && (item.version.length === 0 || actual.length === 0 || item.version === actual)) {
          item.status = 'embedded';
          if (item.version.length === 0) {
            item.version = item.name === 'Python' ? 'PocketPy 2.2.0' : 'klayout.db 兼容层';
          }
          item.message = item.name === 'Python'
            ? `端侧内置 ${item.version} 已就绪，可直接离线执行参数化版图脚本`
            : '端侧已内置 hongtu / klayout.db 几何与 Clipper2 布尔兼容层';
        } else {
          item.status = available === true ? 'available' : available === false ? 'missing' : 'unknown';
          if (available === true && item.version.length > 0 && actual.length > 0 && actual !== item.version) {
            item.status = 'unknown';
            item.message = `${item.name} 版本需确认：工程 ${item.version} / 当前 ${actual}`;
          } else {
            item.message = `${item.name} ${actual || item.version || '版本未实测'}：${item.status === 'available' ? '运行环境可用' : item.status === 'missing' ? '运行环境缺失' : '运行环境尚未确认'}`;
          }
        }
      } else if (item.kind === 'deck') {
        item.status = environment.availableDeckIds === undefined ? 'unknown' : environment.availableDeckIds.indexOf(item.name) >= 0 ? 'available' : 'missing';
        item.message = `${item.name}：${item.status === 'available' ? '已注册验证 deck，执行资格按其配置检查' : item.status === 'missing' ? '验证 deck 缺失' : '验证 deck 尚未确认'}`;
      }
    }
    const hasRules: boolean = containsRules(bundle.drcDeckJson) || containsRules(bundle.technologyJson);
    const uncertain: EngineeringDependency[] = dependencies.filter((item: EngineeringDependency) => item.status === 'missing' || item.status === 'unknown' || item.status === 'required');
    return { dependencies, canView: true, canEdit: true,
      canRegenerate: !uncertain.some((item: EngineeringDependency) => item.kind === 'pcell' || item.kind === 'runtime'),
      canVerify: environment.verifierAvailable === true && hasRules && !uncertain.some((item: EngineeringDependency) => ['technology', 'drc', 'pdk', 'deck'].indexOf(item.kind) >= 0),
      messages: uncertain.map((item: EngineeringDependency) => item.message) };
  }

  /** Pure payload preparation. The caller's explicit restore button owns storage writes. */
  restoreTools(input: EngineeringProjectBundle, targetWorkspaceId: string): EngineeringRestorePayload {
    const bundle: EngineeringProjectBundle = this.validateBundle(input);
    if (!validText(targetWorkspaceId, 256) || targetWorkspaceId.length === 0) throw new Error('恢复目标文档身份无效');
    let macrosJson: string = '';
    if (bundle.macrosJson.length > 0) {
      const collection: EngineeringMacros = JSON.parse(bundle.macrosJson) as EngineeringMacros;
      collection.macros.forEach((item: EngineeringMacro) => { item.originDocumentId = targetWorkspaceId; });
      macrosJson = JSON.stringify(collection);
    }
    return { python: copyPython(bundle.python), macrosJson, drcDeckJson: bundle.drcDeckJson,
      technologyJson: bundle.technologyJson, sourceWorkspaceId: bundle.workspaceId, targetWorkspaceId };
  }
}
export const engineeringProjectService = new EngineeringProjectService();
