/**
 * 鸿图工作台五大领域状态仓库（@ObservedV2 + @Trace）
 *
 * 严格遵循华为官方《状态管理 V1 和 V2 混用指导（API version 19 及之后）》与《基于 StateStore 的全局状态管理》：
 * 1. 将 Index.ets 原有 172 个 @State 字段中的 167 个按职责边界拆分为五大高内聚 @ObservedV2 领域 Store；
 * 2. Phase 5 扩展 ViewportSelectionStore：默认开启几何磁吸与智能延伸对齐参考线、自适应触屏磁吸半径（16vp 基准，触屏自动放大至 24vp+）、
 *    默认启用 90° 正交曼哈顿走线约束及触屏局部放大镜开关。
 *
 * This file is part of HongTu, licensed under GPLv3.
 */

import { AppStorageV2 } from '@kit.ArkUI';
import { CellTreeNode } from '../components/workbench/CellTreePanel';
import { ViolationHighlight } from '../components/workbench/LayoutCanvasView';
import { ProjectRecoveryEntry } from '../components/workbench/ProjectPanel';
import { EngineeringRestoreSourceChoice } from '../components/workbench/EngineeringReviewRestorePanel';
import { BreakpointManager, DeviceType, LayoutConfig, breakpointManager } from '../common/BreakpointManager';
import { UiLayer, ViewMode } from '../common/types';
import { UI } from '../common/UiTokens';
import { ShapeType } from '../models/GdsiiData';
import { ResolvedPort } from '../models/LayoutPort';
import type { EngineeringReviewRestorePreview } from '../models/EngineeringReviewBundle';
import type { RdbItem, RdbTransform } from '../models/RdbData';
import { emptyRdbReviewUiState, RdbReviewUiState } from '../models/RdbReviewUi';
import type { ViewOverlayDiagnostic, ViewOverlayDocumentChoice } from '../models/ViewOverlayUi';
import type { ViewBookmark, ViewRecord } from '../models/ViewWorkspace';
import {
  AiChatToolState,
  AiContext,
  AiContextOptions,
  AiConversationSummary,
  ChatMessage,
  ParsedCommand
} from '../services/AiService';
import { AiReviewGroup } from '../services/AiReviewGroups';
import { ComponentLibraryEntry } from '../services/ComponentLibraryService';
import { EngineeringDependency } from '../services/EngineeringProjectService';
import type { HierarchyHitCandidate } from '../services/HierarchyExpandService';
import { GEOMETRY_SNAP_KINDS } from '../services/PrecisionService';
import { RoutingMode } from '../services/RoutingConstraintService';
import { rdbIdentityTransform } from '../services/RdbService';
import { LvsNetReport, Net } from '../services/VerifyService';
import { viewService } from '../services/ViewService';
import { WorkspaceHistory, workspaceService, WorkspaceTab } from '../services/WorkspaceService';
import {
  createDrcIssues,
  createInitialLayers,
  createRecentFiles
} from '../workbench/WorkbenchData';
import {
  ActiveTool,
  DrcIssue,
  RecentFile,
  WorkModule
} from '../workbench/WorkbenchModels';
import type {
  NativeLayoutCompareLayer,
  NativeLvsResult
} from '../../cpp/types/libhongtu/Index';

export function createEmptyLvsResult(): NativeLvsResult {
  return {
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
}

/**
 * 领域一：版图文档、图层、多标签工作区与原生作业状态
 */
@ObservedV2
export class DocumentDomainStore {
  @Trace editorRevision: number = 0;
  @Trace nativeSnapshotCurrent: boolean = false;
  @Trace layers: UiLayer[] = createInitialLayers();
  @Trace workspaceTabs: WorkspaceTab[] = [];
  @Trace activeWorkspaceId: string = workspaceService.newId();
  @Trace workspaceHistory: WorkspaceHistory[] = [];
  @Trace recoveryStatus: string = '';
  @Trace workspaceReady: boolean = false;
  @Trace layerPresetNames: string[] = viewService.listLayerPresets();
  @Trace currentDocumentTitle: string = '未命名版图';
  @Trace engineeringDependencies: EngineeringDependency[] = [];
  @Trace fileRecoveryEntries: ProjectRecoveryEntry[] = [];
  @Trace currentFilePath: string = '';
  @Trace docLibName: string = 'UNTITLED_LIB';
  @Trace docCellCount: number = 1;
  @Trace docElementCount: number = 0;
  @Trace docTopCellName: string = 'TOP';
  @Trace currentEditingCellId: number = 0;
  @Trace currentEditingCellName: string = 'TOP';
  @Trace docUserUnits: number = 0.001;
  @Trace docPhysicalUnits: number = 1e-9;
  @Trace documentDirty: boolean = false;
  @Trace editCanUndo: boolean = false;
  @Trace editCanRedo: boolean = false;
  @Trace libraryEntries: ComponentLibraryEntry[] = [];
  @Trace pcellEditName: string = '';
  @Trace recentFiles: RecentFile[] = createRecentFiles();
  @Trace hierarchyDepth: number = 2;
  @Trace cellTreeData: CellTreeNode[] = [];
  @Trace currentTopCellId: number = 0;
  @Trace wizardFileSize: number = 0;
  @Trace wizardFileName: string = '';
  @Trace wizardStoredShapes: number = -1;
  @Trace wizardCoordinateCount: number = -1;
  @Trace wizardExpandedPlacements: number = -1;
  @Trace wizardGeometryBytes: number = -1;
  @Trace wizardBudgetMessage: string = '';
  @Trace activeNativeJobId: string = '';
  @Trace nativeJobLabel: string = '';
  @Trace nativeJobProgress: number = -1;
  @Trace nativeJobCancelRequested: boolean = false;

  /** 原生 C++ g_layout 展开仅在快照已同步且无未保存几何差异时启用 */
  canPreferNativeExpand(isDirty: boolean): boolean {
    return this.nativeSnapshotCurrent && !isDirty;
  }

  /** 当 g_layout 未同步或存在未保存编辑时，向渲染器提供当前 ArkTS 快照 */
  needsRenderSnapshot(isDirty: boolean): boolean {
    return !this.nativeSnapshotCurrent || isDirty;
  }
}

/**
 * 领域二：画布视口相机、选区过滤、空间磁吸、走线约束与视图工作区
 */
@ObservedV2
export class ViewportSelectionStore {
  @Trace currentModule: WorkModule = WorkModule.Layout;
  @Trace currentViewMode: ViewMode = ViewMode.EDIT;
  @Trace currentTool: ActiveTool = ActiveTool.Select;
  @Trace selectedLayerNumber: number = 1;
  @Trace selectedDatatype: number = 0;
  @Trace selectedShapeId: number = -1;
  @Trace selectedShapeCount: number = 0;
  @Trace multiSelectAdditive: boolean = false;
  @Trace zoomPercent: number = 100;
  @Trace viewOffsetX: number = 0;
  @Trace viewOffsetY: number = 0;
  @Trace canvasViewportWidth: number = 1200;
  @Trace canvasViewportHeight: number = 700;
  @Trace selectionLayerFilter: number = -1;
  @Trace selectionDatatypeFilter: number = -1;
  @Trace selectionTypeFilter: ShapeType[] = [];
  @Trace displayGridNm: number = 10;
  @Trace drawStepNm: number = 10;
  @Trace geometrySnapEnabled: boolean = true;
  @Trace geometrySnapKinds: string[] = GEOMETRY_SNAP_KINDS.slice();
  @Trace smartGuidesEnabled: boolean = true;
  @Trace routingMode: RoutingMode = RoutingMode.MANHATTAN_90;
  @Trace touchLoupeEnabled: boolean = true;
  @Trace interactiveCurveKind: string = '';
  @Trace pickedPlacement: HierarchyHitCandidate | null = null;
  @Trace instanceScopeLabel: string = '';
  @Trace instanceScopeSummary: string = '';
  @Trace gridSize: number = 10;
  @Trace snapEnabled: boolean = true;
  @Trace gridVisible: boolean = true;
  @Trace vertexSnapEnabled: boolean = true;
  @Trace vertexSnapThreshold: number = 16;
  @Trace projectedPorts: ResolvedPort[] = [];
  @Trace portProjectionNotice: string = '';
  @Trace portCapabilityNotice: string = '';
  @Trace viewWorkspaceViews: ViewRecord[] = [];
  @Trace viewWorkspaceBookmarks: ViewBookmark[] = [];
  @Trace viewWorkspaceActiveId: string = '';
  @Trace viewWorkspaceStatus: string = '';
  @Trace viewWorkspaceFileBusy: boolean = false;
  @Trace viewWorkspaceSceneRevision: number = 0;
  @Trace viewWorkspaceOverlayDocuments: ViewOverlayDocumentChoice[] = [];
  @Trace viewWorkspaceOverlayDiagnostics: ViewOverlayDiagnostic[] = [];
  @Trace viewWorkspaceOverlayContext: string = '';
  @Trace viewWorkspaceSceneDiagnostic: string = '';
}

/**
 * 领域三：DRC / LVS 物理验证、版图对比、RDB 审查与工程恢复校验
 */
@ObservedV2
export class VerificationDomainStore {
  @Trace drcIssues: DrcIssue[] = createDrcIssues();
  @Trace drcHasRun: boolean = false;
  @Trace drcDockCollapsed: boolean = false;
  @Trace showDrcRules: boolean = false;
  @Trace drcRulesAreaHeight: number = 0;
  @Trace drcRdbExportBusy: boolean = false;
  @Trace lastDrcElapsed: number = 0;
  @Trace highlightedViolationId: number = -1;
  @Trace highlightedViolation: ViolationHighlight | null = null;
  @Trace tracedNets: Net[] = [];
  @Trace lvsNetlistText: string = '';
  @Trace lvsHasResult: boolean = false;
  @Trace lvsResult: NativeLvsResult = createEmptyLvsResult();
  @Trace lvsReports: LvsNetReport[] = [];
  @Trace lvsNote: string = '';
  @Trace comparisonLayers: NativeLayoutCompareLayer[] = [];
  @Trace comparisonPair: string = '';
  @Trace comparisonCellName: string = '';
  @Trace rdbReviewUi: RdbReviewUiState = emptyRdbReviewUiState();
  @Trace rdbReviewStatus: string = '';
  @Trace rdbReviewBusy: boolean = false;
  @Trace rdbMarkerItem: RdbItem | null = null;
  @Trace rdbMarkerFrame: RdbTransform = rdbIdentityTransform();
  @Trace engineeringRestorePreview: EngineeringReviewRestorePreview | undefined = undefined;
  @Trace engineeringRestoreBusy: boolean = false;
  @Trace engineeringRestoreError: string = '';
  @Trace engineeringRestoreSourceIds: string[] = [];
  @Trace engineeringRestoreTargets: EngineeringRestoreSourceChoice[] = [];
  @Trace engineeringRestoreReplaceViews: boolean = false;
}

/**
 * 领域四：面板显隐协调、响应式窗口几何、侧栏/检查器分栏与外部拖拽悬停
 */
@ObservedV2
export class PanelLayoutStore {
  @Trace statusText: string = '就绪 | 空白版图 | 点击"打开"加载 GDSII/OASIS，或直接绘制新图形';
  @Trace nativeText: string = 'Native: loading';
  @Trace activeDialogCount: number = 0;
  @Trace showAiPanel: boolean = false;
  @Trace showPythonPanel: boolean = false;
  @Trace pythonOpenConnectionSettings: boolean = false;
  @Trace showComparePanel: boolean = false;
  @Trace showViewWorkspacePanel: boolean = false;
  @Trace showRdbReviewPanel: boolean = false;
  @Trace showTechnologyPanel: boolean = false;
  @Trace showLayerStackPanel: boolean = false;
  @Trace showVerificationPanel: boolean = false;
  @Trace showMacroPanel: boolean = false;
  @Trace macroRecording: boolean = false;
  @Trace macroStatusText: string = '';
  @Trace showLvsPanel: boolean = false;
  @Trace showFilePanel: boolean = false;
  @Trace showShortcutPanel: boolean = false;
  @Trace showLayerStylePanel: boolean = false;
  @Trace showProjectPanel: boolean = false;
  @Trace showSearchPanel: boolean = false;
  @Trace showLibraryPanel: boolean = false;
  @Trace propertyPanelClosed: boolean = false;
  @Trace propertyPanelPinned: boolean = false;
  @Trace windowWidthVp: number = 1280;
  @Trace windowHeightVp: number = 800;
  @Trace layerStyleAvailableHeight: number = 0;
  @Trace layerStyleAvailableWidth: number = 0;
  @Trace currentDevice: DeviceType = DeviceType.PC;
  @Trace layoutConfig: LayoutConfig = breakpointManager.getConfig();
  @Trace sidebarVisible: boolean = true;
  @Trace inspectorVisible: boolean = true;
  @Trace preferredSidebarWidth: number = UI.sidebarWidth;
  @Trace preferredInspectorWidth: number = 280;
  @Trace cellNameDialogTitle: string = '新建 Cell';
  @Trace cellNameDialogInitial: string = '';
  @Trace curveInitialName: string = '';
  @Trace curveOutputMode: string = 'instance';
  @Trace isExternalDragHovering: boolean = false;
}

/**
 * 领域五：AI 版图助手会话、上下文预算、流式输出与变更审查组
 */
@ObservedV2
export class AiAssistantStore {
  @Trace aiMessages: ChatMessage[] = [];
  @Trace aiConversations: AiConversationSummary[] = [];
  @Trace aiActiveConversationId: string = '';
  @Trace aiContextOptions: AiContextOptions = { includeHistory: true, includeLayout: true, includeSelection: true };
  @Trace aiContextEpoch: number = 0;
  @Trace aiReportedContextUsage: string = '';
  @Trace aiLoading: boolean = false;
  @Trace aiCanCancel: boolean = false;
  @Trace aiError: string = '';
  @Trace aiStreamingText: string = '';
  @Trace aiReasoningText: string = '';
  @Trace aiToolCalls: AiChatToolState[] = [];
  @Trace aiPendingSummary: string = '';
  @Trace aiPendingDetail: string = '';
  @Trace aiLastResult: string = '';
  @Trace aiCanUndo: boolean = false;
  @Trace pendingAiCommands: ParsedCommand[] = [];
  @Trace pendingAiContext: AiContext | null = null;
  @Trace aiCheckpointSummary: string = '';
  @Trace aiHasInterruptedCheckpoint: boolean = false;
  @Trace aiHasRecoverableArtifact: boolean = false;
  @Trace aiProjectNote: string = '';
  @Trace aiReviewGroups: AiReviewGroup[] = [];
  @Trace aiRunStartedAt: number = 0;
  @Trace aiSessionMode: 'agent' | 'readonly' = 'agent';
  @Trace aiMinimizedNotice: string = '';
}

export function connectDocumentDomainStore(): DocumentDomainStore {
  return AppStorageV2.connect(DocumentDomainStore, () => new DocumentDomainStore())!;
}

export function connectViewportSelectionStore(): ViewportSelectionStore {
  return AppStorageV2.connect(ViewportSelectionStore, () => new ViewportSelectionStore())!;
}

export function connectVerificationDomainStore(): VerificationDomainStore {
  return AppStorageV2.connect(VerificationDomainStore, () => new VerificationDomainStore())!;
}

export function connectPanelLayoutStore(): PanelLayoutStore {
  return AppStorageV2.connect(PanelLayoutStore, () => new PanelLayoutStore())!;
}

export function connectAiAssistantStore(): AiAssistantStore {
  return AppStorageV2.connect(AiAssistantStore, () => new AiAssistantStore())!;
}
