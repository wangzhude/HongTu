import { hongTuThemeState } from '../../store/ThemeStore';
import { SegmentButtonItemTuple, SegmentButtonTextItem } from '@kit.ArkUI';
import { StableSegmentButton } from '../StableSegmentButton';
import { COLORS, formatZoomPercent } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { ViewAffine, ViewBookmark, ViewLayerVisibility, ViewOverlayState, ViewPresentation, ViewRecord } from '../../models/ViewWorkspace';
import { ViewOverlayCellChoice, ViewOverlayDiagnostic, ViewOverlayDocumentChoice, ViewOverlayEditDraft } from '../../models/ViewOverlayUi';
import { isFiniteViewAffine } from '../../services/ViewAffineValidationService';
import { PanelHeading } from './PanelHeading';

interface OverlayLayerRowSpec {
  overlayId: string;
  layerNumber: number;
  datatype: number;
  visible: boolean;
  viewId: string;
  context: string;
}

interface OverlayRowSpec {
  overlay: ViewOverlayState;
  index: number;
  viewId: string;
  context: string;
}

/** Views share the document database; this panel edits only presentation records. */
@Component
export struct ViewWorkspacePanel {
  @Prop @Watch('resetDocumentState') documentId: string = '';
  @Prop documentTitle: string = '';
  @Prop activeViewId: string = '';
  @Prop cellKeyNames: Record<string, string> = {};
  @Prop views: ViewRecord[] = [];
  @Prop bookmarks: ViewBookmark[] = [];
  @Prop status: string = '';
  @Prop ready: boolean = false;
  @Prop busy: boolean = false;
  @Prop panelWidth: number = 620;
  @Prop panelHeight: number = 700;
  @Prop overlayDocuments: ViewOverlayDocumentChoice[] = [];
  @Prop overlayDiagnostics: ViewOverlayDiagnostic[] = [];
  @Prop @Watch('synchronizeOverlayOwner') overlayContext: string = '';
  action: (kind: string, id: string, name: string) => boolean = () => false;
  overlayAction: (viewId: string, expectedContext: string, overlays: ViewOverlayState[]) => boolean = () => false;
  fileAction: (importing: boolean, replace: boolean) => void = () => {};
  closeAction: () => void = () => {};
  @State selectedIndexes: number[] = [0];
  @State viewName: string = '';
  @State bookmarkName: string = '';
  @State renameKind: string = '';
  @State renameId: string = '';
  @State renameName: string = '';
  @State localError: string = '';
  @State overlaySourceId: string = '';
  @State overlayCellKey: string = '';
  @State overlaySourceRevision: number = -1;
  @State overlaySelectionContext: string = '';
  @State overlaySelectionViewId: string = '';
  @State overlayDrafts: ViewOverlayEditDraft[] = [];
  @State expandedOverlayId: string = '';
  @State overlayLayerPage: number = 0;
  @State overlayControlEpoch: number = 0;
  private active: boolean = true;
  private generation: number = 0;
  private overlaySerial: number = 0;
  private overlayOwnerDocumentId: string = '';

  aboutToAppear(): void {
    this.active = true;
    this.synchronizeOverlayOwner();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.generation++;
  }

  private resetDocumentState(): void {
    this.generation++;
    this.viewName = ''; this.bookmarkName = ''; this.clearRename();
    this.localError = ''; this.selectedIndexes = [0];
    this.overlaySourceId = ''; this.overlayCellKey = ''; this.overlaySourceRevision = -1;
    this.overlaySelectionContext = ''; this.overlaySelectionViewId = '';
    this.overlayDrafts = []; this.expandedOverlayId = ''; this.overlayLayerPage = 0;
    this.overlayOwnerDocumentId = '';
  }

  private clearRename(): void { this.renameKind = ''; this.renameId = ''; this.renameName = ''; }
  private available(): boolean { return this.active && this.ready && !this.busy && this.documentId.length > 0; }
  private isBookmarkTab(): boolean { return this.selectedIndexes.length > 0 && this.selectedIndexes[0] === 1; }
  private isOverlayTab(): boolean { return this.selectedIndexes.length > 0 && this.selectedIndexes[0] === 2; }
  private hasView(id: string): boolean { return this.views.some((view: ViewRecord): boolean => view.id === id); }
  private hasBookmark(id: string): boolean { return this.bookmarks.some((bookmark: ViewBookmark): boolean => bookmark.id === id); }

  private invoke(kind: string, id: string, name: string = ''): boolean {
    if (!this.available()) return false;
    const bookmarkAction: boolean = ['locateBookmark', 'renameBookmark', 'updateBookmark', 'deleteBookmark'].includes(kind);
    if (bookmarkAction ? !this.hasBookmark(id) : !this.hasView(id)) {
      this.localError = '此记录已变化，请使用当前列表重试'; return false;
    }
    if (kind === 'closeView' && this.views.length <= 1) { this.localError = '每个文档至少保留一个视图'; return false; }
    const documentId: string = this.documentId;
    this.localError = '';
    try { return this.action(kind, id, name) && this.documentId === documentId && this.active; }
    catch (error) { if (this.documentId === documentId && this.active) this.localError = error instanceof Error ? error.message : String(error); return false; }
  }

  private createRecord(): void {
    const bookmark: boolean = this.isBookmarkTab();
    const name: string = bookmark ? this.bookmarkName : this.viewName;
    if (name.trim().length === 0) { this.localError = '请输入名称'; return; }
    const documentId: string = this.documentId;
    if (this.invoke(bookmark ? 'saveBookmark' : 'clone', this.activeViewId, name) && this.documentId === documentId) {
      if (bookmark && this.bookmarkName === name) this.bookmarkName = '';
      if (!bookmark && this.viewName === name) this.viewName = '';
    }
  }

  private beginRename(kind: string, id: string, name: string): void {
    if (!this.available()) return;
    this.renameKind = kind; this.renameId = id; this.renameName = name; this.localError = '';
  }

  private saveRename(): void {
    const documentId: string = this.documentId;
    const kind: string = this.renameKind;
    const id: string = this.renameId;
    const name: string = this.renameName;
    if (name.trim().length === 0) { this.localError = '请输入名称'; return; }
    if (this.invoke(kind, id, name) && this.documentId === documentId && this.renameKind === kind &&
      this.renameId === id && this.renameName === name) this.clearRename();
  }

  private confirmBookmarkChange(kind: string, bookmark: ViewBookmark): void {
    if (!this.available() || !this.hasBookmark(bookmark.id)) return;
    const documentId: string = this.documentId;
    const id: string = bookmark.id;
    const name: string = bookmark.name;
    const snapshot: string = JSON.stringify(bookmark);
    const viewId: string = this.activeViewId;
    const generation: number = this.generation;
    this.getUIContext().showAlertDialog({
      title: kind === 'deleteBookmark' ? '删除书签' : '覆盖书签位置',
      message: kind === 'deleteBookmark' ? `删除“${name}”？版图内容不会改变。` : `用当前视图的位置与图层显示覆盖“${name}”？`,
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: kind === 'deleteBookmark' ? '删除' : '覆盖', action: () => {
        if (this.documentId !== documentId || generation !== this.generation || !this.available()) return;
        const current: ViewBookmark | undefined = this.bookmarks.find((item: ViewBookmark): boolean => item.id === id);
        if (!current || JSON.stringify(current) !== snapshot || (kind === 'updateBookmark' && this.activeViewId !== viewId)) {
          this.localError = '书签或当前视图已变化，请重新确认'; return;
        }
        if (this.invoke(kind, id) && this.renameId === id) this.clearRename();
      } }
    });
  }

  private transfer(importing: boolean, replace: boolean): void {
    if (!this.available()) return;
    this.localError = '';
    try { this.fileAction(importing, replace); }
    catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }

  private cellKey(presentation: ViewPresentation): string {
    const keys: string[] = presentation.location.cellStackKeys;
    if (keys.length === 0) return '未定位';
    const rawKey: string = keys[keys.length - 1];
    const resolved: string | undefined = this.cellKeyNames[rawKey];
    if (resolved !== undefined && resolved.length > 0) return resolved;
    return rawKey.length > 18 ? `${rawKey.slice(0, 14)}…` : rawKey;
  }

  private activeOverlayView(): ViewRecord | undefined {
    return this.views.find((view: ViewRecord): boolean => view.id === this.activeViewId);
  }
  private currentOverlays(): ViewOverlayState[] { return this.activeOverlayView()?.overlays ?? []; }
  private findCurrentOverlay(id: string): ViewOverlayState | undefined {
    return this.currentOverlays().find((item: ViewOverlayState): boolean => item.id === id);
  }
  private isOverlayVisible(id: string): boolean {
    return this.findCurrentOverlay(id)?.visible ?? false;
  }
  private isOverlayLayerVisible(overlayId: string, layerNumber: number, datatype: number): boolean {
    const overlay: ViewOverlayState | undefined = this.findCurrentOverlay(overlayId);
    if (!overlay) return false;
    const found: ViewLayerVisibility | undefined = this.overlayLayers(overlay)
      .find((item: ViewLayerVisibility): boolean => item.layerNumber === layerNumber && item.datatype === datatype);
    return found?.visible ?? true;
  }
  private overlayChoices(): ViewOverlayDocumentChoice[] {
    return this.overlayDocuments.filter((document: ViewOverlayDocumentChoice): boolean => document.documentId !== this.documentId);
  }
  private overlaySource(id: string): ViewOverlayDocumentChoice | undefined {
    return this.overlayChoices().find((document: ViewOverlayDocumentChoice): boolean => document.documentId === id);
  }
  private overlaySourceLabel(id: string): string { return this.overlaySource(id)?.title ?? id; }
  private overlayCellLabel(overlay: ViewOverlayState): string {
    return this.overlaySource(overlay.sourceDocumentId)?.cells.find((cell: ViewOverlayCellChoice): boolean => cell.key === overlay.cellKey)?.name ?? overlay.cellKey;
  }
  private overlayProblem(overlay: ViewOverlayState): string {
    const diagnostic: ViewOverlayDiagnostic | undefined = this.overlayDiagnostics.find((item: ViewOverlayDiagnostic): boolean => item.overlayId === overlay.id);
    if (diagnostic) return diagnostic.message;
    const source: ViewOverlayDocumentChoice | undefined = this.overlaySource(overlay.sourceDocumentId);
    if (!source) return '来源文档已关闭或不可用，画布已撤下此来源';
    if (!source.cells.some((cell: ViewOverlayCellChoice): boolean => cell.key === overlay.cellKey)) return '稳定 Cell 已失效，画布已撤下此来源';
    return '';
  }
  private overlayCurrent(viewId: string, context: string): boolean {
    return this.available() && this.overlayOwnerDocumentId === this.documentId && context.length > 0 &&
      this.overlayContext === context && this.activeViewId === viewId && this.hasView(viewId);
  }
  private overlayContentKey(context: string): string {
    return JSON.stringify([this.documentId, this.activeViewId, context,
      this.overlayControlEpoch, this.overlayDocuments]);
  }
  private synchronizeOverlayOwner(): void { this.overlayOwnerDocumentId = this.documentId; }
  private requireOverlayCurrent(viewId: string, context: string): boolean {
    if (this.overlayCurrent(viewId, context)) return true;
    this.localError = '文档、视图或来源版本已变化，请使用当前列表重试'; return false;
  }
  private chooseOverlayDocument(id: string, revision: number, viewId: string, context: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const source: ViewOverlayDocumentChoice | undefined = this.overlaySource(id);
    if (!source || source.revision !== revision) { this.localError = '来源版本已变化，请重新选择'; return; }
    this.overlaySourceId = id; this.overlaySourceRevision = revision;
    this.overlaySelectionContext = context; this.overlaySelectionViewId = viewId;
    this.overlayCellKey = ''; this.localError = '';
  }
  private chooseOverlayCell(id: string, revision: number, key: string, viewId: string, context: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const source: ViewOverlayDocumentChoice | undefined = this.overlaySource(id);
    if (this.overlaySourceId !== id || !source || source.revision !== revision ||
      this.overlaySourceRevision !== revision || !source.cells.some((cell: ViewOverlayCellChoice): boolean => cell.key === key)) {
      this.localError = '来源或 Cell 已变化，请重新选择来源'; return;
    }
    this.overlayCellKey = key; this.overlaySelectionContext = context; this.overlaySelectionViewId = viewId; this.localError = '';
  }
  private canAddOverlay(): boolean {
    const source: ViewOverlayDocumentChoice | undefined = this.overlaySource(this.overlaySourceId);
    return this.overlayCurrent(this.overlaySelectionViewId, this.overlaySelectionContext) && this.currentOverlays().length < 64 &&
      source !== undefined && source.revision === this.overlaySourceRevision && source.cells.some((cell: ViewOverlayCellChoice): boolean => cell.key === this.overlayCellKey);
  }
  private copyOverlay(overlay: ViewOverlayState): ViewOverlayState {
    return { id: overlay.id, sourceDocumentId: overlay.sourceDocumentId, cellKey: overlay.cellKey, visible: overlay.visible,
      opacity: overlay.opacity, transform: { a: overlay.transform.a, b: overlay.transform.b, c: overlay.transform.c,
        d: overlay.transform.d, tx: overlay.transform.tx, ty: overlay.transform.ty },
      layerVisibilities: overlay.layerVisibilities.map((layer: ViewLayerVisibility): ViewLayerVisibility =>
        ({ layerNumber: layer.layerNumber, datatype: layer.datatype, visible: layer.visible })) };
  }
  private publishOverlays(viewId: string, context: string, overlays: ViewOverlayState[]): boolean {
    if (!this.requireOverlayCurrent(viewId, context)) return false;
    const documentId: string = this.documentId, generation: number = this.generation;
    this.localError = '';
    try {
      const accepted: boolean = this.overlayAction(viewId, context, overlays.map((overlay: ViewOverlayState): ViewOverlayState => this.copyOverlay(overlay)));
      if (this.documentId !== documentId || this.activeViewId !== viewId || this.generation !== generation || !this.active) return false;
      if (!accepted) { this.localError = '叠加设置未保存，输入已保留；请查看保存状态后重试'; this.overlayControlEpoch++; }
      return accepted;
    } catch (error) {
      if (this.documentId === documentId && this.active && this.generation === generation) {
        this.localError = error instanceof Error ? error.message : String(error); this.overlayControlEpoch++;
      }
      return false;
    }
  }
  private addOverlay(viewId: string, context: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    if (!this.canAddOverlay()) { this.localError = '请选择当前来源文档和稳定 Cell；最多保留64项来源'; return; }
    const source: ViewOverlayDocumentChoice = this.overlaySource(this.overlaySourceId)!;
    const overlays: ViewOverlayState[] = this.currentOverlays().map((item: ViewOverlayState): ViewOverlayState => this.copyOverlay(item));
    let id: string = '';
    do { id = `overlay-${Date.now().toString(36)}-${++this.overlaySerial}`; }
    while (this.views.some((view: ViewRecord): boolean => view.overlays.some((item: ViewOverlayState): boolean => item.id === id)));
    overlays.push({ id, sourceDocumentId: source.documentId, cellKey: this.overlayCellKey, visible: true, opacity: 1,
      transform: { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 },
      layerVisibilities: source.layers.map((layer: ViewLayerVisibility): ViewLayerVisibility =>
        ({ layerNumber: layer.layerNumber, datatype: layer.datatype, visible: layer.visible })) });
    if (this.publishOverlays(viewId, context, overlays)) { this.expandedOverlayId = id; this.overlayLayerPage = 0; }
  }
  private changeOverlay(viewId: string, context: string, id: string, kind: string, visible: boolean = false): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const overlays: ViewOverlayState[] = this.currentOverlays().map((item: ViewOverlayState): ViewOverlayState => this.copyOverlay(item));
    const index: number = overlays.findIndex((item: ViewOverlayState): boolean => item.id === id);
    if (index < 0) { this.localError = '此叠加来源已移除'; return; }
    if (kind === 'visible') {
      if (overlays[index].visible === visible) return;
      overlays[index].visible = visible;
    } else if (kind === 'remove') overlays.splice(index, 1);
    else if (kind === 'up' || kind === 'down') {
      const target: number = index + (kind === 'up' ? -1 : 1);
      if (target < 0 || target >= overlays.length) return;
      const moved: ViewOverlayState = overlays[index]; overlays[index] = overlays[target]; overlays[target] = moved;
    } else return;
    if (this.publishOverlays(viewId, context, overlays) && kind === 'remove') {
      this.overlayDrafts = this.overlayDrafts.filter((draft: ViewOverlayEditDraft): boolean => draft.overlayId !== id);
      if (this.expandedOverlayId === id) this.expandedOverlayId = '';
    }
  }
  private overlayDraft(id: string): ViewOverlayEditDraft | undefined {
    return this.overlayDrafts.find((draft: ViewOverlayEditDraft): boolean => draft.documentId === this.documentId && draft.viewId === this.activeViewId && draft.overlayId === id);
  }
  private seedOverlayDraft(viewId: string, context: string, overlay: ViewOverlayState): ViewOverlayEditDraft {
    return { documentId: this.documentId, viewId, overlayId: overlay.id, context,
      opacity: String(overlay.opacity * 100), a: String(overlay.transform.a), b: String(overlay.transform.b),
      c: String(overlay.transform.c), d: String(overlay.transform.d), tx: String(overlay.transform.tx), ty: String(overlay.transform.ty) };
  }
  private putOverlayDraft(draft: ViewOverlayEditDraft): void {
    this.overlayDrafts = this.overlayDrafts.filter((item: ViewOverlayEditDraft): boolean =>
      item.documentId !== draft.documentId || item.viewId !== draft.viewId || item.overlayId !== draft.overlayId).concat([draft]);
  }
  private draftField(draft: ViewOverlayEditDraft, field: string): string {
    if (field === 'opacity') return draft.opacity;
    if (field === 'a') return draft.a; if (field === 'b') return draft.b; if (field === 'c') return draft.c;
    if (field === 'd') return draft.d; if (field === 'tx') return draft.tx; return draft.ty;
  }
  private overlayNumberText(overlay: ViewOverlayState, field: string): string {
    return this.draftField(this.overlayDraft(overlay.id) ?? this.seedOverlayDraft(this.activeViewId, this.overlayContext, overlay), field);
  }
  private editOverlayNumber(viewId: string, context: string, id: string, field: string, value: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const overlay: ViewOverlayState | undefined = this.currentOverlays().find((item: ViewOverlayState): boolean => item.id === id);
    if (!overlay) { this.localError = '此叠加来源已移除'; return; }
    const existing: ViewOverlayEditDraft | undefined = this.overlayDraft(id);
    if (existing && this.draftField(existing, field) === value) return;
    if (!existing && this.draftField(this.seedOverlayDraft(viewId, context, overlay), field) === value) return;
    if (existing && existing.context !== context) { this.localError = '数值草稿所属来源版本已变化；请重新读取设置后编辑'; return; }
    const draft: ViewOverlayEditDraft = existing ? { documentId: existing.documentId, viewId: existing.viewId, overlayId: existing.overlayId,
      context: existing.context, opacity: existing.opacity, a: existing.a, b: existing.b, c: existing.c, d: existing.d, tx: existing.tx, ty: existing.ty } : this.seedOverlayDraft(viewId, context, overlay);
    if (field === 'opacity') draft.opacity = value; else if (field === 'a') draft.a = value; else if (field === 'b') draft.b = value;
    else if (field === 'c') draft.c = value; else if (field === 'd') draft.d = value; else if (field === 'tx') draft.tx = value;
    else if (field === 'ty') draft.ty = value; else return;
    this.putOverlayDraft(draft); this.localError = '';
  }
  private rereadOverlayDraft(viewId: string, context: string, id: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const overlay: ViewOverlayState | undefined = this.currentOverlays().find((item: ViewOverlayState): boolean => item.id === id);
    if (!overlay) return;
    this.putOverlayDraft(this.seedOverlayDraft(viewId, context, overlay)); this.localError = '';
  }
  private resetOverlayTransform(viewId: string, context: string, id: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const existing: ViewOverlayEditDraft | undefined = this.overlayDraft(id);
    if (existing && existing.context !== context) { this.localError = '草稿版本已变化，请先重新读取设置'; return; }
    this.editOverlayNumber(viewId, context, id, 'a', '1'); this.editOverlayNumber(viewId, context, id, 'b', '0');
    this.editOverlayNumber(viewId, context, id, 'c', '0'); this.editOverlayNumber(viewId, context, id, 'd', '1');
    this.editOverlayNumber(viewId, context, id, 'tx', '0'); this.editOverlayNumber(viewId, context, id, 'ty', '0');
  }
  private finiteOverlayNumber(value: string, label: string): number {
    if (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim())) throw new Error(`${label}请输入有限十进制数`);
    const number: number = Number(value.trim());
    if (!Number.isFinite(number)) throw new Error(`${label}须为有限数`); return number;
  }
  private applyOverlayNumbers(viewId: string, context: string, id: string): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    const draft: ViewOverlayEditDraft | undefined = this.overlayDraft(id);
    if (!draft) return;
    if (draft.context !== context) { this.localError = '数值草稿所属来源版本已变化；请重新读取设置后提交'; return; }
    const overlays: ViewOverlayState[] = this.currentOverlays().map((item: ViewOverlayState): ViewOverlayState => this.copyOverlay(item));
    const overlay: ViewOverlayState | undefined = overlays.find((item: ViewOverlayState): boolean => item.id === id);
    if (!overlay) { this.localError = '此叠加来源已移除'; return; }
    try {
      const opacity: number = this.finiteOverlayNumber(draft.opacity, '不透明度');
      if (opacity < 0 || opacity > 100) throw new Error('不透明度须在0–100%之间');
      const transform: ViewAffine = { a: this.finiteOverlayNumber(draft.a, 'a'), b: this.finiteOverlayNumber(draft.b, 'b'),
        c: this.finiteOverlayNumber(draft.c, 'c'), d: this.finiteOverlayNumber(draft.d, 'd'),
        tx: this.finiteOverlayNumber(draft.tx, 'tx'), ty: this.finiteOverlayNumber(draft.ty, 'ty') };
      if (!isFiniteViewAffine(transform)) throw new Error('仿射矩阵须为有限可逆矩阵，且完整逆矩阵系数须为有限数');
      overlay.opacity = opacity / 100; overlay.transform = transform;
      if (this.publishOverlays(viewId, context, overlays) && this.overlayDraft(id) === draft) {
        this.overlayDrafts = this.overlayDrafts.filter((item: ViewOverlayEditDraft): boolean => item !== draft);
      }
    } catch (error) { this.localError = error instanceof Error ? error.message : String(error); }
  }
  private overlayLayers(overlay: ViewOverlayState): ViewLayerVisibility[] {
    const source: ViewOverlayDocumentChoice | undefined = this.overlaySource(overlay.sourceDocumentId);
    const layers: ViewLayerVisibility[] = (source?.layers ?? []).map((layer: ViewLayerVisibility): ViewLayerVisibility => {
      const override: ViewLayerVisibility | undefined = overlay.layerVisibilities.find((item: ViewLayerVisibility): boolean => item.layerNumber === layer.layerNumber && item.datatype === layer.datatype);
      return { layerNumber: layer.layerNumber, datatype: layer.datatype, visible: override?.visible ?? true };
    });
    for (const layer of overlay.layerVisibilities) {
      if (!layers.some((item: ViewLayerVisibility): boolean => item.layerNumber === layer.layerNumber && item.datatype === layer.datatype))
        layers.push({ layerNumber: layer.layerNumber, datatype: layer.datatype, visible: layer.visible });
    }
    return layers;
  }
  private setOverlayLayer(viewId: string, context: string, id: string, layerNumber: number, datatype: number, visible: boolean): void {
    if (!this.requireOverlayCurrent(viewId, context)) return;
    if (this.isOverlayLayerVisible(id, layerNumber, datatype) === visible) return;
    const overlays: ViewOverlayState[] = this.currentOverlays().map((item: ViewOverlayState): ViewOverlayState => this.copyOverlay(item));
    const overlay: ViewOverlayState | undefined = overlays.find((item: ViewOverlayState): boolean => item.id === id);
    if (!overlay || !this.overlayLayers(overlay).some((layer: ViewLayerVisibility): boolean => layer.layerNumber === layerNumber && layer.datatype === datatype)) {
      this.localError = '此来源图层已变化'; return;
    }
    const layer: ViewLayerVisibility | undefined = overlay.layerVisibilities.find((item: ViewLayerVisibility): boolean => item.layerNumber === layerNumber && item.datatype === datatype);
    if (layer) layer.visible = visible; else overlay.layerVisibilities.push({ layerNumber, datatype, visible });
    this.publishOverlays(viewId, context, overlays);
  }
  private expandOverlay(viewId: string, context: string, id: string): void {
    if (!this.requireOverlayCurrent(viewId, context) || !this.currentOverlays().some((item: ViewOverlayState): boolean => item.id === id)) return;
    this.expandedOverlayId = this.expandedOverlayId === id ? '' : id; this.overlayLayerPage = 0;
  }
  private overlayLayerPageCount(overlay: ViewOverlayState): number { return Math.max(1, Math.ceil(this.overlayLayers(overlay).length / 20)); }
  private overlayPageLayers(overlay: ViewOverlayState): ViewLayerVisibility[] {
    const page: number = Math.min(this.overlayLayerPage, this.overlayLayerPageCount(overlay) - 1);
    return this.overlayLayers(overlay).slice(page * 20, (page + 1) * 20);
  }
  private changeOverlayLayerPage(viewId: string, context: string, id: string, page: number): void {
    if (!this.requireOverlayCurrent(viewId, context) || this.expandedOverlayId !== id) return;
    const overlay: ViewOverlayState | undefined = this.currentOverlays().find((item: ViewOverlayState): boolean => item.id === id);
    if (overlay && page >= 0 && page < this.overlayLayerPageCount(overlay)) this.overlayLayerPage = page;
  }

  @Builder
  private PresentationDetail(presentation: ViewPresentation) {
    Text(`Cell：${this.cellKey(presentation)} · 缩放 ${formatZoomPercent(presentation.camera.zoomPercent)}`)
      .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
    Text(`中心 (${Number(presentation.camera.centerXNm.toFixed(1))}, ${Number(presentation.camera.centerYNm.toFixed(1))}) nm · 显示图层 ${presentation.layerVisibilities.filter((layer: ViewLayerVisibility): boolean => layer.visible).length}/${presentation.layerVisibilities.length}`)
      .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
  }

  @Builder
  private RenameEditor() {
    TextInput({ text: this.renameName, placeholder: '输入新名称' }).viewWorkspaceInput().maxLength(512)
      .enabled(this.available()).onChange((value: string) => this.renameName = value).id('view-workspace-rename-input')
    Row({ space: 8 }) {
      Button('取消重命名', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).enabled(!this.busy).onClick(() => this.clearRename())
      Button('确认重命名', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontColor(COLORS.primary)
        .enabled(this.available() && this.renameName.trim().length > 0).onClick(() => this.saveRename())
    }.width('100%')
  }

  @Builder
  private ViewRow(view: ViewRecord) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(view.name).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).layoutWeight(1)
        if (view.id === this.activeViewId) {
          Text('当前').fontSize(UI.fontCaption).fontColor(COLORS.primary).padding(4).backgroundColor(COLORS.primarySoft).borderRadius(UI.chipRadius)
        }
      }.width('100%')
      this.PresentationDetail(view.presentation)
      if (this.renameKind === 'renameView' && this.renameId === view.id) { this.RenameEditor() }
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('切换', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .fontColor(view.id === this.activeViewId ? COLORS.muted : COLORS.primary)
          .opacity(view.id === this.activeViewId ? 0.5 : 1)
          .enabled(this.available() && view.id !== this.activeViewId).onClick(() => { this.invoke('activate', view.id); })
        Button('重命名', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.available()).onClick(() => this.beginRename('renameView', view.id, view.name))
        Button('关闭视图', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 })
          .enabled(this.available() && this.views.length > 1).onClick(() => { if (this.invoke('closeView', view.id) && this.renameId === view.id) this.clearRename(); })
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(view.id === this.activeViewId ? COLORS.primarySoft : COLORS.surface)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.panelRadius).id(`view-workspace-view-${view.id}`)
  }

  @Builder
  private BookmarkRow(bookmark: ViewBookmark) {
    Column({ space: 8 }) {
      Text(bookmark.name).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      this.PresentationDetail(bookmark.presentation)
      if (this.renameKind === 'renameBookmark' && this.renameId === bookmark.id) { this.RenameEditor() }
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('定位', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 }).fontColor(COLORS.primary)
          .enabled(this.available()).onClick(() => { this.invoke('locateBookmark', bookmark.id); })
        Button('重命名', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.available()).onClick(() => this.beginRename('renameBookmark', bookmark.id, bookmark.name))
        Button('用当前视图覆盖', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.available() && this.hasView(this.activeViewId)).onClick(() => this.confirmBookmarkChange('updateBookmark', bookmark))
        Button('删除', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 }).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
          .enabled(this.available()).onClick(() => this.confirmBookmarkChange('deleteBookmark', bookmark))
      }.width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(COLORS.surface)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.panelRadius).id(`view-workspace-bookmark-${bookmark.id}`)
  }

  @Builder
  private OverlayPicker(documents: ViewOverlayDocumentChoice[], viewId: string, context: string) {
    Column({ space: 8 }) {
      Text('来源文档').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Select(documents.map((document: ViewOverlayDocumentChoice): SelectOption => ({ value: `${document.title} · ${document.documentId}` })))
        .selected(documents.findIndex((document: ViewOverlayDocumentChoice): boolean => document.documentId === this.overlaySourceId))
        .value(this.overlaySourceId.length > 0 ? this.overlaySourceLabel(this.overlaySourceId) : '选择已打开的其他文档')
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.overlayCurrent(viewId, context) && documents.length > 0)
        .onSelect((index: number) => {
          if (index >= 0 && index < documents.length) this.chooseOverlayDocument(documents[index].documentId, documents[index].revision, viewId, context);
        }).id('view-overlay-source-select').accessibilityText('只读叠加来源文档')
      Text('稳定 Cell').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      ForEach([this.overlaySourceId], (sourceId: string) => {
        this.OverlayCellPicker(this.overlaySource(sourceId)?.cells ?? [], sourceId, this.overlaySourceRevision, viewId, context)
      }, (sourceId: string) => `${viewId}:${context}:${sourceId}:${this.overlaySourceRevision}`)
      Button('添加来源', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width('100%')
        .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
        .enabled(this.canAddOverlay()).onClick(() => this.addOverlay(viewId, context)).id('view-overlay-add')
      if (this.currentOverlays().length >= 64) {
        Text('已达 64 项上限').fontSize(UI.fontCaption).fontColor(COLORS.warning).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private OverlayCellPicker(cells: ViewOverlayCellChoice[], sourceId: string, revision: number, viewId: string, context: string) {
    Select(cells.map((cell: ViewOverlayCellChoice): SelectOption => ({ value: `${cell.name} · ${cell.key}` })))
      .selected(cells.findIndex((cell: ViewOverlayCellChoice): boolean => cell.key === this.overlayCellKey))
      .value(cells.find((cell: ViewOverlayCellChoice): boolean => cell.key === this.overlayCellKey)?.name ?? '选择稳定 Cell')
      .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
      .enabled(this.overlayCurrent(viewId, context) && cells.length > 0 && this.overlaySelectionContext === context)
      .onSelect((index: number) => {
        if (index >= 0 && index < cells.length) this.chooseOverlayCell(sourceId, revision, cells[index].key, viewId, context);
      }).id('view-overlay-cell-select').accessibilityText('只读叠加稳定 Cell')
  }

  @Builder
  private OverlayNumberField(overlay: ViewOverlayState, field: string, label: string, viewId: string, context: string) {
    Column({ space: 4 }) {
      Text(label).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      TextInput({ text: this.overlayNumberText(overlay, field), placeholder: label }).viewWorkspaceInput().maxLength(96)
        .width('100%').enabled(this.overlayCurrent(viewId, context))
        .onChange((value: string) => this.editOverlayNumber(viewId, context, overlay.id, field, value))
        .id(`view-overlay-${overlay.id}-${field}`).accessibilityText(`叠加来源${this.overlaySourceLabel(overlay.sourceDocumentId)} ${label}`)
    }.width(this.panelWidth < 420 ? '100%' : '31%').alignItems(HorizontalAlign.Start).margin({ right: 8, bottom: 8 })
  }

  @Builder
  private OverlayLayerRow(spec: OverlayLayerRowSpec) {
    Row({ space: 8 }) {
      Text(`${spec.layerNumber}/${spec.datatype}`).fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
      Text(spec.visible ? '显示' : '隐藏').fontSize(UI.fontCaption).fontColor(COLORS.muted)
      Toggle({ type: ToggleType.Switch, isOn: spec.visible }).selectedColor(COLORS.primary)
        .enabled(this.overlayCurrent(spec.viewId, spec.context))
        .onChange((visible: boolean) => {
          if (visible === this.isOverlayLayerVisible(spec.overlayId, spec.layerNumber, spec.datatype)) {
            return;
          }
          this.setOverlayLayer(spec.viewId, spec.context, spec.overlayId, spec.layerNumber, spec.datatype, visible);
        })
        .id(`view-overlay-${spec.overlayId}-layer-${spec.layerNumber}-${spec.datatype}`)
        .accessibilityText(`叠加图层 ${spec.layerNumber}/${spec.datatype} 显示`)
    }.width('100%').height(UI.rowHeight).padding({ left: 8, right: 8 })
      .border({ width: { bottom: 1 }, color: COLORS.border })
  }

  @Builder
  private OverlayLayers(overlay: ViewOverlayState, viewId: string, context: string) {
    Column({ space: 8 }) {
      Text(`来源图层 · ${this.overlayLayers(overlay).length} 项`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      if (this.overlayLayers(overlay).length === 0) {
        Text('暂无可用图层').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      }
      ForEach(this.overlayPageLayers(overlay), (layer: ViewLayerVisibility) => {
        this.OverlayLayerRow({
          overlayId: overlay.id,
          layerNumber: layer.layerNumber,
          datatype: layer.datatype,
          visible: this.isOverlayLayerVisible(overlay.id, layer.layerNumber, layer.datatype),
          viewId: viewId,
          context: context
        })
      }, (layer: ViewLayerVisibility) => `${overlay.id}:${layer.layerNumber}:${layer.datatype}`)
      if (this.overlayLayerPageCount(overlay) > 1) {
        Flex({ wrap: FlexWrap.Wrap }) {
          Button('上一页图层', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
            .enabled(this.overlayCurrent(viewId, context) && this.overlayLayerPage > 0)
            .onClick(() => this.changeOverlayLayerPage(viewId, context, overlay.id, this.overlayLayerPage - 1)).id(`view-overlay-${overlay.id}-layers-prev`)
          Text(`${Math.min(this.overlayLayerPage + 1, this.overlayLayerPageCount(overlay))}/${this.overlayLayerPageCount(overlay)} 页`).fontSize(UI.fontCaption).fontColor(COLORS.muted).margin({ top: 8, right: 8 })
          Button('下一页图层', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 })
            .enabled(this.overlayCurrent(viewId, context) && this.overlayLayerPage + 1 < this.overlayLayerPageCount(overlay))
            .onClick(() => this.changeOverlayLayerPage(viewId, context, overlay.id, this.overlayLayerPage + 1)).id(`view-overlay-${overlay.id}-layers-next`)
        }.width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private OverlayRow(spec: OverlayRowSpec) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text(`${spec.index + 1} · ${this.overlaySourceLabel(spec.overlay.sourceDocumentId)}`).fontSize(UI.fontBody).fontWeight(FontWeight.Medium)
          .fontColor(COLORS.ink).layoutWeight(1).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('显示').fontSize(UI.fontCaption).fontColor(COLORS.muted)
        Toggle({ type: ToggleType.Switch, isOn: this.isOverlayVisible(spec.overlay.id) }).selectedColor(COLORS.primary)
          .enabled(this.overlayCurrent(spec.viewId, spec.context))
          .onChange((visible: boolean) => {
            if (visible === this.isOverlayVisible(spec.overlay.id)) {
              return;
            }
            this.changeOverlay(spec.viewId, spec.context, spec.overlay.id, 'visible', visible);
          })
          .id(`view-overlay-${spec.overlay.id}-visible`).accessibilityText(`只读叠加来源 ${this.overlaySourceLabel(spec.overlay.sourceDocumentId)} 显示`)
      }.width('100%')
      Text(`Cell：${this.overlayCellLabel(spec.overlay)} · ${spec.overlay.cellKey}`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      if (this.overlayProblem(spec.overlay).length > 0) {
        Text(this.overlayProblem(spec.overlay)).fontSize(UI.fontCaption).fontColor(COLORS.danger).width('100%').id(`view-overlay-${spec.overlay.id}-diagnostic`)
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('上移', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.overlayCurrent(spec.viewId, spec.context) && spec.index > 0).onClick(() => this.changeOverlay(spec.viewId, spec.context, spec.overlay.id, 'up')).id(`view-overlay-${spec.overlay.id}-up`)
        Button('下移', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.overlayCurrent(spec.viewId, spec.context) && spec.index + 1 < this.currentOverlays().length).onClick(() => this.changeOverlay(spec.viewId, spec.context, spec.overlay.id, 'down')).id(`view-overlay-${spec.overlay.id}-down`)
        Button(this.expandedOverlayId === spec.overlay.id ? '收起变换与图层' : '变换与图层', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.overlayCurrent(spec.viewId, spec.context)).onClick(() => this.expandOverlay(spec.viewId, spec.context, spec.overlay.id)).id(`view-overlay-${spec.overlay.id}-expand`)
        Button('移除', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 }).fontColor(COLORS.danger).backgroundColor(COLORS.dangerSoft)
          .enabled(this.overlayCurrent(spec.viewId, spec.context)).onClick(() => this.changeOverlay(spec.viewId, spec.context, spec.overlay.id, 'remove')).id(`view-overlay-${spec.overlay.id}-remove`)
      }.width('100%')
      Row({ space: 8 }) {
        Text('不透明度').fontSize(UI.fontCaption).fontColor(COLORS.muted).width(72)
        TextInput({ text: this.overlayNumberText(spec.overlay, 'opacity'), placeholder: '0–100' }).viewWorkspaceInput().maxLength(96).layoutWeight(1)
          .enabled(this.overlayCurrent(spec.viewId, spec.context)).onChange((value: string) => this.editOverlayNumber(spec.viewId, spec.context, spec.overlay.id, 'opacity', value))
          .id(`view-overlay-${spec.overlay.id}-opacity`).accessibilityText('叠加来源不透明度百分比')
        Text('%').fontSize(UI.fontBody).fontColor(COLORS.muted).width(20)
      }.width('100%')
      if (this.expandedOverlayId === spec.overlay.id) {
        Flex({ wrap: FlexWrap.Wrap }) {
          this.OverlayNumberField(spec.overlay, 'a', 'a', spec.viewId, spec.context)
          this.OverlayNumberField(spec.overlay, 'b', 'b', spec.viewId, spec.context)
          this.OverlayNumberField(spec.overlay, 'c', 'c', spec.viewId, spec.context)
          this.OverlayNumberField(spec.overlay, 'd', 'd', spec.viewId, spec.context)
          this.OverlayNumberField(spec.overlay, 'tx', 'tx (nm)', spec.viewId, spec.context)
          this.OverlayNumberField(spec.overlay, 'ty', 'ty (nm)', spec.viewId, spec.context)
        }.width('100%')
        Button('重置变换', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(this.overlayCurrent(spec.viewId, spec.context)).onClick(() => this.resetOverlayTransform(spec.viewId, spec.context, spec.overlay.id)).id(`view-overlay-${spec.overlay.id}-reset`)
      }
      if (this.overlayDraft(spec.overlay.id) && this.overlayDraft(spec.overlay.id)!.context !== spec.context) {
        Text('草稿版本已变化，重新读取后提交').fontSize(UI.fontCaption).fontColor(COLORS.warning).width('100%')
      }
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('重新读取设置', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
          .enabled(this.overlayCurrent(spec.viewId, spec.context) && this.overlayDraft(spec.overlay.id) !== undefined)
          .onClick(() => this.rereadOverlayDraft(spec.viewId, spec.context, spec.overlay.id)).id(`view-overlay-${spec.overlay.id}-reread`)
        Button('应用数值设置', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 })
          .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .enabled(this.overlayCurrent(spec.viewId, spec.context) && this.overlayDraft(spec.overlay.id) !== undefined && this.overlayDraft(spec.overlay.id)!.context === spec.context)
          .onClick(() => this.applyOverlayNumbers(spec.viewId, spec.context, spec.overlay.id)).id(`view-overlay-${spec.overlay.id}-apply`)
      }.width('100%')
      if (this.expandedOverlayId === spec.overlay.id) { this.OverlayLayers(spec.overlay, spec.viewId, spec.context) }
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(COLORS.surfaceMuted)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.panelRadius).id(`view-overlay-source-${spec.overlay.id}`)
  }

  @Builder
  private OverlayContent(documents: ViewOverlayDocumentChoice[], viewId: string, context: string) {
    Column({ space: 12 }) {
      Text(`当前视图：${this.activeOverlayView()?.name ?? '尚未就绪'} · 层级 ${this.activeOverlayView()?.presentation.hierarchyDepth ?? 1} · 只读`)
        .fontSize(UI.fontCaption).fontColor(COLORS.primary).width('100%').padding(8).backgroundColor(COLORS.primarySoft).borderRadius(UI.controlRadius)
      this.OverlayPicker(documents, viewId, context)
      Text(`叠加来源 · ${this.currentOverlays().length}/64`).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      if (this.currentOverlays().length === 0) {
        Text('尚无只读叠加来源').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%')
      }
      ForEach(this.currentOverlays(), (overlay: ViewOverlayState, index: number) => {
        this.OverlayRow({ overlay: overlay, index: index, viewId: viewId, context: context })
      }, (overlay: ViewOverlayState) => `${viewId}:${context}:${this.overlayControlEpoch}:${overlay.id}:${overlay.sourceDocumentId}:${overlay.cellKey}`)
    }.width('100%').alignItems(HorizontalAlign.Start).id('view-overlay-content')
  }

  build() {
    Column({ space: 12 }) {
      PanelHeading({ title: '视图与书签', subtitle: this.documentTitle, closeAction: () => this.closeAction() })
      StableSegmentButton({
        items: [{ text: '视图' }, { text: '书签' }, { text: '只读叠加' }] as [SegmentButtonTextItem, SegmentButtonTextItem, SegmentButtonTextItem] as SegmentButtonItemTuple,
        selectedIndex: this.selectedIndexes[0] ?? 0,
        onItemClicked: (idx: number) => { this.selectedIndexes = [idx]; },
        fontColor: COLORS.muted,
        selectedFontColor: COLORS.primary,
        capsuleBackgroundColor: COLORS.surfaceMuted,
        selectedBackgroundColor: COLORS.primarySoft,
        fontSizeFp: UI.fontBody,
        capsuleBorderRadius: UI.controlRadius,
        buttonMinHeight: 36,
        itemMinHeight: 30
      }).width('100%')
      Scroll() {
        Column({ space: 12 }) {
          if (this.localError.length > 0 || this.status.length > 0) {
            Text(this.localError.length > 0 ? this.localError : this.status).fontSize(UI.fontCaption)
              .fontColor(this.localError.length > 0 ? COLORS.danger : COLORS.accent).width('100%').id('view-workspace-status')
          }
          if (!this.ready) {
            Text('视图库尚未就绪').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%')
          } else if (this.isOverlayTab()) {
            ForEach([this.overlayContext], (context: string) => {
              this.OverlayContent(this.overlayChoices(), this.activeViewId, context)
            }, (context: string) => this.overlayContentKey(context))
          } else if (this.isBookmarkTab()) {
            if (this.bookmarks.length === 0) { Text('尚无书签').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%') }
            ForEach(this.bookmarks, (bookmark: ViewBookmark) => { this.BookmarkRow(bookmark) }, (bookmark: ViewBookmark) => `${bookmark.id}:${bookmark.name}`)
          } else {
            ForEach(this.views, (view: ViewRecord) => { this.ViewRow(view) }, (view: ViewRecord) => `${view.id}:${view.name}`)
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)
      .id('view-workspace-content')

      Column({ space: 8 }) {
        if (this.isOverlayTab()) {
          Text('只读叠加不参与编辑与命中')
            .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').id('view-overlay-readonly-note')
        } else {
          Flex({ direction: this.panelWidth < 420 ? FlexDirection.Column : FlexDirection.Row }) {
            TextInput({ text: this.isBookmarkTab() ? this.bookmarkName : this.viewName, placeholder: this.isBookmarkTab() ? '新书签名称' : '新视图名称' })
              .viewWorkspaceInput().maxLength(512).width('100%').layoutWeight(this.panelWidth < 420 ? 0 : 1)
              .enabled(this.available()).onChange((value: string) => { if (this.isBookmarkTab()) this.bookmarkName = value; else this.viewName = value; })
              .id('view-workspace-name-input')
            Button(this.isBookmarkTab() ? '保存当前书签' : '克隆当前视图', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
              .margin({ left: this.panelWidth < 420 ? 0 : 8, top: this.panelWidth < 420 ? 8 : 0 }).width(this.panelWidth < 420 ? '100%' : 128)
              .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
              .enabled(this.available() && this.hasView(this.activeViewId) && (this.isBookmarkTab() ? this.bookmarkName : this.viewName).trim().length > 0)
              .onClick(() => this.createRecord()).id('view-workspace-create')
          }.width('100%')
          if (this.isBookmarkTab()) {
            Flex({ wrap: FlexWrap.Wrap }) {
              Button('合并导入 JSON', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
                .enabled(this.available()).onClick(() => this.transfer(true, false))
              Button('替换导入 JSON', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ right: 8, bottom: 4 })
                .enabled(this.available()).onClick(() => this.transfer(true, true))
              Button('导出 JSON', { type: ButtonType.Normal }).viewWorkspaceButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).margin({ bottom: 4 })
                .enabled(this.available()).onClick(() => this.transfer(false, false))
            }.width('100%')
          }
        }
      }.width('100%').padding({ top: 12 }).border({ width: { top: 1 }, color: COLORS.border }).id('view-workspace-actions')
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).id('view-workspace-panel')
  }
}

@Extend(Button)
function viewWorkspaceButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).padding({ left: 12, right: 12 })
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}

@Extend(TextInput)
function viewWorkspaceInput() {
  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).backgroundColor(COLORS.surfaceMuted)
  .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
}
