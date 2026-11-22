/**
 * 鸿图 GDSII 数据模型
 *
 * 将 NAPI 解析结果转换为 UI 可用的数据结构。
 * 定义图形元素（矩形/多边形/路径）、单元、版图文档等模型。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { UiLayer, LayerGroup } from '../common/types';
import { LAYER_NAME_MAP, getDefaultLayerColor } from '../common/constants';
import type { GdsiiResult, LayerInfo, NativeShape, LayoutPropRecord, SourceLayerDefinition } from '../../cpp/types/libhongtu/Index';
import { normalizeLayoutSemantics } from './LayoutPort';
import type { LayoutSemanticState } from './LayoutPort';
import { cloneStructured, markImmutablePointArray, isImmutablePointArray, markFiniteValidatedPointArray } from '../common/CloneUtils';

/** 图形元素类型 */
export enum ShapeType {
  RECT = 'rect',
  POLYGON = 'polygon',
  PATH = 'path',
  TEXT = 'text',
  /** Cell 实例引用 */
  INSTANCE = 'instance',
  /** GDSII NODE: datatype is NODETYPE; points retain the net coordinate sequence */
  NODE = 'node',
}

/** 坐标点（用户单位 nm） */
export interface Point {
  x: number;
  y: number;
}

/** 版图图形元素 */
export interface Shape {
  /** 唯一 ID */
  id: number;
  /** 图形类型 */
  type: ShapeType;
  /** 图层号 */
  layerNumber: number;
  /** 数据类型 */
  datatype: number;
  /** 顶点坐标列表（用户单位 nm） */
  points: Point[];
  /** 路径宽度（仅 PATH 类型，nm） */
  pathWidth?: number;
  /**
   * PATH 端型（GDSII PATHTYPE）：0=flush、1=round、2=extended。
   * 必须随图形活过「打开→编辑→保存」：丢了它，round/extended 端会塌成 flush，
   * 两端各短 pathWidth/2，且画布/DRC 用的轮廓与磁盘文件不再一致。
   */
  pathType?: number;
  textPresentation?: number;
  /** GDSII PATHTYPE=4 signed end extensions, in nm. */
  pathBeginExtension?: number;
  pathEndExtension?: number;
  /** Negative GDS WIDTH: magnification of an instance does not scale its width. */
  pathWidthAbsolute?: boolean;
  /** Compressed AREF dimensions; omitted/zero means SREF. Steps are in parent coordinates. */
  arrayCols?: number;
  arrayRows?: number;
  arrayColStepX?: number;
  arrayColStepY?: number;
  arrayRowStepX?: number;
  arrayRowStepY?: number;
  /** 是否被选中 */
  selected: boolean;
  /** 引用的 Cell ID（仅 INSTANCE 类型） */
  cellId?: number;
  /** 旋转角度 0/90/180/270（仅 INSTANCE 类型） */
  rotation?: number;
  /** 镜像 0=无 1=X 轴 2=Y 轴（仅 INSTANCE 类型） */
  mirror?: number;
  /** GDSII MAG magnification for INSTANCE shapes */
  magnification?: number;
  /** 文本内容（仅 TEXT 类型） */
  text?: string;
  /** Referenced cell name for INSTANCE shapes */
  cellName?: string;
  /** Cell that owns this shape in the imported hierarchy */
  ownerCellId?: number;
  /**
   * 元素级属性（GDSII PROPATTR/PROPVALUE、OASIS PROPERTY）。
   * 编辑/撤销/保存必须原样携带：这是「打开→改一个矩形→保存不丢属性」的唯一通路。
   * 无属性的图形该字段为 undefined（不分配、不写出任何属性记录）。
   */
  properties?: LayoutPropRecord[];
}

/** 单元模型 */
export interface CellModel {
  name: string;
  elementCount: number;
  shapes: Shape[];
  layers: LayerInfo[];
  /** 结构级属性；无属性时为 undefined */
  properties?: LayoutPropRecord[];
}

/** 版图文档模型 */
export interface LayoutDocument extends LayoutSemanticState {
  layerDefinitions?: SourceLayerDefinition[];
  filePath: string;
  fileName: string;
  fileSize: number;
  libName: string;
  version: number;
  cells: CellModel[];
  topCellIds: number[];
  primaryTopCellId: number;
  allLayers: LayerInfo[];
  shapes: Shape[];
  totalElements: number;
  userUnits: number;
  physicalUnits: number;
  unitDescription: string;
  /** 库/数据库级属性；无属性时为 undefined。保存须原样带回，否则库级属性丢失。 */
  libProperties?: LayoutPropRecord[];
}

/**
 * 每个归属者（图元 / 结构 / 库）跨 UI 边界的属性条数上限。
 * 与 native 侧 gdsii_reader 的 kMaxPropsPerOwner、NAPI 的 kMaxPropsPerOwnerWire 同值，
 * 三层同口径才能保证「打开→编辑→保存」不出现某一层静默截断而另一层不截。
 */
export const MAX_PROPS_PER_OWNER: number = 64;

/**
 * 归一化跨边界的属性数组：只保留四字段类型正确的条目，条数钳制到 MAX_PROPS_PER_OWNER。
 * 返回 undefined = 无有效属性（调用方据此**省略字段**，写出端也就不产生任何属性记录）。
 * 畸形条目逐条忽略而非抛错，与 native reader 的敌意输入策略一致。
 */
export function normalizePropRecords(raw: LayoutPropRecord[] | undefined): LayoutPropRecord[] | undefined {
  if (raw === undefined || raw === null) {
    return undefined;
  }
  const out: LayoutPropRecord[] = [];
  for (let i = 0; i < raw.length && out.length < MAX_PROPS_PER_OWNER; i++) {
    const rec: LayoutPropRecord = raw[i];
    if (rec === null || rec === undefined) {
      continue;
    }
    if (typeof rec.attr !== 'number' || typeof rec.dtype !== 'number' ||
      typeof rec.name !== 'string' || typeof rec.value !== 'string') {
      continue;
    }
    out.push({ attr: rec.attr, dtype: rec.dtype, name: rec.name, value: rec.value });
  }
  return out.length > 0 ? out : undefined;
}

/**
 * 将 NAPI LayerInfo 转换为 UiLayer（带中文名、颜色、分组）
 */
function nativeShapeType(type: string): ShapeType {
  if (type === ShapeType.POLYGON) {
    return ShapeType.POLYGON;
  }
  if (type === ShapeType.PATH) {
    return ShapeType.PATH;
  }
  if (type === ShapeType.TEXT) {
    return ShapeType.TEXT;
  }
  if (type === ShapeType.INSTANCE) {
    return ShapeType.INSTANCE;
  }
  if (type === ShapeType.NODE) {
    return ShapeType.NODE;
  }
  return ShapeType.RECT;
}

export interface PackedShapesWireBuffers {
  packedCoords?: Float64Array;
  shapePointOffsets?: Int32Array;
  shapePointCounts?: Int32Array;
  totalPoints: number;
}

/**
 * 将大版图 Shape[] 坐标紧凑打包为连续 Float64Array（>thresholdPoints 时启用），
 * 消除向 C++ NAPI 同步文档、渲染快照或启动后台 DRC 时创建数百万 JS 数组/对象导致的卡顿与堆膨胀。
 */
export function packShapesCoordinates(shapes: Shape[], thresholdPoints: number = 8192): PackedShapesWireBuffers {
  let totalPoints: number = 0;
  for (let i = 0; i < shapes.length; i++) {
    totalPoints += shapes[i].points.length;
  }
  if (totalPoints <= thresholdPoints || shapes.length > 2147483647 || totalPoints > 2147483647) {
    return { totalPoints: totalPoints };
  }
  const packedCoords: Float64Array = new Float64Array(totalPoints * 2);
  const shapePointOffsets: Int32Array = new Int32Array(shapes.length);
  const shapePointCounts: Int32Array = new Int32Array(shapes.length);
  let cursor: number = 0;
  for (let i = 0; i < shapes.length; i++) {
    const pts: Point[] = shapes[i].points;
    const len: number = pts.length;
    shapePointOffsets[i] = cursor;
    shapePointCounts[i] = len;
    let base: number = cursor * 2;
    for (let j = 0; j < len; j++) {
      const p: Point = pts[j];
      packedCoords[base] = p.x;
      packedCoords[base + 1] = p.y;
      base += 2;
    }
    cursor += len;
  }
  return {
    packedCoords: packedCoords,
    shapePointOffsets: shapePointOffsets,
    shapePointCounts: shapePointCounts,
    totalPoints: totalPoints,
  };
}

function convertSingleNativeShape(
  native: NativeShape,
  index: number,
  fallbackId: number,
  packedCoords?: Float64Array,
  shapePointOffsets?: Int32Array,
  shapePointCounts?: Int32Array
): Shape | null {
  let points: Point[];
  if (
    packedCoords !== undefined &&
    shapePointOffsets !== undefined &&
    shapePointCounts !== undefined &&
    index < shapePointOffsets.length &&
    index < shapePointCounts.length
  ) {
    const ptCount: number = shapePointCounts[index];
    if (ptCount <= 0) {
      return null;
    }
    const ptOffset: number = shapePointOffsets[index];
    points = new Array<Point>(ptCount);
    let base: number = ptOffset * 2;
    let pMinX: number = Infinity;
    let pMinY: number = Infinity;
    let pMaxX: number = -Infinity;
    let pMaxY: number = -Infinity;
    let allFinite: boolean = true;
    for (let j = 0; j < ptCount; j++) {
      const px: number = packedCoords[base];
      const py: number = packedCoords[base + 1];
      if (Number.isFinite(px) && Number.isFinite(py)) {
        if (px < pMinX) pMinX = px;
        if (py < pMinY) pMinY = py;
        if (px > pMaxX) pMaxX = px;
        if (py > pMaxY) pMaxY = py;
      } else {
        allFinite = false;
      }
      points[j] = { x: px, y: py };
      base += 2;
    }
    markImmutablePointArray(points);
    if (allFinite) {
      markFiniteValidatedPointArray(points);
      cacheImmutablePointsBounds(points, { minX: pMinX, minY: pMinY, maxX: pMaxX, maxY: pMaxY });
    }
  } else {
    if (native.points === undefined || native.points.length === 0) {
      return null;
    }
    const ptCount: number = native.points.length;
    points = new Array<Point>(ptCount);
    let pMinX: number = Infinity;
    let pMinY: number = Infinity;
    let pMaxX: number = -Infinity;
    let pMaxY: number = -Infinity;
    let allFinite: boolean = true;
    for (let j = 0; j < ptCount; j++) {
      const px: number = native.points[j].x;
      const py: number = native.points[j].y;
      if (Number.isFinite(px) && Number.isFinite(py)) {
        if (px < pMinX) pMinX = px;
        if (py < pMinY) pMinY = py;
        if (px > pMaxX) pMaxX = px;
        if (py > pMaxY) pMaxY = py;
      } else {
        allFinite = false;
      }
      points[j] = { x: px, y: py };
    }
    markImmutablePointArray(points);
    if (allFinite) {
      markFiniteValidatedPointArray(points);
      cacheImmutablePointsBounds(points, { minX: pMinX, minY: pMinY, maxX: pMaxX, maxY: pMaxY });
    }
  }

  const type: ShapeType = nativeShapeType(native.type);
  const shape: Shape = {
    id: native.id > 0 ? native.id : fallbackId,
    type: type,
    layerNumber: native.layerNumber,
    datatype: native.datatype,
    points: points,
    selected: false,
  };
  if (native.ownerCellId >= 0) {
    shape.ownerCellId = native.ownerCellId;
  }
  if (type === ShapeType.PATH) {
    shape.pathWidth = native.pathWidth >= 0 ? native.pathWidth : 1;
    shape.pathBeginExtension = native.pathBeginExtension;
    shape.pathEndExtension = native.pathEndExtension;
    shape.pathWidthAbsolute = native.pathWidthAbsolute;
    if (native.pathType !== undefined && native.pathType > 0) {
      shape.pathType = native.pathType;
    }
  }
  if (type === ShapeType.TEXT) {
    shape.text = native.text;
    shape.textPresentation = native.textPresentation;
    shape.rotation = native.rotation;
    shape.mirror = native.mirror;
    shape.magnification = native.magnification > 0 ? native.magnification : 1;
  }
  if (type === ShapeType.INSTANCE) {
    if (native.cellId >= 0) {
      shape.cellId = native.cellId;
    }
    shape.cellName = native.cellName;
    shape.rotation = native.rotation;
    shape.mirror = native.mirror;
    shape.magnification = native.magnification > 0 ? native.magnification : 1;
    shape.arrayCols = native.arrayCols;
    shape.arrayRows = native.arrayRows;
    shape.arrayColStepX = native.arrayColStepX;
    shape.arrayColStepY = native.arrayColStepY;
    shape.arrayRowStepX = native.arrayRowStepX;
    shape.arrayRowStepY = native.arrayRowStepY;
  }
  const props: LayoutPropRecord[] | undefined = normalizePropRecords(native.properties);
  if (props !== undefined) {
    shape.properties = props;
  }
  return shape;
}

export function releaseParsedGeometryBuffers(result: GdsiiResult): void {
  result.packedCoords = undefined;
  result.shapePointOffsets = undefined;
  result.shapePointCounts = undefined;
  result.shapes = [];
}

export function nativeShapesToShapes(
  nativeShapes: NativeShape[] | undefined,
  packedCoords?: Float64Array,
  shapePointOffsets?: Int32Array,
  shapePointCounts?: Int32Array
): Shape[] {
  const shapes: Shape[] = [];
  if (nativeShapes === undefined) {
    return shapes;
  }
  for (let i = 0; i < nativeShapes.length; i++) {
    const converted: Shape | null = convertSingleNativeShape(
      nativeShapes[i],
      i,
      shapes.length + 1,
      packedCoords,
      shapePointOffsets,
      shapePointCounts
    );
    if (converted !== null) {
      shapes.push(converted);
    }
  }
  return shapes;
}

/**
 * 异步分片水合大版图解析结果：
 * 每处理 ~2,048 个图元或 ~160,000 个顶点主动归还一次 UI 事件循环（避免 >200 万点触发 THREAD_BLOCK_6S），
 * 并在水合完成后立即释放 NAPI 二进制传输缓冲与临时壳数组，将导入峰值内存减半。
 */
export async function nativeResultToShapesAsync(
  result: GdsiiResult,
  releaseWireBuffers: boolean = true,
  canContinue?: () => boolean
): Promise<Shape[]> {
  const nativeShapes: NativeShape[] | undefined = result.shapes;
  if (nativeShapes === undefined || nativeShapes.length === 0) {
    if (releaseWireBuffers) {
      releaseParsedGeometryBuffers(result);
    }
    return [];
  }
  const packedCoords: Float64Array | undefined = result.packedCoords;
  const shapePointOffsets: Int32Array | undefined = result.shapePointOffsets;
  const shapePointCounts: Int32Array | undefined = result.shapePointCounts;
  const shapes: Shape[] = [];
  let sliceShapes: number = 0;
  let slicePoints: number = 0;

  for (let i = 0; i < nativeShapes.length; i++) {
    if (canContinue !== undefined && (i & 255) === 0 && !canContinue()) {
      throw new Error('导入请求已取消或过期');
    }
    const converted: Shape | null = convertSingleNativeShape(
      nativeShapes[i],
      i,
      shapes.length + 1,
      packedCoords,
      shapePointOffsets,
      shapePointCounts
    );
    if (converted !== null) {
      shapes.push(converted);
      slicePoints += converted.points.length;
    }
    // 立即断开已消费的 NAPI 包装对象引用，便于年轻代 GC 即时回收
    if (releaseWireBuffers) {
      (nativeShapes as Array<NativeShape | undefined>)[i] = undefined;
    }
    sliceShapes++;
    if (sliceShapes >= 2048 || slicePoints >= 160000) {
      sliceShapes = 0;
      slicePoints = 0;
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 0);
      });
    }
  }
  if (releaseWireBuffers) {
    releaseParsedGeometryBuffers(result);
  }
  return shapes;
}

export function layerInfoToUiLayer(info: LayerInfo): UiLayer {
  const mapped = LAYER_NAME_MAP.get(info.layerNumber);
  return {
    layerNumber: info.layerNumber,
    datatype: info.datatype,
    sourceName: info.sourceName,
    chineseName: mapped?.chinese ?? `图层${info.layerNumber}`,
    englishName: mapped?.english ?? `L${info.layerNumber}`,
    color: mapped?.color ?? getDefaultLayerColor(info.layerNumber),
    visible: true,
    elementCount: info.elementCount,
    group: mapped?.group ?? LayerGroup.OTHER,
  };
}

/**
 * 将 NAPI GdsiiResult 转换为 LayoutDocument
 */
export function parseResultToDocument(result: GdsiiResult): LayoutDocument {
  const parsedShapes: Shape[] = nativeShapesToShapes(result.shapes, result.packedCoords, result.shapePointOffsets, result.shapePointCounts);
  const cells: CellModel[] = result.cells.map((cell): CellModel => {
    const model: CellModel = {
      name: cell.name,
      elementCount: cell.elementCount,
      shapes: [],
      layers: cell.layers,
    };
    const cellProps: LayoutPropRecord[] | undefined = normalizePropRecords(cell.properties);
    if (cellProps !== undefined) {
      model.properties = cellProps;
    }
    return model;
  });
  for (let i = 0; i < parsedShapes.length; i++) {
    const shape = parsedShapes[i];
    const ownerCellId = shape.ownerCellId ?? 0;
    if (ownerCellId >= 0 && ownerCellId < cells.length) {
      cells[ownerCellId].shapes.push(shape);
    }
  }

  // 从文件路径提取文件名
  const pathParts = result.filePath.split('/');
  const fileName = pathParts[pathParts.length - 1] || result.filePath;

  const doc: LayoutDocument = {
    cellKeys: result.cellKeys?.slice(), ports: result.ports === undefined ? undefined : cloneStructured(result.ports),
    crossSections: result.crossSections === undefined ? undefined : cloneStructured(result.crossSections),
    layoutContextRecords: result.layoutContextRecords === undefined ? undefined : cloneStructured(result.layoutContextRecords),
    cellContextRecords: result.cellContextRecords === undefined ? undefined : cloneStructured(result.cellContextRecords),
    filePath: result.filePath,
    fileName: fileName,
    fileSize: result.fileSize,
    libName: result.libName,
    version: result.version,
    cells: cells,
    topCellIds: result.topCellIds,
    primaryTopCellId: result.primaryTopCellId,
    allLayers: result.allLayers,
    layerDefinitions: result.layerDefinitions,
    shapes: parsedShapes,
    totalElements: result.totalElements,
    userUnits: result.userUnits,
    physicalUnits: result.physicalUnits,
    unitDescription: result.unitDescription,
  };
  // 库级属性：无属性时省略字段（与 native 输出口径一致，也让旧文档保持旧形状）
  const libProps: LayoutPropRecord[] | undefined = normalizePropRecords(result.libProperties);
  if (libProps !== undefined) {
    doc.libProperties = libProps;
  }
  normalizeLayoutSemantics(doc, cells.length);
  return doc;
}

/** 生成示例图形（无实际文件时用于演示） */
export function createDemoShapes(): Shape[] {
  let nextId = 1;
  const shapes: Shape[] = [];

  // 金属1 矩形
  shapes.push({
    id: nextId++, type: ShapeType.RECT, layerNumber: 1, datatype: 0, selected: false,
    points: [{ x: 100, y: 100 }, { x: 260, y: 200 }],
  });
  shapes.push({
    id: nextId++, type: ShapeType.RECT, layerNumber: 1, datatype: 0, selected: false,
    points: [{ x: 300, y: 100 }, { x: 520, y: 200 }],
  });

  // 多晶硅矩形
  shapes.push({
    id: nextId++, type: ShapeType.RECT, layerNumber: 4, datatype: 0, selected: false,
    points: [{ x: 180, y: 100 }, { x: 300, y: 200 }],
  });

  // 有源区矩形
  shapes.push({
    id: nextId++, type: ShapeType.RECT, layerNumber: 5, datatype: 0, selected: false,
    points: [{ x: 100, y: 220 }, { x: 400, y: 280 }],
  });

  // 金属2 矩形
  shapes.push({
    id: nextId++, type: ShapeType.RECT, layerNumber: 2, datatype: 0, selected: false,
    points: [{ x: 350, y: 100 }, { x: 550, y: 280 }],
  });

  // 通孔1 路径
  shapes.push({
    id: nextId++, type: ShapeType.PATH, layerNumber: 10, datatype: 0, selected: false,
    pathWidth: 8,
    points: [{ x: 260, y: 150 }, { x: 350, y: 150 }],
  });
  shapes.push({
    id: nextId++, type: ShapeType.PATH, layerNumber: 10, datatype: 0, selected: false,
    pathWidth: 8,
    points: [{ x: 260, y: 250 }, { x: 350, y: 250 }],
  });

  // 多晶硅多边形（L形）
  shapes.push({
    id: nextId++, type: ShapeType.POLYGON, layerNumber: 4, datatype: 0, selected: false,
    points: [
      { x: 100, y: 300 }, { x: 200, y: 300 }, { x: 200, y: 350 },
      { x: 280, y: 350 }, { x: 280, y: 420 }, { x: 100, y: 420 },
    ],
  });

  return shapes;
}

/** 图形边界框 */
export interface ShapeBounds {
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
}

const _immutablePointBoundsCache: WeakMap<Point[], ShapeBounds> = new WeakMap<Point[], ShapeBounds>();

/** 预存不可变点集的原始点包围盒（供 GDS/OASIS 解包时零额外遍历写入） */
export function cacheImmutablePointsBounds(points: Point[], bounds: ShapeBounds): void {
  if (points.length > 0) {
    _immutablePointBoundsCache.set(points, bounds);
  }
}

/**
 * 判定闭合多边形顶点序列是否含反向重合的 Keyhole 桥接切缝边（u -> v 与 v -> u）。
 * 普通简单多边形在 O(n) 重复顶点快速筛查阶段直接返回 false。
 */
export function hasKeyholeBridgeEdges(points: Point[]): boolean {
  const n: number = points.length;
  if (n < 8) return false;
  const seenVerts: Set<string> = new Set<string>();
  let hasDup: boolean = false;
  for (let i = 0; i < n; i++) {
    const k: string = `${points[i].x},${points[i].y}`;
    if (seenVerts.has(k)) {
      hasDup = true;
      break;
    }
    seenVerts.add(k);
  }
  if (!hasDup) return false;
  const forwardEdges: Set<string> = new Set<string>();
  for (let i = 0; i < n; i++) {
    const a: Point = points[i];
    const b: Point = points[(i + 1) % n];
    if (a.x === b.x && a.y === b.y) continue;
    const revKey: string = `${b.x},${b.y}>${a.x},${a.y}`;
    if (forwardEdges.has(revKey)) return true;
    forwardEdges.add(`${a.x},${a.y}>${b.x},${b.y}`);
  }
  return false;
}

/**
 * 标记闭合多边形中成对抵消的反向重合 Keyhole 桥接边下标（跳过后仅保留真实外环与内孔轮廓边）。
 */
export function markKeyholeBridgeEdgeFlags(points: Point[]): boolean[] {
  const n: number = points.length;
  const skip: boolean[] = new Array<boolean>(n).fill(false);
  if (n < 8) return skip;
  const firstByDir: Map<string, number[]> = new Map<string, number[]>();
  for (let i = 0; i < n; i++) {
    const a: Point = points[i];
    const b: Point = points[(i + 1) % n];
    if (a.x === b.x && a.y === b.y) {
      skip[i] = true;
      continue;
    }
    const revKey: string = `${b.x},${b.y}>${a.x},${a.y}`;
    const revList: number[] | undefined = firstByDir.get(revKey);
    if (revList !== undefined && revList.length > 0) {
      const partner: number = revList.pop()!;
      skip[partner] = true;
      skip[i] = true;
    } else {
      const fwdKey: string = `${a.x},${a.y}>${b.x},${b.y}`;
      const list: number[] | undefined = firstByDir.get(fwdKey);
      if (list !== undefined) list.push(i);
      else firstByDir.set(fwdKey, [i]);
    }
  }
  return skip;
}

/**
 * 将含 Keyhole 切缝桥接的单个多边形还原为互不相交的独立闭合轮廓环（外轮廓 CCW + 各内孔 CW），
 * 用于 ArkUI Path / 预览 Canvas 无接缝描边与填充。
 */
export function extractKeyholeCleanLoops(points: Point[]): Point[][] {
  const n: number = points.length;
  if (n < 3) return [];
  const skip: boolean[] = markKeyholeBridgeEdgeFlags(points);
  let anySkipped: boolean = false;
  for (let i = 0; i < n; i++) {
    if (skip[i]) { anySkipped = true; break; }
  }
  if (!anySkipped) return [points];

  const edgeUsed: boolean[] = skip.slice();
  const adj: Map<string, number[]> = new Map<string, number[]>();
  for (let i = 0; i < n; i++) {
    if (edgeUsed[i]) continue;
    const key: string = `${points[i].x},${points[i].y}`;
    const list: number[] | undefined = adj.get(key);
    if (list !== undefined) list.push(i);
    else adj.set(key, [i]);
  }
  const loops: Point[][] = [];
  for (let start = 0; start < n; start++) {
    if (edgeUsed[start]) continue;
    const loop: Point[] = [];
    const startKey: string = `${points[start].x},${points[start].y}`;
    let cur: number = start;
    while (!edgeUsed[cur]) {
      edgeUsed[cur] = true;
      loop.push(points[cur]);
      const nextVert: Point = points[(cur + 1) % n];
      const nextKey: string = `${nextVert.x},${nextVert.y}`;
      if (nextKey === startKey) break;
      const candidates: number[] | undefined = adj.get(nextKey);
      if (candidates === undefined) break;
      let nextEdge: number = -1;
      for (let c = 0; c < candidates.length; c++) {
        if (!edgeUsed[candidates[c]]) {
          nextEdge = candidates[c];
          break;
        }
      }
      if (nextEdge < 0) break;
      cur = nextEdge;
    }
    if (loop.length >= 3) loops.push(loop);
  }
  return loops.length > 0 ? loops : [points];
}

/** 计算图形的边界框（对不可变点集采用 WeakMap O(1) 缓存，消除百万顶点全图适配主线程阻塞） */
export function getShapeBounds(shape: Shape): ShapeBounds {
  const pts: Point[] = shape.points;
  const len: number = pts.length;
  if (len === 0) {
    return { minX: 0, minY: 0, maxX: 0, maxY: 0 };
  }
  let minX: number = Infinity;
  let minY: number = Infinity;
  let maxX: number = -Infinity;
  let maxY: number = -Infinity;
  const immutable: boolean = isImmutablePointArray(pts);
  const cached: ShapeBounds | undefined = immutable ? _immutablePointBoundsCache.get(pts) : undefined;
  if (cached !== undefined) {
    minX = cached.minX;
    minY = cached.minY;
    maxX = cached.maxX;
    maxY = cached.maxY;
  } else {
    for (let i = 0; i < len; i++) {
      const p: Point = pts[i];
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    if (immutable) {
      _immutablePointBoundsCache.set(pts, { minX: minX, minY: minY, maxX: maxX, maxY: maxY });
    }
  }
  // G1.5-FIX: PATH 中心线顶点算 bounds 需向外扩展 pathWidth/2，否则框选/DRC 间距判定偏小
  if (shape.type === ShapeType.PATH) {
    const half = (shape.pathWidth ?? 0) / 2 + ((shape.pathType ?? 0) === 4 ?
      Math.max(Math.abs(shape.pathBeginExtension ?? 0), Math.abs(shape.pathEndExtension ?? 0)) : 0);
    minX -= half; maxX += half; minY -= half; maxY += half;
  }
  return { minX: minX, minY: minY, maxX: maxX, maxY: maxY };
}

/** 计算图形面积（nm²） */
export function getShapeArea(shape: Shape): number {
  if (shape.type === ShapeType.RECT && shape.points.length >= 2) {
    // G1.6-FIX: 用 getShapeBounds 求宽高，兼容 2 点对角线 / 4 点矩形两种存储
    const b = getShapeBounds(shape);
    const w = b.maxX - b.minX;
    const h = b.maxY - b.minY;
    return Math.round(w * h);
  }
  if (shape.type === ShapeType.POLYGON && shape.points.length >= 3) {
    // Shoelace 公式
    let area = 0;
    const pts = shape.points;
    for (let i = 0; i < pts.length; i++) {
      const j = (i + 1) % pts.length;
      area += pts[i].x * pts[j].y;
      area -= pts[j].x * pts[i].y;
    }
    return Math.round(Math.abs(area) / 2);
  }
  if (shape.type === ShapeType.PATH && shape.points.length >= 2) {
    let length = 0;
    for (let i = 1; i < shape.points.length; i++) {
      const dx = shape.points[i].x - shape.points[i - 1].x;
      const dy = shape.points[i].y - shape.points[i - 1].y;
      length += Math.sqrt(dx * dx + dy * dy);
    }
    return Math.round(length * (shape.pathWidth ?? 0));
  }
  return 0;
}
