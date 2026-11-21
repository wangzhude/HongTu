/**
 * 鸿图 DRC 设计规则检查引擎
 *
 * 实现基础 DRC 检查规则：
 * - 最小宽度检查 (Min Width)
 * - 最小间距检查 (Min Spacing)
 * - 最小面积检查 (Min Area)
 * - 最小包围检查 (Min Enclosure)
 *
 * 检查结果含违规类型、位置、规则描述、严重等级。
 *
 * 规则可配置（对齐 KLayout「一组带名字/层/参数的规则」）：默认用内置预设（28nm，
 * `common/drcRulesets.RULESET_28NM`，行为与改动前一致），也可由用户规则清单文本
 * （粘贴或选中的 .json / CSV 风格文件）装载，见 loadRulesFromText / loadRulesFromFile；
 * 解析与分组统计的纯逻辑在 `common/drcRuleText.ets`（host 可跑断言：
 * `node --experimental-transform-types tools/drc_rules_host_check.mjs`）。
 * 装载失败**不静默回退**到预设，返回可显示的中文 error。
 *
 * 结果分组：getRuleGroups() 按 ruleId 归组（0 命中也列出），并把两条完整性告警
 * 完整性告警与规则违例分别计数——告警不计入任何规则命中，但会阻止 passed。
 *
 * 层级展开：native 主路径按 hierarchyDepth 把 SREF/AREF 实例内几何变换到被检查
 * Cell 的坐标系后一并检查（默认 1 层，KLayout 风格）。ArkTS 回退路径只有当前 Cell 的
 * 本地 Shape，**不能展开层级**：其结果通过 DrcResult.hierarchyDepthApplied=0 与
 * ruleId='DRC.NOHIER' 告警项如实标注，UI 不得把这类结果宣称为已展开。
 *
 * [注意] 两条路径都是「快速几何预检查」。密度回退按实际区域并集与窗口相交测量；
 *   无法证明区域、精度或预算时给出完整性告警，不返回乐观的通过。
 *   不可作为签核依据；签核需 KLayout 等工具。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, getShapeBounds, getShapeArea, Point } from '../models/GdsiiData';
import { nativeHongTuService } from './NativeHongTuService';
// 层级展开深度需要 3 参调用 native runDrc；NativeHongTuService 的 2 参封装保持不变，
// 故此处按其同一口径直取 native 模块（GlCanvas.ets 已有相同用法），失败回退 2 参封装。
import hongtu from 'libhongtu.so';
import type { HongTuNative, NativeDrcRule, NativeDrcViolation } from '../../cpp/types/libhongtu/Index';
import type { NativeRenderSnapshot, NativeDrcJobOptions, NativeDrcJobResult, NativeDrcJob, NativeJobScopeBox } from '../../cpp/types/libhongtu/Index';
import {
  DrcSeverity,
  DrcRuleType,
  DrcRule,
  DrcRuleset,
  ALL_RULESETS,
  readRuleFileText,
} from '../common/drcRulesets';
import {
  parseRuleSetText,
  ruleSetToText,
  builtinRules,
  copyRule,
  mergeRulesById,
  groupViolationsByRule,
  isCompletenessNotice,
  DRC_NOTICE_NOHIER,
  DRC_NOTICE_MERGE,
  DRC_NOTICE_EXEC,
  BUILTIN_PRESET_NAME,
} from '../common/drcRuleText';
import type { DrcRuleTextResult, DrcGroupSummary, DrcViolationRef } from '../common/drcRuleText';

// 重新导出类型与枚举，保持对外 API 向后兼容
export { DrcSeverity, DrcRuleType, DrcRule, DrcRuleset } from '../common/drcRulesets';
// 规则清单装载 / 分组统计的纯逻辑统一在 drcRuleText.ets（可 host 断言），此处转发给 UI
export {
  parseRuleSetText, ruleSetToText, builtinRules, groupViolationsByRule, isCompletenessNotice,
  mergeRulesById, typeLabel, unitLabel, severityLabel, layerSpecText, parseLayerSpec,
  layerNumberFromName, drcRuleTextSelfCheck,
  DRC_NOTICE_TRUNC, DRC_NOTICE_NOHIER, BUILTIN_PRESET_NAME, DRC_RULE_CSV_HEADER,
  DrcRuleTextResult, DrcGroupSummary, DrcRuleGroup, DrcNoticeRow, DrcViolationRef,
  DrcLayerSpec,
} from '../common/drcRuleText';

/** DRC 违规项 */
export interface DrcViolation {
  id: number;
  ruleId: string;
  ruleName: string;
  type: DrcRuleType;
  severity: DrcSeverity;
  layerNumber: number;
  /** 违规位置 X */
  x: number;
  /** 违规位置 Y */
  y: number;
  /** 违规区域宽度（nm），用于高亮框定位 */
  width: number;
  /** 违规区域高度（nm），用于高亮框定位 */
  height: number;
  /** 违规描述 */
  message: string;
  /** 相关图形 ID（层级展开命中实例几何时，这些 id 属于**子 Cell**，当前 Cell 内查不到） */
  shapeIds: number[];
  /** true → 违规位于 SREF/AREF 展开后的实例几何上；定位请用 x/y，勿按 shapeIds 反查当前 Cell */
  fromInstance?: boolean;
}

/** DRC 检查结果 */
interface DrcBounds {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}
interface DensityRect { minX: number; minY: number; maxX: number; maxY: number; }
interface DensityGeometry { rectangles: DensityRect[]; polygons: number[][]; rectangleOnly: boolean; approximation: string; }
interface DensityWork { examined: number; }

export interface DrcResult {
  totalRules: number;
  executedRules: number;
  totalViolations: number;
  errors: number;
  warnings: number;
  passed: boolean;
  violations: DrcViolation[];
  elapsed: number;
  /**
   * 本次 native 展开**真正生效**的层级深度：
   * 0 = 未展开（depth 传 0 / native 不可用 / 走 ArkTS 回退），≥1 = 实例几何已并入检查。
   * 任何 UI 文案不得在未检查此字段的情况下宣称「已展开层级」。
   */
  hierarchyDepthApplied: number;
  /** 由 ArkTS 回退路径检查的规则数（该路径只吃当前 Cell 本地图形，无法展开层级） */
  arkFallbackRules: number;
  /**
   * 「结果是否完整」告警条数，不算进 errors / warnings 或规则命中数；
   * >0 会阻止 passed，因为存在未覆盖的检查。
   * >0 时 UI 必须显眼提示「结果不完整」，不得宣称干净。
   */
  completenessNotices: number;
}

export interface DrcBackgroundResult {
  status: 'succeeded' | 'failed' | 'cancelled'; message: string;
  documentId: string; inputVersion: number;
  result?: DrcResult; rules: DrcRule[]; scopeText: string;
}
export interface DrcBackgroundJob {
  jobId: string; scope: string; completion: Promise<DrcBackgroundResult>;
}

/** In-session rollback state; preserves source identity as well as rule values. */
export interface DrcConfiguration {
  rules: DrcRule[]; baseRules: DrcRule[]; ruleFiles: string[];
  currentProcess: string; ruleSource: string; ruleSourceLabel: string; rulesTweaked: boolean;
  hierarchyDepth: number; deepMode: boolean; tilingEnabled: boolean; tileSize: number; ruleFilter: string;
}

/** 规则来源标识（面板与状态栏用它区分「内置预设」与「用户清单」） */
export const DRC_RULE_SOURCE_BUILTIN: string = 'builtin';
export const DRC_RULE_SOURCE_CUSTOM: string = 'custom';

/** 默认 DRC 规则集（内置预设；单一真源为 drcRulesets.RULESET_28NM，经 drcRuleText.builtinRules 深拷贝） */
export function createDefaultRules(): DrcRule[] {
  // D-6 / L-1: 预设映射只在一处（builtinRules），避免多处手抄字段
  return builtinRules();
}

/**
 * DRC 检查引擎
 */
export class DrcService {
  private rules: DrcRule[];
  private violationIdCounter: number = 1;

  /** native 模块（3 参 runDrc 用；加载失败时为 null → 回退 nativeHongTuService 的 2 参封装） */
  private drcNativeModule: HongTuNative | null = hongtu as HongTuNative;

  /** 深度模式开关（镜像 hierarchyDepth >= 1，供 UI Toggle 双向绑定） */
  deepMode: boolean = true;
  /**
   * native DRC 层级展开深度：
   * 0 = 仅各 Cell 本地几何（旧「快速几何预检查」口径）；
   * 1 = 本地 + 一层 SREF/AREF 展开（KLayout 风格默认，本服务默认值）；
   * ≥2 = 继续向下展开（native 侧上限 16 层）。
   * 只作用于 native 主路径：ArkTS AABB 回退路径拿不到实例展开几何，
   * 其结果一律标注为未展开（DrcResult.hierarchyDepthApplied === 0）。
   */
  hierarchyDepth: number = 1;
  /** 分块模式开关：开启后按 tileSize 切分设计区域逐块检查 */
  tilingEnabled: boolean = false;
  /** 分块大小（nm） */
  tileSize: number = 1000;
  /** 规则过滤关键字（按规则名 / ID 大小写不敏感子串匹配，空串表示不过滤） */
  ruleFilter: string = '';
  /** 外部引用的规则文件路径列表 */
  private ruleFiles: string[] = [];
  /** DRC-3/4: 当前生效的工艺节点（用于 removeRuleFile 时重建基础规则集） */
  private currentProcess: string = '28nm';
  /**
   * 规则来源：DRC_RULE_SOURCE_BUILTIN（内置预设 / 工艺节点预设）或 DRC_RULE_SOURCE_CUSTOM
   * （用户清单：粘贴文本、规则文件或手工改过参数）。面板据此如实显示，不得反过来猜。
   */
  ruleSource: string = DRC_RULE_SOURCE_BUILTIN;
  /** 规则来源的显示说明（预设名 / 清单 name 字段 / 规则文件路径） */
  ruleSourceLabel: string = BUILTIN_PRESET_NAME;
  /** 是否在来源之上手工改过单条规则（面板显示「含手工调整」） */
  rulesTweaked: boolean = false;
  /**
   * 基准规则集：装入当前生效规则时的那一份快照（内置预设 / 工艺预设 / 用户清单）。
   * removeRuleFile 触发的重建以它为底，避免「删一个规则文件顺手把用户清单也抹掉」。
   */
  private baseRules: DrcRule[] = createDefaultRules();
  /** 最近一次 runDrc 的完整结果（面板分组统计用；null = 本次会话尚未运行） */
  private lastRunResult: DrcResult | null = null;
  private lastRunRules: DrcRule[] = [];
  private lastRunScope: string = '';

  constructor() {
    this.rules = createDefaultRules();
  }

  /** 获取所有规则 */
  getRules(): DrcRule[] {
    return this.rules;
  }

  /** Geometry or configuration changed: previous measurements are no longer current. */
  invalidateResult(): void {
    this.lastRunResult = null;
    this.lastRunRules = [];
    this.lastRunScope = '';
  }

  captureConfiguration(): DrcConfiguration {
    return { rules: this.snapshotRules(this.rules), baseRules: this.snapshotRules(this.baseRules),
      ruleFiles: this.ruleFiles.slice(), currentProcess: this.currentProcess,
      ruleSource: this.ruleSource, ruleSourceLabel: this.ruleSourceLabel, rulesTweaked: this.rulesTweaked,
      hierarchyDepth: this.hierarchyDepth, deepMode: this.deepMode, tilingEnabled: this.tilingEnabled,
      tileSize: this.tileSize, ruleFilter: this.ruleFilter };
  }

  restoreConfiguration(state: DrcConfiguration): void {
    this.invalidateResult();
    this.rules = this.snapshotRules(state.rules); this.baseRules = this.snapshotRules(state.baseRules);
    this.ruleFiles = state.ruleFiles.slice(); this.currentProcess = state.currentProcess;
    this.ruleSource = state.ruleSource; this.ruleSourceLabel = state.ruleSourceLabel;
    this.rulesTweaked = state.rulesTweaked; this.hierarchyDepth = state.hierarchyDepth;
    this.deepMode = state.deepMode; this.tilingEnabled = state.tilingEnabled;
    this.tileSize = state.tileSize; this.ruleFilter = state.ruleFilter;
  }

  /** 当前规则来源标识：'builtin' / 'custom' */
  getRuleSource(): string {
    return this.ruleSource;
  }

  /** true = 当前生效的是内置预设（未装清单、未手工改值） */
  isBuiltinRuleSource(): boolean {
    return this.ruleSource === DRC_RULE_SOURCE_BUILTIN && !this.rulesTweaked;
  }

  /** 规则来源显示文案（面板「规则来源」区块与状态栏共用） */
  ruleSourceText(): string {
    const kind: string = this.ruleSource === DRC_RULE_SOURCE_BUILTIN ? '内置' : '自定义';
    const tweak: string = this.rulesTweaked ? ' · 含手工调整' : '';
    return kind + ' · ' + this.ruleSourceLabel + tweak;
  }

  /** 更新规则（手工改动会把来源标成「含手工调整」，来源本身不变） */
  updateRule(id: string, updates: Partial<DrcRule>): void {
    const rule = this.rules.find(r => r.id === id);
    if (rule) {
      this.invalidateResult();
      if (updates.id !== undefined) rule.id = updates.id;
      if (updates.name !== undefined) rule.name = updates.name;
      if (updates.type !== undefined) rule.type = updates.type;
      if (updates.layerNumber !== undefined) rule.layerNumber = updates.layerNumber;
      if (updates.targetLayerNumber !== undefined) rule.targetLayerNumber = updates.targetLayerNumber;
      if (updates.value !== undefined) rule.value = updates.value;
      if (updates.severity !== undefined) rule.severity = updates.severity;
      if (updates.description !== undefined) rule.description = updates.description;
      if (updates.enabled !== undefined) rule.enabled = updates.enabled;
      this.rulesTweaked = true;
    }
  }

  /** 设置当前生效规则集（整体替换；外部注入一律视为自定义来源） */
  setRules(rules: DrcRule[], label: string = '外部注入规则集'): void {
    this.invalidateResult();
    this.rules = rules;
    this.baseRules = this.snapshotRules(rules);
    // DRC-4: 整体替换规则集时清空 ruleFiles，避免 UI 显示的规则文件与实际生效规则脱节
    this.ruleFiles = [];
    this.ruleSource = DRC_RULE_SOURCE_CUSTOM;
    this.ruleSourceLabel = label;
    this.rulesTweaked = false;
  }

  /**
   * 设置单条规则的启用状态。
   * DRC-9: 返回 boolean 表示是否找到规则，避免静默失败让 UI 误以为修改成功。
   */
  setEnabled(ruleId: string, enabled: boolean): boolean {
    const rule = this.rules.find(r => r.id === ruleId);
    if (rule) {
      this.invalidateResult();
      rule.enabled = enabled;
      this.rulesTweaked = true;
      return true;
    }
    console.warn(`[DRC] setEnabled: 未找到规则 ${ruleId}`);
    return false;
  }

  /**
   * 设置单条规则的参数值。
   * DRC-9: 返回 boolean 表示是否找到规则，避免静默失败。
   */
  setValue(ruleId: string, value: number): boolean {
    if (!Number.isFinite(value) || value <= 0) return false;
    const rule = this.rules.find(r => r.id === ruleId);
    if (rule) {
      this.invalidateResult();
      rule.value = value;
      this.rulesTweaked = true;
      return true;
    }
    console.warn(`[DRC] setValue: 未找到规则 ${ruleId}`);
    return false;
  }

  /**
   * 设置深度模式：true → native DRC 展开一层实例几何（hierarchyDepth>=1），
   * false → 退回仅本地几何的快速预检查（hierarchyDepth=0）。
   */
  setDeepMode(v: boolean): void {
    this.invalidateResult();
    this.deepMode = v;
    this.hierarchyDepth = v ? Math.max(1, this.hierarchyDepth) : 0;
  }

  /**
   * 设置 native DRC 层级展开深度（0 = 仅本地几何，1 = KLayout 风格默认，更大更深）。
   * 同步 deepMode 标志，保持 UI Toggle 与实际行为一致。
   */
  setHierarchyDepth(v: number): void {
    this.invalidateResult();
    const d: number = v > 0 ? Math.min(Math.floor(v), 16) : 0;
    this.hierarchyDepth = d;
    this.deepMode = d >= 1;
  }

  /** 设置分块模式开关 */
  setTilingEnabled(v: boolean): void {
    this.invalidateResult();
    this.tilingEnabled = v;
  }

  /** 设置分块大小（nm） */
  setTileSize(v: number): void {
    if (!Number.isFinite(v) || v <= 0) return;
    this.invalidateResult();
    this.tileSize = v;
  }

  /** 设置规则过滤关键字（空串清除过滤） */
  getRuleFilter(): string {
    return this.ruleFilter;
  }

  setRuleFilter(s: string): void {
    this.invalidateResult();
    this.ruleFilter = s;
  }

  /**
   * 从**用户规则清单文本**装载规则（面板粘贴文本 / AI 指令共用）。
   *
   * 失败时**不改当前规则集**（不静默回退到内置预设），并把中文 error 原样返回给调用方显示。
   *
   * @param text 清单文本：JSON（{"name","rules":[…]} 或顶层数组）或 CSV/TSV/分号风格
   * @param merge false = 整体替换当前规则集；true = 按 ruleId 合并（同 ID 覆盖、新 ID 追加）
   */
  loadRulesFromText(text: string, merge: boolean = false): DrcRuleTextResult {
    const parsed: DrcRuleTextResult = parseRuleSetText(text);
    if (!parsed.ok) {
      console.warn(`[DRC] 规则清单装载失败：${parsed.error}`);
      return parsed;
    }
    this.invalidateResult();
    this.rules = merge ? mergeRulesById(this.rules, parsed.rules) : this.snapshotRules(parsed.rules);
    this.baseRules = merge ? mergeRulesById(this.baseRules, parsed.rules) : this.snapshotRules(parsed.rules);
    this.ruleSource = DRC_RULE_SOURCE_CUSTOM;
    this.ruleSourceLabel = merge
      ? `${parsed.setName}（合并进当前规则集）`
      : parsed.setName;
    this.rulesTweaked = false;
    if (!merge) {
      // DRC-4: 整体替换后旧的规则文件不再全部生效，清空避免 UI 显示与实际脱节
      this.ruleFiles = [];
    }
    console.info(`[DRC] 规则清单已装载：${parsed.rules.length} 条（格式 ${parsed.format}）`);
    return parsed;
  }

  /**
   * 从**规则文件**装载（与粘贴文本走同一个解析器，两条入口一套口径）。
   * @param merge false = 替换当前规则集；true = 按 ruleId 合并
   */
  loadRulesFromFile(path: string, merge: boolean = false): DrcRuleTextResult {
    if (path.length === 0) {
      const empty: DrcRuleTextResult = {
        ok: false, format: '', setName: '', rules: [], error: '路径不能为空', warnings: [],
      };
      return empty;
    }
    const text: string = readRuleFileText(path);
    if (text.trim().length === 0) {
      const missing: DrcRuleTextResult = {
        ok: false, format: '', setName: '', rules: [],
        error: `规则文件不存在、不可读或为空：${path}`, warnings: [],
      };
      return missing;
    }
    // 解析错误不带路径（调用方自己补），保证「粘贴文本」与「文件」两条入口的错误文案完全同源
    return this.loadRulesFromText(text, merge);
  }

  /** 恢复内置预设（面板「规则来源 = 内置」即走这里；行为与改动前的默认规则集一致） */
  resetRulesToBuiltin(): void {
    this.invalidateResult();
    this.rules = createDefaultRules();
    this.baseRules = this.snapshotRules(this.rules);
    this.ruleFiles = [];
    this.ruleSource = DRC_RULE_SOURCE_BUILTIN;
    this.ruleSourceLabel = BUILTIN_PRESET_NAME;
    this.currentProcess = '28nm';
    this.rulesTweaked = false;
  }

  /** 把当前生效规则集导出成**可再装载**的清单文本（面板「复制去编辑」用） */
  rulesAsText(): string {
    return ruleSetToText(this.rules, this.ruleSourceLabel);
  }

  /**
   * 添加一个外部规则文件路径（去重）并立即解析合并到当前规则集。
   * @param path 规则文件绝对路径
   * @returns 状态字符串：成功时为 `已加载 N 条规则：${path}`；
   *          失败时为 `规则文件解析失败：…`（中文原因，来自同一套解析器）
   */
  addRuleFile(path: string): string {
    if (path.length === 0) {
      return '路径不能为空';
    }
    if (this.ruleFiles.indexOf(path) >= 0) {
      return '该规则文件已添加';
    }
    const parsed: DrcRuleTextResult = this.loadRulesFromFile(path, true);
    if (!parsed.ok) {
      return `规则文件装载失败：${parsed.error}`;
    }
    this.ruleFiles.push(path);
    // 来源说明落到「文件」上：合并后的 label 不再是单一清单名
    this.ruleSourceLabel = this.ruleFiles.join('、');
    const tip: string = parsed.warnings.length > 0 ? `（提示：${parsed.warnings[0]}）` : '';
    return `已加载 ${parsed.rules.length} 条规则：${path}${tip}`;
  }

  /** 移除一个外部规则文件路径 */
  removeRuleFile(path: string): void {
    const idx = this.ruleFiles.indexOf(path);
    if (idx >= 0) {
      this.ruleFiles.splice(idx, 1);
      // DRC-3: 移除文件后需同步移除其规则，否则 UI 显示已移除但规则仍生效
      // 最简方案：从当前规则集基础重建 + 重新应用剩余 ruleFiles
      this.rebuildRulesFromBase();
    }
  }

  /**
   * DRC-3: 从基础规则集重建 this.rules，并重新应用剩余 ruleFiles。
   * 基础集 `baseRules` 是「装入当前规则集时的那一份」（内置预设 / 工艺预设 / 用户清单），
   * 这样移除某个规则文件不会顺手把用户清单也抹掉。
   * 解析走与粘贴文本同一个解析器；解析失败的文件跳过并 console.warn（不静默产出半套规则）。
   */
  private rebuildRulesFromBase(): void {
    this.invalidateResult();
    let rebuilt: DrcRule[] = this.snapshotRules(this.baseRules);
    for (let i = 0; i < this.ruleFiles.length; i++) {
      const path: string = this.ruleFiles[i];
      const parsed: DrcRuleTextResult = this.parseRuleFileText(readRuleFileText(path));
      if (!parsed.ok) {
        console.warn(`[DRC] 规则文件重新装载失败，已跳过：${path} —— ${parsed.error}`);
        continue;
      }
      rebuilt = mergeRulesById(rebuilt, parsed.rules);
    }
    this.rules = rebuilt;
    if (this.ruleFiles.length > 0) {
      this.ruleSource = DRC_RULE_SOURCE_CUSTOM;
      this.ruleSourceLabel = this.ruleFiles.join('、');
    }
  }

  /** 只解析、不改服务状态（重建流程用；文本为空 = 文件不可读，给中文提示） */
  private parseRuleFileText(text: string): DrcRuleTextResult {
    if (text.trim().length === 0) {
      const empty: DrcRuleTextResult = {
        ok: false, format: '', setName: '', rules: [], error: '文件为空或不可读', warnings: [],
      };
      return empty;
    }
    return parseRuleSetText(text);
  }

  /** 逐条深拷贝（规则对象会被面板单条编辑，基准集不能与生效集共享引用） */
  private snapshotRules(rules: DrcRule[]): DrcRule[] {
    const out: DrcRule[] = [];
    for (let i = 0; i < rules.length; i++) {
      out.push(copyRule(rules[i]));
    }
    return out;
  }

  /** 获取当前外部规则文件路径列表（副本） */
  getRuleFiles(): string[] {
    return this.ruleFiles.slice();
  }

  /**
   * 根据工艺节点创建规则集（深拷贝，避免修改预设）
   * @param process 工艺节点：'28nm' / '14nm' / '7nm'
   * @returns 对应工艺的规则列表；未知工艺回退到 28nm 默认
   */
  createRuleset(process: string): DrcRule[] {
    const ruleset = ALL_RULESETS.find(rs => rs.process === process);
    if (!ruleset) {
      return createDefaultRules();
    }
    return ruleset.rules.map((r): DrcRule => copyRule(r));
  }

  /** 切换工艺节点规则集并设为当前生效（内置预设之一） */
  applyRuleset(process: string): void {
    this.invalidateResult();
    this.rules = this.createRuleset(process);
    this.currentProcess = process;
    this.baseRules = this.snapshotRules(this.rules);
    // DRC-4: 切换规则集时清空 ruleFiles，避免 UI 显示的规则文件与实际生效规则脱节
    this.ruleFiles = [];
    this.ruleSource = DRC_RULE_SOURCE_BUILTIN;
    const named: DrcRuleset | undefined = ALL_RULESETS.find(rs => rs.process === process);
    this.ruleSourceLabel = named !== undefined ? named.name : BUILTIN_PRESET_NAME;
    this.rulesTweaked = false;
  }

  /**
   * 运行 DRC 检查
   * @param shapes 待检查的图形列表（ArkTS 回退路径用；仅当前 Cell 本地几何）
   * @param onProgress 进度回调
   * @param useNative 允许走 native DRC 内核主路径（调用方需保证 native 布局与
   *        当前编辑态一致；编辑后先 syncDocument，无需磁盘保存。native 失败自动回退 ArkTS）
   * @param ownerCellId native 路径的检查根 Cell（-1 = 全部 Cell 本地几何 / top cell）
   * @param hierarchyDepth native 层级展开深度；省略或 -1 = 取 this.hierarchyDepth；
   *        0 = 仅本地几何（旧快速预检查），≥1 = 展开 SREF/AREF 实例几何（KLayout 风格默认 1）
   */
  /** Snapshot rules and inputs before queuing. Heavy checks stay in the native worker;
   * unsupported rules become completeness notices instead of a blocking JS fallback. */
  startDrcJob(snapshot: NativeRenderSnapshot, options: NativeDrcJobOptions): DrcBackgroundJob | null {
    const started: number = Date.now();
    const runRules: DrcRule[] = this.snapshotRules(this.rules);
    const filter: string = this.ruleFilter.toLowerCase();
    for (let i: number = 0; i < runRules.length; i++) {
      runRules[i].enabled = runRules[i].enabled && (filter.length === 0 ||
        runRules[i].id.toLowerCase().includes(filter) || runRules[i].name.toLowerCase().includes(filter));
    }
    const active: DrcRule[] = runRules.filter((r: DrcRule) => r.enabled);
    const nativeRules: NativeDrcRule[] = [];
    for (const rule of active) {
      const mapped: NativeDrcRule | null = this.toNativeRule(rule);
      if (mapped !== null) nativeRules.push(mapped);
    }
    const skipped: number = active.length - nativeRules.length;
    const tiled: boolean = this.tilingEnabled;
    const source: string = this.ruleSourceText();
    const process: string = this.currentProcess;
    const box: NativeJobScopeBox | undefined = options.scopeBox;
    const scopeBox: NativeJobScopeBox | undefined = box === undefined ? undefined : {
      minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY };
    const jobOptions: NativeDrcJobOptions = { scope: options.scope, documentId: options.documentId,
      inputVersion: options.inputVersion, ownerCellId: options.ownerCellId, hierarchyDepth: options.hierarchyDepth,
      mergeSameLayer: options.mergeSameLayer || (process === 'sky130-met1-public' &&
        nativeRules.every((r: NativeDrcRule) => r.type === 0 || r.type === 1 || r.type === 3)), scopeBox: scopeBox };
    const native: NativeDrcJob | null = nativeHongTuService.startDrcJob(snapshot, nativeRules, jobOptions);
    if (native === null) return null;
    const completion: Promise<DrcBackgroundResult> = native.completion.then((output: NativeDrcJobResult): DrcBackgroundResult => {
      const scopeText: string = `${source} · Cell ${jobOptions.ownerCellId} · 输入版本 ${jobOptions.inputVersion}`
        + ` · 层级 ${output.hierarchyDepthApplied ?? 0} · 快速几何预检查，非签核`;
      if (output.status !== 'succeeded') return { status: output.status, message: output.message,
        documentId: jobOptions.documentId, inputVersion: jobOptions.inputVersion, rules: runRules, scopeText: scopeText };
      const violations: DrcViolation[] = (output.violations ?? []).map((v: NativeDrcViolation): DrcViolation => this.nativeViolationToDrc(v, runRules));
      const notices: string[] = [];
      if (active.length === 0) notices.push('未启用任何匹配规则，未进行检查');
      if (skipped > 0) notices.push(`${skipped} 条规则尚不支持后台内核，未检查；未转入阻塞界面的同步回退`);
      if (tiled) notices.push('后台路径当前执行完整范围预检查，未执行分块配置');
      if (jobOptions.scopeBox !== undefined) notices.push('范围检查按与范围相交的完整图形计算，范围外邻居及跨边界规则未构成完整覆盖');
      for (const message of notices) {
        violations.push({ id: this.violationIdCounter++, ruleId: DRC_NOTICE_EXEC, ruleName: '后台检查完整性提示',
          type: DrcRuleType.MIN_WIDTH, severity: DrcSeverity.WARNING, layerNumber: 0,
          x: 0, y: 0, width: 0, height: 0, shapeIds: [], message: message });
      }
      const errors: number = violations.filter((v: DrcViolation) => !isCompletenessNotice(v.ruleId) && v.severity === DrcSeverity.ERROR).length;
      const warnings: number = violations.filter((v: DrcViolation) => !isCompletenessNotice(v.ruleId) && v.severity === DrcSeverity.WARNING).length;
      const completeness: number = violations.filter((v: DrcViolation) => isCompletenessNotice(v.ruleId)).length;
      const result: DrcResult = { totalRules: active.length, executedRules: nativeRules.length,
        totalViolations: violations.length, errors: errors, warnings: warnings, passed: errors === 0 && completeness === 0,
        violations: violations, elapsed: Date.now() - started, hierarchyDepthApplied: output.hierarchyDepthApplied ?? 0,
        arkFallbackRules: 0, completenessNotices: completeness };
      return { status: output.status, message: output.message, documentId: jobOptions.documentId,
        inputVersion: jobOptions.inputVersion, result: result, rules: runRules, scopeText: scopeText };
    });
    return { jobId: native.jobId, scope: native.scope, completion: completion };
  }

  /** Caller verifies active document + revision before publishing a completed background result. */
  acceptBackgroundResult(output: DrcBackgroundResult): boolean {
    if (output.status !== 'succeeded' || output.result === undefined) return false;
    this.lastRunRules = this.snapshotRules(output.rules); this.lastRunScope = output.scopeText; this.lastRunResult = output.result;
    return true;
  }

  /** densityGridNm is the active document's physical DBU in nm; omitted callers retain 1 nm. */
  runDrc(
    shapes: Shape[],
    onProgress?: (percent: number, message: string) => void,
    useNative: boolean = false,
    ownerCellId: number = -1,
    hierarchyDepth: number = -1,
    densityGridNm: number = 1
  ): DrcResult {
    const startTime = Date.now();
    const violations: DrcViolation[] = [];
    const drawableShapes: Shape[] = shapes.filter((s: Shape) => s.type !== ShapeType.NODE);
    // DRC-3: onProgress 防御性处理，允许调用方省略或传 null/undefined
    const progressCb: (p: number, m: string) => void = onProgress ?? ((_p: number, _m: string) => {});

    // 本次请求的层级展开深度（<0 表示沿用服务上的默认配置）
    const requestedDepth: number = hierarchyDepth >= 0 ? hierarchyDepth : this.hierarchyDepth;
    // 实际生效深度：只有 native 路径真正执行后才可能 > 0（ArkTS 回退路径不展开）
    let depthApplied: number = 0;

    if (requestedDepth >= 1) {
      console.info(`[DRC] 层级展开深度 ${requestedDepth}：实例内几何将变换到检查根 Cell 坐标系后并入检查`);
    } else {
      console.info('[DRC] 层级展开关闭（depth=0）：仅检查 Cell 本地几何（快速预检查口径）');
    }

    // 应用规则过滤：按规则名 / ID 大小写不敏感子串匹配
    let activeRules = this.rules.filter(r => r.enabled);
    if (this.ruleFilter.length > 0) {
      const filter = this.ruleFilter.toLowerCase();
      activeRules = activeRules.filter(r =>
        r.name.toLowerCase().includes(filter) ||
        r.id.toLowerCase().includes(filter)
      );
    }
    // DRC-1: totalRules 与 executedRules 口径统一，均基于本次实际执行的 activeRules
    const totalRules = activeRules.length;
    if (totalRules === 0) {
      violations.push({ id: this.violationIdCounter++, ruleId: DRC_NOTICE_EXEC,
        ruleName: '没有可执行规则', type: DrcRuleType.MIN_WIDTH, severity: DrcSeverity.WARNING,
        layerNumber: 0, x: 0, y: 0, width: 0, height: 0, shapeIds: [],
        message: '未启用任何匹配规则，未进行设计规则检查，不能判定通过' });
    }
    const runRules: DrcRule[] = this.snapshotRules(this.rules);
    for (let i: number = 0; i < runRules.length; i++) {
      runRules[i].enabled = activeRules.some((rule: DrcRule) => rule.id === runRules[i].id);
    }
    const runSource: string = this.ruleSourceText();
    const runProcess: string = this.currentProcess;
    let executedRules = 0;

    progressCb(5, '初始化 DRC 引擎...');

    // 原生 DRC 主路径：可映射规则交给 native 内核（R-Tree + 真实边距 + 层级展开），
    // 不可映射规则（如未指定包围层的 enclosure）留给 ArkTS 路径补检
    if (useNative && !this.tilingEnabled) {
      const nativeRules: NativeDrcRule[] = [];
      const arkOnlyRules: DrcRule[] = [];
      for (let i = 0; i < activeRules.length; i++) {
        const nr = this.toNativeRule(activeRules[i]);
        if (nr !== null) {
          nativeRules.push(nr);
        } else {
          arkOnlyRules.push(activeRules[i]);
        }
      }
      if (nativeRules.length > 0) {
        progressCb(15, `原生 DRC 内核检查 ${nativeRules.length} 条规则（层级深度 ${requestedDepth}）...`);
        const nativeViolations = this.runNativeDrc(nativeRules, ownerCellId, requestedDepth);
        if (nativeViolations !== null) {
          for (let i = 0; i < nativeViolations.length; i++) {
            violations.push(this.nativeViolationToDrc(nativeViolations[i]));
          }
          executedRules += nativeRules.length;
          activeRules = arkOnlyRules;
          depthApplied = requestedDepth;
          progressCb(40, `原生检查完成：${nativeViolations.length} 项（层级深度 ${depthApplied}）`);
        }
        // nativeViolations === null → native 不可用/失败，全部规则回退 ArkTS（不展开层级）
      }
    }
    // 由 ArkTS 路径（不展开层级）检查的规则数：必须在 native 分流之后统计
    const arkFallbackRules = activeRules.length;
    if (this.currentProcess === 'sky130-met1-public' && arkFallbackRules > 0) {
      violations.push({
        id: this.violationIdCounter++, ruleId: DRC_NOTICE_MERGE,
        ruleName: '同层区域合并未覆盖', type: DrcRuleType.MIN_WIDTH,
        severity: DrcSeverity.WARNING, layerNumber: 68,
        x: 0, y: 0, width: 0, height: 0, shapeIds: [],
        message: `${arkFallbackRules} 条规则未使用原生合并区域检查，结果不完整`,
      });
    }

    // 按规则类型分组执行
    for (const rule of activeRules) {
      try {
        // Omitted datatype is wildcard; explicit zero is an exact purpose.
        const layerShapes = drawableShapes.filter(s => this.shapeMatchesRuleLayer(rule, s));

        if (this.tilingEnabled && this.tileSize > 0 && layerShapes.length > 0) {
          // 分块模式：按 tileSize 切分设计区域，逐块执行规则检查
          this.runRuleTiled(rule, layerShapes, drawableShapes, violations, densityGridNm);
        } else {
          switch (rule.type) {
            case DrcRuleType.MIN_WIDTH:
              this.checkMinWidth(rule, layerShapes, violations);
              break;
            case DrcRuleType.MIN_SPACING:
              this.checkMinSpacing(rule, layerShapes, violations);
              break;
            case DrcRuleType.MIN_AREA:
              this.checkMinArea(rule, layerShapes, violations);
              break;
            case DrcRuleType.MIN_ENCLOSURE:
              this.checkMinEnclosure(rule, layerShapes, drawableShapes, violations);
              break;
            case DrcRuleType.DENSITY:
              this.checkDensity(rule, layerShapes, violations, densityGridNm);
              break;
          }
        }
      } catch (e) {
        // 单条规则失败不中断整体 DRC，记录 INFO 违规并继续
        console.warn(`[DRC] 规则 ${rule.id} 执行异常: ${e}`);
        violations.push({
          id: this.violationIdCounter++,
          ruleId: DRC_NOTICE_EXEC,
          ruleName: `规则未完成：${rule.name}`,
          type: rule.type,
          severity: DrcSeverity.WARNING,
          layerNumber: rule.layerNumber,
          x: 0, y: 0, width: 0, height: 0,
          message: `规则 ${rule.id} 执行异常，结果不完整: ${e}`,
          shapeIds: [],
        });
      }

      executedRules++;
      const percent = 5 + Math.round((executedRules / totalRules) * 90);
      progressCb(percent, `检查规则: ${rule.name} (${executedRules}/${totalRules})`);
    }

    // 诚实标注：本次已有规则走层级展开的 native 路径，但另有规则由不展开的 ArkTS 路径补检
    // → 混合结果必须显式说明哪部分未展开（纯 ArkTS 结果由 hierarchyDepthApplied=0 表达）
    if (requestedDepth >= 1 && arkFallbackRules > 0) {
      violations.push({
        id: this.violationIdCounter++,
        ruleId: DRC_NOTICE_NOHIER,
        ruleName: '层级展开未覆盖',
        type: DrcRuleType.MIN_WIDTH,
        severity: DrcSeverity.WARNING,
        layerNumber: 0,
        x: 0, y: 0, width: 0, height: 0,
        message: `${arkFallbackRules} 条规则由 ArkTS 回退路径检查：仅覆盖当前 Cell 本地几何，`
          + `未展开实例层级（非签核，结果偏乐观）`,
        shapeIds: [],
        fromInstance: false,
      });
    }

    progressCb(100, `DRC 完成: ${violations.length} 项违规（层级深度 ${depthApplied}）`);

    // 口径分离（L-2）：DRC.TRUNC / DRC.NOHIER 是「结果是否完整」的告警，不是规则违例。
    // 它们不进 errors / warnings 或规则命中数，但会阻止 passed。
    let errors = 0;
    let warnings = 0;
    let notices = 0;
    for (let i = 0; i < violations.length; i++) {
      const v = violations[i];
      if (isCompletenessNotice(v.ruleId)) {
        notices++;
        continue;
      }
      if (v.severity === DrcSeverity.ERROR) {
        errors++;
      } else if (v.severity === DrcSeverity.WARNING) {
        warnings++;
      }
    }

    const result: DrcResult = {
      // DRC-1: totalRules 使用 activeRules.length，与 executedRules 口径一致
      totalRules: totalRules,
      executedRules,
      // 原始行数（含完整性告警行）；纯规则违例数见 groupViolationsByRule().ruleViolationCount
      totalViolations: violations.length,
      errors,
      warnings,
      passed: errors === 0 && notices === 0,
      violations,
      elapsed: Date.now() - startTime,
      hierarchyDepthApplied: depthApplied,
      arkFallbackRules,
      completenessNotices: notices,
    };
    this.lastRunRules = runRules;
    this.lastRunScope = `${runSource} · ${executedRules} 条已执行规则 · 层级 ${depthApplied}`
      + (runProcess === 'sky130-met1-public'
        ? ' · 仅 met1 宽度/间距/面积子集，非工艺签核'
        : ' · 快速几何预检查，非签核');
    this.lastRunResult = result;
    return result;
  }

  /** 最近一次 runDrc 的结果（null = 本次会话尚未运行） */
  getLastResult(): DrcResult | null {
    return this.lastRunResult;
  }

  /** 单条规则的信息行数（severity=info 的规则违例，既非 error 也非 warning） */
  getLastInfoCount(): number {
    const r = this.lastRunResult;
    if (r === null) {
      return 0;
    }
    return Math.max(0, r.totalViolations - r.errors - r.warnings - r.completenessNotices);
  }

  /**
   * 把最近一次结果按 ruleId 归组（面板分组统计表用）。
   * null = 尚未运行过 DRC。口径：完整性告警（TRUNC / NOHIER）不进任何规则的命中数，
   * 单独在 summary.notices 里；存在完整性告警时不得判为通过。
   */
  getRuleGroups(): DrcGroupSummary | null {
    const r = this.lastRunResult;
    if (r === null) {
      return null;
    }
    const summary: DrcGroupSummary = groupViolationsByRule(this.lastRunRules, this.toViolationRefs(r.violations));
    summary.scopeNote = this.lastRunScope;
    return summary;
  }

  /** DrcViolation[] → 分组用的轻量引用列表（不让纯逻辑模块反向依赖 native 类型） */
  private toViolationRefs(violations: DrcViolation[]): DrcViolationRef[] {
    const refs: DrcViolationRef[] = [];
    for (let i = 0; i < violations.length; i++) {
      const v = violations[i];
      refs.push({
        ruleId: v.ruleId,
        ruleName: v.ruleName,
        severity: v.severity,
        x: v.x,
        y: v.y,
        message: v.message,
      });
    }
    return refs;
  }

  /**
   * 调用 native DRC 内核（带层级展开深度）。
   * NativeHongTuService 的封装只转发 (rules, ownerCellId) 两参，无法传深度，
   * 故优先直取 native 模块；模块不可用或异常时回退 2 参封装（native 侧按 depth=0 处理），
   * 两者都失败返回 null，由调用方整体回退 ArkTS 路径。
   * @returns 违规列表；null = native 不可用
   */
  private runNativeDrc(rules: NativeDrcRule[], ownerCellId: number,
                       hierarchyDepth: number): NativeDrcViolation[] | null {
    // Only the independently checked public met1 subset uses merged regions by
    // default. Other checker types still have separate per-shape semantics.
    const merged: boolean = this.currentProcess === 'sky130-met1-public' &&
      rules.every((rule: NativeDrcRule) => rule.type === 0 || rule.type === 1 || rule.type === 3);
    const nativeMod: HongTuNative | null = this.drcNativeModule;
    if (nativeMod !== null && nativeMod !== undefined) {
      try {
        return nativeMod.runDrc(rules, ownerCellId, hierarchyDepth, merged ? 1 : 0) ?? null;
      } catch (error) {
        console.error('native runDrc(层级展开) 失败: ' + error);
        return null;
      }
    }
    // The older two-argument wrapper cannot provide the requested hierarchy or
    // merged semantics. Let the caller report the visible fallback notice.
    if (merged || hierarchyDepth > 0) return null;
    return nativeHongTuService.runDrc(rules, ownerCellId);
  }

  /**
   * 分块执行单条规则：将设计区域按 tileSize 切分，对每个分块内的图形子集
   * 重新执行该规则检查。
   * 间距规则按阈值扩展 halo，覆盖跨块对象对；按成员 ID 去重。
   * 密度规则保持全设计窗口原点与范围，不能用子块重新定义窗口。
   */
  private runRuleTiled(rule: DrcRule, layerShapes: Shape[], allShapes: Shape[], violations: DrcViolation[], densityGridNm: number = 1): void {
    if (rule.type === DrcRuleType.DENSITY) {
      this.checkDensity(rule, layerShapes, violations, densityGridNm);
      return;
    }
    const bounds = this.boundsOfShapes(layerShapes);
    const tile = this.tileSize;
    if (tile <= 0) {
      return;
    }
    const halo: number = rule.type === DrcRuleType.MIN_SPACING ? Math.max(0, rule.value) : 0;
    const seen: Set<string> = new Set<string>();
    for (let x = bounds.minX; x < bounds.maxX; x += tile) {
      for (let y = bounds.minY; y < bounds.maxY; y += tile) {
        const tx0 = x;
        const ty0 = y;
        const tx1 = x + tile;
        const ty1 = y + tile;
        const tileShapes = layerShapes.filter(s => {
          const b = getShapeBounds(s);
          return b.maxX >= tx0 - halo && b.minX <= tx1 + halo &&
            b.maxY >= ty0 - halo && b.minY <= ty1 + halo;
        });
        if (tileShapes.length === 0) {
          continue;
        }
        const tileViolations: DrcViolation[] = [];
        switch (rule.type) {
          case DrcRuleType.MIN_WIDTH:
            this.checkMinWidth(rule, tileShapes, tileViolations);
            break;
          case DrcRuleType.MIN_SPACING:
            this.checkMinSpacing(rule, tileShapes, tileViolations);
            break;
          case DrcRuleType.MIN_AREA:
            this.checkMinArea(rule, tileShapes, tileViolations);
            break;
          case DrcRuleType.MIN_ENCLOSURE:
            this.checkMinEnclosure(rule, tileShapes, allShapes, tileViolations);
            break;
        }
        for (const violation of tileViolations) {
          const ids: number[] = violation.shapeIds.slice().sort((a: number, b: number): number => a - b);
          const key: string = violation.ruleId + ':' + ids.join(',');
          if (!seen.has(key)) {
            seen.add(key);
            violations.push(violation);
          }
        }
      }
    }
  }

  /** 最小宽度检查 */
  private checkMinWidth(rule: DrcRule, shapes: Shape[], violations: DrcViolation[]): void {
    for (const shape of shapes) {
      // D-2: 跳过 INSTANCE/TEXT，其退化 bbox 不反映真实几何宽度
      if (shape.type === ShapeType.INSTANCE || shape.type === ShapeType.TEXT) continue;
      const b = getShapeBounds(shape);
      // PATH 类型使用 pathWidth（路径宽度）而非包围盒最小边，
      // 因为 PATH 的几何宽度由 pathWidth 决定，bbox 最小边可能与实际线宽不符
      let width: number;
      let skipWidthCheck = false;
      if (shape.type === ShapeType.PATH) {
        // DRC-2: pathWidth 未设置（undefined）时跳过宽度检查（无法判定线宽）
        if (shape.pathWidth === undefined) {
          skipWidthCheck = true;
          width = 0;
        } else {
          width = shape.pathWidth;
        }
      } else {
        width = Math.min(b.maxX - b.minX, b.maxY - b.minY);
      }
      if (skipWidthCheck) continue;
      // D-1: PATH 的 pathWidth===0 是确凿违规（0 < rule.value 必然成立），不应被 width > 0 守卫跳过；
      // 非 PATH 退化图形（width<=0，如空 points）应跳过
      const isViolation: boolean = shape.type === ShapeType.PATH
        ? width < rule.value
        : (width < rule.value && width > 0);
      if (isViolation) {
        violations.push({
          id: this.violationIdCounter++,
          ruleId: rule.id,
          ruleName: rule.name,
          type: rule.type,
          severity: rule.severity,
          layerNumber: rule.layerNumber,
          x: (b.minX + b.maxX) / 2,
          y: (b.minY + b.maxY) / 2,
          width: b.maxX - b.minX,
          height: b.maxY - b.minY,
          message: `宽度 ${width}nm < 规则要求 ${rule.value}nm`,
          shapeIds: [shape.id],
        });
      }
    }
  }

  /** 最小间距检查 */
  private checkMinSpacing(rule: DrcRule, shapes: Shape[], violations: DrcViolation[]): void {
    // D-2/D-4: 过滤 INSTANCE/TEXT（退化 bbox 产生虚假间距违规）和空 points 图形（原点假命中）
    const geometricShapes: Shape[] = [];
    for (let i = 0; i < shapes.length; i++) {
      const s = shapes[i];
      if (s.type === ShapeType.INSTANCE || s.type === ShapeType.TEXT) continue;
      if (s.points.length === 0) continue;
      geometricShapes.push(s);
    }
    for (let i = 0; i < geometricShapes.length; i++) {
      for (let j = i + 1; j < geometricShapes.length; j++) {
        const dist = this.shapeDistance(geometricShapes[i], geometricShapes[j]);
        if (dist >= 0 && dist < rule.value) {
          const b1 = getShapeBounds(geometricShapes[i]);
          const b2 = getShapeBounds(geometricShapes[j]);
          violations.push({
            id: this.violationIdCounter++,
            ruleId: rule.id,
            ruleName: rule.name,
            type: rule.type,
            severity: rule.severity,
            layerNumber: rule.layerNumber,
            x: (b1.minX + b2.minX) / 2,
            y: (b1.minY + b2.minY) / 2,
            width: Math.abs(b2.maxX - b1.minX),
            height: Math.abs(b2.maxY - b1.minY),
            message: `间距 ${Math.round(dist)}nm < 规则要求 ${rule.value}nm`,
            shapeIds: [geometricShapes[i].id, geometricShapes[j].id],
          });
        }
      }
    }
  }

  /** 最小面积检查 */
  private checkMinArea(rule: DrcRule, shapes: Shape[], violations: DrcViolation[]): void {
    for (const shape of shapes) {
      const area = getShapeArea(shape);
      if (area > 0 && area < rule.value) {
        const b = getShapeBounds(shape);
        violations.push({
          id: this.violationIdCounter++,
          ruleId: rule.id,
          ruleName: rule.name,
          type: rule.type,
          severity: rule.severity,
          layerNumber: rule.layerNumber,
          x: (b.minX + b.maxX) / 2,
          y: (b.minY + b.maxY) / 2,
          width: b.maxX - b.minX,
          height: b.maxY - b.minY,
          message: `面积 ${area}nm² < 规则要求 ${rule.value}nm²`,
          shapeIds: [shape.id],
        });
      }
    }
  }

  /**
   * Layer must match; omitted datatype is wildcard, including explicit zero is exact.
   */
  private shapeMatchesRuleLayer(rule: DrcRule, s: Shape): boolean {
    if (s.layerNumber !== rule.layerNumber) {
      return false;
    }
    return rule.datatype === undefined || (s.datatype ?? 0) === rule.datatype;
  }

  /** 包围层过滤（同上，用 targetDatatype；targetLayer<0 表示「任意其他层」不参与） */
  private targetMatchesRuleLayer(rule: DrcRule, s: Shape, targetLayer: number): boolean {
    if (s.layerNumber !== targetLayer) {
      return false;
    }
    return rule.targetDatatype === undefined || (s.datatype ?? 0) === rule.targetDatatype;
  }

  /**
   * 最小包围检查
   * 算法覆盖范围：
   * - RECT 图形：基于矩形四条边到相邻图层图形的边距判断包围关系，
   *   能正确处理边重叠 / 共边 / 部分重叠场景（矩形 bbox 即真实几何）
   * - POLYGON / PATH / 其他类型：保留包围盒近似检查，凹多边形等边角情况未处理
   */
  private checkMinEnclosure(rule: DrcRule, shapes: Shape[], allShapes: Shape[], violations: DrcViolation[]): void {
    // 检查当前图层图形是否被目标图层图形包围。
    // 优先使用 rule.targetLayerNumber（明确指定的包围层）；
    // 未指定时回退到设计中所有其他图层（排除当前规则图层）。
    let targetLayers: number[];
    if (rule.targetLayerNumber >= 0) {
      targetLayers = [rule.targetLayerNumber];
    } else {
      const otherLayerSet = new Set<number>();
      for (let i = 0; i < allShapes.length; i++) {
        if (allShapes[i].layerNumber !== rule.layerNumber) {
          otherLayerSet.add(allShapes[i].layerNumber);
        }
      }
      targetLayers = Array.from(otherLayerSet);
    }
      const targetShapes = allShapes.filter(s =>
        s.type !== ShapeType.INSTANCE &&
        s.type !== ShapeType.TEXT &&
        targetLayers.some((targetLayer: number) => this.targetMatchesRuleLayer(rule, s, targetLayer))
      );
      for (const shape of shapes) {
        // D-3: 跳过 INSTANCE/TEXT，其退化 bbox（单点）误判包围关系
        if (shape.type === ShapeType.INSTANCE || shape.type === ShapeType.TEXT) continue;
        const b1 = getShapeBounds(shape);
        let enclosed = false;
        for (const target of targetShapes) {
          // DRC-FIX: enclosureMargin 正值表示 target 包住 shape，要求四边外延 >= rule.value
          if (this.enclosureMargin(shape, target) >= rule.value) {
            enclosed = true;
            break;
          }
        }
        if (!enclosed) {
          violations.push({
            id: this.violationIdCounter++,
            ruleId: rule.id,
            ruleName: rule.name,
            type: rule.type,
            severity: rule.severity,
            layerNumber: rule.layerNumber,
            x: (b1.minX + b1.maxX) / 2,
            y: (b1.minY + b1.maxY) / 2,
            width: b1.maxX - b1.minX,
            height: b1.maxY - b1.minY,
            message: `图形未被相邻图层充分包围 (要求 ${rule.value}nm)`,
            shapeIds: [shape.id],
          });
        }
      }
  }

  /**
   * 计算 shape 被 target 包围的最小边距余量
   * - RECT vs RECT：逐边计算外延距离，bbox 即轴对齐矩形真实几何，结果精确
   * - POLYGON / PATH / 其他：退化为包围盒边距近似，凹多边形边角情况未处理
   * 返回值：正值表示 target 在该侧包住 shape；负值表示 shape 超出 target
   */
  private enclosureMargin(shape: Shape, target: Shape): number {
    const b1 = getShapeBounds(shape);
    const b2 = getShapeBounds(target);
    // 四条边的包围余量：target 边相对 shape 边的外延距离
    // 注：RECT 的 bbox 即真实几何，结果精确；POLYGON/PATH 为包围盒近似，凹多边形边角未处理
    const leftMargin = b1.minX - b2.minX;
    const rightMargin = b2.maxX - b1.maxX;
    const bottomMargin = b1.minY - b2.minY;
    const topMargin = b2.maxY - b1.maxY;
    return Math.min(leftMargin, rightMargin, bottomMargin, topMargin);
  }

  /** Area of the filled union clipped to the unchanged full-design window lattice. */
  private checkDensity(rule: DrcRule, shapes: Shape[], violations: DrcViolation[], gridNm: number = 1): void {
    if (rule.value <= 0) {
      return;
    }
    if (!Number.isFinite(gridNm) || gridNm <= 0) throw new Error('密度缺少有效的物理 DBU 网格');
    if (shapes.length === 0) throw new Error('密度源层为空，无法由源图形确定检查窗口');
    if (shapes.length > 100000) throw new Error('密度源层超过 100000 个对象预算');
    const geometry: DensityGeometry = this.densityGeometry(shapes, gridNm);
    const designBounds = this.boundsOfShapes(shapes);
    const designW = designBounds.maxX - designBounds.minX;
    const designH = designBounds.maxY - designBounds.minY;
    if (!Number.isFinite(designW) || !Number.isFinite(designH) || designW <= 0 || designH <= 0) throw new Error('密度设计窗口缺少有限正面积');

    const windowSize = Math.max(1000, rule.value * 20);
    const step = windowSize;
    const endX = designBounds.maxX;
    const endY = designBounds.maxY;
    const maxViolationsPerRule = 50;
    let emitted = 0;
    if (Math.ceil(designW / windowSize) * Math.ceil(designH / windowSize) > 10000) throw new Error('密度超过 10000 个检查窗口预算');
    const work: DensityWork = { examined: 0 };
    if (geometry.approximation.length > 0) {
      violations.push({ id: this.violationIdCounter++, ruleId: DRC_NOTICE_EXEC,
        ruleName: `密度精度未完成：${rule.name}`, type: rule.type, severity: DrcSeverity.WARNING,
        layerNumber: rule.layerNumber, x: 0, y: 0, width: 0, height: 0, shapeIds: [],
        message: `规则 ${rule.id} 已按实际量化区域计算；${geometry.approximation}，结果不完整，不能判定通过` });
    }

    for (let x = designBounds.minX; x < endX && emitted < maxViolationsPerRule; x += step) {
      const wx0 = x;
      const wx1 = Math.min(x + windowSize, endX);
      if (wx1 <= wx0) {
        continue;
      }
      for (let y = designBounds.minY; y < endY && emitted < maxViolationsPerRule; y += step) {
        const wy0 = y;
        const wy1 = Math.min(y + windowSize, endY);
        if (wy1 <= wy0) {
          continue;
        }
        const windowArea = (wx1 - wx0) * (wy1 - wy0);
        if (windowArea <= 0) {
          continue;
        }
        const coverage: number = this.coverageInWindow(geometry, wx0, wy0, wx1, wy1, gridNm, work);
        if (!Number.isFinite(coverage) || coverage < 0 || coverage > windowArea + Math.max(1e-9, windowArea * 1e-9)) throw new Error('密度区域内核返回无效或重复覆盖面积');
        const density: number = (coverage / windowArea) * 100;
        if (density + 1e-6 < rule.value) {
          const ids = this.shapeIdsInWindow(shapes, wx0, wy0, wx1, wy1);
          violations.push({
            id: this.violationIdCounter++,
            ruleId: rule.id,
            ruleName: rule.name,
            type: rule.type,
            severity: rule.severity,
            layerNumber: rule.layerNumber,
            x: (wx0 + wx1) / 2,
            y: (wy0 + wy1) / 2,
            width: wx1 - wx0,
            height: wy1 - wy0,
            message: `并集密度 ${density.toFixed(4)}% < 规则要求 ${rule.value}%`,
            shapeIds: ids,
          });
          emitted++;
          if (emitted >= maxViolationsPerRule && (y + step < endY || x + step < endX)) {
            violations.push({
              id: this.violationIdCounter++, ruleId: DRC_NOTICE_EXEC,
              ruleName: `密度检查未完成：${rule.name}`, type: DrcRuleType.DENSITY,
              severity: DrcSeverity.WARNING, layerNumber: rule.layerNumber,
              x: 0, y: 0, width: 0, height: 0, shapeIds: [],
              message: `规则 ${rule.id} 已达到 ${maxViolationsPerRule} 个密度命中预算；剩余窗口未检查，结果不完整`,
            });
            return;
          }
        }
      }
    }
  }

  private boundsOfShapes(shapes: Shape[]): DrcBounds {
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const shape of shapes) {
      const b = getShapeBounds(shape);
      minX = Math.min(minX, b.minX);
      minY = Math.min(minY, b.minY);
      maxX = Math.max(maxX, b.maxX);
      maxY = Math.max(maxY, b.maxY);
    }
    const result: DrcBounds = {
      minX: minX,
      minY: minY,
      maxX: maxX,
      maxY: maxY,
    };
    return result;
  }

  private densityPolygonArea(polygon: number[]): number {
    let sum: number = 0; let correction: number = 0;
    for (let i: number = 0; i < polygon.length; i += 2) {
      const next: number = (i + 2) % polygon.length;
      const term: number = (polygon[i] - polygon[0]) * (polygon[next + 1] - polygon[1]) -
        (polygon[next] - polygon[0]) * (polygon[i + 1] - polygon[1]);
      const adjusted: number = term - correction; const value: number = sum + adjusted;
      correction = (value - sum) - adjusted; sum = value;
    }
    return Math.abs(sum) * 0.5;
  }

  private validateDensityRegion(polygons: number[][], gridNm: number): number {
    if (!Array.isArray(polygons) || polygons.length > 40000) throw new Error('密度区域未返回完整有界轮廓');
    let vertices: number = 0;
    for (const polygon of polygons) {
      if (!Array.isArray(polygon) || polygon.length < 6 || polygon.length % 2 !== 0) throw new Error('密度区域轮廓不完整');
      vertices += polygon.length / 2;
      if (vertices > 20000) throw new Error('密度区域超过 20000 个原生运算顶点预算');
      for (const coordinate of polygon) {
        const units: number = coordinate / gridNm;
        if (!Number.isFinite(units) || Math.abs(units) > 1e14 ||
          Math.abs(coordinate - Math.round(units) * gridNm) > Math.max(1e-10, Math.abs(coordinate) * Number.EPSILON * 4)) throw new Error('密度区域坐标无效或未在声明的 DBU 网格上');
      }
      const area: number = this.densityPolygonArea(polygon);
      if (!Number.isFinite(area) || area <= 0) throw new Error('密度区域含无效或零面积分片');
    }
    return vertices;
  }

  private densityGeometry(shapes: Shape[], gridNm: number): DensityGeometry {
    const rectangles: DensityRect[] = []; const polygons: number[][] = [];
    let rectangleOnly: boolean = true; let sourcePoints: number = 0; let approximation: string = '';
    for (const shape of shapes) {
      if (shape.type === ShapeType.TEXT || shape.type === ShapeType.NODE || shape.type === ShapeType.INSTANCE) continue;
      if (shape.points.some((point: Point): boolean => !Number.isFinite(point.x) || !Number.isFinite(point.y))) throw new Error('密度源图形含非有限坐标');
      sourcePoints += shape.points.length;
      if (sourcePoints > 20000) throw new Error('密度源图形超过 20000 个顶点预算');
      if (shape.type === ShapeType.RECT) {
        if (shape.points.length < 2) throw new Error('密度矩形缺少坐标');
        const b = getShapeBounds(shape);
        if (!(b.maxX > b.minX) || !(b.maxY > b.minY)) throw new Error('密度矩形缺少正面积');
        rectangles.push({ minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY });
        polygons.push([b.minX, b.minY, b.maxX, b.minY, b.maxX, b.maxY, b.minX, b.maxY]);
      } else if (shape.type === ShapeType.POLYGON) {
        rectangleOnly = false;
        const polygon: number[] = []; shape.points.forEach((point: Point): void => { polygon.push(point.x, point.y); });
        for (let i: number = 0; i < shape.points.length; i++) {
          const next: Point = shape.points[(i + 1) % shape.points.length];
          if (shape.points[i].x !== next.x && shape.points[i].y !== next.y) {
            approximation = '斜边相交可能产生 DBU 量化，尚无解析面积误差证明';
          }
        }
        polygons.push(polygon);
      } else if (shape.type === ShapeType.PATH) {
        rectangleOnly = false;
        const points: number[] = []; shape.points.forEach((point: Point): void => { points.push(point.x, point.y); });
        for (const value of points) {
          const units: number = value / gridNm;
          if (!Number.isFinite(units) || Math.abs(units) > 1e14 ||
            Math.abs(value - Math.round(units) * gridNm) > Math.max(1e-10, Math.abs(value) * Number.EPSILON * 4)) throw new Error('密度 PATH 中心线不在声明的 DBU 网格上');
        }
        const result = nativeHongTuService.pathRegionForEdit(points, shape.pathWidth ?? 0, shape.pathType ?? 0,
          shape.pathBeginExtension ?? 0, shape.pathEndExtension ?? 0, 1, shape.pathWidthAbsolute === true, gridNm);
        if (!result.success || result.polygons.length === 0) throw new Error(`密度 PATH 区域未完成：${result.errorMessage}`);
        this.validateDensityRegion(result.polygons, gridNm); polygons.push(...result.polygons);
        const halfWidth: number = (shape.pathWidth ?? 0) * 0.5;
        let axisAligned: boolean = true;
        for (let i: number = 1; i < shape.points.length; i++) {
          if (shape.points[i].x !== shape.points[i - 1].x && shape.points[i].y !== shape.points[i - 1].y) axisAligned = false;
        }
        const beginUnits: number = (shape.pathBeginExtension ?? 0) / gridNm;
        const endUnits: number = (shape.pathEndExtension ?? 0) / gridNm;
        if ((shape.pathType ?? 0) === 1 || !axisAligned || Math.abs(halfWidth / gridNm - Math.round(halfWidth / gridNm)) > 1e-6 ||
          ((shape.pathType ?? 0) === 4 && (Math.abs(beginUnits - Math.round(beginUnits)) > 1e-6 || Math.abs(endUnits - Math.round(endUnits)) > 1e-6))) {
          approximation = '圆端分段或斜边/半宽量化尚无精确面积误差证明';
        }
      } else throw new Error('密度源层含未知面积几何类型');
    }
    if (rectangleOnly) return { rectangles: rectangles, polygons: [], rectangleOnly: true, approximation: '' };
    this.validateDensityRegion(polygons, gridNm);
    const result = nativeHongTuService.regionBooleanForEdit(polygons, [], 1, gridNm);
    if (!result.success) throw new Error(`密度面积并集未完成：${result.errorMessage}`);
    this.validateDensityRegion(result.polygons, gridNm);
    return { rectangles: [], polygons: result.polygons, rectangleOnly: false, approximation: approximation };
  }

  private coverageInWindow(geometry: DensityGeometry, wx0: number, wy0: number, wx1: number, wy1: number,
    gridNm: number, work: DensityWork): number {
    if (!geometry.rectangleOnly) {
      const window: number[] = [wx0, wy0, wx1, wy0, wx1, wy1, wx0, wy1];
      this.validateDensityRegion([window], gridNm);
      work.examined += geometry.polygons.reduce((count: number, polygon: number[]): number => count + polygon.length / 2, 0) + 4;
      if (work.examined > 2000000) throw new Error('密度窗口区域计算超过 2000000 个顶点预算');
      const result = nativeHongTuService.regionBooleanForEdit(geometry.polygons, [window], 0, gridNm);
      if (!result.success) throw new Error(`密度窗口裁剪未完成：${result.errorMessage}`);
      this.validateDensityRegion(result.polygons, gridNm);
      let area: number = 0; let correction: number = 0;
      for (const polygon of result.polygons) {
        const adjusted: number = this.densityPolygonArea(polygon) - correction; const sum: number = area + adjusted;
        correction = (sum - area) - adjusted; area = sum;
      }
      return area;
    }
    // Exact axis-aligned rectangle union. Distinct IDs, opposite traversal or
    // partial overlaps do not alter material; no native library is necessary.
    const rectangles: DensityRect[] = []; const xs: number[] = [];
    work.examined += geometry.rectangles.length;
    if (work.examined > 2000000) throw new Error('密度矩形候选扫描超过 2000000 次预算');
    for (const r of geometry.rectangles) {
      const clipped: DensityRect = { minX: Math.max(wx0, r.minX), minY: Math.max(wy0, r.minY),
        maxX: Math.min(wx1, r.maxX), maxY: Math.min(wy1, r.maxY) };
      if (clipped.maxX > clipped.minX && clipped.maxY > clipped.minY) { rectangles.push(clipped); xs.push(clipped.minX, clipped.maxX); }
    }
    xs.sort((a: number, b: number): number => a - b);
    let coverage: number = 0; let correction: number = 0;
    for (let i: number = 1; i < xs.length; i++) {
      const x0: number = xs[i - 1]; const x1: number = xs[i]; if (x1 <= x0) continue;
      work.examined += rectangles.length;
      if (work.examined > 2000000) throw new Error('密度矩形并集超过 2000000 次预算');
      const intervals: DensityRect[] = rectangles.filter((r: DensityRect): boolean => r.minX < x1 && r.maxX > x0);
      intervals.sort((a: DensityRect, b: DensityRect): number => a.minY - b.minY);
      let start: number = 0; let end: number = 0; let height: number = 0; let has: boolean = false;
      for (const r of intervals) {
        if (!has) { start = r.minY; end = r.maxY; has = true; }
        else if (r.minY <= end) end = Math.max(end, r.maxY);
        else { height += end - start; start = r.minY; end = r.maxY; }
      }
      if (has) height += end - start;
      const adjusted: number = (x1 - x0) * height - correction; const sum: number = coverage + adjusted;
      correction = (sum - coverage) - adjusted; coverage = sum;
    }
    return coverage;
  }

  private shapeIdsInWindow(shapes: Shape[], wx0: number, wy0: number, wx1: number, wy1: number): number[] {
    const ids: number[] = [];
    for (const shape of shapes) {
      const b = getShapeBounds(shape);
      if (b.maxX >= wx0 && b.minX <= wx1 && b.maxY >= wy0 && b.minY <= wy1) {
        ids.push(shape.id);
      }
    }
    return ids;
  }

  /**
   * ArkTS 规则 → native 规则映射。
   * 不可映射（native 无对应检查或参数不完整）返回 null，由 ArkTS 路径补检。
   * native type 编码：0=MIN_WIDTH 1=MIN_SPACING 3=MIN_AREA 5=MIN_ENCLOSURE 8=MIN_DENSITY
   * Explicit datatype uses an exact flag, preserving native legacy wildcard defaults.
   */
  private toNativeRule(rule: DrcRule): NativeDrcRule | null {
    let nativeType: number = -1;
    let layer1: number = rule.layerNumber;
    let layer2: number = -1;
    let value2: number = 0;
    let datatype1: number = rule.datatype === undefined ? 0 : rule.datatype;
    let datatype2: number = 0;
    if (rule.type === DrcRuleType.MIN_WIDTH) {
      nativeType = 0;
    } else if (rule.type === DrcRuleType.MIN_SPACING) {
      nativeType = 1;
    } else if (rule.type === DrcRuleType.MIN_AREA) {
      nativeType = 3;
    } else if (rule.type === DrcRuleType.MIN_ENCLOSURE) {
      if (rule.targetLayerNumber === undefined || rule.targetLayerNumber < 0) {
        return null; // 未指明包围层，native 无「任意其他层」语义
      }
      nativeType = 5;
      layer1 = rule.targetLayerNumber; // native: layer1=包围层, layer2=被包围层
      layer2 = rule.layerNumber;
      datatype1 = rule.targetDatatype === undefined ? 0 : rule.targetDatatype;
      datatype2 = rule.datatype === undefined ? 0 : rule.datatype;
    } else if (rule.type === DrcRuleType.DENSITY) {
      nativeType = 8; // MIN_DENSITY：value 为最小覆盖率百分比
      value2 = Math.max(1000, rule.value * 20); // 窗口尺寸与 ArkTS 近似口径一致
    } else {
      return null;
    }
    const nr: NativeDrcRule = {
      id: rule.id,
      name: rule.name,
      type: nativeType,
      layer1: layer1,
      datatype1: datatype1,
      exactDatatype1: nativeType === 5 ? rule.targetDatatype !== undefined : rule.datatype !== undefined,
      layer2: layer2,
      datatype2: datatype2,
      exactDatatype2: nativeType === 5 && rule.datatype !== undefined,
      value: rule.value,
      value2: value2,
      enabled: true,
    };
    return nr;
  }

  /** native 违规 → ArkTS 违规（severity/type 从本地规则表回查） */
  private nativeViolationToDrc(nv: NativeDrcViolation, runRules?: DrcRule[]): DrcViolation {
    const rule = (runRules ?? this.rules).find((r: DrcRule) => r.id === nv.ruleId);
    const isNotice: boolean = isCompletenessNotice(nv.ruleId);
    const region: number = Math.max(100, nv.limit * 2);
    const shapeIds: number[] = [];
    if (nv.shapeId1 >= 0) {
      shapeIds.push(nv.shapeId1);
    }
    if (nv.shapeId2 >= 0) {
      shapeIds.push(nv.shapeId2);
    }
    return {
      id: this.violationIdCounter++,
      ruleId: nv.ruleId,
      ruleName: nv.ruleName,
      type: rule !== undefined ? rule.type : DrcRuleType.MIN_WIDTH,
      // 完整性告警（DRC.TRUNC）在 native 侧按 error 报，落到 UI 上降为 warning：
      // 它说明「结果可能被漏检」，不是某条规则的违例，不得让布局看起来「错 N 项」
      severity: isNotice ? DrcSeverity.WARNING
        : (rule !== undefined ? rule.severity : DrcSeverity.ERROR),
      layerNumber: rule !== undefined ? rule.layerNumber : nv.layer,
      x: nv.x,
      y: nv.y,
      width: region,
      height: region,
      message: nv.message,
      shapeIds: shapeIds,
      // 实例展开命中的违规：shapeIds 属子 Cell，UI 定位只能用 x/y
      fromInstance: nv.fromInstance === true,
    };
  }

  /** 计算两个图形之间的最小距离（v0.3: 优先使用原生引擎真实边到边距离） */
  private shapeDistance(a: Shape, b: Shape): number {
    const ba = getShapeBounds(a);
    const bb = getShapeBounds(b);

    // 快速 bbox 排斥：bbox 距离 > 阈值时直接返回（避免昂贵的精确计算）
    const bboxDx = Math.max(0, Math.max(bb.minX - ba.maxX, ba.minX - bb.maxX));
    const bboxDy = Math.max(0, Math.max(bb.minY - ba.maxY, ba.minY - bb.maxY));
    const bboxDist = Math.sqrt(bboxDx * bboxDx + bboxDy * bboxDy);

    // bbox 重叠 → 需要精确判断是否真正相交
    if (bboxDist === 0) {
      // 尝试原生精确距离
      const nativeDist = this.nativePolygonDistance(a, b);
      if (nativeDist >= 0) return nativeDist;
      return 0;  // 回退: bbox 重叠视为距离 0
    }

    // bbox 不重叠但接近时，用原生精确距离（bbox 距离只是下界）
    if (bboxDist < 500) {  // 500nm 阈值内做精确计算
      const nativeDist = this.nativePolygonDistance(a, b);
      if (nativeDist >= 0) return nativeDist;
    }

    return bboxDist;
  }

  /** 调用原生引擎计算真实多边形边到边距离 */
  private nativePolygonDistance(a: Shape, b: Shape): number {
    try {
      const ptsA = this.shapeToFlatPoints(a);
      const ptsB = this.shapeToFlatPoints(b);
      if (ptsA.length < 6 || ptsB.length < 6) return -1;  // 不够构成多边形
      const dist = nativeHongTuService.polygonDistance(ptsA, ptsB);
      return (dist !== Infinity && dist >= 0) ? dist : -1;
    } catch (_e) {
      return -1;  // 原生不可用时回退
    }
  }

  /** 将 Shape 的 points 转为扁平数组 [x0,y0,x1,y1,...] */
  private shapeToFlatPoints(s: Shape): number[] {
    const flat: number[] = [];
    if (s.points) {
      for (const p of s.points) {
        flat.push(p.x, p.y);
      }
    }
    return flat;
  }
}

/** DRC 服务单例 */
export const drcService = new DrcService();
