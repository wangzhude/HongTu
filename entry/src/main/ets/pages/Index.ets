import { SheetGlassHeader } from '../components/SheetGlassHeader';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { EditorToolbar } from '../components/workbench/EditorToolbar';
import { DrawingToolbar } from '../components/workbench/DrawingToolbar';
import { WorkbenchIcon } from '../components/workbench/WorkbenchIcon';
import { CanvasViewToolbar } from '../components/workbench/CanvasViewToolbar';
import { CellTreeNode } from '../components/workbench/CellTreePanel';
import { common } from '@kit.AbilityKit';
import { fileIo as cardFileIo } from '@kit.CoreFileKit';
import { FormUpdater, FormDrcSummary, buildFormSnapshot } from '../services/FormUpdateService';
import {
  classifyHongTuUri,
  HONGTU_ALLOWED_DROP_TYPES,
  DroppedHongTuAsset,
  KnockSharePayload,
  systemCollaborationService
} from '../services/SystemCollaborationService';
import { CursorStore, MeasureStore, VertexStore } from '../common/UiStores';
import { CanvasFocusReturnFrame } from '../common/CanvasFocusReturnFrame';
import type { LayoutPropRecord } from '../../cpp/types/libhongtu/Index';
import { LayoutPort, LayoutCrossSection, LayoutContextRecord, LayoutPortDraft, PortEndpoint, ResolvedPort,
  newLayoutIdentity, remapCellSemantics, mergeLayoutSemantics, reconcileGeneratedPorts, portFromDraft, markCellLineage, appendCellSemantics } from '../models/LayoutPort';
import { portService, PortRequest, PortResult, PortPreview, resolveLayoutPort } from '../services/PortService';
import { PortManagerDialog } from '../components/dialogs/PortManagerDialog';
import { PortConnectDialog } from '../components/dialogs/PortConnectDialog';
import { PortRouteDialog } from '../components/dialogs/PortRouteDialog';
import { routeSessionService, RouteSessionContext, RouteSessionRequest, RouteSessionPreview, RouteSessionResult } from '../services/RouteSessionService';
import { PortUiChoice } from '../components/dialogs/PortGeometryPanel';
import { PortChoiceQuery } from '../models/PortUiChoice';
import { collectPortChoices } from '../services/PortChoiceService';
import { contextRecordBytes } from '../services/LayoutPortInteropCodec';
import { LayoutCanvasView, ViolationHighlight } from '../components/workbench/LayoutCanvasView';
import {
  AiAssistantPanel,
  FileOpenPanel,
  LayerStylePanel,
  MacroPanel,
  ShortcutPanel,
} from '../components/workbench/WorkbenchOverlays';
import { WorkbenchInspector, DrcRulesPopover } from '../components/workbench/WorkbenchInspector';
import { ShapePropertiesPopover } from '../components/workbench/ShapePropertiesPopover';
import { DrcResultsDock } from '../components/workbench/DrcResultsDock';
import { HdsTabs, HdsTabsController, DividerMode } from '@kit.UIDesignKit';
import { hongTuThemeState, Radius, ThemeMode, ThemeState, ZIndexTokens } from '../store/ThemeStore';
import { resolveHdsSystemMaterialEffect } from '../store/LuminousMaterial';
import {
  buildLuminousContextMenuOptions,
  buildLuminousMenuOptions,
  buildLuminousSheetOptions
} from '../store/LuminousSurfaceOptions';
import {
  RESPONSIVE_COMPACT_SQUARE_KEY,
  RESPONSIVE_IS_FLOATING_WINDOW_KEY,
  SAFE_AREA_BOTTOM_VP_KEY,
  SAFE_AREA_TOP_VP_KEY
} from '../store/ResponsiveStore';
import { HONGTU_BACKGROUND_FLUSH_KEY } from '../entryability/EntryAbility';
import { AppearanceSettingsSheet } from '../components/AppearanceSettingsSheet';
import { AppToastDuration, showAppSnackBar, showAppToast } from '../components/AppSnackBar';
import { ACTIVE_LAYOUT_STAGE_GEOMETRY_ID, DataWorkspace } from '../components/workbench/DataWorkspace';
import { AiCommandPreview, buildAiCommandPreview, AiPreviewBox } from '../components/workbench/AiCommandPreview';
import { AgentCanvasAuraOverlay, AgentLiveStatusHud } from '../components/workbench/AgentCanvasStageOverlay';
import { PythonLayoutPanel } from '../components/workbench/PythonLayoutPanel';
import { LayoutComparePanel } from '../components/workbench/LayoutComparePanel';
import { ViewWorkspacePanel } from '../components/workbench/ViewWorkspacePanel';
import { RdbReviewPanel } from '../components/workbench/RdbReviewPanel';
import { RdbMarkerOverlay } from '../components/workbench/RdbMarkerOverlay';
import { describeRdbMarkerImage, planRdbMarkerGeometry } from '../services/RdbMarkerGeometryService';
import { RdbReviewService } from '../services/RdbReviewService';
import { RdbReviewWorkspaceService, defaultRdbReviewWorkspaceLimits } from '../services/RdbReviewWorkspaceService';
import { rdbReviewTransferService } from '../services/RdbReviewTransferService';
import { rdbMergeService } from '../services/RdbMergeService';
import type { RdbMergeInput, RdbMergePlan, RdbMergeSummary, RdbMergeRow, RdbMergeOptions } from '../models/RdbMerge';
import type { RdbReviewTransferPlan, RdbReviewTransferRow, RdbReviewTransferSummary, RdbReviewTransferOptions } from '../models/RdbReviewTransfer';
import type { RdbReviewWorkspaceRecovery, RdbReviewWorkspaceLegacyRecovery,
  RdbReviewWorkspaceReport, RdbReviewWorkspaceSaveTicket, RdbReviewWorkspaceSourceBinding } from '../models/RdbReviewWorkspace';
import { IntegratedReviewWorkspaceService, IntegratedReviewRdbStorage } from '../services/IntegratedReviewWorkspaceService';
import { rdbWaiverFileService } from '../services/RdbWaiverFileService';
import type { RdbWaiverContext, RdbWaiverCellBinding, RdbWaiverUiRequest, RdbWaiverCaptureRequest, RdbWaiverFileRequest } from '../models/RdbWaiver';
import { rdbFileService, RdbPickedReport } from '../services/RdbFileService';
import { emptyRdbReviewUiState, RdbReviewUiState, RdbReviewCategoryChoice, RdbReviewCellChoice,
  RdbReviewTagChoice, RdbReviewLayoutCell, RdbTransferUiRequest, RdbTransferUiPreview,
  RdbTransferUiRow, RdbTransferUiChanges, RdbMergeUiRequest, RdbMergeUiSource, RdbMergeUiPreview } from '../models/RdbReviewUi';
import type { RdbReviewFilter, RdbReviewPatch, RdbReviewLayoutMapping, RdbReviewLocationPlan,
  RdbReviewSaveTicket, RdbReviewRow, RdbReviewRecovery } from '../models/RdbReview';
import { ViewWorkspaceService, viewCameraFromCanvas, viewCameraToCanvas } from '../services/ViewWorkspaceService';
import type { ViewRecord, ViewBookmark, ViewPresentation, ViewPlacementRef, ViewLayerVisibility,
  ViewDatabaseSource, ViewDatabaseSnapshot, ViewRuntime, ViewResolvedLocation, ViewCanvasCamera,
  ViewOverlayState, ViewRenderResolution, ViewRenderSource, ViewWorkspaceState } from '../models/ViewWorkspace';
import type { ViewSceneSource } from '../models/ViewRenderScene';
import type { ViewOverlayDocumentChoice, ViewOverlayCellChoice, ViewOverlayDiagnostic } from '../models/ViewOverlayUi';
import { LayoutCompareOverlay } from '../components/workbench/LayoutCompareOverlay';
import { TechnologyPanel } from '../components/workbench/TechnologyPanel';
import { LayerStackPanel, LayerStackBuildOptions } from '../components/workbench/LayerStackPanel';
import { PhysicalLayerStack, parsePhysicalLayerStack } from '../models/PhysicalLayerStack';
import { layerStackService, LayerStackResult } from '../services/LayerStackService';
import { VerificationPanel } from '../components/workbench/VerificationPanel';
import { pythonBridgeService, PythonInputMode, PythonDocumentInput, PythonLayoutArtifact, PythonViolation, PythonVerificationResult, PythonOperationHandle, PythonCancellationResult, PythonParameter } from '../services/PythonBridgeService';
import { layoutCompareService, LayoutCompareRun } from '../services/LayoutCompareService';
import { layerStackExportService } from '../services/LayerStackExportService';
import { pythonWorkspaceService, PythonWorkspaceBundle, PythonEditorDraft, PythonTemplate } from '../services/PythonWorkspaceService';
import { aiHarnessService, AiHarnessResult, HarnessToolState, HarnessContextUsage } from '../services/AiHarnessService';
import { dshLayoutAgentService, DshLayoutBackendHost, DshCmosInverterParams, DshEditOperation, DshToolExecutionOutcome, DshAgentRunResult, DshAskUserPromptParams } from '../services/DshLayoutAgentService';
import { aiAttachmentService, AiChatAttachment, AiClipboardPasteResult } from '../services/AiAttachmentService';
import type { DshWebSearchItem } from '../services/DshWebSearchService';
import type { DshPermissionMode } from '../components/dsh/DshDesign';
import { publishAiLiveStream, resetAiLiveStream, splitInlineThinking } from '../services/AiAgentPresentation';
import type { AiAskUserExchange, AiAskUserOption, AiAskUserRequest, AiProcessStep } from '../services/AiService';
import { WorkspaceTabs } from '../components/workbench/WorkspaceTabs';
import { ProjectPanel, ProjectRecoveryEntry } from '../components/workbench/ProjectPanel';
import { fileRecoveryService } from '../services/FileRecoveryService';
import { engineeringProjectService, EngineeringProjectBundle, EngineeringDependency, EngineeringProjectSnapshot, EngineeringRestorePayload, EngineeringEnvironment, EngineeringPythonBundle } from '../services/EngineeringProjectService';
import { engineeringReviewBundleService } from '../services/EngineeringReviewBundleService';
import { EngineeringReviewRestoreService } from '../services/EngineeringReviewRestoreService';
import { EngineeringReviewRestorePanel, EngineeringRestoreSourceChoice } from '../components/workbench/EngineeringReviewRestorePanel';
import type { EngineeringReviewBundle, EngineeringReviewRuntime, EngineeringReviewRuntimeState,
  EngineeringReviewRestoreState, EngineeringReviewRestorePreview, EngineeringDocumentMapping, EngineeringReviewSource } from '../models/EngineeringReviewBundle';
import { parseRuleSetText } from '../common/drcRuleText';
import type { DrcRule } from '../common/drcRulesets';
import { ComponentLibraryPanel } from '../components/workbench/ComponentLibraryPanel';
import { PCellEditDialog } from '../components/dialogs/PCellEditDialog';
import { componentLibraryService, ComponentLibraryEntry, PCellProcessIdentity } from '../services/ComponentLibraryService';
import { technologyService, TechnologyDevicePlacement } from '../services/TechnologyService';
import { parseTechnologyPackage, TechnologyPackage } from '../common/technologyPackage';
import { ShapeSearchPanel } from '../components/workbench/ShapeSearchPanel';
import { CommandSearchDialog } from '../components/dialogs/CommandSearchDialog';
import { BooleanPreviewDialog } from '../components/dialogs/BooleanPreviewDialog';
import { LayerExpressionDialog } from '../components/dialogs/LayerExpressionDialog';
import { layerExpressionService, LayerExpressionOptions, LayerExpressionPreview, LayerExpressionResult } from '../services/LayerExpressionService';
import { NativeLayerRegionAdapter } from '../services/NativeLayerRegionAdapter';
import { HierarchyClipDialog } from '../components/dialogs/HierarchyClipDialog';
import { HierarchyClipOptions } from '../services/HierarchyClipService';
import { hierarchyClipSessionService, HierarchyClipPreview, HierarchyClipSessionResult, createRegionHierarchyClipAdapter } from '../services/HierarchyClipSessionService';
import { ImportMergeDialog } from '../components/dialogs/ImportMergeDialog';
import { HierarchyFillDialog } from '../components/dialogs/HierarchyFillDialog';
import { hierarchyFillService, HierarchyFillOptions, HierarchyFillFootprintResult } from '../services/HierarchyFillService';
import { hierarchyFillSessionService, HierarchyFillPreview, HierarchyFillSessionResult } from '../services/HierarchyFillSessionService';
import { CellMaintenanceDialog } from '../components/dialogs/CellMaintenanceDialog';
import { cellMaintenanceService, CellMaintenanceRequest, CellMaintenancePreview, CellMaintenanceResult, CellOriginOffset, readCellOriginOffset } from '../services/CellMaintenanceService';
import { importMergeFileService, ImportMergeFileService, ImportMergeFileSelection, ImportMergeFileResult } from '../services/ImportMergeFileService';
import { ImportMergeOptions, ImportMergePreview, ImportMergeResult, ImportMergeSource } from '../services/ImportMergeService';
import { PrecisionSettings, QuantizationReport, quantizationReport, validatePrecision, GEOMETRY_SNAP_KINDS, cleanDbuNm, cleanMetricNumber, legacyDocumentPrecision } from '../services/PrecisionService';
import { RoutingMode, routingConstraintService } from '../services/RoutingConstraintService';
import { DraftControlStore, DraftGhostOutline, DraftStampTemplate, draftCanvasEngine } from '../store/DraftOverlayStore';
import { PCellPlacementOptions } from '../services/CurveDrawingService';
import type { InstancePathStep } from '../services/EditService';
import type { HierarchyHitCandidate, HierarchyCandidatesResult } from '../services/HierarchyExpandService';
import { WorkbenchCommand } from '../services/CommandSearchService';
import { booleanPreviewService, BooleanPreview, BooleanPreviewOptions, BooleanPreviewResult, PreviewBooleanOp } from '../services/BooleanPreviewService';
import { flattenPreviewService } from '../services/FlattenPreviewService';
import { workspaceService, MAX_WORKSPACE_TABS, WorkspaceDocument, WorkspaceTab, WorkspaceHistory, PCellVariant, WorkspaceLocalProcessState, WorkspacePreparedDraft } from '../services/WorkspaceService';
import { EditSessionState, EditStructureState } from '../services/EditService';
import { PropertyCellOption, DecodedPCellProperty, decodePCellProperty } from '../services/ShapePropertyService';
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { WorkbenchSidebar } from '../components/workbench/WorkbenchSidebar';
import { WorkbenchStatusBar } from '../components/workbench/StatusBar';
import { WorkbenchTitleBar } from '../components/workbench/WorkbenchTitleBar';
import { DesktopModuleRail } from '../components/workbench/DesktopModuleRail';
import { PlaceInstanceDialog, CellInfo } from '../components/dialogs/PlaceInstanceDialog';
import { OpenWizardDialog } from '../components/dialogs/OpenWizardDialog';
import { CellNameDialog } from '../components/dialogs/CellNameDialog';
import { PresetSaveDialog } from '../components/dialogs/PresetSaveDialog';
import { ArrayCopyDialog } from '../components/dialogs/ArrayCopyDialog';
import { SizeOffsetDialog } from '../components/dialogs/SizeOffsetDialog';
import { PlacePCellDialog } from '../components/dialogs/PlacePCellDialog';
import {
  cloneLayerWithVisible,
  createDrcIssues,
  createInitialLayers,
  createRecentFiles,
  createToolEntries,
} from '../workbench/WorkbenchData';
import {
  ActiveTool,
  DrcIssue,
  RecentFile,
  ToolEntry,
  WorkModule,
} from '../workbench/WorkbenchModels';
import { Shape, ShapeType, Point, ShapeBounds, nativeShapesToShapes, nativeResultToShapesAsync, packShapesCoordinates, getShapeBounds } from '../models/GdsiiData';
import { UiLayer, LayerGroup, DrawTool, ViewMode } from '../common/types';
import { NativeStatus, nativeHongTuService } from '../services/NativeHongTuService';
import type { GdsiiResult, GdsiiWriteResult, ExportLayerStyle, NativeNet, NativeLvsResult, NativeViaLayer, NativeLayoutCompareLayer, NativeLayoutCompareResult, SourceLayerDefinition, QuantizationReport as NativeQuantizationReport, NativeRenderSnapshot, NativeRenderShape, NativeImportEstimate, NativeEmbeddedPythonInfo } from '../../cpp/types/libhongtu/Index';
import { fileImportService, ImportedLayoutResult, PickedLayout, layoutFileTypeForPath } from '../services/FileImportService';
import {
  lypService,
  parseLyp,
  formatLyp,
  lypExportWarnings,
  entriesFromUiLayers,
  mergeLypIntoLayers,
  lypSelfCheck,
  LypFileContent,
  LypMergeResult,
  LypParseResult,
} from '../services/LypService';
import { editService } from '../services/EditService';
import { drcService, DrcViolation, DrcConfiguration, DrcResult } from '../services/DrcService';
import { rdbService, rdbCellQName, rdbIdentityTransform } from '../services/RdbService';
import type { RdbViolation, RdbViolationReport, RdbReadResult, RdbWriteResult, RdbDocument,
  RdbCategory, RdbCell, RdbTagRef, RdbFramePath, RdbFrameResult, RdbItem, RdbTransform } from '../models/RdbData';
import { engineeringFileService } from '../services/EngineeringFileService';
import { shortcutService, ShortcutAction } from '../services/ShortcutService';
import { aiService, AiContext, AiSelectedShape, AiCellInfo, AiIssueInfo, AiNetInfo, ParsedCommand, ChatMessage, ChatRole, AiCommandType, AiProvider, AiChatToolState, AiConversationSummary, AiContextOptions, AiModelConfig, AiAgentTask } from '../services/AiService';
import { buildAiContextBudget, estimateAiTokens, aiHistoryMessages, AiBudgetMessage, AiCompressionNotBeneficialError } from '../services/AiContextBudget';
import type { AiTaskCheckpoint } from '../services/AiService';
import { queryAiWorkbench, AiEditorQuery, AiEditorReply } from '../services/AiWorkbenchQuery';
import { AiNativeCall, AiNativeResult, AiNativeData, aiNativeTool, aiNativeTools, parseAiNativeCall, validateAiNativeBatch, aiNativeResult, aiNativeData } from '../services/AiNativeTools';
import { runAiNativeGeometry, selectAiNativeTargets, AiGeometryContext } from '../services/AiNativeGeometry';
import type { AiLayerInfo, CommandParams } from '../services/AiService';
import type { NativeLayoutCompareOptions } from '../../cpp/types/libhongtu/Index';
import { groupAiEdits, acceptedAiEdits, AiReviewGroup } from '../services/AiReviewGroups';
import { aiExecutor, AiCommandExecutor, CommandResult, ViewAction } from '../services/AiCommandParser';
import { macroService, Macro, MacroResult, MacroStep, MacroServiceState } from '../services/MacroService';
import { advEditService, AlignType, DistributeType, CornerRoundPreview } from '../services/AdvancedEditService';
import { verifyService, Net, LvsNetReport, DEFAULT_VIA_LAYERS } from '../services/VerifyService';
import { viewService, NavigatorData } from '../services/ViewService';
import { layoutExportService, LayoutExportResult, ChildCellExport, ExportLayoutInput, ImageExportCancelledError } from '../services/LayoutExportService';
import { expandCellShapes, summarizeCellShapes, summarizeCellDisplayShapes, HierarchySummary, HierarchyDisplaySummary, HierarchyReferenceBoundsResolver, instanceTransformMat, Mat2D } from '../services/HierarchyExpandService';
import { summarizeCellPorts, PortBoundsResult } from '../services/PortBoundsService';
import { COLORS, formatFileSize, formatZoomPercent, LARGE_FILE_THRESHOLD_BYTES, HUGE_FILE_THRESHOLD_BYTES, MIN_ZOOM_PERCENT, MAX_ZOOM_PERCENT, screenToWorldPx, screenToWorldYpx, worldToScreenPx, worldToScreenYpx } from '../common/constants';
import { ThemeManager } from '../common/Theme';
import { UI } from '../common/UiTokens';
import { menuIcon, menuSubmenuArrow, MENU_ITEM_STYLE, MENU_DANGER_ITEM_STYLE, menuStyle, menuCheckIcon } from '../common/WorkbenchMenuStyle';
import { PanelHeading } from '../components/workbench/PanelHeading';
import { defaultLayoutLayer, hasSky130DisplaySignature } from '../services/LayoutDisplayDefaults';
import { BREAKPOINT_MD, BreakpointManager, DeviceType, LayoutConfig, breakpointManager } from '../common/BreakpointManager';
import { setShiftHeld, setCtrlHeld, setAltHeld, isShiftHeld, isCtrlHeld } from '../common/ModifierKeys';
import { canvasKeyName } from '../common/CanvasKeyboard';
import { componentSnapshot, promptAction, window, display } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { Elevation, SHADOW_BY_ELEVATION, BLUR_BY_LAYER } from '../common/MaterialTokens';
import {
  dialogTransition,
  feedbackCurve,
  fullscreenTransitionDuration,
  hierarchyTransition,
  motionDuration,
  MOTION,
  MotionSettings,
  panelTransition,
  REDUCE_MOTION_KEY
} from '../common/Motion';
import { boundedPanelWidth, workbenchPanelPlacement } from '../common/WorkbenchLayout';
import {
  AiAssistantStore,
  connectAiAssistantStore,
  connectDocumentDomainStore,
  connectPanelLayoutStore,
  connectVerificationDomainStore,
  connectViewportSelectionStore,
  DocumentDomainStore,
  PanelLayoutStore,
  VerificationDomainStore,
  ViewportSelectionStore
} from '../store/WorkbenchDomainStore';
import {
  cloneCellContextRecordMatrix,
  cloneContextRecordArray,
  cloneCrossSectionArray,
  cloneEditStructureModel,
  clonePortArray,
  clonePortEndpointModel,
  cloneShapeModel,
  cloneStructured,
  cloneUiLayerArray,
  cloneUiLayerModel,
  incrementalSnapshotEngine,
  unwrapObserved
} from '../common/CloneUtils';

interface LayerExpressionFocusOwner {
  ticket: number;
  generation: number;
  documentId: string;
  module: WorkModule;
  cellId: number;
  viewMode: ViewMode;
  context: string;
}

/** AI 上下文所需的简化图层信息（满足 ArkTS 严格模式对命名 interface 的要求） */
interface EngineeringRuleSnapshot { name: string; rules: DrcRule[]; }
interface EngineeringMacroSnapshot { macros: Macro[]; }
interface WorkspaceAutomaticEngineeringOrigin {
  toolsBaseline: string; reviewBaseline: string; localPythonBaseline: string;
  sessionOwnedBefore: boolean; bundle?: EngineeringProjectBundle; bundleJson: string;
  firstPublishedCreatedAt?: number;
}
interface IntegratedEngineeringCheckpoint {
  python: PythonWorkspaceBundle; macros: MacroServiceState; technology: string; deck: string; drc: DrcConfiguration;
  layers: UiLayer[]; currentTechnologyId: string; documentTechnologyJson: string;
  localPythonDraft?: PythonEditorDraft; localPythonDraftDirty: boolean; toolsRestored: boolean;
  views: ViewWorkspaceService; sources: Map<string, ViewDatabaseSource>;
  rdbStorage: IntegratedReviewRdbStorage; reports: RdbReviewWorkspaceService; rdbCore: RdbReviewService; rdbUri: string;
  mappings: RdbReviewLayoutMapping[]; mapping: RdbReviewLayoutMapping | null;
  rdbBaseline?: string; rdbTarget: string; rdbTargetSet: boolean; rdbPathIndex: number;
  markerItem: RdbItem | null; markerFrame: RdbTransform; markerDocumentId: string; markerRevision: number;
  markerCellId: number; markerCellKey: string; markerReportToken: string;
  owned: boolean;
}

interface DshLayoutLayerSummary {
  layer: number;
  datatype: number;
  chineseName: string;
  name: string;
  visible: boolean;
  locked?: boolean;
  elementCount?: number;
}

interface DshAttachmentBriefItem {
  id: string;
  name: string;
  kind: string;
  mimeType: string;
  sizeBytes: number;
  summary: string;
}

interface DshEmbeddedPythonBrief {
  available: boolean;
  tier: string;
  version: string;
  executionMode: string;
}

interface DshLayoutActiveLayer {
  layer: number;
  datatype: number;
}

interface DshWorkbenchWindow {
  widthVp: number;
  heightVp: number;
  deviceType: string;
  desktopMode: boolean;
  themeMode: ThemeMode;
  isDark: boolean;
}

interface DshWorkbenchCamera {
  zoomPercent: number;
  viewOffsetX: number;
  viewOffsetY: number;
  hierarchyDepth: number;
  viewportWorldBoundsNm: ShapeBounds;
}

interface DshWorkbenchGrid {
  gridVisible: boolean;
  gridSizeNm: number;
  snapEnabled: boolean;
  geometrySnapEnabled: boolean;
  smartGuidesEnabled: boolean;
  routingMode: RoutingMode;
}

interface DshWorkbenchPanels {
  sidebarVisible: boolean;
  inspectorVisible: boolean;
  drcDockOpen: boolean;
  aiPanel: boolean;
  pythonPanel: boolean;
  verificationPanel: boolean;
  lvsPanel: boolean;
  macroPanel: boolean;
  libraryPanel: boolean;
  technologyPanel: boolean;
  layerStackPanel: boolean;
  comparePanel: boolean;
  rdbReviewPanel: boolean;
  searchPanel: boolean;
  projectPanel: boolean;
  viewWorkspacePanel: boolean;
}

interface DshWorkbenchSnapshot {
  window: DshWorkbenchWindow;
  currentModule: WorkModule;
  viewMode: string;
  activeTool: ActiveTool;
  activeLayer: DshLayoutActiveLayer;
  camera: DshWorkbenchCamera;
  gridAndSnap: DshWorkbenchGrid;
  panels: DshWorkbenchPanels;
  rulersCount: number;
  embeddedPython: NativeEmbeddedPythonInfo;
  pythonExecutionMode: string;
  statusText: string;
}

interface DshLayoutCellSummary {
  id: number;
  name: string;
}

interface DshDrcViolationSummary {
  id: number;
  ruleType: string;
  severity: string;
  message: string;
  x: number;
  y: number;
}

interface CanvasNavigationViewport {
  width: number;
  height: number;
  centerX: number;
  centerY: number;
  toolbarReserved: boolean;
}

interface RecentFileRecord {
  name: string;
  fileSizeLabel: string;
  fileType: string;
  sourceUri: string;
  sandboxPath: string;
  openedAt: number;
}

const RECENT_FILES_STORAGE_KEY: string = 'hongtuRecentFiles';
const MAX_RECENT_FILES: number = 8;
const CANVAS_FIT_PADDING: number = 60;

/** LVS 空结果（status=not-run）：让 @State 保持非空，面板可无条件读字段 */
function emptyLvsResult(): NativeLvsResult {
  const r: NativeLvsResult = {
    matched: false,
    ran: false,
    status: 'not-run',
    error: '',
    layoutNetCount: 0,
    schematicNetCount: 0,
    matchedNets: 0,
    shortNets: [],
    openNets: [],
    extraNets: [],
    messages: [],
  };
  return r;
}

/**
 * UiLayer 的线型是字符串（.lyp 口径），native/导出侧是枚举码。
 * 未设置时返回 undefined：让 native 保留图层原值，而不是把它判成 solid。
 */
function lineStyleCode(style: string | undefined): number | undefined {
  if (style === 'dashed') {
    return 1;
  }
  if (style === 'dotted') {
    return 2;
  }
  if (style === 'dotdash') {
    return 3;
  }
  if (style === 'solid') {
    return 0;
  }
  return undefined;
}

/** UI fill tokens -> image-export pattern; absent/unknown keeps native defaults. */
function fillPatternCode(style: string | undefined): number | undefined {
  if (style === 'solid') return 0;
  if (style === 'outline' || style === 'hollow') return 1;
  if (style === 'diagonal') return 2;
  if (style === 'cross') return 3;
  return undefined;
}

interface PCellPreparedDefinition { shapes: Shape[]; ports: LayoutPortDraft[]; }

@CustomDialog
struct ExportCompletionDialog {
  controller: CustomDialogController;
  @Prop format: string = 'PNG';
  @Prop fileName: string = '';
  @Prop fileUri: string = '';
  onCopyUri: (uri: string) => void = () => {};
  onShareFile: (uri: string, fileName: string) => void = () => {};
  onSaveGallerySuccess: () => void = () => {};
  onSaveGalleryError: (msg: string) => void = () => {};

  private async savePngToSystemGallery(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const helper = photoAccessHelper.getPhotoAccessHelper(context);
      const assetUri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, 'png');
      const srcFile = cardFileIo.openSync(this.fileUri, cardFileIo.OpenMode.READ_ONLY);
      try {
        const stat = cardFileIo.statSync(srcFile.fd);
        const buf: ArrayBuffer = new ArrayBuffer(Math.max(1, stat.size));
        const readLen: number = cardFileIo.readSync(srcFile.fd, buf);
        const dstFile = await cardFileIo.open(assetUri, cardFileIo.OpenMode.READ_WRITE | cardFileIo.OpenMode.CREATE);
        try {
          await cardFileIo.write(dstFile.fd, buf.slice(0, readLen));
        } finally {
          await cardFileIo.close(dstFile.fd);
        }
      } finally {
        cardFileIo.closeSync(srcFile.fd);
      }
      this.onSaveGallerySuccess();
      this.controller.close();
    } catch (err) {
      this.onSaveGalleryError(err instanceof Error ? err.message : String(err));
    }
  }

  build() {
    Column({ space: 14 }) {
      Text('导出完成')
        .fontSize(UI.titleSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(COLORS.ink)
        .width('100%')

      Text(`已导出 ${this.format}：${this.fileName}`)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .width('100%')

      Text(this.fileUri)
        .fontSize(UI.fontCaption)
        .fontFamily('monospace')
        .fontColor(COLORS.muted)
        .copyOption(CopyOptions.LocalDevice)
        .padding(10)
        .width('100%')
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)

      if (this.format === 'PNG') {
        Row({ space: 10 }) {
          Text('快捷转存至系统相册')
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.muted)
            .layoutWeight(1)
          // 严守官方规范：SaveButton 不挂载通用属性修饰器，保持高对比实色背景与字色
          Row() {
            SaveButton({
              icon: SaveIconStyle.FULL_FILLED,
              text: SaveDescription.SAVE_TO_GALLERY,
              buttonType: ButtonType.Capsule
            })
              .fontSize(13)
              .fontColor(Color.White)
              .iconColor(Color.White)
              .backgroundColor(COLORS.primary)
              .padding({ top: 8, bottom: 8, left: 14, right: 14 })
              .onClick((_event: ClickEvent, result: SaveButtonOnClickResult) => {
                if (result === SaveButtonOnClickResult.SUCCESS) {
                  this.savePngToSystemGallery();
                } else {
                  this.onSaveGalleryError('未授予临时图库写入授权');
                }
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }

      Row({ space: 10 }) {
        Button('复制位置', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .layoutWeight(1)
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            this.onCopyUri(this.fileUri);
          })
        Button('系统分享', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .layoutWeight(1)
          .fontSize(UI.fontBody)
          .fontColor(Color.White)
          .backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => {
            const uri: string = this.fileUri;
            const name: string = this.fileName;
            this.controller.close();
            this.onShareFile(uri, name);
          })
        Button('关闭', { type: ButtonType.Normal })
          .height(UI.controlHeight)
          .padding({ left: 16, right: 16 })
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.controller.close())
      }
      .width('100%')
      .padding({ top: 12 })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(460)
    .constraintSize({ maxWidth: '94%' })
    .padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface)
    .borderRadius(UI.dialogRadius)
  }
}


interface ModuleTabLabelParams {
  module: WorkModule;
  label: string;
  icon: string;
  activeModule: WorkModule;
}

interface ParsedPendingCardCommand {
  command: string;
  documentId: string;
}

interface ParsedPendingExternalUri {
  uri: string;
}

@Entry
@Component
struct Index {
  @StorageProp(REDUCE_MOTION_KEY) reduceMotion: boolean = false;
  /** @ObservedV2 五大领域状态仓库（按 API 19+ 混用规范以无装饰器常规只读成员挂载，属性级精准刷新） */
  private readonly docStore: DocumentDomainStore = connectDocumentDomainStore();
  private readonly viewportStore: ViewportSelectionStore = connectViewportSelectionStore();
  private readonly verifyStore: VerificationDomainStore = connectVerificationDomainStore();
  private readonly panelStore: PanelLayoutStore = connectPanelLayoutStore();
  private readonly aiStore: AiAssistantStore = connectAiAssistantStore();
  /** 当前视图模式（查看 / 编辑），对应 KLayout viewer/editor 模式分离 */
  private canvasViewportMeasured: boolean = false;
  private cachedDisplayLayersKey: string = '';
  private cachedDisplayLayers: UiLayer[] = [];
  private cachedVisibleLayerKey: string = '';
  private cachedVisibleLayerNums: number[] = [];
  private cachedRenderCellNamesKey: string = '';
  private cachedRenderCellNames: string[] = [];
  private pendingAskUserResolve: ((exchange: AiAskUserExchange) => void) | null = null;
  /** S-1: 光标世界坐标（nm）— @Observed CursorStore 隔离高频更新。
   *  必须为 @State 才能下传给子组件 @ObjectLink（CanvasHud/StatusBar 属性级观察），
   *  光标移动仅刷新观察方，不触发 Index 整树重渲染。 */
  @State cursorStore: CursorStore = new CursorStore();
  /** 测量/标尺状态（gap-matrix §5）：同 CursorStore 套路——页面 @State 持有，
   *  画布与其叶子组件属性级观察，端点拖动不重建画布整树。 */
  @State measureStore: MeasureStore = new MeasureStore();
  /** 库级 / 结构级（Cell）GDS 属性：随解析进来、随保存出去。
   *  缺这两级，dirty 保存仍会静默丢掉库与 Cell 上的 PROPATTR/PROPVALUE。 */
  private docLibProperties: LayoutPropRecord[] = [];
  private docCellProperties: LayoutPropRecord[][] = [[]];
  private docCellKeys: string[] = [newLayoutIdentity()];
  private docPorts: LayoutPort[] = [];
  private docCrossSections: LayoutCrossSection[] = [];
  private docLayoutContextRecords: LayoutContextRecord[] = [];
  private docCellContextRecords: LayoutContextRecord[][] = [[]];
  private pickedPortEndpoint: PortEndpoint | undefined = undefined;
  /** 顶点编辑状态（gap-matrix §6）：同 measureStore 套路——页面 @State 持有，
   *  画布与其叶子 VertexLayer 属性级观察；拖顶点的指针级写入不重建画布整树。 */
  @State vertexStore: VertexStore = new VertexStore();
  /** 草稿控制条状态（V1 @Observed + @ObjectLink 叶子观察，零根树高频重排） */
  @State draftControlStore: DraftControlStore = new DraftControlStore();
  /** E-TX: 方向键松开后的合并定时器句柄（-1 = 无待关闭定时器） */
  private nudgeTxTimer: number = -1;
  private nudgeTxActive: boolean = false;
  private nudgeKeyHeld: boolean = false;
  private canvasFocusReturnTicket: number = 0;
  private layerExpressionFocusOwner: LayerExpressionFocusOwner | undefined = undefined;
  private layerExpressionFocusClosingOwner: LayerExpressionFocusOwner | undefined = undefined;
  private layerExpressionFocusClosingCount: number = 0;
  /** AI-10: 聊天消息列表（从 aiService.getChatHistory 刷新） */
  private aiContextCacheKey: string = '';
  private aiContextCacheLabel: string = '';
  /** AI-11: 加载状态指示 */
  private aiNativeOperation: PythonOperationHandle | null = null;
  private aiNativeCancellation: Promise<PythonCancellationResult> | null = null;
  private aiNativeCompare: LayoutCompareRun | null = null;
  private aiNativeComparePath: string = '';
  private aiNativeImport: ImportMergeFileService = new ImportMergeFileService();
  private aiNativeImportSelection: ImportMergeFileSelection | undefined = undefined;
  private aiRequestGeneration: number = 0;
  private aiOperationTicket: number = 0;
  private aiStreamFlushTimer: number = -1;
  private aiStreamBufferedText: string = '';
  private aiStreamBufferedReasoning: string = '';
  private aiStreamBufferedSteps: AiProcessStep[] = [];
  private aiStreamBufferedAnswer: string = '';
  private aiPythonPhase: string = '';
  private aiGeneratedFitAction: (() => void) | null = null;
  private aiGeneratedFitTimer: number = -1;
  private aiGeneratedFitFallbackTimer: number = -1;
  /** AI-11: 错误信息 */
  /** AI-15: 流式增量文本（onChunk 累加，onComplete/onError 清空） */
  private aiUndoMarker: Object | null = null;
  private pendingAiWorkflow: string = '';
  private pendingAiRunId: string = '';
  private pendingAiAllCommands: ParsedCommand[] = [];
  private pendingAiPrompt: string = '';
  private pendingAiReply: string = '';
  private pendingAiRevision: number = -1;
  private pendingAiDocumentId: string = '';
  private pendingAiSelection: string = '';
  private pendingAiCell: number = -1;
  private pendingAiLayer: number = -1;
  private pendingAiDatatype: number = 0;
  private analysisContext: string = '';
  private mnemonicContext: string = '';
  private netSnapshotRevision: number = -1;
  private drcSnapshotRevision: number = -1;
  private drcRdbResult: DrcResult | null = null;
  private drcRdbDocument: string = '';
  private drcRdbInputVersion: number = -1;
  private drcRdbOwnerCell: number = -1;
  private drcRdbCellName: string = '';
  private saveInProgress: boolean = false;
  private workspaceCloseConfirming: boolean = false;
  private openDialogKeys: Set<string> = new Set<string>();
  private snapshotSerial: number = 0;
  private viewWorkspaceCore: ViewWorkspaceService | null = null;
  private viewWorkspaceInitialized: boolean = false;
  private viewWorkspaceDocumentId: string = '';
  private viewWorkspaceSources: Map<string, ViewDatabaseSource> = new Map<string, ViewDatabaseSource>();
  private viewWorkspaceFileTicket: number = 0;
  private viewWorkspaceCheckpointVersions: Map<string, number> = new Map<string, number>();
  private viewWorkspaceShapeIdentities: Map<string, Shape[]> = new Map<string, Shape[]>();
  private viewWorkspaceIdentityVersions: Map<string, number> = new Map<string, number>();
  private rdbReviewCore: RdbReviewService = new RdbReviewService();
  private rdbReviewWorkspace: RdbReviewWorkspaceService = new RdbReviewWorkspaceService();
  private rdbTransferPlan: RdbReviewTransferPlan | null = null;
  private rdbTransferRequest: RdbTransferUiRequest | null = null;
  private rdbTransferPreviewId: string = '';
  private rdbTransferConfirmationId: string = '';
  private rdbTransferPageIndex: number = 0;
  private rdbTransferPageSize: number = 20;
  private rdbMergePlan: RdbMergePlan | null = null;
  private rdbMergeRequest: RdbMergeUiRequest | null = null;
  private rdbMergeSources: RdbReviewWorkspaceSourceBinding[] = [];
  private rdbMergePreviewId: string = '';
  private rdbMergeConfirmationId: string = '';
  private rdbReportCloseConfirmationId: string = '';
  private rdbReportReloadConfirmationId: string = '';
  private rdbMergePageIndex: number = 0;
  private rdbMergePageSize: number = 20;
  private integratedReviewWorkspace: IntegratedReviewWorkspaceService = new IntegratedReviewWorkspaceService();
  private rdbReviewStorage = this.integratedReviewWorkspace.rdb();
  private rdbReviewLayoutMappings: RdbReviewLayoutMapping[] = [];
  private rdbWaiverPage: number = 0;
  private rdbWaiverConfirmationId: string = '';
  private engineeringRestoreCore: EngineeringReviewRestoreService | null = null;
  private engineeringRestoreProject: EngineeringProjectBundle | undefined = undefined;
  private engineeringRestoreMappings: EngineeringDocumentMapping[] = [];
  private engineeringRestoreBlocked: boolean = false;
  private rdbReviewInitialized: boolean = false;
  private rdbReviewBaseline: string | undefined = undefined;
  private rdbReviewUri: string = '';
  private rdbReviewFileTicket: number = 0;
  private rdbReviewDraftDirty: boolean = false;
  private rdbReviewMapping: RdbReviewLayoutMapping | null = null;
  private rdbReviewTarget: string = '';
  private rdbReviewTargetSet: boolean = false;
  private rdbReviewPathIndex: number = -1;
  private rdbMarkerDocumentId: string = '';
  private rdbMarkerLayoutRevision: number = -1;
  private rdbMarkerCellId: number = -1;
  private rdbMarkerCellKey: string = '';
  private rdbMarkerReportToken: string = '';
  /** 宏录制中（驱动 MacroPanel 录制/停止按钮态） */
  /** 网络追踪结果（traceNets 后填充，供面板/状态栏展示） */
  // ===== LVS 连通性预检查（native lvs_engine，非签核）=====
  /** LVS 面板可见 */
  /** SPICE/CDL 参考网表文本（LVS 的另一侧输入） */
  /** 是否已有 LVS 结果（用布尔位而非可空对象，避免 ArkTS 窄化问题） */
  /** 最近一次 LVS 结果（未运行时为 not-run 空结果） */
  /** 最近一次逐网判定（面板列表数据源） */
  /** 面板内提示文本（未运行原因 / 导出结果） */
  /** 最近一次 native 提取的网络（供点击行高亮成员，不驱动渲染） */
  private lvsNativeNets: NativeNet[] = [];
  /** 大版图打开向导：quickScan 后若文件超过阈值则弹出，让用户选择查看/编辑模式并提示内存影响 */
  private pendingWizardResolve: ((mode: ViewMode) => void) | null = null;
  @State shapes: Shape[] = [];
  private pcellEditCellId: number = -1;
  private pcellEditDocumentId: string = '';
  private pcellEditRevision: number = -1;
  private pcellEditContextCellId: number = -1;
  private instanceDialogContext: string = '';
  private arrayDialogContext: string = '';
  private sizeDialogContext: string = '';
  private pcellDialogContext: string = '';
  private pcellEditParams: Record<string, number | string | boolean> = {};
  private pcellEditController: CustomDialogController = new CustomDialogController({
    builder: PCellEditDialog({
      pcellName: this.docStore.pcellEditName,
      initialParams: this.pcellEditParams,
      applyAction: (params: Record<string, number | string | boolean>): string => this.regenerateSelectedPCell(params)
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('pcellEdit'),
    onDidDisappear: (): void => this.onModalDialogClosed('pcellEdit')
  });
  private workspaceDocuments: Map<string, WorkspaceDocument> = new Map<string, WorkspaceDocument>();
  private workspaceSessions: Map<string, EditSessionState> = new Map<string, EditSessionState>();
  private presetSaveContext: string = '';
  private presetSaveController: CustomDialogController = new CustomDialogController({
    builder: PresetSaveDialog({ onConfirm: (name: string): boolean => {
      if (this.presetSaveContext !== this.parameterDialogContext()) {
        this.panelStore.statusText = '版图已变化，请重新保存视图预设';
        return false;
      }
      const saved: boolean = viewService.saveLayerPreset(name);
      this.panelStore.statusText = saved ? `已保存视图预设：${name}` : viewService.getLayerPresetError();
      if (saved) this.docStore.layerPresetNames = viewService.listLayerPresets();
      return saved;
    }, errorProvider: (): string => this.panelStore.statusText }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('presetSave'),
    onDidDisappear: (): void => this.onModalDialogClosed('presetSave')
  });
  private autosaveTimer: number = -1;
  private workspaceViewTimer: number = -1;
  private workspaceViewKey: string = '';
  private exitDraftKey: string = '';
  private currentSaveUri: string = '';
  private currentProjectUri: string = '';
  private currentTechnologyId: string = '';
  private pcellVariants: PCellVariant[] = [];
  private sourceLayerDefinitions: SourceLayerDefinition[] = [];
  private engineeringBundle?: EngineeringProjectBundle;
  private workspaceToolBaselineId: string = '';
  private workspaceToolBaseline: string = '';
  private automaticEngineeringOrigins: Map<string, WorkspaceAutomaticEngineeringOrigin> = new Map<string, WorkspaceAutomaticEngineeringOrigin>();
  private engineeringToolsRestored: boolean = false;
  private documentTechnologyJson: string = '';
  private localProcessOwned: boolean = false;
  private localPythonDraft?: PythonEditorDraft;
  private localPythonDraftDirty: boolean = false;
  /** 当前打开的文件路径（用于 quickScan 等需要文件路径的操作；空字符串表示尚未加载文件） */
  /** 当前文档元信息（DataInspector 展示用） */
  /** GDS UNITS：用户单位 / 物理单位（米），导入时同步，导出写回 */
  /** M2：文档未保存修改（镜像 editService.isDirty） */
  /** 原生 g_layout 同步标志已纳入 this.docStore.nativeSnapshotCurrent（@Trace）统一门控 */
  /** 原始沙箱文件是否仍可代表当前文档；保存编辑后 native 快照可能已更新，但源文件不会更新。 */
  private originalSourceCurrent: boolean = false;
  /** 最近一次 DRC 耗时（ms），Inspector 展示用 */
  /** 当前高亮的 DRC 违规 id（点击跳转后高亮，重新检查时清空） */
  /** violation 高亮矩形（传给 LayoutCanvasView 渲染闪烁框；null 则不绘制） */
  /** 当前文档可放置的 Cell 列表；空白版图下为空，加载真实文件后由解析结果填充。 */
  private placeableCells: CellInfo[] = [{ id: 0, name: 'TOP' }];
  /** 实例放置弹窗控制器（@CustomDialog 由控制器驱动 open/close，取代原 visible 状态） */
  private pendingStampCellId: number = -1;
  private preferredInstanceTargetId: number = -1;
  private pendingStampPCellName: string = '';
  private pendingStampPCellParams: Record<string, number | string | boolean> = {};
  private pendingStampPCellOptions: PCellPlacementOptions | undefined = undefined;
  private pendingStampPCellDevice: string = '';
  private cachedStampOutlines: DraftGhostOutline[] = [];
  private cachedStampPorts: Point[] = [];
  private cachedStampKey: string = '';

  private placeInstanceController: CustomDialogController = new CustomDialogController({
    builder: PlaceInstanceDialog({
      cells: this.placeableCells,
      cellsProvider: (): CellInfo[] => this.placeableInstanceCells(),
      initialCellIdProvider: (): number => this.resolveInitialInstanceCellId(),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      isCompact: this.isCompact(),
      cellSpanProvider: (cellId: number): Point | null => this.computeCellBoundingSpan(cellId),
      viewportCenterProvider: (): Point => this.currentViewportWorldCenter(),
      contextProvider: (): string => this.parameterDialogContext(),
      onConfirm: (cellId: number, x: number, y: number, rotation: number, mirror: number,
        arrayCols?: number, arrayRows?: number, pitchX?: number, pitchY?: number) => {
        return this.placeInstance(cellId, x, y, rotation, mirror, arrayCols ?? 1, arrayRows ?? 1, pitchX ?? 0, pitchY ?? 0);
      },
      onStartInteractiveStamp: (cellId: number, rotation: number, mirror: number): boolean => {
        return this.startCellStampSession(cellId, rotation, mirror);
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('placeInstance'),
    onDidDisappear: (): void => this.onModalDialogClosed('placeInstance')
  });

  /** 大版图打开向导弹窗控制器（@CustomDialog 由控制器驱动 open/close，取代原 showOpenWizard 状态） */
  private openWizardController: CustomDialogController = new CustomDialogController({
    builder: OpenWizardDialog({
      fileName: this.docStore.wizardFileName,
      fileSize: this.docStore.wizardFileSize,
      storedShapes: this.docStore.wizardStoredShapes,
      coordinateCount: this.docStore.wizardCoordinateCount,
      expandedPlacements: this.docStore.wizardExpandedPlacements,
      geometryBytes: this.docStore.wizardGeometryBytes,
      budgetMessage: this.docStore.wizardBudgetMessage,
      isCompact: this.isCompact(),
      onSelect: (mode: ViewMode) => {
        this.resolveWizard(mode);
      }
    }),
    cancel: () => this.cancelImportWizard(),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('openWizard'),
    onDidDisappear: (): void => this.onModalDialogClosed('openWizard')
  });

  /** Cell 命名弹窗状态（新建 / 重命名共用一个弹窗） */
  private cellNameDialogMode: string = 'new';
  private cellNameDialogTargetId: number = -1;
  private cellNameDialogDocumentId: string = '';
  private cellNameDialogRevision: number = -1;
  private cellNameController: CustomDialogController = new CustomDialogController({
    builder: CellNameDialog({
      title: this.panelStore.cellNameDialogTitle,
      initialName: this.panelStore.cellNameDialogInitial,
      contextProvider: (): string => `${this.parameterDialogContext()}:${this.cellNameDialogMode}:${this.cellNameDialogTargetId}`,
      onConfirm: (name: string): boolean => this.onCellNameConfirmed(name)
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('cellName'),
    onDidDisappear: (): void => this.onModalDialogClosed('cellName')
  });

  /** 阵列复制弹窗（KLayout: Make Array） */
  private arrayCopyController: CustomDialogController = new CustomDialogController({
    builder: ArrayCopyDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      onConfirm: (rows: number, cols: number, pitchX: number, pitchY: number) => {
        return this.applyArrayCopy(rows, cols, pitchX, pitchY);
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('arrayCopy'),
    onDidDisappear: (): void => this.onModalDialogClosed('arrayCopy')
  });

  /** 尺寸调整弹窗（KLayout: Size Shapes） */
  private sizeOffsetController: CustomDialogController = new CustomDialogController({
    builder: SizeOffsetDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      onConfirm: (offset: number) => {
        return this.applySizeOffset(offset);
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('sizeOffset'),
    onDidDisappear: (): void => this.onModalDialogClosed('sizeOffset')
  });

  private roundCornersController: CustomDialogController = new CustomDialogController({
    builder: SizeOffsetDialog({ title: '倒圆角', fieldLabel: '圆角半径 (nm)', positiveOnly: true,
      hint: '对单个矩形或多边形生成切线圆弧；超出边长的半径会拒绝。',
      contextProvider: (): string => this.parameterDialogContext(),
      failureMessageProvider: (): string => this.panelStore.statusText,
      onConfirm: (radius: number): boolean => this.previewRoundedCorners(radius) }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('roundCorners'),
    onDidDisappear: (): void => this.onModalDialogClosed('roundCorners')
  });

  /** PCell 放置弹窗（KLayout: Instance > PCell） */
  private pendingBooleanOp: PreviewBooleanOp = 'subtract';
  private pickedPlacementRevision: number = -1;
  private scopeLabelKey: string = '';
  private scopeLabelValue: string = '';
  private booleanPreviewController: CustomDialogController = new CustomDialogController({
    builder: BooleanPreviewDialog({
      sourcesProvider: (): Shape[] => editService.getSelectedShapes(),
      layersProvider: (): UiLayer[] => this.layersForDisplay(),
      contextProvider: (): string => this.parameterDialogContext(),
      opProvider: (): PreviewBooleanOp => this.pendingBooleanOp,
      cellNameProvider: (): string => this.cellName(editService.getCurrentCellId()),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      prepareAction: (options: BooleanPreviewOptions): BooleanPreviewResult => booleanPreviewService.prepare(options),
      applyAction: (preview: BooleanPreview): BooleanPreviewResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图，请切换到编辑模式' };
        const result: BooleanPreviewResult = booleanPreviewService.apply(preview, this.cellStructureState());
        this.panelStore.statusText = result.message;
        if (result.ok) this.syncShapesFromEditService();
        return result;
      }
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('booleanPreview'),
    onDidDisappear: (): void => this.onModalDialogClosed('booleanPreview')
  });
  private commandSearchController: CustomDialogController = new CustomDialogController({
    builder: CommandSearchDialog({
      commandsProvider: (): WorkbenchCommand[] => this.workbenchCommands(),
      executeAction: (id: string): boolean => this.executeWorkbenchCommand(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('commandSearch'),
    onDidDisappear: (): void => this.onModalDialogClosed('commandSearch')
  });
  private layerExpressionController: CustomDialogController = new CustomDialogController({
    builder: LayerExpressionDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      documentProvider: (): string => this.docStore.activeWorkspaceId,
      cellNameProvider: (): string => this.cellName(editService.getCurrentCellId()),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      layerProvider: (): number[] => [this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype],
      sourcesProvider: (): Shape[] => editService.getShapes(),
      sourceRegionsProvider: (sources: Shape[]): Shape[] => this.filledPathPreview(sources, cleanDbuNm(this.docStore.docPhysicalUnits)),
      prepareAction: (options: LayerExpressionOptions): LayerExpressionResult => {
        return layerExpressionService.prepare(options, new NativeLayerRegionAdapter(), this.cellStructureState());
      },
      cancelAction: (preview?: LayerExpressionPreview): void => layerExpressionService.cancel(preview),
      applyAction: (preview: LayerExpressionPreview): LayerExpressionResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图' };
        const focusOwner: LayerExpressionFocusOwner | undefined = this.layerExpressionFocusOwner;
        const focusContext: string = this.parameterDialogContext();
        const result: LayerExpressionResult = layerExpressionService.apply(preview, this.cellStructureState(), this.docStore.activeWorkspaceId);
        this.panelStore.statusText = result.message;
        if (result.ok) {
          this.syncShapesFromEditService();
          this.advanceLayerExpressionFocusOwner(focusOwner, focusContext);
        }
        return result;
      }
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('layerExpression'),
    onWillDisappear: (): void => this.layerExpressionWillDisappear(),
    onDidDisappear: (): void => { this.onModalDialogClosed('layerExpression'); this.layerExpressionDidDisappear(); }
  });
  private hierarchyClipController: CustomDialogController = new CustomDialogController({
    builder: HierarchyClipDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      cellNameProvider: (): string => this.cellName(editService.getCurrentCellId()),
      sourceCellProvider: (): number => editService.getCurrentCellId(),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      boundsProvider: (): ShapeBounds => this.hierarchyClipInitialBounds(),
      sourcesProvider: (): Shape[] => this.filledHierarchyPreview(editService.getShapes(), editService.getCurrentCellId(), editService.getTopCellId()),
      previewShapesProvider: (preview: HierarchyClipPreview): Shape[] => this.filledHierarchyPreview(hierarchyClipSessionService.getPreviewShapes(preview.id), preview.outputCellId, editService.getTopCellId()),
      prepareAction: (options: HierarchyClipOptions): HierarchyClipSessionResult => hierarchyClipSessionService.prepare(
        { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }, options, createRegionHierarchyClipAdapter(new NativeLayerRegionAdapter())),
      applyAction: (id: string): HierarchyClipSessionResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图' };
        const result: HierarchyClipSessionResult = hierarchyClipSessionService.apply(id, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() });
        this.panelStore.statusText = result.message;
        if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); this.fitAllShapes(); }
        return result;
      },
      cancelAction: (id?: string): void => hierarchyClipSessionService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('hierarchyClip'),
    onDidDisappear: (): void => this.onModalDialogClosed('hierarchyClip')
  });
  private hierarchyFillController: CustomDialogController = new CustomDialogController({
    builder: HierarchyFillDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      cellsProvider: (): CellInfo[] => this.placeableCells.slice(),
      currentCellProvider: (): number => editService.getCurrentCellId(),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      layerProvider: (): number[] => [this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype],
      boundsProvider: (): ShapeBounds => this.hierarchyClipInitialBounds(),
      selectedAreaProvider: (): number[] => editService.getSelectedIds(),
      footprintProvider: (id: number): HierarchyFillFootprintResult => hierarchyFillService.definitionFootprint(
        editService.getShapes(), this.cellStructureState(), id, cleanDbuNm(this.docStore.docPhysicalUnits)),
      areaPreviewProvider: (options: HierarchyFillOptions): Shape[] => {
        if (options.areaPolygons !== undefined) return options.areaPolygons.map((points: Point[], index: number): Shape => ({
          id: index + 1, type: ShapeType.POLYGON, layerNumber: this.viewportStore.selectedLayerNumber, datatype: this.viewportStore.selectedDatatype, points: points, selected: false }));
        const ids: number[] = options.areaShapeIds ?? [];
        return this.filledPathPreview(editService.getShapes().filter((shape: Shape): boolean => ids.indexOf(shape.id) >= 0), options.dbuNm);
      },
      previewShapesProvider: (preview: HierarchyFillPreview): Shape[] => this.filledHierarchyPreview(
        hierarchyFillSessionService.getPreviewShapes(preview.id), preview.targetCellId, editService.getTopCellId()),
      prepareAction: (options: HierarchyFillOptions): HierarchyFillSessionResult => hierarchyFillSessionService.prepare(
        { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }, options, new NativeLayerRegionAdapter()),
      applyAction: (id: string): HierarchyFillSessionResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图' };
        const result: HierarchyFillSessionResult = hierarchyFillSessionService.apply(id, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() });
        this.panelStore.statusText = result.message; if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); }
        return result;
      },
      cancelAction: (id?: string): void => hierarchyFillSessionService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('hierarchyFill'),
    onDidDisappear: (): void => this.onModalDialogClosed('hierarchyFill')
  });
  private cellMaintenanceController: CustomDialogController = new CustomDialogController({
    builder: CellMaintenanceDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      cellsProvider: (): CellInfo[] => this.placeableCells.slice(),
      currentCellProvider: (): number => editService.getCurrentCellId(),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      selectedInstancesProvider: (): number[] => editService.getSelectedIds(),
      sourcesProvider: (): Shape[] => this.filledHierarchyPreview(editService.getShapes(), editService.getCurrentCellId(), editService.getTopCellId()),
      previewShapesProvider: (preview: CellMaintenancePreview): Shape[] => {
        const structure: EditStructureState | undefined = cellMaintenanceService.getPreviewStructure(preview.id);
        if (structure === undefined) throw new Error('库维护预览已失效');
        return this.filledHierarchyPreview(cellMaintenanceService.getPreviewShapes(preview.id), structure.cellStack[structure.cellStack.length - 1], structure.topCellId);
      },
      prepareAction: (request: CellMaintenanceRequest): CellMaintenanceResult => cellMaintenanceService.prepare(
        { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }, request),
      applyAction: (id: string): CellMaintenanceResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图' };
        const result: CellMaintenanceResult = cellMaintenanceService.apply(id, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() });
        this.panelStore.statusText = result.message; if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); }
        return result;
      },
      cancelAction: (id?: string): void => cellMaintenanceService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('cellMaintenance'),
    onDidDisappear: (): void => this.onModalDialogClosed('cellMaintenance')
  });
  private portManagerController: CustomDialogController = new CustomDialogController({
    builder: PortManagerDialog({
      contextProvider: (): string => this.portDialogContext(),
      cellNameProvider: (): string => this.cellName(editService.getCurrentCellId()),
      currentCellProvider: (): number => editService.getCurrentCellId(),
      choicesProvider: (options: PortChoiceQuery = {}): PortUiChoice[] => this.portChoices(options),
      scopeNoticeProvider: (): string => [this.viewportStore.portProjectionNotice, this.viewportStore.portCapabilityNotice].filter((notice: string): boolean => !!notice).join('；'),
      initialEndpointProvider: (): PortEndpoint | undefined => this.pickedPortEndpoint,
      previewPortsProvider: (preview: PortPreview): ResolvedPort[] => this.portPreviewEndpoints(preview),
      prepareAction: (request: PortRequest): PortResult => this.preparePortAction(request),
      applyAction: (id: string): PortResult => this.applyPortAction(id),
      cancelAction: (id?: string): void => portService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('portManager'),
    onDidDisappear: (): void => this.onModalDialogClosed('portManager')
  });
  private portConnectController: CustomDialogController = new CustomDialogController({
    builder: PortConnectDialog({
      contextProvider: (): string => this.portDialogContext(),
      choicesProvider: (options: PortChoiceQuery = {}): PortUiChoice[] => this.portChoices(options),
      scopeNoticeProvider: (): string => [this.viewportStore.portProjectionNotice, this.viewportStore.portCapabilityNotice].filter((notice: string): boolean => !!notice).join('；'),
      resolveAction: (endpoint: PortEndpoint): ResolvedPort => portService.resolve(endpoint, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }),
      previewPortsProvider: (preview: PortPreview): ResolvedPort[] => this.portPreviewEndpoints(preview),
      prepareAction: (request: PortRequest): PortResult => this.preparePortAction(request),
      applyAction: (id: string): PortResult => this.applyPortAction(id),
      cancelAction: (id?: string): void => portService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('portConnect'),
    onDidDisappear: (): void => this.onModalDialogClosed('portConnect')
  });
  private portRouteController: CustomDialogController = new CustomDialogController({
    builder: PortRouteDialog({
      contextProvider: (): string => `${this.portDialogContext()}:${technologyService.serialize()}`,
      choicesProvider: (options: PortChoiceQuery = {}): PortUiChoice[] => this.portChoices(options),
      scopeNoticeProvider: (): string => [this.viewportStore.portProjectionNotice, this.viewportStore.portCapabilityNotice].filter((notice: string): boolean => !!notice).join('；'),
      technologyProvider: (): TechnologyPackage | undefined => technologyService.getActive(),
      resolveAction: (endpoint: PortEndpoint): ResolvedPort => portService.resolve(endpoint, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }),
      prepareAction: (request: RouteSessionRequest): RouteSessionResult => this.prepareRouteAction(request),
      previewAction: (id: string): RouteSessionPreview | undefined => this.routePreview(id),
      applyAction: (id: string): RouteSessionResult => this.applyRouteAction(id),
      cancelAction: (id?: string): void => routeSessionService.cancel(id)
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('portRoute'),
    onDidDisappear: (): void => this.onModalDialogClosed('portRoute')
  });
  private importMergeController: CustomDialogController = new CustomDialogController({
    builder: ImportMergeDialog({
      contextProvider: (): string => this.parameterDialogContext(),
      cellNameProvider: (): string => this.cellName(editService.getCurrentCellId()),
      dbuProvider: (): number => cleanDbuNm(this.docStore.docPhysicalUnits),
      targetsProvider: (): CellInfo[] => this.placeableCells.slice(),
      currentCellProvider: (): number => editService.getCurrentCellId(),
      layerProvider: (): number[] => [this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype],
      chooseAction: async (guard: () => boolean): Promise<ImportMergeFileResult> => {
        if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) return { ok: false, cancelled: false, message: '已有后台作业，请等待完成后选择合并源' };
        return importMergeFileService.pickSource(this.getUIContext().getHostContext() as common.UIAbilityContext, guard);
      },
      prepareAction: (selection: ImportMergeFileSelection, options: ImportMergeOptions): ImportMergeResult => importMergeFileService.prepare(selection, this.cellStructureState(), options, this.docStore.activeWorkspaceId),
      sourceShapesProvider: (selection: ImportMergeFileSelection, root: number): Shape[] => {
        const source: ImportMergeSource | null = importMergeFileService.getSourceSnapshot(selection);
        return source === null ? [] : this.filledHierarchyPreview(source.shapes, root, source.topCellId, cleanDbuNm(source.physicalUnits));
      },
      previewShapesProvider: (preview: ImportMergePreview): Shape[] => {
        const source: ImportMergeSource | null = importMergeFileService.getPreviewSnapshot(preview);
        return source === null ? [] : this.filledHierarchyPreview(source.shapes, editService.getCurrentCellId(), source.topCellId);
      },
      applyAction: (preview: ImportMergePreview): ImportMergeResult => {
        if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改版图' };
        const result: ImportMergeResult = importMergeFileService.apply(preview, this.cellStructureState(), this.docStore.activeWorkspaceId,
          (state: EditStructureState): void => this.restoreCellStructure(state));
        this.panelStore.statusText = result.message;
        if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); }
        return result;
      },
      cancelAction: (): void => importMergeFileService.cancel()
    }), alignment: DialogAlignment.Center, customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('importMerge'),
    onDidDisappear: (): void => this.onModalDialogClosed('importMerge')
  });
  private placePCellController: CustomDialogController = new CustomDialogController({
    builder: PlacePCellDialog({
      initialPCellName: this.panelStore.curveInitialName,
      initialOutputMode: this.panelStore.curveOutputMode,
      initialLayerNumber: this.viewportStore.selectedLayerNumber,
      initialDatatype: this.viewportStore.selectedDatatype,
      dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits),
      viewportCenterProvider: (): Point => this.currentViewportWorldCenter(),
      contextProvider: (): string => this.parameterDialogContext(),
      onConfirm: (pcellName: string, params: Record<string, number | string | boolean>,
                  x: number, y: number, options?: PCellPlacementOptions, deviceName?: string) => {
        return this.applyPlacedPCell(pcellName, params, x, y, options, deviceName);
      },
      onStartInteractiveStamp: (pcellName: string, params: Record<string, number | string | boolean>,
                                options: PCellPlacementOptions, deviceName: string): boolean => {
        return this.startPCellStampSession(pcellName, params, options, deviceName);
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('placePCell'),
    onDidDisappear: (): void => this.onModalDialogClosed('placePCell')
  });

  private toolEntries: ToolEntry[] = createToolEntries();
  /** 网格尺寸（网格吸附与状态栏展示用） */
  /** 网格吸附开关 */
  /** SHORTCUT-2: 网格显示开关（TOGGLE_GRID 快捷键切换） */
  /** SNAP-1: 顶点吸附开关 */
  /** SNAP-1: 顶点吸附阈值（nm） */
  // INDEX-5: inspectorTab 已移除（死状态，从未传给 WorkbenchInspector；属性面板由 selectedShapeId 驱动）
  /** 当前层级深度（ViewService 回调写回） */
  /** Cell 层级树数据（供左侧 Toolbox Cell Tab 展示） */
  /** 当前 Top Cell ID（Cell 树高亮用） */
  /** 上次同步时的 INSTANCE 数量（变化时重建 Cell 树） */
  private lastInstanceCount: number = -1;
  /** 当前设备类型（由 BreakpointManager 回写，sm=手机/md=平板/lg=PC） */
  /** 当前布局配置（由 BreakpointManager 回写） */
  /** 当前窗口宽度（vp），用于浮层/浮钮定位 */
  /** 桌面显示器上缩小窗口时仍保持用户选择的浅色白画布。 */
  @StorageProp('hongtuDesktopWorkspace') desktopHost: boolean = false;
  @StorageProp('hongtuWindowDensity') @Watch('refreshWindowMetrics') effectiveWindowDensity: number = 1;
  /** 侧边栏是否可见（SideBarContainer.showSideBar 双向绑定，替代原 sidebarForceOpen） */
  /** 检查器是否可见（SideBarContainer.showSideBar 双向绑定，替代原 inspectorForceOpen） */
  private sidebarWidthTimer: number = -1;
  private inspectorWidthTimer: number = -1;

  /** BreakpointManager 布局变化监听器引用（aboutToDisappear 移除） */
  private breakpointListener: (config: LayoutConfig) => void = () => {};
  /** 窗口尺寸变化监听器引用 */
  private windowSizeChangeHandler: (size: window.Size) => void = () => {};
  /** 已注册尺寸监听的窗口实例 */
  private trackedWindow: window.Window | null = null;
  @Provide themeState: ThemeState = hongTuThemeState;
  @State showAppearanceSheet: boolean = false;
  @State lvsSheetOpen: boolean = false;
  @State lastExportFormat: string = 'PNG';
  @State lastExportFileName: string = '';
  @State lastExportUri: string = '';
  private exportCompletionController: CustomDialogController = new CustomDialogController({
    builder: ExportCompletionDialog({
      format: this.lastExportFormat,
      fileName: this.lastExportFileName,
      fileUri: this.lastExportUri,
      onCopyUri: (uri: string) => { this.copyExportLocation(uri); },
      onShareFile: (uri: string, fileName: string) => {
        this.shareExportedUri(uri, fileName, `${this.lastExportFormat} 导出文件 · 鸿图版图编辑器`);
      },
      onSaveGallerySuccess: () => {
        showAppSnackBar(this.getUIContext(), '版图 PNG 已保存至系统图库', {
          icon: $r('sys.symbol.checkmark_circle'),
          duration: AppToastDuration.SHORT
        });
      },
      onSaveGalleryError: (msg: string) => {
        showAppToast(this.getUIContext(), `保存图库未完成：${msg}`, AppToastDuration.NORMAL);
      }
    }),
    alignment: DialogAlignment.Center,
    customStyle: true,
    onWillAppear: (): void => this.onModalDialogOpened('exportCompletion'),
    onDidDisappear: (): void => this.onModalDialogClosed('exportCompletion')
  });
  @StorageProp('hongtuPendingCardCommand') @Watch('onPendingCardCommandChanged') pendingCardCommand: string = '';
  @StorageProp('hongtuPendingExternalUri') @Watch('onPendingExternalUriChanged') pendingExternalUri: string = '';
  @StorageProp(SAFE_AREA_TOP_VP_KEY) safeAreaTopVp: number = 0;
  @StorageProp(SAFE_AREA_BOTTOM_VP_KEY) safeAreaBottomVp: number = 0;
  @StorageProp(RESPONSIVE_COMPACT_SQUARE_KEY) compactSquare: boolean = false;
  @StorageProp(RESPONSIVE_IS_FLOATING_WINDOW_KEY) isFloatingWindow: boolean = false;
  @StorageProp(HONGTU_BACKGROUND_FLUSH_KEY) @Watch('onBackgroundFlushRequested') backgroundFlushToken: string = '';
  private handledCardCommandToken: string = '';
  private handledExternalUriToken: string = '';
  private handledBackgroundFlushToken: string = '';
  private hdsTabsController: HdsTabsController = new HdsTabsController();
  private pageAlive: boolean = false;
  private pageGeneration: number = 0;

  aboutToAppear(): void {
    this.pageAlive = true;
    const generation: number = ++this.pageGeneration;
    MotionSettings.start();
    ThemeManager.syncPersistence();
    PersistentStorage.persistProp('hongtuSidebarWidth', UI.sidebarWidth);
    PersistentStorage.persistProp('hongtuInspectorWidth', 280);
    PersistentStorage.persistProp('hongtuInspectorPinned', false);
    this.panelStore.preferredSidebarWidth = boundedPanelWidth(AppStorage.get<number>('hongtuSidebarWidth') ?? UI.sidebarWidth, 220, 400, UI.sidebarWidth);
    this.panelStore.preferredInspectorWidth = boundedPanelWidth(AppStorage.get<number>('hongtuInspectorWidth') ?? 280, 280, 480, 280);
    this.panelStore.propertyPanelPinned = AppStorage.get<boolean>('hongtuInspectorPinned') === true;
    this.panelStore.inspectorVisible = false;
    aiService.ensureReady().then(() => {
      if (!this.pageAlive || generation !== this.pageGeneration) return;
      this.refreshAiConversation();
      this.aiStore.aiError = aiService.getCredentialError();
    }).catch((error: Object) => {
      if (this.pageAlive && generation === this.pageGeneration) this.aiStore.aiError = `AI 会话初始化失败：${String(error)}`;
    });
    this.docStore.recentFiles = this.loadPersistedRecentFiles();
    // .lyp 互通自检（与 LayoutCanvasView 的 canvasTransformConsistent 同先例：
    // ArkTS 侧无测试框架，仅 console.warn 暴露，失败不阻塞启动）
    const lypCheck: string = lypSelfCheck();
    if (lypCheck.length > 0) {
      console.warn('LypService 自检失败: ' + lypCheck);
    }
    const nativeResult = nativeHongTuService.getVersion();
    if (nativeResult.status === NativeStatus.READY) {
      this.panelStore.nativeText = `Native: ${nativeResult.version}`;
      this.panelStore.statusText = '就绪 · 空白版图';
    } else {
      this.panelStore.nativeText = 'Native: ERROR';
      this.panelStore.statusText = `原生核心加载失败: ${nativeResult.message}`;
    }
    // 接通 EditService：把当前画布图形同步到编辑服务（建立撤销栈基线）
    editService.setShapes(this.shapes);
    editService.setStructureRestoreAction((state: EditStructureState) => this.restoreCellStructure(state));
    editService.setStructureLayerSnapshotAction((layers: UiLayer[], shapes: Shape[], preserveOwnFields: boolean = false): UiLayer[] => this.layersWithCounts(layers, shapes, preserveOwnFields));
    editService.setStructureStateProvider((): EditStructureState => this.cellStructureState());
    editService.setProcessStateProvider(() => ({ technologyJson: technologyService.serialize(),
      drcDeckJson: JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() }), drcConfiguration: drcService.captureConfiguration(), localProcessOwned: this.localProcessOwned === true }));
    this.refreshLayerCounts();
    // LAYER-4: 接通图层可见性 provider，使隐藏图层上的图形不可被 hitTest 命中
    editService.setLayerVisibleProvider((layerNumber: number, datatype: number): boolean => {
      for (let i = 0; i < this.docStore.layers.length; i++) {
        if (this.docStore.layers[i].layerNumber === layerNumber && this.docStore.layers[i].datatype === datatype) {
          return this.docStore.layers[i].visible;
        }
      }
      return true; // 未注册的图层默认可见
    });
    editService.setLayerSelectableProvider((layerNumber: number, datatype: number): boolean => {
      const layer: UiLayer | undefined = this.docStore.layers.find((item: UiLayer) => item.layerNumber === layerNumber && item.datatype === datatype);
      return layer === undefined || layer.selectable !== false;
    });
    editService.setLayerEditableProvider((layerNumber: number, datatype: number): boolean => {
      const layer: UiLayer | undefined = this.docStore.layers.find((item: UiLayer) => item.layerNumber === layerNumber && item.datatype === datatype);
      return layer === undefined || layer.locked !== true;
    });
    // 初始化文档元信息（空白版图下为 0 个图形）
    this.docStore.docElementCount = this.shapes.length;
    // 初始化顶层 Cell ID（子 Cell 导航栈底，空白版图用 0）
    editService.setTopCellId(0);
    advEditService.loadCellsFromImport(this.placeableCells.map((cell: CellInfo): string => cell.name), this.shapes, 0);
    this.rebuildCellTree();
    // 接通 ShortcutService：注册快捷键动作处理器
    shortcutService.setHandler((action: ShortcutAction, param?: Object) => {
      this.dispatchMnemonicAction(action, param);
    });
    // 接通 ViewService：层级深度变化回写本地状态
    viewService.onHierarchyDepthChange = (depth: number) => {
      if (depth !== this.docStore.hierarchyDepth) { this.invalidateLvsResult(); verifyService.clearNetSnapshot(); }
      this.docStore.hierarchyDepth = depth;
    };
    // VIEW-5: onLayerVisibilityChange 注册在页面级（而非 WorkbenchSidebar），避免侧栏抽屉卸载后 applyLayerPreset 静默失效
    viewService.onLayerVisibilityChange = (visibilities: Map<string, boolean>) => {
      this.applyLayerPresetToLayers(visibilities);
    };
    // 接通 ViewService：视图重置回调（重置画布缩放/偏移）
    viewService.onViewReset = () => {
      this.viewportStore.zoomPercent = viewService.getViewZoomPercent();
      const offset = viewService.getViewOffset();
      this.viewportStore.viewOffsetX = offset.offsetX;
      this.viewportStore.viewOffsetY = offset.offsetY;
    };
    // 接入 BreakpointManager：初始化断点并注册监听
    this.initBreakpoint();
    editService.setActiveDocumentIdentity(this.docStore.activeWorkspaceId);
    this.setNativeSnapshotCurrent(false);
    this.docStore.workspaceTabs = [{ id: this.docStore.activeWorkspaceId, title: this.docStore.currentDocumentTitle, dirty: false }];
    systemCollaborationService.registerKnockShare((): KnockSharePayload | null => this.buildKnockSharePayload());
    this.initializeWorkspace();
  }

  aboutToDisappear(): void {
    systemCollaborationService.unregisterKnockShare();
    this.panelStore.isExternalDragHovering = false;
    this.aiNativeImport.cancel(); this.aiNativeImportSelection = undefined;
    if (this.aiNativeOperation !== null && this.aiNativeCancellation === null) this.aiNativeCancellation = pythonBridgeService.cancelOperation(this.aiNativeOperation);
    this.revokeRdbWaiverPreview(); layerExpressionService.cancel();
    if (this.verifyStore.engineeringRestorePreview !== undefined) this.cancelEngineeringReviewRestore(this.verifyStore.engineeringRestorePreview.token);
    this.rdbReviewFileTicket++; this.verifyStore.rdbReviewBusy = false;
    if (this.viewWorkspaceInitialized) {
      this.persistViewWorkspacePresentation(); this.viewWorkspaceFileTicket++; this.viewportStore.viewWorkspaceFileBusy = false;
    }
    this.canvasFocusReturnTicket++;
    this.pageAlive = false; this.pageGeneration++;
    if (this.sidebarWidthTimer >= 0) clearTimeout(this.sidebarWidthTimer);
    if (this.inspectorWidthTimer >= 0) clearTimeout(this.inspectorWidthTimer);
    this.sidebarWidthTimer = -1; this.inspectorWidthTimer = -1;
    this.cancelImportWizard();
    this.importInProgress = false;
    hierarchyClipSessionService.cancel(); importMergeFileService.cancel(); hierarchyFillSessionService.cancel(); cellMaintenanceService.cancel();
    shortcutService.clear(); this.mnemonicContext = '';
    this.cancelActiveNativeJob();
    if (this.nativeJobTimer >= 0) clearInterval(this.nativeJobTimer);
    this.nativeJobTimer = -1;
    this.finishNudgeTransaction();
    editService.setStructureRestoreAction(null);
    editService.setStructureLayerSnapshotAction(null);
    editService.setStructureStateProvider(null);
    editService.setProcessStateProvider(null);
    this.openDialogKeys.clear();
    this.panelStore.activeDialogCount = 0;
    if (this.autosaveTimer >= 0) { clearTimeout(this.autosaveTimer); this.autosaveTimer = -1; }
    if (this.workspaceViewTimer >= 0) { clearInterval(this.workspaceViewTimer); this.workspaceViewTimer = -1; }
    this.saveWorkspaceDraft(false, true);
    MotionSettings.stop();
    // 移除 BreakpointManager 监听与窗口尺寸监听
    breakpointManager.removeListener(this.breakpointListener);
    if (this.trackedWindow !== null) {
      try {
        this.trackedWindow.off('windowSizeChange', this.windowSizeChangeHandler);
      } catch (e) {
        // 忽略反注册异常
      }
      this.trackedWindow = null;
    }
  }

  /** 初始化断点管理器：获取窗口宽度、注册布局变化监听、监听窗口尺寸变化 */
  private initBreakpoint(): void {
    const generation: number = this.pageGeneration;
    // 注册布局变化监听：设备类型变化时 BreakpointManager 回调
    this.breakpointListener = (config: LayoutConfig) => {
      if (!this.pageAlive || generation !== this.pageGeneration) return;
      this.panelStore.layoutConfig = config;
      this.panelStore.currentDevice = config.device;
      // 根据设备类型设置侧边栏/检查器默认显隐
      // lg：双栏内联显示；md：侧边栏内联 + 检查器浮层；sm：双栏浮层
      if (config.device === DeviceType.PC) {
        this.panelStore.sidebarVisible = true;
        this.panelStore.inspectorVisible = false;
      } else if (config.device === DeviceType.TABLET) {
        this.panelStore.sidebarVisible = true;
        this.panelStore.inspectorVisible = false;
      } else {
        this.panelStore.sidebarVisible = false;
        this.panelStore.inspectorVisible = false;
      }
    };
    breakpointManager.addListener(this.breakpointListener);

    // 用 display 同步获取屏幕宽度作为初始估计（display 宽度 ≠ 窗口宽度，但近似足够）
    try {
      const d = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      const widthVp: number = d.width / density;
      this.panelStore.windowHeightVp = d.height / density;
      this.panelStore.windowWidthVp = widthVp;
      breakpointManager.updateWidth(widthVp);
      this.panelStore.layoutConfig = breakpointManager.getConfig();
      this.panelStore.currentDevice = breakpointManager.getDevice();
    } catch (e) {
      // 降级：保持默认 PC 配置
    }

    // 异步获取实际窗口宽度并注册尺寸变化监听
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window) => {
        if (!this.pageAlive || generation !== this.pageGeneration) return;
        this.trackedWindow = win;
        const d = display.getDefaultDisplaySync();
        const density: number = this.effectiveWindowDensity > 0 ? this.effectiveWindowDensity : d.densityPixels;
        // 用实际窗口宽度覆盖 display 宽度估计
        const winWidthPx: number = win.getWindowProperties().windowRect.width;
        const winWidthVp: number = winWidthPx / density;
        this.panelStore.windowWidthVp = winWidthVp;
        this.panelStore.windowHeightVp = win.getWindowProperties().windowRect.height / density;
        breakpointManager.updateWidth(winWidthVp);
        this.panelStore.layoutConfig = breakpointManager.getConfig();
        this.panelStore.currentDevice = breakpointManager.getDevice();
          // 注册窗口尺寸变化监听
        this.windowSizeChangeHandler = (size: window.Size) => {
          if (!this.pageAlive || generation !== this.pageGeneration) return;
          const currentDensity: number = this.effectiveWindowDensity > 0 ? this.effectiveWindowDensity : density;
          const wv: number = size.width / currentDensity;
          this.panelStore.windowWidthVp = wv;
          this.panelStore.windowHeightVp = size.height / currentDensity;
          breakpointManager.updateWidth(wv);
        };
        win.on('windowSizeChange', this.windowSizeChangeHandler);
      }).catch((_e: Object) => {
        // 获取窗口失败：已用 display 宽度降级
      });
    } catch (e) {
      // getUIContext 不可用：保持 display 宽度降级
    }
  }

  /** 是否紧凑模式（sm 手机端） */
  private isCompact(): boolean {
    return !this.isDesktopWorkspace() && this.panelStore.currentDevice === DeviceType.PHONE;
  }

  private refreshWindowMetrics(): void {
    if (this.trackedWindow === null) return;
    const rect: window.Rect = this.trackedWindow.getWindowProperties().windowRect;
    const density: number = this.effectiveWindowDensity > 0 ? this.effectiveWindowDensity : 1;
    this.panelStore.windowWidthVp = rect.width / density;
    this.panelStore.windowHeightVp = rect.height / density;
    breakpointManager.updateWidth(this.panelStore.windowWidthVp);
  }

  private isDesktopWorkspace(): boolean {
    return this.desktopHost;
  }

  private selectModule(module: WorkModule, label: string): void {
    const durationMs: number = fullscreenTransitionDuration(undefined, this.isDesktopWorkspace());
    const curve: Curve | ICurve = this.reduceMotion
      ? Curve.Linear
      : (this.isDesktopWorkspace() ? Curve.Friction : feedbackCurve());
    this.getUIContext().animateTo({ duration: durationMs, curve: curve }, () => {
      this.viewportStore.currentModule = module;
      this.panelStore.statusText = `切换到${label}`;
      if (module === WorkModule.Verify) this.verifyStore.drcDockCollapsed = false;
      this.verifyStore.showDrcRules = false;
    });
  }

  private moduleStageTransition(edge: TransitionEdge = TransitionEdge.BOTTOM): TransitionEffect {
    return this.reduceMotion ? TransitionEffect.IDENTITY : hierarchyTransition(edge, this.isDesktopWorkspace());
  }

  private canvasStageGeometryId(): string {
    if (this.reduceMotion || this.isCompact() || this.viewportStore.currentModule !== WorkModule.Layout) {
      return '';
    }
    return ACTIVE_LAYOUT_STAGE_GEOMETRY_ID;
  }

  private floatingTransition(edge: TransitionEdge): TransitionEffect {
    return this.reduceMotion ? TransitionEffect.IDENTITY : panelTransition(edge, this.isDesktopWorkspace());
  }

  private modalTransition(): TransitionEffect {
    return this.reduceMotion ? TransitionEffect.IDENTITY : dialogTransition(this.isDesktopWorkspace());
  }

  private floatingShapePropertiesVisible(): boolean {
    if (this.viewportStore.currentModule !== WorkModule.Layout || this.panelStore.propertyPanelClosed) {
      return false;
    }
    if (this.panelStore.activeDialogCount > 0 || this.showAppearanceSheet || this.lvsSheetOpen) {
      return false;
    }
    if (this.viewportStore.selectedShapeId < 0) {
      return false;
    }
    if (
      this.vertexStore.isDragging() ||
      this.draftControlStore.stampActive ||
      this.viewportStore.interactiveCurveKind.length > 0
    ) {
      return false;
    }
    return this.viewportStore.currentTool === ActiveTool.Select || this.viewportStore.currentTool === ActiveTool.Move;
  }

  private currentViewportWorldCenter(): Point {
    const nav: CanvasNavigationViewport = this.canvasNavigationViewport();
    const wx: number = screenToWorldPx(nav.centerX, this.viewportStore.zoomPercent, this.viewportStore.viewOffsetX);
    const wy: number = screenToWorldYpx(nav.centerY, this.viewportStore.zoomPercent, this.viewportStore.viewOffsetY);
    return {
      x: Number.isFinite(wx) ? wx : 0,
      y: Number.isFinite(wy) ? wy : 0
    };
  }

  private cellKeyNameLookup(): Record<string, string> {
    const map: Record<string, string> = {};
    const names: PropertyCellOption[] = this.propertyCellOptions();
    for (let i: number = 0; i < names.length; i++) {
      const opt: PropertyCellOption = names[i];
      const key: string | undefined = this.docCellKeys[opt.id];
      if (key !== undefined && key.length > 0) {
        map[key] = opt.name;
      }
    }
    return map;
  }

  private shapePopoverBounds(shape: Shape): ShapeBounds {
    if (shape.type === ShapeType.INSTANCE) {
      try {
        const resolved: ShapeBounds | undefined = new HierarchyReferenceBoundsResolver(
          this.shapes,
          editService.getCurrentCellId()
        ).boundsForInstance(shape);
        if (resolved !== undefined) {
          return resolved;
        }
      } catch (_err) {}
    }
    return getShapeBounds(shape);
  }

  private propertyX(): number {
    const minLeft: number = this.isDesktopWorkspace() ? 76 : 12;
    const aiOverlayReserve: number = (this.isDesktopWorkspace() && this.panelStore.showAiPanel) ? 476 : 0;
    const maxX: number = Math.max(minLeft, this.viewportStore.canvasViewportWidth - aiOverlayReserve - 324);
    if (this.panelStore.propertyPanelPinned) return maxX;
    const shape: Shape | undefined = this.shapes.find((item: Shape) => item.id === this.viewportStore.selectedShapeId);
    if (shape === undefined) return maxX;
    const bounds: ShapeBounds = this.shapePopoverBounds(shape);
    return Math.min(
      maxX,
      Math.max(minLeft, worldToScreenPx(bounds.maxX, this.viewportStore.zoomPercent, this.viewportStore.viewOffsetX) + 18)
    );
  }

  private propertyY(): number {
    if (this.panelStore.propertyPanelPinned) return 14;
    const shape: Shape | undefined = this.shapes.find((item: Shape) => item.id === this.viewportStore.selectedShapeId);
    if (shape === undefined) return 14;
    const xPos: number = this.propertyX();
    const minTop: number = xPos < 280 ? 56 : 14;
    const panelHeight: number = Math.min(596, Math.max(160, this.viewportStore.canvasViewportHeight - 28));
    const bounds: ShapeBounds = this.shapePopoverBounds(shape);
    return Math.min(
      Math.max(minTop, this.viewportStore.canvasViewportHeight - panelHeight - 14),
      Math.max(minTop, worldToScreenYpx(bounds.maxY, this.viewportStore.zoomPercent, this.viewportStore.viewOffsetY))
    );
  }

  /** 画布工作区不足时使用紧凑编辑工具栏，避免命令挤出右侧边界 */
  private isToolbarCompact(): boolean {
    const sidebarWidth: number = this.panelStore.sidebarVisible && this.sidebarContainerType() === SideBarContainerType.Embed ? this.sidebarWidth() : 0;
    const inspectorWidth: number = this.panelStore.inspectorVisible && this.inspectorContainerType() === SideBarContainerType.Embed ? this.inspectorWidth() : 0;
    return this.isCompact() || (this.panelStore.windowWidthVp - sidebarWidth - inspectorWidth) < 1400;
  }

  /** Preserve the preferred width while narrow windows temporarily constrain drawers. */
  private sidebarWidth(): number {
    const available: number = this.panelStore.windowWidthVp - (this.isDesktopWorkspace() ? UI.railWidth : 0) - 24;
    return Math.max(220, Math.min(this.panelStore.preferredSidebarWidth, available));
  }

  /** 检查器宽度（lg=panelWidth，md/sm 浮层=280） */
  private inspectorWidth(): number {
    const available: number = this.panelStore.windowWidthVp - (this.isDesktopWorkspace() ? UI.railWidth : 0) - 24;
    return Math.max(280, Math.min(this.panelStore.preferredInspectorWidth, available));
  }

  /** 外层 SideBarContainer 类型：lg/md 内联（Embed），sm 浮层（Overlay） */
  private sidebarContainerType(): SideBarContainerType {
    const placement = workbenchPanelPlacement(this.panelStore.windowWidthVp, this.isDesktopWorkspace() ? UI.railWidth : 0,
      this.sidebarWidth(), this.inspectorWidth(), this.panelStore.sidebarVisible, this.panelStore.propertyPanelPinned, this.panelStore.windowHeightVp);
    return this.isCompact() || placement.sidebarOverlay ? SideBarContainerType.Overlay : SideBarContainerType.Embed;
  }

  /** 内层 SideBarContainer 类型：lg 内联（Embed），md/sm 浮层（Overlay） */
  private inspectorContainerType(): SideBarContainerType {
    const placement = workbenchPanelPlacement(this.panelStore.windowWidthVp, this.isDesktopWorkspace() ? UI.railWidth : 0,
      this.sidebarWidth(), this.inspectorWidth(), this.panelStore.sidebarVisible, this.isDesktopWorkspace() ? this.panelStore.propertyPanelPinned : true, this.panelStore.windowHeightVp);
    return this.isCompact() || placement.inspectorOverlay ? SideBarContainerType.Overlay : SideBarContainerType.Embed;
  }

  /** V2 画布优先准则：选中图形仅弹出画布上方就近悬浮属性窗，绝不自动展开全高右侧 SideBarContainer 挤压画布。 */
  private desktopInspectorVisible(): boolean {
    return this.panelStore.inspectorVisible;
  }

  private ensureFloatingPropertyToolReady(): void {
    this.exitStampSession();
    this.viewportStore.interactiveCurveKind = '';
    if (this.vertexStore.isDragging()) {
      this.vertexStore.revert();
    }
    if (this.viewportStore.currentTool !== ActiveTool.Select && this.viewportStore.currentTool !== ActiveTool.Move) {
      this.viewportStore.currentTool = ActiveTool.Select;
    }
  }

  private toggleInspectorPanel(): void {
    if (this.viewportStore.currentModule === WorkModule.Layout && this.viewportStore.selectedShapeId >= 0) {
      if (this.floatingShapePropertiesVisible()) {
        this.panelStore.propertyPanelClosed = true;
      } else {
        this.panelStore.propertyPanelClosed = false;
        this.ensureFloatingPropertyToolReady();
      }
      return;
    }
    this.panelStore.inspectorVisible = !this.panelStore.inspectorVisible;
    if (this.panelStore.inspectorVisible && this.sidebarContainerType() === SideBarContainerType.Overlay) {
      this.panelStore.sidebarVisible = false;
    }
  }

  private showInspectorPanel(): void {
    this.panelStore.propertyPanelClosed = false;
    if (this.viewportStore.currentModule === WorkModule.Layout && this.viewportStore.selectedShapeId >= 0) {
      this.ensureFloatingPropertyToolReady();
      return;
    }
    this.panelStore.inspectorVisible = true;
    if (this.sidebarContainerType() === SideBarContainerType.Overlay) {
      this.panelStore.sidebarVisible = false;
    }
  }

  private setInspectorPinned(pinned: boolean): void {
    this.panelStore.propertyPanelPinned = pinned;
    AppStorage.setOrCreate<boolean>('hongtuInspectorPinned', pinned);
  }

  /** Read the native divider's actual width; programmatic window clamps are not preferences. */
  private rememberPanelWidth(sidebar: boolean, width: number): void {
    const expected: number = sidebar ? this.sidebarWidth() : this.inspectorWidth();
    const minimum: number = sidebar ? 220 : 280;
    const maximum: number = sidebar ? 400 : 480;
    const pending: number = sidebar ? this.sidebarWidthTimer : this.inspectorWidthTimer;
    if (pending >= 0) clearTimeout(pending);
    if (!Number.isFinite(width) || width < minimum || width > maximum || Math.abs(width - expected) < 1) return;
    // Let the native drag finish before feeding its width back into layout.
    const timer: number = setTimeout(() => {
      if (!this.pageAlive) return;
      if (sidebar) {
        this.sidebarWidthTimer = -1;
        this.panelStore.preferredSidebarWidth = width;
        AppStorage.setOrCreate<number>('hongtuSidebarWidth', width);
      } else {
        this.inspectorWidthTimer = -1;
        this.panelStore.preferredInspectorWidth = width;
        AppStorage.setOrCreate<number>('hongtuInspectorWidth', width);
      }
    }, 180);
    if (sidebar) this.sidebarWidthTimer = timer;
    else this.inspectorWidthTimer = timer;
  }

  /** 右键上下文菜单内容（绑定到画布，右键触发；替代旧 ContextMenu 组件） */
  @Builder
  buildCanvasContextMenu() {
    Menu() {
      MenuItem({ content: '编辑', builder: this.buildCanvasEditMenu, symbolStartIcon: menuIcon('edit') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '变换', builder: this.buildCanvasTransformMenu, symbolStartIcon: menuIcon('rotate') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.viewportStore.selectedShapeId >= 0)
      MenuItem({ content: '对齐与分布', builder: this.buildCanvasAlignMenu, symbolStartIcon: menuIcon('alignLeft') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(editService.getSelectedShapes().length >= 2)
      MenuItem({ content: '布尔与 Cell', builder: this.buildCanvasBooleanMenu, symbolStartIcon: menuIcon('union') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE).id('canvas-context-boolean')
      MenuItem({ content: '选择与图层', builder: this.buildCanvasSelectionMenu, symbolStartIcon: menuIcon('select') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '验证与网络', builder: this.buildCanvasVerificationMenu, symbolStartIcon: menuIcon('verify') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '视图与导出', builder: this.buildCanvasViewExportMenu, symbolStartIcon: menuIcon('view') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
    }
    .attributeModifier(menuStyle([
      { content: '编辑', builder: this.buildCanvasEditMenu, symbolStartIcon: menuIcon('edit') , symbolEndIcon: menuSubmenuArrow() },
      { content: '变换', builder: this.buildCanvasTransformMenu, symbolStartIcon: menuIcon('rotate') , symbolEndIcon: menuSubmenuArrow() },
      { content: '对齐与分布', builder: this.buildCanvasAlignMenu, symbolStartIcon: menuIcon('alignLeft') , symbolEndIcon: menuSubmenuArrow() },
      { content: '布尔与 Cell', builder: this.buildCanvasBooleanMenu, symbolStartIcon: menuIcon('union') , symbolEndIcon: menuSubmenuArrow() },
      { content: '选择与图层', builder: this.buildCanvasSelectionMenu, symbolStartIcon: menuIcon('select') , symbolEndIcon: menuSubmenuArrow() },
      { content: '验证与网络', builder: this.buildCanvasVerificationMenu, symbolStartIcon: menuIcon('verify') , symbolEndIcon: menuSubmenuArrow() },
      { content: '视图与导出', builder: this.buildCanvasViewExportMenu, symbolStartIcon: menuIcon('view') , symbolEndIcon: menuSubmenuArrow() }
    ], this.getUIContext(), [this.buildCanvasEditMenuSizing(), this.buildCanvasTransformMenuSizing(), this.buildCanvasAlignMenuSizing(), this.buildCanvasBooleanMenuSizing(), this.buildCanvasSelectionMenuSizing(), this.buildCanvasVerificationMenuSizing(), this.buildCanvasViewExportMenuSizing()]))
  }

  @Builder
  buildCanvasEditMenu() {
    Menu() {
      MenuItemGroup({ header: '剪贴板' }) {
        MenuItem({ symbolStartIcon: menuIcon('copy'), content: '复制', labelInfo: 'Ctrl+C' })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.copySelection(); })

        MenuItem({ symbolStartIcon: menuIcon('paste'), content: '粘贴', labelInfo: 'Ctrl+V' })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.pasteFromClipboard(); })

        MenuItem({ symbolStartIcon: menuIcon('copy'), content: '原地偏移复制', labelInfo: 'Ctrl+D' })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.duplicateSelection(); })

      }

      MenuItemGroup({ header: '修改选中图形' }) {
        MenuItem({ content: '移动', labelInfo: 'M', symbolStartIcon: menuIcon('move') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.switchToMoveTool(); })

        MenuItem({ content: '阵列复制…', symbolStartIcon: menuIcon('array') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.openArrayCopyDialog(); })

        MenuItem({ content: '尺寸调整…', symbolStartIcon: menuIcon('size') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.openSizeOffsetDialog(); })

      }

      MenuItemGroup() {
        MenuItem({ symbolStartIcon: menuIcon('delete', true), content: '删除', labelInfo: 'Del' })
        .attributeModifier(MENU_DANGER_ITEM_STYLE)
        .enabled(this.viewportStore.selectedShapeId >= 0)
        .onClick(() => { this.removeSelectedShape(); })

      }
    }
    .attributeModifier(menuStyle(this.buildCanvasEditMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCanvasVerificationMenu() {
    Menu() {
      MenuItemGroup({ header: '检查' }) {
      MenuItem({ content: '运行 DRC', symbolStartIcon: menuIcon('verify') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.runDrcBackground(); })
      if (this.verifyStore.drcIssues.length > 0) {
        MenuItem({ symbolStartIcon: menuIcon('warning'), content: '定位首个违规' })
        .attributeModifier(MENU_ITEM_STYLE)
          .onClick(() => { this.locateIssue(this.verifyStore.drcIssues[0]); })
      }
      }
      MenuItemGroup({ header: '网络' }) {
      MenuItem({ content: '网络追踪', symbolStartIcon: menuIcon('trace') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.traceNets(); })
      // LVS：连通性级预检查（提取版图网络 vs. SPICE 参考网表按名比对，非签核）
      MenuItem({ content: 'LVS 连通性预检查', symbolStartIcon: menuIcon('verify') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.openLvsPanel(); })
      }
    }
    .attributeModifier(menuStyle(this.buildCanvasVerificationMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCanvasViewExportMenu() {
    Menu() {
      MenuItemGroup({ header: '视图' }) {
        MenuItem({ content: '框选放大', symbolStartIcon: menuIcon('zoomIn') })
        .attributeModifier(MENU_ITEM_STYLE)
        .id('canvas-box-zoom')
        .onClick(() => { this.handleShortcut(ShortcutAction.BOX_ZOOM); })

        MenuItem({ symbolStartIcon: menuIcon('measure'), content: '测量距离', labelInfo: 'R' })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => {
          this.viewportStore.currentTool = ActiveTool.Measure;
          this.panelStore.statusText = '已切换到测量工具';
        })

        MenuItem({ symbolStartIcon: menuIcon('view'), content: '适配全部', labelInfo: 'F' })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.fitAllShapes(); })

        MenuItem({ symbolStartIcon: menuIcon('reset'), content: '重置视图' })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.resetView(); })


      }

      MenuItemGroup({ header: '导出与分享' }) {
        MenuItem({ content: '导出 SVG 矢量图…', symbolStartIcon: menuIcon('export') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.shapes.length > 0)
        .onClick(() => { this.exportImage('svg'); })

        MenuItem({ content: '导出 PNG 图片…', symbolStartIcon: menuIcon('export') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.shapes.length > 0)
        .onClick(() => { this.exportImage('png'); })

        MenuItem({ content: '分享 PNG 版图快照…', symbolStartIcon: menuIcon('export') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.shapes.length > 0)
        .onClick(() => { this.shareCurrentLayoutSnapshot('png'); })

        MenuItem({ content: '分享 SVG 矢量版图…', symbolStartIcon: menuIcon('export') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.shapes.length > 0)
        .onClick(() => { this.shareCurrentLayoutSnapshot('svg'); })

        MenuItem({ content: '导出 OASIS…', symbolStartIcon: menuIcon('export') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(this.shapes.length > 0 || this.docPorts.length > 0)
        .onClick(() => { this.exportOasis(); })

      }
    }
    .attributeModifier(menuStyle(this.buildCanvasViewExportMenuSizing(), this.getUIContext()))
  }

  // MenuItemOptions.builder creates a submenu; a trailing block is custom item content.
  @Builder
  buildCanvasTransformMenu() {
    Menu() {
      MenuItemGroup({ header: '旋转' }) {
        MenuItem({ content: '旋转 90°', symbolStartIcon: menuIcon('rotate') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('rotate', 90); })

        MenuItem({ content: '旋转 180°', symbolStartIcon: menuIcon('rotate') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('rotate', 180); })

        MenuItem({ content: '旋转 270°', symbolStartIcon: menuIcon('rotate') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('rotate', 270); })

      }

      MenuItemGroup({ header: '镜像' }) {
        MenuItem({ content: '水平镜像', symbolStartIcon: menuIcon('mirror') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('mirror', 0); })

        MenuItem({ content: '垂直镜像', symbolStartIcon: menuIcon('mirror') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('mirror', 1); })

      }

      MenuItemGroup({ header: '缩放' }) {
        MenuItem({ content: '放大至 2 倍', symbolStartIcon: menuIcon('zoomIn') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('scale', 2); })

        MenuItem({ content: '缩小至 0.5 倍', symbolStartIcon: menuIcon('zoomOut') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.transformSelection('scale', 0.5); })

      }
    }
    .attributeModifier(menuStyle(this.buildCanvasTransformMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCanvasAlignMenu() {
    Menu() {
      MenuItemGroup({ header: '对齐' }) {
      MenuItem({ content: '左对齐', symbolStartIcon: menuIcon('alignLeft') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.LEFT, this.alignLabel(AlignType.LEFT)); })
      MenuItem({ content: '右对齐', symbolStartIcon: menuIcon('alignRight') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.RIGHT, this.alignLabel(AlignType.RIGHT)); })
      MenuItem({ content: '上对齐', symbolStartIcon: menuIcon('alignTop') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.TOP, this.alignLabel(AlignType.TOP)); })
      MenuItem({ content: '下对齐', symbolStartIcon: menuIcon('alignBottom') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.BOTTOM, this.alignLabel(AlignType.BOTTOM)); })
      MenuItem({ content: '水平居中', symbolStartIcon: menuIcon('alignCenter') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.CENTER_H, this.alignLabel(AlignType.CENTER_H)); })
      MenuItem({ content: '垂直居中', symbolStartIcon: menuIcon('alignMiddle') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.alignSelection(AlignType.CENTER_V, this.alignLabel(AlignType.CENTER_V)); })
      }
      MenuItemGroup({ header: '等距分布' }) {
      MenuItem({ content: '水平等距', symbolStartIcon: menuIcon('distributeH') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(editService.getSelectedShapes().length >= 3)
        .onClick(() => { this.distributeSelection(DistributeType.HORIZONTAL); })
      MenuItem({ content: '垂直等距', symbolStartIcon: menuIcon('distributeV') })
        .attributeModifier(MENU_ITEM_STYLE)
        .enabled(editService.getSelectedShapes().length >= 3)
        .onClick(() => { this.distributeSelection(DistributeType.VERTICAL); })
      }
      MenuItemGroup({ header: '端口' }) {
        MenuItem({ content: '端口连接对齐…', symbolStartIcon: menuIcon('alignCenter') })
          .attributeModifier(MENU_ITEM_STYLE).enabled(this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress)
          .onClick(() => this.openPortConnect())
        MenuItem({ content: '端口布线…', symbolStartIcon: menuIcon('path') })
          .attributeModifier(MENU_ITEM_STYLE).enabled(this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress)
          .onClick(() => this.openPortRoute())
      }
    }
    .attributeModifier(menuStyle(this.buildCanvasAlignMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCanvasBooleanMenu() {
    Menu() {
      MenuItemGroup({ header: '布尔运算' }) {
      MenuItem({ content: '合并', symbolStartIcon: menuIcon('union') })
        .attributeModifier(MENU_ITEM_STYLE)
        .id('canvas-boolean-merge')
        .enabled(editService.getSelectedShapes().length === 2)
        .onClick(() => { this.applyBooleanOp('merge'); })
      MenuItem({ content: '相减', symbolStartIcon: menuIcon('subtract') })
        .attributeModifier(MENU_ITEM_STYLE)
        .id('canvas-boolean-subtract')
        .enabled(editService.getSelectedShapes().length === 2)
        .onClick(() => { this.applyBooleanOp('subtract'); })
      MenuItem({ content: '相交', symbolStartIcon: menuIcon('intersect') })
        .attributeModifier(MENU_ITEM_STYLE)
        .id('canvas-boolean-intersect')
        .enabled(editService.getSelectedShapes().length === 2)
        .onClick(() => { this.applyBooleanOp('intersect'); })
      MenuItem({ content: '异或', symbolStartIcon: menuIcon('xor') })
        .attributeModifier(MENU_ITEM_STYLE)
        .id('canvas-boolean-xor')
        .enabled(editService.getSelectedShapes().length === 2)
        .onClick(() => { this.applyBooleanOp('xor'); })
      MenuItem({ content: '倒圆角…', symbolStartIcon: menuIcon('path') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.canRoundSelectedShape())
        .onClick(() => this.openRoundCornersDialog())
      }
      MenuItemGroup({ header: 'Cell' }) {
        if (this.viewportStore.selectedShapeId >= 0) {
          MenuItem({ content: '进入子 Cell', symbolStartIcon: menuIcon('cell') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => { this.enterSelectedInstanceCell(); })
        }
        MenuItem({ content: '放置实例…', labelInfo: 'I', symbolStartIcon: menuIcon('instance') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => { this.openInstanceDialog(); })
        MenuItem({ content: '放置 PCell…', symbolStartIcon: menuIcon('pcell') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => { this.openPCellDialog(); })
        MenuItem({ content: '展开选中实例…', symbolStartIcon: menuIcon('flatten') })
        .attributeModifier(MENU_ITEM_STYLE).enabled(this.viewportStore.selectedShapeId >= 0)
          .onClick(() => { this.flattenSelectedInstance(); })
        MenuItem({ content: '选区组成 Cell…', symbolStartIcon: menuIcon('cell') })
          .attributeModifier(MENU_ITEM_STYLE).enabled(editService.getSelectedIds().length > 0 && this.viewportStore.currentViewMode === ViewMode.EDIT)
          .onClick(() => this.openMakeCellDialog())
        MenuItem({ content: '端口管理…', symbolStartIcon: menuIcon('cell') })
          .attributeModifier(MENU_ITEM_STYLE).enabled(this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress)
          .onClick(() => this.openPortManager())
      }
    }
    .attributeModifier(menuStyle(this.buildCanvasBooleanMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCanvasSelectionMenu() {
    Menu() {
      MenuItemGroup({ header: '选择' }) {
      MenuItem({ content: '全选', labelInfo: 'Ctrl+A', symbolStartIcon: menuIcon('selectAll') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.selectAllShapes(); })
      MenuItem({ content: '选择当前层全部', symbolStartIcon: menuIcon('layer') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => { this.selectAllOnCurrentLayer(); })
      MenuItem({ content: '取消选择', symbolStartIcon: menuIcon('selectNone') })
        .attributeModifier(MENU_ITEM_STYLE)
        .onClick(() => {
          editService.clearSelection();
          this.viewportStore.selectedShapeId = -1;
          this.syncShapesFromEditService();
        })
      }
      MenuItemGroup({ header: '移动到图层' }) {
      ForEach(this.layersForDisplay(), (layer: UiLayer) => {
        MenuItem({ content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName}`, symbolStartIcon: menuIcon('layer') })
        .attributeModifier(MENU_ITEM_STYLE)
          .enabled(this.viewportStore.selectedShapeId >= 0)
          .onClick(() => { this.changeLayerOfSelected(layer.layerNumber, layer.datatype); })
      }, (layer: UiLayer) => `${layer.layerNumber}_${layer.datatype}`)
      }
    }
    .attributeModifier(menuStyle(this.buildCanvasSelectionMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildCompactCanvasOptions() {
    Menu() {
      MenuItem({ content: '选择过滤', builder: this.buildSelectionFilterMenu, symbolStartIcon: menuIcon('filter') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
      MenuItem({ content: '显示层级', builder: this.buildHierarchyMenu, symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuSubmenuArrow() })
        .attributeModifier(MENU_ITEM_STYLE)
    }
    .attributeModifier(menuStyle([
      { content: '选择过滤', builder: this.buildSelectionFilterMenu, symbolStartIcon: menuIcon('filter') , symbolEndIcon: menuSubmenuArrow() },
      { content: '显示层级', builder: this.buildHierarchyMenu, symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuSubmenuArrow() }
    ], this.getUIContext(), [this.buildSelectionFilterMenuSizing(), this.buildHierarchyMenuSizing()]))
  }

  @Builder
  buildSelectionFilterMenu() {
    Menu() {
      MenuItemGroup({ header: '图层范围' }) {
        MenuItem({ content: '所有可选图层', symbolStartIcon: menuIcon('layer') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionLayerFilter < 0 && this.viewportStore.selectionDatatypeFilter < 0) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionLayerFilter < 0 && this.viewportStore.selectionDatatypeFilter < 0).onClick(() => { this.viewportStore.selectionLayerFilter = -1; this.viewportStore.selectionDatatypeFilter = -1; })
        MenuItem({ content: `仅 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype}`, symbolStartIcon: menuIcon('layer') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionLayerFilter === this.viewportStore.selectedLayerNumber && this.viewportStore.selectionDatatypeFilter === this.viewportStore.selectedDatatype) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionLayerFilter === this.viewportStore.selectedLayerNumber && this.viewportStore.selectionDatatypeFilter === this.viewportStore.selectedDatatype)
          .onClick(() => { this.viewportStore.selectionLayerFilter = this.viewportStore.selectedLayerNumber; this.viewportStore.selectionDatatypeFilter = this.viewportStore.selectedDatatype; })
      }
      MenuItemGroup({ header: '图形类型' }) {
        MenuItem({ content: '所有类型', symbolStartIcon: menuIcon('filter') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 0) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionTypeFilter.length === 0).onClick(() => { this.viewportStore.selectionTypeFilter = []; })
        MenuItem({ content: '矩形与多边形', symbolStartIcon: menuIcon('array') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 2 && this.viewportStore.selectionTypeFilter.includes(ShapeType.RECT) && this.viewportStore.selectionTypeFilter.includes(ShapeType.POLYGON)) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionTypeFilter.length === 2 && this.viewportStore.selectionTypeFilter.includes(ShapeType.RECT) && this.viewportStore.selectionTypeFilter.includes(ShapeType.POLYGON)).onClick(() => { this.viewportStore.selectionTypeFilter = [ShapeType.RECT, ShapeType.POLYGON]; })
        MenuItem({ content: '路径', symbolStartIcon: menuIcon('path') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.PATH) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.PATH).onClick(() => { this.viewportStore.selectionTypeFilter = [ShapeType.PATH]; })
        MenuItem({ content: '文字', symbolStartIcon: menuIcon('text') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.TEXT) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.TEXT).onClick(() => { this.viewportStore.selectionTypeFilter = [ShapeType.TEXT]; })
      }

    }
    .attributeModifier(menuStyle(this.buildSelectionFilterMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildHierarchyMenu() {
    Menu() {
      MenuItemGroup({ header: '显示层级' }) {
        MenuItem({ content: '层级 1 · 当前 Cell', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 1) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 1).onClick(() => viewService.setHierarchyDepth(1))
        MenuItem({ content: '层级 2', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 2) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 2).onClick(() => viewService.setHierarchyDepth(2))
        MenuItem({ content: '层级 3', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 3) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 3).onClick(() => viewService.setHierarchyDepth(3))
        MenuItem({ content: '层级 4', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 4) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 4).onClick(() => viewService.setHierarchyDepth(4))
        MenuItem({ content: '层级 5', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 5) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 5).onClick(() => viewService.setHierarchyDepth(5))
        MenuItem({ content: '全部层级', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 32) })
        .attributeModifier(MENU_ITEM_STYLE)
        .selected(this.docStore.hierarchyDepth === 32).onClick(() => viewService.setHierarchyDepth(32))
      }

    }
    .attributeModifier(menuStyle(this.buildHierarchyMenuSizing(), this.getUIContext()))
  }

  @Builder
  buildInstanceScopeMenu() {
    Menu() {
      MenuItemGroup({ header: '编辑范围' }) {
        MenuItem({ content: '仅修改当前实例…', symbolStartIcon: menuIcon('instance') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.confirmLocalInstance())
        MenuItem({ content: '编辑全部引用', symbolStartIcon: menuIcon('cell') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.enterSharedInstanceDefinition())
      }
      MenuItemGroup({ header: '数组成员' }) {
        MenuItem({ content: '提取成员…', symbolStartIcon: menuIcon('flatten') })
        .attributeModifier(MENU_ITEM_STYLE).onClick(() => this.confirmExtractArrayMember())
      }
    }
    .attributeModifier(menuStyle([
      { content: '仅修改当前实例…', symbolStartIcon: menuIcon('instance') },
      { content: '编辑全部引用', symbolStartIcon: menuIcon('cell') },
      { content: '提取成员…', symbolStartIcon: menuIcon('flatten') }
    ], this.getUIContext()))
  }


  private buildCanvasVerificationMenuSizing(): MenuItemOptions[] {
    const items: MenuItemOptions[] = [
      { content: '运行 DRC', symbolStartIcon: menuIcon('verify') },
      { content: '网络追踪', symbolStartIcon: menuIcon('trace') },
      { content: 'LVS 连通性预检查', symbolStartIcon: menuIcon('verify') }
    ];
    if (this.verifyStore.drcIssues.length > 0) items.splice(1, 0, { symbolStartIcon: menuIcon('warning'), content: '定位首个违规' });
    return items;
  }

  private buildCanvasBooleanMenuSizing(): MenuItemOptions[] {
    const items: MenuItemOptions[] = [
      { content: '合并', symbolStartIcon: menuIcon('union') },
      { content: '相减', symbolStartIcon: menuIcon('subtract') },
      { content: '相交', symbolStartIcon: menuIcon('intersect') },
      { content: '异或', symbolStartIcon: menuIcon('xor') },
      { content: '倒圆角…', symbolStartIcon: menuIcon('path') },
      { content: '放置实例…', labelInfo: 'I', symbolStartIcon: menuIcon('instance') },
      { content: '放置 PCell…', symbolStartIcon: menuIcon('pcell') },
      { content: '展开选中实例…', symbolStartIcon: menuIcon('flatten') },
      { content: '选区组成 Cell…', symbolStartIcon: menuIcon('cell') },
      { content: '端口管理…', symbolStartIcon: menuIcon('cell') }
    ];
    if (this.viewportStore.selectedShapeId >= 0) items.splice(5, 0, { content: '进入子 Cell', symbolStartIcon: menuIcon('cell') });
    return items;
  }

  private buildCanvasSelectionMenuSizing(): MenuItemOptions[] {
    const items: MenuItemOptions[] = [
      { content: '全选', labelInfo: 'Ctrl+A', symbolStartIcon: menuIcon('selectAll') },
      { content: '选择当前层全部', symbolStartIcon: menuIcon('layer') },
      { content: '取消选择', symbolStartIcon: menuIcon('selectNone') }
    ];
    for (const layer of this.layersForDisplay()) items.push({ content: `L${layer.layerNumber}/D${layer.datatype} ${layer.chineseName}`, symbolStartIcon: menuIcon('layer') });
    return items;
  }


  private buildCanvasEditMenuSizing(): MenuItemOptions[] {
    return [
      { symbolStartIcon: menuIcon('copy'), content: '复制', labelInfo: 'Ctrl+C' },
      { symbolStartIcon: menuIcon('paste'), content: '粘贴', labelInfo: 'Ctrl+V' },
      { content: '移动', labelInfo: 'M', symbolStartIcon: menuIcon('move') },
      { content: '阵列复制…', symbolStartIcon: menuIcon('array') },
      { content: '尺寸调整…', symbolStartIcon: menuIcon('size') },
      { symbolStartIcon: menuIcon('delete', true), content: '删除', labelInfo: 'Del' }
    ];
  }

  private buildCanvasViewExportMenuSizing(): MenuItemOptions[] {
    return [
      { content: '框选放大', symbolStartIcon: menuIcon('zoomIn') },
      { symbolStartIcon: menuIcon('measure'), content: '测量距离', labelInfo: 'R' },
      { symbolStartIcon: menuIcon('view'), content: '适配全部', labelInfo: 'F' },
      { symbolStartIcon: menuIcon('reset'), content: '重置视图' },
      { content: '导出 SVG 矢量图…', symbolStartIcon: menuIcon('export') },
      { content: '导出 PNG 图片…', symbolStartIcon: menuIcon('export') },
      { content: '导出 OASIS…', symbolStartIcon: menuIcon('export') }
    ];
  }

  private buildCanvasTransformMenuSizing(): MenuItemOptions[] {
    return [
      { content: '旋转 90°', symbolStartIcon: menuIcon('rotate') },
      { content: '旋转 180°', symbolStartIcon: menuIcon('rotate') },
      { content: '旋转 270°', symbolStartIcon: menuIcon('rotate') },
      { content: '水平镜像', symbolStartIcon: menuIcon('mirror') },
      { content: '垂直镜像', symbolStartIcon: menuIcon('mirror') },
      { content: '放大至 2 倍', symbolStartIcon: menuIcon('zoomIn') },
      { content: '缩小至 0.5 倍', symbolStartIcon: menuIcon('zoomOut') }
    ];
  }

  private buildCanvasAlignMenuSizing(): MenuItemOptions[] {
    return [
      { content: '左对齐', symbolStartIcon: menuIcon('alignLeft') },
      { content: '右对齐', symbolStartIcon: menuIcon('alignRight') },
      { content: '上对齐', symbolStartIcon: menuIcon('alignTop') },
      { content: '下对齐', symbolStartIcon: menuIcon('alignBottom') },
      { content: '水平居中', symbolStartIcon: menuIcon('alignCenter') },
      { content: '垂直居中', symbolStartIcon: menuIcon('alignMiddle') },
      { content: '水平等距', symbolStartIcon: menuIcon('distributeH') },
      { content: '垂直等距', symbolStartIcon: menuIcon('distributeV') },
      { content: '端口连接对齐…', symbolStartIcon: menuIcon('alignCenter') },
      { content: '端口布线…', symbolStartIcon: menuIcon('path') }
    ];
  }

  private buildSelectionFilterMenuSizing(): MenuItemOptions[] {
    return [
      { content: '所有可选图层', symbolStartIcon: menuIcon('layer') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionLayerFilter < 0 && this.viewportStore.selectionDatatypeFilter < 0) },
      { content: `仅 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype}`, symbolStartIcon: menuIcon('layer') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionLayerFilter === this.viewportStore.selectedLayerNumber && this.viewportStore.selectionDatatypeFilter === this.viewportStore.selectedDatatype) },
      { content: '所有类型', symbolStartIcon: menuIcon('filter') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 0) },
      { content: '矩形与多边形', symbolStartIcon: menuIcon('array') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 2 && this.viewportStore.selectionTypeFilter.includes(ShapeType.RECT) && this.viewportStore.selectionTypeFilter.includes(ShapeType.POLYGON)) },
      { content: '路径', symbolStartIcon: menuIcon('path') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.PATH) },
      { content: '文字', symbolStartIcon: menuIcon('text') , symbolEndIcon: menuCheckIcon(this.viewportStore.selectionTypeFilter.length === 1 && this.viewportStore.selectionTypeFilter[0] === ShapeType.TEXT) }
    ];
  }

  private buildHierarchyMenuSizing(): MenuItemOptions[] {
    return [
      { content: '层级 1 · 当前 Cell', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 1) },
      { content: '层级 2', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 2) },
      { content: '层级 3', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 3) },
      { content: '层级 4', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 4) },
      { content: '层级 5', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 5) },
      { content: '全部层级', symbolStartIcon: menuIcon('hierarchy') , symbolEndIcon: menuCheckIcon(this.docStore.hierarchyDepth === 32) }
    ];
  }

  /**
   * LVS 面板（连通性级预检查，非签核）：
   * 参考网表输入 → 运行 → 汇总结论 → 逐网判定列表（点行高亮该网图形）。
   * 未运行时（缺参考网表 / 网表畸形 / 0 网络 / 无布局）以 danger 色显式区分，
   * **绝不把「没跑」渲染成「通过」**。
   */
  @Builder
  buildLvsPanel() {
    Column() {
      SheetGlassHeader({
        title: 'LVS 连通性预检查',
        subtitle: '',
        showClose: true,
        onClose: () => { this.closeLvsPanel(); }
      })

      Scroll() {
        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text('参考网表（SPICE / CDL）')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(COLORS.ink)
              .layoutWeight(1)
            // 严守官方规范：PasteButton 不挂载通用属性修饰器，保持高对比实色背景与字色
            Row() {
              PasteButton({ icon: PasteIconStyle.LINES, text: PasteDescription.PASTE, buttonType: ButtonType.Capsule })
                .fontSize(12)
                .fontColor(Color.White)
                .iconColor(Color.White)
                .backgroundColor(COLORS.primary)
                .padding({ top: 6, bottom: 6, left: 12, right: 12 })
                .onClick((_event: ClickEvent, pasteResult: PasteButtonOnClickResult) => {
                  if (pasteResult === PasteButtonOnClickResult.SUCCESS) {
                    pasteboard.getSystemPasteboard().getData().then((data) => {
                      const pasted: string = data.getPrimaryText() ?? '';
                      if (pasted.trim().length > 0) {
                        if (pasted !== this.verifyStore.lvsNetlistText) {
                          this.invalidateLvsResult();
                        }
                        this.verifyStore.lvsNetlistText = pasted;
                        this.verifyStore.lvsNote = '已从剪贴板粘贴参考 SPICE/CDL 网表';
                      }
                    }).catch(() => {});
                  }
                })
            }
          }
          .width('100%')
          .alignItems(VerticalAlign.Center)

          TextArea({ text: this.verifyStore.lvsNetlistText, placeholder: '.SUBCKT TOP VDD GND OUT\nM1 OUT IN VDD VSS nmos_model W=100n L=30n\n.ENDS' })
            .fontSize(13)
            .fontFamily('monospace')
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .height(120)
            .width('100%')
            .borderRadius(UI.controlRadius)
            .onKeyEvent((e: KeyEvent) => {
              e.stopPropagation();
            })
            .onChange((value: string) => {
              if (value !== this.verifyStore.lvsNetlistText) this.invalidateLvsResult();
              this.verifyStore.lvsNetlistText = value;
            })

          Row({ space: 8 }) {
            Button('载入提取网表', { type: ButtonType.Normal })
              .height(UI.controlHeight)
              .fontSize(UI.fontBody)
              .borderRadius(UI.controlRadius)
              .backgroundColor(COLORS.surfaceMuted)
              .fontColor(COLORS.ink)
              .border({ width: 1, color: COLORS.border })
              .layoutWeight(1)
              .attributeModifier(this.themeState.luminousPointLightModifier())
              .onClick(() => { this.loadExtractedNetlist(); })
            Button('运行 LVS', { type: ButtonType.Normal })
              .height(UI.controlHeight)
              .fontSize(UI.fontBody)
              .borderRadius(UI.controlRadius)
              .backgroundColor(COLORS.primary)
              .fontColor(Color.White)
              .layoutWeight(1)
              .attributeModifier(this.themeState.luminousPointLightModifier())
              .onClick(() => { this.runLvsCheck(); })
          }
          .width('100%')

          if (this.verifyStore.lvsNote.length > 0) {
            Text(this.verifyStore.lvsNote)
              .fontSize(11)
              .fontColor(COLORS.warning)
              .lineHeight(16)
              .width('100%')
          }

          if (this.verifyStore.lvsHasResult) {
            Column({ space: 6 }) {
              Text(verifyService.lvsStatusLabel(this.verifyStore.lvsResult.status))
                .fontSize(13)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.verifyStore.lvsResult.matched ? COLORS.success : COLORS.danger)
              Text(`版图 ${this.verifyStore.lvsResult.layoutNetCount} 网 · 参考 ${this.verifyStore.lvsResult.schematicNetCount} 网 · 匹配 ${this.verifyStore.lvsResult.matchedNets}`)
                .fontSize(11)
                .fontColor(COLORS.muted)
              Progress({
                value: this.verifyStore.lvsResult.matchedNets,
                total: Math.max(1, this.verifyStore.lvsResult.schematicNetCount),
                type: ProgressType.Linear
              })
                .color(this.verifyStore.lvsResult.matched ? COLORS.success : COLORS.primary)
                .backgroundColor(COLORS.surfaceMuted)
                .style({ strokeWidth: 6 })
                .width('100%')
              if (this.verifyStore.lvsResult.openNets.length > 0) {
                Text(`开路 ${this.verifyStore.lvsResult.openNets.length}：${this.verifyStore.lvsResult.openNets.join('、')}`)
                  .fontSize(11)
                  .fontColor(COLORS.danger)
                  .width('100%')
              }
              if (this.verifyStore.lvsResult.shortNets.length > 0) {
                Text(`短路 ${this.verifyStore.lvsResult.shortNets.length}：${this.verifyStore.lvsResult.shortNets.join('、')}`)
                  .fontSize(11)
                  .fontColor(COLORS.danger)
                  .width('100%')
              }
              if (this.verifyStore.lvsResult.extraNets.length > 0) {
                Text(`多余网络 ${this.verifyStore.lvsResult.extraNets.length}：${this.verifyStore.lvsResult.extraNets.join('、')}`)
                  .fontSize(11)
                  .fontColor(COLORS.warning)
                  .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(12)
            .borderRadius(UI.controlRadius)
            .attributeModifier(this.themeState.luminousSheetSurfaceModifier(UI.controlRadius))
          }

          Text('逐网判定')
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.muted)
            .width('100%')

          Column() {
            if (this.verifyStore.lvsReports.length === 0) {
              Text('暂无网络结果')
                .fontSize(12)
                .fontColor(COLORS.muted)
                .width('100%')
                .padding({ top: 6, bottom: 6 })
            }
            ForEach(this.verifyStore.lvsReports, (report: LvsNetReport) => {
              Row() {
                Text(report.verdictLabel)
                  .fontSize(11)
                  .fontColor(report.ok ? COLORS.success :
                    (report.verdict === 'anonymous' ? COLORS.muted : COLORS.danger))
                  .width(138)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(report.name)
                  .fontSize(11)
                  .fontColor(COLORS.ink)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(`${report.shapeCount} 图形/${report.layers.length} 层`)
                  .fontSize(10)
                  .fontColor(COLORS.muted)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(UI.controlRadius)
              .attributeModifier(this.themeState.luminousPointLightModifier())
              .onClick(() => { this.selectLvsNet(report); })
            }, (report: LvsNetReport, index: number) => `${index}_${report.name}`)
          }
          .width('100%')
          .padding(8)
          .borderRadius(UI.controlRadius)
          .attributeModifier(this.themeState.luminousSheetSurfaceModifier(UI.controlRadius))
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 28 + Math.max(0, this.safeAreaBottomVp) })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clipContent(ContentClipMode.SAFE_AREA)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .zIndex(ZIndexTokens.lvsPanel)
  }

  build() {
    WithTheme({
      theme: ThemeManager.nativeTheme(),
      colorMode: this.themeState.isDark ? ThemeColorMode.DARK : ThemeColorMode.LIGHT
    }) {
      this.workbench()
    }
  }

  @Builder
  private workspaceContent() {
    Column() {
      // 桌面端保留独立模块导航栏，版图画布获得连续的主工作区。
      Row() {
        if (this.isDesktopWorkspace()) {
          DesktopModuleRail({
            currentModule: this.viewportStore.currentModule,
            drcIssueCount: this.verifyStore.drcIssues.length,
            searchActive: this.panelStore.showSearchPanel,
            libraryActive: this.panelStore.showLibraryPanel,
            pythonActive: this.panelStore.showPythonPanel,
            techActive: this.panelStore.showTechnologyPanel || this.panelStore.showLayerStackPanel,
            compareActive: this.panelStore.showComparePanel,
            aiActive: this.panelStore.showAiPanel,
            macroActive: this.panelStore.showMacroPanel,
            searchAction: () => { this.openExclusiveUtilitySheet('search'); },
            libraryAction: () => {
              this.docStore.libraryEntries = componentLibraryService.list();
              this.openExclusiveUtilitySheet('library');
            },
            pythonAction: () => {
              if (this.panelStore.showPythonPanel) {
                this.closeAssistantPanel('python');
              } else {
                this.openPythonPanel(false);
              }
            },
            technologyAction: () => { this.openExclusiveUtilitySheet('technology'); },
            compareAction: () => { this.openExclusiveUtilitySheet('compare'); },
            aiAction: () => { this.toggleAiPanel(); },
            macroAction: () => { this.openExclusiveUtilitySheet('macro'); },
            projectAction: () => {
              this.docStore.workspaceHistory = workspaceService.listHistory(this.docStore.activeWorkspaceId);
              this.openExclusiveUtilitySheet('project');
            },
            shortcutAction: () => { this.openExclusiveUtilitySheet('shortcut'); },
            openAppearanceAction: () => { this.showAppearanceSheet = true; },
            selectModuleAction: (module: WorkModule, label: string) => {
              this.selectModule(module, label);
            }
          })
        }
        if (this.viewportStore.currentModule === WorkModule.Data) {
          DataWorkspace({
            compact: this.isCompact(),
            tabletMode: !this.isDesktopWorkspace() && !this.isCompact(),
            files: unwrapObserved(this.docStore.recentFiles),
            currentFilePath: this.docStore.currentFilePath,
            activeDocumentTitle: this.currentFileDisplayName() || '未命名版图',
            docLibName: this.docStore.docLibName,
            docCellCount: this.docStore.docCellCount,
            docElementCount: this.docStore.docElementCount,
            docTopCellName: this.docStore.docTopCellName,
            cellTree: unwrapObserved(this.docStore.cellTreeData),
            currentTopCellId: this.docStore.currentTopCellId,
            openFileAction: () => { this.pickAndParseFile(); },
            chooseFileAction: (file: RecentFile) => { this.loadRecentFile(file); },
            showLayoutAction: () => this.selectModule(WorkModule.Layout, '版图'),
            enterCellAction: (id: number, name: string) => {
              if (!this.enterCellDefinition(id)) return;
              this.selectModule(WorkModule.Layout, '版图');
              this.panelStore.statusText = `已进入 ${name}`;
            },
            quickScanAction: () => { this.runQuickScan(); }
          }).layoutWeight(1).transition(this.moduleStageTransition(TransitionEdge.BOTTOM))
        } else if (!this.isDesktopWorkspace() && this.isCompact() && this.viewportStore.currentModule === WorkModule.Verify) {
          WorkbenchInspector({
            currentModule: WorkModule.Verify,
            editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
            panelWidth: this.panelStore.windowWidthVp,
            issues: unwrapObserved(this.verifyStore.drcIssues),
            highlightedViolationId: this.verifyStore.highlightedViolationId,
            lastDrcElapsed: this.verifyStore.lastDrcElapsed,
            runDrcAction: () => this.runDrcBackground(),
            drcConfigurationChangedAction: () => this.onDrcConfigurationChanged(),
            locateIssueAction: (issue: DrcIssue) => {
              this.selectModule(WorkModule.Layout, '版图');
              this.locateIssue(issue);
            }
          }).layoutWeight(1).transition(this.moduleStageTransition(TransitionEdge.BOTTOM))
        } else {
        // 外层 SideBarContainer：左侧栏 + 主区（lg/md Embed 内联，sm Overlay 浮层）
        SideBarContainer(this.sidebarContainerType()) {
        // 左侧栏内容（SideBarContainer.showSideBar 控制显隐，无需条件渲染）
        Column() {
        WorkbenchSidebar({
          visible: true,
          showShortcutFooter: !this.isDesktopWorkspace(),
          sidebarWidth: this.sidebarWidth(),
          layers: this.layersForDisplay(),
          selectedLayerNumber: this.viewportStore.selectedLayerNumber,
          selectedDatatype: this.viewportStore.selectedDatatype,
          cellTree: unwrapObserved(this.docStore.cellTreeData),
          cellDefinitionCount: this.placeableCells.length,
          currentTopCellId: this.docStore.currentEditingCellId,
          rootTopCellId: editService.getTopCellId(),
          currentEditingCellName: this.docStore.currentEditingCellName,
          presetNames: unwrapObserved(this.docStore.layerPresetNames),
          savePresetAction: () => {
            this.presetSaveContext = this.parameterDialogContext();
            this.openCanvasDialog(this.presetSaveController);
          },
          applyPresetAction: (name: string) => this.applyViewPreset(name),
          deletePresetAction: (name: string) => this.confirmDeleteViewPreset(name),
          toggleLayerAction: (layerNumber: number, visible: boolean, datatype: number) => {
            this.setLayerVisible(layerNumber, visible, datatype);
          },
          selectLayerAction: (layer: UiLayer) => {
            this.viewportStore.selectedLayerNumber = layer.layerNumber;
            this.viewportStore.selectedDatatype = layer.datatype;
            this.panelStore.statusText = `已激活 L${layer.layerNumber}/D${layer.datatype} ${layer.englishName}`;
          },
          styleLayerAction: (layer: UiLayer) => {
            this.selectLayer(layer);
          },
          addLayerAction: () => { this.addNewLayerQuick(); },
          clearLayerAction: (layerNumber: number, datatype: number) => { this.clearShapesOnLayer(layerNumber, datatype, false); },
          deleteLayerAction: (layerNumber: number, datatype: number) => { this.deleteLayerWithUndo(layerNumber, datatype, true); },
          deleteEmptyLayersAction: () => { this.deleteAllEmptyLayersWithUndo(); },
          openShortcutAction: () => {
            this.panelStore.showShortcutPanel = true;
          },
          setTopCellAction: (cellId: number, cellName: string) => {
            if (!this.enterCellDefinition(cellId)) return;
            this.panelStore.statusText = `已切换到 Cell: ${cellName}`;
            if (!this.canvasKeyboardBlocked()) {
              try {
                this.getUIContext().getFocusController().requestFocus('layout-canvas-keyboard');
              } catch (error) {
                console.warn(`[Index] Cell navigation canvas focus unavailable: ${error}`);
              }
            }
          },
          newCellAction: () => {
            this.openNewCellDialog();
          },
          placeCellInstanceAction: (cellId: number) => {
            this.openInstanceDialogForCell(cellId);
          },
          deleteCellAction: (cellId: number) => {
            this.confirmDeleteCell(cellId);
          },
          renameCellAction: (cellId: number) => {
            this.openRenameCellDialog(cellId);
          },
          flattenCellAction: (cellId: number) => {
            this.flattenCellInstances(cellId);
          },
          cellMaintenanceAction: () => {
            this.openCanvasDialog(this.cellMaintenanceController);
          },
          openPCellAction: () => {
            this.openPCellDialog();
          },
          openCurveAction: (kind: string) => {
            this.openCurveDialog(kind);
          },
          makeCellFromSelectionAction: () => {
            this.openMakeCellDialog();
          },
          arrayCopySelectionAction: () => {
            this.openArrayCopyDialog();
          },
          lockLayerAction: (layerNumber: number, datatype: number) => {
            this.toggleLayerLock(layerNumber, datatype);
          },
          selectableLayerAction: (layerNumber: number, datatype: number, selectable: boolean) => this.setLayerSelectable(layerNumber, datatype, selectable),
          selectAllOnLayerAction: (layerNumber: number, datatype: number) => {
            this.selectAllOnLayer(layerNumber, datatype);
          },
          importLypAction: () => {
            this.importLypFile();
          },
          exportLypAction: () => {
            this.exportLypFile();
          }
        })
        }.width('100%').height('100%')
          .onAreaChange((oldValue: Area, newValue: Area) => this.rememberPanelWidth(true, Number(newValue.width)))

        // 主区：右侧检查器作为第二层 SideBarContainer（lg Embed 内联，md/sm Overlay 浮层）
        SideBarContainer(this.inspectorContainerType()) {
          // 右侧检查器：SideBarContainer 的第一个子组件是 sidebar；
          // sideBarPosition(End) 只控制它贴到右侧，不会交换两个子组件的语义。
          Column() {
          WorkbenchInspector({
            visible: true,
            editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
              desktopCanvasFirst: this.isDesktopWorkspace(),
            panelWidth: this.inspectorWidth(),
            currentModule: this.viewportStore.currentModule,
            layers: this.layersForDisplay(),
            issues: unwrapObserved(this.verifyStore.drcIssues),
            selectedLayerNumber: this.viewportStore.selectedLayerNumber,
          selectedDatatype: this.viewportStore.selectedDatatype,
            selectedShapeId: this.viewportStore.selectedShapeId,
            zoomPercent: this.viewportStore.zoomPercent,
            highlightedViolationId: this.verifyStore.highlightedViolationId,
            selectedShape: this.viewportStore.selectedShapeId >= 0 ? editService.getShapeById(this.viewportStore.selectedShapeId) ?? null : null,
            lastDrcElapsed: this.verifyStore.lastDrcElapsed,
            docLibName: this.docStore.docLibName,
            docCellCount: this.docStore.docCellCount,
            docElementCount: this.docStore.docElementCount,
            docTopCellName: this.docStore.docTopCellName,
            currentFilePath: this.docStore.currentFilePath,
            selectLayerAction: (layer: UiLayer) => {
              this.selectLayer(layer);
            },
            toggleLayerAction: (layerNumber: number, datatype: number) => {
              this.toggleLayer(layerNumber, datatype);
            },
            runDrcAction: () => {
              this.runDrcBackground();
            },
            drcConfigurationChangedAction: () => this.onDrcConfigurationChanged(),
            locateIssueAction: (issue: DrcIssue) => {
              this.locateIssue(issue);
            },
            openFileAction: () => {
              this.pickAndParseFile();
            },
            quickScanAction: () => {
              this.runQuickScan();
            },
            onShapePropertySubmit: (shapeId: number, property: string, value: string) => {
              this.updateShapeProperty(shapeId, property, value);
            }
          })
          }.width('100%').height('100%')
            .onAreaChange((oldValue: Area, newValue: Area) => this.rememberPanelWidth(false, Number(newValue.width)))

          // 画布区
          Column() {
          // 手机和平板保留水平工具栏；桌面端工具栏位于白画布左侧。
          if (!this.isDesktopWorkspace()) {
            DrawingToolbar({
            draftStore: this.draftControlStore,
            measureStore: this.measureStore,
            multiSelectAdditive: this.viewportStore.multiSelectAdditive,
            hierarchyDepth: this.docStore.hierarchyDepth,
            curveAction: (name: string) => this.openCurveDialog(name),
            interactiveCurveAction: (kind: string) => this.activateInteractiveCurve(kind),
            activeCurveKind: this.viewportStore.interactiveCurveKind,
            currentTool: this.viewportStore.currentTool,
            editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
            isCompact: this.isCompact(),
            routingModeChangeAction: (mode: RoutingMode) => { this.viewportStore.routingMode = mode; },
            pathWidthChangeAction: (w: string) => { this.draftControlStore.pathWidthStr = w; },
            toggleAdditiveSelectAction: () => { this.viewportStore.multiSelectAdditive = !this.viewportStore.multiSelectAdditive; },
            selectAllAction: () => { this.selectAllShapes(); },
            clearSelectionAction: () => { this.handleShortcut(ShortcutAction.DESELECT); },
            switchMoveToolAction: () => { this.switchToMoveTool(); },
            fitAllAction: () => { this.fitAllShapes(); },
            resetViewAction: () => { this.resetView(); },
            viewBackAction: () => { this.viewBack(); },
            setHierarchyDepthAction: (d: number) => { viewService.setHierarchyDepth(d); },
            exactCreateRectAction: (minX: number, minY: number, maxX: number, maxY: number): boolean =>
              this.createRectShape({ x: minX, y: minY }, { x: maxX, y: maxY }),
            viewportCenterProvider: (): Point => this.currentViewportWorldCenter(),
            placeInstanceDialogAction: () => { this.openInstanceDialogForCell(-1); },
            placePCellDialogAction: () => { this.openPCellDialog(); },
            makeCellFromSelectionAction: () => { this.openMakeCellDialog(); },
            arrayCopySelectionAction: () => { this.openArrayCopyDialog(); },
            selectToolAction: (tool: ActiveTool, label: string) => {
              this.viewportStore.interactiveCurveKind = '';
              if (tool === ActiveTool.Instance) {
                this.activateInstanceToolSmart();
                return;
              }
              this.exitStampSession();
              this.viewportStore.currentTool = tool;
              this.panelStore.statusText = `当前工具: ${label}`;
            }
            })
          }
          if (!this.isDesktopWorkspace()) {
          EditorToolbar({
            isCompact: this.isToolbarCompact(),
            editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
            zoomPercent: this.viewportStore.zoomPercent,
            moveToolActive: this.viewportStore.currentTool === ActiveTool.Move,
            canUndo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanUndo,
            canRedo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanRedo,
            hasSelection: this.viewportStore.selectedShapeId >= 0,
            // TOOLBAR-1: 传入选中数量，对齐按钮需 ≥2 才启用
            selectionCount: this.viewportStore.selectedShapeCount,
            undoAction: () => {
              this.undoEdit();
            },
            redoAction: () => {
              this.redoEdit();
            },
            duplicateAction: () => {
              this.duplicateSelection();
            },
            deleteAction: () => {
              this.removeSelectedShape();
            },
            moveToolAction: () => {
              this.switchToMoveTool();
            },
            alignLeftAction: () => {
              this.alignSelection(AlignType.LEFT, '左对齐');
            },
            alignRightAction: () => {
              this.alignSelection(AlignType.RIGHT, '右对齐');
            },
            alignTopAction: () => {
              this.alignSelection(AlignType.TOP, '上对齐');
            },
            alignBottomAction: () => {
              this.alignSelection(AlignType.BOTTOM, '下对齐');
            },
            alignCenterAction: () => {
              this.alignSelection(AlignType.CENTER_H, '水平居中');
            },
            alignCenterVAction: () => {
              this.alignSelection(AlignType.CENTER_V, '垂直居中');
            },
            placeInstanceAction: () => {
              this.openInstanceDialog();
            },
            traceAction: () => {
              this.traceNets();
            },
            zoomAction: (delta: number) => {
              this.setZoom(delta);
            },
            resetViewAction: () => {
              this.resetView();
            },
            geometrySnapEnabled: this.viewportStore.geometrySnapEnabled,
            routingModeLabel: routingConstraintService.modeLabel(this.viewportStore.routingMode),
            routingLocked: this.viewportStore.routingMode !== RoutingMode.FREE,
            touchLoupeEnabled: this.viewportStore.touchLoupeEnabled,
            multiSelectAdditive: this.viewportStore.multiSelectAdditive,
            toggleGeometrySnapAction: () => { this.toggleGeometrySnapQuick(); },
            cycleRoutingModeAction: () => { this.cycleRoutingModeQuick(); },
            toggleTouchLoupeAction: () => { this.toggleTouchLoupeQuick(); },
            toggleMultiSelectAdditiveAction: () => { this.toggleMultiSelectAdditiveQuick(); },
            // TRANSFORM-1: 工具栏旋转/镜像按钮
            rotate90Action: () => {
              this.transformSelection('rotate', 90);
            },
            mirrorHAction: () => {
              this.transformSelection('mirror', 0);
            }
          })
          }
          if (this.isDesktopWorkspace()) {
            Row() {
              CanvasViewToolbar({
                viewMode: this.viewportStore.currentViewMode === ViewMode.VIEWER ? '查看' : '编辑',
                compactMode: this.viewportStore.canvasViewportWidth < 1220,
                zoomPercent: this.viewportStore.zoomPercent,
                canUndo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanUndo,
                canRedo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanRedo,
                editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
                hasSelection: this.viewportStore.selectedShapeCount > 0 || this.viewportStore.selectedShapeId >= 0,
                selectionCount: this.viewportStore.selectedShapeCount,
                moveToolActive: this.viewportStore.currentTool === ActiveTool.Move,
                activeLayerNumber: this.viewportStore.selectedLayerNumber,
                activeDatatype: this.viewportStore.selectedDatatype,
                activeLayerColor: this.activeSelectedLayerColor(),
                activeLayerLabel: this.activeSelectedLayerShortLabel(),
                scopeText: this.viewportStore.instanceScopeLabel,
                gridSnapEnabled: this.viewportStore.snapEnabled,
                geometrySnapEnabled: this.viewportStore.geometrySnapEnabled,
                routingModeLabel: routingConstraintService.modeLabel(this.viewportStore.routingMode),
                routingLocked: this.viewportStore.routingMode !== RoutingMode.FREE,
                multiSelectAdditive: this.viewportStore.multiSelectAdditive,
                undoAction: () => this.undoEdit(),
                redoAction: () => this.redoEdit(),
                duplicateAction: () => this.duplicateSelection(),
                deleteAction: () => this.removeSelectedShape(),
                moveToolAction: () => this.switchToMoveTool(),
                rotate90Action: () => this.transformSelection('rotate', 90),
                mirrorHAction: () => this.transformSelection('mirror', 0),
                mirrorVAction: () => this.transformSelection('mirror', 1),
                alignAction: (m: string) => {
                  const t = this.alignTypeFromString(m);
                  if (t !== null) this.alignSelection(t, this.alignLabel(t));
                },
                booleanAction: (op: 'merge' | 'subtract' | 'dialog') => {
                  if (op === 'dialog') {
                    this.openCanvasDialog(this.booleanPreviewController);
                  } else {
                    this.applyBooleanOp(op);
                  }
                },
                traceAction: () => this.traceNets(),
                openLayerStyleAction: () => { this.openExclusiveUtilitySheet('layer_style'); },
                zoomAction: (delta: number) => this.setZoom(delta * 20),
                fitAction: () => this.fitAllShapes(),
                modeAction: (mode: string) => this.setViewMode(mode === '查看' ? ViewMode.VIEWER : ViewMode.EDIT),
                toggleGridSnapAction: () => this.toggleGridSnapQuick(),
                toggleGeometrySnapAction: () => this.toggleGeometrySnapQuick(),
                cycleRoutingModeAction: () => this.cycleRoutingModeQuick(),
                toggleMultiSelectAdditiveAction: () => this.toggleMultiSelectAdditiveQuick()
              })
              if (this.viewportStore.canvasViewportWidth >= 1100) {
                Row({ space: 4 }) {
                  Text(`选择：${this.viewportStore.selectedShapeCount} 个图形`).fontSize(12).fontColor(COLORS.ink)
                  WorkbenchIcon({ name: 'chevronDown', iconSize: 11, color: COLORS.muted })
                }
                .height(34)
                .padding({ left: 10, right: 10 })
                .borderRadius(UI.controlRadius)
                .alignItems(VerticalAlign.Center)
                .bindMenu(this.buildSelectionFilterMenu, buildLuminousMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius))

                Row().width(1).height(18).backgroundColor(COLORS.border).margin({ left: 6, right: 6 })

                Row({ space: 4 }) {
                  Text(this.docStore.hierarchyDepth === 32 ? '全部层级' : `层级 ${this.docStore.hierarchyDepth}`).fontSize(11).fontColor(COLORS.muted)
                  WorkbenchIcon({ name: 'chevronDown', iconSize: 11, color: COLORS.muted })
                }
                .height(34)
                .padding({ left: 8, right: 12 })
                .borderRadius(UI.controlRadius)
                .alignItems(VerticalAlign.Center)
                .bindMenu(this.buildHierarchyMenu, buildLuminousMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius))

                Text('单位：µm').fontSize(12).fontColor(COLORS.ink).margin({ right: 14 })
              } else {
                Row({ space: 4 }) {
                  Text('选项').fontSize(12).fontColor(COLORS.ink)
                  WorkbenchIcon({ name: 'chevronDown', iconSize: 11, color: COLORS.muted })
                }
                .height(36)
                .padding({ left: 10, right: 10 })
                .margin({ right: 8 })
                .borderRadius(UI.controlRadius)
                .alignItems(VerticalAlign.Center)
                .bindMenu(this.buildCompactCanvasOptions, buildLuminousMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius))
              }
            }.height(44).width('100%')
              .backgroundColor(this.themeState.isLuminousBackgroundEnabled()
                ? this.themeState.luminous.translucentCardColor
                : COLORS.surface)
              .border({ width: { bottom: 0.8 }, color: COLORS.border })
          }
          if (this.viewportStore.instanceScopeLabel.length > 0 &&
            (this.isDesktopWorkspace() || !this.isCompact() || this.viewportStore.pickedPlacement !== null || editService.getCurrentCellId() !== editService.getTopCellId())) {
          Row({ space: 8 }) {
            Text('共享定义').fontSize(UI.fontCaption).fontColor(COLORS.primary)
              .padding({ left: 6, right: 6, top: 4, bottom: 4 }).backgroundColor(COLORS.primarySoft).borderRadius(UI.chipRadius)
            Text(this.viewportStore.instanceScopeSummary || this.docStore.currentEditingCellName).fontSize(UI.fontCaption).fontColor(COLORS.ink).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .accessibilityText(this.viewportStore.instanceScopeLabel).bindTips(this.viewportStore.instanceScopeLabel)
            Button('范围', { type: ButtonType.Normal }).height(UI.compactControlHeight).padding({ left: 6, right: 6 })
              .fontSize(UI.fontCaption).fontColor(COLORS.primary).backgroundColor(Color.Transparent).borderRadius(UI.controlRadius)
              .accessibilityText('查看编辑范围与引用影响')
              .onClick(() => this.getUIContext().showAlertDialog({ title: '编辑范围与引用影响', message: this.viewportStore.instanceScopeLabel,
                cornerRadius: UI.dialogRadius, primaryButton: { value: '知道了', action: () => {} } }))
            Row({ space: 3 }) {
              Text('选择过滤').fontSize(10).fontColor(COLORS.ink)
              WorkbenchIcon({ name: 'chevronDown', iconSize: 10, color: COLORS.muted })
            }
            .padding(6)
            .borderRadius(UI.controlRadius)
            .alignItems(VerticalAlign.Center)
            .bindMenu(this.buildSelectionFilterMenu, buildLuminousMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius))

            if (this.viewportStore.pickedPlacement !== null) {
              Button({ type: ButtonType.Normal }) {
                Row({ space: 4 }) {
                  Text('实例操作').fontSize(12).fontColor(COLORS.primary)
                  WorkbenchIcon({ name: 'chevronDown', iconSize: 11, color: COLORS.primary })
                }
                .alignItems(VerticalAlign.Center)
              }
              .height(UI.compactControlHeight)
              .backgroundColor(COLORS.primarySoft)
              .borderRadius(UI.controlRadius)
              .padding({ left: 12, right: 12 })
              .bindMenu(this.buildInstanceScopeMenu, buildLuminousMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius))
            }
          }.width('100%').padding({ left: 10, right: 10 }).constraintSize({ minHeight: 36 })
            .backgroundColor(this.themeState.isLuminousBackgroundEnabled()
              ? this.themeState.luminous.translucentCardColor
              : COLORS.surface)
            .border({ width: { bottom: 0.8 }, color: COLORS.border })
          }
          // The rule controls share the canvas and result dock area.
          Stack({ alignContent: Alignment.TopStart }) {
            Column() {
          Stack({ alignContent: Alignment.TopStart }) {
            LayoutCanvasView({
              preferNativeExpand: this.canPreferNativeExpand(),
              sceneRevision: this.viewportStore.viewWorkspaceSceneRevision + this.docStore.editorRevision * 2 + (this.canPreferNativeExpand() ? 0 : 1),
              sceneDiagnostic: this.viewportStore.viewWorkspaceSceneDiagnostic,
              renderSceneProvider: (): ViewSceneSource[] => this.viewWorkspaceRenderScene(),
              projectedPorts: unwrapObserved(this.viewportStore.projectedPorts),
              onPickPort: (endpoint: PortEndpoint): void => {
                if (this.canvasKeyboardBlocked() || this.docStore.activeNativeJobId.length > 0 || this.importInProgress) return;
                this.pickedPortEndpoint = clonePortEndpointModel(endpoint) as PortEndpoint;
                this.openCanvasDialog(this.portManagerController);
              },
              displayGridNm: this.viewportStore.displayGridNm,
              drawStepNm: this.viewportStore.drawStepNm,
              geometrySnapEnabled: this.viewportStore.geometrySnapEnabled,
              geometrySnapKinds: unwrapObserved(this.viewportStore.geometrySnapKinds),
              smartGuidesEnabled: this.viewportStore.smartGuidesEnabled,
              routingMode: this.viewportStore.routingMode,
              touchLoupeEnabled: this.viewportStore.touchLoupeEnabled,
              multiSelectAdditive: this.viewportStore.multiSelectAdditive,
              selectedShapeCount: this.viewportStore.selectedShapeCount,
              interactiveCurveKind: this.viewportStore.interactiveCurveKind,
              routingModeChangeAction: (mode: RoutingMode): void => {
                this.viewportStore.routingMode = mode;
              },
              interactiveCurveKindChangeAction: (kind: string): void => {
                this.viewportStore.interactiveCurveKind = kind;
              },
              openExactCurveDialogAction: (kind: string): void => {
                this.openCurveDialog(kind);
              },
              selectActiveLayerAction: (ln: number, dt: number): void => {
                this.viewportStore.selectedLayerNumber = ln;
                this.viewportStore.selectedDatatype = dt;
                this.panelStore.statusText = `已切换当前绘图层至 L${ln}/D${dt}`;
              },
              unlockAndShowLayerAction: (ln: number, dt: number): void => {
                this.unlockAndShowLayer(ln, dt);
              },
              duplicateSelectionAction: (): void => { this.duplicateSelection(); },
              rotateSelection90Action: (): void => { this.transformSelection('rotate', 90); },
              mirrorSelectionHAction: (): void => { this.transformSelection('mirror', 0); },
              mirrorSelectionVAction: (): void => { this.transformSelection('mirror', 1); },
              deleteSelectionAction: (): void => { this.removeSelectedShape(); },
              roundCornersAction: (): void => { this.openRoundCornersDialog(); },
              openArrayCopyAction: (): void => { this.openArrayCopyDialog(); },
              alignQuickAction: (m: string): void => {
                const t = this.alignTypeFromString(m);
                if (t !== null) this.alignSelection(t, this.alignLabel(t));
              },
              booleanQuickAction: (op: 'merge' | 'subtract'): void => { this.applyBooleanOp(op); },
              enterSelectedInstanceAction: (): void => { this.enterSelectedInstanceCell(); },
              flattenSelectedInstanceAction: (): void => { this.flattenSelectedInstance(); },
              changeSelectionLayerAction: (ln: number, dt: number): void => { this.changeLayerOfSelected(ln, dt); },
              commitStampAtAction: (x: number, y: number): boolean => { return this.commitCanvasStampAt(x, y); },
              openStampDialogAction: (): void => {
                if (this.draftControlStore.stampIsPCell) this.openPCellDialog();
                else this.openInstanceDialog();
              },
              stampTransformChangedAction: (): void => { this.invalidateStampCache(); },
              exitStampModeAction: (): void => { this.exitStampSession(true); },
              stampTemplateProvider: () => this.provideStampTemplate(),
              continuePathCommitAction: (shapeId: number, pts: Point[], w: number, ptType: number): boolean => {
                return this.commitContinuedPathShape(shapeId, pts, w, ptType);
              },
              requestPathToolAction: (): void => {
                this.viewportStore.currentTool = ActiveTool.Path;
              },
              fitAllAction: (): void => {
                this.fitAllShapes();
              },
              selectionLayerFilter: this.viewportStore.selectionLayerFilter,
              selectionDatatypeFilter: this.viewportStore.selectionDatatypeFilter,
              selectionTypeFilter: unwrapObserved(this.viewportStore.selectionTypeFilter),
              onHitCandidates: (result: HierarchyCandidatesResult): void => {
                if (result.candidates.length === 0) this.viewportStore.pickedPlacement = null;
                this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
              },
              onPickCandidate: (candidate: HierarchyHitCandidate): void => {
                if (candidate.path.length > 0 && candidate.path[0].parentCellId !== editService.getCurrentCellId()) {
                  this.viewportStore.pickedPlacement = null; this.viewportStore.instanceScopeLabel = this.sharedCellScopeText(); return;
                }
                this.viewportStore.pickedPlacement = candidate; this.pickedPlacementRevision = editService.getSessionRevision();
                this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
              },
              onEnterInstancePath: (path: InstancePathStep[]): boolean => {
                if (!editService.enterInstancePath(path)) { this.panelStore.statusText = '实例路径已变化，请重新点选'; return false; }
                this.viewportStore.pickedPlacement = null; this.syncShapesFromEditService(); this.fitAllShapes();
                this.panelStore.statusText = this.sharedCellScopeText(); return true;
              },
              documentKey: this.docStore.activeWorkspaceId,
              editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
              keyboardBlocked: this.canvasKeyboardBlocked(),
              onBoxZoomDone: () => { this.viewportStore.currentTool = ActiveTool.Select; },
              boxZoomAction: (left: number, top: number, width: number, height: number) => {
                this.onCanvasBoxZoom(left, top, width, height);
              },
              renderCellNames: this.renderCellNamesForCanvas(),
            desktopMode: this.isDesktopWorkspace(),
            isCompact: this.isCompact(),
            cursorStore: this.cursorStore,
            measureStore: this.measureStore,
            vertexStore: this.vertexStore,
            draftControlStore: this.draftControlStore,
            snapEnabled: this.viewportStore.snapEnabled,
            gridSize: this.viewportStore.gridSize,
            // INDEX-6: 传递网格显隐开关，使 TOGGLE_GRID 快捷键生效
            gridVisible: this.viewportStore.gridVisible,
            vertexSnapEnabled: this.viewportStore.vertexSnapEnabled,
            vertexSnapThreshold: this.viewportStore.vertexSnapThreshold,
            shapes: $shapes,
            layers: this.layersForDisplay(),
            visibleLayerNumbers: this.visibleLayerNumbers(),
            selectedShapeId: this.viewportStore.selectedShapeId,
            selectedLayerNumber: this.viewportStore.selectedLayerNumber,
          selectedDatatype: this.viewportStore.selectedDatatype,
            currentTool: this.viewportStore.currentTool,
            zoomPercent: this.viewportStore.zoomPercent,
            viewOffsetX: this.viewportStore.viewOffsetX,
            viewOffsetY: this.viewportStore.viewOffsetY,
            highlightedViolation: unwrapObserved(this.verifyStore.highlightedViolation),
            // CANVAS-13: hierarchyDepth 由 Index 统一管理，避免与 LayoutCanvasView 内部状态不同步
            hierarchyDepth: this.docStore.hierarchyDepth,
            selectShapeAction: (shape: Shape) => {
              this.selectShape(shape);
            },
            selectMultipleAction: (ids: number[]) => {
              this.selectMultipleShapes(ids);
            },
            createShapeAction: (start: Point, end: Point): boolean => {
              return this.createRectShape(start, end);
            },
            moveShapeAction: (shapeId: number, deltaX: number, deltaY: number) => {
              this.moveShape(shapeId, deltaX, deltaY);
            },
            requestRenderAction: () => {
              this.syncShapesFromEditService();
            },
            vertexMoveCommittedAction: () => {
              this.panelStore.statusText = '已移动顶点（Ctrl+Z 一步撤销）';
            },
            onEnterCell: (cellId: number) => {
              this.enterCell(cellId);
            },
            onNavigateCellStack: (stackIndex: number) => {
              this.navigateCellStack(stackIndex);
            },
            createPolygonAction: (points: Point[]): boolean => {
              return this.createPolygonShape(points);
            },
            createPathAction: (points: Point[], width: number, pathType?: number): boolean => {
              return this.createPathShape(points, width, pathType ?? 0);
            },
            editContextProvider: () => this.parameterDialogContext(),
            createTextAction: (x: number, y: number, text: string): boolean => this.createTextShape(x, y, text),
            zoomAtAction: (screenX: number, screenY: number, scaleFactor: number) => {
              this.zoomCanvasAt(screenX, screenY, scaleFactor);
            },
            panCanvasAction: (deltaScreenX: number, deltaScreenY: number) => {
              this.panCanvas(deltaScreenX, deltaScreenY);
            },
            viewportChangeAction: (width: number, height: number) => {
              this.updateCanvasViewport(width, height);
            },
                canvasKeyAction: (event: KeyEvent) => { this.handleCanvasKeyEvent(event); }
            })
            if (this.verifyStore.comparisonLayers.length > 0 && this.docStore.currentEditingCellName === this.verifyStore.comparisonCellName) {
              LayoutCompareOverlay({ differences: unwrapObserved(this.verifyStore.comparisonLayers), selectedPair: this.verifyStore.comparisonPair,
                scalePxPerNm: this.viewportStore.zoomPercent / 100, viewOffsetX: this.viewportStore.viewOffsetX, viewOffsetY: this.viewportStore.viewOffsetY })
            }
            if (this.rdbReviewOverlayCurrent()) {
              RdbMarkerOverlay({ item: unwrapObserved(this.verifyStore.rdbMarkerItem), frame: unwrapObserved(this.verifyStore.rdbMarkerFrame),
                zoomPercent: this.viewportStore.zoomPercent, viewOffsetX: this.viewportStore.viewOffsetX, viewOffsetY: this.viewportStore.viewOffsetY })
            }
            if (this.aiStore.pendingAiCommands.length > 0 && this.pendingAiRevision === this.docStore.editorRevision && this.pendingAiSelection === editService.getSelectedIds().join(',')) {
              AiCommandPreview({
                commands: unwrapObserved(this.aiStore.pendingAiCommands),
                context: unwrapObserved(this.aiStore.pendingAiContext),
                shapes: $shapes,
                selectedIds: editService.getSelectedIds(),
                zoomPercent: this.viewportStore.zoomPercent,
                viewOffsetX: this.viewportStore.viewOffsetX,
                viewOffsetY: this.viewportStore.viewOffsetY
              })
            }
            AgentCanvasAuraOverlay({
              isLoading: this.aiStore.aiLoading,
              pendingActive: this.aiStore.aiPendingSummary.length > 0
            })
            if (this.isDesktopWorkspace()) {
              DrawingToolbar({
                draftStore: this.draftControlStore,
                measureStore: this.measureStore,
                multiSelectAdditive: this.viewportStore.multiSelectAdditive,
                hierarchyDepth: this.docStore.hierarchyDepth,
                curveAction: (name: string) => this.openCurveDialog(name),
                interactiveCurveAction: (kind: string) => this.activateInteractiveCurve(kind),
                activeCurveKind: this.viewportStore.interactiveCurveKind,
                currentTool: this.viewportStore.currentTool,
                editable: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT,
                vertical: true,
                availableHeight: this.viewportStore.canvasViewportHeight - 28,
                routingModeChangeAction: (mode: RoutingMode) => { this.viewportStore.routingMode = mode; },
                pathWidthChangeAction: (w: string) => { this.draftControlStore.pathWidthStr = w; },
                toggleAdditiveSelectAction: () => { this.viewportStore.multiSelectAdditive = !this.viewportStore.multiSelectAdditive; },
                selectAllAction: () => { this.selectAllShapes(); },
                clearSelectionAction: () => { this.handleShortcut(ShortcutAction.DESELECT); },
                switchMoveToolAction: () => { this.switchToMoveTool(); },
                fitAllAction: () => { this.fitAllShapes(); },
                resetViewAction: () => { this.resetView(); },
                viewBackAction: () => { this.viewBack(); },
                setHierarchyDepthAction: (d: number) => { viewService.setHierarchyDepth(d); },
                exactCreateRectAction: (minX: number, minY: number, maxX: number, maxY: number): boolean =>
                  this.createRectShape({ x: minX, y: minY }, { x: maxX, y: maxY }),
                viewportCenterProvider: (): Point => this.currentViewportWorldCenter(),
                placeInstanceDialogAction: () => { this.openInstanceDialogForCell(-1); },
                placePCellDialogAction: () => { this.openPCellDialog(); },
                makeCellFromSelectionAction: () => { this.openMakeCellDialog(); },
                arrayCopySelectionAction: () => { this.openArrayCopyDialog(); },
                selectToolAction: (tool: ActiveTool, label: string) => {
                  this.viewportStore.interactiveCurveKind = '';
                  if (tool === ActiveTool.Instance) {
                    this.activateInstanceToolSmart();
                    return;
                  }
                  this.exitStampSession();
                  this.viewportStore.currentTool = tool;
                  this.panelStore.statusText = `当前工具: ${label}`;
                }
              })
                .position({ x: 14, y: 14 })
            }
            this.buildAgentLiveHud()
          }
          .id('hongtu-canvas-stage')
          .layoutWeight(1)
          .width('100%')
          .geometryTransition(this.canvasStageGeometryId(), { follow: true })
          if (this.isDesktopWorkspace() && this.viewportStore.currentModule === WorkModule.Verify) {
            DrcResultsDock({
              issues: unwrapObserved(this.verifyStore.drcIssues),
              highlightedViolationId: this.verifyStore.highlightedViolationId,
              lastDrcElapsed: this.verifyStore.lastDrcElapsed,
              hasRun: this.verifyStore.drcHasRun,
              collapsed: this.verifyStore.drcDockCollapsed,
              runDrcAction: () => this.runDrcBackground(),
              exportRdbEnabled: this.canExportDrcRdb(),
              exportRdbBusy: this.verifyStore.drcRdbExportBusy,
              exportRdbAction: () => { this.exportDrcRdb(); },
              locateIssueAction: (issue: DrcIssue) => this.locateIssue(issue),
              openRulesAction: () => { this.verifyStore.showDrcRules = !this.verifyStore.showDrcRules; this.panelStore.showAiPanel = false; },
              toggleCollapsedAction: () => { this.verifyStore.drcDockCollapsed = !this.verifyStore.drcDockCollapsed; }
            })
          }
            }.width('100%').height('100%')
            if (this.floatingShapePropertiesVisible()) {
              ShapePropertiesPopover({
                docked: false,
                pinned: this.panelStore.propertyPanelPinned,
                togglePinnedAction: () => this.setInspectorPinned(!this.panelStore.propertyPanelPinned),
                panelHeight: Math.min(596, Math.max(160, this.viewportStore.canvasViewportHeight - 28)),
                documentId: this.docStore.activeWorkspaceId,
                revision: this.docStore.editorRevision,
                selectedShape: this.viewportStore.selectedShapeId >= 0 ? editService.getShapeById(this.viewportStore.selectedShapeId) ?? null : null,
                selectedShapes: editService.getSelectedShapes(),
                cells: this.propertyCellOptions(),
                onPropertiesSubmit: (ids: number[], property: string, value: string, documentId: string, revision: number): string =>
                  this.submitSelectedProperties(ids, property, value, documentId, revision),
                layers: this.layersForDisplay(),
                editable: this.selectedPropertiesEditable(),
                onShapePropertySubmit: (id: number, property: string, value: string) => this.updateShapeProperty(id, property, value),
                closeAction: () => { this.panelStore.propertyPanelClosed = true; },
                copyAction: () => { this.copySelection(); },
                deleteAction: () => { this.removeSelectedShape(); },
                enterInstanceAction: () => { this.enterSelectedInstanceCell(); },
                flattenInstanceAction: () => { this.flattenSelectedInstance(); },
                returnCanvasFocusAction: () => { this.restoreCanvasFocusAfterPanelClose(); },
                saveShortcutAction: (saveAs: boolean) => {
                  if (saveAs) this.saveCurrentLayout(true);
                  else this.handleShortcut(ShortcutAction.SAVE);
                }
              })
                .position({ x: this.propertyX(), y: this.propertyY() })
                .zIndex(ZIndexTokens.floatingToolbar + 10)
                .transition(this.floatingTransition(TransitionEdge.END))
            }
            if (this.isDesktopWorkspace() && this.verifyStore.showDrcRules) {
              DrcRulesPopover({
                issues: unwrapObserved(this.verifyStore.drcIssues),
                highlightedViolationId: this.verifyStore.highlightedViolationId,
                lastDrcElapsed: this.verifyStore.lastDrcElapsed,
                panelHeight: Math.max(1, this.verifyStore.drcRulesAreaHeight - 28),
                runDrcAction: () => { this.runDrcBackground(); },
                drcConfigurationChangedAction: () => this.onDrcConfigurationChanged(),
                locateIssueAction: (issue: DrcIssue) => this.locateIssue(issue),
                closeAction: () => { this.verifyStore.showDrcRules = false; }
              }).position({ x: Math.max(72, this.viewportStore.canvasViewportWidth - 416), y: 14 })
                .transition(this.floatingTransition(TransitionEdge.END))
            }
          }
          .layoutWeight(1).width('100%')
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const height: number = Math.floor(newValue.height as number);
            if (Number.isFinite(height) && height > 0 && height !== this.verifyStore.drcRulesAreaHeight) {
              this.verifyStore.drcRulesAreaHeight = height;
            }
          })
        }
        .layoutWeight(1)
        .width('100%')
        .height('100%')
        .backgroundColor(COLORS.canvasBg)
        .id('layout-canvas-context-target')
        .onGestureRecognizerJudgeBegin((event: BaseGestureEvent, current: GestureRecognizer,
          recognizers: Array<GestureRecognizer>): GestureJudgeResult => {
          if (current.isBuiltIn() && current.getType() === GestureControl.GestureType.LONG_PRESS_GESTURE &&
            current.getEventTargetInfo().getId() === 'layout-canvas-context-target' &&
            (this.vertexStore.isEditing() || this.draftControlStore.stampActive || this.viewportStore.interactiveCurveKind.length > 0 ||
              this.viewportStore.currentTool === ActiveTool.Move || this.viewportStore.currentTool === ActiveTool.Pan ||
              this.viewportStore.currentTool === ActiveTool.Rect || this.viewportStore.currentTool === ActiveTool.Polygon ||
              this.viewportStore.currentTool === ActiveTool.Path || this.viewportStore.currentTool === ActiveTool.Text ||
              this.viewportStore.currentTool === ActiveTool.Measure || this.viewportStore.currentTool === ActiveTool.BoxZoom)) {
            return GestureJudgeResult.REJECT;
          }
          return GestureJudgeResult.CONTINUE;
        })
        .bindContextMenu(
          this.buildCanvasContextMenu,
          ResponseType.RightClick,
          buildLuminousContextMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius)
        )
        .bindContextMenu(
          this.buildCanvasContextMenu,
          ResponseType.LongPress,
          buildLuminousContextMenuOptions(undefined, this.themeState.luminous, this.themeState.resolveLuminousRenderMode(), UI.panelRadius)
        )
        }
        .showSideBar(this.isDesktopWorkspace()
          ? this.panelStore.inspectorVisible
          : this.panelStore.inspectorVisible || (!this.isCompact() && this.viewportStore.currentModule === WorkModule.Verify))
        .showControlButton(false)
        .sideBarWidth(this.inspectorWidth())
        .minSideBarWidth(280)
        .maxSideBarWidth(480)
        .autoHide(false)
        .minContentWidth(0)
        .sideBarPosition(SideBarPosition.End)
        .onChange((visible: boolean) => {
          this.panelStore.inspectorVisible = visible;
        })
        .width('100%').height('100%')
        }
        .showSideBar(this.panelStore.sidebarVisible)
        .showControlButton(false)
        .sideBarWidth(this.sidebarWidth())
        .minSideBarWidth(196)
        .maxSideBarWidth(400)
        .autoHide(false)
        .minContentWidth(0)
        .sideBarPosition(SideBarPosition.Start)
        .onChange((visible: boolean) => {
          this.panelStore.sidebarVisible = visible;
        })
        .layoutWeight(1)
        .height('100%')
        .transition(this.floatingTransition(TransitionEdge.BOTTOM))
        }
      }
      .layoutWeight(1)
      .width('100%')

      WorkbenchStatusBar({
        desktopMode: this.isDesktopWorkspace(),
        dataMode: this.viewportStore.currentModule === WorkModule.Data,
        isCompact: this.isCompact(),
        statusText: this.panelStore.statusText,
        documentDirty: this.docStore.documentDirty,
        shapeCount: this.shapes.length,
        visibleLayerCount: this.visibleLayerNumbers().length,
        zoomPercent: this.viewportStore.zoomPercent,
        gridSize: this.viewportStore.gridSize,
        dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits),
        displayGridNm: this.viewportStore.displayGridNm,
        drawStepNm: this.viewportStore.drawStepNm,
        geometrySnapEnabled: this.viewportStore.geometrySnapEnabled,
        geometrySnapKinds: unwrapObserved(this.viewportStore.geometrySnapKinds),
        precisionContextProvider: (): string => this.parameterDialogContext(),
        precisionChangeAction: (settings: PrecisionSettings): boolean => this.applyPrecisionSettings(settings),
        viewMode: this.viewportStore.currentViewMode === ViewMode.VIEWER ? '查看' : '编辑',
        nativeText: this.panelStore.nativeText,
        cursorStore: this.cursorStore
      })
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .padding({
      bottom: this.isDesktopWorkspace() || deviceInfo.sdkApiVersion < 20
        ? Math.max(0, this.safeAreaBottomVp)
        : 68 + Math.min(10, Math.max(4, Math.round(this.safeAreaBottomVp * 0.35)))
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }

  @Builder
  private moduleTabLabel(params: ModuleTabLabelParams) {
    Column({ space: 4 }) {
      WorkbenchIcon({
        name: params.icon,
        iconSize: 24,
        color: params.activeModule === params.module ? COLORS.primary : COLORS.muted
      })
      Text(params.label)
        .fontSize(12)
        .fontColor(params.activeModule === params.module ? COLORS.primary : COLORS.muted)
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .accessibilityText(params.label)
  }

  private moduleTabIndex(): number {
    return this.viewportStore.currentModule === WorkModule.Layout ? 0 : this.viewportStore.currentModule === WorkModule.Verify ? 1 : 2;
  }

  private changeModuleTab(index: number): void {
    this.selectModule(index === 0 ? WorkModule.Layout : index === 1 ? WorkModule.Verify : WorkModule.Data,
      index === 0 ? '版图' : index === 1 ? '验证' : '数据');
  }

  @Builder
  private touchTabContents() {
    TabContent() { if (this.viewportStore.currentModule === WorkModule.Layout) { this.workspaceContent() } }
      .tabBar(this.moduleTabLabel({
        module: WorkModule.Layout,
        label: '版图',
        icon: 'layout',
        activeModule: this.viewportStore.currentModule
      }))
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    TabContent() { if (this.viewportStore.currentModule === WorkModule.Verify) { this.workspaceContent() } }
      .tabBar(this.moduleTabLabel({
        module: WorkModule.Verify,
        label: '验证',
        icon: 'verify',
        activeModule: this.viewportStore.currentModule
      }))
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    TabContent() { if (this.viewportStore.currentModule === WorkModule.Data) { this.workspaceContent() } }
      .tabBar(this.moduleTabLabel({
        module: WorkModule.Data,
        label: '数据',
        icon: 'data',
        activeModule: this.viewportStore.currentModule
      }))
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  private floatingTabWidthVp(): number {
    if (this.panelStore.windowWidthVp < 440) {
      return Math.max(240, this.panelStore.windowWidthVp - 40);
    }
    if (this.panelStore.windowWidthVp < 600) {
      return Math.min(420, this.panelStore.windowWidthVp - 48);
    }
    if (this.panelStore.windowWidthVp <= 840) {
      const ratio: number = this.panelStore.windowWidthVp / Math.max(1, this.panelStore.windowHeightVp);
      return ratio < 0.8 ? 420 : 480;
    }
    return 520;
  }

  private floatingTabSideMarginVp(): number {
    const targetWidth: number = this.floatingTabWidthVp();
    return Math.max(16, Math.round((this.panelStore.windowWidthVp - targetWidth) / 2));
  }

  @Builder
  private buildLuminousAmbientBackground() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: this.themeState.getLuminousBackgroundColors()
        })

      // 右上主散射光晕
      Column()
        .width(320)
        .height(320)
        .borderRadius(160)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 160,
          colors: [
            [this.themeState.getLuminousAmbientOrbs()[0], 0.0],
            ['rgba(0, 0, 0, 0)', 1.0]
          ]
        })
        .position({ x: Math.max(40, this.panelStore.windowWidthVp - 280), y: -60 })

      // 左中辅散射光晕
      Column()
        .width(300)
        .height(300)
        .borderRadius(150)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 150,
          colors: [
            [this.themeState.getLuminousAmbientOrbs()[1], 0.0],
            ['rgba(0, 0, 0, 0)', 1.0]
          ]
        })
        .position({ x: -80, y: Math.max(120, this.panelStore.windowHeightVp * 0.32) })

      // 右下柔光散射球
      Column()
        .width(280)
        .height(280)
        .borderRadius(140)
        .radialGradient({
          center: ['50%', '50%'],
          radius: 140,
          colors: [
            [this.themeState.getLuminousAmbientOrbs()[2], 0.0],
            ['rgba(0, 0, 0, 0)', 1.0]
          ]
        })
        .position({ x: Math.max(60, this.panelStore.windowWidthVp - 240), y: Math.max(200, this.panelStore.windowHeightVp - 220) })
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  private buildLiveJobCapsule() {
    Row({ space: 10 }) {
      LoadingProgress()
        .width(18)
        .height(18)
        .color(COLORS.primary)
      Column({ space: 4 }) {
        Text(this.docStore.nativeJobLabel)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.docStore.nativeJobProgress >= 0) {
          Progress({ value: this.docStore.nativeJobProgress, total: 100, type: ProgressType.Linear })
            .color(COLORS.primary)
            .backgroundColor(COLORS.surfaceMuted)
            .style({ strokeWidth: 4, enableScanEffect: true })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      Button(this.docStore.nativeJobCancelRequested ? '正在取消' : '取消作业', { type: ButtonType.Normal })
        .fontSize(UI.fontCaption)
        .height(30)
        .padding({ left: 12, right: 12 })
        .backgroundColor(COLORS.primarySoft)
        .fontColor(COLORS.primary)
        .borderRadius(Radius.pill)
        .attributeModifier(this.themeState.luminousPointLightModifier())
        .enabled(!this.docStore.nativeJobCancelRequested)
        .onClick(() => this.cancelActiveNativeJob())
    }
    .width(this.isDesktopWorkspace()
      ? Math.min(440, Math.max(260, this.panelStore.windowWidthVp - 120))
      : Math.max(216, this.floatingTabWidthVp() - 24))
    .height(this.docStore.nativeJobProgress >= 0 ? 54 : 48)
    .padding({ left: 16, right: 12 })
    .alignItems(VerticalAlign.Center)
    .attributeModifier(this.themeState.luminousFloatingModifier(Radius.pill, 'thick', this.themeState.elevation('lg')))
    .zIndex(ZIndexTokens.liveJobCapsule)
    .position(this.isDesktopWorkspace()
      ? { x: Math.max(16, (this.panelStore.windowWidthVp - Math.min(440, Math.max(260, this.panelStore.windowWidthVp - 120))) / 2), y: 66 + Math.max(0, this.safeAreaTopVp) }
      : {
        x: Math.max(16, (this.panelStore.windowWidthVp - Math.max(216, this.floatingTabWidthVp() - 24)) / 2),
        y: Math.max(80, this.panelStore.windowHeightVp - 64 - Math.max(8, this.safeAreaBottomVp) - 12 - (this.docStore.nativeJobProgress >= 0 ? 54 : 48))
      })
    .transition(this.floatingTransition(TransitionEdge.BOTTOM))
  }

  private agentCanvasStageWidthVp(): number {
    if (this.viewportStore.canvasViewportWidth > 160) {
      return this.viewportStore.canvasViewportWidth;
    }
    return Math.max(320, this.panelStore.windowWidthVp - (this.isDesktopWorkspace() ? 276 : 0));
  }

  private agentHudWidthVp(): number {
    const stageW: number = this.agentCanvasStageWidthVp();
    if (this.isDesktopWorkspace()) {
      const leftReserved: number = 204;
      const rightReserved: number = this.panelStore.showAiPanel
        ? 484
        : (this.floatingShapePropertiesVisible() ? 268 : 20);
      const available: number = Math.max(248, stageW - leftReserved - rightReserved);
      return Math.min(480, available);
    }
    return Math.min(440, Math.max(240, stageW - 24));
  }

  private agentHudLeftVp(): number {
    const stageW: number = this.agentCanvasStageWidthVp();
    const w: number = this.agentHudWidthVp();
    if (this.isDesktopWorkspace()) {
      const leftReserved: number = 204;
      const rightReserved: number = this.panelStore.showAiPanel
        ? 484
        : (this.floatingShapePropertiesVisible() ? 268 : 20);
      const corridor: number = Math.max(w, stageW - leftReserved - rightReserved);
      return Math.max(76, Math.min(Math.max(76, stageW - w - 12), leftReserved + Math.round((corridor - w) / 2)));
    }
    return Math.max(12, Math.round((stageW - w) / 2));
  }

  private agentHudTopVp(): number {
    return this.docStore.activeNativeJobId.length > 0 ? 68 : 14;
  }

  @Builder
  private buildAgentLiveHud() {
    if (this.aiStore.aiLoading || this.aiStore.aiPendingSummary.length > 0 ||
      (!this.panelStore.showAiPanel && this.aiStore.aiMinimizedNotice.length > 0)) {
      Column() {
        AgentLiveStatusHud({
          isLoading: this.aiStore.aiLoading,
          canCancel: this.aiStore.aiCanCancel,
          pendingSummary: this.aiStore.aiPendingSummary,
          minimizedNotice: this.aiStore.aiMinimizedNotice,
          showAiPanel: this.panelStore.showAiPanel,
          toolCalls: unwrapObserved(this.aiStore.aiToolCalls),
          generationStatus: this.aiStore.aiLoading ? this.panelStore.statusText : '',
          streamingText: this.aiStore.aiStreamingText,
          runStartedAt: this.aiStore.aiRunStartedAt,
          hudWidth: this.agentHudWidthVp(),
          togglePanelAction: () => this.toggleAiPanel(),
          stopAction: () => this.cancelAiGeneration(),
          focusPreviewAction: () => this.focusAiReview(),
          applyPreviewAction: () => this.applyPendingAiCommands(),
          cancelPreviewAction: () => this.cancelPendingAiCommands(),
          dismissNoticeAction: () => { this.aiStore.aiMinimizedNotice = ''; }
        })
      }
      .zIndex(ZIndexTokens.liveJobCapsule + 2)
      .position({ x: this.agentHudLeftVp(), y: this.agentHudTopVp() })
      .transition(this.floatingTransition(TransitionEdge.TOP))
    }
  }

  private activeSelectedLayerColor(): string {
    const found: UiLayer | undefined = this.docStore.layers.find((l: UiLayer): boolean =>
      l.layerNumber === this.viewportStore.selectedLayerNumber && l.datatype === this.viewportStore.selectedDatatype
    );
    return found !== undefined ? found.color : COLORS.primary;
  }

  private activeSelectedLayerShortLabel(): string {
    const found: UiLayer | undefined = this.docStore.layers.find((l: UiLayer): boolean =>
      l.layerNumber === this.viewportStore.selectedLayerNumber && l.datatype === this.viewportStore.selectedDatatype
    );
    if (found === undefined) return '';
    return found.chineseName.trim().length > 0 ? found.chineseName.trim() : found.englishName.trim();
  }

  private hasActiveUtilitySheet(): boolean {
    return this.panelStore.showProjectPanel ||
      this.panelStore.showSearchPanel ||
      this.panelStore.showLibraryPanel ||
      this.panelStore.showViewWorkspacePanel ||
      this.panelStore.showComparePanel ||
      this.panelStore.showTechnologyPanel ||
      this.panelStore.showVerificationPanel ||
      this.panelStore.showMacroPanel ||
      this.panelStore.showFilePanel ||
      this.panelStore.showShortcutPanel ||
      this.panelStore.showLayerStylePanel;
  }

  private closeAllUtilitySheets(): void {
    const wasViewWs: boolean = this.panelStore.showViewWorkspacePanel;
    this.panelStore.showProjectPanel = false;
    this.panelStore.showSearchPanel = false;
    this.panelStore.showLibraryPanel = false;
    this.panelStore.showViewWorkspacePanel = false;
    this.panelStore.showComparePanel = false;
    this.panelStore.showTechnologyPanel = false;
    this.panelStore.showVerificationPanel = false;
    this.panelStore.showMacroPanel = false;
    this.panelStore.showFilePanel = false;
    this.panelStore.showShortcutPanel = false;
    this.panelStore.showLayerStylePanel = false;
    if (wasViewWs) {
      this.closeViewWorkspace();
    }
  }

  private openExclusiveUtilitySheet(kind: string): void {
    const currentlyActive: boolean =
      (kind === 'project' && this.panelStore.showProjectPanel) ||
      (kind === 'search' && this.panelStore.showSearchPanel) ||
      (kind === 'library' && this.panelStore.showLibraryPanel) ||
      (kind === 'view_workspace' && this.panelStore.showViewWorkspacePanel) ||
      (kind === 'compare' && this.panelStore.showComparePanel) ||
      (kind === 'technology' && this.panelStore.showTechnologyPanel) ||
      (kind === 'verification' && this.panelStore.showVerificationPanel) ||
      (kind === 'macro' && this.panelStore.showMacroPanel) ||
      (kind === 'file' && this.panelStore.showFilePanel) ||
      (kind === 'shortcut' && this.panelStore.showShortcutPanel) ||
      (kind === 'layer_style' && this.panelStore.showLayerStylePanel);
    this.closeAllUtilitySheets();
    if (currentlyActive) {
      this.restoreCanvasFocusAfterPanelClose();
      return;
    }
    if (kind === 'project') this.panelStore.showProjectPanel = true;
    else if (kind === 'search') this.panelStore.showSearchPanel = true;
    else if (kind === 'library') this.panelStore.showLibraryPanel = true;
    else if (kind === 'view_workspace') this.panelStore.showViewWorkspacePanel = true;
    else if (kind === 'compare') this.panelStore.showComparePanel = true;
    else if (kind === 'technology') this.panelStore.showTechnologyPanel = true;
    else if (kind === 'verification') this.panelStore.showVerificationPanel = true;
    else if (kind === 'macro') this.panelStore.showMacroPanel = true;
    else if (kind === 'file') this.panelStore.showFilePanel = true;
    else if (kind === 'shortcut') this.panelStore.showShortcutPanel = true;
    else if (kind === 'layer_style') this.panelStore.showLayerStylePanel = true;
  }

  @Builder
  private buildActiveUtilitySheet() {
    if (this.panelStore.showProjectPanel) {
      ProjectPanel({
        panelWidth: Math.min(640, this.panelStore.windowWidthVp - 24),
        actionStatus: this.panelStore.statusText,
        history: unwrapObserved(this.docStore.workspaceHistory),
        recoveryStatus: this.docStore.recoveryStatus,
        engineeringDependencies: unwrapObserved(this.docStore.engineeringDependencies),
        toolBundleAvailable: this.engineeringBundle !== undefined,
        restoreToolContentsAction: () => { this.confirmRestoreEngineeringTools(); },
        recentEdits: editService.getHistorySummary(8),
        recoveryEntries: unwrapObserved(this.docStore.fileRecoveryEntries),
        recoverAction: (item: ProjectRecoveryEntry) => { this.exportRecoveryCopy(item); },
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        createAction: (library: string, top: string, dbu: number) => this.createWorkspaceDocument(library, top, dbu),
        saveProjectAction: () => { this.saveProject(); },
        saveProjectAsAction: () => { this.saveProject(true); },
        openProjectAction: () => { this.openProject(); },
        checkpointAction: () => { this.saveWorkspaceDraft(true); },
        restoreAction: (item: WorkspaceHistory) => { this.restoreWorkspaceHistory(item); }
      })
    } else if (this.panelStore.showSearchPanel) {
      ShapeSearchPanel({
        panelWidth: Math.min(520, this.panelStore.windowWidthVp - 24),
        shapes: this.shapes,
        currentCellId: editService.getCurrentCellId(),
        documentKey: `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        cellNames: this.propertyCellOptions().map((cell: PropertyCellOption): string => cell.name),
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        selectAction: (ids: number[]) => {
          editService.selectMultiple(ids);
          this.viewportStore.selectedShapeId = editService.getSelectedId();
          this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;
          this.shapes = editService.getShapes().slice();
          this.panelStore.statusText = `已选择 ${editService.getSelectedIds().length} 个搜索结果`;
        },
        locateAction: (id: number) => this.locateShapeById(id),
        batchEditAction: (ids: number[]) => {
          this.viewportStore.pickedPlacement = null;
          editService.selectMultiple(ids);
          this.syncShapesFromEditService();
          const appliedIds: number[] = editService.getSelectedIds();
          this.viewportStore.selectedShapeId = appliedIds.length > 0 ? appliedIds[0] : -1;
          if (appliedIds.length > 0) {
            const first: Shape | undefined = this.shapes.find((item: Shape) => item.id === appliedIds[0]);
            if (first !== undefined) {
              this.viewportStore.selectedLayerNumber = first.layerNumber;
              this.viewportStore.selectedDatatype = first.datatype;
            }
            this.ensureFloatingPropertyToolReady();
          }
          this.closeAllUtilitySheets();
          this.panelStore.propertyPanelClosed = false;
          this.panelStore.statusText = `批量属性：当前 Cell 的 ${appliedIds.length} 个可编辑匹配项`;
        },
        enterResultCellAction: (id: number) => {
          const shape: Shape | undefined = this.shapes.find((item: Shape) => item.id === id);
          if (shape !== undefined && this.enterCellDefinition(shape.ownerCellId ?? editService.getTopCellId())) {
            this.locateShapeById(id);
          }
        }
      })
    } else if (this.panelStore.showLibraryPanel) {
      ComponentLibraryPanel({
        panelWidth: Math.min(640, this.panelStore.windowWidthVp - 24),
        actionStatus: this.panelStore.statusText,
        entries: unwrapObserved(this.docStore.libraryEntries),
        selectedPCellName: this.selectedPCellVariant()?.name ?? '',
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        editPCellAction: () => this.openPCellEditor(),
        addPresetAction: (title: string, category: string) => { this.addPCellToLibrary(title, category); },
        addCellAction: (title: string, category: string) => { this.addCellToLibrary(title, category); },
        insertAction: (entry: ComponentLibraryEntry, x: number, y: number) => this.insertLibraryEntry(entry, x, y),
        removeAction: (id: string) => { this.removeLibraryEntry(id); },
        importAction: () => { this.importComponentLibrary(); },
        exportAction: () => { this.exportComponentLibrary(); }
      })
    } else if (this.panelStore.showViewWorkspacePanel) {
      ViewWorkspacePanel({
        documentId: this.docStore.activeWorkspaceId,
        documentTitle: this.docStore.currentDocumentTitle,
        activeViewId: this.viewportStore.viewWorkspaceActiveId,
        cellKeyNames: this.cellKeyNameLookup(),
        views: unwrapObserved(this.viewportStore.viewWorkspaceViews),
        bookmarks: unwrapObserved(this.viewportStore.viewWorkspaceBookmarks),
        overlayDocuments: unwrapObserved(this.viewportStore.viewWorkspaceOverlayDocuments),
        overlayDiagnostics: unwrapObserved(this.viewportStore.viewWorkspaceOverlayDiagnostics),
        overlayContext: this.viewportStore.viewWorkspaceOverlayContext,
        overlayAction: (viewId: string, expectedContext: string, overlays: ViewOverlayState[]): boolean =>
          this.handleViewWorkspaceOverlays(viewId, expectedContext, overlays),
        status: this.viewportStore.viewWorkspaceStatus,
        ready: this.docStore.workspaceReady && this.viewWorkspaceDocumentId === this.docStore.activeWorkspaceId,
        busy: this.viewportStore.viewWorkspaceFileBusy,
        panelWidth: Math.min(620, this.panelStore.windowWidthVp - 24),
        panelHeight: Math.max(240, this.panelStore.windowHeightVp - 120),
        action: (kind: string, id: string, name: string): boolean => this.handleViewWorkspaceAction(kind, id, name),
        fileAction: (importing: boolean, replace: boolean): void => { this.viewWorkspaceFileAction(importing, replace); },
        closeAction: (): void => this.closeViewWorkspace(),
      })
    } else if (this.panelStore.showComparePanel) {
      LayoutComparePanel({
        panelWidth: Math.min(640, this.panelStore.windowWidthVp - 24),
        panelHeight: Math.max(320, this.panelStore.windowHeightVp - 120),
        snapshotProvider: () => this.currentExportInput(),
        inputRevision: `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        revisionProvider: () => `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        locateAction: (layer: NativeLayoutCompareLayer, cell: string) => {
          this.showResultCell(cell);
          this.verifyStore.comparisonPair = `${layer.layerNumber}/${layer.datatype}`;
          this.focusWorldBounds({ minX: layer.minX, minY: layer.minY, maxX: layer.maxX, maxY: layer.maxY });
          this.closeAllUtilitySheets();
          this.panelStore.statusText = `已定位比较差异：${cell} · L${layer.layerNumber}/D${layer.datatype}`;
        },
        resultAction: (result: NativeLayoutCompareResult) => {
          this.verifyStore.comparisonLayers = result.success ? result.layers : [];
          this.verifyStore.comparisonPair = '';
          this.verifyStore.comparisonCellName = result.cellA;
        },
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); }
      })
    } else if (this.panelStore.showTechnologyPanel) {
      TechnologyPanel({
        panelWidth: Math.min(640, this.panelStore.windowWidthVp - 24),
        panelHeight: Math.max(320, this.panelStore.windowHeightVp - 120),
        revisionProvider: () => `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        applyAction: (technology: TechnologyPackage) => this.applyTechnology(technology),
        clearAction: () => this.clearTechnology(),
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        layerStackAction: () => { this.closeAllUtilitySheets(); this.openLayerStack(); }
      })
    } else if (this.panelStore.showVerificationPanel) {
      VerificationPanel({
        panelWidth: Math.min(680, this.panelStore.windowWidthVp - 24),
        panelHeight: Math.max(320, this.panelStore.windowHeightVp - 120),
        inputRevision: `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        documentProvider: () => this.createPythonSnapshot('document'),
        revisionProvider: () => `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
        locateAction: (violation: PythonViolation, cell: string) => { this.showResultCell(cell); this.locateExternalViolation(violation); },
        resultAction: (result: PythonVerificationResult) => {
          this.panelStore.statusText = !result.success
            ? result.error ? `工艺验证失败：${result.error}` : '工艺验证未运行或已失效'
            : `${result.scope}：${result.complete ? (result.passed ? '通过' : '未通过') : '不完整'}，${result.violationCount} 项`;
        },
        technologyAction: () => { this.openExclusiveUtilitySheet('technology'); },
        settingsAction: () => { this.closeAllUtilitySheets(); this.openPythonPanel(false); },
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); }
      })
    } else if (this.panelStore.showMacroPanel) {
      MacroPanel({
        isCompact: this.isCompact(),
        availableWidth: this.panelStore.layerStyleAvailableWidth,
        availableHeight: this.panelStore.layerStyleAvailableHeight,
        macros: this.macroList(),
        lastStatus: this.panelStore.macroStatusText,
        isRecording: this.panelStore.macroRecording,
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        runMacroAction: (macroId: number) => { this.runMacro(macroId); },
        startRecordingAction: (name: string) => {
          try {
            macroService.startRecording(name, this.docStore.activeWorkspaceId);
            this.panelStore.macroRecording = true;
            this.panelStore.macroStatusText = `正在录制宏「${name}」，后续编辑操作将被记录`;
          } catch (error) {
            this.panelStore.macroRecording = macroService.isRecording();
            this.panelStore.macroStatusText = `未开始新录制：${String(error)}`;
          }
        },
        stopRecordingAction: () => {
          try {
            const macro = macroService.stopRecording();
            this.panelStore.macroRecording = false;
            this.panelStore.macroStatusText = macro !== null
              ? `已保存宏「${macro.name}」（${macro.steps.length} 步）` : '未录制到任何步骤，宏未保存';
          } catch (error) {
            this.panelStore.macroRecording = macroService.isRecording();
            this.panelStore.macroStatusText = `宏未保存，待录制内容保留，可重试：${String(error)}`;
          }
        },
        cancelRecordingAction: () => {
          macroService.cancelRecording();
          this.panelStore.macroRecording = false;
          this.panelStore.macroStatusText = '已取消录制';
        }
      })
    } else if (this.panelStore.showFilePanel) {
      FileOpenPanel({
        isCompact: this.isCompact(),
        files: unwrapObserved(this.docStore.recentFiles),
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        chooseFileAction: (file: RecentFile) => {
          this.closeAllUtilitySheets();
          this.loadRecentFile(file);
        }
      })
    } else if (this.panelStore.showShortcutPanel) {
      ShortcutPanel({
        isCompact: this.isCompact(),
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); }
      })
    } else if (this.panelStore.showLayerStylePanel) {
      LayerStylePanel({
        availableHeight: this.panelStore.layerStyleAvailableHeight,
        availableWidth: this.panelStore.layerStyleAvailableWidth,
        actualLayer: this.docStore.layers.find((layer: UiLayer) =>
          layer.layerNumber === this.viewportStore.selectedLayerNumber && layer.datatype === this.viewportStore.selectedDatatype
        ),
        changeStyleAction: (nextLayer: UiLayer) => {
          this.docStore.layers = this.docStore.layers.map((layer: UiLayer): UiLayer =>
            layer.layerNumber === nextLayer.layerNumber && layer.datatype === nextLayer.datatype ? nextLayer : layer
          );
          this.syncLayerVisibilityMirror();
          this.docStore.editorRevision++;
          this.scheduleWorkspaceDraft();
          this.panelStore.statusText = `已更新 L${nextLayer.layerNumber}/D${nextLayer.datatype} 显示设置；真实层号与几何未改变`;
        },
        isCompact: this.isCompact(),
        selectedLayerNumber: this.viewportStore.selectedLayerNumber,
        selectedDatatype: this.viewportStore.selectedDatatype,
        closeAction: () => { this.closeAllUtilitySheets(); this.restoreCanvasFocusAfterPanelClose(); },
        hideLayerAction: (layerNumber: number, datatype: number) => {
          this.setLayerVisible(layerNumber, false, datatype);
          this.closeAllUtilitySheets();
        },
        setCurrentLayerAction: (layerNumber: number, datatype: number) => {
          this.viewportStore.selectedLayerNumber = layerNumber;
          this.viewportStore.selectedDatatype = datatype;
          this.panelStore.statusText = `L${layerNumber}/D${datatype} 已设为当前绘制层`;
          this.closeAllUtilitySheets();
        }
      })
    } else {
      Column().width(1).height(1)
    }
  }

  @Builder
  private buildAppearanceSheet() {
    AppearanceSettingsSheet({
      onClose: () => {
        this.showAppearanceSheet = false;
        this.restoreCanvasFocusAfterPanelClose();
      }
    })
  }

  @Builder
  private touchWorkspace() {
    if (deviceInfo.sdkApiVersion >= 20) {
      HdsTabs({ index: this.moduleTabIndex(), controller: this.hdsTabsController }) { this.touchTabContents() }
        .barMode(BarMode.Fixed).barOverlap(true).vertical(false).barPosition(BarPosition.End).barHeight(64)
        .barFloatingStyle({
          barSideMargin: this.floatingTabSideMarginVp(),
          barBottomMargin: this.isFloatingWindow ? 10 : 8,
          adaptToHandedness: !this.isDesktopWorkspace(),
          gradientMask: { maskColor: '#00000000', maskHeight: 0 },
          systemMaterialEffect: resolveHdsSystemMaterialEffect(this.themeState.luminousIntensityPreset)
        })
        .divider({ mode: DividerMode.NONE }).scrollable(false).animationDuration(0)
        .onChange((index: number) => this.changeModuleTab(index))
        .width('100%')
        .layoutWeight(1)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Tabs({ index: this.moduleTabIndex(), barPosition: BarPosition.End }) { this.touchTabContents() }
        .barMode(BarMode.Fixed).barHeight(64).scrollable(false).animationDuration(0)
        .onChange((index: number) => this.changeModuleTab(index))
        .width('100%')
        .layoutWeight(1)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }

  @Builder
  private workbench() {
    Stack() {
      if (this.themeState.isLuminousBackgroundEnabled()) {
        this.buildLuminousAmbientBackground()
      }

      Column() {
        WorkbenchTitleBar({
          openAppearanceAction: () => { this.showAppearanceSheet = true; },
          newFileAction: () => {
            this.docStore.workspaceHistory = workspaceService.listHistory(this.docStore.activeWorkspaceId);
            this.openExclusiveUtilitySheet('project');
          },
          saveAsAction: () => { this.saveCurrentLayout(true); },
          shareLayoutAction: () => { this.shareCurrentLayoutSnapshot('png'); },
          projectAction: () => {
            this.docStore.workspaceHistory = workspaceService.listHistory(this.docStore.activeWorkspaceId);
            this.openExclusiveUtilitySheet('project');
          },
          searchAction: () => { this.openExclusiveUtilitySheet('search'); },
          commandSearchAction: (): void => { this.openCanvasDialog(this.commandSearchController); },
          libraryAction: () => {
            this.docStore.libraryEntries = componentLibraryService.list();
            this.openExclusiveUtilitySheet('library');
          },
          compareAction: () => { this.openExclusiveUtilitySheet('compare'); },
          viewWorkspaceAction: () => this.openViewWorkspace(),
          rdbReviewAction: () => this.openRdbReview(),
          technologyAction: () => { this.openExclusiveUtilitySheet('technology'); },
          verificationAction: () => { this.openExclusiveUtilitySheet('verification'); },
          isCompact: this.isCompact(),
          isDesktop: this.isDesktopWorkspace(),
          narrowWindow: this.panelStore.windowWidthVp < 1180,
          zoomPercent: this.viewportStore.zoomPercent,
          canUndo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanUndo,
          canRedo: this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT && this.docStore.editCanRedo,
          undoAction: () => this.undoEdit(),
          redoAction: () => this.redoEdit(),
          zoomAction: (delta: number) => this.setZoom(delta * 20),
          showAiPanel: this.panelStore.showAiPanel,
          aiRunning: this.aiStore.aiLoading,
          aiPending: this.aiStore.aiPendingSummary.length > 0,
          showMacroPanel: this.panelStore.showMacroPanel,
          showPythonPanel: this.panelStore.showPythonPanel,
          openPythonAction: () => {
            if (this.panelStore.showPythonPanel) {
              this.closeAssistantPanel('python');
            } else {
              this.openPythonPanel(false);
            }
          },
          tabs: unwrapObserved(this.docStore.workspaceTabs),
          activeTabId: this.docStore.activeWorkspaceId,
          selectTabAction: (id: string) => this.switchWorkspaceDocument(id),
          closeTabAction: (id: string) => { this.closeWorkspaceDocument(id); },
          currentModule: this.viewportStore.currentModule,
          drcIssueCount: this.verifyStore.drcIssues.length,
          viewMode: this.viewportStore.currentViewMode === ViewMode.VIEWER ? '查看' : '编辑',
          fileName: this.currentFileDisplayName(),
          cellName: this.docStore.currentEditingCellName,
          documentDirty: this.docStore.documentDirty,
          sidebarVisible: this.panelStore.sidebarVisible,
          inspectorVisible: this.floatingShapePropertiesVisible() || this.panelStore.inspectorVisible,
          openFileAction: async () => {
            await this.pickAndParseFile();
          },
          recentFilesAction: () => { this.openExclusiveUtilitySheet('file'); },
          saveAction: () => {
            this.saveCurrentLayout();
          },
          fitAction: () => {
            this.fitAllShapes();
          },
          runDrcAction: () => {
            this.runDrcBackground();
          },
          toggleMacroAction: () => {
            this.openExclusiveUtilitySheet('macro');
          },
          toggleAiAction: () => this.toggleAiPanel(),
          selectModuleAction: (module: WorkModule, label: string) => {
            this.selectModule(module, label);
          },
          setViewModeAction: (mode: string) => {
            this.setViewMode(mode === '查看' ? ViewMode.VIEWER : ViewMode.EDIT);
          },
          resetViewAction: () => {
            this.resetView();
          },
          savePresetAction: () => {
            this.presetSaveContext = this.parameterDialogContext();
            this.openCanvasDialog(this.presetSaveController);
          },
          toggleSidebarAction: () => {
            this.panelStore.sidebarVisible = !this.panelStore.sidebarVisible;
            if (this.panelStore.sidebarVisible && this.sidebarContainerType() === SideBarContainerType.Overlay) {
              this.panelStore.propertyPanelClosed = true;
              this.panelStore.inspectorVisible = false;
            }
          },
          toggleInspectorAction: () => this.toggleInspectorPanel()
        })

        // 桌面端标签页已直接内联进 WorkbenchTitleBar，仅在触控窄屏且打开 ≥2 个文档时展示次级标签栏
        if (!this.isDesktopWorkspace() && this.viewportStore.currentModule !== WorkModule.Data && this.docStore.workspaceTabs.length > 1) {
          WorkspaceTabs({
            desktopMode: false,
            tabs: unwrapObserved(this.docStore.workspaceTabs),
            activeId: this.docStore.activeWorkspaceId,
            selectAction: (id: string) => this.switchWorkspaceDocument(id),
            closeAction: (id: string) => { this.closeWorkspaceDocument(id); },
            newAction: () => { this.openExclusiveUtilitySheet('project'); }
          })
          .transition(this.floatingTransition(TransitionEdge.TOP))
        }

        if (this.isDesktopWorkspace()) {
          this.workspaceContent()
        } else {
          this.touchWorkspace()
        }
      }
      .width('100%')
      .height('100%')
      .padding({ top: Math.max(0, this.safeAreaTopVp) })
      .backgroundColor(this.themeState.isLuminousBackgroundEnabled() ? Color.Transparent : COLORS.bg)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.panelStore.showAiPanel) {
        AiAssistantPanel({
              desktopMode: this.isDesktopWorkspace(),
              panelWidth: this.isDesktopWorkspace()
                ? Math.min(460, Math.max(320, this.panelStore.windowWidthVp - 24))
                : Math.min(480, Math.max(280, this.panelStore.windowWidthVp - 20)),
              panelHeight: this.isDesktopWorkspace()
                ? Math.max(320, this.panelStore.windowHeightVp - 88)
                : Math.max(300, this.panelStore.windowHeightVp - Math.max(0, this.safeAreaTopVp) - 138),
              sessionMode: this.aiStore.aiPermissionMode === 'readonly' ? 'readonly' : 'agent',
              permissionMode: this.aiStore.aiPermissionMode,
              changePermissionModeAction: (mode: DshPermissionMode) => {
                this.aiStore.aiPermissionMode = mode;
                this.aiStore.aiSessionMode = mode === 'readonly' ? 'readonly' : 'agent';
              },
              turnChangeSummary: this.aiStore.aiTurnChangeSummary,
              runStartedAt: this.aiStore.aiRunStartedAt,
              fitCanvasAction: () => { this.fitAllShapes(); },
              toggleSessionModeAction: () => {
                const nextMode: DshPermissionMode = this.aiStore.aiPermissionMode === 'auto'
                  ? 'review'
                  : (this.aiStore.aiPermissionMode === 'review' ? 'readonly' : 'auto');
                this.aiStore.aiPermissionMode = nextMode;
                this.aiStore.aiSessionMode = nextMode === 'readonly' ? 'readonly' : 'agent';
              },
              minimizeAction: () => {
                this.panelStore.showAiPanel = false;
                this.restoreCanvasFocusAfterPanelClose();
              },
              fileName: this.currentFileDisplayName() || '未命名版图',
              cellName: this.docStore.currentEditingCellName || this.cellName(editService.getCurrentCellId()),
              topCellName: this.docStore.docTopCellName,
              selectionCount: this.viewportStore.selectedShapeCount,
              pendingSummary: this.aiStore.aiPendingSummary,
              pendingDetail: this.aiStore.aiPendingDetail,
              reviewGroups: unwrapObserved(this.aiStore.aiReviewGroups),
              toggleReviewGroupAction: (id: string, accepted: boolean): void => this.toggleAiReviewGroup(id, accepted),
              focusReviewAction: (): void => this.focusAiReview(),
              lastResult: this.aiStore.aiLastResult,
              canUndo: this.aiStore.aiCanUndo,
              applyPendingAction: () => this.applyPendingAiCommands(),
              cancelPendingAction: () => this.cancelPendingAiCommands(),
              undoAction: () => {
                if (this.aiStore.aiCanUndo && this.aiUndoMarker === editService.getUndoMarker()) {
                  this.undoEdit();
                  this.aiStore.aiLastResult = this.panelStore.statusText;
                }
                this.aiStore.aiCanUndo = false;
              },
              isCompact: this.isCompact(),
              messages: unwrapObserved(this.aiStore.aiMessages),
              conversations: unwrapObserved(this.aiStore.aiConversations),
              activeConversationId: this.aiStore.aiActiveConversationId,
              contextOptions: unwrapObserved(this.aiStore.aiContextOptions),
              contextUsageSummary: this.aiContextUsageLabel(),
              compressionSummary: this.aiCompressionLabel(),
              contextDetail: this.aiContextDetail(),
              checkpointSummary: this.aiStore.aiCheckpointSummary,
              hasRecoverableArtifact: this.aiStore.aiHasRecoverableArtifact,
              projectNote: this.aiStore.aiProjectNote,
              projectIdentity: this.docStore.activeWorkspaceId,
              saveProjectNoteAction: (text: string): boolean => {
                try { aiService.saveProjectKnowledge(this.docStore.activeWorkspaceId, text); this.aiStore.aiProjectNote = text; this.aiStore.aiContextEpoch++; return true; }
                catch (error) { this.aiStore.aiError = String(error); return false; }
              },
              analyzeResultAction: (): void => { this.handleAiPromptFull('只读分析最近一次真实执行回执与当前DRC结果，说明改善、剩余问题和下一步建议，不提出可应用修改。'); },
              recoverArtifactAction: (): void => { this.recoverAiArtifact(); },
              newConversationAction: () => this.handleAiConversationAction('new'),
              switchConversationAction: (id: string) => this.handleAiConversationAction('switch', id),
              renameConversationAction: (id: string, title: string) => this.handleAiConversationAction('rename', id, title),
              deleteConversationAction: (id: string) => this.handleAiConversationAction('delete', id),
              clearConversationAction: () => this.handleAiConversationAction('clear'),
              setContextOptionsAction: (options: AiContextOptions) => this.setAiContextOptions(options),
              compressConversationAction: () => { this.compressAiConversation(); },
              clearCompressionAction: () => this.clearAiCompression(),
              configChangedAction: () => { this.aiStore.aiContextEpoch++; this.aiStore.aiReportedContextUsage = ''; },
              isLoading: this.aiStore.aiLoading,
              canCancel: this.aiStore.aiCanCancel,
              generationStatus: this.aiStore.aiLoading ? this.panelStore.statusText : '',
              cancelGenerationAction: () => this.cancelAiGeneration(),
              errorMessage: this.aiStore.aiError,
              streamingText: this.aiStore.aiStreamingText,
              reasoningText: this.aiStore.aiReasoningText,
              toolCalls: unwrapObserved(this.aiStore.aiToolCalls),
              closeAction: () => this.closeAssistantPanel('ai'),
              openPythonAction: () => this.openPythonPanel(false),
              openAgentConnectionAction: () => this.openPythonPanel(true),
              promptAction: (prompt: string, resumeTask?: boolean, forceReadOnly?: boolean) => {
                this.handleAiPromptFull(prompt, resumeTask, forceReadOnly);
              },
              pendingAttachments: unwrapObserved(this.aiStore.aiPendingAttachments),
              webSearchEnabled: this.aiStore.aiWebSearchEnabled,
              pendingAskUser: unwrapObserved(this.aiStore.aiPendingAskUser),
              toggleWebSearchAction: (enabled: boolean) => { this.aiStore.aiWebSearchEnabled = enabled; },
              pickPhotoAttachmentAction: () => { this.pickAiPhotosForChat(); },
              pickFileAttachmentAction: () => { this.pickAiFilesForChat(); },
              captureCanvasAttachmentAction: () => { this.attachCurrentCanvasSnapshotToChat(); },
              pasteClipboardAttachmentAction: () => { this.pasteClipboardIntoAiChat(); },
              dropAttachmentUrisAction: (uris: string[]) => { this.ingestDroppedUrisIntoAiChat(uris); },
              removePendingAttachmentAction: (id: string) => {
                this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.filter((a: AiChatAttachment): boolean => a.id !== id);
              },
              copyAttachmentAction: (att: AiChatAttachment) => { this.copyAiAttachmentToClipboard(att); },
              saveAttachmentAsAction: (att: AiChatAttachment) => { this.saveAiAttachmentAs(att); },
              openAttachmentLayoutAction: (att: AiChatAttachment) => { this.openAiLayoutAttachment(att, 'new_tab'); },
              submitAskUserAction: (exchange: AiAskUserExchange) => { this.resolvePendingAskUser(exchange); },
              contextSummary: this.aiContextDetail()
            })
            .zIndex(ZIndexTokens.aiAssistantPanel)
            .position({
              x: this.isDesktopWorkspace()
                ? Math.max(16, this.panelStore.windowWidthVp - Math.min(460, Math.max(320, this.panelStore.windowWidthVp - 24)) - 16)
                : Math.max(10, Math.round((this.panelStore.windowWidthVp - Math.min(480, Math.max(280, this.panelStore.windowWidthVp - 20))) / 2)),
              y: this.isDesktopWorkspace() ? 64 + Math.max(0, this.safeAreaTopVp) : 52 + Math.max(0, this.safeAreaTopVp)
            })
            .transition(this.floatingTransition(TransitionEdge.END))
      }

      if (this.panelStore.showPythonPanel) {
        PythonLayoutPanel({
          openConnectionSettings: this.panelStore.pythonOpenConnectionSettings,
          connectionInUse: this.aiStore.aiLoading,
          panelWidth: Math.min(620, this.panelStore.windowWidthVp - 32),
          panelHeight: Math.max(320, this.panelStore.windowHeightVp - 122),
          contextProvider: () => this.buildAiContext(),
          documentProvider: (mode: PythonInputMode) => this.createPythonSnapshot(mode),
          documentIdentityProvider: () => this.docStore.activeWorkspaceId,
          onDraftChanged: (documentId: string, draft: PythonEditorDraft) => this.handlePythonDraftChanged(documentId, draft),
          revisionProvider: () => `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`,
          loadResultAction: (artifact: PythonLayoutArtifact, mode: 'replace' | 'merge', revision: number, canApply: () => boolean) => this.applyPythonResult(artifact, mode, revision, canApply),
          loadLayoutAction: (path: string, name: string, canApply: () => boolean) => this.loadGeneratedPython(path, name, canApply),
          backAction: () => this.returnToAiPanel(),
          closeAction: () => this.closeAssistantPanel('python'),
        })
          .position({ x: Math.max(16, this.panelStore.windowWidthVp - 638), y: 68 })
          .transition(this.floatingTransition(TransitionEdge.END))
      }

      if (this.panelStore.showRdbReviewPanel) {
        RdbReviewPanel({ state: unwrapObserved(this.verifyStore.rdbReviewUi), status: this.verifyStore.rdbReviewStatus, busy: this.verifyStore.rdbReviewBusy,
          canUseCurrentDrc: this.canExportDrcRdb(), panelWidth: Math.min(1100, this.panelStore.windowWidthVp - 32),
          panelHeight: Math.max(240, this.panelStore.windowHeightVp - 140),
          fileAction: (kind: string): void => this.rdbReviewFileAction(kind),
          reportActivateAction: (id: string, workspace: string, context: string): boolean => this.activateRdbReport(id, workspace, context),
          reportCloseAction: (id: string, workspace: string, context: string): void => this.closeRdbReport(id, workspace, context),
          reportFileAction: (kind: string, id: string, workspace: string, context: string): void => this.rdbReportFileAction(kind, id, workspace, context),
          transferPreviewAction: (request: RdbTransferUiRequest): boolean => this.previewRdbTransfer(request),
          transferPageAction: (id: string, page: number, size: number): boolean => this.pageRdbTransfer(id, page, size),
          transferApplyAction: (id: string): void => this.applyRdbTransfer(id),
          transferCancelAction: (id: string): void => this.cancelRdbTransfer(id),
          mergePreviewAction: (request: RdbMergeUiRequest): boolean => this.previewRdbMerge(request),
          mergePageAction: (id: string, page: number, size: number): boolean => this.pageRdbMerge(id, page, size),
          mergeApplyAction: (id: string): void => this.applyRdbMerge(id),
          mergeCancelAction: (id: string): void => this.cancelRdbMerge(id),
          waiverCaptureAction: (request: RdbWaiverCaptureRequest): boolean => this.captureRdbWaiver(request),
          waiverPreviewAction: (request: RdbWaiverUiRequest): boolean => this.previewRdbWaiver(request),
          waiverPageAction: (id: string, page: number, size: number): boolean => this.pageRdbWaiver(id, page, size),
          waiverApplyAction: (id: string): void => this.confirmRdbWaiver(id),
          waiverCancelAction: (id: string): void => this.cancelRdbWaiver(id),
          waiverDeleteAction: (id: string, version: string): void => this.deleteRdbWaiver(id, version),
          waiverFileAction: (request: RdbWaiverFileRequest): void => { this.rdbWaiverFileAction(request); },
          reloadWorkspaceAction: (token: string): void => this.reloadIntegratedReview(token),
          filterAction: (filter: RdbReviewFilter): boolean => this.filterRdbReview(filter),
          pageAction: (index: number, size: number): boolean => this.pageRdbReview(index, size),
          selectAction: (index: number): boolean => this.selectRdbReview(index),
          reviewAction: (index: number, patch: RdbReviewPatch, token: string): boolean => this.updateRdbReview(index, patch, token),
          frameAction: (target: string, index: number): boolean => this.frameRdbReview(target, index),
          bindAction: (cell: string, id: number): boolean => this.bindRdbReview(cell, id),
          locateAction: (): boolean => this.locateRdbReview(),
          clearOverlayAction: (): void => this.clearRdbReviewOverlay(),
          draftAction: (dirty: boolean): void => { this.rdbReviewDraftDirty = dirty; },
          closeAction: (): void => this.closeRdbReview(),
        })
          .position({ x: Math.max(16, (this.panelStore.windowWidthVp - Math.min(1100, this.panelStore.windowWidthVp - 32)) / 2), y: 68 })
          .transition(this.modalTransition())
      }
      if (this.verifyStore.engineeringRestorePreview !== undefined) {
        EngineeringReviewRestorePanel({ preview: unwrapObserved(this.verifyStore.engineeringRestorePreview), busy: this.verifyStore.engineeringRestoreBusy,
          error: this.verifyStore.engineeringRestoreError, sourceDocumentIds: unwrapObserved(this.verifyStore.engineeringRestoreSourceIds),
          targetDocuments: unwrapObserved(this.verifyStore.engineeringRestoreTargets), replaceTargetViews: this.verifyStore.engineeringRestoreReplaceViews,
          onMapping: (source: string, target: string, token: string): void => this.changeEngineeringRestoreMapping(source, target, token),
          onReplaceViews: (replace: boolean, token: string): void => this.changeEngineeringRestoreReplacement(replace, token),
          onConfirm: (token: string): void => this.commitEngineeringReviewRestore(token),
          onCancel: (token: string): void => this.cancelEngineeringReviewRestore(token),
          panelWidth: Math.min(700, this.panelStore.windowWidthVp - 32), panelHeight: Math.max(240, this.panelStore.windowHeightVp - 140)
        })
          .position({ x: Math.max(16, (this.panelStore.windowWidthVp - Math.min(700, this.panelStore.windowWidthVp - 32)) / 2), y: 68 })
          .transition(this.modalTransition())
      }
      if (this.panelStore.showLayerStackPanel) {
        LayerStackPanel({ panelWidth: Math.min(1020, this.panelStore.windowWidthVp - 32), panelHeight: Math.max(320, this.panelStore.windowHeightVp - 140),
          inputContext: this.layerStackContext(),
          technologyProvider: () => technologyService.getActive(), contextProvider: () => this.layerStackContext(),
          buildAction: (stack: PhysicalLayerStack, options: LayerStackBuildOptions): LayerStackResult => this.buildLayerStack(stack, options),
          saveAction: (stack: PhysicalLayerStack) => this.saveLayerStack(stack), closeAction: () => { this.panelStore.showLayerStackPanel = false; } })
          .position({ x: Math.max(16, (this.panelStore.windowWidthVp - Math.min(1020, this.panelStore.windowWidthVp - 32)) / 2), y: 68 })
          .transition(this.modalTransition())
      }
      // 统一鸿蒙原生光感半模态/居中模态宿主（收口 11 个工作台二级面板：手机底部无极半屏 / 平板与桌面居中玻璃弹窗）
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .bindSheet(
          this.hasActiveUtilitySheet(),
          this.buildActiveUtilitySheet(),
          buildLuminousSheetOptions(
            {
              detents: this.compactSquare ? ['88%', SheetSize.MEDIUM] : [SheetSize.MEDIUM, SheetSize.LARGE],
              preferType: this.isCompact() ? SheetType.BOTTOM : SheetType.CENTER,
              showClose: false,
              dragBar: true,
              onWillDismiss: (dismissSheetAction: DismissSheetAction) => {
                this.closeAllUtilitySheets();
                dismissSheetAction.dismiss();
              },
              onDisappear: () => {
                this.closeAllUtilitySheets();
                this.restoreCanvasFocusAfterPanelClose();
              }
            },
            this.themeState.luminous,
            this.themeState.resolveLuminousRenderMode()
          )
        )

      if (this.docStore.activeNativeJobId.length > 0) {
        this.buildLiveJobCapsule()
      }

      // LVS 连通性预检查半模态宿主（全尺寸无触摸穿透锚点，避免 SheetType.POPUP 在大屏锚定到 0x0 左上角）
      Stack()
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.None)
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .bindSheet(
          $$this.lvsSheetOpen,
          this.buildLvsPanel(),
          buildLuminousSheetOptions(
            {
              detents: this.compactSquare ? ['88%', SheetSize.MEDIUM] : [SheetSize.MEDIUM, SheetSize.LARGE],
              preferType: SheetType.POPUP,
              showClose: false,
              dragBar: true,
              onDisappear: () => {
                this.lvsSheetOpen = false;
                this.panelStore.showLvsPanel = false;
                this.restoreCanvasFocusAfterPanelClose();
              }
            },
            this.themeState.luminous,
            this.themeState.resolveLuminousRenderMode()
          )
        )

      if (this.panelStore.isExternalDragHovering) {
        this.buildExternalDropOverlay()
      }

      // 实例放置弹窗：由 placeInstanceController（@CustomDialog）驱动，open() 时按需弹出
      // 大版图打开向导：由 openWizardController（@CustomDialog）驱动，文件 ≥ LARGE_FILE_THRESHOLD_BYTES 时弹出，
      // 让用户显式选择查看/编辑模式并提示内存影响（解决 KLayout 痛点：
      // "Edit mode 会显著增加加载时间和内存，尤其对 OASIS 数组不友好"）。
    }
    .id('hongtu-workbench-root')
    .width(LayoutPolicy.matchParent)
    .height(LayoutPolicy.matchParent)
    .backgroundColor(COLORS.bg)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .allowDrop(HONGTU_ALLOWED_DROP_TYPES)
    .onDragEnter(() => {
      this.panelStore.isExternalDragHovering = true;
    })
    .onDragLeave(() => {
      this.panelStore.isExternalDragHovering = false;
    })
    .onDrop((event: DragEvent) => {
      this.panelStore.isExternalDragHovering = false;
      this.handleExternalFileDrop(event);
    })
    .onAreaChange((oldValue: Area, newValue: Area) => {
      const width: number = Math.floor(newValue.width as number);
      if (Number.isFinite(width) && width > 0 && width !== this.panelStore.layerStyleAvailableWidth) {
        this.panelStore.layerStyleAvailableWidth = width;
      }
      const height: number = Math.floor(newValue.height as number);
      if (Number.isFinite(height) && height > 0 && height !== this.panelStore.layerStyleAvailableHeight) {
        this.panelStore.layerStyleAvailableHeight = height;
      }
    })
    .bindSheet(
      $$this.showAppearanceSheet,
      this.buildAppearanceSheet(),
      buildLuminousSheetOptions(
        {
          detents: this.compactSquare ? ['88%', SheetSize.MEDIUM] : [SheetSize.MEDIUM, SheetSize.LARGE],
          preferType: SheetType.POPUP,
          showClose: false,
          dragBar: true,
          onDisappear: () => {
            this.restoreCanvasFocusAfterPanelClose();
          }
        },
        this.themeState.luminous,
        this.themeState.resolveLuminousRenderMode()
      )
    )
  }

  private closeAssistantPanel(panel: 'ai' | 'python'): void {
    if (panel === 'ai') this.panelStore.showAiPanel = false;
    else this.panelStore.showPythonPanel = false;
    this.restoreCanvasFocusAfterPanelClose();
  }

  private toggleAiPanel(): void {
    this.canvasFocusReturnTicket++;
    this.panelStore.showPythonPanel = false;
    this.panelStore.showAiPanel = !this.panelStore.showAiPanel;
    if (this.panelStore.showAiPanel) {
      this.aiStore.aiMinimizedNotice = '';
      this.verifyStore.showDrcRules = false;
      this.panelStore.showMacroPanel = false;
      this.panelStore.showRdbReviewPanel = false;
      this.panelStore.showComparePanel = false;
      this.panelStore.showViewWorkspacePanel = false;
    } else this.restoreCanvasFocusAfterPanelClose();
  }

  private openPythonPanel(connectionSettings: boolean): void {
    this.canvasFocusReturnTicket++;
    this.panelStore.pythonOpenConnectionSettings = connectionSettings;
    this.panelStore.showAiPanel = false;
    this.panelStore.showPythonPanel = true;
  }

  private returnToAiPanel(): void {
    this.canvasFocusReturnTicket++;
    this.aiStore.aiMinimizedNotice = '';
    this.panelStore.showPythonPanel = false;
    this.panelStore.showRdbReviewPanel = false;
    this.panelStore.showComparePanel = false;
    this.panelStore.showViewWorkspacePanel = false;
    this.panelStore.showAiPanel = true;
  }

  private restoreCanvasFocusAfterPanelClose(): void {
    const ticket: number = ++this.canvasFocusReturnTicket;
    if (!this.pageAlive || !this.docStore.workspaceReady || this.importInProgress || this.saveInProgress || this.canvasKeyboardBlocked()) return;
    if (!this.isDesktopWorkspace() && this.isCompact() && this.viewportStore.currentModule !== WorkModule.Layout) return;
    const generation: number = this.pageGeneration;
    const documentId: string = this.docStore.activeWorkspaceId;
    const module: WorkModule = this.viewportStore.currentModule;
    const context: string = this.parameterDialogContext();
    try {
      this.getUIContext().postFrameCallback(new CanvasFocusReturnFrame((): void => {
        if (!this.pageAlive || generation !== this.pageGeneration || ticket !== this.canvasFocusReturnTicket ||
          documentId !== this.docStore.activeWorkspaceId || module !== this.viewportStore.currentModule || !this.docStore.workspaceReady ||
          context !== this.parameterDialogContext() || this.importInProgress || this.saveInProgress || this.canvasKeyboardBlocked()) return;
        this.canvasFocusReturnTicket++;
        try { this.getUIContext().getFocusController().requestFocus('layout-canvas-keyboard'); }
        catch (_) { console.warn('[Index] Canvas focus return unavailable'); }
      }));
    } catch (_) { this.canvasFocusReturnTicket++; }
  }

  private onModalDialogOpened(key: string): void {
    if (!this.openDialogKeys.has(key)) {
      this.openDialogKeys.add(key);
      this.panelStore.activeDialogCount = this.openDialogKeys.size;
    }
    if (this.nudgeTxActive) this.finishNudgeTransaction();
    setShiftHeld(false);
    setCtrlHeld(false);
    shortcutService.clear();
    this.mnemonicContext = '';
  }

  private onModalDialogClosed(key: string): void {
    if (this.openDialogKeys.delete(key)) {
      this.panelStore.activeDialogCount = this.openDialogKeys.size;
    }
    if (key !== 'layerExpression' && this.openDialogKeys.size === 0 && !this.canvasKeyboardBlocked()) {
      this.restoreCanvasFocusAfterPanelClose();
    }
  }

  private dialogKeyForController(controller: CustomDialogController): string {
    if (controller === this.pcellEditController) return 'pcellEdit';
    if (controller === this.presetSaveController) return 'presetSave';
    if (controller === this.placeInstanceController) return 'placeInstance';
    if (controller === this.openWizardController) return 'openWizard';
    if (controller === this.cellNameController) return 'cellName';
    if (controller === this.arrayCopyController) return 'arrayCopy';
    if (controller === this.sizeOffsetController) return 'sizeOffset';
    if (controller === this.roundCornersController) return 'roundCorners';
    if (controller === this.booleanPreviewController) return 'booleanPreview';
    if (controller === this.commandSearchController) return 'commandSearch';
    if (controller === this.layerExpressionController) return 'layerExpression';
    if (controller === this.hierarchyClipController) return 'hierarchyClip';
    if (controller === this.hierarchyFillController) return 'hierarchyFill';
    if (controller === this.cellMaintenanceController) return 'cellMaintenance';
    if (controller === this.portManagerController) return 'portManager';
    if (controller === this.portConnectController) return 'portConnect';
    if (controller === this.portRouteController) return 'portRoute';
    if (controller === this.importMergeController) return 'importMerge';
    if (controller === this.placePCellController) return 'placePCell';
    if (controller === this.exportCompletionController) return 'exportCompletion';
    return '';
  }

  private canvasKeyboardBlocked(): boolean {
    return this.panelStore.activeDialogCount > 0 || this.lvsSheetOpen || this.workspaceCloseConfirming ||
      this.viewportStore.currentModule === WorkModule.Data || this.panelStore.showAiPanel || this.panelStore.showPythonPanel ||
      this.verifyStore.showDrcRules || this.panelStore.showMacroPanel || this.panelStore.showLvsPanel || this.panelStore.showFilePanel ||
      this.panelStore.showShortcutPanel || this.panelStore.showLayerStylePanel || this.panelStore.showProjectPanel || this.panelStore.showSearchPanel ||
      this.panelStore.showLibraryPanel || this.panelStore.showViewWorkspacePanel || this.panelStore.showRdbReviewPanel || this.verifyStore.engineeringRestorePreview !== undefined ||
      this.panelStore.showComparePanel || this.panelStore.showTechnologyPanel || this.panelStore.showLayerStackPanel || this.panelStore.showVerificationPanel || this.showAppearanceSheet;
  }

  private dispatchMnemonicAction(action: ShortcutAction, param?: Object): void {
    if (this.canvasKeyboardBlocked() || (this.mnemonicContext.length > 0 && this.mnemonicContext !== this.parameterDialogContext())) {
      shortcutService.clear(); this.mnemonicContext = ''; return;
    }
    this.mnemonicContext = '';
    this.handleShortcut(action, param);
  }

  private armLayerExpressionFocusOwner(): void {
    // An overlapping reopen has no reliable completed-close identity. Suppress
    // both returns until the corresponding disappearance callbacks finish.
    if (this.layerExpressionFocusClosingCount > 0 || this.layerExpressionFocusOwner !== undefined) {
      this.layerExpressionFocusClosingOwner = undefined;
      this.layerExpressionFocusOwner = undefined;
      return;
    }
    this.layerExpressionFocusOwner = {
      ticket: this.canvasFocusReturnTicket,
      generation: this.pageGeneration,
      documentId: this.docStore.activeWorkspaceId,
      module: this.viewportStore.currentModule,
      cellId: editService.getCurrentCellId(),
      viewMode: this.viewportStore.currentViewMode,
      context: this.parameterDialogContext()
    };
  }

  private sameLayerExpressionFocusOwner(owner: LayerExpressionFocusOwner): boolean {
    return this.pageAlive && this.docStore.workspaceReady &&
      owner.ticket === this.canvasFocusReturnTicket && owner.generation === this.pageGeneration &&
      owner.documentId === this.docStore.activeWorkspaceId && owner.module === this.viewportStore.currentModule &&
      owner.cellId === editService.getCurrentCellId() && owner.viewMode === this.viewportStore.currentViewMode;
  }

  private advanceLayerExpressionFocusOwner(owner: LayerExpressionFocusOwner | undefined, beforeContext: string): void {
    // Call only after this dialog's successful applyAction and its existing sync.
    // Do not refresh authority after an arbitrary external document/context change.
    if (owner !== undefined && owner === this.layerExpressionFocusOwner &&
      owner.context === beforeContext && this.sameLayerExpressionFocusOwner(owner)) {
      owner.context = this.parameterDialogContext();
    }
  }

  private layerExpressionWillDisappear(): void {
    this.layerExpressionFocusClosingOwner = this.layerExpressionFocusClosingCount === 0 ?
      this.layerExpressionFocusOwner : undefined;
    this.layerExpressionFocusOwner = undefined;
    this.layerExpressionFocusClosingCount++;
  }

  private layerExpressionDidDisappear(): void {
    if (this.layerExpressionFocusClosingCount <= 0) return;
    const owner: LayerExpressionFocusOwner | undefined = this.layerExpressionFocusClosingCount === 1 ?
      this.layerExpressionFocusClosingOwner : undefined;
    this.layerExpressionFocusClosingCount--;
    this.layerExpressionFocusClosingOwner = undefined;
    if (this.layerExpressionFocusClosingCount > 0 || owner === undefined ||
      !this.sameLayerExpressionFocusOwner(owner) || owner.context !== this.parameterDialogContext()) return;
    this.restoreCanvasFocusAfterPanelClose();
  }

  private openCanvasDialog(controller: CustomDialogController): void {
    this.canvasFocusReturnTicket++;
    const key: string = this.dialogKeyForController(controller);
    if (key.length > 0) this.onModalDialogOpened(key);
    else { shortcutService.clear(); this.mnemonicContext = ''; }
    if (controller === this.layerExpressionController) this.armLayerExpressionFocusOwner();
    controller.open();
  }

  /** Called only by the canvas focus leaf; text inputs never bubble into this handler. */
  private handleCanvasKeyEvent(event: KeyEvent): void {
    if (this.canvasKeyboardBlocked()) {
      if (this.nudgeTxActive) this.finishNudgeTransaction();
      setShiftHeld(false);
      setCtrlHeld(false);
      setAltHeld(false);
      return;
    }
    const key: string = canvasKeyName(event.keyCode, event.keyText);
    const down: boolean = event.type === KeyType.Down;
    if (key === 'SHIFT') {
      setShiftHeld(down);
      return;
    }
    if (key === 'CTRL') {
      setCtrlHeld(down);
      return;
    }
    if (key === 'ALT') {
      setAltHeld(down);
      return;
    }
    if (!down) {
      if (key === 'ARROWUP' || key === 'ARROWDOWN' || key === 'ARROWLEFT' || key === 'ARROWRIGHT') {
        this.nudgeKeyHeld = false;
        if (this.nudgeTxActive) this.scheduleNudgeTransactionEnd();
      }
      return;
    }

    let ctrl: boolean = isCtrlHeld();
    let shift: boolean = isShiftHeld();
    let alt: boolean = false;
    // Track physical modifier events as a fallback when this optional API is absent.
    if (event.getModifierKeyState !== undefined) {
      try {
        ctrl = event.getModifierKeyState(['Ctrl']);
        shift = event.getModifierKeyState(['Shift']);
        alt = event.getModifierKeyState(['Alt']);
      } catch (_error) {}
    }
    setCtrlHeld(ctrl);
    setShiftHeld(shift);
    setAltHeld(alt);
    if (alt || event.metaKey !== 0) return;

    let handled: boolean = true;
    if (ctrl) {
      shortcutService.clear(); this.mnemonicContext = '';
      switch (key) {
        case 'Z': this.handleShortcut(shift ? ShortcutAction.REDO : ShortcutAction.UNDO); break;
        case 'Y': this.handleShortcut(ShortcutAction.REDO); break;
        case 'S': if (shift) this.saveCurrentLayout(true); else this.handleShortcut(ShortcutAction.SAVE); break;
        case 'N': this.panelStore.showProjectPanel = true; break;
        case 'W': this.closeWorkspaceDocument(this.docStore.activeWorkspaceId); break;
        case 'F': this.panelStore.showSearchPanel = true; break;
        case 'K': this.openCanvasDialog(this.commandSearchController); break;
        case 'O': this.handleShortcut(ShortcutAction.OPEN); break;
        case 'A': this.handleShortcut(ShortcutAction.SELECT_ALL); break;
        case 'C': this.handleShortcut(ShortcutAction.COPY); break;
        case 'V': this.handleShortcut(ShortcutAction.PASTE); break;
        case 'D': this.duplicateSelection(); break;
        case 'M': this.switchToMoveTool(); break;
        default: handled = false;
      }
    } else {
      if (key === 'ARROWUP' || key === 'ARROWDOWN' || key === 'ARROWLEFT' || key === 'ARROWRIGHT') {
        this.nudgeKeyHeld = true;
      }
      switch (key) {
        case 'SPACE':
          this.mnemonicContext = this.parameterDialogContext();
          shortcutService.beginMnemonic();
          this.panelStore.statusText = '助记码：输入字母，Esc 取消';
          break;
        case 'ENTER':
          if (shortcutService.isMnemonicMode()) { shortcutService.commitMnemonic(); }
          else handled = false;
          break;
        case 'DELETE': this.handleShortcut(ShortcutAction.DELETE); break;
        case 'ESCAPE': this.handleShortcut(ShortcutAction.ESCAPE); break;
        case 'BACKSPACE': this.handleShortcut(ShortcutAction.VIEW_BACK); break;
        case 'ARROWUP': this.handleShortcut(ShortcutAction.NUDGE, 'up'); break;
        case 'ARROWDOWN': this.handleShortcut(ShortcutAction.NUDGE, 'down'); break;
        case 'ARROWLEFT': this.handleShortcut(ShortcutAction.NUDGE, 'left'); break;
        case 'ARROWRIGHT': this.handleShortcut(ShortcutAction.NUDGE, 'right'); break;
        case '+':
        case ']': this.handleShortcut(ShortcutAction.ZOOM_IN); break;
        case '-':
        case '[': this.handleShortcut(ShortcutAction.ZOOM_OUT); break;
        case 'F2': this.fitAllShapes(); break;
        case 'HOME': this.resetView(); break;
        case '*':
          viewService.setHierarchyDepth(5);
          this.panelStore.statusText = '层级展开深度: 全部 (5 层)';
          break;
        default:
          if (shift && key === 'K') {
            this.measureStore.clearAll();
            this.panelStore.statusText = '已清空全部测量标注与参考标尺';
            handled = true;
            break;
          }
          handled = /^[A-Z]$/.test(key) && shortcutService.consumeInput(key);
          if (!handled) handled = key.length === 1 && this.handleSingleKey(key);
      }
    }
    if (handled) event.stopPropagation();
  }

  private macroList(): Macro[] {
    return macroService.getAllMacros();
  }

  private recordMacroStep(description: string, command: string): void {
    try { macroService.recordStep(description, command, 'edit', this.docStore.activeWorkspaceId); }
    catch (error) {
      this.panelStore.macroStatusText = `此步未录入，已有录制和实际编辑保留：${String(error)}`;
      this.panelStore.statusText += '；此步未录入宏，请查看录制提示';
    }
  }

  private finishMacroRecordingForDocumentChange(nextId: string): void {
    if (nextId === this.docStore.activeWorkspaceId || !macroService.isRecording()) return;
    const macro: Macro | null = macroService.stopRecording();
    this.panelStore.macroRecording = false;
    this.panelStore.macroStatusText = macro !== null
      ? `切换文档前已保存宏「${macro.name}」（${macro.steps.length} 步）`
      : '切换文档前已结束空录制';
  }

  private runMacro(macroId: number): void {
    if (macroService.isRecording()) {
      this.panelStore.macroStatusText = '请先停止或取消录制，再运行宏';
      this.panelStore.statusText = this.panelStore.macroStatusText;
      return;
    }
    // INDEX-2: 查看模式下禁止宏执行（宏可能包含编辑操作）
    if (!this.assertEditMode()) {
      return;
    }
    // INDEX-2: try-catch 防止宏执行异常导致状态不一致
    try {
      const result: MacroResult = macroService.executeMacro(macroId, this.buildAiContext(), this.docStore.activeWorkspaceId, this.propertyCellOptions());
      this.syncShapesFromEditService();
      if (result.viewActions !== undefined) {
        for (let i = 0; i < result.viewActions.length; i++) {
          this.applyViewAction(result.viewActions[i]);
        }
      }
      if (result.success) {
        this.panelStore.macroStatusText = `${result.macroName}: 已执行 ${result.executedSteps}/${result.totalSteps} 步`;
        this.panelStore.statusText = `宏完成: ${result.macroName} | ${this.shapes.length} 图形`;
      } else {
        const error = result.error !== undefined ? result.error : '未知错误';
        this.panelStore.macroStatusText = `${result.macroName}: 执行失败 - ${error}`;
        this.panelStore.statusText = `宏失败: ${result.macroName} - ${error}`;
      }
    } catch (e) {
      this.panelStore.macroStatusText = `宏执行异常: ${e}`;
      this.panelStore.statusText = `宏执行异常: ${e}`;
      this.syncShapesFromEditService();
    }
  }

  private layersQuickSignature(): string {
    const srcLayers: UiLayer[] = this.docStore.layers;
    const parts: string[] = [];
    for (let i = 0; i < srcLayers.length; i++) {
      const l: UiLayer = srcLayers[i];
      parts.push(`${l.layerNumber}/${l.datatype}:${l.visible ? 1 : 0}:${l.locked ? 1 : 0}:${l.selectable === false ? 0 : 1}:${l.color}:${l.fillStyle ?? ''}:${l.lineStyle ?? ''}:${l.transparency ?? -1}:${l.lineWidth ?? -1}:${l.chineseName}:${l.englishName}`);
    }
    return parts.join('|');
  }

  private renderCellNamesForCanvas(): string[] {
    const key: string = `${this.docStore.activeWorkspaceId}:${this.placeableCells.length}:${this.placeableCells.map((c: CellInfo): string => `${c.id}=${c.name}`).join(',')}`;
    if (key === this.cachedRenderCellNamesKey) {
      return this.cachedRenderCellNames;
    }
    this.cachedRenderCellNamesKey = key;
    this.cachedRenderCellNames = this.placeableCells.map((cell: CellInfo): string => cell.name);
    return this.cachedRenderCellNames;
  }

  private visibleLayerNumbers(): number[] {
    const srcLayers: UiLayer[] = this.docStore.layers;
    const parts: string[] = [];
    for (let i = 0; i < srcLayers.length; i++) {
      if (srcLayers[i].visible) parts.push(`${srcLayers[i].layerNumber}`);
    }
    const key: string = parts.join(',');
    if (key === this.cachedVisibleLayerKey) {
      return this.cachedVisibleLayerNums;
    }
    const values: number[] = [];
    for (let i = 0; i < srcLayers.length; i++) {
      if (srcLayers[i].visible) {
        values.push(srcLayers[i].layerNumber);
      }
    }
    this.cachedVisibleLayerKey = key;
    this.cachedVisibleLayerNums = values;
    return values;
  }

  private syncLayerVisibilityMirror(): void {
    const visibilities: Map<string, boolean> = new Map<string, boolean>();
    for (let i = 0; i < this.docStore.layers.length; i++) {
      visibilities.set(`${this.docStore.layers[i].layerNumber}:${this.docStore.layers[i].datatype}`, this.docStore.layers[i].visible);
    }
    viewService.setCurrentLayerVisibilities(visibilities);
    editService.refreshLayerAccess();
    this.viewportStore.selectedShapeId = editService.getSelectedId();
    this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;
    this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
  }

  private syncShapesFromEditService(preserveLayerOwnFields: boolean = false): void {
    this.docStore.currentEditingCellId = editService.getCurrentCellId();
    this.docStore.currentEditingCellName = this.cellName(editService.getCurrentCellId());
    const context: string = `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`;
    if (context !== this.analysisContext) {
      this.analysisContext = context;
      this.docStore.editorRevision++;
      this.setNativeSnapshotCurrent(false);
      this.verifyStore.comparisonLayers = [];
      this.verifyStore.comparisonPair = '';
      this.drcSnapshotRevision = -1;
      this.netSnapshotRevision = -1;
      verifyService.invalidateDocumentAnalysis();
      this.verifyStore.drcHasRun = false;
      this.verifyStore.drcIssues = [];
      this.verifyStore.highlightedViolation = null;
      this.verifyStore.highlightedViolationId = -1;
      this.invalidateLvsResult();
      this.aiStore.aiCanUndo = false;
      shortcutService.clear(); this.mnemonicContext = '';
    }
    const latestShapes: Shape[] = editService.getShapes().slice();
    this.refreshPortProjection();
    const currentSelectedIds: number[] = editService.getSelectedIds();
    this.viewportStore.selectedShapeCount = currentSelectedIds.length;
    if (currentSelectedIds.length === 0) {
      this.viewportStore.selectedShapeId = -1;
    } else if (!currentSelectedIds.includes(this.viewportStore.selectedShapeId)) {
      this.viewportStore.selectedShapeId = currentSelectedIds[0];
    }
    this.shapes = latestShapes;
    this.refreshLayerCounts(latestShapes, preserveLayerOwnFields);
    if (this.viewWorkspaceInitialized && this.viewWorkspaceDocumentId === this.docStore.activeWorkspaceId) this.refreshViewWorkspaceOverlays();
    this.docStore.documentDirty = editService.isDirty();
    this.docStore.editCanUndo = editService.canUndo();
    this.docStore.editCanRedo = editService.canRedo();
    // 实例数量变化（放置/删除/撤销/粘贴）时重建 Cell 树引用计数
    let instCount: number = 0;
    for (let i = 0; i < latestShapes.length; i++) {
      if (latestShapes[i].type === ShapeType.INSTANCE) {
        instCount++;
      }
    }
    if (instCount !== this.lastInstanceCount) {
      this.lastInstanceCount = instCount;
      this.rebuildCellTree();
    }
    const serviceSelectedId: number = editService.getSelectedId();
    if (serviceSelectedId >= 0) {
      const selected: Shape | undefined = latestShapes.find((shape: Shape) => shape.id === serviceSelectedId);
      if (selected !== undefined) {
        this.viewportStore.selectedShapeId = selected.id;
        this.viewportStore.selectedLayerNumber = selected.layerNumber;
        this.viewportStore.selectedDatatype = selected.datatype;
      }
    } else {
      this.viewportStore.selectedShapeId = -1;
    }
    this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
    this.refreshWorkspaceTabs();
    this.scheduleWorkspaceDraft();
    this.publishFormSnapshot();
  }

  private formFileSizes: Map<string, number> = new Map<string, number>();

  private publishFormSnapshot(): void {
    try {
      let bytes: number = this.formFileSizes.get(this.docStore.activeWorkspaceId) ?? 0;
      if (!this.formFileSizes.has(this.docStore.activeWorkspaceId) && this.docStore.currentFilePath.length > 0) {
        try { bytes = cardFileIo.statSync(this.docStore.currentFilePath).size; } catch (_error) { bytes = 0; }
        this.formFileSizes.set(this.docStore.activeWorkspaceId, bytes);
      }
      const result = this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision ? drcService.getLastResult() : null;
      const formatPath: string = /\.(gds|gdsii|oas|oasis|cif|dxf)$/i.test(this.docStore.currentDocumentTitle)
        ? this.docStore.currentDocumentTitle : this.docStore.currentFilePath;
      const format: string = formatPath.length === 0 ? '版图' : this.fileTypeForPath(formatPath);
      const context: string = `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}:${this.docStore.editorRevision}`;
      const summary: FormDrcSummary | undefined = result === null ? undefined : { errors: result.errors,
        warnings: result.warnings, passed: result.passed, executedRules: result.executedRules,
        totalRules: result.totalRules, completenessNotices: result.completenessNotices };
      const scope: string = result === null ? '' : `${this.cellName(editService.getCurrentCellId())} · ` +
        (result.executedRules === 0 ? '未执行规则' : result.hierarchyDepthApplied > 0
          ? `已展开${result.hierarchyDepthApplied}层` : '未展开层级');
      FormUpdater.publish(buildFormSnapshot(this.docStore.activeWorkspaceId, context, this.docStore.currentDocumentTitle, format, bytes,
        summary, scope),
        this.getUIContext().getHostContext() as common.UIAbilityContext);
    } catch (error) { console.warn(`卡片快照尚未同步：${String(error)}`); }
  }

  private propertyCellOptions(): PropertyCellOption[] {
    if (this.placeableCells.length === 0) return [{ id: 0, name: this.docStore.docTopCellName }];
    return this.placeableCells.map((cell: CellInfo): PropertyCellOption => ({ id: cell.id, name: cell.name }));
  }

  private selectedPropertiesEditable(): boolean {
    if (!this.docStore.workspaceReady || this.viewportStore.currentViewMode !== ViewMode.EDIT || this.canvasKeyboardBlocked()) return false;
    const selected: Shape[] = editService.getSelectedShapes();
    if (selected.length === 0 || selected.some((shape: Shape): boolean =>
      !editService.isShapeInCurrentCell(shape) || !editService.canEditLayer(shape.layerNumber, shape.datatype))) return false;
    // Only actual main-document objects can make its editor writable.
    for (let i = 0; i < selected.length; i++) {
      const target: Shape = unwrapObserved(selected[i]);
      const live: Shape | undefined = editService.getShapeById(target.id);
      if (live === undefined || unwrapObserved(live) !== target) return false;
    }
    return true;
  }

  private submitSelectedProperties(ids: number[], property: string, value: string,
                                   documentId: string, revision: number): string {
    if (!this.assertEditMode()) return this.panelStore.statusText;
    if (documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) return '版图已切换或修改，请重新输入属性';
    const selected: number[] = editService.getSelectedIds();
    if (ids.length === 0 || ids.length !== selected.length || ids.some((id: number) => selected.indexOf(id) < 0)) {
      return '选区已改变，请重新输入属性';
    }
    const result = editService.updateProperties(ids, property, value, this.propertyCellOptions());
    if (!result.ok) return result.message;
    if (result.changed === 0) { this.panelStore.statusText = result.message; return ''; }
    this.syncShapesFromEditService(); this.rebuildCellTree();
    this.panelStore.statusText = result.message;
    return '';
  }

  private currentExportInput(): ExportLayoutInput {
    const cellNames: string[] = this.propertyCellOptions().map((cell: PropertyCellOption) => cell.name);
    return { shapes: editService.getShapes(), layers: this.layersForDisplay(), libName: this.docStore.docLibName,
      topCellName: this.docStore.docTopCellName, sourcePath: this.docStore.currentFilePath, cellNames: cellNames,
      topCellId: this.resolveTopCellIdForExport(cellNames), userUnits: this.docStore.docUserUnits,
      physicalUnits: this.docStore.docPhysicalUnits, cellProperties: this.docCellProperties,
      cellKeys: this.docCellKeys, ports: this.docPorts, crossSections: this.docCrossSections,
      layoutContextRecords: this.docLayoutContextRecords, cellContextRecords: this.docCellContextRecords,
      libProperties: this.docLibProperties, layerDefinitions: this.sourceLayerDefinitions, preferNativeWriter: false, preferOriginalSourceCopy: false,
      nativeTempDir: (this.getUIContext().getHostContext() as common.UIAbilityContext).cacheDir };
  }

  private setNativeSnapshotCurrent(current: boolean): void {
    this.docStore.nativeSnapshotCurrent = current;
    editService.setNativeSnapshotCurrent(current);
  }

  /** 原生 C++ g_layout 展开仅在 nativeSnapshotCurrent && !editService.isDirty() 时启用 */
  private canPreferNativeExpand(): boolean {
    return this.docStore.canPreferNativeExpand(editService.isDirty());
  }

  /** 当 !nativeSnapshotCurrent || editService.isDirty() 时，向渲染管线提供实时 ArkTS 快照 */
  private provideCanvasRenderSnapshot(): NativeRenderSnapshot | null {
    if (!this.docStore.needsRenderSnapshot(editService.isDirty())) {
      return null;
    }
    const renderShapes: NativeRenderShape[] = editService.getShapes().map((s: Shape): NativeRenderShape => ({
      id: s.id, type: s.type, layerNumber: s.layerNumber, datatype: s.datatype,
      points: s.points.map((p: Point): Point => ({ x: p.x, y: p.y })), ownerCellId: s.ownerCellId,
      cellId: s.cellId, cellName: s.cellName, rotation: s.rotation, mirror: s.mirror, magnification: s.magnification,
      pathWidth: s.pathWidth, pathType: s.pathType, pathBeginExtension: s.pathBeginExtension,
      pathEndExtension: s.pathEndExtension, pathWidthAbsolute: s.pathWidthAbsolute, text: s.text,
      arrayCols: s.arrayCols, arrayRows: s.arrayRows, arrayColStepX: s.arrayColStepX,
      arrayColStepY: s.arrayColStepY, arrayRowStepX: s.arrayRowStepX, arrayRowStepY: s.arrayRowStepY
    }));
    return {
      cellNames: this.propertyCellOptions().map((cell: PropertyCellOption): string => cell.name),
      topCellId: editService.getTopCellId(),
      shapes: renderShapes
    };
  }

  /** 当撤回干净基线或保存工程后 !editService.isDirty() 但 g_layout 仍停留在旧版本时，立即校准 C++ 快照消除脑裂 */
  private calibrateNativeBaselineIfClean(): void {
    if (!editService.isDirty() && !this.docStore.nativeSnapshotCurrent) {
      try { this.synchronizeCurrentDocument(); } catch (_) { this.setNativeSnapshotCurrent(false); }
    }
  }

  private synchronizeCurrentDocument(): boolean {
    const result = nativeHongTuService.syncDocument(layoutExportService.buildNativeDocument(this.currentExportInput()));
    this.setNativeSnapshotCurrent(result.success);
    if (result.success) this.viewportStore.portCapabilityNotice = (result.portCapabilityDiagnostics ?? []).join('；');
    if (!result.success) this.panelStore.statusText = `当前文档同步失败：${result.errorMessage}`;
    return result.success;
  }

  private workspaceDocument(includeEngineering: boolean = false): WorkspaceDocument {
    this.readPCellVariants();
    const names: string[] = this.propertyCellOptions().map((cell: PropertyCellOption) => cell.name);
    const ownsTools: boolean = engineeringProjectService.canRefreshBundle(this.docStore.activeWorkspaceId, this.engineeringBundle);
    const document: WorkspaceDocument = { version: 2, id: this.docStore.activeWorkspaceId, title: this.docStore.currentDocumentTitle,
      sourcePath: this.docStore.currentFilePath, saveUri: this.currentSaveUri, projectUri: this.currentProjectUri,
      libName: this.docStore.docLibName, topCellName: this.docStore.docTopCellName, topCellId: this.resolveTopCellIdForExport(names),
      cellNames: names, cellProperties: this.docCellProperties, libProperties: this.docLibProperties,
      cellKeys: this.docCellKeys, ports: this.docPorts, crossSections: this.docCrossSections,
      layoutContextRecords: this.docLayoutContextRecords, cellContextRecords: this.docCellContextRecords,
      shapes: editService.getShapes(), layers: unwrapObserved(this.docStore.layers),
      userUnits: this.docStore.docUserUnits, physicalUnits: this.docStore.docPhysicalUnits,
      dirty: editService.isDirty() || this.docStore.documentDirty || this.localPythonDraftDirty, cellStack: editService.getCurrentCellStack(), navigationPath: editService.getNavigationPath(),
      layerDefinitions: this.sourceLayerDefinitions, precision: this.precisionSettings(),
      viewMode: this.viewportStore.currentViewMode,
      selectedIds: editService.getSelectedIds(), zoom: this.viewportStore.zoomPercent, offsetX: this.viewportStore.viewOffsetX,
      offsetY: this.viewportStore.viewOffsetY, hierarchyDepth: this.docStore.hierarchyDepth, gridSize: this.viewportStore.gridSize,
      rulers: this.measureStore.rulers, pcells: this.pcellVariants, technologyId: this.currentTechnologyId,
      technologyJson: ownsTools ? technologyService.serialize() : this.documentTechnologyJson, engineering: this.engineeringBundle,
      localProcessState: this.localProcessOwned === true ? this.captureLocalProcessState() : undefined,
      localPythonDraft: this.localPythonDraft,
      localPythonDraftDirty: this.localPythonDraft === undefined ? undefined : this.localPythonDraftDirty,
      revision: this.docStore.editorRevision, updatedAt: Date.now() };
    const previous: WorkspaceDocument | undefined = this.workspaceDocuments.get(document.id);
    if (previous !== undefined) {
      // A missing optional field and an explicitly saved empty value have different
      // meanings. Reading a legacy document must not publish runtime defaults.
      if (previous.layerDefinitions === undefined && this.sourceLayerDefinitions.length === 0) document.layerDefinitions = undefined;
      if (previous.navigationPath === undefined && (document.navigationPath?.length ?? 0) === 0) document.navigationPath = undefined;
      if (previous.precision === undefined && this.docStore.docPhysicalUnits === previous.physicalUnits &&
        this.viewportStore.drawStepNm === previous.gridSize && this.viewportStore.displayGridNm === previous.gridSize && this.viewportStore.geometrySnapEnabled &&
        JSON.stringify(this.viewportStore.geometrySnapKinds) === JSON.stringify(GEOMETRY_SNAP_KINDS)) document.precision = undefined;
    }
    if (ownsTools) {
      const origin: WorkspaceAutomaticEngineeringOrigin | undefined = this.automaticEngineeringOrigins.get(document.id);
      const automatic: boolean = origin !== undefined && this.engineeringBundle === origin.bundle &&
        JSON.stringify(this.engineeringBundle ?? null) === origin.bundleJson;
      if (origin !== undefined && !automatic) this.automaticEngineeringOrigins.delete(document.id);
      const candidate: EngineeringProjectBundle = this.buildEngineeringBundle(document);
      // Existing bundles retain their identity; absent Undo keeps the timestamp
      // sealed by the first actual automatic publication for its Redo.
      const createdAt: number | undefined = document.engineering?.createdAt ??
        (automatic && origin !== undefined ? origin.firstPublishedCreatedAt : undefined);
      if (createdAt !== undefined) candidate.createdAt = createdAt;
      const restoresAbsent: boolean = automatic && origin !== undefined && !macroService.isRecording() && !this.rdbReviewDraftDirty &&
        this.engineeringBundleContext(candidate, false) === origin.toolsBaseline &&
        JSON.stringify(candidate.review ?? null) === origin.reviewBaseline &&
        JSON.stringify({ draft: this.localPythonDraft, dirty: this.localPythonDraftDirty }) === origin.localPythonBaseline;
      const unchangedAbsentTools: boolean = this.engineeringBundle === undefined &&
        this.workspaceToolBaselineId === document.id && this.engineeringBundleContext(candidate, false) === this.workspaceToolBaseline;
      if (!includeEngineering && restoresAbsent && origin !== undefined) {
        document.engineering = undefined; this.engineeringBundle = undefined;
        origin.bundle = undefined; origin.bundleJson = 'null';
        if (!origin.sessionOwnedBefore) engineeringProjectService.forgetSessionTools(document.id);
        this.refreshEngineeringDependencies();
      } else if (includeEngineering || !unchangedAbsentTools) {
        document.engineering = candidate;
        // A Save Project picker can still be cancelled. Publish its candidate
        // only after the file has actually been saved and its context accepted.
        if (!includeEngineering) {
          this.engineeringBundle = candidate;
          if (automatic && origin !== undefined) {
            if (origin.firstPublishedCreatedAt === undefined) origin.firstPublishedCreatedAt = candidate.createdAt;
            origin.bundle = candidate; origin.bundleJson = JSON.stringify(candidate);
          }
          engineeringProjectService.markSessionToolsOwned(document.id);
        }
      }
    }
    return document;
  }

  private viewWorkspaceCapture(): ViewPresentation {
    const stack: number[] = editService.getCurrentCellStack();
    const placements: ViewPlacementRef[] = editService.getNavigationPath().map((step: InstancePathStep): ViewPlacementRef => ({
      parentCellKey: this.docCellKeys[step.parentCellId], cellKey: this.docCellKeys[step.cellId],
      instanceId: step.instanceId, row: step.row, col: step.col
    }));
    return { camera: viewCameraFromCanvas(this.viewportStore.canvasViewportWidth, this.viewportStore.canvasViewportHeight,
      this.viewportStore.zoomPercent, this.viewportStore.viewOffsetX, this.viewportStore.viewOffsetY),
      location: { cellStackKeys: stack.map((id: number): string => this.docCellKeys[id]), placements },
      hierarchyDepth: this.docStore.hierarchyDepth,
      layerVisibilities: this.docStore.layers.map((layer: UiLayer): ViewLayerVisibility => ({
        layerNumber: layer.layerNumber, datatype: layer.datatype, visible: layer.visible })) };
  }

  private viewWorkspaceIdle(): boolean {
    return this.pageAlive && this.docStore.workspaceReady && !this.importInProgress && this.docStore.activeNativeJobId.length === 0 &&
      !editService.isTransactionOpen() && !this.vertexStore.isDragging();
  }

  private viewWorkspaceContext(): string {
    return `${this.pageGeneration}:${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:` +
      JSON.stringify(this.viewWorkspaceCapture());
  }

  private viewWorkspaceApply(presentation: ViewPresentation, location: ViewResolvedLocation, viewId: string): void {
    const camera: ViewCanvasCamera = viewCameraToCanvas(presentation.camera, this.viewportStore.canvasViewportWidth, this.viewportStore.canvasViewportHeight);
    const stack: number[] = editService.getCurrentCellStack();
    if (JSON.stringify(stack) !== JSON.stringify(location.cellStack) ||
      JSON.stringify(editService.getNavigationPath()) !== JSON.stringify(location.navigationPath)) {
      if (location.cellStack.length > 0 && location.cellStack[0] !== editService.getTopCellId()) {
        if (!editService.resetStackToCell(location.cellStack[0])) {
          throw new Error('独立根Cell无效，未切换视图');
        }
      } else {
        editService.exitToTop();
      }
      for (let index: number = 1; index < location.cellStack.length; index++) editService.enterCell(location.cellStack[index]);
      if (location.navigationPath.length > 0 && !editService.restoreNavigationPath(location.navigationPath)) {
        throw new Error('实例路径已失效，未切换视图');
      }
    }
    const visible: Map<string, boolean> = new Map<string, boolean>();
    for (const layer of presentation.layerVisibilities) visible.set(`${layer.layerNumber}:${layer.datatype}`, layer.visible);
    this.docStore.layers = this.docStore.layers.map((layer: UiLayer): UiLayer => cloneLayerWithVisible(layer,
      visible.get(`${layer.layerNumber}:${layer.datatype}`) ?? layer.visible));
    this.viewportStore.zoomPercent = camera.zoomPercent; this.viewportStore.viewOffsetX = camera.offsetX; this.viewportStore.viewOffsetY = camera.offsetY;
    this.docStore.hierarchyDepth = presentation.hierarchyDepth;
    viewService.setViewZoomPercent(camera.zoomPercent); viewService.setViewOffset(camera.offsetX, camera.offsetY);
    viewService.setHierarchyDepth(presentation.hierarchyDepth);
    this.syncLayerVisibilityMirror();
    this.viewportStore.viewWorkspaceActiveId = viewId;
    this.shapes = editService.getShapes().slice();
    this.refreshEditingCellPresentation();
  }

  private viewWorkspaceRuntime(): ViewRuntime {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null) throw new Error('视图库尚未初始化');
    const documentId: string = this.docStore.activeWorkspaceId;
    const selected: number[] = editService.getSelectedIds().slice();
    return { documentId: (): string => this.docStore.activeWorkspaceId, viewId: (): string => this.viewportStore.viewWorkspaceActiveId,
      contextToken: (): string => this.viewWorkspaceContext(), isIdle: (): boolean => this.viewWorkspaceIdle(),
      capturePresentation: (): ViewPresentation => this.viewWorkspaceCapture(),
      applyPresentation: (presentation: ViewPresentation, location: ViewResolvedLocation, viewId: string): void => {
        this.viewWorkspaceApply(presentation, location, viewId);
      },
      rollbackPresentation: (presentation: ViewPresentation, viewId: string): void => {
        if (this.docStore.activeWorkspaceId !== documentId) throw new Error('文档已切换，不能回滚到旧视图');
        this.viewWorkspaceApply(presentation, core.resolveLocation(documentId, presentation.location), viewId);
        editService.selectMultiple(selected);
        this.viewportStore.selectedShapeId = editService.getSelectedId(); this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;
        this.shapes = editService.getShapes().slice();
      } };
  }

  /** Passive reads never activate, restore, capture transactions or copy history. */
  private readViewWorkspaceSource(documentId: string): ViewDatabaseSnapshot {
    if (documentId === this.docStore.activeWorkspaceId) {
      return { documentId, revision: editService.getSessionRevision(), dirty: editService.isDirty() || this.docStore.documentDirty,
        historyToken: `${editService.getSessionRevision()}:${editService.canUndo()}:${editService.canRedo()}`,
        shapes: editService.getShapes(), cellKeys: this.docCellKeys.slice(),
        topCellKey: this.docCellKeys[editService.getTopCellId()],
        cellNames: this.propertyCellOptions().map((cell: PropertyCellOption): string => cell.name), layers: unwrapObserved(this.docStore.layers) };
    }
    const record: WorkspaceDocument | undefined = this.workspaceDocuments.get(documentId);
    if (record === undefined) throw new Error('叠加来源文档已关闭或尚未打开');
    const session: EditSessionState | undefined = this.workspaceSessions.get(documentId);
    const revision: number = this.viewWorkspaceCheckpointVersions.get(documentId) ?? record.revision;
    return { documentId, revision, dirty: record.dirty,
      historyToken: `${revision}:${session?.undoStack.length ?? 0}:${session?.redoStack.length ?? 0}:${record.updatedAt}`,
      shapes: record.shapes, cellKeys: (record.cellKeys as string[]).slice(),
      topCellKey: (record.cellKeys as string[])[record.topCellId], cellNames: record.cellNames, layers: record.layers };
  }

  private bindViewWorkspaceSources(): void {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null) return;
    const ids: string[] = Array.from(this.workspaceDocuments.keys());
    if (!ids.includes(this.docStore.activeWorkspaceId)) ids.push(this.docStore.activeWorkspaceId);
    for (const previous of Array.from(this.viewWorkspaceSources.keys())) {
      if (!ids.includes(previous)) { core.unbindDatabase(previous); this.viewWorkspaceSources.delete(previous); }
    }
    for (const documentId of ids) {
      if (this.viewWorkspaceSources.has(documentId)) continue;
      const source: ViewDatabaseSource = { documentId, read: (): ViewDatabaseSnapshot => this.readViewWorkspaceSource(documentId) };
      core.bindDatabase(source); this.viewWorkspaceSources.set(documentId, source);
    }
  }

  private prepareViewWorkspace(restore: boolean = false): void {
    this.configureIntegratedReviewWorkspace();
    if (this.viewWorkspaceCore === null) this.viewWorkspaceCore = new ViewWorkspaceService(this.integratedReviewWorkspace.createViewStore());
    const core: ViewWorkspaceService = this.viewWorkspaceCore;
    if (!this.viewWorkspaceInitialized) {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (!core.initialize(context.filesDir)) throw new Error(core.getError());
      this.viewWorkspaceInitialized = true;
    }
    this.bindViewWorkspaceSources();
    const restoreExisting: boolean = restore && core.exportRecovery().documents.some((document): boolean => document.documentId === this.docStore.activeWorkspaceId);
    const initialCapture: ViewPresentation = this.viewWorkspaceCapture();
    const topCellId: number = editService.getTopCellId();
    if (topCellId >= 0 && topCellId < this.docCellKeys.length &&
        (initialCapture.location.cellStackKeys.length === 0 ||
          initialCapture.location.cellStackKeys.some((key: string): boolean => !this.docCellKeys.includes(key)))) {
      initialCapture.location = { cellStackKeys: [this.docCellKeys[topCellId]], placements: [] };
    }
    const current: ViewRecord = core.ensureDocument(this.docStore.activeWorkspaceId, initialCapture);
    this.viewWorkspaceDocumentId = this.docStore.activeWorkspaceId; this.viewportStore.viewWorkspaceActiveId = current.id;
    // A newly captured view already matches the canvas; applying it would round-trip its camera.
    try { if (restoreExisting && this.viewWorkspaceIdle()) core.activateView(current.id, this.viewWorkspaceRuntime()); }
    finally { this.refreshViewWorkspace(); }
  }

  private overlayWorkspaceContext(): string {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null || this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId) return '';
    const stamps: string[] = [];
    for (const documentId of this.viewWorkspaceSources.keys()) {
      try {
        const source: ViewDatabaseSnapshot = this.readViewWorkspaceSource(documentId);
        if (this.viewWorkspaceShapeIdentities.get(documentId) !== source.shapes) {
          this.viewWorkspaceShapeIdentities.set(documentId, source.shapes);
          this.viewWorkspaceIdentityVersions.set(documentId, (this.viewWorkspaceIdentityVersions.get(documentId) ?? 0) + 1);
        }
        stamps.push(JSON.stringify([documentId, this.viewWorkspaceIdentityVersions.get(documentId), source.revision,
          source.historyToken, source.cellKeys, source.cellNames, source.layers]));
      } catch (_) { stamps.push(`${documentId}:unavailable`); }
    }
    return JSON.stringify([this.pageGeneration, this.docStore.activeWorkspaceId, this.viewportStore.viewWorkspaceActiveId,
      core.getView(this.viewportStore.viewWorkspaceActiveId).overlays, stamps]);
  }

  private refreshViewWorkspaceOverlays(): void {
    const choices: ViewOverlayDocumentChoice[] = [];
    for (const documentId of this.viewWorkspaceSources.keys()) {
      try {
        const source: ViewDatabaseSnapshot = this.readViewWorkspaceSource(documentId);
        const record: WorkspaceDocument | undefined = this.workspaceDocuments.get(documentId);
        choices.push({ documentId, title: documentId === this.docStore.activeWorkspaceId ? this.docStore.currentDocumentTitle : (record?.title ?? documentId),
          revision: source.revision,
          cells: source.cellKeys.map((key: string, index: number): ViewOverlayCellChoice => ({ key, name: source.cellNames?.[index] ?? key })),
          layers: (source.layers ?? []).map((layer: UiLayer): ViewLayerVisibility => ({ layerNumber: layer.layerNumber, datatype: layer.datatype, visible: layer.visible })) });
      } catch (_) { /* Unresolved references remain in the view and diagnostics. */ }
    }
    this.viewportStore.viewWorkspaceOverlayDocuments = choices;
    const resolution: ViewRenderResolution = this.viewWorkspaceCore!.resolveRenderScene(this.viewportStore.viewWorkspaceActiveId, false);
    this.viewportStore.viewWorkspaceOverlayDiagnostics = resolution.diagnostics;
    this.viewportStore.viewWorkspaceSceneDiagnostic = resolution.diagnostics.map((item: ViewOverlayDiagnostic): string => `${item.overlayId}: ${item.message}`).join('；');
    this.viewportStore.viewWorkspaceOverlayContext = this.overlayWorkspaceContext();
    this.viewportStore.viewWorkspaceSceneRevision++;
  }

  private viewWorkspaceRenderScene(): ViewSceneSource[] {
    const useLiveArkSnapshot: boolean = !this.docStore.nativeSnapshotCurrent || editService.isDirty();
    const mainShapes: Shape[] = useLiveArkSnapshot ? editService.getShapes() : this.shapes;
    const mainRevision: number = editService.getSessionRevision() * 2 + (this.canPreferNativeExpand() ? 0 : 1);
    const main: ViewSceneSource = { sourceId: `main:${this.docStore.activeWorkspaceId}`, sourceDocumentId: this.docStore.activeWorkspaceId,
      revision: mainRevision, shapes: mainShapes,
      cellNames: this.propertyCellOptions().map((cell: PropertyCellOption): string => cell.name), layers: unwrapObserved(this.docStore.layers),
      cellId: editService.getCurrentCellId(), topCellId: editService.getTopCellId(), depth: this.docStore.hierarchyDepth,
      transform: { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 }, opacity: 1, readOnly: false };
    if (!this.viewWorkspaceInitialized || this.viewWorkspaceCore === null || this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId) return [main];
    const resolution: ViewRenderResolution = this.viewWorkspaceCore.resolveRenderScene(this.viewportStore.viewWorkspaceActiveId, false);
    const sources: ViewSceneSource[] = [main];
    for (const source of resolution.sources) {
      const masks: ViewLayerVisibility[] = source.layerVisibilities;
      const layers: UiLayer[] = (source.snapshot.layers ?? []).map((layer: UiLayer): UiLayer => {
        const mask: ViewLayerVisibility | undefined = masks.find((value: ViewLayerVisibility): boolean => value.layerNumber === layer.layerNumber && value.datatype === layer.datatype);
        return cloneLayerWithVisible(layer, mask?.visible ?? true);
      });
      sources.push({ sourceId: source.sourceId ?? source.sourceDocumentId, sourceDocumentId: source.sourceDocumentId,
        revision: source.snapshot.revision, shapes: source.snapshot.shapes, cellNames: source.snapshot.cellNames ?? source.snapshot.cellKeys,
        layers, cellId: source.cellId, topCellId: source.snapshot.cellKeys.indexOf(source.snapshot.topCellKey),
        depth: this.docStore.hierarchyDepth, transform: source.transform, opacity: source.opacity, readOnly: true });
    }
    return sources;
  }

  private handleViewWorkspaceOverlays(viewId: string, expectedContext: string, overlays: ViewOverlayState[]): boolean {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null || !this.panelStore.showViewWorkspacePanel || this.viewportStore.viewWorkspaceFileBusy || !this.viewWorkspaceIdle() ||
      viewId !== this.viewportStore.viewWorkspaceActiveId || expectedContext !== this.overlayWorkspaceContext()) {
      this.viewportStore.viewWorkspaceStatus = '文档、来源或视图已变化，请重新选择叠加设置'; return false;
    }
    try {
      core.setOverlays(viewId, overlays); this.refreshViewWorkspace();
      this.viewportStore.viewWorkspaceStatus = '只读叠加显示设置已保存'; return true;
    } catch (error) { this.viewportStore.viewWorkspaceStatus = `叠加设置未保存：${String(error)}`; return false; }
  }

  private refreshViewWorkspace(): void {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null || this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId) return;
    this.viewportStore.viewWorkspaceActiveId = core.activeViewId(this.docStore.activeWorkspaceId);
    this.viewportStore.viewWorkspaceViews = core.listViews(this.docStore.activeWorkspaceId);
    this.viewportStore.viewWorkspaceBookmarks = core.listBookmarks(this.docStore.activeWorkspaceId);
    this.refreshViewWorkspaceOverlays();
  }

  private openViewWorkspace(): void {
    this.finishNudgeTransaction();
    if (!this.viewWorkspaceIdle()) { this.panelStore.statusText = '文档未就绪或编辑/后台作业尚未结束，请稍后打开视图'; return; }
    try {
      this.prepareViewWorkspace();
      if (!this.persistViewWorkspacePresentation()) return;
      this.refreshViewWorkspace(); this.viewportStore.viewWorkspaceStatus = '视图共享实时版图；位置、Cell 与图层显隐独立保存';
      this.panelStore.showComparePanel = false; this.panelStore.showPythonPanel = false; this.panelStore.showAiPanel = false;
      this.panelStore.showViewWorkspacePanel = true; this.viewportStore.currentModule = WorkModule.Layout;
      shortcutService.clear(); this.mnemonicContext = '';
    } catch (error) { this.viewportStore.viewWorkspaceStatus = `视图库未打开：${String(error)}`; this.panelStore.statusText = this.viewportStore.viewWorkspaceStatus; }
  }

  private closeViewWorkspace(): void {
    if (!this.persistViewWorkspacePresentation()) return;
    this.viewWorkspaceFileTicket++; this.viewportStore.viewWorkspaceFileBusy = false; this.panelStore.showViewWorkspacePanel = false;
  }

  private persistViewWorkspacePresentation(): boolean {
    if (!this.viewWorkspaceInitialized || this.viewWorkspaceCore === null || this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId) return true;
    const activeStack: number[] = editService.getCurrentCellStack();
    if (activeStack.length === 0) return true;
    try {
      const current: ViewPresentation = this.viewWorkspaceCapture();
      if (JSON.stringify(this.viewWorkspaceCore.getView(this.viewportStore.viewWorkspaceActiveId).presentation) !== JSON.stringify(current)) {
        this.viewWorkspaceCore.updateView(this.viewportStore.viewWorkspaceActiveId, current);
      }
      return true;
    } catch (error) {
      this.viewportStore.viewWorkspaceStatus = `视图位置未保存：${String(error)}`; this.docStore.recoveryStatus = this.viewportStore.viewWorkspaceStatus;
      this.panelStore.statusText = this.viewportStore.viewWorkspaceStatus; return false;
    }
  }

  private handleViewWorkspaceAction(kind: string, id: string, name: string): boolean {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null || !this.panelStore.showViewWorkspacePanel || this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId ||
      this.viewportStore.viewWorkspaceFileBusy || !this.viewWorkspaceIdle()) { this.viewportStore.viewWorkspaceStatus = '文档或作业状态已变化，请重新打开视图面板'; return false; }
    const previousDepth: number = this.docStore.hierarchyDepth;
    try {
      // Validate membership before accepting callbacks retained by a previously rendered row.
      if (['clone', 'activate', 'renameView', 'closeView', 'saveBookmark'].includes(kind) &&
        !core.listViews(this.docStore.activeWorkspaceId).some((view: ViewRecord): boolean => view.id === id)) throw new Error('视图不属于当前文档');
      if ((kind === 'clone' || kind === 'saveBookmark') && id !== this.viewportStore.viewWorkspaceActiveId) throw new Error('当前视图已改变');
      if (kind === 'clone') core.cloneView(id, name, this.viewWorkspaceCapture());
      else if (kind === 'activate') core.activateView(id, this.viewWorkspaceRuntime());
      else if (kind === 'renameView') core.renameView(id, name);
      else if (kind === 'closeView') core.closeView(id, this.viewWorkspaceRuntime());
      else if (kind === 'saveBookmark') core.saveBookmark(id, name, this.viewWorkspaceCapture());
      else if (kind === 'locateBookmark') core.locateBookmark(this.viewportStore.viewWorkspaceActiveId, id, this.viewWorkspaceRuntime());
      else if (kind === 'renameBookmark') core.renameBookmark(this.docStore.activeWorkspaceId, id, name);
      else if (kind === 'updateBookmark') core.updateBookmark(this.docStore.activeWorkspaceId, id, this.viewWorkspaceCapture());
      else if (kind === 'deleteBookmark') core.deleteBookmark(this.docStore.activeWorkspaceId, id);
      else throw new Error('未知视图操作');
      this.refreshViewWorkspace();
      if (kind === 'activate' || kind === 'closeView' || kind === 'locateBookmark') {
        // Invalidate Cell-dependent analysis only after the atomic view transaction has succeeded.
        if (this.docStore.hierarchyDepth !== previousDepth) {
          this.invalidateLvsResult(); verifyService.clearNetSnapshot();
          this.netSnapshotRevision = -1; this.verifyStore.tracedNets = [];
        }
        const dirtyBefore: boolean = this.docStore.documentDirty;
        try { this.syncShapesFromEditService(); }
        finally { this.docStore.documentDirty = dirtyBefore || editService.isDirty(); }
        this.refreshWorkspaceTabs(); this.rebuildCellTree(); this.scheduleWorkspaceDraft();
      }
      this.viewportStore.viewWorkspaceStatus = '操作已保存'; return true;
    } catch (error) { this.viewportStore.viewWorkspaceStatus = `操作未完成：${String(error)}`; return false; }
  }

  private async viewWorkspaceFileAction(importing: boolean, replace: boolean): Promise<void> {
    const core: ViewWorkspaceService | null = this.viewWorkspaceCore;
    if (core === null || this.viewportStore.viewWorkspaceFileBusy || !this.panelStore.showViewWorkspacePanel ||
      this.viewWorkspaceDocumentId !== this.docStore.activeWorkspaceId || !this.viewWorkspaceIdle()) return;
    const ticket: number = ++this.viewWorkspaceFileTicket;
    const generation: number = this.pageGeneration;
    const documentId: string = this.docStore.activeWorkspaceId, contextToken: string = this.viewWorkspaceContext();
    const json: string = core.exportBookmarks(documentId);
    const isCurrent: () => boolean = (): boolean => this.pageAlive && this.panelStore.showViewWorkspacePanel && ticket === this.viewWorkspaceFileTicket &&
      documentId === this.docStore.activeWorkspaceId && this.viewWorkspaceIdle() && contextToken === this.viewWorkspaceContext() && core.exportBookmarks(documentId) === json;
    this.viewportStore.viewWorkspaceFileBusy = true; this.viewportStore.viewWorkspaceStatus = importing ? '请选择当前文档的书签 JSON' : '请选择书签保存位置';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (importing) {
        const text: string = await engineeringFileService.pickText(context, '视图书签|.json');
        if (!isCurrent()) throw new Error('等待期间文档、位置或书签已改变，请重新导入');
        core.importBookmarks(documentId, text, replace); this.refreshViewWorkspace();
        this.viewportStore.viewWorkspaceStatus = replace ? '已替换当前文档书签' : '已合并当前文档书签';
      } else {
        await engineeringFileService.saveText(context, 'hongtu-bookmarks.json', json, isCurrent);
        if (isCurrent()) this.viewportStore.viewWorkspaceStatus = '书签 JSON 已导出';
      }
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration && ticket === this.viewWorkspaceFileTicket &&
        documentId === this.docStore.activeWorkspaceId) this.viewportStore.viewWorkspaceStatus = `文件操作未完成：${String(error)}`;
    } finally { if (ticket === this.viewWorkspaceFileTicket) this.viewportStore.viewWorkspaceFileBusy = false; }
  }

  private initializeRdbReview(): boolean {
    if (this.rdbReviewInitialized) return true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.configureIntegratedReviewWorkspace();
      const raw: string | undefined = this.rdbReviewStorage.read();
      const candidate = new RdbReviewWorkspaceService();
      if (raw !== undefined) {
        const stored = JSON.parse(raw) as RdbReviewWorkspaceRecovery | RdbReviewWorkspaceLegacyRecovery;
        candidate.restoreRecovery(stored);
      }
      this.adoptRdbWorkspace(candidate); this.rdbReviewBaseline = raw;
      this.rdbReviewInitialized = true;
      this.verifyStore.rdbReviewStatus = raw === undefined ? '打开 .lyrdb 报告或载入当前 DRC 结果' : `已恢复 ${candidate.listReports().length} 份独立报告及审阅草稿`;
      return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `报告草稿未读取：${String(error)}`; return false; }
  }

  private configureIntegratedReviewWorkspace(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.integratedReviewWorkspace.configure(context.filesDir);
    this.rdbReviewLayoutMappings = this.integratedReviewWorkspace.readLayoutMappings();
  }

  private reloadIntegratedReview(token: string): void {
    if (!this.pageAlive || !this.panelStore.showRdbReviewPanel || this.verifyStore.rdbReviewBusy || this.rdbReviewDraftDirty ||
      !this.viewWorkspaceIdle() || token !== this.rdbReviewWorkspace.contextToken()) return;
    try {
      this.revokeRdbWaiverPreview();
      if (this.verifyStore.engineeringRestorePreview !== undefined) this.cancelEngineeringReviewRestore(this.verifyStore.engineeringRestorePreview.token);
      pythonWorkspaceService.validateBundle(pythonWorkspaceService.exportBundle());
      this.projectToolContext(); this.engineeringReviewSources();
      this.integratedReviewWorkspace.reload();
      const views: ViewWorkspaceService = new ViewWorkspaceService(this.integratedReviewWorkspace.createViewStore());
      if (!views.initialize()) throw new Error(views.getError());
      const storage: IntegratedReviewRdbStorage = this.integratedReviewWorkspace.forkRdb();
      const raw: string | undefined = storage.read();
      const reports: RdbReviewWorkspaceService = new RdbReviewWorkspaceService();
      if (raw !== undefined) reports.restoreRecovery(JSON.parse(raw) as RdbReviewWorkspaceRecovery | RdbReviewWorkspaceLegacyRecovery);
      const mappings: RdbReviewLayoutMapping[] = this.integratedReviewWorkspace.readLayoutMappings();
      this.viewWorkspaceCore = views; this.viewWorkspaceSources = new Map<string, ViewDatabaseSource>();
      this.viewWorkspaceInitialized = true; this.bindViewWorkspaceSources();
      this.rdbReviewStorage = storage; this.rdbReviewBaseline = raw; this.rdbReviewLayoutMappings = mappings;
      this.adoptRdbWorkspace(reports); this.rdbReviewInitialized = true; this.prepareViewWorkspace(true);
      this.engineeringRestoreBlocked = false; this.clearRdbReviewOverlay(); this.refreshRdbReview();
      this.verifyStore.rdbReviewStatus = '已重新读取同一份本机视图、报告与豁免库；当前真实工具和来源作为新基线';
    } catch (error) {
      this.engineeringRestoreBlocked = true; this.rdbReviewInitialized = false;
      this.verifyStore.rdbReviewStatus = `本机工作区未重新采用：${String(error)}`;
    }
  }

  private captureRdbWaiverContext(): RdbWaiverContext | null {
    const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace;
    const id: string = workspace.activeReportId();
    if (id.length === 0) return null;
    const technology = technologyService.getActive();
    const process: string = technology === undefined ? '' : JSON.stringify([technologyService.serialize(), drcService.getRules()]);
    const mappings: RdbReviewLayoutMapping[] = this.rdbReviewLayoutMappings.filter((value: RdbReviewLayoutMapping): boolean =>
      value.reportSourceIdentity === this.rdbReviewCore.source()?.identity && value.layoutDocumentId === this.docStore.activeWorkspaceId &&
      value.layoutRevision === editService.getSessionRevision() && this.docCellKeys[value.layoutCellId] === value.layoutCellKey);
    return { workspaceToken: workspace.contextToken(), reportId: id, reportContext: workspace.reportContext(id),
      reportContentToken: workspace.reportContentToken(id), layoutRevision: editService.getSessionRevision(),
      configurationToken: JSON.stringify([this.pageGeneration, this.docStore.activeWorkspaceId, editService.getSessionRevision(), process, mappings]),
      qualification: { layoutIdentity: this.docStore.activeWorkspaceId, technologyIdentity: process,
        cells: mappings.map((value: RdbReviewLayoutMapping): RdbWaiverCellBinding => ({ reportCell: value.reportCell, stableCellKey: value.layoutCellKey })) } };
  }

  private rdbWaiverRequestCurrent(context: RdbWaiverContext, version: string): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.viewWorkspaceIdle()) return false;
    return version === this.rdbReviewStorage.library().version() && JSON.stringify(context) === JSON.stringify(this.captureRdbWaiverContext());
  }

  private captureRdbWaiver(request: RdbWaiverCaptureRequest): boolean {
    try {
      if (!this.rdbWaiverRequestCurrent(request.context, request.libraryVersion)) throw new Error('报告、库或布局资格已变化');
      this.rdbReviewStorage.library().capture(this.rdbReviewWorkspace, request.context, request.itemIndex,
        request.name, request.rationale, request.libraryVersion);
      this.refreshRdbReview(); this.verifyStore.rdbReviewStatus = '豁免规则与完整依据已保存到本机库'; return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `豁免捕获未确认：${String(error)}`; return false; }
  }

  private previewRdbWaiver(request: RdbWaiverUiRequest): boolean {
    try {
      if (!this.rdbWaiverRequestCurrent(request.context, request.libraryVersion)) throw new Error('报告、库或布局资格已变化');
      this.rdbWaiverConfirmationId = '';
      this.rdbReviewStorage.library().preview(this.rdbReviewWorkspace, request.context, request.ruleIds, request.operation, request.libraryVersion);
      this.rdbWaiverPage = 0; this.refreshRdbReview(); return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `豁免预览未完成：${String(error)}`; return false; }
  }

  private pageRdbWaiver(id: string, page: number, size: number): boolean {
    try {
      const lib = this.rdbReviewStorage.library(); const preview = lib.previewProjection(this.rdbWaiverPage, 10);
      if (preview === null || preview.id !== id || !this.rdbWaiverRequestCurrent(preview.context, preview.libraryVersion) || size !== 10) return false;
      lib.previewProjection(page, size); this.rdbWaiverPage = page; this.refreshRdbReview(); return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `豁免分页未改变：${String(error)}`; return false; }
  }

  private cancelRdbWaiver(id: string): void {
    if (!this.rdbReviewInitialized) return;
    const preview = this.rdbReviewStorage.library().previewProjection(this.rdbWaiverPage, 10);
    if (preview === null || preview.id !== id) return;
    this.rdbReviewStorage.library().cancel(id);
    if (this.rdbWaiverConfirmationId === id) this.rdbWaiverConfirmationId = '';
    this.rdbWaiverPage = 0; this.refreshRdbReview();
  }

  private revokeRdbWaiverPreview(): void {
    this.rdbWaiverConfirmationId = '';
    if (!this.rdbReviewInitialized) return;
    try { const preview = this.rdbReviewStorage.library().previewProjection(); if (preview !== null) this.rdbReviewStorage.library().cancel(preview.id); }
    catch (_) { /* Blocked storage stays blocked until explicit recovery. */ }
    this.rdbWaiverPage = 0;
  }

  private confirmRdbWaiver(id: string): void {
    try {
      const preview = this.rdbReviewStorage.library().previewProjection(this.rdbWaiverPage, 10);
      if (preview === null || preview.id !== id || !preview.canApply || !this.rdbWaiverRequestCurrent(preview.context, preview.libraryVersion)) return;
      this.rdbWaiverConfirmationId = id;
      const generation: number = this.pageGeneration, ticket: number = this.rdbReviewFileTicket;
      this.canvasFocusReturnTicket++;
      this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius,
        title: preview.operation === 'apply' ? '确认应用豁免库' : '确认移除本库豁免',
        message: `本次将改变 ${preview.summary.changed} 个标记；${preview.summary.conflicts + preview.summary.uncertain} 项被阻断。豁免仅记录审阅依据，不代表检查通过。`,
        primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {
          if (this.rdbWaiverConfirmationId === id) this.rdbWaiverConfirmationId = '';
        } },
        secondaryButton: { value: '确认', fontColor: Color.White, backgroundColor: COLORS.primary, action: () => {
          if (this.rdbWaiverConfirmationId !== id) return;
          this.rdbWaiverConfirmationId = '';
          try {
            if (generation !== this.pageGeneration || ticket !== this.rdbReviewFileTicket ||
              !this.rdbWaiverRequestCurrent(preview.context, preview.libraryVersion)) throw new Error('确认来源已变化，请重新预览');
            const current: RdbWaiverContext | null = this.captureRdbWaiverContext();
            if (current === null) throw new Error('当前报告资格不存在');
            const committed = this.rdbReviewStorage.library().confirm(id, this.rdbReviewWorkspace, current);
            this.rdbReviewBaseline = committed.workspaceJson; this.adoptRdbWorkspace(committed.workspace);
            this.clearRdbReviewOverlay(); this.rdbWaiverPage = 0; this.refreshRdbReview();
            this.verifyStore.rdbReviewStatus = `已确认 ${committed.summary.changed} 个标记的本机审阅；外部报告尚未另存为`;
          } catch (error) { this.verifyStore.rdbReviewStatus = `豁免写入未确认：${String(error)}；必要时重新读取本机工作区`; }
        } } });
    } catch (error) { this.verifyStore.rdbReviewStatus = `豁免确认未打开：${String(error)}`; }
  }

  private deleteRdbWaiver(id: string, version: string): void {
    try {
      const context: RdbWaiverContext | null = this.captureRdbWaiverContext();
      if (context === null || !this.rdbWaiverRequestCurrent(context, version)) return;
      const generation: number = this.pageGeneration;
      this.canvasFocusReturnTicket++;
      this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '删除豁免规则',
        message: '删除规则保留已有报告标记和应用记录。如需解除本库豁免，请先预览并移除。',
        primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {} },
        secondaryButton: { value: '删除规则', fontColor: Color.White, backgroundColor: COLORS.danger, action: () => {
          try {
            if (generation !== this.pageGeneration || !this.rdbWaiverRequestCurrent(context, version)) throw new Error('删除来源已变化');
            this.rdbReviewStorage.library().deleteRule(id, version); this.refreshRdbReview();
          } catch (error) { this.verifyStore.rdbReviewStatus = `规则删除未确认：${String(error)}`; }
        } } });
    } catch (error) { this.verifyStore.rdbReviewStatus = `规则删除未打开：${String(error)}`; }
  }

  private async rdbWaiverFileAction(request: RdbWaiverFileRequest): Promise<void> {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.viewWorkspaceIdle()) return;
    const lib = this.rdbReviewStorage.library(); const generation: number = this.pageGeneration;
    const configuration: string = JSON.stringify(this.captureRdbWaiverContext());
    const ticket: number = ++this.rdbReviewFileTicket;
    const current = (): boolean => this.pageAlive && this.panelStore.showRdbReviewPanel && generation === this.pageGeneration &&
      ticket === this.rdbReviewFileTicket && this.viewWorkspaceIdle() && request.workspaceToken === this.rdbReviewWorkspace.contextToken() &&
      request.libraryVersion === lib.version() && configuration === JSON.stringify(this.captureRdbWaiverContext());
    this.verifyStore.rdbReviewBusy = true;
    try {
      if (!current()) throw new Error('文件请求来源已变化');
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (request.kind === 'import') {
        const picked = await rdbWaiverFileService.pick(host, current);
        if (picked === undefined || !current()) return;
        const count: number = lib.importLibrary(picked.json, request.libraryVersion);
        this.verifyStore.rdbReviewStatus = `已导入 ${count} 条完整豁免规则`;
      } else if (request.kind === 'export') {
        const uri = await rdbWaiverFileService.save(host, lib.exportLibrary(request.libraryVersion), current);
        if (uri === undefined || !current()) return;
        this.verifyStore.rdbReviewStatus = '豁免库规则已导出';
      } else throw new Error('未知豁免文件请求');
      this.refreshRdbReview();
    } catch (error) {
      if (generation === this.pageGeneration && ticket === this.rdbReviewFileTicket) this.verifyStore.rdbReviewStatus = `豁免文件操作未确认：${String(error)}`;
    } finally { if (ticket === this.rdbReviewFileTicket) this.verifyStore.rdbReviewBusy = false; }
  }

  private publishRdbReview(candidate: RdbReviewService, uri: string): void {
    const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
    const id: string = workspace.activeReportId();
    if (id.length === 0) workspace.addSession(candidate, uri, workspace.contextToken());
    else workspace.replaceSession(id, candidate, uri, workspace.reportContext(id));
    this.publishRdbWorkspace(workspace);
  }

  private adoptRdbWorkspace(candidate: RdbReviewWorkspaceService): void {
    const id: string = candidate.activeReportId();
    const core: RdbReviewService = id.length === 0 ? new RdbReviewService() : candidate.session(id);
    const report: RdbReviewWorkspaceReport | undefined = candidate.listReports().find((row: RdbReviewWorkspaceReport): boolean => row.id === id);
    const changed: boolean = id !== this.rdbReviewWorkspace.activeReportId() || core.source()?.identity !== this.rdbReviewCore.source()?.identity;
    this.rdbReviewWorkspace = candidate; this.rdbReviewCore = core; this.rdbReviewUri = report?.uri ?? '';
    if (changed) {
      this.rdbReviewMapping = null;
      const frame = core.isLoaded() ? core.selectedFrame() : undefined;
      const target: string | undefined = core.isLoaded() ? core.selectedFrameTarget() : undefined;
      this.rdbReviewTarget = target ?? ''; this.rdbReviewTargetSet = target !== undefined;
      this.rdbReviewPathIndex = frame?.pathIndex ?? -1;
      this.clearRdbReviewOverlay();
    }
  }

  private publishRdbWorkspace(candidate: RdbReviewWorkspaceService): void {
    // Validate the full detached workspace and active session before the durable CAS.
    candidate.snapshot();
    if (candidate.activeReportId().length > 0) candidate.session(candidate.activeReportId());
    const next: string = JSON.stringify(candidate.exportRecovery());
    this.rdbReviewStorage.compareAndSwap(this.rdbReviewBaseline, next);
    this.rdbReviewBaseline = next; this.adoptRdbWorkspace(candidate);
  }

  private cloneRdbReview(): RdbReviewService {
    const candidate = new RdbReviewService();
    candidate.restoreRecovery(this.rdbReviewCore.exportRecovery());
    return candidate;
  }

  private rdbReviewActionReady(): boolean {
    return this.pageAlive && this.panelStore.showRdbReviewPanel && this.rdbReviewInitialized && !this.verifyStore.rdbReviewBusy;
  }

  private rdbReportActionCurrent(id: string, workspaceToken: string, reportContext: string): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || this.rdbReviewWorkspace.contextToken() !== workspaceToken) return false;
    try { return this.rdbReviewWorkspace.reportContext(id) === reportContext; } catch (_) { return false; }
  }

  private activateRdbReport(id: string, workspaceToken: string, reportContext: string): boolean {
    if (!this.rdbReportActionCurrent(id, workspaceToken, reportContext)) return false;
    try {
      const candidate: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
      candidate.activate(id, workspaceToken); this.publishRdbWorkspace(candidate);
      this.clearRdbReviewOverlay(); this.refreshRdbReview(); this.verifyStore.rdbReviewStatus = '已切换报告，独立筛选和审阅状态已恢复'; return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `报告未切换：${String(error)}`; return false; }
  }

  private closeRdbReport(id: string, workspaceToken: string, reportContext: string): void {
    if (!this.rdbReportActionCurrent(id, workspaceToken, reportContext)) return;
    const report: RdbReviewWorkspaceReport | undefined = this.rdbReviewWorkspace.listReports().find((row: RdbReviewWorkspaceReport): boolean => row.id === id);
    if (report === undefined) return;
    const epoch: number = this.rdbReviewFileTicket;
    const generation: number = this.pageGeneration;
    const close = (): void => {
      if (epoch !== this.rdbReviewFileTicket || generation !== this.pageGeneration || !this.rdbReportActionCurrent(id, workspaceToken, reportContext)) return;
      try {
        const candidate: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
        candidate.close(id, reportContext, report.dirty); this.publishRdbWorkspace(candidate);
        this.clearRdbReviewOverlay(); this.refreshRdbReview();
        this.verifyStore.rdbReviewStatus = report.uri.length > 0 ? `已关闭“${report.name}”，外部报告文件保留` : `已关闭“${report.name}”`;
      } catch (error) { this.verifyStore.rdbReviewStatus = `报告未关闭：${String(error)}`; }
    };
    if (!report.dirty) { close(); return; }
    const confirmationId: string = newLayoutIdentity('rdb-close-confirm');
    this.rdbReportCloseConfirmationId = confirmationId;
    const cancelConfirmation = (): void => {
      if (this.rdbReportCloseConfirmationId === confirmationId) this.rdbReportCloseConfirmationId = '';
    };
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ title: '关闭未导出的报告',
      message: `“${report.name}”还有未导出的审阅。关闭将移除此报告的本机恢复草稿，可取消后另存为。`,
      cancel: cancelConfirmation,
      onWillDismiss: (action: DismissDialogAction): void => { cancelConfirmation(); action.dismiss(); },
      primaryButton: { value: '取消', action: cancelConfirmation }, secondaryButton: { value: '放弃并关闭', action: () => {
        if (this.rdbReportCloseConfirmationId !== confirmationId) return;
        this.rdbReportCloseConfirmationId = ''; close();
      } } });
  }

  private rdbReportFileAction(kind: string, id: string, workspaceToken: string, reportContext: string): void {
    if (!['save', 'reload'].includes(kind) || !this.rdbReportActionCurrent(id, workspaceToken, reportContext)) return;
    const report: RdbReviewWorkspaceReport | undefined = this.rdbReviewWorkspace.listReports().find((row: RdbReviewWorkspaceReport): boolean => row.id === id);
    if (report === undefined) return;
    const epoch: number = this.rdbReviewFileTicket;
    const generation: number = this.pageGeneration;
    const perform = (): void => {
      if (epoch === this.rdbReviewFileTicket && generation === this.pageGeneration && this.rdbReportActionCurrent(id, workspaceToken, reportContext)) {
        this.performRdbWorkspaceFileAction(kind, id, workspaceToken, reportContext);
      }
    };
    if (kind === 'reload' && report.dirty) {
      const confirmationId: string = newLayoutIdentity('rdb-reload-confirm');
      this.rdbReportReloadConfirmationId = confirmationId;
      const cancelConfirmation = (): void => {
        if (this.rdbReportReloadConfirmationId === confirmationId) this.rdbReportReloadConfirmationId = '';
      };
      this.canvasFocusReturnTicket++;
      this.getUIContext().showAlertDialog({ title: '重新载入报告', message: `重新载入“${report.name}”将替换这份报告未导出的审阅。其他报告保持独立。`,
        cancel: cancelConfirmation,
        onWillDismiss: (action: DismissDialogAction): void => { cancelConfirmation(); action.dismiss(); },
        primaryButton: { value: '取消', action: cancelConfirmation }, secondaryButton: { value: '重新载入', action: () => {
          if (this.rdbReportReloadConfirmationId !== confirmationId) return;
          this.rdbReportReloadConfirmationId = ''; perform();
        } } });
    } else perform();
  }

  private rdbReviewMappingCurrent(): boolean {
    const mapping: RdbReviewLayoutMapping | null = this.rdbReviewMapping;
    return mapping !== null && this.docStore.workspaceReady && !this.importInProgress && this.docStore.activeNativeJobId.length === 0 &&
      mapping.reportSourceIdentity === this.rdbReviewCore.source()?.identity &&
      mapping.layoutDocumentId === this.docStore.activeWorkspaceId && mapping.layoutRevision === editService.getSessionRevision() &&
      this.docCellKeys[mapping.layoutCellId] === mapping.layoutCellKey &&
      this.placeableCells.some((cell: CellInfo): boolean => cell.id === mapping.layoutCellId);
  }

  private rdbTransferCurrent(id: string): boolean {
    const request: RdbTransferUiRequest | null = this.rdbTransferRequest;
    if (this.rdbTransferPlan === null || request === null || id.length === 0 || id !== this.rdbTransferPreviewId ||
      request.workspaceToken !== this.rdbReviewWorkspace.contextToken()) return false;
    try {
      return request.sourceReportId !== request.targetReportId &&
        this.rdbReviewWorkspace.reportContext(request.sourceReportId) === request.sourceContext &&
        this.rdbReviewWorkspace.reportContext(request.targetReportId) === request.targetContext;
    } catch (_) { return false; }
  }

  private rdbTransferProjection(): RdbTransferUiPreview | null {
    if (!this.rdbTransferCurrent(this.rdbTransferPreviewId) || this.rdbTransferPlan === null || this.rdbTransferRequest === null) {
      this.rdbTransferPlan = null; this.rdbTransferRequest = null; this.rdbTransferPreviewId = ''; return null;
    }
    const plan: RdbReviewTransferPlan = this.rdbTransferPlan;
    const pages: number = Math.max(1, Math.ceil(plan.rows.length / this.rdbTransferPageSize));
    const page: number = Math.min(this.rdbTransferPageIndex, pages - 1);
    const start: number = page * this.rdbTransferPageSize;
    return { id: this.rdbTransferPreviewId, request: cloneStructured(this.rdbTransferRequest) as RdbTransferUiRequest,
      summary: cloneStructured(plan.summary) as RdbReviewTransferSummary, pageIndex: page, pageSize: this.rdbTransferPageSize,
      totalRows: plan.rows.length, pageCount: pages,
      rows: plan.rows.slice(start, start + this.rdbTransferPageSize).map((row: RdbReviewTransferRow): RdbTransferUiRow => this.projectRdbTransferRow(row)),
      canApply: plan.canApply && plan.summary.changed > 0,
      message: plan.summary.blocked > 0 ? (plan.options.blockedPolicy === 'skip' ? '仅应用可继承项；冲突和无法匹配的标记保持原样' : '存在冲突，整批尚不能应用；请检查记录或明确选择跳过冲突') :
        plan.summary.changed === 0 ? '没有需要更新的审阅内容' : '预览已生成，尚未写入目标报告' };
  }

  private projectRdbTransferRow(row: RdbReviewTransferRow): RdbTransferUiRow {
    let changes: RdbTransferUiChanges | undefined = undefined;
    if (row.changes !== undefined) {
      const full = row.changes;
      changes = { comment: full.comment, visited: full.visited, waived: full.waived, important: full.important,
        userTags: full.userTags, image: full.image === undefined ? undefined : {
          beforeCharacters: full.image.before.length, afterCharacters: full.image.after.length } };
    }
    const projected: RdbTransferUiRow = { targetIndex: row.targetIndex, sourceIndices: row.sourceIndices,
      status: row.status, reason: row.reason, applicable: row.applicable, changes };
    return cloneStructured(projected) as RdbTransferUiRow;
  }

  private previewRdbTransfer(request: RdbTransferUiRequest): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      if (request.sourceReportId === request.targetReportId || request.workspaceToken !== this.rdbReviewWorkspace.contextToken() ||
        this.rdbReviewWorkspace.reportContext(request.sourceReportId) !== request.sourceContext ||
        this.rdbReviewWorkspace.reportContext(request.targetReportId) !== request.targetContext) throw new Error('来源、目标或报告内容已改变，请重新选择');
      const source = this.rdbReviewWorkspace.session(request.sourceReportId).document();
      const target = this.rdbReviewWorkspace.session(request.targetReportId).document();
      const preview = rdbReviewTransferService.preview(source, target, request.options);
      if (!preview.ok || preview.plan === undefined) throw new Error(preview.message);
      this.rdbTransferPlan = preview.plan;
      this.rdbTransferRequest = cloneStructured(request) as RdbTransferUiRequest;
      this.rdbTransferPreviewId = newLayoutIdentity('rdb-transfer'); this.rdbTransferPageIndex = 0;
      this.verifyStore.rdbReviewStatus = `已检查 ${preview.plan.summary.targetItems} 条目标标记，${preview.plan.summary.changed} 条可更新；尚未应用`;
      this.refreshRdbReview(); return true;
    } catch (error) {
      this.rdbTransferPlan = null; this.rdbTransferRequest = null; this.rdbTransferPreviewId = '';
      this.verifyStore.rdbReviewStatus = `继承预览未生成：${String(error)}`; this.refreshRdbReview(); return false;
    }
  }

  private pageRdbTransfer(id: string, page: number, size: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.rdbTransferCurrent(id) || this.rdbTransferPlan === null) return false;
    if (!Number.isSafeInteger(size) || size < 1 || size > 200 || !Number.isSafeInteger(page) || page < 0 ||
      page >= Math.max(1, Math.ceil(this.rdbTransferPlan.rows.length / size))) return false;
    this.rdbTransferPageIndex = page; this.rdbTransferPageSize = size; this.refreshRdbReview(); return true;
  }

  private cancelRdbTransfer(id: string): void {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || id !== this.rdbTransferPreviewId) return;
    this.rdbTransferConfirmationId = '';
    this.rdbTransferPlan = null; this.rdbTransferRequest = null; this.rdbTransferPreviewId = '';
    this.refreshRdbReview(); this.verifyStore.rdbReviewStatus = '已取消预览，报告内容未改变';
  }

  private applyRdbTransfer(id: string): void {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.rdbTransferCurrent(id) ||
      this.rdbTransferPlan === null || this.rdbTransferRequest === null || !this.rdbTransferPlan.canApply || this.rdbTransferPlan.summary.changed === 0) return;
    const request: RdbTransferUiRequest = cloneStructured(this.rdbTransferRequest) as RdbTransferUiRequest;
    const plan: RdbReviewTransferPlan = this.rdbTransferPlan;
    const reports: RdbReviewWorkspaceReport[] = this.rdbReviewWorkspace.listReports();
    const sourceName: string = reports.find((row: RdbReviewWorkspaceReport): boolean => row.id === request.sourceReportId)!.name;
    const targetName: string = reports.find((row: RdbReviewWorkspaceReport): boolean => row.id === request.targetReportId)!.name;
    const epoch: number = this.rdbReviewFileTicket, generation: number = this.pageGeneration;
    const confirmationId: string = newLayoutIdentity('rdb-transfer-confirm');
    this.rdbTransferConfirmationId = confirmationId;
    const cancelConfirmation = (): void => {
      if (this.rdbTransferConfirmationId === confirmationId) this.rdbTransferConfirmationId = '';
    };
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ title: '确认继承审阅',
      message: `将“${sourceName}”的所选审阅内容应用到“${targetName}”：更新 ${plan.summary.changed} 条，跳过 ${plan.summary.unmatched + plan.summary.blocked} 条。目标报告仍需另存为以更新外部文件。`,
      cancel: cancelConfirmation,
      onWillDismiss: (action: DismissDialogAction): void => { cancelConfirmation(); action.dismiss(); },
      primaryButton: { value: '取消', action: cancelConfirmation }, secondaryButton: { value: '应用继承', action: () => {
        if (this.rdbTransferConfirmationId !== confirmationId) return;
        this.rdbTransferConfirmationId = '';
        if (epoch !== this.rdbReviewFileTicket || generation !== this.pageGeneration || !this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.rdbTransferCurrent(id)) return;
        try {
          const source = this.rdbReviewWorkspace.session(request.sourceReportId);
          const target = this.rdbReviewWorkspace.session(request.targetReportId);
          const applied = rdbReviewTransferService.apply(source.document(), target.document(), plan);
          if (!applied.ok || applied.document === undefined) throw new Error(applied.message);
          target.applyReviewDocument(applied.document, target.contextToken());
          const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
          const targetReport: RdbReviewWorkspaceReport = workspace.listReports().find((row: RdbReviewWorkspaceReport): boolean => row.id === request.targetReportId)!;
          workspace.replaceSession(request.targetReportId, target, targetReport.uri, request.targetContext);
          this.publishRdbWorkspace(workspace);
          this.rdbTransferPlan = null; this.rdbTransferRequest = null; this.rdbTransferPreviewId = '';
          this.clearRdbReviewOverlay(); this.refreshRdbReview();
          this.verifyStore.rdbReviewStatus = `已向“${targetName}”继承 ${applied.appliedTargetIndices?.length ?? 0} 条审阅，外部报告尚未更新`;
        } catch (error) { this.verifyStore.rdbReviewStatus = `继承未确认写入，预览保留：${String(error)}`; }
      } } });
  }

  private clearRdbMergePreview(): void {
    this.rdbMergePlan = null; this.rdbMergeRequest = null; this.rdbMergeSources = [];
    this.rdbMergePreviewId = ''; this.rdbMergeConfirmationId = ''; this.rdbMergePageIndex = 0;
  }

  private rdbMergeInputs(request: RdbMergeUiRequest): RdbMergeInput[] {
    if (request.workspaceToken !== this.rdbReviewWorkspace.contextToken() || !Array.isArray(request.sources)) {
      throw new Error('报告工作区已改变，请重新选择来源');
    }
    const ids: string[] = request.sources.map((source): string => source.reportId);
    const bindings: RdbReviewWorkspaceSourceBinding[] = this.rdbReviewWorkspace.captureSources(ids, request.workspaceToken);
    return bindings.map((binding: RdbReviewWorkspaceSourceBinding, index: number): RdbMergeInput => {
      const requested = request.sources[index];
      if (requested.sourceIdentity !== binding.sourceIdentity ||
        requested.reportContext !== this.rdbReviewWorkspace.reportContext(binding.reportId)) {
        throw new Error('来源报告的内容或导航已改变，请刷新后重新预览');
      }
      return { reportId: binding.reportId, sourceIdentity: binding.sourceIdentity, contentToken: binding.contentToken,
        document: this.rdbReviewWorkspace.session(binding.reportId).document() };
    });
  }

  private rdbMergeCurrent(id: string): boolean {
    const request: RdbMergeUiRequest | null = this.rdbMergeRequest;
    const plan: RdbMergePlan | null = this.rdbMergePlan;
    if (request === null || plan === null || id.length === 0 || id !== this.rdbMergePreviewId ||
      request.workspaceToken !== this.rdbReviewWorkspace.contextToken() || request.sources.length !== this.rdbMergeSources.length) return false;
    try {
      const reports: RdbReviewWorkspaceReport[] = this.rdbReviewWorkspace.listReports();
      return request.sources.every((source, index: number): boolean => {
        const binding: RdbReviewWorkspaceSourceBinding = this.rdbMergeSources[index];
        return source.reportId === binding.reportId && source.sourceIdentity === binding.sourceIdentity &&
          source.reportContext === this.rdbReviewWorkspace.reportContext(source.reportId) &&
          binding.contentToken === this.rdbReviewWorkspace.reportContentToken(source.reportId) &&
          binding.sourceIdentity === reports.find((report: RdbReviewWorkspaceReport): boolean => report.id === source.reportId)?.source.identity;
      });
    } catch (_) { return false; }
  }

  private rdbMergeProjection(): RdbMergeUiPreview | null {
    if (!this.rdbMergeCurrent(this.rdbMergePreviewId) || this.rdbMergePlan === null || this.rdbMergeRequest === null) {
      this.clearRdbMergePreview(); return null;
    }
    const plan: RdbMergePlan = this.rdbMergePlan;
    const pages: number = Math.max(1, Math.ceil(plan.rows.length / this.rdbMergePageSize));
    const page: number = Math.min(this.rdbMergePageIndex, pages - 1);
    const start: number = page * this.rdbMergePageSize;
    const room: boolean = this.rdbReviewWorkspace.listReports().length < defaultRdbReviewWorkspaceLimits().maximumReports;
    return { id: this.rdbMergePreviewId, request: cloneStructured(this.rdbMergeRequest) as RdbMergeUiRequest,
      summary: cloneStructured(plan.summary) as RdbMergeSummary,
      rows: cloneStructured(plan.rows.slice(start, start + this.rdbMergePageSize)) as RdbMergeRow[],
      pageIndex: page, pageSize: this.rdbMergePageSize, pageCount: pages, totalRows: plan.rows.length,
      canApply: plan.canApply && room, notices: plan.notices.slice(),
      message: !room ? '报告数量已达上限，请先另存并关闭不再需要的报告' :
        plan.canApply ? '预览已生成；确认后创建未导出的独立报告，来源保持不变' : '存在结构冲突，请检查完整映射或选择按来源隔离' };
  }

  private previewRdbMerge(request: RdbMergeUiRequest): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      const inputs: RdbMergeInput[] = this.rdbMergeInputs(request);
      const preview = rdbMergeService.preview(inputs, request.options);
      if (!preview.ok || preview.plan === undefined) throw new Error(preview.message);
      this.rdbMergeSources = this.rdbReviewWorkspace.captureSources(inputs.map((input: RdbMergeInput): string => input.reportId), request.workspaceToken);
      this.rdbMergePlan = preview.plan;
      this.rdbMergeRequest = cloneStructured(request) as RdbMergeUiRequest;
      this.rdbMergePreviewId = newLayoutIdentity('rdb-merge'); this.rdbMergePageIndex = 0;
      this.verifyStore.rdbReviewStatus = `已预览 ${preview.plan.summary.sources} 份来源、${preview.plan.summary.inputItems} 个标记；尚未创建报告`;
      this.refreshRdbReview(); return true;
    } catch (error) {
      this.clearRdbMergePreview();
      this.verifyStore.rdbReviewStatus = `合并预览未生成：${String(error)}`; this.refreshRdbReview(); return false;
    }
  }

  private pageRdbMerge(id: string, page: number, size: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.rdbMergeCurrent(id) || this.rdbMergePlan === null) return false;
    if (!Number.isSafeInteger(size) || size < 1 || size > 200 || !Number.isSafeInteger(page) || page < 0 ||
      page >= Math.max(1, Math.ceil(this.rdbMergePlan.rows.length / size))) return false;
    this.rdbMergePageIndex = page; this.rdbMergePageSize = size; this.refreshRdbReview(); return true;
  }

  private cancelRdbMerge(id: string): void {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || id !== this.rdbMergePreviewId) return;
    this.clearRdbMergePreview(); this.refreshRdbReview(); this.verifyStore.rdbReviewStatus = '已取消合并预览，来源报告保持不变';
  }

  private applyRdbMerge(id: string): void {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.rdbMergeCurrent(id) ||
      this.rdbMergePlan === null || this.rdbMergeRequest === null || !this.rdbMergePlan.canApply) return;
    const request: RdbMergeUiRequest = cloneStructured(this.rdbMergeRequest) as RdbMergeUiRequest;
    const plan: RdbMergePlan = this.rdbMergePlan;
    const bindings: RdbReviewWorkspaceSourceBinding[] = cloneStructured(this.rdbMergeSources) as RdbReviewWorkspaceSourceBinding[];
    const epoch: number = this.rdbReviewFileTicket, generation: number = this.pageGeneration;
    const confirmationId: string = newLayoutIdentity('rdb-merge-confirm');
    this.rdbMergeConfirmationId = confirmationId;
    const cancelConfirmation = (): void => {
      if (this.rdbMergeConfirmationId === confirmationId) this.rdbMergeConfirmationId = '';
    };
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ title: '确认创建合并报告',
      message: `将 ${plan.summary.sources} 份来源的全部 ${plan.summary.inputItems} 个标记合并为“${plan.options.outputName}”。来源报告保留，新报告仍需另存为。`,
      cancel: cancelConfirmation,
      onWillDismiss: (action: DismissDialogAction): void => { cancelConfirmation(); action.dismiss(); },
      primaryButton: { value: '取消', action: cancelConfirmation }, secondaryButton: { value: '创建新报告', action: () => {
        if (this.rdbMergeConfirmationId !== confirmationId) return;
        this.rdbMergeConfirmationId = '';
        if (epoch !== this.rdbReviewFileTicket || generation !== this.pageGeneration || !this.rdbReviewActionReady() ||
          this.rdbReviewDraftDirty || !this.rdbMergeCurrent(id)) return;
        try {
          const applied = rdbMergeService.apply(this.rdbMergeInputs(request), plan);
          if (!applied.ok || applied.document === undefined || applied.outputName === undefined) throw new Error(applied.message);
          const session: RdbReviewService = new RdbReviewService();
          session.loadGenerated(applied.document, { identity: newLayoutIdentity('rdb-merged'), name: applied.outputName });
          const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
          workspace.addMergedSession(session, bindings, request.workspaceToken);
          this.publishRdbWorkspace(workspace);
          this.clearRdbMergePreview(); this.clearRdbReviewOverlay(); this.refreshRdbReview();
          this.verifyStore.rdbReviewStatus = `已创建“${applied.outputName}”，${applied.document.items.length} 个标记；来源保留，新报告尚未另存为`;
        } catch (error) { this.verifyStore.rdbReviewStatus = `合并未确认写入，预览保留：${String(error)}`; }
      } } });
  }

  private refreshRdbReview(): void {
    const core: RdbReviewService = this.rdbReviewCore;
    const state: RdbReviewUiState = emptyRdbReviewUiState();
    state.workspaceToken = this.rdbReviewWorkspace.contextToken();
    state.activeReportId = this.rdbReviewWorkspace.activeReportId();
    state.reports = this.rdbReviewWorkspace.listReports();
    state.reportLimit = defaultRdbReviewWorkspaceLimits().maximumReports;
    state.transferPreview = this.rdbTransferProjection();
    state.mergePreview = this.rdbMergeProjection();
    if (this.rdbReviewInitialized) {
      const lib = this.rdbReviewStorage.library();
      state.waiverLibrary = lib.snapshot(); state.waiverContext = this.captureRdbWaiverContext();
      state.waiverPreview = lib.previewProjection(this.rdbWaiverPage, 10);
    }
    state.layoutDocumentTitle = this.docStore.currentDocumentTitle;
    state.layoutCells = this.placeableCells.map((cell: CellInfo): RdbReviewLayoutCell => ({
      id: cell.id, key: this.docCellKeys[cell.id] ?? '', name: cell.name })).filter((cell: RdbReviewLayoutCell): boolean => cell.key.length > 0);
    if (!core.isLoaded()) { this.verifyStore.rdbReviewUi = state; return; }
    const document: RdbDocument = core.document();
    state.token = core.contextToken(); state.loaded = true; state.dirty = core.isDirty(); state.sourceName = core.source()!.name;
    state.description = document.description; state.originalFile = document.originalFile;
    state.generator = document.generator; state.topCell = document.topCell;
    state.page = core.page(); state.filter = core.snapshot().filter; state.selected = core.selectedItem() ?? null;
    state.statistics = core.statistics();
    const categoryCounts: Map<string, number> = new Map<string, number>();
    const cellCounts: Map<string, number> = new Map<string, number>();
    const tags: Map<string, RdbTagRef> = new Map<string, RdbTagRef>();
    for (const item of document.items) {
      cellCounts.set(item.cell, (cellCounts.get(item.cell) ?? 0) + 1);
      for (let depth: number = 1; depth <= item.category.length; depth++) {
        const key: string = JSON.stringify(item.category.slice(0, depth));
        categoryCounts.set(key, (categoryCounts.get(key) ?? 0) + 1);
      }
      for (const tag of item.tags) tags.set(JSON.stringify(tag), { name: tag.name, user: tag.user });
    }
    const append = (categories: RdbCategory[], prefix: string[]): void => {
      for (const category of categories) {
        const path: string[] = prefix.concat([category.name]);
        state.categories.push({ path, label: path.join(' / '), description: category.description,
          count: categoryCounts.get(JSON.stringify(path)) ?? 0 });
        append(category.categories, path);
      }
    };
    append(document.categories, []);
    state.cells = document.cells.map((cell: RdbCell): RdbReviewCellChoice => ({
      qname: rdbCellQName(cell), name: cell.name, variant: cell.variant, layoutName: cell.layoutName,
      count: cellCounts.get(rdbCellQName(cell)) ?? 0 }));
    tags.forEach((tag: RdbTagRef): void => { state.tags.push({ tag, label: (tag.user ? '#' : '') + tag.name }); });
    if (state.selected !== null) {
      if (!this.rdbReviewTargetSet || !document.cells.some((cell: RdbCell): boolean => rdbCellQName(cell) === this.rdbReviewTarget)) {
        this.rdbReviewTarget = state.selected.item.cell; this.rdbReviewTargetSet = true; this.rdbReviewPathIndex = -1;
      }
      state.frameTarget = this.rdbReviewTarget;
      try {
        state.frames = core.framePaths(state.selected.index, this.rdbReviewTarget);
        if (this.rdbReviewPathIndex < 0 && state.frames.length === 1) this.rdbReviewPathIndex = 0;
        if (this.rdbReviewPathIndex >= state.frames.length) this.rdbReviewPathIndex = -1;
        state.frameIndex = this.rdbReviewPathIndex;
        state.frameMessage = state.frames.length > 1 ? `${state.frames.length} 条报告引用路径，请选择具体变换` : '报告引用坐标系已解析';
      } catch (error) { state.frameMessage = String(error); this.rdbReviewPathIndex = -1; }
      const image = describeRdbMarkerImage(state.selected.item.image);
      if (image.ok && image.image !== undefined) state.imageSource = image.image.dataUri;
      state.imageNotice = image.message;
    }
    if (this.rdbReviewMapping === null || this.rdbReviewMapping.reportCell !== this.rdbReviewTarget) {
      this.rdbReviewMapping = this.rdbReviewLayoutMappings.find((value: RdbReviewLayoutMapping): boolean =>
        value.reportSourceIdentity === core.source()?.identity && value.reportCell === this.rdbReviewTarget &&
        value.layoutDocumentId === this.docStore.activeWorkspaceId && value.layoutRevision === editService.getSessionRevision() &&
        this.docCellKeys[value.layoutCellId] === value.layoutCellKey) ?? null;
    }
    state.mappingCurrent = this.rdbReviewMappingCurrent() && this.rdbReviewMapping!.reportCell === this.rdbReviewTarget;
    state.boundLayoutCellId = state.mappingCurrent ? this.rdbReviewMapping!.layoutCellId : -1;
    if (state.mappingCurrent && state.selected !== null && state.frameIndex >= 0) {
      try { state.canLocate = core.planLocation(state.selected.index, this.rdbReviewMapping!, state.frameIndex).boundsNm !== undefined; }
      catch (_) { state.canLocate = false; }
    }
    this.verifyStore.rdbReviewUi = state;
  }

  private openRdbReview(): void {
    this.finishNudgeTransaction();
    this.panelStore.showRdbReviewPanel = true; this.rdbReviewFileTicket++; this.verifyStore.rdbReviewBusy = false;
    this.initializeRdbReview(); this.refreshRdbReview();
  }

  private closeRdbReview(): void {
    if (this.rdbReviewDraftDirty) { this.verifyStore.rdbReviewStatus = '请先保存审阅或取消编辑，再关闭面板'; return; }
    this.rdbReportCloseConfirmationId = ''; this.rdbReportReloadConfirmationId = '';
    this.revokeRdbWaiverPreview();
    this.clearRdbMergePreview();
    this.rdbTransferConfirmationId = '';
    this.rdbReviewFileTicket++; this.verifyStore.rdbReviewBusy = false; this.panelStore.showRdbReviewPanel = false;
  }

  private filterRdbReview(filter: RdbReviewFilter): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      const candidate: RdbReviewService = this.cloneRdbReview(); candidate.setQuery(filter);
      this.publishRdbReview(candidate, this.rdbReviewUri); this.clearRdbReviewOverlay(); this.refreshRdbReview(); return true;
    }
    catch (error) { this.verifyStore.rdbReviewStatus = `筛选未改变：${String(error)}`; return false; }
  }

  private pageRdbReview(index: number, size: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      const candidate: RdbReviewService = this.cloneRdbReview(); candidate.setPage(index, size);
      this.publishRdbReview(candidate, this.rdbReviewUri); this.clearRdbReviewOverlay(); this.refreshRdbReview(); return true;
    }
    catch (error) { this.verifyStore.rdbReviewStatus = `分页未改变：${String(error)}`; return false; }
  }

  private selectRdbReview(index: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      const candidate: RdbReviewService = this.cloneRdbReview(); candidate.selectItem(index);
      this.publishRdbReview(candidate, this.rdbReviewUri);
      this.rdbReviewTarget = ''; this.rdbReviewTargetSet = false; this.rdbReviewPathIndex = -1; this.clearRdbReviewOverlay();
      this.refreshRdbReview(); return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `标记未选择：${String(error)}`; return false; }
  }

  private updateRdbReview(index: number, patch: RdbReviewPatch, expectedContext: string): boolean {
    if (!this.rdbReviewActionReady()) return false;
    try {
      if (this.rdbReviewCore.contextToken() !== expectedContext || this.rdbReviewCore.selectedItem()?.index !== index) throw new Error('报告或所选标记已改变');
      const candidate: RdbReviewService = this.cloneRdbReview();
      candidate.updateReview(index, patch, candidate.contextToken());
      this.publishRdbReview(candidate, this.rdbReviewUri);
      this.rdbReviewDraftDirty = false; this.clearRdbReviewOverlay(); this.refreshRdbReview();
      this.verifyStore.rdbReviewStatus = '审阅已写入本机恢复草稿；另存为可更新外部 RDB 文件'; return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `审阅未确认保存，输入保留：${String(error)}`; return false; }
  }

  private frameRdbReview(target: string, pathIndex: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) return false;
    try {
      const selected: RdbReviewRow | undefined = this.rdbReviewCore.selectedItem();
      if (selected === undefined) throw new Error('请先选择标记');
      const paths: RdbFramePath[] = this.rdbReviewCore.framePaths(selected.index, target);
      const chosen: number = pathIndex < 0 && paths.length === 1 ? 0 : pathIndex;
      const candidate: RdbReviewService = this.cloneRdbReview();
      candidate.selectFrameTarget(selected.index, target);
      if (chosen >= 0) candidate.selectFrame(selected.index, target, chosen);
      this.publishRdbReview(candidate, this.rdbReviewUri);
      if (target !== this.rdbReviewTarget) this.rdbReviewMapping = null;
      this.rdbReviewTarget = target; this.rdbReviewTargetSet = true; this.rdbReviewPathIndex = chosen;
      this.clearRdbReviewOverlay(); this.refreshRdbReview(); return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `引用坐标系未改变：${String(error)}`; return false; }
  }

  private bindRdbReview(reportCell: string, layoutCellId: number): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.viewWorkspaceIdle()) return false;
    try {
      if (reportCell !== this.rdbReviewTarget || !this.verifyStore.rdbReviewUi.cells.some((cell: RdbReviewCellChoice): boolean => cell.qname === reportCell)) throw new Error('报告坐标系已变化');
      if (layoutCellId === -1) {
        const mappings: RdbReviewLayoutMapping[] = this.rdbReviewLayoutMappings.filter((value: RdbReviewLayoutMapping): boolean =>
          value.reportSourceIdentity !== this.rdbReviewCore.source()?.identity || value.reportCell !== reportCell || value.layoutDocumentId !== this.docStore.activeWorkspaceId);
        this.integratedReviewWorkspace.writeLayoutMappings(this.rdbReviewLayoutMappings, mappings);
        this.rdbReviewLayoutMappings = mappings; this.rdbReviewMapping = null;
        this.clearRdbReviewOverlay(); this.refreshRdbReview(); this.verifyStore.rdbReviewStatus = '当前报告 Cell 的布局关联已解除'; return true;
      }
      const cell: RdbReviewLayoutCell | undefined = this.verifyStore.rdbReviewUi.layoutCells.find((value: RdbReviewLayoutCell): boolean => value.id === layoutCellId);
      if (cell === undefined || this.docCellKeys[cell.id] !== cell.key) throw new Error('所选布局 Cell 已改变');
      const mapping: RdbReviewLayoutMapping = { reportSourceIdentity: this.rdbReviewCore.source()!.identity, reportCell,
        layoutDocumentId: this.docStore.activeWorkspaceId, layoutRevision: editService.getSessionRevision(), layoutCellId, layoutCellKey: cell.key };
      const mappings: RdbReviewLayoutMapping[] = this.rdbReviewLayoutMappings.filter((value: RdbReviewLayoutMapping): boolean =>
        value.reportSourceIdentity !== mapping.reportSourceIdentity || value.reportCell !== reportCell || value.layoutDocumentId !== this.docStore.activeWorkspaceId);
      mappings.push(mapping);
      this.integratedReviewWorkspace.writeLayoutMappings(this.rdbReviewLayoutMappings, mappings);
      this.rdbReviewLayoutMappings = mappings; this.rdbReviewMapping = mapping;
      this.clearRdbReviewOverlay(); this.refreshRdbReview();
      this.verifyStore.rdbReviewStatus = `已明确关联“${reportCell}”到 ${this.docStore.currentDocumentTitle} / ${cell.name}；报告不代表检查通过`; return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `未关联布局：${String(error)}`; return false; }
  }

  private clearRdbReviewOverlay(): void {
    this.verifyStore.rdbMarkerItem = null; this.rdbMarkerDocumentId = ''; this.rdbMarkerLayoutRevision = -1;
    this.rdbMarkerCellId = -1; this.rdbMarkerCellKey = ''; this.rdbMarkerReportToken = '';
  }

  private rdbReviewOverlayCurrent(): boolean {
    return this.verifyStore.rdbMarkerItem !== null && this.rdbMarkerDocumentId === this.docStore.activeWorkspaceId &&
      this.rdbMarkerLayoutRevision === editService.getSessionRevision() && this.rdbMarkerCellId === editService.getCurrentCellId() &&
      this.docCellKeys[this.rdbMarkerCellId] === this.rdbMarkerCellKey && this.rdbMarkerReportToken === this.rdbReviewCore.contextToken();
  }

  private locateRdbReview(): boolean {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !this.viewWorkspaceIdle()) return false;
    try {
      if (!this.rdbReviewMappingCurrent() || this.rdbReviewMapping === null) throw new Error('布局来源或版本已改变，请重新关联');
      const selected: RdbReviewRow | undefined = this.rdbReviewCore.selectedItem();
      if (selected === undefined) throw new Error('尚未选择标记');
      const plan: RdbReviewLocationPlan = this.rdbReviewCore.planLocation(selected.index, this.rdbReviewMapping, this.rdbReviewPathIndex);
      if (plan.boundsNm === undefined) throw new Error('此标记没有非空几何，只能浏览信息');
      const geometry = planRdbMarkerGeometry(selected.item, plan.path.transform);
      if (!geometry.ok) throw new Error(geometry.message);
      if (!this.rdbReviewMappingCurrent() || !this.rdbReviewCore.isLocationCurrent(plan, this.rdbReviewMapping)) throw new Error('定位来源已失效');
      const dirtyBefore: boolean = this.docStore.documentDirty;
      const documentBefore: string = this.docStore.activeWorkspaceId, revisionBefore: number = editService.getSessionRevision();
      const stackBefore: number[] = editService.getCurrentCellStack(), selectedBefore: number[] = editService.getSelectedIds();
      const pathBefore: InstancePathStep[] = editService.getNavigationPath();
      const zoomBefore: number = this.viewportStore.zoomPercent, offsetXBefore: number = this.viewportStore.viewOffsetX, offsetYBefore: number = this.viewportStore.viewOffsetY;
      const cellId: number = plan.mapping.layoutCellId;
      try {
        if (cellId !== editService.getCurrentCellId()) {
          editService.exitToTop();
          if (cellId !== editService.getCurrentCellId()) editService.enterCell(cellId);
        }
        this.focusWorldBounds({ minX: plan.boundsNm.minX, minY: plan.boundsNm.minY,
          maxX: plan.boundsNm.maxX, maxY: plan.boundsNm.maxY });
        try { this.syncShapesFromEditService(); } finally { this.docStore.documentDirty = dirtyBefore || editService.isDirty(); }
        this.rebuildCellTree(); this.refreshWorkspaceTabs();
      } catch (error) {
        // Restore presentation only; never reload the editor database or its undo history.
        if (this.docStore.activeWorkspaceId === documentBefore && editService.getSessionRevision() === revisionBefore) {
          this.viewportStore.zoomPercent = zoomBefore; this.viewportStore.viewOffsetX = offsetXBefore; this.viewportStore.viewOffsetY = offsetYBefore;
          editService.exitToTop();
          for (let index: number = 1; index < stackBefore.length; index++) editService.enterCell(stackBefore[index]);
          if (pathBefore.length > 0 && !editService.restoreNavigationPath(pathBefore)) throw new Error(`定位失败，实例导航恢复失败：${String(error)}`);
          editService.selectMultiple(selectedBefore);
          try {
            viewService.setViewZoomPercent(zoomBefore); viewService.setViewOffset(offsetXBefore, offsetYBefore);
          } finally {
            try { this.syncShapesFromEditService(); this.rebuildCellTree(); this.refreshWorkspaceTabs(); }
            finally { this.docStore.documentDirty = dirtyBefore || editService.isDirty(); }
          }
        }
        throw new Error(String(error));
      }
      this.verifyStore.rdbMarkerItem = selected.item; this.verifyStore.rdbMarkerFrame = plan.path.transform;
      this.rdbMarkerDocumentId = plan.mapping.layoutDocumentId; this.rdbMarkerLayoutRevision = plan.mapping.layoutRevision;
      this.rdbMarkerCellId = cellId; this.rdbMarkerCellKey = plan.mapping.layoutCellKey;
      this.rdbMarkerReportToken = this.rdbReviewCore.contextToken();
      this.scheduleWorkspaceDraft();
      this.verifyStore.rdbReviewStatus = `已定位标记 #${selected.index + 1}；仅显示报告标记` +
        (plan.conservativePath ? '，PATH 范围用于保守适配' : '') + (plan.labelAnchorOnly ? '，文字以锚点定位' : '');
      return true;
    } catch (error) { this.verifyStore.rdbReviewStatus = `未定位：${String(error)}`; return false; }
  }

  private currentDrcReviewDocument(): RdbDocument {
    if (!this.canExportDrcRdb() || this.drcRdbResult === null) throw new Error('当前 DRC 来源已改变，请重新检查');
    const result: DrcResult = this.drcRdbResult;
    const report: RdbViolationReport = { description: '鸿图当前 DRC 预检查报告', originalFile: this.docStore.currentDocumentTitle,
      generator: 'HongTu', cellName: this.drcRdbCellName,
      runNotice: `输入 ${this.docStore.activeWorkspaceId} / ${this.drcRdbInputVersion}；规则 ${result.executedRules}/${result.totalRules}；` +
        `层级 ${result.hierarchyDepthApplied}；完整性提示 ${result.completenessNotices}；${drcService.getRuleGroups()?.scopeNote ?? ''}；不是制造签核。`,
      violations: result.violations.map((v: DrcViolation): RdbViolation => ({ id: v.id, ruleId: v.ruleId, ruleName: v.ruleName,
        type: v.type, severity: v.severity, layerNumber: v.layerNumber, x: v.x, y: v.y, width: v.width,
        height: v.height, message: v.message, shapeIds: v.shapeIds.slice(), fromInstance: v.fromInstance })) };
    const converted: RdbReadResult = rdbService.fromViolations(report);
    if (!converted.ok || converted.document === undefined) throw new Error(converted.message);
    return converted.document;
  }

  private rdbReviewFileAction(kind: string): void {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !['open', 'reload', 'save', 'currentDrc'].includes(kind)) return;
    const id: string = this.rdbReviewWorkspace.activeReportId();
    if (kind === 'save' || kind === 'reload') {
      if (id.length > 0) this.rdbReportFileAction(kind, id, this.rdbReviewWorkspace.contextToken(), this.rdbReviewWorkspace.reportContext(id));
    } else this.performRdbReviewFileAction(kind, this.rdbReviewCore.contextToken());
  }

  private async performRdbReviewFileAction(kind: string, expectedContext: string): Promise<void> {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || expectedContext !== this.rdbReviewCore.contextToken()) return;
    if (!['open', 'currentDrc'].includes(kind)) return;
    await this.performRdbWorkspaceFileAction(kind, '', this.rdbReviewWorkspace.contextToken(), '');
  }

  private rdbReviewExportName(name: string): string {
    const stem: string = name.replace(/\.[^./\\]*$/, '').replace(/[\\/:*?"<>|\x00-\x1f\x7f]/g, '_').trim().replace(/[. ]+$/g, '');
    let suggestion: string = '', count: number = 0;
    for (const letter of Array.from(stem)) {
      const code: number = letter.codePointAt(0) ?? 0;
      const bytes: number = code <= 0x7f ? 1 : code <= 0x7ff ? 2 : code <= 0xffff ? 3 : 4;
      if (count + bytes > 200) break;
      suggestion += letter; count += bytes;
    }
    return `${suggestion || 'rdb-report'}-review.lyrdb`;
  }

  private async performRdbWorkspaceFileAction(kind: string, reportId: string, workspaceToken: string, reportContext: string): Promise<void> {
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty || !['open', 'reload', 'save', 'currentDrc'].includes(kind)) return;
    const newReport: boolean = kind === 'open' || kind === 'currentDrc';
    if (newReport ? this.rdbReviewWorkspace.contextToken() !== workspaceToken : !this.rdbReportActionCurrent(reportId, workspaceToken, reportContext)) return;
    const ticket: number = ++this.rdbReviewFileTicket, generation: number = this.pageGeneration;
    const activeContext: string = this.rdbReviewCore.contextToken();
    const isCurrent: () => boolean = (): boolean => {
      if (!this.pageAlive || generation !== this.pageGeneration || !this.panelStore.showRdbReviewPanel || ticket !== this.rdbReviewFileTicket || this.rdbReviewDraftDirty) return false;
      if ((newReport || reportId === this.rdbReviewWorkspace.activeReportId()) && activeContext !== this.rdbReviewCore.contextToken()) return false;
      try {
        return newReport ? workspaceToken === this.rdbReviewWorkspace.contextToken() : reportContext === this.rdbReviewWorkspace.reportContext(reportId);
      } catch (_) { return false; }
    };
    this.verifyStore.rdbReviewBusy = true;
    let externalSaved: boolean = false;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (kind === 'save') {
        const save: RdbReviewWorkspaceSaveTicket = this.rdbReviewWorkspace.prepareSave(reportId);
        const name: string = this.rdbReviewExportName(this.rdbReviewWorkspace.session(reportId).source()!.name);
        const uri: string = await engineeringFileService.saveText(context, name, save.xml, isCurrent, 'KLayout 报告数据库|.lyrdb');
        externalSaved = true;
        if (!isCurrent()) throw new Error('报告已改变，旧保存不能确认当前草稿');
        const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
        if (!workspace.acknowledgeSave(save, uri)) throw new Error('报告保存上下文已失效');
        this.publishRdbWorkspace(workspace);
        this.verifyStore.rdbReviewStatus = 'RDB 已另存为，审阅状态与恢复草稿一致';
      } else {
        const candidate = new RdbReviewService();
        let uri: string = '';
        const identity: string = newLayoutIdentity('rdb');
        if (kind === 'currentDrc') {
          candidate.loadGenerated(this.currentDrcReviewDocument(), { identity, name: 'drc-report.lyrdb' });
        } else {
          const report: RdbReviewWorkspaceReport | undefined = this.rdbReviewWorkspace.listReports().find((row: RdbReviewWorkspaceReport): boolean => row.id === reportId);
          if (kind === 'reload' && (report === undefined || report.uri.length === 0)) throw new Error('此报告没有可重载文件，请先另存为或打开报告');
          const picked: RdbPickedReport = kind === 'reload' ? await rdbFileService.read(report!.uri) : await rdbFileService.pick(context);
          if (!isCurrent()) throw new Error('等待期间报告或面板已改变，旧文件未载入');
          const parsedRdb = await rdbService.parseAsync(picked.xml);
          if (!parsedRdb.ok || parsedRdb.document === undefined) throw new Error(parsedRdb.message);
          if (!isCurrent()) throw new Error('等待期间报告或面板已改变，旧文件未载入');
          candidate.replaceDocument(parsedRdb.document, { identity, name: picked.name }); uri = picked.uri;
        }
        if (!isCurrent()) throw new Error('报告来源已改变，未替换当前报告');
        const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
        if (newReport) workspace.addSession(candidate, uri, workspaceToken);
        else workspace.reloadSession(reportId, candidate, uri, reportContext, true);
        this.publishRdbWorkspace(workspace);
        this.verifyStore.rdbReviewStatus = kind === 'reload' ? '指定报告已从原文件重新载入' : '已新增完整报告，原有报告及审阅保留';
      }
      this.clearRdbReviewOverlay(); this.refreshRdbReview();
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration && ticket === this.rdbReviewFileTicket && this.panelStore.showRdbReviewPanel) {
        this.verifyStore.rdbReviewStatus = (externalSaved ? '外部文件已写入，草稿确认未完成；原审阅状态保留：' : '报告操作未完成，原报告保留：') + String(error);
      }
    } finally { if (ticket === this.rdbReviewFileTicket) this.verifyStore.rdbReviewBusy = false; }
  }

  private captureWorkspaceDocument(targetActiveId?: string): void {
    if (this.docStore.workspaceTabs.length === 0) return;
    if (this.autosaveTimer >= 0) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    this.finishNudgeTransaction();
    if (this.viewWorkspaceInitialized && !this.persistViewWorkspacePresentation()) throw new Error(this.viewportStore.viewWorkspaceStatus);
    const isCleanTab: boolean = !editService.isDirty() && !this.docStore.documentDirty && !this.localPythonDraftDirty;
    const session: EditSessionState = isCleanTab ? editService.captureReadOnlySession(this.docStore.activeWorkspaceId) : editService.captureSession();
    const record: WorkspaceDocument = this.workspaceDocument();
    record.shapes = session.shapes;
    const prepared: WorkspacePreparedDraft | undefined = this.docStore.workspaceReady ? workspaceService.prepareDraft(record) : undefined;
    const copy: WorkspaceDocument = prepared !== undefined ? prepared.document : workspaceService.cloneValidatedDocument(record);
    session.shapes = copy.shapes;
    this.workspaceDocuments.set(record.id, copy);
    this.workspaceSessions.set(record.id, session);
    this.viewWorkspaceCheckpointVersions.set(record.id, editService.getSessionRevision());
    this.refreshWorkspaceTabs();
    const desiredActiveId: string = targetActiveId !== undefined && targetActiveId.length > 0 ? targetActiveId : record.id;
    if (prepared !== undefined) workspaceService.savePreparedDraft(prepared, this.docStore.workspaceTabs, desiredActiveId).catch((error: Error) => {
      this.docStore.recoveryStatus = `自动恢复保存失败：${error.message}`;
    });
  }

  private refreshWorkspaceTabs(): void {
    const tabs: WorkspaceTab[] = [];
    for (const tab of this.docStore.workspaceTabs) {
      const record: WorkspaceDocument | undefined = this.workspaceDocuments.get(tab.id);
      tabs.push(tab.id === this.docStore.activeWorkspaceId
        ? { id: tab.id, title: this.docStore.currentDocumentTitle, dirty: editService.isDirty() || this.docStore.documentDirty }
        : { id: tab.id, title: record?.title ?? tab.title, dirty: record?.dirty ?? tab.dirty });
    }
    if (!tabs.some((tab: WorkspaceTab) => tab.id === this.docStore.activeWorkspaceId)) tabs.push({
      id: this.docStore.activeWorkspaceId, title: this.docStore.currentDocumentTitle, dirty: editService.isDirty() || this.docStore.documentDirty });
    this.docStore.workspaceTabs = tabs;
  }

  private isCurrentWorkspaceTabEmptyReusable(): boolean {
    return this.docStore.workspaceReady &&
      editService.getShapes().length === 0 &&
      this.docPorts.length === 0 &&
      !this.localPythonDraftDirty;
  }

  private availableAiArtifactSlots(): number {
    const freeTabs: number = Math.max(0, MAX_WORKSPACE_TABS - this.docStore.workspaceTabs.length);
    const reuseEmpty: number = (freeTabs === 0 && this.isCurrentWorkspaceTabEmptyReusable()) ? 1 : 0;
    return Math.min(8, freeTabs + reuseEmpty);
  }

  private canOpenWorkspaceDocument(): boolean {
    if (!this.docStore.workspaceReady) { this.panelStore.statusText = '正在恢复工作区，请稍候'; return false; }
    if (this.docStore.workspaceTabs.length >= MAX_WORKSPACE_TABS) {
      this.panelStore.statusText = `最多同时打开 ${MAX_WORKSPACE_TABS} 个版图，请先关闭一个标签页`;
      return false;
    }
    return true;
  }

  private async initializeWorkspace(): Promise<void> {
    const generation: number = this.pageGeneration;
    const startRevision: number = this.docStore.editorRevision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      this.docStore.fileRecoveryEntries = fileRecoveryService.list(context);
      const recovery = await workspaceService.initialize(context);
      if (!this.pageAlive || generation !== this.pageGeneration) return;
      if (recovery.documents.length > 0 && (this.docStore.editorRevision === startRevision || !editService.isDirty())) {
        const active: WorkspaceDocument = recovery.documents.find((document: WorkspaceDocument) => document.id === recovery.activeId) ?? recovery.documents[0];
        // Native activation can reject a document; publish its tabs only after it succeeds.
        const documents: WorkspaceDocument[] = recovery.documents.map((document: WorkspaceDocument): WorkspaceDocument =>
          workspaceService.cloneValidatedDocument(document));
        this.activateWorkspaceDocument(active);
        this.workspaceDocuments = new Map<string, WorkspaceDocument>();
        this.workspaceSessions = new Map<string, EditSessionState>();
        for (const document of documents) this.workspaceDocuments.set(document.id, document);
        this.docStore.workspaceTabs = documents.map((document: WorkspaceDocument): WorkspaceTab => ({ id: document.id, title: document.title, dirty: document.dirty }));
        this.docStore.recoveryStatus = `已恢复 ${recovery.documents.length} 个版图及未保存草稿`;
        this.panelStore.statusText = this.docStore.recoveryStatus;
      } else if (recovery.documents.length > 0) {
        for (const document of recovery.documents) {
          if (this.workspaceDocuments.has(document.id)) continue;
          this.workspaceDocuments.set(document.id, document);
          this.docStore.workspaceTabs = this.docStore.workspaceTabs.concat([{ id: document.id, title: document.title, dirty: document.dirty }]);
        }
      }
      if (recovery.warnings.length > 0) this.docStore.recoveryStatus = recovery.warnings.join('；');
      await componentLibraryService.initialize(context);
      if (!this.pageAlive || generation !== this.pageGeneration) return;
      this.docStore.libraryEntries = componentLibraryService.list();
      this.docStore.workspaceReady = true;
      this.consumePendingCardCommand();
      this.consumePendingExternalUri();
      try { this.prepareViewWorkspace(true); }
      catch (error) { this.viewportStore.viewWorkspaceSceneDiagnostic = `视图恢复未完成：${String(error)}`; }
      this.schedulePruneImportCache();
      this.workspaceViewKey = this.currentWorkspaceViewKey();
      this.workspaceViewTimer = setInterval(() => {
        if (!this.pageAlive || generation !== this.pageGeneration || this.workspaceCloseConfirming) return;
        const key: string = this.currentWorkspaceViewKey();
        if (key !== this.workspaceViewKey) {
          this.workspaceViewKey = key;
          if (this.viewWorkspaceInitialized) this.persistViewWorkspacePresentation();
          const viewOnlyOnCleanDoc: boolean = !editService.isDirty() && !this.docStore.documentDirty && !this.localPythonDraftDirty;
          this.scheduleWorkspaceDraft(viewOnlyOnCleanDoc ? 4000 : 1500);
        }
      }, 2000);
      this.scheduleWorkspaceDraft();
    } catch (error) {
      if (!this.pageAlive || generation !== this.pageGeneration) return;
      this.docStore.workspaceReady = true;
      this.docStore.recoveryStatus = `恢复提示：${String(error)}`;
      this.panelStore.statusText = this.docStore.recoveryStatus;
      this.consumePendingCardCommand();
      this.consumePendingExternalUri();
    }
  }

  private activateWorkspaceDocument(document: WorkspaceDocument, adoptValidatedInPlace: boolean = false, skipRedundantNativeSync: boolean = false): void {
    this.canvasFocusReturnTicket++;
    this.revokeRdbWaiverPreview(); layerExpressionService.cancel();
    if (this.verifyStore.engineeringRestorePreview !== undefined) this.cancelEngineeringReviewRestore(this.verifyStore.engineeringRestorePreview.token);
    if (this.viewWorkspaceInitialized && !this.persistViewWorkspacePresentation()) throw new Error(this.viewportStore.viewWorkspaceStatus);
    shortcutService.clear(); this.mnemonicContext = '';
    const doc: WorkspaceDocument = adoptValidatedInPlace
      ? workspaceService.adoptValidatedDocument(document)
      : workspaceService.cloneValidatedDocument(document);
    const input: ExportLayoutInput = { shapes: doc.shapes, layers: doc.layers, libName: doc.libName,
      topCellName: doc.topCellName, sourcePath: '', cellNames: doc.cellNames, topCellId: doc.topCellId,
      physicalUnits: doc.physicalUnits, userUnits: doc.userUnits,
      cellKeys: doc.cellKeys, ports: doc.ports, crossSections: doc.crossSections,
      layoutContextRecords: doc.layoutContextRecords, cellContextRecords: doc.cellContextRecords,
      cellProperties: doc.cellProperties, libProperties: doc.libProperties, layerDefinitions: doc.layerDefinitions };
    const nativeDocument = skipRedundantNativeSync ? null : layoutExportService.buildNativeDocument(input);
    const ownsTools: boolean = engineeringProjectService.canRefreshBundle(doc.id, doc.engineering);
    const previousTechnology: string = technologyService.serialize();
    const previousDeck: EngineeringRuleSnapshot = { name: drcService.ruleSourceText(), rules: drcService.getRules() };
    const previousDraft: PythonEditorDraft | undefined = pythonWorkspaceService.draft();
    const previousDrc: DrcConfiguration = drcService.captureConfiguration();
    let nextLayers: UiLayer[] = doc.layers;
    let nextPortCapabilityNotice: string = '';
    let draftChanged: boolean = false;
    let technologyChanged: boolean = false;
    let nativeChanged: boolean = false;
    let nextToolBaseline: string = '';
    try {
      if (doc.engineering !== undefined && ownsTools) {
        const saved: EngineeringRestorePayload = engineeringProjectService.restoreTools(doc.engineering, doc.id);
        pythonWorkspaceService.restoreSessionDraft(saved.python.draft); draftChanged = true;
        nextLayers = technologyService.restoreDocumentSettings(saved.technologyJson, saved.drcDeckJson, doc.layers);
        technologyChanged = true;
      } else {
        pythonWorkspaceService.restoreSessionDraft(); draftChanged = true;
        nextLayers = technologyService.restoreDocumentSettings(doc.engineering === undefined ? (doc.technologyJson ?? '') : '', '', doc.layers);
        technologyChanged = true;
        if (doc.engineering !== undefined) drcService.setRules([], '工程规则尚未恢复');
      }
      if (doc.localProcessState !== undefined) {
        nextLayers = technologyService.restoreDocumentSettings(doc.localProcessState.technologyJson, doc.localProcessState.drcDeckJson, doc.layers);
        technologyChanged = true;
        drcService.restoreConfiguration(doc.localProcessState.drcConfiguration);
      }
      if (doc.localPythonDraft !== undefined) {
        pythonWorkspaceService.restoreSessionDraft(doc.localPythonDraft); draftChanged = true;
      }
      // Capture the effective, document-scoped tools before publishing activation.
      // Existing global templates/macros alone are not an edit of this document.
      if (doc.engineering === undefined) nextToolBaseline = this.engineeringBundleContext(
        this.buildEngineeringBundle(doc, this.collectPCellVariants(doc.shapes, doc.topCellId)), false);
      if (!skipRedundantNativeSync && nativeDocument !== null) {
        const synchronized = nativeHongTuService.syncDocument(nativeDocument);
        if (!synchronized.success) throw new Error(synchronized.errorMessage || '工作区文档无法同步');
        nextPortCapabilityNotice = (synchronized.portCapabilityDiagnostics ?? []).join('；');
        nativeChanged = true;
      }
      // Native validation must succeed before ending recording; a refused macro save rolls it back below.
      this.finishMacroRecordingForDocumentChange(doc.id);
    } catch (error) {
      let rollbackError: string = '';
      try {
        if (technologyChanged) technologyService.restoreDocumentSettings(previousTechnology, JSON.stringify(previousDeck), this.docStore.layers);
        drcService.restoreConfiguration(previousDrc);
      }
      catch (restoreError) { rollbackError += `；工艺回滚失败：${String(restoreError)}`; }
      try { if (draftChanged) pythonWorkspaceService.restoreSessionDraft(previousDraft); }
      catch (restoreError) { rollbackError += `；草稿回滚失败：${String(restoreError)}`; }
      if (technologyChanged) {
        this.verifyStore.drcHasRun = false; this.drcSnapshotRevision = -1; this.verifyStore.drcIssues = [];
        this.verifyStore.highlightedViolation = null; this.verifyStore.highlightedViolationId = -1; this.verifyStore.lastDrcElapsed = 0;
        this.publishFormSnapshot();
        rollbackError += '；原检查结论已清除，请重新检查';
      }
      if (nativeChanged) {
        try {
          // EditService and document metadata still own the previous document
          // until this preflight succeeds. Build its wire copy only on rollback.
          const restored = nativeHongTuService.syncDocument(layoutExportService.buildNativeDocument(this.currentExportInput()));
          this.setNativeSnapshotCurrent(restored.success);
          if (!restored.success) rollbackError += `；原生回滚失败：${restored.errorMessage}`;
        } catch (restoreError) { this.setNativeSnapshotCurrent(false); rollbackError += `；原生回滚失败：${String(restoreError)}`; }
      }
      throw new Error(`${String(error)}${rollbackError}`);
    }
    this.docStore.layers = doc.layers;
    const session: EditSessionState | undefined = this.workspaceSessions.get(doc.id);
    if (session !== undefined) editService.restoreSession(session);
    else {
      editService.setTopCellId(doc.topCellId);
      editService.adoptShapes(doc.shapes);
      if (doc.cellStack.length === 1 && doc.cellStack[0] !== doc.topCellId) {
        editService.navigateToCellDefinition(doc.cellStack[0]);
      } else {
        for (let i = 1; i < doc.cellStack.length; i++) editService.enterCell(doc.cellStack[i]);
      }
      if (doc.navigationPath !== undefined) editService.restoreNavigationPath(doc.navigationPath);
      editService.selectMultiple(doc.selectedIds);
      if (doc.dirty) editService.markDirty();
    }
    if (this.docStore.activeWorkspaceId !== doc.id) {
      this.preferredInstanceTargetId = -1;
      this.exitStampSession();
    }
    this.docStore.activeWorkspaceId = doc.id;
    editService.setActiveDocumentIdentity(doc.id);
    this.aiStore.aiProjectNote = aiService.getProjectKnowledge(doc.id)?.text ?? '';
    this.workspaceSelectionTicket++;
    this.pickedPortEndpoint = undefined; portService.cancel(); routeSessionService.cancel();
    this.viewportStore.portCapabilityNotice = nextPortCapabilityNotice;
    this.cancelActiveNativeJob();
    this.docStore.currentDocumentTitle = doc.title;
    this.viewportStore.currentViewMode = doc.viewMode === 'viewer' ? ViewMode.VIEWER : ViewMode.EDIT;
    this.docStore.currentFilePath = doc.sourcePath;
    this.currentSaveUri = doc.saveUri;
    this.currentProjectUri = doc.projectUri;
    this.docStore.docLibName = doc.libName;
    this.docStore.docTopCellName = doc.topCellName;
    this.docStore.docUserUnits = doc.userUnits;
    this.docStore.docPhysicalUnits = doc.physicalUnits;
    this.docCellProperties = doc.cellProperties;
    this.docLibProperties = doc.libProperties;
    this.docCellKeys = (doc.cellKeys as string[]).slice();
    this.docPorts = clonePortArray(doc.ports)! as LayoutPort[];
    this.docCrossSections = cloneCrossSectionArray(doc.crossSections)! as LayoutCrossSection[];
    this.docLayoutContextRecords = cloneContextRecordArray(doc.layoutContextRecords)! as LayoutContextRecord[];
    this.docCellContextRecords = cloneCellContextRecordMatrix(doc.cellContextRecords)! as LayoutContextRecord[][];
    this.sourceLayerDefinitions = doc.layerDefinitions ?? [];
    const origin: WorkspaceAutomaticEngineeringOrigin | undefined = this.automaticEngineeringOrigins.get(doc.id);
    const cachedAutomatic: boolean = origin !== undefined && this.workspaceSessions.has(doc.id) &&
      JSON.stringify(doc.engineering ?? null) === origin.bundleJson;
    if (origin !== undefined && !cachedAutomatic) this.automaticEngineeringOrigins.delete(doc.id);
    this.engineeringBundle = doc.engineering;
    this.workspaceToolBaselineId = doc.id;
    this.workspaceToolBaseline = cachedAutomatic && origin !== undefined ? origin.toolsBaseline : nextToolBaseline;
    if (cachedAutomatic && origin !== undefined) origin.bundle = doc.engineering;
    this.engineeringToolsRestored = ownsTools;
    this.refreshEngineeringDependencies();
    this.docStore.layers = session === undefined ? nextLayers : doc.layers;
    this.placeableCells = doc.cellNames.map((name: string, id: number): CellInfo => ({ id: id, name: name }));
    if (!this.docStore.layers.some((layer: UiLayer): boolean => layer.layerNumber === this.viewportStore.selectedLayerNumber && layer.datatype === this.viewportStore.selectedDatatype) && this.docStore.layers.length > 0) {
      this.viewportStore.selectedLayerNumber = this.docStore.layers[0].layerNumber;
      this.viewportStore.selectedDatatype = this.docStore.layers[0].datatype;
    }
    this.pcellVariants = doc.pcells;
    this.currentTechnologyId = doc.technologyId;
    this.documentTechnologyJson = doc.technologyJson ?? '';
    this.localProcessOwned = doc.localProcessState !== undefined;
    this.localPythonDraft = doc.localPythonDraft;
    this.localPythonDraftDirty = doc.localPythonDraft !== undefined && doc.localPythonDraftDirty !== false;
    if (this.localPythonDraftDirty && !editService.isDirty()) editService.markDirty();
    advEditService.loadCellsFromImport(doc.cellNames, editService.getShapes(), doc.topCellId);
    this.measureStore.reset();
    this.measureStore.restoreRulers(doc.rulers);
    this.vertexStore.reset();
    this.viewportStore.zoomPercent = doc.zoom;
    this.viewportStore.viewOffsetX = doc.offsetX;
    this.viewportStore.viewOffsetY = doc.offsetY;
    this.viewportStore.gridSize = doc.gridSize;
    const precision: PrecisionSettings = doc.precision ?? legacyDocumentPrecision(doc.physicalUnits, doc.gridSize);
    this.viewportStore.drawStepNm = precision.drawStepNm;
    this.viewportStore.displayGridNm = precision.displayGridNm;
    this.viewportStore.geometrySnapEnabled = precision.geometrySnapEnabled;
    this.viewportStore.geometrySnapKinds = precision.geometrySnapKinds.slice();
    this.viewportStore.snapEnabled = this.viewportStore.drawStepNm > 0; this.viewportStore.vertexSnapEnabled = this.viewportStore.geometrySnapEnabled; this.viewportStore.smartGuidesEnabled = this.viewportStore.geometrySnapEnabled;
    this.viewportStore.pickedPlacement = null;
    this.docStore.hierarchyDepth = doc.hierarchyDepth;
    viewService.setHierarchyDepth(doc.hierarchyDepth);
    viewService.setViewZoomPercent(doc.zoom);
    viewService.setViewOffset(doc.offsetX, doc.offsetY);
    this.originalSourceCurrent = false;
    this.verifyStore.drcIssues = [];
    this.verifyStore.drcHasRun = false;
    this.verifyStore.tracedNets = [];
    this.verifyStore.lvsHasResult = false;
    this.verifyStore.highlightedViolation = null;
    this.verifyStore.highlightedViolationId = -1;
    this.docStore.docCellCount = doc.cellNames.length;
    this.cancelPendingAiCommands(false);
    this.syncShapesFromEditService(session !== undefined);
    this.setNativeSnapshotCurrent(true);
    this.rebuildCellTree();
    this.syncLayerVisibilityMirror();
    this.viewportStore.currentModule = WorkModule.Layout;
    if (this.viewWorkspaceInitialized) {
      this.panelStore.showViewWorkspacePanel = false;
      this.viewWorkspaceDocumentId = '';
      this.viewWorkspaceFileTicket++;
      this.viewportStore.viewWorkspaceFileBusy = false;
      try { this.prepareViewWorkspace(true); }
      catch (error) { this.viewportStore.viewWorkspaceSceneDiagnostic = `视图恢复未完成：${String(error)}`; this.viewportStore.viewWorkspaceSceneRevision++; }
    }
    if (this.rdbReviewInitialized) {
      this.rdbReviewMapping = null; this.clearRdbReviewOverlay();
      if (this.panelStore.showRdbReviewPanel) this.refreshRdbReview();
    }
  }

  private switchWorkspaceDocument(id: string): void {
    if (this.workspaceCloseConfirming) return;
    if (id === this.docStore.activeWorkspaceId) return;
    const document: WorkspaceDocument | undefined = this.workspaceDocuments.get(id);
    if (document === undefined) return;
    if (this.autosaveTimer >= 0) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    try {
      this.captureWorkspaceDocument(document.id);
      this.activateWorkspaceDocument(document);
      this.workspaceViewKey = this.currentWorkspaceViewKey();
      this.panelStore.statusText = `已切换至 ${document.title}`;
      this.persistWorkspaceSelection(document.id);
    } catch (error) { this.panelStore.statusText = `切换失败，当前版图保留：${String(error)}`; }
  }

  private workspaceSelectionTicket: number = 0;

  private persistWorkspaceSelection(documentId: string): void {
    if (!this.docStore.workspaceReady) return;
    const generation: number = this.pageGeneration;
    const ticket: number = ++this.workspaceSelectionTicket;
    const isOpen = (): boolean => this.workspaceDocuments.has(documentId) &&
      this.docStore.workspaceTabs.some((tab: WorkspaceTab): boolean => tab.id === documentId);
    const isCurrent = (): boolean => this.pageAlive && generation === this.pageGeneration &&
      ticket === this.workspaceSelectionTicket && documentId === this.docStore.activeWorkspaceId && isOpen();
    workspaceService.saveActiveDocument(documentId, isOpen).then(() => {
      if (!isCurrent()) return;
      this.docStore.recoveryStatus = '下次启动将恢复当前页签';
    }).catch((error: Error) => {
      if (!isCurrent()) return;
      this.docStore.recoveryStatus = `页签选择保存失败：${String(error)}`;
      this.panelStore.statusText = this.docStore.recoveryStatus;
    });
  }

  private createWorkspaceDocument(library: string, top: string, dbuNm: number): void {
    if (!this.canOpenWorkspaceDocument()) return;
    this.captureWorkspaceDocument();
    const document: WorkspaceDocument = { version: 2, id: workspaceService.newId(), title: `${library}.gds`,
      sourcePath: '', saveUri: '', projectUri: '', libName: library, topCellName: top, topCellId: 0,
      cellNames: [top], cellProperties: [[]], libProperties: [], shapes: [], layers: createInitialLayers(),
      cellKeys: [newLayoutIdentity()], ports: [], crossSections: [], layoutContextRecords: [], cellContextRecords: [[]],
      userUnits: dbuNm / 1000, physicalUnits: dbuNm * 1e-9, dirty: true, cellStack: [0], selectedIds: [],
      zoom: 100, offsetX: 0, offsetY: 0, hierarchyDepth: 2, gridSize: dbuNm,
      rulers: [], pcells: [], technologyId: '', revision: 0, updatedAt: Date.now() };
    try {
      this.activateWorkspaceDocument(document);
      this.workspaceDocuments.set(document.id, document);
      this.panelStore.showProjectPanel = false;
      this.panelStore.statusText = `已新建 ${library} · ${top} · DBU ${dbuNm} nm`;
      this.saveWorkspaceDraft();
      this.restoreCanvasFocusAfterPanelClose();
    } catch (error) { this.panelStore.statusText = `新建失败：${String(error)}`; }
  }

  private async closeWorkspaceDocument(id: string): Promise<void> {
    if (this.workspaceCloseConfirming) return;
    this.switchWorkspaceDocument(id);
    if (id !== this.docStore.activeWorkspaceId) return;
    if (this.autosaveTimer >= 0) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    if (editService.isDirty() || this.docStore.documentDirty) {
      this.workspaceCloseConfirming = true;
      let confirmed: boolean = false;
      try {
        confirmed = await this.confirmUnsavedBeforeOpen('关闭标签页');
      } finally {
        this.workspaceCloseConfirming = false;
      }
      if (!confirmed) {
        if (id === this.docStore.activeWorkspaceId) {
          this.workspaceViewKey = this.currentWorkspaceViewKey();
          this.restoreCanvasFocusAfterPanelClose();
        }
        return;
      }
    }
    if (id !== this.docStore.activeWorkspaceId) return;
    if (this.autosaveTimer >= 0) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    const remaining: WorkspaceTab[] = this.docStore.workspaceTabs.filter((tab: WorkspaceTab) => tab.id !== id);
    try {
      if (remaining.length > 0) {
        const next = this.workspaceDocuments.get(remaining[remaining.length - 1].id);
        if (next === undefined) throw new Error('目标文档尚未保存到工作区');
        this.activateWorkspaceDocument(next);
      } else {
        this.createWorkspaceDocument('UNTITLED_LIB', 'TOP', 1);
        if (id === this.docStore.activeWorkspaceId) return;
      }
    } catch (error) { this.panelStore.statusText = `关闭失败，原标签已保留：${String(error)}`; return; }
    this.workspaceDocuments.delete(id);
    this.workspaceSessions.delete(id);
    this.automaticEngineeringOrigins.delete(id);
    this.viewWorkspaceCheckpointVersions.delete(id);
    this.viewWorkspaceShapeIdentities.delete(id); this.viewWorkspaceIdentityVersions.delete(id);
    if (this.viewWorkspaceCore !== null && this.viewWorkspaceSources.has(id)) {
      this.viewWorkspaceCore.unbindDatabase(id); this.viewWorkspaceSources.delete(id);
      if (this.viewWorkspaceDocumentId === this.docStore.activeWorkspaceId) this.refreshViewWorkspace();
    }
    engineeringProjectService.forgetSessionTools(id);
    this.docStore.workspaceTabs = this.docStore.workspaceTabs.filter((tab: WorkspaceTab) => tab.id !== id);
    this.workspaceViewKey = this.currentWorkspaceViewKey();
    this.panelStore.statusText = `已关闭标签页 · 当前文档：${this.docStore.currentDocumentTitle}`;
    await this.saveWorkspaceDraft(false, true);
    this.schedulePruneImportCache();
    this.restoreCanvasFocusAfterPanelClose();
  }

  private onBackgroundFlushRequested(): void {
    const token: string = this.backgroundFlushToken;
    if (token.length === 0 || token === this.handledBackgroundFlushToken) return;
    this.handledBackgroundFlushToken = token;
    if (!this.pageAlive || !this.docStore.workspaceReady) return;
    if (this.autosaveTimer >= 0) {
      clearTimeout(this.autosaveTimer);
      this.autosaveTimer = -1;
    }
    this.saveWorkspaceDraft(false, true);
  }

  private scheduleWorkspaceDraft(delayMs: number = 1500): void {
    if (!this.docStore.workspaceReady || this.workspaceCloseConfirming) return;
    if (this.autosaveTimer >= 0) clearTimeout(this.autosaveTimer);
    this.autosaveTimer = setTimeout(() => {
      this.autosaveTimer = -1;
      if (!this.workspaceCloseConfirming) {
        this.saveWorkspaceDraft();
      }
    }, delayMs);
  }

  private currentWorkspaceViewKey(): string {
    return `${this.docStore.activeWorkspaceId}:${this.viewportStore.zoomPercent}:${this.viewportStore.viewOffsetX}:${this.viewportStore.viewOffsetY}:${this.viewportStore.gridSize}:${this.docStore.hierarchyDepth}:`
      + JSON.stringify(this.measureStore.rulers) + JSON.stringify(this.docStore.layers.map((layer: UiLayer): string =>
        `${layer.layerNumber}/${layer.datatype}/${layer.visible}/${layer.locked}/${layer.color}`))
      + ':' + JSON.stringify(editService.getCurrentCellStack()) + ':' + JSON.stringify(editService.getNavigationPath())
      + ':' + editService.getSelectionIdentity();
  }

  private async saveWorkspaceDraft(checkpoint: boolean = false, forceFlush: boolean = false): Promise<boolean> {
    if (!this.docStore.workspaceReady || (this.workspaceCloseConfirming && !forceFlush)) return false;
    if (!checkpoint && !forceFlush && !editService.isDirty() && !this.docStore.documentDirty && !this.localPythonDraftDirty &&
      this.docStore.currentFilePath.length > 0 && editService.getShapes().length > 50000) {
      this.refreshWorkspaceTabs();
      this.docStore.recoveryStatus = `大版图原文件已关联 · 免拷贝就绪 (${editService.getShapes().length} 图元)`;
      return true;
    }
    try {
      this.refreshWorkspaceTabs();
      const document: WorkspaceDocument = this.workspaceDocument();
      if (checkpoint) this.refreshEngineeringDependencies();
      await workspaceService.saveDraft(document, this.docStore.workspaceTabs, this.docStore.activeWorkspaceId, checkpoint);
      this.docStore.recoveryStatus = `自动草稿已保存 · ${new Date().toLocaleTimeString()}`;
      this.docStore.workspaceHistory = workspaceService.listHistory(this.docStore.activeWorkspaceId);
      if (checkpoint) this.panelStore.statusText = '已创建可恢复的版图版本';
      return true;
    } catch (error) { this.docStore.recoveryStatus = `草稿保存失败：${String(error)}`; this.panelStore.statusText = this.docStore.recoveryStatus; return false; }
  }

  private async saveProject(saveAs: boolean = false): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (this.saveInProgress) { this.panelStore.statusText = '当前保存或导出尚未结束，请稍候'; return; }
    this.saveInProgress = true;
    const id: string = this.docStore.activeWorkspaceId;
    let toolIdentity: string = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const revision: number = this.docStore.editorRevision;
      const ownsTools: boolean = engineeringProjectService.canRefreshBundle(id, this.engineeringBundle);
      const document: WorkspaceDocument = this.workspaceDocument(true);
      toolIdentity = this.projectToolContext();
      const contentIdentity: string = this.projectSaveContext();
      const isCurrent: () => boolean = (): boolean => id === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision && contentIdentity === this.projectSaveContext();
      const uri: string = await workspaceService.exportProject(context, document, saveAs, isCurrent);
      if (!isCurrent()) { this.markUnsavedProjectTools(id, toolIdentity); this.panelStore.statusText = '工程保存期间内容已变化；当前修改仍未保存'; return; }
      this.currentProjectUri = uri;
      this.automaticEngineeringOrigins.delete(id);
      this.engineeringBundle = document.engineering; this.refreshEngineeringDependencies();
      if (ownsTools) engineeringProjectService.markSessionToolsOwned(id);
      this.localPythonDraftDirty = false;
      editService.markClean();
      this.docStore.documentDirty = false;
      // 保存工程将 ArkTS 标为 clean，必须同步刷新 C++ g_layout 快照，杜绝 GL 视口继续绘制旧几何
      this.synchronizeCurrentDocument();
      this.refreshWorkspaceTabs(); this.saveWorkspaceDraft(true);
      this.panelStore.statusText = '工程已保存（含器件参数、图层、视图和脚本依赖；未执行代码）';
    } catch (error) {
      this.markUnsavedProjectTools(id, toolIdentity);
      this.panelStore.statusText = `保存工程失败：${String(error)}`;
    } finally {
      this.saveInProgress = false;
    }
  }

  private projectToolContext(): string {
    return JSON.stringify({ python: pythonWorkspaceService.peekBundle(),
      macros: (JSON.parse(macroService.exportAllMacros()) as EngineeringMacroSnapshot).macros,
      deck: drcService.getRules(), deckSource: drcService.ruleSourceText(), technology: technologyService.serialize() });
  }

  private handlePythonDraftChanged(documentId: string, draft: PythonEditorDraft): void {
    if (!this.pageAlive || !this.docStore.workspaceReady || documentId !== this.docStore.activeWorkspaceId) throw new Error('脚本所属文档已切换或尚未恢复，请重新打开脚本面板');
    const local: PythonEditorDraft = engineeringProjectService.validateLocalPythonDraft(draft);
    if (JSON.stringify(local) === JSON.stringify(this.localPythonDraft)) return;
    this.localPythonDraft = local;
    this.localPythonDraftDirty = true;
    editService.markDirty();
    this.docStore.documentDirty = true;
    this.refreshWorkspaceTabs(); this.scheduleWorkspaceDraft();
  }

  private markUnsavedProjectTools(documentId: string, identity: string): void {
    if (documentId !== this.docStore.activeWorkspaceId || identity.length === 0) return;
    try {
      if (identity !== this.projectToolContext()) {
        editService.markDirty(); this.syncShapesFromEditService();
      }
    } catch (_) { this.docStore.documentDirty = true; this.refreshWorkspaceTabs(); }
  }

  /** Compare persisted content without snapshot timestamps or UI-only dirty flags. */
  private captureAutomaticEngineeringOrigin(): void {
    const id: string = this.docStore.activeWorkspaceId;
    if (this.automaticEngineeringOrigins.has(id) || this.engineeringBundle !== undefined ||
      this.workspaceToolBaselineId !== id || this.workspaceToolBaseline.length === 0 ||
      macroService.isRecording() || this.rdbReviewDraftDirty) return;
    const previous: WorkspaceDocument | undefined = this.workspaceDocuments.get(id);
    if (previous === undefined || previous.engineering !== undefined) return;
    try {
      const candidate: EngineeringProjectBundle = this.buildEngineeringBundle(previous,
        this.collectPCellVariants(editService.getShapes(), editService.getTopCellId()));
      if (this.engineeringBundleContext(candidate, false) !== this.workspaceToolBaseline) return;
      this.automaticEngineeringOrigins.set(id, {
        toolsBaseline: this.workspaceToolBaseline, reviewBaseline: JSON.stringify(candidate.review ?? null),
        localPythonBaseline: JSON.stringify({ draft: this.localPythonDraft, dirty: this.localPythonDraftDirty }),
        // A defined candidate asks for actual session ownership; undefined always permits refresh.
        sessionOwnedBefore: engineeringProjectService.canRefreshBundle(id, candidate), bundleJson: 'null' });
    } catch (error) {
      // Missing provenance must retain engineering, without blocking the existing process edit.
      return;
    }
  }

  private engineeringBundleContext(bundle: EngineeringProjectBundle | undefined, includeReview: boolean = true): string {
    return bundle === undefined ? '' : JSON.stringify({ workspaceId: bundle.workspaceId,
      python: bundle.python, macrosJson: bundle.macrosJson, drcDeckJson: bundle.drcDeckJson,
      technologyJson: bundle.technologyJson, pcells: bundle.pcells, dependencies: bundle.dependencies,
      sourceChecksums: includeReview ? bundle.sourceChecksums : bundle.sourceChecksums.filter((value): boolean => value.name !== 'review'),
      review: includeReview ? bundle.review : undefined });
  }

  private projectSaveContext(): string {
    const engineering: string = this.engineeringBundleContext(this.engineeringBundle);
    return JSON.stringify({ documentId: this.docStore.activeWorkspaceId, revision: editService.getSessionRevision(),
      cellId: editService.getCurrentCellId(), title: this.docStore.currentDocumentTitle, libName: this.docStore.docLibName,
      topCellName: this.docStore.docTopCellName, cellNames: this.propertyCellOptions(), cellProperties: this.docCellProperties,
      libProperties: this.docLibProperties, userUnits: this.docStore.docUserUnits, physicalUnits: this.docStore.docPhysicalUnits,
      cellKeys: this.docCellKeys, ports: this.docPorts, crossSections: this.docCrossSections,
      layoutContextRecords: this.docLayoutContextRecords, cellContextRecords: this.docCellContextRecords,
      layers: unwrapObserved(this.docStore.layers), layerDefinitions: this.sourceLayerDefinitions, precision: this.precisionSettings(),
      viewMode: this.viewportStore.currentViewMode, zoom: this.viewportStore.zoomPercent, offsetX: this.viewportStore.viewOffsetX, offsetY: this.viewportStore.viewOffsetY,
      hierarchyDepth: this.docStore.hierarchyDepth, gridSize: this.viewportStore.gridSize, rulers: this.measureStore.rulers,
      selectedIds: editService.getSelectedIds(), pcells: this.pcellVariants, technologyId: this.currentTechnologyId,
      documentTechnologyJson: this.documentTechnologyJson, engineering,
      localPythonDraft: this.localPythonDraft,
      localPythonDraftDirty: this.localPythonDraftDirty,
      tools: this.projectToolContext(), review: this.captureEngineeringReview(this.docStore.activeWorkspaceId) });
  }

  private collectPCellVariants(shapes: Shape[], topCellId: number): PCellVariant[] {
    const found: Map<number, PCellVariant> = new Map<number, PCellVariant>();
    for (const shape of shapes) {
      const owner: number = shape.ownerCellId ?? topCellId;
      if (found.has(owner)) continue;
      for (const property of shape.properties ?? []) {
        const decoded: DecodedPCellProperty | undefined = decodePCellProperty(property);
        if (decoded === undefined || !decoded.active) continue;
        const variant: PCellVariant = { cellId: owner, name: decoded.metadata.name, params: decoded.metadata.params };
        if (decoded.metadata.technologyId !== undefined) {
          variant.technologyId = decoded.metadata.technologyId; variant.technologyVersion = decoded.metadata.technologyVersion;
          variant.deviceName = decoded.metadata.deviceName; variant.deviceModel = decoded.metadata.deviceModel;
        }
        found.set(owner, variant);
        break;
      }
    }
    return Array.from(found.values());
  }

  private buildEngineeringBundle(document: WorkspaceDocument, pcells?: PCellVariant[]): EngineeringProjectBundle {
    const deck: EngineeringRuleSnapshot = { name: drcService.captureConfiguration().ruleSourceLabel, rules: drcService.getRules() };
    const source: PythonWorkspaceBundle = pythonWorkspaceService.exportBundle();
    const python: EngineeringPythonBundle = { draft: source.draft, templates: source.templates };
    const snapshot: EngineeringProjectSnapshot = { workspaceId: document.id, python,
      macrosJson: macroService.exportAllMacros(), drcDeckJson: JSON.stringify(deck),
      technologyJson: technologyService.serialize(), pcells: pcells ?? document.pcells };
    const tools: EngineeringProjectBundle = engineeringProjectService.buildBundle(snapshot);
    return document.id === this.docStore.activeWorkspaceId ? engineeringProjectService.refreshReviewBundle(tools, this.captureEngineeringReview(document.id)) : tools;
  }

  private engineeringReviewSources(): ViewDatabaseSnapshot[] {
    const ids: string[] = Array.from(this.workspaceDocuments.keys());
    if (!ids.includes(this.docStore.activeWorkspaceId)) ids.push(this.docStore.activeWorkspaceId);
    return ids.map((id: string): ViewDatabaseSnapshot => {
      const source: ViewDatabaseSnapshot = this.readViewWorkspaceSource(id);
      // Tool adoption may change display styles. The source guard binds actual
      // geometry/lineage/history; display configuration is in the runtime context.
      return { documentId: source.documentId, revision: source.revision, dirty: source.dirty,
        historyToken: source.historyToken, shapes: source.shapes, cellKeys: source.cellKeys.slice(), topCellKey: source.topCellKey };
    });
  }

  private captureEngineeringReview(documentId: string): EngineeringReviewBundle {
    this.configureIntegratedReviewWorkspace();
    if (!this.initializeRdbReview()) throw new Error(this.verifyStore.rdbReviewStatus);
    const sources: EngineeringReviewSource[] = this.engineeringReviewSources().map((source: ViewDatabaseSnapshot): EngineeringReviewSource => {
      const document: WorkspaceDocument | undefined = this.workspaceDocuments.get(source.documentId);
      const uri: string = source.documentId === this.docStore.activeWorkspaceId ? (this.currentProjectUri || this.docStore.currentFilePath) : (document?.projectUri || document?.sourcePath || '');
      return { documentId: source.documentId, cellKeys: source.cellKeys.slice(), topCellKey: source.topCellKey,
        originUri: uri.length === 0 ? undefined : uri };
    });
    const views: ViewWorkspaceState = this.viewWorkspaceCore?.exportRecovery() ?? this.integratedReviewWorkspace.readViews();
    const active = views.documents.find((value): boolean => value.documentId === documentId);
    if (active !== undefined && documentId === this.docStore.activeWorkspaceId) {
      const view = active.views.find((value): boolean => value.id === active.activeViewId);
      if (view !== undefined) view.presentation = this.viewWorkspaceCapture();
    }
    return engineeringReviewBundleService.capture(documentId, sources, active ?? null,
      this.rdbReviewWorkspace.exportRecovery(), this.rdbReviewLayoutMappings);
  }

  private refreshEngineeringDependencies(): void {
    if (this.engineeringBundle === undefined) { this.docStore.engineeringDependencies = []; return; }
    const names: string[] = nativeHongTuService.listPCells().map((item): string => item.name);
    const environment: EngineeringEnvironment = { availablePCells: names };
    this.docStore.engineeringDependencies = engineeringProjectService.dependencyReport(this.engineeringBundle, environment).dependencies;
  }

  private engineeringReviewState(): EngineeringReviewRuntimeState {
    if (this.viewWorkspaceCore === null || !this.rdbReviewInitialized) throw new Error('工程审阅运行态尚未就绪');
    return { views: this.viewWorkspaceCore.exportRecovery(), reports: this.rdbReviewWorkspace.exportRecovery(),
      layoutMappings: cloneStructured(this.rdbReviewLayoutMappings) as RdbReviewLayoutMapping[] };
  }

  private engineeringReviewContext(): string {
    return JSON.stringify([this.pageGeneration, this.docStore.activeWorkspaceId, this.projectToolContext(),
      this.viewWorkspaceCapture(), editService.getSelectionIdentity(),
      this.rdbReviewMapping, this.rdbReviewTarget, this.rdbReviewTargetSet, this.rdbReviewPathIndex,
      this.verifyStore.rdbMarkerItem, this.verifyStore.rdbMarkerFrame, this.rdbMarkerDocumentId, this.rdbMarkerLayoutRevision,
      this.rdbMarkerCellId, this.rdbMarkerCellKey, this.rdbMarkerReportToken, this.rdbReviewCore.contextToken(),
      engineeringProjectService.canRefreshBundle(this.docStore.activeWorkspaceId, this.engineeringBundle),
      this.currentTechnologyId, this.documentTechnologyJson, this.docStore.layers, this.localPythonDraft,
      this.localPythonDraftDirty, this.engineeringToolsRestored, this.engineeringReviewState()]);
  }

  private engineeringReviewIdle(): boolean {
    return this.viewWorkspaceIdle() && !this.verifyStore.rdbReviewBusy && !this.rdbReviewDraftDirty &&
      !this.viewportStore.viewWorkspaceFileBusy && !macroService.isRecording();
  }

  private captureEngineeringReviewRuntime(): IntegratedEngineeringCheckpoint {
    if (this.viewWorkspaceCore === null) throw new Error('视图库尚未就绪');
    return { python: pythonWorkspaceService.exportBundle(), macros: macroService.captureState(),
      technology: technologyService.serialize(), deck: JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() }),
      drc: drcService.captureConfiguration(), layers: cloneUiLayerArray(this.docStore.layers) as UiLayer[],
      currentTechnologyId: this.currentTechnologyId, documentTechnologyJson: this.documentTechnologyJson,
      localPythonDraft: this.localPythonDraft, localPythonDraftDirty: this.localPythonDraftDirty, toolsRestored: this.engineeringToolsRestored,
      views: this.viewWorkspaceCore, sources: this.viewWorkspaceSources, rdbStorage: this.rdbReviewStorage,
      reports: this.rdbReviewWorkspace, rdbCore: this.rdbReviewCore, rdbUri: this.rdbReviewUri,
      mappings: this.rdbReviewLayoutMappings, mapping: this.rdbReviewMapping,
      rdbBaseline: this.rdbReviewBaseline, rdbTarget: this.rdbReviewTarget, rdbTargetSet: this.rdbReviewTargetSet,
      rdbPathIndex: this.rdbReviewPathIndex, markerItem: unwrapObserved(this.verifyStore.rdbMarkerItem), markerFrame: unwrapObserved(this.verifyStore.rdbMarkerFrame),
      markerDocumentId: this.rdbMarkerDocumentId, markerRevision: this.rdbMarkerLayoutRevision, markerCellId: this.rdbMarkerCellId,
      markerCellKey: this.rdbMarkerCellKey, markerReportToken: this.rdbMarkerReportToken,
      owned: engineeringProjectService.canRefreshBundle(this.docStore.activeWorkspaceId, this.engineeringBundle) };
  }

  private publishEngineeringReviewRuntime(candidate: EngineeringReviewRestoreState): void {
    const prepared: EngineeringRestorePayload = candidate.tools;
    const python: PythonWorkspaceBundle = { draft: prepared.python.draft, templates: prepared.python.templates };
    pythonWorkspaceService.validateBundle(python);
    let technology: TechnologyPackage | undefined = undefined;
    if (prepared.technologyJson.length > 0) {
      const parsed = parseTechnologyPackage(prepared.technologyJson);
      if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error);
      technology = parsed.technology;
    }
    let deck: EngineeringRuleSnapshot | undefined = undefined;
    if (prepared.drcDeckJson.length > 0) {
      deck = JSON.parse(prepared.drcDeckJson) as EngineeringRuleSnapshot;
      if (deck.rules.length > 0) {
        const parsed = parseRuleSetText(prepared.drcDeckJson, true);
        if (!parsed.ok) throw new Error(parsed.error);
        deck = { name: parsed.setName, rules: parsed.rules };
      }
    }
    if (prepared.macrosJson.length > 0) {
      const macros = JSON.parse(prepared.macrosJson) as EngineeringMacroSnapshot;
      if (macros.macros.some((macro: Macro): boolean => macro.originDocumentId !== this.docStore.activeWorkspaceId || !macroService.validSteps(macro.steps))) throw new Error('恢复宏身份或步骤无效');
    }
    const views: ViewWorkspaceService = new ViewWorkspaceService(this.integratedReviewWorkspace.createViewStore());
    if (!views.initialize()) throw new Error(views.getError());
    const sources: Map<string, ViewDatabaseSource> = new Map<string, ViewDatabaseSource>();
    for (const snapshot of this.engineeringReviewSources()) {
      const id: string = snapshot.documentId;
      const source: ViewDatabaseSource = { documentId: id, read: (): ViewDatabaseSnapshot => this.readViewWorkspaceSource(id) };
      views.bindDatabase(source); sources.set(id, source);
    }
    const reports: RdbReviewWorkspaceService = new RdbReviewWorkspaceService(); reports.restoreRecovery(candidate.state.reports);
    const storage: IntegratedReviewRdbStorage = this.integratedReviewWorkspace.forkRdb();
    const raw: string | undefined = storage.read();
    if (raw !== JSON.stringify(candidate.state.reports) || JSON.stringify(views.exportRecovery()) !== JSON.stringify(candidate.state.views)) throw new Error('工程候选与统一持久化投影不一致');
    // All detached metadata is valid before touching live tools. No camera,
    // geometry, dirty/revision/history or tool ownership changes in this phase.
    pythonWorkspaceService.restoreBundle(python);
    if (python.draft === undefined) pythonWorkspaceService.restoreSessionDraft(undefined);
    if (prepared.macrosJson.length > 0 && (JSON.parse(prepared.macrosJson) as EngineeringMacroSnapshot).macros.length > 0) macroService.importCollection(prepared.macrosJson, true);
    if (technology !== undefined) this.docStore.layers = technologyService.activate(technology, this.docStore.layers);
    else if (prepared.technologyJson.length === 0) technologyService.clear();
    if (deck !== undefined) drcService.setRules(deck.rules, deck.name);
    this.currentTechnologyId = technology?.id ?? ''; this.documentTechnologyJson = technologyService.serialize();
    this.localPythonDraft = prepared.python.draft; this.localPythonDraftDirty = false; this.engineeringToolsRestored = true;
    this.viewWorkspaceCore = views; this.viewWorkspaceSources = sources; this.rdbReviewStorage = storage;
    this.rdbReviewLayoutMappings = cloneStructured(candidate.state.layoutMappings ?? []) as RdbReviewLayoutMapping[];
    this.rdbReviewBaseline = raw; this.adoptRdbWorkspace(reports);
  }

  private rollbackEngineeringReviewRuntime(value: Object): void {
    const checkpoint: IntegratedEngineeringCheckpoint = value as IntegratedEngineeringCheckpoint;
    const failures: string[] = [];
    try { pythonWorkspaceService.replaceBundle(checkpoint.python); } catch (error) { failures.push(`Python：${String(error)}`); }
    try { macroService.restoreState(checkpoint.macros); } catch (error) { failures.push(`宏：${String(error)}`); }
    try { technologyService.restoreDocumentSettings(checkpoint.technology, checkpoint.deck, checkpoint.layers); }
    catch (error) { failures.push(`工艺：${String(error)}`); }
    try { drcService.restoreConfiguration(checkpoint.drc); } catch (error) { failures.push(`规则：${String(error)}`); }
    this.docStore.layers = checkpoint.layers; this.currentTechnologyId = checkpoint.currentTechnologyId; this.documentTechnologyJson = checkpoint.documentTechnologyJson;
    this.localPythonDraft = checkpoint.localPythonDraft; this.localPythonDraftDirty = checkpoint.localPythonDraftDirty; this.engineeringToolsRestored = checkpoint.toolsRestored;
    this.viewWorkspaceCore = checkpoint.views; this.viewWorkspaceSources = checkpoint.sources; this.rdbReviewStorage = checkpoint.rdbStorage;
    this.rdbReviewLayoutMappings = checkpoint.mappings; this.rdbReviewBaseline = checkpoint.rdbBaseline;
    this.rdbReviewWorkspace = checkpoint.reports; this.rdbReviewCore = checkpoint.rdbCore; this.rdbReviewUri = checkpoint.rdbUri;
    this.rdbReviewMapping = checkpoint.mapping; this.rdbReviewTarget = checkpoint.rdbTarget; this.rdbReviewTargetSet = checkpoint.rdbTargetSet; this.rdbReviewPathIndex = checkpoint.rdbPathIndex;
    this.verifyStore.rdbMarkerItem = checkpoint.markerItem; this.verifyStore.rdbMarkerFrame = checkpoint.markerFrame; this.rdbMarkerDocumentId = checkpoint.markerDocumentId;
    this.rdbMarkerLayoutRevision = checkpoint.markerRevision; this.rdbMarkerCellId = checkpoint.markerCellId;
    this.rdbMarkerCellKey = checkpoint.markerCellKey; this.rdbMarkerReportToken = checkpoint.markerReportToken;
    if (checkpoint.owned) engineeringProjectService.markSessionToolsOwned(this.docStore.activeWorkspaceId);
    else engineeringProjectService.forgetSessionTools(this.docStore.activeWorkspaceId);
    if (failures.length > 0) throw new Error(failures.join('；'));
  }

  private engineeringReviewRuntime(): EngineeringReviewRuntime {
    return { contextToken: (): string => this.engineeringReviewContext(),
      lifecycleToken: (): string => JSON.stringify([this.pageGeneration, this.docStore.activeWorkspaceId]), isIdle: (): boolean => this.engineeringReviewIdle(),
      readSources: (): ViewDatabaseSnapshot[] => this.engineeringReviewSources(), readState: (): EngineeringReviewRuntimeState => this.engineeringReviewState(),
      capture: (): Object => this.captureEngineeringReviewRuntime(),
      publish: (candidate: EngineeringReviewRestoreState): void => this.publishEngineeringReviewRuntime(candidate),
      rollback: (checkpoint: Object): void => this.rollbackEngineeringReviewRuntime(checkpoint) };
  }

  private openEngineeringReviewRestore(): void {
    try {
      if (this.engineeringBundle === undefined || !this.engineeringReviewIdle()) throw new Error('文档或工具事务尚未就绪');
      this.prepareViewWorkspace(); if (!this.persistViewWorkspacePresentation()) throw new Error(this.viewportStore.viewWorkspaceStatus);
      if (!this.initializeRdbReview()) throw new Error(this.verifyStore.rdbReviewStatus);
      this.revokeRdbWaiverPreview();
      this.engineeringRestoreProject = engineeringProjectService.validateBundle(this.engineeringBundle);
      const sourceId: string = this.engineeringRestoreProject.workspaceId;
      const sources: ViewDatabaseSnapshot[] = this.engineeringReviewSources();
      this.verifyStore.engineeringRestoreSourceIds = this.engineeringRestoreProject.review?.sources.map((source: EngineeringReviewSource): string => source.documentId) ?? [sourceId];
      this.verifyStore.engineeringRestoreTargets = sources.map((source: ViewDatabaseSnapshot): EngineeringRestoreSourceChoice => ({ documentId: source.documentId,
        title: source.documentId === this.docStore.activeWorkspaceId ? this.docStore.currentDocumentTitle : (this.workspaceDocuments.get(source.documentId)?.title ?? source.documentId) }));
      this.engineeringRestoreMappings = [{ sourceDocumentId: sourceId, targetDocumentId: this.docStore.activeWorkspaceId }];
      for (const id of this.verifyStore.engineeringRestoreSourceIds) {
        if (id !== sourceId && id !== this.docStore.activeWorkspaceId && sources.some((source: ViewDatabaseSnapshot): boolean => source.documentId === id)) {
          this.engineeringRestoreMappings.push({ sourceDocumentId: id, targetDocumentId: id });
        }
      }
      this.verifyStore.engineeringRestoreReplaceViews = false; this.prepareEngineeringReviewRestore();
      this.panelStore.showProjectPanel = false; this.panelStore.showRdbReviewPanel = false; this.panelStore.showViewWorkspacePanel = false;
    } catch (error) { this.panelStore.statusText = `工程恢复预览未打开：${String(error)}`; }
  }

  private prepareEngineeringReviewRestore(): void {
    if (this.engineeringRestoreBlocked) throw new Error('工程事务回滚未完成，请显式重新读取并核对当前工具与来源');
    if (this.engineeringRestoreProject === undefined || !this.engineeringReviewIdle()) throw new Error('恢复来源或当前事务已变化');
    if (this.engineeringRestoreCore !== null && this.verifyStore.engineeringRestorePreview !== undefined) this.engineeringRestoreCore.cancel(this.verifyStore.engineeringRestorePreview.token);
    this.engineeringRestoreCore = this.integratedReviewWorkspace.createEngineeringRestore();
    this.verifyStore.engineeringRestorePreview = this.engineeringRestoreCore.prepare(this.engineeringRestoreProject, this.docStore.activeWorkspaceId,
      { mappings: this.engineeringRestoreMappings, replaceTargetViews: this.verifyStore.engineeringRestoreReplaceViews }, this.engineeringReviewRuntime());
    this.verifyStore.engineeringRestoreError = '';
  }

  private changeEngineeringRestoreMapping(source: string, target: string, token: string): void {
    if (this.verifyStore.engineeringRestoreBusy || this.verifyStore.engineeringRestorePreview?.token !== token || !this.engineeringReviewIdle()) return;
    try {
      if (source === this.engineeringRestoreProject?.workspaceId || !this.verifyStore.engineeringRestoreSourceIds.includes(source) ||
        (target.length > 0 && !this.engineeringReviewSources().some((value: ViewDatabaseSnapshot): boolean => value.documentId === target))) throw new Error('映射来源或真实目标已变化');
      const next: EngineeringDocumentMapping[] = this.engineeringRestoreMappings.filter((value: EngineeringDocumentMapping): boolean => value.sourceDocumentId !== source);
      if (target.length > 0) {
        if (next.some((value: EngineeringDocumentMapping): boolean => value.targetDocumentId === target)) throw new Error('两个来源不可合并到同一目标；请先解除旧映射');
        next.push({ sourceDocumentId: source, targetDocumentId: target });
      }
      this.engineeringRestoreMappings = next; this.prepareEngineeringReviewRestore();
    } catch (error) { this.verifyStore.engineeringRestoreError = String(error); }
  }

  private changeEngineeringRestoreReplacement(replace: boolean, token: string): void {
    if (this.verifyStore.engineeringRestoreBusy || this.verifyStore.engineeringRestorePreview?.token !== token || !this.engineeringReviewIdle()) return;
    try { this.verifyStore.engineeringRestoreReplaceViews = replace; this.prepareEngineeringReviewRestore(); }
    catch (error) { this.verifyStore.engineeringRestoreError = String(error); }
  }

  private cancelEngineeringReviewRestore(token: string): void {
    if (this.verifyStore.engineeringRestorePreview?.token !== token) return;
    this.engineeringRestoreCore?.cancel(token);
    if (!this.verifyStore.engineeringRestoreBusy) { this.verifyStore.engineeringRestorePreview = undefined; this.engineeringRestoreCore = null; this.engineeringRestoreProject = undefined; }
  }

  private commitEngineeringReviewRestore(token: string): void {
    if (this.verifyStore.engineeringRestoreBusy || this.verifyStore.engineeringRestorePreview?.token !== token || !this.verifyStore.engineeringRestorePreview.canRestore || this.engineeringRestoreCore === null) return;
    this.verifyStore.engineeringRestoreBusy = true;
    let published: boolean = false;
    try {
      if (!this.engineeringRestoreCore.confirm(token, this.engineeringReviewRuntime())) throw new Error(this.engineeringRestoreCore.getError());
      published = true; this.verifyStore.engineeringRestorePreview = undefined;
      this.automaticEngineeringOrigins.delete(this.docStore.activeWorkspaceId);
      this.integratedReviewWorkspace.finishEngineeringCommit();
      engineeringProjectService.markSessionToolsOwned(this.docStore.activeWorkspaceId);
      const revisionBefore: number = editService.getSessionRevision();
      editService.markDirty(); this.docStore.documentDirty = true;
      // This revision change records restored tools; geometry and stable Cell
      // lineage are unchanged. Keep only exact pre-change bindings current.
      const mappings: RdbReviewLayoutMapping[] = this.rdbReviewLayoutMappings.map((value: RdbReviewLayoutMapping): RdbReviewLayoutMapping => ({
        reportSourceIdentity: value.reportSourceIdentity, reportCell: value.reportCell, layoutDocumentId: value.layoutDocumentId,
        layoutCellId: value.layoutCellId, layoutCellKey: value.layoutCellKey,
        layoutRevision: value.layoutDocumentId === this.docStore.activeWorkspaceId && value.layoutRevision === revisionBefore &&
          this.docCellKeys[value.layoutCellId] === value.layoutCellKey ? editService.getSessionRevision() : value.layoutRevision }));
      this.integratedReviewWorkspace.writeLayoutMappings(this.rdbReviewLayoutMappings, mappings); this.rdbReviewLayoutMappings = mappings;
      const view: ViewRecord = this.viewWorkspaceCore!.getView(this.viewWorkspaceCore!.activeViewId(this.docStore.activeWorkspaceId));
      this.viewWorkspaceDocumentId = this.docStore.activeWorkspaceId; this.viewportStore.viewWorkspaceActiveId = view.id;
      this.viewWorkspaceApply(view.presentation, this.viewWorkspaceCore!.resolveLocation(this.docStore.activeWorkspaceId, view.presentation.location), view.id);
      this.syncLayerVisibilityMirror(); this.syncShapesFromEditService(); this.refreshViewWorkspace(); this.refreshRdbReview();
      this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false; this.verifyStore.tracedNets = []; this.verifyStore.lvsHasResult = false;
      this.verifyStore.highlightedViolation = null; this.verifyStore.highlightedViolationId = -1; this.clearRdbReviewOverlay();
      this.refreshEngineeringDependencies(); this.scheduleWorkspaceDraft(); this.verifyStore.engineeringRestorePreview = undefined;
      this.engineeringRestoreCore = null; this.engineeringRestoreProject = undefined;
      this.panelStore.statusText = '工程工具、视图、书签、只读引用与审阅已恢复；脚本未运行，外部报告未另存为';
    } catch (error) {
      if (this.engineeringRestoreCore?.isBlocked() || published) this.engineeringRestoreBlocked = true;
      this.verifyStore.engineeringRestoreError = published ? `恢复记录已发布，显示或草稿同步未完成：${String(error)}；请重新读取本机工作区` :
        `恢复未确认：${String(error)}；需要时重新读取本机工作区`;
      this.panelStore.statusText = this.verifyStore.engineeringRestoreError;
    }
    finally { this.verifyStore.engineeringRestoreBusy = false; }
  }

  private confirmRestoreEngineeringTools(): void {
    if (this.engineeringBundle === undefined) return;
    if (this.engineeringBundle.review !== undefined) { this.openEngineeringReviewRestore(); return; }
    const contextKey: string = this.parameterDialogContext();
    let toolContextKey: string = '';
    let payload: EngineeringRestorePayload;
    let deck: EngineeringRuleSnapshot | undefined;
    let technology: TechnologyPackage | undefined;
    try {
      toolContextKey = this.projectToolContext();
      payload = engineeringProjectService.restoreTools(this.engineeringBundle, this.docStore.activeWorkspaceId);
      const python: PythonWorkspaceBundle = { draft: payload.python.draft, templates: payload.python.templates };
      pythonWorkspaceService.validateBundle(python);
      if (payload.drcDeckJson.length > 0) {
        deck = JSON.parse(payload.drcDeckJson) as EngineeringRuleSnapshot;
        if (deck.rules.length > 0) {
          const parsed = parseRuleSetText(payload.drcDeckJson, true);
          if (!parsed.ok) throw new Error(parsed.error);
          deck = { name: parsed.setName, rules: parsed.rules };
        }
      }
      if (payload.technologyJson.length > 0) {
        const parsed = parseTechnologyPackage(payload.technologyJson);
        if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error);
        technology = parsed.technology;
      }
      if (payload.macrosJson.length > 0) {
        const collection: EngineeringMacroSnapshot = JSON.parse(payload.macrosJson) as EngineeringMacroSnapshot;
        if (collection.macros.some((macro: Macro): boolean => macro.originDocumentId !== this.docStore.activeWorkspaceId || !macroService.validSteps(macro.steps))) throw new Error('工程宏身份或步骤无效');
      }
    } catch (error) { this.panelStore.statusText = `工具包未恢复：${String(error)}`; return; }
    const prepared: EngineeringRestorePayload = payload;
    const preparedDeck: EngineeringRuleSnapshot | undefined = deck;
    const preparedTechnology: TechnologyPackage | undefined = technology;
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '恢复工程脚本与规则',
      message: `目标：${this.docStore.currentDocumentTitle}。替换当前 Python 草稿，合并 ${prepared.python.templates.length} 个模板，同名旧内容保留；加载保存的规则和工艺。此操作不运行脚本。`,
      primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消', action: () => {} },
      secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '恢复内容', action: () => {
        if (contextKey !== this.parameterDialogContext()) { this.panelStore.statusText = '文档或选区已变化，请重新打开恢复确认'; return; }
        try {
          if (toolContextKey !== this.projectToolContext()) { this.panelStore.statusText = '脚本或工具内容已变化，请重新打开恢复确认'; return; }
        } catch (_) { this.panelStore.statusText = '脚本或工具内容已变化，请重新打开恢复确认'; return; }
        const priorPython: PythonWorkspaceBundle = pythonWorkspaceService.exportBundle();
        const priorMacros: MacroServiceState = macroService.captureState();
        const priorTechnology: string = technologyService.serialize();
        const priorDeck: string = JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() });
        const priorDrc: DrcConfiguration = drcService.captureConfiguration();
        const priorLayers: UiLayer[] = cloneUiLayerArray(this.docStore.layers) as UiLayer[];
        let importedTemplates: number = 0;
        let renamedTemplates: number = 0;
        let importedMacros: number = 0;
        try {
          // Commit all tool domains before granting ownership or marking the document dirty.
          const python: PythonWorkspaceBundle = { draft: prepared.python.draft, templates: prepared.python.templates };
          const restored = pythonWorkspaceService.restoreBundle(python);
          importedTemplates = restored.importedTemplates; renamedTemplates = restored.renamedTemplates.length;
          if (python.draft === undefined) pythonWorkspaceService.restoreSessionDraft(undefined);
          if (prepared.macrosJson.length > 0 && (JSON.parse(prepared.macrosJson) as EngineeringMacroSnapshot).macros.length > 0) importedMacros = macroService.importCollection(prepared.macrosJson, true);
          if (preparedTechnology !== undefined) this.docStore.layers = technologyService.activate(preparedTechnology, this.docStore.layers);
          else if (prepared.technologyJson.length === 0) technologyService.clear();
          // A saved empty deck intentionally clears rules; never fall back to builtin rules.
          if (preparedDeck !== undefined) drcService.setRules(preparedDeck.rules, preparedDeck.name);
        } catch (error) {
          let rollbackError: string = '';
          try { pythonWorkspaceService.replaceBundle(priorPython); } catch (failure) { rollbackError += `；Python 回滚失败：${String(failure)}`; }
          try { macroService.restoreState(priorMacros); } catch (failure) { rollbackError += `；宏存储回滚失败：${String(failure)}`; }
          try { technologyService.restoreDocumentSettings(priorTechnology, priorDeck, priorLayers); this.docStore.layers = priorLayers; }
          catch (failure) { rollbackError += `；工艺回滚失败：${String(failure)}`; }
          drcService.restoreConfiguration(priorDrc);
          this.panelStore.statusText = `恢复未完成：${String(error)}；${rollbackError.length === 0 ? '工具内容已回滚，工程包仍保留' : '工程包仍保留' + rollbackError}`;
          return;
        }
        this.currentTechnologyId = preparedTechnology?.id ?? '';
        this.documentTechnologyJson = technologyService.serialize();
        this.engineeringToolsRestored = true;
        this.localPythonDraft = prepared.python.draft;
        this.localPythonDraftDirty = false;
        this.automaticEngineeringOrigins.delete(this.docStore.activeWorkspaceId);
        engineeringProjectService.markSessionToolsOwned(this.docStore.activeWorkspaceId);
        this.cancelActiveNativeJob();
        editService.markDirty(); this.syncLayerVisibilityMirror(); this.syncShapesFromEditService();
        this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false; this.verifyStore.tracedNets = []; this.verifyStore.lvsHasResult = false;
        this.verifyStore.highlightedViolation = null; this.verifyStore.highlightedViolationId = -1;
        this.refreshEngineeringDependencies(); this.scheduleWorkspaceDraft();
        this.panelStore.statusText = `已恢复草稿与 ${importedTemplates} 个模板、${importedMacros} 个文档宏；${renamedTemplates} 项重命名，脚本尚未运行`;
      } }
    });
  }

  private async exportRecoveryCopy(item: ProjectRecoveryEntry): Promise<void> {
    this.canvasFocusReturnTicket++;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const protectedTargets: string[] = [this.docStore.currentFilePath, this.currentSaveUri, this.currentProjectUri];
      this.workspaceDocuments.forEach((document: WorkspaceDocument) => {
        protectedTargets.push(document.sourcePath, document.saveUri, document.projectUri);
      });
      await fileRecoveryService.exportBackup(context, item, protectedTargets);
      this.docStore.fileRecoveryEntries = fileRecoveryService.list(context);
      this.panelStore.statusText = '安全副本已导出到新位置，原备份仍保留';
    } catch (error) { this.panelStore.statusText = `安全副本未导出：${String(error)}；原备份保留`; }
  }

  private async openProject(): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (!this.canOpenWorkspaceDocument()) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const document: WorkspaceDocument = await workspaceService.importProject(context);
      if (!this.canOpenWorkspaceDocument()) return;
      this.captureWorkspaceDocument();
      this.activateWorkspaceDocument(document);
      this.workspaceDocuments.set(document.id, document);
      this.panelStore.showProjectPanel = false;
      this.saveWorkspaceDraft();
      this.panelStore.statusText = `已打开工程 ${document.title}`;
    } catch (error) { this.panelStore.statusText = `打开工程失败：${String(error)}`; }
  }

  private async restoreWorkspaceHistory(item: WorkspaceHistory): Promise<void> {
    if (!this.canOpenWorkspaceDocument()) return;
    try {
      const document: WorkspaceDocument = await workspaceService.restoreHistory(item);
      if (!this.canOpenWorkspaceDocument()) return;
      this.captureWorkspaceDocument();
      document.id = workspaceService.newId(); document.title = `${document.title}（版本副本）`;
      document.saveUri = ''; document.projectUri = ''; document.dirty = true;
      this.activateWorkspaceDocument(document);
      this.workspaceDocuments.set(document.id, document);
      this.panelStore.showProjectPanel = false; this.saveWorkspaceDraft();
      this.panelStore.statusText = '历史版本已打开为新副本';
    } catch (error) { this.panelStore.statusText = `恢复版本失败：${String(error)}`; }
  }

  private locateShapeById(id: number): void {
    const shape: Shape | undefined = editService.getShapes().find((item: Shape) => item.id === id);
    if (shape === undefined) return;
    const bounds: ShapeBounds | undefined = advEditService.getSearchShapeBounds(shape);
    if (bounds === undefined) { this.panelStore.statusText = advEditService.getLastGeometryError() || '对象没有可解析几何，未改变定位'; return; }
    const owner: number = shape.ownerCellId ?? this.resolveTopCellIdForExport(this.propertyCellOptions().map((cell: PropertyCellOption) => cell.name));
    editService.exitToTop();
    if (editService.getCurrentCellId() !== owner) editService.enterCell(owner);
    editService.selectShape(id); this.viewportStore.selectedShapeId = id; this.viewportStore.selectedShapeCount = editService.getSelectedIds().length; this.shapes = editService.getShapes().slice();
    this.refreshEditingCellPresentation();
    this.focusWorldBounds(bounds);
    this.panelStore.statusText = `已定位 #${id} · L${shape.layerNumber}/${shape.datatype}`;
  }

  /** Keep desktop navigation outside the floating drawing strip. Tiny or
   * non-desktop canvases retain their previous full-viewport fallback. */
  private canvasNavigationViewport(): CanvasNavigationViewport {
    const width: number = this.viewportStore.canvasViewportWidth, height: number = this.viewportStore.canvasViewportHeight;
    const left: number = Math.max(CANVAS_FIT_PADDING, 14 + 48 + 18 + 8);
    const usableWidth: number = width - left - CANVAS_FIT_PADDING;
    const usableHeight: number = height - CANVAS_FIT_PADDING * 2;
    if (this.isDesktopWorkspace() && usableWidth >= 120 && usableHeight >= 120) {
      return { width: usableWidth, height: usableHeight,
        centerX: left + usableWidth / 2, centerY: CANVAS_FIT_PADDING + usableHeight / 2,
        toolbarReserved: true };
    }
    return { width, height, centerX: width / 2, centerY: height / 2, toolbarReserved: false };
  }

  private focusWorldBounds(bounds: ShapeBounds): void {
    const width: number = Math.max(100, bounds.maxX - bounds.minX), height: number = Math.max(100, bounds.maxY - bounds.minY);
    const viewport: CanvasNavigationViewport = this.canvasNavigationViewport();
    const zoom: number = Math.min(MAX_ZOOM_PERCENT, Math.max(MIN_ZOOM_PERCENT,
      Math.min(viewport.width * 70 / width, viewport.height * 70 / height)));
    this.viewportStore.zoomPercent = zoom;
    this.viewportStore.viewOffsetX = viewport.centerX * 100 / zoom - (bounds.minX + bounds.maxX) / 2;
    this.viewportStore.viewOffsetY = viewport.centerY * 100 / zoom + (bounds.minY + bounds.maxY) / 2;
    viewService.setViewZoomPercent(zoom); viewService.setViewOffset(this.viewportStore.viewOffsetX, this.viewportStore.viewOffsetY);
  }

  private layersForDisplay(): UiLayer[] {
    const key: string = `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}:${this.layersQuickSignature()}`;
    if (key === this.cachedDisplayLayersKey && this.cachedDisplayLayers.length > 0) {
      return this.cachedDisplayLayers;
    }
    const computed: UiLayer[] = this.layersWithCounts(unwrapObserved(this.docStore.layers), editService.getCurrentCellShapes());
    this.cachedDisplayLayersKey = key;
    this.cachedDisplayLayers = computed;
    return computed;
  }

  // Copy supported JSON layer payloads without sharing nested objects. Runtime
  // own undefined values and sparse indices remain distinct until JSON saving.
  private cloneLayerOwnValue(value: Object | null | undefined): Object | null | undefined {
    if (value === null || typeof value !== 'object') return value;
    if (Array.isArray(value)) {
      const source: (Object | null | undefined)[] = value as (Object | null | undefined)[];
      const copy: (Object | null | undefined)[] = new Array<Object | null | undefined>(source.length);
      const present: Set<string> = new Set<string>(Object.keys(source));
      for (let index: number = 0; index < source.length; index++) {
        if (present.has(String(index))) copy[index] = this.cloneLayerOwnValue(source[index]);
      }
      return copy;
    }
    const source: Record<string, Object | null | undefined> = value as Record<string, Object | null | undefined>;
    const keys: string[] = Object.keys(source);
    const entries: string[] = keys.map((key: string): string => JSON.stringify(key) + ':null');
    // Precreate own data properties, including an inert __proto__ key.
    const copy: Record<string, Object | null | undefined> = JSON.parse('{' + entries.join(',') + '}') as Record<string, Object | null | undefined>;
    for (const key of keys) copy[key] = this.cloneLayerOwnValue(source[key]);
    return copy;
  }

  private layersWithCounts(sourceLayers: UiLayer[], shapes: Shape[], preserveOwnFields: boolean = false): UiLayer[] {
    const counts: Map<string, number> = new Map<string, number>();
    for (const shape of shapes) {
      if (shape.type === ShapeType.INSTANCE || shape.type === ShapeType.NODE) continue;
      const key: string = `${shape.layerNumber}:${shape.datatype}`;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
    const included: Set<string> = new Set<string>();
    const nextLayers: UiLayer[] = [];
    for (let i = 0; i < sourceLayers.length; i++) {
      const layer = sourceLayers[i];
      const nextLayer: UiLayer = this.cloneLayerOwnValue(layer) as UiLayer;
      nextLayer.elementCount = counts.get(`${layer.layerNumber}:${layer.datatype === undefined ? 0 : layer.datatype}`) ?? 0;
      nextLayers.push(nextLayer);
      included.add(`${layer.layerNumber}:${layer.datatype}`);
    }

    for (let i = 0; i < shapes.length; i++) {
      const shape = shapes[i];
      if (shape.type === ShapeType.INSTANCE || shape.type === ShapeType.NODE) continue;
      const key: string = `${shape.layerNumber}:${shape.datatype}`;
      const queryKey: string = `${shape.layerNumber}:${shape.datatype === undefined ? 0 : shape.datatype}`;
      if (!included.has(queryKey)) {
        const addedLayer: UiLayer = {
          layerNumber: shape.layerNumber,
          datatype: shape.datatype,
          chineseName: `图层${shape.layerNumber}`,
          englishName: `L${shape.layerNumber}`,
          color: this.layerColor(nextLayers.length),
          visible: true,
          elementCount: counts.get(queryKey) ?? 0,
          group: LayerGroup.OTHER,
        };
        nextLayers.push(addedLayer);
        included.add(key);
      }
    }
    return nextLayers;
  }

  private refreshLayerCounts(sourceShapes?: Shape[], preserveOwnFields: boolean = false): void {
    const shapes: Shape[] = sourceShapes !== undefined ? sourceShapes : this.shapes;
    this.docStore.layers = this.layersWithCounts(this.docStore.layers, shapes, preserveOwnFields);
    this.docStore.docElementCount = shapes.length;
    this.syncLayerVisibilityMirror();
  }

  private countShapesOnLayerDirect(layerNumber: number, shapes: Shape[], datatype: number = 0): number {
    let count = 0;
    for (let i = 0; i < shapes.length; i++) {
      if (shapes[i].layerNumber === layerNumber && shapes[i].datatype === datatype) {
        count++;
      }
    }
    return count;
  }

  private layerListContains(layers: UiLayer[], layerNumber: number, datatype: number = 0): boolean {
    for (let i = 0; i < layers.length; i++) {
      if (layers[i].layerNumber === layerNumber && layers[i].datatype === datatype) {
        return true;
      }
    }
    return false;
  }

  private toggleLayer(layerNumber: number, datatype: number = 0): void {
    const next: UiLayer[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const layer = this.docStore.layers[i];
      const nextVisible = layer.layerNumber === layerNumber && layer.datatype === datatype ? !layer.visible : layer.visible;
      next.push(cloneLayerWithVisible(layer, nextVisible));
    }
    this.docStore.layers = next;
    this.syncLayerVisibilityMirror();
    this.panelStore.statusText = `L${layerNumber}/D${datatype} 可见性已切换`;
  }

  private setLayerVisible(layerNumber: number, visible: boolean, datatype: number = 0): void {
    const next: UiLayer[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const layer = this.docStore.layers[i];
      next.push(cloneLayerWithVisible(layer, layer.layerNumber === layerNumber && layer.datatype === datatype ? visible : layer.visible));
    }
    this.docStore.layers = next;
    this.syncLayerVisibilityMirror();
    this.panelStore.statusText = `${visible ? '显示' : '隐藏'} L${layerNumber}/D${datatype}`;
  }

  /** 切换图层锁定状态 */
  private toggleLayerLock(layerNumber: number, datatype: number = 0): void {
    const next: UiLayer[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const layer = this.docStore.layers[i];
      if (layer.layerNumber === layerNumber && layer.datatype === datatype) {
        // 必须走 cloneLayerWithVisible：它逐字段复制样式（lineStyle/fillStyle/
        // transparency/lineWidth/selectable/highlighted/animated）。
        // 早先这里手搓 9 个字面量，锁定一次图层就把 .lyp 导入的样式抹掉。
        const cloned: UiLayer = cloneLayerWithVisible(layer, layer.visible);
        cloned.locked = !(layer.locked === true);
        next.push(cloned);
      } else {
        next.push(layer);
      }
    }
    this.docStore.layers = next;
    editService.refreshLayerAccess();
    this.viewportStore.selectedShapeId = editService.getSelectedId();
    this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;
    const isLocked: boolean = this.docStore.layers.find(l => l.layerNumber === layerNumber && l.datatype === datatype)?.locked === true;
    this.panelStore.statusText = `L${layerNumber}/D${datatype} ${isLocked ? '已锁定' : '已解锁'}`;
  }

  /** 选择指定层上的所有图形 */
  private selectAllOnLayer(layerNumber: number, datatype: number = 0): void {
    const allShapes: Shape[] = editService.getCurrentCellShapes();
    const ids: number[] = [];
    for (let i = 0; i < allShapes.length; i++) {
      if (allShapes[i].layerNumber === layerNumber && allShapes[i].datatype === datatype) {
        ids.push(allShapes[i].id);
      }
    }
    editService.selectMultiple(ids);
    const selectedCount: number = editService.getSelectedIds().length;
    this.syncShapesFromEditService();
    this.panelStore.statusText = `已选择 L${layerNumber}/D${datatype} 上 ${selectedCount} 个图形`;
  }

  private applyViewPreset(name: string): void {
    if (!this.pageAlive || !this.docStore.layerPresetNames.includes(name)) { this.panelStore.statusText = '预设不存在，请重新选择'; return; }
    try {
      this.panelStore.statusText = viewService.applyLayerPreset(name) ? `已应用视图预设：${name}` : '预设不存在，请重新选择';
    } catch (failure) { this.panelStore.statusText = `预设应用失败：${String(failure)}`; }
  }

  private confirmDeleteViewPreset(name: string): void {
    if (!this.pageAlive || !this.docStore.layerPresetNames.includes(name)) { this.panelStore.statusText = '预设不存在，请重新选择'; return; }
    const generation: number = this.pageGeneration;
    try {
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '删除视图预设', message: `删除“${name}”？当前图层可见性保留。`,
      primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => {} },
      secondaryButton: { value: '删除预设', fontColor: Color.White, backgroundColor: COLORS.danger, action: () => {
        if (!this.pageAlive || generation !== this.pageGeneration || !this.docStore.layerPresetNames.includes(name)) return;
        const deleted: boolean = viewService.deleteLayerPreset(name);
        this.panelStore.statusText = deleted ? `已删除视图预设：${name}` : viewService.getLayerPresetError();
        if (deleted) this.docStore.layerPresetNames = viewService.listLayerPresets();
      } }
    });
    } catch (failure) { this.panelStore.statusText = `删除预设失败：${String(failure)}`; }
  }

  private applyLayerPresetToLayers(visibilities: Map<string, boolean>): void {
    const next: UiLayer[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const layer = this.docStore.layers[i];
      const visible: boolean | undefined = visibilities.get(`${layer.layerNumber}:${layer.datatype}`);
      next.push(cloneLayerWithVisible(layer, visible !== undefined ? visible : layer.visible));
    }
    this.docStore.layers = next;
    this.syncLayerVisibilityMirror();
    this.panelStore.statusText = '已应用图层预设';
  }

  // ===== .lyp 图层属性文件互通（gap-matrix §5） =====

  /**
   * 导入 KLayout .lyp：picker 选文件 → 纯函数解析 → mergeLypIntoLayers 合并。
   * 走 applyLayerPresetToLayers 同一状态路径（重建 @State layers + 可见性镜像 +
   * 计数刷新），画布 layersForDisplay() 自然拾取新设置，无第二真源。
   */
  private async importLypFile(): Promise<void> {
    this.canvasFocusReturnTicket++;
    const documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
    let previous: EditSessionState | undefined;
    let before: EditStructureState | undefined;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.panelStore.statusText = '正在选择 .lyp 图层属性文件...';
      const content: LypFileContent = await lypService.pickAndReadLyp(context);
      if (documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
        this.panelStore.statusText = '版图已切换或修改，请在当前版图重新导入 .lyp'; return;
      }
      const parsed: LypParseResult = parseLyp(content.text);
      const merged: LypMergeResult = mergeLypIntoLayers(this.docStore.layers, parsed.layers);
      this.finishNudgeTransaction();
      before = this.cellStructureState();
      const after: EditStructureState = cloneEditStructureModel(before, true) as EditStructureState;
      after.layers = merged.layers.map((layer: UiLayer): UiLayer => {
        const original: UiLayer | undefined = this.docStore.layers.find((source: UiLayer): boolean => source.layerNumber === layer.layerNumber && source.datatype === layer.datatype);
        if (original === undefined) return cloneUiLayerModel(layer) as UiLayer;
        const source: Record<string, Object> = original as Object as Record<string, Object>;
        const values: Record<string, Object> = layer as Object as Record<string, Object>;
        const keys: string[] = Object.keys(source), mergedKeys: string[] = Object.keys(values);
        for (const key of mergedKeys) if (!keys.includes(key)) keys.push(key);
        const entries: string[] = [];
        for (const key of keys) {
          const value: Object = mergedKeys.includes(key) ? values[key] : source[key];
          if (value !== undefined) entries.push(JSON.stringify(key) + ':' + JSON.stringify(value));
        }
        return JSON.parse('{' + entries.join(',') + '}') as UiLayer;
      });
      if (parsed.layerDefinitions !== undefined) after.layerDefinitions = parsed.layerDefinitions;
      previous = editService.captureSession(true);
      if (!editService.applyDocumentStructure(editService.getShapes(), before, after, `导入 .lyp：${content.fileName}`, true, undefined, true)) {
        throw new Error('图层属性事务未提交，原版图已保留');
      }
      this.syncShapesFromEditService(true);
      const warnCount: number = parsed.warnings.length + merged.warnings.length;
      this.scheduleWorkspaceDraft();
      const firstWarning: string = parsed.warnings.length > 0 ? parsed.warnings[0]
        : (merged.warnings.length > 0 ? merged.warnings[0] : '');
      this.panelStore.statusText = `已导入 ${content.fileName}: 更新 ${merged.appliedCount}/${parsed.layers.length} 层` +
        (warnCount > 0 ? `；${firstWarning}（共 ${warnCount} 条提示）` : '');
      if (parsed.warnings.length > 0) {
        console.warn('LypService 导入警告: ' + parsed.warnings.join(' | '));
      }
      if (merged.warnings.length > 0) {
        console.warn('LypService 合并警告: ' + merged.warnings.join(' | '));
      }
    } catch (e) {
      let restoreFailure: string = '';
      if (previous !== undefined && before !== undefined) {
        editService.restoreSession(previous, true);
        try { this.restoreCellStructure(before); this.syncShapesFromEditService(true); }
        catch (failure) { restoreFailure = `；界面恢复失败：${String(failure)}`; }
        finally { editService.restoreSession(previous, true); }
      }
      const msg: string = (e instanceof Error ? e.message : String(e)) + restoreFailure;
      this.panelStore.statusText = msg.indexOf('未选择') >= 0 ? '已取消 .lyp 导入' : `.lyp 导入失败: ${msg}`;
    }
  }

  /** 导出当前图层显示设置为 KLayout .lyp（@State layers 是唯一来源） */
  private async exportLypFile(): Promise<void> {
    this.canvasFocusReturnTicket++;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const entries = entriesFromUiLayers(this.docStore.layers);
      const warnings: string[] = lypExportWarnings(entries);
      const xml: string = formatLyp(entries, this.sourceLayerDefinitions);
      const base: string = this.lypBaseName();
      this.panelStore.statusText = '正在选择 .lyp 保存位置...';
      const uri: string = await lypService.pickAndWriteLyp(context, base + '.lyp', xml);
      this.panelStore.statusText = `已导出 ${this.fileNameFromPath(uri)}: ${entries.length} 层`
        + (warnings.length > 0 ? `；${warnings[0]}（共 ${warnings.length} 条提示）` : '');
      this.showExportLocation('LYP', this.fileNameFromPath(uri), uri);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.panelStore.statusText = msg.indexOf('未选择') >= 0 ? '已取消 .lyp 导出' : `.lyp 导出失败: ${msg}`;
    }
  }

  /** .lyp 默认文件名：当前文档名去扩展名，无文档时用 hongtu */
  private lypBaseName(): string {
    let name: string = this.currentFileDisplayName();
    if (name.length === 0) name = 'hongtu';
    const dot: number = name.lastIndexOf('.');
    if (dot > 0) {
      name = name.substring(0, dot);
    }
    return name;
  }

  private selectLayer(layer: UiLayer): void {
    this.viewportStore.selectedLayerNumber = layer.layerNumber;
        this.viewportStore.selectedDatatype = layer.datatype;
    this.panelStore.showLayerStylePanel = true;
    this.panelStore.statusText = `当前图层: ${layer.chineseName} (${layer.englishName})`;
  }

  private selectShape(shape: Shape): void {
    this.viewportStore.pickedPlacement = null;
    this.panelStore.propertyPanelClosed = false;
    this.viewportStore.selectedShapeId = shape.id;
    this.viewportStore.selectedLayerNumber = shape.layerNumber;
        this.viewportStore.selectedDatatype = shape.datatype;
    // 接通 EditService：同步选中状态到编辑服务（命中测试/移动/删除依赖此状态）
    editService.selectShape(shape.id);
    this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;
    this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
    this.panelStore.statusText = `选中图形 #${shape.id} (L${shape.layerNumber}#${shape.id})`;
  }

  private selectMultipleShapes(ids: number[]): void {
    this.viewportStore.pickedPlacement = null;
    this.panelStore.propertyPanelClosed = false;
    this.syncShapesFromEditService();
    if (ids.length === 0) {
      this.viewportStore.selectedShapeId = -1;
      this.panelStore.statusText = '已清除选择';
      return;
    }
    this.viewportStore.selectedShapeId = ids[0];
    const first: Shape | undefined = this.shapes.find((shape: Shape) => shape.id === ids[0]);
    if (first !== undefined) {
      this.viewportStore.selectedLayerNumber = first.layerNumber;
        this.viewportStore.selectedDatatype = first.datatype;
    }
    this.panelStore.statusText = `已框选 ${ids.length} 个图形`;
  }

  private setZoom(delta: number): void {
    const targetZoom: number = this.clampZoom(this.viewportStore.zoomPercent * Math.pow(1.2, delta / 20));
    this.zoomCanvasToAt(this.viewportStore.canvasViewportWidth / 2, this.viewportStore.canvasViewportHeight / 2, targetZoom);
  }

  private zoomCanvasAt(screenX: number, screenY: number, scaleFactor: number): void {
    if (!Number.isFinite(scaleFactor) || scaleFactor <= 0) {
      return;
    }
    this.zoomCanvasToAt(screenX, screenY, this.viewportStore.zoomPercent * scaleFactor);
  }

  private onCanvasBoxZoom(left: number, top: number, width: number, height: number): void {
    if (!Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(width) ||
      !Number.isFinite(height) || width <= 0 || height <= 0) return;
    const oldZoom: number = this.clampZoom(this.viewportStore.zoomPercent);
    // The selection was measured in the complete old camera; only its target
    // scale and center use the same toolbar-safe viewport as Fit.
    const worldX: number = (left + width / 2) * 100 / oldZoom - this.viewportStore.viewOffsetX;
    const worldY: number = screenToWorldYpx(top + height / 2, oldZoom, this.viewportStore.viewOffsetY);
    const viewport: CanvasNavigationViewport = this.canvasNavigationViewport();
    const nextZoom: number = this.clampZoom(oldZoom * Math.min(viewport.width / width, viewport.height / height) * 0.9);
    const nextOffsetX: number = viewport.centerX * 100 / nextZoom - worldX;
    const nextOffsetY: number = viewport.centerY * 100 / nextZoom + worldY;
    if (!Number.isFinite(nextOffsetX) || !Number.isFinite(nextOffsetY)) return;
    this.viewportStore.zoomPercent = nextZoom;
    this.viewportStore.viewOffsetX = nextOffsetX;
    this.viewportStore.viewOffsetY = nextOffsetY;
    viewService.setViewZoomPercent(nextZoom);
    viewService.setViewOffset(nextOffsetX, nextOffsetY);
    this.panelStore.statusText = `框选放大：${nextZoom.toFixed(nextZoom < 20 ? 1 : 0)}%`;
  }

  private zoomCanvasToAt(screenX: number, screenY: number, targetZoom: number): void {
    const oldZoom: number = this.clampZoom(this.viewportStore.zoomPercent);
    const nextZoom: number = this.clampZoom(targetZoom);
    if (Math.abs(nextZoom - oldZoom) < 0.001) {
      return;
    }
    const anchorX: number = Number.isFinite(screenX) ? screenX : this.viewportStore.canvasViewportWidth / 2;
    const anchorY: number = Number.isFinite(screenY) ? screenY : this.viewportStore.canvasViewportHeight / 2;
    const anchorWorldX: number = anchorX * 100 / oldZoom - this.viewportStore.viewOffsetX;
    const anchorWorldY: number = screenToWorldYpx(anchorY, oldZoom, this.viewportStore.viewOffsetY);
    const nextOffsetX: number = anchorX * 100 / nextZoom - anchorWorldX;
    const nextOffsetY: number = anchorWorldY + anchorY * 100 / nextZoom;
    this.viewportStore.zoomPercent = nextZoom;
    this.viewportStore.viewOffsetX = nextOffsetX;
    this.viewportStore.viewOffsetY = nextOffsetY;
    viewService.setViewZoomPercent(nextZoom);
    viewService.setViewOffset(nextOffsetX, nextOffsetY);
    this.panelStore.statusText = `缩放: ${nextZoom.toFixed(nextZoom < 20 ? 1 : 0)}%`;
  }

  private panCanvas(deltaScreenX: number, deltaScreenY: number): void {
    if (!Number.isFinite(deltaScreenX) || !Number.isFinite(deltaScreenY)) {
      return;
    }
    const zoom: number = this.clampZoom(this.viewportStore.zoomPercent);
    const nextOffsetX: number = this.viewportStore.viewOffsetX + deltaScreenX * 100 / zoom;
    const nextOffsetY: number = this.viewportStore.viewOffsetY + deltaScreenY * 100 / zoom;
    this.viewportStore.viewOffsetX = nextOffsetX;
    this.viewportStore.viewOffsetY = nextOffsetY;
    viewService.setViewOffset(nextOffsetX, nextOffsetY);
  }

  private updateCanvasViewport(width: number, height: number): void {
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      return;
    }
    const resized: boolean = width !== this.viewportStore.canvasViewportWidth || height !== this.viewportStore.canvasViewportHeight;
    const preserveCenter: boolean = this.canvasViewportMeasured && resized;
    let nextOffsetX: number = this.viewportStore.viewOffsetX;
    let nextOffsetY: number = this.viewportStore.viewOffsetY;
    if (preserveCenter) {
      const scale: number = this.viewportStore.zoomPercent / 100;
      if (!Number.isFinite(scale) || scale <= 0 || !Number.isFinite(nextOffsetX) || !Number.isFinite(nextOffsetY)) return;
      // Match viewCameraToCanvas: keep the world center while the measured viewport changes.
      nextOffsetX += (width - this.viewportStore.canvasViewportWidth) / (2 * scale);
      nextOffsetY += (height - this.viewportStore.canvasViewportHeight) / (2 * scale);
      if (!Number.isFinite(nextOffsetX) || !Number.isFinite(nextOffsetY)) return;
    }
    if (width !== this.viewportStore.canvasViewportWidth) {
      this.viewportStore.canvasViewportWidth = width;
    }
    if (height !== this.viewportStore.canvasViewportHeight) {
      this.viewportStore.canvasViewportHeight = height;
    }
    // Startup defaults do not describe a measured camera; first layout only establishes its size.
    this.canvasViewportMeasured = true;
    if (preserveCenter) {
      this.viewportStore.viewOffsetX = nextOffsetX;
      this.viewportStore.viewOffsetY = nextOffsetY;
      viewService.setViewOffset(nextOffsetX, nextOffsetY);
    }
    if (this.aiGeneratedFitAction !== null) this.aiGeneratedFitAction();
  }

  private clampZoom(value: number): number {
    if (!Number.isFinite(value)) {
      return Math.max(MIN_ZOOM_PERCENT, Math.min(MAX_ZOOM_PERCENT, this.viewportStore.zoomPercent));
    }
    const clamped: number = Math.max(MIN_ZOOM_PERCENT, Math.min(MAX_ZOOM_PERCENT, value));
    const precision: number = clamped < 0.01 ? 1000000 : 10000;
    return Math.round(clamped * precision) / precision;
  }

  private removeSelectedShape(): void {
    if (!this.assertEditMode()) {
      return;
    }
    this.finishNudgeTransaction();
    const selected: Shape[] = editService.getSelectedShapes();
    const ids: number[] = [];
    for (let i = 0; i < selected.length; i++) {
      ids.push(selected[i].id);
    }
    if (ids.length === 0 && this.viewportStore.selectedShapeId >= 0) {
      ids.push(this.viewportStore.selectedShapeId);
    }
    if (ids.length === 0) {
      this.panelStore.statusText = '未选中图形，无法删除';
      return;
    }

    let deletedIds: number[] = [];
    try {
      deletedIds = editService.deleteShapesWithSelectionHistory(ids);
    } catch (error) {
      this.syncShapesFromEditService();
      const message: string = error instanceof Error ? error.message : String(error);
      this.panelStore.statusText = `删除未完成：${message}`;
      return;
    }
    this.syncShapesFromEditService();
    const deletedCount: number = deletedIds.length;
    if (deletedCount === 0) {
      const remainingCurrentShapes: Shape[] = editService.getCurrentCellShapes();
      if (remainingCurrentShapes.length > 0) {
        this.viewportStore.selectedShapeId = remainingCurrentShapes[0].id;
        this.viewportStore.selectedLayerNumber = remainingCurrentShapes[0].layerNumber;
          this.viewportStore.selectedDatatype = remainingCurrentShapes[0].datatype;
        editService.selectShape(this.viewportStore.selectedShapeId);
      } else {
        this.viewportStore.selectedShapeId = -1;
        editService.clearSelection();
      }

      this.viewportStore.selectedShapeCount = editService.getSelectedIds().length;

    }
    const skippedCount: number = ids.length - deletedCount;
    this.panelStore.statusText = deletedCount > 0 ? `已删除 ${deletedCount} 个图形${skippedCount > 0 ? `；跳过 ${skippedCount} 个锁定或不可编辑图形` : ''}` : '删除未完成：选中图形锁定、不可编辑或已不存在';
    if (deletedCount > 0) {
      showAppSnackBar(this.getUIContext(), `已删除 ${deletedCount} 个图形`, {
        icon: $r('sys.symbol.trash'),
        duration: AppToastDuration.LONG,
        actionText: '撤销',
        onAction: () => { this.undoEdit(); }
      });
    }
    if (deletedCount > 0 && macroService.isRecording()) {
      this.recordMacroStep(`删除 ${deletedCount} 个图形`, `delete_shapes|${deletedIds.join(',')}`);
    }
  }

  private runDrc(preserveWorkspaceModule: boolean = false): void {
    if (!preserveWorkspaceModule) {
      this.verifyStore.drcDockCollapsed = false;
      // 使用当前规则集；完整性提示不等同于几何违规。
      this.viewportStore.currentModule = WorkModule.Verify;
    }
    this.panelStore.statusText = '正在运行 DRC 检查...';
    try {
      if (!this.synchronizeCurrentDocument()) throw new Error(this.panelStore.statusText);
      const nativeEligible: boolean = true;
      const result = drcService.runDrc(
        editService.getCurrentCellShapes(),
        (percent: number, msg: string) => {
          this.panelStore.statusText = `DRC ${percent}%: ${msg}`;
        },
        nativeEligible,
        editService.getCurrentCellId(),
        -1,
        cleanDbuNm(this.docStore.docPhysicalUnits)
      );
      this.verifyStore.drcIssues = this.convertViolationsToIssues(result.violations);
      if (preserveWorkspaceModule && result.violations.length > 0) {
        this.verifyStore.drcDockCollapsed = false;
        this.viewportStore.currentModule = WorkModule.Verify;
      }
      this.verifyStore.highlightedViolationId = -1;
      this.verifyStore.highlightedViolation = null;
      this.verifyStore.lastDrcElapsed = result.elapsed;
      this.verifyStore.drcHasRun = true;
      this.drcSnapshotRevision = this.docStore.editorRevision;
      this.drcRdbResult = result; this.drcRdbDocument = this.docStore.activeWorkspaceId;
      this.drcRdbInputVersion = editService.getSessionRevision(); this.drcRdbOwnerCell = editService.getCurrentCellId();
      this.drcRdbCellName = this.cellName(this.drcRdbOwnerCell);
      this.publishFormSnapshot();
      // 口径必须可见：本次到底展开了几层、有多少规则退回到未展开的 ArkTS 补检
      const depthApplied: number = result.hierarchyDepthApplied;
      const fallbackRules: number = result.arkFallbackRules;
      const summary: string = this.aiDrcResultSummary();
      this.panelStore.statusText = `${summary} (用时 ${result.elapsed}ms)`
        + ` · 层级${depthApplied >= 1 ? depthApplied : '未展开'}`
        + (fallbackRules > 0 ? ` · ${fallbackRules} 条规则未展开` : '');
      if (!preserveWorkspaceModule || result.violations.length > 0) {
        showAppSnackBar(this.getUIContext(), summary, { icon: $r('sys.symbol.checkmark_circle'), duration: AppToastDuration.NORMAL });
      }
    } catch (e) {
      // INDEX-13: DRC 异常时复位状态并提示，避免界面卡在"正在运行..."
      this.verifyStore.highlightedViolationId = -1;
      this.verifyStore.highlightedViolation = null;
      this.verifyStore.lastDrcElapsed = 0;
      this.verifyStore.drcHasRun = false;
      this.drcSnapshotRevision = -1;
      this.verifyStore.drcIssues = [];
      this.panelStore.statusText = `DRC 检查失败: ${e instanceof Error ? e.message : String(e)}`;
      this.publishFormSnapshot();
    }
  }

  private canExportDrcRdb(): boolean {
    return this.pageAlive && this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision &&
      this.drcRdbResult !== null && this.drcRdbResult === drcService.getLastResult() &&
      this.drcRdbDocument === this.docStore.activeWorkspaceId && this.drcRdbInputVersion === editService.getSessionRevision() &&
      this.drcRdbOwnerCell === editService.getCurrentCellId() && this.drcRdbCellName.length > 0 &&
      this.drcRdbCellName === this.cellName(this.drcRdbOwnerCell);
  }

  private async exportDrcRdb(): Promise<void> {
    if (this.verifyStore.drcRdbExportBusy) return;
    if (!this.canExportDrcRdb()) { this.panelStore.statusText = '当前 DRC 报告来源已变化，请重新检查后导出'; return; }
    const result: DrcResult = this.drcRdbResult!;
    const documentId: string = this.docStore.activeWorkspaceId;
    const revision: number = this.docStore.editorRevision;
    const generation: number = this.pageGeneration;
    const sourceFile: string = this.docStore.currentFilePath;
    const cell: string = this.drcRdbCellName;
    const canPublish: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration &&
      documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision && sourceFile === this.docStore.currentFilePath &&
      result === this.drcRdbResult && cell === this.drcRdbCellName && this.canExportDrcRdb();
    this.verifyStore.drcRdbExportBusy = true;
    try {
      const groups = drcService.getRuleGroups();
      const report: RdbViolationReport = { description: '鸿图当前 DRC 预检查报告', originalFile: sourceFile,
        generator: 'HongTu', cellName: cell, runNotice: `输入 ${documentId} / ${this.drcRdbInputVersion}；` +
          `规则 ${result.executedRules}/${result.totalRules}；层级 ${result.hierarchyDepthApplied}；` +
          `完整性提示 ${result.completenessNotices}；${groups === null ? '' : groups.scopeNote}；不是制造签核。`,
        violations: result.violations.map((v: DrcViolation): RdbViolation => ({ id: v.id, ruleId: v.ruleId, ruleName: v.ruleName,
          type: v.type, severity: v.severity, layerNumber: v.layerNumber, x: v.x, y: v.y, width: v.width, height: v.height,
          message: v.message, shapeIds: v.shapeIds.slice(), fromInstance: v.fromInstance })) };
      const converted: RdbReadResult = rdbService.fromViolations(report);
      if (!converted.ok || !converted.document) throw new Error(converted.message);
      const serialized: RdbWriteResult = rdbService.serialize(converted.document);
      if (!serialized.ok || serialized.xml === undefined) throw new Error(serialized.message);
      await engineeringFileService.saveText(this.getUIContext().getHostContext() as common.UIAbilityContext,
        'drc-report.lyrdb', serialized.xml, canPublish, 'KLayout 报告数据库|.lyrdb');
      if (canPublish()) this.panelStore.statusText = '标准 RDB 报告已导出';
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) this.panelStore.statusText = canPublish()
        ? `RDB 导出失败：${error instanceof Error ? error.message : String(error)}` : 'DRC 来源已变化，旧 RDB 报告未导出';
    } finally { this.verifyStore.drcRdbExportBusy = false; }
  }

  private convertViolationsToIssues(violations: DrcViolation[]): DrcIssue[] {
    const issues: DrcIssue[] = [];
    for (let i = 0; i < violations.length; i++) {
      const v = violations[i];
      // DRC.TRUNC / DRC.NOHIER 不是规则违例，而是"结果是否完整"的告警：
      // 必须显眼且不冒充几何违规，否则用户会把漏检当成干净
      const isCompletenessNotice: boolean =
        v.ruleId === 'DRC.TRUNC' || v.ruleId === 'DRC.NOHIER';
      issues.push(new DrcIssue(
        v.id,
        isCompletenessNotice ? 'warning' : v.severity,
        isCompletenessNotice ? `[结果不完整] ${v.ruleName}` : v.ruleName,
        this.layerNameOf(v.layerNumber),
        v.message,
        v.x,
        v.y,
        v.width,
        v.height,
        v.ruleId
      ));
    }
    return issues;
  }

  private layerNameOf(layerNumber: number): string {
    for (let i = 0; i < this.docStore.layers.length; i++) {
      if (this.docStore.layers[i].layerNumber === layerNumber) {
        return `L${layerNumber} ${this.docStore.layers[i].chineseName}`;
      }
    }
    return `L${layerNumber}`;
  }

  private locateIssue(issue: DrcIssue): void {
    this.verifyStore.highlightedViolationId = issue.id;
    this.viewportStore.currentModule = this.isDesktopWorkspace() ? WorkModule.Verify : WorkModule.Layout;
    // Keep the existing DRC marker dimensions; native markers may be threshold-based.
    const hw = issue.width > 0 ? issue.width : 80;
    const hh = issue.height > 0 ? issue.height : 80;
    const highlight: ViolationHighlight = {
      x: issue.x - hw / 2,
      y: issue.y - hh / 2,
      w: hw,
      h: hh,
    };
    this.focusWorldBounds({ minX: highlight.x, minY: highlight.y,
      maxX: highlight.x + highlight.w, maxY: highlight.y + highlight.h });
    this.verifyStore.highlightedViolation = highlight;
    this.panelStore.statusText = `定位违规: ${issue.ruleName} (已跳转至 ${issue.x.toFixed(0)}, ${issue.y.toFixed(0)})`;
  }

  private loadRecentFile(file: RecentFile): void {
    this.panelStore.showFilePanel = false;
    this.reopenRecentFile(file);
  }

  private importInProgress: boolean = false;
  private importWizardCancelled: boolean = false;
  private activeNativeJobScope: string = '';
  private nativeJobTimer: number = -1;
  private nativeJobSequence: number = 0;
  private pendingDrcContext: string = '';

  private onDrcConfigurationChanged(): void {
    drcService.invalidateResult();
    this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false; this.drcSnapshotRevision = -1;
    this.verifyStore.highlightedViolation = null; this.verifyStore.highlightedViolationId = -1; this.verifyStore.lastDrcElapsed = 0;
    this.publishFormSnapshot();
    if (this.docStore.activeNativeJobId.length > 0 && this.activeNativeJobScope.indexOf('-drc-') >= 0) {
      this.pendingDrcContext = `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`;
      this.cancelActiveNativeJob();
      this.panelStore.statusText = '规则配置已变化，旧结论已失效；等待旧检查停止后重新检查';
    } else this.panelStore.statusText = '规则配置已变化，旧结论已失效；正在准备重新检查';
    this.scheduleWorkspaceDraft();
  }

  private beginNativeJob(jobId: string, scope: string, kind: string, canContinue: () => boolean = (): boolean => true): void {
    if (this.nativeJobTimer >= 0) clearInterval(this.nativeJobTimer);
    this.docStore.activeNativeJobId = jobId; this.activeNativeJobScope = scope;
    AppStorage.setOrCreate<number>('collapsedLiveCapsuleInset', this.isDesktopWorkspace() ? 0 : 60);
    this.docStore.nativeJobCancelRequested = false; this.docStore.nativeJobProgress = -1; this.docStore.nativeJobLabel = `${kind} · 排队`;
    this.nativeJobTimer = setInterval(() => {
      if (this.docStore.activeNativeJobId !== jobId || this.activeNativeJobScope !== scope) return;
      if (!canContinue()) this.cancelActiveNativeJob();
      const progress = nativeHongTuService.getJobProgress(jobId, scope);
      if (progress === undefined) return;
      const stage: string = progress.stage === 'queued' ? '排队' : progress.stage === 'reading' ? '读取' : progress.stage === 'parsing' ? '解析' : progress.stage === 'resolving' ? '名称与引用' : progress.stage === 'budget' ? '资源预算' : progress.stage === 'indexing' ? '建立索引' : progress.stage === 'checking' ? '规则检查' : progress.stage === 'publishing' ? '生成结果' : progress.stage === 'decompressing' ? '解压' : progress.stage;
      const count: string = progress.total > 0 ? ` ${progress.completed}/${progress.total}` : '';
      this.docStore.nativeJobProgress = progress.total > 0 ? Math.min(100, Math.max(0, Math.round((progress.completed / progress.total) * 100))) : -1;
      this.docStore.nativeJobLabel = `${kind} · ${stage}${count}${progress.cancelRequested ? ' · 正在取消' : ''}`;
      this.docStore.nativeJobCancelRequested = progress.cancelRequested;
      if (progress.terminal === true && progress.workerStopped === true && progress.status !== 'running') this.finishNativeJob(jobId, scope);
    }, 200);
  }

  private finishNativeJob(jobId: string, scope: string): void {
    if (jobId !== this.docStore.activeNativeJobId || scope !== this.activeNativeJobScope) return;
    if (this.aiNativeCompare !== null && this.aiNativeCompare.jobId === jobId && this.aiNativeCompare.scope === scope) {
      this.aiNativeCompare.progress();
      if (this.aiNativeCompare.workerStopped()) {
        if (this.aiNativeComparePath.length > 0) engineeringFileService.removeTemporary(this.aiNativeComparePath);
        this.aiNativeComparePath = ''; this.aiNativeCompare = null;
      }
    }
    if (this.nativeJobTimer >= 0) clearInterval(this.nativeJobTimer);
    this.nativeJobTimer = -1; this.docStore.activeNativeJobId = ''; this.activeNativeJobScope = '';
    AppStorage.setOrCreate<number>('collapsedLiveCapsuleInset', 0);
    this.docStore.nativeJobLabel = ''; this.docStore.nativeJobProgress = -1; this.docStore.nativeJobCancelRequested = false;
  }

  private cancelActiveNativeJob(): void {
    if (this.docStore.activeNativeJobId.length === 0 || this.docStore.nativeJobCancelRequested) return;
    if (nativeHongTuService.cancelJob(this.docStore.activeNativeJobId, this.activeNativeJobScope)) {
      this.docStore.nativeJobCancelRequested = true; this.docStore.nativeJobLabel += ' · 正在取消';
    } else this.panelStore.statusText = '作业已完成或取消请求未接受，请等待结果';
  }

  private async parseImportJob(path: string, quickScan: boolean = false, canContinue: () => boolean = (): boolean => true): Promise<GdsiiResult> {
    if (!this.pageAlive) throw new Error('页面已退出，未启动解析');
    if (!canContinue()) throw new Error('解析请求已过期，未启动解析');
    const generation: number = this.pageGeneration;
    const lower: string = path.toLowerCase();
    if (this.docStore.activeNativeJobId.length > 0) throw new Error('已有后台作业，请完成或取消后重试');
    const textLayout: boolean = lower.endsWith('.cif') || lower.endsWith('.dxf');
    const effectiveQuickScan: boolean = quickScan && !textLayout;
    const scope: string = `${this.docStore.activeWorkspaceId}-import-${Date.now()}-${++this.nativeJobSequence}`;
    // Scans and full imports stay detached until the caller validates and activates the result.
    const job = nativeHongTuService.startParseJob(path, { scope, isOasis: lower.endsWith('.oas') || lower.endsWith('.oasis'), quickScan: effectiveQuickScan, publishToActive: false });
    if (job === null) throw new Error('后台解析作业启动失败');
    this.beginNativeJob(job.jobId, job.scope, quickScan ? (textLayout ? '扫描（完整解析）' : '扫描') : '导入', canContinue);
    let workerStopped: boolean = false;
    try {
      const output = await job.completion;
      if (output.jobId !== job.jobId || output.scope !== job.scope || output.terminal !== true || output.workerStopped !== true) throw new Error('解析作业未确认停止，结果未应用');
      workerStopped = true;
      if (!this.pageAlive || generation !== this.pageGeneration) throw new Error('页面已改变，解析结果未应用');
      if (!canContinue()) throw new Error('解析请求已过期，结果未应用');
      if (output.status !== 'succeeded' || output.result === undefined || !output.result.success) throw new Error(output.message || '导入未完成');
      const budget: NativeImportEstimate | undefined = output.budget;
      if (budget !== undefined) {
        this.docStore.wizardStoredShapes = budget.storedShapes; this.docStore.wizardCoordinateCount = budget.coordinates;
        this.docStore.wizardExpandedPlacements = budget.expandedPlacements; this.docStore.wizardGeometryBytes = budget.geometryBytes;
        this.docStore.wizardBudgetMessage = budget.message;
      }
      return output.result;
    } finally {
      const progress = nativeHongTuService.getJobProgress(job.jobId, job.scope);
      if (workerStopped || (progress?.terminal === true && progress.workerStopped === true && progress.status !== 'running')) this.finishNativeJob(job.jobId, job.scope);
      else nativeHongTuService.cancelJob(job.jobId, job.scope);
    }
  }

  private async runDrcBackground(): Promise<void> {
    if (!this.pageAlive) return;
    const pageGeneration: number = this.pageGeneration;
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) {
      this.panelStore.statusText = this.pendingDrcContext.length > 0 ? '旧检查正在停止，随后按当前配置重新检查' : '已有后台作业，请完成或取消后重试'; return;
    }
    const documentId: string = this.docStore.activeWorkspaceId;
    const inputVersion: number = editService.getSessionRevision();
    const ownerCellId: number = editService.getCurrentCellId();
    const ruleIdentity: string = JSON.stringify(drcService.getRules()) + drcService.ruleSourceText() + technologyService.serialize();
    const requestedDepth: number = drcService.hierarchyDepth;
    const requestedFilter: string = drcService.ruleFilter;
    const requestedTiling: boolean = drcService.tilingEnabled;
    const requestedTileSize: number = drcService.tileSize;
    const rawEditShapes: Shape[] = editService.getShapes();
    const packedDrc = packShapesCoordinates(rawEditShapes, 8192);
    const usePackedDrc: boolean = packedDrc.packedCoords !== undefined;
    const emptyDrcPts: Point[] = [];
    const shapes: NativeRenderShape[] = rawEditShapes.map((s: Shape): NativeRenderShape => ({
      id: s.id, type: s.type, layerNumber: s.layerNumber, datatype: s.datatype,
      points: usePackedDrc ? emptyDrcPts : s.points.map((p: Point): Point => ({ x: p.x, y: p.y })), ownerCellId: s.ownerCellId,
      cellId: s.cellId, cellName: s.cellName, rotation: s.rotation, mirror: s.mirror, magnification: s.magnification,
      pathWidth: s.pathWidth, pathType: s.pathType, pathBeginExtension: s.pathBeginExtension,
      pathEndExtension: s.pathEndExtension, pathWidthAbsolute: s.pathWidthAbsolute, text: s.text,
      arrayCols: s.arrayCols, arrayRows: s.arrayRows, arrayColStepX: s.arrayColStepX,
      arrayColStepY: s.arrayColStepY, arrayRowStepX: s.arrayRowStepX, arrayRowStepY: s.arrayRowStepY }));
    const snapshot: NativeRenderSnapshot = { cellNames: this.propertyCellOptions().map((c: PropertyCellOption): string => c.name),
      topCellId: editService.getTopCellId(), shapes,
      packedCoords: packedDrc.packedCoords,
      shapePointOffsets: packedDrc.shapePointOffsets,
      shapePointCounts: packedDrc.shapePointCounts };
    const scope: string = `${documentId}-drc-${Date.now()}-${++this.nativeJobSequence}`;
    const job = drcService.startDrcJob(snapshot, { scope, documentId, inputVersion, ownerCellId,
      hierarchyDepth: drcService.hierarchyDepth, mergeSameLayer: false });
    if (job === null) { this.panelStore.statusText = '后台 DRC 启动失败，上次结果保留'; return; }
    this.viewportStore.currentModule = WorkModule.Verify; this.verifyStore.drcDockCollapsed = false;
    this.beginNativeJob(job.jobId, job.scope, `DRC · ${this.cellName(ownerCellId)} · 版本${inputVersion}`);
    try {
      const output = await job.completion;
      if (!this.pageAlive || pageGeneration !== this.pageGeneration) return;
      if (output.status !== 'succeeded' || output.result === undefined) { this.panelStore.statusText = `${output.message}；${this.verifyStore.drcHasRun ? '上次有效结果保留' : '当前检查未完成'}`; return; }
      if (documentId !== this.docStore.activeWorkspaceId || inputVersion !== editService.getSessionRevision() || ownerCellId !== editService.getCurrentCellId() || requestedDepth !== drcService.hierarchyDepth || requestedFilter !== drcService.ruleFilter || requestedTiling !== drcService.tilingEnabled || requestedTileSize !== drcService.tileSize || ruleIdentity !== JSON.stringify(drcService.getRules()) + drcService.ruleSourceText() + technologyService.serialize()) {
        this.panelStore.statusText = `DRC 来源为 ${documentId} 版本${inputVersion}；当前文档已变化，结果未应用`; return;
      }
      drcService.acceptBackgroundResult(output);
      this.verifyStore.drcIssues = this.convertViolationsToIssues(output.result.violations);
      this.verifyStore.highlightedViolationId = -1; this.verifyStore.highlightedViolation = null;
      this.verifyStore.lastDrcElapsed = output.result.elapsed; this.verifyStore.drcHasRun = true; this.drcSnapshotRevision = this.docStore.editorRevision;
      this.drcRdbResult = output.result; this.drcRdbDocument = documentId; this.drcRdbInputVersion = inputVersion;
      this.drcRdbOwnerCell = ownerCellId; this.drcRdbCellName = this.cellName(ownerCellId);
      this.publishFormSnapshot();
      this.panelStore.statusText = `${this.aiDrcResultSummary()} · ${output.scopeText} · 版本${inputVersion} · ${output.result.elapsed}ms`;
    } catch (error) {
      if (this.pageAlive && pageGeneration === this.pageGeneration) this.panelStore.statusText = `DRC 后台检查失败：${String(error)}；上次结果保留`;
    }
    finally {
      this.finishNativeJob(job.jobId, job.scope);
      const pending: string = this.pendingDrcContext;
      this.pendingDrcContext = '';
      if (this.pageAlive && pageGeneration === this.pageGeneration && pending === `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${editService.getCurrentCellId()}`) this.runDrcBackground();
    }
  }

  private cancelImportWizard(): void {
    this.importWizardCancelled = true;
    this.resolveWizard(ViewMode.VIEWER);
  }

  private finishLayoutImport(): void {
    try { this.synchronizeCurrentDocument(); }
    catch (error) {
      this.setNativeSnapshotCurrent(false);
      this.panelStore.statusText += `；当前版图同步失败：${String(error)}`;
    } finally {
      this.importInProgress = false;
      this.importWizardCancelled = false;
    }
  }

  private async reopenRecentFile(file: RecentFile): Promise<void> {
    if (!this.pageAlive) return;
    const generation: number = this.pageGeneration, documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
    const isCurrent: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision;
    if (this.importInProgress) { this.panelStore.statusText = '已有版图正在打开，请等待完成或取消'; return; }
    if (file.sandboxPath.length === 0) { this.panelStore.statusText = `最近文件无法重新打开：${file.name}`; return; }
    if (!this.canOpenWorkspaceDocument()) return;
    this.importInProgress = true;
    this.setNativeSnapshotCurrent(false);
    try {
      this.panelStore.statusText = `正在打开最近文件：${file.name}`;
      const quickInfo: GdsiiResult = await this.parseImportJob(file.sandboxPath, true, isCurrent);
      if (!isCurrent()) return;
      if (!quickInfo.success) throw new Error(quickInfo.errorMessage || '快速扫描失败');
      const parseResult: GdsiiResult = await this.parseImportJob(file.sandboxPath, false, isCurrent);
      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;
      const imported = new ImportedLayoutResult(file.sourceUri, file.sandboxPath, quickInfo, parseResult);
      await this.applyParsedResult(imported, ViewMode.EDIT, isCurrent);
      this.rememberRecentFile(imported);
      this.viewportStore.currentModule = WorkModule.Layout;
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) this.panelStore.statusText = `最近文件打开失败：${error}`;
    } finally { if (this.pageAlive && generation === this.pageGeneration) this.finishLayoutImport(); }
  }

  private async pickAndParseFile(): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (!this.pageAlive) return;
    const generation: number = this.pageGeneration, documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
    const isCurrent: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision;
    if (this.importInProgress) { this.panelStore.statusText = '已有版图正在打开，请等待完成或取消'; return; }
    if (!this.canOpenWorkspaceDocument()) return;
    this.importInProgress = true;
    this.importWizardCancelled = false;
    this.setNativeSnapshotCurrent(false);
    let sandboxPath: string = '';
    let keepImportedFile: boolean = false;
    try {
      this.panelStore.statusText = '正在打开系统文件选择器...';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.docStore.wizardStoredShapes = -1; this.docStore.wizardCoordinateCount = -1; this.docStore.wizardExpandedPlacements = -1;
      this.docStore.wizardGeometryBytes = -1; this.docStore.wizardBudgetMessage = '';
      const picked: PickedLayout = await fileImportService.pickAndScan(context, (path: string): Promise<GdsiiResult> => {
        if (!isCurrent()) throw new Error('打开请求已过期，未启动扫描');
        return this.parseImportJob(path, true, isCurrent);
      });
      sandboxPath = picked.sandboxPath;
      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;

      const fileSize: number = picked.quickInfo.fileSize;
      let mode: ViewMode = ViewMode.EDIT;
      if (fileSize >= LARGE_FILE_THRESHOLD_BYTES) {
        const fileName: string = this.fileNameFromPath(this.stripUriQuery(picked.sourceUri));
        mode = await this.promptOpenWizard(fileSize, fileName);
        if (this.importWizardCancelled) throw new Error('已取消打开版图');
      }

      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;
      this.panelStore.statusText = '正在解析版图...';
      const parseResult: GdsiiResult = await this.parseImportJob(sandboxPath, false, isCurrent);
      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;
      const imported = new ImportedLayoutResult(picked.sourceUri, sandboxPath, picked.quickInfo, parseResult);
      await this.applyParsedResult(imported, mode, isCurrent);
      keepImportedFile = true;
      this.rememberRecentFile(imported);
      this.viewportStore.currentModule = WorkModule.Layout;
      this.panelStore.statusText = mode === ViewMode.VIEWER
        ? `已以查看模式打开（${formatFileSize(fileSize)}，只读；与编辑模式使用相同解析器）`
        : `已打开：${this.displayNameForImported(imported)}`;
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) this.panelStore.statusText = `打开/解析失败: ${error}`;
    } finally {
      try { if (!keepImportedFile) fileImportService.cleanup(sandboxPath); }
      finally { if (this.pageAlive && generation === this.pageGeneration) this.finishLayoutImport(); }
    }
  }

  /**
   * 打开类操作前未保存确认（两轮对话框，因 Alert 仅两按钮）：
   * 1) 取消 | 选择如何处理
   * 2) 丢弃并继续 | 保存并继续
   * resolve true = 可继续；false = 取消或保存失败/用户取消选择器。
   */
  private confirmUnsavedBeforeOpen(actionLabel: string): Promise<boolean> {
    const documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
    const pythonContext: string = JSON.stringify(this.localPythonDraft ?? null);
    const isCurrent: () => boolean = (): boolean => documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision &&
      pythonContext === JSON.stringify(this.localPythonDraft ?? null);
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      this.canvasFocusReturnTicket++;
      AlertDialog.show({ cornerRadius: UI.dialogRadius,
        title: '未保存的修改',
        message: `${this.localPythonDraftDirty ? '当前工程脚本或版图' : '当前版图'}有未保存修改。${actionLabel}前：`,
        primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted,
          value: '取消',
          action: () => {
            resolve(false);
          }
        },
        secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary,
          value: '选择如何处理',
          action: () => {
            if (!isCurrent()) { resolve(false); return; }
            this.canvasFocusReturnTicket++;
            AlertDialog.show({ cornerRadius: UI.dialogRadius,
              title: '如何处理未保存修改？',
              message: this.localPythonDraftDirty ? '「保存并继续」将保存含当前脚本的鸿图工程；「丢弃并继续」将丢失当前修改。' :
                '「保存并继续」将先弹出保存对话框；「丢弃并继续」将丢失当前修改。',
              primaryButton: { fontColor: COLORS.danger, backgroundColor: COLORS.dangerSoft,
                value: '丢弃并继续',
                action: () => {
                  if (!isCurrent()) { resolve(false); return; }
                  resolve(true);
                }
              },
              secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary,
                value: '保存并继续',
                action: () => {
                  if (!isCurrent()) { resolve(false); return; }
                  const saving: Promise<void> = this.localPythonDraftDirty ? this.saveProject() : this.saveCurrentLayout();
                  saving.then(() => {
                    resolve(isCurrent() && !editService.isDirty() && !this.docStore.documentDirty && !this.localPythonDraftDirty);
                  }).catch(() => {
                    resolve(false);
                  });
                }
              }
            });
          }
        }
      });
    });
  }

  /** 系统返回键：有未保存修改时拦截 */
  private exitWorkspaceDraftContext(): string {
    if (!this.pageAlive || !this.docStore.workspaceReady) return '';
    try {
      return JSON.stringify({ generation: this.pageGeneration, editorRevision: this.docStore.editorRevision,
        dirty: editService.isDirty(), documentDirty: this.docStore.documentDirty,
        content: this.projectSaveContext() });
    } catch (_) { return ''; }
  }

  private dismissTopFloatingPanelOnBack(): boolean {
    if (this.verifyStore.engineeringRestorePreview !== undefined) {
      if (!this.verifyStore.engineeringRestoreBusy) {
        this.cancelEngineeringReviewRestore(this.verifyStore.engineeringRestorePreview.token);
        this.restoreCanvasFocusAfterPanelClose();
      }
      return true;
    }
    if (this.panelStore.showRdbReviewPanel) {
      if (this.rdbReviewDraftDirty) {
        this.verifyStore.rdbReviewStatus = '请先保存审阅或取消尚未提交的编辑';
        return true;
      }
      this.closeRdbReview();
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showLayerStackPanel) {
      this.panelStore.showLayerStackPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showVerificationPanel) {
      this.panelStore.showVerificationPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showTechnologyPanel) {
      this.panelStore.showTechnologyPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showComparePanel) {
      this.panelStore.showComparePanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showViewWorkspacePanel) {
      this.closeViewWorkspace();
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showPythonPanel) {
      this.closeAssistantPanel('python');
      return true;
    }
    if (this.panelStore.showAiPanel) {
      this.closeAssistantPanel('ai');
      return true;
    }
    if (this.panelStore.showLibraryPanel) {
      this.panelStore.showLibraryPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showSearchPanel) {
      this.panelStore.showSearchPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showProjectPanel) {
      this.panelStore.showProjectPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showLayerStylePanel) {
      this.panelStore.showLayerStylePanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showShortcutPanel) {
      this.panelStore.showShortcutPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showFilePanel) {
      this.panelStore.showFilePanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.panelStore.showMacroPanel) {
      this.panelStore.showMacroPanel = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    if (this.verifyStore.showDrcRules) {
      this.verifyStore.showDrcRules = false;
      this.restoreCanvasFocusAfterPanelClose();
      return true;
    }
    return false;
  }

  onBackPress(): boolean | void {
    if (this.dismissTopFloatingPanelOnBack()) {
      return true;
    }
    if (this.rdbReviewDraftDirty) {
      this.panelStore.showRdbReviewPanel = true; this.verifyStore.rdbReviewStatus = '请先保存审阅或取消尚未提交的编辑'; return true;
    }
    if (!editService.isDirty() && !this.docStore.documentDirty && !this.localPythonDraftDirty) return false;
    const key: string = this.exitWorkspaceDraftContext();
    if (key.length === 0) { this.panelStore.statusText = '草稿状态暂不可确认，请稍后重试退出'; return true; }
    if (this.exitDraftKey !== key) {
      this.canvasFocusReturnTicket++;
      AlertDialog.show({ cornerRadius: UI.dialogRadius,
        title: '未保存的修改',
        message: '退出前有未保存的版图修改。可以保留自动草稿后退出，下次启动继续恢复。',
        primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted,
          value: '取消',
          action: () => {}
        },
        secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary,
          value: '保留草稿后退出',
          action: () => {
            if (key !== this.exitWorkspaceDraftContext()) return;
            const saving: Promise<boolean> = this.saveWorkspaceDraft();
            // saveWorkspaceDraft captures synchronously and may refresh the bundle.
            // Acknowledgement belongs to that captured state, including script edits.
            const snapshotKey: string = this.exitWorkspaceDraftContext();
            saving.then((saved: boolean) => {
              if (saved && snapshotKey.length > 0 && snapshotKey === this.exitWorkspaceDraftContext()) {
                this.exitDraftKey = snapshotKey; this.panelStore.statusText = '草稿已保留，请再按一次返回退出';
              }
            }).catch(() => {});
          }
        }
      });
      return true; // 拦截本次返回
    }
    return false;
  }

  /**
   * 大版图打开向导：返回一个 Promise，在用户点击"查看模式"或"编辑模式"按钮后 resolve。
   * 解决 KLayout 痛点："大版图打开向导"——把 viewer/非编辑/编辑模式的差异与内存影响前置给用户。
   */
  private promptOpenWizard(fileSize: number, fileName: string): Promise<ViewMode> {
    return new Promise<ViewMode>((resolve: (mode: ViewMode) => void) => {
      this.docStore.wizardFileSize = fileSize;
      this.docStore.wizardFileName = fileName.length > 0 ? fileName : '大版图文件';
      this.pendingWizardResolve = resolve;
      this.openCanvasDialog(this.openWizardController);
    });
  }

  private resolveWizard(mode: ViewMode): void {
    if (this.pendingWizardResolve !== null) {
      this.pendingWizardResolve(mode);
      this.pendingWizardResolve = null;
    }
  }

  /** 切换视图模式（查看 / 编辑），对应 KLayout viewer/editor 模式分离 */
  private setViewMode(mode: ViewMode): void {
    const nextStatus: string = mode === ViewMode.VIEWER
      ? '已切换到查看模式（只读，不可创建/删除/修改图形）'
      : '已切换到编辑模式';
    if (this.viewportStore.currentViewMode === mode) {
      this.panelStore.statusText = nextStatus;
      return;
    }
    if (mode === ViewMode.VIEWER) {
      this.exitStampSession();
      this.viewportStore.interactiveCurveKind = '';
      if (
        this.viewportStore.currentTool !== ActiveTool.Select &&
        this.viewportStore.currentTool !== ActiveTool.Pan &&
        this.viewportStore.currentTool !== ActiveTool.Measure &&
        this.viewportStore.currentTool !== ActiveTool.BoxZoom
      ) {
        this.viewportStore.currentTool = ActiveTool.Select;
      }
    }
    try {
      this.getUIContext().animateTo({ duration: motionDuration(MOTION.panel), curve: feedbackCurve() }, () => {
        this.viewportStore.currentViewMode = mode;
        this.panelStore.statusText = nextStatus;
      });
    } catch (_err) {
      this.viewportStore.currentViewMode = mode;
      this.panelStore.statusText = nextStatus;
    }
  }

  /** 编辑模式守卫：查看模式下拦截所有改库操作并提示 */
  private assertEditMode(): boolean {
    if (!this.docStore.workspaceReady) { this.panelStore.statusText = '正在恢复工作区，请稍候再编辑'; return false; }
    if (this.viewportStore.currentViewMode === ViewMode.VIEWER) {
      this.panelStore.statusText = '查看模式不可编辑，请先切换到编辑模式';
      return false;
    }
    return true;
  }

  private rememberRecentFile(imported: ImportedLayoutResult): void {
    const parsed: GdsiiResult = imported.parseResult;
    this.formFileSizes.set(this.docStore.activeWorkspaceId, parsed.fileSize);
    this.publishFormSnapshot();
    const nextFile = new RecentFile(
      this.displayNameForImported(imported),
      formatFileSize(parsed.fileSize),
      this.fileTypeForPath(imported.sandboxPath.length > 0 ? imported.sandboxPath : imported.sourceUri),
      imported.sourceUri,
      imported.sandboxPath,
      Date.now()
    );
    this.publishRecentFile(nextFile);
  }

  /** 收集当前所有受保护的沙箱导入路径（recentFiles + 当前活动文档 + 全部工作区打开标签）并异步回收孤儿 hongtu-import-* 大文件 */
  private schedulePruneImportCache(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const retained: string[] = [];
      for (let i = 0; i < this.docStore.recentFiles.length; i++) {
        const p: string = this.docStore.recentFiles[i].sandboxPath;
        if (p.length > 0) retained.push(p);
      }
      if (this.docStore.currentFilePath.length > 0) {
        retained.push(this.docStore.currentFilePath);
      }
      this.workspaceDocuments.forEach((doc: WorkspaceDocument) => {
        if (doc.sourcePath.length > 0) retained.push(doc.sourcePath);
      });
      fileImportService.pruneUnreferencedImports(context.filesDir, retained).catch(() => {});
    } catch (_) {}
  }

  private publishRecentFile(nextFile: RecentFile): void {
    const nextFiles: RecentFile[] = [nextFile];
    for (let i = 0; i < this.docStore.recentFiles.length; i++) {
      const oldFile = this.docStore.recentFiles[i];
      if (!this.isSameRecentFile(oldFile, nextFile)) {
        nextFiles.push(oldFile);
      }
      if (nextFiles.length >= MAX_RECENT_FILES) {
        break;
      }
    }
    this.docStore.recentFiles = nextFiles;
    this.persistRecentFiles();
    this.schedulePruneImportCache();
  }

  private async rememberSavedFile(context: common.UIAbilityContext, result: LayoutExportResult): Promise<string> {
    const saved: RecentFile = new RecentFile(result.fileName, formatFileSize(result.bytes),
      'GDSII', result.uri, '', Date.now());
    this.docStore.recentFiles = this.docStore.recentFiles.filter((file: RecentFile): boolean => !this.isSameRecentFile(file, saved));
    this.persistRecentFiles();
    try {
      saved.sandboxPath = await fileImportService.cacheSourceFile(context, result.uri, result.bytes);
      this.publishRecentFile(saved);
      return '';
    } catch (error) {
      this.schedulePruneImportCache();
      return `；文件已保存，最近文件缓存更新失败，请从文件选择器重新打开：${String(error)}`;
    }
  }

  private isSameRecentFile(left: RecentFile, right: RecentFile): boolean {
    if (left.sourceUri.length > 0 && right.sourceUri.length > 0 && left.sourceUri === right.sourceUri) {
      return true;
    }
    if (left.sandboxPath.length > 0 && right.sandboxPath.length > 0 && left.sandboxPath === right.sandboxPath) {
      return true;
    }
    return false;
  }

  private loadPersistedRecentFiles(): RecentFile[] {
    try {
      PersistentStorage.persistProp(RECENT_FILES_STORAGE_KEY, JSON.stringify([]));
      const raw: string = AppStorage.get<string>(RECENT_FILES_STORAGE_KEY) ?? '[]';
      const records: RecentFileRecord[] = JSON.parse(raw) as RecentFileRecord[];
      const files: RecentFile[] = [];
      for (let i = 0; i < records.length; i++) {
        const record = records[i];
        if (record && record.name && record.sandboxPath) {
          files.push(new RecentFile(
            record.name,
            record.fileSizeLabel || '',
            this.fileTypeForPath(record.sandboxPath || record.sourceUri || record.name),
            record.sourceUri || '',
            record.sandboxPath,
            record.openedAt || 0
          ));
        }
      }
      return files;
    } catch (error) {
      return createRecentFiles();
    }
  }

  private persistRecentFiles(): void {
    try {
      const records: RecentFileRecord[] = [];
      for (let i = 0; i < this.docStore.recentFiles.length; i++) {
        const file = this.docStore.recentFiles[i];
        records.push({
          name: file.name,
          fileSizeLabel: file.fileSizeLabel,
          fileType: file.fileType,
          sourceUri: file.sourceUri,
          sandboxPath: file.sandboxPath,
          openedAt: file.openedAt,
        });
      }
      AppStorage.setOrCreate<string>(RECENT_FILES_STORAGE_KEY, JSON.stringify(records));
    } catch (error) {
      // Recent files are a convenience feature; parsing should remain usable if persistence fails.
    }
  }

  private displayNameForImported(imported: ImportedLayoutResult): string {
    const sourceName: string = this.fileNameFromPath(this.stripUriQuery(imported.sourceUri));
    if (sourceName.length > 0) {
      try {
        return decodeURIComponent(sourceName);
      } catch (error) {
        return sourceName;
      }
    }
    const sandboxName: string = this.fileNameFromPath(imported.sandboxPath);
    if (sandboxName.length > 0) {
      return sandboxName;
    }
    const libName: string = imported.parseResult.libName;
    return libName.length > 0 ? libName : 'layout.gds';
  }

  private stripUriQuery(uri: string): string {
    const queryIndex: number = uri.indexOf('?');
    if (queryIndex >= 0) {
      return uri.substring(0, queryIndex);
    }
    return uri;
  }

  private fileTypeForPath(path: string): string {
    return layoutFileTypeForPath(path);
  }

  private async applyParsedResult(
    imported: ImportedLayoutResult,
    mode: ViewMode = ViewMode.EDIT,
    canContinue?: () => boolean
  ): Promise<void> {
    const parsed: GdsiiResult = imported.parseResult;
    if (!parsed.success) throw new Error(parsed.errorMessage || '版图解析失败，当前文档保留');
    if (!this.canOpenWorkspaceDocument()) throw new Error('无法打开更多版图，当前文档保留');
    this.panelStore.statusText = '正在流式构建版图几何模型...';
    const importedShapes: Shape[] = await nativeResultToShapesAsync(parsed, true, canContinue);
    if (canContinue !== undefined && !canContinue()) throw new Error('打开请求已过期，当前文档保留');
    const topCellId: number = parsed.primaryTopCellId >= 0 && parsed.primaryTopCellId < parsed.cells.length
      ? parsed.primaryTopCellId : 0;
    const cellNames: string[] = parsed.cells.map((cell): string => cell.name);
    const candidate: WorkspaceDocument = {
      version: 2, id: workspaceService.newId(), title: this.displayNameForImported(imported),
      sourcePath: imported.sandboxPath, saveUri: '', projectUri: '', libName: parsed.libName || 'UNKNOWN_LIB',
      topCellName: cellNames[topCellId] ?? 'TOP', topCellId: topCellId, cellNames: cellNames,
      cellProperties: parsed.cells.map((cell): LayoutPropRecord[] => cell.properties ?? []),
      cellKeys: parsed.cellKeys, ports: parsed.ports, crossSections: parsed.crossSections,
      layoutContextRecords: parsed.layoutContextRecords, cellContextRecords: parsed.cellContextRecords,
      libProperties: parsed.libProperties ?? [], layerDefinitions: parsed.layerDefinitions ?? [], shapes: importedShapes, layers: this.layersFromResult(parsed),
      userUnits: parsed.userUnits > 0 ? parsed.userUnits : 0.001,
      physicalUnits: parsed.physicalUnits > 0 ? parsed.physicalUnits : 1e-9,
      dirty: false, viewMode: mode, cellStack: [topCellId], selectedIds: [], zoom: 100,
      offsetX: 0, offsetY: 0, hierarchyDepth: 2, gridSize: 1, rulers: [], pcells: [], technologyId: '',
      revision: 0, updatedAt: Date.now()
    };
    const document: WorkspaceDocument = workspaceService.adoptValidatedDocument(candidate);
    // Validation and native activation finish before publishing a new document or source association.
    this.captureWorkspaceDocument();
    this.activateWorkspaceDocument(document, true, true);
    this.workspaceDocuments.set(document.id, document);
    const firstDrawable: Shape | undefined = importedShapes.find((shape: Shape) =>
      shape.type !== ShapeType.NODE && shape.type !== ShapeType.INSTANCE);
    this.viewportStore.selectedLayerNumber = firstDrawable !== undefined ? firstDrawable.layerNumber :
      (this.docStore.layers.length > 0 ? this.docStore.layers[0].layerNumber : 1);
    this.viewportStore.selectedDatatype = firstDrawable !== undefined ? firstDrawable.datatype : (this.docStore.layers.length > 0 ? this.docStore.layers[0].datatype : 0);
    this.lvsNativeNets = []; this.verifyStore.lvsReports = []; this.verifyStore.comparisonCellName = ''; this.aiStore.aiLastResult = '';
    this.setNativeSnapshotCurrent(true);
    this.originalSourceCurrent = true;
    this.panelStore.statusText = `已解析 ${this.fileNameFromPath(parsed.filePath)}: ${parsed.cellCount} Cells / ${parsed.layerCount} Layers / ${importedShapes.length} Shapes / ${parsed.ports.length} Ports / Top ${this.docStore.docTopCellName}${(parsed.portCapabilityDiagnostics ?? []).length > 0 ? `；${(parsed.portCapabilityDiagnostics ?? []).join('；')}` : ''}`;
    if (editService.getCurrentCellShapes().length > 0 || this.docPorts.length > 0) this.fitAllShapes();
    this.readPCellVariants();
    this.refreshWorkspaceTabs();
    this.scheduleWorkspaceDraft();
  }

  private layersFromResult(result: GdsiiResult): UiLayer[] {
    const parsedLayers: UiLayer[] = [];
    const sky130: boolean = hasSky130DisplaySignature(result.allLayers);
    for (let i = 0; i < result.allLayers.length; i++) {
      const layer = result.allLayers[i];
      const uiLayer: UiLayer = defaultLayoutLayer(layer.layerNumber, layer.datatype,
        layer.elementCount, this.layerColor(i), sky130);
      if (layer.sourceName !== undefined) {
        uiLayer.sourceName = layer.sourceName;
        if (!sky130 && layer.sourceName.trim().length > 0) { uiLayer.chineseName = layer.sourceName; uiLayer.englishName = layer.sourceName; }
      }
      if (sky130 && layer.layerNumber === 235 && layer.datatype === 4) {
        uiLayer.chineseName = '版图边界';
        uiLayer.color = '#8E9AAD'; uiLayer.fillStyle = 'outline'; uiLayer.lineWidth = 0.6;
      }
      parsedLayers.push(uiLayer);
    }
    return parsedLayers;
  }

  private cellsFromResult(result: GdsiiResult): CellInfo[] {
    const cells: CellInfo[] = [];
    for (let i = 0; i < result.cells.length; i++) {
      cells.push({ id: i, name: result.cells[i].name });
    }
    return cells;
  }

  private layerColor(index: number): string {
    const colors: string[] = ['#4A90D9', '#D9B34A', '#6BCB77', '#D94A4A', '#4AD97A', '#9B6BDB', '#B34AD9', '#D96BA8'];
    return colors[index % colors.length];
  }

  /** Display the source filename while retaining the sandbox path for native I/O. */
  private currentFileDisplayName(): string {
    if (this.docStore.currentDocumentTitle.length > 0) return this.docStore.currentDocumentTitle;
    if (this.docStore.currentFilePath.length === 0) return this.docStore.currentDocumentTitle;
    const file: RecentFile | undefined = this.docStore.recentFiles.find((item: RecentFile): boolean =>
      item.sandboxPath === this.docStore.currentFilePath || item.sourceUri === this.docStore.currentFilePath);
    return file !== undefined && file.name.length > 0 ? file.name : this.fileNameFromPath(this.docStore.currentFilePath);
  }

  private async loadGeneratedPython(path: string, name: string, canApply: () => boolean = (): boolean => true): Promise<boolean> {
    return this.applyPythonResult({ path, name, previewPath: '', summary: '', stdout: '', inputMode: 'new' }, 'replace', -1, canApply);
  }

  private async createPythonSnapshot(mode: PythonInputMode): Promise<PythonDocumentInput> {
    const revision: number = this.docStore.editorRevision, id: string = this.docStore.activeWorkspaceId;
    const semanticContext: string = JSON.stringify([this.docCellKeys, this.docPorts, this.docCrossSections,
      this.docLayoutContextRecords, this.docCellContextRecords]);
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const document: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
    const serial: string = `${Date.now()}-${++this.snapshotSerial}`;
    const path: string = `${context.cacheDir}/python-input-${serial}.gds`;
    const input: ExportLayoutInput = this.exportInputFromWorkspace(document);
    let selectionPath: string | undefined;
    try {
      const saved: LayoutExportResult = await layoutExportService.writeGdsToPath(input, path);
      if (saved.skippedShapeCount > 0) throw new Error('当前文档快照不完整');
      if (mode === 'selection') {
        if (document.selectedIds.length === 0) throw new Error('请先选择当前 Cell 中的图形');
        const selection: WorkspaceDocument = this.cloneDocumentSubset(document, document.cellStack[document.cellStack.length - 1], document.selectedIds);
        selectionPath = `${context.cacheDir}/python-selection-${serial}.gds`;
        const selectionSaved = await layoutExportService.writeGdsToPath(this.exportInputFromWorkspace(selection), selectionPath);
        if (selectionSaved.skippedShapeCount > 0) throw new Error('选区快照不完整');
      }
      if (id !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) throw new Error('创建快照期间文档发生变化，请重试');
      if (semanticContext !== JSON.stringify([this.docCellKeys, this.docPorts, this.docCrossSections,
        this.docLayoutContextRecords, this.docCellContextRecords])) throw new Error('创建快照期间端口信息发生变化，请重试');
      return { path, selectionPath, currentCellName: document.cellNames[document.cellStack[document.cellStack.length - 1]], revision, documentId: id };
    } catch (error) {
      await pythonBridgeService.disposeDocumentInput({ path, selectionPath, revision, documentId: id }, context);
      throw new Error(error instanceof Error ? error.message : String(error));
    } finally { this.synchronizeCurrentDocument(); }
  }

  private exportInputFromWorkspace(document: WorkspaceDocument): ExportLayoutInput {
    return { shapes: document.shapes, layers: document.layers, libName: document.libName,
      topCellName: document.topCellName, topCellId: document.topCellId, cellNames: document.cellNames,
      cellProperties: document.cellProperties, libProperties: document.libProperties, layerDefinitions: document.layerDefinitions,
      cellKeys: document.cellKeys, ports: document.ports, crossSections: document.crossSections,
      layoutContextRecords: document.layoutContextRecords, cellContextRecords: document.cellContextRecords,
      physicalUnits: document.physicalUnits, userUnits: document.userUnits,
      sourcePath: '', preferNativeWriter: false, preferOriginalSourceCopy: false,
      nativeTempDir: (this.getUIContext().getHostContext() as common.UIAbilityContext).cacheDir };
  }

  private layersForPythonResult(parsed: GdsiiResult, artifact: PythonLayoutArtifact): UiLayer[] {
    const layers: UiLayer[] = this.layersFromResult(parsed);
    // Current-document scripts keep the user's layer display metadata for surviving pairs.
    if (artifact.inputMode !== undefined && artifact.inputMode !== 'new') {
      for (let i = 0; i < layers.length; i++) {
        const existing: UiLayer | undefined = this.docStore.layers.find((layer: UiLayer): boolean =>
          layer.layerNumber === layers[i].layerNumber && layer.datatype === layers[i].datatype);
        if (existing !== undefined) {
          const count: number = layers[i].elementCount;
          layers[i] = cloneUiLayerModel(existing) as UiLayer;
          layers[i].elementCount = count;
        }
      }
    }
    const pairs: Set<string> = new Set<string>();
    for (const definition of artifact.layerDefinitions ?? []) {
      const pair: string = `${definition.layerNumber}/${definition.datatype}`;
      if (!Number.isInteger(definition.layerNumber) || definition.layerNumber < 0 || definition.layerNumber > 32767 ||
        !Number.isInteger(definition.datatype) || definition.datatype < 0 || definition.datatype > 32767 ||
        typeof definition.name !== 'string' || /[\u0000-\u001f\u007f-\u009f]/.test(definition.name) || pairs.has(pair)) {
        throw new Error('Python 输出的命名图层无效');
      }
      pairs.add(pair);
      let layer: UiLayer | undefined = layers.find((item: UiLayer): boolean =>
        item.layerNumber === definition.layerNumber && item.datatype === definition.datatype);
      if (layer === undefined) {
        const existing: UiLayer | undefined = artifact.inputMode !== undefined && artifact.inputMode !== 'new'
          ? this.docStore.layers.find((item: UiLayer): boolean => item.layerNumber === definition.layerNumber && item.datatype === definition.datatype)
          : undefined;
        layer = existing !== undefined ? cloneUiLayerModel(existing) as UiLayer :
          defaultLayoutLayer(definition.layerNumber, definition.datatype, 0, this.layerColor(layers.length), false);
        layer.elementCount = 0;
        layers.push(layer);
      }
      if (definition.name.trim().length > 0) {
        layer.chineseName = definition.name;
        layer.englishName = definition.name;
      }
    }
    return layers;
  }

  private async applyPythonResult(artifact: PythonLayoutArtifact, mode: 'replace' | 'merge', revision: number,
                                  canApply: () => boolean = (): boolean => true, requireGeometry: boolean = false,
                                  onStage: (stage: string, status: 'running' | 'completed', detail: string) => void = (): void => {}): Promise<boolean> {
    const id: string = this.docStore.activeWorkspaceId, start: number = this.docStore.editorRevision, generation: number = this.pageGeneration;
    const isCurrent: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration && id === this.docStore.activeWorkspaceId && start === this.docStore.editorRevision && canApply();
    if (!this.pageAlive) return false;
    if (!isCurrent()) { this.panelStore.statusText = '生成请求已取消或上下文已改变，Python 输出未应用'; return false; }
    if (artifact.inputMode !== undefined && artifact.inputMode !== 'new' &&
      (artifact.sourceDocumentId !== id || revision !== start)) {
      this.panelStore.statusText = 'Python 输出对应的源文档已改变，请重新执行后载入'; return false;
    }
    const reuseEmptyActiveTab: boolean = mode === 'replace' &&
      this.docStore.workspaceTabs.length >= MAX_WORKSPACE_TABS &&
      this.isCurrentWorkspaceTabEmptyReusable();
    if (mode === 'replace' && !reuseEmptyActiveTab && !this.canOpenWorkspaceDocument()) return false;
    if (mode === 'merge' && !this.assertEditMode()) return false;
    let parsed: GdsiiResult;
    onStage('parse', 'running', '正在解析生成的版图文件');
    if (!isCurrent()) return false;
    try { parsed = await this.parseImportJob(artifact.path, false, isCurrent); }
    catch (error) {
      if (!isCurrent()) return false;
      throw new Error(error instanceof Error ? error.message : String(error));
    }
    if (!isCurrent()) return false;
    if (!parsed.success) throw new Error(parsed.errorMessage || 'Python 输出解析失败');
    this.verifyPythonPortMetadata(parsed, artifact);
    if (!isCurrent()) {
      this.panelStore.statusText = '载入期间请求已取消或文档已改变，Python 输出未应用'; return false;
    }
    if (mode === 'merge' && parsed.topCellIds.length > 1) {
      this.panelStore.statusText = 'Python 输出含多个独立顶层 Cell，请载入新标签页以保留完整库'; return false;
    }
    const resultDocument: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
    const top: number = parsed.primaryTopCellId >= 0 ? parsed.primaryTopCellId : 0;
    resultDocument.id = reuseEmptyActiveTab ? id : workspaceService.newId(); resultDocument.title = artifact.name;
    resultDocument.shapes = nativeShapesToShapes(parsed.shapes);
    if (requireGeometry && parsed.ports.length === 0 && !resultDocument.shapes.some((shape: Shape): boolean =>
      shape.type !== ShapeType.NODE && shape.type !== ShapeType.INSTANCE)) throw new Error('模型脚本未生成可绘制图形或有效端口，原文档已保留');
    resultDocument.cellNames = parsed.cells.map((cell): string => cell.name);
    resultDocument.cellProperties = parsed.cells.map((cell): LayoutPropRecord[] => cell.properties ?? []);
    resultDocument.cellKeys = parsed.cellKeys; resultDocument.ports = parsed.ports;
    resultDocument.crossSections = parsed.crossSections; resultDocument.layoutContextRecords = parsed.layoutContextRecords;
    resultDocument.cellContextRecords = parsed.cellContextRecords;
    resultDocument.libProperties = parsed.libProperties ?? [];
    resultDocument.layerDefinitions = parsed.layerDefinitions ?? [];
    resultDocument.navigationPath = [];
    resultDocument.precision = { dbuNm: cleanDbuNm(parsed.physicalUnits), drawStepNm: resultDocument.precision?.drawStepNm ?? resultDocument.gridSize,
      displayGridNm: resultDocument.gridSize, geometrySnapEnabled: this.viewportStore.geometrySnapEnabled, geometrySnapKinds: this.viewportStore.geometrySnapKinds.slice() };
    resultDocument.libName = parsed.libName || 'PYTHON_OUTPUT'; resultDocument.topCellId = top;
    resultDocument.topCellName = resultDocument.cellNames[top]; resultDocument.cellStack = [top];
    resultDocument.userUnits = parsed.userUnits; resultDocument.physicalUnits = parsed.physicalUnits;
    resultDocument.layers = this.layersForPythonResult(parsed, artifact); resultDocument.selectedIds = []; resultDocument.pcells = [];
    resultDocument.sourcePath = mode === 'replace' ? artifact.path : ''; resultDocument.saveUri = ''; resultDocument.projectUri = '';
    resultDocument.technologyId = ''; resultDocument.technologyJson = ''; resultDocument.rulers = [];
    resultDocument.viewMode = ViewMode.EDIT; resultDocument.dirty = true; resultDocument.revision = 0;
    resultDocument.zoom = 100; resultDocument.offsetX = 0; resultDocument.offsetY = 0;
    resultDocument.hierarchyDepth = 2; resultDocument.gridSize = cleanDbuNm(parsed.physicalUnits);
    const validated: WorkspaceDocument = workspaceService.cloneValidatedDocument(resultDocument);
    onStage('parse', 'completed', `已解析 ${validated.shapes.length} 个图形、${validated.layers.length} 个图层`);
    if (!isCurrent()) return false;
    if (mode === 'replace') {
      const reuseNow: boolean = this.docStore.workspaceTabs.length >= MAX_WORKSPACE_TABS && this.isCurrentWorkspaceTabEmptyReusable();
      if (!reuseNow && !this.canOpenWorkspaceDocument()) return false;
      if (!isCurrent()) return false;
      if (reuseNow && validated.id !== id) {
        validated.id = id;
      }
      onStage('activate', 'running', reuseNow ? '正在当前空白标签页载入版图' : '正在打开独立版图标签页');
      if (!isCurrent()) return false;
      if (!reuseNow) {
        this.captureWorkspaceDocument();
      }
      try {
        // All geometry and named/empty layers are validated before native activation or publication.
        this.activateWorkspaceDocument(validated);
      } catch (error) {
        this.synchronizeCurrentDocument();
        throw new Error(error instanceof Error ? error.message : String(error));
      }
      this.workspaceDocuments.set(validated.id, validated);
      this.originalSourceCurrent = false;
      this.lvsNativeNets = []; this.verifyStore.lvsReports = []; this.verifyStore.comparisonCellName = '';
      this.fitAllShapes(); this.panelStore.statusText = `已${reuseNow ? '在当前空白标签页' : '在新标签页'}载入 Python 版图：${artifact.name} · ${parsed.ports.length} 个端口${(parsed.portCapabilityDiagnostics ?? []).length > 0 ? `；${(parsed.portCapabilityDiagnostics ?? []).join('；')}` : ''}`;
      this.refreshWorkspaceTabs(); this.scheduleWorkspaceDraft();
      onStage('activate', 'completed', reuseNow ? '已载入当前空白标签页' : '已打开独立标签页，原文档保留');
      return true;
    }
    return this.insertLibraryEntry({ id: `python-${Date.now()}`, title: artifact.name, category: 'Python', createdAt: Date.now(),
      pcellName: '', params: {}, document: validated }, 0, 0);
  }

  private verifyPythonPortMetadata(parsed: GdsiiResult, artifact: PythonLayoutArtifact): void {
    const metadata = artifact.portMetadata;
    if (metadata === undefined) return;
    if (metadata.cellNames.length !== parsed.cells.length || metadata.ports.length !== parsed.ports.length ||
      metadata.crossSections.length !== parsed.crossSections.length) throw new Error('Python 端口 sidecar 与实际版图文件不一致');
    if (!this.sameContextRecords(metadata.layoutContextRecords, parsed.layoutContextRecords) ||
      metadata.cellContextRecords.length !== parsed.cellContextRecords.length) throw new Error('Python 布局 context 字节或顺序与实际文件不一致');
    for (let sourceId: number = 0; sourceId < metadata.cellNames.length; sourceId++) {
      const targetId: number = parsed.cells.findIndex((cell): boolean => cell.name === metadata.cellNames[sourceId]);
      if (targetId < 0 || parsed.cellKeys[targetId] !== metadata.cellKeys[sourceId]) throw new Error('Python 端口的稳定 Cell 身份未通过实际文件核对');
      if (!this.sameContextRecords(metadata.cellContextRecords[sourceId], parsed.cellContextRecords[targetId])) throw new Error('Python Cell context 的归属、字节或顺序与实际文件不一致');
    }
    for (const expected of metadata.ports) {
      const actual = parsed.ports.find((port): boolean => port.id === expected.id);
      const targetId: number = parsed.cells.findIndex((cell): boolean => cell.name === metadata.cellNames[expected.ownerCellId]);
      if (actual === undefined || actual.ownerCellId !== targetId || actual.ownerCellKey !== expected.ownerCellKey ||
        actual.name !== expected.name || actual.portType !== expected.portType || actual.layerNumber !== expected.layerNumber ||
        actual.datatype !== expected.datatype || actual.frameMirror !== expected.frameMirror ||
        actual.crossSectionKey !== expected.crossSectionKey || actual.crossSectionVersion !== expected.crossSectionVersion ||
        actual.infoJson !== expected.infoJson || actual.provenance !== expected.provenance) throw new Error('Python 端口定义与实际文件不一致');
      const expectedNumbers: number[] = [expected.centerNm.x, expected.centerNm.y, expected.orientationDeg, expected.widthNm, expected.frameMagnification];
      const actualNumbers: number[] = [actual.centerNm.x, actual.centerNm.y, actual.orientationDeg, actual.widthNm, actual.frameMagnification];
      if (expectedNumbers.some((value: number, index: number): boolean => Math.abs(value - actualNumbers[index]) > Math.max(1, Math.abs(value)) * 1e-9)) throw new Error('Python 端口 frame 或宽度未通过实际文件核对');
    }
    for (const expected of metadata.crossSections) {
      const actual = parsed.crossSections.find((section): boolean => section.key === expected.key && section.version === expected.version);
      if (actual === undefined || actual.name !== expected.name || actual.definitionJson !== expected.definitionJson ||
        actual.sourceFormat !== expected.sourceFormat || actual.sourceVersion !== expected.sourceVersion) throw new Error('Python CrossSection 与实际文件不一致');
    }
  }

  private sameContextRecords(expected: LayoutContextRecord[], actual: LayoutContextRecord[]): boolean {
    if (!Array.isArray(expected) || !Array.isArray(actual) || expected.length !== actual.length) return false;
    for (let index: number = 0; index < expected.length; index++) {
      const left: number[] = contextRecordBytes(expected[index]), right: number[] = contextRecordBytes(actual[index]);
      if (left.length !== right.length || left.some((byte: number, at: number): boolean => byte !== right[at])) return false;
    }
    return true;
  }

  private applyTechnology(technology: TechnologyPackage, preserveRuleConfiguration: boolean = false): void {
    if (!this.assertEditMode()) throw new Error('查看模式不能修改工艺');
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) throw new Error('已有后台作业，请等待完成后修改工艺');
    this.finishNudgeTransaction();
    const parsed = parseTechnologyPackage(JSON.stringify(technology));
    if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error);
    this.captureAutomaticEngineeringOrigin();
    const before: EditStructureState = this.cellStructureState(), after: EditStructureState = cloneEditStructureModel(before, true) as EditStructureState;
    before.technologyJson = technologyService.serialize(); before.drcConfiguration = drcService.captureConfiguration();
    before.drcDeckJson = JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() });
    before.localProcessOwned = this.localProcessOwned === true; after.localProcessOwned = true;
    after.technologyJson = JSON.stringify(parsed.technology, null, 2);
    const label: string = `${technology.name} ${technology.version} · ${technology.qualification}`;
    after.drcDeckJson = JSON.stringify({ name: `自定义 · ${label}`, rules: parsed.technology.drcRules });
    after.drcConfiguration = drcService.captureConfiguration();
    after.drcConfiguration.rules = cloneStructured(parsed.technology.drcRules);
    after.drcConfiguration.baseRules = cloneStructured(parsed.technology.drcRules);
    after.drcConfiguration.ruleSource = 'custom'; after.drcConfiguration.ruleSourceLabel = label;
    after.drcConfiguration.ruleFiles = []; after.drcConfiguration.rulesTweaked = false;
    after.layers = preserveRuleConfiguration ? cloneUiLayerArray(this.docStore.layers) as UiLayer[] : technologyService.deriveLayers(parsed.technology, this.docStore.layers);
    if (preserveRuleConfiguration) { after.drcDeckJson = before.drcDeckJson; after.drcConfiguration = before.drcConfiguration; }
    if (!editService.applyDocumentStructure(editService.getShapes(), before, after, '工艺与物理层栈配置')) throw new Error('工艺结构事务被拒绝，原配置保留');
    this.syncLayerVisibilityMirror(); this.syncShapesFromEditService();
    this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false; this.verifyStore.tracedNets = []; this.verifyStore.lvsHasResult = false;
    this.panelStore.statusText = `已绑定 ${technology.name} ${technology.version}，规则范围：${technology.qualification}`;
  }

  private layerStackContext(): string {
    return `${this.portDialogContext()}:${technologyService.serialize()}`;
  }
  private captureLocalProcessState(): WorkspaceLocalProcessState {
    const state: WorkspaceLocalProcessState = { schema: 'hongtu-local-process/v1', technologyJson: technologyService.serialize(),
      drcDeckJson: JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() }), drcConfiguration: drcService.captureConfiguration() };
    return state;
  }
  private openLayerStack(): void {
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { this.panelStore.statusText = '已有后台作业，请等待完成后打开层栈'; return; }
    if (technologyService.getActive() === undefined) { this.panelStore.statusText = '请先绑定含明确图层映射的工艺包'; this.panelStore.showTechnologyPanel = true; return; }
    this.finishNudgeTransaction(); this.panelStore.showLayerStackPanel = true;
  }
  private buildLayerStack(stack: PhysicalLayerStack, options: LayerStackBuildOptions): LayerStackResult {
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) return { ok: false, message: '已有后台作业，不能生成旧文档的几何' };
    const parsed = parsePhysicalLayerStack(JSON.stringify(stack), technologyService.getActive()?.layers);
    if (!parsed.ok || !parsed.executable || parsed.stack === undefined) return { ok: false, message: parsed.message };
    return layerStackService.build({ stack: parsed.stack, shapes: editService.getShapes(), structure: this.cellStructureState(),
      rootCellId: editService.getCurrentCellId(), dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits),
      precisionNm: options.precisionNm, boundsNm: options.boundsNm, sectionLine: options.sectionLine, coordinatePolicy: options.coordinatePolicy });
  }
  private saveLayerStack(stack: PhysicalLayerStack): void {
    const technology: TechnologyPackage | undefined = technologyService.getActive();
    if (technology === undefined) throw new Error('当前文档工艺绑定已失效');
    const parsed = parsePhysicalLayerStack(JSON.stringify(stack), technology.layers);
    if (!parsed.ok || parsed.stack === undefined) throw new Error(parsed.message);
    technology.layerStack = parsed.stack; this.applyTechnology(technology, true);
  }

  private clearTechnology(): void {
    if (!this.assertEditMode()) throw new Error('查看模式不能修改工艺');
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) throw new Error('已有后台作业，请等待完成后修改工艺');
    this.finishNudgeTransaction();
    this.captureAutomaticEngineeringOrigin();
    const before: EditStructureState = this.cellStructureState(), after: EditStructureState = cloneEditStructureModel(before, true) as EditStructureState;
    before.technologyJson = technologyService.serialize(); before.drcConfiguration = drcService.captureConfiguration();
    before.drcDeckJson = JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() });
    before.localProcessOwned = this.localProcessOwned === true; after.localProcessOwned = true;
    after.technologyJson = ''; after.drcDeckJson = JSON.stringify({ name: '未绑定工艺', rules: [] });
    after.drcConfiguration = drcService.captureConfiguration(); after.drcConfiguration.rules = []; after.drcConfiguration.baseRules = [];
    after.drcConfiguration.ruleSource = 'custom'; after.drcConfiguration.ruleSourceLabel = '未绑定工艺';
    after.drcConfiguration.ruleFiles = []; after.drcConfiguration.rulesTweaked = false;
    if (!editService.applyDocumentStructure(editService.getShapes(), before, after, '解除工艺绑定')) throw new Error('工艺结构事务被拒绝，原配置保留');
    this.syncShapesFromEditService(); this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false;
    this.verifyStore.tracedNets = []; this.verifyStore.lvsHasResult = false; this.panelStore.statusText = '工艺绑定已移除';
  }

  private locateExternalViolation(violation: PythonViolation): void {
    this.focusWorldBounds({ minX: violation.minX, minY: violation.minY, maxX: violation.maxX, maxY: violation.maxY });
    this.verifyStore.highlightedViolation = { x: violation.minX,
      y: violation.minY, w: Math.max(1, violation.maxX - violation.minX),
      h: Math.max(1, violation.maxY - violation.minY) };
    this.panelStore.statusText = `${violation.rule} · L${violation.layerNumber}/D${violation.datatype}：${violation.message}`;
  }

  private showResultCell(name: string): void {
    const cell: CellInfo | undefined = this.placeableCells.find((item: CellInfo): boolean => item.name === name);
    if (cell === undefined || cell.id === editService.getCurrentCellId()) return;
    editService.exitToTop();
    if (cell.id !== editService.getTopCellId()) editService.enterCell(cell.id);
    this.viewportStore.selectedShapeId = -1; this.viewportStore.selectedShapeCount = editService.getSelectedIds().length; this.shapes = editService.getShapes().slice();
    this.refreshEditingCellPresentation();
    this.scheduleWorkspaceDraft();
  }

  private fileNameFromPath(path: string): string {
    const parts = path.split('/');
    return parts[parts.length - 1] || path;
  }

  private scanNativeFile(filePath: string): void {
    try {
      const result: GdsiiResult = nativeHongTuService.quickScan(filePath);
      if (result.success) {
        this.panelStore.statusText = `quickInfo: ${result.libName} | ${result.cellCount} Cells | ${result.layerCount} Layers`;
      } else {
        this.panelStore.statusText = `quickInfo 失败: ${result.errorMessage}`;
      }
    } catch (error) {
      this.panelStore.statusText = `quickInfo 异常: ${error}`;
    }
  }

  private refreshAiConversation(): void {
    this.aiStore.aiConversations = aiService.getConversations();
    this.aiStore.aiActiveConversationId = aiService.getActiveConversationId();
    this.aiStore.aiContextOptions = aiService.getContextOptions();
    this.aiStore.aiMessages = aiService.getChatHistory().slice();
    this.aiStore.aiContextEpoch++;
    this.aiStore.aiProjectNote = aiService.getProjectKnowledge(this.docStore.activeWorkspaceId)?.text ?? '';
    const checkpoint: AiTaskCheckpoint | undefined = aiService.getTaskCheckpoint();
    const phaseIds: string[] = ['running', 'pending', 'applying', 'applied', 'failed', 'cancelled', 'completed'];
    const phaseLabels: string[] = ['上轮运行未结束，可核对后继续', '方案待确认；重新打开后需重新核对版图',
      '应用回执不完整，需先核对版图', '修改已应用，请查看复检回执', '上轮未完成', '上轮已取消等待', '上轮已结束'];
    let hasUnloadedArtifact: boolean = false;
    if (checkpoint !== undefined && !checkpoint.task.readOnly && checkpoint.task.artifactGenerationAllowed &&
      checkpoint.phase !== 'applying' && checkpoint.documentIdentity === this.docStore.activeWorkspaceId) {
      let latestArtifactId: string = '';
      for (const tool of checkpoint.tools) {
        if (tool.status !== 'completed' || !['create_cmos_inverter', 'execute_layout_python'].includes(tool.name)) continue;
        try {
          const val: Record<string, Object> = JSON.parse(tool.result) as Record<string, Object>;
          const artId: Object | undefined = val['artifactId'];
          if (val['success'] === true && typeof artId === 'string' && /^[a-f0-9-]{32,36}$/i.test(artId)) {
            latestArtifactId = artId;
          }
        } catch (_) {}
      }
      if (latestArtifactId.length > 0 && !(checkpoint.loadedArtifacts ?? []).includes(latestArtifactId)) {
        hasUnloadedArtifact = true;
      }
    }
    const isInterruptedCheckpoint: boolean = checkpoint !== undefined &&
      ['running', 'applying', 'failed', 'cancelled'].includes(checkpoint.phase);
    this.aiStore.aiHasRecoverableArtifact = hasUnloadedArtifact;
    this.aiStore.aiHasInterruptedCheckpoint = isInterruptedCheckpoint;
    this.aiStore.aiCheckpointSummary = (checkpoint !== undefined && (isInterruptedCheckpoint || hasUnloadedArtifact))
      ? `${phaseLabels[phaseIds.indexOf(checkpoint.phase)]} · ${checkpoint.tools.filter((tool: AiChatToolState): boolean => tool.status === 'completed').length} 个工具步骤已记录`
      : '';
    const error: string = aiService.getConversationError();
    if (error.length > 0) this.aiStore.aiError = error;
  }

  private handleAiConversationAction(action: string, id: string = '', title: string = ''): void {
    if (this.aiStore.aiLoading) { this.aiStore.aiError = '请先完成或取消当前运行，再管理会话'; return; }
    try {
      if (action === 'new' || action === 'clear' || action === 'switch' || (action === 'delete' && id === this.aiStore.aiActiveConversationId)) {
        this.cancelPendingAiCommands(false);
      }
      let changed: boolean = false;
      if (action === 'new') changed = aiService.createConversation().length > 0;
      else if (action === 'switch') changed = aiService.switchConversation(id);
      else if (action === 'rename') changed = aiService.renameConversation(id, title);
      else if (action === 'delete') changed = aiService.deleteConversation(id);
      else if (action === 'clear') changed = aiService.clearCurrentConversation();
      if (!changed) throw new Error('会话操作未完成，请重试');
      this.aiStore.aiError = ''; this.aiStore.aiLastResult = ''; this.aiStore.aiCanUndo = false;
      this.aiStore.aiStreamingText = ''; this.aiStore.aiReasoningText = ''; this.aiStore.aiToolCalls = [];
      this.aiStore.aiReportedContextUsage = '';
      this.refreshAiConversation();
    } catch (error) { this.aiStore.aiError = error instanceof Error ? error.message : String(error); }
  }

  private setAiContextOptions(options: AiContextOptions): void {
    if (this.aiStore.aiLoading) { this.aiStore.aiError = '运行结束后可调整上下文范围'; return; }
    try {
      this.cancelPendingAiCommands(false);
      aiService.setContextOptions(options);
      this.aiStore.aiReportedContextUsage = '';
      this.refreshAiConversation();
    } catch (error) { this.aiStore.aiError = error instanceof Error ? error.message : String(error); }
  }

  private filteredAiContext(context: AiContext): AiContext {
    const options: AiContextOptions = aiService.getContextOptions();
    if (!options.includeLayout) return { layers: [], currentLayer: 0, shapeCount: 0, selectedShape: null,
      layoutContextIncluded: false, selectionContextIncluded: false };
    context.layoutContextIncluded = true;
    context.selectionContextIncluded = options.includeSelection;
    if (!options.includeSelection) {
      context.selectedShape = null; context.selectedShapes = [];
      if (context.coverage !== undefined) { context.coverage.selectedTotal = 0; context.coverage.selectedIncluded = 0; context.coverage.selectedGeometryTruncated = false; }
    }
    if (!options.includeHistory) context.executionReceipt = undefined;
    return context;
  }

  private aiContextDetail(): string {
    const options: AiContextOptions = this.aiStore.aiContextOptions;
    const history: string = options.includeHistory ? '本会话历史（不发送其他会话）' : '不发送聊天历史';
    const layout: string = options.includeLayout
      ? `${this.currentFileDisplayName() || '未命名版图'} / 当前编辑 ${this.cellName(editService.getCurrentCellId())}；Top ${this.docStore.docTopCellName}，${this.shapes.length} 图形、${this.docStore.layers.length} 图层`
      : '未发送当前版图资料';
    const selection: string = options.includeLayout && options.includeSelection
      ? `选区 ${editService.getSelectedIds().length} 项（最多64项、每项128点）` : '未发送选区资料';
    const drc: string = !options.includeLayout ? '未发送检查信息' :
      (this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision
        ? `${this.verifyStore.drcIssues.length} 项检查记录；规则范围以验证结果为准` : '当前版本尚无有效检查结果');
    return `${history}\n${layout}\n${selection}\n${drc}\n坐标 nm；DBU ${(cleanDbuNm(this.docStore.docPhysicalUnits)).toPrecision(4)} nm；文档版本 ${this.docStore.editorRevision}。摘要最多128个Cell、64项检查和32个网络，附截断标记；启用版图上下文后支持按需分页查询，不上传完整GDS。`;
  }

  private aiContextUsageLabel(): string {
    const config: AiModelConfig = aiService.getConfig();
    const key: string = `${this.aiStore.aiContextEpoch}:${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}:` +
      `${editService.getSelectedIds().join(',')}:${this.drcSnapshotRevision}:${this.netSnapshotRevision}:` +
      `${config.contextWindowTokens}:${config.maxTokens}:${config.compressionThreshold}:${this.aiStore.aiReportedContextUsage}`;
    if (key === this.aiContextCacheKey) return this.aiContextCacheLabel;
    let label: string = '';
    try {
      const budget = buildAiContextBudget(aiService.getContextHistory(), this.filteredAiContext(this.buildAiContext()), '', config);
      label = `估算 ${budget.estimatedTotalTokens} / 配置窗口 ${budget.contextWindowTokens} tokens（含输出预留 ${budget.reservedOutputTokens}）`;
      if (budget.exceedsWindow) label += ' · 超出窗口，请压缩会话';
      else if (budget.shouldCompress) label += ' · 已到压缩阈值';
      if (this.aiStore.aiReportedContextUsage.length > 0) label += `\n${this.aiStore.aiReportedContextUsage}`;
    } catch (error) { label = error instanceof Error ? error.message : String(error); }
    this.aiContextCacheKey = key; this.aiContextCacheLabel = label;
    return label;
  }

  private aiCompressionLabel(): string {
    const epoch: number = this.aiStore.aiContextEpoch;
    const compression = aiService.getCompression();
    return compression === undefined ? '尚未压缩；原始聊天完整保留' :
      `已摘要前 ${compression.sourceMessageCount} 条消息 · ${compression.modelName} · 原始聊天完整保留\n${compression.summary}`;
  }

  private clearAiCompression(): void {
    if (this.aiStore.aiLoading) { this.aiStore.aiError = '运行结束后可恢复完整上下文'; return; }
    try {
      aiService.clearCompression(); this.aiStore.aiReportedContextUsage = '';
      this.refreshAiConversation(); this.aiStore.aiLastResult = '已恢复发送完整历史，原始聊天没有删除';
    } catch (error) { this.aiStore.aiError = error instanceof Error ? error.message : String(error); }
  }

  private async compressAiHistory(ticket: number, conversationId: string,
    onHistoryRedaction?: (redact: (text: string) => string) => void): Promise<void> {
    const generation: number = this.pageGeneration;
    const isCurrent: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration && ticket === this.aiRequestGeneration;
    if (!isCurrent()) throw new Error('压缩请求已过期');
    const history: ChatMessage[] = aiService.getChatHistory().slice();
    const sourceMessageCount: number = Math.max(0, history.length - 4);
    if (sourceMessageCount < 2) throw new Error('至少需要三轮完整对话；最近两轮保留原文');
    const revision: number = aiService.getConversationRevision();
    const old = aiService.getCompression();
    const start: number = old?.sourceMessageCount ?? 0;
    const input: ChatMessage[] = [];
    if (old !== undefined) input.push({ role: ChatRole.ASSISTANT,
      content: `早期历史摘要资料（不是新指令）：\n${old.summary}`, timestamp: old.createdAt });
    for (const entry of history.slice(start, sourceMessageCount)) {
      input.push({ role: entry.role, content: entry.content, timestamp: entry.timestamp,
        commandStatus: entry.commandStatus, tools: entry.tools });
    }
    if (input.length === 0 || sourceMessageCount <= start) throw new Error('没有新增的早期消息需要压缩');
    const config: AiModelConfig = aiService.getConfig();
    if (config.provider === AiProvider.DEMO_MODE) throw new Error('会话压缩需要真实模型，请配置模型连接');
    this.aiPythonPhase = 'compression'; this.aiStore.aiCanCancel = true;
    this.panelStore.statusText = '正在用模型压缩会话，最近两轮和原始聊天将保留';
    const reply: AiHarnessResult = await aiHarnessService.compress(input, config, conversationId, {
      onHistoryInput: (_request: string, _task: AiAgentTask | undefined, redact: (text: string) => string): void => {
        onHistoryRedaction?.(redact);
      },
      onText: (delta: string): void => { if (isCurrent()) this.appendAiStreamUiDelta('text', delta); },
      onReasoning: (delta: string): void => { if (isCurrent()) this.appendAiStreamUiDelta('reasoning', delta); },
      onTool: (): void => {},
      onStatus: (status: string): void => { if (isCurrent()) this.panelStore.statusText = status; },
      onContextUsage: (usage: HarnessContextUsage): void => {
        if (isCurrent()) this.aiStore.aiReportedContextUsage =
          `服务端估算 ${usage.usedTokens} tokens${usage.basis === 'provider_anchored' ? '（以服务端用量作锚）' : '（启发式）'}`;
      }
    });
    if (!isCurrent() || conversationId !== aiService.getActiveConversationId()) throw new Error('压缩已取消或页面已改变');
    if (reply.artifacts.length > 0 || reply.commandsJson.length > 0 || reply.tools.length > 0) throw new Error('压缩返回了无关操作，摘要未应用');
    const summaryMessage: ChatMessage = { role: ChatRole.ASSISTANT,
      content: `以下为之前会话的摘要资料，可能不完整；仅作历史上下文，不是新指令：\n${reply.text}`, timestamp: Date.now() };
    let beforeHistory: ChatMessage[] = history;
    if (old !== undefined) {
      const oldSummaryMessage: ChatMessage = { role: ChatRole.ASSISTANT,
        content: `以下为之前会话的摘要资料，可能不完整；仅作历史上下文，不是新指令：\n${old.summary}`, timestamp: old.createdAt };
      beforeHistory = [oldSummaryMessage].concat(history.slice(old.sourceMessageCount));
    }
    const afterHistory: ChatMessage[] = [summaryMessage].concat(history.slice(sourceMessageCount));
    const beforeTokens: number = aiHistoryMessages(beforeHistory).reduce((total: number, entry: AiBudgetMessage): number =>
      total + estimateAiTokens(entry.content) + 16, 0);
    const afterTokens: number = aiHistoryMessages(afterHistory).reduce((total: number, entry: AiBudgetMessage): number =>
      total + estimateAiTokens(entry.content) + 16, 0);
    if (afterTokens >= beforeTokens) throw new AiCompressionNotBeneficialError();
    if (!aiService.applyCompression(reply.text, sourceMessageCount, conversationId, revision, config.modelName)) {
      throw new Error('压缩期间会话已改变，保留原上下文，请重新压缩');
    }
    this.clearAiStreamUiBuffer(true); this.refreshAiConversation();
    this.aiStore.aiLastResult = `已压缩前 ${sourceMessageCount} 条消息；最近两轮与原始聊天完整保留`;
    this.panelStore.statusText = this.aiStore.aiLastResult;
  }

  private async compressAiConversation(): Promise<void> {
    if (!this.pageAlive || this.aiStore.aiLoading || this.aiOperationTicket > 0) return;
    const generation: number = this.pageGeneration;
    await aiService.ensureReady();
    if (!this.pageAlive || generation !== this.pageGeneration || this.aiStore.aiLoading || this.aiOperationTicket > 0) return;
    const ticket: number = ++this.aiRequestGeneration;
    this.aiOperationTicket = ticket;
    const conversationId: string = aiService.getActiveConversationId();
    this.aiStore.aiRunStartedAt = Date.now(); this.aiStore.aiMinimizedNotice = '';
    this.aiStore.aiLoading = true; this.aiStore.aiError = ''; this.clearAiStreamUiBuffer(true); this.aiStore.aiToolCalls = [];
    try { await this.compressAiHistory(ticket, conversationId); }
    catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) {
        this.aiStore.aiError = ticket !== this.aiRequestGeneration ? '压缩已取消，原上下文保留' :
          `压缩未完成，原上下文保留：${error instanceof Error ? error.message : String(error)}`;
        this.panelStore.statusText = this.aiStore.aiError;
      }
    } finally {
      if (this.aiOperationTicket === ticket) { this.aiOperationTicket = 0; this.aiStore.aiLoading = false; this.aiStore.aiCanCancel = false; this.aiPythonPhase = ''; }
      if (this.pageAlive && generation === this.pageGeneration) {
        this.clearAiStreamUiBuffer(true); this.aiStore.aiToolCalls = [];
        this.refreshAiConversation();
      }
    }
  }

  private async handleAiPromptFull(prompt: string, resumeTask: boolean = false, forceReadOnly: boolean = false): Promise<void> {
    const stagedAttachments: AiChatAttachment[] = unwrapObserved(this.aiStore.aiPendingAttachments).slice();
    if (prompt.trim().length === 0 && stagedAttachments.length > 0) {
      prompt = '请分析并处理我附带的图片或文件。';
    }
    if (!this.pageAlive || this.aiStore.aiLoading || this.aiOperationTicket > 0 || prompt.trim().length === 0) return;
    this.aiStore.aiPendingAttachments = [];
    prompt = aiService.redactConversationText(prompt);
    const generation: number = this.pageGeneration;
    this.cancelPendingAiCommands(false);
    const ticket: number = ++this.aiRequestGeneration;
    this.aiOperationTicket = ticket;
    const requestContext: string = this.aiRequestContext();
    const requestRevision: number = this.docStore.editorRevision;
    const requestDocumentId: string = this.docStore.activeWorkspaceId;
    const requestSelection: string = editService.getSelectedIds().join(',');
    const requestCell: number = editService.getCurrentCellId();
    const requestLayer: number = this.viewportStore.selectedLayerNumber;
    const requestDatatype: number = this.viewportStore.selectedDatatype;
    const requestConversationId: string = aiService.getActiveConversationId();
    let task: AiAgentTask | undefined;
    let harnessStarted: boolean = false;
    let redactPreparation: (text: string) => string = (text: string): string => aiService.redactConversationText(text);
    try {
      let context: AiContext = this.buildAiContext();
      this.panelStore.statusText = 'AI: 正在处理版图需求…';
      this.aiStore.aiRunStartedAt = Date.now();
      this.aiStore.aiMinimizedNotice = '';
      this.aiStore.aiLoading = true;
      this.aiStore.aiCanCancel = true;
      this.aiStore.aiError = '';
      this.aiStore.aiLastResult = '';
      this.aiStore.aiTurnChangeSummary = '';
      // AI-15: 流式增量显示——清空 streamingText 与节流缓冲，并立即开启 V1 实时流状态
      this.clearAiStreamUiBuffer(true);
      publishAiLiveStream(true, this.panelStore.statusText, [], '');
      this.aiStore.aiToolCalls = [];
      await aiService.ensureReady();
      this.assertAiRequestCurrent(ticket, requestContext);
      // A cold credential load can complete after the initial input check.
      prompt = aiService.redactConversationText(prompt);
      context = this.filteredAiContext(context);
      this.aiStore.aiMessages = aiService.getChatHistory().slice().concat([{
        role: ChatRole.USER,
        content: prompt,
        attachments: stagedAttachments.length > 0 ? stagedAttachments : undefined,
        timestamp: Date.now()
      }]);
      if (aiService.getConfig().provider !== AiProvider.DEMO_MODE) {
        const effectivePerm: DshPermissionMode = forceReadOnly ? 'readonly' : this.aiStore.aiPermissionMode;
        harnessStarted = true;
        await this.runDshNativeAgentPrompt(prompt, ticket, effectivePerm, stagedAttachments);
        return;
      }
      const demoHandled: boolean = await this.tryRunDemoHarnessShortcut(prompt, ticket, forceReadOnly ? 'readonly' : this.aiStore.aiPermissionMode, stagedAttachments);
      if (demoHandled) {
        harnessStarted = true;
        return;
      }
      this.panelStore.statusText = '演示模式：使用本地指令，不调用真实模型';
      await aiService.sendMessage(prompt, context, {
        onStreamReset: () => {
          if (ticket !== this.aiRequestGeneration || requestContext !== this.aiRequestContext()) return;
          this.clearAiStreamUiBuffer(true);
        },
        onChunk: (text: string) => {
          if (ticket !== this.aiRequestGeneration || requestContext !== this.aiRequestContext()) return;
          if (text.length > 0) {
            this.appendAiStreamUiDelta('text', text);
            if (this.panelStore.statusText !== 'AI: 正在生成回复...') {
              this.panelStore.statusText = 'AI: 正在生成回复...';
            }
          }
        },
        onComplete: (fullText: string, commands: ParsedCommand[]) => {
          if (!this.pageAlive || generation !== this.pageGeneration || ticket !== this.aiRequestGeneration) return;
          // AI-15: 完成后清空 streamingText（完整文本已作为 ChatMessage 入历史）
          this.clearAiStreamUiBuffer(true);
          // AI-10: 刷新聊天消息列表（触发 UI 重渲染）
          this.aiStore.aiMessages = aiService.getChatHistory().slice();
          if (requestContext !== this.aiRequestContext()) {
            aiService.updateLastCommandStatus(undefined);
            this.aiStore.aiLastResult = '生成期间版图已切换或修改，请在当前版图重新生成方案';
            this.panelStore.statusText = this.aiStore.aiLastResult;
            return;
          }
          if (commands.length === 0 || forceReadOnly || this.aiStore.aiSessionMode === 'readonly') {
            this.panelStore.statusText = 'AI 回复已就绪';
            if (!this.panelStore.showAiPanel) {
              this.aiStore.aiMinimizedNotice = 'AI 回复已就绪，点击展开查看';
            }
            return;
          }
          this.aiStore.pendingAiCommands = commands;
          this.aiStore.pendingAiContext = context;
          this.pendingAiPrompt = prompt;
          this.pendingAiReply = fullText;
          this.pendingAiRevision = requestRevision;
          this.pendingAiDocumentId = requestDocumentId;
          this.pendingAiSelection = requestSelection;
          this.pendingAiCell = requestCell;
          this.pendingAiLayer = requestLayer;
          this.pendingAiDatatype = requestDatatype;
          this.aiStore.aiPendingSummary = `${commands.length} 项操作待确认`;
          this.aiStore.aiPendingDetail = commands.map((command: ParsedCommand) => command.description || command.type).join('\n');
          this.prepareAiReview(commands);
          this.aiStore.aiLastResult = '';
          this.aiStore.aiCanUndo = false;
          this.panelStore.statusText = 'AI 方案已生成，确认后应用';
        },
        onError: (error: string) => {
          if (!this.pageAlive || generation !== this.pageGeneration || ticket !== this.aiRequestGeneration) return;
          this.aiStore.aiError = error;
          this.aiStore.aiStreamingText = '';
          this.panelStore.statusText = `AI 执行失败: ${error}`;
          // AI-10: 即使出错也刷新消息列表（错误消息已入历史）
          this.aiStore.aiMessages = aiService.getChatHistory().slice();
        }
      });
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration && ticket === this.aiRequestGeneration) {
        this.aiStore.aiError = String(error);
        this.panelStore.statusText = `AI 执行失败: ${error}`;
      }
      if (task !== undefined && !harnessStarted) {
        try {
          aiService.recordHarnessResult(redactPreparation(prompt), '任务准备失败，原文档未修改', '', [], false,
            undefined, requestConversationId, ticket !== this.aiRequestGeneration,
            { originalRequest: redactPreparation(task.originalRequest), readOnly: task.readOnly,
              artifactGenerationAllowed: task.artifactGenerationAllowed, requiredValidationProfile: task.requiredValidationProfile });
          this.refreshAiConversation();
        } catch (_) {}
      }
    } finally {
      redactPreparation = (text: string): string => text;
      // Cancellation does not release this lock until both model/host promises have settled.
      if (this.aiOperationTicket === ticket) { this.aiOperationTicket = 0; this.aiStore.aiLoading = false; this.aiStore.aiCanCancel = false; this.aiPythonPhase = ''; }
      if (this.pageAlive && generation === this.pageGeneration) {
        this.clearAiStreamUiBuffer(true); this.aiStore.aiToolCalls = [];
        this.refreshAiConversation();
      }
    }
  }

  private clearAiStreamUiBuffer(resetStore: boolean = false): void {
    if (this.aiStreamFlushTimer >= 0) {
      clearTimeout(this.aiStreamFlushTimer);
      this.aiStreamFlushTimer = -1;
    }
    this.aiStreamBufferedText = '';
    this.aiStreamBufferedReasoning = '';
    this.aiStreamBufferedSteps = [];
    this.aiStreamBufferedAnswer = '';
    if (resetStore) {
      this.aiStore.aiStreamingText = '';
      this.aiStore.aiReasoningText = '';
      resetAiLiveStream();
    }
  }

  private commitAiLiveSnapshot(): void {
    if (this.aiStore.aiStreamingText !== this.aiStreamBufferedText) {
      this.aiStore.aiStreamingText = this.aiStreamBufferedText;
    }
    if (this.aiStore.aiReasoningText !== this.aiStreamBufferedReasoning) {
      this.aiStore.aiReasoningText = this.aiStreamBufferedReasoning;
    }
    let steps: AiProcessStep[] = this.aiStreamBufferedSteps;
    let ans: string = this.aiStreamBufferedAnswer;
    if (steps.length === 0 && (this.aiStreamBufferedText.length > 0 || this.aiStreamBufferedReasoning.length > 0)) {
      const split = splitInlineThinking(this.aiStreamBufferedText, this.aiStreamBufferedReasoning);
      if (split.thinking.length > 0) {
        steps = [{
          id: 'direct-think-1',
          kind: 'thinking',
          title: '思考过程',
          text: split.thinking,
          status: split.isStreamingThink ? 'running' : 'completed'
        }];
      }
      ans = split.answer;
    }
    publishAiLiveStream(this.aiStore.aiLoading, this.panelStore.statusText, steps, ans);
  }

  private flushAiStreamUiNow(): void {
    if (this.aiStreamFlushTimer >= 0) {
      clearTimeout(this.aiStreamFlushTimer);
      this.aiStreamFlushTimer = -1;
    }
    if (!this.pageAlive) return;
    this.commitAiLiveSnapshot();
  }

  private scheduleAiStreamUiCommit(): void {
    if (this.aiStreamFlushTimer >= 0) {
      return;
    }
    this.aiStreamFlushTimer = setTimeout((): void => {
      this.aiStreamFlushTimer = -1;
      if (!this.pageAlive || !this.aiStore.aiLoading) {
        return;
      }
      this.commitAiLiveSnapshot();
    }, 24);
  }

  private appendAiStreamUiDelta(kind: 'text' | 'reasoning', delta: string): void {
    if (kind === 'text') {
      this.aiStreamBufferedText += delta;
    } else {
      this.aiStreamBufferedReasoning += delta;
    }
    this.scheduleAiStreamUiCommit();
  }

  private aiRequestContext(): string {
    return `${this.pageGeneration}:${this.pageAlive}:${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}:${editService.getCurrentCellId()}:` +
      `${editService.getSelectedIds().join(',')}:${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}:` +
      `${this.viewportStore.currentViewMode}:${this.docStore.workspaceReady}:${this.aiStore.aiActiveConversationId}`;
  }

  private cancelAiGeneration(): void {
    if (!this.aiStore.aiLoading || !this.aiStore.aiCanCancel) return;
    this.aiRequestGeneration++;
    this.aiStore.aiCanCancel = false;
    if (this.aiPythonPhase === 'native_import') {
      this.aiNativeImport.cancel(); this.aiNativeImportSelection = undefined;
      this.aiStore.aiLastResult = '已请求取消导入选择/解析；等待原生流程返回，不采用旧来源'; return;
    }
    if (this.aiPythonPhase === 'native_compare' && this.aiNativeCompare !== null) {
      this.aiNativeCompare.cancel(); this.aiStore.aiLastResult = '已请求取消比较，等待后台停止确认'; return;
    }
    if (this.aiPythonPhase === 'native_tool' && this.aiNativeOperation !== null) {
      this.aiNativeCancellation = pythonBridgeService.cancelOperation(this.aiNativeOperation);
      this.aiNativeCancellation.then((result: PythonCancellationResult): void => { this.aiStore.aiLastResult = result.message; });
      return;
    }
    if (this.pendingAskUserResolve !== null) {
      const pendingReq: AiAskUserRequest | null = this.aiStore.aiPendingAskUser;
      const resolver = this.pendingAskUserResolve;
      this.pendingAskUserResolve = null;
      this.aiStore.aiPendingAskUser = null;
      resolver({
        id: pendingReq?.id ?? 'cancelled',
        question: pendingReq?.question ?? '',
        context: pendingReq?.context,
        options: pendingReq?.options ?? [],
        multiSelect: pendingReq?.multiSelect ?? false,
        selectedLabels: [],
        customText: '',
        skipped: true
      });
    }
    if (this.aiPythonPhase === 'dsh_native') {
      dshLayoutAgentService.cancel();
      this.aiStore.aiLastResult = '已停止当前 Agent 推理；已完成步骤保留，可随时一键撤销版图修改';
      this.panelStore.statusText = this.aiStore.aiLastResult;
      return;
    }
    if (this.aiPythonPhase === 'harness') {
      const cancelledGeneration: number = this.aiRequestGeneration;
      const cancelledConversation: string = this.aiStore.aiActiveConversationId;
      aiHarnessService.cancelAndConfirm().then((message: string): void => {
        try { aiService.recordExecutionReceipt(message, cancelledConversation); } catch (_) {}
        if (this.pageAlive && cancelledGeneration === this.aiRequestGeneration && cancelledConversation === this.aiStore.aiActiveConversationId) {
          this.aiStore.aiLastResult = message; this.panelStore.statusText = message;
          try { this.refreshAiConversation(); } catch (_) {}
        }
      });
    } else if (this.aiPythonPhase === 'compression') aiHarnessService.cancel();
    if (this.aiPythonPhase === 'artifact') pythonBridgeService.cancelGeneration();
    this.aiStore.aiLastResult = this.aiPythonPhase === 'compression' ? '已取消压缩等待，原上下文与版图保留' :
      '已取消生成等待，后续结果不应用；后台工具可能仍在收尾，原文档未修改';
    this.panelStore.statusText = this.aiStore.aiLastResult;
  }

  private assertAiRequestCurrent(ticket: number, context: string): void {
    if (!this.pageAlive) throw new Error('页面已退出，AI 结果未应用');
    if (ticket !== this.aiRequestGeneration) throw new Error('AI 生成已取消');
    if (context !== this.aiRequestContext()) throw new Error('生成期间版图已切换或修改，原文档保留，请重新生成');
  }

  private aiCircuitValidationProfile(prompt: string): 'generic_inverter' | undefined {
    return aiService.agentValidationProfile(prompt);
  }

  private aiDrcResultSummary(): string {
    const result = drcService.getLastResult();
    if (!this.verifyStore.drcHasRun || this.drcSnapshotRevision !== this.docStore.editorRevision || result === null) return '当前规则检查未完成';
    const counts: string = `${result.errors} 错误 / ${result.warnings} 警告 / ${result.completenessNotices} 项完整性提示`;
    if (result.executedRules === 0) return `未进行设计规则检查：没有可执行规则（${counts}），不能判定通过`;
    return `已执行 ${result.executedRules}/${result.totalRules} 条规则：${counts}` +
      (result.completenessNotices > 0 || result.executedRules < result.totalRules ? '，检查不完整，不能判定通过' : '');
  }

  private aiGeneratedViewContext(): string {
    return `${this.aiRequestContext()}:${this.viewportStore.zoomPercent}:${this.viewportStore.viewOffsetX}:${this.viewportStore.viewOffsetY}:` +
      `${this.docStore.hierarchyDepth}:${this.viewportStore.currentModule}:${this.verifyStore.drcDockCollapsed}:` +
      this.docStore.layers.map((layer: UiLayer): string => `${layer.layerNumber}/${layer.datatype}/${layer.visible}`).join(',');
  }

  private scheduleAiGeneratedFit(ticket: number): void {
    if (this.aiGeneratedFitTimer >= 0) clearTimeout(this.aiGeneratedFitTimer);
    if (this.aiGeneratedFitFallbackTimer >= 0) clearTimeout(this.aiGeneratedFitFallbackTimer);
    let expected: string = this.aiGeneratedViewContext();
    const refit: () => void = (): void => {
      if (this.aiGeneratedFitAction !== refit) return;
      if (ticket !== this.aiRequestGeneration || expected !== this.aiGeneratedViewContext()) {
        this.aiGeneratedFitAction = null; return;
      }
      const status: string = this.panelStore.statusText;
      this.fitAllShapes();
      this.panelStore.statusText = status;
      expected = this.aiGeneratedViewContext();
    };
    this.aiGeneratedFitAction = refit;
    // The measured viewport callback handles DRC reflow. Also fit when the dock was already open.
    this.aiGeneratedFitFallbackTimer = setTimeout((): void => { refit(); this.aiGeneratedFitFallbackTimer = -1; }, 0);
    // Keep a bounded window for subsequent layout passes, without taking over later user navigation.
    this.aiGeneratedFitTimer = setTimeout((): void => {
      if (this.aiGeneratedFitAction === refit) this.aiGeneratedFitAction = null;
      this.aiGeneratedFitTimer = -1;
    }, 1000);
  }

  private setAiLocalStage(ticket: number, stage: string, status: 'running' | 'completed' | 'failed', detail: string): void {
    if (!this.pageAlive || ticket !== this.aiRequestGeneration) return;
    const names: string[] = ['download', 'parse', 'activate', 'drc'];
    const titles: string[] = ['下载并校验版图', '解析图形与图层', '打开独立版图', '检查当前规则'];
    const position: number = names.indexOf(stage);
    if (position < 0) return;
    const id: string = `native:${ticket}:${stage}`;
    const item: AiChatToolState = { id, name: titles[position], status, arguments: '', result: detail.substring(0, 4000) };
    const next: AiChatToolState[] = this.aiStore.aiToolCalls.slice();
    const index: number = next.findIndex((entry: AiChatToolState): boolean => entry.id === id);
    if (index < 0) next.push(item); else next[index] = item;
    this.aiStore.aiToolCalls = next;
    if (status === 'running') this.panelStore.statusText = detail;
  }

  private ensureDshLayerExists(layerNumber: number, datatype: number, englishName: string, chineseName: string, colorHex: string): void {
    const exists: boolean = this.docStore.layers.some(
      (l: UiLayer): boolean => l.layerNumber === layerNumber && l.datatype === datatype
    );
    if (exists) {
      return;
    }
    const created: UiLayer = {
      layerNumber,
      datatype,
      englishName: englishName.length > 0 ? englishName : `L${layerNumber}_${datatype}`,
      chineseName: chineseName.length > 0 ? chineseName : (englishName.length > 0 ? englishName : `图层 ${layerNumber}/${datatype}`),
      color: colorHex,
      visible: true,
      locked: false,
      selectable: true,
      group: LayerGroup.INTERCONNECT,
      elementCount: 0
    };
    this.docStore.layers = this.docStore.layers.concat([created]);
    this.syncLayerVisibilityMirror();
  }

  private executeDshInverterGeometry(params: DshCmosInverterParams, permission: DshPermissionMode): DshToolExecutionOutcome {
    const gl: number = Math.max(50, Math.round(params.gateLengthNm));
    const nw: number = Math.max(100, Math.round(params.nmosWidthNm));
    const pw: number = Math.max(100, Math.round(params.pmosWidthNm));
    const unit: number = Math.max(3, Math.min(gl, nw, pw));
    const cut: number = Math.max(1, Math.floor(unit / 3));
    const metal: number = 3 * cut;
    const sdWidth: number = 4 * unit;
    const span: number = 2 * sdWidth + gl;
    const gateX: number = sdWidth;
    const gap: number = 6 * unit;
    const ny: number = 0;
    const py: number = nw + gap;
    const railH: number = 2 * unit;
    const vssY: number = -4 * unit - railH;
    const vddY: number = py + pw + 4 * unit;
    const outX: number = span + 2 * unit;
    const tapSize: number = 3 * cut;
    const tapX: number = span + 4 * unit + Math.floor(unit / 2);
    const ntapY: number = vssY + Math.floor((railH - tapSize) / 2);
    const ptapY: number = vddY + Math.floor((railH - tapSize) / 2);
    const inContactX: number = gateX - sdWidth;
    const inPadX: number = inContactX - cut;
    const midY: number = nw + Math.floor(gap / 2);
    const nCy: number = ny + Math.floor((nw - cut) / 2);
    const pCy: number = py + Math.floor((pw - cut) / 2);
    const sxL: number = Math.floor((sdWidth - cut) / 2);
    const dxR: number = sdWidth + gl + Math.floor((sdWidth - cut) / 2);
    const nwellMargin: number = 3 * unit;

    const commands: ParsedCommand[] = [
      // 1/0 NWELL covering PMOS + VDD PTAP
      { type: AiCommandType.CREATE_RECT, params: { layer: 1, datatype: 0, x: -nwellMargin, y: py - nwellMargin, width: (tapX + tapSize + 2 * unit) - (-nwellMargin), height: (ptapY + tapSize + 2 * unit) - (py - nwellMargin) }, description: 'NWELL (1/0) PMOS 与衬底接触阱区' },
      // 2/0 ACTIVE (NMOS, PMOS, NTAP, PTAP)
      { type: AiCommandType.CREATE_RECT, params: { layer: 2, datatype: 0, x: 0, y: ny, width: span, height: nw }, description: `NMOS 有源区 ${span}×${nw}nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: 2, datatype: 0, x: 0, y: py, width: span, height: pw }, description: `PMOS 有源区 ${span}×${pw}nm` },
      { type: AiCommandType.CREATE_RECT, params: { layer: 2, datatype: 0, x: tapX, y: ntapY, width: tapSize, height: tapSize }, description: 'VSS P+ 衬底接触有源区' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 2, datatype: 0, x: tapX, y: ptapY, width: tapSize, height: tapSize }, description: 'VDD N+ 阱接触有源区' },
      // 4/0 NPLUS (NMOS + PTAP) & 5/0 PPLUS (PMOS + NTAP)
      { type: AiCommandType.CREATE_RECT, params: { layer: 4, datatype: 0, x: -unit, y: ny - unit, width: span + 2 * unit, height: nw + 2 * unit }, description: 'NMOS N+ 注入区 (4/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 4, datatype: 0, x: tapX - unit, y: ptapY - unit, width: tapSize + 2 * unit, height: tapSize + 2 * unit }, description: 'VDD N+ 阱接触注入 (4/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 5, datatype: 0, x: -unit, y: py - unit, width: span + 2 * unit, height: pw + 2 * unit }, description: 'PMOS P+ 注入区 (5/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 5, datatype: 0, x: tapX - unit, y: ntapY - unit, width: tapSize + 2 * unit, height: tapSize + 2 * unit }, description: 'VSS P+ 衬底接触注入 (5/0)' },
      // 3/0 POLY gate + input extension
      { type: AiCommandType.CREATE_RECT, params: { layer: 3, datatype: 0, x: gateX, y: ny - 2 * unit, width: gl, height: (py + pw + 2 * unit) - (ny - 2 * unit) }, description: `多晶硅共栅 ${gl}nm (3/0)` },
      { type: AiCommandType.CREATE_RECT, params: { layer: 3, datatype: 0, x: inPadX, y: midY - cut - Math.floor(cut / 2), width: (gateX + gl) - inPadX, height: 3 * cut }, description: '多晶硅栅输入引出端 (3/0)' },
      // 6/0 CONTACT cuts (NMOS S/D, PMOS S/D, Gate IN, NTAP, PTAP)
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: sxL, y: nCy, width: cut, height: cut }, description: 'NMOS 源极接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: dxR, y: nCy, width: cut, height: cut }, description: 'NMOS 漏极接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: sxL, y: pCy, width: cut, height: cut }, description: 'PMOS 源极接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: dxR, y: pCy, width: cut, height: cut }, description: 'PMOS 漏极接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: inContactX, y: midY - Math.floor(cut / 2), width: cut, height: cut }, description: '输入栅接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: tapX + cut, y: ntapY + cut, width: cut, height: cut }, description: 'VSS 衬底接触孔 (6/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 6, datatype: 0, x: tapX + cut, y: ptapY + cut, width: cut, height: cut }, description: 'VDD 阱接触孔 (6/0)' },
      // 7/0 METAL1 rails, S/D straps, IN pad & OUT bus
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: -2 * unit, y: vssY, width: (tapX + tapSize + 2 * unit) - (-2 * unit), height: railH }, description: 'VSS 金属1 电源轨 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: -2 * unit, y: vddY, width: (tapX + tapSize + 2 * unit) - (-2 * unit), height: railH }, description: 'VDD 金属1 电源轨 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: tapX, y: Math.min(vssY, ntapY), width: tapSize, height: Math.max(vssY + railH, ntapY + tapSize) - Math.min(vssY, ntapY) }, description: 'VSS 衬底接触金属连线 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: tapX, y: Math.min(vddY, ptapY), width: tapSize, height: Math.max(vddY + railH, ptapY + tapSize) - Math.min(vddY, ptapY) }, description: 'VDD 阱接触金属连线 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: sxL - cut, y: vssY, width: metal, height: (nCy + 2 * cut) - vssY }, description: 'NMOS 源极接 VSS 金属条 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: sxL - cut, y: pCy - cut, width: metal, height: (vddY + railH) - (pCy - cut) }, description: 'PMOS 源极接 VDD 金属条 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: dxR - cut, y: nCy - cut, width: (outX + metal) - (dxR - cut), height: metal }, description: 'NMOS 漏极输出支路 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: dxR - cut, y: pCy - cut, width: (outX + metal) - (dxR - cut), height: metal }, description: 'PMOS 漏极输出支路 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: outX, y: nCy - cut, width: metal, height: (pCy + 2 * cut) - (nCy - cut) }, description: 'OUT 漏极汇流金属线 (7/0)' },
      { type: AiCommandType.CREATE_RECT, params: { layer: 7, datatype: 0, x: inPadX, y: midY - cut - Math.floor(cut / 2), width: metal, height: 3 * cut }, description: 'IN 输入金属焊盘 (7/0)' },
      // 8/0 PIN_LABEL
      { type: AiCommandType.CREATE_TEXT, params: { layer: 8, datatype: 0, x: inPadX, y: midY, text: 'IN' }, description: '端口标签 IN (8/0)' },
      { type: AiCommandType.CREATE_TEXT, params: { layer: 8, datatype: 0, x: outX + metal, y: midY, text: 'OUT' }, description: '端口标签 OUT (8/0)' },
      { type: AiCommandType.CREATE_TEXT, params: { layer: 8, datatype: 0, x: 0, y: vssY + Math.floor(railH / 2), text: 'VSS' }, description: '端口标签 VSS (8/0)' },
      { type: AiCommandType.CREATE_TEXT, params: { layer: 8, datatype: 0, x: 0, y: vddY + Math.floor(railH / 2), text: 'VDD' }, description: '端口标签 VDD (8/0)' }
    ];

    if (permission === 'review') {
      const ctx: AiContext = this.filteredAiContext(this.buildAiContext());
      this.aiStore.pendingAiCommands = commands;
      this.aiStore.pendingAiContext = ctx;
      this.pendingAiRevision = this.docStore.editorRevision;
      this.pendingAiDocumentId = this.docStore.activeWorkspaceId;
      this.pendingAiSelection = editService.getSelectedIds().join(',');
      this.pendingAiCell = editService.getCurrentCellId();
      this.pendingAiLayer = this.viewportStore.selectedLayerNumber;
      this.pendingAiDatatype = this.viewportStore.selectedDatatype;
      this.prepareAiReview(commands);
      return {
        success: true,
        stagedPending: true,
        summary: `已生成 CMOS 反相器预览方案（${commands.length} 项图元），等待确认写入`,
        payloadJson: JSON.stringify({
          success: true,
          stagedPending: true,
          cellName: params.cellName,
          operations: commands.length,
          message: '已在画布生成 CMOS 反相器几何预览，待用户点击「应用修改」后写入。'
        })
      };
    }

    if (!this.assertEditMode()) {
      this.setViewMode(ViewMode.EDIT);
    }

    // Decide whether to write in-place or create a clean tab
    const currentShapesInCell: number = editService.getShapes().filter(
      (s: Shape): boolean => (s.ownerCellId ?? editService.getTopCellId()) === editService.getCurrentCellId()
    ).length;
    if (params.target === 'new_tab' || (params.target === 'auto' && currentShapesInCell > 0)) {
      if (!this.isCurrentWorkspaceTabEmptyReusable() && this.docStore.workspaceTabs.length < MAX_WORKSPACE_TABS) {
        this.createWorkspaceDocument('GENERIC_CMOS', params.cellName, 1);
      }
    } else if (currentShapesInCell === 0 && params.cellName.length > 0 &&
      this.docStore.currentEditingCellName !== params.cellName) {
      this.performRenameCell(editService.getCurrentCellId(), params.cellName);
    }

    // Ensure standard 8 generic CMOS layers exist with clear EDA colors
    this.ensureDshLayerExists(1, 0, 'NWELL', 'N阱', '#D97706');
    this.ensureDshLayerExists(2, 0, 'ACTIVE', '有源区', '#16A34A');
    this.ensureDshLayerExists(3, 0, 'POLY', '多晶硅栅', '#DC2626');
    this.ensureDshLayerExists(4, 0, 'NPLUS', 'N+注入', '#CA8A04');
    this.ensureDshLayerExists(5, 0, 'PPLUS', 'P+注入', '#9333EA');
    this.ensureDshLayerExists(6, 0, 'CONTACT', '接触孔', '#64748B');
    this.ensureDshLayerExists(7, 0, 'METAL1', '金属1', '#2563EB');
    this.ensureDshLayerExists(8, 0, 'PIN_LABEL', '端口标签', '#0891B2');

    const execCtx: AiContext = this.buildAiContext();
    const before: EditStructureState = this.cellStructureState();
    const after: EditStructureState = this.cellStructureState();
    const beforeMarker: Object | null = editService.getUndoMarker();
    const baseSession: EditSessionState = editService.captureSession();
    const createdIds: number[] = [];
    let nextShapes: Shape[] = [];
    editService.beginBatch();
    try {
      for (let i = 0; i < commands.length; i++) {
        const res: CommandResult = aiExecutor.execute(commands[i], execCtx);
        if (!res.success) return { success: false, summary: res.message, payloadJson: JSON.stringify(res) };
        createdIds.push(...res.affectedShapeIds);
      }
      nextShapes = editService.getShapes().slice();
    } finally {
      editService.endBatch();
      editService.restoreSession(baseSession);
    }
    const createdCount: number = createdIds.length;

    // Add 4 semantic ports (IN, OUT, VSS, VDD) to current cell
    const ownerCell: number = editService.getCurrentCellId();
    const portDefs: Array<[string, number, number, number, number]> = [
      ['IN', inPadX, midY, 180, 3 * cut],
      ['OUT', outX + metal, midY, 0, 3 * cut],
      ['VSS', -2 * unit, vssY + Math.floor(railH / 2), 180, railH],
      ['VDD', -2 * unit, vddY + Math.floor(railH / 2), 180, railH]
    ];
    const ownerKey: string = (before.cellKeys ?? [])[ownerCell];
    const ports: LayoutPort[] = this.docPorts.slice();
    for (const pDef of portDefs) {
      const draft: LayoutPortDraft = {
        name: pDef[0], centerNm: { x: pDef[1], y: pDef[2] }, orientationDeg: pDef[3], widthNm: pDef[4],
        layerNumber: 7, datatype: 0, portType: 'electrical', frameMirror: false, frameMagnification: 1, infoJson: '{}'
      };
      const existingIdx: number = ports.findIndex((p: LayoutPort): boolean => p.ownerCellId === ownerCell && p.name === draft.name);
      if (existingIdx >= 0) {
        ports[existingIdx] = portFromDraft(ports[existingIdx].id, ownerCell, ownerKey, draft);
      } else {
        ports.push(portFromDraft(newLayoutIdentity('port'), ownerCell, ownerKey, draft));
      }
    }
    const addedPorts: number = ports.length - this.docPorts.length;
    after.ports = ports;
    if (!editService.applyDocumentStructure(nextShapes, before, after, '生成 CMOS 反相器', true, createdIds)) {
      return { success: false, summary: '无法写入反相器图形或端口，请检查图层的可编辑状态', payloadJson: '{"success":false}' };
    }

    this.syncShapesFromEditService();
    this.rebuildCellTree();
    this.fitAllShapes();
    this.aiUndoMarker = editService.getUndoMarker();
    this.aiStore.aiCanUndo = this.aiUndoMarker !== beforeMarker;
    this.scheduleWorkspaceDraft();

    let drcSummary: string = '';
    try {
      this.runDrc(true);
      drcSummary = this.aiDrcResultSummary();
    } catch (e) {
      drcSummary = `DRC 复检跳过：${String(e)}`;
    }

    return {
      success: true,
      addedShapes: createdCount,
      addedPorts,
      drcSummary,
      summary: `已在单元 ${this.docStore.currentEditingCellName} 原生生成 CMOS 反相器（${createdCount} 个图元，${addedPorts} 个端口）`,
      payloadJson: JSON.stringify({
        success: true,
        cellName: this.docStore.currentEditingCellName,
        gateLengthNm: gl,
        nmosWidthNm: nw,
        pmosWidthNm: pw,
        addedShapes: createdCount,
        addedPorts,
        layers: ['1/0 NWELL', '2/0 ACTIVE', '3/0 POLY', '4/0 NPLUS', '5/0 PPLUS', '6/0 CONTACT', '7/0 METAL1', '8/0 PIN_LABEL'],
        ports: ['IN', 'OUT', 'VSS', 'VDD'],
        drcSummary,
        note: '通用 CMOS 教学/工程几何版图（未绑定晶圆厂 PDK 签核规则）'
      })
    };
  }

  private resolvePendingAskUser(exchange: AiAskUserExchange): void {
    const resolver = this.pendingAskUserResolve;
    this.pendingAskUserResolve = null;
    this.aiStore.aiPendingAskUser = null;
    if (resolver !== null) {
      resolver(exchange);
    }
  }

  private async pickAiPhotosForChat(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const picked: AiChatAttachment[] = await aiAttachmentService.pickPhotos(context, 6);
      if (picked.length > 0) {
        this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.concat(picked).slice(0, 12);
        this.panelStore.statusText = `已添加 ${picked.length} 张图片附件`;
      }
    } catch (e) {
      this.panelStore.statusText = `选择图片未完成：${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private async pickAiFilesForChat(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const picked: AiChatAttachment[] = await aiAttachmentService.pickFiles(context, 6);
      if (picked.length > 0) {
        this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.concat(picked).slice(0, 12);
        this.panelStore.statusText = `已添加 ${picked.length} 个文件附件`;
      }
    } catch (e) {
      this.panelStore.statusText = `选择文件未完成：${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private async attachCurrentCanvasSnapshotToChat(): Promise<void> {
    try {
      const outcome: DshToolExecutionOutcome = await this.captureWorkbenchOrCanvasPng('canvas_viewport', 1440, 960, false, false);
      const att: AiChatAttachment | undefined = outcome.visualAttachment ?? outcome.generatedAttachment;
      if (att !== undefined) {
        this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.concat([att]).slice(0, 12);
        this.panelStore.statusText = `已截取当前画布快照 (${att.summary ?? att.name})`;
      } else {
        this.panelStore.statusText = outcome.summary;
      }
    } catch (e) {
      this.panelStore.statusText = `画布截图未完成：${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private async pasteClipboardIntoAiChat(): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const res: AiClipboardPasteResult = await aiAttachmentService.readClipboard(context);
      if (res.attachments.length > 0) {
        this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.concat(res.attachments).slice(0, 12);
      }
      this.panelStore.statusText = res.statusMessage;
      showAppToast(this.getUIContext(), res.statusMessage, AppToastDuration.SHORT);
    } catch (e) {
      this.panelStore.statusText = `剪贴板粘贴失败：${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private ingestDroppedUrisIntoAiChat(uris: string[]): void {
    if (uris.length === 0) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const added: AiChatAttachment[] = [];
      for (let i = 0; i < uris.length && added.length < 8; i++) {
        try {
          added.push(aiAttachmentService.ingestUri(context, uris[i]));
        } catch (_) {}
      }
      if (added.length > 0) {
        this.aiStore.aiPendingAttachments = this.aiStore.aiPendingAttachments.concat(added).slice(0, 12);
        this.panelStore.statusText = `已拖入 ${added.length} 个附件`;
      }
    } catch (e) {
      this.panelStore.statusText = `拖入附件处理未完成：${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private async copyAiAttachmentToClipboard(att: AiChatAttachment): Promise<void> {
    const msg: string = await aiAttachmentService.copyAttachmentToClipboard(att);
    this.panelStore.statusText = msg;
    showAppToast(this.getUIContext(), msg, AppToastDuration.SHORT);
  }

  private async saveAiAttachmentAs(att: AiChatAttachment): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const msg: string = await aiAttachmentService.saveAttachmentToUserFile(context, att);
    if (msg.length === 0) return;
    this.panelStore.statusText = msg;
    showAppToast(this.getUIContext(), msg, AppToastDuration.SHORT);
  }

  private async openAiLayoutAttachment(att: AiChatAttachment, mode: 'new_tab' | 'merge'): Promise<boolean> {
    if (att.kind !== 'layout') {
      this.panelStore.statusText = '该附件不是 GDSII/OASIS 版图文件';
      return false;
    }
    const revision: string = `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`;
    if (mode === 'merge') {
      const artifact: PythonLayoutArtifact = {
        name: att.name,
        path: att.sandboxPath,
        previewPath: '',
        summary: att.summary ?? att.name,
        stdout: '',
        sourceRevision: this.docStore.editorRevision
      };
      const curRev: number = this.docStore.editorRevision;
      return await this.applyPythonResult(artifact, 'merge', curRev, (): boolean => this.pageAlive);
    }
    await this.loadGeneratedPython(att.sandboxPath, att.name, (): boolean =>
      this.pageAlive && `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}` === revision
    );
    return true;
  }

  private addNewLayerQuick(): void {
    let nextNum: number = 1;
    const used: Set<number> = new Set<number>(this.docStore.layers.map((l: UiLayer): number => l.layerNumber));
    while (used.has(nextNum) && nextNum < 32767) nextNum++;
    const color: string = this.layerColor(this.docStore.layers.length);
    this.ensureDshLayerExists(nextNum, 0, `LAYER_${nextNum}`, `自定义层 ${nextNum}`, color);
    this.viewportStore.selectedLayerNumber = nextNum;
    this.viewportStore.selectedDatatype = 0;
    this.docStore.editorRevision++;
    this.scheduleWorkspaceDraft();
    this.panelStore.statusText = `已新建并激活图层 L${nextNum}/D0`;
  }

  private clearShapesOnLayer(layerNumber: number, datatype: number, currentCellOnly: boolean = false): number {
    if (!this.assertEditMode()) {
      this.setViewMode(ViewMode.EDIT);
    }
    const curCell: number = editService.getCurrentCellId();
    const targets: number[] = editService.getShapes()
      .filter((s: Shape): boolean =>
        s.type !== ShapeType.INSTANCE &&
        s.type !== ShapeType.NODE &&
        s.layerNumber === layerNumber &&
        s.datatype === datatype &&
        (!currentCellOnly || (s.ownerCellId ?? editService.getTopCellId()) === curCell)
      )
      .map((s: Shape): number => s.id);
    if (targets.length === 0) {
      this.panelStore.statusText = `图层 L${layerNumber}/D${datatype} 当前无图形可清空`;
      return 0;
    }
    const deleted: number[] = editService.deleteShapesWithSelectionHistory(targets);
    this.syncShapesFromEditService();
    this.scheduleWorkspaceDraft();
    this.panelStore.statusText = `已清空图层 L${layerNumber}/D${datatype} 上的 ${deleted.length} 个图形（Ctrl+Z 可撤销）`;
    return deleted.length;
  }

  private deleteLayerWithUndo(layerNumber: number, datatype: number, deleteShapes: boolean = true): boolean {
    if (!this.assertEditMode()) {
      this.setViewMode(ViewMode.EDIT);
    }
    if (this.docStore.layers.length <= 1) {
      this.panelStore.statusText = '至少需保留 1 个有效绘图层，无法删除最后一个图层';
      return false;
    }
    const exists: boolean = this.docStore.layers.some((l: UiLayer): boolean => l.layerNumber === layerNumber && l.datatype === datatype);
    if (!exists) {
      this.panelStore.statusText = `图层 L${layerNumber}/D${datatype} 不存在`;
      return false;
    }
    const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
    let removedShapes: number = 0;
    if (deleteShapes) {
      const kept: Shape[] = [];
      for (let i = 0; i < candidate.shapes.length; i++) {
        const s: Shape = candidate.shapes[i];
        if (s.type !== ShapeType.INSTANCE && s.type !== ShapeType.NODE && s.layerNumber === layerNumber && s.datatype === datatype) {
          removedShapes++;
          continue;
        }
        kept.push(s);
      }
      candidate.shapes = kept;
      candidate.selectedIds = candidate.selectedIds.filter((id: number): boolean => kept.some((s: Shape): boolean => s.id === id));
    }
    candidate.layers = candidate.layers.filter((l: UiLayer): boolean => !(l.layerNumber === layerNumber && l.datatype === datatype));
    if (candidate.layers.length === 0) {
      this.panelStore.statusText = '至少需保留 1 个图层';
      return false;
    }
    if (candidate.layerDefinitions !== undefined) {
      candidate.layerDefinitions = candidate.layerDefinitions.filter(
        (d: SourceLayerDefinition): boolean => !(d.layer.lower === layerNumber && d.layer.upper === layerNumber &&
          d.datatype.lower === datatype && d.datatype.upper === datatype)
      );
    }
    if (!this.commitCellStructure(candidate, candidate.selectedIds, true)) {
      return false;
    }
    if (this.viewportStore.selectedLayerNumber === layerNumber && this.viewportStore.selectedDatatype === datatype) {
      this.viewportStore.selectedLayerNumber = this.docStore.layers[0].layerNumber;
      this.viewportStore.selectedDatatype = this.docStore.layers[0].datatype;
    }
    this.syncLayerVisibilityMirror();
    this.scheduleWorkspaceDraft();
    this.panelStore.statusText = `已删除图层 L${layerNumber}/D${datatype}${removedShapes > 0 ? `（连同清理 ${removedShapes} 个图形）` : ''}，可一键撤销`;
    return true;
  }

  private deleteAllEmptyLayersWithUndo(): number {
    if (!this.assertEditMode()) {
      this.setViewMode(ViewMode.EDIT);
    }
    const nonEmptyKeys: Set<string> = new Set<string>();
    for (const s of editService.getShapes()) {
      if (s.type === ShapeType.INSTANCE || s.type === ShapeType.NODE) continue;
      nonEmptyKeys.add(`${s.layerNumber}:${s.datatype}`);
    }
    for (const p of this.docPorts) {
      nonEmptyKeys.add(`${p.layerNumber}:${p.datatype}`);
    }
    const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
    const beforeLen: number = candidate.layers.length;
    let filtered: UiLayer[] = candidate.layers.filter((l: UiLayer): boolean => nonEmptyKeys.has(`${l.layerNumber}:${l.datatype}`));
    if (filtered.length === 0 && candidate.layers.length > 0) {
      filtered = [candidate.layers[0]];
    }
    const removedCount: number = beforeLen - filtered.length;
    if (removedCount <= 0) {
      this.panelStore.statusText = '当前没有可清理的空图层';
      return 0;
    }
    candidate.layers = filtered;
    if (!this.commitCellStructure(candidate)) {
      return 0;
    }
    if (!this.docStore.layers.some((l: UiLayer): boolean =>
      l.layerNumber === this.viewportStore.selectedLayerNumber && l.datatype === this.viewportStore.selectedDatatype)) {
      this.viewportStore.selectedLayerNumber = this.docStore.layers[0].layerNumber;
      this.viewportStore.selectedDatatype = this.docStore.layers[0].datatype;
    }
    this.syncLayerVisibilityMirror();
    this.scheduleWorkspaceDraft();
    this.panelStore.statusText = `已清理 ${removedCount} 个无图元空图层（可撤销）`;
    return removedCount;
  }

  private async captureWorkbenchOrCanvasPng(
    target: string,
    widthPx: number,
    heightPx: number,
    showInChat: boolean,
    fitBeforeCapture: boolean
  ): Promise<DshToolExecutionOutcome> {
    if (fitBeforeCapture && (editService.getCurrentCellShapes().length > 0 || this.docPorts.length > 0)) {
      this.fitAllShapes();
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let capturedAttachment: AiChatAttachment | undefined = undefined;
    let captureMethod: string = '';

    if (target === 'workbench_window' || target === 'canvas_viewport') {
      let pixmap: image.PixelMap | null = null;
      try {
        if (target === 'workbench_window') {
          try {
            const win = await window.getLastWindow(context);
            pixmap = await win.snapshot();
            captureMethod = 'window.snapshot';
          } catch (_) {
            pixmap = await componentSnapshot.get('hongtu-workbench-root');
            captureMethod = 'componentSnapshot(workbench)';
          }
        } else {
          pixmap = await componentSnapshot.get('hongtu-canvas-stage');
          captureMethod = 'componentSnapshot(canvas)';
        }
        if (pixmap !== null) {
          capturedAttachment = await aiAttachmentService.savePixelMapAsAttachment(
            context,
            pixmap,
            `${this.currentShareBaseName()}_${target}.png`
          );
        }
      } catch (_) {
        // Fallback to C++ native rasterizer below when componentSnapshot is offscreen or unavailable
      } finally {
        try { if (pixmap !== null) await pixmap.release(); } catch (_) {}
      }
    }

    if (capturedAttachment === undefined) {
      if (this.synchronizeCurrentDocument()) {
        const safeW: number = Math.min(4096, Math.max(320, Math.round(widthPx)));
        const safeH: number = Math.min(4096, Math.max(240, Math.round(heightPx)));
        try {
          const exported = layoutExportService.exportImageToCacheForShare(
            'png',
            context.cacheDir,
            `${this.currentShareBaseName()}_render`,
            this.buildExportLayerStyles(),
            safeW,
            safeH
          );
          capturedAttachment = aiAttachmentService.adoptSandboxFile(
            context,
            exported.sandboxPath,
            exported.fileName,
            'image/png'
          );
          captureMethod = 'nativeLayoutRasterizerPng';
        } catch (err) {
          return {
            success: false,
            summary: `截图生成未完成：${err instanceof Error ? err.message : String(err)}`,
            payloadJson: JSON.stringify({
              success: false,
              error: err instanceof Error ? err.message : String(err),
              uiState: JSON.parse(this.inspectCurrentWorkbenchUiJson()) as Object
            })
          };
        }
      }
    }

    if (capturedAttachment === undefined) {
      return {
        success: false,
        summary: '当前画布尚无图形且组件离屏，已返回结构化 UI 状态',
        payloadJson: JSON.stringify({
          success: false,
          error: '当前无法生成位图快照，请参考 uiState 结构化状态',
          uiState: JSON.parse(this.inspectCurrentWorkbenchUiJson()) as Object
        })
      };
    }

    const summaryText: string = `已完成 ${target === 'workbench_window' ? '软件整窗' : (target === 'layout_render' ? '版图高清光栅' : '画布视口')}截图 (${capturedAttachment.width ?? widthPx}×${capturedAttachment.height ?? heightPx} px)`;
    return {
      success: true,
      summary: summaryText,
      visualAttachment: capturedAttachment,
      generatedAttachment: showInChat ? capturedAttachment : undefined,
      payloadJson: JSON.stringify({
        success: true,
        target,
        method: captureMethod,
        fileName: capturedAttachment.name,
        width: capturedAttachment.width ?? widthPx,
        height: capturedAttachment.height ?? heightPx,
        sizeBytes: capturedAttachment.sizeBytes,
        visionInjected: true,
        currentCell: this.docStore.currentEditingCellName,
        zoomPercent: this.viewportStore.zoomPercent,
        shapeCount: editService.getShapes().length,
        visibleLayers: this.visibleLayerNumbers().length
      })
    };
  }

  private inspectCurrentWorkbenchUiJson(): string {
    const scalePxPerNm: number = Math.max(1e-6, this.viewportStore.zoomPercent / 100);
    const vpW: number = Math.max(1, this.viewportStore.canvasViewportWidth);
    const vpH: number = Math.max(1, this.viewportStore.canvasViewportHeight);
    const minWorldX: number = Math.round(-this.viewportStore.viewOffsetX / scalePxPerNm);
    const maxWorldX: number = Math.round((vpW - this.viewportStore.viewOffsetX) / scalePxPerNm);
    const maxWorldY: number = Math.round(this.viewportStore.viewOffsetY / scalePxPerNm);
    const minWorldY: number = Math.round((this.viewportStore.viewOffsetY - vpH) / scalePxPerNm);
    const pyInfo = nativeHongTuService.getEmbeddedPythonInfo();
    const snapshot: DshWorkbenchSnapshot = {
      window: {
        widthVp: this.panelStore.windowWidthVp,
        heightVp: this.panelStore.windowHeightVp,
        deviceType: this.panelStore.currentDevice,
        desktopMode: this.isDesktopWorkspace(),
        themeMode: this.themeState.themeMode,
        isDark: this.themeState.isDark
      },
      currentModule: this.viewportStore.currentModule,
      viewMode: this.viewportStore.currentViewMode === ViewMode.EDIT ? 'edit' : 'viewer',
      activeTool: this.viewportStore.currentTool,
      activeLayer: {
        layer: this.viewportStore.selectedLayerNumber,
        datatype: this.viewportStore.selectedDatatype
      },
      camera: {
        zoomPercent: this.viewportStore.zoomPercent,
        viewOffsetX: Math.round(this.viewportStore.viewOffsetX),
        viewOffsetY: Math.round(this.viewportStore.viewOffsetY),
        hierarchyDepth: this.docStore.hierarchyDepth,
        viewportWorldBoundsNm: {
          minX: Math.min(minWorldX, maxWorldX),
          minY: Math.min(minWorldY, maxWorldY),
          maxX: Math.max(minWorldX, maxWorldX),
          maxY: Math.max(minWorldY, maxWorldY)
        }
      },
      gridAndSnap: {
        gridVisible: this.viewportStore.gridVisible,
        gridSizeNm: this.viewportStore.gridSize,
        snapEnabled: this.viewportStore.snapEnabled,
        geometrySnapEnabled: this.viewportStore.geometrySnapEnabled,
        smartGuidesEnabled: this.viewportStore.smartGuidesEnabled,
        routingMode: this.viewportStore.routingMode
      },
      panels: {
        sidebarVisible: this.panelStore.sidebarVisible,
        inspectorVisible: this.panelStore.inspectorVisible,
        drcDockOpen: !this.verifyStore.drcDockCollapsed,
        aiPanel: this.panelStore.showAiPanel,
        pythonPanel: this.panelStore.showPythonPanel,
        verificationPanel: this.panelStore.showVerificationPanel,
        lvsPanel: this.panelStore.showLvsPanel,
        macroPanel: this.panelStore.showMacroPanel,
        libraryPanel: this.panelStore.showLibraryPanel,
        technologyPanel: this.panelStore.showTechnologyPanel,
        layerStackPanel: this.panelStore.showLayerStackPanel,
        comparePanel: this.panelStore.showComparePanel,
        rdbReviewPanel: this.panelStore.showRdbReviewPanel,
        searchPanel: this.panelStore.showSearchPanel,
        projectPanel: this.panelStore.showProjectPanel,
        viewWorkspacePanel: this.panelStore.showViewWorkspacePanel
      },
      rulersCount: this.measureStore.rulers.length,
      embeddedPython: pyInfo,
      pythonExecutionMode: pythonBridgeService.getExecutionMode(),
      statusText: this.panelStore.statusText
    };
    return JSON.stringify(snapshot);
  }

  private computeCellBoundsForPitch(cellId: number): ShapeBounds {
    let minX: number = Infinity;
    let minY: number = Infinity;
    let maxX: number = -Infinity;
    let maxY: number = -Infinity;
    for (const s of editService.getShapes()) {
      if ((s.ownerCellId ?? editService.getTopCellId()) !== cellId) continue;
      if (s.type === ShapeType.INSTANCE || s.type === ShapeType.NODE) continue;
      const b: ShapeBounds = getShapeBounds(s);
      if (b.minX < minX) minX = b.minX;
      if (b.minY < minY) minY = b.minY;
      if (b.maxX > maxX) maxX = b.maxX;
      if (b.maxY > maxY) maxY = b.maxY;
    }
    if (!Number.isFinite(minX) || !Number.isFinite(minY)) {
      return { minX: 0, minY: 0, maxX: 1000, maxY: 1000 };
    }
    return { minX, minY, maxX, maxY };
  }

  private buildRegularOrCurvePoints(op: DshEditOperation): Point[] {
    const cx: number = op.x ?? 0;
    const cy: number = op.y ?? 0;
    if (op.action === 'create_regular_polygon') {
      const sides: number = Math.max(3, Math.min(128, Math.round(op.sides ?? 6)));
      const r: number = Math.max(1, op.radiusNm ?? ((op.width ?? 400) / 2));
      const pts: Point[] = [];
      for (let i = 0; i < sides; i++) {
        const ang: number = (2 * Math.PI * i) / sides;
        pts.push({ x: Math.round(cx + r * Math.cos(ang)), y: Math.round(cy + r * Math.sin(ang)) });
      }
      return pts;
    }
    const segs: number = Math.max(8, Math.min(512, Math.round(op.segments ?? 32)));
    if (op.action === 'create_circle' || op.action === 'create_ellipse') {
      const rx: number = Math.max(1, op.action === 'create_ellipse' ? (op.radiusXNm ?? op.radiusNm ?? 200) : (op.radiusNm ?? 200));
      const ry: number = Math.max(1, op.action === 'create_ellipse' ? (op.radiusYNm ?? op.radiusNm ?? 120) : rx);
      const pts: Point[] = [];
      for (let i = 0; i < segs; i++) {
        const ang: number = (2 * Math.PI * i) / segs;
        pts.push({ x: Math.round(cx + rx * Math.cos(ang)), y: Math.round(cy + ry * Math.sin(ang)) });
      }
      return pts;
    }
    const outerR: number = Math.max(2, op.radiusNm ?? 400);
    const innerR: number = Math.max(0, Math.min(outerR - 1, op.innerRadiusNm ?? Math.round(outerR * 0.5)));
    const isArc: boolean = op.action === 'create_arc';
    const a0Deg: number = isArc ? (op.startAngleDeg ?? 0) : 0;
    const a1Deg: number = isArc ? (op.endAngleDeg ?? 90) : 360;
    const a0: number = (a0Deg * Math.PI) / 180;
    const a1: number = (a1Deg * Math.PI) / 180;
    const outerPts: Point[] = [];
    const innerPts: Point[] = [];
    for (let i = 0; i <= segs; i++) {
      const t: number = i / segs;
      const ang: number = a0 + (a1 - a0) * t;
      outerPts.push({ x: Math.round(cx + outerR * Math.cos(ang)), y: Math.round(cy + outerR * Math.sin(ang)) });
      if (innerR > 0) {
        innerPts.push({ x: Math.round(cx + innerR * Math.cos(ang)), y: Math.round(cy + innerR * Math.sin(ang)) });
      }
    }
    if (innerR > 0) {
      innerPts.reverse();
      return outerPts.concat(innerPts);
    }
    const center: Point = { x: Math.round(cx), y: Math.round(cy) };
    return isArc ? [center].concat(outerPts) : outerPts.slice(0, segs);
  }

  private buildDshBackendHost(ticket: number): DshLayoutBackendHost {
    const generation: number = this.pageGeneration;
    return {
      isPageCurrent: (): boolean => this.pageAlive && generation === this.pageGeneration && ticket === this.aiRequestGeneration,
      inspectLayout: (): string => {
        if (!aiService.getContextOptions().includeLayout) {
          return '{"layoutContextIncluded":false}';
        }
        const ctx: AiContext = this.filteredAiContext(this.buildAiContext());
        const currentCell: DshLayoutCellSummary = {
          id: editService.getCurrentCellId(),
          name: this.docStore.currentEditingCellName || ctx.currentCell?.name || ''
        };
        const activeLayer: DshLayoutActiveLayer = {
          layer: this.viewportStore.selectedLayerNumber, datatype: this.viewportStore.selectedDatatype
        };
        const pyInfo = nativeHongTuService.getEmbeddedPythonInfo();
        const pyBrief: DshEmbeddedPythonBrief = {
          available: pyInfo.available,
          tier: pyInfo.activeTier,
          version: pyInfo.version,
          executionMode: pythonBridgeService.getExecutionMode()
        };
        return JSON.stringify({
          documentId: this.docStore.activeWorkspaceId,
          title: this.currentFileDisplayName() || '未命名版图',
          libraryName: this.docStore.docLibName,
          topCell: this.docStore.docTopCellName,
          currentCell,
          allCells: this.placeableCells,
          dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits),
          shapeCount: editService.getShapes().length,
          currentCellShapeCount: editService.getCurrentCellShapes().length,
          selectedCount: ctx.coverage?.selectedTotal ?? 0,
          selectedShapes: (ctx.selectedShapes ?? []).slice(0, 16),
          activeLayer,
          layers: this.layersForDisplay().map((l: UiLayer): DshLayoutLayerSummary => ({
            layer: l.layerNumber,
            datatype: l.datatype,
            name: l.englishName,
            chineseName: l.chineseName,
            visible: l.visible,
            locked: l.locked === true,
            elementCount: l.elementCount
          })),
          portCount: this.docPorts.filter((p: LayoutPort): boolean => p.ownerCellId === editService.getCurrentCellId()).length,
          drcSummary: this.aiDrcResultSummary(),
          openTabs: this.docStore.workspaceTabs.length,
          maxTabs: MAX_WORKSPACE_TABS,
          embeddedPython: pyBrief
        });
      },
      queryLayout: async (argsJson: string): Promise<string> => {
        let parsed: Record<string, Object> = {};
        try { parsed = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const kindRaw: string = typeof parsed['kind'] === 'string' ? (parsed['kind'] as string) : 'shapes';
        const query: AiEditorQuery = {
          kind: kindRaw as 'shapes' | 'cells' | 'drc' | 'rules' | 'ports',
          cellId: typeof parsed['cellId'] === 'number' ? (parsed['cellId'] as number) : undefined,
          layer: typeof parsed['layer'] === 'number' ? (parsed['layer'] as number) : undefined,
          datatype: typeof parsed['datatype'] === 'number' ? (parsed['datatype'] as number) : undefined,
          offset: typeof parsed['offset'] === 'number' ? (parsed['offset'] as number) : 0,
          limit: typeof parsed['limit'] === 'number' ? (parsed['limit'] as number) : 32
        };
        const snapshot: AiContext = this.filteredAiContext(this.buildAiContext());
        const counts: Map<number, number> = new Map<number, Set<number>>().size >= 0 ? new Map<number, number>() : new Map<number, number>();
        const children: Map<number, Set<number>> = new Map<number, Set<number>>();
        if (query.kind === 'cells') {
          for (const shape of editService.getShapes()) {
            const owner: number = shape.ownerCellId ?? editService.getTopCellId();
            counts.set(owner, (counts.get(owner) ?? 0) + 1);
            if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
              let ids: Set<number> | undefined = children.get(owner);
              if (ids === undefined) { ids = new Set<number>(); children.set(owner, ids); }
              ids.add(shape.cellId);
            }
          }
        }
        const allCells: AiCellInfo[] = query.kind === 'cells'
          ? this.propertyCellOptions().map((cell: PropertyCellOption): AiCellInfo => ({
            id: cell.id,
            name: cell.name,
            shapeCount: counts.get(cell.id) ?? 0,
            children: Array.from(children.get(cell.id) ?? new Set<number>())
          }))
          : [];
        const reply: AiEditorReply = queryAiWorkbench(query, {
          context: snapshot,
          shapes: editService.getShapes(),
          cells: allCells,
          drc: drcService.getLastResult()?.violations ?? [],
          rules: drcService.getRules(),
          ports: this.docPorts.filter((port: LayoutPort): boolean => port.ownerCellId === (query.cellId ?? editService.getCurrentCellId())),
          drcCurrent: this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision,
          ruleSource: `${drcService.ruleSourceText()}；${this.aiDrcResultSummary()}`
        });
        return JSON.stringify(reply);
      },
      inspectWorkbenchUi: (): string => {
        return this.inspectCurrentWorkbenchUiJson();
      },
      captureScreenshot: async (argsJson: string): Promise<DshToolExecutionOutcome> => {
        let parsed: Record<string, Object> = {};
        try { parsed = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const target: string = typeof parsed['target'] === 'string' ? (parsed['target'] as string) : 'canvas_viewport';
        const widthPx: number = typeof parsed['widthPx'] === 'number' ? (parsed['widthPx'] as number) : 1280;
        const heightPx: number = typeof parsed['heightPx'] === 'number' ? (parsed['heightPx'] as number) : 900;
        const showInChat: boolean = parsed['showInChat'] !== false;
        const fitBeforeCapture: boolean = parsed['fitBeforeCapture'] === true;
        return await this.captureWorkbenchOrCanvasPng(target, widthPx, heightPx, showInChat, fitBeforeCapture);
      },
      automateWorkbenchUi: async (argsJson: string, _permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        let parsed: Record<string, Object> = {};
        try { parsed = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const rawSteps: Object[] = Array.isArray(parsed['steps']) ? (parsed['steps'] as Object[]) : [];
        const captureAfter: boolean = parsed['captureAfter'] === true;
        const logs: string[] = [];

        for (let i = 0; i < rawSteps.length; i++) {
          const item: Object = rawSteps[i];
          if (item === null || typeof item !== 'object' || Array.isArray(item)) continue;
          const step: Record<string, Object> = item as Record<string, Object>;
          const action: string = typeof step['action'] === 'string' ? (step['action'] as string) : '';

          if (action === 'switch_module') {
            const mod: string = String(step['module'] ?? 'layout');
            if (mod === 'verification' || mod === 'verify') this.selectModule(WorkModule.Verify, '验证');
            else if (mod === 'data') this.selectModule(WorkModule.Data, '数据');
            else this.selectModule(WorkModule.Layout, '版图');
            logs.push(`切换模块至 ${mod}`);
          } else if (action === 'set_view_mode') {
            const m: string = String(step['mode'] ?? 'edit');
            this.setViewMode(m === 'viewer' || m === 'view' ? ViewMode.VIEWER : ViewMode.EDIT);
            logs.push(`切换模式至 ${m}`);
          } else if (action === 'select_tool') {
            const toolStr: string = String(step['tool'] ?? 'select');
            if (toolStr === 'zoom_box') this.viewportStore.currentTool = ActiveTool.BoxZoom;
            else if (toolStr === 'rect') this.viewportStore.currentTool = ActiveTool.Rect;
            else if (toolStr === 'polygon') this.viewportStore.currentTool = ActiveTool.Polygon;
            else if (toolStr === 'path') this.viewportStore.currentTool = ActiveTool.Path;
            else if (toolStr === 'text') this.viewportStore.currentTool = ActiveTool.Text;
            else if (toolStr === 'measure') this.viewportStore.currentTool = ActiveTool.Measure;
            else this.viewportStore.currentTool = ActiveTool.Select;
            logs.push(`激活工具 ${toolStr}`);
          } else if (action === 'toggle_panel') {
            const panel: string = String(step['panel'] ?? '');
            const openVal: boolean = step['open'] !== false;
            if (panel === 'sidebar') this.panelStore.sidebarVisible = openVal;
            else if (panel === 'inspector') this.panelStore.inspectorVisible = openVal;
            else if (panel === 'drc_dock') this.verifyStore.drcDockCollapsed = !openVal;
            else if (panel === 'verification') this.panelStore.showVerificationPanel = openVal;
            else if (panel === 'lvs') this.panelStore.showLvsPanel = openVal;
            else if (panel === 'python') this.panelStore.showPythonPanel = openVal;
            else if (panel === 'macro') this.panelStore.showMacroPanel = openVal;
            else if (panel === 'library') { if (openVal) this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.showLibraryPanel = openVal; }
            else if (panel === 'technology') this.panelStore.showTechnologyPanel = openVal;
            else if (panel === 'layer_stack') this.panelStore.showLayerStackPanel = openVal;
            else if (panel === 'compare') this.panelStore.showComparePanel = openVal;
            else if (panel === 'rdb_review') { if (openVal) this.openRdbReview(); else this.panelStore.showRdbReviewPanel = false; }
            else if (panel === 'search') this.panelStore.showSearchPanel = openVal;
            else if (panel === 'project') this.panelStore.showProjectPanel = openVal;
            else if (panel === 'view_workspace') { if (openVal) this.openViewWorkspace(); else this.closeViewWorkspace(); }
            else if (panel === 'shortcuts') this.panelStore.showShortcutPanel = openVal;
            else if (panel === 'layer_style') this.panelStore.showLayerStylePanel = openVal;
            logs.push(`${openVal ? '打开' : '关闭'}面板 ${panel}`);
          } else if (action === 'camera') {
            const op: string = String(step['op'] ?? 'fit_all');
            if (op === 'fit_all') this.fitAllShapes();
            else if (op === 'reset_view') this.resetView();
            else if (op === 'zoom_to' && typeof step['zoomPercent'] === 'number') {
              viewService.setViewZoomPercent(step['zoomPercent'] as number);
              this.viewportStore.zoomPercent = viewService.getViewZoomPercent();
            } else if (op === 'pan_by') {
              this.panCanvas(Number(step['dxPx'] ?? 0), Number(step['dyPx'] ?? 0));
            } else if (op === 'focus_world_box') {
              this.focusWorldBounds({
                minX: Number(step['minX'] ?? 0),
                minY: Number(step['minY'] ?? 0),
                maxX: Number(step['maxX'] ?? 1000),
                maxY: Number(step['maxY'] ?? 1000)
              });
            } else if (op === 'focus_shape' && typeof step['shapeId'] === 'number') {
              const targetShape: Shape | undefined = editService.getShapes().find((s: Shape): boolean => s.id === (step['shapeId'] as number));
              if (targetShape !== undefined) {
                editService.selectShape(targetShape.id);
                this.syncShapesFromEditService();
                this.focusWorldBounds(getShapeBounds(targetShape));
              }
            } else if (op === 'focus_violation' && typeof step['violationIndex'] === 'number') {
              const idx: number = step['violationIndex'] as number;
              if (idx >= 0 && idx < this.verifyStore.drcIssues.length) {
                this.locateIssue(this.verifyStore.drcIssues[idx]);
              }
            } else if (op === 'set_hierarchy_depth' && typeof step['depth'] === 'number') {
              const d: number = Math.max(0, Math.min(32, Math.round(step['depth'] as number)));
              viewService.setHierarchyDepth(d);
              this.docStore.hierarchyDepth = d;
            }
            logs.push(`相机动作 ${op}`);
          } else if (action === 'canvas_click_world') {
            const wx: number = Number(step['x'] ?? 0);
            const wy: number = Number(step['y'] ?? 0);
            const additive: boolean = step['additive'] === true;
            const hitShapes: Shape[] = editService.getCurrentCellShapes().filter((s: Shape): boolean => {
              const b: ShapeBounds = getShapeBounds(s);
              return wx >= b.minX && wx <= b.maxX && wy >= b.minY && wy <= b.maxY;
            });
            if (hitShapes.length > 0) {
              const topHit: Shape = hitShapes[hitShapes.length - 1];
              if (additive) {
                const nextIds: number[] = editService.getSelectedIds().concat([topHit.id]);
                editService.selectMultiple(nextIds);
              } else {
                editService.selectShape(topHit.id);
              }
              this.syncShapesFromEditService();
              logs.push(`点选 (${wx},${wy}) 命中 #${topHit.id}`);
            } else {
              if (!additive) editService.clearSelection();
              this.syncShapesFromEditService();
              logs.push(`点选 (${wx},${wy}) 空白区`);
            }
          } else if (action === 'canvas_box_select_world') {
            const bx0: number = Math.min(Number(step['minX'] ?? 0), Number(step['maxX'] ?? 0));
            const by0: number = Math.min(Number(step['minY'] ?? 0), Number(step['maxY'] ?? 0));
            const bx1: number = Math.max(Number(step['minX'] ?? 0), Number(step['maxX'] ?? 0));
            const by1: number = Math.max(Number(step['minY'] ?? 0), Number(step['maxY'] ?? 0));
            const encloseOnly: boolean = step['encloseOnly'] === true;
            const matchedIds: number[] = editService.getCurrentCellShapes()
              .filter((s: Shape): boolean => {
                const b: ShapeBounds = getShapeBounds(s);
                return encloseOnly
                  ? (b.minX >= bx0 && b.maxX <= bx1 && b.minY >= by0 && b.maxY <= by1)
                  : !(b.maxX < bx0 || b.minX > bx1 || b.maxY < by0 || b.minY > by1);
              })
              .map((s: Shape): number => s.id);
            editService.selectMultiple(matchedIds);
            this.syncShapesFromEditService();
            logs.push(`框选命中 ${matchedIds.length} 个对象`);
          } else if (action === 'ruler') {
            const op: string = String(step['op'] ?? 'add');
            if (op === 'clear_all') this.measureStore.restoreRulers([]);
            else this.measureStore.addRuler(step['vertical'] === true, Number(step['positionNm'] ?? 0));
            logs.push(`标尺操作 ${op}`);
          } else if (action === 'set_grid_and_snap') {
            if (typeof step['gridVisible'] === 'boolean') this.viewportStore.gridVisible = step['gridVisible'] as boolean;
            if (typeof step['gridSize'] === 'number' && (step['gridSize'] as number) > 0) this.viewportStore.gridSize = step['gridSize'] as number;
            if (typeof step['snapEnabled'] === 'boolean') this.viewportStore.snapEnabled = step['snapEnabled'] as boolean;
            if (typeof step['routingMode'] === 'string') {
              const rm: string = step['routingMode'] as string;
              this.viewportStore.routingMode = rm === 'free_angle' ? RoutingMode.FREE : (rm === 'octilinear_45' ? RoutingMode.OCTILINEAR_45 : RoutingMode.MANHATTAN_90);
            }
            logs.push('更新栅格/磁吸/走线配置');
          } else if (action === 'set_theme') {
            const tm: string = String(step['theme'] ?? 'system');
            const normalizedTheme: ThemeMode = tm === 'dark' ? 'dark' : (tm === 'light' ? 'light' : 'system');
            this.themeState.setThemeMode(normalizedTheme);
            logs.push(`切换外观主题为 ${normalizedTheme}`);
          } else if (action === 'execute_command' && typeof step['commandId'] === 'string') {
            this.executeWorkbenchCommand(step['commandId'] as string);
            logs.push(`执行命令 ${step['commandId'] as string}`);
          }
        }

        let shotOutcome: DshToolExecutionOutcome | undefined = undefined;
        if (captureAfter) {
          shotOutcome = await this.captureWorkbenchOrCanvasPng('canvas_viewport', 1280, 860, true, false);
        }
        const summaryStr: string = logs.length > 0 ? logs.join('；') : '未执行任何 UI 步骤';
        return {
          success: true,
          summary: summaryStr,
          visualAttachment: shotOutcome?.visualAttachment,
          generatedAttachment: shotOutcome?.generatedAttachment,
          payloadJson: JSON.stringify({
            success: true,
            executedSteps: logs.length,
            summary: summaryStr,
            uiStateAfter: JSON.parse(this.inspectCurrentWorkbenchUiJson()) as Object
          })
        };
      },
      askUser: async (params: DshAskUserPromptParams): Promise<AiAskUserExchange> => {
        const reqId: string = `ask_${Date.now().toString(36)}`;
        const req: AiAskUserRequest = {
          id: reqId,
          question: params.question,
          context: params.header.length > 0 ? params.header : undefined,
          options: params.options,
          multiSelect: params.allowMultiple,
          allowCustomInput: true,
          placeholder: params.placeholder
        };
        this.aiStore.aiPendingAskUser = req;
        this.panelStore.showAiPanel = true;
        this.flushAiStreamUiNow();
        return await new Promise<AiAskUserExchange>((resolve: (val: AiAskUserExchange) => void) => {
          this.pendingAskUserResolve = resolve;
        });
      },
      manageLayers: async (argsJson: string, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        if (permission === 'readonly') throw new Error('只读问答模式下不可修改图层');
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? '');
        const layerNum: number = typeof args['layer'] === 'number' ? Math.round(args['layer'] as number) : this.viewportStore.selectedLayerNumber;
        const dtNum: number = typeof args['datatype'] === 'number' ? Math.round(args['datatype'] as number) : 0;
        const beforeMarker: Object | null = editService.getUndoMarker();
        let summaryStr: string = '';
        let deletedShapesCount: number = 0;
        let addedShapesCount: number = 0;

        if (action === 'create') {
          const cName: string = typeof args['chineseName'] === 'string' && (args['chineseName'] as string).trim().length > 0
            ? (args['chineseName'] as string).trim() : `图层 ${layerNum}/${dtNum}`;
          const eName: string = typeof args['englishName'] === 'string' && (args['englishName'] as string).trim().length > 0
            ? (args['englishName'] as string).trim() : `L${layerNum}_${dtNum}`;
          const col: string = typeof args['color'] === 'string' && /^#[0-9A-Fa-f]{6}$/.test(args['color'] as string)
            ? (args['color'] as string) : this.layerColor(this.docStore.layers.length);
          this.ensureDshLayerExists(layerNum, dtNum, eName, cName, col);
          this.viewportStore.selectedLayerNumber = layerNum;
          this.viewportStore.selectedDatatype = dtNum;
          this.docStore.editorRevision++;
          summaryStr = `已新建并激活图层 L${layerNum}/D${dtNum} (${eName} ${cName})`;
        } else if (action === 'delete') {
          const batchList: Object[] = Array.isArray(args['layers']) ? (args['layers'] as Object[]) : [];
          if (batchList.length > 0) {
            let deletedLayers: number = 0;
            for (let i = 0; i < batchList.length; i++) {
              const entry: Object = batchList[i];
              if (entry !== null && typeof entry === 'object' && !Array.isArray(entry)) {
                const rec: Record<string, Object> = entry as Record<string, Object>;
                const ln: number = Number(rec['layer'] ?? -1);
                const dt: number = Number(rec['datatype'] ?? 0);
                const beforeS: number = editService.getShapes().length;
                if (ln >= 0 && this.deleteLayerWithUndo(ln, dt, true)) {
                  deletedLayers++;
                  deletedShapesCount += Math.max(0, beforeS - editService.getShapes().length);
                }
              }
            }
            summaryStr = `已批量删除 ${deletedLayers} 个图层（清理 ${deletedShapesCount} 个图形，可撤销）`;
          } else {
            const beforeS: number = editService.getShapes().length;
            const ok: boolean = this.deleteLayerWithUndo(layerNum, dtNum, true);
            deletedShapesCount = Math.max(0, beforeS - editService.getShapes().length);
            if (!ok) {
              return { success: false, summary: this.panelStore.statusText, payloadJson: JSON.stringify({ success: false, error: this.panelStore.statusText }) };
            }
            summaryStr = this.panelStore.statusText;
          }
        } else if (action === 'delete_empty') {
          const removed: number = this.deleteAllEmptyLayersWithUndo();
          summaryStr = removed > 0 ? `已清理 ${removed} 个无图形空图层` : '当前无空图层需要清理';
        } else if (action === 'clear') {
          const curOnly: boolean = args['allCells'] === false;
          deletedShapesCount = this.clearShapesOnLayer(layerNum, dtNum, curOnly);
          summaryStr = this.panelStore.statusText;
        } else if (action === 'rename') {
          const target: UiLayer | undefined = this.docStore.layers.find((l: UiLayer): boolean => l.layerNumber === layerNum && l.datatype === dtNum);
          if (target === undefined) throw new Error(`图层 L${layerNum}/D${dtNum} 不存在`);
          const nextLayers: UiLayer[] = this.docStore.layers.map((l: UiLayer): UiLayer => {
            if (l.layerNumber !== layerNum || l.datatype !== dtNum) return l;
            const copy: UiLayer = cloneLayerWithVisible(l, l.visible);
            if (typeof args['chineseName'] === 'string' && (args['chineseName'] as string).trim().length > 0) copy.chineseName = (args['chineseName'] as string).trim();
            if (typeof args['englishName'] === 'string' && (args['englishName'] as string).trim().length > 0) copy.englishName = (args['englishName'] as string).trim();
            return copy;
          });
          this.docStore.layers = nextLayers;
          this.docStore.editorRevision++;
          summaryStr = `已重命名图层 L${layerNum}/D${dtNum}`;
        } else if (action === 'style') {
          const target: UiLayer | undefined = this.docStore.layers.find((l: UiLayer): boolean => l.layerNumber === layerNum && l.datatype === dtNum);
          if (target === undefined) throw new Error(`图层 L${layerNum}/D${dtNum} 不存在`);
          this.docStore.layers = this.docStore.layers.map((l: UiLayer): UiLayer => {
            if (l.layerNumber !== layerNum || l.datatype !== dtNum) return l;
            const copy: UiLayer = cloneLayerWithVisible(l, l.visible);
            if (typeof args['color'] === 'string' && /^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/.test(args['color'] as string)) copy.color = args['color'] as string;
            if (typeof args['fillStyle'] === 'string') copy.fillStyle = (args['fillStyle'] as string) === 'stipple' ? 'cross' : (args['fillStyle'] as string);
            if (typeof args['lineStyle'] === 'string') copy.lineStyle = args['lineStyle'] as string;
            if (typeof args['transparency'] === 'number') {
              const rawT: number = args['transparency'] as number;
              copy.transparency = rawT <= 1 ? Math.round(rawT * 100) : Math.round(Math.min(100, rawT));
            }
            if (typeof args['lineWidth'] === 'number') copy.lineWidth = args['lineWidth'] as number;
            return copy;
          });
          this.syncLayerVisibilityMirror();
          this.docStore.editorRevision++;
          summaryStr = `已更新图层 L${layerNum}/D${dtNum} 视觉样式`;
        } else if (action === 'visibility') {
          this.setLayerVisible(layerNum, args['visible'] !== false, dtNum);
          summaryStr = `图层 L${layerNum}/D${dtNum} 已设为${args['visible'] !== false ? '可见' : '隐藏'}`;
        } else if (action === 'lock') {
          const target: UiLayer | undefined = this.docStore.layers.find((l: UiLayer): boolean => l.layerNumber === layerNum && l.datatype === dtNum);
          if (target !== undefined && (target.locked === true) !== (args['locked'] === true)) {
            this.toggleLayerLock(layerNum, dtNum);
          }
          summaryStr = `图层 L${layerNum}/D${dtNum} 已${args['locked'] === true ? '锁定' : '解锁'}`;
        } else if (action === 'selectable') {
          this.setLayerSelectable(layerNum, dtNum, args['selectable'] !== false);
          summaryStr = `图层 L${layerNum}/D${dtNum} 可选状态已设为 ${args['selectable'] !== false}`;
        } else if (action === 'set_active') {
          this.ensureDshLayerExists(layerNum, dtNum, `L${layerNum}_${dtNum}`, `图层 ${layerNum}/${dtNum}`, this.layerColor(this.docStore.layers.length));
          this.viewportStore.selectedLayerNumber = layerNum;
          this.viewportStore.selectedDatatype = dtNum;
          summaryStr = `已将当前活动绘制层切换至 L${layerNum}/D${dtNum}`;
        } else if (action === 'reorder') {
          const idx: number = this.docStore.layers.findIndex((l: UiLayer): boolean => l.layerNumber === layerNum && l.datatype === dtNum);
          if (idx < 0) throw new Error(`图层 L${layerNum}/D${dtNum} 不存在`);
          const arr: UiLayer[] = this.docStore.layers.slice();
          const moved: UiLayer = arr.splice(idx, 1)[0];
          const dest: number = Math.max(0, Math.min(arr.length, typeof args['targetIndex'] === 'number' ? Math.round(args['targetIndex'] as number) : 0));
          arr.splice(dest, 0, moved);
          this.docStore.layers = arr;
          this.docStore.editorRevision++;
          summaryStr = `已将图层 L${layerNum}/D${dtNum} 移动至位置 #${dest}`;
        } else if (action === 'select_shapes_on_layer') {
          const ids: number[] = editService.getCurrentCellShapes()
            .filter((s: Shape): boolean => s.layerNumber === layerNum && s.datatype === dtNum)
            .map((s: Shape): number => s.id);
          editService.selectMultiple(ids);
          this.syncShapesFromEditService();
          summaryStr = `已选中图层 L${layerNum}/D${dtNum} 上的 ${ids.length} 个图形`;
        } else if (action === 'copy_shapes' || action === 'move_shapes') {
          const dstLayer: number = Number(args['targetLayer'] ?? layerNum);
          const dstDt: number = Number(args['targetDatatype'] ?? 0);
          this.ensureDshLayerExists(dstLayer, dstDt, `L${dstLayer}_${dstDt}`, `图层 ${dstLayer}/${dstDt}`, this.layerColor(this.docStore.layers.length));
          const curCell: number = editService.getCurrentCellId();
          const allCells: boolean = args['allCells'] !== false;
          const matches: Shape[] = editService.getShapes().filter((s: Shape): boolean =>
            s.type !== ShapeType.INSTANCE && s.type !== ShapeType.NODE &&
            s.layerNumber === layerNum && s.datatype === dtNum &&
            (allCells || (s.ownerCellId ?? editService.getTopCellId()) === curCell)
          );
          if (action === 'copy_shapes') {
            const copies: Shape[] = matches.map((s: Shape): Shape => {
              const cp: Shape = cloneShapeModel(s) as Shape;
              cp.id = 0;
              cp.layerNumber = dstLayer;
              cp.datatype = dstDt;
              return cp;
            });
            const created: Shape[] = editService.createShapeCopies(copies, true, true);
            addedShapesCount = created.length;
            summaryStr = `已将 L${layerNum}/D${dtNum} 的 ${created.length} 个图形复制到 L${dstLayer}/D${dstDt}`;
          } else {
            editService.beginBatch();
            try {
              for (const s of matches) {
                editService.updateShape(s.id, dstLayer, 0, 0, dstDt);
              }
            } finally {
              editService.endBatch();
            }
            summaryStr = `已将 L${layerNum}/D${dtNum} 的 ${matches.length} 个图形迁移至 L${dstLayer}/D${dstDt}`;
          }
          this.syncShapesFromEditService();
        } else if (action === 'batch_state') {
          const op: string = String(args['op'] ?? 'show_all');
          this.docStore.layers = this.docStore.layers.map((l: UiLayer): UiLayer => {
            const cp: UiLayer = cloneLayerWithVisible(l, l.visible);
            if (op === 'show_all') cp.visible = true;
            else if (op === 'hide_all') cp.visible = false;
            else if (op === 'only_layer') cp.visible = (l.layerNumber === layerNum && l.datatype === dtNum);
            else if (op === 'invert_visibility') cp.visible = !l.visible;
            else if (op === 'lock_all') cp.locked = true;
            else if (op === 'unlock_all') cp.locked = false;
            return cp;
          });
          this.syncLayerVisibilityMirror();
          this.docStore.editorRevision++;
          summaryStr = `已执行图层批量状态操作：${op}`;
        } else if (action === 'expression') {
          const exprRaw: string = String(args['expression'] ?? '').trim();
          let exprBody: string = exprRaw;
          let outL: number = typeof args['targetLayer'] === 'number' ? Math.round(args['targetLayer'] as number) : layerNum;
          let outDt: number = typeof args['targetDatatype'] === 'number' ? Math.round(args['targetDatatype'] as number) : dtNum;
          const eqIdx: number = exprRaw.indexOf('=');
          if (eqIdx > 0) {
            const lhs: string = exprRaw.substring(0, eqIdx).trim();
            exprBody = exprRaw.substring(eqIdx + 1).trim();
            const m: RegExpExecArray | null = /^(\d+)(?:\/(\d+))?$/.exec(lhs);
            if (m !== null) {
              outL = Number(m[1]);
              outDt = m[2] !== undefined ? Number(m[2]) : 0;
            }
          }
          const callRes: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('layers.expression', JSON.stringify({
            expression: exprBody,
            outputLayer: outL,
            outputDatatype: outDt,
            keepSources: true,
            hierarchyDepth: this.docStore.hierarchyDepth
          })));
          this.syncShapesFromEditService();
          summaryStr = callRes.message;
        } else {
          throw new Error(`未知 manage_layers 动作: ${action}`);
        }

        this.aiUndoMarker = editService.getUndoMarker();
        this.aiStore.aiCanUndo = this.aiUndoMarker !== beforeMarker;
        this.scheduleWorkspaceDraft();
        return {
          success: true,
          addedShapes: addedShapesCount,
          deletedShapes: deletedShapesCount,
          summary: summaryStr,
          payloadJson: JSON.stringify({
            success: true,
            action,
            summary: summaryStr,
            layerCount: this.docStore.layers.length,
            activeLayer: `${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}`
          })
        };
      },
      manageCells: async (argsJson: string, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        if (permission === 'readonly') throw new Error('只读问答模式下不可修改单元层级');
        if (!this.assertEditMode()) this.setViewMode(ViewMode.EDIT);
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? '');
        const resolveTargetCellId = (): number => {
          if (typeof args['cellId'] === 'number') return Math.round(args['cellId'] as number);
          if (typeof args['cellName'] === 'string' && (args['cellName'] as string).trim().length > 0) {
            const nm: string = (args['cellName'] as string).trim();
            const found: CellInfo | undefined = this.placeableCells.find((c: CellInfo): boolean => c.name === nm);
            if (found !== undefined) return found.id;
          }
          return editService.getCurrentCellId();
        };

        const beforeCount: number = editService.getShapes().length;
        const beforeMarker: Object | null = editService.getUndoMarker();
        let summaryStr: string = '';

        if (action === 'create') {
          const nm: string = String(args['cellName'] ?? args['newName'] ?? `CELL_${this.placeableCells.length}`).trim();
          const ok: boolean = this.createNewCell(nm);
          if (!ok) return { success: false, summary: this.panelStore.statusText, payloadJson: JSON.stringify({ success: false, error: this.panelStore.statusText }) };
          const createdCell: CellInfo | undefined = this.placeableCells.find((c: CellInfo): boolean => c.name === nm);
          if (args['enterAfterCreate'] !== false && createdCell !== undefined) {
            this.enterCellDefinition(createdCell.id);
          }
          summaryStr = `已新建单元 ${nm}${args['enterAfterCreate'] !== false ? ' 并进入编辑' : ''}`;
        } else if (action === 'delete') {
          const cid: number = resolveTargetCellId();
          if (editService.getCurrentCellStack().indexOf(cid) >= 0) {
            const fallbackId: number = editService.getTopCellId() !== cid
              ? editService.getTopCellId()
              : (this.placeableCells.find((c: CellInfo): boolean => c.id !== cid)?.id ?? -1);
            if (fallbackId >= 0) this.enterCellDefinition(fallbackId);
          }
          const instIds: number[] = editService.getShapes()
            .filter((s: Shape): boolean => s.type === ShapeType.INSTANCE && s.cellId === cid)
            .map((s: Shape): number => s.id);
          if (instIds.length > 0) {
            editService.deleteShapesWithSelectionHistory(instIds);
            this.syncShapesFromEditService();
          }
          const prevCells: number = this.placeableCells.length;
          this.deleteCellById(cid);
          if (this.placeableCells.length >= prevCells) {
            return { success: false, summary: this.panelStore.statusText, payloadJson: JSON.stringify({ success: false, error: this.panelStore.statusText }) };
          }
          summaryStr = this.panelStore.statusText;
        } else if (action === 'rename') {
          const cid: number = resolveTargetCellId();
          const newNm: string = String(args['newName'] ?? '').trim();
          const ok: boolean = this.performRenameCell(cid, newNm);
          if (!ok) return { success: false, summary: this.panelStore.statusText, payloadJson: JSON.stringify({ success: false, error: this.panelStore.statusText }) };
          summaryStr = this.panelStore.statusText;
        } else if (action === 'duplicate') {
          const cid: number = resolveTargetCellId();
          const newNm: string = String(args['newName'] ?? `${this.cellName(cid)}_COPY`).trim();
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('cell.duplicate', JSON.stringify({ cellId: cid, newName: newNm })));
          if (!res.success) return { success: false, summary: res.message, payloadJson: JSON.stringify(res) };
          summaryStr = res.message;
        } else if (action === 'clear') {
          const cid: number = resolveTargetCellId();
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('cell.clear', JSON.stringify({ cellId: cid })));
          summaryStr = res.message;
        } else if (action === 'enter') {
          const cid: number = resolveTargetCellId();
          this.enterCellDefinition(cid);
          this.fitAllShapes();
          summaryStr = `已进入单元 ${this.cellName(cid)} 编辑`;
        } else if (action === 'exit_parent') {
          const stack: number[] = editService.getCurrentCellStack();
          if (stack.length > 1) {
            this.navigateCellStack(stack.length - 2);
            summaryStr = `已退回父级单元 ${this.docStore.currentEditingCellName}`;
          } else {
            summaryStr = '当前已在顶层单元';
          }
        } else if (action === 'exit_top') {
          editService.exitToTop();
          this.syncShapesFromEditService();
          this.fitAllShapes();
          summaryStr = `已退回顶层单元 ${this.docStore.currentEditingCellName}`;
        } else if (action === 'set_top') {
          const cid: number = resolveTargetCellId();
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('cell.set_top', JSON.stringify({ cellId: cid })));
          summaryStr = res.message;
        } else if (action === 'make_from_selection') {
          const nm: string = String(args['newName'] ?? args['cellName'] ?? `SUB_${this.placeableCells.length}`).trim();
          const ids: number[] = Array.isArray(args['shapeIds'])
            ? (args['shapeIds'] as Object[]).map((v: Object): number => Number(v))
            : editService.getSelectedIds();
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('cell.make', JSON.stringify({ shapeIds: ids, name: nm })));
          this.syncShapesFromEditService();
          this.rebuildCellTree();
          summaryStr = res.message;
        } else if (action === 'place_sref' || action === 'place_aref') {
          const cid: number = resolveTargetCellId();
          const px: number = Number(args['x'] ?? 0);
          const py: number = Number(args['y'] ?? 0);
          const rot: number = Number(args['rotation'] ?? 0);
          const mir: number = args['mirror'] === true ? 1 : 0;
          const cols: number = action === 'place_aref' ? Math.max(1, Math.round(Number(args['cols'] ?? 2))) : 1;
          const rows: number = action === 'place_aref' ? Math.max(1, Math.round(Number(args['rows'] ?? 2))) : 1;
          const cb: ShapeBounds = this.computeCellBoundsForPitch(cid);
          const gapX: number = Number(args['gapX'] ?? 200);
          const gapY: number = Number(args['gapY'] ?? 200);
          const pitchX: number = typeof args['pitchX'] === 'number' ? (args['pitchX'] as number) : Math.max(200, (cb.maxX - cb.minX) + gapX);
          const pitchY: number = typeof args['pitchY'] === 'number' ? (args['pitchY'] as number) : Math.max(200, (cb.maxY - cb.minY) + gapY);
          this.instanceDialogContext = this.parameterDialogContext();
          const ok: boolean = this.placeInstance(cid, px, py, rot, mir, cols, rows, pitchX, pitchY);
          if (!ok) return { success: false, summary: this.panelStore.statusText, payloadJson: JSON.stringify({ success: false, error: this.panelStore.statusText }) };
          this.fitAllShapes();
          summaryStr = this.panelStore.statusText;
        } else if (action === 'flatten') {
          const ids: number[] = Array.isArray(args['shapeIds']) && (args['shapeIds'] as Object[]).length > 0
            ? (args['shapeIds'] as Object[]).map((v: Object): number => Number(v))
            : editService.getCurrentCellShapes().filter((s: Shape): boolean => s.type === ShapeType.INSTANCE).map((s: Shape): number => s.id);
          if (ids.length === 0) {
            summaryStr = '当前单元内没有可打平的子实例';
          } else {
            const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('instance.flatten', JSON.stringify({ shapeIds: ids })));
            this.syncShapesFromEditService();
            this.rebuildCellTree();
            summaryStr = res.message;
          }
        } else if (action === 'maintenance_scan') {
          const referenced: Set<number> = new Set<number>([editService.getTopCellId()]);
          for (const s of editService.getShapes()) {
            if (s.type === ShapeType.INSTANCE && s.cellId !== undefined) referenced.add(s.cellId);
          }
          const orphans: CellInfo[] = this.placeableCells.filter((c: CellInfo): boolean => !referenced.has(c.id));
          summaryStr = `共 ${this.placeableCells.length} 个单元，未被引用的孤立单元 ${orphans.length} 个`;
          return {
            success: true,
            summary: summaryStr,
            payloadJson: JSON.stringify({ success: true, totalCells: this.placeableCells.length, orphanCells: orphans })
          };
        } else if (action === 'prune_orphan_cells') {
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('cell.prune', JSON.stringify({
            rootCellIds: [editService.getTopCellId()],
            preserveCellIds: [editService.getCurrentCellId()]
          })));
          this.syncShapesFromEditService();
          this.rebuildCellTree();
          summaryStr = res.message;
        } else {
          throw new Error(`未知 manage_cells 动作: ${action}`);
        }

        const afterCount: number = editService.getShapes().length;
        this.aiUndoMarker = editService.getUndoMarker();
        this.aiStore.aiCanUndo = this.aiUndoMarker !== beforeMarker;
        this.scheduleWorkspaceDraft();
        return {
          success: true,
          addedShapes: Math.max(0, afterCount - beforeCount),
          deletedShapes: Math.max(0, beforeCount - afterCount),
          summary: summaryStr,
          payloadJson: JSON.stringify({
            success: true,
            action,
            summary: summaryStr,
            cells: this.placeableCells,
            currentCell: this.docStore.currentEditingCellName
          })
        };
      },
      createCmosInverter: async (params: DshCmosInverterParams, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        return this.executeDshInverterGeometry(params, permission);
      },
      editLayout: async (operations: DshEditOperation[], permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        const commands: ParsedCommand[] = [];
        for (let i = 0; i < operations.length; i++) {
          const op: DshEditOperation = operations[i];
          const layer: number = op.layer ?? this.viewportStore.selectedLayerNumber;
          const dt: number = op.datatype ?? this.viewportStore.selectedDatatype;
          if (op.action === 'create_regular_polygon' || op.action === 'create_circle' || op.action === 'create_ellipse' ||
            op.action === 'create_donut' || op.action === 'create_arc') {
            const polyPts: Point[] = this.buildRegularOrCurvePoints(op);
            commands.push({
              type: AiCommandType.CREATE_POLYGON,
              params: { layer, datatype: dt, points: polyPts },
              description: `${op.action} (L${layer}/D${dt})`
            });
            continue;
          }
          const cmdType: AiCommandType = op.action as AiCommandType;
          const pts: Point[] | undefined = op.points !== undefined
            ? op.points.map((pt: Record<string, number>): Point => ({ x: Number(pt['x'] ?? 0), y: Number(pt['y'] ?? 0) }))
            : undefined;
          commands.push({
            type: cmdType,
            params: {
              layer,
              datatype: dt,
              x: op.x,
              y: op.y,
              width: cmdType === AiCommandType.CREATE_PATH ? op.pathWidth ?? op.width : op.width,
              height: op.height,
              points: pts,
              text: op.text,
              shapeIds: op.shapeIds ?? (op.shapeId !== undefined ? [op.shapeId] : undefined),
              rows: op.rows,
              cols: op.cols,
              spacingX: op.spacingX,
              spacingY: op.spacingY,
              dx: op.dx,
              dy: op.dy,
              degrees: op.degrees,
              horizontal: op.horizontal === undefined ? undefined : (op.horizontal ? 1 : 0),
              scale: op.scale,
              centerX: op.centerX,
              centerY: op.centerY
            },
            description: `${op.action} (L${layer}/D${dt})`
          });
        }

        if (permission === 'review') {
          const ctx: AiContext = this.filteredAiContext(this.buildAiContext());
          this.aiStore.pendingAiCommands = commands;
          this.aiStore.pendingAiContext = ctx;
          this.pendingAiRevision = this.docStore.editorRevision;
          this.pendingAiDocumentId = this.docStore.activeWorkspaceId;
          this.pendingAiSelection = editService.getSelectedIds().join(',');
          this.pendingAiCell = editService.getCurrentCellId();
          this.pendingAiLayer = this.viewportStore.selectedLayerNumber;
          this.pendingAiDatatype = this.viewportStore.selectedDatatype;
          this.prepareAiReview(commands);
          return {
            success: true,
            stagedPending: true,
            summary: `已生成 ${commands.length} 项版图修改预览，等待确认`,
            payloadJson: JSON.stringify({ success: true, stagedPending: true, operations: commands.length })
          };
        }

        if (!this.assertEditMode()) {
          this.setViewMode(ViewMode.EDIT);
        }
        for (const op of operations) {
          if (op.layer !== undefined) {
            this.ensureDshLayerExists(op.layer, op.datatype ?? this.viewportStore.selectedDatatype,
              op.layerName ?? `L${op.layer}`, op.layerName ?? `图层${op.layer}`, this.layerColor(this.docStore.layers.length));
          }
          if (op.targetLayer !== undefined) {
            this.ensureDshLayerExists(op.targetLayer, op.targetDatatype ?? 0,
              `L${op.targetLayer}`, `图层${op.targetLayer}`, this.layerColor(this.docStore.layers.length));
          }
        }
        const beforeMarker: Object | null = editService.getUndoMarker();
        const beforeCount: number = editService.getShapes().length;
        const execCtx: AiContext = this.buildAiContext();
        editService.beginBatch();
        const messages: string[] = [];
        let allOk: boolean = true;
        try {
          for (let i = 0; i < operations.length; i++) {
            const op: DshEditOperation = operations[i];
            const ids: number[] = op.shapeIds ?? (op.shapeId !== undefined ? [op.shapeId] : editService.getSelectedIds());
            if (op.action === 'duplicate_shape') {
              const dx: number = op.dx ?? 200;
              const dy: number = op.dy ?? 200;
              const copies: Shape[] = editService.getShapes()
                .filter((s: Shape): boolean => ids.indexOf(s.id) >= 0)
                .map((s: Shape): Shape => {
                  const cp: Shape = cloneShapeModel(s) as Shape;
                  cp.id = 0;
                  cp.points = cp.points.map((pt: Point): Point => ({ x: pt.x + dx, y: pt.y + dy }));
                  return cp;
                });
              const created: Shape[] = editService.createShapeCopies(copies, false, true);
              messages.push(`复制 ${created.length} 个图元`);
            } else if (op.action === 'change_layer') {
              const tl: number = op.targetLayer ?? op.layer ?? this.viewportStore.selectedLayerNumber;
              const tdt: number = op.targetDatatype ?? op.datatype ?? 0;
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('selection.layer', JSON.stringify({ shapeIds: ids, layer: tl, datatype: tdt })));
              messages.push(res.message);
            } else if (op.action === 'set_exact_bounds') {
              const sid: number = op.shapeId ?? (ids.length > 0 ? ids[0] : -1);
              const anchor: string = op.anchor ?? 'bottom_left';
              let minX: number = 0;
              let minY: number = 0;
              let maxX: number = 100;
              let maxY: number = 100;
              if (anchor === 'corners') {
                minX = Math.min(op.x ?? 0, op.x2 ?? 100);
                maxX = Math.max(op.x ?? 0, op.x2 ?? 100);
                minY = Math.min(op.y ?? 0, op.y2 ?? 100);
                maxY = Math.max(op.y ?? 0, op.y2 ?? 100);
              } else if (anchor === 'center') {
                const w: number = Math.max(1, op.width ?? 100);
                const h: number = Math.max(1, op.height ?? 100);
                minX = Math.round((op.x ?? 0) - w / 2);
                minY = Math.round((op.y ?? 0) - h / 2);
                maxX = minX + Math.round(w);
                maxY = minY + Math.round(h);
              } else {
                minX = Math.round(op.x ?? 0);
                minY = Math.round(op.y ?? 0);
                maxX = minX + Math.max(1, Math.round(op.width ?? 100));
                maxY = minY + Math.max(1, Math.round(op.height ?? 100));
              }
              const targetS: Shape | undefined = editService.getShapes().find((s: Shape): boolean => s.id === sid);
              if (targetS !== undefined) {
                if (targetS.type === ShapeType.RECT) {
                  editService.updateShapePoints(sid, [{ x: minX, y: minY }, { x: maxX, y: maxY }]);
                } else {
                  const oldB: ShapeBounds = getShapeBounds(targetS);
                  const oldW: number = Math.max(1, oldB.maxX - oldB.minX);
                  const oldH: number = Math.max(1, oldB.maxY - oldB.minY);
                  const scaledPts: Point[] = targetS.points.map((pt: Point): Point => ({
                    x: Math.round(minX + ((pt.x - oldB.minX) / oldW) * (maxX - minX)),
                    y: Math.round(minY + ((pt.y - oldB.minY) / oldH) * (maxY - minY))
                  }));
                  editService.updateShapePoints(sid, scaledPts);
                }
                messages.push(`按 ${anchor} 锚点设界 [${minX},${minY}]..[${maxX},${maxY}]`);
              }
            } else if (op.action === 'update_vertices' && op.points !== undefined) {
              const sid: number = op.shapeId ?? (ids.length > 0 ? ids[0] : -1);
              const pts: Point[] = op.points.map((pt: Record<string, number>): Point => ({ x: Number(pt['x'] ?? 0), y: Number(pt['y'] ?? 0) }));
              editService.updateShapePoints(sid, pts);
              messages.push(`更新图元 #${sid} 顶点 (${pts.length} 点)`);
            } else if (op.action === 'size_offset') {
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('selection.offset', JSON.stringify({ shapeIds: ids, offsetNm: op.offsetNm ?? 50 })));
              messages.push(res.message);
            } else if (op.action === 'round_corners') {
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('selection.round', JSON.stringify({ shapeIds: ids, radiusNm: op.radiusNm ?? 100, maxErrorNm: 2 })));
              messages.push(res.message);
            } else if (op.action === 'align_shapes') {
              const mStr: string = op.alignMode === 'center_x' ? 'centerH' : (op.alignMode === 'center_y' ? 'centerV' : (op.alignMode ?? 'left'));
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('selection.align', JSON.stringify({ shapeIds: ids, alignment: mStr })));
              messages.push(res.message);
            } else if (op.action === 'distribute_shapes') {
              const dir: string = op.horizontal === false ? 'vertical' : 'horizontal';
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('selection.distribute', JSON.stringify({ shapeIds: ids, direction: dir })));
              messages.push(res.message);
            } else if (op.action === 'boolean_op' && ids.length >= 2) {
              const outL: number = op.targetLayer ?? op.layer ?? this.viewportStore.selectedLayerNumber;
              const outDt: number = op.targetDatatype ?? op.datatype ?? 0;
              const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('boolean.apply', JSON.stringify({
                op: op.booleanOp ?? 'merge',
                sourceAId: ids[0],
                sourceBId: ids[1],
                outputLayer: outL,
                outputDatatype: outDt,
                keepSources: op.keepSources === true
              })));
              messages.push(res.message);
            } else {
              const res: CommandResult = aiExecutor.execute(commands[i], execCtx);
              messages.push(res.message);
              if (!res.success) {
                allOk = false;
                break;
              }
            }
          }
        } finally {
          editService.endBatch();
        }
        this.syncShapesFromEditService();
        this.rebuildCellTree();
        if (editService.getShapes().length > beforeCount) {
          this.fitAllShapes();
        }
        const afterCount: number = editService.getShapes().length;
        this.aiUndoMarker = editService.getUndoMarker();
        this.aiStore.aiCanUndo = this.aiUndoMarker !== beforeMarker;
        this.scheduleWorkspaceDraft();
        const added: number = Math.max(0, afterCount - beforeCount);
        const deleted: number = Math.max(0, beforeCount - afterCount);
        return {
          success: allOk,
          addedShapes: added,
          deletedShapes: deleted,
          summary: messages.slice(0, 4).join('；'),
          payloadJson: JSON.stringify({
            success: allOk,
            operations: operations.length,
            addedShapes: added,
            deletedShapes: deleted,
            totalShapesNow: afterCount,
            messages: messages.slice(0, 8)
          })
        };
      },
      managePortsAndRouting: async (argsJson: string, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? 'list_ports');
        const curCellId: number = editService.getCurrentCellId();

        if (action === 'list_ports') {
          const ports = this.docPorts.filter((p: LayoutPort): boolean => p.ownerCellId === curCellId);
          return {
            success: true,
            summary: `当前单元共 ${ports.length} 个端口`,
            payloadJson: JSON.stringify({ success: true, ports })
          };
        }
        if (action === 'list_pcells') {
          const pcells = nativeHongTuService.listPCells();
          const libItems = componentLibraryService.list();
          return {
            success: true,
            summary: `内置 PCell ${pcells.length} 项，个人器件库 ${libItems.length} 项`,
            payloadJson: JSON.stringify({ success: true, pcells, libraryItems: libItems })
          };
        }
        if (permission === 'readonly') throw new Error('只读模式下不可修改端口或自动布线');
        if (!this.assertEditMode()) this.setViewMode(ViewMode.EDIT);

        if (action === 'add_port' || action === 'update_port') {
          const pName: string = String(args['name'] ?? `P_${this.docPorts.length + 1}`).trim();
          const px: number = Number(args['x'] ?? 0);
          const py: number = Number(args['y'] ?? 0);
          const wNm: number = Math.max(10, Number(args['widthNm'] ?? 200));
          const ori: number = Number(args['orientationDeg'] ?? 0);
          const ln: number = Number(args['layer'] ?? this.viewportStore.selectedLayerNumber);
          const dt: number = Number(args['datatype'] ?? 0);
          const pType: string = String(args['portType'] ?? 'electrical');
          const draft: LayoutPortDraft = {
            name: pName,
            centerNm: { x: px, y: py },
            orientationDeg: ori,
            widthNm: wNm,
            layerNumber: ln,
            datatype: dt,
            portType: pType,
            frameMirror: false,
            frameMagnification: 1,
            infoJson: '{}'
          };
          const callName: string = action === 'update_port' && typeof args['portId'] === 'string' ? 'ports.update' : 'ports.add';
          const callPayload: string = callName === 'ports.update'
            ? JSON.stringify({ portId: args['portId'] as string, draft })
            : JSON.stringify({ ownerCellId: curCellId, draft });
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall(callName, callPayload));
          this.syncShapesFromEditService();
          return {
            success: res.success,
            addedPorts: res.success ? 1 : 0,
            summary: res.message,
            payloadJson: JSON.stringify(res)
          };
        }
        if (action === 'delete_port') {
          let pid: string = typeof args['portId'] === 'string' ? (args['portId'] as string) : '';
          if (pid.length === 0 && typeof args['name'] === 'string') {
            const matchedPort: LayoutPort | undefined = this.docPorts.find((p: LayoutPort): boolean =>
              p.ownerCellId === curCellId && p.name === (args['name'] as string)
            );
            if (matchedPort !== undefined) pid = matchedPort.id;
          }
          if (pid.length === 0) throw new Error('未找到指定端口');
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('ports.remove', JSON.stringify({ portId: pid })));
          this.syncShapesFromEditService();
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'extract_ports_from_labels') {
          const texts: Shape[] = editService.getCurrentCellShapes().filter((s: Shape): boolean => s.type === ShapeType.TEXT && (s.text ?? '').trim().length > 0);
          let createdCount: number = 0;
          for (const t of texts) {
            const label: string = (t.text ?? '').trim();
            if (this.docPorts.some((p: LayoutPort): boolean => p.ownerCellId === curCellId && p.name === label)) continue;
            const pt: Point = t.points.length > 0 ? t.points[0] : { x: 0, y: 0 };
            const draft: LayoutPortDraft = {
              name: label,
              centerNm: { x: pt.x, y: pt.y },
              orientationDeg: 0,
              widthNm: 200,
              layerNumber: t.layerNumber,
              datatype: t.datatype,
              portType: 'electrical',
              frameMirror: false,
              frameMagnification: 1,
              infoJson: '{}'
            };
            const r: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('ports.add', JSON.stringify({ ownerCellId: curCellId, draft })));
            if (r.success) createdCount++;
          }
          this.syncShapesFromEditService();
          return {
            success: true,
            addedPorts: createdCount,
            summary: `已从当前单元文本标签提取 ${createdCount} 个端口`,
            payloadJson: JSON.stringify({ success: true, extractedPorts: createdCount })
          };
        }
        if (action === 'route_auto') {
          let x1: number = Number(args['x'] ?? 0);
          let y1: number = Number(args['y'] ?? 0);
          let x2: number = Number(args['toX'] ?? 1000);
          let y2: number = Number(args['toY'] ?? 1000);
          let ln: number = Number(args['layer'] ?? this.viewportStore.selectedLayerNumber);
          let dt: number = Number(args['datatype'] ?? 0);
          let wNm: number = Math.max(20, Number(args['widthNm'] ?? 200));
          if (typeof args['fromPort'] === 'string') {
            const fp: LayoutPort | undefined = this.docPorts.find((p: LayoutPort): boolean => p.ownerCellId === curCellId && (p.name === args['fromPort'] || p.id === args['fromPort']));
            if (fp !== undefined) { x1 = fp.centerNm.x; y1 = fp.centerNm.y; ln = fp.layerNumber; dt = fp.datatype; wNm = fp.widthNm; }
          }
          if (typeof args['toPort'] === 'string') {
            const tp: LayoutPort | undefined = this.docPorts.find((p: LayoutPort): boolean => p.ownerCellId === curCellId && (p.name === args['toPort'] || p.id === args['toPort']));
            if (tp !== undefined) { x2 = tp.centerNm.x; y2 = tp.centerNm.y; }
          }
          this.ensureDshLayerExists(ln, dt, `L${ln}`, `互连层 ${ln}`, this.layerColor(this.docStore.layers.length));
          const midX: number = Math.round((x1 + x2) / 2);
          const routePts: Point[] = (x1 === x2 || y1 === y2)
            ? [{ x: x1, y: y1 }, { x: x2, y: y2 }]
            : [{ x: x1, y: y1 }, { x: midX, y: y1 }, { x: midX, y: y2 }, { x: x2, y: y2 }];
          const createdPath: Shape = editService.createPath(ln, routePts, wNm, dt, 0);
          this.syncShapesFromEditService();
          this.fitAllShapes();
          this.scheduleWorkspaceDraft();
          return {
            success: true,
            addedShapes: 1,
            summary: `已在 L${ln}/D${dt} 完成正交自动布线 (#${createdPath.id}, 线宽 ${wNm}nm)`,
            payloadJson: JSON.stringify({ success: true, shapeId: createdPath.id, points: routePts, widthNm: wNm })
          };
        }
        if (action === 'place_pcell') {
          const pName: string = String(args['pcellName'] ?? args['name'] ?? 'CIRCLE');
          const paramsObj: Record<string, number | string | boolean> =
            (args['parameters'] !== undefined && args['parameters'] !== null && typeof args['parameters'] === 'object')
              ? (args['parameters'] as Record<string, number | string | boolean>)
              : {};
          const res: AiNativeResult = this.runAiNativeEdit(parseAiNativeCall('pcell.place', JSON.stringify({
            name: pName,
            parameters: paramsObj,
            x: Number(args['x'] ?? 0),
            y: Number(args['y'] ?? 0),
            outputMode: 'instance',
            datatype: Number(args['datatype'] ?? 0),
            maxErrorNm: 2
          })));
          this.syncShapesFromEditService();
          this.rebuildCellTree();
          return { success: res.success, addedShapes: res.success ? 1 : 0, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'insert_library_item') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('library.insert', JSON.stringify({
            id: String(args['entryId'] ?? ''),
            x: Number(args['x'] ?? 0),
            y: Number(args['y'] ?? 0)
          })));
          return { success: res.success, addedShapes: res.success ? 1 : 0, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        throw new Error(`未知 manage_ports_and_routing 动作: ${action}`);
      },
      manageVerification: async (argsJson: string, _permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? 'run_drc');
        if (action === 'run_drc') {
          this.runDrc(true);
          const sum: string = this.aiDrcResultSummary();
          return { success: true, drcSummary: sum, summary: sum, payloadJson: JSON.stringify({ success: true, summary: sum, issues: this.verifyStore.drcIssues.slice(0, 24) }) };
        }
        if (action === 'focus_violation') {
          const idx: number = Math.max(0, Math.round(Number(args['index'] ?? 0)));
          if (idx < this.verifyStore.drcIssues.length) {
            this.locateIssue(this.verifyStore.drcIssues[idx]);
            return { success: true, summary: `已定位至第 ${idx + 1} 项 DRC 违规`, payloadJson: JSON.stringify({ success: true, issue: this.verifyStore.drcIssues[idx] }) };
          }
          return { success: false, summary: 'DRC 违规索引超出范围或当前无违规', payloadJson: JSON.stringify({ success: false }) };
        }
        if (action === 'set_drc_rule') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('drc.rule', JSON.stringify({
            id: String(args['ruleId'] ?? ''),
            value: Number(args['valueNm'] ?? 100),
            enabled: args['enabled'] !== false
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'import_drc_rules') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('drc.import_text', JSON.stringify({
            text: String(args['rulesText'] ?? ''),
            merge: args['merge'] !== false
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'reset_drc_rules') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('drc.builtin', '{}'));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'trace_nets') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('nets.trace', '{}'));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'extract_netlist') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('lvs.extract', '{}'));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'run_lvs') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('lvs.run', JSON.stringify({
            schematic: String(args['schematicSpice'] ?? '')
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        throw new Error(`未知 manage_verification 动作: ${action}`);
      },
      manageWorkbench: async (argsJson: string, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? '');
        if (action === 'undo' || action === 'redo') {
          if (permission === 'readonly') throw new Error('只读模式下不可撤销或重做');
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall(action === 'undo' ? 'edit.undo' : 'edit.redo', '{}'));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'select_by_ids') {
          const ids: number[] = Array.isArray(args['shapeIds']) ? (args['shapeIds'] as Object[]).map((v: Object): number => Number(v)) : [];
          editService.selectMultiple(ids);
          this.syncShapesFromEditService();
          return { success: true, summary: `已选中 ${ids.length} 个图元`, payloadJson: JSON.stringify({ success: true, selectedCount: ids.length }) };
        }
        if (action === 'select_all') {
          this.selectAllShapes();
          return { success: true, summary: `已全选当前单元 (${editService.getSelectedIds().length} 个图元)`, payloadJson: JSON.stringify({ success: true, selectedCount: editService.getSelectedIds().length }) };
        }
        if (action === 'clear_selection') {
          editService.clearSelection();
          this.syncShapesFromEditService();
          return { success: true, summary: '已清空当前选区', payloadJson: JSON.stringify({ success: true }) };
        }
        if (action === 'invert_selection') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('selection.invert', '{}'));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'filter_selection') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('selection.filter', JSON.stringify({
            layer: typeof args['layer'] === 'number' ? args['layer'] : -1,
            datatype: typeof args['datatype'] === 'number' ? args['datatype'] : -1,
            shapeType: typeof args['shapeType'] === 'string' ? args['shapeType'] : 'all'
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'new_tab') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('workspace.new', JSON.stringify({
            library: String(args['library'] ?? 'WORK_LIB'),
            top: String(args['topCell'] ?? 'TOP'),
            dbuNm: Number(args['dbuNm'] ?? 1)
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'switch_tab') {
          let tid: string = String(args['tabId'] ?? '');
          if (tid.length === 0 && typeof args['title'] === 'string') {
            const matchedTab: WorkspaceTab | undefined = this.docStore.workspaceTabs.find((t: WorkspaceTab): boolean => t.title.includes(args['title'] as string));
            if (matchedTab !== undefined) tid = matchedTab.id;
          }
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('workspace.switch', JSON.stringify({ id: tid })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'close_tab') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('workspace.close', JSON.stringify({ id: String(args['tabId'] ?? this.docStore.activeWorkspaceId) })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'rename_tab') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('workspace.rename', JSON.stringify({ title: String(args['title'] ?? '未命名版图') })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'save_checkpoint') {
          const ok: boolean = await this.saveWorkspaceDraft(true);
          return { success: ok, summary: ok ? '已保存工作区恢复检查点' : '保存检查点失败', payloadJson: JSON.stringify({ success: ok }) };
        }
        if (action === 'set_precision') {
          const cur: PrecisionSettings = this.precisionSettings();
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('precision.set', JSON.stringify({
            dbuNm: Number(args['dbuNm'] ?? cur.dbuNm),
            displayGridNm: Number(args['displayGridNm'] ?? cur.displayGridNm),
            drawStepNm: Number(args['drawStepNm'] ?? cur.drawStepNm),
            geometrySnapEnabled: cur.geometrySnapEnabled,
            geometrySnapKinds: cur.geometrySnapKinds
          })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        if (action === 'save_bookmark' || action === 'apply_bookmark') {
          const nm: string = String(args['name'] ?? 'BM_1');
          this.prepareViewWorkspace();
          if (action === 'save_bookmark') {
            this.handleViewWorkspaceAction('saveBookmark', '', nm);
            return { success: true, summary: `已保存视图书签 ${nm}`, payloadJson: JSON.stringify({ success: true, name: nm }) };
          }
          const bm: ViewBookmark | undefined = this.viewportStore.viewWorkspaceBookmarks.find((b: ViewBookmark): boolean => b.name === nm || b.id === nm);
          if (bm !== undefined) {
            this.handleViewWorkspaceAction('locateBookmark', bm.id, bm.name);
            return { success: true, summary: `已跳转到视图书签 ${bm.name}`, payloadJson: JSON.stringify({ success: true, bookmark: bm }) };
          }
          return { success: false, summary: `未找到书签 ${nm}`, payloadJson: JSON.stringify({ success: false }) };
        }
        if (action === 'list_macros') {
          const macros = macroService.getAllMacros();
          return { success: true, summary: `共 ${macros.length} 个可执行宏`, payloadJson: JSON.stringify({ success: true, macros }) };
        }
        if (action === 'run_macro') {
          const res: AiNativeResult = await this.runAiNativeAction(parseAiNativeCall('macro.run', JSON.stringify({ id: Number(args['macroId'] ?? 0) })));
          return { success: res.success, summary: res.message, payloadJson: JSON.stringify(res) };
        }
        throw new Error(`未知 manage_workbench 动作: ${action}`);
      },
      manageAttachmentsAndFiles: async (argsJson: string, _permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        let args: Record<string, Object> = {};
        try { args = JSON.parse(argsJson) as Record<string, Object>; } catch (_) {}
        const action: string = String(args['action'] ?? 'list_attachments');
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;

        const allKnownAttachments: AiChatAttachment[] = [];
        for (const m of this.aiStore.aiMessages) {
          for (const a of (m.attachments ?? [])) allKnownAttachments.push(a);
        }
        for (const a of this.aiStore.aiPendingAttachments) allKnownAttachments.push(a);

        const findAtt = (): AiChatAttachment | undefined => {
          const targetId: string = String(args['attachmentId'] ?? '').trim();
          const targetName: string = String(args['fileName'] ?? '').trim();
          if (targetId.length > 0) {
            const byId: AiChatAttachment | undefined = allKnownAttachments.find((a: AiChatAttachment): boolean => a.id === targetId);
            if (byId !== undefined) return byId;
          }
          if (targetName.length > 0) {
            const byName: AiChatAttachment | undefined = allKnownAttachments.find((a: AiChatAttachment): boolean => a.name === targetName);
            if (byName !== undefined) return byName;
          }
          return allKnownAttachments.length > 0 ? allKnownAttachments[allKnownAttachments.length - 1] : undefined;
        };

        if (action === 'list_attachments') {
          return {
            success: true,
            summary: `当前会话共有 ${allKnownAttachments.length} 个附件`,
            payloadJson: JSON.stringify({
              success: true,
              count: allKnownAttachments.length,
              attachments: allKnownAttachments.map((a: AiChatAttachment): DshAttachmentBriefItem => ({
                id: a.id, name: a.name, kind: a.kind, mimeType: a.mimeType, sizeBytes: a.sizeBytes, summary: a.summary ?? ''
              }))
            })
          };
        }
        if (action === 'read_attachment_text') {
          const att: AiChatAttachment | undefined = findAtt();
          if (att === undefined) throw new Error('未找到可读取的附件');
          const offset: number = Math.max(0, Number(args['offsetChars'] ?? 0));
          const maxChars: number = Math.min(32000, Math.max(256, Number(args['maxChars'] ?? 12000)));
          const fullText: string = aiAttachmentService.readAttachmentText(att, offset + maxChars);
          const slice: string = fullText.substring(offset, offset + maxChars);
          return {
            success: true,
            summary: `已读取附件 ${att.name} (${slice.length} 字符)`,
            payloadJson: JSON.stringify({ success: true, name: att.name, offsetChars: offset, content: slice })
          };
        }
        if (action === 'inspect_attachment_image') {
          const att: AiChatAttachment | undefined = findAtt();
          if (att === undefined || att.kind !== 'image') throw new Error('未找到对应的图片附件');
          return {
            success: true,
            summary: `已载入图片附件 ${att.name} 至多模态视觉上下文`,
            visualAttachment: att,
            payloadJson: JSON.stringify({ success: true, id: att.id, name: att.name, width: att.width, height: att.height })
          };
        }
        if (action === 'import_attachment_layout') {
          const att: AiChatAttachment | undefined = findAtt();
          if (att === undefined || att.kind !== 'layout') throw new Error('未找到可导入的 GDSII/OASIS 版图附件');
          const mode: 'new_tab' | 'merge' = String(args['importMode'] ?? 'new_tab') === 'merge' ? 'merge' : 'new_tab';
          const ok: boolean = await this.openAiLayoutAttachment(att, mode);
          return {
            success: ok,
            summary: ok ? `已将版图附件 ${att.name} 导入工作区 (${mode})` : `导入附件 ${att.name} 未完成`,
            payloadJson: JSON.stringify({ success: ok, name: att.name, importMode: mode })
          };
        }
        if (action === 'export_deliverable_to_chat') {
          const fmt: string = String(args['format'] ?? 'png').toLowerCase();
          const base: string = this.currentShareBaseName();
          let deliverable: AiChatAttachment;
          if (fmt === 'png' || fmt === 'svg') {
            if (!this.synchronizeCurrentDocument()) throw new Error('同步当前版图到渲染器失败');
            const w: number = Math.min(4096, Math.max(256, Number(args['widthPx'] ?? 1600)));
            const h: number = Math.min(4096, Math.max(256, Number(args['heightPx'] ?? 1200)));
            const exported = layoutExportService.exportImageToCacheForShare(
              fmt === 'svg' ? 'svg' : 'png',
              context.cacheDir,
              base,
              this.buildExportLayerStyles(),
              w,
              h
            );
            deliverable = aiAttachmentService.adoptSandboxFile(
              context,
              exported.sandboxPath,
              String(args['fileName'] ?? exported.fileName),
              fmt === 'svg' ? 'image/svg+xml' : 'image/png'
            );
          } else if (fmt === 'gds' || fmt === 'oas') {
            const outPath: string = `${context.cacheDir}/${base}_${Date.now()}.${fmt}`;
            if (fmt === 'oas') {
              if (!this.synchronizeCurrentDocument()) throw new Error('无法同步当前版图');
              const writeRes: GdsiiWriteResult = nativeHongTuService.writeOasis(outPath);
              if (!writeRes.success || writeRes.skippedShapes > 0) {
                throw new Error(writeRes.errorMessage || 'OASIS 版图未完整导出');
              }
            } else {
              await layoutExportService.writeGdsToPath(this.currentExportInput(), outPath);
            }
            deliverable = aiAttachmentService.adoptSandboxFile(
              context,
              outPath,
              String(args['fileName'] ?? `${base}.${fmt}`),
              fmt === 'oas' ? 'application/x-oasis' : 'application/x-gdsii'
            );
          } else if (fmt === 'spice') {
            this.loadExtractedNetlist();
            const spiceBody: string = String(args['content'] ?? this.verifyStore.lvsNetlistText ?? '* Empty SPICE netlist');
            deliverable = aiAttachmentService.writeTextDeliverable(
              context,
              String(args['fileName'] ?? `${base}.spice`),
              spiceBody,
              'text/plain'
            );
          } else {
            const ext: string = fmt === 'json' ? 'json' : 'md';
            const textBody: string = String(args['content'] ?? this.inspectCurrentWorkbenchUiJson());
            deliverable = aiAttachmentService.writeTextDeliverable(
              context,
              String(args['fileName'] ?? `${base}_report.${ext}`),
              textBody,
              fmt === 'json' ? 'application/json' : 'text/markdown'
            );
          }
          return {
            success: true,
            summary: `已向对话框交付文件 ${deliverable.name} (${deliverable.summary ?? ''})`,
            generatedAttachment: deliverable,
            payloadJson: JSON.stringify({
              success: true,
              id: deliverable.id,
              name: deliverable.name,
              kind: deliverable.kind,
              sizeBytes: deliverable.sizeBytes
            })
          };
        }
        if (action === 'copy_to_clipboard') {
          if (typeof args['content'] === 'string' && (args['content'] as string).length > 0) {
            const msg: string = await aiAttachmentService.copyTextToClipboard(args['content'] as string);
            return { success: true, summary: msg, payloadJson: JSON.stringify({ success: true, message: msg }) };
          }
          const att: AiChatAttachment | undefined = findAtt();
          if (att === undefined) throw new Error('未找到可复制的附件');
          const msg: string = await aiAttachmentService.copyAttachmentToClipboard(att);
          return { success: true, summary: msg, payloadJson: JSON.stringify({ success: true, message: msg, name: att.name }) };
        }
        throw new Error(`未知 manage_attachments_and_files 动作: ${action}`);
      },
      runDrcCheck: async (): Promise<DshToolExecutionOutcome> => {
        if (!aiService.getContextOptions().includeLayout) throw new Error('用户未发送版图资料');
        this.runDrc(true);
        const summary: string = this.aiDrcResultSummary();
        const last = drcService.getLastResult();
        const sampleViolations = (last?.violations ?? []).slice(0, 24).map((v: DrcViolation): DshDrcViolationSummary => ({
          id: v.id,
          ruleType: v.type,
          severity: v.severity,
          message: v.message,
          x: v.x,
          y: v.y
        }));
        return {
          success: true,
          drcSummary: summary,
          summary,
          payloadJson: JSON.stringify({
            success: true,
            summary,
            errors: last?.errors ?? 0,
            warnings: last?.warnings ?? 0,
            violations: sampleViolations
          })
        };
      },
      listNativeTools: (category: string, offset: number, toolName: string): string => {
        return JSON.stringify(aiNativeTools(category, offset, toolName));
      },
      callNativeTool: async (toolName: string, argumentsJson: string, permission: DshPermissionMode): Promise<DshToolExecutionOutcome> => {
        const call: AiNativeCall = parseAiNativeCall(toolName, argumentsJson);
        const def = aiNativeTool(call.name);
        if (def.requiresLayout && !aiService.getContextOptions().includeLayout) throw new Error('用户未发送版图资料');
        if (def.mode === 'read') {
          const readRes: AiNativeResult = this.readAiNativeTool(call);
          return { success: readRes.success, summary: readRes.message, payloadJson: JSON.stringify(readRes) };
        }
        if (permission === 'readonly') {
          throw new Error(`工具 ${call.name} 会修改版图，当前为只读问答模式`);
        }
        if (permission === 'review') {
          const stagedCmd: ParsedCommand = {
            type: AiCommandType.NATIVE_TOOL,
            params: { nativeTool: call.name, argumentsJson },
            description: `${def.title} (${call.name})`
          };
          this.aiStore.pendingAiCommands = [stagedCmd];
          this.aiStore.pendingAiContext = this.filteredAiContext(this.buildAiContext());
          this.pendingAiRevision = this.docStore.editorRevision;
          this.pendingAiDocumentId = this.docStore.activeWorkspaceId;
          this.pendingAiSelection = editService.getSelectedIds().join(',');
          this.pendingAiCell = editService.getCurrentCellId();
          this.pendingAiLayer = this.viewportStore.selectedLayerNumber;
          this.pendingAiDatatype = this.viewportStore.selectedDatatype;
          this.prepareAiReview([stagedCmd]);
          return {
            success: true,
            stagedPending: true,
            summary: `已准备原生工具 ${def.title} 待确认`,
            payloadJson: JSON.stringify({ success: true, stagedPending: true, tool: call.name })
          };
        }
        if (def.mode === 'edit') {
          const beforeCount: number = editService.getShapes().length;
          const beforeMarker: Object | null = editService.getUndoMarker();
          const res: AiNativeResult = this.runAiNativeEdit(call);
          this.syncShapesFromEditService();
          this.rebuildCellTree();
          this.aiUndoMarker = editService.getUndoMarker();
          this.aiStore.aiCanUndo = this.aiUndoMarker !== beforeMarker;
          this.scheduleWorkspaceDraft();
          const afterCount: number = editService.getShapes().length;
          return {
            success: res.success,
            addedShapes: Math.max(0, afterCount - beforeCount),
            deletedShapes: Math.max(0, beforeCount - afterCount),
            summary: res.message,
            payloadJson: JSON.stringify(res)
          };
        }
        const actRes: AiNativeResult = await this.runAiNativeAction(call);
        return { success: actRes.success, summary: actRes.message, payloadJson: JSON.stringify(actRes) };
      },
      executeKlayoutPython: async (
        script: string,
        applyMode: 'replace' | 'merge' | 'preview',
        inputMode: 'new' | 'document' | 'selection' = 'new',
        parametersJson: string = '{}'
      ): Promise<DshToolExecutionOutcome> => {
        if (!aiService.getContextOptions().includeLayout && inputMode !== 'new') {
          throw new Error('用户未发送版图资料');
        }
        const documentId: string = this.docStore.activeWorkspaceId;
        const revision: number = this.docStore.editorRevision;
        // 仅当用户显式切换到“外部桌面伴随服务”模式时才探测远程 HTTP；默认端侧内置完整 Python 3 直接离线运行！
        if (pythonBridgeService.getExecutionMode() === 'remote') {
          await pythonBridgeService.checkConnection(false);
        }
        if (!this.pageAlive || ticket !== this.aiRequestGeneration || generation !== this.pageGeneration ||
          documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
          throw new Error('文档已变化或请求已取消');
        }
        const beforeCount: number = editService.getShapes().length;
        const pyRes: AiNativeResult = await this.runAiNativePython(
          parseAiNativeCall('python.run', JSON.stringify({
            script,
            inputMode,
            applyMode,
            parameters: parametersJson
          }))
        );
        const afterCount: number = editService.getShapes().length;
        return {
          success: pyRes.success,
          addedShapes: pyRes.success ? Math.max(1, afterCount - beforeCount) : 0,
          summary: pyRes.message,
          payloadJson: JSON.stringify(pyRes)
        };
      }
    };
  }

  private async tryRunDemoHarnessShortcut(
    prompt: string,
    ticket: number,
    permission: DshPermissionMode,
    userAttachments: AiChatAttachment[]
  ): Promise<boolean> {
    const trimmed: string = prompt.trim();
    const conversationId: string = aiService.getActiveConversationId();
    const host: DshLayoutBackendHost = this.buildDshBackendHost(ticket);

    if (permission === 'auto' && /^(?:画|生成|创建|绘制).*(?:cmos\s*)?(?:反相器|inverter)/i.test(trimmed)) {
      const outcome: DshToolExecutionOutcome = this.executeDshInverterGeometry({
        cellName: 'INVERTER',
        gateLengthNm: 200,
        nmosWidthNm: 600,
        pmosWidthNm: 1200,
        target: 'auto'
      }, 'auto');
      const toolItem: AiChatToolState = {
        id: `demo-inv-${Date.now()}`,
        name: 'create_cmos_inverter',
        status: outcome.success ? 'completed' : 'failed',
        arguments: '{"cellName":"INVERTER","gateLengthNm":200,"nmosWidthNm":600,"pmosWidthNm":1200}',
        result: outcome.payloadJson
      };
      const steps: AiProcessStep[] = [{
        id: 'demo-step-inv',
        kind: 'tool',
        title: 'create_cmos_inverter',
        text: '',
        status: outcome.success ? 'completed' : 'failed',
        tool: toolItem
      }];
      const replyText: string = outcome.success
        ? `已在单元 **${this.docStore.currentEditingCellName}** 原生生成完整通用 CMOS 反相器版图（共 **${outcome.addedShapes ?? 0}** 个几何图元、**${outcome.addedPorts ?? 0}** 个电气端口 \`IN / OUT / VSS / VDD\`），并自动完成视图适配。`
        : outcome.summary;
      this.aiStore.aiTurnChangeSummary = outcome.success
        ? `本轮版图变更：+${outcome.addedShapes ?? 0} 图元 · +${outcome.addedPorts ?? 0} 端口 · ${outcome.drcSummary ?? ''}`
        : '';
      this.aiStore.aiLastResult = outcome.summary;
      this.panelStore.statusText = outcome.summary;
      const demoTask: AiAgentTask = aiService.createAgentTask(prompt, false, false);
      aiService.recordHarnessResult(prompt, replyText, '', [toolItem], outcome.success, outcome.success ? 'executed' : 'failed',
        conversationId, false, demoTask, steps, userAttachments);
      this.refreshAiConversation();
      return true;
    }

    if (/截图|查看当前(?:工作|画布|界面)|capture_screenshot/i.test(trimmed)) {
      const shotArgs: string = JSON.stringify({
        target: /整窗|窗口/.test(trimmed) ? 'workbench_window' : 'canvas_viewport',
        showInChat: true
      });
      const outcome: DshToolExecutionOutcome = await host.captureScreenshot(shotArgs);
      const toolItem: AiChatToolState = {
        id: `demo-shot-${Date.now()}`,
        name: 'capture_screenshot',
        status: outcome.success ? 'completed' : 'failed',
        arguments: shotArgs,
        result: outcome.payloadJson
      };
      const steps: AiProcessStep[] = [{ id: 'demo-step-shot', kind: 'tool', title: 'capture_screenshot', text: '', status: toolItem.status, tool: toolItem }];
      const generated: AiChatAttachment[] = outcome.generatedAttachment !== undefined ? [outcome.generatedAttachment] : [];
      const reply: string = outcome.success
        ? `已完成实时截图自检：当前编辑单元 **${this.docStore.currentEditingCellName}**，缩放 **${Math.round(this.viewportStore.zoomPercent)}%**，共 **${editService.getShapes().length}** 个图形、**${this.visibleLayerNumbers().length}** 个可见图层。截图卡片支持下方一键复制图片或另存。`
        : outcome.summary;
      const demoTask: AiAgentTask = aiService.createAgentTask(prompt, false, true);
      aiService.recordHarnessResult(prompt, reply, '', [toolItem], outcome.success, undefined,
        conversationId, false, demoTask, steps, userAttachments, generated);
      this.refreshAiConversation();
      return true;
    }

    const delLayerMatch: RegExpExecArray | null = /(?:删除|移除)(?:图层|层)\s*L?(\d+)(?:\s*[/,:D]\s*(\d+))?/i.exec(trimmed);
    if (permission !== 'readonly' && (delLayerMatch !== null || /清理空(?:图)?层|删除空(?:图)?层/.test(trimmed))) {
      const layerArgs: string = delLayerMatch !== null
        ? JSON.stringify({ action: 'delete', layer: Number(delLayerMatch[1]), datatype: delLayerMatch[2] !== undefined ? Number(delLayerMatch[2]) : 0 })
        : JSON.stringify({ action: 'delete_empty' });
      const outcome: DshToolExecutionOutcome = await host.manageLayers(layerArgs, permission);
      const toolItem: AiChatToolState = {
        id: `demo-layer-${Date.now()}`,
        name: 'manage_layers',
        status: outcome.success ? 'completed' : 'failed',
        arguments: layerArgs,
        result: outcome.payloadJson
      };
      const steps: AiProcessStep[] = [{ id: 'demo-step-layer', kind: 'tool', title: 'manage_layers', text: '', status: toolItem.status, tool: toolItem }];
      const demoTask: AiAgentTask = aiService.createAgentTask(prompt, false, false);
      aiService.recordHarnessResult(prompt, outcome.summary, '', [toolItem], outcome.success, outcome.success ? 'executed' : 'failed',
        conversationId, false, demoTask, steps, userAttachments);
      this.refreshAiConversation();
      return true;
    }

    return false;
  }

  private async runDshNativeAgentPrompt(
    prompt: string,
    ticket: number,
    permission: DshPermissionMode,
    userAttachments: AiChatAttachment[] = []
  ): Promise<void> {
    const generation: number = this.pageGeneration;
    const isCurrentPage = (): boolean => this.pageAlive && generation === this.pageGeneration;
    const conversationId: string = aiService.getActiveConversationId();
    const config: AiModelConfig = aiService.getConfig();
    const history: ChatMessage[] = aiService.getContextOptions().includeHistory ? aiService.getContextHistory().slice() : [];
    const compSummary: string = aiService.getCompression()?.summary ?? '';
    const task: AiAgentTask = aiService.createAgentTask(prompt, false, permission === 'readonly');
    let capturedSteps: AiProcessStep[] = [];
    let capturedTools: AiChatToolState[] = [];
    let capturedReasoning: string = '';
    let capturedAnswer: string = '';
    let capturedWebSources: DshWebSearchItem[] = [];
    let capturedGeneratedAttachments: AiChatAttachment[] = [];
    let capturedAskExchanges: AiAskUserExchange[] = [];
    let succeeded: boolean = false;
    let commandStatus: 'pending' | 'executed' | 'failed' | undefined = undefined;

    this.aiPythonPhase = 'dsh_native';
    try {
      const result: DshAgentRunResult = await dshLayoutAgentService.run(
        prompt,
        config,
        history,
        compSummary,
        permission,
        this.buildDshBackendHost(ticket),
        {
          onStatus: (statusText: string): void => {
            if (isCurrentPage() && ticket === this.aiRequestGeneration) {
              this.panelStore.statusText = statusText;
              this.flushAiStreamUiNow();
            }
          },
          onProgress: (steps: AiProcessStep[], liveAnswer: string, tools: AiChatToolState[]): void => {
            capturedSteps = steps.slice();
            capturedTools = tools.slice();
            capturedAnswer = liveAnswer;
            if (isCurrentPage() && ticket === this.aiRequestGeneration) {
              this.aiStore.aiToolCalls = tools.slice();
              this.aiStreamBufferedSteps = steps.slice();
              this.aiStreamBufferedAnswer = liveAnswer;
              this.flushAiStreamUiNow();
            }
          }
        },
        {
          userAttachments,
          webSearchEnabled: this.aiStore.aiWebSearchEnabled
        }
      );
      capturedSteps = result.steps;
      capturedTools = result.tools;
      capturedReasoning = result.fullReasoning;
      capturedAnswer = result.finalAnswer;
      capturedWebSources = result.webSources;
      capturedGeneratedAttachments = result.generatedAttachments;
      capturedAskExchanges = result.askUserExchanges;
      succeeded = true;
      commandStatus = result.stagedPending ? 'pending' : (result.mutatedLayout ? 'executed' : undefined);
      if (isCurrentPage() && ticket === this.aiRequestGeneration) {
        this.aiStore.aiTurnChangeSummary = result.turnChangeSummary;
        this.aiStore.aiLastResult = result.turnChangeSummary.length > 0 ? result.turnChangeSummary : 'AI 回复已就绪';
        this.panelStore.statusText = this.aiStore.aiLastResult;
        this.aiStore.aiError = '';
        if (!this.panelStore.showAiPanel) {
          this.aiStore.aiMinimizedNotice = this.aiStore.aiLastResult;
        }
      }
    } catch (err) {
      const rawErr: string = err instanceof Error ? err.message : String(err);
      const cancelled: boolean = ticket !== this.aiRequestGeneration || rawErr.includes('取消');
      capturedTools = capturedTools.map((t: AiChatToolState): AiChatToolState =>
        t.status === 'running' ? { id: t.id, name: t.name, status: 'failed', arguments: t.arguments, result: rawErr } : t
      );
      capturedSteps = capturedSteps.map((s: AiProcessStep): AiProcessStep =>
        s.status === 'running' ? { id: s.id, kind: s.kind, title: s.title, text: s.text, status: 'failed', tool: s.tool } : s
      );
      if (cancelled) {
        capturedAnswer = capturedAnswer.length > 0 ? `${capturedAnswer}

*（已手动停止生成）*` : '已停止本次生成。';
      } else {
        if (isCurrentPage()) {
          this.aiStore.aiError = rawErr;
          this.panelStore.statusText = `Agent 提示：${rawErr}`;
        }
        capturedAnswer = capturedAnswer.length > 0 ? `${capturedAnswer}

${rawErr}` : rawErr;
      }
      commandStatus = cancelled ? undefined : 'failed';
    } finally {
      this.aiStore.aiPendingAskUser = null;
      this.pendingAskUserResolve = null;
      try {
        aiService.recordHarnessResult(
          prompt,
          aiService.redactConversationText(capturedAnswer),
          aiService.redactConversationText(capturedReasoning),
          capturedTools,
          succeeded,
          commandStatus,
          conversationId,
          ticket !== this.aiRequestGeneration,
          task,
          capturedSteps,
          userAttachments,
          capturedGeneratedAttachments,
          capturedWebSources,
          capturedAskExchanges
        );
        if (isCurrentPage()) {
          this.refreshAiConversation();
        }
      } catch (_) {}
    }
  }

  private async runAiHarnessPrompt(prompt: string, context: AiContext, ticket: number, requestContext: string, task: AiAgentTask, resumeTask: boolean): Promise<void> {
    const generation: number = this.pageGeneration;
    const isCurrentPage: () => boolean = (): boolean => this.pageAlive && generation === this.pageGeneration;
    const conversationId: string = aiService.getActiveConversationId();
    let reply: AiHarnessResult | undefined;
    let historyPrompt: string = prompt;
    let historyTask: AiAgentTask = task;
    let redactHistory: (text: string) => string = (text: string): string => aiService.redactConversationText(text);
    let message: string = '';
    let businessSummary: string = '';
    let success: boolean = false;
    let published: number = 0;
    let expectedContext: string = requestContext;
    let commandStatus: 'pending' | 'executed' | 'failed' | undefined;
    const artifacts: PythonLayoutArtifact[] = [];
    let previousDraft: string | undefined;
    let capturedText: string = '', capturedReasoning: string = '';
    let capturedTools: AiChatToolState[] = [];
    let capturedSteps: AiProcessStep[] = [];
    let checkpoint: AiTaskCheckpoint | undefined;
    const setLocalStage: (stage: string, status: 'running' | 'completed' | 'failed', detail: string) => void =
      (stage: string, status: 'running' | 'completed' | 'failed', detail: string): void => {
        this.setAiLocalStage(ticket, stage, status, detail);
        if (!isCurrentPage() || ticket !== this.aiRequestGeneration) return;
        const id: string = `native:${ticket}:${stage}`;
        const item: AiChatToolState | undefined = this.aiStore.aiToolCalls.find((tool: AiChatToolState): boolean => tool.id === id);
        if (item === undefined) return;
        const owned: AiChatToolState = { id: item.id, name: item.name, status: item.status, arguments: item.arguments, result: item.result };
        const position: number = capturedTools.findIndex((tool: AiChatToolState): boolean => tool.id === id);
        if (position < 0) capturedTools.push(owned); else capturedTools[position] = owned;
        const stepId: string = `tool-${id}`;
        const sPos: number = capturedSteps.findIndex((s: AiProcessStep): boolean => s.id === stepId);
        if (sPos < 0) {
          capturedSteps.push({ id: stepId, kind: 'tool', title: owned.name, text: '', status, tool: owned });
        } else {
          capturedSteps[sPos] = { id: stepId, kind: 'tool', title: owned.name, text: '', status, tool: owned };
        }
        this.aiStreamBufferedSteps = capturedSteps.slice();
        this.flushAiStreamUiNow();
      };
    try { previousDraft = JSON.stringify(pythonWorkspaceService.draft() ?? null); } catch (_) {}
    try {
      const availableSlots: number = this.availableAiArtifactSlots();
      if (availableSlots === 0 && !task.readOnly && task.artifactGenerationAllowed && task.requiredValidationProfile !== undefined) {
        throw new Error(`当前已打开满 ${MAX_WORKSPACE_TABS} 个非空版图标签页，无法新建独立版图；请先关闭一个不用的标签页后再生成`);
      }
      this.aiPythonPhase = 'harness';
      reply = await aiHarnessService.run(prompt, context, aiService.getConfig(), aiService.getContextHistory().slice(),
        availableSlots, {
          onHistoryInput: (request: string, savedTask: AiAgentTask | undefined, redact: (text: string) => string): void => {
            historyPrompt = request;
            if (savedTask !== undefined) historyTask = savedTask;
            redactHistory = redact;
          },
          onRunId: (id: string): void => {
            checkpoint = { id, task: historyTask, documentIdentity: this.docStore.activeWorkspaceId, startedAt: Date.now(),
              updatedAt: Date.now(), phase: 'running', tools: [], receipt: context.executionReceipt ?? '' };
            aiService.saveTaskCheckpoint(checkpoint, conversationId);
          },
          onEditorQuery: async (query: AiEditorQuery): Promise<Object> => {
            this.assertAiRequestCurrent(ticket, requestContext);
            try {
              if (query.kind === 'native_tools') return aiNativeTools(query.category ?? '', query.offset ?? 0, query.toolName ?? '');
              if (query.kind === 'native_read') {
                const call: AiNativeCall = parseAiNativeCall(query.toolName ?? '', query.argumentsJson ?? '{}');
                const definition = aiNativeTool(call.name);
                if (definition.mode !== 'read') throw new Error('实时查询不能执行修改工具');
                if (definition.requiresLayout && this.filteredAiContext(this.buildAiContext()).layoutContextIncluded === false) throw new Error('用户未发送版图资料');
                return this.readAiNativeTool(call);
              }
              const snapshot: AiContext = this.filteredAiContext(this.buildAiContext());
              const counts: Map<number, number> = new Map<number, number>();
              const children: Map<number, Set<number>> = new Map<number, Set<number>>();
              if (query.kind === 'cells') for (const shape of this.shapes) {
                const owner: number = shape.ownerCellId ?? editService.getTopCellId(); counts.set(owner, (counts.get(owner) ?? 0) + 1);
                if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
                  let ids: Set<number> | undefined = children.get(owner);
                  if (ids === undefined) { ids = new Set<number>(); children.set(owner, ids); }
                  ids.add(shape.cellId);
                }
              }
              const allCells: AiCellInfo[] = query.kind === 'cells' ? this.propertyCellOptions().map((cell: PropertyCellOption): AiCellInfo => ({
                id: cell.id, name: cell.name, shapeCount: counts.get(cell.id) ?? 0, children: Array.from(children.get(cell.id) ?? new Set<number>()) })) : [];
              return queryAiWorkbench(query, { context: snapshot, shapes: editService.getShapes(), cells: allCells,
                drc: drcService.getLastResult()?.violations ?? [], rules: drcService.getRules(),
                ports: this.docPorts.filter((port: LayoutPort): boolean => port.ownerCellId === (query.cellId ?? editService.getCurrentCellId())),
                drcCurrent: this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision,
                ruleSource: `${drcService.ruleSourceText()}；${this.aiDrcResultSummary()}` });
            } catch (error) {
              const failed: AiEditorReply = { success: false, error: String(error).substring(0, 400), coordinateUnit: 'nm',
                source: query.kind, total: 0, offset: 0, truncated: false, items: [] };
              return failed;
            }
          },
          onText: (delta: string): void => {
            capturedText += delta;
            if (ticket === this.aiRequestGeneration && requestContext === this.aiRequestContext()) {
              this.appendAiStreamUiDelta('text', delta);
            }
          },
          onReasoning: (delta: string): void => {
            capturedReasoning += delta;
            if (ticket === this.aiRequestGeneration && requestContext === this.aiRequestContext()) {
              this.appendAiStreamUiDelta('reasoning', delta);
            }
          },
          onTool: (tool: HarnessToolState): void => {
            if (ticket === this.aiRequestGeneration && requestContext === this.aiRequestContext()) {
              this.flushAiStreamUiNow();
            }
            const copy: AiChatToolState = { id: tool.id, name: tool.name, status: tool.status,
              arguments: tool.arguments, result: tool.result };
            const capturedIndex: number = capturedTools.findIndex((item: AiChatToolState): boolean => item.id === tool.id);
            if (capturedIndex < 0) capturedTools.push(copy); else capturedTools[capturedIndex] = copy;
            if (checkpoint !== undefined && tool.status !== 'running') {
              checkpoint.tools = capturedTools.map((entry: AiChatToolState): AiChatToolState => ({ id: entry.id, name: entry.name,
                status: entry.status, arguments: redactHistory(entry.arguments).substring(0, 60000), result: redactHistory(entry.result).substring(0, 15000) }));
              checkpoint.updatedAt = Date.now(); aiService.saveTaskCheckpoint(checkpoint, conversationId);
            }
            if (!isCurrentPage() || ticket !== this.aiRequestGeneration || requestContext !== this.aiRequestContext()) return;
            const index: number = this.aiStore.aiToolCalls.findIndex((item: AiChatToolState): boolean => item.id === tool.id);
            const next: AiChatToolState[] = this.aiStore.aiToolCalls.slice();
            if (index < 0) next.push(copy); else next[index] = copy;
            this.aiStore.aiToolCalls = next;
          },
          onProgress: (steps: AiProcessStep[], liveAnswer: string): void => {
            capturedSteps = steps.slice();
            if (isCurrentPage() && ticket === this.aiRequestGeneration && requestContext === this.aiRequestContext()) {
              this.aiStreamBufferedSteps = steps.slice();
              this.aiStreamBufferedAnswer = liveAnswer;
              this.scheduleAiStreamUiCommit();
            }
          },
          onStatus: (status: string): void => {
            if (ticket === this.aiRequestGeneration && requestContext === this.aiRequestContext()) {
              this.panelStore.statusText = status;
              this.flushAiStreamUiNow();
            }
          },
          onContextUsage: (usage: HarnessContextUsage): void => {
            if (isCurrentPage() && ticket === this.aiRequestGeneration) this.aiStore.aiReportedContextUsage =
              `服务端估算 ${usage.usedTokens} / ${usage.windowTokens} tokens${usage.basis === 'provider_anchored' ? '（以用量作锚）' : '（启发式）'}`;
          }
        }, task.requiredValidationProfile, conversationId, '', task, resumeTask);
      capturedTools = reply.tools.slice();
      if (reply.steps !== undefined && reply.steps.length > 0) {
        capturedSteps = reply.steps.slice();
      }
      const answerBody: string = (reply.finalAnswer !== undefined && reply.finalAnswer.trim().length > 0)
        ? reply.finalAnswer
        : reply.text;
      this.assertAiRequestCurrent(ticket, requestContext);
      this.aiStreamBufferedText = answerBody;
      this.aiStreamBufferedReasoning = reply.reasoning;
      this.aiStreamBufferedSteps = capturedSteps.slice();
      this.aiStreamBufferedAnswer = answerBody;
      this.flushAiStreamUiNow();
      this.aiStore.aiToolCalls = reply.tools.slice();
      if (reply.artifacts.length > 0 && reply.commandsJson.trim().length > 0) {
        throw new Error('助手同时返回新文档和当前文档编辑方案，未自动应用，请分开请求');
      }
      if (reply.artifacts.length > 1) throw new Error('助手单次返回了多个产物，未载入，请每次生成一个版图');
      if (reply.artifacts.length > 0) {
        if (task.readOnly || !task.artifactGenerationAllowed) throw new Error('原任务未授权自动生成版图，助手产物未下载或载入');
        if (this.docStore.workspaceTabs.length + reply.artifacts.length > MAX_WORKSPACE_TABS && !this.isCurrentWorkspaceTabEmptyReusable()) {
          throw new Error(`最多同时打开 ${MAX_WORKSPACE_TABS} 个文档，请关闭一个标签页后重新生成`);
        }
        const ids: string[] = [];
        const hostContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
        this.aiPythonPhase = 'artifact';
        // Download every complete artifact before publishing any document. The source stays unchanged.
        for (const item of reply.artifacts) {
          if (ids.includes(item.artifactId)) throw new Error('助手返回了重复产物，未重复载入');
          ids.push(item.artifactId);
          setLocalStage('download', 'running', '正在下载并校验生成的版图文件');
          const artifact: PythonLayoutArtifact = await pythonBridgeService.loadAssistantArtifact(item.artifactId, hostContext);
          artifacts.push(artifact);
          this.assertAiRequestCurrent(ticket, requestContext);
          if (this.docStore.workspaceTabs.length + reply.artifacts.length > MAX_WORKSPACE_TABS && !this.isCurrentWorkspaceTabEmptyReusable()) {
            throw new Error(`最多同时打开 ${MAX_WORKSPACE_TABS} 个文档，请关闭一个标签页后重新生成`);
          }
          if (!artifact.script || artifact.script !== item.script || artifact.originalRequest !== prompt) {
            throw new Error('助手产物与本次需求或脚本不一致，未载入');
          }
          if (task.requiredValidationProfile === 'generic_inverter' && artifact.validationProfile !== 'generic_inverter') {
            throw new Error('反相器产物缺少要求的通用一致性检查，未载入');
          }
          setLocalStage('download', 'completed', '文件、图层定义和本次请求已核对');
        }
        this.aiPythonPhase = 'load';
        for (const artifact of artifacts) {
          if (checkpoint !== undefined) { checkpoint.phase = 'applying'; aiService.saveTaskCheckpoint(checkpoint, conversationId); }
          this.assertAiRequestCurrent(ticket, expectedContext);
          this.panelStore.statusText = `AI: 正在载入独立版图 ${published + 1}/${artifacts.length}…`;
          const loaded: boolean = await this.applyPythonResult(artifact, 'replace', -1,
            (): boolean => ticket === this.aiRequestGeneration && expectedContext === this.aiRequestContext(), true,
            (stage: string, status: 'running' | 'completed', detail: string): void => {
              setLocalStage(stage, status, detail);
            });
          if (!loaded) throw new Error(this.panelStore.statusText);
          published++;
          commandStatus = 'executed';
          if (checkpoint !== undefined) {
            checkpoint.loadedArtifacts = (checkpoint.loadedArtifacts ?? []).concat([artifact.artifactId ?? '']);
            checkpoint.phase = 'applied'; aiService.saveTaskCheckpoint(checkpoint, conversationId);
          }
          expectedContext = this.aiRequestContext();
        }
        commandStatus = 'executed';
        let check: string = '当前规则检查未完成';
        try {
          setLocalStage('drc', 'running', '正在执行当前可用的设计规则');
          this.runDrc(true);
          check = this.aiDrcResultSummary();
          const checked: boolean = this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision &&
            drcService.getLastResult() !== null;
          setLocalStage('drc', checked ? 'completed' : 'failed', check);
          this.scheduleAiGeneratedFit(ticket);
        } catch (_) {
          check = '当前规则检查未完成，请手动复检';
          setLocalStage('drc', 'failed', check);
        }
        message = `${answerBody}${answerBody.length > 0 ? '\n\n' : ''}` +
          `已载入 ${published} 个独立版图：${artifacts.map((artifact: PythonLayoutArtifact): string => artifact.name).join('、')}。` +
          `${check}。通用几何示例，未作工艺签核；原文档保留在原标签页。`;
        businessSummary = `已载入 ${published} 个独立版图。${check}。`;
      } else if (reply.workflow !== undefined) {
        if (task.readOnly || task.requiredValidationProfile !== undefined) throw new Error('原任务不允许专业编辑流程');
        this.pendingAiWorkflow = reply.workflow.workflow;
        this.pendingAiRunId = checkpoint?.id ?? '';
        this.aiStore.pendingAiContext = context; this.pendingAiDocumentId = this.docStore.activeWorkspaceId;
        this.pendingAiRevision = this.docStore.editorRevision; this.pendingAiCell = editService.getCurrentCellId();
        this.pendingAiSelection = editService.getSelectedIds().join(',');
        this.pendingAiLayer = this.viewportStore.selectedLayerNumber; this.pendingAiDatatype = this.viewportStore.selectedDatatype;
        this.aiStore.aiPendingSummary = '专业流程待确认';
        this.aiStore.aiPendingDetail = `${reply.workflow.summary}\n确认后打开原生参数与预览流程，尚未修改几何。`;
        commandStatus = 'pending'; message = this.aiStore.aiPendingDetail; businessSummary = this.aiStore.aiPendingSummary;
      } else if (reply.commandsJson.trim().length > 0) {
        if (task.readOnly) throw new Error('原任务为只读说明，助手编辑方案未进入应用流程');
        if (task.requiredValidationProfile !== undefined) throw new Error('原任务必须通过固定反相器验证，不能用编辑方案绕过');
        const commands: ParsedCommand[] = aiService.parseText(reply.commandsJson, context);
        if (commands.length === 0) throw new Error('助手编辑方案无有效命令，版图未修改');
        if (commands[0].type === AiCommandType.NATIVE_TOOL) validateAiNativeBatch(commands.map((command: ParsedCommand): AiNativeCall => parseAiNativeCall(command.params.nativeTool ?? '',command.params.argumentsJson ?? '{}')));
        this.aiStore.pendingAiCommands = commands;
        this.aiStore.pendingAiContext = context;
        this.pendingAiPrompt = prompt;
        this.pendingAiReply = reply.text;
        this.pendingAiRevision = this.docStore.editorRevision;
        this.pendingAiDocumentId = this.docStore.activeWorkspaceId;
        this.pendingAiSelection = editService.getSelectedIds().join(',');
        this.pendingAiCell = editService.getCurrentCellId();
        this.pendingAiLayer = this.viewportStore.selectedLayerNumber;
        this.pendingAiDatatype = this.viewportStore.selectedDatatype;
        this.aiStore.aiPendingSummary = `${commands.length} 项操作待确认`;
        this.aiStore.aiPendingDetail = commands.map((command: ParsedCommand): string => command.description || command.type).join('\n');
        this.prepareAiReview(commands);
        this.pendingAiRunId = checkpoint?.id ?? '';
        commandStatus = 'pending';
        message = `${answerBody}${answerBody.length > 0 ? '\n\n' : ''}编辑方案已生成，确认后应用；版图尚未修改。`;
        businessSummary = `${commands.length} 项操作待确认，版图未修改`;
      } else {
        message = answerBody || reply.text || '助手运行结束，未返回可显示的正文或版图结果。';
        businessSummary = 'AI 回复已就绪';
      }
      success = true;
      this.aiStore.aiError = '';
    } catch (error) {
      capturedTools = capturedTools.map((tool: AiChatToolState): AiChatToolState => tool.status === 'running'
        ? { id: tool.id, name: tool.name, status: 'failed', arguments: tool.arguments,
          result: ticket !== this.aiRequestGeneration ? '已取消等待，步骤未完成；后台工具可能仍在收尾' : '步骤未完成，请查看答复说明' } : tool);
      capturedSteps = capturedSteps.map((step: AiProcessStep): AiProcessStep => {
        if (step.status !== 'running') return step;
        return {
          id: step.id,
          kind: step.kind,
          title: step.title,
          text: step.text,
          status: 'failed',
          tool: step.tool === undefined ? undefined : {
            id: step.tool.id,
            name: step.tool.name,
            status: 'failed',
            arguments: step.tool.arguments,
            result: ticket !== this.aiRequestGeneration ? '已取消等待，步骤未完成；后台工具可能仍在收尾' : '步骤未完成，请查看答复说明'
          }
        };
      });
      const detail: string = ticket !== this.aiRequestGeneration ? '已取消生成等待；后续结果不应用，后台工具可能仍在收尾' :
        `助手未完成：${error instanceof Error ? error.message : String(error)}`;
      if (isCurrentPage()) this.aiStore.aiToolCalls = capturedTools.slice();
      const partial: string = reply?.text ?? capturedText;
      const cleanDetail: string = detail.replace(/[。．.]+$/, '');
      message = `${partial}${partial.length > 0 ? '\n\n' : ''}${cleanDetail}。` +
        (published > 0 ? `已载入 ${published} 个独立版图；剩余结果未载入，原文档保留。` : '原文档未修改。');
      businessSummary = detail.replace(/\s+/g, ' ').substring(0, 120);
      if (isCurrentPage() && ticket === this.aiRequestGeneration) this.aiStore.aiError = detail;
    } finally {
      // Persistence errors cannot reclassify a successfully published document as an execution failure.
      for (let index = 0; index < artifacts.length; index++) {
        const artifact: PythonLayoutArtifact = artifacts[index];
        const note: string = this.preserveAiPythonRun(prompt, artifact.script ?? '', artifact, message, index < published,
          ticket, expectedContext, previousDraft);
        if (note.length > 0) message += ` ${note}`;
        try { previousDraft = JSON.stringify(pythonWorkspaceService.draft() ?? null); } catch (_) {}
      }
      if (isCurrentPage()) {
        this.aiStore.aiLastResult = message;
        this.panelStore.statusText = businessSummary;
        if (!this.panelStore.showAiPanel && commandStatus !== 'pending' && businessSummary.length > 0) {
          this.aiStore.aiMinimizedNotice = businessSummary;
        }
      }
      try {
        if (checkpoint !== undefined) {
          checkpoint.phase = published > 0 ? 'applied' : checkpoint.phase === 'applying' ? 'applying' :
            commandStatus === 'pending' ? 'pending' : ticket !== this.aiRequestGeneration ? 'cancelled' : success ? 'completed' : 'failed';
          checkpoint.tools = capturedTools.map((tool: AiChatToolState): AiChatToolState => ({ id: tool.id, name: tool.name,
            status: tool.status, arguments: redactHistory(tool.arguments).substring(0, 60000), result: redactHistory(tool.result).substring(0, 15000) }));
          checkpoint.updatedAt = Date.now(); checkpoint.receipt = redactHistory(message).substring(0, 15000);
          aiService.saveTaskCheckpoint(checkpoint, conversationId);
        }
        aiService.recordHarnessResult(historyPrompt, redactHistory(message), redactHistory(reply?.reasoning ?? capturedReasoning),
          capturedTools.map((tool: AiChatToolState): AiChatToolState => ({ id: tool.id, name: tool.name, status: tool.status,
            arguments: redactHistory(tool.arguments), result: redactHistory(tool.result) })),
          success, commandStatus, conversationId, ticket !== this.aiRequestGeneration, historyTask, capturedSteps);
        if (isCurrentPage()) this.refreshAiConversation();
      } catch (error) {
        if (isCurrentPage()) {
          this.aiStore.aiError = `聊天记录保存失败：${error instanceof Error ? error.message : String(error)}`;
          this.panelStore.statusText += ' 聊天记录未保存，版图操作结果以当前文档为准。';
        }
      }
      redactHistory = (text: string): string => text;
      if (isCurrentPage()) this.aiStore.aiCanUndo = false;
    }
  }

  private async recoverAiArtifact(): Promise<void> {
    if (this.aiStore.aiLoading || this.aiStore.aiPendingSummary.length > 0) return;
    const checkpoint: AiTaskCheckpoint | undefined = aiService.getTaskCheckpoint();
    if (checkpoint === undefined || checkpoint.task.readOnly || !checkpoint.task.artifactGenerationAllowed ||
      checkpoint.phase === 'applying' || checkpoint.documentIdentity !== this.docStore.activeWorkspaceId) {
      this.aiStore.aiError = '没有可在当前文档安全恢复的生成任务；请先核对任务所属文档'; return;
    }
    let artifactId: string = '';
    for (const tool of checkpoint.tools) {
      if (tool.status !== 'completed' || !['create_cmos_inverter', 'execute_layout_python'].includes(tool.name)) continue;
      try {
        const value = JSON.parse(tool.result) as Record<string, string | boolean>;
        if (value.success === true && typeof value.artifactId === 'string' && /^[a-f0-9]{32}$/.test(value.artifactId)) artifactId = value.artifactId;
      } catch (_) {}
    }
    if (!artifactId || (checkpoint.loadedArtifacts ?? []).includes(artifactId)) { this.aiStore.aiError = '没有尚未载入的生成产物；已载入的产物不会重复打开'; return; }
    if (this.docStore.workspaceTabs.length >= MAX_WORKSPACE_TABS && !this.isCurrentWorkspaceTabEmptyReusable()) {
      this.aiStore.aiError = `最多同时打开 ${MAX_WORKSPACE_TABS} 个版图，请先关闭一个标签页再恢复生成产物`;
      return;
    }
    const ticket: number = ++this.aiRequestGeneration;
    const expected: string = this.aiRequestContext();
    this.aiStore.aiLoading = true; this.aiStore.aiCanCancel = true; this.aiPythonPhase = 'artifact';
    let artifact: PythonLayoutArtifact | undefined;
    let loaded: boolean = false;
    try {
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext;
      artifact = await pythonBridgeService.loadAssistantArtifact(artifactId, host);
      this.assertAiRequestCurrent(ticket, expected);
      if (artifact.originalRequest !== checkpoint.task.originalRequest && !artifact.originalRequest?.startsWith('继续上一次') &&
        !artifact.originalRequest?.startsWith('重试上一次')) throw new Error('产物所属需求与恢复任务不符');
      if (checkpoint.task.requiredValidationProfile && artifact.validationProfile !== checkpoint.task.requiredValidationProfile) throw new Error('产物缺少原任务要求的验证');
      checkpoint.phase = 'applying'; checkpoint.updatedAt = Date.now(); aiService.saveTaskCheckpoint(checkpoint);
      this.aiStore.aiCanCancel = false; this.aiPythonPhase = 'load';
      loaded = await this.applyPythonResult(artifact, 'replace', -1, (): boolean => ticket === this.aiRequestGeneration && expected === this.aiRequestContext(), true);
      if (!loaded) throw new Error(this.panelStore.statusText);
      checkpoint.loadedArtifacts = (checkpoint.loadedArtifacts ?? []).concat([artifactId]);
      checkpoint.phase = 'applied'; checkpoint.updatedAt = Date.now();
      this.runDrc(true); checkpoint.receipt = `已恢复并载入现有生成产物 ${artifactId}，没有重新调用模型。${this.aiDrcResultSummary()}`;
      aiService.saveTaskCheckpoint(checkpoint); aiService.recordExecutionReceipt(checkpoint.receipt);
      pythonWorkspaceService.record(checkpoint.task.originalRequest, artifact.script ?? '', '{}', 'new', true, checkpoint.receipt, artifact);
      this.aiStore.aiLastResult = checkpoint.receipt; this.aiStore.aiError = ''; this.fitAllShapes();
    } catch (error) {
      this.aiStore.aiError = `${loaded ? '版图已载入，恢复回执或复检未完成，请勿重复载入' : '生成产物未恢复'}：${String(error)}`;
    } finally {
      this.aiStore.aiLoading = false; this.aiStore.aiCanCancel = false; this.aiPythonPhase = ''; this.refreshAiConversation();
    }
  }

  private preserveAiPythonRun(prompt: string, script: string, artifact: PythonLayoutArtifact | undefined,
                              message: string, loaded: boolean, ticket: number, requestContext: string,
                              previousDraft: string | undefined): string {
    if (script.trim().length === 0) return '';
    const notes: string[] = [];
    try {
      // History success means isolated execution produced a result, just like the manual Python panel.
      // The full request is the record name; message separately records whether automatic loading succeeded.
      pythonWorkspaceService.record(prompt, script, '{}', 'new', artifact !== undefined, message, artifact);
      notes.push('脚本与原始需求已保存到 Python 运行历史，可打开修改。');
    } catch (error) {
      notes.push(`Python 运行历史保存失败：${error instanceof Error ? error.message : String(error)}`);
    }
    if (!this.pageAlive || ticket !== this.aiRequestGeneration || requestContext !== this.aiRequestContext()) return notes.join(' ');
    try {
      // A different draft or an already open Python editor belongs to the user, even if geometry did not change.
      if (previousDraft === undefined || this.panelStore.showPythonPanel ||
        previousDraft !== JSON.stringify(pythonWorkspaceService.draft() ?? null)) {
        notes.push('已有 Python 编辑草稿已保留，请从运行历史选择本次脚本。');
      } else {
        pythonWorkspaceService.saveDraft({ script, parameters: '{}', inputMode: 'new', request: prompt,
          sweepName: '', sweepValues: '', templateName: '' });
      }
    } catch (error) {
      notes.push(`Python 编辑草稿保存失败：${error instanceof Error ? error.message : String(error)}`);
    }
    return notes.join(' ');
  }

  private setLastAiCommandStatus(status: 'pending' | 'executed' | 'failed' | undefined): void {
    try {
      aiService.updateLastCommandStatus(status);
      this.refreshAiConversation();
    } catch (error) {
      this.aiStore.aiError = `聊天状态保存失败：${error instanceof Error ? error.message : String(error)}`;
      this.panelStore.statusText += ' 聊天状态未保存。';
    }
  }

  private prepareAiReview(commands: ParsedCommand[]): void {
    this.pendingAiAllCommands = commands.slice(); this.aiStore.aiReviewGroups = groupAiEdits(commands);
    this.updateAiReviewDetail();
  }

  private toggleAiReviewGroup(id: string, accepted: boolean): void {
    if (this.aiStore.aiLoading) return;
    this.aiStore.aiReviewGroups = this.aiStore.aiReviewGroups.map((group: AiReviewGroup): AiReviewGroup => ({ id: group.id, title: group.title,
      indexes: group.indexes, targetIds: group.targetIds, accepted: group.id === id ? accepted : group.accepted }));
    this.aiStore.pendingAiCommands = acceptedAiEdits(this.pendingAiAllCommands, this.aiStore.aiReviewGroups);
    this.updateAiReviewDetail();
  }

  private updateAiReviewDetail(): void {
    if (this.aiStore.pendingAiCommands.some((command: ParsedCommand): boolean => command.type === AiCommandType.NATIVE_TOOL)) {
      const calls: AiNativeCall[] = this.aiStore.pendingAiCommands.map((command: ParsedCommand): AiNativeCall => parseAiNativeCall(command.params.nativeTool ?? '', command.params.argumentsJson ?? '{}'));
      const atomic: boolean = calls.every((call: AiNativeCall): boolean => aiNativeTool(call.name).mode === 'edit');
      this.aiStore.aiPendingSummary = `${calls.length} 项原生工具${atomic ? '，整批应用后可一次撤销' : '，单独执行并返回实际状态'}`;
      this.aiStore.aiPendingDetail = calls.map((call: AiNativeCall): string => `${aiNativeTool(call.name).title} (${call.name})\n${JSON.stringify(call.arguments, null, 2)}`).join('\n\n');
      return;
    }
    const preview = buildAiCommandPreview(this.aiStore.pendingAiCommands, this.aiStore.pendingAiContext, editService.getShapes(), editService.getSelectedIds());
    const dimensions: string[] = preview.boxes.slice(0, 12).map((box: AiPreviewBox): string => {
      const after: string = `${(box.bounds.maxX - box.bounds.minX).toFixed(2)} × ${(box.bounds.maxY - box.bounds.minY).toFixed(2)} nm`;
      const before: string = box.beforeBounds === undefined ? '新增' :
        `${(box.beforeBounds.maxX - box.beforeBounds.minX).toFixed(2)} × ${(box.beforeBounds.maxY - box.beforeBounds.minY).toFixed(2)} nm`;
      return `${box.label}${box.shapeId === undefined ? '' : ` #${box.shapeId}`}：${before} → ${box.deleted ? '删除' : after}`;
    });
    this.aiStore.aiPendingSummary = `${this.aiStore.pendingAiCommands.length}/${this.pendingAiAllCommands.length} 项操作已选，确认后作为一次撤销`;
    this.aiStore.aiPendingDetail = this.aiStore.pendingAiCommands.map((command: ParsedCommand): string => command.description || command.type).join('\n') +
      '\n预计几何范围（nm）：\n' + dimensions.join('\n') + (preview.boxes.length > 12 ? '\n更多对象见画布预览' : '') +
      (preview.note ? `\n${preview.note}` : '');
  }

  private focusAiReview(): void {
    const boxes: AiPreviewBox[] = buildAiCommandPreview(this.aiStore.pendingAiCommands, this.aiStore.pendingAiContext, editService.getShapes(), editService.getSelectedIds()).boxes;
    if (boxes.length === 0) { this.aiStore.aiError = '当前方案没有可确定的几何范围'; return; }
    this.focusWorldBounds({ minX: Math.min(...boxes.map((box: AiPreviewBox): number => box.bounds.minX)),
      minY: Math.min(...boxes.map((box: AiPreviewBox): number => box.bounds.minY)),
      maxX: Math.max(...boxes.map((box: AiPreviewBox): number => box.bounds.maxX)),
      maxY: Math.max(...boxes.map((box: AiPreviewBox): number => box.bounds.maxY)) });
  }

  private cancelPendingAiCommands(report: boolean = true): void {
    if (this.aiStore.pendingAiCommands.length > 0 || this.pendingAiWorkflow.length > 0) {
      this.setLastAiCommandStatus(undefined);
      if (report) {
        this.aiStore.aiLastResult = '已取消待应用方案，版图未修改';
        this.panelStore.statusText = '已取消待应用方案，版图未修改';
      }
    }
    this.aiStore.pendingAiCommands = [];
    this.pendingAiWorkflow = '';
    this.pendingAiRunId = '';
    this.pendingAiAllCommands = []; this.aiStore.aiReviewGroups = [];
    this.aiStore.pendingAiContext = null;
    this.pendingAiDocumentId = '';
    this.aiStore.aiPendingSummary = '';
    this.aiStore.aiPendingDetail = '';
  }

  private applyPendingAiCommands(): void {
    if (this.aiStore.aiLoading) return;
    if (this.aiStore.pendingAiContext === null || (this.aiStore.pendingAiCommands.length === 0 && this.pendingAiWorkflow.length === 0)) return;
    if (this.pendingAiDocumentId !== this.docStore.activeWorkspaceId || this.pendingAiRevision !== this.docStore.editorRevision || this.pendingAiCell !== editService.getCurrentCellId() ||
      this.pendingAiSelection !== editService.getSelectedIds().join(',') || this.pendingAiLayer !== this.viewportStore.selectedLayerNumber || this.pendingAiDatatype !== this.viewportStore.selectedDatatype) {
      this.cancelPendingAiCommands(false);
      this.aiStore.aiError = '版图、当前层或选择已改变，请重新生成方案后再应用。';
      return;
    }
    if (this.aiStore.pendingAiCommands.some((command: ParsedCommand): boolean => command.type === AiCommandType.NATIVE_TOOL)) {
      this.applyPendingAiNativeTools(); return;
    }
    if (this.pendingAiWorkflow.length > 0) {
      const workflow: string = this.pendingAiWorkflow;
      if (workflow.startsWith('boolean_')) {
        const available: WorkbenchCommand | undefined = this.workbenchCommands().find((command: WorkbenchCommand): boolean => command.id === 'boolean');
        if (available === undefined || !available.enabled) { this.aiStore.aiError = available?.reason ?? '布尔操作不可用'; return; }
        this.applyBooleanOp(workflow === 'boolean_union' ? 'merge' : workflow === 'boolean_intersection' ? 'intersect' : 'subtract');
      } else {
        const command: string = workflow === 'ports' ? 'portManager' : workflow === 'route' ? 'portRoute' :
          workflow === 'cell_hierarchy' ? 'cellMaintenance' : 'pcell';
        if (!this.executeWorkbenchCommand(command)) return;
      }
      this.cancelPendingAiCommands(false);
      this.aiStore.aiLastResult = '已打开原生参数与预览流程，尚未确认或应用几何修改。';
      try {
        const handoff: AiTaskCheckpoint | undefined = aiService.getTaskCheckpoint();
        if (handoff !== undefined) { handoff.phase = 'completed'; handoff.receipt = this.aiStore.aiLastResult; handoff.updatedAt = Date.now(); aiService.saveTaskCheckpoint(handoff); }
        aiService.recordExecutionReceipt(this.aiStore.aiLastResult); this.refreshAiConversation();
      } catch (error) { this.aiStore.aiError = `流程已打开，回执未保存：${String(error)}`; }
      return;
    }
    const savedCheckpoint: AiTaskCheckpoint | undefined = aiService.getTaskCheckpoint();
    const checkpoint: AiTaskCheckpoint | undefined = savedCheckpoint?.id === this.pendingAiRunId ? savedCheckpoint : undefined;
    if (checkpoint !== undefined && ['applied', 'applying'].includes(checkpoint.phase)) { this.aiStore.aiError = '本方案已有应用记录，请核对版图，不能重复应用'; return; }
    if (checkpoint !== undefined) {
      checkpoint.phase = 'applying'; checkpoint.updatedAt = Date.now();
      try { aiService.saveTaskCheckpoint(checkpoint); } catch (error) { this.aiStore.aiError = `无法保存应用前记录，未修改版图：${String(error)}`; return; }
    }
    let applied: boolean = false;
    try {
      applied = this.applyAiCommands(this.aiStore.pendingAiCommands, this.pendingAiReply, this.pendingAiPrompt, this.aiStore.pendingAiContext);
    } catch (error) {
      this.aiStore.aiError = `执行状态需要核对：${String(error)}；请检查当前版图，不要重复应用。`;
      this.aiStore.aiLastResult = this.aiStore.aiError;
      this.aiStore.pendingAiCommands = []; this.pendingAiAllCommands = []; this.aiStore.aiReviewGroups = [];
      this.aiStore.pendingAiContext = null; this.aiStore.aiPendingSummary = ''; this.aiStore.aiPendingDetail = '';
      return;
    }
    try {
      if (checkpoint !== undefined) {
        checkpoint.phase = applied ? 'applied' : 'failed'; checkpoint.updatedAt = Date.now();
        checkpoint.receipt = `文档 ${this.docStore.activeWorkspaceId} / 版本 ${this.docStore.editorRevision} / Cell ${editService.getCurrentCellId()}\n${this.aiStore.aiLastResult}`;
        aiService.saveTaskCheckpoint(checkpoint);
      }
      aiService.recordExecutionReceipt(`原生执行回执\n${checkpoint?.receipt ?? this.aiStore.aiLastResult}`);
      this.refreshAiConversation();
    } catch (error) {
      this.aiStore.aiError = `${applied ? '修改已应用' : '方案未应用'}，回执保存失败：${String(error)}；请勿重复应用。`;
    } finally {
      this.aiStore.pendingAiCommands = [];
      this.pendingAiAllCommands = []; this.aiStore.aiReviewGroups = [];
      this.aiStore.pendingAiContext = null;
      this.aiStore.aiPendingSummary = '';
      this.aiStore.aiPendingDetail = '';
    }
  }

  private aiGeometryContext(): AiGeometryContext {
    return { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState(),
      technologyJson: technologyService.serialize(), hierarchyDepth: this.docStore.hierarchyDepth,
      cells: this.propertyCellOptions(), document: this.workspaceDocument() };
  }

  private aiNativePage(rows: Object[], args: Record<string, Object>): Object {
    const offset: number = (args['offset'] as number) ?? 0, limit: number = (args['limit'] as number) ?? 24;
    return aiNativeData({ total: rows.length, offset, nextOffset: offset + limit < rows.length ? offset + limit : undefined,
      truncated: offset + limit < rows.length, items: rows.slice(offset, offset + limit) });
  }

  private readAiNativeTool(call: AiNativeCall): AiNativeResult {
    const args: Record<string, Object> = call.arguments;
    let data: Object;
    switch (call.name) {
      case 'pcells.list': data = this.aiNativePage(nativeHongTuService.listPCells(), args); break;
      case 'workbench.commands': data = this.workbenchCommands(); break;
      case 'stack.get': data = technologyService.getLayerStack() ?? aiNativeData({ loaded: false }); break;
      case 'stack.build': {
        const stack: PhysicalLayerStack | undefined = technologyService.getLayerStack();
        if (stack === undefined) throw new Error('当前工艺没有物理层栈');
        const result: LayerStackResult = this.buildLayerStack(stack,args as Object as LayerStackBuildOptions);
        if (!result.ok || result.preview === undefined) return aiNativeResult(false,result.message);
        return aiNativeResult(true,result.message,aiNativeData({ totalVolumeNm3: result.preview.totalVolumeNm3, sourcePolygons: result.preview.sourcePolygons,
          placements: result.preview.placements, warnings: result.preview.warnings, meshes: result.preview.meshes.map((mesh): AiNativeData => ({ levelId: mesh.levelId, materialId: mesh.materialId, volumeNm3: mesh.volumeNm3, surfaceAreaNm2: mesh.surfaceAreaNm2 })) }),'read_only');
      }
      case 'python.workspace': data = aiNativeData({ loaded: pythonWorkspaceService.draft() !== undefined,
        templates: this.aiNativePage(pythonWorkspaceService.templates().map((row): AiNativeData => ({ id: row.id,title: row.name,inputMode: row.inputMode })),args),
        history: this.aiNativePage(pythonWorkspaceService.history().map((row): AiNativeData => ({ id: row.id, title: row.name, timestamp: row.timestamp, inputMode: row.inputMode, success: row.success, message: row.message })),args) }); break;
      case 'python.detail': case 'macros.detail': {
        let record: Object | undefined;
        if (call.name === 'macros.detail') record = macroService.getMacro(args['id'] as number);
        else if (args['source'] === 'draft') record = pythonWorkspaceService.draft();
        else if (args['source'] === 'template') record = pythonWorkspaceService.templates().find((row): boolean => row.id === args['id']);
        else {
          const row = pythonWorkspaceService.history().find((item): boolean => item.id === args['id']);
          if (row !== undefined) record = { id: row.id,name: row.name,script: row.script,parameters: row.parameters,inputMode: row.inputMode } as PythonTemplate;
        }
        if (record === undefined) throw new Error('脚本或宏记录不存在');
        const text: string = JSON.stringify(record), offset: number = (args['offset'] as number) ?? 0, limit: number = (args['limit'] as number) ?? 12000;
        data = aiNativeData({ text: text.substring(offset,offset+limit),total: text.length,offset,
          nextOffset: offset+limit < text.length ? offset+limit : undefined,truncated: offset+limit < text.length }); break;
      }
      case 'technology.get': data = aiNativeData({ active: technologyService.getActive(), ruleSource: drcService.ruleSourceText(), rules: this.aiNativePage(drcService.getRules(), args) }); break;
      case 'precision.get': data = this.precisionSettings(); break;
      case 'layers.list': data = this.aiNativePage(this.docStore.layers, args); break;
      case 'workspace.list': data = aiNativeData({ activeId: this.docStore.activeWorkspaceId, tabs: unwrapObserved(this.docStore.workspaceTabs),
        history: this.aiNativePage(workspaceService.listHistory(this.docStore.activeWorkspaceId).map((row: WorkspaceHistory): AiNativeData => ({ id: row.id, documentId: row.documentId, title: row.title, createdAt: row.createdAt })), args) }); break;
      case 'views.list': {
        this.prepareViewWorkspace(); this.refreshViewWorkspace();
        data = aiNativeData({ activeId: this.viewportStore.viewWorkspaceActiveId,
          views: this.aiNativePage(this.viewportStore.viewWorkspaceViews, args), bookmarks: this.aiNativePage(this.viewportStore.viewWorkspaceBookmarks, args) }); break;
      }
      case 'macros.list': data = this.aiNativePage(macroService.getAllMacros().map((row): AiNativeData => ({ id: row.id,title: row.name,stepCount: row.steps.length })), args); break;
      case 'library.list': data = this.aiNativePage(componentLibraryService.list().map((entry: ComponentLibraryEntry): AiNativeData => ({ id: entry.id, title: entry.title, category: entry.category, pcellName: entry.pcellName, params: entry.params })), args); break;
      case 'verification.get': data = aiNativeData({ drc: this.aiDrcResultSummary(), rules: drcService.ruleSourceText(), lvsCurrent: this.netSnapshotRevision === this.docStore.editorRevision,
        lvs: this.netSnapshotRevision === this.docStore.editorRevision ? this.verifyStore.lvsResult : undefined,
        nets: this.aiNativePage(this.netSnapshotRevision === this.docStore.editorRevision ? this.verifyStore.tracedNets : [], args) }); break;
      case 'rdb.get': data = this.rdbReviewCore.isLoaded() ? aiNativeData({ reports: this.rdbReviewWorkspace.listReports(), statistics: this.rdbReviewCore.statistics(), page: this.rdbReviewCore.page() }) : aiNativeData({ loaded: false }); break;
      case 'shortcuts.list': data = this.aiNativePage(shortcutService.getShortcutList(), args); break;
      case 'rulers.list': data = this.aiNativePage(this.measureStore.rulers, args); break;
      case 'job.status': data = this.docStore.activeNativeJobId.length > 0 ? nativeHongTuService.getJobProgress(this.docStore.activeNativeJobId,this.activeNativeJobScope) ?? aiNativeData({ message: '作业状态暂不可用，不能确认已停止' }) : aiNativeData({ message: '无活动原生后台作业' }); break;
      case 'import.selected': {
        const selected = this.aiNativeImportSelection;
        if (selected === undefined || !this.aiNativeImport.selectionCurrent(selected)) throw new Error('未选择合并来源或来源已过期');
        data = aiNativeData({ selectionToken: selected.token,fileName: selected.fileName,sourceDbuNm: selected.sourceDbuNm,topCellId: selected.topCellId,
          cells: this.aiNativePage(selected.cells,args),layers: this.aiNativePage(selected.layerPairs,args) }); break;
      }
      case 'presets.list': data = viewService.listLayerPresets(); break;
      case 'views.sources': this.prepareViewWorkspace(); this.refreshViewWorkspaceOverlays(); data = this.viewportStore.viewWorkspaceOverlayDocuments; break;
      case 'views.bookmarks_export': this.prepareViewWorkspace(); data = aiNativeData({ text: this.viewWorkspaceCore!.exportBookmarks(this.docStore.activeWorkspaceId) }); break;
      case 'rdb.previews': this.initializeRdbReview(); this.refreshRdbReview(); data = aiNativeData({ transfer: this.verifyStore.rdbReviewUi.transferPreview ?? undefined,merge: this.verifyStore.rdbReviewUi.mergePreview ?? undefined,waiver: this.verifyStore.rdbReviewUi.waiverPreview ?? undefined }); break;
      case 'waivers.list': this.initializeRdbReview(); this.refreshRdbReview(); data = this.aiNativePage(this.verifyStore.rdbReviewUi.waiverLibrary?.rules ?? [],args); break;
      case 'ports.project': data = this.aiNativePage(portService.project((args['cellId'] as number) ?? editService.getCurrentCellId(),
        { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }), args); break;
      default: {
        const result: AiNativeResult | undefined = runAiNativeGeometry(call, this.aiGeometryContext());
        if (result === undefined) throw new Error('工具缺少只读执行器');
        return result;
      }
    }
    return { success: true, status: 'read_only', message: '来自当前原生编辑器；分页结果须继续读取', data,
      documentIdentity: this.docStore.activeWorkspaceId, documentRevision: this.docStore.editorRevision, coordinateUnit: 'nm' };
  }

  private runAiNativeEdit(call: AiNativeCall): AiNativeResult {
    if (call.name.startsWith('editor.')) {
      const command: ParsedCommand = { type: call.name.substring(7) as AiCommandType, params: call.arguments as Object as CommandParams, description: aiNativeTool(call.name).title };
      const result: CommandResult = aiExecutor.execute(command,this.buildAiContext());
      return aiNativeResult(result.success,result.message,result.affectedShapeIds);
    }
    const geometry: AiNativeResult | undefined = runAiNativeGeometry(call, this.aiGeometryContext());
    if (geometry !== undefined) return geometry;
    const args: Record<string, Object> = call.arguments;
    let ok: boolean = false;
    switch (call.name) {
      case 'import.apply': {
        const selected = this.aiNativeImportSelection;
        if (selected === undefined || selected.token !== args['selectionToken']) throw new Error('导入来源已过期，请重新选择');
        const prepared = this.aiNativeImport.prepare(selected,this.cellStructureState(),args['options'] as ImportMergeOptions,this.docStore.activeWorkspaceId);
        if (!prepared.ok || prepared.preview === undefined) return aiNativeResult(false,prepared.message);
        const result = this.aiNativeImport.apply(prepared.preview,this.cellStructureState(),this.docStore.activeWorkspaceId,(state: EditStructureState): void => this.restoreCellStructure(state));
        return aiNativeResult(result.ok,result.message,result.addedIds);
      }
      case 'cell.create': ok = this.createNewCell(args['name'] as string); break;
      case 'cell.rename': ok = this.performRenameCell(args['cellId'] as number, args['name'] as string); break;
      case 'cell.delete': {
        const count: number = this.placeableCells.length;
        this.deleteCellById(args['cellId'] as number); ok = this.placeableCells.length === count - 1; break;
      }
      case 'cell.make': {
        selectAiNativeTargets(args['shapeIds'] as number[]);
        const cell = advEditService.makeCellFromSelection(args['name'] as string, this.cellStructureState(), this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype);
        ok = cell !== null; this.panelStore.statusText = ok ? '选区已组成 Cell' : '选区不能组成 Cell'; break;
      }
      case 'instance.place': this.instanceDialogContext = this.parameterDialogContext(); ok = this.placeInstance(args['cellId'] as number,args['x'] as number,args['y'] as number,args['rotation'] as number,args['mirror'] as number); break;
      case 'pcell.place': {
        this.pcellDialogContext = this.parameterDialogContext();
        const options: PCellPlacementOptions = { outputMode: args['outputMode'] as string, datatype: args['datatype'] as number, maxErrorNm: args['maxErrorNm'] as number };
        ok = this.applyPlacedPCell(args['name'] as string,args['parameters'] as Record<string,number|string|boolean>,args['x'] as number,args['y'] as number,options,(args['deviceName'] as string) ?? ''); break;
      }
      case 'pcell.update': {
        selectAiNativeTargets([args['shapeId'] as number]);
        const variant: PCellVariant | undefined = this.selectedPCellVariant();
        if (variant === undefined) throw new Error('对象没有可重生成的 PCell 参数');
        this.pcellEditDocumentId = this.docStore.activeWorkspaceId; this.pcellEditRevision = this.docStore.editorRevision;
        this.pcellEditContextCellId = editService.getCurrentCellId(); this.pcellEditCellId = variant.cellId; this.docStore.pcellEditName = variant.name;
        const message: string = this.regenerateSelectedPCell(args['parameters'] as Record<string,number|string|boolean>);
        ok = message.length === 0; if (!ok) this.panelStore.statusText = message; break;
      }
      case 'layers.clear': {
        const deletedCount: number = this.clearShapesOnLayer(
          args['layer'] as number,
          args['datatype'] as number,
          args['currentCellOnly'] === true
        );
        return aiNativeResult(true, `已清空图层 L${args['layer'] as number}/D${args['datatype'] as number} 上的 ${deletedCount} 个图形`);
      }
      case 'layers.copy_shapes': case 'layers.move_shapes': {
        const srcL: number = args['sourceLayer'] as number;
        const srcDt: number = args['sourceDatatype'] as number;
        const dstL: number = args['targetLayer'] as number;
        const dstDt: number = args['targetDatatype'] as number;
        const curOnly: boolean = args['currentCellOnly'] === true;
        const curCell: number = editService.getCurrentCellId();
        this.ensureDshLayerExists(dstL, dstDt, `L${dstL}_${dstDt}`, `图层 ${dstL}/${dstDt}`, this.layerColor(this.docStore.layers.length));
        const matched: Shape[] = editService.getShapes().filter((s: Shape): boolean =>
          s.type !== ShapeType.INSTANCE && s.type !== ShapeType.NODE &&
          s.layerNumber === srcL && s.datatype === srcDt &&
          (!curOnly || (s.ownerCellId ?? editService.getTopCellId()) === curCell)
        );
        if (call.name === 'layers.copy_shapes') {
          const copies: Shape[] = matched.map((s: Shape): Shape => {
            const cp: Shape = cloneShapeModel(s) as Shape;
            cp.id = 0; cp.layerNumber = dstL; cp.datatype = dstDt;
            return cp;
          });
          const created: Shape[] = editService.createShapeCopies(copies, true, true);
          return aiNativeResult(true, `已复制 ${created.length} 个图形至 L${dstL}/D${dstDt}`, created.map((s: Shape): number => s.id));
        }
        editService.beginBatch();
        try {
          for (const s of matched) editService.updateShape(s.id, dstL, 0, 0, dstDt);
        } finally {
          editService.endBatch();
        }
        return aiNativeResult(true, `已迁移 ${matched.length} 个图形至 L${dstL}/D${dstDt}`);
      }
      case 'cell.duplicate': {
        const srcCellId: number = args['cellId'] as number;
        const newName: string = String(args['newName'] ?? '').trim();
        if (!this.hasPlaceableCell(srcCellId)) throw new Error('源 Cell 不存在');
        if (newName.length === 0 || this.cellNameExists(newName)) throw new Error('新 Cell 名称为空或已存在');
        const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
        const newCellId: number = candidate.cellNames.length;
        candidate.cellNames.push(newName);
        candidate.cellProperties.push(cloneStructured(candidate.cellProperties[srcCellId] ?? []) as LayoutPropRecord[]);
        appendCellSemantics(candidate);
        let maxId: number = 0;
        for (const s of candidate.shapes) if (s.id > maxId) maxId = s.id;
        const clonedShapes: Shape[] = [];
        for (const s of candidate.shapes) {
          if ((s.ownerCellId ?? candidate.topCellId) === srcCellId) {
            const cp: Shape = cloneShapeModel(s) as Shape;
            cp.id = ++maxId;
            cp.ownerCellId = newCellId;
            cp.selected = false;
            clonedShapes.push(cp);
          }
        }
        candidate.shapes = candidate.shapes.concat(clonedShapes);
        ok = this.commitCellStructure(candidate);
        if (ok) this.panelStore.statusText = `已复制 Cell ${this.cellName(srcCellId)} 为 ${newName} (${clonedShapes.length} 个图形)`;
        break;
      }
      case 'cell.clear': {
        const targetCellId: number = args['cellId'] as number;
        const ids: number[] = editService.getShapes()
          .filter((s: Shape): boolean => (s.ownerCellId ?? editService.getTopCellId()) === targetCellId)
          .map((s: Shape): number => s.id);
        const removed: number[] = ids.length > 0 ? editService.deleteShapesWithSelectionHistory(ids) : [];
        return aiNativeResult(true, `已清空 Cell ${this.cellName(targetCellId)} 内的 ${removed.length} 个图形`);
      }
      case 'instance.place_aref': {
        this.instanceDialogContext = this.parameterDialogContext();
        const cols: number = Math.max(1, Math.round(args['cols'] as number));
        const rows: number = Math.max(1, Math.round(args['rows'] as number));
        const rot: number = typeof args['rotation'] === 'number' ? (args['rotation'] as number) : 0;
        const mir: number = typeof args['mirror'] === 'number' ? (args['mirror'] as number) : 0;
        ok = this.placeInstance(
          args['cellId'] as number,
          args['x'] as number,
          args['y'] as number,
          rot,
          mir,
          cols,
          rows,
          args['colStepX'] as number,
          args['rowStepY'] as number
        );
        break;
      }
      default: throw new Error(`工具缺少编辑执行器：${call.name}`);
    }
    return aiNativeResult(ok, this.panelStore.statusText);
  }

  private async runAiNativeAction(call: AiNativeCall): Promise<AiNativeResult> {
    const args: Record<string, Object> = call.arguments;
    const title: string = aiNativeTool(call.name).title;
    if ((call.name.startsWith('rdb.') || call.name.startsWith('waivers.')) && this.verifyStore.rdbReviewBusy) throw new Error('报告文件操作尚未结束，请等待其回执');
    let ok: boolean = true;
    switch (call.name) {
      case 'import.select': {
        const documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision, ticket: number = this.aiRequestGeneration;
        this.aiPythonPhase = 'native_import'; this.aiStore.aiCanCancel = true;
        try {
          const result = await this.aiNativeImport.pickSource(this.getUIContext().getHostContext() as common.UIAbilityContext,
            (): boolean => this.pageAlive && ticket === this.aiRequestGeneration && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision);
          this.aiNativeImportSelection = result.ok ? result.selection : undefined;
          return aiNativeResult(result.ok,result.message,result.selection === undefined ? undefined : aiNativeData({ selectionToken: result.selection.token,fileName: result.selection.fileName,sourceDbuNm: result.selection.sourceDbuNm }));
        } finally { this.aiPythonPhase = ''; this.aiStore.aiCanCancel = false; }
      }
      case 'import.cancel': this.aiNativeImport.cancel(); this.aiNativeImportSelection = undefined; break;
      case 'presets.save': ok = viewService.saveLayerPreset(args['name'] as string); this.docStore.layerPresetNames = viewService.listLayerPresets(); break;
      case 'presets.apply': ok = viewService.applyLayerPreset(args['name'] as string); break;
      case 'presets.remove': ok = viewService.deleteLayerPreset(args['name'] as string); this.docStore.layerPresetNames = viewService.listLayerPresets(); break;
      case 'rulers.add': this.measureStore.addRuler(args['vertical'] as boolean,args['positionNm'] as number); this.scheduleWorkspaceDraft(); break;
      case 'rulers.remove': {
        if (!this.measureStore.rulers.some((row): boolean => row.id === args['id'])) throw new Error('标尺不存在');
        this.measureStore.restoreRulers(this.measureStore.rulers.filter((row): boolean => row.id !== args['id'])); this.scheduleWorkspaceDraft(); break;
      }
      case 'views.overlays': {
        this.openViewWorkspace(); ok = this.handleViewWorkspaceOverlays(this.viewportStore.viewWorkspaceActiveId,this.overlayWorkspaceContext(),args['overlays'] as ViewOverlayState[]);
        return aiNativeResult(ok,this.viewportStore.viewWorkspaceStatus);
      }
      case 'views.bookmarks_import': {
        this.prepareViewWorkspace(); this.viewWorkspaceCore!.importBookmarks(this.docStore.activeWorkspaceId,args['json'] as string,args['replace'] as boolean); this.refreshViewWorkspace(); break;
      }
      case 'rdb.transfer_preview': case 'rdb.merge_preview': case 'rdb.preview_action': case 'rdb.close':
      case 'waivers.capture': case 'waivers.preview': case 'waivers.remove': case 'waivers.file': return this.runAiNativeReview(call);
      case 'technology.import_json': {
        const parsed = parseTechnologyPackage(args['json'] as string);
        if (!parsed.ok || parsed.technology === undefined) throw new Error(parsed.error ?? '工艺包解析失败');
        this.applyTechnology(parsed.technology); break;
      }
      case 'stack.save': {
        const parsed = parsePhysicalLayerStack(args['json'] as string,technologyService.getActive()?.layers);
        if (!parsed.ok || parsed.stack === undefined) throw new Error(parsed.message);
        this.saveLayerStack(parsed.stack); break;
      }
      case 'stack.export': {
        const stack: PhysicalLayerStack | undefined = technologyService.getLayerStack();
        if (stack === undefined) throw new Error('当前工艺没有层栈');
        const revision: string = this.layerStackContext();
        const built: LayerStackResult = this.buildLayerStack(stack,args['options'] as LayerStackBuildOptions);
        if (!built.ok || built.preview === undefined) throw new Error(built.message);
        const format: string = args['format'] as string;
        const contents: string = format === 'obj' ? layerStackExportService.obj(built.preview) : format === 'geometry_json' ? layerStackExportService.geometryJson(built.preview) : layerStackExportService.sectionJson(built.preview);
        await engineeringFileService.saveText(this.getUIContext().getHostContext() as common.UIAbilityContext,`layer-stack.${format === 'obj' ? 'obj' : 'json'}`,contents,(): boolean => this.pageAlive && revision === this.layerStackContext());
        return aiNativeResult(true,'实际层栈几何已保存');
      }
      case 'verification.run': case 'python.run': case 'python.sweep': return await this.runAiNativePython(call);
      case 'python.check_connection': await pythonBridgeService.checkConnection(true); break;
      case 'python.history_apply': {
        const row = pythonWorkspaceService.history().find((item): boolean => item.id === args['id']);
        if (row?.artifact === undefined) throw new Error('此运行没有可加载的实际产物');
        const documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
        ok = await this.applyPythonResult(row.artifact,args['mode'] as 'replace'|'merge',row.artifact.sourceRevision ?? -1,
          (): boolean => this.pageAlive && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision); break;
      }
      case 'python.template_save': pythonWorkspaceService.saveTemplate(args['name'] as string,args['script'] as string,args['parameters'] as string,args['inputMode'] as PythonInputMode,args['sweepName'] as string,args['sweepValues'] as string); break;
      case 'python.template_remove': pythonWorkspaceService.removeTemplate(args['id'] as number); break;
      case 'shortcuts.set': { const result = shortcutService.setShortcut(args['actionKey'] as string,args['code'] as string); return aiNativeResult(result.ok,result.error ?? result.conflict ?? '快捷键已保存'); }
      case 'shortcuts.import': { const result = shortcutService.importProfile(args['json'] as string); return aiNativeResult(result.ok,result.error ?? '快捷键配置已保存'); }
      case 'shortcuts.reset': { const result = shortcutService.resetToDefault(); return aiNativeResult(result.ok,result.error ?? '默认快捷键已恢复'); }
      case 'view.grid': this.viewportStore.gridVisible = args['visible'] as boolean; break;
      case 'editor.tool': {
        const result: CommandResult = aiExecutor.execute({ type: AiCommandType.SET_TOOL,params: { tool: args['tool'] as string },description: title },this.buildAiContext());
        if (result.viewAction !== undefined) this.applyViewAction(result.viewAction); return aiNativeResult(result.success,result.message);
      }
      case 'rdb.page': this.openRdbReview(); ok = this.pageRdbReview(args['index'] as number,args['size'] as number); break;
      case 'rdb.select': this.openRdbReview(); ok = this.selectRdbReview(args['index'] as number); break;
      case 'rdb.review': {
        this.openRdbReview(); const index: number = args['index'] as number;
        ok = this.selectRdbReview(index) && this.updateRdbReview(index,args['patch'] as RdbReviewPatch,this.rdbReviewCore.contextToken()); break;
      }
      case 'rdb.bind': this.openRdbReview(); ok = this.bindRdbReview(args['reportCell'] as string,args['layoutCellId'] as number); break;
      case 'rdb.frame': this.openRdbReview(); ok = this.frameRdbReview(args['target'] as string,args['pathIndex'] as number); break;
      case 'rdb.locate': this.openRdbReview(); ok = this.locateRdbReview(); break;
      case 'rdb.clear_overlay': this.clearRdbReviewOverlay(); break;
      case 'rdb.activate': { this.openRdbReview(); const id: string = args['id'] as string; ok = this.activateRdbReport(id,this.rdbReviewWorkspace.contextToken(),this.rdbReviewWorkspace.reportContext(id)); break; }
      case 'rdb.filter': this.openRdbReview(); ok = this.filterRdbReview(args as Object as RdbReviewFilter); break;
      case 'compare.run': {
        const revision: string = `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`;
        const ticket: number = this.aiRequestGeneration;
        const picked = await engineeringFileService.pickComparison(this.getUIContext().getHostContext() as common.UIAbilityContext);
        let run: LayoutCompareRun | undefined;
        try {
          if (!this.pageAlive || revision !== `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`) throw new Error('选择文件期间文档已变化');
          run = layoutCompareService.start(this.currentExportInput(),picked.path,args as Object as NativeLayoutCompareOptions);
          this.aiNativeCompare = run; this.aiNativeComparePath = picked.path; this.aiPythonPhase = 'native_compare'; this.aiStore.aiCanCancel = true;
          this.beginNativeJob(run.jobId,run.scope,'AI 版图比较',(): boolean => this.pageAlive && ticket === this.aiRequestGeneration && revision === `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`);
          const completed = await run.completion();
          if (!this.pageAlive || ticket !== this.aiRequestGeneration || revision !== `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}`) throw new Error('比较期间文档已变化或已取消，旧结果未采用');
          if (completed.result === undefined) return aiNativeResult(false,completed.message);
          return aiNativeResult(completed.result.success && completed.result.complete,completed.result.errorMessage || '版图比较已完成',completed.result);
        } finally {
          this.aiStore.aiCanCancel = false; this.aiPythonPhase = '';
          if (run !== undefined) run.progress();
          if (run === undefined || run.workerStopped()) {
            engineeringFileService.removeTemporary(picked.path);
            this.aiNativeComparePath = ''; this.aiNativeCompare = null;
            if (run !== undefined) this.finishNativeJob(run.jobId,run.scope);
          } else { run.cancel(); this.panelStore.statusText = '比较尚未确认停止，输入文件保留供后台收尾'; }
        }
      }
      case 'workbench.invoke': {
        const id: string = args['commandId'] as string;
        // These palette entries perform an immediate action. Return its actual
        // outcome rather than mislabelling a completed edit as a dialog handoff.
        const direct: string = id === 'undo' ? 'edit.undo' : id === 'redo' ? 'edit.redo' : id === 'paste' ? 'edit.paste' : id === 'fit' ? 'view.fit' : '';
        if (direct.length > 0) return await this.runAiNativeAction(parseAiNativeCall(direct,'{}'));
        if (id === 'copy') return await this.runAiNativeAction(parseAiNativeCall('edit.copy',JSON.stringify({ shapeIds: editService.getSelectedIds() } as CommandParams)));
        if (id === 'layerStack') this.openLayerStack(); else if (id === 'lvs') this.openLvsPanel();
        else if (id === 'macro') this.panelStore.showMacroPanel = true; else if (id === 'newCell') this.openNewCellDialog();
        else if (id === 'placeInstance') this.openInstanceDialog(); else if (id === 'editPCell') this.openPCellEditor();
        else if (id === 'restoreEngineering') this.confirmRestoreEngineeringTools();
        else if (!this.executeWorkbenchCommand(id)) return aiNativeResult(false,this.panelStore.statusText);
        if (id === 'drc') return aiNativeResult(this.docStore.activeNativeJobId.length > 0 || this.verifyStore.drcHasRun,this.docStore.nativeJobLabel || this.aiDrcResultSummary(),undefined,this.docStore.activeNativeJobId.length > 0 ? 'job_started' : 'verification');
        return aiNativeResult(true,'已调用原生工作流入口；参数、文件选择和最终完成状态请以原生流程回执为准',undefined,'awaiting_user');
      }
      case 'edit.undo': case 'edit.redo': {
        if (!this.assertEditMode()) throw new Error('查看模式不可编辑');
        const marker: Object | null = editService.getUndoMarker();
        if (call.name === 'edit.undo') this.undoEdit(); else this.redoEdit();
        ok = marker !== editService.getUndoMarker(); break;
      }
      case 'edit.copy': selectAiNativeTargets(args['shapeIds'] as number[]); ok = editService.copySelection() > 0; break;
      case 'edit.paste': { const count: number = this.shapes.length; this.pasteFromClipboard(); ok = this.shapes.length > count; break; }
      case 'selection.set': {
        const ids: number[] = args['shapeIds'] as number[];
        if (ids.length) selectAiNativeTargets(ids); else editService.clearSelection(); this.syncShapesFromEditService(); break;
      }
      case 'selection.all': this.selectAllShapes(); break;
      case 'cell.enter': ok = this.enterCellDefinition(args['cellId'] as number); break;
      case 'layers.visible': {
        if (!this.docStore.layers.some((row: UiLayer): boolean => row.layerNumber === args['layer'] && row.datatype === args['datatype'])) throw new Error('图层不存在');
        this.setLayerVisible(args['layer'] as number,args['visible'] as boolean,args['datatype'] as number); break;
      }
      case 'layers.style': {
        const original: UiLayer | undefined = this.docStore.layers.find((row: UiLayer): boolean => row.layerNumber === args['layer'] && row.datatype === args['datatype']);
        if (original === undefined) throw new Error('图层不存在');
        if (!/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(args['color'] as string)) throw new Error('颜色须为十六进制 RGB 或 ARGB');
        const next: UiLayer = cloneLayerWithVisible(original,original.visible);
        next.color = args['color'] as string; next.fillColor = undefined; next.lineStyle = args['lineStyle'] as string; next.fillStyle = args['fillStyle'] as string;
        next.transparency = args['transparency'] as number; next.lineWidth = args['lineWidth'] as number;
        next.highlighted = args['highlighted'] as boolean; next.animated = args['animated'] as boolean;
        this.docStore.layers = this.docStore.layers.map((row: UiLayer): UiLayer => row === original ? next : row);
        this.syncLayerVisibilityMirror(); this.docStore.editorRevision++; this.scheduleWorkspaceDraft(); break;
      }
      case 'layers.lock': {
        const layer: UiLayer | undefined = this.docStore.layers.find((row: UiLayer): boolean => row.layerNumber === args['layer'] && row.datatype === args['datatype']);
        if (layer === undefined) throw new Error('图层不存在');
        if (layer.locked !== args['locked']) this.toggleLayerLock(layer.layerNumber,layer.datatype); break;
      }
      case 'layers.selectable': {
        if (!this.docStore.layers.some((row: UiLayer): boolean => row.layerNumber === args['layer'] && row.datatype === args['datatype'])) throw new Error('图层不存在');
        this.setLayerSelectable(args['layer'] as number,args['datatype'] as number,args['selectable'] as boolean); break;
      }
      case 'layers.select': {
        const layer: UiLayer | undefined = this.docStore.layers.find((row: UiLayer): boolean => row.layerNumber === args['layer'] && row.datatype === args['datatype']);
        if (layer === undefined) throw new Error('图层不存在'); this.selectLayer(layer); break;
      }
      case 'view.fit': this.fitAllShapes(); break;
      case 'view.reset': this.resetView(); break;
      case 'view.back': this.viewBack(); break;
      case 'view.focus': this.focusWorldBounds(args['bounds'] as ShapeBounds); break;
      case 'view.zoom': viewService.setViewZoomPercent(args['percent'] as number); this.viewportStore.zoomPercent = viewService.getViewZoomPercent(); break;
      case 'view.hierarchy': ok = viewService.setHierarchyDepth(args['depth'] as number); break;
      case 'view.mode': this.setViewMode(args['mode'] === 'edit' ? ViewMode.EDIT : ViewMode.VIEWER); break;
      case 'precision.set': ok = this.applyPrecisionSettings(args as Object as PrecisionSettings); break;
      case 'views.action': this.openViewWorkspace(); ok = this.handleViewWorkspaceAction(args['kind'] as string,args['id'] as string,args['name'] as string); break;
      case 'drc.run': this.runDrc(); return aiNativeResult(this.verifyStore.drcHasRun && this.drcSnapshotRevision === this.docStore.editorRevision,this.aiDrcResultSummary());
      case 'drc.rule': ok = drcService.setValue(args['id'] as string,args['value'] as number) && drcService.setEnabled(args['id'] as string,args['enabled'] as boolean); this.onDrcConfigurationChanged(); break;
      case 'drc.import_text': {
        const result = drcService.loadRulesFromText(args['text'] as string,args['merge'] as boolean);
        this.onDrcConfigurationChanged(); return aiNativeResult(result.ok,JSON.stringify(result));
      }
      case 'drc.builtin': drcService.resetRulesToBuiltin(); this.onDrcConfigurationChanged(); break;
      case 'nets.trace': this.traceNets(); return aiNativeResult(this.netSnapshotRevision === this.docStore.editorRevision,this.panelStore.statusText,aiNativeData({ nets: this.verifyStore.tracedNets.slice(0,64) }));
      case 'lvs.run': this.verifyStore.lvsNetlistText = args['schematic'] as string; this.runLvsCheck(); return aiNativeResult(this.verifyStore.lvsHasResult && this.verifyStore.lvsResult.ran,this.panelStore.statusText,this.verifyStore.lvsResult);
      case 'lvs.extract': this.loadExtractedNetlist(); return aiNativeResult(!this.verifyStore.lvsResult.error,this.panelStore.statusText,aiNativeData({ spice: this.verifyStore.lvsNetlistText, boundary: '几何连通网表，不是器件提取签核' }));
      case 'job.cancel': this.cancelActiveNativeJob(); return aiNativeResult(true,'已请求取消，须等待原生作业终止回执','', 'cancellation_requested');
      case 'workspace.new': {
        const before: string = this.docStore.activeWorkspaceId;
        this.createWorkspaceDocument(args['library'] as string,args['top'] as string,args['dbuNm'] as number); ok = before !== this.docStore.activeWorkspaceId; break;
      }
      case 'workspace.switch': this.switchWorkspaceDocument(args['id'] as string); ok = this.docStore.activeWorkspaceId === args['id']; break;
      case 'workspace.checkpoint': ok = await this.saveWorkspaceDraft(true); break;
      case 'workspace.restore': {
        const history: WorkspaceHistory | undefined = workspaceService.listHistory(this.docStore.activeWorkspaceId).find((row: WorkspaceHistory): boolean => row.id === args['id']);
        if (history === undefined) throw new Error('恢复版本不存在');
        const before: string = this.docStore.activeWorkspaceId; await this.restoreWorkspaceHistory(history); ok = this.docStore.activeWorkspaceId !== before; break;
      }
      case 'technology.clear': this.clearTechnology(); ok = technologyService.getActive() === undefined; break;
      case 'library.insert': {
        const entry: ComponentLibraryEntry | undefined = componentLibraryService.list().find((row: ComponentLibraryEntry): boolean => row.id === args['id']);
        if (entry === undefined) throw new Error('器件库条目不存在'); ok = this.insertLibraryEntry(entry,args['x'] as number,args['y'] as number); break;
      }
      case 'library.add_cell': case 'library.add_pcell': {
        const count: number = componentLibraryService.list().length;
        if (call.name === 'library.add_cell') await this.addCellToLibrary(args['title'] as string,args['category'] as string);
        else await this.addPCellToLibrary(args['title'] as string,args['category'] as string);
        ok = componentLibraryService.list().length > count; break;
      }
      case 'library.remove': await this.removeLibraryEntry(args['id'] as string); ok = !componentLibraryService.list().some((entry: ComponentLibraryEntry): boolean => entry.id === args['id']); break;
      case 'macro.run': {
        if (!this.assertEditMode() || macroService.isRecording()) throw new Error('请在编辑模式下结束宏录制后运行');
        const result: MacroResult = macroService.executeMacro(args['id'] as number,this.buildAiContext(),this.docStore.activeWorkspaceId,this.propertyCellOptions());
        this.syncShapesFromEditService(); for (const action of result.viewActions ?? []) this.applyViewAction(action);
        return aiNativeResult(result.success,result.success ? `宏已执行 ${result.executedSteps}/${result.totalSteps} 步` : result.error ?? '宏执行失败',result);
      }
      case 'macro.import': ok = macroService.importMacro(args['json'] as string) !== null; break;
      case 'macro.remove': ok = macroService.deleteMacro(args['id'] as number); break;
      case 'macro.record_start': if (macroService.isRecording()) throw new Error('已有正在录制的宏'); macroService.startRecording(args['name'] as string,this.docStore.activeWorkspaceId); this.panelStore.macroRecording = macroService.isRecording(); break;
      case 'macro.record_stop': ok = macroService.stopRecording() !== null; this.panelStore.macroRecording = false; break;
      case 'macro.record_cancel': macroService.cancelRecording(); this.panelStore.macroRecording = false; break;
      case 'rulers.clear': this.measureStore.restoreRulers([]); this.scheduleWorkspaceDraft(); break;
      case 'file.open': this.observeAiNativeWorkflow(title,this.pickAndParseFile(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已打开系统文件选择流程，完成或取消情况由文件流程返回',undefined,'awaiting_user');
      case 'file.save': this.observeAiNativeWorkflow(title,this.saveCurrentLayout(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用原生保存流程，需核对保存结果',undefined,'awaiting_user');
      case 'file.save_as': this.observeAiNativeWorkflow(title,this.saveCurrentLayout(true),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 GDS 另存流程',undefined,'awaiting_user');
      case 'file.export_oasis': this.observeAiNativeWorkflow(title,this.exportOasis(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 OASIS 导出流程',undefined,'awaiting_user');
      case 'file.export_svg': this.observeAiNativeWorkflow(title,this.exportImage('svg'),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 SVG 导出流程',undefined,'awaiting_user');
      case 'file.export_png': this.observeAiNativeWorkflow(title,this.exportImage('png'),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 PNG 导出流程',undefined,'awaiting_user');
      case 'project.open': this.observeAiNativeWorkflow(title,this.openProject(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用工程选择流程',undefined,'awaiting_user');
      case 'project.save': this.observeAiNativeWorkflow(title,this.saveProject(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用工程保存流程',undefined,'awaiting_user');
      case 'project.save_as': this.observeAiNativeWorkflow(title,this.saveProject(true),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用工程另存流程',undefined,'awaiting_user');
      case 'layers.import_lyp': this.observeAiNativeWorkflow(title,this.importLypFile(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 LYP 选择流程',undefined,'awaiting_user');
      case 'layers.export_lyp': this.observeAiNativeWorkflow(title,this.exportLypFile(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 LYP 保存流程',undefined,'awaiting_user');
      case 'library.import': this.observeAiNativeWorkflow(title,this.importComponentLibrary(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用器件库选择流程',undefined,'awaiting_user');
      case 'library.export': this.observeAiNativeWorkflow(title,this.exportComponentLibrary(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用器件库保存流程',undefined,'awaiting_user');
      case 'drc.export_rdb': if (!this.canExportDrcRdb()) throw new Error('没有当前版本的完整 DRC 结果'); this.observeAiNativeWorkflow(title,this.exportDrcRdb(),(): string => this.panelStore.statusText); return aiNativeResult(true,'已调用 DRC 报告保存流程',undefined,'awaiting_user');
      case 'rdb.open': case 'rdb.save': case 'rdb.from_drc': {
        this.openRdbReview();
        if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) throw new Error('报告尚未就绪或有未保存的编辑');
        const kind: string = call.name === 'rdb.open' ? 'open' : call.name === 'rdb.save' ? 'save' : 'currentDrc';
        const id: string = kind === 'save' ? this.rdbReviewWorkspace.activeReportId() : '';
        if (kind === 'save' && id.length === 0) throw new Error('没有可保存的报告');
        this.observeAiNativeWorkflow(title,this.performRdbWorkspaceFileAction(kind,id,this.rdbReviewWorkspace.contextToken(),id ? this.rdbReviewWorkspace.reportContext(id) : ''),(): string => this.verifyStore.rdbReviewStatus);
        return aiNativeResult(true,'已调用报告工作流，完成或取消回执将写回对话',undefined,'awaiting_user');
      }
      case 'layers.create': {
        const ln: number = args['layer'] as number;
        const dt: number = args['datatype'] as number;
        const eName: string = typeof args['englishName'] === 'string' ? (args['englishName'] as string) : `L${ln}_${dt}`;
        const cName: string = typeof args['chineseName'] === 'string' ? (args['chineseName'] as string) : `图层 ${ln}/${dt}`;
        const col: string = typeof args['color'] === 'string' ? (args['color'] as string) : this.layerColor(this.docStore.layers.length);
        this.ensureDshLayerExists(ln, dt, eName, cName, col);
        if (args['selectAsActive'] !== false) {
          this.viewportStore.selectedLayerNumber = ln;
          this.viewportStore.selectedDatatype = dt;
        }
        this.docStore.editorRevision++;
        this.scheduleWorkspaceDraft();
        break;
      }
      case 'layers.delete': {
        ok = this.deleteLayerWithUndo(args['layer'] as number, args['datatype'] as number, args['deleteShapes'] !== false);
        break;
      }
      case 'layers.delete_empty': {
        const removed: number = this.deleteAllEmptyLayersWithUndo();
        return aiNativeResult(true, removed > 0 ? `已删除 ${removed} 个无图形空图层` : '当前没有空图层');
      }
      case 'layers.rename': {
        const ln: number = args['layer'] as number;
        const dt: number = args['datatype'] as number;
        if (!this.docStore.layers.some((l: UiLayer): boolean => l.layerNumber === ln && l.datatype === dt)) throw new Error('图层不存在');
        this.docStore.layers = this.docStore.layers.map((l: UiLayer): UiLayer => {
          if (l.layerNumber !== ln || l.datatype !== dt) return l;
          const cp: UiLayer = cloneLayerWithVisible(l, l.visible);
          if (typeof args['englishName'] === 'string') cp.englishName = args['englishName'] as string;
          if (typeof args['chineseName'] === 'string') cp.chineseName = args['chineseName'] as string;
          return cp;
        });
        this.docStore.editorRevision++;
        this.scheduleWorkspaceDraft();
        break;
      }
      case 'layers.reorder': {
        const ln: number = args['layer'] as number;
        const dt: number = args['datatype'] as number;
        const curIdx: number = this.docStore.layers.findIndex((l: UiLayer): boolean => l.layerNumber === ln && l.datatype === dt);
        if (curIdx < 0) throw new Error('图层不存在');
        const arr: UiLayer[] = this.docStore.layers.slice();
        const item: UiLayer = arr.splice(curIdx, 1)[0];
        let dest: number = curIdx;
        if (typeof args['targetIndex'] === 'number') dest = Math.max(0, Math.min(arr.length, Math.round(args['targetIndex'] as number)));
        else if (args['direction'] === 'top') dest = 0;
        else if (args['direction'] === 'bottom') dest = arr.length;
        else if (args['direction'] === 'up') dest = Math.max(0, curIdx - 1);
        else if (args['direction'] === 'down') dest = Math.min(arr.length, curIdx + 1);
        arr.splice(dest, 0, item);
        this.docStore.layers = arr;
        this.docStore.editorRevision++;
        this.scheduleWorkspaceDraft();
        break;
      }
      case 'layers.batch_state': {
        const op: string = args['operation'] as string;
        const ln: number = typeof args['layer'] === 'number' ? (args['layer'] as number) : this.viewportStore.selectedLayerNumber;
        const dt: number = typeof args['datatype'] === 'number' ? (args['datatype'] as number) : this.viewportStore.selectedDatatype;
        this.docStore.layers = this.docStore.layers.map((l: UiLayer): UiLayer => {
          const cp: UiLayer = cloneLayerWithVisible(l, l.visible);
          if (op === 'show_all') cp.visible = true;
          else if (op === 'hide_all') cp.visible = false;
          else if (op === 'solo') cp.visible = (l.layerNumber === ln && l.datatype === dt);
          else if (op === 'unlock_all') cp.locked = false;
          else if (op === 'lock_all') cp.locked = true;
          return cp;
        });
        this.syncLayerVisibilityMirror();
        this.docStore.editorRevision++;
        this.scheduleWorkspaceDraft();
        break;
      }
      case 'cell.exit_top': {
        editService.exitToTop();
        this.syncShapesFromEditService();
        this.fitAllShapes();
        break;
      }
      case 'cell.exit_parent': {
        const stack: number[] = editService.getCurrentCellStack();
        if (stack.length > 1) this.navigateCellStack(stack.length - 2);
        break;
      }
      case 'cell.set_top': {
        const targetId: number = args['cellId'] as number;
        if (!this.hasPlaceableCell(targetId)) throw new Error('目标 Cell 不存在');
        const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
        candidate.topCellId = targetId;
        candidate.topCellName = candidate.cellNames[targetId];
        candidate.cellStack = [targetId];
        candidate.navigationPath = [];
        ok = this.commitCellStructure(candidate);
        if (ok) {
          this.docStore.docTopCellName = this.cellName(targetId);
          this.fitAllShapes();
        }
        break;
      }
      case 'selection.filter': {
        const filterL: number = typeof args['layer'] === 'number' ? (args['layer'] as number) : -1;
        const filterDt: number = typeof args['datatype'] === 'number' ? (args['datatype'] as number) : -1;
        const st: string = typeof args['shapeType'] === 'string' ? (args['shapeType'] as string) : 'all';
        const ids: number[] = editService.getCurrentCellShapes()
          .filter((s: Shape): boolean => {
            if (filterL >= 0 && s.layerNumber !== filterL) return false;
            if (filterDt >= 0 && s.datatype !== filterDt) return false;
            if (st === 'rect' && s.type !== ShapeType.RECT) return false;
            if (st === 'polygon' && s.type !== ShapeType.POLYGON) return false;
            if (st === 'path' && s.type !== ShapeType.PATH) return false;
            if (st === 'text' && s.type !== ShapeType.TEXT) return false;
            if (st === 'instance' && s.type !== ShapeType.INSTANCE) return false;
            return true;
          })
          .map((s: Shape): number => s.id);
        editService.selectMultiple(ids);
        this.syncShapesFromEditService();
        return aiNativeResult(true, `按条件筛选选中 ${ids.length} 个对象`, ids);
      }
      case 'selection.invert': {
        const curSelected: Set<number> = new Set<number>(editService.getSelectedIds());
        const inverted: number[] = editService.getCurrentCellShapes()
          .filter((s: Shape): boolean => !curSelected.has(s.id))
          .map((s: Shape): number => s.id);
        editService.selectMultiple(inverted);
        this.syncShapesFromEditService();
        return aiNativeResult(true, `反选完成，当前选中 ${inverted.length} 个对象`, inverted);
      }
      case 'workspace.close': {
        const closeId: string = args['id'] as string;
        await this.closeWorkspaceDocument(closeId);
        ok = !this.docStore.workspaceTabs.some((t: WorkspaceTab): boolean => t.id === closeId) || this.docStore.workspaceTabs.length === 1;
        break;
      }
      case 'workspace.rename': {
        const nextTitle: string = String(args['title'] ?? '').trim();
        if (nextTitle.length === 0) throw new Error('文档标题不能为空');
        this.docStore.currentDocumentTitle = nextTitle;
        if (typeof args['libName'] === 'string' && (args['libName'] as string).trim().length > 0) {
          this.docStore.docLibName = (args['libName'] as string).trim();
        }
        this.docStore.documentDirty = true;
        this.refreshWorkspaceTabs();
        this.scheduleWorkspaceDraft();
        break;
      }
      default: throw new Error(`工具缺少应用执行器：${call.name}`);
    }
    return aiNativeResult(ok, ok ? `${title}已完成` : `${title}未完成：${this.panelStore.statusText}`);
  }

  private runAiNativeReview(call: AiNativeCall): AiNativeResult {
    this.openRdbReview();
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) throw new Error('请先完成报告草稿或当前文件操作');
    const args: Record<string,Object> = call.arguments;
    const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace;
    let ok: boolean = false;
    switch (call.name) {
      case 'rdb.transfer_preview': {
        const source: string = args['sourceReportId'] as string, target: string = args['targetReportId'] as string;
        ok = this.previewRdbTransfer({ workspaceToken: workspace.contextToken(),sourceReportId: source,targetReportId: target,
          sourceContext: workspace.reportContext(source),targetContext: workspace.reportContext(target),options: args['options'] as RdbReviewTransferOptions }); break;
      }
      case 'rdb.merge_preview': {
        const ids: string[] = args['reportIds'] as string[];
        const sources = workspace.captureSources(ids,workspace.contextToken());
        ok = this.previewRdbMerge({ workspaceToken: workspace.contextToken(),sources: sources.map((source): RdbMergeUiSource => ({ reportId: source.reportId,
          sourceIdentity: source.sourceIdentity,reportContext: workspace.reportContext(source.reportId) })),options: args['options'] as RdbMergeOptions }); break;
      }
      case 'rdb.preview_action': {
        const id: string = args['id'] as string, action: string = args['action'] as string, kind: string = args['kind'] as string;
        const preview = kind === 'transfer' ? this.verifyStore.rdbReviewUi.transferPreview : kind === 'merge' ? this.verifyStore.rdbReviewUi.mergePreview : this.verifyStore.rdbReviewUi.waiverPreview;
        if (preview === null || preview === undefined || preview.id !== id) throw new Error('预览已过期，请重新生成');
        if (action === 'apply') {
          if (!preview.canApply) throw new Error('预览存在冲突，不能应用');
          if (kind === 'transfer') this.applyRdbTransfer(id); else if (kind === 'merge') this.applyRdbMerge(id); else this.confirmRdbWaiver(id);
          return aiNativeResult(true,'已打开原生最终确认；确认前报告内容未改变',undefined,'awaiting_user');
        }
        if (action === 'cancel') {
          if (kind === 'transfer') this.cancelRdbTransfer(id); else if (kind === 'merge') this.cancelRdbMerge(id); else this.cancelRdbWaiver(id); ok = true;
        } else {
          const page: number = (args['page'] as number) ?? 0, size: number = (args['size'] as number) ?? 10;
          ok = kind === 'transfer' ? this.pageRdbTransfer(id,page,size) : kind === 'merge' ? this.pageRdbMerge(id,page,size) : this.pageRdbWaiver(id,page,size);
        }
        break;
      }
      case 'rdb.close': {
        const id: string = args['id'] as string;
        if (!workspace.listReports().some((row): boolean => row.id === id)) throw new Error('报告不存在');
        this.closeRdbReport(id,workspace.contextToken(),workspace.reportContext(id));
        return aiNativeResult(true,'已调用报告关闭流程；有未保存记录时需处理原生确认',undefined,'awaiting_user');
      }
      case 'waivers.capture': case 'waivers.preview': case 'waivers.remove': case 'waivers.file': {
        const context: RdbWaiverContext | null = this.captureRdbWaiverContext();
        const version: string = this.rdbReviewStorage.library().version();
        if (call.name === 'waivers.file') {
          this.observeAiNativeWorkflow('豁免库文件操作',this.rdbWaiverFileAction({ kind: args['kind'] as 'import'|'export',libraryVersion: version,workspaceToken: workspace.contextToken() }),(): string => this.verifyStore.rdbReviewStatus);
          return aiNativeResult(true,'已打开豁免库文件流程',undefined,'awaiting_user');
        }
        if (context === null) throw new Error('当前报告缺少完整布局和工艺映射');
        if (call.name === 'waivers.capture') ok = this.captureRdbWaiver({ context,libraryVersion: version,itemIndex: args['index'] as number,name: args['name'] as string,rationale: args['rationale'] as string });
        else if (call.name === 'waivers.preview') ok = this.previewRdbWaiver({ context,libraryVersion: version,ruleIds: args['ruleIds'] as string[],operation: args['operation'] as 'apply'|'remove' });
        else {
          if (!this.verifyStore.rdbReviewUi.waiverLibrary?.rules.some((row): boolean => row.id === args['id'])) throw new Error('豁免规则不存在');
          this.deleteRdbWaiver(args['id'] as string,version); return aiNativeResult(true,'已打开豁免规则删除确认',undefined,'awaiting_user');
        }
        break;
      }
      default: throw new Error('未注册的报告工具');
    }
    this.refreshRdbReview();
    return aiNativeResult(ok,this.verifyStore.rdbReviewStatus,aiNativeData({ transfer: this.verifyStore.rdbReviewUi.transferPreview ?? undefined,merge: this.verifyStore.rdbReviewUi.mergePreview ?? undefined,waiver: this.verifyStore.rdbReviewUi.waiverPreview ?? undefined }));
  }

  private observeAiNativeWorkflow(title: string, operation: Promise<void>, status: () => string): void {
    const conversationId: string = this.aiStore.aiActiveConversationId;
    operation.then((): void => {
      aiService.recordExecutionReceipt(`${title}的原生流程已返回\n${status()}\n以此回执为准；打开选择器不代表文件已写入。`,conversationId);
      if (this.pageAlive && conversationId === this.aiStore.aiActiveConversationId) this.refreshAiConversation();
    }).catch((error: Error): void => {
      try { aiService.recordExecutionReceipt(`${title}未完成：${String(error)}`,conversationId); if (this.pageAlive) this.refreshAiConversation(); }
      catch (_) { this.aiStore.aiError = `${title}回执保存失败，请核对原生流程状态`; }
    });
  }

  private async runAiNativePython(call: AiNativeCall): Promise<AiNativeResult> {
    const args: Record<string,Object> = call.arguments;
    const verify: boolean = call.name === 'verification.run';
    const mode: PythonInputMode = verify ? 'document' : args['inputMode'] as PythonInputMode;
    if (mode === 'selection' && this.filteredAiContext(this.buildAiContext()).selectionContextIncluded === false) throw new Error('用户未发送选区资料');
    const revision: number = this.docStore.editorRevision, documentId: string = this.docStore.activeWorkspaceId, ticket: number = this.aiRequestGeneration;
    const current: () => boolean = (): boolean => this.pageAlive && ticket === this.aiRequestGeneration && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let input: PythonDocumentInput | undefined;
    this.aiPythonPhase = 'native_tool'; this.aiNativeCancellation = null;
    try {
      if (mode !== 'new') input = await this.createPythonSnapshot(mode);
      if (!current()) throw new Error('创建快照期间文档已变化，未执行脚本或验证');
      this.aiNativeOperation = pythonBridgeService.createOperation(verify ? 'verify' : 'generate'); this.aiStore.aiCanCancel = true;
      if (verify) {
        const technology: TechnologyPackage | undefined = technologyService.getActive();
        if (technology === undefined || input === undefined) throw new Error('未绑定工艺或缺少文档快照');
        const result: PythonVerificationResult = await pythonBridgeService.verify({ kind: args['kind'] as 'drc'|'lvs',technologyId: technology.id,
          deckId: args['deckId'] as string,document: input,referenceSpice: (args['referenceSpice'] as string) ?? '',
          cellName: (args['cellName'] as string) || input.currentCellName || '' },this.aiNativeOperation);
        if (!current()) throw new Error('验证期间文档已变化或已取消，旧验证结果未采用');
        return aiNativeResult(result.success && result.complete,result.success ? (result.complete ? (result.passed ? '所选工艺规则范围通过' : '所选工艺规则范围未通过') : '检查不完整，不能判定通过') : result.error ?? '验证失败',result);
      }
      const parameters: string = (args['parameters'] as string) ?? '{}';
      if (call.name === 'python.sweep') {
        const runs: PythonParameter[][] = pythonWorkspaceService.sweep(parameters,args['sweepName'] as string,args['sweepValues'] as string);
        const completed: AiNativeData[] = [];
        for (let index: number = 0; index < runs.length; index++) {
          if (!current()) throw new Error(`扫描已停止；已完成 ${completed.length}/${runs.length} 项，产物保留在运行历史`);
          this.aiNativeOperation = pythonBridgeService.createOperation('generate'); this.aiNativeCancellation = null;
          const artifact = await pythonBridgeService.generate(args['script'] as string,context,{ inputMode: mode,document: input,parameters: runs[index] },this.aiNativeOperation);
          const values: Record<string,number|string|boolean> = {};
          for (const item of runs[index]) values[item.name] = item.value;
          const record = pythonWorkspaceService.record(`${artifact.name} · ${index+1}/${runs.length}`,args['script'] as string,JSON.stringify(values),mode,true,artifact.summary,artifact);
          completed.push({ id: record.id,title: record.name,message: record.message });
        }
        return aiNativeResult(true,`${completed.length} 项扫描执行完成，产物已保存在运行历史；可用 python.history_apply 载入`,completed);
      }
      const artifact: PythonLayoutArtifact = await pythonBridgeService.generate(args['script'] as string,context,
        { inputMode: mode,document: input,parameters: pythonWorkspaceService.parseParameters(parameters) },this.aiNativeOperation);
      const record = pythonWorkspaceService.record(artifact.name,args['script'] as string,parameters,mode,true,artifact.summary,artifact);
      if (!current()) throw new Error('脚本已生成产物，文档已变化或请求已取消；产物保留在 Python 历史，未应用');
      if (args['applyMode'] === 'preview') return aiNativeResult(true,'实际产物已生成并保存在 Python 历史，尚未修改版图',aiNativeData({ id: record.id,title: artifact.name,message: artifact.summary }),'artifact_ready');
      this.aiStore.aiCanCancel = false;
      const applied: boolean = await this.applyPythonResult(artifact,args['applyMode'] as 'replace'|'merge',revision,current);
      return aiNativeResult(applied,applied ? `Python 产物已载入：${artifact.summary}` : `产物保留在 Python 历史，未应用：${this.panelStore.statusText}`);
    } finally {
      if (this.aiNativeCancellation !== null) await this.aiNativeCancellation;
      this.aiNativeOperation = null; this.aiNativeCancellation = null; this.aiStore.aiCanCancel = false; this.aiPythonPhase = '';
      if (input !== undefined) await pythonBridgeService.disposeDocumentInput(input,context);
    }
  }

  private async applyPendingAiNativeTools(): Promise<void> {
    const conversationId: string = this.aiStore.aiActiveConversationId;
    const runId: string = this.pendingAiRunId;
    const checkpoint: AiTaskCheckpoint | undefined = aiService.getTaskCheckpoint();
    if (checkpoint !== undefined && checkpoint.id === this.pendingAiRunId && ['applying','applied'].includes(checkpoint.phase)) { this.aiStore.aiError = '已有执行记录，请核对结果，不能重复应用'; return; }
    let calls: AiNativeCall[];
    try {
      calls = this.aiStore.pendingAiCommands.map((command: ParsedCommand): AiNativeCall => parseAiNativeCall(command.params.nativeTool ?? '',command.params.argumentsJson ?? '{}'));
      validateAiNativeBatch(calls);
      if (!this.docStore.workspaceReady || this.importInProgress || (this.docStore.activeNativeJobId.length > 0 && calls[0].name !== 'job.cancel')) throw new Error('文档或后台作业尚未就绪');
      if (calls.some((call: AiNativeCall): boolean => aiNativeTool(call.name).mode === 'edit') && !this.assertEditMode()) throw new Error('查看模式不可编辑');
      if (calls.some((call: AiNativeCall): boolean => aiNativeTool(call.name).mode === 'edit') && macroService.isRecording()) throw new Error('请先结束宏录制，再应用原生编辑批次');
      if (checkpoint !== undefined && checkpoint.id === this.pendingAiRunId) { checkpoint.phase = 'applying'; checkpoint.updatedAt = Date.now(); aiService.saveTaskCheckpoint(checkpoint,conversationId); }
    } catch (error) { this.aiStore.aiError = `原生方案未执行：${String(error)}`; return; }
    this.aiStore.aiLoading = true; this.aiStore.aiCanCancel = false;
    const originalDocument: string = this.docStore.activeWorkspaceId;
    const atomic: boolean = calls.every((call: AiNativeCall): boolean => aiNativeTool(call.name).mode === 'edit');
    let previous: EditSessionState | undefined;
    let before: EditStructureState | undefined;
    let committed: boolean = false;
    const results: AiNativeResult[] = [];
    let success: boolean = false;
    try {
      if (atomic) this.captureAutomaticEngineeringOrigin();
      previous = atomic ? editService.captureSession() : undefined;
      before = atomic ? this.cellStructureState() : undefined;
      const marker: Object | null = editService.getUndoMarker();
      if (atomic && previous !== undefined && before !== undefined) {
        // Structural services deliberately seal their own transactions. Gather
        // their validated final state, then publish ONE editor transaction.
        for (const call of calls) {
          const result: AiNativeResult = this.runAiNativeEdit(call); results.push(result);
          if (!result.success) throw new Error(result.message);
          if (editService.getShapes().length > 1000000) throw new Error('文档图形超过预算');
        }
        const after: EditStructureState = this.cellStructureState();
        const shapes: Shape[] = editService.getShapes().slice();
        const selected: number[] = editService.getSelectedIds().slice();
        editService.restoreSession(previous); this.restoreCellStructure(before);
        if (!editService.applyDocumentStructure(shapes,before,after,'AI 原生工具批次',true,selected)) throw new Error('原生批次提交失败');
        committed = true;
        this.syncShapesFromEditService(); this.rebuildCellTree();
        this.aiUndoMarker = editService.getUndoMarker(); this.aiStore.aiCanUndo = this.aiUndoMarker !== marker;
        try { this.runDrc(true); results.push(aiNativeResult(true,this.aiDrcResultSummary(),undefined,'verification')); }
        catch (error) { results.push(aiNativeResult(true,`修改已应用，DRC 复检未完成：${String(error)}`,undefined,'verification_incomplete')); }
      } else {
        results.push(await this.runAiNativeAction(calls[0]));
      }
      success = results.every((result: AiNativeResult): boolean => result.success);
    } catch (error) {
      if (atomic && !committed && previous !== undefined && before !== undefined) {
        editService.restoreSession(previous);
        try { this.restoreCellStructure(before); } finally { editService.restoreSession(previous); }
        this.syncShapesFromEditService(); this.rebuildCellTree();
      }
      success = committed;
      results.push(aiNativeResult(committed,`${committed ? '修改已提交，后续刷新未完成：' : atomic ? '整批已回滚：' : '操作未完成：'}${String(error)}`));
    } finally {
      this.aiStore.aiLoading = false;
      this.aiStore.aiLastResult = results.map((result: AiNativeResult): string => `${result.status}：${result.message}${result.data === undefined ? '' : `\n${JSON.stringify(result.data).substring(0,12000)}`}`).join('\n');
      this.panelStore.statusText = this.aiStore.aiLastResult;
      // Document switching may clear the pending UI; keep the original run identity.
      this.cancelPendingAiCommands(false);
      this.setLastAiCommandStatus(success ? 'executed' : 'failed');
      try {
        const receipt: string = `原生工具执行回执\n来源文档 ${originalDocument}\n当前文档 ${this.docStore.activeWorkspaceId} / 版本 ${this.docStore.editorRevision}\n${this.aiStore.aiLastResult}`;
        if (checkpoint !== undefined && checkpoint.id === runId) {
          checkpoint.phase = success ? 'applied' : 'failed'; checkpoint.updatedAt = Date.now(); checkpoint.receipt = receipt;
          aiService.saveTaskCheckpoint(checkpoint,conversationId);
        }
        aiService.recordExecutionReceipt(receipt,conversationId); this.refreshAiConversation();
      } catch (error) { this.aiStore.aiError = `执行结果已产生，回执保存失败：${String(error)}；请勿重复应用`; }
    }
  }

  private applyAiCommands(commands: ParsedCommand[], fullText: string, prompt: string, context: AiContext): boolean {
    if (commands.length === 0) {
      this.panelStore.statusText = fullText.length > 0 ? `AI: ${fullText}` : `AI: 未能理解指令 "${prompt}"`;
      return false;
    }
    const hasEditCommand: boolean = commands.some((c: ParsedCommand) =>
        c.type === AiCommandType.CREATE_RECT || c.type === AiCommandType.CREATE_POLYGON ||
        c.type === AiCommandType.CREATE_PATH || c.type === AiCommandType.CREATE_TEXT ||
        c.type === AiCommandType.CREATE_ARRAY || c.type === AiCommandType.MOVE_SHAPE ||
        c.type === AiCommandType.DELETE_SHAPE || c.type === AiCommandType.ROTATE_SHAPE ||
        c.type === AiCommandType.MIRROR_SHAPE || c.type === AiCommandType.SCALE_SHAPE
      );
    if (hasEditCommand && !this.assertEditMode()) {
        this.aiStore.aiError = '当前为查看模式，请切换到编辑模式后重新生成方案。';
        this.setLastAiCommandStatus('failed');
        return false;
    }
    const results: CommandResult[] = [];
    const previousSession: EditSessionState = editService.captureSession();
    const beforeMarker: Object | null = editService.getUndoMarker();
    const useBatch: boolean = hasEditCommand;
    let batchFailed: boolean = false;
    const executionContext: AiContext = cloneStructured(context) as AiContext;
    if (useBatch) {
      editService.beginBatch();
    }
    try {
      for (let i = 0; i < commands.length; i++) {
        const r: CommandResult = aiExecutor.execute(commands[i], executionContext);
        results.push(r);
        if (!r.success) {
          batchFailed = true;
          break;
        }
        if (r.viewAction?.selectLayer !== undefined) {
          executionContext.currentLayer = r.viewAction.selectLayer;
          executionContext.currentDatatype = r.viewAction.selectDatatype ?? 0;
        }
      }
    } catch (error) {
      batchFailed = true;
      results.push({ command: commands[Math.min(results.length, commands.length - 1)], success: false,
        message: `执行异常：${String(error)}`, affectedShapeIds: [] });
    } finally {
      if (useBatch) {
        editService.endBatch();
      }
    }
    if (batchFailed) {
      editService.restoreSession(previousSession);
    }
    this.syncShapesFromEditService();
    const viewAction: ViewAction | undefined = AiCommandExecutor.mergeViewActions(results);
    if (!batchFailed && viewAction !== undefined) {
      this.applyViewAction(viewAction);
    }
    let successCount = 0;
    const messages: string[] = [];
    for (let i = 0; i < results.length; i++) {
      if (results[i].success) {
        successCount++;
      }
      messages.push(results[i].message);
    }
    if (!batchFailed && hasEditCommand && editService.getUndoMarker() !== beforeMarker) {
      try {
        this.runDrc(true);
        messages.push(this.verifyStore.drcHasRun ? this.aiDrcResultSummary() : `复检未完成：${this.panelStore.statusText}`);
      } catch (error) { messages.push(`修改已应用，复检未完成：${String(error)}`); }
    }
    this.panelStore.statusText = batchFailed
      ? `AI: 执行失败，整批已回滚，后续命令未执行 - ${messages.join(' | ')}`
      : `AI: 执行 ${successCount}/${commands.length} 条 - ${messages.join(' | ')}`;
    this.aiStore.aiLastResult = this.panelStore.statusText;
    this.setLastAiCommandStatus(!batchFailed && successCount === commands.length ? 'executed' : 'failed');
    this.aiUndoMarker = editService.getUndoMarker();
    this.aiStore.aiCanUndo = !batchFailed && hasEditCommand && this.aiUndoMarker !== null && this.aiUndoMarker !== beforeMarker;
    return !batchFailed && successCount === commands.length;
  }

  private buildAiContext(): AiContext {
    const aiLayers: AiLayerInfo[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const info: AiLayerInfo = {
        layerNumber: this.docStore.layers[i].layerNumber,
        datatype: this.docStore.layers[i].datatype,
        chineseName: this.docStore.layers[i].chineseName,
        englishName: this.docStore.layers[i].englishName,
        visible: this.docStore.layers[i].visible,
      };
      aiLayers.push(info);
    }
    const selectedShapes: AiSelectedShape[] = editService.getSelectedShapes().slice(0, 64).map((shape: Shape): AiSelectedShape => {
      const bounds: ShapeBounds = getShapeBounds(shape);
      return { id: shape.id, cellId: shape.ownerCellId ?? editService.getTopCellId(), type: shape.type,
        layer: shape.layerNumber, datatype: shape.datatype, x: bounds.minX, y: bounds.minY,
        width: bounds.maxX - bounds.minX, height: bounds.maxY - bounds.minY,
        points: shape.points.slice(0, 128).map((point: Point): Point => ({ x: point.x, y: point.y })), text: shape.text };
    });
    const cellCounts: Map<number, number> = new Map<number, number>();
    const childCells: Map<number, Set<number>> = new Map<number, Set<number>>();
    const shapeLayers: Map<number, number> = new Map<number, number>();
    for (const shape of this.shapes) {
      const owner: number = shape.ownerCellId ?? editService.getTopCellId();
      cellCounts.set(owner, (cellCounts.get(owner) ?? 0) + 1); shapeLayers.set(shape.id, shape.layerNumber);
      if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
        let children: Set<number> | undefined = childCells.get(owner);
        if (children === undefined) { children = new Set<number>(); childCells.set(owner, children); }
        children.add(shape.cellId);
      }
    }
    const current: number = editService.getCurrentCellId();
    const cells: AiCellInfo[] = this.propertyCellOptions().slice(0, 128).map((cell: PropertyCellOption): AiCellInfo => ({
      id: cell.id, name: cell.name, shapeCount: cellCounts.get(cell.id) ?? 0,
      children: Array.from(childCells.get(cell.id) ?? new Set<number>()).slice(0, 128) }));
    const lastDrc = drcService.getLastResult();
    const issues: AiIssueInfo[] = this.drcSnapshotRevision === this.docStore.editorRevision && lastDrc !== null
      ? lastDrc.violations.slice(0, 64).map((issue: DrcViolation): AiIssueInfo => ({ id: String(issue.id),
        rule: issue.ruleName, message: issue.message, x: issue.x, y: issue.y, shapeIds: issue.shapeIds.slice(0, 256) })) : [];
    const nets: AiNetInfo[] = this.netSnapshotRevision === this.docStore.editorRevision
      ? this.verifyStore.tracedNets.slice(0, 32).map((net: Net): AiNetInfo => ({ name: net.name, shapeIds: net.shapes.slice(0, 256),
        layerNumbers: Array.from(new Set<number>(net.shapes.map((id: number): number => shapeLayers.get(id) ?? -1))).filter((layer: number) => layer >= 0) })) : [];
    const scale: number = Math.max(MIN_ZOOM_PERCENT, this.viewportStore.zoomPercent) / 100;
    const context: AiContext = {
      coordinateUnit: 'nm', dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits),
      documentIdentity: this.docStore.activeWorkspaceId, documentRevision: this.docStore.editorRevision,
      technology: technologyService.getActive()?.name ?? '当前未绑定工艺包',
      projectKnowledge: aiService.getProjectKnowledge(this.docStore.activeWorkspaceId),
      executionReceipt: aiService.getTaskCheckpoint()?.receipt,
      coverage: { selectedTotal: editService.getSelectedShapes().length, selectedIncluded: selectedShapes.length,
        cellTotal: this.propertyCellOptions().length, cellIncluded: cells.length,
        drcTotal: this.drcSnapshotRevision === this.docStore.editorRevision ? lastDrc?.violations.length ?? 0 : 0, drcIncluded: issues.length,
        netTotal: this.netSnapshotRevision === this.docStore.editorRevision ? this.verifyStore.tracedNets.length : 0, netIncluded: nets.length,
        selectedGeometryTruncated: editService.getSelectedShapes().some((shape: Shape): boolean => shape.points.length > 128) },
      topCellId: editService.getTopCellId(), selectedShapes, cells, drcIssues: issues, nets,
      currentCell: { id: current, name: this.cellName(current), shapeCount: cellCounts.get(current) ?? 0,
        children: Array.from(childCells.get(current) ?? new Set<number>()).slice(0, 128) },
      viewport: { minX: -this.viewportStore.viewOffsetX, maxX: this.viewportStore.canvasViewportWidth / scale - this.viewportStore.viewOffsetX,
        minY: this.viewportStore.viewOffsetY - this.viewportStore.canvasViewportHeight / scale, maxY: this.viewportStore.viewOffsetY, scale },
      layers: aiLayers,
      currentLayer: this.viewportStore.selectedLayerNumber,
      currentDatatype: this.viewportStore.selectedDatatype,
      shapeCount: this.shapes.length,
      selectedShape: selectedShapes.length > 0 ? selectedShapes[0] : null,
      drcSummary: {
        total: this.drcSnapshotRevision === this.docStore.editorRevision ? this.verifyStore.drcIssues.length : 0,
        errors: this.drcSnapshotRevision === this.docStore.editorRevision ? this.errorCount() : 0,
        warnings: this.drcSnapshotRevision === this.docStore.editorRevision ? this.warningCount() : 0,
      },
    };
    return context;
  }

  private applyViewAction(action: ViewAction): void {
    if (action.focusBounds !== undefined) this.focusWorldBounds({ minX: action.focusBounds.minX, minY: action.focusBounds.minY,
      maxX: action.focusBounds.maxX, maxY: action.focusBounds.maxY });
    if (action.selectLayer !== undefined) {
      this.viewportStore.selectedLayerNumber = action.selectLayer;
      this.viewportStore.selectedDatatype = action.selectDatatype ?? 0;
    }
    if (action.layerVisibles !== undefined) {
      for (let i = 0; i < action.layerVisibles.length; i++) {
        const lv = action.layerVisibles[i];
        this.setLayerVisible(lv.layer, lv.visible, lv.datatype ?? 0);
      }
    } else if (action.layerVisible !== undefined) {
      this.setLayerVisible(action.layerVisible.layer, action.layerVisible.visible, action.layerVisible.datatype ?? 0);
    }
    if (action.zoomScale !== undefined) {
      this.zoomCanvasToAt(
        this.viewportStore.canvasViewportWidth / 2,
        this.viewportStore.canvasViewportHeight / 2,
        action.zoomScale
      );
    }
    if (action.fitAll !== undefined && action.fitAll) {
      this.fitAllShapes();
    }
    if (action.tool !== undefined) {
      this.viewportStore.currentTool = this.drawToolToActiveTool(action.tool);
    }
    if (action.showDrc !== undefined) {
      if (this.drcSnapshotRevision !== this.docStore.editorRevision) { this.runDrc(); return; }
      this.verifyStore.drcHasRun = true;
      this.verifyStore.drcDockCollapsed = false;
      this.viewportStore.currentModule = WorkModule.Verify;
      this.verifyStore.drcIssues = this.convertViolationsToIssues(action.showDrc.violations);
      this.verifyStore.lastDrcElapsed = action.showDrc.elapsed;
      this.verifyStore.highlightedViolationId = -1;
      this.verifyStore.highlightedViolation = null;
    }
  }

  /** 画布拖拽绘制矩形完成回调：用当前选中图层创建矩形并同步视图 */
  private createRectShape(start: Point, end: Point): boolean {
    if (!this.assertEditMode()) {
      return false;
    }
    if (!editService.canEditLayer(this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype)) {
      this.panelStore.statusText = `L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 已锁定，无法绘制`;
      return false;
    }
    const x1: number = Math.min(start.x, end.x);
    const y1: number = Math.min(start.y, end.y);
    const x2: number = Math.max(start.x, end.x);
    const y2: number = Math.max(start.y, end.y);
    let shape: Shape;
    try { shape = editService.createRect(this.viewportStore.selectedLayerNumber, x1, y1, x2, y2, this.viewportStore.selectedDatatype); } catch (error) {
      this.panelStore.statusText = `矩形未创建：${String(error)}`; return false;
    }
    editService.selectShape(shape.id);
    this.syncShapesFromEditService();
    this.viewportStore.selectedShapeId = shape.id;
    this.panelStore.statusText = `已创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 矩形 (ID: ${shape.id}, ${x2 - x1}x${y2 - y1}nm)`;
    if (macroService.isRecording()) {
      this.recordMacroStep(`创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 矩形 ${x2 - x1}x${y2 - y1}nm @(${x1},${y1})`,
        `create_rect|${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}|${x1}|${y1}|${x2}|${y2}`);
    }
    return true;
  }

  /** 画布 Polygon 绘制完成回调：调用 editService.createPolygon 创建多边形 */
  private createPolygonShape(points: Point[]): boolean {
    if (!this.assertEditMode()) {
      return false;
    }
    if (!editService.canEditLayer(this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype)) {
      this.panelStore.statusText = `L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 已锁定，无法绘制`;
      return false;
    }
    if (points.length < 3) {
      this.panelStore.statusText = '多边形至少需要 3 个顶点';
      return false;
    }
    let shape: Shape;
    try { shape = editService.createPolygon(this.viewportStore.selectedLayerNumber, points, this.viewportStore.selectedDatatype); } catch (error) {
      this.panelStore.statusText = `多边形未创建：${String(error)}`; return false;
    }
    editService.selectShape(shape.id);
    this.syncShapesFromEditService();
    this.viewportStore.selectedShapeId = shape.id;
    this.panelStore.statusText = `已创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 多边形 (ID: ${shape.id}, ${points.length} 顶点)`;
    if (macroService.isRecording()) {
      const ptsStr = points.map(p => `${p.x},${p.y}`).join('|');
      this.recordMacroStep(`创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 多边形 ${points.length} 顶点`,
        `create_polygon|${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}|${ptsStr}`);
    }
    return true;
  }

  /** 画布 Path 绘制完成回调：调用 editService.createPath 创建路径 */
  private createPathShape(points: Point[], width: number, pathType: number = 0): boolean {
    if (!this.assertEditMode()) {
      return false;
    }
    if (!editService.canEditLayer(this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype)) {
      this.panelStore.statusText = `L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 已锁定，无法绘制`;
      return false;
    }
    if (points.length < 2) {
      this.panelStore.statusText = '路径至少需要 2 个顶点';
      return false;
    }
    let shape: Shape;
    try { shape = editService.createPath(this.viewportStore.selectedLayerNumber, points, width, this.viewportStore.selectedDatatype, pathType); } catch (error) {
      this.panelStore.statusText = `路径未创建：${String(error)}`; return false;
    }
    editService.selectShape(shape.id);
    this.syncShapesFromEditService();
    this.viewportStore.selectedShapeId = shape.id;
    this.panelStore.statusText = `已创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 路径 (ID: ${shape.id}, ${points.length} 顶点, 线宽 ${width}nm)`;
    if (macroService.isRecording()) {
      const ptsStr = points.map(p => `${p.x},${p.y}`).join('|');
      this.recordMacroStep(`创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 路径 ${points.length} 顶点 线宽${width}nm`,
        `create_path|${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}|${width}|${ptsStr}`);
    }
    return true;
  }

  /** 画布 Text 创建回调：调用 editService.createText 创建文本标注 */
  private createTextShape(x: number, y: number, text: string): boolean {
    if (!this.assertEditMode()) {
      return false;
    }
    if (!editService.canEditLayer(this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype)) {
      this.panelStore.statusText = `L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 已锁定，无法绘制`;
      return false;
    }
    if (!Number.isFinite(x) || !Number.isFinite(y) || text.trim().length === 0) {
      this.panelStore.statusText = '文本坐标或内容无效'; return false;
    }
    let shape: Shape;
    try { shape = editService.createText(this.viewportStore.selectedLayerNumber, x, y, text, this.viewportStore.selectedDatatype); } catch (error) {
      this.panelStore.statusText = `文本未插入：${String(error)}`; return false;
    }
    editService.selectShape(shape.id);
    this.syncShapesFromEditService();
    this.viewportStore.selectedShapeId = shape.id;
    this.panelStore.statusText = `已创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 文本 (ID: ${shape.id}, "${text}" @ ${x},${y})`;
    if (macroService.isRecording()) {
      this.recordMacroStep(`创建 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 文本 "${text}" @(${x},${y})`,
        `create_text|${this.viewportStore.selectedLayerNumber}/${this.viewportStore.selectedDatatype}|${x}|${y}|${text}`);
    }
    return true;
  }

  /** 编辑选中图形：切换 Inspector 到属性面板供用户编辑坐标/尺寸/图层 */
  private editSelectedShape(): void {
    if (!this.assertEditMode()) {
      return;
    }
    if (this.viewportStore.selectedShapeId < 0) {
      this.panelStore.statusText = '未选中图形，无法编辑';
      return;
    }
    // INDEX-5: inspectorTab 已移除；LayerInspector 在 selectedShapeId >= 0 时自动展示属性面板
    this.showInspectorPanel();
    this.panelStore.statusText = `已选中图形 #${this.viewportStore.selectedShapeId}，请在右侧属性面板编辑`;
  }

  private updateShapeProperty(shapeId: number, property: string, value: string): void {
    if (!this.assertEditMode()) {
      return;
    }
    const shape: Shape | undefined = this.shapes.find((s: Shape) => s.id === shapeId);
    if (shape === undefined) {
      this.panelStore.statusText = `属性编辑失败：未找到图形 #${shapeId}`;
      return;
    }

    if (property === 'layerKey') {
      const parts: string[] = value.split('/');
      const layer: number = Number(parts[0]);
      const datatype: number = Number(parts[1]);
      if (parts.length !== 2 || !Number.isInteger(layer) || !Number.isInteger(datatype) ||
        layer < 0 || layer > 32767 || datatype < 0 || datatype > 32767) {
        this.panelStore.statusText = '图层必须是 0–32767 范围的 layer/datatype 整数对';
        return;
      }
      const ok: boolean = editService.updateShape(shapeId, layer, 0, 0, datatype);
      this.finishShapePropertyUpdate(ok, shapeId, `图层 ${layer}/${datatype}`);
      return;
    }

    if (property === 'text') {
      const ok: boolean = editService.updateShapeText(shapeId, value);
      this.finishShapePropertyUpdate(ok, shapeId, '文本');
      return;
    }

    const numericValue: number = value.trim().length > 0 ? Number(value) : Number.NaN;
    if (!Number.isFinite(numericValue)) {
      this.panelStore.statusText = `属性编辑失败：${value} 不是有效数字`;
      return;
    }

    let ok: boolean = false;
    if (property === 'layer') {
      const nextLayer: number = Math.max(0, Math.round(numericValue));
      ok = editService.updateShape(shapeId, nextLayer, 0, 0);
      if (ok) {
        this.viewportStore.selectedLayerNumber = nextLayer;
        this.viewportStore.selectedDatatype = shape.datatype;
      }
      this.finishShapePropertyUpdate(ok, shapeId, `图层 L${nextLayer}`);
      return;
    }
    if (property === 'pathWidth') {
      ok = editService.updateShapePathWidth(shapeId, numericValue);
      this.finishShapePropertyUpdate(ok, shapeId, '线宽');
      return;
    }

    if (property === 'x') {
      ok = this.updateShapeBounds(shape, numericValue, undefined, undefined, undefined);
    } else if (property === 'y') {
      ok = this.updateShapeBounds(shape, undefined, numericValue, undefined, undefined);
    } else if (property === 'width') {
      ok = this.updateShapeBounds(shape, undefined, undefined, numericValue, undefined);
    } else if (property === 'height') {
      ok = this.updateShapeBounds(shape, undefined, undefined, undefined, numericValue);
    }
    this.finishShapePropertyUpdate(ok, shapeId, property);
  }

  private updateShapeBounds(
    shape: Shape,
    nextX?: number,
    nextY?: number,
    nextWidth?: number,
    nextHeight?: number
  ): boolean {
    if (shape.points.length === 0) {
      return false;
    }
    const bounds = getShapeBounds(shape);
    const targetX: number = nextX ?? bounds.minX;
    const targetY: number = nextY ?? bounds.minY;
    const currentWidth: number = bounds.maxX - bounds.minX;
    const currentHeight: number = bounds.maxY - bounds.minY;
    const targetWidth: number = nextWidth ?? currentWidth;
    const targetHeight: number = nextHeight ?? currentHeight;

    if ((nextWidth !== undefined && targetWidth <= 0) || (nextHeight !== undefined && targetHeight <= 0)) {
      this.panelStore.statusText = '属性编辑失败：宽高必须大于 0';
      return false;
    }
    if ((shape.type === ShapeType.TEXT || shape.type === ShapeType.INSTANCE) &&
      (nextWidth !== undefined || nextHeight !== undefined)) {
      this.panelStore.statusText = '文本和实例暂不支持直接改宽高，请修改位置或引用内容';
      return false;
    }

    const points: Point[] = [];
    if (shape.type === ShapeType.RECT && shape.points.length >= 2) {
      points.push({ x: targetX, y: targetY });
      points.push({ x: targetX + Math.max(0, targetWidth), y: targetY + Math.max(0, targetHeight) });
    } else if (shape.type === ShapeType.TEXT || shape.type === ShapeType.INSTANCE) {
      const dx: number = targetX - bounds.minX;
      const dy: number = targetY - bounds.minY;
      for (let i = 0; i < shape.points.length; i++) {
        points.push({ x: shape.points[i].x + dx, y: shape.points[i].y + dy });
      }
    } else {
      const scaleX: number = currentWidth === 0 ? 1 : targetWidth / currentWidth;
      const scaleY: number = currentHeight === 0 ? 1 : targetHeight / currentHeight;
      for (let i = 0; i < shape.points.length; i++) {
        points.push({
          x: targetX + (shape.points[i].x - bounds.minX) * scaleX,
          y: targetY + (shape.points[i].y - bounds.minY) * scaleY,
        });
      }
    }
    return editService.updateShapePoints(shape.id, points);
  }

  private finishShapePropertyUpdate(ok: boolean, shapeId: number, label: string): void {
    if (!ok) {
      if (this.panelStore.statusText.indexOf('失败') < 0 && this.panelStore.statusText.indexOf('暂不支持') < 0) {
        this.panelStore.statusText = `属性编辑失败：无法更新 ${label}`;
      }
      return;
    }
    this.syncShapesFromEditService();
    const updated: Shape | undefined = this.shapes.find((s: Shape) => s.id === shapeId);
    if (updated !== undefined) {
      this.viewportStore.selectedShapeId = updated.id;
      this.viewportStore.selectedLayerNumber = updated.layerNumber;
        this.viewportStore.selectedDatatype = updated.datatype;
    }
    this.panelStore.statusText = `已更新图形 #${shapeId} 的${label}`;
  }

  /** 复制选中图形到跨标签共享剪贴板（附带源文档 cellNames 与被引用子 Cell 定义子树） */
  private copySelection(): void {
    if (this.viewportStore.selectedShapeId < 0 && editService.getSelectedShapes().length === 0) {
      this.panelStore.statusText = '未选中图形，无法复制';
      return;
    }
    const count: number = editService.copySelection(this.docStore.activeWorkspaceId, this.cellStructureState());
    if (count > 0) {
      this.panelStore.statusText = `已复制 ${count} 个图形到剪贴板`;
      showAppToast(this.getUIContext(), '已复制', AppToastDuration.SHORT);
    } else {
      this.panelStore.statusText = '复制失败：未找到选中图形';
    }
  }

  /** 从跨标签共享剪贴板粘贴图形（自动重映射/导入缺失子 Cell 定义） */
  private pasteFromClipboard(): void {
    if (!this.assertEditMode()) {
      return;
    }
    const created: Shape[] = editService.pasteShapes(true, this.docStore.activeWorkspaceId);
    if (created.length === 0) {
      this.panelStore.statusText = editService.getClipboardBundle() === null
        ? '剪贴板为空，无法粘贴（请先复制图形）'
        : '粘贴失败：目标图层已锁定、存在循环实例引用或超出图形预算';
      return;
    }
    const createdIds: number[] = [];
    for (let i = 0; i < created.length; i++) {
      createdIds.push(created[i].id);
    }
    editService.selectMultiple(createdIds);
    this.viewportStore.selectedShapeId = created[created.length - 1].id;
    this.syncShapesFromEditService();
    this.rebuildCellTree();
    this.panelStore.statusText = `已粘贴 ${created.length} 个图形（偏移 +20,+20 nm）`;
    if (macroService.isRecording()) {
      this.recordMacroStep(`粘贴 ${created.length} 个图形`, `paste`);
    }
  }

  /** 画布拖拽移动选中图形回调：提交位移到 EditService（支持撤销）并同步视图 */
  private moveShape(shapeId: number, deltaX: number, deltaY: number): void {
    if (!this.assertEditMode()) {
      return;
    }
    editService.moveShape(shapeId, deltaX, deltaY);
    this.syncShapesFromEditService();
    this.panelStore.statusText = `已移动图形 #${shapeId} (${deltaX.toFixed(1)}, ${deltaY.toFixed(1)}nm)`;
    if (macroService.isRecording()) {
      this.recordMacroStep(`移动图形 #${shapeId} (${deltaX.toFixed(1)}, ${deltaY.toFixed(1)})`,
        `move_shape|${shapeId}|${deltaX}|${deltaY}`);
    }
  }

  private undoEdit(): void {
    this.finishNudgeTransaction();
    if (!this.assertEditMode()) {
      return;
    }
    // 接通 EditService：撤销上一步操作
    // E-TX: EditService 一次弹一条记录 = 一个用户级手势（拖拽/微移串/批量删除整体回退），
    // 且已在服务内收口选择集，这里把主选同步回 UI，避免属性面板/工具栏指向已消失的图形
    const layerPropertiesHistory: boolean = editService.isLayerPropertiesUndo();
    if (editService.undo()) {
      this.viewportStore.selectedShapeId = editService.getSelectedId();
      this.syncShapesFromEditService(layerPropertiesHistory);
      this.calibrateNativeBaselineIfClean();
      this.vertexStore.setHint('');
      this.panelStore.statusText = `已撤销上一步操作（剩余 ${editService.undoStepCount()} 步可撤）`;
    } else {
      this.panelStore.statusText = '没有可撤销的操作';
    }
  }

  private redoEdit(): void {
    this.finishNudgeTransaction();
    if (!this.assertEditMode()) {
      return;
    }
    // 接通 EditService：重做上一步操作
    const layerPropertiesHistory: boolean = editService.isLayerPropertiesRedo();
    if (editService.redo()) {
      this.viewportStore.selectedShapeId = editService.getSelectedId();
      this.syncShapesFromEditService(layerPropertiesHistory);
      this.calibrateNativeBaselineIfClean();
      this.vertexStore.setHint('');
      this.panelStore.statusText = '已重做上一步操作';
    } else {
      this.panelStore.statusText = '没有可重做的操作';
    }
  }

  private alignSelection(type: AlignType, label: string): void {
    if (!this.assertEditMode()) {
      return;
    }
    // 接通 AdvancedEditService：对齐选中图形（当前为单选模式，需 ≥2 个选中图形）
    if (advEditService.alignSelection(type, this.docStore.hierarchyDepth)) {
      this.syncShapesFromEditService();
      this.panelStore.statusText = `已执行${label}`;
      if (macroService.isRecording()) {
        this.recordMacroStep(label, `align|${type}`);
      }
    } else {
      this.panelStore.statusText = advEditService.getLastGeometryError() || `${label}需要至少 2 个选中图形`;
    }
  }

  /** 对齐类型转中文标签（供右键菜单显示） */
  private alignLabel(type: AlignType): string {
    if (type === AlignType.LEFT) {
      return '左对齐';
    }
    if (type === AlignType.RIGHT) {
      return '右对齐';
    }
    if (type === AlignType.TOP) {
      return '顶对齐';
    }
    if (type === AlignType.BOTTOM) {
      return '底对齐';
    }
    if (type === AlignType.CENTER_H) {
      return '水平居中';
    }
    if (type === AlignType.CENTER_V) {
      return '垂直居中';
    }
    return '对齐';
  }

  /** 等距分布选中图形（需 ≥3 个选中，首尾固定，中间均匀分布） */
  private distributeSelection(type: DistributeType): void {
    if (!this.assertEditMode()) {
      return;
    }
    const label: string = type === DistributeType.HORIZONTAL ? '水平等距分布' : '垂直等距分布';
    if (advEditService.distributeSelection(type, this.docStore.hierarchyDepth)) {
      this.syncShapesFromEditService();
      this.panelStore.statusText = `已执行${label}`;
      if (macroService.isRecording()) {
        this.recordMacroStep(label, `distribute|${type}`);
      }
    } else {
      this.panelStore.statusText = advEditService.getLastGeometryError() || `${label}需要至少 3 个选中图形`;
    }
  }

  /** 批量改选中图形的图层（右键菜单"改图层"触发） */
  private changeLayerOfSelected(layerNumber: number, datatype: number = 0): void {
    if (!this.assertEditMode()) {
      return;
    }
    const selected: Shape[] = editService.getSelectedShapes();
    const ids: number[] = [];
    for (let i = 0; i < selected.length; i++) {
      ids.push(selected[i].id);
    }
    if (ids.length === 0) {
      // 单选回退：用当前 selectedShapeId
      if (this.viewportStore.selectedShapeId >= 0) {
        ids.push(this.viewportStore.selectedShapeId);
      }
    }
    if (ids.length === 0) {
      this.panelStore.statusText = '未选中图形，无法改图层';
      return;
    }
    if (!editService.canEditLayer(layerNumber, datatype)) {
      this.panelStore.statusText = `目标图层 ${layerNumber}/${datatype} 已锁定，无法改层`;
      return;
    }
    const changed = editService.changeLayer(ids, layerNumber, datatype);
    if (!changed.ok || changed.changed === 0) { this.panelStore.statusText = changed.message; return; }
    this.syncShapesFromEditService();
    this.viewportStore.selectedLayerNumber = layerNumber;
    this.viewportStore.selectedDatatype = datatype;
    this.panelStore.statusText = `已将 ${changed.changed} 个图形改到 L${layerNumber}/D${datatype}`;
    if (macroService.isRecording()) {
      this.recordMacroStep(`改图层到 L${layerNumber}/D${datatype} (${ids.length} 个图形)`,
        `change_layer|${ids.join(',')}|${layerNumber}/${datatype}`);
    }
  }

  private setLayerSelectable(layerNumber: number, datatype: number, selectable: boolean): void {
    this.docStore.layers = this.docStore.layers.map((layer: UiLayer): UiLayer => {
      const next: UiLayer = cloneLayerWithVisible(layer, layer.visible);
      if (next.layerNumber === layerNumber && next.datatype === datatype) next.selectable = selectable;
      return next;
    });
    this.syncLayerVisibilityMirror(); this.docStore.editorRevision++; this.scheduleWorkspaceDraft();
    this.panelStore.statusText = `L${layerNumber}/D${datatype} ${selectable ? '可选择' : '不可选择'}；编辑锁定独立控制`;
  }

  private precisionSettings(): PrecisionSettings {
    return { dbuNm: cleanDbuNm(this.docStore.docPhysicalUnits), drawStepNm: this.viewportStore.drawStepNm, displayGridNm: this.viewportStore.displayGridNm,
      geometrySnapEnabled: this.viewportStore.geometrySnapEnabled, geometrySnapKinds: this.viewportStore.geometrySnapKinds.slice() };
  }

  private geometryQuantization(dbuNm: number): QuantizationReport {
    const report: QuantizationReport = { count: 0, changedCount: 0, maxDeltaNm: 0 };
    for (const shape of editService.getShapes()) {
      const values: number[] = [];
      for (const point of shape.points) values.push(point.x, point.y);
      for (const value of [shape.pathWidth, shape.pathBeginExtension, shape.pathEndExtension, shape.arrayColStepX, shape.arrayColStepY, shape.arrayRowStepX, shape.arrayRowStepY]) {
        if (value !== undefined) values.push(value);
      }
      const part: QuantizationReport = quantizationReport(values, dbuNm);
      report.count += part.count; report.changedCount += part.changedCount; report.maxDeltaNm = Math.max(report.maxDeltaNm, part.maxDeltaNm);
      if (report.firstChange === undefined && part.firstChange !== undefined) report.firstChange = part.firstChange;
    }
    return report;
  }

  private applyPrecisionSettings(settings: PrecisionSettings): boolean {
    const error: string = validatePrecision(settings);
    if (error.length > 0) { this.panelStore.statusText = error; return false; }
    const context: string = this.parameterDialogContext();
    const commit = (): void => {
      if (context !== this.parameterDialogContext()) { this.panelStore.statusText = '文档已变化，请重新设置精度'; return; }
      const before: EditStructureState = this.cellStructureState();
      const after: EditStructureState = cloneEditStructureModel(before, true) as EditStructureState;
      after.physicalUnits = settings.dbuNm * 1e-9; after.userUnits = settings.dbuNm / 1000; after.precision = settings;
      if (!editService.applyDocumentStructure(editService.getShapes(), before, after, `精度设置：DBU ${settings.dbuNm}nm · 步长 ${settings.drawStepNm}nm · 显示网格 ${settings.displayGridNm}nm`)) { this.panelStore.statusText = '精度设置未提交，原文档已保留'; return; }
      this.syncShapesFromEditService(); this.scheduleWorkspaceDraft();
      this.panelStore.statusText = `精度已更新：DBU ${settings.dbuNm} nm，绘制 ${settings.drawStepNm} nm，显示 ${settings.displayGridNm} nm；可撤销`;
    };
    if (settings.dbuNm !== cleanDbuNm(this.docStore.docPhysicalUnits)) {
      if (!this.assertEditMode()) return false;
      try {
        const report: QuantizationReport = this.geometryQuantization(settings.dbuNm);
        if (report.changedCount > 0) {
          const first: string = report.firstChange === undefined ? '' : `\n示例：${report.firstChange.requestedNm} → ${report.firstChange.writtenNm} nm`;
          this.canvasFocusReturnTicket++;
          AlertDialog.show({ cornerRadius: UI.dialogRadius, title: '数据库精度变化', message: `导出时 ${report.changedCount}/${report.count} 个数值会量化，最大偏差 ${Number(report.maxDeltaNm.toPrecision(4))} nm。当前几何坐标保持原值。${first}`,
            primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消', action: () => { this.panelStore.statusText = '已取消精度变化'; } },
            secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '应用并保留撤销记录', action: commit } });
          return true;
        }
      } catch (failure) { this.panelStore.statusText = `精度检查失败：${String(failure)}`; return false; }
    }
    commit(); return true;
  }

  private sharedCellScopeText(): string {
    const cellId: number = editService.getCurrentCellId();
    const entered: InstancePathStep[] = editService.getNavigationPath();
    const path: InstancePathStep[] = this.localInstancePath();
    const picked: boolean = this.validPickedPlacement();
    const targetId: number = path.length > 0 ? path[path.length - 1].cellId : cellId;
    const key: string = `${this.docStore.activeWorkspaceId}:${editService.getSessionRevision()}:${cellId}:${this.cellName(cellId)}:${picked}:${JSON.stringify(path)}`;
    if (key === this.scopeLabelKey) return this.scopeLabelValue;
    const impact = editService.getSharedImpact(targetId);
    if (!impact.ok) {
      this.viewportStore.instanceScopeSummary = `${this.cellName(targetId)} · 影响统计失败`;
      return `目标 Cell ${this.cellName(targetId)} · 影响统计失败：${impact.message}`;
    }
    const enteredText: string = entered.map((step: InstancePathStep): string =>
      `${this.cellName(step.cellId)}#${step.instanceId}[${step.row + 1},${step.col + 1}]`).join(' / ');
    const pathText: string = path.map((step: InstancePathStep): string =>
      `${this.cellName(step.cellId)}#${step.instanceId}[${step.row + 1},${step.col + 1}]`).join(' / ');
    const current: string = enteredText.length > 0 ? `${this.cellName(entered[0].parentCellId)} / ${enteredText}` : `${this.cellName(cellId)}（定义）`;
    const target: string = picked ? ` · 点选：${this.cellName(path[0].parentCellId)} / ${pathText}` : '';
    this.scopeLabelKey = key;
    this.viewportStore.instanceScopeSummary = `${this.cellName(cellId)}${picked ? ` → ${this.cellName(targetId)}` : ''} · ${impact.directReferences} 条引用 · ${impact.bounded ? '至少 ' : ''}${impact.placements} 个摆放`;
    this.scopeLabelValue = `共享定义范围：修改时同步全部引用 · 当前编辑：${current}${target} · ${this.cellName(targetId)} 共享定义：${impact.directReferences} 条引用，${impact.parentCells} 个父 Cell，${impact.bounded ? '至少 ' : ''}${impact.placements} 个摆放（引用按全库直接记录；摆放按工程 Top ${this.docStore.docTopCellName} 下递归展开）`;
    return this.scopeLabelValue;
  }

  /** Refresh presentation only; view/report navigation must retain analysis state. */
  private refreshEditingCellPresentation(): void {
    const activeCellId: number = editService.getCurrentCellId();
    this.docStore.currentEditingCellId = activeCellId;
    this.docStore.currentTopCellId = activeCellId;
    this.docStore.currentEditingCellName = this.cellName(activeCellId);
    this.viewportStore.instanceScopeLabel = this.sharedCellScopeText();
  }

  private localInstancePath(): InstancePathStep[] {
    const entered: InstancePathStep[] = editService.getNavigationPath();
    if (this.viewportStore.pickedPlacement !== null && this.validPickedPlacement()) return entered.concat(this.viewportStore.pickedPlacement.path);
    return entered;
  }

  private validPickedPlacement(): boolean {
    const picked: HierarchyHitCandidate | null = this.viewportStore.pickedPlacement;
    return picked !== null && picked.path.length > 0 && this.pickedPlacementRevision === editService.getSessionRevision() &&
      picked.path[0].parentCellId === editService.getCurrentCellId() && editService.getSelectedIds().includes(picked.rootShapeId);
  }

  private confirmLocalInstance(): void {
    if (!this.assertEditMode()) return;
    const path: InstancePathStep[] = this.localInstancePath();
    if (path.length === 0 || path[0].parentCellId !== editService.getTopCellId()) {
      this.panelStore.statusText = '请从顶层点选具体实例成员；只进入 Cell 定义不能确定仅改哪个位置'; return;
    }
    const context: string = this.parameterDialogContext();
    const revision: number = editService.getSessionRevision();
    const pathText: string = this.cellName(path[0].parentCellId) + ' / ' + path.map((step: InstancePathStep): string =>
      `${this.cellName(step.cellId)}#${step.instanceId}[${step.row + 1},${step.col + 1}]`).join(' / ');
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '仅修改这个实例路径',
      message: `${pathText}。创建 ${path.length} 级独立定义，保留其余引用和阵列。此操作可一次撤销。`,
      primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消', action: () => {} }, secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '创建独立定义', action: () => {
        if (context !== this.parameterDialogContext() || revision !== editService.getSessionRevision()) { this.panelStore.statusText = '实例或文档已变化，请重新点选'; return; }
        const result = editService.makePathIndependent(path, this.cellStructureState());
        this.panelStore.statusText = result.message;
        if (result.ok) { this.viewportStore.pickedPlacement = null; this.syncShapesFromEditService(); this.rebuildCellTree(); this.fitAllShapes(); }
      } }
    });
  }

  private enterSharedInstanceDefinition(): void {
    if (this.viewportStore.pickedPlacement === null || !this.validPickedPlacement()) { this.panelStore.statusText = this.sharedCellScopeText(); return; }
    const path: InstancePathStep[] = this.viewportStore.pickedPlacement.path;
    if (!editService.enterInstancePath(path)) { this.panelStore.statusText = '实例路径已变化，请重新点选'; return; }
    this.viewportStore.pickedPlacement = null; this.syncShapesFromEditService(); this.fitAllShapes(); this.panelStore.statusText = this.sharedCellScopeText();
  }

  private confirmExtractArrayMember(): void {
    if (!this.assertEditMode() || this.viewportStore.pickedPlacement === null || !this.validPickedPlacement()) { this.panelStore.statusText = '请重新点选当前选区中的具体阵列成员'; return; }
    const step: InstancePathStep = this.viewportStore.pickedPlacement.path[0];
    const context: string = this.parameterDialogContext();
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '提取单个阵列成员',
      message: `引用 #${step.instanceId} 的成员[${step.row + 1},${step.col + 1}]将成为单个实例，其余成员保留为压缩阵列。Cell 定义仍共享；需要独立几何时再使用“仅改此处”。可一次撤销。`,
      primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消', action: () => {} }, secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '提取成员', action: () => {
        if (context !== this.parameterDialogContext()) { this.panelStore.statusText = '版图已变化，请重新选择成员'; return; }
        const result = editService.extractArrayMember(step.instanceId, step.row, step.col, this.cellStructureState());
        if (result.ok) { this.viewportStore.pickedPlacement = null; this.syncShapesFromEditService(); }
        this.panelStore.statusText = result.message;
      } }
    });
  }

  private parameterDialogContext(): string {
    return `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}:${editService.getCurrentCellId()}:${editService.getSelectedIds().join(',')}:${this.viewportStore.currentViewMode}:${this.docStore.workspaceReady}`;
  }

  /** Display-only bounded expansion. The committed Clip/merge plan retains the
   * complete hierarchy and does not use this preview as geometry input. */
  private filledHierarchyPreview(shapes: Shape[], rootCellId: number, topCellId: number, gridNm: number = cleanDbuNm(this.docStore.docPhysicalUnits)): Shape[] {
    const owned: Shape[] = shapes.map((shape: Shape): Shape => {
      if (shape.ownerCellId !== undefined) return shape;
      const copy: Shape = cloneShapeModel(shape, true) as Shape; copy.ownerCellId = topCellId; return copy;
    });
    const expanded: Shape[] = expandCellShapes(owned, rootCellId, 32, false, undefined, 2000);
    return this.filledPathPreview(expanded, gridNm);
  }

  private filledPathPreview(shapes: Shape[], gridNm: number): Shape[] {
    const adapter: NativeLayerRegionAdapter = new NativeLayerRegionAdapter();
    const output: Shape[] = [];
    for (const shape of shapes) {
      if (shape.type === ShapeType.RECT || shape.type === ShapeType.POLYGON) output.push(shape);
      else if (shape.type === ShapeType.PATH) {
        const result = adapter.shape(shape, gridNm, 1);
        if (!result.ok) throw new Error(`PATH 预览失败：${result.message}`);
        for (const polygon of result.polygons) {
          const points: Point[] = [];
          for (let index: number = 0; index < polygon.length; index += 2) points.push({ x: polygon[index], y: polygon[index + 1] });
          output.push({ id: shape.id, type: ShapeType.POLYGON, layerNumber: shape.layerNumber, datatype: shape.datatype, ownerCellId: shape.ownerCellId, points: points, selected: false });
          if (output.length >= 2000) return output;
        }
      }
      if (output.length >= 2000) return output;
    }
    return output;
  }

  private hierarchyClipInitialBounds(): ShapeBounds {
    const summary: HierarchySummary = summarizeCellShapes(editService.getShapes(), editService.getCurrentCellId(), 32, false);
    const dbu: number = cleanDbuNm(this.docStore.docPhysicalUnits);
    if (summary.bounds === undefined) return { minX: 0, minY: 0, maxX: dbu, maxY: dbu };
    const padding: number = summary.absolutePathPadding;
    const bounds: ShapeBounds = { minX: summary.bounds.minX - padding, minY: summary.bounds.minY - padding,
      maxX: summary.bounds.maxX + padding, maxY: summary.bounds.maxY + padding };
    if (bounds.maxX <= bounds.minX) bounds.maxX = bounds.minX + dbu;
    if (bounds.maxY <= bounds.minY) bounds.maxY = bounds.minY + dbu;
    return bounds;
  }

  private validateParameterDialogContext(openedContext: string): boolean {
    if (!this.assertEditMode()) return false;
    if (openedContext.length === 0 || openedContext !== this.parameterDialogContext()) {
      this.panelStore.statusText = '版图或选区已改变，请重新打开参数窗口';
      return false;
    }
    return true;
  }

  private openArrayCopyDialog(): void {
    if (!this.assertEditMode()) return;
    if (editService.getSelectedIds().length === 0) { this.panelStore.statusText = '请先选择要阵列复制的图形'; return; }
    this.arrayDialogContext = this.parameterDialogContext();
    this.openCanvasDialog(this.arrayCopyController);
  }

  private openSizeOffsetDialog(): void {
    if (!this.assertEditMode()) return;
    if (editService.getSelectedIds().length === 0) { this.panelStore.statusText = '请先选择要调整尺寸的图形'; return; }
    this.sizeDialogContext = this.parameterDialogContext();
    this.openCanvasDialog(this.sizeOffsetController);
  }

  private openPCellDialog(): void {
    if (!this.assertEditMode()) return;
    this.panelStore.curveInitialName = ''; this.panelStore.curveOutputMode = 'instance';
    this.pcellDialogContext = this.parameterDialogContext();
    this.openCanvasDialog(this.placePCellController);
  }

  private openCurveDialog(name: string): void {
    if (!this.assertEditMode()) return;
    this.panelStore.curveInitialName = name; this.panelStore.curveOutputMode = 'polygon';
    this.pcellDialogContext = this.parameterDialogContext(); this.openCanvasDialog(this.placePCellController);
  }

  private applyPlacedPCell(pcellName: string, params: Record<string, number | string | boolean>,
                           x: number, y: number, options?: PCellPlacementOptions, deviceName: string = ''): boolean {
    if (!this.validateParameterDialogContext(this.pcellDialogContext)) return false;
    let identity: PCellVariant | undefined;
    if (deviceName.length > 0) {
      try {
        const device: TechnologyDevicePlacement = technologyService.resolveDevice(deviceName, nativeHongTuService.listPCells(), params);
        if (device.pcell !== pcellName || options?.outputMode === 'polygon') throw new Error('工艺器件与 PCell/实例输出不匹配');
        params = device.parameters;
        identity = { cellId: 0, name: pcellName, params: params, technologyId: device.technologyId,
          technologyVersion: device.technologyVersion, deviceName: device.deviceName, deviceModel: device.model };
      } catch (error) { this.panelStore.statusText = `工艺器件未放置：${String(error)}`; return false; }
    }
    if (options !== undefined) {
      params['datatype'] = options.datatype;
      if (['CIRCLE', 'ELLIPSE', 'DONUT', 'ARC'].includes(pcellName)) params['max_error'] = options.maxErrorNm;
      if (options.outputMode === 'polygon') {
        try {
          if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error('放置坐标须为有限值');
          const prepared: PCellPreparedDefinition = this.preparePCellDefinition(pcellName, params);
          const templates: Shape[] = prepared.shapes;
          const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
          let nextId: number = editService.getNextShapeId();
          const createdIds: number[] = [];
          for (const shape of templates) {
            if (shape.type === ShapeType.INSTANCE) throw new Error('生成结果仍有实例，请使用参数化输出');
            shape.datatype = options.datatype;
            if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error(`L${shape.layerNumber}/D${shape.datatype} 不可编辑`);
            shape.id = nextId++; shape.ownerCellId = editService.getCurrentCellId(); shape.selected = false;
            shape.points = shape.points.map((point: Point): Point => ({ x: Math.round(point.x + x), y: Math.round(point.y + y) }));
            shape.properties = (shape.properties ?? []).map((property: LayoutPropRecord): LayoutPropRecord =>
              property.value.startsWith('HONGTU_PCELL_V1:') ? { attr: property.attr, dtype: property.dtype, name: property.name,
                value: `HONGTU_PCELL_FLAT_SOURCE_V1:${property.value.substring('HONGTU_PCELL_V1:'.length)}` } : property);
            candidate.shapes.push(shape); createdIds.push(shape.id);
          }
          const owner: number = editService.getCurrentCellId();
          const candidatePorts: LayoutPort[] = candidate.ports as LayoutPort[];
          const candidateKeys: string[] = candidate.cellKeys as string[];
          const usedNames: Set<string> = new Set<string>(candidatePorts.filter((port: LayoutPort): boolean => port.ownerCellId === owner).map((port: LayoutPort): string => port.name));
          for (const draft of prepared.ports) {
            if (!editService.canEditLayer(draft.layerNumber, draft.datatype)) throw new Error(`端口 L${draft.layerNumber}/D${draft.datatype} 不可编辑`);
            const baseName: string = `${pcellName}_${createdIds[0]}_${draft.name}`; let unique: string = baseName, suffix: number = 1;
            while (usedNames.has(unique)) unique = `${baseName}_${++suffix}`; usedNames.add(unique);
            const sourceName: string = draft.name;
            draft.name = unique; draft.centerNm = { x: draft.centerNm.x + x, y: draft.centerNm.y + y };
            draft.provenance = JSON.stringify({ kind: 'pcell-flat-snapshot', generator: pcellName, sourceName: sourceName });
            candidatePorts.push(portFromDraft(newLayoutIdentity('port'), owner, candidateKeys[owner], draft));
          }
          workspaceService.cloneValidatedDocument(candidate);
          if (!this.commitCellStructure(candidate, createdIds)) return false;
          if (!this.draftControlStore.stampActive) {
            this.viewportStore.interactiveCurveKind = '';
            this.viewportStore.currentTool = ActiveTool.Select;
          }
          this.syncShapesFromEditService();
          const outLayer: number = templates.length > 0 ? templates[0].layerNumber : this.viewportStore.selectedLayerNumber;
          this.panelStore.statusText = `已绘制 ${pcellName}：${createdIds.length} 个普通图形，L${outLayer}/D${options.datatype}，可一次撤销`; return true;
        } catch (error) { this.panelStore.statusText = `曲线未绘制，原图已保留：${String(error)}`; return false; }
      }
    }
    return this.insertPCell(pcellName, params, x, y, identity);
  }

  /** 放置实例（PlaceInstanceDialog 确认回调，调 EditService.createInstance） */
  private placeableInstanceCells(): CellInfo[] {
    const curCell: number = editService.getCurrentCellId();
    const out: CellInfo[] = [];
    for (let i = 0; i < this.placeableCells.length; i++) {
      const candidate: CellInfo = this.placeableCells[i];
      if (!editService.wouldCreateCellCycle(curCell, candidate.id)) {
        out.push(candidate);
      }
    }
    return out;
  }

  private resolveInitialInstanceCellId(): number {
    const allowed: CellInfo[] = this.placeableInstanceCells();
    if (allowed.length === 0) return -1;
    const isAllowed = (id: number): boolean => id >= 0 && allowed.some((c: CellInfo) => c.id === id);
    if (this.draftControlStore.stampActive && !this.draftControlStore.stampIsPCell && isAllowed(this.pendingStampCellId)) {
      return this.pendingStampCellId;
    }
    if (isAllowed(this.preferredInstanceTargetId)) {
      return this.preferredInstanceTargetId;
    }
    const referenced: Set<number> = new Set<number>();
    const allShapes: Shape[] = editService.getShapes();
    for (let i = 0; i < allShapes.length; i++) {
      if (allShapes[i].type === ShapeType.INSTANCE && allShapes[i].cellId !== undefined) {
        referenced.add(allShapes[i].cellId!);
      }
    }
    const topId: number = editService.getTopCellId();
    for (let i = allowed.length - 1; i >= 0; i--) {
      if (allowed[i].id !== topId && !referenced.has(allowed[i].id)) {
        return allowed[i].id;
      }
    }
    for (let i = allowed.length - 1; i >= 0; i--) {
      if (allowed[i].id !== topId) {
        return allowed[i].id;
      }
    }
    return allowed[allowed.length - 1].id;
  }

  private computeCellBoundingSpan(cellId: number): Point | null {
    if (cellId < 0) return null;
    const all: Shape[] = editService.getShapes();
    const topId: number = editService.getTopCellId();
    let minX: number = Number.POSITIVE_INFINITY;
    let minY: number = Number.POSITIVE_INFINITY;
    let maxX: number = Number.NEGATIVE_INFINITY;
    let maxY: number = Number.NEGATIVE_INFINITY;
    let found: boolean = false;
    for (let i = 0; i < all.length; i++) {
      const s: Shape = all[i];
      if ((s.ownerCellId ?? topId) !== cellId || s.type === ShapeType.NODE || s.points.length === 0) continue;
      const b: ShapeBounds = getShapeBounds(s);
      if (Number.isFinite(b.minX) && Number.isFinite(b.maxX) && Number.isFinite(b.minY) && Number.isFinite(b.maxY)) {
        minX = Math.min(minX, b.minX);
        maxX = Math.max(maxX, b.maxX);
        minY = Math.min(minY, b.minY);
        maxY = Math.max(maxY, b.maxY);
        found = true;
      }
    }
    if (!found || maxX <= minX || maxY <= minY) return null;
    return { x: maxX - minX, y: maxY - minY };
  }

  private openInstanceDialogForCell(cellId: number): void {
    if (!this.assertEditMode()) return;
    if (cellId >= 0) {
      this.preferredInstanceTargetId = cellId;
    }
    this.instanceDialogContext = this.parameterDialogContext();
    this.openCanvasDialog(this.placeInstanceController);
    this.panelStore.statusText = '引用子单元：可选择单个实例 (SREF) 或行列阵列 (AREF)';
  }

  private placeInstance(
    cellId: number,
    x: number,
    y: number,
    rotation: number,
    mirror: number,
    arrayCols: number = 1,
    arrayRows: number = 1,
    pitchX: number = 0,
    pitchY: number = 0
  ): boolean {
    if (!this.validateParameterDialogContext(this.instanceDialogContext)) return false;
    if (!this.hasPlaceableCell(cellId)) {
      this.panelStore.statusText = '当前文档没有可放置的 Cell，请先新建子 Cell';
      return false;
    }
    if (editService.wouldCreateCellCycle(editService.getCurrentCellId(), cellId)) {
      this.panelStore.statusText = '不能放置自身或祖先 Cell（会导致循环层级引用）';
      return false;
    }
    const cellName: string = this.cellName(cellId);
    try {
      const newId: number = editService.createInstance(cellId, x, y, rotation, mirror, cellName, arrayCols, arrayRows, pitchX, pitchY);
      this.preferredInstanceTargetId = cellId;
      if (this.draftControlStore.stampActive && !this.draftControlStore.stampIsPCell) {
        this.pendingStampCellId = cellId;
        this.draftControlStore.stampLabel = cellName;
        this.invalidateStampCache();
      }
      editService.selectShape(newId);
      this.syncShapesFromEditService();
      this.rebuildCellTree();
      this.viewportStore.selectedShapeId = newId;
      const arrDesc: string = (arrayCols > 1 || arrayRows > 1) ? ` 阵列 ${arrayCols}×${arrayRows}` : '';
      this.panelStore.statusText = `已放置${arrDesc}实例 ${cellName} 于 (${x}, ${y}) 旋转 ${rotation}°`;
      if (macroService.isRecording()) {
        this.recordMacroStep(`放置实例 ${cellName}${arrDesc} @(${x},${y}) 旋转${rotation}°`,
          `create_instance|${cellId}|${x}|${y}|${rotation}|${mirror}|${cellName}`);
      }
      return true;
    } catch (error) {
      this.panelStore.statusText = `实例未放置：${String(error)}`;
      return false;
    }
  }

  private openInstanceDialog(): void {
    this.openInstanceDialogForCell(-1);
  }

  private hasPlaceableCell(cellId: number): boolean {
    for (let i = 0; i < this.placeableCells.length; i++) {
      if (this.placeableCells[i].id === cellId) {
        return true;
      }
    }
    return false;
  }

  /** 根据 cellId 查当前文档 Cell 名称 */
  private cellName(cellId: number): string {
    for (let i = 0; i < this.placeableCells.length; i++) {
      if (this.placeableCells[i].id === cellId) {
        return this.placeableCells[i].name;
      }
    }
    return `cell_${cellId}`;
  }

  // ==================== Cell 树 / Cell 管理（对齐 KLayout Cells Tab）====================

  /** 从 INSTANCE 引用关系重建 Cell 层级树 */
  private rebuildCellTree(): void {
    const cellCount: number = this.placeableCells.length;
    if (cellCount === 0) {
      this.docStore.cellTreeData = [];
      this.docStore.currentTopCellId = editService.getCurrentCellId();
      return;
    }
    // parent cellId -> (child cellId -> 实例数)
    const childCounts: Map<number, Map<number, number>> = new Map<number, Map<number, number>>();
    const refTotals: Map<number, number> = new Map<number, number>();
    const all: Shape[] = editService.getShapes();
    const fallbackOwner: number = this.docStore.currentTopCellId;
    for (let i = 0; i < all.length; i++) {
      const s: Shape = all[i];
      if (s.type !== ShapeType.INSTANCE || s.cellId === undefined) {
        continue;
      }
      const child: number = s.cellId;
      if (child < 0 || child >= cellCount) {
        continue;
      }
      const parent: number = s.ownerCellId !== undefined ? s.ownerCellId : fallbackOwner;
      let m: Map<number, number> | undefined = childCounts.get(parent);
      if (m === undefined) {
        m = new Map<number, number>();
        childCounts.set(parent, m);
      }
      m.set(child, (m.get(child) ?? 0) + 1);
      refTotals.set(child, (refTotals.get(child) ?? 0) + 1);
    }
    // 根：未被任何 Cell 引用的候选；循环引用兜底取第一个
    const roots: number[] = [];
    for (let i = 0; i < cellCount; i++) {
      const cid: number = this.placeableCells[i].id;
      if ((refTotals.get(cid) ?? 0) === 0) {
        roots.push(cid);
      }
    }
    if (roots.length === 0) {
      roots.push(this.placeableCells[0].id);
    }
    const tree: CellTreeNode[] = [];
    for (let i = 0; i < roots.length; i++) {
      tree.push(this.buildCellTreeNode(roots[i], 0, `${roots[i]}`, 0, childCounts, [roots[i]]));
    }
    this.docStore.cellTreeData = tree;
    this.docStore.currentTopCellId = editService.getCurrentCellId();
  }

  private buildCellTreeNode(cellId: number, depth: number, path: string, refCount: number,
                            childCounts: Map<number, Map<number, number>>,
                            visiting: number[]): CellTreeNode {
    const node: CellTreeNode = new CellTreeNode(cellId, this.cellName(cellId), refCount, depth, path);
    if (depth >= 8) {
      return node; // 深度上限，防御异常深层级
    }
    const children: Map<number, number> | undefined = childCounts.get(cellId);
    if (children !== undefined) {
      children.forEach((count: number, childId: number) => {
        if (visiting.indexOf(childId) >= 0) {
          return; // 循环引用截断
        }
        node.children.push(
          this.buildCellTreeNode(childId, depth + 1, `${path}/${childId}`, count, childCounts,
            [...visiting, childId]));
      });
    }
    return node;
  }

  private cellNameExists(name: string): boolean {
    for (let i = 0; i < this.placeableCells.length; i++) {
      if (this.placeableCells[i].name === name) {
        return true;
      }
    }
    return false;
  }

  private nextDefaultCellName(): string {
    let n: number = this.placeableCells.length;
    let name: string = `CELL_${n}`;
    while (this.cellNameExists(name)) {
      n++;
      name = `CELL_${n}`;
    }
    return name;
  }

  private openNewCellDialog(): void {
    if (!this.assertEditMode()) return;
    this.cellNameDialogDocumentId = this.docStore.activeWorkspaceId;
    this.cellNameDialogRevision = this.docStore.editorRevision;
    this.cellNameDialogMode = 'new';
    this.panelStore.cellNameDialogTitle = '新建 Cell';
    this.panelStore.cellNameDialogInitial = this.nextDefaultCellName();
    this.openCanvasDialog(this.cellNameController);
  }

  private openRenameCellDialog(cellId: number): void {
    if (!this.assertEditMode()) return;
    if (cellId < 0 || cellId >= this.placeableCells.length) {
      return;
    }
    this.cellNameDialogMode = 'rename';
    this.cellNameDialogDocumentId = this.docStore.activeWorkspaceId;
    this.cellNameDialogRevision = this.docStore.editorRevision;
    this.cellNameDialogTargetId = cellId;
    this.panelStore.cellNameDialogTitle = '重命名 Cell';
    this.panelStore.cellNameDialogInitial = this.cellName(cellId);
    this.openCanvasDialog(this.cellNameController);
  }

  private onCellNameConfirmed(name: string): boolean {
    if (this.cellNameDialogDocumentId !== this.docStore.activeWorkspaceId || this.cellNameDialogRevision !== this.docStore.editorRevision) {
      this.panelStore.statusText = '版图已切换或修改，请重新打开 Cell 命名弹窗';
      return false;
    }
    if (this.cellNameDialogMode === 'new') {
      const ok: boolean = this.createNewCell(name);
      if (ok) {
        const createdId: number = this.placeableCells.length - 1;
        const rootId: number = editService.getTopCellId();
        const rootName: string = this.cellName(rootId);
        if (createdId >= 0) {
          this.enterCellDefinition(createdId);
          this.panelStore.statusText = `已新建并进入子单元 ${name}（空白画布）：画好结构后点左侧「回顶层」即可做实例或阵列引用`;
          showAppSnackBar(this.getUIContext(), `已进入新子单元 ${name}，画完单元后可回顶层 ${rootName} 做阵列引用`, {
            actionText: '回顶层',
            onAction: () => {
              this.enterCellDefinition(rootId);
            }
          });
        }
      }
      return ok;
    }
    if (this.cellNameDialogMode === 'selection') {
      if (!this.assertEditMode()) return false;
      this.finishNudgeTransaction();
      const before: EditStructureState = this.cellStructureState();
      const session: EditSessionState = editService.captureSession();
      try {
        const cell = advEditService.makeCellFromSelection(name, before, this.viewportStore.selectedLayerNumber, this.viewportStore.selectedDatatype);
        if (cell === null) { this.panelStore.statusText = advEditService.getLastGeometryError() || '选区无法组成 Cell，请检查名称、图层锁和当前 Cell'; return false; }
        this.syncShapesFromEditService();
        this.rebuildCellTree();
        const placedCell: CellInfo | undefined = this.placeableCells.find((candidate: CellInfo) => candidate.name === cell.name);
        this.preferredInstanceTargetId = placedCell?.id ?? -1;
        this.panelStore.statusText = `选区已组成 Cell ${cell.name}，原位置保持；可整体撤销`;
        return true;
      } catch (error) {
        editService.restoreSession(session); this.restoreCellStructure(before); this.syncShapesFromEditService();
        this.panelStore.statusText = `选区未组成 Cell，原版图已保留：${String(error)}`;
        return false;
      }
    }
    return this.performRenameCell(this.cellNameDialogTargetId, name);
  }

  private openMakeCellDialog(): void {
    if (!this.assertEditMode() || editService.getSelectedIds().length === 0) return;
    this.cellNameDialogDocumentId = this.docStore.activeWorkspaceId;
    this.cellNameDialogRevision = this.docStore.editorRevision;
    this.cellNameDialogMode = 'selection';
    this.cellNameDialogTargetId = editService.getCurrentCellId();
    this.panelStore.cellNameDialogTitle = '选区组成 Cell';
    this.panelStore.cellNameDialogInitial = this.nextDefaultCellName();
    this.openCanvasDialog(this.cellNameController);
  }

  private canRoundSelectedShape(): boolean {
    const selected: Shape[] = editService.getSelectedShapes();
    return this.viewportStore.currentViewMode === ViewMode.EDIT && selected.length === 1 &&
      (selected[0].type === ShapeType.RECT || selected[0].type === ShapeType.POLYGON) &&
      editService.canEditLayer(selected[0].layerNumber, selected[0].datatype);
  }

  private openRoundCornersDialog(): void {
    if (!this.assertEditMode()) return;
    if (!this.canRoundSelectedShape()) { this.panelStore.statusText = '倒圆角需选择一个未锁定的矩形或多边形'; return; }
    this.openCanvasDialog(this.roundCornersController);
  }

  private previewRoundedCorners(radius: number): boolean {
    if (!this.assertEditMode()) return false;
    if (!this.canRoundSelectedShape()) {
      this.panelStore.statusText = '倒圆角需选择一个未锁定的矩形或多边形'; return false;
    }
    const context: string = this.parameterDialogContext();
    const preview: CornerRoundPreview = advEditService.prepareRoundedCorners(editService.getSelectedIds()[0], radius);
    if (!preview.ok) { this.panelStore.statusText = preview.message; return false; }
    this.panelStore.statusText = `倒圆角参数已校验：半径 ${preview.radius} nm，${preview.points.length} 顶点；原图尚未修改`;
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '确认圆角参数',
      message: `半径 ${preview.radius} nm，最大圆弧近似误差 ${preview.maxErrorNm} nm，生成 ${preview.points.length} 个顶点。原图尚未修改，应用后可撤销。`,
      primaryButton: { value: '取消', fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, action: () => { this.panelStore.statusText = '已取消倒圆角：原图保留'; } },
      secondaryButton: { value: '应用', fontColor: Color.White, backgroundColor: COLORS.primary, action: () => {
        if (context !== this.parameterDialogContext() || !this.assertEditMode() || !advEditService.applyRoundedCorners(preview)) {
          this.panelStore.statusText = '圆角未应用：文档/选择已变化或图形不再可编辑'; return;
        }
        this.syncShapesFromEditService();
        this.panelStore.statusText = `倒圆角完成：半径 ${radius} nm，${preview.points.length} 顶点；可撤销`;
      } } });
    return true;
  }

  private createNewCell(name: string): boolean {
    if (!this.assertEditMode()) return false;
    name = name.trim();
    if (name.length === 0) { this.panelStore.statusText = 'Cell 名称不能为空'; return false; }
    if (this.cellNameExists(name)) {
      this.panelStore.statusText = `Cell 名称 ${name} 已存在`;
      return false;
    }
    try {
      const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
      candidate.cellNames.push(name);
      candidate.cellProperties.push([]);
      appendCellSemantics(candidate);
      if (!this.commitCellStructure(candidate)) return false;
      this.preferredInstanceTargetId = this.placeableCells.length - 1;
    } catch (error) { this.panelStore.statusText = `Cell 新建失败，原版图保留：${String(error)}`; return false; }
    this.panelStore.statusText = `已新建 Cell ${name}（在 Cell 树中双击进入）`;
    return true;
  }

  private performRenameCell(cellId: number, newName: string): boolean {
    if (!this.assertEditMode()) return false;
    if (!Number.isInteger(cellId) || cellId < 0 || cellId >= this.placeableCells.length) {
      this.panelStore.statusText = 'Cell 不存在，请重新选择'; return false;
    }
    newName = newName.trim();
    if (newName.length === 0) { this.panelStore.statusText = 'Cell 名称不能为空'; return false; }
    const oldName: string = this.placeableCells[cellId].name;
    if (newName === oldName) {
      return true;
    }
    if (this.cellNameExists(newName)) {
      this.panelStore.statusText = `Cell 名称 ${newName} 已存在`;
      return false;
    }
    try {
      const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
      candidate.cellNames[cellId] = newName;
      for (const shape of candidate.shapes) {
        if (shape.type === ShapeType.INSTANCE && shape.cellId === cellId) {
          shape.cellName = newName;
        }
      }
      candidate.topCellName = candidate.cellNames[candidate.topCellId];
      if (!this.commitCellStructure(candidate)) return false;
    } catch (error) { this.panelStore.statusText = `Cell 重命名失败，原版图保留：${String(error)}`; return false; }
    this.panelStore.statusText = `Cell ${oldName} 已重命名为 ${newName}`;
    return true;
  }

  private cellStructureState(): EditStructureState {
    return { cellNames: this.propertyCellOptions().map((cell: PropertyCellOption) => cell.name),
      cellProperties: this.docCellProperties, libProperties: this.docLibProperties, topCellId: editService.getTopCellId(),
      cellKeys: this.docCellKeys, ports: this.docPorts, crossSections: this.docCrossSections,
      layoutContextRecords: this.docLayoutContextRecords, cellContextRecords: this.docCellContextRecords,
      cellStack: editService.getCurrentCellStack(), navigationPath: editService.getNavigationPath(),
      userUnits: this.docStore.docUserUnits, physicalUnits: this.docStore.docPhysicalUnits, precision: this.precisionSettings(), layerDefinitions: this.sourceLayerDefinitions,
      layers: cloneUiLayerArray(this.docStore.layers) as UiLayer[] };
  }

  private portDialogContext(): string {
    return `${this.parameterDialogContext()}:${this.viewportStore.currentViewMode}:${this.docStore.activeNativeJobId}:${this.importInProgress}`;
  }
  private openPortManager(): void {
    if (!this.assertEditMode()) return;
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { this.panelStore.statusText = '已有后台作业，请等待完成后打开端口管理'; return; }
    this.pickedPortEndpoint = undefined; this.openCanvasDialog(this.portManagerController);
  }
  private openPortConnect(): void {
    if (!this.assertEditMode()) return;
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { this.panelStore.statusText = '已有后台作业，请等待完成后打开连接对齐'; return; }
    this.openCanvasDialog(this.portConnectController);
  }
  private portChoices(options: PortChoiceQuery = {}): PortUiChoice[] {
    const request: PortChoiceQuery = { scope: options.scope, query: options.query, preferredEndpoint: options.preferredEndpoint ?? this.pickedPortEndpoint };
    const result = collectPortChoices(editService.getShapes(), this.cellStructureState(), this.localInstancePath(), 2000, request);
    this.viewportStore.portProjectionNotice = result.truncated ? '匹配端口最多显示 2000 项或已达路径检索预算；大阵列仅列代表成员。可搜索完整名称、端口 ID 或 #实例ID[行,列]；行列输入仅调整末级引用，其他深层大阵列仍使用代表成员。完整文件与服务数据保留。' : '';
    return result.choices;
  }
  private routeContext(): RouteSessionContext {
    return { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState(), technologyJson: technologyService.serialize() };
  }
  private openPortRoute(): void {
    if (!this.assertEditMode()) return;
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { this.panelStore.statusText = '已有后台作业，请等待完成后打开端口布线'; return; }
    this.finishNudgeTransaction();
    this.openCanvasDialog(this.portRouteController);
  }
  private prepareRouteAction(request: RouteSessionRequest): RouteSessionResult {
    if (!this.assertEditMode()) return { ok: false, message: '查看模式不能布线' };
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) return { ok: false, message: '已有后台作业，请等待完成后布线' };
    return routeSessionService.prepare(this.routeContext(), request);
  }
  private routePreview(id: string): RouteSessionPreview | undefined {
    if (this.viewportStore.currentViewMode !== ViewMode.EDIT || this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { routeSessionService.cancel(id); return undefined; }
    return routeSessionService.getPreview(id, this.routeContext());
  }
  private applyRouteAction(id: string): RouteSessionResult {
    if (!this.assertEditMode()) { routeSessionService.cancel(id); return { ok: false, message: '查看模式不能布线' }; }
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { routeSessionService.cancel(id); return { ok: false, message: '后台作业状态已改变，请重新预览布线' }; }
    const result: RouteSessionResult = routeSessionService.apply(id, this.routeContext());
    this.panelStore.statusText = result.message;
    if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); }
    return result;
  }
  private refreshPortProjection(): void {
    try {
      const result = collectPortChoices(editService.getShapes(), this.cellStructureState(), this.localInstancePath(), 2000, { preferredEndpoint: this.pickedPortEndpoint });
      this.viewportStore.projectedPorts = result.choices.map((choice: PortUiChoice): ResolvedPort => choice.resolved);
      this.viewportStore.portProjectionNotice = result.truncated ? '端口采用有界显示（最多 2000 项；大阵列仅列代表成员）；完整数据保留' : '';
    } catch (error) { this.viewportStore.projectedPorts = []; this.viewportStore.portProjectionNotice = `端口投影失败：${String(error)}`; }
  }
  private preparePortAction(request: PortRequest): PortResult {
    if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改端口' };
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) return { ok: false, message: '已有后台作业，请等待完成后修改端口' };
    return portService.prepare({ documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() }, request);
  }
  private applyPortAction(id: string): PortResult {
    if (!this.assertEditMode()) return { ok: false, message: '查看模式不能修改端口' };
    if (this.docStore.activeNativeJobId.length > 0 || this.importInProgress) { portService.cancel(id); return { ok: false, message: '后台作业状态已改变，请重新预览端口' }; }
    const result: PortResult = portService.apply(id, { documentIdentity: this.docStore.activeWorkspaceId, structure: this.cellStructureState() });
    this.panelStore.statusText = result.message;
    if (result.ok) { this.syncShapesFromEditService(); this.rebuildCellTree(); }
    return result;
  }
  private portPreviewEndpoints(preview: PortPreview): ResolvedPort[] {
    const structure: EditStructureState | undefined = portService.getPreviewStructure(preview.id);
    if (structure === undefined) throw new Error('端口预览已失效');
    if (preview.kind === 'connect') {
      if (preview.movingEndpoint === undefined || preview.targetEndpoint === undefined) throw new Error('候选连接路径缺失');
      return portService.resolvePreviewBatch(preview.id, [preview.movingEndpoint, preview.targetEndpoint]);
    }
    const root: number = structure.cellStack[structure.cellStack.length - 1], keys: string[] = structure.cellKeys ?? [];
    const local: LayoutPort[] = (structure.ports ?? []).filter((port: LayoutPort): boolean => port.ownerCellId === root);
    const affected: Set<string> = new Set<string>(preview.affectedPortIds ?? []);
    const shown: LayoutPort[] = local.filter((port: LayoutPort): boolean => affected.has(port.id))
      .concat(local.filter((port: LayoutPort): boolean => !affected.has(port.id))).slice(0, 2000);
    const endpoints: PortEndpoint[] = shown.map((port: LayoutPort): PortEndpoint =>
      ({ portId: port.id, rootCellId: root, rootCellKey: keys[root], path: [] }));
    return portService.resolvePreviewBatch(preview.id, endpoints);
  }

  private restoreCellStructure(state: EditStructureState): void {
    // Validate both complete process strings before publishing any external
    // metadata; EditService reverts geometry/history if publication fails.
    if (state.technologyJson !== undefined) {
    const currentDeck: string = JSON.stringify({ name: drcService.ruleSourceText(), rules: drcService.getRules() });
    if (state.technologyJson !== technologyService.serialize() ||
      (state.drcConfiguration === undefined && state.drcDeckJson !== undefined && state.drcDeckJson !== currentDeck)) {
      const layers: UiLayer[] = technologyService.restoreDocumentSettings(state.technologyJson, state.drcDeckJson ?? '', state.layers ?? this.docStore.layers);
      this.docStore.layers = layers; this.documentTechnologyJson = technologyService.serialize(); this.currentTechnologyId = technologyService.getActive()?.id ?? '';
      this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false; this.verifyStore.tracedNets = []; this.verifyStore.lvsHasResult = false;
    }
    }
    if (state.drcConfiguration !== undefined && JSON.stringify(state.drcConfiguration) !== JSON.stringify(drcService.captureConfiguration())) {
      drcService.restoreConfiguration(state.drcConfiguration); this.verifyStore.drcIssues = []; this.verifyStore.drcHasRun = false;
    }
    if (state.localProcessOwned !== undefined) this.localProcessOwned = state.localProcessOwned;
    if (state.userUnits !== undefined) this.docStore.docUserUnits = state.userUnits;
    if (state.physicalUnits !== undefined) this.docStore.docPhysicalUnits = state.physicalUnits;
    if (state.layerDefinitions !== undefined) this.sourceLayerDefinitions = state.layerDefinitions;
    if (state.layers !== undefined) this.docStore.layers = cloneUiLayerArray(state.layers) as UiLayer[];
    if (state.precision !== undefined) {
      this.viewportStore.drawStepNm = state.precision.drawStepNm; this.viewportStore.displayGridNm = state.precision.displayGridNm;
      this.viewportStore.geometrySnapEnabled = state.precision.geometrySnapEnabled; this.viewportStore.geometrySnapKinds = state.precision.geometrySnapKinds.slice();
      this.viewportStore.gridSize = this.viewportStore.drawStepNm > 0 ? this.viewportStore.drawStepNm : this.viewportStore.displayGridNm;
      this.viewportStore.snapEnabled = this.viewportStore.drawStepNm > 0; this.viewportStore.vertexSnapEnabled = this.viewportStore.geometrySnapEnabled; this.viewportStore.smartGuidesEnabled = this.viewportStore.geometrySnapEnabled;
    }
    this.placeableCells = state.cellNames.map((name: string, id: number): CellInfo => ({ id: id, name: name }));
    this.docCellProperties = state.cellProperties;
    if (state.cellKeys !== undefined) this.docCellKeys = state.cellKeys.slice();
    if (state.ports !== undefined) this.docPorts = clonePortArray(state.ports)! as LayoutPort[];
    if (state.crossSections !== undefined) this.docCrossSections = cloneCrossSectionArray(state.crossSections)! as LayoutCrossSection[];
    if (state.layoutContextRecords !== undefined) this.docLayoutContextRecords = cloneContextRecordArray(state.layoutContextRecords)! as LayoutContextRecord[];
    if (state.cellContextRecords !== undefined) this.docCellContextRecords = cloneCellContextRecordMatrix(state.cellContextRecords)! as LayoutContextRecord[][];
    if (state.libProperties !== undefined) this.docLibProperties = state.libProperties;
    this.docStore.docCellCount = state.cellNames.length;
    this.docStore.docTopCellName = state.cellNames[state.topCellId];
    advEditService.loadCellsFromImport(state.cellNames, editService.getShapes(), state.topCellId);
    this.readPCellVariants();
    this.rebuildCellTree();
  }

  private commitCellStructure(candidate: WorkspaceDocument, finalSelectedIds?: number[], recordSelectionHistory: boolean = false): boolean {
    let previous: EditSessionState | undefined;
    let before: EditStructureState | undefined;
    try {
      const validated: WorkspaceDocument = workspaceService.cloneValidatedDocument(candidate);
      this.finishNudgeTransaction();
      previous = editService.captureSession();
      before = this.cellStructureState();
      this.captureAutomaticEngineeringOrigin();
      const after: EditStructureState = { cellNames: validated.cellNames, cellProperties: validated.cellProperties,
        cellKeys: validated.cellKeys, ports: validated.ports, crossSections: validated.crossSections,
        layoutContextRecords: validated.layoutContextRecords, cellContextRecords: validated.cellContextRecords,
        libProperties: validated.libProperties, topCellId: validated.topCellId, cellStack: validated.cellStack,
        navigationPath: validated.navigationPath, userUnits: validated.userUnits, physicalUnits: validated.physicalUnits,
        precision: validated.precision, layerDefinitions: validated.layerDefinitions, layers: validated.layers };
      if (!editService.applyDocumentStructure(validated.shapes, before, after, '', recordSelectionHistory || finalSelectedIds !== undefined, finalSelectedIds)) {
        this.panelStore.statusText = 'Cell 操作涉及锁定图层或无效图形，请先解锁后重试';
        return false;
      }
      this.syncShapesFromEditService();
      this.rebuildCellTree();
      return true;
    } catch (error) {
      let restoreError: string = '';
      if (previous !== undefined && before !== undefined) {
        editService.restoreSession(previous);
        try {
          this.restoreCellStructure(before);
          this.syncShapesFromEditService(); this.rebuildCellTree();
        } catch (failure) { restoreError = `；界面刷新失败：${String(failure)}`; }
      }
      this.panelStore.statusText = `Cell 操作失败，原版图保留：${String(error)}${restoreError}`;
      return false;
    }
  }

  private confirmDeleteCell(cellId: number): void {
    if (!this.assertEditMode()) return;
    if (cellId < 0 || cellId >= this.placeableCells.length) {
      return;
    }
    if (this.placeableCells.length <= 1) {
      this.panelStore.statusText = '无法删除最后一个 Cell';
      return;
    }
    const name: string = this.cellName(cellId);
    const all: Shape[] = editService.getShapes();
    let referenced: number = 0;
    let owned: number = 0;
    for (let i = 0; i < all.length; i++) {
      const s: Shape = all[i];
      if (s.type === ShapeType.INSTANCE && s.cellId === cellId) {
        referenced++;
      }
      const owner: number = s.ownerCellId !== undefined ? s.ownerCellId : this.docStore.currentTopCellId;
      if (owner === cellId) {
        owned++;
      }
    }
    if (referenced > 0) {
      this.panelStore.statusText = `Cell ${name} 被引用 ${referenced} 次，请先打平或删除其实例`;
      return;
    }
    const stack: number[] = editService.getCurrentCellStack();
    if (stack.indexOf(cellId) >= 0) {
      this.panelStore.statusText = `正在浏览 Cell ${name}，请先切换到其他 Cell 再删除`;
      return;
    }
    const documentId: string = this.docStore.activeWorkspaceId, revision: number = this.docStore.editorRevision;
    this.canvasFocusReturnTicket++;
    AlertDialog.show({ cornerRadius: UI.dialogRadius,
      title: '删除 Cell',
      message: owned > 0
        ? `Cell ${name} 含 ${owned} 个图形，删除将一并移除，可通过撤销恢复。`
        : `确认删除空 Cell ${name}？可通过撤销恢复。`,
      primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted,
        value: '取消',
        action: () => {}
      },
      secondaryButton: { fontColor: COLORS.danger, backgroundColor: COLORS.dangerSoft,
        value: '删除',
        action: () => {
          if (documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
            this.panelStore.statusText = '版图已切换或修改，请重新确认删除 Cell';
            return;
          }
          this.deleteCellById(cellId);
        }
      }
    });
  }

  /** Cell 定义、归属和引用索引在同一条历史内重排。 */
  private deleteCellById(cellId: number): void {
    if (!this.assertEditMode() || cellId < 0 || cellId >= this.placeableCells.length) return;
    if (this.placeableCells.length <= 1) { this.panelStore.statusText = '无法删除最后一个 Cell'; return; }
    if (editService.getCurrentCellStack().indexOf(cellId) >= 0) { this.panelStore.statusText = '请先切换到其他 Cell 再删除'; return; }
    const name: string = this.cellName(cellId);
    const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
    const all: Shape[] = candidate.shapes;
    if (all.some((shape: Shape): boolean => shape.type === ShapeType.INSTANCE && shape.cellId === cellId)) {
      this.panelStore.statusText = `Cell ${name} 仍被引用，请先打平或删除其实例`; return;
    }
    const remaining: Shape[] = [];
    for (let i = 0; i < all.length; i++) {
      const s: Shape = all[i];
      const owner: number = s.ownerCellId !== undefined ? s.ownerCellId : candidate.topCellId;
      if (owner === cellId) {
        continue; // 该 Cell 拥有的图形一并删除
      }
      if (s.ownerCellId !== undefined && s.ownerCellId > cellId) {
        s.ownerCellId = s.ownerCellId - 1;
      }
      if (s.type === ShapeType.INSTANCE && s.cellId !== undefined && s.cellId > cellId) {
        s.cellId = s.cellId - 1;
      }
      remaining.push(s);
    }
    candidate.shapes = remaining;
    remapCellSemantics(candidate, candidate.cellNames.map((_name: string, id: number): number => id === cellId ? -1 : (id > cellId ? id - 1 : id)));
    candidate.cellNames.splice(cellId, 1);
    candidate.cellProperties.splice(cellId, 1);
    candidate.topCellId -= candidate.topCellId > cellId ? 1 : 0;
    candidate.topCellName = candidate.cellNames[candidate.topCellId];
    candidate.cellStack = candidate.cellStack.map((id: number): number => id > cellId ? id - 1 : id);
    candidate.navigationPath = (candidate.navigationPath ?? []).map((step: InstancePathStep): InstancePathStep => ({
      parentCellId: step.parentCellId > cellId ? step.parentCellId - 1 : step.parentCellId,
      cellId: step.cellId > cellId ? step.cellId - 1 : step.cellId, instanceId: step.instanceId,
      row: step.row, col: step.col, transform: step.transform }));
    candidate.selectedIds = candidate.selectedIds.filter((id: number): boolean => remaining.some((shape: Shape): boolean => shape.id === id));
    candidate.pcells = candidate.pcells.filter((pcell: PCellVariant): boolean => pcell.cellId !== cellId)
      .map((pcell: PCellVariant): PCellVariant => {
        const copy: PCellVariant = cloneStructured(pcell) as PCellVariant;
        copy.cellId = pcell.cellId > cellId ? pcell.cellId - 1 : pcell.cellId; return copy;
      });
    if (this.commitCellStructure(candidate)) this.panelStore.statusText = `已删除 Cell ${name}（可撤销）`;
  }

  // ==================== 打平 / 阵列 / 尺寸 / 布尔（KLayout 编辑对齐）====================

  /** 将图形按矩阵变换为新模板（id=0，owner 由调用方指定） */
  private transformShapeTemplate(src: Shape, m: Mat2D): Shape {
    const pts: Point[] = [];
    let sourcePoints: Point[] = src.points;
    if (src.type === ShapeType.RECT && src.points.length === 2) {
      const a: Point = src.points[0];
      const b: Point = src.points[1];
      sourcePoints = [{ x: a.x, y: a.y }, { x: b.x, y: a.y }, { x: b.x, y: b.y }, { x: a.x, y: b.y }];
    }
    for (let i = 0; i < sourcePoints.length; i++) {
      pts.push({
        x: m.a * sourcePoints[i].x + m.b * sourcePoints[i].y + m.tx,
        y: m.c * sourcePoints[i].x + m.d * sourcePoints[i].y + m.ty,
      });
    }
    const copy: Shape = {
      id: 0,
      type: src.type === ShapeType.RECT ? ShapeType.POLYGON : src.type,
      layerNumber: src.layerNumber,
      datatype: src.datatype,
      points: pts,
      selected: false,
    };
    if (src.pathWidth !== undefined) {
      const det: number = m.a * m.d - m.b * m.c;
      const scale: number = Math.sqrt(Math.abs(det));
      copy.pathWidth = src.pathWidthAbsolute ? src.pathWidth : src.pathWidth * scale;
      copy.pathBeginExtension = (src.pathBeginExtension ?? 0) * scale;
      copy.pathEndExtension = (src.pathEndExtension ?? 0) * scale;
      copy.pathWidthAbsolute = src.pathWidthAbsolute;
    }
    // 端型不按矩阵缩放，但必须随粘贴一起保留，否则贴出来的 PATH 一律变 flush
    if (src.pathType !== undefined && src.pathType > 0) {
      copy.pathType = src.pathType;
    }
    if (src.text !== undefined) {
      copy.text = src.text;
      copy.textPresentation = src.textPresentation;
      const determinant: number = m.a * m.d - m.b * m.c;
      const parentAngle: number = Math.atan2(m.c, m.a) * 180 / Math.PI;
      const childAngle: number = (src.rotation ?? 0) + (src.mirror === 2 ? 180 : 0);
      copy.rotation = parentAngle + (determinant < 0 ? -childAngle : childAngle);
      copy.mirror = (determinant < 0) !== ((src.mirror ?? 0) !== 0) ? 1 : 0;
      copy.magnification = (src.magnification ?? 1) * Math.sqrt(Math.abs(determinant));
    }
    if (src.properties !== undefined) {
      copy.properties = src.properties.map((prop: LayoutPropRecord): LayoutPropRecord => ({
        attr: prop.attr, name: prop.name, value: prop.value, dtype: prop.dtype,
      }));
    }
    return copy;
  }

  /**
   * 组合父实例与子实例的 GDS 变换字段：mag 相乘、mirror 异或、
   * 角度按父镜像取正/反向叠加、原点经父矩阵映射。
   */
  private composeInstanceTemplate(parent: Shape, child: Shape, parentMat: Mat2D): Shape {
    const pMag: number = (parent.magnification !== undefined && parent.magnification > 0) ? parent.magnification : 1;
    const cMag: number = (child.magnification !== undefined && child.magnification > 0) ? child.magnification : 1;
    const pMirror: boolean = (parent.mirror ?? 0) !== 0;
    const cMirror: boolean = (child.mirror ?? 0) !== 0;
    const pRot: number = (parent.rotation ?? 0) + (parent.mirror === 2 ? 180 : 0);
    const cRot: number = (child.rotation ?? 0) + (child.mirror === 2 ? 180 : 0);
    const ox: number = child.points.length > 0 ? child.points[0].x : 0;
    const oy: number = child.points.length > 0 ? child.points[0].y : 0;
    let rot: number = pMirror ? (pRot - cRot) : (pRot + cRot);
    rot = ((rot % 360) + 360) % 360;
    const copy: Shape = {
      id: 0,
      type: ShapeType.INSTANCE,
      layerNumber: child.layerNumber,
      datatype: child.datatype,
      points: [{
        x: parentMat.a * ox + parentMat.b * oy + parentMat.tx,
        y: parentMat.c * ox + parentMat.d * oy + parentMat.ty,
      }],
      selected: false,
    };
    copy.cellId = child.cellId;
    copy.cellName = child.cellName;
    copy.rotation = rot;
    copy.mirror = (pMirror !== cMirror) ? 1 : 0;
    copy.magnification = pMag * cMag;
    copy.arrayCols = child.arrayCols;
    copy.arrayRows = child.arrayRows;
    copy.arrayColStepX = parentMat.a * (child.arrayColStepX ?? 0) + parentMat.b * (child.arrayColStepY ?? 0);
    copy.arrayColStepY = parentMat.c * (child.arrayColStepX ?? 0) + parentMat.d * (child.arrayColStepY ?? 0);
    copy.arrayRowStepX = parentMat.a * (child.arrayRowStepX ?? 0) + parentMat.b * (child.arrayRowStepY ?? 0);
    copy.arrayRowStepY = parentMat.c * (child.arrayRowStepX ?? 0) + parentMat.d * (child.arrayRowStepY ?? 0);
    if (child.properties !== undefined) {
      copy.properties = child.properties.map((prop: LayoutPropRecord): LayoutPropRecord => ({
        attr: prop.attr, name: prop.name, value: prop.value, dtype: prop.dtype,
      }));
    }
    return copy;
  }

  /** Prepare the complete one-level candidate before asking to commit it. */
  private confirmFlattenInstances(ids: number[], scope: string): void {
    if (!this.assertEditMode()) return;
    const prepared = flattenPreviewService.prepare(this.workspaceDocument(), ids);
    if (!prepared.ok || prepared.preview === undefined) { this.panelStore.statusText = prepared.message; return; }
    const preview = prepared.preview;
    const estimate = preview.estimate;
    this.canvasFocusReturnTicket++;
    this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '展开实例预览',
      message: `${scope}。删除 ${estimate.removedObjects} 条引用，${estimate.arrayMembers} 个阵列成员将生成 ${estimate.createdObjects} 个对象；工程合计 ${estimate.resultingObjects} 个对象、${estimate.resultingPoints} 个顶点。仅展开一级，保留 ${estimate.nestedInstances} 条子实例引用。原参数化意图不再跟随复制的图形；可一次撤销。${estimate.warnings.join('；')}`,
      primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消', action: () => {} }, secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '展开为对象', action: () => {
        if (!this.assertEditMode()) return;
        const applied = flattenPreviewService.apply(preview, this.workspaceDocument(), this.cellStructureState());
        if (applied.ok) { this.viewportStore.pickedPlacement = null; this.syncShapesFromEditService(); this.rebuildCellTree(); }
        this.panelStore.statusText = applied.message;
      } }
    });
  }

  /** Selected references only; a Cell-tree action explicitly chooses all referring parents. */
  private flattenSelectedInstance(): void {
    const selected: Shape[] = editService.getSelectedShapes().filter((s: Shape): boolean => s.type === ShapeType.INSTANCE);
    if (selected.length === 0) { this.panelStore.statusText = '请选择实例后展开；普通图形无需转换'; return; }
    this.confirmFlattenInstances(selected.map((s: Shape): number => s.id), '当前选中的实例');
  }

  private flattenCellInstances(cellId: number): void {
    const references: Shape[] = editService.getShapes().filter((s: Shape): boolean => s.type === ShapeType.INSTANCE && s.cellId === cellId);
    if (references.length === 0) { this.panelStore.statusText = `Cell ${this.cellName(cellId)} 没有引用，无需展开`; return; }
    const parents: Set<number> = new Set<number>(references.map((s: Shape): number => s.ownerCellId ?? editService.getTopCellId()));
    this.confirmFlattenInstances(references.map((s: Shape): number => s.id),
      `全部 ${references.length} 条 ${this.cellName(cellId)} 引用，涉及 ${parents.size} 个父 Cell`);
  }

  /**
   * 生成并放置 PCell：native 生成几何 → 新建变体 Cell → 图形入 Cell →
   * 在当前 Cell 放置实例（单批撤销覆盖图形与实例；变体 Cell 记录保留，
   * 可在 Cell 树删除）。
   */
  private insertPCell(pcellName: string, params: Record<string, number | string | boolean>,
                      x: number, y: number, identity?: PCellVariant): boolean {
    if (!this.assertEditMode()) return false;
    try {
      const document: WorkspaceDocument = incrementalSnapshotEngine.cloneWorkspaceDocument(this.workspaceDocument()) as WorkspaceDocument;
      const prepared: PCellPreparedDefinition = this.preparePCellDefinition(pcellName, params, identity);
      document.shapes = prepared.shapes;
      document.shapes.forEach((shape: Shape, index: number) => { shape.id = index + 1; shape.ownerCellId = 0; });
      document.cellNames = [`${pcellName}_1`]; document.topCellId = 0; document.topCellName = document.cellNames[0];
      document.cellProperties = [[]]; document.libProperties = []; document.cellStack = [0]; document.navigationPath = []; document.selectedIds = [];
      document.cellKeys = [newLayoutIdentity()]; document.ports = []; document.crossSections = [];
      document.layoutContextRecords = []; document.cellContextRecords = [[]];
      reconcileGeneratedPorts(document, 0, prepared.ports);
      document.pcells = [{ cellId: 0, name: pcellName, params: params,
        technologyId: identity?.technologyId, technologyVersion: identity?.technologyVersion,
        deviceName: identity?.deviceName, deviceModel: identity?.deviceModel }]; document.rulers = [];
      return this.insertLibraryEntry({ id: 'generated-pcell', title: pcellName, category: 'PCell', createdAt: Date.now(),
        pcellName: pcellName, params: params, document: document }, x, y);
    } catch (error) { this.panelStore.statusText = `PCell 未放置：${String(error)}`; return false; }
  }

  private preparePCellTemplates(name: string, params: Record<string, number | string | boolean>, identity?: PCellVariant): Shape[] {
    return this.preparePCellDefinition(name, params, identity).shapes;
  }

  private preparePCellDefinition(name: string, params: Record<string, number | string | boolean>, identity?: PCellVariant): PCellPreparedDefinition {
    workspaceService.validateParameters(params);
    if (name.length === 0 || name.length > 128) throw new Error('PCell 名称无效');
    const generated = nativeHongTuService.generatePCell(name, params);
    if (!generated.success) throw new Error(generated.errorMessage);
    const templates: Shape[] = nativeShapesToShapes(generated.shapes);
    if (templates.length === 0) throw new Error('PCell 生成结果为空，请检查参数');
    const json: string = JSON.stringify({ name: name, params: params,
      technologyId: identity?.technologyId, technologyVersion: identity?.technologyVersion,
      deviceName: identity?.deviceName, deviceModel: identity?.deviceModel });
    let ascii: string = '';
    for (let i = 0; i < json.length; i++) {
      const code: number = json.charCodeAt(i);
      ascii += code > 126 ? `\\u${code.toString(16).padStart(4, '0')}` : json[i];
    }
    const marker: string = `HONGTU_PCELL_V1:${ascii}`;
    if (marker.length > 65530) throw new Error('PCell 参数超过 GDS 属性容量');
    const properties: LayoutPropRecord[] = (templates[0].properties ?? []).filter((p: LayoutPropRecord) =>
      !p.value.startsWith('HONGTU_PCELL_V1:'));
    if (properties.length >= 64) throw new Error('PCell 首图形没有可用属性位置');
    properties.push({ attr: 126, dtype: 6, name: '', value: marker });
    templates[0].properties = properties;
    const ports: LayoutPortDraft[] = [];
    for (const port of generated.ports) {
      const draft: LayoutPortDraft = { name: port.name, centerNm: { x: port.centerNm.x, y: port.centerNm.y },
        orientationDeg: port.orientationDeg, widthNm: port.widthNm, layerNumber: port.layerNumber, datatype: port.datatype,
        portType: port.portType, frameMirror: port.frameMirror, frameMagnification: port.frameMagnification,
        crossSectionKey: port.crossSectionKey, crossSectionVersion: port.crossSectionVersion, infoJson: port.infoJson, provenance: port.provenance };
      ports.push(draft);
    }
    return { shapes: templates, ports: ports };
  }

  private readPCellVariants(): void {
    this.pcellVariants = this.collectPCellVariants(editService.getShapes(), editService.getTopCellId());
  }

  private selectedPCellVariant(): PCellVariant | undefined {
    this.readPCellVariants();
    const selected: Shape | undefined = editService.getShapes().find((s: Shape) => s.id === editService.getSelectedId());
    const cellId: number = selected?.type === ShapeType.INSTANCE ? (selected.cellId ?? -1) :
      (selected?.ownerCellId ?? editService.getCurrentCellId());
    return this.pcellVariants.find((variant: PCellVariant) => variant.cellId === cellId);
  }

  private openPCellEditor(): void {
    if (!this.assertEditMode()) return;
    const variant: PCellVariant | undefined = this.selectedPCellVariant();
    if (variant === undefined) { this.panelStore.statusText = '请选中带参数记录的 PCell 实例，或进入其 Cell'; return; }
    this.pcellEditCellId = variant.cellId; this.docStore.pcellEditName = variant.name;
    this.pcellEditDocumentId = this.docStore.activeWorkspaceId;
    this.pcellEditRevision = this.docStore.editorRevision;
    this.pcellEditContextCellId = editService.getCurrentCellId();
    this.pcellEditParams = cloneStructured(variant.params) as Record<string, number | string | boolean>;
    this.openCanvasDialog(this.pcellEditController);
  }

  private regenerateSelectedPCell(params: Record<string, number | string | boolean>): string {
    if (!this.assertEditMode()) return '当前文档不可编辑';
    if (this.pcellEditDocumentId !== this.docStore.activeWorkspaceId || this.pcellEditRevision !== this.docStore.editorRevision ||
        this.pcellEditContextCellId !== editService.getCurrentCellId()) return '版图已切换或修改，请重新打开器件参数';
    try {
      this.readPCellVariants();
      const variant: PCellVariant | undefined = this.pcellVariants.find((p: PCellVariant) => p.cellId === this.pcellEditCellId && p.name === this.docStore.pcellEditName);
      if (variant === undefined) return '该 PCell 已改变，请重新打开参数面板';
      const prepared: PCellPreparedDefinition = this.preparePCellDefinition(variant.name, params, variant);
      const templates: Shape[] = prepared.shapes;
      // A moved definition keeps its coordinate system when its generator is rerun.
      // Cell-owned origin metadata survives shared references, history and formats.
      const origin: CellOriginOffset = readCellOriginOffset(this.docCellProperties[variant.cellId]);
      for (const shape of templates) shape.points = shape.points.map((point: Point): Point => ({ x: point.x - origin.xNm, y: point.y - origin.yNm }));
      for (const port of prepared.ports) port.centerNm = { x: port.centerNm.x - origin.xNm, y: port.centerNm.y - origin.yNm };
      const candidate: WorkspaceDocument = incrementalSnapshotEngine.cloneWorkspaceDocument(this.workspaceDocument()) as WorkspaceDocument;
      let nextId: number = 1;
      for (const shape of candidate.shapes) nextId = Math.max(nextId, shape.id + 1);
      candidate.shapes = candidate.shapes.filter((s: Shape) => (s.ownerCellId ?? candidate.topCellId) !== variant.cellId);
      for (const shape of templates) { shape.id = nextId++; shape.ownerCellId = variant.cellId; candidate.shapes.push(shape); }
      candidate.selectedIds = candidate.selectedIds.filter((id: number) => candidate.shapes.some((s: Shape) => s.id === id));
      reconcileGeneratedPorts(candidate, variant.cellId, prepared.ports);
      if (!this.commitCellStructure(candidate, undefined, true)) return this.panelStore.statusText;
      this.setNativeSnapshotCurrent(false);
      this.readPCellVariants(); this.syncShapesFromEditService(); this.rebuildCellTree();
      this.panelStore.statusText = `已更新 ${this.cellName(variant.cellId)} 参数；引用该 Cell 的全部实例同时更新，可一次撤销`;
      return '';
    } catch (error) { return `PCell 未更新：${String(error)}`; }
  }

  private async addPCellToLibrary(title: string, category: string): Promise<void> {
    try {
      const variant: PCellVariant | undefined = this.selectedPCellVariant();
      if (variant === undefined) throw new Error('请先选择 PCell 实例');
      let identity: PCellProcessIdentity | undefined;
      if (variant.technologyId !== undefined) identity = { technologyId: variant.technologyId,
        technologyVersion: variant.technologyVersion ?? '', deviceName: variant.deviceName ?? '', deviceModel: variant.deviceModel ?? '' };
      await componentLibraryService.add(title, category, variant.name, variant.params, undefined, identity);
      this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.statusText = `已保存 PCell 预设：${title}`;
    } catch (error) { this.panelStore.statusText = `预设未保存：${String(error)}`; }
  }

  private async addCellToLibrary(title: string, category: string): Promise<void> {
    try {
      const document: WorkspaceDocument = this.cloneDocumentSubset(this.workspaceDocument(), editService.getCurrentCellId());
      await componentLibraryService.add(title, category, '', {}, document);
      this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.statusText = `已保存当前 Cell 及 ${document.cellNames.length - 1} 个依赖 Cell`;
    } catch (error) { this.panelStore.statusText = `器件未保存：${String(error)}`; }
  }

  /** Keep root selection only when supplied; referenced child Cells retain their complete contents. */
  private cloneDocumentSubset(source: WorkspaceDocument, rootCellId: number, rootShapeIds?: number[]): WorkspaceDocument {
    const document: WorkspaceDocument = workspaceService.cloneValidatedDocument(source);
    if (!Number.isInteger(rootCellId) || rootCellId < 0 || rootCellId >= document.cellNames.length) throw new Error('导出 Cell 无效');
    const selected: Set<number> | undefined = rootShapeIds === undefined ? undefined : new Set<number>(rootShapeIds);
    const sourceRootKey: string = (document.cellKeys as string[])[rootCellId];
    const byCell: Map<number, Shape[]> = new Map<number, Shape[]>();
    for (const shape of document.shapes) {
      const owner: number = shape.ownerCellId ?? document.topCellId;
      if (owner === rootCellId && selected !== undefined && !selected.has(shape.id)) continue;
      let local: Shape[] | undefined = byCell.get(owner);
      if (local === undefined) { local = []; byCell.set(owner, local); }
      local.push(shape);
    }
    if (selected !== undefined && (byCell.get(rootCellId)?.length ?? 0) !== selected.size) throw new Error('选区含非当前 Cell 或失效对象');
    const order: number[] = [rootCellId]; const remap: Map<number, number> = new Map<number, number>(); remap.set(rootCellId, 0);
    for (let i = 0; i < order.length; i++) {
      for (const shape of byCell.get(order[i]) ?? []) {
        if (shape.type !== ShapeType.INSTANCE || shape.cellId === undefined || remap.has(shape.cellId)) continue;
        remap.set(shape.cellId, order.length); order.push(shape.cellId);
      }
    }
    const names: string[] = order.map((id: number) => document.cellNames[id]);
    const properties: LayoutPropRecord[][] = order.map((id: number) => document.cellProperties[id] ?? []);
    if (selected !== undefined) properties[0] = properties[0].map((property: LayoutPropRecord): LayoutPropRecord =>
      property.value.startsWith('HONGTU_PCELL_V1:') ? { attr: property.attr, dtype: property.dtype, name: property.name,
        value: `HONGTU_PCELL_SUBSET_SOURCE_V1:${property.value.substring('HONGTU_PCELL_V1:'.length)}` } : property);
    const shapes: Shape[] = [];
    for (let i = 0; i < order.length; i++) {
      for (const shape of byCell.get(order[i]) ?? []) {
        if (selected !== undefined && order[i] === rootCellId) {
          // A partial root is static. Preserve the complete source metadata as
          // provenance instead of allowing readPCellVariants to reactivate it.
          shape.properties = (shape.properties ?? []).map((property: LayoutPropRecord): LayoutPropRecord =>
            property.value.startsWith('HONGTU_PCELL_V1:') ? { attr: property.attr, dtype: property.dtype, name: property.name,
              value: `HONGTU_PCELL_SUBSET_SOURCE_V1:${property.value.substring('HONGTU_PCELL_V1:'.length)}` } : property);
        }
        shape.id = shapes.length + 1; shape.ownerCellId = i; shape.selected = false;
        if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
          shape.cellId = remap.get(shape.cellId) as number; shape.cellName = names[shape.cellId];
        }
        shapes.push(shape);
      }
    }
    document.pcells = document.pcells.filter((p: PCellVariant) => remap.has(p.cellId) &&
      !(selected !== undefined && p.cellId === rootCellId)).map((p: PCellVariant): PCellVariant => {
        p.cellId = remap.get(p.cellId) as number; return p;
      });
    if (selected !== undefined) document.ports = (document.ports as LayoutPort[]).filter((port: LayoutPort): boolean => port.ownerCellId !== rootCellId);
    remapCellSemantics(document, document.cellNames.map((_name: string, id: number): number => remap.get(id) ?? -1));
    const copiedKeys: string[] = (document.cellKeys as string[]).map((): string => newLayoutIdentity());
    document.cellKeys = copiedKeys;
    document.ports = (document.ports as LayoutPort[]).map((port: LayoutPort): LayoutPort => {
      port.id = newLayoutIdentity('port'); port.ownerCellKey = copiedKeys[port.ownerCellId]; return port;
    });
    if (selected !== undefined) markCellLineage(document, 0, 'subset-static', sourceRootKey);
    document.id = workspaceService.newId(); document.cellNames = names; document.cellProperties = properties;
    document.topCellId = 0; document.topCellName = names[0]; document.title = names[0]; document.shapes = shapes;
    document.cellStack = [0]; document.navigationPath = []; document.selectedIds = []; document.rulers = [];
    document.sourcePath = ''; document.saveUri = ''; document.projectUri = ''; document.dirty = true;
    return workspaceService.cloneValidatedDocument(document);
  }

  private insertLibraryEntry(entry: ComponentLibraryEntry, x: number = 0, y: number = 0): boolean {
    if (!this.assertEditMode()) return false;
    if (entry.document === undefined) {
      const identity: PCellVariant | undefined = entry.pcellIdentity === undefined ? undefined : {
        cellId: -1, name: entry.pcellName, params: entry.params,
        technologyId: entry.pcellIdentity.technologyId, technologyVersion: entry.pcellIdentity.technologyVersion,
        deviceName: entry.pcellIdentity.deviceName, deviceModel: entry.pcellIdentity.deviceModel };
      return this.insertPCell(entry.pcellName, entry.params, x, y, identity);
    }
    let previous: EditSessionState | undefined;
    const oldStructure: EditStructureState = this.cellStructureState();
    const oldLayers: UiLayer[] = this.docStore.layers.slice();
    try {
      if (!Number.isFinite(x) || !Number.isFinite(y)) throw new Error('放置坐标无效');
      const incoming: WorkspaceDocument = this.cloneDocumentSubset(entry.document, entry.document.topCellId);
      const candidate: WorkspaceDocument = workspaceService.cloneValidatedDocument(this.workspaceDocument());
      const offset: number = candidate.cellNames.length; const used: Set<string> = new Set<string>(candidate.cellNames);
      candidate.layerDefinitions = (candidate.layerDefinitions ?? []).concat(incoming.layerDefinitions ?? []);
      for (const name of incoming.cellNames) {
        let unique: string = name; let suffix: number = 1;
        while (used.has(unique)) unique = `${name.slice(0, 480)}_${++suffix}`;
        used.add(unique); candidate.cellNames.push(unique);
      }
      candidate.cellProperties = candidate.cellProperties.concat(incoming.cellProperties);
      mergeLayoutSemantics(candidate, incoming, incoming.cellNames.map((_name: string, id: number): number => offset + id));
      for (const property of incoming.libProperties) {
        if (!candidate.libProperties.some((p: LayoutPropRecord) => p.attr === property.attr && p.dtype === property.dtype &&
          p.name === property.name && p.value === property.value)) candidate.libProperties.push(property);
      }
      const preparedSession: EditSessionState = editService.captureSession();
      let nextId: number = preparedSession.nextId;
      for (const shape of candidate.shapes) nextId = Math.max(nextId, shape.id + 1);
      const templates: Shape[] = incoming.shapes;
      for (const port of incoming.ports ?? []) {
        if (!editService.canEditLayer(port.layerNumber, port.datatype)) throw new Error(`端口 L${port.layerNumber}/D${port.datatype} 已锁定`);
      }
      for (const shape of templates) {
        if (!editService.canEditLayer(shape.layerNumber, shape.datatype)) throw new Error(`L${shape.layerNumber}/D${shape.datatype} 已锁定`);
        shape.id = nextId++; shape.ownerCellId = offset + (shape.ownerCellId ?? incoming.topCellId);
        if (shape.type === ShapeType.INSTANCE && shape.cellId !== undefined) {
          shape.cellId += offset; shape.cellName = candidate.cellNames[shape.cellId];
        }
        candidate.shapes.push(shape);
      }
      if (!editService.canEditLayer(0, 0)) throw new Error('实例所在 L0/D0 已锁定');
      candidate.shapes.push({ id: nextId, type: ShapeType.INSTANCE, points: [{ x: x, y: y }], layerNumber: 0, datatype: 0,
        selected: false, ownerCellId: editService.getCurrentCellId(), cellId: offset, cellName: candidate.cellNames[offset],
        rotation: 0, mirror: 0, magnification: 1 });
      for (const layer of incoming.layers) {
        if (!candidate.layers.some((item: UiLayer) => item.layerNumber === layer.layerNumber && item.datatype === layer.datatype)) {
          if (layer.locked === true && (templates.some((shape: Shape) => shape.layerNumber === layer.layerNumber && shape.datatype === layer.datatype) ||
            (incoming.ports ?? []).some((port: LayoutPort): boolean => port.layerNumber === layer.layerNumber && port.datatype === layer.datatype) ||
            (layer.layerNumber === 0 && layer.datatype === 0))) throw new Error(`器件的 L${layer.layerNumber}/D${layer.datatype} 已锁定`);
          candidate.layers.push(layer);
        }
      }
      workspaceService.cloneValidatedDocument(candidate); // Validate combined hierarchy/AREF budget before the first mutation.
      previous = preparedSession;
      if (!this.commitCellStructure(candidate, [nextId])) throw new Error(this.panelStore.statusText);
      this.setNativeSnapshotCurrent(false); this.readPCellVariants();
      this.syncShapesFromEditService(); this.rebuildCellTree();
      this.panelStore.statusText = `已放置 ${entry.title}（${incoming.cellNames.length} 个 Cell，${templates.length} 个图形，可一次撤销）`;
      return true;
    } catch (error) {
      let restoreError: string = '';
      if (previous !== undefined) {
        editService.restoreSession(previous); this.docStore.layers = oldLayers;
        try {
          this.restoreCellStructure(oldStructure); this.syncShapesFromEditService(); this.rebuildCellTree();
        } catch (failure) { restoreError = `；界面刷新失败：${String(failure)}`; }
      }
      this.panelStore.statusText = `器件未放置：${String(error)}${restoreError}`; return false;
    }
  }

  private async removeLibraryEntry(id: string): Promise<void> {
    try { await componentLibraryService.remove(id); this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.statusText = '已移除器件库条目'; }
    catch (error) { this.panelStore.statusText = `移除失败：${String(error)}`; }
  }

  private async importComponentLibrary(): Promise<void> {
    this.canvasFocusReturnTicket++;
    try {
      await componentLibraryService.importWithPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.statusText = `器件库已导入，共 ${this.docStore.libraryEntries.length} 项`;
    } catch (error) {
      const reason: string = String(error).replace(/^Error:\s*/, '');
      this.panelStore.statusText = reason === '已取消导入器件库' ? reason : `器件库未导入：${reason}`;
    }
  }

  private async exportComponentLibrary(): Promise<void> {
    this.canvasFocusReturnTicket++;
    try {
      await componentLibraryService.exportWithPicker(this.getUIContext().getHostContext() as common.UIAbilityContext);
      this.panelStore.statusText = '器件库已导出';
    } catch (error) {
      const reason: string = String(error).replace(/^Error:\s*/, '');
      this.panelStore.statusText = reason === '已取消导出器件库' ? reason : `器件库未导出：${reason}`;
    }
  }

  private applyArrayCopy(rows: number, cols: number, pitchX: number, pitchY: number): boolean {
    if (!this.validateParameterDialogContext(this.arrayDialogContext)) return false;
    try {
      const created: number = advEditService.arraySelection(rows, cols, pitchX, pitchY);
      if (created > 0) {
        this.syncShapesFromEditService();
        this.panelStore.statusText = `阵列复制完成：${rows}×${cols}，新增 ${created} 个图形`;
        return true;
      }
      this.panelStore.statusText = advEditService.getLastGeometryError() || '阵列复制未执行：请先选中图形，且行×列需大于 1×1';
    } catch (error) { this.panelStore.statusText = `阵列复制未执行：${String(error)}`; }
    return false;
  }

  private applySizeOffset(offset: number): boolean {
    if (!this.validateParameterDialogContext(this.sizeDialogContext)) return false;
    try {
      const ok: boolean = advEditService.sizeSelection(offset, this.cellStructureState());
      if (ok) {
        this.syncShapesFromEditService();
        this.panelStore.statusText = `尺寸调整完成：各边偏移 ${offset} nm`;
        return true;
      }
      this.panelStore.statusText = advEditService.getLastGeometryError() || '尺寸调整未执行：请先选中图形';
    } catch (error) { this.panelStore.statusText = `尺寸调整未执行：${String(error)}`; }
    return false;
  }

  private applyBooleanOp(op: 'merge' | 'subtract' | 'intersect' | 'xor'): void {
    if (!this.assertEditMode()) {
      return;
    }
    this.pendingBooleanOp = op;
    this.openCanvasDialog(this.booleanPreviewController);
  }

  private workbenchCommands(): WorkbenchCommand[] {
    const selected: Shape[] = editService.getSelectedShapes();
    const editable: boolean = this.docStore.workspaceReady && this.viewportStore.currentViewMode === ViewMode.EDIT;
    const editableSelection: boolean = selected.length > 0 && selected.every((shape: Shape) => editService.canEditLayer(shape.layerNumber, shape.datatype));
    const booleanReady: boolean = selected.length === 2 && selected.every((shape: Shape) => shape.type === ShapeType.RECT || shape.type === ShapeType.POLYGON);
    const commands: WorkbenchCommand[] = [];
    const add = (id: string, title: string, aliases: string, shortcut: string, enabled: boolean, reason: string, nextStep: string): void => {
      commands.push({ id: id, title: title, aliases: aliases, shortcut: shortcut, enabled: enabled, reason: reason, nextStep: nextStep });
    };
    const editReason: string = !editable ? '当前为查看模式或文档尚未就绪' : '选区为空或包含锁定图层';
    add('open', '打开版图', '文件 GDS OASIS 导入', 'Ctrl+O', true, '', '选择文件后检查格式和资源预算');
    add('recent', '最近打开的版图', '历史 文件 最近打开', '', true, '', '查看真实最近文件列表');
    add('viewPreset', '保存视图预设', '图层 可见性 保存 预设', '', true, '', '保存当前图层可见性');
    add('viewWorkspace', '视图与书签', 'view clone bookmark 多视图 克隆 书签 定位', '', this.docStore.workspaceReady, '文档尚未就绪', '共享当前版图，独立保存位置、Cell 和图层显隐');
    add('rdbReview', 'RDB 报告审阅', 'marker lyrdb 报告 标记 分类 Cell 豁免 评论', '', true, '', '打开报告、筛选标记并保存审阅记录');
    add('compare', '版图比较', 'compare diff XOR 差异 比较', '', this.docStore.workspaceReady, '文档尚未就绪', '选择比较来源、参数并检查差异与范围');
    add('save', '保存版图', '文件 GDS OASIS 导出 存盘', 'Ctrl+S', true, '', '保存前检查 DBU 量化偏差');
    add('project', '工程与恢复', '打包 迁移 版本 草稿 异常恢复', '', true, '', '保存工程或恢复为独立副本');
    add('search', '查找图形与批量属性', '搜索 查询 选区 结果转选择 批量编辑', 'Ctrl+F', true, '', '筛选后选择当前 Cell 的匹配项');
    add('undo', '撤销', '回退 历史', 'Ctrl+Z', editable && editService.canUndo(), editable ? '没有可撤销操作' : editReason, '批量操作可一次撤回');
    add('redo', '重做', '历史 重新应用', 'Ctrl+Shift+Z', editable && editService.canRedo(), editable ? '没有可重做操作' : editReason, '恢复上次撤销的操作');
    add('copy', '复制', 'copy 选区 剪贴板', 'Ctrl+C', selected.length > 0, '未选中图形，无法复制', '复制当前选区到内部剪贴板');
    add('paste', '粘贴', 'paste 剪贴板', 'Ctrl+V', editable, this.docStore.workspaceReady ? '查看模式不可编辑，请先切换到编辑模式' : '正在恢复工作区，请稍候再编辑', '粘贴剪贴板图形并选中新对象，可一次撤销');
    add('properties', '批量属性', '坐标 位置 尺寸 图层 datatype 修改', '', editable && editableSelection, editReason, '选择可编辑对象后打开属性面板');
    add('array', '阵列复制', '重复 网格 排列', '', editable && editableSelection, editReason, '输入行列数和二维步向量');
    add('flatten', '展开选中实例', '打平 转图形 PCell 布尔 转换', '', editable && editableSelection && selected.some((shape: Shape) => shape.type === ShapeType.INSTANCE), '需要选择可编辑实例', '先查看展开后对象数量');
    add('independent', '仅改此处', '变体 单成员 阵列 局部 实例 独立', '', editable && this.localInstancePath().length > 0, '尚未点选一个具体实例成员', '从命中对象条点选成员后隔离当前路径');
    add('size', '尺寸调整', '膨胀 收缩 偏移 offset', '', editable && editableSelection, editReason, '输入偏移 nm，提交前检查图形类型');
    add('roundCorners', '倒圆角', '圆角 fillet 半径 corner', '', this.canRoundSelectedShape(), '需要一个可编辑的矩形或多边形', '填写半径并核对圆弧误差');
    add('makeCell', '选区组成 Cell', '编组 分组 group 新单元 层级', '', editable && editableSelection, editReason, '输入新 Cell 名称，保持版图原位置');
    add('boolean', '布尔预览', '相减 A减B B减A 合并 相交 异或 输出层', '', editable && booleanReady, '需要恰好选择两个矩形或普通多边形', '预览 A/B、输出层与保留原图');
    add('layerExpression', '全层表达式', '派生层 region 全层 合并 相减 相交 异或 datatype', '', editable, editReason, '读取当前 Cell 的全层几何，预览后输出到指定层');
    add('hierarchyClip', '层级 Clip', '裁剪 clip 截取 层级 新建 Cell 保留引用', '', editable, editReason, '填写 nm 范围，预览后新建裁剪 Cell');
    add('hierarchyFill', '区域 Fill', 'fill 填充 阵列 避让 区域 孔洞 dummy', '', editable, editReason, '选择填充 Cell、真实区域和排列，预览后一次应用');
    add('cellMaintenance', 'Cell 库维护', '原点 origin 重链接 relink 清理 prune 库维护', '', editable, editReason, '预览原点补偿、引用替换或不可达定义清理');
    add('portManager', '端口管理', 'port ports 端口 定义 镜像 方向 width CrossSection', '', editable && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress, editable ? '已有后台作业' : editReason, '编辑 Cell 端口或复制具体实例端口，预览后应用');
    add('portConnect', '端口连接对齐', 'connect 端口 连接 对齐 阵列 单成员 optical electrical', '', editable && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress, editable ? '已有后台作业' : editReason, '选择两个具体端点，检查兼容性后移动一个实例');
    add('portRoute', '端口布线', 'route routing 电气 布线 束线 避障 长度匹配 渐变 过孔', '', editable && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress, editable ? '已有后台作业' : editReason, '明确配对，检查真实材料避障和中心线长度后新增多边形');
    add('importMerge', '合并导入', '文件 GDSII OASIS CIF DXF 映射 merge 层 Cell', '', editable && this.docStore.activeNativeJobId.length === 0 && !this.importInProgress, editable ? '已有后台导入或检查作业' : editReason, '隔离读取文件，映射层和 Cell 后合并到当前文档');
    add('pcell', '放置参数化器件', 'PCell 参数 实例 器件库', '', editable, editReason, '参数化实例可再次修改参数');
    add('circle', '画圆', 'CIRCLE 圆形 多边形 曲线', '', editable, editReason, '填写半径、图层与近似误差');
    add('ellipse', '画椭圆', 'ELLIPSE 半轴 多边形 曲线', '', editable, editReason, '填写两半轴与近似误差');
    add('donut', '画圆环', 'DONUT 环形 曲线 孔洞', '', editable, editReason, '填写内外半径');
    add('arc', '画圆弧', 'ARC 弧形 曲线', '', editable, editReason, '填写内外半径与角度');
    add('library', '个人器件库', '库 快照 依赖 复用', '', true, '', '导入或打包 Cell 与参数化意图');
    add('technology', '工艺管理', 'PDK layer datatype 规则 工艺包', '', true, '', '查看实际图层与规则来源');
    add('verify', '工艺 DRC / LVS', '验证 规则 检查 signoff', '', true, '', '选择规则、输入版本和范围');
    add('drc', '运行内置 DRC', '设计规则 间距 线宽 检查', '', this.shapes.length > 0, '当前文档没有图形', '检查当前 Cell 与展开层级范围');
    add('fit', '适配视图', '居中 全图 缩放', '', this.shapes.length > 0 || this.docPorts.length > 0, '当前文档没有图形或端口', '显示当前 Cell 的全部内容');
    add('ai', 'AI 助手', '自然语言 自动绘图 对话', '', true, '', '审阅步骤后应用到当前文档');
    add('python', 'Python 脚本', 'pya klayout 生成 运行 扫参', '', true, '', '明确新建、当前文档或选区范围');
    add('shortcuts', '快捷键设置', '键盘 助记码 profile 冲突', '', true, '', '显示当前实际绑定');
    return commands;
  }

  private executeWorkbenchCommand(id: string): boolean {
    const command: WorkbenchCommand | undefined = this.workbenchCommands().find((item: WorkbenchCommand) => item.id === id);
    if (command === undefined || !command.enabled) { this.panelStore.statusText = command?.reason ?? '命令不可用'; return false; }
    switch (id) {
      case 'open': this.pickAndParseFile(); break;
      case 'recent': this.panelStore.showFilePanel = true; break;
      case 'viewPreset': this.presetSaveContext = this.parameterDialogContext(); this.openCanvasDialog(this.presetSaveController); break;
      case 'save': this.saveCurrentLayout(); break;
      case 'project': this.docStore.workspaceHistory = workspaceService.listHistory(this.docStore.activeWorkspaceId); this.panelStore.showProjectPanel = true; break;
      case 'search': this.panelStore.showSearchPanel = true; break;
      case 'undo': this.undoEdit(); break;
      case 'redo': this.redoEdit(); break;
      case 'copy': this.copySelection(); break;
      case 'paste': this.pasteFromClipboard(); break;
      case 'properties': this.showInspectorPanel(); break;
      case 'array': this.openArrayCopyDialog(); break;
      case 'flatten': this.flattenSelectedInstance(); break;
      case 'independent': {
        this.confirmLocalInstance(); break;
      }
      case 'size': this.openSizeOffsetDialog(); break;
      case 'roundCorners': this.openRoundCornersDialog(); break;
      case 'makeCell': this.openMakeCellDialog(); break;
      case 'boolean': this.applyBooleanOp('subtract'); break;
      case 'layerExpression': this.openCanvasDialog(this.layerExpressionController); break;
      case 'hierarchyClip': this.openCanvasDialog(this.hierarchyClipController); break;
      case 'hierarchyFill': this.openCanvasDialog(this.hierarchyFillController); break;
      case 'cellMaintenance': this.openCanvasDialog(this.cellMaintenanceController); break;
      case 'portManager': this.openPortManager(); break;
      case 'portConnect': this.openPortConnect(); break;
      case 'portRoute': this.openPortRoute(); break;
      case 'importMerge': this.openCanvasDialog(this.importMergeController); break;
      case 'pcell': this.openPCellDialog(); break;
      case 'circle': this.openCurveDialog('CIRCLE'); break;
      case 'ellipse': this.openCurveDialog('ELLIPSE'); break;
      case 'donut': this.openCurveDialog('DONUT'); break;
      case 'arc': this.openCurveDialog('ARC'); break;
      case 'library': this.docStore.libraryEntries = componentLibraryService.list(); this.panelStore.showLibraryPanel = true; break;
      case 'technology': this.panelStore.showTechnologyPanel = true; break;
      case 'verify': this.panelStore.showVerificationPanel = true; break;
      case 'drc': this.runDrcBackground(); break;
      case 'fit': this.fitAllShapes(); break;
      case 'ai': this.returnToAiPanel(); break;
      case 'python': this.openPythonPanel(false); break;
      case 'viewWorkspace': this.openViewWorkspace(); break;
      case 'rdbReview': this.openRdbReview(); break;
      case 'compare': this.panelStore.showComparePanel = true; break;
      case 'shortcuts': this.panelStore.showShortcutPanel = true; break;
      default: return false;
    }
    return true;
  }

  /** 重置视图（右键菜单触发：层级恢复2级 + 缩放100% + 居中） */
  private resetView(): void {
    viewService.resetView();
    this.viewportStore.zoomPercent = viewService.getViewZoomPercent();
    const offset = viewService.getViewOffset();
    this.viewportStore.viewOffsetX = offset.offsetX;
    this.viewportStore.viewOffsetY = offset.offsetY;
    // Fit includes the full port aperture, including cells without geometry.
    if (this.shapes.length > 0 || this.docPorts.length > 0) {
      this.fitAllShapes();
      this.panelStore.statusText = `视图已重置（层级2级）；${this.panelStore.statusText}`;
    } else {
      this.panelStore.statusText = '视图已重置（层级2级，缩放100%）；当前 Cell 没有图形或端口';
    }
  }

  /** 切换到移动工具（工具栏/右键菜单触发） */
  private toggleGridSnapQuick(): void {
    this.viewportStore.snapEnabled = !this.viewportStore.snapEnabled;
    if (this.viewportStore.snapEnabled && this.viewportStore.drawStepNm <= 0) {
      this.viewportStore.drawStepNm = Math.max(1, this.viewportStore.gridSize);
    }
    this.panelStore.statusText = this.viewportStore.snapEnabled
      ? `网格吸附已开启（步长 ${this.viewportStore.drawStepNm} nm）`
      : '网格吸附已关闭';
  }

  private toggleGeometrySnapQuick(): void {
    const next: boolean = !this.viewportStore.geometrySnapEnabled;
    this.viewportStore.geometrySnapEnabled = next;
    this.viewportStore.vertexSnapEnabled = next;
    this.viewportStore.smartGuidesEnabled = next;
    this.panelStore.statusText = next
      ? '几何靶标磁吸与智能十字对齐线已开启'
      : '几何靶标磁吸与智能对齐线已关闭';
  }

  private cycleRoutingModeQuick(): void {
    const next: RoutingMode = routingConstraintService.nextMode(this.viewportStore.routingMode);
    this.viewportStore.routingMode = next;
    this.panelStore.statusText = `走线角度约束：${routingConstraintService.modeLabel(next)}`;
  }

  private activateInteractiveCurve(kind: string): void {
    if (!this.assertEditMode()) return;
    this.viewportStore.interactiveCurveKind = kind;
    if (kind.length > 0) {
      this.panelStore.statusText = `画布拖拽${routingConstraintService.curveKindLabel(kind)}：按下磁吸定圆心，拖动定半径（顶部浮条可输精确参数）`;
    }
  }

  private toggleTouchLoupeQuick(): void {
    this.viewportStore.touchLoupeEnabled = !this.viewportStore.touchLoupeEnabled;
    this.panelStore.statusText = this.viewportStore.touchLoupeEnabled
      ? '触屏指尖放大镜已开启'
      : '触屏指尖放大镜已关闭';
  }

  private switchToMoveTool(): void {
    this.exitStampSession();
    this.viewportStore.interactiveCurveKind = '';
    this.viewportStore.currentTool = ActiveTool.Move;
    this.panelStore.statusText = this.viewportStore.selectedShapeId >= 0
      ? '已切换到移动工具：拖选区沿导轨磁吸平移，原地长按可精确输入位移'
      : '已切换到移动工具：直接按住任意图形即可磁吸平移（长按可微调）';
  }

  private toggleMultiSelectAdditiveQuick(): void {
    this.viewportStore.multiSelectAdditive = !this.viewportStore.multiSelectAdditive;
    this.panelStore.statusText = this.viewportStore.multiSelectAdditive
      ? '已开启免键盘「加选」模式：点选或框选将累加/反选多个图形'
      : '已关闭「加选」模式：单次点选切换单个目标';
  }

  private unlockAndShowLayer(layerNumber: number, datatype: number): void {
    const next: UiLayer[] = [];
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const layer: UiLayer = this.docStore.layers[i];
      if (layer.layerNumber === layerNumber && layer.datatype === datatype) {
        const cloned: UiLayer = cloneLayerWithVisible(layer, true);
        cloned.locked = false;
        cloned.selectable = true;
        next.push(cloned);
      } else {
        next.push(layer);
      }
    }
    this.docStore.layers = next;
    this.syncLayerVisibilityMirror();
    editService.refreshLayerAccess();
    this.panelStore.statusText = `已解锁并显示图层 L${layerNumber}/D${datatype}，现在可直接绘制`;
  }

  private duplicateSelection(): void {
    if (!this.assertEditMode()) return;
    if (this.viewportStore.selectedShapeId < 0 && editService.getSelectedIds().length === 0) {
      this.panelStore.statusText = '请先选中要复制的图形';
      return;
    }
    const stepBase: number = this.viewportStore.drawStepNm > 0 ? this.viewportStore.drawStepNm : this.viewportStore.gridSize;
    const offset: number = Math.max(20, Math.round(stepBase * 2));
    const created: Shape[] = editService.duplicateSelection(offset, offset);
    if (created.length === 0) {
      this.panelStore.statusText = '偏移复制未执行：请检查目标图层是否已锁定';
      return;
    }
    this.viewportStore.selectedShapeId = created[created.length - 1].id;
    this.syncShapesFromEditService();
    this.panelStore.statusText = `已偏移复制 ${created.length} 个图形 (+${offset}, +${offset} nm，不影响剪贴板)`;
  }

  private commitContinuedPathShape(shapeId: number, points: Point[], width: number, pathType: number): boolean {
    if (!this.assertEditMode()) return false;
    const target: Shape | undefined = editService.getShapes().find((s: Shape): boolean => s.id === shapeId);
    if (target === undefined || target.type !== ShapeType.PATH || !editService.canEditLayer(target.layerNumber, target.datatype)) {
      return this.createPathShape(points, width, pathType);
    }
    editService.beginBatch();
    let ok: boolean = false;
    try {
      ok = editService.updateShapePoints(shapeId, points);
      if (ok && target.pathWidth !== width) {
        editService.updateProperties([shapeId], 'width', String(width), this.propertyCellOptions());
      }
    } finally {
      editService.endBatch();
    }
    if (!ok) {
      this.panelStore.statusText = '续画路径更新失败';
      return false;
    }
    editService.selectShape(shapeId);
    this.syncShapesFromEditService();
    this.viewportStore.selectedShapeId = shapeId;
    this.panelStore.statusText = `已续接更新路径 #${shapeId}（共 ${points.length} 顶点，一步撤销）`;
    return true;
  }

  private invalidateStampCache(): void {
    this.cachedStampKey = '';
  }

  private exitStampSession(backToSelect: boolean = false): void {
    if (this.draftControlStore.stampActive) {
      this.draftControlStore.resetStamp();
      this.pendingStampCellId = -1;
      this.pendingStampPCellName = '';
      this.cachedStampKey = '';
      this.cachedStampOutlines = [];
      this.cachedStampPorts = [];
      draftCanvasEngine.stampPreview = null;
      draftCanvasEngine.requestRepaint();
    }
    if (backToSelect && this.viewportStore.currentTool === ActiveTool.Instance) {
      this.viewportStore.currentTool = ActiveTool.Select;
      this.panelStore.statusText = '已退出点放模式';
    }
  }

  private activateInstanceToolSmart(): void {
    if (!this.assertEditMode()) return;
    const preferredId: number = this.resolveInitialInstanceCellId();
    if (preferredId >= 0) {
      if (this.startCellStampSession(preferredId, this.draftControlStore.stampRotation, this.draftControlStore.stampMirror)) {
        return;
      }
    }
    const allowed: CellInfo[] = this.placeableInstanceCells();
    for (let i = allowed.length - 1; i >= 0; i--) {
      if (this.startCellStampSession(allowed[i].id, this.draftControlStore.stampRotation, this.draftControlStore.stampMirror)) {
        return;
      }
    }
    // 当前仅有顶层 Cell（尚无子 Cell 可实例化）：直接打开参数化器件弹窗供点放器件！
    this.openPCellDialog();
    this.panelStore.statusText = '当前仅有顶层 Cell，已为您打开参数化器件库（选好参数点「画布磁吸点放」即可落位）';
  }

  private startCellStampSession(cellId: number, rotation: number, mirror: number): boolean {
    if (!this.assertEditMode()) return false;
    if (!this.hasPlaceableCell(cellId) || editService.wouldCreateCellCycle(editService.getCurrentCellId(), cellId)) {
      this.panelStore.statusText = '不能将当前正在编辑的 Cell 自身或祖先作为实例放入（会产生循环引用）';
      return false;
    }
    this.viewportStore.interactiveCurveKind = '';
    this.pendingStampCellId = cellId;
    this.preferredInstanceTargetId = cellId;
    this.pendingStampPCellName = '';
    this.draftControlStore.stampIsPCell = false;
    this.draftControlStore.stampLabel = this.cellName(cellId);
    this.draftControlStore.stampRotation = ((rotation % 360) + 360) % 360;
    this.draftControlStore.stampMirror = mirror;
    this.draftControlStore.stampActive = true;
    this.invalidateStampCache();
    this.viewportStore.currentTool = ActiveTool.Instance;
    this.panelStore.statusText = `画布点放实例 ${this.draftControlStore.stampLabel}：移动瞄准磁吸点，松手/单击落位（按 R 旋转 90°，Esc 退出）`;
    return true;
  }

  private startPCellStampSession(
    pcellName: string,
    params: Record<string, number | string | boolean>,
    options: PCellPlacementOptions,
    deviceName: string
  ): boolean {
    if (!this.assertEditMode()) return false;
    try {
      let checkParams: Record<string, number | string | boolean> = params;
      if (deviceName.length > 0) {
        const dev: TechnologyDevicePlacement = technologyService.resolveDevice(deviceName, nativeHongTuService.listPCells(), params);
        checkParams = dev.parameters;
      }
      this.preparePCellDefinition(pcellName, checkParams);
    } catch (e) {
      this.panelStore.statusText = `器件参数无法生成轮廓：${String(e)}`;
      return false;
    }
    this.viewportStore.interactiveCurveKind = '';
    this.pendingStampCellId = -1;
    this.pendingStampPCellName = pcellName;
    this.pendingStampPCellParams = params;
    this.pendingStampPCellOptions = options;
    this.pendingStampPCellDevice = deviceName;
    this.draftControlStore.stampIsPCell = true;
    this.draftControlStore.stampLabel = deviceName.length > 0 ? deviceName : pcellName;
    this.draftControlStore.stampRotation = 0;
    this.draftControlStore.stampMirror = 0;
    this.draftControlStore.stampActive = true;
    this.invalidateStampCache();
    this.viewportStore.currentTool = ActiveTool.Instance;
    this.panelStore.statusText = `画布点放器件 ${this.draftControlStore.stampLabel}：磁吸瞄准后单击/松手即可生成落位`;
    return true;
  }

  private transformLocalStampPoint(pt: Point, rotationDeg: number, mirror: number): Point {
    let x: number = pt.x;
    let y: number = pt.y;
    if (mirror === 1) {
      y = -y;
    } else if (mirror === 2) {
      x = -x;
    }
    const rad: number = (rotationDeg * Math.PI) / 180;
    const c: number = Math.cos(rad);
    const s: number = Math.sin(rad);
    return {
      x: Math.round(x * c - y * s),
      y: Math.round(x * s + y * c),
    };
  }

  private provideStampTemplate(): DraftStampTemplate {
    const key: string = `${this.docStore.activeWorkspaceId}:${this.docStore.editorRevision}:${this.draftControlStore.stampIsPCell}:` +
      `${this.pendingStampCellId}:${this.pendingStampPCellName}:${this.draftControlStore.stampRotation}:${this.draftControlStore.stampMirror}`;
    if (key === this.cachedStampKey) {
      return { outlines: this.cachedStampOutlines, ports: this.cachedStampPorts };
    }
    const outlines: DraftGhostOutline[] = [];
    const ports: Point[] = [];
    const rot: number = this.draftControlStore.stampIsPCell ? 0 : this.draftControlStore.stampRotation;
    const mir: number = this.draftControlStore.stampIsPCell ? 0 : this.draftControlStore.stampMirror;

    try {
      let sourceShapes: Shape[] = [];
      if (this.draftControlStore.stampIsPCell && this.pendingStampPCellName.length > 0) {
        const prepared: PCellPreparedDefinition = this.preparePCellDefinition(this.pendingStampPCellName, this.pendingStampPCellParams);
        sourceShapes = prepared.shapes;
        for (let i = 0; i < prepared.ports.length; i++) {
          ports.push(this.transformLocalStampPoint(prepared.ports[i].centerNm, rot, mir));
        }
      } else if (this.pendingStampCellId >= 0) {
        sourceShapes = expandCellShapes(this.shapes, this.pendingStampCellId, 4, false, undefined, 160);
        for (let i = 0; i < this.docPorts.length; i++) {
          if (this.docPorts[i].ownerCellId === this.pendingStampCellId) {
            const centerPt: Point = { x: this.docPorts[i].centerNm.x, y: this.docPorts[i].centerNm.y };
            ports.push(this.transformLocalStampPoint(centerPt, rot, mir));
          }
        }
      }

      for (let i = 0; i < sourceShapes.length && outlines.length < 96; i++) {
        const s: Shape = sourceShapes[i];
        if (s.type === ShapeType.NODE || s.points.length === 0) continue;
        const col: string = this.layerColorForDisplay(s.layerNumber, s.datatype);
        if (s.type === ShapeType.RECT && s.points.length === 2) {
          const b: ShapeBounds = getShapeBounds(s);
          const rawCorners: Point[] = [
            { x: b.minX, y: b.minY },
            { x: b.maxX, y: b.minY },
            { x: b.maxX, y: b.maxY },
            { x: b.minX, y: b.maxY },
          ];
          const corners: Point[] = rawCorners.map((p: Point): Point => this.transformLocalStampPoint(p, rot, mir));
          outlines.push({ closed: true, points: corners, color: col });
        } else if (s.type === ShapeType.POLYGON || s.type === ShapeType.PATH) {
          outlines.push({
            closed: s.type === ShapeType.POLYGON,
            points: s.points.map((p: Point): Point => this.transformLocalStampPoint(p, rot, mir)),
            color: col,
          });
        }
      }
    } catch (_err) {}

    if (outlines.length === 0) {
      const fallbackHalf: number = Math.max(40, this.viewportStore.gridSize * 4);
      outlines.push({
        closed: true,
        points: [
          { x: -fallbackHalf, y: -fallbackHalf },
          { x: fallbackHalf, y: -fallbackHalf },
          { x: fallbackHalf, y: fallbackHalf },
          { x: -fallbackHalf, y: fallbackHalf },
        ],
        color: COLORS.primary,
      });
    }
    this.cachedStampKey = key;
    this.cachedStampOutlines = outlines;
    this.cachedStampPorts = ports;
    return { outlines: outlines, ports: ports };
  }

  private layerColorForDisplay(layerNumber: number, datatype: number): string {
    for (let i = 0; i < this.docStore.layers.length; i++) {
      if (this.docStore.layers[i].layerNumber === layerNumber && this.docStore.layers[i].datatype === datatype) {
        return this.docStore.layers[i].color;
      }
    }
    return COLORS.primary;
  }

  private commitCanvasStampAt(x: number, y: number): boolean {
    if (!this.assertEditMode()) return false;
    if (this.draftControlStore.stampIsPCell && this.pendingStampPCellName.length > 0) {
      this.pcellDialogContext = this.parameterDialogContext();
      return this.applyPlacedPCell(
        this.pendingStampPCellName,
        this.pendingStampPCellParams,
        x,
        y,
        this.pendingStampPCellOptions,
        this.pendingStampPCellDevice
      );
    }
    if (this.pendingStampCellId >= 0) {
      this.instanceDialogContext = this.parameterDialogContext();
      return this.placeInstance(
        this.pendingStampCellId,
        x,
        y,
        this.draftControlStore.stampRotation,
        this.draftControlStore.stampMirror
      );
    }
    return false;
  }

  /** 列表按共享定义导航；保留工程 Top，避免把列表跳转追加为实例层级。 */
  private enterCellDefinition(cellId: number): boolean {
    if (!Number.isInteger(cellId) || cellId < 0 || cellId >= this.placeableCells.length ||
      !editService.navigateToCellDefinition(cellId)) {
      this.panelStore.statusText = `无法进入无效 Cell #${cellId}`;
      return false;
    }
    if (cellId !== editService.getTopCellId()) {
      this.preferredInstanceTargetId = cellId;
    }
    this.docStore.currentTopCellId = editService.getCurrentCellId();
    this.syncShapesFromEditService();
    this.fitAllShapes();
    if (this.viewWorkspaceInitialized) {
      this.persistViewWorkspacePresentation();
    }
    const depth: number = editService.getCurrentCellStack().length;
    this.panelStore.statusText = depth > 1
      ? `已进入 Cell ${this.cellName(cellId)} 的共享定义（面包屑可返回顶层）`
      : `已切换到独立 Cell ${this.cellName(cellId)}`;
    return true;
  }

  /** 进入子 Cell 编辑上下文（双击实例或右键菜单触发） */
  private enterCell(cellId: number): void {
    if (cellId < 0 || cellId >= this.placeableCells.length) {
      this.panelStore.statusText = `无法进入无效 Cell #${cellId}`;
      return;
    }
    editService.enterCell(cellId);
    // 进入子 Cell 后刷新画布（面包屑由 LayoutCanvasView 根据 cellStackDepth 自动显示）
    this.syncShapesFromEditService();
    this.fitAllShapes();
    this.panelStore.statusText = `已进入子 Cell ${this.cellName(cellId)}（面包屑可返回顶层）`;
  }

  private navigateCellStack(stackIndex: number): void {
    const stack: number[] = editService.getCurrentCellStack();
    if (stackIndex < 0 || stackIndex >= stack.length) {
      return;
    }
    editService.navigateToStackIndex(stackIndex);
    this.syncShapesFromEditService();
    this.fitAllShapes();
    const cellId: number = editService.getCurrentCellId();
    this.panelStore.statusText = stackIndex === 0
      ? `已返回顶层 Cell ${this.cellName(cellId)}`
      : `已返回 Cell ${this.cellName(cellId)}`;
  }

  /** 右键菜单"进入子 Cell"：以当前选中实例的 cellId 进入 */
  private enterSelectedInstanceCell(): void {
    const shapes: Shape[] = editService.getShapes();
    const sel: Shape | undefined = shapes.find((s: Shape) => s.id === this.viewportStore.selectedShapeId);
    if (sel === undefined) {
      this.panelStore.statusText = '未找到选中图形，无法进入子 Cell';
      return;
    }
    if (sel.type !== ShapeType.INSTANCE || sel.cellId === undefined) {
      this.panelStore.statusText = '选中图形不是实例，无法进入子 Cell（请选中 INSTANCE 图形）';
      return;
    }
    this.enterCell(sel.cellId);
  }

  /** 导出完成后弹出支持 SaveButton 免权限存图库、复制位置与系统分享的光感完成框。 */
  private showExportLocation(format: string, fileName: string, uri: string): void {
    try {
      this.canvasFocusReturnTicket++;
      this.lastExportFormat = format;
      this.lastExportFileName = fileName;
      this.lastExportUri = uri;
      this.openCanvasDialog(this.exportCompletionController);
    } catch (_error) {
      // 文件已保存。原生反馈异常不得把已完成的导出改报失败。
      showAppToast(this.getUIContext(), '文件已导出；保存位置暂时无法显示', AppToastDuration.NORMAL);
    }
  }

  @Builder
  private buildExternalDropOverlay() {
    Stack() {
      Column({ space: 10 }) {
        Row() {
          WorkbenchIcon({ name: 'open', iconSize: 28, color: COLORS.primary })
        }
        .width(56)
        .height(56)
        .borderRadius(Radius.lg)
        .backgroundColor(COLORS.primarySoft)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        Text('松手导入到鸿图工作台')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)

        Text('支持版图 (.gds / .oas / .cif / .dxf)、图层属性 (.lyp) 与 DRC 报告 (.lyrdb)')
          .fontSize(12)
          .fontColor(COLORS.muted)
          .textAlign(TextAlign.Center)
      }
      .padding({ left: 28, right: 28, top: 24, bottom: 24 })
      .constraintSize({ maxWidth: 420 })
      .attributeModifier(this.themeState.luminousFloatingModifier(Radius.xl, 'thick', this.themeState.elevation('overlay')))
      .border({ width: 1.5, color: COLORS.primary })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('rgba(15, 20, 27, 0.24)')
    .zIndex(ZIndexTokens.modalUtilityPanel)
    .hitTestBehavior(HitTestMode.None)
    .opacity(0.96)
  }

  private onPendingCardCommandChanged(): void {
    this.consumePendingCardCommand();
  }

  private onPendingExternalUriChanged(): void {
    this.consumePendingExternalUri();
  }

  private parsePendingCardToken(token: string): ParsedPendingCardCommand {
    const trimmed: string = token.trim();
    if (trimmed.startsWith('{')) {
      try {
        const obj: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
        const rawCmd: Object | undefined = obj['command'] ?? obj['cardCommand'];
        const rawDoc: Object | undefined = obj['documentId'];
        return {
          command: typeof rawCmd === 'string' ? rawCmd.trim() : '',
          documentId: typeof rawDoc === 'string' ? rawDoc.trim() : ''
        };
      } catch (_err) {
      }
    }
    const colon: number = trimmed.indexOf(':');
    const command: string = colon >= 0 ? trimmed.substring(0, colon).trim() : trimmed;
    return { command: command, documentId: '' };
  }

  private consumePendingCardCommand(): void {
    if (!this.pageAlive || !this.docStore.workspaceReady) {
      return;
    }
    const token: string = this.pendingCardCommand;
    if (token.length === 0 || token === this.handledCardCommandToken) {
      return;
    }
    this.handledCardCommandToken = token;
    const parsed: ParsedPendingCardCommand = this.parsePendingCardToken(token);
    const command: string = parsed.command;
    const targetDocId: string = parsed.documentId;

    if (targetDocId.length > 0 && targetDocId !== this.docStore.activeWorkspaceId && this.workspaceDocuments.has(targetDocId)) {
      this.switchWorkspaceDocument(targetDocId);
    }

    if (command === 'resume') {
      if (this.viewportStore.currentModule !== WorkModule.Layout) {
        this.selectModule(WorkModule.Layout, '版图');
      }
      return;
    }

    if (command === 'runDrc') {
      if (targetDocId.length > 0 && targetDocId !== this.docStore.activeWorkspaceId) {
        showAppSnackBar(this.getUIContext(), '卡片关联的版图未在当前工作区打开，请先切换对应版图后再运行 DRC', {
          duration: AppToastDuration.NORMAL
        });
        return;
      }
      if (this.shapes.length > 0) {
        if (this.viewportStore.currentModule === WorkModule.Data) {
          this.selectModule(WorkModule.Layout, '版图');
        }
        this.runDrcBackground();
      } else {
        showAppSnackBar(this.getUIContext(), '当前尚无版图图形，请先打开版图再运行 DRC', {
          duration: AppToastDuration.NORMAL
        });
      }
    } else if (command === 'openPicker') {
      if (this.viewportStore.currentModule === WorkModule.Data) {
        this.selectModule(WorkModule.Layout, '版图');
      }
      this.pickAndParseFile();
    }
  }

  private parsePendingExternalUriToken(token: string): ParsedPendingExternalUri {
    const trimmed: string = token.trim();
    if (trimmed.startsWith('{')) {
      try {
        const obj: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
        const rawUri: Object | undefined = obj['uri'];
        if (typeof rawUri === 'string') {
          return { uri: rawUri.trim() };
        }
      } catch (_err) {
      }
    }
    return { uri: trimmed };
  }

  private consumePendingExternalUri(): void {
    if (!this.pageAlive || !this.docStore.workspaceReady) {
      return;
    }
    const token: string = this.pendingExternalUri;
    if (token.length === 0 || token === this.handledExternalUriToken) {
      return;
    }
    this.handledExternalUriToken = token;
    const parsed: ParsedPendingExternalUri = this.parsePendingExternalUriToken(token);
    const sourceUri: string = parsed.uri;
    if (sourceUri.length === 0) {
      return;
    }
    const cleanPath: string = this.stripUriQuery(sourceUri);
    let fileName: string = this.fileNameFromPath(cleanPath);
    try {
      fileName = decodeURIComponent(fileName);
    } catch (_err) {
    }
    const lower: string = fileName.toLowerCase();
    if (lower.endsWith('.hongtu')) {
      this.openProjectFromUri(sourceUri, fileName);
      return;
    }
    const classified: DroppedHongTuAsset | null = classifyHongTuUri(sourceUri);
    if (classified !== null) {
      if (classified.kind === 'layout') {
        this.openLayoutFromUri(classified.uri, classified.fileName);
      } else if (classified.kind === 'lyp') {
        this.importLypFromUri(classified.uri);
      } else {
        this.importRdbFromUri(classified.uri);
      }
      return;
    }
    showAppSnackBar(this.getUIContext(), '仅支持打开 .gds / .oas / .cif / .dxf 版图、.lyp 图层、.lyrdb 报告或 .hongtu 工程', {
      duration: AppToastDuration.NORMAL
    });
  }

  private async openProjectFromUri(sourceUri: string, fallbackName: string): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (!this.pageAlive || !this.canOpenWorkspaceDocument()) {
      return;
    }
    const generation: number = this.pageGeneration;
    try {
      this.panelStore.statusText = `正在读取外部工程：${fallbackName}...`;
      const raw: string = await workspaceService.readBounded(sourceUri, 192 * 1024 * 1024);
      if (!this.pageAlive || generation !== this.pageGeneration || !this.canOpenWorkspaceDocument()) {
        return;
      }
      const document: WorkspaceDocument = workspaceService.parseDocument(raw);
      document.id = workspaceService.newId();
      document.localProcessState = undefined;
      document.localPythonDraft = undefined;
      document.localPythonDraftDirty = undefined;
      document.projectUri = sourceUri;
      document.sourcePath = '';
      document.saveUri = '';
      document.dirty = false;
      this.captureWorkspaceDocument();
      this.activateWorkspaceDocument(document);
      this.workspaceDocuments.set(document.id, document);
      this.panelStore.showProjectPanel = false;
      this.viewportStore.currentModule = WorkModule.Layout;
      this.saveWorkspaceDraft();
      this.panelStore.statusText = `已打开工程 ${document.title}`;
      showAppSnackBar(this.getUIContext(), `已打开工程 ${document.title}`, {
        icon: $r('sys.symbol.checkmark_circle'),
        duration: AppToastDuration.SHORT
      });
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) {
        this.panelStore.statusText = `打开外部工程失败：${String(error)}`;
        showAppSnackBar(this.getUIContext(), this.panelStore.statusText, {
          duration: AppToastDuration.NORMAL
        });
      }
    }
  }

  private handleExternalFileDrop(event: DragEvent): void {
    const assets: DroppedHongTuAsset[] = systemCollaborationService.extractDroppedAssets(event);
    if (assets.length === 0) {
      try { event.setResult(DragResult.DRAG_FAILED); } catch (_err) {}
      showAppSnackBar(this.getUIContext(), '仅支持拖入 .gds / .oas / .cif / .dxf 版图、.lyp 图层或 .lyrdb 报告', {
        duration: AppToastDuration.NORMAL
      });
      return;
    }
    try { event.setResult(DragResult.DRAG_SUCCESSFUL); } catch (_err) {}
    const primary: DroppedHongTuAsset = assets[0];
    if (primary.kind === 'layout') {
      this.openLayoutFromUri(primary.uri, primary.fileName);
    } else if (primary.kind === 'lyp') {
      this.importLypFromUri(primary.uri);
    } else {
      this.importRdbFromUri(primary.uri);
    }
  }

  private async openLayoutFromUri(sourceUri: string, fallbackName: string): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (!this.pageAlive) return;
    const generation: number = this.pageGeneration;
    const documentId: string = this.docStore.activeWorkspaceId;
    const revision: number = this.docStore.editorRevision;
    const isCurrent: () => boolean = (): boolean =>
      this.pageAlive && generation === this.pageGeneration && documentId === this.docStore.activeWorkspaceId && revision === this.docStore.editorRevision;
    if (this.importInProgress) {
      this.panelStore.statusText = '已有版图正在打开，请等待完成或取消';
      return;
    }
    if (!this.canOpenWorkspaceDocument()) return;
    this.importInProgress = true;
    this.importWizardCancelled = false;
    this.setNativeSnapshotCurrent(false);
    let sandboxPath: string = '';
    let keepImportedFile: boolean = false;
    try {
      this.panelStore.statusText = `正在读取拖入版图：${fallbackName}...`;
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      this.docStore.wizardStoredShapes = -1;
      this.docStore.wizardCoordinateCount = -1;
      this.docStore.wizardExpandedPlacements = -1;
      this.docStore.wizardGeometryBytes = -1;
      this.docStore.wizardBudgetMessage = '';
      const picked: PickedLayout = await fileImportService.scanFromUri(context, sourceUri, (path: string): Promise<GdsiiResult> => {
        if (!isCurrent()) throw new Error('拖入打开请求已过期');
        return this.parseImportJob(path, true, isCurrent);
      });
      sandboxPath = picked.sandboxPath;
      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;

      const fileSize: number = picked.quickInfo.fileSize;
      let mode: ViewMode = ViewMode.EDIT;
      if (fileSize >= LARGE_FILE_THRESHOLD_BYTES) {
        const fileName: string = this.fileNameFromPath(this.stripUriQuery(picked.sourceUri));
        mode = await this.promptOpenWizard(fileSize, fileName.length > 0 ? fileName : fallbackName);
        if (this.importWizardCancelled) throw new Error('已取消打开版图');
      }

      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;
      this.panelStore.statusText = '正在解析拖入版图...';
      const parseResult: GdsiiResult = await this.parseImportJob(sandboxPath, false, isCurrent);
      if (!isCurrent() || !this.canOpenWorkspaceDocument()) return;
      const imported = new ImportedLayoutResult(picked.sourceUri, sandboxPath, picked.quickInfo, parseResult);
      await this.applyParsedResult(imported, mode, isCurrent);
      keepImportedFile = true;
      this.rememberRecentFile(imported);
      this.viewportStore.currentModule = WorkModule.Layout;
      const openedTitle: string = this.displayNameForImported(imported);
      this.panelStore.statusText = mode === ViewMode.VIEWER
        ? `已拖入打开（查看模式 · ${formatFileSize(fileSize)}）：${openedTitle}`
        : `已拖入打开：${openedTitle}`;
      showAppSnackBar(this.getUIContext(), `已打开 ${openedTitle}`, {
        icon: $r('sys.symbol.checkmark_circle'),
        duration: AppToastDuration.SHORT
      });
    } catch (error) {
      if (this.pageAlive && generation === this.pageGeneration) {
        this.panelStore.statusText = `拖入版图解析失败: ${error}`;
      }
    } finally {
      try {
        if (!keepImportedFile) fileImportService.cleanup(sandboxPath);
      } finally {
        if (this.pageAlive && generation === this.pageGeneration) this.finishLayoutImport();
      }
    }
  }

  private async importLypFromUri(uri: string): Promise<void> {
    this.canvasFocusReturnTicket++;
    const documentId: string = this.docStore.activeWorkspaceId;
    const revision: number = this.docStore.editorRevision;
    let previous: EditSessionState | undefined;
    let before: EditStructureState | undefined;
    try {
      this.panelStore.statusText = '正在读取拖入的 .lyp 图层属性文件...';
      const content: LypFileContent = await lypService.readLypFromUri(uri);
      if (documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
        this.panelStore.statusText = '版图已切换或修改，请重新拖入 .lyp';
        return;
      }
      const parsed: LypParseResult = parseLyp(content.text);
      const merged: LypMergeResult = mergeLypIntoLayers(this.docStore.layers, parsed.layers);
      this.finishNudgeTransaction();
      before = this.cellStructureState();
      const after: EditStructureState = cloneEditStructureModel(before, true) as EditStructureState;
      after.layers = merged.layers;
      if (parsed.layerDefinitions !== undefined) after.layerDefinitions = parsed.layerDefinitions;
      previous = editService.captureSession(true);
      if (!editService.applyDocumentStructure(editService.getShapes(), before, after, `拖入 .lyp：${content.fileName}`, true, undefined, true)) {
        throw new Error('图层属性事务未提交，原版图已保留');
      }
      this.syncShapesFromEditService(true);
      this.scheduleWorkspaceDraft();
      this.panelStore.statusText = `已拖入导入 ${content.fileName}: 更新 ${merged.appliedCount}/${parsed.layers.length} 层`;
      showAppSnackBar(this.getUIContext(), `已应用图层属性 ${content.fileName}`, {
        icon: $r('sys.symbol.checkmark_circle'),
        duration: AppToastDuration.SHORT
      });
    } catch (e) {
      if (previous !== undefined && before !== undefined) {
        editService.restoreSession(previous, true);
        try { this.restoreCellStructure(before); this.syncShapesFromEditService(true); } catch (_ignore) {}
      }
      this.panelStore.statusText = `.lyp 拖入导入失败: ${e instanceof Error ? e.message : String(e)}`;
    }
  }

  private async importRdbFromUri(uri: string): Promise<void> {
    this.openRdbReview();
    if (!this.rdbReviewActionReady() || this.rdbReviewDraftDirty) {
      showAppSnackBar(this.getUIContext(), '请先保存或取消当前 RDB 审阅草稿后再拖入新报告', {
        duration: AppToastDuration.NORMAL
      });
      return;
    }
    const workspaceToken: string = this.rdbReviewWorkspace.contextToken();
    const ticket: number = ++this.rdbReviewFileTicket;
    const generation: number = this.pageGeneration;
    this.verifyStore.rdbReviewBusy = true;
    try {
      const picked: RdbPickedReport = await rdbFileService.read(uri);
      if (!this.pageAlive || generation !== this.pageGeneration || ticket !== this.rdbReviewFileTicket ||
        workspaceToken !== this.rdbReviewWorkspace.contextToken()) {
        return;
      }
      const parsedRdb = await rdbService.parseAsync(picked.xml);
      if (!parsedRdb.ok || parsedRdb.document === undefined) throw new Error(parsedRdb.message);
      if (!this.pageAlive || generation !== this.pageGeneration || ticket !== this.rdbReviewFileTicket ||
        workspaceToken !== this.rdbReviewWorkspace.contextToken()) {
        return;
      }
      const candidate = new RdbReviewService();
      candidate.replaceDocument(parsedRdb.document, { identity: newLayoutIdentity('rdb'), name: picked.name });
      const workspace: RdbReviewWorkspaceService = this.rdbReviewWorkspace.fork();
      workspace.addSession(candidate, picked.uri, workspaceToken);
      this.publishRdbWorkspace(workspace);
      this.clearRdbReviewOverlay();
      this.refreshRdbReview();
      this.verifyStore.rdbReviewStatus = `已拖入载入报告：${picked.name}`;
      showAppSnackBar(this.getUIContext(), `已载入 DRC 报告 ${picked.name}`, {
        icon: $r('sys.symbol.checkmark_circle'),
        duration: AppToastDuration.SHORT
      });
    } catch (error) {
      this.verifyStore.rdbReviewStatus = `拖入报告读取失败：${String(error)}`;
    } finally {
      if (ticket === this.rdbReviewFileTicket) {
        this.verifyStore.rdbReviewBusy = false;
      }
    }
  }

  private buildExportLayerStyles(): ExportLayerStyle[] {
    return this.layersForDisplay().map((l: UiLayer): ExportLayerStyle => {
      const t: number | undefined = l.transparency;
      return {
        layerNumber: l.layerNumber,
        datatype: l.datatype,
        color: l.color,
        visible: l.visible,
        transparency: t === undefined ? undefined : t / 100,
        lineWidth: l.lineWidth,
        lineStyle: lineStyleCode(l.lineStyle),
        fillPattern: fillPatternCode(l.fillStyle),
      };
    });
  }

  private currentShareBaseName(): string {
    let baseName: string = this.currentFileDisplayName();
    const dot: number = baseName.lastIndexOf('.');
    if (dot > 0) {
      baseName = baseName.substring(0, dot);
    }
    return baseName.length > 0 ? baseName : 'layout';
  }

  private buildKnockSharePayload(): KnockSharePayload | null {
    if (!this.pageAlive || !this.docStore.workspaceReady || this.shapes.length === 0) {
      return null;
    }
    try {
      if (!this.synchronizeCurrentDocument()) {
        return null;
      }
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const exported = layoutExportService.exportImageToCacheForShare(
        'png',
        context.cacheDir,
        this.currentShareBaseName(),
        this.buildExportLayerStyles(),
        1600,
        1600
      );
      return {
        sandboxPath: exported.sandboxPath,
        fileName: exported.fileName,
        title: `${this.docStore.currentDocumentTitle} · 版图快照`,
        description: `鸿图版图快照（Cell: ${this.docStore.currentEditingCellName}，${this.shapes.length} 个图形）`,
        thumbnailSandboxPath: exported.sandboxPath,
      };
    } catch (error) {
      console.warn(`[Index] 碰一碰快照构建未完成: ${String(error)}`);
      return null;
    }
  }

  private async shareCurrentLayoutSnapshot(format: 'png' | 'svg'): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (this.shapes.length === 0) {
      showAppSnackBar(this.getUIContext(), '当前画布为空，暂无可分享的版图图形', {
        duration: AppToastDuration.SHORT
      });
      return;
    }
    if (!this.synchronizeCurrentDocument()) return;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const exported = layoutExportService.exportImageToCacheForShare(
        format,
        context.cacheDir,
        this.currentShareBaseName(),
        this.buildExportLayerStyles(),
        2048,
        2048
      );
      await systemCollaborationService.shareSandboxFile(
        context,
        exported.sandboxPath,
        exported.fileName,
        `鸿图 ${format.toUpperCase()} 版图导出 · Cell ${this.docStore.currentEditingCellName}`
      );
      this.panelStore.statusText = `已拉起分享面板：${exported.fileName}`;
    } catch (error) {
      this.panelStore.statusText = `版图分享未完成：${error instanceof Error ? error.message : String(error)}`;
    }
  }

  private async shareExportedUri(uri: string, fileName: string, description: string): Promise<void> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await systemCollaborationService.shareExternalUriViaCache(context, uri, fileName, description);
    } catch (error) {
      showAppSnackBar(this.getUIContext(), `拉起系统分享失败：${error instanceof Error ? error.message : String(error)}`, {
        duration: AppToastDuration.NORMAL
      });
    }
  }

  private async copyExportLocation(uri: string): Promise<void> {
    let message: string = '保存位置已复制';
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, uri));
    } catch (_error) {
      message = '文件已导出；保存位置复制失败';
    }
    showAppToast(this.getUIContext(), message, AppToastDuration.NORMAL);
  }

  /**
   * 导出当前布局为图像（SVG/PNG）。
   * 当前编辑态同步后导出；选择目标期间发生编辑/切换则取消，避免导出其他文档。
   */
  private async exportImage(format: 'svg' | 'png'): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (this.saveInProgress) { this.panelStore.statusText = '当前保存或导出尚未结束，请稍候'; return; }
    this.saveInProgress = true;
    try {
      if (!this.synchronizeCurrentDocument()) return;
      const workspaceId: string = this.docStore.activeWorkspaceId;
      const revision: number = this.docStore.editorRevision;
      this.panelStore.statusText = '正在选择图像保存位置...';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const layers: ExportLayerStyle[] = this.layersForDisplay().map((l: UiLayer): ExportLayerStyle => {
        // UiLayer.transparency 是 0–100（KLayout <transparent> 口径），native 侧是 0–1
        const t: number | undefined = l.transparency;
        return {
          layerNumber: l.layerNumber,
          datatype: l.datatype,
          color: l.color,
          visible: l.visible,
          transparency: t === undefined ? undefined : t / 100,
          lineWidth: l.lineWidth,
          lineStyle: lineStyleCode(l.lineStyle),
          fillPattern: fillPatternCode(l.fillStyle),
        };
      });
      let baseName: string = this.currentFileDisplayName();
      const dot: number = baseName.lastIndexOf('.');
      if (dot > 0) {
        baseName = baseName.substring(0, dot);
      }
      if (baseName.length === 0) {
        baseName = 'layout';
      }
      const result: LayoutExportResult = await layoutExportService.exportImageWithPicker(
        context, format, context.cacheDir, baseName, layers, 2048, 2048, () => {
          if (workspaceId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
            throw new Error('选择目标期间文档已变化，请重新导出');
          }
          if (!this.synchronizeCurrentDocument()) throw new Error('当前编辑文档同步失败，未导出');
        });
      this.panelStore.statusText = `已导出 ${format.toUpperCase()}: ${result.fileName} (${formatFileSize(result.bytes)})`;
      this.showExportLocation(format.toUpperCase(), result.fileName, result.uri);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.panelStore.statusText = e instanceof ImageExportCancelledError ? '已取消图像导出' : `图像导出失败: ${msg}`;
    } finally {
      this.saveInProgress = false;
    }
  }

  /**
   * 导出 OASIS：native 快照结构化写出（SEMI P39，含名称表/END CRC32）。
   * 快照语义与图像导出一致：当前编辑态同步，无需先保存。
   */
  private async exportOasis(): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (this.saveInProgress) { this.panelStore.statusText = '当前保存或导出尚未结束，请稍候'; return; }
    this.saveInProgress = true;
    try {
      if (!this.synchronizeCurrentDocument()) return;
      const workspaceId: string = this.docStore.activeWorkspaceId;
      const revision: number = this.docStore.editorRevision;
      if (!await this.confirmExportQuantization(this.currentExportInput(), workspaceId, revision)) { this.panelStore.statusText = '已取消 OASIS 导出，编辑状态保留'; return; }
      this.panelStore.statusText = '正在选择 OASIS 保存位置...';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      let baseName: string = this.currentFileDisplayName();
      const dot: number = baseName.lastIndexOf('.');
      if (dot > 0) {
        baseName = baseName.substring(0, dot);
      }
      if (baseName.length === 0) {
        baseName = 'layout';
      }
      const result: LayoutExportResult = await layoutExportService.exportOasisWithPicker(
        context, context.cacheDir, baseName, () => {
          if (workspaceId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
            throw new Error('选择目标期间文档已变化，请重新导出');
          }
          if (!this.synchronizeCurrentDocument()) throw new Error('当前编辑文档同步失败，未导出');
        });
      const skipNote: string = result.skippedShapeCount > 0
        ? `，跳过 ${result.skippedShapeCount} 个不支持图形`
        : '';
      this.panelStore.statusText = `已导出 OASIS: ${result.fileName}（${result.shapeCount} 图形, ${formatFileSize(result.bytes)}）${skipNote}${result.warnings.length > 0 ? '；' + result.warnings[0] : ''}`;
      showAppSnackBar(this.getUIContext(), `已导出 ${result.fileName}`, { icon: $r('sys.symbol.checkmark_circle'), duration: AppToastDuration.NORMAL });
    } catch (e) {
      const rawMessage: string = e instanceof Error ? e.message : String(e);
      const msg: string = rawMessage === 'OASIS cannot preserve singleton array identity or inactive vectors; save GDSII'
        ? 'OASIS 无法保留单元素阵列标识或未使用的阵列向量；请保存为 GDSII 以保留这些信息。'
        : rawMessage;
      this.panelStore.statusText = `OASIS 导出失败: ${msg}`;
    } finally {
      this.saveInProgress = false;
      this.refreshFileRecovery();
    }
  }

  private refreshFileRecovery(): void {
    try { this.docStore.fileRecoveryEntries = fileRecoveryService.list(this.getUIContext().getHostContext() as common.UIAbilityContext); }
    catch (error) { this.docStore.recoveryStatus = `安全副本发现失败：${String(error)}`; }
  }

  private confirmExportQuantization(input: ExportLayoutInput, documentId: string, revision: number): Promise<boolean> {
    const report: NativeQuantizationReport = layoutExportService.analyzeQuantization(input);
    if (report.quantizedValueCount === 0) return Promise.resolve(true);
    return new Promise<boolean>((resolve: (allowed: boolean) => void) => {
      this.canvasFocusReturnTicket++;
      this.getUIContext().showAlertDialog({ cornerRadius: UI.dialogRadius, title: '保存将按 DBU 量化',
        message: `DBU ${cleanMetricNumber(report.dbuNm)} nm：${report.quantizedShapeCount} 个对象、${report.quantizedValueCount} 个坐标或尺寸将量化，最大偏差 ${Number(report.maximumDeviationNm.toPrecision(4))} nm。磁盘结果会按数据库精度写出；当前编辑坐标保留。`,
        primaryButton: { fontColor: COLORS.ink, backgroundColor: COLORS.surfaceMuted, value: '取消保存', action: () => resolve(false) },
        secondaryButton: { fontColor: Color.White, backgroundColor: COLORS.primary, value: '继续写出快照', action: () => {
          if (documentId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) { this.panelStore.statusText = '文档已变化，请重新检查量化偏差'; resolve(false); }
          else resolve(true);
        } }, cancel: () => resolve(false)
      });
    });
  }

  /** Export the current editable layout to a real GDSII Stream file. */
  private async saveCurrentLayout(saveAs: boolean = false): Promise<void> {
    this.canvasFocusReturnTicket++;
    if (this.saveInProgress) { this.panelStore.statusText = '当前保存尚未结束'; return; }
    this.saveInProgress = true;
    const workspaceId: string = this.docStore.activeWorkspaceId;
    const revision: number = this.docStore.editorRevision;
    try {
      this.panelStore.statusText = !saveAs && this.currentSaveUri.length > 0 ? '正在保存当前文档…' : '正在选择保存位置…';
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      // Own the exact save revision: picker awaits must not observe later point/property edits.
      const input: ExportLayoutInput = cloneStructured(this.currentExportInput()) as ExportLayoutInput;
      input.preferNativeWriter = false;
      input.preferOriginalSourceCopy = false;
      if (!await this.confirmExportQuantization(input, workspaceId, revision)) { this.panelStore.statusText = '已取消保存，编辑状态保留'; return; }
      this.setNativeSnapshotCurrent(false);
      const result: LayoutExportResult = !saveAs && this.currentSaveUri.length > 0
        ? await layoutExportService.saveGdsToUri(context, input, this.currentSaveUri)
        : await layoutExportService.exportGdsWithPicker(context, input);
      // The native writer may have committed the captured revision after a tab switch.
      // Restore the active editor before any subsequent native check/export.
      this.synchronizeCurrentDocument();
      if (result.skippedShapeCount > 0) {
        this.panelStore.statusText = `保存未完成：${result.skippedShapeCount} 个图形未写出，文档仍有未保存修改`;
        return;
      }
      const recentWarning: string = await this.rememberSavedFile(context, result);
      if (workspaceId !== this.docStore.activeWorkspaceId || revision !== this.docStore.editorRevision) {
        this.panelStore.statusText = `已保存快照 ${result.fileName}；当前文档和随后修改仍保留各自的保存状态${recentWarning}`;
        showAppToast(this.getUIContext(), '快照已保存；当前编辑状态未改变', AppToastDuration.NORMAL);
        return;
      }
      if (!this.localPythonDraftDirty) editService.markClean();
      this.docStore.documentDirty = this.localPythonDraftDirty;
      this.originalSourceCurrent = result.originalSourceCopied === true;
      this.currentSaveUri = result.uri;
      this.docStore.currentDocumentTitle = result.fileName;
      this.formFileSizes.set(this.docStore.activeWorkspaceId, result.bytes);
      this.publishFormSnapshot();
      this.refreshWorkspaceTabs();
      this.saveWorkspaceDraft(true);
      const warning: string = result.warnings.length > 0 ? `；${result.warnings[0]}` : '';
      const pythonWarning: string = this.localPythonDraftDirty ? '；Python 脚本仍未保存，请保存鸿图工程' : '';
      this.panelStore.statusText =
        `已导出 ${result.fileName}: ${result.shapeCount} 图形 / ${result.bytes} 字节${warning}${recentWarning}${pythonWarning}`;
      showAppSnackBar(
        this.getUIContext(),
        this.localPythonDraftDirty ? '版图已保存；脚本请保存鸿图工程' : '保存成功',
        { icon: $r('sys.symbol.checkmark_circle'), duration: AppToastDuration.SHORT }
      );
    } catch (error) {
      this.synchronizeCurrentDocument();
      this.panelStore.statusText = `保存失败，编辑状态已保留: ${error}`;
    } finally { this.saveInProgress = false; this.refreshFileRecovery(); }
  }

  /** 导出用 Top Cell id：优先匹配 docTopCellName，否则 0 */
  private resolveTopCellIdForExport(cellNames: string[]): number {
    for (let i = 0; i < cellNames.length; i++) {
      if (cellNames[i] === this.docStore.docTopCellName) {
        return i;
      }
    }
    // 回退：EditService 当前栈底
    const stack: number[] = editService.getCurrentCellStack();
    if (stack.length > 0 && stack[0] >= 0 && stack[0] < cellNames.length) {
      return stack[0];
    }
    return 0;
  }

  /** 按当前层级的完整几何和端口 aperture 范围适配，端口显示列表上限不影响范围。 */
  private fitAllShapes(): void {
    let summary: HierarchyDisplaySummary;
    const hiddenLayers: Set<string> = new Set<string>();
    for (let i = 0; i < this.docStore.layers.length; i++) {
      const l: UiLayer = this.docStore.layers[i];
      if (l.visible === false) hiddenLayers.add(`${l.layerNumber}:${l.datatype}`);
    }
    try {
      summary = summarizeCellDisplayShapes(editService.getShapes(), editService.getCurrentCellId(), this.docStore.hierarchyDepth,
        (number: number, datatype: number): boolean => !hiddenLayers.has(`${number}:${datatype}`));
    } catch (error) {
      this.panelStore.statusText = `无法适配完整图形范围：${error}`;
      return;
    }
    const portSummary: PortBoundsResult = summarizeCellPorts(
      editService.getShapes(), this.cellStructureState(), editService.getCurrentCellId(), this.docStore.hierarchyDepth
    );
    if (!portSummary.ok) {
      this.panelStore.statusText = `无法适配完整端口范围：${portSummary.message}`;
      return;
    }
    let nav: ShapeBounds | undefined = summary.bounds;
    if (portSummary.bounds !== undefined) {
      const ports: ShapeBounds = portSummary.bounds;
      nav = nav === undefined ? ports : {
        minX: Math.min(nav.minX, ports.minX), minY: Math.min(nav.minY, ports.minY),
        maxX: Math.max(nav.maxX, ports.maxX), maxY: Math.max(nav.maxY, ports.maxY)
      };
    }
    if (nav === undefined) {
      this.panelStore.statusText = '当前 Cell 与显示层级内没有图形或端口可适配';
      return;
    }
    // 单个 TEXT/INSTANCE 可能只有一个锚点，给适配视图一个稳定的最小范围。
    const w: number = Math.max(100, nav.maxX - nav.minX);
    const h: number = Math.max(100, nav.maxY - nav.minY);
    if (!Number.isFinite(w) || !Number.isFinite(h)) {
      this.panelStore.statusText = '无法适配完整范围：坐标跨度超出有限数值';
      return;
    }
    const viewW: number = this.viewportStore.canvasViewportWidth;
    const viewH: number = this.viewportStore.canvasViewportHeight;
    const viewport: CanvasNavigationViewport = this.canvasNavigationViewport();
    const usableW: number = viewport.toolbarReserved ? viewport.width : Math.max(120, viewW - CANVAS_FIT_PADDING * 2);
    const usableH: number = viewport.toolbarReserved ? viewport.height : Math.max(120, viewH - CANVAS_FIT_PADDING * 2);
    const scaleX: number = usableW / w;
    const scaleY: number = usableH / h;
    const zoom: number = Math.min(scaleX, scaleY) * 100;
    const clampedZoom: number = this.clampZoom(zoom);
    // Keep the same world center in the usable viewport (offsets are world coordinates).
    const cx: number = nav.minX / 2 + nav.maxX / 2;
    const cy: number = nav.minY / 2 + nav.maxY / 2;
    const nextOffsetX: number = viewport.centerX * 100 / clampedZoom - cx;
    const nextOffsetY: number = viewport.centerY * 100 / clampedZoom + cy;
    if (!Number.isFinite(nextOffsetX) || !Number.isFinite(nextOffsetY)) {
      this.panelStore.statusText = '无法适配完整范围：画布偏移超出有限数值';
      return;
    }
    viewService.setViewZoomPercent(clampedZoom);
    viewService.setViewOffset(nextOffsetX, nextOffsetY);
    this.viewportStore.zoomPercent = clampedZoom;
    this.viewportStore.viewOffsetX = nextOffsetX;
    this.viewportStore.viewOffsetY = nextOffsetY;
    const fitStatus: string = zoom < MIN_ZOOM_PERCENT ? '视图已居中，达到最小缩放，完整范围无法全部显示，请分区查看' : '视图已适配';
    const frames: string = summary.frameCount > 0 ? ` / ${summary.frameCount} 未展开引用框（提高层级查看内部）` : '';
    this.panelStore.statusText = `${fitStatus}：${summary.shapeCount} 图形${frames} / ${portSummary.portCount} 端口, 包围盒 ${w.toFixed(0)}x${h.toFixed(0)}nm, 缩放 ${formatZoomPercent(clampedZoom)}`;
    if (!this.canvasKeyboardBlocked()) {
      this.restoreCanvasFocusAfterPanelClose();
    }
  }

  /** 快速扫描：若已加载真实文件则调 native quickScan，否则用当前画布元信息汇总 */
  private runQuickScan(): void {
    if (this.docStore.currentFilePath.length > 0) {
      this.scanNativeFile(this.docStore.currentFilePath);
      return;
    }
    // 未加载文件时：用当前画布与图层状态汇总扫描结果
    const visibleCount: number = this.docStore.layers.filter((l: UiLayer) => l.visible).length;
    this.panelStore.statusText = `quickScan (当前画布): ${this.shapes.length} 图形 / ${this.docStore.layers.length} 图层 (${visibleCount} 可见) / 顶层 ${this.docStore.docTopCellName}`;
  }

  /** 全选图形（快捷键触发） */
  private selectAllShapes(): void {
    const allShapes: Shape[] = editService.getCurrentCellShapes();
    const ids: number[] = [];
    for (let i = 0; i < allShapes.length; i++) {
      ids.push(allShapes[i].id);
    }
    editService.selectMultiple(ids);
    const selectedCount: number = editService.getSelectedIds().length;
    this.syncShapesFromEditService();
    this.panelStore.statusText = `已全选 ${selectedCount} 个图形`;
  }

  /** 选择当前激活层上的所有图形（KLayout: Select All in Layer） */
  private selectAllOnCurrentLayer(): void {
    const allShapes: Shape[] = editService.getCurrentCellShapes();
    const ids: number[] = [];
    for (let i = 0; i < allShapes.length; i++) {
      if (allShapes[i].layerNumber === this.viewportStore.selectedLayerNumber && allShapes[i].datatype === this.viewportStore.selectedDatatype) {
        ids.push(allShapes[i].id);
      }
    }
    editService.selectMultiple(ids);
    const selectedCount: number = editService.getSelectedIds().length;
    this.syncShapesFromEditService();
    this.panelStore.statusText = `已选择 L${this.viewportStore.selectedLayerNumber}/D${this.viewportStore.selectedDatatype} 上 ${selectedCount} 个图形`;
  }

  private traceNets(): void {
    // 当前编辑态的几何连通；跨层连接只采用用户绑定的工艺用途映射。
    try {
      let nets: Net[] | null = null;
      const viaLayers: NativeViaLayer[] = technologyService.getViaLayers();
      if (this.synchronizeCurrentDocument() && this.nativeSnapshotUsable()) {
        nets = verifyService.traceNetsNative(viaLayers, editService.getCurrentCellId(), viewService.getHierarchyDepth());
      }
      const nativeUsed: boolean = nets !== null;
      if (nets === null) {
        nets = verifyService.traceNets(editService.getCurrentCellShapes());
      }
      this.verifyStore.tracedNets = nets;
      this.netSnapshotRevision = this.docStore.editorRevision;
      if (nets.length === 0) {
        this.panelStore.statusText = '几何网络追踪完成：未识别到导电图形；未进行器件电气验证';
        return;
      }
      // 找出成员最多的网络，在画布上高亮选中其所有图形（可视化）
      let largest: Net = nets[0];
      for (let i = 1; i < nets.length; i++) {
        if (nets[i].shapes.length > largest.shapes.length) {
          largest = nets[i];
        }
      }
      editService.selectMultiple(largest.shapes);
      this.syncShapesFromEditService();
      this.verifyStore.tracedNets = nets;
      this.netSnapshotRevision = this.docStore.editorRevision;
      // 状态栏展示汇总：总数 + Top 3 网络明细
      const sorted = nets.slice().sort((a: Net, b: Net) => b.shapes.length - a.shapes.length);
      const top3 = sorted.slice(0, 3);
      const detail: string = top3.map((n: Net) => `${n.name}(${n.shapes.length})`).join('，');
      const bboxDesc = `包围盒(${largest.boundingBox.minX},${largest.boundingBox.minY})-(${largest.boundingBox.maxX},${largest.boundingBox.maxY})`;
      const scope: string = !nativeUsed ? '当前 Cell 简化几何预检查，无跨层连接'
        : viaLayers.length > 0 ? `${viaLayers.length} 组工艺通孔映射` : '仅同层，未配置工艺通孔';
      this.panelStore.statusText = `几何网络追踪（${scope}）：共 ${nets.length} 个网络 | 已高亮最大网络 ${largest.name}（${largest.shapes.length} 图形，${bboxDesc}）| Top3：${detail}；未进行器件电气验证`;
    } catch (e) {
      // INDEX-13: 网络追踪异常时清空结果并提示
      this.verifyStore.tracedNets = [];
      this.netSnapshotRevision = -1;
      this.panelStore.statusText = `网络追踪失败: ${e instanceof Error ? e.message : String(e)}`;
    }
  }

  // ==================== LVS 连通性预检查（非签核）====================

  /**
   * native 布局快照是否可作为 LVS / 网络追踪的输入：
   * 是否已同步当前编辑文档且 native 可用；dirty 只表示尚未磁盘保存。
   */
  private nativeSnapshotUsable(): boolean {
    return this.docStore.nativeSnapshotCurrent &&
      nativeHongTuService.getVersion().status === NativeStatus.READY;
  }

  private openLvsPanel(): void {
    this.panelStore.showLvsPanel = true;
    this.lvsSheetOpen = true;
    this.panelStore.showAiPanel = false;
    this.panelStore.showMacroPanel = false;
    const synchronized: boolean = this.synchronizeCurrentDocument();
    this.verifyStore.lvsNote = synchronized && this.nativeSnapshotUsable()
      ? (technologyService.getViaLayers().length > 0 ? '' : '未配置工艺通孔，当前仅检查同层连通')
      : '文档同步未就绪，请检查版图状态后重试';
    this.panelStore.statusText = '几何连通性预检查：粘贴 SPICE/CDL 参考网表后运行；器件 LVS 使用工艺验证面板';
  }

  private closeLvsPanel(): void {
    this.panelStore.showLvsPanel = false;
    this.lvsSheetOpen = false;
  }

  /** 载入提取网表：把版图侧提取结果填进参考框，便于就地改成期望网表后自比对 */
  private loadExtractedNetlist(): void {
    this.verifyStore.lvsHasResult = false;
    this.verifyStore.lvsResult = emptyLvsResult();
    this.verifyStore.lvsReports = [];
    this.lvsNativeNets = [];
    this.netSnapshotRevision = -1;
    try {
      if (!this.synchronizeCurrentDocument() || !this.nativeSnapshotUsable()) {
        throw new Error('当前编辑文档未能同步到 native');
      }
      const viaLayers: NativeViaLayer[] = technologyService.getViaLayers();
      const spice: string | null = verifyService.exportSpiceNetlist(
        viaLayers, editService.getCurrentCellId(), viewService.getHierarchyDepth());
      if (spice === null || spice.length === 0) {
        throw new Error('native 未返回完整的提取网表');
      }
      this.verifyStore.lvsNetlistText = spice;
      this.verifyStore.lvsNote = `已载入几何连通网表（${viaLayers.length > 0 ? '已使用工艺通孔映射' : '仅同层，无工艺通孔映射'}；匿名网未列为端口）；未进行器件提取`;
      this.panelStore.statusText = '已载入版图提取网表到参考框';
    } catch (e) {
      const message: string = e instanceof Error ? e.message : String(e);
      this.verifyStore.lvsResult.error = message;
      this.verifyStore.lvsNote = `无法导出提取网表：${message}；原参考文本已保留`;
      this.panelStore.statusText = this.verifyStore.lvsNote;
    }
  }

  /** 运行 LVS：任何前置条件缺失都以「未运行」呈现，不得显示为通过 */
  private runLvsCheck(): void {
    this.verifyStore.lvsNote = '';
    this.verifyStore.lvsHasResult = false;
    this.verifyStore.lvsResult = emptyLvsResult();
    this.verifyStore.lvsReports = [];
    this.lvsNativeNets = [];
    this.netSnapshotRevision = -1;
    try {
      if (!this.synchronizeCurrentDocument() || !this.nativeSnapshotUsable()) {
        throw new Error('当前编辑文档未能同步到 native');
      }
      const cellId: number = editService.getCurrentCellId();
      // 与画布同口径：按当前显示层级检查实例内的几何连通。
      const lvsDepth: number = viewService.getHierarchyDepth();
      const viaLayers: NativeViaLayer[] = technologyService.getViaLayers();
      const result: NativeLvsResult | null =
        verifyService.runLvsNative(this.verifyStore.lvsNetlistText, viaLayers, cellId, lvsDepth);
      if (result === null) throw new Error('native 模块不可用或检查调用失败');
      if (!result.ran || result.status === 'truncated') {
        const notRun: NativeLvsResult = emptyLvsResult();
        notRun.status = result.status === 'pass' || result.status === 'mismatch' ? 'not-run' : result.status;
        notRun.error = result.error || (result.status === 'truncated' ? '层级或图形预算触顶，网表不完整' : '检查未执行');
        notRun.messages = result.messages;
        this.verifyStore.lvsResult = notRun;
        this.verifyStore.lvsHasResult = true;
        this.verifyStore.lvsNote = `连通性预检查未运行：${notRun.error}`;
        this.panelStore.statusText = this.verifyStore.lvsNote;
        return;
      }
      const nets: NativeNet[] | null = nativeHongTuService.extractNets(viaLayers, cellId, lvsDepth);
      if (nets === null) throw new Error('无法完整提取逐网成员，检查结果已失效');
      const reports: LvsNetReport[] = verifyService.buildLvsReports(nets, result);
      // 完整提取和报告构建均成功后再发布，异常路径不留下通过状态或部分成员。
      this.lvsNativeNets = nets;
      this.verifyStore.lvsReports = reports;
      this.verifyStore.lvsResult = result;
      this.verifyStore.lvsHasResult = true;
      this.netSnapshotRevision = this.docStore.editorRevision;
      this.verifyStore.lvsNote = viaLayers.length > 0
        ? '采用绑定工艺的通孔用途映射；这是几何连通性预检查，器件电气 LVS 请使用工艺验证面板。'
        : '未配置工艺通孔映射：仅检查同层连通，跨层网络可能被拆分；未提取器件。';
      this.panelStore.statusText = `连通性预检查 ${verifyService.lvsStatusLabel(result.status)}：` +
        `版图 ${result.layoutNetCount} 网 / 参考 ${result.schematicNetCount} 网 / 匹配 ${result.matchedNets}` +
        ` / 开路 ${result.openNets.length} / 短路 ${result.shortNets.length}` +
        ` / 多余 ${result.extraNets.length}` +
        ` · 展开 ${lvsDepth} 层 · ${viaLayers.length > 0 ? '绑定工艺通孔' : '仅同层'}（几何连通性预检查）`;
    } catch (e) {
      const message: string = e instanceof Error ? e.message : String(e);
      this.verifyStore.lvsHasResult = false;
      this.verifyStore.lvsResult = emptyLvsResult();
      this.verifyStore.lvsResult.error = message;
      this.verifyStore.lvsReports = [];
      this.lvsNativeNets = [];
      this.netSnapshotRevision = -1;
      this.verifyStore.lvsNote = `连通性预检查未运行：${message}`;
      this.panelStore.statusText = this.verifyStore.lvsNote;
    }
  }

  private invalidateLvsResult(): void {
    this.verifyStore.lvsHasResult = false;
    this.verifyStore.lvsResult = emptyLvsResult();
    this.verifyStore.lvsReports = [];
    this.lvsNativeNets = [];
    this.netSnapshotRevision = -1;
    this.verifyStore.tracedNets = [];
    this.verifyStore.lvsNote = '文档或参考网表已变化，请重新检查';
  }

  /** 点击逐网行：在画布上高亮该网全部成员图形 */
  private selectLvsNet(report: LvsNetReport): void {
    if (!this.verifyStore.lvsHasResult || this.netSnapshotRevision !== this.docStore.editorRevision) {
      this.invalidateLvsResult(); this.panelStore.statusText = 'LVS 结果已失效，请重新检查后定位'; return;
    }
    for (let i = 0; i < this.lvsNativeNets.length; i++) {
      const net: NativeNet = this.lvsNativeNets[i];
      if (net.id !== report.netId) {
        continue;
      }
      this.focusWorldBounds({ minX: net.bboxMinX, minY: net.bboxMinY, maxX: net.bboxMaxX, maxY: net.bboxMaxY });
      if (net.fromInstance) {
        this.verifyStore.highlightedViolation = { x: net.bboxMinX, y: net.bboxMinY,
          w: Math.max(1, net.bboxMaxX - net.bboxMinX), h: Math.max(1, net.bboxMaxY - net.bboxMinY) };
        this.panelStore.statusText = `已定位实例展开网络 ${net.name} #${net.id} 的范围；成员不能直接作为当前 Cell 选区`;
        return;
      }
      const ids: number[] = [];
      for (let j = 0; j < net.shapeIds.length; j++) {
        ids.push(net.shapeIds[j]);
      }
      editService.selectMultiple(ids);
      this.shapes = editService.getShapes().slice();
      this.viewportStore.selectedShapeId = editService.getSelectedId();
      const selected: number = editService.getSelectedIds().length;
      this.viewportStore.selectedShapeCount = selected;
      this.panelStore.statusText = `已定位网络 ${net.name} #${net.id}，选中 ${selected}/${ids.length} 个当前 Cell 可选图形`;
      return;
    }
    this.panelStore.statusText = `未找到网络 ${report.name} 的成员（请重新运行 LVS）`;
  }

  private handleShortcut(action: ShortcutAction, param?: Object): void {
    // 接通 ShortcutService：分发快捷键动作到对应操作
    if (action === ShortcutAction.SWITCH_TOOL) {
      if (param !== undefined && typeof param === 'number') {
        const next: ActiveTool = this.drawToolToActiveTool(param);
        // 实例放置工具：不进入画布交互态，直接弹窗
        if (next === ActiveTool.Instance) {
          this.activateInstanceToolSmart();
          return;
        }
        this.exitStampSession();
        this.viewportStore.currentTool = next;
        this.panelStore.statusText = `当前工具: ${this.toolLabel(this.viewportStore.currentTool)}`;
      }
      return;
    }
    if (action === ShortcutAction.UNDO) {
      this.undoEdit();
      return;
    }
    if (action === ShortcutAction.REDO) {
      this.redoEdit();
      return;
    }
    if (action === ShortcutAction.DELETE) {
      this.removeSelectedShape();
      return;
    }
    if (action === ShortcutAction.ZOOM_IN) {
      this.setZoom(20);
      return;
    }
    if (action === ShortcutAction.ZOOM_OUT) {
      this.setZoom(-20);
      return;
    }
    if (action === ShortcutAction.FIT_ALL) {
      this.fitAllShapes();
      return;
    }
    if (action === ShortcutAction.SELECT_ALL) {
      this.selectAllShapes();
      return;
    }
    if (action === ShortcutAction.OPEN) {
      this.pickAndParseFile();
      return;
    }
    if (action === ShortcutAction.SAVE) {
      this.saveCurrentLayout();
      return;
    }
    if (action === ShortcutAction.RUN_DRC) {
      this.runDrcBackground();
      return;
    }
    // SHORTCUT-2: 取消选择
    if (action === ShortcutAction.DESELECT) {
      editService.clearSelection();
      this.viewportStore.selectedShapeId = -1;
      this.syncShapesFromEditService();
      this.panelStore.statusText = '已取消选择';
      return;
    }
    // SHORTCUT-2: 切换网格显示
    if (action === ShortcutAction.TOGGLE_GRID) {
      this.viewportStore.gridVisible = !this.viewportStore.gridVisible;
      this.panelStore.statusText = `网格${this.viewportStore.gridVisible ? '已显示' : '已隐藏'}`;
      return;
    }
    // TRANSFORM-1: 旋转/镜像/缩放
    if (action === ShortcutAction.ROTATE) {
      if (param !== undefined && typeof param === 'number') {
        this.transformSelection('rotate', param);
      }
      return;
    }
    if (action === ShortcutAction.MIRROR) {
      if (param !== undefined && typeof param === 'number') {
        this.transformSelection('mirror', param);
      }
      return;
    }
    if (action === ShortcutAction.SCALE) {
      if (param !== undefined && typeof param === 'number') {
        this.transformSelection('scale', param);
      }
      return;
    }
    // SC-M2: 复制/粘贴/对齐/分布快捷键分发
    if (action === ShortcutAction.COPY) {
      this.copySelection();
      return;
    }
    if (action === ShortcutAction.PASTE) {
      this.pasteFromClipboard();
      return;
    }
    if (action === ShortcutAction.ALIGN) {
      if (param !== undefined && typeof param === 'string') {
        const labelMap: Record<string, string> = {
          'left': '左对齐', 'right': '右对齐', 'top': '顶对齐',
          'bottom': '底对齐', 'centerH': '水平居中', 'centerV': '垂直居中',
        };
        const alignType = this.alignTypeFromString(param);
        if (alignType !== null) {
          this.alignSelection(alignType, labelMap[param] ?? param);
        }
      }
      return;
    }
    if (action === ShortcutAction.DISTRIBUTE) {
      if (param !== undefined && typeof param === 'string') {
        const distType = this.distributeTypeFromString(param);
        if (distType !== null) {
          this.distributeSelection(distType);
        }
      }
      return;
    }
    // === 单键方案新增动作 ===
    if (action === ShortcutAction.ESCAPE) {
      shortcutService.clear();
      // Esc: 取消当前绘制/回到Select工具
      if (this.viewportStore.currentTool !== ActiveTool.Select) {
        this.viewportStore.currentTool = ActiveTool.Select;
        this.panelStore.statusText = '已回到选择工具';
      } else {
        // 已在Select模式：取消选择
        editService.clearSelection();
        this.viewportStore.selectedShapeId = -1;
        this.syncShapesFromEditService();
        this.panelStore.statusText = '已取消选择';
      }
      return;
    }
    if (action === ShortcutAction.VIEW_BACK) {
      // Backspace: 视图后退（Cell导航回退）
      this.viewBack();
      return;
    }
    if (action === ShortcutAction.NUDGE) {
      // 方向键微移选中图形（步长=网格尺寸）
      if (param !== undefined && typeof param === 'string') {
        this.nudgeSelection(param);
      }
      return;
    }
    if (action === ShortcutAction.BOX_ZOOM) {
      this.viewportStore.currentTool = ActiveTool.BoxZoom;
      this.panelStore.statusText = '框选缩放：拖拽矩形区域放大';
      return;
    }
  }

  /**
   * 单键快捷键主方案（KLayout 兼容）。
   * 返回 true 表示已处理，false 表示未匹配（降级到拼音缓冲区）。
   */
  private handleSingleKey(key: string): boolean {
    switch (key) {
      case 'S':
        this.exitStampSession();
        this.viewportStore.currentTool = ActiveTool.Select;
        this.panelStore.statusText = '当前工具: 选择';
        return true;
      case 'H':
        this.exitStampSession();
        this.viewportStore.interactiveCurveKind = '';
        this.viewportStore.currentTool = ActiveTool.Pan;
        this.panelStore.statusText = '当前工具: 单指漫游（拖拽平移画布）';
        return true;
      case 'B':
        this.viewportStore.currentTool = ActiveTool.Rect;
        this.panelStore.statusText = '当前工具: 矩形';
        return true;
      case 'P':
        this.viewportStore.currentTool = ActiveTool.Polygon;
        this.panelStore.statusText = '当前工具: 多边形';
        return true;
      case 'L':
      case 'W':
        this.exitStampSession();
        this.viewportStore.interactiveCurveKind = '';
        this.viewportStore.currentTool = ActiveTool.Path;
        this.panelStore.statusText = '当前工具: 路径 / 波导';
        return true;
      case 'X':
      case 'T':
        this.exitStampSession();
        this.viewportStore.interactiveCurveKind = '';
        this.viewportStore.currentTool = ActiveTool.Text;
        this.panelStore.statusText = '当前工具: 文本标签';
        return true;
      case 'I':
        this.activateInstanceToolSmart();
        return true;
      case 'R':
      case 'K':
        this.exitStampSession();
        this.viewportStore.interactiveCurveKind = '';
        this.viewportStore.currentTool = ActiveTool.Measure;
        this.panelStore.statusText = '当前工具: 测量与标尺';
        return true;
      case 'Z':
        this.exitStampSession();
        this.viewportStore.interactiveCurveKind = '';
        this.viewportStore.currentTool = ActiveTool.BoxZoom;
        this.panelStore.statusText = '框选缩放：拖拽矩形区域局部放大';
        return true;
      case 'O':
        this.activateInteractiveCurve('CIRCLE');
        return true;
      case '0':
        viewService.setHierarchyDepth(1);
        this.panelStore.statusText = '层级展开深度: 1 层（仅当前单元本地图形）';
        return true;
      case '1':
      case '2':
      case '3':
      case '4':
      case '5': {
        const d: number = Number(key);
        viewService.setHierarchyDepth(d);
        this.panelStore.statusText = `层级展开深度: ${d} 层`;
        return true;
      }
      case '6':
      case '7':
      case '8':
      case '9':
        viewService.setHierarchyDepth(5);
        this.panelStore.statusText = '层级展开深度: 全部展开 (5 层)';
        return true;
      case 'M':
        this.switchToMoveTool();
        return true;
      case 'F':
        this.fitAllShapes();
        return true;
      case 'G':
        this.viewportStore.gridVisible = !this.viewportStore.gridVisible;
        this.panelStore.statusText = `网格${this.viewportStore.gridVisible ? '已显示' : '已隐藏'}`;
        return true;
      default:
        return false;
    }
  }

  /** 视图后退：Cell 导航栈回退 */
  private viewBack(): void {
    const stack: number[] = editService.getCurrentCellStack();
    if (stack.length <= 1) { this.panelStore.statusText = '已在顶层 Cell'; return; }
    this.navigateCellStack(stack.length - 2);
    this.panelStore.statusText = '已返回上一级 Cell';
  }

  private finishNudgeTransaction(): void {
    this.nudgeKeyHeld = false;
    if (this.nudgeTxTimer < 0 && !this.nudgeTxActive) return;
    if (this.nudgeTxTimer >= 0) clearTimeout(this.nudgeTxTimer);
    this.nudgeTxTimer = -1;
    this.nudgeTxActive = false;
    editService.endBatch();
  }

  private scheduleNudgeTransactionEnd(): void {
    if (this.nudgeTxTimer >= 0) clearTimeout(this.nudgeTxTimer);
    this.nudgeTxTimer = -1;
    if (!this.nudgeTxActive || this.nudgeKeyHeld) return;
    this.nudgeTxTimer = setTimeout((): void => {
      this.finishNudgeTransaction();
      this.docStore.documentDirty = editService.isDirty();
      this.syncShapesFromEditService();
    }, 400);
  }

  /** 方向键微移选中图形 */
  private nudgeSelection(direction: string): void {
    if (!this.assertEditMode()) { this.finishNudgeTransaction(); return; }
    if (this.viewportStore.selectedShapeId < 0) {
      return;
    }
    const step: number = this.viewportStore.drawStepNm > 0 ? this.viewportStore.drawStepNm : this.docStore.docPhysicalUnits / 1e-9;
    if (!Number.isFinite(step) || step <= 0) return;
    let dx: number = 0;
    let dy: number = 0;
    switch (direction) {
      case 'up': dy = step; break;
      case 'down': dy = -step; break;
      case 'left': dx = -step; break;
      case 'right': dx = step; break;
      default: return;
    }
    // 对所有选中图形执行微移
    const ids: number[] = editService.getSelectedIds();
    if (ids.length === 0) {
      return;
    }
    if (editService.getSelectedShapes().some((shape: Shape): boolean =>
      !editService.isShapeInCurrentCell(shape) || !editService.canEditLayer(shape.layerNumber, shape.datatype))) {
      this.finishNudgeTransaction();
      this.panelStore.statusText = '选择中包含锁定或不可编辑的图形，整批未微移';
      return;
    }
    // Keep the first Down in the held gesture even when system repeat starts
    // after 400ms. The ordinary 400ms coalescing window starts on key release.
    if (!this.nudgeTxActive) {
      editService.beginBatch();
      this.nudgeTxActive = true;
    }
    for (let i = 0; i < ids.length; i++) {
      editService.moveShape(ids[i], dx, dy);
    }
    this.scheduleNudgeTransactionEnd();
    this.syncShapesFromEditService();
    this.docStore.documentDirty = editService.isDirty();
    this.panelStore.statusText = `微移 ${direction} ${step}nm`;
  }

  /** SC-M2: 字符串 → AlignType 转换 */
  private alignTypeFromString(s: string): AlignType | null {
    switch (s) {
      case 'left': return AlignType.LEFT;
      case 'right': return AlignType.RIGHT;
      case 'top': return AlignType.TOP;
      case 'bottom': return AlignType.BOTTOM;
      case 'centerH': return AlignType.CENTER_H;
      case 'centerV': return AlignType.CENTER_V;
      default: return null;
    }
  }

  /** SC-M2: 字符串 → DistributeType 转换 */
  private distributeTypeFromString(s: string): DistributeType | null {
    switch (s) {
      case 'horizontal': return DistributeType.HORIZONTAL;
      case 'vertical': return DistributeType.VERTICAL;
      default: return null;
    }
  }

  /**
   * TRANSFORM-1: 对选中图形执行变换操作（旋转/镜像/缩放）。
   * 复用 AdvancedEditService 的 rotateSelection/mirrorSelection/scaleSelection，
   * 消除死代码并统一 INSTANCE 特殊处理路径。
   */
  private transformSelection(op: 'rotate' | 'mirror' | 'scale', param: number): void {
    // INDEX-1: 查看模式下禁止变换操作，与 align/distribute/changeLayer 等编辑方法保持一致
    if (!this.assertEditMode()) {
      return;
    }
    const selShapes = editService.getSelectedShapes();
    if (selShapes.length === 0) {
      this.panelStore.statusText = '请先选中图形再执行变换操作';
      return;
    }
    let ok = false;
    let label = '';
    if (op === 'rotate') {
      ok = advEditService.rotateSelection(param);
      label = `旋转 ${param}°`;
    } else if (op === 'mirror') {
      // param=0 水平镜像（沿 X 轴翻转，Y 取反），param=1 垂直镜像
      ok = advEditService.mirrorSelection(param === 0);
      label = param === 0 ? '水平镜像' : '垂直镜像';
    } else {
      // SCALE: 复用快捷键传入的倍数
      ok = advEditService.scaleSelection(param);
      label = `缩放 ${param}x`;
    }
    if (ok) {
      this.syncShapesFromEditService();
      this.panelStore.statusText = `${label}：${selShapes.length} 个图形`;
      if (macroService.isRecording()) {
        const command: string = op === 'mirror' ? `mirror|${param === 0 ? 1 : 0}` : `${op}|${param}`;
        this.recordMacroStep(`${label}：${selShapes.length} 个图形`, command);
      }
    } else {
      this.panelStore.statusText = `${label}失败（无选中或参数非法）`;
    }
  }

  private drawToolToActiveTool(tool: number): ActiveTool {
    if (tool === DrawTool.RECT) {
      return ActiveTool.Rect;
    }
    if (tool === DrawTool.POLYGON) {
      return ActiveTool.Polygon;
    }
    if (tool === DrawTool.PATH) {
      return ActiveTool.Path;
    }
    if (tool === DrawTool.MEASURE) {
      return ActiveTool.Measure;
    }
    if (tool === DrawTool.TEXT) {
      return ActiveTool.Text;
    }
    if (tool === DrawTool.MOVE) {
      return ActiveTool.Move;
    }
    if (tool === DrawTool.INSTANCE) {
      return ActiveTool.Instance;
    }
    if (tool === DrawTool.PAN) {
      return ActiveTool.Pan;
    }
    return ActiveTool.Select;
  }

  private toolLabel(tool: ActiveTool): string {
    if (tool === ActiveTool.Rect) {
      return '矩形';
    }
    if (tool === ActiveTool.Polygon) {
      return '多边形';
    }
    if (tool === ActiveTool.Path) {
      return '路径';
    }
    if (tool === ActiveTool.Measure) {
      return '测量';
    }
    if (tool === ActiveTool.Text) {
      return '文本';
    }
    if (tool === ActiveTool.Move) {
      return '移动';
    }
    if (tool === ActiveTool.Instance) {
      return '放置实例';
    }
    if (tool === ActiveTool.Pan) {
      return '漫游';
    }
    return '选择';
  }

  private errorCount(): number {
    let count = 0;
    for (let i = 0; i < this.verifyStore.drcIssues.length; i++) {
      if (this.verifyStore.drcIssues[i].severity === 'error') {
        count++;
      }
    }
    return count;
  }

  private warningCount(): number {
    let count = 0;
    for (let i = 0; i < this.verifyStore.drcIssues.length; i++) {
      if (this.verifyStore.drcIssues[i].severity === 'warning') {
        count++;
      }
    }
    return count;
  }
}
