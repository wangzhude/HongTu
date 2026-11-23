/**
 * DSH 原生直连多步 Agent 调度引擎 + 鸿图版图原生后端桥接器
 *
 * 架构设计（对齐 DSH-Harmony + dsh-harmony-mobile）：
 * 1. HarmonyOS 端直接通过 @kit.NetworkKit 流式连接任意 OpenAI 兼容 / DeepSeek / 通义 / 硅基流动 /
 *    OpenRouter / WorkBuddy / Ollama 等大模型服务，无需依赖本机 Python 伴随服务即可开箱使用完整 Agent。
 * 2. 工具直接接入鸿图原生 C++/ArkTS 版图引擎（EditService / PortService / DrcService / NativeHongTuService）：
 *    - inspect_layout / query_layout：毫秒级读取当前文档、图层、Cell、端口、选区与 DRC 状态；
 *    - todo_write：实时更新 DSH 任务进度面板；
 *    - create_cmos_inverter：原生参数化构建完整 CMOS 反相器（含 NWELL/ACTIVE/POLY/NPLUS/PPLUS/CONTACT/METAL1、
 *      VDD/VSS 衬底接触、IN/OUT/VDD/VSS 标签与端口），当前为空文档时直接原地写入并支持一键撤销，绝不触发“新文档容量已用尽”；
 *    - edit_layout：批量创建矩形/多边形/路径/文本/阵列或移动/旋转/镜像/缩放/删除，自动补齐命名图层并打包为单次原子撤销事务；
 *    - run_drc：调用原生 C++ DRC 引擎并返回具体违规坐标供 Agent 自主闭环修复；
 *    - list_native_tools / call_native_tool：直连鸿图全部 90+ 原生专业工具（PCell、端口对齐、自动布线、布尔运算、LVS 等）；
 *    - execute_klayout_python：若已连接 PC 端 Python 伴随服务则执行受控 KLayout 脚本，未连接时自动引导改用原生工具无缝完成。
 * 3. 针对长思考模型（如 space-bunny 1M / DeepSeek-R1 / Qwen3 / o3）：
 *    - 实时解析 reasoning_content / reasoning / <think> 标签并逐帧推送至 @StorageLink 视图总线；
 *    - 支持 DeepSeek 等思考模型多轮工具调用中的 reasoning_content 回放；
 *    - 单步 10 分钟滑动静默超时 + 最多 32 轮工具推理闭环 + 纯思考截断（finish_reason=length）自动精简续跑，绝不误杀长思考。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AiProvider } from './AiService';
import type { AiModelConfig, ChatMessage, ParsedCommand, AiChatToolState, AiProcessStep } from './AiService';
import { splitInlineThinking } from './AiAgentPresentation';
import type { DshPermissionMode } from '../components/dsh/DshDesign';

export interface DshCmosInverterParams {
  cellName: string;
  gateLengthNm: number;
  nmosWidthNm: number;
  pmosWidthNm: number;
  target: 'auto' | 'current_cell' | 'new_tab';
}

export interface DshEditOperation {
  action: string;
  layer?: number;
  datatype?: number;
  layerName?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  points?: Array<Record<string, number>>;
  pathWidth?: number;
  text?: string;
  shapeIds?: number[];
  rows?: number;
  cols?: number;
  spacingX?: number;
  spacingY?: number;
  dx?: number;
  dy?: number;
  degrees?: number;
  horizontal?: boolean;
  scale?: number;
  centerX?: number;
  centerY?: number;
}

export interface DshToolExecutionOutcome {
  success: boolean;
  summary: string;
  payloadJson: string;
  addedShapes?: number;
  deletedShapes?: number;
  addedPorts?: number;
  drcSummary?: string;
  stagedPending?: boolean;
}

export interface DshLayoutBackendHost {
  isPageCurrent: () => boolean;
  inspectLayout: () => string;
  queryLayout: (argsJson: string) => Promise<string>;
  createCmosInverter: (params: DshCmosInverterParams, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  editLayout: (operations: DshEditOperation[], permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  runDrcCheck: () => Promise<DshToolExecutionOutcome>;
  listNativeTools: (category: string, offset: number, toolName: string) => string;
  callNativeTool: (toolName: string, argumentsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  executeKlayoutPython: (script: string, applyMode: 'replace' | 'merge') => Promise<DshToolExecutionOutcome>;
}

export interface DshAgentRunCallbacks {
  onStatus: (statusText: string) => void;
  onProgress: (steps: AiProcessStep[], liveAnswer: string, tools: AiChatToolState[]) => void;
}

export interface DshAgentRunResult {
  finalAnswer: string;
  fullReasoning: string;
  steps: AiProcessStep[];
  tools: AiChatToolState[];
  mutatedLayout: boolean;
  stagedPending: boolean;
  turnChangeSummary: string;
}

interface OpenAiToolFunctionDef {
  name: string;
  description: string;
  parameters: Object;
}

interface OpenAiToolDef {
  type: 'function';
  function: OpenAiToolFunctionDef;
}

interface WireToolCallFunction {
  name: string;
  arguments: string;
}

interface WireToolCall {
  id: string;
  type: 'function';
  function: WireToolCallFunction;
}

interface WireChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | null;
  reasoning_content?: string;
  tool_calls?: WireToolCall[];
  tool_call_id?: string;
}

interface WireThinkingConfig {
  type: string;
}

interface WireChatRequest {
  model: string;
  messages: WireChatMessage[];
  tools: OpenAiToolDef[];
  tool_choice: string;
  stream: boolean;
  temperature: number;
  max_completion_tokens?: number;
  max_tokens?: number;
  thinking?: WireThinkingConfig;
  enable_thinking?: boolean;
  reasoning_effort?: string;
}

interface StreamToolCallAccumulator {
  index: number;
  id: string;
  name: string;
  argumentsText: string;
}

interface SingleTurnModelOutput {
  content: string;
  reasoning: string;
  finishReason: string;
  toolCalls: WireToolCall[];
}

const DSH_LAYOUT_SYSTEM_PROMPT: string =
  '你是鸿图 (HongTu EDA) 集成电路与光子版图智能体，采用 DSH 多步工作流直接连接当前版图编辑器。\n' +
  '核心工作准则：\n' +
  '1. 使用中文清晰专业地回答。当用户询问概念、分析版图或检查问题时，先调用 inspect_layout 或 query_layout 读取真实版图数据再作答，绝不猜测坐标或图元。\n' +
  '2. 复杂多步任务可先调用 todo_write 列出简明执行计划（2~5 步），并在完成后更新状态。\n' +
  '3. 当用户要求“画一个反相器 / CMOS 反相器”时，优先直接调用 create_cmos_inverter 工具！该工具会在当前空白单元或独立标签页直接生成包含 NWELL(1/0)、ACTIVE(2/0)、POLY(3/0)、NPLUS(4/0)、PPLUS(5/0)、CONTACT(6/0)、METAL1(7/0)、PIN_LABEL(8/0) 及 IN/OUT/VDD/VSS 端口与衬底接触的完整版图，并自动运行 DRC 检查。注意说明这是通用 CMOS 几何教学/工程示例，未绑定晶圆厂 PDK 签核。\n' +
  '4. 当用户要求绘制矩形、多边形、路径（波导/金属线）、文本标注、阵列复制，或移动/旋转/镜像/缩放/删除现有图形时，直接调用 edit_layout 提交原子操作批次（所有长度与坐标单位均为 nm）。\n' +
  '5. 需要 PCell 参数化器件（圆环谐振器、波导弯曲、MOS 管等）、端口管理、光学/电气自动布线、布尔运算、层逻辑运算、LVS 网表提取等高级能力时，使用 list_native_tools 查询参数 schema 后调用 call_native_tool。\n' +
  '6. 修改或绘制完版图后，可调用 run_drc 执行原生设计规则检查；若发现间距或线宽违规，可根据返回的精确坐标继续调用 edit_layout 自主修正。\n' +
  '7. 保持思考精炼高效，直接调用工具完成用户目标，不要只贴一段代码让用户自己手动运行。';

function buildDshTools(permission: DshPermissionMode): OpenAiToolDef[] {
  const parseSchema = (raw: string): Object => JSON.parse(raw) as Object;
  const readTools: OpenAiToolDef[] = [
    {
      type: 'function',
      function: {
        name: 'inspect_layout',
        description: '读取当前激活版图文档的完整摘要，包括文档名、顶层与当前 Cell、DBU(nm)、图层列表、图形总数、当前选中图形、端口数量、DRC 状态与工作区标签页。',
        parameters: parseSchema('{"type":"object","properties":{},"additionalProperties":false}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'query_layout',
        description: '按需分页查询当前版图的真实对象明细（shapes 图形坐标、cells 层级、ports 端口、drc 违规项、rules 设计规则）。坐标单位均为 nm。',
        parameters: parseSchema('{"type":"object","properties":{"kind":{"type":"string","enum":["shapes","cells","ports","drc","rules"]},"cellId":{"type":"integer","minimum":0},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64}},"required":["kind"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'todo_write',
        description: '创建或更新当前会话的分步执行计划清单，实时展示在底部任务进度栏中。',
        parameters: parseSchema('{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["todos"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'list_native_tools',
        description: '检索鸿图内置的 90+ 项专业版图工具目录（如 pcells、ports、route、geometry、hierarchy、verification、layers、view），传入 toolName 可获取精确 JSON 参数定义。',
        parameters: parseSchema('{"type":"object","properties":{"category":{"type":"string"},"offset":{"type":"integer","minimum":0},"toolName":{"type":"string"}}}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'run_drc',
        description: '对当前版图立即运行原生 C++ DRC 设计规则检查，返回错误/警告统计及具体违规区域坐标（nm）。',
        parameters: parseSchema('{"type":"object","properties":{},"additionalProperties":false}')
      }
    }
  ];

  if (permission === 'readonly') {
    readTools.push({
      type: 'function',
      function: {
        name: 'call_native_tool',
        description: '在只读模式下调用 mode=read 的鸿图原生只读查询工具（如 pcells.list、technology.get、geometry.measure、ports.project）。',
        parameters: parseSchema('{"type":"object","properties":{"name":{"type":"string"},"arguments":{"type":"object"}},"required":["name"]}')
      }
    });
    return readTools;
  }

  const writeTools: OpenAiToolDef[] = [
    {
      type: 'function',
      function: {
        name: 'create_cmos_inverter',
        description: '原生参数化生成完整通用 CMOS 反相器版图（含 NWELL/ACTIVE/POLY/NPLUS/PPLUS/CONTACT/METAL1 图层、VDD/VSS 衬底接触孔、IN/OUT/VDD/VSS 标签与语义端口，并自动执行 DRC 与视图适配）。尺寸单位为整数 nm。当前 Cell 为空时默认原地绘制，否则自动新建独立标签页。',
        parameters: parseSchema('{"type":"object","properties":{"cellName":{"type":"string","default":"INVERTER"},"gateLengthNm":{"type":"integer","minimum":50,"maximum":100000,"default":200},"nmosWidthNm":{"type":"integer","minimum":100,"maximum":100000,"default":600},"pmosWidthNm":{"type":"integer","minimum":100,"maximum":100000,"default":1200},"target":{"type":"string","enum":["auto","current_cell","new_tab"],"default":"auto"}}}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'edit_layout',
        description: '在当前版图 Cell 中原子化批量执行几何绘制与修改（支持一次撤销）。所有坐标和尺寸单位均为 nm。action 支持：create_rect(x,y,width,height,layer,datatype,layerName)、create_polygon(points:[{x,y}],layer,datatype)、create_path(points:[{x,y}],pathWidth,layer,datatype)、create_text(x,y,text,layer,datatype)、create_array(shapeIds,rows,cols,spacingX,spacingY)、move_shape(shapeIds,dx,dy)、rotate_shape(shapeIds,degrees,centerX,centerY)、mirror_shape(shapeIds,horizontal,centerX,centerY)、scale_shape(shapeIds,scale,centerX,centerY)、delete_shape(shapeIds)。',
        parameters: parseSchema('{"type":"object","properties":{"operations":{"type":"array","minItems":1,"maxItems":256,"items":{"type":"object","properties":{"action":{"type":"string","enum":["create_rect","create_polygon","create_path","create_text","create_array","move_shape","rotate_shape","mirror_shape","scale_shape","delete_shape"]},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"layerName":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"points":{"type":"array","items":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}},"pathWidth":{"type":"number"},"text":{"type":"string"},"shapeIds":{"type":"array","items":{"type":"integer"}},"rows":{"type":"integer","minimum":1,"maximum":1000},"cols":{"type":"integer","minimum":1,"maximum":1000},"spacingX":{"type":"number"},"spacingY":{"type":"number"},"dx":{"type":"number"},"dy":{"type":"number"},"degrees":{"type":"number"},"horizontal":{"type":"boolean"},"scale":{"type":"number"},"centerX":{"type":"number"},"centerY":{"type":"number"}},"required":["action"]}}},"required":["operations"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'call_native_tool',
        description: '调用任意鸿图注册原生工具（如 pcell.place 生成参数化器件、ports.add/connect 端口操作、route.preview/apply 自动布线、boolean.apply 布尔运算、layers.expression 层运算、lvs.extract 提取网表、view.fit 视图适配等）。请先用 list_native_tools 确认参数格式。',
        parameters: parseSchema('{"type":"object","properties":{"name":{"type":"string"},"arguments":{"type":"object"}},"required":["name"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'execute_klayout_python',
        description: '（可选增强）当连接了桌面端 Python 伴随服务时，在隔离沙箱中运行 KLayout Python (import hongtu as db) 脚本并载入当前或新标签页；若未连接伴随服务，请改用 create_cmos_inverter、edit_layout 或 call_native_tool 直接原生绘制。',
        parameters: parseSchema('{"type":"object","properties":{"script":{"type":"string"},"applyMode":{"type":"string","enum":["replace","merge"],"default":"replace"}},"required":["script"]}')
      }
    }
  ];

  return readTools.concat(writeTools);
}

function normalizeChatCompletionsUrl(rawEndpoint: string, provider: string): string {
  const trimmed: string = rawEndpoint.trim().replace(/\/+$/, '');
  if (trimmed.length === 0) {
    throw new Error('请先在 AI 设置中填写模型 API 地址（如 https://api.deepseek.com/v1）');
  }
  if (!/^https?:\/\/[^/\s?#]+/i.test(trimmed)) {
    throw new Error('模型 API 地址格式无效，请以 https:// 或 http:// 开头');
  }
  if (trimmed.endsWith('/chat/completions')) {
    return trimmed;
  }
  if (provider === AiProvider.OLLAMA_LOCAL && trimmed.endsWith('/api/chat')) {
    return trimmed.substring(0, trimmed.length - '/api/chat'.length) + '/v1/chat/completions';
  }
  if (/\/v\d+(?:beta\d*)?$/i.test(trimmed) || trimmed.endsWith('/compatible-mode/v1') || trimmed.endsWith('/api/paas/v4')) {
    return `${trimmed}/chat/completions`;
  }
  return `${trimmed}/v1/chat/completions`;
}

function cloneProcessSteps(steps: AiProcessStep[]): AiProcessStep[] {
  return steps.map((s: AiProcessStep): AiProcessStep => ({
    id: s.id,
    kind: s.kind,
    title: s.title,
    text: s.text,
    status: s.status,
    tool: s.tool === undefined ? undefined : {
      id: s.tool.id,
      name: s.tool.name,
      status: s.tool.status,
      arguments: s.tool.arguments,
      result: s.tool.result
    }
  }));
}

function cloneTools(tools: AiChatToolState[]): AiChatToolState[] {
  return tools.map((t: AiChatToolState): AiChatToolState => ({
    id: t.id,
    name: t.name,
    status: t.status,
    arguments: t.arguments,
    result: t.result
  }));
}

export class DshLayoutAgentService {
  private runSerial: number = 0;
  private activeAbort: (() => void) | null = null;
  private running: boolean = false;

  isBusy(): boolean {
    return this.running;
  }

  cancel(): void {
    this.runSerial++;
    if (this.activeAbort !== null) {
      const abortFn: () => void = this.activeAbort;
      this.activeAbort = null;
      try { abortFn(); } catch (_) {}
    }
  }

  async run(
    prompt: string,
    config: AiModelConfig,
    history: ChatMessage[],
    summary: string,
    permission: DshPermissionMode,
    host: DshLayoutBackendHost,
    callbacks: DshAgentRunCallbacks
  ): Promise<DshAgentRunResult> {
    if (this.running) {
      throw new Error('Agent 正在执行上一项版图任务，请等待完成或点击停止');
    }
    if (config.enabled === false) {
      throw new Error('当前模型已停用，请在设置中启用或切换其他模型');
    }
    const url: string = normalizeChatCompletionsUrl(config.endpoint, config.provider);
    const apiKey: string = config.apiKey.trim();
    if (config.provider === AiProvider.OPENAI_COMPATIBLE && apiKey.length === 0 &&
      !/^http:\/\/(?:127\.|localhost|\[::1\])/i.test(url)) {
      throw new Error('当前模型尚未填写 API Key，请点击右上角设置图标配置密钥');
    }

    const ticket: number = ++this.runSerial;
    this.running = true;

    const steps: AiProcessStep[] = [];
    const tools: AiChatToolState[] = [];
    let stepSeq: number = 0;
    let totalAddedShapes: number = 0;
    let totalDeletedShapes: number = 0;
    let totalAddedPorts: number = 0;
    let latestDrcSummary: string = '';
    let mutatedLayout: boolean = false;
    let stagedPending: boolean = false;
    let aggregatedReasoning: string = '';
    let finalAnswer: string = '';

    const emitSnapshot = (liveAns: string): void => {
      callbacks.onProgress(cloneProcessSteps(steps), liveAns, cloneTools(tools));
    };

    try {
      const wireMessages: WireChatMessage[] = [
        { role: 'system', content: DSH_LAYOUT_SYSTEM_PROMPT }
      ];

      if (summary.trim().length > 0) {
        wireMessages.push({
          role: 'user',
          content: `[此前对话摘要参考]\n${summary.trim()}`
        });
      }

      const recentHistory: ChatMessage[] = history.slice(-24);
      for (let i = 0; i < recentHistory.length; i++) {
        const msg: ChatMessage = recentHistory[i];
        if ((msg.role === 'user' || msg.role === 'assistant') && msg.content.trim().length > 0) {
          wireMessages.push({
            role: msg.role === 'user' ? 'user' : 'assistant',
            content: msg.content.substring(0, 12000)
          });
        }
      }

      const initialLayoutSnap: string = host.inspectLayout();
      wireMessages.push({
        role: 'user',
        content: `[当前激活版图实时快照]\n${initialLayoutSnap}\n\n[用户需求]\n${prompt}`
      });

      const toolDefs: OpenAiToolDef[] = buildDshTools(permission);
      const maxTurns: number = 28;
      let lengthRecoveries: number = 0;

      for (let turn = 0; turn < maxTurns; turn++) {
        if (ticket !== this.runSerial || !host.isPageCurrent()) {
          throw new Error('已取消生成');
        }

        let turnThinkStepId: string = '';
        let turnInlineThinkId: string = '';
        callbacks.onStatus(turn === 0 ? '正在连接模型并深度思考…' : `正在进行第 ${turn + 1} 步推理…`);

        const turnOut: SingleTurnModelOutput = await this.streamChatTurn(
          url,
          apiKey,
          config,
          wireMessages,
          toolDefs,
          ticket,
          (liveContent: string, liveReasoning: string, streamingToolNames: string[]): void => {
            if (ticket !== this.runSerial) return;
            const split = splitInlineThinking(liveContent, liveReasoning);
            if (split.thinking.length > 0) {
              if (turnThinkStepId.length === 0) {
                turnThinkStepId = `dsh-think-${++stepSeq}`;
                steps.push({
                  id: turnThinkStepId,
                  kind: 'thinking',
                  title: '思考过程',
                  text: split.thinking,
                  status: 'running'
                });
              } else {
                const idx: number = steps.findIndex((s: AiProcessStep): boolean => s.id === turnThinkStepId);
                if (idx >= 0) {
                  steps[idx].text = split.thinking;
                  steps[idx].status = (split.isStreamingThink || streamingToolNames.length === 0 && split.answer.length === 0)
                    ? 'running'
                    : 'completed';
                }
              }
            }
            if (streamingToolNames.length > 0) {
              callbacks.onStatus(`正在准备工具 ${streamingToolNames[streamingToolNames.length - 1]}…`);
            } else if (split.answer.length > 0) {
              callbacks.onStatus('正在生成回复…');
            } else if (split.thinking.length > 0) {
              callbacks.onStatus(`正在思考（${split.thinking.length} 字）…`);
            }
            emitSnapshot(split.answer);
          }
        );

        // 收拢本轮思考状态
        if (turnThinkStepId.length > 0) {
          const idx: number = steps.findIndex((s: AiProcessStep): boolean => s.id === turnThinkStepId);
          if (idx >= 0) {
            steps[idx].status = 'completed';
          }
        }
        if (turnInlineThinkId.length > 0) {
          const idx2: number = steps.findIndex((s: AiProcessStep): boolean => s.id === turnInlineThinkId);
          if (idx2 >= 0) {
            steps[idx2].status = 'completed';
          }
        }

        const parsedTurn = splitInlineThinking(turnOut.content, turnOut.reasoning);
        if (parsedTurn.thinking.length > 0) {
          aggregatedReasoning += (aggregatedReasoning.length > 0 ? '\n\n' : '') + parsedTurn.thinking;
        }

        // 若模型因长思考触发单轮 max_tokens 截断且尚未发出工具调用，自动提示精简续跑，绝不直接报错中断！
        if (turnOut.finishReason === 'length' && turnOut.toolCalls.length === 0 && lengthRecoveries < 3) {
          lengthRecoveries++;
          wireMessages.push({
            role: 'assistant',
            content: parsedTurn.answer.length > 0 ? parsedTurn.answer : '（思考过程较长，继续执行下一步）',
            reasoning_content: parsedTurn.thinking.length > 0 ? parsedTurn.thinking : undefined
          });
          wireMessages.push({
            role: 'user',
            content: '[系统提示：上一轮输出触及单轮长度上限。请勿重复展开长篇推导，直接调用所需版图工具或输出最终简明结论。]'
          });
          continue;
        }

        // 若没有工具调用，说明本轮已完成最终回答！
        if (turnOut.toolCalls.length === 0) {
          finalAnswer = parsedTurn.answer.trim();
          if (finalAnswer.length === 0 && parsedTurn.thinking.length > 0) {
            finalAnswer = '已完成分析与操作，详情可展开上方「工作过程」查看。';
          }
          emitSnapshot(finalAnswer);
          break;
        }

        // 若在最终工具调用前模型输出了阶段性说明，记为 commentary 步骤
        if (parsedTurn.answer.trim().length > 0) {
          steps.push({
            id: `dsh-note-${++stepSeq}`,
            kind: 'commentary',
            title: '阶段说明',
            text: parsedTurn.answer.trim(),
            status: 'completed'
          });
          emitSnapshot('');
        }

        // 将本轮 assistant 工具调用写入对话上下文（附带 reasoning_content 兼容 DeepSeek Reasoner）
        wireMessages.push({
          role: 'assistant',
          content: parsedTurn.answer.length > 0 ? parsedTurn.answer : null,
          reasoning_content: parsedTurn.thinking.length > 0 ? parsedTurn.thinking : undefined,
          tool_calls: turnOut.toolCalls
        });

        // 逐个执行本轮工具调用并实时刷新 UI 与画布
        for (let ti = 0; ti < turnOut.toolCalls.length; ti++) {
          if (ticket !== this.runSerial || !host.isPageCurrent()) {
            throw new Error('已取消生成');
          }
          const call: WireToolCall = turnOut.toolCalls[ti];
          const toolName: string = call.function.name;
          const rawArgs: string = call.function.arguments || '{}';
          const toolId: string = call.id && call.id.length > 0 ? call.id : `call-${turn}-${ti}`;

          const toolState: AiChatToolState = {
            id: toolId,
            name: toolName === 'todo_write' ? 'write_plan' : toolName,
            status: 'running',
            arguments: rawArgs,
            result: ''
          };
          tools.push(toolState);
          const stepId: string = `dsh-tool-${++stepSeq}`;
          steps.push({
            id: stepId,
            kind: 'tool',
            title: toolName,
            text: '',
            status: 'running',
            tool: toolState
          });
          callbacks.onStatus(`正在执行 ${toolName}…`);
          emitSnapshot('');

          let toolResultJson: string = '';
          let toolOk: boolean = true;
          try {
            const outcome: DshToolExecutionOutcome = await this.dispatchToolCall(
              toolName,
              rawArgs,
              permission,
              host
            );
            toolOk = outcome.success;
            toolResultJson = outcome.payloadJson;
            if (outcome.addedShapes !== undefined && outcome.addedShapes > 0) {
              totalAddedShapes += outcome.addedShapes;
              mutatedLayout = true;
            }
            if (outcome.deletedShapes !== undefined && outcome.deletedShapes > 0) {
              totalDeletedShapes += outcome.deletedShapes;
              mutatedLayout = true;
            }
            if (outcome.addedPorts !== undefined && outcome.addedPorts > 0) {
              totalAddedPorts += outcome.addedPorts;
              mutatedLayout = true;
            }
            if (outcome.drcSummary !== undefined && outcome.drcSummary.length > 0) {
              latestDrcSummary = outcome.drcSummary;
            }
            if (outcome.stagedPending === true) {
              stagedPending = true;
            }
          } catch (toolErr) {
            toolOk = false;
            const errMsg: string = toolErr instanceof Error ? toolErr.message : String(toolErr);
            toolResultJson = JSON.stringify({
              success: false,
              error: errMsg.substring(0, 1200)
            });
          }

          toolState.status = toolOk ? 'completed' : 'failed';
          toolState.result = toolResultJson.substring(0, 15000);
          const sIdx: number = steps.findIndex((s: AiProcessStep): boolean => s.id === stepId);
          if (sIdx >= 0) {
            steps[sIdx].status = toolState.status;
            steps[sIdx].tool = {
              id: toolState.id,
              name: toolState.name,
              status: toolState.status,
              arguments: toolState.arguments,
              result: toolState.result
            };
          }
          emitSnapshot('');

          wireMessages.push({
            role: 'tool',
            tool_call_id: call.id,
            content: toolResultJson.substring(0, 14000)
          });

          // 若处于审阅确认模式且已生成待确认方案，让模型总结方案并暂停等待用户点击确认
          if (stagedPending) {
            break;
          }
        }

        if (stagedPending) {
          finalAnswer = '已生成版图修改预览方案（见下方待确认卡片），确认后将作为单次可撤销操作写入当前版图。';
          emitSnapshot(finalAnswer);
          break;
        }
      }

      if (finalAnswer.trim().length === 0) {
        finalAnswer = mutatedLayout
          ? '已完成版图绘制与检查，详情见上方工作过程与画布视图。'
          : '已完成本次任务，详情见上方工作过程。';
      }

      const changeParts: string[] = [];
      if (totalAddedShapes > 0) changeParts.push(`+${totalAddedShapes} 图元`);
      if (totalDeletedShapes > 0) changeParts.push(`-${totalDeletedShapes} 图元`);
      if (totalAddedPorts > 0) changeParts.push(`+${totalAddedPorts} 端口`);
      if (latestDrcSummary.length > 0) changeParts.push(latestDrcSummary);
      const turnChangeSummary: string = changeParts.length > 0 ? `本轮版图变更：${changeParts.join(' · ')}` : '';

      return {
        finalAnswer,
        fullReasoning: aggregatedReasoning,
        steps: cloneProcessSteps(steps),
        tools: cloneTools(tools),
        mutatedLayout,
        stagedPending,
        turnChangeSummary
      };
    } finally {
      this.running = false;
      this.activeAbort = null;
    }
  }

  private async dispatchToolCall(
    toolName: string,
    rawArgs: string,
    permission: DshPermissionMode,
    host: DshLayoutBackendHost
  ): Promise<DshToolExecutionOutcome> {
    let args: Record<string, Object> = {};
    if (rawArgs.trim().length > 0) {
      try {
        const parsed: Object = JSON.parse(rawArgs) as Object;
        if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
          args = parsed as Record<string, Object>;
        }
      } catch (e) {
        throw new Error(`工具参数 JSON 解析失败：${e instanceof Error ? e.message : String(e)}`);
      }
    }

    switch (toolName) {
      case 'inspect_layout': {
        const snap: string = host.inspectLayout();
        return { success: true, summary: '已读取当前版图摘要', payloadJson: snap };
      }
      case 'query_layout': {
        const res: string = await host.queryLayout(JSON.stringify(args));
        return { success: true, summary: '已查询版图明细', payloadJson: res };
      }
      case 'todo_write': {
        const todosObj: Object | undefined = args['todos'];
        const count: number = Array.isArray(todosObj) ? (todosObj as Object[]).length : 0;
        return {
          success: true,
          summary: `已更新 ${count} 项任务计划`,
          payloadJson: JSON.stringify({ success: true, planSteps: count, todos: todosObj ?? [] })
        };
      }
      case 'list_native_tools': {
        const cat: string = typeof args['category'] === 'string' ? (args['category'] as string) : '';
        const off: number = typeof args['offset'] === 'number' && Number.isInteger(args['offset']) ? (args['offset'] as number) : 0;
        const tn: string = typeof args['toolName'] === 'string' ? (args['toolName'] as string) : '';
        const catalogJson: string = host.listNativeTools(cat, off, tn);
        return { success: true, summary: '已读取原生工具目录', payloadJson: catalogJson };
      }
      case 'run_drc': {
        return await host.runDrcCheck();
      }
      case 'create_cmos_inverter': {
        if (permission === 'readonly') {
          throw new Error('当前处于「只读问答」权限模式，无法绘制版图；请在输入框左下角切换为「自动执行」或「审阅确认」。');
        }
        const rawCell: string = typeof args['cellName'] === 'string' && (args['cellName'] as string).trim().length > 0
          ? (args['cellName'] as string).trim()
          : 'INVERTER';
        const safeCell: string = /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(rawCell) ? rawCell : 'INVERTER';
        const gl: number = typeof args['gateLengthNm'] === 'number' ? Math.round(args['gateLengthNm'] as number) : 200;
        const nw: number = typeof args['nmosWidthNm'] === 'number' ? Math.round(args['nmosWidthNm'] as number) : 600;
        const pw: number = typeof args['pmosWidthNm'] === 'number' ? Math.round(args['pmosWidthNm'] as number) : 1200;
        const tgtRaw: string = typeof args['target'] === 'string' ? (args['target'] as string) : 'auto';
        const target: 'auto' | 'current_cell' | 'new_tab' =
          (tgtRaw === 'current_cell' || tgtRaw === 'new_tab') ? tgtRaw : 'auto';
        return await host.createCmosInverter({
          cellName: safeCell,
          gateLengthNm: Math.min(100000, Math.max(50, gl)),
          nmosWidthNm: Math.min(100000, Math.max(100, nw)),
          pmosWidthNm: Math.min(100000, Math.max(100, pw)),
          target
        }, permission);
      }
      case 'edit_layout': {
        if (permission === 'readonly') {
          throw new Error('当前处于「只读问答」权限模式，无法修改版图；请在输入框左下角切换为「自动执行」或「审阅确认」。');
        }
        const opsRaw: Object | undefined = args['operations'];
        if (!Array.isArray(opsRaw) || (opsRaw as Object[]).length === 0 || (opsRaw as Object[]).length > 256) {
          throw new Error('operations 必须包含 1 到 256 项操作');
        }
        return await host.editLayout(opsRaw as DshEditOperation[], permission);
      }
      case 'call_native_tool': {
        const name: string = typeof args['name'] === 'string' ? (args['name'] as string).trim() : '';
        if (name.length === 0) {
          throw new Error('请提供要调用的原生工具名称 name');
        }
        const subArgs: Object | undefined = args['arguments'];
        return await host.callNativeTool(name, subArgs === undefined ? '{}' : JSON.stringify(subArgs), permission);
      }
      case 'execute_klayout_python': {
        if (permission === 'readonly') {
          throw new Error('当前处于「只读问答」权限模式，无法执行生成脚本。');
        }
        const script: string = typeof args['script'] === 'string' ? (args['script'] as string) : '';
        if (script.trim().length === 0) {
          throw new Error('script 不能为空');
        }
        const modeRaw: string = typeof args['applyMode'] === 'string' ? (args['applyMode'] as string) : 'replace';
        const applyMode: 'replace' | 'merge' = modeRaw === 'merge' ? 'merge' : 'replace';
        if (permission === 'review') {
          return await host.callNativeTool('python.run', JSON.stringify({ script, inputMode: 'document', applyMode, parameters: '{}' }), permission);
        }
        return await host.executeKlayoutPython(script, applyMode);
      }
      default:
        throw new Error(`未知工具 ${toolName}，请从已提供的工具列表中选择`);
    }
  }

  private streamChatTurn(
    url: string,
    apiKey: string,
    config: AiModelConfig,
    messages: WireChatMessage[],
    tools: OpenAiToolDef[],
    ticket: number,
    onLiveUpdate: (content: string, reasoning: string, streamingToolNames: string[]) => void
  ): Promise<SingleTurnModelOutput> {
    const windowTokens: number = config.contextWindowTokens ?? 65536;
    const minThinkingOut: number = windowTokens >= 200000 ? 32768 : (windowTokens >= 65536 ? 16384 : 8192);
    const effectiveMaxOut: number = Math.min(
      Math.max(config.maxTokens, minThinkingOut),
      Math.max(2048, windowTokens - 8192)
    );
    const modelLower: string = config.modelName.toLowerCase();
    const effort: string = config.reasoningEffort ?? 'auto';

    const payload: WireChatRequest = {
      model: config.modelName,
      messages,
      tools,
      tool_choice: 'auto',
      stream: true,
      temperature: config.temperature
    };

    if (/^(?:o[134](?:-|$)|gpt-[56](?:[.-]|$))/.test(modelLower)) {
      payload.max_completion_tokens = effectiveMaxOut;
    } else {
      payload.max_tokens = effectiveMaxOut;
    }

    if (effort !== 'auto') {
      if (effort === 'none') {
        if (modelLower.includes('deepseek')) {
          payload.thinking = { type: 'disabled' };
        } else if (modelLower.includes('qwen3') || modelLower.includes('glm-4')) {
          payload.enable_thinking = false;
        }
      } else if (/(?:o[134]|gpt-[56]|deepseek|qwen3|qwq|glm|claude|gemini|bunny)/.test(modelLower)) {
        payload.reasoning_effort = effort;
      }
    }

    const requestBody: string = JSON.stringify(payload);

    return new Promise<SingleTurnModelOutput>((resolve, reject) => {
      const request: http.HttpRequest = http.createHttp();
      const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
      let finished: boolean = false;
      let statusCode: number = 0;
      let buffer: string = '';
      let nonSseErrorBody: string = '';
      let sawSseFrame: boolean = false;
      let doneMarkerSeen: boolean = false;

      let contentAcc: string = '';
      let reasoningAcc: string = '';
      let finishReason: string = '';
      const toolAccs: StreamToolCallAccumulator[] = [];

      let silenceTimer: number = -1;
      let graceTimer: number = -1;
      const silenceBudgetMs: number = Math.max(600000, config.timeoutMs);

      const cleanup = (): void => {
        clearTimeout(silenceTimer);
        clearTimeout(graceTimer);
        if (this.activeAbort !== null) {
          this.activeAbort = null;
        }
        try {
          request.off('headersReceive');
          request.off('dataReceive');
          request.off('dataEnd');
          request.destroy();
        } catch (_) {}
      };

      const buildFinalOutput = (): SingleTurnModelOutput => {
        toolAccs.sort((a: StreamToolCallAccumulator, b: StreamToolCallAccumulator): number => a.index - b.index);
        const builtCalls: WireToolCall[] = [];
        for (let i = 0; i < toolAccs.length; i++) {
          const acc: StreamToolCallAccumulator = toolAccs[i];
          if (acc.name.trim().length > 0) {
            builtCalls.push({
              id: acc.id.length > 0 ? acc.id : `call_${Date.now()}_${i}`,
              type: 'function',
              function: {
                name: acc.name.trim(),
                arguments: acc.argumentsText.trim().length > 0 ? acc.argumentsText : '{}'
              }
            });
          }
        }
        return {
          content: contentAcc,
          reasoning: reasoningAcc,
          finishReason: finishReason.length > 0 ? finishReason : 'stop',
          toolCalls: builtCalls
        };
      };

      const finishSuccess = (): void => {
        if (finished) return;
        finished = true;
        cleanup();
        resolve(buildFinalOutput());
      };

      const failTurn = (msg: string): void => {
        if (finished) return;
        if ((doneMarkerSeen || finishReason.length > 0) && (statusCode === 200 || statusCode === 0) &&
          (contentAcc.length > 0 || reasoningAcc.length > 0 || toolAccs.length > 0)) {
          finishSuccess();
          return;
        }
        finished = true;
        cleanup();
        const safeMsg: string = apiKey.length >= 4 ? msg.split(apiKey).join('***') : msg;
        reject(new Error(safeMsg));
      };

      const resetSilenceTimer = (): void => {
        clearTimeout(silenceTimer);
        silenceTimer = setTimeout((): void => {
          failTurn('模型服务超过 10 分钟无响应数据包，已停止等待；请检查网络或切换模型后重试');
        }, silenceBudgetMs);
      };

      this.activeAbort = (): void => {
        failTurn('已取消生成');
      };

      const parseHttpErrorDetail = (code: number, raw: string): string => {
        let extracted: string = '';
        if (raw.trim().length > 0) {
          try {
            const obj: Record<string, Object> = JSON.parse(raw.trim()) as Record<string, Object>;
            const errObj: Object | undefined = obj['error'];
            if (typeof errObj === 'string') {
              extracted = errObj;
            } else if (errObj !== null && typeof errObj === 'object') {
              const msgField: Object | undefined = (errObj as Record<string, Object>)['message'];
              if (typeof msgField === 'string') extracted = msgField;
            } else if (typeof obj['message'] === 'string') {
              extracted = obj['message'] as string;
            }
          } catch (_) {
            extracted = raw.trim().substring(0, 180);
          }
        }
        const suffix: string = extracted.length > 0 ? `（${extracted.substring(0, 180)}）` : '';
        if (code === 401 || code === 403) {
          return `模型 API 鉴权失败（HTTP ${code}）${suffix}，请打开右上角设置检查 API Key 与模型权限`;
        }
        if (code === 404) {
          return `模型或接口路径不存在（HTTP ${code}）${suffix}，请检查 API 地址与模型 ID（${config.modelName}）`;
        }
        if (code === 429) {
          return `模型服务触发限流或配额不足（HTTP 429）${suffix}，请稍后重试或切换其他模型`;
        }
        return `模型服务返回 HTTP ${code}${suffix}`;
      };

      const consumePacketJson = (jsonStr: string): void => {
        let packet: Record<string, Object>;
        try {
          packet = JSON.parse(jsonStr) as Record<string, Object>;
        } catch (_) {
          return;
        }
        const errField: Object | undefined = packet['error'];
        if (errField !== undefined && errField !== null) {
          const errText: string = typeof errField === 'string'
            ? errField
            : (typeof (errField as Record<string, Object>)['message'] === 'string'
              ? ((errField as Record<string, Object>)['message'] as string)
              : JSON.stringify(errField));
          failTurn(`模型返回错误：${errText.substring(0, 240)}`);
          return;
        }

        const choicesObj: Object | undefined = packet['choices'];
        if (!Array.isArray(choicesObj) || (choicesObj as Object[]).length === 0) {
          return;
        }
        const choice: Record<string, Object> = (choicesObj as Object[])[0] as Record<string, Object>;
        const deltaObj: Object | undefined = choice['delta'] ?? choice['message'];
        if (deltaObj !== null && deltaObj !== undefined && typeof deltaObj === 'object') {
          const delta: Record<string, Object> = deltaObj as Record<string, Object>;
          if (typeof delta['reasoning_content'] === 'string' && (delta['reasoning_content'] as string).length > 0) {
            reasoningAcc += delta['reasoning_content'] as string;
          } else if (typeof delta['reasoning'] === 'string' && (delta['reasoning'] as string).length > 0) {
            reasoningAcc += delta['reasoning'] as string;
          }
          if (typeof delta['content'] === 'string' && (delta['content'] as string).length > 0) {
            contentAcc += delta['content'] as string;
          }
          const tcList: Object | undefined = delta['tool_calls'];
          if (Array.isArray(tcList)) {
            const arr: Object[] = tcList as Object[];
            for (let k = 0; k < arr.length; k++) {
              const tcItem: Record<string, Object> = arr[k] as Record<string, Object>;
              const tcIdx: number = typeof tcItem['index'] === 'number' ? (tcItem['index'] as number) : k;
              let acc: StreamToolCallAccumulator | undefined =
                toolAccs.find((item: StreamToolCallAccumulator): boolean => item.index === tcIdx);
              if (acc === undefined) {
                acc = { index: tcIdx, id: '', name: '', argumentsText: '' };
                toolAccs.push(acc);
              }
              if (typeof tcItem['id'] === 'string' && (tcItem['id'] as string).length > 0) {
                acc.id = tcItem['id'] as string;
              }
              const fnObj: Object | undefined = tcItem['function'];
              if (fnObj !== null && fnObj !== undefined && typeof fnObj === 'object') {
                const fnRec: Record<string, Object> = fnObj as Record<string, Object>;
                if (typeof fnRec['name'] === 'string' && (fnRec['name'] as string).length > 0) {
                  acc.name += fnRec['name'] as string;
                }
                if (typeof fnRec['arguments'] === 'string' && (fnRec['arguments'] as string).length > 0) {
                  acc.argumentsText += fnRec['arguments'] as string;
                }
              }
            }
          }
        }

        if (typeof choice['finish_reason'] === 'string' && (choice['finish_reason'] as string).length > 0) {
          finishReason = choice['finish_reason'] as string;
        }

        const activeNames: string[] = toolAccs
          .map((a: StreamToolCallAccumulator): string => a.name.trim())
          .filter((n: string): boolean => n.length > 0);
        onLiveUpdate(contentAcc, reasoningAcc, activeNames);
      };

      const consumeLine = (rawLine: string): void => {
        if (finished || ticket !== this.runSerial) return;
        const trimmed: string = rawLine.trim();
        if (trimmed.length === 0 || trimmed.startsWith(':') || /^(?:event|id|retry):/i.test(trimmed)) {
          return;
        }
        if (!trimmed.startsWith('data:')) {
          if (!sawSseFrame && nonSseErrorBody.length < 4096) {
            nonSseErrorBody += (nonSseErrorBody.length > 0 ? '\n' : '') + trimmed;
          }
          return;
        }
        sawSseFrame = true;
        const dataPart: string = trimmed.substring(5).trim();
        if (dataPart === '[DONE]') {
          doneMarkerSeen = true;
          clearTimeout(silenceTimer);
          graceTimer = setTimeout((): void => {
            if (!finished && (statusCode === 200 || statusCode === 0)) {
              finishSuccess();
            }
          }, 400);
          return;
        }
        consumePacketJson(dataPart);
      };

      resetSilenceTimer();

      request.on('headersReceive', (headers: Object): void => {
        resetSilenceTimer();
        if (headers !== null && typeof headers === 'object') {
          const rec: Record<string, Object> = headers as Record<string, Object>;
          const st: Object | undefined = rec['status'] ?? rec[':status'];
          if (typeof st === 'string' || typeof st === 'number') {
            const parsedCode: number = Number(st);
            if (Number.isFinite(parsedCode) && parsedCode >= 100) {
              statusCode = parsedCode;
            }
          }
        }
      });

      request.on('dataReceive', (chunk: ArrayBuffer): void => {
        if (finished || ticket !== this.runSerial) return;
        resetSilenceTimer();
        buffer += decoder.decodeToString(new Uint8Array(chunk), { stream: true });
        if (buffer.length > 8 * 1024 * 1024) {
          failTurn('单轮模型流式数据超出 8 MiB 安全上限');
          return;
        }
        let nl: number = buffer.indexOf('\n');
        while (nl >= 0 && !finished) {
          const line: string = buffer.substring(0, nl);
          buffer = buffer.substring(nl + 1);
          consumeLine(line);
          nl = buffer.indexOf('\n');
        }
      });

      request.on('dataEnd', (): void => {
        if (finished) return;
        buffer += decoder.decodeToString(new Uint8Array(0));
        if (buffer.trim().length > 0) {
          const lines: string[] = buffer.split('\n');
          for (let i = 0; i < lines.length; i++) {
            consumeLine(lines[i]);
          }
          buffer = '';
        }
        if (statusCode !== 0 && statusCode !== 200) {
          failTurn(parseHttpErrorDetail(statusCode, nonSseErrorBody));
          return;
        }
        // 兼容未按 SSE 返回而直接返回完整 JSON 的网关
        if (!sawSseFrame && nonSseErrorBody.trim().startsWith('{')) {
          consumePacketJson(nonSseErrorBody.trim());
        }
        if (contentAcc.length === 0 && reasoningAcc.length === 0 && toolAccs.length === 0) {
          failTurn(nonSseErrorBody.trim().length > 0
            ? parseHttpErrorDetail(statusCode || 500, nonSseErrorBody)
            : '模型未返回任何有效内容或工具调用，请检查模型兼容性');
          return;
        }
        finishSuccess();
      });

      const headers: Record<string, string> = {
        'Content-Type': 'application/json',
        'Accept': 'text/event-stream'
      };
      if (apiKey.length > 0) {
        headers['Authorization'] = `Bearer ${apiKey}`;
      }

      request.requestInStream(url, {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: requestBody,
        connectTimeout: 20000,
        readTimeout: 1800000
      }).then((code: number): void => {
        statusCode = code;
        if (code !== 200) {
          failTurn(parseHttpErrorDetail(code, nonSseErrorBody));
        } else if (doneMarkerSeen && !finished) {
          finishSuccess();
        }
      }).catch((err: Error): void => {
        failTurn(`连接模型服务失败：${err.message || String(err)}（请检查网络或 API 地址）`);
      });
    });
  }
}

export const dshLayoutAgentService: DshLayoutAgentService = new DshLayoutAgentService();
