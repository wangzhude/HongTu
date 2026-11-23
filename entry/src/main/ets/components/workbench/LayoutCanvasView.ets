import { MeasureText, matrix4, PathShape } from '@kit.ArkUI';
import { ActiveTool } from '../../workbench/WorkbenchModels';
import { Shape, ShapeType, ShapeBounds, getShapeBounds,
  hasKeyholeBridgeEdges,
  extractKeyholeCleanLoops, Point } from '../../models/GdsiiData';
import { getPathGeometryBounds } from '../../services/PathBoundsService';
import type { PathBoundsTransform } from '../../services/PathBoundsService';
import { UiLayer } from '../../common/types';
import {
  canvasTransformConsistent,
  COLORS,
  formatZoomPercent,
  MOUSE_DRAG_SLOP_VP,
  MOUSE_POLY_DBLCLICK_SLOP_VP,
  RECT_HANDLE_AUTO_MIN_SPAN_VP,
  RECT_HANDLE_FULL_HIT_SPAN_VP,
  RECT_INTERIOR_MOVE_MIN_RATIO,
  screenToWorldPx,
  screenToWorldYpx,
  TOUCH_DRAG_SLOP_VP,
  TOUCH_POLY_DBLCLICK_SLOP_VP,
  umText,
  worldToScreenPx,
  worldToScreenYpx
} from '../../common/constants';
import { hongTuThemeState, ZIndexTokens } from '../../store/ThemeStore';
import { panelTransition } from '../../common/Motion';
import { isShiftHeld, isCtrlHeld, isAltHeld, isModalKeyboardBlocked, resetModifierKeys, setShiftHeld, setCtrlHeld, setAltHeld } from '../../common/ModifierKeys';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { GlCanvas } from '../GlCanvas';
import type { ViewSceneSource, ViewScenePrimitive, ViewSceneDrawResult } from '../../models/ViewRenderScene';
import { ViewRenderSceneService, sceneViewportFromCamera } from '../../services/ViewRenderSceneService';
import { SCENE_TEXT_FONT_SIZE, SCENE_TEXT_LINE_HEIGHT } from '../../models/ViewRenderScene';
import { PortOverlay } from './PortOverlay';
import { ResolvedPort, PortEndpoint } from '../../models/LayoutPort';
import { editService } from '../../services/EditService';
import type { InstancePathStep } from '../../services/EditService';
import { advEditService, VertexEditResult } from '../../services/AdvancedEditService';
import { viewService } from '../../services/ViewService';
import { AlignmentGuide, RichSnapResult, SpatialSnapIndex, snapService } from '../../services/SnapService';
import { RoutedSegmentResult, RoutingMode, routingConstraintService } from '../../services/RoutingConstraintService';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import {
  draftCanvasEngine,
  DraftControlStore,
  DraftGhostOutline,
  DraftLoupeShape,
  DraftStampTemplate,
} from '../../store/DraftOverlayStore';
import { StableSegmentButton } from '../StableSegmentButton';
import { showAppSnackBar } from '../AppSnackBar';
import { buildLuminousMenuOptions } from '../../store/LuminousSurfaceOptions';
import { menuCheckIcon, menuIcon, MENU_ITEM_STYLE, menuStyle } from '../../common/WorkbenchMenuStyle';
import { DraftOverlayLayer } from './DraftOverlayLayer';
import { shortcutService } from '../../services/ShortcutService';
import { expandCellShapes, isExpandedSyntheticShape, expandAndCullCellShapes, expandAndCullCellShapesBounded, BoundedHierarchyDrawResult, WorldViewport, worldViewportFromCamera, applyLodToShapes, HierarchyBoundsResolver, HierarchyBoundsResult, HierarchyHitResult, HierarchyHitCandidate, HierarchyCandidatesResult } from '../../services/HierarchyExpandService';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { MoveFineTuneDialog } from '../dialogs/MoveFineTuneDialog';
import { TextCreateDialog } from '../dialogs/TextCreateDialog';
import { ALPHA, BLUR_BY_LAYER, LayerRenderStyle, layerRenderStyle, withAlpha } from '../../common/MaterialTokens';
import { CursorStore, MeasureAnnotation, MeasureAreaAnnotation, MeasureStore, RulerLine, VertexStore } from '../../common/UiStores';

/** 矩形绘制预览框（用户坐标 nm） */
interface PreviewRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface RoutedSnapPreview {
  rich: RichSnapResult;
  routed: RoutedSegmentResult;
}

interface FixedRectDimensions {
  w: number;
  h: number;
}

/** 框选矩形（屏幕坐标 px） */
interface BoxSelectRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface ScreenSpanBox {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
  spanW: number;
  spanH: number;
}

interface RectHandleHit {
  isEdge: boolean;
  index: number;
}

/** violation 高亮区域（用户坐标 nm）；DrcViolation 无 w/h，故用本地结构承载矩形区域。
 *  导出供 Index.ets 构造后通过 prop 传入。 */
export interface ViolationHighlight {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 面包屑节点 */
interface BreadcrumbItem {
  label: string;
  cellId: number;
}

interface GridLinePosition {
  position: number;
  index: number;
  major: boolean;
  origin: boolean;
}

// Presentation budgets are checked for the complete frame before creating any
// hatch Path. The polygon/instance definitions and stored geometry are borrowed.
const SCENE_HATCH_STEP_VP: number = 8;
const SCENE_HATCH_LINE_LIMIT: number = 32768;
const SCENE_HATCH_CLIP_VERTEX_LIMIT: number = 200000;
const SCENE_HATCH_COMMAND_LIMIT: number = 32 * 1024 * 1024;
const SCENE_HATCH_VERTEX_COMMAND_RESERVE: number = 144;
const SCENE_HATCH_SEGMENT_COMMAND_RESERVE: number = 288;

interface SceneHatchRegion {
  left: number;
  top: number;
  width: number;
  height: number;
  localLeft: number;
  localTop: number;
  minX: number;
  maxY: number;
}

function sceneHatchRegion(primitive: ViewScenePrimitive, canvasWidth: number, canvasHeight: number,
  zoomPercent: number, offsetX: number, offsetY: number): SceneHatchRegion | undefined {
  if (primitive.kind === 'text' || primitive.hierarchyFrame === true ||
    primitive.style.hatch.length === 0 || primitive.points.length < 3 ||
    primitive.opacity <= 0 || primitive.style.fillOpacity <= 0) return undefined;
  const b: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
  for (const p of primitive.points) {
    b.minX = Math.min(b.minX, p.x); b.maxX = Math.max(b.maxX, p.x);
    b.minY = Math.min(b.minY, p.y); b.maxY = Math.max(b.maxY, p.y);
  }
  const z: number = zoomPercent / 100;
  const x: number = worldToScreenPx(b.minX, zoomPercent, offsetX);
  const y: number = worldToScreenYpx(b.maxY, zoomPercent, offsetY);
  const nodeWidth: number = Math.max(0.01, (b.maxX - b.minX) * z);
  const nodeHeight: number = Math.max(0.01, (b.maxY - b.minY) * z);
  if (![canvasWidth, canvasHeight, z, x, y, nodeWidth, nodeHeight].every((n: number): boolean =>
    Number.isFinite(n)) || canvasWidth < 0 || canvasHeight < 0 || z <= 0) {
    throw new Error('图案投影视口无效');
  }
  const localLeft: number = Math.max(0, -x); const localTop: number = Math.max(0, -y);
  const right: number = Math.min(nodeWidth, canvasWidth - x);
  const bottom: number = Math.min(nodeHeight, canvasHeight - y);
  if (right <= localLeft || bottom <= localTop) return undefined;
  return { left: x + localLeft, top: y + localTop,
    width: right - localLeft, height: bottom - localTop, localLeft, localTop,
    minX: b.minX, maxY: b.maxY };
}

function sceneHatchLineCount(region: SceneHatchRegion, cross: boolean): number {
  const first: number = Math.ceil((region.left + region.top) / SCENE_HATCH_STEP_VP);
  const last: number = Math.floor((region.left + region.width + region.top + region.height) / SCENE_HATCH_STEP_VP);
  let count: number = Math.max(0, last - first + 1);
  if (cross) {
    const crossFirst: number = Math.ceil((region.left - region.top - region.height) / SCENE_HATCH_STEP_VP);
    const crossLast: number = Math.floor((region.left + region.width - region.top) / SCENE_HATCH_STEP_VP);
    count += Math.max(0, crossLast - crossFirst + 1);
  }
  if (!Number.isSafeInteger(count) || count < 0) throw new Error('图案线段数量无效');
  return count;
}

function verifySceneHatchBudget(scene: ViewSceneDrawResult, canvasWidth: number, canvasHeight: number,
  zoomPercent: number, offsetX: number, offsetY: number, density: number): void {
  if (!Number.isFinite(density) || density <= 0) throw new Error('图案像素换算无效');
  let lines: number = 0; let vertices: number = 0;
  for (const primitive of scene.primitives) {
    const region: SceneHatchRegion | undefined = sceneHatchRegion(primitive, canvasWidth, canvasHeight,
      zoomPercent, offsetX, offsetY);
    if (region === undefined) continue;
    lines += sceneHatchLineCount(region, primitive.style.hatch === 'cross');
    vertices += primitive.points.length;
    // Conservative space for two coordinates/vertex and four/segment, including
    // command letters, separators and contour closure. Coordinates are checked
    // below before constructing either complete command string.
    if (lines > SCENE_HATCH_LINE_LIMIT || vertices > SCENE_HATCH_CLIP_VERTEX_LIMIT ||
      SCENE_HATCH_VERTEX_COMMAND_RESERVE * vertices + SCENE_HATCH_SEGMENT_COMMAND_RESERVE * lines >
      SCENE_HATCH_COMMAND_LIMIT) {
      throw new Error('图案绘制超出完整帧预算，请放大局部或降低层级');
    }
    const z: number = zoomPercent / 100;
    for (const p of primitive.points) {
      const px: number = ((p.x - region.minX) * z - region.localLeft) * density;
      const py: number = ((region.maxY - p.y) * z - region.localTop) * density;
      if (!Number.isFinite(px) || !Number.isFinite(py) || px.toString().length > 64 || py.toString().length > 64) {
        throw new Error('图案裁剪坐标或数值表示溢出');
      }
    }
  }
}

/** 顶部浮动栏占用的屏幕高度阈值：触摸落点 y 小于该值视为命中浮动栏，不触发画布手势 */
const TOP_BAR_THRESHOLD: number = 96;
/** 长按判定阈值（ms）：Move 工具按下超过该时长且有位移时，释放弹出微调框 */
const LONG_PRESS_THRESHOLD: number = 500;
const DOUBLE_CLICK_THRESHOLD: number = 500;
const GRID_MIN_SCREEN_SPACING: number = 28;
const GRID_MAX_SCREEN_SPACING: number = 96;
const GRID_MAJOR_INTERVAL: number = 5;
/** 光标命中测试最小间隔（ms）：hitTest 回退路径为全图线性扫描，需节流 */
const CURSOR_HIT_THROTTLE_MS: number = 60;
/** 标尺拖拽判定阈值（屏幕 px）：小于该位移视为单击，落水平标尺 */
const RULER_DRAG_MIN_PX: number = 12;
/** 测量/标尺模式条占用的屏幕高度（px）：落点在此范围内视为命中模式条，不参与测量/标尺 */
const BOTTOM_STRIP_HEIGHT: number = 52;
/** tan(22.5°)：Shift 约束下"更接近对角还是轴向"的判定阈值 */
const ORTHO_TAN_HALF_45: number = 0.41421356;
/** 测量线段包围盒留白（屏幕 px，供 Polyline 端点圆角/线宽外溢） */
const MEASURE_LINE_PAD: number = 6;
/** 测量读数标签预估宽度（屏幕 px），用于把标签夹在画布内 */
const MEASURE_LABEL_W: number = 260;
/** 顶点句柄命中盒半边长（屏幕 px）：触屏友好，远大于绘制尺寸 */
const VERTEX_HANDLE_HIT_PX: number = 22;
/** 顶点句柄绘制边长（vp） */
const VERTEX_HANDLE_PX: number = 13;
/** 边中点插入柄绘制尺寸（vp） */
const VERTEX_INSERT_PX: number = 12;
/** 顶点编辑模式条占用高度（屏幕 px）：落点在其内让位给按钮 */
const VERTEX_STRIP_HEIGHT: number = 46;
/** 顶点句柄/预览描边色（KLayout 顶点编辑用亮黄） */
const VERTEX_COLOR: string = '#FFD700';

function isWhiteCanvas(effectiveIsDark?: boolean): boolean {
  if (effectiveIsDark !== undefined) {
    return !effectiveIsDark;
  }
  return !hongTuThemeState.isDark && COLORS.canvasBg === '#FFFFFF';
}

function canvasSelectionStroke(): string {
  return isWhiteCanvas() ? COLORS.primary : '#FFFFFF';
}

function canvasOverlayBackground(): string {
  return isWhiteCanvas() ? withAlpha('#FFFFFF', 0.92) : withAlpha('#0B0E14', 0.56);
}

function canvasOverlayBorder(): string {
  return isWhiteCanvas() ? COLORS.border : withAlpha('#FFFFFF', 0.10);
}

function canvasOverlayInk(): string {
  return isWhiteCanvas() ? COLORS.ink : '#FFFFFF';
}

function canvasOverlayMuted(): string {
  return isWhiteCanvas() ? COLORS.muted : withAlpha('#FFFFFF', 0.72);
}

function canvasOverlaySubtle(): string {
  return isWhiteCanvas() ? COLORS.muted : withAlpha('#FFFFFF', 0.55);
}

function canvasOverlayInactive(): string {
  return isWhiteCanvas() ? COLORS.surfaceMuted : withAlpha('#FFFFFF', 0.10);
}

function canvasVertexColor(): string {
  return isWhiteCanvas() ? '#A76B00' : VERTEX_COLOR;
}

function canvasMeasureColor(): string {
  return isWhiteCanvas() ? '#21823B' : COLORS.success;
}

function canvasRulerColor(): string {
  return isWhiteCanvas() ? '#087D75' : COLORS.teal;
}

@Component
export struct LayoutCanvasView {
  @Prop projectedPorts: ResolvedPort[] = [];
  onPickPort: (endpoint: PortEndpoint) => void = (_endpoint: PortEndpoint) => {};
  // @Prop deep-copies arrays: a chip-sized document must share the editor state.
  @Link @Watch('onShapesChange') shapes: Shape[];
  @Prop renderCellNames: string[] = [];
  renderSceneProvider: (() => ViewSceneSource[]) | null = null;
  @Prop @Watch('onSceneChanged') sceneRevision: number = 0;
  @Prop sceneDiagnostic: string = '';
  private sceneService: ViewRenderSceneService = new ViewRenderSceneService((text: string): number => this.measureSceneText(text));
  // §5 线型/填充/透明度/动画层：样式全部读这批 UiLayer（面板与 .lyp 导入写入的同一对象），
  // 不 fork 平行列表；layers 变化时只需启停动画层的闪烁循环。
  @Prop @Watch('onLayersChange') layers: UiLayer[] = [];
  @Prop visibleLayerNumbers: number[] = [];
  @Prop @Watch('onSelectedShapeIdChange') selectedShapeId: number = -1;
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop @Watch('onToolChanged') currentTool: ActiveTool = ActiveTool.Select;
  @Prop @Watch('onDocumentChanged') documentKey: string = '';
  @Prop keyboardBlocked: boolean = false;
  @Prop @Watch('onEditableChanged') editable: boolean = true;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  /** violation 高亮区域（DRC 跳转时由父组件传入；为空则不绘制闪烁框） */
  // CANVAS-5: highlightedViolation 变化时启停闪烁定时器，避免无违规时白白消耗 CPU
  @Prop @Watch('onHighlightedViolationChange') highlightedViolation: ViolationHighlight | null = null;
  /** 紧凑模式（sm 手机端）：由父组件根据断点传入，用于浮动面板默认收起等行为 */
  @Prop isCompact: boolean = false;
  @Prop desktopMode: boolean = false;
  /** 网格吸附开关（统一由 SnapService 接管，消除 Ruler/Box/Polygon/Path/Measure/Text/Move 各工具吸附行为不一致） */
  @Prop snapEnabled: boolean = true;
  /** 网格大小（nm），用于 snapWorld 网格吸附 */
  @Prop gridSize: number = 10;
  @Prop displayGridNm: number = -1;
  @Prop drawStepNm: number = -1;
  /** INDEX-6: 网格显隐开关（由 TOGGLE_GRID 快捷键控制） */
  @Prop gridVisible: boolean = true;
  /** SNAP-1: 顶点吸附开关（吸附到已有图形顶点） */
  @Prop vertexSnapEnabled: boolean = true;
  @Prop geometrySnapEnabled: boolean = true;
  @Prop geometrySnapKinds: string[] = ['顶点', '交点', '中点', '包围盒中心', '边'];
  @Prop smartGuidesEnabled: boolean = true;
  @Prop @Watch('onRoutingModePropChanged') routingMode: RoutingMode = RoutingMode.MANHATTAN_90;
  @Prop touchLoupeEnabled: boolean = true;
  @Prop multiSelectAdditive: boolean = false;
  @Prop selectedShapeCount: number = 0;
  @Prop @Watch('onInteractiveCurveKindChanged') interactiveCurveKind: string = '';
  routingModeChangeAction: (mode: RoutingMode) => void = (_mode: RoutingMode) => {};
  interactiveCurveKindChangeAction: (kind: string) => void = (_k: string) => {};
  openExactCurveDialogAction: (kind: string) => void = (_k: string) => {};
  selectActiveLayerAction: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};
  unlockAndShowLayerAction: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};
  duplicateSelectionAction: () => void = () => {};
  rotateSelection90Action: () => void = () => {};
  mirrorSelectionHAction: () => void = () => {};
  mirrorSelectionVAction: () => void = () => {};
  deleteSelectionAction: () => void = () => {};
  roundCornersAction: () => void = () => {};
  openArrayCopyAction: () => void = () => {};
  alignQuickAction: (mode: string) => void = (_m: string) => {};
  booleanQuickAction: (op: 'merge' | 'subtract') => void = (_op: 'merge' | 'subtract') => {};
  enterSelectedInstanceAction: () => void = () => {};
  flattenSelectedInstanceAction: () => void = () => {};
  changeSelectionLayerAction: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};
  commitStampAtAction: (x: number, y: number) => boolean = (_x: number, _y: number) => false;
  openStampDialogAction: () => void = () => {};
  stampTransformChangedAction: () => void = () => {};
  exitStampModeAction: () => void = () => {};
  stampTemplateProvider: () => DraftStampTemplate = (): DraftStampTemplate => ({ outlines: [], ports: [] });
  continuePathCommitAction: (shapeId: number, points: Point[], width: number, pathType: number) => boolean =
    (_id: number, _pts: Point[], _w: number, _pt: number) => false;
  requestPathToolAction: () => void = () => {};
  fitAllAction: () => void = () => {};
  @Prop selectionLayerFilter: number = -1;
  @Prop selectionDatatypeFilter: number = -1;
  @Prop selectionTypeFilter: ShapeType[] = [];
  onHitCandidates: (result: HierarchyCandidatesResult, activeIndex: number) => void = () => {};
  onPickCandidate: (candidate: HierarchyHitCandidate) => void = () => {};
  onEnterInstancePath: (path: InstancePathStep[]) => boolean = () => false;
  /** SNAP-1: 顶点吸附阈值（nm，世界坐标） */
  @Prop vertexSnapThreshold: number = 16;
  selectShapeAction: (shape: Shape) => void = () => {};
  selectMultipleAction: (ids: number[]) => void = () => {};
  createShapeAction: (start: Point, end: Point) => boolean = () => false;
  moveShapeAction: (shapeId: number, deltaX: number, deltaY: number) => void = () => {};
  /** 请求父组件刷新 shapes（editService 状态变更后触发重绘） */
  requestRenderAction: () => void = () => {};
  vertexMoveCommittedAction: () => void = () => {};
  /** 双击实例图形时进入子 Cell 编辑上下文（cellId 为目标 Cell） */
  onEnterCell: (cellId: number) => void = () => {};
  onNavigateCellStack: (stackIndex: number) => void = () => {};
  /** Polygon 绘制完成回调（顶点列表） */
  createPolygonAction: (points: Point[]) => boolean = () => false;
  /** Path 绘制完成回调（顶点列表 + 线宽 + 端头类型） */
  createPathAction: (points: Point[], width: number, pathType?: number) => boolean = () => false;
  /** Text 创建回调（位置 + 文本内容） */
  createTextAction: (x: number, y: number, text: string) => boolean | void = () => {};
  editContextProvider: () => string = () => '';
  private textInsertContext: string = '';
  zoomAtAction: (screenX: number, screenY: number, scaleFactor: number) => void = () => {};
  panCanvasAction: (deltaScreenX: number, deltaScreenY: number) => void = () => {};
  viewportChangeAction: (width: number, height: number) => void = () => {};
  canvasKeyAction: (event: KeyEvent) => void = () => {};
  onBoxZoomDone: () => void = () => {};
  boxZoomAction: ((left: number, top: number, width: number, height: number) => void) | null = null;

  /** S-1: 共享光标存储（@ObjectLink 属性级观察）。光标移动仅写入此存储，
   *  由 CanvasHud/StatusBar 消费，不触发画布整树重建。 */
  @ObjectLink cursorStore: CursorStore;

  // Phase 5: 矩形/拖拽/多边形/框选全部走 DraftOverlayLayer (120fps Canvas2D 叶子层)，
  // 剥离根组件 @State，消除 pointer Move 触发 3,900+ 行画布整树重建。
  private previewRect: PreviewRect = { x: 0, y: 0, w: 0, h: 0 };
  private isPreviewing: boolean = false;
  private isDragging: boolean = false;
  private dragOffsetX: number = 0;
  private dragOffsetY: number = 0;
  private moveGhostOutlines: DraftGhostOutline[] = [];
  // GL 增强渲染开关：v0.3 默认开启，由 GlCanvas 走 XComponent + OpenGL ES 高性能渲染
  @State glEnabled: boolean = true;
  /**
   * GL 主路径是否真正可用。true 时版图几何由 GPU 绘制，ShapeNode 仅叠加
   * 选中/INSTANCE/TEXT（可点击）；false 时回退有上限的 ShapeNode。
   */
  @State glActive: boolean = true;
  @Prop preferNativeExpand: boolean = true;
  private cachedEditOverlayRev: string = '';
  private cachedCurrentCellInstances: Shape[] = [];
  private cachedSelectedOverlayShapes: Shape[] = [];
  private cachedSceneDrawFrameKey: string = '';
  private cachedSceneDrawFrameResult: ViewSceneDrawResult | undefined = undefined;
  // Shape IDs restart in each document. Re-key only when geometry/style data
  // changes, not for cursor, pan or drag-preview frames.
  @State geometryRenderRevision: number = 0;
  private selectionCacheRevision: number = -1;
  private selectionFlagIds: Set<number> = new Set<number>();
  @State styleRenderRevision: number = 0;
  // Cache is deliberately not @State: build reads it without scheduling another
  // build. Geometry/style revisions and camera values invalidate the key.
  private fallbackDrawCacheKey: string = '';
  private fallbackDrawCache: BoundedHierarchyDrawResult = { shapes: [], overflow: false, limit: 2000 };
  private hatchBudgetSource: ViewSceneDrawResult | undefined = undefined;
  private hatchBudgetKey: string = '';
  private hatchBudgetResult: ViewSceneDrawResult | undefined = undefined;
  // Notification only: numeric px conversion always comes from this UIContext.
  @StorageProp('hongtuWindowDensity') @Watch('onHatchDensityChanged') hatchDensitySignal: number = 1;
  @StorageProp('effectiveIsDark') @Watch('onEffectiveThemeChanged') effectiveIsDark: boolean = false;
  private snapCacheKey: string = '';
  private snapCache: Shape[] = [];
  private boxSelectLeftToRight: boolean = true;
  private pendingClickShapeId: number = -1;
  @State hitCandidates: HierarchyHitCandidate[] = [];
  @State hitCandidateIndex: number = 0;
  @State hitCandidatesMessage: string = '';
  @State hitCandidatePreview: PreviewRect = { x: 0, y: 0, w: 0, h: 0 };
  private hitCandidateContext: string = '';
  private hitCandidateX: number = 0;
  private hitCandidateY: number = 0;
  private hitCandidateTolerance: number = 0;
  private twoFingerNavigation: boolean = false;
  private twoFingerPanActive: boolean = false;
  private twoFingerPinchActive: boolean = false;
  private polyLivePoint: Point | null = null;
  private polyLiveTail: Point[] = [];
  private polyCloseLoopReady: boolean = false;
  private hasPendingPolyTouch: boolean = false;
  private hasPendingTextTouch: boolean = false;
  private hasCurveStart: boolean = false;
  private curveCenterX: number = 0;
  private curveCenterY: number = 0;
  private measureDownScreenX: number = 0;
  private measureDownScreenY: number = 0;
  private hasMeasureTouchActive: boolean = false;
  private measureWasWaitingSecondPoint: boolean = false;
  private lastInputIsTouch: boolean = false;
  private lastPointerScreenX: number = 0;
  private lastPointerScreenY: number = 0;
  private gestureCellId: number = -1;
  private gestureContext: string = '';
  private gestureState: string = '';
  private polyDrawContext: string = '';
  private polyDrawState: string = '';
  private selectionBoundsKey: string = '';
  private selectionBoundsResolver: HierarchyBoundsResolver | null = null;
  // GL-1: 真实画布尺寸（通过 onAreaChange 获取），替代硬编码 800×600
  @State canvasWidth: number = 800;
  @State canvasHeight: number = 600;

  // 框选多选（交由 DraftOverlayLayer 绘制，不触发根树重排）
  private isBoxSelecting: boolean = false;
  private boxSelectRect: BoxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
  // 框选命中的图形 ID（本地维护，用于多选高亮渲染）
  @State multiSelectIds: number[] = [];
  @State cellStackIds: number[] = [];
  private lastShapeClickId: number = -1;
  private lastShapeClickAt: number = 0;
  private lastShapeClickScreenX: number = 0;
  private lastShapeClickScreenY: number = 0;
  private lastPolyVertexTapAt: number = 0;
  private lastPolyVertexScreenX: number = 0;
  private lastPolyVertexScreenY: number = 0;
  private lastPolyTapAddedCount: number = 0;

  // Move 工具：长按弹框微调（dialogDxStr/dyStr 为打开前初始位移，由 MoveFineTuneDialog 读取）
  @State dialogDxStr: string = '0';
  @State dialogDyStr: string = '0';
  // Polygon/Path 多顶点绘制（状态同步至 DraftOverlayLayer 与 DraftControlStore）
  private polygonPoints: Point[] = [];
  private isDrawingPoly: boolean = false;
  private pathWidthStr: string = '8';

  // Measure 两点测量 / 标尺：@Observed 存储由页面持有，画布以 @ObjectLink 透传
  // （ArkTS 要求 @ObjectLink 源必须是父组件状态变量）。观察落在 MeasureLayer 叶子，
  // 端点与橡皮筋写入不重建画布整树（含展开几何 ForEach），与 CursorStore 同一套路。
  @ObjectLink measureStore: MeasureStore;
  /**
   * 顶点编辑状态（§6）：与 measureStore 同一套路 —— 页面 @State 持有、此处 @ObjectLink 透传、
   * 仅 VertexLayer 叶子观察。拖顶点是 pointer 高频路径，放进本组件的 @State 会重建画布整树。
   */
  @ObjectLink vertexStore: VertexStore;
  /** 草稿控制条状态：页面 @State 持有、此处 @ObjectLink 透传，仅 DraftOverlayLayer 内部叶子浮条观察 */
  @ObjectLink draftControlStore: DraftControlStore;
  // 标尺按下点（屏幕 px），用于按拖拽主方向判定水平/竖直标尺
  private rulerDownScreenX: number = 0;
  private rulerDownScreenY: number = 0;
  private hasRulerDown: boolean = false;
  // 光标命中测试节流时戳（hitTest 最坏为线性扫描，不能每个 pointer 事件都跑）
  private lastCursorHitAt: number = 0;
  private lastIdleCursorUpdateAt: number = 0;
  private snapCacheViewport: WorldViewport | null = null;

  // Text 创建：落点坐标（textCreateController 打开前由调用方写入）
  private textInsertX: number = 0;
  private textInsertY: number = 0;

  // violation 闪烁透明度（animateTo 驱动 0.3 <-> 1.0）
  @State violationBlinkOpacity: number = 1.0;
  /** §5 动画层闪烁相位（仅 animated 图层参与） */
  @State layerBlinkOpacity: number = 1.0;
  /** 动画层闪烁循环是否已在运行（防重复 animateTo 叠加） */
  private layerBlinkRunning: boolean = false;
  // CANVAS-13: hierarchyDepth 改为 @Prop 由父组件传入，消除两套状态不同步
  @Prop hierarchyDepth: number = 2;

  // 绘制起点（用户坐标 nm）
  private drawStartX: number = 0;
  private drawStartY: number = 0;
  private hasDrawStart: boolean = false;
  // 拖拽起点（屏幕坐标，用于计算偏移）
  private dragStartScreenX: number = 0;
  private dragStartScreenY: number = 0;
  // 框选起点（屏幕坐标）
  private boxStartScreenX: number = 0;
  private boxStartScreenY: number = 0;

  // Move 工具基点（用户坐标 nm）与计时
  private moveFromX: number = 0;
  private moveFromY: number = 0;
  private moveStartTime: number = 0;
  // CANVAS-8/9/14: 长按弹框待确认的位移上下文（支持多选，改为数组）
  private pendingMoveIds: number[] = [];
  private pendingMoveContext: string = '';
  // CANVAS-11: 错误提示与弹框显隐已下沉至 MoveFineTuneDialog（@CustomDialog）
  private moveFineTuneController: CustomDialogController = new CustomDialogController({
    builder: MoveFineTuneDialog({
      dxStr: this.dialogDxStr,
      dyStr: this.dialogDyStr,
      hasSelection: this.pendingMoveIds.length > 0,
      contextProvider: () => this.editGestureContext(),
      onConfirm: (dx: number, dy: number): boolean => this.applyMoveFineTune(dx, dy)
    }),
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  // Task 2.4: 文本标注创建弹框（@CustomDialog，系统模态遮罩自动屏蔽画布触摸）
  private textCreateController: CustomDialogController = new CustomDialogController({
    builder: TextCreateDialog({
      insertX: this.textInsertX,
      insertY: this.textInsertY,
      contextProvider: () => this.textCreateContext(),
      onConfirm: (text: string): boolean => this.confirmTextCreate(text)
    }),
    alignment: DialogAlignment.Center,
    customStyle: true
  });

  // 双指缩放：上次累积 scale，用于计算增量避免缩放失控
  private lastPinchScale: number = 1;
  private lastPinchCenterX: number = 0;
  private lastPinchCenterY: number = 0;
  private lastTwoFingerPanX: number = 0;
  private lastTwoFingerPanY: number = 0;
  private isMousePanning: boolean = false;
  private middleMouseDownAt: number = 0;
  private middleMouseStartX: number = 0;
  private middleMouseStartY: number = 0;
  private lastMiddleTapAt: number = 0;
  private lastMousePanX: number = 0;
  private lastMousePanY: number = 0;
  private hasRegularPolyStart: boolean = false;
  private isSingleFingerPanning: boolean = false;
  private lastSinglePanX: number = 0;
  private lastSinglePanY: number = 0;
  private hasPendingStampTouch: boolean = false;
  private dragThresholdExceeded: boolean = false;

  aboutToAppear(): void {
    // CANVAS-13: hierarchyDepth 已改为 @Prop 由父组件传入，不再在此初始化
    this.draftControlStore.routingMode = this.routingMode;
    this.draftControlStore.curveKind = this.interactiveCurveKind;
    this.draftControlStore.pathWidthStr = this.pathWidthStr;
    this.syncToolActiveFlags();
    this.syncCellStackState();
    // 顶点编辑：进入页面时若已有选中图形，立即投影其顶点句柄
    this.syncVertexStore();
    // §3 统一 DBU/屏幕/Y 轴：世界<->屏幕变换若失去互逆或出现隐式翻转，读数/命中会整体错位，
    // 启动即自检一次（ArkTS 侧无测试框架，沿用 console.warn 告警惯例）
    if (!canvasTransformConsistent()) {
      console.warn('[LayoutCanvasView] 坐标变换自检失败：worldToScreen/screenToWorld 非严格互逆或轴向翻转');
    }
    // CANVAS-5: 仅在有违规高亮时启动闪烁动画
    if (this.highlightedViolation !== null) {
      this.startBlinkAnimation();
    }
    // §5: 仅在有动画图层时启动图层闪烁循环
    if (this.anyLayerAnimated()) {
      this.startLayerBlink();
    }
  }

  aboutToDisappear(): void {
    this.sceneService.clear();
    this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
    this.stopBlinkAnimation();
    this.stopLayerBlink();
    this.isMousePanning = false;
    this.isSingleFingerPanning = false;
    this.hasPendingStampTouch = false;
    this.dragThresholdExceeded = false;
    resetModifierKeys();
    draftCanvasEngine.clearAll();
    this.draftControlStore.resetPoly();
  }

  // CANVAS-5: highlightedViolation 变化回调 — 有违规时启动动画，无违规时停止
  onHighlightedViolationChange(): void {
    if (this.highlightedViolation !== null) {
      this.startBlinkAnimation();
    } else {
      this.stopBlinkAnimation();
    }
  }

  // CANVAS-5: 用 animateTo 替代 setInterval，驱动 opacity 在 0.3~1.0 之间无限循环
  private startBlinkAnimation(): void {
    animateTo({ duration: 500, iterations: -1, curve: Curve.EaseInOut, playMode: PlayMode.Alternate }, () => {
      this.violationBlinkOpacity = 0.3;
    });
  }

  private stopBlinkAnimation(): void {
    // 用 duration:0 的 animateTo 中断正在运行的循环动画并复位到 1.0
    animateTo({ duration: 0 }, () => {
      this.violationBlinkOpacity = 1.0;
    });
  }

  // ==================== §5 动画层（animated）闪烁 ====================
  // KLayout 的 animation 参数（周期/颜色）模型未承载，这里只实现「闪烁」语义开关：
  // 任意可见层 animated=true 时启一个循环，把 layerBlinkOpacity 在 0.25~1.0 间来回驱动，
  // 由 ShapeNode 乘进填充/描边不透明度。仅 ArkUI 路径生效（GL 主路径无逐帧回调）。

  /** layers 变化：按是否仍有动画层启停闪烁循环 */
  onEffectiveThemeChanged(): void {
    this.styleRenderRevision++;
  }

  onLayersChange(): void {
    this.styleRenderRevision++;
    if (this.anyLayerAnimated()) {
      this.startLayerBlink();
    } else {
      this.stopLayerBlink();
    }
  }

  private anyLayerAnimated(): boolean {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].animated === true && this.layers[i].visible) {
        return true;
      }
    }
    return false;
  }

  private startLayerBlink(): void {
    if (this.layerBlinkRunning) {
      return;
    }
    this.layerBlinkRunning = true;
    animateTo({ duration: 600, iterations: -1, curve: Curve.EaseInOut, playMode: PlayMode.Alternate }, () => {
      this.layerBlinkOpacity = 0.25;
    });
  }

  private stopLayerBlink(): void {
    if (!this.layerBlinkRunning) {
      return;
    }
    this.layerBlinkRunning = false;
    animateTo({ duration: 0 }, () => {
      this.layerBlinkOpacity = 1.0;
    });
  }

  /** 取图层样式（单一真源：this.layers 里的 UiLayer 本身，不拷贝列表） */
  private findLayer(layerNumber: number, datatype: number): UiLayer | undefined {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        return this.layers[i];
      }
    }
    return undefined;
  }

  private styleForLayer(layerNumber: number, datatype: number): LayerRenderStyle {
    return layerRenderStyle(this.findLayer(layerNumber, datatype));
  }

  /** 动画层用当前闪烁相位，非动画层恒为 1（不随相位抖动） */
  private blinkForLayer(layerNumber: number, datatype: number): number {
    const layer: UiLayer | undefined = this.findLayer(layerNumber, datatype);
    return (layer !== undefined && layer.animated === true) ? this.layerBlinkOpacity : 1;
  }

  build() {
    Stack() {
      // A focus leaf keeps layout shortcuts outside every text-input focus chain.
      // Pointer input still goes to the drawing surface; requestFocus targets it.
      Text('')
        .id('layout-canvas-keyboard')
        .width(1).height(1).opacity(0)
        .focusable(true)
        .defaultFocus(true)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
        .onKeyEvent((event: KeyEvent) => { this.handleCanvasKeyEvent(event); })
        .onBlur(() => {
          this.isMousePanning = false;
          resetModifierKeys();
        })
      // 原生清屏色跟随画布主题；浅色与深色均保留 GL 主路径。
      if (this.glEnabled) {
        GlCanvas({
          renderSceneProvider: this.renderSceneProvider,
          sceneRevision: this.sceneRevision,
          shapes: this.renderSceneProvider !== null ? [] : this.currentCellShapes(),
          fallbackShapesProvider: () => this.fallbackDrawResult().shapes,
          fallbackOverflowProvider: () => this.fallbackDrawResult().overflow,
          renderSnapshotProvider: () => editService.isDirty() ? {
            cellNames: this.renderCellNames,
            topCellId: editService.getTopCellId(),
            shapes: this.shapes
          } : null,
          layers: this.layers,
          zoomScale: this.zoomPercent,
          offsetX: this.viewOffsetX,
          offsetY: this.viewOffsetY,
          canvasWidth: this.canvasWidth,
          canvasHeight: this.canvasHeight,
          useGL: true,
          lightBackground: !this.effectiveIsDark,
          currentCellId: editService.getCurrentCellId(),
          hierarchyDepth: this.hierarchyDepth,
          // 编辑后 native g_layout 未同步：必须走 ArkTS 已展开 shapes，避免 GL 画旧几何
          preferNativeExpand: this.preferNativeExpand && !editService.isDirty(),
          onGlActiveChange: (active: boolean) => {
            this.glActive = active;
          },
        })
      }

      if (this.renderSceneProvider !== null) {
        ForEach(
          (!this.glEnabled || !this.glActive)
            ? this.sceneDrawResult().primitives
            : this.sceneTextOverlaysForRender(),
          (primitive: ViewScenePrimitive) => {
            ViewSceneNode({ primitive: primitive, zoomPercent: this.zoomPercent,
              viewOffsetX: this.viewOffsetX, viewOffsetY: this.viewOffsetY,
              canvasWidth: this.canvasWidth, canvasHeight: this.canvasHeight,
              densitySignal: this.hatchDensitySignal })
          },
          (primitive: ViewScenePrimitive) => this.scenePrimitiveKey(primitive)
        )
      }

      // 网格叠在不透明 GL Surface 上，避免被清屏遮挡；不拦截画布交互。
      if (this.gridVisible) {
        CanvasGrid({
          canvasWidth: this.canvasWidth,
          canvasHeight: this.canvasHeight,
          zoomPercent: this.zoomPercent,
          viewOffsetX: this.viewOffsetX,
          viewOffsetY: this.viewOffsetY,
          gridSize: this.displayGridNm >= 0 ? this.displayGridNm : this.gridSize,
        })
          .hitTestBehavior(HitTestMode.None)
      }

      // GL 活跃：仅叠加可交互入口（INSTANCE / TEXT / 选中本地图形）
      // GL 降级：仅在视口图元数不超预算时创建 ShapeNode
      ForEach(this.renderSceneProvider !== null ? this.sceneEditOverlaysForRender() : this.overlayShapesForRender(), (shape: Shape) => {
        if (shape.type !== ShapeType.NODE && this.isLayerVisible(shape.layerNumber, shape.datatype)) {
          if (this.renderSceneProvider !== null && shape.type === ShapeType.TEXT) {
            // The ordered scene owns the glyph. Selection must not paint a
            // second, differently sized/anchored copy of its text content.
            ViewSceneTextSelectionNode({
              primitive: this.sceneTextSelectionPrimitive(shape),
              zoomPercent: this.zoomPercent,
              viewOffsetX: this.viewOffsetX,
              viewOffsetY: this.viewOffsetY,
              dragOffsetX: 0,
              dragOffsetY: 0
            })
          } else {
            ShapeNode({
            shape: shape,
            instanceSelectionBounds: this.selectedInstanceBounds(shape),
            color: this.colorForLayer(shape.layerNumber, shape.datatype),
            style: this.styleForLayer(shape.layerNumber, shape.datatype),
            blink: this.blinkForLayer(shape.layerNumber, shape.datatype),
            selected: this.isShapeSelected(shape.id) && !isExpandedSyntheticShape(shape),
            quietInstanceOverlay: this.glEnabled && this.glActive,
            zoomPercent: this.zoomPercent,
            viewOffsetX: this.viewOffsetX,
            viewOffsetY: this.viewOffsetY,
            dragOffsetX: 0,
            dragOffsetY: 0,
            // The canvas owns hit testing, including geometry drawn only by GL.
            selectShapeAction: (_s: Shape) => {}
            })
          }
        }
      }, (shape: Shape) => this.shapeRenderKey(shape))

      PortOverlay({ ports: this.projectedPorts, zoomPercent: this.zoomPercent, viewOffsetX: this.viewOffsetX,
        viewOffsetY: this.viewOffsetY, canvasWidth: this.canvasWidth, canvasHeight: this.canvasHeight,
        pickAllowed: this.currentTool === ActiveTool.Select && !this.keyboardBlocked,
        onPick: (endpoint: PortEndpoint): void => this.onPickPort(endpoint) })

      if (!this.glEnabled && this.sceneCapacityOverflow()) {
        Text(this.renderSceneProvider !== null ? this.sceneDrawResult().message : '内置绘制的视口图元过多，请放大局部或降低层级')
          .fontSize(15)
          .fontColor(canvasOverlayInk())
          .padding({ left: 20, right: 20, top: 14, bottom: 14 })
          .backgroundColor(canvasOverlayBackground())
          .border({ width: 1, color: COLORS.primary })
          .borderRadius(UI.panelRadius)
          .constraintSize({ maxWidth: '85%' })
          .hitTestBehavior(HitTestMode.None)
          .id('canvas-fallback-capacity-warning')
      }
      if (this.sceneDiagnostic.length > 0) {
        Text(this.sceneDiagnostic)
          .fontSize(UI.fontCaption).fontColor(COLORS.danger)
          .backgroundColor(canvasOverlayBackground()).padding(8)
          .borderRadius(UI.segmentItemRadius).constraintSize({ maxWidth: '85%' })
          .position({ x: 8, y: 70 }).hitTestBehavior(HitTestMode.None)
          .id('canvas-scene-source-diagnostic')
      }

      // 矩形预览与框选预览统一由 DraftOverlayLayer 高帧率绘制

      // violation 闪烁高亮框（红色，opacity 动画 0.5<->1.0）
      if (this.highlightedViolation !== null) {
        Rect()
          .width(this.worldToScreen(this.highlightedViolation.w))
          .height(this.worldToScreen(this.highlightedViolation.h))
          .fill(withAlpha(COLORS.danger, ALPHA.FOCUS))
          .fillOpacity(this.violationBlinkOpacity)
          .stroke(COLORS.danger)
          .strokeWidth(2)
          .position({ x: this.worldToScreenX(this.highlightedViolation.x), y: this.worldToScreenY(this.highlightedViolation.y + this.highlightedViolation.h) })
          .hitTestBehavior(HitTestMode.None)
      }

      // 顶部浮动栏：面包屑导航 + 层级滑块（非桌面端在弹出绘制控制浮条且未进入子 Cell 时自动收起层级条，彻底消除 y:48/y:52 重叠！）
      if (this.shouldShowTopFloatingBar()) {
        this.TopFloatingBar()
      }
      if (this.hitCandidates.length > 1) {
        Rect()
          .width(this.hitCandidatePreview.w * this.zoomPercent / 100)
          .height(this.hitCandidatePreview.h * this.zoomPercent / 100)
          .fill('transparent').stroke(canvasSelectionStroke()).strokeWidth(2)
          .position({ x: this.worldToScreenX(this.hitCandidatePreview.x),
            y: this.worldToScreenY(this.hitCandidatePreview.y + this.hitCandidatePreview.h) })
          .hitTestBehavior(HitTestMode.None)
        this.HitCandidateBar()
      }

      CanvasHud({
        toolLabel: this.toolLabel(),
        selectedLayerNumber: this.selectedLayerNumber,
        selectedDatatype: this.selectedDatatype,
        selectedLayerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
        selectedLayerLocked: !editService.canEditLayer(this.selectedLayerNumber, this.selectedDatatype) || !this.isLayerVisible(this.selectedLayerNumber, this.selectedDatatype),
        layers: this.layers,
        desktopMode: this.desktopMode,
        zoomPercent: this.zoomPercent,
        cursorStore: this.cursorStore,
        onSelectLayer: (ln: number, dt: number) => { this.selectActiveLayerAction(ln, dt); },
        onUnlockAndShowLayer: (ln: number, dt: number) => { this.unlockAndShowLayerAction(ln, dt); },
      })

      // Move 工具长按微调弹框：由 moveFineTuneController（@CustomDialog）驱动，open() 时弹出

      // Text 工具：点击位置后弹出文本输入框（由 textCreateController @CustomDialog 驱动）

      // Phase 5: 独立 120fps 瞬态绘制与磁吸反馈叶子层（承载对齐线、磁吸靶标、正交走线、真实线宽包络、尺寸浮标与触屏放大镜）
      DraftOverlayLayer({
        controlStore: this.draftControlStore,
        zoomPercent: this.zoomPercent,
        viewOffsetX: this.viewOffsetX,
        viewOffsetY: this.viewOffsetY,
        canvasWidth: this.canvasWidth,
        canvasHeight: this.canvasHeight,
        desktopMode: this.desktopMode,
        topStripY: this.topControlStripY(),
        stepUnitNm: this.drawStepNm > 0 ? this.drawStepNm : this.gridSize,
        onFinishPoly: () => { this.finishPolyDraw(); },
        onCancelPoly: () => { this.clearPolyDraw(); },
        onUndoPolyVertex: () => { this.undoLastPolyVertex(); },
        onSelectRoutingMode: (mode: RoutingMode) => { this.setRoutingModeDirect(mode); },
        onCycleRoutingMode: () => { this.cycleRoutingMode(); },
        onFlipPosture: () => { this.flipRoutingPosture(); },
        onPathWidthEdited: (val: string) => { this.onPathWidthChanged(val); },
        onPathTypeChanged: () => { this.syncPolyDraftCanvas(); },
        onSelectCurveKind: (kind: string) => {
          this.draftControlStore.curveKind = kind;
          this.interactiveCurveKindChangeAction(kind);
        },
        onOpenExactCurveDialog: (kind: string) => {
          this.openExactCurveDialogAction(kind);
        },
        onExitCurveMode: () => {
          this.draftControlStore.curveKind = '';
          this.hasCurveStart = false;
          draftCanvasEngine.clearTransientPointerVisuals(true);
          this.interactiveCurveKindChangeAction('');
        },
        onOpenStampDialog: () => { this.openStampDialogAction(); },
        onStampTransformChanged: () => {
          this.stampTransformChangedAction();
          this.refreshLiveStampPreview(this.lastPointerScreenX, this.lastPointerScreenY, false);
        },
        onExitStampMode: () => { this.exitStampModeAction(); },
        onExactCreateRect: (minX: number, minY: number, maxX: number, maxY: number): boolean => {
          if (!this.editable || !this.ensureActiveLayerReadyForDraw()) return false;
          return this.createShapeAction({ x: minX, y: minY }, { x: maxX, y: maxY });
        },
        viewportCenterProvider: (): Point => ({
          x: this.screenToWorldX(this.canvasWidth * 0.5),
          y: this.screenToWorldY(this.canvasHeight * 0.5)
        }),
      })

      // Measure 测量 + Ruler 持久标尺：端点/标尺/读数/模式切换全部下沉到叶子组件，
      // 画布仅传入变换参数，拖动过程中不重建本组件
      MeasureLayer({
        store: this.measureStore,
        cursorStore: this.cursorStore,
        zoomPercent: this.zoomPercent,
        viewOffsetX: this.viewOffsetX,
        viewOffsetY: this.viewOffsetY,
        canvasWidth: this.canvasWidth,
        canvasHeight: this.canvasHeight,
        desktopMode: this.desktopMode,
        toolActive: this.currentTool === ActiveTool.Measure
      })

      // 顶点编辑句柄层（§6）：句柄 / 实时轮廓 / 模式条下沉到叶子组件，
      // 拖顶点期间画布主体不重建；手势判定仍在本组件 onTouch 里统一做
      VertexLayer({
        store: this.vertexStore,
        zoomPercent: this.zoomPercent,
        viewOffsetX: this.viewOffsetX,
        viewOffsetY: this.viewOffsetY,
        canvasWidth: this.canvasWidth,
        canvasHeight: this.canvasHeight,
        desktopMode: this.desktopMode,
        selectActive: this.editable && this.currentTool === ActiveTool.Select,
        hasTarget: this.hasVertexTarget(),
        selectionCount: this.selectedShapeCount,
        canRoundSelected: this.canRoundSingleSelection(),
        canContinuePath: this.canContinueSelectedPath(),
        canEnterInstance: this.canEnterSingleSelectedInstance(),
        canFlattenInstance: this.hasSelectedInstance(),
        layers: this.layers,
        onContinuePath: () => { this.startContinueSelectedPath(); },
        onEnterInstance: () => { this.enterSelectedInstanceAction(); },
        onFlattenInstance: () => { this.flattenSelectedInstanceAction(); },
        onDuplicate: () => { this.duplicateSelectionAction(); },
        onRotate90: () => { this.rotateSelection90Action(); },
        onMirrorH: () => { this.mirrorSelectionHAction(); },
        onMirrorV: () => { this.mirrorSelectionVAction(); },
        onRoundCorners: () => { this.roundCornersAction(); },
        onOpenArrayCopy: () => { this.openArrayCopyAction(); },
        onAlignQuick: (m: string) => { this.alignQuickAction(m); },
        onBooleanQuick: (op: 'merge' | 'subtract') => { this.booleanQuickAction(op); },
        onChangeLayer: (ln: number, dt: number) => { this.changeSelectionLayerAction(ln, dt); },
        onDelete: () => { this.deleteSelectionAction(); },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(COLORS.canvasBg)
    .clip(true)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      // GL-1: 保留浮点 vp 宽高，消除 Math.round 整数截断造成的亚像素比例尺偏差
      const w: number = Number(newValue.width);
      const h: number = Number(newValue.height);
      if (Number.isFinite(w) && Number.isFinite(h) && w > 0 && h > 0) {
        if (Math.abs(w - this.canvasWidth) > 1e-4 || Math.abs(h - this.canvasHeight) > 1e-4) {
          this.canvasWidth = w;
          this.canvasHeight = h;
        }
        this.viewportChangeAction(w, h);
      }
    })
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
    .onMouse((event: MouseEvent) => {
      this.handleMouse(event);
    })
    .onAxisEvent((event: AxisEvent) => {
      this.handleAxisEvent(event);
    })
    // 双击实例图形：进入子 Cell 编辑上下文（替代 KLayout Show as New Top，明确进入/退出语义）
    .parallelGesture(
      TapGesture({ count: 2 })
        .onAction((event: GestureEvent) => {
          this.handleDoubleClick(event);
        })
    )
    // 双指同时支持平移与实时双指中点锚定缩放（消除固定初始 pinchCenter 引发的并行漂移）
    .parallelGesture(
      GestureGroup(GestureMode.Parallel,
        PinchGesture({ fingers: 2 })
          .onActionStart((event: GestureEvent) => {
            this.twoFingerPinchActive = this.hasTwoFingerGesture(event);
            if (!this.twoFingerPinchActive) return;
            if (event.sourceTool !== SourceTool.TOUCHPAD) this.twoFingerNavigation = true;
            this.cancelTransientPointerOnly();
            const center: Point = this.resolveTwoFingerCenter(event);
            this.lastPinchCenterX = center.x;
            this.lastPinchCenterY = center.y;
            this.lastPinchScale = event.scale > 0 ? event.scale : 1;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!this.twoFingerPinchActive || !this.hasTwoFingerGesture(event)) return;
            if (event.scale <= 0 || this.lastPinchScale <= 0) {
              return;
            }
            const center: Point = this.resolveTwoFingerCenter(event);
            if (!this.twoFingerPanActive && event.sourceTool !== SourceTool.TOUCHPAD &&
              Number.isFinite(this.lastPinchCenterX) && Number.isFinite(this.lastPinchCenterY)) {
              const cdx: number = center.x - this.lastPinchCenterX;
              const cdy: number = center.y - this.lastPinchCenterY;
              if (Math.abs(cdx) > 0.01 || Math.abs(cdy) > 0.01) {
                this.panCanvasAction(cdx, cdy);
              }
            }
            this.lastPinchCenterX = center.x;
            this.lastPinchCenterY = center.y;
            const incremental: number = event.scale / this.lastPinchScale;
            this.lastPinchScale = event.scale;
            if (Number.isFinite(incremental) && incremental > 0 && Math.abs(incremental - 1) > 0.001) {
              this.zoomAtAction(center.x, center.y, incremental);
            }
          })
          .onActionEnd(() => {
            this.twoFingerPinchActive = false;
            this.lastPinchScale = 1;
          })
          .onActionCancel(() => {
            this.twoFingerPinchActive = false;
            this.lastPinchScale = 1;
          }),
        PanGesture({ fingers: 2, direction: PanDirection.All, distance: 0 })
          .onActionStart((event: GestureEvent) => {
            this.twoFingerPanActive = this.hasTwoFingerGesture(event);
            if (!this.twoFingerPanActive) return;
            if (event.sourceTool !== SourceTool.TOUCHPAD) this.twoFingerNavigation = true;
            this.cancelTransientPointerOnly();
            this.lastTwoFingerPanX = event.offsetX;
            this.lastTwoFingerPanY = event.offsetY;
            const center: Point = this.resolveTwoFingerCenter(event);
            this.lastPinchCenterX = center.x;
            this.lastPinchCenterY = center.y;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (!this.twoFingerPanActive || !this.hasTwoFingerGesture(event)) return;
            const dx: number = event.offsetX - this.lastTwoFingerPanX;
            const dy: number = event.offsetY - this.lastTwoFingerPanY;
            this.lastTwoFingerPanX = event.offsetX;
            this.lastTwoFingerPanY = event.offsetY;
            if (Number.isFinite(dx) && Number.isFinite(dy) && (dx !== 0 || dy !== 0)) {
              this.panCanvasAction(dx, dy);
              this.lastPinchCenterX += dx;
              this.lastPinchCenterY += dy;
            }
          })
          .onActionEnd(() => {
            this.twoFingerPanActive = false;
            this.lastTwoFingerPanX = 0;
            this.lastTwoFingerPanY = 0;
          })
          .onActionCancel(() => {
            this.twoFingerPanActive = false;
            this.lastTwoFingerPanX = 0;
            this.lastTwoFingerPanY = 0;
          })
      )
    )
  }

  private onToolChanged(): void {
    const continuingKeep: boolean = this.currentTool === ActiveTool.Path && this.draftControlStore.continuingShapeId >= 0 && this.isDrawingPoly;
    if (!continuingKeep) {
      this.clearPolyDraw();
    }
    this.syncToolActiveFlags();
    this.hasRegularPolyStart = false;
    if (this.currentTool !== ActiveTool.Instance && this.draftControlStore.stampActive) {
      this.draftControlStore.resetStamp();
      draftCanvasEngine.stampPreview = null;
    }
    this.isSingleFingerPanning = false;
    this.hasPendingStampTouch = false;
    this.clearMeasure();
    this.textInsertContext = '';
    this.textCreateController.close();
    this.moveFineTuneController.close();
    // CANVAS-7: 清理 Move 工具微调弹框的 pendingMoveIds，避免切回 Move 工具时误操作
    this.pendingMoveIds = [];
    this.pendingMoveContext = '';
    this.gestureContext = '';
    // 清理绘制/拖拽中间态，避免切换工具后残留预览
    this.isPreviewing = false;
    this.previewRect = { x: 0, y: 0, w: 0, h: 0 };
    this.hasDrawStart = false;
    this.drawStartX = 0;
    this.drawStartY = 0;
    this.isDragging = false;
    this.dragThresholdExceeded = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.isBoxSelecting = false;
    this.boxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
    this.hasPendingPolyTouch = false;
    this.isSingleFingerPanning = false;
    this.hasPendingStampTouch = false;
    this.hasPendingTextTouch = false;
    this.hasCurveStart = false;
    this.hasRegularPolyStart = false;
    this.hasMeasureTouchActive = false;
    this.moveGhostOutlines = [];
    if (!continuingKeep) {
      draftCanvasEngine.clearTransientPointerVisuals(false, this.draftControlStore.stampActive);
    } else {
      this.syncPolyDraftCanvas();
    }
    // 顶点编辑：丢弃未完成手势（模式与编辑目标保留，切回选择工具仍可用）
    if (this.vertexStore.isDragging()) {
      this.vertexStore.revert();
    }
    // UI-H3: 切换工具时清除多选本地状态，避免与 editService 选中集合不同步
    this.multiSelectIds = [];
    this.pendingClickShapeId = -1;
    this.clearHitCandidates();
  }

  private clearHitCandidates(): void {
    this.hitCandidates = [];
    this.hitCandidateIndex = 0;
    this.hitCandidatesMessage = '';
    this.hitCandidateContext = '';
    this.hitCandidatePreview = { x: 0, y: 0, w: 0, h: 0 };
    this.onHitCandidates({ ok: true, complete: true, candidates: [], message: '' }, 0);
  }

  private onDocumentChanged(): void {
    // A pure GL replacement may never draw through this independent ArkUI cache.
    this.sceneService.clear();
    this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
    this.onToolChanged();
    this.selectionBoundsResolver = null;
    this.selectionBoundsKey = '';
    this.lastShapeClickId = -1;
    this.lastShapeClickAt = 0;
    this.lastShapeClickScreenX = 0;
    this.lastShapeClickScreenY = 0;
    this.twoFingerNavigation = false;
    this.twoFingerPanActive = false;
    this.twoFingerPinchActive = false;
    this.gestureCellId = editService.getCurrentCellId();
  }

  private syncToolActiveFlags(): void {
    this.draftControlStore.rectActive = this.editable && this.currentTool === ActiveTool.Rect;
    this.draftControlStore.polygonToolActive = this.editable && this.currentTool === ActiveTool.Polygon;
    this.draftControlStore.pathToolActive = this.editable && this.currentTool === ActiveTool.Path;
    this.draftControlStore.textToolActive = this.editable && this.currentTool === ActiveTool.Text;
    if (!this.draftControlStore.rectActive && this.draftControlStore.showExactRectBar) {
      this.draftControlStore.showExactRectBar = false;
    }
  }

  private onEditableChanged(): void {
    this.syncToolActiveFlags();
    if (!this.editable) {
      this.draftControlStore.resetStamp();
      this.cancelActiveGesture();
      this.textInsertContext = '';
      this.pendingMoveIds = [];
      this.pendingMoveContext = '';
      this.textCreateController.close();
      this.moveFineTuneController.close();
      this.vertexStore.reset();
    }
    this.syncVertexStore();
  }

  private handleCanvasKeyEvent(event: KeyEvent): void {
    if (this.keyboardBlocked || isModalKeyboardBlocked()) {
      resetModifierKeys();
      event.stopPropagation();
      return;
    }
    const key: string = canvasKeyName(event.keyCode, event.keyText);
    if (event.type === KeyType.Down) {
      if (shortcutService.isMnemonicMode() && (key === 'ENTER' || key === 'ESCAPE')) {
        this.canvasKeyAction(event); event.stopPropagation(); return;
      }
      if (key === 'TAB' && this.currentTool === ActiveTool.Select && this.hitCandidates.length > 1) {
        this.cycleHitCandidate(isShiftHeld() ? -1 : 1);
        event.stopPropagation(); return;
      }
      if (this.currentTool === ActiveTool.Rect && key === 'TAB') {
        this.draftControlStore.rectDrawMode = this.draftControlStore.rectDrawMode === 1 ? 0 : 1;
        this.cursorStore.setReadout(this.draftControlStore.rectDrawMode === 1 ? '矩形模式：中心对称外扩 (Tab切换)' : '矩形模式：对角两点拉框 (Tab切换)');
        event.stopPropagation();
        return;
      }
      if (this.isDrawingPoly && key === 'TAB') {
        this.flipRoutingPosture();
        event.stopPropagation();
        return;
      }
      if (this.isDrawingPoly && key === 'ENTER') {
        this.finishPolyDraw();
        event.stopPropagation();
        return;
      }
      if (this.isDrawingPoly && key === 'BACKSPACE') {
        this.undoLastPolyVertex();
        event.stopPropagation();
        return;
      }
      if (this.draftControlStore.stampActive && key === 'R') {
        this.draftControlStore.cycleStampRotation();
        this.stampTransformChangedAction();
        this.refreshLiveStampPreview(this.lastPointerScreenX, this.lastPointerScreenY, false);
        event.stopPropagation();
        return;
      }
      if (key === 'ESCAPE' && this.draftControlStore.stampActive) {
        this.exitStampModeAction();
        event.stopPropagation();
        return;
      }
      if (key === 'ESCAPE' && (this.isDrawingPoly || this.hasCurveStart || this.draftControlStore.curveKind.length > 0 || this.hasPendingTextTouch || this.hasDrawStart || this.isDragging ||
        this.isBoxSelecting || this.vertexStore.isDragging() || this.measureStore.pending)) {
        this.cancelActiveGesture();
        event.stopPropagation();
        return;
      }
      if (key === 'ESCAPE' && this.currentTool === ActiveTool.Select) {
        let ctrl: boolean = isCtrlHeld();
        let alt: boolean = false;
        // Match Index's modifier gate and optional-API query order before dismissing hits.
        if (event.getModifierKeyState !== undefined) {
          try {
            ctrl = event.getModifierKeyState(['Ctrl']);
            event.getModifierKeyState(['Shift']);
            alt = event.getModifierKeyState(['Alt']);
          } catch (_error) {}
        }
        if (!ctrl && !alt && event.metaKey === 0) this.clearHitCandidates();
      }
    }
    this.canvasKeyAction(event);
  }

  /** UI-H3: selectedShapeId 变化时同步清除本地多选状态（外部 clearSelection/selectShape 时触发） */
  onSelectedShapeIdChange(): void {
    this.selectionCacheRevision = -1;
    // selectedShapeId 变为 -1 表示取消选择（如 DESELECT 快捷键），清除陈旧的 multiSelectIds
    if (this.selectedShapeId < 0) {
      this.multiSelectIds = [];
    }
    // 顶点编辑：换选中图形即换编辑目标（多选时不给句柄，避免歧义）
    this.syncVertexStore();
  }

  private handleShapeClick(capturedShape: Shape): void {
    if (this.currentTool !== ActiveTool.Select && this.currentTool !== ActiveTool.Move) {
      return;
    }
    // A queued old-node callback must never forward a previous document's
    // layer, geometry or cell reference after IDs are reused by a new file.
    const shape: Shape | undefined = editService.getShapes().find((candidate: Shape) =>
      candidate.id === capturedShape.id && editService.isShapeInCurrentCell(candidate));
    if (shape === undefined || !this.isShapeInteractable(shape)) return;
    const now: number = Date.now();
    const maxDblClickDistVp: number = this.lastInputIsTouch ? Math.max(24, TOUCH_DRAG_SLOP_VP * 2.4) : 12;
    const sameSpot: boolean = this.lastShapeClickAt <= 0 ||
      Math.hypot(this.lastPointerScreenX - this.lastShapeClickScreenX, this.lastPointerScreenY - this.lastShapeClickScreenY) <= maxDblClickDistVp;
    const isDoubleClick: boolean = this.lastShapeClickId === shape.id &&
      now - this.lastShapeClickAt <= DOUBLE_CLICK_THRESHOLD &&
      sameSpot;

    // Shift+Click 或触屏「加选」胶囊开启：免键盘加选/减选不相邻图形
    if (isShiftHeld() || this.multiSelectAdditive) {
      const currentIds: number[] = editService.getSelectedIds();
      const idx: number = currentIds.indexOf(shape.id);
      if (idx >= 0) {
        // 已选中 → 减选
        currentIds.splice(idx, 1);
      } else {
        // 未选中 → 加选
        currentIds.push(shape.id);
      }
      editService.selectMultiple(currentIds);
      this.multiSelectIds = currentIds;
      this.selectMultipleAction(currentIds);
      this.requestRenderAction();
      this.lastShapeClickId = shape.id;
      this.lastShapeClickAt = now;
      this.lastShapeClickScreenX = this.lastPointerScreenX;
      this.lastShapeClickScreenY = this.lastPointerScreenY;
      return;
    }

    this.multiSelectIds = [];
    this.selectShapeAction(shape);
    if (isDoubleClick && shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
      this.lastShapeClickId = -1;
      this.lastShapeClickAt = 0;
      this.lastShapeClickScreenX = 0;
      this.lastShapeClickScreenY = 0;
      const candidate: HierarchyHitCandidate | undefined = this.hitCandidates[this.hitCandidateIndex];
      if (candidate !== undefined && candidate.rootShapeId === shape.id && candidate.path.length > 0 &&
        this.onEnterInstancePath(candidate.path.slice(0, 1))) return;
      this.onEnterCell(shape.cellId);
      return;
    }
    this.lastShapeClickId = shape.id;
    this.lastShapeClickAt = now;
    this.lastShapeClickScreenX = this.lastPointerScreenX;
    this.lastShapeClickScreenY = this.lastPointerScreenY;
  }

  onShapesChange(): void {
    if (this.gestureCellId >= 0 && this.gestureCellId !== editService.getCurrentCellId()) this.onDocumentChanged();
    this.gestureCellId = editService.getCurrentCellId();
    // Selection-only refreshes keep the same revision, so Tab can keep cycling
    // concrete members. Geometry/history edits invalidate the saved hit paths.
    if (this.hitCandidateContext.length > 0 && this.hitCandidateContext !==
      `${this.documentKey}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`) this.clearHitCandidates();
    this.geometryRenderRevision++;
    this.syncCellStackState();
    // 顶点编辑：几何落库后重新投影句柄（拖拽中由 syncVertexStore 自行跳过）
    this.syncVertexStore();
  }

  private shapeRenderKey(shape: Shape): string {
    return `${this.geometryRenderRevision}:${this.styleRenderRevision}:${shape.id}`;
  }

  onSceneChanged(): void {
    // Edit hit/snap caches deliberately have no dependency on overlay sources.
    // Drop only derived presentation data when the authoritative scene changes.
    this.sceneService.clear();
    this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
  }

  private onHatchDensityChanged(): void {
    this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
  }

  private sceneDrawResult(): ViewSceneDrawResult {
    if (!this.renderSceneProvider) return { primitives: [], overflow: false, limit: 2000, message: '' };
    const frameKey: string = `${this.sceneRevision}:${this.styleRenderRevision}:${this.geometryRenderRevision}:${this.canvasWidth}:${this.canvasHeight}:${this.zoomPercent}:${this.viewOffsetX}:${this.viewOffsetY}:${this.hatchDensitySignal}`;
    if (frameKey === this.cachedSceneDrawFrameKey && this.cachedSceneDrawFrameResult !== undefined) {
      return this.cachedSceneDrawFrameResult;
    }
    try {
      const scene: ViewSceneDrawResult = this.sceneService.draw(this.renderSceneProvider(), sceneViewportFromCamera(this.canvasWidth,
        this.canvasHeight, this.zoomPercent, this.viewOffsetX, this.viewOffsetY, 96), 2000, this.zoomPercent);
      if (scene.overflow || !scene.primitives.some((p: ViewScenePrimitive): boolean =>
        p.kind !== 'text' && p.hierarchyFrame !== true && p.style.hatch.length > 0 &&
        p.opacity > 0 && p.style.fillOpacity > 0)) {
        this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
        this.cachedSceneDrawFrameKey = frameKey; this.cachedSceneDrawFrameResult = scene;
        return scene;
      }
      const density: number = this.getUIContext().vp2px(1);
      const key: string = JSON.stringify([this.canvasWidth, this.canvasHeight, this.zoomPercent,
        this.viewOffsetX, this.viewOffsetY, this.hatchDensitySignal, density]);
      if (this.hatchBudgetSource === scene && this.hatchBudgetKey === key && this.hatchBudgetResult !== undefined) {
        this.cachedSceneDrawFrameKey = frameKey; this.cachedSceneDrawFrameResult = this.hatchBudgetResult;
        return this.hatchBudgetResult;
      }
      let result: ViewSceneDrawResult = scene;
      try {
        verifySceneHatchBudget(scene, this.canvasWidth, this.canvasHeight, this.zoomPercent,
          this.viewOffsetX, this.viewOffsetY, density);
      } catch (e) {
        // Reject the whole frame and its edit overlays, never a truncated hatch.
        result = { primitives: [], overflow: true, limit: scene.limit, message: `当前场景未完整绘制：${e}` };
      }
      this.hatchBudgetSource = scene; this.hatchBudgetKey = key; this.hatchBudgetResult = result;
      this.cachedSceneDrawFrameKey = frameKey; this.cachedSceneDrawFrameResult = result;
      return result;
    } catch (e) {
      this.sceneService.clear();
      this.hatchBudgetSource = undefined; this.hatchBudgetResult = undefined; this.hatchBudgetKey = '';
    this.cachedSceneDrawFrameKey = ''; this.cachedSceneDrawFrameResult = undefined;
      const errRes: ViewSceneDrawResult = { primitives: [], overflow: true, limit: 2000, message: `当前来源无法完整绘制：${e}` };
      this.cachedSceneDrawFrameKey = frameKey; this.cachedSceneDrawFrameResult = errRes;
      return errRes;
    }
  }

  private measureSceneText(text: string): number {
    const context = this.getUIContext();
    const widthPx: number = context.getMeasureUtils().measureText({ textContent: text,
      fontSize: `${SCENE_TEXT_FONT_SIZE}vp`, fontFamily: FONT_MONO, fontWeight: FontWeight.Medium });
    return context.px2vp(widthPx);
  }

  private scenePrimitiveKey(primitive: ViewScenePrimitive): string {
    return `${this.sceneRevision}:${this.styleRenderRevision}:${this.geometryRenderRevision}:${primitive.key}`;
  }

  private sceneTextOverlaysForRender(): ViewScenePrimitive[] {
    if (!this.renderSceneProvider || this.zoomPercent < 0.5) {
      return [];
    }
    try {
      return this.sceneService.drawTextOverlays(
        this.renderSceneProvider(),
        sceneViewportFromCamera(this.canvasWidth, this.canvasHeight, this.zoomPercent, this.viewOffsetX, this.viewOffsetY, 96),
        256,
        this.zoomPercent
      );
    } catch (_) {
      return [];
    }
  }

  private sceneCapacityOverflow(): boolean {
    return this.renderSceneProvider !== null ? this.sceneDrawResult().overflow : this.fallbackDrawResult().overflow;
  }

  private ensureEditOverlayBuckets(): void {
    const revKey: string = `${this.documentKey}:${this.geometryRenderRevision}:${editService.getCurrentCellId()}:${this.selectedShapeId}:${this.selectedShapeCount}:${editService.getSelectionIdentity()}`;
    if (revKey === this.cachedEditOverlayRev) {
      return;
    }
    const instances: Shape[] = [];
    const selected: Shape[] = [];
    const currentCellId: number = editService.getCurrentCellId();
    const topCellId: number = editService.getTopCellId();
    for (let i = 0; i < this.shapes.length; i++) {
      const s: Shape = this.shapes[i];
      if (s.type === ShapeType.NODE) continue;
      const owner: number = s.ownerCellId !== undefined ? s.ownerCellId : topCellId;
      if (owner !== currentCellId) continue;
      if (this.isShapeSelected(s.id)) {
        selected.push(s);
      } else if (s.type === ShapeType.INSTANCE) {
        instances.push(s);
      }
    }
    this.cachedCurrentCellInstances = instances;
    this.cachedSelectedOverlayShapes = selected;
    this.cachedEditOverlayRev = revKey;
  }

  private sceneEditOverlaysForRender(): Shape[] {
    // This is the sole editing overlay. Source primitives never enter this path.
    if (this.renderSceneProvider !== null && (!this.glEnabled || !this.glActive) && this.sceneDrawResult().overflow) return [];
    this.ensureEditOverlayBuckets();
    if (this.hierarchyDepth < 2 || this.zoomPercent < 1 || this.cachedCurrentCellInstances.length === 0) {
      return this.cachedSelectedOverlayShapes;
    }
    const out: Shape[] = this.cachedSelectedOverlayShapes.slice();
    // Cap ArkUI instance anchor ShapeNodes at 256 in viewport so millions of array/cell instances never flood ArkUI layout
    let instCount: number = 0;
    for (let i = 0; i < this.cachedCurrentCellInstances.length && instCount < 256; i++) {
      const inst: Shape = this.cachedCurrentCellInstances[i];
      if (this.isInstanceAnchorInViewport(inst)) {
        out.push(inst);
        instCount++;
      }
    }
    return out;
  }

  private sceneTextSelectionPrimitive(shape: Shape): ViewScenePrimitive | undefined {
    if (this.renderSceneProvider === null) return undefined;
    try {
      const main: ViewSceneSource | undefined = this.renderSceneProvider().find((source: ViewSceneSource): boolean => !source.readOnly);
      if (main === undefined) return undefined;
      // Project the selected local TEXT through the authoritative scene service,
      // including its measured font box and intrinsic/source glyph affine.
      const source: ViewSceneSource = {
        sourceId: main.sourceId,
        sourceDocumentId: main.sourceDocumentId,
        revision: main.revision,
        shapes: [shape],
        cellNames: main.cellNames,
        layers: main.layers,
        cellId: main.cellId,
        topCellId: main.topCellId,
        depth: main.depth,
        transform: main.transform,
        opacity: main.opacity,
        readOnly: main.readOnly
      };
      const service: ViewRenderSceneService = new ViewRenderSceneService((text: string): number => this.measureSceneText(text));
      const result: ViewSceneDrawResult = service.draw([source], sceneViewportFromCamera(this.canvasWidth,
        this.canvasHeight, this.zoomPercent, this.viewOffsetX, this.viewOffsetY, 96), 1, this.zoomPercent);
      return result.primitives.find((primitive: ViewScenePrimitive): boolean => primitive.kind === 'text');
    } catch (e) {
      return undefined;
    }
  }

  private syncCellStackState(): void {
    this.cellStackIds = editService.getCurrentCellStack();
  }

  /** 双击处理：Polygon/Path 提交绘制 */
  private handleDoubleClick(event: GestureEvent): void {
    const fingers = event.fingerList;
    if (fingers.length === 0) {
      return;
    }
    const screenY: number = fingers[0].localY;
    if (screenY < this.activeTopBarThreshold()) {
      return;
    }

    // Polygon/Path 绘制中：双击提交，若第二击刚刚推入微偏重复末端点则先剥离再收尾
    if (this.isDrawingPoly) {
      const minPts: number = this.currentTool === ActiveTool.Path ? 2 : 3;
      if (this.lastPolyTapAddedCount > 0 &&
        Date.now() - this.lastPolyVertexTapAt <= DOUBLE_CLICK_THRESHOLD &&
        this.polygonPoints.length - this.lastPolyTapAddedCount >= minPts) {
        const tailPt: Point = this.polygonPoints[this.polygonPoints.length - 1];
        const prevPt: Point = this.polygonPoints[this.polygonPoints.length - 1 - this.lastPolyTapAddedCount];
        const screenGap: number = Math.hypot(
          this.worldToScreenX(tailPt.x) - this.worldToScreenX(prevPt.x),
          this.worldToScreenY(tailPt.y) - this.worldToScreenY(prevPt.y)
        );
        if (screenGap <= this.activePolyDoubleClickSlopVp()) {
          this.polygonPoints = this.polygonPoints.slice(0, this.polygonPoints.length - this.lastPolyTapAddedCount);
        }
      }
      this.lastPolyVertexTapAt = 0;
      this.lastPolyTapAddedCount = 0;
      this.finishPolyDraw();
    }
  }

  /**
   * KLayout 语义展开 + 视口裁剪（喂给 GL 主路径，减少 GPU 上传）。
   * depth=1 仅本地；depth≥2 含展开子几何与 INSTANCE 入口。
   */
  private displayShapesForRender(): Shape[] {
    const viewport = worldViewportFromCamera(
      this.canvasWidth,
      this.canvasHeight,
      this.zoomPercent,
      this.viewOffsetX,
      this.viewOffsetY,
      96
    );
    const culled: Shape[] = expandAndCullCellShapes(
      this.shapes,
      editService.getCurrentCellId(),
      this.hierarchyDepth,
      viewport,
      true
    );
    // 远景 LOD：小图元收成 bbox 矩形 / 丢弃亚像素
    return applyLodToShapes(culled, viewport, this.zoomPercent, true);
  }

  /** Avoid allocating an entire hierarchy when the GL surface is unavailable. */
  private fallbackDrawResult(): BoundedHierarchyDrawResult {
    const cellId: number = editService.getCurrentCellId();
    const key: string = `${this.geometryRenderRevision}:${this.styleRenderRevision}:${cellId}:${this.hierarchyDepth}:` +
      `${this.canvasWidth}:${this.canvasHeight}:${this.zoomPercent}:${this.viewOffsetX}:${this.viewOffsetY}`;
    if (key === this.fallbackDrawCacheKey) return this.fallbackDrawCache;
    const viewport = worldViewportFromCamera(this.canvasWidth, this.canvasHeight,
      this.zoomPercent, this.viewOffsetX, this.viewOffsetY, 96);
    // Hidden geometry and NODE metadata do not consume the drawing budget.
    // Keep instance definitions so visible children still expand through them.
    const source: Shape[] = this.shapes.filter((s: Shape) => s.type === ShapeType.INSTANCE ||
      (s.type !== ShapeType.NODE && this.isLayerVisible(s.layerNumber, s.datatype)));
    const result: BoundedHierarchyDrawResult = expandAndCullCellShapesBounded(
      source, cellId, this.hierarchyDepth, viewport, true, 2000);
    if (!result.overflow) result.shapes = applyLodToShapes(result.shapes, viewport, this.zoomPercent, true);
    this.fallbackDrawCache = result;
    this.fallbackDrawCacheKey = key;
    return result;
  }

  /**
   * 未裁剪展开结果（fit / 叠加层需要完整 bbox 时用）。
   */
  private expandedShapesUnculled(): Shape[] {
    return expandCellShapes(
      this.shapes,
      editService.getCurrentCellId(),
      this.hierarchyDepth,
      true
    );
  }

  /**
   * ArkUI 叠加层：
   * - GL 主路径活跃时只画可交互入口，避免每图元节点；
   * - 降级时画裁剪后的展开几何。
   */
  private overlayShapesForRender(): Shape[] {
    if (!this.glEnabled || !this.glActive) {
      return this.fallbackDrawResult().shapes;
    }
    // Only local objects can be edited. Expanding the entire hierarchy here merely
    // to discard synthetic geometry duplicates the expensive drawing traversal.
    const all: Shape[] = this.currentCellShapes();
    const overlay: Shape[] = [];
    let instanceMarkers: number = 0;
    for (let i = 0; i < all.length; i++) {
      const s: Shape = all[i];
      if (isExpandedSyntheticShape(s)) {
        continue;
      }
      if (s.type === ShapeType.INSTANCE) {
        // Thousands of via-cell anchor widgets obscure chip overviews and
        // create thousands of ArkUI nodes. Keep selected objects at every zoom;
        // close views show a bounded set of local navigation markers.
        const selected: boolean = this.isShapeSelected(s.id);
        if (this.hierarchyDepth >= 2 && (selected ||
          (this.zoomPercent >= 1 && instanceMarkers < 200 && this.isInstanceAnchorInViewport(s)))) {
          overlay.push(s);
          if (!selected) instanceMarkers++;
        }
        continue;
      }
      if (s.type === ShapeType.TEXT) {
        if (this.zoomPercent >= 1 || this.isShapeSelected(s.id) || this.hasRoomForOverviewLabel(s, overlay)) overlay.push(s);
        continue;
      }
      if (this.isShapeSelected(s.id)) {
        overlay.push(s);
      }
    }
    return overlay;
  }

  private isInstanceAnchorInViewport(shape: Shape): boolean {
    if (shape.points.length === 0) return false;
    const z: number = this.zoomPercent / 100;
    const x: number = (shape.points[0].x + this.viewOffsetX) * z;
    const y: number = (this.viewOffsetY - shape.points[0].y) * z;
    return x >= -72 && y >= -24 && x <= this.canvasWidth && y <= this.canvasHeight;
  }

  /** Overview labels stay local, inside the viewport and legible without overlap. */
  private hasRoomForOverviewLabel(shape: Shape, existing: Shape[]): boolean {
    if (shape.points.length === 0) return false;
    const z: number = this.zoomPercent / 100;
    const x: number = (shape.points[0].x + this.viewOffsetX) * z;
    const y: number = (this.viewOffsetY - shape.points[0].y) * z;
    const width: number = Math.max(48, (shape.text ?? '').length * 7.2);
    if (x < 0 || y < 0 || x + width > this.canvasWidth || y + 22 > this.canvasHeight) return false;
    let labels: number = 0;
    for (const previous of existing) {
      if (previous.type !== ShapeType.TEXT || previous.points.length === 0) continue;
      labels++;
      const px: number = (previous.points[0].x + this.viewOffsetX) * z;
      const py: number = (this.viewOffsetY - previous.points[0].y) * z;
      const pw: number = Math.max(48, (previous.text ?? '').length * 7.2);
      if (x < px + pw + 8 && x + width + 8 > px && y < py + 26 && y + 26 > py) return false;
    }
    return labels < 32;
  }

  private currentCellShapes(): Shape[] {
    return this.shapes.filter((shape: Shape) => editService.isShapeInCurrentCell(shape));
  }

  private isShapeInteractable(shape: Shape): boolean {
    if (shape.type === ShapeType.NODE) {
      return false;
    }
    if (isExpandedSyntheticShape(shape)) {
      return false;
    }
    if (!editService.isShapeInCurrentCell(shape)) {
      return false;
    }
    if (!this.isLayerVisible(shape.layerNumber, shape.datatype) || !editService.canSelectLayer(shape.layerNumber, shape.datatype)) {
      return false;
    }
    if (shape.type === ShapeType.INSTANCE) {
      return this.hierarchyDepth >= 2;
    }
    return true;
  }

  /** 顶部浮动栏：左侧面包屑（栈深>1 时显示），右侧层级滑块 */
  @Builder
  TopFloatingBar() {
    Row() {
      // 面包屑导航：仅当 Cell 栈深度 > 1 时显示
      if (this.cellStackIds.length > 1) {
        Row() {
          ForEach(this.cellStackLabels(), (item: BreadcrumbItem, idx: number) => {
            if (idx > 0) {
              Text(' > ')
                .fontSize(12)
                .fontColor(isWhiteCanvas() ? COLORS.muted : withAlpha('#FFFFFF', 0.4))
                .margin({ left: 2, right: 2 })
            }
            Button(item.label, { type: ButtonType.Normal })
              .height(UI.controlHeight)
              .fontSize(UI.fontBody)
              .fontColor(idx === this.cellStackIds.length - 1 ? canvasSelectionStroke() : canvasOverlayMuted())
              .padding({ left: 8, right: 8, top: 8, bottom: 8 })
              .backgroundColor(idx === this.cellStackIds.length - 1
                ? (isWhiteCanvas() ? COLORS.primarySoft : withAlpha(COLORS.primary, 0.32))
                : (isWhiteCanvas() ? canvasOverlayInactive() : withAlpha('#FFFFFF', 0.06)))
              .border({ width: 1, color: canvasOverlayBorder() }).borderRadius(UI.controlRadius)
              .focusable(false)
              .accessibilityText(item.label).bindTips(item.label)
              .onClick(() => {
                this.onBreadcrumbClick(idx);
              })
          }, (item: BreadcrumbItem, idx: number) => `${this.documentKey}_${idx}_${item.cellId}_${item.label}`)
        }
        .layoutWeight(1)
        .alignItems(VerticalAlign.Center)
      }

      // 层级滑块（1-5），触屏友好大滑块；深色玻璃容器（鸿蒙分层材质）
      Row() {
        Text('层级')
          .fontSize(12)
          .fontColor(canvasOverlayMuted())
          .margin({ right: 6 })
        Slider({
          value: this.hierarchyDepth,
          min: 1,
          max: 5,
          step: 1,
          style: SliderStyle.OutSet
        })
          .width(120)
          .blockSize({ width: 28, height: 28 })
          .focusable(false)
          .trackThickness(6)
          .selectedColor(COLORS.primary)
          .blockColor('#FFFFFF')
          .trackColor(isWhiteCanvas() ? COLORS.border : withAlpha('#FFFFFF', 0.18))
          .onChange((value: number, mode: SliderChangeMode) => {
            const n: number = Math.round(value);
            if (n !== this.hierarchyDepth) {
              // CANVAS-13: 不直接修改 @Prop，通过 viewService → onHierarchyDepthChange → Index.ets 回写
              viewService.setHierarchyDepth(n);
              this.requestRenderAction();
            }
          })
        Text(this.hierarchyDepth.toString())
          .fontSize(13)
          .fontColor(canvasOverlayInk())
          .fontWeight(FontWeight.Medium)
          .fontFamily(FONT_MONO)
          .margin({ left: 6 })
      }
      .alignItems(VerticalAlign.Center)
      .height(36)
      .padding({ left: 12, right: 12 })
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
    }
    .width(Math.max(0, this.canvasWidth - (this.desktopMode ? (this.canvasWidth >= 760 ? 304 : 72) : 0)))
    .height(44)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
    .position({
      x: this.desktopMode ? (this.canvasWidth >= 760 ? 296 : 72) : 0,
      y: this.desktopMode ? (this.canvasWidth >= 760 ? 6 : 50) : 48
    })
    .hitTestBehavior(HitTestMode.Default)
    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
    .onMouse((event: MouseEvent) => { event.stopPropagation(); })
  }

  private onInteractiveCurveKindChanged(): void {
    this.draftControlStore.curveKind = this.interactiveCurveKind;
    this.hasCurveStart = false;
    if (this.interactiveCurveKind.length > 0) {
      this.clearPolyDraw();
      this.cursorStore.setReadout(`画布拖拽${routingConstraintService.curveKindLabel(this.interactiveCurveKind)}：按下磁吸定圆心，拖动定半径`);
    } else {
      draftCanvasEngine.curvePreview = null;
      draftCanvasEngine.requestRepaint();
    }
  }

  private onRoutingModePropChanged(): void {
    this.draftControlStore.routingMode = this.routingMode;
    if (this.isDrawingPoly && this.polyLivePoint !== null) {
      this.updatePolyLivePreview(
        this.screenToWorldX(this.lastPointerScreenX),
        this.screenToWorldY(this.lastPointerScreenY),
        this.lastPointerScreenX,
        this.lastPointerScreenY,
        false
      );
    }
  }

  private shouldShowTopFloatingBar(): boolean {
    if (this.cellStackIds.length > 1) {
      return true;
    }
    if (this.desktopMode) {
      return false;
    }
    return !this.draftControlStore.hasAnyTopStrip();
  }

  private topControlStripY(): number {
    if (this.desktopMode) {
      return this.cellStackIds.length > 1 ? 66 : 50;
    }
    return this.cellStackIds.length > 1 ? 100 : 50;
  }

  private activeTopBarThreshold(): number {
    if (this.draftControlStore.hasAnyTopStrip()) {
      return this.topControlStripY() + 46;
    }
    if (this.shouldShowTopFloatingBar()) {
      return this.desktopMode ? 66 : 96;
    }
    return 46;
  }

  private ensureActiveLayerReadyForDraw(): boolean {
    const ln: number = this.selectedLayerNumber;
    const dt: number = this.selectedDatatype;
    const visible: boolean = this.isLayerVisible(ln, dt);
    const unlocked: boolean = editService.canEditLayer(ln, dt);
    if (visible && unlocked) {
      return true;
    }
    const reason: string = !visible && !unlocked ? '已隐藏且已锁定' : (!visible ? '当前已隐藏' : '当前已锁定');
    this.cursorStore.setReadout(`图层 L${ln}/D${dt} ${reason}，点击提示条可一键解锁并显示`);
    showAppSnackBar(this.getUIContext(), `图层 L${ln}/D${dt} ${reason}，无法起笔绘制`, {
      actionText: '解锁并显示',
      onAction: () => {
        this.unlockAndShowLayerAction(ln, dt);
      }
    });
    return false;
  }

  private refreshLiveStampPreview(screenX: number, screenY: number, showLoupe: boolean): Point {
    const wx: number = this.screenToWorldX(screenX);
    const wy: number = this.screenToWorldY(screenY);
    const rich: RichSnapResult = this.snapRichWorld(wx, wy);
    const pt: Point = rich.point;
    const tpl = this.stampTemplateProvider();
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;
    draftCanvasEngine.stampPreview = {
      anchor: pt,
      label: this.draftControlStore.stampLabel,
      rotation: this.draftControlStore.stampRotation,
      mirror: this.draftControlStore.stampMirror,
      outlines: tpl.outlines,
      ports: tpl.ports,
    };
    const rotInfo: string = this.draftControlStore.stampIsPCell
      ? ''
      : ` · R${this.draftControlStore.stampRotation}°` + (this.draftControlStore.stampMirror > 0 ? ` ${this.draftControlStore.stampMirrorLabel()}` : '');
    draftCanvasEngine.cursorHud = {
      screenX: screenX,
      screenY: screenY,
      primaryText: `${this.draftControlStore.stampLabel}${rotInfo}`,
      secondaryText: rich.readoutText.length > 0
        ? `${rich.readoutText} · 松手落位`
        : `落点 ${umText(pt.x)}, ${umText(pt.y)} µm`,
    };
    if (showLoupe) {
      this.updateTouchLoupe(screenX, screenY, pt, rich.readoutText);
    } else {
      draftCanvasEngine.loupe = null;
    }
    draftCanvasEngine.requestRepaint();
    return pt;
  }

  private setRoutingModeDirect(next: RoutingMode): void {
    this.draftControlStore.routingMode = next;
    this.routingModeChangeAction(next);
    this.cursorStore.setReadout(`走线约束：${routingConstraintService.modeLabel(next)}`);
    if (this.isDrawingPoly) {
      this.updatePolyLivePreview(
        this.screenToWorldX(this.lastPointerScreenX),
        this.screenToWorldY(this.lastPointerScreenY),
        this.lastPointerScreenX,
        this.lastPointerScreenY,
        this.lastInputIsTouch
      );
    }
  }

  private cycleRoutingMode(): void {
    const next: RoutingMode = routingConstraintService.nextMode(this.draftControlStore.routingMode);
    this.draftControlStore.routingMode = next;
    this.routingModeChangeAction(next);
    this.cursorStore.setReadout(`走线约束：${routingConstraintService.modeLabel(next)}`);
    if (this.isDrawingPoly) {
      this.updatePolyLivePreview(
        this.screenToWorldX(this.lastPointerScreenX),
        this.screenToWorldY(this.lastPointerScreenY),
        this.lastPointerScreenX,
        this.lastPointerScreenY,
        false
      );
    }
  }

  private flipRoutingPosture(): void {
    this.draftControlStore.horizontalFirst = !this.draftControlStore.horizontalFirst;
    this.cursorStore.setReadout(this.draftControlStore.horizontalFirst ? '正交拐向：横先' : '正交拐向：纵先');
    if (this.isDrawingPoly) {
      this.updatePolyLivePreview(
        this.screenToWorldX(this.lastPointerScreenX),
        this.screenToWorldY(this.lastPointerScreenY),
        this.lastPointerScreenX,
        this.lastPointerScreenY,
        false
      );
    }
  }

  private onPathWidthChanged(val: string): void {
    this.pathWidthStr = val;
    this.draftControlStore.pathWidthStr = val;
    this.syncPolyDraftCanvas();
  }

  private undoLastPolyVertex(): void {
    if (!this.isDrawingPoly) {
      return;
    }
    this.lastPolyVertexTapAt = 0;
    this.lastPolyTapAddedCount = 0;
    this.polygonPoints = this.polygonPoints.slice(0, -1);
    if (this.polygonPoints.length === 0) {
      this.clearPolyDraw();
      return;
    }
    this.draftControlStore.syncPolyState(true, this.currentTool === ActiveTool.Path, this.polygonPoints.length, false);
    this.syncPolyDraftCanvas();
  }

  private syncPolyDraftCanvas(): void {
    if (!this.isDrawingPoly) {
      draftCanvasEngine.polyPreview = null;
      draftCanvasEngine.requestRepaint();
      return;
    }
    const widthNm: number = this.normalizedPathWidth();
    draftCanvasEngine.polyPreview = {
      isPath: this.currentTool === ActiveTool.Path,
      committed: this.polygonPoints,
      liveTail: this.polyLiveTail,
      pathWidthNm: Number.isFinite(widthNm) && widthNm > 0 ? widthNm : 8,
      pathType: this.draftControlStore.pathType,
      layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      closeLoopReady: this.polyCloseLoopReady,
    };
    draftCanvasEngine.requestRepaint();
  }

  private canFinishPolyDraw(): boolean {
    if (!this.isDrawingPoly) {
      return false;
    }
    if (this.currentTool === ActiveTool.Polygon) {
      return this.polygonPoints.length >= 3;
    }
    if (this.currentTool === ActiveTool.Path) {
      return this.polygonPoints.length >= 2;
    }
    return false;
  }

  private finishPolyDraw(): void {
    if (!this.canFinishPolyDraw()) {
      return;
    }
    if (this.polyDrawContext.length > 0 && this.polyDrawContext !== this.editGestureContext()) {
      this.clearPolyDraw();
      this.cursorStore.setReadout('版图、图层或编辑状态已变化，绘制草稿已取消');
      return;
    }
    let points: Point[] = this.copyPoints(this.polygonPoints);
    while (points.length >= 2) {
      const a: Point = points[points.length - 1];
      const b: Point = points[points.length - 2];
      if (Math.abs(a.x - b.x) < 1e-6 && Math.abs(a.y - b.y) < 1e-6) {
        points = points.slice(0, points.length - 1);
      } else {
        break;
      }
    }
    if (points.length < (this.currentTool === ActiveTool.Path ? 2 : 3)) {
      this.cursorStore.setReadout('不同顶点数量不足，请继续绘制或取消');
      return;
    }
    if (this.currentTool === ActiveTool.Polygon && points.length > 3 &&
      Math.abs(points[0].x - points[points.length - 1].x) < 1e-6 &&
      Math.abs(points[0].y - points[points.length - 1].y) < 1e-6) {
      points.pop();
    }
    const outline: Shape = { id: 0, type: this.currentTool === ActiveTool.Path ? ShapeType.PATH : ShapeType.POLYGON,
      points: points, layerNumber: this.selectedLayerNumber, datatype: this.selectedDatatype, selected: false };
    const validation: VertexEditResult = advEditService.checkOutline(outline, points);
    if (!validation.ok) {
      this.cursorStore.setReadout(validation.message);
      return;
    }
    let created: boolean = false;
    if (this.currentTool === ActiveTool.Polygon) {
      created = this.createPolygonAction(points);
    } else if (this.currentTool === ActiveTool.Path) {
      const width: number = this.normalizedPathWidth();
      if (!Number.isFinite(width) || width <= 0) {
        this.cursorStore.setReadout('线宽必须是有限的正数（nm）');
        return;
      }
      if (this.draftControlStore.continuingShapeId >= 0) {
        created = this.continuePathCommitAction(this.draftControlStore.continuingShapeId, points, width, this.draftControlStore.pathType);
      } else {
        created = this.createPathAction(points, width, this.draftControlStore.pathType);
      }
    }
    if (!created) {
      this.cursorStore.setReadout('图形未创建，绘制草稿已保留；请查看状态栏原因');
      return;
    }
    this.clearPolyDraw();
  }

  private clearPolyDraw(): void {
    this.polygonPoints = [];
    this.isDrawingPoly = false;
    this.lastPolyVertexTapAt = 0;
    this.lastPolyVertexScreenX = 0;
    this.lastPolyVertexScreenY = 0;
    this.lastPolyTapAddedCount = 0;
    this.polyLivePoint = null;
    this.polyLiveTail = [];
    this.polyCloseLoopReady = false;
    this.hasPendingPolyTouch = false;
    this.polyDrawContext = '';
    this.polyDrawState = '';
    this.draftControlStore.resetPoly();
    draftCanvasEngine.polyPreview = null;
    draftCanvasEngine.snapMarker = null;
    draftCanvasEngine.alignmentGuides = [];
    draftCanvasEngine.cursorHud = null;
    draftCanvasEngine.loupe = null;
    draftCanvasEngine.requestRepaint();
  }

  private normalizedPathWidth(): number {
    return this.pathWidthStr.trim().length > 0 ? Number(this.pathWidthStr) : Number.NaN;
  }

  private clearMeasure(): void {
    // 持久标尺跨工具保留（KLayout 语义：切工具不删标尺）
    this.measureStore.reset();
    this.hasRulerDown = false;
    this.cursorStore.setReadout('');
  }

  /**
   * 读数文本（µm）：世界坐标内部为 nm，只在此处经 umText() 换算一次。
   * 同一份文本写入 CursorStore，供画布标签与状态栏共用，避免两处各自换算导致口径漂移。
   */
  private composeReadout(): string {
    const s: MeasureStore = this.measureStore;
    if (s.rulerMode) {
      const base: string = s.rulerReadout();
      if (!s.pending) {
        return base;
      }
      if (s.rulerOrientation === 'crosshair') {
        const ch: string = `十字标尺 (${s.formatLength(s.liveX)}, ${s.formatLength(s.liveY)})`;
        return base.length > 0 ? `${base}\n待落 ${ch}` : `待落 ${ch}`;
      }
      const isVert: boolean = s.rulerOrientation === 'vertical' ||
        (s.rulerOrientation === 'auto' && Math.abs(s.liveY - s.y1) > Math.abs(s.liveX - s.x1));
      const axis: string = isVert
        ? `竖直 X=${s.formatLength(s.liveX)}`
        : `水平 Y=${s.formatLength(s.liveY)}`;
      return base.length > 0 ? `${base}\n待落 ${axis}` : `待落 ${axis}`;
    }
    if (!s.hasSegment()) {
      return '';
    }
    const dx: number = s.dxNm();
    const dy: number = s.dyNm();
    if (s.isAreaMode()) {
      const wNm: number = Math.abs(dx);
      const hNm: number = Math.abs(dy);
      return `面积 ${s.formatArea(wNm * hNm)}  宽 ${s.formatLength(wNm)} × 高 ${s.formatLength(hNm)}  周长 ${s.formatLength(2 * (wNm + hNm))}`;
    }
    const line1: string = `距离 ${s.formatLength(s.distanceNm())}  Δx=${s.formatLength(dx)} Δy=${s.formatLength(dy)}`;
    const line2: string = `起(${umText(s.x1)}, ${umText(s.y1)})  终(${umText(s.endX())}, ${umText(s.endY())}) µm`
      + (s.pending ? '  ·拖动中' : '  ·已锁定');
    return `${line1}\n${line2}`;
  }

  /** 把当前测量/标尺读数同步到 CursorStore（状态栏 + 画布标签共用） */
  private syncReadout(): void {
    this.cursorStore.setReadout(this.composeReadout());
  }

  /**
   * Shift 约束（KLayout 测量拖拽按住 Shift 的语义）：端点落到最近的 8 方向
   * （水平 / 垂直 / 45°），长度取拖拽距离。tan(22.5°) 为最近的轴向判定阈值。
   */
  private constrainByShift(x: number, y: number): Point {
    const s: MeasureStore = this.measureStore;
    const dx: number = x - s.x1;
    const dy: number = y - s.y1;
    if (dx === 0 && dy === 0) {
      return { x: x, y: y };
    }
    const adx: number = Math.abs(dx);
    const ady: number = Math.abs(dy);
    const sx: number = dx < 0 ? -1 : 1;
    const sy: number = dy < 0 ? -1 : 1;
    const major: number = Math.max(adx, ady);
    if (major > 0 && Math.min(adx, ady) / major > ORTHO_TAN_HALF_45) {
      // 更接近对角：两轴取均值，得到精确 45°
      const m: number = (adx + ady) / 2;
      return { x: s.x1 + sx * m, y: s.y1 + sy * m };
    }
    return adx >= ady ? { x: s.x1 + sx * adx, y: s.y1 } : { x: s.x1, y: s.y1 + sy * ady };
  }

  private copyPoints(points: Point[]): Point[] {
    const out: Point[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push({ x: points[i].x, y: points[i].y });
    }
    return out;
  }

  /** 确认插入文本：由 TextCreateDialog onConfirm 回调触发 */
  private textCreateContext(): string {
    return `${this.editContextProvider()}:${this.documentKey}:${this.currentTool}:${this.editable}:` +
      `${this.selectedLayerNumber}/${this.selectedDatatype}`;
  }

  /** Cheap pointer-frame identity; commit checks below also compare the full selection. */
  private editGestureState(): string {
    return `${this.documentKey}:${editService.getSessionRevision()}:` +
      `${editService.getCurrentCellId()}:${this.currentTool}:${this.editable}:` +
      `${this.selectedLayerNumber}/${this.selectedDatatype}:${editService.canEditLayer(this.selectedLayerNumber, this.selectedDatatype)}`;
  }

  /** Snapshot the actual edit target, including changes made by keyboard/Undo before release. */
  private editGestureContext(): string {
    return `${this.editContextProvider()}:${this.editGestureState()}:` + editService.getSelectedIds().join(',');
  }

  private gestureContextCurrent(checkSelection: boolean = true): boolean {
    if (this.gestureContext.length > 0 && (checkSelection ? this.gestureContext !== this.editGestureContext() :
      this.gestureState !== this.editGestureState())) {
      this.cancelActiveGesture();
      this.cursorStore.setReadout('版图或选择已变化，原手势已取消');
      return false;
    }
    if (this.isDrawingPoly && this.polyDrawContext.length > 0 && (checkSelection ? this.polyDrawContext !== this.editGestureContext() :
      this.polyDrawState !== this.editGestureState())) {
      this.clearPolyDraw();
      this.cursorStore.setReadout('版图、图层或编辑状态已变化，绘制草稿已取消');
      return false;
    }
    return true;
  }

  private confirmTextCreate(text: string): boolean {
    if (!this.editable || this.currentTool !== ActiveTool.Text || this.textInsertContext.length === 0 ||
      this.textInsertContext !== this.textCreateContext()) return false;
    const ok: boolean = this.createTextAction(this.textInsertX, this.textInsertY, text) !== false;
    if (ok) this.textInsertContext = '';
    return ok;
  }

  private activeDragSlopVp(): number {
    return this.lastInputIsTouch ? TOUCH_DRAG_SLOP_VP : MOUSE_DRAG_SLOP_VP;
  }

  private activePolyDoubleClickSlopVp(): number {
    return this.lastInputIsTouch ? TOUCH_POLY_DBLCLICK_SLOP_VP : MOUSE_POLY_DBLCLICK_SLOP_VP;
  }

  private focusCanvasKeyboard(): void {
    if (this.keyboardBlocked || isModalKeyboardBlocked()) {
      return;
    }
    try {
      this.getUIContext().getFocusController().requestFocus('layout-canvas-keyboard');
    } catch (e) {
      console.warn(`[LayoutCanvasView] canvas focus unavailable: ${e}`);
    }
  }

  private handleMouse(event: MouseEvent): void {
    // 防死锁保护：HarmonyOS 在 MouseAction.Move 期间 event.button 为 MouseButton.None(0)，绝不可因 Move 重置中键拖拽！
    if (this.isMousePanning) {
      if (event.action === MouseAction.Hover || event.action === MouseAction.CANCEL ||
        (event.action === MouseAction.Press && event.button !== MouseButton.Middle) ||
        Date.now() - this.middleMouseDownAt > 20000) {
        this.isMousePanning = false;
      }
    }
    if ((event.action === MouseAction.Move || event.action === MouseAction.Hover) && !this.isMousePanning) {
      this.lastInputIsTouch = false;
      this.lastPointerScreenX = event.x;
      this.lastPointerScreenY = event.y;
      const wx: number = this.screenToWorldX(event.x);
      const wy: number = this.screenToWorldY(event.y);
      const activeInteractiveHover: boolean = this.draftControlStore.stampActive || this.isDrawingPoly ||
        this.hasDrawStart || this.isDragging || this.isBoxSelecting || this.vertexStore.isDragging() ||
        this.draftControlStore.curveKind.length > 0 ||
        (this.currentTool !== ActiveTool.Select && this.currentTool !== ActiveTool.Pan && this.currentTool !== ActiveTool.BoxZoom);
      const nowHoverMs: number = Date.now();
      if (activeInteractiveHover || nowHoverMs - this.lastIdleCursorUpdateAt >= 32) {
        this.lastIdleCursorUpdateAt = nowHoverMs;
        this.cursorStore.update(wx, wy);
      }

      if (event.y >= this.activeTopBarThreshold()) {
        if (this.draftControlStore.stampActive && !this.hasPendingStampTouch) {
          this.refreshLiveStampPreview(event.x, event.y, false);
        } else if (this.currentTool === ActiveTool.Rect && this.editable && this.draftControlStore.rectDrawMode === 2 && !this.hasDrawStart) {
          this.previewFixedSizeRect(wx, wy, event.x, event.y, false);
        } else if (this.isDrawingPoly) {
          this.updatePolyLivePreview(wx, wy, event.x, event.y, false);
        } else if (!this.hasDrawStart && !this.isDragging && !this.isBoxSelecting && !this.vertexStore.isDragging() &&
          (this.draftControlStore.curveKind.length > 0 || this.currentTool === ActiveTool.Rect ||
           this.currentTool === ActiveTool.Polygon || this.currentTool === ActiveTool.Path ||
           this.currentTool === ActiveTool.Text || this.currentTool === ActiveTool.Measure ||
           this.currentTool === ActiveTool.Move)) {
          const rich: RichSnapResult = this.snapRichWorld(wx, wy);
          draftCanvasEngine.snapMarker = rich.marker;
          draftCanvasEngine.alignmentGuides = rich.guides;
          draftCanvasEngine.cursorHud = null;
          draftCanvasEngine.loupe = null;
          if (this.currentTool !== ActiveTool.Measure) {
            this.cursorStore.setReadout(rich.readoutText);
          }
          draftCanvasEngine.requestRepaint();
        }
      }
    }
    if (event.action === MouseAction.Press) {
      this.focusCanvasKeyboard();
    }
    if (event.action === MouseAction.Press && event.button === MouseButton.Middle) {
      this.isMousePanning = true;
      this.middleMouseDownAt = Date.now();
      this.middleMouseStartX = event.x;
      this.middleMouseStartY = event.y;
      this.lastMousePanX = event.x;
      this.lastMousePanY = event.y;
      event.stopPropagation();
      return;
    }
    if (event.action === MouseAction.Move && this.isMousePanning) {
      const dx: number = event.x - this.lastMousePanX;
      const dy: number = event.y - this.lastMousePanY;
      this.lastMousePanX = event.x;
      this.lastMousePanY = event.y;
      if (dx !== 0 || dy !== 0) {
        this.panCanvasAction(dx, dy);
      }
      event.stopPropagation();
      return;
    }
    if ((event.action === MouseAction.Release || event.action === MouseAction.CANCEL) &&
      (this.isMousePanning || event.button === MouseButton.Middle)) {
      const wasPanning: boolean = this.isMousePanning;
      this.isMousePanning = false;
      if (wasPanning && event.action === MouseAction.Release) {
        const moveDist: number = Math.hypot(event.x - this.middleMouseStartX, event.y - this.middleMouseStartY);
        const nowMs: number = Date.now();
        if (moveDist <= 5) {
          if (nowMs - this.lastMiddleTapAt <= 380) {
            this.lastMiddleTapAt = 0;
            this.fitAllAction();
          } else {
            this.lastMiddleTapAt = nowMs;
          }
        } else {
          this.lastMiddleTapAt = 0;
        }
      }
      event.stopPropagation();
      return;
    }
  }

  private handleAxisEvent(event: AxisEvent): void {
    if (event.action === AxisAction.END || event.action === AxisAction.CANCEL) {
      return;
    }
    const pinchScale: number = event.getPinchAxisScaleValue();
    if (Number.isFinite(pinchScale) && pinchScale > 0 && Math.abs(pinchScale - 1) > 0.001) {
      this.zoomAtAction(event.x, event.y, pinchScale);
      return;
    }
    const horizontal: number = event.getHorizontalAxisValue();
    const vertical: number = event.getVerticalAxisValue();
    if (event.scrollStep !== undefined && Math.abs(vertical) > 0.001) {
      if (isShiftHeld() && !isCtrlHeld()) {
        this.panCanvasAction(0, -vertical * 2.4);
        return;
      }
      if (isCtrlHeld() && !isShiftHeld()) {
        this.panCanvasAction(-vertical * 2.4, 0);
        return;
      }
      this.zoomAtAction(event.x, event.y, vertical > 0 ? 0.85 : 1.18);
      return;
    }
    if (Math.abs(horizontal) > 0.001 || Math.abs(vertical) > 0.001) {
      this.panCanvasAction(-horizontal, -vertical);
    }
  }

  private hasTwoFingerGesture(event: GestureEvent): boolean {
    // SDK: 多指触摸板仅提供一个点，单指触摸板操作则标记为 MOUSE。
    return event.sourceTool === SourceTool.TOUCHPAD || event.fingerList.filter((finger: FingerInfo): boolean =>
      finger !== undefined && finger !== null).length >= 2;
  }

  private resolveTwoFingerCenter(event: GestureEvent): Point {
    const valid: FingerInfo[] = event.fingerList.filter((finger: FingerInfo): boolean =>
      finger !== undefined && finger !== null && Number.isFinite(finger.localX) && Number.isFinite(finger.localY));
    if (valid.length >= 2) {
      return {
        x: (valid[0].localX + valid[1].localX) * 0.5,
        y: (valid[0].localY + valid[1].localY) * 0.5,
      };
    }
    if (event.sourceTool === SourceTool.TOUCHPAD && Number.isFinite(event.pinchCenterX) && Number.isFinite(event.pinchCenterY)) {
      return { x: event.pinchCenterX, y: event.pinchCenterY };
    }
    if (Number.isFinite(this.lastPinchCenterX) && Number.isFinite(this.lastPinchCenterY) &&
      (this.lastPinchCenterX !== 0 || this.lastPinchCenterY !== 0)) {
      return { x: this.lastPinchCenterX, y: this.lastPinchCenterY };
    }
    return {
      x: Number.isFinite(event.pinchCenterX) ? event.pinchCenterX : this.canvasWidth * 0.5,
      y: Number.isFinite(event.pinchCenterY) ? event.pinchCenterY : this.canvasHeight * 0.5,
    };
  }

  private handleTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) {
      this.twoFingerNavigation = false;
      this.twoFingerPanActive = false;
      this.twoFingerPinchActive = false;
      // 手掌防误触、三指截屏或侧滑返回触发 TouchCancel 时，仅回滚未落定瞬态触摸，完整保留已点下的多边形/路径全部顶点
      this.cancelTransientPointerOnly();
      return;
    }
    if (this.isMousePanning) {
      if (event.source !== SourceType.Mouse || Date.now() - this.middleMouseDownAt > 20000) {
        this.isMousePanning = false;
      } else {
        return;
      }
    }
    // CANVAS-10: 弹框显示期间屏蔽画布触摸，避免误绘制/误选
    // （TextCreateDialog / MoveFineTuneDialog 已改为 @CustomDialog，系统模态遮罩自动屏蔽画布触摸）
    // 双指手势（缩放）时跳过单指逻辑，避免误触发绘制/拖拽
    const remainingTouches: TouchObject[] = event.type === TouchType.Up
      ? event.touches.filter((touch: TouchObject): boolean =>
        !event.changedTouches.some((changed: TouchObject): boolean => changed.id === touch.id))
      : event.touches;
    if (remainingTouches.length >= 2) {
      this.twoFingerNavigation = true;
      this.cancelTransientPointerOnly();
      return;
    }
    // Navigation owns the remaining finger until all contacts lift. Its Up must not commit an edit.
    if (this.twoFingerNavigation) {
      if (remainingTouches.length === 0) {
        this.twoFingerNavigation = false;
        this.twoFingerPanActive = false;
        this.twoFingerPinchActive = false;
      }
      return;
    }
    // Up 的终点由 changedTouches 提供，兼容 touches 是否仍包含抬起的触点。
    const points = event.type === TouchType.Up && event.changedTouches.length > 0
      ? event.changedTouches : event.touches;
    if (points.length === 0) {
      if (event.type === TouchType.Up) this.cancelTransientPointerOnly();
      return;
    }
    this.lastInputIsTouch = event.source !== SourceType.Mouse;
    const t = points[0];
    const screenX: number = t.x;
    const screenY: number = t.y;
    this.lastPointerScreenX = screenX;
    this.lastPointerScreenY = screenY;
    // 屏幕坐标 → 用户坐标 nm（与 ShapeNode / GL 同一变换，见 constants.worldToScreenPx）
    const userX: number = this.screenToWorldX(screenX);
    const userY: number = this.screenToWorldY(screenY);
    // 命中容差：鼠标精确点击用 8nm，触屏放大到 15nm（event.source 继承自 BaseEvent）
    const tolerance: number = (event.source === SourceType.Mouse ? 8 : 15) * 100 / Math.max(this.zoomPercent, 0.00001);
    // S-1: 光标坐标 + 光标下图层写入共享 CursorStore，由 CanvasHud/StatusBar 属性级观察刷新，
    // 不触发画布整树重建（替代原 @State cursorX/cursorY + cursorMoveAction 回调）
    this.cursorStore.update(userX, userY);
    this.trackCursorHit(userX, userY, tolerance);

    if (event.type === TouchType.Down) {
      this.focusCanvasKeyboard();
      this.onDown(userX, userY, screenX, screenY, tolerance);
    } else if (event.type === TouchType.Move) {
      this.onMove(userX, userY, screenX, screenY);
    } else if (event.type === TouchType.Up) {
      this.onUp(userX, userY, screenX, screenY);
    }
  }

  /**
   * 光标下方的图形/图层读数（KLayout 状态栏语义）。
   * hitTest 回退路径为全图线性扫描，故按 CURSOR_HIT_THROTTLE_MS 节流，仅在测量类工具下执行。
   */
  private trackCursorHit(userX: number, userY: number, tolerance: number): void {
    if (this.currentTool !== ActiveTool.Measure) {
      if (this.cursorStore.shapeId !== -1) {
        this.cursorStore.setHit(-1, -1);
      }
      return;
    }
    const now: number = Date.now();
    if (now - this.lastCursorHitAt < CURSOR_HIT_THROTTLE_MS) {
      return;
    }
    this.lastCursorHitAt = now;
    const hit: HierarchyHitResult = this.hitVisibleShape(userX, userY, tolerance);
    if (!hit.ok || hit.shapeId < 0) {
      this.cursorStore.setHit(-1, -1);
      if (!hit.ok) this.cursorStore.setReadout(hit.message);
      return;
    }
    this.cursorStore.setHit(hit.shapeId, hit.layerNumber, hit.datatype);
  }


  /**
   * 屏幕像素 <-> 用户坐标(nm)：统一委托 constants 里的唯一实现，
   * 画布命中、覆盖层绘制、MeasureLayer 共用同一变换（§3 统一 DBU/屏幕/Y 轴）。
   */
  private screenToWorldX(v: number): number {
    return screenToWorldPx(v, this.zoomPercent, this.viewOffsetX);
  }

  private screenToWorldY(v: number): number {
    return screenToWorldYpx(v, this.zoomPercent, this.viewOffsetY);
  }

  /** 用户坐标 nm → 屏幕像素（长度/尺寸换算，不含偏移） */
  private worldToScreen(v: number): number {
    return v * this.zoomPercent / 100;
  }

  private worldToScreenX(v: number): number {
    return worldToScreenPx(v, this.zoomPercent, this.viewOffsetX);
  }

  private worldToScreenY(v: number): number {
    return worldToScreenYpx(v, this.zoomPercent, this.viewOffsetY);
  }

  /**
   * 统一吸附入口（SNAP-1: 增加顶点吸附）。
   *
   * 行为优先级：顶点吸附 > 网格吸附 > 原坐标。
   * - 顶点吸附：吸附到已有图形顶点（含文本锚点），由 vertexSnapEnabled 控制
   * - 网格吸附：吸附到最近网格交点，由 snapEnabled + gridSize 控制
   *
   * 所有绘制工具（Rect/Polygon/Path/Measure/Text/Move）的落点均经此函数，
   * 消除 KLayout "Ruler 能吸附、Box tool 不能吸附" 的结构性不一致。
   */
  /**
   * 获取与相机平移/缩放解耦的 Cell 级空间网格桶索引（O(1) 邻域检索，消除视口超 5000 图元每帧重扫）
   */
  private getSpatialSnapIndex(): SpatialSnapIndex {
    const moving: boolean = this.isDragging && (this.currentTool === ActiveTool.Move || this.currentTool === ActiveTool.Select);
    const excluded: number[] = moving ? this.collectMoveIds() : [];
    // 检测是否为超多顶点大版图（如 BJUT 231 万顶点）：超过 8 万顶点时改用视口扩边局部磁吸索引
    let docVertEstimate: number = 0;
    let isHeavyVertexDoc: boolean = this.shapes.length > 5000;
    if (!isHeavyVertexDoc) {
      for (let i = 0; i < this.shapes.length; i++) {
        docVertEstimate += this.shapes[i].points.length;
        if (docVertEstimate > 80000) {
          isHeavyVertexDoc = true;
          break;
        }
      }
    }

    const baseKey: string = `${this.documentKey}:${this.geometryRenderRevision}:${this.styleRenderRevision}:${editService.getSessionRevision()}:` +
      `${editService.getCurrentCellId()}:${this.hierarchyDepth}:${excluded.join(',')}`;

    if (isHeavyVertexDoc) {
      const curVisVp: WorldViewport = worldViewportFromCamera(
        this.canvasWidth, this.canvasHeight, this.zoomPercent, this.viewOffsetX, this.viewOffsetY, 96
      );
      const vpStillCovered: boolean = this.snapCacheKey.startsWith(baseKey + ':vp:') &&
        this.snapCacheViewport !== null &&
        curVisVp.minX >= this.snapCacheViewport.minX && curVisVp.maxX <= this.snapCacheViewport.maxX &&
        curVisVp.minY >= this.snapCacheViewport.minY && curVisVp.maxY <= this.snapCacheViewport.maxY;
      if (!vpStillCovered) {
        const marginPx: number = Math.max(512, Math.max(this.canvasWidth, this.canvasHeight) * 1.25);
        const snapVp: WorldViewport = worldViewportFromCamera(
          this.canvasWidth, this.canvasHeight, this.zoomPercent, this.viewOffsetX, this.viewOffsetY, marginPx
        );
        const pixelSpanNm: number = 100 / Math.max(1e-6, this.zoomPercent);
        const minSnapSpanNm: number = pixelSpanNm * 2.0; // 屏幕跨度 <2px 的亚像素微结构在鸟瞰态跳过磁吸建桶
        const source: Shape[] = this.shapes.filter((s: Shape): boolean => excluded.indexOf(s.id) < 0 &&
          (s.type === ShapeType.INSTANCE || (s.type !== ShapeType.NODE && this.isLayerVisible(s.layerNumber, s.datatype))));
        const bounded: BoundedHierarchyDrawResult = expandAndCullCellShapesBounded(
          source, editService.getCurrentCellId(), this.hierarchyDepth, snapVp, true, 4000
        );
        const rawCandidates: Shape[] = !bounded.overflow
          ? bounded.shapes
          : this.currentCellShapes().filter((s: Shape): boolean => {
              if (excluded.indexOf(s.id) >= 0 || s.type === ShapeType.NODE || !this.isLayerVisible(s.layerNumber, s.datatype)) {
                return false;
              }
              if (s.points.length === 0) return false;
              const b: ShapeBounds = getShapeBounds(s);
              return b.maxX >= snapVp.minX && b.minX <= snapVp.maxX && b.maxY >= snapVp.minY && b.minY <= snapVp.maxY;
            });
        const trimmed: Shape[] = [];
        let accVerts: number = 0;
        for (let i = 0; i < rawCandidates.length; i++) {
          const cs: Shape = rawCandidates[i];
          if (cs.type !== ShapeType.INSTANCE && cs.type !== ShapeType.TEXT && cs.points.length > 8) {
            const cb: ShapeBounds = getShapeBounds(cs);
            if (Math.max(cb.maxX - cb.minX, cb.maxY - cb.minY) < minSnapSpanNm) {
              continue;
            }
          }
          trimmed.push(cs);
          accVerts += Math.min(cs.points.length, 64);
          if (trimmed.length >= 3500 || accVerts >= 90000) {
            break;
          }
        }
        this.snapCache = trimmed;
        this.snapCacheViewport = snapVp;
        this.snapCacheKey = `${baseKey}:vp:${Math.round(snapVp.minX)}_${Math.round(snapVp.minY)}_${Math.round(snapVp.maxX)}_${Math.round(snapVp.maxY)}`;
      }
      return snapService.ensureSpatialIndex(this.snapCacheKey, this.snapCache);
    }

    if (baseKey !== this.snapCacheKey) {
      const source: Shape[] = this.shapes.filter((s: Shape): boolean => excluded.indexOf(s.id) < 0 &&
        (s.type === ShapeType.INSTANCE || (s.type !== ShapeType.NODE && this.isLayerVisible(s.layerNumber, s.datatype))));
      const hugeViewport: WorldViewport = { minX: -1e12, minY: -1e12, maxX: 1e12, maxY: 1e12 };
      const result: BoundedHierarchyDrawResult = expandAndCullCellShapesBounded(
        source, editService.getCurrentCellId(), this.hierarchyDepth, hugeViewport, true, 5000
      );
      if (!result.overflow) {
        this.snapCache = result.shapes;
      } else {
        this.snapCache = this.currentCellShapes().filter((s: Shape): boolean => excluded.indexOf(s.id) < 0 &&
          s.type !== ShapeType.NODE && this.isLayerVisible(s.layerNumber, s.datatype));
      }
      this.snapCacheViewport = null;
      this.snapCacheKey = baseKey;
    }
    return snapService.ensureSpatialIndex(this.snapCacheKey, this.snapCache);
  }

  /**
   * 富磁吸计算入口：返回吸附坐标 + 视觉靶标（SnapMarker）+ 智能延伸对齐线（AlignmentGuides）
   */
  private snapRichWorld(
    x: number,
    y: number,
    extraAnchors: Point[] = [],
    closeLoopAnchor: Point | null = null,
    excludedShapeId: number = -1
  ): RichSnapResult {
    const geoEnabled: boolean = this.geometrySnapEnabled || this.vertexSnapEnabled;
    const index: SpatialSnapIndex | null = (geoEnabled || this.smartGuidesEnabled) ? this.getSpatialSnapIndex() : null;
    const thresholdNm: number = this.vertexScreenToWorldThreshold();
    const step: number = this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize;
    const viewportSpanNm: number = Math.max(this.canvasWidth, this.canvasHeight) * 100 / Math.max(this.zoomPercent, 0.00001);
    return snapService.snapRich(
      x,
      y,
      index,
      geoEnabled,
      thresholdNm,
      this.geometrySnapKinds,
      this.smartGuidesEnabled && geoEnabled,
      viewportSpanNm * 0.75,
      this.snapEnabled,
      step,
      extraAnchors,
      closeLoopAnchor,
      excludedShapeId
    );
  }

  private snapWorld(x: number, y: number): Point {
    const rich: RichSnapResult = this.snapRichWorld(x, y);
    if (this.currentTool !== ActiveTool.Measure) {
      this.cursorStore.setReadout(rich.readoutText);
    }
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;
    return rich.point;
  }

  private snapMeasurePoint(x: number, y: number): Point {
    const rich: RichSnapResult = this.snapRichWorld(x, y);
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;
    draftCanvasEngine.requestRepaint();
    return rich.point;
  }

  /** 触屏自动放大磁吸捕获半径（触屏 >=24vp，鼠标 >=13vp），随缩放恒定换算世界 nm */
  private vertexScreenToWorldThreshold(): number {
    const basePx: number = this.lastInputIsTouch
      ? Math.max(24, this.vertexSnapThreshold * 1.5)
      : Math.max(13, this.vertexSnapThreshold);
    return this.zoomPercent > 0
      ? basePx * 100 / this.zoomPercent
      : basePx;
  }

  private snapCandidates(x?: number, y?: number): Shape[] {
    const index: SpatialSnapIndex = this.getSpatialSnapIndex();
    if (x !== undefined && y !== undefined) {
      return index.queryShapesNear(x, y, this.vertexScreenToWorldThreshold() * 2);
    }
    return this.snapCache;
  }

  /** 提取放大镜内局部可见图元（最多 48 个，O(1) 空间桶查询） */
  private buildTouchLoupeShapes(worldX: number, worldY: number): DraftLoupeShape[] {
    const radiusNm: number = 64 * 100 / Math.max(this.zoomPercent * 2.5, 0.05);
    const local: Shape[] = this.getSpatialSnapIndex().queryShapesNear(worldX, worldY, radiusNm);
    const out: DraftLoupeShape[] = [];
    for (let i = 0; i < local.length && out.length < 48; i++) {
      const s: Shape = local[i];
      if (s.type === ShapeType.TEXT || s.type === ShapeType.INSTANCE || s.type === ShapeType.NODE || s.points.length === 0) {
        continue;
      }
      let pts: Point[] = s.points;
      if (s.type === ShapeType.RECT && s.points.length === 2) {
        const b: ShapeBounds = getShapeBounds(s);
        pts = [
          { x: b.minX, y: b.minY },
          { x: b.maxX, y: b.minY },
          { x: b.maxX, y: b.maxY },
          { x: b.minX, y: b.maxY },
        ];
      }
      out.push({
        closed: s.type !== ShapeType.PATH,
        points: pts,
        color: this.colorForLayer(s.layerNumber, s.datatype),
      });
    }
    return out;
  }

  private updateTouchLoupe(screenX: number, screenY: number, snappedPt: Point, snapLabel: string): void {
    if (!this.lastInputIsTouch || !this.touchLoupeEnabled) {
      draftCanvasEngine.loupe = null;
      return;
    }
    const step: number = this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize;
    const badge: string = snapLabel.length > 0
      ? snapLabel.replace('吸附：', '')
      : `${umText(snappedPt.x)}, ${umText(snappedPt.y)}`;
    draftCanvasEngine.loupe = {
      active: true,
      fingerScreenX: screenX,
      fingerScreenY: screenY,
      snappedWorldX: snappedPt.x,
      snappedWorldY: snappedPt.y,
      gridStepNm: this.snapEnabled ? step : 0,
      badgeText: badge,
      localShapes: this.buildTouchLoupeShapes(snappedPt.x, snappedPt.y),
    };
  }

  /** 构建移动/拖拽时的轻量轮廓残影集合（仅在 onDown 执行一次） */
  private captureMoveGhostOutlines(): DraftGhostOutline[] {
    const ids: number[] = this.collectMoveIds();
    const outlines: DraftGhostOutline[] = [];
    for (let i = 0; i < ids.length && outlines.length < 128; i++) {
      const s: Shape | undefined = this.shapes.find((item: Shape): boolean => item.id === ids[i]);
      if (s === undefined || s.points.length === 0) continue;
      const col: string = this.colorForLayer(s.layerNumber, s.datatype);
      if (s.type === ShapeType.RECT && s.points.length === 2) {
        const b: ShapeBounds = getShapeBounds(s);
        outlines.push({
          closed: true,
          points: [
            { x: b.minX, y: b.minY },
            { x: b.maxX, y: b.minY },
            { x: b.maxX, y: b.maxY },
            { x: b.minX, y: b.maxY },
          ],
          color: col,
        });
      } else if (s.type === ShapeType.POLYGON && hasKeyholeBridgeEdges(s.points)) {
        const cleanLoops: Point[][] = extractKeyholeCleanLoops(s.points);
        for (let li = 0; li < cleanLoops.length && outlines.length < 128; li++) {
          outlines.push({
            closed: true,
            points: cleanLoops[li],
            color: col,
          });
        }
      } else if (s.type === ShapeType.POLYGON || s.type === ShapeType.PATH) {
        outlines.push({
          closed: s.type === ShapeType.POLYGON,
          points: s.points,
          color: col,
        });
      } else {
        const b: ShapeBounds = getShapeBounds(s);
        outlines.push({
          closed: true,
          points: [
            { x: b.minX, y: b.minY },
            { x: b.maxX, y: b.minY },
            { x: b.maxX, y: b.maxY },
            { x: b.minX, y: b.maxY },
          ],
          color: col,
        });
      }
    }
    return outlines;
  }

  /**
   * 统一计算 Polygon / Path 实时磁吸、正交/45° 走线折点、真实线宽包络、尺寸浮标与触屏放大镜
   */
  private updatePolyLivePreview(
    userX: number,
    userY: number,
    screenX: number,
    screenY: number,
    showLoupe: boolean
  ): RoutedSnapPreview {
    const closeAnchor: Point | null = (this.currentTool === ActiveTool.Polygon && this.polygonPoints.length >= 3)
      ? this.polygonPoints[0]
      : null;
    const rich: RichSnapResult = this.snapRichWorld(userX, userY, this.polygonPoints, closeAnchor);
    const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
    const routed: RoutedSegmentResult = routingConstraintService.routeNextPoints(
      this.polygonPoints,
      rich.point,
      this.draftControlStore.routingMode,
      isShiftHeld(),
      this.draftControlStore.horizontalFirst,
      this.draftControlStore.useLBend,
      step,
      rich.snappedGeometry
    );

    this.polyLivePoint = routed.endPoint;
    this.polyLiveTail = routed.previewTail;
    this.polyCloseLoopReady = rich.closeLoopHit;

    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;

    const widthNm: number = this.normalizedPathWidth();
    draftCanvasEngine.polyPreview = {
      isPath: this.currentTool === ActiveTool.Path,
      committed: this.polygonPoints,
      liveTail: routed.previewTail,
      pathWidthNm: Number.isFinite(widthNm) && widthNm > 0 ? widthNm : 8,
      pathType: this.draftControlStore.pathType,
      layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      closeLoopReady: rich.closeLoopHit,
    };

    if (this.polygonPoints.length >= 1) {
      const anchor: Point = this.polygonPoints[this.polygonPoints.length - 1];
      const dx: number = routed.endPoint.x - anchor.x;
      const dy: number = routed.endPoint.y - anchor.y;
      const primary: string = `段长 ${umText(routed.segmentLengthNm)} µm · ${routed.modeBadge}`;
      const secondary: string = rich.closeLoopHit
        ? '松手或单击自动闭合多边形'
        : `Δx ${umText(dx)}  Δy ${umText(dy)} µm` + (this.currentTool === ActiveTool.Path ? ` · 宽 ${umText(widthNm)}µm` : '');
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: primary,
        secondaryText: secondary,
      };
      this.cursorStore.setReadout(rich.readoutText.length > 0 ? `${rich.readoutText} · ${primary}` : primary);
    } else {
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `${umText(routed.endPoint.x)}, ${umText(routed.endPoint.y)} µm`,
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : `起点待落 · ${routed.modeBadge}`,
      };
      this.cursorStore.setReadout(rich.readoutText);
    }

    if (showLoupe) {
      this.updateTouchLoupe(screenX, screenY, routed.endPoint, rich.readoutText);
    } else {
      draftCanvasEngine.loupe = null;
    }
    draftCanvasEngine.requestRepaint();
    return { rich: rich, routed: routed };
  }

  private snapVertex(x: number, y: number): Point | null {
    if (!this.vertexSnapEnabled || this.shapes.length === 0) {
      return null;
    }
    return snapService.snapToVertex(x, y, this.snapCandidates(x, y), this.vertexScreenToWorldThreshold());
  }

  // ===== 顶点编辑手势（§6 · E-TX：一次手势 = 一条撤销记录） =====

  /**
   * 是否存在「唯一选中且可顶点编辑」的图形。
   * 只读 @Prop shapes / editService，不读 VertexStore —— 否则画布主体会观察 store，
   * 指针级属性一变就重建整树（本仓库的高频状态红线）。
   */
  private hasVertexTarget(): boolean {
    if (!this.editable) return false;
    const ids: number[] = editService.getSelectedIds();
    if (ids.length !== 1) {
      return false;
    }
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === ids[0]);
    return shape !== undefined && this.isShapeInteractable(shape) &&
      editService.canEditLayer(shape.layerNumber, shape.datatype) && advEditService.isVertexEditable(shape);
  }

  /**
   * 真相同步点：选择集 / 图形列表变化后，把「唯一选中且可编辑」图形的归一化顶点写进
   * VertexStore。图形真相始终在 editService 里，这里只是一份编辑期投影（拖拽中跳过，
   * 免得用落库前的旧几何覆盖实时预览）。
   */
  private canEnterSingleSelectedInstance(): boolean {
    const selected: Shape[] = editService.getSelectedShapes();
    return selected.length === 1 && selected[0].type === ShapeType.INSTANCE && selected[0].cellId !== undefined;
  }

  private hasSelectedInstance(): boolean {
    return editService.getSelectedShapes().some((s: Shape): boolean => s.type === ShapeType.INSTANCE);
  }

  private canRoundSingleSelection(): boolean {
    if (!this.editable) return false;
    const ids: number[] = editService.getSelectedIds();
    if (ids.length !== 1) return false;
    const s: Shape | undefined = this.shapes.find((item: Shape) => item.id === ids[0]);
    return s !== undefined && (s.type === ShapeType.RECT || s.type === ShapeType.POLYGON) &&
      editService.canEditLayer(s.layerNumber, s.datatype);
  }

  private canContinueSelectedPath(): boolean {
    if (!this.editable) return false;
    const ids: number[] = editService.getSelectedIds();
    if (ids.length !== 1) return false;
    const s: Shape | undefined = this.shapes.find((item: Shape) => item.id === ids[0]);
    return s !== undefined && s.type === ShapeType.PATH && s.points.length >= 2 &&
      editService.canEditLayer(s.layerNumber, s.datatype);
  }

  private startContinueSelectedPath(): void {
    const ids: number[] = editService.getSelectedIds();
    if (ids.length !== 1) return;
    const s: Shape | undefined = this.shapes.find((item: Shape) => item.id === ids[0]);
    if (s === undefined || s.type !== ShapeType.PATH || s.points.length < 2) return;
    const pts: Point[] = this.copyPoints(s.points);
    const wNm: number = s.pathWidth !== undefined && s.pathWidth > 0 ? s.pathWidth : 8;
    const ptType: number = s.pathType === 1 || s.pathType === 2 ? s.pathType : 0;
    this.selectActiveLayerAction(s.layerNumber, s.datatype);
    this.pathWidthStr = String(wNm);
    this.draftControlStore.pathWidthStr = String(wNm);
    this.draftControlStore.pathType = ptType;
    this.draftControlStore.continuingShapeId = s.id;
    this.polygonPoints = pts;
    this.isDrawingPoly = true;
    this.requestPathToolAction();
    this.polyDrawContext = this.editGestureContext();
    this.polyDrawState = this.editGestureState();
    this.draftControlStore.syncPolyState(true, true, pts.length, false);
    this.syncPolyDraftCanvas();
    this.cursorStore.setReadout(`已衔接路径 #${s.id} 末端，点击继续延伸走线，点「完成」合并更新`);
  }

  private shapeScreenBox(pts: Point[]): ScreenSpanBox {
    if (pts.length === 0) {
      const emptyBox: ScreenSpanBox = { minX: 0, maxX: 0, minY: 0, maxY: 0, spanW: 0, spanH: 0 };
      return emptyBox;
    }
    let minX: number = this.worldToScreenX(pts[0].x);
    let maxX: number = minX;
    let minY: number = this.worldToScreenY(pts[0].y);
    let maxY: number = minY;
    for (let i = 1; i < pts.length; i++) {
      const sx: number = this.worldToScreenX(pts[i].x);
      const sy: number = this.worldToScreenY(pts[i].y);
      minX = Math.min(minX, sx);
      maxX = Math.max(maxX, sx);
      minY = Math.min(minY, sy);
      maxY = Math.max(maxY, sy);
    }
    const resultBox: ScreenSpanBox = { minX: minX, maxX: maxX, minY: minY, maxY: maxY, spanW: maxX - minX, spanH: maxY - minY };
    return resultBox;
  }

  private shapeScreenSpanEnoughForAutoHandles(pts: Point[]): boolean {
    if (pts.length === 0) return false;
    const box: ScreenSpanBox = this.shapeScreenBox(pts);
    return Math.max(box.spanW, box.spanH) >= RECT_HANDLE_AUTO_MIN_SPAN_VP;
  }

  /**
   * 选中矩形八手柄自适应命中判定：
   * 1. 当矩形屏幕宽高较小（如 42~96 vp 或窄条图形）时，按短边比例自适应收窄向内手柄热区半径；
   * 2. 优先保留矩形中心至少 44%×44% 的整体拖拽平移安全区，防止 44×44 vp 手柄热区 100% 吞没中小矩形；
   * 3. 在有效热区内按欧氏距离择优命中最近角点或边中点推拉柄。
   */
  private hitRectHandleAdaptive(pts: Point[], edges: Point[], screenX: number, screenY: number): RectHandleHit {
    const box: ScreenSpanBox = this.shapeScreenBox(pts);
    const minSpan: number = Math.min(box.spanW, box.spanH);
    const inwardHit: number = minSpan < RECT_HANDLE_FULL_HIT_SPAN_VP
      ? Math.max(8, Math.min(VERTEX_HANDLE_HIT_PX, minSpan * 0.24))
      : VERTEX_HANDLE_HIT_PX;
    const outwardHit: number = minSpan < RECT_HANDLE_FULL_HIT_SPAN_VP
      ? Math.max(12, Math.min(VERTEX_HANDLE_HIT_PX, inwardHit + 5))
      : VERTEX_HANDLE_HIT_PX;
    const keepMarginRatio: number = (1 - RECT_INTERIOR_MOVE_MIN_RATIO) * 0.5;
    const marginX: number = Math.min(inwardHit, box.spanW * keepMarginRatio);
    const marginY: number = Math.min(inwardHit, box.spanH * keepMarginRatio);
    if (box.spanW >= 18 && box.spanH >= 18 &&
      screenX > box.minX + marginX && screenX < box.maxX - marginX &&
      screenY > box.minY + marginY && screenY < box.maxY - marginY) {
      const missCenter: RectHandleHit = { isEdge: false, index: -1 };
      return missCenter;
    }
    const insideRect: boolean = screenX >= box.minX && screenX <= box.maxX &&
      screenY >= box.minY && screenY <= box.maxY;
    const hitRadius: number = insideRect ? inwardHit : outwardHit;
    let bestIndex: number = -1;
    let bestIsEdge: boolean = false;
    let bestDist: number = Number.POSITIVE_INFINITY;
    for (let i = 0; i < pts.length; i++) {
      const dx: number = this.worldToScreenX(pts[i].x) - screenX;
      const dy: number = this.worldToScreenY(pts[i].y) - screenY;
      if (Math.abs(dx) <= hitRadius && Math.abs(dy) <= hitRadius) {
        const d: number = Math.hypot(dx, dy);
        if (d < bestDist) {
          bestDist = d;
          bestIndex = i;
          bestIsEdge = false;
        }
      }
    }
    for (let i = 0; i < edges.length; i++) {
      const dx: number = this.worldToScreenX(edges[i].x) - screenX;
      const dy: number = this.worldToScreenY(edges[i].y) - screenY;
      if (Math.abs(dx) <= hitRadius && Math.abs(dy) <= hitRadius) {
        const d: number = Math.hypot(dx, dy);
        if (d < bestDist) {
          bestDist = d;
          bestIndex = i;
          bestIsEdge = true;
        }
      }
    }
    const hitOut: RectHandleHit = { isEdge: bestIsEdge, index: bestIndex };
    return hitOut;
  }

  private syncVertexStore(): void {
    const store: VertexStore = this.vertexStore;
    if (!this.editable) {
      if (store.isDragging()) store.revert();
      store.bind(-1, true, 0, [], [], false);
      return;
    }
    if (store.isDragging()) {
      return;
    }
    const ids: number[] = editService.getSelectedIds();
    const targetId: number = ids.length === 1 ? ids[0] : -1;
    const shape: Shape | undefined = targetId >= 0
      ? this.shapes.find((s: Shape) => s.id === targetId)
      : undefined;
    if (shape === undefined || !this.isShapeInteractable(shape) ||
      !editService.canEditLayer(shape.layerNumber, shape.datatype) || !advEditService.isVertexEditable(shape)) {
      store.bind(-1, true, 0, [], [], false);
      return;
    }
    const pts: Point[] = advEditService.normalizedVertexPoints(shape);
    const isRect: boolean = shape.type === ShapeType.RECT;
    // 矩形提供 4 条边的单向推拉柄；多边形/路径提供边中点插入顶点柄
    const handles: Point[] = isRect ? advEditService.rectEdgeMidpoints(pts) : advEditService.edgeInsertPoints(shape, pts);
    const prevId: number = store.shapeId;
    store.bind(shape.id, shape.type !== ShapeType.PATH, shape.layerNumber, pts, handles, isRect);
    // 单选大尺寸矩形自动亮起四角与四边推拉手柄（缩放过小时自动避让防抢整体拖动）
    if (isRect && prevId !== shape.id && !store.explicitlyPinned) {
      store.active = this.shapeScreenSpanEnoughForAutoHandles(pts);
    }
  }

  /** 屏幕空间命中顶点句柄（返回索引，-1 = 未命中） */
  private vertexHandleIndex(screenX: number, screenY: number): number {
    const pts: Point[] = this.vertexStore.displayPoints();
    for (let i = 0; i < pts.length; i++) {
      if (Math.abs(this.worldToScreenX(pts[i].x) - screenX) <= VERTEX_HANDLE_HIT_PX &&
        Math.abs(this.worldToScreenY(pts[i].y) - screenY) <= VERTEX_HANDLE_HIT_PX) {
        return i;
      }
    }
    return -1;
  }

  /** 屏幕空间命中边中点「插入」柄 */
  private vertexEdgeIndex(screenX: number, screenY: number): number {
    const handles: Point[] = this.vertexStore.edgeHandles;
    for (let i = 0; i < handles.length; i++) {
      if (Math.abs(this.worldToScreenX(handles[i].x) - screenX) <= VERTEX_HANDLE_HIT_PX &&
        Math.abs(this.worldToScreenY(handles[i].y) - screenY) <= VERTEX_HANDLE_HIT_PX) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 按下：句柄优先于「选中/拖动整个图形」。
   * @returns true = 本次按下已被顶点手势消费，onDown 不再走选择/整体拖拽分支
   */
  private onVertexDown(screenX: number, screenY: number): boolean {
    if (!this.editable) return false;
    const store: VertexStore = this.vertexStore;
    if (!store.isEditing() || store.isDragging() || store.points.length === 0) {
      return false;
    }
    if (screenY > this.canvasHeight - VERTEX_STRIP_HEIGHT) {
      return false; // 底部模式条区域让位给按钮
    }
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === store.shapeId);
    if (shape === undefined || !this.isShapeInteractable(shape)) {
      return false;
    }
    store.setHint('');
    if (store.deleteMode) {
      const di: number = this.vertexHandleIndex(screenX, screenY);
      if (di < 0) {
        return false;
      }
      store.beginDrag(di, advEditService.withVertexRemoved(store.points, di), 3,
        editService.getSessionRevision(), editService.getCurrentCellId());
      return true;
    }
    if (!store.explicitlyPinned && !this.shapeScreenSpanEnoughForAutoHandles(store.points)) {
      return false;
    }
    if (shape.type === ShapeType.RECT) {
      const rectHit: RectHandleHit = this.hitRectHandleAdaptive(store.displayPoints(), store.edgeHandles, screenX, screenY);
      if (rectHit.index < 0) {
        return false;
      }
      if (!rectHit.isEdge) {
        const rvi: number = rectHit.index;
        store.originVertexX = store.points[rvi].x;
        store.originVertexY = store.points[rvi].y;
        store.beginDrag(rvi,
          advEditService.withVertexMoved(shape, store.points, rvi, store.points[rvi].x, store.points[rvi].y), 1,
          editService.getSessionRevision(), editService.getCurrentCellId());
        return true;
      }
      const rei: number = rectHit.index;
      const rmid: Point = store.edgeHandles[rei];
      store.originVertexX = rmid.x;
      store.originVertexY = rmid.y;
      store.beginDrag(rei, advEditService.withRectEdgeMoved(store.points, rei, rmid.x, rmid.y), 4,
        editService.getSessionRevision(), editService.getCurrentCellId());
      return true;
    }
    const vi: number = this.vertexHandleIndex(screenX, screenY);
    if (vi >= 0) {
      store.originVertexX = store.points[vi].x;
      store.originVertexY = store.points[vi].y;
      store.beginDrag(vi,
        advEditService.withVertexMoved(shape, store.points, vi, store.points[vi].x, store.points[vi].y), 1,
        editService.getSessionRevision(), editService.getCurrentCellId());
      return true;
    }
    const ei: number = this.vertexEdgeIndex(screenX, screenY);
    if (ei >= 0) {
      const mid: Point = store.edgeHandles[ei];
      store.originVertexX = mid.x;
      store.originVertexY = mid.y;
      store.beginDrag(ei + 1, advEditService.withVertexInserted(shape, store.points, ei, mid.x, mid.y), 2,
        editService.getSessionRevision(), editService.getCurrentCellId());
      return true;
    }
    return false;
  }

  private vertexGestureCurrent(): boolean {
    const store: VertexStore = this.vertexStore;
    const ids: number[] = editService.getSelectedIds();
    return store.gestureRevision === editService.getSessionRevision() &&
      store.gestureCellId === editService.getCurrentCellId() && ids.length === 1 && ids[0] === store.shapeId;
  }

  /** pointer Move：只写预览（VertexStore），不落库、不推撤销记录、不重建画布整树 */
  private onVertexMove(userX: number, userY: number): void {
    const store: VertexStore = this.vertexStore;
    if (!this.editable) {
      store.revert();
      return;
    }
    if (!store.isDragging() || store.gestureKind === 3) {
      return; // 删除是单击语义，拖动不改变结果
    }
    if (!this.vertexGestureCurrent()) {
      store.revert(); store.setHint('版图或选择已变化，顶点预览已取消'); return;
    }
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === store.shapeId);
    if (shape === undefined) {
      return;
    }
    const skipIndex: number = store.gestureKind === 1 ? store.dragIndex : -1;
    const rich: RichSnapResult = this.snapRichWorld(userX, userY, [], null, store.shapeId);
    const p: Point = rich.snappedGeometry
      ? rich.point
      : snapService.snapForVertexDrag(userX, userY, this.snapCandidates(userX, userY),
          this.geometrySnapEnabled || this.vertexSnapEnabled ? this.vertexScreenToWorldThreshold() : 0, store.shapeId, skipIndex,
          this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0,
          this.geometrySnapEnabled ? this.geometrySnapKinds : this.vertexSnapEnabled ? ['顶点'] : []);
    let targetPt: Point = p;
    if (store.gestureKind === 1 && shape.type !== ShapeType.RECT && (store.orthoLock || isShiftHeld())) {
      targetPt = routingConstraintService.constrainVertexOrtho({ x: store.originVertexX, y: store.originVertexY }, p);
    }
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;
    if (store.gestureKind === 4 && shape.type === ShapeType.RECT) {
      const nextBox: Point[] = advEditService.withRectEdgeMoved(store.points, store.dragIndex, targetPt.x, targetPt.y);
      store.moveDrag(nextBox);
      const rw: number = Math.abs(nextBox[2].x - nextBox[0].x);
      const rh: number = Math.abs(nextBox[2].y - nextBox[0].y);
      draftCanvasEngine.cursorHud = {
        screenX: this.lastPointerScreenX,
        screenY: this.lastPointerScreenY,
        primaryText: `单边拉伸 宽 ${umText(rw)} × 高 ${umText(rh)} µm`,
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : '另一轴尺寸已锁定不变',
      };
    } else {
      const basis: Point[] = shape.type === ShapeType.RECT && store.gestureKind === 1 ? store.points : store.livePoints;
      const nextPts: Point[] = advEditService.withVertexMoved(shape, basis, store.dragIndex, targetPt.x, targetPt.y);
      store.moveDrag(nextPts);
      if (shape.type === ShapeType.RECT && nextPts.length === 4) {
        const rw: number = Math.abs(nextPts[2].x - nextPts[0].x);
        const rh: number = Math.abs(nextPts[2].y - nextPts[0].y);
        draftCanvasEngine.cursorHud = {
          screenX: this.lastPointerScreenX,
          screenY: this.lastPointerScreenY,
          primaryText: `宽 ${umText(rw)} × 高 ${umText(rh)} µm`,
          secondaryText: rich.readoutText,
        };
      }
    }
    this.updateTouchLoupe(this.lastPointerScreenX, this.lastPointerScreenY, targetPt, rich.readoutText);
    draftCanvasEngine.requestRepaint();
  }

  /** 松手：候选顶点经退化为/自交自检后才落库 ⇒ 至多产生一条撤销记录 */
  private onVertexUp(): boolean {
    const store: VertexStore = this.vertexStore;
    if (!store.isDragging()) {
      return false;
    }
    if (!this.editable) {
      store.revert();
      store.setHint('只读查看模式不能修改顶点');
      return true;
    }
    if (!this.vertexGestureCurrent()) {
      store.revert(); store.setHint('版图或选择已变化，顶点修改已取消'); return true;
    }
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === store.shapeId);
    if (shape === undefined || !this.isShapeInteractable(shape)) {
      store.revert();
      store.setHint('图形已不可编辑，顶点修改已取消');
      return true;
    }
    const kind: number = store.gestureKind;
    const candidate: Point[] = store.livePoints;
    const revisionBefore: number = editService.getSessionRevision();
    const res: VertexEditResult = advEditService.commitVertexEdit(store.shapeId, candidate);
    if (!res.ok) {
      store.revert();
      store.setHint(res.message);
      return true;
    }
    const movementCommitted: boolean = (kind === 1 || kind === 4) && editService.getSessionRevision() !== revisionBefore;
    store.settle(candidate);
    if (shape.type === ShapeType.RECT) {
      store.edgeHandles = advEditService.rectEdgeMidpoints(candidate);
    } else {
      store.edgeHandles = advEditService.edgeInsertPoints(shape, candidate);
    }
    store.setHint(kind === 3 ? '已删除顶点（一步撤销）'
      : kind === 2 ? '已在边上插入顶点（一步撤销）'
        : kind === 4 ? '已单边推拉调整矩形尺寸（一步撤销）'
          : '已移动顶点（一步撤销）');
    // 整个手势仅此一次几何落库 → 仅此一次重绘请求
    draftCanvasEngine.clearTransientPointerVisuals(true);
    this.requestRenderAction();
    if (movementCommitted) this.vertexMoveCommittedAction();
    return true;
  }

  private fixedRectDimensionsNm(): FixedRectDimensions {
    const rawW: number = Number(this.draftControlStore.rectFixedWNmStr);
    const rawH: number = Number(this.draftControlStore.rectFixedHNmStr);
    const fallback: number = Math.max(10, this.gridSize * 10);
    return {
      w: Number.isFinite(rawW) && rawW > 0 ? rawW : fallback,
      h: Number.isFinite(rawH) && rawH > 0 ? rawH : fallback,
    };
  }

  private previewFixedSizeRect(userX: number, userY: number, screenX: number, screenY: number, showLoupe: boolean): Point {
    const rich: RichSnapResult = this.snapRichWorld(userX, userY);
    const sp: Point = rich.point;
    const dims = this.fixedRectDimensionsNm();
    const rx: number = Math.round(sp.x - dims.w * 0.5);
    const ry: number = Math.round(sp.y - dims.h * 0.5);
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;
    draftCanvasEngine.rectPreview = {
      x: rx,
      y: ry,
      w: dims.w,
      h: dims.h,
      layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      centerAnchor: sp,
    };
    draftCanvasEngine.cursorHud = {
      screenX: screenX,
      screenY: screenY,
      primaryText: `定尺寸 ${umText(dims.w)} × ${umText(dims.h)} µm`,
      secondaryText: rich.readoutText.length > 0 ? `${rich.readoutText} · 松手点放` : `中心(${umText(sp.x)}, ${umText(sp.y)}) µm`,
    };
    if (showLoupe) {
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
    } else {
      draftCanvasEngine.loupe = null;
    }
    draftCanvasEngine.requestRepaint();
    return sp;
  }

  private onDown(userX: number, userY: number, screenX: number, screenY: number, tolerance: number): void {
    if (screenY < this.activeTopBarThreshold()) {
      return;
    }
    if (this.currentTool === ActiveTool.Pan) {
      this.isSingleFingerPanning = true;
      this.lastSinglePanX = screenX;
      this.lastSinglePanY = screenY;
      return;
    }
    if (!this.editable && this.currentTool !== ActiveTool.Select && this.currentTool !== ActiveTool.Measure &&
      this.currentTool !== ActiveTool.BoxZoom) {
      this.cursorStore.setReadout('只读查看模式不能修改图形');
      return;
    }
    if (!this.gestureContextCurrent()) return;
    this.gestureCellId = editService.getCurrentCellId();
    this.gestureContext = this.editGestureContext();
    this.gestureState = this.editGestureState();
    this.pendingClickShapeId = -1;
    if (this.draftControlStore.stampActive && this.editable) {
      this.hasPendingStampTouch = true;
      this.refreshLiveStampPreview(screenX, screenY, this.lastInputIsTouch);
      return;
    }
    if (this.draftControlStore.curveKind.length > 0 && this.editable) {
      if (!this.ensureActiveLayerReadyForDraw()) return;
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.curveCenterX = sp.x;
      this.curveCenterY = sp.y;
      this.hasCurveStart = true;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.curvePreview = {
        kind: this.draftControlStore.curveKind,
        center: sp,
        edge: sp,
        points: [],
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      };
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
      return;
    }
    if (this.currentTool === ActiveTool.BoxZoom) {
      this.isBoxSelecting = true;
      this.boxStartScreenX = screenX;
      this.boxStartScreenY = screenY;
      this.boxSelectRect = { x: screenX, y: screenY, w: 0, h: 0 };
      draftCanvasEngine.boxPreview = { x: screenX, y: screenY, w: 0, h: 0, leftToRight: true, isBoxZoom: true };
      draftCanvasEngine.requestRepaint();
    } else if (this.currentTool === ActiveTool.Rect) {
      if (!this.ensureActiveLayerReadyForDraw()) return;
      if (this.draftControlStore.rectDrawMode === 2) {
        this.hasDrawStart = true;
        this.previewFixedSizeRect(userX, userY, screenX, screenY, this.lastInputIsTouch);
        return;
      }
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.drawStartX = sp.x;
      this.drawStartY = sp.y;
      this.hasDrawStart = true;
      this.previewRect = { x: sp.x, y: sp.y, w: 0, h: 0 };
      this.isPreviewing = true;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.rectPreview = {
        x: sp.x, y: sp.y, w: 0, h: 0,
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
        centerAnchor: (this.draftControlStore.rectDrawMode === 1 || isAltHeld()) ? sp : undefined,
      };
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    } else if (this.currentTool === ActiveTool.Select) {
      if (this.onVertexDown(screenX, screenY)) {
        return;
      }
      const hits: HierarchyCandidatesResult = this.hitVisibleCandidates(userX, userY, tolerance);
      if (!hits.ok) {
        this.clearHitCandidates();
        this.cursorStore.setReadout(hits.message);
        return;
      }
      if (hits.candidates.length === 0) {
        this.clearHitCandidates();
      } else {
        this.hitCandidates = hits.candidates; this.hitCandidateIndex = 0; this.hitCandidatesMessage = hits.message;
        this.hitCandidateX = userX; this.hitCandidateY = userY; this.hitCandidateTolerance = tolerance;
        this.hitCandidateContext = `${this.documentKey}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`;
        this.onHitCandidates(hits, 0);
      }
      let hitId: number = hits.candidates.length > 0 ? hits.candidates[0].rootShapeId : -1;
      if (hitId >= 0) {
        const hitShapeCheck: Shape | undefined = this.shapes.find((s: Shape) => s.id === hitId);
        if (hitShapeCheck === undefined || !this.isShapeInteractable(hitShapeCheck)) {
          hitId = -1;
        }
      }
      if (hitId < 0 && this.lastShapeClickId >= 0 &&
        Date.now() - this.lastShapeClickAt <= DOUBLE_CLICK_THRESHOLD &&
        Math.hypot(screenX - this.lastShapeClickScreenX, screenY - this.lastShapeClickScreenY) <= this.activeDragSlopVp()) {
        const recentInst: Shape | undefined = this.shapes.find((s: Shape) =>
          s.id === this.lastShapeClickId && s.type === ShapeType.INSTANCE);
        if (recentInst !== undefined && this.isShapeInteractable(recentInst)) {
          hitId = recentInst.id;
        }
      }
      this.pendingClickShapeId = hitId;
      const hitShape: Shape | undefined = this.shapes.find((shape: Shape) => shape.id === hitId);
      if (this.editable && hitShape !== undefined && editService.canEditLayer(hitShape.layerNumber, hitShape.datatype) &&
        editService.getSelectedIds().indexOf(hitId) >= 0) {
        const rich: RichSnapResult = this.snapRichWorld(userX, userY);
        const sp: Point = rich.point;
        this.isDragging = true;
        this.dragThresholdExceeded = false;
        this.dragStartScreenX = screenX;
        this.dragStartScreenY = screenY;
        this.moveFromX = sp.x;
        this.moveFromY = sp.y;
        this.dragOffsetX = 0;
        this.dragOffsetY = 0;
        this.moveGhostOutlines = this.captureMoveGhostOutlines();
      } else if (hitId >= 0) {
        // Selection is committed on release, also for GL-only shapes without a node.
      } else {
        this.isBoxSelecting = true;
        this.boxSelectLeftToRight = true;
        this.boxStartScreenX = screenX;
        this.boxStartScreenY = screenY;
        this.boxSelectRect = { x: screenX, y: screenY, w: 0, h: 0 };
        draftCanvasEngine.boxPreview = { x: screenX, y: screenY, w: 0, h: 0, leftToRight: true, isBoxZoom: false };
        draftCanvasEngine.requestRepaint();
      }
    } else if (this.currentTool === ActiveTool.Move) {
      // Phase 8: 若未选中图形，或单选状态下直接按在另一可编辑图形上，自动切换拾取并立即拖拽！
      if (this.selectedShapeId < 0 || editService.getSelectedIds().length <= 1) {
        const hit: HierarchyHitResult = this.hitVisibleShape(userX, userY, tolerance);
        if (hit.ok && hit.shapeId >= 0) {
          const hitShape: Shape | undefined = this.shapes.find((s: Shape): boolean => s.id === hit.shapeId);
          if (hitShape !== undefined && this.isShapeInteractable(hitShape) &&
            editService.canEditLayer(hitShape.layerNumber, hitShape.datatype)) {
            this.selectShapeAction(hitShape);
            this.gestureContext = this.editGestureContext();
            this.gestureState = this.editGestureState();
          }
        }
      }
      if (editService.getSelectedIds().length === 0 && this.selectedShapeId < 0) {
        this.cursorStore.setReadout('请直接按住要移动的版图图形拖拽，或先框选多个图形');
        return;
      }
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.moveFromX = sp.x;
      this.moveFromY = sp.y;
      this.moveStartTime = Date.now();
      this.isDragging = true;
      this.dragThresholdExceeded = false;
      this.dragStartScreenX = screenX;
      this.dragStartScreenY = screenY;
      this.dragOffsetX = 0;
      this.dragOffsetY = 0;
      this.moveGhostOutlines = this.captureMoveGhostOutlines();
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    } else if (this.currentTool === ActiveTool.Polygon && this.draftControlStore.polygonSubMode === 1 && !this.isDrawingPoly) {
      if (!this.ensureActiveLayerReadyForDraw()) return;
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.curveCenterX = sp.x;
      this.curveCenterY = sp.y;
      this.hasRegularPolyStart = true;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.curvePreview = {
        kind: `NGON_${this.draftControlStore.regularPolygonSides}`,
        center: sp,
        edge: sp,
        points: [],
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      };
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
      return;
    } else if (this.currentTool === ActiveTool.Polygon || this.currentTool === ActiveTool.Path) {
      if (!this.ensureActiveLayerReadyForDraw()) return;
      if (!this.isDrawingPoly) {
        this.polyDrawContext = this.editGestureContext();
        this.polyDrawState = this.editGestureState();
        this.isDrawingPoly = true;
        this.draftControlStore.routingMode = this.routingMode;
        this.draftControlStore.pathWidthStr = this.pathWidthStr;
      }
      this.hasPendingPolyTouch = true;
      this.updatePolyLivePreview(userX, userY, screenX, screenY, this.lastInputIsTouch);
      this.draftControlStore.syncPolyState(
        true,
        this.currentTool === ActiveTool.Path,
        this.polygonPoints.length,
        this.polyCloseLoopReady
      );
    } else if (this.currentTool === ActiveTool.Measure) {
      this.onMeasureDown(userX, userY, screenX, screenY);
    } else if (this.currentTool === ActiveTool.Text) {
      if (!this.ensureActiveLayerReadyForDraw()) return;
      // Phase 6: 文本工具支持按下磁吸瞄准（开启放大镜与十字对齐线），松手确认落点后再弹输入框
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.textInsertX = sp.x;
      this.textInsertY = sp.y;
      this.hasPendingTextTouch = true;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `文本落点 ${umText(sp.x)}, ${umText(sp.y)} µm`,
        secondaryText: rich.readoutText.length > 0 ? `${rich.readoutText} · 松手输入文本` : '拖动微调瞄准，松手输入文本',
      };
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    }
  }

  /**
   * 测量/标尺按下（KLayout 语义）：
   * - 测量：未开始或已完成 ⇒ 本次落点开启下一次测量；已落起点 ⇒ 锁定终点。
   *   （旧实现第三次点击只会覆写终点，起点永久卡死，无法连续测量）
   * - 标尺：记录锚点并开始拖拽定向，松手时落成水平/竖直参考线
   */
  /**
   * Phase 6 测量与标尺双模手势：
   * 1. 支持「按住起点直接拖到终点松手锁定（Drag-to-Measure）」与「单击起点 → 移动瞄准 → 单击终点锁定（Click-Click）」无缝兼容；
   * 2. 触屏按下即弹指尖放大镜与几何磁吸靶标，可滑动微调对准金属边/顶点；
   * 3. 标尺拖拽实时跟随最新磁吸点（liveX / liveY），消除旧实现坐标钉死在按下点的顽疾。
   */
  private onMeasureDown(userX: number, userY: number, screenX: number, screenY: number): void {
    if (screenY > this.canvasHeight - BOTTOM_STRIP_HEIGHT) {
      return;
    }
    const s: MeasureStore = this.measureStore;
    const extra: Point[] = (!s.rulerMode && s.pending) ? [{ x: s.x1, y: s.y1 }] : [];
    const rich: RichSnapResult = this.snapRichWorld(userX, userY, extra);
    let sp: Point = rich.point;
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;

    this.measureDownScreenX = screenX;
    this.measureDownScreenY = screenY;
    this.hasMeasureTouchActive = true;

    if (s.rulerMode) {
      s.begin(sp.x, sp.y);
      this.hasRulerDown = true;
      this.rulerDownScreenX = screenX;
      this.rulerDownScreenY = screenY;
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
      this.syncReadout();
      return;
    }

    if (s.pending) {
      this.measureWasWaitingSecondPoint = true;
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      if (!s.isAreaMode()) {
        sp = routingConstraintService.constrainMeasureEnd({ x: s.x1, y: s.y1 }, sp, s.angleLock, isShiftHeld(), step);
        draftCanvasEngine.measureTriangle = { x1: s.x1, y1: s.y1, x2: sp.x, y2: sp.y };
      } else {
        if (isShiftHeld()) {
          sp = routingConstraintService.constrainRectEnd({ x: s.x1, y: s.y1 }, sp, true, step);
        }
        draftCanvasEngine.measureTriangle = null;
      }
      s.moveLive(sp.x, sp.y);
    } else {
      this.measureWasWaitingSecondPoint = false;
      s.begin(sp.x, sp.y);
      draftCanvasEngine.measureTriangle = null;
    }
    this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
    draftCanvasEngine.requestRepaint();
    this.syncReadout();
  }

  private onMeasureMove(userX: number, userY: number, screenX: number, screenY: number): void {
    const s: MeasureStore = this.measureStore;
    if (!s.pending) {
      return;
    }
    const extra: Point[] = !s.rulerMode ? [{ x: s.x1, y: s.y1 }] : [];
    const rich: RichSnapResult = this.snapRichWorld(userX, userY, extra);
    let sp: Point = rich.point;
    draftCanvasEngine.snapMarker = rich.marker;
    draftCanvasEngine.alignmentGuides = rich.guides;

    if (s.isAreaMode()) {
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      if (isShiftHeld()) {
        sp = routingConstraintService.constrainRectEnd({ x: s.x1, y: s.y1 }, sp, true, step);
      }
      s.moveLive(sp.x, sp.y);
      draftCanvasEngine.measureTriangle = null;
      const wNm: number = Math.abs(sp.x - s.x1);
      const hNm: number = Math.abs(sp.y - s.y1);
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `面积 ${s.formatArea(wNm * hNm)}`,
        secondaryText: `宽 ${s.formatLength(wNm)} × 高 ${s.formatLength(hNm)} · 周长 ${s.formatLength(2 * (wNm + hNm))}`,
      };
    } else if (!s.rulerMode) {
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      sp = routingConstraintService.constrainMeasureEnd({ x: s.x1, y: s.y1 }, sp, s.angleLock, isShiftHeld(), step);
      s.moveLive(sp.x, sp.y);
      draftCanvasEngine.measureTriangle = { x1: s.x1, y1: s.y1, x2: sp.x, y2: sp.y };
      const dx: number = sp.x - s.x1;
      const dy: number = sp.y - s.y1;
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `距离 ${s.formatLength(Math.hypot(dx, dy))}`,
        secondaryText: `Δx ${s.formatLength(dx)}  Δy ${s.formatLength(dy)}` + (rich.readoutText.length > 0 ? ` · ${rich.readoutText}` : ''),
      };
    } else {
      s.moveLive(sp.x, sp.y);
      const isCross: boolean = s.rulerOrientation === 'crosshair';
      const vertical: boolean = this.resolveRulerVertical(screenX, screenY);
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: isCross
          ? `十字标尺 (${s.formatLength(sp.x)}, ${s.formatLength(sp.y)})`
          : (vertical ? `竖直标尺 X = ${s.formatLength(sp.x)}` : `水平标尺 Y = ${s.formatLength(sp.y)}`),
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : '拖动吸边，松手落标尺',
      };
    }
    if (this.lastInputIsTouch) {
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
    }
    draftCanvasEngine.requestRepaint();
    this.syncReadout();
  }

  private resolveRulerVertical(screenX: number, screenY: number): boolean {
    const s: MeasureStore = this.measureStore;
    if (s.rulerOrientation === 'vertical') return true;
    if (s.rulerOrientation === 'horizontal') return false;
    const ddx: number = screenX - this.rulerDownScreenX;
    const ddy: number = screenY - this.rulerDownScreenY;
    return Math.abs(ddy) >= RULER_DRAG_MIN_PX && Math.abs(ddy) > Math.abs(ddx);
  }

  private onRulerUp(screenX: number, screenY: number): void {
    const s: MeasureStore = this.measureStore;
    this.hasRulerDown = false;
    this.hasMeasureTouchActive = false;
    if (s.rulerOrientation === 'crosshair') {
      s.addCrosshairRuler(s.liveX, s.liveY);
    } else {
      const vertical: boolean = this.resolveRulerVertical(screenX, screenY);
      s.addRuler(vertical, vertical ? s.liveX : s.liveY);
    }
    s.reset();
    draftCanvasEngine.clearTransientPointerVisuals(true);
    this.syncReadout();
  }

  private onMove(userX: number, userY: number, screenX: number, screenY: number): void {
    if (this.isSingleFingerPanning && this.currentTool === ActiveTool.Pan) {
      const dx: number = screenX - this.lastSinglePanX;
      const dy: number = screenY - this.lastSinglePanY;
      this.lastSinglePanX = screenX;
      this.lastSinglePanY = screenY;
      if (dx !== 0 || dy !== 0) {
        this.panCanvasAction(dx, dy);
      }
      return;
    }
    if (!this.gestureContextCurrent(false)) return;
    if (this.draftControlStore.stampActive && this.hasPendingStampTouch) {
      this.refreshLiveStampPreview(screenX, screenY, this.lastInputIsTouch);
      return;
    }
    if (this.vertexStore.isDragging()) {
      this.onVertexMove(userX, userY);
      return;
    }
    if (this.isDrawingPoly && (this.currentTool === ActiveTool.Polygon || this.currentTool === ActiveTool.Path)) {
      this.updatePolyLivePreview(userX, userY, screenX, screenY, this.lastInputIsTouch);
      this.draftControlStore.syncPolyState(
        true,
        this.currentTool === ActiveTool.Path,
        this.polygonPoints.length,
        this.polyCloseLoopReady
      );
      return;
    }
    if (this.currentTool === ActiveTool.Polygon && this.draftControlStore.polygonSubMode === 1 && this.hasRegularPolyStart) {
      const center: Point = { x: this.curveCenterX, y: this.curveCenterY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [center]);
      const edgePt: Point = rich.point;
      const sides: number = this.draftControlStore.regularPolygonSides;
      const pts: Point[] = routingConstraintService.buildRegularPolygon(center, edgePt, sides, isShiftHeld());
      const rNm: number = Math.hypot(edgePt.x - center.x, edgePt.y - center.y);
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.curvePreview = {
        kind: `NGON_${sides}`,
        center: center,
        edge: edgePt,
        points: pts,
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      };
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `正${sides}边形 · 外接R ${umText(rNm)} µm`,
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : `心(${umText(center.x)}, ${umText(center.y)}) µm · Shift锁15°`,
      };
      this.cursorStore.setReadout(`正${sides}边形 R=${umText(rNm)} µm`);
      this.updateTouchLoupe(screenX, screenY, edgePt, rich.readoutText);
      draftCanvasEngine.requestRepaint();
      return;
    }
    if (this.draftControlStore.curveKind.length > 0 && this.hasCurveStart) {
      const center: Point = { x: this.curveCenterX, y: this.curveCenterY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [center]);
      const edgePt: Point = rich.point;
      const kind: string = this.draftControlStore.curveKind;
      const fixedRingW: number = this.draftControlStore.curveUseFixedWidth
        ? Math.max(0, Number(this.draftControlStore.curveRingWidthNmStr) || 0)
        : 0;
      const pts: Point[] = routingConstraintService.buildInteractiveCurvePolygon(
        kind,
        center,
        edgePt,
        64,
        this.draftControlStore.curveInnerRatioPct,
        this.draftControlStore.curveArcSweepDeg,
        this.draftControlStore.curveArcClockwise,
        fixedRingW
      );
      const rNm: number = Math.hypot(edgePt.x - center.x, edgePt.y - center.y);
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.curvePreview = {
        kind: kind,
        center: center,
        edge: edgePt,
        points: pts,
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
      };
      let primary: string = `半径 R ${umText(rNm)} µm · 直径 ${umText(rNm * 2)} µm`;
      if (kind === 'ELLIPSE') {
        primary = `椭圆 Rx ${umText(Math.abs(edgePt.x - center.x))} × Ry ${umText(Math.abs(edgePt.y - center.y))} µm`;
      } else if (kind === 'DONUT') {
        primary = `外径 R ${umText(rNm)} · 内径 r ${umText(rNm * this.draftControlStore.curveInnerRatioPct / 100)} µm`;
      } else if (kind === 'ARC') {
        primary = `圆弧 R ${umText(rNm)} µm · 跨度 ${this.draftControlStore.curveArcSweepDeg}°`;
      }
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: primary,
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : `心(${umText(center.x)}, ${umText(center.y)}) µm`,
      };
      this.cursorStore.setReadout(`${routingConstraintService.curveKindLabel(kind)} ${primary}`);
      this.updateTouchLoupe(screenX, screenY, edgePt, rich.readoutText);
      draftCanvasEngine.requestRepaint();
      return;
    }
    if (this.currentTool === ActiveTool.Rect && this.hasDrawStart) {
      if (this.draftControlStore.rectDrawMode === 2) {
        this.previewFixedSizeRect(userX, userY, screenX, screenY, this.lastInputIsTouch);
        return;
      }
      const startPt: Point = { x: this.drawStartX, y: this.drawStartY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [startPt]);
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      const lockSq: boolean = isShiftHeld() || this.draftControlStore.rectSquareLock;
      const sp: Point = routingConstraintService.constrainRectEnd(startPt, rich.point, lockSq, step);
      const centerMode: boolean = this.draftControlStore.rectDrawMode === 1 || isAltHeld();
      const halfW: number = Math.abs(sp.x - this.drawStartX);
      const halfH: number = Math.abs(sp.y - this.drawStartY);
      const x: number = centerMode ? this.drawStartX - halfW : Math.min(this.drawStartX, sp.x);
      const y: number = centerMode ? this.drawStartY - halfH : Math.min(this.drawStartY, sp.y);
      const w: number = centerMode ? halfW * 2 : halfW;
      const h: number = centerMode ? halfH * 2 : halfH;
      this.previewRect = { x: x, y: y, w: w, h: h };
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.rectPreview = {
        x: x, y: y, w: w, h: h,
        layerColor: this.colorForLayer(this.selectedLayerNumber, this.selectedDatatype),
        centerAnchor: centerMode ? startPt : undefined,
      };
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `${centerMode ? '中心矩 ' : ''}宽 ${umText(w)} × 高 ${umText(h)} µm`,
        secondaryText: rich.readoutText.length > 0 ? rich.readoutText : (lockSq ? '正方形等边锁定' : `锚(${umText(this.drawStartX)}, ${umText(this.drawStartY)})`),
      };
      this.cursorStore.setReadout(`矩形 宽${umText(w)} × 高${umText(h)} µm`);
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    } else if ((this.currentTool === ActiveTool.Select || this.currentTool === ActiveTool.Move) && this.isDragging) {
      if (!this.dragThresholdExceeded) {
        if (Math.hypot(screenX - this.dragStartScreenX, screenY - this.dragStartScreenY) <= this.activeDragSlopVp()) {
          return;
        }
        this.dragThresholdExceeded = true;
      }
      const origin: Point = { x: this.moveFromX, y: this.moveFromY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [origin]);
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      const target: Point = this.currentTool === ActiveTool.Move
        ? routingConstraintService.constrainMoveTarget(origin, rich.point, this.routingMode, isShiftHeld(), step, rich.snappedGeometry)
        : rich.point;
      const dxNm: number = target.x - this.moveFromX;
      const dyNm: number = target.y - this.moveFromY;
      this.dragOffsetX = dxNm * this.zoomPercent / 100;
      this.dragOffsetY = -dyNm * this.zoomPercent / 100;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.movePreview = {
        fromX: this.moveFromX,
        fromY: this.moveFromY,
        dxNm: dxNm,
        dyNm: dyNm,
        outlines: this.moveGhostOutlines,
      };
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `Δx ${umText(dxNm)}  Δy ${umText(dyNm)} µm`,
        secondaryText: `距离 ${umText(Math.hypot(dxNm, dyNm))} µm` + (rich.readoutText.length > 0 ? ` · ${rich.readoutText}` : ''),
      };
      this.cursorStore.setReadout(`移动 Δx=${umText(dxNm)} Δy=${umText(dyNm)} µm`);
      this.updateTouchLoupe(screenX, screenY, target, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    } else if ((this.currentTool === ActiveTool.Select || this.currentTool === ActiveTool.BoxZoom) && this.isBoxSelecting) {
      const minX: number = Math.min(screenX, this.boxStartScreenX);
      const minY: number = Math.min(screenY, this.boxStartScreenY);
      const w: number = Math.abs(screenX - this.boxStartScreenX);
      const h: number = Math.abs(screenY - this.boxStartScreenY);
      const rule: number = this.draftControlStore.boxSelectRule;
      this.boxSelectLeftToRight = rule === 1 ? false : (rule === 2 ? true : screenX >= this.boxStartScreenX);
      this.boxSelectRect = { x: minX, y: minY, w: w, h: h };
      draftCanvasEngine.boxPreview = {
        x: minX, y: minY, w: w, h: h,
        leftToRight: this.boxSelectLeftToRight,
        isBoxZoom: this.currentTool === ActiveTool.BoxZoom,
      };
      const wx: number = Math.abs(this.screenToWorldX(screenX) - this.screenToWorldX(this.boxStartScreenX));
      const wy: number = Math.abs(this.screenToWorldY(screenY) - this.screenToWorldY(this.boxStartScreenY));
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `${umText(wx)} × ${umText(wy)} µm`,
        secondaryText: this.currentTool === ActiveTool.BoxZoom ? '框选局部放大' : (this.boxSelectLeftToRight ? '完全包含选中' : '相交即选中'),
      };
      draftCanvasEngine.requestRepaint();
    } else if (this.currentTool === ActiveTool.Measure) {
      this.onMeasureMove(userX, userY, screenX, screenY);
    } else if (this.currentTool === ActiveTool.Text && this.hasPendingTextTouch) {
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      const sp: Point = rich.point;
      this.textInsertX = sp.x;
      this.textInsertY = sp.y;
      draftCanvasEngine.snapMarker = rich.marker;
      draftCanvasEngine.alignmentGuides = rich.guides;
      draftCanvasEngine.cursorHud = {
        screenX: screenX,
        screenY: screenY,
        primaryText: `文本落点 ${umText(sp.x)}, ${umText(sp.y)} µm`,
        secondaryText: rich.readoutText.length > 0 ? `${rich.readoutText} · 松手输入文本` : '松手打开文本输入框',
      };
      this.updateTouchLoupe(screenX, screenY, sp, rich.readoutText);
      draftCanvasEngine.requestRepaint();
    }
  }

  private onUp(userX: number, userY: number, screenX: number, screenY: number): void {
    if (this.isSingleFingerPanning) {
      this.isSingleFingerPanning = false;
      return;
    }
    if (!this.gestureContextCurrent()) return;
    this.gestureContext = '';
    if (this.draftControlStore.stampActive && this.hasPendingStampTouch) {
      this.hasPendingStampTouch = false;
      if (this.lastInputIsTouch && screenY < 44) {
        draftCanvasEngine.loupe = null;
        draftCanvasEngine.cursorHud = null;
        draftCanvasEngine.requestRepaint();
        this.cursorStore.setReadout('已取消本次点放');
        return;
      }
      const pt: Point = this.refreshLiveStampPreview(screenX, screenY, false);
      draftCanvasEngine.loupe = null;
      draftCanvasEngine.cursorHud = null;
      const placed: boolean = this.commitStampAtAction(pt.x, pt.y);
      if (placed && !this.draftControlStore.stampContinuous) {
        this.exitStampModeAction();
      } else {
        draftCanvasEngine.requestRepaint();
      }
      return;
    }
    if (this.currentTool === ActiveTool.BoxZoom && this.isBoxSelecting) {
      this.onMove(userX, userY, screenX, screenY);
      const box: BoxSelectRect = this.boxSelectRect;
      this.isBoxSelecting = false;
      this.boxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (box.w > 3 && box.h > 3) {
        if (this.boxZoomAction !== null) {
          this.boxZoomAction(box.x, box.y, box.w, box.h);
        } else {
          const centerX: number = box.x + box.w / 2;
          const centerY: number = box.y + box.h / 2;
          const factor: number = Math.min(this.canvasWidth / box.w, this.canvasHeight / box.h) * 0.9;
          this.zoomAtAction(centerX, centerY, factor);
          this.panCanvasAction(this.canvasWidth / 2 - centerX, this.canvasHeight / 2 - centerY);
        }
      }
      this.onBoxZoomDone();
      return;
    }
    if (this.vertexStore.isDragging()) this.onVertexMove(userX, userY);
    if (this.onVertexUp()) {
      return;
    }
    if (this.currentTool === ActiveTool.Polygon && this.draftControlStore.polygonSubMode === 1 && this.hasRegularPolyStart) {
      this.onMove(userX, userY, screenX, screenY);
      const pts: Point[] = draftCanvasEngine.curvePreview !== null ? draftCanvasEngine.curvePreview.points : [];
      this.hasRegularPolyStart = false;
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (pts.length >= 3) {
        if (!this.createPolygonAction(pts)) {
          this.cursorStore.setReadout('正多边形未创建，请检查当前图层是否锁定');
        }
      }
      return;
    }
    if (this.draftControlStore.curveKind.length > 0 && this.hasCurveStart) {
      this.onMove(userX, userY, screenX, screenY);
      const pts: Point[] = draftCanvasEngine.curvePreview !== null ? draftCanvasEngine.curvePreview.points : [];
      this.hasCurveStart = false;
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (pts.length >= 3) {
        if (!this.createPolygonAction(pts)) {
          this.cursorStore.setReadout('曲线图形未创建，请查看状态栏原因');
        }
      }
      return;
    }
    if (this.currentTool === ActiveTool.Text && this.hasPendingTextTouch) {
      const rich: RichSnapResult = this.snapRichWorld(userX, userY);
      this.textInsertX = rich.point.x;
      this.textInsertY = rich.point.y;
      this.hasPendingTextTouch = false;
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (this.draftControlStore.textQuickPreset.length > 0) {
        const quickPin: string = this.draftControlStore.consumeQuickTextLabel();
        if (quickPin.length > 0) {
          this.createTextAction(this.textInsertX, this.textInsertY, quickPin);
        }
        return;
      }
      this.textInsertContext = this.textCreateContext();
      this.textCreateController.open();
      return;
    }
    if (this.currentTool === ActiveTool.Measure) {
      if (this.hasRulerDown) {
        this.onMeasureMove(userX, userY, screenX, screenY);
        this.onRulerUp(screenX, screenY);
        return;
      }
      if (this.hasMeasureTouchActive && this.measureStore.pending) {
        this.onMeasureMove(userX, userY, screenX, screenY);
        const dragDistPx: number = Math.hypot(screenX - this.measureDownScreenX, screenY - this.measureDownScreenY);
        this.hasMeasureTouchActive = false;
        if (this.measureWasWaitingSecondPoint || dragDistPx > 8) {
          // 拖拽一步量距（Drag-to-Measure）或双点第二击松手：立即锁定一条持久测量标注！
          this.measureStore.commit(this.measureStore.liveX, this.measureStore.liveY);
          this.measureWasWaitingSecondPoint = false;
          draftCanvasEngine.clearTransientPointerVisuals(true);
          this.syncReadout();
        } else {
          // 轻点第一下：锁定起点，保留活动橡皮筋等待第二点（支持中途双指缩放平移看远端终点！）
          draftCanvasEngine.loupe = null;
          draftCanvasEngine.requestRepaint();
          this.syncReadout();
        }
      }
      return;
    }
    if ((this.currentTool === ActiveTool.Polygon || this.currentTool === ActiveTool.Path) && this.hasPendingPolyTouch) {
      this.hasPendingPolyTouch = false;
      // 触屏防误触：手指若上滑至顶部工具区 (<44vp) 松手，仅取消本次瞄准而不强行种下碎点
      if (this.lastInputIsTouch && screenY < 44) {
        this.polyLiveTail = [];
        draftCanvasEngine.loupe = null;
        draftCanvasEngine.cursorHud = null;
        this.syncPolyDraftCanvas();
        this.cursorStore.setReadout('已放弃本次落点，可继续瞄准下一点');
        return;
      }
      const computed = this.updatePolyLivePreview(userX, userY, screenX, screenY, false);
      const tail: Point[] = computed.routed.previewTail;

      // 多边形命中首点闭合环：先补齐 L 型拐点（若有），随后一键自动闭合提交
      if (this.currentTool === ActiveTool.Polygon && this.polygonPoints.length >= 3 && computed.rich.closeLoopHit) {
        if (tail.length === 2) {
          const elbow: Point = tail[0];
          const prev: Point = this.polygonPoints[this.polygonPoints.length - 1];
          if (Math.hypot(elbow.x - prev.x, elbow.y - prev.y) > 1e-6 &&
            Math.hypot(elbow.x - this.polygonPoints[0].x, elbow.y - this.polygonPoints[0].y) > 1e-6) {
            this.polygonPoints = [...this.polygonPoints, elbow];
          }
        }
        this.finishPolyDraw();
        return;
      }

      const nowTap: number = Date.now();
      if (this.canFinishPolyDraw() &&
        this.lastPolyVertexTapAt > 0 &&
        nowTap - this.lastPolyVertexTapAt <= DOUBLE_CLICK_THRESHOLD &&
        Math.hypot(screenX - this.lastPolyVertexScreenX, screenY - this.lastPolyVertexScreenY) <= this.activePolyDoubleClickSlopVp()) {
        this.polyLiveTail = [];
        this.polyCloseLoopReady = false;
        draftCanvasEngine.loupe = null;
        draftCanvasEngine.cursorHud = null;
        this.lastPolyVertexTapAt = 0;
        this.lastPolyTapAddedCount = 0;
        this.finishPolyDraw();
        return;
      }
      const updated: Point[] = this.copyPoints(this.polygonPoints);
      for (let i = 0; i < tail.length; i++) {
        const candidate: Point = tail[i];
        if (updated.length === 0) {
          updated.push({ x: candidate.x, y: candidate.y });
        } else {
          const last: Point = updated[updated.length - 1];
          if (Math.hypot(candidate.x - last.x, candidate.y - last.y) > 1e-6) {
            updated.push({ x: candidate.x, y: candidate.y });
          }
        }
      }
      const addedCount: number = updated.length - this.polygonPoints.length;
      this.polygonPoints = updated;
      if (addedCount > 0) {
        this.lastPolyVertexTapAt = nowTap;
        this.lastPolyVertexScreenX = screenX;
        this.lastPolyVertexScreenY = screenY;
        this.lastPolyTapAddedCount = addedCount;
      }
      this.polyLiveTail = [];
      this.polyCloseLoopReady = false;
      draftCanvasEngine.loupe = null;
      draftCanvasEngine.cursorHud = null;
      this.draftControlStore.syncPolyState(
        true,
        this.currentTool === ActiveTool.Path,
        this.polygonPoints.length,
        false
      );
      this.syncPolyDraftCanvas();
      return;
    }
    if (this.currentTool === ActiveTool.Rect && this.hasDrawStart) {
      if (this.draftControlStore.rectDrawMode === 2) {
        const centerPt: Point = this.previewFixedSizeRect(userX, userY, screenX, screenY, false);
        const dims = this.fixedRectDimensionsNm();
        const p1: Point = { x: Math.round(centerPt.x - dims.w * 0.5), y: Math.round(centerPt.y - dims.h * 0.5) };
        const p2: Point = { x: p1.x + dims.w, y: p1.y + dims.h };
        this.hasDrawStart = false;
        this.isPreviewing = false;
        draftCanvasEngine.clearTransientPointerVisuals(true);
        if (!this.createShapeAction(p1, p2)) {
          this.cursorStore.setReadout('定尺寸矩形未创建，请查看状态栏原因');
        }
        return;
      }
      const start: Point = { x: this.drawStartX, y: this.drawStartY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [start]);
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      const lockSq: boolean = isShiftHeld() || this.draftControlStore.rectSquareLock;
      const end: Point = routingConstraintService.constrainRectEnd(start, rich.point, lockSq, step);
      const centerMode: boolean = this.draftControlStore.rectDrawMode === 1 || isAltHeld();
      const halfW: number = Math.abs(end.x - start.x);
      const halfH: number = Math.abs(end.y - start.y);
      const commitStart: Point = centerMode ? { x: start.x - halfW, y: start.y - halfH } : start;
      const commitEnd: Point = centerMode ? { x: start.x + halfW, y: start.y + halfH } : end;
      if (Math.abs(commitEnd.x - commitStart.x) > 0 && Math.abs(commitEnd.y - commitStart.y) > 0) {
        if (!this.createShapeAction(commitStart, commitEnd)) this.cursorStore.setReadout('矩形未创建，请查看状态栏原因');
      }
      this.hasDrawStart = false;
      this.isPreviewing = false;
      this.previewRect = { x: 0, y: 0, w: 0, h: 0 };
      draftCanvasEngine.clearTransientPointerVisuals(true);
    } else if (this.currentTool === ActiveTool.Select && this.isDragging) {
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [{ x: this.moveFromX, y: this.moveFromY }]);
      const target: Point = rich.point;
      const dx: number = target.x - this.moveFromX;
      const dy: number = target.y - this.moveFromY;
      const dragged: boolean = this.dragThresholdExceeded ||
        Math.hypot(screenX - this.dragStartScreenX, screenY - this.dragStartScreenY) > this.activeDragSlopVp();
      this.isDragging = false;
      this.dragThresholdExceeded = false;
      this.dragOffsetX = 0;
      this.dragOffsetY = 0;
      this.moveGhostOutlines = [];
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (dragged && (dx !== 0 || dy !== 0)) {
        this.applyMove(dx, dy);
      }
      if (!dragged) this.commitPendingShapeClick();
      else this.pendingClickShapeId = -1;
    } else if (this.currentTool === ActiveTool.Select && this.isBoxSelecting) {
      this.onMove(userX, userY, screenX, screenY);
      this.finishBoxSelect();
      draftCanvasEngine.clearTransientPointerVisuals(true);
    } else if (this.currentTool === ActiveTool.Select && this.pendingClickShapeId >= 0) {
      this.commitPendingShapeClick();
    } else if (this.currentTool === ActiveTool.Move && this.isDragging) {
      const origin: Point = { x: this.moveFromX, y: this.moveFromY };
      const rich: RichSnapResult = this.snapRichWorld(userX, userY, [origin]);
      const step: number = this.snapEnabled ? (this.drawStepNm >= 0 ? this.drawStepNm : this.gridSize) : 0;
      const sp: Point = routingConstraintService.constrainMoveTarget(
        origin, rich.point, this.routingMode, isShiftHeld(), step, rich.snappedGeometry
      );
      const dx: number = sp.x - this.moveFromX;
      const dy: number = sp.y - this.moveFromY;
      const duration: number = Date.now() - this.moveStartTime;
      const movedOnScreen: boolean = this.dragThresholdExceeded ||
        Math.hypot(screenX - this.dragStartScreenX, screenY - this.dragStartScreenY) > this.activeDragSlopVp();
      this.isDragging = false;
      this.dragThresholdExceeded = false;
      this.dragOffsetX = 0;
      this.dragOffsetY = 0;
      this.moveGhostOutlines = [];
      draftCanvasEngine.clearTransientPointerVisuals(true);
      if (duration > LONG_PRESS_THRESHOLD && !movedOnScreen) {
        this.pendingMoveIds = this.collectMoveIds();
        this.pendingMoveContext = this.editGestureContext();
        this.dialogDxStr = dx.toFixed(1);
        this.dialogDyStr = dy.toFixed(1);
        this.moveFineTuneController.open();
      } else if (movedOnScreen && (dx !== 0 || dy !== 0)) {
        this.applyMove(dx, dy);
      }
    }
  }

  /**
   * CANVAS-8/9/14: 收集当前需移动的唯一图形 ID 集合。
   * 以 editService.getSelectedIds() 为权威来源（消除 multiSelectIds 与 editService 不同步），
   * 兜底使用 selectedShapeId，确保单选场景仍可移动。
   */
  private collectMoveIds(): number[] {
    const ids: number[] = editService.getSelectedIds();
    if (ids.length > 0) {
      return ids;
    }
    if (this.selectedShapeId >= 0) {
      return [this.selectedShapeId];
    }
    return [];
  }

  /**
   * CANVAS-8/9: 对 collectMoveIds() 返回的全部选中图形施加位移。
   * 多选时用 beginBatch/endBatch 包裹，合并为单个撤销组。
   */
  private applyMove(dx: number, dy: number): void {
    const moveIds: number[] = this.collectMoveIds();
    if (moveIds.length === 0) {
      return;
    }
    // A read-only member in a mixed selection rejects the complete gesture.
    for (const id of moveIds) {
      const shape: Shape | undefined = editService.getShapes().find((item: Shape) => item.id === id);
      if (shape === undefined || !editService.canEditLayer(shape.layerNumber, shape.datatype) ||
        shape.points.some((p: Point) => !Number.isFinite(p.x + dx) || !Number.isFinite(p.y + dy))) {
        this.cursorStore.setReadout('选区含锁定或无效对象，未移动任何图形'); return;
      }
    }
    if (moveIds.length > 1) {
      editService.beginBatch();
    }
    for (let i = 0; i < moveIds.length; i++) {
      this.moveShapeAction(moveIds[i], dx, dy);
    }
    if (moveIds.length > 1) {
      editService.endBatch();
    }
  }

  /** 框选释放：计算与选择框相交的所有图形，调 editService.selectMultiple */
  private finishBoxSelect(): void {
    const box: BoxSelectRect = this.boxSelectRect;
    // 选择框屏幕坐标 → 用户坐标
    const x1: number = this.screenToWorldX(box.x);
    const x2: number = this.screenToWorldX(box.x + box.w);
    const y1: number = this.screenToWorldY(box.y);
    const y2: number = this.screenToWorldY(box.y + box.h);
    const minX: number = Math.min(x1, x2);
    const maxX: number = Math.max(x1, x2);
    const minY: number = Math.min(y1, y2);
    const maxY: number = Math.max(y1, y2);

    // 框选方向语义（KLayout）：
    // 左→右（w>0）= 仅选完全包含在框内的图形
    // 右→左（w<0 即起点在右侧）= 选与框相交的图形
    const isLeftToRight: boolean = this.boxSelectLeftToRight;
    // Point selection filters painted leaves and returns their current-Cell root.
    // Keep the unfiltered bounds cache for ordinary box selection.
    const hasSelectionFilter: boolean = this.selectionLayerFilter >= 0 || this.selectionTypeFilter.length > 0;
    const filteredShapes: Shape[] = this.selectionTypeFilter.length === 0 || this.selectionTypeFilter.includes(ShapeType.INSTANCE) ?
      this.shapes : this.shapes.filter((shape: Shape): boolean =>
        shape.type === ShapeType.INSTANCE || this.selectionTypeFilter.includes(shape.type));
    const filteredBoundsResolver: HierarchyBoundsResolver | undefined = hasSelectionFilter ?
      new HierarchyBoundsResolver(filteredShapes, editService.getTopCellId(),
        (layer: number, datatype: number): boolean => this.isLayerVisible(layer, datatype) &&
          editService.canSelectLayer(layer, datatype) && (this.selectionLayerFilter < 0 ||
            (layer === this.selectionLayerFilter && (this.selectionDatatypeFilter < 0 || datatype === this.selectionDatatypeFilter))),
        1000000, 4000000, (text: string): number => this.measureSceneText(text)) : undefined;

    const ids: number[] = [];
    for (let i = 0; i < this.shapes.length; i++) {
      const s = this.shapes[i];
      if (!this.isShapeInteractable(s)) {
        continue;
      }
      if (s.type !== ShapeType.INSTANCE &&
        ((this.selectionLayerFilter >= 0 && (s.layerNumber !== this.selectionLayerFilter ||
          (this.selectionDatatypeFilter >= 0 && s.datatype !== this.selectionDatatypeFilter))) ||
          (this.selectionTypeFilter.length > 0 && !this.selectionTypeFilter.includes(s.type)))) continue;
      const geometry: HierarchyBoundsResult = s.type === ShapeType.INSTANCE && filteredBoundsResolver !== undefined ?
        filteredBoundsResolver.boundsForShape(s, this.hierarchyDepth) : this.visibleShapeBounds(s);
      if (!geometry.ok) {
        this.isBoxSelecting = false;
        this.boxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
        this.cursorStore.setReadout(geometry.message);
        return;
      }
      if (geometry.bounds === undefined) continue;
      const b: ShapeBounds = geometry.bounds;
      if (isLeftToRight) {
        // 完全包含：图形bounds完全在框内
        if (b.minX >= minX && b.maxX <= maxX && b.minY >= minY && b.maxY <= maxY) {
          ids.push(s.id);
        }
      } else {
        // 相交：bounds与框有交集
        if (b.maxX >= minX && b.minX <= maxX && b.maxY >= minY && b.minY <= maxY) {
          ids.push(s.id);
        }
      }
    }

    // Shift+框选 或触屏「加选」胶囊开启：追加到现有选择集（空框不误清空既有选区）
    if (isShiftHeld() || this.multiSelectAdditive) {
      const existing: number[] = editService.getSelectedIds();
      for (let i = 0; i < ids.length; i++) {
        if (existing.indexOf(ids[i]) < 0) {
          existing.push(ids[i]);
        }
      }
      editService.selectMultiple(existing);
      this.multiSelectIds = existing;
      this.selectMultipleAction(existing);
      this.requestRenderAction();
    } else if (ids.length > 0) {
      editService.selectMultiple(ids);
      this.multiSelectIds = ids;
      this.selectMultipleAction(ids);
      this.requestRenderAction();
    } else {
      // 空框选 → 清除多选
      this.multiSelectIds = [];
      editService.clearSelection();
      this.selectMultipleAction([]);
      this.requestRenderAction();
    }
    this.isBoxSelecting = false;
    this.boxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
  }

  /** Selected-instance outline only; undefined retains the anchor navigation marker.
   * Never present failed, empty, nonfinite or budget-incomplete traversal as a complete bbox. */
  private selectedInstanceBounds(shape: Shape): ShapeBounds | undefined {
    if (shape.type !== ShapeType.INSTANCE || isExpandedSyntheticShape(shape) || !this.isShapeSelected(shape.id)) {
      return undefined;
    }
    const result: HierarchyBoundsResult = this.visibleShapeBounds(shape);
    const bounds: ShapeBounds | undefined = result.bounds;
    if (!result.ok || bounds === undefined || !Number.isFinite(result.shapeCount) || result.shapeCount <= 0 ||
      !Number.isFinite(bounds.minX) || !Number.isFinite(bounds.minY) ||
      !Number.isFinite(bounds.maxX) || !Number.isFinite(bounds.maxY) ||
      !Number.isFinite(bounds.maxX - bounds.minX) || !Number.isFinite(bounds.maxY - bounds.minY) ||
      bounds.maxX <= bounds.minX || bounds.maxY <= bounds.minY) {
      return undefined;
    }
    return bounds;
  }

  private visibleShapeBounds(shape: Shape): HierarchyBoundsResult {
    if (shape.type === ShapeType.PATH) {
      const bounds: ShapeBounds | undefined = getPathGeometryBounds(shape);
      const ok: boolean = bounds === undefined || (Number.isFinite(bounds.minX) && Number.isFinite(bounds.minY) &&
        Number.isFinite(bounds.maxX) && Number.isFinite(bounds.maxY));
      return { ok: ok, bounds: bounds, shapeCount: bounds === undefined ? 0 : 1,
        message: ok ? '' : 'PATH 轮廓坐标越界，未更改选择' };
    }
    if (shape.type !== ShapeType.INSTANCE) return { ok: true, bounds: getShapeBounds(shape), shapeCount: 1, message: '' };
    return this.getHierarchyBoundsResolver().boundsForShape(shape, this.hierarchyDepth);
  }

  private getHierarchyBoundsResolver(): HierarchyBoundsResolver {
    const key: string = `${this.geometryRenderRevision}:${this.styleRenderRevision}:${editService.getSessionRevision()}:` +
      `${editService.getCurrentCellId()}:${this.hierarchyDepth}`;
    if (this.selectionBoundsResolver === null || this.selectionBoundsKey !== key) {
      this.selectionBoundsKey = key;
      this.selectionBoundsResolver = new HierarchyBoundsResolver(this.shapes, editService.getTopCellId(),
        (layer: number, datatype: number): boolean => this.isLayerVisible(layer, datatype), 1000000, 4000000,
        (text: string): number => this.measureSceneText(text));
    }
    return this.selectionBoundsResolver;
  }

  private hitVisibleShape(x: number, y: number, tolerance: number): HierarchyHitResult {
    return this.getHierarchyBoundsResolver().hitTestCell(editService.getCurrentCellId(), this.hierarchyDepth,
      x, y, tolerance, (shape: Shape): boolean => this.isShapeInteractable(shape), true, 1000000, 8000000);
  }

  private hitVisibleCandidates(x: number, y: number, tolerance: number): HierarchyCandidatesResult {
    return this.getHierarchyBoundsResolver().hitCandidatesCell(editService.getCurrentCellId(), this.hierarchyDepth,
      x, y, tolerance, (shape: Shape): boolean => this.isShapeInteractable(shape), {
        maxCandidates: 64, maxNodes: 1000000, maxPoints: 8000000,
        layerNumber: this.selectionLayerFilter, datatype: this.selectionDatatypeFilter >= 0 ? this.selectionDatatypeFilter : undefined,
        types: this.selectionTypeFilter, leafSelectable: (shape: Shape): boolean => editService.canSelectLayer(shape.layerNumber, shape.datatype)
      });
  }

  private cycleHitCandidate(direction: number): void {
    if (this.hitCandidates.length < 2) return;
    this.pickHitCandidate((this.hitCandidateIndex + direction + this.hitCandidates.length) % this.hitCandidates.length);
  }

  private pickHitCandidate(index: number): void {
    const previous: HierarchyHitCandidate | undefined = this.hitCandidates[index];
    if (previous === undefined || this.hitCandidateContext !==
      `${this.documentKey}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`) { this.clearHitCandidates(); return; }
    // Requery after edits or access changes; old candidate indices must never modify a different object.
    const fresh: HierarchyCandidatesResult = this.hitVisibleCandidates(this.hitCandidateX, this.hitCandidateY, this.hitCandidateTolerance);
    if (!fresh.ok) { this.clearHitCandidates(); this.cursorStore.setReadout(fresh.message); return; }
    const key: string = `${previous.rootShapeId}:${previous.leafShapeId}:${JSON.stringify(previous.path)}`;
    const next: number = fresh.candidates.findIndex((candidate: HierarchyHitCandidate) =>
      `${candidate.rootShapeId}:${candidate.leafShapeId}:${JSON.stringify(candidate.path)}` === key);
    if (next < 0) { this.clearHitCandidates(); return; }
    this.hitCandidates = fresh.candidates; this.hitCandidateIndex = next; this.hitCandidatesMessage = fresh.message;
    const candidate: HierarchyHitCandidate = fresh.candidates[next];
    const shape: Shape | undefined = editService.getShapes().find((s: Shape) => s.id === candidate.rootShapeId);
    if (shape === undefined || !this.isShapeInteractable(shape)) { this.clearHitCandidates(); return; }
    this.lastShapeClickId = -1; this.lastShapeClickAt = 0;
    this.selectShapeAction(shape); this.onPickCandidate(candidate); this.onHitCandidates(fresh, next);
    this.updateCandidatePreview(candidate);
    this.cursorStore.setReadout(this.hitCandidateLabel(candidate));
  }

  private hitCandidateLabel(candidate: HierarchyHitCandidate): string {
    const path: string = candidate.path.map((step: InstancePathStep): string => {
      const cellName: string = this.renderCellNames[step.cellId] ?? `Cell ${step.cellId}`;
      return `${cellName}#${step.instanceId}[${step.row + 1},${step.col + 1}]`;
    }).join(' / ');
    return `#${candidate.leafShapeId} ${candidate.leafType} · L${candidate.layerNumber}/${candidate.datatype}` +
      (path.length === 0 ? '' : `\n${path}`);
  }

  private updateCandidatePreview(candidate: HierarchyHitCandidate): void {
    const leaf: Shape | undefined = editService.getShapes().find((s: Shape) => s.id === candidate.leafShapeId);
    if (leaf === undefined) return;
    const step: InstancePathStep | undefined = candidate.path[candidate.path.length - 1];
    const m = step?.transform;
    let bounds: ShapeBounds = getShapeBounds(leaf);
    if (m !== undefined && leaf.type === ShapeType.PATH) {
      const pathTransform: PathBoundsTransform = { a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty };
      const painted: ShapeBounds | undefined = getPathGeometryBounds(leaf, pathTransform);
      if (painted === undefined) return; bounds = painted;
    } else if (m !== undefined) {
      const corners: Point[] = [{ x: bounds.minX, y: bounds.minY }, { x: bounds.maxX, y: bounds.minY },
        { x: bounds.maxX, y: bounds.maxY }, { x: bounds.minX, y: bounds.maxY }];
      const points: Point[] = corners.map((p: Point): Point => ({ x: m.a * p.x + m.b * p.y + m.tx, y: m.c * p.x + m.d * p.y + m.ty }));
      bounds = { minX: Math.min(...points.map((p: Point) => p.x)), maxX: Math.max(...points.map((p: Point) => p.x)),
        minY: Math.min(...points.map((p: Point) => p.y)), maxY: Math.max(...points.map((p: Point) => p.y)) };
    }
    this.hitCandidatePreview = { x: bounds.minX, y: bounds.minY, w: bounds.maxX - bounds.minX, h: bounds.maxY - bounds.minY };
  }

  @Builder
  HitCandidateBar() {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Text(`命中 ${this.hitCandidates.length} 项 · Tab 轮选`).fontSize(12).fontColor(canvasOverlayInk()).layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Button('上一项', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontBody)
          .backgroundColor(canvasOverlayInactive()).fontColor(canvasOverlayInk()).border({ width: 1, color: canvasOverlayBorder() }).borderRadius(UI.controlRadius)
          .focusable(false)
          .onClick(() => this.cycleHitCandidate(-1))
        Button('下一项', { type: ButtonType.Normal }).height(UI.compactControlHeight).fontSize(UI.fontBody)
          .backgroundColor(canvasOverlayInactive()).fontColor(canvasOverlayInk()).border({ width: 1, color: canvasOverlayBorder() }).borderRadius(UI.controlRadius)
          .focusable(false)
          .onClick(() => this.cycleHitCandidate(1))
      }
      Scroll() {
        Column({ space: 4 }) {
          ForEach(this.hitCandidates, (candidate: HierarchyHitCandidate, index: number) => {
            Button({ type: ButtonType.Normal }) {
              Text(this.hitCandidateLabel(candidate)).fontSize(UI.fontBody)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .fontColor(index === this.hitCandidateIndex ? COLORS.primary : canvasOverlayInk())
            }
              .height(candidate.path.length > 0 ? 52 : UI.controlHeight).width('100%')
              .backgroundColor(index === this.hitCandidateIndex ? COLORS.primarySoft : canvasOverlayBackground())
              .border({ width: 1, color: canvasOverlayBorder() }).borderRadius(UI.controlRadius)
              .focusable(false)
              .accessibilityText(this.hitCandidateLabel(candidate))
              .onClick(() => this.pickHitCandidate(index))
          }, (candidate: HierarchyHitCandidate) => `${candidate.rootShapeId}:${candidate.leafShapeId}:${JSON.stringify(candidate.path)}`)
        }
      }.constraintSize({ maxHeight: this.isCompact ? 108 : 180 }).width('100%').align(Alignment.Top)
      if (this.hitCandidatesMessage.length > 0) {
        Text(this.hitCandidatesMessage).fontSize(11).fontColor(canvasOverlayMuted())
      }
    }
    .width(Math.min(this.isCompact ? 280 : 360,
      Math.max(212, this.canvasWidth - (this.desktopMode ? 84 : 24)))).padding(UI.panelPadding)
    .backgroundColor(canvasOverlayBackground()).border({ width: 1, color: canvasOverlayBorder() }).borderRadius(UI.panelRadius)
    .position({ x: this.desktopMode ? 72 : 12, y: 104 })
    .onTouch((event: TouchEvent) => event.stopPropagation())
    .onMouse((event: MouseEvent) => event.stopPropagation())
  }

  /** 微调弹框确认：用最终 dx/dy 通过 moveShapeAction 回调（保留宏录制与 undo）。
   *  校验（NaN、未选中）已下沉至 MoveFineTuneDialog，本方法仅执行位移与清理。 */
  private applyMoveFineTune(dx: number, dy: number): boolean {
    if (!this.editable || this.currentTool !== ActiveTool.Move || this.pendingMoveIds.length === 0 ||
      this.pendingMoveContext.length === 0 || this.pendingMoveContext !== this.editGestureContext() ||
      !Number.isFinite(dx) || !Number.isFinite(dy)) {
      this.cursorStore.setReadout('版图或选择已变化，请重新长按打开微调'); return false;
    }
    for (const id of this.pendingMoveIds) {
      const shape: Shape | undefined = editService.getShapes().find((item: Shape) => item.id === id);
      if (shape === undefined || !editService.isShapeInCurrentCell(shape) || !editService.canEditLayer(shape.layerNumber, shape.datatype) ||
        shape.points.some((p: Point) => !Number.isFinite(p.x + dx) || !Number.isFinite(p.y + dy))) {
        this.cursorStore.setReadout('选区含锁定或无效对象，未移动任何图形'); return false;
      }
    }
    // CANVAS-8/9: 支持多选，遍历 pendingMoveIds 移动全部选中图形
    if (this.pendingMoveIds.length > 1) {
      editService.beginBatch();
    }
    for (let i = 0; i < this.pendingMoveIds.length; i++) {
      this.moveShapeAction(this.pendingMoveIds[i], dx, dy);
    }
    if (this.pendingMoveIds.length > 1) {
      editService.endBatch();
    }
    this.requestRenderAction();
    this.pendingMoveIds = [];
    this.pendingMoveContext = '';
    return true;
  }

  /** 面包屑点击：跳转到对应层级（idx=0 即 Top → exitToTop；其余重建栈至该层） */
  private onBreadcrumbClick(idx: number): void {
    if (idx < 0 || idx >= this.cellStackIds.length) {
      return;
    }
    this.multiSelectIds = [];
    this.onNavigateCellStack(idx);
    this.syncCellStackState();
  }

  /** 生成面包屑节点列表（从 editService 当前 Cell 栈） */
  private cellStackLabels(): BreadcrumbItem[] {
    const stack: number[] = this.cellStackIds;
    const items: BreadcrumbItem[] = [];
    for (let i = 0; i < stack.length; i++) {
      const label: string = i === 0 ? 'Top' : `#${stack[i]}`;
      const path: InstancePathStep[] = editService.getNavigationPath();
      const step: InstancePathStep | undefined = path[i - 1];
      const name: string = this.renderCellNames[stack[i]] ?? label;
      items.push({ label: step === undefined ? name : `${name} · #${step.instanceId}[${step.row + 1},${step.col + 1}]`, cellId: stack[i] });
    }
    return items;
  }

  /** 是否选中（单选主选 或 框选多选集合） */
  private isShapeSelected(id: number): boolean {
    if (id === this.selectedShapeId) {
      return true;
    }
    if (this.selectionCacheRevision !== this.geometryRenderRevision) {
      const flags: Set<number> = new Set<number>();
      for (let i = 0; i < this.shapes.length; i++) {
        const shape: Shape = this.shapes[i];
        if (shape.selected) flags.add(shape.id);
      }
      this.selectionFlagIds = flags;
      this.selectionCacheRevision = this.geometryRenderRevision;
    }
    if (this.selectionFlagIds.has(id)) return true;
    for (let i = 0; i < this.multiSelectIds.length; i++) {
      if (this.multiSelectIds[i] === id) {
        return true;
      }
    }
    return false;
  }

  private commitPendingShapeClick(): void {
    const id: number = this.pendingClickShapeId;
    this.pendingClickShapeId = -1;
    const shape: Shape | undefined = editService.getShapes().find((s: Shape) => s.id === id);
    if (shape !== undefined) this.handleShapeClick(shape);
    const candidate: HierarchyHitCandidate | undefined = this.hitCandidates[this.hitCandidateIndex];
    if (candidate !== undefined && candidate.rootShapeId === id) { this.onPickCandidate(candidate); this.updateCandidatePreview(candidate); }
  }

  /**
   * 仅回滚当前手指尚未松手确认的瞬态指针动作（专供双指缩放/平移介入调用）：
   * 完整保留多边形/路径已落定的顶点列表，解决“边画多边形边双指放大时草稿被清空”的痛点。
   */
  private cancelTransientPointerOnly(): void {
    this.gestureContext = '';
    this.pendingClickShapeId = -1;
    this.isMousePanning = false;
    this.isSingleFingerPanning = false;
    this.hasPendingStampTouch = false;
    this.isPreviewing = false;
    this.previewRect = { x: 0, y: 0, w: 0, h: 0 };
    this.hasDrawStart = false;
    this.isDragging = false;
    this.dragThresholdExceeded = false;
    this.dragOffsetX = 0;
    this.dragOffsetY = 0;
    this.moveGhostOutlines = [];
    this.isBoxSelecting = false;
    this.boxSelectRect = { x: 0, y: 0, w: 0, h: 0 };
    this.hasPendingPolyTouch = false;
    this.polyLiveTail = [];
    this.polyCloseLoopReady = false;
    this.hasPendingTextTouch = false;
    this.hasCurveStart = false;
    this.hasMeasureTouchActive = false;
    if (this.hasRulerDown) {
      this.hasRulerDown = false;
      this.measureStore.reset();
    } else if (this.measureStore.pending && !this.measureWasWaitingSecondPoint) {
      // 第一指刚按下尚未完成起点确认即进入双指缩放：回滚本次误触起点
      this.measureStore.reset();
    }
    if (this.vertexStore.isDragging()) this.vertexStore.revert();
    if (this.isDrawingPoly && this.polygonPoints.length === 0) {
      this.clearPolyDraw();
    } else {
      draftCanvasEngine.clearTransientPointerVisuals(true, this.draftControlStore.stampActive);
      this.syncPolyDraftCanvas();
    }
  }

  /** 彻底取消尚未提交的手势与多边形草稿（供 Escape / 切文档 / 退出编辑模式调用） */
  private cancelActiveGesture(): void {
    this.hasPendingStampTouch = false;
    this.isSingleFingerPanning = false;
    this.cancelTransientPointerOnly();
    this.clearPolyDraw();
    this.clearMeasure();
    draftCanvasEngine.clearAll();
  }

  private isLayerVisible(layerNumber: number, datatype: number): boolean {
    const layer: UiLayer | undefined = this.findLayer(layerNumber, datatype);
    return layer === undefined || layer.visible;
  }

  private colorForLayer(layerNumber: number, datatype: number): string {
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].layerNumber === layerNumber && this.layers[i].datatype === datatype) {
        return this.layers[i].color;
      }
    }
    return isWhiteCanvas() ? '#25364F' : '#FFFFFF';
  }

  private toolLabel(): string {
    if (this.draftControlStore.stampActive) return '点放器件';
    if (this.draftControlStore.curveKind.length > 0) {
      return routingConstraintService.curveKindLabel(this.draftControlStore.curveKind);
    }
    if (this.currentTool === ActiveTool.BoxZoom) return '框选放大';
    if (this.currentTool === ActiveTool.Pan) return '漫游';
    if (this.currentTool === ActiveTool.Select) {
      return '选择';
    }
    if (this.currentTool === ActiveTool.Rect) {
      return '矩形';
    }
    if (this.currentTool === ActiveTool.Polygon) {
      return '多边形';
    }
    if (this.currentTool === ActiveTool.Path) {
      return '路径';
    }
    if (this.currentTool === ActiveTool.Measure) {
      return '测量';
    }
    if (this.currentTool === ActiveTool.Move) {
      return '移动';
    }
    return '文本';
  }
}

@Component
struct ViewSceneNode {
  @Prop primitive: ViewScenePrimitive;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop canvasWidth: number = 0;
  @Prop canvasHeight: number = 0;
  @Prop densitySignal: number = 1;

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.primitive.kind === 'text') {
        Text(this.primitive.text)
          .fontSize(`${SCENE_TEXT_FONT_SIZE}vp`).fontFamily(FONT_MONO).fontWeight(FontWeight.Medium)
          .minFontScale(1).maxFontScale(1).lineHeight(SCENE_TEXT_LINE_HEIGHT)
          .width(this.primitive.textWidth).height(this.primitive.textHeight).textAlign(TextAlign.Start)
          .fontColor(this.primitive.color)
          .opacity(this.primitive.style.strokeOpacity * this.primitive.opacity)
          // Explicit origin prevents the glyph's measured center moving its
          // GDS anchor during a mirror/rotation/shear.
          .rotate({ angle: 0, centerX: 0, centerY: 0 })
          .transform(this.glyphTransform())
          .hitTestBehavior(HitTestMode.None)
      } else {
        if (this.primitive.style.hatch.length > 0 && this.primitive.hierarchyFrame !== true &&
          this.primitive.opacity > 0 && this.primitive.style.fillOpacity > 0) {
          ViewSceneHatchNode({ primitive: this.primitive, zoomPercent: this.zoomPercent,
            region: sceneHatchRegion(this.primitive, this.canvasWidth, this.canvasHeight,
              this.zoomPercent, this.viewOffsetX, this.viewOffsetY), densitySignal: this.densitySignal })
        }
        if (hasKeyholeBridgeEdges(this.primitive.points)) {
          Path({ width: this.sceneNodeWidth(), height: this.sceneNodeHeight() })
            .commands(this.keyholePathCommands())
            .fill(this.primitive.color)
            .fillOpacity(this.primitive.style.strokeOnly ? 0 : this.primitive.style.fillOpacity * this.primitive.opacity)
            .stroke(this.primitive.color)
            .strokeOpacity(this.primitive.style.strokeOpacity * this.primitive.opacity)
            .strokeWidth(this.primitive.style.strokeWidth)
            .strokeDashArray(this.primitive.style.dashArray)
            .hitTestBehavior(HitTestMode.None)
        } else {
          Polygon({ width: this.sceneNodeWidth(), height: this.sceneNodeHeight() })
            .points(this.localPoints()).fill(this.primitive.color)
            .fillOpacity(this.primitive.style.strokeOnly ? 0 : this.primitive.style.fillOpacity * this.primitive.opacity)
            .stroke(this.primitive.color)
            .strokeOpacity(this.primitive.style.strokeOpacity * this.primitive.opacity)
            .strokeWidth(this.primitive.style.strokeWidth)
            .strokeDashArray(this.primitive.style.dashArray)
            .hitTestBehavior(HitTestMode.None)
        }
      }
    }
    .width(this.sceneNodeWidth()).height(this.sceneNodeHeight())
    .position({ x: this.x(), y: this.y() })
    .hitTestBehavior(HitTestMode.None)
  }

  private bounds(): ShapeBounds {
    const b: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    for (const p of this.primitive.points) {
      b.minX = Math.min(b.minX, p.x); b.minY = Math.min(b.minY, p.y);
      b.maxX = Math.max(b.maxX, p.x); b.maxY = Math.max(b.maxY, p.y);
    }
    return b;
  }
  private x(): number { return worldToScreenPx(this.bounds().minX, this.zoomPercent, this.viewOffsetX); }
  private y(): number { return worldToScreenYpx(this.bounds().maxY, this.zoomPercent, this.viewOffsetY); }
  private sceneNodeWidth(): number { return this.primitive.kind === 'text' ? this.primitive.textWidth :
    Math.max(0.01, (this.bounds().maxX - this.bounds().minX) * this.zoomPercent / 100); }
  private sceneNodeHeight(): number { return this.primitive.kind === 'text' ? this.primitive.textHeight :
    Math.max(0.01, (this.bounds().maxY - this.bounds().minY) * this.zoomPercent / 100); }
  private localPoints(): Array<Array<number>> {
    const b: ShapeBounds = this.bounds(); const z: number = this.zoomPercent / 100;
    return this.primitive.points.map((p: Point): Array<number> => [(p.x - b.minX) * z, (b.maxY - p.y) * z]);
  }
  private keyholePathCommands(): string {
    const b: ShapeBounds = this.bounds();
    const z: number = this.zoomPercent / 100;
    const ctx = this.getUIContext();
    const loops: Point[][] = extractKeyholeCleanLoops(this.primitive.points);
    const cmds: string[] = [];
    for (let li = 0; li < loops.length; li++) {
      const loop: Point[] = loops[li];
      for (let i = 0; i < loop.length; i++) {
        const px: number = ctx.vp2px((loop[i].x - b.minX) * z);
        const py: number = ctx.vp2px((b.maxY - loop[i].y) * z);
        cmds.push(`${i === 0 ? 'M' : 'L'}${px} ${py}`);
      }
      cmds.push('Z');
    }
    return cmds.join(' ');
  }
  private glyphTransform(): matrix4.Matrix4Transit {
    const m = this.primitive.textTransform; const z: number = this.zoomPercent / 100;
    // World Y is flipped exactly once. Both camera scale and the complete
    // source/hierarchy/intrinsic glyph affine are applied to the local glyph.
    return matrix4.init([m.a * z, -m.c * z, 0, 0, -m.b * z, m.d * z, 0, 0,
      0, 0, 1, 0, 0, 0, 0, 1]);
  }
}

@Component
struct ViewSceneHatchNode {
  @Prop primitive: ViewScenePrimitive;
  @Prop zoomPercent: number = 100;
  @Prop region: SceneHatchRegion | undefined = undefined;
  @Prop @Watch('onDensitySignalChanged') densitySignal: number = 1;
  private commandsKey: string = '';
  private contourCommands: string = '';
  private lineCommands: string = '';

  build() {
    if (this.region !== undefined) {
      Path({ width: this.region.width, height: this.region.height })
        .commands(this.hatchLines(this.densitySignal))
        .fillOpacity(0)
        .stroke(this.primitive.color)
        .strokeOpacity(this.primitive.style.fillOpacity * this.primitive.opacity)
        .strokeWidth(1)
        .strokeLineCap(LineCapStyle.Butt)
        .clipShape(new PathShape({ commands: this.hatchContour(this.densitySignal) }))
        .position({ x: this.region.localLeft, y: this.region.localTop })
        .hitTestBehavior(HitTestMode.None)
    }
  }

  private onDensitySignalChanged(): void {
    this.commandsKey = ''; this.contourCommands = ''; this.lineCommands = '';
  }

  private hatchLines(signal: number): string { this.prepareCommands(signal); return this.lineCommands; }
  private hatchContour(signal: number): string { this.prepareCommands(signal); return this.contourCommands; }

  private prepareCommands(signal: number): void {
    const region: SceneHatchRegion | undefined = this.region;
    if (region === undefined) { this.commandsKey = ''; this.contourCommands = ''; this.lineCommands = ''; return; }
    const context = this.getUIContext(); const density: number = context.vp2px(1);
    const key: string = JSON.stringify([this.primitive.key, this.zoomPercent, region, signal, density]);
    if (key === this.commandsKey) return;
    const z: number = this.zoomPercent / 100;
    const contour: string[] = [];
    for (let i: number = 0; i < this.primitive.points.length; i++) {
      const p: Point = this.primitive.points[i];
      const x: number = context.vp2px((p.x - region.minX) * z - region.localLeft);
      const y: number = context.vp2px((region.maxY - p.y) * z - region.localTop);
      contour.push(`${i === 0 ? 'M' : 'L'}${x} ${y}`);
    }
    contour.push('Z');
    const lines: string[] = [];
    const segment = (x0: number, y0: number, x1: number, y1: number): void => {
      if (x1 > x0) lines.push(`M${context.vp2px(x0)} ${context.vp2px(y0)} L${context.vp2px(x1)} ${context.vp2px(y1)}`);
    };
    // Both families share the fixed canvas phase. Only visible rectangle
    // intersections are generated; polygon clipping is delegated to ArkUI.
    const first: number = Math.ceil((region.left + region.top) / SCENE_HATCH_STEP_VP);
    const last: number = Math.floor((region.left + region.width + region.top + region.height) / SCENE_HATCH_STEP_VP);
    for (let k: number = first; k <= last; k++) {
      const s: number = k * SCENE_HATCH_STEP_VP - region.left - region.top;
      const x0: number = Math.max(0, s - region.height); const x1: number = Math.min(region.width, s);
      segment(x0, s - x0, x1, s - x1);
    }
    if (this.primitive.style.hatch === 'cross') {
      const crossFirst: number = Math.ceil((region.left - region.top - region.height) / SCENE_HATCH_STEP_VP);
      const crossLast: number = Math.floor((region.left + region.width - region.top) / SCENE_HATCH_STEP_VP);
      for (let k: number = crossFirst; k <= crossLast; k++) {
        const d: number = k * SCENE_HATCH_STEP_VP - region.left + region.top;
        const x0: number = Math.max(0, d); const x1: number = Math.min(region.width, d + region.height);
        segment(x0, x0 - d, x1, x1 - d);
      }
    }
    this.contourCommands = contour.join(' '); this.lineCommands = lines.join(' '); this.commandsKey = key;
  }
}

@Component
struct ViewSceneTextSelectionNode {
  @Prop primitive: ViewScenePrimitive | undefined = undefined;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop dragOffsetX: number = 0;
  @Prop dragOffsetY: number = 0;

  build() {
    if (this.primitive !== undefined) {
      Stack({ alignContent: Alignment.TopStart }) {
        Polygon({ width: this.selectionBoxWidth(), height: this.selectionBoxHeight() })
          .points(this.localOutlinePoints()).fillOpacity(0)
          .stroke(canvasSelectionStroke()).strokeWidth(1.5)
        Rect().width(4).height(4).fill(canvasSelectionStroke())
          .position({ x: -this.outlineBounds().minX - 2, y: -this.outlineBounds().minY - 2 })
      }
      .width(this.selectionBoxWidth()).height(this.selectionBoxHeight())
      .position({ x: this.x(), y: this.y() })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  private outlinePoints(): Point[] {
    if (this.primitive === undefined) return [];
    const m = this.primitive.textTransform;
    const z: number = this.zoomPercent / 100;
    const width: number = this.primitive.textWidth;
    const height: number = this.primitive.textHeight;
    const corners: Point[] = [{ x: 0, y: 0 }, { x: width, y: 0 }, { x: width, y: height }, { x: 0, y: height }];
    // Same glyph-to-screen map as ViewSceneNode, with a top-left origin.
    return corners.map((p: Point): Point => ({ x: (m.a * p.x - m.b * p.y) * z, y: (-m.c * p.x + m.d * p.y) * z }));
  }

  private outlineBounds(): ShapeBounds {
    const points: Point[] = this.outlinePoints();
    if (points.length === 0) return { minX: 0, minY: 0, maxX: 0, maxY: 0 };
    const bounds: ShapeBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    for (const point of points) {
      bounds.minX = Math.min(bounds.minX, point.x); bounds.maxX = Math.max(bounds.maxX, point.x);
      bounds.minY = Math.min(bounds.minY, point.y); bounds.maxY = Math.max(bounds.maxY, point.y);
    }
    return bounds;
  }

  private localOutlinePoints(): Array<Array<number>> {
    const bounds: ShapeBounds = this.outlineBounds();
    return this.outlinePoints().map((point: Point): Array<number> => [point.x - bounds.minX, point.y - bounds.minY]);
  }

  private selectionBoxWidth(): number {
    const bounds: ShapeBounds = this.outlineBounds();
    return Math.max(1, bounds.maxX - bounds.minX);
  }

  private selectionBoxHeight(): number {
    const bounds: ShapeBounds = this.outlineBounds();
    return Math.max(1, bounds.maxY - bounds.minY);
  }

  private x(): number {
    const anchor: Point = this.primitive?.points[0] ?? { x: 0, y: 0 };
    return worldToScreenPx(anchor.x, this.zoomPercent, this.viewOffsetX) + this.outlineBounds().minX + this.dragOffsetX;
  }

  private y(): number {
    const anchor: Point = this.primitive?.points[0] ?? { x: 0, y: 0 };
    return worldToScreenYpx(anchor.y, this.zoomPercent, this.viewOffsetY) + this.outlineBounds().minY + this.dragOffsetY;
  }
}

@Component
struct ShapeNode {
  @Prop shape: Shape = { id: 0, type: ShapeType.RECT, layerNumber: 0, datatype: 0, points: [{ x: 0, y: 0 }, { x: 0, y: 0 }], selected: false };
  @Prop color: string = '#FFFFFF';
  /**
   * §5 图层显示样式（线型 / 填充 / 透明度 / 加亮）。
   * 由 LayoutCanvasView.styleForLayer() 从同一批 UiLayer 派生（layerRenderStyle），
   * 这里不读任何平行图层列表。
   */
  @Prop style: LayerRenderStyle = {
    fillOpacity: 0.62,
    strokeOpacity: 0.85,
    strokeOnly: false,
    hatch: '',
    dashArray: [],
    strokeWidth: 1,
    highlighted: false,
    animated: false,
  };
  /** 动画层闪烁相位（非动画层恒 1） */
  @Prop blink: number = 1;
  @Prop selected: boolean = false;
  @Prop quietInstanceOverlay: boolean = false;
  // A successful complete hierarchy bbox for selected INSTANCE only; no stored-geometry changes.
  @Prop instanceSelectionBounds: ShapeBounds | undefined = undefined;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop dragOffsetX: number = 0;
  @Prop dragOffsetY: number = 0;
  selectShapeAction: (shape: Shape) => void = () => {};

  build() {
    Stack() {
      if (this.shape.type === ShapeType.POLYGON && hasKeyholeBridgeEdges(this.shape.points)) {
        Path({ width: this.shapeWidth(), height: this.shapeHeight() })
          .commands(this.localKeyholePathCommands())
          .fill(this.color)
          .fillOpacity(this.fillAlpha())
          .stroke(this.selected ? canvasSelectionStroke() : this.color)
          .strokeOpacity(this.strokeAlpha())
          .strokeWidth(this.strokeWidthFor(this.selected ? 2 : 1))
          .strokeDashArray(this.dashArrayFor())
      } else if (this.shape.type === ShapeType.POLYGON) {
        Polygon({ width: this.shapeWidth(), height: this.shapeHeight() })
          .points(this.localPointPairs())
          .fill(this.color)
          .fillOpacity(this.fillAlpha())
          .stroke(this.selected ? canvasSelectionStroke() : this.color)
          .strokeOpacity(this.strokeAlpha())
          .strokeWidth(this.strokeWidthFor(this.selected ? 2 : 1))
          .strokeDashArray(this.dashArrayFor())
      } else if (this.shape.type === ShapeType.PATH) {
        Polyline({ width: this.shapeWidth(), height: this.shapeHeight() })
          .points(this.localPointPairs())
          .fillOpacity(0)
          .stroke(this.selected ? canvasSelectionStroke() : this.color)
          .strokeOpacity(this.strokeAlpha())
          .strokeWidth(this.pathStrokeWidthFor())
          .strokeLineCap(this.shape.pathType === 1 ? LineCapStyle.Round :
            (this.shape.pathType === 2 ? LineCapStyle.Square : LineCapStyle.Butt))
          // PATH 是 GDS 线型语义最强的图元：dash 只作用在描边相位上，不改变宽度口径
          .strokeDashArray(this.dashArrayFor())
      } else if (this.shape.type === ShapeType.TEXT) {
        Text(this.shape.text ?? '')
          .fontSize(12)
          .fontColor(this.selected ? canvasSelectionStroke() : this.color)
          .fontWeight(FontWeight.Medium)
          // 动画层闪烁与图层透明度对文本同样生效
          .opacity(this.textAlpha())
          .transform(this.textTransform())
      } else if (this.shape.type === ShapeType.INSTANCE) {
        Stack() {
          Rect()
            .width(this.shapeWidth())
            .height(this.shapeHeight())
            .fill(this.quietInstanceOverlay && !this.selected ? '#00000000' : withAlpha(isWhiteCanvas() ? COLORS.primary : '#FFFFFF', 0.05))
            .stroke(this.selected ? canvasSelectionStroke() : (this.quietInstanceOverlay ? '#8192A6' : this.color))
            .strokeOpacity(this.quietInstanceOverlay && !this.selected ? 0.45 : this.strokeAlpha())
            .strokeWidth(this.strokeWidthFor(this.selected ? 2 : 1))
            .strokeDashArray(this.dashArrayFor())
            .borderRadius(2)
          if (this.shapeWidth() >= 120 && this.shapeHeight() >= 40) {
            Text(this.shape.cellName ?? `#${this.shape.cellId ?? this.shape.id}`)
              .fontSize(9)
              .fontColor(canvasOverlayInk())
              .maxLines(1)
          }
        }
        .width(this.shapeWidth())
        .height(this.shapeHeight())
      } else {
        Rect()
          .width(this.shapeWidth())
          .height(this.shapeHeight())
          .fill(this.color)
          .fillOpacity(this.fillAlpha())
          .stroke(this.selected ? canvasSelectionStroke() : this.color)
          .strokeOpacity(this.strokeAlpha())
          .strokeWidth(this.strokeWidthFor(this.selected ? 2 : 1))
          .strokeDashArray(this.dashArrayFor())
          .borderRadius(2)
      }
    }
    .width(this.shapeWidth())
    .height(this.shapeHeight())
    .position({ x: this.shapeX(), y: this.shapeY() })
    .onClick(() => {
      this.selectShapeAction(this.shape);
    })
  }

  /** 填充不透明度：strokeOnly（outline / hollow，及 cross/diagonal 的无图案退化）恒 0 */
  private fillAlpha(): number {
    if (this.style.strokeOnly) {
      return 0;
    }
    const base: number = this.selected
      ? (isWhiteCanvas() ? Math.min(0.20, this.style.fillOpacity) : Math.max(0.88, this.style.fillOpacity))
      : this.style.fillOpacity;
    return this.clampUnit(base * this.blink);
  }

  /** 描边不透明度：选中始终全实，否则按图层透明度（描边地板由 layerRenderStyle 兜住） */
  private strokeAlpha(): number {
    const base: number = this.selected ? 1 : this.style.strokeOpacity;
    return this.clampUnit(base * this.blink);
  }

  private textAlpha(): number {
    const base: number = this.selected ? 1 : this.style.strokeOpacity;
    return this.clampUnit(base * this.blink);
  }

  private textTransform(): matrix4.Matrix4Transit {
    const mirror: number = this.shape.mirror ?? 0;
    const angle: number = ((this.shape.rotation ?? 0) + (mirror === 2 ? 180 : 0)) * Math.PI / 180;
    const mag: number = this.shape.magnification ?? 1;
    const reflection: number = mirror === 0 ? 1 : -1;
    const c: number = Math.cos(angle) * mag;
    const s: number = Math.sin(angle) * mag;
    // Column-major local glyph transform; screen Y reverses world rotation.
    return matrix4.init([c, -s, 0, 0, reflection * s, reflection * c, 0, 0,
      0, 0, 1, 0, 0, 0, 0, 1]);
  }

  /** 描边宽度：图层 lineWidth 作为下限，选中/加亮的既有粗度不回退 */
  private strokeWidthFor(minimum: number): number {
    return Math.max(minimum, this.style.strokeWidth);
  }

  /** PATH：GDS 真实线宽与图层显示线宽取大，保证样式不会把粗路径削细 */
  private pathStrokeWidthFor(): number {
    return Math.max(this.pathStrokeWidth(), this.style.strokeWidth);
  }

  /** dash 模式属图层语义（非选中态），选中也保留 */
  private dashArrayFor(): number[] {
    return this.style.dashArray;
  }

  private clampUnit(v: number): number {
    if (!Number.isFinite(v) || v < 0) {
      return 0;
    }
    return v > 1 ? 1 : v;
  }

  private localPointPairs(): Array<Array<number>> {
    const b = this.bounds();
    const pad: number = this.pathPadding();
    const points: Array<Array<number>> = [];
    const outline: Point[] = this.pathDisplayPoints();
    for (let i = 0; i < outline.length; i++) {
      points.push([
        Math.round((outline[i].x - b.minX) * this.zoomPercent / 100 + pad),
        Math.round((b.maxY - outline[i].y) * this.zoomPercent / 100 + pad)
      ]);
    }
    return points;
  }

  private localKeyholePathCommands(): string {
    const b = this.bounds();
    const pad: number = this.pathPadding();
    const z: number = this.zoomPercent / 100;
    const ctx = this.getUIContext();
    const loops: Point[][] = extractKeyholeCleanLoops(this.shape.points);
    const cmds: string[] = [];
    for (let li = 0; li < loops.length; li++) {
      const loop: Point[] = loops[li];
      for (let i = 0; i < loop.length; i++) {
        const px: number = ctx.vp2px((loop[i].x - b.minX) * z + pad);
        const py: number = ctx.vp2px((b.maxY - loop[i].y) * z + pad);
        cmds.push(`${i === 0 ? 'M' : 'L'}${px} ${py}`);
      }
      cmds.push('Z');
    }
    return cmds.join(' ');
  }

  private pathDisplayPoints(): Point[] {
    if (this.shape.type !== ShapeType.PATH || this.shape.pathType !== 4 || this.shape.points.length < 2) return this.shape.points;
    const points: Point[] = this.shape.points.filter((p: Point, i: number): boolean => i === 0 ||
      p.x !== this.shape.points[i - 1].x || p.y !== this.shape.points[i - 1].y)
      .map((p: Point): Point => ({ x: p.x, y: p.y }));
    if (points.length < 2) return points;
    const start: Point = points[0]; const next: Point = points[1];
    const end: Point = points[points.length - 1]; const prior: Point = points[points.length - 2];
    const beginScale: number = (this.shape.pathBeginExtension ?? 0) / Math.hypot(next.x - start.x, next.y - start.y);
    const endScale: number = (this.shape.pathEndExtension ?? 0) / Math.hypot(end.x - prior.x, end.y - prior.y);
    const endX: number = end.x + (end.x - prior.x) * endScale;
    const endY: number = end.y + (end.y - prior.y) * endScale;
    start.x -= (next.x - start.x) * beginScale;
    start.y -= (next.y - start.y) * beginScale;
    end.x = endX; end.y = endY;
    return points;
  }

  private pathPadding(): number {
    return this.shape.type === ShapeType.PATH ? this.pathStrokeWidth() / 2 + 2 : 0;
  }

  private pathStrokeWidth(): number {
    if (this.shape.pathWidth === undefined) {
      return this.selected ? 3 : 2;
    }
    return Math.max(this.selected ? 3 : 2, Math.round(this.shape.pathWidth * this.zoomPercent / 100));
  }

  private shapeX(): number {
    return Math.round((this.bounds().minX + this.viewOffsetX) * this.zoomPercent / 100 - this.pathPadding()) + this.dragOffsetX;
  }

  private shapeY(): number {
    return Math.round(worldToScreenYpx(this.bounds().maxY, this.zoomPercent, this.viewOffsetY) - this.pathPadding()) + this.dragOffsetY;
  }

  private measureTextWidth(text: string, fontSize: number = 12): number {
    return MeasureText.measureText({
      textContent: text,
      fontSize: fontSize,
      fontFamily: FONT_MONO
    });
  }

  private shapeWidth(): number {
    if (this.shape.type === ShapeType.TEXT) {
      return Math.max(48, this.measureTextWidth(this.shape.text ?? ''));
    }
    if (this.shape.type === ShapeType.INSTANCE) {
      const bounds: ShapeBounds | undefined = this.selectedInstanceDisplayBounds();
      if (bounds !== undefined) return (bounds.maxX - bounds.minX) * this.zoomPercent / 100;
      // Conservative anchor marker, never a claimed complete geometry bbox.
      const mag: number = this.shape.magnification ?? 1;
      return Math.max(24, 72 * mag);
    }
    const b = this.bounds();
    const pad: number = this.pathPadding();
    return Math.max(8, this.pathStrokeWidth() + 4, Math.round((b.maxX - b.minX) * this.zoomPercent / 100 + pad * 2));
  }

  private shapeHeight(): number {
    if (this.shape.type === ShapeType.TEXT) {
      return 22;
    }
    if (this.shape.type === ShapeType.INSTANCE) {
      const bounds: ShapeBounds | undefined = this.selectedInstanceDisplayBounds();
      if (bounds !== undefined) return (bounds.maxY - bounds.minY) * this.zoomPercent / 100;
      const mag: number = this.shape.magnification ?? 1;
      return Math.max(12, 24 * mag);
    }
    const b = this.bounds();
    const pad: number = this.pathPadding();
    return Math.max(8, this.pathStrokeWidth() + 4, Math.round((b.maxY - b.minY) * this.zoomPercent / 100 + pad * 2));
  }

  private selectedInstanceDisplayBounds(): ShapeBounds | undefined {
    return this.shape.type === ShapeType.INSTANCE && this.selected ? this.instanceSelectionBounds : undefined;
  }

  private bounds(): ShapeBounds {
    return this.selectedInstanceDisplayBounds() ?? getShapeBounds(this.shape);
  }
}

@Component
struct CanvasGrid {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @Prop canvasWidth: number = 800;
  @Prop canvasHeight: number = 600;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop gridSize: number = 10;

  build() {
    Stack() {
      ForEach(this.gridLines(true), (line: GridLinePosition) => {
        Rect()
          .width(line.origin ? 2 : 1)
          .height(this.canvasHeight)
          .fill(this.lineColor(line))
          .position({ x: line.position, y: 0 })
      }, (line: GridLinePosition) => this.gridLineKey(line, true))

      ForEach(this.gridLines(false), (line: GridLinePosition) => {
        Rect()
          .width(this.canvasWidth)
          .height(line.origin ? 2 : 1)
          .fill(this.lineColor(line))
          .position({ x: 0, y: line.position })
      }, (line: GridLinePosition) => this.gridLineKey(line, false))
    }
    .width(this.canvasWidth)
    .height(this.canvasHeight)
    .clip(true)
    .hitTestBehavior(HitTestMode.None)
  }

  private gridLines(vertical: boolean): GridLinePosition[] {
    const lines: GridLinePosition[] = [];
    const length: number = vertical ? this.canvasWidth : this.canvasHeight;
    if (!Number.isFinite(length) || length <= 0 || !Number.isFinite(this.zoomPercent) ||
      this.zoomPercent <= 0 || !Number.isFinite(this.gridSize) || this.gridSize <= 0) {
      return lines;
    }
    const zoom: number = Math.max(0.00001, this.zoomPercent);
    const offset: number = vertical ? this.viewOffsetX : this.viewOffsetY;
    if (!Number.isFinite(offset)) return lines;
    const maxLines: number = 512;
    let worldStep: number = this.visualGridStep(zoom);
    // Keep the same power-of-two grid alignment even for an oversized viewport.
    const viewportSpan: number = Math.max(this.canvasWidth, this.canvasHeight);
    while (worldStep * zoom / 100 < viewportSpan / (maxLines - 4)) worldStep *= 2;
    if (!Number.isFinite(worldStep)) return lines;
    const minWorld: number = vertical ? -offset : offset - length * 100 / zoom;
    const maxWorld: number = vertical ? length * 100 / zoom - offset : offset;
    const firstIndex: number = Math.floor(minWorld / worldStep) - 1;
    const lastIndex: number = Math.ceil(maxWorld / worldStep) + 1;
    if (!Number.isSafeInteger(firstIndex) || !Number.isSafeInteger(lastIndex)) return lines;
    for (let index: number = firstIndex; index <= lastIndex && lines.length < maxLines; index++) {
      const worldPosition: number = index * worldStep;
      const screenPosition: number = vertical
        ? worldToScreenPx(worldPosition, zoom, offset)
        : worldToScreenYpx(worldPosition, zoom, offset);
      lines.push({
        position: screenPosition,
        index: index,
        major: Math.abs(index % GRID_MAJOR_INTERVAL) === 0,
        origin: index === 0,
      });
    }
    return lines;
  }

  private gridLineKey(line: GridLinePosition, vertical: boolean): string {
    // Plain line objects are captured by ForEach's Rect builders. Include the
    // projected position and viewport so a retained world index cannot keep a
    // previous camera's line geometry after pan, zoom, fit or a dock resize.
    return `${vertical ? 'v' : 'h'}_${line.index}_${line.position}_${this.canvasWidth}_${this.canvasHeight}`;
  }

  private visualGridStep(zoom: number): number {
    let worldStep: number = Math.max(0.0001, Math.abs(this.gridSize));
    let screenSpacing: number = worldStep * zoom / 100;
    let guard: number = 0;
    while (screenSpacing < GRID_MIN_SCREEN_SPACING && guard < 48) {
      worldStep *= 2;
      screenSpacing *= 2;
      guard++;
    }
    while (screenSpacing > GRID_MAX_SCREEN_SPACING && guard < 64) {
      worldStep /= 2;
      screenSpacing /= 2;
      guard++;
    }
    return worldStep;
  }

  private lineColor(line: GridLinePosition): string {
    if (line.origin) {
      return withAlpha(COLORS.primary, !this.effectiveIsDark ? 0.45 : 0.62);
    }
    return !this.effectiveIsDark ? (line.major ? 'rgba(15, 23, 42, 0.11)' : 'rgba(15, 23, 42, 0.055)') : (line.major ? 'rgba(148, 163, 184, 0.16)' : 'rgba(148, 163, 184, 0.075)');
  }
}

/**
 * 测量 / 标尺覆盖层（gap-matrix §5「测量 / 标尺」）
 *
 * 唯一观察 MeasureStore 的叶子组件：橡皮筋拖动、标尺放置、测量/标尺模式切换都只重建
 * 本组件，LayoutCanvasView（展开几何 ForEach + GL 子树）不参与重渲染。
 * 端点一律是世界坐标 nm，仅在此处换算屏幕像素与 µm 文本。
 */
@Component
struct MeasureLayer {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @ObjectLink store: MeasureStore;
  @ObjectLink cursorStore: CursorStore;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop canvasWidth: number = 800;
  @Prop canvasHeight: number = 600;
  @Prop desktopMode: boolean = false;
  /** 画布是否处于测量工具：决定模式切换条显隐（标尺线与读数常驻显示） */
  @Prop toolActive: boolean = false;

  build() {
    Stack() {
      // 持久标尺：1px 参考线（切换工具不消失，KLayout rulers 语义）
      ForEach(this.store.rulers, (r: RulerLine) => {
        Rect()
          .width(r.vertical ? 1 : this.canvasWidth)
          .height(r.vertical ? this.canvasHeight : 1)
          .fill(withAlpha(canvasRulerColor(), ALPHA.FOCUS))
          .position({
            x: r.vertical ? this.sx(r.pos) : 0,
            y: r.vertical ? 0 : this.sy(r.pos)
          })
          .hitTestBehavior(HitTestMode.None)
      }, (r: RulerLine) => `line_${r.id}_${r.pos}`)

      // 标尺坐标标签：单独一轮 ForEach（每项单一根组件），与参考线共用同一数据源
      ForEach(this.store.rulers, (r: RulerLine) => {
        Text(umText(r.pos) + (r.vertical ? 'µm X' : 'µm Y'))
          .fontSize(10)
          .fontFamily(FONT_MONO)
          .fontColor(canvasRulerColor())
          .padding({ left: 4, right: 4 })
          .position({
            x: r.vertical ? this.sx(r.pos) + 4 : (this.desktopMode ? 76 : 6),
            y: r.vertical ? 54 : this.sy(r.pos) - 14
          })
          .hitTestBehavior(HitTestMode.None)
      }, (r: RulerLine) => `label_${r.id}_${r.pos}`)

      // 标尺拖拽实时预览（跟随当前磁吸点 liveX / liveY，不再钉死在按下点）
      if (this.store.rulerMode && this.store.pending) {
        Rect()
          .width(this.previewVertical() ? 1.5 : this.canvasWidth)
          .height(this.previewVertical() ? this.canvasHeight : 1.5)
          .fill(canvasRulerColor())
          .position({
            x: this.previewVertical() ? this.sx(this.store.liveX) : 0,
            y: this.previewVertical() ? 0 : this.sy(this.store.liveY)
          })
          .hitTestBehavior(HitTestMode.None)
      }

      // 已锁定的多条持久测量尺寸标注（切换工具不消失，可同时对比多组线宽/间距）
      ForEach(this.store.annotations, (ann: MeasureAnnotation) => {
        Polyline({ width: this.annWidth(ann), height: this.annHeight(ann) })
          .points(this.annPointPairs(ann))
          .fillOpacity(0)
          .stroke(canvasMeasureColor())
          .strokeWidth(1.6)
          .position({ x: this.annLeft(ann), y: this.annTop(ann) })
          .hitTestBehavior(HitTestMode.None)
      }, (ann: MeasureAnnotation) => `ann_seg_${ann.id}`)

      ForEach(this.store.annotations, (ann: MeasureAnnotation) => {
        Circle({ width: 7, height: 7 })
          .fill(canvasMeasureColor())
          .position({ x: this.sx(ann.x1) - 3.5, y: this.sy(ann.y1) - 3.5 })
          .hitTestBehavior(HitTestMode.None)
      }, (ann: MeasureAnnotation) => `ann_p1_${ann.id}`)

      ForEach(this.store.annotations, (ann: MeasureAnnotation) => {
        Circle({ width: 7, height: 7 })
          .fill(canvasMeasureColor())
          .position({ x: this.sx(ann.x2) - 3.5, y: this.sy(ann.y2) - 3.5 })
          .hitTestBehavior(HitTestMode.None)
      }, (ann: MeasureAnnotation) => `ann_p2_${ann.id}`)

      ForEach(this.visibleAnnotations(), (ann: MeasureAnnotation) => {
        Text(this.annText(ann))
          .fontSize(10.5)
          .fontFamily(FONT_MONO)
          .fontColor(canvasMeasureColor())
          .maxLines(1)
          .backgroundColor(isWhiteCanvas() ? withAlpha('#FFFFFF', 0.92) : withAlpha('#0B0E14', 0.82))
          .border({ width: 0.8, color: withAlpha(canvasMeasureColor(), 0.45) })
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .position({ x: this.annLabelX(ann), y: this.annLabelY(ann) })
          .hitTestBehavior(HitTestMode.None)
      }, (ann: MeasureAnnotation) => `ann_lbl_${ann.id}`)

      // 已锁定的区域面积测量框标注
      ForEach(this.store.areaBoxes, (box: MeasureAreaAnnotation) => {
        Rect()
          .width(Math.max(2, Math.abs(this.sx(box.maxX) - this.sx(box.minX))))
          .height(Math.max(2, Math.abs(this.sy(box.maxY) - this.sy(box.minY))))
          .fill(withAlpha(canvasMeasureColor(), 0.10))
          .border({ width: 1.4, color: canvasMeasureColor(), style: BorderStyle.Dashed })
          .position({
            x: Math.min(this.sx(box.minX), this.sx(box.maxX)),
            y: Math.min(this.sy(box.minY), this.sy(box.maxY))
          })
          .hitTestBehavior(HitTestMode.None)
      }, (box: MeasureAreaAnnotation) => `area_box_${box.id}`)

      ForEach(this.store.areaBoxes, (box: MeasureAreaAnnotation) => {
        Text(`${this.store.formatArea((box.maxX - box.minX) * (box.maxY - box.minY))} (${this.store.formatLength(box.maxX - box.minX)}×${this.store.formatLength(box.maxY - box.minY)})`)
          .fontSize(10.5)
          .fontFamily(FONT_MONO)
          .fontColor(canvasMeasureColor())
          .maxLines(1)
          .backgroundColor(isWhiteCanvas() ? withAlpha('#FFFFFF', 0.92) : withAlpha('#0B0E14', 0.84))
          .border({ width: 0.8, color: withAlpha(canvasMeasureColor(), 0.45) })
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .position({
            x: Math.max(this.desktopMode ? 76 : 8, Math.min((this.sx(box.minX) + this.sx(box.maxX)) * 0.5 - 64, this.canvasWidth - 250)),
            y: Math.max(12, Math.min((this.sy(box.minY) + this.sy(box.maxY)) * 0.5 - 12, this.canvasHeight - 62))
          })
          .hitTestBehavior(HitTestMode.None)
      }, (box: MeasureAreaAnnotation) => `area_lbl_${box.id}`)

      // 十字标尺拖拽双线实时预览
      if (this.store.rulerMode && this.store.rulerOrientation === 'crosshair' && this.store.pending) {
        Rect()
          .width(this.canvasWidth).height(1.5).fill(canvasRulerColor())
          .position({ x: 0, y: this.sy(this.store.liveY) })
          .hitTestBehavior(HitTestMode.None)
        Rect()
          .width(1.5).height(this.canvasHeight).fill(canvasRulerColor())
          .position({ x: this.sx(this.store.liveX), y: 0 })
          .hitTestBehavior(HitTestMode.None)
      }

      // 当前正在拖拽的活动橡皮筋（测距线段 或 测面积矩形）
      if (this.store.hasSegment() && !this.store.rulerMode) {
        if (this.store.isAreaMode()) {
          Rect()
            .width(Math.max(2, Math.abs(this.sx(this.store.endX()) - this.sx(this.store.x1))))
            .height(Math.max(2, Math.abs(this.sy(this.store.endY()) - this.sy(this.store.y1))))
            .fill(withAlpha(canvasMeasureColor(), 0.14))
            .border({ width: 1.6, color: canvasMeasureColor(), style: BorderStyle.Dashed })
            .position({
              x: Math.min(this.sx(this.store.x1), this.sx(this.store.endX())),
              y: Math.min(this.sy(this.store.y1), this.sy(this.store.endY()))
            })
            .hitTestBehavior(HitTestMode.None)
        } else {
          Polyline({ width: this.segWidth(), height: this.segHeight() })
            .points(this.segPointPairs())
            .fillOpacity(0)
            .stroke(canvasMeasureColor())
            .strokeWidth(1.8)
            .strokeDashArray([6, 4])
            .position({ x: this.segLeft(), y: this.segTop() })
            .hitTestBehavior(HitTestMode.None)

          Circle({ width: 9, height: 9 })
            .fill(canvasMeasureColor())
            .position({ x: this.sx(this.store.x1) - 4.5, y: this.sy(this.store.y1) - 4.5 })
            .hitTestBehavior(HitTestMode.None)
          Circle({ width: 9, height: 9 })
            .fill(canvasMeasureColor())
            .position({ x: this.sx(this.store.endX()) - 4.5, y: this.sy(this.store.endY()) - 4.5 })
            .hitTestBehavior(HitTestMode.None)
        }
      }

      // 测量 / 测面积 / 持久参考标尺底部浮条
      if (this.toolActive) {
        Scroll() {
          Row({ space: 8 }) {
            Row() {
              StableSegmentButton({
                items: [{ text: '测距尺' }, { text: '测面积' }, { text: '参考线' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
                selectedIndex: this.store.subModeIndex(),
                onItemClicked: (idx: number) => {
                  this.store.setSubModeByIndex(idx);
                  draftCanvasEngine.clearTransientPointerVisuals(true);
                  this.cursorStore.setReadout(idx === 2
                    ? '参考标尺：拖拽磁吸边角，松手落标尺线'
                    : (idx === 1 ? '测面积：对角拉框测量宽×高、面积与周长' : '测距：按住拖拉或单击两点测量距离'));
                },
                fontColor: COLORS.muted,
                selectedFontColor: COLORS.primary,
                capsuleBackgroundColor: COLORS.surfaceMuted,
                selectedBackgroundColor: COLORS.primarySoft,
                fontSizeFp: 11,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 32,
                itemMinHeight: 26,
                itemPaddingHorizontal: 6,
                itemPaddingVertical: 3
              })
            }
            .width(196)

            CanvasModeButton({
              label: `单位:${this.store.unitModeLabel()}`,
              active: this.store.unitMode !== 'um',
              activateAction: () => {
                this.store.cycleUnitMode();
              }
            })

            if (!this.store.rulerMode) {
              if (!this.store.isAreaMode()) {
                Row() {
                  StableSegmentButton({
                    items: [{ text: '自由角' }, { text: '锁90°' }, { text: '锁45°' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
                    selectedIndex: this.store.angleLockIndex(),
                    onItemClicked: (idx: number) => {
                      this.store.setAngleLockByIndex(idx);
                    },
                    fontColor: COLORS.muted,
                    selectedFontColor: COLORS.primary,
                    capsuleBackgroundColor: COLORS.surfaceMuted,
                    selectedBackgroundColor: COLORS.primarySoft,
                    fontSizeFp: 11,
                    capsuleBorderRadius: UI.controlRadius,
                    buttonMinHeight: 32,
                    itemMinHeight: 26,
                    itemPaddingHorizontal: 6,
                    itemPaddingVertical: 3
                  })
                }
                .width(184)
              }

              if (this.store.totalMeasurementCount() > 0 || this.store.pending) {
                CanvasModeButton({
                  label: '撤一条',
                  active: false,
                  activateAction: () => {
                    this.store.undoLastAnnotation();
                    draftCanvasEngine.clearTransientPointerVisuals(true);
                  }
                })
                CanvasModeButton({
                  label: `清空测量 ${this.store.totalMeasurementCount()}`,
                  active: false,
                  danger: true,
                  activateAction: () => {
                    const snapshot: MeasureAnnotation[] = this.store.annotations.slice();
                    const snapshotBoxes: MeasureAreaAnnotation[] = this.store.areaBoxes.slice();
                    const total: number = snapshot.length + snapshotBoxes.length;
                    this.store.clearAnnotations();
                    draftCanvasEngine.clearTransientPointerVisuals(true);
                    this.cursorStore.setReadout('');
                    if (total > 0) {
                      showAppSnackBar(this.getUIContext(), `已清空 ${total} 条测量标注`, {
                        actionText: '撤销',
                        onAction: () => {
                          this.store.restoreAnnotations(snapshot, snapshotBoxes);
                        }
                      });
                    }
                  }
                })
              }
            } else {
              Row() {
                StableSegmentButton({
                  items: [{ text: '自动' }, { text: '水平' }, { text: '竖直' }, { text: '十字' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
                  selectedIndex: this.store.rulerOrientationIndex(),
                  onItemClicked: (idx: number) => {
                    this.store.setRulerOrientationByIndex(idx);
                  },
                  fontColor: COLORS.muted,
                  selectedFontColor: COLORS.primary,
                  capsuleBackgroundColor: COLORS.surfaceMuted,
                  selectedBackgroundColor: COLORS.primarySoft,
                  fontSizeFp: 11,
                  capsuleBorderRadius: UI.controlRadius,
                  buttonMinHeight: 32,
                  itemMinHeight: 26,
                  itemPaddingHorizontal: 6,
                  itemPaddingVertical: 3
                })
              }
              .width(212)

              if (this.store.rulers.length > 0) {
                CanvasModeButton({
                  label: '撤一条',
                  active: false,
                  activateAction: () => {
                    this.store.undoLastRuler();
                  }
                })
                CanvasModeButton({
                  label: `清空参考线 ${this.store.rulers.length}`,
                  active: false,
                  danger: true,
                  activateAction: () => {
                    const snapshotRulers = this.store.rulers.slice();
                    this.store.clearRulers();
                    this.store.reset();
                    this.cursorStore.setReadout('');
                    if (snapshotRulers.length > 0) {
                      showAppSnackBar(this.getUIContext(), `已清空 ${snapshotRulers.length} 条参考标尺`, {
                        actionText: '撤销',
                        onAction: () => {
                          this.store.restoreRulers(snapshotRulers);
                        }
                      });
                    }
                  }
                })
              }
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - 28) })
        .height(44)
        .padding({ left: 10, right: 12 })
        .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
        .transition(panelTransition(TransitionEdge.BOTTOM))
        .zIndex(ZIndexTokens.floatingToolbar)
        .position({ x: 14, y: this.canvasHeight - 52 })
        .hitTestBehavior(HitTestMode.Default)
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .onMouse((event: MouseEvent) => { event.stopPropagation(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
      }
    }
    .width(this.canvasWidth)
    .height(this.canvasHeight)
    .hitTestBehavior(HitTestMode.None)
  }

  private sx(worldX: number): number {
    return worldToScreenPx(worldX, this.zoomPercent, this.viewOffsetX);
  }

  private sy(worldY: number): number {
    return worldToScreenYpx(worldY, this.zoomPercent, this.viewOffsetY);
  }

  /** 预览方向与 LayoutCanvasView.onRulerUp 同一判据（屏幕阈值换算回世界 nm，避免预览与落线不一致） */
  private previewVertical(): boolean {
    if (this.store.rulerOrientation === 'vertical') return true;
    if (this.store.rulerOrientation === 'horizontal') return false;
    const ady: number = Math.abs(this.sy(this.store.liveY) - this.sy(this.store.y1));
    const adx: number = Math.abs(this.sx(this.store.liveX) - this.sx(this.store.x1));
    return ady >= RULER_DRAG_MIN_PX && ady > adx;
  }

  private annLeft(ann: MeasureAnnotation): number {
    return Math.min(this.sx(ann.x1), this.sx(ann.x2)) - MEASURE_LINE_PAD;
  }

  private annTop(ann: MeasureAnnotation): number {
    return Math.min(this.sy(ann.y1), this.sy(ann.y2)) - MEASURE_LINE_PAD;
  }

  private annWidth(ann: MeasureAnnotation): number {
    return Math.max(4, Math.abs(this.sx(ann.x2) - this.sx(ann.x1)) + MEASURE_LINE_PAD * 2);
  }

  private annHeight(ann: MeasureAnnotation): number {
    return Math.max(4, Math.abs(this.sy(ann.y2) - this.sy(ann.y1)) + MEASURE_LINE_PAD * 2);
  }

  private annPointPairs(ann: MeasureAnnotation): Array<Array<number>> {
    const left: number = this.annLeft(ann);
    const top: number = this.annTop(ann);
    return [
      [this.sx(ann.x1) - left, this.sy(ann.y1) - top],
      [this.sx(ann.x2) - left, this.sy(ann.y2) - top],
    ];
  }

  private annText(ann: MeasureAnnotation): string {
    const dx: number = ann.x2 - ann.x1;
    const dy: number = ann.y2 - ann.y1;
    const d: number = Math.hypot(dx, dy);
    if (Math.abs(dx) < 1e-6 || Math.abs(dy) < 1e-6) {
      return this.store.formatLength(d);
    }
    return `${this.store.formatLength(d)} (Δx ${umText(dx)}, Δy ${umText(dy)})`;
  }

  private visibleAnnotations(): MeasureAnnotation[] {
    const margin: number = 24;
    return this.store.annotations.filter((ann: MeasureAnnotation): boolean => {
      const x1: number = this.sx(ann.x1);
      const y1: number = this.sy(ann.y1);
      const x2: number = this.sx(ann.x2);
      const y2: number = this.sy(ann.y2);
      const minX: number = Math.min(x1, x2);
      const maxX: number = Math.max(x1, x2);
      const minY: number = Math.min(y1, y2);
      const maxY: number = Math.max(y1, y2);
      return maxX >= -margin && minX <= this.canvasWidth + margin &&
        maxY >= -margin && minY <= this.canvasHeight + margin;
    });
  }

  private annLabelX(ann: MeasureAnnotation): number {
    const minLeft: number = this.desktopMode ? 76 : 8;
    const mid: number = (this.sx(ann.x1) + this.sx(ann.x2)) * 0.5 + 6;
    return Math.max(minLeft, Math.min(mid, Math.max(minLeft, this.canvasWidth - 220)));
  }

  private annLabelY(ann: MeasureAnnotation): number {
    const xPos: number = this.annLabelX(ann);
    const minTop: number = xPos < 260 ? 54 : 8;
    const mid: number = (this.sy(ann.y1) + this.sy(ann.y2)) * 0.5 - 24;
    return Math.max(minTop, Math.min(mid, Math.max(minTop, this.canvasHeight - 58)));
  }

  /** 未锁定终点（橡皮筋拖动中）画虚线，已锁定画实线 */
  private dashPattern(): Array<number> {
    return this.store.hasEnd ? [] : [6, 4];
  }

  private segLeft(): number {
    return Math.min(this.sx(this.store.x1), this.sx(this.store.endX())) - MEASURE_LINE_PAD;
  }

  private segTop(): number {
    return Math.min(this.sy(this.store.y1), this.sy(this.store.endY())) - MEASURE_LINE_PAD;
  }

  private segWidth(): number {
    return Math.abs(this.sx(this.store.endX()) - this.sx(this.store.x1)) + MEASURE_LINE_PAD * 2;
  }

  private segHeight(): number {
    return Math.abs(this.sy(this.store.endY()) - this.sy(this.store.y1)) + MEASURE_LINE_PAD * 2;
  }

  /** Polyline 顶点为组件内局部坐标，故需按包围盒平移（与多边形预览同一套路） */
  private segPointPairs(): Array<Array<number>> {
    const left: number = this.segLeft();
    const top: number = this.segTop();
    return [
      [this.sx(this.store.x1) - left, this.sy(this.store.y1) - top],
      [this.sx(this.store.endX()) - left, this.sy(this.store.endY()) - top],
    ];
  }

  /** 读数标签：置于线段中点上方，避开桌面左侧工具轨与左上角状态胶囊 */
  private labelX(): number {
    const minLeft: number = this.desktopMode ? 76 : 8;
    const mid: number = (this.sx(this.store.x1) + this.sx(this.store.endX())) / 2 + 8;
    return Math.max(minLeft, Math.min(mid, Math.max(minLeft, this.canvasWidth - MEASURE_LABEL_W)));
  }

  private labelY(): number {
    const xPos: number = this.labelX();
    const minTop: number = xPos < 260 ? 54 : 8;
    const mid: number = (this.sy(this.store.y1) + this.sy(this.store.endY())) / 2 - 30;
    return Math.max(minTop, Math.min(mid, Math.max(minTop, this.canvasHeight - 40)));
  }
}

/**
 * 顶点编辑覆盖层（gap-matrix §6）
 *
 * 叶子组件：@ObjectLink 观察 VertexStore ⇒ 拖顶点期间只有本组件重绘，
 * 画布主体（展开几何 ForEach / GL 子树）不重建。手势仍由画布 onTouch 统一接管，
 * 本层的图形元素全部 HitTestMode.None，只有模式条按钮吃点击。
 */
@Component
struct VertexLayer {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @ObjectLink store: VertexStore;
  @Prop zoomPercent: number = 100;
  @Prop viewOffsetX: number = 0;
  @Prop viewOffsetY: number = 0;
  @Prop canvasWidth: number = 800;
  @Prop canvasHeight: number = 600;
  @Prop selectActive: boolean = false;
  @Prop hasTarget: boolean = false;
  @Prop desktopMode: boolean = false;
  @Prop selectionCount: number = 0;
  @Prop canRoundSelected: boolean = false;
  @Prop canContinuePath: boolean = false;
  @Prop canEnterInstance: boolean = false;
  @Prop canFlattenInstance: boolean = false;
  @Prop layers: UiLayer[] = [];

  onContinuePath: () => void = () => {};
  onEnterInstance: () => void = () => {};
  onFlattenInstance: () => void = () => {};
  onDuplicate: () => void = () => {};
  onRotate90: () => void = () => {};
  onMirrorH: () => void = () => {};
  onMirrorV: () => void = () => {};
  onRoundCorners: () => void = () => {};
  onOpenArrayCopy: () => void = () => {};
  onAlignQuick: (mode: string) => void = (_m: string) => {};
  onBooleanQuick: (op: 'merge' | 'subtract') => void = (_op: 'merge' | 'subtract') => {};
  onChangeLayer: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};
  onDelete: () => void = () => {};

  @Builder
  private changeLayerMenu() {
    Menu() {
      ForEach(this.layers.slice(0, 24), (layer: UiLayer) => {
        MenuItem({
          content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}`,
          symbolStartIcon: menuIcon('layout')
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .enabled(layer.locked !== true)
          .onClick(() => {
            this.onChangeLayer(layer.layerNumber, layer.datatype);
          })
      }, (layer: UiLayer) => `chg_${layer.layerNumber}_${layer.datatype}`)
    }
    .attributeModifier(menuStyle(
      this.layers.slice(0, 24).map((layer: UiLayer): MenuItemOptions => ({
        content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}`,
        symbolStartIcon: menuIcon('layout')
      })),
      this.getUIContext()
    ))
  }

  build() {
    Stack() {
      if (this.selectActive && (this.hasTarget || this.selectionCount > 0)) {
        Scroll() {
          Row({ space: 6 }) {
            if (this.hasTarget) {
              CanvasModeButton({
                label: this.store.isRect ? '拉伸控点' : '顶点',
                active: this.store.active,
                activateAction: () => {
                  const nextActive: boolean = !this.store.active;
                  this.store.active = nextActive;
                  this.store.explicitlyPinned = nextActive;
                  this.store.setHint('');
                }
              })
              if (this.store.active && !this.store.isRect) {
                CanvasModeButton({
                  label: '锁正交',
                  active: this.store.orthoLock,
                  activateAction: () => {
                    this.store.orthoLock = !this.store.orthoLock;
                    this.store.setHint(this.store.orthoLock ? '顶点移动已锁定水平/竖直轴向' : '');
                  }
                })
                CanvasModeButton({
                  label: '删顶点',
                  active: this.store.deleteMode,
                  danger: true,
                  activateAction: () => {
                    this.store.deleteMode = !this.store.deleteMode;
                    this.store.setHint('');
                  }
                })
              }
              if (this.canContinuePath) {
                CanvasModeButton({
                  label: '续画路径',
                  active: false,
                  activateAction: () => {
                    this.onContinuePath();
                  }
                })
              }
              Row().width(1).height(18).backgroundColor(canvasOverlayBorder()).margin({ left: 4, right: 2 })
            } else if (this.selectionCount > 1) {
              Text(`已选 ${this.selectionCount}`)
                .fontSize(11)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.primary)
                .fontWeight(FontWeight.Bold)
                .margin({ left: 4, right: 2 })
            }

            if (this.selectionCount > 0) {
              if (this.canEnterInstance) {
                CanvasModeButton({ label: '进入 Cell', active: true, activateAction: () => { this.onEnterInstance(); } })
              }
              if (this.canFlattenInstance) {
                CanvasModeButton({ label: '展开实例', active: false, activateAction: () => { this.onFlattenInstance(); } })
              }
              CanvasModeButton({ label: '复制+1', active: false, activateAction: () => { this.onDuplicate(); } })
              CanvasModeButton({ label: '旋90°', active: false, activateAction: () => { this.onRotate90(); } })
              CanvasModeButton({ label: '镜像H', active: false, activateAction: () => { this.onMirrorH(); } })
              CanvasModeButton({ label: '镜像V', active: false, activateAction: () => { this.onMirrorV(); } })
              if (this.canRoundSelected) {
                CanvasModeButton({ label: '圆角…', active: false, activateAction: () => { this.onRoundCorners(); } })
              }
              if (this.selectionCount >= 2) {
                CanvasModeButton({ label: '左齐', active: false, activateAction: () => { this.onAlignQuick('left'); } })
                CanvasModeButton({ label: '居中', active: false, activateAction: () => { this.onAlignQuick('centerH'); } })
                CanvasModeButton({ label: '合并', active: false, activateAction: () => { this.onBooleanQuick('merge'); } })
                CanvasModeButton({ label: '相减', active: false, activateAction: () => { this.onBooleanQuick('subtract'); } })
              }
              CanvasModeButton({ label: '阵列…', active: false, activateAction: () => { this.onOpenArrayCopy(); } })

              Button('改层', { type: ButtonType.Normal })
                .fontSize(UI.fontBody)
                .fontColor(canvasOverlayInk())
                .height(UI.compactControlHeight)
                .padding({ left: 10, right: 10 })
                .backgroundColor(canvasOverlayInactive())
                .border({ width: 1, color: canvasOverlayBorder() })
                .borderRadius(UI.controlRadius)
                .focusable(false)
                .attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .bindMenu(
                  this.changeLayerMenu,
                  buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius)
                )

              CanvasModeButton({ label: '删除', active: false, danger: true, activateAction: () => { this.onDelete(); } })
            }

            if (this.store.active && this.store.hint.length > 0) {
              Text(this.store.hint)
                .fontSize(11)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.primary)
                .margin({ left: 6 })
            }
          }
          .alignItems(VerticalAlign.Center)
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .constraintSize({ maxWidth: Math.max(220, this.canvasWidth - (this.desktopMode ? 86 : 28)) })
        .height(42)
        .padding({ left: 8, right: 10 })
        .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
        .transition(panelTransition(TransitionEdge.BOTTOM))
        .zIndex(ZIndexTokens.floatingToolbar)
        .position({ x: this.desktopMode ? 72 : 14, y: this.canvasHeight - VERTEX_STRIP_HEIGHT - 4 })
        .hitTestBehavior(HitTestMode.Default)
        .onTouch((event: TouchEvent) => { event.stopPropagation(); })
        .onMouse((event: MouseEvent) => { event.stopPropagation(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
      }

      if (this.store.active && this.selectActive && this.store.shapeId >= 0) {
        if (this.store.dragIndex >= 0 && this.store.displayPoints().length >= 2) {
          Polygon({ width: this.liveW(), height: this.liveH() })
            .points(this.livePointPairs())
            .fill(withAlpha(canvasVertexColor(), ALPHA.SELECTED))
            .stroke(canvasVertexColor())
            .strokeWidth(1.5)
            .position({ x: this.liveLeft(), y: this.liveTop() })
            .hitTestBehavior(HitTestMode.None)
        }

        // 矩形显示四边单向拉伸条形柄；多边形/路径显示边中点插入圆柄
        if (this.store.dragIndex < 0 && !this.store.deleteMode) {
          ForEach(this.store.edgeHandles, (pt: Point, idx: number) => {
            if (this.store.isRect) {
              Rect()
                .width(idx % 2 === 0 ? 16 : 7)
                .height(idx % 2 === 0 ? 7 : 16)
                .borderRadius(3)
                .fill(COLORS.primary)
                .stroke('#FFFFFF')
                .strokeWidth(1.2)
                .position({
                  x: this.sx(pt.x) - (idx % 2 === 0 ? 8 : 3.5),
                  y: this.sy(pt.y) - (idx % 2 === 0 ? 3.5 : 8)
                })
                .hitTestBehavior(HitTestMode.None)
            } else {
              Circle({ width: VERTEX_INSERT_PX, height: VERTEX_INSERT_PX })
                .fill(isWhiteCanvas() ? COLORS.surface : withAlpha('#FFFFFF', 0.85))
                .stroke(canvasVertexColor())
                .strokeWidth(1.2)
                .position({
                  x: this.sx(pt.x) - VERTEX_INSERT_PX / 2,
                  y: this.sy(pt.y) - VERTEX_INSERT_PX / 2
                })
                .hitTestBehavior(HitTestMode.None)
            }
          }, (pt: Point, idx: number) => `e${idx}_${pt.x}_${pt.y}`)
        }

        // 顶点/四角句柄
        ForEach(this.store.displayPoints(), (pt: Point, idx: number) => {
          Rect()
            .width(VERTEX_HANDLE_PX)
            .height(VERTEX_HANDLE_PX)
            .borderRadius(2)
            .fill(idx === this.store.dragIndex && this.store.gestureKind === 1 ? '#FFFFFF' : canvasVertexColor())
            .stroke('#0B0E14')
            .strokeWidth(1.2)
            .position({
              x: this.sx(pt.x) - VERTEX_HANDLE_PX / 2,
              y: this.sy(pt.y) - VERTEX_HANDLE_PX / 2
            })
            .hitTestBehavior(HitTestMode.None)
        }, (pt: Point, idx: number) => `v${idx}_${pt.x}_${pt.y}`)
      }
    }
    .width(this.canvasWidth)
    .height(this.canvasHeight)
    .hitTestBehavior(HitTestMode.None)
  }

  private sx(worldX: number): number {
    return worldToScreenPx(worldX, this.zoomPercent, this.viewOffsetX);
  }

  private sy(worldY: number): number {
    return worldToScreenYpx(worldY, this.zoomPercent, this.viewOffsetY);
  }

  private box(): VertexBox {
    const pts: Point[] = this.store.displayPoints();
    let minX: number = 0;
    let minY: number = 0;
    let maxX: number = 0;
    let maxY: number = 0;
    for (let i = 0; i < pts.length; i++) {
      const px: number = this.sx(pts[i].x);
      const py: number = this.sy(pts[i].y);
      if (i === 0) {
        minX = px;
        minY = py;
        maxX = px;
        maxY = py;
        continue;
      }
      minX = Math.min(minX, px);
      minY = Math.min(minY, py);
      maxX = Math.max(maxX, px);
      maxY = Math.max(maxY, py);
    }
    const out: VertexBox = {
      left: minX - MEASURE_LINE_PAD,
      top: minY - MEASURE_LINE_PAD,
      w: maxX - minX + MEASURE_LINE_PAD * 2,
      h: maxY - minY + MEASURE_LINE_PAD * 2,
    };
    return out;
  }

  private liveLeft(): number {
    return this.box().left;
  }

  private liveTop(): number {
    return this.box().top;
  }

  private liveW(): number {
    return this.box().w;
  }

  private liveH(): number {
    return this.box().h;
  }

  private livePointPairs(): Array<Array<number>> {
    const b: VertexBox = this.box();
    const pts: Point[] = this.store.displayPoints();
    const out: Array<Array<number>> = [];
    for (let i = 0; i < pts.length; i++) {
      out.push([this.sx(pts[i].x) - b.left, this.sy(pts[i].y) - b.top]);
    }
    return out;
  }
}

interface VertexBox {
  left: number;
  top: number;
  w: number;
  h: number;
}

@Component
struct CanvasModeButton {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @Prop label: string = '';
  @Prop active: boolean = false;
  @Prop danger: boolean = false;
  activateAction: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .fontSize(UI.fontBody)
      .fontColor(this.danger ? COLORS.danger : (this.active ? COLORS.primary : canvasOverlayInk()))
      .fontWeight(this.active ? FontWeight.Bold : FontWeight.Normal)
      .height(UI.compactControlHeight)
      .padding({ left: 9, right: 9 })
      .backgroundColor(this.danger ? COLORS.dangerSoft : (this.active ? COLORS.primarySoft : canvasOverlayInactive()))
      .border({ width: 1, color: this.active ? (this.danger ? COLORS.danger : COLORS.primary) : canvasOverlayBorder() })
      .borderRadius(UI.controlRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .focusable(false)
      .accessibilityText(this.label).bindTips(this.label).hoverEffect(HoverEffect.Highlight)
      .onClick(() => {
        this.activateAction();
      })
  }
}

@Component
struct CanvasHud {
  @StorageProp('effectiveIsDark') private effectiveIsDark: boolean = false;
  @Prop toolLabel: string = '';
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop selectedLayerColor: string = '#3B82F6';
  @Prop selectedLayerLocked: boolean = false;
  @Prop layers: UiLayer[] = [];
  @Prop desktopMode: boolean = false;
  @Prop zoomPercent: number = 100;
  @ObjectLink cursorStore: CursorStore;
  onSelectLayer: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};
  onUnlockAndShowLayer: (layerNumber: number, datatype: number) => void = (_l: number, _d: number) => {};

  @Builder
  private activeLayerMenu() {
    Menu() {
      if (this.selectedLayerLocked) {
        MenuItem({
          content: `解锁并显示当前层 L${this.selectedLayerNumber}/D${this.selectedDatatype}`,
          symbolStartIcon: menuIcon('eye')
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => {
            this.onUnlockAndShowLayer(this.selectedLayerNumber, this.selectedDatatype);
          })
      }
      ForEach(this.layers.slice(0, 24), (layer: UiLayer) => {
        MenuItem({
          content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}` +
            (layer.locked === true ? ' (锁)' : '') + (!layer.visible ? ' (隐)' : ''),
          symbolStartIcon: menuIcon('layout'),
          symbolEndIcon: menuCheckIcon(layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype)
        })
          .attributeModifier(MENU_ITEM_STYLE)
          .selected(layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype)
          .onClick(() => {
            this.onSelectLayer(layer.layerNumber, layer.datatype);
          })
      }, (layer: UiLayer) => `hud_lyr_${layer.layerNumber}_${layer.datatype}`)
    }
    .attributeModifier(menuStyle(
      this.layers.slice(0, 24).map((layer: UiLayer): MenuItemOptions => ({
        content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName || layer.englishName}`,
        symbolStartIcon: menuIcon('layout'),
        symbolEndIcon: menuCheckIcon(layer.layerNumber === this.selectedLayerNumber && layer.datatype === this.selectedDatatype)
      })),
      this.getUIContext()
    ))
  }

  build() {
    Row({ space: 10 }) {
      Text(this.toolLabel)
        .fontSize(11)
        .fontColor(COLORS.primary)
        .fontWeight(FontWeight.Bold)
        .fontFamily(FONT_MONO)

      Button({ type: ButtonType.Normal }) {
        Row({ space: 5 }) {
          Rect()
            .width(9)
            .height(9)
            .borderRadius(2)
            .fill(this.selectedLayerColor)
          Text(`L${this.selectedLayerNumber}/D${this.selectedDatatype}` + (this.selectedLayerLocked ? ' 锁/隐' : ' ▾'))
            .fontSize(11)
            .fontColor(this.selectedLayerLocked ? COLORS.danger : (!this.effectiveIsDark ? '#111827' : '#FFFFFF'))
            .fontFamily(FONT_MONO)
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(24)
      .padding({ left: 7, right: 7 })
      .backgroundColor(this.selectedLayerLocked ? COLORS.dangerSoft : canvasOverlayInactive())
      .borderRadius(UI.chipRadius)
      .attributeModifier(hongTuThemeState.luminousPointLightModifier())
      .focusable(false)
      .accessibilityText(`当前绘图图层 L${this.selectedLayerNumber} D${this.selectedDatatype}，点击快速切换图层`)
      .bindMenu(
        this.activeLayerMenu,
        buildLuminousMenuOptions(undefined, hongTuThemeState.luminous, hongTuThemeState.resolveLuminousRenderMode(), UI.panelRadius)
      )

      if (!this.desktopMode) {
        Text(formatZoomPercent(this.zoomPercent))
          .fontSize(11)
          .fontColor(canvasOverlaySubtle())
          .fontFamily(FONT_MONO)
        Text(`${umText(this.cursorStore.x)}, ${umText(this.cursorStore.y)} µm`)
          .fontSize(11)
          .fontColor(canvasOverlaySubtle())
          .fontFamily(FONT_MONO)
      }
      if (this.cursorStore.layerNumber >= 0) {
        Text(`L${this.cursorStore.layerNumber}/D${this.cursorStore.datatype} #${this.cursorStore.shapeId}`)
          .fontSize(11)
          .fontColor(canvasOverlayMuted())
          .fontFamily(FONT_MONO)
      }
    }
    .height(32)
    .padding({ left: 10, right: 10 })
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'regular', hongTuThemeState.elevation('md')))
    .position({ x: this.desktopMode ? 72 : 14, y: 12 })
    .zIndex(ZIndexTokens.canvasHud + 1)
    .onTouch((event: TouchEvent) => { event.stopPropagation(); })
    .onMouse((event: MouseEvent) => { event.stopPropagation(); })
  }
}
