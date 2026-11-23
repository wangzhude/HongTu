/**
 * 鸿图 NAPI 接口 TypeScript 类型声明
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

/**
 * 版图元素/结构/库级属性（GDSII PROPATTR/PROPVALUE、OASIS SEMI P39 PROPERTY）。
 *
 * 全部为**可选**字段：无属性的图元/结构不会带 `properties` 键，
 * 旧调用方与旧文档读到的对象与今日完全一致。
 *
 * `value` 的载体由 `dtype` 决定（native 侧编解码，双向一致）：
 *   dtype 6 (ASCII)  → 原文，已剥掉 GDS 偶数长度补 0（保存时逐字节复原）
 *   dtype 0 (无数据) → 恒空串（保存为 4 字节空头 PROPVALUE）
 *   dtype 2/3/4/5    → 可见 ASCII 字节为原文；含二进制字节时为 "#" + 大写十六进制（可逆）
 *   dtype 7          → 载体标记：ASCII 槽位里装着非文本字节，回读还原为 dtype 6
 * `name` 仅 OASIS 有值（GDSII 属性按数字属性码索引，恒空串）。
 */
export interface LayoutPropRecord {
  /** GDSII PROPATTR 属性码；0 = 孤立值（无前置属性码）/ OASIS 属性 */
  attr: number;
  /** GDSII PROPVALUE 数据类型码（0/2/3/4/5/6，7 为载体标记）；OASIS 为原始 P39 kind */
  dtype: number;
  /** OASIS PROPNAME；GDSII 恒为空串 */
  name: string;
  /** 属性值（载体形式见上） */
  value: string;
}

/** Ordered raw KLayout context payload. Hex contains bytes without a '#' prefix. */
export interface LayoutContextRecord { encoding: 'utf8' | 'hex'; value: string; }
export interface NativeLayoutPort {
  id: string; ownerCellId: number; ownerCellKey: string; name: string;
  centerNm: NativePoint; orientationDeg: number; widthNm: number;
  layerNumber: number; datatype: number; portType: string;
  frameMirror: boolean; frameMagnification: number;
  crossSectionKey?: string; crossSectionVersion?: number;
  infoJson: string; provenance?: string;
}
export interface NativeLayoutCrossSection {
  key: string; version: number; name: string; definitionJson: string;
  sourceFormat?: string; sourceVersion?: string;
}

/** 图层信息 */
export interface LayerInfo {
  /** 图层编号 (GDSII Layer Number / OASIS Layer Number) */
  layerNumber: number;
  /** 数据类型 (GDSII Datatype / OASIS Datatype) */
  datatype: number;
  /** 该图层上的图形数量 */
  elementCount: number;
  sourceName?: string;
}

export interface LayerNameInterval { type: number; lower: number; upper: number; }
export interface SourceLayerDefinition {
  name: string;
  textLayer: boolean;
  layer: LayerNameInterval;
  datatype: LayerNameInterval;
}
export interface QuantizationReport {
  dbuNm: number;
  examinedValueCount: number;
  quantizedValueCount: number;
  quantizedShapeCount: number;
  maximumDeviationNm: number;
}

/** 单元 (Cell) 信息 */
export interface CellInfo {
  /** 单元名称 */
  name: string;
  /** 单元内图形数量 */
  elementCount: number;
  /** 单元内使用的图层列表 */
  layers: LayerInfo[];
  /** 结构级属性（GDSII 结构 PROPATTR/PROPVALUE / OASIS 一般属性）；无属性时该键省略 */
  properties?: LayoutPropRecord[];
}

/** Native layout point in nm */
export interface NativePoint {
  x: number;
  y: number;
}

/** Native layout shape parsed from GDSII/OASIS */
export interface NativeShape {
  id: number;
  type: string;
  layerNumber: number;
  datatype: number;
  points: NativePoint[];
  pathWidth: number;
  /** PATH 端型（GDSII PATHTYPE）：0=flush、1=round、2=extended；写出侧省略即按 0 */
  pathType?: number;
  textPresentation?: number;
  /** Explicit signed PATH type 4 extensions in nm; negative WIDTH is absolute under MAG. */
  pathBeginExtension?: number;
  pathEndExtension?: number;
  pathWidthAbsolute?: boolean;
  /** Compressed AREF, vectors are in the owner cell coordinate frame (nm). */
  arrayCols?: number;
  arrayRows?: number;
  arrayColStepX?: number;
  arrayColStepY?: number;
  arrayRowStepX?: number;
  arrayRowStepY?: number;
  text: string;
  cellName: string;
  ownerCellId: number;
  cellId: number;
  rotation: number;
  mirror: number;
  magnification: number;
  /** 元素级属性（GDSII PROPATTR/PROPVALUE、OASIS PROPERTY）；无属性时该键省略 */
  properties?: LayoutPropRecord[];
}

/** 文件解析结果（GDSII 和 OASIS 通用） */
export interface GdsiiResult {
  /** 大版图（>8192 顶点）紧凑二进制坐标缓冲 [x0,y0,x1,y1,...]，避免跨 NAPI 创建数百万 JS 对象 */
  packedCoords?: Float64Array;
  shapePointOffsets?: Int32Array;
  shapePointCounts?: Int32Array;
  portCapabilityDiagnostics?: string[];
  cellKeys: string[];
  ports: NativeLayoutPort[];
  crossSections: NativeLayoutCrossSection[];
  layoutContextRecords: LayoutContextRecord[];
  cellContextRecords: LayoutContextRecord[][];
  /** 是否解析成功 */
  success: boolean;
  /** 错误信息（失败时） */
  errorMessage: string;
  /** 文件路径 */
  filePath: string;
  /** 文件大小（字节） */
  fileSize: number;
  /** 格式版本号（OASIS 为 0） */
  version: number;
  /** 库名称 */
  libName: string;
  /** 单元数量 */
  cellCount: number;
  /** 图形总数 */
  totalElements: number;
  /** 图层总数（去重后） */
  layerCount: number;
  /** 用户单位 */
  userUnits: number;
  /** 物理单位（米/用户单位） */
  physicalUnits: number;
  /** 单位描述文本 */
  unitDescription: string;
  /** 单元列表 */
  cells: CellInfo[];
  /** 未被其他 Cell 引用的 Top Cell 候选 ID */
  topCellIds: number[];
  /** 默认打开的 Top Cell ID；无 Cell 时为 -1 */
  primaryTopCellId: number;
  /** 所有图层汇总（去重） */
  allLayers: LayerInfo[];
  layerDefinitions?: SourceLayerDefinition[];
  /** Parsed layout shapes */
  shapes: NativeShape[];
  /** 库/数据库级属性；无属性时该键省略 */
  libProperties?: LayoutPropRecord[];
}

/** Native writeGdsii 结果 */
export interface GdsiiWriteResult {
  success: boolean;
  errorMessage: string;
  writtenCells: number;
  writtenShapes: number;
  skippedShapes: number;
  bytes: number;
  quantization?: QuantizationReport;
}

/** 渲染统计信息 */
export interface RenderStats {
  /** 原始图元数量 */
  primitives: number;
  /** 顶点总数 */
  vertices: number;
  /** 上一帧 CPU 提交耗时（毫秒），不含 GPU 完成时间 */
  frameTimeMs: number;
  ready?: boolean;
  batches?: number;
  drawCalls?: number;
  prepareTime?: number;
  uploadedBytes?: number;
  lodProxies?: number;
  lodDeduped?: number;
  lodScale?: number;
}

/** Small display table for native hierarchy-to-surface submission, with no geometry serialization. */
export interface NativeLayerRenderStyle {
  layerNumber: number;
  datatype: number;
  visible: boolean;
  color: number[];
  strokeOnly: boolean;
  /** 填充图案编码：0=实心，1=45°斜线(diagonal)，2=交叉网格(cross)，3=点阵(stipple) */
  fillPattern?: number;
}

export interface NativeRenderShape {
  id: number; type: string; layerNumber: number; datatype: number; points: NativePoint[];
  ownerCellId?: number; cellId?: number; cellName?: string;
  rotation?: number; mirror?: number; magnification?: number;
  pathWidth?: number; pathType?: number; pathBeginExtension?: number; pathEndExtension?: number;
  pathWidthAbsolute?: boolean; text?: string;
  arrayCols?: number; arrayRows?: number;
  arrayColStepX?: number; arrayColStepY?: number; arrayRowStepX?: number; arrayRowStepY?: number;
}

export interface NativeRenderSnapshot {
  cellNames: string[]; topCellId: number; shapes: NativeRenderShape[];
  packedCoords?: Float64Array | ArrayBuffer;
  shapePointOffsets?: Int32Array | ArrayBuffer;
  shapePointCounts?: Int32Array | ArrayBuffer;
  cellKeys?: string[]; ports?: NativeLayoutPort[]; crossSections?: NativeLayoutCrossSection[];
  layoutContextRecords?: LayoutContextRecord[]; cellContextRecords?: LayoutContextRecord[][];
}

/** Ordered read-only scene source. Points/translation are nm; DBU is not reapplied.
 * x'=a*x+b*y+tx, y'=c*x+d*y+ty. Caller resolves source layer masks into styles.
 * Every source is snapshotted explicitly; no active native database is borrowed.
 */
export interface NativeRenderSceneSource {
  sourceId: string;
  revision: number;
  snapshot: NativeRenderSnapshot;
  cellId: number;
  depth: number;
  transform: { a: number; b: number; c: number; d: number; tx: number; ty: number };
  opacity: number;
  styles: NativeLayerRenderStyle[];
}

/** 渲染图元类型 */
export type GLPrimitiveType =
  | 'rectFilled'
  | 'rectOutline'
  | 'polygonFilled'
  | 'polygonOutline'
  | 'lineStrip'
  | 'selectionBox';

/** 渲染批次（一个图层的一组同类型图元） */
export interface RenderBatch {
  pathWidth?: number;
  pathType?: number;
  pathBeginExtension?: number;
  pathEndExtension?: number;
  /** 图元类型 */
  type: GLPrimitiveType;
  /** 图层编号 */
  layerNumber: number;
  /** 数据类型 */
  datatype: number;
  /** 顶点坐标扁平缓冲区 [x0, y0, x1, y1, …]，优先采用 Float32Array 零拷贝直传，兼容 number[] */
  vertices: Float32Array | number[];
  /** RGBA 颜色 [r, g, b, a]，范围 0–1 */
  color: number[];
  /** 填充图案编码：0=实心，1=45°斜线(diagonal)，2=交叉网格(cross)，3=点阵(stipple) */
  fillPattern?: number;
  /** 是否选中（选中时填充更不透明） */
  selected: boolean;
}

// ==================== V2 Engine API ====================

/** 解析选项 */
export interface ParseOptions {
  isOasis?: boolean;
  quickScan?: boolean;
}

export interface NativeJobProgress {
  jobId: string; scope: string; kind: string; stage: string;
  status: 'running' | 'succeeded' | 'failed' | 'cancelled';
  completed: number; total: number; cancelRequested: boolean; message: string;
  terminal?: boolean; workerStarted?: boolean; workerStopped?: boolean;
}
export interface NativeImportEstimate {
  storedShapes: number; coordinates: number; instanceRecords: number; arrayMembers: number;
  expandedObjects: number; expandedPlacements: number; geometryBytes: number;
  bounded: boolean; withinBudget: boolean; message: string;
}
export interface NativeParseJobOptions extends ParseOptions {
  scope: string;
  /** Defaults true for normal opening. false parses GDSII/OASIS/CIF/DXF into
   * an independent result without replacing native layout or save caches. */
  publishToActive?: boolean;
}
export interface NativeJobScopeBox { minX: number; minY: number; maxX: number; maxY: number; }
export interface NativeDrcJobOptions {
  scope: string; documentId: string; inputVersion: number;
  ownerCellId: number; hierarchyDepth: number; mergeSameLayer: boolean;
  scopeBox?: NativeJobScopeBox;
}
export interface NativeParseJobResult {
  jobId: string; scope: string; status: 'succeeded' | 'failed' | 'cancelled'; message: string;
  terminal: boolean; workerStopped: boolean;
  result?: GdsiiResult; budget?: NativeImportEstimate;
}
export interface NativeDrcJobResult {
  jobId: string; scope: string; status: 'succeeded' | 'failed' | 'cancelled'; message: string;
  documentId?: string; inputVersion?: number; ownerCellId?: number;
  violations?: NativeDrcViolation[]; hierarchyDepthApplied?: number; budget?: NativeImportEstimate;
}
export interface NativeParseJob { jobId: string; scope: string; completion: Promise<NativeParseJobResult>; }
export interface NativeDrcJob { jobId: string; scope: string; completion: Promise<NativeDrcJobResult>; }

/** 布局统计信息 */
export interface LayoutStats {
  totalShapes: number;
  totalInstances: number;
  totalCells: number;
  totalLayers: number;
  bboxMinX: number;
  bboxMinY: number;
  bboxMaxX: number;
  bboxMaxY: number;
  topCellId: number;
  loaded?: boolean;
}

/** 布尔运算类型 */
export type BooleanOpType = 0 | 1 | 2 | 3; // INTERSECTION=0, UNION=1, DIFFERENCE=2, XOR=3

/** Join 类型 (offset) */
export type JoinType = 0 | 1 | 2; // MITER=0, SQUARE=1, ROUND=2

// DRC / LVS 类型均已接线：runDrc（drc_engine.h）与
// extractNets/runLvs/exportSpiceNetlist（lvs_engine.h，连通性级预检查）。

/** DRC 规则类型编码（与 native DrcRuleType 枚举顺序一致） */
export type NativeDrcRuleType = 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11;
// 0=MIN_WIDTH 1=MIN_SPACING 2=MAX_WIDTH 3=MIN_AREA 4=MAX_AREA
// 5=MIN_ENCLOSURE 6=MIN_OVERLAP 7=MAX_DENSITY 8=MIN_DENSITY 9=MIN_NOTCH
// 10=MIN_EXTENSION 11=DENSITY_UNIFORMITY

/** DRC 违规（坐标在 runDrc 本次检查的 Cell 坐标系下，单位 nm） */
export interface NativeDrcViolation {
  id: number;
  ruleName: string;
  ruleId: string;
  /** ruleId === 'DRC.TRUNC' 时为「层级展开图形数命中上限、结果不完整」的告警项，非规则违例 */
  message: string;
  x: number;
  y: number;
  value: number;
  limit: number;
  layer: number;
  datatype: number;
  shapeId1: number;
  shapeId2: number;
  /** true → 该违规位于 SREF/AREF 展开后的实例几何上；
   *  shapeId1/shapeId2 属于子 Cell，在当前 Cell 的图形列表里查不到，定位须用 x/y/bbox */
  fromInstance?: boolean;
  /** 图形真正归属的 Cell id（未展开时 = 当前 Cell） */
  sourceCellId?: number;
  /** 违规区域（native 侧按命中点 ±50nm 生成，用于高亮定位） */
  bboxMinX?: number;
  bboxMinY?: number;
  bboxMaxX?: number;
  bboxMaxY?: number;
  /** 本次 runDrc 的测量口径：'per-shape'（默认，逐图形）| 'merged-region'（同层布尔并后
   *  按区域测量）| 'merged-region+mixed'（请求了合并但有层未合并，结果为混合口径）。
   *  UI 必须把它显示出来——两种口径的「0 违例」含义不同，不可混为一谈。 */
  measureMode?: string;
  /** true → 该违例测的是合并后的区域（shapeId1/2 = -1，只能按 x/y/bbox 定位） */
  mergedRegion?: boolean;
  /** true → 有层没能参与合并（超限/引擎降级），已同时给出 ruleId='DRC.MERGE' 告警项 */
  mergeSkipped?: boolean;
  /** 本次合并得到的区域总数（口径诊断用） */
  mergedRegionCount?: number;
}

/** DRC 规则 */
export interface NativeDrcRule {
  id: string;
  name: string;
  type: number;
  layer1: number;
  datatype1: number;
  /** Explicit zero matches datatype 0; omitted retains the legacy zero wildcard. */
  exactDatatype1?: boolean;
  layer2: number;
  datatype2: number;
  exactDatatype2?: boolean;
  value: number;
  value2: number;
  enabled: boolean;
}

/**
 * via/contact 跨层连通配置（一层 via 一座桥）。
 * native 侧三字段必须**同时存在且为 number**，缺项的条目会被直接丢弃
 * （不会把缺失字段当成 0 层，避免造出不存在的 0 层连通规则）。
 */
export interface NativeViaLayer {
  viaLayer: number;
  lowerLayer: number;
  upperLayer: number;
  /** Exact purpose matching; omitted/-1 retains legacy all-datatype behavior. */
  viaDatatype?: number;
  lowerDatatype?: number;
  upperDatatype?: number;
}

/**
 * 网络 (Net)
 * id / shapeIds 为 native int64：napi_create_int64 落到 JS 侧是 IEEE-754 double，
 * 安全整数区间 ±2^53。本引擎的 shape id / net id 均由 Scene/Layout 顺序自增分配
 * （从 1 起），实际不可能越过 2^53，故不引入 BigInt；若日后接入外部（GDS 句柄级）
 * id，必须改走 napi_create_bigint_int64 并同步本文件类型。
 */
export interface NativeNet {
  id: number;
  name: string;
  shapeIds: number[];
  layers: number[];
  pinCount: number;
  /** 成员含实例展开图形；shapeIds 不含实例路径，须使用根 Cell bbox 定位 */
  fromInstance?: boolean;
  /** 该网承载的全部标签名；length > 1 即「一网多网名」= 潜在短路 */
  labels: string[];
  bboxMinX: number;
  bboxMinY: number;
  bboxMaxX: number;
  bboxMaxY: number;
}

/**
 * LVS 结果（连通性级预检查，**非签核**）
 * status 为机器可读状态，UI 必须据此区分「未运行」与「不匹配」：
 *   not-run          未执行
 *   no-netlist       缺参考网表（参数缺失/非字符串/空白）
 *   empty-schematic  参考网表解析不出网络（格式不支持或畸形）
 *   empty-layout     版图中当前过滤范围 0 网络
 *   no-layout        native 侧无已加载布局
 *   pass / mismatch  已比对
 * **空网表与零网络一律 matched=false**：空结果永不得记为 LVS 通过。
 */
export interface NativeLvsResult {
  matched: boolean;
  /** 是否真正执行了比对（false = 前置条件不满足，计数不可信） */
  ran: boolean;
  status: string;
  /** 未运行原因（status 为 pass / mismatch 时为空串） */
  error: string;
  layoutNetCount: number;
  schematicNetCount: number;
  matchedNets: number;
  /** 一个物理网承载 ≥2 个参考网名，形如 "VDD<->GND" */
  shortNets: string[];
  /** 参考网表有、版图无（未标签或确实断开） */
  openNets: string[];
  /** 版图具名、参考网表无（多余网络/意外合并） */
  extraNets: string[];
  messages: string[];
}

/** 图像导出的图层样式（导出上色/显隐） */
export interface ExportLayerStyle {
  layerNumber: number;
  datatype?: number;
  /** '#RRGGBB' */
  color?: string;
  visible?: boolean;
  /** 透明度 0–1（KLayout 语义：0=不透明，1=全透）；省略则保留图层原值 */
  transparency?: number;
  /** 描边宽度（像素，>0）；省略则保留图层原值 */
  lineWidth?: number;
  /** 0=solid 1=dashed 2=dotted 3=dotdash；省略则保留图层原值 */
  lineStyle?: number;
  /** 0=solid 1=outline/hollow 2=diagonal 3=cross；省略则保留图层原值 */
  fillPattern?: number;
}

/** 图像导出结果 */
export interface ImageExportResult {
  success: boolean;
  errorMessage: string;
  bytes: number;
}

/** PCell 参数声明（GUI 动态表单用） */
export interface PCellParamInfo {
  name: string;
  displayName: string;
  /** 'int' | 'double' | 'string' | 'boolean' | 'list' | 'layer' */
  type: string;
  defaultValue: number | string | boolean;
  minValue: number | string | boolean;
  maxValue: number | string | boolean;
  unit: string;
}

/** PCell 声明信息 */
export interface PCellInfo {
  name: string;
  displayName: string;
  description: string;
  category: string;
  params: PCellParamInfo[];
}

/** PCell 生成结果 */
export interface PCellGenerateResult {
  /** Declared generator interfaces only; owner identity is reconciled by the document transaction. */
  ports: NativeLayoutPort[];
  success: boolean;
  errorMessage: string;
  shapes: NativeShape[];
}

/** 鸿图原生模块接口 */
export interface NativeSyncResult { success: boolean; errorMessage: string; portCapabilityDiagnostics?: string[]; }
export interface NativeLayoutCompareOptions {
  cellA: string;
  cellB: string;
  offsetX: number;
  offsetY: number;
  gridNm: number;
}
export interface NativeCompareJobOptions extends NativeLayoutCompareOptions { scope: string; }
export interface NativeCompareJobResult {
  jobId: string; scope: string; status: 'succeeded' | 'failed' | 'cancelled'; message: string;
  terminal: boolean; workerStopped: boolean; result?: NativeLayoutCompareResult;
}
export interface NativeCompareJob { jobId: string; scope: string; completion: Promise<NativeCompareJobResult>; }
export interface NativeLayoutCompareLayer {
  layerNumber: number;
  datatype: number;
  areaOnlyA: number;
  areaOnlyB: number;
  xorArea: number;
  minX: number;
  minY: number;
  maxX: number;
  maxY: number;
  contourCount: number;
  previewTruncated: boolean;
  contours: NativePoint[][];
}
export interface NativeStructureDifference {
  cellName: string;
  category: string;
  onlyInA: number;
  onlyInB: number;
}
export interface NativeLayoutCompareResult {
  success: boolean;
  complete: boolean;
  geometryEqual: boolean;
  structureEqual: boolean;
  errorMessage: string;
  cellA: string;
  cellB: string;
  gridNm: number;
  elapsedMs: number;
  comparedLayers: number;
  layers: NativeLayoutCompareLayer[];
  structureDifferences: NativeStructureDifference[];
}


export interface NativeEmbeddedPythonInfo {
  available: boolean;
  hasCPython: boolean;
  activeTier: string;
  version: string;
  summary: string;
}

export interface NativeEmbeddedPythonRequest {
  script: string;
  inputMode?: string;
  sourceGdsPath?: string;
  selectionGdsPath?: string;
  currentCellName?: string;
  parametersJson?: string;
  outputGdsPath?: string;
  outputSvgPath?: string;
  cpythonHomeDir?: string;
  timeoutMs?: number;
}

export interface NativeEmbeddedPythonLayerDef {
  layerNumber: number;
  datatype: number;
  name: string;
}

export interface NativeEmbeddedPythonPortDef {
  id: string;
  ownerCellId: number;
  ownerCellKey: string;
  name: string;
  xNm: number;
  yNm: number;
  orientationDeg: number;
  widthNm: number;
  layerNumber: number;
  datatype: number;
  portType: string;
}

export interface NativeEmbeddedPythonResult {
  success: boolean;
  engineTier: string;
  engineVersion: string;
  errorMessage: string;
  fileName: string;
  outputGdsPath: string;
  outputSvgPath: string;
  previewSvg: string;
  stdoutText: string;
  cellCount: number;
  shapeCount: number;
  expandedShapeCount: number;
  layerCount: number;
  gdsBytes: number;
  cellNames: string[];
  layerDefinitions: NativeEmbeddedPythonLayerDef[];
  ports: NativeEmbeddedPythonPortDef[];
}

export interface HongTuNative {
  startParseJob(filePath: string, options: NativeParseJobOptions): NativeParseJob;
  startDrcJob(snapshot: NativeRenderSnapshot, rules: NativeDrcRule[], options: NativeDrcJobOptions): NativeDrcJob;
  startCompareJob(document: Object, filePathB: string, options: NativeCompareJobOptions): NativeCompareJob;
  getJobProgress(jobId: string, scope: string): NativeJobProgress | undefined;
  cancelJob(jobId: string, scope: string): boolean;
  /** Atomically publish current document in memory; does not save or mark clean. */
  syncDocument(document: Object): NativeSyncResult;
  /** B is independently parsed on a worker and cannot replace the active document. */
  compareLayout(document: Object, filePathB: string, options: NativeLayoutCompareOptions): Promise<NativeLayoutCompareResult>;
  // ===== 文件解析 (同步, 兼容旧接口) =====
  /** 完整解析 GDSII 文件 */
  parseGdsii(filePath: string): GdsiiResult;
  /** 快速获取 GDSII 文件概要信息 */
  quickInfo(filePath: string): GdsiiResult;
  /** 完整解析 OASIS 文件 */
  parseOasis(filePath: string): GdsiiResult;
  /** 快速获取 OASIS 文件概要信息 */
  quickOasisInfo(filePath: string): GdsiiResult;
  /** 解析 CIF (Caltech Intermediate Form) 文件（厘微米→nm） */
  parseCif(filePath: string): GdsiiResult;
  /** 解析 DXF (AutoCAD R12 ASCII 子集) 文件（1 单位=1µm→nm） */
  parseDxf(filePath: string): GdsiiResult;

  /**
   * 将当前 native Layout / 最近解析结果结构化写出到 filePath。
   * 无已加载布局时 success=false。
   */
  writeGdsii(filePath: string): GdsiiWriteResult;

  /**
   * 用 ArkTS 文档对象写出 GDS（含编辑后 shapes），并同步 g_layout。
   * document: { libName, userUnits, physicalUnits, topCellId, cellNames, shapes[],
   *             libProperties?, cellProperties?, }
   * shapes[].points 为扁平 [x0,y0,...]
   * shapes[].properties?: LayoutPropRecord[] / cellProperties?: LayoutPropRecord[][]（与 cellNames 同索引）
   * / libProperties?: LayoutPropRecord[] 三处**全部可选**：省略即与旧行为一致（不写属性记录）；
   * 提供时按 GDSII PROPATTR/PROPVALUE 成对写回，畸形条目逐条忽略、每归属者最多 64 条。
   */
  writeGdsiiDocument(filePath: string, document: Object): GdsiiWriteResult;

  /**
   * 将最近解析结果 / g_layout 快照写出为 OASIS（SEMI P39）：
   * 名称表 + modal 压缩 + PLACEMENT 17/18 + 规范 256 字节 END + CRC32。
   * 无已加载布局时 success=false。
   */
  writeOasis(filePath: string): GdsiiWriteResult;

  // ===== 文件解析 (异步, v2) =====
  /** 异步解析文件 (自动检测格式), 返回 Promise */
  parseAsync(filePath: string, options?: ParseOptions): Promise<GdsiiResult>;

  /**
   * KLayout 语义层级展开：从 cellId 出发按 hierarchyDepth 递归变换子 Cell 几何。
   * depth=1 仅本地；depth=N 展开 N-1 层实例几何。返回变换后的 NativeShape 列表。
   */
  expandHierarchy(cellId: number, hierarchyDepth: number): NativeShape[];

  /**
   * 展开并生成 GL RenderBatch（可选世界视口裁剪）。
   * 视口无效（minX>maxX 等）时不做裁剪。
   */
  expandHierarchyToBatches(
    cellId: number,
    hierarchyDepth: number,
    minX?: number,
    minY?: number,
    maxX?: number,
    maxY?: number
  ): RenderBatch[];

  // ===== 空间查询 =====
  /** 点查询: 返回包含 (x,y) 的所有形状 ID */
  queryPoint(x: number, y: number): number[];
  /** 范围查询: 返回与矩形区域相交的所有形状 ID */
  queryRange(x0: number, y0: number, x1: number, y1: number): number[];
  /** 最近邻查询: 返回距 (x,y) 最近的 k 个形状 ID */
  queryNearest(x: number, y: number, k: number): number[];

  // ===== 布尔运算（官方 Clipper2；整数 nm 网格，不等于工艺签核）=====
  /**
   * 多边形布尔运算。后端已换成通用多边形引擎：凹形、带孔、多轮廓、共边/单点相切、
   * 顶点落在边上、两算子重合等退化配置都按一般位置处理，返回**多条**结果轮廓
   * （区域恒在每条轮廓的左侧：外轮廓逆时针、孔顺时针）。
   * @param subject 主体多边形顶点 [x0,y0,x1,y1,...]
   * @param clip 裁剪多边形顶点 [x0,y0,x1,y1,...]
   * @param opType 运算类型: 0=交, 1=并, 2=差, 3=异或
   * @returns 结果轮廓数组 [[x0,y0,...], ...]
   */
  booleanOp(subject: number[], clip: number[], opType: BooleanOpType): number[][];
  /**
   * 同上，附带完成状态；approximated=true 表示请求被拒绝/失败，无部分结果。
   * 成功结果仍有整数 DBU 量化，不能据此宣称无量化或工艺签核。
   */
  booleanOpEx(
    subject: number[],
    clip: number[],
    opType: BooleanOpType
  ): { contours: number[][]; approximated: boolean; note: string; droppedRings: number };
  /**
   * Clipper2 多边形偏移（size/shrink），支持分裂、自合并和孔洞。
   * @param points 多边形顶点 [x0,y0,x1,y1,...]
   * @param delta 偏移量 (正=膨胀, 负=收缩), 单位 nm
   * @param joinType 0=miter, 1=square, 2=round
   * @returns 第一条（面积最大的）轮廓顶点数组；需要全部轮廓请用 offsetPolygons
   */
  offsetPolygon(points: number[], delta: number, joinType: JoinType): number[];
  /** 同上，但返回**全部**结果轮廓（自合并后的 U 形可能是一条，也可能是一片孤岛） */
  offsetPolygons(points: number[], delta: number, joinType: JoinType): number[][];
  /** 编辑专用：返回可独立填充的无孔多边形；整数 nm 输入，无零宽桥。
   * 分解经区域 XOR 校验；失败抛错，[] 是有效空集，调用方不得混淆两者。 */
  booleanOpForEdit(subject: number[], clip: number[], opType: BooleanOpType): number[][];
  /** Whole independently filled regions, quantized to an explicit nm grid.
   * Fractional nm accepted; result holes are fractured. Failure throws. */
  regionBooleanForEdit(subject: number[][], clip: number[][], opType: BooleanOpType, gridNm: number): number[][];
  /** Local physical nm geometry. Absolute GDS WIDTH is divided by cumulative
   * worldScale; TYPE4 extensions retain local lengths. Round caps use 8 segments
   * per semicircle, matching painted PATH rendering, then explicit grid rounding. */
  pathRegionForEdit(points: number[], widthNm: number, pathType: number, beginExtensionNm: number,
    endExtensionNm: number, worldScale: number, widthAbsolute: boolean, gridNm: number): number[][];
  /** Whole continuous DPath contour, quantized once. Simple contours only; ROUND
   * uses 16 segments per semicircle. Complex topology throws, with no painted-strip fallback. */
  pathRegionWholeDPathSimple(points: number[], widthNm: number, pathType: number, beginExtensionNm: number,
    endExtensionNm: number, worldScale: number, widthAbsolute: boolean, gridNm: number): number[][];
  /** 先合并同一 layer/datatype 的选中多边形，再偏移整个区域，保留孔洞。 */
  offsetPolygonsForEdit(polygons: number[][], delta: number, joinType: JoinType): number[][];

  // ===== 几何查询（部分依赖 experimental 几何引擎）=====
  /** 计算两个多边形之间的真实边到边距离 (nm)（experimental） */
  polygonDistance(pointsA: number[], pointsB: number[]): number;
  /** 计算多边形面积 (nm²) */
  polygonArea(points: number[]): number;
  /** 点在多边形内判定: +1=内部, 0=边界, -1=外部 */
  pointInPolygon(x: number, y: number, points: number[]): number;

  // ===== 布局管理 =====
  /** 获取当前加载布局的统计信息 */
  getLayoutStats(): LayoutStats;

  // ===== 原生 DRC（深度可控层级展开的几何预检查；非签核）=====
  /**
   * 在已加载布局上运行 DRC 规则检查。
   * R-Tree 邻域加速 + 真实边到边距离；RECT 2 点对角线自动归一化。
   * @param rules 规则列表（type 见 NativeDrcRuleType 编码注释）
   * @param ownerCellId 仅检查该 Cell 的本地几何；省略或 -1 = 全部 Cell
   * @param hierarchyDepth 尾选参数（省略 = 0，向后兼容）：
   *        0 = 仅本地几何（旧「快速预检查」口径）；
   *        ≥1 = 先把 SREF/AREF 实例内几何按实例矩阵变换到被检查 Cell 的坐标系再检查
   *        （1 = KLayout 风格默认深度，更大值继续向下展开，native 侧上限 16 层）。
   *        根 Cell 取 ownerCellId，其次 topCell；无法解析时退回 depth=0 本地口径。
   *        展开图形数命中上限时结果不完整，会额外返回 ruleId='DRC.TRUNC' 的告警项。
   * @param mergeSameLayer 尾选参数（省略/0 = 关闭，向后兼容）：1 = merged-region 口径，
   *        每层（按 datatype 分桶）同层图形先做真实布尔并，再按合并后的区域测宽度/间距/面积。
   *        这才能抓到「只有合并后才显现」的细腰（例：两个 100×100 方块错位 60 叠成阶梯，
   *        逐图形各宽 100 全过规则，合并后通道宽 40√2≈56.6 → 违例）。
   *        没能合并的层不静默：额外返回 ruleId='DRC.MERGE' 告警项，measureMode 变 'mixed'。
   * @returns 违规列表；无已加载布局时为空数组。hierarchyDepth>0 时 x/y 在**该 Cell 坐标系**下；
   *          merged 区域的违例 shapeId1/2 = -1（合成条目，画布按 id 查不到，只能用 x/y 定位）
   */
  runDrc(
    rules: NativeDrcRule[],
    ownerCellId?: number,
    hierarchyDepth?: number,
    mergeSameLayer?: number | boolean
  ): NativeDrcViolation[];

  // ===== LVS / 网络提取（连通性级预检查，非签核）=====
  /**
   * 提取连通网络：同层交叠/接触 + via 跨层（可选配置）+ TEXT 标签命名。
   * @param viaLayers 工艺连通表；省略/空数组 = 仅同层连通（不做跨层）
   * @param ownerCellId 仅提取该 Cell 本地几何；省略或 -1 = 全部
   * @returns 网络数组；**native 侧无已加载布局时返回 undefined**
   *          （区别于「布局确实 0 网」的空数组，调用方须两者分别处理）
   */
  extractNets(viaLayers?: NativeViaLayer[], ownerCellId?: number, hierarchyDepth?: number): NativeNet[] | undefined;
  /**
   * 连通性级 LVS：与 SPICE 参考网表按网名比对（依赖版图 TEXT 标签）。
   * 结果始终为对象；未执行时 ran=false 且 status 给出原因（见 NativeLvsResult）。
   */
  runLvs(schematicNetlist: string, viaLayers?: NativeViaLayer[],
         ownerCellId?: number, hierarchyDepth?: number): NativeLvsResult | undefined;
  /** 导出提取网表为 SPICE 文本；无已加载布局时返回 undefined */
  exportSpiceNetlist(viaLayers?: NativeViaLayer[], ownerCellId?: number, hierarchyDepth?: number): string | undefined;

  // ===== 图像导出（SVG 矢量 / PNG 软件光栅；INSTANCE/TEXT 不渲染）=====
  /** 导出当前布局为 SVG（尺寸按设计 bbox 等比适配到 maxWidth×maxHeight 内） */
  exportSvg(filePath: string, maxWidth: number, maxHeight: number,
            layers?: ExportLayerStyle[]): ImageExportResult;
  /** 导出当前布局为 PNG（width×height 像素，等比居中） */
  exportPng(filePath: string, width: number, height: number,
            layers?: ExportLayerStyle[]): ImageExportResult;

  // ===== PCell（参数化单元）=====
  /** 列出内置 PCell（Basic circle/donut/arc + MOSFET/VIA_STACK/GUARD_RING） */
  listPCells(): PCellInfo[];
  /**
   * 按参数生成 PCell 几何（在 native 临时布局中生成，不修改当前文档快照）。
   * 返回图形坐标以 PCell 局部原点为基准，由调用方放入目标 Cell。
   */
  generatePCell(name: string, params: Record<string, number | string | boolean>): PCellGenerateResult;

  // ===== 版本 =====
  /** 获取鸿图核心版本号 */
  version(): string;
  getEmbeddedPythonInfo(cpythonHomeDir?: string): NativeEmbeddedPythonInfo;
  runEmbeddedPythonAsync(request: NativeEmbeddedPythonRequest): Promise<NativeEmbeddedPythonResult>;

  // ===== OpenGL ES 渲染 =====
  registerXComponent(xComponent?: object): void;
  setRenderData(batches: RenderBatch[]): void;
  setCamera(scaleX: number, scaleY: number, offsetX: number, offsetY: number,
            viewportW: number, viewportH: number): void;
  /** 设置清屏色（RGBA 各分量 0..1），线程安全并自动请求重绘。 */
  setBackgroundColor(r: number, g: number, b: number, a: number): void;
  requestRedraw(): void;
  getRenderStats(): RenderStats;
  renderHierarchyToSurface(cellId: number, hierarchyDepth: number,
    minX: number, minY: number, maxX: number, maxY: number,
    styles: NativeLayerRenderStyle[], snapshot?: NativeRenderSnapshot): boolean;
  /** Atomically submit at most 65 ordered sources to one surface; [] clears.
   * Invalid/budget-exceeding scenes clear a ready surface and throw. False means
   * the surface was unavailable. Geometry/expanded budgets apply across sources.
   */
  renderSceneToSurface(sources: NativeRenderSceneSource[],
    minX: number, minY: number, maxX: number, maxY: number): boolean;
  /** Release this environment's source references/layouts/scene allocations,
   * and clear CPU render batches even if EGL is unavailable. False reports an
   * unavailable surface; the cache is still fully released in that case.
   */
  clearRenderScene(): boolean;
}

declare const hongtu: HongTuNative;
export default hongtu;
