/**
 * 鸿图 DRC 规则清单文本解析 + 违规按规则分组（纯逻辑）
 *
 * 本文件刻意做到**零 UI / 零 native / 零文件 IO**：只 import 类型与内置预设。
 * 原因是 ArkTS 侧没有测试框架，纯函数只有在不牵连 `@kit.*` 与 `libhongtu.so`
 * 时才可能在 host 上直接跑断言（`tools/drc_rules_host_check.mjs`，
 * 先例见 `LypService.lypSelfCheck()`）。
 *
 * 对齐 KLayout 的两处能力：
 * 1. 规则以「带名字 / 层（layer 或 layer/datatype 或层名）/ 检查类型 / 最小值(nm)」的
 *    清单形式由用户给出（粘贴文本或规则文件，JSON 与 CSV 两种风格都吃）；
 *    装载失败给出可显示的中文错误（含行号），**不静默回退到内置预设**。
 * 2. 结果按规则分类统计：每条规则命中数 + 0 命中也如实列出，首条命中带坐标可逐条定位。
 *
 * 完整性告警口径（硬约束）：`DRC.TRUNC`（native 展开图形数触顶）与 `DRC.NOHIER`
 * （部分规则走了不展开层级的 ArkTS 补检）**不是规则违例**，而是「这次结果是否完整」的
 * 告警。判定唯一入口是 isCompletenessNotice()：分组计数与 passed 判定都必须先排除它们，
 * 否则一条 TRUNC 会让所有规则看起来都「可能被漏检」却被记成某条规则的命中。
 *
 * ⚠ 规则清单只改变「测什么、阈值多少」；检查本身仍是逐图形测量、无同层布尔合并的
 *   快速几何预检查，非签核（见 DrcService 头注释与 gap-matrix §尾，措辞不得弱化）。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

// 接口用 `import type`（纯类型在 ArkTS 编译期擦除，Node 侧直跑也拿不到该导出）；
// 枚举与常量是真实运行时值，必须走普通 import。
import type { DrcRule } from './drcRulesets';
import type { LayerNameEntry } from './constants';
import { DrcRuleType, DrcSeverity, RULESET_28NM } from './drcRulesets';
import { LAYER_NAME_MAP } from './constants';

/** 完整性告警 ruleId：native 层级展开图形数触顶，结果不完整（由 drc_engine.h 侧产出） */
export const DRC_NOTICE_TRUNC: string = 'DRC.TRUNC';
/** 完整性告警 ruleId：部分规则由不展开层级的 ArkTS 回退路径补检（由 DrcService 产出） */
export const DRC_NOTICE_NOHIER: string = 'DRC.NOHIER';
export const DRC_NOTICE_MERGE: string = 'DRC.MERGE';
export const DRC_NOTICE_MEASURE: string = 'DRC.MEASURE';
export const DRC_NOTICE_EXEC: string = 'DRC.EXEC';
export const DRC_NOTICE_OUTPUT: string = 'DRC.OUTPUT';

/** true = 该 ruleId 是「结果是否完整」告警而非规则违例（不得计入任何规则的命中数） */
export function isCompletenessNotice(ruleId: string): boolean {
  return ruleId === DRC_NOTICE_TRUNC || ruleId === DRC_NOTICE_NOHIER ||
    ruleId === DRC_NOTICE_MERGE || ruleId === DRC_NOTICE_MEASURE || ruleId === DRC_NOTICE_EXEC ||
    ruleId === DRC_NOTICE_OUTPUT;
}

/** 两条告警的固定中文标题（violations 里 ruleName 缺失时的兜底显示） */
const NOTICE_TITLES: string[] = [
  DRC_NOTICE_TRUNC + '｜结果不完整：层级展开图形数触顶，超出部分未检查',
  DRC_NOTICE_NOHIER + '｜结果不完整：部分规则未展开实例层级（仅测本 Cell 本地几何）',
  DRC_NOTICE_MERGE + '｜结果不完整：同层区域合并未覆盖',
  DRC_NOTICE_MEASURE + '｜结果不完整：区域测量超过复杂度上限',
  DRC_NOTICE_OUTPUT + '｜结果不完整：违规显示行数触顶，部分命中未显示',
  DRC_NOTICE_EXEC + '｜结果不完整：部分规则未完成',
];

/** 内置预设的规则集显示名（单一真源：drcRulesets.RULESET_28NM） */
export const BUILTIN_PRESET_NAME: string = RULESET_28NM.name;

/** 规则清单默认列序（无表头时按此位置解析；与 ruleSetToText 输出严格一致） */
export const DRC_RULE_CSV_HEADER: string =
  'ruleId,type,layer,datatype,min,target,name,severity,description,enabled';

/** 清单格式标识 */
export const DRC_TEXT_FORMAT_JSON: string = 'json';
export const DRC_TEXT_FORMAT_CSV: string = 'csv';

// ==================== 类型 / 单位 / 图层显示 ====================

/** 检查类型中文显示名（面板与错误文案共用，避免出现第二套约定） */
export function typeLabel(type: DrcRuleType): string {
  if (type === DrcRuleType.MIN_WIDTH) {
    return '最小宽度';
  }
  if (type === DrcRuleType.MIN_SPACING) {
    return '最小间距';
  }
  if (type === DrcRuleType.MIN_AREA) {
    return '最小面积';
  }
  if (type === DrcRuleType.MIN_ENCLOSURE) {
    return '最小包围';
  }
  if (type === DrcRuleType.DENSITY) {
    return '密度';
  }
  return '规则';
}

/** 规则参数单位：密度为 %，面积为 nm²，其余为 nm */
export function unitLabel(type: DrcRuleType): string {
  if (type === DrcRuleType.DENSITY) {
    return '%';
  }
  if (type === DrcRuleType.MIN_AREA) {
    return 'nm²';
  }
  return 'nm';
}

/** 严重等级中文显示名 */
export function severityLabel(sev: DrcSeverity): string {
  if (sev === DrcSeverity.ERROR) {
    return '错误';
  }
  if (sev === DrcSeverity.WARNING) {
    return '警告';
  }
  return '提示';
}

/**
 * 图层规格显示文本：`L1 金属1`，带精确 datatype 时 `L1/5 金属1`。
 * 层名来自唯一的命名真源 `constants.LAYER_NAME_MAP`，未知层号退化为 `L{n}`。
 */
export function layerSpecText(layerNumber: number, datatype: number): string {
  const mapped: LayerNameEntry | undefined = LAYER_NAME_MAP.get(layerNumber);
  const base: string = 'L' + layerNumber.toString() + (mapped !== undefined ? ' ' + mapped.chinese : '');
  return datatype >= 0 ? base + '/' + datatype.toString() : base;
}

/**
 * 层名 → 层号（大小写不敏感，支持英文名与中文名）。未识别返回 -1。
 * 命名真源只有 `constants.LAYER_NAME_MAP` 一处，本函数不另立约定。
 */
export function layerNumberFromName(name: string): number {
  const key: string = name.trim().toLowerCase();
  if (key.length === 0) {
    return -1;
  }
  const keys: number[] = Array.from(LAYER_NAME_MAP.keys());
  for (let i = 0; i < keys.length; i++) {
    const layerNumber: number = keys[i];
    const entry: LayerNameEntry | undefined = LAYER_NAME_MAP.get(layerNumber);
    if (entry === undefined) {
      continue;
    }
    if (entry.english.toLowerCase() === key || entry.chinese === name.trim()) {
      return layerNumber;
    }
  }
  return -1;
}

// ==================== 内置预设（行为默认不变） ====================

/** 内置预设规则集（深拷贝，调用方改值不会污染 RULESET_28NM） */
export function builtinRules(): DrcRule[] {
  const out: DrcRule[] = [];
  for (let i = 0; i < RULESET_28NM.rules.length; i++) {
    const r: DrcRule = RULESET_28NM.rules[i];
    out.push({
      id: r.id,
      name: r.name,
      type: r.type,
      layerNumber: r.layerNumber,
      targetLayerNumber: r.targetLayerNumber,
      value: r.value,
      severity: r.severity,
      description: r.description,
      enabled: r.enabled,
    });
  }
  return out;
}

/**
 * 把一组规则序列化成**本文件解析器可读**的 CSV 文本（含表头与说明注释）。
 * 用途：面板「导出现有规则为文本」→ 用户改文本 → 再装载，避免只能手抄。
 */
export function ruleSetToText(rules: DrcRule[], setName: string): string {
  let out: string = '# 鸿图 DRC 规则清单（CSV 风格）\n';
  out = out + '# 列序：' + DRC_RULE_CSV_HEADER + '\n';
  out = out + '# type 取值：width / spacing / area / enclosure / density\n';
  out = out + '# layer 可写层号(1)、层名(M1/金属1/Poly/AA…) 或 层号/datatype(1/5)；datatype 留空 = 任意，显式 0 精确匹配\n';
  out = out + '# 以 # 开头的行与空行忽略\n';
  out = out + '# 规则集：' + setName + '\n';
  out = out + DRC_RULE_CSV_HEADER + '\n';
  for (let i = 0; i < rules.length; i++) {
    const r: DrcRule = rules[i];
    const row: string[] = [];
    row.push(r.id);
    row.push(checkTypeToText(r.type));
    row.push(datatypeToText(r.layerNumber, r.datatype));
    row.push('');
    row.push(r.value.toString());
    row.push(r.targetLayerNumber >= 0
      ? datatypeToText(r.targetLayerNumber, r.targetDatatype) : '');
    row.push(csvCell(r.name));
    row.push(severityToText(r.severity));
    row.push(csvCell(r.description));
    row.push(r.enabled ? 'true' : 'false');
    out = out + row.join(',') + '\n';
  }
  return out;
}

/** 层号 + 可选 datatype → 清单单元格文本（`1` 或 `1/5`） */
function datatypeToText(layerNumber: number, datatype: number | undefined): string {
  const dt: number = datatype === undefined ? -1 : datatype;
  return dt >= 0 ? layerNumber.toString() + '/' + dt.toString() : layerNumber.toString();
}

/** 含分隔符/换行的文本加引号（最小可用 CSV 转义） */
function csvCell(raw: string): string {
  if (raw.indexOf(',') < 0 && raw.indexOf('"') < 0 && raw.indexOf('\n') < 0) {
    return raw;
  }
  return '"' + raw.replace(/"/g, '""') + '"';
}

function checkTypeToText(type: DrcRuleType): string {
  if (type === DrcRuleType.MIN_WIDTH) {
    return 'width';
  }
  if (type === DrcRuleType.MIN_SPACING) {
    return 'spacing';
  }
  if (type === DrcRuleType.MIN_AREA) {
    return 'area';
  }
  if (type === DrcRuleType.MIN_ENCLOSURE) {
    return 'enclosure';
  }
  return 'density';
}

function severityToText(sev: DrcSeverity): string {
  if (sev === DrcSeverity.ERROR) {
    return 'error';
  }
  if (sev === DrcSeverity.WARNING) {
    return 'warning';
  }
  return 'info';
}

// ==================== 规则清单文本解析 ====================

/** 解析结果：ok=false 时 rules 为空数组、error 为可直接显示的中文文案 */
export interface DrcRuleTextResult {
  ok: boolean;
  /** 识别出的格式：'json' / 'csv'（失败时为已尝试的格式，未识别则空串） */
  format: string;
  /** 规则集显示名（清单给出则用之，否则 '自定义清单'） */
  setName: string;
  rules: DrcRule[];
  /** 失败原因（含行号/字段名）；ok=true 时为空串 */
  error: string;
  /** 非致命提示（未识别列、缺省包围层等），逐条中文 */
  warnings: string[];
}

/** 图层规格解析结果 */
export interface DrcLayerSpec {
  ok: boolean;
  layerNumber: number;
  /** -1 = 清单未声明（视为任意）；>=0 = 精确匹配（包含用途 0） */
  datatype: number;
  error: string;
}

function okResult(rules: DrcRule[], format: string, setName: string, warnings: string[]): DrcRuleTextResult {
  const out: DrcRuleTextResult = {
    ok: true, format: format, setName: setName, rules: rules, error: '', warnings: warnings,
  };
  return out;
}

function failResult(format: string, error: string, warnings: string[]): DrcRuleTextResult {
  const out: DrcRuleTextResult = {
    ok: false, format: format, setName: '', rules: [], error: error, warnings: warnings,
  };
  return out;
}

/** 错误汇总：最多显示 3 条，其余折叠成计数，避免面板被刷屏 */
function joinErrors(errors: string[]): string {
  if (errors.length === 0) {
    return '';
  }
  const head: string[] = [];
  const shown: number = errors.length > 3 ? 3 : errors.length;
  for (let i = 0; i < shown; i++) {
    head.push(errors[i]);
  }
  let text: string = head.join('；');
  if (errors.length > shown) {
    text = text + '；另有 ' + (errors.length - shown).toString() + ' 条错误';
  }
  return text;
}

/** 剥 BOM + 归一行尾（CRLF / 裸 CR 都按换行处理） */
function normalizeText(text: string): string {
  let src: string = text;
  if (src.length > 0 && src.charCodeAt(0) === 0xFEFF) {
    src = src.substring(1);
  }
  src = src.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  return src;
}

function isCommentLine(line: string): boolean {
  const t: string = line.trim();
  return t.length === 0 || t.startsWith('#') || t.startsWith('//');
}

const LAYER_HINT: string = '图层写法：层号(1)、层名(M1/金属1/Poly/AA/NWell/Via1…) 或 层号/datatype(1/5)';

/** 图层规格解析失败结果（module 级工厂，避免 ArkTS 里对局部闭包函数推断不确定） */
function layerSpecError(msg: string): DrcLayerSpec {
  const out: DrcLayerSpec = { ok: false, layerNumber: -1, datatype: -1, error: msg };
  return out;
}

/** 解析一个图层规格（层号 / 层名 / 层号+datatype） */
export function parseLayerSpec(raw: string): DrcLayerSpec {
  const cell: string = raw.trim();
  if (cell.length === 0) {
    return layerSpecError('图层不能为空（' + LAYER_HINT + '）');
  }
  const parts: string[] = cell.indexOf('/') >= 0 ? cell.split('/')
    : (cell.indexOf(':') >= 0 ? cell.split(':') : [cell]);
  if (parts.length > 2) {
    return layerSpecError('图层 "' + cell + '" 格式不对（' + LAYER_HINT + '）');
  }
  const base: string = parts[0].trim();
  let layerNumber: number = -1;
  if (base.length > 1 && (base.charAt(0) === 'L' || base.charAt(0) === 'l') && isAllDigits(base.substring(1))) {
    layerNumber = parseInt(base.substring(1), 10);
  } else if (isAllDigits(base)) {
    layerNumber = parseInt(base, 10);
  } else {
    layerNumber = layerNumberFromName(base);
    if (layerNumber < 0) {
      return layerSpecError('未知图层 "' + base + '"（' + LAYER_HINT + '）');
    }
  }
  if (layerNumber < 0 || layerNumber > 32767) {
    return layerSpecError('层号 ' + layerNumber.toString() + ' 超出当前文档支持范围 0-32767');
  }
  let datatype: number = -1;
  if (parts.length === 2) {
    const dtText: string = parts[1].trim();
    if (!isAllDigits(dtText)) {
      return layerSpecError('datatype "' + dtText + '" 不是非负整数');
    }
    datatype = parseInt(dtText, 10);
    if (datatype > 32767) {
      return layerSpecError('datatype ' + datatype.toString() + ' 超出当前文档支持范围 0-32767');
    }
  }
  const out: DrcLayerSpec = { ok: true, layerNumber: layerNumber, datatype: datatype, error: '' };
  return out;
}

function isAllDigits(s: string): boolean {
  if (s.length === 0) {
    return false;
  }
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c < 48 || c > 57) {
      return false;
    }
  }
  return true;
}

/** 检查类型别名 → 枚举；未识别返回 null（不猜、不静默降级为宽度检查） */
export function parseCheckType(raw: string): DrcRuleType | null {
  const t: string = raw.trim().toLowerCase();
  if (t === 'width' || t === 'min_width' || t === 'minwidth' || t === 'w' || raw.indexOf('宽度') >= 0) {
    return DrcRuleType.MIN_WIDTH;
  }
  if (t === 'spacing' || t === 'min_spacing' || t === 'minspacing' || t === 's' || raw.indexOf('间距') >= 0) {
    return DrcRuleType.MIN_SPACING;
  }
  if (t === 'area' || t === 'min_area' || t === 'minarea' || t === 'a' || raw.indexOf('面积') >= 0) {
    return DrcRuleType.MIN_AREA;
  }
  if (t === 'enclosure' || t === 'enc' || t === 'min_enclosure' || t === 'minenclosure' ||
    raw.indexOf('包围') >= 0 || raw.indexOf('外延') >= 0) {
    return DrcRuleType.MIN_ENCLOSURE;
  }
  if (t === 'density' || t === 'min_density' || t === 'd' || raw.indexOf('密度') >= 0) {
    return DrcRuleType.DENSITY;
  }
  return null;
}

/** 阈值解析：接受 `90` / `90 nm` / `8100nm²` / `20%` / `1e3`；非法（含 `90abc`）返回 NaN */
const NUMERIC_RE: RegExp = /^[+-]?(\d+(\.\d+)?|\.\d+)([eE][+-]?\d+)?$/;
const UNIT_RE: RegExp = /(nm²|nm2|nm|%)$/i;

function parseThreshold(raw: string): number {
  let s: string = raw.trim().replace(/\s+/g, '');
  s = s.replace(UNIT_RE, '');
  if (s.length === 0 || !NUMERIC_RE.test(s)) {
    return NaN;
  }
  const v: number = parseFloat(s);
  return Number.isFinite(v) ? v : NaN;
}

interface SeverityOut {
  sev: DrcSeverity;
  recognized: boolean;
}

function parseSeverity(raw: string): SeverityOut {
  const t: string = raw.trim().toLowerCase();
  if (t === 'error' || t === 'err' || t === 'e' || raw.indexOf('错误') >= 0 || raw.indexOf('严重') >= 0) {
    return { sev: DrcSeverity.ERROR, recognized: true };
  }
  if (t === 'warning' || t === 'warn' || t === 'w' || raw.indexOf('警告') >= 0) {
    return { sev: DrcSeverity.WARNING, recognized: true };
  }
  if (t === 'info' || raw.indexOf('提示') >= 0) {
    return { sev: DrcSeverity.INFO, recognized: true };
  }
  return { sev: DrcSeverity.ERROR, recognized: false };
}

interface BoolOut {
  value: boolean;
  recognized: boolean;
}

function parseEnabledFlag(raw: string): BoolOut {
  const t: string = raw.trim().toLowerCase();
  if (t === 'true' || t === '1' || t === 'yes' || t === 'y' || t === 'on' || raw.indexOf('是') >= 0) {
    return { value: true, recognized: true };
  }
  if (t === 'false' || t === '0' || t === 'no' || t === 'n' || t === 'off' || raw.indexOf('否') >= 0) {
    return { value: false, recognized: true };
  }
  return { value: true, recognized: false };
}

/** 解析过程中的单行/单对象字段袋（统一 CSV 与 JSON 两条来源） */
interface RawRuleFields {
  /** 定位用文本，如 '第 3 行' / 'rules[2]' */
  label: string;
  id: string;
  name: string;
  type: string;
  layer: string;
  datatype: string;
  target: string;
  targetDatatype: string;
  value: string;
  severity: string;
  description: string;
  enabled: string;
}

function emptyFields(label: string): RawRuleFields {
  return {
    label: label, id: '', name: '', type: '', layer: '', datatype: '',
    target: '', targetDatatype: '', value: '', severity: '', description: '', enabled: '',
  };
}

/**
 * 字段袋 → DrcRule。错误 push 进 errors（带 label 定位），非致命提示 push 进 warnings。
 * 出错时不产出规则——调用方以 errors.length 判定整体失败。
 */
function ruleFromFields(
  f: RawRuleFields,
  rules: DrcRule[],
  seenIds: Map<string, boolean>,
  errors: string[],
  warnings: string[]
): void {
  if (f.id.length === 0) {
    errors.push(f.label + '：缺少规则 ID（ruleId / id）');
    return;
  }
  if (seenIds.has(f.id)) {
    errors.push(f.label + '：规则 ID "' + f.id + '" 重复（同一清单内 ID 必须唯一）');
    return;
  }
  const type: DrcRuleType | null = parseCheckType(f.type);
  if (type === null) {
    errors.push(f.label + '：检查类型 "' + f.type + '" 不支持，可用 width / spacing / area / enclosure / density');
    return;
  }
  const layerSpec: DrcLayerSpec = parseLayerSpec(f.layer);
  if (!layerSpec.ok) {
    errors.push(f.label + '：' + layerSpec.error);
    return;
  }
  let datatype: number = layerSpec.datatype;
  if (f.datatype.trim().length > 0) {
    const dtText: string = f.datatype.trim();
    if (!isAllDigits(dtText)) {
      errors.push(f.label + '：datatype "' + dtText + '" 不是非负整数');
      return;
    }
    datatype = parseInt(dtText, 10);
    if (datatype > 32767) {
      errors.push(f.label + '：datatype ' + datatype.toString() + ' 超出当前文档支持范围 0-32767');
      return;
    }
  }
  const value: number = parseThreshold(f.value);
  if (isNaN(value)) {
    errors.push(f.label + '：最小值 "' + f.value + '" 不是数字');
    return;
  }
  if (value <= 0) {
    errors.push(f.label + '：最小值必须 > 0（当前 ' + value.toString() + '），阈值为 0 的规则永远不会命中');
    return;
  }
  let targetLayer: number = -1;
  let targetDatatype: number = -1;
  if (f.target.trim().length > 0) {
    const tSpec: DrcLayerSpec = parseLayerSpec(f.target);
    if (!tSpec.ok) {
      errors.push(f.label + '：包围层无效 —— ' + tSpec.error);
      return;
    }
    targetLayer = tSpec.layerNumber;
    targetDatatype = tSpec.datatype;
  }
  if (f.targetDatatype.trim().length > 0) {
    const text: string = f.targetDatatype.trim();
    if (!isAllDigits(text) || parseInt(text, 10) > 32767) {
      errors.push(f.label + '：targetDatatype 应为 0-32767 整数');
      return;
    }
    if (targetLayer < 0) {
      errors.push(f.label + '：targetDatatype 需要有效的包围层');
      return;
    }
    const explicit: number = parseInt(text, 10);
    if (targetDatatype >= 0 && targetDatatype !== explicit) {
      errors.push(f.label + '：包围层内的 datatype 与 targetDatatype 冲突');
      return;
    }
    targetDatatype = explicit;
  }
  const ruleName: string = f.name.trim().length > 0 ? f.name.trim() : (f.id + ' 规则');
  if (f.name.trim().length === 0) {
    warnings.push(f.label + '：未给显示名，按 "' + ruleName + '" 显示');
  }
  if (type === DrcRuleType.MIN_ENCLOSURE && targetLayer < 0) {
    warnings.push(f.label + '（' + f.id + '）：包围规则未指定包围层——native 主路径会跳过它，'
      + '只由 ArkTS 回退路径按「所有其他图层」近似检查');
  }
  if (type !== DrcRuleType.MIN_ENCLOSURE && targetLayer >= 0) {
    warnings.push(f.label + '（' + f.id + '）：非包围规则给出了包围层，已忽略');
    targetLayer = -1;
    targetDatatype = -1;
  }
  const built: DrcRule = {
    id: f.id,
    name: ruleName,
    type: type,
    layerNumber: layerSpec.layerNumber,
    targetLayerNumber: targetLayer,
    value: value,
    severity: DrcSeverity.ERROR,
    description: f.description,
    enabled: true,
  };
  if (datatype >= 0) {
    // Omitted means wildcard; explicit zero is a real layer purpose.
    built.datatype = datatype;
  }
  if (targetDatatype >= 0) {
    built.targetDatatype = targetDatatype;
  }
  if (f.severity.trim().length > 0) {
    const sevOut: SeverityOut = parseSeverity(f.severity);
    built.severity = sevOut.sev;
    if (!sevOut.recognized) {
      warnings.push(f.label + '：严重等级 "' + f.severity + '" 未识别，按 error 处理');
    }
  }
  if (f.enabled.trim().length > 0) {
    const enOut: BoolOut = parseEnabledFlag(f.enabled);
    built.enabled = enOut.value;
    if (!enOut.recognized) {
      warnings.push(f.label + '：enabled "' + f.enabled + '" 未识别，按启用处理');
    }
  }
  rules.push(built);
  seenIds.set(f.id, true);
}

/**
 * 解析用户规则清单文本（粘贴或读自规则文件）。
 *
 * 支持：
 * - JSON：`{"name":"我的规则","rules":[{...}]}` 或顶层直接是规则数组
 * - CSV / TSV / 分号分隔：首行可为表头（列名有别名，见 ALIAS_*），也支持无表头按默认列序
 *   `ruleId,type,layer,datatype,min,target,name,severity,description,enabled`
 *
 * 失败一律返回中文 error（含行号 / rules[i] 定位），**不会**部分成功地产出半套规则。
 */
export function parseRuleSetText(text: string, allowAllDisabledState: boolean = false): DrcRuleTextResult {
  const src: string = normalizeText(text).trim();
  if (src.length === 0) {
    return failResult('', '规则清单为空：粘贴 JSON（{"rules":[…]}）或 CSV（' + DRC_RULE_CSV_HEADER + '）', []);
  }
  // 格式识别看**第一条非注释行**：允许用户在 JSON 前写 # 说明行
  const lines: string[] = src.split('\n');
  let head: string = '';
  for (let i = 0; i < lines.length; i++) {
    if (isCommentLine(lines[i])) {
      continue;
    }
    head = lines[i].trim().charAt(0);
    break;
  }
  if (head.length === 0) {
    return failResult(DRC_TEXT_FORMAT_CSV, '规则清单里只有注释行，没有一条规则', []);
  }
  // Saved JSON decks represent an existing configuration, including the
  // intentional all-disabled state. User text imports keep the default guard.
  return head === '{' || head === '[' ? parseJsonRuleSet(src, allowAllDisabledState) : parseCsvRuleSet(src);
}

/** Complete runtime snapshots already contain canonical typed rules. Validate
 * these without the user-text aliases, numeric conversion or enum defaults. */
export function copyCanonicalDrcRules(rules: DrcRule[]): DrcRule[] {
  if (!Array.isArray(rules) || rules.length > 4096) throw new Error('完整 DRC 状态须含最多 4096 项规则数组');
  const ids: Set<string> = new Set<string>();
  const out: DrcRule[] = [];
  for (let index: number = 0; index < rules.length; index++) {
    const rule: DrcRule = rules[index];
    const label: string = `完整 DRC 状态 rules[${index}]`;
    if (rule === null || typeof rule !== 'object' || Array.isArray(rule) ||
      typeof rule.id !== 'string' || rule.id.trim().length === 0 || rule.id.length > 4096 || rule.id.includes('\0') ||
      typeof rule.name !== 'string' || rule.name.length > 16384 || rule.name.includes('\0') ||
      typeof rule.description !== 'string' || rule.description.length > 65536 || rule.description.includes('\0') ||
      typeof rule.enabled !== 'boolean') throw new Error(`${label} 文本或启用状态类型无效`);
    if (ids.has(rule.id)) throw new Error(`${label} 规则 ID 重复`);
    if (rule.type !== DrcRuleType.MIN_WIDTH && rule.type !== DrcRuleType.MIN_SPACING &&
      rule.type !== DrcRuleType.MIN_AREA && rule.type !== DrcRuleType.MIN_ENCLOSURE && rule.type !== DrcRuleType.DENSITY)
      throw new Error(`${label} 检查类型无效`);
    if (rule.severity !== DrcSeverity.ERROR && rule.severity !== DrcSeverity.WARNING && rule.severity !== DrcSeverity.INFO)
      throw new Error(`${label} 严重等级无效`);
    if (typeof rule.layerNumber !== 'number' || !Number.isInteger(rule.layerNumber) || rule.layerNumber < 0 || rule.layerNumber > 32767 ||
      typeof rule.targetLayerNumber !== 'number' || !Number.isInteger(rule.targetLayerNumber) || rule.targetLayerNumber < -1 || rule.targetLayerNumber > 32767 ||
      typeof rule.value !== 'number' || !Number.isFinite(rule.value) || rule.value <= 0)
      throw new Error(`${label} 图层或阈值类型与范围无效`);
    for (const datatype of [rule.datatype, rule.targetDatatype]) {
      if (datatype !== undefined && (typeof datatype !== 'number' || !Number.isInteger(datatype) || datatype < 0 || datatype > 32767))
        throw new Error(`${label} datatype 类型与范围无效`);
    }
    if (rule.targetDatatype !== undefined && rule.targetLayerNumber < 0) throw new Error(`${label} targetDatatype 缺少目标图层`);
    ids.add(rule.id); out.push(copyRule(rule));
  }
  return out;
}

const ALIAS_ID: string[] = ['ruleid', 'id', '规则id', '规则编号', '编号'];
const ALIAS_NAME: string[] = ['name', 'rulename', '显示名', '规则名', '名称'];
const ALIAS_TYPE: string[] = ['type', 'check', 'kind', '检查类型', '检查', '类型'];
const ALIAS_LAYER: string[] = ['layer', 'layernumber', '图层', '层', 'gds', 'gdslayer'];
const ALIAS_DATATYPE: string[] = ['datatype', 'dt', '数据类型', '层类型'];
const ALIAS_VALUE: string[] = ['min', 'minimum', 'value', 'nm', '阈值', '最小值', '要求值'];
const ALIAS_TARGET: string[] = ['target', 'targetlayer', 'enclosurelayer', 'targetlayernumber', '包围层', '目标层'];
const ALIAS_SEVERITY: string[] = ['severity', 'level', '等级', '严重度'];
const ALIAS_DESC: string[] = ['description', 'desc', '说明', '描述'];
const ALIAS_ENABLED: string[] = ['enabled', 'enable', '启用', '开关'];

function aliasIndex(cells: string[], aliases: string[]): number {
  for (let i = 0; i < cells.length; i++) {
    const c: string = cells[i].trim().toLowerCase().replace(/"/g, '');
    if (aliases.indexOf(c) >= 0) {
      return i;
    }
  }
  return -1;
}

/**
 * JSON 字段读取：别名匹配**大小写不敏感**（`ruleId` / `RuleID` / `ruleid` 同一含义），
 * 值只认 string / number / boolean，其他类型一律按缺省（不猜）。
 */
function jsonField(obj: Record<string, Object>, keys: string[]): string {
  const objKeys: string[] = Object.keys(obj);
  for (let i = 0; i < keys.length; i++) {
    for (let k = 0; k < objKeys.length; k++) {
      if (objKeys[k].toLowerCase() !== keys[i]) {
        continue;
      }
      const v: Object | undefined = obj[objKeys[k]];
      if (v === undefined || v === null) {
        continue;
      }
      if (typeof v === 'string') {
        return v as string;
      }
      if (typeof v === 'number') {
        return String(v);
      }
      if (typeof v === 'boolean') {
        return (v as boolean) ? 'true' : 'false';
      }
      return '';
    }
  }
  return '';
}

/** A supplied layer purpose must not silently turn into an omitted wildcard. */
function jsonDatatypeField(obj: Record<string, Object>, keys: string[], label: string, errors: string[]): string {
  for (const alias of keys) {
    for (const key of Object.keys(obj)) {
      if (key.toLowerCase() !== alias) continue;
      const value: Object | undefined = obj[key];
      if (typeof value !== 'number' && typeof value !== 'string') {
        errors.push(label + '：' + key + ' 必须是整数或整数字符串，不能省略为任意用途');
        return '';
      }
      return String(value).trim();
    }
  }
  return '';
}

/** 剥掉 JSON 前后的 `#` / `//` 说明行，只留 JSON 本体（首个 { 或 [ 到末个对应闭括号） */
function extractJsonBody(src: string): string {
  const objStart: number = src.indexOf('{');
  const arrStart: number = src.indexOf('[');
  let start: number = -1;
  let close: string = '}';
  if (objStart >= 0 && (arrStart < 0 || objStart < arrStart)) {
    start = objStart;
  } else if (arrStart >= 0) {
    start = arrStart;
    close = ']';
  }
  if (start < 0) {
    return src;
  }
  const end: number = src.lastIndexOf(close);
  return end < start ? src : src.substring(start, end + 1);
}

function parseJsonRuleSet(src: string, allowAllDisabledState: boolean = false): DrcRuleTextResult {
  const warnings: string[] = [];
  const errors: string[] = [];
  const rules: DrcRule[] = [];
  const seenIds: Map<string, boolean> = new Map<string, boolean>();
  let setName: string = '';
  let rawRules: Object | undefined;
  let parsed: Object;
  try {
    parsed = JSON.parse(extractJsonBody(src));
  } catch (e) {
    return failResult(DRC_TEXT_FORMAT_JSON, 'JSON 规则清单解析失败：' + (e instanceof Error ? e.message : String(e)), warnings);
  }
  if (parsed === null || typeof parsed !== 'object') {
    return failResult(DRC_TEXT_FORMAT_JSON, 'JSON 规则清单需要对象或规则数组', warnings);
  }
  if (Array.isArray(parsed)) {
    rawRules = parsed as Object;
  } else {
    const obj: Record<string, Object> = parsed as Record<string, Object>;
    const nameVal: string = jsonField(obj, ['name', 'ruleset', '规则集']);
    setName = nameVal.trim();
    rawRules = obj['rules'] !== undefined && obj['rules'] !== null ? obj['rules'] : obj['规则'];
  }
  if (rawRules === undefined || rawRules === null) {
    return failResult(DRC_TEXT_FORMAT_JSON, 'JSON 规则清单缺少 rules 字段（期望 {"rules":[…]}）', warnings);
  }
  if (!Array.isArray(rawRules)) {
    return failResult(DRC_TEXT_FORMAT_JSON, 'JSON 规则清单的 rules 不是数组', warnings);
  }
  const list: Object[] = rawRules as Object[];
  for (let i = 0; i < list.length; i++) {
    const item = list[i];
    if (typeof item !== 'object' || item === null) {
      errors.push('rules[' + i.toString() + '] 不是对象');
      continue;
    }
    const rec: Record<string, Object> = item as Record<string, Object>;
    const f: RawRuleFields = emptyFields('rules[' + i.toString() + ']');
    f.id = jsonField(rec, ALIAS_ID).trim();
    f.name = jsonField(rec, ALIAS_NAME);
    f.type = jsonField(rec, ALIAS_TYPE).trim();
    f.layer = jsonField(rec, ALIAS_LAYER).trim();
    f.datatype = jsonDatatypeField(rec, ALIAS_DATATYPE, f.label, errors);
    f.target = jsonField(rec, ALIAS_TARGET).trim();
    // Canonical DrcRule JSON is persisted inside technology/project documents.
    // Its -1 sentinel means no target; explicit zero remains a real target layer.
    if (f.target === '-1' && jsonField(rec, ['targetlayernumber']).trim() === '-1') f.target = '';
    f.targetDatatype = jsonDatatypeField(rec, ['targetdatatype', 'targetdt'], f.label, errors);
    f.value = jsonField(rec, ALIAS_VALUE).trim();
    f.severity = jsonField(rec, ALIAS_SEVERITY).trim();
    f.description = jsonField(rec, ALIAS_DESC);
    f.enabled = jsonField(rec, ALIAS_ENABLED).trim();
    ruleFromFields(f, rules, seenIds, errors, warnings);
  }
  if (errors.length > 0) {
    return failResult(DRC_TEXT_FORMAT_JSON, joinErrors(errors), warnings);
  }
  return finishRuleSet(rules, DRC_TEXT_FORMAT_JSON, setName, warnings, allowAllDisabledState);
}

/** 取第 idx 列（越界或 idx<0 一律空串，表示该列缺省） */
function cellAt(cells: string[], idx: number): string {
  return idx >= 0 && idx < cells.length ? cells[idx].trim() : '';
}

/** 分隔符猜测：制表符 > 分号 > 逗号（按出现次数多者，相等时优先制表/分号前的直觉顺序） */
function detectDelimiter(line: string): string {
  const tabs: number = countChar(line, '\t');
  const semis: number = countChar(line, ';');
  const commas: number = countChar(line, ',');
  if (tabs >= semis && tabs >= commas && tabs > 0) {
    return '\t';
  }
  if (semis > commas && semis > 0) {
    return ';';
  }
  return ',';
}

function countChar(s: string, ch: string): number {
  let n: number = 0;
  for (let i = 0; i < s.length; i++) {
    if (s.charAt(i) === ch) {
      n++;
    }
  }
  return n;
}

/** 拆一行（支持 "..." 包裹与 "" 转义） */
function splitDelimited(line: string, delim: string): string[] {
  const cells: string[] = [];
  let cur: string = '';
  let inQuotes: boolean = false;
  for (let i = 0; i < line.length; i++) {
    const ch: string = line.charAt(i);
    if (ch === '"') {
      if (inQuotes && i + 1 < line.length && line.charAt(i + 1) === '"') {
        cur = cur + '"';
        i++;
      } else {
        inQuotes = !inQuotes;
      }
      continue;
    }
    if (ch === delim && !inQuotes) {
      cells.push(cur);
      cur = '';
      continue;
    }
    cur = cur + ch;
  }
  cells.push(cur);
  return cells;
}

function parseCsvRuleSet(src: string): DrcRuleTextResult {
  const warnings: string[] = [];
  const errors: string[] = [];
  const rules: DrcRule[] = [];
  const seenIds: Map<string, boolean> = new Map<string, boolean>();
  const lines: string[] = src.split('\n');
  // 列下标：-1 = 该列不存在；先按表头映射，无表头则按默认列序
  const col: number[] = [-1, -1, -1, -1, -1, -1, -1, -1, -1, -1];
  let delim: string = ',';
  let headerSeen: boolean = false;
  let setName: string = '';
  for (let i = 0; i < lines.length; i++) {
    const lineNo: number = i + 1;
    const raw: string = lines[i];
    if (isCommentLine(raw)) {
      const asName: string = raw.trim();
      if (asName.startsWith('# 规则集：')) {
        setName = asName.substring('# 规则集：'.length).trim();
      }
      continue;
    }
    if (!headerSeen) {
      delim = detectDelimiter(raw);
      const probe: string[] = splitDelimited(raw, delim);
      const looksHeader: boolean = aliasIndex(probe, ALIAS_ID) >= 0 &&
        (aliasIndex(probe, ALIAS_TYPE) >= 0 || aliasIndex(probe, ALIAS_VALUE) >= 0);
      if (looksHeader) {
        col[0] = aliasIndex(probe, ALIAS_ID);
        col[1] = aliasIndex(probe, ALIAS_TYPE);
        col[2] = aliasIndex(probe, ALIAS_LAYER);
        col[3] = aliasIndex(probe, ALIAS_DATATYPE);
        col[4] = aliasIndex(probe, ALIAS_VALUE);
        col[5] = aliasIndex(probe, ALIAS_TARGET);
        col[6] = aliasIndex(probe, ALIAS_NAME);
        col[7] = aliasIndex(probe, ALIAS_SEVERITY);
        col[8] = aliasIndex(probe, ALIAS_DESC);
        col[9] = aliasIndex(probe, ALIAS_ENABLED);
        const skipped: string[] = [];
        for (let c = 0; c < probe.length; c++) {
          if (col.indexOf(c) < 0) {
            skipped.push(probe[c].trim());
          }
        }
        if (skipped.length > 0) {
          warnings.push('第 1 行：未识别的列已忽略（' + skipped.join('、') + '）');
        }
        headerSeen = true;
        continue;
      }
      // 无表头：按 DRC_RULE_CSV_HEADER 的列序位置取值
      for (let c = 0; c < col.length; c++) {
        col[c] = c;
      }
      headerSeen = true;
    }
    const cells: string[] = splitDelimited(raw, delim);
    if (cells.length < 4) {
      errors.push('第 ' + lineNo.toString() + ' 行：只有 ' + cells.length.toString()
        + ' 列，至少需要 ruleId / type / layer / min 四列');
      continue;
    }
    const f: RawRuleFields = emptyFields('第 ' + lineNo.toString() + ' 行');
    f.id = cellAt(cells, col[0]);
    f.type = cellAt(cells, col[1]);
    f.layer = cellAt(cells, col[2]);
    f.datatype = cellAt(cells, col[3]);
    // 无表头时 datatype 与 min 位置固定；有表头时 datatype 列可能缺省 → min 落到下一列
    if (col[4] >= 0) {
      f.value = cellAt(cells, col[4]);
    }
    f.target = cellAt(cells, col[5]);
    f.name = cellAt(cells, col[6]);
    f.severity = cellAt(cells, col[7]);
    f.description = cellAt(cells, col[8]);
    f.enabled = cellAt(cells, col[9]);
    if (f.value.length === 0) {
      // 兼容 `ruleId,type,layer,min` 这类把 min 直接放在第 4 列的简写
      const alt: string = cellAt(cells, 3);
      if (alt.length > 0 && !isNaN(parseThreshold(alt))) {
        f.value = alt;
        f.datatype = '';
      }
    }
    ruleFromFields(f, rules, seenIds, errors, warnings);
  }
  if (errors.length > 0) {
    return failResult(DRC_TEXT_FORMAT_CSV, joinErrors(errors), warnings);
  }
  return finishRuleSet(rules, DRC_TEXT_FORMAT_CSV, setName, warnings);
}

function finishRuleSet(rules: DrcRule[], format: string, setName: string, warnings: string[], allowAllDisabledState: boolean = false): DrcRuleTextResult {
  if (rules.length === 0) {
    return failResult(format, '规则清单里未解析出任何规则（每条至少要有 ruleId / type / layer / min）', warnings);
  }
  let enabledCount: number = 0;
  for (let i = 0; i < rules.length; i++) {
    if (rules[i].enabled) {
      enabledCount++;
    }
  }
  if (enabledCount === 0 && !allowAllDisabledState) {
    return failResult(format, '规则清单里所有规则都被 enabled=false 关闭了，等于什么都不检查', warnings);
  }
  const name: string = setName.length > 0 ? setName : '自定义清单';
  return okResult(rules, format, name, warnings);
}

// ==================== 规则表合并（addRuleFile / 文本装载 / 重建共用） ====================

/**
 * 按规则 ID 合并：同 ID 覆盖参数，新 ID 追加。返回**新数组**（不改入参，便于 UI 换引用触发刷新）。
 * 这是 DrcService 里原先三处复制粘贴合并逻辑的单一实现。
 */
export function mergeRulesById(base: DrcRule[], incoming: DrcRule[]): DrcRule[] {
  const out: DrcRule[] = [];
  const indexById: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < base.length; i++) {
    const r: DrcRule = base[i];
    indexById.set(r.id, out.length);
    out.push(copyRule(r));
  }
  for (let j = 0; j < incoming.length; j++) {
    const src: DrcRule = incoming[j];
    const at: number | undefined = indexById.get(src.id);
    if (at !== undefined && at >= 0) {
      out[at] = copyRule(src);
    } else {
      indexById.set(src.id, out.length);
      out.push(copyRule(src));
    }
  }
  return out;
}

/** 逐字段拷贝（含可选 datatype），避免不同规则集之间共享同一对象 */
export function copyRule(r: DrcRule): DrcRule {
  const out: DrcRule = {
    id: r.id,
    name: r.name,
    type: r.type,
    layerNumber: r.layerNumber,
    targetLayerNumber: r.targetLayerNumber,
    value: r.value,
    severity: r.severity,
    description: r.description,
    enabled: r.enabled,
  };
  if (r.datatype !== undefined) {
    out.datatype = r.datatype;
  }
  if (r.targetDatatype !== undefined) {
    out.targetDatatype = r.targetDatatype;
  }
  return out;
}

// ==================== 违规按规则分组 ====================

/** 分组输入：违规行里只用到这几个字段（DrcService 负责把 DrcViolation 映射过来） */
export interface DrcViolationRef {
  ruleId: string;
  ruleName: string;
  severity: DrcSeverity;
  x: number;
  y: number;
  message: string;
}

/** 单条规则的命中统计 */
export interface DrcRuleGroup {
  ruleId: string;
  ruleName: string;
  /** 检查类型中文；未在册规则（native 侧独有 ID）为 '未在册' */
  typeText: string;
  /** 图层显示文本（L1 金属1）；未在册规则为 '—' */
  layerText: string;
  /** 阈值文本（含单位）；未在册规则为 '—' */
  limitText: string;
  enabled: boolean;
  /** 命中数：**不含**任何完整性告警行 */
  hits: number;
  errors: number;
  warnings: number;
  infos: number;
  /** 首条命中坐标（定位用；无命中时为 0,0） */
  sampleX: number;
  sampleY: number;
  sampleMessage: string;
}

/** 完整性告警行（不计入任何规则命中，也不参与 passed） */
export interface DrcNoticeRow {
  ruleId: string;
  title: string;
  message: string;
}

/** 分组汇总 */
export interface DrcGroupSummary {
  /** 每条已定义规则（含 0 命中），顺序与规则表一致 */
  groups: DrcRuleGroup[];
  /** 违规里出现但规则表里没有的 ruleId（如 native 侧独有规则），如实单列不丢弃 */
  unknown: DrcRuleGroup[];
  /** DRC.TRUNC / DRC.NOHIER 逐条 */
  notices: DrcNoticeRow[];
  noticeCount: number;
  /** 计入规则命中的违例总数（= 各 groups.hits 之和 + unknown 各组 hits 之和） */
  ruleViolationCount: number;
  /** 有命中的「已定义规则」条数（unknown 不计入，另看 unknown.length） */
  hitRuleCount: number;
  /** 已启用但 0 命中的规则数 */
  zeroHitRuleCount: number;
  errorCount: number;
  warningCount: number;
  infoCount: number;
  /** 只看规则违例的 error 数，完整性告警不参与 */
  passed: boolean;
  /** 面板脚注口径文案（保留「快速几何预检查，非签核」措辞） */
  scopeNote: string;
}

function newGroup(rule: DrcRule): DrcRuleGroup {
  return {
    ruleId: rule.id,
    ruleName: rule.name,
    typeText: typeLabel(rule.type),
    layerText: layerSpecText(rule.layerNumber, rule.datatype === undefined ? -1 : rule.datatype),
    limitText: rule.value.toString() + ' ' + unitLabel(rule.type),
    enabled: rule.enabled,
    hits: 0,
    errors: 0,
    warnings: 0,
    infos: 0,
    sampleX: 0,
    sampleY: 0,
    sampleMessage: '',
  };
}

function newUnknownGroup(ruleId: string, ruleName: string): DrcRuleGroup {
  return {
    ruleId: ruleId,
    ruleName: ruleName.length > 0 ? ruleName : ruleId,
    typeText: '未在册',
    layerText: '—',
    limitText: '—',
    enabled: true,
    hits: 0,
    errors: 0,
    warnings: 0,
    infos: 0,
    sampleX: 0,
    sampleY: 0,
    sampleMessage: '',
  };
}

/**
 * 把违规列表按 ruleId 归组。
 *
 * 口径（与面板/状态栏文案严格一致）：
 * - `DRC.TRUNC` / `DRC.NOHIER` 是结果完整性告警，**不计入任何规则的命中数**，
 *   单独进 `notices`；
 * - `passed` 要求没有 error 且没有完整性告警；告警仍不计入规则命中数；
 * - 规则表里每条规则都会出现（0 命中也列出），违规里出现的未知 ruleId 进 `unknown`，
 *   两条都不许静默丢弃。
 */
export function groupViolationsByRule(rules: DrcRule[], violations: DrcViolationRef[]): DrcGroupSummary {
  const groups: DrcRuleGroup[] = [];
  const unknown: DrcRuleGroup[] = [];
  const notices: DrcNoticeRow[] = [];
  const indexById: Map<string, number> = new Map<string, number>();
  for (let i = 0; i < rules.length; i++) {
    indexById.set(rules[i].id, groups.length);
    groups.push(newGroup(rules[i]));
  }

  let ruleViolationCount: number = 0;
  let errorCount: number = 0;
  let warningCount: number = 0;
  let infoCount: number = 0;
  let noticeCount: number = 0;

  for (let v = 0; v < violations.length; v++) {
    const row: DrcViolationRef = violations[v];
    if (isCompletenessNotice(row.ruleId)) {
      noticeCount++;
      notices.push({ ruleId: row.ruleId, title: noticeTitle(row.ruleId, row.ruleName), message: row.message });
      continue;
    }
    const at: number | undefined = indexById.get(row.ruleId);
    let group: DrcRuleGroup | undefined;
    if (at !== undefined) {
      group = groups[at];
    } else {
      let uAt: number = -1;
      for (let u = 0; u < unknown.length; u++) {
        if (unknown[u].ruleId === row.ruleId) {
          uAt = u;
          break;
        }
      }
      if (uAt < 0) {
        unknown.push(newUnknownGroup(row.ruleId, row.ruleName));
        uAt = unknown.length - 1;
      }
      group = unknown[uAt];
    }
    if (group === undefined) {
      continue;
    }
    group.hits++;
    ruleViolationCount++;
    if (row.severity === DrcSeverity.ERROR) {
      group.errors++;
      errorCount++;
    } else if (row.severity === DrcSeverity.WARNING) {
      group.warnings++;
      warningCount++;
    } else {
      group.infos++;
      infoCount++;
    }
    if (group.hits === 1) {
      group.sampleX = row.x;
      group.sampleY = row.y;
      group.sampleMessage = row.message;
    }
  }

  let hitRuleCount: number = 0;
  let zeroHitRuleCount: number = 0;
  for (let g = 0; g < groups.length; g++) {
    const grp: DrcRuleGroup = groups[g];
    if (grp.hits > 0) {
      hitRuleCount++;
    } else if (grp.enabled) {
      zeroHitRuleCount++;
    }
  }

  const summary: DrcGroupSummary = {
    groups: groups,
    unknown: unknown,
    notices: notices,
    noticeCount: noticeCount,
    ruleViolationCount: ruleViolationCount,
    hitRuleCount: hitRuleCount,
    zeroHitRuleCount: zeroHitRuleCount,
    errorCount: errorCount,
    warningCount: warningCount,
    infoCount: infoCount,
    passed: errorCount === 0 && noticeCount === 0,
    scopeNote: '按规则分组统计 · 快速几何预检查，非签核',
  };
  return summary;
}

function noticeTitle(ruleId: string, ruleName: string): string {
  if (ruleName.length > 0) {
    return ruleName;
  }
  for (let i = 0; i < NOTICE_TITLES.length; i++) {
    const t: string = NOTICE_TITLES[i];
    if (t.startsWith(ruleId + '｜')) {
      return t.substring(ruleId.length + 1);
    }
  }
  return '结果不完整';
}

// ==================== host / 设备双侧自检 ====================

/**
 * 纯逻辑自检（返回 '' = 通过，否则中文失败原因）。
 * 与 `LypService.lypSelfCheck()` 同先例：设备启动时调用一次，失败只 console.warn；
 * 同一份断言也被 `tools/drc_rules_host_check.mjs` 在 host 上执行。
 */
export function drcRuleTextSelfCheck(): string {
  // 1) 内置预设可读且非空
  const preset: DrcRule[] = builtinRules();
  if (preset.length < 4) {
    return '内置预设规则数异常：' + preset.length.toString();
  }
  // 2) 文本往返：内置预设 → ruleSetToText → parseRuleSetText 必须逐字段一致
  const text: string = ruleSetToText(preset, BUILTIN_PRESET_NAME);
  const again: DrcRuleTextResult = parseRuleSetText(text);
  if (!again.ok) {
    return '内置预设文本往返失败：' + again.error;
  }
  if (again.rules.length !== preset.length) {
    return '往返规则数不一致：' + again.rules.length.toString() + ' vs ' + preset.length.toString();
  }
  for (let i = 0; i < preset.length; i++) {
    const a: DrcRule = preset[i];
    const b: DrcRule = again.rules[i];
    if (a.id !== b.id || a.type !== b.type || a.layerNumber !== b.layerNumber ||
      a.targetLayerNumber !== b.targetLayerNumber || a.value !== b.value ||
      a.severity !== b.severity || a.name !== b.name || a.enabled !== b.enabled) {
      return '往返字段不一致：' + a.id;
    }
  }
  // 3) 层名解析走 LAYER_NAME_MAP 单一真源
  if (layerNumberFromName('M1') !== 1 || layerNumberFromName('金属1') !== 1 ||
    layerNumberFromName('poly') !== 4 || layerNumberFromName('不存在的层') !== -1) {
    return '层名→层号解析不符合 LAYER_NAME_MAP';
  }
  const spec: DrcLayerSpec = parseLayerSpec('1/5');
  if (!spec.ok || spec.layerNumber !== 1 || spec.datatype !== 5) {
    return 'layer/datatype 写法解析失败';
  }
  // 4) 负例：坏类型 / 坏阈值 / 重复 ID / 空清单必须报错而不是静默降级
  const badType: DrcRuleTextResult = parseRuleSetText('MW_X,width,1,,90\n');
  if (!badType.ok) {
    return '简写清单意外失败：' + badType.error;
  }
  const badCheck: DrcRuleTextResult = parseRuleSetText('R1,foo,1,,90\n');
  if (badCheck.ok) {
    return '未知检查类型必须报错（当前被静默接受）';
  }
  const badValue: DrcRuleTextResult = parseRuleSetText('R1,width,1,,abc\n');
  if (badValue.ok) {
    return '非法阈值必须报错';
  }
  const dupId: DrcRuleTextResult = parseRuleSetText('R1,width,1,,90\nR1,spacing,1,,90\n');
  if (dupId.ok) {
    return '重复规则 ID 必须报错';
  }
  if (parseRuleSetText('   ').ok || parseRuleSetText('# 只有注释\n').ok) {
    return '空清单必须报错（不得静默回退到内置预设）';
  }
  // 5) 分组：完整性告警不计入命中，但结果不完整不能通过
  const oneRule: DrcRule[] = [preset[0]];
  const rows: DrcViolationRef[] = [
    { ruleId: preset[0].id, ruleName: preset[0].name, severity: DrcSeverity.ERROR, x: 10, y: 20, message: '宽度违规' },
    { ruleId: DRC_NOTICE_TRUNC, ruleName: '层级展开触顶', severity: DrcSeverity.ERROR, x: 0, y: 0, message: '结果不完整' },
    { ruleId: DRC_NOTICE_NOHIER, ruleName: '层级展开未覆盖', severity: DrcSeverity.WARNING, x: 0, y: 0, message: '部分未展开' },
    { ruleId: 'NATIVE.ONLY', ruleName: 'native 独有规则', severity: DrcSeverity.WARNING, x: 1, y: 2, message: 'x' },
  ];
  const s: DrcGroupSummary = groupViolationsByRule(oneRule, rows);
  if (s.noticeCount !== 2) {
    return '完整性告警计数应为 2，实际 ' + s.noticeCount.toString();
  }
  if (s.groups.length !== 1 || s.groups[0].hits !== 1) {
    return '告警行不得计入任何规则的命中数';
  }
  if (s.ruleViolationCount !== 2) {
    return '规则违例总数应为 2（1 规则命中 + 1 未在册），实际 ' + s.ruleViolationCount.toString();
  }
  if (s.unknown.length !== 1 || s.unknown[0].ruleId !== 'NATIVE.ONLY') {
    return '未在册 ruleId 必须如实单列';
  }
  const clean: DrcGroupSummary = groupViolationsByRule(oneRule, [rows[1], rows[2]]);
  if (clean.ruleViolationCount !== 0 || clean.passed || clean.groups[0].hits !== 0) {
    return '只有告警行时必须 passed=false 且 0 命中';
  }
  if (clean.zeroHitRuleCount !== 1) {
    return '0 命中规则必须被统计出来';
  }
  // 6) 合并语义：同 ID 覆盖、新 ID 追加、不改入参
  const override: DrcRule[] = [{
    id: preset[0].id, name: '改了名', type: DrcRuleType.MIN_WIDTH, layerNumber: 2,
    targetLayerNumber: -1, value: 111, severity: DrcSeverity.WARNING, description: '', enabled: true,
  }];
  const merged: DrcRule[] = mergeRulesById(oneRule, override);
  if (merged.length !== 1 || merged[0].value !== 111 || oneRule[0].value !== preset[0].value) {
    return 'mergeRulesById 语义不符（应覆盖同 ID 且不改入参）';
  }
  return '';
}
