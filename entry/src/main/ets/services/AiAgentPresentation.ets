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

import type { AiChatToolState, ChatMessage } from './AiService';

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
  phase: 'drawing' | 'preview' | 'completed' | 'hidden';
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
    command: '/python',
    title: '打开 Python 版图工作台',
    subtitle: '进入参数化脚本生成、扫参与隔离预览面板',
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
    case 'query_editor': return '查询版图明细';
    case 'list_native_tools': return '查询软件工具目录';
    case 'read_native_tool': return '读取原生工具数据';
    case 'propose_native_tools': return '提交原生工具方案';
    case 'prepare_native_workflow': return '准备专业编辑流程';
    case 'check_tool_protocol': return '诊断工具调用协议';
    case 'create_cmos_inverter': return '生成 CMOS 反相器';
    case 'execute_layout_python': return '运行参数化版图脚本';
    case 'propose_editor_commands': return '准备版图修改方案';
    case 'read_plan': return '读取执行计划';
    case 'write_plan': return '制定执行计划';
    case 'update_plan': return '更新执行计划';
    case 'update_task_status':
    case 'update_task_statuses': return '更新计划步骤';
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

  if (tool.name === 'query_editor') {
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
  } else if (tool.name === 'execute_layout_python' || tool.name === 'create_cmos_inverter') {
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
  } else if (tool.name === 'write_plan' || tool.name === 'read_plan' || tool.name === 'update_task_status') {
    const planStepMatch: RegExpExecArray | null = /Plan updated:\s*(\d+)\s*step/i.exec(tool.result);
    if (planStepMatch !== null) {
      summaryParts.push(`${planStepMatch[1]} 步`);
      fields.push({ label: '计划步骤', value: `${planStepMatch[1]} 步`, accent: false });
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
  nowMs: number
): AgentCanvasHudModel {
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
