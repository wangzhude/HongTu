/**
 * 鸿图高级编辑服务
 *
 * 补齐与 KLayout 对齐的高级编辑功能：
 * - 文本标注（Text）— 在版图上放置网络名/标签
 * - 实例管理（Instance）— Cell 引用放置与层次结构
 * - 顶点编辑（Vertex Edit）— 多边形顶点增删移
 * - 变换操作（Transform）— 旋转/镜像/缩放/移动
 * - 对齐工具（Alignment）— 左/右/上/下/居中对齐
 * - 倒圆角（Corner Rounding）— 多边形顶点倒圆
 * - 搜索替换（Search & Replace）— 按图层/类型/尺寸搜索
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { Shape, ShapeType, Point, getShapeBounds, ShapeBounds, normalizePropRecords, hasKeyholeBridgeEdges } from '../models/GdsiiData';
import { editService } from './EditService';
import type { EditStructureState } from './EditService';
import { nativeHongTuService } from './NativeHongTuService';
import { HierarchyBoundsResolver } from './HierarchyExpandService';
import type { HierarchyBoundsResult } from './HierarchyExpandService';
import type { BooleanOpType } from '../../cpp/types/libhongtu/Index';
import { normalizeLayoutSemantics, appendCellSemantics } from '../models/LayoutPort';
import { cloneEditStructureModel, cloneStructured } from '../common/CloneUtils';
import { mergeBooleanSourceProperties } from './ShapePropertyService';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';

/** 文本标注对象 */
export interface TextLabel {
  id: number;
  text: string;
  x: number;
  y: number;
  layer: number;
  fontSize: number;
  rotation: number;
}

/** Cell 实例 */
export interface CellInstance {
  id: number;
  cellName: string;
  x: number;
  y: number;
  rotation: number;       // 0/90/180/270
  mirror: boolean;        // X 轴镜像
  scale: number;          // 缩放倍数
  arrayRows: number;      // 阵列行数（1=单个）
  arrayCols: number;      // 阵列列数
  arraySpacingX: number;
  arraySpacingY: number;
}

/** Cell 定义 */
export interface CellDef {
  name: string;
  shapes: Shape[];
  instances: CellInstance[];
  isTop: boolean;
  isPCell: boolean;
}

/** 变换类型 */
export enum TransformType {
  ROTATE_90 = 'rotate90',
  ROTATE_180 = 'rotate180',
  ROTATE_270 = 'rotate270',
  MIRROR_H = 'mirrorH',
  MIRROR_V = 'mirrorV',
  SCALE = 'scale',
}

/**
 * 顶点编辑结果：ok=false 时 message 为可直接展示给用户的拒绝原因（退化 / 自交 / 类型不支持）。
 * KLayout 在 C++ 层用 path_outline + is_simple 拒绝同类输入，这里在 ArkTS 侧把住同一道门。
 */
export interface VertexEditResult {
  ok: boolean;
  message: string;
}

interface GeometrySizeGroup {
  source: Shape;
  polygons: number[][];
  propertyKey: string;
}

export interface CornerRoundPreview {
  ok: boolean;
  message: string;
  shapeId: number;
  revision: number;
  radius: number;
  maxErrorNm: number;
  points: Point[];
}

/** 对齐方式 */
export enum AlignType {
  LEFT = 'left',
  RIGHT = 'right',
  TOP = 'top',
  BOTTOM = 'bottom',
  CENTER_H = 'centerH',
  CENTER_V = 'centerV',
}

/** 分布方式 */
export enum DistributeType {
  HORIZONTAL = 'horizontal',
  VERTICAL = 'vertical',
}

/** 搜索条件 */
export interface SearchCriteria {
  layer?: number;
  datatype?: number;
  ownerCellId?: number;
  selectableOnly?: boolean;
  type?: ShapeType;
  minWidth?: number;
  maxWidth?: number;
  minHeight?: number;
  maxHeight?: number;
  textPattern?: string;
}

/**
 * 高级编辑服务
 */
export class AdvancedEditService {
  private textLabels: TextLabel[] = [];
  private instances: CellInstance[] = [];
  private cells: Map<string, CellDef> = new Map();
  /** Imported definitions resolve their geometry from the canonical editor on demand. */
  private importedCellIds: Map<string, number> = new Map();
  private nextTextId = 1;
  private nextInstanceId = 1;
  private searchBoundsRevision: number = -1;
  private searchBoundsResolver: HierarchyBoundsResolver | null = null;

  // ===== 文本标注 =====

  createText(text: string, x: number, y: number, layer: number, fontSize: number = 12): TextLabel {
    const label: TextLabel = {
      id: this.nextTextId++,
      text, x, y, layer, fontSize, rotation: 0,
    };
    this.textLabels.push(label);
    return label;
  }

  getTexts(): TextLabel[] { return this.textLabels; }

  getTextsByLayer(layer: number): TextLabel[] {
    return this.textLabels.filter(t => t.layer === layer);
  }

  deleteText(id: number): boolean {
    const idx = this.textLabels.findIndex(t => t.id === id);
    if (idx >= 0) {
      this.textLabels.splice(idx, 1);
      return true;
    }
    return false;
  }

  updateText(id: number, updates: Partial<TextLabel>): boolean {
    const label = this.textLabels.find(t => t.id === id);
    if (label) {
      // ADV-5: 移除 id 字段赋值，ID 应仅在创建时分配且不可变
      if (updates.text !== undefined) label.text = updates.text;
      if (updates.x !== undefined) label.x = updates.x;
      if (updates.y !== undefined) label.y = updates.y;
      if (updates.layer !== undefined) label.layer = updates.layer;
      if (updates.fontSize !== undefined) label.fontSize = updates.fontSize;
      if (updates.rotation !== undefined) label.rotation = updates.rotation;
      return true;
    }
    return false;
  }

  // ===== Cell 实例管理 =====

  createInstance(cellName: string, x: number, y: number): CellInstance {
    const inst: CellInstance = {
      id: this.nextInstanceId++,
      cellName, x, y,
      rotation: 0, mirror: false, scale: 1,
      arrayRows: 1, arrayCols: 1,
      arraySpacingX: 0, arraySpacingY: 0,
    };
    this.instances.push(inst);
    return inst;
  }

  getInstances(): CellInstance[] { return this.instances; }

  getInstancesByCell(cellName: string): CellInstance[] {
    return this.instances.filter(i => i.cellName === cellName);
  }

  deleteInstance(id: number): boolean {
    const idx = this.instances.findIndex(i => i.id === id);
    if (idx >= 0) {
      this.instances.splice(idx, 1);
      return true;
    }
    return false;
  }

  updateInstance(id: number, updates: Partial<CellInstance>): boolean {
    const inst = this.instances.find(i => i.id === id);
    if (inst) {
      // ADV-5: 移除 id 字段赋值，ID 应仅在创建时分配且不可变
      if (updates.cellName !== undefined) inst.cellName = updates.cellName;
      if (updates.x !== undefined) inst.x = updates.x;
      if (updates.y !== undefined) inst.y = updates.y;
      if (updates.rotation !== undefined) inst.rotation = updates.rotation;
      if (updates.mirror !== undefined) inst.mirror = updates.mirror;
      if (updates.scale !== undefined) inst.scale = updates.scale;
      if (updates.arrayRows !== undefined) inst.arrayRows = updates.arrayRows;
      if (updates.arrayCols !== undefined) inst.arrayCols = updates.arrayCols;
      if (updates.arraySpacingX !== undefined) inst.arraySpacingX = updates.arraySpacingX;
      if (updates.arraySpacingY !== undefined) inst.arraySpacingY = updates.arraySpacingY;
      return true;
    }
    return false;
  }

  /** 展平实例 — 将实例替换为其 Cell 的图形 */
  flattenInstance(id: number): Shape[] {
    const inst = this.instances.find(i => i.id === id);
    if (!inst) return [];

    const cell = this.getCell(inst.cellName);
    if (!cell) return [];

    const shapes: Shape[] = [];
    for (const s of cell.shapes) {
      const transformed = this.transformShape(s, inst.x, inst.y, inst.rotation, inst.mirror, inst.scale);
      shapes.push(transformed);
    }

    this.deleteInstance(id);
    return shapes;
  }

  // ===== Cell 管理 =====

  createCell(name: string): CellDef {
    this.importedCellIds.delete(name);
    const cell: CellDef = {
      name, shapes: [], instances: [], isTop: false, isPCell: false,
    };
    this.cells.set(name, cell);
    return cell;
  }

  getCell(name: string): CellDef | undefined {
    const cell: CellDef | undefined = this.cells.get(name);
    const id: number | undefined = this.importedCellIds.get(name);
    if (cell !== undefined && id !== undefined) {
      const top: number = editService.getTopCellId();
      cell.shapes = editService.getShapes().filter((s: Shape) => (s.ownerCellId ?? top) === id);
    }
    return cell;
  }

  getAllCells(): CellDef[] {
    // One pass through canonical geometry, not one full-library scan per cell.
    const imported: Map<number, CellDef> = new Map<number, CellDef>();
    this.importedCellIds.forEach((id: number, name: string) => {
      const cell: CellDef | undefined = this.cells.get(name);
      if (cell !== undefined) { cell.shapes = []; imported.set(id, cell); }
    });
    if (imported.size > 0) {
      const top: number = editService.getTopCellId();
      for (const shape of editService.getShapes()) {
        const cell: CellDef | undefined = imported.get(shape.ownerCellId ?? top);
        if (cell !== undefined) cell.shapes.push(shape);
      }
    }
    return Array.from(this.cells.values());
  }

  /** 清空全部 Cell 定义（打开新文件前调用） */
  clearCells(): void {
    this.cells.clear();
    this.importedCellIds.clear();
  }

  /** 重命名 Cell（同步实例引用名） */
  renameCell(oldName: string, newName: string): boolean {
    const cell: CellDef | undefined = this.cells.get(oldName);
    if (cell === undefined || this.cells.has(newName)) {
      return false;
    }
    this.cells.delete(oldName);
    const importedId: number | undefined = this.importedCellIds.get(oldName);
    this.importedCellIds.delete(oldName);
    if (importedId !== undefined) this.importedCellIds.set(newName, importedId);
    cell.name = newName;
    this.cells.set(newName, cell);
    for (let i = 0; i < this.instances.length; i++) {
      if (this.instances[i].cellName === oldName) {
        this.instances[i].cellName = newName;
      }
    }
    return true;
  }

  /** 删除 Cell 定义（调用方负责保证无引用） */
  removeCellDef(name: string): boolean {
    const removedId: number | undefined = this.importedCellIds.get(name);
    this.importedCellIds.delete(name);
    // Index removes a cell by compacting the remaining owner/cell identifiers.
    if (removedId !== undefined) {
      this.importedCellIds.forEach((id: number, key: string) => {
        if (id > removedId) this.importedCellIds.set(key, id - 1);
      });
    }
    return this.cells.delete(name);
  }

  /**
   * M2：从解析结果同步 Cell 元信息；调用前先由 EditService 接管 shapes。
   * cellNames[i] 对应 cellId=i。几何在 getCell/getAllCells 时从当前编辑库取，
   * 不在导入时复制全库，避免陈旧的子 Cell 几何与额外一套顶点对象。
   */
  loadCellsFromImport(cellNames: string[], _shapes: Shape[], topCellId: number): void {
    this.cells.clear();
    this.importedCellIds.clear();
    for (let i = 0; i < cellNames.length; i++) {
      const name: string = cellNames[i].length > 0 ? cellNames[i] : `CELL_${i}`;
      const cell: CellDef = {
        name: name,
        shapes: [],
        instances: [],
        isTop: i === topCellId,
        isPCell: false,
      };
      this.cells.set(name, cell);
      this.importedCellIds.set(name, i);
    }
  }

  /** 导出用：按 cellId 顺序的名称表（与 placeableCells / ownerCellId 对齐） */
  getCellNamesInOrder(preferredOrder: string[]): string[] {
    if (preferredOrder.length > 0) {
      return preferredOrder.slice();
    }
    const names: string[] = [];
    this.cells.forEach((_cell: CellDef, name: string) => {
      names.push(name);
    });
    return names;
  }

  /** 从选中图形创建 Cell */
  makeCellFromSelection(name: string, structure: EditStructureState, layer: number = 0, datatype: number = 0): CellDef | null {
    this.lastGeometryError = '';
    name = name.trim();
    const current: number = editService.getCurrentCellId();
    const selected: Shape[] = editService.getSelectedShapes();
    let error: string = '';
    if (name.length === 0 || name.length > 512 || /[\x00-\x1f]/.test(name)) error = 'Cell 名称须为 1–512 字符且不含控制字符';
    else if (structure.cellNames.indexOf(name) >= 0) error = 'Cell 名称已存在';
    else if (structure.cellNames.length >= 100000 || editService.getShapes().length >= 1000000) error = '组成 Cell 超出文档预算';
    else if (structure.topCellId !== editService.getTopCellId() || current < 0 || current >= structure.cellNames.length ||
      structure.cellStack[structure.cellStack.length - 1] !== current) error = 'Cell 上下文已变化，请重新打开';
    else if (selected.length === 0) error = '请先选择当前 Cell 中的对象';
    else if (!Number.isInteger(layer) || layer < 0 || layer > 65535 || !Number.isInteger(datatype) || datatype < 0 || datatype > 65535 ||
      !editService.canEditLayer(layer, datatype)) error = '实例目标图层无效或已锁定';
    for (const shape of selected) {
      if ((shape.ownerCellId ?? structure.topCellId) !== current || !editService.canEditLayer(shape.layerNumber, shape.datatype)) {
        error = '选区含其它 Cell 或锁定对象，组成 Cell 已取消'; break;
      }
      if (shape.points.length === 0 || shape.points.some((point: Point): boolean => !Number.isFinite(point.x) || !Number.isFinite(point.y))) {
        error = '选区包含无效坐标'; break;
      }
      if (shape.type === ShapeType.INSTANCE && (!Number.isInteger(shape.cellId) || (shape.cellId ?? -1) < 0 ||
        (shape.cellId ?? -1) >= structure.cellNames.length || shape.cellId === current)) {
        error = '选区实例引用无效'; break;
      }
    }
    if (error.length > 0) { this.geometryFailure(error); return null; }
    const cellId: number = structure.cellNames.length;
    const after: EditStructureState = cloneEditStructureModel(structure, true) as EditStructureState;
    normalizeLayoutSemantics(after, after.cellNames.length);
    after.cellNames.push(name); after.cellProperties.push([]); appendCellSemantics(after);
    // Parent definition ports retain ownership; geometry bbox never silently
    // absorbs unrelated definitions into the newly created Cell.
    const selectedIds: Set<number> = new Set<number>(selected.map((shape: Shape): number => shape.id));
    const next: Shape[] = editService.getShapes().map((shape: Shape): Shape => {
      const copy: Shape = this.cloneShape(shape);
      if (selectedIds.has(copy.id)) { copy.ownerCellId = cellId; copy.selected = false; }
      return copy;
    });
    const instanceId: number = editService.getNextShapeId();
    next.push({ id: instanceId, type: ShapeType.INSTANCE, ownerCellId: current, cellId: cellId, cellName: name,
      layerNumber: layer, datatype: datatype, points: [{ x: 0, y: 0 }], selected: false });
    const hierarchyError: string = editService.validateShapeHierarchy(next);
    if (hierarchyError.length > 0) { this.geometryFailure(hierarchyError); return null; }
    if (!editService.applyDocumentStructure(next, structure, after, `选区组成 Cell ${name}`, true, [instanceId])) {
      this.geometryFailure('组成 Cell 未提交，图层或选区已变化'); return null;
    }
    this.loadCellsFromImport(after.cellNames, editService.getShapes(), after.topCellId);
    editService.selectShape(instanceId);
    return this.getCell(name) ?? null;
  }

  // ===== 变换操作 =====

  /** Each selected object keeps its own center; metadata and geometry transform together. */
  rotateSelection(degrees: number): boolean {
    return editService.transformShapes(editService.getSelectedIds(), 'rotate', degrees);
  }

  mirrorSelection(horizontal: boolean): boolean {
    return editService.transformShapes(editService.getSelectedIds(), horizontal ? 'mirrorX' : 'mirrorY', 0);
  }

  scaleSelection(factor: number): boolean {
    return editService.transformShapes(editService.getSelectedIds(), 'scale', factor);
  }

  // ===== 顶点编辑（gap-matrix §6）=====
  // 旧 moveVertex/insertVertex/deleteVertex 只有「改 points + 记一条 modify」，
  // 既不校验退化/自交，也没有手势语义；现统一到
  //   normalizedVertexPoints → with*（纯函数，供画布实时预览）→ commitVertexEdit（校验 + 落库）
  // 一次手势只在撤销栈上留一条记录（见 EditService 的 E-TX）。

  /** 是否可作为顶点编辑目标：多边形 / 路径 / 矩形（文本、实例不支持） */
  isVertexEditable(shape: Shape | null): boolean {
    if (shape === null) {
      return false;
    }
    if (shape.type === ShapeType.POLYGON && hasKeyholeBridgeEdges(shape.points)) {
      return false;
    }
    return shape.type === ShapeType.POLYGON || shape.type === ShapeType.PATH || shape.type === ShapeType.RECT;
  }

  /** 编辑期可见的归一化顶点：RECT 的 2 对角点展开为 4 角点（左上起顺时针） */
  normalizedVertexPoints(shape: Shape): Point[] {
    if (shape.type === ShapeType.RECT && shape.points.length === 2) {
      const minX: number = Math.min(shape.points[0].x, shape.points[1].x);
      const maxX: number = Math.max(shape.points[0].x, shape.points[1].x);
      const minY: number = Math.min(shape.points[0].y, shape.points[1].y);
      const maxY: number = Math.max(shape.points[0].y, shape.points[1].y);
      return [
        { x: minX, y: minY }, { x: maxX, y: minY },
        { x: maxX, y: maxY }, { x: minX, y: maxY },
      ];
    }
    return this.copyPoints(shape.points);
  }

  /** Internal coordinates keep file precision; export quantizes to the document DBU. */
  private denormalizeForStorage(shape: Shape, points: Point[]): Point[] {
    if (shape.type === ShapeType.RECT) {
      let minX: number = points[0].x;
      let minY: number = points[0].y;
      let maxX: number = points[0].x;
      let maxY: number = points[0].y;
      for (let i = 1; i < points.length; i++) {
        minX = Math.min(minX, points[i].x);
        minY = Math.min(minY, points[i].y);
        maxX = Math.max(maxX, points[i].x);
        maxY = Math.max(maxY, points[i].y);
      }
      return [{ x: minX, y: minY }, { x: maxX, y: maxY }];
    }
    const out: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push({ x: points[i].x, y: points[i].y });
    }
    return out;
  }

  /**
   * 拖拽后的候选顶点集（纯函数，不落库）。
   * RECT 走「对角锚定的轴对齐盒子」语义：拖动任一角点，对角固定，
   * 另外两角随之重算 —— 与 KLayout 拖矩形角点的手感一致，也不会把矩形拖成平行四边形。
   */
  withVertexMoved(shape: Shape, points: Point[], index: number, x: number, y: number): Point[] {
    if (index < 0 || index >= points.length) {
      return this.copyPoints(points);
    }
    if (shape.type === ShapeType.RECT && points.length === 4) {
      const anchor: Point = points[(index + 2) % 4];
      const minX: number = Math.min(anchor.x, x);
      const maxX: number = Math.max(anchor.x, x);
      const minY: number = Math.min(anchor.y, y);
      const maxY: number = Math.max(anchor.y, y);
      const box: Point[] = [
        { x: minX, y: minY }, { x: maxX, y: minY },
        { x: maxX, y: maxY }, { x: minX, y: maxY },
      ];
      // 槽位固定为 TL,TR,BR,BL：被拖角与对角锚点张出的轴对齐盒子即新轮廓
      return box;
    }
    const next: Point[] = this.copyPoints(points);
    next[index] = { x: x, y: y };
    return next;
  }

  /** 在边 edgeIndex（点 i → i+1，多边形回绕到 0）上插入顶点 */
  withVertexInserted(shape: Shape, points: Point[], edgeIndex: number, x: number, y: number): Point[] {
    if (edgeIndex < 0 || edgeIndex >= points.length) {
      return this.copyPoints(points);
    }
    const next: Point[] = this.copyPoints(points);
    next.splice(edgeIndex + 1, 0, { x: x, y: y });
    return next;
  }

  /**
   * 矩形四条边的单向推拉中点柄（顺序：0=底边 minY, 1=右边 maxX, 2=顶边 maxY, 3=左边 minX）
   */
  rectEdgeMidpoints(points: Point[]): Point[] {
    if (points.length !== 4) {
      return [];
    }
    const minX: number = Math.min(points[0].x, points[2].x);
    const maxX: number = Math.max(points[0].x, points[2].x);
    const minY: number = Math.min(points[0].y, points[2].y);
    const maxY: number = Math.max(points[0].y, points[2].y);
    const midX: number = (minX + maxX) * 0.5;
    const midY: number = (minY + maxY) * 0.5;
    return [
      { x: midX, y: minY },
      { x: maxX, y: midY },
      { x: midX, y: maxY },
      { x: minX, y: midY },
    ];
  }

  /**
   * 矩形单条边单轴推拉（纯函数）：拖水平边仅改高度不改宽度，拖竖直边仅改宽度不改高度
   */
  withRectEdgeMoved(points: Point[], edgeIndex: number, x: number, y: number): Point[] {
    if (points.length !== 4 || edgeIndex < 0 || edgeIndex > 3) {
      return this.copyPoints(points);
    }
    let minX: number = Math.min(points[0].x, points[2].x);
    let maxX: number = Math.max(points[0].x, points[2].x);
    let minY: number = Math.min(points[0].y, points[2].y);
    let maxY: number = Math.max(points[0].y, points[2].y);
    if (edgeIndex === 0) {
      const anchorY: number = maxY;
      minY = Math.min(y, anchorY);
      maxY = Math.max(y, anchorY);
    } else if (edgeIndex === 1) {
      const anchorX: number = minX;
      minX = Math.min(x, anchorX);
      maxX = Math.max(x, anchorX);
    } else if (edgeIndex === 2) {
      const anchorY: number = minY;
      minY = Math.min(y, anchorY);
      maxY = Math.max(y, anchorY);
    } else {
      const anchorX: number = maxX;
      minX = Math.min(x, anchorX);
      maxX = Math.max(x, anchorX);
    }
    return [
      { x: minX, y: minY },
      { x: maxX, y: minY },
      { x: maxX, y: maxY },
      { x: minX, y: maxY },
    ];
  }

  /** 各边插入柄位置：边中点（PATH 的最后一段是 n-1→n-2 之外的开放边，不闭合） */
  edgeInsertPoints(shape: Shape, points: Point[]): Point[] {
    const out: Point[] = [];
    const closed: boolean = shape.type !== ShapeType.PATH;
    const segCount: number = closed ? points.length : points.length - 1;
    for (let i = 0; i < segCount; i++) {
      const a: Point = points[i];
      const b: Point = points[(i + 1) % points.length];
      out.push({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
    }
    return out;
  }

  /** 删除顶点（纯函数，供预览；是否合法由 checkOutline 判定） */
  withVertexRemoved(points: Point[], index: number): Point[] {
    if (index < 0 || index >= points.length) {
      return this.copyPoints(points);
    }
    const next: Point[] = this.copyPoints(points);
    next.splice(index, 1);
    return next;
  }

  /**
   * 轮廓自检（KLayout 的 pathOutline/accept 语义在 ArkTS 侧的廉价等价实现）：
   * 1) 坐标必须有限；
   * 2) 去重后顶点数：闭合轮廓 ≥3、开放路径 ≥2，否则退化；
   * 3) 闭合轮廓不得自交或自touch（路径允许自交，与 KLayout 对 path 的宽容一致）。
   * 不新增 NAPI 调用：纯 2D 叉积判定，n 为个位~几十，逐帧可算。
   */
  checkOutline(shape: Shape, points: Point[]): VertexEditResult {
    for (let i = 0; i < points.length; i++) {
      if (!Number.isFinite(points[i].x) || !Number.isFinite(points[i].y)) {
        return { ok: false, message: '顶点坐标非法（NaN/Infinity），已拒绝' };
      }
    }
    // 零长度边（相邻顶点重合）：吸附把插入点落到端点上、或把顶点拖到邻居上时出现。
    // KLayout 的 outline 同样不接受，且它会让自交判定退化误判，故先单独拒绝。
    const closedLoop: boolean = shape.type !== ShapeType.PATH;
    for (let i = 0; i < points.length; i++) {
      const j: number = (i + 1) % points.length;
      if (!closedLoop && j === 0) {
        break; // 开放路径无回绕边
      }
      if (points[i].x === points[j].x && points[i].y === points[j].y) {
        return { ok: false, message: '存在重合顶点（零长度边），已拒绝' };
      }
    }
    const distinct: number = this.countDistinct(points);
    const isOpen: boolean = shape.type === ShapeType.PATH;
    if (isOpen && distinct < 2) {
      return { ok: false, message: '路径至少需要 2 个不同顶点，已拒绝' };
    }
    if (!isOpen && distinct < 3) {
      return { ok: false, message: '多边形至少需要 3 个不同顶点，已拒绝' };
    }
    if (shape.type === ShapeType.RECT) {
      // 矩形角点重合即零面积（distinct 只要求 ≥3，这里补严格判定）
      if (distinct < 4) {
        return { ok: false, message: '矩形面积为零（角点重合），已拒绝' };
      }
      return { ok: true, message: '' };
    }
    if (isOpen) {
      return { ok: true, message: '' };
    }
    // Translation must not change validity. World-coordinate products cancel
    // the nm/sub-nm area of small polygons far from the layout origin.
    const origin: Point = points[0];
    let twiceArea: number = 0;
    let compensation: number = 0;
    for (let i = 0; i < points.length; i++) {
      const a: Point = points[i];
      const b: Point = points[(i + 1) % points.length];
      const term: number = (a.x - origin.x) * (b.y - origin.y) - (b.x - origin.x) * (a.y - origin.y);
      const adjusted: number = term - compensation;
      const sum: number = twiceArea + adjusted;
      compensation = (sum - twiceArea) - adjusted;
      twiceArea = sum;
    }
    if (!Number.isFinite(twiceArea) || Math.abs(twiceArea) < 1e-12) {
      return { ok: false, message: '多边形面积为零或越界，请调整顶点' };
    }
    if (!this.isSimpleClosed(points)) {
      return { ok: false, message: '轮廓自交（边相交），KLayout 同样拒绝，已回退' };
    }
    return { ok: true, message: '' };
  }

  /** 连续重复（含首尾回绕）顶点去重后的数量 */
  private countDistinct(points: Point[]): number {
    let n: number = 0;
    let prev: Point | null = null;
    for (let i = 0; i < points.length; i++) {
      if (prev === null || Math.abs(points[i].x - prev.x) > 1e-6 || Math.abs(points[i].y - prev.y) > 1e-6) {
        n++;
        prev = points[i];
      }
    }
    // 首尾同点（闭合重复）算一个
    if (n > 1 && prev !== null && points.length > 1 &&
      Math.abs(points[0].x - prev.x) <= 1e-6 && Math.abs(points[0].y - prev.y) <= 1e-6) {
      n--;
    }
    return n;
  }

  /** 闭合折线是否为简单多边形（无自交 / 无自 touch） */
  private isSimpleClosed(points: Point[]): boolean {
    const n: number = points.length;
    if (n < 4) {
      return true; // 三角形不可能自交
    }
    for (let i = 0; i < n; i++) {
      const a1: Point = points[i];
      const a2: Point = points[(i + 1) % n];
      for (let j = i + 1; j < n; j++) {
        // 相邻边共享端点，首尾边同理，属正常闭合而非自交
        if (j === i + 1 || (i === 0 && j === n - 1)) {
          continue;
        }
        if (this.segmentsTouch(a1, a2, points[j], points[(j + 1) % n])) {
          return false;
        }
      }
    }
    return true;
  }

  /** 两线段是否相交（含 Proper 穿越、端点落在他段上、共线重叠） */
  private segmentsTouch(a: Point, b: Point, c: Point, d: Point): boolean {
    const o1: number = this.orient(a, b, c);
    const o2: number = this.orient(a, b, d);
    const o3: number = this.orient(c, d, a);
    const o4: number = this.orient(c, d, b);
    if (o1 === 0 && this.onSegment(a, c, b)) return true;
    if (o2 === 0 && this.onSegment(a, d, b)) return true;
    if (o3 === 0 && this.onSegment(c, a, d)) return true;
    if (o4 === 0 && this.onSegment(c, b, d)) return true;
    return (o1 > 0) !== (o2 > 0) && (o3 > 0) !== (o4 > 0);
  }

  /** 2D 叉积符号（>0 左拐 / <0 右拐 / 0 共线） */
  private orient(a: Point, b: Point, c: Point): number {
    const v: number = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);
    if (Math.abs(v) < 1e-9) {
      return 0;
    }
    return v > 0 ? 1 : -1;
  }

  /** p 是否落在共线的线段 a-b 内 */
  private onSegment(a: Point, p: Point, b: Point): boolean {
    return p.x >= Math.min(a.x, b.x) - 1e-9 && p.x <= Math.max(a.x, b.x) + 1e-9 &&
      p.y >= Math.min(a.y, b.y) - 1e-9 && p.y <= Math.max(a.y, b.y) + 1e-9;
  }

  /**
   * 提交一次顶点编辑：先自检，通过才落库。
   * 落库走 editService.updateShapePoints ⇒ 一次手势 = 一条撤销记录（含手势起点的完整 before 快照）。
   */
  commitVertexEdit(shapeId: number, candidate: Point[]): VertexEditResult {
    const shape: Shape | undefined = editService.getShapes().find((s: Shape) => s.id === shapeId);
    if (shape === undefined) {
      return { ok: false, message: '图形已不存在，顶点编辑取消' };
    }
    if (!this.isVertexEditable(shape)) {
      return { ok: false, message: '仅多边形 / 路径 / 矩形支持顶点编辑' };
    }
    if (shape.type === ShapeType.RECT && candidate.length !== 4) {
      return { ok: false, message: '矩形固定 4 角：插入/删除顶点请先改用多边形' };
    }
    const check: VertexEditResult = this.checkOutline(shape, candidate);
    if (!check.ok) {
      return check;
    }
    const stored: Point[] = this.denormalizeForStorage(shape, candidate);
    const ok: boolean = editService.updateShapePoints(shapeId, stored);
    return { ok: ok, message: ok ? '' : '顶点更新失败' };
  }

  /** 获取可编辑图形的顶点（归一化后：矩形为 4 角点） */
  getVertices(shapeId: number): Point[] | null {
    const shape: Shape | undefined = editService.getShapes().find(s => s.id === shapeId);
    if (shape === undefined || !this.isVertexEditable(shape)) return null;
    return this.normalizedVertexPoints(shape);
  }

  /** 移动顶点（程序化入口：AI / 宏；带退化与自交校验） */
  moveVertex(shapeId: number, vertexIndex: number, x: number, y: number): boolean {
    const shape: Shape | undefined = editService.getShapes().find(s => s.id === shapeId);
    if (shape === undefined || !this.isVertexEditable(shape)) return false;
    const pts: Point[] = this.normalizedVertexPoints(shape);
    if (vertexIndex < 0 || vertexIndex >= pts.length) return false;
    return this.commitVertexEdit(shapeId, this.withVertexMoved(shape, pts, vertexIndex, x, y)).ok;
  }

  /** 在 afterIndex 之后插入顶点（afterIndex = -1 表示首点之前） */
  insertVertex(shapeId: number, afterIndex: number, x: number, y: number): boolean {
    const shape: Shape | undefined = editService.getShapes().find(s => s.id === shapeId);
    if (shape === undefined || !this.isVertexEditable(shape)) return false;
    const pts: Point[] = this.normalizedVertexPoints(shape);
    const edgeIndex: number = afterIndex + 1 >= pts.length ? (shape.type === ShapeType.PATH ? pts.length - 1 : 0) : afterIndex;
    if (edgeIndex < 0) return false;
    return this.commitVertexEdit(shapeId, this.withVertexInserted(shape, pts, edgeIndex, x, y)).ok;
  }

  /** 删除顶点（退化 / 自交结果会被拒绝，故「至少 3 点」由 checkOutline 统一把关） */
  deleteVertex(shapeId: number, vertexIndex: number): boolean {
    const shape: Shape | undefined = editService.getShapes().find(s => s.id === shapeId);
    if (shape === undefined || !this.isVertexEditable(shape)) return false;
    const pts: Point[] = this.normalizedVertexPoints(shape);
    if (vertexIndex < 0 || vertexIndex >= pts.length) return false;
    return this.commitVertexEdit(shapeId, this.withVertexRemoved(pts, vertexIndex)).ok;
  }

  // ===== 对齐工具 =====

  /** 对齐多个选中图形 */
  alignSelection(type: AlignType, hierarchyDepth: number = 32): boolean {
    this.lastGeometryError = '';
    const selected: Shape[] = editService.getSelectedShapes();
    if (selected.length < 2 || selected.some((s: Shape) => s.points.length === 0)) return false;
    const bounds: ShapeBounds[] | null = this.selectionGeometryBounds(selected, hierarchyDepth);
    if (bounds === null) return false;
    let target: number = 0;
    switch (type) {
      case AlignType.LEFT: target = bounds.reduce((v: number, b: ShapeBounds): number => Math.min(v, b.minX), Infinity); break;
      case AlignType.RIGHT: target = bounds.reduce((v: number, b: ShapeBounds): number => Math.max(v, b.maxX), -Infinity); break;
      case AlignType.TOP: target = bounds.reduce((v: number, b: ShapeBounds): number => Math.max(v, b.maxY), -Infinity); break;
      case AlignType.BOTTOM: target = bounds.reduce((v: number, b: ShapeBounds): number => Math.min(v, b.minY), Infinity); break;
      case AlignType.CENTER_H: target = bounds.reduce((sum: number, b: ShapeBounds): number => sum + (b.minX / 2 + b.maxX / 2) / bounds.length, 0); break;
      case AlignType.CENTER_V: target = bounds.reduce((sum: number, b: ShapeBounds): number => sum + (b.minY / 2 + b.maxY / 2) / bounds.length, 0); break;
      default: return false;
    }
    const shifts: Point[] = [];
    for (let i = 0; i < selected.length; i++) {
      const b: ShapeBounds = bounds[i];
      let dx: number = 0;
      let dy: number = 0;
      if (type === AlignType.LEFT) dx = target - b.minX;
      else if (type === AlignType.RIGHT) dx = target - b.maxX;
      else if (type === AlignType.TOP) dy = target - b.maxY;
      else if (type === AlignType.BOTTOM) dy = target - b.minY;
      else if (type === AlignType.CENTER_H) dx = target - (b.minX / 2 + b.maxX / 2);
      else dy = target - (b.minY / 2 + b.maxY / 2);
      // Subtraction after a previous move may differ by a few floating-point ulps.
      if (Math.abs(dx) <= Number.EPSILON * Math.max(1, Math.abs(target), Math.abs(b.minX), Math.abs(b.maxX)) * 4) dx = 0;
      if (Math.abs(dy) <= Number.EPSILON * Math.max(1, Math.abs(target), Math.abs(b.minY), Math.abs(b.maxY)) * 4) dy = 0;
      if (!editService.canEditLayer(selected[i].layerNumber, selected[i].datatype)) return false;
      for (const p of selected[i].points) if (!Number.isFinite(p.x + dx) || !Number.isFinite(p.y + dy)) return false;
      shifts.push({ x: dx, y: dy });
    }
    editService.beginBatch();
    try {
      for (let i = 0; i < selected.length; i++) editService.moveShape(selected[i].id, shifts[i].x, shifts[i].y);
    } finally {
      editService.endBatch();
    }
    return true;
  }

  /** 分布选中图形 — 按中心点均匀分布，首尾固定，中间图形均匀排列 */
  distributeSelection(type: DistributeType, hierarchyDepth: number = 32): boolean {
    this.lastGeometryError = '';
    // H-4: 过滤空 points 图形，避免中心坐标计算产生 NaN
    const selShapes = editService.getSelectedShapes().filter(s => s.points.length > 0);
    // 至少 3 个图形才执行分布
    if (selShapes.length < 3) return false;
    if (type !== DistributeType.HORIZONTAL && type !== DistributeType.VERTICAL) return false;
    const bounds: ShapeBounds[] | null = this.selectionGeometryBounds(selShapes, hierarchyDepth);
    if (bounds === null) return false;

    // 计算每个图形的中心坐标（HORIZONTAL 用 x，VERTICAL 用 y）
    const centers: number[] = [];
    for (let i = 0; i < selShapes.length; i++) {
      const c: number = type === DistributeType.HORIZONTAL
        ? bounds[i].minX / 2 + bounds[i].maxX / 2
        : bounds[i].minY / 2 + bounds[i].maxY / 2;
      centers.push(c);
    }

    // 按中心坐标排序，得到从首到尾的顺序索引
    const order: number[] = [];
    for (let i = 0; i < selShapes.length; i++) {
      order.push(i);
    }
    order.sort((a, b) => centers[a] - centers[b]);

    const n = selShapes.length;
    const startCenter = centers[order[0]];
    const endCenter = centers[order[n - 1]];

    // Prepare all movements before committing any object.
    const shifts: Point[] = [];
    for (let i = 1; i < n - 1; i++) {
      const idx = order[i];
      const target = startCenter * (1 - i / (n - 1)) + endCenter * i / (n - 1);
      let delta: number = target - centers[idx];
      if (Math.abs(delta) <= Number.EPSILON * Math.max(1, Math.abs(target), Math.abs(centers[idx])) * 4) delta = 0;
      const dx = type === DistributeType.HORIZONTAL ? delta : 0;
      const dy = type === DistributeType.VERTICAL ? delta : 0;
      if (!editService.canEditLayer(selShapes[idx].layerNumber, selShapes[idx].datatype)) return false;
      for (const p of selShapes[idx].points) {
        if (!Number.isFinite(p.x + dx) || !Number.isFinite(p.y + dy)) return this.geometryFailure('分布后坐标越界，原图已保留');
      }
      shifts.push({ x: dx, y: dy });
    }
    editService.beginBatch();
    try {
      for (let i = 1; i < n - 1; i++) editService.moveShape(selShapes[order[i]].id, shifts[i - 1].x, shifts[i - 1].y);
    } finally { editService.endBatch(); }
    return true;
  }

  private selectionGeometryBounds(selected: Shape[], depth: number): ShapeBounds[] | null {
    const resolver: HierarchyBoundsResolver = new HierarchyBoundsResolver(editService.getShapes(), editService.getTopCellId(),
      (layer: number, datatype: number): boolean => editService.isLayerVisible(layer, datatype));
    const bounds: ShapeBounds[] = [];
    for (const shape of selected) {
      const result: HierarchyBoundsResult = resolver.boundsForShape(shape, depth);
      if (!result.ok || result.bounds === undefined) {
        this.lastGeometryError = result.message.length > 0 ? result.message : `对象 #${shape.id} 在当前层级没有可见几何，请提高层级或显示对应图层`;
        return null;
      }
      bounds.push(result.bounds);
    }
    return bounds;
  }

  // ===== 倒圆角 =====

  /** Tangent circular fillets; no radius clamping or integer-nm truncation. */
  prepareRoundedCorners(shapeId: number, radius: number, maxErrorNm: number = 0): CornerRoundPreview {
    const preview: CornerRoundPreview = { ok: false, message: '', shapeId: shapeId, revision: editService.getSessionRevision(),
      radius: radius, maxErrorNm: maxErrorNm, points: [] };
    const shape: Shape | undefined = editService.getShapes().find((s: Shape): boolean => s.id === shapeId);
    if (!Number.isFinite(radius) || radius <= 0 || !Number.isFinite(maxErrorNm) || maxErrorNm < 0) {
      preview.message = '半径须为正有限数，弦高偏差须为非负有限数'; return preview;
    }
    if (shape === undefined || (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON) ||
      !editService.isShapeInCurrentCell(shape) || !editService.canEditLayer(shape.layerNumber, shape.datatype)) {
      preview.message = '请选择当前 Cell 中未锁定的矩形或多边形'; return preview;
    }
    const points: Point[] = this.normalizedVertexPoints(shape);
    if (points.length > 3 && points[0].x === points[points.length - 1].x && points[0].y === points[points.length - 1].y) points.pop();
    if (points.length > 2048) { preview.message = '倒圆角预览最多支持 2048 个输入顶点'; return preview; }
    const outline: Shape = this.cloneShape(shape); outline.type = ShapeType.POLYGON;
    const valid: VertexEditResult = this.checkOutline(outline, points);
    if (!valid.ok) { preview.message = valid.message; return preview; }
    const distances: number[] = [];
    const angles: number[] = [];
    for (let i = 0; i < points.length; i++) {
      const prev: Point = points[(i - 1 + points.length) % points.length];
      const curr: Point = points[i]; const next: Point = points[(i + 1) % points.length];
      const len1: number = Math.hypot(prev.x - curr.x, prev.y - curr.y);
      const len2: number = Math.hypot(next.x - curr.x, next.y - curr.y);
      const dot: number = ((prev.x - curr.x) * (next.x - curr.x) + (prev.y - curr.y) * (next.y - curr.y)) / (len1 * len2);
      const angle: number = Math.acos(Math.max(-1, Math.min(1, dot)));
      if (angle < 1e-7) { preview.message = '存在尖刺或折返边，请先修复轮廓'; return preview; }
      angles.push(angle);
      distances.push(Math.PI - angle < 1e-7 ? 0 : radius / Math.tan(angle / 2));
    }
    for (let i = 0; i < points.length; i++) {
      const next: number = (i + 1) % points.length;
      const length: number = Math.hypot(points[next].x - points[i].x, points[next].y - points[i].y);
      if (distances[i] + distances[next] > length + Math.max(1, length) * 1e-10) {
        preview.message = '半径过大，相邻圆角会重叠；请减小半径'; return preview;
      }
    }
    preview.maxErrorNm = maxErrorNm === 0 ? radius / 100 : maxErrorNm;
    const maxStep: number = Math.min(Math.PI / 2, 2 * Math.acos(Math.max(-1, 1 - Math.min(radius, preview.maxErrorNm) / radius)));
    if (!Number.isFinite(maxStep) || maxStep <= 0) { preview.message = '偏差过小，超出浮点分辨率'; return preview; }
    for (let i = 0; i < points.length; i++) {
      const prev: Point = points[(i - 1 + points.length) % points.length];
      const curr: Point = points[i]; const next: Point = points[(i + 1) % points.length];
      if (distances[i] === 0) { preview.points.push({ x: curr.x, y: curr.y }); continue; }
      const len1: number = Math.hypot(prev.x - curr.x, prev.y - curr.y);
      const len2: number = Math.hypot(next.x - curr.x, next.y - curr.y);
      const ax: number = (prev.x - curr.x) / len1; const ay: number = (prev.y - curr.y) / len1;
      const bx: number = (next.x - curr.x) / len2; const by: number = (next.y - curr.y) / len2;
      const bisector: number = Math.hypot(ax + bx, ay + by);
      const distance: number = radius / Math.sin(angles[i] / 2);
      const cx: number = curr.x + (ax + bx) / bisector * distance;
      const cy: number = curr.y + (ay + by) / bisector * distance;
      const start: number = Math.atan2(curr.y + ay * distances[i] - cy, curr.x + ax * distances[i] - cx);
      const turn: number = (curr.x - prev.x) * (next.y - curr.y) - (curr.y - prev.y) * (next.x - curr.x);
      const sweep: number = (turn > 0 ? 1 : -1) * (Math.PI - angles[i]);
      const steps: number = Math.max(1, Math.ceil(Math.abs(sweep) / maxStep));
      if (preview.points.length + steps + 1 > 2048) { preview.message = '偏差要求超出 2048 顶点预算，请增大偏差'; preview.points = []; return preview; }
      for (let j = 0; j <= steps; j++) {
        const angle: number = start + sweep * j / steps;
        const p: Point = { x: cx + radius * Math.cos(angle), y: cy + radius * Math.sin(angle) };
        const last: Point | undefined = preview.points[preview.points.length - 1];
        if (last === undefined || Math.hypot(last.x - p.x, last.y - p.y) > Math.max(1, radius) * 1e-12) preview.points.push(p);
      }
    }
    if (preview.points.length > 1 && Math.hypot(preview.points[0].x - preview.points[preview.points.length - 1].x,
      preview.points[0].y - preview.points[preview.points.length - 1].y) <= Math.max(1, radius) * 1e-12) preview.points.pop();
    const outputCheck: VertexEditResult = this.checkOutline(outline, preview.points);
    preview.ok = outputCheck.ok; preview.message = outputCheck.message;
    if (!preview.ok) preview.points = [];
    return preview;
  }

  applyRoundedCorners(preview: CornerRoundPreview): boolean {
    this.lastGeometryError = '';
    if (!preview.ok || preview.revision !== editService.getSessionRevision()) return this.geometryFailure('倒圆角预览已过期或无效，请重新预览');
    // Recompute rather than trusting mutable preview geometry supplied by a caller.
    const checked: CornerRoundPreview = this.prepareRoundedCorners(preview.shapeId, preview.radius, preview.maxErrorNm);
    if (!checked.ok) return this.geometryFailure(checked.message);
    if (!editService.updatePolygonOutline(preview.shapeId, checked.points)) return this.geometryFailure('倒圆角提交失败，原图已保留');
    return true;
  }

  roundCorners(shapeId: number, radius: number, maxErrorNm: number = 0): boolean {
    const preview: CornerRoundPreview = this.prepareRoundedCorners(shapeId, radius, maxErrorNm);
    if (!preview.ok) return this.geometryFailure(preview.message);
    return this.applyRoundedCorners(preview);
  }

  // ===== 搜索替换 =====

  searchShapes(criteria: SearchCriteria): Shape[] {
    this.beginSearchBoundsRequest();
    let results = editService.getShapes();

    if (criteria.ownerCellId !== undefined) {
      results = results.filter((s: Shape) => (s.ownerCellId ?? editService.getTopCellId()) === criteria.ownerCellId);
    }
    if (criteria.datatype !== undefined) results = results.filter((s: Shape) => s.datatype === criteria.datatype);
    if (criteria.selectableOnly) {
      results = results.filter((s: Shape) => s.type !== ShapeType.NODE && editService.canSelectLayer(s.layerNumber, s.datatype));
    }

    if (criteria.layer !== undefined) {
      results = results.filter(s => s.layerNumber === criteria.layer);
    }
    if (criteria.type !== undefined) {
      results = results.filter(s => s.type === criteria.type);
    }
    if (criteria.minWidth !== undefined) {
      results = results.filter(s => {
        const w = this.getShapeWidth(s);
        return w >= criteria.minWidth!;
      });
    }
    if (criteria.maxWidth !== undefined) {
      results = results.filter(s => {
        const w = this.getShapeWidth(s);
        return w <= criteria.maxWidth!;
      });
    }
    if (criteria.minHeight !== undefined) {
      results = results.filter(s => {
        const h = this.getShapeHeight(s);
        return h >= criteria.minHeight!;
      });
    }
    if (criteria.maxHeight !== undefined) {
      results = results.filter(s => {
        const h = this.getShapeHeight(s);
        return h <= criteria.maxHeight!;
      });
    }
    if (this.lastGeometryError.length > 0) return [];
    // ADV-3: textPattern 过滤——对 TEXT 类型图形的 text 字段做子串匹配（大小写不敏感）
    if (criteria.textPattern !== undefined && criteria.textPattern.length > 0) {
      const pattern: string = criteria.textPattern.toLowerCase();
      results = results.filter((s: Shape) => {
        if (s.text === undefined) return false;
        return s.text.toLowerCase().includes(pattern);
      });
    }

    return results;
  }

  /** 替换搜索结果的图层 */
  replaceLayer(shapes: Shape[], newLayer: number): number {
    const ids: number[] = [];
    for (const s of shapes) {
      ids.push(s.id);
    }
    const result = editService.changeLayer(ids, newLayer);
    this.lastGeometryError = result.message;
    return result.ok ? result.changed : 0;
  }

  // ===== 辅助方法 =====

  private copyPoints(points: Point[]): Point[] {
    const copied: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      copied.push({ x: points[i].x, y: points[i].y });
    }
    return copied;
  }

  private getShapeCenterX(shape: Shape): number {
    // H-4: 空 points 防护，避免 Math.min(...[]) 返回 Infinity
    if (shape.points.length === 0) return 0;
    const xs = shape.points.map(p => p.x);
    return (Math.min(...xs) + Math.max(...xs)) / 2;
  }

  private getShapeCenterY(shape: Shape): number {
    if (shape.points.length === 0) return 0;
    const ys = shape.points.map(p => p.y);
    return (Math.min(...ys) + Math.max(...ys)) / 2;
  }

  /** Search dimensions include PATH padding and complete instance geometry,
   * independent of display depth and hidden descendant layers. */
  getSearchShapeBounds(shape: Shape): ShapeBounds | undefined {
    this.beginSearchBoundsRequest();
    return this.resolveSearchShapeBounds(shape);
  }

  private beginSearchBoundsRequest(): void {
    this.lastGeometryError = '';
    if (this.searchBoundsResolver !== null) this.searchBoundsResolver.beginCompleteBoundsRequest();
  }

  private resolveSearchShapeBounds(shape: Shape): ShapeBounds | undefined {
    if (shape.type !== ShapeType.INSTANCE) return getShapeBounds(shape);
    const revision: number = editService.getSessionRevision();
    if (this.searchBoundsResolver === null || this.searchBoundsRevision !== revision) {
      this.searchBoundsResolver = new HierarchyBoundsResolver(editService.getShapes(), editService.getTopCellId(),
        (_layer: number, _datatype: number): boolean => true);
      this.searchBoundsRevision = revision;
    }
    const result: HierarchyBoundsResult = this.searchBoundsResolver.completeBoundsForShape(shape);
    if (!result.ok) this.lastGeometryError = result.message;
    return result.ok ? result.bounds : undefined;
  }

  private getShapeWidth(shape: Shape): number {
    const bounds: ShapeBounds | undefined = this.resolveSearchShapeBounds(shape);
    return bounds === undefined ? Number.NaN : bounds.maxX - bounds.minX;
  }

  private getShapeHeight(shape: Shape): number {
    const bounds: ShapeBounds | undefined = this.resolveSearchShapeBounds(shape);
    return bounds === undefined ? Number.NaN : bounds.maxY - bounds.minY;
  }

  private transformShape(shape: Shape, dx: number, dy: number, rotation: number, mirror: boolean, scale: number): Shape {
    let points = shape.points.map((p): Point => {
      const np: Point = { x: p.x * scale, y: p.y * scale };
      return np;
    });

    if (mirror) {
      points = points.map((p): Point => {
        const np: Point = { x: -p.x, y: p.y };
        return np;
      });
    }

    if (rotation !== 0) {
      const rad = rotation * Math.PI / 180;
      const cos = Math.cos(rad);
      const sin = Math.sin(rad);
      points = points.map((p): Point => {
        const np: Point = {
          x: Math.round(p.x * cos - p.y * sin),
          y: Math.round(p.x * sin + p.y * cos),
        };
        return np;
      });
    }

    points = points.map((p): Point => {
      const np: Point = { x: p.x + dx, y: p.y + dy };
      return np;
    });

    const result: Shape = this.cloneShape(shape);
    result.id = 0; // 新 ID 由 EditService 分配
    result.points = points;
    // ADV-1: 缩放 PATH 类型的 pathWidth，与 scaleSelection 保持一致
    if (result.pathWidth !== undefined && scale !== 1) {
      result.pathWidth = result.pathWidth * scale;
      if (result.pathBeginExtension !== undefined) result.pathBeginExtension *= scale;
      if (result.pathEndExtension !== undefined) result.pathEndExtension *= scale;
    }
    return result;
  }

  /** 克隆图形（深拷贝，避免 spread 操作符） */
  private cloneShape(s: Shape): Shape {
    const pts: Point[] = [];
    for (let i = 0; i < s.points.length; i++) {
      pts.push({ x: s.points[i].x, y: s.points[i].y });
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
    // 端型随线宽一同保留（与 EditService.cloneShape 对齐）：阵列/复制/缩放路径
    // 若丢掉它，round/extended 的 PATH 一被复制就塌成 flush
    if (s.pathType !== undefined) {
      copy.pathType = s.pathType;
    }
    // ADV-2: INSTANCE / TEXT 类型额外字段，与 EditService.cloneShape 对齐
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
    // 属性随克隆走：布尔/打平/阵列复制都经此重建图元，漏掉即等于保存时丢属性
    if (s.properties !== undefined) {
      const cloned = normalizePropRecords(s.properties);
      if (cloned !== undefined) {
        copy.properties = cloned;
      }
    }
    return copy;
  }

  // === Phase 3: KLayout 对齐编辑能力 ===

  /**
   * 阵列复制（KLayout: Edit > Array）
   * 将选中图形按 rows×cols 阵列复制，间距 pitchX/pitchY (nm)。
   * 返回新创建的图形数量。
   */
  arraySelection(rows: number, cols: number, pitchX: number, pitchY: number): number {
    if (!Number.isInteger(rows) || !Number.isInteger(cols) || !Number.isFinite(pitchX) || !Number.isFinite(pitchY)) return 0;
    const selectedIds: number[] = editService.getSelectedIds();
    if (selectedIds.length === 0 || rows < 1 || cols < 1) {
      return 0;
    }
    if (rows === 1 && cols === 1) {
      return 0; // 1x1 无意义
    }
    const shapes: Shape[] = editService.getCurrentCellShapes();
    const selected: Shape[] = [];
    for (let i = 0; i < shapes.length; i++) {
      if (selectedIds.indexOf(shapes[i].id) >= 0) {
        selected.push(shapes[i]);
      }
    }
    if (selected.length === 0) {
      return 0;
    }
    const count: number = (rows * cols - 1) * selected.length;
    if (!Number.isSafeInteger(count) || count + editService.getShapes().length > 1000000) return 0;
    let pointsPerCopy: number = 0;
    for (const shape of selected) pointsPerCopy += shape.points.length;
    if (pointsPerCopy * (rows * cols - 1) > 4000000) return 0;
    // createShape 返回 Shape，不能用空值表达拒绝；在事务前锁住全部目标图层。
    for (let i = 0; i < selected.length; i++) {
      if (!editService.canEditLayer(selected[i].layerNumber, selected[i].datatype)) return 0;
    }

    const templates: Shape[] = [];
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          if (r === 0 && c === 0) continue; // 跳过原始位置
          const dx: number = c * pitchX;
          const dy: number = r * pitchY;
          for (let s = 0; s < selected.length; s++) {
            const copy: Shape = this.cloneShape(selected[s]);
            if (!editService.canEditLayer(copy.layerNumber, copy.datatype)) continue;
            copy.id = 0;
            copy.selected = false;
            const newPts: Point[] = [];
            for (let p = 0; p < copy.points.length; p++) {
              newPts.push({ x: copy.points[p].x + dx, y: copy.points[p].y + dy });
            }
            copy.points = newPts;
            templates.push(copy);
          }
        }
      }
    return editService.createShapeCopies(templates, true).length;
  }

  private lastGeometryError: string = '';

  getLastGeometryError(): string {
    return this.lastGeometryError;
  }

  private geometryFailure(message: string): boolean {
    this.lastGeometryError = message;
    return false;
  }

  /** Reject unsupported/malformed input before any mutation or DBU rounding. */
  private validateGeometrySelection(selected: Shape[]): boolean {
    for (const shape of selected) {
      if (shape.type !== ShapeType.RECT && shape.type !== ShapeType.POLYGON) {
        return this.geometryFailure('仅支持矩形和多边形，请移除其它类型的选择');
      }
      if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) {
        return this.geometryFailure('选中图形所在图层已锁定或不可编辑');
      }
      const flat: number[] = this.shapeToFlatPolygon(shape);
      if (flat.length < 6) return this.geometryFailure('图形缺少有效顶点，原图已保留');
      for (const value of flat) {
        if (!Number.isFinite(value) || !Number.isInteger(value) || Math.abs(value) > 1e14) {
          return this.geometryFailure('几何编辑要求整数 nm 坐标；亚 nm 或越界输入已保留');
        }
      }
    }
    return true;
  }

  /** Prepare all output shapes before deleting any originals. */
  private appendGeometryShapes(
    source: Shape,
    polygons: number[][],
    outputs: Shape[],
    mergedProperties?: LayoutPropRecord[]
  ): boolean {
    const effectiveProps: LayoutPropRecord[] | undefined = mergedProperties !== undefined
      ? normalizePropRecords(mergedProperties)
      : normalizePropRecords(source.properties);
    for (const flat of polygons) {
      if (!Array.isArray(flat) || flat.length < 6 || flat.length % 2 !== 0) {
        return this.geometryFailure('几何结果不完整，原图已保留');
      }
      const pts: Point[] = [];
      for (let i = 0; i < flat.length; i += 2) {
        if (!Number.isSafeInteger(flat[i]) || !Number.isSafeInteger(flat[i + 1])) {
          return this.geometryFailure('几何结果超出整数坐标范围，原图已保留');
        }
        pts.push({ x: flat[i], y: flat[i + 1] });
      }
      outputs.push({
        id: 0, type: ShapeType.POLYGON, layerNumber: source.layerNumber,
        datatype: source.datatype, ownerCellId: source.ownerCellId, points: pts, selected: false,
        properties: normalizePropRecords(effectiveProps)
      });
    }
    return true;
  }

  private replaceGeometry(selected: Shape[], outputs: Shape[], label: string = '几何替换'): boolean {
    const replaced: Shape[] | null = editService.replaceShapesWithHistory(
      selected.map((shape: Shape): number => shape.id),
      outputs,
      label,
      true
    );
    if (replaced === null) {
      return this.geometryFailure('结果超过图形/顶点预算或目标图层已锁定，原图已保留');
    }
    return true;
  }

  /** True geometric miter offset in integer nm; empty erosion removes the source. */
  sizeSelection(offset: number, structure: EditStructureState): boolean {
    this.lastGeometryError = '';
    if (structure === undefined) return this.geometryFailure('尺寸调整未执行：文档上下文不可用');
    const selected: Shape[] = editService.getSelectedShapes();
    if (selected.length === 0) return this.geometryFailure('请先选中矩形或多边形');
    if (!Number.isFinite(offset) || offset === 0) return this.geometryFailure('偏移量必须是有限的非零数');
    if (!this.validateGeometrySelection(selected)) return false;
    const outputs: Shape[] = [];
    const groups: GeometrySizeGroup[] = [];
    for (const shape of selected) {
      const propertyKey: string = JSON.stringify(normalizePropRecords(shape.properties) ?? []);
      let group: GeometrySizeGroup | undefined = groups.find((candidate: GeometrySizeGroup) =>
        candidate.source.layerNumber === shape.layerNumber && candidate.source.datatype === shape.datatype &&
        candidate.source.ownerCellId === shape.ownerCellId && candidate.propertyKey === propertyKey);
      if (group === undefined) {
        group = { source: shape, polygons: [], propertyKey: propertyKey };
        groups.push(group);
      }
      group.polygons.push(this.shapeToFlatPolygon(shape));
    }
    for (const group of groups) {
      const result = nativeHongTuService.offsetPolygonsForEdit(group.polygons, offset, 0);
      if (!result.success) return this.geometryFailure('尺寸调整失败，原图已保留：' + result.errorMessage);
      if (!this.appendGeometryShapes(group.source, result.polygons, outputs)) return false;
    }
    const sourceIds: Set<number> = new Set<number>(selected.map((shape: Shape): number => shape.id));
    const nextShapes: Shape[] = editService.getShapes().filter((shape: Shape): boolean => !sourceIds.has(shape.id));
    const createdIds: number[] = [];
    let nextId: number = editService.getNextShapeId();
    for (const output of outputs) {
      const shape: Shape = this.cloneShape(output);
      shape.id = nextId++;
      shape.ownerCellId = editService.getCurrentCellId();
      nextShapes.push(shape);
      createdIds.push(shape.id);
    }
    if (!editService.applyDocumentStructure(nextShapes, structure, structure, '尺寸调整', true, createdIds)) {
      return this.geometryFailure('尺寸调整未执行：图层已锁定或图形无效，原图已保留');
    }
    return true;
  }

  /** RECT（2点对角/4点）或 POLYGON 转扁平多边形坐标 [x0,y0,x1,y1,...] */
  private shapeToFlatPolygon(s: Shape): number[] {
    const flat: number[] = [];
    if (s.type === ShapeType.RECT) {
      const b: ShapeBounds = getShapeBounds(s);
      flat.push(b.minX, b.minY, b.maxX, b.minY, b.maxX, b.maxY, b.minX, b.maxY);
      return flat;
    }
    if (s.type === ShapeType.POLYGON && s.points.length >= 3) {
      let count: number = s.points.length;
      // 去掉与首点重合的闭合点
      if (count > 3 && s.points[0].x === s.points[count - 1].x && s.points[0].y === s.points[count - 1].y) {
        count--;
      }
      for (let i = 0; i < count; i++) {
        flat.push(s.points[i].x, s.points[i].y);
      }
    }
    return flat;
  }

  /** Boolean results are hole-free filled pieces verified by the native kernel. */
  booleanOperation(op: 'merge' | 'subtract' | 'intersect' | 'xor'): boolean {
    this.lastGeometryError = '';
    const selected: Shape[] = editService.getSelectedShapes();
    if (selected.length !== 2) return this.geometryFailure('需恰好选中 2 个矩形或多边形');
    if (!this.validateGeometrySelection(selected)) return false;
    const subjectShape: Shape = selected[0];
    const clipShape: Shape = selected[1];
    const opType: BooleanOpType = op === 'intersect' ? 0 : op === 'merge' ? 1 : op === 'subtract' ? 2 : 3;
    const result = nativeHongTuService.booleanOpForEdit(this.shapeToFlatPolygon(subjectShape),
      this.shapeToFlatPolygon(clipShape), opType);
    if (!result.success) return this.geometryFailure('布尔运算失败，原图已保留：' + result.errorMessage);
    const mergedProps: LayoutPropRecord[] | undefined = mergeBooleanSourceProperties(subjectShape.properties, clipShape.properties);
    const outputs: Shape[] = [];
    if (!this.appendGeometryShapes(subjectShape, result.polygons, outputs, mergedProps)) return false;
    return this.replaceGeometry(selected, outputs, `布尔运算 (${op})`);
  }
}

/** 高级编辑服务单例 */
export const advEditService = new AdvancedEditService();
