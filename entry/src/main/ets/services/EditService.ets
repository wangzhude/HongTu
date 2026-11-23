/**
 * 鸿图编辑服务
 *
 * 管理画布上的图形编辑操作：
 * - 创建图形（矩形/多边形/路径）
 * - 选中/取消选中
 * - 移动图形
 * - 删除图形
 * - 撤销/重做（Undo/Redo）
 * - 图形 ID 生成
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, Point, getShapeBounds, normalizePropRecords } from '../models/GdsiiData';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import type { SourceLayerDefinition } from '../../cpp/types/libhongtu/Index';
import { nativeHongTuService } from './NativeHongTuService';
import { prepareShapeProperty, validatePropertyHierarchy } from './ShapePropertyService';
import type { PropertyCellOption, PropertyEditResult } from './ShapePropertyService';
import type { PrecisionSettings } from './PrecisionService';
import type { UiLayer } from '../common/types';
import type { DrcConfiguration } from './DrcService';
import { normalizeLayoutSemantics, appendCellSemantics, newLayoutIdentity } from '../models/LayoutPort';
import type { LayoutSemanticState, LayoutPort, LayoutCrossSection, LayoutContextRecord } from '../models/LayoutPort';
import {
  cloneContextRecordArray,
  cloneCrossSectionArray,
  cloneEditStructureModel,
  clonePortArray,
  cloneShapeArray,
  cloneSourceLayerDefinitions,
  cloneStructured,
  cloneUiLayerArray,
  cloneUiLayerModel,
  incrementalSnapshotEngine,
  isImmutablePointArray
} from '../common/CloneUtils';

/** One concrete placement on a navigation path. Transform maps this Cell to the path root. */
export interface InstancePathTransform { a: number; b: number; c: number; d: number; tx: number; ty: number; }
export interface InstancePathStep {
  parentCellId: number;
  cellId: number;
  instanceId: number;
  row: number;
  col: number;
  transform: InstancePathTransform;
}
export interface SharedCellImpact {
  ok: boolean;
  directReferences: number;
  parentCells: number;
  placements: number;
  bounded: boolean;
  message: string;
}
export interface IndependentPathResult {
  ok: boolean;
  message: string;
  path: InstancePathStep[];
  instanceId: number;
  clonedCells: number;
  addedShapes: number;
}
export interface IndependentPathPiece { instanceId: number; row: number; col: number; rows: number; cols: number; }
export interface IndependentPathRemap { sourceOwnerCellId: number; targetOwnerCellId: number; sourceInstanceId: number;
  pieces: IndependentPathPiece[]; shapeIds: number[][]; sourceCellId: number; targetCellId: number; }
export interface IndependentPathPlanResult extends IndependentPathResult { shapes?: Shape[]; structure?: EditStructureState; remaps?: IndependentPathRemap[]; }
export interface FlattenEstimate {
  ok: boolean;
  removedReferences: number;
  createdObjects: number;
  remainingChildReferences: number;
  estimatedBytes: number;
  message: string;
}

/**
 * 编辑操作记录（用于撤销/重做）
 *
 * E-TX: 事务简化 —— 一个用户级手势（拖拽、批量删除、方向键微移串）在栈上只占**一条**记录。
 * - 单子记录：直接沿用 'create'/'delete'/'move'/'modify'，与旧行为完全一致
 * - 多子记录：包成一条 'transaction'，steps 按发生顺序存放，撤销时逆序回放、重做时正序回放
 * 旧的 batch_start/batch_end 哨兵已删除：它们一条事务要占 2+N 个栈槽，
 * 且挤出栈底时的配对清理（原 EDIT-3）与嵌套配对（原 H-1）都是易错点。
 */
export interface EditStructureState extends LayoutSemanticState {
  /** Optional complete inert process settings participate in structural history. */
  technologyJson?: string;
  drcDeckJson?: string;
  drcConfiguration?: DrcConfiguration;
  localProcessOwned?: boolean;
  userUnits?: number;
  physicalUnits?: number;
  precision?: PrecisionSettings;
  layerDefinitions?: SourceLayerDefinition[];
  /** Complete layer list, including intentionally empty layers and all UI styles. */
  layers?: UiLayer[];
  cellNames: string[];
  cellProperties: LayoutPropRecord[][];
  libProperties?: LayoutPropRecord[];
  topCellId: number;
  cellStack: number[];
  navigationPath?: InstancePathStep[];
}
export interface EditProcessState { technologyJson: string; drcDeckJson: string; drcConfiguration: DrcConfiguration; localProcessOwned?: boolean; }

/** Selection is independent of geometry history and its primary need not be the last ID. */
export interface EditSelectionState {
  selectedId: number;
  selectedIds: number[];
  selectedShapeIds: number[];
}

export interface EditAction {
  label?: string;
  type: 'create' | 'delete' | 'move' | 'modify' | 'transaction' | 'structure';
  shapeId: number;
  /** 操作前的图形数据（撤销用） */
  before?: Shape;
  /** 操作后的图形数据（重做用） */
  after?: Shape;
  /** Original insertion position for a deletion; restored before later objects. */
  index?: number;
  /** Structural candidates can insert/reorder objects; preserve both paint orders. */
  orderBefore?: number[];
  orderAfter?: number[];
  /** 仅 'transaction'：组成该事务的子记录 */
  steps?: EditAction[];
  structureBefore?: EditStructureState;
  structureAfter?: EditStructureState;
  /** LYP-only metadata history; ordinary structure replay keeps its live-view policy. */
  layerPropertiesHistory?: boolean;
  /** Explicit opt-in for operations whose selection is part of their transaction contract. */
  selectionBefore?: EditSelectionState;
  selectionAfter?: EditSelectionState;
}

export interface ClipboardCellDefinition {
  sourceCellId: number;
  name: string;
  properties: LayoutPropRecord[];
  shapes: Shape[];
  ports: LayoutPort[];
  contextRecords: LayoutContextRecord[];
}

export interface SharedClipboardBundle {
  sourceDocumentId: string;
  sourceTopCellId: number;
  sourceCellNames: string[];
  items: Shape[];
  referencedCells: ClipboardCellDefinition[];
  sourceLayers: UiLayer[];
  sourceCrossSections: LayoutCrossSection[];
}

export interface EditSessionState {
  shapes: Shape[];
  nextId: number;
  undoStack: EditAction[];
  redoStack: EditAction[];
  selectedId: number;
  selectedIds: number[];
  topCellId: number;
  currentCellStack: number[];
  navigationPath?: InstancePathStep[];
  clipboard: Shape[];
  dirty: boolean;
  editDepth: number;
  cleanBaselineReachable: boolean;
}

/**
 * 编辑服务
 */
export class EditService {
  /** 撤销/重做栈上限，超过则丢弃最旧记录 */
  private static readonly MAX_UNDO_STACK: number = 50;

  private shapes: Shape[] = [];
  private nextId: number = 1;
  private undoStack: EditAction[] = [];
  private redoStack: EditAction[] = [];
  private selectedId: number = -1;
  /** 多选 ID 集合（与 selectedId 共存：selectedId 始终跟踪最近一次主选） */
  private selectedIds: Set<number> = new Set<number>();
  private shapeByIdCache: Map<number, Shape> = new Map<number, Shape>();
  private shapeByIdCacheShapesRef: Shape[] | null = null;
  private shapeByIdCacheLength: number = -1;
  private shapeByIdCacheRevision: number = -1;
  private shapeByIdCacheNextId: number = -1;
  private shapeByIdCacheFirstId: number = -1;
  private shapeByIdCacheLastId: number = -1;
  private layerAccessEpoch: number = 0;
  private selectionCacheKey: string = '';
  private cachedSelectedShapes: Shape[] = [];
  private cachedSelectedIdsList: number[] = [];
  /** 图层可见性回调（由外部注入，hitTest 时据此跳过隐藏图层上的图形） */
  private layerVisibleProvider: ((layerNumber: number, datatype: number) => boolean) | null = null;
  /** 可选与可编辑分开：锁定层由 editable 回调拒绝，不能经直接 ID 选中绕过。 */
  private layerSelectableProvider: ((layerNumber: number, datatype: number) => boolean) | null = null;
  private layerEditableProvider: ((layerNumber: number, datatype: number) => boolean) | null = null;
  /** 顶层 Cell ID（子 Cell 导航栈底） */
  private topCellId: number = 0;
  /** 当前编辑的 Cell 栈，栈顶为当前编辑上下文，初始 [topCellId] */
  private currentCellStack: number[] = [0];
  private navigationPath: InstancePathStep[] = [];
  /** 跨标签页共享剪贴板：复制的图形深拷贝及被引用子 Cell 定义子树 */
  private clipboard: Shape[] = [];
  private clipboardBundle: SharedClipboardBundle | null = null;
  private activeDocumentIdentity: string = '';
  /** C++ 原生 g_layout 快照是否与当前 ArkTS 几何严格一致 */
  private nativeSnapshotCurrent: boolean = false;
  /** 文档是否有未保存修改（M2 dirty） */
  private dirty: boolean = false;
  /**
   * 自上次 markClean/setShapes 起，undo 栈上「真实编辑」操作的净计数。
   * push 真实操作 +1；undo 真实操作 -1；redo 真实操作 +1。
   * 为 0 时文档视为与加载/保存基线一致（dirty=false）。
   */
  private editDepth: number = 0;
  /** A new branch before the saved state can make that baseline unreachable. */
  private cleanBaselineReachable: boolean = true;
  /**
   * E-TX: 当前开启的事务层数（嵌套计数）。> 0 时子记录先进 txSteps 缓冲，
   * 闭合到 0 时合并成一条 undo 记录 —— 中途的 pointer move / 子步骤不再各自成为撤销步。
   */
  private txDepth: number = 0;
  /** E-TX: 当前事务的子记录缓冲（发生顺序） */
  private txSteps: EditAction[] = [];
  private sessionRevision: number = 0;
  private structureRestoreAction: ((state: EditStructureState) => void) | null = null;
  private structureLayerSnapshotAction: ((layers: UiLayer[], shapes: Shape[], preserveOwnFields?: boolean) => UiLayer[]) | null = null;
  private structureStateProvider: (() => EditStructureState) | null = null;
  private processStateProvider: (() => EditProcessState) | null = null;
  setProcessStateProvider(provider: (() => EditProcessState) | null): void { this.processStateProvider = provider; }

  setActiveDocumentIdentity(documentId: string): void {
    this.activeDocumentIdentity = documentId;
  }

  getActiveDocumentIdentity(): string {
    return this.activeDocumentIdentity;
  }

  setNativeSnapshotCurrent(current: boolean): void {
    this.nativeSnapshotCurrent = current;
  }

  isNativeSnapshotCurrent(): boolean {
    return this.nativeSnapshotCurrent;
  }

  /** 原生 C++ 展开与 R-Tree 点查询在 g_layout 已同步时启用（任何实时几何编辑均会立即将 nativeSnapshotCurrent 置 false） */
  canPreferNativeExpand(): boolean {
    return this.nativeSnapshotCurrent;
  }

  clearClipboard(): void {
    this.clipboard = [];
    this.clipboardBundle = null;
  }

  getClipboardBundle(): SharedClipboardBundle | null {
    return this.clipboardBundle;
  }

  setStructureRestoreAction(action: ((state: EditStructureState) => void) | null): void {
    this.structureRestoreAction = action;
  }

  /** Pure layer derivation used before sealing a structural transaction's after state. */
  setStructureLayerSnapshotAction(action: ((layers: UiLayer[], shapes: Shape[], preserveOwnFields?: boolean) => UiLayer[]) | null): void {
    this.structureLayerSnapshotAction = action;
  }

  /** Read current non-history layer views before structural history replay. */
  setStructureStateProvider(provider: (() => EditStructureState) | null): void {
    this.structureStateProvider = provider;
  }

  private cloneStructure(state: EditStructureState, preserveOwnFields: boolean = false): EditStructureState {
    return cloneEditStructureModel(state, preserveOwnFields);
  }

  private restoreStructure(from: EditStructureState, state: EditStructureState): void {
    // 仅当共享剪贴板源自当前活动文档时，随本标签结构撤销/重做同步修正同文档引用；
    // 若剪贴板来自其他标签页，绝不能被当前标签的结构撤销污染或误删。
    const sameDocClipboard: boolean = this.clipboardBundle === null ||
      this.clipboardBundle.sourceDocumentId.length === 0 ||
      (this.activeDocumentIdentity.length > 0 && this.clipboardBundle.sourceDocumentId === this.activeDocumentIdentity);
    if (sameDocClipboard) {
      const clipboard: Shape[] = [];
      for (const shape of this.clipboard) {
        if (shape.type !== ShapeType.INSTANCE) {
          clipboard.push(shape);
          continue;
        }
        const oldId: number = shape.cellId ?? -1;
        if (!Number.isInteger(oldId) || oldId < 0 || oldId >= from.cellNames.length) {
          if (this.clipboardBundle !== null && this.clipboardBundle.referencedCells.length > 0) {
            clipboard.push(shape);
          }
          continue;
        }
        const nextId: number = from.cellKeys !== undefined && state.cellKeys !== undefined ?
          state.cellKeys.indexOf(from.cellKeys[oldId]) : (from.cellNames.length === state.cellNames.length ? oldId : state.cellNames.indexOf(from.cellNames[oldId]));
        if (nextId < 0 || nextId >= state.cellNames.length) {
          if (this.clipboardBundle !== null && this.clipboardBundle.referencedCells.length > 0) {
            clipboard.push(shape);
          }
          continue;
        }
        shape.cellId = nextId;
        shape.cellName = state.cellNames[nextId];
        clipboard.push(shape);
      }
      this.clipboard = clipboard;
      if (this.clipboardBundle !== null) {
        this.clipboardBundle.items = this.clipboard.map((s: Shape): Shape => this.cloneShape(s));
        this.clipboardBundle.sourceCellNames = state.cellNames.slice();
        this.clipboardBundle.sourceTopCellId = state.topCellId;
      }
    }
    this.topCellId = state.topCellId;
    this.currentCellStack = state.cellStack.slice();
    this.navigationPath = this.clonePath(state.navigationPath ?? []);
  }

  private hasStructureAction(action: EditAction): boolean {
    if (action.type === 'structure') return true;
    return action.type === 'transaction' && (action.steps ?? []).some((step: EditAction): boolean => this.hasStructureAction(step));
  }

  private hasSelectionAction(action: EditAction): boolean {
    if (action.selectionBefore !== undefined || action.selectionAfter !== undefined) return true;
    return action.type === 'transaction' && (action.steps ?? []).some((step: EditAction): boolean => this.hasSelectionAction(step));
  }

  private hasLayerPropertiesHistory(action: EditAction): boolean {
    if (action.layerPropertiesHistory === true) return true;
    return action.type === 'transaction' && (action.steps ?? []).some((step: EditAction): boolean => this.hasLayerPropertiesHistory(step));
  }

  /** Inspect only the next record; the existing undo/redo return contracts stay boolean. */
  isLayerPropertiesUndo(): boolean {
    if (this.txSteps.length > 0) return this.txSteps.some((step: EditAction): boolean => this.hasLayerPropertiesHistory(step));
    const action: EditAction | undefined = this.undoStack[this.undoStack.length - 1];
    return action !== undefined && this.hasLayerPropertiesHistory(action);
  }

  isLayerPropertiesRedo(): boolean {
    const action: EditAction | undefined = this.redoStack[this.redoStack.length - 1];
    return action !== undefined && this.hasLayerPropertiesHistory(action);
  }

  /** Replay a sealed JSON field only while live still equals this direction's from value.
   * Later independent changes win. Target key order is retained; new live keys append.
   * JSON construction also retains own keys such as __proto__ as inert data. */
  private replayLayerPropertyObject(from: UiLayer, state: UiLayer, live: UiLayer): UiLayer {
    const previous: Record<string, Object> = from as Object as Record<string, Object>;
    const target: Record<string, Object> = state as Object as Record<string, Object>;
    const current: Record<string, Object> = live as Object as Record<string, Object>;
    const fromKeys: string[] = Object.keys(previous), stateKeys: string[] = Object.keys(target), liveKeys: string[] = Object.keys(current);
    const keys: string[] = stateKeys.slice();
    for (const key of liveKeys) if (!keys.includes(key)) keys.push(key);
    const entries: string[] = [];
    for (const key of keys) {
      const fromHas: boolean = fromKeys.includes(key), stateHas: boolean = stateKeys.includes(key), liveHas: boolean = liveKeys.includes(key);
      const unchanged: boolean = fromHas === stateHas && JSON.stringify(previous[key]) === JSON.stringify(target[key]);
      const atFrom: boolean = liveHas === fromHas && JSON.stringify(current[key]) === JSON.stringify(previous[key]);
      const keepLive: boolean = unchanged || !atFrom;
      if ((keepLive && !liveHas) || (!keepLive && !stateHas)) continue;
      const value: Object = keepLive ? current[key] : target[key];
      if (value !== undefined) entries.push(JSON.stringify(key) + ':' + JSON.stringify(value));
    }
    return JSON.parse('{' + entries.join(',') + '}') as UiLayer;
  }

  private layerPropertiesHistoryTarget(from: EditStructureState, state: EditStructureState): EditStructureState {
    const target: EditStructureState = this.liveStructureState(true);
    const liveLayers: UiLayer[] = target.layers ?? [], fromLayers: UiLayer[] = from.layers ?? [];
    const layers: UiLayer[] = [];
    const keys: Set<string> = new Set<string>();
    for (const sealed of state.layers ?? []) {
      const key: string = `${sealed.layerNumber}/${sealed.datatype}`;
      const previous: UiLayer | undefined = fromLayers.find((layer: UiLayer): boolean => `${layer.layerNumber}/${layer.datatype}` === key);
      const live: UiLayer | undefined = liveLayers.find((layer: UiLayer): boolean => `${layer.layerNumber}/${layer.datatype}` === key);
      if (previous !== undefined && live === undefined) continue; // Later independent deletion wins.
      layers.push(previous !== undefined && live !== undefined ? this.replayLayerPropertyObject(previous, sealed, live) :
        cloneUiLayerModel(live ?? sealed) as UiLayer);
      keys.add(key);
    }
    for (const live of liveLayers) {
      const key: string = `${live.layerNumber}/${live.datatype}`;
      if (keys.has(key)) continue;
      const previous: UiLayer | undefined = fromLayers.find((layer: UiLayer): boolean => `${layer.layerNumber}/${layer.datatype}` === key);
      if (previous === undefined || JSON.stringify(previous) !== JSON.stringify(live)) layers.push(cloneUiLayerModel(live) as UiLayer);
    }
    target.layers = layers;
    if (JSON.stringify(target.layerDefinitions) === JSON.stringify(from.layerDefinitions)) {
      target.layerDefinitions = state.layerDefinitions === undefined ? undefined : cloneSourceLayerDefinitions(state.layerDefinitions)! as SourceLayerDefinition[];
    }
    return target;
  }

  // Generic structure history keeps the established known-field policy. Only
  // unknown serialized fields use the same three-way replay as LYP history.
  private mergeStructureLayerProperties(previous: UiLayer, resolved: UiLayer, live: UiLayer): UiLayer {
    const knownKeys: string[] = ['layerNumber', 'datatype', 'chineseName', 'sourceName', 'englishName', 'color',
      'visible', 'locked', 'elementCount', 'group', 'lineStyle', 'fillStyle', 'transparency', 'lineWidth',
      'selectable', 'highlighted', 'animated'];
    const replayed: UiLayer = this.replayLayerPropertyObject(previous, resolved, live);
    const target: Record<string, Object> = resolved as Object as Record<string, Object>;
    const merged: Record<string, Object> = replayed as Object as Record<string, Object>;
    const targetKeys: string[] = Object.keys(target), mergedKeys: string[] = Object.keys(merged);
    const keys: string[] = targetKeys.slice();
    for (const key of mergedKeys) if (!keys.includes(key)) keys.push(key);
    const entries: string[] = [];
    for (const key of keys) {
      const known: boolean = knownKeys.includes(key);
      if (known ? !targetKeys.includes(key) : !mergedKeys.includes(key)) continue;
      const value: Object = known ? target[key] : merged[key];
      if (value !== undefined) entries.push(JSON.stringify(key) + ':' + JSON.stringify(value));
    }
    // This is the established structure-checkpoint JSON boundary: runtime own
    // undefined is omitted from saved/history JSON, not reclassified as a value.
    return JSON.parse('{' + entries.join(',') + '}') as UiLayer;
  }

  private historyStructureTarget(from: EditStructureState, state: EditStructureState, layerPropertiesHistory: boolean = false): EditStructureState {
    if (layerPropertiesHistory) return this.layerPropertiesHistoryTarget(from, state);
    const target: EditStructureState = this.cloneStructure(state);
    if (this.structureStateProvider === null) return target;
    const current: EditStructureState = this.structureStateProvider();
    const process: EditProcessState | null = this.processStateProvider === null ? null : this.processStateProvider();
    // Geometry history must preserve later independent process edits. A process
    // transaction explicitly changes these strings and replays its own delta.
    if (from.technologyJson === state.technologyJson && (process !== null || current.technologyJson !== undefined)) target.technologyJson = process?.technologyJson ?? current.technologyJson;
    if (from.drcDeckJson === state.drcDeckJson && (process !== null || current.drcDeckJson !== undefined)) target.drcDeckJson = process?.drcDeckJson ?? current.drcDeckJson;
    if (JSON.stringify(from.drcConfiguration) === JSON.stringify(state.drcConfiguration) && (process !== null || current.drcConfiguration !== undefined))
      target.drcConfiguration = process?.drcConfiguration ?? current.drcConfiguration;
    if (from.localProcessOwned === state.localProcessOwned && (process?.localProcessOwned !== undefined || current.localProcessOwned !== undefined))
      target.localProcessOwned = process?.localProcessOwned ?? current.localProcessOwned;
    const processChanged: boolean = from.technologyJson !== state.technologyJson;
    if (from.layers === undefined || target.layers === undefined) return target;
    if (current.layers === undefined) return target;
    const fromLayers: Map<string, UiLayer> = new Map<string, UiLayer>();
    const currentLayers: Map<string, UiLayer> = new Map<string, UiLayer>();
    const targetKeys: Set<string> = new Set<string>();
    for (const layer of from.layers) fromLayers.set(`${layer.layerNumber}/${layer.datatype}`, layer);
    for (const layer of current.layers) currentLayers.set(`${layer.layerNumber}/${layer.datatype}`, layer);
    for (let index: number = 0; index < target.layers.length; index++) {
      const layer: UiLayer = target.layers[index];
      const key: string = `${layer.layerNumber}/${layer.datatype}`;
      targetKeys.add(key);
      const previous: UiLayer | undefined = fromLayers.get(key);
      const live: UiLayer | undefined = currentLayers.get(key);
      if (previous === undefined || live === undefined) continue;
      // Replay only the sealed per-field name/color delta. Saving a physical
      // stack changes technology bytes without necessarily changing these
      // fields; later independent .lyp imports must survive both undo and redo.
      // A field changed by a process transaction restores its sealed value.
      // Geometry-only history retains its independent live-view semantics.
      if (!processChanged || previous.chineseName === layer.chineseName) layer.chineseName = live.chineseName;
      if (!processChanged || previous.englishName === layer.englishName) layer.englishName = live.englishName;
      if (!processChanged || previous.color === layer.color) layer.color = live.color;
      // Remaining common-layer views belong to the current UI. Identity,
      // sourceName and geometry-derived counts remain structural.
      layer.visible = live.visible;
      layer.group = live.group;
      layer.locked = live.locked;
      layer.lineStyle = live.lineStyle;
      layer.fillStyle = live.fillStyle;
      layer.transparency = live.transparency;
      layer.lineWidth = live.lineWidth;
      layer.selectable = live.selectable;
      layer.highlighted = live.highlighted;
      layer.animated = live.animated;
      target.layers[index] = this.mergeStructureLayerProperties(previous, layer, live);
    }
    // A user-created layer outside this transaction belongs to neither sealed
    // side. Retain it even when empty; remove only this action's layer delta.
    for (const layer of current.layers) {
      const key: string = `${layer.layerNumber}/${layer.datatype}`;
      if (!fromLayers.has(key) && !targetKeys.has(key)) target.layers.push(cloneUiLayerModel(layer) as UiLayer);
    }
    return target;
  }
  private liveStructureState(preserveOwnFields: boolean = false): EditStructureState {
    if (this.structureStateProvider === null) throw new Error('当前结构状态未就绪');
    const state: EditStructureState = this.cloneStructure(this.structureStateProvider(), preserveOwnFields);
    if (this.processStateProvider !== null) {
      const process: EditProcessState = this.processStateProvider();
      state.technologyJson = process.technologyJson; state.drcDeckJson = process.drcDeckJson;
      state.drcConfiguration = cloneStructured(process.drcConfiguration) as DrcConfiguration;
      if (process.localProcessOwned !== undefined) state.localProcessOwned = process.localProcessOwned;
    }
    return state;
  }

  private notifyStructure(action: EditAction, redo: boolean, history: boolean = true): void {
    if (action.type === 'transaction') {
      const steps: EditAction[] = action.steps ?? [];
      if (redo) for (const step of steps) this.notifyStructure(step, redo, history);
      else for (let i = steps.length - 1; i >= 0; i--) this.notifyStructure(steps[i], redo, history);
      return;
    }
    const state: EditStructureState | undefined = redo ? action.structureAfter : action.structureBefore;
    const from: EditStructureState | undefined = redo ? action.structureBefore : action.structureAfter;
    if (state !== undefined && this.structureRestoreAction !== null) this.structureRestoreAction(history && from !== undefined ?
      this.historyStructureTarget(from, state, action.layerPropertiesHistory === true) : this.cloneStructure(state, action.layerPropertiesHistory === true));
  }

  /** Geometry, Cell definitions and an optional result selection share one undo record. */
  applyDocumentStructure(nextShapes: Shape[], before: EditStructureState, after: EditStructureState, label: string = '', recordSelectionHistory: boolean = false, finalSelectedIds?: number[], recordLayerProperties: boolean = false): boolean {
    if (recordLayerProperties && (this.structureStateProvider === null || this.structureRestoreAction === null)) return false;
    if (!this.canEditStructurePorts(before, after)) return false;
    this.forceCloseTransaction();
    const orderBefore: number[] = this.shapes.map((shape: Shape): number => shape.id);
    const orderAfter: number[] = nextShapes.map((shape: Shape): number => shape.id);
    const orderChanged: boolean = orderBefore.length !== orderAfter.length ||
      orderBefore.some((id: number, index: number): boolean => id !== orderAfter[index]);
    const byId: Map<number, Shape> = new Map<number, Shape>();
    for (const shape of this.shapes) byId.set(shape.id, shape);
    const nextIds: Set<number> = new Set<number>();
    const steps: EditAction[] = [];
    for (const next of nextShapes) {
      if (nextIds.has(next.id) || !Number.isInteger(next.id) || next.id <= 0) return false;
      nextIds.add(next.id);
      const previous: Shape | undefined = byId.get(next.id);
      if (previous === undefined) {
        if (!this.canEditLayer(next.layerNumber, next.datatype)) return false;
        steps.push({ type: 'create', shapeId: next.id, after: this.cloneShape(next) });
      } else if (JSON.stringify(previous) !== JSON.stringify(next)) {
        if (!this.canEditLayer(previous.layerNumber, previous.datatype) || !this.canEditLayer(next.layerNumber, next.datatype)) return false;
        steps.push({ type: 'modify', shapeId: next.id, before: this.cloneShape(previous), after: this.cloneShape(next) });
      }
    }
    for (const previous of this.shapes) {
      if (nextIds.has(previous.id)) continue;
      if (!this.canEditLayer(previous.layerNumber, previous.datatype)) return false;
      steps.push({ type: 'delete', shapeId: previous.id, before: this.cloneShape(previous) });
    }
    const recordedBefore: EditStructureState = this.cloneStructure(before, recordLayerProperties);
    const recordedAfter: EditStructureState = this.cloneStructure(after, recordLayerProperties);
    if (recordLayerProperties) {
      const unrelated: EditStructureState = this.cloneStructure(recordedAfter, true);
      unrelated.layers = recordedBefore.layers; unrelated.layerDefinitions = recordedBefore.layerDefinitions;
      if (steps.length > 0 || orderChanged || JSON.stringify(unrelated) !== JSON.stringify(recordedBefore)) return false;
    }
    // Legacy callers may build an after state field-by-field. Preserve their
    // complete pre-edit layers, then seal any newly used layers and counts using
    // the same pure derivation as Index. Never remove layers by empty counts.
    if (recordedAfter.layers === undefined && recordedBefore.layers !== undefined) recordedAfter.layers = recordedBefore.layers;
    if (recordedAfter.technologyJson === undefined) recordedAfter.technologyJson = recordedBefore.technologyJson;
    if (recordedAfter.drcDeckJson === undefined) recordedAfter.drcDeckJson = recordedBefore.drcDeckJson;
    if (recordedAfter.drcConfiguration === undefined) recordedAfter.drcConfiguration = recordedBefore.drcConfiguration;
    if (recordedAfter.localProcessOwned === undefined && recordedBefore.localProcessOwned !== undefined) recordedAfter.localProcessOwned = recordedBefore.localProcessOwned;
    if (recordedAfter.layers !== undefined && this.structureLayerSnapshotAction !== null) {
      recordedAfter.layers = cloneUiLayerArray(this.structureLayerSnapshotAction(recordedAfter.layers, nextShapes, recordLayerProperties)) as UiLayer[];
    }
    if (JSON.stringify(recordedBefore) !== JSON.stringify(recordedAfter)) {
      const step: EditAction = { type: 'structure', shapeId: 0, structureBefore: this.cloneStructure(recordedBefore, recordLayerProperties), structureAfter: this.cloneStructure(recordedAfter, recordLayerProperties) };
      if (recordLayerProperties) step.layerPropertiesHistory = true;
      steps.push(step);
    }
    if (steps.length === 0 && !orderChanged) return true;
    const rollback: EditSessionState = this.captureSession(recordLayerProperties);
    const sealSelectionHistory: boolean = recordSelectionHistory || finalSelectedIds !== undefined;
    const selectionBefore: EditSelectionState | undefined = sealSelectionHistory ? this.captureSelectionState() : undefined;
    try {
    if (!recordLayerProperties) {
      this.shapes = nextShapes.map((shape: Shape): Shape => this.cloneShape(shape));
      for (const shape of this.shapes) this.nextId = Math.max(this.nextId, shape.id + 1);
      this.restoreStructure(recordedBefore, recordedAfter);
    }
    this.redoStack = [];
    const action: EditAction = steps.length === 1 && !orderChanged ? steps[0] : { type: 'transaction', shapeId: 0, steps };
    if (selectionBefore !== undefined) action.selectionBefore = selectionBefore;
    if (orderChanged) { action.orderBefore = orderBefore; action.orderAfter = orderAfter; }
    if (label.length > 0) action.label = label.slice(0, 256);
    this.appendUndo(action);
    this.pruneSelection();
    if (finalSelectedIds !== undefined) this.selectMultiple(finalSelectedIds);
    if (sealSelectionHistory) action.selectionAfter = this.captureSelectionState();
    if (this.structureRestoreAction !== null) this.structureRestoreAction(this.cloneStructure(recordedAfter, recordLayerProperties));
    if (recordLayerProperties) this.pruneSelection();
    // Publication may prune or change selection; seal the caller's result only
    // after it completes, while keeping both selection endpoints in this action.
    if (finalSelectedIds !== undefined) this.selectMultiple(finalSelectedIds);
    if (sealSelectionHistory) action.selectionAfter = this.captureSelectionState();
    this.sessionRevision++;
    return true;
    } catch (error) {
      // A structure listener publishes Cell/units metadata outside this service.
      // Geometry, allocator, selection, dirty baseline and history must return
      // together if that publication fails, before attempting metadata restore.
      this.restoreSession(rollback, recordLayerProperties);
      let restoreFailure: string = '';
      if (this.structureRestoreAction !== null) {
        try { this.structureRestoreAction(this.cloneStructure(recordedBefore, recordLayerProperties)); }
        catch (failure) { restoreFailure = `；结构恢复回调失败：${String(failure)}`; }
      }
      // Restoring external metadata may itself reenter editing. Reassert the
      // exact pre-transaction session after that callback completes or throws.
      this.restoreSession(rollback, recordLayerProperties);
      throw new Error(`结构事务未提交：${String(error)}${restoreFailure}`);
    }
  }

  getSessionRevision(): number { return this.sessionRevision; }
  /** Read-only selection token for sealed planners; unlike UI getters it never prunes state. */
  getSelectionIdentity(): string { return JSON.stringify([this.selectedId, Array.from(this.selectedIds),
    this.shapes.filter((shape: Shape): boolean => shape.selected).map((shape: Shape): number => shape.id)]); }
  getNextShapeId(): number { return this.nextId; }

  validateShapeHierarchy(shapes: Shape[]): string { return validatePropertyHierarchy(shapes, this.topCellId); }

  /** Human-readable transaction history without copying the document geometry. */
  getHistorySummary(limit: number = 10): string[] {
    const summaries: string[] = [];
    const count: number = Math.max(0, Math.min(50, Math.floor(limit)));
    if (count === 0) return summaries;
    for (const action of this.undoStack.slice(-count).reverse()) {
      if (action.label !== undefined && action.label.length > 0) { summaries.push(action.label); continue; }
      const affected: Set<number> = new Set<number>();
      let hasStructure: boolean = false;
      const collect = (step: EditAction): void => {
        if (step.shapeId > 0) affected.add(step.shapeId);
        if (step.type === 'structure') hasStructure = true;
        for (const child of step.steps ?? []) collect(child);
      };
      collect(action);
      const name: string = hasStructure ? '修改 Cell 与工程设置' : action.type === 'create' ? '创建对象' :
        action.type === 'delete' ? '删除对象' : action.type === 'move' ? '移动对象' : action.type === 'transaction' ? '批量编辑' : '修改属性或几何';
      summaries.push(`${name} · ${affected.size} 个对象 · 一次撤销`);
    }
    return summaries;
  }

  private cloneAction(action: EditAction): EditAction {
    const copy: EditAction = { type: action.type, shapeId: action.shapeId, label: action.label,
      index: action.index, orderBefore: action.orderBefore?.slice(), orderAfter: action.orderAfter?.slice(),
      before: action.before === undefined ? undefined : this.cloneShape(action.before),
      after: action.after === undefined ? undefined : this.cloneShape(action.after),
      structureBefore: action.structureBefore === undefined ? undefined : this.cloneStructure(action.structureBefore, action.layerPropertiesHistory === true),
      structureAfter: action.structureAfter === undefined ? undefined : this.cloneStructure(action.structureAfter, action.layerPropertiesHistory === true),
      selectionBefore: action.selectionBefore === undefined ? undefined : this.cloneSelectionState(action.selectionBefore),
      selectionAfter: action.selectionAfter === undefined ? undefined : this.cloneSelectionState(action.selectionAfter),
      steps: action.steps === undefined ? undefined : action.steps.map((step: EditAction) => this.cloneAction(step)) };
    if (action.layerPropertiesHistory !== undefined) copy.layerPropertiesHistory = action.layerPropertiesHistory;
    return copy;
  }

  private captureSelectionState(): EditSelectionState {
    return { selectedId: this.selectedId, selectedIds: Array.from(this.selectedIds),
      selectedShapeIds: this.shapes.filter((shape: Shape): boolean => shape.selected).map((shape: Shape): number => shape.id) };
  }

  private cloneSelectionState(state: EditSelectionState): EditSelectionState {
    return { selectedId: state.selectedId, selectedIds: state.selectedIds.slice(), selectedShapeIds: state.selectedShapeIds.slice() };
  }

  /** Restore raw selection; final pruning enforces live layer/context access. */
  private restoreActionSelection(action: EditAction, redo: boolean): void {
    const state: EditSelectionState | undefined = redo ? action.selectionAfter : action.selectionBefore;
    if (state === undefined) return;
    this.restoreSelectionState(state);
  }

  private invalidateSelectionCache(): void {
    this.selectionCacheKey = '';
  }

  private invalidateShapeIndex(): void {
    this.shapeByIdCacheShapesRef = null;
    this.shapeByIdCacheLength = -1;
    this.selectionCacheKey = '';
  }

  private ensureShapeByIdMap(): Map<number, Shape> {
    const firstId: number = this.shapes.length > 0 ? this.shapes[0].id : -1;
    const lastId: number = this.shapes.length > 0 ? this.shapes[this.shapes.length - 1].id : -1;
    if (
      this.shapeByIdCacheShapesRef !== this.shapes ||
      this.shapeByIdCacheLength !== this.shapes.length ||
      this.shapeByIdCacheRevision !== this.sessionRevision ||
      this.shapeByIdCacheNextId !== this.nextId ||
      this.shapeByIdCacheFirstId !== firstId ||
      this.shapeByIdCacheLastId !== lastId
    ) {
      const map: Map<number, Shape> = new Map<number, Shape>();
      for (let i = 0; i < this.shapes.length; i++) {
        const s: Shape = this.shapes[i];
        map.set(s.id, s);
      }
      this.shapeByIdCache = map;
      this.shapeByIdCacheShapesRef = this.shapes;
      this.shapeByIdCacheLength = this.shapes.length;
      this.shapeByIdCacheRevision = this.sessionRevision;
      this.shapeByIdCacheNextId = this.nextId;
      this.shapeByIdCacheFirstId = firstId;
      this.shapeByIdCacheLastId = lastId;
    }
    return this.shapeByIdCache;
  }

  /** O(1) 按 ID 检索当前文档图元（避免 1.7 万图元下高频线性 .find 遍历） */
  getShapeById(id: number): Shape | undefined {
    if (id < 0) return undefined;
    const hit: Shape | undefined = this.ensureShapeByIdMap().get(id);
    if (hit !== undefined) return hit;
    return undefined;
  }

  private currentSelectionPruneKey(): string {
    return `${this.sessionRevision}:${this.shapes.length}:${this.currentCellStack.join(',')}:${this.layerAccessEpoch}`;
  }

  private restoreSelectionState(state: EditSelectionState): void {
    const selected: Set<number> = new Set<number>(state.selectedShapeIds);
    for (const shape of this.shapes) shape.selected = selected.has(shape.id);
    this.selectedId = state.selectedId;
    this.selectedIds = new Set<number>(state.selectedIds);
    this.invalidateSelectionCache();
  }

  /** 未编辑大版图切标签时零深拷贝只读会话快照（CoW，消除切走百万顶点版图时的主线程深拷贝） */
  captureReadOnlySession(documentId?: string): EditSessionState {
    this.forceCloseTransaction();
    const docKey: string = documentId !== undefined && documentId.length > 0 ? documentId : this.activeDocumentIdentity;
    return {
      shapes: incrementalSnapshotEngine.captureReadOnlyShapes(docKey, this.shapes),
      nextId: this.nextId,
      undoStack: this.undoStack.map((a: EditAction) => this.cloneAction(a)),
      redoStack: this.redoStack.map((a: EditAction) => this.cloneAction(a)),
      selectedId: this.selectedId,
      selectedIds: Array.from(this.selectedIds),
      topCellId: this.topCellId,
      currentCellStack: this.currentCellStack.slice(),
      navigationPath: this.getNavigationPath(),
      clipboard: this.clipboard.map((s: Shape) => this.cloneShape(s)),
      dirty: this.dirty,
      editDepth: this.editDepth,
      cleanBaselineReachable: this.cleanBaselineReachable
    };
  }

  captureSession(preserveOwnFields: boolean = false): EditSessionState {
    this.forceCloseTransaction();
    if (preserveOwnFields) {
      const state: EditSessionState = { shapes: this.shapes, nextId: this.nextId, undoStack: this.undoStack, redoStack: this.redoStack,
        selectedId: this.selectedId, selectedIds: Array.from(this.selectedIds), topCellId: this.topCellId,
        currentCellStack: this.currentCellStack, navigationPath: this.navigationPath, clipboard: this.clipboard,
        dirty: this.dirty, editDepth: this.editDepth, cleanBaselineReachable: this.cleanBaselineReachable };
      return cloneStructured(state) as EditSessionState;
    }
    return { shapes: this.shapes.map((s: Shape) => this.cloneShape(s)), nextId: this.nextId,
      undoStack: this.undoStack.map((a: EditAction) => this.cloneAction(a)),
      redoStack: this.redoStack.map((a: EditAction) => this.cloneAction(a)),
      selectedId: this.selectedId, selectedIds: Array.from(this.selectedIds),
      topCellId: this.topCellId, currentCellStack: this.currentCellStack.slice(),
      navigationPath: this.getNavigationPath(),
      clipboard: this.clipboard.map((s: Shape) => this.cloneShape(s)), dirty: this.dirty,
      editDepth: this.editDepth, cleanBaselineReachable: this.cleanBaselineReachable };
  }

  /**
   * 恢复单文档编辑会话（默认保留跨标签页共享剪贴板，避免切签用目标标签旧/空剪贴板覆盖用户刚复制的图元）。
   */
  restoreSession(state: EditSessionState, preserveOwnFields: boolean = false, restoreClipboard: boolean = false): void {
    this.shapes = preserveOwnFields ? cloneShapeArray(state.shapes, true) as Shape[] : state.shapes.map((s: Shape) => this.cloneShape(s));
    this.nextId = state.nextId;
    this.undoStack = preserveOwnFields ? cloneStructured(state.undoStack) as EditAction[] : state.undoStack.map((a: EditAction) => this.cloneAction(a));
    this.redoStack = preserveOwnFields ? cloneStructured(state.redoStack) as EditAction[] : state.redoStack.map((a: EditAction) => this.cloneAction(a));
    this.selectedId = state.selectedId;
    this.selectedIds = new Set<number>(state.selectedIds);
    this.topCellId = state.topCellId;
    this.currentCellStack = state.currentCellStack.length > 0 ? state.currentCellStack.slice() : [state.topCellId];
    this.navigationPath = this.clonePath(state.navigationPath ?? []);
    if (restoreClipboard) {
      this.clipboard = preserveOwnFields ? cloneShapeArray(state.clipboard, true) as Shape[] : state.clipboard.map((s: Shape) => this.cloneShape(s));
      this.clipboardBundle = null;
    }
    this.dirty = state.dirty;
    this.editDepth = state.editDepth;
    this.cleanBaselineReachable = state.cleanBaselineReachable;
    this.nativeSnapshotCurrent = false;
    this.txDepth = 0;
    this.txSteps = [];
    this.sessionRevision++;
  }

  /**
   * 原子替换一组图形并完整封存绘制次序（orderBefore/orderAfter）与选区历史（selectionBefore/selectionAfter）。
   */
  replaceShapesWithHistory(
    removedIds: number[],
    templates: Shape[],
    label: string = '',
    selectCreated: boolean = true
  ): Shape[] | null {
    const removeSet: Set<number> = new Set<number>(removedIds);
    const toRemove: Shape[] = [];
    for (let i = 0; i < this.shapes.length; i++) {
      const existing: Shape = this.shapes[i];
      if (removeSet.has(existing.id)) {
        if (!this.canEditLayer(existing.layerNumber, existing.datatype)) return null;
        toRemove.push(existing);
      }
    }
    if (this.shapes.length - toRemove.length + templates.length > 1000000) return null;
    let pointCount: number = 0;
    for (let i = 0; i < this.shapes.length; i++) {
      if (!removeSet.has(this.shapes[i].id)) {
        pointCount += this.shapes[i].points.length;
      }
    }
    const prepared: Shape[] = [];
    for (let i = 0; i < templates.length; i++) {
      const tmpl: Shape = templates[i];
      if (!this.canEditLayer(tmpl.layerNumber, tmpl.datatype) || tmpl.points.length === 0) return null;
      for (let p = 0; p < tmpl.points.length; p++) {
        if (!Number.isFinite(tmpl.points[p].x) || !Number.isFinite(tmpl.points[p].y)) return null;
      }
      pointCount += tmpl.points.length;
      if (pointCount > 4000000) return null;
      const copy: Shape = this.cloneShape(tmpl);
      copy.id = this.nextId + i;
      if (copy.ownerCellId === undefined) copy.ownerCellId = this.getCurrentCellId();
      copy.selected = false;
      prepared.push(copy);
    }
    if (toRemove.length === 0 && prepared.length === 0) return [];
    const candidateAll: Shape[] = this.shapes.filter((s: Shape): boolean => !removeSet.has(s.id)).concat(prepared);
    if (validatePropertyHierarchy(candidateAll, this.topCellId).length > 0) return null;

    this.forceCloseTransaction();
    const orderBefore: number[] = this.shapes.map((s: Shape): number => s.id);
    const selectionBefore: EditSelectionState = this.captureSelectionState();
    const steps: EditAction[] = [];
    for (let i = 0; i < toRemove.length; i++) {
      const targetId: number = toRemove[i].id;
      const idx: number = this.shapes.findIndex((s: Shape): boolean => s.id === targetId);
      if (idx >= 0) {
        const deleted: Shape = this.shapes[idx];
        this.shapes.splice(idx, 1);
        this.selectedIds.delete(targetId);
        if (this.selectedId === targetId) this.selectedId = -1;
        steps.push({ type: 'delete', shapeId: targetId, index: idx, before: this.cloneShape(deleted) });
      }
    }
    const createdIds: number[] = [];
    for (let i = 0; i < prepared.length; i++) {
      const created: Shape = prepared[i];
      this.shapes.push(created);
      createdIds.push(created.id);
      steps.push({ type: 'create', shapeId: created.id, after: this.cloneShape(created) });
    }
    this.nextId += prepared.length;
    const orderAfter: number[] = this.shapes.map((s: Shape): number => s.id);
    if (selectCreated) {
      if (createdIds.length > 0) this.selectMultiple(createdIds);
      else this.clearSelection();
    } else {
      this.pruneSelection();
    }
    const selectionAfter: EditSelectionState = this.captureSelectionState();
    const action: EditAction = steps.length === 1
      ? steps[0]
      : { type: 'transaction', shapeId: steps[0].shapeId, steps: steps };
    if (label.length > 0) action.label = label.slice(0, 256);
    action.orderBefore = orderBefore;
    action.orderAfter = orderAfter;
    action.selectionBefore = this.cloneSelectionState(selectionBefore);
    action.selectionAfter = this.cloneSelectionState(selectionAfter);
    this.redoStack = [];
    this.appendUndo(action);
    return prepared;
  }

  /** Replace PCell geometry atomically with complete paint-order & selection history; a valid empty replacement returns []. */
  replaceCellContents(cellId: number, templates: Shape[]): number[] {
    if (!Number.isInteger(cellId) || cellId < 0) throw new Error('无效 Cell ID');
    const originals: Shape[] = this.shapes.filter((s: Shape) => (s.ownerCellId ?? this.topCellId) === cellId);
    if (this.shapes.length - originals.length + templates.length > 1000000) throw new Error('PCell 重生成超过基础图形预算');
    let pointCount: number = 0;
    for (const existing of this.shapes) {
      if ((existing.ownerCellId ?? this.topCellId) !== cellId) pointCount += existing.points.length;
    }
    for (const template of templates) {
      pointCount += template.points.length;
      if (pointCount > 4000000) throw new Error('PCell 重生成超过顶点预算');
    }
    for (let i = 0; i < originals.length; i++) {
      if (!this.canEditLayer(originals[i].layerNumber, originals[i].datatype)) throw new Error('Cell 含锁定图层');
    }
    const next: Shape[] = [];
    for (let i = 0; i < templates.length; i++) {
      const s: Shape = this.cloneShape(templates[i]);
      if (!this.canEditLayer(s.layerNumber, s.datatype) || s.points.length === 0 ||
        s.points.some((p: Point) => !Number.isFinite(p.x) || !Number.isFinite(p.y)) ||
        (s.type === ShapeType.PATH && (s.points.length < 2 || !Number.isFinite(s.pathWidth) || (s.pathWidth ?? 0) <= 0)) ||
        (s.type === ShapeType.RECT && s.points.length < 2) ||
        (s.type === ShapeType.POLYGON && s.points.length < 3) ||
        [ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH, ShapeType.TEXT].indexOf(s.type) < 0) throw new Error('PCell 模板图层、类型或坐标无效');
      s.ownerCellId = cellId; s.selected = false;
      next.push(s);
    }
    if (originals.length === 0 && next.length === 0) return [];
    const replaced: Shape[] | null = this.replaceShapesWithHistory(
      originals.map((s: Shape): number => s.id),
      next,
      '替换单元几何',
      false
    );
    if (replaced === null) throw new Error('替换单元内容未通过图层或层级校验');
    return replaced.map((s: Shape): number => s.id);
  }

  /** 获取所有图形 */
  getShapes(): Shape[] {
    return this.shapes;
  }

  /** 文档是否有未保存修改 */
  isDirty(): boolean {
    return this.dirty;
  }

  /** 标记为已保存（导出成功后调用） */
  markClean(): void {
    this.dirty = false;
    this.editDepth = 0;
    this.cleanBaselineReachable = true;
  }

  /** 显式标脏（外部批量改图时） */
  markDirty(): void {
    this.sessionRevision++;
    this.nativeSnapshotCurrent = false;
    this.dirty = true;
    this.cleanBaselineReachable = false;
    if (this.editDepth < 1) {
      this.editDepth = 1;
    }
  }

  /**
   * E-TX: 一条 undo 记录包含的「真实编辑」数量。事务记录 = 其子记录之和，
   * 用于 editDepth 的进出账，保证「撤销回基线 ⇒ clean」在事务化后仍成立。
   */
  private contentCount(action: EditAction): number {
    if (action.type !== 'transaction') {
      return 1;
    }
    const steps: EditAction[] = action.steps ?? [];
    let n: number = 0;
    for (let i = 0; i < steps.length; i++) {
      n += this.contentCount(steps[i]);
    }
    return n === 0 && action.orderBefore !== undefined && action.orderAfter !== undefined ? 1 : n;
  }

  /** 顶点列表逐项相等（nm 精确比较）：用于丢弃「手势回到原位」的空事务 */
  private static samePoints(a: Point[], b: Point[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i].x !== b[i].x || a[i].y !== b[i].y) {
        return false;
      }
    }
    return true;
  }

  /** 按 editDepth 同步 dirty：撤销回基线则 clean */
  private syncDirtyFromEditDepth(): void {
    // Undo can move before the saved state; negative depth is still modified.
    this.dirty = !this.cleanBaselineReachable || this.editDepth !== 0;
  }

  /** 当前 Cell 拥有的本地图形；缺少 owner 的旧数据归入 Top Cell。 */
  getCurrentCellShapes(): Shape[] {
    // NODE is stream/net metadata, not an editable drawing. Keep it in getShapes()
    // for save, but exclude it from the UI's current-cell drawing/initial selection.
    return this.shapes.filter((shape: Shape) =>
      shape.type !== ShapeType.NODE && this.isShapeInCurrentCell(shape));
  }

  /** 判断图形是否属于当前 Cell 编辑上下文。 */
  isShapeInCurrentCell(shape: Shape): boolean {
    const ownerCellId: number = shape.ownerCellId ?? this.topCellId;
    return ownerCellId === this.getCurrentCellId();
  }

  /** 设置图形列表（加载文件时） */
  setShapes(shapes: Shape[]): void {
    this.adoptShapes(shapes.map((s: Shape): Shape => this.cloneShape(s)));
  }

  /**
   * Import-only ownership transfer. The caller must hand over a freshly converted
   * Shape[] and stop mutating it outside this service. Unlike setShapes, no second
   * complete copy of the geometry/points is allocated. Undo records still clone
   * individual shapes at edit time, preserving their snapshot isolation.
   */
  adoptShapes(shapes: Shape[]): void {
    this.shapes = shapes;
    // 跨标签页共享剪贴板在此保留；粘贴时由 pasteShapes 对齐目标文档 cellNames 并自动补齐/重映射子 Cell。
    this.nativeSnapshotCurrent = false;
    this.nextId = 1;
    for (const shape of shapes) {
      shape.selected = false;
      this.nextId = Math.max(this.nextId, shape.id + 1);
    }
    this.selectedId = -1;
    this.selectedIds = new Set<number>();
    this.undoStack = [];
    this.redoStack = [];
    // E-TX: 换文档时丢弃未闭合的事务缓冲，避免旧文档的子记录串进新文档第一条撤销
    this.txDepth = 0;
    this.txSteps = [];
    // 重置 Cell 导航栈到顶层
    this.currentCellStack = [this.topCellId];
    this.navigationPath = [];
    this.sessionRevision++;
    // 加载/重置不算未保存修改
    this.dirty = false;
    this.editDepth = 0;
    this.cleanBaselineReachable = true;
  }

  /** 克隆图形（深拷贝，避免 spread 操作符） */
  private cloneShape(s: Shape): Shape {
    let pts: Point[];
    if (isImmutablePointArray(s.points)) {
      pts = s.points;
    } else {
      pts = new Array<Point>(s.points.length);
      for (let i = 0; i < s.points.length; i++) {
        pts[i] = { x: s.points[i].x, y: s.points[i].y };
      }
    }
    const copy: Shape = {
      id: s.id,
      type: s.type,
      layerNumber: s.layerNumber,
      datatype: s.datatype,
      points: pts,
      selected: s.selected,
    };
    if (s.pathWidth !== undefined) {
      copy.pathWidth = s.pathWidth;
    }
    // 端型与线宽同命：cloneShape 是撤销快照/移动/复制的唯一出口，
    // 这里漏一行，「打开→改一笔→保存」就会把 round/extended 抹成 flush
    if (s.pathType !== undefined) {
      copy.pathType = s.pathType;
    }
    // INSTANCE 类型额外字段
    if (s.ownerCellId !== undefined) copy.ownerCellId = s.ownerCellId;
    if (s.cellId !== undefined) copy.cellId = s.cellId;
    if (s.cellName !== undefined) copy.cellName = s.cellName;
    if (s.rotation !== undefined) copy.rotation = s.rotation;
    if (s.mirror !== undefined) copy.mirror = s.mirror;
    if (s.magnification !== undefined) copy.magnification = s.magnification;
    if (s.textPresentation !== undefined) copy.textPresentation = s.textPresentation;
    if (s.pathBeginExtension !== undefined) copy.pathBeginExtension = s.pathBeginExtension;
    if (s.pathEndExtension !== undefined) copy.pathEndExtension = s.pathEndExtension;
    if (s.pathWidthAbsolute !== undefined) copy.pathWidthAbsolute = s.pathWidthAbsolute;
    if (s.arrayCols !== undefined) copy.arrayCols = s.arrayCols;
    if (s.arrayRows !== undefined) copy.arrayRows = s.arrayRows;
    if (s.arrayColStepX !== undefined) copy.arrayColStepX = s.arrayColStepX;
    if (s.arrayColStepY !== undefined) copy.arrayColStepY = s.arrayColStepY;
    if (s.arrayRowStepX !== undefined) copy.arrayRowStepX = s.arrayRowStepX;
    if (s.arrayRowStepY !== undefined) copy.arrayRowStepY = s.arrayRowStepY;
    if (s.text !== undefined) copy.text = s.text;
    // 属性必须随克隆走：撤销/重做、粘贴、布尔与打平都经此处重建图元，
    // 漏掉即等于「编辑后保存丢属性」。深拷贝一份，避免撤销栈与实图共用数组。
    if (s.properties !== undefined) {
      const cloned = normalizePropRecords(s.properties);
      if (cloned !== undefined) {
        copy.properties = cloned;
      }
    }
    return copy;
  }

  /** 获取选中的图形 */
  getSelectedShape(): Shape | null {
    this.pruneSelection();
    if (this.selectedId < 0) return null;
    return this.getShapeById(this.selectedId) ?? null;
  }

  /** 获取所有选中的图形（支持多选，返回所有选中 shape；O(|selected|) 零全表扫描） */
  getSelectedShapes(): Shape[] {
    this.pruneSelection();
    return this.cachedSelectedShapes.slice();
  }

  /** 获取选中图形 ID */
  getSelectedId(): number {
    this.pruneSelection();
    return this.selectedId;
  }

  /** 获取所有选中图形 ID（多选；O(|selected|) 零全表扫描） */
  getSelectedIds(): number[] {
    this.pruneSelection();
    return this.cachedSelectedIdsList.slice();
  }

  /** 追加一个图形到多选（不清除已有选择） */
  addToSelection(id: number): void {
    if (id < 0) return;
    this.pruneSelection();
    const shape = this.getShapeById(id);
    if (!shape || !this.canSelectShape(shape)) return;
    this.selectedIds.add(id);
    shape.selected = true;
    this.selectedId = id; // 跟踪最近一次主选
    this.invalidateSelectionCache();
  }

  /** 切换某个图形的选中状态（选中则取消，未选中则加入） */
  toggleSelection(id: number): void {
    if (id < 0) return;
    this.pruneSelection();
    const shape = this.getShapeById(id);
    if (!shape || !this.canSelectShape(shape)) return;
    if (this.selectedIds.has(id)) {
      this.selectedIds.delete(id);
      shape.selected = false;
      this.invalidateSelectionCache();
      if (this.selectedId === id) {
        const remaining: number[] = this.getSelectedIds();
        this.selectedId = remaining.length > 0 ? remaining[remaining.length - 1] : -1;
      }
    } else {
      this.selectedIds.add(id);
      shape.selected = true;
      this.selectedId = id;
      this.invalidateSelectionCache();
    }
  }

  /** 清除所有选中（单选 + 多选；仅复位已选中项，消除 1.7 万图元全量写触发） */
  clearSelection(): void {
    if (this.selectionCacheKey === this.currentSelectionPruneKey()) {
      for (let i = 0; i < this.cachedSelectedShapes.length; i++) {
        this.cachedSelectedShapes[i].selected = false;
      }
    } else {
      for (let i = 0; i < this.shapes.length; i++) {
        if (this.shapes[i].selected) this.shapes[i].selected = false;
      }
    }
    this.selectedIds = new Set<number>();
    this.selectedId = -1;
    this.cachedSelectedShapes = [];
    this.cachedSelectedIdsList = [];
    this.selectionCacheKey = this.currentSelectionPruneKey();
  }

  /** 设置多选（替换为给定 id 列表；O(|ids|) 哈希直查替代 O(N^2) 线性扫描） */
  selectMultiple(ids: number[]): void {
    this.clearSelection();
    const byId: Map<number, Shape> = this.ensureShapeByIdMap();
    const nextSelectedShapes: Shape[] = [];
    const nextIds: number[] = [];
    let lastId: number = -1;
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i];
      const shape = byId.get(id);
      if (shape && this.canSelectShape(shape)) {
        if (!this.selectedIds.has(id)) {
          this.selectedIds.add(id);
          nextSelectedShapes.push(shape);
          nextIds.push(id);
        }
        shape.selected = true;
        lastId = id;
      }
    }
    this.selectedId = lastId;
    if (nextSelectedShapes.length > 1) {
      // 保持与 this.shapes 绘制顺序一致的 cachedSelectedShapes
      this.invalidateSelectionCache();
    } else {
      this.cachedSelectedShapes = nextSelectedShapes;
      this.cachedSelectedIdsList = nextIds;
      this.selectionCacheKey = this.currentSelectionPruneKey();
    }
  }

  /** Direct drawing must validate every shared ancestor before allocating an ID or recording history. */
  private commitDrawnShape(shape: Shape): Shape {
    const hierarchyError: string = validatePropertyHierarchy(this.shapes.concat([shape]), this.topCellId);
    if (hierarchyError.length > 0) throw new Error(hierarchyError);
    this.nextId++;
    this.shapes.push(shape);
    this.pushUndo({ type: 'create', shapeId: shape.id, after: this.cloneShape(shape) });
    this.redoStack = [];
    return shape;
  }

  /**
   * 创建矩形
   * @param layerNumber 图层号
   * @param x1 起点X
   * @param y1 起点Y
   * @param x2 终点X
   * @param y2 终点Y
   */
  createRect(layerNumber: number, x1: number, y1: number, x2: number, y2: number, datatype: number = 0): Shape {
    this.requireEditableLayer(layerNumber, datatype);
    const shape: Shape = {
      id: this.nextId,
      type: ShapeType.RECT,
      layerNumber: layerNumber,
      datatype: datatype,
      ownerCellId: this.getCurrentCellId(),
      selected: false,
      points: [{ x: x1, y: y1 }, { x: x2, y: y2 }],
    };
    return this.commitDrawnShape(shape);
  }

  /**
   * 创建多边形
   * @param layerNumber 图层号
   * @param points 顶点列表
   */
  createPolygon(layerNumber: number, points: Point[], datatype: number = 0): Shape {
    this.requireEditableLayer(layerNumber, datatype);
    const pts: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      pts.push({ x: points[i].x, y: points[i].y });
    }
    const shape: Shape = {
      id: this.nextId,
      type: ShapeType.POLYGON,
      layerNumber: layerNumber,
      datatype: datatype,
      ownerCellId: this.getCurrentCellId(),
      selected: false,
      points: pts,
    };
    return this.commitDrawnShape(shape);
  }

  /**
   * 创建路径
   * @param layerNumber 图层号
   * @param points 路径点
   * @param width 路径宽度
   */
  createPath(layerNumber: number, points: Point[], width: number, datatype: number = 0, pathType: number = 0): Shape {
    this.requireEditableLayer(layerNumber, datatype);
    const pts: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      pts.push({ x: points[i].x, y: points[i].y });
    }
    const shape: Shape = {
      id: this.nextId,
      type: ShapeType.PATH,
      layerNumber: layerNumber,
      datatype: datatype,
      ownerCellId: this.getCurrentCellId(),
      selected: false,
      points: pts,
      pathWidth: width,
    };
    if (pathType === 1 || pathType === 2 || pathType === 4) {
      shape.pathType = pathType;
    }
    return this.commitDrawnShape(shape);
  }

  /**
   * 创建文本标注
   * @param layerNumber 图层号
   * @param x 插入点 X
   * @param y 插入点 Y
   * @param text 文本内容
   */
  createText(layerNumber: number, x: number, y: number, text: string, datatype: number = 0): Shape {
    this.requireEditableLayer(layerNumber, datatype);
    const shape: Shape = {
      id: this.nextId,
      type: ShapeType.TEXT,
      layerNumber: layerNumber,
      datatype: datatype,
      ownerCellId: this.getCurrentCellId(),
      selected: false,
      points: [{ x: x, y: y }],
      text: text,
    };
    return this.commitDrawnShape(shape);
  }

  /**
   * 通用图形创建（接受预构建的 Shape 对象，分配新 ID）。
   * 用于阵列复制等需要克隆已有图形的场景。
   */
  createShape(template: Shape): Shape {
    return this.createShapeInCell(template, this.getCurrentCellId());
  }

  /**
   * 在指定 Cell 中创建图形（打平实例等跨 Cell 场景）。
   */
  createShapeInCell(template: Shape, ownerCellId: number): Shape {
    this.requireEditableLayer(template.layerNumber, template.datatype);
    const shape: Shape = this.cloneShape(template);
    shape.id = this.nextId++;
    shape.ownerCellId = ownerCellId;
    shape.selected = false;
    this.shapes.push(shape);
    this.pushUndo({ type: 'create', shapeId: shape.id, after: this.cloneShape(shape) });
    this.redoStack = [];
    return shape;
  }

  /**
   * 修改图形顶点（通用，支持 undo）。
   * 用于尺寸调整、顶点编辑等场景。
   */
  modifyShape(id: number, newPoints: Point[]): boolean {
    const shape: Shape | undefined = this.shapes.find(s => s.id === id);
    if (shape === undefined || !this.canEditLayer(shape.layerNumber, shape.datatype)) {
      return false;
    }
    const before: Shape = this.cloneShape(shape);
    const pts: Point[] = [];
    for (let i = 0; i < newPoints.length; i++) {
      pts.push({ x: newPoints[i].x, y: newPoints[i].y });
    }
    shape.points = pts;
    this.pushUndo({ type: 'modify', shapeId: id, before: before, after: this.cloneShape(shape) });
    this.redoStack = [];
    return true;
  }

  /**
   * 复制选中图形到跨标签共享剪贴板，并为 INSTANCE（SREF/AREF）附带源文档 cellNames 与递归子 Cell 定义子树。
   */
  copySelection(sourceDocumentId?: string, sourceStructure?: EditStructureState): number {
    const ids: number[] = this.getSelectedIds();
    let structure: EditStructureState | undefined = sourceStructure;
    if (structure === undefined && this.structureStateProvider !== null) {
      try { structure = this.liveStructureState(false); } catch (_) { structure = undefined; }
    }
    const cellNames: string[] = structure !== undefined ? structure.cellNames.slice() : [];
    const copiedItems: Shape[] = [];
    const rootQueue: number[] = [];
    const visitedCells: Set<number> = new Set<number>();

    for (const id of ids) {
      const s: Shape | undefined = this.shapes.find(sh => sh.id === id);
      if (!s) continue;
      const cloned: Shape = this.cloneShape(s);
      if (cloned.type === ShapeType.INSTANCE) {
        const refId: number = cloned.cellId ?? -1;
        if (refId >= 0 && refId < cellNames.length && cellNames[refId].length > 0) {
          cloned.cellName = cellNames[refId];
        }
        if (refId >= 0 && !visitedCells.has(refId)) {
          visitedCells.add(refId);
          rootQueue.push(refId);
        }
      }
      copiedItems.push(cloned);
    }
    if (copiedItems.length === 0) {
      return 0;
    }

    const referencedCells: ClipboardCellDefinition[] = [];
    for (let qi = 0; qi < rootQueue.length; qi++) {
      const cid: number = rootQueue[qi];
      const cName: string = cid >= 0 && cid < cellNames.length && cellNames[cid].length > 0
        ? cellNames[cid]
        : `CELL_${cid}`;
      const localShapes: Shape[] = [];
      for (let si = 0; si < this.shapes.length; si++) {
        const sh: Shape = this.shapes[si];
        if ((sh.ownerCellId ?? this.topCellId) !== cid) continue;
        const shCopy: Shape = this.cloneShape(sh);
        if (shCopy.type === ShapeType.INSTANCE) {
          const nestedId: number = shCopy.cellId ?? -1;
          if (nestedId >= 0 && nestedId < cellNames.length && cellNames[nestedId].length > 0) {
            shCopy.cellName = cellNames[nestedId];
          }
          if (nestedId >= 0 && !visitedCells.has(nestedId)) {
            visitedCells.add(nestedId);
            rootQueue.push(nestedId);
          }
        }
        localShapes.push(shCopy);
      }
      const cellProps: LayoutPropRecord[] = structure !== undefined && cid < structure.cellProperties.length
        ? (normalizePropRecords(structure.cellProperties[cid]) ?? [])
        : [];
      const cellPorts: LayoutPort[] = structure !== undefined && structure.ports !== undefined
        ? (clonePortArray(structure.ports.filter((p: LayoutPort): boolean => p.ownerCellId === cid)) ?? [])
        : [];
      const cellCtx: LayoutContextRecord[] = structure !== undefined && structure.cellContextRecords !== undefined && cid < structure.cellContextRecords.length
        ? (cloneContextRecordArray(structure.cellContextRecords[cid]) ?? [])
        : [];
      referencedCells.push({
        sourceCellId: cid,
        name: cName,
        properties: cellProps,
        shapes: localShapes,
        ports: cellPorts,
        contextRecords: cellCtx,
      });
    }

    this.clipboard = copiedItems;
    this.clipboardBundle = {
      sourceDocumentId: sourceDocumentId ?? this.activeDocumentIdentity,
      sourceTopCellId: this.topCellId,
      sourceCellNames: cellNames,
      items: copiedItems.map((item: Shape): Shape => this.cloneShape(item)),
      referencedCells: referencedCells,
      sourceLayers: structure?.layers !== undefined ? cloneUiLayerArray(structure.layers) as UiLayer[] : [],
      sourceCrossSections: structure?.crossSections !== undefined ? (cloneCrossSectionArray(structure.crossSections) ?? []) : [],
    };
    return this.clipboard.length;
  }

  /**
   * 粘贴跨标签共享剪贴板图形：偏移 (+20,+20) nm；
   * 若含 INSTANCE（SREF/AREF），自动校验目标文档 cellNames，按名匹配既有单元或合并导入缺失子 Cell 定义子树并重映射 cellId。
   */
  pasteShapes(selectCreated: boolean = false, targetDocumentId?: string): Shape[] {
    if (this.clipboard.length === 0) return [];
    const hasInstance: boolean = this.clipboard.some((s: Shape): boolean => s.type === ShapeType.INSTANCE);
    let beforeStructure: EditStructureState | undefined = undefined;
    if (this.structureStateProvider !== null) {
      try { beforeStructure = this.liveStructureState(false); } catch (_) { beforeStructure = undefined; }
    }
    if (!hasInstance || beforeStructure === undefined) {
      const templates: Shape[] = this.clipboard.map((source: Shape): Shape => {
        const copy: Shape = this.cloneShape(source);
        copy.points = copy.points.map((p: Point): Point => ({ x: p.x + 20, y: p.y + 20 }));
        return copy;
      });
      if (beforeStructure !== undefined) {
        const testAll: Shape[] = this.shapes.concat(templates.map((t: Shape, idx: number): Shape => {
          const c: Shape = this.cloneShape(t);
          c.id = this.nextId + idx;
          c.ownerCellId = this.getCurrentCellId();
          return c;
        }));
        if (validatePropertyHierarchy(testAll, beforeStructure.topCellId, beforeStructure.cellNames.length).length > 0) {
          return [];
        }
      }
      return this.createShapeCopies(templates, true, selectCreated);
    }

    const bundle: SharedClipboardBundle | null = this.clipboardBundle;
    const afterStructure: EditStructureState = this.cloneStructure(beforeStructure, false);
    normalizeLayoutSemantics(afterStructure, afterStructure.cellNames.length);
    const targetOwnerCellId: number = this.getCurrentCellId();
    const cellRemap: Map<number, number> = new Map<number, number>();
    const importedCells: ClipboardCellDefinition[] = [];
    const importedTargetIds: number[] = [];

    if (bundle !== null) {
      for (let i = 0; i < bundle.referencedCells.length; i++) {
        const def: ClipboardCellDefinition = bundle.referencedCells[i];
        const cleanName: string = def.name.trim().length > 0 ? def.name : `CELL_${def.sourceCellId}`;
        const existingIdx: number = afterStructure.cellNames.indexOf(cleanName);
        if (existingIdx >= 0) {
          cellRemap.set(def.sourceCellId, existingIdx);
        } else {
          if (afterStructure.cellNames.length >= 100000) return [];
          for (let pi = 0; pi < def.ports.length; pi++) {
            if (!this.canEditLayer(def.ports[pi].layerNumber, def.ports[pi].datatype)) return [];
          }
          const newCellId: number = afterStructure.cellNames.length;
          afterStructure.cellNames.push(cleanName);
          afterStructure.cellProperties.push(normalizePropRecords(def.properties) ?? []);
          appendCellSemantics(afterStructure);
          if (def.contextRecords.length > 0 && afterStructure.cellContextRecords !== undefined) {
            afterStructure.cellContextRecords[newCellId] = cloneContextRecordArray(def.contextRecords) ?? [];
          }
          if (def.ports.length > 0) {
            if (afterStructure.ports === undefined) afterStructure.ports = [];
            if (afterStructure.crossSections === undefined) afterStructure.crossSections = [];
            const newOwnerKey: string = (afterStructure.cellKeys as string[])[newCellId];
            for (let pi = 0; pi < def.ports.length; pi++) {
              const clonedPort: LayoutPort = (clonePortArray([def.ports[pi]]) as LayoutPort[])[0];
              clonedPort.id = newLayoutIdentity('port');
              clonedPort.ownerCellId = newCellId;
              clonedPort.ownerCellKey = newOwnerKey;
              if (clonedPort.crossSectionKey !== undefined) {
                const hasCs: boolean = afterStructure.crossSections.some((cs: LayoutCrossSection): boolean =>
                  cs.key === clonedPort.crossSectionKey && cs.version === clonedPort.crossSectionVersion);
                if (!hasCs) {
                  const srcCs: LayoutCrossSection | undefined = bundle.sourceCrossSections.find((cs: LayoutCrossSection): boolean =>
                    cs.key === clonedPort.crossSectionKey && cs.version === clonedPort.crossSectionVersion);
                  if (srcCs !== undefined) {
                    afterStructure.crossSections.push((cloneCrossSectionArray([srcCs]) as LayoutCrossSection[])[0]);
                  }
                }
              }
              afterStructure.ports.push(clonedPort);
            }
          }
          cellRemap.set(def.sourceCellId, newCellId);
          importedCells.push(def);
          importedTargetIds.push(newCellId);
        }
      }
    }

    const resolveMappedCellId = (srcShape: Shape): number => {
      const rawId: number = srcShape.cellId ?? -1;
      const byMap: number | undefined = cellRemap.get(rawId);
      if (byMap !== undefined && byMap >= 0 && byMap < afterStructure.cellNames.length) {
        return byMap;
      }
      const explicitName: string = srcShape.cellName !== undefined && srcShape.cellName.length > 0
        ? srcShape.cellName
        : (bundle !== null && rawId >= 0 && rawId < bundle.sourceCellNames.length ? bundle.sourceCellNames[rawId] : '');
      if (explicitName.length > 0) {
        const byName: number = afterStructure.cellNames.indexOf(explicitName);
        if (byName >= 0) return byName;
      }
      const effectiveDoc: string = targetDocumentId ?? this.activeDocumentIdentity;
      const sameDoc: boolean = bundle === null || bundle.sourceDocumentId.length === 0 ||
        (effectiveDoc.length > 0 && bundle.sourceDocumentId === effectiveDoc);
      if (sameDoc && rawId >= 0 && rawId < afterStructure.cellNames.length) {
        return rawId;
      }
      return -1;
    };

    if (importedCells.length === 0) {
      const remappedTemplates: Shape[] = [];
      for (let i = 0; i < this.clipboard.length; i++) {
        const copy: Shape = this.cloneShape(this.clipboard[i]);
        copy.points = copy.points.map((p: Point): Point => ({ x: p.x + 20, y: p.y + 20 }));
        if (copy.type === ShapeType.INSTANCE) {
          const mapped: number = resolveMappedCellId(copy);
          if (mapped < 0 || mapped >= afterStructure.cellNames.length) return [];
          copy.cellId = mapped;
          copy.cellName = afterStructure.cellNames[mapped];
        }
        remappedTemplates.push(copy);
      }
      const previewAll: Shape[] = this.shapes.concat(remappedTemplates.map((t: Shape, idx: number): Shape => {
        const c: Shape = this.cloneShape(t);
        c.id = this.nextId + idx;
        c.ownerCellId = targetOwnerCellId;
        return c;
      }));
      if (validatePropertyHierarchy(previewAll, afterStructure.topCellId, afterStructure.cellNames.length).length > 0) {
        return [];
      }
      return this.createShapeCopies(remappedTemplates, true, selectCreated);
    }

    const nextShapes: Shape[] = this.shapes.map((s: Shape): Shape => this.cloneShape(s));
    let allocId: number = this.nextId;
    for (let i = 0; i < nextShapes.length; i++) {
      allocId = Math.max(allocId, nextShapes[i].id + 1);
    }
    let totalPoints: number = 0;
    for (let i = 0; i < nextShapes.length; i++) totalPoints += nextShapes[i].points.length;

    const usedLayerKeys: Set<string> = new Set<string>();
    for (let ci = 0; ci < importedCells.length; ci++) {
      const def: ClipboardCellDefinition = importedCells[ci];
      const ownerId: number = importedTargetIds[ci];
      for (let si = 0; si < def.shapes.length; si++) {
        const childCopy: Shape = this.cloneShape(def.shapes[si]);
        if (!this.canEditLayer(childCopy.layerNumber, childCopy.datatype)) return [];
        for (let pi = 0; pi < childCopy.points.length; pi++) {
          if (!Number.isFinite(childCopy.points[pi].x) || !Number.isFinite(childCopy.points[pi].y)) return [];
        }
        totalPoints += childCopy.points.length;
        if (totalPoints > 4000000) return [];
        childCopy.id = allocId++;
        childCopy.ownerCellId = ownerId;
        childCopy.selected = false;
        if (childCopy.type === ShapeType.INSTANCE) {
          const mappedChild: number = resolveMappedCellId(childCopy);
          if (mappedChild < 0 || mappedChild >= afterStructure.cellNames.length) return [];
          childCopy.cellId = mappedChild;
          childCopy.cellName = afterStructure.cellNames[mappedChild];
        } else {
          usedLayerKeys.add(`${childCopy.layerNumber}/${childCopy.datatype}`);
        }
        nextShapes.push(childCopy);
      }
    }

    const pastedIds: number[] = [];
    for (let i = 0; i < this.clipboard.length; i++) {
      const topCopy: Shape = this.cloneShape(this.clipboard[i]);
      if (!this.canEditLayer(topCopy.layerNumber, topCopy.datatype)) return [];
      topCopy.points = topCopy.points.map((p: Point): Point => ({ x: p.x + 20, y: p.y + 20 }));
      for (let pi = 0; pi < topCopy.points.length; pi++) {
        if (!Number.isFinite(topCopy.points[pi].x) || !Number.isFinite(topCopy.points[pi].y)) return [];
      }
      totalPoints += topCopy.points.length;
      if (totalPoints > 4000000) return [];
      topCopy.id = allocId++;
      topCopy.ownerCellId = targetOwnerCellId;
      topCopy.selected = false;
      if (topCopy.type === ShapeType.INSTANCE) {
        const mappedTop: number = resolveMappedCellId(topCopy);
        if (mappedTop < 0 || mappedTop >= afterStructure.cellNames.length) return [];
        topCopy.cellId = mappedTop;
        topCopy.cellName = afterStructure.cellNames[mappedTop];
      } else {
        usedLayerKeys.add(`${topCopy.layerNumber}/${topCopy.datatype}`);
      }
      nextShapes.push(topCopy);
      pastedIds.push(topCopy.id);
    }

    if (nextShapes.length > 1000000) return [];
    if (bundle !== null && afterStructure.layers !== undefined) {
      for (let li = 0; li < bundle.sourceLayers.length; li++) {
        const sl: UiLayer = bundle.sourceLayers[li];
        const key: string = `${sl.layerNumber}/${sl.datatype}`;
        if (!usedLayerKeys.has(key)) continue;
        const exists: boolean = afterStructure.layers.some((tl: UiLayer): boolean =>
          tl.layerNumber === sl.layerNumber && tl.datatype === sl.datatype);
        if (!exists) {
          const clonedLayer: UiLayer = cloneUiLayerModel(sl) as UiLayer;
          clonedLayer.locked = false;
          afterStructure.layers.push(clonedLayer);
        }
      }
    }

    if (validatePropertyHierarchy(nextShapes, afterStructure.topCellId, afterStructure.cellNames.length).length > 0) {
      return [];
    }
    const ok: boolean = this.applyDocumentStructure(
      nextShapes,
      beforeStructure,
      afterStructure,
      '跨标签粘贴实例与子单元',
      true,
      selectCreated ? pastedIds : undefined
    );
    if (!ok) return [];
    const idSet: Set<number> = new Set<number>(pastedIds);
    return this.shapes.filter((s: Shape): boolean => idSet.has(s.id));
  }

  /**
   * 原地偏移复制选中图形（Duplicate）：不污染系统/应用剪贴板，单步撤销并自动选中新副本
   */
  duplicateSelection(offsetX: number = 20, offsetY: number = 20): Shape[] {
    const ids: number[] = this.getSelectedIds();
    if (ids.length === 0) {
      return [];
    }
    const templates: Shape[] = [];
    for (let i = 0; i < ids.length; i++) {
      const src: Shape | undefined = this.shapes.find((sh: Shape): boolean => sh.id === ids[i]);
      if (src !== undefined && this.isShapeInCurrentCell(src)) {
        const copy: Shape = this.cloneShape(src);
        copy.points = copy.points.map((p: Point): Point => ({ x: p.x + offsetX, y: p.y + offsetY }));
        templates.push(copy);
      }
    }
    return this.createShapeCopies(templates, true, true);
  }

  /** Copy/array insertion preflights cycles, expansion, layers and coordinates as one unit. */
  createShapeCopies(templates: Shape[], recordSelectionHistory: boolean = false, selectCreated: boolean = false): Shape[] {
    if (templates.length === 0 || templates.length + this.shapes.length > 1000000) return [];
    const prepared: Shape[] = [];
    let pointCount: number = 0;
    for (const shape of this.shapes) pointCount += shape.points.length;
    for (let i = 0; i < templates.length; i++) {
      const source: Shape = templates[i];
      if (!this.canEditLayer(source.layerNumber, source.datatype)) return [];
      pointCount += source.points.length;
      if (pointCount > 4000000) return [];
      for (const point of source.points) if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return [];
      const copy: Shape = this.cloneShape(source);
      copy.id = this.nextId + i;
      copy.ownerCellId = this.getCurrentCellId();
      copy.selected = false;
      prepared.push(copy);
    }
    if (validatePropertyHierarchy(this.shapes.concat(prepared), this.topCellId).length > 0) return [];
    const selectionBefore: EditSelectionState | undefined = recordSelectionHistory || selectCreated ? this.captureSelectionState() : undefined;
    this.beginBatch();
    try {
      for (const copy of prepared) {
        this.shapes.push(copy);
        const action: EditAction = { type: 'create', shapeId: copy.id, after: this.cloneShape(copy) };
        if (selectionBefore !== undefined) {
          // First Undo and last Redo restore the batch endpoints. Only an
          // explicit paste request selects copies; arrays keep their source selection.
          if (copy === prepared[0]) action.selectionBefore = this.cloneSelectionState(selectionBefore);
          if (copy === prepared[prepared.length - 1]) {
            if (selectCreated) this.selectMultiple(prepared.map((shape: Shape): number => shape.id));
            action.selectionAfter = selectCreated ? this.captureSelectionState() : this.cloneSelectionState(selectionBefore);
          }
        }
        this.pushUndo(action);
      }
      this.nextId += prepared.length;
    } finally {
      this.endBatch();
    }
    return prepared;
  }

  /**
   * 更新图形属性（图层/位置）
   * @param id 图形 ID
   * @param newLayerNumber 新图层号（-1 表示不改）
   * @param dx X 方向位移（0 表示不改）
   * @param dy Y 方向位移（0 表示不改）
   */
  updateShape(id: number, newLayerNumber: number, dx: number, dy: number, newDatatype: number = -1): boolean {
    const shape: Shape | undefined = this.shapes.find(s => s.id === id);
    if (!shape) return false;
    const targetLayer: number = newLayerNumber >= 0 ? newLayerNumber : shape.layerNumber;
    const targetDatatype: number = newDatatype >= 0 ? newDatatype : shape.datatype;
    if (!this.canEditLayer(shape.layerNumber, shape.datatype) ||
      !this.canEditLayer(targetLayer, targetDatatype)) return false;
    const layerChanged: boolean = targetLayer !== shape.layerNumber || targetDatatype !== shape.datatype;
    const moved = dx !== 0 || dy !== 0;
    if (!layerChanged && !moved) {
      return true;
    }
    this.pushUndo({ type: 'modify', shapeId: id, before: this.cloneShape(shape) });
    if (newLayerNumber >= 0) {
      shape.layerNumber = newLayerNumber;
    }
    shape.datatype = targetDatatype;
    if (moved) {
      shape.points = shape.points.map((point: Point): Point => ({ x: point.x + dx, y: point.y + dy }));
    }
    // E-TX: 事务开启时 pushUndo 只缓冲、不上栈，原先的
    // 「回写 undoStack 末条 after」会写到错误位置；改为随本条记录直接带 after
    const pending: EditAction | null = this.pendingOrTopAction(id);
    if (pending !== null) {
      pending.after = this.cloneShape(shape);
    }
    this.redoStack = [];
    return true;
  }

  /**
   * E-TX: 找到「刚刚为 shapeId 压入、尚可补写 after」的那条记录 ——
   * 事务缓冲中最后一条，或撤销栈栈顶；找不到返回 null。
   */
  private pendingOrTopAction(shapeId: number): EditAction | null {
    if (this.txDepth > 0) {
      for (let i = this.txSteps.length - 1; i >= 0; i--) {
        if (this.txSteps[i].shapeId === shapeId && this.txSteps[i].after === undefined) {
          return this.txSteps[i];
        }
      }
      return null;
    }
    const top: EditAction | undefined = this.undoStack[this.undoStack.length - 1];
    if (top !== undefined && top.shapeId === shapeId && top.after === undefined) {
      return top;
    }
    return null;
  }

  /**
   * Replace a shape's point list and record the change for undo/redo.
   *
   * E-TX: 顶点编辑 / 尺寸调整的落定入口。几何未变时**不产生**撤销记录，
   * 因此「按下后原样松开」的一次手势不会污染栈（这正是拖拽撤销步膨胀的根因）。
   */
  updateShapePoints(id: number, points: Point[]): boolean {
    const shape: Shape | undefined = this.shapes.find(s => s.id === id);
    if (!shape || !this.canEditLayer(shape.layerNumber, shape.datatype)) {
      return false;
    }
    const nextPoints: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      nextPoints.push({ x: points[i].x, y: points[i].y });
    }
    if (EditService.samePoints(shape.points, nextPoints)) {
      return true;
    }
    const before = this.cloneShape(shape);
    shape.points = nextPoints;
    const after = this.cloneShape(shape);
    this.pushUndo({ type: 'modify', shapeId: id, before: before, after: after });
    this.redoStack = [];
    return true;
  }

  /** Update a PATH shape width and record the change for undo/redo. */
  updateProperties(ids: number[], property: string, value: string, cells: PropertyCellOption[] = []): PropertyEditResult {
    const targets: Shape[] = [];
    const before: Shape[] = [];
    const unique: Set<number> = new Set<number>(ids);
    if (unique.size === 0) return { ok: false, changed: 0, message: '请先选择对象' };
    const indices: Map<number, number> = new Map<number, number>();
    for (let i = 0; i < this.shapes.length; i++) indices.set(this.shapes[i].id, i);
    for (const id of unique) {
      const index: number | undefined = indices.get(id);
      const original: Shape | undefined = index === undefined ? undefined : this.shapes[index];
      if (original === undefined || !this.isShapeInCurrentCell(original) ||
        !this.canEditLayer(original.layerNumber, original.datatype)) return { ok: false, changed: 0, message: '选区含失效、非当前 Cell 或锁定对象' };
      const next: Shape = this.cloneShape(original);
      const error: string = prepareShapeProperty(next, property, value, cells, this.shapes, this.topCellId);
      if (error.length > 0) return { ok: false, changed: 0, message: error };
      const bounds = getShapeBounds(next);
      if (next.points.some((p: Point) => !Number.isFinite(p.x) || !Number.isFinite(p.y)) ||
        !Number.isFinite(bounds.minX) || !Number.isFinite(bounds.minY) || !Number.isFinite(bounds.maxX) || !Number.isFinite(bounds.maxY)) {
        return { ok: false, changed: 0, message: '修改后的坐标或尺寸超出有限数值范围' };
      }
      if (!this.canEditLayer(next.layerNumber, next.datatype)) return { ok: false, changed: 0, message: '目标图层已锁定' };
      if (JSON.stringify(original) !== JSON.stringify(next)) {
        before.push(this.cloneShape(original)); targets.push(next);
      }
    }
    if (targets.length === 0) return { ok: true, changed: 0, message: '属性未改变' };
    if (property === 'cellId' || property === 'arrayCols' || property === 'arrayRows') {
      const replacements: Map<number, Shape> = new Map<number, Shape>();
      for (const target of targets) replacements.set(target.id, target);
      const error: string = validatePropertyHierarchy(this.shapes.map((s: Shape): Shape => replacements.get(s.id) ?? s), this.topCellId);
      if (error.length > 0) return { ok: false, changed: 0, message: error };
    }
    this.beginBatch();
    try {
      for (let i = 0; i < targets.length; i++) {
        const next: Shape = targets[i];
        const index: number = indices.get(next.id) as number;
        this.shapes[index] = next;
        this.pushUndo({ type: 'modify', shapeId: next.id, before: before[i], after: this.cloneShape(next) });
      }
    } finally { this.endBatch(); }
    return { ok: true, changed: targets.length, message: `已更新 ${targets.length} 个对象` };
  }

  /** Update a PATH shape width and record the change for undo/redo. */
  updateShapePathWidth(id: number, width: number): boolean {
    const shape: Shape | undefined = this.shapes.find(s => s.id === id);
    if (!shape || shape.type !== ShapeType.PATH || !this.canEditLayer(shape.layerNumber, shape.datatype)) {
      return false;
    }
    if (!Number.isFinite(width) || width <= 0) return false;
    if (shape.pathWidth === width) return true;
    const next: Shape = this.cloneShape(shape);
    next.pathWidth = width;
    const bounds = getShapeBounds(next);
    if (!Number.isFinite(bounds.minX) || !Number.isFinite(bounds.minY) ||
      !Number.isFinite(bounds.maxX) || !Number.isFinite(bounds.maxY)) return false;
    const before = this.cloneShape(shape);
    shape.pathWidth = width;
    const after = this.cloneShape(shape);
    this.pushUndo({ type: 'modify', shapeId: id, before: before, after: after });
    this.redoStack = [];
    return true;
  }

  /** Update a TEXT shape string and record the change for undo/redo. */
  updateShapeText(id: number, text: string): boolean {
    const shape: Shape | undefined = this.shapes.find(s => s.id === id);
    if (!shape || shape.type !== ShapeType.TEXT || !this.canEditLayer(shape.layerNumber, shape.datatype)) {
      return false;
    }
    const before = this.cloneShape(shape);
    shape.text = text;
    const after = this.cloneShape(shape);
    this.pushUndo({ type: 'modify', shapeId: id, before: before, after: after });
    this.redoStack = [];
    return true;
  }

  /** Select a shape and clear previous multi-selection. */
  selectShape(id: number): void {
    this.clearSelection();
    if (id >= 0) {
      const shape = this.getShapeById(id);
      if (shape && this.canSelectShape(shape)) {
        shape.selected = true;
        this.selectedId = id;
        this.cachedSelectedShapes = [shape];
        this.cachedSelectedIdsList = [id];
        this.selectionCacheKey = this.currentSelectionPruneKey();
      }
    }
  }

  /** 取消选中（单选 + 多选全部清除） — 已与 clearSelection 合并，保留 clearSelection 作为唯一入口 */

  /**
   * 点击测试：找出指定坐标处的图形
   * @param x 点击 X 坐标
   * @param y 点击 Y 坐标
   * @param tolerance 命中容差（nm），默认 8；触屏场景建议传 15
   * @returns 图形 ID，无命中返回 -1
   */
  hitTest(x: number, y: number, tolerance: number = 8, layerNumber: number = -1, datatype: number = 0): number {
    // v0.3: 仅在原生 g_layout 与当前 ArkTS 基线一致且未标脏时启用 R-Tree 加速，杜绝拾取脑裂
    const nativeCandidates = this.canPreferNativeExpand() ? nativeHongTuService.queryPoint(x, y) : [];
    if (nativeCandidates.length > 0) {
      // 从后往前测试候选（后绘制的在上层）
      for (let i = nativeCandidates.length - 1; i >= 0; i--) {
        const shapeId = nativeCandidates[i];
        const shape = this.shapes.find(s => s.id === shapeId);
        if (!shape) continue;
        if (!this.isShapeInCurrentCell(shape)) continue;
        if ((layerNumber >= 0 && (shape.layerNumber !== layerNumber || shape.datatype !== datatype)) || !this.canSelectShape(shape)) continue;
        if (this.isPointInShape(x, y, shape, tolerance)) {
          return shape.id;
        }
      }
    }

    // 回退: 线性扫描（原生不可用或 tolerance 扩展区域超出 R-Tree 点查询范围）
    for (let i = this.shapes.length - 1; i >= 0; i--) {
      const shape = this.shapes[i];
      if (!this.isShapeInCurrentCell(shape)) {
        continue;
      }
      // 可见、可选且未锁定才允许画布命中。
      if ((layerNumber >= 0 && (shape.layerNumber !== layerNumber || shape.datatype !== datatype)) || !this.canSelectShape(shape)) {
        continue;
      }
      if (this.isPointInShape(x, y, shape, tolerance)) {
        return shape.id;
      }
    }
    return -1;
  }

  private isPointInShape(x: number, y: number, shape: Shape, tolerance: number): boolean {
    // 文字命中区：bounds + 16px padding + tolerance
    if (shape.type === ShapeType.TEXT) {
      const b = getShapeBounds(shape);
      const pad = 16 + tolerance;
      return x >= b.minX - pad && x <= b.maxX + pad &&
             y >= b.minY - pad && y <= b.maxY + pad;
    }
    if (shape.type === ShapeType.RECT && shape.points.length >= 2) {
      // 矩形：bounds 扩展 tolerance 后包含点
      const b = getShapeBounds(shape);
      return x >= b.minX - tolerance && x <= b.maxX + tolerance &&
             y >= b.minY - tolerance && y <= b.maxY + tolerance;
    }
    if (shape.type === ShapeType.POLYGON && shape.points.length >= 3) {
      // 多边形：内部命中，或距任一边在 tolerance 内
      if (this.isPointInPolygon(x, y, shape.points)) return true;
      for (let i = 0; i < shape.points.length; i++) {
        const j = (i + 1) % shape.points.length;
        if (this.distanceToSegment(x, y, shape.points[i], shape.points[j]) <= tolerance) {
          return true;
        }
      }
      return false;
    }
    if (shape.type === ShapeType.PATH && shape.points.length >= 2) {
      // 路径：原有路径宽度容差 + 命中容差
      const pathTol = (shape.pathWidth ?? 4) / 2 + 2 + tolerance;
      const centerline: Point[] = shape.points.filter((p: Point, i: number): boolean => i === 0 ||
        p.x !== shape.points[i - 1].x || p.y !== shape.points[i - 1].y)
        .map((p: Point): Point => ({ x: p.x, y: p.y }));
      if (centerline.length < 2) return false;
      if (shape.pathType === 2 || shape.pathType === 4) {
        const start: Point = centerline[0];
        const next: Point = centerline[1];
        const end: Point = centerline[centerline.length - 1];
        const prior: Point = centerline[centerline.length - 2];
        const startLength: number = Math.hypot(next.x - start.x, next.y - start.y);
        const endLength: number = Math.hypot(end.x - prior.x, end.y - prior.y);
        const beginExtension: number = shape.pathType === 2 ? (shape.pathWidth ?? 0) / 2 : shape.pathBeginExtension ?? 0;
        const endExtension: number = shape.pathType === 2 ? (shape.pathWidth ?? 0) / 2 : shape.pathEndExtension ?? 0;
        // Compute both directions before writing either endpoint (two-point PATH).
        const beginDx: number = startLength > 0 ? (next.x - start.x) / startLength * beginExtension : 0;
        const beginDy: number = startLength > 0 ? (next.y - start.y) / startLength * beginExtension : 0;
        const endDx: number = endLength > 0 ? (end.x - prior.x) / endLength * endExtension : 0;
        const endDy: number = endLength > 0 ? (end.y - prior.y) / endLength * endExtension : 0;
        start.x -= beginDx; start.y -= beginDy;
        end.x += endDx; end.y += endDy;
      }
      for (let i = 1; i < centerline.length; i++) {
        if (this.distanceToSegment(x, y, centerline[i - 1], centerline[i]) <= pathTol) {
          return true;
        }
      }
      return false;
    }
    if (shape.type === ShapeType.INSTANCE) {
      // 实例：以放置点为中心的默认方块 + tolerance
      if (shape.points.length >= 1) {
        const p = shape.points[0];
        const half = 10 + tolerance;
        return x >= p.x - half && x <= p.x + half &&
               y >= p.y - half && y <= p.y + half;
      }
      return false;
    }
    // 兜底：bounds + tolerance
    const b = getShapeBounds(shape);
    return x >= b.minX - tolerance && x <= b.maxX + tolerance &&
           y >= b.minY - tolerance && y <= b.maxY + tolerance;
  }

  private isPointInPolygon(x: number, y: number, pts: Point[]): boolean {
    let inside = false;
    for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
      if (((pts[i].y > y) !== (pts[j].y > y)) &&
          (x < (pts[j].x - pts[i].x) * (y - pts[i].y) / (pts[j].y - pts[i].y) + pts[i].x)) {
        inside = !inside;
      }
    }
    return inside;
  }

  private distanceToSegment(px: number, py: number, a: Point, b: Point): number {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    if (dx === 0 && dy === 0) return Math.sqrt((px - a.x) ** 2 + (py - a.y) ** 2);
    const t = Math.max(0, Math.min(1, ((px - a.x) * dx + (py - a.y) * dy) / (dx * dx + dy * dy)));
    return Math.sqrt((px - a.x - t * dx) ** 2 + (py - a.y - t * dy) ** 2);
  }

  /**
   * 移动图形
   * @param id 图形 ID
   * @param dx X 方向位移
   * @param dy Y 方向位移
   * @returns 移动成功返回 true，找不到图形返回 false
   */
  moveShape(id: number, dx: number, dy: number): boolean {
    const shape = this.shapes.find(s => s.id === id);
    if (!shape || !this.canEditLayer(shape.layerNumber, shape.datatype)) return false;
    // E-TX: 零位移（如 gridSize=0 时的方向键微移）不落撤销记录，避免空撤销步
    if (dx === 0 && dy === 0) return true;
    if (!Number.isFinite(dx) || !Number.isFinite(dy)) return false;
    const before = this.cloneShape(shape);
    const newPts: Point[] = [];
    for (let i = 0; i < shape.points.length; i++) {
      newPts.push({ x: shape.points[i].x + dx, y: shape.points[i].y + dy });
    }
    for (const point of newPts) if (!Number.isFinite(point.x) || !Number.isFinite(point.y)) return false;
    shape.points = newPts;
    const after = this.cloneShape(shape);
    this.pushUndo({ type: 'move', shapeId: id, before: before, after: after });
    this.redoStack = [];
    return true;
  }

  /**
   * 两点移动：根据起止绝对坐标移动图形
   * 内部计算 dx=toX-fromX, dy=toY-fromY，复用 moveShape 逻辑与 undo 机制
   * @param id 图形 ID
   * @param fromX 基点 X（绝对坐标）
   * @param fromY 基点 Y（绝对坐标）
   * @param toX 目标点 X（绝对坐标）
   * @param toY 目标点 Y（绝对坐标）
   * @returns 移动成功返回 true，找不到图形返回 false
   */
  moveShapeAbsolute(id: number, fromX: number, fromY: number, toX: number, toY: number): boolean {
    // M-3: 校验输入为有限数，避免 NaN/Infinity 永久腐蚀图形坐标
    if (!Number.isFinite(fromX) || !Number.isFinite(fromY) || !Number.isFinite(toX) || !Number.isFinite(toY)) {
      return false;
    }
    const dx = toX - fromX;
    const dy = toY - fromY;
    return this.moveShape(id, dx, dy);
  }

  /**
   * 旋转图形（EDIT-1）
   *
   * 对 RECT/POLYGON/PATH/TEXT 的 points 做绕中心点的旋转变换。
   * 对 INSTANCE/TEXT 同时变换锚点、STRANS 和阵列步进；任意角 RECT 转为 POLYGON。
   *
   * @param id 图形 ID
   * @param degrees 旋转角度（度，世界坐标 Y 向上，正为逆时针）
   * @param centerX 旋转中心 X（默认 0，即世界坐标系原点）
   * @param centerY 旋转中心 Y（默认 0）
   * @returns 成功返回 true，找不到图形返回 false
   */
  rotateShape(id: number, degrees: number, centerX: number = 0, centerY: number = 0): boolean {
    return this.transformShapes([id], 'rotate', degrees, centerX, centerY);
  }

  /** Prepare every result before committing; selection transforms stay atomic. */
  transformShapes(ids: number[], operation: string, value: number, centerX?: number, centerY?: number): boolean {
    if (!Number.isFinite(value) || (operation === 'scale' && value <= 0) ||
      (centerX !== undefined && !Number.isFinite(centerX)) || (centerY !== undefined && !Number.isFinite(centerY))) return false;
    const before: Shape[] = [];
    const after: Shape[] = [];
    for (const id of ids) {
      const source: Shape | undefined = this.shapes.find((s: Shape) => s.id === id);
      if (source === undefined || !this.canEditLayer(source.layerNumber, source.datatype)) return false;
      const bounds = getShapeBounds(source);
      const cx: number = centerX ?? (bounds.minX / 2 + bounds.maxX / 2);
      const cy: number = centerY ?? (bounds.minY / 2 + bounds.maxY / 2);
      const result: Shape | null = this.transformedShape(source, operation, value, cx, cy);
      if (result === null) return false;
      before.push(this.cloneShape(source));
      after.push(result);
    }
    if (before.length === 0) return false;
    if ((operation === 'rotate' && value % 360 === 0) || (operation === 'scale' && value === 1)) return true;
    this.beginBatch();
    try {
      for (let i = 0; i < after.length; i++) {
        const index: number = this.shapes.findIndex((s: Shape) => s.id === after[i].id);
        this.shapes[index] = after[i];
        this.pushUndo({ type: 'modify', shapeId: after[i].id, before: before[i], after: this.cloneShape(after[i]) });
      }
    } finally {
      this.endBatch();
    }
    return true;
  }

  /** Replace RECT/POLYGON outline while keeping ID, layer and stream attributes. */
  updatePolygonOutline(id: number, points: Point[]): boolean {
    const shape: Shape | undefined = this.shapes.find((s: Shape): boolean => s.id === id);
    if (shape === undefined || !this.isShapeInCurrentCell(shape) || !this.canEditLayer(shape.layerNumber, shape.datatype) ||
      (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON) || points.length < 3 ||
      points.some((point: Point): boolean => !Number.isFinite(point.x) || !Number.isFinite(point.y))) return false;
    if (shape.type === ShapeType.POLYGON && EditService.samePoints(shape.points, points)) return true;
    const before: Shape = this.cloneShape(shape);
    shape.type = ShapeType.POLYGON;
    shape.points = points.map((point: Point): Point => ({ x: point.x, y: point.y }));
    this.pushUndo({ type: 'modify', shapeId: id, before: before, after: this.cloneShape(shape) });
    return true;
  }

  private transformedShape(source: Shape, operation: string, value: number, cx: number, cy: number): Shape | null {
    const result: Shape = this.cloneShape(source);
    const angle: number = operation === 'rotate' ? (value % 360) * Math.PI / 180 : 0;
    const c: number = Math.cos(angle);
    const s: number = Math.sin(angle);
    const scale: number = operation === 'scale' ? value : 1;
    const a: number = operation === 'mirrorY' ? -1 : c * scale;
    const b: number = operation === 'mirrorX' || operation === 'mirrorY' ? 0 : -s * scale;
    const d: number = operation === 'mirrorX' ? -1 : c * scale;
    const e: number = operation === 'mirrorX' || operation === 'mirrorY' ? 0 : s * scale;
    if (operation !== 'rotate' && operation !== 'scale' && operation !== 'mirrorX' && operation !== 'mirrorY') return null;
    if (result.type === ShapeType.RECT && operation === 'rotate' && value % 90 !== 0) {
      const box = getShapeBounds(result);
      result.points = [{ x: box.minX, y: box.minY }, { x: box.maxX, y: box.minY },
        { x: box.maxX, y: box.maxY }, { x: box.minX, y: box.maxY }];
      result.type = ShapeType.POLYGON;
    }
    result.points = result.points.map((p: Point): Point => ({
      x: cx + a * (p.x - cx) + b * (p.y - cy),
      y: cy + e * (p.x - cx) + d * (p.y - cy)
    }));
    if (result.type === ShapeType.INSTANCE || result.type === ShapeType.TEXT) {
      const mirror: number = result.mirror ?? 0;
      const oldAngle: number = (result.rotation ?? 0) + (mirror === 2 ? 180 : 0);
      if (operation === 'rotate') result.rotation = ((oldAngle + value) % 360 + 360) % 360;
      else if (operation === 'mirrorX' || operation === 'mirrorY') {
        result.rotation = (((operation === 'mirrorY' ? 180 : 0) - oldAngle) % 360 + 360) % 360;
      }
      if (operation !== 'scale') result.mirror = operation === 'rotate'
        ? (mirror === 0 ? 0 : 1) : (mirror === 0 ? 1 : 0);
      if (operation === 'scale') result.magnification = (result.magnification ?? 1) * scale;
      if (result.type === ShapeType.INSTANCE) {
        const colX: number = result.arrayColStepX ?? 0;
        const colY: number = result.arrayColStepY ?? 0;
        const rowX: number = result.arrayRowStepX ?? 0;
        const rowY: number = result.arrayRowStepY ?? 0;
        if (result.arrayColStepX !== undefined || result.arrayColStepY !== undefined) {
          result.arrayColStepX = a * colX + b * colY;
          result.arrayColStepY = e * colX + d * colY;
        }
        if (result.arrayRowStepX !== undefined || result.arrayRowStepY !== undefined) {
          result.arrayRowStepX = a * rowX + b * rowY;
          result.arrayRowStepY = e * rowX + d * rowY;
        }
      }
    }
    // Negative GDS WIDTH resists instance MAG, but an explicit shape edit scales it.
    if (result.type === ShapeType.PATH && operation === 'scale') {
      if (result.pathWidth !== undefined) result.pathWidth *= scale;
      if (result.pathBeginExtension !== undefined) result.pathBeginExtension *= scale;
      if (result.pathEndExtension !== undefined) result.pathEndExtension *= scale;
    }
    const numbers: number[] = [result.rotation ?? 0, result.magnification ?? 1, result.pathWidth ?? 0,
      result.pathBeginExtension ?? 0, result.pathEndExtension ?? 0, result.arrayColStepX ?? 0,
      result.arrayColStepY ?? 0, result.arrayRowStepX ?? 0, result.arrayRowStepY ?? 0];
    for (const p of result.points) if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) return null;
    for (const number of numbers) if (!Number.isFinite(number)) return null;
    return result;
  }

  /**
   * 镜像图形（EDIT-1）
   *
   * 对 RECT/POLYGON/PATH/TEXT 的 points 做镜像变换。
   * 对 INSTANCE/TEXT 组合外部镜像与已有 STRANS，并变换锚点、阵列步进。
   *
   * @param id 图形 ID
   * @param horizontal true=水平镜像（沿 X 轴翻转，即 Y 取反）；false=垂直镜像（沿 Y 轴翻转，即 X 取反）
   * @param axis 镜像轴坐标（水平镜像时为 Y 值，垂直镜像时为 X 值，默认 0）
   * @returns 成功返回 true，找不到图形返回 false
   */
  mirrorShape(id: number, horizontal: boolean, axis: number = 0): boolean {
    return this.transformShapes([id], horizontal ? 'mirrorX' : 'mirrorY', 0, horizontal ? 0 : axis, horizontal ? axis : 0);
  }

  /**
   * 缩放图形（EDIT-1）
   *
   * 对 RECT/POLYGON/PATH/TEXT 的 points 做绕中心点的缩放变换。
   * 对 INSTANCE/TEXT 同时更新 MAG，INSTANCE 阵列步进随整体缩放。
   * 对 PATH 类型同时缩放 pathWidth。
   *
   * @param id 图形 ID
   * @param factor 缩放因子（>0 放大，<1 缩小，必须为正数）
   * @param centerX 缩放中心 X（默认 0）
   * @param centerY 缩放中心 Y（默认 0）
   * @returns 成功返回 true，找不到图形或不支持返回 false
   */
  scaleShape(id: number, factor: number, centerX: number = 0, centerY: number = 0): boolean {
    return this.transformShapes([id], 'scale', factor, centerX, centerY);
  }

  /** 删除选中的图形（支持多选：删除 selectedIds 中所有图形） */
  deleteSelected(): boolean {
    const ids: number[] = this.getSelectedIds();
    if (ids.length === 0) return false;
    // EDIT-3: 多选删除包入批处理，使 undo 一次撤销整个删除操作
    const useBatch: boolean = ids.length > 1;
    if (useBatch) {
      this.beginBatch();
    }
    let anyDeleted = false;
    try {
      for (let i = 0; i < ids.length; i++) {
        if (this.deleteShape(ids[i])) {
          anyDeleted = true;
        }
      }
    } finally {
      if (useBatch) {
        this.endBatch();
      }
    }
    // 完整清空选择状态（deleteShape 已部分清理，这里确保彻底清空）
    this.selectedIds = new Set<number>();
    this.selectedId = -1;
    return anyDeleted;
  }

  /** Ordinary UI deletion owns its fallback selection and both history endpoints. */
  deleteShapesWithSelectionHistory(ids: number[]): number[] {
    if (ids.length === 0) return [];
    if (this.txDepth !== 0 || this.txSteps.length !== 0) {
      throw new Error('当前编辑手势尚未结束，请稍后删除');
    }
    const candidates: number[] = [];
    const seen: Set<number> = new Set<number>();
    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      const shape: Shape | undefined = this.shapes.find((item: Shape): boolean => item.id === id);
      if (shape !== undefined && shape.type !== ShapeType.NODE && this.isShapeInCurrentCell(shape) &&
        this.canEditLayer(shape.layerNumber, shape.datatype)) candidates.push(id);
    }
    if (candidates.length === 0) return [];

    // Keep live object references, including unrelated extension fields. Do not clone the document.
    const shapesBefore: Shape[] = this.shapes.slice();
    const undoBefore: EditAction[] = this.undoStack.slice();
    const redoBefore: EditAction[] = this.redoStack.slice();
    const selectionBefore: EditSelectionState = this.captureSelectionState();
    const dirtyBefore: boolean = this.dirty;
    const editDepthBefore: number = this.editDepth;
    const reachableBefore: boolean = this.cleanBaselineReachable;
    const revisionBefore: number = this.sessionRevision;
    const deletedIds: number[] = [];
    try {
      this.beginBatch();
      for (const id of candidates) {
        if (this.deleteShape(id)) deletedIds.push(id);
      }
      if (deletedIds.length > 0) {
        const remaining: Shape[] = this.getCurrentCellShapes();
        if (remaining.length > 0) this.selectShape(remaining[0].id);
        else this.clearSelection();
        // Match the ordinary UI publication's existing getter normalization before sealing after.
        this.getSelectedIds();
        const first: EditAction = this.txSteps[0];
        const last: EditAction = this.txSteps[this.txSteps.length - 1];
        first.selectionBefore = this.cloneSelectionState(selectionBefore);
        last.selectionAfter = this.captureSelectionState();
      }
      this.endBatch();
      return deletedIds;
    } catch (error) {
      // The owned batch may have removed objects or trimmed history before an exception.
      this.shapes = shapesBefore;
      this.undoStack = undoBefore;
      this.redoStack = redoBefore;
      this.txDepth = 0;
      this.txSteps = [];
      this.dirty = dirtyBefore;
      this.editDepth = editDepthBefore;
      this.cleanBaselineReachable = reachableBefore;
      this.sessionRevision = revisionBefore;
      this.restoreSelectionState(selectionBefore);
      throw new Error(String(error));
    }
  }

  /** 按 ID 删除图形 */
  deleteShape(id: number): boolean {
    const idx = this.shapes.findIndex(s => s.id === id);
    if (idx < 0) return false;
    const deleted = this.shapes[idx];
    if (!this.canEditLayer(deleted.layerNumber, deleted.datatype)) return false;
    this.shapes.splice(idx, 1);
    this.pushUndo({ type: 'delete', shapeId: id, index: idx, before: this.cloneShape(deleted) });
    this.redoStack = [];
    if (this.selectedId === id) {
      this.selectedId = -1;
    }
    // 同步清理多选集合
    this.selectedIds.delete(id);
    return true;
  }

  /**
   * 压入一条编辑记录。
   * E-TX: 事务开启时只做缓冲（手势中途的子步骤绝不占独立撤销步），
   * 闭合到 0 层时由 commitTransaction() 合并成一条记录上栈。
   */
  private pushUndo(action: EditAction): void {
    this.redoStack = [];
    this.nativeSnapshotCurrent = false;
    if (this.txDepth > 0) {
      this.sessionRevision++;
      this.txSteps.push(action);
      return;
    }
    this.appendUndo(action);
  }

  /** 记录直接上栈：按 contentCount 结 dirty/editDepth 账，并维持 MAX_UNDO_STACK 上限 */
  private appendUndo(action: EditAction, fromRedo: boolean = false): void {
    const n: number = this.contentCount(action);
    if (n > 0) {
      this.sessionRevision++;
      this.nativeSnapshotCurrent = false;
      if (!fromRedo && this.editDepth < 0) this.cleanBaselineReachable = false;
      this.editDepth += n;
      this.dirty = true;
    }
    this.undoStack.push(action);
    while (this.undoStack.length > EditService.MAX_UNDO_STACK) {
      const dropped: EditAction | undefined = this.undoStack.shift();
      if (dropped === undefined) {
        break;
      }
      // Trimming history does not undo its edits or move the saved baseline.
    }
    this.syncDirtyFromEditDepth();
  }

  /** 压入 redo 栈，并在超过 MAX_UNDO_STACK 时丢弃最旧记录 */
  private pushRedo(action: EditAction): void {
    this.redoStack.push(action);
    while (this.redoStack.length > EditService.MAX_UNDO_STACK) {
      this.redoStack.shift();
    }
  }

  /**
   * 注入图层可见性判断回调。
   * hitTest 会据此跳过 visible === false 的图层上的图形；未注入时视为全部可见。
   * @param provider 给定 layerNumber 返回是否可见
   */
  setLayerVisibleProvider(provider: ((layerNumber: number, datatype: number) => boolean) | null): void {
    this.layerVisibleProvider = provider;
    this.refreshLayerAccess();
  }

  /** Geometry bounds include locked/unselectable children whenever they remain visible. */
  isLayerVisible(layerNumber: number, datatype: number): boolean {
    return this.layerVisibleProvider === null || this.layerVisibleProvider(layerNumber, datatype);
  }

  /** 注入图层可选状态（selectable=false 不能经命中或 ID 入口选中）。 */
  setLayerSelectableProvider(provider: ((layerNumber: number, datatype: number) => boolean) | null): void {
    this.layerSelectableProvider = provider;
    this.refreshLayerAccess();
  }

  /** 注入图层编辑状态（locked=true 不能选中，也不能经 ID 入口修改）。 */
  setLayerEditableProvider(provider: ((layerNumber: number, datatype: number) => boolean) | null): void {
    this.layerEditableProvider = provider;
    this.refreshLayerAccess();
  }

  /** 图层状态对象原地变化后由界面调用，立即清理此前选中的锁定/不可选图形。 */
  refreshLayerAccess(): void {
    this.layerAccessEpoch++;
    this.invalidateSelectionCache();
    this.pruneSelection();
  }

  /** 供创建动作的调用方预检；现有 create* 返回 Shape/ID，不能用空值表示拒绝。 */
  canEditLayer(layerNumber: number, datatype: number = 0): boolean {
    return Number.isInteger(layerNumber) && layerNumber >= 0 && layerNumber <= 32767 &&
      Number.isInteger(datatype) && datatype >= 0 && datatype <= 32767 &&
      (this.layerEditableProvider === null || this.layerEditableProvider(layerNumber, datatype));
  }

  private requireEditableLayer(layerNumber: number, datatype: number): void {
    if (!this.canEditLayer(layerNumber, datatype)) {
      throw new Error(`图层 ${layerNumber}/${datatype} 已锁定或图层编号无效`);
    }
  }

  /** Locked layers remain readable/selectable; every mutation separately checks canEditLayer. */
  canSelectLayer(layerNumber: number, datatype: number = 0): boolean {
    return Number.isInteger(layerNumber) && layerNumber >= 0 && layerNumber <= 32767 &&
      Number.isInteger(datatype) && datatype >= 0 && datatype <= 32767 &&
      (this.layerVisibleProvider === null || this.layerVisibleProvider(layerNumber, datatype)) &&
      (this.layerSelectableProvider === null || this.layerSelectableProvider(layerNumber, datatype));
  }

  private canSelectShape(shape: Shape): boolean {
    return shape.type !== ShapeType.NODE &&
      this.isShapeInCurrentCell(shape) && this.canSelectLayer(shape.layerNumber, shape.datatype);
  }

  // ===== 用户级事务（E-TX，原「AI 操作撤销批处理 Fix ⑩」） =====
  // beginBatch/endBatch 名称保留（AI 命令、对齐、打平、阵列、粘贴等既有调用方不改），
  // 语义升级为「一个用户级手势 = 一条撤销记录」：子记录先进 txSteps 缓冲，
  // 闭合到 0 层时合并为一条记录上栈；嵌套时内层并入外层。

  /** 开始一个用户级事务（一个手势 / 一次批量操作） */
  beginBatch(): void {
    if (this.txDepth === 0 && this.txSteps.length > 0) {
      // 防御：上一次事务未闭合（调用方漏 endBatch 或中途抛异常）时先落账，
      // 否则那批子记录会被本次事务吞掉，用户再也撤不回。
      console.warn('[EditService] beginBatch with unclosed transaction, committing pending steps first');
      this.commitTransaction();
    }
    // Empty/no-op batches preserve redo; pushUndo invalidates it on the first edit.
    this.txDepth++;
  }

  /** 结束事务：闭合到 0 层时把缓冲合并为一条撤销记录 */
  endBatch(): void {
    if (this.txDepth === 0) {
      // 事务已被 undo()/setShapes 强制闭合（或调用方漏配对 begin）：
      // 缓冲为空即无事可做；非空也不能丢，直接落账
      if (this.txSteps.length > 0) {
        console.warn('[EditService] endBatch without open transaction, committing pending steps');
        this.commitTransaction();
      }
      return;
    }
    this.txDepth--;
    if (this.txDepth === 0) {
      this.commitTransaction();
    }
  }

  /** 当前是否有开启中的事务（画布据此避免手势套手势） */
  isTransactionOpen(): boolean {
    return this.txDepth > 0;
  }

  /** 把缓冲的子记录合并上栈：0 条 ⇒ 不产生记录；1 条 ⇒ 原样沿用；≥2 条 ⇒ 一条 transaction */
  private commitTransaction(): void {
    const steps: EditAction[] = this.txSteps;
    this.txSteps = [];
    if (steps.length === 0) {
      return;
    }
    this.redoStack = [];
    if (steps.length === 1) {
      this.appendUndo(steps[0]);
      return;
    }
    const tx: EditAction = { type: 'transaction', shapeId: steps[0].shapeId, steps: steps };
    this.appendUndo(tx);
  }

  /** 强制闭合所有事务层（undo/redo 前置、换文档时调用），保证不丢子记录 */
  private forceCloseTransaction(): void {
    this.txDepth = 0;
    this.commitTransaction();
  }

  /** 撤销 — 弹出一条记录即回退一个完整的用户级手势（事务内部整体回退） */
  undo(): boolean {
    if (this.txSteps.length > 0) {
      // 仍有未闭合事务（如微移合并窗口未到期）时先落账：
      // 否则这条 undo 会跳过刚做完的手势、回退到更早的记录，撤销顺序错位
      this.forceCloseTransaction();
    }
    const action = this.undoStack[this.undoStack.length - 1];
    if (!action || !this.canReplayAction(action)) return false;
    const layerPropertiesHistory: boolean = this.hasLayerPropertiesHistory(action);
    const structural: boolean = this.hasStructureAction(action);
    const recordedSelection: boolean = this.hasSelectionAction(action);
    const atomic: boolean = structural || recordedSelection;
    const rollback: EditSessionState | undefined = atomic ? this.captureSession(layerPropertiesHistory) : undefined;
    const metadata: EditStructureState | undefined = structural && this.structureStateProvider !== null ?
      this.liveStructureState(layerPropertiesHistory) : undefined;
    try {
    this.undoStack.pop();

    this.undoSingle(action);
    this.restoreShapeOrder(action.orderBefore);
    // A parent without its own endpoint retains the ordered effect of sealed
    // children and subsequent legacy steps across metadata publication.
    const replaySelection: EditSelectionState | undefined = action.selectionBefore === undefined && recordedSelection ?
      this.captureSelectionState() : undefined;
    this.notifyStructure(action, false);
    if (replaySelection !== undefined) this.restoreSelectionState(replaySelection);
    this.restoreActionSelection(action, false);
    this.pushRedo(action);
    const n: number = this.contentCount(action);
    if (n > 0) {
      this.editDepth -= n;
      this.syncDirtyFromEditDepth();
    }
    this.invalidateShapeIndex();
    if (recordedSelection) this.pruneRecordedSelection();
    else this.pruneSelection();
    this.nativeSnapshotCurrent = false;
    this.sessionRevision++;
    return true;
    } catch (error) {
      if (rollback === undefined) throw new Error(String(error));
      this.restoreSession(rollback, layerPropertiesHistory);
      let restoreFailure: string = '';
      try {
        if (metadata !== undefined && this.structureRestoreAction !== null) this.structureRestoreAction(this.cloneStructure(metadata, layerPropertiesHistory));
        else this.notifyStructure(action, true, false);
      } catch (failure) { restoreFailure = `；结构恢复回调失败：${String(failure)}`; }
      finally { this.restoreSession(rollback, layerPropertiesHistory); }
      throw new Error(`结构撤销未提交：${String(error)}${restoreFailure}`);
    }
  }

  /**
   * 执行单个撤销操作（'transaction' ⇒ 逆序回放子记录）。
   * 子记录回放不在此处结 editDepth 账，由 undo() 按 contentCount 一次结清。
   */
  private undoSingle(action: EditAction, replayChildSelection: boolean = false): void {
    switch (action.type) {
      case 'structure':
        if (action.structureBefore !== undefined && action.structureAfter !== undefined) {
          if (action.layerPropertiesHistory !== true) this.restoreStructure(action.structureAfter, action.structureBefore);
        }
        break;
      case 'transaction': {
        const txSteps: EditAction[] = action.steps ?? [];
        for (let i = txSteps.length - 1; i >= 0; i--) {
          this.undoSingle(txSteps[i], true);
        }
        break;
      }
      case 'create':
        const createIdx = this.shapes.findIndex(s => s.id === action.shapeId);
        if (createIdx >= 0) this.shapes.splice(createIdx, 1);
        break;
      case 'delete':
        if (action.before) {
          const restored: Shape = this.cloneShape(action.before);
          // 撤销删除 ⇒ 恢复的图元重新入选，Ctrl+Z 后可无缝继续操作
          restored.selected = true;
          const position: number = action.index === undefined ? this.shapes.length : Math.max(0, Math.min(action.index, this.shapes.length));
          this.shapes.splice(position, 0, restored);
          this.selectedIds.add(restored.id);
          if (this.selectedId < 0) {
            this.selectedId = restored.id;
          }
        }
        break;
      case 'move':
      case 'modify':
        const shape = this.shapes.find(s => s.id === action.shapeId);
        if (shape && action.before) {
          const beforePts: Point[] = [];
          for (let i = 0; i < action.before.points.length; i++) {
            beforePts.push({ x: action.before.points[i].x, y: action.before.points[i].y });
          }
          shape.points = beforePts;
          shape.type = action.before.type;
          shape.pathWidth = action.before.pathWidth;
          // 恢复图层号（changeLayer 用 modify 记录）
          shape.layerNumber = action.before.layerNumber;
          shape.datatype = action.before.datatype;
          // EDIT-1: 恢复 text 字段（updateShapeText 用 modify 记录）
          shape.text = action.before.text;
          // 恢复 INSTANCE 相关字段
          shape.ownerCellId = action.before.ownerCellId;
          shape.cellId = action.before.cellId;
          shape.cellName = action.before.cellName;
          shape.rotation = action.before.rotation;
          shape.mirror = action.before.mirror;
          shape.magnification = action.before.magnification;
          shape.textPresentation = action.before.textPresentation;
          shape.properties = normalizePropRecords(action.before.properties);
          shape.pathType = action.before.pathType;
          shape.pathBeginExtension = action.before.pathBeginExtension;
          shape.pathEndExtension = action.before.pathEndExtension;
          shape.pathWidthAbsolute = action.before.pathWidthAbsolute;
          shape.arrayCols = action.before.arrayCols;
          shape.arrayRows = action.before.arrayRows;
          shape.arrayColStepX = action.before.arrayColStepX;
          shape.arrayColStepY = action.before.arrayColStepY;
          shape.arrayRowStepX = action.before.arrayRowStepX;
          shape.arrayRowStepY = action.before.arrayRowStepY;
        }
        break;
    }
    // A sealed child is a selection boundary before subsequent legacy steps.
    // The top-level snapshot is restored again after metadata publication.
    if (replayChildSelection) this.restoreActionSelection(action, false);
  }

  /** 重做 — 弹出一条记录即重放一个完整的用户级手势 */
  redo(): boolean {
    if (this.txSteps.length > 0) this.forceCloseTransaction();
    const action = this.redoStack[this.redoStack.length - 1];
    if (!action || !this.canReplayAction(action)) return false;
    const layerPropertiesHistory: boolean = this.hasLayerPropertiesHistory(action);
    const structural: boolean = this.hasStructureAction(action);
    const recordedSelection: boolean = this.hasSelectionAction(action);
    const atomic: boolean = structural || recordedSelection;
    const rollback: EditSessionState | undefined = atomic ? this.captureSession(layerPropertiesHistory) : undefined;
    const metadata: EditStructureState | undefined = structural && this.structureStateProvider !== null ?
      this.liveStructureState(layerPropertiesHistory) : undefined;
    try {
    this.redoStack.pop();

    this.redoSingle(action);
    this.restoreShapeOrder(action.orderAfter);
    const replaySelection: EditSelectionState | undefined = action.selectionAfter === undefined && recordedSelection ?
      this.captureSelectionState() : undefined;
    this.notifyStructure(action, true);
    if (replaySelection !== undefined) this.restoreSelectionState(replaySelection);
    this.restoreActionSelection(action, true);
    // 重做是回放既有记录，必须直接上栈（走 pushUndo 会在事务开启时被吞进缓冲）
    this.appendUndo(action, true);
    this.nativeSnapshotCurrent = false;
    this.invalidateShapeIndex();
    if (recordedSelection) this.pruneRecordedSelection();
    else this.pruneSelection();
    return true;
    } catch (error) {
      if (rollback === undefined) throw new Error(String(error));
      this.restoreSession(rollback, layerPropertiesHistory);
      let restoreFailure: string = '';
      try {
        if (metadata !== undefined && this.structureRestoreAction !== null) this.structureRestoreAction(this.cloneStructure(metadata, layerPropertiesHistory));
        else this.notifyStructure(action, false, false);
      } catch (failure) { restoreFailure = `；结构恢复回调失败：${String(failure)}`; }
      finally { this.restoreSession(rollback, layerPropertiesHistory); }
      throw new Error(`结构重做未提交：${String(error)}${restoreFailure}`);
    }
  }

  /** 执行单个重做操作（'transaction' ⇒ 正序回放子记录） */
  private redoSingle(action: EditAction, replayChildSelection: boolean = false): void {
    switch (action.type) {
      case 'structure':
        if (action.structureBefore !== undefined && action.structureAfter !== undefined) {
          if (action.layerPropertiesHistory !== true) this.restoreStructure(action.structureBefore, action.structureAfter);
        }
        break;
      case 'transaction': {
        const txSteps: EditAction[] = action.steps ?? [];
        for (let i = 0; i < txSteps.length; i++) {
          this.redoSingle(txSteps[i], true);
        }
        break;
      }
      case 'create':
        if (action.after) {
          const recreated: Shape = this.cloneShape(action.after);
          // 重做创建 ⇒ 该图元入选，与「新建即选中」的手势语义一致
          recreated.selected = true;
          this.shapes.push(recreated);
          this.selectedIds.add(recreated.id);
          if (this.selectedId < 0) {
            this.selectedId = recreated.id;
          }
        }
        break;
      case 'delete':
        const delIdx = this.shapes.findIndex(s => s.id === action.shapeId);
        if (delIdx >= 0) this.shapes.splice(delIdx, 1);
        break;
      case 'move':
      case 'modify':
        const shape = this.shapes.find(s => s.id === action.shapeId);
        if (shape && action.after) {
          const afterPts: Point[] = [];
          for (let i = 0; i < action.after.points.length; i++) {
            afterPts.push({ x: action.after.points[i].x, y: action.after.points[i].y });
          }
          shape.points = afterPts;
          shape.type = action.after.type;
          shape.pathWidth = action.after.pathWidth;
          // 重做图层号（changeLayer 用 modify 记录）
          shape.layerNumber = action.after.layerNumber;
          shape.datatype = action.after.datatype;
          // EDIT-1: 重做 text 字段（updateShapeText 用 modify 记录）
          shape.text = action.after.text;
          // 重做 INSTANCE 相关字段
          shape.ownerCellId = action.after.ownerCellId;
          shape.cellId = action.after.cellId;
          shape.cellName = action.after.cellName;
          shape.rotation = action.after.rotation;
          shape.mirror = action.after.mirror;
          shape.magnification = action.after.magnification;
          shape.textPresentation = action.after.textPresentation;
          shape.properties = normalizePropRecords(action.after.properties);
          shape.pathType = action.after.pathType;
          shape.pathBeginExtension = action.after.pathBeginExtension;
          shape.pathEndExtension = action.after.pathEndExtension;
          shape.pathWidthAbsolute = action.after.pathWidthAbsolute;
          shape.arrayCols = action.after.arrayCols;
          shape.arrayRows = action.after.arrayRows;
          shape.arrayColStepX = action.after.arrayColStepX;
          shape.arrayColStepY = action.after.arrayColStepY;
          shape.arrayRowStepX = action.after.arrayRowStepX;
          shape.arrayRowStepY = action.after.arrayRowStepY;
        }
        break;
    }
    if (replayChildSelection) this.restoreActionSelection(action, true);
  }

  private restoreShapeOrder(order: number[] | undefined): void {
    if (order === undefined) return;
    const byId: Map<number, Shape> = new Map<number, Shape>();
    for (const shape of this.shapes) byId.set(shape.id, shape);
    const ordered: Shape[] = [];
    for (const id of order) {
      const shape: Shape | undefined = byId.get(id);
      if (shape !== undefined) { ordered.push(shape); byId.delete(id); }
    }
    for (const shape of this.shapes) if (byId.has(shape.id)) ordered.push(shape);
    this.shapes = ordered;
  }

  /** 锁定层不能被撤销/重做隐式改动；跨层操作检查前后两个图层。 */
  canEditStructurePorts(before: EditStructureState, after: EditStructureState): boolean {
    const oldPorts: Map<string, LayoutPort> = new Map<string, LayoutPort>();
    const newPorts: Map<string, LayoutPort> = new Map<string, LayoutPort>();
    const oldSections: Map<string, LayoutCrossSection> = new Map<string, LayoutCrossSection>();
    const newSections: Map<string, LayoutCrossSection> = new Map<string, LayoutCrossSection>();
    for (const port of before.ports ?? []) oldPorts.set(port.id, port);
    for (const port of after.ports ?? []) newPorts.set(port.id, port);
    for (const section of before.crossSections ?? []) oldSections.set(`${section.key}:${section.version}`, section);
    for (const section of after.crossSections ?? []) newSections.set(`${section.key}:${section.version}`, section);
    const content = (port: LayoutPort, sections: Map<string, LayoutCrossSection>): string => {
      // Numeric IDs can compact while the same stable Cell and intrinsic frame
      // survive unchanged. Definition changes and descriptor edits require locks.
      const section: LayoutCrossSection | undefined = port.crossSectionKey === undefined ? undefined :
        sections.get(`${port.crossSectionKey}:${port.crossSectionVersion}`);
      return JSON.stringify([port.ownerCellKey, port.name, port.centerNm.x, port.centerNm.y, port.orientationDeg,
        port.widthNm, port.layerNumber, port.datatype, port.portType, port.frameMirror, port.frameMagnification,
        port.crossSectionKey, port.crossSectionVersion, port.infoJson, port.provenance, section]);
    };
    for (const port of before.ports ?? []) {
      const next: LayoutPort | undefined = newPorts.get(port.id);
      if ((next === undefined || content(port, oldSections) !== content(next, newSections)) &&
        (!this.canEditLayer(port.layerNumber, port.datatype) || (next !== undefined && !this.canEditLayer(next.layerNumber, next.datatype)))) return false;
    }
    for (const port of after.ports ?? []) if (!oldPorts.has(port.id) && !this.canEditLayer(port.layerNumber, port.datatype)) return false;
    return true;
  }

  private canReplayAction(action: EditAction): boolean {
    if (action.structureBefore !== undefined && action.structureAfter !== undefined &&
      !this.canEditStructurePorts(action.structureBefore, action.structureAfter)) return false;
    if (action.type === 'transaction') {
      const steps: EditAction[] = action.steps ?? [];
      for (let i = 0; i < steps.length; i++) {
        if (!this.canReplayAction(steps[i])) return false;
      }
      return true;
    }
    if (action.before !== undefined && !this.canEditLayer(action.before.layerNumber, action.before.datatype)) return false;
    if (action.after !== undefined && !this.canEditLayer(action.after.layerNumber, action.after.datatype)) return false;
    const current: Shape | undefined = this.shapes.find((s: Shape) => s.id === action.shapeId);
    return current === undefined || this.canEditLayer(current.layerNumber, current.datatype);
  }

  /** Filter a recorded endpoint without canonicalizing legacy single-selection identity. */
  private pruneRecordedSelection(): void {
    const valid: Set<number> = new Set<number>();
    for (const shape of this.shapes) {
      if (!shape.selected) continue;
      if (this.canSelectShape(shape)) valid.add(shape.id);
      else shape.selected = false;
    }
    const retained: Set<number> = new Set<number>();
    for (const id of this.selectedIds) if (valid.has(id)) retained.add(id);
    this.selectedIds = retained;
    // -1 is a valid recorded sentinel. Only a lost primary needs a fallback;
    // flags-only fallback must not populate an intentionally empty raw ID set.
    if (this.selectedId >= 0 && !valid.has(this.selectedId)) {
      this.selectedId = -1;
      for (const id of retained) this.selectedId = id;
      if (this.selectedId < 0) for (const id of valid) this.selectedId = id;
    }
    this.invalidateSelectionCache();
  }

  /** 清理失效、不可见、不可选或锁定图形的旧选择状态。 */
  private pruneSelection(): void {
    const key: string = this.currentSelectionPruneKey();
    if (this.selectionCacheKey === key) {
      return;
    }
    const valid: Set<number> = new Set<number>();
    const selectedList: Shape[] = [];
    for (let i = 0; i < this.shapes.length; i++) {
      const shape: Shape = this.shapes[i];
      if (!shape.selected) continue;
      if (!this.canSelectShape(shape)) {
        shape.selected = false;
      } else {
        valid.add(shape.id);
        selectedList.push(shape);
      }
    }
    // Pruning must not reorder a sealed multi-selection or replace its valid primary.
    const ordered: Set<number> = new Set<number>();
    for (const id of this.selectedIds) if (valid.has(id)) ordered.add(id);
    for (const id of valid) ordered.add(id);
    this.selectedIds = ordered;
    if (!valid.has(this.selectedId)) {
      this.selectedId = -1;
      for (const id of ordered) this.selectedId = id;
    }
    const idsOut: number[] = [];
    ordered.forEach((id: number) => {
      idsOut.push(id);
    });
    if (idsOut.length === 0 && this.selectedId >= 0 && valid.has(this.selectedId)) {
      idsOut.push(this.selectedId);
    }
    this.cachedSelectedShapes = selectedList;
    this.cachedSelectedIdsList = idsOut;
    this.selectionCacheKey = key;
  }

  /** 是否可撤销 */
  canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  /** E-TX: 撤销栈当前占用的「步数」= 记录条数（一条事务即一步），供状态栏/工具栏提示 */
  undoStepCount(): number {
    return this.undoStack.length;
  }

  /** 不透明的栈顶标记，用于只撤销仍处于栈顶的 AI 批次。 */
  getUndoMarker(): Object | null {
    return this.undoStack.length > 0 ? this.undoStack[this.undoStack.length - 1] : null;
  }

  /** 是否可重做 */
  canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  /** 获取图形数量 */
  getShapeCount(): number {
    return this.shapes.length;
  }

  /** 按图层筛选图形 */
  getShapesByLayer(layerNumber: number, datatype: number = 0): Shape[] {
    return this.shapes.filter(s => s.layerNumber === layerNumber && s.datatype === datatype);
  }

  // ===== 图层批量操作 =====

  /**
   * 批量修改图形图层号
   * 所有 shape 的图层变更合并为单个 undo transaction（用 batch 机制包裹）
   * @param ids 图形 ID 列表
   * @param newLayerNumber 目标图层号
   */
  changeLayer(ids: number[], newLayerNumber: number, datatype: number = 0): PropertyEditResult {
    if (!Number.isInteger(newLayerNumber) || newLayerNumber < 0 || newLayerNumber > 65535 ||
      !Number.isInteger(datatype) || datatype < 0 || datatype > 65535) {
      return { ok: false, changed: 0, message: '图层和数据类型须为 0–65535 整数' };
    }
    const unique: Set<number> = new Set<number>(ids);
    if (unique.size === 0) return { ok: false, changed: 0, message: '请先选择对象' };
    if (!this.canEditLayer(newLayerNumber, datatype)) return { ok: false, changed: 0, message: '目标图层已锁定或不可编辑' };
    const targets: Shape[] = [];
    for (const id of unique) {
      const shape: Shape | undefined = this.shapes.find((s: Shape): boolean => s.id === id);
      if (shape === undefined || !this.isShapeInCurrentCell(shape)) return { ok: false, changed: 0, message: '选区已变化，请重新选择' };
      if (!this.canEditLayer(shape.layerNumber, shape.datatype)) return { ok: false, changed: 0, message: '选区含锁定图层，整批改层已取消' };
      if (shape.layerNumber !== newLayerNumber || shape.datatype !== datatype) targets.push(shape);
    }
    if (targets.length === 0) return { ok: true, changed: 0, message: '选区已在目标图层，无需修改' };
    this.beginBatch();
    try {
      for (const shape of targets) {
        const before = this.cloneShape(shape);
        shape.layerNumber = newLayerNumber;
        shape.datatype = datatype;
        const after = this.cloneShape(shape);
        this.pushUndo({ type: 'modify', shapeId: shape.id, before: before, after: after });
      }
    } finally {
      this.endBatch();
    }
    return { ok: true, changed: targets.length, message: '' };
  }

  // ===== Cell 导航（子 Cell 编辑上下文） =====

  private clonePath(path: InstancePathStep[]): InstancePathStep[] {
    return path.map((step: InstancePathStep): InstancePathStep => ({ parentCellId: step.parentCellId,
      cellId: step.cellId, instanceId: step.instanceId, row: step.row, col: step.col,
      transform: { a: step.transform.a, b: step.transform.b, c: step.transform.c, d: step.transform.d,
        tx: step.transform.tx, ty: step.transform.ty } }));
  }

  private pathIdentity(): InstancePathTransform { return { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }; }

  private pathMultiply(left: InstancePathTransform, right: InstancePathTransform): InstancePathTransform {
    return { a: left.a * right.a + left.b * right.c, b: left.a * right.b + left.b * right.d,
      c: left.c * right.a + left.d * right.c, d: left.c * right.b + left.d * right.d,
      tx: left.a * right.tx + left.b * right.ty + left.tx, ty: left.c * right.tx + left.d * right.ty + left.ty };
  }

  private placementTransform(shape: Shape, row: number, col: number): InstancePathTransform {
    const angle: number = ((shape.rotation ?? 0) + (shape.mirror === 2 ? 180 : 0)) * Math.PI / 180;
    const mag: number = shape.magnification ?? 1;
    const sign: number = shape.mirror === 1 || shape.mirror === 2 ? -1 : 1;
    return { a: mag * Math.cos(angle), b: -sign * mag * Math.sin(angle),
      c: mag * Math.sin(angle), d: sign * mag * Math.cos(angle),
      tx: shape.points[0].x + col * (shape.arrayColStepX ?? 0) + row * (shape.arrayRowStepX ?? 0),
      ty: shape.points[0].y + col * (shape.arrayColStepY ?? 0) + row * (shape.arrayRowStepY ?? 0) };
  }

  /** Validate IDs, member indices and fresh transforms; never trust a saved pointer's transform. */
  private resolvePath(path: InstancePathStep[], rootCell: number, base?: InstancePathTransform): InstancePathStep[] {
    if (path.length > 32) throw new Error('实例路径超过 32 层');
    let parent: number = rootCell;
    let matrix: InstancePathTransform = base ?? this.pathIdentity();
    const visited: number[] = [rootCell];
    const result: InstancePathStep[] = [];
    for (const step of path) {
      const shape: Shape | undefined = this.shapes.find((item: Shape) => item.id === step.instanceId);
      if (shape === undefined || shape.type !== ShapeType.INSTANCE || shape.points.length === 0 ||
        (shape.ownerCellId ?? this.topCellId) !== parent || step.parentCellId !== parent || shape.cellId !== step.cellId ||
        !Number.isInteger(step.row) || !Number.isInteger(step.col) || step.row < 0 || step.col < 0 ||
        step.row >= Math.max(1, shape.arrayRows ?? 1) || step.col >= Math.max(1, shape.arrayCols ?? 1)) {
        throw new Error('实例路径或阵列成员已变化，请重新选择');
      }
      if (visited.indexOf(step.cellId) >= 0) throw new Error('实例路径包含循环引用');
      matrix = this.pathMultiply(matrix, this.placementTransform(shape, step.row, step.col));
      if (![matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty].every((n: number) => Number.isFinite(n))) {
        throw new Error('实例路径变换越界');
      }
      result.push({ parentCellId: parent, cellId: step.cellId, instanceId: shape.id, row: step.row, col: step.col,
        transform: matrix });
      visited.push(step.cellId); parent = step.cellId;
    }
    return result;
  }

  getNavigationPath(): InstancePathStep[] {
    if (this.navigationPath.length !== this.currentCellStack.length - 1) return [];
    try { return this.resolvePath(this.navigationPath, this.topCellId); }
    catch (_error) { return []; }
  }

  /** Concrete path relative to the current Cell; legacy enterCell keeps working without fabricating placements. */
  enterInstancePath(path: InstancePathStep[]): boolean {
    if (path.length === 0) return false;
    try {
      const previous: InstancePathStep | undefined = this.navigationPath[this.navigationPath.length - 1];
      const next: InstancePathStep[] = this.resolvePath(path, this.getCurrentCellId(), previous?.transform);
      this.navigationPath = this.navigationPath.length === this.currentCellStack.length - 1 ? this.navigationPath.concat(next) : [];
      for (const step of next) this.currentCellStack.push(step.cellId);
      this.clearSelection(); return true;
    } catch (_error) { return false; }
  }

  /** Reopen a saved concrete path, or safely fall back to its legacy definition stack. */
  restoreNavigationPath(path: InstancePathStep[]): boolean {
    try {
      const rootCellId: number = this.currentCellStack.length > 0 ? this.currentCellStack[0] : this.topCellId;
      const next: InstancePathStep[] = this.resolvePath(path, rootCellId);
      if (next.length !== this.currentCellStack.length - 1 ||
        next.some((step: InstancePathStep, i: number) => step.cellId !== this.currentCellStack[i + 1])) return false;
      this.navigationPath = next; return true;
    } catch (_error) { this.navigationPath = []; return false; }
  }

  navigateToStackIndex(index: number): boolean {
    if (!Number.isInteger(index) || index < 0 || index >= this.currentCellStack.length) return false;
    const concrete: boolean = this.navigationPath.length === this.currentCellStack.length - 1;
    this.currentCellStack = this.currentCellStack.slice(0, index + 1);
    this.navigationPath = concrete ? this.navigationPath.slice(0, index) : [];
    this.clearSelection(); return true;
  }

  /** Counts direct reference records separately from concrete placements below a chosen root. */
  getSharedImpact(cellId: number, rootCellId: number = this.topCellId, limit: number = 1000000000000): SharedCellImpact {
    const parents: Set<number> = new Set<number>();
    let records: number = 0;
    const children: Map<number, Shape[]> = new Map<number, Shape[]>();
    for (const shape of this.shapes) {
      if (shape.type !== ShapeType.INSTANCE) continue;
      const owner: number = shape.ownerCellId ?? this.topCellId;
      const group: Shape[] = children.get(owner) ?? []; group.push(shape); children.set(owner, group);
      if (shape.cellId === cellId) { records++; parents.add(owner); }
    }
    let bounded: boolean = false; let nodes: number = 0;
    const memo: Map<number, number> = new Map<number, number>();
    const count = (id: number, ancestors: number[]): number => {
      if (ancestors.indexOf(id) >= 0) throw new Error('引用图包含循环，无法确定影响范围');
      if (id === cellId) return 1;
      const cached: number | undefined = memo.get(id); if (cached !== undefined) return cached;
      if (++nodes > 100000) throw new Error('影响范围超过计算预算');
      let total: number = 0;
      for (const shape of children.get(id) ?? []) {
        const copies: number = Math.max(1, shape.arrayRows ?? 1) * Math.max(1, shape.arrayCols ?? 1);
        const addition: number = copies * count(shape.cellId ?? -1, ancestors.concat([id]));
        if (!Number.isSafeInteger(addition) || total + addition > limit) { total = limit; bounded = true; }
        else total += addition;
      }
      memo.set(id, total); return total;
    };
    try {
      if (!Number.isInteger(cellId) || cellId < 0 || !Number.isSafeInteger(limit) || limit < 1) throw new Error('影响范围参数无效');
      return { ok: true, directReferences: records, parentCells: parents.size, placements: count(rootCellId, []),
        bounded: bounded, message: bounded ? `摆放数量至少 ${limit}，达到显示上限` : '' };
    } catch (error) { return { ok: false, directReferences: records, parentCells: parents.size, placements: 0,
      bounded: true, message: String(error) }; }
  }

  /** One-level Flatten estimate. Bytes are an estimate for geometry only, not process memory. */
  estimateFlatten(ids: number[], maxObjects: number = 100000): FlattenEstimate {
    let objects: number = 0; let references: number = 0; let bytes: number = 0;
    const unique: number[] = Array.from(new Set<number>(ids));
    try {
      for (const id of unique) {
        const instance: Shape | undefined = this.shapes.find((shape: Shape) => shape.id === id);
        if (instance === undefined || instance.type !== ShapeType.INSTANCE) throw new Error('打平目标已变化，请重新选择');
        if (!this.canEditLayer(instance.layerNumber, instance.datatype)) throw new Error('实例图层已锁定');
        const copies: number = Math.max(1, instance.arrayRows ?? 1) * Math.max(1, instance.arrayCols ?? 1);
        for (const child of this.shapes) {
          if ((child.ownerCellId ?? this.topCellId) !== instance.cellId) continue;
          if (!this.canEditLayer(child.layerNumber, child.datatype)) throw new Error('子 Cell 含锁定图层');
          objects += copies; bytes += copies * (256 + child.points.length * 16);
          if (child.type === ShapeType.INSTANCE) references += copies;
        }
        if (!Number.isSafeInteger(objects) || objects > maxObjects || !Number.isSafeInteger(bytes)) throw new Error('打平对象数超过预算，请缩小范围');
      }
      return { ok: true, removedReferences: unique.length, createdObjects: objects, remainingChildReferences: references,
        estimatedBytes: bytes, message: '仅展开一级；子实例仍保留引用。内存值为几何估算。' };
    } catch (error) { return { ok: false, removedReferences: unique.length, createdObjects: objects,
      remainingChildReferences: references, estimatedBytes: bytes, message: String(error) }; }
  }

  /** Isolate one concrete path without expanding all AREF members. Entire geometry + metadata is one history item. */
  planPathIndependent(path: InstancePathStep[], structure: EditStructureState, cloneCells: boolean = true): IndependentPathPlanResult {
    const failure = (message: string): IndependentPathPlanResult => ({ ok: false, message: message, path: [], instanceId: -1,
      clonedCells: 0, addedShapes: 0 });
    try {
      if (path.length === 0 || (!cloneCells && path.length !== 1)) return failure('请选择具体实例或阵列成员');
      if (path[0].parentCellId !== this.getCurrentCellId() && path[0].parentCellId !== structure.topCellId) return failure('请选择当前 Cell 或 Top 下的具体路径');
      if (structure.topCellId !== this.topCellId || JSON.stringify(structure.cellStack) !== JSON.stringify(this.currentCellStack)) {
        return failure('编辑上下文已变化，请重新选择');
      }
      const checked: InstancePathStep[] = this.resolvePath(path, path[0].parentCellId);
      const next: Shape[] = this.shapes.map((shape: Shape): Shape => this.cloneShape(shape));
      const after: EditStructureState = this.cloneStructure(structure);
      normalizeLayoutSemantics(after, after.cellNames.length);
      const updated: InstancePathStep[] = [];
      const remaps: IndependentPathRemap[] = [];
      let nextId: number = this.nextId;
      let owner: number = checked[0].parentCellId;
      let remap: Map<number, number> = new Map<number, number>();
      let matrix: InstancePathTransform = this.pathIdentity();
      for (const step of checked) {
        const id: number = remap.get(step.instanceId) ?? step.instanceId;
        const target: Shape | undefined = next.find((shape: Shape) => shape.id === id);
        if (target === undefined || (target.ownerCellId ?? this.topCellId) !== owner ||
          !this.canEditLayer(target.layerNumber, target.datatype)) return failure('实例不可编辑或路径已变化');
        const rows: number = Math.max(1, target.arrayRows ?? 1); const cols: number = Math.max(1, target.arrayCols ?? 1);
        const pathRemap: IndependentPathRemap = { sourceOwnerCellId: step.parentCellId, targetOwnerCellId: owner,
          sourceInstanceId: step.instanceId, pieces: [], shapeIds: [], sourceCellId: target.cellId ?? -1, targetCellId: target.cellId ?? -1 };
        let member: Shape = target;
        if (rows > 1 || cols > 1) {
          const pieces: Shape[] = [];
          const part = (r: number, c: number, height: number, width: number): void => {
            if (height <= 0 || width <= 0) return;
            const copy: Shape = this.cloneShape(target); copy.id = nextId++; copy.selected = false;
            copy.points = [{ x: target.points[0].x + c * (target.arrayColStepX ?? 0) + r * (target.arrayRowStepX ?? 0),
              y: target.points[0].y + c * (target.arrayColStepY ?? 0) + r * (target.arrayRowStepY ?? 0) }];
            copy.arrayRows = height; copy.arrayCols = width; pieces.push(copy);
            pathRemap.pieces.push({ instanceId: copy.id, row: r, col: c, rows: height, cols: width });
          };
          part(0, 0, step.row, cols); part(step.row + 1, 0, rows - step.row - 1, cols);
          part(step.row, 0, 1, step.col); part(step.row, step.col + 1, 1, cols - step.col - 1);
          member = this.cloneShape(target); member.id = nextId++; member.selected = false;
          member.points = [{ x: target.points[0].x + step.col * (target.arrayColStepX ?? 0) + step.row * (target.arrayRowStepX ?? 0),
            y: target.points[0].y + step.col * (target.arrayColStepY ?? 0) + step.row * (target.arrayRowStepY ?? 0) }];
          member.arrayCols = 0; member.arrayRows = 0; member.arrayColStepX = 0; member.arrayColStepY = 0;
          member.arrayRowStepX = 0; member.arrayRowStepY = 0;
          pathRemap.pieces.push({ instanceId: member.id, row: step.row, col: step.col, rows: 1, cols: 1 });
          const index: number = next.indexOf(target); next.splice(index, 1, ...pieces, member);
        }
        if (pathRemap.pieces.length === 0) pathRemap.pieces.push({ instanceId: member.id, row: 0, col: 0, rows: rows, cols: cols });
        let child: number = member.cellId ?? -1;
        if (child < 0 || child >= after.cellNames.length) return failure('引用 Cell 无效');
        remap = new Map<number, number>();
        if (cloneCells) {
          const sourceCell: number = child; child = after.cellNames.length;
          let name: string = `${after.cellNames[sourceCell].slice(0, 460)}_local`; let suffix: number = 1;
          while (after.cellNames.indexOf(name) >= 0) name = `${after.cellNames[sourceCell].slice(0, 450)}_local_${suffix++}`;
          after.cellNames.push(name);
          appendCellSemantics(after, sourceCell, 'path-isolation');
          for (const port of after.ports ?? []) if (port.ownerCellId === sourceCell && !this.canEditLayer(port.layerNumber, port.datatype)) return failure('路径 Cell 含锁定端口图层，未创建副本');
          const properties: LayoutPropRecord[] = after.cellProperties[sourceCell] ?? [];
          after.cellProperties.push(properties.map((p: LayoutPropRecord): LayoutPropRecord =>
            ({ attr: p.attr, name: p.name, value: p.value, dtype: p.dtype })));
          const local: Shape[] = next.filter((shape: Shape) => (shape.ownerCellId ?? this.topCellId) === sourceCell);
          for (const original of local) {
            if (!this.canEditLayer(original.layerNumber, original.datatype)) return failure('路径 Cell 含锁定图层，未创建副本');
            const copy: Shape = this.cloneShape(original); copy.id = nextId++; copy.ownerCellId = child; copy.selected = false;
            remap.set(original.id, copy.id); next.push(copy);
            pathRemap.shapeIds.push([original.id, copy.id]);
          }
          member.cellId = child; member.cellName = name;
        }
        pathRemap.targetCellId = child; remaps.push(pathRemap);
        matrix = this.pathMultiply(matrix, this.placementTransform(member, 0, 0));
        updated.push({ parentCellId: owner, cellId: child, instanceId: member.id, row: 0, col: 0, transform: matrix });
        owner = child;
      }
      if (!cloneCells && checked[0].row === 0 && checked[0].col === 0 && next.length === this.shapes.length) return failure('该实例已是单个引用');
      if (next.length > 1000000 || after.cellNames.length > 100000) return failure('独立编辑超过文档预算');
      let points: number = 0;
      for (const shape of next) { points += shape.points.length;
        if (shape.points.some((p: Point) => !Number.isFinite(p.x) || !Number.isFinite(p.y))) return failure('成员坐标越界'); }
      if (points > 4000000) return failure('独立编辑超过顶点预算');
      const invalid: string = validatePropertyHierarchy(next, this.topCellId);
      if (invalid.length > 0) return failure(invalid);
      if (cloneCells) { after.cellStack = [checked[0].parentCellId].concat(updated.map((step: InstancePathStep) => step.cellId));
        after.navigationPath = updated; }
      const added: number = next.length - this.shapes.length;
      return { ok: true, message: cloneCells ? '已创建此路径的独立定义；其他引用保留，可一次撤销' : '已提取单成员；其余阵列保留，可一次撤销',
        path: this.clonePath(updated), instanceId: updated[updated.length - 1].instanceId,
        clonedCells: cloneCells ? updated.length : 0, addedShapes: added, shapes: next, structure: after, remaps: remaps };
    } catch (error) { return failure(String(error)); }
  }

  makePathIndependent(path: InstancePathStep[], structure: EditStructureState, cloneCells: boolean = true): IndependentPathResult {
    const plan: IndependentPathPlanResult = this.planPathIndependent(path, structure, cloneCells);
    if (!plan.ok || plan.shapes === undefined || plan.structure === undefined) return plan;
    // Seal the operation's selection inside the same history transaction.
    // Extraction selects its one member; entering a local definition starts empty.
    for (const shape of plan.shapes) shape.selected = !cloneCells && shape.id === plan.instanceId;
    if (!this.applyDocumentStructure(plan.shapes, structure, plan.structure, cloneCells ? '仅改此处：隔离具体实例路径' : '提取单个阵列成员', true)) {
      return { ok: false, message: '独立编辑未应用，图层或文档已变化', path: [], instanceId: -1, clonedCells: 0, addedShapes: 0 };
    }
    return { ok: true, message: plan.message, path: plan.path, instanceId: plan.instanceId, clonedCells: plan.clonedCells, addedShapes: plan.addedShapes };
  }

  extractArrayMember(instanceId: number, row: number, col: number, structure: EditStructureState): IndependentPathResult {
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === instanceId);
    if (shape === undefined) return { ok: false, message: '实例已变化', path: [], instanceId: -1, clonedCells: 0, addedShapes: 0 };
    const step: InstancePathStep = { parentCellId: shape.ownerCellId ?? this.topCellId, cellId: shape.cellId ?? -1,
      instanceId: instanceId, row: row, col: col, transform: this.pathIdentity() };
    return this.makePathIndependent([step], structure, false);
  }

  /** 设置顶层 Cell ID（通常在加载文件后调用） */
  setTopCellId(cellId: number): void {
    this.topCellId = cellId;
    this.currentCellStack = [cellId];
    this.navigationPath = [];
  }

  /** 获取顶层 Cell ID */
  getTopCellId(): number {
    return this.topCellId;
  }

  /** 检查 fromCellId 是否通过实例引用链（直接或间接）引用了 targetCellId */
  canReachCell(fromCellId: number, targetCellId: number): boolean {
    if (!Number.isInteger(fromCellId) || !Number.isInteger(targetCellId) || fromCellId < 0 || targetCellId < 0) {
      return false;
    }
    if (fromCellId === targetCellId) return true;
    const childrenByOwner: Map<number, number[]> = new Map<number, number[]>();
    for (let i = 0; i < this.shapes.length; i++) {
      const s: Shape = this.shapes[i];
      if (s.type !== ShapeType.INSTANCE || s.cellId === undefined || s.cellId < 0) continue;
      const owner: number = s.ownerCellId ?? this.topCellId;
      let list: number[] | undefined = childrenByOwner.get(owner);
      if (list === undefined) {
        list = [];
        childrenByOwner.set(owner, list);
      }
      if (list.indexOf(s.cellId) < 0) list.push(s.cellId);
    }
    const visited: Set<number> = new Set<number>([fromCellId]);
    const queue: number[] = [fromCellId];
    for (let head = 0; head < queue.length; head++) {
      const cur: number = queue[head];
      const children: number[] | undefined = childrenByOwner.get(cur);
      if (children === undefined) continue;
      for (let k = 0; k < children.length; k++) {
        const next: number = children[k];
        if (next === targetCellId) return true;
        if (!visited.has(next)) {
          visited.add(next);
          queue.push(next);
        }
      }
    }
    return false;
  }

  /** 判断在 parentCellId 中放置 candidateChildCellId 是否会构成自身引用或祖先循环引用 */
  wouldCreateCellCycle(parentCellId: number, candidateChildCellId: number): boolean {
    if (parentCellId === candidateChildCellId) return true;
    return this.canReachCell(candidateChildCellId, parentCellId);
  }

  /** Navigate a shared definition without fabricating fake parent-child breadcrumbs across independent root cells. */
  navigateToCellDefinition(cellId: number): boolean {
    if (!Number.isInteger(cellId) || cellId < 0) return false;
    if (cellId === this.topCellId) {
      this.currentCellStack = [this.topCellId];
    } else {
      const reachableFromTop: boolean = this.canReachCell(this.topCellId, cellId);
      const index: number = this.currentCellStack.indexOf(cellId);
      const prefix: number[] = index >= 0 ? this.currentCellStack.slice(0, index + 1) : [];
      let validChain: boolean = reachableFromTop && prefix.length > 0 && prefix.length <= 256 &&
        prefix[0] === this.topCellId && new Set<number>(prefix).size === prefix.length;
      if (validChain) {
        for (let k = 0; k + 1 < prefix.length; k++) {
          if (!this.canReachCell(prefix[k], prefix[k + 1])) {
            validChain = false;
            break;
          }
        }
      }
      if (validChain) {
        this.currentCellStack = prefix;
      } else if (reachableFromTop) {
        this.currentCellStack = [this.topCellId, cellId];
      } else {
        // 尚未被 topCellId 引用的独立新 Cell（如刚新建的 PIXLARGE）直接以单层栈打开，不伪造父子面包屑
        this.currentCellStack = [cellId];
      }
    }
    // A definition list does not identify an SREF/AREF placement.
    this.navigationPath = [];
    this.clearSelection();
    return true;
  }

  /**
   * 进入子 Cell 编辑上下文（push 到栈顶）
   * @param cellId 要进入的 Cell ID
   */
  enterCell(cellId: number, step?: InstancePathStep): void {
    if (step !== undefined && !this.enterInstancePath([step])) return;
    if (step !== undefined) return;
    this.currentCellStack.push(cellId);
    // Older callers navigate definitions without identifying a placement.
    // Do not invent an instance path that could later isolate the wrong placement.
    this.navigationPath = [];
    this.clearSelection();
  }

  /** 退出到顶层 Cell：清空栈到只剩 topCellId */
  exitToTop(): void {
    this.currentCellStack = [this.topCellId];
    this.navigationPath = [];
    this.clearSelection();
  }

  /** 将当前导航栈直接重置到指定根 Cell（供独立根 Cell 视图精确恢复，不伪造父子层级） */
  resetStackToCell(cellId: number): boolean {
    if (!Number.isInteger(cellId) || cellId < 0) return false;
    this.currentCellStack = [cellId];
    this.navigationPath = [];
    this.clearSelection();
    return true;
  }

  /** 获取当前编辑上下文的 Cell ID（栈顶） */
  getCurrentCellId(): number {
    if (this.currentCellStack.length === 0) return this.topCellId;
    return this.currentCellStack[this.currentCellStack.length - 1];
  }

  /** 当前 Cell 栈深度 */
  get cellStackDepth(): number {
    return this.currentCellStack.length;
  }

  /**
   * 获取当前 Cell 导航栈的只读副本（供面包屑导航展示完整路径）。
   * 栈底为 topCellId，栈顶为当前编辑上下文。
   */
  getCurrentCellStack(): number[] {
    const copy: number[] = [];
    for (let i = 0; i < this.currentCellStack.length; i++) {
      copy.push(this.currentCellStack[i]);
    }
    return copy;
  }

  // ===== 实例放置 =====

  /**
   * 放置 Cell 实例
   * @param cellId 引用的 Cell ID
   * @param x 放置位置 X（绝对坐标，nm）
   * @param y 放置位置 Y（绝对坐标，nm）
   * @param rotation 旋转角度 0/90/180/270
   * @param mirror 镜像 0=无 1=X 轴 2=Y 轴
   * @returns 新建实例 shape 的 ID
   */
  createInstance(
    cellId: number,
    x: number,
    y: number,
    rotation: number,
    mirror: number,
    cellName?: string,
    arrayCols: number = 1,
    arrayRows: number = 1,
    arrayColStepX: number = 0,
    arrayRowStepY: number = 0
  ): number {
    this.requireEditableLayer(0, 0);
    if (!Number.isInteger(cellId) || cellId < 0 || !Number.isFinite(x) || !Number.isFinite(y) ||
      !Number.isFinite(rotation) || [0, 1, 2].indexOf(mirror) < 0 ||
      !Number.isInteger(arrayCols) || arrayCols < 1 || arrayCols > 32767 ||
      !Number.isInteger(arrayRows) || arrayRows < 1 || arrayRows > 32767 ||
      !Number.isFinite(arrayColStepX) || !Number.isFinite(arrayRowStepY)) {
      throw new Error('实例引用、坐标、变换或阵列参数无效');
    }
    if (this.shapes.length >= 1000000) throw new Error('实例放置超过基础图形预算');
    let points: number = 1;
    for (const existing of this.shapes) points += existing.points.length;
    if (points > 4000000) throw new Error('实例放置超过顶点预算');
    const shape: Shape = {
      id: this.nextId,
      type: ShapeType.INSTANCE,
      layerNumber: 0,
      datatype: 0,
      selected: false,
      points: [{ x: x, y: y }],
      ownerCellId: this.getCurrentCellId(),
      cellId: cellId,
      rotation: ((rotation % 360) + 360) % 360,
      mirror: mirror,
      magnification: 1,
    };
    if (arrayCols > 1 || arrayRows > 1) {
      shape.arrayCols = arrayCols;
      shape.arrayRows = arrayRows;
      shape.arrayColStepX = arrayColStepX;
      shape.arrayColStepY = 0;
      shape.arrayRowStepX = 0;
      shape.arrayRowStepY = arrayRowStepY;
    }
    if (cellName !== undefined && cellName.length > 0) {
      shape.cellName = cellName;
    }
    const hierarchyError: string = validatePropertyHierarchy(this.shapes.concat([shape]), this.topCellId);
    if (hierarchyError.length > 0) throw new Error(hierarchyError);
    this.nextId++;
    this.shapes.push(shape);
    this.pushUndo({ type: 'create', shapeId: shape.id, after: this.cloneShape(shape) });
    this.redoStack = [];
    return shape.id;
  }
}

/** 编辑服务单例 */
export const editService = new EditService();
