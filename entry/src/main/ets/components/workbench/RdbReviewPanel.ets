import { SettingsToggleRow } from '../SettingsKit';
import { StableSegmentButton } from '../StableSegmentButton';
import { ChipGroup, ChipGroupItemOptions, ChipSize, SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { RdbFramePath, RdbTagRef, RdbValue } from '../../models/RdbData';
import { RdbReviewFilter, RdbReviewPatch, RdbReviewRow } from '../../models/RdbReview';
import { RdbReviewWorkspaceReport } from '../../models/RdbReviewWorkspace';
import { RdbReviewTransferOptions } from '../../models/RdbReviewTransfer';
import { RdbMergeOptions, RdbMergeRow } from '../../models/RdbMerge';
import { RdbWaiverUiRequest, RdbWaiverCaptureRequest, RdbWaiverFileRequest,
  RdbWaiverUiPreview, RdbWaiverRuleRow, RdbWaiverPreviewRow } from '../../models/RdbWaiver';
import { RdbReviewCategoryChoice, RdbReviewCellChoice, RdbReviewTagChoice, RdbReviewLayoutCell,
  RdbReviewUiState, RdbTransferUiRequest, RdbTransferUiRow, RdbTransferUiChanges,
  RdbMergeUiSource, RdbMergeUiRequest, RdbMergeUiPreview, emptyRdbReviewUiState } from '../../models/RdbReviewUi';
import { rdbValueDisplay } from '../../services/RdbService';
import { PanelHeading } from './PanelHeading';
import { RdbMarkerOverlay } from './RdbMarkerOverlay';

interface RdbTransferFieldSpec {
  label: string;
  field: string;
  checked: boolean;
}

interface RdbMergeSourceRowSpec {
  report: RdbReviewWorkspaceReport;
  workspace: string;
  checked: boolean;
  orderIndex: number;
}

interface RdbWaiverRuleSpec {
  rule: RdbWaiverRuleRow;
  version: string;
  context: string;
  selected: boolean;
}

interface RdbReportRowSpec {
  report: RdbReviewWorkspaceReport;
  workspace: string;
  isActive: boolean;
}

/** Report data and layout ownership stay in the host; local edits are explicit drafts. */
@Component
export struct RdbReviewPanel {
  @Prop @Watch('synchronizeState') state: RdbReviewUiState = emptyRdbReviewUiState();
  @Prop status: string = '';
  @Prop busy: boolean = false;
  @Prop canUseCurrentDrc: boolean = false;
  @Prop panelWidth: number = 1100;
  @Prop panelHeight: number = 720;
  fileAction: (kind: string) => void = () => {};
  reportActivateAction: (id: string, workspaceToken: string, reportContext: string) => boolean = () => false;
  reportCloseAction: (id: string, workspaceToken: string, reportContext: string) => void = () => {};
  reportFileAction: (kind: string, id: string, workspaceToken: string, reportContext: string) => void = () => {};
  transferPreviewAction: (request: RdbTransferUiRequest) => boolean = () => false;
  transferPageAction: (previewId: string, pageIndex: number, pageSize: number) => boolean = () => false;
  transferApplyAction: (previewId: string) => void = () => {};
  transferCancelAction: (previewId: string) => void = () => {};
  mergePreviewAction: (request: RdbMergeUiRequest) => boolean = () => false;
  mergePageAction: (previewId: string, pageIndex: number, pageSize: number) => boolean = () => false;
  mergeApplyAction: (previewId: string) => void = () => {};
  mergeCancelAction: (previewId: string) => void = () => {};
  waiverCaptureAction: (request: RdbWaiverCaptureRequest) => boolean = () => false;
  waiverPreviewAction: (request: RdbWaiverUiRequest) => boolean = () => false;
  waiverPageAction: (previewId: string, pageIndex: number, pageSize: number) => boolean = () => false;
  waiverApplyAction: (previewId: string) => void = () => {};
  waiverCancelAction: (previewId: string) => void = () => {};
  waiverDeleteAction: (id: string, libraryVersion: string) => void = () => {};
  waiverFileAction: (request: RdbWaiverFileRequest) => void = () => {};
  reloadWorkspaceAction: (workspaceToken: string) => void = () => {};
  filterAction: (filter: RdbReviewFilter) => boolean = () => false;
  pageAction: (pageIndex: number, pageSize: number) => boolean = () => false;
  selectAction: (index: number) => boolean = () => false;
  reviewAction: (index: number, patch: RdbReviewPatch, expectedContext: string) => boolean = () => false;
  frameAction: (targetCell: string, pathIndex: number) => boolean = () => false;
  bindAction: (reportCell: string, layoutCellId: number) => boolean = () => false;
  locateAction: () => boolean = () => false;
  clearOverlayAction: () => void = () => {};
  draftAction: (dirty: boolean) => void = () => {};
  closeAction: () => void = () => {};
  @State localError: string = '';
  @State mode: number = 0;
  @State reportPage: number = 0;
  @State reportPageSize: number = 10;
  @State reportPageText: string = '';
  @State transferSourceId: string = '';
  @State transferTargetId: string = '';
  @State transferComment: boolean = true;
  @State transferVisited: boolean = true;
  @State transferWaived: boolean = true;
  @State transferImportant: boolean = true;
  @State transferUserTags: boolean = false;
  @State transferImage: boolean = false;
  @State duplicatePolicyIndex: number = 0;
  @State targetConflictPolicyIndex: number = 0;
  @State blockedPolicyIndex: number = 0;
  @State transferPageText: string = '';
  @State transferDetailIndex: number = -1;
  @State mergeSourceIds: string[] = [];
  @State mergeSourcePage: number = 0;
  @State mergeSourcePageSize: number = 10;
  @State mergeSourcePageText: string = '';
  @State mergeSelectedPage: number = 0;
  @State mergeName: string = '合并报告';
  @State mergeDescription: string = '';
  @State mergePolicyIndex: number = 0;
  @State mergePageText: string = '';
  @State waiverName: string = '';
  @State waiverRationale: string = '';
  @State waiverRuleIds: string[] = [];
  @State waiverOperation: number = 0;
  @State waiverRulePage: number = 0;
  @State waiverPageText: string = '';
  @State waiverRulePageText: string = '';
  @State pane: number = 1;
  @State draftComment: string = '';
  @State draftVisited: boolean = false;
  @State draftWaived: boolean = false;
  @State draftImportant: boolean = false;
  @State draftDirty: boolean = false;
  @State searchText: string = '';
  @State categoryKeys: string[] = [];
  @State cellKeys: string[] = [];
  @State tagKeys: string[] = [];
  @State statusIndex: number = 0;
  @State waivedIndex: number = 0;
  @State importantIndex: number = 0;
  @State sortIndex: number = 0;
  @State descending: boolean = false;
  @State pageText: string = '';
  @State markerText: string = '';
  @State valuePage: number = 0;
  @State valuePageText: string = '';
  @State layoutChoiceId: number = -1;
  @State imageFailed: boolean = false;
  private active: boolean = true;
  private draftToken: string = '';
  private draftReportId: string = '';
  private draftIndex: number = -1;
  private draftSignature: string = '';
  private appliedFilter: string = '';
  private filterReportId: string = '';
  private selectedSignature: string = '';
  private readonly valuePageSize: number = 8;

  aboutToAppear(): void { this.active = true; this.synchronizeState(); }
  aboutToDisappear(): void { this.active = false; }
  private available(): boolean { return this.active && !this.busy; }
  private loaded(): boolean { return this.available() && this.state.loaded; }
  private currentDraft(): boolean {
    return this.loaded() && this.state.selected !== null && this.draftReportId === this.state.activeReportId &&
      this.draftToken === this.state.token && this.draftIndex === this.state.selected.index;
  }
  private synchronizeState(): void {
    const filter: string = JSON.stringify(this.state.filter);
    if (filter !== this.appliedFilter || this.filterReportId !== this.state.activeReportId) {
      this.readFilter(); this.appliedFilter = filter; this.filterReportId = this.state.activeReportId;
    }
    this.reportPage = Math.min(this.reportPage, this.reportPageCount() - 1);
    this.mergeSourcePage = Math.min(this.mergeSourcePage, this.mergeSourcePageCount() - 1);
    this.mergeSelectedPage = Math.min(this.mergeSelectedPage, this.mergeSelectedPageCount() - 1);
    this.waiverRulePage = Math.min(this.waiverRulePage, this.waiverRulePageCount() - 1);
    if (this.state.waiverLibrary) this.waiverRuleIds = this.waiverRuleIds.filter((id: string): boolean => this.state.waiverLibrary!.rules.some((rule: RdbWaiverRuleRow): boolean => rule.id === id));
    if (!this.state.layoutCells.some((cell: RdbReviewLayoutCell): boolean => cell.id === this.layoutChoiceId)) this.layoutChoiceId = -1;
    const selected: string = JSON.stringify([this.state.activeReportId, this.state.token, this.state.selected === null ? -1 : this.state.selected.index]);
    if (selected === this.selectedSignature) return;
    this.selectedSignature = selected;
    this.valuePage = 0; this.valuePageText = ''; this.imageFailed = false;
    if (this.draftDirty) { this.localError = '报告或所选标记已改变；编辑内容已保留，请取消编辑后重试。'; return; }
    this.readDraft();
  }
  private readDraft(): void {
    this.draftToken = this.state.token;
    this.draftReportId = this.state.activeReportId;
    this.draftIndex = this.state.selected === null ? -1 : this.state.selected.index;
    this.draftComment = this.state.selected === null ? '' : this.state.selected.item.comment;
    this.draftVisited = this.state.selected === null ? false : this.state.selected.item.visited;
    this.draftWaived = this.state.selected === null ? false : this.state.selected.waived;
    this.draftImportant = this.state.selected === null ? false : this.state.selected.important;
    this.draftSignature = this.editSignature(); this.setDraftDirty(false);
  }
  private editSignature(): string {
    return JSON.stringify([this.draftComment, this.draftVisited, this.draftWaived, this.draftImportant]);
  }
  private setDraftDirty(value: boolean): void {
    if (this.draftDirty === value) return;
    this.draftDirty = value; this.draftAction(value);
  }
  private changedDraft(): void { this.setDraftDirty(this.editSignature() !== this.draftSignature); }
  private cancelDraft(): void { if (!this.available()) return; this.localError = ''; this.readDraft(); }
  private navigationAllowed(): boolean {
    if (!this.available()) return false;
    if (this.draftDirty) { this.localError = '有未提交的审阅编辑，请先保存审阅或取消编辑。'; this.mode = 0; this.pane = 2; return false; }
    this.localError = ''; return true;
  }
  private saveReview(): void {
    if (!this.currentDraft()) { this.localError = '报告或标记已改变，编辑未提交。请取消编辑后重试。'; return; }
    const token: string = this.draftToken; const report: string = this.draftReportId;
    const index: number = this.draftIndex; const signature: string = this.editSignature();
    const patch: RdbReviewPatch = { comment: this.draftComment, visited: this.draftVisited, waived: this.draftWaived, important: this.draftImportant };
    try {
      if (this.reviewAction(index, patch, token) && this.active && this.draftReportId === report && this.state.activeReportId === report &&
        this.draftToken === token && this.draftIndex === index && this.editSignature() === signature) {
        this.draftSignature = signature; this.setDraftDirty(false); this.localError = ''; this.readDraft();
      }
    } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private transfer(kind: string): void {
    if (!this.navigationAllowed() || !['open', 'reload', 'save', 'currentDrc'].includes(kind)) return;
    if ((kind === 'reload' || kind === 'save') && !this.state.loaded) return;
    if (kind === 'currentDrc' && !this.canUseCurrentDrc) return;
    try { this.fileAction(kind); } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private readFilter(): void {
    const filter: RdbReviewFilter = this.state.filter;
    this.searchText = filter.query.text === undefined ? '' : filter.query.text;
    this.categoryKeys = filter.categories === undefined ? (filter.query.category === undefined ? [] : [JSON.stringify(filter.query.category)]) : filter.categories.map((path: string[]): string => JSON.stringify(path));
    this.cellKeys = filter.cells === undefined ? (filter.query.cell === undefined ? [] : [filter.query.cell]) : filter.cells.slice();
    this.tagKeys = filter.query.tags === undefined ? [] : filter.query.tags.map((tag: RdbTagRef): string => JSON.stringify(tag));
    this.statusIndex = filter.query.visited === true ? 1 : filter.query.visited === false ? 2 : 0;
    this.waivedIndex = filter.waived === true ? 1 : filter.waived === false ? 2 : 0;
    this.importantIndex = filter.important === true ? 1 : filter.important === false ? 2 : 0;
    const sort: string = filter.sortBy === undefined ? 'index' : filter.sortBy;
    this.sortIndex = ['index', 'category', 'cell', 'multiplicity', 'value'].indexOf(sort);
    this.descending = filter.descending === true;
  }
  private toggleChoice(kind: string, key: string, checked: boolean): void {
    if (!this.loaded()) return;
    const keys: string[] = kind === 'category' ? this.categoryKeys : kind === 'cell' ? this.cellKeys : this.tagKeys;
    const next: string[] = checked ? (keys.includes(key) ? keys.slice() : keys.concat([key])) : keys.filter((value: string): boolean => value !== key);
    if (kind === 'category') this.categoryKeys = next; else if (kind === 'cell') this.cellKeys = next; else this.tagKeys = next;
  }
  private applyFilter(reset: boolean = false): void {
    if (!this.loaded() || !this.navigationAllowed()) return;
    const filter: RdbReviewFilter = { query: {} };
    if (!reset) {
      if (this.searchText.length > 0) filter.query.text = this.searchText;
      if (this.categoryKeys.length > 0) { filter.categories = this.categoryKeys.map((key: string): string[] => JSON.parse(key) as string[]); filter.query.includeDescendants = true; }
      if (this.cellKeys.length > 0) filter.cells = this.cellKeys.slice();
      if (this.tagKeys.length > 0) filter.query.tags = this.tagKeys.map((key: string): RdbTagRef => JSON.parse(key) as RdbTagRef);
      if (this.statusIndex === 1 || this.statusIndex === 2) filter.query.visited = this.statusIndex === 1;
      if (this.waivedIndex === 1 || this.waivedIndex === 2) filter.waived = this.waivedIndex === 1;
      if (this.importantIndex === 1 || this.importantIndex === 2) filter.important = this.importantIndex === 1;
      filter.sortBy = this.sortIndex === 1 ? 'category' : this.sortIndex === 2 ? 'cell' : this.sortIndex === 3 ? 'multiplicity' : this.sortIndex === 4 ? 'value' : 'index';
      filter.descending = this.descending;
    }
    try { if (this.filterAction(filter)) { this.pane = 1; if (reset) this.readFilter(); } }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private changePage(index: number, size: number = this.state.page.pageSize): void {
    if (!this.loaded() || !this.navigationAllowed()) return;
    const count: number = Math.max(1, Math.ceil(this.state.page.filteredCount / size));
    if (!Number.isInteger(index) || !Number.isInteger(size) || size < 1 || index < 0 || index >= count) { this.localError = '页码超出当前筛选范围'; return; }
    try { if (this.pageAction(index, size)) this.pageText = ''; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private jumpPage(): void {
    if (!/^[1-9][0-9]*$/.test(this.pageText)) { this.localError = '请输入从 1 开始的页码'; return; }
    this.changePage(Number(this.pageText) - 1);
  }
  private selectMarker(index: number, token: string): void {
    if (!this.loaded() || !this.navigationAllowed()) return;
    if (token !== this.state.token) { this.localError = '报告已变化，请使用当前列表'; return; }
    if (!Number.isInteger(index) || index < 0 || index >= this.state.page.totalItems) { this.localError = '标记编号超出报告范围'; return; }
    try { if (this.selectAction(index)) { this.markerText = ''; this.pane = 2; } }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private jumpMarker(): void {
    if (!/^[1-9][0-9]*$/.test(this.markerText)) { this.localError = '请输入从 1 开始的标记编号'; return; }
    this.selectMarker(Number(this.markerText) - 1, this.state.token);
  }
  private chooseFrame(target: string, index: number): void {
    if (!this.loaded() || this.state.selected === null || !this.navigationAllowed()) return;
    try { if (this.frameAction(target, index)) this.layoutChoiceId = -1; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private bindCell(): void {
    if (!this.loaded() || !this.navigationAllowed() || this.state.frameIndex < 0 || this.layoutChoiceId < 0) return;
    if (!this.state.layoutCells.some((cell: RdbReviewLayoutCell): boolean => cell.id === this.layoutChoiceId)) { this.localError = '版图 Cell 已变化，请重新选择'; return; }
    try { this.bindAction(this.state.frameTarget, this.layoutChoiceId); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private locate(): void {
    if (!this.loaded() || !this.navigationAllowed() || !this.state.mappingCurrent || !this.state.canLocate) return;
    try { this.locateAction(); } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private closePanel(): void { if (this.navigationAllowed()) this.closeAction(); }
  private valueIndices(): number[] {
    const total: number = this.state.selected === null ? 0 : this.state.selected.item.values.length;
    const indices: number[] = [];
    for (let index: number = this.valuePage * this.valuePageSize; index < Math.min(total, (this.valuePage + 1) * this.valuePageSize); index++) indices.push(index);
    return indices;
  }
  private valuePageCount(): number { return Math.max(1, Math.ceil((this.state.selected === null ? 0 : this.state.selected.item.values.length) / this.valuePageSize)); }
  private changeValuePage(index: number): void {
    if (!Number.isInteger(index) || index < 0 || index >= this.valuePageCount()) { this.localError = '值页码超出范围'; return; }
    this.valuePage = index; this.valuePageText = '';
  }
  private jumpValuePage(): void {
    if (!/^[1-9][0-9]*$/.test(this.valuePageText)) { this.localError = '请输入从 1 开始的值页码'; return; }
    this.changeValuePage(Number(this.valuePageText) - 1);
  }
  private valueText(value: RdbValue): string { try { return rdbValueDisplay(value); } catch (error) { return error instanceof Error ? error.message : String(error); } }
  private frameLabel(path: RdbFramePath, index: number): string {
    return `${index + 1}. ${path.cells.join(' → ')} · r${path.transform.rotationDeg} / m${path.transform.mirror ? '是' : '否'} / s${path.transform.magnification} / (${path.transform.x}, ${path.transform.y}) μm`;
  }
  private frameOptions(): SelectOption[] { return this.state.frames.map((path: RdbFramePath, index: number): SelectOption => ({ value: this.frameLabel(path, index) })); }
  private cellOptions(): SelectOption[] { return this.state.cells.map((cell: RdbReviewCellChoice): SelectOption => ({ value: cell.qname })); }
  private layoutOptions(): SelectOption[] { return this.state.layoutCells.map((cell: RdbReviewLayoutCell): SelectOption => ({ value: `${cell.name} · ${cell.key}` })); }
  private rowStatus(row: RdbReviewRow): string { return `${row.item.visited ? '已查看' : '未查看'}${row.waived ? ' · 豁免' : ''}${row.important ? ' · 重要' : ''}`; }
  private markImageError(token: string, index: number, source: string): void {
    if (this.active && this.state.token === token && this.state.selected !== null && this.state.selected.index === index && this.state.imageSource === source) this.imageFailed = true;
  }

  private reportLabel(report: RdbReviewWorkspaceReport): string {
    return `${report.name} · ${report.id} · ${report.items} 项${report.dirty ? ' · 未导出' : ''}`;
  }
  private reportPageCount(): number { return Math.max(1, Math.ceil(this.state.reports.length / this.reportPageSize)); }
  private reportRows(): RdbReviewWorkspaceReport[] {
    return this.state.reports.slice(this.reportPage * this.reportPageSize, (this.reportPage + 1) * this.reportPageSize);
  }
  private changeReportPage(index: number, size: number = this.reportPageSize): void {
    if (!this.available() || ![10, 20].includes(size) || !Number.isInteger(index) || index < 0 ||
      index >= Math.max(1, Math.ceil(this.state.reports.length / size))) return;
    this.reportPage = index; this.reportPageSize = size; this.reportPageText = '';
  }
  private jumpReportPage(): void {
    if (!/^[1-9][0-9]*$/.test(this.reportPageText) || Number(this.reportPageText) > this.reportPageCount()) {
      this.localError = '报告页码超出范围'; return;
    }
    this.changeReportPage(Number(this.reportPageText) - 1);
  }
  private reportCurrent(id: string, workspace: string, context: string): boolean {
    if (!this.navigationAllowed()) return false;
    if (workspace !== this.state.workspaceToken || !this.state.reports.some((report: RdbReviewWorkspaceReport): boolean => report.id === id && report.contextToken === context)) {
      this.localError = '报告工作区或内容已改变，请使用当前列表重试。'; return false;
    }
    return true;
  }
  private activateReport(id: string, workspace: string, context: string): void {
    if (!this.reportCurrent(id, workspace, context)) return;
    try { if (this.reportActivateAction(id, workspace, context)) { this.mode = 0; this.localError = ''; } }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private closeReport(id: string, workspace: string, context: string): void {
    if (!this.reportCurrent(id, workspace, context)) return;
    try { this.reportCloseAction(id, workspace, context); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private reportFile(kind: string, id: string, workspace: string, context: string): void {
    if (!['save', 'reload'].includes(kind) || !this.reportCurrent(id, workspace, context)) return;
    try { this.reportFileAction(kind, id, workspace, context); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private transferOptions(): RdbReviewTransferOptions {
    return { fields: { comment: this.transferComment, visited: this.transferVisited, waived: this.transferWaived,
      important: this.transferImportant, userTags: this.transferUserTags, image: this.transferImage },
      duplicatePolicy: this.duplicatePolicyIndex === 1 ? 'consensus' : 'reject',
      targetConflictPolicy: this.targetConflictPolicyIndex === 1 ? 'overwrite' : 'reject',
      blockedPolicy: this.blockedPolicyIndex === 1 ? 'skip' : 'reject' };
  }
  private transferHasFields(): boolean {
    return this.transferComment || this.transferVisited || this.transferWaived || this.transferImportant || this.transferUserTags || this.transferImage;
  }
  private chooseTransferReport(source: boolean, id: string, workspace: string, context: string): void {
    if (!this.available() || workspace !== this.state.workspaceToken ||
      !this.state.reports.some((report: RdbReviewWorkspaceReport): boolean => report.id === id && report.contextToken === context)) return;
    if ((source ? this.transferSourceId : this.transferTargetId) === id || !this.navigationAllowed() || !this.invalidateTransferPreview()) return;
    if (source) this.transferSourceId = id; else this.transferTargetId = id;
    this.transferDetailIndex = -1;
  }
  private transferRequest(): RdbTransferUiRequest | null {
    const source: RdbReviewWorkspaceReport | undefined = this.state.reports.find((report: RdbReviewWorkspaceReport): boolean => report.id === this.transferSourceId);
    const target: RdbReviewWorkspaceReport | undefined = this.state.reports.find((report: RdbReviewWorkspaceReport): boolean => report.id === this.transferTargetId);
    if (source === undefined || target === undefined || source.id === target.id || !this.transferHasFields()) return null;
    return { workspaceToken: this.state.workspaceToken, sourceReportId: source.id, targetReportId: target.id,
      sourceContext: source.contextToken, targetContext: target.contextToken, options: this.transferOptions() };
  }
  private transferPreviewCurrent(): boolean {
    const request: RdbTransferUiRequest | null = this.transferRequest();
    return request !== null && this.state.transferPreview !== null &&
      this.transferRequestKey(request) === this.transferRequestKey(this.state.transferPreview.request);
  }
  private transferRequestKey(request: RdbTransferUiRequest): string {
    const options: RdbReviewTransferOptions = request.options;
    return JSON.stringify([request.workspaceToken, request.sourceReportId, request.targetReportId, request.sourceContext, request.targetContext,
      options.fields.comment, options.fields.visited, options.fields.waived, options.fields.important, options.fields.userTags, options.fields.image,
      options.duplicatePolicy, options.targetConflictPolicy, options.blockedPolicy]);
  }
  private isTransferFieldChecked(field: string): boolean {
    if (field === 'comment') return this.transferComment;
    if (field === 'visited') return this.transferVisited;
    if (field === 'waived') return this.transferWaived;
    if (field === 'important') return this.transferImportant;
    if (field === 'userTags') return this.transferUserTags;
    if (field === 'image') return this.transferImage;
    return false;
  }
  private transferFieldSpecs(): RdbTransferFieldSpec[] {
    return [
      { label: '评论', field: 'comment', checked: this.transferComment },
      { label: '已查看', field: 'visited', checked: this.transferVisited },
      { label: '豁免', field: 'waived', checked: this.transferWaived },
      { label: '重要', field: 'important', checked: this.transferImportant },
      { label: '用户标签', field: 'userTags', checked: this.transferUserTags },
      { label: '图片附件', field: 'image', checked: this.transferImage }
    ];
  }
  private mergeSourceRowSpecs(): RdbMergeSourceRowSpec[] {
    return this.mergeSourceRows().map((report: RdbReviewWorkspaceReport): RdbMergeSourceRowSpec => ({
      report,
      workspace: this.state.workspaceToken,
      checked: this.mergeSourceIds.includes(report.id),
      orderIndex: this.mergeSourceIds.indexOf(report.id)
    }));
  }
  private waiverRuleSpecs(): RdbWaiverRuleSpec[] {
    const version: string = this.state.waiverLibrary?.version ?? '';
    const context: string = this.waiverContextKey();
    return this.waiverRuleRows().map((rule: RdbWaiverRuleRow): RdbWaiverRuleSpec => ({
      rule,
      version,
      context,
      selected: this.waiverRuleIds.includes(rule.id)
    }));
  }
  private reportRowSpecs(): RdbReportRowSpec[] {
    return this.reportRows().map((report: RdbReviewWorkspaceReport): RdbReportRowSpec => ({
      report,
      workspace: this.state.workspaceToken,
      isActive: report.id === this.state.activeReportId
    }));
  }
  private setTransferField(field: string, value: boolean): void {
    if (!this.available()) return;
    const changed: boolean = field === 'comment' ? this.transferComment !== value : field === 'visited' ? this.transferVisited !== value :
      field === 'waived' ? this.transferWaived !== value : field === 'important' ? this.transferImportant !== value :
      field === 'userTags' ? this.transferUserTags !== value : field === 'image' ? this.transferImage !== value : false;
    if (!changed || !this.navigationAllowed() || !this.invalidateTransferPreview()) return;
    if (field === 'comment') this.transferComment = value;
    else if (field === 'visited') this.transferVisited = value;
    else if (field === 'waived') this.transferWaived = value;
    else if (field === 'important') this.transferImportant = value;
    else if (field === 'userTags') this.transferUserTags = value;
    else if (field === 'image') this.transferImage = value;
  }
  private chooseTransferPolicy(kind: string, index: number): void {
    if (!this.available() || (index !== 0 && index !== 1)) return;
    const changed: boolean = kind === 'duplicates' ? this.duplicatePolicyIndex !== index :
      kind === 'conflicts' ? this.targetConflictPolicyIndex !== index : kind === 'blocked' ? this.blockedPolicyIndex !== index : false;
    if (!changed || !this.navigationAllowed() || !this.invalidateTransferPreview()) return;
    if (kind === 'duplicates') this.duplicatePolicyIndex = index;
    else if (kind === 'conflicts') this.targetConflictPolicyIndex = index;
    else if (kind === 'blocked') this.blockedPolicyIndex = index;
  }
  private invalidateTransferPreview(): boolean {
    if (this.state.transferPreview === null) return true;
    const id: string = this.state.transferPreview.id;
    try {
      this.transferCancelAction(id);
      this.localError = '继承条件已改变，旧预览已取消；请重新预览。';
      return true;
    } catch (error) { this.localError = `旧预览未能取消，选项未改变：${error instanceof Error ? error.message : String(error)}`; return false; }
  }
  private showTransferChanges(index: number, id: string): void {
    if (!this.available() || this.state.transferPreview === null || this.state.transferPreview.id !== id ||
      !this.state.transferPreview.rows.some((row: RdbTransferUiRow): boolean => row.targetIndex === index)) return;
    this.transferDetailIndex = this.transferDetailIndex === index ? -1 : index;
  }
  private previewTransfer(): void {
    if (!this.navigationAllowed()) return;
    const request: RdbTransferUiRequest | null = this.transferRequest();
    if (request === null) { this.localError = '请选择两个不同的现有报告，并至少选择一个继承字段。'; return; }
    try { if (this.transferPreviewAction(request)) { this.transferPageText = ''; this.transferDetailIndex = -1; } }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private changeTransferPage(index: number, size: number): void {
    if (!this.available() || !this.transferPreviewCurrent() || this.state.transferPreview === null) return;
    if (![10, 20, 50].includes(size) || !Number.isInteger(index) || index < 0 || index >= Math.max(1, Math.ceil(this.state.transferPreview.totalRows / size))) {
      this.localError = '继承预览页码超出范围'; return;
    }
    const id: string = this.state.transferPreview.id;
    try { if (this.transferPageAction(id, index, size)) { this.transferPageText = ''; this.transferDetailIndex = -1; } }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private jumpTransferPage(): void {
    if (!/^[1-9][0-9]*$/.test(this.transferPageText) || this.state.transferPreview === null) {
      this.localError = '请输入从 1 开始的继承预览页码'; return;
    }
    this.changeTransferPage(Number(this.transferPageText) - 1, this.state.transferPreview.pageSize);
  }
  private applyTransfer(id: string): void {
    if (!this.navigationAllowed()) return;
    if (!this.transferPreviewCurrent() || this.state.transferPreview === null || this.state.transferPreview.id !== id) {
      this.localError = '报告或继承选项已变化，请重新预览。'; return;
    }
    if (!this.state.transferPreview.canApply || this.state.transferPreview.summary.changed === 0) return;
    try { this.transferApplyAction(id); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private cancelTransfer(id: string): void {
    if (!this.available() || this.state.transferPreview === null || this.state.transferPreview.id !== id) return;
    try { this.transferCancelAction(id); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private transferReportName(id: string): string {
    const report: RdbReviewWorkspaceReport | undefined = this.state.reports.find((value: RdbReviewWorkspaceReport): boolean => value.id === id);
    return report === undefined ? (id.length > 0 ? `${id}（已不在工作区）` : '请选择报告') : this.reportLabel(report);
  }
  private transferStatus(row: RdbTransferUiRow): string {
    if (row.status === 'unmatched') return '无匹配 · 保留目标';
    if (row.status === 'ambiguous') return '重复歧义 · 阻断';
    if (row.status === 'reference-mismatch') return '引用坐标系不一致 · 阻断';
    if (row.status === 'conflict') return '目标冲突 · 阻断';
    return row.changes === undefined || JSON.stringify(row.changes) === '{}' ? '匹配 · 无需修改' : '匹配 · 有字段变更';
  }
  private transferSourceIndices(row: RdbTransferUiRow): string {
    return row.sourceIndices.length === 0 ? '无' : row.sourceIndices.map((index: number): string => '#' + (index + 1)).join('、');
  }
  private transferChangeText(changes: RdbTransferUiChanges): string {
    const lines: string[] = [];
    if (changes.comment !== undefined) lines.push(`评论\n原值：${changes.comment.before}\n新值：${changes.comment.after}`);
    if (changes.visited !== undefined) lines.push(`已查看：${changes.visited.before ? '是' : '否'} → ${changes.visited.after ? '是' : '否'}`);
    if (changes.waived !== undefined) lines.push(`豁免：${changes.waived.before ? '是' : '否'} → ${changes.waived.after ? '是' : '否'}`);
    if (changes.important !== undefined) lines.push(`重要：${changes.important.before ? '是' : '否'} → ${changes.important.after ? '是' : '否'}`);
    if (changes.userTags !== undefined) lines.push(`用户标签\n原值：${JSON.stringify(changes.userTags.before)}\n新值：${JSON.stringify(changes.userTags.after)}`);
    if (changes.image !== undefined) lines.push(`图片内容已改变（${changes.image.beforeCharacters} → ${changes.image.afterCharacters} 字符）；这里只显示附件长度。`);
    return lines.length > 0 ? lines.join('\n\n') : '没有字段变更';
  }

  private mergeOptions(): RdbMergeOptions {
    return { structurePolicy: this.mergePolicyIndex === 1 ? 'namespace-sources' : 'reuse-identical',
      outputName: this.mergeName, outputDescription: this.mergeDescription };
  }
  private mergeRequest(): RdbMergeUiRequest | null {
    if (this.mergeSourceIds.length < 2 || this.mergeName.trim().length === 0) return null;
    const sources: RdbMergeUiSource[] = [];
    for (const id of this.mergeSourceIds) {
      const report: RdbReviewWorkspaceReport | undefined = this.state.reports.find((value: RdbReviewWorkspaceReport): boolean => value.id === id);
      if (report === undefined || sources.some((source: RdbMergeUiSource): boolean => source.reportId === id)) return null;
      sources.push({ reportId: id, sourceIdentity: report.source.identity, reportContext: report.contextToken });
    }
    return { workspaceToken: this.state.workspaceToken, sources: sources, options: this.mergeOptions() };
  }
  private mergeRequestKey(request: RdbMergeUiRequest): string {
    return JSON.stringify([request.workspaceToken,
      request.sources.map((source: RdbMergeUiSource): string[] => [source.reportId, source.sourceIdentity, source.reportContext]),
      request.options.structurePolicy, request.options.outputName, request.options.outputDescription]);
  }
  private mergePreviewCurrent(): boolean {
    const request: RdbMergeUiRequest | null = this.mergeRequest();
    return request !== null && this.state.mergePreview !== null &&
      this.mergeRequestKey(request) === this.mergeRequestKey(this.state.mergePreview.request);
  }
  private invalidateMergePreview(): boolean {
    if (this.state.mergePreview === null) return true;
    try {
      this.mergeCancelAction(this.state.mergePreview.id);
      this.localError = '合并条件已改变，旧预览已取消；请重新预览。';
      return true;
    } catch (error) { this.localError = `旧预览未能取消，设置未改变：${error instanceof Error ? error.message : String(error)}`; return false; }
  }
  private toggleMergeSource(id: string, checked: boolean, workspace: string, identity: string, context: string): void {
    if (!this.available() || workspace !== this.state.workspaceToken || !this.state.reports.some((report: RdbReviewWorkspaceReport): boolean =>
      report.id === id && report.source.identity === identity && report.contextToken === context)) return;
    if (this.mergeSourceIds.includes(id) === checked || !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    this.mergeSourceIds = checked ? this.mergeSourceIds.concat([id]) : this.mergeSourceIds.filter((value: string): boolean => value !== id);
    this.mergeSelectedPage = Math.min(this.mergeSelectedPage, this.mergeSelectedPageCount() - 1);
  }
  private mergeSelectionKey(): string { return JSON.stringify([this.state.workspaceToken, this.mergeSourceIds]); }
  private removeMergeSource(id: string, selection: string): void {
    if (!this.available() || selection !== this.mergeSelectionKey() || !this.mergeSourceIds.includes(id) ||
      !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    this.mergeSourceIds = this.mergeSourceIds.filter((value: string): boolean => value !== id);
    this.mergeSelectedPage = Math.min(this.mergeSelectedPage, this.mergeSelectedPageCount() - 1);
  }
  private moveMergeSource(id: string, delta: number, selection: string): void {
    if (!this.available() || selection !== this.mergeSelectionKey() || (delta !== -1 && delta !== 1)) return;
    const index: number = this.mergeSourceIds.indexOf(id); const target: number = index + delta;
    if (index < 0 || target < 0 || target >= this.mergeSourceIds.length || !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    const next: string[] = this.mergeSourceIds.slice(); const value: string = next[target];
    next[target] = id; next[index] = value; this.mergeSourceIds = next;
  }
  private selectMergePage(workspace: string, pageKey: string): void {
    if (!this.available() || workspace !== this.state.workspaceToken || pageKey !== JSON.stringify(this.mergeSourceRows())) return;
    const ids: string[] = this.mergeSourceRows().map((report: RdbReviewWorkspaceReport): string => report.id).filter((id: string): boolean => !this.mergeSourceIds.includes(id));
    if (ids.length === 0 || !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    this.mergeSourceIds = this.mergeSourceIds.concat(ids);
  }
  private clearMergeSources(): void {
    if (!this.available() || this.mergeSourceIds.length === 0 || !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    this.mergeSourceIds = []; this.mergeSelectedPage = 0;
  }
  private setMergeText(kind: string, value: string): void {
    const changed: boolean = kind === 'name' ? this.mergeName !== value : kind === 'description' ? this.mergeDescription !== value : false;
    if (!this.available() || !changed || !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    if (kind === 'name') this.mergeName = value; else this.mergeDescription = value;
  }
  private chooseMergePolicy(index: number): void {
    if (!this.available() || (index !== 0 && index !== 1) || this.mergePolicyIndex === index ||
      !this.navigationAllowed() || !this.invalidateMergePreview()) return;
    this.mergePolicyIndex = index;
  }
  private mergeSourcePageCount(): number { return Math.max(1, Math.ceil(this.state.reports.length / this.mergeSourcePageSize)); }
  private mergeSourceRows(): RdbReviewWorkspaceReport[] {
    return this.state.reports.slice(this.mergeSourcePage * this.mergeSourcePageSize, (this.mergeSourcePage + 1) * this.mergeSourcePageSize);
  }
  private changeMergeSourcePage(index: number, size: number = this.mergeSourcePageSize): void {
    if (!this.available() || ![10, 20].includes(size) || !Number.isInteger(index) || index < 0 ||
      index >= Math.max(1, Math.ceil(this.state.reports.length / size))) return;
    this.mergeSourcePage = index; this.mergeSourcePageSize = size; this.mergeSourcePageText = '';
  }
  private jumpMergeSourcePage(): void {
    if (!/^[1-9][0-9]*$/.test(this.mergeSourcePageText) || Number(this.mergeSourcePageText) > this.mergeSourcePageCount()) {
      this.localError = '来源报告页码超出范围'; return;
    }
    this.changeMergeSourcePage(Number(this.mergeSourcePageText) - 1);
  }
  private mergeSelectedPageCount(): number { return Math.max(1, Math.ceil(this.mergeSourceIds.length / 10)); }
  private mergeSelectedRows(): string[] { return this.mergeSourceIds.slice(this.mergeSelectedPage * 10, (this.mergeSelectedPage + 1) * 10); }
  private changeMergeSelectedPage(index: number): void {
    if (this.available() && Number.isInteger(index) && index >= 0 && index < this.mergeSelectedPageCount()) this.mergeSelectedPage = index;
  }
  private previewMerge(): void {
    if (!this.navigationAllowed()) return;
    const request: RdbMergeUiRequest | null = this.mergeRequest();
    if (request === null) { this.localError = '请按顺序选择至少两份现有报告，并填写输出报告名称。'; return; }
    if (this.state.reports.length >= this.state.reportLimit) { this.localError = '报告工作区已满，请先关闭其他报告，为新报告留出一个位置。'; return; }
    try { if (this.mergePreviewAction(request)) this.mergePageText = ''; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private changeMergePage(index: number, size: number, id: string): void {
    if (!this.navigationAllowed() || !this.mergePreviewCurrent() || this.state.mergePreview === null || this.state.mergePreview.id !== id) return;
    if (![10, 20, 50].includes(size) || !Number.isInteger(index) || index < 0 || index >= Math.max(1, Math.ceil(this.state.mergePreview.totalRows / size))) {
      this.localError = '合并预览页码超出范围'; return;
    }
    try { if (this.mergePageAction(id, index, size)) this.mergePageText = ''; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private jumpMergePage(): void {
    if (!/^[1-9][0-9]*$/.test(this.mergePageText) || this.state.mergePreview === null) { this.localError = '请输入从 1 开始的合并预览页码'; return; }
    this.changeMergePage(Number(this.mergePageText) - 1, this.state.mergePreview.pageSize, this.state.mergePreview.id);
  }
  private applyMerge(id: string): void {
    if (!this.navigationAllowed()) return;
    if (!this.mergePreviewCurrent() || this.state.mergePreview === null || this.state.mergePreview.id !== id) {
      this.localError = '报告、来源顺序或合并设置已变化，请重新预览。'; return;
    }
    if (!this.state.mergePreview.canApply || this.state.reports.length >= this.state.reportLimit) return;
    try { this.mergeApplyAction(id); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private cancelMerge(id: string): void {
    if (!this.available() || this.state.mergePreview === null || this.state.mergePreview.id !== id) return;
    try { this.mergeCancelAction(id); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private mergeKind(row: RdbMergeRow): string {
    return row.kind === 'metadata' ? '来源信息' : row.kind === 'cell' ? 'Cell' : row.kind === 'category' ? '分类' :
      row.kind === 'tag' ? '标签映射' : row.kind === 'item' ? '标记' : '结构问题';
  }
  private mergeStatus(row: RdbMergeRow): string {
    return row.status === 'preserved' ? '完整保留' : row.status === 'reused' ? '复用相同定义' : row.status === 'renamed' ? '命名空间隔离' :
      row.status === 'conflict' ? '冲突 · 阻止合并' : '提示';
  }

  private waiverContextKey(): string {
    const report = this.state.reports.find((row: RdbReviewWorkspaceReport): boolean => row.id === this.state.activeReportId);
    return JSON.stringify([this.state.workspaceToken, this.state.activeReportId, this.state.token, report?.contextToken, this.state.waiverContext]);
  }
  private waiverRulePageCount(): number { return Math.max(1, Math.ceil((this.state.waiverLibrary?.rules.length ?? 0) / 10)); }
  private waiverRuleRows(): RdbWaiverRuleRow[] { return this.state.waiverLibrary?.rules.slice(this.waiverRulePage * 10, (this.waiverRulePage + 1) * 10) ?? []; }
  private waiverReady(): boolean {
    const context = this.state.waiverContext;
    return this.loaded() && !!this.state.waiverLibrary && !!context && context.workspaceToken === this.state.workspaceToken &&
      context.reportId === this.state.activeReportId && this.state.reports.some((report: RdbReviewWorkspaceReport): boolean => report.id === context.reportId && report.contextToken === context.reportContext);
  }
  private invalidateWaiver(): void { const id: string = this.state.waiverPreview?.id ?? ''; if (id) this.waiverCancelAction(id); }
  private chooseWaiver(id: string, version: string, context: string, selected: boolean): void {
    if (!this.navigationAllowed() || (this.state.loaded && !this.waiverReady()) || version !== this.state.waiverLibrary?.version || context !== this.waiverContextKey() ||
      !this.state.waiverLibrary?.rules.some((rule: RdbWaiverRuleRow): boolean => rule.id === id)) return;
    this.waiverRuleIds = selected ? (this.waiverRuleIds.includes(id) ? this.waiverRuleIds : this.waiverRuleIds.concat([id])) : this.waiverRuleIds.filter((value: string): boolean => value !== id);
    this.invalidateWaiver();
  }
  private chooseWaiverOperation(index: number): void { if (!this.navigationAllowed() || ![0, 1].includes(index)) return; this.waiverOperation = index; this.invalidateWaiver(); }
  private captureWaiver(): void {
    if (!this.navigationAllowed() || !this.waiverReady() || this.state.selected === null || !this.waiverName.trim() || !this.waiverRationale.trim()) return;
    const name: string = this.waiverName, rationale: string = this.waiverRationale, context: string = this.waiverContextKey();
    try {
      const request: RdbWaiverCaptureRequest = { context: this.state.waiverContext!, libraryVersion: this.state.waiverLibrary!.version,
        itemIndex: this.state.selected.index, name, rationale };
      if (this.waiverCaptureAction(request) && this.active && context === this.waiverContextKey() && name === this.waiverName && rationale === this.waiverRationale) {
        this.waiverName = ''; this.waiverRationale = ''; this.localError = '';
      }
    } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private waiverRequest(): RdbWaiverUiRequest | null {
    if (!this.waiverReady() || this.waiverRuleIds.length === 0) return null;
    return { context: this.state.waiverContext!, libraryVersion: this.state.waiverLibrary!.version,
      ruleIds: this.waiverRuleIds.slice(), operation: this.waiverOperation === 0 ? 'apply' : 'remove' };
  }
  private previewWaiver(): void {
    if (!this.navigationAllowed()) return; const request = this.waiverRequest(); if (request === null) return;
    try { if (this.waiverPreviewAction(request)) this.waiverPageText = ''; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private waiverPreviewCurrent(): boolean {
    const preview = this.state.waiverPreview, request = this.waiverRequest();
    return preview !== undefined && preview !== null && request !== null && preview.libraryVersion === request.libraryVersion &&
      JSON.stringify(preview.context) === JSON.stringify(request.context) && JSON.stringify(preview.ruleIds) === JSON.stringify(request.ruleIds) && preview.operation === request.operation;
  }
  private applyWaiver(id: string): void {
    if (!this.navigationAllowed() || !this.waiverPreviewCurrent() || this.state.waiverPreview?.id !== id || !this.state.waiverPreview.canApply || this.state.waiverPreview.summary.changed <= 0) return;
    try { this.waiverApplyAction(id); } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private cancelWaiver(id: string): void {
    if (!this.available() || this.state.waiverPreview?.id !== id) return;
    try { this.waiverCancelAction(id); } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private deleteWaiver(id: string, version: string, context: string): void {
    if (!this.navigationAllowed() || (this.state.loaded && !this.waiverReady()) || version !== this.state.waiverLibrary?.version || context !== this.waiverContextKey() || !this.state.waiverLibrary?.rules.some((rule: RdbWaiverRuleRow): boolean => rule.id === id)) return;
    try { this.waiverDeleteAction(id, version); } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private fileWaiver(kind: string): void {
    if (!this.navigationAllowed() || !this.state.waiverLibrary || !['import', 'export'].includes(kind)) return;
    try { this.waiverFileAction({ kind: kind === 'import' ? 'import' : 'export', libraryVersion: this.state.waiverLibrary.version, workspaceToken: this.state.workspaceToken }); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private changeWaiverRulePage(index: number): void {
    if (!this.available() || !Number.isSafeInteger(index) || index < 0 || index >= this.waiverRulePageCount()) return;
    this.waiverRulePage = index; this.waiverRulePageText = '';
  }
  private jumpWaiverRulePage(): void { if (!/^\d+$/.test(this.waiverRulePageText)) return; this.changeWaiverRulePage(Number(this.waiverRulePageText) - 1); }
  private changeWaiverPage(id: string, index: number): void {
    const preview = this.state.waiverPreview;
    if (!this.available() || !this.waiverPreviewCurrent() || !preview || preview.id !== id || !Number.isSafeInteger(index) || index < 0 || index >= preview.pageCount) return;
    try { if (this.waiverPageAction(id, index, preview.pageSize)) this.waiverPageText = ''; }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private jumpWaiverPage(id: string): void { if (!/^\d+$/.test(this.waiverPageText)) return; this.changeWaiverPage(id, Number(this.waiverPageText) - 1); }

  private selectedCategoryIndexes(): number[] {
    const indexes: number[] = [];
    for (let i: number = 0; i < this.state.categories.length; i++) {
      if (this.categoryKeys.includes(JSON.stringify(this.state.categories[i].path))) {
        indexes.push(i);
      }
    }
    return indexes;
  }

  private selectedCellIndexes(): number[] {
    const indexes: number[] = [];
    for (let i: number = 0; i < this.state.cells.length; i++) {
      if (this.cellKeys.includes(this.state.cells[i].qname)) {
        indexes.push(i);
      }
    }
    return indexes;
  }

  private selectedTagIndexes(): number[] {
    const indexes: number[] = [];
    for (let i: number = 0; i < this.state.tags.length; i++) {
      if (this.tagKeys.includes(JSON.stringify(this.state.tags[i].tag))) {
        indexes.push(i);
      }
    }
    return indexes;
  }

  private selectedReviewFlagIndexes(): number[] {
    const indexes: number[] = [];
    if (this.draftVisited) indexes.push(0);
    if (this.draftWaived) indexes.push(1);
    if (this.draftImportant) indexes.push(2);
    return indexes;
  }

  @Builder
  private FilterContent() {
    Column({ space: 10 }) {
      Text('筛选与报告').rdbSectionTitle()
      Search({ value: this.searchText, placeholder: '搜索标记内容' })
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
        .enabled(this.loaded())
        .onKeyEvent((event: KeyEvent) => event.stopPropagation())
        .onChange((text: string) => { this.searchText = text; })
        .onSubmit(() => { if (this.loaded()) this.applyFilter(); })
        .id('rdb-review-search')
      Select([{ value: '所有查看状态' }, { value: '已查看' }, { value: '未查看' }])
        .selected(this.statusIndex).value(['所有查看状态', '已查看', '未查看'][this.statusIndex])
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded()).onSelect((index: number) => this.statusIndex = index)
      Select([{ value: '所有豁免状态' }, { value: '已豁免' }, { value: '未豁免' }])
        .selected(this.waivedIndex).value(['所有豁免状态', '已豁免', '未豁免'][this.waivedIndex])
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded()).onSelect((index: number) => this.waivedIndex = index)
      Select([{ value: '所有重要状态' }, { value: '重要' }, { value: '非重要' }])
        .selected(this.importantIndex).value(['所有重要状态', '重要', '非重要'][this.importantIndex])
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded()).onSelect((index: number) => this.importantIndex = index)
      Select([{ value: '原始编号' }, { value: '分类' }, { value: 'Cell' }, { value: '出现次数' }, { value: '标记值' }])
        .selected(this.sortIndex).value(['原始编号', '分类', 'Cell', '出现次数', '标记值'][this.sortIndex])
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded()).onSelect((index: number) => this.sortIndex = index)
      SettingsToggleRow({
        title: '降序排列',
        isOn: this.descending,
        enabledState: this.loaded(),
        compact: true,
        onToggle: (value: boolean) => {
          if (value === this.descending) return;
          this.descending = value;
        }
      })
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('应用筛选', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary).margin({ right: 8, bottom: 4 }).enabled(this.loaded()).onClick(() => this.applyFilter()).id('rdb-review-filter-apply')
        Button('清空筛选', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.loaded()).onClick(() => this.applyFilter(true))
      }
      Text('分类（多选并集；不选为全部）').rdbSectionTitle()
      if (this.state.categories.length > 0) {
        // 严守官方规范：ChipGroup 外包容器承载布局属性，组件自身不链式追加通用属性
        Column() {
          ChipGroup({
            items: this.state.categories.map((choice: RdbReviewCategoryChoice): ChipGroupItemOptions => ({
              label: { text: `${choice.label} · ${choice.count}` },
              allowClose: false
            })),
            itemStyle: {
              size: ChipSize.SMALL,
              backgroundColor: COLORS.surfaceMuted,
              fontColor: COLORS.ink,
              selectedBackgroundColor: COLORS.primarySoft,
              selectedFontColor: COLORS.primary
            },
            selectedIndexes: this.selectedCategoryIndexes(),
            multiple: true,
            chipGroupSpace: { itemSpace: 6, startSpace: 0, endSpace: 0 },
            chipGroupPadding: { top: 4, bottom: 4 },
            onChange: (indexes: Array<number>) => {
              if (!this.loaded()) return;
              this.categoryKeys = indexes
                .filter((idx: number) => idx >= 0 && idx < this.state.categories.length)
                .map((idx: number) => JSON.stringify(this.state.categories[idx].path));
            }
          })
        }.width('100%').enabled(this.loaded()).opacity(this.loaded() ? 1.0 : 0.5)
      }
      Text('Cell（精确名称 / variant，多选并集）').rdbSectionTitle()
      if (this.state.cells.length > 0) {
        Column() {
          ChipGroup({
            items: this.state.cells.map((choice: RdbReviewCellChoice): ChipGroupItemOptions => ({
              label: { text: `${choice.qname} · ${choice.count}` },
              allowClose: false
            })),
            itemStyle: {
              size: ChipSize.SMALL,
              backgroundColor: COLORS.surfaceMuted,
              fontColor: COLORS.ink,
              selectedBackgroundColor: COLORS.primarySoft,
              selectedFontColor: COLORS.primary
            },
            selectedIndexes: this.selectedCellIndexes(),
            multiple: true,
            chipGroupSpace: { itemSpace: 6, startSpace: 0, endSpace: 0 },
            chipGroupPadding: { top: 4, bottom: 4 },
            onChange: (indexes: Array<number>) => {
              if (!this.loaded()) return;
              this.cellKeys = indexes
                .filter((idx: number) => idx >= 0 && idx < this.state.cells.length)
                .map((idx: number) => this.state.cells[idx].qname);
            }
          })
        }.width('100%').enabled(this.loaded()).opacity(this.loaded() ? 1.0 : 0.5)
      }
      Text('标签（多选交集，# 表示用户标签）').rdbSectionTitle()
      if (this.state.tags.length > 0) {
        Column() {
          ChipGroup({
            items: this.state.tags.map((choice: RdbReviewTagChoice): ChipGroupItemOptions => ({
              label: { text: choice.label },
              allowClose: false
            })),
            itemStyle: {
              size: ChipSize.SMALL,
              backgroundColor: COLORS.surfaceMuted,
              fontColor: COLORS.ink,
              selectedBackgroundColor: COLORS.primarySoft,
              selectedFontColor: COLORS.primary
            },
            selectedIndexes: this.selectedTagIndexes(),
            multiple: true,
            chipGroupSpace: { itemSpace: 6, startSpace: 0, endSpace: 0 },
            chipGroupPadding: { top: 4, bottom: 4 },
            onChange: (indexes: Array<number>) => {
              if (!this.loaded()) return;
              this.tagKeys = indexes
                .filter((idx: number) => idx >= 0 && idx < this.state.tags.length)
                .map((idx: number) => JSON.stringify(this.state.tags[idx].tag));
            }
          })
        }.width('100%').enabled(this.loaded()).opacity(this.loaded() ? 1.0 : 0.5)
      }
      Text('报告元数据').rdbSectionTitle()
      if (this.state.statistics !== undefined) {
        Text(`全报告：${this.state.statistics.all.items} 项 · 已查看 ${this.state.statistics.all.visited} · 豁免 ${this.state.statistics.all.waived} · 重要 ${this.state.statistics.all.important}\n次数加权：合计 ${this.state.statistics.all.multiplicity} · 已查看 ${this.state.statistics.all.visitedMultiplicity} · 豁免 ${this.state.statistics.all.waivedMultiplicity} · 重要 ${this.state.statistics.all.importantMultiplicity}`).rdbCaption().copyOption(CopyOptions.LocalDevice)
        Text(`当前筛选：${this.state.statistics.filtered.items} 项 · 已查看 ${this.state.statistics.filtered.visited} · 豁免 ${this.state.statistics.filtered.waived} · 重要 ${this.state.statistics.filtered.important}\n次数加权：合计 ${this.state.statistics.filtered.multiplicity} · 已查看 ${this.state.statistics.filtered.visitedMultiplicity} · 豁免 ${this.state.statistics.filtered.waivedMultiplicity} · 重要 ${this.state.statistics.filtered.importantMultiplicity}`).rdbCaption().copyOption(CopyOptions.LocalDevice)
      }
      Text(`文件：${this.state.sourceName}\n说明：${this.state.description}\n原始文件：${this.state.originalFile}\n生成器：${this.state.generator}\n顶层 Cell：${this.state.topCell}`).rdbCaption().copyOption(CopyOptions.LocalDevice)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
  }

  @Builder
  private MarkerRow(row: RdbReviewRow, token: string) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 5 }) {
        Text(`#${row.index + 1} · ${row.item.category.join(' / ')}`).rdbText().fontWeight(FontWeight.Medium)
        Text(`Cell ${row.item.cell} · 次数 ${row.item.multiplicity}`).rdbCaption()
        Text(this.rowStatus(row)).rdbCaption().fontColor(COLORS.primary)
        Text(`值 ${row.item.values.length} 项 · ${row.item.comment.length > 0 ? '有评论' : '无评论'}${row.item.image.length > 0 ? ' · 有图片' : ''}`).rdbCaption()
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.width('100%').padding(10).backgroundColor(this.state.selected !== null && this.state.selected.index === row.index ? COLORS.primarySoft : COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(this.loaded()).onClick(() => this.selectMarker(row.index, token)).id(`rdb-review-marker-${row.index}`)
  }

  @Builder
  private MarkerContent() {
    Column({ space: 8 }) {
      Text(`标记列表 · 筛选 ${this.state.page.filteredCount} / 全部 ${this.state.page.totalItems}`).rdbSectionTitle()
      Row({ space: 6 }) {
        TextInput({ text: this.markerText, placeholder: '当前筛选内任意编号' }).rdbInput().layoutWeight(1).onChange((text: string) => this.markerText = text)
        Button('转到', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.loaded()).onClick(() => this.jumpMarker()).id('rdb-review-marker-jump')
      }
      if (this.state.page.rows.length === 0) { Text(this.state.loaded ? '当前筛选没有标记。' : '打开报告或导入当前 DRC 结果。').rdbCaption() }
      ForEach(this.state.page.rows, (row: RdbReviewRow) => { this.MarkerRow(row, this.state.token) }, (row: RdbReviewRow) => this.state.token + ':' + row.index)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
  }

  @Builder
  private ReviewEditor() {
    Text('审阅内容').rdbSectionTitle()
    Column() {
      ChipGroup({
        items: [
          { label: { text: '已查看' }, allowClose: false },
          { label: { text: '已豁免' }, allowClose: false },
          { label: { text: '重要' }, allowClose: false }
        ],
        itemStyle: {
          size: ChipSize.SMALL,
          backgroundColor: COLORS.surfaceMuted,
          fontColor: COLORS.ink,
          selectedBackgroundColor: COLORS.primarySoft,
          selectedFontColor: COLORS.primary
        },
        selectedIndexes: this.selectedReviewFlagIndexes(),
        multiple: true,
        chipGroupSpace: { itemSpace: 8, startSpace: 0, endSpace: 0 },
        chipGroupPadding: { top: 4, bottom: 4 },
        onChange: (indexes: Array<number>) => {
          if (!this.currentDraft()) return;
          this.draftVisited = indexes.indexOf(0) >= 0;
          this.draftWaived = indexes.indexOf(1) >= 0;
          this.draftImportant = indexes.indexOf(2) >= 0;
          this.changedDraft();
        }
      })
    }.width('100%').enabled(this.currentDraft()).opacity(this.currentDraft() ? 1.0 : 0.5).id('rdb-review-flags')
    TextArea({ text: this.draftComment, placeholder: '评论' }).width('100%').height(112).fontSize(UI.fontBody).fontColor(COLORS.ink)
      .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      .enabled(this.currentDraft()).onChange((text: string) => { this.draftComment = text; this.changedDraft(); }).id('rdb-review-comment')
    Flex({ wrap: FlexWrap.Wrap }) {
      Button('保存审阅', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).backgroundColor(COLORS.primary).fontColor(Color.White)
        .margin({ right: 8, bottom: 4 }).enabled(this.currentDraft() && this.draftDirty).onClick(() => this.saveReview()).id('rdb-review-save-edit')
      Button('取消编辑', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.draftDirty).onClick(() => this.cancelDraft()).id('rdb-review-cancel-edit')
    }
    if (this.draftDirty) { Text('未提交审阅修改').rdbCaption() }
  }

  @Builder
  private LocationEditor() {
    Text('坐标系与 Cell 映射').rdbSectionTitle()
    Select(this.cellOptions()).value(this.state.frameTarget || '选择报告目标 Cell').selected(this.state.cells.findIndex((cell: RdbReviewCellChoice): boolean => cell.qname === this.state.frameTarget))
      .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded()).onSelect((index: number) => { if (index >= 0 && index < this.state.cells.length) this.chooseFrame(this.state.cells[index].qname, -1); }).id('rdb-review-frame-target')
    Select(this.frameOptions()).value(this.state.frameIndex >= 0 && this.state.frameIndex < this.state.frames.length ? this.frameLabel(this.state.frames[this.state.frameIndex], this.state.frameIndex) : '选择具体实例 frame')
      .selected(this.state.frameIndex).width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded() && this.state.frames.length > 0)
      .onSelect((index: number) => this.chooseFrame(this.state.frameTarget, index)).id('rdb-review-frame-path')
    if (this.state.frameMessage.length > 0) { Text(this.state.frameMessage).rdbCaption() }
    if (this.state.frameIndex >= 0 && this.state.frameIndex < this.state.frames.length) { Text(this.frameLabel(this.state.frames[this.state.frameIndex], this.state.frameIndex)).rdbCaption().copyOption(CopyOptions.LocalDevice) }
    Text(`当前版图：${this.state.layoutDocumentTitle || '未打开'}`).rdbCaption()
    Select(this.layoutOptions()).value(this.layoutChoiceId < 0 ? '明确选择当前版图 Cell' : this.state.layoutCells.find((cell: RdbReviewLayoutCell): boolean => cell.id === this.layoutChoiceId)?.name || '重新选择 Cell')
      .selected(this.state.layoutCells.findIndex((cell: RdbReviewLayoutCell): boolean => cell.id === this.layoutChoiceId))
      .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded() && this.state.layoutCells.length > 0)
      .onSelect((index: number) => { if (index >= 0 && index < this.state.layoutCells.length) this.layoutChoiceId = this.state.layoutCells[index].id; }).id('rdb-review-layout-cell')
    Flex({ wrap: FlexWrap.Wrap }) {
      Button('绑定所选 Cell', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 }).enabled(this.loaded() && this.layoutChoiceId >= 0 && this.state.frameIndex >= 0).onClick(() => this.bindCell()).id('rdb-review-bind')
      Button('解除当前关联', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 }).enabled(this.loaded() && !this.draftDirty && this.state.frameTarget.length > 0)
        .onClick(() => { if (this.loaded() && !this.draftDirty && !this.bindAction(this.state.frameTarget, -1)) this.localError = '关联未解除，请核对当前报告'; }).id('rdb-review-unbind')
      Button('定位标记', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary).margin({ right: 8, bottom: 4 }).enabled(this.loaded() && this.state.mappingCurrent && this.state.canLocate).onClick(() => this.locate()).id('rdb-review-locate')
      Button('清除标记覆盖', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available()).onClick(() => this.clearOverlayAction())
    }
    Text(this.state.mappingCurrent ? `已绑定版图 Cell #${this.state.boundLayoutCellId}` : '未绑定版图 Cell').rdbCaption()
  }

  @Builder
  private ValuesContent() {
    Text(`全部标记值 · ${this.state.selected === null ? 0 : this.state.selected.item.values.length} 项`).rdbSectionTitle()
    ForEach(this.valueIndices(), (index: number) => {
      Column({ space: 5 }) {
        Text(`#${index + 1} · ${this.state.selected!.item.values[index].kind}`).rdbText().fontWeight(FontWeight.Medium)
        Text(this.valueText(this.state.selected!.item.values[index])).rdbText().copyOption(CopyOptions.LocalDevice)
        Text(JSON.stringify(this.state.selected!.item.values[index], null, 2)).rdbCaption().copyOption(CopyOptions.LocalDevice)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(8).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
    }, (index: number) => this.state.token + ':' + (this.state.selected === null ? -1 : this.state.selected.index) + ':' + index)
    Flex({ wrap: FlexWrap.Wrap }) {
      Button('前一值页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.valuePage > 0).onClick(() => this.changeValuePage(this.valuePage - 1))
      Text(`${this.valuePage + 1}/${this.valuePageCount()}`).rdbCaption().width(72).margin({ right: 6, top: 9 })
      Button('后一值页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.valuePage + 1 < this.valuePageCount()).onClick(() => this.changeValuePage(this.valuePage + 1))
    }
    Row({ space: 6 }) {
      TextInput({ text: this.valuePageText, placeholder: '任意值页码' }).rdbInput().layoutWeight(1).onChange((text: string) => this.valuePageText = text)
      Button('转到值页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => this.jumpValuePage())
    }
  }

  @Builder
  private DetailContent() {
    Column({ space: 10 }) {
      if (this.state.selected === null && !this.draftDirty) { Text('未选择标记').rdbCaption() }
      if (this.state.selected !== null) {
        Text(`标记 #${this.state.selected.index + 1} · ${this.rowStatus(this.state.selected)}`).rdbSectionTitle()
        Text(`分类：${this.state.selected.item.category.join(' / ')}\nCell：${this.state.selected.item.cell}\n出现次数：${this.state.selected.item.multiplicity}\n标签：${this.state.selected.item.tags.map((tag: RdbTagRef): string => (tag.user ? '#' : '') + tag.name).join('、')}`).rdbText().copyOption(CopyOptions.LocalDevice)
      }
      if (this.state.selected !== null || this.draftDirty) { this.ReviewEditor() }
      if (this.state.selected !== null) {
        Text('标记几何（报告 Cell 坐标）').rdbSectionTitle()
        RdbMarkerOverlay({ item: this.state.selected.item, preview: true }).width('100%').height(160).id('rdb-review-geometry')
        this.LocationEditor()
        this.ValuesContent()
        if (this.state.selected.item.image.length > 0 || this.state.imageSource.length > 0) {
          Text('报告嵌入图片').rdbSectionTitle()
          if (this.state.imageSource.length > 0 && !this.imageFailed) {
            ForEach([this.state.imageSource], (source: string) => {
              this.ReportImage(source, this.state.token, this.state.selected!.index)
            }, (source: string) => JSON.stringify([this.state.token, this.state.selected!.index, source]))
          }
          if (this.imageFailed || this.state.imageSource.length === 0) {
            Text('图片暂无法预览，原附件仍保留').rdbCaption()
          }
        }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10)
  }

  @Builder
  private ReportImage(source: string, token: string, index: number) {
    Image(source).width('100%').height(220).objectFit(ImageFit.Contain).borderRadius(UI.controlRadius)
      .onError(() => this.markImageError(token, index, source)).id('rdb-review-image')
  }

  @Builder
  private Pagination() {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.loaded() && this.state.page.pageIndex > 0).onClick(() => this.changePage(this.state.page.pageIndex - 1)).id('rdb-review-page-prev')
        Text(`${this.state.page.pageIndex + 1}/${Math.max(1, this.state.page.pageCount)} 页`).rdbCaption().width(92).margin({ right: 6, top: 9 })
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.loaded() && this.state.page.pageIndex + 1 < this.state.page.pageCount).onClick(() => this.changePage(this.state.page.pageIndex + 1)).id('rdb-review-page-next')
        Select([{ value: '20 / 页' }, { value: '50 / 页' }, { value: '100 / 页' }]).value(`${this.state.page.pageSize} / 页`)
          .selected([20, 50, 100].indexOf(this.state.page.pageSize)).width(120).height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.loaded())
          .onSelect((index: number) => { if (index >= 0 && index < 3) this.changePage(0, [20, 50, 100][index]); })
      }.width('100%')
      Row({ space: 6 }) {
        TextInput({ text: this.pageText, placeholder: '任意页码' }).rdbInput().layoutWeight(1).onChange((text: string) => this.pageText = text)
        Button('转到页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.loaded()).onClick(() => this.jumpPage()).id('rdb-review-page-jump')
      }.width('100%')
    }.width('100%').padding({ top: 8 }).border({ width: { top: 1 }, color: COLORS.border }).id('rdb-review-pagination')
  }

  @Builder
  private TransferReportPicker(source: boolean, reports: RdbReviewWorkspaceReport[], workspace: string) {
    Select(reports.map((report: RdbReviewWorkspaceReport): SelectOption => ({ value: this.reportLabel(report) })))
      .selected(reports.findIndex((report: RdbReviewWorkspaceReport): boolean => report.id === (source ? this.transferSourceId : this.transferTargetId)))
      .value(this.transferReportName(source ? this.transferSourceId : this.transferTargetId)).width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
      .enabled(this.available() && reports.length > 0).onSelect((index: number) => {
        if (index >= 0 && index < reports.length) this.chooseTransferReport(source, reports[index].id, workspace, reports[index].contextToken);
      }).id(source ? 'rdb-review-transfer-source' : 'rdb-review-transfer-target')
  }

  @Builder
  private TransferField(spec: RdbTransferFieldSpec) {
    Row({ space: 4 }) {
      Checkbox().select(spec.checked).enabled(this.available()).onChange((value: boolean) => {
        if (value === this.isTransferFieldChecked(spec.field)) return;
        this.setTransferField(spec.field, value);
      }).id('rdb-review-transfer-field-' + spec.field)
      Text(spec.label).fontSize(UI.fontBody).fontColor(COLORS.ink)
    }.margin({ right: 12, bottom: 4 })
  }

  @Builder
  private TransferEndpoint(source: boolean) {
    Column({ space: 4 }) {
      Text(source ? '来源报告' : '目标报告（接收修改）').rdbCaption()
      ForEach([JSON.stringify([source, this.state.workspaceToken, this.state.reports])], (snapshot: string) => {
        this.TransferReportPicker(source, this.state.reports, this.state.workspaceToken)
      }, (snapshot: string) => snapshot)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TransferDuplicatePolicy() {
    Column({ space: 4 }) {
      Text('来源重复标记').rdbCaption()
      Select([{ value: '拒绝重复匹配' }, { value: '仅选定字段一致时合并重复' }]).selected(this.duplicatePolicyIndex)
        .value(this.duplicatePolicyIndex === 1 ? '仅选定字段一致时合并重复' : '拒绝重复匹配').width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.available()).onSelect((index: number) => this.chooseTransferPolicy('duplicates', index)).id('rdb-review-transfer-duplicates')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TransferConflictPolicy() {
    Column({ space: 4 }) {
      Text('目标已有不同审阅记录').rdbCaption()
      Select([{ value: '拒绝覆盖目标冲突' }, { value: '用来源覆盖选定字段' }]).selected(this.targetConflictPolicyIndex)
        .value(this.targetConflictPolicyIndex === 1 ? '用来源覆盖选定字段' : '拒绝覆盖目标冲突').width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.available()).onSelect((index: number) => this.chooseTransferPolicy('conflicts', index)).id('rdb-review-transfer-conflicts')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TransferBlockedPolicy() {
    Column({ space: 4 }) {
      Text('歧义、引用不一致或冲突').rdbCaption()
      Select([{ value: '存在阻断项时整批不应用' }, { value: '明确跳过阻断项，仅应用匹配项' }]).selected(this.blockedPolicyIndex)
        .value(this.blockedPolicyIndex === 1 ? '明确跳过阻断项，仅应用匹配项' : '存在阻断项时整批不应用').width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.available()).onSelect((index: number) => this.chooseTransferPolicy('blocked', index)).id('rdb-review-transfer-blocked')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TransferControls() {
    Column({ space: 8 }) {
      Text('将来源报告的审阅记录继承到目标报告').rdbSectionTitle()
      if (this.panelWidth >= 1000) {
        Row({ space: 12 }) {
          Column() { this.TransferEndpoint(true) }.layoutWeight(1)
          Column() { this.TransferEndpoint(false) }.layoutWeight(1)
        }.width('100%').alignItems(VerticalAlign.Top)
      } else { this.TransferEndpoint(true); this.TransferEndpoint(false) }
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.transferFieldSpecs(), (spec: RdbTransferFieldSpec) => {
          this.TransferField(spec)
        }, (spec: RdbTransferFieldSpec): string => spec.field)
      }.width('100%')
      if (this.panelWidth >= 1000) {
        Row({ space: 12 }) {
          Column() { this.TransferDuplicatePolicy() }.layoutWeight(1)
          Column() { this.TransferConflictPolicy() }.layoutWeight(1)
          Column() { this.TransferBlockedPolicy() }.layoutWeight(1)
        }.width('100%').padding({ right: 4 }).alignItems(VerticalAlign.Top)
      } else { this.TransferDuplicatePolicy(); this.TransferConflictPolicy(); this.TransferBlockedPolicy() }
      Button('预览匹配', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary).enabled(this.available() && this.transferRequest() !== null)
        .onClick(() => this.previewTransfer()).id('rdb-review-transfer-preview')
      if (this.state.reports.length < 2) { Text('请在“报告”中新增打开至少两份报告。').rdbCaption() }
      this.StatusContent()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private TransferSummary() {
    if (this.state.transferPreview !== null) {
      Column({ space: 6 }) {
        Text(`预览：${this.transferReportName(this.state.transferPreview.request.sourceReportId)} → ${this.transferReportName(this.state.transferPreview.request.targetReportId)}`).rdbSectionTitle()
        Text(`来源 ${this.state.transferPreview.summary.sourceItems} 项 · 目标 ${this.state.transferPreview.summary.targetItems} 项\n匹配 ${this.state.transferPreview.summary.matched} · 实际有变更 ${this.state.transferPreview.summary.changed} · 无需修改 ${this.state.transferPreview.summary.noChanges}\n无匹配 ${this.state.transferPreview.summary.unmatched} · 歧义 ${this.state.transferPreview.summary.ambiguous} · 引用不一致 ${this.state.transferPreview.summary.referenceMismatch} · 冲突 ${this.state.transferPreview.summary.conflict}\n阻断 ${this.state.transferPreview.summary.blocked} · 未使用来源 ${this.state.transferPreview.summary.unusedSourceItems}`).rdbText().copyOption(CopyOptions.LocalDevice)
        if (!this.transferPreviewCurrent()) { Text('报告或选项已改变；这份预览已失效，请重新预览。').rdbCaption().fontColor(COLORS.danger) }
        if (this.state.transferPreview.message.length > 0) { Text(this.state.transferPreview.message).rdbCaption() }
      }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius).id('rdb-review-transfer-summary')
    }
  }

  @Builder
  private TransferRow(row: RdbTransferUiRow, previewId: string) {
    Column({ space: 6 }) {
      Text(`目标 #${row.targetIndex + 1} ← 来源 ${this.transferSourceIndices(row)}`).rdbSectionTitle().copyOption(CopyOptions.LocalDevice)
      Text(this.transferStatus(row)).rdbText().fontColor(row.status === 'matched' ? COLORS.primary : row.status === 'unmatched' ? COLORS.muted : COLORS.danger)
      Text(row.reason).rdbCaption().copyOption(CopyOptions.LocalDevice)
      if (row.changes !== undefined) {
        Button(this.transferDetailIndex === row.targetIndex ? '收起字段变更' : '查看字段变更', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available())
          .onClick(() => this.showTransferChanges(row.targetIndex, previewId)).id('rdb-review-transfer-changes-' + row.targetIndex)
        if (this.transferDetailIndex === row.targetIndex) { Text(this.transferChangeText(row.changes)).rdbText().copyOption(CopyOptions.LocalDevice).id('rdb-review-transfer-change-detail') }
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius)
  }

  @Builder
  private TransferRows() {
    if (this.state.transferPreview !== null) {
      Column({ space: 8 }) {
        ForEach(this.state.transferPreview.rows, (row: RdbTransferUiRow) => {
          this.TransferRow(row, this.state.transferPreview!.id)
        }, (row: RdbTransferUiRow) => this.state.transferPreview!.id + ':' + row.targetIndex + ':' + JSON.stringify(row))
      }.width('100%').alignItems(HorizontalAlign.Start).id('rdb-review-transfer-rows')
    }
  }

  @Builder
  private TransferPagination() {
    if (this.state.transferPreview !== null) {
      Column({ space: 6 }) {
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.transferPreviewCurrent() && this.state.transferPreview.pageIndex > 0)
            .onClick(() => this.changeTransferPage(this.state.transferPreview!.pageIndex - 1, this.state.transferPreview!.pageSize)).id('rdb-review-transfer-prev')
          Text(`${this.state.transferPreview.pageIndex + 1}/${Math.max(1, this.state.transferPreview.pageCount)} 页 · 共 ${this.state.transferPreview.totalRows} 项`).rdbCaption().width(155).margin({ right: 6, top: 9 })
          Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.transferPreviewCurrent() && this.state.transferPreview.pageIndex + 1 < this.state.transferPreview.pageCount)
            .onClick(() => this.changeTransferPage(this.state.transferPreview!.pageIndex + 1, this.state.transferPreview!.pageSize)).id('rdb-review-transfer-next')
          Select([{ value: '10 / 页' }, { value: '20 / 页' }, { value: '50 / 页' }]).selected([10, 20, 50].indexOf(this.state.transferPreview.pageSize))
            .value(`${this.state.transferPreview.pageSize} / 页`).width(120).height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.available() && this.transferPreviewCurrent())
            .onSelect((index: number) => { if (index >= 0 && index < 3) this.changeTransferPage(0, [10, 20, 50][index]); })
        }.width('100%')
        Row({ space: 6 }) {
          TextInput({ text: this.transferPageText, placeholder: '继承预览页码' }).rdbInput().layoutWeight(1).enabled(this.available()).onChange((text: string) => this.transferPageText = text)
          Button('转到页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.transferPreviewCurrent()).onClick(() => this.jumpTransferPage()).id('rdb-review-transfer-jump')
        }.width('100%').padding({ right: 4 })
      }.width('100%').id('rdb-review-transfer-pagination')
    }
  }

  @Builder
  private TransferActions(previewId: string) {
    Flex({ wrap: FlexWrap.Wrap }) {
      Button('取消预览', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 }).enabled(this.available()).onClick(() => this.cancelTransfer(previewId)).id('rdb-review-transfer-cancel')
      Button('确认应用继承…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor('#FFFFFF').backgroundColor(COLORS.primary)
        .enabled(this.available() && this.transferPreviewCurrent() && this.state.transferPreview !== null && this.state.transferPreview.canApply && this.state.transferPreview.summary.changed > 0)
        .onClick(() => this.applyTransfer(previewId)).id('rdb-review-transfer-apply')
    }.width('100%')
  }

  @Builder
  private MergeSourceRow(spec: RdbMergeSourceRowSpec) {
    Row({ space: 8 }) {
      Checkbox({ name: spec.report.id }).select(spec.checked).selectedColor(COLORS.primary)
        .enabled(this.available()).onChange((checked: boolean) => {
          if (checked === this.mergeSourceIds.includes(spec.report.id)) return;
          this.toggleMergeSource(spec.report.id, checked, spec.workspace, spec.report.source.identity, spec.report.contextToken);
        })
        .id('rdb-review-merge-source-' + spec.report.id)
      Column({ space: 4 }) {
        Text(spec.report.name).rdbSectionTitle()
        Text(`${spec.report.id} · ${spec.report.items} 个标记${spec.report.dirty ? ' · 未导出修改' : ''}`).rdbCaption()
        if (spec.checked && spec.orderIndex >= 0) { Text(`来源顺序 ${spec.orderIndex + 1}`).rdbCaption().fontColor(COLORS.primary) }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.width('100%').padding(8).backgroundColor(spec.checked ? COLORS.primarySoft : COLORS.surfaceMuted).borderRadius(UI.controlRadius)
  }

  @Builder
  private MergeSourcePagination(workspace: string, pageKey: string) {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergeSourcePage > 0)
          .onClick(() => this.changeMergeSourcePage(this.mergeSourcePage - 1)).id('rdb-review-merge-sources-prev')
        Text(`${this.mergeSourcePage + 1}/${this.mergeSourcePageCount()} 页 · 共 ${this.state.reports.length} 份`).rdbCaption().width(155).margin({ right: 6, top: 9 })
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergeSourcePage + 1 < this.mergeSourcePageCount())
          .onClick(() => this.changeMergeSourcePage(this.mergeSourcePage + 1)).id('rdb-review-merge-sources-next')
        Select([{ value: '10 / 页' }, { value: '20 / 页' }]).selected(this.mergeSourcePageSize === 10 ? 0 : 1).value(`${this.mergeSourcePageSize} / 页`)
          .width(120).height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.available()).onSelect((index: number) => {
            if (index === 0 || index === 1) this.changeMergeSourcePage(0, index === 0 ? 10 : 20);
          })
      }.width('100%')
      Row({ space: 6 }) {
        TextInput({ text: this.mergeSourcePageText, placeholder: '来源报告页码' }).rdbInput().layoutWeight(1).enabled(this.available())
          .onChange((text: string) => this.mergeSourcePageText = text).id('rdb-review-merge-sources-page-input')
        Button('转到页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available()).onClick(() => this.jumpMergeSourcePage()).id('rdb-review-merge-sources-jump')
      }.width('100%').padding({ right: 4 })
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('选择本页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.state.reports.length > 0)
          .onClick(() => this.selectMergePage(workspace, pageKey)).id('rdb-review-merge-select-page')
        Button('清空选择', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.mergeSourceIds.length > 0)
          .onClick(() => this.clearMergeSources()).id('rdb-review-merge-clear-sources')
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private MergeSelectedRow(id: string, selection: string) {
    Column({ space: 4 }) {
      Text(`${this.mergeSourceIds.indexOf(id) + 1}. ${this.transferReportName(id)}`).rdbText().copyOption(CopyOptions.LocalDevice)
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上移', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergeSourceIds.indexOf(id) > 0)
          .onClick(() => this.moveMergeSource(id, -1, selection)).id('rdb-review-merge-up-' + id)
        Button('下移', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergeSourceIds.indexOf(id) + 1 < this.mergeSourceIds.length)
          .onClick(() => this.moveMergeSource(id, 1, selection)).id('rdb-review-merge-down-' + id)
        Button('移除', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available()).onClick(() => this.removeMergeSource(id, selection)).id('rdb-review-merge-remove-' + id)
      }.width('100%')
    }.width('100%').padding(8).alignItems(HorizontalAlign.Start).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
  }

  @Builder
  private MergeSources() {
    Column({ space: 8 }) {
      Text('1. 选择来源报告').rdbSectionTitle()
      ForEach([JSON.stringify([this.state.workspaceToken, this.mergeSourceRows()])], (snapshot: string) => {
        this.MergeSourcePagination(this.state.workspaceToken, JSON.stringify(this.mergeSourceRows()))
      }, (snapshot: string) => snapshot)
      ForEach(this.mergeSourceRowSpecs(), (spec: RdbMergeSourceRowSpec) => {
        this.MergeSourceRow(spec)
      }, (spec: RdbMergeSourceRowSpec): string => `${spec.workspace}:${spec.report.id}:${spec.report.contextToken}`)
      if (this.state.reports.length < 2) { Text('请先在“报告”中新增打开至少两份报告。').rdbCaption() }
      Text(`已选 ${this.mergeSourceIds.length} 份 · 以下顺序决定标记顺序及来源命名空间`).rdbSectionTitle().id('rdb-review-merge-selected-count')
      ForEach(this.mergeSelectedRows(), (id: string) => {
        this.MergeSelectedRow(id, this.mergeSelectionKey())
      }, (id: string) => this.mergeSelectionKey() + ':' + id + ':' + this.transferReportName(id))
      if (this.mergeSelectedPageCount() > 1) {
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('已选上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergeSelectedPage > 0)
            .onClick(() => this.changeMergeSelectedPage(this.mergeSelectedPage - 1)).id('rdb-review-merge-selected-prev')
          Text(`${this.mergeSelectedPage + 1}/${this.mergeSelectedPageCount()} 页`).rdbCaption().width(80).margin({ right: 6, top: 9 })
          Button('已选下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.mergeSelectedPage + 1 < this.mergeSelectedPageCount())
            .onClick(() => this.changeMergeSelectedPage(this.mergeSelectedPage + 1)).id('rdb-review-merge-selected-next')
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private MergeSettings() {
    Column({ space: 8 }) {
      Text('2. 设置独立输出报告').rdbSectionTitle()
      Text('报告名称').rdbCaption()
      TextInput({ text: this.mergeName, placeholder: '输出报告名称' }).rdbInput().width('100%').enabled(this.available())
        .onChange((text: string) => this.setMergeText('name', text)).id('rdb-review-merge-name')
      Text('报告说明').rdbCaption()
      TextArea({ text: this.mergeDescription, placeholder: '填写合并报告的说明（可选）' }).width('100%').height(88).fontSize(UI.fontBody)
        .fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .enabled(this.available()).onChange((text: string) => this.setMergeText('description', text)).id('rdb-review-merge-description')
      Text('结构策略').rdbCaption()
      Select([{ value: '复用相同定义，冲突时阻止合并' }, { value: '按来源隔离命名空间' }]).selected(this.mergePolicyIndex)
        .value(this.mergePolicyIndex === 1 ? '按来源隔离命名空间' : '复用相同定义，冲突时阻止合并').width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.available()).onSelect((index: number) => this.chooseMergePolicy(index)).id('rdb-review-merge-policy')
      if (this.state.reports.length >= this.state.reportLimit) { Text('报告工作区已满，请先关闭其他报告，为新报告留出一个位置。').rdbCaption().fontColor(COLORS.danger) }
      Button('生成合并预览', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary)
        .enabled(this.available() && this.mergeRequest() !== null && this.state.reports.length < this.state.reportLimit)
        .onClick(() => this.previewMerge()).id('rdb-review-merge-preview')
      this.StatusContent()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private MergeSummary(preview: RdbMergeUiPreview) {
    Column({ space: 6 }) {
      Text('3. 核对合并预览').rdbSectionTitle()
      Text(`输出：${preview.request.options.outputName}\n来源 ${preview.summary.sources} 份 · 输入标记 ${preview.summary.inputItems} · 输出标记 ${preview.summary.outputItems} · 值 ${preview.summary.values}\nCell ${preview.summary.cells} · 分类 ${preview.summary.categories} · 标签定义 ${preview.summary.tagDefinitions}\n保留 ${preview.summary.preserved} · 复用 ${preview.summary.reused} · 隔离重命名 ${preview.summary.renamed}\n冲突 ${preview.summary.conflicts} · 提示 ${preview.summary.notices}`).rdbText().copyOption(CopyOptions.LocalDevice)
      if (!this.mergePreviewCurrent()) { Text('来源、顺序或设置已改变；这份预览已失效，请重新预览。').rdbCaption().fontColor(COLORS.danger) }
      Text(preview.message).rdbCaption().fontColor(preview.canApply ? COLORS.primary : COLORS.danger)
      if (preview.notices.length > 0) { Text(preview.notices.join('\n')).rdbCaption().copyOption(CopyOptions.LocalDevice) }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius).id('rdb-review-merge-summary')
  }

  @Builder
  private MergePagination(preview: RdbMergeUiPreview) {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergePreviewCurrent() && preview.pageIndex > 0)
          .onClick(() => this.changeMergePage(preview.pageIndex - 1, preview.pageSize, preview.id)).id('rdb-review-merge-prev')
        Text(`${preview.pageIndex + 1}/${Math.max(1, preview.pageCount)} 页 · 共 ${preview.totalRows} 条映射`).rdbCaption().width(180).margin({ right: 6, top: 9 })
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.mergePreviewCurrent() && preview.pageIndex + 1 < preview.pageCount)
          .onClick(() => this.changeMergePage(preview.pageIndex + 1, preview.pageSize, preview.id)).id('rdb-review-merge-next')
        Select([{ value: '10 / 页' }, { value: '20 / 页' }, { value: '50 / 页' }]).selected([10, 20, 50].indexOf(preview.pageSize))
          .value(`${preview.pageSize} / 页`).width(120).height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.available() && this.mergePreviewCurrent())
          .onSelect((index: number) => { if (index >= 0 && index < 3) this.changeMergePage(0, [10, 20, 50][index], preview.id); })
      }.width('100%')
      Row({ space: 6 }) {
        TextInput({ text: this.mergePageText, placeholder: '合并预览页码' }).rdbInput().layoutWeight(1).enabled(this.available())
          .onChange((text: string) => this.mergePageText = text).id('rdb-review-merge-page-input')
        Button('转到页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.mergePreviewCurrent()).onClick(() => this.jumpMergePage()).id('rdb-review-merge-jump')
      }.width('100%').padding({ right: 4 })
    }.width('100%').id('rdb-review-merge-pagination')
  }

  @Builder
  private MergeRow(row: RdbMergeRow, index: number) {
    Column({ space: 6 }) {
      Text(`${index + 1}. ${this.mergeKind(row)} · ${this.mergeStatus(row)}`).rdbSectionTitle().fontColor(row.status === 'conflict' ? COLORS.danger : COLORS.ink)
      Text(`${row.sourceIndex < 0 ? '合并整体' : '来源 ' + (row.sourceIndex + 1)} · ${row.reportId}\n${row.sourceLabel}\n→ ${row.outputLabel}`).rdbText().copyOption(CopyOptions.LocalDevice)
      if (row.kind === 'item') { Text(`来源标记 ${row.sourceItemIndex < 0 ? '未指定' : '#' + (row.sourceItemIndex + 1)} → 输出标记 ${row.outputItemIndex < 0 ? '尚未生成' : '#' + (row.outputItemIndex + 1)}`).rdbCaption() }
      Text(row.reason).rdbText().copyOption(CopyOptions.LocalDevice)
    }.width('100%').alignItems(HorizontalAlign.Start).padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius).id('rdb-review-merge-row-' + index)
  }

  @Builder
  private MergeRows(preview: RdbMergeUiPreview) {
    Column({ space: 8 }) {
      ForEach(preview.rows, (row: RdbMergeRow, index: number) => {
        this.MergeRow(row, preview.pageIndex * preview.pageSize + index)
      }, (row: RdbMergeRow, index: number) => preview.id + ':' + preview.pageIndex + ':' + index + ':' + JSON.stringify(row))
    }.width('100%').alignItems(HorizontalAlign.Start).id('rdb-review-merge-rows')
  }

  @Builder
  private MergeActions(previewId: string) {
    Flex({ wrap: FlexWrap.Wrap }) {
      Button('取消预览', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 }).enabled(this.available())
        .onClick(() => this.cancelMerge(previewId)).id('rdb-review-merge-cancel')
      Button('确认创建独立报告…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor('#FFFFFF').backgroundColor(COLORS.primary)
        .enabled(this.available() && this.mergePreviewCurrent() && this.state.mergePreview !== null && this.state.mergePreview.canApply && this.state.reports.length < this.state.reportLimit)
        .onClick(() => this.applyMerge(previewId)).id('rdb-review-merge-apply')
    }.width('100%')
  }

  @Builder
  private WaiverCapture() {
    Column({ space: 8 }) {
      Text('捕获当前标记为豁免规则').rdbSectionTitle()
      Text(this.state.selected === null ? '请先在审阅页选择标记' : `来源 ${this.state.sourceName} · 标记 #${this.state.selected.index + 1}`).rdbCaption()
      TextInput({ text: this.waiverName, placeholder: '规则名称' }).rdbInput().enabled(this.available()).onChange((value: string) => this.waiverName = value).id('rdb-waiver-name')
      TextInput({ text: this.waiverRationale, placeholder: '豁免依据（必填，随规则保存）' }).rdbInput().enabled(this.available()).onChange((value: string) => this.waiverRationale = value).id('rdb-waiver-rationale')
      Button('捕获并保存当前标记', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.waiverReady() && this.state.selected !== null && this.waiverName.trim().length > 0 && this.waiverRationale.trim().length > 0)
        .onClick(() => this.captureWaiver()).id('rdb-waiver-capture')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WaiverRule(spec: RdbWaiverRuleSpec) {
    Row({ space: 8 }) {
      Checkbox().select(spec.selected).enabled(this.available())
        .onChange((checked: boolean) => {
          if (checked === this.waiverRuleIds.includes(spec.rule.id)) return;
          this.chooseWaiver(spec.rule.id, spec.version, spec.context, checked);
        }).id('rdb-waiver-rule-select-' + spec.rule.id)
      Column({ space: 4 }) {
        Text(spec.rule.name).rdbSectionTitle()
        Text(`${spec.rule.sourceName} · ${spec.rule.cell} · ${spec.rule.valueCount} 项值 · 应用 ${spec.rule.applications}`).rdbCaption()
        Text(spec.rule.rationale).rdbCaption()
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Button('删除…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.danger)
        .enabled(this.available()).onClick(() => this.deleteWaiver(spec.rule.id, spec.version, spec.context)).id('rdb-waiver-rule-delete-' + spec.rule.id)
    }.width('100%').padding(8).border({ width: 1, color: COLORS.border, radius: UI.controlRadius })
  }

  @Builder
  private WaiverLibrary() {
    Column({ space: 8 }) {
      Text(this.state.waiverLibrary ? `豁免库 · ${this.state.waiverLibrary.rules.length} / ${this.state.waiverLibrary.ruleLimit} 条` : '豁免库未读取').rdbSectionTitle()
      Row({ space: 8 }) {
        Button('导入JSON…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && !!this.state.waiverLibrary).onClick(() => this.fileWaiver('import')).id('rdb-waiver-import')
        Button('导出JSON…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && !!this.state.waiverLibrary).onClick(() => this.fileWaiver('export')).id('rdb-waiver-export')
        Button('刷新工作区', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && !this.draftDirty)
          .onClick(() => this.reloadWorkspaceAction(this.state.workspaceToken)).id('rdb-waiver-reload-workspace')
      }.width('100%')
      if (this.state.waiverLibrary?.rules.length === 0) { Text('暂无豁免规则').rdbCaption() }
      ForEach(this.waiverRuleSpecs(), (spec: RdbWaiverRuleSpec) => {
        this.WaiverRule(spec)
      }, (spec: RdbWaiverRuleSpec): string => `${spec.version}:${spec.rule.id}`)
      Row({ space: 8 }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.waiverRulePage > 0).onClick(() => this.changeWaiverRulePage(this.waiverRulePage - 1))
        Text(`${this.waiverRulePage + 1} / ${this.waiverRulePageCount()}`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.waiverRulePage + 1 < this.waiverRulePageCount()).onClick(() => this.changeWaiverRulePage(this.waiverRulePage + 1))
      }.width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.waiverRulePageText, placeholder: '页码' }).rdbInput().layoutWeight(1).enabled(this.available()).onChange((value: string) => this.waiverRulePageText = value)
        Button('跳转', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available()).onClick(() => this.jumpWaiverRulePage())
        Text(`已选 ${this.waiverRuleIds.length} 条`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WaiverControls() {
    Column({ space: 8 }) {
      Text('批量匹配预览').rdbSectionTitle()
      Select([{ value: '应用所选规则' }, { value: '移除所选规则的库应用' }]).selected(this.waiverOperation)
        .value(this.waiverOperation === 0 ? '应用所选规则' : '移除所选规则的库应用').height(UI.fieldHeight).width('100%').borderRadius(UI.controlRadius)
        .enabled(this.available()).onSelect((index: number) => this.chooseWaiverOperation(index)).id('rdb-waiver-operation')
      Button('生成完整匹配预览', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.waiverReady() && this.waiverRuleIds.length > 0)
        .onClick(() => this.previewWaiver()).id('rdb-waiver-preview')
      if (this.state.waiverLibrary && this.state.waiverLibrary.abandonedApplications > 0) {
        Text(`${this.state.waiverLibrary.abandonedApplications} 个历史应用已放弃移除所有权，报告标记保留`).rdbCaption()
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WaiverPreview(preview: RdbWaiverUiPreview) {
    Column({ space: 8 }) {
      Text(`${preview.summary.changed} 项可更改 · ${preview.summary.alreadyWaived} 项原有豁免 · ${preview.summary.uncertain} 项不确定 · ${preview.summary.conflicts} 项冲突 · ${preview.summary.unmatched} 项不匹配`).rdbSectionTitle()
      Text(this.waiverPreviewCurrent() ? preview.message : '来源、库或选择已改变；请重新预览').rdbCaption()
      Row({ space: 8 }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.waiverPreviewCurrent() && preview.pageIndex > 0).onClick(() => this.changeWaiverPage(preview.id, preview.pageIndex - 1))
        Text(`${preview.pageIndex + 1} / ${preview.pageCount} · 全部 ${preview.totalRows} 项`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.waiverPreviewCurrent() && preview.pageIndex + 1 < preview.pageCount).onClick(() => this.changeWaiverPage(preview.id, preview.pageIndex + 1))
      }.width('100%')
      Row({ space: 8 }) {
        TextInput({ text: this.waiverPageText, placeholder: '预览页码' }).rdbInput().layoutWeight(1).enabled(this.available()).onChange((value: string) => this.waiverPageText = value)
        Button('跳转', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.waiverPreviewCurrent()).onClick(() => this.jumpWaiverPage(preview.id))
      }.width('100%')
      ForEach(preview.rows, (row: RdbWaiverPreviewRow) => {
        Column({ space: 4 }) {
          Text(`标记 ${row.itemIndex + 1} · ${row.status} · ${row.ruleNames.join(' / ') || '无匹配规则'}`).rdbSectionTitle()
          Text(row.reason).rdbCaption()
        }.width('100%').alignItems(HorizontalAlign.Start).padding(8).border({ width: 1, color: COLORS.border, radius: UI.controlRadius })
      }, (row: RdbWaiverPreviewRow) => JSON.stringify([preview.id, preview.libraryVersion, preview.context, preview.pageIndex, row]))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WaiverActions(id: string) {
    Row({ space: 8 }) {
      Button('取消预览', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1).enabled(this.available()).onClick(() => this.cancelWaiver(id)).id('rdb-waiver-cancel')
      Button(this.waiverOperation === 0 ? '确认应用豁免…' : '确认移除库应用…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1)
        .backgroundColor(this.waiverOperation === 0 ? COLORS.primary : COLORS.dangerSoft).fontColor(this.waiverOperation === 0 ? '#FFFFFF' : COLORS.danger)
        .enabled(this.available() && this.waiverPreviewCurrent() && this.state.waiverPreview?.canApply === true)
        .onClick(() => this.applyWaiver(id)).id('rdb-waiver-apply')
    }.width('100%')
  }

  private buildModeSegmentItems(): SegmentButtonItemTuple {
    const items: [
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem,
      SegmentButtonTextItem
    ] = [
      { text: '审阅' },
      { text: `报告 ${this.state.reports.length}` },
      { text: '继承' },
      { text: '合并' },
      { text: '豁免库' }
    ];
    return items;
  }

  @Builder
  private ModeTabs() {
    Column({ space: 6 }) {
      StableSegmentButton({
        items: this.buildModeSegmentItems(),
        selectedIndex: this.mode,
        onItemClicked: (index: number) => {
          if (this.available()) {
            this.mode = index;
          }
        },
        fontColor: COLORS.muted,
        selectedFontColor: COLORS.primary,
        capsuleBackgroundColor: COLORS.surfaceMuted,
        selectedBackgroundColor: COLORS.primarySoft,
        fontSizeFp: this.panelWidth < 520 ? 11 : UI.fontBody,
        capsuleBorderRadius: UI.controlRadius,
        itemPaddingHorizontal: this.panelWidth < 520 ? 4 : 8,
        itemPaddingVertical: 5,
        buttonMinHeight: 36,
        itemMinHeight: 30
      })
    }.width('100%').enabled(this.available()).opacity(this.available() ? 1.0 : 0.5).id('rdb-review-modes')
  }

  @Builder
  private ActiveReportPicker(reports: RdbReviewWorkspaceReport[], workspace: string) {
    Select(reports.map((report: RdbReviewWorkspaceReport): SelectOption => ({ value: this.reportLabel(report) })))
      .selected(reports.findIndex((report: RdbReviewWorkspaceReport): boolean => report.id === this.state.activeReportId))
      .value(this.state.sourceName || '尚未打开报告').width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
      .enabled(this.available() && reports.length > 0).onSelect((index: number) => {
        if (index >= 0 && index < reports.length) this.activateReport(reports[index].id, workspace, reports[index].contextToken);
      }).id('rdb-review-active-report')
  }

  @Builder
  private ReportsToolbar() {
    Column({ space: 8 }) {
      Text(`报告工作区 · ${this.state.reports.length} / ${this.state.reportLimit} 份`).rdbSectionTitle()
      ForEach([JSON.stringify([this.state.workspaceToken, this.state.reports])], (snapshot: string) => {
        this.ActiveReportPicker(this.state.reports, this.state.workspaceToken)
      }, (snapshot: string) => snapshot)
      this.FileToolbar()
      this.StatusContent()
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ReportRow(spec: RdbReportRowSpec) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(`${spec.isActive ? '当前 · ' : ''}${spec.report.name}`).rdbSectionTitle().copyOption(CopyOptions.LocalDevice)
        Text(`${spec.report.id} · ${spec.report.items} 项${spec.report.dirty ? ' · 未导出修改' : ''}`).rdbCaption()
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      if (!spec.isActive) {
        Button('切换', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available())
          .onClick(() => this.activateReport(spec.report.id, spec.workspace, spec.report.contextToken)).id('rdb-review-report-activate-' + spec.report.id)
      }
      Button('关闭', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft).enabled(this.available())
        .onClick(() => this.closeReport(spec.report.id, spec.workspace, spec.report.contextToken)).id('rdb-review-report-close-' + spec.report.id)
    }.width('100%').alignItems(VerticalAlign.Center).padding(10)
      .backgroundColor(spec.isActive ? COLORS.primarySoft : COLORS.surfaceMuted).borderRadius(UI.panelRadius)
  }

  @Builder
  private ReportList() {
    Column({ space: 8 }) {
      if (this.state.reports.length === 0) { Text('暂无报告').rdbCaption() }
      ForEach(this.reportRowSpecs(), (spec: RdbReportRowSpec) => {
        this.ReportRow(spec)
      }, (spec: RdbReportRowSpec): string => `${spec.workspace}:${spec.report.id}:${spec.report.contextToken}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ReportPagination() {
    Column({ space: 6 }) {
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.reportPage > 0).onClick(() => this.changeReportPage(this.reportPage - 1)).id('rdb-review-reports-prev')
        Text(`${this.reportPage + 1}/${this.reportPageCount()} 页 · 共 ${this.state.reports.length} 份`).rdbCaption().width(155).margin({ top: 9, right: 6 })
        Button('下一页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available() && this.reportPage + 1 < this.reportPageCount()).onClick(() => this.changeReportPage(this.reportPage + 1)).id('rdb-review-reports-next')
        Select([{ value: '10 / 页' }, { value: '20 / 页' }]).selected(this.reportPageSize === 10 ? 0 : 1).value(`${this.reportPageSize} / 页`)
          .width(120).height(UI.fieldHeight).borderRadius(UI.controlRadius).enabled(this.available()).onSelect((index: number) => {
            if (index === 0 || index === 1) this.changeReportPage(0, index === 0 ? 10 : 20);
          })
      }.width('100%')
      Row({ space: 6 }) {
        TextInput({ text: this.reportPageText, placeholder: '报告页码' }).rdbInput().layoutWeight(1).enabled(this.available()).onChange((text: string) => this.reportPageText = text)
        Button('转到页', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available()).onClick(() => this.jumpReportPage()).id('rdb-review-reports-jump')
      }.width('100%').padding({ right: 4 })
    }.width('100%').id('rdb-review-reports-pagination')
  }

  @Builder
  private FileToolbar() {
    Flex({ wrap: FlexWrap.Wrap }) {
        Button('新增打开…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.available()).onClick(() => this.transfer('open')).id('rdb-review-open')
        Button('重新载入', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.loaded()).onClick(() => this.transfer('reload')).id('rdb-review-reload')
        Button('另存为…', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 6, bottom: 4 }).enabled(this.loaded()).onClick(() => this.transfer('save')).id('rdb-review-save')
        Button('当前 DRC 新建', { type: ButtonType.Normal }).rdbButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(this.available() && this.canUseCurrentDrc).onClick(() => this.transfer('currentDrc')).id('rdb-review-current-drc')
    }.width('100%')
  }

  @Builder
  private SectionTabs() {
    Row() {
      StableSegmentButton({
        items: [{ text: '筛选' }, { text: '列表' }, { text: '详情' }] as [
          SegmentButtonTextItem,
          SegmentButtonTextItem,
          SegmentButtonTextItem
        ] as SegmentButtonItemTuple,
        selectedIndex: this.pane,
        onItemClicked: (idx: number) => { this.pane = idx; },
        fontColor: COLORS.muted,
        selectedFontColor: COLORS.primary,
        capsuleBackgroundColor: COLORS.surfaceMuted,
        selectedBackgroundColor: COLORS.primarySoft,
        fontSizeFp: UI.fontBody,
        capsuleBorderRadius: UI.controlRadius,
        buttonMinHeight: 34,
        itemMinHeight: 28
      })
    }.width('100%').id('rdb-review-sections')
  }

  @Builder
  private StatusContent() {
    if (this.localError.length > 0 || this.status.length > 0) {
      Text(this.localError || this.status).rdbCaption().fontColor(this.localError.length > 0 ? COLORS.danger : COLORS.primary).copyOption(CopyOptions.LocalDevice).id('rdb-review-status')
    }
  }

  build() {
    Column({ space: 8 }) {
      PanelHeading({ title: 'RDB 报告审阅', subtitle: this.panelHeight < 520 ? '' : (this.state.loaded ? `${this.state.sourceName}${this.state.dirty ? ' · 未保存' : ''}` : ''), canClose: !this.busy, closeAction: () => this.closePanel() })
      this.ModeTabs()
      if (this.mode === 1) {
        Scroll() {
          Column({ space: 12 }) {
            this.ReportsToolbar()
            this.ReportPagination()
            this.ReportList()
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-reports-scroll')
      } else if (this.mode === 2) {
        Scroll() {
          Column({ space: 12 }) {
            this.TransferControls()
            this.TransferSummary()
            this.TransferPagination()
            if (this.panelHeight < 520 && this.state.transferPreview !== null) {
              ForEach([this.state.transferPreview.id], (previewId: string) => {
                this.TransferActions(previewId)
              }, (previewId: string) => previewId)
            }
            this.TransferRows()
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-transfer-scroll')
        if (this.panelHeight >= 520 && this.state.transferPreview !== null) {
          ForEach([this.state.transferPreview.id], (previewId: string) => {
            this.TransferActions(previewId)
          }, (previewId: string) => previewId)
        }
      } else if (this.mode === 3) {
        Scroll() {
          Column({ space: 16 }) {
            this.MergeSources()
            this.MergeSettings()
            if (this.state.mergePreview !== null) {
              ForEach([this.state.mergePreview!], (preview: RdbMergeUiPreview) => {
                this.MergeSummary(preview)
                this.MergePagination(preview)
                if (this.panelHeight < 520) { this.MergeActions(preview.id) }
                this.MergeRows(preview)
              }, (preview: RdbMergeUiPreview) => JSON.stringify(preview))
            }
          }.width('100%').padding({ right: 4 }).alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-merge-scroll')
        if (this.panelHeight >= 520 && this.state.mergePreview !== null) {
          ForEach([this.state.mergePreview.id], (previewId: string) => {
            this.MergeActions(previewId)
          }, (previewId: string) => previewId)
        }
      } else if (this.mode === 4) {
        Scroll() {
          Column({ space: 16 }) {
            if ((this.localError || this.status).length > 0) {
              Text(this.localError || this.status).rdbCaption()
            }
            this.WaiverCapture()
            this.WaiverLibrary()
            this.WaiverControls()
            if (this.state.waiverPreview) {
              ForEach([this.state.waiverPreview!], (preview: RdbWaiverUiPreview) => {
                this.WaiverPreview(preview)
                if (this.panelHeight < 520) { this.WaiverActions(preview.id) }
              }, (preview: RdbWaiverUiPreview) => JSON.stringify([this.waiverContextKey(), preview]))
            }
          }.width('100%').padding({ right: 4 }).alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-waiver-scroll')
        if (this.panelHeight >= 520 && this.state.waiverPreview) {
          ForEach([this.state.waiverPreview!], (preview: RdbWaiverUiPreview) => {
            this.WaiverActions(preview.id)
          }, (preview: RdbWaiverUiPreview) => JSON.stringify([this.waiverContextKey(), preview.id, preview.libraryVersion, preview.context]))
        }
      } else if (this.panelHeight < 520) {
        Scroll() {
          Column({ space: 8 }) {
            this.SectionTabs()
            this.FileToolbar()
            this.StatusContent()
            if (this.state.loaded) {
              Text(`${this.state.sourceName}${this.state.dirty ? ' · 未保存' : ''}`).rdbCaption()
            }
            this.Pagination()
            if (this.pane === 0) { this.FilterContent() } else if (this.pane === 1) { this.MarkerContent() } else { this.DetailContent() }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-content')
      } else {
        this.FileToolbar()
        if (this.panelWidth < 1000) {
          this.SectionTabs()
          Scroll() {
            Column({ space: 8 }) {
              this.StatusContent()
              if (this.pane === 0) { this.FilterContent() } else if (this.pane === 1) { this.MarkerContent() } else { this.DetailContent() }
            }.width('100%').alignItems(HorizontalAlign.Start)
          }
          .layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-content')
        } else {
          Row({ space: 8 }) {
            Scroll() { this.FilterContent() }.layoutWeight(24).height('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-filter-scroll')
            Scroll() { this.MarkerContent() }.layoutWeight(32).height('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-list-scroll')
            Scroll() { Column({ space: 8 }) { this.StatusContent(); this.DetailContent() }.width('100%').alignItems(HorizontalAlign.Start) }.layoutWeight(44).height('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('rdb-review-detail-scroll')
          }.layoutWeight(1).width('100%').alignItems(VerticalAlign.Top)
        }
        this.Pagination()
      }
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).id('rdb-review-panel')
  }
}

@Extend(Button)
function rdbButton() { .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).padding({ left: 10, right: 10 }).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight) }
@Extend(TextInput)
function rdbInput() { .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius) }
@Extend(Text)
function rdbText() { .fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%') }
@Extend(Text)
function rdbCaption() { .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%') }
@Extend(Text)
function rdbSectionTitle() { .fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%') }
