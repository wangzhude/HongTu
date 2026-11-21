import { hongTuThemeState } from '../../store/ThemeStore';
import { SettingsToggleRow } from '../SettingsKit';
import { PanelHeading } from '../workbench/PanelHeading';
import { COLORS } from '../../common/constants';
import { UI } from '../../common/UiTokens';
import { UiLayer } from '../../common/types';
import { dialogTransition } from '../../common/Motion';
import { Shape, ShapeType, Point, getShapeBounds } from '../../models/GdsiiData';
import { BooleanPreview, BooleanPreviewOptions, BooleanPreviewResult, PreviewBooleanOp } from '../../services/BooleanPreviewService';
import { acquireModalKeyboardGate, releaseModalKeyboardGate, resetModifierKeys } from '../../common/ModifierKeys';

const BOOLEAN_OPS: PreviewBooleanOp[] = ['merge', 'subtract', 'intersect', 'xor'];
const BOOLEAN_LABELS: string[] = ['A ∪ B 合并', 'A - B 相减', 'A ∩ B 相交', 'A XOR B 异或'];

@Component
export struct BooleanGeometryView {
  @Prop @Watch('redraw') shapes: Shape[] = [];
  @Prop @Watch('redraw') extentShapes: Shape[] = [];
  @Prop sourceColors: boolean = false;
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ready: boolean = false;
  private redraw(): void {
    if (!this.ready) return;
    const ctx: CanvasRenderingContext2D = this.context;
    const width: number = ctx.width; const height: number = ctx.height;
    ctx.clearRect(0, 0, width, height);
    if (this.extentShapes.length === 0) return;
    let minX: number = Number.POSITIVE_INFINITY; let minY: number = Number.POSITIVE_INFINITY;
    let maxX: number = Number.NEGATIVE_INFINITY; let maxY: number = Number.NEGATIVE_INFINITY;
    for (const shape of this.extentShapes) {
      const b = getShapeBounds(shape); minX = Math.min(minX, b.minX); minY = Math.min(minY, b.minY);
      maxX = Math.max(maxX, b.maxX); maxY = Math.max(maxY, b.maxY);
    }
    const scale: number = Math.min((width - 24) / Math.max(1, maxX - minX), (height - 24) / Math.max(1, maxY - minY));
    const ox: number = (width - (maxX - minX) * scale) / 2; const oy: number = (height - (maxY - minY) * scale) / 2;
    const denseMode: boolean = this.shapes.length > 256;
    const occupiedCells: Set<number> = new Set<number>();
    for (let index: number = 0; index < this.shapes.length; index++) {
      const shape: Shape = this.shapes[index];
      const b = getShapeBounds(shape);
      const screenW: number = (b.maxX - b.minX) * scale;
      const screenH: number = (b.maxY - b.minY) * scale;
      const fillColor: string = this.sourceColors && index === 1 ? '#45D79B2A' : '#453C7DFF';
      const strokeColor: string = this.sourceColors && index === 1 ? '#D79B2A' : '#3C7DFF';
      if (denseMode && screenW <= 2.2 && screenH <= 2.2) {
        const sx: number = ox + (b.minX - minX) * scale;
        const sy: number = height - oy - (b.maxY - minY) * scale;
        const cellKey: number = ((Math.round(sx * 2) & 0x7FFF) << 16) | (Math.round(sy * 2) & 0xFFFF);
        if (occupiedCells.has(cellKey)) continue;
        occupiedCells.add(cellKey);
        ctx.fillStyle = strokeColor;
        ctx.fillRect(sx, sy, Math.max(1.1, screenW), Math.max(1.1, screenH));
        continue;
      }
      const points: Point[] = shape.type === 'rect' ? [{ x: b.minX, y: b.minY }, { x: b.maxX, y: b.minY },
        { x: b.maxX, y: b.maxY }, { x: b.minX, y: b.maxY }] as Point[] : shape.points;
      if (points.length < 3) continue;
      const step: number = (denseMode && points.length > 24 && Math.max(screenW, screenH) < 18) ? Math.max(1, Math.floor(points.length / 12)) : 1;
      ctx.beginPath();
      for (let i: number = 0; i < points.length; i += step) {
        const x: number = ox + (points[i].x - minX) * scale; const y: number = height - oy - (points[i].y - minY) * scale;
        if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
      }
      ctx.closePath();
      ctx.fillStyle = fillColor;
      ctx.strokeStyle = strokeColor;
      ctx.lineWidth = denseMode ? 1.0 : 1.5; ctx.fill(); ctx.stroke();
    }
  }
  build() {
    Canvas(this.context).width('100%').height(172).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
      .onReady(() => { this.ready = true; this.redraw(); })
      .onAreaChange(() => { this.redraw(); })
  }
}

@Component
export struct BooleanGeometryPanel {
  @Prop title: string = '';
  @Prop shapes: Shape[] = [];
  @Prop extentShapes: Shape[] = [];
  @Prop sourceColors: boolean = false;
  build() {
    Column({ space: 8 }) {
      Text(this.title).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
      BooleanGeometryView({ shapes: this.shapes, extentShapes: this.extentShapes, sourceColors: this.sourceColors })
    }.layoutWeight(1).padding(12).backgroundColor(COLORS.surface)
      .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).alignItems(HorizontalAlign.Start)
  }
}

@CustomDialog
export struct BooleanPreviewDialog {
  controller: CustomDialogController;
  private modalGateToken: number = 0;
  sourcesProvider: () => Shape[] = () => [];
  layersProvider: () => UiLayer[] = () => [];
  contextProvider: () => string = () => '';
  opProvider: () => PreviewBooleanOp = () => 'subtract';
  cellNameProvider: () => string = () => '';
  dbuProvider: () => number = () => 1;
  prepareAction: (options: BooleanPreviewOptions) => BooleanPreviewResult = (_options: BooleanPreviewOptions) => ({ ok: false, message: '' });
  applyAction: (preview: BooleanPreview) => BooleanPreviewResult = (_preview: BooleanPreview) => ({ ok: false, message: '' });
  private openedContext: string = '';
  private previewTimer: number = -1;
  @State sources: Shape[] = [];
  @State availableLayers: UiLayer[] = [];
  @State opIndex: number = 1;
  @State outputLayer: string = '0';
  @State outputDatatype: string = '0';
  /** 默认直接替换 A/B 原图（对齐 KLayout/Virtuoso 原位布尔行为，避免原矩形残留在新图形下方遮挡差集挖空区域） */
  @State keepSources: boolean = false;
  private previewResult: BooleanPreview | undefined = undefined;
  @State previewReady: boolean = false;
  @State previewOutputs: Shape[] = [];
  @State previewArea: number = 0;
  @State status: string = '';
  @State contentWidth: number = 652;

  aboutToAppear(): void {
    this.modalGateToken = acquireModalKeyboardGate();
    this.sources = this.sourcesProvider();
    this.availableLayers = this.layersProvider();
    this.openedContext = this.contextProvider();
    const initialOp: number = BOOLEAN_OPS.indexOf(this.opProvider());
    this.opIndex = initialOp >= 0 ? initialOp : 1;
    // 若任一源对象所在图层已锁定无法删除，则自动退化为保留原图并输出到可编辑层
    const sourceLocked: boolean = this.sources.some((s: Shape): boolean =>
      this.availableLayers.some((l: UiLayer): boolean => l.layerNumber === s.layerNumber && l.datatype === s.datatype && l.locked === true)
    );
    this.keepSources = sourceLocked;
    this.outputLayer = `${this.sources[0]?.layerNumber ?? 0}`;
    this.outputDatatype = `${this.sources[0]?.datatype ?? 0}`;
    this.clearPreview();
    this.status = '';
    this.refreshPreview();
  }

  private clearPreview(): void {
    this.previewResult = undefined; this.previewReady = false; this.previewOutputs = []; this.previewArea = 0;
  }

  private shapeKindText(shape: Shape): string {
    if (shape.type === ShapeType.RECT) return '矩形';
    if (shape.type === ShapeType.POLYGON) return '多边形';
    return shape.type;
  }

  private scheduleRefreshPreview(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    this.clearPreview();
    const lnTrim: string = this.outputLayer.trim();
    const dtTrim: string = this.outputDatatype.trim();
    if (!/^\d+$/.test(lnTrim) || !/^\d+$/.test(dtTrim)) {
      this.status = '请填写 0–32767 的整数输出 Layer / Datatype';
      return;
    }
    this.previewTimer = setTimeout(() => {
      this.previewTimer = -1;
      this.refreshPreview();
    }, 80);
  }

  private refreshPreview(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    this.clearPreview();
    if (this.openedContext !== this.contextProvider()) { this.status = '文档或选择已变化，请重新打开布尔预览'; return; }
    if (this.sources.length !== 2) { this.status = '请恰好选择两个矩形或普通多边形'; return; }
    if (this.outputLayer.trim().length === 0 || this.outputDatatype.trim().length === 0) { this.status = '请填写输出 layer/datatype'; return; }
    try {
      const options: BooleanPreviewOptions = {
        op: BOOLEAN_OPS[this.opIndex],
        sourceAId: this.sources[0].id,
        sourceBId: this.sources[1].id,
        outputLayer: Number(this.outputLayer),
        outputDatatype: Number(this.outputDatatype),
        keepSources: this.keepSources
      };
      const result: BooleanPreviewResult = this.prepareAction(options);
      this.status = result.message;
      if (result.ok && result.preview !== undefined) {
        this.previewResult = result.preview;
        this.previewOutputs = result.preview.outputs;
        this.previewArea = result.preview.areaNm2;
        this.previewReady = true;
      }
    } catch (error) { this.status = `预览失败：${String(error)}`; }
  }

  private apply(): void {
    if (!this.previewReady || this.previewResult === undefined) {
      this.refreshPreview();
    }
    if (!this.previewReady || this.previewResult === undefined) return;
    if (this.openedContext !== this.contextProvider()) { this.clearPreview(); this.status = '文档或选择已变化，请重新生成预览'; return; }
    try {
      const result: BooleanPreviewResult = this.applyAction(this.previewResult);
      this.status = result.message;
      if (result.ok) this.controller.close(); else this.clearPreview();
    } catch (error) { this.clearPreview(); this.status = `提交未完成：${String(error)}`; }
  }

  private matchedLayerIndex(): number {
    return this.availableLayers.findIndex((layer: UiLayer): boolean =>
      `${layer.layerNumber}` === this.outputLayer.trim() && `${layer.datatype}` === this.outputDatatype.trim()
    );
  }

  private layerSelectOptions(): SelectOption[] {
    return this.availableLayers.map((layer: UiLayer): SelectOption => ({
      value: `L${layer.layerNumber}/D${layer.datatype} · ${layer.chineseName || layer.englishName}`
    }));
  }

  private layerSelectLabel(): string {
    const idx: number = this.matchedLayerIndex();
    if (idx >= 0) {
      const l: UiLayer = this.availableLayers[idx];
      return `L${l.layerNumber}/D${l.datatype} · ${l.chineseName || l.englishName}`;
    }
    return `自定义 L${this.outputLayer.trim() || '0'}/D${this.outputDatatype.trim() || '0'}`;
  }

  @Builder
  ScopeOutput() {
    Column({ space: 10 }) {
      Text(`当前 Cell ${this.cellNameProvider()} · DBU ${this.dbuProvider()} nm`).fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
      Column({ space: 8 }) {
        Text('输出 L / D').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
        if (this.availableLayers.length > 0) {
          Select(this.layerSelectOptions())
            .selected(this.matchedLayerIndex())
            .value(this.layerSelectLabel())
            .width('100%')
            .height(UI.fieldHeight)
            .font({ size: UI.fontCaption })
            .fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted)
            .border({ width: 1, color: COLORS.border })
            .borderRadius(UI.controlRadius)
            .onSelect((index: number) => {
              if (index >= 0 && index < this.availableLayers.length) {
                const chosen: UiLayer = this.availableLayers[index];
                this.outputLayer = `${chosen.layerNumber}`;
                this.outputDatatype = `${chosen.datatype}`;
                this.refreshPreview();
              }
            })
        }
        Row({ space: 8 }) {
          Column({ space: 6 }) {
            Text('Layer').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.outputLayer, placeholder: 'Layer' }).height(UI.fieldHeight).width('100%')
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .onChange((value: string) => {
                if (value === this.outputLayer) return;
                this.outputLayer = value;
                this.scheduleRefreshPreview();
              })
          }.layoutWeight(1)
          Column({ space: 6 }) {
            Text('Datatype').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            TextInput({ text: this.outputDatatype, placeholder: 'Datatype' }).height(UI.fieldHeight).width('100%')
              .onFocus(() => { resetModifierKeys(); })
              .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
              .fontSize(UI.fontBody).fontColor(COLORS.ink).placeholderColor(COLORS.muted).backgroundColor(COLORS.surfaceMuted)
              .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .onChange((value: string) => {
                if (value === this.outputDatatype) return;
                this.outputDatatype = value;
                this.scheduleRefreshPreview();
              })
          }.layoutWeight(1)
        }.width('100%')
        Button('更新预览', { type: ButtonType.Normal }).width('100%').height(UI.controlHeight).fontSize(UI.fontBody)
          .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .onClick(() => this.refreshPreview())
      }.width('100%').padding({ top: 10 }).border({ width: { top: 1 }, color: COLORS.border })
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }

  aboutToDisappear(): void {
    if (this.previewTimer >= 0) {
      clearTimeout(this.previewTimer);
      this.previewTimer = -1;
    }
    releaseModalKeyboardGate(this.modalGateToken);
    this.modalGateToken = 0;
  }

  build() {
    Column({ space: 12 }) {
      PanelHeading({
        title: '布尔预览',
        subtitle: '修改运算或输出图层自动实时刷新预览',
        closeAction: (): void => { this.controller.close(); }
      })
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 10 }) {
            ForEach(this.sources, (source: Shape, index: number) => {
              Column({ space: 4 }) {
                Text(`${index === 0 ? 'A' : 'B'} · #${source.id} · ${source.type}`).fontSize(UI.fontBody).fontColor(COLORS.ink)
                Text(`L${source.layerNumber}/D${source.datatype} · ${this.shapeKindText(source)}`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(10).backgroundColor(COLORS.surface)
                .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            }, (source: Shape) => `${source.id}`)
            Button('交换 A/B', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontCaption)
              .backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
              .attributeModifier(hongTuThemeState.luminousPointLightModifier())
              .onClick(() => { this.sources = this.sources.slice().reverse(); this.refreshPreview(); })
          }.width('100%')
          Text('布尔操作').fontSize(UI.fontBody).fontColor(COLORS.ink).width('100%')
          Select([{ value: 'A ∪ B 合并' }, { value: 'A - B 相减' }, { value: 'A ∩ B 相交' }, { value: 'A XOR B 异或' }])
            .height(UI.fieldHeight).font({ size: UI.fontBody }).fontColor(COLORS.ink)
            .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
            .selected(this.opIndex).value(BOOLEAN_LABELS[this.opIndex]).width('100%')
            .onSelect((index: number) => { this.opIndex = index; this.refreshPreview(); })
          if (this.contentWidth >= 600) {
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: '原图 · A 蓝 / B 金', shapes: this.sources, extentShapes: this.sources, sourceColors: true })
              BooleanGeometryPanel({ title: this.previewReady ? `结果 · ${this.previewOutputs.length} 个多边形` : '结果待计算', shapes: this.previewOutputs, extentShapes: this.sources })
              this.ScopeOutput()
            }.width('100%').alignItems(VerticalAlign.Top)
          } else {
            Row({ space: 12 }) {
              BooleanGeometryPanel({ title: '原图 · A 蓝 / B 金', shapes: this.sources, extentShapes: this.sources, sourceColors: true })
              BooleanGeometryPanel({ title: this.previewReady ? `结果 · ${this.previewOutputs.length} 个多边形` : '结果待计算', shapes: this.previewOutputs, extentShapes: this.sources })
            }.width('100%')
            Row() { this.ScopeOutput() }.width('100%')
          }
          Row({ space: 12 }) {
            Row() {
              SettingsToggleRow({
                title: '保留 A/B 原图',
                subtitle: this.keepSources ? '保留原图形并叠加新结果（适合跨层派生）' : '原位替换为布尔结果（标准编辑行为，可一次撤销）',
                isOn: this.keepSources,
                compact: true,
                onToggle: (value: boolean) => { this.keepSources = value; this.refreshPreview(); }
              })
            }.layoutWeight(1)
            if (this.previewReady) {
              Text(`面积 ${this.previewArea} nm²`).fontSize(UI.fontCaption).fontColor(COLORS.muted)
            }
          }.width('100%').alignItems(VerticalAlign.Center)
        }.width('100%').padding({ bottom: 4 }).alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ maxHeight: 580 })
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(true)

      if (this.status.length > 0) {
        Text(this.status).fontSize(UI.fontCaption).fontColor(this.previewReady ? COLORS.muted : COLORS.danger).width('100%')
      }
      Row({ space: 12 }) {
        Blank()
        Button('取消', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
          .border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).backgroundColor(COLORS.surfaceMuted).fontColor(COLORS.ink)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => this.controller.close())
        Button('应用结果', { type: ButtonType.Normal }).height(UI.controlHeight).fontSize(UI.fontBody).padding({ left: 24, right: 24 })
          .borderRadius(UI.controlRadius).enabled(this.sources.length === 2)
          .backgroundColor(COLORS.primary).fontColor(Color.White)
          .attributeModifier(hongTuThemeState.luminousPointLightModifier()).onClick(() => this.apply())
      }.width('100%').padding({ top: 14 }).border({ width: { top: 1 }, color: COLORS.border })
    }.width(720).constraintSize({ maxWidth: '94%', maxHeight: '90%' }).padding(UI.dialogPadding).backgroundColor(COLORS.surface)
      .borderRadius(UI.dialogRadius).transition(dialogTransition()).onKeyEvent((event: KeyEvent) => event.stopPropagation())
      .onAreaChange((_oldArea: Area, newArea: Area) => { this.contentWidth = Math.max(0, Number(newArea.width) - 2 * UI.dialogPadding); })
  }
}
