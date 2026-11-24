/**
 * DSH 原生直连全能视觉 Harness Agent 调度引擎 + 鸿图全软件能力桥接器
 *
 * 核心升级（v8 Full Visual Harness & On-Device Python）：
 * 1. 全软件权限覆盖（19 项一级工具 + 195 项原生目录工具）：
 *    - 图层全生命周期（manage_layers）：新建、删除图层（含一键连带清理图元并可撤销）、删除全部空层、清空图层、重命名、配色填充样式、显隐/锁定/可选、批量状态、跨层复制移动、布尔层表达式；
 *    - 单元与层级（manage_cells）：新建、删除、重命名、复制副本、清空、进入/退回父级/回顶层、设为主顶层、选区打包子单元、放置 SREF 与 GDSII AREF 行列阵列、扁平化展开、孤立单元扫描清理；
 *    - 全几何与精确锚点编辑（edit_layout）：矩形、多边形、正多边形、圆、椭圆、圆环、圆弧、路径（含线宽/端头/延伸）、文本、阵列、平移/旋转/镜像/缩放/复制/删除、改层、三基准锚点精确设界（中心/左下/四角）、顶点编辑、偏置缩放、倒圆角、对齐分布、Clipper2 布尔运算；
 *    - 端口、PCell 与自动布线（manage_ports_and_routing）：端口增删改查、标签提取端口、端口对齐互连、曼哈顿/光学避障自动布线、PCell 与器件库放置；
 *    - 物理验证与工作台（manage_verification / manage_workbench）：DRC、违规聚焦、规则配置、网表追踪提取、LVS、豁免捕获、撤销/重做、选区过滤、多标签页管理、精度与视图书签、宏运行；
 * 2. 现代视觉 Harness 闭环（capture_screenshot + inspect_workbench_ui + automate_workbench_ui）：
 *    - Agent 可自主对整个软件窗口、画布视口或高精度版图光栅化执行实时截图，并将 PNG 视觉帧自动回注多模态推理上下文（非视觉文本模型自动平滑降级为结构化视觉遥测，绝不报错中断）；
 *    - Agent 可直接读取并自动化操控软件 UI（切换模块、切换编辑/查看模式、激活绘图工具、开关任意面板/侧栏/检查器、控制相机缩放平移定位、模拟画布点击与框选、添加标尺、执行命令面板动作，并支持操作后自动复检截图）；
 * 3. 端侧内置完整 Python 3 引擎（execute_klayout_python）：
 *    - 直接调用编译在 libhongtu.so 内的端侧原生 Python 3 虚拟机（PocketPy 2.2.0 / CPython 动态层 + Clipper2 Region + 原生 GDSII），无需任何外部桌面伴随进程即可离线执行参数化版图生成与文档级修改；
 * 4. 实时联网检索（web_search / web_fetch）、交互式向用户提问（ask_user 原地挂起恢复）与多模态图片/文件附件读写导出（manage_attachments_and_files）。
 */
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { AiProvider } from './AiService';
import type {
  AiAskUserExchange,
  AiAskUserOption,
  AiChatAttachment,
  AiChatToolState,
  AiModelConfig,
  AiProcessStep,
  ChatMessage
} from './AiService';
import { aiAttachmentService } from './AiAttachmentService';
import { dshWebSearchService } from './DshWebSearchService';
import type { DshWebFetchResponse, DshWebSearchItem, DshWebSearchResponse } from './DshWebSearchService';
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
  targetLayer?: number;
  targetDatatype?: number;
  layerName?: string;
  x?: number;
  y?: number;
  x2?: number;
  y2?: number;
  width?: number;
  height?: number;
  radiusNm?: number;
  innerRadiusNm?: number;
  radiusXNm?: number;
  radiusYNm?: number;
  startAngleDeg?: number;
  endAngleDeg?: number;
  sides?: number;
  segments?: number;
  points?: Array<Record<string, number>>;
  pathWidth?: number;
  pathType?: number;
  beginExtNm?: number;
  endExtNm?: number;
  text?: string;
  shapeId?: number;
  shapeIds?: number[];
  vertexIndex?: number;
  anchor?: 'center' | 'bottom_left' | 'corners';
  rows?: number;
  cols?: number;
  spacingX?: number;
  spacingY?: number;
  dx?: number;
  dy?: number;
  offsetNm?: number;
  degrees?: number;
  horizontal?: boolean;
  scale?: number;
  centerX?: number;
  centerY?: number;
  alignMode?: string;
  booleanOp?: 'merge' | 'subtract' | 'intersect' | 'xor';
  keepSources?: boolean;
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
  visualAttachment?: AiChatAttachment;
  generatedAttachment?: AiChatAttachment;
}

export interface DshAskUserPromptParams {
  question: string;
  header: string;
  options: AiAskUserOption[];
  allowMultiple: boolean;
  placeholder: string;
}

export interface DshLayoutBackendHost {
  isPageCurrent: () => boolean;
  inspectLayout: () => string;
  queryLayout: (argsJson: string) => Promise<string>;
  inspectWorkbenchUi: () => string;
  captureScreenshot: (argsJson: string) => Promise<DshToolExecutionOutcome>;
  automateWorkbenchUi: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  askUser: (params: DshAskUserPromptParams) => Promise<AiAskUserExchange>;
  manageLayers: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  manageCells: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  createCmosInverter: (params: DshCmosInverterParams, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  editLayout: (operations: DshEditOperation[], permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  managePortsAndRouting: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  manageVerification: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  manageWorkbench: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  manageAttachmentsAndFiles: (argsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  runDrcCheck: () => Promise<DshToolExecutionOutcome>;
  listNativeTools: (category: string, offset: number, toolName: string) => string;
  callNativeTool: (toolName: string, argumentsJson: string, permission: DshPermissionMode) => Promise<DshToolExecutionOutcome>;
  executeKlayoutPython: (script: string, applyMode: 'replace' | 'merge' | 'preview' | 'inspect', inputMode?: 'new' | 'document' | 'selection', parametersJson?: string) => Promise<DshToolExecutionOutcome>;
}

export interface DshAgentRunCallbacks {
  onStatus: (statusText: string) => void;
  onProgress: (steps: AiProcessStep[], liveAnswer: string, tools: AiChatToolState[]) => void;
}

export interface DshAgentRunOptions {
  userAttachments?: AiChatAttachment[];
  webSearchEnabled?: boolean;
}

export interface DshAgentRunResult {
  finalAnswer: string;
  fullReasoning: string;
  steps: AiProcessStep[];
  tools: AiChatToolState[];
  mutatedLayout: boolean;
  stagedPending: boolean;
  turnChangeSummary: string;
  webSources: DshWebSearchItem[];
  generatedAttachments: AiChatAttachment[];
  askUserExchanges: AiAskUserExchange[];
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

interface WireImageUrlField {
  url: string;
}

interface WireContentPart {
  type: 'text' | 'image_url';
  text?: string;
  image_url?: WireImageUrlField;
}

interface WireChatMessage {
  role: 'system' | 'user' | 'assistant' | 'tool';
  content: string | WireContentPart[] | null;
  fallbackText?: string;
  reasoning_content?: string;
  tool_calls?: WireToolCall[];
  tool_call_id?: string;
}

interface WireThinkingConfig {
  type: string;
}

interface WireChatRequest {
  model: string;
  messages: Object[];
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

interface PendingVisualObservation {
  summary: string;
  attachment: AiChatAttachment;
}

interface SingleTurnModelOutput {
  content: string;
  reasoning: string;
  finishReason: string;
  toolCalls: WireToolCall[];
}

class MultimodalUnsupportedError extends Error {
  constructor(message: string) {
    super(message);
  }
}

const DSH_LAYOUT_SYSTEM_PROMPT: string =
  '你是鸿图 (HongTu EDA) 全能集成电路与光子版图智能体 (Visual Harness Agent)，拥有对鸿图软件全部功能的直接操控权限。\n' +
  '核心工作准则：\n' +
  '1. 【读取与自检先行】分析或修改前，优先调用 inspect_layout / query_layout / inspect_workbench_ui 获取真实图层、Cell、坐标与界面状态，绝不凭空猜测。\n' +
  '2. 【自主截图视觉巡检 (Visual Harness)】当完成复杂版图绘制、自动布线、多层叠对、视角切换，或用户询问“界面现在长什么样 / 检查当前工作情况”时，主动调用 capture_screenshot 对当前画布或整个工作台窗口截图，亲自查看视觉效果并闭环修正。\n' +
  '3. 【全软件权限与 UI 自动化】你拥有完整软件操作能力：\n' +
  '   - 图层管理：直接调用 manage_layers 新建图层、删除指定图层（delete）、清理空图层（delete_empty）、清空图层图元（clear）、重命名、修改颜色与填充样式、批量显隐锁定、跨层复制移动或执行布尔层运算；\n' +
  '   - 单元与层级：直接调用 manage_cells 新建/删除/重命名/复制 Cell、进入或退回顶层、放置单实例(SREF)或 GDSII 行列阵列(AREF)、扁平化展开；\n' +
  '   - 几何与精确锚点编辑：调用 edit_layout 绘制矩形/多边形/圆/圆环/圆弧/路径/文本、三基准锚点(center/bottom_left/corners)精确设界、Clipper2 布尔运算、尺寸偏置、倒圆角、对齐分布与顶点编辑（坐标单位均为 nm）；\n' +
  '   - 端侧内置 Python 3 引擎：调用 execute_klayout_python 可直接在鸿蒙端侧内置 Python 3 虚拟机中离线运行 import hongtu as db / import klayout.db as db / import pya 及 db.Region 布尔脚本，无需任何外部桌面伴随服务；\n' +
  '   - 自动化操控软件界面：调用 automate_workbench_ui 可自动切换工作台模块、编辑/查看模式、绘图工具、开关任意面板/侧栏、操控相机缩放聚焦、模拟画布点选/框选并自动复检截图。\n' +
  '4. 【主动澄清 ask_user】当工艺参数、层号、尺寸规格或删除范围存在关键歧义时，调用 ask_user 弹出结构化单选/多选卡片向用户确认，收到答复后立即继续执行。\n' +
  '5. 【按需联网检索】仅当用户明确要求搜索网络，或涉及外部 PDK 设计标准、器件论文参数、公开 EDA/鸿蒙技术文档时才调用 web_search 与 web_fetch（纯本地版图盘点、修改与 DRC 检查严禁无故触发联网搜索），引用外部资料时附带 Markdown 可点击链接 [来源标题](URL)。\n' +
  '6. 【附件与产物交付】用户上传或粘贴的图片、GDSII/OASIS 版图、网表与代码文件可通过 manage_attachments_and_files 读取或导入画布；需要向用户交付 PNG/SVG 截图、GDSII/OASIS 版图或 SPICE 网表文件时，调用 manage_attachments_and_files(action="export_deliverable_to_chat") 直接生成带一键复制与另存按钮的对话文件卡片。';

function buildDshTools(permission: DshPermissionMode, webSearchEnabled: boolean): OpenAiToolDef[] {
  const parseSchema = (raw: string): Object => JSON.parse(raw) as Object;
  const tools: OpenAiToolDef[] = [
    {
      type: 'function',
      function: {
        name: 'inspect_layout',
        description: '读取当前激活版图文档的完整摘要，包括文档名、顶层与当前 Cell、DBU(nm)、图层列表（含显隐/锁定/图元数）、图形总数、选中图形、端口数量、DRC 状态、工作区标签页及端侧内置 Python 引擎状态。',
        parameters: parseSchema('{"type":"object","properties":{},"additionalProperties":false}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'query_layout',
        description: '分页查询当前版图的真实对象明细（shapes 图形坐标、cells 层级树、ports 端口、drc 违规项、rules 设计规则）。坐标单位均为 nm。',
        parameters: parseSchema('{"type":"object","properties":{"kind":{"type":"string","enum":["shapes","cells","ports","drc","rules"]},"cellId":{"type":"integer","minimum":0},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"offset":{"type":"integer","minimum":0},"limit":{"type":"integer","minimum":1,"maximum":64}},"required":["kind"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'inspect_workbench_ui',
        description: '读取鸿图软件当前完整的 UI 工作台状态，包括窗口尺寸、深浅色主题、当前工作模块、编辑/查看模式、激活绘图工具、所有面板/侧栏/检查器开关状态、画布相机视口世界坐标范围(nm)、缩放百分比、展开层级深度、网格/磁吸配置、标尺及可执行命令列表。',
        parameters: parseSchema('{"type":"object","properties":{},"additionalProperties":false}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'capture_screenshot',
        description: '【视觉 Harness 自检截图】对当前软件界面或版图画布执行实时截图，并将高清 PNG 图像回注到你的视觉上下文中供你亲自查看当前绘制效果、图层叠对、DRC 标记与工作情况；同时可选择在对话中展示截图卡片。target 支持 workbench_window（整个软件窗口）、canvas_viewport（当前画布视口含叠加层）、layout_render（高精度版图光栅化 PNG）。',
        parameters: parseSchema('{"type":"object","properties":{"target":{"type":"string","enum":["canvas_viewport","workbench_window","layout_render"],"default":"canvas_viewport"},"widthPx":{"type":"integer","minimum":320,"maximum":4096,"default":1280},"heightPx":{"type":"integer","minimum":240,"maximum":4096,"default":900},"showInChat":{"type":"boolean","default":true},"fitBeforeCapture":{"type":"boolean","default":false}}}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'todo_write',
        description: '创建或更新当前会话的分步任务执行计划清单，实时展示在底部任务进度坞中。',
        parameters: parseSchema('{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"content":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["todos"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'ask_user',
        description: '向用户发起结构化交互提问（单选、多选或自由输入），原地挂起当前推理循环并等待用户点击选项或填写答复后无缝继续执行。',
        parameters: parseSchema('{"type":"object","properties":{"header":{"type":"string","description":"简短卡片标题（如 工艺参数确认 / 删除图层确认）"},"question":{"type":"string","description":"向用户询问的具体问题"},"options":{"type":"array","maxItems":6,"items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"]}},"allowMultiple":{"type":"boolean","default":false},"placeholder":{"type":"string","default":"或直接输入自定义要求…"}},"required":["question"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'list_native_tools',
        description: '检索鸿图内置的全部 195 项原生专业工具目录（如 layers、cell、instance、geometry、pcells、ports、route、verification、view、workspace、macro），传入 toolName 可读取精确 JSON 参数 schema。',
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

  if (webSearchEnabled) {
    tools.push(
      {
        type: 'function',
        function: {
          name: 'web_search',
          description: '仅当需要查询外部公开技术规范、PDK 标准、论文参数或用户明确要求联网检索时调用；纯本地版图检查与几何编辑请勿调用。返回标题、摘要与真实可点击 URL。',
          parameters: parseSchema('{"type":"object","properties":{"query":{"type":"string"},"maxResults":{"type":"integer","minimum":1,"maximum":10,"default":6}},"required":["query"]}')
        }
      },
      {
        type: 'function',
        function: {
          name: 'web_fetch',
          description: '抓取并提取指定公开网页（http/https）的正文内容，用于核实搜索结果中的具体指标、公式或文档细节。',
          parameters: parseSchema('{"type":"object","properties":{"url":{"type":"string"},"maxChars":{"type":"integer","minimum":500,"maximum":24000,"default":10000}},"required":["url"]}')
        }
      }
    );
  }

  tools.push({
    type: 'function',
    function: {
      name: 'manage_attachments_and_files',
      description: '管理对话中的多模态图片/文件附件与版图文件交付：list_attachments(列出当前对话附件)、read_attachment_text(读取文本/代码/SPICE/DRC/RDB附件全文)、inspect_attachment_image(将附图载入视觉上下文查看)、import_attachment_layout(将用户附带的 GDSII/OASIS 版图打开到新标签页或合并入当前版图)、export_deliverable_to_chat(将当前版图导出为 png/svg/gds/oas/spice/markdown 文件卡片发到对话框供用户一键复制或另存)、copy_to_clipboard(将指定附件或文本复制到系统剪贴板)。',
      parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["list_attachments","read_attachment_text","inspect_attachment_image","import_attachment_layout","export_deliverable_to_chat","copy_to_clipboard"]},"attachmentId":{"type":"string"},"format":{"type":"string","enum":["png","svg","gds","oas","spice","markdown","json"]},"fileName":{"type":"string"},"content":{"type":"string"},"importMode":{"type":"string","enum":["new_tab","merge"],"default":"new_tab"},"widthPx":{"type":"integer","minimum":256,"maximum":4096,"default":1600},"heightPx":{"type":"integer","minimum":256,"maximum":4096,"default":1200},"maxChars":{"type":"integer","minimum":256,"maximum":32000,"default":12000},"offsetChars":{"type":"integer","minimum":0,"default":0}},"required":["action"]}')
    }
  });

  tools.push({
    type: 'function',
    function: {
      name: 'automate_workbench_ui',
      description: '自动化操控鸿图软件界面、工具栏、面板、相机视角与画布交互（支持单步或批量连续动作）。step.action 支持：switch_module(module: layout|verification|data)、set_view_mode(mode: edit|viewer)、select_tool(tool: select|rect|polygon|path|text|measure|zoom_box)、toggle_panel(panel: sidebar|inspector|drc_dock|verification|lvs|python|macro|library|technology|layer_stack|compare|rdb_review|search|project|view_workspace|shortcuts|layer_style, open: boolean)、camera(op: fit_all|reset_view|zoom_to|pan_by|focus_world_box|focus_shape|focus_violation|set_hierarchy_depth, zoomPercent, dxPx, dyPx, minX, minY, maxX, maxY, shapeId, violationIndex, depth)、canvas_click_world(x, y, additive)、canvas_box_select_world(minX, minY, maxX, maxY, encloseOnly)、ruler(op: add|clear_all, vertical, positionNm)、set_grid_and_snap(gridVisible, gridSize, snapEnabled, routingMode: manhattan_90|octilinear_45|free_angle)、set_theme(theme: light|dark|system)、execute_command(commandId)。可设 captureAfter=true 在自动化操作完成后自动截图验视。',
      parameters: parseSchema('{"type":"object","properties":{"steps":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"object","properties":{"action":{"type":"string","enum":["switch_module","set_view_mode","select_tool","toggle_panel","camera","canvas_click_world","canvas_box_select_world","ruler","set_grid_and_snap","set_theme","execute_command"]},"module":{"type":"string"},"mode":{"type":"string"},"tool":{"type":"string"},"panel":{"type":"string"},"open":{"type":"boolean"},"op":{"type":"string"},"zoomPercent":{"type":"number"},"dxPx":{"type":"number"},"dyPx":{"type":"number"},"x":{"type":"number"},"y":{"type":"number"},"minX":{"type":"number"},"minY":{"type":"number"},"maxX":{"type":"number"},"maxY":{"type":"number"},"shapeId":{"type":"integer"},"violationIndex":{"type":"integer"},"depth":{"type":"integer","minimum":0,"maximum":32},"additive":{"type":"boolean"},"encloseOnly":{"type":"boolean"},"vertical":{"type":"boolean"},"positionNm":{"type":"number"},"gridVisible":{"type":"boolean"},"gridSize":{"type":"number"},"snapEnabled":{"type":"boolean"},"routingMode":{"type":"string"},"theme":{"type":"string","enum":["light","dark","system"]},"commandId":{"type":"string"}},"required":["action"]}},"captureAfter":{"type":"boolean","default":false}},"required":["steps"]}')
    }
  });

  if (permission === 'readonly') {
    tools.push({
      type: 'function',
      function: {
        name: 'call_native_tool',
        description: '在只读模式下调用 mode=read 或纯视图导航类的鸿图原生工具。',
        parameters: parseSchema('{"type":"object","properties":{"name":{"type":"string"},"arguments":{"type":"object"}},"required":["name"]}')
      }
    });
    return tools;
  }

  const writeTools: OpenAiToolDef[] = [
    {
      type: 'function',
      function: {
        name: 'manage_layers',
        description: '完整管理工艺图层（全部支持一步撤销）：create(新建图层 layer/datatype/chineseName/englishName/color)、delete(删除指定图层及其上所有图形，支持 layer/datatype 或 layers:[{layer,datatype}])、delete_empty(一键删除所有无图元的空图层)、clear(清空指定图层上的图形但保留图层定义)、rename(重命名图层)、style(修改颜色 #RRGGBB、fillStyle: solid|outline|diagonal|cross|stipple、lineStyle: solid|dashed|dotted、transparency 0..1、lineWidth)、visibility(显隐单层)、lock(锁定/解锁)、selectable(允许/禁止选中)、set_active(设为当前绘图层)、reorder(调整图层顺序 targetIndex)、select_shapes_on_layer(选中该层全部图形)、copy_shapes / move_shapes(跨层复制或移动图形到 targetLayer/targetDatatype)、batch_state(op: show_all|hide_all|only_layer|lock_all|unlock_all|invert_visibility)、expression(执行图层布尔表达式如 "10/0 = 1/0 AND 2/0")。',
        parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["create","delete","delete_empty","clear","rename","style","visibility","lock","selectable","set_active","reorder","select_shapes_on_layer","copy_shapes","move_shapes","batch_state","expression"]},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"layers":{"type":"array","items":{"type":"object","properties":{"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767}},"required":["layer"]}},"targetLayer":{"type":"integer","minimum":0,"maximum":32767},"targetDatatype":{"type":"integer","minimum":0,"maximum":32767},"chineseName":{"type":"string"},"englishName":{"type":"string"},"color":{"type":"string"},"fillStyle":{"type":"string","enum":["solid","outline","diagonal","cross","stipple"]},"lineStyle":{"type":"string","enum":["solid","dashed","dotted","dotdash"]},"transparency":{"type":"number","minimum":0,"maximum":1},"lineWidth":{"type":"number","minimum":0.5,"maximum":8},"visible":{"type":"boolean"},"locked":{"type":"boolean"},"selectable":{"type":"boolean"},"targetIndex":{"type":"integer","minimum":0},"allCells":{"type":"boolean","default":true},"op":{"type":"string","enum":["show_all","hide_all","only_layer","lock_all","unlock_all","invert_visibility"]},"expression":{"type":"string"}},"required":["action"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'manage_cells',
        description: '完整管理版图 Cell 单元与层级结构：create(新建 Cell，可选 enterAfterCreate)、delete(按 cellId/cellName 删除单个 Cell，或传 cellIds/cellNames 一次原子批量删除多个 Cell)、rename(重命名 Cell)、duplicate(深拷贝 Cell 及其内部几何为新名称 newName)、clear(清空指定 Cell 内图形)、enter(进入指定 Cell 编辑)、exit_parent(退回上一级父 Cell)、exit_top(退回顶层 Cell)、set_top(将指定 Cell 设为文档主顶层 Top Cell)、make_from_selection(将选中图形打包成新子 Cell 并原位替换为实例)、place_sref(放置单个子单元引用实例 x/y/rotation/mirror/magnification)、place_aref(放置 GDSII AREF 行列阵列实例 cols/rows/pitchX/pitchY，省略步进时自动按子单元包围盒计算无重叠间距)、flatten(展开实例层级)、maintenance_scan(扫描孤立/空 Cell 统计)、prune_orphan_cells(清理未被顶层引用的孤立空 Cell)。',
        parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["create","delete","rename","duplicate","clear","enter","exit_parent","exit_top","set_top","make_from_selection","place_sref","place_aref","flatten","maintenance_scan","prune_orphan_cells"]},"cellId":{"type":"integer","minimum":0},"cellName":{"type":"string"},"cellIds":{"type":"array","items":{"type":"integer","minimum":0}},"cellNames":{"type":"array","items":{"type":"string"}},"newName":{"type":"string"},"enterAfterCreate":{"type":"boolean","default":true},"x":{"type":"number","default":0},"y":{"type":"number","default":0},"rotation":{"type":"number","default":0},"mirror":{"type":"boolean","default":false},"magnification":{"type":"number","default":1},"cols":{"type":"integer","minimum":1,"maximum":32767,"default":2},"rows":{"type":"integer","minimum":1,"maximum":32767,"default":2},"pitchX":{"type":"number"},"pitchY":{"type":"number"},"gapX":{"type":"number","default":200},"gapY":{"type":"number","default":200},"depth":{"type":"integer","minimum":1,"maximum":32,"default":32},"shapeIds":{"type":"array","items":{"type":"integer"}}},"required":["action"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'create_cmos_inverter',
        description: '原生参数化生成完整通用 CMOS 反相器版图（含 NWELL/ACTIVE/POLY/NPLUS/PPLUS/CONTACT/METAL1 图层、VDD/VSS 衬底接触孔、IN/OUT/VDD/VSS 标签与语义端口，并自动运行 DRC 与视图适配）。尺寸单位为整数 nm。',
        parameters: parseSchema('{"type":"object","properties":{"cellName":{"type":"string","default":"INVERTER"},"gateLengthNm":{"type":"integer","minimum":50,"maximum":100000,"default":200},"nmosWidthNm":{"type":"integer","minimum":100,"maximum":100000,"default":600},"pmosWidthNm":{"type":"integer","minimum":100,"maximum":100000,"default":1200},"target":{"type":"string","enum":["auto","current_cell","new_tab"],"default":"auto"}}}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'edit_layout',
        description: '在当前版图 Cell 中原子化批量执行全套几何绘制、曲线生成、三锚点精确设界、Clipper2 布尔运算与变换编辑（支持一次撤销，单位均为 nm）。action 支持：create_rect、create_polygon、create_regular_polygon(x,y,radiusNm,sides)、create_circle(x,y,radiusNm,segments)、create_ellipse(x,y,radiusXNm,radiusYNm,segments)、create_donut(x,y,innerRadiusNm,radiusNm,segments)、create_arc(x,y,innerRadiusNm,radiusNm,startAngleDeg,endAngleDeg,segments)、create_path(points,pathWidth,pathType:0|1|2,beginExtNm,endExtNm)、create_text(x,y,text)、create_array(shapeIds,rows,cols,spacingX,spacingY)、move_shape(shapeIds,dx,dy)、rotate_shape(shapeIds,degrees,centerX,centerY)、mirror_shape(shapeIds,horizontal,centerX,centerY)、scale_shape(shapeIds,scale,centerX,centerY)、duplicate_shape(shapeIds,dx,dy)、delete_shape(shapeIds)、change_layer(shapeIds,targetLayer,targetDatatype)、set_exact_bounds(shapeId,anchor:center|bottom_left|corners,x,y,width,height,x2,y2)、update_vertices(shapeId,points)、size_offset(shapeIds,offsetNm)、round_corners(shapeIds,radiusNm)、align_shapes(shapeIds,alignMode:left|right|top|bottom|center_x|center_y)、distribute_shapes(shapeIds,horizontal)、boolean_op(shapeIds,booleanOp:merge|subtract|intersect|xor,targetLayer,targetDatatype,keepSources)。',
        parameters: parseSchema('{"type":"object","properties":{"operations":{"type":"array","minItems":1,"maxItems":256,"items":{"type":"object","properties":{"action":{"type":"string","enum":["create_rect","create_polygon","create_regular_polygon","create_circle","create_ellipse","create_donut","create_arc","create_path","create_text","create_array","move_shape","rotate_shape","mirror_shape","scale_shape","duplicate_shape","delete_shape","change_layer","set_exact_bounds","update_vertices","size_offset","round_corners","align_shapes","distribute_shapes","boolean_op"]},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"targetLayer":{"type":"integer","minimum":0,"maximum":32767},"targetDatatype":{"type":"integer","minimum":0,"maximum":32767},"layerName":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"x2":{"type":"number"},"y2":{"type":"number"},"width":{"type":"number"},"height":{"type":"number"},"radiusNm":{"type":"number"},"innerRadiusNm":{"type":"number"},"radiusXNm":{"type":"number"},"radiusYNm":{"type":"number"},"startAngleDeg":{"type":"number"},"endAngleDeg":{"type":"number"},"sides":{"type":"integer","minimum":3,"maximum":128},"segments":{"type":"integer","minimum":8,"maximum":512},"points":{"type":"array","items":{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"}},"required":["x","y"]}},"pathWidth":{"type":"number"},"pathType":{"type":"integer","enum":[0,1,2,4]},"beginExtNm":{"type":"number"},"endExtNm":{"type":"number"},"text":{"type":"string"},"shapeId":{"type":"integer"},"shapeIds":{"type":"array","items":{"type":"integer"}},"anchor":{"type":"string","enum":["center","bottom_left","corners"]},"rows":{"type":"integer","minimum":1,"maximum":2000},"cols":{"type":"integer","minimum":1,"maximum":2000},"spacingX":{"type":"number"},"spacingY":{"type":"number"},"dx":{"type":"number"},"dy":{"type":"number"},"offsetNm":{"type":"number"},"degrees":{"type":"number"},"horizontal":{"type":"boolean"},"scale":{"type":"number"},"centerX":{"type":"number"},"centerY":{"type":"number"},"alignMode":{"type":"string","enum":["left","right","top","bottom","center_x","center_y"]},"booleanOp":{"type":"string","enum":["merge","subtract","intersect","xor"]},"keepSources":{"type":"boolean"}},"required":["action"]}}},"required":["operations"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'manage_ports_and_routing',
        description: '管理芯片/光子端口、参数化器件 PCell 与自动避障布线：list_ports、add_port(name,x,y,widthNm,orientationDeg,layer,datatype,portType:electrical|optical)、update_port、delete_port(portId 或 name)、extract_ports_from_labels(自动从当前 Cell 的文本标签提取电气端口)、route_auto(在两个端口或两点之间自动规划曼哈顿/波导走线并写入版图)、list_pcells、place_pcell(pcellName,parameters,x,y)、insert_library_item(entryId,x,y)。',
        parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["list_ports","add_port","update_port","delete_port","extract_ports_from_labels","route_auto","list_pcells","place_pcell","insert_library_item"]},"portId":{"type":"string"},"name":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"toX":{"type":"number"},"toY":{"type":"number"},"fromPort":{"type":"string"},"toPort":{"type":"string"},"widthNm":{"type":"number","default":200},"orientationDeg":{"type":"number","default":0},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"portType":{"type":"string","enum":["electrical","optical"],"default":"electrical"},"bendRadiusNm":{"type":"number","default":5000},"clearanceNm":{"type":"number","default":200},"pcellName":{"type":"string"},"parameters":{"type":"object"},"entryId":{"type":"string"}},"required":["action"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'manage_verification',
        description: '管理 DRC 设计规则、连通网追踪、SPICE 网表提取与 LVS 比对：run_drc、focus_violation(index)、set_drc_rule(ruleId,valueNm,enabled)、import_drc_rules(rulesText,merge)、reset_drc_rules、trace_nets、extract_netlist、run_lvs(schematicSpice)。',
        parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["run_drc","focus_violation","set_drc_rule","import_drc_rules","reset_drc_rules","trace_nets","extract_netlist","run_lvs"]},"index":{"type":"integer","minimum":0},"ruleId":{"type":"string"},"valueNm":{"type":"number"},"enabled":{"type":"boolean","default":true},"rulesText":{"type":"string"},"merge":{"type":"boolean","default":true},"schematicSpice":{"type":"string"}},"required":["action"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'manage_workbench',
        description: '执行工作台全局编辑历史、选区筛选、多文档标签页、精度与宏批处理操作：undo、redo、select_by_ids(shapeIds)、select_all、clear_selection、invert_selection、filter_selection(layer,datatype,shapeType:rect|polygon|path|text|instance)、new_tab(library,topCell,dbuNm)、switch_tab(tabId 或 title)、close_tab(tabId)、rename_tab(title)、save_checkpoint、set_precision(dbuNm,displayGridNm,drawStepNm)、save_bookmark(name)、apply_bookmark(name)、list_macros、run_macro(macroId)。',
        parameters: parseSchema('{"type":"object","properties":{"action":{"type":"string","enum":["undo","redo","select_by_ids","select_all","clear_selection","invert_selection","filter_selection","new_tab","switch_tab","close_tab","rename_tab","save_checkpoint","set_precision","save_bookmark","apply_bookmark","list_macros","run_macro"]},"shapeIds":{"type":"array","items":{"type":"integer"}},"layer":{"type":"integer","minimum":0,"maximum":32767},"datatype":{"type":"integer","minimum":0,"maximum":32767},"shapeType":{"type":"string","enum":["rect","polygon","path","text","instance"]},"tabId":{"type":"string"},"title":{"type":"string"},"library":{"type":"string","default":"WORK_LIB"},"topCell":{"type":"string","default":"TOP"},"dbuNm":{"type":"number","default":1},"displayGridNm":{"type":"number"},"drawStepNm":{"type":"number"},"name":{"type":"string"},"macroId":{"type":"integer"}},"required":["action"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'execute_klayout_python',
        description: '直接在鸿图鸿蒙端侧内置的完整 CPython 3.12 引擎（含完整 Python 3.12 语法、标准库 collections/itertools/hashlib/json/re/math/statistics/heapq/dataclasses/zlib 与原生 C++ Clipper2/GDSII 内核）中离线运行脚本。支持 import hongtu as db、import klayout.db as db、import pya、db.Layout、db.Box/DBox、db.Polygon/DPolygon、db.Path/DPath、db.Text、db.Trans、db.CellInstArray(SREF/AREF)、db.Region(Clipper2 布尔 + - & ^ 与 sized 偏置)、generic_cmos_inverter 及 add_port。inputMode=document 时自动注入 layout 与 current_cell。自动执行模式下可用 applyMode="inspect" 获取脚本 stdout，跳过版图结果导出和应用。Layout 支持 layers()/layer_indexes()/layer_infos()/cells()/each_cell()/top_cells()/cell(k)/delete_cell(i)/prune_cell(i)，Cell 支持 shapes(layer_idx)/shapes()/each_inst()/each_child_cell()/each_parent_cell()/instances()/is_empty()/bbox()，_ShapeRef 支持 is_polygon()/is_box()/is_path()/is_text()/polygon/box/path/text/area()/bbox()，CellInstArray 支持 cell/size()/is_regular_array()/bbox()。',
        parameters: parseSchema('{"type":"object","properties":{"script":{"type":"string","description":"完整 Python 3.12 脚本；生成/修改版图时结果保存在变量 layout (db.Layout)，纯分析脚本配合 applyMode=inspect 直接 print 输出"},"inputMode":{"type":"string","enum":["new","document","selection"],"default":"new"},"applyMode":{"type":"string","enum":["inspect","preview","replace","merge"],"default":"replace"},"parameters":{"type":"object","description":"注入到脚本全局变量 params / PARAMETERS 的键值对"}},"required":["script"]}')
      }
    },
    {
      type: 'function',
      function: {
        name: 'call_native_tool',
        description: '调用鸿图全部 195 项注册原生工具中的任意一项（如 layers.*、cell.*、instance.*、pcell.*、ports.*、route.*、boolean.*、hierarchy.*、lvs.*、rdb.*、waivers.*、views.*、workspace.*）。可先用 list_native_tools 查询精确参数格式。',
        parameters: parseSchema('{"type":"object","properties":{"name":{"type":"string"},"arguments":{"type":"object"}},"required":["name"]}')
      }
    }
  ];

  return tools.concat(writeTools);
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

function serializeWireMessages(messages: WireChatMessage[], allowMultimodalImages: boolean): Object[] {
  const out: Object[] = [];
  for (let i = 0; i < messages.length; i++) {
    const m: WireChatMessage = messages[i];
    const rec: Record<string, Object | null> = {
      'role': m.role
    };
    if (Array.isArray(m.content)) {
      if (allowMultimodalImages) {
        rec['content'] = m.content as Object[];
      } else {
        rec['content'] = m.fallbackText ?? '';
      }
    } else {
      rec['content'] = m.content;
    }
    if (m.reasoning_content !== undefined && m.reasoning_content.length > 0) {
      rec['reasoning_content'] = m.reasoning_content;
    }
    if (m.tool_calls !== undefined && m.tool_calls.length > 0) {
      rec['tool_calls'] = m.tool_calls as Object[];
    }
    if (m.tool_call_id !== undefined && m.tool_call_id.length > 0) {
      rec['tool_call_id'] = m.tool_call_id;
    }
    out.push(rec);
  }
  return out;
}

function hasAnyMultimodalPart(messages: WireChatMessage[]): boolean {
  for (let i = 0; i < messages.length; i++) {
    if (Array.isArray(messages[i].content)) {
      return true;
    }
  }
  return false;
}

function describeUserAttachmentsForPrompt(attachments: AiChatAttachment[]): string {
  if (attachments.length === 0) return '';
  const lines: string[] = ['[本轮附带文件与图片清单]'];
  for (let i = 0; i < attachments.length; i++) {
    const a: AiChatAttachment = attachments[i];
    lines.push(`- id="${a.id}" | 名称="${a.name}" | 类型=${a.kind} (${a.mimeType}) | 摘要=${a.summary ?? ''}`);
    if (a.kind === 'text' && a.textPreview && a.textPreview.trim().length > 0) {
      lines.push(`  内容预览:\n\`\`\`\n${a.textPreview.substring(0, 3000)}\n\`\`\``);
    }
  }
  lines.push('提示：如需读取完整附件文本、载入 GDSII/OASIS 附件到画布或查看附图，可调用 manage_attachments_and_files。');
  return lines.join('\n');
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
    callbacks: DshAgentRunCallbacks,
    options?: DshAgentRunOptions
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
    const webSources: DshWebSearchItem[] = [];
    const seenSourceUrls: Set<string> = new Set<string>();
    const generatedAttachments: AiChatAttachment[] = [];
    const askUserExchanges: AiAskUserExchange[] = [];
    const userAttachments: AiChatAttachment[] = options?.userAttachments ?? [];
    const webSearchEnabled: boolean = options?.webSearchEnabled !== false;
    let visionAllowed: boolean = true;

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
      const attachmentDigest: string = describeUserAttachmentsForPrompt(userAttachments);
      const userPromptText: string =
        `[当前激活版图实时快照]\n${initialLayoutSnap}` +
        (attachmentDigest.length > 0 ? `\n\n${attachmentDigest}` : '') +
        `\n\n[用户需求]\n${prompt}`;

      const imageParts: WireContentPart[] = [];
      for (let i = 0; i < userAttachments.length && imageParts.length < 4; i++) {
        const att: AiChatAttachment = userAttachments[i];
        if (att.kind === 'image') {
          const dataUrl: string = aiAttachmentService.readImageAsDataUrl(att);
          if (dataUrl.length > 0) {
            imageParts.push({
              type: 'image_url',
              image_url: { url: dataUrl }
            });
          }
        }
      }

      if (imageParts.length > 0) {
        const parts: WireContentPart[] = [{ type: 'text', text: userPromptText }];
        wireMessages.push({
          role: 'user',
          content: parts.concat(imageParts),
          fallbackText: userPromptText
        });
      } else {
        wireMessages.push({
          role: 'user',
          content: userPromptText
        });
      }

      const toolDefs: OpenAiToolDef[] = buildDshTools(permission, webSearchEnabled);
      const maxTurns: number = 32;
      let lengthRecoveries: number = 0;

      for (let turn = 0; turn < maxTurns; turn++) {
        if (ticket !== this.runSerial || !host.isPageCurrent()) {
          throw new Error('已取消生成');
        }

        let turnThinkStepId: string = '';
        callbacks.onStatus(turn === 0 ? '正在连接模型并深度思考…' : `正在进行第 ${turn + 1} 步推理…`);

        const onLiveChunk = (liveContent: string, liveReasoning: string, streamingToolNames: string[]): void => {
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
                steps[idx].status = (split.isStreamingThink || (streamingToolNames.length === 0 && split.answer.length === 0))
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
        };

        let turnOut: SingleTurnModelOutput;
        try {
          turnOut = await this.streamChatTurn(
            url,
            apiKey,
            config,
            wireMessages,
            toolDefs,
            ticket,
            visionAllowed,
            onLiveChunk
          );
        } catch (turnErr) {
          if (turnErr instanceof MultimodalUnsupportedError && visionAllowed && hasAnyMultimodalPart(wireMessages)) {
            visionAllowed = false;
            callbacks.onStatus('当前模型为纯文本端点，已自动切换为结构化视觉遥测模式续跑…');
            turnOut = await this.streamChatTurn(
              url,
              apiKey,
              config,
              wireMessages,
              toolDefs,
              ticket,
              false,
              onLiveChunk
            );
          } else {
            const failure: Error = turnErr instanceof Error ? turnErr : new Error(String(turnErr));
            throw failure;
          }
        }

        if (turnThinkStepId.length > 0) {
          const idx: number = steps.findIndex((s: AiProcessStep): boolean => s.id === turnThinkStepId);
          if (idx >= 0) {
            steps[idx].status = 'completed';
          }
        }

        const parsedTurn = splitInlineThinking(turnOut.content, turnOut.reasoning);
        if (parsedTurn.thinking.length > 0) {
          aggregatedReasoning += (aggregatedReasoning.length > 0 ? '\n\n' : '') + parsedTurn.thinking;
        }

        if (turnOut.finishReason === 'length' && turnOut.toolCalls.length === 0 && lengthRecoveries < 3) {
          lengthRecoveries++;
          wireMessages.push({
            role: 'assistant',
            content: parsedTurn.answer.length > 0 ? parsedTurn.answer : '（思考过程较长，继续执行下一步）',
            reasoning_content: parsedTurn.thinking.length > 0 ? parsedTurn.thinking : undefined
          });
          wireMessages.push({
            role: 'user',
            content: '[系统提示：上一轮输出触及单轮长度上限。请勿重复展开长篇推导，直接调用所需工具或输出最终简明结论。]'
          });
          continue;
        }

        if (turnOut.toolCalls.length === 0) {
          finalAnswer = parsedTurn.answer.trim();
          if (finalAnswer.length === 0 && parsedTurn.thinking.length > 0) {
            finalAnswer = '已完成分析与操作，详情可展开上方「工作过程」查看。';
          }
          emitSnapshot(finalAnswer);
          break;
        }

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

        wireMessages.push({
          role: 'assistant',
          content: parsedTurn.answer.length > 0 ? parsedTurn.answer : null,
          reasoning_content: parsedTurn.thinking.length > 0 ? parsedTurn.thinking : undefined,
          tool_calls: turnOut.toolCalls
        });

        const pendingVisualObservations: PendingVisualObservation[] = [];

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
          callbacks.onStatus(toolName === 'ask_user' ? '等待你在对话框中确认选项…' : `正在执行 ${toolName}…`);
          emitSnapshot('');

          let toolResultJson: string = '';
          let toolOk: boolean = true;
          try {
            const outcome: DshToolExecutionOutcome = await this.dispatchToolCall(
              toolName,
              rawArgs,
              permission,
              host,
              webSources,
              seenSourceUrls,
              askUserExchanges
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
            if (outcome.generatedAttachment !== undefined) {
              generatedAttachments.push(outcome.generatedAttachment);
            }
            if (outcome.visualAttachment !== undefined) {
              pendingVisualObservations.push({
                summary: outcome.summary,
                attachment: outcome.visualAttachment
              });
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

          if (stagedPending) {
            break;
          }
        }

        // Inject autonomous Visual Harness screenshot observations for multimodal inspection!
        if (!stagedPending && pendingVisualObservations.length > 0) {
          const textSummaryLines: string[] = ['[Harness 视觉巡检图像回注]'];
          const parts: WireContentPart[] = [];
          for (let vi = 0; vi < pendingVisualObservations.length && vi < 2; vi++) {
            const obs = pendingVisualObservations[vi];
            textSummaryLines.push(`- 图像 ${vi + 1} (${obs.attachment.name}, ${obs.attachment.summary ?? ''}): ${obs.summary}`);
            if (visionAllowed) {
              const dataUrl: string = aiAttachmentService.readImageAsDataUrl(obs.attachment);
              if (dataUrl.length > 0) {
                parts.push({
                  type: 'image_url',
                  image_url: { url: dataUrl }
                });
              }
            }
          }
          textSummaryLines.push('请结合上述实时截图画面与结构化几何状态，核查图形排布、图层可见性、连线或界面状态是否符合预期。');
          const fallbackObsText: string = textSummaryLines.join('\n');
          if (parts.length > 0) {
            const fullParts: WireContentPart[] = [{ type: 'text', text: fallbackObsText }];
            wireMessages.push({
              role: 'user',
              content: fullParts.concat(parts),
              fallbackText: fallbackObsText
            });
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
        turnChangeSummary,
        webSources,
        generatedAttachments,
        askUserExchanges
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
    host: DshLayoutBackendHost,
    webSources: DshWebSearchItem[],
    seenSourceUrls: Set<string>,
    askUserExchanges: AiAskUserExchange[]
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
      case 'inspect_workbench_ui': {
        const uiSnap: string = host.inspectWorkbenchUi();
        return { success: true, summary: '已读取软件工作台 UI 与视口状态', payloadJson: uiSnap };
      }
      case 'capture_screenshot': {
        return await host.captureScreenshot(JSON.stringify(args));
      }
      case 'automate_workbench_ui': {
        return await host.automateWorkbenchUi(JSON.stringify(args), permission);
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
      case 'ask_user': {
        const question: string = typeof args['question'] === 'string' ? (args['question'] as string).trim() : '';
        if (question.length === 0) {
          throw new Error('ask_user 必须提供非空 question');
        }
        const header: string = typeof args['header'] === 'string' && (args['header'] as string).trim().length > 0
          ? (args['header'] as string).trim()
          : '请确认参数或偏好';
        const allowMultiple: boolean = args['allowMultiple'] === true;
        const placeholder: string = typeof args['placeholder'] === 'string' && (args['placeholder'] as string).trim().length > 0
          ? (args['placeholder'] as string).trim()
          : '或输入自定义说明…';
        const parsedOptions: AiAskUserOption[] = [];
        const rawOpts: Object | undefined = args['options'];
        if (Array.isArray(rawOpts)) {
          const arr: Object[] = rawOpts as Object[];
          for (let i = 0; i < arr.length && parsedOptions.length < 6; i++) {
            const item: Object = arr[i];
            if (item !== null && typeof item === 'object') {
              const rec: Record<string, Object> = item as Record<string, Object>;
              const lbl: string = typeof rec['label'] === 'string' ? (rec['label'] as string).trim() : '';
              const desc: string = typeof rec['description'] === 'string' ? (rec['description'] as string).trim() : '';
              if (lbl.length > 0) {
                parsedOptions.push({ label: lbl, description: desc.length > 0 ? desc : undefined });
              }
            } else if (typeof item === 'string' && (item as string).trim().length > 0) {
              parsedOptions.push({ label: (item as string).trim() });
            }
          }
        }
        const exchange: AiAskUserExchange = await host.askUser({
          question,
          header,
          options: parsedOptions,
          allowMultiple,
          placeholder
        });
        askUserExchanges.push(exchange);
        const answer: string = exchange.selectedLabels.concat([exchange.customText])
          .filter((text: string): boolean => text.trim().length > 0).join('、');
        return {
          success: true,
          summary: exchange.skipped ? '用户跳过了该提问' : `用户已回复：${answer}`,
          payloadJson: JSON.stringify({
            success: true,
            question: exchange.question,
            answer,
            selectedLabels: exchange.selectedLabels,
            customText: exchange.customText ?? '',
            skipped: exchange.skipped === true
          })
        };
      }
      case 'web_search': {
        const query: string = typeof args['query'] === 'string' ? (args['query'] as string).trim() : '';
        if (query.length === 0) {
          throw new Error('web_search 需要提供非空搜索词 query');
        }
        const maxRes: number = typeof args['maxResults'] === 'number'
          ? Math.max(1, Math.min(10, Math.round(args['maxResults'] as number)))
          : 6;
        const searchRes: DshWebSearchResponse = await dshWebSearchService.search(query, maxRes);
        for (const it of searchRes.results) {
          if (it.url.length > 0 && !seenSourceUrls.has(it.url) && webSources.length < 16) {
            seenSourceUrls.add(it.url);
            webSources.push(it);
          }
        }
        return {
          success: searchRes.results.length > 0 || searchRes.errorMessage === undefined,
          summary: `联网检索「${query}」返回 ${searchRes.results.length} 条结果`,
          payloadJson: JSON.stringify(searchRes)
        };
      }
      case 'web_fetch': {
        const targetUrl: string = typeof args['url'] === 'string' ? (args['url'] as string).trim() : '';
        if (targetUrl.length === 0) {
          throw new Error('web_fetch 需要提供目标网页 url');
        }
        const maxChars: number = typeof args['maxChars'] === 'number'
          ? Math.max(500, Math.min(24000, Math.round(args['maxChars'] as number)))
          : 10000;
        const fetchRes: DshWebFetchResponse = await dshWebSearchService.fetchPage(targetUrl, maxChars);
        if (!seenSourceUrls.has(fetchRes.url) && webSources.length < 16) {
          seenSourceUrls.add(fetchRes.url);
          webSources.push({
            title: fetchRes.title.length > 0 ? fetchRes.title : fetchRes.url,
            url: fetchRes.url,
            snippet: fetchRes.content.substring(0, 180),
            source: 'WebFetch'
          });
        }
        return {
          success: true,
          summary: `已读取网页「${fetchRes.title || fetchRes.url}」`,
          payloadJson: JSON.stringify(fetchRes)
        };
      }
      case 'manage_attachments_and_files': {
        return await host.manageAttachmentsAndFiles(JSON.stringify(args), permission);
      }
      case 'manage_layers': {
        if (permission === 'readonly') {
          throw new Error('当前处于「只读巡检」模式，无法修改图层；请切换为「自动执行」或「审阅确认」。');
        }
        return await host.manageLayers(JSON.stringify(args), permission);
      }
      case 'manage_cells': {
        if (permission === 'readonly') {
          throw new Error('当前处于「只读巡检」模式，无法修改 Cell 结构；请切换为「自动执行」或「审阅确认」。');
        }
        return await host.manageCells(JSON.stringify(args), permission);
      }
      case 'manage_ports_and_routing': {
        return await host.managePortsAndRouting(JSON.stringify(args), permission);
      }
      case 'manage_verification': {
        return await host.manageVerification(JSON.stringify(args), permission);
      }
      case 'manage_workbench': {
        return await host.manageWorkbench(JSON.stringify(args), permission);
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
          throw new Error('当前处于「只读巡检」权限模式，无法绘制版图；请在输入框左下角切换为「自动执行」或「审阅确认」。');
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
          throw new Error('当前处于「只读巡检」权限模式，无法修改版图；请在输入框左下角切换为「自动执行」或「审阅确认」。');
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
          throw new Error('当前处于「只读巡检」权限模式，无法执行 Python 脚本。');
        }
        const modeRaw: string = typeof args['applyMode'] === 'string' ? (args['applyMode'] as string) : 'replace';
        const applyMode: 'replace' | 'merge' | 'preview' | 'inspect' =
          modeRaw === 'inspect' ? 'inspect' : (modeRaw === 'merge' ? 'merge' : (modeRaw === 'preview' ? 'preview' : 'replace'));
        if (permission === 'review' && applyMode === 'inspect') {
          throw new Error('Python inspect 仅支持「自动执行」模式。');
        }
        const script: string = typeof args['script'] === 'string' ? (args['script'] as string) : '';
        if (script.trim().length === 0) {
          throw new Error('script 不能为空');
        }
        const inModeRaw: string = typeof args['inputMode'] === 'string' ? (args['inputMode'] as string) : 'new';
        const inputMode: 'new' | 'document' | 'selection' =
          inModeRaw === 'document' ? 'document' : (inModeRaw === 'selection' ? 'selection' : 'new');
        const paramsObj: Object | undefined = args['parameters'];
        const paramsJson: string = paramsObj !== undefined && paramsObj !== null && typeof paramsObj === 'object'
          ? JSON.stringify(paramsObj)
          : '{}';
        if (permission === 'review') {
          return await host.callNativeTool(
            'python.run',
            JSON.stringify({ script, inputMode, applyMode, parameters: paramsJson }),
            permission
          );
        }
        return await host.executeKlayoutPython(script, applyMode, inputMode, paramsJson);
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
    allowMultimodalImages: boolean,
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
    const serializedMessages: Object[] = serializeWireMessages(messages, allowMultimodalImages);
    const sentMultimodal: boolean = allowMultimodalImages && hasAnyMultimodalPart(messages);

    const payload: WireChatRequest = {
      model: config.modelName,
      messages: serializedMessages,
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

      const isVisionUnsupportedHttp = (code: number, rawErr: string): boolean => {
        if (!sentMultimodal) return false;
        if (code === 415 || code === 422) return true;
        if (code === 400) {
          const lower: string = rawErr.toLowerCase();
          return lower.length === 0 ||
            lower.includes('image') ||
            lower.includes('vision') ||
            lower.includes('multimodal') ||
            lower.includes('content') ||
            lower.includes('array') ||
            lower.includes('string') ||
            lower.includes('expected');
        }
        return false;
      };

      const failTurn = (msg: string, rawCode: number = 0, rawBody: string = ''): void => {
        if (finished) return;
        if ((doneMarkerSeen || finishReason.length > 0) && (statusCode === 200 || statusCode === 0) &&
          (contentAcc.length > 0 || reasoningAcc.length > 0 || toolAccs.length > 0)) {
          finishSuccess();
          return;
        }
        finished = true;
        cleanup();
        const safeMsg: string = apiKey.length >= 4 ? msg.split(apiKey).join('***') : msg;
        if (isVisionUnsupportedHttp(rawCode || statusCode, rawBody || msg)) {
          reject(new MultimodalUnsupportedError(safeMsg));
          return;
        }
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
          failTurn(`模型返回错误：${errText.substring(0, 240)}`, statusCode || 400, errText);
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
        if (buffer.length > 12 * 1024 * 1024) {
          failTurn('单轮模型流式数据超出 12 MiB 安全上限');
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
          failTurn(parseHttpErrorDetail(statusCode, nonSseErrorBody), statusCode, nonSseErrorBody);
          return;
        }
        if (!sawSseFrame && nonSseErrorBody.trim().startsWith('{')) {
          consumePacketJson(nonSseErrorBody.trim());
        }
        if (contentAcc.length === 0 && reasoningAcc.length === 0 && toolAccs.length === 0) {
          failTurn(
            nonSseErrorBody.trim().length > 0
              ? parseHttpErrorDetail(statusCode || 500, nonSseErrorBody)
              : '模型未返回任何有效内容或工具调用，请检查模型兼容性',
            statusCode || 500,
            nonSseErrorBody
          );
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
          failTurn(parseHttpErrorDetail(code, nonSseErrorBody), code, nonSseErrorBody);
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
