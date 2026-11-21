import { hongTuThemeState } from '../../store/ThemeStore';
import { PanelHeading } from '../workbench/PanelHeading';
import { SettingsToggleRow } from '../SettingsKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { dialogTransition } from '../../common/Motion';
import { Shape } from '../../models/GdsiiData';
import { CellInfo } from './PlaceInstanceDialog';
import { BooleanGeometryPanel } from './BooleanPreviewDialog';
import { GeometryNumberField } from './GeometryNumberField';
import {
  ImportMergeFileCell,
  ImportMergeFileLayer,
  ImportMergeFileResult,
  ImportMergeFileSelection
} from '../../services/ImportMergeFileService';
import {
  ImportCellMapping,
  ImportLayerMapping,
  ImportMergeOptions,
  ImportMergePreview,
  ImportMergeResult,
  ImportRootPlacement
} from '../../services/ImportMergeService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

interface CellRowDraft {
  sourceCellId: number;
  sourceName: string;
  elementCount: number;
  selectedRoot: boolean;
  actionIndex: number; // 0 = 新建 / 重命名, 1 = 严格复用已有
  targetName: string;
  reuseTargetIndex: number;
}

interface LayerRowDraft {
  sourceLayer: number;
  sourceDatatype: number;
  elementCount: number;
  actionIndex: number; // 0 = 映射, 1 = 丢弃
  targetLayerText: string;
  targetDatatypeText: string;
}

@CustomDialog
export struct ImportMergeDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  private previewTimer: number = -1;
  contextProvider: () => string = () => '';
  cellNameProvider: () => string = () => '';
  dbuProvider: () => number = () => 1;
  targetsProvider: () => CellInfo[] = () => [];
  currentCellProvider: () => number = () => 0;
  layerProvider: () => number[] = () => [0, 0];
  chooseAction: (guard: () => boolean) => Promise<ImportMergeFileResult> =
    async (_guard: () => boolean): Promise<ImportMergeFileResult> => ({ ok: false, cancelled: true, message: '' });
  prepareAction: (selection: ImportMergeFileSelection, options: ImportMergeOptions) => ImportMergeResult =
    (_selection: ImportMergeFileSelection, _options: ImportMergeOptions): ImportMergeResult => ({ ok: false, message: '' });
  sourceShapesProvider: (selection: ImportMergeFileSelection, root: number) => Shape[] =
    (_selection: ImportMergeFileSelection, _root: number): Shape[] => [];
  previewShapesProvider: (preview: ImportMergePreview) => Shape[] = (_preview: ImportMergePreview): Shape[] => [];
  applyAction: (preview: ImportMergePreview) => ImportMergeResult = (_preview: ImportMergePreview): ImportMergeResult => ({ ok: false, message: '' });
  cancelAction: () => void = () => {};

  private openedContext: string = '';
  private active: boolean = false;
  private selection: ImportMergeFileSelection | undefined = undefined;
  private preview: ImportMergePreview | undefined = undefined;

  @State hasSelection: boolean = false;
  @State fileSummary: string = '';
  @State mergeWholeLibrary: boolean = true;
  @State placeRootInCurrent: boolean = false;
  @State placeXText: string = '0';
  @State placeYText: string = '0';
  @State placeRotationText: string = '0';
  @State placeMagnificationText: string = '1';
  @State placeMirrorX: boolean = false;
  @State entryCellIndex: number = 0;
  @State rejectCollisions: boolean = false;
  @State mergeLibraryProperties: boolean = false;
  @State rejectLayerNames: boolean = false;
  @State targetCells: CellInfo[] = [];
  @State cellRows: CellRowDraft[] = [];
  @State layerRows: LayerRowDraft[] = [];
  @State sourceShapes: Shape[] = [];
  @State previewShapes: Shape[] = [];
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State status: string = '';
  @State warningText: string = '';
  @State contentWidth: number = 760;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.active = true;
    this.openedContext = this.contextProvider();
    this.targetCells = this.targetsProvider();
    this.resetSelectionState();
  }

  aboutToDisappear(): void {
    this.active = false;
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
    this.cancelAction();
  }

  private contextStillValid(): boolean {
    try {
      return this.active && this.openedContext.length > 0 && this.openedContext === this.contextProvider();
    } catch (_) {
      return false;
    }
  }

  private resetSelectionState(): void {
    this.selection = undefined;
    this.preview = undefined;
    this.hasSelection = false;
    this.ready = false;
    this.fileSummary = '';
    this.mergeWholeLibrary = true;
    this.placeRootInCurrent = false;
    this.placeXText = '0';
    this.placeYText = '0';
    this.placeRotationText = '0';
    this.placeMagnificationText = '1';
    this.placeMirrorX = false;
    this.entryCellIndex = 0;
    this.rejectCollisions = false;
    this.mergeLibraryProperties = false;
    this.rejectLayerNames = false;
    this.cellRows = [];
    this.layerRows = [];
    this.sourceShapes = [];
    this.previewShapes = [];
    this.warningText = '';
    this.status = '请选择 GDSII、OASIS、CIF 或 DXF 版图文件进行隔离解析与映射预览';
  }

  private invalidatePreview(): void {
    this.preview = undefined;
    this.ready = false;
    this.previewShapes = [];
    this.warningText = '';
  }

  private scheduleRefreshPreview(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    if (!this.hasSelection || this.selection === undefined) return;
    this.invalidatePreview();
    this.previewTimer = setTimeout(() => {
      this.previewTimer = -1;
      if (this.active && !this.busy && this.selection !== undefined) {
        this.refresh();
      }
    }, 100);
  }

  private cancel(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    this.cancelAction();
    this.controller.close();
  }

  private async pickFile(): Promise<void> {
    if (this.busy) return;
    if (!this.contextStillValid()) {
      this.status = '当前文档已变化，请重新打开合并导入';
      return;
    }
    this.busy = true;
    this.invalidatePreview();
    this.status = '正在选择并隔离解析源版图…';
    try {
      const result: ImportMergeFileResult = await this.chooseAction((): boolean => this.contextStillValid());
      if (!this.active) return;
      this.status = result.message;
      if (!result.ok || result.selection === undefined) {
        if (!result.cancelled) {
          this.hasSelection = false;
          this.selection = undefined;
        }
        return;
      }
      const sel: ImportMergeFileSelection = result.selection;
      this.selection = sel;
      this.hasSelection = true;
      this.targetCells = this.targetsProvider();
      this.fileSummary = `${sel.fileName} · ${sel.fileType} · ${sel.cells.length} 个 Cell · DBU ${Number(sel.sourceDbuNm.toPrecision(6))} nm`;
      this.mergeWholeLibrary = true;
      this.entryCellIndex = Math.max(0, sel.cells.findIndex((cell: ImportMergeFileCell): boolean => cell.id === sel.topCellId));
      const topSet: Set<number> = new Set<number>(sel.topCellIds.length > 0 ? sel.topCellIds : [sel.topCellId]);
      this.cellRows = sel.cells.map((cell: ImportMergeFileCell): CellRowDraft => {
        const sameTargetIdx: number = this.targetCells.findIndex((t: CellInfo): boolean => t.name === cell.name);
        return {
          sourceCellId: cell.id,
          sourceName: cell.name,
          elementCount: cell.elementCount,
          selectedRoot: topSet.has(cell.id),
          actionIndex: 0,
          targetName: '',
          reuseTargetIndex: sameTargetIdx >= 0 ? sameTargetIdx : 0
        };
      });
      this.layerRows = sel.layerPairs.map((pair: ImportMergeFileLayer): LayerRowDraft => ({
        sourceLayer: pair.layer,
        sourceDatatype: pair.datatype,
        elementCount: pair.elementCount,
        actionIndex: 0,
        targetLayerText: `${pair.layer}`,
        targetDatatypeText: `${pair.datatype}`
      }));
      this.sourceShapes = this.sourceShapesProvider(sel, sel.topCellId);
      this.busy = false;
      this.refresh();
      return;
    } catch (error) {
      if (this.active) {
        this.status = `文件读取失败：${error instanceof Error ? error.message : String(error)}`;
      }
    } finally {
      this.busy = false;
    }
  }

  private buildOptions(): ImportMergeOptions {
    const sel: ImportMergeFileSelection | undefined = this.selection;
    if (sel === undefined) throw new Error('请先选择导入版图文件');
    const sourceRootIds: number[] | undefined = this.mergeWholeLibrary
      ? undefined
      : this.cellRows.filter((row: CellRowDraft): boolean => row.selectedRoot).map((row: CellRowDraft): number => row.sourceCellId);
    if (sourceRootIds !== undefined && sourceRootIds.length === 0) {
      throw new Error('关闭「合并整个库」后请至少勾选一个源根 Cell');
    }

    const includedIds: Set<number> = new Set<number>();
    if (sourceRootIds === undefined) {
      for (const c of sel.cells) includedIds.add(c.id);
    } else {
      const queue: number[] = sourceRootIds.slice();
      while (queue.length > 0) {
        const cid: number = queue.pop() as number;
        if (includedIds.has(cid)) continue;
        includedIds.add(cid);
        const meta: ImportMergeFileCell | undefined = sel.cells.find((item: ImportMergeFileCell): boolean => item.id === cid);
        for (const refId of meta?.referencedCellIds ?? []) {
          if (!includedIds.has(refId)) queue.push(refId);
        }
      }
    }

    const cellMappings: ImportCellMapping[] = [];
    for (const row of this.cellRows) {
      if (!includedIds.has(row.sourceCellId)) continue;
      if (row.actionIndex === 1) {
        const target: CellInfo | undefined = this.targetCells[row.reuseTargetIndex];
        if (target === undefined) throw new Error(`源 Cell ${row.sourceName} 没有可复用的目标 Cell`);
        cellMappings.push({ sourceCellId: row.sourceCellId, action: 'reuse', targetCellId: target.id });
      } else if (row.targetName.trim().length > 0) {
        cellMappings.push({ sourceCellId: row.sourceCellId, action: 'rename', targetName: row.targetName.trim() });
      }
    }

    const layerMappings: ImportLayerMapping[] = [];
    for (const row of this.layerRows) {
      if (row.actionIndex === 1) {
        layerMappings.push({ sourceLayer: row.sourceLayer, sourceDatatype: row.sourceDatatype, action: 'drop' });
      } else {
        const tlText: string = row.targetLayerText.trim();
        const tdText: string = row.targetDatatypeText.trim();
        if (!/^\d+$/.test(tlText) || !/^\d+$/.test(tdText)) {
          throw new Error(`源层 L${row.sourceLayer}/D${row.sourceDatatype} 的目标 Layer / Datatype 须为 0–32767 整数`);
        }
        const tl: number = Number(tlText);
        const td: number = Number(tdText);
        layerMappings.push({
          sourceLayer: row.sourceLayer,
          sourceDatatype: row.sourceDatatype,
          action: 'map',
          targetLayer: tl,
          targetDatatype: td
        });
      }
    }

    const placements: ImportRootPlacement[] = [];
    if (this.placeRootInCurrent) {
      const px: number = Number(this.placeXText.trim());
      const py: number = Number(this.placeYText.trim());
      const rotation: number = Number(this.placeRotationText.trim());
      const magnification: number = Number(this.placeMagnificationText.trim());
      if (this.placeXText.trim().length === 0 || this.placeYText.trim().length === 0 || !Number.isFinite(px) || !Number.isFinite(py)) {
        throw new Error('放置根实例坐标 X / Y 须为有限数值（nm）');
      }
      if (this.placeRotationText.trim().length === 0 || !Number.isFinite(rotation) || !Number.isFinite(magnification) ||
        magnification <= 0) {
        throw new Error('旋转须为有限数值，缩放须大于 0');
      }
      const root: ImportMergeFileCell | undefined = sel.cells[this.entryCellIndex];
      if (root === undefined || !includedIds.has(root.id)) {
        throw new Error('请选择一个包含在本次导入范围内的入口 Cell');
      }
      const activeLayer: number[] = this.layerProvider();
      placements.push({
        sourceCellId: root.id,
        targetCellId: this.currentCellProvider(),
        xNm: px,
        yNm: py,
        rotation: rotation,
        magnification: magnification,
        mirror: this.placeMirrorX ? 1 : 0,
        layer: activeLayer[0] ?? 0,
        datatype: activeLayer[1] ?? 0
      });
    }

    return {
      sourceRootIds: sourceRootIds,
      cellMappings: cellMappings,
      layerMappings: layerMappings,
      collisionPolicy: this.rejectCollisions ? 'reject' : 'rename',
      libraryProperties: this.mergeLibraryProperties ? 'merge' : 'keep-target',
      layerNameConflictPolicy: this.rejectLayerNames ? 'reject' : 'keep-target',
      placements: placements.length > 0 ? placements : undefined
    };
  }

  private refresh(): void {
    if (this.busy) return;
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    this.invalidatePreview();
    if (!this.contextStillValid()) {
      this.status = '目标文档已变化，请重新打开合并导入';
      return;
    }
    const sel: ImportMergeFileSelection | undefined = this.selection;
    if (sel === undefined) {
      this.status = '请先选择版图文件';
      return;
    }
    this.busy = true;
    try {
      const options: ImportMergeOptions = this.buildOptions();
      const previewRoot: number = options.placements?.[0]?.sourceCellId ?? options.sourceRootIds?.[0] ?? sel.topCellId;
      this.sourceShapes = this.sourceShapesProvider(sel, previewRoot);
      const result: ImportMergeResult = this.prepareAction(sel, options);
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.preview = result.preview;
        this.previewShapes = this.previewShapesProvider(result.preview);
        this.warningText = result.preview.warnings.join('；');
        this.ready = true;
      }
    } catch (error) {
      this.invalidatePreview();
      this.status = `预览未就绪：${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private apply(): void {
    if (this.busy) return;
    if (!this.ready || this.preview === undefined) {
      this.refresh();
    }
    if (!this.ready || this.preview === undefined) return;
    if (!this.contextStillValid()) {
      this.invalidatePreview();
      this.status = '目标文档已变化，请重新打开合并导入';
      return;
    }
    this.busy = true;
    try {
      const result: ImportMergeResult = this.applyAction(this.preview);
      this.status = result.message;
      if (result.ok) {
        this.invalidatePreview();
        this.controller.close();
      } else {
        this.invalidatePreview();
      }
    } catch (error) {
      this.invalidatePreview();
      this.status = `合并失败：${error instanceof Error ? error.message : String(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private updateCellRow(index: number, patch: Partial<CellRowDraft>, immediate: boolean = false): void {
    if (index < 0 || index >= this.cellRows.length) return;
    const prev: CellRowDraft = this.cellRows[index];
    const nextRow: CellRowDraft = {
      sourceCellId: prev.sourceCellId,
      sourceName: prev.sourceName,
      elementCount: prev.elementCount,
      selectedRoot: patch.selectedRoot !== undefined ? patch.selectedRoot : prev.selectedRoot,
      actionIndex: patch.actionIndex !== undefined ? patch.actionIndex : prev.actionIndex,
      targetName: patch.targetName !== undefined ? patch.targetName : prev.targetName,
      reuseTargetIndex: patch.reuseTargetIndex !== undefined ? patch.reuseTargetIndex : prev.reuseTargetIndex
    };
    const copy: CellRowDraft[] = this.cellRows.slice();
    copy[index] = nextRow;
    this.cellRows = copy;
    if (immediate) this.refresh();
    else this.scheduleRefreshPreview();
  }

  private updateLayerRow(index: number, patch: Partial<LayerRowDraft>, immediate: boolean = false): void {
    if (index < 0 || index >= this.layerRows.length) return;
    const prev: LayerRowDraft = this.layerRows[index];
    const nextRow: LayerRowDraft = {
      sourceLayer: prev.sourceLayer,
      sourceDatatype: prev.sourceDatatype,
      elementCount: prev.elementCount,
      actionIndex: patch.actionIndex !== undefined ? patch.actionIndex : prev.actionIndex,
      targetLayerText: patch.targetLayerText !== undefined ? patch.targetLayerText : prev.targetLayerText,
      targetDatatypeText: patch.targetDatatypeText !== undefined ? patch.targetDatatypeText : prev.targetDatatypeText
    };
    const copy: LayerRowDraft[] = this.layerRows.slice();
    copy[index] = nextRow;
    this.layerRows = copy;
    if (immediate) this.refresh();
    else this.scheduleRefreshPreview();
  }

  private reuseSelectOptions(): SelectOption[] {
    if (this.targetCells.length === 0) {
      return [{ value: '无可用目标 Cell' }];
    }
    return this.targetCells.map((cell: CellInfo): SelectOption => ({ value: cell.name }));
  }

  @Builder
  private CellMappingSection() {
    Column({ space: 8 }) {
      Text('Cell 映射 · 严格复用要求映射后内容与属性完全相同')
        .fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      ForEach(this.cellRows, (row: CellRowDraft, index: number) => {
        Column({ space: 8 }) {
          Row({ space: 10 }) {
            Checkbox({ name: `merge_cell_${row.sourceCellId}` })
              .select(this.mergeWholeLibrary ? true : row.selectedRoot)
              .selectedColor(COLORS.primary)
              .enabled(!this.busy && !this.mergeWholeLibrary)
              .width(20).height(20).margin(0)
              .onChange((checked: boolean) => {
                if (!this.mergeWholeLibrary && checked !== row.selectedRoot) {
                  this.updateCellRow(index, { selectedRoot: checked }, true);
                }
              })
            Text(`${row.sourceName} · ${row.elementCount} 个对象`)
              .fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Select([{ value: '新建 / 重命名' }, { value: '严格复用已有' }])
              .selected(row.actionIndex)
              .value(row.actionIndex === 1 ? '严格复用已有' : '新建 / 重命名')
              .height(UI.fieldHeight)
              .width(148)
              .font({ size: UI.fontCaption })
              .fontColor(COLORS.ink)
              .backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border })
              .borderRadius(UI.controlRadius)
              .enabled(!this.busy)
              .onSelect((actIdx: number) => {
                if (actIdx !== row.actionIndex) {
                  this.updateCellRow(index, { actionIndex: actIdx }, true);
                }
              })
          }.width('100%').alignItems(VerticalAlign.Center)

          if (row.actionIndex === 0) {
            TextInput({ text: row.targetName, placeholder: '目标名称留空：按重名策略自动命名' })
              .width('100%').height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
              .placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .enabled(!this.busy)
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .onChange((val: string) => {
                if (val !== row.targetName) {
                  this.updateCellRow(index, { targetName: val }, false);
                }
              })
          } else {
            Select(this.reuseSelectOptions())
              .selected(row.reuseTargetIndex)
              .value(this.targetCells[row.reuseTargetIndex]?.name ?? '选择复用目标 Cell')
              .width('100%').height(UI.fieldHeight).font({ size: UI.fontBody }).fontColor(COLORS.ink)
              .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .enabled(!this.busy && this.targetCells.length > 0)
              .onSelect((targetIdx: number) => {
                if (targetIdx !== row.reuseTargetIndex) {
                  this.updateCellRow(index, { reuseTargetIndex: targetIdx }, true);
                }
              })
          }
        }
        .width('100%').padding(12).backgroundColor(COLORS.surface)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
      }, (row: CellRowDraft): string => `${row.sourceCellId}:${row.actionIndex}:${this.mergeWholeLibrary}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private LayerMappingSection() {
    Column({ space: 8 }) {
      Text('层映射 · 源层/Datatype及数量  ->  操作  ->  目标 Layer / Datatype')
        .fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      if (this.layerRows.length === 0) {
        Text('源版图无普通几何图层（仅含 Cell 定义或空引用）')
          .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').padding(8)
      }
      ForEach(this.layerRows, (row: LayerRowDraft, index: number) => {
        Row({ space: 10 }) {
          Text(`L${row.sourceLayer}/D${row.sourceDatatype} · ${row.elementCount} 项`)
            .fontSize(UI.fontBody).fontColor(COLORS.ink).width(142).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Select([{ value: '映射' }, { value: '丢弃' }])
            .selected(row.actionIndex)
            .value(row.actionIndex === 1 ? '丢弃' : '映射')
            .height(UI.fieldHeight)
            .width(104)
            .font({ size: UI.fontBody })
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .enabled(!this.busy)
            .onSelect((actIdx: number) => {
              if (actIdx !== row.actionIndex) {
                this.updateLayerRow(index, { actionIndex: actIdx }, true);
              }
            })
          TextInput({ text: row.targetLayerText, placeholder: 'Layer' })
            .layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
            .placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .enabled(!this.busy && row.actionIndex === 0)
            .onFocus(() => { resetModifierKeys(); })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .onChange((val: string) => {
              if (val !== row.targetLayerText) {
                this.updateLayerRow(index, { targetLayerText: val }, false);
              }
            })
          TextInput({ text: row.targetDatatypeText, placeholder: 'Datatype' })
            .layoutWeight(1).height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
            .placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .enabled(!this.busy && row.actionIndex === 0)
            .onFocus(() => { resetModifierKeys(); })
            .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
            .onChange((val: string) => {
              if (val !== row.targetDatatypeText) {
                this.updateLayerRow(index, { targetDatatypeText: val }, false);
              }
            })
        }
        .width('100%').padding(10).backgroundColor(COLORS.surface)
        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
        .alignItems(VerticalAlign.Center)
      }, (row: LayerRowDraft): string => `${row.sourceLayer}/${row.sourceDatatype}:${row.actionIndex}`)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Column({ space: 12 }) {
      PanelHeading({
        title: '合并导入',
        subtitle: `当前目标 ${this.cellNameProvider()} · DBU ${this.dbuProvider()} nm`,
        closeAction: () => { if (!this.busy) this.cancel(); }
      })

      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Button('选择版图文件', { type: ButtonType.Normal })
              .height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 18, right: 18 })
              .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .attributeModifier(hongTuThemeState.luminousPointLightModifier())
              .enabled(!this.busy)
              .onClick(() => { this.pickFile(); })
            if (this.fileSummary.length > 0) {
              Text(this.fileSummary)
                .fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1).maxLines(2)
            }
          }.width('100%').alignItems(VerticalAlign.Center)

          if (this.hasSelection) {
            Row({ space: 8 }) {
              Checkbox({ name: 'merge_whole_lib' })
                .select(this.mergeWholeLibrary)
                .selectedColor(COLORS.primary)
                .width(20).height(20).margin(0)
                .enabled(!this.busy)
                .onChange((checked: boolean) => {
                  if (checked !== this.mergeWholeLibrary) {
                    this.mergeWholeLibrary = checked;
                    this.refresh();
                  }
                })
              Text('合并整个库（关闭后勾选源根 Cell，依赖自动包含）')
                .fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
            }.width('100%').alignItems(VerticalAlign.Center)

            Row({ space: 8 }) {
              Checkbox({ name: 'place_root_in_current' })
                .select(this.placeRootInCurrent)
                .selectedColor(COLORS.primary)
                .width(20).height(20).margin(0)
                .enabled(!this.busy)
                .onChange((checked: boolean) => {
                  if (checked !== this.placeRootInCurrent) {
                    this.placeRootInCurrent = checked;
                    this.refresh();
                  }
                })
              Text(`同时在当前 Cell (${this.cellNameProvider()}) 放置导入根实例`)
                .fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
              if (this.placeRootInCurrent) {
                TextInput({ text: this.placeXText, placeholder: 'X nm' })
                  .width(96).height(UI.compactControlHeight).fontSize(UI.fontCaption).fontColor(COLORS.ink)
                  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                  .onFocus(() => { resetModifierKeys(); }).onKeyEvent((e: KeyEvent) => e.stopPropagation())
                  .onChange((v: string) => { if (v !== this.placeXText) { this.placeXText = v; this.scheduleRefreshPreview(); } })
                TextInput({ text: this.placeYText, placeholder: 'Y nm' })
                  .width(96).height(UI.compactControlHeight).fontSize(UI.fontCaption).fontColor(COLORS.ink)
                  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
                  .onFocus(() => { resetModifierKeys(); }).onKeyEvent((e: KeyEvent) => e.stopPropagation())
                  .onChange((v: string) => { if (v !== this.placeYText) { this.placeYText = v; this.scheduleRefreshPreview(); } })
              }
            }.width('100%').alignItems(VerticalAlign.Center)

            this.CellMappingSection()
            this.LayerMappingSection()

            SettingsToggleRow({ title: '重名即拒绝（默认自动重命名）', isOn: this.rejectCollisions, compact: true,
              enabledState: !this.busy, onToggle: (value: boolean) => { this.rejectCollisions = value; this.refresh(); } })
            SettingsToggleRow({ title: '合并源库属性（冲突拒绝）', isOn: this.mergeLibraryProperties, compact: true,
              enabledState: !this.busy, onToggle: (value: boolean) => { this.mergeLibraryProperties = value; this.refresh(); } })
            SettingsToggleRow({ title: '图层名称冲突即拒绝（默认保留目标名称）', isOn: this.rejectLayerNames, compact: true,
              enabledState: !this.busy, onToggle: (value: boolean) => { this.rejectLayerNames = value; this.refresh(); } })
            if (this.placeRootInCurrent) {
              Select(this.cellRows.map((row: CellRowDraft): SelectOption => ({ value: row.sourceName })))
                .selected(this.entryCellIndex).value(this.cellRows[this.entryCellIndex]?.sourceName ?? '选择入口 Cell')
                .width('100%').height(UI.fieldHeight).font({ size: UI.fontBody }).borderRadius(UI.controlRadius).enabled(!this.busy)
                .accessibilityText('选择入口 Cell')
                .onSelect((index: number) => { this.entryCellIndex = index; this.refresh(); })
              Row({ space: 12 }) {
                GeometryNumberField({ label: '旋转 (°)', value: this.placeRotationText, inputAllowed: !this.busy,
                  onValueChange: (value: string) => { this.placeRotationText = value; this.scheduleRefreshPreview(); } }).layoutWeight(1)
                GeometryNumberField({ label: '缩放 (>0)', value: this.placeMagnificationText, inputAllowed: !this.busy,
                  onValueChange: (value: string) => { this.placeMagnificationText = value; this.scheduleRefreshPreview(); } }).layoutWeight(1)
              }.width('100%')
              SettingsToggleRow({ title: '镜像 X', isOn: this.placeMirrorX, compact: true, enabledState: !this.busy,
                onToggle: (value: boolean) => { this.placeMirrorX = value; this.refresh(); } })
            }

            if (this.contentWidth >= 560) {
              Row({ space: 12 }) {
                BooleanGeometryPanel({
                  title: `源版图预览 · ${this.sourceShapes.length} 个填充对象`,
                  shapes: this.sourceShapes,
                  extentShapes: this.sourceShapes
                })
                BooleanGeometryPanel({
                  title: this.ready ? `合并后当前 Cell · ${this.previewShapes.length} 个填充对象` : '合并后预览待生成',
                  shapes: this.previewShapes,
                  extentShapes: this.previewShapes.length > 0 ? this.previewShapes : this.sourceShapes
                })
              }.width('100%')
            } else {
              BooleanGeometryPanel({
                title: `源版图预览 · ${this.sourceShapes.length} 个填充对象`,
                shapes: this.sourceShapes,
                extentShapes: this.sourceShapes
              })
              BooleanGeometryPanel({
                title: this.ready ? `合并后当前 Cell · ${this.previewShapes.length} 个填充对象` : '合并后预览待生成',
                shapes: this.previewShapes,
                extentShapes: this.previewShapes.length > 0 ? this.previewShapes : this.sourceShapes
              })
            }

            if (this.warningText.length > 0) {
              Text(this.warningText).fontSize(UI.fontCaption).fontColor(COLORS.warning).width('100%')
            }
          }
        }.width('100%').padding({ right: 6, bottom: 12 }).alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      if (this.status.length > 0) {
        Text(this.status)
          .fontSize(UI.fontCaption)
          .fontColor(this.ready || !this.hasSelection ? COLORS.muted : COLORS.danger)
          .width('100%')
      }

      Row({ space: 12 }) {
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 20, right: 20 })
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(!this.busy).onClick(() => this.cancel())
        Blank()
        Button('更新预览', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 20, right: 20 })
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(this.hasSelection && !this.busy).onClick(() => this.refresh())
        Button('合并', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
          .backgroundColor(COLORS.primary).fontColor(Color.White)
          .border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .enabled(this.hasSelection && !this.busy).onClick(() => this.apply())
      }.width('100%').padding({ top: 14 }).border({ width: { top: 1 }, color: COLORS.border })
    }
    .width(820).height('88%').constraintSize({ maxWidth: '94%', maxHeight: 820 }).padding(UI.dialogPadding)
    .backgroundColor(COLORS.surface).borderRadius(UI.dialogRadius).transition(dialogTransition())
    .onKeyEvent((event: KeyEvent) => event.stopPropagation())
    .onAreaChange((_old: Area, area: Area) => { this.contentWidth = Math.max(0, Number(area.width) - 2 * UI.dialogPadding); })
  }
}
