/**
 * 鸿图 AI 命令执行器
 *
 * 将 AiService 解析出的 ParsedCommand 列表通过 EditService / DrcService 等
 * 服务执行，并返回执行结果。
 *
 * 支持批量执行和单步执行（用户可在 AI 面板中逐条确认）。
 *
 * 关键设计：
 * - 编辑命令（创建/移动/删除）直接调用 EditService
 * - 视口命令（缩放/适配/选层/可见性/工具）通过 ViewAction 返回给 UI 层处理
 * - DRC 命令执行后通过 ViewAction 通知 UI 切换到验证面板
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { ParsedCommand, AiCommandType, AiContext } from './AiService';
import { editService } from './EditService';
import { advEditService } from './AdvancedEditService';
import { drcService, DrcResult } from './DrcService';
import { Point, ShapeType, getShapeBounds } from '../models/GdsiiData';
import { DrawTool } from '../common/types';
import { cloneStructured } from '../common/CloneUtils';

/** 图层可见性条目 */
export interface LayerVisibility {
  layer: number;
  datatype?: number;
  visible: boolean;
}

interface AiLayerTarget {
  layer: number;
  datatype: number;
}

export interface AiFocusBounds { minX: number; minY: number; maxX: number; maxY: number; }

/** 视口动作（由 UI 层处理） */
export interface ViewAction {
  focusBounds?: AiFocusBounds;
  /** 切换到指定图层 */
  selectLayer?: number;
  selectDatatype?: number;
  /** 设置图层可见性 — Fix ⑦: 改为数组支持多条合并 */
  layerVisible?: LayerVisibility;
  /** Fix ⑦: 多条图层可见性操作合并 */
  layerVisibles?: LayerVisibility[];
  /** 设置缩放比例 */
  zoomScale?: number;
  /** 适配全部 */
  fitAll?: boolean;
  /** 切换工具 */
  tool?: DrawTool;
  /** 切换到验证面板并显示 DRC 结果 */
  showDrc?: DrcResult;
}

/** 命令执行结果 */
export interface CommandResult {
  command: ParsedCommand;
  success: boolean;
  message: string;
  /** 执行后受影响的图形 ID */
  affectedShapeIds: number[];
  /** 视口动作（UI 层处理） */
  viewAction?: ViewAction;
  /** Fix ④: 校验警告（不阻止执行，但提示用户） */
  warnings?: string[];
}

/**
 * AI 命令执行器
 */
export class AiCommandExecutor {
  /**
   * 批量执行命令
   * @param commands 待执行命令列表
   * @param context 编辑器上下文
   * @param onProgress 每条命令执行后回调
   */
  async executeBatch(
    commands: ParsedCommand[],
    context: AiContext,
    onProgress: (index: number, result: CommandResult) => void
  ): Promise<CommandResult[]> {
    const results: CommandResult[] = [];
    const executionContext: AiContext = cloneStructured(context) as AiContext;

    try {
      if (commands.length > 256) throw new Error('AI 命令超过 256 条预算');
      let shapes: number = 0;
      let points: number = 0;
      for (const command of commands) {
        this.validateGeometryParameters(command);
        shapes += this.createdShapeCount(command);
        points += this.createdPointCount(command);
      }
      this.assertCreationBudget(shapes, points);
    } catch (error) {
      if (commands.length === 0) return [];
      const rejected: CommandResult = { command: commands[0], success: false,
        message: `执行异常: ${error}`, affectedShapeIds: [] };
      onProgress(0, rejected);
      return [rejected];
    }

    if (commands.length === 0) return [];
    const preBatchSession = editService.captureSession(true);
    const preUndoMarker: Object | null = editService.getUndoMarker();
    let batchCompleted: boolean = false;
    let batchOpened: boolean = false;

    // 批处理开始 — 所有命令作为一个原子事务；任一子命令失败或抛异常时执行逆序撤销并完整回滚会话，绝不提交半截批次
    editService.beginBatch();
    batchOpened = true;

    try {
      for (let i = 0; i < commands.length; i++) {
        const result = this.execute(commands[i], executionContext);
        results.push(result);
        onProgress(i, result);
        if (!result.success) {
          batchCompleted = false;
          break;
        }
        if (result.viewAction?.selectLayer !== undefined) {
          executionContext.currentLayer = result.viewAction.selectLayer;
          executionContext.currentDatatype = result.viewAction.selectDatatype ?? 0;
        }
        if (i === commands.length - 1) {
          batchCompleted = true;
        }
      }
    } finally {
      if (batchOpened) {
        editService.endBatch();
      }
      if (!batchCompleted) {
        // 先逆序回放本次批处理产生的撤销动作，再恢复会话基线以彻底清除半截 redo/dirty 痕迹
        try {
          if (editService.getUndoMarker() !== preUndoMarker) {
            editService.undo();
          }
        } catch (_) {}
        editService.restoreSession(preBatchSession, true);
        for (let r = 0; r < results.length; r++) {
          if (results[r].success) {
            results[r].affectedShapeIds = [];
          }
        }
      }
    }

    return results;
  }

  /**
   * 执行单条命令
   */
  execute(command: ParsedCommand, context: AiContext): CommandResult {
    // Fix ④: 命令预校验
    let warnings: string[] = [];
    let previousSelection: number[] | undefined;

    try {
      this.validateGeometryParameters(command);
      this.validateLayerValue(command.params.layer, 'layer');
      this.validateLayerValue(command.params.datatype, 'datatype');
      const targetsSelection: boolean = [AiCommandType.MOVE_SHAPE, AiCommandType.DELETE_SHAPE, AiCommandType.ROTATE_SHAPE,
        AiCommandType.MIRROR_SHAPE, AiCommandType.SCALE_SHAPE].includes(command.type) ||
        (command.type === AiCommandType.CREATE_ARRAY && command.params.width === undefined && command.params.height === undefined);
      if (targetsSelection && command.params.shapeIds !== undefined) {
        previousSelection = editService.getSelectedIds().slice();
        this.execSelectShape(command, context);
      }
      this.assertCreationBudget(this.createdShapeCount(command), this.createdPointCount(command));
      warnings = this.validateCommand(command, context);
      if (command.type === AiCommandType.MOVE_SHAPE || command.type === AiCommandType.DELETE_SHAPE ||
        command.type === AiCommandType.ROTATE_SHAPE || command.type === AiCommandType.MIRROR_SHAPE ||
        command.type === AiCommandType.SCALE_SHAPE ||
        (command.type === AiCommandType.CREATE_ARRAY && command.params.width === undefined)) {
        this.assertSelectedLayersEditable();
      }
      let result: CommandResult;
      switch (command.type) {
        case AiCommandType.CREATE_RECT:
          result = this.execCreateRect(command, context);
          break;
        case AiCommandType.CREATE_POLYGON:
          result = this.execCreatePolygon(command, context);
          break;
        case AiCommandType.CREATE_PATH:
          result = this.execCreatePath(command, context);
          break;
        case AiCommandType.CREATE_TEXT:
          result = this.execCreateText(command, context);
          break;
        case AiCommandType.CREATE_ARRAY:
          result = this.execCreateArray(command, context);
          break;
        case AiCommandType.SELECT_LAYER:
          result = this.execSelectLayer(command, context);
          break;
        case AiCommandType.SELECT_SHAPE:
          result = this.execSelectShape(command, context);
          break;
        case AiCommandType.MOVE_SHAPE:
          result = this.execMoveShape(command);
          break;
        case AiCommandType.DELETE_SHAPE:
          result = this.execDeleteShape(command);
          break;
        // AICMD-2: 旋转/镜像/缩放委派给 AdvancedEditService
        case AiCommandType.ROTATE_SHAPE:
          result = this.execRotateShape(command);
          break;
        case AiCommandType.MIRROR_SHAPE:
          result = this.execMirrorShape(command);
          break;
        case AiCommandType.SCALE_SHAPE:
          result = this.execScaleShape(command);
          break;
        case AiCommandType.SET_LAYER_VISIBLE:
          result = this.execSetLayerVisible(command, context);
          break;
        case AiCommandType.ZOOM:
          result = this.execZoom(command);
          break;
        case AiCommandType.FIT_ALL:
          result = this.execFitAll(command);
          break;
        case AiCommandType.RUN_DRC:
          result = this.execRunDrc(command);
          break;
        case AiCommandType.SET_TOOL:
          result = this.execSetTool(command);
          break;
        case AiCommandType.BATCH_OPERATION:
          // MACRO-2: 宏回放中已由 parsePipeCommand 直接执行，此处仅作 no-op 确认
          result = {
            command, success: command.params.ok === true && typeof command.params.message === 'string' && command.params.message.trim().length > 0,
            message: command.params.message ?? '缺少宏内部批次执行结果',
            affectedShapeIds: [],
          };
          break;
        default:
          result = {
            command, success: false,
            message: `未知命令类型: ${command.type}`,
            affectedShapeIds: [],
          };
      }
      if (warnings.length > 0) {
        result.warnings = (result.warnings ?? []).concat(warnings);
      }
      if (!result.success && previousSelection !== undefined) editService.selectMultiple(previousSelection);
      return result;
    } catch (e) {
      if (previousSelection !== undefined) editService.selectMultiple(previousSelection);
      return {
        command, success: false,
        message: `执行异常: ${e}`,
        affectedShapeIds: [],
        warnings: warnings.length > 0 ? warnings : undefined,
      };
    }
  }

  // ===== 命令预校验 (Fix ④) =====
  private validateLayerValue(value: number | undefined, name: string): void {
    if (value !== undefined && (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 32767)) {
      throw new Error(`${name} 必须是 0..32767 的整数`);
    }
  }

  /** 省略 dtype 只继承当前层的类型，不把当前类型带到其他层。 */
  private resolveLayer(cmd: ParsedCommand, context: AiContext): AiLayerTarget {
    const layer: number = cmd.params.layer ?? context.currentLayer;
    const datatype: number = cmd.params.datatype ??
      (layer === context.currentLayer ? (context.currentDatatype ?? 0) : 0);
    this.validateLayerValue(layer, 'layer');
    this.validateLayerValue(datatype, 'datatype');
    return { layer: layer, datatype: datatype };
  }

  private assertSelectedLayersEditable(): void {
    const shapes = editService.getSelectedShapes();
    for (const shape of shapes) {
      if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) {
        throw new Error(`L${shape.layerNumber}/${shape.datatype} 图层已锁定，不能编辑图形`);
      }
    }
  }

  /**
   * 校验命令参数合法性，返回警告列表（不阻止执行）
   * - 图层号是否存在
   * - 坐标是否在合理范围 (±1,000,000nm)
   * - 尺寸是否为正数
   * - 多边形顶点数 ≥ 3
   */
  private validateCommand(command: ParsedCommand, context: AiContext): string[] {
    const warnings: string[] = [];
    const validLayers = new Set(context.layers.map(l => `${l.layerNumber}/${l.datatype ?? 0}`));
    const MAX_COORD = 1_000_000;
    const type = command.type;
    const params = command.params;

    // 图层号校验
    if (params.layer !== undefined || params.datatype !== undefined) {
      const target = this.resolveLayer(command, context);
      if (validLayers.size > 0 && !validLayers.has(`${target.layer}/${target.datatype}`)) {
        warnings.push(`图层 L${target.layer}/${target.datatype} 不在当前图层列表中`);
      }
    }

    // 坐标范围校验
    const checkCoord = (val: number | undefined, name: string) => {
      if (val !== undefined && (val < -MAX_COORD || val > MAX_COORD)) {
        warnings.push(`${name}=${val} 超出合理范围 (±${MAX_COORD}nm)`);
      }
    };
    checkCoord(params.x, 'x');
    checkCoord(params.y, 'y');
    checkCoord(params.dx, 'dx');
    checkCoord(params.dy, 'dy');

    // 尺寸校验
    if (type === AiCommandType.CREATE_RECT || (type === AiCommandType.CREATE_ARRAY && (params.width !== undefined || params.height !== undefined))) {
      if (params.width !== undefined && params.width <= 0) {
        warnings.push(`width=${params.width} 必须为正数`);
      }
      if (params.height !== undefined && params.height <= 0) {
        warnings.push(`height=${params.height} 必须为正数`);
      }
    }

    // 阵列行列校验
    if (type === AiCommandType.CREATE_ARRAY) {
      if (params.rows !== undefined && (params.rows < 1 || params.rows > 1000)) {
        warnings.push(`rows=${params.rows} 超出合理范围 (1-1000)`);
      }
      if (params.cols !== undefined && (params.cols < 1 || params.cols > 1000)) {
        warnings.push(`cols=${params.cols} 超出合理范围 (1-1000)`);
      }
    }

    // 缩放校验
    if (type === AiCommandType.ZOOM && params.scale !== undefined) {
      if (params.scale < 1 || params.scale > 100000) {
        warnings.push(`scale=${params.scale} 超出合理范围 (1-100000)`);
      }
    }

    return warnings;
  }

  private validateGeometryParameters(command: ParsedCommand): void {
    if (command === null || typeof command !== 'object' || command.params === null ||
      typeof command.params !== 'object' || Array.isArray(command.params)) throw new Error('命令 params 必须是对象');
    const p = command.params;
    const values: (number | undefined)[] = [p.x, p.y, p.dx, p.dy, p.width, p.height,
      p.spacingX, p.spacingY, p.scale, p.degrees, p.horizontal, p.centerX, p.centerY];
    const names: string[] = ['x', 'y', 'dx', 'dy', 'width', 'height', 'spacingX', 'spacingY', 'scale', 'degrees', 'horizontal', 'centerX', 'centerY'];
    for (let i = 0; i < values.length; i++) {
      const value: number | undefined = values[i];
      if (value !== undefined && !Number.isFinite(value)) throw new Error(`${names[i]} 必须是有限数值`);
    }
    if (p.visible !== undefined && typeof p.visible !== 'boolean') throw new Error('visible 必须是布尔值');
    if (p.focus !== undefined && typeof p.focus !== 'boolean') throw new Error('focus 必须是布尔值');
    if (p.horizontal !== undefined && p.horizontal !== 0 && p.horizontal !== 1) throw new Error('horizontal 必须是 0 或 1');
    if ((p.centerX === undefined) !== (p.centerY === undefined)) throw new Error('变换中心需要同时提供 centerX 和 centerY');
    const type: AiCommandType = command.type;
    if (type === AiCommandType.SELECT_SHAPE && ((p.x === undefined) !== (p.y === undefined))) {
      throw new Error('坐标选择需要同时提供 x 和 y，不能按不完整坐标改选整层');
    }
    if (type === AiCommandType.ZOOM && p.scale !== undefined && p.scale <= 0) throw new Error('缩放比例必须为正数');
    if (type === AiCommandType.CREATE_RECT || (type === AiCommandType.CREATE_ARRAY && (p.width !== undefined || p.height !== undefined))) {
      if (p.width === undefined || p.height === undefined || p.width <= 0 || p.height <= 0) throw new Error('矩形宽高必须为正数');
      if (!Number.isFinite((p.x ?? 0) + p.width) || !Number.isFinite((p.y ?? 0) + p.height)) throw new Error('矩形端点超出有限坐标范围');
    }
    if (type === AiCommandType.CREATE_ARRAY) {
      const rows: number = p.rows ?? 0;
      const cols: number = p.cols ?? 0;
      if (!Number.isInteger(rows) || !Number.isInteger(cols) || rows < 1 || cols < 1 || rows > 1000 || cols > 1000) {
        throw new Error('阵列行列必须为 1..1000 的整数');
      }
      if (rows * cols > 10000) throw new Error('阵列超过 10000 图形预算');
      if (p.width === undefined && p.height === undefined && (p.spacingX === undefined || p.spacingY === undefined)) throw new Error('选区阵列需要明确二维间距');
      if (!Number.isFinite((p.x ?? 0) + (cols - 1) * (p.spacingX ?? p.width ?? 0) + (p.width ?? 0)) ||
        !Number.isFinite((p.y ?? 0) + (rows - 1) * (p.spacingY ?? p.height ?? 0) + (p.height ?? 0))) {
        throw new Error('阵列端点超出有限坐标范围');
      }
    }
    if (type === AiCommandType.CREATE_POLYGON || type === AiCommandType.CREATE_PATH) {
      const points: Point[] | undefined = p.points;
      const minimum: number = type === AiCommandType.CREATE_PATH ? 2 : 3;
      if (!Array.isArray(points) || points.length < minimum || points.length > 10000) throw new Error(`图形需要 ${minimum}..10000 个有效坐标点`);
      for (const point of points) {
        if (point === null || typeof point !== 'object' || !Number.isFinite(point.x) || !Number.isFinite(point.y)) {
          throw new Error('图形坐标必须是有限数值');
        }
      }
      if (type === AiCommandType.CREATE_PATH && p.width !== undefined && p.width <= 0) throw new Error('路径宽度必须为正数');
    }
    if (type === AiCommandType.CREATE_TEXT && (typeof p.text !== 'string' || p.text.trim().length === 0 || p.text.length > 4096)) {
      throw new Error('文本需要 1..4096 个字符且不能为空白');
    }
  }

  private createdShapeCount(command: ParsedCommand): number {
    switch (command.type) {
      case AiCommandType.CREATE_ARRAY: {
        const copies: number = (command.params.rows ?? 0) * (command.params.cols ?? 0);
        if (command.params.width !== undefined) return copies;
        const ids: number[] = command.params.shapeIds ?? editService.getSelectedIds();
        return editService.getCurrentCellShapes().filter((shape): boolean => ids.includes(shape.id)).length * (copies - 1);
      }
      case AiCommandType.CREATE_RECT:
      case AiCommandType.CREATE_POLYGON:
      case AiCommandType.CREATE_PATH:
      case AiCommandType.CREATE_TEXT: return 1;
      default: return 0;
    }
  }

  private createdPointCount(command: ParsedCommand): number {
    switch (command.type) {
      case AiCommandType.CREATE_ARRAY: {
        if (command.params.width !== undefined) return this.createdShapeCount(command) * 2;
        const ids: number[] = command.params.shapeIds ?? editService.getSelectedIds();
        let points: number = 0;
        for (const shape of editService.getCurrentCellShapes()) if (ids.includes(shape.id)) points += shape.points.length;
        return points * ((command.params.rows ?? 0) * (command.params.cols ?? 0) - 1);
      }
      case AiCommandType.CREATE_RECT: return 2;
      case AiCommandType.CREATE_POLYGON:
      case AiCommandType.CREATE_PATH: return command.params.points?.length ?? 0;
      case AiCommandType.CREATE_TEXT: return 1;
      default: return 0;
    }
  }

  private assertCreationBudget(shapes: number, points: number): void {
    if (shapes > 10000 || points > 100000) throw new Error('AI 批次超过 10000 图形 / 100000 坐标点预算');
    if (shapes === 0) return;
    const existing = editService.getShapes();
    if (existing.length + shapes > 1000000) throw new Error('文档超过 1000000 图形预算');
    let totalPoints: number = points;
    for (const shape of existing) {
      totalPoints += shape.points?.length ?? 0;
      if (totalPoints > 4000000) throw new Error('文档超过 4000000 坐标点预算');
    }
  }

  private execCreateRect(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const datatype = target.datatype;
    const x = cmd.params.x;
    const y = cmd.params.y;
    const width = cmd.params.width;
    const height = cmd.params.height;
    if (layer === undefined || width === undefined || height === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer, x, y, width, height', affectedShapeIds: [] };
    }
    if (!editService.canEditLayer(layer, datatype)) {
      return { command: cmd, success: false, message: `L${layer}/${datatype} 图层已锁定，不能创建图形`, affectedShapeIds: [] };
    }
    const px = x ?? 0;
    const py = y ?? 0;
    const shape = editService.createRect(layer, px, py, px + width, py + height, datatype);
    editService.selectShape(shape.id);
    return {
      command: cmd, success: true,
      message: `已在 L${layer}/${datatype} 层创建 ${width}×${height}nm 矩形 (ID: ${shape.id})`,
      affectedShapeIds: [shape.id],
    };
  }

  private execCreatePolygon(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const datatype = target.datatype;
    const points = cmd.params.points;
    if (layer === undefined || !points || !Array.isArray(points) || points.length < 3) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer 和至少 3 个顶点', affectedShapeIds: [] };
    }
    if (!editService.canEditLayer(layer, datatype)) {
      return { command: cmd, success: false, message: `L${layer}/${datatype} 图层已锁定，不能创建图形`, affectedShapeIds: [] };
    }
    const pts: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const pt: Point = { x: p.x, y: p.y };
      pts.push(pt);
    }
    const shape = editService.createPolygon(layer, pts, datatype);
    editService.selectShape(shape.id);
    return {
      command: cmd, success: true,
      message: `已在 L${layer}/${datatype} 层创建多边形 (${pts.length} 个顶点, ID: ${shape.id})`,
      affectedShapeIds: [shape.id],
    };
  }

  private execCreatePath(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const datatype = target.datatype;
    const points = cmd.params.points;
    const width = cmd.params.width;
    if (layer === undefined || !points || !Array.isArray(points) || points.length < 2) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer 和至少 2 个点', affectedShapeIds: [] };
    }
    if (!editService.canEditLayer(layer, datatype)) {
      return { command: cmd, success: false, message: `L${layer}/${datatype} 图层已锁定，不能创建图形`, affectedShapeIds: [] };
    }
    const pts: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      const p = points[i];
      const pt: Point = { x: p.x, y: p.y };
      pts.push(pt);
    }
    const shape = editService.createPath(layer, pts, width ?? 4, datatype);
    editService.selectShape(shape.id);
    return {
      command: cmd, success: true,
      message: `已在 L${layer}/${datatype} 层创建路径 (${pts.length} 个点, 宽度 ${width ?? 4}nm, ID: ${shape.id})`,
      affectedShapeIds: [shape.id],
    };
  }

  private execCreateText(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const datatype = target.datatype;
    const x = cmd.params.x;
    const y = cmd.params.y;
    const text = cmd.params.text;
    if (layer === undefined || x === undefined || y === undefined || text === undefined || text.length === 0) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer, x, y, text', affectedShapeIds: [] };
    }
    if (!editService.canEditLayer(layer, datatype)) {
      return { command: cmd, success: false, message: `L${layer}/${datatype} 图层已锁定，不能创建图形`, affectedShapeIds: [] };
    }
    const shape = editService.createText(layer, x, y, text, datatype);
    editService.selectShape(shape.id);
    return {
      command: cmd, success: true,
      message: `已在 L${layer}/${datatype} 层创建文本 "${text}" (ID: ${shape.id})`,
      affectedShapeIds: [shape.id],
    };
  }

  private execCreateArray(cmd: ParsedCommand, context: AiContext): CommandResult {
    if (cmd.params.width === undefined && cmd.params.height === undefined) {
      const rows: number = cmd.params.rows!, cols: number = cmd.params.cols!;
      const expected: number = this.createdShapeCount(cmd);
      if (expected === 0) return { command: cmd, success: false, message: '阵列需要有效选区且至少两个成员', affectedShapeIds: [] };
      const count: number = advEditService.arraySelection(rows, cols, cmd.params.spacingX!, cmd.params.spacingY!);
      return { command: cmd, success: count === expected, message: count === expected ? `已保留原图并新增 ${count} 个阵列图形` : '选区阵列未完整执行',
        affectedShapeIds: count === expected ? editService.getSelectedIds().slice() : [] };
    }
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const datatype = target.datatype;
    const x = cmd.params.x;
    const y = cmd.params.y;
    const width = cmd.params.width;
    const height = cmd.params.height;
    const rows = cmd.params.rows;
    const cols = cmd.params.cols;
    const spacingX = cmd.params.spacingX;
    const spacingY = cmd.params.spacingY;
    if (layer === undefined || !rows || !cols || width === undefined || height === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer, rows, cols, width, height', affectedShapeIds: [] };
    }
    if (!editService.canEditLayer(layer, datatype)) {
      return { command: cmd, success: false, message: `L${layer}/${datatype} 图层已锁定，不能创建阵列`, affectedShapeIds: [] };
    }
    const sx = spacingX ?? width;
    const sy = spacingY ?? height;
    const startX = x ?? 0;
    const startY = y ?? 0;
    const ids: number[] = [];

    // A-3: 阵列创建包入批处理，使 undo 一次撤销整个阵列（支持与外层 executeBatch 嵌套）
    editService.beginBatch();
    try {
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          const px = startX + c * sx;
          const py = startY + r * sy;
          const shape = editService.createRect(layer, px, py, px + width, py + height, datatype);
          ids.push(shape.id);
        }
      }
    } finally {
      editService.endBatch();
    }
    editService.selectMultiple(ids);

    return {
      command: cmd, success: true,
      message: `已在 L${layer}/${datatype} 层创建 ${rows}×${cols} 阵列 (${ids.length} 个图形)`,
      affectedShapeIds: ids,
    };
  }

  private execSelectLayer(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    if (layer === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer', affectedShapeIds: [] };
    }
    return {
      command: cmd, success: true,
      message: `已切换到 L${layer}/${target.datatype} 层`,
      affectedShapeIds: [],
      viewAction: { selectLayer: layer, selectDatatype: target.datatype },
    };
  }

  private execSelectShape(cmd: ParsedCommand, context: AiContext): CommandResult {
    if (cmd.params.shapeIds !== undefined) {
      const ids = cmd.params.shapeIds;
      if (!Array.isArray(ids) || ids.length === 0 || ids.length > 256 ||
        ids.some((id: number) => !Number.isInteger(id) || id < 0)) {
        throw new Error('shapeIds 必须包含 1–256 个有效图形 ID');
      }
      const uniqueIds: number[] = Array.from(new Set<number>(ids));
      const current = editService.getCurrentCellShapes();
      const shapes = uniqueIds.map((id: number) => current.find(shape => shape.id === id));
      if (shapes.some(shape => shape === undefined || shape.type === ShapeType.NODE || !editService.canSelectLayer(shape.layerNumber, shape.datatype))) {
        throw new Error('目标图形不在当前 Cell、已失效或图层不可选择');
      }
      editService.selectMultiple(uniqueIds);
      let minX = Infinity; let minY = Infinity; let maxX = -Infinity; let maxY = -Infinity;
      for (const shape of shapes) {
        if (shape === undefined) continue;
        const box = getShapeBounds(shape);
        minX = Math.min(minX, box.minX); minY = Math.min(minY, box.minY);
        maxX = Math.max(maxX, box.maxX); maxY = Math.max(maxY, box.maxY);
      }
      return { command: cmd, success: true, message: `已定位选中 ${uniqueIds.length} 个图形`, affectedShapeIds: uniqueIds,
        viewAction: cmd.params.focus === false ? undefined : { focusBounds: { minX, minY, maxX, maxY } } };
    }
    const x = cmd.params.x;
    const y = cmd.params.y;
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    if (x !== undefined && y !== undefined) {
      const hasLayerFilter: boolean = cmd.params.layer !== undefined || cmd.params.datatype !== undefined;
      const id = editService.hitTest(x, y, 8, hasLayerFilter ? layer : -1, target.datatype);
      if (id >= 0) {
        editService.selectShape(id);
        return { command: cmd, success: true, message: `已选中坐标 (${x},${y}) 处的图形 (ID: ${id})`, affectedShapeIds: [id] };
      }
      return { command: cmd, success: false, message: `坐标 (${x},${y}) 处未找到图形`, affectedShapeIds: [] };
    }
    if (cmd.params.layer !== undefined || cmd.params.datatype !== undefined) {
      if (!editService.canSelectLayer(layer, target.datatype)) {
        return { command: cmd, success: false, message: `L${layer}/${target.datatype} 图层不可选择`, affectedShapeIds: [] };
      }
      const shapes = editService.getCurrentCellShapes().filter(shape =>
        shape.type !== ShapeType.NODE && shape.layerNumber === layer && shape.datatype === target.datatype);
      if (shapes.length === 0) {
        return { command: cmd, success: false, message: `当前 Cell 的 L${layer}/${target.datatype} 层没有可选图形`, affectedShapeIds: [] };
      }
      const ids: number[] = shapes.map(shape => shape.id);
      editService.selectMultiple(ids);
      return { command: cmd, success: true, message: `已选中当前 Cell 的 L${layer}/${target.datatype} 层 ${ids.length} 个图形`, affectedShapeIds: ids };
    }
    return { command: cmd, success: false, message: '参数缺失: 需要 x,y 或 layer', affectedShapeIds: [] };
  }

  private execMoveShape(cmd: ParsedCommand): CommandResult {
    const dx = cmd.params.dx;
    const dy = cmd.params.dy;
    // A-4: 使用 getSelectedIds 支持多选移动，而非仅移动 selectedId
    const selIds: number[] = editService.getSelectedIds();
    if (selIds.length === 0) {
      return { command: cmd, success: false, message: '没有选中的图形', affectedShapeIds: [] };
    }
    // A-4: 多选时包入批处理，使 undo 一次撤销整个移动操作
    if (selIds.length > 1) {
      editService.beginBatch();
    }
    try {
      for (let i = 0; i < selIds.length; i++) {
        editService.moveShape(selIds[i], dx ?? 0, dy ?? 0);
      }
    } finally {
      if (selIds.length > 1) {
        editService.endBatch();
      }
    }
    return {
      command: cmd, success: true,
      message: `已移动 ${selIds.length} 个图形 (${dx ?? 0}, ${dy ?? 0}) nm`,
      affectedShapeIds: selIds,
    };
  }

  private execDeleteShape(cmd: ParsedCommand): CommandResult {
    // A-4: 使用 getSelectedIds 支持多选，deleteSelected 已内置批处理
    const selIds: number[] = editService.getSelectedIds();
    if (selIds.length === 0) {
      return { command: cmd, success: false, message: '没有选中的图形', affectedShapeIds: [] };
    }
    editService.deleteSelected();
    return {
      command: cmd, success: true,
      message: `已删除 ${selIds.length} 个图形 (ID: ${selIds.join(', ')})`,
      affectedShapeIds: selIds,
    };
  }

  // AICMD-2: 旋转选中图形（委派 AdvancedEditService，支持 INSTANCE 委托）
  private execRotateShape(cmd: ParsedCommand): CommandResult {
    const selId = editService.getSelectedId();
    if (selId < 0) {
      return { command: cmd, success: false, message: '没有选中的图形', affectedShapeIds: [] };
    }
    const degrees = cmd.params.degrees;
    if (degrees === undefined || !Number.isFinite(degrees)) {
      return { command: cmd, success: false, message: '参数缺失: degrees 必须为有限数', affectedShapeIds: [] };
    }
    const ids: number[] = editService.getSelectedIds();
    const ok = cmd.params.centerX === undefined ? advEditService.rotateSelection(degrees) :
      editService.transformShapes(ids, 'rotate', degrees, cmd.params.centerX, cmd.params.centerY);
    if (!ok) {
      return { command: cmd, success: false, message: `旋转失败（可能选中图形不支持旋转）`, affectedShapeIds: [] };
    }
    return {
      command: cmd, success: true,
      message: `已旋转选中图形 ${degrees}°`,
      affectedShapeIds: ids,
    };
  }

  // AICMD-2: 镜像选中图形（委派 AdvancedEditService）
  private execMirrorShape(cmd: ParsedCommand): CommandResult {
    const selId = editService.getSelectedId();
    if (selId < 0) {
      return { command: cmd, success: false, message: '没有选中的图形', affectedShapeIds: [] };
    }
    const horizontal = cmd.params.horizontal;
    if (horizontal === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 horizontal (1/0)', affectedShapeIds: [] };
    }
    const ids: number[] = editService.getSelectedIds();
    const ok = cmd.params.centerX === undefined ? advEditService.mirrorSelection(horizontal === 1) :
      editService.transformShapes(ids, horizontal === 1 ? 'mirrorX' : 'mirrorY', 0, cmd.params.centerX, cmd.params.centerY);
    if (!ok) {
      return { command: cmd, success: false, message: `镜像失败（可能选中图形不支持镜像）`, affectedShapeIds: [] };
    }
    const desc = horizontal === 1 ? '水平（X 轴）' : '垂直（Y 轴）';
    return {
      command: cmd, success: true,
      message: `已${desc}镜像选中图形`,
      affectedShapeIds: ids,
    };
  }

  // AICMD-2: 缩放选中图形（委派 AdvancedEditService，PATH 同步缩放 pathWidth）
  private execScaleShape(cmd: ParsedCommand): CommandResult {
    const selId = editService.getSelectedId();
    if (selId < 0) {
      return { command: cmd, success: false, message: '没有选中的图形', affectedShapeIds: [] };
    }
    const scale = cmd.params.scale;
    if (scale === undefined || !Number.isFinite(scale) || scale <= 0) {
      return { command: cmd, success: false, message: '参数缺失: scale 必须为正数', affectedShapeIds: [] };
    }
    const ids: number[] = editService.getSelectedIds();
    const ok = cmd.params.centerX === undefined ? advEditService.scaleSelection(scale) :
      editService.transformShapes(ids, 'scale', scale, cmd.params.centerX, cmd.params.centerY);
    if (!ok) {
      return { command: cmd, success: false, message: `缩放失败（可能选中图形不支持缩放）`, affectedShapeIds: [] };
    }
    return {
      command: cmd, success: true,
      message: `已缩放选中图形 ${scale}x`,
      affectedShapeIds: ids,
    };
  }

  private execSetLayerVisible(cmd: ParsedCommand, context: AiContext): CommandResult {
    const target = this.resolveLayer(cmd, context);
    const layer = target.layer;
    const visible = cmd.params.visible;
    if (layer === undefined || visible === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 layer 和 visible', affectedShapeIds: [] };
    }
    const lv: LayerVisibility = { layer: layer, datatype: target.datatype, visible: !!visible };
    const va: ViewAction = { layerVisible: lv };
    return {
      command: cmd, success: true,
      message: `已${visible ? '显示' : '隐藏'} L${layer}/${target.datatype} 层`,
      affectedShapeIds: [],
      viewAction: va,
    };
  }

  private execZoom(cmd: ParsedCommand): CommandResult {
    const scale = cmd.params.scale;
    if (scale === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 scale', affectedShapeIds: [] };
    }
    return {
      command: cmd, success: true,
      message: `缩放到 1:${scale}`,
      affectedShapeIds: [],
      viewAction: { zoomScale: scale },
    };
  }

  private execFitAll(cmd: ParsedCommand): CommandResult {
    return {
      command: cmd, success: true,
      message: '已适配全部图形到画布',
      affectedShapeIds: [],
      viewAction: { fitAll: true },
    };
  }

  private execRunDrc(cmd: ParsedCommand): CommandResult {
    const shapes = editService.getShapes();
    const result = drcService.runDrc(shapes, () => {});
    return {
      command: cmd, success: true,
      message: `DRC 几何预检查${result.completenessNotices > 0 ? '结果不完整' : '完成'}: ` +
        `${result.totalViolations} 项违规 (${result.errors} 错误, ${result.warnings} 警告)` +
        (result.completenessNotices > 0 ? `；${result.completenessNotices} 项覆盖告警，请查看验证面板` : ''),
      affectedShapeIds: [],
      viewAction: { showDrc: result },
      warnings: result.completenessNotices > 0 ? ['DRC 结果不完整，不能据零违规判定通过；请查看覆盖告警'] : undefined,
    };
  }

  private execSetTool(cmd: ParsedCommand): CommandResult {
    const tool = cmd.params.tool;
    if (tool === undefined) {
      return { command: cmd, success: false, message: '参数缺失: 需要 tool', affectedShapeIds: [] };
    }
    const toolMap: Record<string, DrawTool> = {
      'select': DrawTool.SELECT,
      'rect': DrawTool.RECT,
      'polygon': DrawTool.POLYGON,
      'path': DrawTool.PATH,
      'measure': DrawTool.MEASURE,
      'text': DrawTool.TEXT,
      'move': DrawTool.MOVE,
      'instance': DrawTool.INSTANCE,
    };
    const drawTool = toolMap[tool];
    if (drawTool === undefined) {
      return { command: cmd, success: false, message: `无效工具: ${tool}`, affectedShapeIds: [] };
    }
    return {
      command: cmd, success: true,
      message: `已切换到 ${tool} 工具`,
      affectedShapeIds: [],
      viewAction: { tool: drawTool },
    };
  }

  /**
   * 从批量执行结果中提取合并的 ViewAction
   * Fix ⑦: 改进合并策略
   * - focusBounds / fitAll / zoomScale: 最后一个视口指令生效
   * - selectLayer: 取最后一条（覆盖）
   * - layerVisibles: 累积所有（数组），同一图层取最后一条
   * - tool: 取最后一条（覆盖）
   * - showDrc: 取最后一条
   */
  static mergeViewActions(results: CommandResult[]): ViewAction | undefined {
    let merged: ViewAction | undefined;
    let showDrcResult: DrcResult | undefined;
    let layerVisAccumulator: Map<string, LayerVisibility> = new Map();

    for (const r of results) {
      if (!r.viewAction) continue;
      if (!merged) merged = {};
      if (r.viewAction.focusBounds !== undefined) {
        merged.focusBounds = r.viewAction.focusBounds;
        merged.fitAll = undefined;
        merged.zoomScale = undefined;
      }

      if (r.viewAction.fitAll) {
        merged.fitAll = true;
        merged.focusBounds = undefined;
        merged.zoomScale = undefined;
      }
      if (r.viewAction.zoomScale !== undefined) {
        merged.zoomScale = r.viewAction.zoomScale; // 覆盖
        merged.focusBounds = undefined;
        merged.fitAll = undefined;
      }
      if (r.viewAction.selectLayer !== undefined) {
        merged.selectLayer = r.viewAction.selectLayer; // 覆盖
        merged.selectDatatype = r.viewAction.selectDatatype ?? 0;
      }
      if (r.viewAction.layerVisible) {
        // Fix ⑦: 累积到 Map，同层取最后一条
        const item = r.viewAction.layerVisible;
        layerVisAccumulator.set(`${item.layer}/${item.datatype ?? 0}`, item);
      }
      if (r.viewAction.layerVisibles) {
        for (const item of r.viewAction.layerVisibles) {
          layerVisAccumulator.set(`${item.layer}/${item.datatype ?? 0}`, item);
        }
      }
      if (r.viewAction.tool !== undefined) {
        merged.tool = r.viewAction.tool; // 覆盖
      }
      if (r.viewAction.showDrc) {
        showDrcResult = r.viewAction.showDrc;
      }
    }

    // Fix ⑦: 将累积的图层可见性转为数组
    if (layerVisAccumulator.size > 0) {
      if (!merged) merged = {};
      const entries = Array.from(layerVisAccumulator.entries());
      const visibles: LayerVisibility[] = [];
      for (let i = 0; i < entries.length; i++) {
        const entry = entries[i];
        const lv: LayerVisibility = entry[1];
        visibles.push(lv);
      }
      merged.layerVisibles = visibles;
      // 兼容：保留第一个到 layerVisible
      merged.layerVisible = visibles[0];
    }

    if (showDrcResult) {
      if (!merged) merged = {};
      merged.showDrc = showDrcResult;
    }

    return merged;
  }
}

/** AI 命令执行器单例 */
export const aiExecutor = new AiCommandExecutor();
