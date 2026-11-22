/**
 * 鸿图零序列化结构克隆与写时复制（CoW）增量快照引擎
 *
 * 设计目标：
 * 1. 全仓彻底消除同步 JSON 序列化往返（stringify + parse）字符串往返深拷贝，避免大版图主线程 GC 抖动与帧率跌落；
 * 2. 通过 `UIUtils.getTarget()` 先剥离 ArkUI V1（@State/@Prop/@Observed）与 V2（@ObservedV2/@Trace）状态代理，
 *    避免跨 V2->V1 组件传递或推入 TaskPool 并发队列时触发双重代理或序列化异常；
 * 3. 对高频热路径模型（Point / Shape / UiLayer / EditStructureState / WorkspaceDocument）提供单态快速克隆与
 *    基于 IEEE-754 双 32 位 64-bit 精确浮点比特混合指纹 + 关键头中尾顶点校验的增量写时复制（Copy-on-Write）只读快照缓存，
 *    彻底根除超过 2.15 mm 坐标时的 32 位整型乘法回绕与亚纳米浮点截断问题。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { UIUtils } from '@kit.ArkUI';
import type { Point, Shape } from '../models/GdsiiData';
import type { UiLayer } from './types';
import type { LayoutPropRecord, SourceLayerDefinition } from '../../cpp/types/libhongtu/Index';
import type { LayoutPort, LayoutCrossSection, LayoutContextRecord, PortEndpoint } from '../models/LayoutPort';
import type { EditStructureState, InstancePathStep } from '../services/EditService';
import type { WorkspaceDocument, PCellVariant } from '../services/WorkspaceService';
import type { RulerLine } from './UiStores';

const STANDARD_SHAPE_KEYS: Set<string> = new Set<string>([
  'id', 'type', 'layerNumber', 'datatype', 'points', 'pathWidth', 'pathType',
  'textPresentation', 'pathBeginExtension', 'pathEndExtension', 'pathWidthAbsolute',
  'arrayCols', 'arrayRows', 'arrayColStepX', 'arrayColStepY', 'arrayRowStepX', 'arrayRowStepY',
  'selected', 'cellId', 'rotation', 'mirror', 'magnification', 'text', 'cellName',
  'ownerCellId', 'properties'
]);

// Freshly hydrated geometry is shared by snapshots. Geometry edits replace the points array.
const immutablePointArrays: WeakSet<Object> = new WeakSet<Object>();
const finiteValidatedPointArrays: WeakSet<Object> = new WeakSet<Object>();

export function markImmutablePointArray(points: Point[]): void {
  immutablePointArrays.add(points);
}

export function isImmutablePointArray(points: Point[]): boolean {
  return immutablePointArrays.has(unwrapObserved(points));
}

export function markFiniteValidatedPointArray(points: Point[]): void {
  finiteValidatedPointArrays.add(points);
}

export function isFiniteValidatedPointArray(points: Point[]): boolean {
  return finiteValidatedPointArrays.has(unwrapObserved(points));
}

/** 零分配 IEEE-754 binary64 精确比特提取缓冲区 */
const FLOAT64_SCRATCH_BUFFER: ArrayBuffer = new ArrayBuffer(8);
const FLOAT64_SCRATCH_VIEW: DataView = new DataView(FLOAT64_SCRATCH_BUFFER);

/**
 * 剥离 ArkUI V1 / V2 观察者代理，获取底层原始对象。
 * 在向 V1 子组件 @Prop 传递 @Trace 数组/对象或向 TaskPool 投递参数前调用，防止双重代理。
 */
export function unwrapObserved<T>(value: T): T {
  if (value === null || value === undefined || typeof value !== 'object') {
    return value;
  }
  try {
    return UIUtils.getTarget(value);
  } catch (_) {
    return value;
  }
}

/**
 * 通用零 JSON 递归结构化深拷贝。
 * - 自动剥离每层 V1/V2 代理；
 * - 保持与 JSON 往返深拷贝 一致的键省略语义（忽略值为 undefined 或 function 的对象属性），
 *   完整保留自定义扩展自有字段（preserveOwnFields）。
 */
export function cloneStructured<T>(value: T): T {
  const raw: T = unwrapObserved(value);
  if (raw === null || raw === undefined || typeof raw !== 'object') {
    return raw;
  }
  if (Array.isArray(raw)) {
    const srcArr: Object[] = raw as Object as Object[];
    if (immutablePointArrays.has(srcArr)) return raw;
    const len: number = srcArr.length;
    const dstArr: Object[] = new Array<Object>(len);
    for (let i: number = 0; i < len; i++) {
      dstArr[i] = cloneStructured(srcArr[i]);
    }
    return dstArr as Object as T;
  }
  if (raw instanceof Date) {
    return new Date(raw.getTime()) as Object as T;
  }
  if (raw instanceof ArrayBuffer) {
    return raw.slice(0) as Object as T;
  }
  if (raw instanceof Float32Array) {
    return new Float32Array(raw) as Object as T;
  }
  if (raw instanceof Float64Array) {
    return new Float64Array(raw) as Object as T;
  }
  if (raw instanceof Int32Array) {
    return new Int32Array(raw) as Object as T;
  }
  if (raw instanceof Uint8Array) {
    return new Uint8Array(raw) as Object as T;
  }
  if (raw instanceof Set) {
    const dstSet: Set<Object> = new Set<Object>();
    (raw as Object as Set<Object>).forEach((entry: Object) => {
      dstSet.add(cloneStructured(entry));
    });
    return dstSet as Object as T;
  }
  if (raw instanceof Map) {
    const dstMap: Map<Object, Object> = new Map<Object, Object>();
    (raw as Object as Map<Object, Object>).forEach((entryVal: Object, entryKey: Object) => {
      dstMap.set(cloneStructured(entryKey), cloneStructured(entryVal));
    });
    return dstMap as Object as T;
  }
  const srcObj: Record<string, Object> = raw as Object as Record<string, Object>;
  const dstObj: Record<string, Object> = {};
  const keys: string[] = Object.keys(srcObj);
  for (let i: number = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const fieldVal: Object | undefined = srcObj[key];
    if (fieldVal !== undefined && typeof fieldVal !== 'function') {
      dstObj[key] = cloneStructured(fieldVal);
    }
  }
  return dstObj as Object as T;
}

export function clonePointModel(point: Point): Point {
  const raw: Point = unwrapObserved(point);
  return { x: raw.x, y: raw.y };
}

export function clonePointArray(points: Point[]): Point[] {
  const rawPoints: Point[] = unwrapObserved(points);
  if (immutablePointArrays.has(rawPoints)) {
    return rawPoints;
  }
  const len: number = rawPoints.length;
  const copy: Point[] = new Array<Point>(len);
  for (let i: number = 0; i < len; i++) {
    const p: Point = unwrapObserved(rawPoints[i]);
    copy[i] = { x: p.x, y: p.y };
  }
  return copy;
}

export function clonePropRecordsModel(records: LayoutPropRecord[] | undefined): LayoutPropRecord[] | undefined {
  if (records === undefined) {
    return undefined;
  }
  const rawRecords: LayoutPropRecord[] = unwrapObserved(records);
  const len: number = rawRecords.length;
  const copy: LayoutPropRecord[] = new Array<LayoutPropRecord>(len);
  for (let i: number = 0; i < len; i++) {
    const r: LayoutPropRecord = unwrapObserved(rawRecords[i]);
    copy[i] = { attr: r.attr, name: r.name, value: r.value, dtype: r.dtype };
  }
  return copy;
}

/**
 * 单态高速克隆单个版图图元 Shape（比 JSON 往返快一个数量级，零临时字符串分配）。
 */
export function cloneShapeModel(shape: Shape, preserveOwnFields: boolean = false): Shape {
  const raw: Shape = unwrapObserved(shape);
  const points: Point[] = unwrapObserved(raw.points);
  const copy: Shape = {
    id: raw.id,
    type: raw.type,
    layerNumber: raw.layerNumber,
    datatype: raw.datatype,
    points: immutablePointArrays.has(points) ? points : clonePointArray(points),
    selected: raw.selected,
  };
  if (raw.pathWidth !== undefined) copy.pathWidth = raw.pathWidth;
  if (raw.pathType !== undefined) copy.pathType = raw.pathType;
  if (raw.textPresentation !== undefined) copy.textPresentation = raw.textPresentation;
  if (raw.pathBeginExtension !== undefined) copy.pathBeginExtension = raw.pathBeginExtension;
  if (raw.pathEndExtension !== undefined) copy.pathEndExtension = raw.pathEndExtension;
  if (raw.pathWidthAbsolute !== undefined) copy.pathWidthAbsolute = raw.pathWidthAbsolute;
  if (raw.arrayCols !== undefined) copy.arrayCols = raw.arrayCols;
  if (raw.arrayRows !== undefined) copy.arrayRows = raw.arrayRows;
  if (raw.arrayColStepX !== undefined) copy.arrayColStepX = raw.arrayColStepX;
  if (raw.arrayColStepY !== undefined) copy.arrayColStepY = raw.arrayColStepY;
  if (raw.arrayRowStepX !== undefined) copy.arrayRowStepX = raw.arrayRowStepX;
  if (raw.arrayRowStepY !== undefined) copy.arrayRowStepY = raw.arrayRowStepY;
  if (raw.ownerCellId !== undefined) copy.ownerCellId = raw.ownerCellId;
  if (raw.cellId !== undefined) copy.cellId = raw.cellId;
  if (raw.cellName !== undefined) copy.cellName = raw.cellName;
  if (raw.rotation !== undefined) copy.rotation = raw.rotation;
  if (raw.mirror !== undefined) copy.mirror = raw.mirror;
  if (raw.magnification !== undefined) copy.magnification = raw.magnification;
  if (raw.text !== undefined) copy.text = raw.text;
  if (raw.properties !== undefined) copy.properties = clonePropRecordsModel(raw.properties);

  if (preserveOwnFields) {
    const srcRec: Record<string, Object> = raw as Object as Record<string, Object>;
    const dstRec: Record<string, Object> = copy as Object as Record<string, Object>;
    const keys: string[] = Object.keys(srcRec);
    for (let i: number = 0; i < keys.length; i++) {
      const k: string = keys[i];
      if (!STANDARD_SHAPE_KEYS.has(k)) {
        const extra: Object | undefined = srcRec[k];
        if (extra !== undefined && typeof extra !== 'function') {
          dstRec[k] = cloneStructured(extra);
        }
      }
    }
  }
  return copy;
}

export function cloneShapeArray(shapes: Shape[], preserveOwnFields: boolean = false): Shape[] {
  const rawShapes: Shape[] = unwrapObserved(shapes);
  const len: number = rawShapes.length;
  const out: Shape[] = new Array<Shape>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = cloneShapeModel(rawShapes[i], preserveOwnFields);
  }
  return out;
}

export function cloneUiLayerModel(layer: UiLayer): UiLayer {
  return cloneStructured(layer);
}

export function cloneUiLayerArray(layers: UiLayer[]): UiLayer[] {
  const rawLayers: UiLayer[] = unwrapObserved(layers);
  const len: number = rawLayers.length;
  const out: UiLayer[] = new Array<UiLayer>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = cloneStructured(rawLayers[i]);
  }
  return out;
}

export function cloneSourceLayerDefinitions(
  defs: SourceLayerDefinition[] | undefined
): SourceLayerDefinition[] | undefined {
  if (defs === undefined) {
    return undefined;
  }
  const rawDefs: SourceLayerDefinition[] = unwrapObserved(defs);
  const len: number = rawDefs.length;
  const out: SourceLayerDefinition[] = new Array<SourceLayerDefinition>(len);
  for (let i: number = 0; i < len; i++) {
    const d: SourceLayerDefinition = unwrapObserved(rawDefs[i]);
    out[i] = {
      name: d.name,
      textLayer: d.textLayer,
      layer: { type: d.layer.type, lower: d.layer.lower, upper: d.layer.upper },
      datatype: { type: d.datatype.type, lower: d.datatype.lower, upper: d.datatype.upper },
    };
  }
  return out;
}

export function cloneInstancePathSteps(steps: InstancePathStep[] | undefined): InstancePathStep[] {
  if (steps === undefined) {
    return [];
  }
  const rawSteps: InstancePathStep[] = unwrapObserved(steps);
  const len: number = rawSteps.length;
  const out: InstancePathStep[] = new Array<InstancePathStep>(len);
  for (let i: number = 0; i < len; i++) {
    const s: InstancePathStep = unwrapObserved(rawSteps[i]);
    out[i] = {
      instanceId: s.instanceId,
      parentCellId: s.parentCellId,
      cellId: s.cellId,
      row: s.row,
      col: s.col,
      transform: {
        a: s.transform.a,
        b: s.transform.b,
        c: s.transform.c,
        d: s.transform.d,
        tx: s.transform.tx,
        ty: s.transform.ty,
      },
    };
  }
  return out;
}

export function clonePortModel(port: LayoutPort): LayoutPort {
  const raw: LayoutPort = unwrapObserved(port);
  const out: LayoutPort = {
    id: raw.id,
    ownerCellId: raw.ownerCellId,
    ownerCellKey: raw.ownerCellKey,
    name: raw.name,
    centerNm: { x: raw.centerNm.x, y: raw.centerNm.y },
    orientationDeg: raw.orientationDeg,
    widthNm: raw.widthNm,
    layerNumber: raw.layerNumber,
    datatype: raw.datatype,
    portType: raw.portType,
    frameMirror: raw.frameMirror,
    frameMagnification: raw.frameMagnification,
    infoJson: raw.infoJson,
  };
  if (raw.crossSectionKey !== undefined) out.crossSectionKey = raw.crossSectionKey;
  if (raw.crossSectionVersion !== undefined) out.crossSectionVersion = raw.crossSectionVersion;
  if (raw.provenance !== undefined) out.provenance = raw.provenance;
  return out;
}

export function clonePortArray(ports: LayoutPort[] | undefined): LayoutPort[] | undefined {
  if (ports === undefined) {
    return undefined;
  }
  const rawPorts: LayoutPort[] = unwrapObserved(ports);
  const len: number = rawPorts.length;
  const out: LayoutPort[] = new Array<LayoutPort>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = clonePortModel(rawPorts[i]);
  }
  return out;
}

export function cloneCrossSectionModel(section: LayoutCrossSection): LayoutCrossSection {
  return cloneStructured(section);
}

export function cloneCrossSectionArray(sections: LayoutCrossSection[] | undefined): LayoutCrossSection[] | undefined {
  if (sections === undefined) {
    return undefined;
  }
  const rawSections: LayoutCrossSection[] = unwrapObserved(sections);
  const len: number = rawSections.length;
  const out: LayoutCrossSection[] = new Array<LayoutCrossSection>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = cloneStructured(rawSections[i]);
  }
  return out;
}

export function cloneContextRecordArray(records: LayoutContextRecord[] | undefined): LayoutContextRecord[] | undefined {
  if (records === undefined) {
    return undefined;
  }
  const rawRecords: LayoutContextRecord[] = unwrapObserved(records);
  const len: number = rawRecords.length;
  const out: LayoutContextRecord[] = new Array<LayoutContextRecord>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = cloneStructured(rawRecords[i]);
  }
  return out;
}

export function cloneCellContextRecordMatrix(
  matrix: LayoutContextRecord[][] | undefined
): LayoutContextRecord[][] | undefined {
  if (matrix === undefined) {
    return undefined;
  }
  const rawMatrix: LayoutContextRecord[][] = unwrapObserved(matrix);
  const len: number = rawMatrix.length;
  const out: LayoutContextRecord[][] = new Array<LayoutContextRecord[]>(len);
  for (let i: number = 0; i < len; i++) {
    out[i] = cloneContextRecordArray(rawMatrix[i]) ?? [];
  }
  return out;
}

export function clonePortEndpointModel(endpoint: PortEndpoint): PortEndpoint {
  const raw: PortEndpoint = unwrapObserved(endpoint);
  return {
    portId: raw.portId,
    rootCellId: raw.rootCellId,
    rootCellKey: raw.rootCellKey,
    path: cloneInstancePathSteps(raw.path),
  };
}

export function cloneEditStructureModel(
  state: EditStructureState,
  preserveOwnFields: boolean = false
): EditStructureState {
  if (preserveOwnFields) {
    return cloneStructured(state);
  }
  const raw: EditStructureState = unwrapObserved(state);
  const copy: EditStructureState = {
    technologyJson: raw.technologyJson,
    drcDeckJson: raw.drcDeckJson,
    drcConfiguration: raw.drcConfiguration === undefined ? undefined : cloneStructured(raw.drcConfiguration),
    cellKeys: raw.cellKeys === undefined ? undefined : unwrapObserved(raw.cellKeys).slice(),
    ports: clonePortArray(raw.ports),
    crossSections: cloneCrossSectionArray(raw.crossSections),
    layoutContextRecords: cloneContextRecordArray(raw.layoutContextRecords),
    cellContextRecords: cloneCellContextRecordMatrix(raw.cellContextRecords),
    cellNames: unwrapObserved(raw.cellNames).slice(),
    cellProperties: unwrapObserved(raw.cellProperties).map(
      (props: LayoutPropRecord[]): LayoutPropRecord[] => clonePropRecordsModel(props) ?? []
    ),
    libProperties: clonePropRecordsModel(raw.libProperties),
    topCellId: raw.topCellId,
    cellStack: unwrapObserved(raw.cellStack).slice(),
    layers: raw.layers === undefined ? undefined : cloneUiLayerArray(raw.layers),
    layerDefinitions: cloneSourceLayerDefinitions(raw.layerDefinitions),
    navigationPath: cloneInstancePathSteps(raw.navigationPath),
    userUnits: raw.userUnits,
    physicalUnits: raw.physicalUnits,
    precision: raw.precision === undefined ? undefined : {
      dbuNm: raw.precision.dbuNm,
      drawStepNm: raw.precision.drawStepNm,
      displayGridNm: raw.precision.displayGridNm,
      geometrySnapEnabled: raw.precision.geometrySnapEnabled,
      geometrySnapKinds: unwrapObserved(raw.precision.geometrySnapKinds).slice(),
    },
  };
  if (raw.localProcessOwned !== undefined) {
    copy.localProcessOwned = raw.localProcessOwned;
  }
  return copy;
}

/**
 * 双 32 位通道 64-bit 精确浮点比特指纹累积器：
 * 通过 DataView 提取 IEEE-754 binary64 完整 64-bit 尾数与阶码比特，
 * 彻底消除 `Math.trunc(value * 1000)` 在 >2.15 mm (2,147,483 nm) 坐标时的 32 位溢出回绕与亚皮米截断。
 */
export interface ShapeFingerprint64 {
  lo: number;
  hi: number;
}

/** 不可变点集（导入解包冻结数组）的 64-bit 浮点比特摘要缓存，将 231 万顶点重复摘要从 5.5s 降至 O(1) */
const IMMUTABLE_POINT_DIGESTS: WeakMap<Point[], ShapeFingerprint64> = new WeakMap<Point[], ShapeFingerprint64>();

function hasNonStandardShapeKeys(srcRec: Record<string, Object>): boolean {
  const keys: string[] = Object.keys(srcRec);
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (!STANDARD_SHAPE_KEYS.has(k)) {
      const extra: Object | undefined = srcRec[k];
      if (extra !== undefined && typeof extra !== 'function') {
        return true;
      }
    }
  }
  return false;
}

class Fingerprint64Accumulator {
  lo: number = 0x811c9dc5;
  hi: number = 0x9e3779b9;

  mixUint32Pair(wordLo: number, wordHi: number): void {
    let a: number = (this.lo ^ (wordLo >>> 0)) >>> 0;
    a = Math.imul(a, 16777619) >>> 0;
    a = (a ^ (wordHi >>> 16)) >>> 0;
    a = Math.imul(a, 0x85ebca6b) >>> 0;

    let b: number = (this.hi ^ (wordHi >>> 0)) >>> 0;
    b = Math.imul(b, 0xc2b2ae35) >>> 0;
    b = (b ^ (wordLo >>> 13) ^ (a >>> 19)) >>> 0;
    b = Math.imul(b, 16777619) >>> 0;

    this.lo = (a ^ (b >>> 15)) >>> 0;
    this.hi = (b ^ (a >>> 11)) >>> 0;
  }

  mixFloat64(value: number): void {
    if (Number.isNaN(value)) {
      this.mixUint32Pair(0x00000001, 0x7ff80000);
      return;
    }
    const normalized: number = value === 0 ? 0 : value;
    FLOAT64_SCRATCH_VIEW.setFloat64(0, normalized, true);
    const wordLo: number = FLOAT64_SCRATCH_VIEW.getUint32(0, true);
    const wordHi: number = FLOAT64_SCRATCH_VIEW.getUint32(4, true);
    this.mixUint32Pair(wordLo, wordHi);
  }

  mixOptionalFloat64(value: number | undefined, sentinelTag: number): void {
    if (value === undefined) {
      this.mixUint32Pair(sentinelTag >>> 0, 0x7ff40000);
      return;
    }
    this.mixUint32Pair(0xa5a55a5a, sentinelTag >>> 0);
    this.mixFloat64(value);
  }

  mixString(text: string | undefined): void {
    if (text === undefined) {
      this.mixUint32Pair(0xffffffff, 0x7ff10000);
      return;
    }
    const len: number = text.length;
    this.mixUint32Pair(len >>> 0, 0x517cc1b7);
    let i: number = 0;
    while (i + 1 < len) {
      const pair: number = ((text.charCodeAt(i) & 0xffff) | ((text.charCodeAt(i + 1) & 0xffff) << 16)) >>> 0;
      this.mixUint32Pair(pair, (i * 2654435761) >>> 0);
      i += 2;
    }
    if (i < len) {
      this.mixUint32Pair(text.charCodeAt(i) & 0xffff, 0x27d4eb2f);
    }
  }
}

export function computeShapeFingerprint64(shape: Shape): ShapeFingerprint64 {
  const raw: Shape = unwrapObserved(shape);
  const acc: Fingerprint64Accumulator = new Fingerprint64Accumulator();
  acc.mixFloat64(raw.id);
  acc.mixString(raw.type);
  acc.mixFloat64(raw.layerNumber);
  acc.mixFloat64(raw.datatype);
  acc.mixUint32Pair(raw.selected ? 1 : 0, raw.pathWidthAbsolute ? 1 : 0);
  acc.mixOptionalFloat64(raw.ownerCellId, 1);
  acc.mixOptionalFloat64(raw.cellId, 2);
  acc.mixOptionalFloat64(raw.rotation, 3);
  acc.mixOptionalFloat64(raw.mirror, 4);
  acc.mixOptionalFloat64(raw.magnification, 5);
  acc.mixOptionalFloat64(raw.pathWidth, 6);
  acc.mixOptionalFloat64(raw.pathType, 7);
  acc.mixOptionalFloat64(raw.pathBeginExtension, 8);
  acc.mixOptionalFloat64(raw.pathEndExtension, 9);
  acc.mixOptionalFloat64(raw.textPresentation, 10);
  acc.mixOptionalFloat64(raw.arrayCols, 11);
  acc.mixOptionalFloat64(raw.arrayRows, 12);
  acc.mixOptionalFloat64(raw.arrayColStepX, 13);
  acc.mixOptionalFloat64(raw.arrayColStepY, 14);
  acc.mixOptionalFloat64(raw.arrayRowStepX, 15);
  acc.mixOptionalFloat64(raw.arrayRowStepY, 16);
  acc.mixString(raw.text);
  acc.mixString(raw.cellName);

  const pts: Point[] = unwrapObserved(raw.points);
  acc.mixUint32Pair(pts.length >>> 0, 0x31415926);
  if (immutablePointArrays.has(pts)) {
    let ptDigest: ShapeFingerprint64 | undefined = IMMUTABLE_POINT_DIGESTS.get(pts);
    if (ptDigest === undefined) {
      const ptAcc: Fingerprint64Accumulator = new Fingerprint64Accumulator();
      for (let i: number = 0; i < pts.length; i++) {
        const p: Point = pts[i];
        ptAcc.mixFloat64(p.x);
        ptAcc.mixFloat64(p.y);
      }
      ptDigest = { lo: ptAcc.lo >>> 0, hi: ptAcc.hi >>> 0 };
      IMMUTABLE_POINT_DIGESTS.set(pts, ptDigest);
    }
    acc.mixUint32Pair(ptDigest.lo, ptDigest.hi);
  } else {
    for (let i: number = 0; i < pts.length; i++) {
      const p: Point = unwrapObserved(pts[i]);
      acc.mixFloat64(p.x);
      acc.mixFloat64(p.y);
    }
  }

  const props: LayoutPropRecord[] | undefined = raw.properties;
  if (props !== undefined) {
    const rawProps: LayoutPropRecord[] = unwrapObserved(props);
    acc.mixUint32Pair(rawProps.length >>> 0, 0x27182818);
    for (let i: number = 0; i < rawProps.length; i++) {
      const pr: LayoutPropRecord = unwrapObserved(rawProps[i]);
      acc.mixFloat64(pr.attr);
      acc.mixFloat64(pr.dtype);
      acc.mixString(pr.name);
      acc.mixString(pr.value);
    }
  } else {
    acc.mixUint32Pair(0xffffffff, 0x7ff20000);
  }

  const srcRec: Record<string, Object> = raw as Object as Record<string, Object>;
  const keys: string[] = Object.keys(srcRec);
  for (let i: number = 0; i < keys.length; i++) {
    const k: string = keys[i];
    if (!STANDARD_SHAPE_KEYS.has(k)) {
      const extra: Object | undefined = srcRec[k];
      if (extra !== undefined && typeof extra !== 'function') {
        acc.mixString(k);
        if (typeof extra === 'number') {
          acc.mixFloat64(extra as number);
        } else if (typeof extra === 'string') {
          acc.mixString(extra as string);
        } else if (typeof extra === 'boolean') {
          acc.mixUint32Pair((extra as boolean) ? 1 : 0, 0x55aa55aa);
        } else {
          acc.mixString(JSON.stringify(unwrapObserved(extra)));
        }
      }
    }
  }

  return { lo: acc.lo >>> 0, hi: acc.hi >>> 0 };
}

export function computeShapeDigest(shape: Shape): number {
  const fp: ShapeFingerprint64 = computeShapeFingerprint64(shape);
  return (fp.lo ^ Math.imul(fp.hi, 0x9e3779b1)) >>> 0;
}

function sameCoord(a: number, b: number): boolean {
  if (a === 0 && b === 0) {
    return true;
  }
  return a === b || (Number.isNaN(a) && Number.isNaN(b));
}

interface KeyVertexGuard {
  firstX: number;
  firstY: number;
  midX: number;
  midY: number;
  lastX: number;
  lastY: number;
}

function extractKeyVertices(pts: Point[]): KeyVertexGuard {
  const len: number = pts.length;
  if (len === 0) {
    return { firstX: 0, firstY: 0, midX: 0, midY: 0, lastX: 0, lastY: 0 };
  }
  const first: Point = unwrapObserved(pts[0]);
  const mid: Point = unwrapObserved(pts[len >> 1]);
  const last: Point = unwrapObserved(pts[len - 1]);
  return {
    firstX: first.x,
    firstY: first.y,
    midX: mid.x,
    midY: mid.y,
    lastX: last.x,
    lastY: last.y,
  };
}

interface CachedShapeSnapshotEntry {
  digestLo: number;
  digestHi: number;
  pointCount: number;
  propCount: number;
  layerNumber: number;
  datatype: number;
  ownerCellId: number;
  cellId: number;
  selected: boolean;
  rotation: number;
  mirror: number;
  magnification: number;
  pathWidth: number;
  pathType: number;
  text: string;
  cellName: string;
  immutablePtsRef: Point[] | null;
  hasCustomKeys: boolean;
  vertices: KeyVertexGuard;
  immutableClone: Shape;
}

export interface IncrementalSnapshotStats {
  hits: number;
  misses: number;
  cachedDocuments: number;
}

/**
 * 写时复制（Copy-on-Write）增量文档快照缓存引擎。
 * - 自动保存草稿（WorkspaceService.prepareDraft）高频触发时，未改动图元直接 O(1) 复用已冻结副本，
 *   仅对脏图元（新增、移动、属性或顶点编辑）重新分配 Point[] 与 Shape；
 * - 需要可写独立副本的场景（PCell 预览、局部扁平化、导出改写）走 `cloneWorkspaceDocument`，仍完全绕过 JSON 序列化。
 */
export class IncrementalDocumentSnapshotCache {
  private readonly docShapeCaches: Map<string, Map<number, CachedShapeSnapshotEntry>> =
    new Map<string, Map<number, CachedShapeSnapshotEntry>>();
  private hitCount: number = 0;
  private missCount: number = 0;

  captureReadOnlyShapes(docOrShapes: string | Shape[], maybeShapes?: Shape[]): Shape[] {
    const documentId: string = typeof docOrShapes === 'string' ? docOrShapes : '__default__';
    const inputShapes: Shape[] = typeof docOrShapes === 'string' ? (maybeShapes ?? []) : docOrShapes;
    const rawShapes: Shape[] = unwrapObserved(inputShapes);
    const key: string = documentId.length > 0 ? documentId : '__default__';
    let prevCache: Map<number, CachedShapeSnapshotEntry> | undefined = this.docShapeCaches.get(key);
    if (prevCache === undefined) {
      prevCache = new Map<number, CachedShapeSnapshotEntry>();
    }
    const nextCache: Map<number, CachedShapeSnapshotEntry> = new Map<number, CachedShapeSnapshotEntry>();
    const len: number = rawShapes.length;
    const out: Shape[] = new Array<Shape>(len);
    for (let i: number = 0; i < len; i++) {
      const s: Shape = unwrapObserved(rawShapes[i]);
      const pts: Point[] = unwrapObserved(s.points);
      const immutablePts: boolean = immutablePointArrays.has(pts);
      const ptLen: number = pts.length;
      const propLen: number = s.properties === undefined ? -1 : unwrapObserved(s.properties).length;
      const ownerCell: number = s.ownerCellId ?? -1;
      const refCell: number = s.cellId ?? -1;
      const rot: number = s.rotation ?? 0;
      const mir: number = s.mirror ?? 0;
      const mag: number = s.magnification ?? 1;
      const pw: number = s.pathWidth ?? 0;
      const pt: number = s.pathType ?? 0;
      const txt: string = s.text ?? '';
      const cname: string = s.cellName ?? '';
      const hit: CachedShapeSnapshotEntry | undefined = prevCache.get(s.id);

      // O(1) 零哈希快路径：不可变点集引用未变且标量属性未改时，完全跳过逐点混合与 Object.keys
      if (
        hit !== undefined &&
        immutablePts &&
        hit.immutablePtsRef === pts &&
        !hit.hasCustomKeys &&
        propLen <= 0 &&
        hit.pointCount === ptLen &&
        hit.propCount === propLen &&
        hit.layerNumber === s.layerNumber &&
        hit.datatype === s.datatype &&
        hit.ownerCellId === ownerCell &&
        hit.cellId === refCell &&
        hit.selected === s.selected &&
        sameCoord(hit.rotation, rot) &&
        hit.mirror === mir &&
        sameCoord(hit.magnification, mag) &&
        sameCoord(hit.pathWidth, pw) &&
        hit.pathType === pt &&
        hit.text === txt &&
        hit.cellName === cname
      ) {
        this.hitCount++;
        out[i] = hit.immutableClone;
        nextCache.set(s.id, hit);
        continue;
      }

      const kv: KeyVertexGuard = extractKeyVertices(pts);
      const fp: ShapeFingerprint64 = computeShapeFingerprint64(s);
      if (
        hit !== undefined &&
        hit.digestLo === fp.lo &&
        hit.digestHi === fp.hi &&
        hit.pointCount === ptLen &&
        hit.propCount === propLen &&
        hit.layerNumber === s.layerNumber &&
        hit.datatype === s.datatype &&
        hit.ownerCellId === ownerCell &&
        hit.cellId === refCell &&
        sameCoord(hit.vertices.firstX, kv.firstX) &&
        sameCoord(hit.vertices.firstY, kv.firstY) &&
        sameCoord(hit.vertices.midX, kv.midX) &&
        sameCoord(hit.vertices.midY, kv.midY) &&
        sameCoord(hit.vertices.lastX, kv.lastX) &&
        sameCoord(hit.vertices.lastY, kv.lastY)
      ) {
        this.hitCount++;
        out[i] = hit.immutableClone;
        nextCache.set(s.id, hit);
      } else {
        this.missCount++;
        const customKeys: boolean = hasNonStandardShapeKeys(s as Object as Record<string, Object>);
        const cloned: Shape = cloneShapeModel(s, customKeys);
        const entry: CachedShapeSnapshotEntry = {
          digestLo: fp.lo,
          digestHi: fp.hi,
          pointCount: ptLen,
          propCount: propLen,
          layerNumber: s.layerNumber,
          datatype: s.datatype,
          ownerCellId: ownerCell,
          cellId: refCell,
          selected: s.selected,
          rotation: rot,
          mirror: mir,
          magnification: mag,
          pathWidth: pw,
          pathType: pt,
          text: txt,
          cellName: cname,
          immutablePtsRef: immutablePts ? pts : null,
          hasCustomKeys: customKeys,
          vertices: kv,
          immutableClone: cloned,
        };
        out[i] = cloned;
        nextCache.set(s.id, entry);
      }
    }
    if (this.docShapeCaches.size >= 12 && !this.docShapeCaches.has(key)) {
      const oldestKey: string | undefined = this.docShapeCaches.keys().next().value;
      if (oldestKey !== undefined) {
        this.docShapeCaches.delete(oldestKey);
      }
    }
    this.docShapeCaches.set(key, nextCache);
    return out;
  }

  private cloneDocumentMetadataShell(raw: WorkspaceDocument, clonedShapes: Shape[]): WorkspaceDocument {
    const rulers: RulerLine[] = unwrapObserved(raw.rulers).map((r: RulerLine): RulerLine => ({
      id: r.id,
      vertical: r.vertical,
      pos: r.pos,
    }));
    const pcells: PCellVariant[] = unwrapObserved(raw.pcells).map((v: PCellVariant): PCellVariant => {
      const copy: PCellVariant = {
        cellId: v.cellId,
        name: v.name,
        params: cloneStructured(v.params),
      };
      if (v.technologyId !== undefined) copy.technologyId = v.technologyId;
      if (v.technologyVersion !== undefined) copy.technologyVersion = v.technologyVersion;
      if (v.deviceName !== undefined) copy.deviceName = v.deviceName;
      if (v.deviceModel !== undefined) copy.deviceModel = v.deviceModel;
      return copy;
    });
    const out: WorkspaceDocument = {
      version: raw.version,
      id: raw.id,
      title: raw.title,
      sourcePath: raw.sourcePath,
      saveUri: raw.saveUri,
      projectUri: raw.projectUri,
      libName: raw.libName,
      topCellName: raw.topCellName,
      topCellId: raw.topCellId,
      cellNames: unwrapObserved(raw.cellNames).slice(),
      cellProperties: unwrapObserved(raw.cellProperties).map(
        (records: LayoutPropRecord[]): LayoutPropRecord[] => clonePropRecordsModel(records) ?? []
      ),
      libProperties: clonePropRecordsModel(raw.libProperties) ?? [],
      shapes: clonedShapes,
      layers: cloneUiLayerArray(raw.layers),
      userUnits: raw.userUnits,
      physicalUnits: raw.physicalUnits,
      dirty: raw.dirty,
      cellStack: unwrapObserved(raw.cellStack).slice(),
      selectedIds: unwrapObserved(raw.selectedIds).slice(),
      zoom: raw.zoom,
      offsetX: raw.offsetX,
      offsetY: raw.offsetY,
      hierarchyDepth: raw.hierarchyDepth,
      gridSize: raw.gridSize,
      rulers: rulers,
      pcells: pcells,
      technologyId: raw.technologyId,
      revision: raw.revision,
      updatedAt: raw.updatedAt,
    };
    if (raw.viewMode !== undefined) out.viewMode = raw.viewMode;
    if (raw.cellKeys !== undefined) out.cellKeys = unwrapObserved(raw.cellKeys).slice();
    if (raw.ports !== undefined) out.ports = clonePortArray(raw.ports);
    if (raw.crossSections !== undefined) out.crossSections = cloneCrossSectionArray(raw.crossSections);
    if (raw.layoutContextRecords !== undefined) out.layoutContextRecords = cloneContextRecordArray(raw.layoutContextRecords);
    if (raw.cellContextRecords !== undefined) out.cellContextRecords = cloneCellContextRecordMatrix(raw.cellContextRecords);
    if (raw.layerDefinitions !== undefined) out.layerDefinitions = cloneSourceLayerDefinitions(raw.layerDefinitions);
    if (raw.navigationPath !== undefined) out.navigationPath = cloneInstancePathSteps(raw.navigationPath);
    if (raw.precision !== undefined) {
      out.precision = {
        dbuNm: raw.precision.dbuNm,
        drawStepNm: raw.precision.drawStepNm,
        displayGridNm: raw.precision.displayGridNm,
        geometrySnapEnabled: raw.precision.geometrySnapEnabled,
        geometrySnapKinds: unwrapObserved(raw.precision.geometrySnapKinds).slice(),
      };
    }
    if (raw.technologyJson !== undefined) out.technologyJson = raw.technologyJson;
    if (raw.localProcessState !== undefined) out.localProcessState = cloneStructured(raw.localProcessState);
    if (raw.engineering !== undefined) out.engineering = cloneStructured(raw.engineering);
    if (raw.localPythonDraft !== undefined) out.localPythonDraft = cloneStructured(raw.localPythonDraft);
    if (raw.localPythonDraftDirty !== undefined) out.localPythonDraftDirty = raw.localPythonDraftDirty;
    return out;
  }

  /**
   * 生成只读增量快照（供自动保存草稿与后台序列化线程消费，未变更图元零内存分配）。
   */
  captureReadOnlyWorkspaceDocument(document: WorkspaceDocument): WorkspaceDocument {
    const raw: WorkspaceDocument = unwrapObserved(document);
    const sharedShapes: Shape[] = this.captureReadOnlyShapes(raw.id, raw.shapes);
    return this.cloneDocumentMetadataShell(raw, sharedShapes);
  }

  /**
   * 生成完全隔离的可写 WorkspaceDocument 副本（零 JSON 往返）。
   */
  cloneWorkspaceDocumentMetadataWithShapes(document: WorkspaceDocument, shapes: Shape[]): WorkspaceDocument {
    const raw: WorkspaceDocument = unwrapObserved(document);
    return this.cloneDocumentMetadataShell(raw, shapes);
  }

  cloneWorkspaceDocument(document: WorkspaceDocument): WorkspaceDocument {
    const raw: WorkspaceDocument = unwrapObserved(document);
    const mutableShapes: Shape[] = cloneShapeArray(raw.shapes, true);
    return this.cloneDocumentMetadataShell(raw, mutableShapes);
  }

  evictDocument(documentId: string): void {
    this.docShapeCaches.delete(documentId);
  }

  clear(): void {
    this.docShapeCaches.clear();
  }

  stats(): IncrementalSnapshotStats {
    return {
      hits: this.hitCount,
      misses: this.missCount,
      cachedDocuments: this.docShapeCaches.size,
    };
  }
}

export const incrementalSnapshotEngine: IncrementalDocumentSnapshotCache = new IncrementalDocumentSnapshotCache();
