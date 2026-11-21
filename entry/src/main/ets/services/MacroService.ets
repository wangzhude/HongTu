/**
 * 鸿图宏脚本服务
 *
 * 对齐 KLayout 的 Macro/Scripting 功能：
 * - 宏脚本录制与回放
 * - 批处理操作序列
 * - 常用宏模板管理
 * - 宏导入导出（JSON 格式）
 *
 * 注意：鸿图使用简化版脚本格式（非 Ruby/Python），
 * 通过命令序列定义批处理流程，兼容 AI 命令格式。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { editService } from './EditService';
import { aiExecutor, ViewAction } from './AiCommandParser';
import { aiService, AiContext, AiLayerInfo, ParsedCommand, AiCommandType } from './AiService';
import { advEditService, AlignType, DistributeType } from './AdvancedEditService';
import { Point } from '../models/GdsiiData';
import { cloneStructured } from '../common/CloneUtils';

export type MacroStepType = 'draw' | 'edit' | 'layer' | 'view' | 'drc' | 'ai';
export interface MacroCellReference { id: number; name: string; }

/** 宏步骤 */
export interface MacroStep {
  /** 步骤描述（人类可读） */
  description: string;
  /** 命令文本 */
  command: string;
  /** 步骤类型 */
  type: MacroStepType;
}

/** 宏定义 */
export interface Macro {
  id: number;
  name: string;
  description: string;
  steps: MacroStep[];
  /** 创建时间 */
  createdAt: number;
  /** 最后修改时间 */
  updatedAt: number;
  /** 是否为内置宏 */
  builtin: boolean;
  /** 快捷键 */
  shortcut?: string;
  /** Literal shape/Cell IDs are valid only in this workspace document. */
  originDocumentId?: string;
}

/** 宏执行结果 */
export interface MacroResult {
  macroId: number;
  macroName: string;
  success: boolean;
  executedSteps: number;
  totalSteps: number;
  error?: string;
  elapsed: number;
  /** 执行产生的命令结果 */
  results: string[];
  viewActions?: ViewAction[];
}

interface MacroStepResult {
  success: boolean;
  message?: string;
  viewActions?: ViewAction[];
}

interface MacroExportItem {
  name: string;
  description: string;
  steps: MacroStep[];
  originDocumentId?: string;
}

interface MacroExportPayload {
  format: string;
  version: string;
  macro: MacroExportItem;
}

interface MacroCollectionItem {
  name: string;
  description: string;
  steps: MacroStep[];
  builtin: boolean;
  originDocumentId?: string;
}

interface MacroCollectionExportPayload {
  format: string;
  version: string;
  exportedAt: string;
  macros: MacroCollectionItem[];
}

interface MacroImportCandidate {
  name?: string;
  description?: string;
  steps?: MacroStep[];
  originDocumentId?: string;
}

interface MacroImportPayload extends MacroImportCandidate {
  macro?: MacroImportCandidate;
}

/** 持久化存储的自定义宏条目（仅非内置宏） */
interface MacroPersistItem {
  id: number;
  name: string;
  description: string;
  steps: MacroStep[];
  createdAt: number;
  updatedAt: number;
  shortcut?: string;
  originDocumentId?: string;
}

export interface MacroServiceState {
  macros: Macro[];
  nextId: number;
  recording: boolean;
  recordedSteps: MacroStep[];
  recordName: string;
  recordOriginDocumentId?: string;
  storage: string;
}

/**
 * 宏脚本服务
 */
interface MacroCommandBudget {
  count: number;
}

export class MacroService {
  /** 单次宏回放挂钟时间预算（ms）：超出立即熔断并原子回滚会话，防止死循环或超大宏触发 APP_FREEZE */
  public static readonly MAX_MACRO_WALL_TIME_MS: number = 2500;
  /** 单次宏执行最大步数熔断上限 */
  public static readonly MAX_MACRO_EXECUTION_STEPS: number = 500;
  /** 单次宏展开原子命令总数上限 */
  public static readonly MAX_MACRO_EXPANDED_COMMANDS: number = 1000;

  private macros: Map<number, Macro> = new Map();
  private nextId: number = 1;
  private recording: boolean = false;
  private executing: boolean = false;
  private recordedSteps: MacroStep[] = [];
  private recordName: string = '';
  private recordOriginDocumentId: string | undefined = undefined;
  // 是否已完成初始化（构造期间不持久化，避免覆盖已存储的自定义宏）
  private initialized: boolean = false;

  constructor() {
    this.replaceBuiltinMacros();
    this.loadCustomMacros();
  }

  captureState(): MacroServiceState {
    return { macros: cloneStructured(Array.from(this.macros.values())) as Macro[],
      nextId: this.nextId, recording: this.recording, recordedSteps: this.copySteps(this.recordedSteps),
      recordName: this.recordName, recordOriginDocumentId: this.recordOriginDocumentId,
      storage: AppStorage.get<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY) ?? '[]' };
  }

  private restoreMemory(state: MacroServiceState): void {
    this.macros = new Map<number, Macro>();
    for (const macro of state.macros) this.macros.set(macro.id, cloneStructured(macro) as Macro);
    this.nextId = state.nextId; this.recording = state.recording;
    this.recordedSteps = this.copySteps(state.recordedSteps); this.recordName = state.recordName;
    this.recordOriginDocumentId = state.recordOriginDocumentId;
  }

  restoreState(state: MacroServiceState): void {
    this.restoreMemory(state);
    if ((AppStorage.get<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY) ?? '[]') === state.storage) return;
    AppStorage.setOrCreate<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY, state.storage);
    if (AppStorage.get<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY) !== state.storage) throw new Error('宏快照存储回读不一致');
  }

  private commitMutation(change: () => void): void {
    if (!this.initialized) { change(); return; }
    const prior: MacroServiceState = this.captureState();
    try { change(); this.persistCustomMacros(); }
    catch (failure) {
      let rollback: string = '';
      try { this.restoreState(prior); }
      catch (error) { rollback = `；宏存储回滚未完成：${String(error)}`; }
      throw new Error(`宏保存失败：${String(failure)}${rollback}`);
    }
  }

  // ===== 宏录制 =====

  /** 开始录制宏 */
  startRecording(name: string, documentId?: string) {
    if (typeof name !== 'string' || !name.trim() || name.length > 120) throw new Error('宏录制名称无效');
    if (!this.validOrigin(documentId)) throw new Error('宏录制文档标识无效');
    if (this.recording) this.stopRecording();
    this.recording = true;
    this.recordedSteps = [];
    this.recordName = name.trim();
    this.recordOriginDocumentId = documentId;
  }

  /** 录制一步操作 */
  recordStep(description: string, command: string, type: MacroStepType = 'edit', currentDocumentId?: string) {
    if (!this.recording) return;
    if (currentDocumentId !== undefined && currentDocumentId !== this.recordOriginDocumentId) {
      this.stopRecording();
      return;
    }
    if (this.recordedSteps.length >= 1000 || !this.validSteps([{ description, command, type }])) {
      throw new Error('宏录制步骤无效或超过 1000 步，已有录制保留');
    }
    this.recordedSteps.push({ description, command, type });
  }

  /** 停止录制并保存宏 */
  stopRecording(): Macro | null {
    if (!this.recording || this.recordedSteps.length === 0) {
      this.recording = false;
      this.recordOriginDocumentId = undefined;
      return null;
    }

    const macro: Macro = {
      id: this.nextId,
      name: this.recordName,
      description: `录制的宏 (${this.recordedSteps.length} 步)`,
      steps: this.copySteps(this.recordedSteps),
      createdAt: Date.now(),
      updatedAt: Date.now(),
      builtin: false,
      originDocumentId: this.recordOriginDocumentId,
    };

    this.commitMutation(() => {
      this.nextId++; this.macros.set(macro.id, macro);
      this.recording = false; this.recordedSteps = []; this.recordName = '';
      this.recordOriginDocumentId = undefined;
    });
    return macro;
  }

  /** 取消录制 */
  cancelRecording() {
    this.recording = false;
    this.recordedSteps = [];
    this.recordName = '';
    this.recordOriginDocumentId = undefined;
  }

  isRecording(): boolean { return this.recording; }

  // ===== 宏管理 =====

  /** 获取所有宏 */
  getAllMacros(): Macro[] {
    return Array.from(this.macros.values());
  }

  /** 获取宏 */
  getMacro(id: number): Macro | undefined {
    return this.macros.get(id);
  }

  /** 创建宏 */
  createMacro(name: string, description: string, steps: MacroStep[], originDocumentId?: string): Macro {
    if (!name.trim() || name.length > 120 || description.length > 4000 || !this.validSteps(steps) || !this.validOrigin(originDocumentId)) {
      throw new Error('宏名称、说明或步骤无效');
    }
    const macro: Macro = {
      id: this.nextId,
      name: name.trim(), description, steps: this.copySteps(steps),
      createdAt: Date.now(),
      updatedAt: Date.now(),
      builtin: false,
      originDocumentId,
    };
    this.commitMutation(() => { this.nextId++; this.macros.set(macro.id, macro); });
    return macro;
  }

  /** 更新宏 */
  updateMacro(id: number, updates: Partial<Macro>): boolean {
    const macro = this.macros.get(id);
    if (!macro || macro.builtin) return false;
    if (updates.name !== undefined && (!updates.name.trim() || updates.name.length > 120)) return false;
    if (updates.description !== undefined && updates.description.length > 4000) return false;
    if (updates.steps !== undefined && !this.validSteps(updates.steps)) return false;

    const updated: Macro = {
      id: macro.id,
      name: updates.name !== undefined ? updates.name : macro.name,
      description: updates.description !== undefined ? updates.description : macro.description,
      steps: updates.steps !== undefined ? this.copySteps(updates.steps) : this.copySteps(macro.steps),
      createdAt: macro.createdAt,
      updatedAt: Date.now(),
      builtin: macro.builtin,
      originDocumentId: macro.originDocumentId,
    };
    const shortcut = updates.shortcut !== undefined ? updates.shortcut : macro.shortcut;
    if (shortcut !== undefined) {
      updated.shortcut = shortcut;
    }
    this.commitMutation(() => { this.macros.set(id, updated); });
    return true;
  }

  /** 删除宏 */
  deleteMacro(id: number): boolean {
    const macro = this.macros.get(id);
    if (!macro || macro.builtin) return false;
    this.commitMutation(() => { this.macros.delete(id); });
    return true;
  }

  // ===== 宏执行 =====

  /** 执行宏 */
  executeMacro(id: number, context?: AiContext, documentId?: string | AiLayerInfo[], cellOptions?: MacroCellReference[]): MacroResult {
    const startTime = Date.now();
    const macro = this.macros.get(id);
    const results: string[] = [];
    const viewActions: ViewAction[] = [];

    if (!macro) {
      return {
        macroId: id, macroName: '未知',
        success: false, executedSteps: 0, totalSteps: 0,
        error: '宏不存在', elapsed: 0, results,
      };
    }

    if (this.executing) {
      return { macroId: id, macroName: macro.name, success: false, executedSteps: 0, totalSteps: macro.steps.length,
        error: '宏正在执行中，已阻止嵌套或重入调用', elapsed: Date.now() - startTime, results, viewActions: [] };
    }

    if (this.recording) {
      return { macroId: id, macroName: macro.name, success: false, executedSteps: 0, totalSteps: macro.steps.length,
        error: '宏录制中，请先停止或取消录制后再运行', elapsed: Date.now() - startTime, results, viewActions: [] };
    }

    if (macro.steps.length > MacroService.MAX_MACRO_EXECUTION_STEPS) {
      return {
        macroId: id,
        macroName: macro.name,
        success: false,
        executedSteps: 0,
        totalSteps: macro.steps.length,
        error: `宏步数（${macro.steps.length} 步）超过单次熔断上限（${MacroService.MAX_MACRO_EXECUTION_STEPS} 步），整批未执行`,
        elapsed: Date.now() - startTime,
        results,
        viewActions: [],
      };
    }

    // Preserve the legacy third-argument layer list while accepting workspace identity.
    const layers: AiLayerInfo[] | undefined = Array.isArray(documentId) ? documentId : undefined;
    const currentDocumentId: string | undefined = typeof documentId === 'string' ? documentId : undefined;
    if (!this.validSteps(macro.steps) || (this.hasDocumentIds(macro.steps) &&
      (macro.originDocumentId === undefined || !this.validOrigin(macro.originDocumentId) || macro.originDocumentId !== currentDocumentId))) {
      return { macroId: id, macroName: macro.name, success: false, executedSteps: 0, totalSteps: macro.steps.length,
        error: !this.validSteps(macro.steps) ? '宏步骤无效，整批未执行' :
          '宏含固定图形或 Cell ID，但缺少来源文档或与当前文档不符；请回到录制文档，或在当前文档重新录制。整批未执行。',
        elapsed: Date.now() - startTime, results };
    }
    const cellError: string = this.validateInstanceReferences(macro.steps, cellOptions !== undefined ? cellOptions : context?.cells);
    if (cellError.length > 0) return { macroId: id, macroName: macro.name, success: false, executedSteps: 0,
      totalSteps: macro.steps.length, error: cellError, elapsed: Date.now() - startTime, results };

    let executed = 0;
    let expandedCommands = 0;
    let completed: boolean = false;
    const deadlineMs: number = startTime + MacroService.MAX_MACRO_WALL_TIME_MS;
    const previousSession = editService.captureSession(true);
    // MACRO-2: 宏回放整体包入批处理，使 undo 一次撤销整个宏（与"宏是单个批处理操作"语义一致）
    const useBatch: boolean = macro.steps.length > 1;
    this.executing = true;
    if (useBatch) {
      editService.beginBatch();
    }
    try {
      for (const step of macro.steps) {
        if (Date.now() > deadlineMs) {
          return {
            macroId: id, macroName: macro.name,
            success: false, executedSteps: 0, totalSteps: macro.steps.length,
            error: `宏执行超时（超过 ${MacroService.MAX_MACRO_WALL_TIME_MS}ms 挂钟预算），已熔断并完整回滚会话`,
            elapsed: Date.now() - startTime, results, viewActions: [],
          };
        }
        try {
          const budgetState: MacroCommandBudget = { count: expandedCommands };
          const result = this.executeStep(step, context, layers, deadlineMs, budgetState);
          expandedCommands = budgetState.count;
          results.push(result.message ?? 'OK');
          if (result.viewActions !== undefined) {
            for (let i = 0; i < result.viewActions.length; i++) {
              viewActions.push(result.viewActions[i]);
            }
          }
          if (!result.success) {
            return {
              macroId: id, macroName: macro.name,
              success: false, executedSteps: 0, totalSteps: macro.steps.length,
              error: result.message ?? `步骤 ${executed + 1} 执行失败: ${step.description}`,
              elapsed: Date.now() - startTime, results, viewActions: [],
            };
          }
          if (Date.now() > deadlineMs) {
            return {
              macroId: id, macroName: macro.name,
              success: false, executedSteps: 0, totalSteps: macro.steps.length,
              error: `宏执行超时（超过 ${MacroService.MAX_MACRO_WALL_TIME_MS}ms 挂钟预算），已熔断并完整回滚会话`,
              elapsed: Date.now() - startTime, results, viewActions: [],
            };
          }
          executed++;
        } catch (e) {
          return {
            macroId: id, macroName: macro.name,
            success: false, executedSteps: 0, totalSteps: macro.steps.length,
            error: `步骤 ${executed + 1} 执行失败: ${step.description}`,
            elapsed: Date.now() - startTime, results, viewActions: [],
          };
        }
      }
      completed = true;
    } finally {
      this.executing = false;
      if (useBatch) {
        editService.endBatch();
      }
      if (!completed) editService.restoreSession(previousSession, true);
    }

    return {
      macroId: id, macroName: macro.name,
      success: true, executedSteps: executed, totalSteps: macro.steps.length,
      elapsed: Date.now() - startTime, results, viewActions,
    };
  }

  /** 执行单个步骤 (Fix ⑤: 修复类型不匹配 Bug; MACRO-1: 增加管道格式直接解析) */
  private executeStep(
    step: MacroStep,
    providedContext?: AiContext,
    layers?: AiLayerInfo[],
    deadlineMs?: number,
    commandBudget?: MacroCommandBudget
  ): MacroStepResult {
    // Transform opcodes execute locally; they never enter an AI parser/executor.
    const transform: string[] = step.command.trim().split('|');
    transform[0] = transform[0].trim();
    if (transform[0] === 'rotate' || transform[0] === 'mirror' || transform[0] === 'scale') {
      if (!this.validTransformCommand(step.command)) return { success: false, message: '变换宏参数无效' };
      const value: number = Number(transform[1]);
      const ok: boolean = transform[0] === 'rotate' ? advEditService.rotateSelection(value) :
        transform[0] === 'mirror' ? advEditService.mirrorSelection(value === 1) : advEditService.scaleSelection(value);
      return { success: ok, message: ok ? `选区变换 ${step.command}` : '选区变换失败，选区为空、锁定或参数越界' };
    }
    // 构建上下文（layers 由调用方注入，避免图层名解析失效）
    const context: AiContext = providedContext ?? {
      layers: layers ?? [],
      currentLayer: 1,
      shapeCount: editService.getShapeCount(),
      selectedShape: null,
    };

    // MACRO-1: 优先尝试管道分隔格式（create_rect|... / move_shape|... / delete_shapes|...）
    // 该格式由 Index.ets 中的 macroService.recordStep 调用产生，aiService.parseText 无法识别
    const pipeCommands = this.parsePipeCommand(step.command.trimStart());
    const commands: ParsedCommand[] = pipeCommands !== null
      ? pipeCommands
      : aiService.parseText(step.command, context);
    if (commands.length === 0) {
      return { success: false, message: `无法解析命令: ${step.command}` };
    }

    let lastMessage = '';
    const viewActions: ViewAction[] = [];
    for (const cmd of commands) {
      if (commandBudget !== undefined) {
        commandBudget.count++;
        if (commandBudget.count > MacroService.MAX_MACRO_EXPANDED_COMMANDS) {
          return {
            success: false,
            message: `宏展开原子命令数超过上限（${MacroService.MAX_MACRO_EXPANDED_COMMANDS} 条），已熔断回滚`,
            viewActions: []
          };
        }
      }
      if (deadlineMs !== undefined && Date.now() > deadlineMs) {
        return {
          success: false,
          message: `宏执行超时（超过 ${MacroService.MAX_MACRO_WALL_TIME_MS}ms 挂钟预算），已熔断并完整回滚会话`,
          viewActions: []
        };
      }
      const result = aiExecutor.execute(cmd, context);
      if (!result.success) {
        return { success: false, message: result.message, viewActions };
      }
      if (result.viewAction !== undefined) {
        viewActions.push(result.viewAction);
      }
      lastMessage = result.message;
    }

    return { success: true, message: lastMessage || 'OK', viewActions };
  }

  /**
   * 解析管道分隔的宏命令格式。
   *
   * 命令格式（与 Index.ets 中 recordStep 调用一致）：
   * layer 接受 layer/datatype（如 67/44）；旧纯 layer 字段按 datatype=0 回放。
   * - `create_rect|layer|x1|y1|x2|y2`：创建矩形，坐标为两个对角点
   * - `create_polygon|layer|x1,y1|x2,y2|...`：创建多边形，顶点为逗号分隔的 x,y 对
   * - `create_path|layer|width|x1,y1|x2,y2|...`：创建路径，width 为线宽
   * - `create_text|layer|x|y|text`：创建文本
   * - `create_instance|cellId|x|y|rotation|mirror|cellName?`：放置实例
   * - `move_shape|shapeId|dx|dy`：移动指定图形
   * - `delete_shapes|id1,id2,...`：删除指定图形列表
   * - `paste`：粘贴剪贴板内容
   * - `align|type`：对齐选中图形（type = left/right/top/bottom/centerH/centerV）
   * - `distribute|type`：分布选中图形（type = horizontal/vertical）
   * - `change_layer|id1,id2,...|newLayer`：改图层
   *
   * @returns 解析成功返回 ParsedCommand[]，非管道格式或解析失败返回 null
   */
  private parsePipeCommand(command: string): ParsedCommand[] | null {
    if (command.length === 0) return null;
    const pipeIdx = command.indexOf('|');
    // 无管道分隔符：检查是否为无参数命令（如 paste）
    if (pipeIdx < 0) {
      if (command === 'paste') {
        const pasted = editService.pasteShapes();
        return [this.noOpCommand(pasted.length > 0 ? `粘贴 ${pasted.length} 个图形` :
          '粘贴失败：剪贴板为空、目标图层锁定或超出图形预算', pasted.length > 0)];
      }
      return null;
    }
    const op = command.substring(0, pipeIdx).trim();
    const rest = command.substring(pipeIdx + 1);

    if (op === 'create_rect') {
      const parts = rest.split('|');
      if (parts.length !== 5) return null;
      const layerKey: string[] = parts[0].split('/');
      const layer = Number(layerKey[0]);
      const datatype = layerKey.length > 1 ? Number(layerKey[1]) : 0;
      if (layerKey.length > 2 || !Number.isInteger(layer) || !Number.isInteger(datatype) || layer < 0 || layer > 32767 || datatype < 0 || datatype > 32767) return null;
      const x1 = Number.parseFloat(parts[1]);
      const y1 = Number.parseFloat(parts[2]);
      const x2 = Number.parseFloat(parts[3]);
      const y2 = Number.parseFloat(parts[4]);
      if (Number.isNaN(layer) || Number.isNaN(x1) || Number.isNaN(y1) || Number.isNaN(x2) || Number.isNaN(y2)) {
        return null;
      }
      const width = Math.abs(x2 - x1);
      const height = Math.abs(y2 - y1);
      const x = Math.min(x1, x2);
      const y = Math.min(y1, y2);
      const cmd: ParsedCommand = {
        type: AiCommandType.CREATE_RECT,
        params: { layer, datatype, x, y, width, height },
        description: `创建 L${layer} 矩形 ${width}x${height}nm @(${x},${y})`,
      };
      return [cmd];
    }

    if (op === 'create_polygon') {
      const parts = rest.split('|');
      if (parts.length < 4) return null; // layer + 至少 3 个点
      const layerKey: string[] = parts[0].split('/');
      const layer = Number(layerKey[0]);
      const datatype = layerKey.length > 1 ? Number(layerKey[1]) : 0;
      if (layerKey.length > 2 || !Number.isInteger(layer) || !Number.isInteger(datatype) || layer < 0 || layer > 32767 || datatype < 0 || datatype > 32767) return null;
      if (Number.isNaN(layer)) return null;
      const points: Point[] = [];
      for (let i = 1; i < parts.length; i++) {
        const xy = parts[i].split(',');
        if (xy.length !== 2) return null;
        const px = Number.parseFloat(xy[0]);
        const py = Number.parseFloat(xy[1]);
        if (Number.isNaN(px) || Number.isNaN(py)) return null;
        points.push({ x: px, y: py });
      }
      const cmd: ParsedCommand = {
        type: AiCommandType.CREATE_POLYGON,
        params: { layer, datatype, points },
        description: `创建 L${layer} 多边形 ${points.length} 顶点`,
      };
      return [cmd];
    }

    if (op === 'create_path') {
      const parts = rest.split('|');
      if (parts.length < 4) return null; // layer + width + 至少 2 个点
      const layerKey: string[] = parts[0].split('/');
      const layer = Number(layerKey[0]);
      const datatype = layerKey.length > 1 ? Number(layerKey[1]) : 0;
      if (layerKey.length > 2 || !Number.isInteger(layer) || !Number.isInteger(datatype) || layer < 0 || layer > 32767 || datatype < 0 || datatype > 32767) return null;
      const width = Number.parseFloat(parts[1]);
      if (Number.isNaN(layer) || Number.isNaN(width)) return null;
      const points: Point[] = [];
      for (let i = 2; i < parts.length; i++) {
        const xy = parts[i].split(',');
        if (xy.length !== 2) return null;
        const px = Number.parseFloat(xy[0]);
        const py = Number.parseFloat(xy[1]);
        if (Number.isNaN(px) || Number.isNaN(py)) return null;
        points.push({ x: px, y: py });
      }
      const cmd: ParsedCommand = {
        type: AiCommandType.CREATE_PATH,
        params: { layer, datatype, width, points },
        description: `创建 L${layer} 路径 ${points.length} 顶点 线宽${width}nm`,
      };
      return [cmd];
    }

    if (op === 'create_text') {
      const parts = rest.split('|');
      if (parts.length < 4) return null;
      const layerKey: string[] = parts[0].split('/');
      const layer = Number(layerKey[0]);
      const datatype = layerKey.length > 1 ? Number(layerKey[1]) : 0;
      if (layerKey.length > 2 || !Number.isInteger(layer) || !Number.isInteger(datatype) || layer < 0 || layer > 32767 || datatype < 0 || datatype > 32767) return null;
      const x = Number.parseFloat(parts[1]);
      const y = Number.parseFloat(parts[2]);
      // Text is the final unescaped field recorded by the workbench. Keep pipes
      // and trailing whitespace as content instead of splitting them into args.
      const text = parts.slice(3).join('|');
      if (Number.isNaN(layer) || Number.isNaN(x) || Number.isNaN(y)) return null;
      const cmd: ParsedCommand = {
        type: AiCommandType.CREATE_TEXT,
        params: { layer, datatype, x, y, text },
        description: `创建 L${layer} 文本 "${text}" @(${x},${y})`,
      };
      return [cmd];
    }

    if (op === 'create_instance') {
      const parts = rest.split('|');
      if (parts.length < 5) return null;
      const cellId = Number.parseInt(parts[0], 10);
      const x = Number.parseFloat(parts[1]);
      const y = Number.parseFloat(parts[2]);
      const rotation = Number.parseFloat(parts[3]);
      const mirror = Number.parseInt(parts[4], 10);
      if (Number.isNaN(cellId) || Number.isNaN(x) || Number.isNaN(y) || Number.isNaN(rotation) || Number.isNaN(mirror)) {
        return null;
      }
      const cellName = parts.length >= 6 ? parts.slice(5).join('|') : undefined;
      // 直接执行：createInstance 无对应 AiCommandType，在 parsePipeCommand 中直接调用
      editService.createInstance(cellId, x, y, rotation, mirror, cellName);
      return [this.noOpCommand(`放置实例 ${cellName ?? `cell=${cellId}`} @(${x},${y})`) ];
    }

    if (op === 'move_shape') {
      const parts = rest.split('|');
      if (parts.length !== 3) return null;
      const shapeId = Number.parseInt(parts[0], 10);
      const dx = Number.parseFloat(parts[1]);
      const dy = Number.parseFloat(parts[2]);
      if (Number.isNaN(shapeId) || Number.isNaN(dx) || Number.isNaN(dy)) {
        return null;
      }
      // MACRO-2: 直接调用 moveShape 而非改变选中状态再执行 MOVE_SHAPE，
      // 避免宏执行后永久改变用户选中状态
      if (!editService.moveShape(shapeId, dx, dy)) {
        return [this.noOpCommand(`图形 #${shapeId} 不存在，移动失败`, false)];
      }
      return [this.noOpCommand(`移动图形 #${shapeId} (${dx},${dy})`) ];
    }

    if (op === 'delete_shapes') {
      const idStrs = rest.split(',');
      const ids: number[] = [];
      for (let i = 0; i < idStrs.length; i++) {
        const n = Number.parseInt(idStrs[i].trim(), 10);
        if (!Number.isNaN(n)) {
          ids.push(n);
        }
      }
      if (ids.length === 0) return null;
      const shapes = editService.getShapes();
      if (ids.some((id: number): boolean => {
        const shape = shapes.find(s => s.id === id);
        return shape === undefined || !editService.canEditLayer(shape.layerNumber, shape.datatype);
      })) return [this.noOpCommand('删除失败：宏中的图形已不存在或图层锁定，整批未执行', false)];
      // MACRO-2: 直接调用 deleteShape 而非改变选中状态再执行 DELETE_SHAPE，
      // 避免宏执行后永久改变用户选中状态
      let deletedCount = 0;
      if (ids.length > 1) {
        editService.beginBatch();
      }
      try {
        for (let i = 0; i < ids.length; i++) {
          if (editService.deleteShape(ids[i])) {
            deletedCount++;
          }
        }
      } finally {
        if (ids.length > 1) {
          editService.endBatch();
        }
      }
      if (deletedCount !== ids.length) return [this.noOpCommand('删除未完整执行，整批回滚', false)];
      return [this.noOpCommand(`删除 ${deletedCount} 个图形`) ];
    }

    if (op === 'align') {
      if (!this.isAlignType(rest)) {
        return [this.noOpCommand(`未知对齐方式: ${rest}`, false)];
      }
      // 直接执行：align 无对应 executor 处理，在 parsePipeCommand 中直接调用
      const ok = advEditService.alignSelection(rest as AlignType);
      if (!ok) {
        return [this.noOpCommand(`对齐失败：需要至少 2 个可对齐的选中图形 (${rest})`, false)];
      }
      return [this.noOpCommand(`对齐 ${rest}`)];
    }

    if (op === 'distribute') {
      if (!this.isDistributeType(rest)) {
        return [this.noOpCommand(`未知分布方式: ${rest}`, false)];
      }
      const ok = advEditService.distributeSelection(rest as DistributeType);
      if (!ok) {
        return [this.noOpCommand(`分布失败：需要至少 3 个可分布的选中图形 (${rest})`, false)];
      }
      return [this.noOpCommand(`分布 ${rest}`)];
    }

    if (op === 'change_layer') {
      const parts = rest.split('|');
      if (parts.length !== 2) return null;
      const idStrs = parts[0].split(',');
      const ids: number[] = [];
      for (let i = 0; i < idStrs.length; i++) {
        const n = Number.parseInt(idStrs[i].trim(), 10);
        if (!Number.isNaN(n)) ids.push(n);
      }
      const layerKey: string[] = parts[1].split('/');
      const newLayer = Number(layerKey[0]);
      const datatype = layerKey.length > 1 ? Number(layerKey[1]) : 0;
      if (layerKey.length > 2 || !Number.isInteger(newLayer) || !Number.isInteger(datatype) || newLayer < 0 || newLayer > 32767 || datatype < 0 || datatype > 32767) return null;
      if (Number.isNaN(newLayer) || ids.length === 0) return null;
      let existingCount = 0;
      const shapes = editService.getShapes();
      if (ids.some((id: number): boolean => shapes.find(s => s.id === id) === undefined)) {
        return [this.noOpCommand('改层失败：宏中的图形已不存在，整批未执行', false)];
      }
      for (let i = 0; i < ids.length; i++) {
        if (shapes.find(s => s.id === ids[i]) !== undefined) {
          existingCount++;
        }
      }
      if (existingCount === 0) {
        return [this.noOpCommand(`未找到可改层的图形 (${ids.join(',')})`, false)];
      }
      if (!editService.canEditLayer(newLayer, datatype)) {
        return [this.noOpCommand(`目标图层 ${newLayer}/${datatype} 已锁定`, false)];
      }
      for (let i = 0; i < ids.length; i++) {
        const shape = shapes.find(s => s.id === ids[i]);
        if (shape !== undefined && !editService.canEditLayer(shape.layerNumber, shape.datatype)) {
          return [this.noOpCommand(`源图层 ${shape.layerNumber}/${shape.datatype} 已锁定`, false)];
        }
      }
      const result = editService.changeLayer(ids, newLayer, datatype);
      return [this.noOpCommand(result.ok ? `改图层到 L${newLayer}/D${datatype} (${result.changed} 个图形)` : result.message, result.ok)];
    }

    return null;
  }

  private isAlignType(value: string): boolean {
    return value === AlignType.LEFT
      || value === AlignType.RIGHT
      || value === AlignType.TOP
      || value === AlignType.BOTTOM
      || value === AlignType.CENTER_H
      || value === AlignType.CENTER_V;
  }

  private isDistributeType(value: string): boolean {
    return value === DistributeType.HORIZONTAL || value === DistributeType.VERTICAL;
  }

  /** 生成 BATCH_OPERATION no-op 命令（操作已在 parsePipeCommand 中直接执行） */
  private noOpCommand(description: string, ok: boolean = true): ParsedCommand {
    return {
      type: AiCommandType.BATCH_OPERATION,
      params: { ok, message: description },
      description: description,
    };
  }

  // ===== 导入导出 =====

  /** 导出宏为 JSON */
  exportMacro(id: number): string | null {
    const macro = this.macros.get(id);
    if (!macro) return null;

    const macroPayload: MacroExportItem = {
      name: macro.name,
      description: macro.description,
      steps: this.copySteps(macro.steps),
      originDocumentId: macro.originDocumentId,
    };
    const payload: MacroExportPayload = {
      format: 'HongTu-Macro',
      version: '1.0',
      macro: macroPayload,
    };
    return JSON.stringify(payload, null, 2);
  }

  /** 导出所有宏 */
  exportAllMacros(): string {
    const macros: MacroCollectionItem[] = [];
    const allMacros: Macro[] = Array.from(this.macros.values());
    for (let i = 0; i < allMacros.length; i++) {
      const macro = allMacros[i];
      const item: MacroCollectionItem = {
        name: macro.name,
        description: macro.description,
        steps: this.copySteps(macro.steps),
        builtin: macro.builtin,
        originDocumentId: macro.originDocumentId,
      };
      macros.push(item);
    }

    const payload: MacroCollectionExportPayload = {
      format: 'HongTu-Macro-Collection',
      version: '1.0',
      exportedAt: new Date().toISOString(),
      macros: macros,
    };
    return JSON.stringify(payload, null, 2);
  }

  /** 从 JSON 导入宏 */
  importMacro(json: string): Macro | null {
    try {
      if (json.length > 1024 * 1024) return null;
      const data = JSON.parse(json) as MacroImportPayload;
      const m: MacroImportCandidate = data.macro !== undefined ? data.macro : data;
      const steps = m.steps;
      if (steps === undefined || !this.validSteps(steps) || typeof m.name !== 'string' || !m.name.trim() || m.name.length > 120 ||
        (m.description !== undefined && (typeof m.description !== 'string' || m.description.length > 4000)) || !this.validOrigin(m.originDocumentId)) return null;

      const macro: Macro = {
        id: this.nextId,
        name: m.name ?? '导入的宏',
        description: m.description ?? '',
        steps: this.copySteps(steps),
        createdAt: Date.now(),
        updatedAt: Date.now(),
        builtin: false,
        originDocumentId: m.originDocumentId,
      };
      this.commitMutation(() => { this.nextId++; this.macros.set(macro.id, macro); });
      return macro;
    } catch {
      return null;
    }
  }

  private copySteps(steps: MacroStep[]): MacroStep[] {
    const copied: MacroStep[] = [];
    for (let i = 0; i < steps.length; i++) {
      const step = steps[i];
      copied.push({
        description: step.description,
        command: step.command,
        type: step.type,
      });
    }
    return copied;
  }

  private validOrigin(originDocumentId?: string): boolean {
    return originDocumentId === undefined || (typeof originDocumentId === 'string' &&
      /^[A-Za-z0-9_-]{1,240}$/.test(originDocumentId) && originDocumentId.trim() === originDocumentId);
  }

  private hasDocumentIds(steps: MacroStep[]): boolean {
    return steps.some((step: MacroStep) => /^(move_shape|delete_shapes|change_layer|create_instance)\s*\|/.test(step.command.trim()));
  }

  /** Validate imported/editor data before a mutation or replay is possible. */
  validSteps(steps: MacroStep[]): boolean {
    if (!Array.isArray(steps) || steps.length === 0 || steps.length > 1000) return false;
    const types: string[] = ['draw', 'edit', 'layer', 'view', 'drc', 'ai'];
    return steps.every((step: MacroStep) => step !== null && typeof step === 'object' &&
      typeof step.command === 'string' && step.command.trim().length > 0 && step.command.length <= 16000 &&
      typeof step.description === 'string' && step.description.length <= 1000 && types.includes(step.type) &&
      this.validTransformCommand(step.command) && this.validPipeCommand(step.command));
  }

  private validNumberToken(token: string): boolean {
    return /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(token.trim()) && Number.isFinite(Number(token));
  }

  private validIdToken(token: string, minimum: number): boolean {
    return /^\d+$/.test(token.trim()) && Number.isSafeInteger(Number(token)) && Number(token) >= minimum;
  }

  private validLayerToken(token: string): boolean {
    const parts: string[] = token.split('/');
    return parts.length <= 2 && parts.every((part: string): boolean => this.validIdToken(part, 0) && Number(part) <= 32767);
  }

  private validIdList(token: string): boolean {
    const parts: string[] = token.split(',');
    return parts.every((part: string): boolean => this.validIdToken(part, 1)) &&
      new Set<number>(parts.map((part: string): number => Number(part))).size === parts.length;
  }

  /** Recorded pipe opcodes have strict numeric tokens; malformed inputs cannot fall through to AI parsing. */
  private validPipeCommand(command: string): boolean {
    const parts: string[] = command.trimStart().split('|');
    const op: string = parts[0].trim();
    if (op === 'create_rect') return parts.length === 6 && this.validLayerToken(parts[1]) &&
      parts.slice(2).every((part: string): boolean => this.validNumberToken(part));
    if (op === 'create_polygon' || op === 'create_path') {
      const pointStart: number = op === 'create_path' ? 3 : 2;
      if (parts.length < 5 || !this.validLayerToken(parts[1]) || (op === 'create_path' &&
        (!this.validNumberToken(parts[2]) || Number(parts[2]) <= 0))) return false;
      return parts.slice(pointStart).every((part: string): boolean => {
        const xy: string[] = part.split(',');
        return xy.length === 2 && xy.every((number: string): boolean => this.validNumberToken(number));
      });
    }
    if (op === 'create_text') return parts.length >= 5 && this.validLayerToken(parts[1]) &&
      this.validNumberToken(parts[2]) && this.validNumberToken(parts[3]) && parts.slice(4).join('|').length > 0;
    if (op === 'create_instance') return parts.length >= 6 && this.validIdToken(parts[1], 0) &&
      parts.slice(2, 5).every((part: string): boolean => this.validNumberToken(part)) &&
      this.validIdToken(parts[5], 0) && Number(parts[5]) <= 2;
    if (op === 'move_shape') return parts.length === 4 && this.validIdToken(parts[1], 1) &&
      this.validNumberToken(parts[2]) && this.validNumberToken(parts[3]);
    if (op === 'delete_shapes') return parts.length === 2 && this.validIdList(parts[1]);
    if (op === 'change_layer') return parts.length === 3 && this.validIdList(parts[1]) && this.validLayerToken(parts[2]);
    return true;
  }

  /** The AI prompt list is bounded. Workbench playback supplies the complete current Cell registry separately. */
  private validateInstanceReferences(steps: MacroStep[], cells?: MacroCellReference[]): string {
    const instances: MacroStep[] = steps.filter((step: MacroStep): boolean => step.command.trimStart().split('|')[0].trim() === 'create_instance');
    if (instances.length === 0) return '';
    if (!Array.isArray(cells) || cells.length === 0 || cells.length > 100000) return '宏实例缺少有效的当前 Cell 清单，整批未执行';
    const names: Map<number, string> = new Map<number, string>();
    for (const cell of cells) {
      if (cell === null || !Number.isSafeInteger(cell.id) || cell.id < 0 || names.has(cell.id) ||
        typeof cell.name !== 'string' || cell.name.length === 0 || cell.name.length > 512) return '宏实例的当前 Cell 清单无效，整批未执行';
      names.set(cell.id, cell.name);
    }
    for (const instance of instances) {
      const parts: string[] = instance.command.trimStart().split('|');
      const cellId: number = Number(parts[1]);
      const name: string | undefined = names.get(cellId);
      if (name === undefined) return `宏引用的 Cell #${cellId} 已不存在，整批未执行`;
      if (parts.length >= 7 && parts.slice(6).join('|') !== name) return `宏引用的 Cell #${cellId} 名称已变化，请重新录制；整批未执行`;
    }
    return '';
  }

  private validTransformCommand(command: string): boolean {
    const parts: string[] = command.trim().split('|');
    parts[0] = parts[0].trim();
    if (parts[0] !== 'rotate' && parts[0] !== 'mirror' && parts[0] !== 'scale') return true;
    if (parts.length !== 2 || !/^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(parts[1])) return false;
    const value: number = Number(parts[1]);
    if (!Number.isFinite(value)) return false;
    return parts[0] === 'mirror' ? (value === 0 || value === 1) : parts[0] === 'scale' ? value > 0 : true;
  }

  importCollection(json: string, deduplicate: boolean = false): number {
    if (json.length > 1024 * 1024) throw new Error('宏文件超过 1 MiB');
    const data = JSON.parse(json) as MacroCollectionExportPayload;
    if (!Array.isArray(data.macros)) {
      if (this.importMacro(json) === null) throw new Error('宏格式无效：需要名称与有效步骤');
      return 1;
    }
    if (data.macros.length === 0 || data.macros.length > 100) throw new Error('一次导入 1–100 个宏');
    for (const item of data.macros) {
      if (item === null || typeof item !== 'object' || typeof item.name !== 'string' || !item.name.trim() || item.name.length > 120 || !this.validSteps(item.steps) ||
        (item.description !== undefined && (typeof item.description !== 'string' || item.description.length > 4000)) || !this.validOrigin(item.originDocumentId)) {
        throw new Error('集合中存在无效宏，未导入任何项目');
      }
    }
    let imported: number = 0;
    this.commitMutation(() => {
      for (const item of data.macros) {
        const identical: boolean = deduplicate && Array.from(this.macros.values()).some((macro: Macro): boolean =>
          !macro.builtin && macro.name === item.name.trim() && macro.description === (item.description ?? '') &&
          macro.originDocumentId === item.originDocumentId && JSON.stringify(macro.steps) === JSON.stringify(item.steps));
        if (identical) continue;
        const macro: Macro = { id: this.nextId++, name: item.name.trim(), description: item.description ?? '',
          steps: this.copySteps(item.steps), createdAt: Date.now(), updatedAt: Date.now(), builtin: false,
          originDocumentId: item.originDocumentId };
        this.macros.set(macro.id, macro); imported++;
      }
    });
    return imported;
  }

  // ===== 内置宏 =====

  private replaceBuiltinMacros(): void {
    this.macros.clear();
    this.nextId = 1;

    this.createMacro(
      '创建 CMOS 反相器',
      '在当前版图中生成一个可编辑的反相器模板。',
      [
        { description: '生成反相器模板', command: '创建反相器', type: 'draw' },
        { description: '适配全部图形', command: '适配全部', type: 'view' },
      ],
    );
    this.markBuiltin(this.nextId - 1);

    this.createMacro(
      '创建 M1 宽度测试',
      '创建一个 160x80nm 的 M1 矩形，可直接用于 DRC 宽度规则验证。',
      [
        { description: '创建 M1 测试矩形', command: '创建一个 160x80nm 的 M1 矩形', type: 'draw' },
      ],
    );
    this.markBuiltin(this.nextId - 1);

    this.createMacro(
      '运行 28nm DRC',
      '对当前版图执行规则检查，并切换到验证结果面板。',
      [
        { description: '运行 DRC', command: '运行 DRC 检查', type: 'drc' },
      ],
    );
    this.markBuiltin(this.nextId - 1);

    this.createMacro(
      '只看互连层',
      '隐藏非互连主层，仅保留 M1/M2 视图。',
      [
        { description: '隐藏其它层', command: '隐藏 M3，只看 M1/M2 互连', type: 'view' },
      ],
    );
    this.markBuiltin(this.nextId - 1);
  }

  private markBuiltin(id: number) {
    const macro = this.macros.get(id);
    if (macro) macro.builtin = true;
  }

  // ===== 宏持久化（仅自定义宏，App 重启后恢复） =====

  private static readonly CUSTOM_MACRO_STORAGE_KEY: string = 'macro_custom_list';

  /** 持久化用户自定义宏（非内置宏）到 PersistentStorage */
  private persistCustomMacros(): void {
    if (!this.initialized) return;
      const items: MacroPersistItem[] = [];
      this.macros.forEach((macro: Macro) => {
        if (!macro.builtin) {
          const item: MacroPersistItem = {
            id: macro.id,
            name: macro.name,
            description: macro.description,
            steps: this.copySteps(macro.steps),
            createdAt: macro.createdAt,
            updatedAt: macro.updatedAt,
            shortcut: macro.shortcut,
            originDocumentId: macro.originDocumentId,
          };
          items.push(item);
        }
      });
      const encoded: string = JSON.stringify(items);
      AppStorage.setOrCreate<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY, encoded);
      if (AppStorage.get<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY) !== encoded) throw new Error('宏存储回读不一致');
  }

  /** 从 PersistentStorage 加载用户自定义宏 */
  private loadCustomMacros(): void {
    try {
      PersistentStorage.persistProp(MacroService.CUSTOM_MACRO_STORAGE_KEY, '[]');
      const raw: string = AppStorage.get<string>(MacroService.CUSTOM_MACRO_STORAGE_KEY) ?? '[]';
      const parsed: Object = JSON.parse(raw);
      // MACRO-1: 防御性校验，避免 JSON.parse 返回非数组导致后续循环异常
      if (!Array.isArray(parsed)) {
        // 非 数组结构，视为空列表，安全初始化
        this.initialized = true;
        return;
      }
      const items = parsed as MacroPersistItem[];
      let maxId = this.nextId - 1;
      for (let i = 0; i < items.length; i++) {
        const item = items[i];
        // MACRO-1: 对每个 item 做与 importMacro 等同的结构校验，坏 item 跳过而非整体失败
        if (item === null || item === undefined) continue;
        const steps = item.steps;
        if (steps === undefined || !this.validSteps(steps) || !this.validOrigin(item.originDocumentId)) continue;
        const macro: Macro = {
          id: item.id,
          name: item.name ?? '未命名宏',
          description: item.description ?? '',
          steps: this.copySteps(steps),
          createdAt: item.createdAt ?? Date.now(),
          updatedAt: item.updatedAt ?? Date.now(),
          builtin: false,
          originDocumentId: item.originDocumentId,
        };
        if (item.shortcut !== undefined) {
          macro.shortcut = item.shortcut;
        }
        this.macros.set(macro.id, macro);
        if (macro.id > maxId) {
          maxId = macro.id;
        }
      }
      this.nextId = maxId + 1;
      // MACRO-1: 仅在完整成功加载后才标记 initialized，避免加载异常时下次 persistCustomMacros 覆盖原始存储
      this.initialized = true;
    } catch (e) {
      console.error('加载自定义宏失败: ' + e);
      // MACRO-1: 加载失败时也标记 initialized 以允许后续重试，但不会触发 persistCustomMacros 覆盖
      // （persistCustomMacros 仅在用户主动操作时触发，此时 initialized 已为 true）
      this.initialized = true;
    }
  }
}

/** 宏服务单例 */
export const macroService = new MacroService();
