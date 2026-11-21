import { hongTuThemeState } from '../../store/ThemeStore';
import { common } from '@kit.AbilityKit';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { WorkbenchIcon } from './WorkbenchIcon';
import { NativeLayoutCompareLayer, NativeLayoutCompareOptions, NativeLayoutCompareResult, NativeStructureDifference, NativeJobProgress, NativeCompareJobResult } from '../../../cpp/types/libhongtu/Index';
import { ExportLayoutInput } from '../../services/LayoutExportService';
import { layoutCompareService, emptyLayoutCompareResult, LayoutCompareRun, layoutCompareProgressText } from '../../services/LayoutCompareService';
import { engineeringFileService } from '../../services/EngineeringFileService';

@Component
export struct LayoutComparePanel {
  @Prop panelWidth: number = 580;
  @Prop panelHeight: number = 700;
  snapshotProvider: () => ExportLayoutInput = () => { throw new Error('当前文档尚未连接'); };
  revisionProvider: () => string = () => '';
  @Prop @Watch('invalidateResult') inputRevision: string = '';
  locateAction: (layer: NativeLayoutCompareLayer, cellName: string) => void = () => {};
  resultAction: (result: NativeLayoutCompareResult) => void = () => {};
  closeAction: () => void = () => {};
  @State fileB: string = '';
  @State cellA: string = '';
  @State cellB: string = '';
  @State offsetX: string = '0';
  @State offsetY: string = '0';
  @State gridNm: string = '0';
  @State busy: boolean = false;
  @State stopping: boolean = false;
  @State jobProgress: string = '';
  @State status: string = '选择参考文件 B，与当前编辑中的 A 比较。';
  @State result: NativeLayoutCompareResult = emptyLayoutCompareResult();
  private contentScroller: Scroller = new Scroller();
  private pathB: string = '';
  private fileA: string = '';
  private options: NativeLayoutCompareOptions = { cellA: '', cellB: '', offsetX: 0, offsetY: 0, gridNm: 0 };
  private generation: number = 0;
  private resultRevision: string = '';
  private active: boolean = true;
  private compareRun: LayoutCompareRun | undefined = undefined;
  private progressTimer: number = -1;
  private waitingForStop: boolean = false;
  aboutToAppear(): void { this.active = true; }
  aboutToDisappear(): void {
    this.active = false;
    this.generation++;
    if (this.compareRun) this.compareRun.cancel();
    if (!this.busy) engineeringFileService.removeTemporary(this.pathB);
  }
  private context(): common.UIAbilityContext { return this.getUIContext().getHostContext() as common.UIAbilityContext; }
  private invalidateResult(): void {
    this.generation++;
    if (this.compareRun) { this.stopping = true; this.compareRun.cancel(); }
    this.resultRevision = '';
    this.result = emptyLayoutCompareResult();
    this.resultAction(this.result);
    this.status = this.compareRun ? '文档已变化，正在停止本次比较…' : '比较输入已变化，请重新运行';
  }
  private cancelRun(): void {
    if (!this.compareRun || this.stopping) return;
    this.stopping = true;
    this.compareRun.cancel();
    this.status = '正在停止比较，等待后台计算结束…';
  }
  private finishRun(run: LayoutCompareRun, source: string): void {
    if (!run.workerStopped()) return;
    if (this.compareRun === run) {
      if (this.progressTimer >= 0) clearInterval(this.progressTimer);
      this.progressTimer = -1; this.compareRun = undefined; this.waitingForStop = false;
      this.busy = false; this.stopping = false; this.jobProgress = '';
    }
    if (!this.active) engineeringFileService.removeTemporary(source);
  }
  private pollRun(run: LayoutCompareRun, source: string): void {
    const progress: NativeJobProgress | undefined = run.progress();
    if (this.active && this.compareRun === run && progress) this.jobProgress = layoutCompareProgressText(progress);
    if (this.waitingForStop && run.workerStopped()) {
      if (this.active) this.status += '；后台已停止，本次结果未应用';
      this.finishRun(run, source);
    }
  }
  private changeInput(field: string, value: string): void {
    if (this.busy) return;
    if (field === 'cellA') { if (this.cellA === value) return; this.cellA = value; }
    else if (field === 'cellB') { if (this.cellB === value) return; this.cellB = value; }
    else if (field === 'offsetX') { if (this.offsetX === value) return; this.offsetX = value; }
    else if (field === 'offsetY') { if (this.offsetY === value) return; this.offsetY = value; }
    else if (field === 'gridNm') { if (this.gridNm === value) return; this.gridNm = value; }
    else return;
    this.invalidateResult();
  }
  private async pickB(): Promise<void> {
    if (this.busy) return;
    const token: number = ++this.generation;
    this.busy = true;
    try {
      const picked = await engineeringFileService.pickComparison(this.context());
      if (!this.active || token !== this.generation) { engineeringFileService.removeTemporary(picked.path); return; }
      engineeringFileService.removeTemporary(this.pathB);
      this.pathB = picked.path; this.fileB = picked.name;
      this.resultRevision = ''; this.result = emptyLayoutCompareResult(); this.resultAction(this.result);
      this.status = `参考文件：${picked.name}`;
    } catch (error) { if (this.active && token === this.generation) this.status = error instanceof Error ? error.message : String(error); }
    finally {
      if (!this.active) engineeringFileService.removeTemporary(this.pathB);
      this.busy = false;
    }
  }
  private async run(): Promise<void> {
    if (this.busy || this.pathB.length === 0) return;
    const token: number = ++this.generation;
    const revision: string = this.revisionProvider();
    const source: string = this.pathB;
    this.busy = true;
    this.stopping = false; this.waitingForStop = false;
    this.status = '正在准备当前文档快照…';
    let run: LayoutCompareRun | undefined = undefined;
    try {
      const numericText: string[] = [this.offsetX, this.offsetY, this.gridNm];
      if (!numericText.every((value: string) => /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/.test(value.trim()))) {
        throw new Error('偏移和网格请输入完整数字，不能为空');
      }
      const options: NativeLayoutCompareOptions = { cellA: this.cellA.trim(), cellB: this.cellB.trim(),
        offsetX: Number(this.offsetX), offsetY: Number(this.offsetY), gridNm: Number(this.gridNm) };
      if (![options.offsetX, options.offsetY, options.gridNm].every((value: number) => Number.isFinite(value)) || options.gridNm < 0) throw new Error('偏移和网格应为有限数字，网格不能为负');
      const input: ExportLayoutInput = this.snapshotProvider();
      run = layoutCompareService.start(input, source, options);
      this.compareRun = run;
      const ownedRun: LayoutCompareRun = run;
      this.status = '正在比较，可随时取消';
      this.progressTimer = setInterval(() => this.pollRun(ownedRun, source), 200);
      this.pollRun(ownedRun, source);
      const completed: NativeCompareJobResult = await ownedRun.completion();
      if (!this.active || token !== this.generation) return;
      if (revision !== this.revisionProvider()) throw new Error('比较期间文档已变化，请重新运行；旧结果未应用');
      if (completed.status === 'cancelled') { this.status = '已取消，后台计算已停止'; return; }
      if (this.stopping) { this.status = '后台计算已结束，本次结果未应用'; return; }
      if (completed.status !== 'succeeded' || !completed.result) throw new Error(completed.message || '比较未完成');
      const result: NativeLayoutCompareResult = completed.result;
      this.fileA = input.libName; this.options = options;
      this.result = result; this.resultRevision = revision; this.resultAction(result);
      this.status = result.success && result.complete
        ? `几何${result.geometryEqual ? '一致' : '有差异'} · 结构${result.structureEqual ? '一致' : '有差异'} · ${result.elapsedMs.toFixed(0)} ms`
        : `比较未完成：${result.errorMessage}`;
      if (result.success) {
        setTimeout(() => {
          if (this.active) {
            this.contentScroller.scrollTo({ xOffset: 0, yOffset: 300, animation: { duration: 220, curve: Curve.EaseOut } });
          }
        }, 40);
      }
    } catch (error) { if (this.active && token === this.generation) this.status = error instanceof Error ? error.message : String(error); }
    finally {
      if (run) {
        if (run.workerStopped()) this.finishRun(run, source);
        else { this.waitingForStop = true; run.cancel(); this.pollRun(run, source); }
      } else {
        this.busy = false;
        if (!this.active) engineeringFileService.removeTemporary(source);
      }
    }
  }
  private async exportReport(): Promise<void> {
    if (this.busy || !this.result.success) return;
    if (!this.result.complete || this.resultRevision !== this.revisionProvider()) { this.invalidateResult(); return; }
    const revision: string = this.resultRevision;
    const generation: number = this.generation;
    const result: NativeLayoutCompareResult = this.result;
    const canPublish: () => boolean = (): boolean => this.active && generation === this.generation &&
      revision === this.revisionProvider() && this.resultRevision === revision && result === this.result;
    this.busy = true;
    try {
      await engineeringFileService.saveText(this.context(), 'layout-comparison.json',
        layoutCompareService.report(result, this.fileA, this.fileB, this.options), canPublish);
      if (canPublish()) this.status = '比较报告已导出';
    } catch (error) { if (canPublish()) this.status = error instanceof Error ? error.message : String(error); }
    finally {
      if (!this.active) engineeringFileService.removeTemporary(this.pathB);
      this.busy = false;
    }
  }
  private locate(layer: NativeLayoutCompareLayer): void {
    if (this.resultRevision !== this.revisionProvider()) {
      this.status = '比较后文档已变化，请重新比较后定位';
      this.resultRevision = ''; this.result = emptyLayoutCompareResult(); this.resultAction(this.result);
      return;
    }
    if (!this.result.success || !this.result.complete || this.result.cellA.length === 0) return;
    this.locateAction(layer, this.result.cellA);
  }
  build() {
    Column({ space: 12 }) {
      PanelHeading({ title: '版图 A/B 比较', subtitle: '几何与层级结构差异', closeAction: () => this.closeAction() })
      if (this.result.success) {
        Row({ space: 8 }) {
          Text(`${this.result.cellA} <-> ${this.result.cellB} · ${this.result.comparedLayers} 对图层 · ${this.result.gridNm} nm 网格`)
            .fontSize(UI.fontCaption).fontColor(COLORS.primary).layoutWeight(1).maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.result.geometryEqual && this.result.structureEqual ? '完全一致' : '存在差异')
            .fontSize(11).fontColor(this.result.geometryEqual && this.result.structureEqual ? COLORS.success : COLORS.warning)
        }
        .width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .backgroundColor(COLORS.primarySoft).borderRadius(UI.controlRadius)
        .onClick(() => {
          this.contentScroller.scrollTo({ xOffset: 0, yOffset: 300, animation: { duration: 200, curve: Curve.EaseOut } });
        })
      }
      Scroll(this.contentScroller) {
        Column({ space: 12 }) {
          Column({ space: 10 }) {
            Text('比较来源').utilitySectionTitle()
            Flex({ direction: this.panelWidth < 480 ? FlexDirection.Column : FlexDirection.Row }) {
              Column({ space: 6 }) {
                Text('A · 当前编辑文档').utilityLabel()
                Text('当前编辑文档').fontSize(UI.fontBody).fontColor(COLORS.muted).width('100%').height(UI.fieldHeight)
                  .padding({ left: 12, right: 12 }).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
                Text('A Cell').utilityLabel()
                TextInput({ text: this.cellA, placeholder: '留空使用顶层 Cell' }).utilityInput().enabled(!this.busy).onChange((v: string) => this.changeInput('cellA', v))
              }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 4 - 12) / 2).margin({ right: this.panelWidth < 480 ? 0 : 12, bottom: this.panelWidth < 480 ? 12 : 0 })
              Column({ space: 6 }) {
                Text('B · 参考文件').utilityLabel()
                Row({ space: 8 }) {
                  Text(this.fileB.length > 0 ? this.fileB : '尚未选择').fontSize(UI.fontBody).fontColor(this.fileB.length > 0 ? COLORS.ink : COLORS.muted)
                    .layoutWeight(1).height(UI.fieldHeight).padding({ left: 12, right: 12 }).backgroundColor(COLORS.surface)
                    .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Button('选择文件 B', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).fontSize(12).width(96).padding(0).enabled(!this.busy).onClick(() => { this.pickB(); })
                }.width('100%')
                Text('B Cell').utilityLabel()
                TextInput({ text: this.cellB, placeholder: '留空使用顶层 Cell' }).utilityInput().enabled(!this.busy).onChange((v: string) => this.changeInput('cellB', v))
              }.width(this.panelWidth < 480 ? '100%' : (this.panelWidth - UI.panelPadding * 4 - 12) / 2)
            }.width('100%')
          }.utilitySection().id('layout-compare-source')
          Column({ space: 10 }) {
            Text('对齐与网格').utilitySectionTitle()
            Row({ space: 10 }) {
              Column({ space: 6 }) {
                Text('B 偏移 X / nm').utilityLabel()
                TextInput({ text: this.offsetX }).utilityInput().enabled(!this.busy).onChange((v: string) => this.changeInput('offsetX', v))
              }.layoutWeight(1)
              Column({ space: 6 }) {
                Text('B 偏移 Y / nm').utilityLabel()
                TextInput({ text: this.offsetY }).utilityInput().enabled(!this.busy).onChange((v: string) => this.changeInput('offsetY', v))
              }.layoutWeight(1)
              Column({ space: 6 }) {
                Text('网格 nm').utilityLabel()
                TextInput({ text: this.gridNm }).utilityInput().enabled(!this.busy).onChange((v: string) => this.changeInput('gridNm', v))
              }.layoutWeight(1)
            }.width('100%')
            Text('网格 0 = 自动网格').fontSize(11).fontColor(COLORS.muted).width('100%')
            Text(this.status).fontSize(11).fontColor(COLORS.accent).width('100%')
            if (this.jobProgress.length > 0) { Text(this.jobProgress).fontSize(11).fontColor(COLORS.muted).width('100%') }
          }.utilitySection().id('layout-compare-grid')
          Column({ space: 10 }) {
            Text('比较结果').utilitySectionTitle()
            Column({ space: 10 }) {
              if (this.result.success) {
                Text(`${this.result.cellA} <-> ${this.result.cellB} · ${this.result.comparedLayers} 对图层 · ${this.result.gridNm} nm 网格`).fontSize(12).fontColor(COLORS.ink).width('100%')
                if (this.panelWidth >= 480) {
                  Row({ space: 10 }) {
                    Text('图层').fontSize(11).fontColor(COLORS.muted).width(92)
                    Text('差异统计').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                    Text('操作').fontSize(11).fontColor(COLORS.muted).width(80)
                  }.width('100%').padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
                }
                ForEach(this.result.layers, (layer: NativeLayoutCompareLayer) => {
                  Column({ space: 6 }) {
                    Row({ space: 10 }) {
                      Row({ space: 6 }) {
                        WorkbenchIcon({ name: 'rect', iconSize: 14, color: COLORS.muted })
                        Text(`L${layer.layerNumber}/D${layer.datatype}`).fontSize(12).fontColor(COLORS.ink).maxLines(2).layoutWeight(1)
                      }.width(92)
                      if (this.panelWidth >= 480) {
                        Text(`XOR ${(layer.xorArea / 1e6).toFixed(6)} µm² · A独有 ${(layer.areaOnlyA / 1e6).toFixed(6)} · B独有 ${(layer.areaOnlyB / 1e6).toFixed(6)}`)
                          .fontSize(11).fontColor(COLORS.ink).layoutWeight(1)
                      } else { Blank() }
                      Button('定位差异', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).fontSize(11).width(80).padding(0).backgroundColor(COLORS.surface).fontColor(COLORS.primary)
                        .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).enabled(!this.busy).onClick(() => this.locate(layer))
                    }.width('100%')
                    if (this.panelWidth < 480) {
                      Text(`XOR ${(layer.xorArea / 1e6).toFixed(6)} µm² · A独有 ${(layer.areaOnlyA / 1e6).toFixed(6)} · B独有 ${(layer.areaOnlyB / 1e6).toFixed(6)}`).fontSize(11).fontColor(COLORS.ink).width('100%')
                    }
                    if (layer.previewTruncated) { Text('差异轮廓较多，仅显示完整范围；面积计算已完成。').fontSize(11).fontColor(COLORS.muted).width('100%') }
                  }.width('100%').padding({ left: 10, right: 10, top: 8, bottom: 8 }).border({ width: { bottom: 1 }, color: COLORS.border })
                }, (layer: NativeLayoutCompareLayer) => `${layer.layerNumber}/${layer.datatype}`)
                Text(`结构记录变化：${this.result.structureDifferences.length} 组`).fontSize(13).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%').margin({ top: 8 })
                if (this.result.structureDifferences.length > 0 && this.panelWidth >= 480) {
                  Row({ space: 10 }) {
                    Text('Cell').fontSize(11).fontColor(COLORS.muted).width(92)
                    Text('变化类别').fontSize(11).fontColor(COLORS.muted).layoutWeight(1)
                    Text('A独有 / B独有').fontSize(11).fontColor(COLORS.muted).width(100)
                  }.width('100%').padding(10).backgroundColor(COLORS.surfaceMuted).borderRadius(6)
                }
                ForEach(this.result.structureDifferences.slice(0, 300), (diff: NativeStructureDifference) => {
                  if (this.panelWidth >= 480) {
                    Row({ space: 10 }) {
                      Text(diff.cellName).fontSize(12).fontColor(COLORS.ink).width(92).maxLines(2)
                      Text(diff.category).fontSize(11).fontColor(COLORS.ink).layoutWeight(1)
                      Text(`${diff.onlyInA} / ${diff.onlyInB}`).fontSize(11).fontColor(COLORS.muted).width(100)
                    }.width('100%').padding(10).border({ width: { bottom: 1 }, color: COLORS.border })
                  } else {
                    Text(`${diff.cellName} · ${diff.category}：A独有 ${diff.onlyInA}，B独有 ${diff.onlyInB}`).fontSize(11).fontColor(COLORS.ink).width('100%').padding({ top: 6, bottom: 6 })
                  }
                }, (diff: NativeStructureDifference) => `${diff.cellName}:${diff.category}`)
                if (this.result.structureDifferences.length > 300) { Text('面板显示前 300 组，完整记录在报告中。').fontSize(11).fontColor(COLORS.muted).width('100%') }
              }
              Text('几何比较按 layer/datatype 分开合并，包含完整所选层级。结构比较覆盖全库 Cell、实例、TEXT、NODE、普通属性，以及稳定 Cell 键、命名端口全部字段、截面全部字段和 layout/Cell 原始 context。元数据按保存顺序、Cell 归属、精确数值及字符串/JSON 原始字节严格比较，不使用 B 的对齐偏移。').fontSize(11).fontColor(COLORS.muted).width('100%').id('layout-compare-scope')
            }.width('100%')
          }.utilitySection().id('layout-compare-results')
        }.width('100%').padding({ bottom: 8 }).alignItems(HorizontalAlign.Start)
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true).id('layout-compare-content')
      Flex({ wrap: FlexWrap.Wrap }) {
        Button(this.busy ? '处理中…' : '运行比较', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width(110)
          .margin({ right: 8, bottom: 4 })
          .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).enabled(!this.busy && this.pathB.length > 0).onClick(() => { this.run(); })
        Button('导出报告', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width(96).margin({ right: 8, bottom: 4 }).enabled(this.result.success && !this.busy).onClick(() => { this.exportReport(); })
        if (this.compareRun) {
          Button(this.stopping ? '停止中…' : '取消比较', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).width(96)
            .margin({ right: 8, bottom: 4 })
            .enabled(!this.stopping).onClick(() => this.cancelRun())
        }
      }.width('100%').padding({ top: 10 }).border({ width: { top: 1 }, color: COLORS.border }).id('layout-compare-actions')
    }.width(this.panelWidth).height(this.panelHeight).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay'))).id('layout-compare-panel')
  }
}

@Extend(Button)
function utilityButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).hoverEffect(HoverEffect.Highlight)
}

@Extend(TextInput)
function utilityInput() {
  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
}
@Extend(Column)
function utilitySection() {
  .width('100%').padding(UI.panelPadding).backgroundColor(COLORS.surface)
  .border({ width: 1, color: COLORS.border }).borderRadius(UI.panelRadius).alignItems(HorizontalAlign.Start)
}
@Extend(Text)
function utilitySectionTitle() {
  .fontSize(14).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
}
@Extend(Text)
function utilityLabel() {
  .fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
}
