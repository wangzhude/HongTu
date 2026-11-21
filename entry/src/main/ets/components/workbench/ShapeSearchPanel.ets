import { SettingsToggleRow } from '../SettingsKit';
import { hongTuThemeState } from '../../store/ThemeStore';
import { COLORS } from '../../common/constants';
import { resetModifierKeys } from '../../common/ModifierKeys';
import { UI } from '../../common/UiTokens';
import { PanelHeading } from './PanelHeading';
import { WorkbenchIcon } from './WorkbenchIcon';
import { RADIUS } from '../../common/MaterialTokens';
import { Shape, ShapeType } from '../../models/GdsiiData';
import { advEditService, SearchCriteria } from '../../services/AdvancedEditService';
import { editService } from '../../services/EditService';

const SEARCH_TYPES: ShapeType[] = [ShapeType.RECT, ShapeType.POLYGON, ShapeType.PATH, ShapeType.TEXT, ShapeType.INSTANCE];

/** Results are re-run after document edits; stale IDs never act on another tab. */
@Component
export struct ShapeSearchPanel {
  @Prop panelWidth: number = 460;
  @Prop @Watch('refreshResults') shapes: Shape[] = [];
  @Prop @Watch('refreshResults') currentCellId: number = 0;
  @Prop @Watch('clearResults') documentKey: string = '';
  @Prop cellNames: string[] = [];
  @State layerText: string = '';
  @State typeIndex: number = 0;
  @State textPattern: string = '';
  @State minWidthText: string = '';
  @State maxWidthText: string = '';
  @State minHeightText: string = '';
  @State maxHeightText: string = '';
  @State currentCellOnly: boolean = true;
  @State selectableOnly: boolean = true;
  @State resultIds: number[] = [];
  @State status: string = '';
  private hasSearched: boolean = false;
  private resultShapes: Map<number, Shape> = new Map<number, Shape>();
  locateAction: (id: number) => void = () => {};
  selectAction: (ids: number[]) => void = () => {};
  batchEditAction: (ids: number[]) => void = () => {};
  enterResultCellAction: (id: number) => void = () => {};
  closeAction: () => void = () => {};

  aboutToAppear(): void {
    resetModifierKeys();
  }

  aboutToDisappear(): void {
    resetModifierKeys();
  }

  clearResults(): void { this.resultIds = []; this.resultShapes.clear(); this.status = ''; this.hasSearched = false; }
  refreshResults(): void { if (this.hasSearched) this.search(); }
  private optionalNumber(value: string): number | undefined {
    return value.trim().length === 0 ? undefined : Number(value);
  }
  private search(): void {
    const criteria: SearchCriteria = { selectableOnly: this.selectableOnly };
    if (this.currentCellOnly) criteria.ownerCellId = this.currentCellId;
    if (this.typeIndex > 0) criteria.type = SEARCH_TYPES[this.typeIndex - 1];
    if (this.layerText.trim().length > 0) {
      const pair: string[] = this.layerText.trim().split('/');
      if (pair.length > 2 || pair.some((p: string) => p.trim().length === 0 ||
        !Number.isInteger(Number(p)) || Number(p) < 0 || Number(p) > 32767)) {
        this.status = '图层格式为 68 或 68/20，取值 0–32767'; this.resultIds = []; return;
      }
      criteria.layer = Number(pair[0]);
      if (pair.length === 2) criteria.datatype = Number(pair[1]);
    }
    const values: string[] = [this.minWidthText, this.maxWidthText, this.minHeightText, this.maxHeightText];
    if (values.some((v: string) => v.trim().length > 0 && (!Number.isFinite(Number(v)) || Number(v) < 0))) {
      this.status = '尺寸必须为非负有限数值（nm）'; this.resultIds = []; return;
    }
    criteria.minWidth = this.optionalNumber(this.minWidthText); criteria.maxWidth = this.optionalNumber(this.maxWidthText);
    criteria.minHeight = this.optionalNumber(this.minHeightText); criteria.maxHeight = this.optionalNumber(this.maxHeightText);
    if ((criteria.minWidth !== undefined && criteria.maxWidth !== undefined && criteria.minWidth > criteria.maxWidth) ||
      (criteria.minHeight !== undefined && criteria.maxHeight !== undefined && criteria.minHeight > criteria.maxHeight)) {
      this.status = '尺寸下限不能超过上限'; this.resultIds = []; return;
    }
    criteria.textPattern = this.textPattern.trim();
    this.hasSearched = true;
    const results: Shape[] = advEditService.searchShapes(criteria).filter((s: Shape) => s.type !== ShapeType.NODE);
    this.resultShapes.clear();
    for (const shape of results) this.resultShapes.set(shape.id, shape);
    this.resultIds = results.map((s: Shape) => s.id);
    this.status = advEditService.getLastGeometryError() || `找到 ${this.resultIds.length} 个对象${this.resultIds.length > 200 ? '，列表显示前 200 项' : ''}`;
  }
  private resultLabel(id: number): string {
    const s: Shape | undefined = this.resultShapes.get(id);
    if (s === undefined) return `#${id}`;
    const b = advEditService.getSearchShapeBounds(s);
    const cellId: number = s.ownerCellId ?? editService.getTopCellId();
    return `#${id} ${s.type} · L${s.layerNumber}/D${s.datatype}\nCell ${this.cellNames[cellId] ?? cellId} · ${b === undefined ? '无可解析几何尺寸' : `${b.maxX - b.minX} × ${b.maxY - b.minY} nm`}${s.text ? ` · ${s.text}` : ''}`;
  }
  private currentMatches(editable: boolean = false): number[] {
    // Selection never crosses the edit context, even when results span the document.
    const matched: Set<number> = new Set<number>(this.resultIds);
    return this.shapes.filter((s: Shape) => matched.has(s.id) &&
      (s.ownerCellId ?? editService.getTopCellId()) === this.currentCellId &&
      editService.canSelectLayer(s.layerNumber, s.datatype) &&
      (!editable || editService.canEditLayer(s.layerNumber, s.datatype))).map((s: Shape) => s.id);
  }
  private selectMatches(): void {
    const ids: number[] = this.currentMatches();
    this.selectAction(ids);
    this.status = `已选择当前 Cell 的 ${ids.length} 个匹配对象`;
  }
  build() {
    Column({ space: 12 }) {
      PanelHeading({ title: '查找图形', closeAction: () => this.closeAction() })
      Scroll() {
        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Column({ space: 6 }) {
              Text('图层 / 数据型').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              TextInput({ text: this.layerText, placeholder: '68 或 68/20' })
                .utilityInput()
                .defaultFocus(true)
                .onChange((v: string) => this.layerText = v)
                .onSubmit(() => { this.search(); })
            }.layoutWeight(1)
            Column({ space: 6 }) {
              Text('对象类型').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              Select([{ value: '全部类型' }, { value: '矩形' }, { value: '多边形' }, { value: '路径' }, { value: '文本' }, { value: '实例' }])
                .selected(this.typeIndex).value(['全部类型', '矩形', '多边形', '路径', '文本', '实例'][this.typeIndex] ?? '全部类型')
                .font({ size: UI.fontBody }).fontColor(COLORS.ink).height(UI.fieldHeight).width('100%')
                .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius).onSelect((i: number) => this.typeIndex = i)
            }.layoutWeight(1)
          }.width('100%')
          Column({ space: 6 }) {
            Text('文本内容').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
            Search({ value: this.textPattern, placeholder: '包含的文本，不区分大小写' })
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
              .onChange((v: string) => { this.textPattern = v; })
              .onSubmit(() => { this.search(); })
          }.width('100%')
          Flex({ direction: this.panelWidth < 400 ? FlexDirection.Column : FlexDirection.Row }) {
            Column({ space: 6 }) {
              Text('宽度 (nm)').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              Row({ space: 6 }) {
                TextInput({ text: this.minWidthText, placeholder: '最小值' }).utilityInput().layoutWeight(1).onChange((v: string) => this.minWidthText = v)
                Text('–').fontSize(12).fontColor(COLORS.muted)
                TextInput({ text: this.maxWidthText, placeholder: '最大值' }).utilityInput().layoutWeight(1).onChange((v: string) => this.maxWidthText = v)
              }.width('100%').padding({ right: 2 })
            }.width(this.panelWidth < 400 ? '100%' : 'calc(50% - 6vp)').margin({ right: this.panelWidth < 400 ? 0 : 12, bottom: this.panelWidth < 400 ? 12 : 0 })
            Column({ space: 6 }) {
              Text('高度 (nm)').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%')
              Row({ space: 6 }) {
                TextInput({ text: this.minHeightText, placeholder: '最小值' }).utilityInput().layoutWeight(1).onChange((v: string) => this.minHeightText = v)
                Text('–').fontSize(12).fontColor(COLORS.muted)
                TextInput({ text: this.maxHeightText, placeholder: '最大值' }).utilityInput().layoutWeight(1).onChange((v: string) => this.maxHeightText = v)
              }.width('100%').padding({ right: 2 })
            }.width(this.panelWidth < 400 ? '100%' : 'calc(50% - 6vp)')
          }.width('100%')
          Column({ space: 6 }) {
            SettingsToggleRow({
              title: '仅限当前 Cell',
              isOn: this.currentCellOnly,
              compact: true,
              onToggle: (v: boolean) => { this.currentCellOnly = v; }
            })
            SettingsToggleRow({
              title: '仅匹配可选对象',
              isOn: this.selectableOnly,
              compact: true,
              onToggle: (v: boolean) => { this.selectableOnly = v; }
            })
          }.width('100%')
          Row({ space: 8 }) {
            Button('查找', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1)
              .backgroundColor(COLORS.primary).fontColor(Color.White).border({ width: 1, color: COLORS.primary }).borderRadius(UI.controlRadius).onClick(() => this.search())
            Button('选择匹配项', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).layoutWeight(1)
              .enabled(this.resultIds.length > 0).onClick(() => this.selectMatches())
          }.width('100%')
          Button(`批量属性 · ${this.currentMatches(true).length} 个可编辑匹配项`, { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .width('100%').enabled(this.currentMatches(true).length > 0)
            .onClick(() => this.batchEditAction(this.currentMatches(true)))
          Divider().color(COLORS.border)
          Text(this.status.length > 0 ? this.status : '查找结果').fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%')
          List({ space: 8 }) {
            ForEach(this.resultIds.slice(0, 200), (id: number) => {
              ListItem() {
                Row({ space: 8 }) {
                  WorkbenchIcon({ name: this.resultShapes.get(id)?.type.toLowerCase() ?? 'rect', iconSize: 16, color: COLORS.muted })
                  Column({ space: 5 }) {
                    Text(this.resultLabel(id).split('\n')[0]).fontSize(UI.fontBody).fontWeight(FontWeight.Medium).fontColor(COLORS.ink).width('100%').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(this.resultLabel(id).split('\n')[1] ?? '').fontSize(UI.fontCaption).fontColor(COLORS.muted).width('100%').maxLines(2)
                  }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  if ((this.resultShapes.get(id)?.ownerCellId ?? editService.getTopCellId()) !== this.currentCellId) {
                    Button('进入 Cell', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).padding({ left: 8, right: 8 }).fontSize(UI.fontCaption)
                      .backgroundColor(COLORS.surface).onClick(() => this.enterResultCellAction(id))
                  }
                  Button('定位', { type: ButtonType.Normal }).utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier()).height(UI.compactControlHeight).width(54).padding(0)
                    .backgroundColor(COLORS.surface).fontColor(COLORS.primary).onClick(() => this.locateAction(id))
                }.width('100%').padding(12).backgroundColor(COLORS.surfaceMuted).borderRadius(UI.controlRadius)
              }
            }, (id: number) => `${id}`)
          }.width('100%').height(260).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
        }.width('100%').padding({ left: 2, right: 2 })
      }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true }).clip(true)
    }.width(this.panelWidth).height('85%').constraintSize({ maxWidth: '94%', maxHeight: 740 }).padding(UI.panelPadding)
      .attributeModifier(hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('overlay')))
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
  }
}

@Extend(Button)
function utilityButton() {
  .height(UI.controlHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
  .focusable(false).hoverEffect(HoverEffect.Highlight)
}

@Extend(TextInput)
function utilityInput() {
  .height(UI.fieldHeight).fontSize(UI.fontBody).fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted).border({ width: 1, color: COLORS.border }).borderRadius(UI.controlRadius)
  .onFocus(() => { resetModifierKeys(); })
  .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
}
