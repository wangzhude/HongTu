import { COLORS } from '../../common/constants';
import { WorkbenchIcon } from './WorkbenchIcon';
import { FONT_MONO } from '../../common/Fonts';
import { UI } from '../../common/UiTokens';
import { canvasKeyName } from '../../common/CanvasKeyboard';
import { resetModifierKeys } from '../../common/ModifierKeys';
import { UiLayer } from '../../common/types';
import { Shape, ShapeType } from '../../models/GdsiiData';
import { PropertyCellOption, ShapePropertyField, shapePropertyFields, shapePropertyValue } from '../../services/ShapePropertyService';
import { hongTuThemeState, Radius } from '../../store/ThemeStore';

/** A field submission applies to the explicit selection in one undo transaction. */
@Component
export struct ShapePropertiesPopover {
  @Prop @Watch('resetDraft') documentId: string = '';
  @Prop @Watch('resetDraft') revision: number = 0;
  @Prop selectedShape: Shape | null = null;
  @Prop @Watch('resetDraft') selectedShapes: Shape[] = [];
  @Prop layers: UiLayer[] = [];
  @Prop cells: PropertyCellOption[] = [];
  @Prop pinned: boolean = false;
  @Prop editable: boolean = true;
  @Prop panelHeight: number = 596;
  @Prop docked: boolean = false;
  @State detailsExpanded: boolean = false;
  @State propertiesDraft: string = '';
  @State errorText: string = '';
  private propertiesSelectionKey: string = '';
  private propertiesSourceValue: string = '';
  onShapePropertySubmit: (shapeId: number, property: string, value: string) => void = () => {};
  onPropertiesSubmit: ((ids: number[], property: string, value: string, documentId: string, revision: number) => string) | null = null;
  togglePinnedAction: () => void = () => {};
  closeAction: () => void = () => {};
  copyAction: () => void = () => {};
  deleteAction: () => void = () => {};
  enterInstanceAction: (() => void) | null = null;
  flattenInstanceAction: (() => void) | null = null;
  returnCanvasFocusAction: () => void = () => {};
  saveShortcutAction: ((saveAs: boolean) => void) | null = null;

  aboutToAppear(): void {
    this.resetDraft();
  }

  aboutToDisappear(): void {
    resetModifierKeys();
  }

  private focusGuardId(): string {
    return this.docked ? 'shape-properties-focus-guard-docked' : 'shape-properties-focus-guard-floating';
  }

  private parkFocusInsidePopover(): void {
    resetModifierKeys();
    try {
      this.getUIContext().getFocusController().requestFocus('layout-canvas-keyboard');
    } catch (_err) {
      try {
        this.getUIContext().getFocusController().requestFocus(this.focusGuardId());
      } catch (error) {
        console.warn(`[ShapePropertiesPopover] park focus unavailable: ${error}`);
      }
    }
    this.returnCanvasFocusAction();
  }

  private targets(): Shape[] {
    return this.selectedShapes.length > 0 ? this.selectedShapes : (this.selectedShape === null ? [] : [this.selectedShape]);
  }

  private selectionKey(): string {
    return `${this.documentId}:${this.revision}:` + this.targets().map((s: Shape) => s.id).join(',');
  }

  private commonType(): ShapeType | null {
    const targets: Shape[] = this.targets();
    return targets.length > 0 && targets.every((s: Shape) => s.type === targets[0].type) ? targets[0].type : null;
  }

  private typeLabel(): string {
    switch (this.commonType()) {
      case ShapeType.RECT: return '矩形';
      case ShapeType.POLYGON: return '多边形';
      case ShapeType.PATH: return '路径';
      case ShapeType.TEXT: return '文本';
      case ShapeType.INSTANCE: return '实例';
      default: return '图形';
    }
  }

  private headerTitle(): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 1) {
      return `${this.typeLabel()} #${targets[0].id}`;
    }
    return this.commonType() !== null ? `${targets.length} 个${this.typeLabel()}` : `${targets.length} 个对象`;
  }

  private commonValue(key: string): string {
    const targets: Shape[] = this.targets();
    if (targets.length === 0) return '';
    const value: string = shapePropertyValue(targets[0], key);
    return targets.every((s: Shape) => shapePropertyValue(s, key) === value) ? value : '';
  }

  resetDraft(): void {
    const key: string = this.selectionKey();
    const value: string = this.commonValue('properties');
    if (key === this.propertiesSelectionKey && value === this.propertiesSourceValue) return;
    this.propertiesDraft = value;
    this.propertiesSelectionKey = key;
    this.propertiesSourceValue = value;
    this.errorText = '';
  }

  private fields(): ShapePropertyField[] {
    const fields: ShapePropertyField[] = shapePropertyFields(this.commonType());
    return fields.filter((f: ShapePropertyField) => f.key !== 'cellId' &&
      (f.key !== 'layerKey' || !this.targets().some((s: Shape) => s.type === ShapeType.INSTANCE)) &&
      (this.detailsExpanded || ['x', 'y', 'width', 'height', 'layerKey', 'text', 'pathWidth'].indexOf(f.key) >= 0));
  }

  private hasField(key: string): boolean {
    return this.fields().some((f: ShapePropertyField) => f.key === key);
  }

  private submit(key: string, value: string, selection: string): void {
    if (!this.editable || selection !== this.selectionKey()) return;
    const ids: number[] = this.targets().map((s: Shape) => s.id);
    if (this.onPropertiesSubmit !== null) {
      this.errorText = this.onPropertiesSubmit(ids, key, value, this.documentId, this.revision);
    } else if (ids.length === 1) {
      this.onShapePropertySubmit(ids[0], key, value);
    }
  }

  private cellOptions(): SelectOption[] {
    return this.cells.map((c: PropertyCellOption): SelectOption => ({ value: `${c.name} (#${c.id})` }));
  }

  private cellIndex(): number {
    return this.cells.findIndex((c: PropertyCellOption) => `${c.id}` === this.commonValue('cellId'));
  }

  private matchedLayer(): UiLayer | undefined {
    const currentKey: string = this.commonValue('layerKey');
    if (currentKey.length === 0) return undefined;
    return this.layers.find((layer: UiLayer) => `${layer.layerNumber}/${layer.datatype}` === currentKey);
  }

  private layerIndex(): number {
    const currentKey: string = this.commonValue('layerKey');
    if (currentKey.length === 0) return -1;
    return this.layers.findIndex((layer: UiLayer) => `${layer.layerNumber}/${layer.datatype}` === currentKey);
  }

  private layerDisplayLabel(layer: UiLayer): string {
    const code: string = layer.englishName.trim().length > 0 ? layer.englishName : layer.chineseName;
    if (layer.chineseName.trim().length > 0 && layer.chineseName !== code) {
      return `${code} · ${layer.chineseName}`;
    }
    return `${code} (${layer.layerNumber}/${layer.datatype})`;
  }

  private layerOptions(): SelectOption[] {
    return this.layers.map((layer: UiLayer): SelectOption => ({
      value: `${this.layerDisplayLabel(layer)} (${layer.layerNumber}/${layer.datatype})`
    }));
  }

  private selectedLayerText(): string {
    const matched: UiLayer | undefined = this.matchedLayer();
    if (matched !== undefined) {
      return this.layerDisplayLabel(matched);
    }
    const raw: string = this.commonValue('layerKey');
    return raw.length > 0 ? `L${raw}` : '多个图层';
  }

  @Builder
  private propertySection(title: string) {
    Text(title)
      .fontSize(UI.fontCaption)
      .fontWeight(FontWeight.Medium)
      .fontColor(COLORS.muted)
      .width('100%')
      .padding({ top: 10 })
      .border({ width: { top: 0.8 }, color: COLORS.border })
  }

  @Builder
  private propertyFields(keys: string[]) {
    ForEach(this.fields().filter((field: ShapePropertyField) => keys.indexOf(field.key) >= 0), (field: ShapePropertyField) => {
      SelectionPropertyField({
        label: field.label,
        unit: field.unit,
        fieldKey: field.key,
        compactCell: false,
        bareInput: false,
        stacked: field.key === 'text',
        value: this.commonValue(field.key),
        selectionKey: this.selectionKey(),
        editable: this.editable,
        focusGuardId: this.focusGuardId(),
        returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
        saveShortcutAction: this.saveShortcutAction,
        submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
      })
    }, (field: ShapePropertyField) => field.key)
  }

  @Builder
  private LayerSelectorRow() {
    if (this.layers.length > 0) {
      Row({ space: 6 }) {
        Text('图层')
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width(26)
        Row({ space: 6 }) {
          Row()
            .width(12)
            .height(12)
            .borderRadius(3)
            .backgroundColor(this.matchedLayer()?.color ?? COLORS.primary)
            .border({ width: 0.8, color: COLORS.border })
          Select(this.layerOptions())
            .selected(this.layerIndex())
            .value(this.selectedLayerText())
            .layoutWeight(1)
            .height(34)
            .font({ size: 12 })
            .fontColor(COLORS.ink)
            .backgroundColor(Color.Transparent)
            .borderRadius(UI.controlRadius)
            .enabled(this.editable)
            .focusable(false)
            .onSelect((index: number) => {
              if (index >= 0 && index < this.layers.length) {
                const chosen: UiLayer = this.layers[index];
                this.submit('layerKey', `${chosen.layerNumber}/${chosen.datatype}`, this.selectionKey());
              }
            })
        }
        .layoutWeight(1)
        .height(34)
        .padding({ left: 8, right: 2 })
        .backgroundColor(COLORS.surfaceMuted)
        .border({ width: 1, color: COLORS.border })
        .borderRadius(UI.controlRadius)
        .alignItems(VerticalAlign.Center)

        SelectionPropertyField({
          label: '',
          unit: '',
          fieldKey: 'layerKey',
          compactCell: false,
          bareInput: true,
          stacked: false,
          value: this.commonValue('layerKey'),
          selectionKey: this.selectionKey(),
          editable: this.editable,
          focusGuardId: this.focusGuardId(),
          submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
        })
        .width(66)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    } else {
      SelectionPropertyField({
        label: '图层',
        unit: '',
        fieldKey: 'layerKey',
        compactCell: false,
        bareInput: false,
        stacked: false,
        value: this.commonValue('layerKey'),
        selectionKey: this.selectionKey(),
        editable: this.editable,
        focusGuardId: this.focusGuardId(),
        returnCanvasFocusAction: () => this.returnCanvasFocusAction(),
        saveShortcutAction: this.saveShortcutAction,
        submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
      })
    }
  }

  @Builder
  private GeometryGrid() {
    Column({ space: 8 }) {
      if (this.hasField('x') && this.hasField('y')) {
        Row({ space: 8 }) {
          SelectionPropertyField({
            label: 'X',
            unit: 'nm',
            fieldKey: 'x',
            compactCell: true,
            bareInput: false,
            stacked: false,
            value: this.commonValue('x'),
            selectionKey: this.selectionKey(),
            editable: this.editable,
            focusGuardId: this.focusGuardId(),
            submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
          }).layoutWeight(1)
          SelectionPropertyField({
            label: 'Y',
            unit: 'nm',
            fieldKey: 'y',
            compactCell: true,
            bareInput: false,
            stacked: false,
            value: this.commonValue('y'),
            selectionKey: this.selectionKey(),
            editable: this.editable,
            focusGuardId: this.focusGuardId(),
            submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
          }).layoutWeight(1)
        }.width('100%')
      }
      if (this.hasField('width') && this.hasField('height')) {
        Row({ space: 8 }) {
          SelectionPropertyField({
            label: '宽',
            unit: 'nm',
            fieldKey: 'width',
            compactCell: true,
            bareInput: false,
            stacked: false,
            value: this.commonValue('width'),
            selectionKey: this.selectionKey(),
            editable: this.editable,
            focusGuardId: this.focusGuardId(),
            submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
          }).layoutWeight(1)
          SelectionPropertyField({
            label: '高',
            unit: 'nm',
            fieldKey: 'height',
            compactCell: true,
            bareInput: false,
            stacked: false,
            value: this.commonValue('height'),
            selectionKey: this.selectionKey(),
            editable: this.editable,
            focusGuardId: this.focusGuardId(),
            submitAction: (key: string, value: string, selection: string) => this.submit(key, value, selection)
          }).layoutWeight(1)
        }.width('100%')
      }
    }.width('100%')
  }

  build() {
    if (this.targets().length > 0) {
      Column() {
        Text('')
          .id(this.focusGuardId())
          .width(1)
          .height(1)
          .opacity(0)
          .focusable(true)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no')
          .onFocus(() => { resetModifierKeys(); })
          .onKeyEvent((_event: KeyEvent) => {})

        Row({ space: 6 }) {
          Row({ space: 6 }) {
            Text(this.headerTitle())
              .fontSize(this.docked ? UI.titleSize : 14)
              .fontWeight(FontWeight.Bold)
              .fontColor(COLORS.ink)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (!this.editable) {
              Text('只读')
                .fontSize(10)
                .fontColor(COLORS.muted)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(COLORS.surfaceMuted)
                .borderRadius(UI.chipRadius)
            }
          }
          .alignItems(VerticalAlign.Center)
          .layoutWeight(1)

          Button(this.pinned ? '已固定' : '固定', { type: ButtonType.Normal })
            .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .id('pin-properties-panel')
            .accessibilityText(this.pinned ? '取消固定属性面板' : '固定属性面板')
            .fontSize(11)
            .height(28)
            .padding({ left: 8, right: 8 })
            .backgroundColor(this.pinned ? COLORS.primarySoft : COLORS.surfaceMuted)
            .fontColor(this.pinned ? COLORS.primary : COLORS.muted)
            .border({ width: 1, color: this.pinned ? COLORS.primary : COLORS.border })
            .onClick(this.togglePinnedAction)

          Button({ type: ButtonType.Circle }) {
            WorkbenchIcon({ name: 'close', iconSize: 14, color: COLORS.ink })
          }
          .width(28)
          .height(28)
          .padding(0)
          .borderRadius(Radius.pill)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .focusable(false)
          .accessibilityText('关闭属性')
          .onClick(this.closeAction)
        }
        .width('100%')
        .height(this.docked ? 56 : 44)
        .padding({ left: this.docked ? UI.panelPadding : 12, right: this.docked ? UI.panelPadding : 10 })
        .border({ width: { bottom: 0.8 }, color: COLORS.border })

        Scroll() {
          Column({ space: 10 }) {
            if (this.commonType() === ShapeType.INSTANCE) {
              Row({ space: 6 }) {
                Text('Cell')
                  .fontSize(11)
                  .fontColor(COLORS.muted)
                  .width(28)
                Select(this.cellOptions())
                  .selected(this.cellIndex())
                  .value(this.cellIndex() >= 0 ? this.cells[this.cellIndex()].name : '选择 Cell')
                  .layoutWeight(1)
                  .height(34)
                  .font({ size: 12 })
                  .fontColor(COLORS.ink)
                  .backgroundColor(COLORS.surfaceMuted)
                  .border({ width: 1, color: COLORS.border })
                  .borderRadius(UI.controlRadius)
                  .enabled(this.editable)
                  .focusable(false)
                  .onSelect((index: number) => {
                    if (index >= 0 && index < this.cells.length) {
                      this.submit('cellId', `${this.cells[index].id}`, this.selectionKey());
                    }
                  })
              }.width('100%')

              if (this.enterInstanceAction !== null || this.flattenInstanceAction !== null) {
                Row({ space: 8 }) {
                  if (this.enterInstanceAction !== null && this.targets().length === 1) {
                    Button('进入 Cell', { type: ButtonType.Normal })
                      .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
                      .layoutWeight(1)
                      .height(30)
                      .fontSize(11)
                      .fontColor(COLORS.primary)
                      .backgroundColor(COLORS.primarySoft)
                      .border({ width: 1, color: COLORS.primary })
                      .onClick(() => {
                        if (this.enterInstanceAction !== null) {
                          this.enterInstanceAction();
                        }
                      })
                  }
                  if (this.flattenInstanceAction !== null) {
                    Button('展开实例', { type: ButtonType.Normal })
                      .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
                      .layoutWeight(1)
                      .height(30)
                      .fontSize(11)
                      .fontColor(COLORS.ink)
                      .backgroundColor(COLORS.surfaceMuted)
                      .border({ width: 1, color: COLORS.border })
                      .enabled(this.editable)
                      .onClick(() => {
                        if (this.flattenInstanceAction !== null) {
                          this.flattenInstanceAction();
                        }
                      })
                  }
                }.width('100%')
              }
            }

            if (this.hasField('layerKey')) {
              this.LayerSelectorRow()
            }

            this.GeometryGrid()

            this.propertyFields(['pathWidth', 'text'])

            if (this.detailsExpanded && this.commonType() === ShapeType.PATH) {
              this.propertySection('路径端部')
              this.propertyFields(['pathType', 'pathBeginExtension', 'pathEndExtension', 'pathWidthAbsolute'])
            }
            if (this.detailsExpanded && this.commonType() === ShapeType.INSTANCE) {
              this.propertySection('阵列参数')
              this.propertyFields(['arrayCols', 'arrayRows', 'arrayColStepX', 'arrayColStepY', 'arrayRowStepX', 'arrayRowStepY'])
            }
            if (this.detailsExpanded && (this.commonType() === ShapeType.INSTANCE || this.commonType() === ShapeType.TEXT)) {
              this.propertySection(this.commonType() === ShapeType.TEXT ? '显示变换' : '实例变换')
              this.propertyFields(['rotation', 'mirror', 'magnification'])
            }

            Button({ type: ButtonType.Normal }) {
              Row({ space: 6 }) {
                Text(this.detailsExpanded ? '收起更多' : '更多属性')
                  .fontSize(11)
                  .fontColor(COLORS.muted)
                  .layoutWeight(1)
                WorkbenchIcon({ name: 'chevronDown', iconSize: 14, color: COLORS.muted })
                  .rotate({ angle: this.detailsExpanded ? 180 : 0 })
              }.width('100%')
            }
            .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
            .width('100%')
            .height(30)
            .padding({ left: 10, right: 10 })
            .backgroundColor(COLORS.surfaceMuted)
            .borderRadius(UI.controlRadius)
            .onClick(() => {
              this.detailsExpanded = !this.detailsExpanded;
              this.resetDraft();
            })

            if (this.detailsExpanded) {
              this.propertySection('用户属性（JSON）')
              TextArea({ text: this.propertiesDraft, placeholder: '[{"attr":1,"dtype":6,"name":"","value":"备注"}]' })
                .height(88)
                .fontSize(11)
                .fontFamily(FONT_MONO)
                .fontColor(COLORS.ink)
                .backgroundColor(COLORS.surfaceMuted)
                .border({ width: 1, color: COLORS.border })
                .borderRadius(UI.controlRadius)
                .padding(10)
                .enabled(this.editable)
                .onFocus(() => { resetModifierKeys(); })
                .onChange((value: string) => {
                  if (this.propertiesSelectionKey === this.selectionKey()) {
                    this.propertiesDraft = value;
                  }
                })
                .onKeyEvent((event: KeyEvent) => {
                  event.stopPropagation();
                  if (event.type === KeyType.Down && canvasKeyName(event.keyCode, event.keyText) === 'ESCAPE') {
                    this.propertiesDraft = this.propertiesSourceValue;
                    this.parkFocusInsidePopover();
                  }
                })
              Button('应用用户属性', { type: ButtonType.Normal })
                .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
                .width('100%')
                .height(32)
                .fontSize(12)
                .backgroundColor(COLORS.primary)
                .fontColor(Color.White)
                .border({ width: 1, color: COLORS.primary })
                .borderRadius(UI.controlRadius)
                .enabled(this.editable && this.propertiesDraft.trim().length > 0)
                .onClick(() => this.submit('properties', this.propertiesDraft, this.propertiesSelectionKey))
            }

            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(11)
                .fontColor(COLORS.danger)
                .width('100%')
            }
          }
          .width('100%')
          .padding(this.docked ? UI.panelPadding : 12)
        }
        .width('100%')
        .layoutWeight(this.docked ? 1 : 0)
        .constraintSize({
          minHeight: 0,
          maxHeight: this.docked ? this.panelHeight : Math.max(0, Math.min(420, this.panelHeight - 100))
        })
        .align(Alignment.Top)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .clip(true)

        Row({ space: 8 }) {
          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              WorkbenchIcon({ name: 'duplicate', iconSize: 15, color: COLORS.ink })
              Text('复制').fontSize(12).fontColor(COLORS.ink)
            }
          }
          .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .layoutWeight(1)
          .height(this.docked ? UI.controlHeight : 32)
          .padding(0)
          .backgroundColor(COLORS.surfaceMuted)
          .border({ width: 1, color: COLORS.border })
          .borderRadius(UI.controlRadius)
          .onClick(this.copyAction)

          Button({ type: ButtonType.Normal }) {
            Row({ space: 5 }) {
              WorkbenchIcon({ name: 'delete', iconSize: 15, color: COLORS.danger })
              Text('删除').fontSize(12).fontColor(COLORS.danger)
            }
          }
          .utilityButton().attributeModifier(hongTuThemeState.luminousPointLightModifier())
          .layoutWeight(1)
          .height(this.docked ? UI.controlHeight : 32)
          .padding(0)
          .backgroundColor(COLORS.dangerSoft)
          .border({ width: 1, color: COLORS.dangerSoft })
          .borderRadius(UI.controlRadius)
          .enabled(this.editable)
          .onClick(this.deleteAction)
        }
        .width('100%')
        .height(this.docked ? 60 : 48)
        .padding({ left: this.docked ? UI.panelPadding : 12, right: this.docked ? UI.panelPadding : 12 })
        .border({ width: { top: 0.8 }, color: COLORS.border })
      }
      .width(this.docked ? '100%' : 274)
      .layoutWeight(this.docked ? 1 : 0)
      .attributeModifier(this.docked
        ? hongTuThemeState.luminousCardModifier(0, { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
        : hongTuThemeState.luminousFloatingModifier(UI.panelRadius, 'thick', hongTuThemeState.elevation('lg')))
      .clip(true)
      .onKeyEvent((event: KeyEvent) => { event.stopPropagation(); })
    }
  }
}

@Component
struct SelectionPropertyField {
  @Prop label: string = '';
  @Prop unit: string = '';
  @Prop fieldKey: string = '';
  @Prop @Watch('resetValue') value: string = '';
  @Prop @Watch('resetValue') selectionKey: string = '';
  @Prop editable: boolean = true;
  @Prop stacked: boolean = false;
  @Prop compactCell: boolean = false;
  @Prop bareInput: boolean = false;
  @Prop focusGuardId: string = 'shape-properties-focus-guard-floating';
  returnCanvasFocusAction: () => void = () => {};
  saveShortcutAction: ((saveAs: boolean) => void) | null = null;
  @State draft: string = '';
  private focusedSelection: string = '';
  private focusedIdentity: string = '';
  private inputFocused: boolean = false;
  private observedIdentity: string = '';
  private observedValue: string = '';
  private changed: boolean = false;
  submitAction: (key: string, value: string, selection: string) => void = () => {};

  aboutToAppear(): void {
    this.resetValue();
  }

  private selectionIdentity(): string {
    const targetsSeparator: number = this.selectionKey.lastIndexOf(':');
    const revisionSeparator: number = this.selectionKey.lastIndexOf(':', targetsSeparator - 1);
    if (revisionSeparator < 0) return this.selectionKey;
    return `${this.selectionKey.substring(0, revisionSeparator)}:${this.selectionKey.substring(targetsSeparator + 1)}:${this.fieldKey}`;
  }

  private focusSelection(): void {
    resetModifierKeys();
    this.inputFocused = true;
    this.focusedIdentity = this.selectionIdentity();
    this.focusedSelection = this.selectionKey;
  }

  private clearFocusedSelection(): void {
    this.inputFocused = false;
    this.focusedIdentity = '';
    this.focusedSelection = '';
  }

  resetValue(): void {
    const identity: string = this.selectionIdentity();
    const preserveDraft: boolean = this.inputFocused && this.focusedIdentity === identity &&
      this.observedIdentity === identity && this.observedValue === this.value;
    if (!preserveDraft) {
      this.draft = this.value;
      this.changed = false;
    }
    this.observedIdentity = identity;
    this.observedValue = this.value;
    if (this.inputFocused && this.focusedIdentity === identity) {
      this.focusedSelection = this.selectionKey;
    } else {
      this.clearFocusedSelection();
    }
  }

  private canEditFocusedSelection(): boolean {
    return this.editable && this.inputFocused && this.selectionKey.length > 0 &&
      this.focusedSelection === this.selectionKey && this.focusedIdentity === this.selectionIdentity();
  }

  private commit(): void {
    if (!this.canEditFocusedSelection() || !this.changed) return;
    this.changed = false;
    this.submitAction(this.fieldKey, this.draft, this.focusedSelection);
  }

  private releaseToCanvasFocus(): void {
    resetModifierKeys();
    try {
      this.getUIContext().getFocusController().requestFocus('layout-canvas-keyboard');
    } catch (_err) {
      try {
        this.getUIContext().getFocusController().requestFocus(this.focusGuardId);
      } catch (error) {
        console.warn(`[SelectionPropertyField] park focus unavailable: ${error}`);
      }
    }
    this.returnCanvasFocusAction();
  }

  private handleInputKey(event: KeyEvent): void {
    const key: string = canvasKeyName(event.keyCode, event.keyText);
    let ctrl: boolean = false;
    let shift: boolean = false;
    if (event.getModifierKeyState !== undefined) {
      try {
        ctrl = event.getModifierKeyState(['Ctrl']);
        shift = event.getModifierKeyState(['Shift']);
      } catch (_err) {}
    }
    if (ctrl && key === 'S') {
      event.stopPropagation();
      if (event.type === KeyType.Down) {
        this.commit();
        this.clearFocusedSelection();
        this.releaseToCanvasFocus();
        if (this.saveShortcutAction !== null) {
          this.saveShortcutAction(shift);
        }
      }
      return;
    }
    event.stopPropagation();
    if (event.type !== KeyType.Down || key !== 'ESCAPE') return;
    this.clearFocusedSelection();
    this.resetValue();
    this.releaseToCanvasFocus();
  }

  @Builder
  private inlineEmbeddedField() {
    Row({ space: 4 }) {
      if (this.compactCell && this.label.length > 0) {
        Text(this.label)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .constraintSize({ minWidth: 14 })
          .maxLines(1)
      }
      TextInput({ text: this.draft, placeholder: this.bareInput ? 'L/D' : '多值' })
        .fontSize(12)
        .fontFamily(FONT_MONO)
        .fontColor(COLORS.ink)
        .placeholderColor(COLORS.muted)
        .height(32)
        .layoutWeight(1)
        .padding({ left: 2, right: 2 })
        .backgroundColor(Color.Transparent)
        .borderWidth(0)
        .enabled(this.editable)
        .accessibilityText(this.label.length > 0 ? this.label : this.fieldKey)
        .onFocus(() => this.focusSelection())
        .onChange((value: string) => {
          if (this.canEditFocusedSelection()) {
            this.draft = value;
            this.changed = true;
          }
        })
        .onSubmit(() => {
          this.commit();
          this.clearFocusedSelection();
          this.releaseToCanvasFocus();
        })
        .onBlur(() => {
          this.commit();
          this.clearFocusedSelection();
        })
        .onKeyEvent((event: KeyEvent) => this.handleInputKey(event))
      if (this.unit.length > 0) {
        Text(this.unit)
          .fontSize(10)
          .fontFamily(FONT_MONO)
          .fontColor(COLORS.muted)
          .maxLines(1)
      }
    }
    .width('100%')
    .height(34)
    .padding({ left: 8, right: 8 })
    .backgroundColor(COLORS.surfaceMuted)
    .border({ width: 1, color: COLORS.border })
    .borderRadius(UI.controlRadius)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    if (this.compactCell || this.bareInput) {
      this.inlineEmbeddedField()
    } else if (this.stacked) {
      Column({ space: 6 }) {
        Text(this.label).fontSize(11).fontColor(COLORS.muted).width('100%')
        this.inlineEmbeddedField()
      }.width('100%')
    } else {
      Row({ space: 6 }) {
        Text(this.label)
          .fontSize(11)
          .fontColor(COLORS.muted)
          .width(68)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row() {
          this.inlineEmbeddedField()
        }.layoutWeight(1)
      }.width('100%').alignItems(VerticalAlign.Center)
    }
  }
}

@Extend(Button)
function utilityButton() {
  .height(UI.controlHeight)
  .fontSize(UI.fontBody)
  .fontColor(COLORS.ink)
  .backgroundColor(COLORS.surfaceMuted)
  .border({ width: 1, color: COLORS.border })
  .borderRadius(UI.controlRadius)
  .focusable(false)
  .hoverEffect(HoverEffect.Highlight)
}
