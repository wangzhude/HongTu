import { StableSegmentButton } from '../StableSegmentButton';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { DrcIssue, WorkModule } from '../../workbench/WorkbenchModels';
import { UiLayer, LayerGroup } from '../../common/types';
import { COLORS, formatZoomPercent, umText } from '../../common/constants';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { resetModifierKeys } from '../../common/ModifierKeys';
import { BLUR_BY_LAYER, RADIUS, withAlpha } from '../../common/MaterialTokens';
import { FONT_MONO } from '../../common/Fonts';
import {
  drcService, DrcViolation, DrcRule, DrcRuleType, DrcSeverity,
  // DRC 规则清单装载 / 分组统计的纯逻辑由 DrcService 统一转发（同一实现，host 可断言）
  typeLabel, unitLabel, DRC_RULE_CSV_HEADER, DRC_RULE_SOURCE_BUILTIN,
} from '../../services/DrcService';
import type { DrcGroupSummary, DrcRuleGroup, DrcRuleTextResult, DrcNoticeRow } from '../../services/DrcService';
import { Shape, ShapeType, getShapeBounds, getShapeArea } from '../../models/GdsiiData';
import { PropertyCellOption } from '../../services/ShapePropertyService';
import { ShapePropertiesPopover, InspectorLayerPatch } from './ShapePropertiesPopover';
import { RulesetSegment } from '../segments/RulesetSegment';
import { hongTuThemeState } from '../../store/ThemeStore';
import { DrawnStatusIcon } from '../DrawnStatusIcon';
import { WorkbenchIcon } from './WorkbenchIcon';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { feedbackCurve, MOTION } from '../../common/Motion';

/** 规则集显示名（用于副标题等纯字符串场景） */
const RULESET_NAMES: string[] = ['28nm默认', '14nm默认', '7nm默认', 'SKY130 M1子集', '自定义'];
/** 规则集对应工艺节点（传给 drcService.applyRuleset）；'custom' 表示自定义，不调用 applyRuleset */
const RULESET_PROCESSES: string[] = ['28nm', '14nm', '7nm', 'sky130-met1-public', 'custom'];

@Component
export struct WorkbenchInspector {
  @Prop currentModule: WorkModule = WorkModule.Layout;
  @Prop editable: boolean = true;
  /** Desktop B layout already shows layers in the left dock. */
  @Prop desktopCanvasFirst: boolean = false;
  @Prop layers: UiLayer[] = [];
  @Prop issues: DrcIssue[] = [];
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop selectedShapeId: number = -1;
  @Prop zoomPercent: number = 100;
  /** 当前高亮的违规 id（-1 表示无高亮） */
  @Prop highlightedViolationId: number = -1;
  /** 当前选中图形（null 表示无选中），供 PropertiesPanel 展示真实属性 */
  @Prop selectedShape: Shape | null = null;
  /** 最近一次 DRC 耗时（ms） */
  @Prop lastDrcElapsed: number = 0;
  /** 文档元信息（DataInspector 展示用） */
  @Prop docLibName: string = 'DEMO_LIB';
  @Prop docCellCount: number = 1;
  @Prop docElementCount: number = 0;
  @Prop docTopCellName: string = 'TOP';
  @Prop currentFilePath: string = '';
  /** 是否可见（父组件在 md/sm 抽屉态下控制；lg 内联态恒为 true） */
  @Prop visible: boolean = true;
  /** 检查器宽度（vp）：lg=panelWidth，md/sm 浮层抽屉=280，由父组件根据断点传入 */
  @Prop panelWidth: number = 296;
  @Prop documentId: string = '';
  @Prop revision: number = 0;
  @Prop selectedShapes: Shape[] = [];
  @Prop cells: PropertyCellOption[] = [];
  @Prop currentCellName: string = 'TOP';
  @Prop floatingPopoverEnabled: boolean = true;
  selectLayerAction: (layer: UiLayer) => void = () => {};
  toggleLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  runDrcAction: () => void = () => {};
  drcConfigurationChangedAction: () => void = () => {};
  locateIssueAction: (issue: DrcIssue) => void = () => {};
  openFileAction: () => void = () => {};
  quickScanAction: () => void = () => {};
  onShapePropertySubmit: (shapeId: number, property: string, value: string) => void = () => {};
  onPropertiesSubmit: ((ids: number[], property: string, value: string, documentId: string, revision: number) => string) | null = null;
  toggleFloatingPopoverAction: (() => void) | null = null;
  collapseInspectorAction: () => void = () => {};
  copyAction: () => void = () => {};
  duplicateAction: (() => void) | null = null;
  deleteAction: () => void = () => {};
  openArrayAction: (() => void) | null = null;
  applyInlineArrayAction: ((rows: number, cols: number, pitchXNm: number, pitchYNm: number) => boolean) | null = null;
  booleanAction: ((op: 'merge' | 'subtract' | 'intersect' | 'xor') => void) | null = null;
  changeSelectionLayerAction: ((layerNumber: number, datatype: number) => void) | null = null;
  selectActiveLayerAction: ((layerNumber: number, datatype: number) => void) | null = null;
  updateLayerStyleAction: ((layerNumber: number, datatype: number, patch: InspectorLayerPatch) => void) | null = null;
  moveSelectedByAction: ((dxNm: number, dyNm: number) => void) | null = null;
  enterInstanceAction: (() => void) | null = null;
  flattenInstanceAction: (() => void) | null = null;
  returnCanvasFocusAction: () => void = () => {};
  saveShortcutAction: ((saveAs: boolean) => void) | null = null;

  build() {
    Column() {
      if (this.currentModule === WorkModule.Layout) {
        ShapePropertiesPopover({
          docked: true,
          allowEmptySelection: true,
          pinned: true,
          floatingEnabled: this.floatingPopoverEnabled,
          toggleFloatingAction: this.toggleFloatingPopoverAction,
          closeAction: this.collapseInspectorAction,
          documentId: this.documentId,
          revision: this.revision,
          selectedShape: this.selectedShape,
          selectedShapes: this.selectedShapes,
          layers: this.layers,
          cells: this.cells,
          currentCellName: this.currentCellName,
          activeLayerNumber: this.selectedLayerNumber,
          activeDatatype: this.selectedDatatype,
          editable: this.editable,
          onShapePropertySubmit: this.onShapePropertySubmit,
          onPropertiesSubmit: this.onPropertiesSubmit,
          copyAction: this.copyAction,
          duplicateAction: this.duplicateAction,
          deleteAction: this.deleteAction,
          openArrayAction: this.openArrayAction,
          applyInlineArrayAction: this.applyInlineArrayAction,
          booleanAction: this.booleanAction,
          changeSelectionLayerAction: this.changeSelectionLayerAction,
          selectActiveLayerAction: this.selectActiveLayerAction,
          updateLayerStyleAction: this.updateLayerStyleAction,
          moveSelectedByAction: this.moveSelectedByAction,
          enterInstanceAction: this.enterInstanceAction,
          flattenInstanceAction: this.flattenInstanceAction,
          returnCanvasFocusAction: this.returnCanvasFocusAction,
          saveShortcutAction: this.saveShortcutAction
        })
      } else if (this.currentModule === WorkModule.Verify) {
        DrcInspector({
          issues: this.issues,
          runDrcAction: this.runDrcAction,
          drcConfigurationChangedAction: this.drcConfigurationChangedAction,
          locateIssueAction: this.locateIssueAction,
          highlightedViolationId: this.highlightedViolationId,
          lastDrcElapsed: this.lastDrcElapsed
        })
      } else {
        DataInspector({
          openFileAction: this.openFileAction,
          quickScanAction: this.quickScanAction,
          docLibName: this.docLibName,
          docCellCount: this.docCellCount,
          docElementCount: this.docElementCount,
          docTopCellName: this.docTopCellName,
          currentFilePath: this.currentFilePath
        })
      }
    }
    .width(this.panelWidth)
    .height('100%')
    .backgroundColor(hongTuThemeState.isLuminousBackgroundEnabled()
      ? hongTuThemeState.luminous.translucentCardColor
      : COLORS.surface)
    .border({ width: { left: 0.8 }, color: COLORS.border })
    .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}

@Component
struct LayerInspector {
  @Prop layers: UiLayer[] = [];
  @Prop editable: boolean = true;
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop selectedShapeId: number = -1;
  @Prop zoomPercent: number = 100;
  @Prop selectedShape: Shape | null = null;
  selectLayerAction: (layer: UiLayer) => void = () => {};
  toggleLayerAction: (layerNumber: number, datatype: number) => void = () => {};
  onShapePropertySubmit: (shapeId: number, property: string, value: string) => void = () => {};

  build() {
    Column() {
      PanelHeader({ title: '图层管理', subtitle: '' })

      List() {
        ForEach(this.layers, (layer: UiLayer) => {
          ListItem() {
            LayerRow({
              layer: layer,
              elementCount: layer.elementCount,
              selectedLayerNumber: this.selectedLayerNumber,
          selectedDatatype: this.selectedDatatype,
              selectLayerAction: this.selectLayerAction,
              toggleLayerAction: this.toggleLayerAction
            })
          }
        }, (layer: UiLayer) => `${layer.layerNumber}:${layer.datatype}`)
      }
      .layoutWeight(1)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      Divider().color(COLORS.border)

      PropertiesPanel({
        selectedShapeId: this.selectedShapeId,
        editable: this.editable,
        selectedLayerNumber: this.selectedLayerNumber,
          selectedDatatype: this.selectedDatatype,
        zoomPercent: this.zoomPercent,
        selectedShape: this.selectedShape,
        onShapePropertySubmit: this.onShapePropertySubmit
      })
    }
    .width('100%')
    .height('100%')
  }


}

/** Independent desktop rule configuration; result rows stay in DrcResultsDock. */
@Component
export struct DrcRulesPopover {
  @Prop issues: DrcIssue[] = [];
  @Prop highlightedViolationId: number = -1;
  @Prop lastDrcElapsed: number = 0;
  @Prop panelHeight: number = 560;
  runDrcAction: () => void = () => {};
  drcConfigurationChangedAction: () => void = () => {};
  locateIssueAction: (issue: DrcIssue) => void = () => {};
  closeAction: () => void = () => {};

  build() {
    Column() {
      PanelHeading({ title: '规则设置', subtitle: '', canClose: true, closeAction: this.closeAction })
        .padding({ left: UI.panelPadding, right: UI.panelPadding, top: 12 })
      DrcInspector({
        issues: this.issues,
        highlightedViolationId: this.highlightedViolationId,
        lastDrcElapsed: this.lastDrcElapsed,
        rulesOnly: true,
        runDrcAction: this.runDrcAction,
        drcConfigurationChangedAction: this.drcConfigurationChangedAction,
        locateIssueAction: this.locateIssueAction
      })
      .layoutWeight(1)
      Row() {
        Text('配置变更后自动重新检查')
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .layoutWeight(1)
        Button('检查当前版图', { type: ButtonType.Normal })
          .focusable(false)
          .fontSize(UI.fontBody)
          .fontColor(Color.White)
          .height(UI.controlHeight)
          .padding({ left: 14, right: 14 })
          .backgroundColor(COLORS.primary)
          .borderRadius(UI.controlRadius)
          .onClick(this.runDrcAction)
      }
      .width('100%')
      .height(64)
      .padding({ left: 16, right: 16 })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(400)
    .height(this.panelHeight)
    .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
    .clip(true)
    .onKeyEvent((event: KeyEvent) => {
      event.stopPropagation();
    })
  }
}

@Component
struct DrcInspector {
  @StorageProp('hongtuReduceMotion') reduceMotion: boolean = false;
  /** A desktop popover reuses the same rule controls without duplicating results. */
  @Prop rulesOnly: boolean = false;
  @Prop @Watch('onIssuesChanged') issues: DrcIssue[] = [];
  runDrcAction: () => void = () => {};
  drcConfigurationChangedAction: () => void = () => {};
  locateIssueAction: (issue: DrcIssue) => void = () => {};
  @Prop highlightedViolationId: number = -1;
  @Prop lastDrcElapsed: number = 0;
  /** DRC 正在执行中（显示加载指示器） */
  @State isDrcRunning: boolean = false;
  /** DRC 防抖定时器 */
  private drcDebounceTimer: number = -1;
  /** 规则配置面板折叠状态 */
  @State rulesConfigExpanded: boolean = false;
  /** 当前生效规则缓存（规则集切换后刷新） */
  @State rules: DrcRule[] = [];
  /** 当前选中的规则集下标 */
  @State selectedRulesetIndex: number = 0;
  /** 规则集版本号，用于强制 ForEach 重建规则行（刷新本地状态） */
  @State rulesetVersion: number = 0;
  @State drcConfigStatus: string = '';
  /** 高级参数面板折叠状态 */
  @State advancedParamsExpanded: boolean = false;
  /** 深度模式开关状态（镜像 drcService.deepMode） */
  @State deepModeOn: boolean = false;
  /** DRC 层级展开深度（镜像 drcService.hierarchyDepth）：0=仅本 Cell 本地几何 */
  @State hierarchyDepth: number = 1;
  /** 可选展开深度档位（native 上限 16 层，UI 只暴露常用档） */
  private readonly depthChoices: number[] = [0, 1, 2, 3];
  /** 分块模式开关状态（镜像 drcService.tilingEnabled） */
  @State tilingOn: boolean = false;
  /** 分块大小输入文本（镜像 drcService.tileSize） */
  @State tileSizeText: string = '1000';
  /** 规则过滤输入文本（镜像 drcService.ruleFilter） */
  @State ruleFilterText: string = '';
  /** 只筛选配置表显示，不改变服务的执行过滤或当前规则集。 */
  @State ruleSearchText: string = '';
  /** 规则文件列表（镜像 drcService.getRuleFiles()） */
  @State ruleFiles: string[] = [];
  /** 新增规则文件路径输入 */
  @State newRuleFilePath: string = '';
  /** 规则来源（镜像 drcService.getRuleSource()）：'builtin' = 内置预设 / 'custom' = 自定义 */
  @State ruleSourceKind: string = DRC_RULE_SOURCE_BUILTIN;
  /** 规则来源显示文案（如「内置 · 28nm默认」「自定义 · 我的工艺 · 含手工调整」） */
  @State ruleSourceTextValue: string = '';
  /** 自定义规则清单文本（粘贴 / 从文件读入后编辑） */
  @State ruleSetText: string = '';
  /** 清单装载结果文案：'' = 未提示；失败时为可显示的中文错误 */
  @State ruleSetTextMsg: string = '';
  /** 上一次装载是否失败（决定上面文案用危险色还是主色） */
  @State ruleSetTextFailed: boolean = false;
  /** 「按规则分组」统计折叠状态 */
  @State ruleGroupsExpanded: boolean = true;
  /**
   * 最近一次 DRC 的分规则统计快照（一次 DRC 结束 = 父组件刷新 issues 时回读一次）。
   * 拆成平铺字段而不是存 DrcGroupSummary 对象：ArkTS 不对 `this.x.y` 做 null 收窄，
   * 判空必须先提到局部变量，平铺后渲染期根本不需要解引用可空对象。
   */
  @State groupRanOnce: boolean = false;
  @State groupRows: DrcRuleGroup[] = [];
  @State groupUnknown: DrcRuleGroup[] = [];
  @State groupNotices: DrcNoticeRow[] = [];
  @State groupHitRules: number = 0;
  @State groupZeroHitRules: number = 0;
  @State groupRuleViolations: number = 0;
  @State groupErrors: number = 0;
  @State groupWarnings: number = 0;
  @State groupNoticeCount: number = 0;
  @State groupPassed: boolean = true;
  @State groupScopeNote: string = '';

  aboutToAppear(): void {
    if (this.rulesOnly) {
      this.rulesConfigExpanded = true;
    }
    this.rules = drcService.getRules();
    this.deepModeOn = drcService.deepMode;
    this.hierarchyDepth = drcService.hierarchyDepth;
    this.tilingOn = drcService.tilingEnabled;
    this.tileSizeText = drcService.tileSize.toString();
    this.ruleFilterText = drcService.ruleFilter;
    this.ruleFiles = drcService.getRuleFiles().slice();
    this.syncRuleSource();
    this.refreshGroupSummary();
  }

  /** 父组件刷新 issues（= 一次 DRC 结束）后回读分组与来源，面板不自己猜口径 */
  onIssuesChanged(): void {
    this.refreshGroupSummary();
    this.syncRuleSource();
    this.ruleFiles = drcService.getRuleFiles().slice();
  }

  /** 从 drcService 回读分组统计（null = 本次会话尚未运行 DRC） */
  private refreshGroupSummary(): void {
    const summary: DrcGroupSummary | null = drcService.getRuleGroups();
    if (summary === null) {
      this.groupRanOnce = false;
      this.groupRows = [];
      this.groupUnknown = [];
      this.groupNotices = [];
      this.groupHitRules = 0;
      this.groupZeroHitRules = 0;
      this.groupRuleViolations = 0;
      this.groupErrors = 0;
      this.groupWarnings = 0;
      this.groupNoticeCount = 0;
      this.groupPassed = true;
      this.groupScopeNote = '';
      return;
    }
    this.groupRanOnce = true;
    this.groupRows = summary.groups;
    this.groupUnknown = summary.unknown;
    this.groupNotices = summary.notices;
    this.groupHitRules = summary.hitRuleCount;
    this.groupZeroHitRules = summary.zeroHitRuleCount;
    this.groupRuleViolations = summary.ruleViolationCount;
    this.groupErrors = summary.errorCount;
    this.groupWarnings = summary.warningCount;
    this.groupNoticeCount = summary.noticeCount;
    this.groupPassed = summary.passed;
    this.groupScopeNote = summary.scopeNote;
  }

  /** 从服务回读规则来源（装载 / 切预设 / 恢复内置后都要调，避免面板自己猜） */
  private syncRuleSource(): void {
    this.ruleSourceKind = drcService.getRuleSource();
    this.ruleSourceTextValue = drcService.ruleSourceText();
    // Both inspector and popover reflect the actual source, not an initial preset.
    if (!drcService.isBuiltinRuleSource()) {
      this.selectedRulesetIndex = RULESET_NAMES.length - 1;
    } else {
      const index: number = RULESET_NAMES.findIndex((name: string) => name === drcService.ruleSourceLabel);
      this.selectedRulesetIndex = index >= 0 ? index : RULESET_NAMES.length - 1;
    }
  }

  /** 规则改动后的统一收口：刷新规则表 + 来源 + 触发重检 */
  private afterRulesChanged(): void {
    this.rules = drcService.getRules();
    this.rulesetVersion++;
    this.syncRuleSource();
    this.debouncedRunDrc();
  }

  /**
   * 装载「规则清单」文本框的内容（替换 / 合并）。
   * 失败时**不改规则集**（服务保证），这里只把中文 error 显示出来。
   */
  private loadRuleSetText(merge: boolean): void {
    const result: DrcRuleTextResult = drcService.loadRulesFromText(this.ruleSetText, merge);
    if (!result.ok) {
      this.ruleSetTextFailed = true;
      this.ruleSetTextMsg = result.error;
      this.drcConfigStatus = '规则清单装载失败，仍在使用原有规则';
      return;
    }
    this.ruleSetTextFailed = false;
    const warn: string = result.warnings.length > 0
      ? `；${result.warnings.length} 条提示：${result.warnings[0]}` : '';
    this.ruleSetTextMsg = `已装载 ${result.rules.length} 条规则（${result.format === 'json' ? 'JSON' : 'CSV'} 格式）${warn}`;
    this.drcConfigStatus = `规则来源已切换为自定义：${result.setName}`;
    this.afterRulesChanged();
  }

  /** 把当前生效规则导出成清单文本填回输入框（改数值再装载，不必手抄） */
  private exportRuleSetText(): void {
    this.ruleSetText = drcService.rulesAsText();
    this.ruleSetTextFailed = false;
    this.ruleSetTextMsg = `已把当前 ${this.rules.length} 条规则写成清单文本，编辑后点「装载（替换）」`;
  }

  /** 恢复内置预设（行为与未装清单时一致） */
  private restoreBuiltinRules(): void {
    drcService.resetRulesToBuiltin();
    this.ruleSetTextFailed = false;
    this.ruleSetTextMsg = '已恢复内置预设规则集';
    this.drcConfigStatus = '规则来源：内置预设';
    this.selectedRulesetIndex = 0;
    this.afterRulesChanged();
  }

  /**
   * 定位到某条规则的首个命中。
   * DrcIssue 目前不带 ruleId（见交接文档），这里按「显示名」回查违规行；
   * 回查不到时如实提示，不假装定位成功。
   */
  private locateGroupSample(group: DrcRuleGroup): void {
    for (let i = 0; i < this.issues.length; i++) {
      const issue = this.issues[i];
      if (issue.ruleName === group.ruleName) {
        this.locateIssueAction(issue);
        return;
      }
    }
    this.drcConfigStatus = `未在违规列表中找到「${group.ruleName}」的行（可能已被新的检查覆盖）`;
  }

  build() {
    if (this.rulesOnly) {
      Scroll() {
        Column() {
          if (this.drcConfigStatus.length > 0) {
            Text(this.drcConfigStatus)
              .fontSize(11)
              .fontColor(COLORS.accent)
              .padding({ left: 14, right: 14, top: 10, bottom: 8 })
              .width('100%')
          }
          this.RuleConfiguration()
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
      .align(Alignment.Top)
    } else {
      this.InspectorBody()
    }
  }

  @Builder
  private RuleConfiguration() {
      // Desktop already has a panel title; keep the collapsible header in the dock.
      if (!this.rulesOnly) {
      Row() {
        Text('规则配置')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
        WorkbenchIcon({ name: 'chevronDown', iconSize: 12, color: COLORS.muted })
          .animation(null)
          .rotate({ angle: this.rulesConfigExpanded ? 180 : 0 })
          .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
        Text(this.rulesConfigExpanded ? '收起' : '展开')
          .fontSize(11)
          .fontColor(COLORS.muted)
          .margin({ left: 4 })
      }
      .width('100%')
      .height(40)
      .padding({ left: 14, right: 14 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: { top: 1, bottom: 1 }, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .onClick(() => {
        this.rulesConfigExpanded = !this.rulesConfigExpanded;
      })
      }

      if (this.rulesConfigExpanded) {
        // 规则集选择：原生 SegmentButton 替代手写 Text 按钮组（Select 在部分预览/设备上只渲染箭头）。
        Column() {
          if (!this.rulesOnly) {
          Text('规则集')
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.muted)
          }
          RulesetSegment({
            paletteKey: `${COLORS.primary}:${COLORS.surfaceMuted}:${COLORS.ink}`,
            current: this.selectedRulesetIndex,
            onChange: (index: number) => {
              this.selectRuleset(index);
            }
          })
            .width('100%')
            .margin({ top: this.rulesOnly ? 0 : 6 })
        }
        .width('100%')
        .padding({ left: UI.panelPadding, right: UI.panelPadding, top: 8, bottom: 12 })
        .alignItems(HorizontalAlign.Start)

        if (this.rulesOnly) {
          this.DesktopRuleTable()
        }

        // 规则来源（内置 / 自定义）：跑的是哪一组规则必须可见、可一键切回内置预设
        Column() {
          Row() {
            Text('规则来源')
              .fontSize(11)
              .fontColor(COLORS.muted)
              .layoutWeight(1)
            Text(this.ruleSourceKind === DRC_RULE_SOURCE_BUILTIN ? '内置' : '自定义')
              .fontSize(UI.fontCaption)
              .fontColor(this.ruleSourceKind === DRC_RULE_SOURCE_BUILTIN
                ? COLORS.success : COLORS.primary)
              .backgroundColor(this.ruleSourceKind === DRC_RULE_SOURCE_BUILTIN
                ? withAlpha(COLORS.success, 0.1) : COLORS.primarySoft)
              .borderRadius(UI.controlRadius)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            Button('恢复内置', { type: ButtonType.Normal })
              .fontSize(11)
              .fontColor(COLORS.accent)
              .height(UI.compactControlHeight)
              .padding({ left: 6, right: 6 })
              .backgroundColor(Color.Transparent)
              .borderRadius(UI.controlRadius)
              .margin({ left: 8 })
              .onClick(() => {
                this.restoreBuiltinRules();
              })
          }
          .width('100%')

          Text(this.ruleSourceTextValue)
            .fontSize(UI.fontCaption)
            .fontColor(COLORS.muted)
            .width('100%')
            .maxLines(2)
            .margin({ top: 2 })
        }
        .width('100%')
        .padding({ left: UI.panelPadding, right: UI.panelPadding, top: 8, bottom: 12 })
        .alignItems(HorizontalAlign.Start)

        // 高级参数折叠头
        Column() {
        Row() {
          Text('高级参数')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.ink)
            .layoutWeight(1)
          WorkbenchIcon({ name: 'chevronDown', iconSize: 12, color: COLORS.muted })
            .animation(null)
            .rotate({ angle: this.advancedParamsExpanded ? 180 : 0 })
            .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
          Text(this.advancedParamsExpanded ? '收起' : '展开')
            .fontSize(11)
            .fontColor(COLORS.muted)
            .margin({ left: 4 })
        }
        .width('100%')
        .height(44)
        .padding({ left: 12, right: 12 })
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)
        .onClick(() => {
          this.advancedParamsExpanded = !this.advancedParamsExpanded;
        })
        }
        .width('100%')
        .padding({ left: UI.panelPadding, right: UI.panelPadding, top: 4, bottom: 12 })

        if (this.advancedParamsExpanded) {
          Column() {
            // 深度模式
            Row() {
              Text('深度模式')
                .fontSize(12)
                .fontColor(COLORS.ink)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.deepModeOn })
                .selectedColor(COLORS.primary)
                .height(28)
                .onChange((isOn: boolean) => {
                  if (isOn === this.deepModeOn) return;
                  this.deepModeOn = isOn;
                  drcService.setDeepMode(isOn);
                  this.drcConfigStatus = `深度模式已${isOn ? '开启' : '关闭'}，并重新检查`;
                  this.debouncedRunDrc();
                })
            }
            .width('100%')
            .height(44)

            // 层级展开深度：native DRC 把实例内几何变换到本 Cell 后再测量（对齐 KLayout flattened）
            Column({ space: 6 }) {
              Text('展开层级')
                .fontSize(12)
                .fontColor(COLORS.ink)
                .width('100%')
              StableSegmentButton({
                items: [
                  { text: this.depthLabel(0) },
                  { text: this.depthLabel(1) },
                  { text: this.depthLabel(2) },
                  { text: this.depthLabel(3) }
                ] as [
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem,
                  SegmentButtonTextItem
                ] as SegmentButtonItemTuple,
                selectedIndex: Math.max(0, this.depthChoices.indexOf(this.hierarchyDepth)),
                onItemClicked: (idx: number) => {
                  if (idx >= 0 && idx < this.depthChoices.length) {
                    this.applyHierarchyDepth(this.depthChoices[idx]);
                  }
                },
                fontColor: COLORS.muted,
                selectedFontColor: COLORS.primary,
                capsuleBackgroundColor: COLORS.surfaceMuted,
                selectedBackgroundColor: COLORS.primarySoft,
                fontSizeFp: 11,
                capsuleBorderRadius: UI.controlRadius,
                buttonMinHeight: 32,
                itemMinHeight: 26,
                itemPaddingHorizontal: 6
              })
            }
            .width('100%')
            .padding({ top: 4, bottom: 4 })

            // 分块模式
            Row() {
              Text('分块模式')
                .fontSize(12)
                .fontColor(COLORS.ink)
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.tilingOn })
                .selectedColor(COLORS.primary)
                .height(28)
                .onChange((isOn: boolean) => {
                  if (isOn === this.tilingOn) return;
                  this.tilingOn = isOn;
                  drcService.setTilingEnabled(isOn);
                  this.drcConfigStatus = `分块模式已${isOn ? '开启' : '关闭'}，并重新检查`;
                  this.debouncedRunDrc();
                })
              TextInput({ text: this.tileSizeText, placeholder: '块大小' })
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .type(InputType.Number)
                .height(40)
                .width(72)
                .fontSize(13)
                .padding({ left: 6, right: 6 })
                .backgroundColor(COLORS.surfaceMuted)
                .borderRadius(UI.controlRadius)
                .margin({ left: 8 })
                .onChange((val: string) => {
                  this.tileSizeText = val;
                })
                .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => {
                  this.applyTileSize(event.text);
                })
              Text('nm')
                .fontSize(10)
                .fontColor(COLORS.muted)
                .width(22)
                .textAlign(TextAlign.Start)
                .margin({ left: 4 })
              Button('应用', { type: ButtonType.Normal })
                .fontSize(11)
                .fontColor(COLORS.accent)
                .width(40)
                .height(UI.compactControlHeight)
                .padding(0)
                .backgroundColor(Color.Transparent)
                .borderRadius(UI.controlRadius)
                .onClick(() => {
                  this.applyTileSize(this.tileSizeText);
                })
            }
            .width('100%')
            .height(52)

            // 规则过滤
            Row() {
              Text('规则过滤')
                .fontSize(12)
                .fontColor(COLORS.ink)
                .width(56)
              Search({ value: this.ruleFilterText, placeholder: '按规则名关键字过滤' })
                .height(40)
                .layoutWeight(1)
                .textFont({ size: 13 })
                .placeholderFont({ size: 12 })
                .fontColor(COLORS.ink)
                .placeholderColor(COLORS.muted)
                .searchIcon({ size: 15, color: COLORS.muted })
                .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 13, color: COLORS.muted } })
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .onChange((val: string) => {
                  this.ruleFilterText = val;
                  if (val.length === 0 && drcService.getRuleFilter().length > 0) {
                    drcService.setRuleFilter('');
                    this.drcConfigStatus = '规则过滤已清空，并重新检查';
                    this.debouncedRunDrc();
                  }
                })
                .onSubmit((value: string) => {
                  this.ruleFilterText = value;
                  drcService.setRuleFilter(value);
                  this.drcConfigStatus = `规则过滤已更新：${value.length === 0 ? '（空）' : value}，并重新检查`;
                  this.debouncedRunDrc();
                })
            }
            .width('100%')
            .height(44)

            // 规则文件
            Row() {
              Text('规则文件')
                .fontSize(12)
                .fontColor(COLORS.ink)
                .width(56)
              Text(`${this.ruleFiles.length} 个`)
                .fontSize(11)
                .fontColor(COLORS.muted)
                .layoutWeight(1)
            }
            .width('100%')
            .height(28)

            if (this.ruleFiles.length > 0) {
              Column() {
                ForEach(this.ruleFiles, (path: string) => {
                  Row() {
                    Text(path)
                      .fontSize(11)
                      .fontColor(COLORS.ink)
                      .layoutWeight(1)
                      .maxLines(1)
                    Button({ type: ButtonType.Normal }) {
                      WorkbenchIcon({ name: 'close', iconSize: 13, color: COLORS.danger })
                    }
                      .width(28)
                      .height(26)
                      .padding(0)
                      .backgroundColor(withAlpha(COLORS.danger, 0.12))
                      .borderRadius(UI.controlRadius)
                      .accessibilityText('移除规则文件')
                      .onClick(() => {
                        drcService.removeRuleFile(path);
                        this.ruleFiles = drcService.getRuleFiles().slice();
                        this.drcConfigStatus = `已移除规则文件：${path}`;
                        // 移除后规则集真的变了（服务会重建基准集 + 剩余文件），面板跟着刷新
                        this.afterRulesChanged();
                      })
                  }
                  .width('100%')
                  .height(26)
                }, (path: string) => path)
              }
              .width('100%')
              .padding({ left: 56, right: 4 })
              .alignItems(HorizontalAlign.Start)
            }

            // 添加规则文件（内联输入）
            Row() {
              TextInput({ text: this.newRuleFilePath, placeholder: '输入规则文件路径' })
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .type(InputType.Normal)
                .height(36)
                .fontSize(12)
                .padding({ left: 8, right: 8 })
                .layoutWeight(1)
                .backgroundColor(COLORS.surfaceMuted)
                .borderRadius(UI.controlRadius)
                .onChange((val: string) => {
                  this.newRuleFilePath = val;
                })
                .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => {
                  this.addRuleFileFromInput(event.text);
                  event.keepEditableState();
                })
              Button('添加', { type: ButtonType.Normal })
                .fontSize(11)
                .fontColor(Color.White)
                .height(UI.compactControlHeight)
                .padding({ left: 10, right: 10 })
                .backgroundColor(COLORS.accent)
                .borderRadius(UI.controlRadius)
                .margin({ left: 6 })
                .onClick(() => {
                  this.addRuleFileFromInput(this.newRuleFilePath);
                })
            }
            .width('100%')
            .height(40)

            Divider().color(COLORS.border).margin({ top: 6, bottom: 6 })

            // 规则清单（粘贴 JSON / CSV 风格清单）：失败只显示中文错误，不动当前规则集
            Column() {
              Row() {
                Text('规则清单（粘贴）')
                  .fontSize(12)
                  .fontColor(COLORS.ink)
                  .layoutWeight(1)
                Button('导出现有为文本', { type: ButtonType.Normal })
                  .fontSize(11)
                  .fontColor(COLORS.accent)
                  .height(UI.compactControlHeight)
                  .padding({ left: 6, right: 6 })
                  .backgroundColor(Color.Transparent)
                  .borderRadius(UI.controlRadius)
                  .onClick(() => {
                    this.exportRuleSetText();
                  })
              }
              .width('100%')

              TextArea({
                text: this.ruleSetText,
                placeholder: 'JSON：{"name":"我的工艺","rules":[{"id":"MW_M1","type":"width","layer":"M1","min":90}]}\n'
                  + 'CSV：' + DRC_RULE_CSV_HEADER,
              })
                .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
                .fontSize(10)
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .borderRadius(UI.controlRadius)
                .height(88)
                .width('100%')
                .margin({ top: 4 })
                .onChange((val: string) => {
                  this.ruleSetText = val;
                })

              Row() {
                Button('装载（替换）', { type: ButtonType.Normal })
                  .fontSize(11)
                  .fontColor(Color.White)
                  .height(UI.compactControlHeight)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(COLORS.primary)
                  .borderRadius(UI.controlRadius)
                  .onClick(() => {
                    this.loadRuleSetText(false);
                  })
                Button('装载（合并）', { type: ButtonType.Normal })
                  .fontSize(11)
                  .fontColor(COLORS.ink)
                  .height(UI.compactControlHeight)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(COLORS.surfaceMuted)
                  .borderRadius(UI.controlRadius)
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.loadRuleSetText(true);
                  })
                Blank()
              }
              .width('100%')
              .margin({ top: 6 })

              if (this.ruleSetTextMsg.length > 0) {
                Text(this.ruleSetTextMsg)
                  .fontSize(10)
                  .fontColor(this.ruleSetTextFailed ? COLORS.danger : COLORS.success)
                  .width('100%')
                  .lineHeight(14)
                  .margin({ top: 4 })
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .alignItems(HorizontalAlign.Start)
        }

        // The compact dock keeps its existing virtualized rules list.
        if (!this.rulesOnly) {
          List() {
            ForEach(this.rules, (rule: DrcRule) => {
              ListItem() {
                DrcRuleRow({
                  rule: rule,
                  runDrcAction: this.runDrcAction,
                  statusAction: (status: string) => {
                    this.drcConfigStatus = status;
                  },
                  onRuleModified: () => {
                    this.selectedRulesetIndex = RULESET_NAMES.length - 1;
                    this.syncRuleSource();
                  }
                })
              }
            }, (rule: DrcRule) => `${rule.id}_${this.rulesetVersion}`)
          }
          .layoutWeight(1)
          .width('100%')
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(true)
          .divider({ strokeWidth: 1, color: COLORS.border })
        }

        Divider().color(COLORS.border)
      }

  }

  /** Local configuration lookup; execution still uses drcService.ruleFilter. */
  private visibleRuleRows(): DrcRule[] {
    const query: string = this.ruleSearchText.trim().toLowerCase();
    if (query.length === 0) {
      return this.rules;
    }
    return this.rules.filter((rule: DrcRule) => {
      const text: string = `${rule.name} ${rule.id} ${typeLabel(rule.type)} L${rule.layerNumber} ${rule.description}`;
      return text.toLowerCase().includes(query);
    });
  }

  @Builder
  private DesktopRuleTable() {
    Column({ space: 10 }) {
      Search({ value: this.ruleSearchText, placeholder: '搜索规则（名称、类型、层号）' })
        .width('100%')
        .height(UI.fieldHeight)
        .textFont({ size: UI.fontBody })
        .placeholderFont({ size: UI.fontBody })
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .searchIcon({ size: 16, color: COLORS.muted })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { size: 14, color: COLORS.muted } })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .onChange((value: string) => {
          this.ruleSearchText = value;
        })

      if (this.ruleSearchText.length > 0) {
        Text(`显示 ${this.visibleRuleRows().length} / ${this.rules.length} 条 · 仅筛选显示`)
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .width('100%')
      }

      Column() {
        Row({ space: 6 }) {
          Text('启用').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(24)
          Text('规则名称').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
          Text('层').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(56)
          Text('阈值').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(62)
          Text('单位').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(26)
          Blank().width(32)
        }
        .width('100%')
        .height(36)
        .padding({ left: 10, right: 10 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: { bottom: 1 }, color: COLORS.border })

        if (this.rules.length === 0) {
          Column() {
            Text('暂无可执行规则')
              .fontSize(UI.fontBody)
              .fontColor(COLORS.muted)
          }
          .width('100%')
          .height(84)
          .justifyContent(FlexAlign.Center)
        } else if (this.visibleRuleRows().length === 0) {
          Column() {
            Text('无匹配规则')
              .fontSize(UI.fontBody)
              .fontColor(COLORS.muted)
          }
          .width('100%')
          .height(84)
          .justifyContent(FlexAlign.Center)
        } else {
          ForEach(this.visibleRuleRows(), (rule: DrcRule) => {
            DrcRuleRow({
              rule: rule,
              tableLayout: true,
              runDrcAction: this.runDrcAction,
              statusAction: (status: string) => {
                this.drcConfigStatus = status;
              },
              onRuleModified: () => {
                this.selectedRulesetIndex = RULESET_NAMES.length - 1;
                this.syncRuleSource();
              }
            })
          }, (rule: DrcRule) => `${rule.id}_${this.rulesetVersion}`)
        }
      }
      .width('100%')
      .border({ width: 1, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .clip(true)
    }
    .width('100%')
    .padding({ left: UI.panelPadding, right: UI.panelPadding, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private InspectorBody() {
    Column() {
      PanelHeader({ title: 'DRC 验证', subtitle: this.currentSubtitle() })

      Row() {
        StatCard({ label: '总数', value: this.issues.length.toString(), colorValue: COLORS.accent })
        StatCard({ label: '错误', value: this.errorCount().toString(), colorValue: COLORS.danger })
        StatCard({ label: '警告', value: this.warningCount().toString(), colorValue: COLORS.warning })
      }
      .padding({ left: 12, right: 12, bottom: 10 })

      Text(`最近一次检查耗时 ${this.lastDrcElapsed}ms`)
        .fontSize(12)
        .fontColor(COLORS.muted)
        .padding({ left: 14, bottom: 8 })
        .width('100%')
      if (this.drcConfigStatus.length > 0) {
        Text(this.drcConfigStatus)
          .fontSize(11)
          .fontColor(COLORS.accent)
          .padding({ left: 14, right: 14, bottom: 8 })
          .width('100%')
          .maxLines(2)
      }

      this.RuleConfiguration()

      // 按规则分组统计（KLayout 口径：每条规则一行、0 命中也列出；TRUNC / NOHIER 另列且不计命中）
      Row() {
        Text('按规则分组')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink)
          .layoutWeight(1)
        Text(this.groupRanOnce
          ? `${this.groupHitRules} 命中 · ${this.groupZeroHitRules} 未命中`
          : '未运行')
          .fontSize(11)
          .fontColor(this.groupRanOnce && this.groupErrors > 0 ? COLORS.danger : COLORS.muted)
          .margin({ right: 6 })
        WorkbenchIcon({ name: 'chevronDown', iconSize: 12, color: COLORS.muted })
          .animation(null)
          .rotate({ angle: this.ruleGroupsExpanded ? 180 : 0 })
          .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
      }
      .width('100%')
      .height(36)
      .padding({ left: 14, right: 14 })
      .backgroundColor(COLORS.surfaceMuted)
      .border({ width: { top: 1, bottom: 1 }, color: COLORS.border })
      .borderRadius(UI.controlRadius)
      .onClick(() => {
        this.ruleGroupsExpanded = !this.ruleGroupsExpanded;
      })

      if (this.ruleGroupsExpanded) {
        DrcRuleGroupTable({
          ranOnce: this.groupRanOnce,
          rows: this.groupRows,
          unknown: this.groupUnknown,
          notices: this.groupNotices,
          hitRules: this.groupHitRules,
          zeroHitRules: this.groupZeroHitRules,
          ruleViolations: this.groupRuleViolations,
          errors: this.groupErrors,
          warnings: this.groupWarnings,
          noticeCount: this.groupNoticeCount,
          passed: this.groupPassed,
          scopeNote: this.groupScopeNote,
          locateGroupAction: (group: DrcRuleGroup) => {
            this.locateGroupSample(group);
          }
        })
      }

      // 违规列表标题
      Row() {
        Text('违规列表')
          .fontSize(12)
          .fontColor(COLORS.muted)
          .fontWeight(FontWeight.Medium)
        Text(`${this.issues.length} 项`)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .margin({ left: 6 })
      }
      .width('100%')
      .padding({ left: 14, top: 8, bottom: 6 })

      Stack() {
        List() {
          ForEach(this.issues, (issue: DrcIssue) => {
            ListItem() {
              DrcIssueRow({
                issue: issue,
                locateIssueAction: this.locateIssueAction,
                highlightedViolationId: this.highlightedViolationId
              })
            }
          }, (issue: DrcIssue) => issue.key())
        }
        .layoutWeight(1)
        .width('100%')
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)

        // DRC 执行中加载指示器
        if (this.isDrcRunning) {
          Column() {
            LoadingProgress()
              .width(28)
              .height(28)
              .color(COLORS.primary)
            Text('检查中...')
              .fontSize(11)
              .fontColor(COLORS.muted)
              .margin({ top: 6 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(withAlpha(COLORS.bg, 0.82))
        }
      }
      .layoutWeight(1)
      .width('100%')

      Row() {
        PanelCommand({ label: '重新检查', primary: true, activateAction: this.runDrcAction })
        PanelCommand({
          label: '定位违规',
          primary: false,
          disabled: this.issues.length === 0,
          activateAction: () => {
            if (this.issues.length > 0) {
              this.locateIssueAction(this.issues[0]);
            }
          }
        })
      }
      .height(54)
      .padding({ left: 12, right: 12 })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width('100%')
    .height('100%')
  }

  private currentSubtitle(): string {
    return this.ruleSourceTextValue;
  }

  /** 防抖 DRC 触发：规则配置变更时调用，500ms 内多次变更合并为一次执行 */
  private debouncedRunDrc(): void {
    // Invalidate immediately; the debounce only delays running the new configuration.
    this.drcConfigurationChangedAction();
    if (this.drcDebounceTimer !== -1) {
      clearTimeout(this.drcDebounceTimer);
    }
    this.isDrcRunning = true;
    this.drcDebounceTimer = setTimeout(() => {
      this.drcDebounceTimer = -1;
      this.runDrcAction();
      // DRC 完成后关闭加载指示（由父组件更新 issues 后触发重渲染）
      setTimeout(() => { this.isDrcRunning = false; }, 100);
    }, 500);
  }

  private selectRuleset(index: number): void {
    if (index < 0 || index >= RULESET_PROCESSES.length) {
      return;
    }
    const process: string = RULESET_PROCESSES[index];
    if (process === 'custom') {
      // 自定义：保留当前规则参数，仅切换选中态，不重置规则集
      this.selectedRulesetIndex = index;
      this.drcConfigStatus = `已切换到 ${RULESET_NAMES[index]}（保留当前规则参数）`;
      return;
    }
    drcService.applyRuleset(process);
    this.rules = drcService.getRules();
    this.selectedRulesetIndex = index;
    this.rulesetVersion++;
    this.syncRuleSource();
    this.drcConfigStatus = `已切换到 ${RULESET_NAMES[index]}，并重新检查`;
    this.debouncedRunDrc();
  }

  private applyTileSize(value: string): void {
    const text: string = value.trim();
    const num: number = Number(text);
    if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) ||
      !Number.isFinite(num) || num <= 0) {
      this.drcConfigStatus = `分块大小无效：${value}`;
      return;
    }
    this.tileSizeText = value;
    drcService.setTileSize(num);
    this.drcConfigStatus = `分块大小已更新为 ${num}nm，并重新检查`;
    this.debouncedRunDrc();
  }

  private addRuleFileFromInput(value: string): void {
    const path: string = value.trim();
    if (path.length === 0) {
      this.drcConfigStatus = '规则文件路径不能为空';
      return;
    }
    const status: string = drcService.addRuleFile(path);
    this.drcConfigStatus = status;
    if (status.startsWith('已加载')) {
      this.newRuleFilePath = '';
      this.ruleFiles = drcService.getRuleFiles().slice();
      // 规则真的变了：规则表 / 来源 / 分组一起刷新，并触发一次重检
      this.afterRulesChanged();
    }
  }

  private depthLabel(d: number): string {
    return d === 0 ? '仅本地' : (d === 1 ? '1 层' : (d === 2 ? '2 层' : '3 层'));
  }

  /** 切换 DRC 层级展开深度；深度≥1 与「深度模式」Toggle 保持同义 */
  private applyHierarchyDepth(d: number): void {
    drcService.setHierarchyDepth(d);
    this.hierarchyDepth = drcService.hierarchyDepth;
    this.deepModeOn = drcService.deepMode;
    this.drcConfigStatus = `展开层级已设为 ${this.hierarchyDepth}`;
    this.debouncedRunDrc();
  }

  private errorCount(): number {
    let count = 0;
    for (let i = 0; i < this.issues.length; i++) {
      if (this.issues[i].severity === 'error') {
        count++;
      }
    }
    return count;
  }

  private warningCount(): number {
    let count = 0;
    for (let i = 0; i < this.issues.length; i++) {
      if (this.issues[i].severity === 'warning') {
        count++;
      }
    }
    return count;
  }
}

@Component
struct DataInspector {
  openFileAction: () => void = () => {};
  quickScanAction: () => void = () => {};
  @Prop docLibName: string = 'DEMO_LIB';
  @Prop docCellCount: number = 1;
  @Prop docElementCount: number = 0;
  @Prop docTopCellName: string = 'TOP';
  @Prop currentFilePath: string = '';

  /** 从完整路径提取文件名 */
  private fileNameFromPath(path: string): string {
    if (path.length === 0) {
      return 'demo（未加载文件）';
    }
    const parts: string[] = path.split('/');
    const name: string = parts[parts.length - 1];
    return name.length > 0 ? name : path;
  }

  build() {
    Column() {
      PanelHeader({ title: '数据管理', subtitle: '' })

      Column() {
        Text('当前文件')
          .fontSize(12)
          .fontColor(COLORS.muted)
        Text(this.fileNameFromPath(this.currentFilePath))
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor(COLORS.ink)
          .margin({ top: 6 })
        Text(`GDSII | ${this.docCellCount} Cells | ${this.docElementCount} Elements`)
          .fontSize(12)
          .fontColor(COLORS.muted)
          .margin({ top: 4 })
      }
      .width('100%')
      .padding(14)
      .alignItems(HorizontalAlign.Start)

      Divider().color(COLORS.border)

      DataRow({ label: '库名称', value: this.docLibName })
      DataRow({ label: '顶层单元', value: this.docTopCellName })
      DataRow({ label: '用户单位', value: '1nm' })
      DataRow({ label: '物理单位', value: '1e-9m' })
      DataRow({ label: '原生库', value: 'libhongtu.so' })
      DataRow({ label: 'ABI', value: 'x86_64 / arm64-v8a' })

      Blank()

      Row() {
        PanelCommand({ label: '打开文件', primary: true, activateAction: this.openFileAction })
        PanelCommand({ label: '快速扫描', primary: false, activateAction: this.quickScanAction })
      }
      .height(54)
      .padding({ left: 12, right: 12 })
      .border({ width: { top: 1 }, color: COLORS.border })
    }
    .width('100%')
    .height('100%')
  }
}

@Component
struct LayerRow {
  @StorageProp('hongtuReduceMotion') reduceMotion: boolean = false;
  // INSPECTOR-1: layer 改用 @Prop，使可见性/颜色等变更能触发刷新（原先普通字段不响应父组件状态变化）
  @Prop layer: UiLayer = { layerNumber: 0, datatype: 0, chineseName: '', englishName: '', color: '#FFFFFF', visible: false, elementCount: 0, group: LayerGroup.OTHER };
  @Prop elementCount: number = 0;
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  selectLayerAction: (layer: UiLayer) => void = () => {};
  toggleLayerAction: (layerNumber: number, datatype: number) => void = () => {};

  build() {
    Row() {
      Button({ type: ButtonType.Normal }) {
        WorkbenchIcon({ name: this.layer.visible ? 'eye' : 'eyeOff', iconSize: 20, color: COLORS.muted })
      }
        .width(UI.compactControlHeight)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .accessibilityText(this.layer.visible ? '隐藏图层' : '显示图层')
        .bindTips(this.layer.visible ? '隐藏图层' : '显示图层')
        .onClick(() => {
          this.toggleLayerAction(this.layer.layerNumber, this.layer.datatype);
        })
        .hitTestBehavior(HitTestMode.Block)
      Rect()
        .width(16)
        .height(16)
        .fill(this.layer.color)
        .borderRadius(RADIUS.xs)
      Column() {
        Row() {
          Text(this.layer.chineseName)
            .fontSize(13)
            .fontColor(COLORS.ink)
          Text(this.layer.englishName)
            .fontSize(11)
            .fontColor(COLORS.muted)
            .fontFamily(FONT_MONO)
            .margin({ left: 6 })
        }
        Text(`L${this.layer.layerNumber}/D${this.layer.datatype} · ${this.elementCount} 图形`)
          .fontSize(10)
          .fontColor(COLORS.muted)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 10 })
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .animation(null)
    .backgroundColor(this.selectedLayerNumber === this.layer.layerNumber && this.selectedDatatype === this.layer.datatype ? COLORS.primarySoft : COLORS.surface)
    .animation({ duration: this.reduceMotion ? 0 : MOTION.feedback, curve: feedbackCurve() })
    .border({ width: { bottom: 1 }, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .onClick(() => {
      this.selectLayerAction(this.layer);
    })
  }
}

@Component
struct DrcIssueRow {
  // INSPECTOR-1: 改为 @Prop，确保 DRC 重新运行后新违规数据能正确同步到复用的行
  @Prop issue: DrcIssue = new DrcIssue(0, '', '', '', '', 0, 0);
  locateIssueAction: (issue: DrcIssue) => void = () => {};
  @Prop highlightedViolationId: number = -1;

  build() {
    Row() {
      // 左侧严重度色条（专业问题面板惯例）
      Row()
        .width(3)
        .height('100%')
        .borderRadius(2)
        .backgroundColor(this.issue.severity === 'error' ? COLORS.danger : COLORS.warning)
      Column() {
        Row() {
          Text(this.issue.severity === 'error' ? '错误' : '警告')
            .fontSize(10)
            .fontColor(Color.White)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.issue.severity === 'error' ? COLORS.danger : COLORS.warning)
            .borderRadius(RADIUS.xs)
          Text(this.issue.ruleName)
            .fontSize(13)
            .fontColor(COLORS.ink)
            .fontWeight(FontWeight.Medium)
            .margin({ left: 8 })
            .layoutWeight(1)
            .maxLines(1)
          Row({ space: 2 }) {
            Text('定位')
              .fontSize(10)
              .fontColor(COLORS.accent)
            WorkbenchIcon({ name: 'chevronRight', iconSize: 11, color: COLORS.accent })
          }
          .alignItems(VerticalAlign.Center)
        }
        .alignItems(VerticalAlign.Center)
        Text(this.issue.message)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .margin({ top: 6 })
        Text(`${this.issue.layerName} · (${this.issue.x}, ${this.issue.y})`)
          .fontSize(10)
          .fontColor(COLORS.muted)
          .fontFamily(FONT_MONO)
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .padding({ top: 12, bottom: 12, right: 12 })
      .margin({ left: 10 })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .backgroundColor(this.isHighlighted() ? COLORS.primarySoft : COLORS.surface)
    .border({ width: { bottom: 1 }, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .onClick(() => {
      this.locateIssueAction(this.issue);
    })
  }

  private isHighlighted(): boolean {
    return this.highlightedViolationId === this.issue.id;
  }
}

/**
 * DRC 结果按规则分组表：每条已定义规则都要出现（0 命中也列），
 * 完整性告警（DRC.TRUNC / DRC.NOHIER）单列且**不计入**任何规则命中或 passed。
 */
@Component
struct DrcRuleGroupTable {
  @Prop ranOnce: boolean = false;
  @Prop rows: DrcRuleGroup[] = [];
  @Prop unknown: DrcRuleGroup[] = [];
  @Prop notices: DrcNoticeRow[] = [];
  @Prop hitRules: number = 0;
  @Prop zeroHitRules: number = 0;
  @Prop ruleViolations: number = 0;
  @Prop errors: number = 0;
  @Prop warnings: number = 0;
  @Prop noticeCount: number = 0;
  @Prop passed: boolean = true;
  @Prop scopeNote: string = '';
  locateGroupAction: (group: DrcRuleGroup) => void = () => {};

  build() {
    Column() {
      if (!this.ranOnce) {
        Text('尚未运行检查')
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width('100%')
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      }
      if (this.ranOnce) {
        Row() {
          Text(this.passed ? '通过（仅规则违例）' : '未通过（规则违例）')
            .fontSize(11)
            .fontColor(this.passed ? COLORS.primary : COLORS.danger)
            .layoutWeight(1)
          Text(`命中规则 ${this.hitRules} · 零命中 ${this.zeroHitRules} · 违例 ${this.ruleViolations}`)
            .fontSize(10)
            .fontColor(COLORS.muted)
        }
        .width('100%')
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })

        ForEach(this.rows, (g: DrcRuleGroup) => {
          Row() {
            Column() {
              Text(`${g.ruleName} · ${g.typeText}`)
                .fontSize(11)
                .fontColor(COLORS.ink)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(`${g.layerText} · ${g.limitText}`)
                .fontSize(10)
                .fontColor(COLORS.muted)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            Text(g.hits === 0 ? '0' : `${g.hits}`)
              .fontSize(11)
              .fontColor(g.errors > 0 ? COLORS.danger : (g.hits > 0 ? COLORS.warning : COLORS.muted))
              .width(28)
              .textAlign(TextAlign.End)
          }
          .width('100%')
          .height(38)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            if (g.hits > 0) {
              this.locateGroupAction(g);
            }
          })
        }, (g: DrcRuleGroup) => g.ruleId)

        if (this.unknown.length > 0) {
          Text('未在册规则（native 侧独有 ruleId，如实列出）')
            .fontSize(10)
            .fontColor(COLORS.muted)
            .width('100%')
            .padding({ left: 14, top: 6, bottom: 2 })
          ForEach(this.unknown, (g: DrcRuleGroup) => {
            Text(`${g.ruleId} · ${g.hits} 项`)
              .fontSize(10)
              .fontColor(COLORS.ink)
              .width('100%')
              .padding({ left: 14, bottom: 2 })
          }, (g: DrcRuleGroup) => `u-${g.ruleId}`)
        }

        if (this.noticeCount > 0) {
          ForEach(this.notices, (n: DrcNoticeRow) => {
            Row({ space: 6 }) {
              DrawnStatusIcon({ kind: 'warning', iconSize: 14, strokeColor: COLORS.warning, showSoftPlate: false })
              Text(`${n.title}：${n.message}`)
                .fontSize(10)
                .fontColor(COLORS.warning)
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            .padding({ left: 14, right: 14, top: 4, bottom: 4 })
          }, (n: DrcNoticeRow) => `n-${n.ruleId}-${n.title}`)
        }
      }

      if (this.ranOnce && this.scopeNote.length > 0) {
        Text(this.scopeNote)
          .fontSize(10)
          .fontColor(COLORS.muted)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 14, right: 14, top: 4, bottom: 6 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}

/** DRC 规则配置行：启用开关 + 规则名 + 参数输入框 + 单位 */
@Component
struct DrcRuleRow {
  /** Desktop table uses the same columns as its heading; the dock stays compact. */
  @Prop tableLayout: boolean = false;
  // INSPECTOR-2: 改为 @Prop + @Watch，确保规则集切换/外部修改时新规则数据能正确同步
  @Prop @Watch('onRulePropChange') rule: DrcRule = {
    id: '',
    name: '',
    type: DrcRuleType.MIN_WIDTH,
    layerNumber: 0,
    targetLayerNumber: -1,
    value: 0,
    severity: DrcSeverity.ERROR,
    description: '',
    enabled: false
  };
  @State ruleEnabled: boolean = false;
  @State valueText: string = '';
  runDrcAction: () => void = () => {};
  statusAction: (status: string) => void = () => {};
  /** 规则被修改时通知父组件（用于自动切换到"自定义"规则集） */
  onRuleModified: () => void = () => {};

  aboutToAppear(): void {
    this.ruleEnabled = this.rule.enabled;
    this.valueText = this.rule.value.toString();
  }

  // INSPECTOR-2: rule prop 变化时重新同步本地状态
  onRulePropChange(): void {
    this.ruleEnabled = this.rule.enabled;
    this.valueText = this.rule.value.toString();
  }

  build() {
    if (this.tableLayout) {
      this.TableRuleRow()
    } else {
      this.CompactRuleRow()
    }
  }

  @Builder
  private TableRuleRow() {
    Row({ space: 6 }) {
      Row() {
        Checkbox({ name: this.rule.id })
          .select(this.ruleEnabled)
          .selectedColor(COLORS.primary)
          .unselectedColor(COLORS.muted)
          .width(20)
          .height(20)
          .margin(0)
          .accessibilityText(`${this.rule.name}，${this.ruleEnabled ? '已启用' : '已停用'}`)
          .bindTips(this.ruleEnabled ? '停用规则' : '启用规则')
          .onChange((enabled: boolean) => {
            this.setRuleEnabled(enabled);
          })
      }
      .width(24)
      .justifyContent(FlexAlign.Center)

      Column({ space: 3 }) {
        Text(this.rule.name)
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(typeLabel(this.rule.type))
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .bindTips(`${this.rule.name}：${this.rule.description}`)

      Column({ space: 3 }) {
        Text(`L${this.rule.layerNumber}`)
          .fontSize(UI.fontBody)
          .fontColor(COLORS.ink)
          .maxLines(1)
        Text(`D${this.rule.datatype === undefined ? '*' : this.rule.datatype}`)
          .fontSize(UI.fontCaption)
          .fontColor(COLORS.muted)
          .maxLines(1)
      }
      .width(56)
      .alignItems(HorizontalAlign.Start)
      .bindTips(`层 ${this.rule.layerNumber} / datatype ${this.rule.datatype === undefined ? '任意' : this.rule.datatype}`)

      TextInput({ text: this.valueText, placeholder: '数值' })
        .type(InputType.Number)
        .width(62)
        .height(UI.compactControlHeight)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .padding({ left: 8, right: 6 })
        .backgroundColor(COLORS.surface)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .onChange((value: string) => {
          this.valueText = value;
        })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => {
          this.applyValue(event.text);
        })

      Text(unitLabel(this.rule.type))
        .fontSize(UI.fontCaption)
        .fontColor(COLORS.muted)
        .width(26)
        .textAlign(TextAlign.Start)

      Button('应用', { type: ButtonType.Normal })
        .fontSize(UI.fontCaption)
        .fontColor(COLORS.primary)
        .width(32)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .onClick(() => {
          this.applyValue(this.valueText);
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 10, right: 10 })
    .alignItems(VerticalAlign.Center)
    .border({ width: { bottom: 1 }, color: COLORS.border })
  }

  @Builder
  private CompactRuleRow() {
    Row() {
      Checkbox({ name: this.rule.id })
        .select(this.ruleEnabled)
        .selectedColor(COLORS.primary)
        .unselectedColor(COLORS.muted)
        .width(20)
        .height(20)
        .margin({ left: 0, right: 0 })
        .accessibilityText(`${this.rule.name}，${this.ruleEnabled ? '已启用' : '已停用'}`)
        .bindTips(this.ruleEnabled ? '停用规则' : '启用规则')
        .onChange((enabled: boolean) => {
          this.setRuleEnabled(enabled);
        })

      Column() {
        Text(this.rule.name)
          .fontSize(12)
          .fontColor(COLORS.ink)
          .maxLines(1)
        Text(`L${this.rule.layerNumber}/D${this.rule.datatype === undefined ? '*（任意）' : this.rule.datatype} · ${typeLabel(this.rule.type)}`)
          .fontSize(10)
          .fontColor(COLORS.muted)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .margin({ left: 8 })

      TextInput({ text: this.valueText, placeholder: '数值' })
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
        .type(InputType.Number)
        .height(UI.fieldHeight)
        .width(58)
        .fontSize(UI.fontBody)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)
        .padding({ left: 6, right: 6 })
        .onChange((val: string) => {
          this.valueText = val;
        })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => {
          this.applyValue(event.text);
        })

      Text(unitLabel(this.rule.type))
        .fontSize(10)
        .fontColor(COLORS.muted)
        .width(28)
        .textAlign(TextAlign.Start)
        .margin({ left: 4 })
      Button('应用', { type: ButtonType.Normal })
        .fontSize(11)
        .fontColor(COLORS.accent)
        .width(40)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .onClick(() => {
          this.applyValue(this.valueText);
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 12, right: 12 })
    .alignItems(VerticalAlign.Center)
  }

  private setRuleEnabled(nextEnabled: boolean): void {
    if (nextEnabled === this.ruleEnabled) {
      return;
    }
    // INSPECTOR-3: 检查 setEnabled 返回值，规则未找到时提示用户
    const ok: boolean = drcService.setEnabled(this.rule.id, nextEnabled);
    if (!ok) {
      this.statusAction(`规则 ${this.rule.id} 未找到，请刷新规则列表`);
      return;
    }
    this.ruleEnabled = nextEnabled;
    this.statusAction(`${this.rule.name} 已${nextEnabled ? '启用' : '停用'}，并重新检查`);
    this.onRuleModified();
    this.runDrcAction();
  }

  private applyValue(value: string): void {
    const text: string = value.trim();
    const num: number = Number(text);
    if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(text) ||
      !Number.isFinite(num) || num <= 0) {
      this.statusAction(`${this.rule.name} 参数无效：${value}`);
      return;
    }
    // INSPECTOR-3: 检查 setValue 返回值，规则未找到时提示用户
    const ok: boolean = drcService.setValue(this.rule.id, num);
    if (!ok) {
      this.statusAction(`规则 ${this.rule.id} 未找到，请刷新规则列表`);
      return;
    }
    this.valueText = value;
    this.statusAction(`${this.rule.name} 已更新为 ${num}${unitLabel(this.rule.type)}，并重新检查`);
    this.onRuleModified();
    this.runDrcAction();
  }
}

@Component
struct PropertiesPanel {
  @Prop selectedShapeId: number = -1;
  @Prop editable: boolean = true;
  @Prop selectedLayerNumber: number = 1;
  @Prop selectedDatatype: number = 0;
  @Prop zoomPercent: number = 100;
  @Prop selectedShape: Shape | null = null;
  @Prop desktopCanvasFirst: boolean = false;
  @StorageLink('hongtuPropCoordMode') coordMode: number = 0;
  onShapePropertySubmit: (shapeId: number, property: string, value: string) => void = () => {};

  /** 图形类型中文标签 */
  private shapeTypeLabel(t: ShapeType): string {
    if (t === ShapeType.RECT) {
      return '矩形';
    }
    if (t === ShapeType.POLYGON) {
      return '多边形';
    }
    if (t === ShapeType.PATH) {
      return '路径';
    }
    if (t === ShapeType.TEXT) {
      return '文本';
    }
    if (t === ShapeType.INSTANCE) {
      return '实例';
    }
    return '未知';
  }

  private shapeMinX(): number {
    if (this.selectedShape === null) {
      return 0;
    }
    return getShapeBounds(this.selectedShape).minX;
  }

  private shapeMinY(): number {
    if (this.selectedShape === null) {
      return 0;
    }
    return getShapeBounds(this.selectedShape).minY;
  }

  private shapeMaxX(): number {
    if (this.selectedShape === null) {
      return 0;
    }
    return getShapeBounds(this.selectedShape).maxX;
  }

  private shapeMaxY(): number {
    if (this.selectedShape === null) {
      return 0;
    }
    return getShapeBounds(this.selectedShape).maxY;
  }

  private shapeWidth(): number {
    return this.shapeMaxX() - this.shapeMinX();
  }

  private shapeHeight(): number {
    return this.shapeMaxY() - this.shapeMinY();
  }

  build() {
    if (this.desktopCanvasFirst && (this.selectedShape === null || this.selectedShapeId < 0)) {
      Column() {
        PanelHeader({ title: '属性', subtitle: '' })
        Blank()
        Column() {
          WorkbenchIcon({ name: 'layout', iconSize: 38, color: COLORS.muted })
          Text('未选中对象')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(COLORS.muted)
            .margin({ top: 12 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        Blank()
      }
      .width('100%')
      .height('100%')
    } else {
    Column() {
      Text('')
        .id('workbench-inspector-focus-guard')
        .width(1)
        .height(1)
        .opacity(0)
        .focusable(true)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no')
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
      Text('属性')
        .fontSize(12)
        .fontColor(COLORS.muted)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 8 })

      if (this.selectedShape !== null && this.selectedShapeId >= 0) {
        DataRow({ label: '选中图形', value: `#${this.selectedShape.id}` })
        DataRow({ label: '图形类型', value: this.shapeTypeLabel(this.selectedShape.type) })
        EditablePropertyRow({
          label: '所在图层',
          value: `${this.selectedShape.layerNumber}/${this.selectedShape.datatype}`,
          propertyKey: 'layerKey',
          shapeId: this.selectedShape.id,
          editable: this.editable,
          numericOnly: false,
          submitAction: this.onShapePropertySubmit
        })
        if (this.selectedShape.type === ShapeType.RECT || this.selectedShape.type === ShapeType.POLYGON || this.selectedShape.type === ShapeType.PATH) {
          Row({ space: 6 }) {
            Text('坐标基准').fontSize(11).fontColor(COLORS.muted).width(60)
            Row() {
              StableSegmentButton({
                items: [{ text: '中心点' }, { text: '左下角' }, { text: '对角边界' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
                selectedIndex: (this.coordMode === 0 || this.coordMode === 1 || this.coordMode === 2) ? this.coordMode : 0,
                onItemClicked: (idx: number) => {
                  if (idx === 0 || idx === 1 || idx === 2) this.coordMode = idx;
                },
                fontColor: COLORS.muted,
                selectedFontColor: COLORS.primary,
                capsuleBackgroundColor: COLORS.surfaceMuted,
                selectedBackgroundColor: COLORS.primarySoft,
                fontSizeFp: 10.5,
                capsuleBorderRadius: 6,
                buttonMinHeight: 26,
                itemMinHeight: 22,
                itemPaddingHorizontal: 5,
                itemPaddingVertical: 2
              })
            }.layoutWeight(1)
          }
          .width('100%')
          .height(32)
          .padding({ left: 14, right: 14 })
          .alignItems(VerticalAlign.Center)

          if (this.coordMode === 0) {
            EditablePropertyRow({
              label: '中心 CX',
              value: `${(this.shapeMinX() + this.shapeMaxX()) * 0.5}`,
              propertyKey: 'centerX',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '中心 CY',
              value: `${(this.shapeMinY() + this.shapeMaxY()) * 0.5}`,
              propertyKey: 'centerY',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '对称宽 W',
              value: `${this.shapeWidth()}`,
              propertyKey: 'widthCenter',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '对称高 H',
              value: `${this.shapeHeight()}`,
              propertyKey: 'heightCenter',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
          } else if (this.coordMode === 1) {
            EditablePropertyRow({
              label: '左下 X1',
              value: `${this.shapeMinX()}`,
              propertyKey: 'x',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '左下 Y1',
              value: `${this.shapeMinY()}`,
              propertyKey: 'y',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '宽度 W',
              value: `${this.shapeWidth()}`,
              propertyKey: 'width',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '高度 H',
              value: `${this.shapeHeight()}`,
              propertyKey: 'height',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
          } else {
            EditablePropertyRow({
              label: '左边界 X1',
              value: `${this.shapeMinX()}`,
              propertyKey: 'minXEdge',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '下边界 Y1',
              value: `${this.shapeMinY()}`,
              propertyKey: 'minYEdge',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '右边界 X2',
              value: `${this.shapeMaxX()}`,
              propertyKey: 'maxX',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
            EditablePropertyRow({
              label: '上边界 Y2',
              value: `${this.shapeMaxY()}`,
              propertyKey: 'maxY',
              shapeId: this.selectedShape.id,
              editable: this.editable,
              numericOnly: false,
              submitAction: this.onShapePropertySubmit
            })
          }
        } else {
          EditablePropertyRow({
            label: '锚点 X',
            value: `${this.shapeMinX()}`,
            propertyKey: 'x',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
          EditablePropertyRow({
            label: '锚点 Y',
            value: `${this.shapeMinY()}`,
            propertyKey: 'y',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
        }
        if (this.selectedShape.type === ShapeType.INSTANCE) {
          EditablePropertyRow({
            label: '阵列列数',
            value: `${this.selectedShape.arrayCols || 1}`,
            propertyKey: 'arrayCols',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: true,
            submitAction: this.onShapePropertySubmit
          })
          EditablePropertyRow({
            label: '阵列行数',
            value: `${this.selectedShape.arrayRows || 1}`,
            propertyKey: 'arrayRows',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: true,
            submitAction: this.onShapePropertySubmit
          })
          EditablePropertyRow({
            label: '列距 PitchX',
            value: `${this.selectedShape.arrayColStepX ?? 0}`,
            propertyKey: 'arrayColStepX',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
          EditablePropertyRow({
            label: '行距 PitchY',
            value: `${this.selectedShape.arrayRowStepY ?? 0}`,
            propertyKey: 'arrayRowStepY',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
        }
        if (this.selectedShape.type === ShapeType.PATH) {
          EditablePropertyRow({
            label: '线宽',
            value: `${this.selectedShape.pathWidth ?? 1}`,
            propertyKey: 'pathWidth',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
        }
        DataRow({ label: '中心 (CX,CY)', value: `(${umText((this.shapeMinX() + this.shapeMaxX()) * 0.5)}, ${umText((this.shapeMinY() + this.shapeMaxY()) * 0.5)}) µm` })
        DataRow({ label: '包围盒 X', value: `${this.shapeMinX().toFixed(0)} ~ ${this.shapeMaxX().toFixed(0)}` })
        DataRow({ label: '包围盒 Y', value: `${this.shapeMinY().toFixed(0)} ~ ${this.shapeMaxY().toFixed(0)}` })
        DataRow({ label: '宽 x 高', value: `${this.shapeWidth().toFixed(0)} x ${this.shapeHeight().toFixed(0)} nm` })
        // INSPECTOR-3: 面积用 getShapeArea 替代包围盒 width*height，正确处理 PATH（中心线×线宽）和 INSTANCE
        DataRow({ label: '面积', value: `${getShapeArea(this.selectedShape).toFixed(0)} nm²` })
        DataRow({ label: '顶点数', value: `${this.selectedShape.points.length}` })
        if (this.selectedShape.type === ShapeType.TEXT && this.selectedShape.text !== undefined) {
          EditablePropertyRow({
            label: '文本内容',
            value: this.selectedShape.text,
            propertyKey: 'text',
            shapeId: this.selectedShape.id,
            editable: this.editable,
            numericOnly: false,
            submitAction: this.onShapePropertySubmit
          })
        }
        if (this.selectedShape.type === ShapeType.INSTANCE && this.selectedShape.cellId !== undefined) {
          DataRow({ label: '引用 Cell', value: `#${this.selectedShape.cellId}` })
        }
        DataRow({ label: '缩放', value: formatZoomPercent(this.zoomPercent) })
      } else {
        DataRow({ label: '选中图形', value: '无' })
        DataRow({ label: '缩放', value: formatZoomPercent(this.zoomPercent) })
      }
    }
    .width('100%')
    .padding(14)
    .alignItems(HorizontalAlign.Start)
    }
  }
}

@Component
struct EditablePropertyRow {
  label: string = '';
  @Prop editable: boolean = true;
  @Prop @Watch('onExternalValueChanged') value: string = '';
  @Prop @Watch('onTargetChanged') propertyKey: string = '';
  @Prop @Watch('onTargetChanged') shapeId: number = -1;
  numericOnly: boolean = false;
  @State pendingValue: string = '';
  @State valueDirty: boolean = false;
  submitAction: (shapeId: number, property: string, value: string) => void = () => {};

  aboutToAppear(): void {
    this.pendingValue = '';
    this.valueDirty = false;
  }

  onExternalValueChanged(): void {
    if (!this.valueDirty) {
      this.pendingValue = '';
    }
  }

  onTargetChanged(): void {
    this.pendingValue = '';
    this.valueDirty = false;
  }

  private currentValue(): string {
    return this.valueDirty ? this.pendingValue : this.value;
  }

  private submitValue(value: string): void {
    if (!this.editable || !this.valueDirty) return;
    this.pendingValue = '';
    this.valueDirty = false;
    this.submitAction(this.shapeId, this.propertyKey, value);
  }

  build() {
    Row() {
      Text(this.label)
        .fontSize(12)
        .fontColor(COLORS.muted)
        .width(84)
      Text(this.value)
        .fontSize(12)
        .fontColor(COLORS.ink)
        .width(44)
        .maxLines(1)
      TextInput({ text: $$this.pendingValue, placeholder: this.value })
        .onFocus(() => { resetModifierKeys(); })
        .onKeyEvent((event: KeyEvent) => {
          event.stopPropagation();
          if (event.type === KeyType.Down && canvasKeyName(event.keyCode, event.keyText) === 'ESCAPE') {
            resetModifierKeys();
            this.pendingValue = '';
            this.valueDirty = false;
            try {
              this.getUIContext().getFocusController().requestFocus('workbench-inspector-focus-guard');
            } catch (_err) {}
          }
        })
        .type(this.numericOnly ? InputType.Number : InputType.Normal)
        .enabled(this.editable)
        .fontSize(12)
        .fontColor(COLORS.ink)
        .height(30)
        .layoutWeight(1)
        .padding({ left: 8, right: 8 })
        .backgroundColor(COLORS.surfaceMuted)
        .borderRadius(UI.controlRadius)
        .onChange((value: string) => {
          this.pendingValue = value;
          this.valueDirty = true;
        })
        .onSubmit((_enterKey: EnterKeyType, event: SubmitEvent) => {
          this.submitValue(event.text);
          event.keepEditableState();
        })
      Button('应用', { type: ButtonType.Normal })
        .focusable(false)
        .enabled(this.editable)
        .fontSize(11)
        .fontColor(COLORS.accent)
        .width(40)
        .height(UI.compactControlHeight)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .borderRadius(UI.controlRadius)
        .onClick(() => {
          this.submitValue(this.currentValue());
        })
    }
    .width('100%')
    .height(34)
    .padding({ left: 14, right: 14 })
  }
}

@Component
struct PanelHeader {
  @Prop title: string = '';
  @Prop subtitle: string = '';

  build() {
    PanelHeading({ title: this.title, subtitle: this.subtitle })
      .padding({ left: UI.panelPadding, right: UI.panelPadding, top: 12 })
  }
}

@Component
struct DataRow {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(12)
        .fontColor(COLORS.muted)
        .width(84)
      Text(this.value)
        .fontSize(12)
        .fontColor(COLORS.ink)
        .fontFamily(FONT_MONO)
        .layoutWeight(1)
        .maxLines(1)
    }
    .width('100%')
    .height(30)
    .padding({ left: 14, right: 14 })
  }
}

@Component
struct StatCard {
  @Prop label: string = '';
  @Prop value: string = '';
  @Prop colorValue: string = COLORS.accent;

  build() {
    Column() {
      Text(this.value)
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.colorValue)
        .fontFamily(FONT_MONO)
      Text(this.label)
        .fontSize(10)
        .fontColor(COLORS.muted)
        .margin({ top: 3 })
    }
    .layoutWeight(1)
    .height(64)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 1, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .margin({ right: 8 })
  }
}

@Component
struct PanelCommand {
  @Prop label: string = '';
  @Prop primary: boolean = false;
  @Prop disabled: boolean = false;
  activateAction: () => void = () => {};

  build() {
    Button(this.label, { type: ButtonType.Normal })
      .focusable(false)
      .fontSize(12)
      .fontColor(this.disabled ? COLORS.muted : (this.primary ? Color.White : COLORS.ink))
      .fontWeight(FontWeight.Medium)
      .height(UI.compactControlHeight)
      .padding({ left: 16, right: 16 })
      .backgroundColor(this.primary && !this.disabled ? COLORS.primary : COLORS.surfaceMuted)
      .borderRadius(UI.controlRadius)
      .margin({ left: 8 })
      .opacity(this.disabled ? 0.5 : 1)
      .enabled(!this.disabled)
      .onClick(() => {
        if (!this.disabled) {
          this.activateAction();
        }
      })
  }
}
