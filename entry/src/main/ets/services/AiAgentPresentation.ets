/**
 * 鸿图 AI Agent 原生呈现与流式解析引擎
 *
 * 融合开源 DeepSeek Harness 鸿蒙原生客户端（DSH-Harmony / dsh-harmony-mobile，MIT 许可）核心交互范式：
 * 1. 流式未闭合 Markdown 尾部无损修复（代码块围栏、行内代码、链接与半行 GFM 表格防抖）；
 * 2. GFM 管道表格独立分块解析与中日英混排自适应列宽计算，支持画布侧栏内原生横向滚动；
 * 3. 工具调用（query_editor / propose_editor_commands / execute_layout_python 等）流式半结构化 JSON 提取与版图语义徽标；
 * 4. 斜杠快捷命令（/explain、/check、/fix 等）、上下文 Token 计量条、会话 Markdown 导出与画布两期运行态 HUD 模型。
 *
 * This file is part of HongTu, licensed under GPLv3 (incorporating clean-room ArkTS adaptations compatible with MIT).
 */

import type { AiChatToolState, AiProcessStep, ChatMessage } from './AiService';

export class AiGfmTable {
  headers: string[] = [];
  aligns: string[] = [];
  rows: string[][] = [];
  columnWidths: number[] = [];
  totalWidth: number = 0;
}

export class AiMarkdownSegment {
  kind: 'markdown' | 'table' = 'markdown';
  text: string = '';
  table: AiGfmTable = new AiGfmTable();
}

export interface AiPlanStepView {
  id: string;
  content: string;
  status: string;
}

export interface AiToolField {
  label: string;
  value: string;
  accent: boolean;
}

export interface AiToolPresentation {
  title: string;
  inlineTarget: string;
  statusText: string;
  fields: AiToolField[];
  formattedArgs: string;
  formattedResult: string;
}

export interface AiExtractedThinking {
  thinking: string;
  answer: string;
  isStreamingThink: boolean;
}

export interface AiTokenMeterState {
  usedTokens: number;
  windowTokens: number;
  percent: number;
  thresholdPercent: number;
  nearThreshold: boolean;
  hasNumeric: boolean;
  badgeText: string;
}

export interface AiSlashCommandSpec {
  command: string;
  title: string;
  subtitle: string;
  kind: 'prompt' | 'template' | 'python' | 'compact' | 'new' | 'mode_agent' | 'mode_readonly';
  prompt: string;
}

export interface AgentCanvasHudModel {
  phase: 'drawing' | 'waiting' | 'preview' | 'completed' | 'hidden';
  badge: string;
  title: string;
  detail: string;
  stepText: string;
  elapsedText: string;
}

export const AI_SLASH_COMMANDS: AiSlashCommandSpec[] = [
  {
    command: '/explain',
    title: '解释当前图形',
    subtitle: '读取选中图形坐标、尺寸、图层与结构用途',
    kind: 'prompt',
    prompt: '解释当前选中的图形及其用途'
  },
  {
    command: '/check',
    title: '检查版图与规则',
    subtitle: '盘点图层、Cell 层级与当前 DRC 状态',
    kind: 'prompt',
    prompt: '检查当前版图并说明需要关注的问题'
  },
  {
    command: '/locate',
    title: '定位首个 DRC 问题',
    subtitle: '选中并聚焦第一个违规关联图形，不改几何',
    kind: 'prompt',
    prompt: '根据当前 DRC 具体问题，选中并定位第一个问题涉及的图形，不修改几何。'
  },
  {
    command: '/fix',
    title: '提出最小修复预览',
    subtitle: '生成画布虚线预览与可撤销修改方案，确认后生效',
    kind: 'prompt',
    prompt: '根据当前选区与 DRC 证据，提出最小修复方案供我预览确认，并在修改后复检；资料不足时先说明，不猜测工艺规则。'
  },
  {
    command: '/inverter',
    title: '生成 CMOS 反相器',
    subtitle: '在隔离脚本沙箱生成标准反相器单元并校验',
    kind: 'prompt',
    prompt: '画一个反相器'
  },
  {
    command: '/array',
    title: '阵列参数模板',
    subtitle: '展开或收起选区行列间距快速参数面板',
    kind: 'template',
    prompt: ''
  },
  {
    command: '/screenshot',
    title: '自主截图视觉自检',
    subtitle: '让 Agent 截取当前画布或软件窗口并汇报视觉巡检结论',
    kind: 'prompt',
    prompt: '请调用 capture_screenshot 截取当前画布视口，查看当前版图绘制情况、图层可见性与布局结构并向我汇报。'
  },
  {
    command: '/search',
    title: '联网检索技术资料',
    subtitle: '实时调用 web_search 查询工艺设计规则、论文或开发文档',
    kind: 'prompt',
    prompt: '请使用 web_search 联网检索：'
  },
  {
    command: '/python',
    title: '打开端侧 Python 3 工作台',
    subtitle: '免伴随服务离线运行 KLayout / HongTu 参数化脚本与扫参',
    kind: 'python',
    prompt: ''
  },
  {
    command: '/ask',
    title: '切换为只读问答模式',
    subtitle: '锁定当前会话仅作分析说明，禁止生成修改方案',
    kind: 'mode_readonly',
    prompt: ''
  },
  {
    command: '/agent',
    title: '切换为 Agent 编辑模式',
    subtitle: '允许提出待确认版图修改方案或隔离生成新文档',
    kind: 'mode_agent',
    prompt: ''
  },
  {
    command: '/compact',
    title: '压缩早期会话上下文',
    subtitle: '保留最近两轮原文并总结早期记录，释放窗口容量',
    kind: 'compact',
    prompt: ''
  },
  {
    command: '/new',
    title: '新建独立会话',
    subtitle: '创建干净上下文的新对话线程',
    kind: 'new',
    prompt: ''
  }
];

export function matchAiSlashCommands(rawInput: string): AiSlashCommandSpec[] {
  const trimmed: string = rawInput.trimStart();
  if (!trimmed.startsWith('/')) {
    return [];
  }
  const spaceIdx: number = trimmed.indexOf(' ');
  if (spaceIdx >= 0) {
    return [];
  }
  const token: string = trimmed.toLowerCase();
  if (token === '/') {
    return AI_SLASH_COMMANDS.slice();
  }
  return AI_SLASH_COMMANDS.filter((item: AiSlashCommandSpec): boolean =>
    item.command.startsWith(token) || item.title.toLowerCase().includes(token.substring(1))
  );
}

function parsePipeCells(line: string): string[] | null {
  let source: string = line.trim();
  if (source.length === 0 || source.indexOf('|') < 0) {
    return null;
  }
  if (source.startsWith('|')) {
    source = source.substring(1);
  }
  if (source.endsWith('|') && !source.endsWith('\\|')) {
    source = source.substring(0, source.length - 1);
  }
  const result: string[] = [];
  let current: string = '';
  let escaped: boolean = false;
  let inCodeTick: boolean = false;
  for (let i: number = 0; i < source.length; i++) {
    const ch: string = source.charAt(i);
    if (escaped) {
      current += ch === '|' ? '|' : `\\${ch}`;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      escaped = true;
      continue;
    }
    if (ch === '`') {
      inCodeTick = !inCodeTick;
      current += ch;
      continue;
    }
    if (ch === '|' && !inCodeTick) {
      result.push(current.trim());
      current = '';
      continue;
    }
    current += ch;
  }
  if (escaped) {
    current += '\\';
  }
  result.push(current.trim());
  return result.length >= 2 ? result : null;
}

function parseDelimiterAlign(cell: string): string {
  const trimmed: string = cell.trim();
  if (!/^:?-+:?$/.test(trimmed)) {
    return '';
  }
  if (trimmed.startsWith(':') && trimmed.endsWith(':')) {
    return 'center';
  }
  if (trimmed.endsWith(':')) {
    return 'right';
  }
  return 'left';
}

export function stripInlineMarkdownDecorators(cellText: string): string {
  return cellText
    .replace(/`([^`]+)`/g, '$1')
    .replace(/\*\*([^*]+)\*\*/g, '$1')
    .replace(/\*([^*]+)\*/g, '$1')
    .replace(/~~([^~]+)~~/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .trim();
}

export function computeTableColumnWidths(headers: string[], rows: string[][]): number[] {
  const colCount: number = headers.length;
  const widths: number[] = [];
  for (let col: number = 0; col < colCount; col++) {
    let desired: number = 88;
    const candidates: string[] = [headers[col] ?? ''];
    for (let r: number = 0; r < rows.length; r++) {
      candidates.push(rows[r][col] ?? '');
    }
    for (let c: number = 0; c < candidates.length; c++) {
      const clean: string = stripInlineMarkdownDecorators(candidates[c]);
      let visualPx: number = 0;
      for (let k: number = 0; k < clean.length; k++) {
        visualPx += clean.charCodeAt(k) > 255 ? 14 : 7.6;
      }
      desired = Math.max(desired, Math.ceil(visualPx + 26));
    }
    widths.push(Math.min(280, Math.max(88, desired)));
  }
  return widths;
}

export function formatGfmTableTsv(table: AiGfmTable): string {
  const lines: string[] = [table.headers.map((h: string): string => stripInlineMarkdownDecorators(h)).join('\t')];
  for (let r: number = 0; r < table.rows.length; r++) {
    lines.push(table.rows[r].map((c: string): string => stripInlineMarkdownDecorators(c)).join('\t'));
  }
  return lines.join('\n');
}

/**
 * 在流式生成期间仅修复末尾未闭合的代码围栏、行内反引号、未完成链接或半行表格分隔符，
 * 不改动持久化消息原文，消除流式刷新时的闪烁与乱码。
 */
export function repairStreamingMarkdown(text: string): string {
  if (!text || text.length === 0) {
    return '';
  }
  const normalized: string = text.replace(/\r\n?/g, '\n');
  const lines: string[] = normalized.split('\n');
  let fenceChar: string = '';
  let fenceLen: number = 0;
  for (let i: number = 0; i < lines.length; i++) {
    const trimmed: string = lines[i].trim();
    if (fenceChar.length > 0) {
      const closeMatch: RegExpExecArray | null = /^(`{3,}|~{3,})\s*$/.exec(trimmed);
      if (closeMatch !== null && closeMatch[1].charAt(0) === fenceChar && closeMatch[1].length >= fenceLen) {
        fenceChar = '';
        fenceLen = 0;
      }
    } else {
      const openMatch: RegExpExecArray | null = /^(`{3,}|~{3,})/.exec(trimmed);
      if (openMatch !== null) {
        fenceChar = openMatch[1].charAt(0);
        fenceLen = openMatch[1].length;
      }
    }
  }
  if (fenceChar.length > 0) {
    return `${normalized}\n${fenceChar.repeat(fenceLen)}`;
  }

  // 若末尾正在流式输出表格第一行或未写完分隔行，暂缓将该半截行当成残缺管道渲染
  if (lines.length >= 1) {
    const last: string = lines[lines.length - 1].trim();
    const prev: string = lines.length >= 2 ? lines[lines.length - 2].trim() : '';
    if (prev.startsWith('|') && /^\|[\s:\-|]*$/.test(last) && parsePipeCells(last) === null) {
      return lines.slice(0, lines.length - 1).join('\n');
    }
  }

  let output: string = normalized;
  const lastNewline: number = output.lastIndexOf('\n');
  const tailLine: string = output.substring(lastNewline + 1);
  const openLinkIdx: number = tailLine.lastIndexOf('](');
  if (openLinkIdx >= 0 && tailLine.indexOf(')', openLinkIdx + 2) < 0) {
    output = output.substring(0, lastNewline + 1 + openLinkIdx + 1);
  }
  let tickCount: number = 0;
  for (let i: number = 0; i < output.length; i++) {
    if (output.charAt(i) === '`') {
      tickCount++;
    }
  }
  if (tickCount % 2 === 1) {
    output += '`';
  }
  return output;
}

/**
 * 将 Markdown 拆分为常规段落块与原生可横滑 GFM 表格块（自动跳过代码围栏内部内容）。
 */
export function splitMarkdownSegments(rawText: string): AiMarkdownSegment[] {
  const normalized: string = (rawText || '').replace(/\r\n?/g, '\n');
  if (normalized.indexOf('|') < 0 || normalized.indexOf('\n') < 0) {
    const single: AiMarkdownSegment = new AiMarkdownSegment();
    single.kind = 'markdown';
    single.text = normalized;
    return [single];
  }

  const lines: string[] = normalized.split('\n');
  const segments: AiMarkdownSegment[] = [];
  let mdBuffer: string[] = [];
  let fenceChar: string = '';
  let fenceLen: number = 0;

  const flushMarkdown = (): void => {
    if (mdBuffer.length === 0) {
      return;
    }
    const joined: string = mdBuffer.join('\n');
    mdBuffer = [];
    if (joined.trim().length === 0) {
      return;
    }
    const seg: AiMarkdownSegment = new AiMarkdownSegment();
    seg.kind = 'markdown';
    seg.text = joined;
    segments.push(seg);
  };

  let index: number = 0;
  while (index < lines.length) {
    const line: string = lines[index];
    const trimmed: string = line.trim();
    if (fenceChar.length > 0) {
      mdBuffer.push(line);
      const closeMatch: RegExpExecArray | null = /^(`{3,}|~{3,})\s*$/.exec(trimmed);
      if (closeMatch !== null && closeMatch[1].charAt(0) === fenceChar && closeMatch[1].length >= fenceLen) {
        fenceChar = '';
        fenceLen = 0;
      }
      index++;
      continue;
    }
    const openMatch: RegExpExecArray | null = /^(`{3,}|~{3,})/.exec(trimmed);
    if (openMatch !== null) {
      fenceChar = openMatch[1].charAt(0);
      fenceLen = openMatch[1].length;
      mdBuffer.push(line);
      index++;
      continue;
    }

    if (index + 1 < lines.length && line.indexOf('|') >= 0 && lines[index + 1].indexOf('|') >= 0) {
      const headers: string[] | null = parsePipeCells(line);
      const delimiters: string[] | null = parsePipeCells(lines[index + 1]);
      if (headers !== null && delimiters !== null && delimiters.length === headers.length) {
        const aligns: string[] = delimiters.map((d: string): string => parseDelimiterAlign(d));
        if (aligns.every((a: string): boolean => a.length > 0)) {
          flushMarkdown();
          const colCount: number = aligns.length;
          const table: AiGfmTable = new AiGfmTable();
          table.headers = headers.slice(0, colCount);
          table.aligns = aligns;
          let cursor: number = index + 2;
          while (cursor < lines.length) {
            const rowLine: string = lines[cursor];
            if (rowLine.trim().length === 0 || /^(`{3,}|~{3,})/.test(rowLine.trim())) {
              break;
            }
            const rowCells: string[] | null = parsePipeCells(rowLine);
            if (rowCells === null) {
              break;
            }
            const normalizedRow: string[] = rowCells.slice(0, colCount);
            while (normalizedRow.length < colCount) {
              normalizedRow.push('');
            }
            table.rows.push(normalizedRow);
            cursor++;
          }
          table.columnWidths = computeTableColumnWidths(table.headers, table.rows);
          table.totalWidth = table.columnWidths.reduce((acc: number, w: number): number => acc + w, 0);
          const tableSeg: AiMarkdownSegment = new AiMarkdownSegment();
          tableSeg.kind = 'table';
          tableSeg.table = table;
          segments.push(tableSeg);
          index = cursor;
          continue;
        }
      }
    }

    mdBuffer.push(line);
    index++;
  }

  flushMarkdown();
  if (segments.length === 0) {
    const emptySeg: AiMarkdownSegment = new AiMarkdownSegment();
    emptySeg.kind = 'markdown';
    emptySeg.text = normalized;
    return [emptySeg];
  }
  return segments;
}

export function parseGfmTableBlock(text: string): AiGfmTable | null {
  const segments: AiMarkdownSegment[] = splitMarkdownSegments(text);
  return segments.length === 1 && segments[0].kind === 'table' ? segments[0].table : null;
}

function asRecord(raw: string): Record<string, Object> | null {
  const trimmed: string = (raw || '').trim();
  if (!trimmed.startsWith('{')) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(trimmed) as Object;
    if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
      return parsed as Record<string, Object>;
    }
  } catch (_) {}
  return null;
}

function extractPartialString(source: string, key: string): string {
  if (!source) {
    return '';
  }
  const regex: RegExp = new RegExp(`"${key}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)"`);
  const match: RegExpExecArray | null = regex.exec(source);
  if (match === null) {
    return '';
  }
  try {
    return JSON.parse(`"${match[1]}"`) as string;
  } catch (_) {
    return match[1];
  }
}

function extractPartialNumber(source: string, key: string): number | undefined {
  if (!source) {
    return undefined;
  }
  const regex: RegExp = new RegExp(`"${key}"\\s*:\\s*(-?\\d+(?:\\.\\d+)?)`);
  const match: RegExpExecArray | null = regex.exec(source);
  if (match === null) {
    return undefined;
  }
  const n: number = Number(match[1]);
  return Number.isFinite(n) ? n : undefined;
}

function recordStr(rec: Record<string, Object> | null, raw: string, key: string): string {
  if (rec !== null && typeof rec[key] === 'string') {
    return (rec[key] as string).trim();
  }
  return extractPartialString(raw, key).trim();
}

function recordNum(rec: Record<string, Object> | null, raw: string, key: string): number | undefined {
  if (rec !== null && typeof rec[key] === 'number' && Number.isFinite(rec[key] as number)) {
    return rec[key] as number;
  }
  return extractPartialNumber(raw, key);
}

function recordBool(rec: Record<string, Object> | null, raw: string, key: string): boolean | undefined {
  if (rec !== null && typeof rec[key] === 'boolean') {
    return rec[key] as boolean;
  }
  const match: RegExpExecArray | null = new RegExp(`"${key}"\\s*:\\s*(true|false)`).exec(raw);
  if (match === null) {
    return undefined;
  }
  return match[1] === 'true';
}

export function mapAiToolDisplayTitle(name: string): string {
  switch (name) {
    case 'inspect_layout': return '读取当前版图';
    case 'inspect_workbench_ui': return '读取工作台界面状态';
    case 'capture_screenshot': return '自主截图视觉巡检';
    case 'automate_workbench_ui': return '自动化操控软件界面';
    case 'query_layout':
    case 'query_editor': return '查询版图明细';
    case 'list_native_tools': return '查询软件工具目录';
    case 'read_native_tool': return '读取原生工具数据';
    case 'call_native_tool': return '执行原生专业工具';
    case 'edit_layout': return '编辑当前版图几何';
    case 'run_drc': return '运行 DRC 规则检查';
    case 'propose_native_tools': return '提交原生工具方案';
    case 'prepare_native_workflow': return '准备专业编辑流程';
    case 'check_tool_protocol': return '诊断工具调用协议';
    case 'create_cmos_inverter': return '生成 CMOS 反相器';
    case 'execute_klayout_python':
    case 'execute_layout_python': return '运行参数化版图脚本';
    case 'propose_editor_commands': return '准备版图修改方案';
    case 'read_plan': return '读取执行计划';
    case 'todo_write':
    case 'write_plan': return '制定执行计划';
    case 'update_plan': return '更新执行计划';
    case 'update_task_status':
    case 'update_task_statuses': return '更新计划步骤';
    case 'ask_user': return '向您确认细节';
    case 'web_search': return '联网搜索资料';
    case 'web_fetch': return '读取网页正文';
    case 'manage_layers': return '管理版图图层';
    case 'manage_cells': return '管理单元与层级';
    case 'manage_ports_and_routing': return '端口与自动布线';
    case 'manage_verification': return '物理验证与网表';
    case 'manage_workbench': return '工作台与视图控制';
    case 'manage_attachments_and_files': return '附件与文件导出';
    default: return name;
  }
}

function queryKindLabel(kind: string): string {
  switch (kind) {
    case 'shapes': return '图形列表';
    case 'cells': return 'Cell 层级';
    case 'layers': return '图层清单';
    case 'drc': return 'DRC 违规';
    case 'rules': return '设计规则';
    case 'ports': return '端口列表';
    case 'native_tools': return '原生工具目录';
    case 'native_read': return '原生只读状态';
    default: return kind;
  }
}

function prettyJsonIfPossible(raw: string): string {
  const trimmed: string = (raw || '').trim();
  if (trimmed.length === 0) {
    return '';
  }
  try {
    return JSON.stringify(JSON.parse(trimmed), null, 2);
  } catch (_) {
    return trimmed;
  }
}

/**
 * 将单次工具调用解析为 DSH-Harmony 风格的内联目标徽标与结构化字段列表，
 * 让连续多次 `query_editor` 或编辑建议在折叠态即可一眼区分查询目标。
 */
export function describeAiToolCall(tool: AiChatToolState, isLiveRunning: boolean = false): AiToolPresentation {
  const title: string = mapAiToolDisplayTitle(tool.name);
  const argsRec: Record<string, Object> | null = asRecord(tool.arguments);
  const resRec: Record<string, Object> | null = asRecord(tool.result);
  const fields: AiToolField[] = [];
  const summaryParts: string[] = [];

  if (tool.name === 'query_editor' || tool.name === 'query_layout') {
    const kind: string = recordStr(argsRec, tool.arguments, 'kind') || recordStr(resRec, tool.result, 'source');
    const layer: number | undefined = recordNum(argsRec, tool.arguments, 'layer');
    const datatype: number | undefined = recordNum(argsRec, tool.arguments, 'datatype');
    const selectedOnly: boolean | undefined = recordBool(argsRec, tool.arguments, 'selectedOnly');
    const cellId: number | undefined = recordNum(argsRec, tool.arguments, 'cellId');
    const subTool: string = recordStr(argsRec, tool.arguments, 'toolName');
    const total: number | undefined = recordNum(resRec, tool.result, 'total');
    const truncated: boolean | undefined = recordBool(resRec, tool.result, 'truncated');

    if (kind.length > 0) {
      const label: string = queryKindLabel(kind);
      summaryParts.push(label);
      fields.push({ label: '查询数据源', value: `${label} (${kind})`, accent: false });
    }
    if (subTool.length > 0) {
      summaryParts.push(subTool);
      fields.push({ label: '原生工具', value: subTool, accent: true });
    }
    if (layer !== undefined) {
      const lTag: string = `L${layer}/${datatype ?? 0}`;
      summaryParts.push(lTag);
      fields.push({ label: '图层过滤', value: lTag, accent: true });
    }
    if (selectedOnly === true) {
      summaryParts.push('仅选区');
      fields.push({ label: '范围过滤', value: '仅当前选中图形', accent: true });
    }
    if (cellId !== undefined) {
      fields.push({ label: '目标 Cell', value: `#${cellId}`, accent: false });
    }
    if (total !== undefined) {
      summaryParts.push(`${total} 项`);
      fields.push({
        label: '返回记录',
        value: `${total} 项${truncated === true ? '（已分页截断）' : ''}`,
        accent: total > 0
      });
    }
  } else if (tool.name === 'inspect_workbench_ui') {
    const mod: string = recordStr(resRec, tool.result, 'currentModule');
    const modeStr: string = recordStr(resRec, tool.result, 'viewMode');
    const zoomNum: number | undefined = recordNum(resRec, tool.result, 'zoomPercent');
    if (mod.length > 0) {
      summaryParts.push(mod);
      fields.push({ label: '当前模块', value: `${mod} (${modeStr || 'edit'})`, accent: false });
    }
    if (zoomNum !== undefined) {
      summaryParts.push(`${Math.round(zoomNum)}%`);
      fields.push({ label: '视口缩放', value: `${zoomNum}%`, accent: true });
    }
  } else if (tool.name === 'capture_screenshot') {
    const target: string = recordStr(argsRec, tool.arguments, 'target') || recordStr(resRec, tool.result, 'target') || 'canvas_viewport';
    const wPx: number | undefined = recordNum(resRec, tool.result, 'width');
    const hPx: number | undefined = recordNum(resRec, tool.result, 'height');
    const targetLabel: string = target === 'workbench_window' ? '软件整窗' : (target === 'layout_render' ? '版图光栅化' : '画布视口');
    summaryParts.push(targetLabel);
    fields.push({ label: '截图范围', value: targetLabel, accent: true });
    if (wPx !== undefined && hPx !== undefined && wPx > 0 && hPx > 0) {
      summaryParts.push(`${wPx}×${hPx}`);
      fields.push({ label: '图像尺寸', value: `${wPx} × ${hPx} px (已注入视觉上下文)`, accent: true });
    }
  } else if (tool.name === 'automate_workbench_ui') {
    const stepArrCount: number = argsRec !== null && Array.isArray(argsRec['steps']) ? (argsRec['steps'] as Object[]).length : 0;
    const summaryStr: string = recordStr(resRec, tool.result, 'summary');
    if (stepArrCount > 0) {
      summaryParts.push(`${stepArrCount} 步界面动作`);
      fields.push({ label: '自动化步骤', value: `${stepArrCount} 项 UI 操作`, accent: true });
    }
    if (summaryStr.length > 0) {
      fields.push({ label: '执行回执', value: summaryStr, accent: false });
    }
  } else if (tool.name === 'inspect_layout') {
    const cellObj: Object | undefined = resRec !== null ? resRec['currentCell'] : undefined;
    const cellRec: Record<string, Object> | null = (cellObj !== undefined && cellObj !== null && typeof cellObj === 'object' && !Array.isArray(cellObj))
      ? (cellObj as Record<string, Object>) : null;
    const cellName: string = cellRec !== null && typeof cellRec['name'] === 'string' ? (cellRec['name'] as string) : '';
    const shapeCount: number | undefined = recordNum(resRec, tool.result, 'shapeCount');
    if (cellName.length > 0) {
      summaryParts.push(`Cell ${cellName}`);
      fields.push({ label: '当前单元', value: cellName, accent: false });
    }
    if (shapeCount !== undefined) {
      summaryParts.push(`${shapeCount} 个图形`);
      fields.push({ label: '图形总数', value: `${shapeCount}`, accent: true });
    }
  } else if (tool.name === 'propose_editor_commands') {
    let cmdCount: number = 0;
    let firstDesc: string = '';
    if (argsRec !== null && Array.isArray(argsRec['commands'])) {
      const arr: Object[] = argsRec['commands'] as Object[];
      cmdCount = arr.length;
      if (arr.length > 0 && arr[0] !== null && typeof arr[0] === 'object' && !Array.isArray(arr[0])) {
        const first: Record<string, Object> = arr[0] as Record<string, Object>;
        const t: string = typeof first['type'] === 'string' ? (first['type'] as string) : '';
        const d: string = typeof first['description'] === 'string' ? (first['description'] as string) : '';
        firstDesc = d.length > 0 ? d : t;
      }
    }
    if (cmdCount > 0) {
      summaryParts.push(`${cmdCount} 项待确认`);
      fields.push({ label: '操作数量', value: `${cmdCount} 项（预览待确认）`, accent: true });
    }
    if (firstDesc.length > 0) {
      const compactDesc: string = firstDesc.length > 26 ? `${firstDesc.substring(0, 25)}…` : firstDesc;
      summaryParts.push(compactDesc);
      fields.push({ label: '首项变更', value: firstDesc, accent: true });
    }
  } else if (tool.name === 'propose_native_tools' || tool.name === 'read_native_tool' || tool.name === 'list_native_tools') {
    const toolName: string = recordStr(argsRec, tool.arguments, 'toolName') || recordStr(argsRec, tool.arguments, 'category');
    if (toolName.length > 0) {
      summaryParts.push(toolName);
      fields.push({ label: '目标工具', value: toolName, accent: true });
    }
    if (argsRec !== null && Array.isArray(argsRec['calls'])) {
      const calls: Object[] = argsRec['calls'] as Object[];
      summaryParts.push(`${calls.length} 项调用`);
      fields.push({ label: '批量调用', value: `${calls.length} 项原生操作`, accent: true });
    }
  } else if (tool.name === 'create_cmos_inverter') {
    const cName: string = recordStr(argsRec, tool.arguments, 'cellName') || recordStr(resRec, tool.result, 'cellName') || 'INVERTER';
    const gl: number | undefined = recordNum(argsRec, tool.arguments, 'gateLengthNm');
    const nw: number | undefined = recordNum(argsRec, tool.arguments, 'nmosWidthNm');
    const pw: number | undefined = recordNum(argsRec, tool.arguments, 'pmosWidthNm');
    const added: number | undefined = recordNum(resRec, tool.result, 'addedShapes');
    const drcStr: string = recordStr(resRec, tool.result, 'drcSummary');
    summaryParts.push(cName);
    if (gl !== undefined) summaryParts.push(`L=${gl}nm`);
    if (added !== undefined && added > 0) summaryParts.push(`+${added} 图元`);
    fields.push({ label: '目标单元', value: cName, accent: true });
    if (gl !== undefined || nw !== undefined || pw !== undefined) {
      fields.push({ label: '器件尺寸', value: `Lg=${gl ?? 200}nm, Wn=${nw ?? 600}nm, Wp=${pw ?? 1200}nm`, accent: false });
    }
    if (drcStr.length > 0) {
      fields.push({ label: 'DRC 复检', value: drcStr, accent: true });
    }
  } else if (tool.name === 'edit_layout') {
    const opCount: number = argsRec !== null && Array.isArray(argsRec['operations']) ? (argsRec['operations'] as Object[]).length : 0;
    const added: number | undefined = recordNum(resRec, tool.result, 'addedShapes');
    const summaryStr: string = recordStr(resRec, tool.result, 'summary');
    if (opCount > 0) {
      summaryParts.push(`${opCount} 项几何操作`);
      fields.push({ label: '批次规模', value: `${opCount} 项原子操作`, accent: true });
    }
    if (added !== undefined && added > 0) {
      fields.push({ label: '变更图元', value: `${added} 个图形`, accent: true });
    }
    if (summaryStr.length > 0) {
      fields.push({ label: '执行结果', value: summaryStr, accent: false });
    }
  } else if (tool.name === 'run_drc') {
    const drcSummary: string = recordStr(resRec, tool.result, 'summary') || recordStr(resRec, tool.result, 'drcSummary');
    if (drcSummary.length > 0) {
      summaryParts.push(drcSummary.length > 28 ? `${drcSummary.substring(0, 27)}…` : drcSummary);
      fields.push({ label: '检查结论', value: drcSummary, accent: true });
    }
  } else if (tool.name === 'ask_user') {
    const q: string = recordStr(argsRec, tool.arguments, 'question');
    const ans: string = recordStr(resRec, tool.result, 'answerSummary');
    if (q.length > 0) {
      summaryParts.push(q.length > 24 ? `${q.substring(0, 23)}…` : q);
      fields.push({ label: '提问内容', value: q, accent: true });
    }
    if (ans.length > 0) {
      fields.push({ label: '用户答复', value: ans, accent: true });
    }
  } else if (tool.name === 'web_search') {
    const q: string = recordStr(argsRec, tool.arguments, 'query');
    const count: number | undefined = recordNum(resRec, tool.result, 'count');
    if (q.length > 0) {
      summaryParts.push(q.length > 24 ? `${q.substring(0, 23)}…` : q);
      fields.push({ label: '检索关键词', value: q, accent: true });
    }
    if (count !== undefined) {
      summaryParts.push(`${count} 条结果`);
      fields.push({ label: '命中来源', value: `${count} 条网页摘要`, accent: count > 0 });
    }
  } else if (tool.name === 'web_fetch') {
    const targetUrl: string = recordStr(argsRec, tool.arguments, 'url');
    const pageTitle: string = recordStr(resRec, tool.result, 'title');
    if (pageTitle.length > 0) {
      summaryParts.push(pageTitle.length > 24 ? `${pageTitle.substring(0, 23)}…` : pageTitle);
      fields.push({ label: '网页标题', value: pageTitle, accent: true });
    } else if (targetUrl.length > 0) {
      summaryParts.push(targetUrl.length > 28 ? `${targetUrl.substring(0, 27)}…` : targetUrl);
    }
    if (targetUrl.length > 0) {
      fields.push({ label: '网页地址', value: targetUrl, accent: false });
    }
  } else if (tool.name === 'manage_layers' || tool.name === 'manage_cells' || tool.name === 'manage_ports_and_routing' ||
    tool.name === 'manage_verification' || tool.name === 'manage_workbench' || tool.name === 'manage_attachments_and_files') {
    const action: string = recordStr(argsRec, tool.arguments, 'action');
    const layerNum: number | undefined = recordNum(argsRec, tool.arguments, 'layer');
    const dtNum: number | undefined = recordNum(argsRec, tool.arguments, 'datatype');
    const cName: string = recordStr(argsRec, tool.arguments, 'name') || recordStr(argsRec, tool.arguments, 'cellName') || recordStr(argsRec, tool.arguments, 'fileName');
    const summaryStr: string = recordStr(resRec, tool.result, 'summary') || recordStr(resRec, tool.result, 'message');
    if (action.length > 0) {
      summaryParts.push(action);
      fields.push({ label: '执行动作', value: action, accent: true });
    }
    if (layerNum !== undefined) {
      const lStr: string = `L${layerNum}/${dtNum ?? 0}`;
      summaryParts.push(lStr);
      fields.push({ label: '目标图层', value: lStr, accent: true });
    }
    if (cName.length > 0) {
      summaryParts.push(cName);
      fields.push({ label: '目标对象', value: cName, accent: false });
    }
    if (summaryStr.length > 0) {
      fields.push({ label: '执行结果', value: summaryStr, accent: false });
    }  } else if (tool.name === 'call_native_tool') {
    const subName: string = recordStr(argsRec, tool.arguments, 'name');
    const resMsg: string = recordStr(resRec, tool.result, 'message') || recordStr(resRec, tool.result, 'summary');
    if (subName.length > 0) {
      summaryParts.push(subName);
      fields.push({ label: '调用工具', value: subName, accent: true });
    }
    if (resMsg.length > 0) {
      fields.push({ label: '执行回执', value: resMsg, accent: false });
    }
  } else if (tool.name === 'execute_layout_python' || tool.name === 'execute_klayout_python') {
    const script: string = recordStr(argsRec, tool.arguments, 'script');
    if (script.length > 0) {
      const lineCount: number = script.split('\n').length;
      summaryParts.push(`${lineCount} 行脚本`);
      fields.push({ label: '脚本规模', value: `${lineCount} 行 Python / KLayout DB`, accent: false });
    }
    const artifactName: string = recordStr(resRec, tool.result, 'name') || recordStr(resRec, tool.result, 'summary');
    if (artifactName.length > 0) {
      const shortArt: string = artifactName.length > 24 ? `${artifactName.substring(0, 23)}…` : artifactName;
      summaryParts.push(shortArt);
      fields.push({ label: '生成产物', value: artifactName, accent: true });
    }
  } else if (tool.name === 'prepare_native_workflow') {
    const wf: string = recordStr(argsRec, tool.arguments, 'workflow') || recordStr(resRec, tool.result, 'workflow');
    if (wf.length > 0) {
      summaryParts.push(wf);
      fields.push({ label: '工作流', value: wf, accent: true });
    }
  } else if (tool.name === 'todo_write' || tool.name === 'write_plan' || tool.name === 'read_plan' || tool.name === 'update_task_status') {
    const planSteps: AiPlanStepView[] = extractAiPlan([tool]);
    if (planSteps.length > 0) {
      summaryParts.push(`${planSteps.length} 步计划`);
      fields.push({ label: '计划步骤', value: `${planSteps.length} 步`, accent: false });
    } else {
      const planStepMatch: RegExpExecArray | null = /Plan updated:\s*(\d+)\s*step/i.exec(tool.result);
      if (planStepMatch !== null) {
        summaryParts.push(`${planStepMatch[1]} 步`);
        fields.push({ label: '计划步骤', value: `${planStepMatch[1]} 步`, accent: false });
      }
    }
  } else if (tool.result.length > 0 && tool.result.length <= 96 && !tool.result.includes('{')) {
    summaryParts.push(tool.result.trim());
  }

  const errStr: string = recordStr(resRec, tool.result, 'error');
  if (errStr.length > 0) {
    fields.push({ label: '返回提示', value: errStr, accent: true });
  }

  const statusText: string = tool.status === 'failed'
    ? '失败'
    : (tool.status === 'running' ? (isLiveRunning ? '运行中' : '未完成') : '已完成');

  return {
    title,
    inlineTarget: summaryParts.join(' · '),
    statusText,
    fields,
    formattedArgs: prettyJsonIfPossible(tool.arguments),
    formattedResult: prettyJsonIfPossible(tool.result)
  };
}

export function extractAiPlan(tools: AiChatToolState[]): AiPlanStepView[] {
  let latest: AiPlanStepView[] = [];
  for (let i = 0; i < tools.length; i++) {
    const tool: AiChatToolState = tools[i];
    if (tool.name === 'todo_write' || tool.name === 'write_plan' || tool.name === 'update_plan') {
      const argsRec: Record<string, Object> | null = asRecord(tool.arguments);
      const resRec: Record<string, Object> | null = asRecord(tool.result);
      const rawList: Object | undefined =
        (argsRec !== null ? (argsRec['todos'] ?? argsRec['steps']) : undefined) ??
        (resRec !== null ? (resRec['todos'] ?? resRec['steps']) : undefined);
      if (Array.isArray(rawList)) {
        const arr: Object[] = rawList as Object[];
        const parsed: AiPlanStepView[] = [];
        for (let k = 0; k < arr.length; k++) {
          const item: Object = arr[k];
          if (item !== null && typeof item === 'object' && !Array.isArray(item)) {
            const rec: Record<string, Object> = item as Record<string, Object>;
            const content: string = typeof rec['content'] === 'string'
              ? (rec['content'] as string).trim()
              : (typeof rec['title'] === 'string' ? (rec['title'] as string).trim() : '');
            const status: string = typeof rec['status'] === 'string' ? (rec['status'] as string) : 'pending';
            const id: string = typeof rec['id'] === 'string' && (rec['id'] as string).length > 0
              ? (rec['id'] as string)
              : `step-${k + 1}`;
            if (content.length > 0) {
              parsed.push({ id, content, status });
            }
          } else if (typeof item === 'string' && (item as string).trim().length > 0) {
            parsed.push({ id: `step-${k + 1}`, content: (item as string).trim(), status: 'pending' });
          }
        }
        if (parsed.length > 0) {
          latest = parsed;
        }
      }
    } else if ((tool.name === 'update_task_status' || tool.name === 'update_task_statuses') && latest.length > 0) {
      const argsRec: Record<string, Object> | null = asRecord(tool.arguments);
      if (argsRec !== null) {
        const sid: string = typeof argsRec['id'] === 'string' ? (argsRec['id'] as string) : '';
        const st: string = typeof argsRec['status'] === 'string' ? (argsRec['status'] as string) : '';
        if (sid.length > 0 && st.length > 0) {
          latest = latest.map((p: AiPlanStepView): AiPlanStepView =>
            p.id === sid ? { id: p.id, content: p.content, status: st } : p
          );
        }
      }
    }
  }
  return latest;
}

export function parseAiTokenMeter(
  usageSummary: string,
  contextWindowTokens: number,
  thresholdFraction: number
): AiTokenMeterState {
  const safeWindow: number = Number.isFinite(contextWindowTokens) && contextWindowTokens >= 1024 ? contextWindowTokens : 32768;
  const thresholdPercent: number = Math.round(Math.min(0.95, Math.max(0.5, thresholdFraction)) * 100);
  const rawSummary: string = usageSummary || '';
  const lines: string[] = rawSummary.split(/\r?\n/);
  let preferredTarget: string = rawSummary;
  for (let i: number = lines.length - 1; i >= 0; i--) {
    if (lines[i].includes('服务端')) {
      preferredTarget = lines[i];
      break;
    }
  }
  const ratioPattern: RegExp = /(\d[\d,]*)\s*(?:tokens?\s*)?\/\s*(?:[^\d/\r\n]{0,24}?)(\d[\d,]*)\s*tokens?/i;
  const ratioMatch: RegExpExecArray | null = ratioPattern.exec(preferredTarget) ?? ratioPattern.exec(rawSummary);
  if (ratioMatch !== null) {
    const used: number = Number(ratioMatch[1].replace(/,/g, ''));
    const win: number = Number(ratioMatch[2].replace(/,/g, '')) || safeWindow;
    const pct: number = Math.min(100, Math.max(0, Math.round((used / Math.max(1, win)) * 100)));
    return {
      usedTokens: used,
      windowTokens: win,
      percent: pct,
      thresholdPercent,
      nearThreshold: pct >= thresholdPercent,
      hasNumeric: true,
      badgeText: `${used.toLocaleString()} / ${win.toLocaleString()} (${pct}%)`
    };
  }
  const singleMatch: RegExpExecArray | null = rawSummary.includes('/') ? null : /(\d[\d,]*)\s*tokens?/i.exec(rawSummary);
  if (singleMatch !== null) {
    const used: number = Number(singleMatch[1].replace(/,/g, ''));
    const pct: number = Math.min(100, Math.max(0, Math.round((used / Math.max(1, safeWindow)) * 100)));
    return {
      usedTokens: used,
      windowTokens: safeWindow,
      percent: pct,
      thresholdPercent,
      nearThreshold: pct >= thresholdPercent,
      hasNumeric: true,
      badgeText: `${used.toLocaleString()} / ${safeWindow.toLocaleString()} (${pct}%)`
    };
  }
  return {
    usedTokens: 0,
    windowTokens: safeWindow,
    percent: 0,
    thresholdPercent,
    nearThreshold: false,
    hasNumeric: false,
    badgeText: `窗口上限 ${safeWindow.toLocaleString()} tokens`
  };
}

export function formatAgentElapsed(startedAt: number, nowMs: number): string {
  if (!Number.isFinite(startedAt) || startedAt <= 0) {
    return '00:00';
  }
  const totalSec: number = Math.max(0, Math.floor((nowMs - startedAt) / 1000));
  const mins: number = Math.floor(totalSec / 60);
  const secs: number = totalSec % 60;
  const mm: string = mins < 10 ? `0${mins}` : `${mins}`;
  const ss: string = secs < 10 ? `0${secs}` : `${secs}`;
  return `${mm}:${ss}`;
}

export function buildAgentCanvasHudModel(
  isLoading: boolean,
  pendingSummary: string,
  minimizedNotice: string,
  showAiPanel: boolean,
  toolCalls: AiChatToolState[],
  generationStatus: string,
  streamingText: string,
  startedAt: number,
  nowMs: number,
  waitingForUser: boolean = false
): AgentCanvasHudModel {
  if (isLoading && waitingForUser) {
    return {
      phase: 'waiting',
      badge: '等待确认',
      title: 'Agent 等待你的选择',
      detail: showAiPanel ? '请在右侧对话卡片中勾选选项以继续执行' : '请展开窗口并在提问卡片中确认选项',
      stepText: toolCalls.length > 0 ? `第 ${toolCalls.length} 步` : '待确认',
      elapsedText: ''
    };
  }
  if (isLoading) {
    let activeToolLabel: string = '';
    for (let i: number = toolCalls.length - 1; i >= 0; i--) {
      const desc: AiToolPresentation = describeAiToolCall(toolCalls[i], true);
      if (toolCalls[i].status === 'running') {
        activeToolLabel = desc.inlineTarget.length > 0 ? `${desc.title} · ${desc.inlineTarget}` : desc.title;
        break;
      }
    }
    if (activeToolLabel.length === 0 && toolCalls.length > 0) {
      const latest: AiToolPresentation = describeAiToolCall(toolCalls[toolCalls.length - 1], true);
      activeToolLabel = latest.inlineTarget.length > 0 ? `${latest.title} · ${latest.inlineTarget}` : latest.title;
    }
    let detail: string = activeToolLabel;
    if (detail.length === 0) {
      if (streamingText.trim().length > 0) {
        const cleanStream: string = streamingText.replace(/\s+/g, ' ').trim();
        detail = cleanStream.length > 42 ? `正在输出回复：${cleanStream.substring(cleanStream.length - 40)}` : `正在输出回复：${cleanStream}`;
      } else {
        detail = generationStatus.trim().length > 0 ? generationStatus.trim() : '正在分析版图与准备操作…';
      }
    }
    return {
      phase: 'drawing',
      badge: '第一期 · Agent 操作中',
      title: 'Agent 正在操作图纸',
      detail,
      stepText: toolCalls.length > 0 ? `第 ${toolCalls.length} 步` : '准备中',
      elapsedText: formatAgentElapsed(startedAt, nowMs)
    };
  }

  if (pendingSummary.trim().length > 0) {
    return {
      phase: 'preview',
      badge: '第二期 · 待确认预览',
      title: '图纸预览就绪 · 尚未落盘',
      detail: pendingSummary.trim(),
      stepText: '待审阅',
      elapsedText: ''
    };
  }

  if (!showAiPanel && minimizedNotice.trim().length > 0) {
    return {
      phase: 'completed',
      badge: 'Agent 已就绪',
      title: '后台任务已完成',
      detail: minimizedNotice.trim(),
      stepText: '',
      elapsedText: ''
    };
  }

  return {
    phase: 'hidden',
    badge: '',
    title: '',
    detail: '',
    stepText: '',
    elapsedText: ''
  };
}

export function formatRelativeConversationTime(updatedAt: number, nowMs: number = Date.now()): string {
  if (!Number.isFinite(updatedAt) || updatedAt <= 0) {
    return '';
  }
  const diffSec: number = Math.max(0, Math.floor((nowMs - updatedAt) / 1000));
  if (diffSec < 45) {
    return '刚刚';
  }
  if (diffSec < 3600) {
    return `${Math.floor(diffSec / 60)} 分钟前`;
  }
  if (diffSec < 86400) {
    return `${Math.floor(diffSec / 3600)} 小时前`;
  }
  const d: Date = new Date(updatedAt);
  const m: number = d.getMonth() + 1;
  const day: number = d.getDate();
  return `${m}/${day}`;
}

export function exportConversationAsMarkdown(title: string, messages: ChatMessage[]): string {
  const lines: string[] = [`# ${title || '鸿图 AI 会话记录'}`, ''];
  for (let i: number = 0; i < messages.length; i++) {
    const msg: ChatMessage = messages[i];
    const roleTitle: string = msg.role === 'user' ? '## 用户' : (msg.role === 'assistant' ? '## 鸿图 Agent' : '## 系统');
    lines.push(roleTitle);
    if (msg.tools !== undefined && msg.tools.length > 0) {
      lines.push('');
      lines.push('> 工具轨迹：' + msg.tools.map((t: AiChatToolState): string => {
        const d: AiToolPresentation = describeAiToolCall(t, false);
        return d.inlineTarget.length > 0 ? `${d.title}(${d.inlineTarget})` : d.title;
      }).join(' → '));
    }
    if (msg.content.trim().length > 0) {
      lines.push('');
      lines.push(msg.content.trim());
    }
    lines.push('');
  }
  return lines.join('\n');
}

export function formatCompactTokens(tokens: number): string {
  if (!Number.isFinite(tokens) || tokens <= 0) {
    return '—';
  }
  if (tokens >= 1000000) {
    const m: number = Math.round((tokens / 1048576) * 10) / 10;
    return `${m}M`;
  }
  if (tokens === 200000) {
    return '200K';
  }
  if (tokens >= 1024 && tokens % 1024 === 0) {
    return `${Math.round(tokens / 1024)}K`;
  }
  if (tokens >= 1000) {
    const k: number = Math.round((tokens / 1000) * 10) / 10;
    return `${k}K`;
  }
  return `${Math.round(tokens)}`;
}

export function reasoningEffortLabel(effort: string | undefined): string {
  if (effort === 'none') return '关闭';
  if (effort === 'low') return '低';
  if (effort === 'medium') return '中';
  if (effort === 'high') return '高';
  return '自动';
}

export function splitInlineThinking(rawText: string, explicitReasoning: string = ''): AiExtractedThinking {
  const parts: string[] = [];
  if (explicitReasoning.trim().length > 0) {
    parts.push(explicitReasoning.trim());
  }
  let rest: string = rawText || '';
  let streamingThink: boolean = false;
  const closedThinkRegex: RegExp = /<think>([\s\S]*?)<\/think>/gi;
  let match: RegExpExecArray | null = closedThinkRegex.exec(rest);
  while (match !== null) {
    if (match[1].trim().length > 0) {
      parts.push(match[1].trim());
    }
    match = closedThinkRegex.exec(rest);
  }
  rest = rest.replace(/<think>[\s\S]*?<\/think>\s*/gi, '');
  const openIdx: number = rest.toLowerCase().indexOf('<think>');
  if (openIdx >= 0) {
    const unclosed: string = rest.substring(openIdx + 7).trim();
    if (unclosed.length > 0) {
      parts.push(unclosed);
    }
    rest = rest.substring(0, openIdx);
    streamingThink = true;
  }
  return {
    thinking: parts.join('\n\n'),
    answer: rest.trimStart(),
    isStreamingThink: streamingThink
  };
}

export function estimateDraftQuickTokens(text: string): number {
  if (!text || text.length === 0) return 0;
  let wide: number = 0;
  let narrow: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    if (text.charCodeAt(i) > 255) wide++;
    else narrow++;
  }
  return Math.ceil(wide * 1.5 + narrow / 3);
}

export function computeDraftAwareTokenMeter(
  usageSummary: string,
  draftText: string,
  contextWindowTokens: number,
  thresholdFraction: number
): AiTokenMeterState {
  const base: AiTokenMeterState = parseAiTokenMeter(usageSummary, contextWindowTokens, thresholdFraction);
  const draftTokens: number = estimateDraftQuickTokens(draftText);
  if (draftTokens <= 0) {
    return base;
  }
  const win: number = base.windowTokens > 0 ? base.windowTokens : 32768;
  const used: number = base.usedTokens + draftTokens;
  const pct: number = Math.min(100, Math.max(0, Math.round((used / Math.max(1, win)) * 100)));
  return {
    usedTokens: used,
    windowTokens: win,
    percent: pct,
    thresholdPercent: base.thresholdPercent,
    nearThreshold: pct >= base.thresholdPercent,
    hasNumeric: true,
    badgeText: `${used.toLocaleString()} / ${win.toLocaleString()} (${pct}%)`
  };
}

export interface AiStreamingBlock {
  kind: 'code' | 'heading' | 'quote' | 'list' | 'paragraph';
  text: string;
  language: string;
  level: number;
  marker: string;
}

/**
 * 流式输出期间使用的同步轻量块切分器：
 * 在同一段落或同一代码块持续追加 token 时，保持块数量与 kind 不变，仅更新末尾块的 text，
 * 避免第三方 Markdown 组件在流式帧重建 AST 导致滚动容器高度归零抖动。
 */
export function splitStreamingMarkdownBlocks(raw: string): AiStreamingBlock[] {
  const normalized: string = (raw || '').replace(/\r\n/g, '\n');
  if (normalized.trim().length === 0) {
    return [];
  }
  const lines: string[] = normalized.split('\n');
  const blocks: AiStreamingBlock[] = [];
  let i: number = 0;

  while (i < lines.length) {
    const line: string = lines[i];
    const trimmed: string = line.trim();
    if (trimmed.length === 0) {
      i++;
      continue;
    }

    const fenceMatch: RegExpExecArray | null = /^(`{3,}|~{3,})([^`~]*)$/.exec(trimmed);
    if (fenceMatch !== null) {
      const markerFence: string = fenceMatch[1];
      const lang: string = fenceMatch[2].trim();
      const codeLines: string[] = [];
      i++;
      while (i < lines.length) {
        const checkTrim: string = lines[i].trim();
        if (checkTrim.startsWith(markerFence.charAt(0).repeat(markerFence.length)) &&
          checkTrim.replace(/[`~]/g, '').trim().length === 0) {
          i++;
          break;
        }
        codeLines.push(lines[i]);
        i++;
      }
      blocks.push({
        kind: 'code',
        text: codeLines.join('\n'),
        language: lang,
        level: 0,
        marker: ''
      });
      continue;
    }

    const headingMatch: RegExpExecArray | null = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (headingMatch !== null) {
      blocks.push({
        kind: 'heading',
        text: stripInlineMarkdownDecorators(headingMatch[2]),
        language: '',
        level: headingMatch[1].length,
        marker: ''
      });
      i++;
      continue;
    }

    if (trimmed.startsWith('>')) {
      const quoteLines: string[] = [];
      while (i < lines.length && lines[i].trim().startsWith('>')) {
        quoteLines.push(stripInlineMarkdownDecorators(lines[i].trim().replace(/^>+\s?/, '')));
        i++;
      }
      blocks.push({
        kind: 'quote',
        text: quoteLines.join('\n'),
        language: '',
        level: 0,
        marker: ''
      });
      continue;
    }

    const listMatch: RegExpExecArray | null = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(line);
    if (listMatch !== null) {
      const indentLevel: number = Math.min(4, Math.floor(listMatch[1].length / 2));
      const bullet: string = /^\d+\./.test(listMatch[2]) ? listMatch[2] : '•';
      blocks.push({
        kind: 'list',
        text: stripInlineMarkdownDecorators(listMatch[3]),
        language: '',
        level: indentLevel,
        marker: bullet
      });
      i++;
      continue;
    }

    const paraLines: string[] = [];
    while (i < lines.length) {
      const cur: string = lines[i];
      const curTrim: string = cur.trim();
      if (curTrim.length === 0 ||
        /^(`{3,}|~{3,})/.test(curTrim) ||
        /^#{1,6}\s+/.test(curTrim) ||
        curTrim.startsWith('>') ||
        /^(\s*)([-*+]|\d+\.)\s+/.test(cur)) {
        break;
      }
      paraLines.push(stripInlineMarkdownDecorators(cur));
      i++;
    }
    if (paraLines.length > 0) {
      blocks.push({
        kind: 'paragraph',
        text: paraLines.join('\n'),
        language: '',
        level: 0,
        marker: ''
      });
    } else {
      i++;
    }
  }
  return blocks;
}

/**
 * 直接移植自 DSH-Harmony `NativeStreamingMarkdown.ets`：
 * 已闭合段落脱离流式重绘循环，仅末尾活跃块作为单节点内联更新，彻底兼顾实时刷新与零高度跳动。
 */
export class DshStreamingMarkdownUpdate {
  changed: boolean = false;
  reset: boolean = false;
  tail: string = '';
  tailInFence: boolean = false;
  appended: string[] = [];
}

export class DshStreamingMarkdownBuffer {
  private value: string = '';
  private tail: string = '';
  private blocks: string[] = [];
  private blockStart: number = 0;
  private lineStart: number = 0;
  private scanAt: number = 0;
  private fenceCharacter: string = '';
  private fenceLength: number = 0;
  private tableCandidate: boolean = false;
  readonly maxBlockLength: number = 3072;

  private reset(): void {
    this.blocks = [];
    this.tail = '';
    this.blockStart = 0;
    this.lineStart = 0;
    this.scanAt = 0;
    this.fenceCharacter = '';
    this.fenceLength = 0;
    this.tableCandidate = false;
  }

  private finishBlock(source: string, end: number, update: DshStreamingMarkdownUpdate): void {
    if (end <= this.blockStart) return;
    const block: string = source.substring(this.blockStart, end);
    if (block.trim().length > 0) {
      this.blocks.push(block);
      update.appended.push(block);
    }
    this.blockStart = end;
    this.tableCandidate = false;
  }

  private processLine(source: string, lineEnd: number, line: string, update: DshStreamingMarkdownUpdate): void {
    if (this.fenceCharacter.length > 0) {
      const close = /^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})[ \t]*$/.exec(line);
      if (close !== null && close[1].charAt(0) === this.fenceCharacter && close[1].length >= this.fenceLength) {
        this.fenceCharacter = '';
        this.fenceLength = 0;
      }
      return;
    }
    const fence = /^[ \t]*(?:>[ \t]?)*[ \t]*(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence !== null) {
      this.fenceCharacter = fence[1].charAt(0);
      this.fenceLength = fence[1].length;
      return;
    }
    if (line.trim().length === 0) {
      this.finishBlock(source, lineEnd, update);
      return;
    }
    if (line.indexOf('|') >= 0) this.tableCandidate = true;
    const length: number = lineEnd - this.blockStart;
    if (!this.tableCandidate && length >= this.maxBlockLength) {
      this.finishBlock(source, lineEnd, update);
    }
  }

  update(next: string): DshStreamingMarkdownUpdate {
    const update: DshStreamingMarkdownUpdate = new DshStreamingMarkdownUpdate();
    if (next === this.value) {
      update.tail = this.tail;
      update.tailInFence = this.fenceCharacter.length > 0;
      return update;
    }
    update.changed = true;
    update.reset = !next.startsWith(this.value);
    if (update.reset) this.reset();
    const from: number = update.reset ? 0 : this.scanAt;
    this.value = next;
    for (let index = from; index < next.length; index++) {
      if (next.charAt(index) !== '\n') continue;
      const line: string = next.substring(this.lineStart, index);
      this.processLine(next, index + 1, line, update);
      this.lineStart = index + 1;
    }
    this.scanAt = next.length;
    this.tail = next.substring(this.blockStart);
    update.tail = this.tail;
    update.tailInFence = this.fenceCharacter.length > 0;
    return update;
  }
}

export function oneLineStepPreview(raw: string, maxChars: number = 96): string {
  const clean: string = (raw || '').replace(/\*\*/g, '').replace(/`/g, '').replace(/\s+/g, ' ').trim();
  if (clean.length <= maxChars) return clean;
  return `${clean.substring(0, maxChars - 1)}…`;
}

/**
 * 为历史消息或实时步骤统一生成 DSH 交错多步过程列表：
 * 新消息直接使用按事件时序记录的 `msg.steps`（思考 #1 -> 工具 #1 -> 思考 #2 -> 工具 #2）；
 * 旧历史消息自动由 `reasoning` 与 `tools` 回退合成为步骤序列。
 */
export function resolveMessageProcessSteps(msg: ChatMessage): AiProcessStep[] {
  if (msg.steps !== undefined && msg.steps.length > 0) {
    return msg.steps.filter((s: AiProcessStep): boolean =>
      s.kind === 'tool' || s.text.trim().length > 0);
  }
  const fallback: AiProcessStep[] = [];
  const split = splitInlineThinking(msg.content || '', msg.reasoning ?? '');
  if (split.thinking.trim().length > 0) {
    fallback.push({
      id: `legacy-think-${msg.timestamp}`,
      kind: 'thinking',
      title: '思考过程',
      text: split.thinking.trim(),
      status: 'completed'
    });
  }
  const tools: AiChatToolState[] = msg.tools ?? [];
  for (let i = 0; i < tools.length; i++) {
    fallback.push({
      id: `legacy-tool-${tools[i].id}`,
      kind: 'tool',
      title: tools[i].name,
      text: '',
      status: tools[i].status,
      tool: tools[i]
    });
  }
  return fallback;
}

export function resolveMessageFinalAnswer(msg: ChatMessage): string {
  if (msg.steps !== undefined && msg.steps.length > 0) {
    return splitInlineThinking(msg.content || '', '').answer;
  }
  return splitInlineThinking(msg.content || '', msg.reasoning ?? '').answer;
}

export function summarizeProcessSteps(steps: AiProcessStep[], isLive: boolean): string {
  let thinkCount: number = 0;
  let toolCount: number = 0;
  let failedTools: number = 0;
  for (let i = 0; i < steps.length; i++) {
    if (steps[i].kind === 'thinking' && steps[i].text.trim().length > 0) thinkCount++;
    if (steps[i].kind === 'tool') {
      toolCount++;
      if (steps[i].status === 'failed') failedTools++;
    }
  }
  if (isLive) {
    for (let i = steps.length - 1; i >= 0; i--) {
      const s: AiProcessStep = steps[i];
      if (s.status === 'running') {
        if (s.kind === 'tool' && s.tool !== undefined) {
          const desc: AiToolPresentation = describeAiToolCall(s.tool, true);
          return desc.inlineTarget.length > 0 ? `正在${desc.title} · ${desc.inlineTarget}` : `正在${desc.title}`;
        }
        if (s.kind === 'thinking') {
          const preview: string = oneLineStepPreview(s.text, 42);
          return preview.length > 0 ? `正在思考 · ${preview}` : '正在深度思考…';
        }
      }
    }
  }
  const parts: string[] = [];
  if (thinkCount > 0) parts.push(`${thinkCount} 步思考`);
  if (toolCount > 0) {
    parts.push(failedTools > 0 ? `${toolCount} 步工具（${failedTools} 步未通过）` : `${toolCount} 步工具调用`);
  }
  return parts.length > 0 ? parts.join(' · ') : '工作过程';
}

/**
 * 纯 V1 `@StorageLink('hongtu_ai_live_rev')` 实时流通道（对应 DSH-Harmony `nativeRefreshRevision`）：
 * 彻底绕开 Index(V1) -> AiStore(@ObservedV2) -> AiAssistantPanel(V1 @Prop) 的跨代响应式断层，
 * 确保无需收起/展开面板，每一个流式分片与工具步骤都实时刷新到屏幕上。
 */
export interface AiLiveStreamSnapshot {
  revision: number;
  running: boolean;
  statusText: string;
  steps: AiProcessStep[];
  answerText: string;
  activeThinkId: string;
  activeThinkText: string;
}

let currentLiveSnapshot: AiLiveStreamSnapshot = {
  revision: 0,
  running: false,
  statusText: '',
  steps: [],
  answerText: '',
  activeThinkId: '',
  activeThinkText: ''
};

function bumpLiveRevision(): void {
  try {
    AppStorage.setOrCreate<number>('hongtu_ai_live_rev', currentLiveSnapshot.revision);
  } catch (_) {
    // Headless unit test environments without ArkUI AppStorage safely ignore.
  }
}

export function publishAiLiveStream(
  running: boolean,
  statusText: string,
  steps: AiProcessStep[],
  answerText: string
): void {
  let activeId: string = '';
  let activeText: string = '';
  for (let i = steps.length - 1; i >= 0; i--) {
    if (steps[i].kind === 'thinking' && steps[i].status === 'running') {
      activeId = steps[i].id;
      activeText = steps[i].text;
      break;
    }
  }
  currentLiveSnapshot = {
    revision: currentLiveSnapshot.revision + 1,
    running,
    statusText,
    steps: steps.slice(),
    answerText,
    activeThinkId: activeId,
    activeThinkText: activeText
  };
  bumpLiveRevision();
}

export function resetAiLiveStream(): void {
  currentLiveSnapshot = {
    revision: currentLiveSnapshot.revision + 1,
    running: false,
    statusText: '',
    steps: [],
    answerText: '',
    activeThinkId: '',
    activeThinkText: ''
  };
  bumpLiveRevision();
}

export function getAiLiveStreamSnapshot(): AiLiveStreamSnapshot {
  return currentLiveSnapshot;
}
