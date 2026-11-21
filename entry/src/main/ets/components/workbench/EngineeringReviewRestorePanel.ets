import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import type { EngineeringReviewRestorePreview } from '../../models/EngineeringReviewBundle';

export interface EngineeringRestoreSourceChoice {
  documentId: string;
  title: string;
}

interface EngineeringRestoreSelectOption { value: string; }

interface EngineeringReviewRestoreMappingRow {
  sourceDocumentId: string;
  targetDocumentId: string;
}

interface EngineeringReviewRestoreDiagnosticRow {
  code: string;
  message: string;
  sourceDocumentId?: string;
  cellKey?: string;
}

interface RestoreSourceMappingParams {
  sourceId: string;
  token: string;
  generation: number;
  inventory: string;
  choices: EngineeringRestoreSourceChoice[];
}

interface RestoreMappingControlsParams {
  token: string;
  generation: number;
  inventory: string;
}

interface RestoreMetricParams {
  label: string;
  count: number;
}

interface RestorePreviewParams {
  preview: EngineeringReviewRestorePreview;
}

interface RestoreMappingRowParams {
  mapping: EngineeringReviewRestoreMappingRow;
  index: number;
}

interface RestoreActionsParams {
  token: string;
  generation: number;
}

/** Owner prepares every explicit mapping change; it alone publishes after CAS. */
@Component
export struct EngineeringReviewRestorePanel {
  @Prop @Watch('resetPreviewState') preview: EngineeringReviewRestorePreview | undefined = undefined;
  @Prop busy: boolean = false;
  @Prop error: string = '';
  @Prop panelWidth: number = 640;
  @Prop panelHeight: number = 620;
  @Prop @Watch('resetPreviewState') sourceDocumentIds: string[] = [];
  @Prop @Watch('resetPreviewState') targetDocuments: EngineeringRestoreSourceChoice[] = [];
  @Prop @Watch('resetPreviewState') replaceTargetViews: boolean = false;
  onConfirm: (token: string) => void = () => {};
  onCancel: (token: string) => void = () => {};
  onMapping: (sourceDocumentId: string, targetDocumentId: string, token: string) => void = () => {};
  onReplaceViews: (replace: boolean, token: string) => void = () => {};
  @State localError: string = '';
  private active: boolean = true;
  @State private generation: number = 0;
  private dispatching: boolean = false;

  aboutToAppear(): void { this.active = true; }
  aboutToDisappear(): void { this.active = false; this.generation++; }

  private resetPreviewState(): void {
    this.generation++;
    this.localError = '';
  }

  private current(token: string, generation: number): boolean {
    return this.active && !this.dispatching && generation === this.generation &&
      token.length > 0 && this.preview !== undefined && this.preview.token === token;
  }

  private canConfirm(token: string, generation: number): boolean {
    return this.current(token, generation) && !this.busy && this.preview !== undefined && this.preview.canRestore;
  }

  private confirm(token: string, generation: number): void {
    if (!this.canConfirm(token, generation)) return;
    this.invoke(token, generation, true);
  }

  private cancel(token: string, generation: number): void {
    if (!this.current(token, generation)) return;
    this.invoke(token, generation, false);
  }

  private invoke(token: string, generation: number, confirming: boolean): void {
    this.localError = '';
    this.dispatching = true;
    try {
      if (confirming) this.onConfirm(token);
      else this.onCancel(token);
    } catch (error) {
      if (this.active && this.generation === generation && this.preview !== undefined && this.preview.token === token) {
        this.localError = error instanceof Error ? error.message : String(error);
      }
    } finally { this.dispatching = false; }
  }

  private statusText(preview: EngineeringReviewRestorePreview): string {
    if (this.busy) return '正在恢复';
    return preview.canRestore ? '待确认' : '恢复已阻断';
  }

  private visibleError(): string { return this.localError.length > 0 ? this.localError : this.error; }

  private mappingInventory(): string {
    return JSON.stringify([this.sourceDocumentIds, this.targetDocuments, this.preview?.mappings, this.replaceTargetViews]);
  }

  private previewRenderKey(): string {
    return JSON.stringify([this.preview?.token ?? '', this.generation, this.mappingInventory()]);
  }

  private validMappingInventory(): boolean {
    return this.preview !== undefined && Array.isArray(this.sourceDocumentIds) && Array.isArray(this.targetDocuments) &&
      this.sourceDocumentIds.includes(this.preview.sourceWorkspaceId) &&
      this.sourceDocumentIds.every((id: string): boolean => typeof id === 'string' && id.trim().length > 0) &&
      new Set(this.sourceDocumentIds).size === this.sourceDocumentIds.length &&
      this.targetDocuments.every((choice: EngineeringRestoreSourceChoice): boolean =>
        typeof choice.documentId === 'string' && choice.documentId.trim().length > 0 && typeof choice.title === 'string') &&
      new Set(this.targetDocuments.map((choice: EngineeringRestoreSourceChoice): string => choice.documentId)).size === this.targetDocuments.length;
  }

  private canEditMapping(token: string, generation: number, inventory: string): boolean {
    return this.current(token, generation) && !this.busy && this.validMappingInventory() && inventory === this.mappingInventory();
  }

  private sourceChoices(): EngineeringRestoreSourceChoice[] {
    return this.targetDocuments.map((choice: EngineeringRestoreSourceChoice): EngineeringRestoreSourceChoice =>
      ({ documentId: choice.documentId, title: choice.title }));
  }

  private mappedTarget(sourceId: string): string {
    return this.preview?.mappings.find((mapping: EngineeringReviewRestoreMappingRow): boolean => mapping.sourceDocumentId === sourceId)?.targetDocumentId ?? '';
  }

  private mappingOptions(choices: EngineeringRestoreSourceChoice[]): EngineeringRestoreSelectOption[] {
    const options: EngineeringRestoreSelectOption[] = [{ value: '未关联' }];
    return options.concat(choices.map((choice: EngineeringRestoreSourceChoice): EngineeringRestoreSelectOption =>
      ({ value: `${choice.title} · ${choice.documentId}` })));
  }

  private mappingIndex(sourceId: string, choices: EngineeringRestoreSourceChoice[]): number {
    const target: string = this.mappedTarget(sourceId);
    if (target.length === 0) return 0;
    const index: number = choices.findIndex((choice: EngineeringRestoreSourceChoice): boolean => choice.documentId === target);
    return index < 0 ? -1 : index + 1;
  }

  private mappingLabel(sourceId: string, choices: EngineeringRestoreSourceChoice[]): string {
    const target: string = this.mappedTarget(sourceId);
    if (target.length === 0) return '未关联';
    const choice = choices.find((item: EngineeringRestoreSourceChoice): boolean => item.documentId === target);
    if (choice !== undefined) return `${choice.title} · ${choice.documentId}`;
    return sourceId === this.preview?.sourceWorkspaceId ? `已指定新文档 · ${target}` : `当前目标未打开 · ${target}`;
  }

  private selectMapping(sourceId: string, index: number, choices: EngineeringRestoreSourceChoice[],
    token: string, generation: number, inventory: string): void {
    if (!this.canEditMapping(token, generation, inventory) || !this.sourceDocumentIds.includes(sourceId) ||
      sourceId === this.preview?.sourceWorkspaceId || !Number.isSafeInteger(index) || index < 0 || index > choices.length) return;
    const target: string = index === 0 ? '' : choices[index - 1].documentId;
    if (target.length > 0 && !this.targetDocuments.some((choice: EngineeringRestoreSourceChoice): boolean => choice.documentId === target)) return;
    if (target === this.mappedTarget(sourceId)) return;
    this.invokeMapping(sourceId, target, token, generation, inventory);
  }

  private replaceViews(replace: boolean, token: string, generation: number, inventory: string): void {
    if (!this.canEditMapping(token, generation, inventory) || typeof replace !== 'boolean' || replace === this.replaceTargetViews) return;
    this.invokeMapping('', replace ? 'true' : 'false', token, generation, inventory, true);
  }

  private invokeMapping(sourceId: string, target: string, token: string, generation: number,
    inventory: string, replacing: boolean = false): void {
    this.localError = ''; this.dispatching = true;
    try {
      if (replacing) this.onReplaceViews(target === 'true', token);
      else this.onMapping(sourceId, target, token);
    } catch (error) {
      if (this.active && this.generation === generation && this.preview?.token === token && inventory === this.mappingInventory()) {
        this.localError = error instanceof Error ? error.message : String(error);
      }
    } finally { this.dispatching = false; }
  }

  @Builder
  private SourceMapping(params: RestoreSourceMappingParams) {
    Column({ space: 4 }) {
      Text(params.sourceId === this.preview?.sourceWorkspaceId ? `主来源（固定） · ${params.sourceId}` : `来源文档 · ${params.sourceId}`)
        .fontFamily('monospace').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').wordBreak(WordBreak.BREAK_ALL)
      Select(this.mappingOptions(params.choices)).selected(this.mappingIndex(params.sourceId, params.choices)).value(this.mappingLabel(params.sourceId, params.choices))
        .width('100%').height(UI.fieldHeight).borderRadius(UI.controlRadius)
        .enabled(this.canEditMapping(params.token, params.generation, params.inventory) && params.sourceId !== this.preview?.sourceWorkspaceId)
        .onSelect((index: number) => this.selectMapping(params.sourceId, index, params.choices, params.token, params.generation, params.inventory))
        .id('engineering-review-restore-source-choice-' + params.sourceId)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private MappingControls(params: RestoreMappingControlsParams) {
    Column({ space: 8 }) {
      Text('关联来源文档').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      ForEach(this.sourceDocumentIds, (sourceId: string) => {
        this.SourceMapping({
          sourceId: sourceId,
          token: params.token,
          generation: params.generation,
          inventory: params.inventory,
          choices: this.sourceChoices()
        })
      }, (sourceId: string) => JSON.stringify([params.token, params.generation, params.inventory, sourceId]))
      ForEach([params.inventory], (choiceInventory: string) => {
        Row({ space: 8 }) {
          Text('替换目标现有视图').fontSize(UI.fontBody).fontColor(COLORS.ink).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.replaceTargetViews }).selectedColor(COLORS.primary)
            .enabled(this.canEditMapping(params.token, params.generation, choiceInventory))
            .onChange((replace: boolean) => this.replaceViews(replace, params.token, params.generation, choiceInventory))
            .id('engineering-review-restore-replace-views')
        }.width('100%')
      }, (choiceInventory: string) => JSON.stringify([params.token, params.generation, choiceInventory]))
    }.width('100%').alignItems(HorizontalAlign.Start).id('engineering-review-restore-mapping-controls')
  }

  @Builder
  private Metric(params: RestoreMetricParams) {
    Column({ space: 4 }) {
      Text(params.label).fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      Text(`${params.count}`).fontSize(UI.titleSize).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  @Builder
  private WorkspaceIds(params: RestorePreviewParams) {
    Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
      Column({ space: 4 }) {
        Text('来源工作区').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Text(params.preview.sourceWorkspaceId).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .width('100%').wordBreak(WordBreak.BREAK_ALL).id('engineering-review-restore-source-workspace')
      }.alignItems(HorizontalAlign.Start).layoutWeight(this.panelWidth < 480 ? 0 : 1).width(this.panelWidth < 480 ? '100%' : '50%')
        .margin({ bottom: this.panelWidth < 480 ? 12 : 0, right: this.panelWidth < 480 ? 0 : 12 })
      Column({ space: 4 }) {
        Text('目标工作区').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
        Text(params.preview.targetWorkspaceId).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .width('100%').wordBreak(WordBreak.BREAK_ALL).id('engineering-review-restore-target-workspace')
      }.alignItems(HorizontalAlign.Start).layoutWeight(this.panelWidth < 480 ? 0 : 1).width(this.panelWidth < 480 ? '100%' : '50%')
    }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius)
  }

  @Builder
  private Counts(params: RestorePreviewParams) {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        this.Metric({ label: '视图', count: params.preview.viewCount })
        this.Metric({ label: '书签', count: params.preview.bookmarkCount })
        this.Metric({ label: '叠加引用', count: params.preview.overlayCount })
      }.width('100%')
      Divider().color(COLORS.border)
      Row({ space: 12 }) {
        this.Metric({ label: '报告', count: params.preview.reportCount })
        this.Metric({ label: '未保存审阅', count: params.preview.dirtyReportCount })
        this.Metric({ label: '来源映射', count: params.preview.mappings.length })
      }.width('100%')
    }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.panelRadius)
      .id('engineering-review-restore-counts')
  }

  @Builder
  private MappingRow(params: RestoreMappingRowParams) {
    if (this.panelWidth >= 480) {
      Row({ space: 12 }) {
        Text(params.mapping.sourceDocumentId).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
        Text(params.mapping.targetDocumentId).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .layoutWeight(1).wordBreak(WordBreak.BREAK_ALL)
      }.width('100%').constraintSize({ minHeight: UI.rowHeight }).padding({ left: 8, right: 8, top: 8, bottom: 8 })
        .border({ width: { bottom: 1 }, color: COLORS.border }).id(`engineering-review-restore-mapping-${params.index}`)
    } else {
      Column({ space: 4 }) {
        Text(`原文档 ID：${params.mapping.sourceDocumentId}`).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .width('100%').wordBreak(WordBreak.BREAK_ALL)
        Text(`新文档 ID：${params.mapping.targetDocumentId}`).fontFamily('monospace').fontSize(UI.fontBody).fontColor(COLORS.ink)
          .width('100%').wordBreak(WordBreak.BREAK_ALL)
      }.width('100%').alignItems(HorizontalAlign.Start).padding(8)
        .border({ width: { bottom: 1 }, color: COLORS.border }).id(`engineering-review-restore-mapping-${params.index}`)
    }
  }

  @Builder
  private Mappings(params: RestorePreviewParams) {
    Column({ space: 8 }) {
      Text('文档来源映射').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      if (this.panelWidth >= 480 && params.preview.mappings.length > 0) {
        Row({ space: 12 }) {
          Text('原文档 ID').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
          Text('新文档 ID').fontSize(UI.fontCaption).fontColor(COLORS.muted).layoutWeight(1)
        }.width('100%').padding(8).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.chipRadius)
      }
      ForEach(params.preview.mappings, (mapping: EngineeringReviewRestoreMappingRow, index: number) => {
        this.MappingRow({ mapping: mapping, index: index })
      }, (mapping: EngineeringReviewRestoreMappingRow, index: number) => `${index}:${mapping.sourceDocumentId}:${mapping.targetDocumentId}`)
      if (params.preview.mappings.length === 0) {
        Text('暂无文档来源映射').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).id('engineering-review-restore-mappings')
  }

  @Builder
  private Diagnostics(params: RestorePreviewParams) {
    Column({ space: 8 }) {
      Text(`诊断（${params.preview.diagnostics.length}）`).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
      ForEach(params.preview.diagnostics, (diagnostic: EngineeringReviewRestoreDiagnosticRow, index: number) => {
        Column({ space: 4 }) {
          Text(diagnostic.code).fontSize(UI.fontCaption).fontColor(COLORS.warning).width('100%')
            .wordBreak(WordBreak.BREAK_ALL)
          Text(diagnostic.message).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%').wordBreak(WordBreak.BREAK_ALL)
          if (diagnostic.sourceDocumentId !== undefined) {
            Text(`来源文档：${diagnostic.sourceDocumentId}`).fontFamily('monospace').fontSize(UI.fontCaption).fontColor(COLORS.muted)
              .width('100%').wordBreak(WordBreak.BREAK_ALL)
          }
          if (diagnostic.cellKey !== undefined) {
            Text(`Cell：${diagnostic.cellKey}`).fontFamily('monospace').fontSize(UI.fontCaption).fontColor(COLORS.muted)
              .width('100%').wordBreak(WordBreak.BREAK_ALL)
          }
        }.width('100%').alignItems(HorizontalAlign.Start).padding(12).backgroundColor(COLORS.surfaceMuted)
          .borderRadius(UI.panelRadius).id(`engineering-review-restore-diagnostic-${index}`)
      }, (diagnostic: EngineeringReviewRestoreDiagnosticRow, index: number) => `${index}:${diagnostic.code}:${diagnostic.sourceDocumentId ?? ''}:${diagnostic.cellKey ?? ''}`)
      if (params.preview.diagnostics.length === 0) {
        Text('无恢复诊断问题').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
      }
    }.width('100%').alignItems(HorizontalAlign.Start).id('engineering-review-restore-diagnostics')
  }

  @Builder
  private Actions(params: RestoreActionsParams) {
    Row({ space: 8 }) {
      Button('取消', { type: ButtonType.Normal }).engineeringReviewRestoreButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1)
        .enabled(this.current(params.token, params.generation)).onClick(() => this.cancel(params.token, params.generation))
        .id('engineering-review-restore-cancel')
      Button(this.busy ? '正在恢复…' : '确认恢复', { type: ButtonType.Normal }).engineeringReviewRestoreButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1)
        .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary })
        .borderRadius(UI.controlRadius).enabled(this.canConfirm(params.token, params.generation))
        .onClick(() => this.confirm(params.token, params.generation)).id('engineering-review-restore-confirm')
    }.width('100%').padding({ top: 12 }).border({ width: { top: 1 }, color: COLORS.border })
      .id('engineering-review-restore-actions')
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('工程恢复预览').fontSize(UI.titleSize).fontWeight(FontWeight.Bold).fontColor(COLORS.ink).width('100%')
      }.width('100%').padding({ bottom: 10 })
        .border({ width: { bottom: 0.75 }, color: COLORS.border })
      ForEach([this.previewRenderKey()], (renderKey: string) => {
        Scroll() {
          Column({ space: 12 }) {
            if (this.visibleError().length > 0) {
              Text(this.visibleError()).fontSize(UI.fontBody).fontColor(COLORS.danger).width('100%')
                .wordBreak(WordBreak.BREAK_ALL).id('engineering-review-restore-error')
            }
            if (this.preview !== undefined) {
              Text(this.statusText(this.preview)).fontSize(UI.fontBody).fontWeight(FontWeight.Medium)
                .fontColor(this.busy ? COLORS.primary : (this.preview.canRestore ? COLORS.ink : COLORS.warning))
                .width('100%').id('engineering-review-restore-status')
              this.WorkspaceIds({ preview: this.preview })
              this.Counts({ preview: this.preview })
              this.MappingControls({ token: this.preview.token, generation: this.generation, inventory: this.mappingInventory() })
              this.Mappings({ preview: this.preview })
              this.Diagnostics({ preview: this.preview })
            } else {
              Text('暂无恢复预览').fontSize(UI.fontBody).fontColor(COLORS.muted)
                .width('100%').id('engineering-review-restore-empty')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).align(Alignment.Top).scrollBar(BarState.Auto)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .clip(true)
          .id('engineering-review-restore-scroll')
        this.Actions({ token: this.preview !== undefined ? this.preview.token : '', generation: this.generation })
      }, (renderKey: string) => renderKey)
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).id('engineering-review-restore-panel')
  }
}

@Extend(Button)
function engineeringReviewRestoreButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink).padding({ left: 12, right: 12 })
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
  .hoverEffect(HoverEffect.Highlight)
}
